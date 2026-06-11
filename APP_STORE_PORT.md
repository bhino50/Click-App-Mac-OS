# Click — Mac App Store Port Plan

Goal: ship Click on the Mac App Store (Klack-style keyboard sound app).
Verified 2026-06-10: the event tap is listen-only (KeyEventTap.swift,
`options: .listenOnly`), zero event-posting APIs in the codebase, so the app
is App Store eligible. Remaining blockers are certificates and App Store
Connect setup — all code work is DONE and verified (2026-06-11).

## Current state (verified 2026-06-11)

- Bundle ID `brandon.Click`, MARKETING_VERSION 1.0
- Permission flow uses Input Monitoring (`CGPreflightListenEventAccess` /
  `CGRequestListenEventAccess`, PermissionsManager.swift) — DONE
- `Click/Click.AppStore.entitlements`: app-sandbox + user-selected
  read-only (needed for Import pack open panel and drag-and-drop) — DONE
- Self-updater fully compiled out of MAS builds: UpdateChecker.swift and
  SemanticVersion.swift are wrapped in `#if !MAS_BUILD`, as are all usages
  (AppCoordinator, MenuBarView) and the DMG/Gatekeeper onboarding caption
  (PermissionsView) — DONE, verified via `nm` (zero updater symbols)
- `importPacks(from:)` claims security-scoped resource access so sandboxed
  drag-and-drop import works — DONE
- Stale `INFOPLIST_KEY_NSAccessibilityUsageDescription` removed from
  pbxproj (never landed in the built Info.plist; misleading) — DONE
- `./scripts/build_mas.sh` smoke build PASSES all checks: sandboxed,
  universal (x86_64 + arm64), no updater symbols, exact entitlements,
  LSUIElement set; app launches sandboxed and creates its container
- Developer ID 1.0 build already notarized and verified (dist/Click-1.0.dmg)
- Team VJPMCBH6NX, Apple ID beast5225@icloud.com, notary profile AC_NOTARY

## Step 1 — Code changes — DONE

All items landed; see "Current state" above.

## Step 2 — Verify sandbox locally — DONE (one manual check left)

```bash
./scripts/build_mas.sh        # builds + verifies, ad hoc signed
open build/MAS/Build/Products/Release/Click.app
```

Automated checks pass. One manual confirmation remains for Brandon: grant
Input Monitoring when prompted, type, confirm sounds play, and import a pack
via the Settings window (both the open panel and drag-and-drop). If the
listen-only tap ever misbehaves sandboxed, the fallback is
`NSEvent.addGlobalMonitorForEvents(matching: [.keyDown, .flagsChanged])`
in KeyEventTap (same Input Monitoring permission, sandbox-proven).

## Step 3 — Certificates and profile (browser, ~10 min)

Reuse the CSR flow from the FinderPath setup (openssl CSR → upload → import):
1. developer.apple.com → Certificates → create **Apple Distribution** AND
   **Mac Installer Distribution**; import both into the login keychain.
2. Identifiers → register App ID `brandon.Click` (exact match).
3. Profiles → new **Mac App Store** distribution profile for that App ID +
   the Apple Distribution cert → download `ClickMAS.provisionprofile`.

## Step 4 — App Store Connect (Brandon must do parts)

1. appstoreconnect.apple.com → complete **trader status** declaration
   (Business section) — REQUIRED before submission; legal, Brandon-only.
2. Apps → + → New App → platform macOS, bundle ID brandon.Click.
   NOTE: the name "Click" is almost certainly taken — have a backup name
   ("Click — Keyboard Sounds" or similar). Subtitle, category (Utilities or
   Music?), privacy labels: "Data Not Collected" (keystrokes never leave the
   process — true per KeyEventTap design comment).
3. Pricing: $0.99 = price point/tier 1 (Pricing and Availability → Price →
   pick the $0.99 USD price point; Apple maps other currencies). Undercuts
   Klack ($4.99). Requires the Paid Apps agreement: Business → Agreements →
   Paid Applications must be Active (bank + tax forms complete) BEFORE the
   app can be priced — start this early, bank verification can take days.
4. Screenshots (1280x800 or 2560x1600 min), description.

## Step 5 — Build, package, upload

```bash
SIGN_ID="Apple Distribution: Brandon Hinojosa (VJPMCBH6NX)" \
INSTALLER_ID="3rd Party Mac Developer Installer: Brandon Hinojosa (VJPMCBH6NX)" \
PROFILE=ClickMAS.provisionprofile \
  ./scripts/build_mas.sh store
```

Produces `build/Click-MAS.pkg`, fully verified (entitlements, universal,
no updater). Upload: Transporter.app (Mac App Store, free) — drag the pkg in.

## Step 6 — Submit

In App Store Connect select the uploaded build, add review notes:
"Click plays a sound on each keystroke. It requires Input Monitoring to
observe key-down events; it is listen-only (CGEventTap .listenOnly),
never records, stores, or transmits keystrokes." Submit. First review:
usually 1-3 days; expect one rejection round as a new account — respond,
resubmit.

## Gotchas

- Do NOT remove the Developer ID pipeline — keep both channels
  (package_release.sh stays as-is for direct downloads).
- The MAS build must not contain the updater or any "download" links to
  the website version (rejection risk: guideline 2.3.10 / 3.1.x).
- LSUIElement menu bar apps are fine on MAS, but onboarding must make the
  menu bar icon discoverable (already has Onboarding/).
- If the listen-only CGEventTap fails App Review automation checks, the
  NSEvent global monitor fallback (Step 2) is the proven path.
