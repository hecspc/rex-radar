import SwiftUI

/// The picker's state (an ObservableObject: the Mac target avoids SwiftUI's macros).
@MainActor
final class SkillPickerModel: ObservableObject {
  @Published var skills: [Skill]?
  @Published var query = ""
  @Published var selected: Skill?
  @Published var arguments = ""
  @Published var error: String?
  @Published var sending = false
}

/// Picks one of the skills an agent offers in a pane, filtered as you type, grouped by where it
/// comes from; then takes optional arguments and sends it.
struct SkillPicker: View {
  let load: () async throws -> [Skill]
  let send: (SkillRequest) async throws -> Void
  /// Who gets it, on the Send button: "Claude Code", "Codex".
  let agentName: String
  var cancel: (() -> Void)?
  /// The list's height where nothing else sizes it (the menu bar panel); nil fills the space.
  var listHeight: CGFloat?

  @StateObject private var model = SkillPickerModel()
  @FocusState private var focus: Field?

  private enum Field { case filter, arguments }

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      if let selected = model.selected { detail(selected) } else { picker }
      if let error = model.error {
        Label(error, systemImage: "exclamationmark.triangle").font(.callout).foregroundStyle(.orange)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
    .task {
      do { model.skills = try await load() } catch { model.error = error.localizedDescription }
    }
  }

  // MARK: Choosing

  private var picker: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack(spacing: 8) {
        Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
        TextField("Filter skills", text: $model.query)
          .textFieldStyle(.plain)
          .focused($focus, equals: .filter)
          .autocorrectionDisabled()
          #if os(iOS)
            .textInputAutocapitalization(.never)
          #endif
          .onSubmit { if let first = groups.first?.skills.first { choose(first) } }
        if !model.query.isEmpty {
          Button { model.query = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
            .buttonStyle(.plain)
        }
      }
      .padding(.horizontal, 12)
      .padding(.vertical, 8)
      .glassBackground(in: Capsule())
      .onAppear { focus = .filter }

      list
        .frame(height: listHeight)
        .frame(maxHeight: listHeight == nil ? .infinity : nil)

      if let cancel {
        HStack {
          Button("Cancel", action: cancel).glassButtonStyle()
          Spacer()
        }
      }
    }
  }

  @ViewBuilder private var list: some View {
    if model.skills == nil, model.error == nil {
      ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
    } else if groups.isEmpty {
      Text(model.query.isEmpty ? "No skills here." : "No skill matches “\(model.query)”.")
        .font(.callout).foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    } else {
      ScrollView {
        LazyVStack(alignment: .leading, spacing: 2) {
          ForEach(groups, id: \.scope) { group in
            Text("\(group.scope.title.uppercased()) · \(group.skills.count)")
              .font(.caption.weight(.semibold)).foregroundStyle(.secondary).tracking(1)
              .padding(.top, 10).padding(.bottom, 2).padding(.horizontal, 4)
            ForEach(group.skills) { skill in
              Button { choose(skill) } label: { SkillRow(skill: skill) }.buttonStyle(.plain)
            }
          }
        }
      }
      .scrollIndicators(.automatic)
    }
  }

  /// Matches per group, in Project, User, Plugins order; a name match comes before a description match.
  private var groups: [(scope: Skill.Scope, skills: [Skill])] {
    let all = model.skills ?? []
    let q = model.query.trimmingCharacters(in: .whitespaces).lowercased()
    return Skill.Scope.allCases.compactMap { scope in
      var matches = all.filter { $0.scope == scope && (q.isEmpty || $0.matches(q)) }
      if !q.isEmpty {
        let key = q.hasPrefix("/") ? String(q.dropFirst()) : q
        matches.sort { a, b in
          let (ra, rb) = (rank(a, key), rank(b, key))
          return ra != rb ? ra < rb : a.name < b.name
        }
      }
      return matches.isEmpty ? nil : (scope, matches)
    }
  }

  private func rank(_ skill: Skill, _ q: String) -> Int {
    let name = skill.name.lowercased()
    let short = name.split(separator: ":").last.map(String.init) ?? name
    if name.hasPrefix(q) || short.hasPrefix(q) { return 0 }
    if name.contains(q) { return 1 }
    return 2
  }

  private func choose(_ skill: Skill) {
    model.selected = skill
    model.error = nil
    focus = .arguments
  }

  // MARK: Sending

  private func detail(_ skill: Skill) -> some View {
    VStack(alignment: .leading, spacing: 12) {
      VStack(alignment: .leading, spacing: 4) {
        Text(skill.command).font(.headline.monospaced()).lineLimit(2)
        Text(skill.scope == .plugin ? "Plugin \(skill.plugin ?? "")" : skill.scope.title)
          .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
        if let d = skill.description {
          Text(d).font(.callout).foregroundStyle(.secondary).lineLimit(6).fixedSize(horizontal: false, vertical: true)
        }
      }
      TextField("Arguments (optional)", text: $model.arguments, axis: .vertical)
        .lineLimit(1...4)
        .textFieldStyle(.roundedBorder)
        .focused($focus, equals: .arguments)
        .onSubmit { submit(skill) }
      HStack {
        Button {
          model.selected = nil
          model.error = nil
          focus = .filter
        } label: { Label("Skills", systemImage: "chevron.left") }
          .glassButtonStyle()
        Spacer()
        Button { submit(skill) } label: {
          if model.sending { ProgressView().controlSize(.small) } else { Label("Send to \(agentName)", systemImage: "paperplane.fill") }
        }
        .glassProminentButtonStyle()
        .disabled(model.sending)
        .keyboardShortcut(.defaultAction)
      }
    }
  }

  private func submit(_ skill: Skill) {
    guard !model.sending else { return }
    // A newline would press Enter mid-line: arguments are one line.
    let args = model.arguments.components(separatedBy: .newlines).joined(separator: " ")
    model.sending = true
    model.error = nil
    Task {
      do { try await send(SkillRequest(name: skill.name, arguments: args)) } catch { model.error = error.localizedDescription }
      model.sending = false
    }
  }
}

/// A skill as a list row: what you'd type, then what it does.
struct SkillRow: View {
  let skill: Skill

  var body: some View {
    VStack(alignment: .leading, spacing: 2) {
      Text(skill.command).font(.callout.monospaced().weight(.medium)).foregroundStyle(.primary).lineLimit(1)
      if let d = skill.description {
        Text(d).font(.caption).foregroundStyle(.secondary).lineLimit(2)
      }
    }
    .padding(.vertical, 6)
    .padding(.horizontal, 4)
    .frame(maxWidth: .infinity, alignment: .leading)
    .contentShape(Rectangle())
  }
}
