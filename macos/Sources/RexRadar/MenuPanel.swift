import AppKit
import SwiftUI

struct MenuPanel: View {
  @ObservedObject var store: Store
  @Environment(\.openWindow) private var openWindow

  var body: some View {
    GlassEffectContainer(spacing: 12) {
      VStack(alignment: .leading, spacing: 12) {
        header
        if let hero = store.rows.first {
          HeroCard(row: hero) { store.open(hero) }
          let rest = Array(store.rows.dropFirst())
          if !rest.isEmpty { others(rest) }
        } else {
          empty
        }
        if let message = store.openError ?? store.lastError {
          Label(message, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.red)
        }
        footer
      }
      .padding(16)
    }
    .frame(width: 380)
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
      CircleButton(symbol: "arrow.clockwise", help: "Reload") { store.reload() }
      CircleButton(symbol: "macwindow", help: "Open Rex Radar") { showWindow() }
    }
  }

  /// The other agents, one card per server.
  private func others(_ rows: [Row]) -> some View {
    let content = VStack(alignment: .leading, spacing: 12) {
      ForEach(Dictionary(grouping: rows, by: \.source).sorted { $0.key < $1.key }, id: \.key) { source, rows in
        GlassCard {
          VStack(alignment: .leading, spacing: 4) {
            Text(source.uppercased()).font(.caption.weight(.semibold)).foregroundStyle(.secondary).tracking(1)
            ForEach(rows) { row in AgentRow(row: row) { store.open(row) } }
          }
        }
      }
    }
    // A ScrollView in a menu bar window has no height of its own: size it to its rows.
    return ScrollView { content }
      .frame(height: min(CGFloat(rows.count) * 58 + 40, 360))
      .scrollIndicators(.never)
  }

  private var empty: some View {
    GlassCard {
      VStack(alignment: .leading, spacing: 6) {
        Label("No agents", systemImage: "dot.radiowaves.left.and.right").font(.headline)
        Text("Start a watcher in a Rex pane:").font(.caption).foregroundStyle(.secondary)
        Text("rex do watcher/rex-radar.lua --all source=mac")
          .font(.caption.monospaced()).textSelection(.enabled)
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

  private func showWindow() {
    openWindow(id: "main")
    NSApp.activate()
  }
}
