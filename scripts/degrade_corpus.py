#!/usr/bin/env python3 -I
"""Make traffic-camera-quality copies of the eval corpus.

Usage: python3 -I scripts/degrade_corpus.py [eval dir]   (default: eval)
Writes <eval>/degraded/<profile>/{manifest.json, corpus/...} for each profile, so
`EvalHarness eval/degraded/<profile>` measures what survives public-feed image quality.

Profiles approximate real DOT/transit snapshot feeds (typically 352x240 .. 704x480, heavy JPEG, some softness,
often noisy at dusk). They are deliberately rough — the point is the trend, not a calibrated simulator.
"""
import json, os, random, sys
from PIL import Image, ImageFilter

root = sys.argv[1] if len(sys.argv) > 1 else "eval"
PROFILES = {                       # long side px, JPEG quality, blur radius, noise sigma
    "dot-720": (1280, 60, 0.0, 0),
    "dot-480": (704, 40, 0.6, 3),
    "dot-240": (352, 30, 0.8, 5),
}
manifest = json.load(open(os.path.join(root, "manifest.json")))
for name, (side, quality, blur, noise) in PROFILES.items():
    out = os.path.join(root, "degraded", name)
    rnd = random.Random(7)
    for e in manifest:
        src = os.path.join(root, e["file"])
        dst = os.path.join(out, e["file"])
        os.makedirs(os.path.dirname(dst), exist_ok=True)
        im = Image.open(src).convert("RGB")
        scale = side / max(im.size)
        if scale < 1: im = im.resize((max(1, round(im.width * scale)), max(1, round(im.height * scale))), Image.BILINEAR)
        if blur: im = im.filter(ImageFilter.GaussianBlur(blur))
        if noise:
            px = im.load()
            for y in range(0, im.height):
                for x in range(0, im.width):
                    r, g, b = px[x, y]; n = rnd.gauss(0, noise)
                    px[x, y] = (max(0, min(255, int(r + n))), max(0, min(255, int(g + n))), max(0, min(255, int(b + n))))
        im.save(dst.rsplit(".", 1)[0] + ".jpg", "JPEG", quality=quality)
    m2 = [dict(e, file=e["file"].rsplit(".", 1)[0] + ".jpg") for e in manifest]
    json.dump(m2, open(os.path.join(out, "manifest.json"), "w"))
    print(name, "->", out, f"(long side {side}px, q{quality}, blur {blur}, noise {noise})")
