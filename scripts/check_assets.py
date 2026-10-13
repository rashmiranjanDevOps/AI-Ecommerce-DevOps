#!/usr/bin/env python3
"""Check that every local file referenced by the Nexvion pages exists, and list external resources.

Usage: check_assets.py [application_dir]
Exit code 1 if a local reference is broken. External resources are only reported
(they are the site's third-party dependencies: fonts, images).
"""
import re
import sys
from collections import Counter
from html.parser import HTMLParser
from pathlib import Path
from urllib.parse import urlparse

root = Path(sys.argv[1] if len(sys.argv) > 1 else "application").resolve()


class Refs(HTMLParser):
    def __init__(self):
        super().__init__()
        self.refs = []

    def handle_starttag(self, tag, attrs):
        a = dict(attrs)
        for key in ("href", "src"):
            if a.get(key):
                self.refs.append((tag, a[key]))


missing, external = [], Counter()


def classify(source, ref):
    ref = ref.strip()
    if not ref or ref.startswith(("#", "mailto:", "tel:", "javascript:", "data:")):
        return
    parsed = urlparse(ref)
    if parsed.scheme in ("http", "https") or ref.startswith("//"):
        external[parsed.netloc or ref] += 1
        return
    target = (source.parent / parsed.path).resolve()
    if parsed.path and not target.exists():
        missing.append(f"{source.name}: {ref}")


pages = sorted(root.glob("*.html"))
if not pages:
    print(f"No HTML files found in {root}")
    sys.exit(1)

for page in pages:
    p = Refs()
    p.feed(page.read_text(encoding="utf-8", errors="replace"))
    for _, ref in p.refs:
        classify(page, ref)

for css in sorted(root.glob("*.css")):
    for ref in re.findall(r"url\(['\"]?([^'\")]+)['\"]?\)", css.read_text(encoding="utf-8", errors="replace")):
        classify(css, ref)

for js in sorted(root.glob("*.js")):
    text = js.read_text(encoding="utf-8", errors="replace")
    for ref in re.findall(r"https?://[^\s'\"`)]+", text):
        classify(js, ref)

print(f"Pages checked : {', '.join(p.name for p in pages)}")
print("External resources used by the site (third-party dependencies):")
for host, count in external.most_common():
    print(f"  {host:35s} {count} reference(s)")
if missing:
    print("\nBROKEN LOCAL REFERENCES:")
    for m in missing:
        print("  -", m)
    sys.exit(1)
print("\nAll local references exist.")
