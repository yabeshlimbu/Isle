import AppKit

/// Reads and controls media playback across all macOS applications
/// (Safari, YouTube, Chrome, Spotify, Apple Music, QuickTime, TV, etc.).
///
/// Sources, in order of preference:
///  1. A long-lived helper script run by the system Swift interpreter that
///     talks to MediaRemote and streams one JSON line per update.  (Newer
///     macOS versions only answer MediaRemote queries from Apple-signed
///     processes, which is why this isn't done in-process.)
///  2. MediaRemote in-process (works on older macOS versions).
///  3. AppleScript for Music and Spotify.
final class NowPlaying: ObservableObject {
    enum Source { case mediaRemote, appleScript }

    struct Track: Equatable {
        var title: String
        var artist: String
        var position: Double
        var duration: Double
        var playing: Bool
        var bundleID: String
        var pid: pid_t?
        var source: Source
    }

    @Published private(set) var track: Track?
    @Published private(set) var artwork: NSImage?
    @Published private(set) var permissionDenied = false

    private static let appleScriptPlayers = ["com.spotify.client", "com.apple.Music"]

    private let mr = MediaRemoteBridge()
    private let scriptQueue = DispatchQueue(label: "isle.nowplaying.applescript", qos: .userInitiated)
    private var scripts: [String: NSAppleScript] = [:]   // touched only on scriptQueue
    private var timer: Timer?
    private var scriptInFlight = false
    private var mrInFlight = false

    private var artworkData: Data?
    /// Ignore incoming updates briefly after a command so the optimistic UI doesn't flicker back.
    private var ignoreUpdatesUntil = Date.distantPast

    // Helper process
    private var agent: Process?
    private var agentInput: FileHandle?
    private var agentBuffer = Data()
    private var agentFailures = 0
    private var agentDisabled = false
    private var lastAgentLine = Date.distantPast

    private let scriptURL: URL = {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Isle", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("media_agent.swift")
    }()

    func start() {
        guard timer == nil else { return }
        try? Self.agentSource.write(to: scriptURL, atomically: true, encoding: .utf8)
        startAgent()
        let t = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        tick()
    }

    /// Ask for fresh information now (e.g. when the island opens).
    func refresh() {
        if agentRunning {
            sendToAgent("query")
        } else {
            tick()
        }
    }

    private var agentRunning: Bool { agent?.isRunning == true }

    private func tick() {
        if agentRunning {
            // The helper pushes updates itself; only step in if it has gone quiet.
            if Date().timeIntervalSince(lastAgentLine) > 6 { agent?.terminate() }
            return
        }
        guard !mrInFlight else { return }
        guard mr.isAvailable else { return queryAppleScriptPlayers() }
        mrInFlight = true
        mr.fetchInfo { [weak self] info in
            guard let self else { return }
            self.mrInFlight = false
            guard let info else { return self.queryAppleScriptPlayers() }
            self.publish(Track(title: info.title, artist: info.artist, position: info.position,
                               duration: info.duration, playing: info.isPlaying,
                               bundleID: info.bundleID, pid: info.pid > 0 ? info.pid : nil,
                               source: .mediaRemote),
                         artwork: .some(info.artworkData))
        }
    }

    // MARK: Publishing

    /// `artwork`: `.none` keeps the current artwork, `.some(nil)` clears it.
    private func publish(_ new: Track?, artwork newArt: Data?? = .none) {
        if Date() < ignoreUpdatesUntil { return }
        if case .some(let data) = newArt, data != artworkData {
            artworkData = data
            artwork = data.flatMap { NSImage(data: $0) }
        }
        if new == nil, artworkData != nil {
            artworkData = nil
            artwork = nil
        }
        if track != new { track = new }
        if new != nil, permissionDenied { permissionDenied = false }
    }

    // MARK: Helper process

    /// The system Swift interpreter, if developer tools are installed.
    /// (Running /usr/bin/swift without them pops up an install dialog.)
    private func swiftAvailable() -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/xcode-select")
        p.arguments = ["-p"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return false }
        p.waitUntilExit()
        guard p.terminationStatus == 0,
              let dir = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines), !dir.isEmpty else { return false }
        let fm = FileManager.default
        return fm.fileExists(atPath: dir + "/usr/bin/swift")
            || fm.fileExists(atPath: dir + "/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift")
    }

    private func startAgent() {
        guard !agentDisabled, agent == nil else { return }
        guard swiftAvailable() else { agentDisabled = true; return }

        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/swift")
        p.arguments = [scriptURL.path]
        let output = Pipe(), input = Pipe()
        p.standardOutput = output
        p.standardInput = input
        p.standardError = FileHandle.nullDevice

        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil; return }
            DispatchQueue.main.async { self?.consume(data) }
        }
        p.terminationHandler = { [weak self] proc in
            DispatchQueue.main.async { self?.agentExited(proc) }
        }
        do {
            try p.run()
        } catch {
            agentDisabled = true
            return
        }
        agent = p
        agentInput = input.fileHandleForWriting
        agentBuffer.removeAll()
        lastAgentLine = Date()   // give it time to compile before calling it stuck
            .addingTimeInterval(20)
    }

    private func agentExited(_ proc: Process) {
        guard proc === agent else { return }
        agent = nil
        agentInput = nil
        agentFailures += 1
        if agentFailures >= 5 { agentDisabled = true; return }   // fall back to in-process / AppleScript
        DispatchQueue.main.asyncAfter(deadline: .now() + Double(agentFailures) * 3) { [weak self] in
            self?.startAgent()
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        agentDisabled = true
        agentInput = nil   // closing stdin makes the helper exit
        agent?.terminate()
        agent = nil
    }

    private func sendToAgent(_ line: String) {
        guard let agentInput, let data = (line + "\n").data(using: .utf8) else { return }
        try? agentInput.write(contentsOf: data)
    }

    private func consume(_ data: Data) {
        agentBuffer.append(data)
        while let nl = agentBuffer.firstIndex(of: 0x0A) {
            let line = agentBuffer[agentBuffer.startIndex..<nl]
            agentBuffer.removeSubrange(agentBuffer.startIndex...nl)
            handleAgentLine(Data(line))
        }
    }

    private func handleAgentLine(_ line: Data) {
        guard let json = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { return }
        lastAgentLine = Date()
        agentFailures = 0

        if json["unavailable"] as? Bool == true {
            // MediaRemote can't be loaded at all; stop trying.
            agentDisabled = true
            agentInput = nil
            agent?.terminate()
            return
        }

        guard let title = json["title"] as? String, !title.isEmpty else {
            return queryAppleScriptPlayers()   // MediaRemote has nothing: try Music / Spotify
        }

        var art: Data?? = .none
        if let b64 = json["artwork"] as? String {
            art = .some(b64.isEmpty ? nil : Data(base64Encoded: b64))
        }
        let pid = (json["pid"] as? NSNumber)?.int32Value ?? 0
        publish(Track(title: title,
                      artist: json["artist"] as? String ?? "",
                      position: (json["position"] as? NSNumber)?.doubleValue ?? 0,
                      duration: (json["duration"] as? NSNumber)?.doubleValue ?? 0,
                      playing: json["playing"] as? Bool ?? false,
                      bundleID: json["bundleID"] as? String ?? "",
                      pid: pid > 0 ? pid : nil,
                      source: .mediaRemote),
                artwork: art)
    }

    // MARK: AppleScript fallback (Music / Spotify)

    private func queryAppleScriptPlayers() {
        guard !scriptInFlight else { return }
        let running = Self.appleScriptPlayers.filter {
            !NSRunningApplication.runningApplications(withBundleIdentifier: $0).isEmpty
        }
        if running.isEmpty {
            publish(nil)
            if permissionDenied { permissionDenied = false }
            return
        }
        scriptInFlight = true
        scriptQueue.async { [weak self] in
            guard let self else { return }
            var best: Track?
            var denied = false
            for id in running {
                switch self.queryAppleScript(id) {
                case .track(let t):
                    if t.playing || best == nil { best = t }
                case .denied:
                    denied = true
                case .nothing:
                    break
                }
                if best?.playing == true { break }
            }
            DispatchQueue.main.async {
                self.scriptInFlight = false
                self.publish(best, artwork: .some(nil))
                let d = denied && best == nil
                if self.permissionDenied != d { self.permissionDenied = d }
            }
        }
    }

    private enum ScriptResult { case track(Track), denied, nothing }

    private func queryAppleScript(_ id: String) -> ScriptResult {
        let script: NSAppleScript
        if let cached = scripts[id] {
            script = cached
        } else {
            // `is running` guard: never relaunch a player that just quit.
            let source = """
            if application id "\(id)" is running then
                tell application id "\(id)"
                    if player state is stopped then return ""
                    set t to current track
                    if player state is playing then
                        set s to "1"
                    else
                        set s to "0"
                    end if
                    return s & linefeed & (name of t) & linefeed & (artist of t) & linefeed & (player position as string) & linefeed & ((duration of t) as string)
                end tell
            end if
            return ""
            """
            guard let s = NSAppleScript(source: source) else { return .nothing }
            scripts[id] = s
            script = s
        }

        var error: NSDictionary?
        let output = script.executeAndReturnError(&error)
        if let error {
            return (error[NSAppleScript.errorNumber] as? Int) == -1743 ? .denied : .nothing
        }
        guard let text = output.stringValue, !text.isEmpty else { return .nothing }
        let parts = text.components(separatedBy: "\n")
        guard parts.count >= 5 else { return .nothing }

        func number(_ s: String) -> Double { Double(s.replacingOccurrences(of: ",", with: ".")) ?? 0 }
        var duration = number(parts[4])
        if id == "com.spotify.client" { duration /= 1000 }
        return .track(Track(title: parts[1], artist: parts[2], position: number(parts[3]),
                            duration: duration, playing: parts[0] == "1",
                            bundleID: id, pid: nil, source: .appleScript))
    }

    // MARK: Controls

    func openApp() {
        if let pid = track?.pid, let app = NSRunningApplication(processIdentifier: pid) {
            app.activate()
        } else if let id = track?.bundleID, !id.isEmpty,
                  let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) {
            NSWorkspace.shared.openApplication(at: url, configuration: .init())
        }
    }

    func playPause() {
        guard track != nil else { return }
        track?.playing.toggle()   // optimistic
        send(agent: "toggle", mr: .togglePlayPause, appleScript: "playpause")
    }

    func next() { send(agent: "next", mr: .nextTrack, appleScript: "next track") }
    func previous() { send(agent: "prev", mr: .previousTrack, appleScript: "previous track") }

    /// Send a command exactly once, through the channel that owns the current track.
    private func send(agent cmd: String, mr command: MediaRemoteBridge.Command, appleScript: String) {
        ignoreUpdatesUntil = Date().addingTimeInterval(0.45)
        if let t = track, t.source == .appleScript {
            let id = t.bundleID
            scriptQueue.async {
                _ = NSAppleScript(source: "tell application id \"\(id)\" to \(appleScript)")?
                    .executeAndReturnError(nil)
            }
        } else if agentRunning {
            sendToAgent(cmd)
        } else {
            mr.send(command)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.refresh() }
    }

    // MARK: Helper source

    private static let agentSource = ##"""
    import AppKit
    import Foundation

    typealias InfoBlock = @convention(block) (CFDictionary?) -> Void
    typealias PIDBlock = @convention(block) (pid_t) -> Void

    setvbuf(stdout, nil, _IOLBF, 0)

    guard let bundle = CFBundleCreate(kCFAllocatorDefault, NSURL(fileURLWithPath: "/System/Library/PrivateFrameworks/MediaRemote.framework")),
          let infoPtr = CFBundleGetFunctionPointerForName(bundle, "MRMediaRemoteGetNowPlayingInfo" as CFString),
          let pidPtr = CFBundleGetFunctionPointerForName(bundle, "MRMediaRemoteGetNowPlayingApplicationPID" as CFString),
          let cmdPtr = CFBundleGetFunctionPointerForName(bundle, "MRMediaRemoteSendCommand" as CFString) else {
        print("{\"unavailable\":true}")
        exit(0)
    }
    let getInfo = unsafeBitCast(infoPtr, to: (@convention(c) (DispatchQueue, @escaping InfoBlock) -> Void).self)
    let getPID = unsafeBitCast(pidPtr, to: (@convention(c) (DispatchQueue, @escaping PIDBlock) -> Void).self)
    let sendCommand = unsafeBitCast(cmdPtr, to: (@convention(c) (Int32, AnyObject?) -> Bool).self)
    if let regPtr = CFBundleGetFunctionPointerForName(bundle, "MRMediaRemoteRegisterForNowPlayingNotifications" as CFString) {
        let register = unsafeBitCast(regPtr, to: (@convention(c) (DispatchQueue) -> Void).self)
        register(.main)
    }

    var lastArtwork: Data?
    var queryStarted: Date?
    var pending = false

    func emit(_ obj: [String: Any]) {
        if let data = try? JSONSerialization.data(withJSONObject: obj),
           let line = String(data: data, encoding: .utf8) {
            print(line)
        }
    }

    func handle(pid: pid_t, _ dict: [String: Any]?) {
        guard let dict, !dict.isEmpty else {
            lastArtwork = nil
            print("{}")
            return
        }
        var title = dict["kMRMediaRemoteNowPlayingInfoTitle"] as? String ?? ""
        var artist = dict["kMRMediaRemoteNowPlayingInfoArtist"] as? String ?? ""
        let duration = (dict["kMRMediaRemoteNowPlayingInfoDuration"] as? NSNumber)?.doubleValue ?? 0
        var position = (dict["kMRMediaRemoteNowPlayingInfoElapsedTime"] as? NSNumber)?.doubleValue ?? 0
        let rate = (dict["kMRMediaRemoteNowPlayingInfoPlaybackRate"] as? NSNumber)?.doubleValue ?? 0

        if let ts = dict["kMRMediaRemoteNowPlayingInfoTimestamp"] as? Date, rate > 0 {
            position += Date().timeIntervalSince(ts) * rate
        }
        if duration > 0 { position = max(0, min(position, duration)) }
        if title.hasSuffix(" - YouTube") { title = String(title.dropLast(10)) }
        title = title.replacingOccurrences(of: #"^\(\d+\)\s*"#, with: "", options: .regularExpression)

        var appName = "Media"
        var bundleID = ""
        var ownerPID = pid
        if pid > 0, let app = NSRunningApplication(processIdentifier: pid) {
            appName = app.localizedName ?? "Media"
            bundleID = app.bundleIdentifier ?? ""
            // Media often plays in a helper process: report the real app instead.
            if bundleID.hasPrefix("com.apple.WebKit") {
                bundleID = "com.apple.Safari"
                appName = "Safari"
                ownerPID = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first?.processIdentifier ?? 0
            } else if let path = app.bundleURL?.path, let r = path.range(of: ".app/"),
                      let outer = Bundle(path: String(path[..<r.lowerBound]) + ".app"),
                      let outerID = outer.bundleIdentifier {
                bundleID = outerID
                appName = (outer.infoDictionary?["CFBundleDisplayName"] ?? outer.infoDictionary?["CFBundleName"]) as? String ?? appName
                ownerPID = NSRunningApplication.runningApplications(withBundleIdentifier: outerID).first?.processIdentifier ?? 0
            }
        }
        if artist.isEmpty || artist.hasSuffix("Graphics and Media") { artist = appName }
        if title.isEmpty && rate > 0 { title = "Media Playing" }

        var obj: [String: Any] = [
            "title": title, "artist": artist, "duration": duration, "position": position,
            "playing": rate > 0, "bundleID": bundleID, "pid": ownerPID,
        ]
        // Artwork is large: only send it when it changes.
        let art = dict["kMRMediaRemoteNowPlayingInfoArtworkData"] as? Data
        if art != lastArtwork {
            obj["artwork"] = art?.base64EncodedString() ?? ""
            lastArtwork = art
        }
        emit(obj)
    }

    func query() {
        if let started = queryStarted, Date().timeIntervalSince(started) < 3 {
            pending = true
            return
        }
        queryStarted = Date()
        getPID(.main) { pid in
            getInfo(.main) { raw in
                handle(pid: pid, raw as? [String: Any])
                queryStarted = nil
                if pending { pending = false; query() }
            }
        }
    }

    // Commands arrive on stdin; when Isle quits the pipe closes and we exit too.
    Thread {
        while let line = readLine() {
            let cmd = line.trimmingCharacters(in: .whitespaces)
            DispatchQueue.main.async {
                switch cmd {
                case "toggle": _ = sendCommand(2, nil)
                case "next": _ = sendCommand(4, nil)
                case "prev": _ = sendCommand(5, nil)
                default: break
                }
                query()
            }
        }
        exit(0)
    }.start()

    for name in ["kMRMediaRemoteNowPlayingInfoDidChangeNotification",
                 "kMRMediaRemoteNowPlayingApplicationIsPlayingDidChangeNotification",
                 "kMRMediaRemoteNowPlayingApplicationDidChangeNotification"] {
        NotificationCenter.default.addObserver(forName: NSNotification.Name(name), object: nil, queue: .main) { _ in query() }
    }
    let timer = Timer(timeInterval: 1.0, repeats: true) { _ in
        if getppid() == 1 { exit(0) }
        query()
    }
    RunLoop.main.add(timer, forMode: .common)
    query()
    RunLoop.main.run()
    """##
}
