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

log "wait for the container to reach running"
st=""
for _ in $(seq 40); do
    st=$(podman exec desktop systemctl is-system-running 2>/dev/null || true)
    [ "$st" = running ] && break
    sleep 3
done
[ "$st" = running ] || fail "container state: ${st:-unreachable}"

log "seat: logind session on seat0/tty1"
podman exec desktop loginctl list-sessions --no-pager | grep -q 'seat0' \
    || fail "no seat0 session"

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

log "diagnostics: preflight mirrored to podman logs, postmortem fires"
podman logs desktop 2>&1 | grep -q 'preflight:' || fail "preflight not in podman logs"
# The runner has no display hardware, so the session fails and the
# postmortem must have fired with a verdict.
for _ in $(seq 20); do
    podman exec desktop journalctl -t session-postmortem -o cat --no-pager 2>/dev/null \
        | grep -q 'LIKELY CAUSE' && break
    sleep 3
done
podman exec desktop journalctl -t session-postmortem -o cat --no-pager \
    | grep -q 'LIKELY CAUSE' || fail "postmortem verdict missing"

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
