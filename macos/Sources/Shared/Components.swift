import SwiftUI

/// "● Done" in the state's colour, on a tinted capsule.
struct StatePill: View {
  let row: Row

  var body: some View {
    HStack(spacing: 5) {
      Circle().fill(row.state.color).frame(width: 7, height: 7)
      Text(row.stateLabel).font(.callout.weight(.semibold))
    }
    .foregroundStyle(row.state.color)
    .padding(.horizontal, 10)
    .padding(.vertical, 4)
    .background(row.state.color.opacity(0.15), in: Capsule())
  }
}

/// A rounded glass card, the panel's and window's building block.
struct GlassCard<Content: View>: View {
  var padding: CGFloat = 14
  @ViewBuilder var content: Content

  var body: some View {
    content
      .padding(padding)
      .frame(maxWidth: .infinity, alignment: .leading)
      .glassBackground(in: RoundedRectangle(cornerRadius: 18))
  }
}

/// A round glass icon button, like the panel's refresh and window buttons.
struct CircleButton: View {
  let symbol: String
  let help: String
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      Image(systemName: symbol).font(.body.weight(.medium)).frame(width: 30, height: 30)
    }
    .glassButtonStyle()
    .buttonBorderShape(.circle)
    .help(help)
  }
}

/// The most urgent agent, big: pill, where it runs, topic, summary, and Open.
struct HeroCard: View {
  let row: Row
  let open: () -> Void
  /// Set when the questions can be answered from here: shows "Answer N questions".
  var answer: (() -> Void)? = nil
  /// Set when a skill can be sent to it from here: shows a Skill button beside Open.
  var skill: (() -> Void)? = nil

  var body: some View {
    GlassCard(padding: 16) {
      VStack(alignment: .leading, spacing: 10) {
        HStack(alignment: .top) {
          StatePill(row: row)
          Spacer()
          Text(row.appLabel).font(.caption).foregroundStyle(.secondary)
        }
        VStack(alignment: .leading, spacing: 2) {
          Text(row.pane.session ?? "Session").font(.title3.weight(.semibold)).lineLimit(1)
          Text([row.tabLabel, row.source].filter { !$0.isEmpty }.joined(separator: " · "))
            .font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
        }
        if let topic = row.topic {
          Label(topic, systemImage: "bubble.left").font(.callout).lineLimit(1)
        }
        if let msg = row.pane.msg, !msg.isEmpty {
          Text(msg).font(.callout).foregroundStyle(.secondary).lineLimit(3).fixedSize(horizontal: false, vertical: true)
        }
        if let answer, let n = row.questions?.questions.count {
          Button(action: answer) {
            Label("Answer \(n) question\(n == 1 ? "" : "s")", systemImage: "questionmark.bubble").frame(maxWidth: .infinity)
          }
          .glassProminentButtonStyle()
          .controlSize(.large)
        }
        HStack {
          Button(action: open) {
            Label("Open in Rex", systemImage: "arrow.up.forward.app").frame(maxWidth: .infinity)
          }
          if let skill {
            Button(action: skill) { Label("Skill", systemImage: "wand.and.stars") }
              .help("Send a skill to Claude")
          }
        }
        .glassButtonStyle()
        .controlSize(.large)
      }
    }
    .opacity(row.stale ? 0.5 : 1)
  }
}

/// One agent as a compact row; the whole row opens it.
struct AgentRow: View {
  let row: Row
  let open: () -> Void
  /// Set when a skill can be sent to it from here: in the row's context menu.
  var skill: (() -> Void)? = nil

  var body: some View {
    Button(action: open) {
      HStack(alignment: .top, spacing: 10) {
        Image(systemName: row.state.symbol)
          .font(.title3)
          .foregroundStyle(row.state.color)
          .frame(width: 22)
        VStack(alignment: .leading, spacing: 2) {
          HStack(spacing: 6) {
            Text(row.pane.session ?? "Session").font(.callout.weight(.medium)).lineLimit(1)
            Text(row.tabLabel).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            Spacer(minLength: 4)
            Text(row.stale ? "stale" : row.stateLabel).font(.caption).foregroundStyle(row.state.color)
          }
          if let detail = row.pane.msg.flatMap({ $0.isEmpty ? nil : $0 }) ?? row.topic {
            Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(2)
          }
        }
      }
      .padding(.vertical, 6)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .contextMenu {
      Button("Open in Rex", systemImage: "arrow.up.forward.app", action: open)
      if let skill { Button("Send Skill…", systemImage: "wand.and.stars", action: skill) }
    }
    .opacity(row.stale ? 0.5 : 1)
  }
}
