import Foundation
import Observation
import Security

#if canImport(WidgetKit)
  import WidgetKit
#endif

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
  /// Per Mac: whether it lets this device answer agents' questions (its Settings).
  private(set) var answeringByHub: [UUID: Bool] = [:]
  /// Per Mac: whether it lets this device send skills to agents (its Settings).
  private(set) var skillsByHub: [UUID: Bool] = [:]
  /// Per Mac: whether it lets this device allow or deny agents' permissions (its Settings).
  private(set) var permissionsByHub: [UUID: Bool] = [:]
  /// Per Mac that lets this device start sessions (its Settings): the Rex servers it can start them on.
  private(set) var sessionServersByHub: [UUID: [String]] = [:]
  private(set) var errors: [UUID: String] = [:]
  private(set) var updated: Date?
  /// Shown briefly after a tap: "Opened on my-mac".
  var notice: String?
  /// When each Mac was last looked up over Bonjour, so an unreachable one isn't browsed for every poll.
  @ObservationIgnored private var relocatedAt: [UUID: Date] = [:]

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

  /// The Apple Watch app's pairing: mirrors the Macs the iPhone sent, main one included.
  func sync(_ shared: WidgetHubs) {
    var updated: [Hub] = []
    for entry in shared.hubs {
      var hub = Hub(name: entry.name, host: entry.host, port: entry.port)
      if let existing = hubs.first(where: { $0.name == entry.name }) { hub.id = existing.id }
      Keychain.write(entry.token, for: hub.id)
      updated.append(hub)
    }
    for gone in hubs where !updated.contains(where: { $0.id == gone.id }) { Keychain.write(nil, for: gone.id) }
    hubs = updated
    mainID = zip(shared.hubs, updated).first { $0.0.isMain }?.1.id ?? updated.first?.id
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
    sessionServersByHub[hub.id] = nil
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
      for await (id, result) in group { record(result, for: id) }
    }
    #if !os(watchOS)
      for id in unreachable { await relocate(id) }
    #endif
    updated = Date()
    shareWithWidget()
  }

  /// Macs whose last request didn't get through at all (no answer, not a refusal).
  @ObservationIgnored private var unreachable: Set<UUID> = []

  private func record(_ result: Result<AgentsResponse, Error>, for id: UUID) {
    unreachable.remove(id)
    switch result {
    case .success(let response):
      agentsByHub[id] = response.rows
      answeringByHub[id] = response.answering ?? false
      skillsByHub[id] = response.skills ?? false
      permissionsByHub[id] = response.permissions ?? false
      sessionServersByHub[id] = response.sessions == true ? (response.servers ?? []) : nil
      errors[id] = nil
    case .failure(let error):
      errors[id] = error.localizedDescription
      if error is URLError { unreachable.insert(id) }
    }
  }

  #if !os(watchOS)
    /// A Mac that stopped answering at its saved address may have another one now (Wi-Fi and
    /// Ethernet each get their own, or a new DHCP lease): finds it by its Bonjour name and moves
    /// the pairing there. The watch gets the new address from the iPhone.
    private func relocate(_ id: UUID) async {
      guard let hub = hubs.first(where: { $0.id == id }), Bonjour.canRelocate(hub.host),
        Date().timeIntervalSince(relocatedAt[id] ?? .distantPast) > 30
      else { return }
      relocatedAt[id] = Date()
      guard let (host, port) = await Bonjour.locate(name: hub.name), host != hub.host || port != hub.port,
        Bonjour.canRelocate(host), let i = hubs.firstIndex(where: { $0.id == id })
      else { return }
      hubs[i].host = host
      hubs[i].port = port
      save()
      record(await Self.fetch(hubs[i], token: Keychain.read(for: id)), for: id)
    }
  #endif

  /// Hands the paired Macs and the current agents to the widget; wakes it only on a change.
  private func shareWithWidget() {
    let entries = hubs.compactMap { hub -> WidgetHubs.Entry? in
      guard let token = Keychain.read(for: hub.id) else { return nil }
      return .init(name: hub.name, host: hub.host, port: hub.port, token: token, isMain: hub.id == main?.id)
    }
    let shared = WidgetHubs(hubs: entries)
    let hubsChanged = WidgetHubs.write(shared)
    #if os(iOS)
      if hubsChanged { WatchSync.shared.send(shared) }
    #endif
    let rowsChanged = SharedState.write(agents.map(\.row))
    #if canImport(WidgetKit)
      if hubsChanged || rowsChanged { WidgetCenter.shared.reloadAllTimelines() }
    #endif
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

  // MARK: Answering

  /// Whether this agent's questions can be answered from here: its Mac (where the questions hook
  /// ran) allows it.
  func canAnswer(_ agent: Agent) -> Bool { agent.row.questions != nil && (answeringByHub[agent.hubID] ?? false) }

  /// Sends the answers to the Mac that reported the agent; it types them into the agent's form.
  func answer(_ agent: Agent, _ answers: [QuestionAnswer]) async throws {
    guard let hub = hubs.first(where: { $0.id == agent.hubID }), let base = hub.base,
      var c = URLComponents(url: base.appending(path: "v1/answer"), resolvingAgainstBaseURL: false)
    else { throw HubError.notFound }
    c.queryItems = [URLQueryItem(name: "id", value: agent.row.id)]
    guard let url = c.url else { throw HubError.notFound }
    _ = try await Self.request(url, method: "POST", token: Keychain.read(for: hub.id), body: try JSONEncoder().encode(answers))
    notice = "Answered on \(hub.name)"
    await refresh()
    try? await Task.sleep(for: .seconds(2.5))
    notice = nil
  }

  // MARK: Permissions

  /// Whether this agent's permission prompt can be allowed or denied from here: its Mac read it
  /// and allows it.
  func canDecide(_ agent: Agent) -> Bool { agent.row.permission != nil && (permissionsByHub[agent.hubID] ?? false) }

  /// Asks the agent's Mac to allow or deny the permission this device showed. A refusal (it asks
  /// something else now, or Settings is off) shows as the notice.
  func decide(_ agent: Agent, _ decision: PermissionDecision) {
    guard let prompt = agent.row.permission?.prompt else { return }
    Task {
      do {
        let (url, token) = try endpoint("v1/permission", agent)
        let body = try JSONEncoder().encode(PermissionReply(decision: decision, prompt: prompt))
        _ = try await Self.request(url, method: "POST", token: token, body: body)
        notice = decision == .allow ? "Allowed on \(agent.hubName)" : "Denied on \(agent.hubName)"
      } catch {
        notice = "Couldn't \(decision.rawValue): \(error.localizedDescription)"
      }
      await refresh()
      try? await Task.sleep(for: .seconds(2.5))
      notice = nil
    }
  }

  // MARK: Skills

  /// Whether a skill can be sent to this agent from here: Claude Code, Codex, Antigravity or Qoder
  /// on its Mac's own Rex, and that Mac allows it.
  func canSendSkill(_ agent: Agent) -> Bool { agent.row.takesSkills && (skillsByHub[agent.hubID] ?? false) }

  /// The skills the agent offers in its pane, as its Mac reads them.
  func skills(_ agent: Agent) async throws -> [Skill] {
    let (url, token) = try endpoint("v1/skills", agent)
    return try JSONDecoder().decode([Skill].self, from: try await Self.request(url, method: "GET", token: token, body: nil))
  }

  /// Asks the agent's Mac to type the skill into its pane.
  func sendSkill(_ agent: Agent, _ request: SkillRequest) async throws {
    let (url, token) = try endpoint("v1/skill", agent)
    _ = try await Self.request(url, method: "POST", token: token, body: try JSONEncoder().encode(request))
    notice = "Sent /\(request.name) on \(agent.hubName)"
    Task {
      await refresh()
      try? await Task.sleep(for: .seconds(2.5))
      notice = nil
    }
  }

  // MARK: New sessions

  /// The Macs that let this device start sessions, main one first.
  var sessionHubs: [Hub] {
    let allowing = hubs.filter { sessionServersByHub[$0.id] != nil }
    return allowing.filter { $0.id == main?.id } + allowing.filter { $0.id != main?.id }
  }

  /// Asks the Mac to start the agent in a new Rex session; it shows the session in its Rex.
  func newSession(on hub: Hub, _ request: NewSessionRequest) async throws {
    guard let url = hub.base?.appending(path: "v1/session") else { throw HubError.notFound }
    _ = try await Self.request(url, method: "POST", token: Keychain.read(for: hub.id), body: try JSONEncoder().encode(request))
    notice = "Started \(Pane.appLabel(request.agent)) on \(hub.name)"
    Task {
      try? await Task.sleep(for: .seconds(1))
      await refresh()
      try? await Task.sleep(for: .seconds(1.5))
      notice = nil
    }
  }

  /// `<path>?id=<row>` on the Mac that reported the agent, and its token.
  private func endpoint(_ path: String, _ agent: Agent) throws -> (URL, String?) {
    guard let hub = hubs.first(where: { $0.id == agent.hubID }), let base = hub.base,
      var c = URLComponents(url: base.appending(path: path), resolvingAgainstBaseURL: false)
    else { throw HubError.notFound }
    c.queryItems = [URLQueryItem(name: "id", value: agent.row.id)]
    guard let url = c.url else { throw HubError.notFound }
    return (url, Keychain.read(for: hub.id))
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
    default:
      let message = (try? JSONSerialization.jsonObject(with: data) as? [String: String])?["error"]
      throw message.map(HubError.refused) ?? HubError.status(status)
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
  case unauthorized, notFound, status(Int), refused(String)
  var errorDescription: String? {
    switch self {
    case .unauthorized: "The Mac refused the pairing. Pair it again."
    case .notFound: "That Mac doesn't know this agent."
    case .status(let code): "The Mac answered \(code)."
    case .refused(let message): message
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
