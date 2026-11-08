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

  /// Off by default: a new agent can be told to do anything.
  @Published var allowPhoneSessions: Bool {
    didSet { UserDefaults.standard.set(allowPhoneSessions, forKey: "allowPhoneSessions") }
  }

  /// Off by default: closing ends the agent, whatever it was doing.
  @Published var allowPhoneClose: Bool {
    didSet { UserDefaults.standard.set(allowPhoneClose, forKey: "allowPhoneClose") }
  }

  /// Off by default: anyone who reaches the hub gets its token.
  @Published var pairWithoutAsking: Bool {
    didSet { UserDefaults.standard.set(pairWithoutAsking, forKey: "pairWithoutAsking") }
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
    allowPhoneSessions = UserDefaults.standard.bool(forKey: "allowPhoneSessions")
    allowPhonePermissions = UserDefaults.standard.bool(forKey: "allowPhonePermissions")
    allowPhoneClose = UserDefaults.standard.bool(forKey: "allowPhoneClose")
    pairWithoutAsking = UserDefaults.standard.bool(forKey: "pairWithoutAsking")
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
    TabView {
      general.tabItem { Label("General", systemImage: "gearshape") }
      DeviceSettings(prefs: prefs).tabItem { Label("iPhone & iPad", systemImage: "iphone.and.ipad") }
    }
    .frame(width: 500)
    .onAppear { prefs.refresh() }
  }

  private var general: some View {
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
      } footer: {
        Text("Rex Radar runs its watchers and the iPhone & iPad hub while it's open.")
      }

      Section {
        TextField("Rex app to switch", text: $prefs.clientLabel, prompt: Text(Host.current().localizedName ?? ""))
      } footer: {
        Text("The Rex app that shows an agent when you open it: this Mac's name, as `rex client ls` lists it.")
      }
    }
    .formStyle(.grouped)
    .fixedSize(horizontal: false, vertical: true)
  }

}

/// What paired iPhones and iPads may do here, one toggle each.
struct DeviceSettings: View {
  @ObservedObject var prefs: Preferences

  var body: some View {
    Form {
      Section {
        option(
          "Pair without asking", $prefs.pairWithoutAsking,
          "Devices that find this Mac pair at once, instead of waiting on the Devices page. Anyone who reaches port "
            + "\(HubServer.port) gets the token.")
      }

      Section {
        option(
          "Answer questions", $prefs.allowPhoneAnswers,
          "Types the chosen options into the agent's form, after checking it still shows them (Pi's are answered directly).")
        option(
          "Allow or deny permissions", $prefs.allowPhonePermissions,
          "Presses 1 (yes, once) or Esc, while the agent still asks what the phone showed.")
        option(
          "Send skills", $prefs.allowPhoneSkills,
          "Types a skill the agent offers in that pane, never while it waits on you.")
        option(
          "Start new sessions", $prefs.allowPhoneSessions,
          "Starts an agent in a new Rex session in the folder the phone names.")
        option(
          "Close agents", $prefs.allowPhoneClose,
          "Closes the agent's pane in Rex, ending the agent whatever it was doing.")
      } header: {
        Text("Paired iPhones and iPads can")
      } footer: {
        Text("All off by default. Each acts in the agent's pane on this Mac.")
      }
    }
    .formStyle(.grouped)
    .fixedSize(horizontal: false, vertical: true)
  }

  /// A toggle with a one-line note under its label.
  private func option(_ title: String, _ isOn: Binding<Bool>, _ note: String) -> some View {
    Toggle(isOn: isOn) {
      Text(title)
      Text(note)
    }
  }
}
