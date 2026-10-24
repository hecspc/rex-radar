// Draws the Rex Radar app icon and writes the asset catalog's PNGs.
//
//   swift scripts/make-icon.swift [Resources/Assets.xcassets/AppIcon.appiconset]
//
// A dino head (our own drawing, a nod to Rex's mascot) in front of a glowing radar screen,
// on a night-blue tile. Everything is drawn in a 1024 × 1024 box, y up.
import AppKit

let out = CommandLine.arguments.dropFirst().first ?? "Resources/Assets.xcassets/AppIcon.appiconset"

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> NSColor {
  NSColor(
    srgbRed: CGFloat((hex >> 16) & 0xff) / 255, green: CGFloat((hex >> 8) & 0xff) / 255,
    blue: CGFloat(hex & 0xff) / 255, alpha: alpha)
}

/// `tile`: draw the rounded tile (macOS); iOS gets a full square and masks it itself.
func draw(in ctx: CGContext, tile: Bool) {
  let full = CGRect(x: 0, y: 0, width: 1024, height: 1024)
  let rect = tile ? full.insetBy(dx: 100, dy: 100) : full
  let s = rect.width / 1024
  ctx.saveGState()
  if tile {
    // macOS icon grid: 824 pt tile, radius ~185, soft shadow.
    ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 28, color: NSColor.black.withAlphaComponent(0.35).cgColor)
    let path = CGPath(roundedRect: rect, cornerWidth: 185, cornerHeight: 185, transform: nil)
    ctx.addPath(path)
    ctx.setFillColor(color(0x0b1026).cgColor)
    ctx.fillPath()
    ctx.setShadow(offset: .zero, blur: 0)
    ctx.addPath(path)
    ctx.clip()
  }
  ctx.translateBy(x: rect.minX, y: rect.minY)
  ctx.scaleBy(x: s, y: s)

  // Background: night blue, lighter towards the radar.
  let bg = CGGradient(
    colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
    colors: [color(0x1c2a5e).cgColor, color(0x0b1026).cgColor] as CFArray, locations: [0, 1])!
  ctx.drawRadialGradient(
    bg, startCenter: CGPoint(x: 640, y: 640), startRadius: 0, endCenter: CGPoint(x: 640, y: 640), endRadius: 900,
    options: [.drawsAfterEndLocation])

  // The radar screen.
  let c = CGPoint(x: 630, y: 600)
  let green = color(0x5cf2a4)
  ctx.saveGState()
  ctx.addArc(center: c, radius: 330, startAngle: 0, endAngle: .pi * 2, clockwise: false)
  ctx.setFillColor(color(0x0e2a33, 0.9).cgColor)
  ctx.fillPath()
  // Sweep wedge: a fading trail behind the beam (y up, so angles run counter-clockwise).
  let beam = CGFloat.pi * 0.22
  for i in 0..<40 {
    let a0 = beam + CGFloat(i) * 0.03
    ctx.move(to: c)
    ctx.addArc(center: c, radius: 330, startAngle: a0, endAngle: a0 + 0.031, clockwise: false)
    ctx.closePath()
    ctx.setFillColor(green.withAlphaComponent(0.42 * (1 - CGFloat(i) / 40)).cgColor)
    ctx.fillPath()
  }
  ctx.setStrokeColor(green.withAlphaComponent(0.55).cgColor)
  for (r, w) in [(330.0, 14.0), (230.0, 9.0), (130.0, 9.0)] {
    ctx.setLineWidth(w)
    ctx.addArc(center: c, radius: r, startAngle: 0, endAngle: .pi * 2, clockwise: false)
    ctx.strokePath()
  }
  ctx.setLineWidth(6)
  ctx.setStrokeColor(green.withAlphaComponent(0.25).cgColor)
  ctx.move(to: CGPoint(x: c.x - 330, y: c.y)); ctx.addLine(to: CGPoint(x: c.x + 330, y: c.y))
  ctx.move(to: CGPoint(x: c.x, y: c.y - 330)); ctx.addLine(to: CGPoint(x: c.x, y: c.y + 330))
  ctx.strokePath()
  // The beam, glowing.
  ctx.setShadow(offset: .zero, blur: 30, color: green.cgColor)
  ctx.setStrokeColor(green.cgColor)
  ctx.setLineWidth(16)
  ctx.setLineCap(.round)
  ctx.move(to: c)
  ctx.addLine(to: CGPoint(x: c.x + 330 * cos(beam), y: c.y + 330 * sin(beam)))
  ctx.strokePath()
  // A blip: an agent that wants you.
  let blip = CGPoint(x: c.x + 230 * cos(beam + 0.35), y: c.y + 230 * sin(beam + 0.35))
  ctx.setFillColor(color(0xffc777).cgColor)
  ctx.setShadow(offset: .zero, blur: 40, color: color(0xffc777).cgColor)
  ctx.fillEllipse(in: CGRect(x: blip.x - 34, y: blip.y - 34, width: 68, height: 68))
  ctx.restoreGState()

  // The dino head, in front, bottom left. Drawn y down in a 100-unit box, then placed.
  ctx.saveGState()
  ctx.translateBy(x: 40, y: 650)
  ctx.scaleBy(x: 6.4, y: -6.4)
  let head = CGMutablePath()
  head.addEllipse(in: CGRect(x: 10, y: 12, width: 58, height: 50))
  head.addRoundedRect(in: CGRect(x: 16, y: 40, width: 36, height: 66), cornerWidth: 16, cornerHeight: 16)
  for (x, y, r) in [(29.0, 13.0, 9.0), (16.0, 23.0, 9.0), (10.0, 38.0, 9.0), (10.0, 54.0, 8.5), (12.0, 70.0, 8.0), (14.0, 86.0, 7.5)] {
    head.addEllipse(in: CGRect(x: x - r, y: y - r, width: 2 * r, height: 2 * r))
  }
  // A dark outline so the head stands off the radar.
  ctx.setShadow(offset: CGSize(width: 0, height: 0), blur: 6, color: NSColor.black.withAlphaComponent(0.6).cgColor)
  ctx.addPath(head)
  ctx.setFillColor(color(0xf2f4ff).cgColor)
  ctx.fillPath()
  ctx.setShadow(offset: .zero, blur: 0)
  // Soft shading towards the neck.
  ctx.saveGState()
  ctx.addPath(head)
  ctx.clip()
  let shade = CGGradient(
    colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
    colors: [color(0xb7bdf0, 0).cgColor, color(0xb7bdf0, 0.75).cgColor] as CFArray, locations: [0, 1])!
  ctx.drawLinearGradient(shade, start: CGPoint(x: 0, y: 40), end: CGPoint(x: 0, y: 100), options: [.drawsAfterEndLocation])
  ctx.restoreGState()
  // Eye and smile.
  ctx.setFillColor(color(0x1b1d3a).cgColor)
  ctx.fillEllipse(in: CGRect(x: 40, y: 24, width: 10, height: 14))
  ctx.setFillColor(NSColor.white.cgColor)
  ctx.fillEllipse(in: CGRect(x: 42.6, y: 26.2, width: 3.4, height: 4))
  ctx.setStrokeColor(color(0x1b1d3a).cgColor)
  ctx.setLineWidth(3.6)
  ctx.setLineCap(.round)
  ctx.move(to: CGPoint(x: 41, y: 50))
  ctx.addCurve(to: CGPoint(x: 66, y: 46), control1: CGPoint(x: 48, y: 55), control2: CGPoint(x: 59, y: 54))
  ctx.strokePath()
  ctx.restoreGState()
  ctx.restoreGState()
}

func png(size: Int, tile: Bool) -> Data {
  let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8, samplesPerPixel: 4,
    hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
  NSGraphicsContext.saveGraphicsState()
  let ns = NSGraphicsContext(bitmapImageRep: rep)!
  NSGraphicsContext.current = ns
  let ctx = ns.cgContext
  ctx.scaleBy(x: CGFloat(size) / 1024, y: CGFloat(size) / 1024)
  draw(in: ctx, tile: tile)
  NSGraphicsContext.restoreGraphicsState()
  return rep.representation(using: .png, properties: [:])!
}

try FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)
var images: [[String: String]] = [["idiom": "universal", "platform": "ios", "size": "1024x1024", "filename": "ios-1024.png"]]
try png(size: 1024, tile: false).write(to: URL(fileURLWithPath: "\(out)/ios-1024.png"))
for pt in [16, 32, 128, 256, 512] {
  for scale in [1, 2] {
    let name = "mac-\(pt)@\(scale)x.png"
    try png(size: pt * scale, tile: true).write(to: URL(fileURLWithPath: "\(out)/\(name)"))
    images.append(["idiom": "mac", "size": "\(pt)x\(pt)", "scale": "\(scale)x", "filename": name])
  }
}
let contents: [String: Any] = ["images": images, "info": ["author": "xcode", "version": 1]]
try JSONSerialization.data(withJSONObject: contents, options: [.prettyPrinted, .sortedKeys])
  .write(to: URL(fileURLWithPath: "\(out)/Contents.json"))
print("wrote \(out)")
