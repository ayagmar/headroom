# Headroom

See how much of your Claude and Codex subscription limits you have left without leaving your desktop. The bar shows
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
  Headroom reads `~/.claude/.credentials.json` (or `$CLAUDE_CONFIG_DIR/.credentials.json`).
- **Codex**: sign in to the [Codex CLI](https://github.com/openai/codex) with ChatGPT (`codex login`). Headroom reads
  `~/.codex/auth.json` (or `$CODEX_HOME/auth.json`). An API-key-only setup has no plan limits to show.

Headroom detects each provider when its sign-in file is present. Providers that are not signed in stay out of the bar.

## Usage

Add the **Headroom** widget to your bar from Settings → Bar. Each signed-in provider appears as its logo, a ring
gauge and the usage of the window closest to its limit. The color turns to warning and then critical as usage grows.

- **Left click** opens the panel.
- **Right click** refreshes now. The binding is `plugin ayagmar/headroom:poller all refresh`, and you can rebind it in
  the widget's settings.
- **Hover** shows every displayed window with its usage and reset countdown.

The panel shows one card per provider, with every window (for example Session, Weekly, or Weekly · Opus) as a usage
meter.

- A thin time track under each meter shows how much of the window has passed. If the meter is ahead of the track,
  you are using the window faster than it allows.
- The pace line reads either **Runs out in 48m** (shown when you will hit the limit before the reset), **On pace**, or
  **N pts under pace**.
- Extra usage and credits appear under the windows when your plan has them.
- If something goes wrong (expired session, rejected sign-in, offline), the card shows what happened and how to fix
  it. It keeps the last known numbers, marked as cached.
- In the panel, press `R` to refresh or `Esc` to close.

```sh
noctalia msg panel-toggle ayagmar/headroom:panel
```

## Settings

Plugin settings (Settings → Plugins → Headroom):

| Setting | Type | Default | Description |
| --- | --- | --- | --- |
| `refresh_minutes` | `int` | `5` | Minutes between fetches for each provider (1–120). Failures retry sooner with backoff. Throttling waits longer. |
| `warn_percent` | `int` | `70` | Usage at or above this percentage uses the warning color. |
| `critical_percent` | `int` | `90` | Usage at or above this percentage uses the error color and triggers a notification. |
| `notify` | `bool` | `true` | Sends one notification per window per reset cycle when usage crosses `critical_percent`. |
| `brand_colors` | `bool` | `true` | Colors healthy meters with each provider's brand color. Turn it off to use the theme's primary color. |

Widget settings (per bar capsule):

| Setting | Type | Default | Description |
| --- | --- | --- | --- |
| `provider` | `select` | `all` | `all` shows every signed-in provider. `auto` shows only the one closest to its limit. `claude` or `codex` pins one provider. |
| `window` | `select` | `tightest` | Which window to show: the one `tightest` (closest to its limit), the 5-hour `session`, or `weekly`. |
| `show_logo` | `bool` | `true` | Show the provider logo. |
| `show_ring` | `bool` | `true` | Show the ring gauge. |
| `show_value` | `bool` | `true` | Show the percentage (a bare number on vertical bars). |
| `show_countdown` | `bool` | `false` | Show the time until the window resets (horizontal bars only). |

To track two providers in different places, add two capsules and set each one's `provider`.

## IPC

```sh
# Refresh every provider now
noctalia msg plugin ayagmar/headroom:poller all refresh
```

## Notes

- **Network.** The `poller` service is the only part that makes network requests. Every `refresh_minutes` it sends
  one `GET` per signed-in provider: `https://api.anthropic.com/api/oauth/usage` for Claude and
  `https://chatgpt.com/backend-api/wham/usage` for Codex. Claude Code and the Codex CLI use these same endpoints for
  their own usage screens. Headroom identifies itself as `headroom-noctalia/<version>`. It honors `shell.offline_mode`.
- **Credentials are read-only.** Headroom never refreshes, rewrites or copies a token. Both vendors rotate refresh
  tokens, so spending one here would sign your CLI out. When a session expires, the card says so, and running the CLI
  once renews it. Headroom picks up the new session within a minute.
- **Files written.** Everything goes in the plugin data directory (`~/.local/state/noctalia/plugins/data/ayagmar/headroom/`):
  - `cache.json`: the last usage numbers, so the bar has data right after login. It contains no credentials.
  - `icons/` and `rings/`: small theme-tinted SVGs.
- **No processes are spawned.**
- **These endpoints are undocumented.** Vendors can change them at any time. If a provider's card shows
  *Unexpected response*, please open an issue.
- **Trademarks.** Claude and Anthropic are trademarks of Anthropic. OpenAI and Codex are trademarks of OpenAI. The
  logos come from [Simple Icons](https://simpleicons.org) (CC0), are used only to identify each provider, and imply no
  endorsement.
