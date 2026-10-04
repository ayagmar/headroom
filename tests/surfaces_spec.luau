--!nonstrict
local t = require("./support/t")
local env = require("./support/env")

-- Claude and Codex signed in, the service running.
local function running(opts)
  opts = opts or {}
  local host = env.host()
  env.claudeCreds(host)
  env.codexAuth(host)
  env.serve(host, {
    ["api.anthropic.com"] = env.claudeBody(host, opts.claudeSession),
    ["chatgpt.com"] = opts.codexResponse or env.fixture("codex_usage.json"),
  })
  for k, v in opts.config or {} do
    host.config[k] = v
  end
  local svc = env.start(host, "service.luau")
  return host, svc
end

local function firstLabel(tree)
  return env.ofType(tree, "label")[1].props
end

local function openPanel(host)
  local panel = env.start(host, "panel.luau")
  panel.call("onOpen", "")
  return panel, env.texts(host.panelTree)
end

t.group("bar", function()
  t.test("logo, ring and value per signed-in provider", function()
    local host = running()
    env.start(host, "bar.luau")
    local texts = env.texts(host.barTree)
    -- Claude's tightest window is weekly (47%), Codex's is the session (51%).
    t.contains(texts, "47%")
    t.contains(texts, "51%")
    local images = env.ofType(host.barTree, "image")
    t.eq(#images, 4)
    t.ok(host.files[images[1].props.path]:find('fill="#d97757"', 1, true) ~= nil, "logo tinted with the brand color")
    t.ok(images[2].props.path:find("/data/rings/ring%-47%-") ~= nil, images[2].props.path)
  end)

  t.test("bar style: percentage only", function()
    local host = running({ config = { bar_style = "value" } })
    env.start(host, "bar.luau")
    t.eq(#env.ofType(host.barTree, "image"), 2, "logos only, no rings")
  end)

  t.test("tooltip: one short row per fact", function()
    local host = running()
    host.clock = 1791100799 - 2 * 86400 -- Claude weekly 5/7 elapsed
    env.start(host, "bar.luau")
    local rows = host.tooltip
    t.eq(rows[1].key, "Claude · Weekly")
    t.eq(rows[1].value, "47% used")
    t.eq(rows[2].value, "2d · Sun 07:59")
    t.eq(rows[3].value, "≈ 66% by reset")
  end)

  t.test("providers can be switched off in the bar", function()
    local host = running({ config = { bar_claude = false } })
    env.start(host, "bar.luau")
    t.eq(table.concat(env.texts(host.barTree), ","), "51%")
  end)

  t.test("max_providers keeps the most urgent", function()
    local host = running({ claudeSession = 88, config = { max_providers = 1 } })
    env.start(host, "bar.luau")
    t.eq(table.concat(env.texts(host.barTree), ","), "88%")
  end)

  t.test("remaining mode inverts numbers and rings, not colors", function()
    local host = running({ claudeSession = 95, config = { bar_codex = false, window = "session", display = "remaining" } })
    env.start(host, "bar.luau")
    t.eq(firstLabel(host.barTree).text, "5%")
    t.eq(firstLabel(host.barTree).color, "error", "severity follows usage")
    t.ok(env.ofType(host.barTree, "image")[2].props.path:find("ring%-5%-") ~= nil)
    t.eq(host.tooltip[1].value, "5% left")
  end)

  t.test("forecast raises the color before the threshold", function()
    local host = running({ claudeSession = 60, config = { bar_codex = false, window = "session" } })
    host.clock = 1791058799 - 3 * 3600 -- 2h in, 60% used: locked out for 1h40m
    env.start(host, "bar.luau")
    t.eq(firstLabel(host.barTree).color, "#f2b84b")
    t.eq(host.tooltip[3].value, "Runs out in 1h 20m")
  end)

  t.test("a maxed-out window shows when it comes back", function()
    local host = running({ claudeSession = 100, config = { bar_codex = false, window = "session" } })
    host.clock = 1791058799 - 4500
    env.start(host, "bar.luau")
    t.eq(firstLabel(host.barTree).text, "1h 15m")
  end)

  t.test("vertical bars drop the percent sign", function()
    local host = running({ config = { bar_claude = false } })
    host.vertical = true
    env.start(host, "bar.luau")
    t.eq(host.barTree.type, "column")
    t.contains(env.texts(host.barTree), "51")
  end)

  t.test("follows the report as it changes", function()
    local host, svc = running({ config = { bar_codex = false, window = "session" } })
    env.start(host, "bar.luau")
    env.serve(host, { ["api.anthropic.com"] = env.claudeBody(host, 77), ["chatgpt.com"] = env.fixture("codex_usage.json") })
    svc.call("onIpc", "refresh")
    t.contains(env.texts(host.barTree), "77%")
  end)

  t.test("empty state when nothing is signed in", function()
    local host = env.host()
    env.start(host, "service.luau")
    env.start(host, "bar.luau")
    t.eq(env.ofType(host.barTree, "glyph")[1].props.name, "gauge")
  end)
end)

t.group("panel", function()
  t.test("a card per provider with every window", function()
    local host = running()
    local _, texts = openPanel(host)
    for _, text in { "Claude", "Team 5x", "Codex", "Plus", "Weekly · Fable", "38%" } do
      t.contains(texts, text)
    end
    t.ok(#env.ofType(host.panelTree, "progress") >= 5, "a meter per window")
  end)

  t.test("reset clock, projection and remaining mode", function()
    local host = running({ config = { display = "remaining" } })
    host.clock = 1791100799 - 2 * 86400 -- weekly: 5 of 7 days elapsed
    local _, texts = openPanel(host)
    t.contains(texts, "Resets in 2d · Sun 07:59")
    t.contains(texts, "≈ 34% left at reset") -- Claude weekly: 47% used, ~66% by reset
  end)

  t.test("error banner explains how to recover", function()
    local host = running({ codexResponse = { ok = true, status = 401, body = "" } })
    local _, texts = openPanel(host)
    t.contains(texts, "Sign-in rejected")
    t.contains(texts, "Run `codex login` and sign in with ChatGPT.")
  end)

  t.test("disconnected providers and the empty state", function()
    local host = env.host()
    env.start(host, "service.luau")
    local _, texts = openPanel(host)
    t.contains(texts, "No AI subscriptions found")
    t.contains(texts, "Codex · not connected")
  end)

  t.test("usage-page links open with xdg-open", function()
    local host = running()
    openPanel(host)
    local link = env.find(host.panelTree, function(n) return n.props.glyph == "external-link" end)[1]
    link.props.onClick()
    t.eq(table.concat(host.spawned[1], " "), "xdg-open https://claude.ai/settings/usage")
  end)

  t.test("opening fetches data older than 30 seconds, once", function()
    local host = running()
    local panel = openPanel(host)
    local before = #host.requests
    host.clock += 120
    panel.call("onClose")
    panel.call("onOpen", "")
    panel.call("onClose")
    panel.call("onOpen", "")
    t.eq(#host.requests, before + 2)
  end)
end)

return true
