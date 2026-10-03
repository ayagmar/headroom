--!nonstrict
local t = require("./support/t")
local env = require("./support/env")

-- Builds the same Context the service builds, over a fake host.
local function context(host, mods)
  local http = mods.require("lib/http.luau")
  local n = host.globals.noctalia
  return {
    now = function() return host.clock end,
    env = n.getenv,
    expandPath = n.expandPath,
    fileExists = n.fileExists,
    readJson = function(path)
      local text = n.readFile(path)
      if text == nil then return nil, "missing" end
      return n.json.decode(text)
    end,
    decodeJson = n.json.decode,
    getJson = http.client(n.http, n.json.decode),
    tr = n.tr,
    userAgent = "headroom-noctalia/test",
  }
end

local function fetch(provider, ctx)
  local snapshot, err
  provider.fetch(ctx, function(s, e)
    snapshot, err = s, e
  end)
  return snapshot, err
end

local function byId(windows)
  local out = {}
  for _, w in windows do
    out[w.id] = w
  end
  return out
end

t.group("registry", function()
  t.test("every provider satisfies the contract and has a logo and hint", function()
    local host = env.host()
    local mods = env.modules(host)
    local registry = mods.require("providers/registry.luau")
    local seen = {}
    t.ok(#registry >= 2, "at least two providers")
    for _, p in registry do
      t.ok(not seen[p.id], `duplicate id {p.id}`)
      seen[p.id] = true
      t.ok(p.brand.logo:match("^providers/" .. p.id .. "/.+%.svg$") ~= nil, `{p.id} logo lives in its provider folder`)
      t.ok(env.sources[p.brand.logo] ~= nil, `{p.id} logo file exists`)
      p.signInHint(context(host, mods))
    end
    env.noMissingKeys(t, host)
  end)
end)

t.group("claude", function()
  local host = env.host()
  local mods = env.modules(host)
  local claude = mods.require("providers/claude/init.luau")
  local ctx = context(host, mods)
  local json = host.globals.noctalia.json

  t.test("parses the live response shape", function()
    local data = json.decode(env.fixture("claude_usage.json"))
    local snap = claude.parse(data, { subscriptionType = "team", rateLimitTier = "default_claude_max_5x" }, ctx)
    t.eq(snap.plan, "Team 5x")
    t.eq(#snap.windows, 3)
    local w = byId(snap.windows)
    t.eq(w.session.usedPercent, 38)
    t.eq(w.session.kind, "session")
    t.eq(w.session.label, "Session")
    t.eq(w.session.resetsAt, 1791058799)
    t.eq(w.session.periodSeconds, 5 * 3600)
    t.eq(w.weekly.usedPercent, 47)
    t.eq(w.weekly.kind, "weekly")
    t.eq(w["weekly_scoped:Fable"].label, "Weekly · Fable")
    t.eq(w["weekly_scoped:Fable"].kind, "model")
    t.eq(#snap.notes, 0, "extra usage disabled -> no note")
    env.noMissingKeys(t, host)
  end)

  t.test("falls back to the legacy per-window fields", function()
    local snap = claude.parse({
      five_hour = { utilization = 12.5, resets_at = "2024-02-29T12:00:00Z" },
      seven_day_opus = { utilization = 70 },
    }, { subscriptionType = "max", rateLimitTier = "default_claude_max_20x" }, ctx)
    t.eq(snap.plan, "Max 20x")
    local w = byId(snap.windows)
    t.eq(w.session.usedPercent, 12.5)
    t.eq(w.session.resetsAt, 1709208000)
    t.eq(w["weekly:Opus"].label, "Weekly · Opus")
  end)

  t.test("reports extra usage spend", function()
    local data = json.decode(env.fixture("claude_usage.json"))
    data.extra_usage.is_enabled = true
    data.spend.used = { amount_minor = 1230, exponent = 2, currency = "USD" }
    data.spend.limit = { amount_minor = 5000, exponent = 2, currency = "USD" }
    local snap = claude.parse(data, {}, ctx)
    t.eq(snap.notes[1].label, "Extra usage")
    t.eq(snap.notes[1].value, "$12.30 of $50.00")
  end)

  t.test("an empty response is a parse error", function()
    local snap, err = claude.parse({}, {}, ctx)
    t.eq(snap, nil)
    t.eq(err.code, "parse")
  end)

  t.test("missing credentials -> not_configured, no request", function()
    local h = env.host()
    local m = env.modules(h)
    local p = m.require("providers/claude/init.luau")
    local c = context(h, m)
    t.eq(p.isConfigured(c), false)
    local _, err = fetch(p, c)
    t.eq(err.code, "not_configured")
    t.eq(#h.requests, 0)
  end)

  t.test("expired token -> expired, no request", function()
    local h = env.host()
    local m = env.modules(h)
    local p = m.require("providers/claude/init.luau")
    env.claudeCreds(h, { expiresAt = (h.clock - 1) * 1000 })
    local _, err = fetch(p, context(h, m))
    t.eq(err.code, "expired")
    t.eq(#h.requests, 0)
  end)

  t.test("valid token -> authenticated GET with the beta header", function()
    local h = env.host()
    local m = env.modules(h)
    local p = m.require("providers/claude/init.luau")
    env.claudeCreds(h)
    env.serve(h, { ["api.anthropic.com"] = env.fixture("claude_usage.json") })
    local snap, err = fetch(p, context(h, m))
    t.eq(err, nil)
    t.eq(#snap.windows, 3)
    local req = h.requests[1]
    t.eq(req.url, "https://api.anthropic.com/api/oauth/usage")
    t.eq(env.headerOf(req, "Authorization"), "Bearer claude-token")
    t.eq(env.headerOf(req, "anthropic-beta"), "oauth-2025-04-20")
    t.eq(env.headerOf(req, "User-Agent"), "headroom-noctalia/test")
  end)

  t.test("honors CLAUDE_CONFIG_DIR", function()
    local h = env.host()
    local m = env.modules(h)
    local p = m.require("providers/claude/init.luau")
    h.env.CLAUDE_CONFIG_DIR = "/work/claude"
    h.files["/work/claude/.credentials.json"] = "{}"
    t.eq(p.isConfigured(context(h, m)), true)
  end)

  t.test("401 -> auth", function()
    local h = env.host()
    local m = env.modules(h)
    local p = m.require("providers/claude/init.luau")
    env.claudeCreds(h)
    env.serve(h, { ["api.anthropic.com"] = { ok = true, status = 401, body = "" } })
    local _, err = fetch(p, context(h, m))
    t.eq(err.code, "auth")
  end)
end)

t.group("codex", function()
  local host = env.host()
  local mods = env.modules(host)
  local codex = mods.require("providers/codex/init.luau")
  local ctx = context(host, mods)
  local json = host.globals.noctalia.json

  t.test("parses the live response shape", function()
    local snap = codex.parse(json.decode(env.fixture("codex_usage.json")), nil, ctx)
    t.eq(snap.plan, "Plus")
    t.eq(#snap.windows, 2)
    local w = byId(snap.windows)
    t.eq(w.primary_window.kind, "session")
    t.eq(w.primary_window.label, "Session")
    t.eq(w.primary_window.usedPercent, 51)
    t.eq(w.primary_window.periodSeconds, 18000)
    t.eq(w.primary_window.resetsAt, 1791056429)
    t.eq(w.secondary_window.kind, "weekly")
    t.eq(w.secondary_window.usedPercent, 8)
    t.eq(#snap.notes, 0, "no credits -> no note")
    env.noMissingKeys(t, host)
  end)

  t.test("labels code review and feature limits; credits note", function()
    local data = json.decode(env.fixture("codex_usage.json"))
    data.code_review_rate_limit = { primary_window = { used_percent = 5, limit_window_seconds = 604800, reset_after_seconds = 60 } }
    data.additional_rate_limits = { { limit_name = "GPT-6 Astra", rate_limit = { primary_window = { used_percent = 33, limit_window_seconds = 18000 } } } }
    data.credits = { has_credits = true, balance = "120" }
    local snap = codex.parse(data, nil, ctx)
    local w = byId(snap.windows)
    t.eq(w["code_review:primary_window"].label, "Code review · 7d")
    t.eq(w["code_review:primary_window"].resetsAt, host.clock + 60)
    t.eq(w["extra:GPT-6 Astra:primary_window"].label, "GPT-6 Astra · 5h")
    t.eq(snap.notes[1].value, "120")
  end)

  t.test("API-key-only setup -> not_configured", function()
    local h = env.host()
    local m = env.modules(h)
    local p = m.require("providers/codex/init.luau")
    h.files[env.CODEX_AUTH] = '{"auth_mode":"apikey","OPENAI_API_KEY":"sk-x","tokens":null}'
    local _, err = fetch(p, context(h, m))
    t.eq(err.code, "not_configured")
  end)

  t.test("expired access token -> expired, no request", function()
    local h = env.host()
    local m = env.modules(h)
    local p = m.require("providers/codex/init.luau")
    env.codexAuth(h, { access_token = env.JWT_EXPIRED, account_id = "a" })
    local _, err = fetch(p, context(h, m))
    t.eq(err.code, "expired")
    t.eq(#h.requests, 0)
  end)

  t.test("sends the account header; plan falls back to the id token", function()
    local h = env.host()
    local m = env.modules(h)
    local p = m.require("providers/codex/init.luau")
    env.codexAuth(h)
    local body = json.decode(env.fixture("codex_usage.json"))
    body.plan_type = nil
    env.serve(h, { ["chatgpt.com"] = json.encode(body) })
    local snap, err = fetch(p, context(h, m))
    t.eq(err, nil)
    t.eq(snap.plan, "Pro")
    t.eq(env.headerOf(h.requests[1], "ChatGPT-Account-Id"), "acct-1")
    t.eq(env.headerOf(h.requests[1], "Authorization"), `Bearer {env.JWT_VALID}`)
  end)
end)

return true
