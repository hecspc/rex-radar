import SwiftUI

// Liquid Glass where the system has it (iOS/iPadOS/macOS/tvOS 26), the frosted material before.
// The iOS and tvOS apps support 17, so shared views go through these rather than the glass APIs.

extension View {
  /// A glass (or frosted) background in the given shape.
  @ViewBuilder
  func glassBackground<S: Shape>(in shape: S) -> some View {
    if #available(iOS 26, macOS 26, watchOS 26, tvOS 26, *) {
      glassEffect(.regular, in: shape)
    } else {
      background(.regularMaterial, in: shape)
    }
  }

  /// The same, tinted: cards of agents that need you take their state's colour.
  @ViewBuilder
  func glassBackground<S: Shape>(in shape: S, tint: Color?) -> some View {
    if #available(iOS 26, macOS 26, watchOS 26, tvOS 26, *) {
      glassEffect(.regular.tint(tint?.opacity(0.18)), in: shape)
    } else {
      background {
        ZStack {
          shape.fill(.regularMaterial)
          if let tint { shape.fill(tint.opacity(0.1)) }
        }
      }
    }
  }

  /// The glass button style, or the bordered one.
  @ViewBuilder
  func glassButtonStyle() -> some View {
    if #available(iOS 26, macOS 26, watchOS 26, tvOS 26, *) {
      buttonStyle(.glass)
    } else {
      buttonStyle(.bordered)
    }
  }

  /// The prominent glass button style, or the prominent bordered one.
  @ViewBuilder
  func glassProminentButtonStyle() -> some View {
    if #available(iOS 26, macOS 26, watchOS 26, tvOS 26, *) {
      buttonStyle(.glassProminent)
    } else {
      buttonStyle(.borderedProminent)
    }
  }
}

/// GlassEffectContainer (glass shapes near each other blend), or just the content.
struct GlassGroup<Content: View>: View {
  var spacing: CGFloat?
  @ViewBuilder var content: Content

  var body: some View {
    if #available(iOS 26, macOS 26, watchOS 26, tvOS 26, *) {
      GlassEffectContainer(spacing: spacing) { content }
    } else {
      content
    }
  }
}
