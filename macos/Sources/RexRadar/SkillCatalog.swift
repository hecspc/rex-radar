import Foundation

/// The skills and commands Claude Code lists in its slash menu for a working directory, read from
/// this Mac's disk the way Claude Code finds them (as of Claude Code 2.1.310):
///
/// - project: `.claude/skills/<name>/SKILL.md` and `.claude/commands/<name>.md` in the directory
///   and its parents, below the home directory; the nearest wins
/// - user: the same under `~/.claude`
/// - plugins: `skills/` and `commands/` of each enabled plugin in
///   `~/.claude/plugins/installed_plugins.json`, as `/<plugin>:<name>`. A plugin is enabled when
///   `enabledPlugins` in the user or project settings says so; a managed one unless they say not.
///
/// Skills with `user-invocable: false` stay out: Claude's menu hides them too.
enum SkillCatalog {
  static func skills(cwd: String?) -> [Skill] {
    let fm = FileManager.default
    let home = fm.homeDirectoryForCurrentUser.standardizedFileURL
    let claude = home.appendingPathComponent(".claude")
    let projects = cwd.map { projectDirs(from: URL(fileURLWithPath: $0).standardizedFileURL, home: home) } ?? []

    var result: [Skill] = []
    var seen = Set<String>()
    func add(_ skills: [Skill]) {
      for s in skills where seen.insert(s.name).inserted { result.append(s) }
    }
    // Nearest project directory first: it wins a clash.
    for dir in projects { add(scan(dir.appendingPathComponent(".claude"), scope: .project, prefix: nil)) }
    add(scan(claude, scope: .user, prefix: nil))
    for (name, root) in enabledPlugins(claude: claude, projects: projects) {
      add(scan(root, scope: .plugin, prefix: name))
    }
    return result.sorted { ($0.scope.order, $0.name) < ($1.scope.order, $1.name) }
  }

  /// The directory and its parents, nearest first, stopping before the home directory.
  private static func projectDirs(from dir: URL, home: URL) -> [URL] {
    var dirs: [URL] = []
    var dir = dir
    while dir.path != home.path, dir.path != "/", dir.pathComponents.count > 1 {
      dirs.append(dir)
      dir.deleteLastPathComponent()
    }
    return dirs
  }

  /// `<root>/skills/*/SKILL.md` and `<root>/commands/**/*.md` (a subfolder adds `folder:`).
  private static func scan(_ root: URL, scope: Skill.Scope, prefix: String?) -> [Skill] {
    let fm = FileManager.default
    func named(_ name: String) -> String { prefix.map { "\($0):\(name)" } ?? name }
    var found: [Skill] = []

    let skills = root.appendingPathComponent("skills")
    for dir in (try? fm.contentsOfDirectory(atPath: skills.path)) ?? [] where !dir.hasPrefix(".") {
      let file = skills.appendingPathComponent(dir).appendingPathComponent("SKILL.md")
      guard let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
      let meta = frontmatter(text)
      if meta["user-invocable"] == "false" { continue }
      found.append(Skill(name: named(meta["name"] ?? dir), description: meta["description"], scope: scope, plugin: prefix))
    }

    let commands = root.appendingPathComponent("commands")
    if let walk = fm.enumerator(at: commands, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) {
      for case let file as URL in walk where file.pathExtension == "md" {
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
        let relative = file.deletingPathExtension().path.dropFirst(commands.path.count + 1)
        let meta = frontmatter(text)
        if meta["user-invocable"] == "false" { continue }
        found.append(
          Skill(
            name: named(relative.replacingOccurrences(of: "/", with: ":")),
            description: meta["description"] ?? firstLine(text), scope: scope, plugin: prefix))
      }
    }
    return found
  }

  /// Enabled plugins as (name, install directory), from the installed list and the settings.
  private static func enabledPlugins(claude: URL, projects: [URL]) -> [(String, URL)] {
    guard let data = try? Data(contentsOf: claude.appendingPathComponent("plugins/installed_plugins.json")),
      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let plugins = json["plugins"] as? [String: [[String: Any]]]
    else { return [] }

    // User settings, then project settings from the outermost directory in: later ones win.
    var enabled: [String: Bool] = [:]
    let settings = [claude.appendingPathComponent("settings.json")]
      + projects.reversed().flatMap { dir in
        ["settings.json", "settings.local.json"].map { dir.appendingPathComponent(".claude/\($0)") }
      }
    for file in settings {
      guard let data = try? Data(contentsOf: file),
        let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
        let flags = json["enabledPlugins"] as? [String: Bool]
      else { continue }
      enabled.merge(flags) { $1 }
    }

    var result: [(String, URL)] = []
    for (key, installs) in plugins.sorted(by: { $0.key < $1.key }) {
      guard let install = installs.first, let path = install["installPath"] as? String else { continue }
      let on = enabled[key] ?? (install["scope"] as? String == "managed")
      guard on else { continue }
      let root = URL(fileURLWithPath: path)
      let manifest = (try? Data(contentsOf: root.appendingPathComponent(".claude-plugin/plugin.json")))
        .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
      let name = manifest?["name"] as? String ?? String(key.split(separator: "@").first ?? Substring(key))
      result.append((name, root))
    }
    return result
  }

  /// The simple `key: value` lines of a YAML front matter block, folded values (`>`, `|`) joined.
  static func frontmatter(_ text: String) -> [String: String] {
    let lines = text.components(separatedBy: .newlines)
    guard lines.first?.trimmingCharacters(in: .whitespaces) == "---" else { return [:] }
    var result: [String: String] = [:]
    var key: String?
    for line in lines.dropFirst() {
      if line.trimmingCharacters(in: .whitespaces) == "---" { break }
      if line.first?.isWhitespace == true, let k = key {
        let more = line.trimmingCharacters(in: .whitespaces)
        result[k] = [result[k], more].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " ")
        continue
      }
      guard let colon = line.firstIndex(of: ":") else { key = nil; continue }
      let k = String(line[..<colon]).trimmingCharacters(in: .whitespaces)
      var value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
      if [">", "|", ">-", "|-"].contains(value) { value = "" }
      if value.count >= 2, let q = value.first, q == "\"" || q == "'", value.last == q {
        value = String(value.dropFirst().dropLast())
      }
      key = k
      result[k] = value
    }
    return result.filter { !$0.value.isEmpty }
  }

  /// A command's description when it has none: its first line of text, past the front matter.
  private static func firstLine(_ text: String) -> String? {
    var lines = text.components(separatedBy: .newlines)[...]
    if lines.first?.trimmingCharacters(in: .whitespaces) == "---" {
      lines = lines.dropFirst()
      if let end = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "---" }) {
        lines = lines[(end + 1)...]
      }
    }
    return lines.lazy.map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "# ").union(.whitespaces)) }
      .first { !$0.isEmpty }
  }
}

extension Skill.Scope {
  var order: Int { Self.allCases.firstIndex(of: self) ?? 0 }
}
