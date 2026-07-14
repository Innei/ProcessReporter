// MediaInfoProvider.swift
// ProcessReporter
// Created by Claude on 2025/7/12.

import Foundation

/// Distinguishes a successful media lookup, including an authoritative
/// no-media state, from a provider that could not answer the request.
enum MediaInfoFetchResult {
  case resolved(MediaInfo?)
  case unavailable
}

/// Stable state used to suppress duplicate callbacks without discarding
/// enrichment-only changes such as artwork or process metadata.
enum MediaInfoSnapshotKey: Equatable {
  case noMedia
  case media(
    name: String?,
    artist: String?,
    album: String?,
    imageHash: Int?,
    duration: Double,
    processID: Int,
    processName: String,
    executablePath: String,
    playing: Bool,
    applicationIdentifier: String?
  )

  init(_ info: MediaInfo?) {
    guard let info else {
      self = .noMedia
      return
    }

    self = .media(
      name: info.name,
      artist: info.artist,
      album: info.album,
      imageHash: info.image?.hashValue,
      duration: info.duration,
      processID: info.processID,
      processName: info.processName,
      executablePath: info.executablePath,
      playing: info.playing,
      applicationIdentifier: info.applicationIdentifier
    )
  }
}

/// Protocol for providing media information from different sources
protocol MediaInfoProvider {
  /// Start monitoring playback changes
  func startMonitoring(callback: @escaping MediaInfoManager.PlaybackStateChangedCallback)

  /// Stop monitoring playback changes
  func stopMonitoring()

  /// Resolve current media information without conflating no media with a
  /// temporary provider failure.
  func fetchMediaInfo() -> MediaInfoFetchResult

  /// Cancel a currently running synchronous request, if supported.
  func cancelCurrentRequest()
}

extension MediaInfoProvider {
  func cancelCurrentRequest() {}
}
