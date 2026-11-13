// Draws Isle's app icon.  Run:  swift tools/make-icon.swift <out.png>
import AppKit

let size: CGFloat = 1024
let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon.png"
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size),
                           bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                           colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let ctx = NSGraphicsContext.current!.cgContext
let space = CGColorSpaceCreateDeviceRGB()
func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor { CGColor(red: r, green: g, blue: b, alpha: a) }

// macOS icon grid: 824pt rounded square centred in 1024 with a soft drop shadow.
let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
let tilePath = CGPath(roundedRect: tile, cornerWidth: 185, cornerHeight: 185, transform: nil)
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: rgb(0, 0, 0, 0.35))
ctx.addPath(tilePath); ctx.setFillColor(rgb(0.1, 0.1, 0.15)); ctx.fillPath()
ctx.restoreGState()

// Background: dusk sky fading into a calm sea.
ctx.saveGState()
ctx.addPath(tilePath); ctx.clip()
let sky = CGGradient(colorsSpace: space, colors: [rgb(0.99, 0.62, 0.38), rgb(0.80, 0.36, 0.58), rgb(0.29, 0.20, 0.52), rgb(0.08, 0.09, 0.22)] as CFArray,
                     locations: [0, 0.35, 0.7, 1])!
ctx.drawLinearGradient(sky, start: CGPoint(x: 512, y: 100), end: CGPoint(x: 512, y: 924), options: [])
// Glow behind the island.
let glow = CGGradient(colorsSpace: space, colors: [rgb(1, 0.85, 0.6, 0.55), rgb(1, 0.85, 0.6, 0)] as CFArray, locations: [0, 1])!
ctx.drawRadialGradient(glow, startCenter: CGPoint(x: 512, y: 650), startRadius: 0,
                       endCenter: CGPoint(x: 512, y: 650), endRadius: 360, options: [])
// Gentle wave lines, low in the tile.
ctx.setLineCap(.round)
for (i, y) in [300.0, 240.0, 180.0].enumerated() {
    let p = CGMutablePath()
    p.move(to: CGPoint(x: 60, y: y))
    p.addCurve(to: CGPoint(x: 964, y: y), control1: CGPoint(x: 360, y: y + 70), control2: CGPoint(x: 660, y: y - 70))
    ctx.addPath(p)
    ctx.setStrokeColor(rgb(1, 1, 1, 0.16 - CGFloat(i) * 0.04))
    ctx.setLineWidth(14)
    ctx.strokePath()
}
ctx.restoreGState()

// The island: a black pill with a soft shadow.
let island = CGRect(x: 226, y: 575, width: 400, height: 150)
let islandPath = CGPath(roundedRect: island, cornerWidth: 75, cornerHeight: 75, transform: nil)
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -14), blur: 40, color: rgb(0, 0, 0, 0.5))
ctx.addPath(islandPath); ctx.setFillColor(rgb(0, 0, 0)); ctx.fillPath()
ctx.restoreGState()
// Inside the island: album-art square and a little equaliser.
let art = CGRect(x: island.minX + 38, y: island.midY - 40, width: 80, height: 80)
ctx.saveGState()
ctx.addPath(CGPath(roundedRect: art, cornerWidth: 18, cornerHeight: 18, transform: nil)); ctx.clip()
let artGrad = CGGradient(colorsSpace: space, colors: [rgb(1, 0.45, 0.45), rgb(0.62, 0.36, 0.95)] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(artGrad, start: CGPoint(x: art.minX, y: art.maxY), end: CGPoint(x: art.maxX, y: art.minY), options: [])
ctx.restoreGState()
ctx.setFillColor(rgb(0.36, 0.89, 0.52))
for (i, h) in [34.0, 62.0, 46.0, 70.0].enumerated() {
    let x = island.maxX - 125 + CGFloat(i) * 24
    ctx.addPath(CGPath(roundedRect: CGRect(x: x, y: island.midY - h / 2, width: 13, height: h), cornerWidth: 6.5, cornerHeight: 6.5, transform: nil))
    ctx.fillPath()
}

// An activity circle riding beside the island, with a progress ring.
let r: CGFloat = 70, c = CGPoint(x: island.maxX + 32 + r, y: island.midY)
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 30, color: rgb(0, 0, 0, 0.45))
ctx.addEllipse(in: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r)); ctx.setFillColor(rgb(0, 0, 0)); ctx.fillPath()
ctx.restoreGState()
ctx.setLineWidth(13)
ctx.setStrokeColor(rgb(1, 1, 1, 0.18))
ctx.addArc(center: c, radius: r - 18, startAngle: 0, endAngle: .pi * 2, clockwise: false); ctx.strokePath()
ctx.setStrokeColor(rgb(1, 0.78, 0.25))
ctx.addArc(center: c, radius: r - 18, startAngle: .pi / 2, endAngle: .pi / 2 - .pi * 1.35, clockwise: true); ctx.strokePath()

NSGraphicsContext.current = nil
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
print("wrote \(out)")
