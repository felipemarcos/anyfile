#!/usr/bin/env swift
// Draws the AnyFile app icon and writes every macOS size into the asset catalog.
// Usage: swift Scripts/make-icon.swift [output.appiconset]
import AppKit

let outputDir = URL(fileURLWithPath: CommandLine.arguments.count > 1
    ? CommandLine.arguments[1]
    : "AnyFile/Assets.xcassets/AppIcon.appiconset")

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

/// A document sheet with a folded top-right corner, centred on the origin.
func sheetPath(width w: CGFloat, height h: CGFloat, radius r: CGFloat, fold f: CGFloat) -> CGPath {
    let p = CGMutablePath()
    let x0 = -w / 2, y0 = -h / 2, x1 = w / 2, y1 = h / 2
    p.move(to: CGPoint(x: x0 + r, y: y0))
    p.addLine(to: CGPoint(x: x1 - r, y: y0))
    p.addArc(tangent1End: CGPoint(x: x1, y: y0), tangent2End: CGPoint(x: x1, y: y0 + r), radius: r)
    p.addLine(to: CGPoint(x: x1, y: y1 - f))
    p.addLine(to: CGPoint(x: x1 - f, y: y1))
    p.addLine(to: CGPoint(x: x0 + r, y: y1))
    p.addArc(tangent1End: CGPoint(x: x0, y: y1), tangent2End: CGPoint(x: x0, y: y1 - r), radius: r)
    p.addLine(to: CGPoint(x: x0, y: y0 + r))
    p.addArc(tangent1End: CGPoint(x: x0, y: y0), tangent2End: CGPoint(x: x0 + r, y: y0), radius: r)
    p.closeSubpath()
    return p
}

func foldPath(width w: CGFloat, height h: CGFloat, fold f: CGFloat) -> CGPath {
    let p = CGMutablePath()
    p.move(to: CGPoint(x: w / 2 - f, y: h / 2))
    p.addLine(to: CGPoint(x: w / 2 - f, y: h / 2 - f + 18))
    p.addQuadCurve(to: CGPoint(x: w / 2 - f + 18, y: h / 2 - f), control: CGPoint(x: w / 2 - f, y: h / 2 - f))
    p.addLine(to: CGPoint(x: w / 2, y: h / 2 - f))
    p.closeSubpath()
    return p
}

func symbolMask(_ name: String, pointSize: CGFloat) -> CGImage {
    let config = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .heavy)
    let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)!.withSymbolConfiguration(config)!
    var rect = CGRect(origin: .zero, size: image.size)
    return image.cgImage(forProposedRect: &rect, context: nil, hints: nil)!
}

/// Renders the 1024×1024 master on the macOS icon grid (824pt squircle, 100pt margin).
func renderMaster() -> CGImage {
    let size = 1024
    let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
    let tilePath = CGPath(roundedRect: tile, cornerWidth: 186, cornerHeight: 186, transform: nil)

    // Drop shadow under the tile.
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 28, color: color(0x000000, 0.35))
    ctx.addPath(tilePath)
    ctx.setFillColor(color(0x2B1A8F))
    ctx.fillPath()
    ctx.restoreGState()

    // Background: violet → indigo, with a soft light from the top.
    ctx.saveGState()
    ctx.addPath(tilePath)
    ctx.clip()
    let background = CGGradient(colorsSpace: nil, colors: [color(0x8A6CFF), color(0x4B2FD6), color(0x22137A)] as CFArray,
                                locations: [0, 0.55, 1])!
    ctx.drawLinearGradient(background, start: CGPoint(x: 300, y: 924), end: CGPoint(x: 724, y: 100), options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    let glow = CGGradient(colorsSpace: nil, colors: [color(0xFFFFFF, 0.28), color(0xFFFFFF, 0)] as CFArray, locations: [0, 1])!
    ctx.drawRadialGradient(glow, startCenter: CGPoint(x: 512, y: 980), startRadius: 0,
                           endCenter: CGPoint(x: 512, y: 980), endRadius: 620, options: [])
    ctx.restoreGState()

    let sheetW: CGFloat = 430, sheetH: CGFloat = 540, fold: CGFloat = 112

    // Back sheet: the "before" file, tilted and translucent.
    ctx.saveGState()
    ctx.translateBy(x: 440, y: 530)
    ctx.rotate(by: 11 * .pi / 180)
    ctx.addPath(sheetPath(width: sheetW, height: sheetH, radius: 44, fold: fold))
    ctx.setFillColor(color(0xFFFFFF, 0.30))
    ctx.fillPath()
    ctx.addPath(foldPath(width: sheetW, height: sheetH, fold: fold))
    ctx.setFillColor(color(0xFFFFFF, 0.22))
    ctx.fillPath()
    ctx.restoreGState()

    // Front sheet: the "after" file.
    ctx.saveGState()
    ctx.translateBy(x: 572, y: 486)
    ctx.rotate(by: -5 * .pi / 180)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -14), blur: 36, color: color(0x12073F, 0.45))
    ctx.addPath(sheetPath(width: sheetW, height: sheetH, radius: 44, fold: fold))
    ctx.setFillColor(color(0xFFFFFF))
    ctx.fillPath()
    ctx.restoreGState()
    ctx.addPath(foldPath(width: sheetW, height: sheetH, fold: fold))
    let foldGradient = CGGradient(colorsSpace: nil, colors: [color(0xD9D4F5), color(0xB9B0EE)] as CFArray, locations: [0, 1])!
    ctx.saveGState()
    ctx.clip()
    ctx.drawLinearGradient(foldGradient, start: CGPoint(x: sheetW / 2 - fold, y: sheetH / 2),
                           end: CGPoint(x: sheetW / 2, y: sheetH / 2 - fold), options: [])
    ctx.restoreGState()

    // Conversion arrows on the front sheet, filled with a cyan → violet gradient.
    let mask = symbolMask("arrow.triangle.2.circlepath", pointSize: 230)
    let scale = 300 / CGFloat(max(mask.width, mask.height))
    let mw = CGFloat(mask.width) * scale, mh = CGFloat(mask.height) * scale
    let symbolRect = CGRect(x: -mw / 2, y: -mh / 2 - 26, width: mw, height: mh)
    ctx.saveGState()
    ctx.clip(to: symbolRect, mask: mask)
    let accent = CGGradient(colorsSpace: nil, colors: [color(0x14C8E8), color(0x5B3BF0)] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(accent, start: CGPoint(x: symbolRect.minX, y: symbolRect.maxY),
                           end: CGPoint(x: symbolRect.maxX, y: symbolRect.minY), options: [])
    ctx.restoreGState()
    ctx.restoreGState()

    return ctx.makeImage()!
}

func resized(_ image: CGImage, to pixels: Int) -> CGImage {
    let ctx = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.interpolationQuality = .high
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: pixels, height: pixels))
    return ctx.makeImage()!
}

func writePNG(_ image: CGImage, to url: URL) {
    let rep = NSBitmapImageRep(cgImage: image)
    try! rep.representation(using: .png, properties: [:])!.write(to: url)
}

try! FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
let master = renderMaster()
var images: [[String: String]] = []
for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = "icon_\(points)x\(points)\(scale == 2 ? "@2x" : "").png"
        writePNG(resized(master, to: points * scale), to: outputDir.appendingPathComponent(name))
        images.append(["idiom": "mac", "size": "\(points)x\(points)", "scale": "\(scale)x", "filename": name])
    }
}
let contents: [String: Any] = ["images": images, "info": ["author": "xcode", "version": 1]]
let json = try! JSONSerialization.data(withJSONObject: contents, options: [.prettyPrinted, .sortedKeys])
try! json.write(to: outputDir.appendingPathComponent("Contents.json"))

let catalog = outputDir.deletingLastPathComponent().appendingPathComponent("Contents.json")
if !FileManager.default.fileExists(atPath: catalog.path) {
    try! Data(#"{"info":{"author":"xcode","version":1}}"#.utf8).write(to: catalog)
}
print("Wrote \(images.count) icons to \(outputDir.path)")
