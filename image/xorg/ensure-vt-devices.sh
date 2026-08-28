#!/bin/bash
# Container runtimes disagree about whether VT device nodes appear inside a
# container: docker exposes the host's /dev/tty0..N, rootful podman does
# NOT (verified on real hosts - the session then fails at step STDIN and
# the desktop black-screens). The container's /dev is a tmpfs, so create the
# nodes ourselves when the runtime didn't.
#
# The quadlet grants exactly what that needs and nothing more: CAP_MKNOD, and
# device-cgroup-rule "c 4:* rwm" for the VT major. Creating them here on the
# container's OWN /dev is deliberate rather than a workaround - systemd chowns
# TTYPath= to the session user, and doing that to an AddDevice-d host node
# would change the HOST's /dev/tty1. See the MKNOD entry in
# deploy/host/etc/containers/systemd/desktop.container.
#
# Runs first from desktop-init.
set -u

log() { echo "ensure-vt-devices: $*"; }

for spec in "tty0 4 0" "tty1 4 1"; do
    # shellcheck disable=SC2086
    set -- $spec
    node="/dev/$1" major="$2" minor="$3"
    [ -e "$node" ] && continue
    if mknod -m 620 "$node" c "$major" "$minor" 2>/dev/null; then
        chown root:tty "$node" 2>/dev/null || true
        log "created $node (c $major:$minor) - runtime did not expose it"
    else
        log "warning: cannot create $node (kernel without VT support?)"
    fi
done
exit 0
