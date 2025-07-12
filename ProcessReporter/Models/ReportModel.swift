//
//  ReportModel.swift
//  ProcessReporter
//
//  Created by Innei on 2025/4/8.
//
import Foundation
import AppKit
import SwiftData

@Model
class ReportModel {
    @Attribute(.unique)
    var id: UUID
    
    var processName: String?
    var windowTitle: String?
    var timeStamp: Date
    
    // MARK: - Media Info
    
    var artist: String?
    var mediaName: String?
    var mediaProcessName: String?
    var mediaDuration: Double?
    var mediaElapsedTime: Double?
    
    // Store as Data instead of base64 string for efficiency
    var mediaImageData: Data?
    
    @Transient
    var mediaImage: NSImage? {
        get {
            guard let data = mediaImageData else { return nil }
            return NSImage(data: data)
        }
    }
    
    @Transient
    var mediaInfoRaw: MediaInfo?
    @Transient
    var processInfoRaw: FocusedWindowInfo?
    
    // Store integrations as Data for better performance
    @Attribute
    private var integrationsData: Data?
    
    // External interface for integrations
    var integrations: [String] {
        get {
            guard let data = integrationsData else { return [] }
            return (try? JSONDecoder().decode([String].self, from: data)) ?? []
        }
        set {
            integrationsData = try? JSONEncoder().encode(newValue)
        }
    }
    
    func setMediaInfo(_ mediaInfo: MediaInfo) {
        artist = mediaInfo.artist
        mediaName = mediaInfo.name
        mediaProcessName = mediaInfo.processName
        mediaDuration = mediaInfo.duration
        mediaElapsedTime = mediaInfo.elapsedTime
        
        // Convert base64 to Data
        if let base64 = mediaInfo.image {
            mediaImageData = Data(base64Encoded: base64)
        }
        
        mediaInfoRaw = mediaInfo
    }
    
    func setProcessInfo(_ processInfo: FocusedWindowInfo) {
        processName = processInfo.appName
        windowTitle = processInfo.title
        processInfoRaw = processInfo
    }
    
    init(
        windowInfo: FocusedWindowInfo?,
        integrations: [String],
        mediaInfo: MediaInfo?
    ) {
        id = UUID()
        processName = nil
        windowTitle = nil
        processInfoRaw = windowInfo
        
        timeStamp = .now
        integrationsData = try? JSONEncoder().encode(integrations)
        mediaInfoRaw = mediaInfo
        
        if let mediaInfo = mediaInfo {
            setMediaInfo(mediaInfo)
        }
        if let windowInfo = windowInfo {
            setProcessInfo(windowInfo)
        }
    }
}

// Computed properties for frequently accessed data
extension ReportModel {
    var hasMediaInfo: Bool {
        mediaName != nil || artist != nil
    }
    
    var hasProcessInfo: Bool {
        processName != nil
    }
    
    var displayName: String {
        if let mediaName = mediaName, !mediaName.isEmpty {
            return mediaName
        }
        return processName ?? "Unknown"
    }
    
    var subtitle: String? {
        if let artist = artist, !artist.isEmpty {
            return artist
        }
        return windowTitle
    }
}

#if DEBUG
extension ReportModel: CustomDebugStringConvertible {
    var debugDescription: String {
        return """
        ReportModel:
          Process: \(processName ?? "N/A")
          Window: \(windowTitle ?? "N/A")
          Media: \(mediaName ?? "N/A") by \(artist ?? "N/A")
          Media Process: \(mediaProcessName ?? "N/A")
          Duration: \(mediaDuration?.description ?? "N/A") / \(mediaElapsedTime?.description ?? "N/A")
          Timestamp: \(timeStamp)
          Integrations: \(integrations.joined(separator: ", "))
        """
    }
}
#endif

// Legacy version schemas - kept for reference
// Note: These are not used in the current migration plan