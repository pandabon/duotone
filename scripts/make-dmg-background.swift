// Renders Resources/dmg-background.tiff, the install window's arrow, at 1x and 2x.
// Run from the repository root: swift scripts/make-dmg-background.swift
import AppKit

let size = NSSize(width: 660, height: 400)

func render(scale: Int) -> Data {
  let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil, pixelsWide: Int(size.width) * scale, pixelsHigh: Int(size.height) * scale,
    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
    bytesPerRow: 0, bitsPerPixel: 0)!
  rep.size = size

  NSGraphicsContext.saveGraphicsState()
  NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

  // Light, because Finder draws black icon labels over a background picture even in Dark Mode.
  NSGradient(
    colors: [NSColor(red: 0.96, green: 0.95, blue: 0.98, alpha: 1), NSColor(red: 0.87, green: 0.85, blue: 0.93, alpha: 1)]
  )!.draw(in: NSRect(origin: .zero, size: size), angle: -90)

  let arrow = NSBezierPath()
  arrow.move(to: NSPoint(x: 278, y: 200))
  arrow.line(to: NSPoint(x: 366, y: 200))
  arrow.move(to: NSPoint(x: 344, y: 224))
  arrow.line(to: NSPoint(x: 370, y: 200))
  arrow.line(to: NSPoint(x: 344, y: 176))
  arrow.lineWidth = 9
  arrow.lineCapStyle = .round
  arrow.lineJoinStyle = .round

  let context = NSGraphicsContext.current!.cgContext
  context.saveGState()
  context.setLineWidth(arrow.lineWidth)
  context.setLineCap(.round)
  context.setLineJoin(.round)
  context.addPath(arrow.cgPath)
  context.replacePathWithStrokedPath()
  context.clip()
  NSGradient(
    colors: [NSColor(red: 1, green: 0.42, blue: 0.29, alpha: 1), NSColor(red: 0.10, green: 0.81, blue: 0.75, alpha: 1)]
  )!.draw(in: NSRect(x: 268, y: 170, width: 112, height: 60), angle: 0)
  context.restoreGState()

  NSGraphicsContext.restoreGraphicsState()
  return rep.representation(using: .png, properties: [:])!
}

let temporary = FileManager.default.temporaryDirectory
let oneX = temporary.appendingPathComponent("dmg-background.png")
let twoX = temporary.appendingPathComponent("dmg-background@2x.png")
try render(scale: 1).write(to: oneX)
try render(scale: 2).write(to: twoX)

let combine = Process()
combine.executableURL = URL(fileURLWithPath: "/usr/bin/tiffutil")
combine.arguments = ["-cathidpicheck", oneX.path, twoX.path, "-out", "Resources/dmg-background.tiff"]
try combine.run()
combine.waitUntilExit()
print("Wrote Resources/dmg-background.tiff")
