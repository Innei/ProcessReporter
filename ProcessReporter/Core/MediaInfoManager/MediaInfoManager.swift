// MediaInfoManager.swift
// ProcessReporter
// Created by Innei on 2025/4/11.

import AppKit
import Combine
import Foundation

public class MediaInfoManager: NSObject {
  // Callback for when playback state changes
  public typealias PlaybackStateChangedCallback = (MediaInfo) -> Void

  // Media info provider based on macOS version
  private static var provider: MediaInfoProvider = {
    if #available(macOS 15.4, *) {
      return CLIMediaInfoProvider()
    } else {
      return LegacyMediaInfoProvider()
    }
  }()

  // Cache the latest media info to avoid synchronous CLI calls on the main thread
  private static var latestInfo: MediaInfo?

  // Store the callback
  private static var playbackStateChangedCallback: PlaybackStateChangedCallback?
  private static var playbackDebounceCancellable: AnyCancellable?
  private static let playbackSubject = PassthroughSubject<MediaInfo, Never>()

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

    // Reset failure counters if provider supports it
    if let cliProvider = provider as? CLIMediaInfoProvider {
      cliProvider.resetFailureCounter()
    }

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
    // Avoid blocking the main thread with synchronous CLI calls
    if Thread.isMainThread, provider is CLIMediaInfoProvider {
      return latestInfo
    }
    let info = provider.getMediaInfo()
    if let info = info {
      latestInfo = info
    }
    return info
  }

  // Async API backed by the serializing actor with timeout and coalescing
  public static func getMediaInfoAsync(timeout seconds: TimeInterval = 3.0) async throws
    -> MediaInfo?
  {
    let info = try await MediaInfoFetchActor.shared.requestInfo(using: provider, timeout: seconds)
    if let info = info {
      latestInfo = info
    }
    return info
  }

}

// MARK: - Concurrency-based Media Info Actor

/// Actor that serializes external media info requests, with coalescing,
/// shared in-flight task, timeout and cancellation support.
actor MediaInfoFetchActor {
  static let shared = MediaInfoFetchActor()

  private var inFlightTask: Task<MediaInfo?, Error>?
  private var lastRequestStart: Date?
  private var lastCompletedResult: MediaInfo?
  private let coalesceInterval: TimeInterval = 0.2

  enum ErrorType: Swift.Error { case timeout }

  /// Request media info via the given provider, ensuring:
  /// - Serial execution
  /// - Coalescing within 200ms
  /// - Returning the same in-flight Task when already running
  /// - Timeout with external process interruption (for CLI provider)
  func requestInfo(using provider: MediaInfoProvider, timeout seconds: TimeInterval = 3.0)
    async throws -> MediaInfo?
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

    let task = Task<MediaInfo?, Error> {
      // Run provider.getMediaInfo() concurrently with a timeout task
      try await withThrowingTaskGroup(of: MediaInfo?.self) { group in
        group.addTask {
          // Run on a background thread, not on the actor
          return provider.getMediaInfo()
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
          // On timeout/cancellation, try interrupting the CLI process if applicable
          if let cli = provider as? CLIMediaInfoProvider {
            cli.interruptCurrentExecProcess()
          }
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
