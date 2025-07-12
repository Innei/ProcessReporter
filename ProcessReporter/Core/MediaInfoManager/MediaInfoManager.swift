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

  // Store the callback
  private static var playbackStateChangedCallback: PlaybackStateChangedCallback?

  // Setup the notification observer
  public static func startMonitoringPlaybackChanges(
    callback: @escaping PlaybackStateChangedCallback
  ) {
    playbackStateChangedCallback = callback
    provider.startMonitoring(callback: callback)
  }

  // Stop monitoring playback changes
  public static func stopMonitoringPlaybackChanges() {
    provider.stopMonitoring()
    playbackStateChangedCallback = nil
  }

  public static func getMediaInfo() -> MediaInfo? {
    return provider.getMediaInfo()
  }

}
