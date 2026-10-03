--!nonstrict
local t = require("./support/t")
local env = require("./support/env")

local function report(host)
  return host.stateValues.report
end

local function provider(host, id)
  for _, view in report(host).providers do
    if view.id == id then
      return view
    end
  end
  return nil
end

local function signedInClaude()
  local host = env.host()
  env.claudeCreds(host)
  env.serve(host, { ["api.anthropic.com"] = env.fixture("claude_usage.json") })
  return host
end

t.group("service", function()
  t.test("publishes a normalized report on start", function()
    local host = signedInClaude()
    env.start(host, "service.luau")
    local claude = provider(host, "claude")
    t.eq(claude.status, "ok")
    t.eq(claude.configured, true)
    t.eq(#claude.snapshot.windows, 3)
    t.eq(claude.brand.accent, "#D97757")
    local codex = provider(host, "codex")
    t.eq(codex.status, "absent")
    t.eq(#host.requests, 1, "only configured providers are fetched")
    t.eq(report(host).refreshing, false)
  end)

  t.test("never writes credential files", function()
    local host = signedInClaude()
    local before = host.files[env.CLAUDE_CREDS]
    local svc = env.start(host, "service.luau")
    host.clock += 3600
    svc.call("update")
    t.eq(host.files[env.CLAUDE_CREDS], before)
  end)

  t.test("refetches only when due", function()
    local host = signedInClaude()
    local svc = env.start(host, "service.luau")
    host.clock += 60
    svc.call("update")
    t.eq(#host.requests, 1)
    host.clock += 5 * 60
    svc.call("update")
    t.eq(#host.requests, 2)
  end)

  t.test("refresh interval comes from settings", function()
    local host = signedInClaude()
    host.config.refresh_minutes = 1
    local svc = env.start(host, "service.luau")
    host.clock += 61
    svc.call("update")
    t.eq(#host.requests, 2)
  end)

  t.test("refresh via IPC and via shared-state command", function()
    local host = signedInClaude()
    local svc = env.start(host, "service.luau")
    svc.call("onIpc", "refresh")
    t.eq(#host.requests, 2)
    host.globals.noctalia.state.set("command", { action = "refresh", at = 1 })
    t.eq(#host.requests, 3)
  end)

  t.test("an in-flight request is not duplicated", function()
    local host = env.host()
    env.claudeCreds(host)
    host.httpHandler = nil -- never answers
    local svc = env.start(host, "service.luau")
    svc.call("onIpc", "refresh")
    t.eq(#host.requests, 1)
    t.eq(report(host).refreshing, true)
    t.eq(provider(host, "claude").status, "loading")
  end)

  t.test("errors keep the last good snapshot, marked stale, with backoff", function()
    local host = signedInClaude()
    local svc = env.start(host, "service.luau")
    env.serve(host, { ["api.anthropic.com"] = { ok = true, status = 503, body = "" } })
    host.clock += 300
    svc.call("update")
    local claude = provider(host, "claude")
    t.eq(claude.status, "error")
    t.eq(claude.error.code, "server")
    t.eq(claude.stale, true)
    t.eq(#claude.snapshot.windows, 3)
    -- Backoff: 30s after the first failure, not the full interval.
    host.clock += 31
    svc.call("update")
    t.eq(#host.requests, 3)
  end)

  t.test("sign-in problems carry the provider's hint", function()
    local host = env.host()
    env.claudeCreds(host, { expiresAt = 1 })
    env.start(host, "service.luau")
    local claude = provider(host, "claude")
    t.eq(claude.error.code, "expired")
    t.ok(claude.error.hint:find("claude", 1, true) ~= nil, "hint mentions the CLI")
  end)

  t.test("picks up a sign-in that happens while running", function()
    local host = env.host()
    env.serve(host, { ["api.anthropic.com"] = env.fixture("claude_usage.json") })
    local svc = env.start(host, "service.luau")
    t.eq(provider(host, "claude").status, "absent")
    env.claudeCreds(host)
    host.clock += 5
    svc.call("update")
    t.eq(provider(host, "claude").status, "ok")
  end)

  t.test("serves the disk cache immediately after a restart", function()
    local host = signedInClaude()
    env.start(host, "service.luau")
    t.ok(host.files["/data/cache.json"] ~= nil, "cache written")

    local restarted = env.host()
    env.claudeCreds(restarted)
    restarted.files["/data/cache.json"] = host.files["/data/cache.json"]
    restarted.httpHandler = nil -- network has not answered yet
    env.start(restarted, "service.luau")
    local claude = provider(restarted, "claude")
    t.eq(claude.status, "ok")
    t.eq(claude.stale, true)
    t.eq(#claude.snapshot.windows, 3)
    t.eq(claude.busy, true)
  end)

  t.test("notifies once when crossing the critical threshold", function()
    local host = signedInClaude()
    local json = host.globals.noctalia.json
    local svc = env.start(host, "service.luau")
    t.eq(#host.notifications, 0)

    local hot = json.decode(env.fixture("claude_usage.json"))
    hot.limits[1].percent = 93
    env.serve(host, { ["api.anthropic.com"] = json.encode(hot) })
    host.clock += 300
    svc.call("update")
    t.eq(#host.notifications, 1)
    t.eq(host.notifications[1].title, "Claude usage is running low")
    t.ok(host.notifications[1].body:find("Session is at 93%", 1, true) ~= nil, host.notifications[1].body)

    host.clock += 300
    svc.call("update")
    t.eq(#host.notifications, 1, "no repeat within the same window")
    env.noMissingKeys(t, host)
  end)

  t.test("notifications can be turned off", function()
    local host = env.host()
    host.config.notify = false
    env.claudeCreds(host)
    local json = host.globals.noctalia.json
    local hot = json.decode(env.fixture("claude_usage.json"))
    hot.limits[1].percent = 99
    env.serve(host, { ["api.anthropic.com"] = json.encode(hot) })
    env.start(host, "service.luau")
    t.eq(#host.notifications, 0)
  end)

  t.test("a crashing adapter is contained", function()
    local host = signedInClaude()
    env.codexAuth(host)
    -- Codex gets a body that is valid JSON but the wrong type everywhere.
    host.httpHandler = function(req)
      if req.url:find("chatgpt.com", 1, true) then
        return { ok = true, status = 200, body = '{"rate_limit":{"primary_window":"boom"}}' }
      end
      return { ok = true, status = 200, body = env.fixture("claude_usage.json") }
    end
    env.start(host, "service.luau")
    t.eq(provider(host, "claude").status, "ok")
    t.eq(provider(host, "codex").status, "error")
    t.eq(provider(host, "codex").error.code, "parse")
  end)
end)

return true
