#!/usr/bin/env python3
"""Re-download any missing eval/corpus images listed in eval/manifest.json (same 1600 px thumbnails that
fetch_corpus.py used), by Commons file title. Use after the corpus directory was lost or on a fresh clone.

Usage: python3 eval/restore_corpus.py [--eval-dir eval]
Polite: one request per second, descriptive User-Agent. Images stay gitignored (licensed per manifest; may show plates).
"""
import argparse, json, os, sys, time, urllib.parse, urllib.request

UA = "PlateWatch-QA/0.1 (https://github.com/noktirnal42/PlateWatch; restoring evaluation corpus)"
API = "https://commons.wikimedia.org/w/api.php"

def get_json(params):
    url = API + "?" + urllib.parse.urlencode(params)
    for attempt in range(4):
        try:
            with urllib.request.urlopen(urllib.request.Request(url, headers={"User-Agent": UA}), timeout=60) as r:
                return json.load(r)
        except Exception:
            time.sleep(2 * (attempt + 1))
    return {}

ap = argparse.ArgumentParser(); ap.add_argument("--eval-dir", default="eval"); args = ap.parse_args()
manifest = json.load(open(os.path.join(args.eval_dir, "manifest.json")))
missing = [e for e in manifest if not os.path.exists(os.path.join(args.eval_dir, e["file"]))]
print(f"{len(missing)} of {len(manifest)} images missing")
restored = failed = 0
for e in missing:
    data = get_json({"action": "query", "titles": e["title"], "prop": "imageinfo", "iiprop": "url|mime",
                     "iiurlwidth": 1600, "redirects": 1, "format": "json"})
    page = next(iter((data.get("query", {}).get("pages") or {}).values()), {})
    info = (page.get("imageinfo") or [{}])[0]
    url = info.get("thumburl") or info.get("url")
    if not url:
        print("  no url for", e["title"]); failed += 1; continue
    dest = os.path.join(args.eval_dir, e["file"])
    os.makedirs(os.path.dirname(dest), exist_ok=True)
    try:
        with urllib.request.urlopen(urllib.request.Request(url, headers={"User-Agent": UA}), timeout=90) as r:
            open(dest, "wb").write(r.read())
        restored += 1
    except Exception as ex:
        print("  failed", e["title"], ex); failed += 1
    time.sleep(1.0)
print(f"restored {restored}, failed {failed}")
sys.exit(1 if failed else 0)
