import Foundation

/// The branch checked out in a directory on this Mac, read from git's files (no git process): the
/// nearest `.git` above it, a directory or, in a worktree, a file naming the worktree's git dir.
enum GitBranch {
  @MainActor private static var cache: [String: (branch: String?, at: Date)] = [:]
  private static let ttl: TimeInterval = 10

  /// The branch, or a short commit when detached. Called from the main actor every reload, so cached.
  @MainActor static func of(_ cwd: String) -> String? {
    if let hit = cache[cwd], Date().timeIntervalSince(hit.at) < ttl { return hit.branch }
    let branch = read(cwd)
    cache[cwd] = (branch, Date())
    return branch
  }

  private static func read(_ cwd: String) -> String? {
    let fm = FileManager.default
    var dir = URL(fileURLWithPath: cwd).standardizedFileURL
    while dir.path != "/" {
      let git = dir.appendingPathComponent(".git")
      var isDir: ObjCBool = false
      if fm.fileExists(atPath: git.path, isDirectory: &isDir) {
        var gitDir = git
        if !isDir.boolValue {
          // A worktree or submodule: "gitdir: <path>".
          guard let text = try? String(contentsOf: git, encoding: .utf8), text.hasPrefix("gitdir:") else { return nil }
          let path = text.dropFirst(7).trimmingCharacters(in: .whitespacesAndNewlines)
          gitDir = URL(fileURLWithPath: path, relativeTo: dir).standardizedFileURL
        }
        guard let head = try? String(contentsOf: gitDir.appendingPathComponent("HEAD"), encoding: .utf8)
          .trimmingCharacters(in: .whitespacesAndNewlines)
        else { return nil }
        if head.hasPrefix("ref: refs/heads/") { return String(head.dropFirst(16)) }
        return head.isEmpty ? nil : String(head.prefix(7))
      }
      dir.deleteLastPathComponent()
    }
    return nil
  }
}
