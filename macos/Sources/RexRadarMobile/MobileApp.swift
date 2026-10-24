import SwiftUI
import UIKit

@main
struct RexRadarMobileApp: App {
  @State private var client = HubClient()

  init() { WatchSync.shared.activate() }

  var body: some Scene {
    WindowGroup {
      RootView(client: client)
        .onOpenURL { client.handle($0) }
        .onAppear(perform: forceOrientationForTests)
    }
  }
}

struct RootView: View {
  @Bindable var client: HubClient
  @Environment(\.scenePhase) private var phase
  @State private var polling: Task<Void, Never>?

  var body: some View {
    Group {
      if client.hubs.isEmpty {
        PairScreen(client: client)
      } else {
        AgentsScreen(client: client)
      }
    }
    .onChange(of: phase, initial: true) { _, phase in
      polling?.cancel()
      if phase == .active { polling = Task { await client.poll() } }
    }
  }
}

/// For simulators, which this Xcode can't rotate from the command line:
/// `SIMCTL_CHILD_REXRADAR_ORIENTATION=landscape xcrun simctl launch …`.
@MainActor
private func forceOrientationForTests() {
  guard ProcessInfo.processInfo.environment["REXRADAR_ORIENTATION"] == "landscape",
    let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene
  else { return }
  scene.requestGeometryUpdate(.iOS(interfaceOrientations: .landscapeRight))
}
