import AppKit
import SwiftUI

@main
struct RexRadarApp: App {
  @StateObject private var store = Store()

  init() {
    if let dir = Render.directory {
      DispatchQueue.main.async { Render.run(store: Store(), into: dir) }
    }
  }

  var body: some Scene {
    MenuBarExtra {
      MenuPanel(store: store)
    } label: {
      MenuBarLabel(store: store)
    }
    .menuBarExtraStyle(.window)

    Window("Rex Radar", id: "main") {
      MainWindow(store: store)
    }
    .defaultSize(width: 860, height: 560)
  }
}

struct MenuBarLabel: View {
  @ObservedObject var store: Store

  var body: some View {
    let count = store.attentionCount
    HStack(spacing: 3) {
      Image(systemName: store.topState?.symbol ?? "dot.radiowaves.left.and.right")
      if count > 0 { Text("\(count)") }
    }
  }
}
