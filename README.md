# codex-app-intel

Tools to run Codex Desktop on Intel Macs.

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
4. Rebuilds native modules for Electron x64:
   - `better-sqlite3@12.4.6`
   - `node-pty@1.1.0`
5. Sets `BUILD_FLAVOR=dev` in `Info.plist` by default to skip Sparkle (`sparkle.node` in this bundle is arm64-only).
6. Optionally signs the app when `SIGN_APP=1`.

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
- `SKIP_NATIVE_REBUILD=1 ./scripts/repackage-intel.sh` (runtime-only swap)
- `KEEP_PROD_FLAVOR=1 ./scripts/repackage-intel.sh` (keeps Sparkle enabled; likely fails unless you provide x64 `sparkle.node`)
- `SIGN_APP=1 SIGN_IDENTITY=- ./scripts/repackage-intel.sh` (attempt ad-hoc signing; disabled by default)
