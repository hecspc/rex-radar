import Foundation
import Observation
import Security
import WidgetKit

/// A Mac running Rex Radar that this device is paired with.
struct Hub: Codable, Equatable, Identifiable {
  var id = UUID()
  var name: String
  var host: String
  var port: Int
  var base: URL? { URL(string: "http://\(host):\(port)") }
}

/// An agent as this device sees it: which Mac reported it, and the row.
struct Agent: Identifiable, Hashable {
  var hubID: UUID
  var hubName: String
  var row: Row
  var id: String { hubID.uuidString + "|" + row.id }
  /// The Rex server, told apart across Macs: two Macs can each have a local server called "mac".
  var serverKey: String { row.server ?? "\(hubName)/\(row.source)" }
  var serverLabel: String { row.server == nil ? "\(row.source) · \(hubName)" : row.source }
}

@MainActor @Observable
final class HubClient {
  private(set) var hubs: [Hub] = []
  private(set) var mainID: UUID?
  private(set) var agentsByHub: [UUID: [Row]] = [:]
  private(set) var errors: [UUID: String] = [:]
  private(set) var updated: Date?
  /// Shown briefly after a tap: "Opened on vv-macbook".
  var notice: String?

  init() {
    load()
    // For simulators and tests: `SIMCTL_CHILD_REXRADAR_PAIR='rexradar://pair?… rexradar://pair?…' xcrun simctl launch …`.
    for link in (ProcessInfo.processInfo.environment["REXRADAR_PAIR"] ?? "").split(separator: " ") {
      if let url = URL(string: String(link)) { pair(with: url) }
    }
  }

  var main: Hub? { hubs.first { $0.id == mainID } ?? hubs.first }

  /// Every agent from every Mac, most urgent first. When two Macs watch the same Rex server,
  /// the main Mac's copy wins.
  var agents: [Agent] {
    var seen = Set<String>()
    var result: [Agent] = []
    let mainFirst = hubs.filter { $0.id == main?.id } + hubs.filter { $0.id != main?.id }
    for hub in mainFirst {
      for row in agentsByHub[hub.id] ?? [] {
        let agent = Agent(hubID: hub.id, hubName: hub.name, row: row)
        if seen.insert(agent.serverKey + "|" + row.pane.blockId).inserted { result.append(agent) }
      }
    }
    return result.sorted { a, b in
      if a.row.stale != b.row.stale { return !a.row.stale }
      if a.row.state != b.row.state { return a.row.state < b.row.state }
      return (a.row.pane.session ?? "") < (b.row.pane.session ?? "")
    }
  }

  var servers: [(key: String, label: String)] {
    var seen = Set<String>()
    return agents.compactMap { seen.insert($0.serverKey).inserted ? ($0.serverKey, $0.serverLabel) : nil }
      .sorted { $0.label < $1.label }
  }

  var attentionCount: Int { agents.filter { !$0.row.stale && $0.row.state.needsAttention }.count }

  // MARK: Pairing

  /// rexradar://pair?host=…&port=…&token=…&name=…, from the QR code in the Mac app.
  @discardableResult
  func pair(with url: URL) -> Bool {
    guard url.scheme == "rexradar", url.host == "pair",
      let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems
    else { return false }
    func value(_ name: String) -> String? { items.first { $0.name == name }?.value }
    guard let host = value("host"), let token = value("token") else { return false }
    pair(host: host, port: Int(value("port") ?? "") ?? 7298, token: token, name: value("name") ?? host)
    return true
  }

  /// Adds a Mac, or updates it when one with the same name (or address) is already paired.
  /// The first Mac becomes the main one.
  func pair(host: String, port: Int, token: String, name: String) {
    var hub = Hub(name: name, host: host, port: port)
    if let i = hubs.firstIndex(where: { $0.name == name || ($0.host == host && $0.port == port) }) {
      hub.id = hubs[i].id
      hubs[i] = hub
    } else {
      hubs.append(hub)
    }
    if mainID == nil { mainID = hub.id }
    Keychain.write(token, for: hub.id)
    save()
    Task { await refresh() }
  }

  func setMain(_ hub: Hub) {
    mainID = hub.id
    save()
  }

  func unpair(_ hub: Hub) {
    defer { shareWithWidget() }
    hubs.removeAll { $0.id == hub.id }
    agentsByHub[hub.id] = nil
    errors[hub.id] = nil
    Keychain.write(nil, for: hub.id)
    if mainID == hub.id { mainID = hubs.first?.id }
    save()
  }

  // MARK: Fetching

  func refresh() async {
    let hubs = hubs
    let tokens = Dictionary(uniqueKeysWithValues: hubs.map { ($0.id, Keychain.read(for: $0.id)) })
    await withTaskGroup(of: (UUID, Result<AgentsResponse, Error>).self) { group in
      for hub in hubs {
        let token = tokens[hub.id] ?? nil
        group.addTask { (hub.id, await Self.fetch(hub, token: token)) }
      }
      for await (id, result) in group {
        switch result {
        case .success(let response):
          agentsByHub[id] = response.rows
          errors[id] = nil
        case .failure(let error):
          errors[id] = error.localizedDescription
        }
      }
    }
    updated = Date()
    shareWithWidget()
  }

  /// Hands the paired Macs and the current agents to the widget; wakes it only on a change.
  private func shareWithWidget() {
    let entries = hubs.compactMap { hub -> WidgetHubs.Entry? in
      guard let token = Keychain.read(for: hub.id) else { return nil }
      return .init(name: hub.name, host: hub.host, port: hub.port, token: token, isMain: hub.id == main?.id)
    }
    let hubsChanged = WidgetHubs.write(WidgetHubs(hubs: entries))
    let rowsChanged = SharedState.write(agents.map(\.row))
    if hubsChanged || rowsChanged { WidgetCenter.shared.reloadAllTimelines() }
  }

  /// rexradar:// links: pairing from the Mac's QR code, or opening an agent from the widget.
  func handle(_ url: URL) {
    if pair(with: url) { return }
    guard url.scheme == "rexradar", url.host == "open",
      let id = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "id" })?.value
    else { return }
    Task {
      if agents.isEmpty { await refresh() }
      if let agent = agents.first(where: { $0.row.id == id }) { open(agent) }
    }
  }

  /// Polls while the app is on screen; the caller cancels the task when it goes to the background.
  func poll() async {
    while !Task.isCancelled {
      await refresh()
      try? await Task.sleep(for: .seconds(4))
    }
  }

  private nonisolated static func fetch(_ hub: Hub, token: String?) async -> Result<AgentsResponse, Error> {
    guard let base = hub.base else { return .failure(HubError.status(0)) }
    do {
      let data = try await request(base.appending(path: "v1/agents"), method: "GET", token: token, body: nil)
      let decoder = JSONDecoder()
      decoder.dateDecodingStrategy = .iso8601
      return .success(try decoder.decode(AgentsResponse.self, from: data))
    } catch {
      return .failure(error)
    }
  }

  // MARK: Opening

  /// Opens the agent in Rex on the main Mac when it can reach the agent's server (a remote server,
  /// known by address); an agent on another Mac's own Rex opens on that Mac instead.
  func open(_ agent: Agent) {
    guard let main else { return }
    let target: Hub
    var body: Data?
    if agent.hubID == main.id {
      target = main
    } else if agent.row.server != nil {
      target = main
      let encoder = JSONEncoder()
      encoder.dateEncodingStrategy = .iso8601
      body = try? encoder.encode(agent.row)
    } else {
      target = hubs.first { $0.id == agent.hubID } ?? main
    }
    guard let base = target.base,
      var c = URLComponents(url: base.appending(path: "v1/open"), resolvingAgainstBaseURL: false)
    else { return }
    c.queryItems = [URLQueryItem(name: "id", value: agent.row.id)]
    guard let url = c.url else { return }
    let token = Keychain.read(for: target.id)
    Task {
      do {
        _ = try await Self.request(url, method: "POST", token: token, body: body)
        notice = "Opened on \(target.name)"
      } catch {
        notice = "Couldn't open on \(target.name): \(error.localizedDescription)"
      }
      try? await Task.sleep(for: .seconds(2.5))
      notice = nil
    }
  }

  private nonisolated static func request(_ url: URL, method: String, token: String?, body: Data?) async throws -> Data {
    var request = URLRequest(url: url, timeoutInterval: 6)
    request.httpMethod = method
    if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
    if let body {
      request.httpBody = body
      request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    }
    let (data, response) = try await URLSession.shared.data(for: request)
    let status = (response as? HTTPURLResponse)?.statusCode ?? 0
    switch status {
    case 200: return data
    case 401: throw HubError.unauthorized
    case 404: throw HubError.notFound
    default: throw HubError.status(status)
    }
  }

  // MARK: Storage

  private func save() {
    UserDefaults.standard.set(try? JSONEncoder().encode(hubs), forKey: "hubs")
    UserDefaults.standard.set(mainID?.uuidString, forKey: "mainHub")
  }

  private func load() {
    let defaults = UserDefaults.standard
    if let data = defaults.data(forKey: "hubs"), let saved = try? JSONDecoder().decode([Hub].self, from: data) {
      hubs = saved
      mainID = defaults.string(forKey: "mainHub").flatMap(UUID.init)
    } else if let data = defaults.data(forKey: "hub"),
      let old = try? JSONDecoder().decode(LegacyHub.self, from: data)
    {
      // Single-Mac pairing from before: it becomes the main Mac.
      let hub = Hub(name: old.name, host: old.host, port: old.port)
      hubs = [hub]
      mainID = hub.id
      Keychain.write(Keychain.readLegacy(), for: hub.id)
      defaults.removeObject(forKey: "hub")
      save()
    }
  }

  private struct LegacyHub: Codable {
    var name: String
    var host: String
    var port: Int
  }
}

enum HubError: LocalizedError {
  case unauthorized, notFound, status(Int)
  var errorDescription: String? {
    switch self {
    case .unauthorized: "The Mac refused the pairing. Scan its code again."
    case .notFound: "That Mac doesn't know this agent."
    case .status(let code): "The Mac answered \(code)."
    }
  }
}

/// Hub tokens, one per paired Mac, in the Keychain rather than UserDefaults.
enum Keychain {
  private static func query(_ account: String) -> [String: Any] {
    [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: "house.milapan.rex-radar.hub",
      kSecAttrAccount as String: account,
    ]
  }

  static func read(for hub: UUID) -> String? { read(account: hub.uuidString) }
  static func readLegacy() -> String? { read(account: "token") }

  static func write(_ value: String?, for hub: UUID) {
    let q = query(hub.uuidString)
    SecItemDelete(q as CFDictionary)
    guard let value else { return }
    var add = q
    add[kSecValueData as String] = Data(value.utf8)
    add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
    SecItemAdd(add as CFDictionary, nil)
  }

  private static func read(account: String) -> String? {
    var q = query(account)
    q[kSecReturnData as String] = true
    var out: CFTypeRef?
    guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
    return String(data: data, encoding: .utf8)
  }
}
