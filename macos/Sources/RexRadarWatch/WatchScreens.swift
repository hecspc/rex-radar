import SwiftUI

struct AgentsList: View {
  let client: HubClient

  var body: some View {
    List {
      if client.agents.isEmpty {
        Text(client.errors.isEmpty ? "No agents running" : "Can't reach your Mac")
          .foregroundStyle(.secondary)
      }
      ForEach(client.agents) { agent in
        NavigationLink(value: agent) { AgentCell(agent: agent) }
      }
    }
    .navigationDestination(for: Agent.self) { agent in AgentDetail(client: client, agent: agent) }
  }
}

struct AgentCell: View {
  let agent: Agent

  var body: some View {
    HStack(alignment: .top, spacing: 8) {
      Image(systemName: agent.row.state.symbol).foregroundStyle(agent.row.state.color)
      VStack(alignment: .leading, spacing: 2) {
        Text(agent.row.pane.session ?? "Session").font(.headline).lineLimit(1)
        Text(agent.row.stateLabel).font(.caption2).foregroundStyle(agent.row.state.color)
        if let detail = agent.row.permission?.prompt ?? agent.row.pane.msg ?? agent.row.topic {
          Text(detail).font(.caption2).foregroundStyle(.secondary).lineLimit(2)
        }
      }
    }
    .opacity(agent.row.stale ? 0.5 : 1)
  }
}

struct AgentDetail: View {
  let client: HubClient
  let agent: Agent

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 8) {
        Label(agent.row.stateLabel, systemImage: agent.row.state.symbol)
          .font(.headline).foregroundStyle(agent.row.state.color)
        Text(agent.row.pane.session ?? "Session").font(.title3.weight(.semibold))
        Text("\(agent.row.tabLabel) · \(agent.serverLabel)").font(.caption2).foregroundStyle(.secondary)
        if let topic = agent.row.topic { Text(topic).font(.footnote) }
        if let permission = agent.row.permission {
          Text(permission.prompt).font(.footnote.monospaced()).foregroundStyle(.secondary)
        } else if let msg = agent.row.pane.msg {
          Text(msg).font(.footnote).foregroundStyle(.secondary)
        }
        if client.canDecide(agent) {
          Button { client.decide(agent, .allow) } label: { Label("Allow", systemImage: "checkmark") }
            .tint(.green)
          Button(role: .destructive) { client.decide(agent, .deny) } label: { Label("Deny", systemImage: "xmark") }
        }
        if client.canAnswer(agent), let n = agent.row.questions?.questions.count {
          NavigationLink {
            WatchAnswer(client: client, agent: agent)
          } label: {
            Label("Answer \(n)", systemImage: "questionmark.bubble")
          }
          .tint(.accentColor)
        }
        Button { client.open(agent) } label: { Label("Open on Mac", systemImage: "laptopcomputer") }
      }
    }
    .navigationTitle(agent.row.stateLabel)
  }
}

/// Claude's question list on the wrist: a section per question, tap to pick, then Send.
/// Free text isn't offered here.
struct WatchAnswer: View {
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
    List {
      ForEach(Array(draft.questions.questions.enumerated()), id: \.offset) { i, q in
        Section {
          ForEach(Array(q.options.enumerated()), id: \.offset) { j, option in
            Button { draft.toggle(i, j) } label: {
              HStack {
                Text(option.label)
                Spacer()
                if draft.picks[i].contains(j) { Image(systemName: "checkmark").foregroundStyle(.tint) }
              }
            }
          }
        } header: {
          Text(q.question).textCase(nil)
        } footer: {
          if q.isMulti { Text("Pick any") }
        }
      }
      if let error = draft.error {
        Text(error).font(.footnote).foregroundStyle(.orange)
      }
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
        if draft.sending { ProgressView() } else { Label("Send", systemImage: "paperplane.fill") }
      }
      .disabled(draft.answers == nil || draft.sending)
    }
    .navigationTitle("Answer")
  }
}
