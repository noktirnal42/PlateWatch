#!/usr/bin/env python3
"""Fetch a labelled evaluation corpus of US vehicle photos from Wikimedia Commons.

Only CC0 / public-domain / CC-BY / CC-BY-SA files are kept; each image's license,
author and source page are recorded in eval/manifest.json. Images are written to
eval/corpus/ (gitignored: civilian plates may be visible), only the manifest is
committed. Usage: python3 eval/fetch_corpus.py [--per-query N]
"""
import argparse, html, json, os, re, sys, time, urllib.parse, urllib.request

UA = "PlateWatch-QA/0.1 (https://github.com/noktirnal42/PlateWatch; evaluation corpus)"
API = "https://commons.wikimedia.org/w/api.php"
ROOT = os.path.dirname(os.path.abspath(__file__))
OK_LICENSE = re.compile(r"^(cc0|pd|public domain|cc[- ]by(-sa)?[- ]\d|cc[- ]by(-sa)?$)", re.I)

# (class label, expected_fleet, search queries)
QUERIES = [
    ("police",   True,  ["police car United States", "Ford Police Interceptor Utility", "Ford Crown Victoria Police Interceptor",
                         "Dodge Charger Pursuit police", "Chevrolet Tahoe police", "police cruiser rear license plate United States",
                         "city police department patrol car USA"]),
    ("sheriff",  True,  ["sheriff patrol car United States", "county sheriff's office vehicle", "state highway patrol car"]),
    ("fire",     True,  ["fire engine United States", "fire department ladder truck USA", "fire department chief SUV"]),
    ("ems",      True,  ["ambulance United States", "EMS paramedic ambulance USA"]),
    ("transit",  True,  ["city transit bus United States", "school bus United States", "Metro bus USA"]),
    ("public",   True,  ["USPS mail truck", "city public works truck United States", "municipal garbage truck USA", "National Park Service vehicle"]),
    ("civilian", False, ["Toyota Camry parked street United States", "Ford F-150 pickup parked", "Honda Civic parked license plate",
                         "Tesla Model 3 parked", "Chevrolet Silverado parked", "minivan parked street USA", "taxi cab New York"]),
]

def get(params):
    url = API + "?" + urllib.parse.urlencode(params)
    for attempt in range(4):
        try:
            with urllib.request.urlopen(urllib.request.Request(url, headers={"User-Agent": UA}), timeout=60) as r:
                return json.load(r)
        except Exception as e:
            time.sleep(2 * (attempt + 1))
    return {}

def strip(s):
    return html.unescape(re.sub(r"<[^>]+>", "", s or "")).strip()

def search(query, limit):
    data = get({"action": "query", "generator": "search", "gsrsearch": query + " filetype:bitmap",
                "gsrnamespace": 6, "gsrlimit": limit, "prop": "imageinfo",
                "iiprop": "url|size|mime|extmetadata", "iiurlwidth": 1600, "format": "json"})
    return list((data.get("query", {}).get("pages") or {}).values())

def main():
    ap = argparse.ArgumentParser(); ap.add_argument("--per-query", type=int, default=6)
    args = ap.parse_args()
    manifest, seen = [], set()
    for label, fleet, queries in QUERIES:
        os.makedirs(os.path.join(ROOT, "corpus", label), exist_ok=True)
        for q in queries:
            kept = 0
            for page in sorted(search(q, 30), key=lambda p: p.get("index", 0)):
                if kept >= args.per_query: break
                info = (page.get("imageinfo") or [{}])[0]
                title = page.get("title", "")
                if title in seen or info.get("mime") != "image/jpeg": continue
                if (info.get("width") or 0) < 1200 or (info.get("height") or 0) < 700: continue
                meta = info.get("extmetadata") or {}
                lic = strip((meta.get("LicenseShortName") or {}).get("value"))
                if not OK_LICENSE.match(lic.replace("CC BY", "CC-BY").replace("CC0", "cc0")) and "public domain" not in lic.lower() and not lic.lower().startswith("pd"):
                    continue
                url = info.get("thumburl") or info.get("url")
                fname = re.sub(r"[^A-Za-z0-9._-]+", "_", title.replace("File:", ""))[:90]
                dest = os.path.join(ROOT, "corpus", label, fname)
                if not os.path.exists(dest):
                    try:
                        with urllib.request.urlopen(urllib.request.Request(url, headers={"User-Agent": UA}), timeout=90) as r:
                            open(dest, "wb").write(r.read())
                    except Exception as e:
                        print("  skip", title, e); continue
                    time.sleep(1.0)
                seen.add(title); kept += 1
                manifest.append({"file": f"corpus/{label}/{fname}", "class": label, "expectedFleet": fleet,
                                 "title": title, "sourcePage": info.get("descriptionurl"),
                                 "license": lic, "author": strip((meta.get("Artist") or {}).get("value"))[:120],
                                 "query": q})
            print(f"[{label}] {q!r}: kept {kept}")
    json.dump(manifest, open(os.path.join(ROOT, "manifest.json"), "w"), indent=2, ensure_ascii=False)
    print("total", len(manifest))

if __name__ == "__main__":
    main()
