import AppKit
import Combine

// MARK: - Bikram Sambat (BS) calendar

/// One BS year: the AD date of 1 Baisakh and its 12 month lengths.
/// Month lengths change every year and can't be calculated, so each new
/// year has to be added here from an official patro before it starts.
struct BSYear {
    let year: Int
    let start: DateComponents   // AD date of 1 Baisakh
    let months: [Int]           // Baisakh … Chaitra
}

struct BSDate {
    let year: Int
    let month: Int     // 1…12
    let day: Int
    let weekday: Int   // 0 = Sunday
}

enum NepaliCalendar {
    static let years: [BSYear] = [
        // 2083 BS — 1 Baisakh = 14 Apr 2026, 365 days.
        BSYear(year: 2083,
               start: DateComponents(year: 2026, month: 4, day: 14),
               months: [31, 31, 32, 31, 31, 31, 30, 29, 30, 29, 30, 30]),

        // 2084 BS — 1 Baisakh = 14 Apr 2027, 365 days, Chaitra = 30.
        // TODO: fill in the month lengths from an official patro before April 2027, then uncomment.
        // BSYear(year: 2084,
        //        start: DateComponents(year: 2027, month: 4, day: 14),
        //        months: [ , , , , , , , , , , , 30]),
    ]

    static let monthsNP = ["बैशाख", "जेठ", "असार", "साउन", "भदौ", "असोज",
                           "कात्तिक", "मंसिर", "पुस", "माघ", "फागुन", "चैत"]
    static let monthsEN = ["Baisakh", "Jestha", "Asar", "Shrawan", "Bhadra", "Ashwin",
                           "Kartik", "Mangsir", "Poush", "Magh", "Falgun", "Chaitra"]
    static let weekdaysShortNP = ["आइत", "सोम", "मंगल", "बुध", "बिही", "शुक्र", "शनि"]
    static let weekdaysFullNP = ["आइतबार", "सोमबार", "मंगलबार", "बुधबार", "बिहीबार", "शुक्रबार", "शनिबार"]
    static let weekdaysShortEN = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]

    static func bsDate(for date: Date) -> BSDate? {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = .current
        let today = cal.startOfDay(for: date)
        let weekday = cal.component(.weekday, from: today) - 1

        for y in years {
            guard let start = cal.date(from: y.start),
                  var offset = cal.dateComponents([.day], from: start, to: today).day,
                  offset >= 0, offset < y.months.reduce(0, +) else { continue }
            for (i, length) in y.months.enumerated() {
                if offset < length {
                    return BSDate(year: y.year, month: i + 1, day: offset + 1, weekday: weekday)
                }
                offset -= length
            }
        }
        return nil
    }

    static func nepaliDigits(_ n: Int) -> String {
        let digits = Array("०१२३४५६७८९")
        return String(String(n).map { c in c.wholeNumberValue.map { digits[$0] } ?? c })
    }

    /// Menu bar text, e.g. "आइत ६ मंसिर" or "Sun 6 Mangsir".
    static func shortText(_ d: BSDate, nepali: Bool) -> String {
        let m = d.month - 1
        return nepali
            ? "\(weekdaysShortNP[d.weekday]) \(nepaliDigits(d.day)) \(monthsNP[m])"
            : "\(weekdaysShortEN[d.weekday]) \(d.day) \(monthsEN[m])"
    }
}

// MARK: - Menu bar item

/// Shows today's BS date in the menu bar, next to the system clock.
final class NepaliDateStatusItem: NSObject {
    private var statusItem: NSStatusItem?
    private var timer: Timer?
    private var cancellables = Set<AnyCancellable>()
    private let settings = Settings.shared

    func start() {
        // Show/hide and language follow Settings.
        settings.$showNepaliDate
            .combineLatest(settings.$nepaliDateInNepali)
            .receive(on: RunLoop.main)
            .sink { [weak self] show, _ in self?.apply(show: show) }
            .store(in: &cancellables)

        // Re-check every minute, at midnight and after waking from sleep.
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in self?.refresh() }
        NotificationCenter.default.addObserver(self, selector: #selector(refresh),
                                               name: .NSCalendarDayChanged, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(refresh),
                                                          name: NSWorkspace.didWakeNotification, object: nil)
    }

    private func apply(show: Bool) {
        if show {
            if statusItem == nil {
                statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
                statusItem?.autosaveName = "IsleNepaliDate"   // remembers where you ⌘-drag it
            }
            // Defer so Settings has finished updating before we read it.
            DispatchQueue.main.async { [weak self] in self?.refresh() }
        } else if let item = statusItem {
            NSStatusBar.system.removeStatusItem(item)
            statusItem = nil
        }
    }

    @objc func refresh() {
        guard let statusItem else { return }
        let nepali = settings.nepaliDateInNepali
        let menu = NSMenu()

        if let d = NepaliCalendar.bsDate(for: Date()) {
            statusItem.button?.title = NepaliCalendar.shortText(d, nepali: nepali)
            let m = d.month - 1
            menu.addItem(info("\(NepaliCalendar.weekdaysFullNP[d.weekday]), \(NepaliCalendar.nepaliDigits(d.day)) \(NepaliCalendar.monthsNP[m]) \(NepaliCalendar.nepaliDigits(d.year))"))
            menu.addItem(info("\(d.day) \(NepaliCalendar.monthsEN[m]) \(d.year) BS"))
        } else {
            statusItem.button?.title = "BS ?"
            menu.addItem(info("No BS calendar data for this year yet"))
        }

        let ad = DateFormatter()
        ad.dateStyle = .full
        menu.addItem(info(ad.string(from: Date())))
        menu.addItem(.separator())

        let toggle = NSMenuItem(title: nepali ? "Show in English" : "नेपालीमा देखाउनुहोस्",
                                action: #selector(toggleLanguage), keyEquivalent: "")
        toggle.target = self
        menu.addItem(toggle)
        let hide = NSMenuItem(title: "Hide Nepali Date", action: #selector(hide), keyEquivalent: "")
        hide.target = self
        menu.addItem(hide)

        statusItem.menu = menu
    }

    private func info(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    @objc private func toggleLanguage() { settings.nepaliDateInNepali.toggle() }
    @objc private func hide() { settings.showNepaliDate = false }
}
