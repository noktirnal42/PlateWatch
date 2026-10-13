#!/usr/bin/env python3 -I
"""Build a Create ML object-detection dataset from Open Images "Vehicle registration plate" boxes.

Usage: python3 -I scripts/make_plate_dataset.py <training/plate-detector dir>
Reads  <dir>/raw/<ImageID>.jpg, <dir>/boxes.json, <dir>/ATTRIBUTION.json
Writes <dir>/CreateML/{train,validation,test}/ (images + annotations.json) and <dir>/CreateML/ATTRIBUTION.md

Create ML object-detection annotations: an array of
  {"image": "<file>", "annotations": [{"label": "plate", "coordinates": {"x","y","width","height"}}]}
where x,y is the box CENTRE and all four numbers are in PIXELS (origin top-left).
  --keys dts   writes Apple-forum key names (imagefilename / annotation) instead of the WWDC ones.
Images need no rotation: those with a non-zero Open Images Rotation tag are skipped so boxes stay correct.
Licence: every image is CC BY 2.0 (per image); ATTRIBUTION.md credits each Flickr author, as the licence requires.
"""
import hashlib, json, os, shutil, sys
from PIL import Image

root = sys.argv[1]
keys = ("imagefilename", "annotation") if "--keys" in sys.argv and sys.argv[sys.argv.index("--keys") + 1] == "dts" else ("image", "annotations")
boxes = json.load(open(os.path.join(root, "boxes.json")))["boxes"]
attr = {a["id"]: a for a in json.load(open(os.path.join(root, "ATTRIBUTION.json")))}
out = os.path.join(root, "CreateML" + ("-dts" if keys[0] != "image" else ""))
shutil.rmtree(out, ignore_errors=True)
splits = {"train": [], "validation": [], "test": []}
skipped = {"missing": 0, "rotated": 0, "no-boxes": 0}
for key, bxs in sorted(boxes.items()):
    subset, iid = key.split("/")
    path = os.path.join(root, "raw", iid + ".jpg")
    if not os.path.exists(path): skipped["missing"] += 1; continue
    if attr.get(iid, {}).get("rotation") not in ("", "0", "0.0", None): skipped["rotated"] += 1; continue
    try: w, h = Image.open(path).size
    except Exception: skipped["missing"] += 1; continue
    anns = []
    for xmin, xmax, ymin, ymax in bxs:
        bw, bh = (xmax - xmin) * w, (ymax - ymin) * h
        if bw < 0.02 * w or bh < 4: continue                    # unreadably small
        anns.append({"label": "plate", "coordinates": {
            "x": round((xmin + xmax) / 2 * w), "y": round((ymin + ymax) / 2 * h),
            "width": round(bw), "height": round(bh)}})
    if not anns: skipped["no-boxes"] += 1; continue
    bucket = int(hashlib.sha256(iid.encode()).hexdigest(), 16) % 10      # stable 80/10/10
    split = "train" if bucket < 8 else "validation" if bucket == 8 else "test"
    splits[split].append((iid, path, anns))

credit = ["# Attribution", "",
          "Training images are from Google Open Images (annotations CC BY 4.0), each photo licensed",
          "**CC BY 2.0** by its Flickr author (credited below). Boxes: Open Images 'Vehicle registration plate'.", ""]
for split, items in splits.items():
    d = os.path.join(out, split); os.makedirs(d, exist_ok=True)
    ann = []
    for iid, path, anns in items:
        name = iid + ".jpg"
        try: os.link(path, os.path.join(d, name))
        except OSError: shutil.copy2(path, os.path.join(d, name))
        ann.append({keys[0]: name, keys[1]: anns})
        a = attr[iid]
        credit.append(f"- {iid}: “{a['title']}” by {a['author']} — {a['landingURL']} — CC BY 2.0")
    json.dump(ann, open(os.path.join(d, "annotations.json"), "w"))
    print(f"{split:10s} {len(items):5d} images  {sum(len(a) for _, _, a in items):5d} boxes")
open(os.path.join(out, "ATTRIBUTION.md"), "w").write("\n".join(credit) + "\n")
print("skipped:", skipped, "->", out)
