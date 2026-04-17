#!/usr/bin/env python3
"""Inspect a Codex app bundle and emit rebuild metadata as JSON."""

from __future__ import annotations

import argparse
from dataclasses import asdict, dataclass
import json
import os
import pathlib
import plistlib
import subprocess
import sys
import tempfile


@dataclass(frozen=True)
class NativeModuleMetadata:
    name: str
    version: str
    source_path: str
    output_paths: list[str]


@dataclass(frozen=True)
class BundleMetadata:
    app_path: str
    electron_version: str
    short_version: str
    build_version: str
    node_pty_abi_suffix: str
    sparkle_enabled: bool
    native_modules: list[NativeModuleMetadata]


def extract_asar_file(archive: pathlib.Path, filename: str) -> bytes:
    env = os.environ.copy()
    with tempfile.TemporaryDirectory(prefix="codex-asar-cache-") as cache_dir:
        with tempfile.TemporaryDirectory(prefix="codex-asar-extract-") as cwd:
            env["npm_config_cache"] = cache_dir
            env["npm_config_loglevel"] = "error"
            env["npm_config_update_notifier"] = "false"
            subprocess.run(
                ["npx", "--yes", "@electron/asar", "extract-file", str(archive), filename],
                check=True,
                cwd=cwd,
                env=env,
                stdout=subprocess.DEVNULL,
            )
            extracted = pathlib.Path(cwd) / pathlib.Path(filename).name
            return extracted.read_bytes()


def read_json_from_asar(archive: pathlib.Path, filename: str) -> dict[str, object]:
    raw = extract_asar_file(archive, filename)
    data = json.loads(raw.decode("utf-8"))
    if not isinstance(data, dict):
        raise RuntimeError(f"Unexpected JSON object in {filename}")
    return data


def require_string(data: dict[str, object], key: str, source: str) -> str:
    value = data.get(key)
    if not isinstance(value, str) or not value:
        raise RuntimeError(f"Missing string field {key!r} in {source}")
    return value


def derive_node_pty_abi_suffix(app_unpacked: pathlib.Path) -> str:
    base = app_unpacked / "node_modules" / "node-pty" / "bin"
    if not base.is_dir():
        return ""

    for prefix in ("darwin-arm64-", "darwin-x64-"):
        candidates = sorted(
            path.name for path in base.iterdir() if path.is_dir() and path.name.startswith(prefix)
        )
        if candidates:
            return candidates[0][len(prefix) :]

    return ""


def inspect_bundle(app_path: pathlib.Path) -> BundleMetadata:
    if not app_path.is_dir():
        raise RuntimeError(f"App path not found: {app_path}")

    info_plist = app_path / "Contents" / "Info.plist"
    framework_plist = (
        app_path / "Contents" / "Frameworks" / "Electron Framework.framework" / "Resources" / "Info.plist"
    )
    asar_path = app_path / "Contents" / "Resources" / "app.asar"
    unpacked_dir = app_path / "Contents" / "Resources" / "app.asar.unpacked"

    with info_plist.open("rb") as handle:
        info = plistlib.load(handle)
    with framework_plist.open("rb") as handle:
        framework_info = plistlib.load(handle)

    short_version = require_string(info, "CFBundleShortVersionString", str(info_plist))
    build_version = require_string(info, "CFBundleVersion", str(info_plist))
    electron_version = require_string(framework_info, "CFBundleVersion", str(framework_plist))

    better_sqlite3 = read_json_from_asar(asar_path, "node_modules/better-sqlite3/package.json")
    node_pty = read_json_from_asar(asar_path, "node_modules/node-pty/package.json")

    node_pty_abi_suffix = derive_node_pty_abi_suffix(unpacked_dir)
    node_pty_outputs = [
        "node_modules/node-pty/build/Release/pty.node",
    ]
    if node_pty_abi_suffix:
        node_pty_outputs.append(f"node_modules/node-pty/bin/darwin-x64-{node_pty_abi_suffix}/node-pty.node")

    metadata = BundleMetadata(
        app_path=str(app_path),
        electron_version=electron_version,
        short_version=short_version,
        build_version=build_version,
        node_pty_abi_suffix=node_pty_abi_suffix,
        sparkle_enabled=(
            (app_path / "Contents" / "Resources" / "native" / "sparkle.node").exists()
            or (unpacked_dir / "native" / "sparkle.node").exists()
        ),
        native_modules=[
            NativeModuleMetadata(
                name="better-sqlite3",
                version=require_string(better_sqlite3, "version", "better-sqlite3/package.json"),
                source_path="node_modules/better-sqlite3",
                output_paths=[
                    "node_modules/better-sqlite3/build/Release/better_sqlite3.node",
                ],
            ),
            NativeModuleMetadata(
                name="node-pty",
                version=require_string(node_pty, "version", "node-pty/package.json"),
                source_path="node_modules/node-pty",
                output_paths=node_pty_outputs,
            ),
        ],
    )
    return metadata


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("app_path", type=pathlib.Path)
    parser.add_argument("--pretty", action="store_true", help="Pretty-print JSON output")
    args = parser.parse_args()

    metadata = inspect_bundle(args.app_path.resolve())
    json.dump(asdict(metadata), sys.stdout, indent=2 if args.pretty else None)
    sys.stdout.write("\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
