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

  /// Fetches every Mac's agents and merges them, the main Mac's first; nil when none answered.
  func fetchRows() async -> [Row]? {
    let ordered = hubs.filter(\.isMain) + hubs.filter { !$0.isMain }
    var answered = false
    var seen = Set<String>()
    var rows: [Row] = []
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
      for row in agents.rows {
        let key = (row.server ?? "\(hub.name)/\(row.source)") + "|" + row.pane.blockId
        if seen.insert(key).inserted { rows.append(row) }
      }
    }
    guard answered else { return nil }
    return rows.sorted { a, b in
      if a.stale != b.stale { return !a.stale }
      if a.state != b.state { return a.state < b.state }
      return (a.pane.session ?? "") < (b.pane.session ?? "")
    }
  }
}
