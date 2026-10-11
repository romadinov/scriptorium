// Renders the app icon (1024×1024, opaque) — run: swift scripts/make-icon.swift <out.png>
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let size = 1024.0
let ctx = CGContext(data: nil, width: Int(size), height: Int(size), bitsPerComponent: 8, bytesPerRow: 0,
                    space: CGColorSpace(name: CGColorSpace.displayP3)!,
                    bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
func rgb(_ r: Double, _ g: Double, _ b: Double, _ a: Double = 1) -> CGColor { CGColor(red: r, green: g, blue: b, alpha: a) }

// Background: deep ink-blue to teal diagonal.
let bg = CGGradient(colorsSpace: nil, colors: [rgb(0.09, 0.13, 0.32), rgb(0.06, 0.42, 0.52)] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(bg, start: CGPoint(x: 0, y: size), end: CGPoint(x: size, y: 0), options: [])

// Soft glow behind the book.
let glow = CGGradient(colorsSpace: nil, colors: [rgb(1, 0.9, 0.6, 0.35), rgb(1, 0.9, 0.6, 0)] as CFArray, locations: [0, 1])!
ctx.drawRadialGradient(glow, startCenter: CGPoint(x: 512, y: 470), startRadius: 0,
                       endCenter: CGPoint(x: 512, y: 470), endRadius: 430, options: [])

// Open book: two curved pages meeting at a spine.
func page(left: Bool) -> CGPath {
    let p = CGMutablePath()
    let s: Double = left ? -1 : 1
    let spineTop = CGPoint(x: 512, y: 640), spineBottom = CGPoint(x: 512, y: 250)
    p.move(to: spineBottom)
    p.addCurve(to: CGPoint(x: 512 + s * 330, y: 300), control1: CGPoint(x: 512 + s * 110, y: 300),
               control2: CGPoint(x: 512 + s * 230, y: 270))
    p.addLine(to: CGPoint(x: 512 + s * 330, y: 700))
    p.addCurve(to: spineTop, control1: CGPoint(x: 512 + s * 230, y: 680), control2: CGPoint(x: 512 + s * 110, y: 700))
    p.closeSubpath()
    return p
}
ctx.setShadow(offset: CGSize(width: 0, height: -14), blur: 30, color: rgb(0, 0, 0, 0.35))
for left in [true, false] {
    ctx.addPath(page(left: left))
    ctx.setFillColor(left ? rgb(0.98, 0.96, 0.91) : rgb(1, 0.99, 0.96))
    ctx.fillPath()
}
ctx.setShadow(offset: .zero, blur: 0, color: nil)

// Text lines on the pages.
ctx.setStrokeColor(rgb(0.55, 0.6, 0.7, 0.55))
ctx.setLineWidth(14)
ctx.setLineCap(.round)
for i in 0..<5 {
    let y = 590.0 - Double(i) * 62
    for s in [-1.0, 1.0] {
        let inner = 512 + s * 70, outer = 512 + s * (i == 4 ? 190 : 270)
        ctx.move(to: CGPoint(x: inner, y: y - 18 + Double(i) * 2))
        ctx.addLine(to: CGPoint(x: outer, y: y - 8))
    }
}
ctx.strokePath()

// Highlighter stroke across one line (yellow, translucent).
ctx.setStrokeColor(rgb(1, 0.82, 0.2, 0.75))
ctx.setLineWidth(34)
ctx.move(to: CGPoint(x: 582, y: 459)); ctx.addLine(to: CGPoint(x: 770, y: 468))
ctx.strokePath()

// Sparkle (four-point star) top-right = the assistant.
func sparkle(_ c: CGPoint, _ r: Double) {
    let p = CGMutablePath()
    p.move(to: CGPoint(x: c.x, y: c.y + r))
    for (dx, dy) in [(1.0, 0.0), (0.0, -1.0), (-1.0, 0.0), (0.0, 1.0)] {
        p.addQuadCurve(to: CGPoint(x: c.x + dx * r, y: c.y + dy * r), control: c)
    }
    ctx.addPath(p)
    ctx.setFillColor(rgb(1, 0.86, 0.35))
    ctx.fillPath()
}
ctx.setShadow(offset: .zero, blur: 24, color: rgb(1, 0.85, 0.3, 0.8))
sparkle(CGPoint(x: 790, y: 810), 120)
sparkle(CGPoint(x: 905, y: 655), 48)

let image = ctx.makeImage()!
let url = URL(fileURLWithPath: CommandLine.arguments[1])
let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
CGImageDestinationAddImage(dest, image, nil)
CGImageDestinationFinalize(dest)
