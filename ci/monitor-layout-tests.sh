#!/bin/bash
# Branch tests for the fixed monitor layout (README.md, "Fixed monitor
# layout"): the boot-time generator and the session-side re-assert loop.
#
# Pure logic, no root, no X, no container - both scripts take their inputs and
# outputs from environment-overridable paths precisely so this can run in the
# static CI job. What it must pin down:
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
#   - the watcher re-applies on drift and stays silent otherwise.
set -u
cd "$(dirname "$0")/.." || exit 1

GEN=image/xorg/xorg-monitor-conf.sh
WATCH=image/session/monitor-layout-watch
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
fails=0

log()  { echo "== $*"; }
fail() { echo "FAIL: $*" >&2; fails=$((fails + 1)); }

export MONITORS_CONF="$TMP/monitors.conf"
export MONITORS_OUT="$TMP/30-monitors.conf"
export MONITORS_LAYOUT="$TMP/layout"
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
: > "$MONITORS_OUT"; : > "$MONITORS_LAYOUT"
run
[ -e "$MONITORS_OUT" ] && fail "stale generated config not removed when the layout was withdrawn"
[ -e "$MONITORS_LAYOUT" ] && fail "stale layout file not removed when the layout was withdrawn"

log "config with no output lines: same, and says so"
printf '# nothing declared\nwatch 3\n' > "$MONITORS_CONF"
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

log "modesetting: the session layout file describes the same thing"
grep -q '^output DP-1 1920x1080_60.00 0x0 normal primary 1920x1080+0+0$' "$MONITORS_LAYOUT" \
    || fail "layout line for DP-1 wrong: $(grep '^output DP-1' "$MONITORS_LAYOUT")"
grep -q '^output DP-2 1280x1024_60.00 1920x0 normal - 1280x1024+1920+0$' "$MONITORS_LAYOUT" \
    || fail "layout line for DP-2 wrong: $(grep '^output DP-2' "$MONITORS_LAYOUT")"

log "modesetting: rotation transposes the extents, not the mode"
cat > "$MONITORS_CONF" <<'EOF'
DP-1    1920x1080@60   +0+0       primary
DP-2    1920x1080@60   +1920+0    rotate=left
EOF
run
has "$MONITORS_OUT" 'Option      "Rotate" "left"' "rotation not applied"
has "$MONITORS_OUT" 'Virtual 3000 1920' "rotated output not measured transposed (want 1920+1080 x 1920)"
grep -q '^output DP-2 .* left - 1080x1920+1920+0$' "$MONITORS_LAYOUT" \
    || fail "rotated layout line wrong: $(grep '^output DP-2' "$MONITORS_LAYOUT")"

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
# The layout the watcher re-applies must name modes THIS driver has.
grep -q '^output DP-0 2560x1440 0x0 normal primary 2560x1440+0+0$' "$MONITORS_LAYOUT" \
    || fail "nvidia layout line names a mode the driver would not know"

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
    : > "$MONITORS_OUT"; : > "$MONITORS_LAYOUT"
    run
    if [ -e "$MONITORS_OUT" ] || [ -e "$MONITORS_LAYOUT" ]; then
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
bad watch value|watch sometimes\nDP-1 1920x1080 +0+0
EOF

log "a fractional refresh is carried through"
printf 'DP-1 1920x1080@59.94 +0+0\n' > "$MONITORS_CONF"
run
has "$MONITORS_OUT" '"1920x1080_59.94"' "fractional refresh lost"

# --- the session-side re-assert loop -----------------------------------------
log "watcher: silent when the live layout already matches"
cat > "$MONITORS_CONF" <<'EOF'
DP-1    1920x1080@60   +0+0      primary
DP-2    1920x1080@60   +1920+0
EOF
run
mkdir -p "$TMP/bin"
cat > "$TMP/bin/xrandr" <<'EOF'
#!/bin/sh
if [ "${1:-}" = --query ]; then cat "$FAKE_XRANDR_QUERY"; exit 0; fi
printf '%s\n' "$*" >> "$FAKE_XRANDR_APPLIED"
EOF
chmod +x "$TMP/bin/xrandr"
export FAKE_XRANDR_QUERY="$TMP/query" FAKE_XRANDR_APPLIED="$TMP/applied"
cat > "$FAKE_XRANDR_QUERY" <<'EOF'
Screen 0: minimum 320 x 200, current 3840 x 1080, maximum 16384 x 16384
DP-1 connected primary 1920x1080+0+0 (normal left inverted right) 520mm x 290mm
   1920x1080_60.00  60.00*+
DP-2 connected 1920x1080+1920+0 (normal left inverted right) 520mm x 290mm
   1920x1080_60.00  60.00*+
EOF
: > "$FAKE_XRANDR_APPLIED"
PATH="$TMP/bin:$PATH" MONITOR_WATCH_ONCE=1 "$WATCH" > "$TMP/wlog" 2>&1
[ -s "$FAKE_XRANDR_APPLIED" ] && fail "watcher re-applied a layout that was already correct"
grep -q 'drifted' "$TMP/wlog" && fail "watcher reported drift where there was none"

log "watcher: an output that lost its geometry is put back, exactly as declared"
cat > "$FAKE_XRANDR_QUERY" <<'EOF'
Screen 0: minimum 320 x 200, current 1920 x 1080, maximum 16384 x 16384
DP-1 connected primary 1920x1080+0+0 (normal left inverted right) 520mm x 290mm
   1920x1080_60.00  60.00*+
DP-2 disconnected (normal left inverted right)
EOF
: > "$FAKE_XRANDR_APPLIED"
PATH="$TMP/bin:$PATH" MONITOR_WATCH_ONCE=1 "$WATCH" > "$TMP/wlog" 2>&1
want='--output DP-1 --mode 1920x1080_60.00 --pos 0x0 --rotate normal --primary --output DP-2 --mode 1920x1080_60.00 --pos 1920x0 --rotate normal'
[ "$(cat "$FAKE_XRANDR_APPLIED")" = "$want" ] \
    || fail "re-apply argv wrong:
  want: $want
  got:  $(cat "$FAKE_XRANDR_APPLIED")"
grep -q 'drifted (DP-2)' "$TMP/wlog" || fail "watcher did not name the drifted output: $(cat "$TMP/wlog")"

log "watcher: 'watch off' stops it before it touches anything"
printf 'watch off\nDP-1 1920x1080@60 +0+0\n' > "$MONITORS_CONF"
run
: > "$FAKE_XRANDR_APPLIED"
PATH="$TMP/bin:$PATH" MONITOR_WATCH_ONCE=1 "$WATCH" > "$TMP/wlog" 2>&1
[ -s "$FAKE_XRANDR_APPLIED" ] && fail "watcher ran with watch off"
grep -q 'disabled' "$TMP/wlog" || fail "watcher did not report being disabled"

log "watcher: no layout configured is not an error"
rm -f "$MONITORS_LAYOUT"
PATH="$TMP/bin:$PATH" MONITOR_WATCH_ONCE=1 "$WATCH" > "$TMP/wlog" 2>&1 \
    || fail "watcher exited non-zero with no layout configured"
[ -s "$TMP/wlog" ] && fail "watcher was noisy with no layout configured: $(cat "$TMP/wlog")"

[ "$fails" = 0 ] || { echo "monitor layout tests: $fails failure(s)" >&2; exit 1; }
echo "monitor layout tests passed"
