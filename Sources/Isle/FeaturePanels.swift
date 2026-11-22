import AppKit
import AVFoundation
import SwiftUI

// MARK: - Shared bits

struct PillButton: View {
    let title: String
    var symbol: String?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if let symbol { Image(systemName: symbol) }
                Text(title)
            }
            .font(.system(size: 11, weight: .semibold))
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Capsule().fill(Color.white.opacity(0.14)))
            .contentShape(Capsule())
        }
        .buttonStyle(PressStyle())
    }
}

struct EmptyMessage: View {
    let symbol: String
    let text: String
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: symbol).font(.system(size: 22))
            Text(text).font(.system(size: 11)).multilineTextAlignment(.center)
        }
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

func openPrivacySettings(_ anchor: String) {
    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") {
        NSWorkspace.shared.open(url)
    }
}

// MARK: - Calendar

struct CalendarPanel: View {
    @ObservedObject var model: CalendarModel

    var body: some View {
        switch model.access {
        case .notDetermined:
            VStack(spacing: 10) {
                EmptyMessage(symbol: "calendar", text: "See the rest of today's events here.")
                PillButton(title: "Allow Calendar Access", symbol: "lock.open") { model.requestAccess() }
            }
        case .denied:
            VStack(spacing: 10) {
                EmptyMessage(symbol: "calendar.badge.exclamationmark",
                             text: "Calendar access is off for Isle.")
                PillButton(title: "Open Privacy Settings") { openPrivacySettings("Privacy_Calendars") }
            }
        case .granted:
            if model.events.isEmpty {
                EmptyMessage(symbol: "checkmark.circle", text: "Nothing else on your calendar today.")
            } else {
                ScrollView(showsIndicators: false) {
                    VStack(spacing: 5) {
                        ForEach(model.events) { event in
                            EventRow(event: event).onTapGesture { model.openCalendarApp() }
                        }
                    }
                }
            }
        }
    }
}

struct EventRow: View {
    let event: CalendarModel.Event

    var body: some View {
        let now = Date()
        let happening = !event.allDay && event.start <= now && event.end > now
        HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 2).fill(Color(nsColor: event.color)).frame(width: 4, height: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text(event.title).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                Group {
                    if event.allDay {
                        Text("All day")
                    } else {
                        Text(event.start, style: .time) + Text(" – ") + Text(event.end, style: .time)
                    }
                }
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            }
            Spacer()
            if happening {
                Text("NOW").font(.system(size: 9, weight: .bold))
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Capsule().fill(Color.green.opacity(0.3)))
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 9).fill(Color.white.opacity(0.06)))
        .contentShape(Rectangle())
    }
}

// MARK: - Clipboard

struct ClipboardPanel: View {
    @ObservedObject var model: ClipboardHistory

    var body: some View {
        if model.items.isEmpty {
            EmptyMessage(symbol: "doc.on.clipboard", text: "Copy some text and it'll show up here.\nClick an item to copy it again.")
        } else {
            VStack(spacing: 4) {
                HStack {
                    Text("Click to copy").font(.system(size: 10)).foregroundStyle(.secondary)
                    Spacer()
                    Button("Clear") { model.clear() }
                        .buttonStyle(PressStyle())
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                ScrollView(showsIndicators: false) {
                    LazyVStack(spacing: 4) {
                        ForEach(model.items) { item in
                            Button { model.copy(item) } label: {
                                HStack(spacing: 8) {
                                    Image(systemName: model.copiedID == item.id ? "checkmark" : "doc.on.doc")
                                        .font(.system(size: 10))
                                        .foregroundStyle(model.copiedID == item.id ? Color.green : Color.secondary)
                                        .frame(width: 14)
                                    Text(item.text.replacingOccurrences(of: "\n", with: " ")
                                            .trimmingCharacters(in: .whitespaces))
                                        .font(.system(size: 12))
                                        .lineLimit(1)
                                    Spacer(minLength: 8)
                                    Text(item.date, format: .relative(presentation: .numeric, unitsStyle: .narrow))
                                        .font(.system(size: 10))
                                        .foregroundStyle(.tertiary)
                                }
                                .padding(.horizontal, 10)
                                .padding(.vertical, 5)
                                .background(RoundedRectangle(cornerRadius: 7).fill(Color.white.opacity(0.06)))
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(PressStyle())
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Shelf

struct ShelfPanel: View {
    @ObservedObject var shelf: Shelf
    @ObservedObject var converter: Converter
    @ObservedObject var state: IslandState

    var body: some View {
        VStack(spacing: 6) {
            StatusBanner(converter: converter)
            if shelf.files.isEmpty {
                EmptyMessage(symbol: "tray.and.arrow.down",
                             text: "Drag files onto the notch to keep them here.\nDrag photos there to convert them or make a PDF.")
                    .background(
                        RoundedRectangle(cornerRadius: 14)
                            .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [5]))
                            .foregroundStyle(Color.white.opacity(state.dropTargeted ? 0.6 : 0.2))
                    )
            } else {
                HStack(spacing: 12) {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(shelf.files, id: \.self) { url in
                                FileTile(url: url,
                                         onRemove: { shelf.remove(url) },
                                         onDragStart: { state.internalDrag = true })
                            }
                        }
                    }
                    VStack(spacing: 6) {
                        if shelf.files.contains(where: Converter.isImage) {
                            Menu {
                                ForEach(ImageFormat.allCases, id: \.self) { format in
                                    Button("Convert to \(format.rawValue)") { converter.convert(shelf.files, to: format) }
                                }
                                Divider()
                                Button("Make PDF from Photos") { converter.makePDF(shelf.files) }
                            } label: {
                                Label("Convert", systemImage: "arrow.triangle.2.circlepath")
                            }
                            .menuStyle(.borderlessButton)
                            .menuIndicator(.hidden)
                            .fixedSize()
                            .font(.system(size: 11, weight: .semibold))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(Capsule().fill(Color.white.opacity(0.14)))
                        }
                        PillButton(title: "AirDrop", symbol: "airplayaudio") { shelf.airDrop() }
                        PillButton(title: "Clear", symbol: "trash") { shelf.clear() }
                    }
                }
            }
        }
    }
}

struct FileTile: View {
    let url: URL
    let onRemove: () -> Void
    let onDragStart: () -> Void

    var body: some View {
        VStack(spacing: 4) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                .resizable()
                .frame(width: 44, height: 44)
            Text(url.lastPathComponent)
                .font(.system(size: 10))
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(width: 72)
        }
        .padding(6)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(0.06)))
        .overlay(alignment: .topTrailing) {
            Button(action: onRemove) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(Color.white.opacity(0.6))
            }
            .buttonStyle(PressStyle())
            .offset(x: 4, y: -4)
        }
        .onTapGesture(count: 2) { NSWorkspace.shared.open(url) }
        .onDrag {
            onDragStart()
            return NSItemProvider(contentsOf: url) ?? NSItemProvider()
        }
        .help("Drag out to use · double-click to open")
    }
}

// MARK: - Notes

struct NotesPanel: View {
    @ObservedObject var notes: NotesModel

    var body: some View {
        ZStack(alignment: .topLeading) {
            TextEditor(text: $notes.text)
                .font(.system(size: 13))
                .scrollContentBackground(.hidden)
                .padding(6)
            if notes.text.isEmpty {
                Text("Click and jot something down… (saved automatically)")
                    .font(.system(size: 13))
                    .foregroundStyle(.tertiary)
                    .padding(.leading, 11)
                    .padding(.top, 6)
                    .allowsHitTesting(false)
            }
        }
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(0.06)))
    }
}

// MARK: - Camera mirror

struct CameraPanel: View {
    @ObservedObject var camera: CameraMirror

    var body: some View {
        switch camera.access {
        case .notDetermined:
            VStack(spacing: 10) {
                EmptyMessage(symbol: "camera", text: "Check how you look before a call.")
                PillButton(title: "Allow Camera Access", symbol: "lock.open") { camera.requestAccess() }
            }
        case .denied:
            VStack(spacing: 10) {
                EmptyMessage(symbol: "video.slash", text: "Camera access is off for Isle.")
                PillButton(title: "Open Privacy Settings") { openPrivacySettings("Privacy_Camera") }
            }
        case .granted:
            CameraPreview(session: camera.session)
                .frame(width: 220)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .frame(maxWidth: .infinity)
        }
    }
}

struct CameraPreview: NSViewRepresentable {
    let session: AVCaptureSession

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        let layer = AVCaptureVideoPreviewLayer(session: session)
        layer.videoGravity = .resizeAspectFill
        view.layer = layer
        view.wantsLayer = true
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}
