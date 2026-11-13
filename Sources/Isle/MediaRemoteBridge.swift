import AppKit
import Foundation

/// Bridge to macOS's private MediaRemote framework to capture system-wide now playing info
/// and control playback in any app (Safari, YouTube, Chrome, Spotify, Apple Music, QuickTime, etc.).
final class MediaRemoteBridge {
    typealias MRGetInfoBlock = @convention(block) (CFDictionary?) -> Void
    typealias MRPIDBlock = @convention(block) (pid_t) -> Void

    enum Command: Int32 {
        case play = 0
        case pause = 1
        case togglePlayPause = 2
        case stop = 3
        case nextTrack = 4
        case previousTrack = 5
    }

    private var getNowPlayingInfo: (@convention(c) (DispatchQueue, @escaping MRGetInfoBlock) -> Void)?
    private var getNowPlayingPID: (@convention(c) (DispatchQueue, @escaping MRPIDBlock) -> Void)?
    private var sendCommand: (@convention(c) (Int32, AnyObject?) -> Bool)?

    private(set) var isAvailable = false

    init() {
        guard let bundle = CFBundleCreate(kCFAllocatorDefault, NSURL(fileURLWithPath: "/System/Library/PrivateFrameworks/MediaRemote.framework")) else {
            return
        }

        if let ptr = CFBundleGetFunctionPointerForName(bundle, "MRMediaRemoteGetNowPlayingInfo" as CFString) {
            getNowPlayingInfo = unsafeBitCast(ptr, to: (@convention(c) (DispatchQueue, @escaping MRGetInfoBlock) -> Void).self)
        }
        if let ptr = CFBundleGetFunctionPointerForName(bundle, "MRMediaRemoteGetNowPlayingApplicationPID" as CFString) {
            getNowPlayingPID = unsafeBitCast(ptr, to: (@convention(c) (DispatchQueue, @escaping MRPIDBlock) -> Void).self)
        }
        if let ptr = CFBundleGetFunctionPointerForName(bundle, "MRMediaRemoteSendCommand" as CFString) {
            sendCommand = unsafeBitCast(ptr, to: (@convention(c) (Int32, AnyObject?) -> Bool).self)
        }

        isAvailable = (getNowPlayingInfo != nil && sendCommand != nil)
    }

    @discardableResult
    func send(_ command: Command) -> Bool {
        sendCommand?(command.rawValue, nil) ?? false
    }

    struct MediaInfo {
        let pid: pid_t
        let bundleID: String
        let appName: String
        let title: String
        let artist: String
        let album: String
        let position: Double
        let duration: Double
        let isPlaying: Bool
        let artworkData: Data?
    }

    func fetchInfo(queue: DispatchQueue = .main, completion: @escaping (MediaInfo?) -> Void) {
        guard let getPID = getNowPlayingPID,
              let getInfo = getNowPlayingInfo else {
            completion(nil)
            return
        }

        // Ask for the PID first so the info callback always knows which app it belongs to.
        getPID(queue) { currentPID in
        getInfo(queue) { rawDict in
            guard let dict = rawDict as? [String: Any] else {
                completion(nil)
                return
            }

            var title = dict["kMRMediaRemoteNowPlayingInfoTitle"] as? String ?? ""
            var artist = dict["kMRMediaRemoteNowPlayingInfoArtist"] as? String ?? ""
            let album = dict["kMRMediaRemoteNowPlayingInfoAlbum"] as? String ?? ""
            let duration = (dict["kMRMediaRemoteNowPlayingInfoDuration"] as? NSNumber)?.doubleValue ?? 0
            var position = (dict["kMRMediaRemoteNowPlayingInfoElapsedTime"] as? NSNumber)?.doubleValue ?? 0
            let rate = (dict["kMRMediaRemoteNowPlayingInfoPlaybackRate"] as? NSNumber)?.doubleValue ?? 0

            if let timestamp = dict["kMRMediaRemoteNowPlayingInfoTimestamp"] as? Date, rate > 0 {
                position += Date().timeIntervalSince(timestamp) * rate
            }

            if duration > 0 {
                position = max(0, min(position, duration))
            }

            if title.hasSuffix(" - YouTube") {
                title = String(title.dropLast(10))
            }
            if title.range(of: #"^\(\d+\)\s*"#, options: .regularExpression) != nil {
                title = title.replacingOccurrences(of: #"^\(\d+\)\s*"#, with: "", options: .regularExpression)
            }

            let app = NSRunningApplication(processIdentifier: currentPID)
            let bundleID = app?.bundleIdentifier ?? ""
            let appName = app?.localizedName ?? "Media"

            if artist.isEmpty {
                artist = appName
            }

            let artworkData = dict["kMRMediaRemoteNowPlayingInfoArtworkData"] as? Data
            let isPlaying = rate > 0

            guard !title.isEmpty || isPlaying else {
                completion(nil)
                return
            }

            let info = MediaInfo(
                pid: currentPID,
                bundleID: bundleID,
                appName: appName,
                title: title.isEmpty ? "Media Playing" : title,
                artist: artist,
                album: album,
                position: position,
                duration: duration,
                isPlaying: isPlaying,
                artworkData: artworkData
            )
            completion(info)
        }
        }
    }
}
