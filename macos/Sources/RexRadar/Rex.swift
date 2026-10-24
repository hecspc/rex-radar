import Foundation

/// Talks to Rex servers through the `rex` CLI, the only documented client.
enum Rex {
  /// The app keeps its CLI in a versioned bundle that isn't on a GUI app's PATH.
  static let executable: String? = {
    let fm = FileManager.default
    let home = fm.homeDirectoryForCurrentUser.path
    let candidates = [
      ProcessInfo.processInfo.environment["REX_BIN"],
      home + "/Library/Application Support/com.superlogical.rex/RexServer/Versions/Current/Rex Server.app/Contents/MacOS/rex",
      "/opt/homebrew/bin/rex",
      "/usr/local/bin/rex",
    ]
    return candidates.compactMap { $0 }.first { fm.isExecutableFile(atPath: $0) }
  }()

  enum Failure: LocalizedError {
    case noRex, call(String), noApp(String?)
    var errorDescription: String? {
      switch self {
      case .noRex: "Can't find the rex CLI"
      case .call(let msg): msg
      case .noApp(let label): "No Rex app\(label.map { " labelled \($0)" } ?? "") on that server"
      }
    }
  }

  static func call(_ method: String, _ args: [String: Any], server: String?) throws -> Any {
    guard let rex = executable else { throw Failure.noRex }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: rex)
    var argv = [String]()
    if let server, !server.isEmpty { argv += ["-S", server] }
    let json = String(data: try JSONSerialization.data(withJSONObject: args), encoding: .utf8)!
    process.arguments = argv + ["api", "call", method, json]
    let out = Pipe(), err = Pipe()
    process.standardOutput = out
    process.standardError = err
    try process.run()
    let data = out.fileHandleForReading.readDataToEndOfFile()
    let errData = err.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
      throw Failure.call(String(data: errData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? method)
    }
    return (try? JSONSerialization.jsonObject(with: data)) ?? [:]
  }

  /// Shows a pane in the Rex apps on its server: focus it, then ask each app client (or only
  /// the one labelled `clientLabel`, the Mac you sit at) to select its session and tab.
  static func open(_ row: Row, clientLabel: String?) throws {
    let p = row.pane
    _ = try call("session.focus_block", ["session_id": p.sessionId, "block_id": p.blockId], server: row.server)
    let list = try call("client.list", [:], server: row.server) as? [String: Any]
    let clients = (list?["clients"] as? [[String: Any]] ?? []).filter { c in
      let info = c["info"] as? [String: Any]
      guard info?["kind"] as? String == "app" else { return false }
      guard let clientLabel, !clientLabel.isEmpty else { return true }
      return info?["label"] as? String == clientLabel
    }
    guard !clients.isEmpty else { throw Failure.noApp(clientLabel) }
    for c in clients {
      guard let id = c["client_id"] as? String else { continue }
      _ = try call(
        "client.perform",
        [
          "client_id": id, "session_id": p.sessionId, "action": "session.select",
          "args": ["session_id": p.sessionId, "window_id": p.windowId],
        ],
        server: row.server)
    }
  }
}
