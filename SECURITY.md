# Security Policy

## Reporting a vulnerability

Please **do not** open a public issue for a security problem. Instead, use
GitHub's [private security advisory](https://github.com/ThisIsTiger/XRadar/security/advisories/new)
for this repository, or contact the maintainer via the profile linked on the
repository. Include a description, reproduction steps, and the impact you
believe it has. We aim to acknowledge reports within a few days.

## Scope

XRadar runs entirely on your Mac and stores everything locally. Relevant
security surfaces are:

- **Credential handling** — the Telegram bot token and chat ID are stored only in
  the macOS Keychain and must never be written to JSON config/state files or logs.
- **X session isolation** — the app uses its own `WKWebsiteDataStore` and must
  never read another browser's cookies; X session cookies must never reach
  business logic.
- **Outbound requests** — RSSHub instances and custom RSS feeds are fetched
  through an ephemeral, cookie-less session with an HTTPS-only policy, a same-host
  redirect allowlist, and a response-size cap. Credentials/query/fragment in an
  instance URL are rejected, and `x.com` / `twitter.com` are refused as feed hosts.
- **Logging and diagnostics** — no secrets, tokens, cookies, or full page content
  may be logged or exported; the diagnostics export is expected to redact them.

## Out of scope

- X account risk control (风控) resulting from using the WebView fetch policy —
  this is a documented, user-acknowledged trade-off.
- Availability or behavior of third-party RSSHub instances and public feeds.
- The ad-hoc signature produced by `scripts/package.sh` (for local use only; not
  a distribution signature).
