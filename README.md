# Headroom

See how much of your Claude, Codex and Antigravity plan limits you have left without leaving your desktop. The bar shows
each provider's tightest window as a ring and a percentage. The panel shows every window with its reset countdown and
a pace check that says whether you will run out before the reset.

Headroom reuses the sign-in your CLIs already have. It needs no API keys and installs nothing extra.

## Plugin

| Field | Value |
| --- | --- |
| ID | `ayagmar/headroom` |
| Entries | Bar widget: `usage`; panel: `panel`; service: `poller` |

## Requirements

- **Claude**: sign in to [Claude Code](https://claude.com/claude-code) with a Pro, Max, Team or Enterprise plan.
  Headroom reads `~/.claude/.credentials.json` (or `$CLAUDE_CONFIG_DIR/.credentials.json`). When the session has
  expired, Headroom runs `claude -p /status --no-session-persistence` so Claude Code renews its own session. That
  command makes no model call, uses none of your quota and keeps no transcript.
- **Codex**: sign in to the [Codex CLI](https://github.com/openai/codex) with ChatGPT (`codex login`). Headroom reads
  `~/.codex/auth.json` (or `$CODEX_HOME/auth.json`). An API-key-only setup has no plan limits to show.
- **Antigravity**: sign in to the `agy` CLI or an Antigravity app with Google. Headroom reads the session Antigravity
  saved in your keyring through `secret-tool` (from libsecret), or `~/.gemini/antigravity-cli/antigravity-oauth-token`.
  Google sessions expire after an hour. When that happens Headroom runs `agy models` so agy renews its own session.
  That requires `agy` on `PATH` or in `~/.local/bin`, and Headroom does it at most once every 10 minutes. Accounts
  whose plan has no Antigravity quota show *No quota on this plan*.

Headroom detects each provider when its sign-in file is present. Providers that are not signed in stay out of the bar.

Both dependencies are optional:
- `xdg-open` is used only by the panel's "open usage page" buttons, which are hidden when it is not installed.
- `secret-tool` is used only for Antigravity's keyring session.

## Usage

Add the **Headroom** widget to your bar from Settings → Bar. Each signed-in provider appears as its logo, a ring
gauge and the usage of the window closest to its limit.

- The color turns amber at the warning threshold and red at the critical threshold.
- It also turns amber below the warning threshold when the window is on course to run out long before it resets.
- When a window is maxed out, the bar shows how long until it comes back (for example `1h 15m`) instead of `100%`.
- When an amount is real but tiny, it reads `<1%` or `>99% left` rather than rounding it away.

- **Left click** opens the panel. Opening it fetches fresh numbers in the background for any provider whose data is
  older than 30 seconds, and shows the current numbers while it does.
- **Right click** refreshes now. The binding is `plugin ayagmar/headroom:poller all refresh`, and you can rebind it in
  the widget's settings.
- **Middle click** opens Headroom's settings.
- **Hover** shows every displayed window with its usage, reset time and forecast.

The panel shows one card per provider, with every window (for example Session, Weekly, or Weekly · Opus) as a usage
meter.

- A thin time track under each meter shows how much of the window has passed. If the meter is ahead of the track,
  you are using the window faster than it allows.
- Each window shows when it resets, as a countdown plus the clock time in your shell's time format
  (`Resets in 3h 27m · 20:19`, or `Sat 07:59` for weekly windows).
- The forecast extrapolates your usage so far:
  - **≈ 59% by reset** when the window will last.
  - **Runs out in 26m** when it won't. This is highlighted when the lockout before the reset is significant.
- The link button on each card opens the provider's usage page in your browser.
- Extra usage and credits appear under the windows when your plan has them.
- If something goes wrong (expired session, rejected sign-in, offline), the card shows what happened and how to fix
  it. It keeps the last known numbers, marked as cached.
- In the panel, press `R` to refresh or `Esc` to close.

```sh
noctalia msg panel-toggle ayagmar/headroom:panel
```

## Settings

All settings are on one page (Settings → Plugins → Headroom, or middle-click the capsule). They are grouped by
prefix: **Bar**, **Display**, **Alerts** and **Data**.

**Bar**

| Setting | Type | Default | Description |
| --- | --- | --- | --- |
| `bar_claude`, `bar_codex`, `bar_antigravity` | `bool` | `true` | Which providers the bar shows (one switch each). Switched-off providers still appear in the panel. |
| `max_providers` | `int` | `3` | The most providers the bar shows (1–8). When more are switched on and signed in, the ones closest to their limits are shown, with the forecast counted. |
| `window` | `select` | `tightest` | Which window to show: `tightest` (closest to its limit), the 5-hour `session`, or `weekly`. |
| `bar_style` | `select` | `full` | What each provider shows next to its logo: `full` (ring and percentage), `value` (percentage only) or `ring` (ring only). |

**Display**

| Setting | Type | Default | Description |
| --- | --- | --- | --- |
| `display` | `select` | `used` | `used` or `remaining`: which side of the limit percentages, rings and meters show. Colors and warnings always follow usage. |
| `warn_percent` | `int` | `70` | Usage at or above this percentage uses the warning color. A window on course to be locked out for at least 10% of its length before it resets also does. |
| `critical_percent` | `int` | `90` | Usage at or above this percentage uses the error color and can notify you. |

Healthy meters use each provider's brand color.

**Alerts**

| Setting | Type | Default | Description |
| --- | --- | --- | --- |
| `notify` | `bool` | `true` | Notifies once per window when usage crosses `critical_percent`, and again when that window resets. |

**Data**

| Setting | Type | Default | Description |
| --- | --- | --- | --- |
| `refresh_minutes` | `int` | `5` | Minutes between fetches for each provider (1–120). Failures retry sooner with backoff. Throttling waits longer. |
| `disabled_providers` | `string_list` | `[]` | Advanced. Provider ids to ignore entirely (`claude`, `codex`, `antigravity`). A listed provider is never fetched and never shown. |

## IPC

```sh
# Refresh every provider now
noctalia msg plugin ayagmar/headroom:poller all refresh
```

## Notes

- **Network.** The `poller` service is the only part that makes network requests. Every `refresh_minutes` it sends
  one request per signed-in provider:
  - Claude: `GET https://api.anthropic.com/api/oauth/usage`
  - Codex: `GET https://chatgpt.com/backend-api/wham/usage`
  - Antigravity: `POST https://cloudcode-pa.googleapis.com/v1internal:retrieveUserQuotaSummary`, plus
    `:loadCodeAssist` for the plan name at most every 6 hours

  Each vendor's own tools read these same endpoints. Headroom identifies itself as `headroom-noctalia/<version>`,
  except to Antigravity's endpoint, which only answers the `antigravity` User-Agent. It honors `shell.offline_mode`.
- **Credentials are read-only.** Headroom never refreshes, rewrites or copies a token. An expired session is
  renewed by the vendor's own CLI (`claude`, `agy`), never by Headroom, because refresh tokens rotate and spending
  one here could sign your CLI out. Only when that CLI is not installed, or the renewal fails (for example because
  you were signed out), does the card ask you to sign in again. Headroom picks up the new session within a minute.
  Codex has no lightweight renewal command, so an expired Codex session still needs one run of `codex`.
- **Files written.** Everything goes in the plugin data directory (`~/.local/state/noctalia/plugins/data/ayagmar/headroom/`):
  - `cache.json`: the last usage numbers, so the bar has data right after login. It contains no credentials.
  - `icons/` and `rings/`: small theme-tinted SVGs.
- **Processes.** Every command runs directly from an argument list, with no shell:
  - `xdg-open <usage page URL>`, when you click a card's link button.
  - `claude -p /status --no-session-persistence`, when the Claude session has expired, at most every 10 minutes.
  - `secret-tool lookup service gemini username antigravity`, to read Antigravity's session. After a failed lookup
    (for example a locked keyring), Headroom waits 30 minutes before asking again, so it never keeps raising unlock
    prompts.
  - `env AGY_CLI_DISABLE_AUTO_UPDATE=true agy models`, when the Antigravity session has expired, at most every 10
    minutes.
- **These endpoints are undocumented.** Vendors can change them at any time. If a provider's card shows
  *Unexpected response*, please open an issue.
- **Trademarks.** Claude and Anthropic are trademarks of Anthropic. OpenAI and Codex are trademarks of OpenAI. Google
  and Antigravity are trademarks of Google. The Claude and OpenAI logos come from
  [Simple Icons](https://simpleicons.org) (CC0), and the Antigravity mark comes from
  [ai-usagebar](https://github.com/akitaonrails/ai-usagebar) (MIT). They are used only to identify each provider and
  imply no endorsement.
