import AppKit
import ServiceManagement
import SwiftUI

@main
struct RexRadarApp: App {
  @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
  @StateObject private var store = Store.shared

  init() {
    if let dir = Render.directory {
      DispatchQueue.main.async { Render.run(store: Store(), into: dir) }
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
  func applicationDidFinishLaunching(_ notification: Notification) {
    MainActor.assumeIsolated {
      HubServer.shared.start()
      Watchers.shared.startAll()
    }
    // Start at login, so the watchers and the hub are always running. Once only: if you turn it
    // off in System Settings → General → Login Items, it stays off.
    if !UserDefaults.standard.bool(forKey: "loginItemRegistered") {
      try? SMAppService.mainApp.register()
      UserDefaults.standard.set(true, forKey: "loginItemRegistered")
    }
  }

  func application(_ application: NSApplication, open urls: [URL]) {
    MainActor.assumeIsolated { urls.forEach(Store.shared.handle) }
  }
}
