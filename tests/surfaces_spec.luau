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

  t.test("tooltip lists window, value and reset", function()
    local host = running()
    env.start(host, "bar.luau")
    t.eq(#host.tooltip, 2)
    t.eq(host.tooltip[1].key, "Claude · Weekly")
    t.ok(host.tooltip[1].value:find("^47%% · Resets in ") ~= nil, host.tooltip[1].value)
  end)

  t.test("auto shows only the provider closest to its limit", function()
    local host = running({ claudeSession = 88, config = { provider = "auto" } })
    env.start(host, "bar.luau")
    local texts = env.texts(host.barTree)
    t.eq(#texts, 1)
    t.eq(texts[1], "88%")
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
    t.eq(host.tooltip, "Headroom: no Claude or Codex sign-in found")
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
    t.contains(texts, "On pace")
    t.contains(texts, "Resets in 2h 30m")
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
