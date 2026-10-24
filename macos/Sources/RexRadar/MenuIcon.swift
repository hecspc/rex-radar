import AppKit

/// The menu bar glyph: Rex's own menu bar dino, with a radar where its 2×2 session grid sits.
///
/// The dino is loaded at run time from the installed Rex app (`MenubarIcon1`), so none of
/// Superlogical's artwork is copied here; without Rex it falls back to a radar alone.
/// A template image: macOS tints it for the menu bar. `alert` puts a blip on the radar.
enum MenuIcon {
  private static let rexGlyph: NSImage? = {
    let paths = ["/Applications/Rex Beta.app", "/Applications/Rex.app"]
    for path in paths where FileManager.default.fileExists(atPath: path) {
      if let image = Bundle(url: URL(fileURLWithPath: path))?.image(forResource: "MenubarIcon1") { return image }
    }
    return nil
  }()

  static func image(alert: Bool) -> NSImage {
    let image = NSImage(size: NSSize(width: 18, height: 18), flipped: true) { rect in
      // The radar's centre: the bottom-left corner of Rex's session grid.
      var center = NSPoint(x: 9.4, y: 8.2)
      var radii: [CGFloat] = [2.6, 5.0, 7.4]

      if let glyph = rexGlyph {
        glyph.draw(in: rect)
        // Clear the session grid (top right) for the radar.
        NSGraphicsContext.current?.compositingOperation = .destinationOut
        NSBezierPath(rect: NSRect(x: center.x, y: 0, width: 18 - center.x, height: center.y)).fill()
        NSGraphicsContext.current?.compositingOperation = .sourceOver
      } else {
        center = NSPoint(x: 2, y: 16)
        radii = [5, 10, 15]
      }

      NSColor.black.set()
      // Quarter arcs opening up and to the right (flipped: -90…0 is up → right).
      for r in radii {
        let arc = NSBezierPath()
        arc.appendArc(withCenter: center, radius: r, startAngle: -90, endAngle: 0)
        arc.lineWidth = 1.1
        arc.lineCapStyle = .round
        arc.stroke()
      }
      // The sweep.
      let reach = radii.last!
      let sweep = NSBezierPath()
      sweep.move(to: center)
      sweep.line(to: NSPoint(x: center.x + reach * cos(.pi / 5), y: center.y - reach * sin(.pi / 5)))
      sweep.lineWidth = 1.1
      sweep.lineCapStyle = .round
      sweep.stroke()
      if alert {
        let r = radii[1] + 0.6
        let blip = NSPoint(x: center.x + r * cos(.pi * 0.36), y: center.y - r * sin(.pi * 0.36))
        NSBezierPath(ovalIn: NSRect(x: blip.x - 1.5, y: blip.y - 1.5, width: 3, height: 3)).fill()
      }
      return true
    }
    image.isTemplate = true
    return image
  }
}
