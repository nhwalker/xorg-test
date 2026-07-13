#!/bin/bash
# Host-side installer for the containerized desktop (Xorg + mwm + PipeWire).
#
# What it does:
#   1. Builds (or reuses) the container image.
#   2. Undoes host seat/graphical configuration so the container can take
#      the seat devices: disables the display manager, sets the
#      multi-user.target default, removes `loginctl attach` seat udev rules,
#      frees tty1, and stops host logind from spawning gettys / reserving VTs.
#   3. Detects an NVIDIA GPU + nvidia container toolkit and, if present,
#      generates a CDI spec and a quadlet drop-in to inject the GPU.
#   4. Sets up the shared audio socket dir and host-side audio client
#      configs (Pulse client.conf drop-in + asound.conf via the pulse
#      plugin) so pulse/pipewire/alsa clients on the host reach the
#      container's PipeWire.
#   5. Installs the quadlet unit and starts desktop.service.
#
# Usage:
#   ./install.sh [--no-gpu] [--no-build] [--image REF]
#   ./install.sh --uninstall
#
# Everything is idempotent; prior host state is recorded under
# /var/lib/desktop-container so --uninstall can restore it.

set -euo pipefail

IMAGE="localhost/desktop-container:latest"
STATE_DIR="/var/lib/desktop-container"
QUADLET_DIR="/etc/containers/systemd"
DROPIN_DIR="$QUADLET_DIR/desktop.container.d"
AUDIO_DIR="/run/desktop-audio"
TMPFILES_CONF="/etc/tmpfiles.d/desktop-container.conf"
LOGIND_DROPIN="/etc/systemd/logind.conf.d/50-desktop-container.conf"
PULSE_CLIENT_CONF="/etc/pulse/client.conf.d/50-desktop-container.conf"
ASOUND_CONF="/etc/asound.conf"
VT="tty1"
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

DO_GPU=auto
DO_BUILD=1
UNINSTALL=0

log()  { echo "[install] $*"; }
warn() { echo "[install] WARNING: $*" >&2; }
die()  { echo "[install] ERROR: $*" >&2; exit 1; }

while [ $# -gt 0 ]; do
    case "$1" in
        --uninstall) UNINSTALL=1 ;;
        --no-gpu)    DO_GPU=0 ;;
        --no-build)  DO_BUILD=0 ;;
        --image)     shift; IMAGE="${1:?--image needs an argument}" ;;
        -h|--help)   grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) die "unknown argument: $1" ;;
    esac
    shift
done

[ "$(id -u)" = 0 ] || die "must run as root"
command -v podman >/dev/null || die "podman is required"
command -v systemctl >/dev/null || die "systemd host is required"

podman_minor=$(podman --version | grep -oE '[0-9]+\.[0-9]+' | head -n1)
case "$podman_minor" in
    [0-3].*|4.[0-3]) die "podman >= 4.4 required for quadlet (found $podman_minor)" ;;
esac

# ---------------------------------------------------------------------------
uninstall() {
    log "stopping and removing desktop.service"
    systemctl stop desktop.service 2>/dev/null || true
    rm -f "$QUADLET_DIR/desktop.container"
    rm -rf "$DROPIN_DIR"
    systemctl daemon-reload

    log "restoring host seat configuration"
    if [ -d "$STATE_DIR/seat-rules" ]; then
        cp -a "$STATE_DIR/seat-rules/." /etc/udev/rules.d/ 2>/dev/null || true
    fi
    udevadm control --reload || true
    udevadm trigger --subsystem-match=drm --subsystem-match=input \
        --subsystem-match=sound --subsystem-match=graphics || true

    systemctl unmask "getty@$VT.service" 2>/dev/null || true
    systemctl start "getty@$VT.service" 2>/dev/null || true

    rm -f "$LOGIND_DROPIN"
    systemctl try-restart systemd-logind 2>/dev/null || true

    if [ -f "$STATE_DIR/default-target" ]; then
        systemctl set-default "$(cat "$STATE_DIR/default-target")" || true
    fi
    if [ -f "$STATE_DIR/display-manager" ]; then
        dm=$(cat "$STATE_DIR/display-manager")
        log "re-enabling display manager $dm (not started; reboot or start manually)"
        systemctl enable "$dm" 2>/dev/null || true
    fi

    log "removing audio client configuration"
    rm -f "$PULSE_CLIENT_CONF"
    if [ -f "$STATE_DIR/asound.conf.orig" ]; then
        cp -a "$STATE_DIR/asound.conf.orig" "$ASOUND_CONF"
    elif grep -q desktop-container "$ASOUND_CONF" 2>/dev/null; then
        rm -f "$ASOUND_CONF"
    fi
    rm -f "$TMPFILES_CONF"

    rm -rf "$STATE_DIR"
    log "uninstalled. The container image ($IMAGE) was kept; remove with: podman rmi $IMAGE"
    exit 0
}
[ "$UNINSTALL" = 1 ] && uninstall

# ---------------------------------------------------------------------------
mkdir -p "$STATE_DIR"

if [ "$DO_BUILD" = 1 ]; then
    [ -f "$REPO_DIR/Containerfile" ] || die "Containerfile not found next to install.sh (use --no-build with a prebuilt --image)"
    log "building $IMAGE"
    podman build -t "$IMAGE" -f "$REPO_DIR/Containerfile" "$REPO_DIR"
else
    log "skipping build; using image $IMAGE"
fi

# --- 1. Disable host graphical stack ---------------------------------------
if [ ! -f "$STATE_DIR/default-target" ]; then
    systemctl get-default > "$STATE_DIR/default-target"
fi
if dm_unit=$(readlink -f /etc/systemd/system/display-manager.service 2>/dev/null); then
    dm=$(basename "$dm_unit")
    log "disabling display manager: $dm"
    echo "$dm" > "$STATE_DIR/display-manager"
    systemctl disable --now display-manager.service || true
fi
log "setting default target to multi-user.target"
systemctl set-default multi-user.target >/dev/null

# --- 2. Undo seat attachments (loginctl attach writes 72-seat-*.rules) ------
mkdir -p "$STATE_DIR/seat-rules"
found_seat_rules=0
for f in /etc/udev/rules.d/72-seat-*.rules; do
    [ -e "$f" ] || continue
    found_seat_rules=1
    log "removing seat attachment rule: $f (backed up to $STATE_DIR/seat-rules)"
    mv "$f" "$STATE_DIR/seat-rules/"
done
if [ "$found_seat_rules" = 1 ]; then
    udevadm control --reload
    udevadm trigger --subsystem-match=drm --subsystem-match=input \
        --subsystem-match=sound --subsystem-match=graphics || true
fi

# --- 3. Free the VT and quiet host logind -----------------------------------
log "masking getty@$VT.service and disabling host auto-VTs"
systemctl mask --now "getty@$VT.service" >/dev/null
mkdir -p "$(dirname "$LOGIND_DROPIN")"
cat > "$LOGIND_DROPIN" <<'EOF'
# Installed by desktop-container install.sh.
# The containerized Xorg owns the VT; host logind must not spawn gettys on
# VT switches or reserve a VT for itself.
[Login]
NAutoVTs=0
ReserveVT=0
EOF
systemctl try-restart systemd-logind || warn "could not restart systemd-logind; changes apply after reboot"

# --- 4. Shared dirs (audio sockets, X socket) --------------------------------
cat > "$TMPFILES_CONF" <<'EOF'
# Installed by desktop-container install.sh.
d /run/desktop-audio 1777 root root -
d /tmp/.X11-unix 1777 root root -
EOF
systemd-tmpfiles --create "$TMPFILES_CONF"

# --- 5. Host audio client configuration --------------------------------------
log "writing Pulse client config ($PULSE_CLIENT_CONF)"
mkdir -p "$(dirname "$PULSE_CLIENT_CONF")"
cat > "$PULSE_CLIENT_CONF" <<'EOF'
# Installed by desktop-container install.sh.
# Route PulseAudio clients on the host to the containerized desktop's
# pipewire-pulse socket.
default-server = unix:/run/desktop-audio/pulse
autospawn = no
EOF

log "writing ALSA client config ($ASOUND_CONF)"
if [ -f "$ASOUND_CONF" ] && ! grep -q desktop-container "$ASOUND_CONF"; then
    cp -a "$ASOUND_CONF" "$STATE_DIR/asound.conf.orig"
    warn "existing $ASOUND_CONF backed up to $STATE_DIR/asound.conf.orig"
fi
cat > "$ASOUND_CONF" <<'EOF'
# Installed by desktop-container install.sh.
# Route ALSA clients on the host through the pulse plugin to the
# containerized desktop's pipewire-pulse socket. Raw hw access would fight
# the container's PipeWire for the devices.
pcm.!default {
    type pulse
    server "unix:/run/desktop-audio/pulse"
}
ctl.!default {
    type pulse
    server "unix:/run/desktop-audio/pulse"
}
EOF
if [ ! -e /usr/lib64/alsa-lib/libasound_module_pcm_pulse.so ] \
   && [ ! -e /usr/lib/x86_64-linux-gnu/alsa-lib/libasound_module_pcm_pulse.so ]; then
    warn "alsa-plugins-pulseaudio not found on host; ALSA clients won't work until it is installed"
fi

# --- 6. GPU (NVIDIA container toolkit / CDI) ---------------------------------
gpu_enabled=0
if [ "$DO_GPU" != 0 ]; then
    if command -v nvidia-ctk >/dev/null && [ -e /dev/nvidiactl ]; then
        log "NVIDIA GPU + nvidia-ctk found; generating CDI spec"
        mkdir -p /etc/cdi
        nvidia-ctk cdi generate --output=/etc/cdi/nvidia.yaml
        mkdir -p "$DROPIN_DIR"
        cat > "$DROPIN_DIR/10-gpu.conf" <<'EOF'
# Installed by desktop-container install.sh (GPU detected).
[Container]
AddDevice=nvidia.com/gpu=all
Environment=NVIDIA_DRIVER_CAPABILITIES=all
EOF
        gpu_enabled=1
        if ! grep -q nvidia_drv.so /etc/cdi/nvidia.yaml; then
            warn "CDI spec does not include nvidia_drv.so (older toolkit);"
            warn "adding bind-mount fallback for the Xorg driver modules"
            xdrv=$(find /usr/lib64/xorg/modules /usr/lib/xorg/modules -name nvidia_drv.so 2>/dev/null | head -n1)
            glxsrv=$(find /usr/lib64/xorg/modules /usr/lib/xorg/modules -name 'libglxserver_nvidia.so*' 2>/dev/null | head -n1)
            if [ -n "$xdrv" ]; then
                {
                    echo "Volume=$xdrv:/usr/lib64/xorg/modules/drivers/nvidia_drv.so:ro"
                    [ -n "$glxsrv" ] && echo "Volume=$glxsrv:/usr/lib64/xorg/modules/extensions/$(basename "$glxsrv"):ro"
                } >> "$DROPIN_DIR/10-gpu.conf"
            else
                warn "nvidia_drv.so not found on host either; Xorg will fall back to modesetting"
            fi
        fi
    else
        log "no NVIDIA GPU / nvidia-ctk on host; container will use modesetting (no acceleration)"
    fi
else
    log "--no-gpu: skipping GPU setup"
fi

# --- 7. Quadlet ---------------------------------------------------------------
log "installing quadlet unit to $QUADLET_DIR/desktop.container"
mkdir -p "$QUADLET_DIR"
sed "s|^Image=.*|Image=$IMAGE|" "$REPO_DIR/quadlet/desktop.container" \
    > "$QUADLET_DIR/desktop.container"
systemctl daemon-reload
log "starting desktop.service"
systemctl start desktop.service

echo
log "done. GPU injection: $([ "$gpu_enabled" = 1 ] && echo enabled || echo disabled)"
log "status:  systemctl status desktop.service"
log "logs:    podman logs desktop   /   journalctl -u desktop.service"
log "clients: DISPLAY=:0, PULSE_SERVER=unix:/run/desktop-audio/pulse,"
log "         PIPEWIRE_REMOTE=/run/desktop-audio/pipewire-0 (see README.md)"
