#!/usr/bin/env python3 -I
"""Crawl a TRAINING set of US fleet-vehicle photos from Wikimedia Commons category trees.

Usage: python3 -I scripts/crawl_commons_fleet.py <out dir> [--cap 300] [--depth 2]
Writes <out>/<class>/*.jpg and <out>/manifest.json (source page, licence, author per file).

Rules (docs/MODEL-TRAINING.md §0):
  * Only CC0 / public domain / CC BY are kept — CC BY-SA, NC and ND are NOT used for training.
  * Anything whose title appears in eval/manifest.json is skipped: eval images never train.
  * One polite request per second; descriptive User-Agent.
"""
import json, os, re, sys, time, html, urllib.parse, urllib.request

UA = "PlateWatch-training-crawl/0.1 (https://github.com/noktirnal42/PlateWatch; CC-licensed training data)"
API = "https://commons.wikimedia.org/w/api.php"
CLASSES = {
    "police":  ["Category:Police vehicles of the United States"],
    "fire":    ["Category:Fire engines of the United States", "Category:Red fire engines of the United States",
                "Category:Seagrave Fire Apparatus"],
    "ems":     ["Category:Ambulances in the United States"],
    "transit": ["Category:Transit buses in the United States", "Category:School buses in the United States"],
    "public":  ["Category:National Park Service Ranger vehicles", "Category:United States Post Office Department vehicles",
                "Category:Postal vehicles of the United States", "Category:Garbage trucks of the United States"],
    "civilian": ["Category:Black pickup trucks in the United States", "Category:Blue pickup trucks in the United States",
                 "Category:Orange pickup trucks in the United States", "Category:Taxis in New York City",
                 "Category:Cars of the United States"],
}
OK_LICENSE = re.compile(r"^(cc0|pd\b|public domain|cc[- ]by[- ]\d)", re.I)       # BY only; -SA excluded
args = sys.argv
out = args[1]
cap = int(args[args.index("--cap") + 1]) if "--cap" in args else 300
depth = int(args[args.index("--depth") + 1]) if "--depth" in args else 2
here = os.path.dirname(os.path.abspath(__file__))
eval_titles = set()
try:
    for e in json.load(open(os.path.join(here, "..", "eval", "manifest.json"))):
        eval_titles.add(e["title"])
except Exception: pass

def get(params):
    params["format"] = "json"
    for attempt in range(4):
        try:
            with urllib.request.urlopen(urllib.request.Request(API + "?" + urllib.parse.urlencode(params), headers={"User-Agent": UA}), timeout=60) as r:
                return json.load(r)
        except Exception: time.sleep(2 * (attempt + 1))
    return {}

def members(cat, kind):
    token = None; out = []
    while True:
        p = {"action": "query", "list": "categorymembers", "cmtitle": cat, "cmtype": kind, "cmlimit": 500}
        if token: p["cmcontinue"] = token
        d = get(p); out += [m["title"] for m in d.get("query", {}).get("categorymembers", [])]
        token = d.get("continue", {}).get("cmcontinue")
        if not token or len(out) > 3000: return out

def crawl_titles(seeds):
    seen_cats, files, frontier = set(), [], [(s, 0) for s in seeds]
    while frontier and len(files) < cap * 6:
        cat, d = frontier.pop(0)
        if cat in seen_cats: continue
        seen_cats.add(cat)
        files += members(cat, "file")
        if d < depth: frontier += [(c, d + 1) for c in members(cat, "subcat")]
    return list(dict.fromkeys(files))

def strip(s): return html.unescape(re.sub(r"<[^>]+>", "", s or "")).strip()

os.makedirs(out, exist_ok=True)
manifest = []
for cls, seeds in CLASSES.items():
    os.makedirs(os.path.join(out, cls), exist_ok=True)
    titles = [t for t in crawl_titles(seeds) if t not in eval_titles and re.search(r"\.jpe?g$", t, re.I)]
    kept = 0
    for i in range(0, len(titles), 40):
        if kept >= cap: break
        d = get({"action": "query", "titles": "|".join(titles[i:i + 40]), "prop": "imageinfo",
                 "iiprop": "url|size|mime|extmetadata", "iiurlwidth": 1024})
        for page in (d.get("query", {}).get("pages") or {}).values():
            if kept >= cap: break
            ii = (page.get("imageinfo") or [{}])[0]
            meta = ii.get("extmetadata") or {}
            lic = strip((meta.get("LicenseShortName") or {}).get("value"))
            if ii.get("mime") != "image/jpeg" or (ii.get("width") or 0) < 600 or not OK_LICENSE.match(lic.replace("CC BY", "CC-BY")): continue
            fname = re.sub(r"[^A-Za-z0-9._-]+", "_", page["title"].replace("File:", ""))[:90]
            dest = os.path.join(out, cls, fname)
            try:
                with urllib.request.urlopen(urllib.request.Request(ii.get("thumburl") or ii["url"], headers={"User-Agent": UA}), timeout=90) as r:
                    open(dest, "wb").write(r.read())
            except Exception: continue
            time.sleep(1.0)
            kept += 1
            manifest.append({"file": f"{cls}/{fname}", "class": cls, "title": page["title"], "sourcePage": ii.get("descriptionurl"),
                             "license": lic, "author": strip((meta.get("Artist") or {}).get("value"))[:120]})
    print(f"{cls:9s} candidates={len(titles):5d} kept={kept}", flush=True)
json.dump(manifest, open(os.path.join(out, "manifest.json"), "w"), indent=1, ensure_ascii=False)
print("total", len(manifest))
