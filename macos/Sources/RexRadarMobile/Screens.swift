import SwiftUI

/// Agents from every paired Mac. iPad: the cards, with a sidebar of Macs and Rex servers hidden
/// until you show it; iPhone: the same as a stack.
struct AgentsScreen: View {
  @Bindable var client: HubClient
  @State private var selection: String? = AgentsScreen.all
  @State private var showSettings = false
  /// iPad starts on the cards alone; the sidebar button shows the Macs and servers.
  @State private var columns: NavigationSplitViewVisibility = .detailOnly
  @Environment(\.horizontalSizeClass) private var sizeClass
  static let all = "__all__"

  var body: some View {
    NavigationSplitView(columnVisibility: $columns) {
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
        .toolbar {
          // With the sidebar hidden, its gear is too: the cards get one of their own.
          if sizeClass == .regular && columns == .detailOnly {
            ToolbarItem(placement: .primaryAction) {
              Button { showSettings = true } label: { Image(systemName: "gearshape") }
                .accessibilityLabel("Settings")
            }
          }
        }
    }
    // iPad: the sidebar, once shown, sits beside the cards in landscape and slides over in portrait.
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
  @State private var showNewSession = false

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
          // One grid of cards, most urgent first, filling every row; resting agents follow as strips.
          let active = agents.filter { !$0.row.isResting }
          let resting = agents.filter(\.row.isResting)
          if !active.isEmpty {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 300, maximum: 520), spacing: 14, alignment: .top)], spacing: 14) {
              ForEach(active) { agent in
                HeroCard(
                  row: agent.row, open: { client.open(agent) },
                  answer: client.canAnswer(agent) ? { answering = agent } : nil,
                  skill: client.canSendSkill(agent) ? { picking = agent } : nil,
                  decide: client.canDecide(agent) ? { client.decide(agent, $0) } : nil,
                  close: client.canClose(agent) ? { client.close(agent) } : nil, fillHeight: true)
              }
            }
          }
          if !resting.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
              SectionHeader(title: "Resting", count: resting.count)
              LazyVGrid(columns: [GridItem(.adaptive(minimum: 300, maximum: 520), spacing: 10, alignment: .top)], spacing: 8) {
                ForEach(resting) { agent in
                  RestingStrip(
                    row: agent.row, open: { client.open(agent) },
                    skill: client.canSendSkill(agent) ? { picking = agent } : nil,
                    close: client.canClose(agent) ? { client.close(agent) } : nil)
                }
              }
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
    .sheet(isPresented: $showNewSession) { NewSessionSheet(client: client) }
    // For simulators: `SIMCTL_CHILD_REXRADAR_SHOW_NEW_SESSION=1` opens the form once a Mac allows it.
    .task(id: client.sessionHubs.map(\.id)) {
      if ProcessInfo.processInfo.environment["REXRADAR_SHOW_NEW_SESSION"] == "1", !client.sessionHubs.isEmpty {
        showNewSession = true
      }
    }
    .toolbar {
      if !client.sessionHubs.isEmpty {
        ToolbarItem(placement: .primaryAction) {
          Button { showNewSession = true } label: { Image(systemName: "plus") }
            .accessibilityLabel("New Session")
        }
      }
    }
    .navigationTitle(title)
    .toolbarTitleDisplayMode(.inline)
  }
}

/// Before pairing: the ways to add a Mac.
struct PairScreen: View {
  let client: HubClient

  var body: some View {
    NavigationStack {
      AddMacForm(client: client, intro: true)
        .frame(maxWidth: 640)
        .frame(maxWidth: .infinity)
        .navigationTitle("Rex Radar")
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
            NavigationLink {
              EditMacForm(client: client, hub: hub)
            } label: {
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
          Text(
            "Taps open agents in Rex on the main Mac. An agent on another Mac's own Rex opens on that Mac. Tap a Mac "
              + "to change its address.")
        }
        Section {
          Toggle("Keep Screen On", isOn: $keepAwake)
        } footer: {
          Text("The screen stays on while Rex Radar is open, so the device can stay up as an agent wall.")
        }
        Section {
          NavigationLink {
            AddMacForm(client: client) { dismiss() }
              .navigationTitle("Add a Mac")
              .navigationBarTitleDisplayMode(.inline)
          } label: {
            Label("Add a Mac", systemImage: "plus")
          }
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
      .navigationTitle(agent.row.headline)
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
      .navigationTitle(agent.row.headline)
      .navigationBarTitleDisplayMode(.inline)
      .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
    }
  }
}

/// Starts an agent in a new Rex session on a Mac that allows it, in a folder on that Mac.
struct NewSessionSheet: View {
  let client: HubClient
  @Environment(\.dismiss) private var dismiss
  @State private var hubID: UUID?
  @State private var server = ""
  @State private var agent = SkillAgent.claudeCode
  @State private var directory = "~"
  @State private var starting = false
  @State private var error: String?

  private var hub: Hub? { client.sessionHubs.first { $0.id == hubID } ?? client.sessionHubs.first }
  private var servers: [String] { hub.flatMap { client.sessionServersByHub[$0.id] } ?? [] }

  var body: some View {
    NavigationStack {
      Form {
        Section {
          Picker("Agent", selection: $agent) {
            ForEach(SkillAgent.allCases) { Text($0.title).tag($0) }
          }
          LabeledContent("Folder") {
            TextField("Folder", text: $directory, prompt: Text("~"))
              .multilineTextAlignment(.trailing)
              .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
              .onSubmit(start)
          }
        } footer: {
          Text("A folder on that Mac, or on the Rex server you pick. The session is named after it.")
        }
        if client.sessionHubs.count > 1 || servers.count > 1 {
          Section {
            if client.sessionHubs.count > 1 {
              Picker("Mac", selection: Binding(get: { hub?.id }, set: { hubID = $0; server = "" })) {
                ForEach(client.sessionHubs) { Text($0.name).tag(Optional($0.id)) }
              }
            }
            if servers.count > 1 {
              Picker("Rex Server", selection: $server) {
                ForEach(servers, id: \.self) { Text($0).tag($0) }
              }
            }
          }
        }
        if let error {
          Section { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red) }
        }
      }
      .navigationTitle("New Session")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
        ToolbarItem(placement: .confirmationAction) {
          if starting { ProgressView() } else { Button("Start", action: start) }
        }
      }
      .onAppear { if server.isEmpty { server = servers.first ?? "" } }
      .onChange(of: hub?.id) { server = servers.first ?? "" }
    }
  }

  private func start() {
    guard let hub, !starting else { return }
    starting = true
    error = nil
    let request = NewSessionRequest(agent: agent.rawValue, directory: directory, server: server.isEmpty ? nil : server)
    Task {
      do {
        try await client.newSession(on: hub, request)
        dismiss()
      } catch {
        self.error = error.localizedDescription
      }
      starting = false
    }
  }
}
