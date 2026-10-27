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
    try select(session: p.sessionId, window: p.windowId, server: row.server, clientLabel: clientLabel)
  }

  /// Asks the Rex apps on the server (or only the one labelled `clientLabel`) to show the tab.
  private static func select(session: String, window: String, server: String?, clientLabel: String?) throws {
    let list = try call("client.list", [:], server: server) as? [String: Any]
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
          "client_id": id, "session_id": session, "action": "session.select",
          "args": ["session_id": session, "window_id": window],
        ],
        server: server)
    }
  }

  // MARK: New sessions

  /// Starts the agent in a new session named after the folder, and shows it. `rex new -c` neither
  /// expands `~` nor fails on a missing folder (it starts in the home folder, as of 2026-10-27), so
  /// a folder on this Mac is checked first, and a `~` path on another server is entered with `cd`.
  /// The agent runs through an interactive shell: Rex's login shell skips `.zshrc`, where PATH may
  /// gain `~/.local/bin` (agy, qodercli).
  static func newSession(_ agent: SkillAgent, directory: String, server: String?, clientLabel: String?) throws {
    let local = server?.isEmpty ?? true
    var path = directory.trimmingCharacters(in: .whitespaces)
    if path.isEmpty { path = "~" }
    var args = ["new"]
    var line = "exec \"${SHELL:-/bin/sh}\" -ic 'exec \(agent.command)'"
    if local {
      path = (path as NSString).expandingTildeInPath
      var isDirectory: ObjCBool = false
      guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue else {
        throw Failure.call("No folder at \(path)")
      }
      args += [sessionLabel(path), "-c", path]
    } else if path == "~" || path.hasPrefix("~/") {
      args.append(sessionLabel(path))
      let rest = path.dropFirst(path == "~" ? 1 : 2)
      if !rest.isEmpty {
        line = "cd \"$HOME\"/'" + rest.replacingOccurrences(of: "'", with: "'\\''") + "' && " + line
      }
    } else {
      args += [sessionLabel(path), "-c", path]
    }
    let out = try run(args + ["--json", "--", "/bin/sh", "-c", line], server: server)
    guard let created = try JSONSerialization.jsonObject(with: out) as? [String: Any],
      let session = created["session_id"] as? String,
      let window = (created["initial_windows"] as? [[String: Any]])?.first?["window_id"] as? String
    else { throw Failure.call("Rex didn't say which session it made") }
    try select(session: session, window: window, server: server, clientLabel: clientLabel)
  }

  /// The folder's name, as sessions name their project; "home" for the home folder.
  private static func sessionLabel(_ path: String) -> String {
    let name = (path as NSString).lastPathComponent
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    if name == "/" { return "root" }
    return name == "~" || path == home ? "home" : name
  }

  // MARK: Answering questions

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

  /// The pane's OSC 7501 records, as Rex has them now.
  static func statusRecords(_ row: Row) throws -> [[String: Any]] {
    let status = try call(
      "com.superlogical.terminal.program_status",
      ["session_id": row.pane.sessionId, "block_id": row.pane.blockId, "args": [String: String]()],
      server: row.server) as? [String: Any]
    return status?["records"] as? [[String: Any]] ?? []
  }

  /// Whether Rex says the pane's program waits on a question (OSC 7501 blocked, kind question).
  static func waitsOnQuestion(_ row: Row) throws -> Bool {
    try statusRecords(row).contains { $0["state"] as? String == "blocked" && $0["kind"] as? String == "question" }
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
  /// a single single-choice question submits as soon as it's picked. Qoder 1.1.78's form is the
  /// same, except that its review's "Submit answers" has no number and is picked with Enter.
  static func answer(_ row: Row, questions: PendingQuestions, answers: [QuestionAnswer]) throws {
    if questions.app == "codex" || questions.app == "antigravity" {
      return try answerOneByOne(row, questions: questions, answers: answers)
    }
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
    try key(row, questions.app == "qoder" ? "enter" : "1")
  }

  // MARK: Permissions

  /// The permission the pane's agent asks for right now: Rex says it's blocked on one and the
  /// screen shows the "1. Yes" option. Its prompt is Rex's message, or the screen's when there's none.
  static func permission(_ row: Row) throws -> PendingPermission? {
    guard let app = row.pane.app, PendingPermission.apps.contains(app),
      let record = try statusRecords(row).first(where: {
        $0["state"] as? String == "blocked" && $0["kind"] as? String == "permission"
      })
    else { return nil }
    let screen = try screen(row)
    guard PendingPermission.showsOptions(screen) else { return nil }
    if let msg = record["msg"] as? String, !msg.isEmpty { return PendingPermission(prompt: msg) }
    return PendingPermission.prompt(fromScreen: screen).map(PendingPermission.init)
  }

  /// Allows the permission once ("1", the first option, "Yes" or "Allow once") or denies it (Esc),
  /// as tested on Claude Code 2.1.310, Codex 0.164.0, Antigravity 1.4.7 and Qoder 1.1.78: only
  /// while the agent still asks
  /// what `prompt` says, and checks the prompt went away.
  static func decide(_ row: Row, _ decision: PermissionDecision, prompt: String) throws {
    guard let asked = try permission(row) else { throw PermissionError.notWaiting }
    guard asked.prompt == prompt else { throw PermissionError.changed }
    try key(row, decision == .allow ? "1" : "escape")
    Thread.sleep(forTimeInterval: 1)
    if try permission(row)?.prompt == prompt { throw PermissionError.stillWaiting }
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
    try statusRecords(row).contains { $0["state"] as? String == "blocked" }
  }

  /// Runs a skill the way you would, as tested on 2026-10-25; while the agent works, the message
  /// queues, except on Qoder.
  /// - Claude Code 2.1.310, Antigravity 1.4.7 and Qoder 1.1.78: `/name args`, then Enter, which
  ///   submits even while the slash menu is open. Qoder won't queue it while it works.
  /// - Codex 0.164.0: `$name args`, then Tab. Enter would only pick from the `$` menu (a space
  ///   after a bare name closes it), and while Codex works Enter steers the running turn where
  ///   Tab queues.
  static func sendSkill(_ row: Row, _ request: SkillRequest, agent: SkillAgent) throws {
    let records = try statusRecords(row)
    guard !records.contains(where: { $0["state"] as? String == "blocked" }) else { throw SkillError.busy }
    guard agent.queues || !records.contains(where: { $0["state"] as? String == "working" }) else {
      throw SkillError.working
    }
    let line = request.line(agent)
    switch agent {
    case .claudeCode, .antigravity, .qoder:
      try type(row, line)
      try key(row, "enter")
    case .codex:
      try type(row, line.contains(" ") ? line : line + " ")
      try key(row, "tab")
    }
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
