#!/bin/bash
# Publish the desktop's client tools onto the host, where the
# desktop.local/tools CDI device mounts them into client containers.
#
# The binaries ship INSIDE this image (staged in $SRC by the Containerfile) so
# their version is an attribute of the desktop: one image update ships both the
# display server and the tools that talk to it, and they cannot disagree about
# what protocol they speak. That coupling is the whole reason the desktop
# publishes them rather than the host installing them independently - it is
# what makes the Wayland transition a single-artifact change.
#
# $DEST is a host directory bind-mounted in (see the quadlet's Volume= and the
# chart's toolsBin hostPath). It is DISK-backed, not /run: the toolkit is
# expected to grow, and every Go binary carries its own ~1.4MB runtime, so on
# tmpfs each new tool would cost that much RAM again.
#
# Writing anything here makes the host advertise desktop.local/tools:
# desktop-tools-cdi.path watches this directory and writes the CDI spec the
# moment it becomes non-empty. Until then the resource does not exist and a
# client requesting it fails to schedule - which is the point, and much easier
# to diagnose than a container that starts with an empty bin dir.
set -euo pipefail

SRC=/usr/libexec/desktop-tools
DEST=/var/lib/desktop-container/bin

[ -d "$SRC" ] || { echo "no tools staged at $SRC" >&2; exit 1; }
mkdir -p "$DEST"
# 0755, deliberately NOT the 1777 the exported socket dirs use: this directory
# holds executables that get mounted into every client, so anything able to
# write here would control code running in all of them. Nothing unprivileged
# needs to write here - only this unit, as root.
chmod 0755 "$DEST"

published=()
for src in "$SRC"/*; do
    [ -f "$src" ] || continue
    name=$(basename "$src")
    published+=("$name")

    # Copy to a temp file in the DESTINATION dir, then rename into place.
    #
    # Not `cp` over the existing file: a client may be executing it right now,
    # and writing to a running executable fails with ETXTBSY. Rename swaps in a
    # new inode and leaves the old one alive for as long as anything is still
    # running it, so a desktop restart cannot break a client mid-command. Same
    # reasoning as write_spec in desktop-client-cdi.
    tmp=$(mktemp "$DEST/.$name.XXXXXX")
    trap 'rm -f "$tmp"' EXIT
    cat "$src" > "$tmp"
    chmod 0755 "$tmp"
    mv "$tmp" "$DEST/$name"
    trap - EXIT
    echo "published $name"
done

[ "${#published[@]}" -gt 0 ] || { echo "no tools found in $SRC" >&2; exit 1; }

# Prune tools this image no longer ships. Removing stale entries one by one
# rather than wiping the directory first: a wipe would leave a window in which
# a starting client mounts an empty toolkit, and (worse) could momentarily
# empty the directory the CDI spec's existence is keyed on.
shopt -s nullglob dotglob
for existing in "$DEST"/*; do
    name=$(basename "$existing")
    case "$name" in .*) continue ;; esac   # leave stray temp files to mktemp
    for keep in "${published[@]}"; do
        [ "$name" = "$keep" ] && continue 2
    done
    rm -f "$existing"
    echo "pruned $name (no longer shipped by this image)"
done

echo "tools published to $DEST: ${published[*]}"
