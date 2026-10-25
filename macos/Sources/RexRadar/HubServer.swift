import Foundation
import Network

/// Serves the merged agent rows to Rex Radar on iPhone and iPad, and opens the pane they tap here,
/// in this Mac's Rex app: the main server is the Mac this app runs on.
///
///   GET  /v1/agents          → { host, sources, rows, written_at }
///   POST /v1/answer?id=<row> → answers its question list (body: [QuestionAnswer]); only when
///                              Settings allows it, refused otherwise
///   GET  /v1/skills?id=<row> → the skills Claude offers in that pane ([Skill])
///   POST /v1/skill?id=<row>  → types one into it (body: SkillRequest); both only when Settings
///                              allows it
///   POST /v1/open?id=<row>   → shows that pane in Rex here (body: the row, for agents another Mac
///                              watches on a server this Mac reaches by address)
///   POST /v1/pair            → a device without a camera (Apple TV) asks to pair (body:
///                              PairRequestBody) → PairTicket
///   GET  /v1/pair?id=<id>    → PairStatus: the token once someone allows it on the Devices page
///
/// Every other request needs `Authorization: Bearer <token>`; the token is generated once and
/// shown, with a pairing QR code, in the window. Advertised over Bonjour as _rexradar._tcp.
@MainActor
final class HubServer: ObservableObject {
  static let shared = HubServer(store: .shared)
  static let port: UInt16 = 7298
  static let serviceType = "_rexradar._tcp"

  @Published private(set) var state = "stopped"
  /// Devices asking to pair, shown on the Devices page until someone allows or denies them.
  @Published private(set) var pairRequests: [PairRequest] = []
  let token: String
  private var listener: NWListener?
  private let store: Store

  init(store: Store) {
    self.store = store
    if let saved = UserDefaults.standard.string(forKey: "hubToken"), saved.count >= 32 {
      token = saved
    } else {
      var bytes = [UInt8](repeating: 0, count: 24)
      _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
      token = Data(bytes).base64EncodedString()
        .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
      UserDefaults.standard.set(token, forKey: "hubToken")
    }
  }

  var hostName: String { Host.current().localizedName ?? "Mac" }

  func start() {
    guard listener == nil else { return }
    do {
      let listener = try NWListener(using: .tcp, on: NWEndpoint.Port(rawValue: Self.port)!)
      listener.service = NWListener.Service(name: hostName, type: Self.serviceType)
      listener.stateUpdateHandler = { [weak self] state in
        Task { @MainActor in self?.state = "\(state)" }
      }
      listener.newConnectionHandler = { [weak self] connection in
        Task { @MainActor in self?.serve(connection) }
      }
      listener.start(queue: .main)
      self.listener = listener
    } catch {
      state = "failed: \(error.localizedDescription)"
    }
  }

  // MARK: HTTP, just enough of it

  private func serve(_ connection: NWConnection) {
    connection.start(queue: .main)
    receive(connection, buffer: Data())
  }

  private func receive(_ connection: NWConnection, buffer: Data) {
    connection.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) { [weak self] data, _, done, error in
      Task { @MainActor in
        guard let self else { return }
        var buffer = buffer
        if let data { buffer.append(data) }
        if let end = buffer.range(of: Data("\r\n\r\n".utf8)) {
          let head = String(decoding: buffer[..<end.lowerBound], as: UTF8.self)
          let length = head.components(separatedBy: "\r\n")
            .first { $0.lowercased().hasPrefix("content-length:") }
            .flatMap { Int($0.dropFirst("content-length:".count).trimmingCharacters(in: .whitespaces)) } ?? 0
          let body = buffer[end.upperBound...]
          if body.count >= min(length, 64 * 1024) || done || error != nil {
            self.respond(to: head, body: Data(body.prefix(length)), on: connection)
          } else {
            self.receive(connection, buffer: buffer)
          }
        } else if done || error != nil || buffer.count > 16 * 1024 {
          connection.cancel()
        } else {
          self.receive(connection, buffer: buffer)
        }
      }
    }
  }

  private func respond(to head: String, body: Data, on connection: NWConnection) {
    let lines = head.components(separatedBy: "\r\n")
    let parts = (lines.first ?? "").split(separator: " ")
    guard parts.count >= 2 else { return send(connection, 400, ["error": "bad request"]) }
    let method = String(parts[0])
    let target = URLComponents(string: String(parts[1]))
    if target?.path == "/v1/pair" { return pairing(method, target, body, on: connection) }
    let auth = lines.dropFirst().first { $0.lowercased().hasPrefix("authorization:") }
      .map { $0.dropFirst("authorization:".count).trimmingCharacters(in: .whitespaces) }
    guard let auth, constantTimeEqual(auth, "Bearer \(token)") else {
      return send(connection, 401, ["error": "unauthorized"])
    }

    switch (method, target?.path) {
    case ("GET", "/v1/agents"):
      store.reload()
      let body = AgentsResponse(
        host: hostName, sources: store.sources, rows: store.rows, writtenAt: Date(),
        answering: Preferences.shared.allowPhoneAnswers, skills: Preferences.shared.allowPhoneSkills)
      send(connection, 200, body)
    case ("POST", "/v1/open"):
      let id = target?.queryItems?.first { $0.name == "id" }?.value
      store.reload()
      if let row = store.rows.first(where: { $0.id == id }) {
        store.open(row)
        return send(connection, 200, ["ok": "true"])
      }
      // An agent another Mac watches, on a Rex server this Mac can reach too (it has an address):
      // the phone sends the whole row so this Mac, the main one, opens it in its own Rex.
      let decoder = JSONDecoder()
      decoder.dateDecodingStrategy = .iso8601
      if let row = try? decoder.decode(Row.self, from: body), let server = row.server, !server.isEmpty {
        store.open(row)
        return send(connection, 200, ["ok": "true"])
      }
      send(connection, 404, ["error": "no such agent"])
    case ("POST", "/v1/answer"):
      guard Preferences.shared.allowPhoneAnswers else {
        return send(connection, 403, ["error": "Answering from iPhone & iPad is off in Rex Radar's Settings on this Mac."])
      }
      let id = target?.queryItems?.first { $0.name == "id" }?.value
      store.reload()
      guard let row = store.rows.first(where: { $0.id == id }) else {
        return send(connection, 404, ["error": "no such agent"])
      }
      guard let answers = try? JSONDecoder().decode([QuestionAnswer].self, from: body) else {
        return send(connection, 400, ["error": "bad answers"])
      }
      Task {
        do {
          try await store.answer(row, answers)
          send(connection, 200, ["ok": "true"])
        } catch {
          send(connection, 409, ["error": error.localizedDescription])
        }
      }
    case ("GET", "/v1/skills"), ("POST", "/v1/skill"):
      guard Preferences.shared.allowPhoneSkills else {
        return send(connection, 403, ["error": "Sending skills from iPhone & iPad is off in Rex Radar's Settings on this Mac."])
      }
      let id = target?.queryItems?.first { $0.name == "id" }?.value
      store.reload()
      guard let row = store.rows.first(where: { $0.id == id }) else {
        return send(connection, 404, ["error": "no such agent"])
      }
      if method == "GET" {
        Task {
          do { send(connection, 200, try await store.skills(for: row)) } catch {
            send(connection, 409, ["error": error.localizedDescription])
          }
        }
        return
      }
      guard let request = try? JSONDecoder().decode(SkillRequest.self, from: body) else {
        return send(connection, 400, ["error": "bad skill"])
      }
      Task {
        do {
          try await store.sendSkill(row, request)
          send(connection, 200, ["ok": "true"])
        } catch {
          send(connection, 409, ["error": error.localizedDescription])
        }
      }
    default:
      send(connection, 404, ["error": "not found"])
    }
  }

  private func send<T: Encodable>(_ connection: NWConnection, _ status: Int, _ body: T) {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    let json = (try? encoder.encode(body)) ?? Data("{}".utf8)
    let reasons = [
      200: "OK", 400: "Bad Request", 401: "Unauthorized", 403: "Forbidden", 404: "Not Found", 409: "Conflict",
      429: "Too Many Requests",
    ]
    let reason = reasons[status] ?? "Error"
    var response = Data(
      "HTTP/1.1 \(status) \(reason)\r\nContent-Type: application/json\r\nContent-Length: \(json.count)\r\nConnection: close\r\n\r\n".utf8)
    response.append(json)
    connection.send(content: response, completion: .contentProcessed { _ in connection.cancel() })
  }

  private func constantTimeEqual(_ a: String, _ b: String) -> Bool {
    let a = Array(a.utf8), b = Array(b.utf8)
    guard a.count == b.count else { return false }
    return zip(a, b).reduce(0) { $0 | ($1.0 ^ $1.1) } == 0
  }

  // MARK: Pairing

  /// A device that asked to pair. `allowed` is nil until someone decides on the Devices page.
  struct PairRequest: Identifiable, Equatable {
    let id: String
    let name: String
    let code: String
    let created = Date()
    var allowed: Bool?
  }

  var waitingPairRequests: [PairRequest] { pairRequests.filter { $0.allowed == nil } }

  func decide(_ request: PairRequest, allow: Bool) {
    guard let i = pairRequests.firstIndex(where: { $0.id == request.id }) else { return }
    pairRequests[i].allowed = allow
  }

  /// /v1/pair, without a token: the device asks, then polls until someone here allows or denies it.
  /// Requests lapse after two minutes; the token goes out once, to the poll after Allow.
  private func pairing(_ method: String, _ target: URLComponents?, _ body: Data, on connection: NWConnection) {
    pairRequests.removeAll { Date().timeIntervalSince($0.created) > 120 }
    if method == "POST" {
      guard let request = try? JSONDecoder().decode(PairRequestBody.self, from: body) else {
        return send(connection, 400, ["error": "bad request"])
      }
      // Anyone on the network can ask: keep them from flooding the page.
      guard waitingPairRequests.count < 3 else {
        return send(connection, 429, ["error": "Too many devices are asking to pair. Try again in a couple of minutes."])
      }
      let name = request.name.trimmingCharacters(in: .whitespacesAndNewlines)
      let pending = PairRequest(
        id: UUID().uuidString, name: name.isEmpty ? "A device" : String(name.prefix(60)),
        code: String(format: "%04d", Int.random(in: 0..<10_000)))
      pairRequests.append(pending)
      WindowOpener.showMain()
      return send(connection, 200, PairTicket(id: pending.id, code: pending.code))
    }
    let id = target?.queryItems?.first { $0.name == "id" }?.value
    guard method == "GET", let i = pairRequests.firstIndex(where: { $0.id == id }) else {
      return send(connection, 404, ["error": "That pairing request has lapsed. Start again."])
    }
    switch pairRequests[i].allowed {
    case nil:
      send(connection, 200, PairStatus(status: "pending"))
    case true?:
      pairRequests.remove(at: i)
      send(connection, 200, PairStatus(status: "allowed", token: token, name: hostName))
    case false?:
      pairRequests.remove(at: i)
      send(connection, 200, PairStatus(status: "denied"))
    }
  }

  /// Addresses an iPhone can reach this Mac at: LAN and Tailscale (100.64.0.0/10) IPv4.
  var addresses: [String] {
    var result: [String] = []
    var list: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&list) == 0, let first = list else { return [] }
    defer { freeifaddrs(list) }
    for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
      let ifa = ptr.pointee
      guard let addr = ifa.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET),
        (ifa.ifa_flags & UInt32(IFF_LOOPBACK)) == 0, (ifa.ifa_flags & UInt32(IFF_UP)) != 0
      else { continue }
      var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
      getnameinfo(addr, socklen_t(addr.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST)
      let ip = String(decoding: host.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
      if !ip.hasPrefix("169.254.") { result.append(ip) }
    }
    return Array(Set(result)).sorted()
  }

  /// rexradar://pair?host=…&port=…&token=…&name=…: scanned with the iPhone camera, it opens the
  /// iOS app and pairs it.
  func pairingURL(host: String) -> URL? {
    var c = URLComponents()
    c.scheme = "rexradar"
    c.host = "pair"
    c.queryItems = [
      URLQueryItem(name: "host", value: host), URLQueryItem(name: "port", value: "\(Self.port)"),
      URLQueryItem(name: "token", value: token), URLQueryItem(name: "name", value: hostName),
    ]
    return c.url
  }
}
