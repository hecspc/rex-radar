-- rex-radar watcher: publishes the agent panes of one Rex server.
--
--   rex [-S <server>] do watcher/rex-radar.lua --all [source=<name>] [server=<address>] [out=<dir>]
--
-- --all hears every session, including ones created later.
--   source  name of this server in rex-radar (default: "local")
--   server  how readers reach this server with `rex -S`, stored in the snapshot
--           so `rex-radar open` can route a tap back (default: none = local)
--   out     directory for snapshots (default: ~/.local/state/rex-radar)
--
-- Keeps a table of every pane that has program status (OSC 7501 records),
-- and writes it to <out>/<source>.json whenever it changes (debounced) and at
-- least every 15 s, so a reader can tell a stopped watcher from a quiet one.
-- The file is replaced atomically: written to a temp file, then renamed.

local TERMINAL = "com.superlogical.terminal"
local HEARTBEAT = 15

local source = rex.args.source or "local"
local server = rex.args.server
local out = rex.args.out or (os.getenv("HOME") .. "/.local/state/rex-radar")
local path = out .. "/" .. source .. ".json"

-- panes[block_id] = { session_id, block_id, records = { [record_id] = record }, title }
local panes = {}
-- sessions[session_id] = { label, windows = { [block_id] = { window_id, window_label, index } } }
local sessions = {}

local function log(msg) rex.log("rex-radar: " .. msg) end

-- A script only sees sessions it is attached to.
local function attach(session_id) rex.call("session.attach", { session_id = session_id }) end

-- Reads a session's label and which tab holds each pane.
local function load_session(session_id)
  attach(session_id)
  local view, err = rex.session.view { session_id = session_id }
  if not view then
    log("view " .. session_id .. ": " .. tostring(err))
    return nil
  end
  local s = { label = view.label, active_window_id = view.active_window_id, windows = {} }
  for index, w in ipairs(view.windows or {}) do
    for _, layer in ipairs(w.layers or {}) do
      for _, b in ipairs(layer.blocks or {}) do
        s.windows[b.block_id] = {
          window_id = w.window_id,
          window_label = w.label,
          index = index,
          block_label = b.label,
        }
      end
    end
  end
  sessions[session_id] = s
  return s
end

local function load_pane(session_id, block_id)
  local status = rex.block.call(TERMINAL, "program_status", { session_id = session_id, block_id = block_id })
  local records = {}
  for _, r in ipairs(status and status.records or {}) do
    records[r.id or ""] = r
  end
  local p = panes[block_id] or { session_id = session_id, block_id = block_id }
  p.records = records
  local t = rex.block.call(TERMINAL, "title", { session_id = session_id, block_id = block_id })
  p.title = t and t.title or p.title
  panes[block_id] = p
  return p
end

local function load_all()
  panes, sessions = {}, {}
  local list = rex.call("session.list")
  for _, session in ipairs(list and list.sessions or {}) do
    local s = load_session(session.session_id)
    for block_id in pairs(s and s.windows or {}) do
      load_pane(session.session_id, block_id)
    end
  end
end

-- The record that speaks for a pane: the root record, else the most urgent.
local RANK = { blocked = 1, error = 2, done = 3, working = 4, idle = 5 }
local function main_record(records)
  if records[""] then return records[""] end
  local best
  for _, r in pairs(records) do
    if not best or (RANK[r.state] or 9) < (RANK[best.state] or 9) then best = r end
  end
  return best
end

local function snapshot()
  local rows = {}
  for block_id, p in pairs(panes) do
    local r = main_record(p.records or {})
    local s = sessions[p.session_id]
    local w = s and s.windows[block_id]
    if r and s and w then
      rows[#rows + 1] = {
        source = source,
        session_id = p.session_id,
        session = s.label,
        window_id = w.window_id,
        tab = w.window_label,
        tab_index = w.index,
        block_id = block_id,
        pane = w.block_label,
        title = p.title,
        app = r.effective_app or r.app,
        state = r.state,
        kind = r.kind,
        msg = r.msg,
        progress = r.progress,
        updated_at = r.updated_at,
      }
    end
  end
  return {
    format = 1,
    source = source,
    server = server,
    written_at = os.date "!%Y-%m-%dT%H:%M:%SZ",
    heartbeat_seconds = HEARTBEAT,
    panes = rows,
  }
end

local function write()
  rex.exec { "mkdir", "-p", "-m", "700", out }
  local tmp = path .. ".tmp"
  local f, err = io.open(tmp, "w")
  if not f then
    log("write " .. tmp .. ": " .. tostring(err))
    return
  end
  f:write(rex.json.encode(snapshot()))
  f:close()
  local ok, rerr = os.rename(tmp, path)
  if not ok then log("rename: " .. tostring(rerr)) end
end

-- Bursts of events (a layout change, an agent streaming status) write once.
local pending
local function schedule()
  if pending then pending:cancel() end
  pending = rex.after(0.3, function()
    pending = nil
    write()
  end)
end

rex.on("terminal.program_status_changed", function(ctx, ev)
  if not sessions[ctx.session_id] then load_session(ctx.session_id) end
  local p = panes[ctx.block_id] or { session_id = ctx.session_id, block_id = ctx.block_id, records = {} }
  p.records = p.records or {}
  p.records[ev.id or ""] = ev.record
  panes[ctx.block_id] = p
  schedule()
end)

rex.on("terminal.program_status_removed", function(ctx, ev)
  local p = panes[ctx.block_id]
  if not p then return end
  for _, id in ipairs(ev.ids or {}) do
    p.records[id] = nil
  end
  schedule()
end)

rex.on("terminal.title_changed", function(ctx, ev)
  local p = panes[ctx.block_id]
  if p then
    p.title = ev.title
    schedule()
  end
end)

rex.on("block_closed", function(ctx, ev)
  panes[ev.block_id] = nil
  schedule()
end)

-- Tabs moved, renamed, panes split: re-read the session's layout.
rex.on("session_view_changed", function(ctx, ev)
  load_session(ctx.session_id)
  schedule()
end)

rex.on("session_label_changed", function(ctx, ev)
  load_session(ctx.session_id)
  schedule()
end)

rex.on("session_destroyed", function(ctx, ev)
  sessions[ctx.session_id] = nil
  for block_id, p in pairs(panes) do
    if p.session_id == ctx.session_id then panes[block_id] = nil end
  end
  schedule()
end)

rex.every(HEARTBEAT, write)

load_all()
write()
log(("watching %s → %s"):format(source, path))
