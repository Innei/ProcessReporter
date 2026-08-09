// LegacyMediaInfoProvider.swift
// ProcessReporter
// Created by Claude on 2025/7/12.

import AppKit
import Combine
import Foundation

/// MediaRemote provider for macOS releases before 15.4. Private framework
/// callbacks are collected off the main thread and bounded by the caller's
/// timeout; notification subscriptions are recreated after every restart.
final class LegacyMediaInfoProvider: MediaInfoProvider, @unchecked Sendable {
  private typealias GetNowPlayingInfoFunction =
    @convention(c) (
      DispatchQueue, @escaping (NSDictionary?) -> Void
    ) -> Void
  private typealias GetIsPlayingFunction =
    @convention(c) (
      DispatchQueue, @escaping (Bool) -> Void
    ) -> Void
  private typealias GetApplicationPIDFunction =
    @convention(c) (
      DispatchQueue, @escaping (Int32) -> Void
    ) -> Void

  private static let playingStateChangedNotificationName =
    "kMRMediaRemoteNowPlayingApplicationIsPlayingDidChangeNotification"
  private static let applicationChangedNotificationName =
    "kMRMediaRemoteNowPlayingApplicationDidChangeNotification"
  private static let infoChangedNotificationName =
    "kMRMediaRemoteNowPlayingInfoDidChangeNotification"
  private static let frameworkURL = URL(
    fileURLWithPath: "/System/Library/PrivateFrameworks/MediaRemote.framework"
  )

  private let stateLock = NSLock()
  private let fetchGate = DispatchSemaphore(value: 1)
  private let callbackQueue = DispatchQueue(label: "media-info.legacy.callback", qos: .utility)
  private var cancellables = Set<AnyCancellable>()
  private var callback: MediaInfoProviderCallback?
  private var monitoringGeneration: UInt64 = 0
  private var lastSnapshotKey: MediaInfoSnapshotKey?
  private var hasEmitted = false
  private var notificationFetchPending = false
  private var notificationFetchRequested = false

  func startMonitoring(callback: @escaping MediaInfoProviderCallback) {
    stopMonitoring()
    guard Self.loadFramework() != nil else { return }

    stateLock.lock()
    monitoringGeneration &+= 1
    let generation = monitoringGeneration
    self.callback = callback
    lastSnapshotKey = nil
    hasEmitted = false
    notificationFetchPending = false
    notificationFetchRequested = false
    stateLock.unlock()

    var subscriptions = Set<AnyCancellable>()
    for name in [
      Self.playingStateChangedNotificationName,
      Self.applicationChangedNotificationName,
      Self.infoChangedNotificationName,
    ] {
      NotificationCenter.default.publisher(for: Notification.Name(name))
        .sink { [weak self] _ in
          self?.handleNotification(generation: generation)
        }
        .store(in: &subscriptions)
    }

    stateLock.lock()
    if generation == monitoringGeneration, self.callback != nil {
      cancellables = subscriptions
    }
    stateLock.unlock()
  }

  func stopMonitoring() {
    stateLock.lock()
    monitoringGeneration &+= 1
    callback = nil
    lastSnapshotKey = nil
    hasEmitted = false
    notificationFetchPending = false
    notificationFetchRequested = false
    let subscriptions = cancellables
    cancellables.removeAll()
    stateLock.unlock()

    for subscription in subscriptions {
      subscription.cancel()
    }
  }

  func fetchMediaInfo(timeout: TimeInterval) -> MediaInfoFetchResult {
    let startedAt = ProcessInfo.processInfo.systemUptime
    guard timeout > 0, fetchGate.wait(timeout: .now() + timeout) == .success else {
      return .unavailable
    }
    defer { fetchGate.signal() }

    let remaining = timeout - (ProcessInfo.processInfo.systemUptime - startedAt)
    guard remaining > 0 else { return .unavailable }
    return fetchFromFramework(timeout: remaining)
  }

  private func handleNotification(generation: UInt64) {
    stateLock.lock()
    guard generation == monitoringGeneration, callback != nil else {
      stateLock.unlock()
      return
    }
    if notificationFetchPending {
      notificationFetchRequested = true
      stateLock.unlock()
      return
    }
    notificationFetchPending = true
    stateLock.unlock()

    callbackQueue.async { [weak self] in
      guard let self else { return }
      let result = fetchMediaInfo(timeout: 2)

      stateLock.lock()
      var shouldFetchAgain = false
      if generation == monitoringGeneration {
        notificationFetchPending = false
        shouldFetchAgain = notificationFetchRequested
        notificationFetchRequested = false
      }
      stateLock.unlock()

      if case .resolved(let info) = result {
        emitIfChanged(info, generation: generation)
      }
      if shouldFetchAgain {
        handleNotification(generation: generation)
      }
    }
  }

  private func fetchFromFramework(timeout: TimeInterval) -> MediaInfoFetchResult {
    guard
      let bundle = Self.loadFramework(),
      let getInfoPointer = CFBundleGetFunctionPointerForName(
        bundle,
        "MRMediaRemoteGetNowPlayingInfo" as CFString
      ),
      let getPlayingPointer = CFBundleGetFunctionPointerForName(
        bundle,
        "MRMediaRemoteGetNowPlayingApplicationIsPlaying" as CFString
      ),
      let getPIDPointer = CFBundleGetFunctionPointerForName(
        bundle,
        "MRMediaRemoteGetNowPlayingApplicationPID" as CFString
      )
    else { return .unavailable }

    let getInfo = unsafeBitCast(getInfoPointer, to: GetNowPlayingInfoFunction.self)
    let getPlaying = unsafeBitCast(getPlayingPointer, to: GetIsPlayingFunction.self)
    let getPID = unsafeBitCast(getPIDPointer, to: GetApplicationPIDFunction.self)

    let state = LegacyFetchState()
    let group = DispatchGroup()
    let queue = DispatchQueue.global(qos: .utility)

    group.enter()
    getInfo(queue) { information in
      state.setInformation(information)
      group.leave()
    }

    group.enter()
    getPlaying(queue) { playing in
      state.setPlaying(playing)
      group.leave()
    }

    group.enter()
    getPID(queue) { processID in
      state.setProcessID(processID)
      group.leave()
    }

    guard group.wait(timeout: .now() + timeout) == .success else {
      return .unavailable
    }

    let snapshot = state.snapshot()
    guard snapshot.didReceiveInformation else { return .unavailable }
    guard let information = snapshot.information else { return .resolved(nil) }
    return .resolved(
      makeMediaInfo(
        from: information,
        playing: snapshot.playing,
        processID: snapshot.processID
      )
    )
  }

  private static func loadFramework() -> CFBundle? {
    guard let bundle = CFBundleCreate(kCFAllocatorDefault, frameworkURL as CFURL) else {
      return nil
    }
    guard CFBundleLoadExecutable(bundle) else { return nil }
    return bundle
  }

  private func makeMediaInfo(
    from information: NSDictionary,
    playing: Bool,
    processID: Int32
  ) -> MediaInfo? {
    let title = nonEmptyString(information["kMRMediaRemoteNowPlayingInfoTitle"])
    guard title != nil || playing else { return nil }

    let normalizedProcessID = max(0, processID)
    let application =
      normalizedProcessID > 0
      ? NSRunningApplication(processIdentifier: normalizedProcessID)
      : nil
    let artwork = (information["kMRMediaRemoteNowPlayingInfoArtworkData"] as? Data)?
      .base64EncodedString()

    return MediaInfo(
      name: title,
      artist: nonEmptyString(information["kMRMediaRemoteNowPlayingInfoArtist"]),
      album: nonEmptyString(information["kMRMediaRemoteNowPlayingInfoAlbum"]),
      image: artwork,
      duration: numberValue(information["kMRMediaRemoteNowPlayingInfoDuration"]),
      elapsedTime: numberValue(information["kMRMediaRemoteNowPlayingInfoElapsedTime"]),
      processID: Int(normalizedProcessID),
      processName: application?.localizedName ?? "",
      executablePath: application?.executableURL?.path ?? "",
      playing: playing,
      applicationIdentifier: application?.bundleIdentifier
    )
  }

  private func emitIfChanged(_ info: MediaInfo?, generation: UInt64) {
    let key = MediaInfoSnapshotKey(info)

    stateLock.lock()
    guard generation == monitoringGeneration, let callback else {
      stateLock.unlock()
      return
    }
    guard !hasEmitted || lastSnapshotKey != key else {
      stateLock.unlock()
      return
    }
    hasEmitted = true
    lastSnapshotKey = key
    stateLock.unlock()

    callback(info)
  }

  private func nonEmptyString(_ value: Any?) -> String? {
    guard let value = value as? String, !value.isEmpty else { return nil }
    return value
  }

  private func numberValue(_ value: Any?) -> Double? {
    guard
      let number = (value as? NSNumber)?.doubleValue,
      number.isFinite,
      number >= 0
    else { return nil }
    return number
  }
}

private final class LegacyFetchState: @unchecked Sendable {
  struct Snapshot {
    let didReceiveInformation: Bool
    let information: NSDictionary?
    let playing: Bool
    let processID: Int32
  }

  private let lock = NSLock()
  private var didReceiveInformation = false
  private var information: NSDictionary?
  private var playing = false
  private var processID: Int32 = 0

  func setInformation(_ information: NSDictionary?) {
    lock.lock()
    didReceiveInformation = true
    self.information = information
    lock.unlock()
  }

  func setPlaying(_ playing: Bool) {
    lock.lock()
    self.playing = playing
    lock.unlock()
  }

  func setProcessID(_ processID: Int32) {
    lock.lock()
    self.processID = processID
    lock.unlock()
  }

  func snapshot() -> Snapshot {
    lock.lock()
    defer { lock.unlock() }
    return Snapshot(
      didReceiveInformation: didReceiveInformation,
      information: information,
      playing: playing,
      processID: processID
    )
  }
}
