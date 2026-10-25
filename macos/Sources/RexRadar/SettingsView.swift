import ServiceManagement
import SwiftUI

/// Settings state (an ObservableObject: the app target avoids SwiftUI's macros).
@MainActor
final class Preferences: ObservableObject {
  static let shared = Preferences()

  /// Mirrors SMAppService, which is the truth: you can also change it in System Settings.
  @Published private(set) var loginItem: SMAppService.Status = SMAppService.mainApp.status
  @Published private(set) var loginError: String?
  @Published var clientLabel: String {
    didSet { UserDefaults.standard.set(clientLabel, forKey: "clientLabel") }
  }

  /// Off by default: answering types into terminals, so a phone with the token could too.
  @Published var allowPhoneAnswers: Bool {
    didSet { UserDefaults.standard.set(allowPhoneAnswers, forKey: "allowPhoneAnswers") }
  }

  /// Off by default too: a skill can do anything Claude can.
  @Published var allowPhoneSkills: Bool {
    didSet { UserDefaults.standard.set(allowPhoneSkills, forKey: "allowPhoneSkills") }
  }

  init() {
    allowPhoneAnswers = UserDefaults.standard.bool(forKey: "allowPhoneAnswers")
    allowPhoneSkills = UserDefaults.standard.bool(forKey: "allowPhoneSkills")
    clientLabel = UserDefaults.standard.string(forKey: "clientLabel") ?? Host.current().localizedName ?? ""
  }

  var opensAtLogin: Bool { loginItem == .enabled || loginItem == .requiresApproval }

  func refresh() { loginItem = SMAppService.mainApp.status }

  func setOpensAtLogin(_ on: Bool) {
    loginError = nil
    do {
      if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
    } catch {
      loginError = error.localizedDescription
    }
    refresh()
  }
}

struct SettingsView: View {
  @ObservedObject var prefs: Preferences

  var body: some View {
    Form {
      Section {
        Toggle(
          "Open Rex Radar at login",
          isOn: Binding(get: { prefs.opensAtLogin }, set: { prefs.setOpensAtLogin($0) }))
        if prefs.loginItem == .requiresApproval {
          HStack {
            Label("macOS needs you to allow it in Login Items.", systemImage: "exclamationmark.triangle")
              .foregroundStyle(.orange)
            Spacer()
            Button("Open Login Items…") { SMAppService.openSystemSettingsLoginItems() }
          }
        }
        if let error = prefs.loginError {
          Text(error).foregroundStyle(.red).font(.caption)
        }
      } header: {
        Text("General")
      } footer: {
        Text("Rex Radar starts its watchers and the iPhone & iPad hub when it opens.")
      }

      Section {
        Toggle("Let iPhone & iPad answer Claude's questions", isOn: $prefs.allowPhoneAnswers)
      } header: {
        Text("Questions")
      } footer: {
        Text(
          "Answering types into the Claude pane in Rex. Rex Radar only types for a pane that's showing a question "
            + "list, only option numbers, Tab and one short line, and checks Claude's review before submitting.")
      }

      Section {
        Toggle("Let iPhone & iPad send skills to Claude", isOn: $prefs.allowPhoneSkills)
      } header: {
        Text("Skills")
      } footer: {
        Text(
          "Sending types /skill and its arguments into the Claude pane in Rex, then Enter. Rex Radar only sends "
            + "skills Claude offers in that pane, one line, and never while Claude waits on a question or a permission.")
      }

      Section {
        TextField("Rex app to switch", text: $prefs.clientLabel, prompt: Text(Host.current().localizedName ?? ""))
      } header: {
        Text("Open in Rex")
      } footer: {
        Text("The label of the Rex app that shows an agent when you click it: this Mac's name, as `rex client ls` lists it.")
      }
    }
    .formStyle(.grouped)
    .frame(width: 460)
    .fixedSize(horizontal: false, vertical: true)
    .onAppear { prefs.refresh() }
  }
}
