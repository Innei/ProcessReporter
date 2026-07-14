// CLIMediaInfoProvider.swift
// ProcessReporter
// Created by Claude on 2025/7/12.

import AppKit
import Darwin
import Foundation

/// Media provider backed by the optional `media-control` executable.
/// Monitoring state is owned by `stateQueue`; bounded `get` invocations are
/// serialized independently so health checks and explicit fetches cannot race.
final class CLIMediaInfoProvider: MediaInfoProvider, @unchecked Sendable {
  private static let synchronousRequestTimeout: TimeInterval = 2

  private let stateQueue = DispatchQueue(label: "media-control.state")
  private let workQueue = DispatchQueue(label: "media-control.work", qos: .utility)
  private let callbackQueue = DispatchQueue(label: "media-control.callback")
  private let fetchGate = DispatchSemaphore(value: 1)

  // Accessed only on stateQueue.
  private var callback: MediaInfoProviderCallback?
  private var monitoringGeneration: UInt64 = 0
  private var lastSnapshotKey: MediaInfoSnapshotKey?
  private var pollTimer: DispatchSourceTimer?
  private var streamProcess: Process?
  private var streamStdout: FileHandle?
  private var streamStderr: FileHandle?
  private var streamBuffer = Data()
  private var streamErrorBuffer = Data()
  private var liveState: [String: Any] = [:]
  private var streamHealthWorkItem: DispatchWorkItem?

  static func isMediaControlInstalled() -> Bool {
    findMediaControlExecutable() != nil
  }

  func startMonitoring(callback: @escaping MediaInfoProviderCallback) {
    stateQueue.sync {
      stopMonitoringLocked()
      monitoringGeneration &+= 1
      let generation = monitoringGeneration
      self.callback = callback
      lastSnapshotKey = nil

      // Process launch occurs away from the caller (normally the main actor).
      stateQueue.async { [weak self] in
        guard let self, generation == monitoringGeneration, self.callback != nil else { return }
        if !startStreamLocked(generation: generation) {
          startPollingLocked(generation: generation)
        }
      }
    }
  }

  func stopMonitoring() {
    stateQueue.sync {
      stopMonitoringLocked()
    }
  }

  func fetchMediaInfo(timeout: TimeInterval) -> MediaInfoFetchResult {
    let startedAt = ProcessInfo.processInfo.systemUptime
    let boundedTimeout = min(Self.synchronousRequestTimeout, timeout)
    guard boundedTimeout > 0 else { return .unavailable }

    guard fetchGate.wait(timeout: .now() + boundedTimeout) == .success else {
      return .unavailable
    }
    defer { fetchGate.signal() }

    let elapsed = ProcessInfo.processInfo.systemUptime - startedAt
    let remaining = boundedTimeout - elapsed
    guard
      remaining > 0,
      let executable = Self.findMediaControlExecutable()
    else { return .unavailable }

    switch ExternalProcessRunner.run(
      executableURL: URL(fileURLWithPath: executable),
      arguments: ["get"],
      timeout: remaining
    ) {
    case .launchFailed, .timedOut:
      return .unavailable
    case .completed(let status, let output, _):
      guard status == 0 else { return .unavailable }
      return parseMediaInfo(from: output)
    }
  }

  // MARK: - Executable and JSON parsing

  private static func findMediaControlExecutable() -> String? {
    let fileManager = FileManager.default
    let knownPaths = [
      "/opt/homebrew/bin/media-control",
      "/usr/local/bin/media-control",
    ]

    if let path = knownPaths.first(where: { fileManager.isExecutableFile(atPath: $0) }) {
      return path
    }

    guard let pathEnvironment = ProcessInfo.processInfo.environment["PATH"] else { return nil }
    for directory in pathEnvironment.split(separator: ":") where !directory.isEmpty {
      let candidate = String(directory) + "/media-control"
      if fileManager.isExecutableFile(atPath: candidate) {
        return candidate
      }
    }
    return nil
  }

  private func parseMediaInfo(from data: Data) -> MediaInfoFetchResult {
    guard
      let object = try? JSONSerialization.jsonObject(with: data),
      let dictionary = object as? [String: Any]
    else { return .unavailable }

    let playing: Bool
    if let value = dictionary["playing"] as? Bool {
      playing = value
    } else if let state = dictionary["state"] as? String {
      playing = state.caseInsensitiveCompare("playing") == .orderedSame
    } else {
      playing = false
    }

    let title = nonEmptyString(dictionary["name"]) ?? nonEmptyString(dictionary["title"])
    guard title != nil || playing else { return .resolved(nil) }

    let artist = nonEmptyString(dictionary["artist"]) ?? nonEmptyString(dictionary["author"])
    let album = nonEmptyString(dictionary["album"])
    let duration =
      numberValue(dictionary["duration"])
      ?? numberValue(dictionary["durationSeconds"])
      ?? numberValue(dictionary["length"])
      ?? 0
    let elapsed =
      numberValue(dictionary["elapsedTime"])
      ?? numberValue(dictionary["elapsed"])
      ?? numberValue(dictionary["position"])
      ?? numberValue(dictionary["progressSeconds"])
      ?? 0

    var processID =
      intValue(dictionary["pid"])
      ?? intValue(dictionary["processID"])
      ?? intValue(dictionary["processId"])
      ?? intValue(dictionary["processIdentifier"])
      ?? 0
    var processName =
      nonEmptyString(dictionary["app"])
      ?? nonEmptyString(dictionary["process"])
      ?? ""
    var executablePath =
      nonEmptyString(dictionary["executablePath"])
      ?? nonEmptyString(dictionary["path"])
      ?? ""
    let explicitBundleIdentifier =
      nonEmptyString(dictionary["bundleId"])
      ?? nonEmptyString(dictionary["bundleIdentifier"])

    let runningApplication = runningApplication(
      processID: processID,
      bundleIdentifier: explicitBundleIdentifier
    )
    if let runningApplication {
      if processID == 0 { processID = Int(runningApplication.processIdentifier) }
      if processName.isEmpty { processName = runningApplication.localizedName ?? "" }
      if executablePath.isEmpty { executablePath = runningApplication.executableURL?.path ?? "" }
    }

    let applicationIdentifier = explicitBundleIdentifier ?? runningApplication?.bundleIdentifier
    let artwork =
      nonEmptyString(dictionary["artwork"])
      ?? nonEmptyString(dictionary["image"])
      ?? nonEmptyString(dictionary["artworkData"])

    return .resolved(
      MediaInfo(
        name: title,
        artist: artist,
        album: album,
        image: artwork,
        duration: duration,
        elapsedTime: elapsed,
        processID: processID,
        processName: processName,
        executablePath: executablePath,
        playing: playing,
        applicationIdentifier: applicationIdentifier
      )
    )
  }

  // MARK: - Stream monitoring

  /// Must run on stateQueue.
  private func startStreamLocked(generation: UInt64) -> Bool {
    dispatchPrecondition(condition: .onQueue(stateQueue))
    guard
      generation == monitoringGeneration,
      callback != nil,
      let executable = Self.findMediaControlExecutable()
    else { return false }

    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = ["stream", "--micros"]

    let outputPipe = Pipe()
    let errorPipe = Pipe()
    process.standardOutput = outputPipe
    process.standardError = errorPipe

    process.terminationHandler = { [weak self] terminatedProcess in
      self?.stateQueue.async { [weak self] in
        self?.handleStreamTerminationLocked(
          terminatedProcess,
          generation: generation
        )
      }
    }

    let outputHandle = outputPipe.fileHandleForReading
    outputHandle.readabilityHandler = { [weak self, weak process] handle in
      let data = handle.availableData
      guard !data.isEmpty, let self, let process else { return }
      stateQueue.async { [weak self, weak process] in
        guard let self, let process else { return }
        consumeStreamDataLocked(data, process: process, generation: generation)
      }
    }

    let errorHandle = errorPipe.fileHandleForReading
    errorHandle.readabilityHandler = { [weak self, weak process] handle in
      let data = handle.availableData
      guard !data.isEmpty, let self, let process else { return }
      stateQueue.async { [weak self, weak process] in
        guard
          let self,
          let process,
          streamProcess === process,
          generation == monitoringGeneration
        else { return }
        streamErrorBuffer.append(data.prefix(max(0, 4_096 - streamErrorBuffer.count)))
      }
    }

    do {
      try process.run()
    } catch {
      process.terminationHandler = nil
      outputHandle.readabilityHandler = nil
      errorHandle.readabilityHandler = nil
      return false
    }

    streamProcess = process
    streamStdout = outputHandle
    streamStderr = errorHandle
    streamBuffer.removeAll(keepingCapacity: true)
    streamErrorBuffer.removeAll(keepingCapacity: true)
    liveState.removeAll(keepingCapacity: true)
    scheduleStreamHealthCheckLocked(for: process, generation: generation, after: 3)
    return true
  }

  /// Must run on stateQueue.
  private func consumeStreamDataLocked(
    _ data: Data,
    process: Process,
    generation: UInt64
  ) {
    dispatchPrecondition(condition: .onQueue(stateQueue))
    guard
      streamProcess === process,
      generation == monitoringGeneration,
      callback != nil
    else { return }

    streamBuffer.append(data)
    while let newline = streamBuffer.firstRange(of: Data([0x0A])) {
      let line = streamBuffer.subdata(in: 0..<newline.lowerBound)
      streamBuffer.removeSubrange(0..<newline.upperBound)
      handleStreamLineLocked(line)
    }
  }

  /// Must run on stateQueue.
  private func handleStreamLineLocked(_ lineData: Data) {
    dispatchPrecondition(condition: .onQueue(stateQueue))
    guard
      !lineData.isEmpty,
      let object = try? JSONSerialization.jsonObject(with: lineData),
      let dictionary = object as? [String: Any],
      let payload = dictionary["payload"] as? [String: Any]
    else { return }

    if (dictionary["diff"] as? Bool) == true {
      for (key, value) in payload {
        if value is NSNull {
          liveState.removeValue(forKey: key)
        } else {
          liveState[key] = value
        }
      }
    } else {
      // A non-diff message is a full snapshot. Replacing rather than merging
      // prevents fields from a previous player leaking into the new item.
      liveState = payload.reduce(into: [:]) { state, entry in
        if !(entry.value is NSNull) {
          state[entry.key] = entry.value
        }
      }
    }

    emitIfChangedLocked(buildMediaInfoFromLiveStateLocked())
  }

  /// Must run on stateQueue.
  private func buildMediaInfoFromLiveStateLocked() -> MediaInfo? {
    dispatchPrecondition(condition: .onQueue(stateQueue))

    let title = nonEmptyString(liveState["title"]) ?? nonEmptyString(liveState["name"])
    let artist = nonEmptyString(liveState["artist"])
    let album = nonEmptyString(liveState["album"])
    let playing = (liveState["playing"] as? Bool) ?? false
    guard title != nil || playing else { return nil }

    let durationMicros = int64Value(liveState["durationMicros"]) ?? 0
    let elapsedMicros = int64Value(liveState["elapsedTimeMicros"]) ?? 0
    let timestampMicros = int64Value(liveState["timestampEpochMicros"]) ?? 0

    var currentElapsedMicros = max(0, elapsedMicros)
    if playing, timestampMicros > 0 {
      let nowMicros = Int64(Date().timeIntervalSince1970 * 1_000_000)
      currentElapsedMicros += max(0, nowMicros - timestampMicros)
    }

    let duration = Double(max(0, durationMicros)) / 1_000_000
    var elapsed = Double(currentElapsedMicros) / 1_000_000
    if duration > 0 { elapsed = min(elapsed, duration) }

    var processID =
      intValue(liveState["pid"])
      ?? intValue(liveState["processID"])
      ?? intValue(liveState["processIdentifier"])
      ?? 0
    var processName =
      nonEmptyString(liveState["app"])
      ?? nonEmptyString(liveState["process"])
      ?? ""
    var executablePath =
      nonEmptyString(liveState["path"])
      ?? nonEmptyString(liveState["executablePath"])
      ?? ""
    let explicitBundleIdentifier =
      nonEmptyString(liveState["bundleId"])
      ?? nonEmptyString(liveState["bundleIdentifier"])
    let runningApplication = runningApplication(
      processID: processID,
      bundleIdentifier: explicitBundleIdentifier
    )

    if let runningApplication {
      if processID == 0 { processID = Int(runningApplication.processIdentifier) }
      if processName.isEmpty { processName = runningApplication.localizedName ?? "" }
      if executablePath.isEmpty { executablePath = runningApplication.executableURL?.path ?? "" }
    }

    let artwork =
      nonEmptyString(liveState["artworkData"])
      ?? nonEmptyString(liveState["artwork"])
      ?? nonEmptyString(liveState["image"])

    return MediaInfo(
      name: title,
      artist: artist,
      album: album,
      image: artwork,
      duration: duration,
      elapsedTime: elapsed,
      processID: processID,
      processName: processName,
      executablePath: executablePath,
      playing: playing,
      applicationIdentifier: explicitBundleIdentifier ?? runningApplication?.bundleIdentifier
    )
  }

  /// Must run on stateQueue.
  private func handleStreamTerminationLocked(_ process: Process, generation: UInt64) {
    dispatchPrecondition(condition: .onQueue(stateQueue))
    guard streamProcess === process, generation == monitoringGeneration else { return }

    streamHealthWorkItem?.cancel()
    streamHealthWorkItem = nil
    streamStdout?.readabilityHandler = nil
    streamStderr?.readabilityHandler = nil
    streamStdout = nil
    streamStderr = nil
    streamProcess = nil
    streamBuffer.removeAll(keepingCapacity: false)
    liveState.removeAll(keepingCapacity: false)

    if !streamErrorBuffer.isEmpty,
      let message = String(data: streamErrorBuffer, encoding: .utf8)?
        .trimmingCharacters(in: .whitespacesAndNewlines),
      !message.isEmpty
    {
      NSLog("[CLIMediaInfoProvider] Stream ended: \(message)")
    }
    streamErrorBuffer.removeAll(keepingCapacity: false)

    // Transport failure is not an authoritative no-media result. Polling will
    // emit nil only after a successful `get` confirms that state.
    startPollingLocked(generation: generation)
  }

  /// Must run on stateQueue.
  private func scheduleStreamHealthCheckLocked(
    for process: Process,
    generation: UInt64,
    after delay: TimeInterval
  ) {
    dispatchPrecondition(condition: .onQueue(stateQueue))
    streamHealthWorkItem?.cancel()

    let item = DispatchWorkItem { [weak self, weak process] in
      guard let self, let process else { return }
      let result = fetchMediaInfo(timeout: Self.synchronousRequestTimeout)

      stateQueue.async { [weak self, weak process] in
        guard
          let self,
          let process,
          streamProcess === process,
          generation == monitoringGeneration,
          callback != nil
        else { return }

        if case .resolved(let fetchedInfo) = result,
          MediaInfoSnapshotKey(fetchedInfo) != lastSnapshotKey
        {
          NSLog("[CLIMediaInfoProvider] Stream state is stale; switching to polling")
          process.terminate()
          workQueue.asyncAfter(deadline: .now() + 0.25) {
            if process.isRunning {
              Darwin.kill(process.processIdentifier, SIGKILL)
            }
          }
          return
        }

        scheduleStreamHealthCheckLocked(
          for: process,
          generation: generation,
          after: 10
        )
      }
    }

    streamHealthWorkItem = item
    workQueue.asyncAfter(deadline: .now() + delay, execute: item)
  }

  // MARK: - Polling fallback

  /// Must run on stateQueue.
  private func startPollingLocked(generation: UInt64) {
    dispatchPrecondition(condition: .onQueue(stateQueue))
    guard
      pollTimer == nil,
      callback != nil,
      generation == monitoringGeneration
    else { return }

    let timer = DispatchSource.makeTimerSource(queue: workQueue)
    timer.schedule(deadline: .now(), repeating: 1, leeway: .milliseconds(100))
    timer.setEventHandler { [weak self] in
      guard let self else { return }
      let result = fetchMediaInfo(timeout: Self.synchronousRequestTimeout)
      guard case .resolved(let info) = result else { return }
      stateQueue.async { [weak self] in
        guard
          let self,
          generation == monitoringGeneration,
          callback != nil
        else { return }
        emitIfChangedLocked(info)
      }
    }
    pollTimer = timer
    timer.resume()
  }

  /// Must run on stateQueue.
  private func stopMonitoringLocked() {
    dispatchPrecondition(condition: .onQueue(stateQueue))
    monitoringGeneration &+= 1

    pollTimer?.setEventHandler {}
    pollTimer?.cancel()
    pollTimer = nil

    streamHealthWorkItem?.cancel()
    streamHealthWorkItem = nil

    streamStdout?.readabilityHandler = nil
    streamStderr?.readabilityHandler = nil
    streamStdout = nil
    streamStderr = nil

    if let process = streamProcess {
      process.terminationHandler = nil
      if process.isRunning {
        process.terminate()
        workQueue.asyncAfter(deadline: .now() + 0.25) {
          if process.isRunning {
            Darwin.kill(process.processIdentifier, SIGKILL)
          }
        }
      }
    }
    streamProcess = nil

    callback = nil
    lastSnapshotKey = nil
    streamBuffer.removeAll(keepingCapacity: false)
    streamErrorBuffer.removeAll(keepingCapacity: false)
    liveState.removeAll(keepingCapacity: false)
  }

  /// Must run on stateQueue.
  private func emitIfChangedLocked(_ info: MediaInfo?) {
    dispatchPrecondition(condition: .onQueue(stateQueue))
    let key = MediaInfoSnapshotKey(info)
    guard key != lastSnapshotKey else { return }

    lastSnapshotKey = key
    let callback = callback
    callbackQueue.async {
      callback?(info)
    }
  }

  // MARK: - Value conversion

  private func runningApplication(
    processID: Int,
    bundleIdentifier: String?
  ) -> NSRunningApplication? {
    if processID > 0,
      let application = NSRunningApplication(processIdentifier: pid_t(processID))
    {
      return application
    }
    if let bundleIdentifier {
      return NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).first
    }
    return nil
  }

  private func nonEmptyString(_ value: Any?) -> String? {
    guard let string = value as? String, !string.isEmpty else { return nil }
    return string
  }

  private func intValue(_ value: Any?) -> Int? {
    if let number = value as? NSNumber { return number.intValue }
    if let string = value as? String { return Int(string) }
    return nil
  }

  private func int64Value(_ value: Any?) -> Int64? {
    if let number = value as? NSNumber { return number.int64Value }
    if let string = value as? String { return Int64(string) }
    return nil
  }

  private func numberValue(_ value: Any?) -> Double? {
    if let number = value as? NSNumber {
      let result = number.doubleValue
      return result.isFinite ? max(0, result) : nil
    }
    guard let string = value as? String else { return nil }
    if let result = Double(string), result.isFinite {
      return max(0, result)
    }

    let parts = string.split(separator: ":").reversed()
    var multiplier = 1.0
    var total = 0.0
    for part in parts {
      guard let value = Double(part.replacingOccurrences(of: ",", with: ".")) else {
        return nil
      }
      total += value * multiplier
      multiplier *= 60
    }
    return total.isFinite ? max(0, total) : nil
  }
}
