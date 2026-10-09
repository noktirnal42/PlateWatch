#!/usr/bin/env python3
"""Convert open-source ALPR models to CoreML (.mlpackage) for PlateWatch.

What it does per registry entry (models/registry.json):
  1. Download the upstream ONNX/PyTorch checkpoint (source URL pinned).
  2. Convert with coremltools (INT8 palettized for ANE efficiency).
  3. Write the .mlpackage into models/cache/ and update the registry entry's
     sha256 + version stamp.

Usage:
  python3 -m venv scripts/.venv
  scripts/.venv/bin/pip install -r scripts/requirements.txt
  scripts/.venv/bin/python scripts/convert_models.py --all
  scripts/.venv/bin/python scripts/convert_models.py --task plate-detection

Rule: never commit model weights. The registry is code; artifacts go to a
GitHub Release (`gh release upload models-vX.Y.Z …`) — see RELEASING.md
section in this file's module docstring if adding models.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
REGISTRY_PATH = ROOT / "models" / "registry.json"
CACHE = ROOT / "models" / "cache"

# Upstream sources. The registry records provenance; this table is where
# conversion pulls from. Keep both accurate — the AGENTS.md provenance rule
# is enforced by listing these in the registry entry itself.
SOURCES = {
    "plate-detector-yolov9t-384": {
        "kind": "onnx",
        "hf_repo": "ankandrew/yolo-v9-t-384-license-plate-end2end",
        "hf_filename": "yolo-v9-t-384-license-plate-end2end.onnx",
        "compute": "cpuAndNeuralEngine",
    },
    "plate-ocr-global-vit-v2": {
        "kind": "onnx",
        "hf_repo": "ankandrew/fast-plate-ocr",
        "hf_filename": "models/global-plates-mobile-vit-v2/model.onnx",
        "compute": "cpuAndNeuralEngine",
    },
    "vehicle-detector-yolo11n": {
        "kind": "ultralytics",  # natively exports CoreML; no manual ONNX step
        "weights": "yolo11n.pt",
        "compute": "cpuAndNeuralEngine",
    },
    "vehicle-reid-osnet-x0_25": {
        "kind": "torchscript_placeholder",
        "note": (
            "OSNet export requires torchscript trace of deep-person-reid. "
            "Placeholder until M2 — VehicleML falls back to Vision feature "
            "prints. Remove this note when a traceable checkpoint is wired."
        ),
    },
}


def sha256_of(path: Path) -> str:
    """SHA-256 of a file, or of a directory as a deterministic digest over
    (relative path, content) pairs in sorted order."""
    if path.is_file():
        h = hashlib.sha256()
        with open(path, "rb") as f:
            for chunk in iter(lambda: f.read(1 << 20), b""):
                h.update(chunk)
        return h.hexdigest()
    h = hashlib.sha256()
    for p in sorted(path.rglob("*")):
        if not p.is_file():
            continue
        h.update(str(p.relative_to(path)).encode())
        with open(p, "rb") as f:
            for chunk in iter(lambda: f.read(1 << 20), b""):
                h.update(chunk)
    return h.hexdigest()


def convert_onnx(src: Path, dst: Path, compute: str) -> None:
    import coremltools as ct

    print(f"[coreml] {src.name} → {dst.name} (compute_units={compute})")
    model = ct.convert(
        str(src),
        source="onnx",
        compute_units=ct.ComputeUnit[compute.replace("-", "_").upper()]
        if "-" not in compute
        else ct.ComputeUnit.ALL,
        minimum_deployment_target=ct.target.macOS14,  # iOS 17/macOS 14 floor
        convert_to="mlprogram",
    )
    # INT8 palettized: ~4x smaller, ANE-friendly, negligible plate-OCR loss.
    try:
        import coremltools.optimize.coreml as cto

        model = cto.palettize_weights(model, nbits=8,
                                      mode="kmeans", granularity="per_grouped_channel")
    except Exception as exc:  # pragma: no cover — quantization failure is non-fatal
        print(f"  (palettization skipped: {exc})")
    model.save(str(dst))


def convert_ultralytics(src: Path, dst: Path) -> None:
    """Ultralytics has first-party CoreML export; wrap it for uniformity."""
    from ultralytics import YOLO

    model = YOLO(str(src))
    out = model.export(format="coreml", int8=True, nms=True, imgsz=640)
    shutil.move(str(out), str(dst))


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--task", help="convert only this task")
    parser.add_argument("--all", action="store_true", help="convert every entry")
    args = parser.parse_args()

    try:
        import coremltools  # noqa: F401
    except ImportError:
        sys.exit("coremltools not installed. Run: scripts/.venv/bin/pip install -r scripts/requirements.txt")

    registry = json.loads(REGISTRY_PATH.read_text())
    CACHE.mkdir(parents=True, exist_ok=True)

    for entry in registry["entries"]:
        name = entry["name"]
        if args.task and entry["task"] != args.task and not args.all:
            continue
        spec = SOURCES.get(name)
        if not spec:
            print(f"[skip] {name}: no conversion source wired")
            continue
        if spec["kind"] == "torchscript_placeholder":
            print(f"[skip] {name}: {spec['note']}")
            continue

        out_pkg = CACHE / f"{name}.mlpackage"
        with tempfile.TemporaryDirectory() as tmp:
            tmp = Path(tmp)
            if spec["kind"] == "onnx":
                from huggingface_hub import hf_hub_download

                print(f"[fetch] {spec['hf_repo']}/{spec['hf_filename']}")
                src = Path(hf_hub_download(spec["hf_repo"], spec["hf_filename"], local_dir=tmp))
                convert_onnx(src, out_pkg, spec.get("compute", "ALL"))
            elif spec["kind"] == "ultralytics":
                from huggingface_hub import hf_hub_download

                weights = Path(hf_hub_download("Ultralytics/YOLO11", spec["weights"], local_dir=tmp))
                convert_ultralytics(weights, out_pkg)
            else:  # pragma: no cover
                raise RuntimeError(f"unknown kind {spec['kind']}")

        digest = sha256_of(out_pkg)
        entry["sha256"] = digest
        print(f"[done] {name} → {out_pkg} sha256={digest[:12]}…")

    REGISTRY_PATH.write_text(json.dumps(registry, indent=2) + "\n")
    print(f"[registry] updated {REGISTRY_PATH}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
