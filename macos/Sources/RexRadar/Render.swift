import AppKit
import SwiftUI

/// `RexRadar --render <dir>`: draws the panel and the window off-screen to PNGs and quits.
/// For checking the layout without clicking the menu bar.
@MainActor
enum Render {
  static var directory: URL? {
    let args = CommandLine.arguments
    guard let i = args.firstIndex(of: "--render"), i + 1 < args.count else { return nil }
    return URL(fileURLWithPath: args[i + 1])
  }

  static func run(store: Store, into dir: URL) async {
    store.reload()
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    await snap(MenuPanel(store: store), size: nil, to: dir.appendingPathComponent("panel.png"))
    await snap(MainWindow(store: store), size: NSSize(width: 860, height: 560), to: dir.appendingPathComponent("window.png"))
    await snap(SettingsView(prefs: .shared), size: nil, to: dir.appendingPathComponent("settings.png"))
    store.creatingSession = true
    await snap(MenuPanel(store: store), size: nil, to: dir.appendingPathComponent("panel-new-session.png"))
    store.creatingSession = false
    if let row = store.rows.first(where: \.takesSkills) {
      store.picking = row
      // The picker reads the skills first.
      await snap(MenuPanel(store: store), size: nil, to: dir.appendingPathComponent("panel-skills.png"), wait: 2.5)
      store.picking = nil
    }
    NSApp.terminate(nil)
  }

  private static func snap<V: View>(_ view: V, size: NSSize?, to url: URL, wait: TimeInterval = 0.6) async {
    let host = NSHostingView(rootView: view.environment(\.colorScheme, .dark))
    let fitted = size ?? host.fittingSize
    let window = NSWindow(
      contentRect: NSRect(x: -10000, y: -10000, width: fitted.width, height: fitted.height),
      styleMask: [.borderless], backing: .buffered, defer: false)
    window.appearance = NSAppearance(named: .darkAqua)
    let effect = NSVisualEffectView(frame: NSRect(origin: .zero, size: fitted))
    effect.material = .popover
    effect.state = .active
    host.frame = effect.bounds
    host.autoresizingMask = [.width, .height]
    effect.addSubview(host)
    window.contentView = effect
    window.orderFrontRegardless()
    host.layoutSubtreeIfNeeded()
    // Sleeping, not spinning the run loop: the views' tasks need the main actor meanwhile.
    try? await Task.sleep(for: .seconds(wait))
    guard let rep = effect.bitmapImageRepForCachingDisplay(in: effect.bounds) else { return }
    effect.cacheDisplay(in: effect.bounds, to: rep)
    try? rep.representation(using: .png, properties: [:])?.write(to: url)
    window.orderOut(nil)
  }
}
