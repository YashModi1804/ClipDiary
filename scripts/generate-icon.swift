#!/usr/bin/env swift
import AppKit

// Reproducible native vector drawing; no downloaded artwork or image service.
let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
let teal = NSColor(srgbRed: 0.04, green: 0.48, blue: 0.48, alpha: 1)
let deepTeal = NSColor(srgbRed: 0.015, green: 0.27, blue: 0.34, alpha: 1)
func rounded(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, _ radius: CGFloat, _ color: NSColor) {
    color.setFill()
    NSBezierPath(roundedRect: NSRect(x: x, y: y, width: w, height: h), xRadius: radius, yRadius: radius).fill()
}
func draw() {
    let tile = NSBezierPath(roundedRect: NSRect(x: 22, y: 22, width: 980, height: 980), xRadius: 218, yRadius: 218)
    NSGradient(starting: teal, ending: deepTeal)!.draw(in: tile, angle: -60)
    NSGraphicsContext.saveGraphicsState()
    let tilt = AffineTransform(translationByX: 490, byY: 515)
    let transform = NSAffineTransform(transform: tilt)
    transform.rotate(byDegrees: 12)
    transform.translateX(by: -490, yBy: -515)
    transform.concat()
    rounded(208, 215, 490, 635, 55, NSColor(srgbRed: 0.58, green: 0.87, blue: 0.82, alpha: 1))
    NSGraphicsContext.restoreGraphicsState()
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.26)
    shadow.shadowBlurRadius = 38
    shadow.shadowOffset = NSSize(width: 0, height: -16)
    shadow.set()
    rounded(300, 150, 490, 650, 58, NSColor(srgbRed: 0.97, green: 0.99, blue: 0.98, alpha: 1))
    NSGraphicsContext.restoreGraphicsState()
    rounded(431, 755, 228, 94, 28, NSColor(srgbRed: 0.84, green: 0.94, blue: 0.91, alpha: 1))
    rounded(483, 793, 124, 23, 11, deepTeal)
    rounded(375, 608, 335, 30, 15, teal)
    rounded(375, 508, 280, 30, 15, NSColor(srgbRed: 0.55, green: 0.72, blue: 0.71, alpha: 1))
    rounded(375, 408, 335, 30, 15, NSColor(srgbRed: 0.55, green: 0.72, blue: 0.71, alpha: 1))
    rounded(375, 308, 210, 30, 15, NSColor(srgbRed: 0.55, green: 0.72, blue: 0.71, alpha: 1))
}
for (size, suffix) in [(16, ""), (16, "@2x"), (32, ""), (32, "@2x"), (128, ""), (128, "@2x"), (256, ""), (256, "@2x"), (512, ""), (512, "@2x")] {
    let pixels = size * (suffix.isEmpty ? 1 : 2)
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    bitmap.size = NSSize(width: pixels, height: pixels)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
    let scale = NSAffineTransform()
    scale.scale(by: CGFloat(pixels) / 1024)
    scale.concat()
    draw()
    NSGraphicsContext.restoreGraphicsState()
    let data = bitmap.representation(using: .png, properties: [:])!
    try data.write(to: output.appendingPathComponent("icon_\(size)x\(size)\(suffix).png"))
}
