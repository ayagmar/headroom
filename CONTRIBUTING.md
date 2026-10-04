# Contributing to Headroom

## Architecture

```
providers/<id>/init.luau   adapter: credentials + endpoint -> model.Snapshot
providers/<id>/logo.svg    monochrome logo, tinted at runtime
providers/registry.luau    the list of adapters, in display order
lib/model.luau             the normalized schema (Window, Snapshot, ProviderError)
lib/provider.luau          the adapter contract and its Context
lib/scheduler.luau         per-provider timing, backoff, stale-reply protection
lib/context.luau           builds the Context: the only capabilities adapters get
lib/http.luau              JSON GET/POST + vendor-neutral error mapping
lib/notify.luau            which notifications a new snapshot deserves (pure)
lib/state.luau             the service <-> surfaces shared-state contract
lib/view.luau, theme.luau  wording, colors, tinted logos, ring gauges
ui/cards.luau              provider cards and states, shared by full-detail surfaces
service.luau               [[service]]: the only entry that fetches
bar.luau, panel.luau       [[widget]] and [[panel]]: presentation only
```

Data flows one way:

```
adapter.fetch(ctx) ──► service ──noctalia.state("report")──► bar / panel
                         ▲                                      │
                         └──── noctalia.state("command") ◄──────┘  (refresh)
```

Adapters never touch the `noctalia` global. Everything they can do (read a file, GET JSON, translate a string)
comes in through the `Context` defined in `lib/provider.luau`. This keeps each adapter's side effects easy to review
and lets the tests run adapters against recorded responses.

## Adding a provider

1. **Create `providers/<id>/init.luau`** and return `provider.define{...}` with these fields:
   - `id`, `name`
   - `brand = { logo, tint, accent, glyph, dashboard? }`
   - `isConfigured(ctx)`: a cheap local check, run on every tick.
   - `fetch(ctx, done)`: calls `done(snapshot)` or `done(nil, model.err(code))` exactly once.
   - `signInHint(ctx)`: a one-line recovery instruction.
   - `parse`: optional, but expose it so fixtures can test it.

   Use `providers/claude/init.luau` as the reference for a token file plus a GET, and
   `providers/antigravity/init.luau` for a keyring, a POST, and renewal delegated to the vendor's CLI. Map vendor windows onto the `kind` values `session`, `weekly`,
   `model` or `other`, and set `periodSeconds` when you know it, because pacing depends on it.
2. **Add `providers/<id>/logo.svg`**: a monochrome SVG with no `fill` on the root element. [Simple Icons](https://simpleicons.org)
   is a good source.
3. **Register it** with one line in `providers/registry.luau`.
4. **Expose it in the bar's provider picker**: add an option to the `provider` widget setting in `plugin.toml` and a
   `settings.provider.option.<id>` label to `translations/en.json`.
5. **Translate** `providers.<id>.hint` in `translations/en.json`.
6. **Test it**: record a real response into `tests/fixtures/<id>_usage.json` (redact ids and emails), then add
   parse and fetch cases to `tests/providers_spec.luau`.
7. **Document it**: add the endpoint and credential path to the README's *Requirements* and *Notes*.

The bar and the panel need no changes.

### Rules for adapters

- **Credentials are read-only.** Never refresh a token or write to a vendor's files. Report `expired` and let the
  vendor's tool renew it.
- **Only make requests to the vendor's own usage endpoint.** Spawn processes only through `ctx.run`, with
  argv (no shell), and document each command in the README's *Notes*.
- **Never put response bodies, tokens or emails in errors or logs.** `lib/http.luau` already keeps bodies out.
- **Expect undocumented endpoints to change.** Treat every field as optional and return a `parse` error rather
  than throwing. The service also contains adapter crashes, but don't rely on that.

## Development

```sh
ln -sfn "$PWD" ~/.local/share/noctalia/plugins/headroom
noctalia msg plugins enable ayagmar/headroom
noctalia msg panel-toggle ayagmar/headroom:panel
```

`.luau` edits hot-reload. For edits to `plugin.toml` or `translations/en.json`, run
`noctalia msg plugins disable ayagmar/headroom && noctalia msg plugins enable ayagmar/headroom`
(`config-reload` alone does not re-read them). Logs are in `~/.cache/noctalia/noctalia.log`
(`grep headroom`).

```sh
scripts/test.sh        # unit + integration tests against a fake host (fetches the Luau CLI on first run)
noctalia plugins lint .
```

For editor support, fetch `noctalia.d.luau` from
[official-plugins](https://github.com/noctalia-dev/official-plugins) into the repo root (it is gitignored) and point
luau-lsp at it.
