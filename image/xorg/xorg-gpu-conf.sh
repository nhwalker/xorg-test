#!/bin/bash
# Generate /etc/X11/xorg.conf.d/20-gpu.conf at container boot.
#
# Two modes:
#   1. NVIDIA GPU present (injected by the nvidia container toolkit / CDI):
#      use the "nvidia" driver, with a ModulePath covering wherever the
#      toolkit dropped nvidia_drv.so.
#   2. Otherwise: use the kernel modesetting driver on the first DRM card
#      that has a connected connector (unaccelerated is fine).
#
# Logs all the evidence the decision is based on, so the journal shows what
# the chooser saw, not just its conclusion.
set -u

OUT=/etc/X11/xorg.conf.d/20-gpu.conf
mkdir -p /etc/X11/xorg.conf.d

log() { echo "xorg-gpu-conf: $*"; }

emit_conf() {
    log "wrote $OUT:"
    sed 's/^/xorg-gpu-conf:     /' "$OUT"
}

# --- evidence ----------------------------------------------------------------
log "DRM nodes: $(ls -m /dev/dri 2>/dev/null || echo '(none)')"
shopt -s nullglob
for status in /sys/class/drm/card*-*/status; do
    log "connector $(basename "$(dirname "$status")"): $(cat "$status")"
done
shopt -u nullglob
log "NVIDIA nodes: $(ls -m /dev/nvidia* 2>/dev/null || echo '(none)')"

nvidia_drv=""
if [ -e /dev/nvidiactl ] || [ -e /dev/nvidia0 ]; then
    log "searching /usr/lib64 and /usr/lib for injected nvidia_drv.so"
    nvidia_drv=$(find /usr/lib64 /usr/lib -name nvidia_drv.so 2>/dev/null | head -n1)
    log "nvidia_drv.so: ${nvidia_drv:-NOT FOUND}"
    glxserver=$(find /usr/lib64 /usr/lib -name 'libglxserver_nvidia.so*' 2>/dev/null | head -n1)
    log "libglxserver_nvidia: ${glxserver:-NOT FOUND}"
    if [ -z "$nvidia_drv" ]; then
        log "warning: NVIDIA device nodes present but no nvidia_drv.so was injected;"
        log "warning: falling back to modesetting (see README, 'nvidia_drv.so missing')"
    fi
fi

# --- decision ----------------------------------------------------------------
if [ -n "$nvidia_drv" ]; then
    # ModulePath must point at the modules dir (parent of drivers/).
    moddir=$(dirname "$(dirname "$nvidia_drv")")
    log "decision: NVIDIA driver (module dir $moddir)"
    cat > "$OUT" <<EOF
# Generated at boot by xorg-gpu-conf.sh - NVIDIA mode. Do not edit.
Section "Files"
    ModulePath "$moddir"
    ModulePath "/usr/lib64/xorg/modules"
EndSection

Section "Device"
    Identifier "gpu0"
    Driver     "nvidia"
EndSection
EOF
    emit_conf
    exit 0
fi

card=""
for status in /sys/class/drm/card*-*/status; do
    [ -e "$status" ] || continue
    if [ "$(cat "$status")" = "connected" ]; then
        card=$(basename "$(dirname "$status")")
        card=/dev/dri/${card%%-*}
        log "first connected connector belongs to $card"
        break
    fi
done
if [ -z "$card" ]; then
    card=/dev/dri/card0
    log "no connected connector found in sysfs; defaulting to $card"
fi

if [ -e "$card" ]; then
    log "decision: modesetting driver on $card"
    cat > "$OUT" <<EOF
# Generated at boot by xorg-gpu-conf.sh - modesetting mode. Do not edit.
Section "Device"
    Identifier "gpu0"
    Driver     "modesetting"
    Option     "kmsdev" "$card"
EndSection
EOF
    emit_conf
else
    log "decision: $card does not exist; removing generated config, Xorg will autodetect (and likely fail: see preflight lines above)"
    rm -f "$OUT"
fi
