import AppKit
import Foundation

typealias MRGetInfoBlock = @convention(block) (CFDictionary?) -> Void
typealias MRPIDBlock = @convention(block) (pid_t) -> Void

guard let bundle = CFBundleCreate(kCFAllocatorDefault, NSURL(fileURLWithPath: "/System/Library/PrivateFrameworks/MediaRemote.framework")),
      let getInfoPtr = CFBundleGetFunctionPointerForName(bundle, "MRMediaRemoteGetNowPlayingInfo" as CFString),
      let getPIDPtr = CFBundleGetFunctionPointerForName(bundle, "MRMediaRemoteGetNowPlayingApplicationPID" as CFString),
      let sendCommandPtr = CFBundleGetFunctionPointerForName(bundle, "MRMediaRemoteSendCommand" as CFString),
      let regPtr = CFBundleGetFunctionPointerForName(bundle, "MRMediaRemoteRegisterForNowPlayingNotifications" as CFString) else {
    exit(1)
}

let getInfo = unsafeBitCast(getInfoPtr, to: (@convention(c) (DispatchQueue, @escaping MRGetInfoBlock) -> Void).self)
let getPID = unsafeBitCast(getPIDPtr, to: (@convention(c) (DispatchQueue, @escaping MRPIDBlock) -> Void).self)
let sendCommand = unsafeBitCast(sendCommandPtr, to: (@convention(c) (Int32, AnyObject?) -> Bool).self)
let registerNotifications = unsafeBitCast(regPtr, to: (@convention(c) (DispatchQueue) -> Void).self)

// Handle CLI command invocation
if CommandLine.arguments.count > 1 {
    let cmd = CommandLine.arguments[1]
    if cmd == "toggle" { _ = sendCommand(2, nil) }
    else if cmd == "next" { _ = sendCommand(4, nil) }
    else if cmd == "prev" { _ = sendCommand(5, nil) }
    exit(0)
}

let appSupport = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Isle")
try? FileManager.default.createDirectory(at: appSupport, withIntermediateDirectories: true)
let jsonURL = appSupport.appendingPathComponent("nowplaying.json")

registerNotifications(.main)

var currentPID: pid_t = 0
var inFlight = false

func query() {
    guard !inFlight else { return }
    inFlight = true

    getPID(.main) { pid in
        currentPID = pid
    }

    getInfo(.main) { dict in
        inFlight = false
        guard let dict = dict as? [String: Any] else {
            try? "{}".write(to: jsonURL, atomically: true, encoding: .utf8)
            return
        }

        var title = dict["kMRMediaRemoteNowPlayingInfoTitle"] as? String ?? ""
        var artist = dict["kMRMediaRemoteNowPlayingInfoArtist"] as? String ?? ""
        let album = dict["kMRMediaRemoteNowPlayingInfoAlbum"] as? String ?? ""
        let duration = (dict["kMRMediaRemoteNowPlayingInfoDuration"] as? NSNumber)?.doubleValue ?? 0
        var position = (dict["kMRMediaRemoteNowPlayingInfoElapsedTime"] as? NSNumber)?.doubleValue ?? 0
        let rate = (dict["kMRMediaRemoteNowPlayingInfoPlaybackRate"] as? NSNumber)?.doubleValue ?? 0

        if let ts = dict["kMRMediaRemoteNowPlayingInfoTimestamp"] as? Date, rate > 0 {
            position += Date().timeIntervalSince(ts) * rate
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

        var appName = "Media"
        var bundleID = ""
        if currentPID > 0, let app = NSRunningApplication(processIdentifier: currentPID) {
            appName = app.localizedName ?? "Media"
            bundleID = app.bundleIdentifier ?? ""
        }
        if artist.isEmpty { artist = appName }

        var base64Artwork: String? = nil
        if let data = dict["kMRMediaRemoteNowPlayingInfoArtworkData"] as? Data {
            base64Artwork = data.base64EncodedString()
        }

        let obj: [String: Any] = [
            "title": title,
            "artist": artist,
            "album": album,
            "duration": duration,
            "position": position,
            "playing": rate > 0,
            "bundleID": bundleID,
            "appName": appName,
            "artwork": base64Artwork as Any,
            "pid": currentPID
        ]

        if let jsonData = try? JSONSerialization.data(withJSONObject: obj) {
            try? jsonData.write(to: jsonURL, options: .atomic)
        }
    }
}

// Check every 0.75s to advance playback position and catch transitions
let timer = Timer(timeInterval: 0.75, repeats: true) { _ in
    // Exit if orphaned
    if getppid() == 1 {
        exit(0)
    }
    query()
}
RunLoop.main.add(timer, forMode: .common)

let notifs = [
    "kMRMediaRemoteNowPlayingInfoDidChangeNotification",
    "kMRMediaRemoteNowPlayingApplicationIsPlayingDidChangeNotification",
    "kMRMediaRemoteNowPlayingApplicationDidChangeNotification"
]
for n in notifs {
    NotificationCenter.default.addObserver(forName: NSNotification.Name(n), object: nil, queue: .main) { _ in
        query()
    }
}

query()
RunLoop.main.run()

