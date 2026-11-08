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
    if pane.app == "pi" {
      // Pi titles read "π - <session name> - <folder>", and "π - <folder>" until the session
      // has a name.
      guard title.hasPrefix("π - ") else { return nil }
      var parts = title.dropFirst(4).components(separatedBy: " - ")
      guard parts.count > 1 else { return nil }
      parts.removeLast()
      return parts.joined(separator: " - ")
    }
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
    case "pi": "AgentPi"
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
    case "pi": "p.circle"
    default: "cpu"
    }
  }

  var appColor: Color {
    switch pane.app {
    case "claude-code": Color(red: 0.85, green: 0.47, blue: 0.34)
    case "codex": Color(red: 0.16, green: 0.70, blue: 0.64)
    case "antigravity": Color(red: 0.26, green: 0.52, blue: 0.96)
    case "qoder": Color(red: 0.16, green: 0.78, blue: 0.47)
    case "pi": .primary
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
    case "pi": "Pi"
    case let app?: app
    case nil: "Agent"
    }
  }
}

extension Row {
  /// What tells this agent apart from the others in its session: the conversation's topic, else
  /// the tab's name, else the pane's own label, else the agent.
  var headline: String {
    let session = pane.session?.lowercased()
    let candidates = [topic, tabName, paneLabel, folder].compactMap { $0 }.filter { !$0.isEmpty }
    return candidates.first { $0.lowercased() != session } ?? candidates.first ?? appLabel
  }

  /// The tab's name without its index.
  var tabName: String? {
    guard let tab = pane.tab?.trimmingCharacters(in: .whitespaces), !tab.isEmpty else { return nil }
    return tab
  }

  /// The pane's own label, unless it's Rex's default "shell".
  var paneLabel: String? {
    guard let label = pane.pane?.trimmingCharacters(in: .whitespaces), !label.isEmpty, label != "shell" else { return nil }
    return label
  }

  /// The last component of the working directory, or ~ for the home directory.
  var folder: String? {
    guard let cwd = pane.cwd, !cwd.isEmpty else { return nil }
    let url = URL(fileURLWithPath: cwd)
    let parts = url.pathComponents
    if parts.count == 3, parts[1] == "Users" || parts[1] == "home" { return "~" }
    return url.lastPathComponent
  }

  /// The small facts under the headline that tell agents in one session apart, each with a symbol:
  /// branch, folder (when it isn't the session's name), and where it sits (tab › pane) unless the
  /// headline already says it. The session itself is added when `session` is true.
  func facts(session: Bool) -> [(symbol: String, text: String)] {
    var facts: [(String, String)] = []
    if session, let name = pane.session { facts.append(("square.stack", name)) }
    if let branch = pane.branch { facts.append(("arrow.triangle.branch", branch)) }
    if let folder, folder.lowercased() != pane.session?.lowercased(), folder != headline {
      facts.append(("folder", folder))
    }
    let place = [tabName, paneLabel].compactMap { $0 }.filter { $0 != headline }
    if !place.isEmpty { facts.append(("rectangle.split.2x1", place.joined(separator: " › "))) }
    return facts
  }

  /// Since when Rex reports the pane in its state.
  var since: Date? { pane.updatedAt.flatMap(Row.parseDate) }

  private static func parseDate(_ text: String) -> Date? {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let date = formatter.date(from: text) { return date }
    formatter.formatOptions = [.withInternetDateTime]
    return formatter.date(from: text.replacingOccurrences(of: #"\.\d+"#, with: "", options: .regularExpression))
  }

  /// "now", "3m", "2h", "4d": how long it has been in its state.
  func elapsed(at now: Date = .now) -> String? {
    guard let since else { return nil }
    let seconds = max(0, now.timeIntervalSince(since))
    switch seconds {
    case ..<60: return "now"
    case ..<3600: return "\(Int(seconds / 60))m"
    case ..<86400: return "\(Int(seconds / 3600))h"
    default: return "\(Int(seconds / 86400))d"
    }
  }

  /// What the agent says beyond the headline: its message (Pi's is the session name, which the
  /// headline already shows).
  var message: String? {
    guard let msg = pane.msg?.trimmingCharacters(in: .whitespacesAndNewlines), !msg.isEmpty, msg != headline, msg != topic
    else { return nil }
    return msg
  }
}

/// Rows grouped for display by what they need from you, in this order: agents that need you,
/// agents just done, agents working, and resting ones (idle, done for a while, stale), which show as
/// one-line strips. Each keeps the rows' order (most urgent, then most recent, first). Sessions
/// aren't grouped: each card and strip names its own.
struct RowSection<Item>: Identifiable {
  enum Kind: Int, CaseIterable {
    case needsYou, done, working, resting

    var title: String {
      switch self {
      case .needsYou: "Needs you"
      case .done: "Done"
      case .working: "Working"
      case .resting: "Resting"
      }
    }

    init(_ row: Row) {
      if row.isResting {
        self = .resting
      } else if row.state.needsAttention || row.permission != nil || row.questions != nil {
        self = .needsYou
      } else if row.state == .done {
        self = .done
      } else {
        self = .working
      }
    }
  }

  var kind: Kind
  var items: [Item]
  var id: Int { kind.rawValue }

  /// "3 need you · 2 done · 1 working · 7 resting": how many agents in each state, for a title.
  static func summary(_ items: [Item], row: (Item) -> Row) -> String {
    let counts = Dictionary(grouping: items) { Kind(row($0)) }.mapValues(\.count)
    return Kind.allCases.compactMap { kind in
      counts[kind].map { "\($0) \(kind == .needsYou ? "need you" : kind.title.lowercased())" }
    }.joined(separator: " · ")
  }

  /// The sections that have rows, in order.
  static func sections(_ items: [Item], row: (Item) -> Row) -> [RowSection] {
    let byKind = Dictionary(grouping: items) { Kind(row($0)) }
    return Kind.allCases.compactMap { kind in byKind[kind].map { RowSection(kind: kind, items: $0) } }
  }
}
