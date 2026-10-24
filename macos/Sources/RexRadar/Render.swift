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

  static func run(store: Store, into dir: URL) {
    store.reload()
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    snap(MenuPanel(store: store), size: nil, to: dir.appendingPathComponent("panel.png"))
    snap(MainWindow(store: store), size: NSSize(width: 860, height: 560), to: dir.appendingPathComponent("window.png"))
    snap(SettingsView(prefs: .shared), size: nil, to: dir.appendingPathComponent("settings.png"))
    NSApp.terminate(nil)
  }

  private static func snap<V: View>(_ view: V, size: NSSize?, to url: URL) {
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
    RunLoop.current.run(until: Date().addingTimeInterval(0.6))
    guard let rep = effect.bitmapImageRepForCachingDisplay(in: effect.bounds) else { return }
    effect.cacheDisplay(in: effect.bounds, to: rep)
    try? rep.representation(using: .png, properties: [:])?.write(to: url)
    window.orderOut(nil)
  }
}
