import WatchConnectivity

/// Hands the paired Macs (with their tokens) to the Apple Watch app, so it needs no pairing of its
/// own. Sent as the application context: the latest one reaches the watch even if its app isn't
/// running, and replaces anything older.
final class WatchSync: NSObject, WCSessionDelegate, @unchecked Sendable {
  static let shared = WatchSync()
  /// A list sent before the session was active; guarded by `lock` (delegate calls come on any thread).
  private var pending: WidgetHubs?
  private let lock = NSLock()

  func activate() {
    guard WCSession.isSupported() else { return }
    WCSession.default.delegate = self
    WCSession.default.activate()
  }

  func send(_ hubs: WidgetHubs) {
    guard WCSession.isSupported() else { return }
    guard WCSession.default.activationState == .activated else {
      lock.withLock { pending = hubs }
      return
    }
    guard WCSession.default.isPaired, WCSession.default.isWatchAppInstalled,
      let data = try? JSONEncoder().encode(hubs)
    else { return }
    try? WCSession.default.updateApplicationContext(["hubs": data])
  }

  func session(_ session: WCSession, activationDidCompleteWith state: WCSessionActivationState, error: Error?) {
    guard state == .activated else { return }
    // Also the current list, not only changes: the watch app may be newly installed.
    let waiting = lock.withLock { () -> WidgetHubs? in
      defer { pending = nil }
      return pending
    }
    if let hubs = waiting ?? WidgetHubs.read() { send(hubs) }
  }

  /// The watch app was just installed (or the watch re-paired): give it the Macs.
  func sessionWatchStateDidChange(_ session: WCSession) {
    if let hubs = WidgetHubs.read() { send(hubs) }
  }

  func sessionDidBecomeInactive(_ session: WCSession) {}
  func sessionDidDeactivate(_ session: WCSession) { session.activate() }
}
