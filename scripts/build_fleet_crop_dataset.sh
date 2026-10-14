#!/bin/bash
# Builds the Create ML fleet *crop* classification dataset from a Commons crawl (scripts/crawl_commons_fleet.py).
#   1. tag every crawled image with Apple's classifier and keep only car/truck/bus-like images (drops boats, bikes,
#      motorcycles, crowds — the raw `police` class was ~80% such noise),
#   2. cut the main vehicle out of each kept image with the vehicle detector,
#   3. split by PHOTOGRAPHER (a random split leaks near-duplicates and inflated test accuracy from 73% to 82%).
# Usage: scripts/build_fleet_crop_dataset.sh <crawl dir> <out dir> [models dir]   (models dir has vehicle-detector-yolov8n.mlpackage)
set -euo pipefail
CRAWL="$1"; OUT="$2"; MODELS="${3:-models/cache}"
HERE="$(cd "$(dirname "$0")" && pwd)"; TMP="$(mktemp -d)"
swiftc -O "$HERE/tag_images.swift" -o "$TMP/tag_images"
swiftc -O "$HERE/vehicle_crops.swift" -o "$TMP/vehicle_crops"
"$TMP/tag_images" "$CRAWL" "$TMP/tags.json"
python3 -I - "$CRAWL" "$TMP" <<'PY'
import json, re, shutil, sys, os
crawl, tmp = sys.argv[1], sys.argv[2]
tags = json.load(open(f"{tmp}/tags.json"))
bad = re.compile(r"moto|bicycle|boat|ship|watercraft|sail|vessel|ferry|cycl|scooter|aircraft|helicopter")
def keep(e):
    t = {x["l"]: x["c"] for x in e["tags"]}
    if any(t[l] >= 0.15 for l in t if bad.search(l)): return False
    veh = max(t.get("automobile", 0), t.get("vehicle", 0), t.get("bus", 0), t.get("truck", 0), t.get("wagon", 0))
    return veh >= 0.20 and t.get("people", 0) < 0.5
man = {m["file"]: m for m in json.load(open(f"{crawl}/manifest.json"))}
cur = f"{tmp}/curated"; kept = []
for e in tags:
    if not keep(e): continue
    os.makedirs(f"{cur}/{e['class']}", exist_ok=True)
    shutil.copy2(f"{crawl}/{e['class']}/{e['file']}", f"{cur}/{e['class']}/{e['file']}")
    if f"{e['class']}/{e['file']}" in man: kept.append(man[f"{e['class']}/{e['file']}"])
json.dump(kept, open(f"{cur}/manifest.json", "w"))
print(f"kept {len(kept)} of {len(tags)} tagged images")
PY
"$TMP/vehicle_crops" "$TMP/curated" "$TMP/crops" "$MODELS/vehicle-detector-yolov8n.mlpackage"
python3 -I "$HERE/make_classifier_dataset.py" "$TMP/crops" "$OUT" --min 20 --group-by-author
echo "dataset: $OUT   (work dir kept at $TMP)"
