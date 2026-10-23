#!/usr/bin/env python3
"""Import a bounded, auditable subset of official LCC outlines (not full schedules).

Requires pypdf. Downloads source PDFs to a cache outside the app; only normalized
JSON is bundled. Chinese translations and candidate keywords are separate app data.
"""
import argparse
import concurrent.futures
import hashlib
import html
import io
import json
import re
import urllib.parse
import urllib.request
from datetime import datetime, timezone
from pathlib import Path
from pypdf import PdfReader

INDEX = "https://www.loc.gov/catdir/cpso/lcco/"
RIGHTS = "https://www.loc.gov/legal/security-copyright-and-privacy/understanding-copyright/"


def fetch(url):
    request = urllib.request.Request(url, headers={"User-Agent": "PointVerse-LCC-Prototype/1.0"})
    with urllib.request.urlopen(request, timeout=60) as response:
        return response.read(), response.headers.get("Last-Modified"), response.geturl()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--cache", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--proxy")
    args = parser.parse_args()
    if args.proxy:
        urllib.request.install_opener(urllib.request.build_opener(urllib.request.ProxyHandler({"http": args.proxy, "https": args.proxy})))
    args.cache.mkdir(parents=True, exist_ok=True)
    page, _, _ = fetch(INDEX)
    anchors = re.findall(r'<a\b[^>]*href=["\']([^"\']+\.pdf)["\'][^>]*>(.*?)</a>', page.decode(), re.I | re.S)
    roots = []
    for href, caption in anchors:
        text = re.sub(r"\s+", " ", html.unescape(re.sub(r"<[^>]+>", "", caption))).strip()
        match = re.match(r"^([A-Z])\s*--\s*(.+)$", text)
        if match:
            roots.append((match[1], match[2], urllib.parse.urljoin(INDEX, href)))
    if len(roots) != 21:
        raise ValueError(f"Expected 21 official main classes, got {len(roots)}; index layout may have changed")

    def download(url):
        data, modified, final_url = fetch(url)
        if not data.startswith(b"%PDF"):
            raise ValueError(f"Not a PDF: {url}")
        filename = Path(urllib.parse.urlparse(url).path).name
        (args.cache / filename).write_bytes(data)
        reader = PdfReader(io.BytesIO(data))
        return url, {
            "url": url, "resolvedURL": final_url, "sha256": hashlib.sha256(data).hexdigest(),
            "lastModified": modified, "pageCount": len(reader.pages),
        }, reader.pages[0].extract_text()

    with concurrent.futures.ThreadPoolExecutor(max_workers=4) as pool:
        downloaded = list(pool.map(download, sorted({item[2] for item in roots})))
    by_url = {url: (metadata, text) for url, metadata, text in downloaded}
    terms = []
    seen = set()
    for code, caption, url in roots:
        terms.append({"id": "lcc:" + code, "code": code, "englishTitle": caption,
                      "parentID": None, "sourceURL": url, "sourcePage": 1, "kind": "main-class"})
        seen.add(code)
        text = by_url[url][1]
        for match in re.finditer(r"Subclass\s+([A-Z]{1,3}(?:-[A-Z]{1,3})?)\s+(.+?)(?=\s*Subclass\s+|\Z)", text, re.S):
            subclass, title = match.groups()
            if subclass in seen or not subclass.startswith(code):
                continue
            title = re.sub(r"\s+", " ", title).strip()
            title = re.sub(r"\s+\d+$", "", title)
            if not title or "LIBRARY OF CONGRESS" in title:
                raise ValueError(f"Unexpected heading: {subclass} {title}")
            terms.append({"id": "lcc:" + subclass, "code": subclass, "englishTitle": title,
                          "parentID": "lcc:" + code, "sourceURL": url, "sourcePage": 1, "kind": "subclass"})
            seen.add(subclass)

    # Explicit curated parent links from page 3 of Q; never infer ranges by truncating codes.
    computer_path = [
        ("QA71-90", "Instruments and machines", "QA"),
        ("QA75-76.95", "Calculating machines", "QA71-90"),
        ("QA75.5-76.95", "Electronic computers. Computer science", "QA75-76.95"),
        ("QA76.75-76.765", "Computer software", "QA75.5-76.95"),
    ]
    q_url = next(url for code, _, url in roots if code == "Q")
    q_reader = PdfReader(args.cache / Path(urllib.parse.urlparse(q_url).path).name)
    q_text = re.sub(r"\s+", " ", q_reader.pages[2].extract_text())
    for code, caption, parent in computer_path:
        if code not in q_text or caption not in q_text:
            raise ValueError(f"Q outline no longer contains expected computer heading: {code}")
        terms.append({"id": "lcc:" + code, "code": code, "englishTitle": caption,
                      "parentID": "lcc:" + parent, "sourceURL": q_url, "sourcePage": 3, "kind": "selected-range"})

    ids = {term["id"] for term in terms}
    if len(ids) != len(terms) or any(term["parentID"] and term["parentID"] not in ids for term in terms):
        raise ValueError("Duplicate IDs or orphan parent")
    result = {
        "schemaVersion": 1, "scheme": "LCC", "snapshotID": "loc-lcco-retrieved-" + datetime.now(timezone.utc).date().isoformat(),
        "retrievedAt": datetime.now(timezone.utc).isoformat(), "indexURL": INDEX, "rightsURL": RIGHTS,
        "coverage": "21 main classes; subclasses explicitly listed on the first page of each outline; four selected computer ranges. Not complete schedules or a current full LCC release.",
        "sources": [metadata for _, metadata, _ in downloaded], "terms": terms,
    }
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(result, ensure_ascii=False, indent=2) + "\n")
    print(f"Imported {len(terms)} terms from {len(downloaded)} official PDFs to {args.output}")
    print("\n".join(f'{t["code"]}\t{t["englishTitle"]}' for t in terms))


if __name__ == "__main__":
    main()
