import AppKit
import Foundation

guard CommandLine.arguments.count == 2 else {
    FileHandle.standardError.write(Data("usage: generate_icon.swift <output.png>\n".utf8))
    exit(2)
}

let outputURL = URL(fileURLWithPath: CommandLine.arguments[1])
guard let bitmap = NSBitmapImageRep(
    bitmapDataPlanes: nil,
    pixelsWide: 1_024,
    pixelsHigh: 1_024,
    bitsPerSample: 8,
    samplesPerPixel: 4,
    hasAlpha: true,
    isPlanar: false,
    colorSpaceName: .deviceRGB,
    bytesPerRow: 0,
    bitsPerPixel: 0
) else {
    FileHandle.standardError.write(Data("could not allocate app icon bitmap\n".utf8))
    exit(1)
}
guard let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
    FileHandle.standardError.write(Data("could not create app icon graphics context\n".utf8))
    exit(1)
}
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = context
defer { NSGraphicsContext.restoreGraphicsState() }
context.imageInterpolation = .high
NSColor.clear.setFill()
NSRect(x: 0, y: 0, width: 1_024, height: 1_024).fill()

let background = NSBezierPath(roundedRect: NSRect(x: 32, y: 32, width: 960, height: 960), xRadius: 218, yRadius: 218)
NSColor(calibratedRed: 0.90, green: 0.62, blue: 0.18, alpha: 1).setFill()
background.fill()

let innerEdge = NSBezierPath(roundedRect: NSRect(x: 54, y: 54, width: 916, height: 916), xRadius: 198, yRadius: 198)
innerEdge.lineWidth = 7
NSColor(calibratedWhite: 1, alpha: 0.22).setStroke()
innerEdge.stroke()

let ink = NSColor(calibratedRed: 0.12, green: 0.14, blue: 0.15, alpha: 1)
ink.setStroke()

func drawArrow(x: CGFloat) {
    let stem = NSBezierPath()
    stem.lineWidth = 78
    stem.lineCapStyle = .round
    stem.lineJoinStyle = .round
    stem.move(to: NSPoint(x: x, y: 716))
    stem.line(to: NSPoint(x: x, y: 424))
    stem.stroke()

    let head = NSBezierPath()
    head.lineWidth = 78
    head.lineCapStyle = .round
    head.lineJoinStyle = .round
    head.move(to: NSPoint(x: x - 94, y: 512))
    head.line(to: NSPoint(x: x, y: 414))
    head.line(to: NSPoint(x: x + 94, y: 512))
    head.stroke()
}

drawArrow(x: 360)
drawArrow(x: 664)

let tray = NSBezierPath()
tray.lineWidth = 78
tray.lineCapStyle = .round
tray.lineJoinStyle = .round
tray.move(to: NSPoint(x: 250, y: 318))
tray.line(to: NSPoint(x: 296, y: 244))
tray.line(to: NSPoint(x: 728, y: 244))
tray.line(to: NSPoint(x: 774, y: 318))
tray.stroke()

guard let png = bitmap.representation(using: .png, properties: [:]) else {
    FileHandle.standardError.write(Data("could not render app icon\n".utf8))
    exit(1)
}
try png.write(to: outputURL, options: .atomic)
