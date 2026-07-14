// AdaptiveMediaInfoProvider.swift
// ProcessReporter

import Foundation

/// Combines a best-effort enrichment provider with a state-authoritative
/// provider. A successful authoritative `nil` clears stale CLI state, while an
/// unavailable authoritative provider leaves the enrichment source in charge.
final class AdaptiveMediaInfoProvider: MediaInfoProvider {
  private enum ProviderState {
    case unknown
    case known(MediaInfo?)
  }

  private let enrichmentProvider: MediaInfoProvider
  private let authoritativeProvider: MediaInfoProvider
  private let stateQueue = DispatchQueue(label: "media-info.adaptive.state")

  private var enrichmentState = ProviderState.unknown
  private var authoritativeState = ProviderState.unknown
  private var callback: MediaInfoManager.PlaybackStateChangedCallback?
  private var hasEmitted = false
  private var lastSnapshotKey: String?

  init(
    enrichmentProvider: MediaInfoProvider,
    authoritativeProvider: MediaInfoProvider
  ) {
    self.enrichmentProvider = enrichmentProvider
    self.authoritativeProvider = authoritativeProvider
  }

  func startMonitoring(callback: @escaping MediaInfoManager.PlaybackStateChangedCallback) {
    stopMonitoring()

    stateQueue.sync {
      self.callback = callback
      enrichmentState = .unknown
      authoritativeState = .unknown
      hasEmitted = false
      lastSnapshotKey = nil
    }

    enrichmentProvider.startMonitoring { [weak self] info in
      self?.receive(info, fromAuthoritativeProvider: false)
    }
    authoritativeProvider.startMonitoring { [weak self] info in
      self?.receive(info, fromAuthoritativeProvider: true)
    }
  }

  func stopMonitoring() {
    enrichmentProvider.stopMonitoring()
    authoritativeProvider.stopMonitoring()
    stateQueue.sync {
      callback = nil
      enrichmentState = .unknown
      authoritativeState = .unknown
      hasEmitted = false
      lastSnapshotKey = nil
    }
  }

  func getMediaInfo() -> MediaInfo? {
    if let authoritativeInfo = authoritativeProvider.getMediaInfo() {
      guard let enrichmentInfo = enrichmentProvider.getMediaInfo() else {
        return authoritativeInfo
      }
      return Self.merge(authoritative: authoritativeInfo, enrichment: enrichmentInfo)
    }
    return enrichmentProvider.getMediaInfo()
  }

  func cancelCurrentRequest() {
    enrichmentProvider.cancelCurrentRequest()
    authoritativeProvider.cancelCurrentRequest()
  }

  private func receive(_ info: MediaInfo?, fromAuthoritativeProvider: Bool) {
    stateQueue.async { [weak self] in
      guard let self else { return }

      if fromAuthoritativeProvider {
        authoritativeState = .known(info)
      } else {
        enrichmentState = .known(info)
      }

      guard let resolved = resolveState() else { return }
      let snapshotKey = Self.snapshotKey(for: resolved)
      guard !hasEmitted || lastSnapshotKey != snapshotKey else { return }

      hasEmitted = true
      lastSnapshotKey = snapshotKey
      callback?(resolved)
    }
  }

  /// The outer optional distinguishes "no resolved state yet" from a resolved
  /// and authoritative "no media" state.
  private func resolveState() -> MediaInfo?? {
    switch authoritativeState {
    case .known(nil):
      return .some(nil)
    case .known(let authoritativeInfo?):
      if case .known(let enrichmentInfo?) = enrichmentState {
        return .some(Self.merge(authoritative: authoritativeInfo, enrichment: enrichmentInfo))
      }
      return .some(authoritativeInfo)
    case .unknown:
      if case .known(let enrichmentInfo) = enrichmentState {
        return .some(enrichmentInfo)
      }
      return nil
    }
  }

  private static func merge(authoritative: MediaInfo, enrichment: MediaInfo) -> MediaInfo {
    guard representsSameItem(authoritative, enrichment) else { return authoritative }

    let useEnrichmentProcess = enrichment.processID != 0
    return MediaInfo(
      name: authoritative.name ?? enrichment.name,
      artist: authoritative.artist ?? enrichment.artist,
      album: authoritative.album ?? enrichment.album,
      image: enrichment.image ?? authoritative.image,
      duration: authoritative.duration > 0 ? authoritative.duration : enrichment.duration,
      elapsedTime: authoritative.elapsedTime > 0
        ? authoritative.elapsedTime : enrichment.elapsedTime,
      processID: useEnrichmentProcess ? enrichment.processID : authoritative.processID,
      processName: useEnrichmentProcess ? enrichment.processName : authoritative.processName,
      executablePath: useEnrichmentProcess
        ? enrichment.executablePath : authoritative.executablePath,
      playing: authoritative.playing,
      applicationIdentifier: authoritative.applicationIdentifier
        ?? enrichment.applicationIdentifier
    )
  }

  private static func representsSameItem(_ lhs: MediaInfo, _ rhs: MediaInfo) -> Bool {
    let matchingApplication =
      lhs.applicationIdentifier == nil
      || rhs.applicationIdentifier == nil
      || lhs.applicationIdentifier == rhs.applicationIdentifier
    return matchingApplication && lhs.name == rhs.name && lhs.artist == rhs.artist
  }

  private static func snapshotKey(for info: MediaInfo?) -> String {
    guard let info else { return "<no-media>" }
    return [
      info.name ?? "",
      info.artist ?? "",
      info.album ?? "",
      info.playing.description,
      info.applicationIdentifier ?? "",
    ].joined(separator: "|")
  }
}
