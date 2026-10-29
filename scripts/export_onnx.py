#!/usr/bin/env python3
"""Export the YOLOv8n plate and vehicle detectors to ONNX (opset 17, 640x640) for non-Apple runtimes.
Usage: scripts/.venv/bin/python scripts/export_onnx.py   (writes models/cache/onnx/, gitignored; never commit weights)
Upstream sources match models/registry.json: joker5914/yolov8n-license-plate and Ultralytics YOLOv8n (AGPL-3.0).
"""
import sys, hashlib, pathlib
from huggingface_hub import hf_hub_download
from ultralytics import YOLO
out = pathlib.Path("models/cache/onnx"); out.mkdir(parents=True, exist_ok=True)
jobs = {"plate-detector-yolov8n": hf_hub_download("joker5914/yolov8n-license-plate", "best.pt"),
        "vehicle-detector-yolov8n": "yolov8n.pt"}
for name, w in jobs.items():
    p = YOLO(w).export(format="onnx", imgsz=640, opset=17, simplify=True)
    dst = out / f"{name}.onnx"; pathlib.Path(p).replace(dst)
    print(name, dst, hashlib.sha256(dst.read_bytes()).hexdigest(), dst.stat().st_size)
