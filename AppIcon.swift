import AppKit

// Generate the bundle icon without storing build artifacts in the checkout.
let destination = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = size * scale
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                                      bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                      isPlanar: false, colorSpaceName: .deviceRGB,
                                      bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        let context = NSGraphicsContext.current!.cgContext
        context.scaleBy(x: CGFloat(pixels) / 1024, y: CGFloat(pixels) / 1024)
        let tile = NSBezierPath(roundedRect: NSRect(x: 64, y: 64, width: 896, height: 896), xRadius: 200, yRadius: 200)
        NSGradient(starting: NSColor(calibratedRed: 0.12, green: 0.20, blue: 0.34, alpha: 1),
                   ending: NSColor(calibratedRed: 0.30, green: 0.18, blue: 0.51, alpha: 1))!.draw(in: tile, angle: 45)
        NSColor(calibratedRed: 0.40, green: 0.84, blue: 0.94, alpha: 1).setFill()
        NSBezierPath(roundedRect: NSRect(x: 208, y: 555, width: 280, height: 145), xRadius: 35, yRadius: 35).fill()
        NSBezierPath(roundedRect: NSRect(x: 208, y: 295, width: 608, height: 330), xRadius: 48, yRadius: 48).fill()
        NSColor(calibratedRed: 0.10, green: 0.19, blue: 0.32, alpha: 1).setStroke()
        let arrow = NSBezierPath()
        arrow.lineWidth = 48
        arrow.lineCapStyle = .round
        arrow.lineJoinStyle = .round
        arrow.move(to: NSPoint(x: 418, y: 375))
        arrow.line(to: NSPoint(x: 628, y: 565))
        arrow.move(to: NSPoint(x: 474, y: 565))
        arrow.line(to: NSPoint(x: 628, y: 565))
        arrow.line(to: NSPoint(x: 628, y: 411))
        arrow.stroke()
        NSGraphicsContext.restoreGraphicsState()
        let suffix = scale == 2 ? "@2x" : ""
        try bitmap.representation(using: .png, properties: [:])!.write(to: destination.appendingPathComponent("icon_\(size)x\(size)\(suffix).png"))
    }
}
