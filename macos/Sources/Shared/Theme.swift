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
    // Claude and Codex put a spinner, ✳ or "[ ! ]" in front of the topic.
    let trimmed = String(title.drop { !$0.isLetter && !$0.isNumber })
    if pane.app == "qoder" {
      // Qoder titles read "◇ <topic> | Ready" (or "| Working"), and "Qoder CLI | Ready" before
      // the first prompt.
      var parts = trimmed.components(separatedBy: " | ")
      if parts.count > 1 { parts.removeLast() }
      let topic = parts.joined(separator: " | ")
      return topic.isEmpty || topic == "Qoder CLI" ? nil : topic
    }
    guard pane.app == "codex" else { return trimmed.isEmpty ? nil : trimmed }
    // Codex titles read "[Action Required | ]<topic> | <project>", and just
    // "<project>" before the first prompt; the tab already says the project.
    var parts = trimmed.components(separatedBy: " | ").filter { $0 != "Action Required" }
    guard parts.count > 1 else { return nil }
    parts.removeLast()
    return parts.joined(separator: " | ")
  }

  /// Tab, plus the pane's own label when it has one, so helpers sharing an
  /// `agents` tab can be told apart. Rex's default label "shell" says nothing.
  var tabLabel: String {
    let tab = [pane.tabIndex.map { "\($0)." }, pane.tab].compactMap { $0 }.joined(separator: " ")
    guard let label = pane.pane?.trimmingCharacters(in: .whitespaces), !label.isEmpty, label != "shell"
    else { return tab }
    return tab.isEmpty ? label : "\(tab) › \(label)"
  }

  var appLabel: String { Pane.appLabel(pane.app) }

  /// The agent's own logo in Resources/AgentIcons.xcassets, for the agents that have one.
  var appImage: String? {
    switch pane.app {
    case "claude-code": "AgentClaudeCode"
    case "codex": "AgentCodex"
    case "antigravity": "AgentAntigravity"
    case "qoder": "AgentQoder"
    default: nil
    }
  }

  /// Without a logo (another agent, or the SwiftPM build, which has no asset catalog): a
  /// generic symbol and colour.
  var appSymbol: String {
    switch pane.app {
    case "claude-code": "asterisk"
    case "codex": "curlybraces"
    case "antigravity": "arrow.up.circle"
    case "qoder": "q.circle"
    default: "cpu"
    }
  }

  var appColor: Color {
    switch pane.app {
    case "claude-code": Color(red: 0.85, green: 0.47, blue: 0.34)
    case "codex": Color(red: 0.16, green: 0.70, blue: 0.64)
    case "antigravity": Color(red: 0.26, green: 0.52, blue: 0.96)
    case "qoder": Color(red: 0.16, green: 0.78, blue: 0.47)
    default: .secondary
    }
  }
}

extension Pane {
  /// The agent's name for a Rex app id.
  static func appLabel(_ app: String?) -> String {
    switch app {
    case "claude-code": "Claude Code"
    case "codex": "Codex"
    case "antigravity": "Antigravity"
    case "qoder": "Qoder"
    case let app?: app
    case nil: "Agent"
    }
  }
}
