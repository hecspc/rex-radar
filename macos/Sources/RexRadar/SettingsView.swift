import AppKit
import ServiceManagement
import SwiftUI

/// Where Rex Radar shows itself: its menu bar icon, its Dock icon, or both (the default).
enum AppPresence: String, CaseIterable, Identifiable {
  case dockAndMenuBar, menuBar, dock

  var id: Self { self }
  var title: String {
    switch self {
    case .dockAndMenuBar: "Dock and menu bar"
    case .menuBar: "Menu bar"
    case .dock: "Dock"
    }
  }
  var showsMenuBar: Bool { self != .dock }
  var showsDock: Bool { self != .menuBar }
}

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

  /// Off by default too: a skill can do anything the agent can.
  @Published var allowPhoneSkills: Bool {
    didSet { UserDefaults.standard.set(allowPhoneSkills, forKey: "allowPhoneSkills") }
  }

  /// Off by default as well: allowing runs whatever the agent asked to run.
  @Published var allowPhonePermissions: Bool {
    didSet { UserDefaults.standard.set(allowPhonePermissions, forKey: "allowPhonePermissions") }
  }

  @Published var presence: AppPresence {
    didSet {
      UserDefaults.standard.set(presence.rawValue, forKey: "presence")
      applyDock()
      // Turning the Dock icon off deactivates the app: keep Settings in front.
      NSApp.activate()
    }
  }

  init() {
    presence = UserDefaults.standard.string(forKey: "presence").flatMap(AppPresence.init) ?? .dockAndMenuBar
    allowPhoneAnswers = UserDefaults.standard.bool(forKey: "allowPhoneAnswers")
    allowPhoneSkills = UserDefaults.standard.bool(forKey: "allowPhoneSkills")
    allowPhonePermissions = UserDefaults.standard.bool(forKey: "allowPhonePermissions")
    clientLabel = UserDefaults.standard.string(forKey: "clientLabel") ?? Host.current().localizedName ?? ""
  }

  /// The Info.plist starts the app as a menu bar agent (LSUIElement); this adds the Dock icon.
  func applyDock() {
    NSApp.setActivationPolicy(presence.showsDock ? .regular : .accessory)
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
        Picker("Show Rex Radar in", selection: $prefs.presence) {
          ForEach(AppPresence.allCases) { Text($0.title).tag($0) }
        }
      } header: {
        Text("General")
      } footer: {
        Text("Rex Radar starts its watchers and the iPhone & iPad hub when it opens. Without the menu bar icon, "
          + "click its Dock icon to open the window.")
      }

      Section {
        Toggle("Let iPhone & iPad answer agents' questions", isOn: $prefs.allowPhoneAnswers)
      } header: {
        Text("Questions")
      } footer: {
        Text(
          "Answering types into the agent's pane in Rex (Claude Code, Codex, Antigravity or Qoder on this Mac). Rex "
            + "Radar only types for a pane that's showing the question list, only option numbers, Tab, arrows, Enter and "
            + "one short line, and checks the form before typing and the agent's review before submitting.")
      }

      Section {
        Toggle("Let iPhone & iPad allow or deny permissions", isOn: $prefs.allowPhonePermissions)
      } header: {
        Text("Permissions")
      } footer: {
        Text(
          "Allowing presses 1 (Yes, this once) and denying presses Esc in the agent's pane in Rex, for Claude Code, "
            + "Codex, Antigravity and Qoder. Rex Radar only presses them while the agent still asks what the phone "
            + "showed.")
      }

      Section {
        Toggle("Let iPhone & iPad send skills to agents", isOn: $prefs.allowPhoneSkills)
      } header: {
        Text("Skills")
      } footer: {
        Text(
          "Sending types the skill and its arguments into the agent's pane in Rex (/skill for Claude Code, "
            + "Antigravity and Qoder, $skill for Codex), then submits it. Rex Radar only sends skills the agent offers "
            + "in that pane, one line, and never while the agent waits on a question or a permission, nor while Qoder "
            + "works, since it can't queue them.")
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
