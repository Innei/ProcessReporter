//
//  MediaInfo.swift
//  ProcessReporter
//
//  Created by Innei on 2025/4/11.
//
import AppKit
import Foundation

struct MediaInfo {
	let name: String?
	let artist: String?
	let album: String?
	let image: String?
	let duration: Double
	let elapsedTime: Double
	let processID: Int
	var processName: String
	let executablePath: String
	let playing: Bool
	
	let applicationIdentifier: String?
}

func getMediaInfo() -> MediaInfo? {
	if let nowPlayingInfo = NowPlaying.getInfo() {
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
		let uniqueIdentifier = nowPlayingInfo["uniqueIdentifier"] as? String ?? ""
		
		let pid = pid_t(processID)
		let bundleID = getBundleIdentifierForPID(pid)
		 
		return MediaInfo(
			name: name, artist: artist, album: album, image: artworkData, duration: duration,
			elapsedTime: elapsedTime, processID: processID, processName: processName,
			executablePath: executablePath, playing: playing,
			applicationIdentifier: bundleID
		)
	}
	return nil
}

func getBundleIdentifierForPID(_ pid: pid_t) -> String? {
	// 根据 PID 获取 NSRunningApplication 实例
	if let runningApp = NSRunningApplication(processIdentifier: pid) {
		// 获取 Bundle Identifier
		return runningApp.bundleIdentifier
	}
	return nil
}

func getBundleIdentifierFromAuditToken(_ auditToken: audit_token_t) -> String? {
	// 使用 Security 框架的 API 获取 Bundle Identifier
	var auditToken = auditToken
	let attributes = [kSecGuestAttributeAudit: Data(bytes: &auditToken, count: MemoryLayout<audit_token_t>.size)]
	
	var code: SecCode?
	var status = SecCodeCopyGuestWithAttributes(nil, attributes as CFDictionary, [], &code)
	
	guard status == errSecSuccess, let code = code else {
		print("Failed to get SecCode: \(status)")
		return nil
	}
	
	var info: CFDictionary?
	status = SecCodeCopySigningInformation(code as! SecStaticCode, [], &info)
	
	guard status == errSecSuccess, let info = info as NSDictionary? else {
		print("Failed to get signing information: \(status)")
		return nil
	}
	
	// 从 signing information 中提取 Bundle Identifier
	if let bundleID = info[kSecCodeInfoIdentifier as String] as? String {
		return bundleID
	}
	
	return nil
}
