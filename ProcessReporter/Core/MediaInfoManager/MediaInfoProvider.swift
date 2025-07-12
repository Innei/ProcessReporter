// MediaInfoProvider.swift
// ProcessReporter
// Created by Claude on 2025/7/12.

import Foundation

/// Protocol for providing media information from different sources
protocol MediaInfoProvider {
  /// Start monitoring playback changes
  func startMonitoring(callback: @escaping MediaInfoManager.PlaybackStateChangedCallback)
  
  /// Stop monitoring playback changes
  func stopMonitoring()
  
  /// Get current media information
  func getMediaInfo() -> MediaInfo?
}