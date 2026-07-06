# SiteBlock

A private, single-user macOS menu bar app that blocks distracting websites across all
browsers (Chrome, Firefox, Safari) using an asymmetric friction model: **effortless to add
restrictions, deliberately slow to remove them.**

- **Strengthen instantly** — turning blocking on and adding a domain are one click, no gate.
- **Weaken deliberately** — turning blocking off, or removing a domain, requires a **5-minute
  cooldown → a 2-minute confirmation window → your Mac password**. Miss the window and you start
  over. Quitting or restarting resets a pending timer (blocking stays on).

Blocking works by writing a managed region into `/etc/hosts` (each domain → `127.0.0.1` + `::1`),
so it covers every browser at once and persists across restarts. `www.` and common subdomains are
covered automatically. `http://` sites show a custom blocked page; `https://` sites show the
browser's own security warning (a documented limitation — see below).

## Architecture

| Target | What it is |
| --- | --- |
| `SiteBlockCore` | Pure, fully-unit-tested logic: domain normalization/expansion, hosts-region rendering + atomic write, the friction state machine, JSON persistence, the blocked-page server, and `AppModel` (all action logic). |
| `SiteBlock` | The SwiftUI `MenuBarExtra` app: menu bar UI + the real system adapters (XPC helper client, `LocalAuthentication`, `SMAppService` launch-at-login). |
| `SiteBlockHelper` | The privileged `launchd` daemon (registered once via `SMAppService`) that performs the `/etc/hosts` edits and serves the blocked page on port 80. |

## Build & run

Requires macOS 13+ and Xcode 15+ (developed on Xcode 26).

```sh
swift build          # builds all targets
swift test           # runs the full SiteBlockCore test suite
```

To run the actual menu bar app with real system blocking you must build the app **bundle** in
Xcode (so the helper daemon and Info.plist are packaged and code-signed) — the plain
`swift build` binary cannot register an `SMAppService` daemon. Templates for the required
`Info.plist` and the helper's `launchd` plist are in [`Packaging/`](Packaging/), and the full
walkthrough is in [`docs/MANUAL_VERIFICATION.md`](docs/MANUAL_VERIFICATION.md).

## What's automatically tested vs. manually verified

- **Automated (`swift test`):** every pure behavior — domain expansion, the hosts
  managed-region render/apply/remove + atomic write, the 5-min→2-min friction machine, JSON
  persistence, the loopback blocked-page server and TLS SNI sensor, block-attempt counting,
  and all of `AppModel`'s instant-vs-gated logic.
- **Manual (needs a signed build on a live login session with admin approval — cannot run in
  headless CI):** the `SMAppService` helper registration, the one-time admin prompt, real
  `/etc/hosts` blocking across Chrome/Firefox/Safari, the on-screen password confirmation, and
  launch-at-login. See `docs/MANUAL_VERIFICATION.md`.

## Scope

v1 is a single-Mac focus tool. Out of scope: iPhone/Windows, scheduling, Pomodoro sessions,
preset category lists, text-file import, remember-password-for-session, and signed/App-Store
distribution.
