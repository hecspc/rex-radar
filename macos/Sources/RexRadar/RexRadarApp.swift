import AppKit
import ServiceManagement
import SwiftUI

@main
struct RexRadarApp: App {
  @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
  @StateObject private var store = Store.shared

  init() {
    if let dir = Render.directory {
      Task { @MainActor in await Render.run(store: Store(), into: dir) }
    }
    if let (block, json) = AnswerCommand.arguments {
      DispatchQueue.main.async { AnswerCommand.run(block, json) }
    }
  }

  var body: some Scene {
    MenuBarExtra {
      MenuPanel(store: store)
    } label: {
      MenuBarLabel(store: store)
    }
    .menuBarExtraStyle(.window)

    Window("Rex Radar", id: "main") {
      MainWindow(store: store)
    }
    .defaultSize(width: 860, height: 560)

    Settings {
      SettingsView(prefs: .shared)
    }
  }
}

struct MenuBarLabel: View {
  @ObservedObject var store: Store

  var body: some View {
    let count = store.attentionCount
    HStack(spacing: 3) {
      Image(nsImage: MenuIcon.image(alert: count > 0))
      if count > 0 { Text("\(count)") }
    }
  }
}

/// Starts the hub for iPhone and iPad; widget taps arrive as rexradar:// URLs.
final class AppDelegate: NSObject, NSApplicationDelegate {
  private var sigterm: DispatchSourceSignal?

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

  func applicationWillTerminate(_ notification: Notification) {
    MainActor.assumeIsolated { Watchers.shared.stopAll() }
  }

  func application(_ application: NSApplication, open urls: [URL]) {
    MainActor.assumeIsolated { urls.forEach(Store.shared.handle) }
  }
}
