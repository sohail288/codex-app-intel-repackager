# codex-app-intel

Tools to run Codex Desktop on Intel Macs.

## NOTICE

Current repacked builds are not notarized. On first launch, macOS may show a warning such as
"malicious software cannot be examined" or "cannot be opened because Apple cannot check it for malicious software."

If this appears, open the app once via:

1. Finder -> right click `Codex-intel.app`
2. Click `Open`
3. Confirm `Open` in the prompt

After this one-time approval, normal launches should work.

## Problem

The bundled app is arm64-only:

- `Codex.app/Contents/MacOS/Codex`
- `Codex.app/Contents/Resources/codex`

Intel Macs (`x86_64`) cannot execute those binaries.

## Option 1: launcher wrapper

Use `./codex-app` to:

1. Detect host architecture.
2. On Apple Silicon, launch bundled `Codex.app`.
3. On Intel, prefer an installed Intel-capable app.
4. Fallback to `codex app <workspace>`.
5. Optional DMG install fallback.

Env vars:

- `CODEX_APP_WORKSPACE` (default: current directory)
- `CODEX_APP_DMG_URL`
- `CODEX_APP_AUTO_INSTALL=0|1` (default: `1`)

## Option 2: true Intel repack

Use `scripts/repackage-intel.sh` to build an Intel app bundle.

What it does:

1. Copies `Codex.app` to `Codex-intel.app`.
2. Downloads Electron `darwin-x64` runtime matching bundled Electron version.
3. Replaces runtime binaries/framework inside app bundle.
4. Inspects the upstream app bundle and derives the exact Electron/native-module versions from the shipped artifact.
5. Rebuilds the upstream app's native modules for Electron x64 using those discovered versions instead of repo-pinned guesses.
5. Replaces bundled helper binaries that remain arm64-only, including `Contents/Resources/rg`.
6. Rebuilds an Intel `sparkle.node` addon when Sparkle is kept enabled.
7. Defaults to `BUILD_FLAVOR=dev` only when no GitHub-release Sparkle config is provided.
8. Optionally signs the app when `SIGN_APP=1`.

### Repack command

```bash
./scripts/repackage-intel.sh
```

Output:

- `Codex-intel.app`

### Repack prerequisites

- macOS with Xcode Command Line Tools
- `node`/`npm`
- `curl`, `unzip`, `codesign`, `lipo`
- Network access to:
  - `github.com/electron/electron` (runtime zip)
  - npm registry (native module rebuild)

### Useful overrides

- `ELECTRON_VERSION=40.0.0 ./scripts/repackage-intel.sh`
- `INSPECT_ONLY=1 ./scripts/repackage-intel.sh Codex.app` (print discovered upstream metadata JSON and exit)
- `SKIP_NATIVE_REBUILD=1 ./scripts/repackage-intel.sh` (runtime-only swap)
- `KEEP_PROD_FLAVOR=1 ./scripts/repackage-intel.sh` (keeps Sparkle enabled and rebuilds the Intel updater bridge)
- `SIGN_APP=1 SIGN_IDENTITY=- ./scripts/repackage-intel.sh` (attempt ad-hoc signing; disabled by default)
- `RG_X64_BINARY=/usr/local/bin/rg ./scripts/repackage-intel.sh` (use a specific Intel ripgrep binary)
- `RIPGREP_VERSION=15.1.0 ./scripts/repackage-intel.sh` (override the default pinned ripgrep version used for x64 replacement)
- `SPARKLE_FEED_URL=https://github.com/<owner>/<repo>/releases/download/codex-intel-latest/appcast.xml SPARKLE_PUBLIC_ED_KEY=<public-key> ./scripts/repackage-intel.sh` (enable GitHub Releases auto-update for the repacked app)

## GitHub Action automation

This repo includes `.github/workflows/release-intel.yml` to auto-publish Intel builds.

Behavior:

1. Reads upstream app metadata from `appcast.xml` using `scripts/check_upstream.py`.
2. Computes a tag: `codex-intel-v<short_version>-<build_version>`.
3. Skips if that release tag already exists.
4. If missing, downloads upstream DMG, repacks Intel app, and publishes release assets:
   - `Codex-intel-<short_version>-<build_version>.zip`
   - `Codex-intel-<short_version>-<build_version>.sha256`

Triggers:

- Scheduled every 6 hours.
- Manual run (`workflow_dispatch`), with optional:
  - `force=true` to publish even if tag exists
  - `cleanup=false` to skip deleting old releases
  - `keep_releases=<N>` to retain N versioned releases

Additional release behavior:

- Maintains a moving tag/release: `codex-intel-latest`
- Keeps stable latest assets on `codex-intel-latest`:
  - `Codex-intel-latest.zip`
  - `Codex-intel-latest.sha256`
  - `appcast.xml` (when Sparkle secrets are configured)
- Cleans up old versioned tags/releases (default keep: `10`)
- To enable GitHub Releases auto-update in published builds, configure these repository secrets:
  - `SPARKLE_PUBLIC_ED_KEY`
  - `SPARKLE_PRIVATE_KEY`
- Without those secrets, the workflow still publishes Intel builds but keeps the previous dev-flavor/no-updater fallback.
