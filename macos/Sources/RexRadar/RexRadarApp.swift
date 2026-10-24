import AppKit
import SwiftUI

@main
struct RexRadarApp: App {
  @StateObject private var store = Store()

  var body: some Scene {
    MenuBarExtra {
      RadarView(store: store)
    } label: {
      MenuBarLabel(store: store)
    }
    .menuBarExtraStyle(.window)
  }
}

struct MenuBarLabel: View {
  @ObservedObject var store: Store

  var body: some View {
    let count = store.attentionCount
    HStack(spacing: 2) {
      Image(systemName: store.topState?.symbol ?? "dot.radiowaves.left.and.right")
      if count > 0 { Text("\(count)") }
    }
  }
}

struct RadarView: View {
  @ObservedObject var store: Store
  /// The Rex app to switch: this Mac's, by its device name. Override with
  /// `defaults write house.milapan.rex-radar clientLabel <label>`.
  @AppStorage("clientLabel") private var clientLabel = Host.current().localizedName ?? ""

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      header
      Divider()
      if store.rows.isEmpty {
        empty
      } else {
        ScrollView {
          VStack(alignment: .leading, spacing: 2) {
            ForEach(store.rows) { row in
              RowView(row: row) { open(row) }
            }
          }
          .padding(6)
        }
        .frame(maxHeight: 420)
      }
      if let message = store.openError ?? store.lastError {
        Divider()
        Text(message).font(.caption).foregroundStyle(.red).padding(8)
      }
      Divider()
      footer
    }
    .frame(width: 360)
  }

  private var header: some View {
    HStack {
      Text("rex-radar").font(.headline)
      Spacer()
      Text(store.sources.isEmpty ? "no watchers" : store.sources.joined(separator: " · "))
        .font(.caption).foregroundStyle(.secondary)
    }
    .padding(10)
  }

  private var empty: some View {
    VStack(alignment: .leading, spacing: 6) {
      Text("No agent panes").font(.subheadline)
      Text("Start a watcher in a Rex pane:\nrex do watcher/rex-radar.lua --all source=mac")
        .font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
    }
    .padding(10)
  }

  private var footer: some View {
    HStack {
      Button("Snapshots") { NSWorkspace.shared.open(store.directory) }
      Spacer()
      Button("Quit") { NSApp.terminate(nil) }
    }
    .buttonStyle(.borderless)
    .font(.caption)
    .padding(8)
  }

  private func open(_ row: Row) {
    store.openError = nil
    let label = clientLabel
    let store = store
    Task.detached {
      do {
        try Rex.open(row, clientLabel: label)
      } catch {
        let message = error.localizedDescription
        await MainActor.run { store.openError = message }
      }
    }
  }
}

struct RowView: View {
  let row: Row
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      HStack(alignment: .top, spacing: 8) {
        Image(systemName: row.state.symbol)
          .foregroundStyle(color)
          .frame(width: 16)
        VStack(alignment: .leading, spacing: 2) {
          HStack {
            Text(row.place).font(.callout).lineLimit(1)
            Spacer()
            Text(row.source + (row.stale ? " · stale" : "")).font(.caption2).foregroundStyle(.secondary)
          }
          if let detail = row.detail {
            Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(2)
          }
        }
      }
      .padding(6)
      .contentShape(Rectangle())
    }
    .buttonStyle(RowButtonStyle())
    .opacity(row.stale ? 0.45 : 1)
    .help(row.pane.kind.map { "\(row.pane.state) (\($0))" } ?? row.pane.state)
  }

  private var color: Color {
    switch row.state {
    case .blocked: .red
    case .error: .orange
    case .done: .green
    case .working: .blue
    case .idle, .unknown: .secondary
    }
  }
}

struct RowButtonStyle: ButtonStyle {
  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .background(
        configuration.isPressed ? Color.primary.opacity(0.12) : Color.primary.opacity(0.03),
        in: RoundedRectangle(cornerRadius: 6))
  }
}
