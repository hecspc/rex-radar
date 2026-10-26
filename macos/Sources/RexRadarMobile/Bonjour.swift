import Foundation
import Network

/// Finding a Mac's hub (_rexradar._tcp, advertised under the Mac's name) on this network.
enum Bonjour {
  static let serviceType = "_rexradar._tcp"

  /// Whether a pairing's address may be swapped for the one Bonjour finds. A Tailscale address
  /// (100.64.0.0/10) or a name stays: it works away from home, where the LAN one wouldn't.
  static func canRelocate(_ host: String) -> Bool {
    let octets = host.split(separator: ".").compactMap { Int($0) }
    guard octets.count == 4 else { return false }
    return !(octets[0] == 100 && (64...127).contains(octets[1]))
  }

  /// The IPv4 address and port of the Mac advertising the hub under `name`, if it shows up in time.
  static func locate(name: String, timeout: TimeInterval = 3) async -> (String, Int)? {
    guard let endpoint = await find(name: name, timeout: timeout) else { return nil }
    return await resolve(endpoint)
  }

  private static func find(name: String, timeout: TimeInterval) async -> NWEndpoint? {
    let browser = NWBrowser(for: .bonjour(type: serviceType, domain: nil), using: .tcp)
    let once = Once()
    return await withCheckedContinuation { continuation in
      let finish: @Sendable (NWEndpoint?) -> Void = { result in
        guard once.claim() else { return }
        browser.cancel()
        continuation.resume(returning: result)
      }
      browser.browseResultsChangedHandler = { results, _ in
        let match = results.first { result in
          if case .service(name, _, _, _) = result.endpoint { return true }
          return false
        }
        if let match { finish(match.endpoint) }
      }
      browser.stateUpdateHandler = { state in
        if case .failed = state { finish(nil) }
      }
      browser.start(queue: .main)
      DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { finish(nil) }
    }
  }

  /// The Mac's IPv4 address and port, from a connection to its Bonjour service: the hub's URL
  /// needs a host, and an IPv6 link-local one wouldn't survive a network change.
  static func resolve(_ endpoint: NWEndpoint) async -> (String, Int)? {
    let parameters = NWParameters.tcp
    (parameters.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options)?.version = .v4
    let connection = NWConnection(to: endpoint, using: parameters)
    let once = Once()
    return await withCheckedContinuation { continuation in
      let finish: @Sendable ((String, Int)?) -> Void = { result in
        guard once.claim() else { return }
        connection.cancel()
        continuation.resume(returning: result)
      }
      connection.stateUpdateHandler = { state in
        switch state {
        case .ready:
          guard case .hostPort(let host, let port) = connection.currentPath?.remoteEndpoint else { return finish(nil) }
          let name: String
          switch host {
          case .ipv4(let address): name = "\(address)"
          case .ipv6(let address): name = "[\(address)]"
          case .name(let hostName, _): name = hostName
          @unknown default: return finish(nil)
          }
          finish((String(name.prefix { $0 != "%" }), Int(port.rawValue)))
        case .failed, .cancelled:
          finish(nil)
        default:
          break
        }
      }
      connection.start(queue: .main)
      DispatchQueue.main.asyncAfter(deadline: .now() + 6) { finish(nil) }
    }
  }

  /// Lets the first of the callbacks and the timeout through. All run on the main queue.
  private final class Once: @unchecked Sendable {
    private var done = false
    func claim() -> Bool {
      defer { done = true }
      return !done
    }
  }
}
