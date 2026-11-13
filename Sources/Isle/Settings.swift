import AppKit
import Carbon.HIToolbox
import Combine
import SwiftUI

// MARK: - Persistent settings

final class Settings: ObservableObject {
    static let shared = Settings()

    // Clipboard
    @Published var clipboardLimit: Int {
        didSet { UserDefaults.standard.set(clipboardLimit, forKey: "clipboardLimit") }
    }
    @Published var clipboardPersist: Bool {
        didSet { UserDefaults.standard.set(clipboardPersist, forKey: "clipboardPersist") }
    }

    // Appearance
    @Published var showInFullscreen: Bool {
        didSet { UserDefaults.standard.set(showInFullscreen, forKey: "showInFullscreen") }
    }

    private init() {
        let d = UserDefaults.standard
        clipboardLimit = d.object(forKey: "clipboardLimit") as? Int ?? 30
        clipboardPersist = d.object(forKey: "clipboardPersist") as? Bool ?? true
        showInFullscreen = d.object(forKey: "showInFullscreen") as? Bool ?? false
    }
}

// MARK: - Settings window

final class SettingsWindowController {
    private var window: NSWindow?

    func show() {
        if let window, window.isVisible {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate()
            return
        }
        let view = SettingsView()
        let host = NSHostingController(rootView: view)
        let w = NSWindow(contentViewController: host)
        w.title = "Isle Settings"
        w.styleMask = [.titled, .closable]
        w.setContentSize(NSSize(width: 400, height: 420))
        w.center()
        w.isReleasedWhenClosed = false
        w.makeKeyAndOrderFront(nil)
        NSApp.activate()
        window = w
    }
}

struct SettingsView: View {
    @ObservedObject private var settings = Settings.shared

    var body: some View {
        TabView {
            GeneralSettingsTab(settings: settings)
                .tabItem { Label("General", systemImage: "gear") }
            ClipboardSettingsTab(settings: settings)
                .tabItem { Label("Clipboard", systemImage: "doc.on.clipboard") }
            ShortcutsSettingsTab()
                .tabItem { Label("Shortcuts", systemImage: "keyboard") }
        }
        .padding(20)
        .frame(width: 400, height: 420)
    }
}

struct GeneralSettingsTab: View {
    @ObservedObject var settings: Settings

    var body: some View {
        Form {
            Section {
                Toggle("Show island in fullscreen apps", isOn: $settings.showInFullscreen)
            } header: {
                Text("Appearance").font(.headline)
            }
            Section {
                Text("Some quotes are provided by [ZenQuotes API](https://zenquotes.io/).")
                    .foregroundStyle(.secondary)
            } header: {
                Text("Credits").font(.headline)
            }
        }
        .formStyle(.grouped)
    }
}

struct ClipboardSettingsTab: View {
    @ObservedObject var settings: Settings

    var body: some View {
        Form {
            Section {
                HStack {
                    Text("History size")
                    Spacer()
                    Picker("", selection: $settings.clipboardLimit) {
                        ForEach([10, 20, 30, 50, 100], id: \.self) { n in
                            Text("\(n) items").tag(n)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 100)
                }
                Toggle("Persist clipboard history across restarts", isOn: $settings.clipboardPersist)
            } header: {
                Text("Clipboard History").font(.headline)
            }
        }
        .formStyle(.grouped)
    }
}

struct ShortcutsSettingsTab: View {
    var body: some View {
        Form {
            Section {
                ShortcutRow(label: "Toggle island", key: "⌃ Space")
            } header: {
                Text("Global Keyboard Shortcuts").font(.headline)
            }
            Section {
                Text("Shortcuts are built-in and always active.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

struct ShortcutRow: View {
    let label: String
    let key: String

    var body: some View {
        HStack {
            Text(label)
            Spacer()
            Text(key)
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(RoundedRectangle(cornerRadius: 5).fill(Color.secondary.opacity(0.15)))
        }
    }
}
