import SwiftUI
import UIKit

@main
struct RexRadarTVApp: App {
  @State private var client = HubClient()

  var body: some Scene {
    WindowGroup {
      TVRoot(client: client)
    }
  }
}

struct TVRoot: View {
  @Bindable var client: HubClient
  @Environment(\.scenePhase) private var phase
  @AppStorage("keepAwake") private var keepAwake = true
  @State private var polling: Task<Void, Never>?

  var body: some View {
    Group {
      if client.hubs.isEmpty {
        TVPairScreen(client: client)
      } else {
        TVAgentsScreen(client: client)
      }
    }
    .onChange(of: phase, initial: true) { _, phase in
      polling?.cancel()
      if phase == .active { polling = Task { await client.poll() } }
      keepScreenOn()
    }
    .onChange(of: keepAwake) { keepScreenOn() }
  }

  /// A dashboard on the wall: no screen saver or sleep while it's open, unless turned off.
  private func keepScreenOn() {
    UIApplication.shared.isIdleTimerDisabled = keepAwake && phase == .active
  }
}
