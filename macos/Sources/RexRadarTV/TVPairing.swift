import SwiftUI

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
      Button("Pair") { attempt = PairAttempt(.address(address, port: 7298), client: client) }
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
