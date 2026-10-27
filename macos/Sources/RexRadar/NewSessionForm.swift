import SwiftUI

/// The form's state (an ObservableObject: the Mac target avoids SwiftUI's macros).
@MainActor
final class NewSessionModel: ObservableObject {
  @Published var agent = SkillAgent.claudeCode
  @Published var directory = "~"
  @Published var server: UUID?
  @Published var error: String?
  @Published var starting = false
}

/// Picks an agent, a folder and (with several servers) a server, and starts a new Rex session there.
struct NewSessionForm: View {
  let servers: [ServerConfig]
  let start: (SkillAgent, String, String?) async throws -> Void
  let cancel: () -> Void

  @StateObject private var model = NewSessionModel()

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      Text("New Session").font(.headline)
      Form {
        Picker("Agent:", selection: $model.agent) {
          ForEach(SkillAgent.allCases) { Text($0.title).tag($0) }
        }
        TextField("Folder:", text: $model.directory, prompt: Text("~"))
          .textFieldStyle(.roundedBorder)
          .onSubmit(send)
        if servers.count > 1 {
          Picker("Server:", selection: $model.server) {
            ForEach(servers) { Text($0.name).tag(Optional($0.id)) }
          }
        }
      }
      .formStyle(.columns)
      if let error = model.error {
        Label(error, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.red)
      }
      HStack {
        Spacer()
        Button("Cancel", action: cancel).keyboardShortcut(.cancelAction)
        Button("Start", action: send)
          .keyboardShortcut(.defaultAction)
          .disabled(model.starting)
      }
    }
    .onAppear { model.server = servers.first(where: \.isLocal)?.id ?? servers.first?.id }
  }

  private func send() {
    let model = model
    guard !model.starting else { return }
    let address = servers.first { $0.id == model.server }?.address
    model.starting = true
    model.error = nil
    Task {
      do { try await start(model.agent, model.directory, address) } catch { model.error = error.localizedDescription }
      model.starting = false
    }
  }
}
