--!nonstrict
local t = require("./support/t")
local env = require("./support/env")

local function provider(host, id)
  for _, view in host.stateValues.report.providers do
    if view.id == id then
      return view
    end
  end
  return nil
end

local function signedInClaude(sessionPercent: number?)
  local host = env.host()
  env.claudeCreds(host)
  env.serve(host, { ["api.anthropic.com"] = env.claudeBody(host, sessionPercent) })
  return host
end

t.group("service", function()
  t.test("publishes a normalized report and never touches credentials", function()
    local host = signedInClaude()
    local creds = host.files[env.CLAUDE_CREDS]
    local svc = env.start(host, "service.luau")
    local claude = provider(host, "claude")
    t.eq(claude.status, "ok")
    t.eq(#claude.snapshot.windows, 3)
    t.ok(claude.hint:find("claude", 1, true) ~= nil, "sign-in hint published")
    t.eq(provider(host, "codex").status, "absent")
    t.eq(#host.requests, 1, "only signed-in providers are fetched")
    host.clock += 3600
    svc.call("update")
    t.eq(host.files[env.CLAUDE_CREDS], creds)
  end)

  t.test("refetches when due, on the configured interval", function()
    local host = signedInClaude()
    host.config.refresh_minutes = 2
    local svc = env.start(host, "service.luau")
    host.clock += 60
    svc.call("update")
    t.eq(#host.requests, 1)
    host.clock += 61
    svc.call("update")
    t.eq(#host.requests, 2)
  end)

  t.test("refresh via IPC; an in-flight request is not duplicated", function()
    local host = signedInClaude()
    local svc = env.start(host, "service.luau")
    svc.call("onIpc", "refresh")
    t.eq(#host.requests, 2)
    host.httpHandler = nil -- never answers
    svc.call("onIpc", "refresh")
    svc.call("onIpc", "refresh")
    t.eq(#host.requests, 3)
    t.eq(provider(host, "claude").busy, true)
  end)

  t.test("errors keep the last good snapshot, marked stale, with backoff", function()
    local host = signedInClaude()
    local svc = env.start(host, "service.luau")
    env.serve(host, { ["api.anthropic.com"] = { ok = true, status = 503, body = "" } })
    host.clock += 300
    svc.call("update")
    local claude = provider(host, "claude")
    t.eq(claude.status, "error")
    t.eq(claude.stale, true)
    t.eq(#claude.snapshot.windows, 3)
    host.clock += 31 -- 30s backoff after the first failure, not the full interval
    svc.call("update")
    t.eq(#host.requests, 3)
  end)

  t.test("opening the panel refreshes old data but respects backoff", function()
    local host = signedInClaude()
    local svc = env.start(host, "service.luau")
    local state = host.globals.noctalia.state
    state.set("command", { action = "refresh", maxAge = 30 })
    t.eq(#host.requests, 1, "fresh data: nothing to do")
    host.clock += 120
    state.set("command", { action = "refresh", maxAge = 30 })
    t.eq(#host.requests, 2, "old data: refetched")

    env.serve(host, { ["api.anthropic.com"] = { ok = true, status = 429, body = "" } })
    svc.call("onIpc", "refresh")
    t.eq(#host.requests, 3)
    host.clock += 120
    state.set("command", { action = "refresh", maxAge = 30 })
    t.eq(#host.requests, 3, "throttled provider keeps its backoff")
  end)

  t.test("notices a sign-in that happens while running", function()
    local host = env.host()
    env.serve(host, { ["api.anthropic.com"] = env.fixture("claude_usage.json") })
    local svc = env.start(host, "service.luau")
    t.eq(provider(host, "claude").status, "absent")
    env.claudeCreds(host)
    host.clock += 30
    svc.call("update")
    t.eq(provider(host, "claude").status, "ok")
  end)

  t.test("serves the disk cache immediately after a restart", function()
    local host = signedInClaude()
    env.start(host, "service.luau")
    local restarted = env.host()
    env.claudeCreds(restarted)
    restarted.files["/data/cache.json"] = host.files["/data/cache.json"]
    restarted.httpHandler = nil -- network has not answered yet
    env.start(restarted, "service.luau")
    local claude = provider(restarted, "claude")
    t.eq(claude.status, "ok")
    t.eq(claude.stale, true)
    t.eq(claude.busy, true)
  end)

  t.test("notifies once when crossing the critical threshold", function()
    local host = signedInClaude()
    local svc = env.start(host, "service.luau")
    env.serve(host, { ["api.anthropic.com"] = env.claudeBody(host, 93) })
    host.clock += 300
    svc.call("update")
    host.clock += 300
    svc.call("update")
    t.eq(#host.notifications, 1)
    t.eq(host.notifications[1].title, "Claude usage is running low")
  end)

  t.test("providers set to off are neither fetched nor shown", function()
    local host = signedInClaude()
    env.codexAuth(host)
    host.config.provider_codex = "off"
    env.start(host, "service.luau")
    t.eq(provider(host, "codex"), nil)
    t.eq(#host.requests, 1)
  end)

  t.test("a crashing adapter is contained", function()
    local host = signedInClaude()
    env.codexAuth(host)
    env.serve(host, {
      ["api.anthropic.com"] = env.fixture("claude_usage.json"),
      ["chatgpt.com"] = '{"rate_limit":{"primary_window":"boom"}}',
    })
    env.start(host, "service.luau")
    t.eq(provider(host, "claude").status, "ok")
    t.eq(provider(host, "codex").error.code, "parse")
  end)
end)

return true
