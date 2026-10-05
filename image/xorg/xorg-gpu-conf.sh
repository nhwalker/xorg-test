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

# Test overrides (Requirements.md, Appendix A); all unset in the image, where
# these are exactly the paths below:
#   GPU_DEV_DIR    where the DRM and NVIDIA device nodes are looked for
#   GPU_SYS_DRM    the sysfs DRM class directory (connector status)
#   GPU_LIB_DIRS   where an injected nvidia_drv.so is searched for
#   GPU_OUT        the config this writes
DEV=${GPU_DEV_DIR:-/dev}
SYS_DRM=${GPU_SYS_DRM:-/sys/class/drm}
LIB_DIRS=${GPU_LIB_DIRS:-/usr/lib64 /usr/lib}
OUT=${GPU_OUT:-/etc/X11/xorg.conf.d/20-gpu.conf}
mkdir -p "$(dirname "$OUT")"

log() { echo "xorg-gpu-conf: $*"; }

emit_conf() {
    log "wrote $OUT:"
    sed 's/^/xorg-gpu-conf:     /' "$OUT"
}

# --- evidence ----------------------------------------------------------------
log "DRM nodes: $(ls -m "$DEV/dri" 2>/dev/null || echo '(none)')"
shopt -s nullglob
for status in "$SYS_DRM"/card*-*/status; do
    log "connector $(basename "$(dirname "$status")"): $(cat "$status")"
done
shopt -u nullglob
log "NVIDIA nodes: $(ls -m "$DEV"/nvidia* 2>/dev/null || echo '(none)')"

nvidia_drv=""
if [ -e "$DEV/nvidiactl" ] || [ -e "$DEV/nvidia0" ]; then
    log "searching ${LIB_DIRS// / and } for injected nvidia_drv.so"
    # shellcheck disable=SC2086 # a list of directories
    nvidia_drv=$(find $LIB_DIRS -name nvidia_drv.so 2>/dev/null | head -n1)
    log "nvidia_drv.so: ${nvidia_drv:-NOT FOUND}"
    # shellcheck disable=SC2086
    glxserver=$(find $LIB_DIRS -name 'libglxserver_nvidia.so*' 2>/dev/null | head -n1)
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
for status in "$SYS_DRM"/card*-*/status; do
    [ -e "$status" ] || continue
    if [ "$(cat "$status")" = "connected" ]; then
        card=$(basename "$(dirname "$status")")
        card=$DEV/dri/${card%%-*}
        log "first connected connector belongs to $card"
        break
    fi
done
if [ -z "$card" ]; then
    card=$DEV/dri/card0
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
