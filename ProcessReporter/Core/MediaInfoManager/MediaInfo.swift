public struct MediaInfo: Sendable {
  let name: String?
  let artist: String?
  let album: String?
  let image: String?
  /// Total playback duration in seconds. `nil` means that the source did not
  /// provide a duration; a real zero remains distinguishable from absence.
  let duration: Double?
  /// Current playback position in seconds. `nil` means that the source did not
  /// provide a position; a real zero remains distinguishable from absence.
  let elapsedTime: Double?
  let processID: Int
  var processName: String
  let executablePath: String
  let playing: Bool

  let applicationIdentifier: String?

  init(
    name: String?,
    artist: String?,
    album: String?,
    image: String?,
    duration: Double?,
    elapsedTime: Double?,
    processID: Int,
    processName: String,
    executablePath: String,
    playing: Bool,
    applicationIdentifier: String?
  ) {
    self.name = name
    self.artist = artist
    self.album = album
    self.image = image

    let normalizedDuration = Self.normalizedPlaybackTime(duration)
    let normalizedElapsedTime = Self.normalizedPlaybackTime(elapsedTime)
    self.duration = normalizedDuration
    if let normalizedDuration, let normalizedElapsedTime {
      self.elapsedTime = min(normalizedElapsedTime, normalizedDuration)
    } else {
      self.elapsedTime = normalizedElapsedTime
    }

    self.processID = processID
    self.processName = processName
    self.executablePath = executablePath
    self.playing = playing
    self.applicationIdentifier = applicationIdentifier
  }

  private static func normalizedPlaybackTime(_ value: Double?) -> Double? {
    guard let value, value.isFinite, value >= 0 else { return nil }
    return value
  }
}
