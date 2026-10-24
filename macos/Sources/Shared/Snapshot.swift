import Foundation

/// One watcher's snapshot: `~/.local/state/rex-radar/<source>.json`, written by watcher/rex-radar.lua.
struct Snapshot: Decodable {
  var source: String
  var server: String?
  var writtenAt: Date
  var heartbeatSeconds: Double
  var panes: [Pane]

  enum CodingKeys: String, CodingKey { case source, server, writtenAt, heartbeatSeconds, panes }

  init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    source = try c.decode(String.self, forKey: .source)
    server = try c.decodeIfPresent(String.self, forKey: .server)
    writtenAt = try c.decode(Date.self, forKey: .writtenAt)
    heartbeatSeconds = try c.decodeIfPresent(Double.self, forKey: .heartbeatSeconds) ?? 15
    // Lua encodes an empty table as {}, not [].
    panes = (try? c.decode([Pane].self, forKey: .panes)) ?? []
  }
}

struct Pane: Codable, Identifiable, Hashable {
  var sessionId: String
  var session: String?
  var windowId: String
  var tab: String?
  var tabIndex: Int?
  var blockId: String
  var pane: String?
  var title: String?
  var app: String?
  var state: String
  var kind: String?
  var msg: String?

  var id: String { blockId }
}

enum AgentState: Int, Comparable, Codable {
  case blocked = 1, error, done, working, idle, unknown

  init(_ raw: String) {
    switch raw {
    case "blocked": self = .blocked
    case "error": self = .error
    case "done": self = .done
    case "working": self = .working
    case "idle": self = .idle
    default: self = .unknown
    }
  }

  static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }

  var symbol: String {
    switch self {
    case .blocked: "exclamationmark.circle.fill"
    case .error: "xmark.octagon.fill"
    case .done: "checkmark.circle.fill"
    case .working: "ellipsis.circle"
    case .idle: "circle"
    case .unknown: "questionmark.circle"
    }
  }

  /// Wants you: the menu bar counts these.
  var needsAttention: Bool { self == .blocked || self == .error || self == .done }
}

/// A pane as shown: its snapshot's source and server, and whether that watcher went quiet.
struct Row: Codable, Identifiable, Hashable {
  var pane: Pane
  var source: String
  var server: String?
  var stale: Bool
  /// The question list Claude is asking here, when it is (from the questions hook).
  var questions: PendingQuestions?

  var id: String { source + "/" + pane.blockId }
  var state: AgentState { AgentState(pane.state) }

  var place: String {
    let tab = [pane.tabIndex.map { "\($0)." }, pane.tab].compactMap { $0 }.joined(separator: " ")
    return [pane.session, tab].compactMap { $0 }.joined(separator: " · ")
  }

  var detail: String? {
    if let msg = pane.msg, !msg.isEmpty { return msg }
    if let title = pane.title, !title.isEmpty, title != "Claude Code" { return title }
    return nil
  }
}
