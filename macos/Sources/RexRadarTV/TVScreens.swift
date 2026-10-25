import SwiftUI

/// Every agent from every paired Mac as a grid of cards, most urgent first. Select opens one in Rex.
struct TVAgentsScreen: View {
  let client: HubClient

  var body: some View {
    NavigationStack {
      ScrollView {
        GlassGroup(spacing: 40) {
          VStack(alignment: .leading, spacing: 40) {
            header
            ForEach(client.hubs.filter { client.errors[$0.id] != nil }) { hub in
              Label("\(hub.name): \(client.errors[hub.id] ?? "")", systemImage: "wifi.exclamationmark")
                .foregroundStyle(.orange)
            }
            if client.agents.isEmpty {
              ContentUnavailableView(
                "No agents", systemImage: "dot.radiowaves.left.and.right",
                description: Text("Nothing is running in Rex on your Macs right now."))
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 520, maximum: 760), spacing: 40, alignment: .top)], spacing: 40) {
              ForEach(client.agents) { agent in
                HeroCard(row: agent.row, open: { client.open(agent) }, fillHeight: true)
              }
            }
          }
        }
      }
    }
    .overlay(alignment: .bottom) {
      if let notice = client.notice {
        Text(notice)
          .font(.headline)
          .padding(.horizontal, 32)
          .padding(.vertical, 16)
          .glassBackground(in: Capsule())
          .padding(.bottom, 40)
          .transition(.move(edge: .bottom).combined(with: .opacity))
      }
    }
    .animation(.spring, value: client.notice)
  }

  private var header: some View {
    HStack(alignment: .firstTextBaseline) {
      VStack(alignment: .leading, spacing: 6) {
        Text("Rex Radar").font(.largeTitle.weight(.bold))
        Text(summary).foregroundStyle(.secondary)
      }
      Spacer()
      NavigationLink {
        TVSettings(client: client)
      } label: {
        Label("Settings", systemImage: "gearshape")
      }
    }
  }

  private var summary: String {
    let count = client.agents.count
    var parts = ["\(count) agent\(count == 1 ? "" : "s")"]
    if client.attentionCount > 0 { parts.append("\(client.attentionCount) need\(client.attentionCount == 1 ? "s" : "") you") }
    if let updated = client.updated { parts.append("updated \(updated.formatted(date: .omitted, time: .shortened))") }
    return parts.joined(separator: " · ")
  }
}

/// The paired Macs (make one the main Mac, unpair), pairing another, and keeping the screen on.
struct TVSettings: View {
  let client: HubClient
  @AppStorage("keepAwake") private var keepAwake = true
  @State private var chosen: Hub?

  var body: some View {
    List {
      Section {
        ForEach(client.hubs) { hub in
          Button { chosen = hub } label: {
            HStack {
              Label(hub.name, systemImage: hub.id == client.main?.id ? "star.fill" : "laptopcomputer")
              Spacer()
              if let error = client.errors[hub.id] {
                Text(error).foregroundStyle(.orange).lineLimit(1)
              } else {
                Text("\(hub.host):\(hub.port)").foregroundStyle(.secondary)
              }
            }
          }
        }
        NavigationLink {
          TVPairScreen(client: client)
        } label: {
          Label("Pair Another Mac", systemImage: "plus")
        }
      } header: {
        Text("Paired Macs")
      } footer: {
        Text("Selecting an agent opens it in Rex on the main Mac. An agent on another Mac's own Rex opens on that Mac.")
      }
      Section {
        Toggle("Keep the Screen On", isOn: $keepAwake)
      } footer: {
        Text("While Rex Radar is open, the Apple TV doesn't start its screen saver or go to sleep.")
      }
    }
    .navigationTitle("Settings")
    .confirmationDialog(chosen?.name ?? "", isPresented: Binding(get: { chosen != nil }, set: { if !$0 { chosen = nil } })) {
      if let hub = chosen {
        if hub.id != client.main?.id { Button("Make Main") { client.setMain(hub) } }
        Button("Unpair", role: .destructive) { client.unpair(hub) }
      }
    }
  }
}
