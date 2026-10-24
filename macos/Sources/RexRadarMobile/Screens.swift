import SwiftUI

/// Agents from every paired Mac. iPad: a sidebar of Macs and Rex servers beside the cards;
/// iPhone: the same as a stack.
struct AgentsScreen: View {
  @Bindable var client: HubClient
  @State private var selection: String? = AgentsScreen.all
  @State private var showSettings = false
  static let all = "__all__"

  var body: some View {
    NavigationSplitView {
      List(selection: $selection) {
        Label("All Agents", systemImage: "dot.radiowaves.left.and.right")
          .badge(client.attentionCount)
          .tag(Self.all)
        if !client.servers.isEmpty {
          Section("Rex Servers") {
            ForEach(client.servers, id: \.key) { server in
              Label(server.label, systemImage: "server.rack")
                .badge(client.agents.filter { $0.serverKey == server.key && !$0.row.stale && $0.row.state.needsAttention }.count)
                .tag(server.key)
            }
          }
        }
        Section("Macs") {
          ForEach(client.hubs) { hub in
            HStack {
              Label(hub.name, systemImage: hub.id == client.main?.id ? "star.fill" : "laptopcomputer")
              Spacer()
              if client.errors[hub.id] != nil {
                Image(systemName: "wifi.exclamationmark").foregroundStyle(.orange)
              }
            }
            .selectionDisabled()
          }
        }
      }
      .navigationTitle("Rex Radar")
      .toolbar {
        ToolbarItem {
          Button { showSettings = true } label: { Image(systemName: "gearshape") }
        }
      }
    } detail: {
      AgentList(client: client, agents: agents, title: title)
    }
    .sheet(isPresented: $showSettings) { SettingsSheet(client: client) }
    .overlay(alignment: .bottom) {
      if let notice = client.notice {
        Text(notice)
          .font(.callout.weight(.medium))
          .padding(.horizontal, 16)
          .padding(.vertical, 10)
          .glassEffect(.regular, in: .capsule)
          .padding(.bottom, 24)
          .transition(.move(edge: .bottom).combined(with: .opacity))
      }
    }
    .animation(.spring, value: client.notice)
  }

  private var agents: [Agent] {
    guard let selection, selection != Self.all else { return client.agents }
    return client.agents.filter { $0.serverKey == selection }
  }

  private var title: String {
    guard let selection, selection != Self.all else { return "All Agents" }
    return client.servers.first { $0.key == selection }?.label ?? selection
  }
}

struct AgentList: View {
  let client: HubClient
  let agents: [Agent]
  let title: String

  var body: some View {
    ScrollView {
      GlassEffectContainer(spacing: 14) {
        VStack(spacing: 14) {
          ForEach(client.hubs.filter { client.errors[$0.id] != nil }) { hub in
            Label("\(hub.name): \(client.errors[hub.id] ?? "")", systemImage: "wifi.exclamationmark")
              .font(.callout).foregroundStyle(.orange)
              .frame(maxWidth: .infinity, alignment: .leading)
          }
          if agents.isEmpty {
            ContentUnavailableView(
              "No agents", systemImage: "dot.radiowaves.left.and.right",
              description: Text("Nothing is running in Rex on your Macs right now."))
          }
          LazyVGrid(columns: [GridItem(.adaptive(minimum: 320), spacing: 14)], spacing: 14) {
            ForEach(agents) { agent in HeroCard(row: agent.row) { client.open(agent) } }
          }
        }
        .padding()
      }
    }
    .refreshable { await client.refresh() }
    .navigationTitle(title)
    .toolbarTitleDisplayMode(.inline)
  }
}

/// Before pairing: how to pair, plus a manual form.
struct PairScreen: View {
  let client: HubClient

  var body: some View {
    ScrollView {
      GlassEffectContainer(spacing: 16) {
        VStack(alignment: .leading, spacing: 16) {
          VStack(alignment: .leading, spacing: 6) {
            Image(systemName: "dot.radiowaves.left.and.right").font(.largeTitle).foregroundStyle(.tint)
            Text("Rex Radar").font(.largeTitle.weight(.bold))
            Text("Your coding agents in Rex, from your pocket. Tapping one opens it on your Mac.")
              .foregroundStyle(.secondary)
          }
          PairInstructions()
          ManualPairForm(client: client)
        }
        .padding(24)
        .frame(maxWidth: 560)
      }
      .frame(maxWidth: .infinity)
    }
  }
}

struct PairInstructions: View {
  var body: some View {
    GlassCard(padding: 16) {
      VStack(alignment: .leading, spacing: 8) {
        Label("Pair with a Mac", systemImage: "qrcode.viewfinder").font(.headline)
        Text("On the Mac, open Rex Radar → iPhone & iPad, and scan a code with this device's Camera app.")
          .font(.callout).foregroundStyle(.secondary)
      }
    }
  }
}

struct ManualPairForm: View {
  let client: HubClient
  @State private var host = ""
  @State private var token = ""

  var body: some View {
    GlassCard(padding: 16) {
      VStack(alignment: .leading, spacing: 10) {
        Label("Or enter it by hand", systemImage: "keyboard").font(.headline)
        TextField("Mac address (e.g. 100.101.102.103)", text: $host)
          .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
        TextField("Token", text: $token)
          .textInputAutocapitalization(.never).autocorrectionDisabled()
        Button("Pair") {
          client.pair(host: host, port: 7298, token: token, name: host)
          host = ""
          token = ""
        }
        .buttonStyle(.glassProminent)
        .disabled(host.isEmpty || token.isEmpty)
      }
    }
  }
}

struct SettingsSheet: View {
  let client: HubClient
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    NavigationStack {
      Form {
        Section {
          ForEach(client.hubs) { hub in
            VStack(alignment: .leading, spacing: 4) {
              HStack {
                Text(hub.name).font(.headline)
                if hub.id == client.main?.id {
                  Text("Main").font(.caption.weight(.semibold)).foregroundStyle(.tint)
                }
              }
              Text("\(hub.host):\(hub.port)").font(.caption.monospaced()).foregroundStyle(.secondary)
              if let error = client.errors[hub.id] {
                Text(error).font(.caption).foregroundStyle(.orange)
              }
            }
            .swipeActions {
              Button("Unpair", role: .destructive) { client.unpair(hub) }
              if hub.id != client.main?.id {
                Button("Make Main") { client.setMain(hub) }.tint(.blue)
              }
            }
            .contextMenu {
              if hub.id != client.main?.id { Button("Make Main") { client.setMain(hub) } }
              Button("Unpair", role: .destructive) { client.unpair(hub) }
            }
          }
        } header: {
          Text("Paired Macs")
        } footer: {
          Text("Taps open agents in Rex on the main Mac. An agent on another Mac's own Rex opens on that Mac.")
        }
        Section("Pair another Mac") {
          Text("On that Mac, open Rex Radar → iPhone & iPad and scan its code with the Camera app.")
            .font(.callout).foregroundStyle(.secondary)
        }
        if let updated = client.updated {
          Section { LabeledContent("Updated", value: updated.formatted(date: .omitted, time: .standard)) }
        }
      }
      .navigationTitle("Settings")
      .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
    }
  }
}
