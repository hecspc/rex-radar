import AppKit

/// `RexRadar --answer <block id> '<answers json>'`: answers a pane's question list the way the
/// app's buttons do, prints the outcome and quits. For testing without clicking.
@MainActor
enum AnswerCommand {
  static var arguments: (block: String, json: String)? {
    let args = CommandLine.arguments
    guard let i = args.firstIndex(of: "--answer"), i + 2 < args.count else { return nil }
    return (args[i + 1], args[i + 2])
  }

  static func run(_ block: String, _ json: String) {
    Task {
      let store = Store.shared
      store.reload()
      do {
        guard let row = store.rows.first(where: { $0.pane.blockId.hasSuffix(block) }) else {
          throw AnswerError.notWaiting
        }
        let answers = try JSONDecoder().decode([QuestionAnswer].self, from: Data(json.utf8))
        try await store.answer(row, answers)
        print("answered")
      } catch {
        print("refused: \(error.localizedDescription)")
      }
      exit(0)
    }
  }
}
