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
  @ObservedObject private var hub = HubServer.shared
  @Environment(\.openWindow) private var openWindow

  var body: some View {
    NavigationSplitView {
      List(selection: $model.selection) {
        Label("All Agents", systemImage: "dot.radiowaves.left.and.right")
          .badge(store.attentionCount)
          .tag(Self.all)
        Label("Devices", systemImage: "iphone.and.ipad")
          .badge(hub.waitingPairRequests.count)
          .tag(Self.devices)
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
    // An Apple TV asking to pair: show where to allow it.
    .onChange(of: hub.waitingPairRequests.map(\.id), initial: true) { _, waiting in
      if !waiting.isEmpty { model.selection = Self.devices }
    }
    .toolbar {
      Button { store.creatingSession = true } label: { Label("New Session", systemImage: "plus") }
        .help("Start an agent in a new Rex session")
    }
    .sheet(isPresented: $store.creatingSession) {
      NewSessionForm(
        servers: Watchers.shared.servers, start: { try await store.newSession($0, directory: $1, server: $2) },
        cancel: { store.creatingSession = false })
        .padding(24)
        .frame(width: 420)
    }
    .sheet(isPresented: Binding(get: { store.answering != nil }, set: { if !$0 { store.stopAnswering() } })) {
      if let (row, draft) = store.answering {
        ScrollView {
          VStack(alignment: .leading, spacing: 12) {
            Text(row.headline).font(.title2.weight(.bold))
            FactsLine(facts: row.facts(session: true), font: .subheadline)
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
          Text(row.headline).font(.title2.weight(.bold))
          FactsLine(facts: row.facts(session: true), font: .subheadline)
          SkillPicker(
            load: { try await store.skills(for: row) }, send: { try await store.sendSkill(row, $0) },
            agentName: row.appLabel, cancel: { store.picking = nil })
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
          // One grid of cards, most urgent first, filling every row: a wall, not a list of sections.
          // Resting agents follow as strips.
          let active = rows.filter { !$0.isResting }
          let resting = rows.filter(\.isResting)
          VStack(alignment: .leading, spacing: 24) {
            if !active.isEmpty {
              LazyVGrid(columns: [GridItem(.adaptive(minimum: 320), spacing: 14, alignment: .top)], spacing: 14) {
                ForEach(active) { row in
                  HeroCard(
                    row: row, open: { store.open(row) }, answer: row.questions == nil ? nil : { store.startAnswering(row) },
                    skill: row.takesSkills ? { store.picking = row } : nil, decide: { store.decide(row, $0) },
                    close: { store.close(row) }, fillHeight: true)
                }
              }
            }
            if !resting.isEmpty {
              VStack(alignment: .leading, spacing: 10) {
                SectionHeader(title: "Resting", count: resting.count)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 320), spacing: 10, alignment: .top)], spacing: 8) {
                  ForEach(resting) { row in
                    RestingStrip(
                      row: row, open: { store.open(row) }, skill: row.takesSkills ? { store.picking = row } : nil,
                      close: { store.close(row) })
                  }
                }
              }
            }
          }
          .padding(20)
        }
      }
      .navigationTitle(model.selection == Self.all || model.selection == nil ? "All Agents" : model.selection!)
      .navigationSubtitle(store.openError ?? RowSection.summary(rows) { $0 })
    }
  }
}
