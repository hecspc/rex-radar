import AppKit

/// The menu bar glyph: Rex's own menu bar dino, in front, over a round radar screen behind it.
///
/// The dino is loaded at run time from the installed Rex app (`MenubarIcon1`), so none of
/// Superlogical's artwork is copied here; without Rex it draws the radar alone.
/// A template image: macOS tints it for the menu bar. `alert` puts a blip on the radar.
enum MenuIcon {
  /// Rex's glyph without its 2×2 session grid (the top-right quarter).
  private static let dino: NSImage? = {
    let paths = ["/Applications/Rex Beta.app", "/Applications/Rex.app"]
    guard let path = paths.first(where: { FileManager.default.fileExists(atPath: $0) }),
      let glyph = Bundle(url: URL(fileURLWithPath: path))?.image(forResource: "MenubarIcon1")
    else { return nil }
    return NSImage(size: NSSize(width: 18, height: 18), flipped: true) { rect in
      glyph.draw(in: rect)
      NSGraphicsContext.current?.compositingOperation = .destinationOut
      NSBezierPath(rect: NSRect(x: 9.4, y: 0, width: 8.6, height: 8.2)).fill()
      return true
    }
  }()

  // The icon is a little wider than tall, so the round radar fits beside the dino.
  static let size = NSSize(width: 20, height: 18)
  // The dino: bottom left, in front, overlapping the radar's lower-left edge.
  private static let dinoRect = NSRect(x: 0, y: 3.6, width: 14.4, height: 14.4)
  // The radar screen: a round scope in the top right, behind the dino.
  private static let center = NSPoint(x: 12.4, y: 7.6)
  private static let outer: CGFloat = 7.2
  private static let inner: CGFloat = 3.9

  static func image(alert: Bool) -> NSImage {
    let image = NSImage(size: size, flipped: true) { rect in
      NSGraphicsContext.current?.cgContext.clip(to: rect)
      // The radar is background: lighter than the dino. The blip stays full strength.
      let ink = NSColor.black.withAlphaComponent(0.6)
      ink.set()
      for r in [outer, inner] {
        let ring = NSBezierPath(ovalIn: NSRect(x: center.x - r, y: center.y - r, width: 2 * r, height: 2 * r))
        ring.lineWidth = 1.2
        ring.stroke()
      }
      // The sweep: a faint wedge trailing the beam (flipped: angles run clockwise).
      let beam: CGFloat = -50
      let wedge = NSBezierPath()
      wedge.move(to: center)
      wedge.appendArc(withCenter: center, radius: outer, startAngle: beam - 55, endAngle: beam)
      wedge.close()
      NSColor.black.withAlphaComponent(0.25).setFill()
      wedge.fill()
      ink.set()
      let line = NSBezierPath()
      line.move(to: center)
      line.line(to: NSPoint(x: center.x + outer * cos(beam * .pi / 180), y: center.y + outer * sin(beam * .pi / 180)))
      line.lineWidth = 1.2
      line.lineCapStyle = .round
      line.stroke()
      if alert {
        NSColor.black.set()
        let r = (outer + inner) / 2
        let a: CGFloat = 25 * .pi / 180
        let blip = NSPoint(x: center.x + r * cos(a), y: center.y + r * sin(a))
        NSBezierPath(ovalIn: NSRect(x: blip.x - 1.7, y: blip.y - 1.7, width: 3.4, height: 3.4)).fill()
      }

      guard let dino else { return true }
      // A clear gap around the dino, so the radar passes behind it: knock out a slightly larger
      // copy (several times over, since Rex's glyph is partly transparent), then draw it.
      NSGraphicsContext.current?.compositingOperation = .destinationOut
      let halo = dinoRect.insetBy(dx: -1.2, dy: -1.2)
      for _ in 0..<4 { dino.draw(in: halo) }
      for _ in 0..<4 { dino.draw(in: dinoRect) }
      NSGraphicsContext.current?.compositingOperation = .sourceOver
      // In front and solid: Rex's glyph is partly transparent, so draw it over itself.
      for _ in 0..<3 { dino.draw(in: dinoRect) }
      return true
    }
    image.isTemplate = true
    return image
  }
}
