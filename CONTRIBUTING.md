# Contributing to Headroom

## Architecture

```
providers/<id>/init.luau   adapter: credentials + endpoint -> model.Snapshot
providers/<id>/logo.svg    monochrome logo, tinted at runtime
providers/registry.luau    the list of adapters, in display order
lib/model.luau             the normalized schema (Window, Snapshot, ProviderError)
lib/provider.luau          the adapter contract and its Context
lib/context.luau           builds the Context: everything an adapter is allowed to do, per account
lib/accounts.luau          a provider's accounts (one per config folder), the registry of added ones
lib/http.luau              JSON GET/POST and error mapping (adapters can classify their own error bodies)
lib/renew.luau             hands an expired session back to the vendor's CLI, with a cooldown
lib/scheduler.luau         per-provider timing, backoff, dropping late replies
lib/pace.luau              forecast: projected usage at reset, or when it runs out
lib/notify.luau            which notifications a new snapshot deserves (pure)
lib/time.luau, jwt.luau    timestamps, expiry, durations; reading JWT expiry
lib/fs.luau                atomic file writes
lib/state.luau             what the service publishes and the surfaces read
lib/view.luau, theme.luau  wording, colors, tinted logos, ring gauges
ui/cards.luau              provider cards and their states
service.luau               [[service]]: the only entry that fetches; carries out account commands
bar.luau, panel.luau       [[widget]] and [[panel]]: presentation only
```

Data flows one way:

```
adapter.fetch(ctx) ──► service ──noctalia.state("report")──► bar / panel
                         ▲                                      │
                         └──── noctalia.state("command") ◄──────┘  (refresh, add/sign in/remove account)
```

Adapters never touch the `noctalia` global. Everything they can do (read a file, fetch JSON, run a command, translate
a string) comes through the `Context` in `lib/provider.luau`. That keeps an adapter's side effects in one place for
review, and lets the tests run adapters against recorded responses.

## Adding a provider

1. **Create `providers/<id>/init.luau`** returning `provider.define{...}` with:
   - `id`, `name`
   - `brand = { logo, tint, glyph, dashboard? }`. `tint` colors the logo; meters use the theme.
   - `isConfigured(ctx)`: a cheap local check for a sign-in. The service runs it every 30 seconds.
   - `fetch(ctx, done)`: calls `done(snapshot)` or `done(nil, model.err(code))`, exactly once.
   - `signInHint(ctx)`: one line telling the user how to sign in.
   - `parse` (optional): the pure response-to-snapshot step, exposed so fixtures can test it.
   - `accounts` (optional): for a CLI that keeps its sign-in in a folder an environment variable can move, like
     Claude Code's `CLAUDE_CONFIG_DIR`. Give the variable, the default folder, the prefix of sibling folders, the CLI and
     its login arguments, and an `identity(ctx)` that reads who is signed in. Headroom then shows one account per
     folder, lets users add accounts from the panel, and runs your adapter once per account with `ctx.home` set to
     that folder: read credentials from there, and wrap any command you run in `ctx.inHome(argv)`. Skip renewal when
     `ctx.mayRenew` is false.

   `providers/claude/init.luau` is the model for a token file, a GET, accounts and session renewal;
   `providers/antigravity/init.luau` for a keyring and a POST. Map each vendor window onto a `kind` (`session`,
   `weekly`, `model` or `other`), and set `periodSeconds` when you know it: forecasts need it.
2. **Add `providers/<id>/logo.svg`**: monochrome, with no `fill` on the root element.
   [Simple Icons](https://simpleicons.org) is a good source.
3. **Register it** with one line in `providers/registry.luau`.
4. **Give it a Providers setting**: copy a `provider_<id>` select in `plugin.toml` (its options and description are
   shared) and add `settings.provider_<id>.label` ("Providers · <Name>") to `translations/en.json`.
5. **Add its sign-in hint** as `providers.<id>.hint` in `translations/en.json`.
6. **Test it**: record a real response into `tests/fixtures/<id>_usage.json` (redact ids and emails) and add parse
   and fetch cases to `tests/providers_spec.luau`. `scripts/test.sh` also fails when steps 3–5 drift apart: a provider
   without a setting, a setting without a provider, or a translation that is used but missing, or defined but unused.
7. **Document it**: the endpoint, credential path and any command it runs go in the README's *Requirements* and
   *Notes*.

The bar and the panel need no changes.

### Rules for adapters

- **Credentials are read-only.** Never refresh a token or write to a vendor's files: refresh tokens rotate, and
  using one could sign the vendor's CLI out. When a session expires, either report `expired`, or, if the vendor's
  CLI has a cheap command that renews its own session, run it through `lib/renew` and read the credentials again.
- **Talk only to the vendor's own usage endpoint.** Run commands only through `ctx.run`, as an argument list (never a
  shell string), and list each one in the README's *Notes*.
- **Keep response bodies, tokens and emails out of errors and logs.** `lib/http.luau` already never copies bodies.
- **Assume undocumented endpoints will change.** Treat every field as optional and return a `parse` error rather than
  throwing. The service survives a crashing adapter, but don't rely on it.

## Development

```sh
ln -sfn "$PWD" ~/.local/share/noctalia/plugins/headroom
noctalia msg plugins enable ayagmar/headroom
```

`.luau` edits reload on their own. `plugin.toml` and `translations/` are read only when the plugin is enabled
(`noctalia msg config-reload` doesn't re-read them), so after changing either, run
`noctalia msg plugins disable ayagmar/headroom && noctalia msg plugins enable ayagmar/headroom`.

Logs are in `~/.cache/noctalia/noctalia.log` (`grep headroom`).

```sh
scripts/test.sh        # unit and integration tests against a fake host (downloads the Luau CLI on first run)
noctalia plugins lint .
```

For editor support, put `noctalia.d.luau` from [official-plugins](https://github.com/noctalia-dev/official-plugins) in
the repo root (it's gitignored) and point luau-lsp at it.
