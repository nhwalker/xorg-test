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
#
# Evidence (Requirements.md, S3.4.1-S3.4.7): with EV_ROOT set, every case
# keeps its input, the GPU config it ran against, what the generator wrote
# (or a listing showing it wrote nothing) and its log, under the story it
# proves; every assertion is a line in that story's checks.
set -u
cd "$(dirname "$0")/.." || exit 1
# shellcheck source=ci/evidence.sh
. ci/evidence.sh
[ -z "$EV_ROOT" ] || mkdir -p "$EV_ROOT"

GEN=image/xorg/xorg-monitor-conf.sh
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
fails=0

log()  { echo "== $*"; }
fail() { echo "FAIL: $*" >&2; fails=$((fails + 1)); ev_fail "$*"; }
ok()   { ev_pass "$*"; }

# The container's own layout, under the temporary directory: the host's
# monitors.conf, and the xorg.conf.d the two generators write into.
mkdir -p "$TMP/etc" "$TMP/xorg.conf.d"
export MONITORS_CONF="$TMP/etc/monitors.conf"
export MONITORS_OUT="$TMP/xorg.conf.d/30-monitors.conf"
export XORG_GPU_CONF="$TMP/xorg.conf.d/20-gpu.conf"

gpu_conf() {   # gpu_conf <driver>|none
    if [ "$1" = none ]; then rm -f "$XORG_GPU_CONF"; return; fi
    printf 'Section "Device"\n    Identifier "gpu0"\n    Driver     "%s"\nEndSection\n' \
        "$1" > "$XORG_GPU_CONF"
}
# run <case>: the generator, then the case's evidence. The generator exits 0
# whatever it decides - a bad layout must not cost the desktop - so a
# non-zero status is itself a failure.
run() {
    local rc=0
    "$GEN" > "$TMP/log" 2>&1 || rc=$?
    if [ "$rc" = 0 ]; then ok "$1: the generator exited 0"; else fail "$1: the generator exited $rc"; fi
    if [ -f "$MONITORS_CONF" ]; then
        ev_copy "$MONITORS_CONF" "$1-input" "EV-CONFIG: the case's monitors.conf"
    else
        ev_text "$1-input" "the case's input" "(no monitors.conf at all)"
    fi
    if [ -f "$XORG_GPU_CONF" ]; then
        ev_copy "$XORG_GPU_CONF" "$1-gpu" "EV-CONFIG: the 20-gpu.conf the case ran against (its Driver line picks the path)"
    else
        ev_text "$1-gpu" "the GPU config the case ran against" "(no 20-gpu.conf: no Device section)"
    fi
    if [ -f "$MONITORS_OUT" ]; then
        ev_copy "$MONITORS_OUT" "$1-generated" "EV-CONFIG: the 30-monitors.conf the generator wrote"
    fi
    ev_save "$1-ls" "EV-STATE: ls of xorg.conf.d after the run: 30-monitors.conf there or not" \
        ls -l "$TMP/xorg.conf.d" >/dev/null || true
    ev_copy "$TMP/log" "$1-log" "the generator's log (EV-LOG-DESKTOP in the container)"
}
# has <file> <text> <claim>: the text is in the file.
has()   { if grep -qF "$2" "$1"; then ok "$3"; else fail "NOT: $3"; fi; }
hasnt() { if grep -qF "$2" "$1"; then fail "NOT: $3"; else ok "$3"; fi; }
absent()  { if [ -e "$MONITORS_OUT" ]; then fail "NOT: $1"; else ok "$1"; fi; }
logged()  { if grep -qF "$1" "$TMP/log"; then ok "$2"; else fail "NOT: $2"; fi; }

# --- opt-in ------------------------------------------------------------------
ev_begin S3.4.1 "Opt-in: absent or output-less config generates nothing" T0
log "no config file: nothing generated, Xorg autodetects"
gpu_conf modesetting
rm -f "$MONITORS_CONF"
: > "$MONITORS_OUT"
run no-config
absent "no monitors.conf: the stale generated config is removed"
logged "no fixed monitor layout configured" "no monitors.conf: the generator logs the no-op"

log "config with no output lines: same, and says so"
printf '# nothing declared\n' > "$MONITORS_CONF"
: > "$MONITORS_OUT"
run comments-only
absent "comments only: no config generated, the stale one removed"
logged "no fixed layout" "comments only: the generator logs the no-op"

log "global lines but no output lines: same"
printf 'virtual 3840x1080\nnvidia-connected DFP-0,DFP-1\n' > "$MONITORS_CONF"
: > "$MONITORS_OUT"
run globals-only
absent "globals only (virtual, nvidia-connected): no config generated, the stale one removed"
logged "no fixed layout" "globals only: the generator logs the no-op"
ev_end

# --- the modesetting path ----------------------------------------------------
ev_begin S3.4.2 "modesetting emission" T0
log "modesetting: forced-on outputs, CVT timings, pinned framebuffer"
gpu_conf modesetting
cat > "$MONITORS_CONF" <<'EOF'
DP-1    1920x1080@60   +0+0      primary
DP-2    1280x1024      +1920+0
EOF
run modesetting
has "$MONITORS_OUT" 'Option      "Enable" "true"' "the outputs are forced enabled"
[ "$(grep -c '^Section "Monitor"' "$MONITORS_OUT")" = 2 ] \
    && ok "one Monitor section per declared output (2)" || fail "NOT: one Monitor section per declared output"
has "$MONITORS_OUT" 'Identifier  "DP-1"' "a Monitor section is named for DP-1"
has "$MONITORS_OUT" 'Identifier  "DP-2"' "a Monitor section is named for DP-2"
has "$MONITORS_OUT" 'HorizSync   15.0 - 300.0' "each Monitor section states wide sync ranges, so the EDID's are not needed"
has "$MONITORS_OUT" 'Option      "PreferredMode" "1920x1080_60.00"' "DP-1 prefers its generated mode"
has "$MONITORS_OUT" 'Option      "PreferredMode" "1280x1024_60.00"' "DP-2 prefers its generated mode"
has "$MONITORS_OUT" 'Option      "Position" "1920 0"' "the second output is positioned at +1920+0"
has "$MONITORS_OUT" 'Option      "Primary" "true"' "the primary output is marked"
[ "$(grep -c 'Option      "Primary"' "$MONITORS_OUT")" = 1 ] \
    && ok "exactly one primary" || fail "NOT: exactly one primary"
has "$MONITORS_OUT" 'Virtual 3200 1080' "the framebuffer is pinned to the layout's extents (3200x1080)"
has "$MONITORS_OUT" 'Device      "gpu0"' "the Screen section references the GPU device gpu0"
hasnt "$MONITORS_OUT" 'MetaModes' "no NVIDIA MetaModes on the modesetting path"
cp "$MONITORS_OUT" "$TMP/modesetting.conf"
ev_end

ev_begin S3.4.3 "CVT timings match cvt(1)" T0
# cvt(1)'s Modeline for each mode, verbatim as the image's own cvt prints it
# (Rocky 9's xorg-x11-server-Xorg 1.20.11; the runner has no cvt, so the
# lines are pinned here). Every aspect branch: 16:9 at 50/60/75/85 Hz and at
# 1440p and 2160p, 5:4 (also with no refresh given: 60), 4:3 twice, 16:10,
# 15:9, portrait (no standard ratio), and 1280x768, which only the
# divisibility check keeps out of 15:9. Equality field for field, not a
# pattern: cvt pads after the name differently, nothing else may differ.
# The point is that a monitor with no EDID is handed a timing it accepts.
gpu_conf modesetting
: > "$TMP/cvt-table"
while IFS='|' read -r label decl ref; do
    printf 'DP-1 %s +0+0\n' "$decl" > "$MONITORS_CONF"
    rc=0
    "$GEN" > "$TMP/log" 2>&1 || rc=$?
    gen=$(sed -n 's/^ *\(Modeline .*\)/\1/p' "$MONITORS_OUT" 2>/dev/null)
    printf '%s\n  generated: %s\n  cvt(1):    %s\n' "$label" "${gen:-(none; the generator exited $rc)}" "$ref" >> "$TMP/cvt-table"
    if [ "$rc" = 0 ] && [ -n "$gen" ] && [ "$(tr -s ' ' <<<"$gen")" = "$(tr -s ' ' <<<"$ref")" ]; then
        ok "$label: the generated Modeline is cvt(1)'s, field for field"
    else
        fail "$label: the generated Modeline is not cvt(1)'s (exit $rc)"
    fi
done <<'EOF'
1920x1080@60 (16:9)|1920x1080@60|Modeline "1920x1080_60.00"  173.00  1920 2048 2248 2576  1080 1083 1088 1120 -hsync +vsync
1920x1080@50 (16:9)|1920x1080@50|Modeline "1920x1080_50.00"  141.50  1920 2032 2232 2544  1080 1083 1088 1114 -hsync +vsync
1920x1080@75 (16:9)|1920x1080@75|Modeline "1920x1080_75.00"  220.75  1920 2064 2264 2608  1080 1083 1088 1130 -hsync +vsync
1920x1080@85 (16:9)|1920x1080@85|Modeline "1920x1080_85.00"  253.25  1920 2064 2272 2624  1080 1083 1088 1137 -hsync +vsync
2560x1440@60 (16:9)|2560x1440@60|Modeline "2560x1440_60.00"  312.25  2560 2752 3024 3488  1440 1443 1448 1493 -hsync +vsync
3840x2160@60 (16:9)|3840x2160@60|Modeline "3840x2160_60.00"  712.75  3840 4160 4576 5312  2160 2163 2168 2237 -hsync +vsync
1280x1024@60 (5:4)|1280x1024@60|Modeline "1280x1024_60.00"  109.00  1280 1368 1496 1712  1024 1027 1034 1063 -hsync +vsync
1280x1024 (5:4, no refresh given: 60)|1280x1024|Modeline "1280x1024_60.00"  109.00  1280 1368 1496 1712  1024 1027 1034 1063 -hsync +vsync
1600x1200@60 (4:3)|1600x1200@60|Modeline "1600x1200_60.00"  161.00  1600 1712 1880 2160  1200 1203 1207 1245 -hsync +vsync
1024x768@60 (4:3)|1024x768@60|Modeline "1024x768_60.00"   63.50  1024 1072 1176 1328  768 771 775 798 -hsync +vsync
1920x1200@60 (16:10)|1920x1200@60|Modeline "1920x1200_60.00"  193.25  1920 2056 2256 2592  1200 1203 1209 1245 -hsync +vsync
1800x1080@60 (15:9)|1800x1080@60|Modeline "1800x1080_60.00"  161.75  1800 1920 2104 2408  1080 1083 1090 1120 -hsync +vsync
1080x1920@60 (portrait: no standard ratio)|1080x1920@60|Modeline "1080x1920_60.00"  176.50  1080 1168 1280 1480  1920 1923 1933 1989 -hsync +vsync
1280x768@60 (768 not divisible by 9: no standard ratio)|1280x768@60|Modeline "1280x768_60.00"   79.50  1280 1344 1472 1664  768 771 781 798 -hsync +vsync
EOF
log "a fractional refresh is carried through"
printf 'DP-1 1920x1080@59.94 +0+0\n' > "$MONITORS_CONF"
run fractional
has "$MONITORS_OUT" '"1920x1080_59.94"' "a fractional refresh (59.94) is carried into the mode name"
printf '1920x1080@59.94 (fractional refresh; not in the table above)\n  generated: %s\n' \
    "$(sed -n 's/^ *\(Modeline .*\)/\1/p' "$MONITORS_OUT")" >> "$TMP/cvt-table"
ev_copy "$TMP/cvt-table" cvt-table "EV-STATE: declared mode -> the Modeline the generator wrote -> the Modeline the image's cvt(1) prints (Rocky 9, xorg-x11-server-Xorg 1.20.11), pinned in this script"
ev_end

ev_begin S3.4.4 "Rotation transposes extents" T0
for dir in left right inverted; do
    log "modesetting: rotate=$dir"
    cat > "$MONITORS_CONF" <<EOF
DP-1    1920x1080@60   +0+0       primary
DP-2    1920x1080@60   +1920+0    rotate=$dir
EOF
    run "rotate-$dir"
    has "$MONITORS_OUT" "Option      \"Rotate\" \"$dir\"" "rotate=$dir is applied to DP-2"
    case $dir in
        left|right) has "$MONITORS_OUT" 'Virtual 3000 1920' \
            "rotate=$dir: DP-2 is measured transposed, 1080x1920, so the framebuffer is 3000x1920" ;;
        inverted)   has "$MONITORS_OUT" 'Virtual 3840 1080' \
            "rotate=inverted keeps DP-2's 1920x1080, so the framebuffer is 3840x1080" ;;
    esac
    has "$MONITORS_OUT" 'Modeline "1920x1080_60.00"' "rotate=$dir: the mode itself is not transposed"
done
ev_end

# --- the NVIDIA path ---------------------------------------------------------
ev_begin S3.4.5 "NVIDIA emission" T0
log "nvidia: one MetaMode, no per-output Monitor sections"
gpu_conf nvidia
cat > "$MONITORS_CONF" <<'EOF'
nvidia-connected DFP-0,DFP-2
nvidia-edid DFP-0=/etc/desktop-container/edid-dfp0.bin
DP-0    2560x1440@60   +0+0      primary
HDMI-0  1920x1080@60   +2560+0
EOF
run nvidia
has "$MONITORS_OUT" 'Option      "MetaModes" "DP-0: 2560x1440 +0+0, HDMI-0: 1920x1080 +2560+0"' \
    "one MetaMode carries the whole layout"
has "$MONITORS_OUT" 'Option      "ConnectedMonitor" "DFP-0,DFP-2"' "nvidia-connected becomes ConnectedMonitor"
has "$MONITORS_OUT" 'Option      "CustomEDID" "DFP-0:/etc/desktop-container/edid-dfp0.bin"' \
    "nvidia-edid becomes CustomEDID"
has "$MONITORS_OUT" 'Option      "ModeValidation" "AllowNonEdidModes"' "mode validation allows non-EDID modes"
has "$MONITORS_OUT" 'Virtual 4480 1440' "the framebuffer is pinned (4480x1440)"
hasnt "$MONITORS_OUT" 'Section "Monitor"' "no Monitor sections, which the NVIDIA driver ignores"
hasnt "$MONITORS_OUT" 'Modeline' "no invented timing for a driver that validates its own"

log "nvidia: ConnectedMonitor and CustomEDID are opt-in"
cat > "$MONITORS_CONF" <<'EOF'
DP-0    1920x1080@60   +0+0   primary
EOF
run nvidia-plain
hasnt "$MONITORS_OUT" 'ConnectedMonitor' "without nvidia-connected, no ConnectedMonitor"
hasnt "$MONITORS_OUT" 'CustomEDID' "without nvidia-edid, no CustomEDID"
ev_end

# --- degraded host -----------------------------------------------------------
ev_begin S3.4.6 "Degraded host: no Device section" T0
log "no GPU device section: Monitor sections only, and a warning"
gpu_conf none
cat > "$MONITORS_CONF" <<'EOF'
DP-1    1920x1080@60   +0+0   primary
EOF
run no-device
has "$MONITORS_OUT" 'Section "Monitor"' "the Monitor sections are still written"
hasnt "$MONITORS_OUT" 'Section "Screen"' "no Screen section referencing a Device that does not exist"
logged 'framebuffer size is NOT pinned' "the generator warns that the framebuffer is not pinned"
ev_end

# --- rejections --------------------------------------------------------------
ev_begin S3.4.7 "A bad config is rejected whole" T0
log "a bad config is rejected whole, leaving nothing behind"
gpu_conf modesetting
while IFS='|' read -r slug what body; do
    [ -n "$slug" ] || continue
    printf '%b\n' "$body" > "$MONITORS_CONF"
    : > "$MONITORS_OUT"
    run "reject-$slug"
    absent "$what: rejected, and no file is left behind"
    logged 'ERROR' "$what: the generator says why (an ERROR line)"
done <<'EOF'
no-height|mode without a height|DP-1 1920 +0+0
xrandr-pos|position in xrandr --pos form|DP-1 1920x1080 0x0
unknown-flag|unknown flag|DP-1 1920x1080 +0+0 primaryy
two-primaries|two primaries|DP-1 1920x1080 +0+0 primary\nDP-2 1920x1080 +1920+0 primary
duplicate|duplicate output|DP-1 1920x1080 +0+0\nDP-1 1920x1080 +1920+0
bad-refresh|non-numeric refresh|DP-1 1920x1080@sixty +0+0
implausible|implausible mode|DP-1 4x4 +0+0
small-virtual|virtual smaller than the layout|virtual 1920x1080\nDP-1 1920x1080 +0+0\nDP-2 1920x1080 +1920+0
bad-virtual|virtual without a height|virtual 1920\nDP-1 1920x1080 +0+0
connected-empty|nvidia-connected without a list|nvidia-connected\nDP-1 1920x1080 +0+0
edid-no-equals|nvidia-edid without =|nvidia-edid DFP-0\nDP-1 1920x1080 +0+0
digit-name|output name starting with a digit|1DP 1920x1080 +0+0
bad-char-name|output name with an illegal character|DP/1 1920x1080 +0+0
watch-line|a watch line, which the generator does not know|watch 5\nDP-1 1920x1080 +0+0
EOF
ev_end

[ "$fails" = 0 ] || { echo "monitor layout tests: $fails failure(s)" >&2; exit 1; }
echo "monitor layout tests passed"
