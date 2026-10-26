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
    // iPad landscape: sidebar beside the cards; portrait: the sidebar slides over.
    .navigationSplitViewStyle(.balanced)
    .sheet(isPresented: $showSettings) { SettingsSheet(client: client) }
    .overlay(alignment: .bottom) {
      if let notice = client.notice {
        Text(notice)
          .font(.callout.weight(.medium))
          .padding(.horizontal, 16)
          .padding(.vertical, 10)
          .glassBackground(in: Capsule())
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
  @State private var answering: Agent?
  @State private var picking: Agent?

  var body: some View {
    ScrollView {
      GlassGroup(spacing: 14) {
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
          // Portrait iPhone: one column; landscape and iPad: as many as fit.
          LazyVGrid(columns: [GridItem(.adaptive(minimum: 300, maximum: 520), spacing: 14, alignment: .top)], spacing: 14) {
            ForEach(agents) { agent in
              HeroCard(
                row: agent.row, open: { client.open(agent) },
                answer: client.canAnswer(agent) ? { answering = agent } : nil,
                skill: client.canSendSkill(agent) ? { picking = agent } : nil,
                decide: client.canDecide(agent) ? { client.decide(agent, $0) } : nil, fillHeight: true)
            }
          }
        }
        .padding()
      }
    }
    .refreshable { await client.refresh() }
    .sheet(item: $answering) { agent in AnswerSheet(client: client, agent: agent) }
    .sheet(item: $picking) { agent in SkillSheet(client: client, agent: agent) }
    // For simulators: `SIMCTL_CHILD_REXRADAR_SHOW_ANSWER=1` opens the first answerable form, and
    // `SIMCTL_CHILD_REXRADAR_SHOW_SKILLS=1` the skill picker of the first agent that takes skills.
    .task(id: agents.map(\.id)) {
      let env = ProcessInfo.processInfo.environment
      if env["REXRADAR_SHOW_ANSWER"] == "1", answering == nil { answering = agents.first(where: client.canAnswer) }
      if env["REXRADAR_SHOW_SKILLS"] == "1", picking == nil { picking = agents.first(where: client.canSendSkill) }
    }
    .navigationTitle(title)
    .toolbarTitleDisplayMode(.inline)
  }
}

/// Before pairing: how to pair, plus a manual form.
struct PairScreen: View {
  let client: HubClient

  var body: some View {
    ScrollView {
      GlassGroup(spacing: 16) {
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
        .glassProminentButtonStyle()
        .disabled(host.isEmpty || token.isEmpty)
      }
    }
  }
}

struct SettingsSheet: View {
  let client: HubClient
  @Environment(\.dismiss) private var dismiss
  @AppStorage(keepAwakeKey) private var keepAwake = keepAwakeDefault

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
        Section {
          Toggle("Keep Screen On", isOn: $keepAwake)
        } footer: {
          Text("The screen stays on while Rex Radar is open, so the device can stay up as an agent wall.")
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

/// An agent's question list as a form, sent to the Mac that reported it.
struct AnswerSheet: View {
  let client: HubClient
  let agent: Agent
  @StateObject private var draft: AnswerDraft
  @Environment(\.dismiss) private var dismiss

  init(client: HubClient, agent: Agent) {
    self.client = client
    self.agent = agent
    _draft = StateObject(wrappedValue: AnswerDraft(agent.row.questions ?? PendingQuestions(questions: [])))
  }

  var body: some View {
    NavigationStack {
      ScrollView {
        QuestionsForm(draft: draft) { answers in
          try await client.answer(agent, answers)
          dismiss()
        }
        .padding()
        .frame(maxWidth: 640)
        .frame(maxWidth: .infinity)
      }
      .navigationTitle(agent.row.pane.session ?? "Questions")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
    }
  }
}

/// The skills an agent offers in its pane, sent to the Mac that reported it.
struct SkillSheet: View {
  let client: HubClient
  let agent: Agent
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    NavigationStack {
      SkillPicker(
        load: { try await client.skills(agent) },
        send: { request in
          try await client.sendSkill(agent, request)
          dismiss()
        },
        agentName: agent.row.appLabel
      )
      .padding()
      .frame(maxWidth: 640)
      .frame(maxWidth: .infinity)
      .navigationTitle(agent.row.pane.session ?? "Skills")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
    }
  }
}
