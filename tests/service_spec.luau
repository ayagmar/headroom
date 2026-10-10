--!nonstrict
local t = require("./support/t")
local env = require("./support/env")

-- An account in the published report, by key ("claude" is Claude's default).
local function account(host, key)
  for _, view in host.stateValues.report.providers do
    for _, a in view.accounts do
      if a.key == key then
        return a
      end
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
    local claude = account(host, "claude")
    t.eq(claude.status, "ok")
    t.eq(#claude.snapshot.windows, 3)
    t.ok(host.stateValues.report.providers[1].hint:find("claude", 1, true) ~= nil, "sign-in hint published")
    t.eq(account(host, "codex").status, "absent")
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
    t.eq(account(host, "claude").busy, true)
  end)

  t.test("errors keep the last good snapshot, marked stale, with backoff", function()
    local host = signedInClaude()
    local svc = env.start(host, "service.luau")
    env.serve(host, { ["api.anthropic.com"] = { ok = true, status = 503, body = "" } })
    host.clock += 300
    svc.call("update")
    local claude = account(host, "claude")
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
    t.eq(account(host, "claude").status, "absent")
    env.claudeCreds(host)
    host.clock += 30
    svc.call("update")
    t.eq(account(host, "claude").status, "ok")
  end)

  t.test("serves the disk cache after a restart and refetches only when it is due", function()
    local host = signedInClaude()
    env.start(host, "service.luau")
    local restarted = signedInClaude()
    restarted.files["/data/cache.json"] = host.files["/data/cache.json"]
    restarted.clock = host.clock + 60
    local svc = env.start(restarted, "service.luau")
    local claude = account(restarted, "claude")
    t.eq(claude.status, "ok")
    t.eq(claude.stale, true)
    t.eq(#restarted.requests, 0, "data from a minute ago is not fetched again")
    restarted.clock += 240
    svc.call("update")
    t.eq(#restarted.requests, 1, "fetched once its interval is over")
  end)

  t.test("a manual refresh doesn't retry a throttled account before its wait is over", function()
    local host = signedInClaude()
    local svc = env.start(host, "service.luau")
    env.serve(host, { ["api.anthropic.com"] = { ok = true, status = 429, body = "" } })
    svc.call("onIpc", "refresh")
    t.eq(#host.requests, 2)
    host.clock += 60
    svc.call("onIpc", "refresh")
    t.eq(#host.requests, 2, "still throttled: not asked again")
    host.clock += 240
    svc.call("onIpc", "refresh")
    t.eq(#host.requests, 3, "the wait is over")
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
    t.eq(account(host, "codex"), nil)
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
    t.eq(account(host, "claude").status, "ok")
    t.eq(account(host, "codex").error.code, "parse")
  end)
end)

t.group("accounts", function()
  local WORK = "/home/test/.claude-work"
  local ADDED = "/data/accounts/claude/side"
  local ADDED_PERSONAL = "/data/accounts/claude/personal"

  -- Claude answers each account with its own session usage, picked by token.
  local function serveByToken(host, percents)
    host.httpHandler = function(req)
      local token = (env.headerOf(req, "Authorization") or ""):gsub("^Bearer ", "")
      local percent = percents[token]
      if percent == nil then
        return { ok = true, status = 401, body = "" }
      end
      return { ok = true, status = 200, body = env.claudeBody(host, percent) }
    end
  end

  local function sessionOf(view)
    for _, w in view.snapshot.windows do
      if w.id == "session" then
        return w.usedPercent
      end
    end
    return nil
  end

  local function claudeView(host)
    return host.stateValues.report.providers[1]
  end

  t.test("a folder beside the default with a sign-in is another account, fetched with its own", function()
    local host = env.host()
    env.claudeCreds(host)
    env.claudeCreds(host, { accessToken = "work-token" }, WORK)
    host.dirs["/home/test/.claude-modmgr-dev"] = true -- no sign-in: not an account
    serveByToken(host, { ["claude-token"] = 38, ["work-token"] = 88 })
    env.start(host, "service.luau")

    local accounts = claudeView(host).accounts
    t.eq(#accounts, 2)
    t.eq(accounts[1].kind, "default")
    t.eq(sessionOf(accounts[1]), 38)
    t.eq(accounts[2].kind, "found")
    t.eq(accounts[2].label, "work")
    t.eq(sessionOf(accounts[2]), 88)
    t.eq(accounts[2].launch, "CLAUDE_CONFIG_DIR='/home/test/.claude-work' claude")
  end)

  t.test("notifications name the account when there are several", function()
    local host = env.host()
    env.claudeCreds(host)
    env.claudeCreds(host, { accessToken = "work-token" }, WORK)
    serveByToken(host, { ["claude-token"] = 38, ["work-token"] = 50 })
    local svc = env.start(host, "service.luau")
    serveByToken(host, { ["claude-token"] = 38, ["work-token"] = 95 })
    svc.call("onIpc", "refresh")
    t.eq(#host.notifications, 1)
    t.eq(host.notifications[1].title, "Claude · work usage is running low")
  end)

  t.test("a copy of an account already shown is left out", function()
    local host = env.host()
    env.claudeCreds(host)
    env.claudeProfile(host, "me")
    env.claudeCreds(host, nil, WORK)
    env.claudeProfile(host, "me", WORK)
    env.claudeCreds(host, nil, "/home/test/.claude-other")
    env.claudeProfile(host, "someone-else", "/home/test/.claude-other")
    serveByToken(host, { ["claude-token"] = 38 })
    env.start(host, "service.luau")
    local accounts = claudeView(host).accounts
    t.eq(#accounts, 2)
    t.eq(accounts[2].label, "other")
    t.eq(accounts[1].email, "me@example.com")
  end)

  t.test("adding one makes its folder and opens the CLI's login there, then picks up the sign-in", function()
    local host = env.host()
    host.commands["claude"] = true
    env.claudeCreds(host)
    serveByToken(host, { ["claude-token"] = 38, ["side-token"] = 12 })
    local svc = env.start(host, "service.luau")
    t.eq(claudeView(host).canAdd, true)

    host.globals.noctalia.state.set("command", { action = "add", provider = "claude", label = "  Side  " })
    t.ok(host.dirs[ADDED], "folder made under the data dir")
    t.eq(#host.terminals, 1)
    local login = host.terminals[1]
    t.ok(login:find("'env' 'CLAUDE_CONFIG_DIR=/data/accounts/claude/side' 'claude' 'auth' 'login'", 1, true) ~= nil, login)
    local added = claudeView(host).accounts[2]
    t.eq(added.label, "Side")
    t.eq(added.status, "absent")
    t.eq(added.signingIn, true)

    env.claudeCreds(host, { accessToken = "side-token" }, ADDED) -- the CLI finished signing in
    host.clock += 5
    svc.call("update")
    added = claudeView(host).accounts[2]
    t.eq(added.status, "ok")
    t.eq(added.signingIn, false)
    t.eq(sessionOf(added), 12)
  end)

  t.test("added accounts survive a restart; removing one deletes its folder only", function()
    local host = env.host()
    host.commands["claude"] = true
    env.claudeCreds(host)
    serveByToken(host, { ["claude-token"] = 38 })
    env.start(host, "service.luau")
    host.globals.noctalia.state.set("command", { action = "add", provider = "claude", label = "Side" })

    local restarted = env.host()
    restarted.files["/data/accounts.json"] = host.files["/data/accounts.json"]
    env.claudeCreds(restarted)
    serveByToken(restarted, { ["claude-token"] = 38 })
    env.start(restarted, "service.luau")
    local key = claudeView(restarted).accounts[2].key
    t.eq(claudeView(restarted).accounts[2].label, "Side")

    restarted.globals.noctalia.state.set("command", { action = "remove", key = key })
    t.eq(table.concat(restarted.spawned[#restarted.spawned], " "), `rm -rf -- {ADDED}`)
    t.eq(#claudeView(restarted).accounts, 1)
    restarted.globals.noctalia.state.set("command", { action = "remove", key = "claude" })
    t.eq(#claudeView(restarted).accounts, 1, "the default account can't be removed")
  end)

  t.test("removing a found account hides it and leaves its folder alone", function()
    local host = env.host()
    env.claudeCreds(host)
    env.claudeCreds(host, { accessToken = "work-token" }, WORK)
    serveByToken(host, { ["claude-token"] = 38, ["work-token"] = 88 })
    env.start(host, "service.luau")
    local spawnedBefore = #host.spawned
    host.globals.noctalia.state.set("command", { action = "remove", key = claudeView(host).accounts[2].key })
    t.eq(#claudeView(host).accounts, 1)
    t.eq(#host.spawned, spawnedBefore, "nothing deleted")
    t.ok(host.files[`{WORK}/.credentials.json`] ~= nil)

    local restarted = env.host()
    restarted.files = host.files
    serveByToken(restarted, { ["claude-token"] = 38, ["work-token"] = 88 })
    env.start(restarted, "service.luau")
    t.eq(#claudeView(restarted).accounts, 1, "still hidden after a restart")
  end)

  t.test("an added account signed in to an account already shown is flagged, not fetched twice", function()
    local host = env.host()
    host.commands["claude"] = true
    env.claudeCreds(host)
    env.claudeProfile(host, "me")
    serveByToken(host, { ["claude-token"] = 38, ["side-token"] = 12 })
    local svc = env.start(host, "service.luau")
    host.globals.noctalia.state.set("command", { action = "add", provider = "claude", label = "Personal" })
    env.claudeCreds(host, { accessToken = "side-token" }, ADDED_PERSONAL)
    env.claudeProfile(host, "me", ADDED_PERSONAL) -- same account as the default
    host.clock += 5
    svc.call("update")
    local requests = #host.requests
    local personal = claudeView(host).accounts[2]
    t.eq(personal.duplicateOf, "Default")
    t.eq(personal.snapshot, nil)

    host.globals.noctalia.state.set("command", { action = "sign_in", key = personal.key })
    env.claudeProfile(host, "someone-else", ADDED_PERSONAL) -- signed in again, as another account
    host.clock += 5
    svc.call("update")
    host.clock += 5
    svc.call("update")
    personal = claudeView(host).accounts[2]
    t.eq(personal.duplicateOf, nil)
    t.eq(sessionOf(personal), 12)
    t.eq(#host.requests, requests + 1, "fetched once it is its own account")
  end)

  t.test("accounts can be renamed, and the name sticks; an empty name gives back the usual one", function()
    local host = env.host()
    env.claudeCreds(host)
    env.claudeCreds(host, { accessToken = "work-token" }, WORK)
    serveByToken(host, { ["claude-token"] = 38, ["work-token"] = 88 })
    env.start(host, "service.luau")
    local state = host.globals.noctalia.state
    state.set("command", { action = "rename", key = "claude", label = "  Personal " })
    state.set("command", { action = "rename", key = claudeView(host).accounts[2].key, label = "Job" })
    t.eq(claudeView(host).accounts[1].label, "Personal")
    t.eq(claudeView(host).accounts[2].label, "Job")

    local restarted = env.host()
    restarted.files = host.files
    serveByToken(restarted, { ["claude-token"] = 38, ["work-token"] = 88 })
    env.start(restarted, "service.luau")
    t.eq(claudeView(restarted).accounts[1].label, "Personal")
    restarted.globals.noctalia.state.set("command", { action = "rename", key = claudeView(restarted).accounts[2].key, label = "" })
    t.eq(claudeView(restarted).accounts[2].label, "work", "back to the folder's name")
  end)
end)

return true
