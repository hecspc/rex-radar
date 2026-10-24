import Foundation

/// GET /v1/agents from the Mac hub (HubServer), as the iOS app reads it.
struct AgentsResponse: Codable {
  var host: String
  var sources: [String]
  var rows: [Row]
  var writtenAt: Date
}
