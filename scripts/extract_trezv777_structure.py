from __future__ import annotations

import html
import json
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / "trezv777_site" / "index.html"
OUTPUT = ROOT / "docs" / "trezv777_structure.json"
TEXT_OUTPUT = ROOT / "docs" / "trezv777_text_dump.txt"


def clean_text(value: str) -> str:
    text = html.unescape(re.sub(r"<[^>]+>", " ", value))
    text = re.sub(r"\s+", " ", text).strip()
    return text


def unique_clean(items: list[str], min_len: int = 1) -> list[str]:
    seen: set[str] = set()
    result: list[str] = []
    for item in items:
        cleaned = clean_text(item)
        if len(cleaned) < min_len:
            continue
        if cleaned in seen:
            continue
        seen.add(cleaned)
        result.append(cleaned)
    return result


def main() -> None:
    source = SOURCE.read_text(encoding="utf-8", errors="ignore")

    menu_matches = re.findall(
        r'<a class="t-menu__link-item[^\"]*" href="([^"]+)"[^>]*>(.*?)</a>',
        source,
        re.S,
    )
    menu = [
        {
            "href": href,
            "label": clean_text(label),
        }
        for href, label in menu_matches
        if clean_text(label)
    ]

    section_ids = re.findall(r'<div id="(rec\d+)"', source)
    section_matches = re.findall(r'(<div id="(rec\d+)".*?)(?=<div id="rec\d+"|<!--/allrecords-->)', source, re.S)
    form_ids = re.findall(r'<form[^>]+id="([^"]+)"', source)
    phone_links = sorted(set(re.findall(r'href="tel: ?([^"]+)"', source)))
    whatsapp_links = sorted(set(re.findall(r'href="(https://wa.me/[^"]+)"', source)))
    telegram_links = sorted(set(re.findall(r'href="(https://t.me/[^"]+)"', source)))
    headings = unique_clean(re.findall(r'<h[1-3][^>]*>(.*?)</h[1-3]>', source, re.S), min_len=2)
    buttons = unique_clean(
        re.findall(r'<a[^>]*class="[^"]*t-btn[^"]*"[^>]*>(.*?)</a>', source, re.S)
        + re.findall(r'<button[^>]*>(.*?)</button>', source, re.S),
        min_len=2,
    )
    paragraph_like = unique_clean(
        re.findall(r'<p[^>]*>(.*?)</p>', source, re.S)
        + re.findall(r'<div[^>]+field="text"[^>]*>(.*?)</div>', source, re.S)
        + re.findall(r'<div[^>]+field="descr"[^>]*>(.*?)</div>', source, re.S),
        min_len=10,
    )
    sections = {
        section_id: unique_clean(re.findall(r'<(?:h[1-6]|p|li|a|span|div)[^>]*>(.*?)</(?:h[1-6]|p|li|a|span|div)>', block, re.S), min_len=2)
        for block, section_id in section_matches
    }

    result = {
        "source": str(SOURCE),
        "sectionCount": len(section_ids),
        "sectionIds": section_ids,
        "menu": menu,
        "formIds": form_ids,
        "phones": phone_links,
        "whatsapp": whatsapp_links,
        "telegram": telegram_links,
        "headings": headings,
        "buttons": buttons,
        "paragraphs": paragraph_like,
        "sections": sections,
    }

    OUTPUT.parent.mkdir(parents=True, exist_ok=True)
    OUTPUT.write_text(json.dumps(result, ensure_ascii=False, indent=2), encoding="utf-8")
    TEXT_OUTPUT.write_text(
        "\n".join(
            [
                "# MENU",
                *[f"- {item['label']} -> {item['href']}" for item in menu],
                "",
                "# HEADINGS",
                *[f"- {item}" for item in headings],
                "",
                "# BUTTONS",
                *[f"- {item}" for item in buttons],
                "",
                "# PARAGRAPHS",
                *[f"- {item}" for item in paragraph_like],
                "",
                "# SECTIONS",
                *[
                    "\n".join([f"## {section_id}", *[f"- {item}" for item in items], ""])
                    for section_id, items in sections.items()
                ],
            ]
        ),
        encoding="utf-8",
    )
    print(OUTPUT)
    print(json.dumps(result, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
