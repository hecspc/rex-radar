import Foundation

/// The permission an agent waits on in a pane (Rex says blocked, kind permission), which can be
/// allowed once or denied from Rex Radar.
struct PendingPermission: Codable, Hashable {
  /// What it asks to do: Rex's status message, or the prompt read off the screen when the agent
  /// sends none (Codex).
  var prompt: String

  /// Agents whose permission prompt was checked to take "1" for "Yes" (once) and Esc for no:
  /// Claude Code 2.1.310, Codex 0.164.0 and Antigravity 1.4.7, on 2026-10-25.
  static let apps: Set<String> = ["claude-code", "codex", "antigravity"]

  /// The first option, "1. Yes…", behind the agent's selection mark (❯, › or >).
  private static func isAllowOption(_ line: some StringProtocol) -> Bool {
    line.drop { " ❯›>".contains($0) }.hasPrefix("1. Yes")
  }

  /// Whether the screen shows a permission prompt's options.
  static func showsOptions(_ screen: String) -> Bool {
    screen.split(separator: "\n").contains { isAllowOption($0) }
  }

  /// The prompt above the options, up to the line that starts the agent's turn ("• Running …"),
  /// a rule or a dozen lines: Codex shows the question, environment, reason and `$ command` there.
  static func prompt(fromScreen screen: String) -> String? {
    let lines = screen.components(separatedBy: "\n")
    guard let options = lines.lastIndex(where: { isAllowOption($0) }) else { return nil }
    var screenLines: [String] = []
    for line in lines[..<options].reversed() {
      let text = line.trimmingCharacters(in: .whitespaces)
      if text.hasPrefix("•") || text.hasPrefix("─") || text.hasPrefix("╌") || screenLines.count == 12 { break }
      if !text.isEmpty { screenLines.insert(text, at: 0) }
    }
    // Rejoin what a narrow pane wrapped: a new line starts at "$ command", "Key: value" or after a question.
    var prompt: [String] = []
    for text in screenLines {
      let starts = text.hasPrefix("$ ") || text.range(of: #"^[A-Z][A-Za-z ]{0,20}:"#, options: .regularExpression) != nil
      if let last = prompt.last, !starts, !last.hasSuffix("?") {
        prompt[prompt.count - 1] = last + " " + text
      } else {
        prompt.append(text)
      }
    }
    let joined = prompt.joined(separator: "\n")
    return joined.isEmpty ? nil : String(joined.prefix(2048))
  }
}

enum PermissionDecision: String, Codable {
  case allow, deny
}

/// POST /v1/permission's body: the decision and the prompt it was made on, so the Mac refuses
/// when the agent has moved on to another request.
struct PermissionReply: Codable {
  var decision: PermissionDecision
  var prompt: String
}

enum PermissionError: LocalizedError {
  case notWaiting, changed, stillWaiting

  var errorDescription: String? {
    switch self {
    case .notWaiting: "That agent isn't asking for permission anymore."
    case .changed: "That agent is asking for something else now; look again."
    case .stillWaiting: "The agent still shows the prompt; check the pane in Rex."
    }
  }
}
