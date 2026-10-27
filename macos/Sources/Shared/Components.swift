import SwiftUI

#if os(macOS)
  import AppKit
#else
  import UIKit
#endif

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

/// Which agent it is: its logo, or its symbol in its colour when this build has no logo for it.
struct AgentIcon: View {
  let row: Row
  var size: CGFloat = 14

  private var hasLogo: Bool {
    guard let name = row.appImage else { return false }
    #if os(macOS)
      return NSImage(named: name) != nil
    #else
      return UIImage(named: name) != nil
    #endif
  }

  var body: some View {
    if hasLogo, let name = row.appImage {
      Image(name).resizable().interpolation(.high).scaledToFit().frame(width: size, height: size)
        .accessibilityLabel(row.appLabel)
    } else {
      Image(systemName: row.appSymbol).font(.system(size: size * 0.8, weight: .bold)).foregroundStyle(row.appColor)
        .frame(width: size, height: size).accessibilityLabel(row.appLabel)
    }
  }
}

/// The agent's icon, then its name: Claude Code, Codex, Antigravity, Qoder, Pi.
struct AppBadge: View {
  let row: Row
  var size: CGFloat = 14

  var body: some View {
    HStack(spacing: 5) {
      AgentIcon(row: row, size: size)
      Text(row.appLabel).foregroundStyle(.secondary)
    }
    .font(.caption)
  }
}

/// A rounded glass card, the panel's and window's building block.
struct GlassCard<Content: View>: View {
  var padding: CGFloat = 14
  /// Grow to the height it's offered (a grid row's), content at the top.
  var fillHeight = false
  @ViewBuilder var content: Content

  var body: some View {
    content
      .padding(padding)
      .frame(maxWidth: .infinity, maxHeight: fillHeight ? .infinity : nil, alignment: .topLeading)
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
  /// Set when its permission can be allowed or denied from here: shows Allow and Deny.
  var decide: ((PermissionDecision) -> Void)? = nil
  /// In a grid: as tall as the row, with the buttons along the bottom.
  var fillHeight = false

  var body: some View {
    GlassCard(padding: 16, fillHeight: fillHeight) {
      VStack(alignment: .leading, spacing: 10) {
        HStack(alignment: .top) {
          StatePill(row: row)
          Spacer()
          AppBadge(row: row)
        }
        VStack(alignment: .leading, spacing: 2) {
          Text(row.pane.session ?? "Session").font(.title3.weight(.semibold)).lineLimit(1)
          Text([row.tabLabel, row.source].filter { !$0.isEmpty }.joined(separator: " · "))
            .font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
        }
        if let topic = row.topic {
          Label(topic, systemImage: "bubble.left").font(.callout).lineLimit(1)
        }
        if let permission = row.permission {
          PermissionPrompt(permission: permission)
        } else if let msg = row.pane.msg, !msg.isEmpty {
          Text(msg).font(.callout).foregroundStyle(.secondary).lineLimit(3).fixedSize(horizontal: false, vertical: true)
        }
        if fillHeight { Spacer(minLength: 0) }
        if let decide, row.permission != nil {
          HStack {
            Button { decide(.allow) } label: { Label("Allow", systemImage: "checkmark").frame(maxWidth: .infinity) }
              .glassProminentButtonStyle()
              .help("Yes, this once: presses 1 in the pane")
            Button { decide(.deny) } label: { Label("Deny", systemImage: "xmark").frame(maxWidth: .infinity) }
              .glassButtonStyle()
              .help("No: presses Esc in the pane")
          }
          .controlSize(.large)
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
              .help("Send a skill to \(row.appLabel)")
          }
        }
        .glassButtonStyle()
        .controlSize(.large)
      }
    }
    .opacity(row.stale ? 0.5 : 1)
  }
}

/// What a blocked agent asks permission for, as a quoted block: often a command.
struct PermissionPrompt: View {
  let permission: PendingPermission
  var lineLimit = 6

  var body: some View {
    Text(permission.prompt)
      .font(.callout.monospaced())
      .lineLimit(lineLimit)
      .fixedSize(horizontal: false, vertical: true)
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(10)
      .background(.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
  }
}

/// One agent as a compact row; the whole row opens it.
struct AgentRow: View {
  let row: Row
  let open: () -> Void
  /// Set when a skill can be sent to it from here: in the row's context menu.
  var skill: (() -> Void)? = nil
  /// Set when its permission can be allowed or denied from here: in the context menu too.
  var decide: ((PermissionDecision) -> Void)? = nil

  var body: some View {
    Button(action: open) {
      HStack(alignment: .top, spacing: 10) {
        Image(systemName: row.state.symbol)
          .font(.title3)
          .foregroundStyle(row.state.color)
          .frame(width: 22)
        VStack(alignment: .leading, spacing: 2) {
          HStack(spacing: 6) {
            AgentIcon(row: row, size: 13).help(row.appLabel)
            Text(row.pane.session ?? "Session").font(.callout.weight(.medium)).lineLimit(1)
            Text(row.tabLabel).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            Spacer(minLength: 4)
            Text(row.stale ? "stale" : row.stateLabel).font(.caption).foregroundStyle(row.state.color)
          }
          if let detail = row.permission?.prompt ?? row.pane.msg.flatMap({ $0.isEmpty ? nil : $0 }) ?? row.topic {
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
      if let decide, row.permission != nil {
        Button("Allow", systemImage: "checkmark") { decide(.allow) }
        Button("Deny", systemImage: "xmark") { decide(.deny) }
      }
    }
    .opacity(row.stale ? 0.5 : 1)
  }
}
