# Click Mac App Store Submission

Status (2026-06-11): build upload path complete. Apple Distribution and
Mac Installer Distribution certificates created and installed in the login
keychain. `ClickMAS.provisionprofile` (App Store, brandon.Click, expires
2027-06-11) generated and saved at the repo root. `build/Click-MAS.pkg`
built, signed, verified, and uploaded via `altool` with the App Store
Connect API key `6JCQQ53XK8` (issuer `4c49942c-0cdb-4979-b577-725ac2f014a3`,
key file `~/.appstoreconnect/private_keys/AuthKey_6JCQQ53XK8.p8`).
App record "Click Keys" (Apple ID 6779320750) already exists with an
in-flight macOS version. Remaining: attach the processed build to the
version, finish trader status / Paid Apps agreement, submit for review.

## App Record

- Platform: macOS
- Bundle ID: `brandon.Click`
- SKU: `click-macos-1`
- Name: `Click Keys - Keyboard Sounds`
- Primary category: Utilities
- Price: USD $0.99 price point
- Privacy: Data Not Collected

## Listing Copy

Subtitle:

Mechanical keyboard sounds for your Mac.

Promotional text:

Click adds low-latency keyboard sound feedback to your Mac from a quiet menu
bar app.

Description:

Click plays crisp keyboard sounds as you type, with per-key variation and
simple sound pack controls from the macOS menu bar.

Choose between bundled Click Light and Click Mech packs, import compatible
sound packs, adjust volume, mute specific apps, and keep the app tucked away
without a Dock icon.

Click requires Input Monitoring so it can observe key-down events globally.
Events are listen-only. Keystrokes are never recorded, stored, or transmitted.

Keywords:

keyboard,typing,sounds,mechanical,click,menu bar,sound pack,productivity

Support URL:

https://github.com/bhino50/click

Review notes:

Click plays a sound on each keystroke. It requires Input Monitoring to observe
key-down events globally. The event tap is listen-only (`CGEventTap`
`.listenOnly`) and the app never records, stores, or transmits keystrokes.

## Required Apple Portal Steps

1. Complete trader status and Paid Applications agreement in App Store Connect.
2. Create a macOS app record using bundle ID `brandon.Click`.
3. Set pricing to the USD $0.99 price point.
4. In Apple Developer, create these certificates from the prepared CSRs:
   - Apple Distribution:
     `/Users/brandon/Projects/Mac Apps/.signing/Apple_Distribution.certSigningRequest`
   - Mac Installer Distribution:
     `/Users/brandon/Projects/Mac Apps/.signing/Mac_Installer_Distribution.certSigningRequest`
5. Register App ID `brandon.Click`.
6. Create a Mac App Store provisioning profile for `brandon.Click`, download it
   as `ClickMAS.provisionprofile`, and place it in this repo root.

## Store Package Command

After the certificates and profile are installed:

```bash
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer \
SIGN_ID="Apple Distribution: Brandon Hinojosa (VJPMCBH6NX)" \
INSTALLER_ID="3rd Party Mac Developer Installer: Brandon Hinojosa (VJPMCBH6NX)" \
PROFILE=ClickMAS.provisionprofile \
  ./scripts/build_mas.sh store
```

The expected upload artifact is:

```text
build/Click-MAS.pkg
```
