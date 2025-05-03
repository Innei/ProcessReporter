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
    var timeStamp: Date

    // MARK: - Media Info

    var artist: String?
    var mediaName: String?
    var mediaProcessName: String?
    var mediaDuration: Double?
    var mediaElapsedTime: Double?

    @Transient
    var mediaImage: NSImage?
    @Transient
    var mediaInfoRaw: MediaInfo?
    @Transient
    var processInfoRaw: FocusedWindowInfo?

    // 持久化字段：存储 JSON 字符串
    @Attribute
    private var integrationsRaw: String

    // 外部使用的 [String] 接口
    var integrations: [String] {
        get {
            (try? JSONDecoder().decode([String].self, from: Data(integrationsRaw.utf8))) ?? []
        }
        set {
            integrationsRaw =
                (try? JSONEncoder().encode(newValue)).flatMap { String(data: $0, encoding: .utf8) }
                ?? "[]"
        }
    }

    func setMediaInfo(_ mediaInfo: MediaInfo) {
        artist = mediaInfo.artist
        mediaName = mediaInfo.name
        mediaProcessName = mediaInfo.processName
        mediaDuration = mediaInfo.duration
        mediaElapsedTime = mediaInfo.elapsedTime
        if let base64 = mediaInfo.image, let data = Data(base64Encoded: base64) {
            mediaImage = NSImage(data: data)
        }
        mediaInfoRaw = mediaInfo
    }

    func setProcessInfo(_ processInfo: FocusedWindowInfo) {
        processName = processInfo.appName
        processInfoRaw = processInfo
    }

    init(
        windowInfo: FocusedWindowInfo?,
        integrations: [String],
        mediaInfo: MediaInfo?
    ) {
        id = UUID()
        processName = nil
        processInfoRaw = windowInfo

        timeStamp = .now
        integrationsRaw =
            (try? JSONEncoder().encode(integrations)).flatMap { String(data: $0, encoding: .utf8) }
            ?? "[]"
        mediaInfoRaw = mediaInfo

        if let mediaInfo = mediaInfo {
            setMediaInfo(mediaInfo)
        }
        if let windowInfo = windowInfo {
            setProcessInfo(windowInfo)
        }
    }
}

#if DEBUG
    extension ReportModel: CustomDebugStringConvertible {
        var debugDescription: String {
            return "Process Name: \(processName)\n"
                + "Process Title: \(processInfoRaw?.title ?? "N/A")\n"
                + "Artist: \(artist ?? "N/A")\n" + "Media Name: \(mediaName ?? "N/A")\n"
                + "Media Process Name: \(mediaProcessName ?? "N/A")\n"
                + "Media Duration: \(mediaDuration?.description ?? "N/A")\n"
                + "Media Elapsed Time: \(mediaElapsedTime?.description ?? "N/A")\n"
                + "Timestamp: \(timeStamp)\n"
        }
    }

#endif

enum ReportModelV1: VersionedSchema {
    static var versionIdentifier = Schema.Version(1, 0, 0)

    static var models: [any PersistentModel.Type] {
        [ReportModel.self]
    }
}
