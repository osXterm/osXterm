import AppKit

let outputPath = CommandLine.arguments.dropFirst().first ?? "Packaging/AppIcon.png"
let size = NSSize(width: 1024, height: 1024)
guard let bitmap = NSBitmapImageRep(
    bitmapDataPlanes: nil,
    pixelsWide: Int(size.width),
    pixelsHigh: Int(size.height),
    bitsPerSample: 8,
    samplesPerPixel: 4,
    hasAlpha: true,
    isPlanar: false,
    colorSpaceName: .deviceRGB,
    bitmapFormat: .alphaFirst,
    bytesPerRow: 0,
    bitsPerPixel: 0
), let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
    exit(1)
}

NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = context
defer { NSGraphicsContext.restoreGraphicsState() }

let canvas = NSRect(origin: .zero, size: size)
let background = NSBezierPath(roundedRect: canvas.insetBy(dx: 72, dy: 72), xRadius: 202, yRadius: 202)
NSGradient(
    starting: NSColor(red: 0.20, green: 0.29, blue: 0.47, alpha: 1),
    ending: NSColor(red: 0.06, green: 0.09, blue: 0.15, alpha: 1)
)?.draw(in: background, angle: -45)

NSColor(calibratedWhite: 1, alpha: 0.16).setFill()
NSBezierPath(roundedRect: NSRect(x: 146, y: 174, width: 732, height: 650), xRadius: 72, yRadius: 72).fill()
NSColor(red: 0.05, green: 0.08, blue: 0.14, alpha: 1).setFill()
NSBezierPath(roundedRect: NSRect(x: 170, y: 198, width: 684, height: 602), xRadius: 54, yRadius: 54).fill()

for (offset, color) in [(0, NSColor.systemRed), (54, NSColor.systemYellow), (108, NSColor.systemGreen)] {
    color.setFill()
    NSBezierPath(ovalIn: NSRect(x: 220 + offset, y: 736, width: 36, height: 36)).fill()
}

let prompt = NSBezierPath()
prompt.move(to: NSPoint(x: 290, y: 612))
prompt.line(to: NSPoint(x: 418, y: 512))
prompt.line(to: NSPoint(x: 290, y: 412))
NSColor(red: 0.47, green: 0.85, blue: 1, alpha: 1).setStroke()
prompt.lineWidth = 54
prompt.lineCapStyle = .round
prompt.lineJoinStyle = .round
prompt.stroke()

let cursor = NSBezierPath()
cursor.move(to: NSPoint(x: 496, y: 398))
cursor.line(to: NSPoint(x: 712, y: 398))
NSColor(red: 0.72, green: 0.95, blue: 0.78, alpha: 1).setStroke()
cursor.lineWidth = 52
cursor.lineCapStyle = .round
cursor.stroke()

guard let png = bitmap.representation(using: .png, properties: [:])
else {
    exit(1)
}
try png.write(to: URL(fileURLWithPath: outputPath), options: .atomic)
