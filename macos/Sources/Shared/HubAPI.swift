import Foundation

/// GET /v1/agents from the Mac hub (HubServer), as the iOS app reads it.
struct AgentsResponse: Codable {
  var host: String
  var sources: [String]
  var rows: [Row]
  var writtenAt: Date
  /// Whether this Mac lets phones answer agents' questions (Settings, off by default).
  var answering: Bool? = nil
  /// Whether this Mac lets phones send skills to agents (Settings, off by default).
  var skills: Bool? = nil
  /// Whether this Mac lets phones allow or deny agents' permissions (Settings, off by default).
  var permissions: Bool? = nil
  /// Whether this Mac lets phones start agents in new sessions (Settings, off by default).
  var sessions: Bool? = nil
  /// Whether this Mac lets phones close agents' panes (Settings, off by default).
  var closing: Bool? = nil
  /// The Rex servers this Mac can start sessions on, by name.
  var servers: [String]? = nil
}

/// POST /v1/session: start the agent (a SkillAgent's raw value) in a new Rex session in the folder.
struct NewSessionRequest: Codable {
  var agent: String
  var directory: String
  /// The server's name on that Mac; nil for its own Rex.
  var server: String? = nil
}

/// POST /v1/pair: a device asks to pair without the QR code (an Apple TV, or an iPhone that found
/// the Mac over Bonjour or by address); someone allows it on the Mac.
struct PairRequestBody: Codable {
  var name: String
}

/// The answer to POST /v1/pair: poll GET /v1/pair?id=<id>. Both screens show `code`, so you can
/// tell the request you allow on the Mac is the one on your device.
struct PairTicket: Codable {
  var id: String
  var code: String
  /// The Mac pairs devices without asking (its Settings): the first poll gets the token.
  var allowed: Bool? = nil
}

/// GET /v1/pair?id=…: "pending", "allowed" (with the token and the Mac's name) or "denied".
struct PairStatus: Codable {
  var status: String
  var token: String? = nil
  var name: String? = nil
}
