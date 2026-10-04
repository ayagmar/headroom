--!nonstrict
local t = require("./support/t")
local env = require("./support/env")

local host = env.host()
local mods = env.modules(host)
local time = mods.require("lib/time.luau")
local pace = mods.require("lib/pace.luau")
local model = mods.require("lib/model.luau")
local scheduler = mods.require("lib/scheduler.luau")
local jwt = mods.require("lib/jwt.luau")
local http = mods.require("lib/http.luau")
local json = host.globals.noctalia.json

t.group("time", function()
  t.test("parses ISO-8601 with fractions and offsets", function()
    t.eq(time.parseIso8601("1970-01-01T00:00:00Z"), 0)
    t.eq(time.parseIso8601("2026-10-03T20:19:59.911287+00:00"), 1791058799)
    t.eq(time.parseIso8601("2000-03-01T00:00:00+02:00"), 951861600)
    t.eq(time.parseIso8601("1999-12-31T23:59:59-05:30"), 946704599)
    t.eq(time.parseIso8601("2024-02-29T12:00:00Z"), 1709208000)
  end)

  t.test("rejects non-timestamps", function()
    t.eq(time.parseIso8601("tomorrow"), nil)
    t.eq(time.parseIso8601("2026-10-03"), nil)
    t.eq(time.parseIso8601(nil), nil)
    t.eq(time.parseIso8601("2026-10-03T20:19:59+0x:00"), nil)
  end)

  t.test("toUnix accepts numbers, numeric strings and ISO", function()
    t.eq(time.toUnix(1791056429), 1791056429)
    t.eq(time.toUnix("1791056429"), 1791056429)
    t.eq(time.toUnix("2024-02-29T12:00:00Z"), 1709208000)
  end)

  t.test("formats compact durations", function()
    t.eq(time.duration(30), "<1m")
    t.eq(time.duration(300), "5m")
    t.eq(time.duration(3600), "1h")
    t.eq(time.duration(3720), "1h 2m")
    t.eq(time.duration(2 * 86400 + 4 * 3600 + 59), "2d 4h")
    t.eq(time.duration(6 * 86400), "6d")
    t.eq(time.duration(-5), "<1m")
  end)

  t.test("formats relative ages", function()
    t.eq(time.ago(10), "just now")
    t.eq(time.ago(125), "2m ago")
    t.eq(time.ago(7200), "2h ago")
  end)
end)

t.group("pace", function()
  local H5 = 5 * 3600
  local now = 1_000_000
  local function window(used, remaining)
    return model.window({ id = "s", usedPercent = used, periodSeconds = H5, resetsAt = now + remaining })
  end

  t.test("projects exhaustion and the lockout it costs", function()
    local p = pace.compute(window(80, H5 / 2), now)
    t.eq(p.status, "runs_out")
    t.near(p.elapsedFraction, 0.5, 1e-9)
    -- 80% in 9000s -> the last 20% takes 2250s, leaving 6750s locked out.
    t.near(p.runsOutIn, 2250, 1e-6)
    t.near(p.lockoutSeconds, 6750, 1e-6)
    t.eq(p.severity, "warn")
  end)

  t.test("running out just before the reset is not a warning", function()
    local p = pace.compute(window(52, H5 / 2), now)
    t.eq(p.status, "runs_out")
    t.eq(p.severity, "ok")
  end)

  t.test("projects usage at reset when it will last", function()
    local p = pace.compute(window(20, H5 / 2), now)
    t.eq(p.status, "projected")
    t.near(p.projectedPercent, 40, 1e-9)
    t.eq(p.severity, "ok")
  end)

  t.test("no verdict early in a window", function()
    t.eq(pace.compute(window(30, H5 - 300), now).status, "early")
  end)

  t.test("exhausted at the limit", function()
    local p = pace.compute(window(100, 600), now)
    t.eq(p.status, "exhausted")
    t.eq(p.severity, "critical")
  end)

  t.test("nil without period or reset", function()
    t.eq(pace.compute(model.window({ id = "x", usedPercent = 10 }), now), nil)
  end)
end)

t.group("model", function()
  t.test("clamps percentages and flags the limit", function()
    t.eq(model.window({ id = "a", usedPercent = 140 }).usedPercent, 100)
    t.eq(model.window({ id = "a", usedPercent = -3 }).usedPercent, 0)
    t.eq(model.window({ id = "a", usedPercent = "42" }).usedPercent, 42)
    t.eq(model.window({ id = "a", usedPercent = 100 }).limitReached, true)
  end)

  t.test("tightest prefers higher usage, then later reset", function()
    local a = model.window({ id = "a", usedPercent = 40, resetsAt = 10 })
    local b = model.window({ id = "b", usedPercent = 40, resetsAt = 20 })
    local c = model.window({ id = "c", usedPercent = 10 })
    t.eq(model.tightest({ a, b, c }).id, "b")
    t.eq(model.tightest({}), nil)
  end)

  t.test("pick honors a kind preference with fallback", function()
    local s = model.window({ id = "s", kind = "session", usedPercent = 10 })
    local w = model.window({ id = "w", kind = "weekly", usedPercent = 60 })
    t.eq(model.pick({ s, w }, "session").id, "s")
    t.eq(model.pick({ s, w }, "tightest").id, "w")
    t.eq(model.pick({ s }, "weekly").id, "s")
  end)

  t.test("severity thresholds", function()
    t.eq(model.severity(69, 70, 90), "ok")
    t.eq(model.severity(70, 70, 90), "warn")
    t.eq(model.severity(90, 70, 90), "critical")
  end)
end)

t.group("scheduler", function()
  t.test("backoff per error class", function()
    t.eq(scheduler.retryDelay("network", 1, 300), 30)
    t.eq(scheduler.retryDelay("network", 3, 300), 120)
    t.eq(scheduler.retryDelay("server", 10, 300), 300)
    t.eq(scheduler.retryDelay("rate_limited", 1, 300), 300)
    t.eq(scheduler.retryDelay("rate_limited", 3, 300), 1200)
    t.eq(scheduler.retryDelay("rate_limited", 9, 300), 3600)
    t.eq(scheduler.retryDelay("expired", 5, 300), 60)
    t.eq(scheduler.retryDelay("auth", 1, 300), 300)
  end)

  t.test("drops replies from superseded requests", function()
    local e = scheduler.new()
    local first = scheduler.start(e, 0)
    local second = scheduler.start(e, 100) -- e.g. after a timeout
    t.eq(scheduler.finish(e, first, 101, 300, nil), false)
    t.eq(scheduler.finish(e, second, 102, 300, nil), true)
    t.eq(e.nextAt, 402)
  end)

  t.test("a lost request stops blocking after the timeout", function()
    local e = scheduler.new()
    scheduler.start(e, 0)
    t.eq(scheduler.isDue(e, 10), false)
    t.eq(scheduler.isDue(e, scheduler.TIMEOUT_SECONDS), true)
  end)

  t.test("failures accumulate and reset on success", function()
    local e = scheduler.new()
    scheduler.finish(e, scheduler.start(e, 0), 0, 300, model.err("network"))
    scheduler.finish(e, scheduler.start(e, 30), 30, 300, model.err("network"))
    t.eq(e.failures, 2)
    t.eq(e.nextAt, 90)
    scheduler.finish(e, scheduler.start(e, 90), 90, 300, nil)
    t.eq(e.failures, 0)
  end)
end)

t.group("jwt", function()
  t.test("decodes base64url with and without padding", function()
    t.eq(jwt.base64Decode("aGVsbG8"), "hello")
    t.eq(jwt.base64Decode("aGVsbG8="), "hello")
    t.eq(jwt.base64Decode("-_8"), "\251\255")
    t.eq(jwt.base64Decode("a!b"), nil)
  end)

  t.test("reads claims, rejects junk", function()
    t.eq(jwt.claims(env.JWT_VALID, json.decode).exp, 1790003600)
    t.eq(jwt.claims("not-a-jwt", json.decode), nil)
    t.eq(jwt.claims(nil, json.decode), nil)
  end)
end)

t.group("http", function()
  local function code(response)
    local _, err = http.interpret(response, json.decode)
    return err and err.code
  end

  t.test("maps transport and status failures", function()
    t.eq(code({ ok = false, status = 0, body = "" }), "network")
    t.eq(code({ ok = true, status = 401, body = "" }), "auth")
    t.eq(code({ ok = true, status = 403, body = "" }), "auth")
    t.eq(code({ ok = true, status = 429, body = "" }), "rate_limited")
    t.eq(code({ ok = true, status = 502, body = "" }), "server")
    t.eq(code({ ok = true, status = 200, body = "<html>" }), "parse")
    t.eq(code({ ok = true, status = 200, body = "[1]" }), nil)
  end)

  t.test("never copies response bodies into errors", function()
    local _, err = http.interpret({ ok = true, status = 500, body = "secret@example.com" }, json.decode)
    t.eq(err.detail, "HTTP 500")
  end)
end)

t.group("pace regressions", function()
  t.test("a busy first day does not alarm a weekly window", function()
    -- Live case: 11% used 10h into a 7-day window extrapolates to 177%.
    local week = 7 * 86400
    local now = 2_000_000
    local w = model.window({ id = "w", usedPercent = 11, periodSeconds = week, resetsAt = now + week - 10 * 3600 })
    t.eq(pace.compute(w, now).status, "early")
    t.eq(pace.compute(w, now).severity, "ok")
  end)
end)

t.group("notify", function()
  local notify = mods.require("lib/notify.luau")
  local function opts(overrides)
    local o = { critical = 90, low = true, reset = true, now = 0, tr = host.globals.noctalia.tr, duration = time.duration }
    for k, v in overrides or {} do
      o[k] = v
    end
    return o
  end
  local function snap(percent, resetsAt)
    return { windows = { model.window({ id = "s", label = "Session", usedPercent = percent, resetsAt = resetsAt }) } }
  end

  t.test("low: once per cycle, remembered across calls", function()
    local notified = {}
    local first = notify.messages("Claude", snap(80, 5000), snap(92, 5000), notified, opts())
    t.eq(#first, 1)
    t.eq(first[1].kind, "low")
    t.eq(first[1].body, "Session is at 92%. Resets in 1h 23m.")
    -- Dips below and crosses again in the same cycle: still once.
    t.eq(#notify.messages("Claude", snap(85, 5000), snap(95, 5000), notified, opts()), 0)
    -- Next cycle may warn again.
    t.eq(#notify.messages("Claude", snap(85, 9000), snap(95, 9000), notified, opts()), 1)
  end)

  t.test("reset: only after being near the limit, only on a real new cycle", function()
    t.eq(notify.messages("Claude", snap(97, 5000), snap(3, 23000), {}, opts())[1].kind, "reset")
    t.eq(#notify.messages("Claude", snap(60, 5000), snap(3, 23000), {}, opts()), 0, "was never near the limit")
    t.eq(#notify.messages("Claude", snap(97, 5000), snap(96, 5001), {}, opts()), 0, "jitter")
  end)

  t.test("each kind can be switched off", function()
    t.eq(#notify.messages("Claude", snap(80, 5000), snap(92, 5000), {}, opts({ low = false })), 0)
    t.eq(#notify.messages("Claude", snap(97, 5000), snap(3, 23000), {}, opts({ reset = false })), 0)
  end)
end)

t.group("packaging", function()
  t.test("lib/state VERSION matches plugin.toml", function()
    local state = mods.require("lib/state.luau")
    local manifestVersion = env.sources["plugin.toml"]:match('\nversion%s*=%s*"([^"]+)"')
    t.eq(state.VERSION, manifestVersion)
  end)

  t.test("plugin id and panel id match the manifest", function()
    local state = mods.require("lib/state.luau")
    t.eq(env.sources["plugin.toml"]:match('\nid%s*=%s*"([^"]+)"'), state.PLUGIN_ID)
    t.ok(state.PANEL_ID == state.PLUGIN_ID .. ":panel")
  end)
end)

t.group("context", function()
  t.test("a timed-out command counts as not run", function()
    local h = env.host()
    h.runHandler = function()
      return { exitCode = 0, stdout = "partial", timedOut = true }
    end
    local ctx = env.modules(h).require("lib/context.luau").new(h.globals.noctalia, "ua")
    local got = "unset"
    ctx.run({ "slow" }, 100, function(result)
      got = result
    end)
    t.eq(got, nil)
  end)
end)

return true
