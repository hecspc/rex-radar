import AppKit

/// The menu bar glyph: the app icon's dino head in front of its radar screen, in one ink.
///
/// Same shapes as `scripts/make-icon.swift`, redrawn as a template image so macOS tints it for
/// the menu bar. The radar is lighter than the dino, the eye and smile are cut out of the head,
/// and `alert` puts the icon's blip on the radar.
enum MenuIcon {
  static let size = NSSize(width: 18, height: 18)
  /// Points per unit of the icon's 1024 box, and where the box sits: the glyph keeps the tile's
  /// content (dino and radar), not its margins.
  private static let scale: CGFloat = 18 / 960
  private static let origin = CGPoint(x: -40, y: -62)

  // The radar, in the 1024 box, y down.
  private static let center = CGPoint(x: 630, y: 424)
  private static let rings: [CGFloat] = [330, 200]
  private static let beam: CGFloat = -0.22 * .pi

  static func image(alert: Bool) -> NSImage {
    let image = NSImage(size: size, flipped: true) { rect in
      guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
      ctx.clip(to: rect)
      ctx.scaleBy(x: scale, y: scale)
      ctx.translateBy(x: origin.x, y: origin.y)
      radar(ctx, alert: alert)
      dino(ctx)
      return true
    }
    image.isTemplate = true
    return image
  }

  private static func radar(_ ctx: CGContext, alert: Bool) {
    let ink = NSColor.black
    let outer = rings[0]
    // The sweep: a faint wedge trailing the beam (y down, so the trail runs anticlockwise).
    ctx.move(to: center)
    ctx.addArc(center: center, radius: outer, startAngle: beam, endAngle: beam - 1.1, clockwise: true)
    ctx.closePath()
    ctx.setFillColor(ink.withAlphaComponent(0.22).cgColor)
    ctx.fillPath()
    // Crosshair and rings: background, lighter than the dino. One layer, so crossings don't darken.
    ctx.setAlpha(0.55)
    ctx.beginTransparencyLayer(auxiliaryInfo: nil)
    ctx.setStrokeColor(ink.cgColor)
    ctx.setLineWidth(52)
    for r in rings {
      ctx.addArc(center: center, radius: r, startAngle: 0, endAngle: .pi * 2, clockwise: false)
      ctx.strokePath()
    }
    ctx.setStrokeColor(ink.withAlphaComponent(0.6).cgColor)
    ctx.setLineWidth(28)
    ctx.move(to: CGPoint(x: center.x - outer, y: center.y)); ctx.addLine(to: CGPoint(x: center.x + outer, y: center.y))
    ctx.move(to: CGPoint(x: center.x, y: center.y - outer)); ctx.addLine(to: CGPoint(x: center.x, y: center.y + outer))
    ctx.strokePath()
    ctx.endTransparencyLayer()
    ctx.setAlpha(1)
    // The beam, full strength.
    ctx.setStrokeColor(ink.cgColor)
    ctx.setLineWidth(64)
    ctx.setLineCap(.round)
    ctx.move(to: center)
    ctx.addLine(to: CGPoint(x: center.x + outer * cos(beam), y: center.y + outer * sin(beam)))
    ctx.strokePath()
    if alert {
      let a = beam - 0.8
      let r: CGFloat = 250
      let blip = CGPoint(x: center.x + r * cos(a), y: center.y + r * sin(a))
      // A clear gap around it, so it stays apart from the beam.
      ctx.setBlendMode(.clear)
      ctx.fillEllipse(in: CGRect(x: blip.x - 100, y: blip.y - 100, width: 200, height: 200))
      ctx.setBlendMode(.normal)
      ctx.setFillColor(ink.cgColor)
      ctx.fillEllipse(in: CGRect(x: blip.x - 75, y: blip.y - 75, width: 150, height: 150))
    }
  }

  /// The head, drawn in a 100-unit box like the app icon's, with a clear gap around it so the
  /// radar passes behind.
  private static func dino(_ ctx: CGContext) {
    ctx.saveGState()
    ctx.translateBy(x: 40, y: 374)
    ctx.scaleBy(x: 6.4, y: 6.4)
    let head = CGMutablePath()
    head.addEllipse(in: CGRect(x: 10, y: 12, width: 58, height: 50))
    head.addRoundedRect(in: CGRect(x: 16, y: 40, width: 36, height: 66), cornerWidth: 16, cornerHeight: 16)
    for (x, y, r) in [(29.0, 13.0, 9.0), (16.0, 23.0, 9.0), (10.0, 38.0, 9.0), (10.0, 54.0, 8.5), (12.0, 70.0, 8.0), (14.0, 86.0, 7.5)] {
      head.addEllipse(in: CGRect(x: x - r, y: y - r, width: 2 * r, height: 2 * r))
    }
    ctx.setBlendMode(.clear)
    ctx.addPath(head)
    ctx.setLineWidth(12)
    ctx.setLineJoin(.round)
    ctx.strokePath()
    ctx.setBlendMode(.normal)
    ctx.addPath(head)
    ctx.setFillColor(NSColor.black.cgColor)
    ctx.fillPath()
    // Eye and smile, cut out.
    ctx.setBlendMode(.clear)
    ctx.fillEllipse(in: CGRect(x: 40, y: 24, width: 10, height: 14))
    ctx.setLineWidth(6)
    ctx.setLineCap(.round)
    ctx.move(to: CGPoint(x: 41, y: 50))
    ctx.addCurve(to: CGPoint(x: 66, y: 46), control1: CGPoint(x: 48, y: 55), control2: CGPoint(x: 59, y: 54))
    ctx.strokePath()
    ctx.restoreGState()
  }
}
