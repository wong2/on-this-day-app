import AppKit

let size = 1024
let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
    bitsPerSample: 8, samplesPerPixel: 3, hasAlpha: false, isPlanar: false,
    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
NSColor(red: 0.95, green: 0.92, blue: 0.86, alpha: 1).setFill()
NSBezierPath(rect: NSRect(x: 0, y: 0, width: size, height: size)).fill()
NSColor(red: 0.87, green: 0.82, blue: 0.72, alpha: 1).setFill()
let back = NSBezierPath(roundedRect: NSRect(x: 222, y: 195, width: 580, height: 660), xRadius: 60, yRadius: 60)
var transform = AffineTransform()
transform.translate(x: 512, y: 512)
transform.rotate(byDegrees: -12)
transform.translate(x: -512, y: -512)
back.transform(using: transform)
back.fill()
NSColor(red: 1, green: 0.99, blue: 0.96, alpha: 1).setFill()
NSBezierPath(roundedRect: NSRect(x: 242, y: 190, width: 540, height: 650), xRadius: 54, yRadius: 54).fill()
NSColor(red: 0.78, green: 0.40, blue: 0.16, alpha: 1).setStroke()
let sun = NSBezierPath(ovalIn: NSRect(x: 427, y: 430, width: 170, height: 170))
sun.lineWidth = 14
sun.stroke()
for index in 0..<12 {
    let angle = Double(index) * .pi / 6
    let ray = NSBezierPath()
    ray.move(to: NSPoint(x: 512 + cos(angle) * 126, y: 515 + sin(angle) * 126))
    ray.line(to: NSPoint(x: 512 + cos(angle) * 161, y: 515 + sin(angle) * 161))
    ray.lineWidth = 14
    ray.lineCapStyle = .round
    ray.stroke()
}
NSGraphicsContext.restoreGraphicsState()
let destination = CommandLine.arguments.dropFirst().first ?? "OnThisDay/Assets.xcassets/AppIcon.appiconset/AppIcon.png"
try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: destination))
