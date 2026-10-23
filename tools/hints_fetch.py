"""Downloads guide pages listed in a local sources file for paraphrasing.

Each source line is "<qid> <url>". Pages are saved as reference/hints/<qid>/<n>.html
with the page's visible text beside it as <n>.txt. Standard library only.
"""
import argparse
import os
import re
import sys
import urllib.parse
import urllib.request
from html.parser import HTMLParser

USER_AGENT = "Mozilla/5.0 (compatible; hint-research/1.0)"
TIMEOUT = 30
SKIP = {"script", "style", "noscript", "template", "head"}
MAX_BYTES = 5 * 1024 * 1024
BREAK = {"br", "p", "div", "li", "tr", "h1", "h2", "h3", "h4"}


class _Text(HTMLParser):
    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.parts = []
        self.depth = 0

    def handle_starttag(self, tag, attrs):
        if tag in SKIP:
            self.depth += 1
        elif tag in BREAK:
            self.parts.append("\n")

    def handle_endtag(self, tag):
        if tag in SKIP and self.depth > 0:
            self.depth -= 1

    def handle_data(self, data):
        if self.depth == 0:
            self.parts.append(data)


def visible_text(html):
    p = _Text()
    p.feed(html)
    lines = (" ".join(s.split()) for s in "".join(p.parts).splitlines())
    return "\n".join(s for s in lines if s) + "\n"


def parse_sources(text):
    """Yields (qid, url) for each non-blank, non-comment line."""
    for raw in text.splitlines():
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        parts = line.split()
        if len(parts) != 2:
            raise ValueError("bad source line: %r" % raw)
        if not re.fullmatch(r"[0-9]+", parts[0]):
            raise ValueError("bad qid: %r" % parts[0])
        yield parts[0], parts[1]


def _check_scheme(url):
    if urllib.parse.urlsplit(url).scheme.lower() not in ("http", "https"):
        raise ValueError("not an http(s) url")


class _SafeRedirect(urllib.request.HTTPRedirectHandler):
    """Refuses redirects to anything but http(s)."""

    def redirect_request(self, req, fp, code, msg, headers, newurl):
        _check_scheme(newurl)
        return super().redirect_request(req, fp, code, msg, headers, newurl)


def fetch(url):
    _check_scheme(url)
    req = urllib.request.Request(url, headers={"User-Agent": USER_AGENT})
    opener = urllib.request.build_opener(_SafeRedirect)
    with opener.open(req, timeout=TIMEOUT) as r:
        charset = r.headers.get_content_charset() or "utf-8"
        return r.read(MAX_BYTES).decode(charset, errors="replace")


def main(argv=None):
    ap = argparse.ArgumentParser()
    ap.add_argument("--sources", default="tools/hint_sources.local.txt")
    ap.add_argument("--out", default="reference/hints")
    args = ap.parse_args(argv)
    with open(args.sources, encoding="utf-8") as f:
        sources = list(parse_sources(f.read()))
    counts = {}
    bad = 0
    for qid, url in sources:
        n = counts.get(qid, 0) + 1
        counts[qid] = n
        d = os.path.join(args.out, qid)
        os.makedirs(d, exist_ok=True)
        try:
            html = fetch(url)
        except Exception as e:
            print("hints_fetch: qid %s #%d failed: %s" % (qid, n, e))
            bad += 1
            continue
        with open(os.path.join(d, "%d.html" % n), "w", encoding="utf-8", newline="\n") as f:
            f.write(html)
        with open(os.path.join(d, "%d.txt" % n), "w", encoding="utf-8", newline="\n") as f:
            f.write(visible_text(html))
        print("hints_fetch: qid %s #%d saved" % (qid, n))
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
