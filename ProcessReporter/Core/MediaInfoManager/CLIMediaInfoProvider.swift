// CLIMediaInfoProvider.swift
// ProcessReporter
// Created by Claude on 2025/7/12.

import AppKit
import Foundation

/// MediaInfoProvider implementation using media-control CLI tool
/// Requires media-control to be installed via: brew install media-control
/// Compatible with macOS 15.4 and later
class CLIMediaInfoProvider: MediaInfoProvider {

  // MARK: - Properties

  private var timer: Timer?
  private var callback: MediaInfoManager.PlaybackStateChangedCallback?
  private var lastMediaInfo: MediaInfo?
  private var isMonitoring = false
  private let pollingInterval: TimeInterval = {
    #if DEBUG
      return 1.0
    #else
      return 5.0
    #endif
  }()
  private var currentProcess: Process?
  private let processQueue = DispatchQueue(
    label: "com.processreporter.cli.queue", attributes: .concurrent)
  private let processLock = NSLock()
  private var consecutiveFailures = 0
  private let maxConsecutiveFailures = 5
  private let cliTimeout: TimeInterval = 5.0
  private let failureResetDelay: TimeInterval = 30.0
  private let processTerminationDelay: TimeInterval = 1.0
  private let forceKillDelay: TimeInterval = 0.5

  // MARK: - Constants

  private enum Constants {
    static let elapsedTimeThreshold: TimeInterval = 2.0
    static let jsonPreviewLength = 200
    static let mediaControlCommand = "get"
  }

  // MARK: - MediaInfoProvider Implementation

  func startMonitoring(callback: @escaping MediaInfoManager.PlaybackStateChangedCallback) {

    debugPrint("[CLIMediaInfoProvider] 🚀 Starting monitoring...")

    guard !isMonitoring else {

      debugPrint("[CLIMediaInfoProvider] ⚠️ Already monitoring, ignoring start request")

      return
    }

    self.callback = callback
    self.isMonitoring = true

    debugPrint("[CLIMediaInfoProvider] Callback set, getting initial state...")

    // Get initial state immediately
    checkForMediaChanges()

    // Start periodic polling with timer
    timer = Timer.scheduledTimer(withTimeInterval: pollingInterval, repeats: true) {
      [weak self] _ in
      self?.checkForMediaChanges()
    }

    debugPrint("[CLIMediaInfoProvider] ✅ Timer started with \(pollingInterval)s interval")

  }

  func stopMonitoring() {

    debugPrint("[CLIMediaInfoProvider] 🛑 Stopping monitoring...")

    isMonitoring = false
    timer?.invalidate()
    timer = nil
    callback = nil
    lastMediaInfo = nil

    // Kill any running process with more aggressive cleanup
    processLock.lock()
    if let process = currentProcess, process.isRunning {

      debugPrint(
        "[CLIMediaInfoProvider] Terminating running process PID: \(process.processIdentifier)")

      process.terminate()

      // Give it a moment to terminate gracefully, then force kill if needed
      DispatchQueue.global().asyncAfter(deadline: .now() + processTerminationDelay) {
        if process.isRunning {

          debugPrint(
            "[CLIMediaInfoProvider] Force killing process PID: \(process.processIdentifier)")

          process.interrupt()
        }
      }
    }
    currentProcess = nil
    processLock.unlock()
    consecutiveFailures = 0

    debugPrint("[CLIMediaInfoProvider] ✅ Monitoring stopped and resources cleaned up")

  }

  func getMediaInfo() -> MediaInfo? {
    return lastMediaInfo
  }

  deinit {
    stopMonitoring()
  }

  // MARK: - Private Methods

  /// Safely cleanup file handles by setting readability handlers to nil
  private func cleanupFileHandles(_ outputHandle: FileHandle, _ errorHandle: FileHandle) {
    outputHandle.readabilityHandler = nil
    errorHandle.readabilityHandler = nil
  }

  /// Reset failure counters - useful after system wake or external restart
  func resetFailureCounter() {
    consecutiveFailures = 0
    debugPrint("[CLIMediaInfoProvider] Failure counter reset")
  }

  private func checkForMediaChanges() {

    debugPrint("[CLIMediaInfoProvider] Starting media check...")

    // Check if we've hit too many consecutive failures
    if consecutiveFailures >= maxConsecutiveFailures {

      debugPrint(
        "[CLIMediaInfoProvider] ❌ Too many consecutive failures (\(consecutiveFailures)), pausing checks"
      )

      // Reset the counter after a longer delay
      DispatchQueue.main.asyncAfter(deadline: .now() + failureResetDelay) { [weak self] in
        self?.consecutiveFailures = 0

        debugPrint("[CLIMediaInfoProvider] Resetting failure counter after delay")

      }
      return
    }

    // Skip if a process is already running
    processLock.lock()
    if let process = currentProcess, process.isRunning {
      processLock.unlock()

      debugPrint("[CLIMediaInfoProvider] ⚠️ Previous process still running, skipping this check")

      return
    }
    processLock.unlock()

    // Execute CLI asynchronously to avoid blocking the timer
    executeMediaRemoteAdapterAsync { [weak self] mediaInfo in
      guard let self = self else {

        debugPrint("[CLIMediaInfoProvider] Self was deallocated during async execution")

        return
      }

      debugPrint(
        "[CLIMediaInfoProvider] CLI execution completed, mediaInfo: \(mediaInfo != nil ? "✅" : "❌")"
      )

      // Update failure counter
      if mediaInfo != nil {
        self.consecutiveFailures = 0
      } else {
        self.consecutiveFailures += 1

        debugPrint("[CLIMediaInfoProvider] Consecutive failures: \(self.consecutiveFailures)")

      }

      // Check if this is a significant change
      let hasChanged = self.hasSignificantChange(from: self.lastMediaInfo, to: mediaInfo)

      debugPrint("[CLIMediaInfoProvider] Has significant change: \(hasChanged)")

      self.lastMediaInfo = mediaInfo

      if hasChanged, let mediaInfo = mediaInfo {

        debugPrint(
          "[CLIMediaInfoProvider] Triggering callback with media: \(mediaInfo.name ?? "unknown")")

        DispatchQueue.main.async {
          self.callback?(mediaInfo)
        }
      } else {

        debugPrint(
          "[CLIMediaInfoProvider] No callback triggered - hasChanged: \(hasChanged), mediaInfo exists: \(mediaInfo != nil)"
        )

      }
    }
  }

  private func executeMediaRemoteAdapterAsync(completion: @escaping (MediaInfo?) -> Void) {

    debugPrint("[CLIMediaInfoProvider] Starting async CLI execution...")

    processQueue.async(flags: .barrier) { [weak self] in
      guard let self = self else {

        debugPrint("[CLIMediaInfoProvider] Self deallocated in async block")

        completion(nil)
        return
      }

      debugPrint("[CLIMediaInfoProvider] In background queue, finding executable...")

      // Find the mediaremote-adapter executable
      guard let executablePath = self.findMediaRemoteAdapter() else {

        debugPrint("[CLIMediaInfoProvider] ❌ media-control not found")

        completion(nil)
        return
      }

      debugPrint("[CLIMediaInfoProvider] ✅ Found executable at: \(executablePath)")

      let process = Process()
      let outputPipe = Pipe()
      let errorPipe = Pipe()

      // Configure process for media-control binary
      process.executableURL = URL(fileURLWithPath: executablePath)
      process.arguments = [Constants.mediaControlCommand]

      debugPrint(
        "[CLIMediaInfoProvider] Configured media-control process: \(executablePath) get")

      process.standardOutput = outputPipe
      process.standardError = errorPipe

      // Set up data accumulation buffers
      var outputData = Data()
      var errorData = Data()
      let dataLock = NSLock()

      // Set up non-blocking data reading
      let outputHandle = outputPipe.fileHandleForReading
      let errorHandle = errorPipe.fileHandleForReading

      // Configure file handles for non-blocking reads
      outputHandle.readabilityHandler = { handle in
        let data = handle.availableData
        dataLock.lock()
        outputData.append(data)
        dataLock.unlock()

        debugPrint(
          "[CLIMediaInfoProvider] Read \(data.count) bytes from stdout (total: \(outputData.count))"
        )

      }

      errorHandle.readabilityHandler = { handle in
        let data = handle.availableData
        dataLock.lock()
        errorData.append(data)
        dataLock.unlock()

        if !data.isEmpty, let errorString = String(data: data, encoding: .utf8) {
          debugPrint("[CLIMediaInfoProvider] Error output: \(errorString)")
        }

      }

      do {

        debugPrint("[CLIMediaInfoProvider] Attempting to run process...")

        // Store the process reference
        self.processLock.lock()
        self.currentProcess = process
        self.processLock.unlock()

        try process.run()

        // Verify process actually started
        guard process.isRunning else {

          debugPrint("[CLIMediaInfoProvider] ❌ Process failed to start")

          self.processLock.lock()
          self.currentProcess = nil
          self.processLock.unlock()
          completion(nil)
          return
        }

        debugPrint(
          "[CLIMediaInfoProvider] ✅ Process started successfully, PID: \(process.processIdentifier)"
        )

        // Set up timeout using DispatchSourceTimer (works in background queues)

        debugPrint("[CLIMediaInfoProvider] Setting up \(self.cliTimeout)-second timeout timer...")

        let timeoutTimer = DispatchSource.makeTimerSource(queue: self.processQueue)
        var hasTimedOut = false
        var hasCompleted = false
        let completionLock = NSLock()

        timeoutTimer.schedule(deadline: .now() + self.cliTimeout)
        timeoutTimer.setEventHandler { [weak self] in
          completionLock.lock()
          guard !hasCompleted else {
            completionLock.unlock()
            return
          }
          hasTimedOut = true
          hasCompleted = true
          completionLock.unlock()

          debugPrint("[CLIMediaInfoProvider] ⏰ Timeout triggered!")

          // Clean up file handles
          self?.cleanupFileHandles(outputHandle, errorHandle)

          self?.processLock.lock()
          if let currentProcess = self?.currentProcess,
            currentProcess.processIdentifier == process.processIdentifier
          {
            if process.isRunning {

              debugPrint("[CLIMediaInfoProvider] Process still running, terminating...")

              process.terminate()
              // Give it a moment to terminate gracefully
              let delay = self?.forceKillDelay ?? 0.5
              DispatchQueue.global().asyncAfter(deadline: .now() + delay) {
                if process.isRunning {

                  debugPrint("[CLIMediaInfoProvider] Force killing process")

                  process.interrupt()
                }
              }
            } else {

              debugPrint("[CLIMediaInfoProvider] Process already finished when timeout triggered")

            }
            self?.currentProcess = nil
          }
          self?.processLock.unlock()

          completion(nil)
          timeoutTimer.cancel()
        }
        timeoutTimer.resume()
        debugPrint("[CLIMediaInfoProvider] Timeout timer started")

        // Use terminationHandler for async completion
        debugPrint("[CLIMediaInfoProvider] Setting up termination handler...")
        process.terminationHandler = { [weak self] terminatedProcess in
          completionLock.lock()
          guard !hasCompleted else {
            completionLock.unlock()

            debugPrint("[CLIMediaInfoProvider] Termination handler called but already completed")

            return
          }
          hasCompleted = true
          completionLock.unlock()

          debugPrint(
            "[CLIMediaInfoProvider] 🎯 Termination handler called! Status: \(terminatedProcess.terminationStatus)"
          )
          timeoutTimer.cancel()

          // Clean up file handles
          self?.cleanupFileHandles(outputHandle, errorHandle)

          // Clear the current process reference
          self?.processLock.lock()
          if self?.currentProcess?.processIdentifier == terminatedProcess.processIdentifier {
            self?.currentProcess = nil
          }
          self?.processLock.unlock()

          // Don't process if we already timed out
          guard !hasTimedOut else {
            debugPrint("[CLIMediaInfoProvider] Ignoring termination handler - already timed out")
            return
          }

          guard terminatedProcess.terminationStatus == 0 else {
            debugPrint(
              "[CLIMediaInfoProvider] ❌ Process failed with status: \(terminatedProcess.terminationStatus)"
            )

            // Log error output if available
            dataLock.lock()
            if !errorData.isEmpty, let errorString = String(data: errorData, encoding: .utf8) {
              debugPrint("[CLIMediaInfoProvider] Error details: \(errorString)")
            }
            dataLock.unlock()

            completion(nil)
            return
          }

          debugPrint("[CLIMediaInfoProvider] ✅ Process completed successfully, processing data...")

          // Get the final output data
          dataLock.lock()
          let finalOutputData = outputData
          dataLock.unlock()

          debugPrint("[CLIMediaInfoProvider] Read \(finalOutputData.count) bytes of data")

          let mediaInfo = self?.parseJSONOutput(finalOutputData)
          debugPrint("[CLIMediaInfoProvider] Parsed media info: \(mediaInfo != nil ? "✅" : "❌")")

          completion(mediaInfo)
        }
        debugPrint("[CLIMediaInfoProvider] Termination handler set, waiting for completion...")

      } catch {
        debugPrint("[CLIMediaInfoProvider] ❌ Failed to execute process: \(error)")

        // Clean up file handles
        self.cleanupFileHandles(outputHandle, errorHandle)

        // Clear the process reference on error
        self.processLock.lock()
        self.currentProcess = nil
        self.processLock.unlock()

        completion(nil)
      }
    }
  }

  private func hasSignificantChange(from old: MediaInfo?, to new: MediaInfo?) -> Bool {
    guard let old = old, let new = new else {
      return new != nil  // Return true if we have new data
    }

    return old.name != new.name || old.artist != new.artist || old.playing != new.playing
      || abs(old.elapsedTime - new.elapsedTime) > Constants.elapsedTimeThreshold
  }

  private func findMediaRemoteAdapter() -> String? {
    // Only check for media-control binary paths
    let mediaControlPaths = [
      "/opt/homebrew/bin/media-control",
      "/usr/local/bin/media-control",
    ]

    return mediaControlPaths.first { FileManager.default.fileExists(atPath: $0) }
  }

  private func parseJSONOutput(_ data: Data) -> MediaInfo? {
    debugPrint("[CLIMediaInfoProvider] Parsing JSON output...")

    guard !data.isEmpty else {
      debugPrint("[CLIMediaInfoProvider] ❌ Empty data received")
      return nil
    }

    // Debug: Print raw data as string
    if let rawString = String(data: data, encoding: .utf8) {
      debugPrint(
        "[CLIMediaInfoProvider] Raw JSON data: \(rawString.prefix(Constants.jsonPreviewLength))...")
    }

    do {
      guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {

        debugPrint("[CLIMediaInfoProvider] ❌ Failed to parse as JSON dictionary")

        return nil
      }

      debugPrint("[CLIMediaInfoProvider] ✅ Successfully parsed JSON with \(json.keys.count) keys")
      debugPrint("[CLIMediaInfoProvider] JSON keys: \(json.keys.sorted())")

      // Parse basic media information from the actual output format
      let title = json["title"] as? String
      let artist = json["artist"] as? String
      let album = json["album"] as? String
      let duration = json["duration"] as? Double ?? 0
      let elapsedTime = json["elapsedTime"] as? Double ?? 0
      let playing = json["playing"] as? Bool ?? false
      let bundleID = json["bundleIdentifier"] as? String

      debugPrint(
        "[CLIMediaInfoProvider] Parsed fields - title: \(title ?? "nil"), artist: \(artist ?? "nil"), playing: \(playing), bundleID: \(bundleID ?? "nil")"
      )

      // Try to get process ID and name from bundle identifier
      var processID = 0
      var processName = ""
      var executablePath = ""

      if let bundleID = bundleID {
        if let app = NSWorkspace.shared.runningApplications.first(where: {
          $0.bundleIdentifier == bundleID
        }) {
          processID = Int(app.processIdentifier)
          processName = app.localizedName ?? ""
          executablePath = app.executableURL?.path ?? ""

          debugPrint(
            "[CLIMediaInfoProvider] Found app info - PID: \(processID), name: \(processName)")

        } else {

          debugPrint("[CLIMediaInfoProvider] ⚠️ No running app found for bundle ID: \(bundleID)")

        }
      }

      // Handle artwork data - it's already base64 encoded in the output
      let artworkBase64 = json["artworkData"] as? String ?? ""

      debugPrint("[CLIMediaInfoProvider] Artwork data length: \(artworkBase64.count) characters")

      let mediaInfo = MediaInfo(
        name: title,
        artist: artist,
        album: album,
        image: artworkBase64,
        duration: duration,
        elapsedTime: elapsedTime,
        processID: processID,
        processName: processName,
        executablePath: executablePath,
        playing: playing,
        applicationIdentifier: bundleID
      )

      debugPrint("[CLIMediaInfoProvider] ✅ Created MediaInfo successfully")

      return mediaInfo

    } catch {

      debugPrint("[CLIMediaInfoProvider] ❌ JSON parsing error: \(error)")

      return nil
    }
  }

  // MARK: - Helper Methods

  public static func isMediaControlInstalled() -> Bool {
    let provider = CLIMediaInfoProvider()
    let path = provider.findMediaRemoteAdapter()
    // Check if media-control binary is installed
    return path != nil && FileManager.default.fileExists(atPath: path!)
  }

}
