// MediaInfoManager.swift
// ProcessReporter
// Created by Innei on 2025/4/11.

import AppKit
import Combine
import Foundation

public class MediaInfoManager: NSObject {
  // Callback for when playback state changes
  public typealias PlaybackStateChangedCallback = (MediaInfo?) -> Void

  // Use JXA as the state authority on modern macOS. media-control remains an
  // optional enrichment source when it is installed.
  private static var provider: MediaInfoProvider = {
    if #available(macOS 15.4, *) {
      let jxaProvider = JXAMediaInfoProvider()
      guard CLIMediaInfoProvider.isMediaControlInstalled() else {
        return jxaProvider
      }
      return AdaptiveMediaInfoProvider(
        enrichmentProvider: CLIMediaInfoProvider(),
        authoritativeProvider: jxaProvider
      )
    } else {
      return LegacyMediaInfoProvider()
    }
  }()

  // Cache the latest media info to avoid synchronous CLI calls on the main thread
  private static var latestInfo: MediaInfo?

  // Store the callback
  private static var playbackStateChangedCallback: PlaybackStateChangedCallback?
  private static var playbackDebounceCancellable: AnyCancellable?
  private static let playbackSubject = PassthroughSubject<MediaInfo?, Never>()

  // Setup the notification observer
  public static func startMonitoringPlaybackChanges(
    callback: @escaping PlaybackStateChangedCallback
  ) {
    playbackStateChangedCallback = callback

    // Debounce rapid notifications
    playbackDebounceCancellable?.cancel()
    playbackDebounceCancellable =
      playbackSubject
      .debounce(for: .milliseconds(150), scheduler: RunLoop.main)
      .sink { info in
        latestInfo = info
        callback(info)
      }

    provider.startMonitoring { info in
      playbackSubject.send(info)
    }
  }

  // Stop monitoring playback changes
  public static func stopMonitoringPlaybackChanges() {
    provider.stopMonitoring()
    playbackStateChangedCallback = nil
  }

  // Check if there's an active callback
  public static func hasActiveCallback() -> Bool {
    return playbackStateChangedCallback != nil
  }

  // Restart monitoring with the existing callback (useful after system wake)
  public static func restartMonitoring() {
    guard let callback = playbackStateChangedCallback else {
      return
    }

    // Stop current monitoring
    provider.stopMonitoring()

    // Small delay to ensure clean restart
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
      // Recreate debounced sink and restart provider
      playbackDebounceCancellable?.cancel()
      playbackDebounceCancellable =
        playbackSubject
        .debounce(for: .milliseconds(150), scheduler: RunLoop.main)
        .sink { info in
          latestInfo = info
          callback(info)
        }
      provider.startMonitoring { info in
        playbackSubject.send(info)
      }
    }
  }

  public static func getMediaInfo() -> MediaInfo? {
    // All modern providers may spawn an external process. Never block the UI.
    if Thread.isMainThread {
      return latestInfo
    }
    return resolve(provider.fetchMediaInfo())
  }

  // Async API backed by the serializing actor with timeout and coalescing
  public static func getMediaInfoAsync(timeout seconds: TimeInterval = 3.0) async throws
    -> MediaInfo?
  {
    let result = try await MediaInfoFetchActor.shared.requestInfo(using: provider, timeout: seconds)
    return resolve(result)
  }

  private static func resolve(_ result: MediaInfoFetchResult) -> MediaInfo? {
    switch result {
    case .resolved(let info):
      latestInfo = info
      return info
    case .unavailable:
      return latestInfo
    }
  }
}

// MARK: - Concurrency-based Media Info Actor

/// Actor that serializes external media info requests, with coalescing,
/// shared in-flight task, timeout and cancellation support.
actor MediaInfoFetchActor {
  static let shared = MediaInfoFetchActor()

  private var inFlightTask: Task<MediaInfoFetchResult, Error>?
  private var lastRequestStart: Date?
  private var lastCompletedResult: MediaInfoFetchResult?
  private let coalesceInterval: TimeInterval = 0.2

  enum ErrorType: Swift.Error { case timeout }

  /// Request media info via the given provider, ensuring:
  /// - Serial execution
  /// - Coalescing within 200ms
  /// - Returning the same in-flight Task when already running
  /// - Timeout with external process interruption (for CLI provider)
  func requestInfo(using provider: MediaInfoProvider, timeout seconds: TimeInterval = 3.0)
    async throws -> MediaInfoFetchResult
  {
    if let task = inFlightTask {
      return try await task.value
    }

    let now = Date()
    if let last = lastRequestStart {
      let delta = now.timeIntervalSince(last)
      if delta < coalesceInterval, let cached = lastCompletedResult {
        return cached
      }
      if delta < coalesceInterval {
        let remaining = coalesceInterval - delta
        let ns = UInt64(max(0, remaining) * 1_000_000_000)
        try? await Task.sleep(nanoseconds: ns)
      }
    }

    lastRequestStart = Date()

    let task = Task<MediaInfoFetchResult, Error> {
      // Run provider.fetchMediaInfo() concurrently with a timeout task
      try await withThrowingTaskGroup(of: MediaInfoFetchResult.self) { group in
        group.addTask {
          // Run on a background thread, not on the actor
          return provider.fetchMediaInfo()
        }
        group.addTask {
          try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
          throw ErrorType.timeout
        }

        do {
          let result = try await group.next()!
          group.cancelAll()
          return result
        } catch {
          group.cancelAll()
          provider.cancelCurrentRequest()
          throw error
        }
      }
    }

    inFlightTask = task
    defer {
      inFlightTask = nil
      lastRequestStart = Date()
    }
    let result = try await task.value
    lastCompletedResult = result
    return result
  }
}
