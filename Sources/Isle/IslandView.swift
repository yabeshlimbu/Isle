import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Black notch shape: concave top corners that blend into the bezel, rounded bottom.
struct NotchShape: Shape {
    var flare: CGFloat
    var bottomRadius: CGFloat

    var animatableData: CGFloat {
        get { bottomRadius }
        set { bottomRadius = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let w = rect.width, h = rect.height, t = flare
        let b = max(0, min(bottomRadius, h - t, (w - 2 * t) / 2))
        var p = Path()
        p.move(to: CGPoint(x: 0, y: 0))
        p.addQuadCurve(to: CGPoint(x: t, y: t), control: CGPoint(x: t, y: 0))
        p.addLine(to: CGPoint(x: t, y: h - b))
        p.addQuadCurve(to: CGPoint(x: t + b, y: h), control: CGPoint(x: t, y: h))
        p.addLine(to: CGPoint(x: w - t - b, y: h))
        p.addQuadCurve(to: CGPoint(x: w - t, y: h - b), control: CGPoint(x: w - t, y: h))
        p.addLine(to: CGPoint(x: w - t, y: t))
        p.addQuadCurve(to: CGPoint(x: w, y: 0), control: CGPoint(x: w - t, y: 0))
        p.closeSubpath()
        return p
    }
}

struct IslandView: View {
    @ObservedObject var state: IslandState
    let features: Features
    @ObservedObject private var music: NowPlaying

    init(state: IslandState, features: Features) {
        self.state = state
        self.features = features
        _music = ObservedObject(wrappedValue: features.music)
    }

    private var live: Bool { music.track?.playing ?? false }

    var body: some View {
        let size = IslandMetrics.size(notch: state.notchSize, expanded: state.expanded, live: live)
        let shape = NotchShape(flare: IslandMetrics.flare, bottomRadius: state.expanded ? 24 : 10)

        VStack(spacing: 0) {
            ZStack(alignment: .top) {
                shape.fill(Color.black)

                if state.expanded {
                    ExpandedContent(state: state, features: features)
                        .padding(.horizontal, IslandMetrics.flare + 18)
                        .padding(.bottom, 14)
                        .transition(.opacity.combined(with: .scale(scale: 0.95, anchor: .top)))
                } else if live {
                    CollapsedContent(music: music, notchWidth: state.notchSize.width)
                        .padding(.horizontal, IslandMetrics.flare)
                        .frame(height: state.notchSize.height)
                        .transition(.opacity)
                }
            }
            .frame(width: size.width, height: size.height)
            .clipShape(shape)
            .overlay(
                shape.stroke(Color.white.opacity(state.dropTargeted ? 0.5 : 0), lineWidth: 2)
            )
            .shadow(color: .black.opacity(state.expanded ? 0.4 : 0), radius: 14, y: 6)

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .animation(.spring(response: 0.38, dampingFraction: 0.82), value: live)
        .animation(.easeOut(duration: 0.15), value: state.tab)
        .foregroundStyle(.white)
        .environment(\.colorScheme, .dark)
    }
}

// MARK: - Collapsed ("live activity") state

struct CollapsedContent: View {
    @ObservedObject var music: NowPlaying
    let notchWidth: CGFloat

    var body: some View {
        HStack(spacing: 0) {
            Image(systemName: "waveform")
                .symbolEffect(.variableColor.iterative, isActive: true)
                .foregroundStyle(.green)
                .font(.system(size: 12, weight: .semibold))
                .frame(width: IslandMetrics.liveWing)

            Spacer(minLength: notchWidth)

            Group {
                if let img = music.artwork {
                    Image(nsImage: img)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: 16, height: 16)
                        .clipShape(RoundedRectangle(cornerRadius: 3))
                } else if let id = music.track?.bundleID, !id.isEmpty {
                    AppIcon(bundleID: id).frame(width: 16, height: 16)
                } else {
                    Image(systemName: "music.note").font(.system(size: 12))
                }
            }
            .frame(width: IslandMetrics.liveWing)
        }
    }
}

// MARK: - Expanded state

struct ExpandedContent: View {
    @ObservedObject var state: IslandState
    let features: Features

    var body: some View {
        VStack(spacing: 0) {
            Header(state: state, keepAwake: features.keepAwake, battery: features.battery)
                .frame(height: state.notchSize.height)
            Group {
                if state.dragging {
                    DropZonesView(state: state) { zone, providers in handleDrop(zone, providers) }
                } else {
                    tabContent
                        .onDrop(of: [.fileURL], isTargeted: Binding(get: { state.dropTargeted },
                                                                    set: { state.dropTargeted = $0 })) { providers in
                            handleDrop(.shelf, providers)
                            return true
                        }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.top, 6)
        }
    }

    @ViewBuilder private var tabContent: some View {
        switch state.tab {
        case .home: HomeTab(features: features)
        case .calendar: CalendarPanel(model: features.calendar)
        case .clipboard: ClipboardPanel(model: features.clipboard)
        case .shelf: ShelfPanel(shelf: features.shelf, converter: features.converter, state: state)
        case .notes: NotesPanel(notes: features.notes)
        case .camera: CameraPanel(camera: features.camera)
        }
    }

    private func handleDrop(_ zone: DropZone, _ providers: [NSItemProvider]) {
        let fallback = state.dragFiles
        loadFileURLs(providers) { loaded in
            let urls = loaded.isEmpty ? fallback : loaded
            switch zone {
            case .shelf: urls.forEach { features.shelf.add($0) }
            case .pdf: features.converter.makePDF(urls)
            case .jpg, .heic, .png:
                if let format = zone.format { features.converter.convert(urls, to: format) }
            }
            state.tab = .shelf
            state.dragging = false
            state.hoveredZone = nil
            state.dropTargeted = false
        }
    }
}

/// Tabs on the left of the notch, quick toggles on the right.
struct Header: View {
    @ObservedObject var state: IslandState
    @ObservedObject var keepAwake: KeepAwake
    @ObservedObject var battery: BatteryMonitor

    var body: some View {
        HStack(spacing: 0) {
            HStack(spacing: 2) {
                ForEach(IslandTab.allCases) { tab in
                    let selected = state.tab == tab
                    Button { state.tab = tab } label: {
                        Image(systemName: tab.symbol)
                            .font(.system(size: 11, weight: .semibold))
                            .frame(width: 26, height: 22)
                            .foregroundStyle(Color.white.opacity(selected ? 1 : 0.45))
                            .background(Capsule().fill(Color.white.opacity(selected ? 0.16 : 0)))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(PressStyle())
                    .help(tab.title)
                }
            }
            Spacer(minLength: state.notchSize.width + 12)
            HStack(spacing: 8) {
                Button {
                    NotificationCenter.default.post(name: .openIsleSettings, object: nil)
                } label: {
                    Image(systemName: "gearshape")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Color.white.opacity(0.55))
                        .frame(width: 20, height: 20)
                        .contentShape(Rectangle())
                }
                .buttonStyle(PressStyle())
                .help("Settings")

                Button { keepAwake.toggle() } label: {
                    Image(systemName: keepAwake.isOn ? "cup.and.saucer.fill" : "cup.and.saucer")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(keepAwake.isOn ? Color.yellow : Color.white.opacity(0.5))
                        .frame(width: 22, height: 20)
                        .contentShape(Rectangle())
                }
                .buttonStyle(PressStyle())
                .help(keepAwake.isOn ? "Keep awake is ON (click to turn off)" : "Keep your Mac awake")

                if let level = battery.level {
                    HStack(spacing: 3) {
                        Text("\(level)%").monospacedDigit()
                        Image(systemName: battery.symbol)
                    }
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(battery.charging ? Color.green : Color.white.opacity(0.7))
                }
            }
        }
    }
}

struct HomeTab: View {
    let features: Features
    var body: some View {
        HStack(spacing: 18) {
            QuotePanel(quotes: features.quotes).frame(width: 165)
            Separator()
            MusicPanel(music: features.music).frame(maxWidth: .infinity)
            Separator()
            StatsPanel(stats: features.stats).frame(width: 140)
        }
    }
}

struct Separator: View {
    var body: some View {
        Rectangle().fill(.white.opacity(0.12)).frame(width: 1).padding(.vertical, 10)
    }
}

struct QuotePanel: View {
    @ObservedObject var quotes: QuoteModel

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Image(systemName: "quote.opening")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(.orange)
            Text(quotes.current.text)
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .lineLimit(5)
                .minimumScaleFactor(0.75)
                .fixedSize(horizontal: false, vertical: true)
            Text("— \(quotes.current.author)")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .id(quotes.current.text)
        .transition(.opacity)
        .animation(.easeInOut(duration: 0.4), value: quotes.current)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .onTapGesture { withAnimation(.easeInOut(duration: 0.4)) { quotes.next() } }
        .help("A new quote every 5 minutes · click for another")
    }
}

struct MusicPanel: View {
    @ObservedObject var music: NowPlaying

    var body: some View {
        if let t = music.track {
            HStack(spacing: 12) {
                MediaArtworkView(track: t, artwork: music.artwork)
                    .frame(width: 48, height: 48)
                    .onTapGesture { music.openApp() }
                    .help("Click to open app")
                VStack(alignment: .leading, spacing: 4) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(t.title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                        Text(t.artist.isEmpty ? "Unknown" : t.artist)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { music.openApp() }
                    .help("Click to open app")

                    ProgressBar(fraction: t.duration > 0 ? min(t.position / t.duration, 1) : 0)
                        .padding(.top, 2)
                    HStack(spacing: 20) {
                        IconButton(symbol: "backward.fill") { music.previous() }
                        IconButton(symbol: t.playing ? "pause.fill" : "play.fill", size: 18) { music.playPause() }
                        IconButton(symbol: "forward.fill") { music.next() }
                    }
                    .frame(maxWidth: .infinity)
                }
            }
        } else if music.permissionDenied {
            VStack(spacing: 8) {
                Text("Allow Isle to control Music / Spotify to see what's playing")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                PillButton(title: "Open Privacy Settings") { openPrivacySettings("Privacy_Automation") }
            }
        } else {
            VStack(spacing: 6) {
                Image(systemName: "music.note").font(.system(size: 20))
                Text("Nothing playing right now")
                    .font(.system(size: 11))
                    .multilineTextAlignment(.center)
            }
            .foregroundStyle(.secondary)
        }
    }
}

struct MediaArtworkView: View {
    let track: NowPlaying.Track
    let artwork: NSImage?

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            if let img = artwork {
                Image(nsImage: img)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 48, height: 48)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .strokeBorder(Color.white.opacity(0.15), lineWidth: 0.5)
                    )
                if !track.bundleID.isEmpty {
                    AppIcon(bundleID: track.bundleID)
                        .frame(width: 16, height: 16)
                        .background(Circle().fill(Color.black.opacity(0.85)))
                        .offset(x: 3, y: 3)
                }
            } else if !track.bundleID.isEmpty {
                AppIcon(bundleID: track.bundleID)
                    .frame(width: 48, height: 48)
            } else {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.white.opacity(0.1))
                    .overlay(Image(systemName: "music.note").font(.system(size: 20)))
                    .frame(width: 48, height: 48)
            }
        }
    }
}

// MARK: - Small building blocks

struct IconButton: View {
    let symbol: String
    var size: CGFloat = 14
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size, weight: .semibold))
                .frame(width: 28, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(PressStyle())
    }
}

struct PressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.6 : 1)
            .scaleEffect(configuration.isPressed ? 0.88 : 1)
            .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
    }
}

struct ProgressBar: View {
    let fraction: Double
    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.18))
                Capsule().fill(.white).frame(width: geo.size.width * (fraction.isFinite ? max(0, min(fraction, 1)) : 0))
            }
        }
        .frame(height: 3)
        .animation(.linear(duration: 1), value: fraction)
    }
}

struct AppIcon: View {
    let bundleID: String
    private static var cache: [String: NSImage] = [:]   // main thread only (views)

    private static func icon(for id: String) -> NSImage? {
        if let cached = cache[id] { return cached }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) else { return nil }
        let img = NSWorkspace.shared.icon(forFile: url.path)
        cache[id] = img
        return img
    }

    var body: some View {
        if let img = Self.icon(for: bundleID) {
            Image(nsImage: img).resizable().scaledToFit()
        } else {
            Image(systemName: "music.note")
        }
    }
}
