#!/usr/bin/env python3
"""Fetch Codex appcast metadata and print latest DMG details as JSON."""

from __future__ import annotations

import json
import logging
import os
import subprocess
import sys
import urllib.request
import xml.etree.ElementTree as ET

APPCAST_URL = "https://persistent.oaistatic.com/codex-app-prod/appcast.xml"
SPARKLE_NS = {"sparkle": "http://www.andymatuschak.org/xml-namespaces/sparkle"}
SPARKLE_URI = "http://www.andymatuschak.org/xml-namespaces/sparkle"


def setup_logger() -> logging.Logger:
    logger = logging.getLogger("check_upstream")
    if logger.handlers:
        return logger

    level_name = os.getenv("CHECK_UPSTREAM_LOG_LEVEL", "WARNING").strip().upper()
    level = getattr(logging, level_name, logging.WARNING)
    logger.setLevel(level)

    handler = logging.StreamHandler(sys.stderr)
    handler.setFormatter(logging.Formatter("[%(name)s][%(levelname)s] %(message)s"))
    logger.addHandler(handler)
    logger.propagate = False
    return logger


LOGGER = setup_logger()


def sanitize_snippet(text: str, limit: int = 400) -> str:
    compact = " ".join(text.split())
    if len(compact) <= limit:
        return compact
    return compact[: limit - 3] + "..."


def xml_text(el: ET.Element | None) -> str | None:
    if el is None or el.text is None:
        return None
    value = el.text.strip()
    return value if value else None


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
        LOGGER.debug("Fetching appcast via urllib: %s", url)
        with urllib.request.urlopen(req, timeout=30) as resp:
            data = resp.read()
            LOGGER.debug(
                "urllib fetch success: status=%s bytes=%s",
                getattr(resp, "status", "unknown"),
                len(data),
            )
            return data
    except Exception as exc:
        LOGGER.debug("urllib fetch failed (%s): %s; falling back to curl", type(exc).__name__, exc)
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
        LOGGER.debug("curl fetch success: bytes=%s", len(out))
        return out


def main() -> int:
    url = APPCAST_URL
    if len(sys.argv) > 1 and sys.argv[1].strip():
        url = sys.argv[1].strip()

    xml_bytes = fetch_bytes(url)

    LOGGER.debug("Received XML payload: bytes=%s", len(xml_bytes))
    if LOGGER.isEnabledFor(logging.DEBUG):
        try:
            xml_content = xml_bytes.decode("utf-8", errors="replace")
            LOGGER.debug("XML snippet: %s", sanitize_snippet(xml_content))
        except Exception as exc:
            LOGGER.debug("Could not decode XML snippet: %s: %s", type(exc).__name__, exc)

    root = ET.fromstring(xml_bytes)
    LOGGER.debug("Root tag: %s", root.tag)
    channel = root.find("./channel")
    if channel is None:
        raise RuntimeError("Invalid appcast: missing channel")
    LOGGER.debug("Found channel element")

    item = channel.find("./item")
    if item is None:
        raise RuntimeError("Invalid appcast: missing item")
    LOGGER.debug("Found first item element")

    enclosure = item.find("./enclosure")
    if enclosure is None:
        raise RuntimeError("Invalid appcast: missing enclosure")
    LOGGER.debug("Found enclosure element")
    LOGGER.debug("Enclosure attrs keys: %s", sorted(enclosure.attrib.keys()))

    dmg_url = enclosure.attrib.get("url")
    # Newer appcast puts version values on <item> as sparkle:* elements.
    short_version = xml_text(item.find("./sparkle:shortVersionString", SPARKLE_NS)) or enclosure.attrib.get(
        f"{{{SPARKLE_URI}}}shortVersionString"
    )
    build_version = xml_text(item.find("./sparkle:version", SPARKLE_NS)) or enclosure.attrib.get(
        f"{{{SPARKLE_URI}}}version"
    )
    pub_date_el = item.find("./pubDate")
    pub_date = pub_date_el.text.strip() if pub_date_el is not None and pub_date_el.text else ""

    if not dmg_url or not short_version or not build_version:
        LOGGER.debug("Resolved dmg_url=%r", dmg_url)
        LOGGER.debug("Resolved short_version=%r", short_version)
        LOGGER.debug("Resolved build_version=%r", build_version)
        LOGGER.debug("Item children tags: %s", [child.tag for child in list(item)])
        if LOGGER.isEnabledFor(logging.DEBUG):
            for key, value in enclosure.attrib.items():
                LOGGER.debug("Enclosure attr: %s=%r", key, value)
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
