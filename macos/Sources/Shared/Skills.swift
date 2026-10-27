import Foundation

/// The agents Rex Radar sends skills to, by Rex app id, and how each takes one at its prompt.
enum SkillAgent: String, CaseIterable, Identifiable {
  case claudeCode = "claude-code"
  case codex
  case antigravity
  case qoder

  var id: String { rawValue }
  var title: String { Pane.appLabel(rawValue) }

  /// The command that starts the agent in a new pane.
  var command: String {
    switch self {
    case .claudeCode: "claude"
    case .codex: "codex"
    case .antigravity: "agy"
    case .qoder: "qodercli"
    }
  }

  /// What goes before a skill's name: Codex mentions skills as `$name`, the others run `/name`.
  var sigil: String { self == .codex ? "$" : "/" }

  /// Whether a skill sent while the agent works waits for its turn. Qoder 1.1.78 refuses: "Slash
  /// commands cannot be queued", and the line stays at its prompt.
  var queues: Bool { self != .qoder }
}

/// A skill or slash command an agent offers in a pane, as the Mac finds it on disk.
struct Skill: Codable, Hashable, Identifiable {
  enum Scope: String, Codable, CaseIterable {
    case project, user, plugin

    var title: String {
      switch self {
      case .project: "Project"
      case .user: "User"
      case .plugin: "Plugins"
      }
    }
  }

  /// What follows the sigil: `commit`, or `plugin:skill` for a plugin's.
  var name: String
  var description: String?
  var scope: Scope
  var plugin: String?
  /// `/` or `$`; absent from Macs that only sent skills to Claude, which take `/`.
  var sigil: String?

  var id: String { scope.rawValue + "/" + name }

  /// What you'd type at the agent's prompt: `/commit`, `$imagegen`.
  var command: String { (sigil ?? "/") + name }

  /// Every word of the filter appears in the name or the description.
  func matches(_ query: String) -> Bool {
    let words = query.lowercased().split(whereSeparator: \.isWhitespace)
    let text = (name + " " + (description ?? "")).lowercased()
    return words.allSatisfy { text.contains(String($0.drop { $0 == "/" || $0 == "$" })) }
  }
}

/// POST /v1/skill: which skill to run in the pane, and what to type after its name.
struct SkillRequest: Codable {
  var name: String
  var arguments: String?

  /// What Rex Radar types into the pane before the key that submits it.
  func line(_ agent: SkillAgent) -> String {
    let args = arguments?.trimmingCharacters(in: .whitespaces) ?? ""
    return args.isEmpty ? agent.sigil + name : "\(agent.sigil)\(name) \(args)"
  }

  /// One short line, nothing that could act as a key press when typed.
  func validate() throws {
    let args = arguments ?? ""
    guard args.count <= 500,
      (name + args).unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) })
    else { throw SkillError.invalid }
  }
}

enum SkillError: LocalizedError, Equatable {
  case invalid, unknown(String), busy, working, unsupported

  var errorDescription: String? {
    switch self {
    case .invalid: "Arguments must be one short line."
    case .unknown(let command): "The agent doesn't offer \(command) in that pane."
    case .busy: "The agent is waiting on a question or a permission in that pane; answer it first."
    case .working: "The agent can't queue skills; send it when the agent is done."
    case .unsupported: "That pane isn't running Claude Code, Codex, Antigravity or Qoder on this Mac's Rex."
    }
  }
}

extension Row {
  /// The agent in the pane, when it's one Rex Radar can send skills to.
  var skillAgent: SkillAgent? { pane.app.flatMap(SkillAgent.init(rawValue:)) }

  /// Claude Code, Codex, Antigravity or Qoder on the Mac's own Rex server (its skills are on that
  /// Mac's disk), not stuck on a prompt that typing would answer, nor working when it can't queue.
  var takesSkills: Bool {
    guard let agent = skillAgent else { return false }
    return server == nil && !stale && state != .blocked && (agent.queues || state != .working)
  }
}
