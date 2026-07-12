# Contributing to Click

Thanks for opening this up. A few notes to keep changes small and focused.

## Building

- Xcode 16+, macOS 14+ deployment target.
- Open `Click/Click.xcodeproj`, ⌘B.
- The project uses **Swift 6** with `default-isolation=MainActor`. Any
  shared-mutable state should be inside an `actor`; data types that flow
  across actor boundaries should be `nonisolated` and `Sendable`.

## Code style

- Files target 200–400 lines, 800 hard max.
- No comments that just restate code. Comments earn their place by
  explaining a non-obvious invariant or workaround.
- Lean on `os.Logger` (not `print`) for production diagnostics.

## Tests

- Use **Swift Testing** (`import Testing`, `@Test`, `#expect`).
- High-value targets: `MechvibesAdapter` (manifest parsing, single-file
  slicing), `KeyCodeMap` (mapping completeness), `SettingsStore`
  (persistence round-trip).

## Authoring a `.clickpack`

The procedural generator at `tools/generate_packs.py` is the reference for
the native format. To add a new bundled pack:

```bash
python3 tools/generate_packs.py        # regenerate the procedural packs
# or hand-author your own folder in Resources/DefaultPacks/
```

Bundled pack audio must be original (synthesized or recorded by the
contributor) — no scraped third-party samples.

## Mechvibes pack support

The adapter targets the two formats Mechvibes itself ships. If a pack in the
wild doesn't load, please open an issue with the `config.json` attached
(remove any audio if licensing is unclear).

## Releasing

1. Bump `MARKETING_VERSION` in every Click target configuration.
2. Run `scripts/release.sh` with both `DEVELOPER_ID` and `NOTARY_PROFILE`.
   It delegates to the canonical packager, derives the artifact version from
   `MARKETING_VERSION`, notarizes and validates the DMG itself, and updates the
   public manifest only after Gatekeeper accepts it.
3. Tag the release: `git tag v$VERSION && git push --tags`.
4. Attach the signed `.dmg` to the GitHub release.
5. Update the Homebrew cask formula.

For a clearly labeled local-only artifact, use `scripts/package_release.sh`
without credentials. See both scripts for the exact release gates.
