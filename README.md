# rex-radar

A glanceable view of the coding agents running in [Rex](https://www.superlogical.com/rex) sessions, across
several Rex servers, for iOS and macOS. Tap an agent to jump to its tab, in the Rex app you're meant to use.

> Status: prototype backend (watcher + CLI). Rex is in beta and its API changes weekly.

## What it shows

A sidebar like Rex's own: servers → sessions → tabs → panes. Each pane running an agent shows:

- **State**: idle, working, blocked (permission, question or auth), done or error.
- **Summary**: one line about what the agent did or needs.
- **Unread**: done or blocked since you last looked.

Ordered by urgency: blocked first, then done-unseen, then working.

## Servers and the main server

rex-radar connects to several Rex servers at once. One of them is the **main** server, the one whose Rex app you
sit in front of.

| Where you tap | Server of the tapped agent | What opens |
| --- | --- | --- |
| iOS | any | The tab in the **main** server's Rex app, not on the phone |
| macOS | local | The tab in the local Rex app |
| macOS | remote | The tab in the local Rex app, through its connection to that remote host |

On iOS rex-radar is a remote control: it shows everything and sends you to your desk.

## How it would work

### Data: all from the Rex server API

The server describes its own API (`rex api list`, `rex api describe <method>`):

- `session.list`, `session.view`: sessions, windows (tabs), layouts, blocks (panes) and labels.
- `com.superlogical.terminal.program_status`: each pane's status records. Programs report them with
  [OSC 7501](https://www.superlogical.com/rex/docs/build/program-status).
- `com.superlogical.terminal.title`: the terminal title. Claude Code sets it to the conversation topic.
- Events (`rex.on` in Lua, or `rex events`): `terminal.program_status_changed`, window and session changes, so no
  polling.

**Claude Code reports its own status from 2.1.310 on.** Verified 2026-10-24: `idle` at start, `working` while it
runs, `done` with a summary in `msg` ("replied 'pong' as requested"). 2.1.283 reported nothing. Not yet verified:
`blocked` on a permission or question prompt.

### Opening a tab in the right app

Rex apps are clients of a server. A Mac app connected to a remote host is also a client *of that host*. To open
a tab in a given app, ask the server that holds the session to run `session.select` on that app's client:

```sh
rex -S <server> -C <client> do session.select session_id=<session> window_id=<tab>
```

- Needs **Remote Control** turned on in that Rex app's settings.
- For a remote agent opening in the main or local Mac app, that app must already have the remote host added.

### Connecting

Rex trusts callers by how they connect. The only safe remote access today is **Tailscale**: a server started with
`rex server start --tailscale`, or Tailscale Serve or a tailnet address on Linux. Any connection gets full control
of that server ([Remote Access](https://www.superlogical.com/rex/docs/linux/remote-access)). rex-radar should only
read, plus `session.select`.

## Prototype

`watcher/rex-radar.lua` publishes one server's agent panes; `bin/rex-radar` reads every server's snapshot.

```sh
# one watcher per server; leave it running in a Rex pane
rex do watcher/rex-radar.lua --all source=mac
rex -S build do watcher/rex-radar.lua --all source=build server=build

bin/rex-radar                         # every agent pane, most urgent first
bin/rex-radar --json                  # the same as JSON
bin/rex-radar open 2                  # show row 2 in the server's Rex apps
bin/rex-radar open 2 --client vv-macbook   # only in the app labelled vv-macbook (the main Mac)
```

```
1  ✓ done      mac · rex-config-review · 3. radar-test
       init.lua: tmux-style keybinds, rexurrect restore, loads rexdiff
```

- Snapshots: `~/.local/state/rex-radar/<source>.json` (`REX_RADAR_DIR`), replaced atomically on every change
  (debounced 0.3 s) and every 15 s. A snapshot older than two heartbeats is shown as stale.
- A row is a pane with at least one OSC 7501 record; its root record speaks for it (else the most urgent).
- `open` calls `session.focus_block`, then `client.perform` → `session.select` on the app clients of the pane's
  server. For a remote pane it goes through `rex -S <server>`, so the Mac app must have that host added.

Verified 2026-10-24 on Rex build 1408 with Claude Code 2.1.310: idle → working → done with the summary, a session
rename picked up live, and `open` switching the Mac app to the pane's tab. Not yet tried: a second server.

### macOS app and widget

`macos/` is a SwiftUI menu bar app with a window and a desktop widget, over the same snapshots.

```sh
DEVELOPMENT_TEAM=<team id> macos/scripts/build.sh --install   # app + widget, Xcode, signed
macos/bundle.sh --install                                     # app only, command-line tools, ad-hoc signed
```

- **Menu bar**: Rex's own dino (loaded from the installed Rex app at run time) over a round radar; a blip and a
  count when agents want you.
- **Panel** (Liquid Glass): the most urgent agent as a card with **Open in Rex**, the others in a card per server.
- **Window**: a server sidebar and a card per agent.
- **Widget** (small, medium, large): agents by urgency; tap one to open it in Rex (`rexradar://open?id=…`).
  The sandboxed widget can't read the snapshots, so the app copies the merged rows into the App Group
  `<team>.house.milapan.rex-radar` and reloads the widget when they change.
- **Open in Rex** switches the Rex app labelled with this Mac's name (`defaults write house.milapan.rex-radar
  clientLabel <label>` to change it), then brings Rex to the front.
- The team ID is the `OU` of your Apple Development certificate. A free Personal Team is enough to run it on your
  own Mac.

## Risks

- **The transport isn't public.** The API methods are documented; the protocol the `rex` CLI speaks to the server
  (`rex.control.v1` over the server's socket or HTTP) is not. A native Swift client would have to follow a beta that
  changes weekly. Going through `rex` (CLI or Lua) avoids that.
- **Overlap with Rex.** Rex's own iOS app and the Mac app's Activity view already show per-pane status and navigate
  on tap, for one host at a time. What rex-radar adds: several servers in one view, main-server routing, and the
  summary up front.
- **Auth.** Until Rex has its own authentication, everything rides on Tailscale ACLs.

## Plan

1. Use Rex's own iOS app and Activity view for a while with Claude Code ≥ 2.1.310, and note which gaps hurt.
2. Prototype the backend: one Lua watcher per server (`rex -S <server> do watcher.lua --all`, as
   [cheap-rex-display](https://github.com/yethranayeh/cheap-rex-display) does), publishing pane state to a small
   local service.
3. A SwiftUI menu-bar app on macOS reading that service, with tap → `session.select`.
4. iOS: the same UI against the service over Tailscale, routing every tap to the main server's app.
5. Summaries beyond the status `msg`, if they're still missing.

## Related

- Rex docs: [Server API](https://www.superlogical.com/rex/docs/automate/server-api),
  [Program Status Protocol](https://www.superlogical.com/rex/docs/build/program-status),
  [Lua events](https://www.superlogical.com/rex/docs/automate/lua-events)
- [rexurrect](https://github.com/cemcatik/rexurrect): session restore; holds each pane's `claude --resume <id>`
