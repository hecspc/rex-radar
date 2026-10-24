import SwiftUI

extension AgentState {
  var color: Color {
    switch self {
    case .blocked: .red
    case .error: .orange
    case .done: .green
    case .working: .blue
    case .idle, .unknown: .secondary
    }
  }
}

extension Row {
  /// What the status pill says: the blocked kind when there is one.
  var stateLabel: String {
    switch state {
    case .blocked:
      switch pane.kind {
      case "permission": "Needs permission"
      case "question": "Has a question"
      case "auth": "Needs login"
      default: "Needs you"
      }
    case .error: "Error"
    case .done: "Done"
    case .working: "Working"
    case .idle: "Idle"
    case .unknown: pane.state.capitalized
    }
  }

  /// The conversation's topic, when the agent has set a terminal title worth showing.
  var topic: String? {
    guard let title = pane.title?.trimmingCharacters(in: .whitespaces), !title.isEmpty, title != "Claude Code"
    else { return nil }
    // Claude puts a spinner or ✳ glyph in front of the topic.
    let trimmed = title.drop { !$0.isLetter && !$0.isNumber }
    return trimmed.isEmpty ? nil : String(trimmed)
  }

  var tabLabel: String {
    [pane.tabIndex.map { "\($0)." }, pane.tab].compactMap { $0 }.joined(separator: " ")
  }

  var appLabel: String {
    switch pane.app {
    case "claude-code": "Claude Code"
    case let app?: app
    case nil: "Agent"
    }
  }
}
