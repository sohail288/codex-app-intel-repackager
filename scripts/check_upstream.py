#!/usr/bin/env python3
"""Fetch Codex appcast metadata and print latest DMG details as JSON."""

from __future__ import annotations

import json
import subprocess
import sys
import urllib.request
import xml.etree.ElementTree as ET

APPCAST_URL = "https://persistent.oaistatic.com/codex-app-prod/appcast.xml"
SPARKLE_NS = {"sparkle": "http://www.andymatuschak.org/xml-namespaces/sparkle"}


def fetch_bytes(url: str) -> bytes:
    # Some hosts block Python's default urllib user agent in CI.
    req = urllib.request.Request(
        url,
        headers={
            "User-Agent": (
                "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) "
                "AppleWebKit/537.36 (KHTML, like Gecko) "
                "Chrome/122.0.0.0 Safari/537.36"
            ),
            "Accept": "application/xml,text/xml;q=0.9,*/*;q=0.8",
        },
    )
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            return resp.read()
    except Exception:
        # Fallback to curl for CI environments where urllib is blocked.
        out = subprocess.check_output(
            [
                "curl",
                "-fLsS",
                "--retry",
                "3",
                "--retry-delay",
                "2",
                "-A",
                (
                    "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) "
                    "AppleWebKit/537.36 (KHTML, like Gecko) "
                    "Chrome/122.0.0.0 Safari/537.36"
                ),
                url,
            ]
        )
        return out


def main() -> int:
    url = APPCAST_URL
    if len(sys.argv) > 1 and sys.argv[1].strip():
        url = sys.argv[1].strip()

    xml_bytes = fetch_bytes(url)

    root = ET.fromstring(xml_bytes)
    channel = root.find("./channel")
    if channel is None:
        raise RuntimeError("Invalid appcast: missing channel")

    item = channel.find("./item")
    if item is None:
        raise RuntimeError("Invalid appcast: missing item")

    enclosure = item.find("./enclosure")
    if enclosure is None:
        raise RuntimeError("Invalid appcast: missing enclosure")

    dmg_url = enclosure.attrib.get("url")
    short_version = enclosure.attrib.get("{http://www.andymatuschak.org/xml-namespaces/sparkle}shortVersionString")
    build_version = enclosure.attrib.get("{http://www.andymatuschak.org/xml-namespaces/sparkle}version")
    pub_date_el = item.find("./pubDate")
    pub_date = pub_date_el.text.strip() if pub_date_el is not None and pub_date_el.text else ""

    if not dmg_url or not short_version or not build_version:
        raise RuntimeError("Invalid appcast: missing required version attributes")

    data = {
        "appcast_url": url,
        "dmg_url": dmg_url,
        "short_version": short_version,
        "build_version": str(build_version),
        "pub_date": pub_date,
        "tag_name": f"codex-intel-v{short_version}-{build_version}",
    }
    print(json.dumps(data))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
