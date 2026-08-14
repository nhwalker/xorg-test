#!/bin/bash
# Converge the host seat state for the containerized desktop (run at every
# boot by desktop-seat-prep.service; also safe to run by hand when
# converting a live host). Assumes NOTHING about the initial state: any
# combination of running display manager, spawned gettys, custom seat
# attachments, or a graphical default target is walked back to what the
# quadlet needs:
#   - every seat device on the default seat0 (loginctl-attach rules removed)
#   - no display manager enabled or running; multi-user.target the default
#   - getty masked and stopped on the desktop's VT
#   - nothing holding DRM or the VT (the desktop's Xorg must be first opener)
#
# Convergence deletes rather than backs up - no /var/lib state, matching
# the rest of the tree: a host is reprovisioned back, not uninstalled back.
# Exits nonzero only when the seat CANNOT be made ready (an unknown process
# still holds a DRM device or the VT); everything else converges silently
# and idempotently, so steady-state boots log nothing and change nothing.
set -euo pipefail

VT="${DESKTOP_VT:-tty1}"
changed=0

log() { echo "seat-prep: $*"; }

# --- 1. custom seat attachments (loginctl attach writes 72-seat-*.rules) ----
# Any multi-seat split hides devices from the container's logind, which
# expects everything on the default seat0.
for f in /etc/udev/rules.d/72-seat-*.rules; do
    [ -e "$f" ] || continue
    log "removing custom seat attachment rule $f"
    rm -f "$f"
    changed=1
done
if [ "$changed" = 1 ]; then
    udevadm control --reload
    udevadm trigger --subsystem-match=drm --subsystem-match=input \
        --subsystem-match=sound --subsystem-match=graphics || true
    udevadm settle --timeout=15 || true
fi

# --- 2. display manager: not running, not enabled ---------------------------
# The quadlet's Conflicts= would stop a running one anyway; disabling also
# survives a package install or an admin re-enabling it between boots.
# Operate on the RESOLVED unit, not the display-manager.service alias:
# disabling the alias removes the alias symlink first, after which --now
# cannot resolve the name and the real unit keeps running.
if [ -e /etc/systemd/system/display-manager.service ]; then
    dm=$(basename "$(readlink -f /etc/systemd/system/display-manager.service)")
    log "disabling display manager $dm"
    systemctl disable --now "$dm" || true
    changed=1
fi

# --- 3. boot target: multi-user ----------------------------------------------
# The tree ships the default.target symlink, but a later package install or
# a stray set-default can flip it back; converge every boot.
if [ "$(systemctl get-default)" != multi-user.target ]; then
    log "setting default target to multi-user.target"
    systemctl set-default multi-user.target >/dev/null
    changed=1
fi

# --- 4. the VT: no getty, ever -----------------------------------------------
if [ "$(systemctl is-enabled "getty@$VT.service" 2>/dev/null || true)" != masked ]; then
    log "masking getty@$VT.service"
    systemctl mask --now "getty@$VT.service" >/dev/null
    changed=1
elif systemctl is-active --quiet "getty@$VT.service"; then
    # masked (e.g. by this tree's symlink) but started before the mask landed
    log "stopping running getty@$VT.service"
    systemctl stop "getty@$VT.service"
    changed=1
fi

# --- 5. logind: make sure NAutoVTs=0 / ReserveVT=0 are in effect -------------
# The drop-in is a static file in this tree, but logind only reads it at
# start. Restart logind only when this run actually changed seat state -
# steady-state boots must not churn it. Safe: logind keeps state in /run.
if [ "$changed" = 1 ]; then
    if [ ! -f /etc/systemd/logind.conf.d/50-desktop-container.conf ]; then
        log "WARNING: logind drop-in missing - deploy tree not fully applied?"
    fi
    systemctl try-restart systemd-logind \
        || log "WARNING: could not restart systemd-logind; NAutoVTs/ReserveVT apply after reboot"
fi

# --- 6. gate: DRM and the VT must actually be takeable -----------------------
# Everything above is convergence; this verifies it worked. A process still
# holding a DRM device here (a compositor we don't know about, a session
# that outlived its display manager) would make Xorg fail drmSetMaster -
# fail loudly now, naming the culprit, instead of letting the desktop boot
# into that error.
if command -v fuser >/dev/null; then
    shopt -s nullglob
    holders=""
    for dev in /dev/dri/card* "/dev/$VT"; do
        [ -e "$dev" ] || continue
        if pids=$(fuser "$dev" 2>/dev/null) && [ -n "${pids// /}" ]; then
            holders="$holders $dev($(echo "$pids" | tr -s ' ' | sed 's/^ //'))"
        fi
    done
    shopt -u nullglob
    if [ -n "$holders" ]; then
        log "ERROR: devices still held after convergence:$holders"
        fuser -v /dev/dri/card* "/dev/$VT" 2>&1 | sed 's/^/seat-prep: /' || true
        log "ERROR: stop these processes (or reboot); Xorg cannot take DRM master or the VT while they live"
        exit 1
    fi
else
    log "fuser not available (install psmisc); skipping DRM/VT holder verification"
fi

if [ "$changed" = 1 ]; then
    log "seat converged"
fi
exit 0
