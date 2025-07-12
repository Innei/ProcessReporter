// LegacyMediaInfoProvider.swift
// ProcessReporter
// Created by Claude on 2025/7/12.

import AppKit
import Combine
import Foundation

/// MediaInfoProvider implementation using private MediaRemote framework APIs
/// Compatible with macOS versions before 15.4
class LegacyMediaInfoProvider: MediaInfoProvider {
  
  // MARK: - Private Framework Integration
  
  // Recreating the MRContent classes in Swift
  @objc class MRContentItemMetadata: NSObject {
    @objc var playbackState: Int = 0
    @objc var bundleIdentifier: String?
  }

  @objc class MRContentItem: NSObject {
    @objc var metadata: MRContentItemMetadata?

    @objc init(nowPlayingInfo: NSDictionary) {
      super.init()
      // This is just a stub - actual initialization would be done by MediaRemote framework
    }
  }

  // Type definitions for MediaRemote framework function pointers
  typealias MRMediaRemoteGetNowPlayingInfoFunction = @convention(c) (
    DispatchQueue, @escaping (NSDictionary?) -> Void
  ) -> Void
  typealias MRMediaRemoteSetElapsedTimeFunction = @convention(c) (Double) -> Void
  typealias MRMediaRemoteGetNowPlayingApplicationIsPlayingFunction = @convention(c) (
    DispatchQueue, @escaping (Bool) -> Void
  ) -> Void
  typealias MRMediaRemoteGetNowPlayingApplicationPIDFunction = @convention(c) (
    DispatchQueue, @escaping (Int32) -> Void
  ) -> Void
  
  // MARK: - Properties
  
  private static let playingStateChangedNotificationName =
    "kMRMediaRemoteNowPlayingApplicationIsPlayingDidChangeNotification"
  private static let applicationChangedNotificationName =
    "kMRMediaRemoteNowPlayingApplicationDidChangeNotification"
  private static let infoChangedNotificationName =
    "kMRMediaRemoteNowPlayingInfoDidChangeNotification"
    
  private var cancellables = Set<AnyCancellable>()
  private var callback: MediaInfoManager.PlaybackStateChangedCallback?
  private var isFrameworkLoaded = false
  
  // MARK: - MediaInfoProvider Implementation
  
  func startMonitoring(callback: @escaping MediaInfoManager.PlaybackStateChangedCallback) {
    self.callback = callback
    loadMediaRemoteFramework()
  }
  
  func stopMonitoring() {
    cancellables.removeAll()
    callback = nil
  }
  
  func getMediaInfo() -> MediaInfo? {
    guard let nowPlayingInfo = getNowPlayingInfo() else { return nil }
    
    let name = nowPlayingInfo["name"] as? String
    let artist = nowPlayingInfo["artist"] as? String
    let elapsedTime = nowPlayingInfo["elapsedTime"] as? Double ?? 0
    let duration = nowPlayingInfo["duration"] as? Double ?? 0
    let processID = nowPlayingInfo["processID"] as? Int ?? 0
    let processName = nowPlayingInfo["processName"] as? String ?? ""
    let executablePath = nowPlayingInfo["executablePath"] as? String ?? ""
    let artworkData = nowPlayingInfo["artworkData"] as? String ?? ""
    let playing = nowPlayingInfo["isPlaying"] as? Bool ?? false
    let album = nowPlayingInfo["album"] as? String ?? ""

    let pid = pid_t(processID)
    let bundleID = AppUtility.getBundleIdentifierForPID(pid)

    return MediaInfo(
      name: name, artist: artist, album: album, image: artworkData, duration: duration,
      elapsedTime: elapsedTime, processID: processID, processName: processName,
      executablePath: executablePath, playing: playing,
      applicationIdentifier: bundleID
    )
  }
  
  // MARK: - Private Methods
  
  private func loadMediaRemoteFramework() {
    guard !isFrameworkLoaded else { return }
    
    let url = URL(fileURLWithPath: "/System/Library/PrivateFrameworks/MediaRemote.framework")
    guard CFBundleCreate(kCFAllocatorDefault, url as CFURL) != nil else {
      print("Failed to load MediaRemote framework")
      return
    }
    
    isFrameworkLoaded = true
    
    for name in [
      Self.playingStateChangedNotificationName, 
      Self.applicationChangedNotificationName,
      Self.infoChangedNotificationName,
    ] {
      NotificationCenter.default.publisher(for: Notification.Name(name)).sink { _ in
        if let callback = self.callback {
          DispatchQueue.main.async {
            guard let mediaInfo = self.getMediaInfo() else { return }
            callback(mediaInfo)
          }
        }
      }.store(in: &cancellables)
    }
  }
  
  private func getNowPlayingInfo() -> NSDictionary? {
    var result: NSDictionary?
    let group = DispatchGroup()
    group.enter()

    autoreleasepool {
      let url = URL(fileURLWithPath: "/System/Library/PrivateFrameworks/MediaRemote.framework")
      guard let bundle = CFBundleCreate(kCFAllocatorDefault, url as CFURL) else {
        group.leave()
        return
      }

      // Get function pointers from the framework
      let getMRMediaRemoteGetNowPlayingInfo = unsafeBitCast(
        CFBundleGetFunctionPointerForName(bundle, "MRMediaRemoteGetNowPlayingInfo" as CFString),
        to: MRMediaRemoteGetNowPlayingInfoFunction.self
      )

      let getMRMediaRemoteGetNowPlayingApplicationIsPlaying = unsafeBitCast(
        CFBundleGetFunctionPointerForName(
          bundle, "MRMediaRemoteGetNowPlayingApplicationIsPlaying" as CFString
        ),
        to: MRMediaRemoteGetNowPlayingApplicationIsPlayingFunction.self
      )

      let getMRMediaRemoteGetNowPlayingApplicationPID = unsafeBitCast(
        CFBundleGetFunctionPointerForName(
          bundle, "MRMediaRemoteGetNowPlayingApplicationPID" as CFString
        ),
        to: MRMediaRemoteGetNowPlayingApplicationPIDFunction.self
      )

      // Get playing status
      var isPlaying = false
      group.enter()
      getMRMediaRemoteGetNowPlayingApplicationIsPlaying(
        DispatchQueue.global(qos: .default)
      ) { playing in
        isPlaying = playing
        group.leave()
      }

      // Get application PID
      var pid: Int32 = 0
      group.enter()
      getMRMediaRemoteGetNowPlayingApplicationPID(
        DispatchQueue.global(qos: .default)
      ) { applicationPID in
        pid = applicationPID
        group.leave()
      }

      // Get now playing information
      getMRMediaRemoteGetNowPlayingInfo(
        DispatchQueue.global(qos: .default)
      ) { information in
        guard let info = information else {
          group.leave()
          return
        }

        // Create MRContentItem instance using runtime
        var item: NSObject?
        if let MRContentItemClass = objc_getClass("MRContentItem") as? AnyClass {
          // Create an instance of MRContentItem
          let allocatedItem = class_createInstance(MRContentItemClass, 0) as? NSObject

          // Call the initialization method manually
          let selector = NSSelectorFromString("initWithNowPlayingInfo:")
          if let allocatedItem = allocatedItem, allocatedItem.responds(to: selector) {
            item = allocatedItem.perform(selector, with: info)?.takeUnretainedValue() as? NSObject
          } else {
            item = nil
          }
        } else {
          item = nil
        }
        
        // Extract all the media information (same as original implementation)
        let name = info["kMRMediaRemoteNowPlayingInfoTitle"] as? String
        let artist = info["kMRMediaRemoteNowPlayingInfoArtist"] as? String
        let album = info["kMRMediaRemoteNowPlayingInfoAlbum"] as? String
        let genre = info["kMRMediaRemoteNowPlayingInfoGenre"] as? String
        let composer = info["kMRMediaRemoteNowPlayingInfoComposer"] as? String

        // Extract playback information
        let elapsedTime =
          (info["kMRMediaRemoteNowPlayingInfoElapsedTime"] as? NSNumber)?.doubleValue ?? 0
        let duration = (info["kMRMediaRemoteNowPlayingInfoDuration"] as? NSNumber)?.doubleValue ?? 0
        let playbackRate =
          (info["kMRMediaRemoteNowPlayingInfoPlaybackRate"] as? NSNumber)?.doubleValue ?? 0
        let startTime =
          (info["kMRMediaRemoteNowPlayingInfoStartTime"] as? NSNumber)?.doubleValue ?? 0

        // Extract track information
        let trackNumber = info["kMRMediaRemoteNowPlayingInfoTrackNumber"] as? NSNumber
        let totalTrackCount = info["kMRMediaRemoteNowPlayingInfoTotalTrackCount"] as? NSNumber
        let discNumber = info["kMRMediaRemoteNowPlayingInfoDiscNumber"] as? NSNumber
        let totalDiscCount = info["kMRMediaRemoteNowPlayingInfoTotalDiscCount"] as? NSNumber
        let chapterNumber = info["kMRMediaRemoteNowPlayingInfoChapterNumber"] as? NSNumber
        let totalChapterCount = info["kMRMediaRemoteNowPlayingInfoTotalChapterCount"] as? NSNumber

        // Extract queue information
        let queueIndex = info["kMRMediaRemoteNowPlayingInfoQueueIndex"] as? NSNumber
        let totalQueueCount = info["kMRMediaRemoteNowPlayingInfoTotalQueueCount"] as? NSNumber

        // Extract playback mode
        let shuffleMode = info["kMRMediaRemoteNowPlayingInfoShuffleMode"] as? NSNumber
        let repeatMode = info["kMRMediaRemoteNowPlayingInfoRepeatMode"] as? NSNumber

        // Extract miscellaneous information
        let mediaType = info["kMRMediaRemoteNowPlayingInfoMediaType"] as? String
        let isMusicApp = info["kMRMediaRemoteNowPlayingInfoIsMusicApp"] as? NSNumber
        let uniqueIdentifier = info["kMRMediaRemoteNowPlayingInfoUniqueIdentifier"] as? String
        let timestamp = info["kMRMediaRemoteNowPlayingInfoTimestamp"] as? Date

        // Extract interaction states
        let isAdvertisement = info["kMRMediaRemoteNowPlayingInfoIsAdvertisement"] as? NSNumber
        let isBanned = info["kMRMediaRemoteNowPlayingInfoIsBanned"] as? NSNumber
        let isInWishList = info["kMRMediaRemoteNowPlayingInfoIsInWishList"] as? NSNumber
        let isLiked = info["kMRMediaRemoteNowPlayingInfoIsLiked"] as? NSNumber
        let prohibitsSkip = info["kMRMediaRemoteNowPlayingInfoProhibitsSkip"] as? NSNumber

        // Extract radio information
        let radioStationIdentifier =
          info["kMRMediaRemoteNowPlayingInfoRadioStationIdentifier"] as? String
        let radioStationHash = info["kMRMediaRemoteNowPlayingInfoRadioStationHash"] as? String

        // Extract supported features
        let supportsFastForward15Seconds =
          info["kMRMediaRemoteNowPlayingInfoSupportsFastForward15Seconds"] as? NSNumber
        let supportsRewind15Seconds =
          info["kMRMediaRemoteNowPlayingInfoSupportsRewind15Seconds"] as? NSNumber
        let supportsIsBanned = info["kMRMediaRemoteNowPlayingInfoSupportsIsBanned"] as? NSNumber
        let supportsIsLiked = info["kMRMediaRemoteNowPlayingInfoSupportsIsLiked"] as? NSNumber

        // Get playback state
        var playbackState: String?
        if item?.responds(to: #selector(getter: MRContentItem.metadata)) == true,
          let metadata = item?.value(forKey: "metadata") as? NSObject,
          metadata.responds(to: #selector(getter: MRContentItemMetadata.playbackState)) == true,
          let playbackStateValue = metadata.value(forKey: "playbackState") as? NSNumber
        {
          playbackState = String(format: "%ld", playbackStateValue.intValue)
        }

        // Get bundle identifier
        var bundleIdentifier: String?
        if item?.responds(to: #selector(getter: MRContentItem.metadata)) == true,
          let metadata = item?.value(forKey: "metadata") as? NSObject,
          metadata.responds(to: #selector(getter: MRContentItemMetadata.bundleIdentifier)) == true
        {
          bundleIdentifier = metadata.value(forKey: "bundleIdentifier") as? String
        }

        // Get artwork
        let artworkData = info["kMRMediaRemoteNowPlayingInfoArtworkData"] as? Data
        let artworkMIMEType = info["kMRMediaRemoteNowPlayingInfoArtworkMIMEType"] as? String

        // Process artwork data
        var artworkBase64 = ""
        if let data = artworkData {
          if artworkMIMEType == "image/png" || artworkMIMEType == "image/jpeg" {
            artworkBase64 = data.base64EncodedString(options: [])
          } else {
            if let image = NSImage(data: data) {
              if let tiffData = image.tiffRepresentation {
                artworkBase64 = tiffData.base64EncodedString(options: [])
              }
            }
          }
        }

        // Get process information
        let app = NSRunningApplication(processIdentifier: pid)
        let processName = app?.localizedName ?? ""
        let executablePath = app?.executableURL?.path ?? ""

        // Create result dictionary
        result = [
          // Basic information
          "name": name ?? "",
          "artist": artist ?? "",
          "album": album ?? "",
          "genre": genre ?? "",
          "composer": composer ?? "",

          // Playback information
          "elapsedTime": NSNumber(value: elapsedTime),
          "duration": NSNumber(value: duration),
          "playbackRate": NSNumber(value: playbackRate),
          "startTime": NSNumber(value: startTime),
          "playbackState": playbackState ?? "",

          // Track information
          "trackNumber": trackNumber ?? 0,
          "totalTrackCount": totalTrackCount ?? 0,
          "discNumber": discNumber ?? 0,
          "totalDiscCount": totalDiscCount ?? 0,
          "chapterNumber": chapterNumber ?? 0,
          "totalChapterCount": totalChapterCount ?? 0,

          // Queue information
          "queueIndex": queueIndex ?? 0,
          "totalQueueCount": totalQueueCount ?? 0,

          // Playback mode
          "shuffleMode": shuffleMode ?? 0,
          "repeatMode": repeatMode ?? 0,

          // Miscellaneous information
          "mediaType": mediaType ?? "",
          "isMusicApp": isMusicApp ?? false,
          "uniqueIdentifier": uniqueIdentifier ?? "",
          "timestamp": timestamp ?? Date(),
          "bundleIdentifier": bundleIdentifier ?? "",

          // Interaction states
          "isAdvertisement": isAdvertisement ?? false,
          "isBanned": isBanned ?? false,
          "isInWishList": isInWishList ?? false,
          "isLiked": isLiked ?? false,
          "prohibitsSkip": prohibitsSkip ?? false,

          // Radio information
          "radioStationIdentifier": radioStationIdentifier ?? "",
          "radioStationHash": radioStationHash ?? "",

          // Supported features
          "supportsFastForward15Seconds": supportsFastForward15Seconds ?? false,
          "supportsRewind15Seconds": supportsRewind15Seconds ?? false,
          "supportsIsBanned": supportsIsBanned ?? false,
          "supportsIsLiked": supportsIsLiked ?? false,

          // Artwork
          "artworkData": artworkBase64,
          "artworkMIMEType": artworkMIMEType ?? "",

          // Playback status
          "isPlaying": NSNumber(value: isPlaying),

          // Process information
          "processID": NSNumber(value: pid),
          "processName": processName,
          "executablePath": executablePath,
        ]

        group.leave()
      }
    }

    group.wait()
    return result
  }
}