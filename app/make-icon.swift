import AppKit
import Foundation

let size = 1024
guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil,
                                 pixelsWide: size, pixelsHigh: size,
                                 bitsPerSample: 8, samplesPerPixel: 4,
                                 hasAlpha: true, isPlanar: false,
                                 colorSpaceName: .deviceRGB,
                                 bytesPerRow: 0, bitsPerPixel: 0) else {
    fatalError("bitmap")
}

NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

let canvas = NSRect(x: 0, y: 0, width: size, height: size)
NSColor.clear.setFill()
canvas.fill()

let body = NSRect(x: 42, y: 42, width: 940, height: 940)
let bodyPath = NSBezierPath(roundedRect: body, xRadius: 220, yRadius: 220)
let gradient = NSGradient(colors: [
    NSColor(calibratedRed: 0.12, green: 0.52, blue: 0.96, alpha: 1),
    NSColor(calibratedRed: 0.04, green: 0.24, blue: 0.56, alpha: 1)
])!
gradient.draw(in: bodyPath, angle: -55)

// White drive symbol.
if let base = NSImage(systemSymbolName: "externaldrive.fill", accessibilityDescription: nil),
   let symbol = base.withSymbolConfiguration(.init(pointSize: 430, weight: .regular)) {
    let tinted = NSImage(size: symbol.size)
    tinted.lockFocus()
    NSColor.white.setFill()
    NSRect(origin: .zero, size: symbol.size).fill()
    symbol.draw(in: NSRect(origin: .zero, size: symbol.size),
                from: .zero, operation: .destinationIn, fraction: 1)
    tinted.unlockFocus()

    let r = NSRect(x: (CGFloat(size) - symbol.size.width) / 2,
                   y: (CGFloat(size) - symbol.size.height) / 2 + 24,
                   width: symbol.size.width,
                   height: symbol.size.height)
    tinted.draw(in: r)
}

// Green check badge.
let badge = NSRect(x: 690, y: 150, width: 220, height: 220)
NSColor(calibratedRed: 0.12, green: 0.76, blue: 0.38, alpha: 1).setFill()
NSBezierPath(ovalIn: badge).fill()

let check = NSBezierPath()
check.lineWidth = 26
check.lineCapStyle = .round
check.lineJoinStyle = .round
check.move(to: NSPoint(x: 746, y: 258))
check.line(to: NSPoint(x: 790, y: 216))
check.line(to: NSPoint(x: 856, y: 300))
NSColor.white.setStroke()
check.stroke()

NSGraphicsContext.restoreGraphicsState()

guard let png = rep.representation(using: .png, properties: [:]) else {
    fatalError("png")
}
try png.write(to: URL(fileURLWithPath: "app/icon-1024.png"))
print("wrote app/icon-1024.png")
