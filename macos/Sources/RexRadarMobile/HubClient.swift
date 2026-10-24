import Foundation
import Observation
import Security

/// The Mac this phone is paired with: where agents come from, and where taps open them.
struct Hub: Codable, Equatable {
  var name: String
  var host: String
  var port: Int
  var base: URL? { URL(string: "http://\(host):\(port)") }
}

@MainActor @Observable
final class HubClient {
  private(set) var hub: Hub?
  private(set) var rows: [Row] = []
  private(set) var sources: [String] = []
  private(set) var updated: Date?
  private(set) var error: String?
  /// Shown briefly after a tap: "Opened on vv-macbook".
  var notice: String?

  private var token: String? { Keychain.read() }

  init() {
    if let data = UserDefaults.standard.data(forKey: "hub") { hub = try? JSONDecoder().decode(Hub.self, from: data) }
    // For simulators and tests: `SIMCTL_CHILD_REXRADAR_PAIR=rexradar://pair?… xcrun simctl launch …`.
    if let link = ProcessInfo.processInfo.environment["REXRADAR_PAIR"], let url = URL(string: link) { pair(with: url) }
  }

  var attentionCount: Int { rows.filter { !$0.stale && $0.state.needsAttention }.count }

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

  func pair(host: String, port: Int, token: String, name: String) {
    let hub = Hub(name: name, host: host, port: port)
    self.hub = hub
    Keychain.write(token)
    UserDefaults.standard.set(try? JSONEncoder().encode(hub), forKey: "hub")
    rows = []
    error = nil
    Task { await refresh() }
  }

  func unpair() {
    hub = nil
    rows = []
    Keychain.write(nil)
    UserDefaults.standard.removeObject(forKey: "hub")
  }

  func refresh() async {
    guard let base = hub?.base else { return }
    do {
      let data = try await request(base.appending(path: "v1/agents"), method: "GET")
      let decoder = JSONDecoder()
      decoder.dateDecodingStrategy = .iso8601
      let response = try decoder.decode(AgentsResponse.self, from: data)
      rows = response.rows
      sources = response.sources
      updated = response.writtenAt
      error = nil
    } catch {
      self.error = error.localizedDescription
    }
  }

  /// Asks the Mac to show the agent in its Rex app.
  func open(_ row: Row) {
    guard let base = hub?.base, var c = URLComponents(url: base.appending(path: "v1/open"), resolvingAgainstBaseURL: false)
    else { return }
    c.queryItems = [URLQueryItem(name: "id", value: row.id)]
    guard let url = c.url else { return }
    Task {
      do {
        _ = try await request(url, method: "POST")
        notice = "Opened on \(hub?.name ?? "your Mac")"
      } catch {
        notice = "Couldn't open: \(error.localizedDescription)"
      }
      try? await Task.sleep(for: .seconds(2.5))
      notice = nil
    }
  }

  /// Polls while the app is on screen; the caller cancels the task when it goes to the background.
  func poll() async {
    while !Task.isCancelled {
      await refresh()
      try? await Task.sleep(for: .seconds(4))
    }
  }

  private func request(_ url: URL, method: String) async throws -> Data {
    var request = URLRequest(url: url, timeoutInterval: 6)
    request.httpMethod = method
    if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
    let (data, response) = try await URLSession.shared.data(for: request)
    let status = (response as? HTTPURLResponse)?.statusCode ?? 0
    switch status {
    case 200: return data
    case 401: throw HubError.unauthorized
    default: throw HubError.status(status)
    }
  }
}

enum HubError: LocalizedError {
  case unauthorized, status(Int)
  var errorDescription: String? {
    switch self {
    case .unauthorized: "The Mac refused the pairing. Scan its code again."
    case .status(let code): "The Mac answered \(code)."
    }
  }
}

/// The hub token, in the Keychain rather than UserDefaults.
enum Keychain {
  private static var query: [String: Any] {
    [
    kSecClass as String: kSecClassGenericPassword,
    kSecAttrService as String: "house.milapan.rex-radar.hub",
    kSecAttrAccount as String: "token",
    ]
  }

  static func read() -> String? {
    var q = query
    q[kSecReturnData as String] = true
    var out: CFTypeRef?
    guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
    return String(data: data, encoding: .utf8)
  }

  static func write(_ value: String?) {
    SecItemDelete(query as CFDictionary)
    guard let value else { return }
    var q = query
    q[kSecValueData as String] = Data(value.utf8)
    q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
    SecItemAdd(q as CFDictionary, nil)
  }
}
