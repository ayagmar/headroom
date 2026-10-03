--!nonstrict
-- Presentation helpers shared by the bar and the panel, so both surfaces word
-- and color the same window the same way.

local model = require("./model.luau")
local pace = require("./pace.luau")
local state = require("./state.luau")
local time = require("./time.luau")
local theme = require("./theme.luau")

local M = {}

function M.now(): number
  return math.floor(noctalia.nowMs() / 1000)
end

local RANK = { ok = 0, warn = 1, critical = 2 }

-- Usage severity, raised by the forecast when `pace_colors` is on: a window at
-- 60% that will lock you out for hours deserves the warning color now.
function M.severity(window, now: number?): string
  local warn, critical = state.thresholds()
  local severity = model.severity(window.usedPercent, warn, critical)
  if now ~= nil and state.config("pace_colors", true) then
    local p = pace.compute(window, now)
    if p and RANK[p.severity] > RANK[severity] then
      severity = p.severity
    end
  end
  return severity
end

-- Text color for a percentage at a severity.
function M.textColor(severity: string): string
  return theme.severityColor(severity) or "on_surface"
end

function M.percent(window): string
  return `{math.floor(window.usedPercent + 0.5)}%`
end

-- Wall-clock time of a reset in the shell's own time format, with the weekday
-- when it is more than a day away: "20:19", "Sat 09:59".
function M.clock(at: number, now: number): string
  local format = if noctalia.timeFormat then noctalia.timeFormat() else "%H:%M"
  local clock = noctalia.formatTime(format, at)
  if at - now >= 86400 then
    return `{noctalia.formatTime("%a", at)} {clock}`
  end
  return clock
end

-- "Resets in 3h 12m · 20:19", or nil when the vendor gave no reset time.
function M.resetsIn(window, now: number, withClock: boolean?): string?
  if window.resetsAt == nil then
    return nil
  end
  local remaining = window.resetsAt - now
  if remaining <= 0 then
    return noctalia.tr("reset.now")
  end
  if withClock then
    return noctalia.tr("reset.in_at", { duration = time.duration(remaining), clock = M.clock(window.resetsAt, now) })
  end
  return noctalia.tr("reset.in", { duration = time.duration(remaining) })
end

-- Forecast as (text, color role, pace), or nil when it is too early to say.
function M.pace(window, now: number): (string?, string?, pace.Pace?)
  local p = pace.compute(window, now)
  if p == nil then
    return nil, nil, nil
  end
  if p.status == "exhausted" then
    return noctalia.tr("pace.exhausted"), "error", p
  elseif p.status == "runs_out" then
    local color = if p.severity == "ok" then "on_surface_variant" else M.textColor(p.severity)
    return noctalia.tr("pace.runs_out", { duration = time.duration(p.runsOutIn or 0) }), color, p
  elseif p.status == "projected" then
    return noctalia.tr("pace.projected", { percent = math.floor((p.projectedPercent or 0) + 0.5) }), "on_surface_variant", p
  end
  return nil, nil, p
end

-- Providers that can be shown at all (signed in), in registry order.
function M.visibleProviders(report): { any }
  local out = {}
  if type(report) ~= "table" or type(report.providers) ~= "table" then
    return out
  end
  for _, view in report.providers do
    if view.configured then
      table.insert(out, view)
    end
  end
  return out
end

-- What a bar capsule shows: a list of { view, window? } pairs.
--   providerSetting: "all" | "auto" | <provider id>
--   windowPref:      "tightest" | "session" | "weekly"
function M.barItems(report, providerSetting: string, windowPref: string): { any }
  local items = {}
  for _, view in M.visibleProviders(report) do
    if providerSetting == "all" or providerSetting == "auto" or providerSetting == view.id then
      local windows = view.snapshot and view.snapshot.windows or {}
      table.insert(items, { view = view, window = model.pick(windows, windowPref) })
    end
  end
  if providerSetting == "auto" and #items > 1 then
    local best = items[1]
    for _, item in items do
      local pct = item.window and item.window.usedPercent or -1
      local bestPct = best.window and best.window.usedPercent or -1
      if pct > bestPct then
        best = item
      end
    end
    return { best }
  end
  return items
end

return M
