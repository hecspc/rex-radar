import Foundation

/// GET /v1/agents from the Mac hub (HubServer), as the iOS app reads it.
struct AgentsResponse: Codable {
  var host: String
  var sources: [String]
  var rows: [Row]
  var writtenAt: Date
  /// Whether this Mac lets phones answer Claude's questions (Settings, off by default).
  var answering: Bool? = nil
  /// Whether this Mac lets phones send skills to Claude (Settings, off by default).
  var skills: Bool? = nil
}
