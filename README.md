# SiteBlock

A private, single-user macOS menu bar app that blocks distracting websites across all
browsers (Chrome, Firefox, Safari) using an asymmetric friction model: effortless to add
restrictions, deliberately slow to remove them.

## Status

Early development.

## Stack

- Swift + SwiftUI (`MenuBarExtra`) menu bar app
- `SMAppService` privileged helper (edits `/etc/hosts`)
- `LocalAuthentication` for password-gated unblocking
- Local JSON storage, macOS 13+
