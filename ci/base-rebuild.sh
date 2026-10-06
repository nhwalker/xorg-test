#!/bin/bash
# The weekly from-scratch rebuild of the base images (base-rebuild.yml), with
# the evidence S1.1.2 asks for: each build's log, rpm -qa of the desktop base
# GHCR held before this rebuild and of the fresh one, and their diff - the
# week's package drift, there to read even when nothing broke.
#
# Run from the repository root, with podman reachable through sudo:
#   REGISTRY=ghcr.io/<owner> EV_ROOT=artifacts ci/base-rebuild.sh
# Pushing the result is the workflow's next step, not this script's.
set -euo pipefail

# shellcheck source=ci/evidence.sh
. ci/evidence.sh
REGISTRY=${REGISTRY:?set REGISTRY to the GHCR namespace, e.g. ghcr.io/<owner>}
PREV="$REGISTRY/desktop-container-base:latest"
LOGS=$(mktemp -d)
# What fail() prints and keeps: the images in root's podman storage and the
# tail of each build's log so far.
rebuild_diagnostics() {
    echo "---- diagnostics: sudo podman images ----"
    sudo podman images 2>&1 || true
    local f
    for f in "$LOGS"/*; do
        [ -f "$f" ] || continue
        echo "---- diagnostics: ${f##*/} (tail) ----"
        tail -n 40 "$f" 2>&1 || true
    done
}
fail() {
    trap - ERR
    local msg="FAIL: $*" d
    echo "$msg" >&2
    d=$(rebuild_diagnostics 2>&1)
    printf '%s\n' "$d" >&2
    ev_text failure-diagnostics "what fail() printed when this story failed: the images in root's storage and each build log's tail" "$d"
    ev_abort "$*"
    echo "$msg" >&2
    exit 1
}
# A command that fails where nothing handles it (errexit would end the
# script with no word of why) reports through fail(): the command, its line,
# the diagnostics, and the message repeated last (Requirements.md S9.2.3).
# The main shell reports; a substitution's subshell leaves it to the
# assignment that then fails.
set -E
on_unhandled() {
    [ "$BASH_SUBSHELL" = 0 ] || return 0
    trap - ERR
    fail "unhandled failure (exit $1) at $3: $2"
}
trap 'on_unhandled $? "$BASH_COMMAND" "${BASH_SOURCE[0]}:$LINENO"' ERR
mkdir -p "$EV_ROOT"
ev_begin S1.1.2 "Bases rebuild from current upstream" T2

# The base as last week's run (or the last push) left it, before anything
# here can replace it. Its absence is recorded, not fatal: the first run on
# a fresh registry has nothing to compare against.
before="" prevfile=""
if sudo podman pull -q "$PREV" >/dev/null 2>&1; then
    ev_note "the previous base: $PREV, image $(sudo podman image inspect --format '{{.Id}} created {{.Created}}' "$PREV")"
    before=$(sudo podman run --rm --network=none "$PREV" sh -c 'rpm -qa | sort') \
        || fail "could not list the previous base's packages"
    ev_text rpm-previous "EV-STATE: rpm -qa of the base GHCR held before this rebuild ($PREV), sorted" "$before"
    prevfile=$EV_LAST
else
    ev_note "no previous base to compare against: $PREV could not be pulled"
fi

build() { # <moment> <what> <podman build arguments...>
    local moment=$1 what=$2 rc=0
    shift 2
    # The log is this script's, written as its own user: sudo is for podman.
    # shellcheck disable=SC2024
    sudo podman build "$@" > "$LOGS/$moment.log" 2>&1 || rc=$?
    ev_copy "$LOGS/$moment.log" "$moment" "EV-LOG: $what: podman build $* (exit $rc)"
    [ "$rc" = 0 ] || fail "$what: podman build exited $rc: $(tail -n 3 "$LOGS/$moment.log" | tr '\n' ' ')"
    ev_pass "$what"
}

# --pull re-resolves the upstream FROM image even when a local copy exists,
# and --no-cache discards every layer cache entry. Together they are what
# makes this rebuild mean anything: its whole job is to prove the bases
# still build from current upstream and to pick up security updates.
# Without them it could "succeed" against a stale cache and report a green
# that tested nothing.
build base-desktop "the desktop base builds from current upstream (--pull --no-cache)" \
    --pull --no-cache -t localhost/desktop-container-base:latest -f Containerfile.base .
build base-plugin "the device plugin's base builds from current upstream (--pull --no-cache)" \
    --pull --no-cache -t localhost/cdi-device-plugin-base:latest -f Containerfile.plugin.base .
build base-screenshot "the screenshot tool's base builds from current upstream (--pull --no-cache)" \
    --pull --no-cache -t localhost/screenshot-base:latest -f Containerfile.screenshot.base .

# --network=none is the offline gate, not a speed-up: these layers must
# build with no network at all, so a dependency can never be added without
# also changing a Containerfile.*.base and forcing a base rebuild. A build
# that needs the network fails here loudly instead of drifting. The
# screenshot image first: the desktop image stages its tools out of it.
build app-screenshot "the screenshot image builds offline on the fresh base" \
    --network=none -t localhost/screenshot:latest -f Containerfile.screenshot .
build app-desktop "the desktop image builds offline on the fresh base" \
    --network=none -t localhost/desktop-container:latest -f Containerfile .
build app-plugin "the device plugin's image builds offline on the fresh base" \
    --network=none -t localhost/cdi-device-plugin:latest -f Containerfile.plugin .

after=$(sudo podman run --rm --network=none localhost/desktop-container-base:latest sh -c 'rpm -qa | sort') \
    || fail "could not list the fresh base's packages"
ev_text rpm-fresh "EV-STATE: rpm -qa of the freshly built desktop base, sorted" "$after"
fresh=$EV_LAST
[ -n "$after" ] || fail "the fresh base lists no packages"
ev_pass "the fresh base lists $(grep -c . <<<"$after") packages"
if [ -n "$before" ]; then
    ev_diff rpm-drift "EV-DIFF: the week's package drift: rpm -qa of the previous base (-) against the fresh one (+)" \
        "$prevfile" "$fresh" "the lines of the packages the week's updates changed, whichever they are: this diff is the drift"
    gone=$(comm -23 <(printf '%s\n' "$before") <(printf '%s\n' "$after") | grep -c . || true)
    new=$(comm -13 <(printf '%s\n' "$before") <(printf '%s\n' "$after") | grep -c . || true)
    ev_note "the week's drift in the desktop base: $new package versions new, $gone gone"
fi
ev_end
