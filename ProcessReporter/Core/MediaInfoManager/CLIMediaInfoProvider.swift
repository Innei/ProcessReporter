// CLIMediaInfoProvider.swift
// ProcessReporter
// Created by Claude on 2025/7/12.

import Foundation
import AppKit

/// MediaInfoProvider implementation using mediaremote-adapter CLI
/// Compatible with macOS 15.4 and later
class CLIMediaInfoProvider: MediaInfoProvider {
  
  // MARK: - Properties
  
  private var timer: Timer?
  private var callback: MediaInfoManager.PlaybackStateChangedCallback?
  private var lastMediaInfo: MediaInfo?
  private var isMonitoring = false
  private let pollingInterval: TimeInterval = 1.0 // Poll every second
  
  // MARK: - MediaInfoProvider Implementation
  
  func startMonitoring(callback: @escaping MediaInfoManager.PlaybackStateChangedCallback) {
    guard !isMonitoring else { return }
    
    self.callback = callback
    self.isMonitoring = true
    
    // Get initial state immediately
    checkForMediaChanges()
    
    // Start periodic polling with timer
    timer = Timer.scheduledTimer(withTimeInterval: pollingInterval, repeats: true) { [weak self] _ in
      self?.checkForMediaChanges()
    }
  }
  
  func stopMonitoring() {
    isMonitoring = false
    timer?.invalidate()
    timer = nil
    callback = nil
    lastMediaInfo = nil
  }
  
  func getMediaInfo() -> MediaInfo? {
    return lastMediaInfo
  }
  
  deinit {
    stopMonitoring()
  }
  
  // MARK: - Private Methods
  
  private func checkForMediaChanges() {
    // Execute CLI asynchronously to avoid blocking the timer
    executeMediaRemoteAdapterAsync { [weak self] mediaInfo in
      guard let self = self else { return }
      
      // Check if this is a significant change
      let hasChanged = self.hasSignificantChange(from: self.lastMediaInfo, to: mediaInfo)
      
      self.lastMediaInfo = mediaInfo
      
      if hasChanged, let mediaInfo = mediaInfo {
        DispatchQueue.main.async {
          self.callback?(mediaInfo)
        }
      }
    }
  }
  
  private func executeMediaRemoteAdapterAsync(completion: @escaping (MediaInfo?) -> Void) {
    DispatchQueue.global(qos: .utility).async { [weak self] in
      guard let self = self else {
        completion(nil)
        return
      }
      
      // Find the mediaremote-adapter executable
      guard let executablePath = self.findMediaRemoteAdapter() else {
        print("mediaremote-adapter not found")
        completion(nil)
        return
      }
      
      let process = Process()
      let pipe = Pipe()
      
      // Configure process for 'get' mode
      if executablePath.hasSuffix(".pl") {
        process.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        let frameworkPath = "/opt/homebrew/Frameworks/MediaRemoteAdapter.framework"
        process.arguments = [executablePath, frameworkPath, "get"]
      } else {
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = ["--format", "json"]
      }
      
      process.standardOutput = pipe
      process.standardError = Pipe() // Suppress errors
      
      do {
        try process.run()
        
        // Set up timeout to prevent hanging
        let timeoutTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: false) { _ in
          if process.isRunning {
            process.terminate()
            completion(nil)
          }
        }
        
        // Use terminationHandler for async completion
        process.terminationHandler = { process in
          timeoutTimer.invalidate()
          
          guard process.terminationStatus == 0 else {
            print("mediaremote-adapter failed with status: \(process.terminationStatus)")
            completion(nil)
            return
          }
          
          let data = pipe.fileHandleForReading.readDataToEndOfFile()
          let mediaInfo = self.parseJSONOutput(data)
          completion(mediaInfo)
        }
        
      } catch {
        print("Failed to execute mediaremote-adapter: \(error)")
        completion(nil)
      }
    }
  }
  
  private func hasSignificantChange(from old: MediaInfo?, to new: MediaInfo?) -> Bool {
    guard let old = old, let new = new else { 
      return new != nil // Return true if we have new data
    }
    
    return old.name != new.name ||
           old.artist != new.artist ||
           old.playing != new.playing ||
           abs(old.elapsedTime - new.elapsedTime) > 2.0
  }
  
  private func findMediaRemoteAdapter() -> String? {
    let possiblePaths = [
      "/usr/local/bin/mediaremote-adapter",
      "/opt/homebrew/bin/mediaremote-adapter", 
      "/opt/homebrew/Cellar/media-control/0.4.0/lib/media-control/mediaremote-adapter.pl"
    ]
    
    return possiblePaths.first { FileManager.default.fileExists(atPath: $0) }
  }
  
  
  private func parseJSONOutput(_ data: Data) -> MediaInfo? {
    do {
      guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        return nil
      }
      
      // Parse basic media information from the actual output format
      let title = json["title"] as? String
      let artist = json["artist"] as? String
      let album = json["album"] as? String
      let duration = json["duration"] as? Double ?? 0
      let elapsedTime = json["elapsedTime"] as? Double ?? 0
      let playing = json["playing"] as? Bool ?? false
      
      // Get application information
      let bundleID = json["bundleIdentifier"] as? String
      
      // Try to get process ID and name from bundle identifier
      var processID = 0
      var processName = ""
      var executablePath = ""
      
      if let bundleID = bundleID {
        if let app = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == bundleID }) {
          processID = Int(app.processIdentifier)
          processName = app.localizedName ?? ""
          executablePath = app.executableURL?.path ?? ""
        }
      }
      
      // Handle artwork data - it's already base64 encoded in the output
      let artworkBase64 = json["artworkData"] as? String ?? ""
      
      return MediaInfo(
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
      
    } catch {
      print("Failed to parse JSON from mediaremote-adapter: \(error)")
      return nil
    }
  }
  
  // MARK: - Helper Methods
  
  private func findInBrewCellar() -> [String]? {
    let cellarBase = "/opt/homebrew/Cellar/media-control"
    
    guard FileManager.default.fileExists(atPath: cellarBase) else {
      return nil
    }
    
    do {
      let versions = try FileManager.default.contentsOfDirectory(atPath: cellarBase)
      var paths: [String] = []
      
      for version in versions {
        let adapterPath = "\(cellarBase)/\(version)/lib/media-control/mediaremote-adapter.pl"
        if FileManager.default.fileExists(atPath: adapterPath) {
          paths.append(adapterPath)
        }
      }
      
      return paths.isEmpty ? nil : paths
    } catch {
      print("Failed to search brew cellar: \(error)")
      return nil
    }
  }
}