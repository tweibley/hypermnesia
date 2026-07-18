# Packaging & Distribution

Hypermnesia ships as a macOS `.app` plus the `hypermnesia` CLI. Two build scripts:

| Script | Use |
|--------|-----|
| `Scripts/make-app.sh [debug\|release]` | Fast dev bundle (ad-hoc signed). For your own machine. |
| `Scripts/release.sh` | Universal build + bundled CLI + hardened-runtime signing + optional notarization → a cask-ready zip. |

## Local use (any machine you control)

```bash
bash Scripts/release.sh
open Hypermnesia.app
```

`release.sh` signs with the best identity it finds (`Developer ID Application` → `Apple Development`
→ ad-hoc). An Apple Development signature is enough to run it yourself without Gatekeeper friction,
but **macOS will block it on other people's machines** — that needs notarization (below).

## Distributing to others (notarized)

Notarization requires a **Developer ID Application** certificate (paid Apple Developer Program), which
is different from the "Apple Development" cert used for local builds.

1. **Get a Developer ID Application certificate** (Apple Developer account → Certificates) and install
   it in your login keychain. Confirm with:
   ```bash
   security find-identity -v -p codesigning | grep "Developer ID Application"
   ```
2. **Store notarytool credentials once** as a keychain profile. Using an App Store Connect API key
   (create one under App Store Connect → Users and Access → Integrations):
   ```bash
   xcrun notarytool store-credentials hypermnesia-notary \
     --key /path/to/AuthKey_XXXX.p8 --key-id <KEY_ID> --issuer <ISSUER_UUID>
   ```
   (Or `--apple-id <email> --team-id <TEAMID> --password <app-specific-password>`.)
3. **Build, sign, notarize, staple** in one shot:
   ```bash
   NOTARY_PROFILE=hypermnesia-notary bash Scripts/release.sh
   ```
   The script zips the app, submits with `notarytool --wait`, and `stapler staple`s the ticket on
   success. It then writes a versioned, cask-ready `dist/Hypermnesia-<version>.zip` and prints its
   `sha256`. The result is double-click-distributable.

## Auto-update (Sparkle)

Direct-download installs keep themselves current via [Sparkle](https://sparkle-project.org): the app
checks `https://github.com/tweibley/hypermnesia/releases/latest/download/appcast.xml` (a signed feed
`release.sh` writes to `dist/appcast.xml` and the release workflow uploads as a release asset).
Homebrew users can keep using `brew upgrade`; both channels serve the same zip.

How the pieces fit:

- **Public key** — committed at `packaging/sparkle-public-ed-key.txt`; `release.sh` stamps it into
  Info.plist as `SUPublicEDKey` along with `SUFeedURL`. If the file is missing, the app ships with
  the updater dormant (menu items hide themselves) and the release still succeeds.
- **Private key** — lives in the release-signing Mac's Keychain (created by Sparkle's
  `generate_keys`, found under `.build/artifacts/sparkle/Sparkle/bin/` after `swift package
  resolve`). CI signs with the `SPARKLE_ED_PRIVATE_KEY` repo secret instead: export with
  `generate_keys -x key.txt`, `gh secret set SPARKLE_ED_PRIVATE_KEY < key.txt`, delete `key.txt`.
- **Signing order** — Sparkle's nested executables (XPC services, `Autoupdate`, `Updater.app`, the
  framework) are hardened-runtime signed individually before the app, per Sparkle's notarization
  docs; `--deep` is never used.
- **Versioning** — `CFBundleVersion` is set to the marketing version, and the appcast's
  `sparkle:version` matches it, so Sparkle's standard comparator just compares release numbers.

## Homebrew cask

The friendliest install for end users is `brew install --cask tweibley/tap/hypermnesia`. A cask
serves a **prebuilt, notarized** zip (the one `release.sh` produces) from a GitHub Release, and the
bundled `hypermnesia` CLI is symlinked onto `PATH` automatically. Full setup — creating the tap,
cutting releases, and the CI workflow that automates it — is in
[`packaging/homebrew/README.md`](../packaging/homebrew/README.md); the cask itself is
[`packaging/homebrew/hypermnesia.rb`](../packaging/homebrew/hypermnesia.rb).

## Notes

- The app is **not sandboxed** (it reads `~/.claude`, runs `git`/`claude` subprocesses) — fine for
  Developer ID distribution; only the Mac App Store requires sandboxing.
- Hardened runtime needs `com.apple.security.automation.apple-events` (see
  `packaging/Hypermnesia.entitlements`) so notch click-back can focus terminal/IDE tabs. Outbound
  HTTPS (Gemini) and spawning subprocesses are allowed by default.
- The CLI (`hypermnesia`) is **bundled inside the app** at `Contents/Resources/hypermnesia`, so the
  cask can symlink it onto `PATH` with one artifact. For a from-source (non-cask) install, symlink
  `~/.local/bin/hypermnesia` to `.build/release/hypermnesia` instead.
- `release.sh` builds a **universal** binary (arm64 + x86_64) by default so one cask covers both
  Apple Silicon and Intel. Set `UNIVERSAL=0` for a faster native-only local build.
