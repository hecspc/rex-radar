import Foundation

/// The paired Macs, as the iOS app shares them with its widget (in the App Group container),
/// so the widget can fetch agents itself while the app isn't running.
struct WidgetHubs: Codable, Equatable {
  struct Entry: Codable, Equatable {
    var name: String
    var host: String
    var port: Int
    var token: String
    var isMain: Bool
  }

  var hubs: [Entry]

  private static var url: URL? {
    guard let id = SharedState.groupID, !id.hasPrefix("$") else { return nil }
    return FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: id)?
      .appendingPathComponent("hubs.json")
  }

  static func read() -> WidgetHubs? {
    guard let url, let data = try? Data(contentsOf: url) else { return nil }
    return try? JSONDecoder().decode(WidgetHubs.self, from: data)
  }

  /// Returns whether it changed.
  @discardableResult
  static func write(_ value: WidgetHubs) -> Bool {
    guard let url, read() != value, let data = try? JSONEncoder().encode(value) else { return false }
    try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    // Holds tokens: readable by this app and its widget only (the App Group container is theirs).
    return (try? data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])) != nil
  }

  /// Fetches every Mac's agents and merges them (Row.merged), the main Mac's first; nil when none answered.
  func fetchRows() async -> [Row]? {
    let ordered = hubs.filter(\.isMain) + hubs.filter { !$0.isMain }
    var answered = false
    var macs: [(name: String, rows: [Row])] = []
    for hub in ordered {
      guard let url = URL(string: "http://\(hub.host):\(hub.port)/v1/agents") else { continue }
      var request = URLRequest(url: url, timeoutInterval: 8)
      request.setValue("Bearer \(hub.token)", forHTTPHeaderField: "Authorization")
      guard let (data, response) = try? await URLSession.shared.data(for: request),
        (response as? HTTPURLResponse)?.statusCode == 200
      else { continue }
      let decoder = JSONDecoder()
      decoder.dateDecodingStrategy = .iso8601
      guard let agents = try? decoder.decode(AgentsResponse.self, from: data) else { continue }
      answered = true
      macs.append((hub.name, agents.rows))
    }
    guard answered else { return nil }
    return Row.merged(macs, labelled: hubs.count > 1).map(\.row)
  }
}
