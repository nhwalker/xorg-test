#!/bin/bash
# Runs INSIDE the Rocky 9 e2e VM (as root via sudo from the rocky user).
# phase1: podman/quadlet flow with the real install.sh - real Xorg on the
#         virtio display, audio, host-terminal ssh, all under SELinux
#         enforcing.
# phase-deploy: the declarative deploy/ tree on the same VM - install.sh
#         uninstalled (which restores a live getty for seat-prep to evict),
#         tree rsync-applied, desktop booted from its quadlet, root-owned
#         desktop-shell ssh trust exercised under SELinux enforcing, and
#         desktop-preflight asserted fully green.
# phase2: k3s + the desktop chart - client pods reaching the same display
#         through the CDI device desktop.local/display=all, injected by
#         CRI-O from /etc/cdi/desktop.yaml.
set -euo pipefail

REPO="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$REPO"

# EL sudo's secure_path omits /usr/local/bin, where the k3s installer and
# our helm download land. Without this the k3s readiness loop silently
# spins on "command not found".
export PATH="/usr/local/bin:$PATH"

# CRI-O stream to install for phase 2 (the chart's documented runtime). Kept
# near k3s's k8s minor; CRI-O interops across a minor or two if it drifts.
CRIO_VERSION="${CRIO_VERSION:-v1.31}"

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
        echo "---- diagnostics: client CDI spec ----" >&2
        cat /etc/cdi/desktop.yaml >&2 2>/dev/null || echo "(no /etc/cdi/desktop.yaml)" >&2
        echo "---- diagnostics: crio CDI view ----" >&2
        journalctl -u crio --no-pager -o cat 2>/dev/null | grep -i cdi | tail -20 >&2 || true
        echo "---- diagnostics: desktop pod audio (export sockets + pipewire procs) ----" >&2
        k3s kubectl exec deploy/desktop -- sh -c \
            'ls -la /run/desktop-audio 2>&1; echo "-- pipewire procs:"; ps -o pid,comm -C pipewire -C pipewire-pulse -C wireplumber 2>&1; echo "-- listening unix sockets:"; ss -lxn 2>&1 | grep desktop-audio' \
            >&2 2>&1 || true
        k3s kubectl describe pod x11-client-demo cdi-verify >&2 2>/dev/null || true
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

    log p1 "install.sh wrote the client CDI spec"
    [ -f /etc/cdi/desktop.yaml ] || fail "install.sh did not write /etc/cdi/desktop.yaml"
    grep -q 'kind: desktop.local/display' /etc/cdi/desktop.yaml \
        || fail "client CDI spec has the wrong kind"

    # The whole client contract in one command, under podman: a SEPARATE
    # container that passes no -v and no -e reaches the display purely
    # because the runtime applied the spec's containerEdits. Same mechanism
    # k8s uses via the annotation, minus kubernetes.
    log p1 "a podman client resolves desktop.local/display=all and opens :0"
    out=$(podman run --rm --device desktop.local/display=all \
        localhost/desktop-container:latest \
        sh -c 'printenv DISPLAY; xdpyinfo >/dev/null && echo XDPYINFO_OK') \
        || fail "podman CDI client failed (see output above)"
    echo "$out" | grep -qx ':0' || fail "CDI did not inject DISPLAY=:0 (got: $out)"
    echo "$out" | grep -qx XDPYINFO_OK \
        || fail "CDI client could not open the display (got: $out)"
    log p1 "podman CDI client reached the display with no -v/-e of its own"

    log p1 "spawn an xterm so the screendump shows a window"
    podman exec -d -u desktop -e DISPLAY=:0 -e HOME=/home/desktop desktop \
        xterm -T e2e-proof -geometry 80x24+80+80
    sleep 3
    log p1 "phase1 passed"
}

phase_deploy() {
    log pd "SELinux must still be enforcing for this phase to mean anything"
    [ "$(getenforce)" = Enforcing ] || fail "SELinux is not enforcing"

    log pd "hand over: uninstall the install.sh flow (restores getty@tty1, a live dirty seat)"
    ./install.sh --uninstall
    if systemctl is-active --quiet desktop.service; then
        fail "desktop.service still active after uninstall"
    fi

    log pd "install the deploy tree's host prerequisites (HOST-REQUIRES.md)"
    dnf -y -q install rsync psmisc >/dev/null

    log pd "apply the deploy tree (verbatim README command)"
    rsync -a --chown=root:root deploy/host/ /
    [ -L /etc/systemd/system/getty@tty1.service ] || fail "getty mask did not survive as a symlink"
    systemctl daemon-reload
    systemd-sysusers
    systemd-tmpfiles --create || true
    # the sshd_config.d drop-in (root-owned authorized_keys path) is only
    # read at sshd start; this VM's sshd predates it
    systemctl reload sshd

    log pd "start desktop.service; seat-prep must evict the getty uninstall restarted"
    systemctl start desktop.service
    for u in desktop-seat-prep desktop-cdi-refresh desktop-display-cdi desktop-host-shell; do
        systemctl is-active --quiet "$u.service" || fail "$u.service not active"
    done
    # The tree ships this one pre-enabled (multi-user.target.wants symlink)
    # because a k8s node never starts desktop.service at all - assert the
    # symlink survived the rsync, not just that the unit happens to be up.
    [ "$(systemctl is-enabled desktop-display-cdi.service)" = enabled ] \
        || fail "desktop-display-cdi.service is not enabled for multi-user.target"
    if systemctl is-active --quiet getty@tty1.service; then
        fail "getty@tty1 survived seat-prep"
    fi

    log pd "container reaches running"
    wait_for 40 3 "systemd running in container" container_running

    log pd "stub CDI spec resolved (no NVIDIA in the VM; marker on container PID 1)"
    grep -q NVIDIA_CDI_STUB /etc/cdi/nvidia.yaml || fail "stub CDI spec not written"
    podman exec desktop sh -c "tr '\0' '\n' </proc/1/environ | grep -qx NVIDIA_CDI_STUB=1" \
        || fail "stub marker not on container PID 1"

    log pd "the tree's oneshot wrote the client CDI spec"
    grep -q 'kind: desktop.local/display' /etc/cdi/desktop.yaml \
        || fail "desktop-display-cdi did not write a usable /etc/cdi/desktop.yaml"

    log pd "Xorg serves the virtio display, rootless, under the deploy quadlet"
    wait_for 60 4 "X socket" podman exec desktop test -S /tmp/.X11-unix/X0
    podman exec -u desktop -e DISPLAY=:0 desktop xdpyinfo >/dev/null \
        || fail "xdpyinfo could not talk to :0"
    owner=$(podman exec desktop sh -c 'ps -o user= -C Xorg | head -1' || true)
    [ "$owner" = desktop ] || fail "Xorg runs as '${owner:-nobody}', want desktop"
    podman exec desktop sh -c 'loginctl list-sessions --no-pager | grep -q seat0' \
        || fail "no seat0 session"
    podman exec desktop ps -C mwm >/dev/null || fail "mwm not running"

    log pd "host terminal under SELinux enforcing: desktop-shell account, root-owned trust"
    # This is the path only this phase can prove: sshd reading the key from
    # /etc/ssh/authorized_keys.d (not a home dir) with SELinux enforcing.
    who=$(ssh -i /etc/desktop-container/host-shell-key -o BatchMode=yes -o ConnectTimeout=5 \
        -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null desktop-shell@127.0.0.1 whoami)
    [ "$who" = desktop-shell ] || fail "host-side ssh whoami='$who', want desktop-shell"
    who=$(podman exec -u desktop -e HOME=/home/desktop desktop \
        ssh -o ConnectTimeout=5 -o BatchMode=yes host whoami)
    [ "$who" = desktop-shell ] || fail "container 'ssh host' whoami='$who', want desktop-shell"

    log pd "desktop-preflight fully green on the VM"
    out=$(desktop-preflight) || { echo "$out"; fail "desktop-preflight reported FAILs"; }
    echo "$out"
    echo "$out" | grep -q 'done: 0 FAIL' || fail "preflight did not report 0 FAILs"

    log pd "spawn an xterm so the screendump shows a window"
    podman exec -d -u desktop -e DISPLAY=:0 -e HOME=/home/desktop desktop \
        xterm -T deploy-proof -geometry 80x24+80+80
    sleep 3
    log pd "phase-deploy passed"
}

phase2() {
    log p2 "hand the display over: stop quadlet desktop"
    systemctl stop desktop.service
    rm -f /etc/containers/systemd/desktop.container
    systemctl daemon-reload

    # Client pods reach the display through a cdi.k8s.io annotation, which
    # only the CRI resolves - so this phase runs k3s on an EXTERNAL CRI-O
    # instead of the bundled containerd (also what the chart targets:
    # container=cri-o env, the GPU annotation). CRI-O scans /etc/cdi by
    # default, which is where both specs live.
    # (SELinux policy interplay is out of scope here: permissive.)
    log p2 "install CRI-O ${CRIO_VERSION} (the chart's documented runtime)"
    setenforce 0
    cat > /etc/yum.repos.d/cri-o.repo <<EOF
[cri-o]
name=CRI-O ${CRIO_VERSION}
baseurl=https://pkgs.k8s.io/addons:/cri-o:/stable:/${CRIO_VERSION}/rpm/
enabled=1
gpgcheck=1
gpgkey=https://pkgs.k8s.io/addons:/cri-o:/stable:/${CRIO_VERSION}/rpm/repodata/repomd.xml.key
EOF
    dnf -y -q install cri-o >/dev/null

    # podman and CRI-O share /var/lib/containers/storage by default, so a root
    # `podman load` is visible to CRI-O - no ctr import or skopeo needed. Load
    # before starting crio to avoid concurrent writers to the storage.
    log p2 "load images into shared containers-storage"
    for t in desktop testclient; do
        podman load -q -i "/tmp/images-$t.tar" >/dev/null
    done
    # Guard against tag/content mix-ups in the archive plumbing (a combined
    # podman-save archive once shipped the desktop image under BOTH tags).
    ddig=$(podman image inspect localhost/desktop-container:latest --format '{{.Id}}' 2>/dev/null || true)
    tdig=$(podman image inspect localhost/desktop-testclient:latest --format '{{.Id}}' 2>/dev/null || true)
    if [ -z "$ddig" ] || [ -z "$tdig" ] || [ "$ddig" = "$tdig" ]; then
        fail "image load broken: desktop='$ddig' testclient='$tdig' (must both exist and differ)"
    fi

    # Everything downstream depends on this file; assert it before k3s so a
    # missing spec fails here instead of as an opaque pod creation error.
    # phase-deploy's desktop-display-cdi.service wrote it and the tree is
    # still applied - only the quadlet unit was removed above.
    log p2 "client CDI spec is on the node"
    grep -q 'kind: desktop.local/display' /etc/cdi/desktop.yaml \
        || fail "/etc/cdi/desktop.yaml missing or malformed before k3s install"

    # k3s writes its flannel CNI config + plugin binaries under its own tree,
    # not CRI-O's default /etc/cni/net.d + /opt/cni/bin. Point CRI-O at k3s's
    # dirs so the pod network comes up (else kubelet stays NetworkNotReady).
    mkdir -p /etc/crio/crio.conf.d
    cat > /etc/crio/crio.conf.d/11-k3s-cni.conf <<'EOF'
[crio.network]
network_dir = "/var/lib/rancher/k3s/agent/etc/cni/net.d"
plugin_dirs = ["/var/lib/rancher/k3s/data/current/bin", "/opt/cni/bin"]
EOF
    systemctl enable --now crio >/dev/null 2>&1 || fail "crio failed to start"
    wait_for 30 2 "crio socket" test -S /run/crio/crio.sock

    # Everything in this phase rests on CRI-O scanning /etc/cdi (its
    # default). Assert it here against the running config: otherwise the
    # first symptom is a pod failing to create with an unresolvable-device
    # error, several steps away from the cause. Matched on the path rather
    # than the option name, which has moved between CRI-O versions.
    crio config 2>/dev/null | grep -q '/etc/cdi' \
        || fail "CRI-O ${CRIO_VERSION} is not scanning /etc/cdi: set cdi_spec_dirs in /etc/crio/crio.conf.d"
    log p2 "crio scans /etc/cdi for device specs"

    log p2 "install k3s driving the external CRI-O (kubelet cgroup driver = systemd to match)"
    curl -sfL https://get.k3s.io | INSTALL_K3S_EXEC="\
        --container-runtime-endpoint=unix:///run/crio/crio.sock \
        --kubelet-arg=cgroup-driver=systemd \
        --disable traefik --disable metrics-server" sh - >/dev/null
    wait_for 60 5 "k3s node ready" \
        sh -c "k3s kubectl get nodes | grep -q ' Ready'"
    # Prove the node really runs CRI-O, not the bundled containerd.
    k3s kubectl get node -o jsonpath='{.items[0].status.nodeInfo.containerRuntimeVersion}' \
        | grep -q cri-o || fail "node runtime is not cri-o"

    curl -fsSL https://get.helm.sh/helm-v3.16.4-linux-amd64.tar.gz \
        | tar -xz -C /usr/local/bin --strip-components=1 linux-amd64/helm

    log p2 "deploy desktop chart and wait for real readiness (xdpyinfo probe)"
    export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
    helm install desktop charts/desktop-container --set fullnameOverride=desktop \
        --set image.repository=localhost/desktop-container --set image.pullPolicy=Never
    wait_for 40 5 "desktop deployment ready" \
        sh -c "k3s kubectl get deploy desktop -o jsonpath='{.status.readyReplicas}' | grep -q 1"

    log p2 "client pod schedules and opens xterm on the desktop"
    # The example pod carries only the cdi.k8s.io annotation - no resource
    # request, no volumes, no env - so it running an X client at all is the
    # CDI injection working.
    sed 's|image: desktop-container:latest|image: localhost/desktop-container:latest|' \
        examples/x11-client-pod.yaml | k3s kubectl apply -f -
    wait_for 30 4 "client pod running" \
        sh -c "k3s kubectl get pod x11-client-demo -o jsonpath='{.status.phase}' | grep -q Running"
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

# --- CDI injection verification (phase 2) -----------------------------------

VPOD=cdi-verify

assert_pod_env() { # $1: var, $2: expected value
    local got
    got=$(k3s kubectl exec "$VPOD" -- printenv "$1" 2>/dev/null || true)
    [ "$got" = "$2" ] || fail "injected env $1='$got', want '$2'"
    log vp "env $1=$got"
}

assert_pod_socket() { # $1: path
    # Present, a socket, and writable: the spec mounts rw because unix
    # connect(2) needs write access; a ro mount would pass -S but break use.
    k3s kubectl exec "$VPOD" -- sh -c "test -S '$1' && test -w '$1'" \
        || fail "socket $1 missing or not writable in the annotated pod"
    log vp "socket $1 present + writable"
}

verify_cdi() {
    log vp "apply verifier pod: cdi.k8s.io annotation only, declares nothing else"
    k3s kubectl apply -f ci/vm/cdi-verify-pod.yaml
    wait_for 30 4 "verifier pod running" \
        sh -c "k3s kubectl get pod $VPOD -o jsonpath='{.status.phase}' | grep -q Running"

    log vp "CDI injected the DISPLAY + audio env vars"
    assert_pod_env DISPLAY :0
    assert_pod_env PULSE_SERVER unix:/run/desktop-audio/pulse
    assert_pod_env PIPEWIRE_REMOTE /run/desktop-audio/pipewire-0

    log vp "the injected X socket is mounted and the display works"
    assert_pod_socket /tmp/.X11-unix/X0
    # sh -c so it uses the injected DISPLAY, not a hardcoded one; bounded so
    # a broken connection fails instead of hanging.
    timeout 20 k3s kubectl exec "$VPOD" -- sh -c 'xdpyinfo >/dev/null' \
        || fail "xdpyinfo could not open the display from the annotated pod"
    log vp "xdpyinfo opened :0 from the pod"

    # Negative control: without the annotation the SAME image gets none of
    # it. Without this, a stray hostPath or a baked-in env in the desktop
    # image would make every assertion above pass for the wrong reason.
    log vp "control: an identical pod WITHOUT the annotation gets nothing"
    k3s kubectl delete pod cdi-control --ignore-not-found >/dev/null 2>&1 || true
    grep -v 'cdi\.k8s\.io/display' ci/vm/cdi-verify-pod.yaml \
        | sed -e 's/^  name: cdi-verify$/  name: cdi-control/' \
              -e '/^  annotations:$/d' \
        | k3s kubectl apply -f -
    wait_for 30 4 "control pod running" \
        sh -c "k3s kubectl get pod cdi-control -o jsonpath='{.status.phase}' | grep -q Running"
    if k3s kubectl exec cdi-control -- printenv DISPLAY >/dev/null 2>&1; then
        fail "control pod has DISPLAY set without the annotation - injection is not what we measured"
    fi
    if k3s kubectl exec cdi-control -- test -S /tmp/.X11-unix/X0 2>/dev/null; then
        fail "control pod can see the X socket without the annotation"
    fi
    k3s kubectl delete pod cdi-control --wait=true >/dev/null 2>&1 || true
    log vp "control pod saw no DISPLAY and no X socket - the annotation is the cause"

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
    log vp "CDI mounted the audio sockets; export is live"
    assert_pod_socket /run/desktop-audio/pulse
    assert_pod_socket /run/desktop-audio/pipewire-0

    log vp "spawn an xterm from the pod so the screendump shows a client window"
    timeout 15 k3s kubectl exec "$VPOD" -- \
        sh -c 'setsid xterm -T cdi-verify -geometry 80x24+150+150 </dev/null >/dev/null 2>&1 &' \
        || true
    sleep 3
    log vp "verify-cdi passed"
}

play_audio_pod() { # $1: pulse|pipewire|alsa   $2: pod (default cdi-verify)
    # Same beep-per-path convention as the in-container test, but played from an
    # annotated pod using ONLY the injected env - so success proves the CDI spec
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
    log tc "apply a LEAN non-desktop client (no server stack) carrying the annotation"
    k3s kubectl apply -f ci/vm/testclient-pod.yaml
    wait_for 30 4 "testclient running" \
        sh -c "k3s kubectl get pod x11-testclient -o jsonpath='{.status.phase}' | grep -q Running"
    # The image ships no Xorg server or session, so a working display here can
    # only come from the CDI spec's injected DISPLAY + X-socket mount.
    got=$(k3s kubectl exec x11-testclient -- printenv DISPLAY 2>/dev/null || true)
    [ "$got" = ":0" ] || fail "testclient DISPLAY='$got', want :0 (CDI injection)"
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
    # Reuse the example client (a long-running xterm), renamed and pointed
    # at the locally-imported image.
    sed -e "s/name: x11-client-demo/name: $1/" \
        -e 's|image: desktop-container:latest|image: localhost/desktop-container:latest|' \
        examples/x11-client-pod.yaml | k3s kubectl apply -f -
}

verify_concurrency() {
    # The display is shareable and CDI imposes no cap, so the property to
    # prove is that several independent clients hold LIVE connections to the
    # one display at the same time - not that a counter runs out.
    log vs "start from a clean slate"
    k3s kubectl delete pod cdi-verify x11-client-demo x11-testclient \
        --ignore-not-found --wait=true >/dev/null 2>&1 || true

    log vs "three clients open the shared display concurrently"
    for n in a b c; do apply_client "x11-client-$n"; done
    for n in a b c; do
        wait_for 30 4 "client $n running" \
            sh -c "k3s kubectl get pod x11-client-$n -o jsonpath='{.status.phase}' | grep -q Running"
    done
    for n in a b c; do
        timeout 20 k3s kubectl exec "x11-client-$n" -- sh -c 'xdpyinfo >/dev/null' \
            || fail "client $n could not open the shared display"
    done
    # ...and all three at once, not merely one after another: each holds an
    # X connection open while the next one connects.
    timeout 40 k3s kubectl exec x11-client-a -- \
        sh -c 'xterm -T hold-a -geometry 40x8+40+400 & sleep 25' >/dev/null 2>&1 &
    holder=$!
    sleep 5
    for n in b c; do
        timeout 20 k3s kubectl exec "x11-client-$n" -- sh -c 'xdpyinfo >/dev/null' \
            || { kill "$holder" 2>/dev/null; fail "client $n lost the display while a held it"; }
    done
    kill "$holder" 2>/dev/null || true
    wait "$holder" 2>/dev/null || true
    log vs "three concurrent clients on one display, no cap in the way"
    log vs "verify-concurrency passed"
}

verify_teardown() {
    export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
    log td "helm uninstall the desktop chart"
    helm uninstall desktop >/dev/null || fail "helm uninstall desktop failed"

    # The chart-managed workload must be gone (get returns non-zero once the
    # object no longer exists).
    wait_for 20 3 "desktop deployment gone" \
        sh -c "! k3s kubectl get deploy desktop >/dev/null 2>&1"

    # The CDI spec is host state, not chart state: uninstalling the desktop
    # must NOT remove it (nothing in k8s owns it). Clients that keep the
    # annotation simply find no socket behind the mount.
    grep -q 'kind: desktop.local/display' /etc/cdi/desktop.yaml \
        || fail "helm uninstall removed the host CDI spec - it is host state"
    log td "chart uninstalled; workload removed; host CDI spec untouched"
    log td "verify-teardown passed"
}

verify_record() {
    # Capture direction: a client RECORDS from the desktop's audio, not just
    # plays. Loopback via the sink's monitor source - record it while playing a
    # known tone into the same sink, then confirm the recording carries that
    # tone. Runs in cdi-verify (a client pod) over the injected PULSE_SERVER.
    local pod=cdi-verify freq=660
    gen_tone "$freq" /tmp/rectone.wav
    timeout 20 k3s kubectl exec -i "$pod" -- sh -c 'cat > /tmp/rt.wav' \
        < /tmp/rectone.wav || fail "could not copy record tone into $pod"

    log rec "record the sink monitor while playing a ${freq}Hz tone"
    timeout 30 k3s kubectl exec "$pod" -- sh -c '
        sink=$(pactl get-default-sink) || exit 3
        parec -d "${sink}.monitor" --file-format=wav \
            --rate=44100 --format=s16le --channels=2 /tmp/rec.wav &
        rpid=$!
        sleep 0.5
        paplay /tmp/rt.wav
        sleep 0.5
        kill -INT "$rpid" 2>/dev/null   # SIGINT: parec finalizes the WAV header
        wait "$rpid" 2>/dev/null
        true
    ' || fail "record/playback in $pod failed"

    # Pull the recording into the VM and analyse it there (Rocky has python3);
    # kubectl exec (no -t) streams the bytes verbatim.
    timeout 20 k3s kubectl exec "$pod" -- cat /tmp/rec.wav > /tmp/rec-pulled.wav \
        || fail "could not pull the recording from $pod"
    python3 ci/vm/check-audio.py /tmp/rec-pulled.wav 0.5 0.02 "$freq" \
        || fail "recorded audio is silent or not ${freq}Hz - capture path broken"
    log rec "a client recorded the ${freq}Hz tone back from the desktop audio"
    log rec "verify-record passed"
}

case "${1:?phase1|phase-deploy|phase2|play-audio|play-audio-pod|verify-cdi|verify-testclient|verify-record|verify-concurrency|verify-teardown|input-sink-start|input-sink-check}" in
    phase1) phase1 ;;
    phase-deploy) phase_deploy ;;
    phase2) phase2 ;;
    play-audio) play_audio "${2:-}" ;;
    play-audio-pod) play_audio_pod "${2:-}" "${3:-}" ;;
    verify-cdi) verify_cdi ;;
    verify-testclient) verify_testclient ;;
    verify-record) verify_record ;;
    verify-concurrency) verify_concurrency ;;
    verify-teardown) verify_teardown ;;
    input-sink-start) input_sink_start ;;
    input-sink-check) input_sink_check "${2:-}" ;;
    *) fail "unknown phase $1" ;;
esac
