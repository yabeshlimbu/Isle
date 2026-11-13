import AppKit
import ApplicationServices
import Combine

// MARK: - Activity circles

/// Something running in the background that gets its own little circle beside the notch,
/// so the notch itself stays free for music.
enum ActivityKind: Hashable {
    case keepAwake, meeting   // left of the notch
    case timer, download      // right of the notch
}

/// Decides which circles are showing.
final class ActivityCenter: ObservableObject {
    @Published private(set) var left: [ActivityKind] = []
    @Published private(set) var right: [ActivityKind] = []
    /// The meeting that starts within 15 minutes (or started under 5 minutes ago).
    @Published private(set) var meeting: CalendarModel.Event?

    static let meetingLead: TimeInterval = 15 * 60
    private var cancellables = Set<AnyCancellable>()

    init(keepAwake: KeepAwake, timer: TimerModel, downloads: DownloadMonitor, calendar: CalendarModel) {
        let meetingTick = Timer.publish(every: 5, on: .main, in: .common).autoconnect().map { _ in () }
            .prepend(())
        Publishers.CombineLatest(calendar.$events, meetingTick)
            .map { events, _ in Self.upcoming(in: events) }
            .removeDuplicates()
            .assign(to: &$meeting)

        Publishers.CombineLatest4(keepAwake.$isOn, $meeting.map { $0 != nil }, timer.$isActive, downloads.$visible)
            .sink { [weak self] awake, meeting, timer, download in
                self?.left = (awake ? [.keepAwake] : []) + (meeting ? [.meeting] : [])
                self?.right = (timer ? [.timer] : []) + (download ? [.download] : [])
            }
            .store(in: &cancellables)
    }

    private static func upcoming(in events: [CalendarModel.Event]) -> CalendarModel.Event? {
        let now = Date()
        return events.first { e in
            !e.allDay && e.end > now
                && e.start.timeIntervalSince(now) <= meetingLead
                && now.timeIntervalSince(e.start) <= 5 * 60
        }
    }
}

// MARK: - Timer

final class TimerModel: ObservableObject {
    @Published private(set) var isActive = false
    @Published private(set) var isRunning = false
    @Published private(set) var duration: TimeInterval = 0

    private var endDate: Date?
    private var pausedRemaining: TimeInterval?
    private var fireTimer: Timer?
    var onFinish: ((TimeInterval) -> Void)?

    func remaining(at now: Date = Date()) -> TimeInterval {
        if let endDate { return max(0, endDate.timeIntervalSince(now)) }
        return pausedRemaining ?? 0
    }

    /// 1 = just started, 0 = done.
    func fractionLeft(at now: Date = Date()) -> Double {
        duration > 0 ? remaining(at: now) / duration : 0
    }

    func start(_ seconds: TimeInterval) {
        duration = seconds
        pausedRemaining = nil
        run(for: seconds)
    }

    func add(_ seconds: TimeInterval) {
        guard isActive else { return start(seconds) }
        duration += seconds
        if isRunning { run(for: remaining() + seconds) } else { pausedRemaining = remaining() + seconds }
    }

    func pause() {
        guard isRunning else { return }
        pausedRemaining = remaining()
        endDate = nil
        fireTimer?.invalidate()
        isRunning = false
    }

    func resume() {
        guard isActive, !isRunning, let left = pausedRemaining else { return }
        pausedRemaining = nil
        run(for: left)
    }

    func cancel() {
        fireTimer?.invalidate()
        endDate = nil
        pausedRemaining = nil
        isRunning = false
        isActive = false
    }

    private func run(for seconds: TimeInterval) {
        fireTimer?.invalidate()
        endDate = Date().addingTimeInterval(seconds)
        isActive = true
        isRunning = true
        let t = Timer(timeInterval: seconds, repeats: false) { [weak self] _ in
            guard let self else { return }
            let total = self.duration
            self.cancel()
            NSSound(named: "Glass")?.play()
            self.onFinish?(total)
        }
        RunLoop.main.add(t, forMode: .common)
        fireTimer = t
    }

    static func format(_ seconds: TimeInterval) -> String {
        let s = Int(seconds.rounded(.up))
        if s >= 3600 { return String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60) }
        return String(format: "%d:%02d", s / 60, s % 60)
    }

    /// Short form that fits inside a circle: "4:32", "12m", "1h".
    static func short(_ seconds: TimeInterval) -> String {
        let s = Int(seconds.rounded(.up))
        if s >= 3600 { return "\(s / 3600)h" }
        if s >= 600 { return "\(s / 60)m" }
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}

// MARK: - Downloads

/// Watches ~/Downloads for downloads in progress.
///
/// Browsers publish download progress for Finder through `NSProgress`, which
/// Isle subscribes to. As a fallback it also looks for the browsers' partial
/// files (Safari `.download`, Chromium `.crdownload`, Firefox `.part`).
final class DownloadMonitor: ObservableObject {
    /// True while something is downloading, and for a few seconds after it finishes.
    @Published private(set) var visible = false
    @Published private(set) var fraction: Double?     // nil = size unknown
    @Published private(set) var name = ""
    @Published private(set) var justFinished = false

    private let folder = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads")
    private static let partialExtensions = ["download", "crdownload", "part", "partial"]
    private var progresses: [ObjectIdentifier: Progress] = [:]
    private let lock = NSLock()
    private var subscriber: Any?
    private var timer: Timer?
    private var hideWork: DispatchWorkItem?

    func start() {
        guard timer == nil else { return }
        subscriber = Progress.addSubscriber(forFileURL: folder) { [weak self] progress in
            guard let self else { return nil }
            let key = ObjectIdentifier(progress)
            self.lock.lock(); self.progresses[key] = progress; self.lock.unlock()
            return { [weak self] in
                guard let self else { return }
                self.lock.lock(); self.progresses[key] = nil; self.lock.unlock()
            }
        }
        let t = Timer(timeInterval: 1, repeats: true) { [weak self] _ in self?.update() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func update() {
        lock.lock()
        let running = progresses.values.filter { !$0.isFinished && !$0.isCancelled }
        lock.unlock()

        var active = false
        var newFraction: Double?
        var newName = ""

        if !running.isEmpty {
            active = true
            let known = running.filter { $0.totalUnitCount > 0 }
            if !known.isEmpty {
                let done = known.reduce(Int64(0)) { $0 + $1.completedUnitCount }
                let total = known.reduce(Int64(0)) { $0 + $1.totalUnitCount }
                newFraction = Double(done) / Double(max(total, 1))
            }
            newName = running.first?.fileURL?.lastPathComponent ?? ""
        } else if let partial = partialFile() {
            active = true
            newFraction = Self.safariFraction(partial)
            newName = partial.deletingPathExtension().lastPathComponent
        }

        if active {
            hideWork?.cancel()
            hideWork = nil
            justFinished = false
            visible = true
            fraction = newFraction.map { min(max($0, 0), 1) }
            if !newName.isEmpty { name = newName }
        } else if visible, !justFinished {
            // Show a tick for a few seconds, then hide.
            justFinished = true
            fraction = 1
            let work = DispatchWorkItem { [weak self] in
                self?.visible = false
                self?.justFinished = false
            }
            hideWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: work)
        }
    }

    private func partialFile() -> URL? {
        let items = (try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles])) ?? []
        let partials = items.filter { Self.partialExtensions.contains($0.pathExtension.lowercased()) }
        // Ignore abandoned partial files nobody has touched in 10 minutes.
        return partials.first {
            let modified = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            return Date().timeIntervalSince(modified ?? .distantPast) < 600
        }
    }

    /// Safari keeps progress in an Info.plist inside its `.download` bundle.
    private static func safariFraction(_ url: URL) -> Double? {
        guard url.pathExtension == "download",
              let dict = NSDictionary(contentsOf: url.appendingPathComponent("Info.plist")),
              let done = (dict["DownloadEntryProgressBytesSoFar"] as? NSNumber)?.doubleValue,
              let total = (dict["DownloadEntryProgressTotalToLoad"] as? NSNumber)?.doubleValue, total > 0
        else { return nil }
        return done / total
    }

    func revealInFinder() {
        NSWorkspace.shared.open(folder)
    }
}

// MARK: - Notifications in the notch

/// A message shown in the notch for a few seconds.
struct Banner: Identifiable, Equatable {
    let id = UUID()
    let title: String
    let body: String
    let appBundleID: String?
    let symbol: String           // used when there's no app icon
    let onClick: (() -> Void)?

    static func == (a: Banner, b: Banner) -> Bool { a.id == b.id }
}

/// Reads macOS notification banners through the Accessibility API as they
/// appear and turns them into `Banner`s.
///
/// macOS has no public API for other apps' notifications, so this looks at the
/// on-screen banners drawn by the Notification Center process. It needs
/// Accessibility permission and only sees notifications that show a banner.
final class NotificationWatcher: ObservableObject {
    @Published private(set) var trusted = AXIsProcessTrusted()
    var onNotification: ((Banner) -> Void)?

    private var enabled = false
    private var timer: Timer?
    private var seen: [String: Date] = [:]
    private var primed = false
    private var loggedTrust = false
    private var lastTree = ""

    static let logURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/Isle/notifications.log")

    static func note(_ text: String) { debugLog(text) }

    /// Diagnostics for matching banner layouts on new macOS versions. Off unless enabled with
    /// `defaults write io.github.yabeshlimbu17.isle notificationDebug -bool true`
    /// (the log includes notification text, so it stays off by default).
    private static func debugLog(_ text: String) {
        guard UserDefaults.standard.bool(forKey: "notificationDebug") else { return }
        let dir = logURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let line = "[\(Date())] \(text)\n\n"
        if let h = try? FileHandle(forWritingTo: logURL) {
            h.seekToEndOfFile(); h.write(Data(line.utf8)); try? h.close()
        } else {
            try? Data(line.utf8).write(to: logURL)
        }
    }

    private static func describe(_ e: AXUIElement, depth: Int, into lines: inout [String]) {
        guard depth < 14, lines.count < 300 else { return }
        var parts = [string(e, kAXRoleAttribute) ?? "?"]
        if let v = string(e, kAXSubroleAttribute) { parts.append("sub=\(v)") }
        if let v = string(e, kAXIdentifierAttribute) { parts.append("id=\(v)") }
        if let v = string(e, kAXTitleAttribute) { parts.append("title=\(v)") }
        if let v = string(e, kAXDescriptionAttribute) { parts.append("desc=\(v)") }
        if let v = string(e, kAXValueAttribute) { parts.append("value=\(v)") }
        var names: CFArray?
        if AXUIElementCopyActionNames(e, &names) == .success, let n = names as? [String], !n.isEmpty {
            parts.append("actions=\(n.map { $0.components(separatedBy: "\n").first ?? $0 })")
        }
        lines.append(String(repeating: "  ", count: depth) + parts.joined(separator: " "))
        for c in children(e) { describe(c, depth: depth + 1, into: &lines) }
    }

    func setEnabled(_ on: Bool) {
        enabled = on
        timer?.invalidate()
        timer = nil
        guard on else { return }
        primed = false
        let t = Timer(timeInterval: 0.6, repeats: true) { [weak self] _ in self?.poll() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    /// Shows the system prompt (and adds Isle to the Accessibility list).
    func requestPermission() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        trusted = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    private func poll() {
        let nowTrusted = AXIsProcessTrusted()
        if nowTrusted != trusted || !loggedTrust {
            trusted = nowTrusted
            loggedTrust = true
            Self.debugLog("Accessibility trusted: \(nowTrusted)")
        }
        guard enabled, nowTrusted,
              let nc = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.notificationcenterui").first
        else { return }

        let app = AXUIElementCreateApplication(nc.processIdentifier)
        AXUIElementSetMessagingTimeout(app, 0.3)
        var found: [AXUIElement] = []
        let windows = Self.children(app, kAXWindowsAttribute)
        for window in windows { Self.collectNotifications(window, into: &found, depth: 0) }

        // Diagnostics (opt-in): record the banner layout so it can be matched on new macOS versions.
        if !windows.isEmpty, UserDefaults.standard.bool(forKey: "notificationDebug") {
            var lines: [String] = []
            for w in windows { Self.describe(w, depth: 0, into: &lines) }
            let tree = lines.joined(separator: "\n")
            if tree != lastTree {
                lastTree = tree
                Self.debugLog("Windows: \(windows.count), banners matched: \(found.count)\n" + tree)
            }
        } else {
            lastTree = ""
        }

        let now = Date()
        seen = seen.filter { now.timeIntervalSince($0.value) < 120 }
        for element in found {
            guard let banner = makeBanner(element) else { continue }
            // Each banner has a unique identifier; fall back to its text.
            let key = Self.string(element, kAXIdentifierAttribute) ?? (banner.title + "\u{1}" + banner.body)
            let isNew = seen[key] == nil
            seen[key] = now
            // Banners already on screen when watching starts aren't new.
            if isNew && primed {
                Self.debugLog("New notification: \(banner.title) (app: \(banner.appBundleID ?? "unknown"))")
                onNotification?(banner)
                // Isle shows it instead, so close the macOS banner.
                if Settings.shared.hideSystemBanners { Self.close(element) }
            }
        }
        primed = true
    }

    private func makeBanner(_ element: AXUIElement) -> Banner? {
        var texts: [(id: String, text: String)] = []
        var labels: [String] = []
        Self.collectTexts(element, texts: &texts, labels: &labels, depth: 0)
        if let d = Self.string(element, kAXDescriptionAttribute) { labels.insert(d, at: 0) }

        func byID(_ id: String) -> String? { texts.first { $0.id.lowercased() == id }?.text }
        let plain = texts.map(\.text)
        guard !plain.isEmpty else { return nil }

        // The banner's description reads "App, Title, Body".
        let appName = labels.first?.components(separatedBy: ", ").first
        let app = Self.matchApp(labels + plain)
        let bundleID = app?.bundleIdentifier ?? appName.flatMap(Self.bundleID(forAppNamed:))
        var title = byID("title") ?? plain[0]
        let subtitle = byID("subtitle")
        var body = byID("body") ?? (plain.count > 1 ? plain.dropFirst().joined(separator: " ") : "")
        if let subtitle, byID("body") != nil, !subtitle.isEmpty { body = subtitle + " — " + body }
        // Some banners lead with the app's name; prefer the sender as the title.
        if title == app?.localizedName ?? appName, plain.count > 1 {
            title = plain[1]
            body = plain.dropFirst(2).joined(separator: " ")
        }

        return Banner(title: title, body: body, appBundleID: bundleID, symbol: "bell.fill") {
            if AXUIElementPerformAction(element, kAXPressAction as CFString) != .success {
                if let app { app.activate() }
                else if let id = bundleID, let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) {
                    NSWorkspace.shared.openApplication(at: url, configuration: .init())
                }
            }
        }
    }

    // MARK: Accessibility helpers

    private static func children(_ e: AXUIElement, _ attribute: String = kAXChildrenAttribute) -> [AXUIElement] {
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(e, attribute as CFString, &value) == .success else { return [] }
        return value as? [AXUIElement] ?? []
    }

    private static func string(_ e: AXUIElement, _ attribute: String) -> String? {
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(e, attribute as CFString, &value) == .success,
              let s = value as? String else { return nil }
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }

    /// Notification banners have subroles like `AXNotificationCenterBanner` / `…Alert`.
    private static func collectNotifications(_ e: AXUIElement, into found: inout [AXUIElement], depth: Int) {
        guard depth < 12 else { return }
        let sub = string(e, kAXSubroleAttribute) ?? ""
        if sub.hasPrefix("AXNotificationCenter") && !sub.contains("Stack") {
            found.append(e)
            return
        }
        for c in children(e) { collectNotifications(c, into: &found, depth: depth + 1) }
    }

    private static func collectTexts(_ e: AXUIElement, texts: inout [(id: String, text: String)],
                                     labels: inout [String], depth: Int) {
        guard depth < 8 else { return }
        let role = string(e, kAXRoleAttribute) ?? ""
        if role == kAXStaticTextRole as String, let v = string(e, kAXValueAttribute) {
            texts.append((string(e, kAXIdentifierAttribute) ?? "", v))
        } else if role == kAXImageRole as String, let d = string(e, kAXDescriptionAttribute) {
            labels.append(d)
        }
        for c in children(e) { collectTexts(c, texts: &texts, labels: &labels, depth: depth + 1) }
    }

    /// Press a banner's "Close" action. Its full name looks like "Name:Close\nTarget:…".
    private static func close(_ element: AXUIElement) {
        var names: CFArray?
        guard AXUIElementCopyActionNames(element, &names) == .success,
              let action = (names as? [String])?.first(where: { $0.hasPrefix("Name:Close") || $0 == "AXCancel" })
        else { return }
        let result = AXUIElementPerformAction(element, action as CFString)
        debugLog("Closed macOS banner: \(result == .success)")
    }

    /// Look up an installed app by its display name, e.g. "Messages".
    private static func bundleID(forAppNamed name: String) -> String? {
        let folders = ["/Applications", "/System/Applications", "/System/Applications/Utilities",
                       "/Applications/Utilities", NSHomeDirectory() + "/Applications"]
        for folder in folders {
            let url = URL(fileURLWithPath: folder).appendingPathComponent(name + ".app")
            if let id = Bundle(url: url)?.bundleIdentifier { return id }
        }
        return nil
    }

    /// Find the app a banner belongs to by matching names it mentions against running apps.
    private static func matchApp(_ candidates: [String]) -> NSRunningApplication? {
        let apps = NSWorkspace.shared.runningApplications.filter { $0.localizedName != nil && $0.bundleIdentifier != nil }
        for c in candidates {
            let lower = c.lowercased()
            if let app = apps.first(where: { $0.localizedName!.lowercased() == lower }) { return app }
        }
        for c in candidates {
            let lower = c.lowercased()
            if let app = apps.first(where: {
                let name = $0.localizedName!.lowercased()
                return name.count > 3 && (lower.hasPrefix(name + ",") || lower.hasPrefix(name + ":"))
            }) { return app }
        }
        return nil
    }
}
