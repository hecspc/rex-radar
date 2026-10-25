import AppKit
import ServiceManagement
import SwiftUI

@main
struct RexRadarApp: App {
  @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
  @StateObject private var store = Store.shared
  @ObservedObject private var prefs = Preferences.shared

  init() {
    if let dir = Render.directory {
      Task { @MainActor in await Render.run(store: Store(), into: dir) }
    }
    if let (block, json) = AnswerCommand.arguments {
      DispatchQueue.main.async { AnswerCommand.run(block, json) }
    }
  }

  var body: some Scene {
    MenuBarExtra(isInserted: Binding(get: { prefs.presence.showsMenuBar }, set: { _ in })) {
      MenuPanel(store: store)
    } label: {
      MenuBarLabel(store: store)
    }
    .menuBarExtraStyle(.window)

    Window("Rex Radar", id: "main") {
      MainWindow(store: store)
    }
    .defaultSize(width: 860, height: 560)
    // Without a menu bar icon, the window is the app: open it at launch.
    .defaultLaunchBehavior(Preferences.shared.presence.showsMenuBar ? .suppressed : .presented)

    Settings {
      SettingsView(prefs: .shared)
    }
  }
}

/// SwiftUI opens windows only from a view: the menu bar label (or the window, without the menu
/// bar icon) keeps the action, so a click on the Dock icon can open the window too.
@MainActor
enum WindowOpener {
  static var openWindow: OpenWindowAction?

  static func showMain() {
    openWindow?(id: "main")
    NSApp.activate()
  }
}

struct MenuBarLabel: View {
  @ObservedObject var store: Store
  @Environment(\.openWindow) private var openWindow

  var body: some View {
    let count = store.attentionCount
    HStack(spacing: 3) {
      Image(nsImage: MenuIcon.image(alert: count > 0))
      if count > 0 { Text("\(count)") }
    }
    .onAppear { WindowOpener.openWindow = openWindow }
  }
}

/// Starts the hub for iPhone and iPad; widget taps arrive as rexradar:// URLs.
final class AppDelegate: NSObject, NSApplicationDelegate {
  private var sigterm: DispatchSourceSignal?

  func applicationWillFinishLaunching(_ notification: Notification) {
    guard Render.directory == nil, AnswerCommand.arguments == nil else { return }
    MainActor.assumeIsolated { Preferences.shared.applyDock() }
  }

  func applicationDidFinishLaunching(_ notification: Notification) {
    // The --render and --answer test modes run beside the real app: no watchers, no hub.
    guard Render.directory == nil, AnswerCommand.arguments == nil else { return }
    MainActor.assumeIsolated {
      HubServer.shared.start()
      Watchers.shared.startAll()
    }
    // `kill` and logout send SIGTERM, which skips applicationWillTerminate: quit properly instead.
    signal(SIGTERM, SIG_IGN)
    let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
    source.setEventHandler { NSApp.terminate(nil) }
    source.resume()
    sigterm = source
    // Start at login, so the watchers and the hub are always running. Once only: if you turn it
    // off in System Settings → General → Login Items, it stays off.
    if !UserDefaults.standard.bool(forKey: "loginItemRegistered") {
      try? SMAppService.mainApp.register()
      UserDefaults.standard.set(true, forKey: "loginItemRegistered")
    }
  }

  /// A click on the Dock icon with no window open opens the window.
  func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
    if !hasVisibleWindows { MainActor.assumeIsolated { WindowOpener.showMain() } }
    return true
  }

  /// With the Dock icon the app is a regular app, which SwiftUI quits once its last window (the
  /// main window or the menu bar panel) closes. The watchers and the hub must keep running.
  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

  func applicationWillTerminate(_ notification: Notification) {
    MainActor.assumeIsolated { Watchers.shared.stopAll() }
  }

  func application(_ application: NSApplication, open urls: [URL]) {
    MainActor.assumeIsolated { urls.forEach(Store.shared.handle) }
  }
}
