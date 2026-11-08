import SwiftUI

/// Every agent from every paired Mac as a grid of cards, most urgent first. Select opens one in
/// Rex, shows an agent's questions when they can be answered from here, or asks to allow or deny
/// the permission an agent waits on.
struct TVAgentsScreen: View {
  let client: HubClient
  @FocusState private var focused: String?
  @FocusState private var settingsFocused: Bool
  @State private var answering: Agent?
  @State private var deciding: Agent?

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
            // As on the Mac: one grid of cards, most urgent first, filling every row, then resting
            // agents as strips. Four to a row: it's a wall.
            let active = client.agents.filter { !$0.row.isResting }
            let resting = client.agents.filter(\.row.isResting)
            VStack(alignment: .leading, spacing: 48) {
              if !active.isEmpty {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 390), spacing: 32, alignment: .top)], spacing: 32) {
                  ForEach(active) { agent in card(agent) }
                }
              }
              if !resting.isEmpty {
                VStack(alignment: .leading, spacing: 24) {
                  TVSectionHeader(title: "Resting", count: resting.count)
                  LazyVGrid(columns: [GridItem(.adaptive(minimum: 560), spacing: 32, alignment: .top)], spacing: 20) {
                    ForEach(resting) { agent in
                      TVRestingStrip(row: agent.row) { client.open(agent) }
                        .focused($focused, equals: agent.id)
                    }
                  }
                }
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
    .confirmationDialog(
      "\(deciding?.row.appLabel ?? "The agent") asks permission",
      isPresented: Binding(get: { deciding != nil }, set: { if !$0 { deciding = nil } }), presenting: deciding
    ) { agent in
      Button("Allow") { client.decide(agent, .allow) }
      Button("Deny", role: .destructive) { client.decide(agent, .deny) }
      Button("Open in Rex Instead") { client.open(agent) }
    } message: { agent in
      Text(agent.row.permission?.prompt ?? "")
    }
    // For simulators: `SIMCTL_CHILD_REXRADAR_SHOW_ANSWER=1` opens the first answerable agent's questions.
    .task(id: client.agents.filter(client.canAnswer).map(\.id)) {
      guard ProcessInfo.processInfo.environment["REXRADAR_SHOW_ANSWER"] == "1", answering == nil else { return }
      answering = client.agents.first(where: client.canAnswer)
    }
  }

  private func card(_ agent: Agent) -> some View {
    let answerable = client.canAnswer(agent)
    let decidable = client.canDecide(agent)
    return TVAgentCard(row: agent.row, answerable: answerable, decidable: decidable) {
      if answerable {
        answering = agent
      } else if decidable {
        deciding = agent
      } else {
        client.open(agent)
      }
    }
    .focused($focused, equals: agent.id)
  }

  private var header: some View {
    HStack(alignment: .firstTextBaseline) {
      VStack(alignment: .leading, spacing: 6) {
        Text("Rex Radar").font(.largeTitle.weight(.bold))
        Text(summary).foregroundStyle(.secondary)
      }
      Spacer()
      HStack(spacing: 40) {
        // The time now, beside "updated …": a TV has no menu bar clock to compare against.
        TimelineView(.everyMinute) { context in
          Text(context.date, format: .dateTime.hour().minute())
            .font(.body.weight(.medium).monospacedDigit())
            .foregroundStyle(.secondary)
        }
        // Just the gear until it has focus; then "Settings" slides out, pushing the clock aside.
        NavigationLink {
          TVSettings(client: client)
        } label: {
          HStack(spacing: 12) {
            Image(systemName: "gearshape")
            if settingsFocused {
              Text("Settings").transition(.move(edge: .trailing).combined(with: .opacity))
            }
          }
          .accessibilityLabel("Settings")
        }
        // A circle around the gear alone, a capsule once the label shows.
        .buttonBorderShape(settingsFocused ? .capsule : .circle)
        .focused($settingsFocused)
      }
      .animation(.spring(duration: 0.35), value: settingsFocused)
    }
  }

  private var summary: String {
    var parts = [RowSection.summary(client.agents) { $0.row }].filter { !$0.isEmpty }
    if let updated = client.updated { parts.append("updated \(updated.formatted(date: .omitted, time: .shortened))") }
    return parts.joined(separator: " · ")
  }
}

/// An agent as one focusable card, which the system lifts under focus; Select opens it in Rex.
/// Laid out like the Mac's: its scope, its state and time in it, the headline and what tells it
/// apart, then what it says or asks.
struct TVAgentCard: View {
  let row: Row
  /// Its questions can be answered from here: Select shows them instead of opening it.
  var answerable = false
  /// Its permission can be allowed or denied from here: Select asks which.
  var decidable = false
  let select: () -> Void

  private var facts: [(symbol: String, text: String)] {
    row.facts(session: true) + (row.server == nil ? [] : [("server.rack", row.source)])
  }

  var body: some View {
    Button(action: select) {
      VStack(alignment: .leading, spacing: 12) {
        HStack(spacing: 14) {
          Scope(row: row, size: 34)
          StateEyebrow(row: row)
          Spacer(minLength: 8)
          AgentIcon(row: row, size: 24)
        }
        VStack(alignment: .leading, spacing: 4) {
          Text(row.headline).font(.headline).lineLimit(2)
          if !facts.isEmpty {
            Text(facts.map(\.text).joined(separator: " · "))
              .font(.caption2.monospaced()).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
          }
        }
        if let permission = row.permission {
          Text(permission.prompt).font(.caption.monospaced()).lineLimit(3)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(row.state.color.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
        } else if let question = row.questions?.questions.first {
          Quote(text: question.question, color: row.state.color, lineLimit: 2).font(.caption)
        } else if let message = row.message {
          Quote(text: message, color: row.state == .error ? row.state.color : .secondary, lineLimit: 2).font(.caption)
        }
        Spacer(minLength: 0)
        if answerable, let n = row.questions?.questions.count {
          Label("Answer \(n) question\(n == 1 ? "" : "s")", systemImage: "questionmark.bubble.fill")
            .font(.caption.weight(.semibold)).foregroundStyle(.tint)
        } else if decidable {
          Label("Allow or deny", systemImage: "hand.raised.fill")
            .font(.caption.weight(.semibold)).foregroundStyle(.tint)
        }
      }
      .padding(24)
      .frame(maxWidth: .infinity, minHeight: 250, alignment: .topLeading)
      // The state's colour as an outline rather than a fill (a fill bled past the card into the
      // row), inside the label so it lifts with the card under focus.
      .overlay {
        if row.state.needsAttention && !row.stale {
          RoundedRectangle(cornerRadius: 12).strokeBorder(row.state.color.opacity(0.8), lineWidth: 3)
        }
      }
    }
    .buttonStyle(.card)
    .opacity(row.stale ? 0.5 : 1)
  }
}

/// A resting agent as one focusable line: its scope, what it is, where, and how long it has
/// rested. Select opens it in Rex.
struct TVRestingStrip: View {
  let row: Row
  var showSession = true
  let select: () -> Void

  private var place: String? {
    let fact = showSession ? row.pane.session : row.facts(session: false).first?.text
    let text = [fact, row.server == nil ? nil : row.source].compactMap { $0 }.joined(separator: " · ")
    return text.isEmpty ? nil : text
  }

  var body: some View {
    Button(action: select) {
      HStack(spacing: 20) {
        Scope(row: row, size: 28)
        Text(row.headline).font(.callout.weight(.semibold)).lineLimit(1).layoutPriority(1)
        Spacer(minLength: 12)
        if let place {
          Text(place).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
        }
        Text(row.stale ? "stale" : row.elapsed() ?? "").font(.caption.monospaced()).foregroundStyle(.tertiary)
        AgentIcon(row: row, size: 24)
      }
      .padding(.horizontal, 28)
      .padding(.vertical, 18)
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .buttonStyle(.card)
    .opacity(row.stale ? 0.5 : 1)
  }
}

/// Above the resting agents on the TV: a title and how many.
struct TVSectionHeader: View {
  let title: String
  let count: Int

  var body: some View {
    HStack(spacing: 16) {
      Text(title.uppercased()).font(.system(.headline, design: .monospaced).weight(.bold)).tracking(2).lineLimit(1)
      Text("\(count)").font(.system(.headline, design: .monospaced)).foregroundStyle(.secondary)
    }
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

/// An agent's question list, full screen and answered with the remote: the agent on the left, its
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
        HStack(spacing: 16) {
          Scope(row: agent.row, size: 40)
          StateEyebrow(row: agent.row)
        }
        Text(agent.row.headline).font(.largeTitle.weight(.bold)).lineLimit(2)
        Text((agent.row.facts(session: true).map(\.text) + [agent.serverLabel]).joined(separator: " · "))
          .foregroundStyle(.secondary)
        Text("\(agent.row.appLabel) is asking. Pick an answer for each question, then Send.")
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
