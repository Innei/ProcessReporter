// JXAMediaInfoProvider.swift
// ProcessReporter

import AppKit
import Foundation

/// Reads the system Now Playing state through an Apple-signed `osascript`
/// process. The queried MediaRemote classes are private API, but this path does
/// not require the private mediaremoted client entitlement introduced in 15.4.
final class JXAMediaInfoProvider: MediaInfoProvider {
  private enum FetchError: Error {
    case launchFailed(Error)
    case timedOut
    case processFailed(Int32, String)
    case invalidOutput
  }

  private static let script = #"""
    ObjC.import("Foundation")

    function unwrap(value) {
      if (value === null || value === undefined) return null
      try {
        return ObjC.unwrap(value)
      } catch (_) {
        return null
      }
    }

    function run() {
      const framework = $.NSBundle.bundleWithPath(
        "/System/Library/PrivateFrameworks/MediaRemote.framework"
      )
      if (!framework || !framework.load) {
        throw new Error("Unable to load MediaRemote.framework")
      }

      const request = $.NSClassFromString("MRNowPlayingRequest")
      if (!request) {
        throw new Error("MRNowPlayingRequest is unavailable")
      }

      const playerPath = request.localNowPlayingPlayerPath
      const client = playerPath ? playerPath.client : null
      const item = request.localNowPlayingItem
      const info = item ? item.nowPlayingInfo : null

      function infoValue(key) {
        if (!info) return null
        return unwrap(info.objectForKey(key))
      }

      const parentBundleIdentifier = client
        ? unwrap(client.parentApplicationBundleIdentifier)
        : null
      const bundleIdentifier = parentBundleIdentifier ||
        (client ? unwrap(client.bundleIdentifier) : null)

      return JSON.stringify({
        album: infoValue("kMRMediaRemoteNowPlayingInfoAlbum"),
        artist: infoValue("kMRMediaRemoteNowPlayingInfoArtist"),
        bundleIdentifier: bundleIdentifier,
        duration: infoValue("kMRMediaRemoteNowPlayingInfoDuration"),
        elapsedTime: infoValue("kMRMediaRemoteNowPlayingInfoElapsedTime"),
        playing: Boolean(request.localIsPlaying),
        title: infoValue("kMRMediaRemoteNowPlayingInfoTitle")
      })
    }
    """#

  private let pollQueue = DispatchQueue(label: "media-info.jxa.poll", qos: .utility)
  private let executionLock = NSLock()
  private let processLock = NSLock()
  private let stateLock = NSLock()
  private let pollInterval: TimeInterval
  private let requestTimeout: TimeInterval

  private var timer: DispatchSourceTimer?
  private var callback: MediaInfoManager.PlaybackStateChangedCallback?
  private var currentProcess: Process?
  private var isMonitoring = false
  private var hasEmitted = false
  private var lastSnapshotKey: MediaInfoSnapshotKey?

  init(pollInterval: TimeInterval = 1.0, requestTimeout: TimeInterval = 2.0) {
    self.pollInterval = pollInterval
    self.requestTimeout = requestTimeout
  }

  func startMonitoring(callback: @escaping MediaInfoManager.PlaybackStateChangedCallback) {
    stopMonitoring()

    stateLock.lock()
    self.callback = callback
    isMonitoring = true
    hasEmitted = false
    lastSnapshotKey = nil
    stateLock.unlock()

    let timer = DispatchSource.makeTimerSource(queue: pollQueue)
    timer.schedule(deadline: .now(), repeating: pollInterval, leeway: .milliseconds(100))
    timer.setEventHandler { [weak self] in
      self?.poll()
    }
    self.timer = timer
    timer.resume()
  }

  func stopMonitoring() {
    stateLock.lock()
    isMonitoring = false
    callback = nil
    hasEmitted = false
    lastSnapshotKey = nil
    let timer = self.timer
    self.timer = nil
    stateLock.unlock()

    timer?.setEventHandler {}
    timer?.cancel()
    cancelCurrentRequest()
  }

  func fetchMediaInfo() -> MediaInfoFetchResult {
    switch performFetch() {
    case .success(let info):
      return .resolved(info)
    case .failure:
      return .unavailable
    }
  }

  func cancelCurrentRequest() {
    processLock.lock()
    let process = currentProcess
    processLock.unlock()

    guard let process, process.isRunning else { return }
    process.terminate()
  }

  private func poll() {
    stateLock.lock()
    let shouldPoll = isMonitoring
    stateLock.unlock()
    guard shouldPoll else { return }

    // A failed invocation is not equivalent to an authoritative "no media"
    // result. In that case the adaptive provider keeps using media-control.
    guard case .success(let info) = performFetch() else { return }
    emitIfChanged(info)
  }

  private func performFetch() -> Result<MediaInfo?, FetchError> {
    executionLock.lock()
    defer { executionLock.unlock() }

    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
    process.arguments = ["-l", "JavaScript", "-e", Self.script]

    let outputPipe = Pipe()
    let errorPipe = Pipe()
    process.standardOutput = outputPipe
    process.standardError = errorPipe

    let completion = DispatchSemaphore(value: 0)
    process.terminationHandler = { _ in completion.signal() }

    do {
      try process.run()
    } catch {
      return .failure(.launchFailed(error))
    }

    processLock.lock()
    currentProcess = process
    processLock.unlock()

    guard completion.wait(timeout: .now() + requestTimeout) == .success else {
      process.terminate()
      _ = completion.wait(timeout: .now() + 0.5)
      clearCurrentProcess(process)
      return .failure(.timedOut)
    }

    clearCurrentProcess(process)

    let output = outputPipe.fileHandleForReading.readDataToEndOfFile()
    let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
    guard process.terminationStatus == 0 else {
      let message = String(data: errorData, encoding: .utf8) ?? ""
      return .failure(.processFailed(process.terminationStatus, message))
    }

    guard
      let json = try? JSONSerialization.jsonObject(with: output),
      let dictionary = json as? [String: Any]
    else {
      return .failure(.invalidOutput)
    }

    return .success(makeMediaInfo(from: dictionary))
  }

  private func clearCurrentProcess(_ process: Process) {
    processLock.lock()
    if currentProcess === process {
      currentProcess = nil
    }
    processLock.unlock()
  }

  private func makeMediaInfo(from dictionary: [String: Any]) -> MediaInfo? {
    let title = dictionary["title"] as? String
    let artist = dictionary["artist"] as? String
    let album = dictionary["album"] as? String
    let playing = (dictionary["playing"] as? Bool) ?? false
    let bundleIdentifier = dictionary["bundleIdentifier"] as? String

    guard title != nil || playing else { return nil }

    let runningApplication = bundleIdentifier.flatMap {
      NSRunningApplication.runningApplications(withBundleIdentifier: $0).first
    }

    return MediaInfo(
      name: title,
      artist: artist,
      album: album,
      image: nil,
      duration: numberValue(dictionary["duration"]),
      elapsedTime: numberValue(dictionary["elapsedTime"]),
      processID: runningApplication.map { Int($0.processIdentifier) } ?? 0,
      processName: runningApplication?.localizedName ?? "",
      executablePath: runningApplication?.executableURL?.path ?? "",
      playing: playing,
      applicationIdentifier: bundleIdentifier
    )
  }

  private func numberValue(_ value: Any?) -> Double {
    if let number = value as? NSNumber { return number.doubleValue }
    if let string = value as? String, let number = Double(string) { return number }
    return 0
  }

  private func emitIfChanged(_ info: MediaInfo?) {
    let snapshotKey = MediaInfoSnapshotKey(info)

    stateLock.lock()
    guard isMonitoring else {
      stateLock.unlock()
      return
    }
    guard !hasEmitted || lastSnapshotKey != snapshotKey else {
      stateLock.unlock()
      return
    }
    hasEmitted = true
    lastSnapshotKey = snapshotKey
    let callback = self.callback
    stateLock.unlock()

    callback?(info)
  }
}
