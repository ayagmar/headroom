--!nonstrict
-- Headroom bar capsule: a logo, a ring gauge and a percentage per provider.
--
-- Presentation only: it watches the report the service publishes and never
-- fetches. Left click opens the panel; right click asks the service for a
-- refresh (bound in plugin.toml, so users can rebind it).

local state = require("./lib/state.luau")
local theme = require("./lib/theme.luau")
local view = require("./lib/view.luau")
local time = require("./lib/time.luau")

local ICON_SIZE = 15

local report = noctalia.state.get(state.REPORT)

local function setting(key: string, fallback: any): any
  return state.config(key, fallback)
end

local function providerIcon(provider, dimmed: boolean)
  local path = theme.logo(provider)
  if path then
    return ui.image({ path = path, width = ICON_SIZE, height = ICON_SIZE, fit = "contain", opacity = if dimmed then 0.55 else 1 })
  end
  return ui.glyph({ name = provider.brand.glyph, size = ICON_SIZE, color = "on_surface" })
end

local function itemNodes(item, vertical: boolean)
  local provider, window = item.view, item.window
  local nodes = {}
  local dimmed = provider.stale or provider.status == "error"

  if setting("show_logo", true) then
    table.insert(nodes, providerIcon(provider, dimmed and window == nil))
  end

  if window == nil then
    -- Signed in but no numbers yet (first fetch running) or nothing usable.
    if provider.status == "error" then
      table.insert(nodes, ui.glyph({ name = "alert-triangle", size = ICON_SIZE - 2, color = "error" }))
    else
      table.insert(nodes, ui.label({ text = "…", color = "on_surface_variant" }))
    end
    return nodes
  end

  local now = view.now()
  local severity = view.severity(window, now)
  if setting("show_ring", true) then
    local ring = theme.ring(view.shownPercent(window), theme.meterColor(provider, severity), "surface_variant")
    if ring then
      table.insert(nodes, ui.image({ path = ring, width = ICON_SIZE, height = ICON_SIZE, opacity = if dimmed then 0.6 else 1 }))
    end
  end
  -- At the limit the percentage says nothing new; when you get it back does.
  local exhausted = window.limitReached and window.resetsAt ~= nil and window.resetsAt > now
  if setting("show_value", true) then
    local text
    if exhausted then
      text = time.duration(window.resetsAt - now)
    elseif vertical then
      text = view.roundPercent(view.shownPercent(window))
    else
      text = view.percent(window)
    end
    table.insert(nodes, ui.label({
      text = text,
      color = view.textColor(severity),
      fontWeight = if severity == "ok" then "medium" else "bold",
      opacity = if dimmed then 0.7 else 1,
    }))
  end
  if setting("show_countdown", false) and window.resetsAt and not vertical and not exhausted then
    table.insert(nodes, ui.label({
      text = time.duration(window.resetsAt - now),
      color = "on_surface_variant",
    }))
  end
  return nodes
end

-- One short row per fact, so the tooltip never truncates:
--   Claude · Weekly   59% used (cached)
--   Resets            6h 5m · 07:59
--   Forecast          ≈ 61% by reset
local function tooltipRows(items)
  local rows = {}
  local now = view.now()
  for _, item in items do
    local provider, window = item.view, item.window
    if window then
      local value = view.percent(window, true)
      if provider.stale then
        value ..= ` ({noctalia.tr("bar.stale")})`
      end
      table.insert(rows, { key = `{provider.name} · {window.label}`, value = value })
      if window.resetsAt and window.resetsAt > now then
        table.insert(rows, {
          key = noctalia.tr("tooltip.resets"),
          value = `{time.duration(window.resetsAt - now)} · {view.clock(window.resetsAt, now)}`,
        })
      end
      local forecast = view.pace(window, now)
      if forecast and window.usedPercent < 100 then
        table.insert(rows, { key = noctalia.tr("tooltip.forecast"), value = forecast })
      end
    else
      local value = if provider.status == "error" and provider.error
        then noctalia.tr(`error.{provider.error.code}.title`)
        else noctalia.tr("bar.loading")
      table.insert(rows, { key = provider.name, value = value })
    end
  end
  return rows
end

local function render()
  local vertical = barWidget.isVertical()
  local maxProviders = math.clamp(setting("max_providers", 3), 1, 8)
  local items = view.barItems(report, setting("provider", "all"), setting("window", "tightest"), maxProviders, view.now())

  if #items == 0 then
    barWidget.render(ui.row({ gap = 4, align = "center" }, {
      ui.glyph({ name = "gauge", size = ICON_SIZE, color = "on_surface_variant" }),
    }))
    barWidget.setTooltip(noctalia.tr("bar.empty"))
    return
  end

  local groups = {}
  for _, item in items do
    local container = if vertical then ui.column else ui.row
    table.insert(groups, container({ gap = 4, align = "center", key = item.view.id }, itemNodes(item, vertical)))
  end
  local outer = if vertical then ui.column else ui.row
  barWidget.render(outer({ gap = if vertical then 8 else 10, align = "center" }, groups))
  barWidget.setTooltip(tooltipRows(items))
end

noctalia.state.watch(state.REPORT, function(value)
  report = value
  render()
end)

-- Ticks only keep countdowns and the tooltip current; data arrives via watch.
function update()
  render()
end

function onClick()
  noctalia.togglePanel(state.PANEL_ID)
end

noctalia.setUpdateInterval(30000)
render()
