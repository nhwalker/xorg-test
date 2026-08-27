#!/bin/bash
# Branch tests for the boot-time generator behind the fixed monitor layout
# (README.md, "Fixed monitor layout").
#
# Pure logic, no root, no X, no container - the generator takes its input and
# output paths from the environment precisely so this can run in the static CI
# job. What it must pin down:
#
#   - the derived CVT timings, against values cvt(1) prints. A wrong Modeline
#     is a mode the monitor refuses, i.e. a black screen on the one host that
#     opted in - and nothing else in the pipeline would catch it, because the
#     config it lands in is syntactically perfect either way.
#   - opt-in: absent or output-less config writes nothing and removes stale
#     output, so a host that never asked for this keeps autodetecting.
#   - the two driver paths emit their own mechanism and not the other's.
#   - a bad config gives up whole, leaving no half-written file behind: the
#     desktop must still come up.
set -u
cd "$(dirname "$0")/.." || exit 1

GEN=image/xorg/xorg-monitor-conf.sh
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
fails=0

log()  { echo "== $*"; }
fail() { echo "FAIL: $*" >&2; fails=$((fails + 1)); }

export MONITORS_CONF="$TMP/monitors.conf"
export MONITORS_OUT="$TMP/30-monitors.conf"
export XORG_GPU_CONF="$TMP/20-gpu.conf"

gpu_conf() {   # gpu_conf <driver>|none
    if [ "$1" = none ]; then rm -f "$XORG_GPU_CONF"; return; fi
    printf 'Section "Device"\n    Identifier "gpu0"\n    Driver     "%s"\nEndSection\n' \
        "$1" > "$XORG_GPU_CONF"
}
run() { "$GEN" > "$TMP/log" 2>&1; }
has() { grep -qF "$2" "$1" || fail "$3"; }
hasnt() { grep -qF "$2" "$1" && fail "$3"; return 0; }

# --- opt-in ------------------------------------------------------------------
log "no config file: nothing generated, Xorg autodetects"
gpu_conf modesetting
rm -f "$MONITORS_CONF"
: > "$MONITORS_OUT"
run
[ -e "$MONITORS_OUT" ] && fail "stale generated config not removed when the layout was withdrawn"

log "config with no output lines: same, and says so"
printf '# nothing declared\n' > "$MONITORS_CONF"
: > "$MONITORS_OUT"
run
[ -e "$MONITORS_OUT" ] && fail "generated a config from a file declaring no outputs"
grep -q "no fixed layout" "$TMP/log" || fail "did not report the no-op"

# --- the modesetting path ----------------------------------------------------
log "modesetting: forced-on outputs, CVT timings, pinned framebuffer"
gpu_conf modesetting
cat > "$MONITORS_CONF" <<'EOF'
DP-1    1920x1080@60   +0+0      primary
DP-2    1280x1024      +1920+0
EOF
run
# Verbatim cvt(1) output for these two modes. Equality, not a pattern: the
# point is that a monitor with no EDID is handed a timing it will accept.
has "$MONITORS_OUT" 'Modeline "1920x1080_60.00" 173.00  1920 2048 2248 2576  1080 1083 1088 1120 -hsync +vsync' \
    "1920x1080@60 CVT timing does not match cvt(1)"
has "$MONITORS_OUT" 'Modeline "1280x1024_60.00" 109.00  1280 1368 1496 1712  1024 1027 1034 1063 -hsync +vsync' \
    "1280x1024 (default 60Hz) CVT timing does not match cvt(1)"
has "$MONITORS_OUT" 'Option      "Enable" "true"' "outputs are not forced enabled"
has "$MONITORS_OUT" 'Identifier  "DP-1"' "no Monitor section named for the output"
has "$MONITORS_OUT" 'Option      "Position" "1920 0"' "second output not positioned"
has "$MONITORS_OUT" 'Option      "Primary" "true"' "primary output not marked"
has "$MONITORS_OUT" 'Virtual 3200 1080' "framebuffer not pinned to the layout extents"
has "$MONITORS_OUT" 'Device      "gpu0"' "Screen section does not reference the GPU device"
hasnt "$MONITORS_OUT" 'MetaModes' "emitted the NVIDIA mechanism on the modesetting path"
[ "$(grep -c 'Option      "Primary"' "$MONITORS_OUT")" = 1 ] || fail "more than one primary emitted"

log "modesetting: rotation transposes the extents, not the mode"
cat > "$MONITORS_CONF" <<'EOF'
DP-1    1920x1080@60   +0+0       primary
DP-2    1920x1080@60   +1920+0    rotate=left
EOF
run
has "$MONITORS_OUT" 'Option      "Rotate" "left"' "rotation not applied"
has "$MONITORS_OUT" 'Virtual 3000 1920' "rotated output not measured transposed (want 1920+1080 x 1920)"

# --- the NVIDIA path ---------------------------------------------------------
log "nvidia: one MetaMode, no per-output Monitor sections"
gpu_conf nvidia
cat > "$MONITORS_CONF" <<'EOF'
nvidia-connected DFP-0,DFP-2
nvidia-edid DFP-0=/etc/desktop-container/edid-dfp0.bin
DP-0    2560x1440@60   +0+0      primary
HDMI-0  1920x1080@60   +2560+0
EOF
run
has "$MONITORS_OUT" 'Option      "MetaModes" "DP-0: 2560x1440 +0+0, HDMI-0: 1920x1080 +2560+0"' \
    "MetaMode wrong or missing"
has "$MONITORS_OUT" 'Option      "ConnectedMonitor" "DFP-0,DFP-2"' "ConnectedMonitor not passed through"
has "$MONITORS_OUT" 'Option      "CustomEDID" "DFP-0:/etc/desktop-container/edid-dfp0.bin"' \
    "CustomEDID not passed through"
has "$MONITORS_OUT" 'Option      "ModeValidation" "AllowNonEdidModes"' "mode validation not relaxed"
has "$MONITORS_OUT" 'Virtual 4480 1440' "framebuffer not pinned on the nvidia path"
hasnt "$MONITORS_OUT" 'Section "Monitor"' "emitted Monitor sections the NVIDIA driver ignores"
hasnt "$MONITORS_OUT" 'Modeline' "invented a timing for a driver that validates its own"

log "nvidia: ConnectedMonitor and CustomEDID are opt-in"
cat > "$MONITORS_CONF" <<'EOF'
DP-0    1920x1080@60   +0+0   primary
EOF
run
hasnt "$MONITORS_OUT" 'ConnectedMonitor' "emitted ConnectedMonitor nobody asked for"
hasnt "$MONITORS_OUT" 'CustomEDID' "emitted CustomEDID nobody asked for"

# --- degraded host -----------------------------------------------------------
log "no GPU device section: Monitor sections only, and a warning"
gpu_conf none
cat > "$MONITORS_CONF" <<'EOF'
DP-1    1920x1080@60   +0+0   primary
EOF
run
has "$MONITORS_OUT" 'Section "Monitor"' "wrote nothing at all without a Device section"
hasnt "$MONITORS_OUT" 'Section "Screen"' "wrote a Screen referencing a Device that does not exist"
grep -q 'framebuffer size is NOT pinned' "$TMP/log" || fail "did not warn about the unpinned framebuffer"

# --- rejections --------------------------------------------------------------
log "a bad config is rejected whole, leaving nothing behind"
gpu_conf modesetting
while IFS='|' read -r what body; do
    [ -n "$what" ] || continue
    printf '%b\n' "$body" > "$MONITORS_CONF"
    : > "$MONITORS_OUT"
    run
    if [ -e "$MONITORS_OUT" ]; then
        fail "$what: accepted, or left a half-written file"
    fi
    grep -q 'ERROR' "$TMP/log" || fail "$what: rejected without saying why"
done <<'EOF'
mode without a height|DP-1 1920 +0+0
position in xrandr --pos form|DP-1 1920x1080 0x0
unknown flag|DP-1 1920x1080 +0+0 primaryy
two primaries|DP-1 1920x1080 +0+0 primary\nDP-2 1920x1080 +1920+0 primary
duplicate output|DP-1 1920x1080 +0+0\nDP-1 1920x1080 +1920+0
non-numeric refresh|DP-1 1920x1080@sixty +0+0
implausible mode|DP-1 4x4 +0+0
virtual smaller than the layout|virtual 1920x1080\nDP-1 1920x1080 +0+0\nDP-2 1920x1080 +1920+0
EOF

log "a fractional refresh is carried through"
printf 'DP-1 1920x1080@59.94 +0+0\n' > "$MONITORS_CONF"
run
has "$MONITORS_OUT" '"1920x1080_59.94"' "fractional refresh lost"

[ "$fails" = 0 ] || { echo "monitor layout tests: $fails failure(s)" >&2; exit 1; }
echo "monitor layout tests passed"
