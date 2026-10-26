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

/// Asking one Mac to pair. The Apple TV has no camera for the QR code, so it asks the hub
/// (POST /v1/pair), shows the code, and polls until someone allows it on the Mac's Devices page.
@MainActor @Observable
final class PairAttempt {
  enum Target {
    case found(FoundMac)
    case address(String)
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
    case .address(let address): macName = address
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
    case .address(let address):
      host = address.trimmingCharacters(in: .whitespaces)
    }
    guard let url = URL(string: "http://\(host):\(port)/v1/pair") else {
      phase = .failed("That isn't an address.")
      return
    }
    do {
      let body = try JSONEncoder().encode(PairRequestBody(name: UIDevice.current.name))
      let ticket = try JSONDecoder().decode(PairTicket.self, from: try await Self.request(url, body: body))
      phase = .waiting(code: ticket.code)
      var c = URLComponents(url: url, resolvingAgainstBaseURL: false)!
      c.queryItems = [URLQueryItem(name: "id", value: ticket.id)]
      while true {
        try await Task.sleep(for: .seconds(1.5))
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

/// Before pairing (and Settings → Pair Another Mac): the Macs on this network, or an address.
struct TVPairScreen: View {
  let client: HubClient
  @State private var finder = MacFinder()
  @State private var attempt: PairAttempt?
  @State private var address = ""
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    HStack(alignment: .top, spacing: 100) {
      VStack(alignment: .leading, spacing: 24) {
        Image(systemName: "dot.radiowaves.left.and.right").font(.system(size: 90)).foregroundStyle(.tint)
        Text("Rex Radar").font(.largeTitle.weight(.bold))
        Text("Your coding agents in Rex, on the big screen. Choose the Mac that runs Rex Radar, then allow this Apple TV there.")
          .foregroundStyle(.secondary)
      }
      .frame(maxWidth: 640, alignment: .leading)
      VStack(alignment: .leading, spacing: 24) {
        if let attempt {
          AttemptView(attempt: attempt) {
            attempt.cancel()
            self.attempt = nil
          }
        } else {
          choices
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .padding(.top, 60)
    .onAppear { finder.start() }
    .onDisappear {
      finder.stop()
      attempt?.cancel()
    }
    .onChange(of: attempt?.phase) { _, phase in
      if phase == .paired { dismiss() }
    }
    // For simulators, which can't press the remote from the command line:
    // `SIMCTL_CHILD_REXRADAR_PAIR_WITH=<Mac name> xcrun simctl launch …` asks that Mac once it's found.
    .onChange(of: finder.macs) {
      guard attempt == nil, let name = ProcessInfo.processInfo.environment["REXRADAR_PAIR_WITH"],
        let mac = finder.macs.first(where: { $0.name == name })
      else { return }
      attempt = PairAttempt(.found(mac), client: client)
    }
  }

  @ViewBuilder private var choices: some View {
    Text("Macs on this network").font(.headline)
    if finder.macs.isEmpty {
      HStack(spacing: 16) {
        ProgressView()
        Text("Looking for Macs running Rex Radar…").foregroundStyle(.secondary)
      }
    }
    ForEach(finder.macs) { mac in
      Button {
        attempt = PairAttempt(.found(mac), client: client)
      } label: {
        Label(mac.name, systemImage: "laptopcomputer").frame(maxWidth: .infinity, alignment: .leading)
      }
    }
    Text("Or enter its address, for a Mac on Tailscale").font(.headline).padding(.top, 24)
    HStack {
      TextField("100.101.102.103", text: $address)
        .keyboardType(.numbersAndPunctuation)
        .autocorrectionDisabled()
      Button("Pair") { attempt = PairAttempt(.address(address), client: client) }
        .disabled(address.trimmingCharacters(in: .whitespaces).isEmpty)
    }
  }
}

/// One pairing in progress: the code to check on the Mac, or what went wrong.
private struct AttemptView: View {
  let attempt: PairAttempt
  let cancel: () -> Void

  var body: some View {
    switch attempt.phase {
    case .connecting:
      HStack(spacing: 16) {
        ProgressView()
        Text("Asking \(attempt.macName)…")
      }
      Button("Cancel", action: cancel)
    case .waiting(let code):
      Text("On \(attempt.macName), allow this Apple TV in Rex Radar → Devices. It shows this code:")
        .foregroundStyle(.secondary)
      Text(code).font(.system(size: 120, weight: .bold, design: .monospaced)).foregroundStyle(.tint)
      Button("Cancel", action: cancel)
    case .paired:
      Label("Paired with \(attempt.macName)", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
    case .failed(let message):
      Label(message, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
      Button("Try Again", action: cancel)
    }
  }
}
