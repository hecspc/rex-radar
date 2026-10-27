import AppKit

/// `RexRadar --answer <block id> '<answers json>'` answers a pane's question list, and
/// `RexRadar --decide <block id> allow|deny` its agent's permission prompt, and
/// `RexRadar --skill <block id> list|'<SkillRequest json>'` lists or sends a skill, and
/// `RexRadar --new-session claude-code|codex|antigravity|qoder <folder>` starts an agent in a new
/// session on this Mac's Rex, the way the app's buttons do; it prints the outcome and quits. For testing without clicking.
@MainActor
enum AnswerCommand {
  static var arguments: (flag: String, block: String, value: String)? {
    let args = CommandLine.arguments
    for flag in ["--answer", "--decide", "--skill", "--new-session"] {
      if let i = args.firstIndex(of: flag), i + 2 < args.count { return (flag, args[i + 1], args[i + 2]) }
    }
    return nil
  }

  static func run(_ flag: String, _ block: String, _ value: String) {
    Task {
      let store = Store.shared
      store.reload()
      do {
        if flag == "--new-session" {
          guard let agent = SkillAgent(rawValue: block) else { throw SkillError.unsupported }
          try await store.newSession(agent, directory: value, server: nil)
          print("started")
        } else if flag == "--decide" {
          // The screen prompt of an agent that sends no message (Codex) is read in the background.
          try? await Task.sleep(for: .seconds(1.5))
          store.reload()
          guard let row = store.rows.first(where: { $0.pane.blockId.hasSuffix(block) }),
            let prompt = row.permission?.prompt, let decision = PermissionDecision(rawValue: value)
          else { throw PermissionError.notWaiting }
          print("prompt: \(prompt)")
          try await store.decide(row, decision, prompt: prompt)
          print(decision == .allow ? "allowed" : "denied")
        } else if flag == "--skill" {
          guard let row = store.rows.first(where: { $0.pane.blockId.hasSuffix(block) }) else {
            throw SkillError.unsupported
          }
          if value == "list" {
            for skill in try await store.skills(for: row) { print("\(skill.scope.rawValue)\t\(skill.command)") }
          } else {
            try await store.sendSkill(row, try JSONDecoder().decode(SkillRequest.self, from: Data(value.utf8)))
            print("sent")
          }
        } else {
          // Codex's and Antigravity's questions are read in the background too.
          try? await Task.sleep(for: .seconds(1.5))
          store.reload()
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
