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
    await snap(DeviceSettings(prefs: .shared).frame(width: 500), size: nil, to: dir.appendingPathComponent("settings-devices.png"))
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
    // Liquid Glass draws nothing off-screen: REXRADAR_RENDER_ONSCREEN=1 shows each view for a moment.
    let onScreen = ProcessInfo.processInfo.environment["REXRADAR_RENDER_ONSCREEN"] == "1"
    let window = NSWindow(
      contentRect: NSRect(x: onScreen ? 80 : -10000, y: onScreen ? 80 : -10000, width: fitted.width, height: fitted.height),
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
    if size == nil, host.fittingSize != fitted {
      // Views that measure themselves (the panel's list) settle after the first layout.
      window.setContentSize(host.fittingSize)
      try? await Task.sleep(for: .seconds(0.4))
    }
    if onScreen {
      // The window as the screen shows it, glass included.
      let capture = Process()
      capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
      capture.arguments = ["-x", "-o", "-l\(window.windowNumber)", url.path]
      try? capture.run()
      capture.waitUntilExit()
      window.orderOut(nil)
      return
    }
    guard let rep = effect.bitmapImageRepForCachingDisplay(in: effect.bounds) else { return }
    effect.cacheDisplay(in: effect.bounds, to: rep)
    try? rep.representation(using: .png, properties: [:])?.write(to: url)
    window.orderOut(nil)
  }
}
