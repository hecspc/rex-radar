import SwiftUI

/// Every agent from every paired Mac as a grid of cards, most urgent first. Select opens one in
/// Rex, or shows Claude's questions when they can be answered from here.
struct TVAgentsScreen: View {
  let client: HubClient
  @FocusState private var focused: String?
  @State private var answering: Agent?

  var body: some View {
    NavigationStack {
      ScrollView {
        GlassGroup(spacing: 40) {
          VStack(alignment: .leading, spacing: 40) {
            header.focusSection()
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
                let answerable = client.canAnswer(agent)
                TVAgentCard(row: agent.row, answerable: answerable) {
                  if answerable { answering = agent } else { client.open(agent) }
                }
                .focused($focused, equals: agent.id)
              }
            }
            // Its own section: from Settings, at the top right, down reaches the cards.
            .focusSection()
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
    // The agents arrive after the screen appears: start on the first one, not Settings.
    .onChange(of: client.agents.first?.id, initial: true) { old, first in
      if old == nil, first != nil { focused = first }
    }
    .fullScreenCover(item: $answering) { agent in TVAnswer(client: client, agent: agent) }
    // For simulators: `SIMCTL_CHILD_REXRADAR_SHOW_ANSWER=1` opens the first answerable agent's questions.
    .task(id: client.agents.filter(client.canAnswer).map(\.id)) {
      guard ProcessInfo.processInfo.environment["REXRADAR_SHOW_ANSWER"] == "1", answering == nil else { return }
      answering = client.agents.first(where: client.canAnswer)
    }
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

/// An agent as one focusable card, which the system lifts under focus; Select opens it in Rex.
struct TVAgentCard: View {
  let row: Row
  /// Its questions can be answered from here: Select shows them instead of opening it.
  var answerable = false
  let select: () -> Void

  var body: some View {
    Button(action: select) {
      VStack(alignment: .leading, spacing: 12) {
        HStack(alignment: .top) {
          StatePill(row: row)
          Spacer()
          Text(row.appLabel).font(.caption).foregroundStyle(.secondary)
        }
        VStack(alignment: .leading, spacing: 4) {
          Text(row.pane.session ?? "Session").font(.title3.weight(.semibold)).lineLimit(1)
          Text([row.tabLabel, row.source].filter { !$0.isEmpty }.joined(separator: " · "))
            .font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
        }
        if let topic = row.topic {
          Label(topic, systemImage: "bubble.left").font(.callout).lineLimit(1)
        }
        if let msg = row.pane.msg, !msg.isEmpty {
          Text(msg).font(.callout).foregroundStyle(.secondary).lineLimit(answerable ? 1 : 2)
        }
        Spacer(minLength: 0)
        if answerable, let n = row.questions?.questions.count {
          Label("Answer \(n) question\(n == 1 ? "" : "s")", systemImage: "questionmark.bubble.fill")
            .font(.callout.weight(.semibold)).foregroundStyle(.tint)
        }
      }
      .padding(28)
      .frame(maxWidth: .infinity, minHeight: 380, maxHeight: 380, alignment: .topLeading)
    }
    .buttonStyle(.card)
    .opacity(row.stale ? 0.5 : 1)
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

/// Claude's question list, full screen and answered with the remote: the agent on the left, its
/// questions on the right. Picking an option of a single-choice question moves on to the next
/// question, then to Send. Free text isn't offered, as on the watch; Open in Rex is there for
/// anything else. Menu goes back.
struct TVAnswer: View {
  let client: HubClient
  let agent: Agent
  @StateObject private var draft: AnswerDraft
  @Environment(\.dismiss) private var dismiss
  @FocusState private var focus: Field?

  enum Field: Hashable {
    case option(Int, Int)
    case send
  }

  init(client: HubClient, agent: Agent) {
    self.client = client
    self.agent = agent
    _draft = StateObject(wrappedValue: AnswerDraft(agent.row.questions ?? PendingQuestions(questions: [])))
  }

  var body: some View {
    HStack(alignment: .top, spacing: 80) {
      VStack(alignment: .leading, spacing: 16) {
        StatePill(row: agent.row)
        Text(agent.row.pane.session ?? "Session").font(.largeTitle.weight(.bold)).lineLimit(2)
        Text("\(agent.row.tabLabel) · \(agent.serverLabel)").foregroundStyle(.secondary)
        if let topic = agent.row.topic {
          Label(topic, systemImage: "bubble.left").font(.callout)
        }
        Text("Claude is asking. Pick an answer for each question, then Send.")
          .font(.callout).foregroundStyle(.secondary).padding(.top, 24)
      }
      .frame(width: 560, alignment: .leading)
      ScrollView {
        VStack(alignment: .leading, spacing: 20) {
          ForEach(Array(draft.questions.questions.enumerated()), id: \.offset) { i, q in
            VStack(alignment: .leading, spacing: 4) {
              Text(q.question).font(.headline)
              if q.isMulti { Text("Pick any").font(.caption).foregroundStyle(.secondary) }
            }
            .padding(.top, i == 0 ? 0 : 28)
            ForEach(Array(q.options.enumerated()), id: \.offset) { j, option in
              Button {
                draft.toggle(i, j)
                guard !q.isMulti else { return }
                focus = i + 1 < draft.questions.questions.count ? .option(i + 1, 0) : .send
              } label: {
                HStack(spacing: 20) {
                  Image(systemName: draft.picks[i].contains(j) ? (q.isMulti ? "checkmark.square.fill" : "largecircle.fill.circle")
                    : (q.isMulti ? "square" : "circle"))
                  VStack(alignment: .leading, spacing: 4) {
                    Text(option.label)
                    if let description = option.description, !description.isEmpty {
                      Text(description).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    }
                  }
                  Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
              }
              .focused($focus, equals: .option(i, j))
            }
          }
          if let error = draft.error {
            Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange).padding(.top, 20)
          }
          VStack(alignment: .leading, spacing: 24) {
            Button {
              guard let answers = draft.answers else { return }
              draft.sending = true
              Task {
                do {
                  try await client.answer(agent, answers)
                  dismiss()
                } catch {
                  draft.error = error.localizedDescription
                }
                draft.sending = false
              }
            } label: {
              Group {
                if draft.sending { ProgressView() } else { Label("Send", systemImage: "paperplane.fill") }
              }
              .frame(maxWidth: .infinity)
            }
            .disabled(draft.answers == nil || draft.sending)
            .focused($focus, equals: .send)
            Button {
              client.open(agent)
              dismiss()
            } label: {
              Label("Open in Rex Instead", systemImage: "arrow.up.forward.app").frame(maxWidth: .infinity)
            }
          }
          .padding(.top, 32)
        }
        // Room for the focused button to grow without clipping.
        .padding(40)
      }
      .scrollClipDisabled()
    }
    .padding(.horizontal, 40)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    // tvOS full-screen covers are see-through: hide the grid behind it.
    .background { Rectangle().fill(.ultraThickMaterial).ignoresSafeArea() }
  }
}
