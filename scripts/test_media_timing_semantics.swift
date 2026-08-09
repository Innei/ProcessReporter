import Foundation

private enum HarnessFailure: Error, CustomStringConvertible {
  case expectation(String)

  var description: String {
    switch self {
    case .expectation(let message):
      return message
    }
  }
}

private final class StubMediaInfoProvider: MediaInfoProvider, @unchecked Sendable {
  private let result: MediaInfoFetchResult

  init(result: MediaInfoFetchResult) {
    self.result = result
  }

  func startMonitoring(callback: @escaping MediaInfoProviderCallback) {}
  func stopMonitoring() {}

  func fetchMediaInfo(timeout: TimeInterval) -> MediaInfoFetchResult {
    result
  }
}

@main
private struct MediaTimingSemanticsHarness {
  static func main() throws {
    let missing = media(duration: nil, elapsedTime: nil)
    try expect(missing.duration == nil, "missing duration was converted to a value")
    try expect(missing.elapsedTime == nil, "missing position was converted to a value")

    let zero = media(duration: 0, elapsedTime: 0)
    try expect(zero.duration == 0, "real zero duration was not preserved")
    try expect(zero.elapsedTime == 0, "real zero position was not preserved")

    let invalidNegative = media(duration: -1, elapsedTime: -1)
    try expect(invalidNegative.duration == nil, "negative duration became a real zero")
    try expect(invalidNegative.elapsedTime == nil, "negative position became a real zero")
    try expect(
      MediaInfoSnapshotKey(missing) != MediaInfoSnapshotKey(zero),
      "snapshot identity conflated missing duration with zero"
    )
    try expect(
      MediaInfoSnapshotKey(media(duration: 120, elapsedTime: nil))
        != MediaInfoSnapshotKey(media(duration: 120, elapsedTime: 0)),
      "snapshot identity conflated missing position with zero"
    )

    let clamped = media(duration: 120, elapsedTime: 145)
    try expect(clamped.elapsedTime == 120, "position was not clamped to known duration")

    let zeroDurationClamp = media(duration: 0, elapsedTime: 10)
    try expect(zeroDurationClamp.elapsedTime == 0, "known zero duration did not clamp position")

    let unboundedPosition = media(duration: nil, elapsedTime: 10)
    try expect(
      unboundedPosition.elapsedTime == 10,
      "position was discarded when duration was unavailable"
    )

    let enriched = try merged(
      authoritative: media(duration: nil, elapsedTime: nil),
      enrichment: media(duration: 180, elapsedTime: 45)
    )
    try expect(enriched.duration == 180, "merge did not fill a missing duration")
    try expect(enriched.elapsedTime == 45, "merge did not fill a missing position")

    let authoritativeZero = try merged(
      authoritative: media(duration: 0, elapsedTime: 0),
      enrichment: media(duration: 180, elapsedTime: 45)
    )
    try expect(authoritativeZero.duration == 0, "merge replaced a real zero duration")
    try expect(authoritativeZero.elapsedTime == 0, "merge replaced a real zero position")

    print("Media timing semantics behavior passed")
  }

  private static func merged(
    authoritative: MediaInfo,
    enrichment: MediaInfo
  ) throws -> MediaInfo {
    let provider = AdaptiveMediaInfoProvider(
      enrichmentProvider: StubMediaInfoProvider(result: .resolved(enrichment)),
      authoritativeProvider: StubMediaInfoProvider(result: .resolved(authoritative))
    )

    guard case .resolved(let result?) = provider.fetchMediaInfo(timeout: 1) else {
      throw HarnessFailure.expectation("adaptive provider did not resolve media")
    }
    return result
  }

  private static func media(duration: Double?, elapsedTime: Double?) -> MediaInfo {
    MediaInfo(
      name: "Track",
      artist: "Artist",
      album: nil,
      image: nil,
      duration: duration,
      elapsedTime: elapsedTime,
      processID: 0,
      processName: "Player",
      executablePath: "",
      playing: true,
      applicationIdentifier: "example.player"
    )
  }

  private static func expect(
    _ condition: @autoclosure () -> Bool,
    _ message: String
  ) throws {
    guard condition() else { throw HarnessFailure.expectation(message) }
  }
}
