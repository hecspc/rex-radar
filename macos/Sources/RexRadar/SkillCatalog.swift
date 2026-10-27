import Foundation

/// The skills and commands an agent lists in its menu for a working directory, read from this
/// Mac's disk the way the agent finds them.
///
/// Claude Code (as of 2.1.310), typed `/name`:
/// - project: `.claude/skills/<name>/SKILL.md` and `.claude/commands/<name>.md` in the directory
///   and its parents, below the home directory; the nearest wins
/// - user: the same under `~/.claude`
/// - plugins: `skills/` and `commands/` of each enabled plugin in
///   `~/.claude/plugins/installed_plugins.json`, as `/<plugin>:<name>`. A plugin is enabled when
///   `enabledPlugins` in the user or project settings says so; a managed one unless they say not.
///
/// Codex (as of 0.164.0), typed `$name`:
/// - project: `.agents/skills` and `.codex/skills` from the directory up to the repository root
/// - user: `~/.agents/skills`, `~/.codex/skills` and its bundled `.system` skills
/// - plugins: the newest cached version of each installed plugin,
///   `~/.codex/plugins/cache/<marketplace>/<plugin>/<version>/skills`, as `$<plugin>:<name>`,
///   unless `config.toml` sets `[plugins."<plugin>@<marketplace>"] enabled = false`
///
/// Antigravity (as of agy 1.4.7), typed `/name`:
/// - project: `skills/` in `.agents`, `.agent`, `_agents` or `_agent` from the directory up to
///   the repository root
/// - user: `~/.gemini/config/skills`
/// - plugins: `plugins/<plugin>/skills` in those same folders, as `/<plugin>:<name>`, unless
///   `~/.gemini/config/config.json` or the plugin's manifest turns it off
/// Its built-in skills are left out: it mounts only some of them, and nothing on disk says which.
///
/// Qoder (as of 1.1.78), typed `/name`:
/// - project: `.qoder/skills`, `.qoder/commands` and `.agents/skills` in the directory itself,
///   not its parents
/// - user: `~/.qoder/skills`, `~/.qoder/commands` and `~/.agents/skills`
/// - plugins: each plugin in `~/.qoder/plugins/installed_plugins_v2.json` that's enabled there and
///   not turned off by `enabledPlugins` in `~/.qoder/settings.json`, with a named manifest:
///   its skills as `/<plugin>:<name>`, and its commands as the manifest names them
/// Its bundled skills (`/review`, `/imagegen`, …) are left out, like Antigravity's.
///
/// Pi (as of 1.4.0), typed `/name` for prompt templates and `/skill:name` for skills: Pi lists
/// them itself (`get_commands` in its RPC mode, run in the directory), since its packages,
/// settings and project trust decide what loads. Extensions stay off for that run, so their
/// commands are left out: they run code as they load.
///
/// Skills with `user-invocable: false` (Claude) or `disable-slash-command: true` (Antigravity)
/// stay out: the agents' menus hide them too.
enum SkillCatalog {
  static func skills(cwd: String?, agent: SkillAgent) -> [Skill] {
    let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL
    let dir = cwd.map { URL(fileURLWithPath: $0).standardizedFileURL }
    let found: [Skill]
    switch agent {
    case .claudeCode: found = claude(dir, home: home)
    case .codex: found = codex(dir, home: home)
    case .antigravity: found = antigravity(dir, home: home)
    case .qoder: found = qoder(dir, home: home)
    case .pi: found = pi(dir ?? home)
    }
    // Found in priority order: the first of a name wins a clash.
    var seen = Set<String>()
    return found.filter { seen.insert($0.name).inserted }
      .map { var skill = $0; skill.sigil = agent.sigil; return skill }
      .sorted { ($0.scope.order, $0.name) < ($1.scope.order, $1.name) }
  }

  // MARK: Agents

  private static func claude(_ dir: URL?, home: URL) -> [Skill] {
    let claude = home.appendingPathComponent(".claude")
    let projects = dir.map { projectDirs(from: $0, home: home) } ?? []
    // Nearest project directory first.
    var found = projects.flatMap { scan($0.appendingPathComponent(".claude"), scope: .project, prefix: nil) }
    found += scan(claude, scope: .user, prefix: nil)
    for (name, root) in enabledPlugins(claude: claude, projects: projects) {
      found += scan(root, scope: .plugin, prefix: name)
    }
    return found
  }

  private static func codex(_ dir: URL?, home: URL) -> [Skill] {
    let codex = home.appendingPathComponent(".codex")
    let projects = dir.map(repoDirs) ?? []
    var found = projects.flatMap { dir in
      [".agents", ".codex"].flatMap { scanSkills(dir.appendingPathComponent("\($0)/skills"), scope: .project, prefix: nil) }
    }
    found += scanSkills(home.appendingPathComponent(".agents/skills"), scope: .user, prefix: nil)
    found += scanSkills(codex.appendingPathComponent("skills"), scope: .user, prefix: nil)
    found += scanSkills(codex.appendingPathComponent("skills/.system"), scope: .user, prefix: nil)
    for (name, root) in codexPlugins(codex: codex) {
      found += scanSkills(root.appendingPathComponent("skills"), scope: .plugin, prefix: name)
    }
    return found
  }

  private static func antigravity(_ dir: URL?, home: URL) -> [Skill] {
    let config = home.appendingPathComponent(".gemini/config")
    let projects = (dir.map(repoDirs) ?? []).flatMap { dir in
      [".agents", ".agent", "_agents", "_agent"].map { dir.appendingPathComponent($0) }
    }
    var found = projects.flatMap { scanSkills($0.appendingPathComponent("skills"), scope: .project, prefix: nil) }
    found += scanSkills(config.appendingPathComponent("skills"), scope: .user, prefix: nil)
    for (name, root) in antigravityPlugins(roots: projects + [config], config: config) {
      found += scanSkills(root.appendingPathComponent("skills"), scope: .plugin, prefix: name)
    }
    return found
  }

  private static func qoder(_ dir: URL?, home: URL) -> [Skill] {
    let qoder = home.appendingPathComponent(".qoder")
    var found: [Skill] = []
    // The working directory and the home directory, the same folders in each.
    for (root, scope) in [(dir, Skill.Scope.project), (home, .user)] {
      guard let root, scope == .user || root != home else { continue }
      found += scan(root.appendingPathComponent(".qoder"), scope: scope, prefix: nil)
      found += scanSkills(root.appendingPathComponent(".agents/skills"), scope: scope, prefix: nil)
    }
    for plugin in qoderPlugins(qoder: qoder) {
      found += scanSkills(plugin.skills, scope: .plugin, prefix: plugin.name) + plugin.commands
    }
    return found
  }

  /// Asks Pi what its menu offers in `dir`. Pi runs through an interactive shell, like a new
  /// session's agent, so it's found on the PATH `.zshrc` sets; a pane's own PATH can differ.
  private static func pi(_ dir: URL) -> [Skill] {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh")
    process.arguments = ["-ic", "exec pi --mode rpc --no-session --no-extensions"]
    process.currentDirectoryURL = dir
    let input = Pipe(), output = Pipe()
    process.standardInput = input
    process.standardOutput = output
    process.standardError = FileHandle.nullDevice
    guard (try? process.run()) != nil else { return [] }
    // Pi answers, then quits at the end of its input.
    input.fileHandleForWriting.write(Data(#"{"type":"get_commands"}"#.utf8 + [10]))
    try? input.fileHandleForWriting.close()
    let deadline = DispatchWorkItem { process.terminate() }
    DispatchQueue.global().asyncAfter(deadline: .now() + 10, execute: deadline)
    let data = output.fileHandleForReading.readDataToEndOfFile()
    deadline.cancel()
    process.waitUntilExit()
    // The shell's own start-up may print first: take the line that answers.
    let reply = data.split(separator: 10).lazy.compactMap { try? JSONSerialization.jsonObject(with: Data($0)) as? [String: Any] }
      .first { $0["command"] as? String == "get_commands" }
    let commands = (reply?["data"] as? [String: Any])?["commands"] as? [[String: Any]] ?? []
    return commands.compactMap { command in
      guard let name = command["name"] as? String, command["source"] as? String != "extension" else { return nil }
      let info = command["sourceInfo"] as? [String: Any] ?? [:]
      let description = (command["description"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
      if info["origin"] as? String == "package" {
        return Skill(name: name, description: description, scope: .plugin, plugin: info["source"] as? String)
      }
      return Skill(name: name, description: description, scope: info["scope"] as? String == "project" ? .project : .user)
    }
  }

  // MARK: Directories

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

  /// The directory and its parents up to the repository root (the one holding `.git`), nearest
  /// first; just the directory outside a repository.
  private static func repoDirs(from dir: URL) -> [URL] {
    var dirs: [URL] = []
    var current = dir
    while true {
      dirs.append(current)
      if FileManager.default.fileExists(atPath: current.appendingPathComponent(".git").path) { return dirs }
      guard current.path != "/", current.pathComponents.count > 1 else { return [dir] }
      current.deleteLastPathComponent()
    }
  }

  /// The visible entries of a directory, sorted.
  private static func entries(_ dir: URL) -> [String] {
    ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).filter { !$0.hasPrefix(".") }.sorted()
  }

  private static func json(_ file: URL) -> [String: Any]? {
    (try? Data(contentsOf: file)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
  }

  // MARK: Scanning

  /// `<root>/skills/*/SKILL.md` and `<root>/commands/**/*.md`.
  private static func scan(_ root: URL, scope: Skill.Scope, prefix: String?) -> [Skill] {
    scanSkills(root.appendingPathComponent("skills"), scope: scope, prefix: prefix)
      + scanCommands(root.appendingPathComponent("commands"), scope: scope, prefix: prefix)
  }

  /// `<dir>/*/SKILL.md`.
  private static func scanSkills(_ dir: URL, scope: Skill.Scope, prefix: String?) -> [Skill] {
    entries(dir).compactMap { name in
      let file = dir.appendingPathComponent(name).appendingPathComponent("SKILL.md")
      guard let text = try? String(contentsOf: file, encoding: .utf8) else { return nil }
      let meta = frontmatter(text)
      guard !hidden(meta) else { return nil }
      return Skill(name: named(meta["name"] ?? name, prefix), description: meta["description"], scope: scope, plugin: prefix)
    }
  }

  /// `<dir>/**/*.md` (a subfolder adds `folder:`).
  private static func scanCommands(_ dir: URL, scope: Skill.Scope, prefix: String?) -> [Skill] {
    guard let walk = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
    else { return [] }
    var found: [Skill] = []
    for case let file as URL in walk where file.pathExtension == "md" {
      guard let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
      let relative = file.deletingPathExtension().path.dropFirst(dir.path.count + 1)
      let meta = frontmatter(text)
      if hidden(meta) { continue }
      found.append(
        Skill(
          name: named(relative.replacingOccurrences(of: "/", with: ":"), prefix),
          description: meta["description"] ?? firstLine(text), scope: scope, plugin: prefix))
    }
    return found
  }

  private static func named(_ name: String, _ prefix: String?) -> String { prefix.map { "\($0):\(name)" } ?? name }

  private static func hidden(_ meta: [String: String]) -> Bool {
    meta["user-invocable"] == "false" || meta["disable-slash-command"] == "true"
  }

  // MARK: Plugins

  /// Enabled Claude plugins as (name, install directory), from the installed list and the settings.
  private static func enabledPlugins(claude: URL, projects: [URL]) -> [(String, URL)] {
    guard let installed = json(claude.appendingPathComponent("plugins/installed_plugins.json")),
      let plugins = installed["plugins"] as? [String: [[String: Any]]]
    else { return [] }

    // User settings, then project settings from the outermost directory in: later ones win.
    var enabled: [String: Bool] = [:]
    let settings = [claude.appendingPathComponent("settings.json")]
      + projects.reversed().flatMap { dir in
        ["settings.json", "settings.local.json"].map { dir.appendingPathComponent(".claude/\($0)") }
      }
    for file in settings {
      guard let flags = json(file)?["enabledPlugins"] as? [String: Bool] else { continue }
      enabled.merge(flags) { $1 }
    }

    var result: [(String, URL)] = []
    for (key, installs) in plugins.sorted(by: { $0.key < $1.key }) {
      guard let install = installs.first, let path = install["installPath"] as? String else { continue }
      let on = enabled[key] ?? (install["scope"] as? String == "managed")
      guard on else { continue }
      let root = URL(fileURLWithPath: path)
      let manifest = json(root.appendingPathComponent(".claude-plugin/plugin.json"))
      let name = manifest?["name"] as? String ?? String(key.split(separator: "@").first ?? Substring(key))
      result.append((name, root))
    }
    return result
  }

  /// Installed Codex plugins as (name, newest cached version), minus those `config.toml` turns off.
  private static func codexPlugins(codex: URL) -> [(String, URL)] {
    let cache = codex.appendingPathComponent("plugins/cache")
    let off = codexDisabledPlugins(codex.appendingPathComponent("config.toml"))
    var result: [(String, URL)] = []
    for marketplace in entries(cache) {
      for plugin in entries(cache.appendingPathComponent(marketplace)) where !off.contains("\(plugin)@\(marketplace)") {
        let dir = cache.appendingPathComponent("\(marketplace)/\(plugin)")
        let versions = entries(dir).map { dir.appendingPathComponent($0) }
        func modified(_ url: URL) -> Date {
          (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
        }
        guard let root = versions.max(by: { modified($0) < modified($1) }) else { continue }
        let name = json(root.appendingPathComponent(".codex-plugin/plugin.json"))?["name"] as? String ?? plugin
        result.append((name, root))
      }
    }
    return result
  }

  /// The `<plugin>@<marketplace>` tables of `config.toml` that say `enabled = false`.
  private static func codexDisabledPlugins(_ file: URL) -> Set<String> {
    guard let text = try? String(contentsOf: file, encoding: .utf8) else { return [] }
    var off = Set<String>()
    var table: String?
    for line in text.components(separatedBy: .newlines) {
      let line = line.trimmingCharacters(in: .whitespaces)
      if line.hasPrefix("[") {
        table = line.hasPrefix("[plugins.") && line.hasSuffix("]")
          ? String(line.dropFirst("[plugins.".count).dropLast()).trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
          : nil
      } else if let table, line.replacingOccurrences(of: " ", with: "").hasPrefix("enabled=false") {
        off.insert(table)
      }
    }
    return off
  }

  /// Qoder plugins that are on, with where their skills are and their commands. Qoder 1.1.78
  /// skips a plugin whose manifest (`.qoder-plugin/plugin.json` or `plugin.json`) has no name. Its
  /// commands are the manifest's `commands` map, `{"<name>": {"source", "description"}}`, as
  /// `/<plugin>:<name>`, or else the `.md` files in its `commands` folder.
  private static func qoderPlugins(qoder: URL) -> [(name: String, skills: URL, commands: [Skill])] {
    let plugins = qoder.appendingPathComponent("plugins")
    guard let installed = json(plugins.appendingPathComponent("installed_plugins_v2.json"))?["plugins"] as? [String: [[String: Any]]]
    else { return [] }
    let off = (json(qoder.appendingPathComponent("settings.json"))?["enabledPlugins"] as? [String: Bool] ?? [:])
      .filter { !$0.value }.keys
    var result: [(String, URL, [Skill])] = []
    for (key, installs) in installed.sorted(by: { $0.key < $1.key }) where !off.contains(key) {
      guard let install = installs.first, install["enabled"] as? Bool != false, let path = install["installPath"] as? String
      else { continue }
      let root = URL(fileURLWithPath: path)
      guard let manifest = [".qoder-plugin/plugin.json", "plugin.json"].lazy.compactMap({ json(root.appendingPathComponent($0)) }).first,
        let name = manifest["name"] as? String, !name.isEmpty
      else { continue }
      let skills = root.appendingPathComponent(manifest["skills"] as? String ?? "skills")
      var commands: [Skill] = []
      if let map = manifest["commands"] as? [String: Any] {
        for (command, entry) in map.sorted(by: { $0.key < $1.key }) {
          let entry = entry as? [String: Any]
          let text = (entry?["source"] as? String).flatMap { try? String(contentsOf: root.appendingPathComponent($0), encoding: .utf8) }
          let description = entry?["description"] as? String ?? text.flatMap { frontmatter($0)["description"] ?? firstLine($0) }
          commands.append(Skill(name: named(command, name), description: description, scope: .plugin, plugin: name))
        }
      } else {
        commands = scanCommands(root.appendingPathComponent(manifest["commands"] as? String ?? "commands"), scope: .plugin, prefix: name)
      }
      result.append((name, skills, commands))
    }
    return result
  }

  /// Antigravity plugins in `<root>/plugins/<dir>` that are on, as (name, directory): a
  /// `plugins.<dir>.enabled` entry in `config.json` wins, else the manifest's `disabled`.
  private static func antigravityPlugins(roots: [URL], config: URL) -> [(String, URL)] {
    let settings = json(config.appendingPathComponent("config.json"))?["plugins"] as? [String: [String: Any]] ?? [:]
    var result: [(String, URL)] = []
    for root in roots {
      let plugins = root.appendingPathComponent("plugins")
      for dir in entries(plugins) {
        let plugin = plugins.appendingPathComponent(dir)
        let manifest = ["plugin.json", ".antigravity-plugin/plugin.json", ".gemini-plugin/plugin.json"].lazy
          .compactMap { json(plugin.appendingPathComponent($0)) }.first
        guard let manifest else { continue }
        let on = settings[dir]?["enabled"] as? Bool ?? (manifest["disabled"] as? Bool != true)
        if on { result.append((manifest["name"] as? String ?? dir, plugin)) }
      }
    }
    return result
  }

  // MARK: Front matter

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
