#!/usr/bin/env python3
"""Fetch Codex appcast metadata and print latest DMG details as JSON."""

from __future__ import annotations

import json
import sys
import urllib.request
import xml.etree.ElementTree as ET

APPCAST_URL = "https://persistent.oaistatic.com/codex-app-prod/appcast.xml"
SPARKLE_NS = {"sparkle": "http://www.andymatuschak.org/xml-namespaces/sparkle"}


def main() -> int:
    url = APPCAST_URL
    if len(sys.argv) > 1 and sys.argv[1].strip():
        url = sys.argv[1].strip()

    with urllib.request.urlopen(url, timeout=30) as resp:
        xml_bytes = resp.read()

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
