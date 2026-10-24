import Foundation

/// A Rex server the app watches. `address` is what `rex -S` takes (a host label from `rex hosts`,
/// or a URL); nil is this Mac's own server.
struct ServerConfig: Codable, Identifiable, Hashable {
  var id = UUID()
  /// The source name agents carry; also the snapshot's file name.
  var name: String
  var address: String?

  var isLocal: Bool { address?.isEmpty ?? true }
}

/// Runs one watcher (watcher/rex-radar.lua) per configured server as a child `rex do` process,
/// and restarts any that exit, waiting longer after repeated failures.
@MainActor
final class Watchers: ObservableObject {
  static let shared = Watchers()

  @Published private(set) var servers: [ServerConfig]
  /// Per server: "running", or why it isn't.
  @Published private(set) var status: [UUID: String] = [:]

  private var processes: [UUID: Process] = [:]
  private var failures: [UUID: Int] = [:]
  private var stopping: Set<UUID> = []

  private static let defaultsKey = "servers"

  init() {
    if let data = UserDefaults.standard.data(forKey: Self.defaultsKey),
      let saved = try? JSONDecoder().decode([ServerConfig].self, from: data)
    {
      servers = saved
    } else {
      servers = [ServerConfig(name: "mac", address: nil)]
    }
  }

  /// The watcher script: in the app's resources, else next to the repo checkout (development).
  static var script: URL? {
    if let url = Bundle.main.url(forResource: "rex-radar", withExtension: "lua") { return url }
    let dev = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
      .deletingLastPathComponent().appendingPathComponent("watcher/rex-radar.lua")
    return FileManager.default.fileExists(atPath: dev.path) ? dev : nil
  }

  func startAll() { servers.forEach(start) }

  func add(name: String, address: String?) {
    let name = name.trimmingCharacters(in: .whitespaces)
    let address = address?.trimmingCharacters(in: .whitespaces)
    guard !name.isEmpty, !servers.contains(where: { $0.name == name }) else { return }
    let server = ServerConfig(name: name, address: (address?.isEmpty ?? true) ? nil : address)
    servers.append(server)
    save()
    start(server)
  }

  func remove(_ server: ServerConfig) {
    stop(server)
    servers.removeAll { $0.id == server.id }
    save()
    // Its agents leave the list with its snapshot.
    try? FileManager.default.removeItem(at: Store.shared.directory.appendingPathComponent("\(server.name).json"))
    Store.shared.reload()
  }

  private func save() {
    UserDefaults.standard.set(try? JSONEncoder().encode(servers), forKey: Self.defaultsKey)
  }

  private func start(_ server: ServerConfig) {
    guard processes[server.id] == nil else { return }
    guard let rex = Rex.executable else { status[server.id] = "can't find the rex CLI"; return }
    guard let script = Self.script else { status[server.id] = "watcher script missing"; return }

    let process = Process()
    process.executableURL = URL(fileURLWithPath: rex)
    var args = [String]()
    if let address = server.address, !server.isLocal { args += ["-S", address] }
    args += ["do", script.path, "--all", "source=\(server.name)", "out=\(Store.shared.directory.path)"]
    if let address = server.address, !server.isLocal { args.append("server=\(address)") }
    process.arguments = args
    let errors = Pipe()
    process.standardError = errors
    process.standardOutput = FileHandle.nullDevice
    // The last line rex printed explains a failure ("connection refused", a Lua error…).
    let lastLine = LastLine()
    errors.fileHandleForReading.readabilityHandler = { handle in lastLine.append(handle.availableData) }
    process.terminationHandler = { [weak self] p in
      let reason = lastLine.value ?? "exited (\(p.terminationStatus))"
      Task { @MainActor in self?.exited(server, reason: reason) }
    }
    do {
      try process.run()
      processes[server.id] = process
      status[server.id] = "running"
    } catch {
      status[server.id] = error.localizedDescription
    }
  }

  private func stop(_ server: ServerConfig) {
    guard let process = processes.removeValue(forKey: server.id) else { return }
    stopping.insert(server.id)
    process.terminate()
    status[server.id] = nil
  }

  private func exited(_ server: ServerConfig, reason: String) {
    processes[server.id] = nil
    if stopping.remove(server.id) != nil { return }
    guard servers.contains(where: { $0.id == server.id }) else { return }
    let n = (failures[server.id] ?? 0) + 1
    failures[server.id] = n
    let delay = min(60.0, pow(2.0, Double(min(n, 6))))
    status[server.id] = "\(reason) · retrying in \(Int(delay)) s"
    Task {
      try? await Task.sleep(for: .seconds(delay))
      guard let current = servers.first(where: { $0.id == server.id }) else { return }
      start(current)
      // A watcher that stays up for a minute counts as healthy again.
      try? await Task.sleep(for: .seconds(60))
      if processes[server.id] != nil { failures[server.id] = 0 }
    }
  }

  /// Host labels from `rex hosts`, to suggest when adding a server.
  nonisolated static func knownHosts() -> [String] {
    guard let rex = Rex.executable else { return [] }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: rex)
    process.arguments = ["hosts", "--json"]
    let out = Pipe()
    process.standardOutput = out
    process.standardError = FileHandle.nullDevice
    guard (try? process.run()) != nil else { return [] }
    let data = out.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    return (json?["hosts"] as? [[String: Any]] ?? []).compactMap { $0["label"] as? String }
  }
}

/// Collects a process's stderr and keeps its last non-empty line.
private final class LastLine: @unchecked Sendable {
  private let lock = NSLock()
  private var buffer = ""
  private(set) var value: String?

  func append(_ data: Data) {
    guard !data.isEmpty else { return }
    lock.lock()
    defer { lock.unlock() }
    buffer += String(decoding: data, as: UTF8.self)
    let lines = buffer.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    if let last = lines.last { value = String(last.prefix(160)) }
    buffer = String(buffer.suffix(4096))
  }
}
