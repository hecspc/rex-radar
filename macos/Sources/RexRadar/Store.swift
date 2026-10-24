import Foundation
import Combine

/// Reads every watcher's snapshot every couple of seconds.
@MainActor
final class Store: ObservableObject {
  @Published private(set) var rows: [Row] = []
  @Published private(set) var sources: [String] = []
  @Published private(set) var lastError: String?
  /// The last failed `open`, shown under the list.
  @Published var openError: String?

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
  /// `defaults write house.milapan.rex-radar clientLabel <label>`.
  var clientLabel: String {
    UserDefaults.standard.string(forKey: "clientLabel") ?? Host.current().localizedName ?? ""
  }

  /// Shows the row's pane in the Rex app, off the main thread (it runs the rex CLI).
  func open(_ row: Row) {
    openError = nil
    let label = clientLabel
    Task.detached { [weak self] in
      do {
        try Rex.open(row, clientLabel: label)
      } catch {
        let message = error.localizedDescription
        await MainActor.run { self?.openError = message }
      }
    }
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
        rows += s.panes.map { Row(pane: $0, source: s.source, server: s.server, stale: stale) }
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
  }
}
