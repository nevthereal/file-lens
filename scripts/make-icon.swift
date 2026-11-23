import AppKit

// A vector-drawn lens with the app's proportional bubbles inside the glass.
// Render every icon size directly so small Dock/Finder icons stay sharp.
let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
func gray(_ value: CGFloat, _ alpha: CGFloat = 1) -> NSColor { NSColor(white: value, alpha: alpha) }
func disk(_ x: CGFloat, _ y: CGFloat, _ radius: CGFloat) -> NSBezierPath {
    NSBezierPath(ovalIn: NSRect(x: x - radius, y: y - radius, width: radius * 2, height: radius * 2))
}
func render(_ pixels: Int, _ name: String) throws {
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
    let scale = CGFloat(pixels) / 1024
    NSGraphicsContext.current!.cgContext.scaleBy(x: scale, y: scale)
    let tile = NSBezierPath(roundedRect: NSRect(x: 80, y: 80, width: 864, height: 864), xRadius: 194, yRadius: 194)
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow(); shadow.shadowColor = gray(0, 0.35); shadow.shadowBlurRadius = 20; shadow.shadowOffset = NSSize(width: 0, height: -12); shadow.set()
    gray(0.07).setFill(); tile.fill()
    NSGraphicsContext.restoreGraphicsState()
    NSGradient(starting: gray(0.15), ending: gray(0.035))!.draw(in: tile, angle: -90)
    gray(0.9, 0.15).setStroke(); tile.lineWidth = 2; tile.stroke()

    let handle = NSBezierPath(); handle.move(to: NSPoint(x: 616, y: 402)); handle.line(to: NSPoint(x: 756, y: 262))
    handle.lineCapStyle = .round; handle.lineWidth = 82; gray(0.12).setStroke(); handle.stroke()
    handle.lineWidth = 64; gray(0.87).setStroke(); handle.stroke()
    let highlight = NSBezierPath(); highlight.move(to: NSPoint(x: 649, y: 386)); highlight.line(to: NSPoint(x: 759, y: 276))
    highlight.lineCapStyle = .round; highlight.lineWidth = 8; gray(1, 0.6).setStroke(); highlight.stroke()

    let rim = disk(468, 563, 244)
    NSGradient(colors: [gray(0.98), gray(0.62), gray(0.9)])!.draw(in: rim, angle: -55)
    let inset = disk(468, 563, 221)
    gray(0.04).setFill(); inset.fill()
    let glass = disk(468, 563, 209)
    NSGradient(starting: gray(0.22), ending: gray(0.035))!.draw(in: glass, relativeCenterPosition: NSPoint(x: -0.4, y: 0.5))
    gray(0.8, 0.35).setStroke(); glass.lineWidth = 2; glass.stroke()
    for (x, y, radius) in [(418.0, 538.0, 91.0), (542.0, 635.0, 53.0), (555.0, 494.0, 35.0)] {
        let bubble = disk(x, y, radius)
        NSGradient(starting: gray(0.9, 0.13), ending: gray(0.9, 0.02))!.draw(in: bubble, angle: -70)
        gray(0.95, 0.85).setStroke(); bubble.lineWidth = 5; bubble.stroke()
    }
    let glint = NSBezierPath()
    glint.appendArc(withCenter: NSPoint(x: 468, y: 563), radius: 231, startAngle: 83, endAngle: 153)
    glint.lineWidth = 5; glint.lineCapStyle = .round; gray(1, 0.75).setStroke(); glint.stroke()
    NSGraphicsContext.restoreGraphicsState()
    try bitmap.representation(using: .png, properties: [:])!.write(to: output.appendingPathComponent(name))
}
for size in [16, 32, 128, 256, 512] {
    try render(size, "icon_\(size)x\(size).png")
    try render(size * 2, "icon_\(size)x\(size)@2x.png")
}
