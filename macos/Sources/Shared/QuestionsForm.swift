import SwiftUI

/// Claude's question list as a form: a choice per single-choice question (or your own words),
/// checkboxes per multi-select one, then Send.
struct QuestionsForm: View {
  @ObservedObject var draft: AnswerDraft
  let send: ([QuestionAnswer]) async throws -> Void
  var cancel: (() -> Void)?

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      ForEach(Array(draft.questions.questions.enumerated()), id: \.offset) { i, q in
        VStack(alignment: .leading, spacing: 8) {
          if let header = q.header {
            Text(header.uppercased()).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
          }
          Text(q.question).font(.headline).fixedSize(horizontal: false, vertical: true)
          ForEach(Array(q.options.enumerated()), id: \.offset) { j, option in
            Button { draft.toggle(i, j) } label: {
              HStack(alignment: .top, spacing: 10) {
                Image(systemName: symbol(selected: draft.picks[i].contains(j), multi: q.isMulti))
                  .foregroundStyle(draft.picks[i].contains(j) ? Color.accentColor : .secondary)
                VStack(alignment: .leading, spacing: 1) {
                  Text(option.label).foregroundStyle(.primary)
                  if let d = option.description, !d.isEmpty, d != option.label {
                    Text(d).font(.caption).foregroundStyle(.secondary)
                  }
                }
                Spacer(minLength: 0)
              }
              .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
          }
          if !q.isMulti {
            TextField("Or type your own answer", text: $draft.texts[i])
              .textFieldStyle(.roundedBorder)
              .onChange(of: draft.texts[i]) { _, text in if !text.isEmpty { draft.picks[i] = [] } }
          }
        }
      }
      if let error = draft.error {
        Label(error, systemImage: "exclamationmark.triangle").font(.callout).foregroundStyle(.orange)
          .fixedSize(horizontal: false, vertical: true)
      }
      HStack {
        if let cancel { Button("Cancel", action: cancel).glassButtonStyle() }
        Spacer()
        Button {
          guard let answers = draft.answers else { return }
          draft.sending = true
          draft.error = nil
          Task {
            do { try await send(answers) } catch { draft.error = error.localizedDescription }
            draft.sending = false
          }
        } label: {
          if draft.sending { ProgressView().controlSize(.small) } else { Label("Send to Claude", systemImage: "paperplane.fill") }
        }
        .glassProminentButtonStyle()
        .disabled(draft.answers == nil || draft.sending)
      }
    }
  }

  private func symbol(selected: Bool, multi: Bool) -> String {
    multi ? (selected ? "checkmark.square.fill" : "square") : (selected ? "largecircle.fill.circle" : "circle")
  }
}
