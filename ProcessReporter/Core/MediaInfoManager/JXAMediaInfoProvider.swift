// JXAMediaInfoProvider.swift
// ProcessReporter

import AppKit
import Foundation

/// Reads the system Now Playing state through an Apple-signed `osascript`
/// process. The queried MediaRemote classes are private API, but this path does
/// not require the private mediaremoted client entitlement introduced in 15.4.
final class JXAMediaInfoProvider: MediaInfoProvider, @unchecked Sendable {
  private enum FetchError: Error {
    case launchFailed
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
  private let executionGate = DispatchSemaphore(value: 1)
  private let stateLock = NSLock()
  private let pollInterval: TimeInterval
  private let requestTimeout: TimeInterval

  private var timer: DispatchSourceTimer?
  private var callback: MediaInfoProviderCallback?
  private var monitoringGeneration: UInt64 = 0
  private var isMonitoring = false
  private var hasEmitted = false
  private var lastSnapshotKey: MediaInfoSnapshotKey?

  init(pollInterval: TimeInterval = 1, requestTimeout: TimeInterval = 2) {
    self.pollInterval = max(0.1, pollInterval)
    self.requestTimeout = max(0.1, requestTimeout)
  }

  func startMonitoring(callback: @escaping MediaInfoProviderCallback) {
    stopMonitoring()

    let timer = DispatchSource.makeTimerSource(queue: pollQueue)

    stateLock.lock()
    monitoringGeneration &+= 1
    let generation = monitoringGeneration
    self.callback = callback
    isMonitoring = true
    hasEmitted = false
    lastSnapshotKey = nil
    self.timer = timer
    timer.setEventHandler { [weak self] in
      self?.poll(generation: generation)
    }
    timer.schedule(deadline: .now(), repeating: pollInterval, leeway: .milliseconds(100))
    timer.resume()
    stateLock.unlock()
  }

  func stopMonitoring() {
    stateLock.lock()
    monitoringGeneration &+= 1
    isMonitoring = false
    callback = nil
    hasEmitted = false
    lastSnapshotKey = nil
    let timer = self.timer
    self.timer = nil
    stateLock.unlock()

    timer?.setEventHandler {}
    timer?.cancel()
  }

  func fetchMediaInfo(timeout: TimeInterval) -> MediaInfoFetchResult {
    let boundedTimeout = min(requestTimeout, timeout)
    guard boundedTimeout > 0 else { return .unavailable }

    switch performFetch(timeout: boundedTimeout) {
    case .success(let info):
      return .resolved(info)
    case .failure:
      return .unavailable
    }
  }

  private func poll(generation: UInt64) {
    stateLock.lock()
    let shouldPoll = isMonitoring && generation == monitoringGeneration
    stateLock.unlock()
    guard shouldPoll else { return }

    guard case .success(let info) = performFetch(timeout: requestTimeout) else { return }
    emitIfChanged(info, generation: generation)
  }

  private func performFetch(timeout: TimeInterval) -> Result<MediaInfo?, FetchError> {
    let startedAt = ProcessInfo.processInfo.systemUptime
    guard executionGate.wait(timeout: .now() + timeout) == .success else {
      return .failure(.timedOut)
    }
    defer { executionGate.signal() }

    let elapsed = ProcessInfo.processInfo.systemUptime - startedAt
    let remaining = timeout - elapsed
    guard remaining > 0 else { return .failure(.timedOut) }

    switch ExternalProcessRunner.run(
      executableURL: URL(fileURLWithPath: "/usr/bin/osascript"),
      arguments: ["-l", "JavaScript", "-e", Self.script],
      timeout: remaining
    ) {
    case .launchFailed:
      return .failure(.launchFailed)
    case .timedOut:
      return .failure(.timedOut)
    case .completed(let status, let output, let errorData):
      guard status == 0 else {
        let message = String(data: errorData, encoding: .utf8) ?? ""
        return .failure(.processFailed(status, message))
      }

      guard
        let json = try? JSONSerialization.jsonObject(with: output),
        let dictionary = json as? [String: Any]
      else {
        return .failure(.invalidOutput)
      }

      return .success(makeMediaInfo(from: dictionary))
    }
  }

  private func makeMediaInfo(from dictionary: [String: Any]) -> MediaInfo? {
    let title = nonEmptyString(dictionary["title"])
    let artist = nonEmptyString(dictionary["artist"])
    let album = nonEmptyString(dictionary["album"])
    let playing = (dictionary["playing"] as? Bool) ?? false
    let bundleIdentifier = nonEmptyString(dictionary["bundleIdentifier"])

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

  private func nonEmptyString(_ value: Any?) -> String? {
    guard let string = value as? String, !string.isEmpty else { return nil }
    return string
  }

  private func numberValue(_ value: Any?) -> Double? {
    let number: Double?
    if let value = value as? NSNumber {
      number = value.doubleValue
    } else if let value = value as? String {
      number = Double(value)
    } else {
      number = nil
    }

    guard let number, number.isFinite, number >= 0 else { return nil }
    return number
  }

  private func emitIfChanged(_ info: MediaInfo?, generation: UInt64) {
    let snapshotKey = MediaInfoSnapshotKey(info)

    stateLock.lock()
    guard isMonitoring, generation == monitoringGeneration else {
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
