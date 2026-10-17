#!/bin/zsh
set -euo pipefail

# This is the local QA/release path. CI intentionally uses CODE_SIGNING_ALLOWED=NO,
# but an unsigned Hub cannot construct the CloudKit backend and must never replace
# the installed operator build.
ROOT_DIR="$(cd "$(dirname "$0")/../../.." && pwd)"
DERIVED_DATA="${PLATEWATCH_DERIVED_DATA:-${TMPDIR:-/tmp}/platewatch-hub-derived}"
INSTALL_DIR="${PLATEWATCH_INSTALL_DIR:-$HOME/Applications}"
APP="$DERIVED_DATA/Build/Products/Debug/PlateWatchHub.app"

xcodebuild \
  -project "$ROOT_DIR/apps/macos-hub/PlateWatchHub.xcodeproj" \
  -scheme PlateWatchHub \
  -configuration Debug \
  -destination 'platform=macOS' \
  -derivedDataPath "$DERIVED_DATA" \
  -allowProvisioningUpdates \
  -skipPackageUpdates \
  build

if ! /usr/bin/codesign -d --entitlements :- "$APP" 2>/dev/null \
    | /usr/bin/grep -q 'iCloud.org.platewatch.platewatch'; then
  print -u2 "Refusing to install an unsigned or non-CloudKit-entitled Hub: $APP"
  exit 2
fi

mkdir -p "$INSTALL_DIR"
/usr/bin/pkill -x PlateWatchHub 2>/dev/null || true
/usr/bin/ditto "$APP" "$INSTALL_DIR/PlateWatchHub.app"
open "$INSTALL_DIR/PlateWatchHub.app"
print "Installed signed CloudKit-entitled Hub at $INSTALL_DIR/PlateWatchHub.app"
