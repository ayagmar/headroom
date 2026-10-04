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
--   reads    each provider's saved sign-in (read-only); see providers/*
--   spawns   only what adapters declare (Antigravity: secret-tool, agy)
--   writes   <pluginDataDir>/cache.json (snapshots only, never credentials)

local registry = require("./providers/registry.luau")
local model = require("./lib/model.luau")
local scheduler = require("./lib/scheduler.luau")
local context = require("./lib/context.luau")
local state = require("./lib/state.luau")
local time = require("./lib/time.luau")
local notify = require("./lib/notify.luau")

local E = model.ErrorCode
local TICK_MS = 5000

local ctx = context.new(noctalia, `headroom-noctalia/{state.VERSION}`)

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

-- Providers the user switched off: never fetched, never shown.
local function isDisabled(id: string): boolean
  local list = noctalia.getConfig("disabled_providers")
  if type(list) ~= "table" then
    return false
  end
  for _, entry in list do
    if type(entry) == "string" and entry:lower():gsub("%s", "") == id then
      return true
    end
  end
  return false
end

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
    if isDisabled(p.id) then
      continue
    end
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

local function sendNotifications(p, rt: Runtime, previous: model.Snapshot?)
  local _, critical = state.thresholds()
  local messages = notify.messages(p.name, previous, rt.snapshot, rt.notified, {
    critical = critical,
    low = state.config("notify", true) == true,
    reset = state.config("notify_reset", true) == true,
    now = ctx.now(),
    tr = noctalia.tr,
    duration = time.duration,
  })
  for _, message in messages do
    noctalia.notify(message.title, message.body)
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
      sendNotifications(p, rt, previous)
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
    if isDisabled(p.id) then
      continue
    end
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
