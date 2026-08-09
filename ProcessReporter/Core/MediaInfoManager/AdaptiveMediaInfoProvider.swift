// AdaptiveMediaInfoProvider.swift
// ProcessReporter

import Foundation

/// Combines a best-effort enrichment provider with a state-authoritative
/// provider. A successful authoritative `nil` clears stale CLI state, while an
/// unavailable authoritative provider leaves the enrichment source in charge.
final class AdaptiveMediaInfoProvider: MediaInfoProvider, @unchecked Sendable {
  private enum ProviderState {
    case unknown
    case known(MediaInfo?)
  }

  private let enrichmentProvider: MediaInfoProvider
  private let authoritativeProvider: MediaInfoProvider
  private let stateQueue = DispatchQueue(label: "media-info.adaptive.state")
  private let callbackQueue = DispatchQueue(label: "media-info.adaptive.callback")
  private let callbackQueueKey = DispatchSpecificKey<Void>()

  private var enrichmentState = ProviderState.unknown
  private var authoritativeState = ProviderState.unknown
  private var callback: MediaInfoProviderCallback?
  private var hasEmitted = false
  private var lastSnapshotKey: MediaInfoSnapshotKey?
  private var monitoringGeneration: UInt64 = 0

  init(
    enrichmentProvider: MediaInfoProvider,
    authoritativeProvider: MediaInfoProvider
  ) {
    self.enrichmentProvider = enrichmentProvider
    self.authoritativeProvider = authoritativeProvider
    callbackQueue.setSpecific(key: callbackQueueKey, value: ())
  }

  func startMonitoring(callback: @escaping MediaInfoProviderCallback) {
    stopMonitoring()

    let generation = stateQueue.sync {
      monitoringGeneration &+= 1
      self.callback = callback
      enrichmentState = .unknown
      authoritativeState = .unknown
      hasEmitted = false
      lastSnapshotKey = nil
      return monitoringGeneration
    }

    enrichmentProvider.startMonitoring { [weak self] info in
      self?.receive(info, fromAuthoritativeProvider: false, generation: generation)
    }
    authoritativeProvider.startMonitoring { [weak self] info in
      self?.receive(info, fromAuthoritativeProvider: true, generation: generation)
    }
  }

  func stopMonitoring() {
    stateQueue.sync {
      monitoringGeneration &+= 1
      callback = nil
      enrichmentState = .unknown
      authoritativeState = .unknown
      hasEmitted = false
      lastSnapshotKey = nil
    }
    enrichmentProvider.stopMonitoring()
    authoritativeProvider.stopMonitoring()

    // Do not let a callback already queued by the previous monitoring session
    // escape after stopMonitoring() returns.
    if DispatchQueue.getSpecific(key: callbackQueueKey) == nil {
      callbackQueue.sync {}
    }
  }

  func fetchMediaInfo(timeout: TimeInterval) -> MediaInfoFetchResult {
    guard timeout > 0 else { return .unavailable }
    let startedAt = ProcessInfo.processInfo.systemUptime

    func remainingTime() -> TimeInterval {
      max(0, timeout - (ProcessInfo.processInfo.systemUptime - startedAt))
    }

    switch authoritativeProvider.fetchMediaInfo(timeout: remainingTime()) {
    case .resolved(nil):
      return .resolved(nil)
    case .resolved(let authoritativeInfo?):
      let remaining = remainingTime()
      guard
        remaining > 0,
        case .resolved(let enrichmentInfo?) = enrichmentProvider.fetchMediaInfo(timeout: remaining)
      else {
        return .resolved(authoritativeInfo)
      }
      return .resolved(Self.merge(authoritative: authoritativeInfo, enrichment: enrichmentInfo))
    case .unavailable:
      let remaining = remainingTime()
      guard remaining > 0 else { return .unavailable }
      return enrichmentProvider.fetchMediaInfo(timeout: remaining)
    }
  }

  private func receive(
    _ info: MediaInfo?,
    fromAuthoritativeProvider: Bool,
    generation: UInt64
  ) {
    stateQueue.async { [weak self] in
      guard let self else { return }
      guard generation == monitoringGeneration, callback != nil else { return }

      if fromAuthoritativeProvider {
        authoritativeState = .known(info)
      } else {
        enrichmentState = .known(info)
      }

      guard let resolved = resolveState() else { return }
      let snapshotKey = MediaInfoSnapshotKey(resolved)
      guard !hasEmitted || lastSnapshotKey != snapshotKey else { return }

      hasEmitted = true
      lastSnapshotKey = snapshotKey
      let callback = callback
      callbackQueue.async { [weak self] in
        guard let self else { return }
        let isCurrent = stateQueue.sync {
          generation == self.monitoringGeneration && self.callback != nil
        }
        guard isCurrent else { return }
        callback?(resolved)
      }
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
      duration: authoritative.duration ?? enrichment.duration,
      elapsedTime: authoritative.elapsedTime ?? enrichment.elapsedTime,
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

}
