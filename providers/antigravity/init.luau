--!nonstrict
-- Google Antigravity (the `agy` CLI and the Antigravity apps share one quota).
--
-- Credentials: the Google session Antigravity saves through go-keyring, read
-- with `secret-tool lookup service gemini username antigravity` (Secret
-- Service), or the `agy` CLI's file ~/.gemini/antigravity-cli/antigravity-oauth-token.
-- Read-only, like every adapter.
--
-- Google access tokens live for an hour and only Antigravity can renew them, so
-- an expired session is handed back to Antigravity: we run `agy models` (the
-- lightest authenticated command; no prompt, no TTY), which makes agy refresh
-- its own keyring entry, then read it again. At most once per RENEW_COOLDOWN,
-- so a dead session does not spawn agy on every refresh.
--
-- Endpoints: POST https://cloudcode-pa.googleapis.com/v1internal:retrieveUserQuotaSummary
-- (daily-cloudcode-pa as fallback), and :loadCodeAssist for the plan name
-- (at most every 6 hours). Undocumented. It only answers clients that
-- identify as Antigravity, so this adapter's User-Agent is "antigravity"
-- rather than Headroom's own. Plans without Antigravity quota get 403
-- SUBSCRIPTION_REQUIRED, reported as no_plan rather than as a sign-in problem.

local provider = require("../../lib/provider.luau")
local model = require("../../lib/model.luau")
local time = require("../../lib/time.luau")
local jwt = require("../../lib/jwt.luau")

local E = model.ErrorCode

local CODE_ASSIST_URL = "https://cloudcode-pa.googleapis.com/v1internal:loadCodeAssist"
local CLIENT_METADATA = '{"metadata":{"ideType":"ANTIGRAVITY","platform":"PLATFORM_UNSPECIFIED","pluginType":"GEMINI"}}'
-- The plan changes rarely; ask for it at most this often.
local PLAN_TTL = 6 * 3600
local QUOTA_URLS = {
  "https://cloudcode-pa.googleapis.com/v1internal:retrieveUserQuotaSummary",
  "https://daily-cloudcode-pa.googleapis.com/v1internal:retrieveUserQuotaSummary",
}
local SESSION_SECONDS = 5 * 3600
local WEEK_SECONDS = 7 * 86400
local RENEW_COOLDOWN = 600
local RENEW_TIMEOUT_MS = 30000
-- Renew a little early: a token that dies in flight wastes a refresh cycle.
local EXPIRY_MARGIN = 60

local KEYRING_LOOKUP = { "secret-tool", "lookup", "service", "gemini", "username", "antigravity" }
local TOKEN_FILE = "~/.gemini/antigravity-cli/antigravity-oauth-token"
local CLI_SETTINGS = "~/.gemini/antigravity-cli/settings.json"
local LOCAL_AGY = "~/.local/bin/agy"

-- Module state lives as long as the service.
local lastRenewAt = -math.huge
-- A failed lookup may mean a locked keyring, and asking again could raise an
-- unlock prompt on every refresh. So after a failure the keyring rests for
-- KEYRING_BACKOFF and only the token file is read.
local KEYRING_BACKOFF = 30 * 60
local keyringFailedAt = -math.huge
local planCache: { value: string?, at: number } = { value = nil, at = -math.huge }

type Session = { accessToken: string, expiresAt: number? }

-- Accepts go-keyring's "go-keyring-base64:" wrapper, a { token = {...} }
-- envelope or a flat token object, with snake_case or camelCase keys.
local function parseSession(raw: string?, ctx): Session?
  if type(raw) ~= "string" then
    return nil
  end
  raw = raw:match("^%s*(.-)%s*$")
  local wrapped = raw:match("^go%-keyring%-base64:(.*)$")
  if wrapped then
    raw = jwt.base64Decode(wrapped)
    if raw == nil then
      return nil
    end
  end
  local data = ctx.decodeJson(raw)
  if type(data) ~= "table" then
    return nil
  end
  local token = if type(data.token) == "table" then data.token else data
  local access = token.access_token or token.accessToken
  if type(access) ~= "string" or access == "" then
    return nil
  end
  local expiry = token.expiry or token.expires_at or token.expiresAt
  local expiresAt = time.toUnix(expiry)
  if expiresAt and expiresAt > 1e11 then
    expiresAt //= 1000 -- epoch milliseconds
  end
  return { accessToken = access, expiresAt = expiresAt }
end

local function readSession(ctx, done: (Session?) -> ())
  local function fromFile()
    local path = ctx.expandPath(TOKEN_FILE)
    if not ctx.fileExists(path) then
      done(nil)
      return
    end
    local raw = ctx.readFile(path)
    done(parseSession(raw, ctx))
  end
  if not ctx.which("secret-tool") or ctx.now() - keyringFailedAt < KEYRING_BACKOFF then
    fromFile()
    return
  end
  ctx.run(KEYRING_LOOKUP, 5000, function(result)
    local session = result and result.exitCode == 0 and parseSession(result.stdout, ctx) or nil
    if session then
      done(session)
    else
      keyringFailedAt = ctx.now()
      fromFile()
    end
  end)
end

local function agyCommand(ctx): string?
  if ctx.which("agy") then
    return "agy"
  end
  local local_ = ctx.expandPath(LOCAL_AGY)
  return if ctx.fileExists(local_) then local_ else nil
end

local function isFresh(session: Session?, now: number): boolean
  return session ~= nil and (session.expiresAt == nil or session.expiresAt - EXPIRY_MARGIN > now)
end

-- Asks agy to renew its own session; done(true) when it ran successfully.
local function renew(ctx, done: (boolean) -> ())
  local agy = agyCommand(ctx)
  local now = ctx.now()
  if agy == nil or now - lastRenewAt < RENEW_COOLDOWN then
    done(false)
    return
  end
  lastRenewAt = now
  -- `env` sets one variable for this run only: agy otherwise may launch its
  -- background updater.
  ctx.run({ "env", "AGY_CLI_DISABLE_AUTO_UPDATE=true", agy, "models" }, RENEW_TIMEOUT_MS, function(result)
    done(result ~= nil and result.exitCode == 0)
  end)
end

local function groupLabel(name: any): string
  name = if type(name) == "string" then name else ""
  if name:find("Gemini", 1, true) then
    return "Gemini"
  elseif name:find("Claude", 1, true) or name:find("GPT", 1, true) then
    return "Claude & GPT"
  end
  return name
end

-- Exposed for tests: quota summary -> Snapshot. The API reports what is left;
-- every other provider reports what is spent, so it is inverted here.
local function parse(data, ctx): (model.Snapshot?, model.ProviderError?)
  local body = if type(data.response) == "table" then data.response else data
  local groups = body.groups
  if type(groups) ~= "table" then
    return nil, model.err(E.Parse, "no quota groups")
  end
  local windows = {}
  for _, group in groups do
    local label = groupLabel(group.displayName)
    for _, bucket in (if type(group.buckets) == "table" then group.buckets else {}) do
      local remaining = tonumber(bucket.remainingFraction)
      local id = tostring(bucket.bucketId or "")
      local cadence = bucket.window
      local weekly = cadence == "weekly" or id:sub(-6) == "weekly"
      local session = cadence == "5h" or id:sub(-2) == "5h"
      -- A missing fraction is unknown usage, not 0%: skip it rather than reassure.
      if remaining == nil or remaining ~= remaining or remaining < 0 or remaining > 1 or not (weekly or session) then
        continue
      end
      local kind = if weekly then "weekly" else "session"
      table.insert(windows, model.window({
        id = if id ~= "" then id else `{label}:{kind}`,
        kind = kind,
        label = `{label} · {ctx.tr(`window.{kind}`)}`,
        usedPercent = (1 - remaining) * 100,
        resetsAt = time.parseIso8601(bucket.resetTime),
        periodSeconds = if weekly then WEEK_SECONDS else SESSION_SECONDS,
      }))
    end
  end
  if #windows == 0 then
    return nil, model.err(E.Parse, "no usable quota buckets")
  end
  return model.snapshot({ plan = nil, windows = windows, notes = {}, fetchedAt = ctx.now() }), nil
end

-- "Google AI Pro" from loadCodeAssist; paidTier wins over currentTier, which
-- reads "free-tier" even for paid Google AI accounts.
local function planFrom(data): string?
  for _, key in { "paidTier", "currentTier" } do
    local tier = data[key]
    if type(tier) == "table" and type(tier.name) == "string" and tier.name ~= "" then
      return tier.name
    end
  end
  return nil
end

-- Best effort: a failure leaves the plan unknown and never fails the fetch.
local function withPlan(ctx, headers, done: (string?) -> ())
  if ctx.now() - planCache.at < PLAN_TTL then
    done(planCache.value)
    return
  end
  ctx.postJson(CODE_ASSIST_URL, headers, CLIENT_METADATA, function(data, err)
    if err == nil then
      planCache = { value = planFrom(data), at = ctx.now() }
    end
    done(planCache.value)
  end)
end

local function query(ctx, session: Session, done)
  local headers = {
    ["Authorization"] = `Bearer {session.accessToken}`,
    ["User-Agent"] = "antigravity", -- required by the endpoint; see header comment
  }
  local finish = done
  done = function(snapshot, err)
    if snapshot == nil then
      finish(nil, err)
      return
    end
    withPlan(ctx, headers, function(plan)
      snapshot.plan = plan
      finish(snapshot, nil)
    end)
  end
  local function attempt(index: number)
    ctx.postJson(QUOTA_URLS[index], headers, "{}", function(data, err)
      local retryable = err and (err.code == E.Network or err.code == E.Server)
      if retryable and index < #QUOTA_URLS then
        attempt(index + 1)
      elseif err then
        done(nil, err)
      else
        done(parse(data, ctx))
      end
    end)
  end
  attempt(1)
end

return provider.define({
  id = "antigravity",
  name = "Antigravity",
  brand = {
    logo = "providers/antigravity/logo.svg",
    tint = "#4c8df6",
    accent = "#4c8df6",
    glyph = "rocket",
  },

  isConfigured = function(ctx)
    return ctx.fileExists(ctx.expandPath(CLI_SETTINGS))
      or ctx.fileExists(ctx.expandPath(TOKEN_FILE))
      or agyCommand(ctx) ~= nil
  end,

  signInHint = function(ctx)
    return ctx.tr("providers.antigravity.hint")
  end,

  fetch = function(ctx, done)
    readSession(ctx, function(session)
      if session == nil then
        done(nil, model.err(E.NotConfigured))
      elseif isFresh(session, ctx.now()) then
        query(ctx, session, done)
      else
        renew(ctx, function(renewed)
          if not renewed then
            done(nil, model.err(E.Expired))
            return
          end
          readSession(ctx, function(again)
            if isFresh(again, ctx.now()) then
              query(ctx, again, done)
            else
              done(nil, model.err(E.Expired))
            end
          end)
        end)
      end
    end)
  end,

  parse = parse,

  -- Test seam: forget the renewal and keyring cooldowns.
  resetRenewCooldown = function()
    lastRenewAt = -math.huge
    keyringFailedAt = -math.huge
    planCache = { value = nil, at = -math.huge }
  end,
})
