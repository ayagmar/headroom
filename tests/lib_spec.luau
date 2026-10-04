--!nonstrict
local t = require("./support/t")
local env = require("./support/env")

local host = env.host()
local mods = env.modules(host)
local time = mods.require("lib/time.luau")
local pace = mods.require("lib/pace.luau")
local model = mods.require("lib/model.luau")
local scheduler = mods.require("lib/scheduler.luau")
local notify = mods.require("lib/notify.luau")
local http = mods.require("lib/http.luau")
local jwt = mods.require("lib/jwt.luau")
local view = mods.require("lib/view.luau")
local json = host.globals.noctalia.json

t.group("time", function()
  t.test("parses ISO-8601 with fractions and offsets; rejects the rest", function()
    t.eq(time.parseIso8601("2026-10-03T20:19:59.911287+00:00"), 1791058799)
    t.eq(time.parseIso8601("2000-03-01T00:00:00+02:00"), 951861600)
    t.eq(time.parseIso8601("1999-12-31T23:59:59-05:30"), 946704599)
    t.eq(time.parseIso8601("2024-02-29T12:00:00Z"), 1709208000)
    t.eq(time.parseIso8601("2026-10-03"), nil)
    t.eq(time.parseIso8601("tomorrow"), nil)
  end)

  t.test("expiry: seconds, milliseconds or ISO, with a safety margin", function()
    t.eq(time.isExpired(1000, 900), false)
    t.eq(time.isExpired(1000, 950), true, "inside the margin")
    t.eq(time.isExpired(1000 * 1000, 900), false, "epoch milliseconds")
    t.eq(time.isExpired("1970-01-01T00:16:40Z", 950), true)
    t.eq(time.isExpired(nil, 950), false, "unknown expiry: let the vendor decide")
  end)

  t.test("compact durations", function()
    t.eq(time.duration(30), "<1m")
    t.eq(time.duration(3600), "1h")
    t.eq(time.duration(3720), "1h 2m")
    t.eq(time.duration(2 * 86400 + 4 * 3600 + 59), "2d 4h")
  end)
end)

t.group("pace", function()
  local H5 = model.SESSION_SECONDS
  local now = 1_000_000
  local function window(used, remaining, period)
    return model.window({ id = "s", usedPercent = used, periodSeconds = period or H5, resetsAt = now + remaining })
  end

  t.test("runs out: when, and whether the lockout is worth a warning", function()
    local p = pace.compute(window(80, H5 / 2), now)
    t.eq(p.status, "runs_out")
    t.near(p.runsOutIn, 2250, 1e-6) -- 80% in 9000s: the last 20% takes 2250s
    t.eq(p.severity, "warn")
    t.eq(pace.compute(window(52, H5 / 2), now).severity, "ok", "runs out just before the reset")
  end)

  t.test("projects usage at reset when it will last", function()
    local p = pace.compute(window(20, H5 / 2), now)
    t.eq(p.status, "projected")
    t.near(p.projectedPercent, 40, 1e-9)
  end)

  t.test("no verdict early: one busy day must not alarm a weekly window", function()
    -- Live case: 11% used 10h into a 7-day window extrapolates to 177%.
    local week = model.WEEK_SECONDS
    t.eq(pace.compute(window(11, week - 10 * 3600, week), now).status, "early")
    t.eq(pace.compute(window(30, H5 - 300), now).status, "early")
  end)

  t.test("exhausted at the limit; nothing without a period", function()
    t.eq(pace.compute(window(100, 600), now).status, "exhausted")
    t.eq(pace.compute(model.window({ id = "x", usedPercent = 10 }), now), nil)
  end)
end)

t.group("model", function()
  t.test("clamps percentages and flags the limit", function()
    t.eq(model.window({ id = "a", usedPercent = 140 }).usedPercent, 100)
    t.eq(model.window({ id = "a", usedPercent = "42" }).usedPercent, 42)
    t.eq(model.window({ id = "a", usedPercent = 100 }).limitReached, true)
  end)

  t.test("pick: kind preference, else tightest (later reset wins ties)", function()
    local s = model.window({ id = "s", kind = "session", usedPercent = 40, resetsAt = 10 })
    local w = model.window({ id = "w", kind = "weekly", usedPercent = 40, resetsAt = 20 })
    t.eq(model.pick({ s, w }, "session").id, "s")
    t.eq(model.pick({ s, w }, "tightest").id, "w")
    t.eq(model.pick({ s }, "weekly").id, "s")
  end)
end)

t.group("scheduler", function()
  t.test("backoff per error class", function()
    t.eq(scheduler.retryDelay("network", 1, 300), 30)
    t.eq(scheduler.retryDelay("network", 3, 300), 120)
    t.eq(scheduler.retryDelay("rate_limited", 3, 300), 1200)
    t.eq(scheduler.retryDelay("rate_limited", 9, 300), 3600)
    t.eq(scheduler.retryDelay("expired", 5, 300), 60)
    t.eq(scheduler.retryDelay("no_plan", 1, 300), 3600)
  end)

  t.test("drops superseded replies; a lost request stops blocking", function()
    local e = scheduler.new()
    local first = scheduler.start(e, 0)
    t.eq(scheduler.isDue(e, 10), false)
    t.eq(scheduler.isDue(e, scheduler.TIMEOUT_SECONDS), true)
    local second = scheduler.start(e, 100)
    t.eq(scheduler.finish(e, first, 101, 300, nil), false)
    t.eq(scheduler.finish(e, second, 102, 300, nil), true)
    t.eq(e.nextAt, 402)
  end)
end)

t.group("notify", function()
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

  t.test("running low: once per cycle", function()
    local notified = {}
    local first = notify.messages("Claude", snap(80, 5000), snap(92, 5000), notified, opts())
    t.eq(first[1].body, "Session is at 92%. Resets in 1h 23m.")
    t.eq(#notify.messages("Claude", snap(85, 5000), snap(95, 5000), notified, opts()), 0, "same cycle")
    t.eq(#notify.messages("Claude", snap(85, 9000), snap(95, 9000), notified, opts()), 1, "next cycle")
    t.eq(#notify.messages("Claude", snap(80, 5000), snap(92, 5000), {}, opts({ low = false })), 0, "switched off")
  end)

  t.test("reset: only after being near the limit, only on a real new cycle", function()
    t.eq(notify.messages("Claude", snap(97, 5000), snap(3, 23000), {}, opts())[1].kind, "reset")
    t.eq(#notify.messages("Claude", snap(60, 5000), snap(3, 23000), {}, opts()), 0, "never near the limit")
    t.eq(#notify.messages("Claude", snap(97, 5000), snap(96, 5001), {}, opts()), 0, "timestamp jitter")
  end)
end)

t.group("http", function()
  local function code(response, classify)
    local _, err = http.interpret(response, json.decode, classify)
    return err and err.code
  end

  t.test("maps failures; never copies bodies into errors", function()
    t.eq(code({ ok = false, status = 0, body = "" }), "network")
    t.eq(code({ ok = true, status = 403, body = "" }), "auth")
    t.eq(code({ ok = true, status = 429, body = "" }), "rate_limited")
    t.eq(code({ ok = true, status = 200, body = "<html>" }), "parse")
    local _, err = http.interpret({ ok = true, status = 500, body = "secret@example.com" }, json.decode)
    t.eq(err.detail, "HTTP 500")
  end)

  t.test("adapters can classify their vendor's error bodies first", function()
    local function classify(status, body)
      return if status == 403 and body == "plan" then "no_plan" else nil
    end
    t.eq(code({ ok = true, status = 403, body = "plan" }, classify), "no_plan")
    t.eq(code({ ok = true, status = 403, body = "other" }, classify), "auth")
  end)
end)

t.group("jwt", function()
  t.test("reads claims from base64url payloads, rejects junk", function()
    t.eq(jwt.base64Decode("aGVsbG8"), "hello")
    t.eq(jwt.base64Decode("a!b"), nil)
    t.eq(jwt.claims(env.JWT_VALID, json.decode).exp, 1790003600)
    t.eq(jwt.claims("not-a-jwt", json.decode), nil)
  end)
end)

t.group("view", function()
  t.test("rounding never erases a difference", function()
    t.eq(view.roundPercent(0), "0")
    t.eq(view.roundPercent(0.4), "<1")
    t.eq(view.roundPercent(99.6), ">99")
    t.eq(view.roundPercent(100), "100")
  end)
end)

t.group("consistency", function()
  local manifest = env.sources["plugin.toml"]
  local registry = mods.require("providers/registry.luau")
  local translations = json.decode(env.sources["translations/en.json"])

  local function leafKeys(node, prefix, out)
    for k, v in node do
      local key = if prefix == "" then k else `{prefix}.{k}`
      if type(v) == "table" then
        leafKeys(v, key, out)
      else
        out[key] = true
      end
    end
    return out
  end

  -- Every key the code can ask for: quoted keys in the sources, manifest labels,
  -- and the families built at runtime from error codes and window kinds.
  local function usedKeys()
    local used = {}
    for path, source in env.sources do
      if path:match("%.luau$") and not path:match("^tests/") then
        -- Any quoted dotted name counts, so keys picked by an `if` are seen.
        for key in source:gmatch('"([%w_]+%.[%w_%.]+)"') do
          used[key] = true
        end
      end
    end
    for key in manifest:gmatch('_key%s*=%s*"([^"]+)"') do
      used[key] = true
    end
    local hinted = { not_configured = true, expired = true, auth = true } -- body replaced by the provider hint
    for _, code in model.ErrorCode do
      used[`error.{code}.title`] = true
      if not hinted[code] then
        used[`error.{code}.body`] = true
      end
    end
    for _, kind in { "session", "weekly", "other" } do
      used[`window.{kind}`] = true
    end
    return used
  end

  t.test("every translation used exists, and every one that exists is used", function()
    local defined = leafKeys(translations, "", {})
    local used = usedKeys()
    local missing, unused = {}, {}
    for key in used do
      -- Quoted dotted names that are not translation keys (file names, URLs).
      local looksLikeKey = not key:match("%.luau$") and not key:match("%.svg$") and not key:match("%.json$")
        and not key:match("%.com") and translations[key:match("^[^.]+")] ~= nil
      if looksLikeKey and not defined[key] then
        table.insert(missing, key)
      end
    end
    for key in defined do
      if not used[key] then
        table.insert(unused, key)
      end
    end
    table.sort(missing)
    table.sort(unused)
    t.eq(table.concat(missing, ", "), "", "missing")
    t.eq(table.concat(unused, ", "), "", "unused")
  end)

  t.test("the manifest has a bar toggle for every provider, and only those", function()
    local toggles = {}
    for id in manifest:gmatch('key = "bar_([%w_-]+)"\ntype = "bool"') do
      toggles[id] = true
    end
    for _, p in registry do
      t.ok(toggles[p.id], `plugin.toml bar_{p.id} toggle`)
      toggles[p.id] = nil
      t.ok(env.sources[p.brand.logo] ~= nil, `{p.id} logo file exists`)
    end
    t.eq(next(toggles), nil, "toggles without a provider")
  end)

  t.test("VERSION matches plugin.toml", function()
    t.eq(mods.require("lib/state.luau").VERSION, manifest:match('\nversion%s*=%s*"([^"]+)"'))
  end)
end)

return true
