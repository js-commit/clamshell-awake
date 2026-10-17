// Renders the three menu bar icon states at 4x on light and dark strips, for eyeballing.
// Keep the icon() body in sync with Sources/main.swift.
import AppKit

func icon(badge: String) -> NSImage {
    let img = NSImage(size: NSSize(width: 24, height: 18), flipped: false) { rect in
        let baseCfg = NSImage.SymbolConfiguration(pointSize: 15, weight: .regular)
        guard let base = NSImage(systemSymbolName: "laptopcomputer", accessibilityDescription: nil)?
            .withSymbolConfiguration(baseCfg) else { return false }
        let bs = base.size
        base.draw(in: NSRect(x: (rect.width - bs.width) / 2 - 1, y: (rect.height - bs.height) / 2,
                             width: bs.width, height: bs.height))
        let badgeCfg = NSImage.SymbolConfiguration(pointSize: 7, weight: .black)
        guard let b = NSImage(systemSymbolName: badge, accessibilityDescription: nil)?
            .withSymbolConfiguration(badgeCfg) else { return true }
        let d: CGFloat = 11
        let circle = NSRect(x: rect.width - d, y: 0, width: d, height: d)
        if let ctx = NSGraphicsContext.current {
            ctx.saveGraphicsState()
            ctx.compositingOperation = .destinationOut
            NSColor.black.setFill()
            NSBezierPath(ovalIn: circle).fill()
            ctx.restoreGraphicsState()
        }
        let s = b.size
        b.draw(in: NSRect(x: circle.midX - s.width / 2, y: circle.midY - s.height / 2, width: s.width, height: s.height))
        return true
    }
    img.isTemplate = true
    return img
}

let scale: CGFloat = 4
let badges = ["bolt.fill", "hourglass", "moon.fill"]
let w = Int(CGFloat(badges.count) * 40 * scale), h = Int(2 * 22 * scale)
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h, bitsPerSample: 8,
                           samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                           colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let ctx = NSGraphicsContext.current!.cgContext
ctx.scaleBy(x: scale, y: scale)
for (row, (bg, fg)) in [(NSColor(white: 0.93, alpha: 1), NSColor.black), (NSColor(white: 0.12, alpha: 1), NSColor.white)].enumerated() {
    let y = CGFloat(row) * 22
    bg.setFill(); NSRect(x: 0, y: y, width: CGFloat(badges.count) * 40, height: 22).fill()
    for (i, b) in badges.enumerated() {
        let im = icon(badge: b)
        // emulate template tinting
        let tinted = NSImage(size: im.size, flipped: false) { r in im.draw(in: r); fg.set(); r.fill(using: .sourceAtop); return true }
        tinted.draw(in: NSRect(x: CGFloat(i) * 40 + 8, y: y + 2, width: 24, height: 18))
    }
}
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
