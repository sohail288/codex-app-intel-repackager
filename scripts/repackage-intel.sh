#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
SRC_APP="${1:-$ROOT_DIR/Codex.app}"
OUT_APP="${2:-$ROOT_DIR/Codex-intel.app}"
WORK_DIR="${WORK_DIR:-$ROOT_DIR/.build-intel}"
ELECTRON_VERSION="${ELECTRON_VERSION:-}"
ELECTRON_ZIP="${ELECTRON_ZIP:-}"
SKIP_NATIVE_REBUILD="${SKIP_NATIVE_REBUILD:-0}"
KEEP_PROD_FLAVOR="${KEEP_PROD_FLAVOR:-0}"
SIGN_APP="${SIGN_APP:-1}"
SIGN_IDENTITY="${SIGN_IDENTITY:--}"
CODEX_X64_BINARY="${CODEX_X64_BINARY:-}"

BETTER_SQLITE3_VERSION="12.4.6"
NODE_PTY_VERSION="1.1.0"

log() {
  printf '[repack] %s\n' "$*" >&2
}

need_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    printf 'Missing required command: %s\n' "$1" >&2
    exit 1
  fi
}

abs_path() {
  local p="$1"
  if [[ "$p" = /* ]]; then
    printf '%s\n' "$p"
  else
    printf '%s/%s\n' "$PWD" "$p"
  fi
}

copy_binary_slice() {
  local src="$1"
  local dst="$2"
  install -m 755 "$src" "$dst"
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

replace_bundled_codex_cli() {
  local src dst
  dst="$OUT_APP/Contents/Resources/codex"

  if src="$(find_x64_codex_binary)"; then
    log "Replacing bundled Resources/codex with x64 binary from: $src"
    copy_binary_slice "$src" "$dst"
    return
  fi

  log "x64 codex binary not found; replacing Resources/codex with PATH wrapper"
  cat > "$dst" <<'SH'
#!/usr/bin/env bash
set -euo pipefail

if command -v codex >/dev/null 2>&1; then
  exec codex "$@"
fi

echo "codex CLI not found in PATH. Install Codex CLI and retry." >&2
exit 127
SH
  chmod 755 "$dst"
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
  local target_abi="143"

  log "Building Intel native modules for Electron $ELECTRON_VERSION"
  rm -rf "$native_dir"
  mkdir -p "$native_dir"

  cat > "$native_dir/package.json" <<JSON
{
  "name": "codex-intel-native-rebuild",
  "private": true,
  "license": "UNLICENSED",
  "dependencies": {
    "better-sqlite3": "$BETTER_SQLITE3_VERSION",
    "node-pty": "$NODE_PTY_VERSION"
  }
}
JSON

  (
    cd "$native_dir"
    npm_config_arch=x64 \
    npm_config_target="$ELECTRON_VERSION" \
    npm_config_runtime=electron \
    npm_config_disturl=https://electronjs.org/headers \
    npm_config_build_from_source=true \
    npm install --no-audit --no-fund
  )

  local app_unpacked="$OUT_APP/Contents/Resources/app.asar.unpacked"
  local bs_src="$native_dir/node_modules/better-sqlite3/build/Release/better_sqlite3.node"
  local pty_src="$native_dir/node_modules/node-pty/build/Release/pty.node"
  local spawn_src="$native_dir/node_modules/node-pty/build/Release/spawn-helper"

  [[ -f "$bs_src" ]] || { echo "missing rebuilt better_sqlite3.node" >&2; exit 1; }
  [[ -f "$pty_src" ]] || { echo "missing rebuilt pty.node" >&2; exit 1; }

  log "Installing rebuilt better-sqlite3"
  install -m 755 "$bs_src" "$app_unpacked/node_modules/better-sqlite3/build/Release/better_sqlite3.node"

  log "Installing rebuilt node-pty"
  install -m 755 "$pty_src" "$app_unpacked/node_modules/node-pty/build/Release/pty.node"

  if [[ -f "$spawn_src" ]]; then
    install -m 755 "$spawn_src" "$app_unpacked/node_modules/node-pty/build/Release/spawn-helper"
  fi

  mkdir -p "$app_unpacked/node_modules/node-pty/bin/darwin-x64-$target_abi"
  install -m 755 "$pty_src" "$app_unpacked/node_modules/node-pty/bin/darwin-x64-$target_abi/node-pty.node"
}

set_dev_flavor() {
  local plist="$OUT_APP/Contents/Info.plist"
  if [[ "$KEEP_PROD_FLAVOR" == "1" ]]; then
    return
  fi

  log "Setting BUILD_FLAVOR=dev in Info.plist to skip Sparkle native module"
  /usr/libexec/PlistBuddy -c "Delete :LSEnvironment:BUILD_FLAVOR" "$plist" >/dev/null 2>&1 || true
  /usr/libexec/PlistBuddy -c "Add :LSEnvironment:BUILD_FLAVOR string dev" "$plist"
}

strip_sparkle_for_dev() {
  if [[ "$KEEP_PROD_FLAVOR" == "1" ]]; then
    return
  fi

  log "Removing Sparkle artifacts for dev flavor"
  rm -rf "$OUT_APP/Contents/Frameworks/Sparkle.framework"
  rm -f "$OUT_APP/Contents/Resources/native/sparkle.node"
  rm -f "$OUT_APP/Contents/Resources/app.asar.unpacked/native/sparkle.node"
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
  file "$OUT_APP/Contents/Resources/app.asar.unpacked/node_modules/better-sqlite3/build/Release/better_sqlite3.node" || true
  file "$OUT_APP/Contents/Resources/app.asar.unpacked/node_modules/node-pty/build/Release/pty.node" || true
}

main() {
  need_cmd plutil
  need_cmd curl
  need_cmd unzip
  need_cmd lipo
  need_cmd npm

  if [[ "$SIGN_APP" == "1" ]]; then
    need_cmd codesign
  fi

  SRC_APP="$(abs_path "$SRC_APP")"
  OUT_APP="$(abs_path "$OUT_APP")"

  [[ -d "$SRC_APP" ]] || { echo "Source app not found: $SRC_APP" >&2; exit 1; }

  mkdir -p "$WORK_DIR"

  if [[ -z "$ELECTRON_VERSION" ]]; then
    ELECTRON_VERSION="$(plutil -extract CFBundleVersion raw -o - "$SRC_APP/Contents/Frameworks/Electron Framework.framework/Resources/Info.plist")"
  fi

  local runtime_zip="$ELECTRON_ZIP"
  if [[ -z "$runtime_zip" ]]; then
    runtime_zip="$WORK_DIR/electron-v${ELECTRON_VERSION}-darwin-x64.zip"
    if [[ ! -f "$runtime_zip" ]]; then
      log "Downloading Electron runtime v${ELECTRON_VERSION} (darwin-x64)"
      curl -fL --retry 3 --retry-delay 2 \
        "https://github.com/electron/electron/releases/download/v${ELECTRON_VERSION}/electron-v${ELECTRON_VERSION}-darwin-x64.zip" \
        -o "$runtime_zip"
    fi
  fi

  local runtime_dir="$WORK_DIR/electron-runtime"
  rm -rf "$runtime_dir"
  mkdir -p "$runtime_dir"
  unzip -q "$runtime_zip" -d "$runtime_dir"

  local electron_app="$runtime_dir/Electron.app"
  [[ -d "$electron_app" ]] || { echo "Electron.app not found in runtime zip" >&2; exit 1; }

  log "Creating output app: $OUT_APP"
  rm -rf "$OUT_APP"
  cp -R "$SRC_APP" "$OUT_APP"

  replace_runtime "$electron_app"
  replace_bundled_codex_cli

  if [[ "$SKIP_NATIVE_REBUILD" != "1" ]]; then
    build_native_modules
  else
    log "Skipping native module rebuild (SKIP_NATIVE_REBUILD=1)"
  fi

  set_dev_flavor
  strip_sparkle_for_dev
  ad_hoc_sign
  clear_quarantine
  verify_arch

  log "Done: $OUT_APP"
}

main "$@"
