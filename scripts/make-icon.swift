// Renders the CcinnPsql app icon (all macOS iconset sizes) with AppKit: a stack of database disks with a prompt
// chevron on a harbor-blue squircle.
// Usage: swift scripts/make-icon.swift <output.iconset>
import AppKit

let arguments = CommandLine.arguments
guard arguments.count == 2 else {
    FileHandle.standardError.write(Data("usage: make-icon.swift <output.iconset>\n".utf8))
    exit(1)
}
let outputDirectory = URL(fileURLWithPath: arguments[1])
try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

func renderIcon(pixels: Int) -> Data? {
    guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8,
                                        samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                        bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
    bitmap.size = NSSize(width: pixels, height: pixels)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
    defer { NSGraphicsContext.restoreGraphicsState() }

    let scale = CGFloat(pixels) / 1024
    let body = NSRect(x: 100 * scale, y: 100 * scale, width: 824 * scale, height: 824 * scale)
    let radius = 186 * scale

    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.3)
    shadow.shadowBlurRadius = 28 * scale
    shadow.shadowOffset = NSSize(width: 0, height: -12 * scale)
    NSGraphicsContext.saveGraphicsState()
    shadow.set()
    let shape = NSBezierPath(roundedRect: body, xRadius: radius, yRadius: radius)
    NSColor(srgbRed: 0.06, green: 0.22, blue: 0.45, alpha: 1).setFill()
    shape.fill()
    NSGraphicsContext.restoreGraphicsState()

    // Harbor-blue gradient.
    let gradient = NSGradient(colors: [
        NSColor(srgbRed: 0.33, green: 0.68, blue: 0.93, alpha: 1),
        NSColor(srgbRed: 0.13, green: 0.44, blue: 0.72, alpha: 1),
        NSColor(srgbRed: 0.05, green: 0.19, blue: 0.40, alpha: 1),
    ], atLocations: [0, 0.55, 1], colorSpace: .sRGB)
    gradient?.draw(in: shape, angle: -60)

    NSGraphicsContext.saveGraphicsState()
    shape.addClip()
    let highlight = NSGradient(colors: [NSColor.white.withAlphaComponent(0.20), NSColor.white.withAlphaComponent(0)])
    highlight?.draw(in: NSRect(x: body.minX, y: body.midY, width: body.width, height: body.height / 2), angle: -90)

    // Three stacked disks (a database cylinder seen from the side).
    let diskWidth = body.width * 0.56
    let diskHeight = 112 * scale
    let gap = 26 * scale
    let stackHeight = diskHeight * 3 + gap * 2
    let firstY = body.midY - stackHeight / 2 - 30 * scale
    for index in 0..<3 {
        let y = firstY + CGFloat(index) * (diskHeight + gap)
        let rect = NSRect(x: body.midX - diskWidth / 2, y: y, width: diskWidth, height: diskHeight)
        let alpha = 0.78 + CGFloat(index) * 0.1
        NSColor.white.withAlphaComponent(alpha).setFill()
        NSBezierPath(roundedRect: rect, xRadius: diskHeight / 2, yRadius: diskHeight / 2).fill()
        // A subtle rim line on the lower disks (the top one carries the prompt).
        guard index < 2 else { continue }
        let rim = NSRect(x: rect.minX + diskHeight * 0.45, y: rect.midY - 6 * scale, width: rect.width - diskHeight * 0.9, height: 12 * scale)
        NSColor(srgbRed: 0.09, green: 0.33, blue: 0.60, alpha: 0.35).setFill()
        NSBezierPath(roundedRect: rim, xRadius: 6 * scale, yRadius: 6 * scale).fill()
    }
    // Prompt chevron and cursor on the top disk.
    let topY = firstY + 2 * (diskHeight + gap)
    let chevron = NSBezierPath()
    chevron.lineWidth = 26 * scale
    chevron.lineCapStyle = .round
    chevron.lineJoinStyle = .round
    let left = body.midX - diskWidth / 2 + diskHeight * 0.55
    chevron.move(to: NSPoint(x: left, y: topY + diskHeight * 0.78))
    chevron.line(to: NSPoint(x: left + 52 * scale, y: topY + diskHeight * 0.5))
    chevron.line(to: NSPoint(x: left, y: topY + diskHeight * 0.22))
    NSColor(srgbRed: 0.06, green: 0.22, blue: 0.45, alpha: 1).setStroke()
    chevron.stroke()
    let cursor = NSRect(x: left + 96 * scale, y: topY + diskHeight * 0.22, width: 130 * scale, height: 26 * scale)
    NSColor(srgbRed: 0.06, green: 0.22, blue: 0.45, alpha: 1).setFill()
    NSBezierPath(roundedRect: cursor, xRadius: 13 * scale, yRadius: 13 * scale).fill()
    NSGraphicsContext.restoreGraphicsState()
    return bitmap.representation(using: .png, properties: [:])
}

let sizes: [(String, Int)] = [
    ("icon_16x16.png", 16), ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32), ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128), ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256), ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512), ("icon_512x512@2x.png", 1024),
]
for (name, pixels) in sizes {
    guard let data = renderIcon(pixels: pixels) else {
        FileHandle.standardError.write(Data("failed to render \(name)\n".utf8))
        exit(1)
    }
    try data.write(to: outputDirectory.appendingPathComponent(name))
}
print("wrote \(sizes.count) images to \(outputDirectory.path)")
