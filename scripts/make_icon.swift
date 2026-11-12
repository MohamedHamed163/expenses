// Renders the Wallet app icon (emerald→teal squircle, wallet glyph, gold coin) to Resources/AppIcon.icns.
import AppKit

func render(_ px: Int) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = CGFloat(px), inset = s * 0.09
    let rect = NSRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset)
    let path = NSBezierPath(roundedRect: rect, xRadius: rect.width * 0.225, yRadius: rect.width * 0.225)
    NSGraphicsContext.current?.cgContext.setShadow(offset: CGSize(width: 0, height: -s * 0.012), blur: s * 0.03, color: NSColor.black.withAlphaComponent(0.3).cgColor)
    NSGradient(starting: NSColor(red: 0.06, green: 0.73, blue: 0.51, alpha: 1), ending: NSColor(red: 0.05, green: 0.50, blue: 0.68, alpha: 1))!.draw(in: path, angle: -55)
    NSGraphicsContext.current?.cgContext.setShadow(offset: .zero, blur: 0, color: nil)
    let cfg = NSImage.SymbolConfiguration(pointSize: s * 0.42, weight: .semibold).applying(.init(paletteColors: [.white]))
    if let sym = NSImage(systemSymbolName: "wallet.bifold.fill", accessibilityDescription: nil)?.withSymbolConfiguration(cfg) {
        let sz = sym.size
        sym.draw(in: NSRect(x: (s - sz.width) / 2, y: (s - sz.height) / 2 - s * 0.02, width: sz.width, height: sz.height))
    }
    let c = s * 0.2
    let coin = NSRect(x: s * 0.62, y: s * 0.6, width: c, height: c)
    NSColor(red: 0.98, green: 0.75, blue: 0.24, alpha: 1).setFill()
    NSBezierPath(ovalIn: coin).fill()
    NSColor.white.withAlphaComponent(0.9).setStroke()
    let ring = NSBezierPath(ovalIn: coin.insetBy(dx: c * 0.04, dy: c * 0.04)); ring.lineWidth = max(1, s * 0.008); ring.stroke()
    let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: c * 0.62, weight: .heavy), .foregroundColor: NSColor.white]
    let d = NSAttributedString(string: "$", attributes: attrs); let ds = d.size()
    d.draw(at: NSPoint(x: coin.midX - ds.width / 2, y: coin.midY - ds.height / 2))
    NSGraphicsContext.restoreGraphicsState()
    return rep
}

let out = URL(fileURLWithPath: CommandLine.arguments[1])
try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
for (name, px) in [("16x16", 16), ("16x16@2x", 32), ("32x32", 32), ("32x32@2x", 64), ("128x128", 128), ("128x128@2x", 256),
                   ("256x256", 256), ("256x256@2x", 512), ("512x512", 512), ("512x512@2x", 1024)] {
    try! render(px).representation(using: .png, properties: [:])!.write(to: out.appendingPathComponent("icon_\(name).png"))
}
