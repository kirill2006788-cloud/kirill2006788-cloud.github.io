"""Build an editable 1:1 copy of trezv777.ru from the local mirror.

Steps:
  1. Read the mirror HTML from trezv777_site/index.html.
  2. Strip analytics/tracking (GTM, Yandex.Metrika, tilda-stat, tildacopy).
  3. Reuse the original assets from trezv777_site/assets via a shared path.
  4. Pretty-print the resulting HTML so a human can edit it section by section.
  5. Write the result to trezv777_site_editable/index.html.
"""

from __future__ import annotations

import re
from pathlib import Path

from bs4 import BeautifulSoup, Comment

ROOT = Path(__file__).resolve().parents[1]
SRC = ROOT / "trezv777_site" / "index.html"
DST_DIR = ROOT / "trezv777_site_editable"
DST = DST_DIR / "index.html"

TRACKER_PATTERNS = (
    "googletagmanager",
    "mc.yandex.ru/metrika",
    "tilda-stat",
    "gtag(",
    "gtm.start",
    "ym(",
    "window.mainMetrikaId",
    "window.tildastatcookie",
    "GTM-",
)


def looks_like_tracker(script_text: str) -> bool:
    text = script_text or ""
    return any(marker in text for marker in TRACKER_PATTERNS)


def main() -> None:
    html = SRC.read_text(encoding="utf-8", errors="ignore")
    soup = BeautifulSoup(html, "html.parser")

    # Point all local files to the shared assets folder so we don't duplicate data.
    for node in soup.find_all(src=True):
        src = node.get("src", "")
        if src.startswith("./assets/"):
            node["src"] = "../trezv777_site/" + src[2:]
    for node in soup.find_all(href=True):
        href = node.get("href", "")
        if href.startswith("./assets/"):
            node["href"] = "../trezv777_site/" + href[2:]

    # Remove tracking scripts.
    for script in soup.find_all("script"):
        src = script.get("src", "") or ""
        if any(marker in src for marker in TRACKER_PATTERNS):
            script.decompose()
            continue
        if looks_like_tracker(script.string or script.text):
            script.decompose()

    for noscript in soup.find_all("noscript"):
        text = noscript.decode_contents()
        if any(marker in text for marker in TRACKER_PATTERNS):
            noscript.decompose()

    # Remove Tilda copyright badge if it was re-inserted.
    for node in soup.select("#tildacopy, .t-tildalabel"):
        node.decompose()

    # Remove Tilda "save from url" comment and similar cruft.
    for comment in soup.find_all(string=lambda value: isinstance(value, Comment)):
        text = comment.strip()
        if text.startswith("saved from url") or "Yandex.Metrika" in text or "Google Tag Manager" in text:
            comment.extract()

    pretty = soup.prettify(formatter="html5")

    # BeautifulSoup prettify can leave odd whitespace inside scripts; collapse 3+ blank lines.
    pretty = re.sub(r"\n{3,}", "\n\n", pretty)

    DST_DIR.mkdir(parents=True, exist_ok=True)
    DST.write_text(pretty, encoding="utf-8", newline="\n")
    print(f"written: {DST}")
    print(f"size: {DST.stat().st_size} bytes")


if __name__ == "__main__":
    main()
