#!/usr/bin/env python3 -I
"""Expand ONLY the train split of a Create ML classifier dataset with camera-like degradations.

Usage: python3 -I scripts/augment_plate_dataset.py <dataset dir> <out dir> [--copies 5] [--seed 7]
Validation/test are copied unchanged so scores stay comparable. Each copy: random down-scale to 40-160 px wide and back up
(the target is a small plate in a phone/DOT frame), perspective +/-20 degrees, defocus or motion blur, brightness/contrast/colour
cast, sensor noise and JPEG 30-90. Deterministic for a given seed. Docs: docs/PLATE-STATE-CLASSIFIER-SPEC.md section 4.3.
"""
import io, os, random, shutil, sys
from PIL import Image, ImageEnhance, ImageFilter

src, out = sys.argv[1], sys.argv[2]
copies = int(sys.argv[sys.argv.index("--copies") + 1]) if "--copies" in sys.argv else 5
rng = random.Random(int(sys.argv[sys.argv.index("--seed") + 1]) if "--seed" in sys.argv else 7)
shutil.rmtree(out, ignore_errors=True)
for split in ("validation", "test"):
    if os.path.isdir(os.path.join(src, split)): shutil.copytree(os.path.join(src, split), os.path.join(out, split))

def perspective(im):
    w, h = im.size; d = 0.18
    def j(x, y): return (x + rng.uniform(-d, d) * w * (0.5 if x in (0, w) else 0), y + rng.uniform(-d, d) * h * (0.5 if y in (0, h) else 0))
    quad = [j(0, 0), j(0, h), j(w, h), j(w, 0)]
    flat = [c for p in quad for c in p]
    return im.transform((w, h), Image.QUAD, flat, Image.BICUBIC)

def degrade(im):
    im = im.convert("RGB")
    if rng.random() < 0.7: im = perspective(im)
    tw = rng.randint(40, 160); th = max(12, int(im.height * tw / im.width))
    im = im.resize((tw, th), Image.BILINEAR).resize((max(160, tw * 2), max(60, th * 2)), Image.BICUBIC)
    if rng.random() < 0.6: im = im.filter(ImageFilter.GaussianBlur(rng.uniform(0.3, 1.6)))
    elif rng.random() < 0.3: im = im.filter(ImageFilter.BoxBlur(rng.uniform(0.5, 1.5)))
    im = ImageEnhance.Brightness(im).enhance(rng.uniform(0.55, 1.35))
    im = ImageEnhance.Contrast(im).enhance(rng.uniform(0.6, 1.3))
    if rng.random() < 0.4:  # colour cast (dusk / sodium light)
        r, g, b = im.split(); k = rng.uniform(0.8, 1.2)
        im = Image.merge("RGB", (r.point(lambda v: min(255, int(v * k))), g, b.point(lambda v: min(255, int(v / k)))))
    px = im.load()
    for _ in range(int(im.width * im.height * 0.01)):
        x, y = rng.randrange(im.width), rng.randrange(im.height); n = rng.randint(-25, 25)
        r, g, b = px[x, y]; px[x, y] = (max(0, min(255, r + n)), max(0, min(255, g + n)), max(0, min(255, b + n)))
    buf = io.BytesIO(); im.save(buf, "JPEG", quality=rng.randint(30, 90)); buf.seek(0)
    return Image.open(buf).convert("RGB")

n = 0
base = os.path.join(src, "train")
for cls in sorted(os.listdir(base)):
    d = os.path.join(base, cls); os.makedirs(os.path.join(out, "train", cls), exist_ok=True)
    for f in sorted(os.listdir(d)):
        if not f.lower().endswith((".jpg", ".jpeg", ".png")): continue
        shutil.copy(os.path.join(d, f), os.path.join(out, "train", cls, f))
        with Image.open(os.path.join(d, f)) as im:
            for c in range(copies):
                degrade(im.copy()).save(os.path.join(out, "train", cls, f"{os.path.splitext(f)[0]}__aug{c}.jpg"), quality=92); n += 1
print(f"wrote {n} augmented train images (originals kept); validation/test unchanged")
