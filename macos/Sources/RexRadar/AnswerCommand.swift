import AppKit

/// `RexRadar --answer <block id> '<answers json>'` answers a pane's question list, and
/// `RexRadar --decide <block id> allow|deny` its agent's permission prompt, the way the app's
/// buttons do; it prints the outcome and quits. For testing without clicking.
@MainActor
enum AnswerCommand {
  static var arguments: (flag: String, block: String, value: String)? {
    let args = CommandLine.arguments
    for flag in ["--answer", "--decide"] {
      if let i = args.firstIndex(of: flag), i + 2 < args.count { return (flag, args[i + 1], args[i + 2]) }
    }
    return nil
  }

  static func run(_ flag: String, _ block: String, _ value: String) {
    Task {
      let store = Store.shared
      store.reload()
      do {
        if flag == "--decide" {
          // The screen prompt of an agent that sends no message (Codex) is read in the background.
          try? await Task.sleep(for: .seconds(1.5))
          store.reload()
          guard let row = store.rows.first(where: { $0.pane.blockId.hasSuffix(block) }),
            let prompt = row.permission?.prompt, let decision = PermissionDecision(rawValue: value)
          else { throw PermissionError.notWaiting }
          print("prompt: \(prompt)")
          try await store.decide(row, decision, prompt: prompt)
          print(decision == .allow ? "allowed" : "denied")
        } else {
          guard let row = store.rows.first(where: { $0.pane.blockId.hasSuffix(block) }) else {
            throw AnswerError.notWaiting
          }
          let answers = try JSONDecoder().decode([QuestionAnswer].self, from: Data(value.utf8))
          try await store.answer(row, answers)
          print("answered")
        }
      } catch {
        print("refused: \(error.localizedDescription)")
      }
      exit(0)
    }
  }
}
