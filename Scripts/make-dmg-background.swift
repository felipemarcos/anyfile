#!/usr/bin/env swift
// Draws the disk image background (660×400 pt, with @2x) into Scripts/dmg/.
// Icons sit at (170, 190) and (490, 190) in Finder's top-left coordinates; see make-dmg.sh.
import AppKit

let outDir = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "Scripts/dmg")
let width: CGFloat = 660, height: CGFloat = 400

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

func render(scale: CGFloat) -> CGImage {
    let ctx = CGContext(data: nil, width: Int(width * scale), height: Int(height * scale), bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.scaleBy(x: scale, y: scale)

    let background = CGGradient(colorsSpace: nil, colors: [color(0xF7F5FF), color(0xE6E0FF)] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(background, start: CGPoint(x: 0, y: height), end: CGPoint(x: 0, y: 0), options: [])

    // Arrow between the two icons (Finder y=190 → CG y=210).
    let y: CGFloat = height - 190
    let arrow = CGMutablePath()
    arrow.move(to: CGPoint(x: 262, y: y))
    arrow.addLine(to: CGPoint(x: 390, y: y))
    ctx.setLineCap(.round)
    ctx.setLineWidth(7)
    ctx.setStrokeColor(color(0x6D55F2, 0.85))
    ctx.addPath(arrow)
    ctx.strokePath()
    let head = CGMutablePath()
    head.move(to: CGPoint(x: 372, y: y + 20))
    head.addLine(to: CGPoint(x: 398, y: y))
    head.addLine(to: CGPoint(x: 372, y: y - 20))
    ctx.setLineJoin(.round)
    ctx.addPath(head)
    ctx.strokePath()

    // Caption.
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
    let style = NSMutableParagraphStyle()
    style.alignment = .center
    let caption = NSAttributedString(string: "Drag AnyFile to Applications to install", attributes: [
        .font: NSFont.systemFont(ofSize: 15, weight: .medium),
        .foregroundColor: NSColor(srgbRed: 0.27, green: 0.22, blue: 0.48, alpha: 1),
        .paragraphStyle: style,
    ])
    caption.draw(in: CGRect(x: 0, y: 62, width: width, height: 24))
    NSGraphicsContext.restoreGraphicsState()

    return ctx.makeImage()!
}

try! FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
for (scale, name) in [(1.0, "background.png"), (2.0, "background@2x.png")] {
    let rep = NSBitmapImageRep(cgImage: render(scale: scale))
    rep.size = NSSize(width: width, height: height) // 72 dpi at 1x, 144 dpi at 2x
    try! rep.representation(using: .png, properties: [:])!.write(to: outDir.appendingPathComponent(name))
}
print("Wrote background.png and background@2x.png to \(outDir.path)")
