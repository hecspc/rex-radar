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
  /// When Rex last changed the pane's status, as the watcher wrote it.
  var updatedAt: String?
  /// Where the pane's program runs, on its server's machine.
  var cwd: String?
  /// The git branch checked out there: set by the Mac for its own server's panes.
  var branch: String?

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

  /// Can't go on without you (a question, a permission, a login, an error): the menu bar, badges
  /// and complications count these. Done agents are listed, but not counted.
  var needsAttention: Bool { self == .blocked || self == .error }
}

/// A pane as shown: its snapshot's source and server, and whether that watcher went quiet.
struct Row: Codable, Identifiable, Hashable {
  var pane: Pane
  var source: String
  var server: String?
  var stale: Bool
  /// The question list the agent is asking here, when Rex Radar can answer it (see PendingQuestions).
  var questions: PendingQuestions?
  /// The permission it waits on, when it's one Rex Radar can allow or deny.
  var permission: PendingPermission?
  /// The Mac it runs on, as this device paired it: set by a device paired with several Macs.
  var machine: String? = nil

  var id: String { source + "/" + pane.blockId }
  /// Where it runs, when that's worth saying: its Mac, or the remote server it was seen through.
  var machineLabel: String? { machine ?? (server == nil ? nil : source) }
  /// The same as a card's fact, after the others.
  var machineFacts: [(symbol: String, text: String)] {
    machineLabel.map { [(machine == nil ? "server.rack" : "desktopcomputer", $0)] } ?? []
  }
  var state: AgentState { AgentState(pane.state) }

  /// A finished agent stays `done` in Rex until its next run; after this long, or once you open
  /// it from Rex Radar, it counts as idle (Store.reload).
  static let doneFadesAfter: TimeInterval = 5 * 60

  /// The order of every list: live before stale, then by state (blocked, error, done, working,
  /// idle), then the most recent change first.
  static func byUrgency(_ a: Row, _ b: Row) -> Bool {
    if a.stale != b.stale { return !a.stale }
    if a.state != b.state { return a.state < b.state }
    let (ta, tb) = (a.since ?? .distantPast, b.since ?? .distantPast)
    if ta != tb { return ta > tb }
    return a.id < b.id
  }

  var place: String {
    let tab = [pane.tabIndex.map { "\($0)." }, pane.tab].compactMap { $0 }.joined(separator: " ")
    return [pane.session, tab].compactMap { $0 }.joined(separator: " · ")
  }

  var detail: String? {
    if let msg = pane.msg, !msg.isEmpty { return msg }
    // Pi's title is "π - <folder>" until its session has a name.
    if pane.app == "pi" { return topic }
    if let title = pane.title, !title.isEmpty, title != "Claude Code" { return title }
    return nil
  }
}
