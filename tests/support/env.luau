--!nonstrict
-- Shared fixtures for specs: a fresh fake host plus credential files.

local sources = require("../_generated/sources")
local hostLib = require("./host")
local loader = require("./loader")

local M = {}

M.sources = sources
M.find = hostLib.find
M.texts = hostLib.texts

M.CLAUDE_CREDS = "/home/test/.claude/.credentials.json"
M.CODEX_AUTH = "/home/test/.codex/auth.json"

-- JWTs (alg none) whose exp is relative to the host's default clock 1_790_000_000.
M.JWT_VALID = "eyJhbGciOiJub25lIn0.eyJleHAiOjE3OTAwMDM2MDB9.sig"
M.JWT_EXPIRED = "eyJhbGciOiJub25lIn0.eyJleHAiOjE3ODk5OTAwMDB9.sig"
M.JWT_ID_PRO = "eyJhbGciOiJub25lIn0.eyJodHRwczovL2FwaS5vcGVuYWkuY29tL2F1dGgiOnsiY2hhdGdwdF9wbGFuX3R5cGUiOiJwcm8ifX0.sig"

-- A fresh host whose filesystem already holds the plugin's own assets
-- (plugin-relative paths, as Noctalia resolves them).
function M.host()
  local host = hostLib.new(sources)
  for path, content in sources do
    if path:match("%.svg$") then
      host.files[path] = content
    end
  end
  return host
end

-- A runtime for `entryPath` without running it (for requiring modules).
function M.modules(host, entryPath: string?)
  return loader.entry(sources, host, entryPath or "service.luau")
end

function M.start(host, entryPath: string)
  return loader.entry(sources, host, entryPath).start()
end

function M.fixture(name: string): string
  return assert(sources[`tests/fixtures/{name}`], `missing fixture {name}`)
end

function M.claudeCreds(host, overrides)
  local oauth = {
    accessToken = "claude-token",
    expiresAt = (host.clock + 3600) * 1000,
    subscriptionType = "team",
    rateLimitTier = "default_claude_max_5x",
  }
  for k, v in overrides or {} do
    oauth[k] = v
  end
  host.files[M.CLAUDE_CREDS] = host.globals.noctalia.json.encode({ claudeAiOauth = oauth })
end

function M.codexAuth(host, tokens)
  host.files[M.CODEX_AUTH] = host.globals.noctalia.json.encode({
    auth_mode = "chatgpt",
    tokens = tokens or { access_token = M.JWT_VALID, id_token = M.JWT_ID_PRO, account_id = "acct-1" },
  })
end

-- Routes requests by host to fixture bodies (or a custom status).
function M.serve(host, routes)
  host.httpHandler = function(req)
    for needle, response in routes do
      if string.find(req.url, needle, 1, true) then
        if type(response) == "string" then
          return { ok = true, status = 200, body = response }
        end
        return response
      end
    end
    return { ok = true, status = 404, body = "" }
  end
end

function M.headerOf(req, name: string): string?
  for _, line in req.headers or {} do
    local k, v = line:match("^([^:]+):%s*(.*)$")
    if k and k:lower() == name:lower() then
      return v
    end
  end
  return nil
end

function M.noMissingKeys(t, host)
  local missing = {}
  for key in host.missingKeys do
    table.insert(missing, key)
  end
  table.sort(missing)
  t.eq(table.concat(missing, ", "), "", "missing translation keys")
end

return M
