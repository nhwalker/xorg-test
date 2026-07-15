#!/bin/bash
# Boot-time sanity checks for every assumption the desktop container makes.
# One line per assumption -- PASS / WARN / FAIL -- with a remediation hint
# on anything not green, so `journalctl -u xorg-conf` (or `podman logs`)
# explains a failure before anyone reads Xorg logs.
#
# Informational only: always exits 0. Runs from xorg-conf.service after
# align-device-groups.sh (the readability checks depend on aligned gids).
set -u

pass() { echo "preflight: PASS: $*"; }
warn() { echo "preflight: WARN: $*"; }
fail() { echo "preflight: FAIL: $*"; }

# setpriv, not runuser: no PAM session, so no pam_unix open/close noise in
# the journal on every boot.
if command -v setpriv >/dev/null; then
    as_desktop() { setpriv --reuid=desktop --regid=desktop --init-groups "$@" 2>/dev/null; }
else
    warn "setpriv not available; user-perspective checks run as root (less accurate)"
    as_desktop() { "$@" 2>/dev/null; }
fi

# --- devices visible (privileged /dev, hardware present) --------------------
shopt -s nullglob
cards=(/dev/dri/card*)
events=(/dev/input/event*)
snds=(/dev/snd/controlC*)
shopt -u nullglob

if [ ${#cards[@]} -gt 0 ]; then
    pass "DRM devices visible: ${cards[*]}"
else
    fail "no /dev/dri/card* visible: X cannot start. Container not privileged, host has no KMS video device, or (NVIDIA-driver host without GPU injection) nvidia_drm.modeset=1 is missing from the kernel cmdline"
fi

if [ ${#events[@]} -gt 0 ]; then
    pass "input devices visible: ${#events[@]} /dev/input/event* node(s)"
else
    fail "no /dev/input/event* visible: no keyboard/mouse will work. Container not privileged, or host input drivers missing"
fi

if [ ${#snds[@]} -gt 0 ]; then
    pass "sound devices visible: ${#snds[@]} ALSA card(s)"
else
    warn "no /dev/snd/controlC* visible: PipeWire will run but expose no audio devices"
fi

if [ -e /dev/tty1 ]; then
    pass "/dev/tty1 present"
else
    fail "/dev/tty1 missing: the session cannot attach to a VT (container not privileged?)"
fi

# --- host udev database ------------------------------------------------------
if [ -d /run/udev/data ] && [ -n "$(ls -A /run/udev/data 2>/dev/null)" ]; then
    pass "host udev database mounted at /run/udev"
else
    fail "host udev database missing or empty: libinput/logind cannot enumerate devices. Mount the host's /run/udev read-only into the container (quadlet Volume=/run/udev:/run/udev:ro, or the chart's hostPaths.udev)"
fi

# --- foreign seat tags (host seat attachments not undone) --------------------
foreign=$(grep -hE '^E:ID_SEAT=' /run/udev/data/* 2>/dev/null | grep -v '=seat0$' | sort -u)
if [ -n "$foreign" ]; then
    warn "devices tagged for a non-default seat ($(echo "$foreign" | tr '\n' ' ')): host 72-seat-*.rules not removed? Rerun install.sh"
else
    pass "no foreign seat tags in the udev database"
fi

# --- can the session user actually open the devices? (gid alignment) ---------
for n in "${cards[0]:-}" "${events[0]:-}" "${snds[0]:-}"; do
    [ -n "$n" ] || continue
    if as_desktop test -r "$n"; then
        pass "desktop user can read $n"
    else
        fail "desktop user CANNOT read $n ($(stat -c '%a %U:%G' "$n")): gid alignment failed, see align-device-groups lines above. Escape hatch: needs_root_rights=yes in /etc/X11/Xwrapper.config"
    fi
done

# --- logind ------------------------------------------------------------------
if [ "$(systemctl is-enabled systemd-logind.service 2>/dev/null)" = "masked" ]; then
    fail "systemd-logind is masked: PAM session/seat registration will fail (the image build should have unmasked it)"
else
    pass "systemd-logind is not masked"
fi

# --- shared socket directories ------------------------------------------------
for d in /tmp/.X11-unix /run/desktop-audio; do
    if [ -d "$d" ] && as_desktop test -w "$d"; then
        pass "$d exists and is writable by desktop"
    else
        warn "$d missing or not writable by desktop: exported sockets unavailable. Check the quadlet Volume= entries and the host tmpfiles.d config"
    fi
done

# --- NVIDIA coherence ----------------------------------------------------------
drv=$(find /usr/lib64 /usr/lib -name nvidia_drv.so 2>/dev/null | head -n1)
if [ -e /dev/nvidiactl ] && [ -z "$drv" ]; then
    warn "NVIDIA device nodes present but nvidia_drv.so NOT injected: X falls back to unaccelerated modesetting. Toolkit CDI spec lacks the X driver, see README ('nvidia_drv.so missing')"
elif [ -n "$drv" ] && [ ! -e /dev/nvidiactl ]; then
    warn "nvidia_drv.so present but no NVIDIA device nodes: GPU not injected (missing AddDevice=nvidia.com/gpu=all drop-in?)"
elif [ -e /dev/nvidiactl ]; then
    pass "NVIDIA GPU injected together with X driver module ($drv)"
else
    pass "no NVIDIA GPU present: modesetting path will be used"
fi

exit 0
