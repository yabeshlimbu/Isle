import AppKit
import AVFoundation
import Combine
import EventKit
import IOKit.pwr_mgt

/// All the feature models, created once and shared with the views.
final class Features {
    let music = NowPlaying()
    let stats = SystemStats()
    let quotes = QuoteModel()
    let battery = BatteryMonitor()
    let calendar = CalendarModel()
    let clipboard = ClipboardHistory()
    let shelf = Shelf()
    let notes = NotesModel()
    let keepAwake = KeepAwake()
    let camera = CameraMirror()
    let converter = Converter()
    let timer = TimerModel()
    let downloads = DownloadMonitor()
    let activities: ActivityCenter

    init() {
        activities = ActivityCenter(keepAwake: keepAwake, timer: timer, downloads: downloads, calendar: calendar)
        converter.onOutputs = { [weak shelf] urls in urls.forEach { shelf?.add($0) } }
    }
}

// MARK: - Calendar

final class CalendarModel: ObservableObject {
    enum Access { case notDetermined, denied, granted }
    struct Event: Identifiable, Equatable {
        let id: String
        let title: String
        let start: Date
        let end: Date
        let allDay: Bool
        let color: NSColor
    }

    @Published private(set) var access: Access = CalendarModel.currentAccess()
    @Published private(set) var events: [Event] = []   // rest of today
    var nextEvent: Event? { events.first { !$0.allDay } }

    private let store = EKEventStore()
    private var timer: Timer?

    static func currentAccess() -> Access {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .fullAccess: return .granted
        case .notDetermined: return .notDetermined
        default: return .denied
        }
    }

    func start() {
        NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: store, queue: .main) { [weak self] _ in
            self?.reload()
        }
        let t = Timer(timeInterval: 60, repeats: true) { [weak self] _ in self?.reload() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        reload()
    }

    func requestAccess() {
        store.requestFullAccessToEvents { [weak self] _, _ in
            DispatchQueue.main.async { self?.refreshAccess() }
        }
    }

    func refreshAccess() {
        let newAccess = Self.currentAccess()
        if newAccess == .granted && access != .granted { store.reset() }   // a store made before access was granted sees nothing
        access = newAccess
        reload()
    }

    func reload() {
        guard access == .granted else { events = []; return }
        let now = Date()
        let start = Calendar.current.startOfDay(for: now)
        guard let end = Calendar.current.date(byAdding: .day, value: 1, to: start) else { return }
        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: nil)
        let list = store.events(matching: predicate)
            .filter { $0.endDate > now }
            .sorted { $0.startDate < $1.startDate }
            .map { e in
                Event(id: "\(e.eventIdentifier ?? UUID().uuidString)-\(e.startDate.timeIntervalSince1970)",
                      title: e.title ?? "Untitled",
                      start: e.startDate, end: e.endDate, allDay: e.isAllDay,
                      color: e.calendar.flatMap { NSColor(cgColor: $0.cgColor) } ?? .systemBlue)
            }
        if list != events { events = list }
    }

    func openCalendarApp() {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.iCal") {
            NSWorkspace.shared.openApplication(at: url, configuration: .init())
        }
    }
}

// MARK: - Clipboard history (text only, persists across restarts, skips password managers)

final class ClipboardHistory: ObservableObject {
    struct Item: Identifiable, Equatable, Codable {
        var id: UUID = UUID()
        let text: String
        let date: Date

        enum CodingKeys: CodingKey {
            case text, date
        }

        init(text: String, date: Date) {
            self.text = text
            self.date = date
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.text = try container.decode(String.self, forKey: .text)
            self.date = try container.decode(Date.self, forKey: .date)
            self.id = UUID()
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(text, forKey: .text)
            try container.encode(date, forKey: .date)
        }
    }

    @Published private(set) var items: [Item] = []
    @Published private(set) var copiedID: UUID?

    private let pasteboard = NSPasteboard.general
    private lazy var lastChange = pasteboard.changeCount
    private var timer: Timer?
    private let key = "clipboardHistory"

    var limit: Int { Settings.shared.clipboardLimit }

    private var cancellables = Set<AnyCancellable>()

    init() {
        load()
        // @Published emits before the value is stored, so use the emitted values.
        Settings.shared.$clipboardLimit.dropFirst().sink { [weak self] limit in
            guard let self, self.items.count > limit else { return }
            self.items.removeLast(self.items.count - limit)
            self.save()
        }.store(in: &cancellables)
        Settings.shared.$clipboardPersist.dropFirst().sink { [weak self] persist in
            guard let self else { return }
            if persist {
                if let data = try? JSONEncoder().encode(self.items) { UserDefaults.standard.set(data, forKey: self.key) }
            } else {
                UserDefaults.standard.removeObject(forKey: self.key)   // don't leave old history on disk
            }
        }.store(in: &cancellables)
    }

    private func load() {
        guard Settings.shared.clipboardPersist,
              let data = UserDefaults.standard.data(forKey: key),
              let saved = try? JSONDecoder().decode([Item].self, from: data) else { return }
        items = Array(saved.prefix(limit))
    }

    private func save() {
        guard Settings.shared.clipboardPersist else { return }
        if let data = try? JSONEncoder().encode(items) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    func start() {
        let t = Timer(timeInterval: 0.75, repeats: true) { [weak self] _ in self?.check() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func check() {
        guard pasteboard.changeCount != lastChange else { return }
        lastChange = pasteboard.changeCount
        let types = pasteboard.types?.map(\.rawValue) ?? []
        if types.contains("org.nspasteboard.ConcealedType") || types.contains("org.nspasteboard.TransientType") { return }
        guard let text = pasteboard.string(forType: .string),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        items.removeAll { $0.text == text }
        items.insert(Item(text: text, date: Date()), at: 0)
        if items.count > limit { items.removeLast(items.count - limit) }
        save()
    }

    func copy(_ item: Item) {
        pasteboard.clearContents()
        pasteboard.setString(item.text, forType: .string)
        lastChange = pasteboard.changeCount
        items.removeAll { $0.id == item.id }
        let fresh = Item(text: item.text, date: Date())
        items.insert(fresh, at: 0)
        copiedID = fresh.id
        save()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            if self?.copiedID == fresh.id { self?.copiedID = nil }
        }
    }

    func clear() {
        items.removeAll()
        save()
    }
}

// MARK: - File shelf

final class Shelf: ObservableObject {
    @Published private(set) var files: [URL] = []
    private let key = "shelfPaths"

    init() {
        let paths = UserDefaults.standard.stringArray(forKey: key) ?? []
        files = paths.map { URL(fileURLWithPath: $0) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    func add(_ url: URL) {
        guard !files.contains(url) else { return }
        files.append(url)
        save()
    }

    func remove(_ url: URL) {
        files.removeAll { $0 == url }
        save()
    }

    func clear() {
        files.removeAll()
        save()
    }

    func airDrop() {
        guard !files.isEmpty, let service = NSSharingService(named: .sendViaAirDrop) else { return }
        NSApp.activate()
        service.perform(withItems: files)
    }

    private func save() {
        UserDefaults.standard.set(files.map(\.path), forKey: key)
    }
}

// MARK: - Notes scratchpad

final class NotesModel: ObservableObject {
    @Published var text: String = UserDefaults.standard.string(forKey: "notes") ?? "" {
        didSet { UserDefaults.standard.set(text, forKey: "notes") }
    }
}

// MARK: - Keep awake

final class KeepAwake: ObservableObject {
    @Published private(set) var isOn = false
    private var assertion: IOPMAssertionID = 0

    func toggle() {
        if isOn {
            IOPMAssertionRelease(assertion)
            assertion = 0
            isOn = false
        } else {
            var id: IOPMAssertionID = 0
            let result = IOPMAssertionCreateWithName("PreventUserIdleDisplaySleep" as CFString,
                                                     IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                                     "Isle keep awake" as CFString, &id)
            if result == kIOReturnSuccess {
                assertion = id
                isOn = true
            }
        }
    }
}

// MARK: - Camera mirror

final class CameraMirror: ObservableObject {
    enum Access { case notDetermined, denied, granted }

    @Published private(set) var access: Access = CameraMirror.currentAccess()
    let session = AVCaptureSession()

    private let queue = DispatchQueue(label: "isle.camera")
    private var configured = false     // touched only on `queue`
    private var wantActive = false

    static func currentAccess() -> Access {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: return .granted
        case .notDetermined: return .notDetermined
        default: return .denied
        }
    }

    /// Picks up a permission change made in System Settings.
    func refreshAccess() {
        let now = Self.currentAccess()
        guard now != access else { return }
        access = now
        setActive(wantActive)
    }

    func requestAccess() {
        AVCaptureDevice.requestAccess(for: .video) { [weak self] _ in
            DispatchQueue.main.async {
                guard let self else { return }
                self.access = Self.currentAccess()
                self.setActive(self.wantActive)
            }
        }
    }

    /// The camera only runs while the camera tab is open.
    func setActive(_ active: Bool) {
        wantActive = active
        guard access == .granted else { return }
        queue.async { [self] in
            if active {
                if !configured { configure() }
                if !session.isRunning { session.startRunning() }
            } else if session.isRunning {
                session.stopRunning()
            }
        }
    }

    private func configure() {
        session.beginConfiguration()
        session.sessionPreset = .medium
        if let device = AVCaptureDevice.default(for: .video),
           let input = try? AVCaptureDeviceInput(device: device),
           session.canAddInput(input) {
            session.addInput(input)
        }
        session.commitConfiguration()
        configured = true
    }
}
