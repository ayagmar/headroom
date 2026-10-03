--!nonstrict
-- Pacing: is the current burn rate sustainable until the window resets?
--
-- A window that is 40% used but only 20% elapsed is on track to run out; one
-- that is 80% used with 10 minutes left is fine. Comparing usage to elapsed
-- time is what turns a raw percentage into something you can act on.

local M = {}

export type Pace = {
  elapsedFraction: number, -- 0..1 of the window that has passed
  expectedPercent: number, -- usage a perfectly even burn would show now
  delta: number, -- usedPercent - expectedPercent (positive = burning fast)
  status: string, -- "exhausted" | "runs_out" | "on_track" | "under"
  runsOutIn: number?, -- seconds until 100% at the current rate, when before reset
}

-- Below this much elapsed time a projection is noise (one burst early in a
-- window would predict exhaustion), so we report elapsed time but no verdict.
local MIN_ELAPSED_FRACTION = 0.05
local MIN_ELAPSED_SECONDS = 15 * 60
-- |delta| under this many points counts as on track.
local TOLERANCE = 10

function M.compute(window, now: number): Pace?
  local period = window.periodSeconds
  local resetsAt = window.resetsAt
  if period == nil or resetsAt == nil or period <= 0 then
    return nil
  end
  local remaining = math.clamp(resetsAt - now, 0, period)
  local elapsed = period - remaining
  local fraction = elapsed / period
  local used = window.usedPercent
  local expected = fraction * 100

  local pace: Pace = {
    elapsedFraction = fraction,
    expectedPercent = expected,
    delta = used - expected,
    status = "on_track",
    runsOutIn = nil,
  }

  if used >= 100 or window.limitReached then
    pace.status = "exhausted"
    return pace
  end
  if fraction < MIN_ELAPSED_FRACTION or elapsed < MIN_ELAPSED_SECONDS then
    return pace
  end

  -- At a constant rate, any usage above the even-burn line runs out before the
  -- reset, so the tolerance band is what keeps "2 points over" from raising an alarm.
  if pace.delta > TOLERANCE then
    pace.status = "runs_out"
    pace.runsOutIn = (100 - used) / (used / elapsed)
  elseif pace.delta < -TOLERANCE then
    pace.status = "under"
  end
  return pace
end

return M
