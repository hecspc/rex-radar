import SwiftUI

/// The window's sidebar selection. An ObservableObject rather than @State: SwiftUI's macros need Xcode.
@MainActor
final class WindowModel: ObservableObject {
  @Published var selection: String? = MainWindow.all
}

struct MainWindow: View {
  static let all = "__all__"
  static let devices = "__devices__"
  static let manage = "__servers__"

  @ObservedObject var store: Store
  @StateObject private var model = WindowModel()
  @Environment(\.openWindow) private var openWindow

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
          Label("Manage Servers…", systemImage: "slider.horizontal.3").tag(Self.manage)
        }
      }
      .navigationSplitViewColumnWidth(min: 180, ideal: 200)
    } detail: {
      detail
    }
    .frame(minWidth: 720, minHeight: 460)
    .onAppear { WindowOpener.openWindow = openWindow }
    .sheet(isPresented: Binding(get: { store.answering != nil }, set: { if !$0 { store.stopAnswering() } })) {
      if let (row, draft) = store.answering {
        ScrollView {
          VStack(alignment: .leading, spacing: 12) {
            Text(row.pane.session ?? "Session").font(.title2.weight(.bold))
            Text(row.tabLabel).foregroundStyle(.secondary)
            QuestionsForm(draft: draft, send: { try await store.answer(row, $0) }, cancel: { store.stopAnswering() })
          }
          .padding(24)
        }
        .frame(width: 520, height: 560)
      }
    }
    .sheet(isPresented: Binding(get: { store.picking != nil }, set: { if !$0 { store.picking = nil } })) {
      if let row = store.picking {
        VStack(alignment: .leading, spacing: 12) {
          Text(row.pane.session ?? "Session").font(.title2.weight(.bold))
          Text(row.tabLabel).foregroundStyle(.secondary)
          SkillPicker(
            load: { try await store.skills(for: row) }, send: { try await store.sendSkill(row, $0) },
            cancel: { store.picking = nil })
        }
        .padding(24)
        .frame(width: 520, height: 600)
      }
    }
  }

  private var rows: [Row] {
    guard let selection = model.selection, selection != Self.all, selection != Self.devices, selection != Self.manage else { return store.rows }
    return store.rows.filter { $0.source == selection }
  }

  @ViewBuilder private var detail: some View {
    if model.selection == Self.devices {
      PairingView(hub: .shared)
    } else if model.selection == Self.manage {
      ServersView(watchers: .shared)
    } else if rows.isEmpty {
      ContentUnavailableView(
        "No agents", systemImage: "dot.radiowaves.left.and.right",
        description: Text("Run the watcher in a Rex pane:\nrex do watcher/rex-radar.lua --all source=mac"))
    } else {
      ScrollView {
        GlassEffectContainer(spacing: 16) {
          LazyVGrid(columns: [GridItem(.adaptive(minimum: 300), spacing: 16, alignment: .top)], spacing: 16) {
            ForEach(rows) { row in
              HeroCard(
                row: row, open: { store.open(row) }, answer: row.questions == nil ? nil : { store.startAnswering(row) },
                skill: row.takesSkills ? { store.picking = row } : nil, fillHeight: true)
            }
          }
          .padding(20)
        }
      }
      .navigationTitle(model.selection == Self.all || model.selection == nil ? "All Agents" : model.selection!)
      .navigationSubtitle(store.openError ?? "\(rows.count) agent\(rows.count == 1 ? "" : "s")")
    }
  }
}
