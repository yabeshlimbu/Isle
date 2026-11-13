import AppKit
import ImageIO
import PDFKit
import UniformTypeIdentifiers

enum ImageFormat: String, CaseIterable {
    case jpg = "JPG", heic = "HEIC", png = "PNG"

    var type: UTType {
        switch self {
        case .jpg: return .jpeg
        case .heic: return .heic
        case .png: return .png
        }
    }
    var ext: String { rawValue.lowercased() }

    /// The format a file is already in, if it's one of ours.
    static func of(_ url: URL) -> ImageFormat? {
        switch url.pathExtension.lowercased() {
        case "jpg", "jpeg": return .jpg
        case "heic", "heif": return .heic
        case "png": return .png
        default: return nil
        }
    }
}

/// Converts photos between formats and combines photos into a PDF.
final class Converter: ObservableObject {
    enum Status: Equatable {
        case working(String)
        case done(String, [URL])
        case failed(String)
    }

    @Published private(set) var status: Status?
    var onOutputs: (([URL]) -> Void)?
    var onFinish: (() -> Void)?

    private let queue = DispatchQueue(label: "isle.convert", qos: .userInitiated)

    /// Fallback location when we can't write next to the original.
    private static let fallbackFolder: URL = {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Pictures/Isle", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    static func isImage(_ url: URL) -> Bool {
        UTType(filenameExtension: url.pathExtension)?.conforms(to: .image) ?? false
    }

    // MARK: Format conversion

    func convert(_ urls: [URL], to format: ImageFormat) {
        let images = urls.filter(Self.isImage)
        guard !images.isEmpty else { return finish(.failed("Those files aren't photos")) }
        let todo = images.filter { ImageFormat.of($0) != format }
        let skipped = images.count - todo.count
        guard !todo.isEmpty else { return finish(.failed("Already \(format.rawValue), nothing to do")) }

        status = .working("Converting \(plural(todo.count, "photo")) to \(format.rawValue)…")
        queue.async { [weak self] in
            var outputs: [URL] = []
            for url in todo {
                if let out = Self.convertOne(url, to: format) { outputs.append(out) }
            }
            let failed = todo.count - outputs.count
            var message = "Converted \(plural(outputs.count, "photo")) to \(format.rawValue)"
            if skipped > 0 { message += " · \(skipped) already \(format.rawValue)" }
            if failed > 0 { message += " · \(failed) failed" }
            DispatchQueue.main.async {
                self?.finish(outputs.isEmpty ? .failed("Couldn't convert those photos") : .done(message, outputs))
            }
        }
    }

    private static func convertOne(_ url: URL, to format: ImageFormat) -> URL? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              CGImageSourceGetCount(source) > 0,
              var image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }

        // Keep metadata (date, location, camera, orientation).
        var props = (CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]) ?? [:]
        if format != .png { props[kCGImageDestinationLossyCompressionQuality] = 0.9 }
        // JPG has no transparency: put transparent areas on white instead of black.
        if format == .jpg, hasAlpha(image), let flat = flattenOnWhite(image) { image = flat }

        let name = url.deletingPathExtension().lastPathComponent
        for folder in [url.deletingLastPathComponent(), fallbackFolder] {
            let out = uniqueURL(in: folder, name: name, ext: format.ext)
            guard let dest = CGImageDestinationCreateWithURL(out as CFURL, format.type.identifier as CFString, 1, nil)
            else { continue }
            CGImageDestinationAddImage(dest, image, props as CFDictionary)
            if CGImageDestinationFinalize(dest) { return out }
        }
        return nil
    }

    private static func hasAlpha(_ image: CGImage) -> Bool {
        switch image.alphaInfo {
        case .none, .noneSkipFirst, .noneSkipLast: return false
        default: return true
        }
    }

    private static func flattenOnWhite(_ image: CGImage) -> CGImage? {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: space,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        let rect = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        ctx.setFillColor(.white)
        ctx.fill(rect)
        ctx.draw(image, in: rect)
        return ctx.makeImage()
    }

    // MARK: PDF maker

    func makePDF(_ urls: [URL]) {
        let images = urls.filter(Self.isImage).sorted {
            $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending
        }
        guard !images.isEmpty else { return finish(.failed("Those files aren't photos")) }

        status = .working("Making a PDF from \(plural(images.count, "photo"))…")
        queue.async { [weak self] in
            let doc = PDFDocument()
            let thumbOptions = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,   // apply rotation
                kCGImageSourceThumbnailMaxPixelSize: 2400,           // keeps the PDF a sensible size
            ] as CFDictionary

            for url in images {
                guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                      let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbOptions) else { continue }
                // A4 page, turned to match the photo.
                let page = cg.width > cg.height
                    ? CGRect(x: 0, y: 0, width: 842, height: 595)
                    : CGRect(x: 0, y: 0, width: 595, height: 842)
                let image = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
                if let pdfPage = PDFPage(image: image, options: [
                    .mediaBox: NSValue(rect: page),
                    .compressionQuality: 0.8,
                    .upscaleIfSmaller: true,
                ]) {
                    doc.insert(pdfPage, at: doc.pageCount)
                }
            }

            var result: Status = .failed("Couldn't make the PDF")
            if doc.pageCount > 0 {
                let name = images.count == 1 ? images[0].deletingPathExtension().lastPathComponent : "Photos"
                for folder in [images[0].deletingLastPathComponent(), Self.fallbackFolder] {
                    let out = Self.uniqueURL(in: folder, name: name, ext: "pdf")
                    if doc.write(to: out) {
                        result = .done("Made a \(plural(doc.pageCount, "page")) PDF", [out])
                        break
                    }
                }
            }
            DispatchQueue.main.async { self?.finish(result) }
        }
    }

    // MARK: Helpers

    private func finish(_ result: Status) {
        status = result
        if case .done(_, let urls) = result { onOutputs?(urls) }
        onFinish?()
        // Clear the message after a while.
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in
            if self?.status == result { self?.status = nil }
        }
    }

    /// "Photo.jpg", or "Photo 2.jpg" if that already exists.
    private static func uniqueURL(in folder: URL, name: String, ext: String) -> URL {
        var candidate = folder.appendingPathComponent(name).appendingPathExtension(ext)
        var n = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = folder.appendingPathComponent("\(name) \(n)").appendingPathExtension(ext)
            n += 1
        }
        return candidate
    }
}

func plural(_ n: Int, _ word: String) -> String { "\(n) \(word)\(n == 1 ? "" : "s")" }

/// Resolve dropped items to file URLs (in order).
func loadFileURLs(_ providers: [NSItemProvider], completion: @escaping ([URL]) -> Void) {
    let group = DispatchGroup()
    let lock = NSLock()
    var results = [URL?](repeating: nil, count: providers.count)
    for (i, provider) in providers.enumerated() {
        group.enter()
        _ = provider.loadObject(ofClass: URL.self) { url, _ in
            lock.lock()
            results[i] = url
            lock.unlock()
            group.leave()
        }
    }
    group.notify(queue: .main) {
        completion(results.compactMap { $0 }.filter(\.isFileURL))
    }
}
