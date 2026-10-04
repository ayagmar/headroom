--!nonstrict
local t = require("./support/t")
local env = require("./support/env")

-- A host with both providers signed in and the service running.
local function running(opts)
  opts = opts or {}
  local host = env.host()
  local json = host.globals.noctalia.json
  env.claudeCreds(host)
  env.codexAuth(host)
  local claude = json.decode(env.fixture("claude_usage.json"))
  if opts.claudeSession then
    claude.limits[1].percent = opts.claudeSession
  end
  env.serve(host, {
    ["api.anthropic.com"] = json.encode(claude),
    ["chatgpt.com"] = opts.codexResponse or env.fixture("codex_usage.json"),
  })
  for k, v in opts.config or {} do
    host.config[k] = v
  end
  local svc = env.start(host, "service.luau")
  return host, svc
end

local function images(tree)
  return env.find(tree, function(n) return n.type == "image" end)
end

t.group("bar", function()
  t.test("one capsule per signed-in provider with logo, ring and value", function()
    local host = running()
    env.start(host, "bar.luau")
    local texts = env.texts(host.barTree)
    -- Claude's tightest window is weekly (47%), Codex's is the session (51%).
    t.contains(texts, "47%")
    t.contains(texts, "51%")
    local imgs = images(host.barTree)
    t.eq(#imgs, 4, "logo + ring per provider")
    t.ok(host.files[imgs[1].props.path] ~= nil, "tinted logo written")
    t.ok(host.files[imgs[1].props.path]:find('fill="#d97757"', 1, true) ~= nil, "Claude logo tinted with its brand color")
    t.ok(imgs[2].props.path:find("/data/rings/ring%-47%-") ~= nil, imgs[2].props.path)
    env.noMissingKeys(t, host)
  end)

  t.test("tooltip uses one short row per fact", function()
    local host = running()
    host.clock = 1791100799 - 2 * 86400 -- Claude weekly 5/7 elapsed: has a forecast
    env.start(host, "bar.luau")
    local rows = host.tooltip
    t.eq(rows[1].key, "Claude · Weekly")
    t.eq(rows[1].value, "47% used")
    t.eq(rows[2].key, "Resets")
    t.eq(rows[2].value, "2d · Sun 07:59")
    t.eq(rows[3].key, "Forecast")
    t.eq(rows[3].value, "≈ 66% by reset")
    for _, row in rows do
      t.ok(#row.value <= 24, `short value: {row.value}`)
    end
  end)

  t.test("max_providers keeps the most urgent, in registry order", function()
    local host = running({ claudeSession = 88, config = { max_providers = 1 } })
    env.start(host, "bar.luau")
    local texts = env.texts(host.barTree)
    t.eq(#texts, 1)
    t.eq(texts[1], "88%")
  end)

  t.test("remaining mode inverts numbers and rings, not colors", function()
    local host = running({ claudeSession = 95, config = { provider = "claude", window = "session", display = "remaining" } })
    env.start(host, "bar.luau")
    local label = env.find(host.barTree, function(n) return n.type == "label" end)[1]
    t.eq(label.props.text, "5%")
    t.eq(label.props.color, "error", "severity still follows usage")
    local ring = env.find(host.barTree, function(n) return n.type == "image" end)[2]
    t.ok(ring.props.path:find("ring%-5%-") ~= nil, ring.props.path)
    t.eq(host.tooltip[1].value, "5% left")
  end)

  t.test("window preference and severity colors", function()
    local host = running({ claudeSession = 95, config = { provider = "claude", window = "session" } })
    env.start(host, "bar.luau")
    local label = env.find(host.barTree, function(n) return n.type == "label" end)[1]
    t.eq(label.props.text, "95%")
    t.eq(label.props.color, "error")
  end)

  t.test("vertical bars drop the percent sign", function()
    local host = running({ config = { provider = "codex" } })
    host.vertical = true
    env.start(host, "bar.luau")
    t.eq(host.barTree.type, "column")
    t.contains(env.texts(host.barTree), "51")
  end)

  t.test("empty state when nothing is signed in", function()
    local host = env.host()
    env.start(host, "service.luau")
    env.start(host, "bar.luau")
    t.eq(env.find(host.barTree, function(n) return n.type == "glyph" end)[1].props.name, "gauge")
    t.eq(host.tooltip, "Headroom: no Claude, Codex or Antigravity sign-in found")
  end)

  t.test("forecast raises the color before the threshold", function()
    -- Session at 60% with 4h of 5h left: on course to be locked out for hours.
    local host = running({ claudeSession = 60, config = { provider = "claude", window = "session" } })
    host.clock = 1791058799 - 3 * 3600 -- 2h elapsed, 60% used -> runs out after 1h20m more, 1h40m locked out
    env.start(host, "bar.luau")
    local label = env.find(host.barTree, function(n) return n.type == "label" end)[1]
    t.eq(label.props.text, "60%")
    t.eq(label.props.color, "#f2b84b")
    t.eq(host.tooltip[3].value, "Runs out in 1h 20m")
  end)

  t.test("forecast colors can be turned off", function()
    local host = running({ claudeSession = 60, config = { provider = "claude", window = "session", pace_colors = false } })
    host.clock = 1791058799 - 3 * 3600
    env.start(host, "bar.luau")
    local label = env.find(host.barTree, function(n) return n.type == "label" end)[1]
    t.eq(label.props.color, "on_surface")
  end)

  t.test("a maxed-out window shows when it comes back", function()
    local host = running({ claudeSession = 100, config = { provider = "claude", window = "session" } })
    host.clock = 1791058799 - 4500
    env.start(host, "bar.luau")
    local label = env.find(host.barTree, function(n) return n.type == "label" end)[1]
    t.eq(label.props.text, "1h 15m")
    t.eq(label.props.color, "error")
  end)

  t.test("left click opens the panel", function()
    local host = running()
    local bar = env.start(host, "bar.luau")
    bar.call("onClick")
    t.eq(host.toggledPanels[1], "ayagmar/headroom:panel")
  end)

  t.test("re-renders when the report changes", function()
    local host, svc = running({ config = { provider = "codex" } })
    env.start(host, "bar.luau")
    local json = host.globals.noctalia.json
    local codex = json.decode(env.fixture("codex_usage.json"))
    codex.rate_limit.primary_window.used_percent = 77
    env.serve(host, { ["chatgpt.com"] = json.encode(codex), ["api.anthropic.com"] = env.fixture("claude_usage.json") })
    svc.call("onIpc", "refresh")
    t.contains(env.texts(host.barTree), "77%")
  end)
end)

t.group("panel", function()
  t.test("renders a card per provider with every window", function()
    local host = running()
    local panel = env.start(host, "panel.luau")
    panel.call("onOpen", "")
    local texts = env.texts(host.panelTree)
    t.contains(texts, "Headroom")
    t.contains(texts, "Claude")
    t.contains(texts, "Team 5x")
    t.contains(texts, "Codex")
    t.contains(texts, "Plus")
    t.contains(texts, "Weekly · Fable")
    t.contains(texts, "38%")
    t.contains(texts, "16%")
    local progress = env.find(host.panelTree, function(n) return n.type == "progress" end)
    t.ok(#progress >= 5, "a meter per window")
    env.noMissingKeys(t, host)
  end)

  t.test("pace verdict appears once a window is under way", function()
    local host = running()
    -- Two and a half hours before the Codex session resets: half of 5h elapsed, 51% used.
    host.clock = 1791056429 - 9000
    local panel = env.start(host, "panel.luau")
    panel.call("onOpen", "")
    local texts = env.texts(host.panelTree)
    -- 51% at the halfway mark runs out 2% before the reset: worth saying, not alarming.
    t.contains(texts, "Runs out in 2h 24m")
    t.contains(texts, "Resets in 2h 30m · 19:40")
  end)

  t.test("error banner explains how to recover", function()
    local host = running({ codexResponse = { ok = true, status = 401, body = "" } })
    local panel = env.start(host, "panel.luau")
    panel.call("onOpen", "")
    local texts = env.texts(host.panelTree)
    t.contains(texts, "Sign-in rejected")
    t.contains(texts, "Run `codex login` and sign in with ChatGPT.")
  end)

  t.test("disconnected providers are listed with a hint", function()
    local host = env.host()
    env.claudeCreds(host)
    env.serve(host, { ["api.anthropic.com"] = env.fixture("claude_usage.json") })
    env.start(host, "service.luau")
    local panel = env.start(host, "panel.luau")
    panel.call("onOpen", "")
    t.contains(env.texts(host.panelTree), "Codex · not connected")
  end)

  t.test("empty state when nothing is signed in", function()
    local host = env.host()
    env.start(host, "service.luau")
    local panel = env.start(host, "panel.luau")
    panel.call("onOpen", "")
    t.contains(env.texts(host.panelTree), "No AI subscriptions found")
    env.noMissingKeys(t, host)
  end)

  t.test("each card links to the vendor's usage page", function()
    local host = running()
    local panel = env.start(host, "panel.luau")
    panel.call("onOpen", "")
    local buttons = env.find(host.panelTree, function(n) return n.type == "button" and n.props.glyph == "external-link" end)
    t.eq(#buttons, 2)
    t.eq(buttons[1].props.tooltip, "Open Claude usage page")
    buttons[1].props.onClick()
    t.eq(host.spawned[1][1], "xdg-open")
    t.eq(host.spawned[1][2], "https://claude.ai/settings/usage")
  end)

  t.test("no usage-page buttons without xdg-open", function()
    local host = running()
    host.commands["xdg-open"] = nil
    local panel = env.start(host, "panel.luau")
    panel.call("onOpen", "")
    t.eq(#env.find(host.panelTree, function(n) return n.props.glyph == "external-link" end), 0)
  end)

  t.test("projection and weekday reset for long windows", function()
    local host = running()
    host.clock = 1791100799 - 2 * 86400 -- weekly: 5 of 7 days elapsed
    local panel = env.start(host, "panel.luau")
    panel.call("onOpen", "")
    local texts = env.texts(host.panelTree)
    t.contains(texts, "Resets in 2d · Sun 07:59")
    t.contains(texts, "≈ 22% by reset") -- Fable: 16% after 5/7 of the week
    env.noMissingKeys(t, host)
  end)

  t.test("remaining mode labels the panel too", function()
    local host = running({ config = { display = "remaining" } })
    host.clock = 1791100799 - 2 * 86400
    local panel = env.start(host, "panel.luau")
    panel.call("onOpen", "")
    local texts = env.texts(host.panelTree)
    t.contains(texts, "62% left") -- Claude session at 38% used
    t.contains(texts, "≈ 34% left at reset")
    env.noMissingKeys(t, host)
  end)

  t.test("R requests a refresh", function()
    local host = running()
    local panel = env.start(host, "panel.luau")
    panel.call("onOpen", "")
    local before = #host.requests
    panel.call("onKey", "r", true)
    t.eq(#host.requests, before + 2)
  end)

  t.test("does not render while closed", function()
    local host = running()
    env.start(host, "panel.luau")
    t.eq(host.panelTree, nil)
  end)
end)

return true
