#!/bin/bash
# Boot-time sanity checks for every assumption the desktop container makes.
# One line per assumption -- PASS / WARN / FAIL -- with a remediation hint
# on anything not green, so `podman logs desktop`
# explains a failure before anyone reads Xorg logs.
#
# Informational only: always exits 0. Runs from desktop-init after
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

# --- devices visible (granted by the quadlet, hardware present) -------------
shopt -s nullglob
cards=(/dev/dri/card*)
events=(/dev/input/event*)
snds=(/dev/snd/controlC*)
shopt -u nullglob

if [ ${#cards[@]} -gt 0 ]; then
    pass "DRM devices visible: ${cards[*]}"
else
    fail "no /dev/dri/card* visible: X cannot start. The quadlet's AddDevice= for /dev/dri did not resolve, host has no KMS video device, or (NVIDIA-driver host without GPU injection) nvidia_drm.modeset=1 is missing from the kernel cmdline"
fi

if [ ${#events[@]} -gt 0 ]; then
    pass "input devices visible: ${#events[@]} /dev/input/event* node(s)"
else
    fail "no /dev/input/event* visible: no keyboard/mouse will work. The quadlet's /dev/input bind mount is missing, device cgroup does not allow major 13, or host input drivers missing"
fi

if [ ${#snds[@]} -gt 0 ]; then
    pass "sound devices visible: ${#snds[@]} ALSA card(s)"
else
    warn "no /dev/snd/controlC* visible: PipeWire will run but expose no audio devices"
fi

if [ -e /dev/tty1 ]; then
    pass "/dev/tty1 present"
else
    fail "/dev/tty1 missing: the session cannot attach to a VT. The runtime did not expose VT devices AND the ensure-vt-devices mknod fallback failed (kernel without VT support?)"
fi

# --- host udev database ------------------------------------------------------
if [ -d /run/udev/data ] && [ -n "$(ls -A /run/udev/data 2>/dev/null)" ]; then
    pass "host udev database mounted at /run/udev"
else
    fail "host udev database missing or empty: libinput/logind cannot enumerate devices. Mount the host's /run/udev read-only into the container (quadlet Volume=/run/udev:/run/udev:ro)"
fi

# --- foreign seat tags (host seat attachments not undone) --------------------
foreign=$(grep -hE '^E:ID_SEAT=' /run/udev/data/* 2>/dev/null | grep -v '=seat0$' | sort -u)
if [ -n "$foreign" ]; then
    warn "devices tagged for a non-default seat ($(echo "$foreign" | tr '\n' ' ')): host 72-seat-*.rules not removed? desktop-seat-prep.service undoes these"
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

# --- pid namespace -----------------------------------------------------------
# The quadlet runs this container with --pid=host: that is what makes X
# client PIDs real host PIDs (window-to-pod identity, see README). If the
# flag is lost, everything still LOOKS fine - the desktop runs, clients
# connect - but every attribution silently reads pid 0. Catch it at boot:
# in a private pid namespace our init would be PID 1; in the host's it
# cannot be (the host's systemd is).
initpid=$(cat /run/desktop-init.pid 2>/dev/null || echo "")
if [ -z "$initpid" ]; then
    warn "no /run/desktop-init.pid: preflight running outside desktop-init?"
elif [ "$initpid" = 1 ]; then
    fail "container init is PID 1: the container is NOT in the host pid namespace (--pid=host missing from the quadlet), so X clients cannot be attributed to pods"
else
    pass "host pid namespace shared (init is host pid $initpid)"
fi

# --- shared socket directories ------------------------------------------------
for d in /tmp/.X11-unix /run/desktop-audio; do
    if [ -d "$d" ] && as_desktop test -w "$d"; then
        pass "$d exists and is writable by desktop"
    else
        warn "$d missing or not writable by desktop: exported sockets unavailable. Check the quadlet Volume= entries and the host tmpfiles.d config"
    fi
done

# --- host terminal (loopback ssh) ---------------------------------------------
if [ -f /etc/desktop-container/host-shell-key ]; then
    pass "host shell material mounted (Host Terminal -> ssh as '$(cat /etc/desktop-container/shell-user 2>/dev/null || echo '?')')"
else
    warn "no host shell material at /etc/desktop-container: the 'Host Terminal' menu entry will fail. Enable: the desktop-host-shell lines in the deploy tree's quadlet (deploy/README.md)"
fi

# --- fixed monitor layout ------------------------------------------------------
# Only the shallow check that has to happen BEFORE the generator runs: are the
# output names real? Everything else about the file (syntax, geometry, driver
# specifics) is xorg-monitor-conf's to validate and to log, later in this same
# unit. A name that matches nothing is the one mistake that costs an output
# silently - X simply never configures a Monitor section nobody claims.
MONCONF=${MONITORS_CONF:-/etc/desktop-container/monitors.conf}
if [ ! -f "$MONCONF" ]; then
    pass "no fixed monitor layout configured: Xorg will autodetect from EDID"
else
    declared=$(grep -vE '^[[:space:]]*(#|$)' "$MONCONF" \
        | grep -vE '^[[:space:]]*(watch|virtual|nvidia-connected|nvidia-edid)[[:space:]]' \
        | awk '{print $1}')
    if [ -z "$declared" ]; then
        pass "fixed monitor layout file present but declares no outputs: Xorg will autodetect"
    else
        unknown=""
        for o in $declared; do
            ls -d /sys/class/drm/card*-"$o" >/dev/null 2>&1 || unknown="$unknown $o"
        done
        if [ -z "$unknown" ]; then
            pass "fixed monitor layout declares$(printf ' %s' $declared), all present as DRM connectors"
        else
            # WARN, not FAIL: the NVIDIA driver's RandR output names are its
            # own (DP-0 where the kernel says DP-1), so a name with no matching
            # connector is expected there and wrong everywhere else.
            warn "fixed monitor layout names output(s)$unknown with no matching DRM connector ($(ls -d /sys/class/drm/card*-* 2>/dev/null | sed 's|.*/card[0-9]*-||' | tr '\n' ' ')). Expected on NVIDIA (its output names differ from the kernel's); a typo anywhere else - that output would never be configured"
        fi
    fi
fi

# --- NVIDIA coherence ----------------------------------------------------------
# NVIDIA_CDI_STUB=1 is injected by the deploy tree's stub CDI spec, written
# when the host has no working GPU stack. Hardware visible anyway (via the
# quadlet's device grants) means the stub is hiding a broken host, not a missing
# GPU - the one silent-degradation case worth a FAIL. CDI env edits land on
# the container's init process (NOT /proc/1, which is the host's systemd
# under --pid=host), so read desktop-init's environment via the pid it
# records; plain inheritance covers the fallback when that is unreadable.
cdi_stub=$(tr '\0' '\n' </proc/"$(cat /run/desktop-init.pid 2>/dev/null || echo self)"/environ 2>/dev/null | sed -n 's/^NVIDIA_CDI_STUB=//p')
if [ "${cdi_stub:-${NVIDIA_CDI_STUB:-}}" = 1 ] && [ -e /dev/nvidiactl ]; then
    fail "NVIDIA hardware visible but the host injected a STUB CDI spec: nvidia container toolkit missing/broken on the host (desktop-cdi-refresh fell back). GPU acceleration is OFF; fix the host toolkit and restart"
fi
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
