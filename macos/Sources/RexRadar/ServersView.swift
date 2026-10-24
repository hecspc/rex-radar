import SwiftUI

/// The add-server form's state (an ObservableObject: the app target avoids SwiftUI's macros).
@MainActor
final class ServerForm: ObservableObject {
  @Published var name = ""
  @Published var address = ""
  @Published var hosts: [String] = []

  func loadHosts() {
    Task.detached {
      let hosts = Watchers.knownHosts()
      await MainActor.run { self.hosts = hosts }
    }
  }
}

/// The window's "Manage Servers" page: the Rex servers this Mac watches, and a form to add one.
struct ServersView: View {
  @ObservedObject var watchers: Watchers
  @StateObject private var form = ServerForm()

  var body: some View {
    ScrollView {
      GlassEffectContainer(spacing: 16) {
        VStack(alignment: .leading, spacing: 16) {
          VStack(alignment: .leading, spacing: 6) {
            Text("Rex Servers").font(.title2.weight(.bold))
            Text(
              "Rex Radar runs a watcher for each server. Agents on a remote server open in this Mac's Rex, "
                + "so add that host in Rex too (Add Remote Host…)."
            )
            .foregroundStyle(.secondary)
          }
          ForEach(watchers.servers) { server in serverCard(server) }
          addCard
        }
        .padding(24)
      }
    }
    .navigationTitle("Servers")
    .onAppear { form.loadHosts() }
  }

  private func serverCard(_ server: ServerConfig) -> some View {
    let status = watchers.status[server.id] ?? "stopped"
    let running = status == "running"
    return GlassCard {
      HStack(spacing: 12) {
        Image(systemName: server.isLocal ? "laptopcomputer" : "server.rack").font(.title2).frame(width: 30)
        VStack(alignment: .leading, spacing: 2) {
          Text(server.name).font(.headline)
          Text(server.isLocal ? "This Mac" : server.address ?? "").font(.callout).foregroundStyle(.secondary)
          HStack(spacing: 5) {
            Circle().fill(running ? Color.green : .orange).frame(width: 7, height: 7)
            Text(status).font(.caption).foregroundStyle(.secondary).lineLimit(2)
          }
        }
        Spacer()
        Button(role: .destructive) { watchers.remove(server) } label: { Image(systemName: "trash") }
          .buttonStyle(.glass)
          .help("Stop watching \(server.name)")
      }
    }
  }

  private var addCard: some View {
    GlassCard {
      VStack(alignment: .leading, spacing: 10) {
        Label("Add a server", systemImage: "plus.circle").font(.headline)
        TextField("Name shown in Rex Radar (e.g. build)", text: $form.name)
        HStack {
          TextField("Host label or address (e.g. build, https://build.tail1234.ts.net)", text: $form.address)
          if !form.hosts.isEmpty {
            Menu("Hosts") {
              ForEach(form.hosts, id: \.self) { host in
                Button(host) {
                  form.address = host
                  if form.name.isEmpty { form.name = host }
                }
              }
            }
            .fixedSize()
          }
        }
        Button("Add") {
          watchers.add(name: form.name, address: form.address)
          form.name = ""
          form.address = ""
        }
        .buttonStyle(.glassProminent)
        .disabled(form.name.isEmpty || form.address.isEmpty)
      }
      .textFieldStyle(.roundedBorder)
    }
  }
}
