import Foundation

/// A skill or slash command Claude Code offers in a pane, as the Mac finds it on disk.
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

  /// What follows the slash: `commit`, or `plugin:skill` for a plugin's.
  var name: String
  var description: String?
  var scope: Scope
  var plugin: String?

  var id: String { scope.rawValue + "/" + name }

  /// Every word of the filter appears in the name or the description.
  func matches(_ query: String) -> Bool {
    let words = query.lowercased().split(whereSeparator: \.isWhitespace)
    let text = (name + " " + (description ?? "")).lowercased()
    return words.allSatisfy { text.contains($0.hasPrefix("/") ? String($0.dropFirst()) : String($0)) }
  }
}

/// POST /v1/skill: which skill to run in the pane, and what to type after its name.
struct SkillRequest: Codable {
  var name: String
  var arguments: String?

  /// What Rex Radar types into the pane before Enter.
  var line: String {
    let args = arguments?.trimmingCharacters(in: .whitespaces) ?? ""
    return args.isEmpty ? "/" + name : "/\(name) \(args)"
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
  case invalid, unknown(String), busy, notClaude

  var errorDescription: String? {
    switch self {
    case .invalid: "Arguments must be one short line."
    case .unknown(let name): "Claude doesn't offer /\(name) in that pane."
    case .busy: "Claude is waiting on a question or a permission in that pane; answer it first."
    case .notClaude: "That pane isn't running Claude Code on this Mac's Rex."
    }
  }
}

extension Row {
  /// Claude Code on the Mac's own Rex server (its skills are on that Mac's disk), not stuck on a
  /// prompt that typing would answer.
  var takesSkills: Bool { pane.app == "claude-code" && server == nil && !stale && state != .blocked }
}
