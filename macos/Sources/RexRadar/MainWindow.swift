import SwiftUI

/// The window's sidebar selection. An ObservableObject rather than @State: SwiftUI's macros need Xcode.
@MainActor
final class WindowModel: ObservableObject {
  @Published var selection: String? = MainWindow.all
}

struct MainWindow: View {
  static let all = "__all__"
  static let devices = "__devices__"

  @ObservedObject var store: Store
  @StateObject private var model = WindowModel()

  var body: some View {
    NavigationSplitView {
      List(selection: $model.selection) {
        Label("All Agents", systemImage: "dot.radiowaves.left.and.right")
          .badge(store.attentionCount)
          .tag(Self.all)
        Label("iPhone & iPad", systemImage: "iphone.and.ipad").tag(Self.devices)
        Section("Servers") {
          ForEach(store.sources, id: \.self) { source in
            Label(source, systemImage: "server.rack")
              .badge(store.rows.filter { $0.source == source && !$0.stale && $0.state.needsAttention }.count)
              .tag(source)
          }
        }
      }
      .navigationSplitViewColumnWidth(min: 180, ideal: 200)
    } detail: {
      detail
    }
    .frame(minWidth: 720, minHeight: 460)
  }

  private var rows: [Row] {
    guard let selection = model.selection, selection != Self.all, selection != Self.devices else { return store.rows }
    return store.rows.filter { $0.source == selection }
  }

  @ViewBuilder private var detail: some View {
    if model.selection == Self.devices {
      PairingView(hub: .shared)
    } else if rows.isEmpty {
      ContentUnavailableView(
        "No agents", systemImage: "dot.radiowaves.left.and.right",
        description: Text("Run the watcher in a Rex pane:\nrex do watcher/rex-radar.lua --all source=mac"))
    } else {
      ScrollView {
        GlassEffectContainer(spacing: 16) {
          LazyVGrid(columns: [GridItem(.adaptive(minimum: 300), spacing: 16)], spacing: 16) {
            ForEach(rows) { row in HeroCard(row: row) { store.open(row) } }
          }
          .padding(20)
        }
      }
      .navigationTitle(model.selection == Self.all || model.selection == nil ? "All Agents" : model.selection!)
      .navigationSubtitle(store.openError ?? "\(rows.count) agent\(rows.count == 1 ? "" : "s")")
    }
  }
}
