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
      // Restart with existing callback
      provider.startMonitoring(callback: callback)
    }
  }

  public static func getMediaInfo() -> MediaInfo? {
    return provider.getMediaInfo()
  }

}
