# codex-app-intel

Scripts and GitHub Actions workflow for repackaging Codex Desktop so it runs on Intel Macs.

## Notice

Published Intel builds are not notarized. On first launch, macOS may show a warning such as
"Apple cannot check it for malicious software." Open the app once from Finder with right click
-> `Open` to allow future launches.

## What This Repo Does

- Repackages `Codex.app` into `Codex-intel.app` with an Intel Electron runtime.
- Inspects the upstream bundle and derives the Electron version, native module versions, and node-pty ABI suffix from the shipped app.
- Rebuilds the upstream native modules for Intel and replaces bundled Intel-sensitive binaries such as `codex` and `rg`.
- Publishes versioned Intel releases and maintains the moving `codex-intel-latest` release and appcast.

## Local Repack

Run:

```bash
./scripts/repackage-intel.sh [Codex.app] [Codex-intel.app]
```

Key behavior:

- Produces `Codex-intel.app`.
- Supports `INSPECT_ONLY=1` to print discovered upstream metadata and exit.
- Uses the Sparkle-enabled path when `SPARKLE_FEED_URL` and `SPARKLE_PUBLIC_ED_KEY` are set.
- Uses the dev/no-updater path when those Sparkle settings are absent.

Prerequisites:

- macOS with Xcode Command Line Tools
- `node` and `npm`
- `curl`, `unzip`, `codesign`, `lipo`
- network access to GitHub and the npm registry

Useful overrides:

- `WORK_DIR=/tmp/codex-intel-build ./scripts/repackage-intel.sh`
- `ELECTRON_ZIP=/path/to/electron-v41.2.0-darwin-x64.zip ./scripts/repackage-intel.sh`
- `INSPECT_ONLY=1 ./scripts/repackage-intel.sh Codex.app`
- `SKIP_NATIVE_REBUILD=1 ./scripts/repackage-intel.sh`
- `KEEP_PROD_FLAVOR=1 ./scripts/repackage-intel.sh`
- `CODEX_X64_BINARY=/path/to/x64/codex ./scripts/repackage-intel.sh`
- `DOWNLOAD_LATEST_CODEX_CLI=0 ./scripts/repackage-intel.sh`
- `SIGN_APP=1 SIGN_IDENTITY=- ./scripts/repackage-intel.sh`
- `RG_X64_BINARY=/usr/local/bin/rg ./scripts/repackage-intel.sh`
- `RIPGREP_VERSION=15.1.0 ./scripts/repackage-intel.sh`
- `RIPGREP_TARBALL_URL=https://example.invalid/ripgrep-x64.tar.gz ./scripts/repackage-intel.sh`
- `SPARKLE_FEED_URL=https://github.com/<owner>/<repo>/releases/download/codex-intel-latest/appcast.xml SPARKLE_PUBLIC_ED_KEY=<public-key> ./scripts/repackage-intel.sh`

## GitHub Release Workflow

The repo includes [release-intel.yml](./.github/workflows/release-intel.yml) to publish Intel builds.

Current behavior:

1. Reads upstream metadata with [scripts/check_upstream.py](./scripts/check_upstream.py).
2. Computes a versioned release tag from the upstream version and build.
3. Skips the build when that release already exists.
4. Downloads the upstream package, extracts `Codex.app`, inspects the bundle, repacks the Intel app, and smoke-tests the result.
5. Publishes versioned artifacts and updates the moving `codex-intel-latest` release.
6. Publishes `appcast.xml` when Sparkle signing secrets are configured.

Triggers:

- schedule: every 6 hours
- manual dispatch: optional `force`, `cleanup`, and `keep_releases`

Latest release assets:

- `Codex-intel-latest.zip`
- `Codex-intel-latest.sha256`
- `appcast.xml`

Sparkle secrets:

- `SPARKLE_PUBLIC_ED_KEY`
- `SPARKLE_PRIVATE_KEY`

## Special Thanks

- `JustYannicc` for adding x64 `rg` replacement support and the GitHub Releases / Sparkle auto-update foundation for Intel repacks.
