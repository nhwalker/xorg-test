#!/bin/bash
# Generate /etc/X11/xorg.conf.d/20-gpu.conf at container boot.
#
# Two modes:
#   1. NVIDIA GPU present (injected by the nvidia container toolkit / CDI):
#      use the "nvidia" driver, with a ModulePath covering wherever the
#      toolkit dropped nvidia_drv.so.
#   2. Otherwise: use the kernel modesetting driver on the first DRM card
#      that has a connected connector (unaccelerated is fine).
set -u

OUT=/etc/X11/xorg.conf.d/20-gpu.conf
mkdir -p /etc/X11/xorg.conf.d

log() { echo "xorg-gpu-conf: $*"; }

nvidia_drv=""
if [ -e /dev/nvidiactl ] || [ -e /dev/nvidia0 ]; then
    nvidia_drv=$(find /usr/lib64 /usr/lib -name nvidia_drv.so 2>/dev/null | head -n1)
    if [ -z "$nvidia_drv" ]; then
        log "warning: NVIDIA device nodes present but no nvidia_drv.so was injected;"
        log "warning: falling back to modesetting (see README, 'nvidia_drv.so missing')"
    fi
fi

if [ -n "$nvidia_drv" ]; then
    # ModulePath must point at the modules dir (parent of drivers/).
    moddir=$(dirname "$(dirname "$nvidia_drv")")
    log "NVIDIA GPU detected, driver module: $nvidia_drv"
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
    exit 0
fi

card=""
for status in /sys/class/drm/card*-*/status; do
    [ -e "$status" ] || continue
    if [ "$(cat "$status")" = "connected" ]; then
        card=$(basename "$(dirname "$status")")
        card=/dev/dri/${card%%-*}
        break
    fi
done
[ -n "$card" ] || card=/dev/dri/card0

if [ -e "$card" ]; then
    log "no NVIDIA GPU, using modesetting on $card"
    cat > "$OUT" <<EOF
# Generated at boot by xorg-gpu-conf.sh - modesetting mode. Do not edit.
Section "Device"
    Identifier "gpu0"
    Driver     "modesetting"
    Option     "kmsdev" "$card"
EndSection
EOF
else
    log "warning: no /dev/dri card found; removing generated config, Xorg will autodetect"
    rm -f "$OUT"
fi
