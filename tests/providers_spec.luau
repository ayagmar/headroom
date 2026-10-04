--!nonstrict
local t = require("./support/t")
local env = require("./support/env")

-- The same Context the service builds, over a fake host.
local function context(host, mods)
  return mods.require("lib/context.luau").new(host.globals.noctalia, "headroom-noctalia/test")
end

local time -- set below from the module runtime

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

time = env.modules(env.host()).require("lib/time.luau")

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

t.group("antigravity", function()
  local KEYRING = "secret-tool lookup service gemini username antigravity"

  local function session(expiry: string)
    return `\{"token":\{"access_token":"ya29.test","token_type":"Bearer","refresh_token":"r","expiry":"{expiry}"},"auth_method":"oauth"}`
  end

  -- A host with agy installed, secret-tool answering with `keyring`, and the
  -- quota endpoint answering with `quota` (body string or response table).
  local function setup(opts)
    local h = env.host()
    local m = env.modules(h)
    local p = m.require("providers/antigravity/init.luau")
    p.resetRenewCooldown()
    h.commands["secret-tool"] = opts.secretTool ~= false
    h.commands["agy"] = opts.agy ~= false
    local keyring = opts.keyring
    h.runHandler = function(argv)
      local line = table.concat(argv, " ")
      if line == KEYRING then
        return if keyring then { exitCode = 0, stdout = keyring .. "\n" } else { exitCode = 1, stdout = "" }
      elseif line == "env AGY_CLI_DISABLE_AUTO_UPDATE=true agy models" then
        if opts.onRenew then
          keyring = opts.onRenew()
        end
        return { exitCode = 0, stdout = "" }
      end
      return nil
    end
    env.serve(h, { ["cloudcode-pa.googleapis.com"] = opts.quota or env.fixture("antigravity_quota.json") })
    return h, p, context(h, m)
  end

  local FRESH = "2026-09-21T15:00:00Z" -- host clock is 2026-09-21T14:13:20Z
  local STALE = "2026-09-21T14:00:00Z"

  t.test("parses the live response: remaining inverted to used", function()
    local h = env.host()
    local m = env.modules(h)
    local p = m.require("providers/antigravity/init.luau")
    local snap = p.parse(h.globals.noctalia.json.decode(env.fixture("antigravity_quota.json")), context(h, m))
    t.eq(#snap.windows, 4)
    local w = byId(snap.windows)
    t.eq(w["gemini-weekly"].label, "Gemini · Weekly")
    t.near(w["gemini-weekly"].usedPercent, 0.0346, 1e-6)
    t.eq(w["gemini-weekly"].kind, "weekly")
    t.eq(w["gemini-weekly"].periodSeconds, 7 * 86400)
    t.eq(w["gemini-5h"].label, "Gemini · Session")
    t.eq(w["3p-5h"].label, "Claude & GPT · Session")
    t.eq(w["3p-weekly"].resetsAt, time.parseIso8601("2026-10-11T01:11:18Z"))
    env.noMissingKeys(t, h)
  end)

  t.test("a bucket without a valid fraction is skipped, never shown as 0%", function()
    local h = env.host()
    local m = env.modules(h)
    local p = m.require("providers/antigravity/init.luau")
    local snap = p.parse({ groups = { { displayName = "Gemini Models", buckets = {
      { bucketId = "gemini-5h", window = "5h", resetTime = FRESH },
      { bucketId = "gemini-weekly", window = "weekly", remainingFraction = 1.7 },
      { bucketId = "gemini-weekly", window = "weekly", remainingFraction = 0.25 },
    } } } }, context(h, m))
    t.eq(#snap.windows, 1)
    t.eq(snap.windows[1].usedPercent, 75)
  end)

  t.test("fresh keyring session -> POST with the antigravity user agent", function()
    local h, p, c = setup({ keyring = session(FRESH) })
    local snap, err = fetch(p, c)
    t.eq(err, nil)
    t.eq(#snap.windows, 4)
    local req = h.requests[1]
    t.eq(req.method, "POST")
    t.eq(req.body, "{}")
    t.eq(env.headerOf(req, "Authorization"), "Bearer ya29.test")
    t.eq(env.headerOf(req, "User-Agent"), "antigravity")
    t.eq(env.headerOf(req, "Content-Type"), "application/json")
    t.eq(table.concat(h.spawned[1], " "), KEYRING)
  end)

  t.test("go-keyring base64 wrapping and the CLI token file are understood", function()
    local h, p, c = setup({ keyring = "go-keyring-base64:" .. "eyJhY2Nlc3NUb2tlbiI6InlhMjkudGVzdCIsImV4cGlyZXNBdCI6MTc5MDAwMzYwMDAwMH0=" })
    local _, err = fetch(p, c)
    t.eq(err, nil, "base64-wrapped camelCase session with epoch-ms expiry")

    local h2, p2, c2 = setup({ secretTool = false })
    h2.files["/home/test/.gemini/antigravity-cli/antigravity-oauth-token"] = session(FRESH)
    local _, err2 = fetch(p2, c2)
    t.eq(err2, nil, "file fallback without secret-tool")
    t.eq(#h2.spawned, 0)
    t.ok(h ~= nil)
  end)

  t.test("expired session -> agy renews its own session, then we read it again", function()
    local h, p, c = setup({ keyring = session(STALE), onRenew = function() return session(FRESH) end })
    local snap, err = fetch(p, c)
    t.eq(err, nil)
    t.eq(#snap.windows, 4)
    local commands = {}
    for _, argv in h.spawned do
      table.insert(commands, table.concat(argv, " "))
    end
    t.eq(commands[2], "env AGY_CLI_DISABLE_AUTO_UPDATE=true agy models")
    t.eq(commands[3], KEYRING, "re-read after renewal")
  end)

  t.test("renewal is rate-limited when it does not help", function()
    local h, p, c = setup({ keyring = session(STALE), onRenew = function() return session(STALE) end })
    local _, err = fetch(p, c)
    t.eq(err.code, "expired")
    local spawnedBefore = #h.spawned
    local _, again = fetch(p, c)
    t.eq(again.code, "expired")
    t.eq(#h.spawned, spawnedBefore + 1, "only the keyring read, no second agy run")
    t.eq(#h.requests, 0)
  end)

  t.test("without agy an expired session is reported, not renewed", function()
    local h, p, c = setup({ keyring = session(STALE), agy = false })
    local _, err = fetch(p, c)
    t.eq(err.code, "expired")
    t.eq(#h.spawned, 1)
  end)

  t.test("a failed keyring lookup rests the keyring instead of prompting again", function()
    local h, p, c = setup({})
    fetch(p, c)
    fetch(p, c)
    local lookups = 0
    for _, argv in h.spawned do
      if table.concat(argv, " ") == KEYRING then
        lookups += 1
      end
    end
    t.eq(lookups, 1)
  end)

  t.test("no saved session -> not_configured", function()
    local _, p, c = setup({})
    local _, err = fetch(p, c)
    t.eq(err.code, "not_configured")
  end)

  t.test("SUBSCRIPTION_REQUIRED is a plan problem, not a sign-in problem", function()
    local _, p, c = setup({
      keyring = session(FRESH),
      quota = { ok = true, status = 403, body = '{"error":{"details":[{"reason":"SUBSCRIPTION_REQUIRED"}]}}' },
    })
    local _, err = fetch(p, c)
    t.eq(err.code, "no_plan")
  end)

  t.test("falls back to the daily endpoint on a server error", function()
    local h, p, c = setup({ keyring = session(FRESH) })
    h.httpHandler = function(req)
      if req.url:find("daily-cloudcode", 1, true) then
        return { ok = true, status = 200, body = env.fixture("antigravity_quota.json") }
      end
      return { ok = true, status = 503, body = "" }
    end
    local snap, err = fetch(p, c)
    t.eq(err, nil)
    t.eq(#snap.windows, 4)
    t.eq(#h.requests, 2)
  end)
end)

return true
