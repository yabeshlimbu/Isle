import AppKit
import ServiceManagement

extension Notification.Name {
    static let openIsleSettings = Notification.Name("OpenIsleSettings")
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var island: IslandController!
    private var statusItem: NSStatusItem!
    private let settingsController = SettingsWindowController()
    private let hotkeys = GlobalHotkeys()
    private let loginItem = NSMenuItem(title: "Launch at Login", action: #selector(toggleLogin), keyEquivalent: "")

    func applicationDidFinishLaunching(_ notification: Notification) {
        island = IslandController()
        island.show()
        setupStatusItem()
        setupHotkeys()
        // The gear button in the island posts this.
        NotificationCenter.default.addObserver(forName: .openIsleSettings, object: nil, queue: .main) { [weak self] _ in
            self?.settingsController.show()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        island.features.music.stop()   // don't leave the media helper running
    }

    private func setupHotkeys() {
        hotkeys.onToggle = { [weak self] in self?.island.toggle() }
        hotkeys.register()
    }

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        let menu = NSMenu()
        menu.delegate = self
        let peek = NSMenuItem(title: "Show Island", action: #selector(showIsland), keyEquivalent: "")
        peek.target = self
        loginItem.target = self
        let settings = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        settings.target = self
        let quit = NSMenuItem(title: "Quit Isle", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.items = [nepaliDateItem, .separator(), peek, loginItem, settings, .separator(), quit]
        statusItem.menu = menu

        updateNepaliDate()
        // Roll over at midnight, and after waking from sleep.
        NotificationCenter.default.addObserver(forName: .NSCalendarDayChanged, object: nil, queue: .main) { [weak self] _ in
            self?.updateNepaliDate()
        }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil,
                                                          queue: .main) { [weak self] _ in
            self?.updateNepaliDate()
        }
    }

    /// Shows today's Nepali (Bikram Sambat) date in the menu bar, e.g. "मंसिर ६".
    private func updateNepaliDate() {
        guard let button = statusItem.button else { return }
        if let bs = NepaliDate(Date()) {
            button.image = nil
            button.title = "\(NepaliDate.monthNames[bs.month - 1]) \(NepaliDate.devanagari(bs.day))"
            button.toolTip = "\(bs.formattedLatin) BS"
            nepaliDateItem.title = "\(bs.weekdayName), \(bs.formatted)"
            nepaliDateItem.isHidden = false
        } else {
            // Outside the conversion table: fall back to the Isle icon.
            button.title = ""
            button.image = NSImage(systemSymbolName: "capsule.fill", accessibilityDescription: "Isle")
            button.toolTip = nil
            nepaliDateItem.isHidden = true
        }
    }

    private let nepaliDateItem: NSMenuItem = {
        let item = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }()

    func menuNeedsUpdate(_ menu: NSMenu) {
        loginItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
        updateNepaliDate()
    }

    @objc private func showIsland() { island.peek() }
    @objc private func openSettings() { settingsController.show() }

    @objc private func toggleLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            let alert = NSAlert()
            alert.messageText = "Couldn't change the login item"
            alert.informativeText = error.localizedDescription + "\n\nTip: move Isle.app into /Applications first."
            NSApp.activate()
            alert.runModal()
        }
    }
}
