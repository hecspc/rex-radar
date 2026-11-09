import SwiftUI

#if os(macOS)
  import AppKit
#else
  import UIKit
#endif

/// "● Working · 3m" in the state's colour, on a tinted capsule.
struct StatePill: View {
  let row: Row

  var body: some View {
    // Re-render every half minute so the time in state keeps up.
    TimelineView(.periodic(from: .now, by: 30)) { context in
      HStack(spacing: 5) {
        Circle().fill(row.state.color).frame(width: 7, height: 7)
        Text(row.stale ? "Stale" : row.stateLabel).font(.callout.weight(.semibold))
        if let elapsed = row.elapsed(at: context.date), !row.stale {
          Text(elapsed).font(.callout.monospacedDigit()).opacity(0.75)
        }
      }
    }
    .foregroundStyle(row.state.color)
    .padding(.horizontal, 10)
    .padding(.vertical, 4)
    .background(row.state.color.opacity(0.15), in: Capsule())
  }
}

/// The facts that tell agents in one session apart (branch, folder, tab › pane), each with its
/// symbol, on one line.
struct FactsLine: View {
  let facts: [(symbol: String, text: String)]
  var font: Font = .caption

  var body: some View {
    // Wraps rather than truncating: a long branch or folder takes its own line.
    FlowLayout(spacing: 10, lineSpacing: 3) {
      ForEach(Array(facts.enumerated()), id: \.offset) { _, fact in
        HStack(spacing: 3) {
          Image(systemName: fact.symbol).imageScale(.small)
          Text(fact.text).lineLimit(1).truncationMode(.middle)
        }
      }
    }
    .font(font)
    .foregroundStyle(.secondary)
  }
}

/// Lays its views out left to right, starting a new line when the next doesn't fit. A view wider
/// than the whole line gets the line to itself, at the line's width.
struct FlowLayout: Layout {
  var spacing: CGFloat = 8
  var lineSpacing: CGFloat = 4

  private func arrange(_ subviews: Subviews, width: CGFloat) -> (frames: [CGRect], size: CGSize) {
    var frames: [CGRect] = []
    var x: CGFloat = 0, y: CGFloat = 0, lineHeight: CGFloat = 0, widest: CGFloat = 0
    for view in subviews {
      var size = view.sizeThatFits(.unspecified)
      if size.width > width { size = view.sizeThatFits(ProposedViewSize(width: width, height: nil)) }
      if x > 0, x + size.width > width {
        x = 0
        y += lineHeight + lineSpacing
        lineHeight = 0
      }
      frames.append(CGRect(origin: CGPoint(x: x, y: y), size: size))
      x += size.width + spacing
      lineHeight = max(lineHeight, size.height)
      widest = max(widest, x - spacing)
    }
    return (frames, CGSize(width: widest, height: y + lineHeight))
  }

  func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
    arrange(subviews, width: proposal.width ?? .infinity).size
  }

  func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
    let (frames, _) = arrange(subviews, width: bounds.width)
    for (view, frame) in zip(subviews, frames) {
      view.place(
        at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY), anchor: .topLeading,
        proposal: ProposedViewSize(frame.size))
    }
  }
}

/// Above the resting agents' strips: a title and how many.
struct SectionHeader: View {
  let title: String
  let count: Int

  var body: some View {
    HStack(spacing: 8) {
      Text(title.uppercased()).font(.system(.caption, design: .monospaced).weight(.bold)).tracking(1.2).lineLimit(1)
      Text("\(count)").font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
    }
    .padding(.horizontal, 6)
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
  /// Tints the glass: an agent that needs you.
  var tint: Color? = nil
  @ViewBuilder var content: Content

  var body: some View {
    content
      .padding(padding)
      .frame(maxWidth: .infinity, maxHeight: fillHeight ? .infinity : nil, alignment: .topLeading)
      .glassBackground(in: RoundedRectangle(cornerRadius: 18), tint: tint)
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

/// The agent's state as a radar scope, the app's own instrument: a sweep turns while it works, a
/// contact pings while it needs you, a check marks it done, an empty ring while it rests, and a
/// broken ring when its watcher went quiet. Motion stops with Reduce Motion.
struct Scope: View {
  let row: Row
  var size: CGFloat = 28

  private var color: Color { row.state.color }

  /// What a blocked agent waits on.
  private var glyph: String {
    guard row.state == .blocked else { return "exclamationmark" }
    switch row.pane.kind {
    case "question": return "questionmark"
    case "permission": return "hand.raised.fill"
    case "auth": return "key.fill"
    default: return "exclamationmark"
    }
  }

  var body: some View {
    ZStack {
      if row.stale {
        Circle().strokeBorder(Color.secondary.opacity(0.5), style: StrokeStyle(lineWidth: 1.5, dash: [2, 3]))
      } else {
        switch row.state {
        case .working:
          Circle().strokeBorder(color.opacity(0.35), lineWidth: 1.5)
          Sweep(color: color).padding(2)
          Circle().fill(color).frame(width: size * 0.16, height: size * 0.16)
        case .blocked, .error:
          Ping(color: color)
          Circle().fill(color)
          Image(systemName: glyph).font(.system(size: size * 0.42, weight: .bold)).foregroundStyle(.white)
        case .done:
          Circle().strokeBorder(color.opacity(0.7), lineWidth: 1.5)
          Image(systemName: "checkmark").font(.system(size: size * 0.4, weight: .bold)).foregroundStyle(color)
        case .idle, .unknown:
          Circle().strokeBorder(Color.secondary.opacity(0.35), lineWidth: 1.5)
          Circle().fill(Color.secondary.opacity(0.45)).frame(width: size * 0.14, height: size * 0.14)
        }
      }
    }
    .frame(width: size, height: size)
    .accessibilityElement()
    .accessibilityLabel(row.stale ? "Stale" : row.stateLabel)
  }
}

/// The working scope's beam: a quarter of the dial fading in behind the leading edge, one turn
/// every 2.4 s. Driven by the clock rather than a repeating animation, which would also animate
/// the scope's position as cards move.
private struct Sweep: View {
  let color: Color
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    TimelineView(.animation(minimumInterval: 1 / 30, paused: reduceMotion)) { context in
      let turn = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 2.4) / 2.4
      Circle()
        .fill(AngularGradient(
          stops: [.init(color: color.opacity(0), location: 0.72), .init(color: color.opacity(0.85), location: 1)],
          center: .center))
        .rotationEffect(.degrees(reduceMotion ? 45 : turn * 360))
    }
  }
}

/// The ring a contact sends out every 1.6 s while the agent needs you.
private struct Ping: View {
  let color: Color
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    if !reduceMotion {
      TimelineView(.animation(minimumInterval: 1 / 30)) { context in
        let t = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.6) / 1.6
        let eased = 1 - (1 - t) * (1 - t)
        Circle()
          .stroke(color, lineWidth: 1.5)
          .scaleEffect(1 + 0.8 * eased)
          .opacity(0.8 * (1 - eased))
      }
    }
  }
}

/// The line above a card's headline: its state and how long it has been in it, in its colour.
struct StateEyebrow: View {
  let row: Row

  var body: some View {
    TimelineView(.periodic(from: .now, by: 30)) { context in
      Text(
        (row.stale ? ["Stale"] : [row.stateLabel, row.elapsed(at: context.date)].compactMap { $0 })
          .joined(separator: " · ").uppercased()
      )
      .font(.system(.caption2, design: .monospaced).weight(.semibold))
      .tracking(0.8)
      .lineLimit(1)
      .minimumScaleFactor(0.7)
      .foregroundStyle(row.stale || row.state == .idle || row.state == .unknown ? Color.secondary : row.state.color)
    }
  }
}

/// A view's own flag, such as whether the pointer is over it. An ObservableObject rather than
/// @State: SwiftUI's macros need Xcode, and the Mac app also builds with SwiftPM.
@MainActor
final class ViewFlag: ObservableObject {
  @Published var on = false
}

/// A small round icon button for a card's corner.
struct CardIconButton: View {
  let symbol: String
  let help: String
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      Image(systemName: symbol).font(.caption.weight(.semibold)).frame(width: 24, height: 24)
    }
    .glassButtonStyle()
    .buttonBorderShape(.circle)
    .controlSize(.small)
    .help(help)
    .accessibilityLabel(help)
  }
}

/// The corner's close button: the first press arms it (a red "Close"), a second within 3 s closes
/// the agent's pane, ending the agent.
struct CloseButton: View {
  let agent: String
  let close: () -> Void
  @StateObject private var armed = ViewFlag()

  var body: some View {
    if armed.on {
      Button(role: .destructive) {
        armed.on = false
        close()
      } label: {
        Text("Close").font(.caption.weight(.semibold)).padding(.horizontal, 4)
      }
      .glassProminentButtonStyle()
      .tint(.red)
      .controlSize(.small)
      .help("Ends \(agent) and closes its pane in Rex")
      .task {
        try? await Task.sleep(for: .seconds(3))
        armed.on = false
      }
    } else {
      CardIconButton(symbol: "xmark", help: "Close: ends \(agent) and closes its pane in Rex") { armed.on = true }
    }
  }
}

/// Whether an agent shows as a full card or a one-line strip: resting agents (idle, and done ones
/// faded to idle, and stale ones) have nothing to tell you beyond which they are.
extension Row {
  var isResting: Bool { (stale || state == .idle || state == .unknown) && permission == nil && questions == nil }
}

/// An agent as a card: its scope, its state and time in it, what tells it apart from the others in
/// its session (topic or tab, then branch, folder and tab › pane), what it says or asks, and the
/// buttons it needs. A click anywhere on the card opens it in Rex.
struct HeroCard: View {
  let row: Row
  let open: () -> Void
  /// Set when the questions can be answered from here: shows "Answer N questions".
  var answer: (() -> Void)? = nil
  /// Set when a skill can be sent to it from here: shows a Skill button in the corner.
  var skill: (() -> Void)? = nil
  /// Set when its permission can be allowed or denied from here: shows Allow and Deny.
  var decide: ((PermissionDecision) -> Void)? = nil
  /// Set when its pane can be closed from here: shows a close button in the corner.
  var close: (() -> Void)? = nil
  /// In a grid: as tall as the row, with the buttons along the bottom.
  var fillHeight = false
  /// Names the session on the card.
  var showSession = true

  @StateObject private var hover = ViewFlag()

  private var facts: [(symbol: String, text: String)] {
    row.facts(session: showSession) + row.machineFacts
  }

  var body: some View {
    GlassCard(padding: 16, fillHeight: fillHeight, tint: row.state.needsAttention && !row.stale ? row.state.color : nil) {
      HStack(alignment: .top, spacing: 14) {
        Scope(row: row, size: 30).padding(.top, 2)
        VStack(alignment: .leading, spacing: 10) {
          VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .center, spacing: 6) {
              StateEyebrow(row: row)
              Spacer(minLength: 6)
              AgentIcon(row: row, size: 15).help(row.appLabel)
              if let skill { CardIconButton(symbol: "wand.and.stars", help: "Send a skill to \(row.appLabel)", action: skill) }
              CardIconButton(symbol: "arrow.up.forward", help: "Open in Rex", action: open)
              if let close { CloseButton(agent: row.appLabel, close: close) }
            }
            Text(row.headline)
              .font(.title3.weight(.semibold))
              .lineLimit(2)
              .fixedSize(horizontal: false, vertical: true)
            if !facts.isEmpty { FactsLine(facts: facts, font: .caption.monospaced()).padding(.top, 1) }
          }
          if let permission = row.permission {
            PermissionPrompt(permission: permission)
          } else if let question = row.questions?.questions.first {
            Quote(text: question.question, color: row.state.color)
          } else if let message = row.message {
            Quote(text: message, color: row.state == .error ? row.state.color : .secondary)
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
        }
      }
    }
    .overlay {
      RoundedRectangle(cornerRadius: 18).strokeBorder(Color.primary.opacity(hover.on ? 0.18 : 0), lineWidth: 1)
    }
    .contentShape(RoundedRectangle(cornerRadius: 18))
    .onTapGesture(perform: open)
    #if os(macOS) || os(iOS)
      .onHover { hover.on = $0 }
    #endif
    .opacity(row.stale ? 0.5 : 1)
  }
}

/// A resting agent as one line: its scope, what it is, where, and how long it has rested. A click
/// opens it in Rex; the context menu sends a skill.
struct RestingStrip: View {
  let row: Row
  let open: () -> Void
  var skill: (() -> Void)? = nil
  /// Set when its pane can be closed from here: in the context menu.
  var close: (() -> Void)? = nil
  /// Names the session; off to show the branch or folder instead.
  var showSession = true

  @StateObject private var hover = ViewFlag()

  private var place: String? {
    let fact = showSession ? row.pane.session : row.facts(session: false).first?.text
    return [fact, row.machineLabel].compactMap { $0 }.joined(separator: " · ")
  }

  var body: some View {
    Button(action: open) {
      HStack(spacing: 10) {
        Scope(row: row, size: 16)
        Text(row.headline).font(.callout.weight(.semibold)).lineLimit(1).layoutPriority(1)
        Spacer(minLength: 6)
        if let place, !place.isEmpty {
          Text(place).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
        }
        TimelineView(.periodic(from: .now, by: 30)) { context in
          Text(row.stale ? "stale" : row.elapsed(at: context.date) ?? "")
            .font(.caption.monospaced()).foregroundStyle(.tertiary)
        }
        AgentIcon(row: row, size: 13).help(row.appLabel)
      }
      .padding(.horizontal, 12)
      .padding(.vertical, 9)
      .frame(maxWidth: .infinity, alignment: .leading)
      // Flat, not glass: resting agents stay quiet, and glass this close would merge.
      .background(Color.primary.opacity(hover.on ? 0.08 : 0.045), in: RoundedRectangle(cornerRadius: 12))
      .overlay {
        RoundedRectangle(cornerRadius: 12).strokeBorder(Color.primary.opacity(hover.on ? 0.16 : 0.07), lineWidth: 1)
      }
      .contentShape(RoundedRectangle(cornerRadius: 12))
    }
    .buttonStyle(.plain)
    #if os(macOS) || os(iOS)
      .onHover { hover.on = $0 }
    #endif
    .contextMenu {
      Button("Open in Rex", systemImage: "arrow.up.forward.app", action: open)
      if let skill { Button("Send Skill…", systemImage: "wand.and.stars", action: skill) }
      if let close {
        Divider()
        Button("Close", systemImage: "xmark", role: .destructive, action: close)
      }
    }
    .opacity(row.stale ? 0.5 : 1)
  }
}

/// What the agent says or asks, set off by a rule in its colour.
struct Quote: View {
  let text: String
  var color: Color = .secondary
  var lineLimit = 3

  var body: some View {
    HStack(alignment: .top, spacing: 8) {
      RoundedRectangle(cornerRadius: 1).fill(color.opacity(0.6)).frame(width: 3)
      Text(text).font(.callout).foregroundStyle(.secondary).lineLimit(lineLimit)
        .fixedSize(horizontal: false, vertical: true)
    }
    .fixedSize(horizontal: false, vertical: true)
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
  /// Names the session in the row; off when the list is already grouped by session.
  var showSession = true

  var body: some View {
    Button(action: open) {
      HStack(alignment: .top, spacing: 10) {
        Scope(row: row, size: 20).padding(.top, 1)
        VStack(alignment: .leading, spacing: 3) {
          HStack(spacing: 6) {
            AgentIcon(row: row, size: 13).help(row.appLabel)
            Text(row.headline).font(.callout.weight(.semibold)).lineLimit(1)
            Spacer(minLength: 4)
            Text(row.stale ? "stale" : [row.stateLabel, row.elapsed()].compactMap { $0 }.joined(separator: " · "))
              .font(.caption).foregroundStyle(row.state.color).lineLimit(1)
          }
          let facts = row.facts(session: showSession)
          if !facts.isEmpty { FactsLine(facts: Array(facts.prefix(3)), font: .caption2) }
          if let detail = row.permission?.prompt ?? row.questions?.questions.first?.question ?? row.message {
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
