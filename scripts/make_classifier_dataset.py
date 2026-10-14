#!/usr/bin/env python3 -I
"""Build a Create ML *Image Classification* dataset (folder-per-class) from a crawl directory.

Usage: python3 -I scripts/make_classifier_dataset.py <crawl dir> <out dir> [--min 10] [--val 0.1] [--test 0.1]
Input : <crawl dir>/<Class>/*.jpg|png  and <crawl dir>/manifest.json (source/licence/author per file)
Output: <out>/{train,validation,test}/<Class>/..., <out>/ATTRIBUTION.md, <out>/summary.json

* Classes with fewer than --min usable images are dropped (Create ML needs ~10+ per class).
* The split is a stable hash, so re-running never moves an image between splits. With --group-by-author the hash is
  of the photographer, so every photo by one author lands in the SAME split — Commons categories hold many shots of
  the same vehicles by the same person, and a per-file split leaks near-duplicates into the test set (inflated scores).
* Images under 128 px on the short side are skipped. Anything listed in eval/manifest.json is skipped.
"""
import hashlib, json, os, shutil, sys
from PIL import Image

src, out = sys.argv[1], sys.argv[2]
arg = lambda k, d: float(sys.argv[sys.argv.index(k) + 1]) if k in sys.argv else d
min_n, val_f, test_f = int(arg("--min", 10)), arg("--val", 0.1), arg("--test", 0.1)
manifest = {m["file"]: m for m in json.load(open(os.path.join(src, "manifest.json")))}
here = os.path.dirname(os.path.abspath(__file__))
try: eval_titles = {e["title"] for e in json.load(open(os.path.join(here, "..", "eval", "manifest.json")))}
except Exception: eval_titles = set()

shutil.rmtree(out, ignore_errors=True)
classes, dropped = {}, {}
for cls in sorted(os.listdir(src)):
    d = os.path.join(src, cls)
    if not os.path.isdir(d): continue
    ok = []
    for f in sorted(os.listdir(d)):
        rel = f"{cls}/{f}"
        if not f.lower().endswith((".jpg", ".jpeg", ".png")) or (manifest.get(rel, {}).get("title") in eval_titles): continue
        try:
            with Image.open(os.path.join(d, f)) as im:
                if min(im.size) < 128: continue
        except Exception: continue
        ok.append(f)
    if len(ok) < min_n: dropped[cls] = len(ok); continue
    classes[cls] = ok

counts = {"train": {}, "validation": {}, "test": {}}
credits = []
by_author = "--group-by-author" in sys.argv
assign = {}
if by_author:
    # Balanced, deterministic grouped split per class: whole authors go to one split; largest authors are
    # placed first into whichever split is furthest below its target share.
    for cls, files in classes.items():
        groups = {}
        for f in files:
            a = (manifest.get(f"{cls}/{f}", {}).get("author") or "").strip().lower() or f
            groups.setdefault(a, []).append(f)
        target = {"train": 1 - val_f - test_f, "validation": val_f, "test": test_f}
        have = {k: 0 for k in target}
        for a, fs in sorted(groups.items(), key=lambda kv: (-len(kv[1]), kv[0])):
            split = max(target, key=lambda k: target[k] * len(files) - have[k])
            have[split] += len(fs)
            for f in fs: assign[(cls, f)] = split
for cls, files in classes.items():
    for f in files:
        h = int(hashlib.sha256(f.encode()).hexdigest(), 16) % 1000 / 1000
        split = assign.get((cls, f)) or ("test" if h < test_f else "validation" if h < test_f + val_f else "train")
        os.makedirs(os.path.join(out, split, cls), exist_ok=True)
        shutil.copy2(os.path.join(src, cls, f), os.path.join(out, split, cls, f))
        counts[split][cls] = counts[split].get(cls, 0) + 1
        m = manifest.get(f"{cls}/{f}", {})
        credits.append(f"- {cls}/{f} — {m.get('title','')} — {m.get('author','')} — {m.get('license','')} — {m.get('sourcePage','')}")
open(os.path.join(out, "ATTRIBUTION.md"), "w").write("# Attribution (CC0 / public domain / CC BY — Wikimedia Commons)\n\n" + "\n".join(credits) + "\n")
json.dump({"classes": {c: len(v) for c, v in classes.items()}, "dropped(<min)": dropped, "split": counts}, open(os.path.join(out, "summary.json"), "w"), indent=1)
tot = {s: sum(v.values()) for s, v in counts.items()}
print(f"{len(classes)} classes kept, {len(dropped)} dropped (<{min_n}); images {tot}")
if dropped: print("dropped:", dropped)
