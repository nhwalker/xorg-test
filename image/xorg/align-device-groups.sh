#!/bin/bash
# Align container group gids with the host's device nodes at boot.
#
# Kernel permission checks compare NUMERIC gids. The device nodes in /dev
# were created by the HOST's udev with the host's video/render/input/audio
# gids; this image allocated its own gids for the same-named groups, and
# for dynamically-allocated system groups (input, render) the numbers need
# not match. Renumber the container's groups to the gids actually on the
# nodes, so the rootless session user's memberships grant device access.
#
# Runs as root from xorg-conf.service, before desktop-session.service
# starts (supplementary groups are picked up at session start).
# Never chmod/chown the nodes themselves: /dev is the host's.
set -u

log() { echo "align-device-groups: $*"; }

free_gid() {
    local g=60000
    while getent group "$g" >/dev/null; do g=$((g + 1)); done
    echo "$g"
}

align() {
    local group="$1"; shift
    local node="" n gid cur other tmp
    for n in "$@"; do
        if [ -e "$n" ]; then node="$n"; break; fi
    done
    if [ -z "$node" ]; then
        log "$group: no device nodes present, skipping"
        return 0
    fi
    gid=$(stat -c %g "$node")
    # A root-group node (e.g. /dev/nvidia* are 0666 root:root) needs no
    # group alignment.
    if [ "$gid" = 0 ]; then
        log "$group: $node has group root, skipping"
        return 0
    fi
    cur=$(getent group "$group" | cut -d: -f3)
    if [ -z "$cur" ]; then
        log "$group: creating with gid $gid (from $node)"
        groupadd -g "$gid" "$group" && usermod -aG "$group" desktop
        return 0
    fi
    [ "$cur" = "$gid" ] && return 0
    other=$(getent group "$gid" | cut -d: -f1)
    if [ -n "$other" ] && [ "$other" != "$group" ]; then
        tmp=$(free_gid)
        log "gid $gid is taken by group '$other'; moving '$other' to $tmp"
        groupmod -g "$tmp" "$other"
    fi
    log "$group: gid $cur -> $gid (from $node)"
    groupmod -g "$gid" "$group"
}

align video  /dev/dri/card*
align render /dev/dri/renderD*
align input  /dev/input/event*
align audio  /dev/snd/controlC*

exit 0
