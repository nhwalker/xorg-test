#!/bin/bash
# Container runtimes disagree about VT device nodes in privileged
# containers: docker exposes the host's /dev/tty0..N, rootful podman does
# NOT (verified on real hosts - the session then fails at step STDIN and
# the desktop black-screens). The container's /dev is a tmpfs and the
# container has CAP_MKNOD with an open device cgroup, so create the nodes
# ourselves when the runtime didn't. Runs first from xorg-conf.service.
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
