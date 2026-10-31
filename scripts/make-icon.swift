#!/usr/bin/env swift
// Generates Resources/AppIcon.icon, the Icon Composer bundle for Duotone's icon.
// Usage: swift scripts/make-icon.swift [output.icon]
//
// Two layers on a 1024-point canvas: a full-bleed midnight gradient, and a mark of two overlapping
// circles (coral and teal) whose intersection is a lighter blend. The system applies its own dark
// and tinted treatments to the layers.
import AppKit

let size = 1024
let output = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "Resources/AppIcon.icon")
let assets = output.appendingPathComponent("Assets")
try FileManager.default.createDirectory(at: assets, withIntermediateDirectories: true)

func color(_ hex: Int, _ alpha: CGFloat = 1) -> CGColor {
  CGColor(srgbRed: CGFloat((hex >> 16) & 255) / 255, green: CGFloat((hex >> 8) & 255) / 255, blue: CGFloat(hex & 255) / 255, alpha: alpha)
}

func canvas() -> CGContext {
  let context = CGContext(
    data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
    space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
  context.translateBy(x: 0, y: CGFloat(size))
  context.scaleBy(x: 1, y: -1)  // origin at the top left
  return context
}

func write(_ context: CGContext, _ name: String) throws {
  let data = NSBitmapImageRep(cgImage: context.makeImage()!).representation(using: .png, properties: [:])!
  try data.write(to: assets.appendingPathComponent(name))
}

// Background: full bleed, opaque.
let background = canvas()
let gradient = CGGradient(
  colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: [color(0x1B1636), color(0x0A0B16)] as CFArray, locations: [0, 1])!
background.drawLinearGradient(gradient, start: CGPoint(x: 0, y: 0), end: CGPoint(x: CGFloat(size), y: CGFloat(size)), options: [])
try write(background, "background.png")

// Mark: two circles and their lens, transparent around them.
let mark = canvas()
let radius: CGFloat = 270
let left = CGRect(x: 512 - 150 - radius, y: 512 - radius, width: radius * 2, height: radius * 2)
let right = CGRect(x: 512 + 150 - radius, y: 512 - radius, width: radius * 2, height: radius * 2)
mark.setFillColor(color(0xFF6B4A)); mark.fillEllipse(in: left)
mark.setFillColor(color(0x19CFC0)); mark.fillEllipse(in: right)
mark.saveGState()
mark.addEllipse(in: left); mark.clip()
mark.setFillColor(color(0xFFF1DC)); mark.fillEllipse(in: right)
mark.restoreGState()
try write(mark, "mark.png")

let manifest = """
{
  "groups" : [
    {
      "layers" : [
        { "image-name" : "mark.png", "name" : "mark" },
        { "image-name" : "background.png", "name" : "background" }
      ],
      "shadow" : { "kind" : "neutral", "opacity" : 0.35 },
      "translucency" : { "enabled" : false, "value" : 0 }
    }
  ],
  "supported-platforms" : { "squares" : "shared" }
}
"""
try manifest.write(to: output.appendingPathComponent("icon.json"), atomically: true, encoding: .utf8)
print("Wrote \(output.path)")
