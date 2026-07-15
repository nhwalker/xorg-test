#!/bin/bash
# Runs INSIDE the Rocky 9 e2e VM (as root via sudo from the rocky user).
# phase1: podman/quadlet flow with the real install.sh - real Xorg on the
#         virtio display, audio, host-terminal ssh, all under SELinux
#         enforcing.
# phase2: k3s + both charts - device plugin health gating and a client pod
#         opening xterm on the same display.
set -euo pipefail

REPO="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$REPO"

# EL sudo's secure_path omits /usr/local/bin, where the k3s installer and
# our helm download land. Without this the k3s readiness loop silently
# spins on "command not found".
export PATH="/usr/local/bin:$PATH"

log()  { echo "== vm-guest($1): $2"; }
fail() {
    echo "FAIL: vm-guest: $*" >&2
    echo "---- diagnostics: podman logs desktop (tail) ----" >&2
    podman logs desktop 2>&1 | tail -80 >&2 || true
    echo "---- diagnostics: Xorg log (tail) ----" >&2
    podman exec desktop sh -c 'tail -40 /home/desktop/.local/share/xorg/Xorg.0.log' >&2 2>/dev/null || true
    echo "---- diagnostics: postmortem ----" >&2
    podman exec desktop journalctl -t session-postmortem -o cat --no-pager 2>/dev/null | tail -30 >&2 || true
    echo "---- diagnostics: preflight ----" >&2
    podman logs desktop 2>&1 | grep 'preflight:' >&2 || true
    if command -v k3s >/dev/null; then
        echo "---- diagnostics: k3s state ----" >&2
        k3s kubectl get nodes,pods -A -o wide >&2 2>/dev/null || true
        echo "---- diagnostics: node allocatable ----" >&2
        k3s kubectl get node -o jsonpath='{.items[0].status.allocatable}' >&2 2>/dev/null || true
        echo "" >&2
        echo "---- diagnostics: pod images actually running ----" >&2
        k3s kubectl get pods -A -o custom-columns='NAME:.metadata.name,IMAGE:.spec.containers[0].image,IMAGEID:.status.containerStatuses[0].imageID' >&2 2>&1 || true
        echo "---- diagnostics: device-plugin logs ----" >&2
        k3s kubectl logs ds/plugin-desktop-device-plugin --tail=30 >&2 2>&1 || true
        echo "---- diagnostics: kubelet plugin dir ----" >&2
        ls -la /var/lib/kubelet/device-plugins/ >&2 2>/dev/null || true
        k3s kubectl describe pod x11-client-demo x11-client-gated >&2 2>/dev/null || true
        journalctl -u k3s --no-pager -o cat 2>/dev/null | tail -20 >&2 || true
    fi
    exit 1
}

wait_for() { # tries interval description command...
    local tries="$1" interval="$2" desc="$3"
    shift 3
    for _ in $(seq "$tries"); do
        "$@" >/dev/null 2>&1 && return 0
        sleep "$interval"
    done
    fail "timeout waiting for: $desc"
}

container_running() {
    [ "$(podman exec desktop systemctl is-system-running 2>/dev/null || true)" = running ]
}

phase1() {
    log p1 "SELinux must be enforcing for this test to mean anything"
    [ "$(getenforce)" = Enforcing ] || fail "SELinux is not enforcing"

    log p1 "install podman + tools"
    dnf -y -q install podman pulseaudio-utils >/dev/null

    log p1 "load prebuilt images"
    podman load -q -i /tmp/images-desktop.tar >/dev/null
    podman load -q -i /tmp/images-plugin.tar >/dev/null
    # Guard against tag/content mix-ups in the archive plumbing (a combined
    # podman-save archive once shipped the desktop image under BOTH tags).
    ep=$(podman image inspect localhost/desktop-device-plugin:latest \
        --format '{{index .Config.Entrypoint 0}}' || true)
    [ "$ep" = /desktop-device-plugin ] \
        || fail "plugin image has wrong entrypoint '$ep' - archive tag mix-up?"

    log p1 "real install.sh (quadlet, shell user ${SUDO_USER:-rocky})"
    ./install.sh --no-build --no-gpu

    log p1 "container reaches running"
    wait_for 40 3 "systemd running in container" container_running

    log p1 "Xorg actually serves the virtio display, rootless"
    # Generous first-boot window: cold caches, first session start.
    wait_for 60 4 "X socket" podman exec desktop test -S /tmp/.X11-unix/X0
    # NOTE: no `| head` / `| grep -q` on pipelines out of podman exec -
    # under pipefail an early-exiting consumer SIGPIPEs the producer and
    # set -e kills the script with no message.
    podman exec -u desktop -e DISPLAY=:0 desktop xdpyinfo >/dev/null \
        || fail "xdpyinfo could not talk to :0"
    podman exec -u desktop -e DISPLAY=:0 desktop sh -c 'xdpyinfo | sed -n 1,3p' || true
    owner=$(podman exec desktop sh -c 'ps -o user= -C Xorg | head -1' || true)
    [ "$owner" = desktop ] || fail "Xorg runs as '${owner:-nobody}', want desktop"
    podman exec desktop sh -c 'loginctl list-sessions --no-pager | grep -q seat0' \
        || fail "no seat0 session"

    log p1 "mwm session is up"
    podman exec desktop ps -C mwm >/dev/null || fail "mwm not running"

    log p1 "audio: HDA device visible, pulse socket reachable from VM host"
    podman exec -u desktop -e XDG_RUNTIME_DIR=/run/user/1000 desktop \
        sh -c 'wpctl status | grep -qi alsa' || fail "no ALSA device in wireplumber"
    PULSE_SERVER=unix:/run/desktop-audio/pulse pactl info >/dev/null \
        || fail "pulse socket unreachable from VM host"

    log p1 "host terminal: container -> host ssh as ${SUDO_USER:-rocky} (restorecon path)"
    who=$(podman exec -u desktop -e HOME=/home/desktop desktop \
        ssh -o ConnectTimeout=5 -o BatchMode=yes host whoami)
    [ "$who" = "${SUDO_USER:-rocky}" ] || fail "ssh host whoami='$who'"

    log p1 "spawn an xterm so the screendump shows a window"
    podman exec -d -u desktop -e DISPLAY=:0 -e HOME=/home/desktop desktop \
        xterm -T e2e-proof -geometry 80x24+80+80
    sleep 3
    log p1 "phase1 passed"
}

phase2() {
    log p2 "hand the display over: stop quadlet desktop"
    systemctl stop desktop.service
    rm -f /etc/containers/systemd/desktop.container
    systemctl daemon-reload

    log p2 "install k3s (SELinux policy interplay is out of scope: permissive for this phase)"
    setenforce 0
    # traefik/metrics-server: not needed, and their image pulls over the
    # VM's user-mode NAT slow down node readiness considerably.
    curl -sfL https://get.k3s.io \
        | INSTALL_K3S_EXEC="--disable traefik --disable metrics-server" sh - >/dev/null
    wait_for 60 5 "k3s node ready" \
        sh -c "k3s kubectl get nodes | grep -q ' Ready'"

    log p2 "import images + helm"
    k3s ctr images import /tmp/images-desktop.tar >/dev/null
    k3s ctr images import /tmp/images-plugin.tar >/dev/null
    # Same guard as phase1, containerd side: both refs must exist and be
    # DIFFERENT images, or the plugin daemonset silently runs systemd.
    ddig=$(k3s ctr images ls | awk '$1 == "localhost/desktop-container:latest" {print $3}')
    pdig=$(k3s ctr images ls | awk '$1 == "localhost/desktop-device-plugin:latest" {print $3}')
    if [ -z "$ddig" ] || [ -z "$pdig" ] || [ "$ddig" = "$pdig" ]; then
        fail "containerd image import broken: desktop='$ddig' plugin='$pdig' (must both exist and differ)"
    fi
    curl -fsSL https://get.helm.sh/helm-v3.16.4-linux-amd64.tar.gz \
        | tar -xz -C /usr/local/bin --strip-components=1 linux-amd64/helm

    log p2 "deploy desktop chart and wait for real readiness (xdpyinfo probe)"
    export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
    helm install desktop charts/desktop-container --set fullnameOverride=desktop \
        --set image.repository=localhost/desktop-container --set image.pullPolicy=Never
    wait_for 40 5 "desktop deployment ready" \
        sh -c "k3s kubectl get deploy desktop -o jsonpath='{.status.readyReplicas}' | grep -q 1"

    log p2 "deploy device plugin; resource becomes allocatable"
    helm install plugin charts/desktop-device-plugin \
        --set image.repository=localhost/desktop-device-plugin --set image.pullPolicy=Never
    wait_for 30 4 "desktop.local/display allocatable" \
        sh -c "k3s kubectl get node -o jsonpath='{.items[0].status.allocatable.desktop\.local/display}' | grep -q 10"

    log p2 "client pod schedules and opens xterm on the desktop"
    sed 's|image: desktop-container:latest|image: localhost/desktop-container:latest|' \
        examples/x11-client-pod.yaml | k3s kubectl apply -f -
    wait_for 30 4 "client pod running" \
        sh -c "k3s kubectl get pod x11-client-demo -o jsonpath='{.status.phase}' | grep -q Running"

    log p2 "health gating: no desktop -> slots unhealthy -> new clients Pending"
    k3s kubectl scale deploy desktop --replicas=0
    k3s kubectl delete pod x11-client-demo --wait=true
    sleep 20
    sed -e 's|image: desktop-container:latest|image: localhost/desktop-container:latest|' \
        -e 's|name: x11-client-demo|name: x11-client-gated|' \
        examples/x11-client-pod.yaml | k3s kubectl apply -f -
    sleep 15
    phase=$(k3s kubectl get pod x11-client-gated -o jsonpath='{.status.phase}')
    [ "$phase" = Pending ] || fail "gated client is '$phase', want Pending with desktop down"

    log p2 "desktop returns -> gated client runs"
    k3s kubectl scale deploy desktop --replicas=1
    wait_for 40 5 "gated client running" \
        sh -c "k3s kubectl get pod x11-client-gated -o jsonpath='{.status.phase}' | grep -q Running"
    sleep 5
    log p2 "phase2 passed"
}

case "${1:?phase1|phase2}" in
    phase1) phase1 ;;
    phase2) phase2 ;;
    *) fail "unknown phase $1" ;;
esac
