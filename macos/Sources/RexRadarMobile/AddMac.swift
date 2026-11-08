import SwiftUI

/// Adding a Mac: one found on this network, one at an address (with its token, or asking the Mac),
/// or its QR code. Before the first pairing it's the whole screen; after, a sheet from Settings.
struct AddMacForm: View {
  let client: HubClient
  /// Before the first pairing: what the app is for.
  var intro = false
  var done: () -> Void = {}
  @State private var finder = MacFinder()
  @State private var attempt: PairAttempt?
  @State private var host = ""
  @State private var port = "7298"
  @State private var token = ""
  @State private var connecting = false
  @State private var error: String?

  var body: some View {
    Form {
      if intro {
        Section {
          Text("Your coding agents in Rex, from your pocket. Tapping one opens it on your Mac. Pair with a Mac running Rex Radar to start.")
            .foregroundStyle(.secondary)
        }
      }
      if let attempt {
        PairAttemptSection(attempt: attempt) {
          attempt.cancel()
          self.attempt = nil
        }
      }
      Section {
        if finder.macs.isEmpty {
          HStack(spacing: 10) {
            ProgressView()
            Text("Looking for Macs running Rex Radar…").foregroundStyle(.secondary)
          }
        }
        ForEach(finder.macs) { mac in
          Button {
            ask(.found(mac))
          } label: {
            HStack {
              Label(mac.name, systemImage: "laptopcomputer")
              Spacer()
              if client.hubs.contains(where: { $0.name == mac.name }) {
                Text("Paired").font(.caption).foregroundStyle(.secondary)
              }
            }
          }
          .disabled(attempt != nil)
        }
      } header: {
        Text("On This Network")
      } footer: {
        Text("The Mac asks you to allow this device on its Devices page, unless it's set to pair devices without asking.")
      }
      Section {
        MacAddressFields(host: $host, port: $port, token: $token, tokenPrompt: "Token (optional)")
        if let error {
          Label(error, systemImage: "exclamationmark.triangle.fill").font(.callout).foregroundStyle(.orange)
        }
        Button {
          add()
        } label: {
          HStack {
            Text(token.isEmpty ? "Ask to Pair" : "Add Mac")
            if connecting { Spacer(); ProgressView() }
          }
        }
        .disabled(host.trimmingCharacters(in: .whitespaces).isEmpty || Int(port) == nil || connecting || attempt != nil)
      } header: {
        Text("By Address")
      } footer: {
        Text(
          "For a Mac over Tailscale or a VPN, which this device can't find on its own. With the token from the Mac's "
            + "Devices page it pairs at once; without, the Mac asks you to allow it.")
      }
      Section("With the Camera") {
        Text("On the Mac, open Rex Radar → Devices, and scan a code with this device's Camera app.")
          .font(.callout).foregroundStyle(.secondary)
      }
    }
    .onAppear { finder.start() }
    .onDisappear {
      finder.stop()
      attempt?.cancel()
    }
    .onChange(of: attempt?.phase) { _, phase in
      if phase == .paired { done() }
    }
  }

  private func ask(_ target: PairAttempt.Target) {
    error = nil
    attempt = PairAttempt(target, client: client)
  }

  private func add() {
    guard let port = Int(port) else { return }
    guard !token.trimmingCharacters(in: .whitespaces).isEmpty else { return ask(.address(host, port: port)) }
    connecting = true
    error = nil
    Task {
      defer { connecting = false }
      do {
        try await client.connect(host: host, port: port, token: token)
        done()
      } catch {
        self.error = MacAddressFields.describe(error)
      }
    }
  }
}

/// A paired Mac's address, port and token, changed by hand (a new address that Bonjour can't
/// find, such as over a VPN).
struct EditMacForm: View {
  let client: HubClient
  let hub: Hub
  @State private var host: String
  @State private var port: String
  @State private var token = ""
  @State private var saving = false
  @State private var error: String?
  @Environment(\.dismiss) private var dismiss

  init(client: HubClient, hub: Hub) {
    self.client = client
    self.hub = hub
    _host = State(initialValue: hub.host)
    _port = State(initialValue: String(hub.port))
  }

  var body: some View {
    Form {
      Section {
        MacAddressFields(host: $host, port: $port, token: $token, tokenPrompt: "Token (leave empty to keep it)")
      } footer: {
        Text("Saving asks the Mac at the new address first.")
      }
      if let error {
        Section {
          Label(error, systemImage: "exclamationmark.triangle.fill").font(.callout).foregroundStyle(.orange)
          Button("Save Anyway") {
            client.move(hub, host: host, port: Int(port) ?? hub.port)
            dismiss()
          }
        }
      }
    }
    .navigationTitle(hub.name)
    .navigationBarTitleDisplayMode(.inline)
    .toolbar {
      ToolbarItem(placement: .confirmationAction) {
        if saving {
          ProgressView()
        } else {
          Button("Save", action: save)
            .disabled(host.trimmingCharacters(in: .whitespaces).isEmpty || Int(port) == nil)
        }
      }
    }
  }

  private func save() {
    guard let port = Int(port) else { return }
    let token = token.isEmpty ? (Keychain.read(for: hub.id) ?? "") : token
    saving = true
    error = nil
    Task {
      defer { saving = false }
      do {
        try await client.connect(host: host, port: port, token: token, replacing: hub.id)
        dismiss()
      } catch {
        self.error = MacAddressFields.describe(error)
      }
    }
  }
}

struct MacAddressFields: View {
  @Binding var host: String
  @Binding var port: String
  @Binding var token: String
  let tokenPrompt: String

  var body: some View {
    TextField("Address (e.g. 10.0.10.20 or my-mac.example.net)", text: $host)
      .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
    LabeledContent("Port") {
      TextField("7298", text: $port).keyboardType(.numberPad).multilineTextAlignment(.trailing)
    }
    TextField(tokenPrompt, text: $token)
      .textInputAutocapitalization(.never).autocorrectionDisabled()
  }

  static func describe(_ error: Error) -> String {
    switch error {
    case HubError.unauthorized: "The Mac didn't accept that token."
    case is URLError: "Couldn't reach Rex Radar at that address: \(error.localizedDescription)"
    default: error.localizedDescription
    }
  }
}

/// One pairing request in progress: the code to check on the Mac, or what went wrong.
private struct PairAttemptSection: View {
  let attempt: PairAttempt
  let cancel: () -> Void

  var body: some View {
    Section {
      switch attempt.phase {
      case .connecting:
        HStack(spacing: 10) {
          ProgressView()
          Text("Asking \(attempt.macName)…")
        }
        Button("Cancel", role: .cancel, action: cancel)
      case .waiting(let code):
        Text("On \(attempt.macName), allow this device in Rex Radar → Devices. It shows this code:")
          .font(.callout).foregroundStyle(.secondary)
        Text(code).font(.system(size: 44, weight: .bold, design: .monospaced)).foregroundStyle(.tint)
        Button("Cancel", role: .cancel, action: cancel)
      case .paired:
        Label("Paired with \(attempt.macName)", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
      case .failed(let message):
        Label(message, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        Button("Try Again", action: cancel)
      }
    }
  }
}
