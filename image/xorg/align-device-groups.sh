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
# Runs as root from desktop-init, before the session starts (supplementary groups are picked up at session start).
# Never chmod/chown the nodes themselves: /dev is the host's.
#
# Usage: align-device-groups.sh [group...]
#   no arguments   all four groups (video render input audio) - the boot path
#   group names    just those, e.g. `align-device-groups.sh audio`
#
# The narrow form exists for desktop-init's audio supervisor, which
# re-aligns before every audio start: /dev/snd is a live bind mount, so a
# sound card can appear long after boot, and on a host that booted without
# one the boot-time pass had no node to measure and left the container's
# audio gid at its image value. Re-running the WHOLE alignment there would
# renumber video/input/render groups the running X session is already
# using, to no purpose - hence the argument.
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

# The node globs for each group, in one place so align and summary cannot
# drift apart.
nodes_for() { # $1: group
    case "$1" in
        video)  echo "/dev/dri/card*" ;;
        render) echo "/dev/dri/renderD*" ;;
        input)  echo "/dev/input/event*" ;;
        audio)  echo "/dev/snd/controlC*" ;;
        *)      echo "" ;;
    esac
}

groups=("$@")
[ ${#groups[@]} -gt 0 ] || groups=(video render input audio)

for g in "${groups[@]}"; do
    n=$(nodes_for "$g")
    if [ -z "$n" ]; then
        log "unknown group '$g'; known: video render input audio"
        continue
    fi
    # Unquoted on purpose: these are globs, and align() takes the expansion
    # as its candidate node list.
    # shellcheck disable=SC2086
    align "$g" $n
done

# Always log the final state, changes or not: "alignment ran but access
# still fails" should be debuggable from this table alone.
summary() {
    local group="$1"; shift
    local n node="" ggid
    for n in "$@"; do
        if [ -e "$n" ]; then node="$n"; break; fi
    done
    ggid=$(getent group "$group" | cut -d: -f3)
    if [ -n "$node" ]; then
        log "  $group: container gid ${ggid:-<absent>}, device $node has gid $(stat -c %g "$node") mode $(stat -c %a "$node")"
    else
        log "  $group: container gid ${ggid:-<absent>}, no device nodes"
    fi
}
log "final state:"
for g in "${groups[@]}"; do
    n=$(nodes_for "$g")
    [ -n "$n" ] || continue
    # shellcheck disable=SC2086
    summary "$g" $n
done
log "desktop user: $(id desktop)"

exit 0
