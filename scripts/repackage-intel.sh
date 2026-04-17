#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
SRC_APP="${1:-$ROOT_DIR/Codex.app}"
OUT_APP="${2:-$ROOT_DIR/Codex-intel.app}"
WORK_DIR="${WORK_DIR:-$ROOT_DIR/.build-intel}"
ELECTRON_VERSION="${ELECTRON_VERSION:-}"
ELECTRON_ZIP="${ELECTRON_ZIP:-}"
SKIP_NATIVE_REBUILD="${SKIP_NATIVE_REBUILD:-0}"
INSPECT_ONLY="${INSPECT_ONLY:-0}"
KEEP_PROD_FLAVOR="${KEEP_PROD_FLAVOR:-0}"
SIGN_APP="${SIGN_APP:-1}"
SIGN_IDENTITY="${SIGN_IDENTITY:--}"
SPARKLE_FEED_URL="${SPARKLE_FEED_URL:-}"
SPARKLE_PUBLIC_ED_KEY="${SPARKLE_PUBLIC_ED_KEY:-}"
CODEX_X64_BINARY="${CODEX_X64_BINARY:-}"
DOWNLOAD_LATEST_CODEX_CLI="${DOWNLOAD_LATEST_CODEX_CLI:-1}"
RG_X64_BINARY="${RG_X64_BINARY:-}"
RIPGREP_VERSION="${RIPGREP_VERSION:-14.1.1}"
RIPGREP_TARBALL_URL="${RIPGREP_TARBALL_URL:-}"

CURRENT_PHASE="startup"
APP_METADATA_JSON=""
ASAR_DIR=""
NPM_CACHE_DIR=""
META_ELECTRON_VERSION=""
META_SHORT_VERSION=""
META_BUILD_VERSION=""
META_BETTER_SQLITE3_VERSION=""
META_NODE_PTY_VERSION=""
META_NODE_PTY_ABI_SUFFIX=""
META_SPARKLE_ENABLED=""

log() {
  printf '[repack] %s\n' "$*" >&2
}

warn() {
  printf '[repack][warn] %s\n' "$*" >&2
}

need_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    printf 'Missing required command: %s\n' "$1" >&2
    exit 1
  fi
}

set_phase() {
  CURRENT_PHASE="$1"
  log "Phase: $CURRENT_PHASE"
}

report_failure() {
  local line="$1"
  local cmd="$2"
  local exit_code="$3"

  printf '[repack][error] phase=%s line=%s exit=%s\n' "$CURRENT_PHASE" "$line" "$exit_code" >&2
  printf '[repack][error] command=%s\n' "$cmd" >&2

  if [[ -n "$APP_METADATA_JSON" && -f "$APP_METADATA_JSON" ]]; then
    printf '[repack][error] metadata=%s\n' "$APP_METADATA_JSON" >&2
    python3 - "$APP_METADATA_JSON" <<'PY' >&2 || true
import json
import sys

path = sys.argv[1]
data = json.load(open(path, "r", encoding="utf-8"))
mods = {item["name"]: item["version"] for item in data.get("native_modules", [])}
print(
    "[repack][error] summary "
    f"electron={data.get('electron_version')} "
    f"short_version={data.get('short_version')} "
    f"build_version={data.get('build_version')} "
    f"better-sqlite3={mods.get('better-sqlite3')} "
    f"node-pty={mods.get('node-pty')} "
    f"node_pty_abi_suffix={data.get('node_pty_abi_suffix')} "
    f"sparkle_enabled={data.get('sparkle_enabled')}"
)
PY
  fi

  exit "$exit_code"
}

trap 'report_failure "${LINENO}" "${BASH_COMMAND}" "$?"' ERR

abs_path() {
  local p="$1"
  if [[ "$p" = /* ]]; then
    printf '%s\n' "$p"
  else
    printf '%s/%s\n' "$PWD" "$p"
  fi
}

should_keep_prod_flavor() {
  [[ "$KEEP_PROD_FLAVOR" == "1" ]] || has_managed_sparkle_config
}

has_managed_sparkle_config() {
  [[ -n "$SPARKLE_FEED_URL" && -n "$SPARKLE_PUBLIC_ED_KEY" ]]
}

copy_binary_slice() {
  local src="$1"
  local dst="$2"
  install -m 755 "$src" "$dst"
}

run_asar() {
  npm_config_cache="$NPM_CACHE_DIR" \
  npm_config_loglevel=error \
  npm_config_update_notifier=false \
  npx --yes @electron/asar "$@"
}

json_get() {
  local path="$1"
  local expr="$2"
  python3 - "$path" "$expr" <<'PY'
import json
import sys

data = json.load(open(sys.argv[1], "r", encoding="utf-8"))
expr = sys.argv[2]
value = data
for part in expr.split("."):
    if isinstance(value, list):
        value = value[int(part)]
    else:
        value = value[part]
if isinstance(value, bool):
    print("true" if value else "false")
else:
    print(value)
PY
}

load_upstream_metadata() {
  APP_METADATA_JSON="$WORK_DIR/upstream-bundle-metadata.json"
  python3 "$ROOT_DIR/scripts/inspect_upstream_bundle.py" "$SRC_APP" > "$APP_METADATA_JSON"

  META_ELECTRON_VERSION="$(json_get "$APP_METADATA_JSON" "electron_version")"
  META_SHORT_VERSION="$(json_get "$APP_METADATA_JSON" "short_version")"
  META_BUILD_VERSION="$(json_get "$APP_METADATA_JSON" "build_version")"
  META_BETTER_SQLITE3_VERSION="$(json_get "$APP_METADATA_JSON" "native_modules.0.version")"
  META_NODE_PTY_VERSION="$(json_get "$APP_METADATA_JSON" "native_modules.1.version")"
  META_NODE_PTY_ABI_SUFFIX="$(json_get "$APP_METADATA_JSON" "node_pty_abi_suffix")"
  META_SPARKLE_ENABLED="$(json_get "$APP_METADATA_JSON" "sparkle_enabled")"

  log "Upstream metadata: Electron=$META_ELECTRON_VERSION Codex=$META_SHORT_VERSION ($META_BUILD_VERSION) better-sqlite3=$META_BETTER_SQLITE3_VERSION node-pty=$META_NODE_PTY_VERSION abi=$META_NODE_PTY_ABI_SUFFIX sparkle=$META_SPARKLE_ENABLED"
}

ensure_asar_dir() {
  if [[ -d "$ASAR_DIR" ]]; then
    return
  fi

  set_phase "extract app.asar"
  rm -rf "$ASAR_DIR"
  mkdir -p "$ASAR_DIR"
  run_asar extract "$OUT_APP/Contents/Resources/app.asar" "$ASAR_DIR"
}

stage_npm_package_source() {
  local package_name="$1"
  local package_version="$2"
  local dest_dir="$3"
  local tarball

  rm -rf "$dest_dir"
  mkdir -p "$dest_dir"

  tarball="$(cd "$WORK_DIR" && npm pack "${package_name}@${package_version}")"
  tar -xzf "$WORK_DIR/$tarball" -C "$dest_dir" --strip-components=1
  rm -f "$WORK_DIR/$tarball"
}

is_x64_macho() {
  local target="$1"
  [[ -x "$target" ]] || return 1
  file "$target" 2>/dev/null | grep -q 'x86_64'
}

find_x64_codex_binary() {
  local codex_cli prefix candidate

  if [[ -n "$CODEX_X64_BINARY" && -x "$CODEX_X64_BINARY" ]]; then
    printf '%s\n' "$CODEX_X64_BINARY"
    return 0
  fi

  codex_cli="$(command -v codex || true)"
  if [[ -z "$codex_cli" ]]; then
    return 1
  fi

  # Typical npm global layout: <prefix>/bin/codex and
  # <prefix>/lib/node_modules/@openai/codex/node_modules/@openai/codex-darwin-x64/vendor/...
  prefix="$(cd -- "$(dirname -- "$codex_cli")/.." && pwd)"
  candidate="$prefix/lib/node_modules/@openai/codex/node_modules/@openai/codex-darwin-x64/vendor/x86_64-apple-darwin/codex/codex"
  if [[ -x "$candidate" ]]; then
    printf '%s\n' "$candidate"
    return 0
  fi

  return 1
}

install_latest_codex_cli() {
  local cli_dir candidate

  cli_dir="$WORK_DIR/codex-cli"
  rm -rf "$cli_dir"
  mkdir -p "$cli_dir"

  log "Installing latest Codex CLI into build workspace"
  npm install \
    --prefix "$cli_dir" \
    --no-audit \
    --no-fund \
    @openai/codex@latest \
    >/dev/null

  candidate="$(find "$cli_dir" -type f -path '*/x86_64-apple-darwin/codex/codex' | head -n 1 || true)"
  if [[ -n "$candidate" && -x "$candidate" ]]; then
    printf '%s\n' "$candidate"
    return 0
  fi

  echo "latest Codex CLI install did not produce an x64 binary under $cli_dir" >&2
  find "$cli_dir" -maxdepth 8 -type f -name codex | sed -n '1,120p' >&2 || true
  return 1
}

find_x64_rg_binary() {
  local candidate p

  if [[ -n "$RG_X64_BINARY" && -x "$RG_X64_BINARY" ]] && is_x64_macho "$RG_X64_BINARY"; then
    printf '%s\n' "$RG_X64_BINARY"
    return 0
  fi

  for candidate in "$(command -v rg || true)" /usr/local/bin/rg /opt/homebrew/bin/rg; do
    if [[ -n "$candidate" ]] && is_x64_macho "$candidate"; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done

  if [[ -d "$HOME/.nvm/versions/node" ]]; then
    p="$(find "$HOME/.nvm/versions/node" -path '*/bin/rg' -type f 2>/dev/null | tail -n 1 || true)"
    if [[ -n "$p" ]] && is_x64_macho "$p"; then
      printf '%s\n' "$p"
      return 0
    fi
  fi

  return 1
}

download_x64_rg_binary() {
  local rg_work_dir tarball_url tarball_path extract_dir
  rg_work_dir="$WORK_DIR/ripgrep"
  mkdir -p "$rg_work_dir"

  if [[ -n "$RIPGREP_TARBALL_URL" ]]; then
    tarball_url="$RIPGREP_TARBALL_URL"
  else
    tarball_url="https://github.com/BurntSushi/ripgrep/releases/download/${RIPGREP_VERSION}/ripgrep-${RIPGREP_VERSION}-x86_64-apple-darwin.tar.gz"
  fi

  if [[ -z "$tarball_url" ]]; then
    echo "failed to resolve x64 ripgrep tarball URL" >&2
    exit 1
  fi

  tarball_path="$rg_work_dir/$(basename "$tarball_url")"
  if [[ ! -f "$tarball_path" ]]; then
    log "Downloading x64 ripgrep from: $tarball_url"
    curl -fL --retry 3 --retry-delay 2 "$tarball_url" -o "$tarball_path"
  fi

  extract_dir="$rg_work_dir/extracted"
  rm -rf "$extract_dir"
  mkdir -p "$extract_dir"
  tar -xzf "$tarball_path" -C "$extract_dir"

  find "$extract_dir" -path '*/rg' -type f -perm -111 | head -n 1
}

replace_bundled_codex_cli() {
  local src dst
  dst="$OUT_APP/Contents/Resources/codex"

  if [[ "$DOWNLOAD_LATEST_CODEX_CLI" == "1" ]]; then
    if src="$(install_latest_codex_cli)"; then
      log "Replacing bundled Resources/codex with x64 binary from freshly installed latest Codex CLI: $src"
      copy_binary_slice "$src" "$dst"
      return
    fi
  fi

  if src="$(find_x64_codex_binary)"; then
    log "Replacing bundled Resources/codex with x64 binary from: $src"
    copy_binary_slice "$src" "$dst"
    return
  fi

  log "x64 codex binary not found; replacing Resources/codex with PATH wrapper"
  cat > "$dst" <<'SH'
#!/usr/bin/env bash
set -euo pipefail

resolve_codex() {
  local p

  if command -v codex >/dev/null 2>&1; then
    command -v codex
    return 0
  fi

  for p in /usr/local/bin/codex /opt/homebrew/bin/codex; do
    if [[ -x "$p" ]]; then
      printf '%s\n' "$p"
      return 0
    fi
  done

  if [[ -d "$HOME/.nvm/versions/node" ]]; then
    p="$(ls -1d "$HOME/.nvm/versions/node/"*/bin/codex 2>/dev/null | tail -n 1 || true)"
    if [[ -n "${p}" && -x "${p}" ]]; then
      printf '%s\n' "$p"
      return 0
    fi
  fi

  p="$(/bin/bash -lc 'command -v codex' 2>/dev/null || true)"
  if [[ -n "$p" && -x "$p" ]]; then
    printf '%s\n' "$p"
    return 0
  fi

  return 1
}

if COD="$(resolve_codex)"; then
  exec "$COD" "$@"
fi

echo "codex CLI not found. Install Codex CLI (x64) and ensure it is discoverable from GUI apps." >&2
exit 127
SH
  chmod 755 "$dst"
}

replace_bundled_rg() {
  local src dst
  dst="$OUT_APP/Contents/Resources/rg"

  if src="$(find_x64_rg_binary)"; then
    log "Replacing bundled Resources/rg with x64 binary from: $src"
    copy_binary_slice "$src" "$dst"
    return
  fi

  src="$(download_x64_rg_binary)"
  [[ -n "$src" && -f "$src" ]] || { echo "failed to resolve x64 rg binary" >&2; exit 1; }
  log "Replacing bundled Resources/rg with downloaded x64 binary"
  copy_binary_slice "$src" "$dst"
}

replace_runtime() {
  local electron_app="$1"
  local src_frameworks_dir="$electron_app/Contents/Frameworks"
  local dst_frameworks_dir="$OUT_APP/Contents/Frameworks"

  log "Replacing main Electron runtime"
  copy_binary_slice "$electron_app/Contents/MacOS/Electron" "$OUT_APP/Contents/MacOS/Codex"

  log "Replacing helper executables"
  copy_binary_slice "$electron_app/Contents/Frameworks/Electron Helper.app/Contents/MacOS/Electron Helper" \
    "$OUT_APP/Contents/Frameworks/Codex Helper.app/Contents/MacOS/Codex Helper"
  copy_binary_slice "$electron_app/Contents/Frameworks/Electron Helper (Renderer).app/Contents/MacOS/Electron Helper (Renderer)" \
    "$OUT_APP/Contents/Frameworks/Codex Helper (Renderer).app/Contents/MacOS/Codex Helper (Renderer)"
  copy_binary_slice "$electron_app/Contents/Frameworks/Electron Helper (GPU).app/Contents/MacOS/Electron Helper (GPU)" \
    "$OUT_APP/Contents/Frameworks/Codex Helper (GPU).app/Contents/MacOS/Codex Helper (GPU)"
  copy_binary_slice "$electron_app/Contents/Frameworks/Electron Helper (Plugin).app/Contents/MacOS/Electron Helper (Plugin)" \
    "$OUT_APP/Contents/Frameworks/Codex Helper (Plugin).app/Contents/MacOS/Codex Helper (Plugin)"

  log "Replacing matching frameworks from Electron runtime"
  find "$src_frameworks_dir" -maxdepth 1 -type d -name "*.framework" -print0 | while IFS= read -r -d '' src_fwk; do
    local name dst_fwk
    name="$(basename "$src_fwk")"
    dst_fwk="$dst_frameworks_dir/$name"
    if [[ -d "$dst_fwk" ]]; then
      rm -rf "$dst_fwk"
      cp -R "$src_fwk" "$dst_fwk"
      log "Replaced framework: $name"
    fi
  done

  if [[ -d "$electron_app/Contents/Frameworks/Electron Helper (Alerts).app" && -d "$OUT_APP/Contents/Frameworks/Codex Helper (Alerts).app" ]]; then
    copy_binary_slice "$electron_app/Contents/Frameworks/Electron Helper (Alerts).app/Contents/MacOS/Electron Helper (Alerts)" \
      "$OUT_APP/Contents/Frameworks/Codex Helper (Alerts).app/Contents/MacOS/Codex Helper (Alerts)"
  fi
}

build_native_modules() {
  local native_dir="$WORK_DIR/native"
  local app_unpacked="$OUT_APP/Contents/Resources/app.asar.unpacked"
  local bs_stage="$native_dir/better-sqlite3"
  local pty_stage="$native_dir/node-pty"
  local bs_src="$bs_stage/build/Release/better_sqlite3.node"
  local pty_src="$pty_stage/build/Release/pty.node"
  local spawn_src="$pty_stage/build/Release/spawn-helper"

  [[ -d "$app_unpacked/node_modules/better-sqlite3" ]] || { echo "missing unpacked better-sqlite3 directory: $app_unpacked/node_modules/better-sqlite3" >&2; exit 1; }
  [[ -d "$app_unpacked/node_modules/node-pty" ]] || { echo "missing unpacked node-pty directory: $app_unpacked/node_modules/node-pty" >&2; exit 1; }

  log "Building Intel native modules for Electron $META_ELECTRON_VERSION from upstream package versions"
  rm -rf "$native_dir"
  mkdir -p "$native_dir"

  set_phase "stage native module sources"
  stage_npm_package_source "better-sqlite3" "$META_BETTER_SQLITE3_VERSION" "$bs_stage"
  stage_npm_package_source "node-pty" "$META_NODE_PTY_VERSION" "$pty_stage"

  set_phase "rebuild better-sqlite3"
  (
    cd "$bs_stage"
    rm -rf node_modules build/Release
    npm install --ignore-scripts --omit=dev --no-audit --no-fund
    npm rebuild \
      --build-from-source \
      --runtime=electron \
      --target="$META_ELECTRON_VERSION" \
      --dist-url=https://electronjs.org/headers \
      --arch=x64
  )

  set_phase "rebuild node-pty"
  (
    cd "$pty_stage"
    rm -rf build/Release
    npm install --ignore-scripts --omit=dev --no-audit --no-fund
    npm rebuild \
      --build-from-source \
      --runtime=electron \
      --target="$META_ELECTRON_VERSION" \
      --dist-url=https://electronjs.org/headers \
      --arch=x64
  )

  [[ -f "$bs_src" ]] || { echo "missing rebuilt better_sqlite3.node" >&2; exit 1; }
  [[ -f "$pty_src" ]] || { echo "missing rebuilt pty.node" >&2; exit 1; }

  set_phase "install native modules"
  log "Installing rebuilt better-sqlite3"
  install -m 755 "$bs_src" "$app_unpacked/node_modules/better-sqlite3/build/Release/better_sqlite3.node"

  log "Installing rebuilt node-pty"
  install -m 755 "$pty_src" "$app_unpacked/node_modules/node-pty/build/Release/pty.node"

  if [[ -f "$spawn_src" ]]; then
    install -m 755 "$spawn_src" "$app_unpacked/node_modules/node-pty/build/Release/spawn-helper"
  fi

  if [[ -n "$META_NODE_PTY_ABI_SUFFIX" ]]; then
    mkdir -p "$app_unpacked/node_modules/node-pty/bin/darwin-x64-$META_NODE_PTY_ABI_SUFFIX"
    install -m 755 "$pty_src" "$app_unpacked/node_modules/node-pty/bin/darwin-x64-$META_NODE_PTY_ABI_SUFFIX/node-pty.node"
  fi
}

prune_arm64_native_artifacts() {
  local app_unpacked="$OUT_APP/Contents/Resources/app.asar.unpacked"

  if [[ ! -d "$app_unpacked/node_modules/node-pty/bin" ]]; then
    return
  fi

  log "Removing stale arm64 node-pty bundle artifacts"
  rm -rf "$app_unpacked/node_modules/node-pty/bin"/darwin-arm64-*
}

set_dev_flavor() {
  local plist="$OUT_APP/Contents/Info.plist"
  if should_keep_prod_flavor; then
    log "Keeping production build flavor"
    /usr/libexec/PlistBuddy -c "Delete :LSEnvironment:BUILD_FLAVOR" "$plist" >/dev/null 2>&1 || true
    return
  fi

  log "Setting BUILD_FLAVOR=dev in Info.plist to skip Sparkle native module"
  /usr/libexec/PlistBuddy -c "Delete :LSEnvironment:BUILD_FLAVOR" "$plist" >/dev/null 2>&1 || true
  /usr/libexec/PlistBuddy -c "Add :LSEnvironment:BUILD_FLAVOR string dev" "$plist"
}

strip_sparkle_for_dev() {
  if should_keep_prod_flavor; then
    return
  fi

  log "Removing Sparkle artifacts for dev flavor"
  rm -rf "$OUT_APP/Contents/Frameworks/Sparkle.framework"
  rm -f "$OUT_APP/Contents/Resources/native/sparkle.node"
  rm -f "$OUT_APP/Contents/Resources/app.asar.unpacked/native/sparkle.node"
}

patch_sparkle_metadata() {
  if ! has_managed_sparkle_config; then
    log "Sparkle feed or public key missing; keeping packaged metadata unchanged"
    return
  fi

  local plist="$OUT_APP/Contents/Info.plist"
  local package_json="$ASAR_DIR/package.json"

  log "Patching packaged Sparkle feed URL"
  ensure_asar_dir

  node - "$package_json" "$SPARKLE_FEED_URL" <<'NODE'
const fs = require('fs');

const [packageJsonPath, feedUrl] = process.argv.slice(2);
const pkg = JSON.parse(fs.readFileSync(packageJsonPath, 'utf8'));
pkg.codexBuildFlavor = 'prod';
pkg.codexSparkleFeedUrl = feedUrl;
fs.writeFileSync(packageJsonPath, `${JSON.stringify(pkg, null, 2)}\n`);
NODE

  rm -f "$OUT_APP/Contents/Resources/app.asar"
  run_asar pack "$ASAR_DIR" "$OUT_APP/Contents/Resources/app.asar"

  log "Updating Info.plist Sparkle keys"
  /usr/libexec/PlistBuddy -c "Delete :SUFeedURL" "$plist" >/dev/null 2>&1 || true
  /usr/libexec/PlistBuddy -c "Add :SUFeedURL string $SPARKLE_FEED_URL" "$plist"
  /usr/libexec/PlistBuddy -c "Delete :SUPublicEDKey" "$plist" >/dev/null 2>&1 || true
  /usr/libexec/PlistBuddy -c "Add :SUPublicEDKey string $SPARKLE_PUBLIC_ED_KEY" "$plist"
}

build_sparkle_addon() {
  if ! should_keep_prod_flavor; then
    return
  fi

  local addon_dir="$WORK_DIR/sparkle-addon"
  local addon_src="$ROOT_DIR/native/sparkle-addon"
  local app_resources="$OUT_APP/Contents/Resources"
  local addon_bin

  [[ -d "$addon_src" ]] || { echo "missing sparkle addon sources: $addon_src" >&2; exit 1; }

  log "Building Intel Sparkle addon"
  rm -rf "$addon_dir"
  mkdir -p "$addon_dir"
  cp -R "$addon_src/." "$addon_dir/"

  (
    cd "$addon_dir"
    npm install --ignore-scripts --no-audit --no-fund

    SPARKLE_FRAMEWORK_DIR="$OUT_APP/Contents/Frameworks" \
    ./node_modules/.bin/node-gyp rebuild \
      --release \
      --arch=x64 \
      --target="$META_ELECTRON_VERSION" \
      --dist-url=https://electronjs.org/headers
  )

  addon_bin="$addon_dir/build/Release/sparkle.node"
  [[ -f "$addon_bin" ]] || { echo "missing rebuilt sparkle.node" >&2; exit 1; }

  mkdir -p "$app_resources/native" "$app_resources/app.asar.unpacked/native"
  install -m 755 "$addon_bin" "$app_resources/native/sparkle.node"
  install -m 755 "$addon_bin" "$app_resources/app.asar.unpacked/native/sparkle.node"
}

ad_hoc_sign() {
  if [[ "$SIGN_APP" != "1" ]]; then
    log "Skipping code signing (SIGN_APP=0)"
    return
  fi

  log "Deep-signing nested helper apps"
  find "$OUT_APP/Contents/Frameworks" -depth -type d -name "*.app" -print0 | while IFS= read -r -d '' p; do
    if [[ "$p" == *"/Sparkle.framework/"* ]]; then
      continue
    fi
    codesign --force --deep --sign "$SIGN_IDENTITY" "$p"
  done

  log "Deep-signing nested frameworks"
  find "$OUT_APP/Contents/Frameworks" -depth -type d -name "*.framework" -print0 | while IFS= read -r -d '' p; do
    if [[ "$(basename "$p")" == "Sparkle.framework" ]]; then
      continue
    fi
    codesign --force --deep --sign "$SIGN_IDENTITY" "$p"
  done

  log "Signing rebuilt binaries in Resources"
  find "$OUT_APP/Contents/Resources" -type f \( -name "*.node" -o -name "codex" -o -name "rg" -o -name "spawn-helper" \) -print0 | while IFS= read -r -d '' p; do
    codesign --force --sign "$SIGN_IDENTITY" "$p"
  done

  # Finally sign the top-level app bundle.
  log "Signing top-level app"
  codesign --force --sign "$SIGN_IDENTITY" "$OUT_APP"
}

clear_quarantine() {
  log "Clearing quarantine attributes"
  find "$OUT_APP" -print0 | while IFS= read -r -d '' p; do
    if xattr -p com.apple.quarantine "$p" >/dev/null 2>&1; then
      if [[ -f "$p" && ! -w "$p" ]]; then
        chmod u+w "$p" 2>/dev/null || true
        xattr -d com.apple.quarantine "$p" 2>/dev/null || true
        chmod u-w "$p" 2>/dev/null || true
      else
        xattr -d com.apple.quarantine "$p" 2>/dev/null || true
      fi
    fi
  done
}

verify_arch() {
  log "Verifying x86_64 slices"
  file "$OUT_APP/Contents/MacOS/Codex"
  file "$OUT_APP/Contents/Frameworks/Electron Framework.framework/Electron Framework"
  file "$OUT_APP/Contents/Resources/rg"
  file "$OUT_APP/Contents/Resources/app.asar.unpacked/node_modules/better-sqlite3/build/Release/better_sqlite3.node" || true
  file "$OUT_APP/Contents/Resources/app.asar.unpacked/node_modules/node-pty/build/Release/pty.node" || true
}

main() {
  need_cmd plutil
  need_cmd curl
  need_cmd unzip
  need_cmd lipo
  need_cmd npm
  need_cmd node
  need_cmd tar

  if [[ "$SIGN_APP" == "1" ]]; then
    need_cmd codesign
  fi

  SRC_APP="$(abs_path "$SRC_APP")"
  OUT_APP="$(abs_path "$OUT_APP")"
  NPM_CACHE_DIR="$WORK_DIR/npm-cache"
  ASAR_DIR="$WORK_DIR/app-asar"
  export npm_config_cache="$NPM_CACHE_DIR"
  export npm_config_devdir="$WORK_DIR/node-gyp"
  export npm_config_loglevel=error
  export npm_config_update_notifier=false

  [[ -d "$SRC_APP" ]] || { echo "Source app not found: $SRC_APP" >&2; exit 1; }

  mkdir -p "$WORK_DIR"
  set_phase "inspect upstream bundle"
  load_upstream_metadata

  if [[ -z "$ELECTRON_VERSION" ]]; then
    ELECTRON_VERSION="$META_ELECTRON_VERSION"
  elif [[ "$ELECTRON_VERSION" != "$META_ELECTRON_VERSION" ]]; then
    warn "Overriding detected Electron version $META_ELECTRON_VERSION with ELECTRON_VERSION=$ELECTRON_VERSION"
    META_ELECTRON_VERSION="$ELECTRON_VERSION"
  fi

  if [[ "$INSPECT_ONLY" == "1" ]]; then
    cat "$APP_METADATA_JSON"
    exit 0
  fi

  local runtime_zip="$ELECTRON_ZIP"
  if [[ -z "$runtime_zip" ]]; then
    runtime_zip="$WORK_DIR/electron-v${ELECTRON_VERSION}-darwin-x64.zip"
    if [[ ! -f "$runtime_zip" ]]; then
      set_phase "download Electron runtime"
      log "Downloading Electron runtime v${ELECTRON_VERSION} (darwin-x64)"
      curl -fL --retry 3 --retry-delay 2 \
        "https://github.com/electron/electron/releases/download/v${ELECTRON_VERSION}/electron-v${ELECTRON_VERSION}-darwin-x64.zip" \
        -o "$runtime_zip"
    fi
  fi

  local runtime_dir="$WORK_DIR/electron-runtime"
  set_phase "extract Electron runtime"
  rm -rf "$runtime_dir"
  mkdir -p "$runtime_dir"
  unzip -q "$runtime_zip" -d "$runtime_dir"

  local electron_app="$runtime_dir/Electron.app"
  [[ -d "$electron_app" ]] || { echo "Electron.app not found in runtime zip" >&2; exit 1; }

  set_phase "prepare output app"
  log "Creating output app: $OUT_APP"
  rm -rf "$OUT_APP"
  cp -R "$SRC_APP" "$OUT_APP"

  set_phase "replace Electron runtime"
  replace_runtime "$electron_app"
  set_phase "replace bundled codex CLI"
  replace_bundled_codex_cli
  set_phase "replace bundled ripgrep"
  replace_bundled_rg

  if [[ "$SKIP_NATIVE_REBUILD" != "1" ]]; then
    build_native_modules
  else
    log "Skipping native module rebuild (SKIP_NATIVE_REBUILD=1)"
  fi

  set_phase "set build flavor"
  set_dev_flavor
  set_phase "patch Sparkle metadata"
  patch_sparkle_metadata
  set_phase "build Sparkle addon"
  build_sparkle_addon
  set_phase "prune stale native artifacts"
  prune_arm64_native_artifacts
  set_phase "strip Sparkle for dev flavor"
  strip_sparkle_for_dev
  set_phase "codesign app"
  ad_hoc_sign
  set_phase "clear quarantine"
  clear_quarantine
  set_phase "verify architecture"
  verify_arch

  log "Done: $OUT_APP"
}

main "$@"
