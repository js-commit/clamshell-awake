// Renders AppIcon.iconset (run via build.sh). Dark indigo squircle, white laptop, gold bolt.
import AppKit

let outDir = CommandLine.arguments[1]
try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)

func tinted(_ name: String, pt: CGFloat, weight: NSFont.Weight, color: NSColor) -> NSImage? {
    let cfg = NSImage.SymbolConfiguration(pointSize: pt, weight: weight)
    guard let sym = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(cfg) else { return nil }
    let img = NSImage(size: sym.size, flipped: false) { r in
        sym.draw(in: r)
        color.set()
        r.fill(using: .sourceAtop)
        return true
    }
    return img
}

func render(px: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: px, height: px)
    NSGraphicsContext.saveGraphicsState()
    let ctx = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.current = ctx
    ctx.imageInterpolation = .high

    let s = CGFloat(px)
    let inset = s * 100 / 1024
    let rect = NSRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset)
    let squircle = NSBezierPath(roundedRect: rect, xRadius: rect.width * 0.2237, yRadius: rect.height * 0.2237)

    ctx.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowBlurRadius = s * 0.025
    shadow.shadowOffset = NSSize(width: 0, height: -s * 0.012)
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
    shadow.set()
    NSColor.black.setFill()
    squircle.fill()
    ctx.restoreGraphicsState()

    let grad = NSGradient(colors: [
        NSColor(calibratedRed: 0.22, green: 0.30, blue: 0.62, alpha: 1),
        NSColor(calibratedRed: 0.07, green: 0.09, blue: 0.24, alpha: 1),
    ])!
    grad.draw(in: squircle, angle: -90)

    // subtle top highlight
    ctx.saveGraphicsState()
    squircle.addClip()
    let hl = NSGradient(colors: [NSColor.white.withAlphaComponent(0.14), NSColor.white.withAlphaComponent(0)])!
    hl.draw(in: NSRect(x: rect.minX, y: rect.midY, width: rect.width, height: rect.height / 2), angle: 90)
    ctx.restoreGraphicsState()

    if let laptop = tinted("laptopcomputer", pt: s * 0.50, weight: .medium, color: .white) {
        let sz = laptop.size
        laptop.draw(in: NSRect(x: s / 2 - sz.width / 2, y: s * 0.53 - sz.height / 2, width: sz.width, height: sz.height))
    }
    // bolt badge with a dark ring so it reads against the laptop
    let bc = NSPoint(x: s * 0.70, y: s * 0.30)
    let ring: CGFloat = s * 0.17
    NSColor(calibratedRed: 0.07, green: 0.09, blue: 0.24, alpha: 1).setFill()
    NSBezierPath(ovalIn: NSRect(x: bc.x - ring, y: bc.y - ring, width: ring * 2, height: ring * 2)).fill()
    if let bolt = tinted("bolt.fill", pt: s * 0.22, weight: .bold, color: NSColor(calibratedRed: 1.0, green: 0.80, blue: 0.20, alpha: 1)) {
        let sz = bolt.size
        bolt.draw(in: NSRect(x: bc.x - sz.width / 2, y: bc.y - sz.height / 2, width: sz.width, height: sz.height))
    }

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

for base in [16, 32, 128, 256, 512] {
    try! render(px: base).write(to: URL(fileURLWithPath: "\(outDir)/icon_\(base)x\(base).png"))
    try! render(px: base * 2).write(to: URL(fileURLWithPath: "\(outDir)/icon_\(base)x\(base)@2x.png"))
}
print("iconset written to \(outDir)")
