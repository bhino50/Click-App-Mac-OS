# Click — Build Plan & Status

An open-source, MIT-licensed macOS app that plays mechanical keyboard sounds as you type. Mechvibes-compatible sound packs, distributed via Homebrew Cask.

> Goal: a better Klack. Open sound pack format, per-key sample variation, low-latency playback.

**Status:** All 10 phases implemented. App builds clean, runs, plays real recorded Cherry MX switch audio on every keystroke.

---

## Stack (as built)

- **Platform:** macOS 14+ (SwiftUI `MenuBarExtra`, `SMAppService`)
- **Language:** Swift 6 with `default-isolation=MainActor`, `SWIFT_APPROACHABLE_CONCURRENCY=YES`
- **Audio:** `AVAudioEngine` + 16-node `AVAudioPlayerNode` pool; `AVAudioConverter` normalizes every pack to the engine's processing format at install time
- **Input:** `CGEvent.tapCreate(.cgSessionEventTap, .listenOnly)` on the main runloop, surfaced as `AsyncStream<KeyEvent>`
- **Sandbox:** **off** — `com.apple.security.app-sandbox=false`. Required by `CGEventTap`. Hardened runtime stays on.
- **Distribution:** `scripts/package_release.sh` creates clearly labeled local artifacts by default; `scripts/release.sh` requires explicit Developer ID and notary credentials and delegates to that canonical packager for public releases.
- **License:** MIT.

## What ships in the bundle

| Pack | Source | Type |
|------|--------|------|
| **CherryMX Blue - PBT keycaps** ⭐ default | mechvibes.com community pack | Real recording, single-file format |
| CherryMX Black - ABS keycaps | mechvibes.com | Real recording |
| CherryMX Brown - ABS keycaps | mechvibes.com | Real recording |
| CherryMX Red - ABS keycaps | mechvibes.com | Real recording |
| EG Crystal Purple | mechvibes.com | Real recording |
| NK Cream original by Ryan | mechvibes.com | Real recording, multi-file format |
| Click Light | `tools/generate_packs.py` | Procedural modal synthesis |
| Click Mech | `tools/generate_packs.py` | Procedural modal synthesis |

Built `.app` lives at `build/Click.app` (~40 MB with all packs).

---

## Phase 1 — Menu bar app shell ✅

- [x] Strip `ContentView` template content (deleted entirely)
- [x] `INFOPLIST_KEY_LSUIElement = YES` — no dock icon
- [x] `MenuBarExtra` with `.menuBarExtraStyle(.window)` (custom SwiftUI panel, not a plain NSMenu — lets us host the volume slider, pack picker, and test button)
- [x] `Window("Click Settings", id: "settings")` opened via `openWindow(id:)`
- [x] `LICENSE` (MIT) and `README.md` at repo root, plus `CONTRIBUTING.md`

**Done.** Menu bar icon (`keyboard.fill` / `keyboard`) reflects on/off state. Settings window is fully populated.

---

## Phase 2 — Accessibility permissions ✅

- [x] `PermissionsManager` (`@Observable`, `@MainActor`) wraps `AXIsProcessTrusted()` and `AXIsProcessTrustedWithOptions(prompt: true)`
- [x] Onboarding view: numbered steps, status badge, "Open System Settings" deep-link to `x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility`
- [x] `AppCoordinator.startPermissionsPolling()` polls `AXIsProcessTrusted` every second after launch; logs every 10th tick and on every state change
- [x] Event tap install gated behind granted permission; bootstrap fires `requestPrompt()` on first launch so macOS surfaces a fresh TCC entry that matches the current build's code hash

**Done.** Live status badge updates within ~1s of the user flipping the toggle.

---

## Phase 3 — Global keyboard event tap ✅

- [x] `KeyEventTap` (`@MainActor`) wraps `CGEvent.tapCreate` with `.cgSessionEventTap`, `.headInsertEventTap`, `.listenOnly`
- [x] C callback yields `KeyEvent(keyCode, timestamp)` into an `AsyncStream` via `MainActor.assumeIsolated`
- [x] Pass-through (`.listenOnly`) — never consumes events
- [x] Callback re-enables the tap on `.tapDisabledByTimeout` / `.tapDisabledByUserInput`
- [x] Coordinator's `stopEventTap()` lets the master toggle pull the tap

**Done.** Tap runs on the main runloop; callback is constant-time so it doesn't impact UI responsiveness.

---

## Phase 4 — Audio engine ✅

- [x] `AudioEngine` is an `actor` wrapping `AVAudioEngine`
- [x] `PlayerNodePool` (16 `AVAudioPlayerNode`s) attached to `mainMixerNode` at the engine's processing format
- [x] Round-robin node picker (`next()`); no allocation during playback
- [x] Samples are pre-decoded to `AVAudioPCMBuffer` at pack load
- [x] `play(keyCode:volume:)` schedules with `.interrupts`, fire-and-forget completion handler
- [x] End-to-end latency validated by playback; engine startup logs sample rate + channel count

**Done.** Format-mismatch crash (the v1 bug) is fixed by running every buffer through `AVAudioConverter.convert(to:)` during `installPack`.

---

## Phase 5 — Native `.clickpack` format ✅

```text
MyPack.clickpack/
├── manifest.json
└── audio/
    ├── default-1.wav … default-5.wav
    ├── space-1.wav, space-2.wav, space-3.wav
    ├── enter.wav, backspace.wav, tab.wav
    └── …
```

`manifest.json`:

```json
{
  "name": "Click Mech",
  "author": "Click",
  "version": "1.1.0",
  "defaultSound": "audio/default-1.wav",
  "keyMap": {
    "49": ["audio/space-1.wav", "audio/space-2.wav", "audio/space-3.wav"],
    "36": ["audio/enter.wav"],
    "0":  ["audio/default-1.wav", …]
  }
}
```

- [x] `ClickPackManifest` Codable struct (`nonisolated`, `Sendable`)
- [x] `SoundPack` (class, `@unchecked Sendable`) with `samplesByKeyCode: [Int64: [AVAudioPCMBuffer]]` and a `defaultSamples` bucket; `sample(for:)` picks at random with `SystemRandomNumberGenerator`
- [x] `SoundPackLoader` (`actor`) scans `Bundle.main.resourceURL?/DefaultPacks/` and `~/Library/Application Support/Click/SoundPacks/`
- [x] Bundled packs ship inside `Click.app/Contents/Resources/DefaultPacks/` (folder reference in the pbxproj — synced source folders flatten on copy, hence the explicit folder reference)
- [x] Per-key arrays drive random per-keystroke variation (5 default variants per built-in pack)

**Done.** Hot-swap is instant — `selectPack(handle:)` reloads + reinstalls.

---

## Phase 6 — Mechvibes compatibility ✅

`MechvibesAdapter` handles both formats:

1. **Single-file**: `config.json` + one audio file + `defines: { "<mvCode>": [startMs, durationMs] }` → slice the source buffer per range.
2. **Multi-file**: `config.json` + many files + `defines: { "<mvCode>": "file.wav" }` → load each referenced file as a buffer.

- [x] Format detection by `key_define_type` ("single" vs anything else)
- [x] `KeyCodeMap.mechvibesToMac` translates Windows scan codes (~75 keys) to macOS virtual keycodes (kVK_*)
- [x] Single-file slicing: copies float32 or int16 channel data into a new `AVAudioPCMBuffer` at the requested frame range
- [x] **OGG transcoding**: AVFoundation doesn't read Ogg Vorbis; `tools/prepare_packs.py` runs each downloaded pack through `ffmpeg` and rewrites the manifest to point at `.wav` before the pack lands in `Resources/DefaultPacks/`
- [x] Once translated, the rest of the app stays format-agnostic — the internal model is always `SoundPack`

**Done.** All six bundled Mechvibes packs (Black/Blue/Brown/Red Cherry MX, NK Cream, EG Crystal Purple) load and play correctly.

---

## Phase 7 — Settings UI ✅

Two surfaces:

**Menu bar panel** (`.menuBarExtraStyle(.window)`) — quick-access controls:
- Master on/off toggle with live status text
- Volume slider (0–100%) with live readout
- "Test sound" button (plays the default sample — verifies audio path without needing Accessibility)
- Sound pack `Picker`
- "Grant Accessibility…" button when trust missing
- Settings… (⌘,) and Quit Click (⌘Q)

**Settings window**:
- Pack grid (`PackPickerView`) with selection highlight
- Volume slider, master toggle, velocity toggle, visual-feedback toggle, launch-at-login toggle (via `SMAppService.mainApp`)
- "Import pack…" button (`NSOpenPanel`) and drag-and-drop onto the window
- "Reveal folder" → `~/Library/Application Support/Click/SoundPacks/`
- Muted-apps text area (one bundle ID per line)
- About row with version + license

`SettingsStore` (`@Observable`) persists everything via `UserDefaults`. Non-sensitive only.

---

## Phase 8 — Pack import ✅

- [x] `SoundPackLoader.importPack(at:)` validates that the source folder is a recognized pack (manifest or config + mechvibes structure), copies into the user packs directory, replacing any existing pack with the same folder name
- [x] `NSOpenPanel`-backed "Import pack…" button accepts files or directories, multiple selection
- [x] Drag-and-drop on the Settings window via `.onDrop(of: [.fileURL])`
- [x] `PackFolderWatcher` (`actor`) uses `DispatchSource.makeFileSystemObjectSource` on the user packs directory; coordinator re-runs discovery on every change
- [x] Errors surface inline in the Settings window (`coordinator.loadError`)

**Done.** Drop a Mechvibes pack folder from Finder and it shows up in the picker without restarting Click.

---

## Phase 9 — Polish ✅

- [x] **Per-key sample variation**: `SoundPack.sample(for:)` random-picks across the bucket; built-in packs ship 5 default variants
- [x] **Velocity sensitivity**: `AppCoordinator.velocityScalar(for:)` measures inter-keystroke interval via `MachClock.nanoseconds(between:and:)`. Faster typing ≈ 1.0, idle ≥ 1s ≈ 0.7. Toggleable in Settings.
- [x] **Visual press feedback**: `KeyFeedbackOverlay` window watches `lastPressedKey` / `lastPressAt`, renders a capsule glyph that fades out after 320 ms. Toggleable.
- [x] **Per-app rules**: `SettingsStore.allowedAppPolicyMatches(frontmostBundleID:)` consults the muted-bundle list before playback. Coordinator reads `NSWorkspace.shared.frontmostApplication?.bundleIdentifier` on each event.
- [x] App icon + accent color use Xcode's generated symbol set (`ASSETCATALOG_COMPILER_APPICON_NAME = AppIcon`, `ASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME = AccentColor`).

---

## Phase 10 — Release ✅ (scripted; one-shot pending real Developer ID)

- [x] Repo layout finalized: `LICENSE`, `README.md`, `CONTRIBUTING.md`, `BUILD.md` (this file)
- [x] 8 bundled packs (6 Mechvibes-derived + 2 procedural) — all original or community-licensed; no scraped IP
- [x] `scripts/release.sh` delegates to the fail-closed package pipeline: build/sign/notarize/staple/assess app → build/sign/notarize/staple/assess DMG → promote public filenames/update manifest
- [ ] **Pending the user**: install Developer ID cert + `xcrun notarytool store-credentials AC_NOTARY ...`, then run `./scripts/release.sh`
- [ ] **Pending the user**: cut a public GitHub release with the notarized `.dmg`
- [ ] **Pending the user**: publish a Homebrew Cask formula pointing at that release

For local everyday use the ad-hoc signed build at `build/Click.app` works without any of the above.

---

## File layout (actual)

```text
Click/                                              # repo root
├── BUILD.md, README.md, CONTRIBUTING.md, LICENSE
├── Click.xcodeproj/
├── Click/                                          # synced source folder
│   ├── ClickApp.swift                              # @main + scenes
│   ├── Click.entitlements                          # app-sandbox=false
│   ├── App/
│   │   ├── AppDelegate.swift                       # bootstraps coordinator on launch
│   │   ├── AppCoordinator.swift                    # owns everything; bridges keystroke → playback
│   │   ├── MenuBarView.swift                       # .window-style menu panel
│   │   ├── MachClock.swift                         # mach_absolute_time → nanoseconds
│   │   └── KeyFeedbackOverlay.swift                # visual press feedback
│   ├── Input/
│   │   ├── PermissionsManager.swift                # AXIsProcessTrusted wrapper
│   │   └── KeyEventTap.swift                       # CGEventTap on the main runloop
│   ├── Audio/
│   │   ├── AudioEngine.swift                       # actor; AVAudioEngine + pool
│   │   └── PlayerNodePool.swift                    # 16-node round-robin
│   ├── Packs/
│   │   ├── ClickPackManifest.swift
│   │   ├── SoundPack.swift                         # converted(to:) handles fmt mismatch
│   │   ├── SoundPackLoader.swift                   # discover + load + import
│   │   ├── MechvibesAdapter.swift                  # single + multi parsing
│   │   ├── KeyCodeMap.swift                        # Mechvibes → macOS vKeycodes
│   │   └── PackFolderWatcher.swift                 # kqueue-backed folder watch
│   ├── Settings/
│   │   ├── SettingsStore.swift                     # @Observable, UserDefaults-backed
│   │   ├── SettingsView.swift
│   │   ├── PackPickerView.swift
│   │   └── LaunchAtLogin.swift                     # SMAppService wrapper
│   ├── Onboarding/
│   │   └── PermissionsView.swift                   # first-run accessibility flow
│   └── Models/
│       └── KeyEvent.swift                          # Sendable struct (nonisolated)
├── Resources/
│   └── DefaultPacks/                               # folder reference → bundled into .app
│       ├── CherryMX Black - ABS keycaps.clickpack/
│       ├── CherryMX Blue - PBT keycaps.clickpack/
│       ├── CherryMX Brown - ABS keycaps.clickpack/
│       ├── CherryMX Red - ABS keycaps.clickpack/
│       ├── Click Light.clickpack/
│       ├── Click Mech.clickpack/
│       ├── EG Crystal Purple.clickpack/
│       └── NK Cream original by Ryan.clickpack/
├── tools/
│   ├── generate_packs.py                           # procedural modal synthesis
│   └── prepare_packs.py                            # download + transcode Mechvibes packs
├── scripts/
│   ├── package_release.sh                          # canonical local/public packager
│   └── release.sh                                  # strict public-release wrapper
└── build/                                          # gitignored
    ├── DerivedData/                                # Xcode build products
    ├── pack-downloads/                             # zip cache for prepare_packs.py
    └── Click.app                                   # latest ad-hoc-signed build
```

~1,800 lines of Swift across 19 source files. Most files stay well under 200 lines; the coordinator is the largest at ~200.

---

## Testing strategy (as built)

- **Manual QA** through the menu bar's "Test sound" button verifies the audio path end-to-end without needing Accessibility — useful when iterating because each rebuild requires a fresh TCC grant.
- Live `os.Logger` instrumentation under subsystem `brandon.Click`: `audio`, `coordinator`, `eventtap`, `settings`. Stream with `log stream --predicate 'subsystem == "brandon.Click"' --info`.
- No XCTest/Swift-Testing target yet — Phase-10 stretch goal. Per BUILD.md's intent, the audio engine resists meaningful unit testing without a real device, so the highest-leverage future tests are: manifest parsing, Mechvibes adapter (slice + multi-file), keycode mapping, settings persistence.

---

## Build commands

```bash
# Local debug build (Xcode UI: ⌘B)
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcodebuild -project Click.xcodeproj -scheme Click -configuration Debug build

# Local ad-hoc release used by build/Click.app
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild \
  -project Click.xcodeproj -scheme Click -configuration Release \
  -derivedDataPath build/DerivedData \
  CODE_SIGN_IDENTITY="-" CODE_SIGNING_REQUIRED=NO build

# Regenerate procedural packs
python3 tools/generate_packs.py

# Refresh the bundled Mechvibes packs from downloads in build/pack-downloads/
python3 tools/prepare_packs.py

# Full notarized release pipeline (needs Developer ID + notary profile)
DEVELOPER_ID="Developer ID Application: Your Name (TEAMID)" \
NOTARY_PROFILE="AC_NOTARY" \
  ./scripts/release.sh
```

---

## Known issues & gotchas

- **TCC re-grant on every rebuild.** Ad-hoc signed rebuilds get a new code hash, so the existing "Click" entry in System Settings → Privacy & Security → Accessibility no longer applies. Workaround: toggle Click off then on, or remove the entry with `−` and let the next launch trigger `AXIsProcessTrustedWithOptions(prompt: true)`. This goes away once the app ships with a stable Developer ID signature.
- **Stale sandbox container.** The very first build had `ENABLE_APP_SANDBOX = YES`; once macOS creates `~/Library/Containers/brandon.Click/`, some preference reads keep going through the container even after sandbox is disabled. If pack selection seems "stuck", delete `~/Library/Preferences/brandon.Click.plist` and (if it still exists) `~/Library/Containers/brandon.Click/`.
- **OGG support.** AVFoundation on macOS doesn't decode Ogg Vorbis. `prepare_packs.py` transcodes via `ffmpeg` at install time; the in-app importer copies packs verbatim, so Mechvibes packs the user installs at runtime via drag-and-drop need to be pre-transcoded or in WAV/AIFF already. (Future: detect OGG on import and transcode in-process.)
- **macOS 15-only window styles.** `windowStyle(.plain)` and `windowLevel(.floating)` were nice-to-have for the visual feedback overlay but are 15.0+ only, so the overlay uses a standard Window. Bump deployment target to 15.0 if those become important.

---

## Open questions to revisit

- Per-app rules expose a raw bundle-ID text editor today. A picker that lets the user click an app from `NSWorkspace.shared.runningApplications` would be nicer.
- Pack signing / trust model — packs run in-process; do we want any sandboxing of audio file reads? Likely overkill for v1.
- iCloud sync for settings + pack library — nice-to-have, not v1.
- A test target — Swift Testing for the deterministic modules (`MechvibesAdapter`, `KeyCodeMap`, `SettingsStore` round-trip, manifest decoding).
