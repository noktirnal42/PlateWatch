#!/usr/bin/env bash
set -euo pipefail
MODE="${1:-run}"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"
DERIVED_DATA="${PLATEWATCH_DERIVED_DATA_PATH:-$ROOT_DIR/build/hub}"
case "$MODE" in run|--verify|--debug|--logs|--telemetry) ;; *) echo "usage: $0 [run|--verify|--debug|--logs|--telemetry]" >&2; exit 2 ;; esac
xcodegen --spec apps/macos-hub/project.yml
xcodebuild -project apps/macos-hub/PlateWatchHub.xcodeproj -scheme PlateWatchHub \
  -configuration Debug -destination 'platform=macOS' -derivedDataPath "$DERIVED_DATA" build
APP_BUNDLE="$DERIVED_DATA/Build/Products/Debug/PlateWatchHub.app"
pkill -x PlateWatchHub >/dev/null 2>&1 || true
if [[ "$MODE" == --debug ]]; then
  exec lldb -- "$APP_BUNDLE/Contents/MacOS/PlateWatchHub"
fi
/usr/bin/open -n "$APP_BUNDLE"
case "$MODE" in
  --verify)
    # A process existing for one instant misses early startup traps (for example
    # SwiftData rejecting a schema after a capability change).
    for attempt in {1..10}; do
      sleep 0.5
      if ! pgrep -x PlateWatchHub >/dev/null; then
        echo 'PlateWatch Hub exited during startup verification' >&2; exit 1
      fi
    done
    echo 'PlateWatch Hub remained running through startup verification'; exit 0 ;;
  --logs|--telemetry)
    exec /usr/bin/log stream --info --style compact --predicate 'process == "PlateWatchHub"' ;;
esac
