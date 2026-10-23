#!/usr/bin/env python3 -I
"""Crawl a TRAINING set of US licence-plate images, labelled by issuing state, from Wikimedia Commons.

Usage: python3 -I scripts/crawl_commons_plates.py <out dir> [--cap 120] [--depth 1] [--allow-sa]
  --allow-sa  also keep CC BY-SA files (owner decision 2026-10-13, for the plate-state classifier ONLY).
              Resumes: files already in <out dir> are kept and not downloaded again.
Writes <out>/<State>/*.jpg|png and <out>/manifest.json (source page, licence, author per file).

Purpose: a plate-DESIGN classifier (Create ML Image Classification, one class per state) — Apple Vision
cannot read small cursive state banners ("Minnesota"), so the state has to come from the plate's look.
Rules (docs/MODEL-TRAINING.md §0): only CC0 / public domain / CC BY are kept (BY-SA/NC/ND are not used for
training); one request per second; descriptive User-Agent. Historic plates (titles naming a year before
1990) are skipped — they are not what is on the road. The manifest is rewritten after every state.
"""
import json, os, re, sys, time, html, urllib.parse, urllib.request

UA = "PlateWatch-training-crawl/0.1 (https://github.com/noktirnal42/PlateWatch; CC-licensed training data)"
API = "https://commons.wikimedia.org/w/api.php"
ROOT = "Category:License plates of the United States by state"
ALLOW_SA = "--allow-sa" in sys.argv
OK_LICENSE = re.compile(r"^(cc0|pd\b|public domain|cc[- ]by[- ]\d" + (r"|cc[- ]by[- ]sa[- ]\d" if ALLOW_SA else "") + ")", re.I)
OLD_YEAR = re.compile(r"\b(1[0-8]\d\d|19[0-8]\d)\b")
SKIP_TITLE = re.compile(r"trailer|motorcycle|temporary|dealer|sample|specimen", re.I)
args = sys.argv
out = args[1]
cap = int(args[args.index("--cap") + 1]) if "--cap" in args else 120
DEPTH = int(args[args.index("--depth") + 1]) if "--depth" in args else 1

def get(params):
    params["format"] = "json"
    for attempt in range(4):
        try:
            with urllib.request.urlopen(urllib.request.Request(API + "?" + urllib.parse.urlencode(params), headers={"User-Agent": UA}), timeout=60) as r:
                return json.load(r)
        except Exception: time.sleep(2 * (attempt + 1))
    return {}

def members(cat, kind):
    token = None; res = []
    while True:
        p = {"action": "query", "list": "categorymembers", "cmtitle": cat, "cmtype": kind, "cmlimit": 500}
        if token: p["cmcontinue"] = token
        d = get(p); res += [m["title"] for m in d.get("query", {}).get("categorymembers", [])]
        token = d.get("continue", {}).get("cmcontinue")
        if not token or len(res) > 2000: return res

def strip(s): return html.unescape(re.sub(r"<[^>]+>", "", s or "")).strip()

def state_name(cat):
    n = re.sub(r"^Category:(License plates|Vehicle registration plates) of (the )?", "", cat)
    return re.sub(r" \((U\.S\. )?state\)$", "", n)

states = [c for c in members(ROOT, "subcat")
          if re.match(r"Category:(License plates|Vehicle registration plates) of ", c)
          and not re.search(r"Samoa|Canal Zone|Guam|Mariana|Puerto Rico|Virgin Islands", c)]
os.makedirs(out, exist_ok=True)
mpath = os.path.join(out, "manifest.json")
manifest = json.load(open(mpath)) if os.path.exists(mpath) else []
have = {m["file"] for m in manifest}
for cat in states:
    state = state_name(cat)
    os.makedirs(os.path.join(out, state), exist_ok=True)
    titles = members(cat, "file")
    # Subcategories (by plate series, by year, by vehicle) breadth-first down to --depth levels (default 1).
    frontier, seen_cats = [cat], {cat}
    for _ in range(DEPTH):
        nxt = []
        for parent in frontier:
            for sub in members(parent, "subcat"):
                if sub in seen_cats or SKIP_TITLE.search(sub) or OLD_YEAR.search(sub): continue
                seen_cats.add(sub); nxt.append(sub)
                titles += members(sub, "file")
                time.sleep(0.3)
        frontier = nxt
    titles = [t for t in dict.fromkeys(titles)
              if re.search(r"\.(jpe?g|png)$", t, re.I) and not OLD_YEAR.search(t) and not SKIP_TITLE.search(t)]
    kept = sum(1 for m in manifest if m["class"] == state)
    for i in range(0, len(titles), 40):
        if kept >= cap: break
        d = get({"action": "query", "titles": "|".join(titles[i:i + 40]), "prop": "imageinfo",
                 "iiprop": "url|size|mime|extmetadata", "iiurlwidth": 800})
        for page in (d.get("query", {}).get("pages") or {}).values():
            if kept >= cap: break
            ii = (page.get("imageinfo") or [{}])[0]
            meta = ii.get("extmetadata") or {}
            lic = strip((meta.get("LicenseShortName") or {}).get("value"))
            if ii.get("mime") not in ("image/jpeg", "image/png") or (ii.get("width") or 0) < 250 \
                    or not OK_LICENSE.match(lic.replace("CC BY", "CC-BY")): continue
            fname = re.sub(r"[^A-Za-z0-9._-]+", "_", page["title"].replace("File:", ""))[:90]
            dest = os.path.join(out, state, fname)
            if f"{state}/{fname}" in have: continue
            try:
                with urllib.request.urlopen(urllib.request.Request(ii.get("thumburl") or ii["url"], headers={"User-Agent": UA}), timeout=90) as r:
                    open(dest, "wb").write(r.read())
            except Exception: continue
            time.sleep(1.0)
            kept += 1
            manifest.append({"file": f"{state}/{fname}", "class": state, "title": page["title"], "sourcePage": ii.get("descriptionurl"),
                             "license": lic, "author": strip((meta.get("Artist") or {}).get("value"))[:120]})
    print(f"{state:22s} candidates={len(titles):4d} kept={kept}", flush=True)
    json.dump(manifest, open(os.path.join(out, "manifest.json"), "w"), indent=1, ensure_ascii=False)
print("total", len(manifest))
