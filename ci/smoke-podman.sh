#!/bin/bash
# Podman boot-smoke suite for CI (run as root on an EPHEMERAL runner: this
# runs the real install.sh, which reconfigures the host's seat/getty/audio).
# Assumes localhost/desktop-container:latest already built.
set -euo pipefail
cd "$(dirname "$0")/.."

IMG=localhost/desktop-container:latest
log()  { echo "== $*"; }
fail() { echo "FAIL: $*" >&2; exit 1; }

[ "$(id -u)" = 0 ] || fail "must run as root (sudo)"
SMOKE_USER="${SUDO_USER:-runner}"

# VT availability must be judged from INSIDE the container: podman's
# privileged /dev population does not necessarily expose the host's VT
# devices (observed on GitHub runners: host has /dev/tty1, container does
# not), and TTYPath=/dev/tty1 can only spawn against the container's /dev.
# Without a VT the session/X/postmortem path is covered by the VM e2e job;
# everything else is still verified here. Determined after the container
# starts (see below).
HAVE_VT=

log "tty-less guard: journal mirror must fail loudly, not leak"
podman rm -f nott >/dev/null 2>&1 || true
podman run -d --name nott --privileged --systemd=always --network=host "$IMG" >/dev/null
sleep 10
podman exec nott journalctl -u journal-console -o cat --no-pager \
    | grep -q 'not a character device' || fail "tty guard message missing"
if podman exec nott test -e /dev/console; then
    fail "/dev/console exists in tty-less container (regression: RAM-leak file)"
fi
podman rm -f nott >/dev/null

log "ensure sshd exists for the host-terminal path"
if ! systemctl is-active --quiet ssh && ! systemctl is-active --quiet sshd; then
    apt-get update -q && apt-get install -y -q openssh-server
    systemctl enable --now ssh
fi

log "run the real install.sh (quadlet flow, shell user $SMOKE_USER)"
SUDO_USER="$SMOKE_USER" ./install.sh --no-build --no-gpu

log "wait for the container to answer, then judge VT availability from inside"
for _ in $(seq 20); do
    podman exec desktop true 2>/dev/null && break
    sleep 2
done
if podman exec desktop test -e /dev/tty1 2>/dev/null; then
    HAVE_VT=1
else
    HAVE_VT=0
    log "container has no /dev/tty1: session asserts will be skipped (VM job covers them)"
fi

log "wait for the container to settle"
st=""
for _ in $(seq 40); do
    st=$(podman exec desktop systemctl is-system-running 2>/dev/null || true)
    if [ "$st" = running ]; then break; fi
    if [ "$HAVE_VT" = 0 ] && [ "$st" = degraded ]; then break; fi
    sleep 3
done
if [ "$HAVE_VT" = 1 ]; then
    [ "$st" = running ] || fail "container state: ${st:-unreachable}"
else
    case "$st" in running|degraded) ;; *) fail "container state: ${st:-unreachable}" ;; esac
    failed=$(podman exec desktop systemctl --failed --no-legend --plain 2>/dev/null \
        | awk '{print $1}' | sort | tr '\n' ' ')
    case "$failed" in
        ""|"desktop-session.service ") ;;
        *) fail "unexpected failed units: $failed" ;;
    esac
    log "starting user@1000 directly (no VT means no PAM session to do it)"
    podman exec desktop systemctl start user@1000
fi

if [ "$HAVE_VT" = 1 ]; then
    log "seat: logind session on seat0/tty1"
    podman exec desktop loginctl list-sessions --no-pager | grep -q 'seat0' \
        || fail "no seat0 session"
fi

log "audio: services active, exported sockets world-connectable"
for _ in $(seq 15); do
    ok=$(podman exec -u desktop -e XDG_RUNTIME_DIR=/run/user/1000 desktop \
        systemctl --user is-active pipewire wireplumber pipewire-pulse 2>/dev/null \
        | grep -c '^active$' || true)
    [ "$ok" = 3 ] && break
    sleep 2
done
[ "$ok" = 3 ] || fail "audio services not all active"
podman exec desktop sh -c 'test -S /run/desktop-audio/pulse && test -S /run/desktop-audio/pipewire-0' \
    || fail "exported audio sockets missing"
podman exec -e PULSE_SERVER=unix:/run/desktop-audio/pulse desktop pactl info >/dev/null \
    || fail "cross-uid pulse connect failed"
podman exec -e PIPEWIRE_REMOTE=/run/desktop-audio/pipewire-0 -e XDG_RUNTIME_DIR=/tmp \
    desktop pw-cli info 0 >/dev/null || fail "cross-uid pipewire connect failed"

log "diagnostics: preflight mirrored to podman logs"
podman logs desktop 2>&1 | grep -q 'preflight:' || fail "preflight not in podman logs"
if [ "$HAVE_VT" = 1 ]; then
    log "postmortem fires when the session dies"
    for _ in $(seq 20); do
        podman exec desktop journalctl -t session-postmortem -o cat --no-pager 2>/dev/null \
            | grep -q 'postmortem:' && break
        sleep 3
    done
    podman exec desktop journalctl -t session-postmortem -o cat --no-pager \
        | grep -q 'postmortem:' || fail "postmortem output missing"
fi

log "host terminal: ssh from container to host as $SMOKE_USER"
who=$(podman exec -u desktop -e HOME=/home/desktop desktop \
    ssh -o ConnectTimeout=5 -o BatchMode=yes host whoami)
[ "$who" = "$SMOKE_USER" ] || fail "ssh host whoami returned '$who', want '$SMOKE_USER'"

log "uninstall restores the host"
./install.sh --uninstall
systemctl is-active --quiet desktop.service && fail "desktop.service still active after uninstall"
[ -e /etc/containers/systemd/desktop.container ] && fail "quadlet not removed"
if grep -q desktop-container-host-shell "/home/$SMOKE_USER/.ssh/authorized_keys" 2>/dev/null; then
    fail "authorized_keys entry not removed"
fi

log "smoke suite passed"
