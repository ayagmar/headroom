--!nonstrict
-- Headroom panel: one card per signed-in provider with every usage window.
--
-- Each window shows its usage meter with a thin time track beneath it: when the
-- meter runs ahead of the time track you are burning faster than the window
-- allows, and the pace line says when you would run out. Presentation only;
-- refreshes are requested from the service through shared state.

local state = require("./lib/state.luau")
local theme = require("./lib/theme.luau")
local view = require("./lib/view.luau")
local time = require("./lib/time.luau")

local report = noctalia.state.get(state.REPORT)
local isOpen = false
local lastRenderAt = 0

local CARD_FILL = "surface_variant/0.45"
local TRACK = "on_surface/0.10"

-- ── Pieces ────────────────────────────────────────────────────────────────

local function logo(provider, size: number, opacity: number?)
  local path = theme.logo(provider)
  if path then
    return ui.image({ path = path, width = size, height = size, fit = "contain", opacity = opacity or 1 })
  end
  return ui.glyph({ name = provider.brand.glyph, size = size, color = "on_surface", opacity = opacity or 1 })
end

local function caption(text: string, color: string?, extra)
  local props = { text = text, fontSize = 11, color = color or "on_surface_variant" }
  if extra then
    for k, v in extra do
      props[k] = v
    end
  end
  return ui.label(props)
end

local function windowRow(provider, window, now: number, dimmed: boolean)
  local severity = view.severity(window)
  local paceText, paceColor, pace = view.pace(window, now)
  local resets = view.resetsIn(window, now)

  local children = {
    ui.row({ align = "center", gap = 8 }, {
      ui.label({ text = window.label, fontSize = 13, color = "on_surface", flexGrow = 1, maxLines = 1 }),
      ui.label({
        text = view.percent(window),
        fontSize = 13,
        fontWeight = "semibold",
        color = view.textColor(severity),
      }),
    }),
    ui.progress({
      progress = window.usedPercent / 100,
      height = 8,
      radius = 4,
      fill = theme.meterColor(provider, severity),
      track = TRACK,
    }),
  }

  if pace then
    -- The time track: how much of this window has elapsed.
    table.insert(children, ui.column({
      tooltip = noctalia.tr("panel.elapsed_tooltip", { percent = math.floor(pace.elapsedFraction * 100 + 0.5) }),
    }, {
      ui.progress({
        progress = pace.elapsedFraction,
        height = 3,
        radius = 2,
        fill = "on_surface_variant/0.55",
        track = "on_surface/0.05",
      }),
    }))
  end

  if resets or paceText then
    table.insert(children, ui.row({ align = "center", gap = 8 }, {
      caption(resets or "", nil, { flexGrow = 1, maxLines = 1 }),
      caption(paceText or "", paceColor, { maxLines = 1 }),
    }))
  end

  return ui.column({ gap = 6, key = window.id, opacity = if dimmed then 0.6 else 1 }, children)
end

local function errorBanner(provider, compact: boolean)
  local err = provider.error
  local title = noctalia.tr(`error.{err.code}.title`)
  local body = err.hint or noctalia.tr(`error.{err.code}.body`)
  if compact and provider.snapshot and provider.snapshot.fetchedAt then
    body = noctalia.tr("panel.showing_cached", { ago = time.ago(view.now() - provider.snapshot.fetchedAt) }) .. " " .. body
  end
  return ui.row({ gap = 10, align = "center", padding = 10, radius = 10, fill = "error/0.12" }, {
    ui.glyph({ name = "alert-circle", size = 18, color = "error" }),
    ui.column({ gap = 2, flexGrow = 1 }, {
      ui.label({ text = title, fontSize = 12, fontWeight = "semibold", color = "on_surface" }),
      caption(body, nil, { maxLines = 3 }),
    }),
    ui.button({
      glyph = "refresh",
      variant = "ghost",
      controlSize = "sm",
      tooltip = noctalia.tr("panel.retry"),
      onClick = state.requestRefresh,
    }),
  })
end

local function notesBlock(notes)
  local rows = {}
  for i, note in notes do
    table.insert(rows, ui.row({ align = "center", key = `note{i}` }, {
      caption(note.label, nil, { flexGrow = 1 }),
      ui.label({
        text = note.value,
        fontSize = 11,
        fontWeight = "medium",
        color = if note.tone == "warn" then "tertiary" elseif note.tone == "muted" then "on_surface_variant" else "on_surface",
      }),
    }))
  end
  return ui.column({ gap = 4 }, rows)
end

local function providerCard(provider, now: number)
  local snapshot = provider.snapshot
  local subtitle = snapshot and snapshot.plan or nil
  if provider.busy then
    subtitle = noctalia.tr("panel.refreshing_provider")
  elseif provider.stale and snapshot and provider.status ~= "error" then
    subtitle = (if subtitle then subtitle .. " · " else "") .. noctalia.tr("panel.cached")
  end

  local header = ui.row({ align = "center", gap = 10 }, {
    logo(provider, 22),
    ui.column({ gap = 1, flexGrow = 1 }, {
      ui.label({ text = provider.name, fontSize = 14, fontWeight = "semibold", color = "on_surface" }),
      caption(subtitle or " ", nil, { visible = subtitle ~= nil }),
    }),
  })

  local body = { header }
  local dimmed = provider.status == "error"

  if provider.status == "error" and provider.error then
    table.insert(body, errorBanner(provider, snapshot ~= nil))
  end

  if snapshot and #snapshot.windows > 0 then
    for _, window in snapshot.windows do
      table.insert(body, windowRow(provider, window, now, dimmed))
    end
    if snapshot.notes and #snapshot.notes > 0 then
      table.insert(body, ui.separator({ color = "outline/0.25" }))
      table.insert(body, notesBlock(snapshot.notes))
    end
  elseif provider.status == "loading" then
    table.insert(body, caption(noctalia.tr("panel.fetching")))
  end

  return ui.column({ key = provider.id, gap = 12, padding = 14, radius = 14, fill = CARD_FILL }, body)
end

local function disconnectedRow(provider)
  local hint = noctalia.tr(`providers.{provider.id}.hint`)
  return ui.row({ key = `off-{provider.id}`, align = "center", gap = 10, padding = 10, radius = 12, border = "outline/0.25", borderWidth = 1 }, {
    logo(provider, 18, 0.5),
    ui.column({ gap = 1, flexGrow = 1 }, {
      ui.label({ text = noctalia.tr("panel.not_connected", { provider = provider.name }), fontSize = 12, color = "on_surface_variant" }),
      caption(hint, "on_surface_variant/0.8", { maxLines = 2 }),
    }),
  })
end

local function emptyState()
  return ui.column({ flexGrow = 1, gap = 10, align = "center", justify = "center", padding = 24 }, {
    ui.glyph({ name = "gauge", size = 40, color = "on_surface_variant" }),
    ui.label({ text = noctalia.tr("panel.empty_title"), fontSize = 15, fontWeight = "semibold", color = "on_surface" }),
    ui.label({ text = noctalia.tr("panel.empty_body"), fontSize = 12, color = "on_surface_variant", textAlign = "center", maxLines = 4 }),
  })
end

local function subtitle(now: number): string
  if type(report) ~= "table" then
    return noctalia.tr("panel.starting")
  elseif report.refreshing then
    return noctalia.tr("panel.refreshing")
  elseif report.lastRefreshAt then
    return noctalia.tr("panel.updated", { ago = time.ago(now - report.lastRefreshAt) })
  end
  return noctalia.tr("panel.not_refreshed")
end

-- ── Render ────────────────────────────────────────────────────────────────

local function render()
  if not isOpen then
    return
  end
  local now = view.now()
  lastRenderAt = now

  local connected, disconnected = {}, {}
  if type(report) == "table" and type(report.providers) == "table" then
    for _, provider in report.providers do
      if provider.configured then
        table.insert(connected, providerCard(provider, now))
      else
        table.insert(disconnected, disconnectedRow(provider))
      end
    end
  end

  local content
  if #connected == 0 then
    content = { emptyState() }
    for _, row in disconnected do
      table.insert(content, row)
    end
  else
    content = connected
    if #disconnected > 0 then
      table.insert(content, ui.column({ gap = 8, key = "disconnected" }, disconnected))
    end
  end

  local refreshing = type(report) == "table" and report.refreshing == true

  panel.render(ui.column({ flexGrow = 1, gap = 14 }, {
    ui.row({ align = "center", gap = 6 }, {
      ui.column({ gap = 2, flexGrow = 1 }, {
        ui.label({ text = "Headroom", fontSize = 16, fontWeight = "bold", color = "on_surface" }),
        caption(subtitle(now)),
      }),
      ui.button({
        glyph = "refresh",
        variant = "ghost",
        controlSize = "sm",
        enabled = not refreshing,
        tooltip = noctalia.tr("panel.refresh_tooltip"),
        onClick = state.requestRefresh,
      }),
      ui.button({
        glyph = "settings",
        variant = "ghost",
        controlSize = "sm",
        tooltip = noctalia.tr("panel.settings_tooltip"),
        onClick = function()
          panel.close()
          noctalia.openSettings()
        end,
      }),
    }),
    ui.scroll({ flexGrow = 1, gap = 12 }, content),
  }))
end

-- ── Host callbacks ────────────────────────────────────────────────────────

noctalia.state.watch(state.REPORT, function(value)
  report = value
  render()
end)

function onOpen(_context)
  isOpen = true
  report = noctalia.state.get(state.REPORT)
  panel.setWantsSecondTicks(true)
  render()
end

function onClose()
  isOpen = false
  panel.setWantsSecondTicks(false)
end

-- Second ticks keep "updated 2m ago" and the countdowns honest; minute
-- precision is all they show, so a re-render every 15s is plenty.
function update()
  if isOpen and view.now() - lastRenderAt >= 15 then
    render()
  end
end

function onKey(chord, pressed)
  if not pressed then
    return
  end
  if chord == "r" then
    state.requestRefresh()
  elseif chord == "escape" then
    panel.close()
  end
end
