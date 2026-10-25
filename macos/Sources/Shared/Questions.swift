import Foundation

/// The question list an agent is asking in a pane: Claude Code's AskUserQuestion (as the
/// hooks/claude-rex-questions hook saves it), Codex's request_user_input or Antigravity's
/// ask_question (both read from the agent's own records on the Mac).
struct PendingQuestions: Codable, Hashable {
  var toolUseId: String?
  var askedAt: String?
  var questions: [AgentQuestion]
  /// The Rex app id of the agent asking ("claude-code" when the hook file has none).
  var app: String?

  /// Agents whose question forms were checked to take the keys Rex.answer types: Claude Code
  /// 2.1.310, Codex 0.164.0 and Antigravity 1.4.7, on 2026-10-25.
  static let apps: Set<String> = ["claude-code", "codex", "antigravity"]

  var agentName: String { Pane.appLabel(app ?? "claude-code") }
}

struct AgentQuestion: Codable, Hashable {
  struct Option: Codable, Hashable {
    var label: String
    var description: String?
  }

  var question: String
  var header: String?
  var options: [Option]
  var multiSelect: Bool?

  var isMulti: Bool { multiSelect ?? false }
}

/// One answer per question: chosen options (0-based), or free text for a single-choice question.
/// Free text on a multi-select question isn't offered: Claude's form doesn't take it by typing,
/// and Codex asks only single-choice questions.
struct QuestionAnswer: Codable, Hashable {
  var options: [Int]?
  var text: String?

  static func option(_ index: Int) -> Self { .init(options: [index]) }
  static func options(_ indices: [Int]) -> Self { .init(options: indices.sorted()) }
  static func text(_ text: String) -> Self { .init(text: text) }
}

enum AnswerError: LocalizedError, Equatable {
  case invalid(String)
  case notWaiting
  case notAtStart
  case reviewMismatch(String)
  case stillWaiting

  var errorDescription: String? {
    switch self {
    case .invalid(let why): "Invalid answer: \(why)"
    case .notWaiting: "That pane isn't asking these questions anymore."
    case .notAtStart: "The form in Rex has moved on from the first question; finish it there."
    case .reviewMismatch(let what): "Claude's review didn't match (\(what)); left it open in Rex for you."
    case .stillWaiting: "The agent still shows the questions; check the pane in Rex."
    }
  }
}

extension PendingQuestions {
  /// Checks answers against the questions: one per question, options in range, text only where
  /// it can be typed, and nothing that could act as a key press when typed.
  func validate(_ answers: [QuestionAnswer]) throws {
    guard answers.count == questions.count else { throw AnswerError.invalid("one answer per question") }
    for (q, a) in zip(questions, answers) {
      if let text = a.text {
        guard !q.isMulti else { throw AnswerError.invalid("free text only on single-choice questions") }
        guard a.options == nil, !text.trimmingCharacters(in: .whitespaces).isEmpty, text.count <= 300,
          text.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) })
        else { throw AnswerError.invalid("text must be one short line") }
      } else {
        let picked = a.options ?? []
        guard Set(picked).count == picked.count, picked.allSatisfy({ (0..<q.options.count).contains($0) }) else {
          throw AnswerError.invalid("option out of range")
        }
        guard q.isMulti ? true : picked.count == 1 else { throw AnswerError.invalid("pick one option") }
      }
    }
  }

  /// What Claude's review screen shows for each answer ("→ Blue", "→ Crisps, Fruit").
  func reviewLines(_ answers: [QuestionAnswer]) -> [String] {
    zip(questions, answers).map { q, a in
      a.text ?? (a.options ?? []).sorted().map { q.options[$0].label }.joined(separator: ", ")
    }
  }
}
