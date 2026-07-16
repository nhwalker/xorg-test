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
        echo "---- diagnostics: desktop pod audio (export sockets + pipewire procs) ----" >&2
        k3s kubectl exec deploy/desktop -- sh -c \
            'ls -la /run/desktop-audio 2>&1; echo "-- pipewire procs:"; ps -o pid,comm -C pipewire -C pipewire-pulse -C wireplumber 2>&1; echo "-- listening unix sockets:"; ss -lxn 2>&1 | grep desktop-audio' \
            >&2 2>&1 || true
        k3s kubectl describe pod x11-client-demo x11-client-gated plugin-verify >&2 2>/dev/null || true
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
    k3s ctr images import /tmp/images-testclient.tar >/dev/null
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

gen_tone() { # $1: frequency Hz, $2: outfile (.wav -> WAV, else raw s16le)
    # 1.5s stereo sine at 60% full scale: audibly a beep in the artifact,
    # and unmistakably non-silent for the host-side amplitude check.
    python3 - "$1" "$2" <<'EOF'
import math, sys, wave
freq, out = float(sys.argv[1]), sys.argv[2]
rate, dur, amp = 44100, 1.5, 0.6
pcm = bytearray()
for i in range(int(rate * dur)):
    s = int(amp * 32767 * math.sin(2 * math.pi * freq * i / rate))
    b = s.to_bytes(2, "little", signed=True)
    pcm += b + b
if out.endswith(".wav"):
    w = wave.open(out, "wb")
    w.setnchannels(2)
    w.setsampwidth(2)
    w.setframerate(rate)
    w.writeframes(bytes(pcm))
    w.close()
else:
    with open(out, "wb") as f:
        f.write(bytes(pcm))
EOF
}

play_audio() { # $1: pulse | pipewire | alsa (inside the desktop container)
    # A distinct pitch per path, so a human listening to the artifacts can
    # tell which route produced which beep.
    local path="${1:?pulse|pipewire|alsa}" player freq
    case "$path" in
        pulse)    freq=440;  player='paplay /tmp/tone.wav' ;;
        pipewire) freq=880;  player='pw-play /tmp/tone.wav' ;;
        alsa)     freq=1320; player='aplay -q /tmp/tone.wav' ;;
        *) fail "unknown audio path '$path'" ;;
    esac
    gen_tone "$freq" /tmp/tone.wav
    podman cp /tmp/tone.wav desktop:/tmp/tone.wav
    log pa "play ${freq}Hz tone via $path from an xterm on :0"
    podman exec desktop rm -f /tmp/audio-ok
    # The xterm is the X11 app doing the playing. Its exit status does not
    # reliably reflect the -e command, so the inner script leaves a marker
    # only when the player succeeded.
    podman exec -u desktop -e DISPLAY=:0 -e HOME=/home/desktop \
        -e XDG_RUNTIME_DIR=/run/user/1000 desktop \
        timeout 60 xterm -T "audio-$path" -geometry 80x12+120+320 -e \
        sh -c "$player && touch /tmp/audio-ok" \
        || true
    podman exec desktop test -f /tmp/audio-ok \
        || fail "$path player failed inside the xterm"
    log pa "$path played"
}

# --- device-plugin injection verification (phase 2) -------------------------

VPOD=plugin-verify

assert_pod_env() { # $1: var, $2: expected value
    local got
    got=$(k3s kubectl exec "$VPOD" -- printenv "$1" 2>/dev/null || true)
    [ "$got" = "$2" ] || fail "injected env $1='$got', want '$2'"
    log vp "env $1=$got"
}

assert_pod_socket() { # $1: path
    # Present, a socket, and writable: the plugin mounts rw because unix
    # connect(2) needs write access; a ro mount would pass -S but break use.
    k3s kubectl exec "$VPOD" -- sh -c "test -S '$1' && test -w '$1'" \
        || fail "socket $1 missing or not writable in the requesting pod"
    log vp "socket $1 present + writable"
}

verify_plugin() {
    log vp "apply verifier pod: requests desktop.local/display, declares nothing else"
    k3s kubectl apply -f ci/vm/plugin-verify-pod.yaml
    wait_for 30 4 "verifier pod running" \
        sh -c "k3s kubectl get pod $VPOD -o jsonpath='{.status.phase}' | grep -q Running"

    log vp "device plugin injected the DISPLAY + audio env vars"
    assert_pod_env DISPLAY :0
    assert_pod_env PULSE_SERVER unix:/run/desktop-audio/pulse
    assert_pod_env PIPEWIRE_REMOTE /run/desktop-audio/pipewire-0

    log vp "the injected X socket is mounted and the display works"
    assert_pod_socket /tmp/.X11-unix/X0
    # sh -c so it uses the injected DISPLAY, not a hardcoded one; bounded so
    # a broken connection fails instead of hanging.
    timeout 20 k3s kubectl exec "$VPOD" -- sh -c 'xdpyinfo >/dev/null' \
        || fail "xdpyinfo could not open the display from the requesting pod"
    log vp "xdpyinfo opened :0 from the pod"

    # The pod readiness probe only gates on Xorg, so the desktop's user
    # pipewire session (which exports BOTH the pulse and the native pipewire
    # sockets) can lag X by several seconds - especially on the freshly
    # restarted pod from the health-gating step. Wait for both sockets to
    # exist AND pulse to actually accept BEFORE asserting them; otherwise the
    # socket assertions race the export and flake.
    log vp "wait for the injected audio export (pulse + pipewire native) to come up"
    timeout 120 k3s kubectl exec "$VPOD" -- sh -c '
        until [ -S /run/desktop-audio/pulse ] && [ -S /run/desktop-audio/pipewire-0 ] \
              && pactl info >/dev/null 2>&1; do sleep 2; done' \
        || fail "injected audio export never came up in the requesting pod (pulse + pipewire sockets)"
    log vp "device plugin mounted the audio sockets; export is live"
    assert_pod_socket /run/desktop-audio/pulse
    assert_pod_socket /run/desktop-audio/pipewire-0

    log vp "spawn an xterm from the pod so the screendump shows a client window"
    timeout 15 k3s kubectl exec "$VPOD" -- \
        sh -c 'setsid xterm -T plugin-verify -geometry 80x24+150+150 </dev/null >/dev/null 2>&1 &' \
        || true
    sleep 3
    log vp "verify-plugin passed"
}

play_audio_pod() { # $1: pulse|pipewire|alsa   $2: pod (default plugin-verify)
    # Same beep-per-path convention as the in-container test, but played from a
    # requesting pod using ONLY the injected env - so success proves the plugin
    # wired that client path, not the desktop image's own local session.
    local path="${1:?pulse|pipewire|alsa}" pod="${2:-$VPOD}" player freq
    case "$path" in
        pulse)    freq=440;  player='paplay /tmp/t.wav' ;;
        pipewire) freq=880;  player='pw-play /tmp/t.wav' ;;
        alsa)     freq=1320; player='aplay -q /tmp/t.wav' ;;
        *) fail "unknown audio path '$path'" ;;
    esac
    gen_tone "$freq" /tmp/tone-pod.wav
    # Stream the WAV in over exec stdin (no kubectl cp -> no tar dependency).
    timeout 20 k3s kubectl exec -i "$pod" -- sh -c 'cat > /tmp/t.wav' \
        < /tmp/tone-pod.wav || fail "could not copy tone into $pod"
    # Retry + hard timeout: the audio client can lag briefly, and a stuck
    # connect must fail rather than hang (see the earlier pacat hang).
    for _ in 1 2 3 4 5; do
        if timeout 20 k3s kubectl exec "$pod" -- sh -c "$player"; then
            log pa "$pod played ${freq}Hz via $path"
            return 0
        fi
        sleep 3
    done
    fail "$pod $path playback failed after 5 tries"
}

verify_testclient() {
    log tc "apply a LEAN non-desktop client (no server stack) that requests the resource"
    k3s kubectl apply -f ci/vm/testclient-pod.yaml
    wait_for 30 4 "testclient running" \
        sh -c "k3s kubectl get pod x11-testclient -o jsonpath='{.status.phase}' | grep -q Running"
    # The image ships no Xorg server or session, so a working display here can
    # only come from the plugin's injected DISPLAY + X-socket mount.
    got=$(k3s kubectl exec x11-testclient -- printenv DISPLAY 2>/dev/null || true)
    [ "$got" = ":0" ] || fail "testclient DISPLAY='$got', want :0 (plugin injection)"
    timeout 20 k3s kubectl exec x11-testclient -- sh -c 'xdpyinfo >/dev/null' \
        || fail "lean client could not open the display via injected env"
    log tc "lean client opened the display with only injected env"
}

input_sink_start() {
    # A sink xterm reads one line and records it. Geometry must match the
    # click coordinate the host computes (100x30 at +250+200 -> centre ~550,395).
    log is "launch a sink xterm that records one typed line"
    podman exec desktop rm -f /tmp/inputproof
    podman exec -d -u desktop -e DISPLAY=:0 -e HOME=/home/desktop desktop \
        xterm -T inputtest -geometry 100x30+250+200 -e \
        sh -c 'read x; printf "%s" "$x" > /tmp/inputproof; sleep 60'
}

input_sink_check() { # $1: expected text
    local expected="${1:?expected text}" got=""
    for _ in 1 2 3 4 5; do
        got=$(podman exec desktop cat /tmp/inputproof 2>/dev/null || true)
        [ -n "$got" ] && break
        sleep 1
    done
    [ "$got" = "$expected" ] \
        || fail "input sink recorded '$got', want '$expected' (keys did not reach the focused app)"
    log is "the app received the typed text over the real input path: $got"
}

apply_client() { # $1: pod name
    # Reuse the example client (long-running xterm holds the slot), renamed
    # and pointed at the locally-imported image.
    sed -e "s/name: x11-client-demo/name: $1/" \
        -e 's|image: desktop-container:latest|image: localhost/desktop-container:latest|' \
        examples/x11-client-pod.yaml | k3s kubectl apply -f -
}

verify_scale() {
    export KUBECONFIG=/etc/rancher/k3s/k3s.yaml  # helm (unlike k3s kubectl) needs this
    log vs "free all slots so the capacity test accounts exactly"
    k3s kubectl delete pod plugin-verify x11-client-gated x11-client-demo x11-testclient \
        --ignore-not-found --wait=true >/dev/null 2>&1 || true

    # Shrink capacity to 2 while nothing holds a slot (clean re-register; no
    # allocated-device reconciliation). Proves both concurrency AND exhaustion
    # with just 3 pods instead of 11.
    log vs "set the plugin to 2 slots"
    helm upgrade plugin charts/desktop-device-plugin \
        --set image.repository=localhost/desktop-device-plugin \
        --set image.pullPolicy=Never --set slots=2 >/dev/null
    wait_for 30 4 "resource downshifts to 2 slots" \
        sh -c "k3s kubectl get node -o jsonpath='{.items[0].status.allocatable.desktop\.local/display}' | grep -qx 2"

    log vs "two clients take both slots and run concurrently"
    apply_client x11-client-a
    apply_client x11-client-b
    for n in a b; do
        wait_for 30 4 "client $n running" \
            sh -c "k3s kubectl get pod x11-client-$n -o jsonpath='{.status.phase}' | grep -q Running"
    done
    # Both must hold a LIVE connection to the one shared display at once.
    for n in a b; do
        timeout 20 k3s kubectl exec "x11-client-$n" -- sh -c 'xdpyinfo >/dev/null' \
            || fail "client $n could not open the shared display"
    done
    log vs "both clients share the display simultaneously"

    log vs "a third request cannot get a slot and stays Pending"
    apply_client x11-client-c
    sleep 15
    phase=$(k3s kubectl get pod x11-client-c -o jsonpath='{.status.phase}')
    [ "$phase" = Pending ] \
        || fail "3rd client is '$phase', want Pending (both slots held by a+b)"
    # ...and specifically because the resource is exhausted, not some other reason.
    msg=$(k3s kubectl get pod x11-client-c \
        -o jsonpath='{.status.conditions[?(@.type=="PodScheduled")].message}' 2>/dev/null || true)
    case "$msg" in
        *desktop.local/display*|*[Ii]nsufficient*) log vs "unschedulable on the resource: $msg" ;;
        *) fail "3rd client Pending for the wrong reason: '$msg'" ;;
    esac
    log vs "verify-scale passed"
}

verify_teardown() {
    export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
    log td "helm uninstall both charts"
    helm uninstall plugin >/dev/null || fail "helm uninstall plugin failed"
    helm uninstall desktop >/dev/null || fail "helm uninstall desktop failed"

    # Removing the device-plugin daemonset must make the node stop offering the
    # resource. kubelet drops the allocatable COUNT to 0 promptly but often
    # keeps the resource key in node status for a while, so assert the count is
    # 0 (or the key is gone), not that the key vanished.
    wait_for 30 4 "desktop.local/display no longer allocatable" \
        sh -c "v=\$(k3s kubectl get node -o jsonpath='{.items[0].status.allocatable.desktop\.local/display}'); [ -z \"\$v\" ] || [ \"\$v\" = 0 ]"
    # The chart-managed workloads must be gone (get returns non-zero once
    # the objects no longer exist).
    wait_for 20 3 "desktop deployment + plugin daemonset gone" \
        sh -c "! k3s kubectl get deploy desktop >/dev/null 2>&1 && ! k3s kubectl get ds plugin-desktop-device-plugin >/dev/null 2>&1"
    log td "charts uninstalled; resource withdrawn; workloads removed"
    log td "verify-teardown passed"
}

case "${1:?phase1|phase2|play-audio|play-audio-pod|verify-plugin|verify-testclient|verify-scale|verify-teardown|input-sink-start|input-sink-check}" in
    phase1) phase1 ;;
    phase2) phase2 ;;
    play-audio) play_audio "${2:-}" ;;
    play-audio-pod) play_audio_pod "${2:-}" "${3:-}" ;;
    verify-plugin) verify_plugin ;;
    verify-testclient) verify_testclient ;;
    verify-scale) verify_scale ;;
    verify-teardown) verify_teardown ;;
    input-sink-start) input_sink_start ;;
    input-sink-check) input_sink_check "${2:-}" ;;
    *) fail "unknown phase $1" ;;
esac
