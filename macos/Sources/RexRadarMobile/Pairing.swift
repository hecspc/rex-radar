import Network
import SwiftUI
import UIKit

/// A Mac advertising Rex Radar's hub on this network, under the Mac's name.
struct FoundMac: Identifiable, Hashable {
  var name: String
  var endpoint: NWEndpoint
  var id: String { name }
}

/// Finds Macs running Rex Radar over Bonjour (the hub advertises _rexradar._tcp).
@MainActor @Observable
final class MacFinder {
  private(set) var macs: [FoundMac] = []
  private var browser: NWBrowser?

  func start() {
    guard browser == nil else { return }
    let browser = NWBrowser(for: .bonjour(type: Bonjour.serviceType, domain: nil), using: .tcp)
    browser.browseResultsChangedHandler = { [weak self] results, _ in
      let macs = results.compactMap { result -> FoundMac? in
        guard case .service(let name, _, _, _) = result.endpoint else { return nil }
        return FoundMac(name: name, endpoint: result.endpoint)
      }
      Task { @MainActor in self?.macs = macs.sorted { $0.name < $1.name } }
    }
    browser.start(queue: .main)
    self.browser = browser
  }

  func stop() {
    browser?.cancel()
    browser = nil
  }
}

/// Asking one Mac to pair, without its QR code or token: the device asks the hub (POST /v1/pair),
/// shows the code, and polls until someone allows it on the Mac's Devices page. A Mac set to pair
/// devices without asking allows it at once.
@MainActor @Observable
final class PairAttempt {
  enum Target {
    case found(FoundMac)
    case address(String, port: Int)
  }

  enum Phase: Equatable {
    case connecting
    case waiting(code: String)
    case paired
    case failed(String)
  }

  let macName: String
  private(set) var phase = Phase.connecting
  private var task: Task<Void, Never>?

  init(_ target: Target, client: HubClient) {
    switch target {
    case .found(let mac): macName = mac.name
    case .address(let address, _): macName = address
    }
    task = Task { await run(target, client: client) }
  }

  func cancel() { task?.cancel() }

  private func run(_ target: Target, client: HubClient) async {
    var host: String
    var port = 7298
    switch target {
    case .found(let mac):
      guard let resolved = await Bonjour.resolve(mac.endpoint) else {
        phase = .failed("Couldn't reach \(mac.name). Is Rex Radar running there?")
        return
      }
      (host, port) = resolved
    case .address(let address, let given):
      host = address.trimmingCharacters(in: .whitespaces)
      port = given
    }
    guard let url = URL(string: "http://\(host):\(port)/v1/pair") else {
      phase = .failed("That isn't an address.")
      return
    }
    do {
      let body = try JSONEncoder().encode(PairRequestBody(name: UIDevice.current.name))
      let ticket = try JSONDecoder().decode(PairTicket.self, from: try await Self.request(url, body: body))
      if ticket.allowed != true { phase = .waiting(code: ticket.code) }
      var c = URLComponents(url: url, resolvingAgainstBaseURL: false)!
      c.queryItems = [URLQueryItem(name: "id", value: ticket.id)]
      while true {
        // Allowed at once: fetch the token straight away.
        try await Task.sleep(for: .seconds(phase == .connecting ? 0.1 : 1.5))
        let status = try JSONDecoder().decode(PairStatus.self, from: try await Self.request(c.url!, body: nil))
        switch status.status {
        case "allowed":
          guard let token = status.token else { throw HubError.status(200) }
          client.pair(host: host, port: port, token: token, name: status.name ?? macName)
          phase = .paired
          return
        case "denied":
          phase = .failed("\(macName) didn't allow it.")
          return
        default:
          continue
        }
      }
    } catch is CancellationError {
    } catch {
      phase = .failed(error.localizedDescription)
    }
  }

  private nonisolated static func request(_ url: URL, body: Data?) async throws -> Data {
    var request = URLRequest(url: url, timeoutInterval: 6)
    if let body {
      request.httpMethod = "POST"
      request.httpBody = body
      request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    }
    let (data, response) = try await URLSession.shared.data(for: request)
    let status = (response as? HTTPURLResponse)?.statusCode ?? 0
    guard status == 200 else {
      let message = (try? JSONSerialization.jsonObject(with: data) as? [String: String])?["error"]
      throw message.map(HubError.refused) ?? HubError.status(status)
    }
    return data
  }
}
