#!/usr/bin/env bash
# Run the prototype on macOS (Apple Silicon or Intel). Downloads Godot 4.5.1 if needed.
#
#   tools/crowd_mac.sh               live crowd test: 100 NPCs, real rendering, real FPS overlay
#   tools/crowd_mac.sh live-uncapped same, with vsync off (shows how far above the display refresh it goes)
#   tools/crowd_mac.sh measure       headless simulation-only FPS (same numbers as docs/performance.md)
#   tools/crowd_mac.sh video         measure, then record out/crowd_mac.mp4 (needs ffmpeg for .mp4)
#   tools/crowd_mac.sh game          play the test level yourself
#   tools/crowd_mac.sh tests         run the full gameplay test suite
#   tools/crowd_mac.sh import        import the Mixamo clips in assets/animations/mixamo/ once
#
# Crowd modes take extra options, e.g.:
#   tools/crowd_mac.sh live --npcs=1000          1000 NPCs (crowd layer)
#   tools/crowd_mac.sh measure --npcs=10000
#   tools/crowd_mac.sh live --characters         every NPC a full character (no crowd layer)
#
# Set GODOT=/path/to/Godot to use your own Godot 4.5.x binary.
set -euo pipefail
cd "$(dirname "$0")/.."

GODOT_VERSION="4.5.1"
MODE="${1:-live}"
shift || true
EXTRA=("$@")
OUT="out"
mkdir -p "$OUT"

find_godot() {
  if [ -n "${GODOT:-}" ]; then echo "$GODOT"; return; fi
  local local_app=".tools/godot-$GODOT_VERSION/Godot.app/Contents/MacOS/Godot"
  if [ -x "$local_app" ]; then echo "$local_app"; return; fi
  if command -v godot >/dev/null 2>&1 && godot --version 2>/dev/null | grep -q "^4\.5"; then
    command -v godot; return
  fi
  if [ -x "/Applications/Godot.app/Contents/MacOS/Godot" ] && \
     /Applications/Godot.app/Contents/MacOS/Godot --version 2>/dev/null | grep -q "^4\.5"; then
    echo "/Applications/Godot.app/Contents/MacOS/Godot"; return
  fi
  echo "Downloading Godot $GODOT_VERSION for macOS (~160 MB, one time)..." >&2
  local dir=".tools/godot-$GODOT_VERSION"
  mkdir -p "$dir"
  curl -fL --progress-bar -o "$dir/godot.zip" \
    "https://github.com/godotengine/godot/releases/download/${GODOT_VERSION}-stable/Godot_v${GODOT_VERSION}-stable_macos.universal.zip"
  (cd "$dir" && unzip -q -o godot.zip && rm godot.zip)
  # Downloaded apps are quarantined by Gatekeeper; clear it so the binary can run from the shell.
  xattr -dr com.apple.quarantine "$dir/Godot.app" 2>/dev/null || true
  echo "$local_app"
}

GODOT_BIN="$(find_godot)"
echo "Using $("$GODOT_BIN" --version) at $GODOT_BIN"
echo "Machine: $(sysctl -n machdep.cpu.brand_string 2>/dev/null || uname -m), $(sysctl -n hw.ncpu 2>/dev/null || echo '?') cores"

# First run (or after pulling changes): import assets / build the script class cache.
"$GODOT_BIN" --headless --path . --import >/dev/null 2>&1 || true

case "$MODE" in
  live)
    "$GODOT_BIN" --path . --resolution 1600x900 -s tests/crowd.gd -- --live ${EXTRA[@]+"${EXTRA[@]}"}
    ;;
  live-uncapped)
    "$GODOT_BIN" --path . --resolution 1600x900 -s tests/crowd.gd -- --live --no-vsync ${EXTRA[@]+"${EXTRA[@]}"}
    ;;
  measure)
    "$GODOT_BIN" --headless --fixed-fps 60 --path . -s tests/crowd.gd -- --measure \
      --timeline="$PWD/$OUT/crowd_mac.json" ${EXTRA[@]+"${EXTRA[@]}"} | grep -E "^CROWD"
    ;;
  video)
    "$GODOT_BIN" --headless --fixed-fps 60 --path . -s tests/crowd.gd -- --measure \
      --timeline="$PWD/$OUT/crowd_mac.json" ${EXTRA[@]+"${EXTRA[@]}"} | grep -E "^CROWD"
    echo "Recording video (renders offline, takes a minute or two)..."
    "$GODOT_BIN" --path . --resolution 1280x720 --write-movie "$PWD/$OUT/crowd_mac.avi" --fixed-fps 60 \
      -s tests/crowd.gd -- --timeline="$PWD/$OUT/crowd_mac.json" ${EXTRA[@]+"${EXTRA[@]}"} | grep -E "frames at" || true
    if command -v ffmpeg >/dev/null 2>&1; then
      ffmpeg -loglevel error -y -i "$OUT/crowd_mac.avi" -c:v libx264 -pix_fmt yuv420p -crf 23 \
        -movflags +faststart "$OUT/crowd_mac.mp4" && rm "$OUT/crowd_mac.avi"
      echo "Video: $OUT/crowd_mac.mp4"
      open "$OUT/crowd_mac.mp4" 2>/dev/null || true
    else
      echo "Video: $OUT/crowd_mac.avi  (install ffmpeg with 'brew install ffmpeg' to get an .mp4)"
    fi
    ;;
  game)
    "$GODOT_BIN" --path .
    ;;
  tests)
    GODOT="$GODOT_BIN" tests/run.sh full
    ;;
  import)
    "$GODOT_BIN" --headless --path . -s tools/import_mocap.gd
    ;;
  *)
    sed -n '2,18p' "$0"
    exit 1
    ;;
esac
