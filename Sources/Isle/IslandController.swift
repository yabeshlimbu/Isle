import AppKit
import ApplicationServices
import Combine
import SwiftUI

enum IslandTab: String, CaseIterable, Identifiable {
    case home, calendar, timer, clipboard, shelf, notes, camera
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
    var symbol: String {
        switch self {
        case .home: return "house.fill"
        case .calendar: return "calendar"
        case .timer: return "timer"
        case .clipboard: return "doc.on.clipboard"
        case .shelf: return "tray.full.fill"
        case .notes: return "note.text"
        case .camera: return "camera.fill"
        }
    }
}

final class IslandState: ObservableObject {
    @Published var expanded = false
    @Published var notchSize = CGSize(width: 190, height: 32)
    @Published var hasNotch = false
    @Published var tab: IslandTab = .home
    @Published var dropTargeted = false
    /// A message (e.g. timer finished) showing in the notch.
    @Published var banner: Banner?
    /// Set by the controller: what clicking a circle or the banner does.
    var openActivity: (ActivityKind) -> Void = { _ in }
    var tapBanner: () -> Void = {}

    // Drag-and-drop onto the notch
    @Published var dragging = false
    @Published var dragFiles: [URL] = []
    @Published var hoveredZone: DropZone?
    var internalDrag = false   // a file dragged out of our own shelf
}

enum IslandMetrics {
    static let expandedWidth: CGFloat = 640
    static let expandedContentHeight: CGFloat = 150
    static let liveWing: CGFloat = 40      // extra width on each side when something is "live"
    static let flare: CGFloat = 8          // concave top corners, like the real notch
    static let shadowRoom: CGFloat = 40
    static let bannerWidth: CGFloat = 440
    static let bannerContentHeight: CGFloat = 58
    static let circleGap: CGFloat = 6

    static func circleDiameter(notch: CGSize) -> CGFloat { max(20, notch.height - 4) }

    static func size(notch: CGSize, expanded: Bool, live: Bool, banner: Bool = false) -> CGSize {
        if expanded {
            return CGSize(width: expandedWidth, height: notch.height + expandedContentHeight)
        }
        if banner {
            return CGSize(width: max(bannerWidth, notch.width + flare * 2), height: notch.height + bannerContentHeight)
        }
        return CGSize(width: notch.width + (live ? liveWing * 2 : 0) + flare * 2, height: notch.height)
    }
}

/// Transparent, always-on-top panel that never activates the app.
final class IslandPanel: NSPanel {
    /// Only the Notes tab needs keyboard focus.
    var allowsKey = false

    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 3)
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle] // hidden in fullscreen apps
        isMovable = false
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        acceptsMouseMovedEvents = true
        ignoresMouseEvents = true
    }
    override var canBecomeKey: Bool { allowsKey }
    override var canBecomeMain: Bool { false }
}

/// Lets buttons respond on the first click even though the app is never active.
final class FirstClickHostingView<V: View>: NSHostingView<V> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

final class IslandController {
    let state = IslandState()
    let features = Features()

    private let panel = IslandPanel()
    private var monitors: [Any] = []
    private var screen: NSScreen?
    private var collapseWork: DispatchWorkItem?
    private var peekUntil: Date?
    private var peekWork: DispatchWorkItem?
    /// Opened from the keyboard/menu: stay open until the pointer visits and leaves.
    private var pinned = false
    private var poll: Timer?
    private var cancellables = Set<AnyCancellable>()
    private var lastDragCount = NSPasteboard(name: .drag).changeCount
    private var dragEndWork: DispatchWorkItem?
    private var bannerWork: DispatchWorkItem?
    private var bannerHovered = false

    init() {
        let host = FirstClickHostingView(rootView: IslandView(state: state, features: features))
        host.sizingOptions = []
        panel.contentView = host

        features.converter.onFinish = { [weak self] in
            self?.state.tab = .shelf
            self?.peek(seconds: 5)
        }
        state.openActivity = { [weak self] kind in self?.openActivity(kind) }
        state.tapBanner = { [weak self] in
            guard let self, let banner = self.state.banner else { return }
            self.dismissBanner()
            banner.onClick?()
        }
        features.timer.onFinish = { [weak self] total in
            let minutes = Int((total / 60).rounded())
            let length = minutes >= 1 ? "\(minutes)-minute " : ""
            self?.showBanner(Banner(title: "Time's up", body: "Your \(length)timer has finished.",
                                    appBundleID: nil, symbol: "timer", onClick: nil), seconds: 8)
        }

        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main) { [weak self] _ in self?.layout() }
        NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification,
            object: panel, queue: .main) { [weak self] _ in self?.mouseMoved() }

        state.$tab.sink { [weak self] tab in
            self?.panel.allowsKey = (tab == .notes)
            if tab != .notes { self?.dropKeyFocus() }
        }.store(in: &cancellables)

        Settings.shared.$showInFullscreen.sink { [weak self] show in
            var behavior: NSWindow.CollectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
            if show { behavior.insert(.fullScreenAuxiliary) }
            self?.panel.collectionBehavior = behavior
        }.store(in: &cancellables)

        Publishers.CombineLatest(state.$expanded, state.$tab).sink { [weak self] expanded, tab in
            guard let self else { return }
            if expanded && tab == .camera { self.features.camera.refreshAccess() }
            self.features.camera.setActive(expanded && tab == .camera)
            if expanded && tab == .calendar { self.features.calendar.refreshAccess() }
        }.store(in: &cancellables)
    }

    func show() {
        layout()
        panel.orderFrontRegardless()
        features.music.start()
        features.battery.start()
        features.clipboard.start()
        features.calendar.start()
        features.stats.start()
        features.quotes.start()
        features.downloads.start()

        let mask: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged]
        if let m = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] _ in self?.mouseMoved() }) {
            monitors.append(m)
        }
        if let m = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { [weak self] e in self?.mouseMoved(); return e }) {
            monitors.append(m)
        }
        // A click in another app doesn't take key status away from a
        // non-activating panel, so do it ourselves (otherwise the island
        // would stay open forever after typing a note).
        if let m = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: { [weak self] _ in
            guard let self, !self.hotRect().contains(NSEvent.mouseLocation) else { return }
            self.dropKeyFocus()
            self.pinned = false
            self.mouseMoved()
        }) {
            monitors.append(m)
        }
        // Mouse-moved events aren't delivered while files are dragged from
        // Finder, so also check the pointer position a few times a second.
        let t = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in self?.mouseMoved() }
        RunLoop.main.add(t, forMode: .common)
        poll = t
    }

    /// Prefer the built-in screen with a notch; otherwise the main screen.
    private func targetScreen() -> NSScreen? {
        NSScreen.screens.first { $0.safeAreaInsets.top > 0 } ?? NSScreen.main ?? NSScreen.screens.first
    }

    func layout() {
        guard let s = targetScreen() else { return }
        screen = s
        let f = s.frame
        if s.safeAreaInsets.top > 0, let l = s.auxiliaryTopLeftArea, let r = s.auxiliaryTopRightArea {
            state.notchSize = CGSize(width: f.width - l.width - r.width, height: s.safeAreaInsets.top)
            state.hasNotch = true
        } else {
            state.notchSize = CGSize(width: 190, height: max(24, f.maxY - s.visibleFrame.maxY))
            state.hasNotch = false
        }
        let w = IslandMetrics.expandedWidth + IslandMetrics.shadowRoom * 2
        let h = state.notchSize.height + IslandMetrics.expandedContentHeight + IslandMetrics.shadowRoom
        panel.setFrame(NSRect(x: f.midX - w / 2, y: f.maxY - h, width: w, height: h), display: true)
    }

    private var isLive: Bool { features.music.track?.playing ?? false }
    private var bannerShowing: Bool { !state.expanded && state.banner != nil }

    /// The island's visible area in screen coordinates (slightly padded).
    private func hotRect() -> NSRect {
        guard let s = screen else { return .zero }
        let size = IslandMetrics.size(notch: state.notchSize, expanded: state.expanded, live: isLive,
                                      banner: bannerShowing)
        return NSRect(x: s.frame.midX - size.width / 2, y: s.frame.maxY - size.height,
                      width: size.width, height: size.height).insetBy(dx: -4, dy: -6)
    }

    /// The strip holding the activity circles beside the collapsed notch.
    private func circleRect() -> NSRect? {
        guard let s = screen, !state.expanded, !bannerShowing else { return nil }
        let left = CGFloat(features.activities.left.count), right = CGFloat(features.activities.right.count)
        guard left + right > 0 else { return nil }
        let step = IslandMetrics.circleDiameter(notch: state.notchSize) + IslandMetrics.circleGap
        let size = IslandMetrics.size(notch: state.notchSize, expanded: false, live: isLive)
        return NSRect(x: s.frame.midX - size.width / 2 - left * step, y: s.frame.maxY - state.notchSize.height,
                      width: size.width + (left + right) * step, height: state.notchSize.height)
    }

    private func mouseMoved() {
        let location = NSEvent.mouseLocation
        let inside = hotRect().contains(location)
        let overCircles = !inside && (circleRect()?.contains(location) ?? false)
        let buttonDown = NSEvent.pressedMouseButtons & 1 != 0
        // Only capture clicks while the pointer is over the island or a circle;
        // everywhere else clicks fall through to whatever is underneath.
        panel.ignoresMouseEvents = !(inside || overCircles)
        trackDrag(inside: inside, buttonDown: buttonDown)

        // A notification stays put while the pointer is on it, so it can be clicked.
        if bannerShowing && !state.dragging {
            if inside && !bannerHovered {
                bannerHovered = true
                bannerWork?.cancel()
            } else if !inside && bannerHovered {
                bannerHovered = false
                scheduleBannerDismiss(after: 1.5)
            }
            return
        }

        if inside {
            pinned = false
            collapseWork?.cancel()
            collapseWork = nil
            if !state.expanded { setExpanded(true) }
        } else if state.expanded, collapseWork == nil, !pinned,
                  (peekUntil ?? .distantPast) < Date(),
                  !(state.internalDrag && buttonDown),   // dragging a file out of the shelf
                  !panel.isKeyWindow {   // stay open while typing a note
            let work = DispatchWorkItem { [weak self] in
                self?.collapseWork = nil
                self?.setExpanded(false)
            }
            collapseWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
        }
    }

    /// Notice when files are dragged onto the notch and look at what they are,
    /// so the island can offer the right actions (shelf, convert, PDF).
    private func trackDrag(inside: Bool, buttonDown: Bool) {
        let dragPasteboard = NSPasteboard(name: .drag)
        let count = dragPasteboard.changeCount

        if !buttonDown {
            lastDragCount = count
            state.internalDrag = false
            if state.dragging, dragEndWork == nil {
                // Give the drop handler a moment to run before hiding the zones.
                let work = DispatchWorkItem { [weak self] in
                    self?.dragEndWork = nil
                    self?.state.dragging = false
                    self?.state.hoveredZone = nil
                }
                dragEndWork = work
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
            }
            return
        }

        guard inside, count != lastDragCount else { return }
        lastDragCount = count
        guard !state.internalDrag else { return }
        let files = dragPasteboard.readObjects(forClasses: [NSURL.self],
                                               options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        guard !files.isEmpty else { return }
        dragEndWork?.cancel()
        dragEndWork = nil
        state.dragFiles = files
        state.dragging = true
    }

    private func setExpanded(_ value: Bool) {
        guard state.expanded != value else { return }
        withAnimation(.spring(response: 0.38, dampingFraction: 0.82)) {
            state.expanded = value
        }
        if value {
            features.music.refresh()
        } else {
            pinned = false
            dropKeyFocus()
            panel.ignoresMouseEvents = true
            state.dropTargeted = false
        }
    }

    /// Give keyboard focus back to whatever app the user was in.
    private func dropKeyFocus() {
        guard panel.isKeyWindow else { return }
        panel.orderOut(nil)
        panel.orderFrontRegardless()
    }

    func toggle() {
        collapseWork?.cancel()
        collapseWork = nil
        peekWork?.cancel()
        peekUntil = nil
        if state.expanded {
            setExpanded(false)
        } else {
            setExpanded(true)
            pinned = true
            panel.ignoresMouseEvents = false
        }
    }

    // MARK: Banners and activities

    func showBanner(_ banner: Banner, seconds: TimeInterval = 5) {
        // The user is already looking at the open island; don't cover it.
        guard !state.expanded else { return }
        withAnimation(.spring(response: 0.38, dampingFraction: 0.82)) { state.banner = banner }
        bannerHovered = hotRect().contains(NSEvent.mouseLocation)
        if !bannerHovered { scheduleBannerDismiss(after: seconds) }
        mouseMoved()
    }

    private func scheduleBannerDismiss(after seconds: TimeInterval) {
        bannerWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.dismissBanner() }
        bannerWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    private func dismissBanner() {
        bannerWork?.cancel()
        bannerWork = nil
        bannerHovered = false
        withAnimation(.spring(response: 0.38, dampingFraction: 0.82)) { state.banner = nil }
        mouseMoved()
    }

    private func openActivity(_ kind: ActivityKind) {
        switch kind {
        case .keepAwake:
            features.keepAwake.toggle()
        case .meeting:
            state.tab = .calendar
            toggle()
        case .timer:
            state.tab = .timer
            toggle()
        case .download:
            features.downloads.revealInFinder()
        }
    }

    /// Open the island for a few seconds (e.g. when the timer finishes).
    func peek(seconds: TimeInterval = 4) {
        peekWork?.cancel()
        peekUntil = Date().addingTimeInterval(seconds)
        setExpanded(true)
        panel.ignoresMouseEvents = false
        // Cancel the previous peek's timeout so a newer, longer peek isn't cut short.
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.peekUntil = nil
            self.peekWork = nil
            if !self.pinned, !self.panel.isKeyWindow,
               !self.hotRect().contains(NSEvent.mouseLocation) { self.setExpanded(false) }
        }
        peekWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }
}
