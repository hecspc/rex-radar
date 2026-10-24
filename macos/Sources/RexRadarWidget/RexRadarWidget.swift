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
    .supportedFamilies(families)
  }

  private var families: [WidgetFamily] {
    #if os(iOS)
      [.systemSmall, .systemMedium, .systemLarge, .accessoryCircular, .accessoryRectangular, .accessoryInline]
    #else
      [.systemSmall, .systemMedium, .systemLarge]
    #endif
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
    // iOS: the app shares its paired Macs, so the widget fetches fresh agents itself (the app is
    // often not running). macOS: the app is always running and writes the rows for us.
    guard let hubs = WidgetHubs.read(), !hubs.hubs.isEmpty else {
      completion(Timeline(entries: [current()], policy: .after(.now.addingTimeInterval(15 * 60))))
      return
    }
    // WidgetKit calls completion once, from any thread.
    nonisolated(unsafe) let completion = completion
    let fallback = current()
    Task {
      var entry = fallback
      if let rows = await hubs.fetchRows() {
        SharedState.write(rows)
        entry = Entry(date: .now, rows: rows, connected: true)
      }
      completion(Timeline(entries: [entry], policy: .after(.now.addingTimeInterval(5 * 60))))
    }
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
    #if os(iOS)
      case .accessoryCircular: circular
      case .accessoryRectangular: rectangular
      case .accessoryInline: inline
    #endif
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

  #if os(iOS)
    /// Lock Screen: how many agents want you, around the radar glyph.
    private var circular: some View {
      ZStack {
        AccessoryWidgetBackground()
        VStack(spacing: 0) {
          Image(systemName: "dot.radiowaves.left.and.right").font(.caption)
          Text("\(entry.attention)").font(.title3.weight(.bold))
        }
      }
      .widgetURL(entry.rows.first?.openURL)
    }

    /// Lock Screen: the most urgent agent.
    private var rectangular: some View {
      VStack(alignment: .leading, spacing: 1) {
        if let row = entry.rows.first {
          Label(row.stateLabel, systemImage: row.state.symbol).font(.headline)
          Text(row.pane.session ?? "Session").font(.caption).lineLimit(1)
          if let detail = row.pane.msg ?? row.topic { Text(detail).font(.caption2).lineLimit(1) }
        } else {
          Label("Rex Radar", systemImage: "dot.radiowaves.left.and.right").font(.headline)
          Text(entry.connected ? "No agents" : "Open the app").font(.caption)
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .widgetURL(entry.rows.first?.openURL)
    }

    private var inline: some View {
      Label(
        entry.attention > 0 ? "\(entry.attention) agent\(entry.attention == 1 ? "" : "s") want you" : "Agents quiet",
        systemImage: "dot.radiowaves.left.and.right")
    }
  #endif

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
