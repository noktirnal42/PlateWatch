#!/usr/bin/env python3 -I
"""Turn hand-collected agency plate images into a crawler-style folder + manifest.

Usage: python3 -I scripts/ingest_manual_plates.py <dir with <State>/*.jpg|png and sources.csv>
sources.csv columns (header required): file,state,page_url,retrieved,note   e.g.  Maine/pine-tree.png,Maine,https://www.maine.gov/...,2026-10-20,standard
Writes <dir>/manifest.json in the format scripts/make_classifier_dataset.py and scripts/plate_crops.swift read. Every row is stamped with the
counsel fair-use statement from docs/DECISIONS.md (2026-10-19). Rows whose file is missing, or without a page URL / date, are rejected.
"""
import csv, json, os, sys
root = sys.argv[1]
rows, bad = [], []
for r in csv.DictReader(open(os.path.join(root, "sources.csv"), newline="")):
    f = r["file"].strip()
    if not os.path.isfile(os.path.join(root, f)) or not r["page_url"].startswith("https://") or not r["retrieved"].strip():
        bad.append(f); continue
    rows.append({"file": f, "class": r["state"].strip(), "title": os.path.basename(f), "sourcePage": r["page_url"].strip(),
                 "license": "agency-published image, used under counsel's fair-use determination 2026-10-19 (docs/DECISIONS.md)",
                 "author": "state agency", "retrieved": r["retrieved"].strip(), "note": r.get("note", "").strip()})
json.dump(rows, open(os.path.join(root, "manifest.json"), "w"), indent=1, ensure_ascii=False)
print(f"manifest: {len(rows)} images; rejected {len(bad)}: {bad[:10]}")
