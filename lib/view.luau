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

function M.severity(window): string
  local warn, critical = state.thresholds()
  return model.severity(window.usedPercent, warn, critical)
end

-- Text color for a percentage at a severity.
function M.textColor(severity: string): string
  return theme.SEVERITY_ROLE[severity] or "on_surface"
end

function M.percent(window): string
  return `{math.floor(window.usedPercent + 0.5)}%`
end

-- "Resets in 3h 12m", or nil when the vendor gave no reset time.
function M.resetsIn(window, now: number): string?
  if window.resetsAt == nil then
    return nil
  end
  local remaining = window.resetsAt - now
  if remaining <= 0 then
    return noctalia.tr("reset.now")
  end
  return noctalia.tr("reset.in", { duration = time.duration(remaining) })
end

-- Pace verdict as (text, color role), or nil when there is nothing to say yet.
function M.pace(window, now: number): (string?, string?, pace.Pace?)
  local p = pace.compute(window, now)
  if p == nil then
    return nil, nil, nil
  end
  if p.status == "exhausted" then
    return noctalia.tr("pace.exhausted"), "error", p
  elseif p.status == "runs_out" then
    return noctalia.tr("pace.runs_out", { duration = time.duration(p.runsOutIn or 0) }), "error", p
  elseif p.status == "under" then
    return noctalia.tr("pace.under", { points = math.floor(-p.delta + 0.5) }), "on_surface_variant", p
  end
  -- Too early in the window for a verdict: stay quiet rather than say "on track".
  if p.elapsedFraction < 0.05 then
    return nil, nil, p
  end
  return noctalia.tr("pace.on_track"), "on_surface_variant", p
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
