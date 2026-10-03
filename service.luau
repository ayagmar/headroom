--!nonstrict
-- Headroom poller: the one entry that talks to the network.
--
-- Every tick it walks the provider registry, fetches whatever the scheduler says
-- is due, and publishes one normalized report to noctalia.state for the bar and
-- panel to draw. The last good snapshots are cached on disk so the bar shows
-- numbers immediately after login instead of an empty state (stale-while-
-- revalidate), and threshold notifications fire from here exactly once per crossing.
--
-- Side effects, for review:
--   network  GET to each configured provider's usage endpoint (see providers/*)
--   reads    each provider's credentials file (read-only)
--   writes   <pluginDataDir>/cache.json (snapshots only, never credentials)

local registry = require("./providers/registry.luau")
local model = require("./lib/model.luau")
local scheduler = require("./lib/scheduler.luau")
local http = require("./lib/http.luau")
local state = require("./lib/state.luau")
local time = require("./lib/time.luau")

local E = model.ErrorCode
local TICK_MS = 5000

local function decodeJson(text: string)
  return noctalia.json.decode(text)
end

local ctx = {
  now = function()
    return math.floor(noctalia.nowMs() / 1000)
  end,
  env = noctalia.getenv,
  expandPath = noctalia.expandPath,
  fileExists = noctalia.fileExists,
  readJson = function(path: string)
    local text, err = noctalia.readFile(path)
    if text == nil then
      return nil, err
    end
    return decodeJson(text)
  end,
  decodeJson = decodeJson,
  getJson = http.client(noctalia.http, decodeJson),
  tr = noctalia.tr,
  userAgent = `headroom-noctalia/{state.VERSION}`,
}

-- ── Per-provider runtime state ─────────────────────────────────────────────

type Runtime = {
  schedule: scheduler.Entry,
  configured: boolean,
  snapshot: model.Snapshot?,
  error: model.ProviderError?,
  stale: boolean,
  notified: { [string]: number }, -- window id -> resetsAt we already warned about
}

local runtimes: { [string]: Runtime } = {}
for _, p in registry do
  runtimes[p.id] = {
    schedule = scheduler.new(),
    configured = false,
    snapshot = nil,
    error = nil,
    stale = false,
    notified = {},
  }
end

local lastRefreshAt: number? = nil

local function intervalSeconds(): number
  return math.clamp(state.config("refresh_minutes", 5), 1, 120) * 60
end

-- ── Cache ──────────────────────────────────────────────────────────────────

local function cachePath(): string?
  local dir = noctalia.pluginDataDir()
  return if dir then `{dir}/cache.json` else nil
end

local function saveCache()
  local path = cachePath()
  if path == nil then
    return
  end
  local doc = { version = 1, providers = {} }
  for id, rt in runtimes do
    if rt.snapshot then
      doc.providers[id] = { snapshot = rt.snapshot, notified = rt.notified }
    end
  end
  local text = noctalia.json.encode(doc)
  if text then
    noctalia.writeFile(path, text)
  end
end

local function loadCache()
  local path = cachePath()
  if path == nil or not noctalia.fileExists(path) then
    return
  end
  local doc = ctx.readJson(path)
  if type(doc) ~= "table" or doc.version ~= 1 or type(doc.providers) ~= "table" then
    return
  end
  for id, entry in doc.providers do
    local rt = runtimes[id]
    if rt and type(entry) == "table" and type(entry.snapshot) == "table" and type(entry.snapshot.windows) == "table" then
      rt.snapshot = entry.snapshot
      rt.stale = true
      rt.notified = if type(entry.notified) == "table" then entry.notified else {}
    end
  end
end

-- ── Publishing ─────────────────────────────────────────────────────────────

local function statusOf(rt: Runtime): string
  if not rt.configured then
    return "absent"
  elseif rt.error ~= nil then
    return "error"
  elseif rt.snapshot == nil then
    return "loading"
  end
  return "ok"
end

local function publish()
  local now = ctx.now()
  local views = {}
  local refreshing = false
  for _, p in registry do
    local rt = runtimes[p.id]
    local busy = scheduler.isBusy(rt.schedule, now)
    refreshing = refreshing or busy
    table.insert(views, {
      id = p.id,
      name = p.name,
      brand = p.brand,
      configured = rt.configured,
      status = statusOf(rt),
      snapshot = rt.snapshot,
      error = rt.error,
      stale = rt.stale,
      busy = busy,
    })
  end
  noctalia.state.set(state.REPORT, {
    refreshing = refreshing,
    lastRefreshAt = lastRefreshAt,
    providers = views,
  })
end

-- ── Notifications ──────────────────────────────────────────────────────────

-- Warns once per window per reset cycle when usage crosses the critical
-- threshold. Keyed by resetsAt, so the next cycle can warn again.
local function notifyCrossings(p, rt: Runtime, previous: model.Snapshot?)
  if state.config("notify", true) ~= true or rt.snapshot == nil then
    return
  end
  local _, critical = state.thresholds()
  local before = {}
  if previous then
    for _, w in previous.windows do
      before[w.id] = w.usedPercent
    end
  end
  for _, w in rt.snapshot.windows do
    local cycle = w.resetsAt or 0
    local crossed = w.usedPercent >= critical and (before[w.id] or 0) < critical
    if crossed and rt.notified[w.id] ~= cycle then
      rt.notified[w.id] = cycle
      local body = if w.resetsAt
        then noctalia.tr("notify.body_reset", { window = w.label, percent = math.floor(w.usedPercent), reset = time.duration(w.resetsAt - ctx.now()) })
        else noctalia.tr("notify.body", { window = w.label, percent = math.floor(w.usedPercent) })
      noctalia.notify(noctalia.tr("notify.title", { provider = p.name }), body)
    end
  end
end

-- ── Fetching ───────────────────────────────────────────────────────────────

local function withHint(p, err: model.ProviderError): model.ProviderError
  if err.code == E.NotConfigured or err.code == E.Expired or err.code == E.Auth then
    err.hint = p.signInHint(ctx)
  end
  return err
end

local function fetchProvider(p, rt: Runtime, now: number)
  local generation = scheduler.start(rt.schedule, now)
  publish()
  local ok, thrown = pcall(p.fetch, ctx, function(snapshot, err)
    local finishedAt = ctx.now()
    if not scheduler.finish(rt.schedule, generation, finishedAt, intervalSeconds(), err) then
      return -- superseded by a newer request
    end
    lastRefreshAt = finishedAt
    if err then
      rt.error = withHint(p, err)
      rt.stale = rt.snapshot ~= nil
      noctalia.log(`[headroom] {p.id}: {err.code}{if err.detail then " (" .. err.detail .. ")" else ""}`)
    else
      local previous = rt.snapshot
      rt.snapshot = snapshot
      rt.error = nil
      rt.stale = false
      notifyCrossings(p, rt, previous)
      saveCache()
    end
    publish()
  end)
  if not ok then
    -- A bug in an adapter must not take the other providers down with it.
    noctalia.log(`[headroom] {p.id}: adapter error: {thrown}`)
    scheduler.finish(rt.schedule, generation, ctx.now(), intervalSeconds(), model.err(E.Parse, "adapter error"))
    rt.error = model.err(E.Parse, "adapter error")
    publish()
  end
end

local function tick()
  local now = ctx.now()
  local changed = false
  for _, p in registry do
    local rt = runtimes[p.id]
    local configured = p.isConfigured(ctx)
    if configured ~= rt.configured then
      rt.configured = configured
      changed = true
      if configured then
        scheduler.force(rt.schedule, now) -- signed in since the last tick
      else
        rt.error = nil
      end
    end
    if configured and scheduler.isDue(rt.schedule, now) then
      fetchProvider(p, rt, now)
      changed = false -- fetchProvider published
    end
  end
  if changed then
    publish()
  end
end

local function refreshAll()
  local now = ctx.now()
  for _, p in registry do
    scheduler.force(runtimes[p.id].schedule, now)
  end
  tick()
end

-- ── Host callbacks ─────────────────────────────────────────────────────────

function update()
  tick()
end

function onIpc(event, _payload)
  if event == "refresh" then
    refreshAll()
  end
end

function onConfigChanged()
  -- A new interval applies from now on; reschedule so a shorter one takes effect.
  local now = ctx.now()
  for _, p in registry do
    local rt = runtimes[p.id]
    if rt.error == nil and rt.snapshot ~= nil then
      rt.schedule.nextAt = math.min(rt.schedule.nextAt, now + intervalSeconds())
    end
  end
  publish()
end

noctalia.state.watch(state.COMMAND, function(command)
  if type(command) == "table" and command.action == "refresh" then
    refreshAll()
  end
end)

loadCache()
noctalia.setUpdateInterval(TICK_MS)
tick()
publish() -- even with nothing signed in, so surfaces leave their "starting" state
