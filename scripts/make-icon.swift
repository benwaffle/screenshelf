// Renders Resources/AppIcon.icns: a stack of rounded "screenshots" on a gradient, drawn with AppKit.
import AppKit

let output = CommandLine.arguments[1]
let iconset = URL(fileURLWithPath: NSTemporaryDirectory()).appending(path: "AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

func render(_ px: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = CGFloat(px)
    // macOS icon grid: the rounded square sits inside a ~10% margin.
    let inset = s * 0.1
    let body = NSRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset)
    let shape = NSBezierPath(roundedRect: body, xRadius: body.width * 0.225, yRadius: body.width * 0.225)
    NSGradient(colors: [NSColor(red: 0.36, green: 0.30, blue: 0.95, alpha: 1), NSColor(red: 0.13, green: 0.62, blue: 0.98, alpha: 1)])!
        .draw(in: shape, angle: 60)

    func card(_ rect: NSRect, rotation: CGFloat, alpha: CGFloat) {
        let t = NSAffineTransform()
        t.translateX(by: rect.midX, yBy: rect.midY)
        t.rotate(byDegrees: rotation)
        t.translateX(by: -rect.midX, yBy: -rect.midY)
        let path = NSBezierPath(roundedRect: rect, xRadius: rect.width * 0.08, yRadius: rect.width * 0.08)
        path.transform(using: t as AffineTransform)
        NSColor.black.withAlphaComponent(0.18 * alpha).setFill()
        let shadow = path.copy() as! NSBezierPath
        shadow.transform(using: AffineTransform(translationByX: 0, byY: -s * 0.012))
        shadow.fill()
        NSColor.white.withAlphaComponent(alpha).setFill()
        path.fill()
        // A title bar and a few "text" lines.
        let bar = NSRect(x: rect.minX, y: rect.maxY - rect.height * 0.18, width: rect.width, height: rect.height * 0.18)
        let barPath = NSBezierPath(rect: bar)
        barPath.transform(using: t as AffineTransform)
        NSGraphicsContext.saveGraphicsState()
        path.addClip()
        NSColor(red: 0.85, green: 0.88, blue: 0.97, alpha: alpha).setFill()
        barPath.fill()
        for i in 0..<3 {
            let w = rect.width * [0.62, 0.78, 0.45][i]
            let line = NSRect(x: rect.minX + rect.width * 0.1, y: rect.maxY - rect.height * (0.36 + CGFloat(i) * 0.17), width: w, height: rect.height * 0.07)
            let lp = NSBezierPath(roundedRect: line, xRadius: line.height / 2, yRadius: line.height / 2)
            lp.transform(using: t as AffineTransform)
            NSColor(red: 0.55, green: 0.58, blue: 0.75, alpha: 0.55 * alpha).setFill()
            lp.fill()
        }
        NSGraphicsContext.restoreGraphicsState()
    }
    let w = s * 0.5, h = s * 0.36
    card(NSRect(x: s * 0.27, y: s * 0.38, width: w, height: h), rotation: 10, alpha: 0.55)
    card(NSRect(x: s * 0.23, y: s * 0.33, width: w, height: h), rotation: 4, alpha: 0.8)
    card(NSRect(x: s * 0.19, y: s * 0.27, width: w, height: h), rotation: -4, alpha: 1)

    // Magnifier badge for search.
    let r = s * 0.13
    let center = NSPoint(x: s * 0.64, y: s * 0.34)
    let lens = NSBezierPath(ovalIn: NSRect(x: center.x - r, y: center.y - r, width: 2 * r, height: 2 * r))
    NSColor(red: 1, green: 0.78, blue: 0.2, alpha: 1).setFill()
    lens.fill()
    NSColor.white.setStroke()
    lens.lineWidth = s * 0.028
    lens.stroke()
    let handle = NSBezierPath()
    handle.move(to: NSPoint(x: center.x + r * 0.72, y: center.y - r * 0.72))
    handle.line(to: NSPoint(x: center.x + r * 1.3, y: center.y - r * 1.3))
    handle.lineWidth = s * 0.05
    handle.lineCapStyle = .round
    handle.stroke()

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

for size in [16, 32, 128, 256, 512] {
    try render(size).write(to: iconset.appending(path: "icon_\(size)x\(size).png"))
    try render(size * 2).write(to: iconset.appending(path: "icon_\(size)x\(size)@2x.png"))
}
let task = Process()
task.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
task.arguments = ["-c", "icns", iconset.path, "-o", output]
try task.run()
task.waitUntilExit()
exit(task.terminationStatus)
