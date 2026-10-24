import SwiftUI
import WatchConnectivity

@main
struct RexRadarWatchApp: App {
  @State private var client = HubClient()
  @State private var link = PhoneLink()

  var body: some Scene {
    WindowGroup {
      WatchRoot(client: client)
        .onAppear { link.start(client) }
    }
  }
}

/// Receives the paired Macs from the iPhone app (WatchSync there). `client` is set once, on the
/// main actor, before the session starts, and only used on the main actor.
final class PhoneLink: NSObject, WCSessionDelegate, @unchecked Sendable {
  private var client: HubClient?

  @MainActor func start(_ client: HubClient) {
    self.client = client
    guard WCSession.isSupported() else { return }
    WCSession.default.delegate = self
    WCSession.default.activate()
  }

  func session(_ session: WCSession, activationDidCompleteWith state: WCSessionActivationState, error: Error?) {
    apply(session.receivedApplicationContext)
  }

  func session(_ session: WCSession, didReceiveApplicationContext context: [String: Any]) { apply(context) }

  private func apply(_ context: [String: Any]) {
    guard let data = context["hubs"] as? Data, let hubs = try? JSONDecoder().decode(WidgetHubs.self, from: data)
    else { return }
    Task { @MainActor in client?.sync(hubs) }
  }
}

struct WatchRoot: View {
  @Bindable var client: HubClient
  @Environment(\.scenePhase) private var phase
  @State private var polling: Task<Void, Never>?
  @State private var path: [Agent] = []

  var body: some View {
    NavigationStack(path: $path) {
      Group {
        if client.hubs.isEmpty {
          ContentUnavailableView(
            "Not paired", systemImage: "iphone",
            description: Text("Open Rex Radar on your iPhone; it shares your Macs with this watch."))
        } else {
          AgentsList(client: client)
        }
      }
      .navigationTitle("Rex Radar")
    }
    .overlay(alignment: .bottom) {
      if let notice = client.notice {
        Text(notice).font(.footnote).padding(8).background(.thinMaterial, in: Capsule()).padding(.bottom, 4)
      }
    }
    // For simulators: `SIMCTL_CHILD_REXRADAR_SHOW_ANSWER=1` opens the first answerable agent.
    .onChange(of: client.agents.map(\.id)) {
      guard ProcessInfo.processInfo.environment["REXRADAR_SHOW_ANSWER"] == "1", path.isEmpty,
        let agent = client.agents.first(where: client.canAnswer)
      else { return }
      path = [agent]
    }
    .onChange(of: phase, initial: true) { _, phase in
      polling?.cancel()
      if phase == .active { polling = Task { await client.poll() } }
    }
  }
}
