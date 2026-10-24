import SwiftUI

/// Agents from the paired Mac. iPad: a server sidebar beside the cards; iPhone: the same as a stack.
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
        if !client.sources.isEmpty {
          Section("Servers") {
            ForEach(client.sources, id: \.self) { source in
              Label(source, systemImage: "server.rack")
                .badge(client.rows.filter { $0.source == source && !$0.stale && $0.state.needsAttention }.count)
                .tag(source)
            }
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
      AgentList(client: client, rows: rows, title: title)
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

  private var rows: [Row] {
    guard let selection, selection != Self.all else { return client.rows }
    return client.rows.filter { $0.source == selection }
  }

  private var title: String { selection == nil || selection == Self.all ? "All Agents" : selection! }
}

struct AgentList: View {
  let client: HubClient
  let rows: [Row]
  let title: String

  var body: some View {
    ScrollView {
      GlassEffectContainer(spacing: 14) {
        VStack(spacing: 14) {
          if let error = client.error {
            Label(error, systemImage: "wifi.exclamationmark")
              .font(.callout).foregroundStyle(.orange)
              .frame(maxWidth: .infinity, alignment: .leading)
          }
          if rows.isEmpty {
            ContentUnavailableView(
              "No agents", systemImage: "dot.radiowaves.left.and.right",
              description: Text("Nothing is running in Rex on \(client.hub?.name ?? "your Mac") right now."))
          }
          LazyVGrid(columns: [GridItem(.adaptive(minimum: 320), spacing: 14)], spacing: 14) {
            ForEach(rows) { row in HeroCard(row: row) { client.open(row) } }
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
  @State private var host = ""
  @State private var token = ""

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
          GlassCard(padding: 16) {
            VStack(alignment: .leading, spacing: 8) {
              Label("Pair with your Mac", systemImage: "qrcode.viewfinder").font(.headline)
              Text("On the Mac, open Rex Radar → iPhone & iPad, and scan a code with this device's Camera app.")
                .font(.callout).foregroundStyle(.secondary)
            }
          }
          GlassCard(padding: 16) {
            VStack(alignment: .leading, spacing: 10) {
              Label("Or enter it by hand", systemImage: "keyboard").font(.headline)
              TextField("Mac address (e.g. 100.101.102.103)", text: $host)
                .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
              TextField("Token", text: $token)
                .textInputAutocapitalization(.never).autocorrectionDisabled()
              Button("Pair") { client.pair(host: host, port: 7298, token: token, name: host) }
                .buttonStyle(.glassProminent)
                .disabled(host.isEmpty || token.isEmpty)
            }
          }
        }
        .padding(24)
        .frame(maxWidth: 560)
      }
      .frame(maxWidth: .infinity)
    }
  }
}

struct SettingsSheet: View {
  let client: HubClient
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    NavigationStack {
      Form {
        if let hub = client.hub {
          Section("Paired Mac") {
            LabeledContent("Name", value: hub.name)
            LabeledContent("Address", value: "\(hub.host):\(hub.port)")
            if let updated = client.updated {
              LabeledContent("Updated", value: updated.formatted(date: .omitted, time: .standard))
            }
          }
        }
        Section {
          Button("Unpair", role: .destructive) {
            client.unpair()
            dismiss()
          }
        }
      }
      .navigationTitle("Settings")
      .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
    }
  }
}
