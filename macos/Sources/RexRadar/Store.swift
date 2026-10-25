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

  /// The skills Claude offers in the pane: read from this Mac's disk for its working directory.
  func skills(for row: Row) async throws -> [Skill] {
    guard row.pane.app == "claude-code", row.server == nil else { throw SkillError.notClaude }
    return try await Task.detached { SkillCatalog.skills(cwd: try Rex.workingDirectory(row)) }.value
  }

  /// Types the skill into the pane, if Claude offers it there. Throws on refusal.
  func sendSkill(_ row: Row, _ request: SkillRequest) async throws {
    try request.validate()
    guard try await skills(for: row).contains(where: { $0.name == request.name }) else {
      throw SkillError.unknown(request.name)
    }
    try await Task.detached { try Rex.sendSkill(row, request) }.value
    if picking?.id == row.id { picking = nil }
    reload()
  }

  let directory: URL = {
    if let dir = ProcessInfo.processInfo.environment["REX_RADAR_DIR"] { return URL(fileURLWithPath: dir) }
    return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/state/rex-radar")
  }()

  private var task: Task<Void, Never>?

  init() {
    task = Task { [weak self] in
      while !Task.isCancelled {
        self?.reload()
        try? await Task.sleep(for: .seconds(2))
      }
    }
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

  /// The question list the hook saved for a pane, but only while Rex says the pane is waiting on
  /// a question: a cancelled list leaves its file behind. The hook runs on this Mac, so only this
  /// Mac's own Rex server has them.
  private func questions(for pane: Pane, server: String?) -> PendingQuestions? {
    guard server == nil, pane.state == "blocked", pane.kind == "question" else { return nil }
    let file = directory.appendingPathComponent("questions/\(pane.blockId).json")
    guard let data = try? Data(contentsOf: file) else { return nil }
    let decoder = JSONDecoder()
    decoder.keyDecodingStrategy = .convertFromSnakeCase
    return try? decoder.decode(PendingQuestions.self, from: data)
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
          Row(pane: $0, source: s.source, server: s.server, stale: stale, questions: questions(for: $0, server: s.server))
        }
      } catch {
        errors.append("\(file.lastPathComponent): \(error.localizedDescription)")
      }
    }
    self.rows = rows.sorted { a, b in
      if a.stale != b.stale { return !a.stale }
      if a.state != b.state { return a.state < b.state }
      if a.source != b.source { return a.source < b.source }
      if a.pane.session != b.pane.session { return (a.pane.session ?? "") < (b.pane.session ?? "") }
      return (a.pane.tabIndex ?? 0) < (b.pane.tabIndex ?? 0)
    }
    self.sources = sources.sorted()
    self.lastError = errors.first
    // Hand the rows to the widget, and wake it only when they changed.
    if SharedState.write(self.rows) { WidgetCenter.shared.reloadAllTimelines() }
  }
}
