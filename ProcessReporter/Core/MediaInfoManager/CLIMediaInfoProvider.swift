// CLIMediaInfoProvider.swift
// ProcessReporter
// Created by Claude on 2025/7/12.

import AppKit
import Foundation

/// MediaInfoProvider implementation using media-control CLI tool
/// Requires media-control to be installed via: brew install media-control
/// Compatible with macOS 15.4 and later
class CLIMediaInfoProvider: MediaInfoProvider {

  // MARK: - Public Helpers

  /// Quick check for whether media-control is available on this system
  static func isMediaControlInstalled() -> Bool {
    return CLIMediaInfoProvider().findMediaControlExecutable() != nil
  }

  // MARK: - Monitoring

  private var timer: Timer?
  private var callback: MediaInfoManager.PlaybackStateChangedCallback?
  private var lastSnapshotKey: String?
  private var lastInfo: MediaInfo?
  private var consecutiveFailures = 0
  private var streamProcess: Process?
  private var streamStdout: FileHandle?
  private var streamBuffer = Data()
  private let streamQueue = DispatchQueue(label: "media-control.stream.queue")
  private var isStreaming = false

  func resetFailureCounter() {
    consecutiveFailures = 0
  }

  func startMonitoring(callback: @escaping MediaInfoManager.PlaybackStateChangedCallback) {
    // Stop existing monitoring first to avoid clearing the new callback
    stopMonitoring()
    self.callback = callback

    // Prefer streaming if available
    if startStream() {
      return
    }

    // Fallback: poll every second
    timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
      guard let self = self else { return }
      guard let info = self.getMediaInfo() else { return }
      self.emitIfChanged(info)
    }
    if let timer = timer {
      RunLoop.main.add(timer, forMode: .common)
      print("✅ [CLIMediaInfoProvider] Polling timer started")
    }
  }

  func stopMonitoring() {
    print("🛑 [CLIMediaInfoProvider] Stopping monitoring...")

    // Stop stream if running
    if isStreaming {
      isStreaming = false
    }

    if let handle = streamStdout {
      handle.readabilityHandler = nil
    }
    streamStdout = nil

    if let process = streamProcess {
      if process.isRunning {
        process.terminate()
      }
    }
    streamProcess = nil
    streamBuffer.removeAll(keepingCapacity: false)

    if timer != nil {
      timer?.invalidate()
      timer = nil
    }

    callback = nil
    lastSnapshotKey = nil
  }

  func getMediaInfo() -> MediaInfo? {
    guard let exec = findMediaControlExecutable() else { return nil }

    // Execute: media-control get
    guard let outputData = runProcess(execPath: exec, arguments: ["get"]) else {
      consecutiveFailures += 1
      return nil
    }

    // Parse JSON output into MediaInfo
    do {
      let json = try JSONSerialization.jsonObject(with: outputData, options: [])
      guard let dict = json as? [String: Any] else { return nil }

      // If the tool reports nothing playing, prefer returning nil
      // Common flags: playing/state
      let playing: Bool = {
        if let v = dict["playing"] as? Bool { return v }
        if let s = dict["state"] as? String { return s.lowercased() == "playing" }
        return false
      }()

      // Extract fields with flexible key mapping
      let name = (dict["name"] as? String) ?? (dict["title"] as? String)
      let artist = (dict["artist"] as? String) ?? (dict["author"] as? String)
      let album = dict["album"] as? String

      // Durations/positions may come as number or string
      func numberValue(_ any: Any?) -> Double? {
        if let n = any as? NSNumber { return n.doubleValue }
        if let d = any as? Double { return d }
        if let i = any as? Int { return Double(i) }
        if let s = any as? String {
          // Try parsing seconds from common formats (e.g., "123.45")
          if let v = Double(s) { return v }
          // Try mm:ss or hh:mm:ss
          let parts = s.split(separator: ":").reversed()
          var mul = 1.0
          var total = 0.0
          for p in parts {
            if let v = Double(p.replacingOccurrences(of: ",", with: ".")) {
              total += v * mul
              mul *= 60
            } else {
              return nil
            }
          }
          return total
        }
        return nil
      }

      let duration =
        numberValue(dict["duration"]) ?? numberValue(dict["durationSeconds"]) ?? numberValue(
          dict["length"]) ?? 0

      let elapsed =
        numberValue(dict["elapsedTime"]) ?? numberValue(dict["elapsed"]) ?? numberValue(
          dict["position"]) ?? numberValue(dict["progressSeconds"]) ?? 0

      // Process info
      let pid =
        (dict["pid"] as? Int) ?? (dict["processID"] as? Int) ?? (dict["processId"] as? Int) ?? 0
      var processName = (dict["app"] as? String) ?? (dict["process"] as? String) ?? ""
      var executablePath = (dict["executablePath"] as? String) ?? (dict["path"] as? String) ?? ""

      // Artwork may be base64 in various keys; ignore non-base64 URL forms here
      let imageBase64 =
        (dict["artwork"] as? String) ?? (dict["image"] as? String)
        ?? (dict["artworkData"] as? String)

      // Fallback to NSRunningApplication for richer process info
      if pid != 0 {
        if let app = NSRunningApplication(processIdentifier: pid_t(pid)) {
          if processName.isEmpty { processName = app.localizedName ?? processName }
          if executablePath.isEmpty { executablePath = app.executableURL?.path ?? executablePath }
        }
      }

      // Application identifier
      let explicitBundleId = (dict["bundleId"] as? String) ?? (dict["bundleIdentifier"] as? String)
      let applicationIdentifier =
        explicitBundleId ?? AppUtility.getBundleIdentifierForPID(pid_t(pid))

      // If no track name and not playing, treat as no media
      if name == nil && !playing {
        return nil
      }

      consecutiveFailures = 0
      return MediaInfo(
        name: name,
        artist: artist,
        album: album,
        image: imageBase64,
        duration: duration,
        elapsedTime: elapsed,
        processID: pid,
        processName: processName,
        executablePath: executablePath,
        playing: playing,
        applicationIdentifier: applicationIdentifier
      )
    } catch {
      // Malformed output
      consecutiveFailures += 1
      return nil
    }
  }

  // MARK: - CLI helpers

  /// Locate the media-control binary by checking common Homebrew paths and PATH
  private func findMediaControlExecutable() -> String? {
    // Check common install locations first
    let mediaControlPaths = [
      "/opt/homebrew/bin/media-control",
      "/usr/local/bin/media-control",
    ]
    if let p = mediaControlPaths.first(where: { FileManager.default.fileExists(atPath: $0) }) {
      return p
    }

    // Search in PATH
    if let pathEnv = ProcessInfo.processInfo.environment["PATH"] {
      for dir in pathEnv.split(separator: ":") {
        let candidate = String(dir) + "/media-control"
        if FileManager.default.fileExists(atPath: candidate) {
          return candidate
        }
      }
    }
    return nil
  }

  private func runProcess(execPath: String, arguments: [String]) -> Data? {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: execPath)
    process.arguments = arguments

    let outputPipe = Pipe()
    process.standardOutput = outputPipe
    process.standardError = Pipe()

    do {
      try process.run()
    } catch {
      return nil
    }

    process.waitUntilExit()
    guard process.terminationStatus == 0 else { return nil }
    return outputPipe.fileHandleForReading.readDataToEndOfFile()
  }

  // MARK: - Streaming

  private func startStream() -> Bool {

    guard let exec = findMediaControlExecutable() else {
      return false
    }

    let process = Process()
    process.executableURL = URL(fileURLWithPath: exec)
    process.arguments = ["stream", "--micros"]

    let outputPipe = Pipe()
    process.standardOutput = outputPipe
    process.standardError = Pipe()

    do {
      try process.run()
    } catch {
      return false
    }

    streamProcess = process
    streamStdout = outputPipe.fileHandleForReading
    isStreaming = true

    streamStdout?.readabilityHandler = { [weak self] handle in
      guard let self = self else { return }
      let data = handle.availableData

      if data.isEmpty {
        return
      }

      self.streamQueue.async {
        self.streamBuffer.append(data)

        var lineCount = 0
        // Split by newlines (JSONL)
        while let range = self.streamBuffer.firstRange(of: Data([0x0a])) {  // '\n'
          let lineData = self.streamBuffer.subdata(in: 0..<range.lowerBound)
          self.streamBuffer.removeSubrange(0..<(range.upperBound))
          lineCount += 1
          self.handleStreamLine(lineData)
        }
      }
    }

    return true
  }

  private func handleStreamLine(_ lineData: Data) {
    guard isStreaming else {
      return
    }
    guard !lineData.isEmpty else {
      return
    }

    // Parse line JSON: { diff: bool, payload: { ... } }
    guard
      let obj = try? JSONSerialization.jsonObject(with: lineData, options: []),
      let dict = obj as? [String: Any]
    else { return }

    let payload = (dict["payload"] as? [String: Any]) ?? [:]
    let isEmpty = (dict["diff"] as? Bool) == false && payload.isEmpty

    // Maintain a live state dictionary
    if isEmpty {
      liveState = [:]
    } else {
      // Remove nils and merge
      var filtered: [String: Any] = [:]
      for (k, v) in payload {
        if !(v is NSNull) { filtered[k] = v }
      }
      for (k, v) in filtered { liveState[k] = v }
    }

    if let info = buildMediaInfoFromLiveState() {
      print(
        "✅ [CLIMediaInfoProvider] Built MediaInfo: \(info.name ?? "nil") by \(info.artist ?? "nil") - playing: \(info.playing)"
      )
      lastInfo = info
      emitIfChanged(info)
    } else {
      print("⚠️ [CLIMediaInfoProvider] Could not build MediaInfo from current live state")
    }
  }

  // Keep last received fields from stream
  private var liveState: [String: Any] = [:]

  private func buildMediaInfoFromLiveState() -> MediaInfo? {
    // Extract using micros fields when present
    let title = (liveState["title"] as? String) ?? (liveState["name"] as? String)
    let artist = liveState["artist"] as? String
    let album = liveState["album"] as? String
    let playing = (liveState["playing"] as? Bool) ?? false

    // Micros-based timing
    func int64(_ any: Any?) -> Int64? {
      if let n = any as? NSNumber { return n.int64Value }
      if let i = any as? Int { return Int64(i) }
      if let l = any as? Int64 { return l }
      if let s = any as? String, let v = Int64(s) { return v }
      return nil
    }

    let durationMicros = int64(liveState["durationMicros"]) ?? 0
    let elapsedMicrosBase = int64(liveState["elapsedTimeMicros"]) ?? 0
    let timestampMicros = int64(liveState["timestampEpochMicros"]) ?? 0

    // Compute elapsed now
    var elapsedSeconds: Double = 0
    if elapsedMicrosBase > 0 {
      var micros = elapsedMicrosBase
      if playing, timestampMicros > 0 {
        let nowMicros = Int64(Date().timeIntervalSince1970 * 1_000_000)
        let delta = max(0, nowMicros - timestampMicros)
        micros += delta
      }
      elapsedSeconds = Double(micros) / 1_000_000.0
    }

    let durationSeconds = Double(max(0, durationMicros)) / 1_000_000.0

    // Process info
    let pid = (liveState["pid"] as? Int) ?? (liveState["processID"] as? Int) ?? 0
    var processName = (liveState["app"] as? String) ?? (liveState["process"] as? String) ?? ""
    var executablePath =
      (liveState["path"] as? String) ?? (liveState["executablePath"] as? String) ?? ""
    if pid != 0 {
      if let app = NSRunningApplication(processIdentifier: pid_t(pid)) {
        if processName.isEmpty { processName = app.localizedName ?? processName }
        if executablePath.isEmpty { executablePath = app.executableURL?.path ?? executablePath }
      }
    }

    let bundleId = (liveState["bundleId"] as? String) ?? (liveState["bundleIdentifier"] as? String)
    let applicationIdentifier = bundleId ?? AppUtility.getBundleIdentifierForPID(pid_t(pid))

    // Artwork may not be provided by stream; keep nil unless present
    let imageBase64 = (liveState["artwork"] as? String) ?? (liveState["image"] as? String)

    if title == nil && !playing {
      return nil
    }

    return MediaInfo(
      name: title,
      artist: artist,
      album: album,
      image: imageBase64,
      duration: durationSeconds,
      elapsedTime: elapsedSeconds,
      processID: pid,
      processName: processName,
      executablePath: executablePath,
      playing: playing,
      applicationIdentifier: applicationIdentifier
    )
  }

  private func emitIfChanged(_ info: MediaInfo) {
    let key = "\(info.name ?? "")|\(info.artist ?? "")|\(info.playing)|\(info.processID)"

    if key != self.lastSnapshotKey {
      print("🔔 [CLIMediaInfoProvider] Media state changed, emitting callback")
      print("   Previous key: \(self.lastSnapshotKey ?? "nil")")
      print("   New key: \(key)")
      print("   Track: \(info.name ?? "nil") by \(info.artist ?? "nil")")
      print("   Playing: \(info.playing), PID: \(info.processID)")

      self.lastSnapshotKey = key
      if let cb = self.callback {
        print("📞 [CLIMediaInfoProvider] Dispatching callback to main queue")
        DispatchQueue.main.async {
          cb(info)
        }
      } else {
        print("⚠️ [CLIMediaInfoProvider] No callback registered, skipping emission")
      }
    } else {
      print("🔄 [CLIMediaInfoProvider] Media state unchanged, skipping callback")
    }
  }
}
