#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
ARCHIVE_DIR="${1:-}"
OUTPUT_PATH="${2:-}"
DOWNLOAD_URL_PREFIX="${3:-}"
WORK_DIR="${WORK_DIR:-$ROOT_DIR/.build-intel}"
SPARKLE_VERSION="${SPARKLE_VERSION:-2.8.0}"
SPARKLE_TARBALL_URL="${SPARKLE_TARBALL_URL:-https://github.com/sparkle-project/Sparkle/releases/download/${SPARKLE_VERSION}/Sparkle-${SPARKLE_VERSION}.tar.xz}"
SPARKLE_PRIVATE_KEY="${SPARKLE_PRIVATE_KEY:-}"

log() {
  printf '[appcast] %s\n' "$*" >&2
}

need_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    printf 'Missing required command: %s\n' "$1" >&2
    exit 1
  fi
}

main() {
  need_cmd curl
  need_cmd tar

  [[ -n "$ARCHIVE_DIR" ]] || { echo "usage: $0 <archive-dir> <output-path> <download-url-prefix>" >&2; exit 1; }
  [[ -d "$ARCHIVE_DIR" ]] || { echo "archive dir not found: $ARCHIVE_DIR" >&2; exit 1; }
  [[ -n "$OUTPUT_PATH" ]] || { echo "missing output path" >&2; exit 1; }
  [[ -n "$DOWNLOAD_URL_PREFIX" ]] || { echo "missing download URL prefix" >&2; exit 1; }
  [[ -n "$SPARKLE_PRIVATE_KEY" ]] || { echo "SPARKLE_PRIVATE_KEY is required" >&2; exit 1; }

  mkdir -p "$WORK_DIR"
  local sparkle_dir="$WORK_DIR/sparkle-tools"
  local tarball="$WORK_DIR/$(basename "$SPARKLE_TARBALL_URL")"

  if [[ ! -f "$tarball" ]]; then
    log "Downloading Sparkle tools from $SPARKLE_TARBALL_URL"
    curl -fL --retry 3 --retry-delay 2 "$SPARKLE_TARBALL_URL" -o "$tarball"
  fi

  rm -rf "$sparkle_dir"
  mkdir -p "$sparkle_dir"
  tar -xf "$tarball" -C "$sparkle_dir"

  log "Generating appcast for archives in $ARCHIVE_DIR"
  printf '%s' "$SPARKLE_PRIVATE_KEY" | \
    "$sparkle_dir/bin/generate_appcast" \
      --ed-key-file - \
      --download-url-prefix "$DOWNLOAD_URL_PREFIX" \
      --maximum-versions 1 \
      -o "$OUTPUT_PATH" \
      "$ARCHIVE_DIR"
}

main "$@"
