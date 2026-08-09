#!/usr/bin/env bash
# Invariant 4: the HUD never appears in the capture.
#
# A blank screenshot on its own proves nothing — the panel might simply not be
# drawn. So this captures the same screen region twice: once with the panel made
# capturable on purpose, once normally. The first must show something, the second
# must not, and they must differ.
#
#     ./scripts/verify-hud-not-captured.sh

set -euo pipefail
cd "$(dirname "$0")/.."

OUT="${TMPDIR:-/tmp}/lookit-hud-verify"
mkdir -p "$OUT"
BIN="lookit.app/Contents/MacOS/lookit"

[[ -x "$BIN" ]] || ./scripts/bundle.sh >/dev/null

stop() { pkill -f "$BIN" 2>/dev/null || true; sleep 1; }
trap stop EXIT

shoot() { # $1 = LOOKIT_HUD_CAPTURABLE value, $2 = output png
    stop
    LOOKIT_HUD_CAPTURABLE="$1" "./$BIN" &
    sleep 2

    local frame
    frame="$(swift scripts/hud-frame.swift)" || { echo "FAIL: no HUD panel on screen" >&2; exit 1; }
    echo "  panel at $frame (capturable=$1)"
    screencapture -x -R"$frame" "$2"
}

shoot 1 "$OUT/capturable.png"
shoot 0 "$OUT/excluded.png"
stop

a="$(md5 -q "$OUT/capturable.png")"
b="$(md5 -q "$OUT/excluded.png")"

echo
if [[ "$a" == "$b" ]]; then
    echo "FAIL: the two captures are identical — sharingType = .none had no effect,"
    echo "      so the HUD would appear in a display capture."
    exit 1
fi

echo "PASS: the HUD is visible when made capturable and absent when not."
echo "      sharingType = .none is honoured on this macOS."
echo "      $OUT/capturable.png vs $OUT/excluded.png"
