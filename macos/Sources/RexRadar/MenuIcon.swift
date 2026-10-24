import AppKit

/// The menu bar glyph: Rex's own menu bar dino, smaller and in the bottom-left corner, in front of
/// a radar whose waves spread up and to the right behind it.
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

  // Where the dino sits: about 70 %, in the bottom-left corner.
  private static let dinoRect = NSRect(x: 0, y: 5.4, width: 12.6, height: 12.6)
  // The radar's centre: the dino's head.
  private static let center = NSPoint(x: 6.2, y: 11.5)
  private static let radii: [CGFloat] = [8.0, 11.0, 14.0]

  static func image(alert: Bool) -> NSImage {
    let image = NSImage(size: NSSize(width: 18, height: 18), flipped: true) { rect in
      NSGraphicsContext.current?.cgContext.clip(to: rect)
      // The radar is background: half strength. The blip stays full strength.
      NSColor.black.withAlphaComponent(0.5).set()

      // The radar: quarter arcs up and to the right of the dino, and the sweep.
      for r in radii {
        let arc = NSBezierPath()
        arc.appendArc(withCenter: center, radius: r, startAngle: -90, endAngle: 0)
        arc.lineWidth = 1.2
        arc.lineCapStyle = .round
        arc.stroke()
      }
      let reach = radii.last!
      let sweep = NSBezierPath()
      sweep.move(to: center)
      sweep.line(to: NSPoint(x: center.x + reach * cos(.pi / 4), y: center.y - reach * sin(.pi / 4)))
      sweep.lineWidth = 1.2
      sweep.lineCapStyle = .round
      sweep.stroke()
      if alert {
        NSColor.black.set()
        let r = radii[1]
        let blip = NSPoint(x: center.x + r * cos(.pi * 0.3), y: center.y - r * sin(.pi * 0.3))
        NSBezierPath(ovalIn: NSRect(x: blip.x - 1.6, y: blip.y - 1.6, width: 3.2, height: 3.2)).fill()
      }

      guard let dino else { return true }
      // A clear gap around the dino, so the radar passes behind it: knock out a slightly larger
      // copy (several times over, since Rex's glyph is partly transparent), then draw it.
      NSGraphicsContext.current?.compositingOperation = .destinationOut
      let halo = dinoRect.insetBy(dx: -1.3, dy: -1.3)
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
