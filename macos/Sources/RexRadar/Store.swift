import Foundation
import Combine
import WidgetKit

/// Reads every watcher's snapshot every couple of seconds.
@MainActor
final class Store: ObservableObject {
  static let shared = Store()

  @Published private(set) var rows: [Row] = []
  @Published private(set) var sources: [String] = []
  @Published private(set) var lastError: String?
  /// The last failed `open`, shown under the list.
  @Published var openError: String?
  /// The question list being answered in the panel or window, and what's picked so far.
  @Published private(set) var answering: (row: Row, draft: AnswerDraft)?

  func startAnswering(_ row: Row) {
    guard let questions = row.questions else { return }
    answering = (row, AnswerDraft(questions))
  }

  func stopAnswering() { answering = nil }

  /// The pane the skill picker is open for, in the panel or window.
  @Published var picking: Row?

  /// Whether the new-session form is open, in the panel or window.
  @Published var creatingSession = false

  /// Starts the agent in a new Rex session in the folder, and brings it up in Rex. Throws on failure.
  func newSession(_ agent: SkillAgent, directory: String, server: String?) async throws {
    let label = clientLabel
    try await Task.detached { try Rex.newSession(agent, directory: directory, server: server, clientLabel: label) }.value
    creatingSession = false
    Rex.activateApp()
    reload()
  }

  /// The skills the pane's agent offers: read from this Mac's disk for its working directory.
  func skills(for row: Row) async throws -> [Skill] {
    guard let agent = row.skillAgent, row.server == nil else { throw SkillError.unsupported }
    return try await Task.detached { SkillCatalog.skills(cwd: try Rex.workingDirectory(row), agent: agent) }.value
  }

  /// Types the skill into the pane, if its agent offers it there. Throws on refusal.
  func sendSkill(_ row: Row, _ request: SkillRequest) async throws {
    try request.validate()
    guard let agent = row.skillAgent else { throw SkillError.unsupported }
    guard try await skills(for: row).contains(where: { $0.name == request.name }) else {
      throw SkillError.unknown(agent.sigil + request.name)
    }
    try await Task.detached { try Rex.sendSkill(row, request, agent: agent) }.value
    if picking?.id == row.id { picking = nil }
    reload()
  }

  /// Allows or denies the permission the row's agent asks for (see Rex.decide). Throws on refusal.
  func decide(_ row: Row, _ decision: PermissionDecision, prompt: String) async throws {
    guard row.permission != nil else { throw PermissionError.notWaiting }
    try await Task.detached { try Rex.decide(row, decision, prompt: prompt) }.value
    reload()
  }

  /// The same from a button here: a refusal shows under the list, like a failed open.
  func decide(_ row: Row, _ decision: PermissionDecision) {
    guard let prompt = row.permission?.prompt else { return }
    openError = nil
    Task {
      do { try await decide(row, decision, prompt: prompt) } catch { openError = error.localizedDescription }
    }
  }

  /// Permission prompts read off the screen, by pane and status update, for agents that send no
  /// message (Codex): a pane's screen is read once per request, off the main thread.
  private var screenPrompts: [String: String] = [:]
  private var readingPrompts: Set<String> = []

  private func permission(for row: Row) -> PendingPermission? {
    let pane = row.pane
    guard pane.state == "blocked", pane.kind == "permission", let app = pane.app, PendingPermission.apps.contains(app)
    else { return nil }
    if let msg = pane.msg, !msg.isEmpty { return PendingPermission(prompt: msg) }
    let key = row.id + "@" + (pane.updatedAt ?? "")
    if let prompt = screenPrompts[key] { return prompt.isEmpty ? nil : PendingPermission(prompt: prompt) }
    if readingPrompts.insert(key).inserted {
      Task.detached { [weak self] in
        let prompt = (try? Rex.screen(row)).flatMap(PendingPermission.prompt(fromScreen:)) ?? ""
        await MainActor.run {
          self?.readingPrompts.remove(key)
          self?.screenPrompts[key] = prompt
          self?.reload()
        }
      }
    }
    return nil
  }

  /// Where the watchers, hooks and Pi's extension keep their files.
  nonisolated static let stateDirectory: URL = {
    if let dir = ProcessInfo.processInfo.environment["REX_RADAR_DIR"] { return URL(fileURLWithPath: dir) }
    return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/state/rex-radar")
  }()

  let directory = Store.stateDirectory

  private var task: Task<Void, Never>?

  init() {
    task = Task { [weak self] in
      while !Task.isCancelled {
        self?.reload()
        try? await Task.sleep(for: .seconds(2))
      }
    }
  }

  /// Closes the row's pane in Rex, ending its agent (see Rex.close). Throws on failure.
  func close(_ row: Row) async throws {
    try await Task.detached { try Rex.close(row) }.value
    if answering?.row.id == row.id { answering = nil }
    if picking?.id == row.id { picking = nil }
    reload()
  }

  /// The same from a button here: a failure shows under the list, like a failed open.
  func close(_ row: Row) {
    openError = nil
    Task {
      do { try await close(row) } catch { openError = error.localizedDescription }
    }
  }

  /// Done panes opened from here, by row and the status update they were opened at: they count
  /// as idle until the agent reports again.
  private var seenDone: [String: String] = [:]

  /// Done for long enough, or opened from here since: idle (see Row.doneFadesAfter).
  private func fadeDone(_ pane: inout Pane, id: String) {
    guard pane.state == "done" else { return }
    let opened = seenDone[id] == (pane.updatedAt ?? "")
    let old = Row(pane: pane, source: "", stale: false).since.map { Date().timeIntervalSince($0) > Row.doneFadesAfter } ?? false
    if opened || old { pane.state = "idle" }
  }

  /// Most urgent state among live panes, for the menu bar icon.
  var topState: AgentState? { rows.filter { !$0.stale }.map(\.state).min() }
  var attentionCount: Int { rows.filter { !$0.stale && $0.state.needsAttention }.count }

  /// The Rex app to switch: this Mac's, by its device name. Override with
  /// `defaults write <bundle id> clientLabel <label>` (house.milapan.rex-radar by default).
  var clientLabel: String { Preferences.shared.clientLabel }

  /// Shows the row's pane in the Rex app, off the main thread (it runs the rex CLI).
  func open(_ row: Row) {
    openError = nil
    if row.pane.state == "done" { seenDone[row.id] = row.pane.updatedAt ?? "" }
    let label = clientLabel
    Task.detached { [weak self] in
      do {
        try Rex.open(row, clientLabel: label)
        await MainActor.run { Rex.activateApp() }
      } catch {
        let message = error.localizedDescription
        await MainActor.run { self?.openError = message }
      }
    }
  }

  /// Opens the row a widget link names: rexradar://open?id=<row id>.
  func handle(_ url: URL) {
    guard url.scheme == "rexradar", url.host == "open",
      let id = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "id" })?.value
    else { return }
    reload()
    if let row = rows.first(where: { $0.id == id }) { open(row) }
  }

  /// The question list Claude's hook saved for a pane (Qoder runs it too), but only while Rex says
  /// the pane is waiting on a question: a cancelled list leaves its file behind. The hook runs on
  /// this Mac, so only this Mac's own Rex server has them.
  private func questions(for pane: Pane, server: String?) -> PendingQuestions? {
    guard server == nil, pane.state == "blocked", pane.kind == "question" else { return nil }
    let file = directory.appendingPathComponent("questions/\(pane.blockId).json")
    guard let data = try? Data(contentsOf: file) else { return nil }
    let decoder = JSONDecoder()
    decoder.keyDecodingStrategy = .convertFromSnakeCase
    guard var questions = try? decoder.decode(PendingQuestions.self, from: data) else { return nil }
    // The file doesn't say which agent asked; the pane does.
    if let app = pane.app, PendingQuestions.hookApps.contains(app) { questions.app = questions.app ?? app }
    return questions
  }

  /// Question lists read from Codex's and Antigravity's own records (AgentQuestions), by pane
  /// and status update: read once per question, off the main thread, and again after 5 s while
  /// nothing is found.
  private var agentQuestions: [String: PendingQuestions] = [:]
  private var readingQuestions: Set<String> = []

  private func agentQuestions(for row: Row) -> PendingQuestions? {
    let pane = row.pane
    guard row.server == nil, !row.stale, pane.state == "blocked", pane.kind == "question", let app = pane.app,
      !PendingQuestions.hookApps.contains(app), PendingQuestions.apps.contains(app)
    else { return nil }
    let key = row.id + "@" + (pane.updatedAt ?? "")
    if let questions = agentQuestions[key] { return questions }
    if readingQuestions.insert(key).inserted {
      Task.detached { [weak self] in
        let questions = AgentQuestions.load(row)
        if questions == nil { try? await Task.sleep(for: .seconds(5)) }
        await MainActor.run {
          self?.readingQuestions.remove(key)
          guard let questions else { return }
          self?.agentQuestions[key] = questions
          self?.reload()
        }
      }
    }
    return nil
  }

  /// Answers the question list in a pane by typing into it (see Rex.answer). Throws on refusal.
  func answer(_ row: Row, _ answers: [QuestionAnswer]) async throws {
    guard let questions = row.questions else { throw AnswerError.notWaiting }
    try questions.validate(answers)
    try await Task.detached { try Rex.answer(row, questions: questions, answers: answers) }.value
    if answering?.row.id == row.id { answering = nil }
    reload()
  }

  func reload() {
    let decoder = JSONDecoder()
    decoder.keyDecodingStrategy = .convertFromSnakeCase
    decoder.dateDecodingStrategy = .iso8601

    let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
    var rows: [Row] = []
    var sources: [String] = []
    var errors: [String] = []
    for file in files where file.pathExtension == "json" {
      do {
        let s = try decoder.decode(Snapshot.self, from: Data(contentsOf: file))
        let stale = Date().timeIntervalSince(s.writtenAt) > 2 * s.heartbeatSeconds
        sources.append(s.source)
        rows += s.panes.map {
          var pane = $0
          if s.server == nil, let cwd = pane.cwd { pane.branch = GitBranch.of(cwd) }
          fadeDone(&pane, id: s.source + "/" + pane.blockId)
          var row = Row(pane: pane, source: s.source, server: s.server, stale: stale, questions: questions(for: pane, server: s.server))
          row.permission = stale ? nil : permission(for: row)
          if row.questions == nil { row.questions = agentQuestions(for: row) }
          return row
        }
      } catch {
        errors.append("\(file.lastPathComponent): \(error.localizedDescription)")
      }
    }
    self.rows = rows.sorted(by: Row.byUrgency)
    let live = Set(rows.map { $0.id + "@" + ($0.pane.updatedAt ?? "") })
    screenPrompts = screenPrompts.filter { live.contains($0.key) }
    seenDone = seenDone.filter { live.contains($0.key + "@" + $0.value) }
    agentQuestions = agentQuestions.filter { live.contains($0.key) }
    self.sources = sources.sorted()
    self.lastError = errors.first
    // Hand the rows to the widget, and wake it only when they changed.
    if SharedState.write(self.rows) { WidgetCenter.shared.reloadAllTimelines() }
  }
}
