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

log "wait for the container to answer"
for _ in $(seq 20); do
    podman exec desktop true 2>/dev/null && break
    sleep 2
done

log "VT devices present (ensure-vt-devices mknod fallback covers podman)"
podman exec desktop test -e /dev/tty1 \
    || fail "/dev/tty1 missing in container despite ensure-vt-devices"

log "wait for the container to settle (X may or may not drive this runner's virtual GPU)"
st=""
for _ in $(seq 40); do
    st=$(podman exec desktop systemctl is-system-running 2>/dev/null || true)
    case "$st" in running|degraded) break ;; esac
    sleep 3
done
case "$st" in running|degraded) ;; *) fail "container state: ${st:-unreachable}" ;; esac
failed=$(podman exec desktop systemctl --failed --no-legend --plain 2>/dev/null \
    | awk '{print $1}' | sort | tr '\n' ' ')
case "$failed" in
    ""|"desktop-session.service ") ;;
    *) fail "unexpected failed units: $failed" ;;
esac

log "session plumbing: X serves, or the postmortem explains why not"
plumbing=""
for _ in $(seq 30); do
    if podman exec desktop test -S /tmp/.X11-unix/X0 2>/dev/null; then
        plumbing=x; break
    fi
    if podman exec desktop journalctl -t session-postmortem -o cat --no-pager 2>/dev/null \
        | grep -q 'postmortem:'; then
        plumbing=postmortem; break
    fi
    sleep 3
done
[ -n "$plumbing" ] || fail "neither X socket nor postmortem appeared: session plumbing is broken"
log "session outcome on this runner: $plumbing"
if [ "$plumbing" = x ]; then
    ok=0
    for _ in $(seq 10); do
        podman exec desktop loginctl list-sessions --no-pager 2>/dev/null \
            | grep -q seat0 && { ok=1; break; }
        sleep 3
    done
    [ "$ok" = 1 ] || fail "X is serving but no seat0 session exists"
fi

log "pin the user manager (linger): audio asserts must not depend on session state"
AUDIO_VIA_SYSTEMD=1
if ! podman exec desktop loginctl enable-linger desktop \
   || ! podman exec desktop systemctl start user@1000; then
    AUDIO_VIA_SYSTEMD=0
    log "user@1000 unavailable; its journal follows, then direct daemon start"
    podman exec desktop journalctl -u user@1000 -u user-runtime-dir@1000 --no-pager -o cat 2>/dev/null | tail -30 || true
    podman exec desktop mkdir -p /run/user/1000
    podman exec desktop chown desktop:desktop /run/user/1000
    # umask 000 stands in for the UMask= drop-in the user services carry.
    for d in pipewire wireplumber pipewire-pulse; do
        podman exec -d -u desktop -e XDG_RUNTIME_DIR=/run/user/1000 desktop \
            sh -c "umask 000; exec $d"
    done
fi

log "audio: services active, exported sockets world-connectable"
ok=0
if [ "${AUDIO_VIA_SYSTEMD:-1}" = 1 ]; then
    for _ in $(seq 15); do
        ok=$(podman exec -u desktop -e XDG_RUNTIME_DIR=/run/user/1000 desktop \
            systemctl --user is-active pipewire wireplumber pipewire-pulse 2>/dev/null \
            | grep -c '^active$' || true)
        [ "$ok" = 3 ] && break
        sleep 2
    done
    [ "$ok" = 3 ] || fail "audio services not all active"
else
    for _ in $(seq 15); do
        ok=$(podman exec desktop sh -c \
            'pgrep -x pipewire >/dev/null && pgrep -x wireplumber >/dev/null && pgrep -f pipewire-pulse >/dev/null' \
            && echo 3 || echo 0)
        [ "$ok" = 3 ] && break
        sleep 2
    done
    [ "$ok" = 3 ] || fail "audio daemons not all running (direct-start fallback)"
fi
# Retry loop: sockets appear moments after the daemons start.
okc=0
for _ in $(seq 15); do
    if podman exec desktop sh -c 'test -S /run/desktop-audio/pulse && test -S /run/desktop-audio/pipewire-0' 2>/dev/null \
       && podman exec -e PULSE_SERVER=unix:/run/desktop-audio/pulse desktop pactl info >/dev/null 2>&1 \
       && podman exec -e PIPEWIRE_REMOTE=/run/desktop-audio/pipewire-0 -e XDG_RUNTIME_DIR=/tmp \
            desktop pw-cli info 0 >/dev/null 2>&1; then
        okc=1
        break
    fi
    sleep 2
done
[ "$okc" = 1 ] || fail "exported audio sockets not connectable cross-uid"

log "diagnostics: preflight mirrored to podman logs"
pf=0
for _ in $(seq 10); do
    podman logs desktop 2>&1 | grep -q 'preflight:' && { pf=1; break; }
    sleep 3
done
[ "$pf" = 1 ] || fail "preflight not in podman logs (journal mirror not flushing?)"
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
