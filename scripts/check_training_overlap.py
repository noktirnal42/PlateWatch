#!/usr/bin/env python3 -I
"""Fail (exit 1) if any training image is also an evaluation image.

Usage: python3 -I scripts/check_training_overlap.py <dataset dir with train|validation|test/<Class>/...> [more dirs]
Compares by Commons title (the crawler manifest), by file name, and by SHA-256 of the bytes against
eval/manifest.json, eval/corpus and eval/user. Evaluation images may be absent locally; the title and name checks still run.
"""
import hashlib, json, os, sys

here = os.path.dirname(os.path.abspath(__file__))
eval_root = os.path.join(here, "..", "eval")

def sha(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""): h.update(chunk)
    return h.hexdigest()

titles, names, hashes = set(), set(), set()
try:
    for e in json.load(open(os.path.join(eval_root, "manifest.json"))):
        titles.add(e.get("title", "").replace("File:", "").replace(" ", "_").lower())
        names.add(os.path.basename(e.get("file", "")).lower())
except Exception as exc:
    print("warning: eval manifest unreadable:", exc)
for sub in ("corpus", "user"):
    for dp, _, files in os.walk(os.path.join(eval_root, sub)):
        for f in files:
            if f.lower().endswith((".jpg", ".jpeg", ".png")):
                names.add(f.lower()); hashes.add(sha(os.path.join(dp, f)))

bad, total = [], 0
for root in sys.argv[1:]:
    for dp, _, files in os.walk(root):
        for f in files:
            if not f.lower().endswith((".jpg", ".jpeg", ".png")): continue
            total += 1
            p = os.path.join(dp, f)
            if f.lower() in names or f.lower() in titles or (hashes and sha(p) in hashes): bad.append(p)
print(f"checked {total} training images against {len(titles)} eval titles, {len(names)} names, {len(hashes)} hashes")
if bad:
    print("OVERLAP:", *bad[:20], sep="\n  "); sys.exit(1)
print("no overlap")
