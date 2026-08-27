#!/bin/bash
# Generate /etc/X11/xorg.conf.d/30-monitors.conf from the host-declared
# monitor layout, so the desktop's geometry is a FIXED property of the
# deployment rather than of whatever EDID happens to be readable at the
# moment Xorg starts.
#
# Why this exists: a KVM switch takes the video link with it. On switch-away
# the monitor's EDID disappears and the GPU sees a connector disconnect; the
# outputs X had enabled are then backed by nothing, and on switch-back
# nothing re-establishes them - mwm is not a desktop environment, so there is
# no RandR client watching for hotplug. The screen collapses onto whatever
# output survived, every window is reflowed into it, and the session never
# recovers. Input hotplug was solved by giving the container a live view of
# the host's /dev/input; video cannot be solved that way, because the device
# node never goes away - only the modes on it do.
#
# So: declare the layout instead of detecting it. Every output named in the
# config is forced ENABLED at a fixed mode and position whether or not the
# driver thinks anything is plugged in, and the framebuffer is pinned at the
# layout's extents. Xorg then has no reason to change geometry when a
# connector comes and goes, because it never consults the connector to decide
# what the geometry should be.
#
# Config (host-provided, mounted read-only at /etc/desktop-container):
#
#     # global, all optional
#     virtual 3840x1080             # override the computed framebuffer size
#     nvidia-connected DFP-0,DFP-1  # NVIDIA ConnectedMonitor (see below)
#     nvidia-edid DFP-0=/etc/desktop-container/edid-dfp0.bin
#
#     # one line per output: <output> <WxH[@Hz]> <+X+Y> [primary] [rotate=<dir>]
#     DP-1  1920x1080@60  +0+0     primary
#     DP-2  1920x1080@60  +1920+0
#
# Absent or output-less config = feature off: nothing is written, any stale
# generated file is removed, and Xorg autodetects exactly as before. It is
# opt-in per host because only the operator knows the layout.
#
# Runs from xorg-conf.service, AFTER xorg-gpu-conf.sh: the Screen section
# below references that script's Device section by identifier, and what has
# to be written differs by driver (see "two drivers, two mechanisms").
set -u

CONF=${MONITORS_CONF:-/etc/desktop-container/monitors.conf}
OUT=${MONITORS_OUT:-/etc/X11/xorg.conf.d/30-monitors.conf}
# Written by xorg-gpu-conf.sh; read here for the Device identifier and driver.
GPU_CONF=${XORG_GPU_CONF:-/etc/X11/xorg.conf.d/20-gpu.conf}
DEVICE_ID=gpu0

log() { echo "xorg-monitor-conf: $*"; }

# Give up cleanly: leave nothing half-written and let Xorg autodetect. A bad
# layout must not cost the operator a desktop that would otherwise boot -
# preflight-check.sh flags the config file, and these lines say what was
# wrong with it.
give_up() {
    log "ERROR: $*"
    log "no fixed layout applied; Xorg will autodetect (previous behaviour)"
    rm -f "$OUT"
    exit 0
}

# --- CVT timing generator ----------------------------------------------------
# VESA Coordinated Video Timings, standard (non-reduced) blanking - the same
# arithmetic as xf86CVTMode()/the cvt(1) tool, in integer shell so the image
# needs neither cvt nor a floating point helper.
#
# A generated Modeline is what makes "enabled while disconnected" actually
# work on the modesetting driver: with no monitor there is no EDID, with no
# EDID there are no modes, and an output with no modes cannot be turned on
# however forcefully it is enabled. Deriving the timing from the declared
# resolution means the mode list is identical whether the KVM is pointed at
# this host or not - which is the whole point.
#
# Time is carried in picoseconds; every intermediate is an exact integer at
# that scale, so nothing rounds differently from the float original.
# Sets CVT_NAME and CVT_MODELINE.
cvt_mode() {
    local w=$1 h=$2 mhz=$3          # mhz: refresh in milli-Hz (60000 = 60Hz)
    local vsync frame hperiod vsyncbp vtotal duty hblank htotal clock
    local hss hse vss vse

    # Vertical sync width comes from the aspect ratio (CVT table).
    if   [ $((h * 4 / 3))   -eq "$w" ]; then vsync=4
    elif [ $((h * 16 / 9))  -eq "$w" ]; then vsync=5
    elif [ $((h * 16 / 10)) -eq "$w" ]; then vsync=6
    elif [ $((h * 5 / 4))   -eq "$w" ]; then vsync=7
    elif [ $((h * 15 / 9))  -eq "$w" ]; then vsync=7
    else vsync=10
    fi

    # Horizontal period: the frame time less the 550us minimum vsync+back
    # porch, spread over the active lines plus the 3-line front porch.
    frame=$((1000000000000000 / mhz))
    hperiod=$(((frame - 550000000) / (h + 3)))
    [ "$hperiod" -gt 0 ] || return 1

    vsyncbp=$((550000000 / hperiod + 1))
    [ "$vsyncbp" -lt $((vsync + 6)) ] && vsyncbp=$((vsync + 6))
    vtotal=$((h + 3 + vsyncbp))

    # Blanking duty cycle on a percent scale carried in parts per million:
    # the CVT curve 30% - 300 * HPeriod(us)/1000, floored at the spec's 20%.
    duty=$((30000000 - 300 * hperiod / 1000))
    [ "$duty" -lt 20000000 ] && duty=20000000
    hblank=$((w * duty / (100000000 - duty)))
    hblank=$((hblank - hblank % 16))
    htotal=$((w + hblank))

    clock=$((htotal * 1000000000 / hperiod))    # kHz
    clock=$((clock - clock % 250))              # CVT clock step: 0.25 MHz

    hse=$((w + hblank / 2))
    hss=$((hse - htotal * 8 / 100))
    hss=$((hss + 8 - hss % 8))
    vss=$((h + 3))
    vse=$((vss + vsync))

    CVT_NAME=$(printf '%dx%d_%d.%02d' "$w" "$h" $((mhz / 1000)) $((mhz % 1000 / 10)))
    CVT_MODELINE=$(printf 'Modeline "%s" %d.%02d  %d %d %d %d  %d %d %d %d -hsync +vsync' \
        "$CVT_NAME" $((clock / 1000)) $((clock % 1000 / 10)) \
        "$w" "$hss" "$hse" "$htotal" "$h" "$vss" "$vse" "$vtotal")
}

# --- read the config ---------------------------------------------------------
if [ ! -f "$CONF" ]; then
    log "no $CONF: no fixed monitor layout configured, Xorg will autodetect"
    rm -f "$OUT"
    exit 0
fi

names=() widths=() heights=() rates=() xs=() ys=() rots=() prims=()
virt_w=0 virt_h=0 nv_connected="" nv_edids=()
primary_seen=""
lineno=0

while read -r f1 f2 f3 rest || [ -n "$f1" ]; do
    lineno=$((lineno + 1))
    case "$f1" in ''|'#'*) continue ;; esac

    case "$f1" in
    virtual)
        case "$f2" in
            *x*) virt_w=${f2%%x*}; virt_h=${f2##*x} ;;
            *)   give_up "$CONF:$lineno: virtual wants WxH, got '$f2'" ;;
        esac
        case "$virt_w$virt_h" in
            ''|*[!0-9]*) give_up "$CONF:$lineno: virtual wants WxH, got '$f2'" ;;
        esac
        continue ;;
    nvidia-connected)
        [ -n "$f2" ] || give_up "$CONF:$lineno: nvidia-connected wants a display device list"
        nv_connected=$f2
        continue ;;
    nvidia-edid)
        case "$f2" in
            ?*=?*) nv_edids+=("$f2") ;;
            *)     give_up "$CONF:$lineno: nvidia-edid wants <display-device>=<path>, got '$f2'" ;;
        esac
        continue ;;
    esac

    # --- an output line ---
    case "$f1" in
        [A-Za-z]*) : ;;
        *) give_up "$CONF:$lineno: '$f1' is neither a known keyword nor an output name" ;;
    esac
    case "$f1" in
        *[!A-Za-z0-9._-]*) give_up "$CONF:$lineno: bad output name '$f1'" ;;
    esac

    # mode: WxH, or WxH@R with R optionally fractional (59.94)
    spec=${f2%%@*}
    rate=60000
    if [ "$f2" != "$spec" ]; then
        r=${f2##*@}
        r_int=${r%%.*}
        case "$r_int" in
            ''|*[!0-9]*) give_up "$CONF:$lineno: bad refresh rate '$r'" ;;
        esac
        if [ "$r" = "$r_int" ]; then
            rate=$((r_int * 1000))
        else
            r_frac=${r#*.}
            case "$r_frac" in
                ''|*[!0-9]*) give_up "$CONF:$lineno: bad refresh rate '$r'" ;;
            esac
            r_frac=$(printf '%s00' "$r_frac" | cut -c1-3)
            rate=$((r_int * 1000 + 10#$r_frac))
        fi
    fi
    case "$spec" in
        *x*) w=${spec%%x*}; h=${spec##*x} ;;
        *)   give_up "$CONF:$lineno: mode wants WxH[@Hz], got '$f2'" ;;
    esac
    case "$w$h" in
        ''|*[!0-9]*) give_up "$CONF:$lineno: mode wants WxH[@Hz], got '$f2'" ;;
    esac
    { [ "$w" -ge 64 ] && [ "$h" -ge 64 ] && [ "$rate" -ge 20000 ]; } \
        || give_up "$CONF:$lineno: implausible mode '$f2'"

    # position: +X+Y (the same spelling xrandr(1) prints)
    case "$f3" in
        +*+*) x=${f3#+}; x=${x%%+*}; y=${f3##*+} ;;
        *)    give_up "$CONF:$lineno: position wants +X+Y, got '$f3'" ;;
    esac
    case "$x$y" in
        ''|*[!0-9]*) give_up "$CONF:$lineno: position wants +X+Y, got '$f3'" ;;
    esac

    prim=- rot=normal
    for flag in $rest; do
        case "$flag" in
            primary)
                [ -z "$primary_seen" ] \
                    || give_up "$CONF:$lineno: a second primary output ('$primary_seen' already is)"
                primary_seen=$f1
                prim=primary ;;
            rotate=normal|rotate=left|rotate=right|rotate=inverted)
                rot=${flag#rotate=} ;;
            '#'*) break ;;
            *) give_up "$CONF:$lineno: unknown flag '$flag'" ;;
        esac
    done

    for prev in ${names[@]+"${names[@]}"}; do
        [ "$prev" = "$f1" ] && give_up "$CONF:$lineno: output '$f1' declared twice"
    done

    names+=("$f1"); widths+=("$w"); heights+=("$h"); rates+=("$rate")
    xs+=("$x"); ys+=("$y"); rots+=("$rot"); prims+=("$prim")
done < "$CONF"

if [ ${#names[@]} -eq 0 ]; then
    log "$CONF declares no outputs: no fixed layout, Xorg will autodetect"
    rm -f "$OUT"
    exit 0
fi

# --- framebuffer extents -----------------------------------------------------
# Rotation is applied by the CRTC, so a rotated output occupies its transposed
# size on the screen: the layout has to be measured in what lands on the
# framebuffer, not in what the panel scans out.
ext_w=() ext_h=()
need_w=0 need_h=0
for i in "${!names[@]}"; do
    case "${rots[$i]}" in
        left|right) ew=${heights[$i]}; eh=${widths[$i]} ;;
        *)          ew=${widths[$i]};  eh=${heights[$i]} ;;
    esac
    ext_w+=("$ew"); ext_h+=("$eh")
    [ $((xs[i] + ew)) -gt "$need_w" ] && need_w=$((xs[i] + ew))
    [ $((ys[i] + eh)) -gt "$need_h" ] && need_h=$((ys[i] + eh))
done
if [ "$virt_w" -eq 0 ]; then
    virt_w=$need_w virt_h=$need_h
elif [ "$virt_w" -lt "$need_w" ] || [ "$virt_h" -lt "$need_h" ]; then
    give_up "virtual ${virt_w}x${virt_h} is smaller than the declared layout (${need_w}x${need_h})"
fi

# --- which driver did xorg-gpu-conf.sh pick? ---------------------------------
# Two drivers, two mechanisms for the same thing, and neither understands the
# other's. The generic RandR-1.2 layer that modesetting uses takes per-output
# Monitor sections; the NVIDIA driver does not use that layer at all and takes
# a MetaMode string instead. Both are decided from the Device section that
# script wrote, so there stays exactly one place that knows which driver runs.
driver=modesetting
have_device=no
if [ -f "$GPU_CONF" ] && grep -q "Identifier[[:space:]]*\"$DEVICE_ID\"" "$GPU_CONF"; then
    have_device=yes
    grep -qi 'Driver[[:space:]]*"nvidia"' "$GPU_CONF" && driver=nvidia
fi
log "driver from $GPU_CONF: $driver (Device \"$DEVICE_ID\" present: $have_device)"

# The Screen section carries the pinned framebuffer size, and it can only
# exist if there is a Device to attach it to: a Screen referencing a Device
# section that was never written is a hard Xorg config error, and refusing to
# start is a worse outcome than the diagnosis xorg-gpu-conf.sh already logged.
if [ "$have_device" = no ]; then
    log "warning: no Device \"$DEVICE_ID\" in $GPU_CONF (no usable GPU?); emitting Monitor sections"
    log "warning: only, so the framebuffer size is NOT pinned. Fix the GPU first - see the lines above"
fi

# Per-output mode names and timings, resolved before anything is emitted so a
# failure here still reaches the journal rather than the config file.
mode_names=() modelines=()
for i in "${!names[@]}"; do
    if [ "$driver" = nvidia ]; then
        # MetaMode entries name a resolution and let the driver pick the
        # timing from its own validated pool; a name it cannot resolve is a
        # failure to start, so nothing invented is put in front of it.
        mode_names+=("${widths[$i]}x${heights[$i]}")
        modelines+=("")
    else
        cvt_mode "${widths[$i]}" "${heights[$i]}" "${rates[$i]}" \
            || give_up "no CVT timing for ${names[$i]} ${widths[$i]}x${heights[$i]}@${rates[$i]}mHz"
        mode_names+=("$CVT_NAME")
        modelines+=("$CVT_MODELINE")
    fi
done

meta=""
if [ "$driver" = nvidia ]; then
    for i in "${!names[@]}"; do
        entry=$(printf '%s: %s +%s+%s' "${names[$i]}" "${mode_names[$i]}" "${xs[$i]}" "${ys[$i]}")
        [ "${rots[$i]}" = normal ] || entry="$entry {Rotation=${rots[$i]}}"
        if [ -z "$meta" ]; then meta=$entry; else meta="$meta, $entry"; fi
    done
fi

# --- emit --------------------------------------------------------------------
{
printf '# Generated at boot by xorg-monitor-conf.sh from %s. Do not edit.\n' "$CONF"
printf '# Fixed layout: %sx%s framebuffer, %d output(s), %s driver.\n\n' \
    "$virt_w" "$virt_h" "${#names[@]}" "$driver"

# NVIDIA takes no per-output Monitor sections at all: its whole layout is the
# one MetaMode in the Screen section below.
for i in "${!names[@]}"; do
    [ "$driver" = nvidia ] && break
    printf 'Section "Monitor"\n'
    # Identifier = the RandR output name. With no "Monitor-<output>" option in
    # the Device section, the server falls back to matching a Monitor section
    # whose identifier IS the output name, which keeps this file independent
    # of the one xorg-gpu-conf.sh owns.
    printf '    Identifier  "%s"\n' "${names[$i]}"
    # Sync ranges wide enough to accept anything declarable. Their real job is
    # to exist: a Monitor section that states them makes mode validation use
    # these instead of the EDID's, so the mode list stops depending on a
    # monitor being present to describe itself.
    printf '    HorizSync   15.0 - 300.0\n'
    printf '    VertRefresh 20.0 - 250.0\n'
    printf '    %s\n' "${modelines[$i]}"
    # Enable: force the output on even where the driver reports it
    # disconnected. This is the line that survives a KVM switch.
    printf '    Option      "Enable" "true"\n'
    printf '    Option      "PreferredMode" "%s"\n' "${mode_names[$i]}"
    printf '    Option      "Position" "%s %s"\n' "${xs[$i]}" "${ys[$i]}"
    [ "${rots[$i]}" = normal ] || printf '    Option      "Rotate" "%s"\n' "${rots[$i]}"
    [ "${prims[$i]}" != primary ] || printf '    Option      "Primary" "true"\n'
    printf 'EndSection\n\n'
done

if [ "$have_device" = yes ]; then
    printf 'Section "Screen"\n'
    printf '    Identifier  "screen0"\n'
    printf '    Device      "%s"\n' "$DEVICE_ID"
    if [ "$driver" = nvidia ]; then
        # One MetaMode is the driver's whole statement about the layout, and
        # it is a statement about the X screen rather than about what is
        # plugged in - so it holds across connector events by construction.
        #
        # These options sit in the Screen section deliberately: the driver
        # reads Device and Screen options from one merged list, and keeping
        # them here leaves the Device section that xorg-gpu-conf.sh owns
        # untouched.
        printf '    Option      "MetaModes" "%s"\n' "$meta"
        # Let the driver use modes it did not learn from an EDID - needed as
        # soon as an output is forced on with nothing attached to describe it.
        printf '    Option      "ModeValidation" "AllowNonEdidModes"\n'
        if [ -n "$nv_connected" ]; then
            # The NVIDIA counterpart of Option "Enable": treat these display
            # devices as permanently connected. Opt-in, and spelled in the
            # driver's own device names (DFP-0, not the RandR output name
            # DP-0), because only the operator can supply them - see
            # deploy/README.md.
            printf '    Option      "ConnectedMonitor" "%s"\n' "$nv_connected"
        fi
        for e in ${nv_edids[@]+"${nv_edids[@]}"}; do
            printf '    Option      "CustomEDID" "%s:%s"\n' "${e%%=*}" "${e#*=}"
        done
    fi
    # The framebuffer, pinned. Every enabled output above already sums to
    # exactly this, so it changes nothing at startup - it is here for the case
    # where an output does NOT come up: the screen is still allocated at full
    # size, so re-establishing that output later is a mode set and not a
    # screen resize. A resize is what moves every window on a desktop whose
    # window manager (mwm) has never heard of RandR.
    printf '    SubSection "Display"\n'
    printf '        Virtual %s %s\n' "$virt_w" "$virt_h"
    printf '    EndSubSection\n'
    printf 'EndSection\n'
fi
} > "$OUT"

log "wrote $OUT:"
sed 's/^/xorg-monitor-conf:     /' "$OUT"
log "fixed layout ${virt_w}x${virt_h}: ${names[*]} (driver $driver)"
exit 0
