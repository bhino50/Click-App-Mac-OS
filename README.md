# Click

An open-source macOS app that plays mechanical keyboard sounds as you type.
Mechvibes-compatible sound packs, low-latency playback, MIT licensed.

> A better Klack. Open sound pack format. Per-key sample variation. Velocity sensitivity. No subscriptions, no telemetry.

## Features

- **Lives in your menu bar.** No dock icon, no chrome. Toggle on/off in one click.
- **Bring your own sounds.** Drag any Mechvibes pack onto the settings window — both classic `config.json` variants are supported. Or author your own with the simple `.clickpack` format below.
- **Per-key variation.** Multiple samples per keycode are picked at random per keystroke so the rhythm of typing never gets robotic.
- **Velocity sensitive.** Faster typing modulates volume slightly — it actually feels like a keyboard.
- **Per-app muting.** Quiet Click for specific apps (games, screen recorders).
- **Launch at login**, accessibility deeplink onboarding, hot reload of new packs, optional on-screen key preview.

## Install

### Download (recommended)

Download the latest `.dmg` from [Releases](https://github.com/bhino50/Click-App-Mac-OS/releases), open it, and drag `Click.app` to `/Applications`. The DMG includes **Install First — Read Me.txt** with step-by-step first-launch instructions.

The public DMG is Developer ID signed and Apple-notarized, so it should open
normally. Local development artifacts are explicitly named
`NOT-FOR-PUBLIC-RELEASE`; macOS may block those test copies:

- **macOS 13–14:** right-click `Click.app` → **Open**, then confirm **Open**
- **macOS 15+:** double-click once (blocked), then **System Settings → Privacy & Security → Open Anyway**

After launch, a welcome window walks you through **Accessibility** access (required for global keystrokes — never stored or transmitted). Reopen it anytime from the menu bar → **Setup Guide…**

### Build from source

Requires Xcode 16+ and macOS 14+.

```bash
git clone https://github.com/bhino50/Click-App-Mac-OS.git
cd Click-App-Mac-OS
open Click.xcodeproj
# ⌘B to build, ⌘R to run.
```

### Package a local-only DMG (no Developer ID)

```bash
./scripts/package_release.sh
```

The local artifact is unmistakably named `ADHOC-LOCAL-ONLY-NOT-FOR-PUBLIC-RELEASE`
and does not change the public update manifest. For a public release, use the
strict entry point with both credentials explicitly set:

```bash
DEVELOPER_ID="Developer ID Application: Your Name (TEAMID)" \
NOTARY_PROFILE="AC_NOTARY" \
./scripts/release.sh
```

Only after the DMG itself passes notarization, stapling, signature validation,
and Gatekeeper does the script emit `Click-$VERSION.dmg` and update
`download-site/version.json`.

## The `.clickpack` format

A `.clickpack` is a folder. Inside, a `manifest.json` describes the pack and
the audio files live in an `audio/` subfolder:

```text
MyPack.clickpack/
├── manifest.json
└── audio/
    ├── default-1.wav
    ├── default-2.wav
    ├── space.wav
    └── enter.wav
```

```json
{
  "name": "Cream",
  "author": "Brandon",
  "version": "1.0.0",
  "defaultSound": "audio/default-1.wav",
  "keyMap": {
    "49": ["audio/space.wav"],
    "36": ["audio/enter.wav"],
    "0":  ["audio/default-1.wav", "audio/default-2.wav"]
  }
}
```

- Keys are macOS virtual keycodes (kVK_*). See
  [`KeyCodeMap.swift`](Click/Click/Packs/KeyCodeMap.swift) for the table.
- Any keycode whose value is a list of more than one file gets random
  selection per keystroke for variation.
- Drop a pack folder into `~/Library/Application Support/Click/SoundPacks/`
  or drag-and-drop onto the settings window.

## Mechvibes compatibility

Mechvibes ships two pack formats:

1. **Multi-file**: `config.json` plus a folder of per-key audio files, with
   `defines: { "<mvKeycode>": "file.ogg" }`.
2. **Single-file**: `config.json` plus one long audio file, with
   `key_define_type: "single"`, `sound: "<file>"`, and
   `defines: { "<mvKeycode>": [startMs, durationMs] }`.

Both work in Click. The bundled adapter translates Mechvibes keycodes
(Windows scan codes) to macOS virtual keycodes at load time, so the rest of
the app stays format-agnostic.

## Project layout

```text
Click/
├── Click/
│   ├── ClickApp.swift            # SwiftUI app entry, MenuBarExtra
│   ├── Click.entitlements        # Sandbox off (required for CGEventTap)
│   ├── App/                      # Coordinator, menu bar view, overlay
│   ├── Input/                    # PermissionsManager, KeyEventTap
│   ├── Audio/                    # AudioEngine, PlayerNodePool
│   ├── Packs/                    # Manifest decoder, loader, Mechvibes adapter
│   ├── Settings/                 # SettingsStore, settings UI
│   └── Onboarding/               # First-run permissions flow
├── Resources/DefaultPacks/       # Bundled sample packs (folder reference)
└── tools/generate_packs.py       # Procedural pack generator
```

## License

MIT. See [LICENSE](LICENSE).

The bundled "Click Light" and "Click Mech" sample packs are synthesized
procedurally — no scraped or copyrighted audio.
