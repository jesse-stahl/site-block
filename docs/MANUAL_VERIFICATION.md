# Manual Verification Guide — SiteBlock

SiteBlock's automated suite (`swift test`) covers all the pure logic: domain expansion
(www./subdomain handling), `/etc/hosts` managed-region rendering and atomic writes, the
friction state machine (cooldown → confirmation window → expiry), JSON persistence, and
the local blocked-page HTTP server.

What automated tests **cannot** cover — because they need code signing, a real logged-in
GUI session, and a live admin approval, none of which are available in headless CI — is
everything below. Run through this checklist manually on a real Mac before shipping or
after any change touching the helper, the hosts writer, or the friction timers.

## Prerequisites

- A real macOS 13+ machine, logged in with an admin account (or an account that can
  supply admin credentials when prompted).
- Xcode 26+ installed.
- Be ready to look at `/etc/hosts` in a terminal (`cat /etc/hosts`) at several points.

---

## 1. Open & build in Xcode

1. Open the project — `Package.swift` if SiteBlock is a Swift Package executable, or the
   `.xcodeproj`/`.xcworkspace` if one has been generated. (`open Package.swift` or
   `open SiteBlock.xcodeproj` from the repo root.)
2. In the scheme selector, choose the **SiteBlock** scheme (menu bar app target).
3. Press **Run** (⌘R). Confirm it builds without errors and a new icon appears in the
   menu bar (not the Dock — this is a `MenuBarExtra` app).
4. If code signing errors appear, set the target's Team under
   **Signing & Capabilities** to your personal Apple ID / development team and re-run.

## 2. First-launch helper registration (SMAppService admin approval)

This is the one-time gate that makes everything afterward password-free.

1. On first run, SiteBlock should register its privileged helper via `SMAppService`.
   Watch for a system prompt asking to approve a new login item / background helper.
2. Approve it when prompted. If no prompt appears, or you dismissed it:
   - Go to **System Settings → General → Login Items & Extensions**.
   - Look for SiteBlock (or its helper) under the relevant section and enable it.
3. Confirm in the app UI that it now reports the helper as active/authorized (however
   the app surfaces this — e.g. no "helper not installed" warning in the menu).
4. You should only ever see this approval **once**. Note that fact — if it reappears on
   every launch, that's a bug, not expected behavior.

## 3. Add a domain and toggle blocking ON (should be instant, no password)

1. Open the menu bar item, add a domain, e.g. `example.com`.
2. Toggle blocking **ON**.
3. Confirm both actions complete instantly with **no password prompt and no delay**.
4. Check `/etc/hosts` in a terminal and confirm `example.com` (and its usual variants)
   now resolve to `127.0.0.1` / `::1` inside the SiteBlock managed region (see §8 for the
   marker format).

## 4. Verify real blocking across browsers

With blocking ON and `example.com` added:

1. **Chrome** — visit `http://example.com` and `https://example.com`. Confirm both fail
   to load the real site.
2. **Firefox** — repeat the same two URLs.
3. **Safari** — repeat the same two URLs.
4. For the **http://** case in each browser: confirm you see SiteBlock's **custom local
   blocked page** (not a generic browser error).
5. For the **https://** case in each browser: confirm you see the **browser's own
   security warning** (e.g. "connection is not private" / "can't connect securely") —
   this is expected and documented, not a bug. The site is still fully blocked; SiteBlock
   just can't serve its custom page over HTTPS since it doesn't hold a cert for the
   domain.
6. Confirm `www.example.com` and 1–2 other common subdomains you'd expect to be covered
   are also blocked, in at least one browser.

## 5. Verify the gated "weaken" flow (unblock + domain removal)

This is the core safety mechanism — test it carefully.

### 5a. Turning blocking OFF

1. Click **Unblock**. Confirm blocking does **not** turn off immediately.
2. Confirm a **5-minute cooldown** countdown starts and is visible in the UI.
3. Try clicking Unblock again / any other action during the cooldown — confirm there is
   **no way to bypass it early**.
4. Wait for the cooldown to elapse. Confirm a **2-minute confirmation window** opens.
5. Within that window, click to confirm and **enter your Mac password**
   (LocalAuthentication prompt). Confirm blocking actually turns off and
   `example.com` resolves normally again in a browser.
6. Repeat, but this time let the **2-minute window expire without confirming**. Confirm
   the flow resets and you must start over from a fresh 5-minute cooldown.

### 5b. Removing a domain

1. Re-add `example.com` and re-enable blocking if needed.
2. Attempt to remove the domain. Confirm it goes through the **same** cooldown →
   confirmation-window → password flow as unblocking (not instant).
3. Confirm early-removal attempts during the cooldown are rejected, and that after
   password confirmation the domain is actually removed from `/etc/hosts` and the site
   resolves normally.

## 6. Verify timer reset on quit / restart

1. Add a domain, enable blocking, then click Unblock to start a 5-minute cooldown.
2. While the cooldown is still running, **quit the app** (⌘Q or from the menu).
3. Reopen SiteBlock. Confirm:
   - The pending unblock timer is **gone** (no countdown resumes, no confirmation window
     waiting).
   - Blocking is **still ON** — the site is still blocked.
4. Repeat, but this time **restart the Mac** instead of just quitting. Confirm the same
   result after logging back in: no leftover timer, blocking still on.

## 7. Verify launch-at-login and persistence across reboot

1. Confirm SiteBlock is configured to launch at login (check
   **System Settings → General → Login Items & Extensions**, or the app's own
   "launch at login" setting if it exposes one).
2. With blocking ON and at least one domain added, restart the Mac fully (not just log
   out).
3. Log back in and confirm:
   - SiteBlock's menu bar icon appears automatically without manually opening it.
   - The blocked domain is still unreachable in a browser immediately (blocking survives
     the reboot because it lives directly in `/etc/hosts`, independent of the app
     running).

## 8. Troubleshooting

**Helper not approved / blocking doesn't take effect:**
- Check **System Settings → General → Login Items & Extensions** for SiteBlock's
  helper and confirm it's enabled. If it's missing or disabled, remove and re-add it,
  or fully quit and relaunch SiteBlock to re-trigger the approval prompt.
- Confirm the app isn't running an ad-hoc/unsigned build with a mismatched bundle
  identifier from a previous approval — `SMAppService` ties approval to a specific
  signed bundle ID.

**Suspect leftover / stale `/etc/hosts` entries (e.g. after an uninstall or a crash):**
- Inspect the file directly: `cat /etc/hosts`.
- SiteBlock's writes are confined to a single managed region delimited by:
  ```
  # >>> SiteBlock managed block >>>
  ...entries...
  # <<< SiteBlock managed block <<<
  ```
- Anything between those two markers is safe to review/delete manually if the app is
  gone or misbehaving — everything outside the markers is untouched user/system config
  and should never be edited by hand as part of SiteBlock cleanup.
- To manually clear a stuck block: open `/etc/hosts` with `sudo`, delete the lines
  between (and including) the two marker comments, save, and flush DNS
  (`sudo dscacheutil -flushcache; sudo killall -HUP mDNSResponder`).
- To manually clear a stuck **app** block (the helper restores its set at boot, independent of
  the UI): `sudo rm "/Library/Application Support/SiteBlock/blockedapps.json"`, then restart the
  helper (`sudo launchctl kickstart -k system/today.siteblock.helper`) or reboot.

## 9. App blocking (Discord / Steam)

App blocking is enforced by the root helper polling the process table once a second, so
it can only be verified on a real Mac with the helper approved.

1. With blocking **off**, open the popover → **Add app…** → pick **Discord**, then **Steam**.
   Both appear in the list with their icons. Adding is instant (no prompt).
2. Launch Discord and leave it running. **Turn on blocking.** Within ~1–4 s Discord quits
   (polite quit first; force-kill after 3 s if it hangs). No notification banner and no
   attempt count for this — killing an already-running app on turn-on is silent.
3. Try to open Discord again. It appears briefly then closes within ~1 s. A banner
   "SiteBlock kept you focused — Blocked Discord for the first time." appears and the row
   shows `1×`. Relaunch a few times inside a minute: banners are rate-limited (one per
   minute per app) but the count keeps growing on the next stats refresh (≤5 s).
4. Launch Steam. Confirm `steam_osx` and all `Steam Helper` processes disappear
   (`ps aux | grep -i steam`), not just the bootstrapper.
5. Quit the SiteBlock menu bar app (Quit button). Launch Discord → it is still killed
   (the helper enforces independently). Relaunch SiteBlock; header still shows
   **Blocking on** (verified), row counts persisted.
6. Reboot. Discord/Steam auto-launch at login → killed within seconds, even before SiteBlock's
   UI reconciles (the helper restores its set from
   `/Library/Application Support/SiteBlock/blockedapps.json`).
7. Click the trash icon on Discord → "Removing Discord in 5:00" countdown; Cancel works;
   after 5 min a 2-min "Confirm — enter password" window appears; confirming prompts for the
   Mac password with reason "remove Discord from your block list"; afterwards Discord launches
   normally.
8. **Turn off blocking** (gated) → after confirming, both Discord and Steam launch normally and
   `blockedapps.json` contains `[]`.
9. Sanity: SiteBlock itself and Finder never appear in the **Add app…** menu.
