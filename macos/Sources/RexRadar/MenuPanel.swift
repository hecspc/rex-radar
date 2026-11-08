import AppKit
import SwiftUI

struct MenuPanel: View {
  @ObservedObject var store: Store
  @Environment(\.openWindow) private var openWindow
  @Environment(\.openSettings) private var openSettings
  @Environment(\.dismiss) private var dismiss

  /// The list's own height, measured: a ScrollView in a menu bar window has none of its own.
  @StateObject private var list = ListHeight()

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      // Each part has its own glass container: glass drawn by one container around the scroll
      // view isn't clipped by it, and scrolled cards would slide over the header.
      GlassEffectContainer { header }
      if store.creatingSession {
        GlassEffectContainer {
          GlassCard(padding: 16) {
            NewSessionForm(
              servers: Watchers.shared.servers, start: { try await store.newSession($0, directory: $1, server: $2) },
              cancel: { store.creatingSession = false })
          }
        }
      } else if let (row, draft) = store.answering {
        GlassEffectContainer {
          GlassCard(padding: 16) {
            VStack(alignment: .leading, spacing: 10) {
              Text([row.pane.session, row.headline].compactMap { $0 }.joined(separator: " · ")).font(.subheadline).foregroundStyle(.secondary)
              QuestionsForm(draft: draft, send: { try await store.answer(row, $0) }, cancel: { store.stopAnswering() })
            }
          }
        }
      } else if let row = store.picking {
        GlassEffectContainer {
          GlassCard(padding: 16) {
            VStack(alignment: .leading, spacing: 10) {
              Text([row.pane.session, row.headline].compactMap { $0 }.joined(separator: " · ")).font(.subheadline).foregroundStyle(.secondary)
              SkillPicker(
                load: { try await store.skills(for: row) }, send: { try await store.sendSkill(row, $0) },
                agentName: row.appLabel, cancel: { store.picking = nil }, listHeight: 300)
            }
          }
        }
      } else if store.rows.isEmpty {
        empty
      } else {
        agents
      }
      if let message = store.openError ?? store.lastError {
        Label(message, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.red)
      }
      footer
    }
    .padding(16)
    .frame(width: 400)
  }

  /// Every agent, as in the window: a card for each agent with something to say, most urgent
  /// first, then a strip for each resting one.
  private var agents: some View {
    let resting = store.rows.filter(\.isResting)
    let content = GlassEffectContainer(spacing: 10) {
      VStack(alignment: .leading, spacing: 8) {
        ForEach(store.rows.filter { !$0.isResting }) { row in
          HeroCard(
            row: row, open: { open(row) }, answer: row.questions == nil ? nil : { store.startAnswering(row) },
            skill: row.takesSkills ? { store.picking = row } : nil, decide: { store.decide(row, $0) },
            close: { store.close(row) })
        }
        if !resting.isEmpty {
          SectionHeader(title: "Resting", count: resting.count).padding(.top, 10)
          ForEach(resting) { row in
            RestingStrip(
              row: row, open: { open(row) }, skill: row.takesSkills ? { store.picking = row } : nil,
              close: { store.close(row) })
          }
        }
      }
      .padding(.vertical, 2)
      .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { list.height = $0 }
    }
    return ScrollView { content }
      .frame(height: min(max(list.height, 60), maxListHeight))
      .scrollIndicators(.automatic)
  }

  /// As tall as the screen allows, below the menu bar, leaving room for the header and footer.
  private var maxListHeight: CGFloat {
    let screen = NSScreen.main?.visibleFrame.height ?? 800
    return max(240, screen - 190)
  }

  private var header: some View {
    HStack(alignment: .top) {
      VStack(alignment: .leading, spacing: 2) {
        Text("Rex Radar").font(.title2.weight(.bold))
        HStack(spacing: 5) {
          Circle().fill(summaryColor).frame(width: 7, height: 7)
          Text(summary).font(.subheadline).foregroundStyle(.secondary)
        }
      }
      Spacer()
      CircleButton(symbol: "plus", help: "New Session") { store.creatingSession = true }
      CircleButton(symbol: "arrow.clockwise", help: "Reload") { store.reload() }
      CircleButton(symbol: "macwindow", help: "Open Rex Radar") { showWindow() }
      CircleButton(symbol: "gearshape", help: "Settings") {
        openSettings()
        NSApp.activate()
      }
    }
  }

  private var empty: some View {
    GlassEffectContainer {
      GlassCard {
        VStack(alignment: .leading, spacing: 6) {
          Label("No agents", systemImage: "dot.radiowaves.left.and.right").font(.headline)
          Text("Start a watcher in a Rex pane:").font(.caption).foregroundStyle(.secondary)
          Text("rex do watcher/rex-radar.lua --all source=mac")
            .font(.caption.monospaced()).textSelection(.enabled)
        }
      }
    }
  }

  private var footer: some View {
    HStack {
      Button { showWindow() } label: { Label("Open Rex Radar", systemImage: "macwindow") }
      Spacer()
      Button("Quit") { NSApp.terminate(nil) }
    }
    .buttonStyle(.plain)
    .font(.callout)
    .padding(.horizontal, 4)
  }

  private var summary: String {
    let live = store.sources.joined(separator: " · ")
    let n = store.attentionCount
    let lead = n == 0 ? (store.rows.isEmpty ? "No agents" : "All quiet") : "\(n) need\(n == 1 ? "s" : "") you"
    return live.isEmpty ? lead : "\(lead) · \(live)"
  }

  private var summaryColor: Color { store.topState?.color ?? .secondary }

  /// Closes the panel too: the pane comes up in Rex, and the panel would sit over it.
  private func open(_ row: Row) {
    store.open(row)
    dismiss()
  }

  private func showWindow() {
    openWindow(id: "main")
    NSApp.activate()
  }
}

/// The panel's measured list height (an ObservableObject: SwiftUI's macros need Xcode).
@MainActor
final class ListHeight: ObservableObject {
  @Published var height: CGFloat = 0
}
