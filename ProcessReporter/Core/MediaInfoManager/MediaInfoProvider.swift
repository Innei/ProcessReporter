// MediaInfoProvider.swift
// ProcessReporter
// Created by Claude on 2025/7/12.

import Darwin
import Foundation

typealias MediaInfoProviderCallback = @Sendable (MediaInfo?) -> Void

/// Distinguishes a successful media lookup, including an authoritative
/// no-media state, from a provider that could not answer the request.
enum MediaInfoFetchResult: Sendable {
  case resolved(MediaInfo?)
  case unavailable
}

/// Stable state used to suppress duplicate callbacks without discarding
/// enrichment-only changes such as artwork or process metadata.
enum MediaInfoSnapshotKey: Equatable, Sendable {
  case noMedia
  case media(
    name: String?,
    artist: String?,
    album: String?,
    imageHash: Int?,
    imageLength: Int,
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
      imageLength: info.image?.utf8.count ?? 0,
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
protocol MediaInfoProvider: AnyObject, Sendable {
  /// Start monitoring playback changes
  func startMonitoring(callback: @escaping MediaInfoProviderCallback)

  /// Stop monitoring playback changes
  func stopMonitoring()

  /// Resolve current media information without conflating no media with a
  /// temporary provider failure.
  func fetchMediaInfo(timeout: TimeInterval) -> MediaInfoFetchResult
}

extension MediaInfoProvider {
  func fetchMediaInfo() -> MediaInfoFetchResult {
    fetchMediaInfo(timeout: 3)
  }
}

/// Result of a bounded external-process invocation. Both output pipes are
/// drained while the child is running so that a full pipe cannot deadlock the
/// parent while it waits for termination.
enum ExternalProcessResult: Sendable {
  case completed(status: Int32, stdout: Data, stderr: Data)
  case launchFailed
  case timedOut
}

enum ExternalProcessRunner {
  static func run(
    executableURL: URL,
    arguments: [String],
    timeout: TimeInterval
  ) -> ExternalProcessResult {
    guard timeout > 0 else { return .timedOut }

    let process = Process()
    process.executableURL = executableURL
    process.arguments = arguments

    let outputPipe = Pipe()
    let errorPipe = Pipe()
    process.standardOutput = outputPipe
    process.standardError = errorPipe

    let completion = DispatchSemaphore(value: 0)
    process.terminationHandler = { _ in completion.signal() }

    do {
      try process.run()
    } catch {
      process.terminationHandler = nil
      return .launchFailed
    }

    let outputReader = PipeReader(handle: outputPipe.fileHandleForReading)
    let errorReader = PipeReader(handle: errorPipe.fileHandleForReading)
    outputReader.start()
    errorReader.start()

    let waitResult = completion.wait(timeout: .now() + timeout)
    guard waitResult == .success else {
      terminate(process, completion: completion)
      _ = outputReader.finish()
      _ = errorReader.finish()
      process.terminationHandler = nil
      return .timedOut
    }

    let output = outputReader.finish()
    let error = errorReader.finish()
    process.terminationHandler = nil
    return .completed(
      status: process.terminationStatus,
      stdout: output,
      stderr: error
    )
  }

  private static func terminate(_ process: Process, completion: DispatchSemaphore) {
    guard process.isRunning else { return }

    process.terminate()
    guard completion.wait(timeout: .now() + 0.25) != .success else { return }

    if process.isRunning {
      Darwin.kill(process.processIdentifier, SIGKILL)
      _ = completion.wait(timeout: .now() + 0.25)
    }
  }
}

private final class PipeReader: @unchecked Sendable {
  private let handle: FileHandle
  private let queue = DispatchQueue(label: "media-info.process-pipe-reader")
  private let group = DispatchGroup()
  private let lock = NSLock()
  private var data = Data()

  init(handle: FileHandle) {
    self.handle = handle
  }

  func start() {
    group.enter()
    queue.async { [self] in
      let readData = handle.readDataToEndOfFile()
      lock.lock()
      data = readData
      lock.unlock()
      group.leave()
    }
  }

  func finish() -> Data {
    if group.wait(timeout: .now() + 1) != .success {
      try? handle.close()
      _ = group.wait(timeout: .now() + 0.1)
    }

    lock.lock()
    defer { lock.unlock() }
    return data
  }
}
