import AppKit
import SwiftUI

/// Actions offered while files are being dragged over the notch.
enum DropZone: String, CaseIterable, Identifiable {
    case shelf, jpg, heic, png, pdf
    var id: String { rawValue }

    var title: String {
        switch self {
        case .shelf: return "Shelf"
        case .jpg: return "To JPG"
        case .heic: return "To HEIC"
        case .png: return "To PNG"
        case .pdf: return "Make PDF"
        }
    }
    var subtitle: String {
        switch self {
        case .shelf: return "Keep for later"
        case .jpg: return "Works everywhere"
        case .heic: return "Smaller files"
        case .png: return "No quality loss"
        case .pdf: return "A page per photo"
        }
    }
    var symbol: String {
        switch self {
        case .shelf: return "tray.and.arrow.down.fill"
        case .jpg, .heic, .png: return "arrow.triangle.2.circlepath"
        case .pdf: return "doc.richtext.fill"
        }
    }
    var format: ImageFormat? {
        switch self {
        case .jpg: return .jpg
        case .heic: return .heic
        case .png: return .png
        default: return nil
        }
    }

    /// Which zones make sense for the files being dragged.
    static func zones(for files: [URL]) -> [DropZone] {
        let images = files.filter(Converter.isImage)
        guard !images.isEmpty else { return [.shelf] }
        let formats = Set(images.map(ImageFormat.of))
        return allCases.filter { zone in
            guard let f = zone.format else { return true }
            return !(formats.count == 1 && formats.first == f)   // hide "To JPG" if they're all JPGs
        }
    }
}

struct DropZonesView: View {
    @ObservedObject var state: IslandState
    let onDrop: (DropZone, [NSItemProvider]) -> Void

    var body: some View {
        let images = state.dragFiles.filter(Converter.isImage).count
        let others = state.dragFiles.count - images
        VStack(spacing: 6) {
            Text(images > 0
                 ? "\(plural(images, "photo"))\(others > 0 ? " + \(plural(others, "other file"))" : "") · drop on an action"
                 : "Drop to keep \(state.dragFiles.count == 1 ? "it" : "them") on the Shelf")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
            HStack(spacing: 8) {
                ForEach(DropZone.zones(for: state.dragFiles)) { zone in
                    ZoneTile(zone: zone, highlighted: state.hoveredZone == zone)
                        .onDrop(of: [.fileURL], isTargeted: Binding(
                            get: { state.hoveredZone == zone },
                            set: { on in
                                if on { state.hoveredZone = zone }
                                else if state.hoveredZone == zone { state.hoveredZone = nil }
                            })) { providers in
                            onDrop(zone, providers)
                            return true
                        }
                }
            }
        }
    }
}

struct ZoneTile: View {
    let zone: DropZone
    let highlighted: Bool

    var body: some View {
        VStack(spacing: 4) {
            Image(systemName: zone.symbol).font(.system(size: 18, weight: .semibold))
            Text(zone.title).font(.system(size: 12, weight: .bold))
            Text(zone.subtitle).font(.system(size: 9)).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.white.opacity(highlighted ? 0.24 : 0.07)))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: highlighted ? [] : [5]))
                .foregroundStyle(Color.white.opacity(highlighted ? 0.8 : 0.2))
        )
        .scaleEffect(highlighted ? 1.05 : 1)
        .animation(.spring(response: 0.25, dampingFraction: 0.7), value: highlighted)
    }
}

/// Progress / result line shown on the Shelf tab.
struct StatusBanner: View {
    @ObservedObject var converter: Converter

    var body: some View {
        if let status = converter.status {
            HStack(spacing: 8) {
                switch status {
                case .working(let text):
                    ProgressView().controlSize(.small).scaleEffect(0.7).frame(width: 14, height: 14)
                    Text(text)
                case .done(let text, let urls):
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    Text(text)
                    Spacer(minLength: 6)
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting(urls) }
                        .buttonStyle(PressStyle())
                        .foregroundStyle(Color.accentColor)
                case .failed(let text):
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Text(text)
                }
                Spacer(minLength: 0)
            }
            .font(.system(size: 11, weight: .medium))
            .lineLimit(1)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.08)))
        }
    }
}
