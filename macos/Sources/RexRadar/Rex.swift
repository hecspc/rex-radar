import AppKit

/// Talks to Rex servers through the `rex` CLI, the only documented client.
enum Rex {
  static let appBundleID = "com.superlogical.rex"

  /// Brings this Mac's Rex app to the front. The panel's app is the active one when you click,
  /// so it hands activation over first; macOS ignores a bare activate() from another app.
  @MainActor static func activateApp() {
    guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: appBundleID) else { return }
    if let running = NSRunningApplication.runningApplications(withBundleIdentifier: appBundleID).first {
      NSApp.yieldActivation(to: running)
    }
    let config = NSWorkspace.OpenConfiguration()
    config.activates = true
    NSWorkspace.shared.openApplication(at: url, configuration: config)
  }

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

  // MARK: Answering Claude's questions

  /// The pane's screen as text.
  static func screen(_ row: Row) throws -> String {
    let out = try run(["capture", "-s", row.pane.sessionId, "-b", row.pane.blockId, "--trim"], server: row.server)
    return String(decoding: out, as: UTF8.self)
  }

  /// Whether the screen shows the text, though Claude wraps a long question over several lines,
  /// each starting with "│ ": compares with whitespace and the box border left out.
  static func shows(_ screen: String, _ text: String) -> Bool {
    func squeezed(_ s: String) -> String { String(s.unicodeScalars.filter { !CharacterSet.whitespacesAndNewlines.contains($0) && $0 != "│" }) }
    return squeezed(screen).contains(squeezed(text))
  }

  /// Whether Rex says the pane's program waits on a question (OSC 7501 blocked, kind question).
  static func waitsOnQuestion(_ row: Row) throws -> Bool {
    let status = try call(
      "com.superlogical.terminal.program_status",
      ["session_id": row.pane.sessionId, "block_id": row.pane.blockId, "args": [String: String]()],
      server: row.server) as? [String: Any]
    let records = status?["records"] as? [[String: Any]] ?? []
    return records.contains { $0["state"] as? String == "blocked" && $0["kind"] as? String == "question" }
  }

  static func key(_ row: Row, _ key: String) throws {
    _ = try run(["send-key", "-s", row.pane.sessionId, "-b", row.pane.blockId, key], server: row.server)
    Thread.sleep(forTimeInterval: 0.45)
  }

  static func type(_ row: Row, _ text: String) throws {
    _ = try run(["send", "-s", row.pane.sessionId, "-b", row.pane.blockId, "--", text], server: row.server)
    Thread.sleep(forTimeInterval: 0.45)
  }

  /// Answers Claude's question list by typing what a person would, as tested on Claude Code 2.1.310:
  /// a single-choice option's number selects it and moves on; "Type something" is the number after
  /// the options, then the text and Enter; on a multi-select question numbers toggle and Tab moves
  /// on. A list ends on a review screen, which must show exactly our answers before "1" submits;
  /// a single single-choice question submits as soon as it's picked.
  static func answer(_ row: Row, questions: PendingQuestions, answers: [QuestionAnswer]) throws {
    let qs = questions.questions
    guard let first = qs.first else { throw AnswerError.notWaiting }
    // Still asking the same thing? Rex must say it waits on a question, and the screen must show it.
    guard try waitsOnQuestion(row), try shows(screen(row), first.question) else { throw AnswerError.notWaiting }

    for (q, a) in zip(qs, answers) {
      if let text = a.text {
        try key(row, "\(q.options.count + 1)")
        try type(row, text)
        try key(row, "enter")
      } else if q.isMulti {
        for i in a.options ?? [] { try key(row, "\(i + 1)") }
        try key(row, "tab")
      } else {
        try key(row, "\((a.options ?? [0])[0] + 1)")
      }
    }

    if qs.count == 1 && !first.isMulti {
      Thread.sleep(forTimeInterval: 1.5)
      if try waitsOnQuestion(row) { throw AnswerError.stillWaiting }
      return
    }

    Thread.sleep(forTimeInterval: 0.6)
    let review = try screen(row)
    guard review.contains("Review your answers") else { throw AnswerError.reviewMismatch("no review screen") }
    for (q, expected) in zip(qs, questions.reviewLines(answers)) {
      guard shows(review, "→ " + expected) else { throw AnswerError.reviewMismatch("\(q.header ?? q.question): \(expected)") }
    }
    try key(row, "1")
  }

  // MARK: Skills

  /// Where the pane's program runs: the foreground process's working directory.
  static func workingDirectory(_ row: Row) throws -> String? {
    let process = try call(
      "com.superlogical.terminal.process",
      ["session_id": row.pane.sessionId, "block_id": row.pane.blockId, "args": [String: String]()],
      server: row.server) as? [String: Any]
    return (process?["foreground"] as? [String: Any])?["cwd"] as? String
  }

  /// Whether the pane's program waits on anything (a question, a permission): typing would answer it.
  static func isBlocked(_ row: Row) throws -> Bool {
    let status = try call(
      "com.superlogical.terminal.program_status",
      ["session_id": row.pane.sessionId, "block_id": row.pane.blockId, "args": [String: String]()],
      server: row.server) as? [String: Any]
    return (status?["records"] as? [[String: Any]] ?? []).contains { $0["state"] as? String == "blocked" }
  }

  /// Runs a skill the way you would: types `/name args` at Claude's prompt, then Enter. One Enter
  /// submits even while the slash menu is open, as tested on Claude Code 2.1.310; while Claude
  /// works, it queues the message.
  static func sendSkill(_ row: Row, _ request: SkillRequest) throws {
    guard try !isBlocked(row) else { throw SkillError.busy }
    try type(row, request.line)
    try key(row, "enter")
  }

  /// Runs `rex [-S server] <args>` and returns its output.
  private static func run(_ args: [String], server: String?) throws -> Data {
    guard let rex = executable else { throw Failure.noRex }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: rex)
    process.arguments = (server.map { $0.isEmpty ? [] : ["-S", $0] } ?? []) + args
    let out = Pipe(), err = Pipe()
    process.standardOutput = out
    process.standardError = err
    try process.run()
    let data = out.fileHandleForReading.readDataToEndOfFile()
    let errData = err.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
      throw Failure.call(String(decoding: errData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
    }
    return data
  }
}
