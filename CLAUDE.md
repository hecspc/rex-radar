# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

Rex Radar is a glanceable view of the coding agents running in [Rex](https://www.superlogical.com/rex) terminal sessions, across several Rex servers. It runs on macOS (menu bar app plus widget), iPhone/iPad (app plus widget), Apple Watch (app plus complications) and Apple TV (app). `README.md` is the design doc. It records what has been verified on which Rex and Claude Code builds, so keep it current when behaviour changes.

## Build

```sh
macos/scripts/build.sh --unsigned                              # compile check of the Mac app + widget (no signing)
DEVELOPMENT_TEAM=<team id> macos/scripts/build.sh --install    # signed Mac app + widget → ~/Applications, relaunch
macos/bundle.sh [--install]                                    # Mac app only via SwiftPM, ad-hoc signed, no widget
```

- `BUNDLE_PREFIX` (default `house.milapan`, the author's) prefixes every bundle ID and App Group. It's a build setting in `project.yml`, overridable on the `xcodebuild` command line or via the environment for `build.sh`/`bundle.sh`. Never hard-code `house.milapan` in plists, entitlements or code.
- `macos/project.yml` is an XcodeGen spec. `build.sh` runs `xcodegen generate`, and `RexRadar.xcodeproj` is gitignored. To add targets or change their sources, edit `project.yml`, not the generated project.
- Package.swift builds only the Mac app, from `Sources/` minus the widget, iOS, watch and tvOS folders. Code that compiles under SwiftPM can still fail under Xcode in another target, so check both.
- iOS, watchOS and tvOS have no script. Run `cd macos && xcodegen generate`, then `xcodebuild -project RexRadar.xcodeproj -scheme RexRadarMobile …`. The watch app is embedded in the iOS app.
- Simulator pairing without the URL prompt: `SIMCTL_CHILD_REXRADAR_PAIR='rexradar://pair?…' xcrun simctl launch <sim> house.milapan.rex-radar.ios`.
- There are no tests. To answer a question list without the UI, run `RexRadar --answer <block id> '<answers json>'` (`AnswerCommand.swift`). The prototype CLI is `bin/rex-radar [--json] | open <n>`.
- tvOS: `xcodebuild -project RexRadar.xcodeproj -scheme RexRadarTV -destination 'generic/platform=tvOS Simulator' …`. Its icon is a separate catalog (`Resources/TVAssets.xcassets`), drawn by `scripts/make-icon.swift`.
- Deployment targets: macOS 26, iOS 17, watchOS 10, tvOS 17. Swift 6 with `SWIFT_STRICT_CONCURRENCY: minimal`. Liquid Glass applies only on 26+, with a frosted material fallback before that (`Shared/Glass.swift`).
- `macos/.build/` (SwiftPM) and `macos/build/` (Xcode) hold thousands of generated files, so exclude them from `find`/`grep` (`-path '*/.build' -prune`).

## Architecture

Data flows one way: Rex server → Lua watcher → JSON snapshots → Mac app → (hub HTTP) → iOS → watch.

1. **Watcher** (`watcher/rex-radar.lua`). One `rex [-S <server>] do … --all` process per Rex server. It listens to Rex events (`terminal.program_status_changed`, session and window changes) and writes `~/.local/state/rex-radar/<source>.json` atomically, at most every 0.3 s and at least every 15 s as a heartbeat. A snapshot older than two heartbeats counts as stale. `REX_RADAR_DIR` overrides the directory everywhere.
2. **Mac app** (`Sources/RexRadar`). `Watchers` spawns and restarts one watcher per configured server. It runs the Lua script from the app bundle, or from the repo checkout during development. `Store` polls the snapshots every 2 s, merges them into `Row`s ordered by urgency, and mirrors them into the App Group for the sandboxed widget (`Shared/SharedState.swift`). `Rex.swift` drives Rex only through the `rex` CLI binary. The wire protocol is undocumented, so don't write a native client. The CLI is found via `REX_BIN` or the path inside the Rex app bundle, because GUI apps don't get the shell's PATH.
3. **Opening a pane**. The app calls `session.focus_block`, then `client.perform` → `session.select` on the Rex app client of the pane's server, chosen by label (`clientLabel` default, which is this Mac's name). Remote servers go through `rex -S`.
4. **Hub** (`HubServer.swift`). It serves HTTP on port 7298 (`GET /v1/agents`, `POST /v1/open`, `POST /v1/answer`, `GET /v1/skills`, `POST /v1/skill`) with a bearer token, advertised over Bonjour as `_rexradar._tcp`. `POST /v1/pair` and `GET /v1/pair` take no token: they let an Apple TV ask to pair and receive the token after someone allows it on the window's Devices page. `/v1/answer` returns 403 unless the "let iPhone & iPad answer" setting is on, and the skill endpoints unless "let iPhone & iPad send skills" is on.
5. **iOS** (`Sources/RexRadarMobile`). `HubClient` holds the paired Macs, with tokens in the Keychain, and talks to the hub. `WatchSync` pushes the paired Macs to the watch as the WatchConnectivity application context.
6. **watchOS** (`Sources/RexRadarWatch`). It has no pairing of its own and compiles `RexRadarMobile/HubClient.swift` directly.
7. **tvOS** (`Sources/RexRadarTV`). It pairs through `/v1/pair` (Bonjour discovery or an address), then compiles `RexRadarMobile/HubClient.swift` like the watch. There is no WidgetKit on tvOS, so `HubClient` guards it with `#if canImport(WidgetKit)`.
8. **Widgets**. `Sources/RexRadarWidget` builds three times (macOS, iOS and watchOS targets). Each has its own App Group: macOS uses `<team>.house.milapan.rex-radar`, iOS uses `group.house.milapan.rex-radar`, and watchOS uses `group.house.milapan.rex-radar.watch`.

`Sources/Shared` goes into every target. The watch and tvOS targets exclude `QuestionsForm.swift` and `SkillPicker.swift`, so watch-incompatible UI must stay out of the other Shared files or be excluded in `project.yml`.

### Sending skills

`SkillCatalog.swift` lists what Claude's slash menu offers for a pane's working directory (project, user and enabled plugin skills and commands, from the Mac's disk), and `Rex.sendSkill` types `/name args` and Enter. Only panes on the Mac's own server qualify (`Row.takesSkills`). See README "Sending skills".

### Answering Claude's questions

`hooks/claude-rex-questions` is a Claude Code hook (PreToolUse `AskUserQuestion` → `ask`; Post/PostFailure, Stop and UserPromptSubmit → `done`). It saves the full question list to `$REX_RADAR_DIR/questions/<REX_BLOCK>.json`, because Rex's status carries only the first question. The hook must never fail or print anything, since hook output reaches Claude. The app answers by typing keystrokes into the pane. The key sequence depends on the Claude Code TUI (number selects, Tab moves between multi-select questions, a review screen then `1`), so check it against the current Claude Code version before changing it. See README "Answering Claude's questions".

## Conventions

- Swift uses 2-space indentation and short `///` doc comments that say why.
- Commits follow Conventional Commits with an optional platform scope (`feat(macos):`, `feat(ios):`, `docs:`).
- Rex is in beta and its API changes weekly. Check `rex api list` / `rex api describe <method>` instead of assuming. Record newly verified behaviour, with the date and versions, in the README.
