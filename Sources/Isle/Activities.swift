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

// MARK: - Notch banner

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
