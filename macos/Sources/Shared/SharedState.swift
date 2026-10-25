import Foundation

/// What the app hands the widget: every agent row, merged from all watchers, in the App Group
/// container. The widget is sandboxed and can't read the watchers' snapshots itself.
struct SharedState: Codable, Equatable {
  var rows: [Row]
  var writtenAt: Date

  /// `<team id>.<bundle prefix>.rex-radar`, from the RexRadarAppGroup key that the build fills in.
  static var groupID: String? { Bundle.main.object(forInfoDictionaryKey: "RexRadarAppGroup") as? String }

  static var url: URL? {
    guard let id = groupID, !id.hasPrefix("$"), !id.hasPrefix(".") else { return nil }
    return FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: id)?
      .appendingPathComponent("agents.json")
  }

  static func read() -> SharedState? {
    guard let url, let data = try? Data(contentsOf: url) else { return nil }
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return try? decoder.decode(SharedState.self, from: data)
  }

  /// Writes the rows if they changed. Returns whether they did, so the app reloads the widget only then.
  @discardableResult
  static func write(_ rows: [Row]) -> Bool {
    guard let url else { return false }
    if read()?.rows == rows { return false }
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    guard let data = try? encoder.encode(SharedState(rows: rows, writtenAt: Date())) else { return false }
    try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    return (try? data.write(to: url, options: .atomic)) != nil
  }
}

extension Row {
  /// rexradar://open?id=<row id>: the widget's way to ask the app to open a pane.
  var openURL: URL? {
    var c = URLComponents()
    c.scheme = "rexradar"
    c.host = "open"
    c.queryItems = [URLQueryItem(name: "id", value: id)]
    return c.url
  }
}
