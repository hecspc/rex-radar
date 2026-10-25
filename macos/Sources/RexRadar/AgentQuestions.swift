import Darwin
import Foundation
import SQLite3

/// The question lists of agents Rex Radar has no hook in, read from the agent's own records on
/// this Mac: Rex's status carries at most the first question.
enum AgentQuestions {
  /// What the row's agent asks now, or nil. Runs the rex CLI and reads files, so call it off the
  /// main thread.
  static func load(_ row: Row) -> PendingQuestions? {
    var questions: PendingQuestions?
    switch row.pane.app {
    case "codex": questions = codex(row)
    case "antigravity": questions = antigravity(row)
    default: return nil
    }
    // Each option and the free-text one take a number key, so only nine fit.
    guard let questions, !questions.questions.isEmpty, questions.questions.allSatisfy({ $0.options.count <= 8 })
    else { return nil }
    return questions
  }

  // MARK: Codex

  /// Codex 0.164.0 asks with request_user_input, in Plan mode only: one to three single-choice
  /// questions, to which its form adds "None of the above" with notes. Its TUI runs threads in
  /// a shared app-server daemon, so neither the pane's process nor a hook (the daemon runs them,
  /// with the environment of whichever pane started it) tells which thread a pane shows. The
  /// call is in the thread's rollout file, written just before Rex reports the question: take
  /// the newest rollout whose unanswered call the screen shows, preferring the pane's directory.
  static func codex(_ row: Row) -> PendingQuestions? {
    guard let screen = try? Rex.screen(row) else { return nil }
    let cwd = try? Rex.workingDirectory(row)
    let since = row.pane.updatedAt.flatMap(date)?.addingTimeInterval(-60) ?? .distantPast
    let home = ProcessInfo.processInfo.environment["CODEX_HOME"].map { URL(fileURLWithPath: $0) }
      ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex")
    let keys: [URLResourceKey] = [.contentModificationDateKey]
    guard let walk = FileManager.default.enumerator(at: home.appendingPathComponent("sessions"), includingPropertiesForKeys: keys)
    else { return nil }
    var rollouts: [(url: URL, modified: Date)] = []
    for case let url as URL in walk where url.lastPathComponent.hasPrefix("rollout-") && url.pathExtension == "jsonl" {
      guard let modified = try? url.resourceValues(forKeys: Set(keys)).contentModificationDate, modified >= since else { continue }
      rollouts.append((url, modified))
    }
    var elsewhere: PendingQuestions?
    for rollout in rollouts.sorted(by: { $0.modified > $1.modified }).prefix(20) {
      guard let questions = pendingCodexCall(rollout.url), codexShows(screen, questions) else { continue }
      guard let cwd, !runs(rollout.url, in: cwd) else { return questions }
      elsewhere = elsewhere ?? questions
    }
    return elsewhere
  }

  /// The rollout's last request_user_input, unless a function_call_output answered it.
  private static func pendingCodexCall(_ url: URL) -> PendingQuestions? {
    guard let tail = read(url, last: 2 << 20) else { return nil }
    var answered: Set<String> = []
    for line in tail.split(separator: UInt8(ascii: "\n")).reversed() {
      guard line.count < 1 << 20, let text = String(bytes: line, encoding: .utf8), text.contains("\"function_call") else { continue }
      guard let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
        let payload = object["payload"] as? [String: Any], let callId = payload["call_id"] as? String
      else { continue }
      if payload["type"] as? String == "function_call_output" { answered.insert(callId) }
      guard payload["type"] as? String == "function_call", payload["name"] as? String == "request_user_input" else { continue }
      guard !answered.contains(callId), let arguments = payload["arguments"] as? String,
        let args = try? JSONDecoder().decode(Arguments.self, from: Data(arguments.utf8))
      else { return nil }
      return PendingQuestions(toolUseId: callId, questions: args.questions, app: "codex")
    }
    return nil
  }

  private struct Arguments: Decodable {
    var questions: [AgentQuestion]
  }

  /// Whether Codex's form shows these questions: "Question 2/3" and the second one's text.
  private static func codexShows(_ screen: String, _ questions: PendingQuestions) -> Bool {
    guard let match = screen.firstMatch(of: /Question (\d+)\/(\d+)/), let k = Int(match.1), let n = Int(match.2),
      n == questions.questions.count, (1...n).contains(k)
    else { return false }
    return Rex.shows(screen, questions.questions[k - 1].question)
  }

  /// Whether the rollout's session started in the directory (its first line names it early on).
  private static func runs(_ url: URL, in cwd: String) -> Bool {
    guard let handle = try? FileHandle(forReadingFrom: url), let head = try? handle.read(upToCount: 4096) else { return false }
    return String(decoding: head, as: UTF8.self).contains("\"cwd\":\"\(cwd)\"")
  }

  // MARK: Antigravity

  /// Antigravity 1.4.7 asks with ask_question: questions with plain options, single or multiple
  /// choice, to which its form adds "Write-in...". Each conversation is a SQLite file the agy
  /// process (Rex's owner pid) keeps open; while it asks, the call is the conversation's latest
  /// step, whose payload holds the call's JSON arguments.
  static func antigravity(_ row: Row) -> PendingQuestions? {
    guard let record = try? Rex.statusRecords(row).first(where: {
      $0["state"] as? String == "blocked" && $0["kind"] as? String == "question"
    }),
      let pid = (record["owner"] as? [String: Any])?["pid"] as? Int,
      let db = openFiles(Int32(pid)).first(where: { $0.contains("/conversations/") && $0.hasSuffix(".db") }),
      let payload = latestStep(db), let json = jsonObject(in: payload, startingWith: #"{"questions":"#),
      let call = try? JSONDecoder().decode(AskQuestion.self, from: json)
    else { return nil }
    let questions = call.questions.map {
      AgentQuestion(question: $0.question, options: ($0.options ?? []).map { .init(label: $0) }, multiSelect: $0.is_multi_select)
    }
    // Rex's message is the first question: a cheap check that this is the call it reports.
    if let msg = record["msg"] as? String, !msg.isEmpty, msg != questions.first?.question { return nil }
    return PendingQuestions(questions: questions, app: "antigravity")
  }

  private struct AskQuestion: Decodable {
    struct Question: Decodable {
      var question: String
      var options: [String]?
      var is_multi_select: Bool?
    }
    var questions: [Question]
  }

  /// The paths of the files a process has open.
  private static func openFiles(_ pid: Int32) -> [String] {
    let size = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
    guard size > 0 else { return [] }
    var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(size) / MemoryLayout<proc_fdinfo>.stride)
    let filled = fds.withUnsafeMutableBytes { proc_pidinfo(pid, PROC_PIDLISTFDS, 0, $0.baseAddress, Int32($0.count)) }
    return fds.prefix(Int(filled) / MemoryLayout<proc_fdinfo>.stride).compactMap { fd in
      guard fd.proc_fdtype == UInt32(PROX_FDTYPE_VNODE) else { return nil }
      var info = vnode_fdinfowithpath()
      let infoSize = Int32(MemoryLayout<vnode_fdinfowithpath>.size)
      guard proc_pidfdinfo(pid, fd.proc_fd, PROC_PIDFDVNODEPATHINFO, &info, infoSize) == infoSize else { return nil }
      return withUnsafeBytes(of: info.pvip.vip_path) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) }
    }
  }

  /// The payload of the conversation's latest step.
  private static func latestStep(_ path: String) -> Data? {
    var db: OpaquePointer?
    defer { sqlite3_close(db) }
    guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { return nil }
    var statement: OpaquePointer?
    defer { sqlite3_finalize(statement) }
    guard sqlite3_prepare_v2(db, "SELECT step_payload FROM steps ORDER BY idx DESC LIMIT 1", -1, &statement, nil) == SQLITE_OK,
      sqlite3_step(statement) == SQLITE_ROW, let bytes = sqlite3_column_blob(statement, 0)
    else { return nil }
    return Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, 0)))
  }

  /// The JSON object embedded in binary data that starts with `prefix`, up to its closing brace.
  private static func jsonObject(in data: Data, startingWith prefix: String) -> Data? {
    guard let start = data.range(of: Data(prefix.utf8))?.lowerBound else { return nil }
    var depth = 0, inString = false, escaped = false
    for i in start..<data.endIndex {
      let byte = data[i]
      if inString {
        if escaped { escaped = false } else if byte == UInt8(ascii: "\\") { escaped = true } else if byte == UInt8(ascii: "\"") { inString = false }
      } else if byte == UInt8(ascii: "\"") {
        inString = true
      } else if byte == UInt8(ascii: "{") {
        depth += 1
      } else if byte == UInt8(ascii: "}") {
        depth -= 1
        if depth == 0 { return data[start...i] }
      }
    }
    return nil
  }

  // MARK: Helpers

  private static func read(_ url: URL, last count: UInt64) -> Data? {
    guard let handle = try? FileHandle(forReadingFrom: url), let end = try? handle.seekToEnd() else { return nil }
    try? handle.seek(toOffset: end > count ? end - count : 0)
    return try? handle.readToEnd()
  }

  /// Rex's status times ("2026-10-25T18:08:27.102916+01:00").
  private static func date(_ text: String) -> Date? {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let date = formatter.date(from: text) { return date }
    formatter.formatOptions = [.withInternetDateTime]
    return formatter.date(from: text.replacingOccurrences(of: #"\.\d+"#, with: "", options: .regularExpression))
  }
}

extension Rex {
  /// Answers Codex's or Antigravity's form, which shows one question at a time ("Question 1/3")
  /// and has no review screen, as tested on Codex 0.164.0 and Antigravity 1.4.7: an option's
  /// number picks it and moves on, and on the last question submits them all. On Antigravity
  /// numbers toggle a multi-select question's options and Enter moves on; its free text is the
  /// number after the options ("Write-in..."), the text and Enter. On Codex it is a note on "None
  /// of the above": Down to it, Tab, the text and Enter.
  static func answerOneByOne(_ row: Row, questions: PendingQuestions, answers: [QuestionAnswer]) throws {
    let qs = questions.questions
    guard let first = qs.first else { throw AnswerError.notWaiting }
    guard try waitsOnQuestion(row) else { throw AnswerError.notWaiting }
    let before = try screen(row)
    guard shows(before, first.question) else { throw AnswerError.notWaiting }
    guard before.contains("Question 1/\(qs.count)") else { throw AnswerError.notAtStart }

    for (q, a) in zip(qs, answers) {
      if let text = a.text {
        if questions.app == "codex" {
          for _ in q.options { try key(row, "down") }
          try key(row, "tab")
        } else {
          try key(row, "\(q.options.count + 1)")
        }
        try type(row, text)
        try key(row, "enter")
      } else if q.isMulti {
        for i in a.options ?? [] { try key(row, "\(i + 1)") }
        try key(row, "enter")
      } else {
        try key(row, "\((a.options ?? [0])[0] + 1)")
      }
    }

    Thread.sleep(forTimeInterval: 1.5)
    if try waitsOnQuestion(row) { throw AnswerError.stillWaiting }
  }
}
