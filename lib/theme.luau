--!nonstrict
-- Colors and generated images.
--
-- ui.* accepts palette roles directly, but SVG files need literal hex, so the
-- logo tints and ring gauges resolve roles through noctalia.getColor and are
-- cached as small SVGs in the plugin data dir, keyed by their content
-- (provider + color, percent + colors). A theme switch simply produces new
-- file names; nothing has to be invalidated.

local M = {}

-- Used when the palette cannot resolve a role (should not happen on API 31+).
local FALLBACK_HEX = {
  on_surface = "#E6E1E5",
  on_surface_variant = "#CAC4D0",
  surface_variant = "#49454F",
  outline = "#938F99",
  primary = "#A8C7FA",
  tertiary = "#E8C26B",
  error = "#F2B8B5",
}

-- Material palettes have an error role but no warning role, and `tertiary`
-- is often blue or pink, which does not read as "careful". So warning is a
-- fixed amber, tuned for contrast against dark and light surfaces.
local WARN_DARK = "#f2b84b"
local WARN_LIGHT = "#a86400"

-- Color for a severity, or nil for "ok" (callers use the provider accent or
-- the default text color).
function M.severityColor(severity: string): string?
  if severity == "critical" then
    return "error"
  elseif severity == "warn" then
    return if noctalia.isDarkMode and not noctalia.isDarkMode() then WARN_LIGHT else WARN_DARK
  end
  return nil
end

function M.hex(colorOrRole: string): string
  if colorOrRole:sub(1, 1) == "#" then
    return colorOrRole:lower()
  end
  colorOrRole = colorOrRole:gsub("/.*$", "") -- "primary/0.6" -> "primary" (SVG gets the solid color)
  local resolved = noctalia.getColor and noctalia.getColor(colorOrRole)
  return (resolved or FALLBACK_HEX[colorOrRole] or "#888888"):lower()
end

-- The meter color for a provider at a given severity (role or hex string;
-- both are valid UiColor values).
function M.meterColor(provider, severity: string): string
  local color = M.severityColor(severity)
  if color then
    return color
  end
  local useBrand = noctalia.getConfig("brand_colors")
  if useBrand == false then
    return "primary"
  end
  return provider.brand.accent
end

local dirs = {}

local function dataDir(sub: string): string?
  if dirs[sub] then
    return dirs[sub]
  end
  local base = noctalia.pluginDataDir()
  if base == nil then
    return nil
  end
  local dir = `{base}/{sub}`
  if not noctalia.mkdirAll(dir) then
    return nil
  end
  dirs[sub] = dir
  return dir
end

-- Writes through a temp file so another entry never loads a half-written SVG.
local function ensureFile(path: string, build: () -> string?): string?
  if noctalia.fileExists(path) then
    return path
  end
  local content = build()
  if content == nil then
    return nil
  end
  local tmp = `{path}.{math.floor(noctalia.nowMs())}.tmp`
  if not noctalia.writeFile(tmp, content) then
    return nil
  end
  if not noctalia.renameFile(tmp, path) then
    noctalia.removeFile(tmp)
    return nil
  end
  return path
end

-- Path to the provider's logo tinted for the current palette, or nil (callers
-- fall back to the provider's glyph).
function M.logo(provider): string?
  local dir = dataDir("icons")
  if dir == nil then
    return nil
  end
  local hex = M.hex(provider.brand.tint)
  local path = `{dir}/{provider.id}-{hex:sub(2)}.svg`
  return ensureFile(path, function()
    local template = noctalia.readFile(provider.brand.logo)
    if template == nil then
      return nil
    end
    -- Monochrome icons inherit fill from the root element.
    return (template:gsub("<svg ", `<svg fill="{hex}" `, 1))
  end)
end

-- A circular gauge: track ring plus an arc for `percent`. pathLength-free
-- geometry: r = 100 / 2π gives a circumference of 100, so the dash length is
-- the percentage itself.
function M.ring(percent: number, fill: string, track: string): string?
  local dir = dataDir("rings")
  if dir == nil then
    return nil
  end
  local pct = math.clamp(math.floor(percent + 0.5), 0, 100)
  local fillHex, trackHex = M.hex(fill), M.hex(track)
  local path = `{dir}/ring-{pct}-{fillHex:sub(2)}-{trackHex:sub(2)}.svg`
  return ensureFile(path, function()
    local arc = if pct > 0
      then `<circle cx="18" cy="18" r="15.9155" fill="none" stroke="{fillHex}" stroke-width="4.2" stroke-linecap="round" stroke-dasharray="{pct} 100" transform="rotate(-90 18 18)"/>`
      else ""
    return table.concat({
      `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 36 36" width="36" height="36">`,
      `<circle cx="18" cy="18" r="15.9155" fill="none" stroke="{trackHex}" stroke-width="4.2"/>`,
      arc,
      `</svg>`,
    })
  end)
end

return M
