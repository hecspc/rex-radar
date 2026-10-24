import SwiftUI

@main
struct RexRadarMobileApp: App {
  @State private var client = HubClient()

  var body: some Scene {
    WindowGroup {
      RootView(client: client)
        .onOpenURL { client.pair(with: $0) }
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
