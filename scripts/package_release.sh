#!/bin/bash
# Package CoreML models for a models-vX.Y.Z GitHub release.
#
# - Single-file Create ML exports (.mlmodel) are published raw: CoreML compiles
#   a downloaded .mlmodel directly (see ModelManager.artifactExtension).
# - .mlpackage directories cannot be downloaded as one file, so they are packed
#   as Apple Archives (.aar). VehicleML.ModelArchive extracts them on-device
#   before compilation. `aa archive -d DIR` stores DIR's *contents* at the
#   archive root; ModelArchive.normalize detects that case and reassembles a
#   named .mlpackage.
#
# Usage: scripts/package_release.sh [path/to/PlateDetector.mlmodel]
# Prints "sha256  filename" for every release artifact; those hashes are the
# `sha256` fields in models/registry.json.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CACHE="$REPO_ROOT/models/cache"
OUT="$REPO_ROOT/models/release"
PLATE_MLMODEL="${1:-$HOME/Documents/PlateWatch-Training/PlateDetector.mlmodel}"

mkdir -p "$OUT"

for pkg in "$CACHE"/*.mlpackage; do
  name="$(basename "$pkg" .mlpackage)"
  echo "archiving $name"
  aa archive -d "$pkg" -o "$OUT/$name.aar"
done

if [ -f "$PLATE_MLMODEL" ]; then
  cp "$PLATE_MLMODEL" "$OUT/plate-detector-createml-v1.mlmodel"
else
  echo "warning: Create ML plate model not found at $PLATE_MLMODEL — raw .mlmodel not staged" >&2
fi

echo
for f in "$OUT"/*; do
  printf "%s  %s\n" "$(shasum -a 256 "$f" | cut -d' ' -f1)" "$(basename "$f")"
done
