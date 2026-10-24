import SwiftUI
import WidgetKit

@main
struct RexRadarWidgets: WidgetBundle {
  var body: some Widget { AgentsWidget() }
}

struct AgentsWidget: Widget {
  var body: some WidgetConfiguration {
    StaticConfiguration(kind: "RexRadarAgents", provider: Provider()) { entry in
      AgentsView(entry: entry).containerBackground(.fill.tertiary, for: .widget)
    }
    .configurationDisplayName("Rex Radar")
    .description("Your coding agents in Rex, most urgent first.")
    .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
  }
}

struct Entry: TimelineEntry {
  var date: Date
  var rows: [Row]
  var connected: Bool

  var live: [Row] { rows.filter { !$0.stale } }
  var attention: Int { live.filter(\.state.needsAttention).count }
  var top: AgentState? { live.map(\.state).min() }

  static let placeholder = Entry(date: .now, rows: [], connected: true)
}

/// The app reloads the timeline whenever the agents change; the refresh below is only a fallback.
struct Provider: TimelineProvider {
  func placeholder(in context: Context) -> Entry { .placeholder }

  func getSnapshot(in context: Context, completion: @escaping (Entry) -> Void) { completion(current()) }

  func getTimeline(in context: Context, completion: @escaping (Timeline<Entry>) -> Void) {
    completion(Timeline(entries: [current()], policy: .after(.now.addingTimeInterval(15 * 60))))
  }

  private func current() -> Entry {
    guard let state = SharedState.read() else { return Entry(date: .now, rows: [], connected: false) }
    return Entry(date: state.writtenAt, rows: state.rows, connected: true)
  }
}

struct AgentsView: View {
  let entry: Entry
  @Environment(\.widgetFamily) private var family

  var body: some View {
    switch family {
    case .systemSmall: small
    default: list(limit: family == .systemLarge ? 7 : 3)
    }
  }

  private var header: some View {
    HStack(spacing: 6) {
      Image(systemName: "dot.radiowaves.left.and.right")
      Text("Rex Radar").font(.headline)
      Spacer()
      if entry.attention > 0 {
        Text("\(entry.attention)")
          .font(.caption.weight(.bold))
          .padding(.horizontal, 7)
          .padding(.vertical, 2)
          .background((entry.top?.color ?? .secondary).opacity(0.25), in: Capsule())
      }
    }
  }

  private var small: some View {
    VStack(alignment: .leading, spacing: 6) {
      header
      Spacer(minLength: 0)
      if let row = entry.rows.first {
        Image(systemName: row.state.symbol).font(.title2).foregroundStyle(row.state.color)
        Text(row.stateLabel).font(.subheadline.weight(.semibold)).foregroundStyle(row.state.color)
        Text(row.pane.session ?? "Session").font(.caption).lineLimit(1)
        if let detail = row.pane.msg ?? row.topic {
          Text(detail).font(.caption2).foregroundStyle(.secondary).lineLimit(2)
        }
      } else {
        emptyText
      }
    }
    .widgetURL(entry.rows.first?.openURL)
  }

  private func list(limit: Int) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      header
      if entry.rows.isEmpty {
        Spacer(minLength: 0)
        emptyText
        Spacer(minLength: 0)
      } else {
        ForEach(entry.rows.prefix(limit)) { row in
          Link(destination: row.openURL ?? URL(string: "rexradar://")!) { WidgetRow(row: row) }
        }
        Spacer(minLength: 0)
        if entry.rows.count > limit {
          Text("+\(entry.rows.count - limit) more").font(.caption2).foregroundStyle(.secondary)
        }
      }
    }
  }

  private var emptyText: some View {
    Text(entry.connected ? "No agents running" : "Open Rex Radar to connect")
      .font(.caption).foregroundStyle(.secondary)
  }
}

struct WidgetRow: View {
  let row: Row

  var body: some View {
    HStack(alignment: .top, spacing: 8) {
      Image(systemName: row.state.symbol).foregroundStyle(row.state.color).frame(width: 16)
      VStack(alignment: .leading, spacing: 1) {
        HStack(spacing: 4) {
          Text(row.pane.session ?? "Session").font(.caption.weight(.semibold)).lineLimit(1)
          Text(row.tabLabel).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
          Spacer(minLength: 2)
          Text(row.stale ? "stale" : row.stateLabel).font(.caption2).foregroundStyle(row.state.color)
        }
        if let detail = row.pane.msg ?? row.topic {
          Text(detail).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
        }
      }
    }
    .opacity(row.stale ? 0.5 : 1)
  }
}
