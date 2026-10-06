#!/bin/bash
# Runs INSIDE the Rocky 9 e2e VM (as root via sudo from the rocky user).
# phase-deploy: the declarative deploy/ tree applied to a stock host - tree
#         rsync-applied over the boot getty seat-prep must evict, desktop
#         booted from its quadlet with real Xorg on the virtio display,
#         audio, root-owned desktop-shell ssh trust under SELinux enforcing,
#         the CONFINED podman client CDI contract, a fixed monitor layout
#         brought up across a connector QEMU never connects, and
#         desktop-preflight fully green.
# phase2: k3s + CRI-O + one cdi-device-plugin release per capability, with
#         the quadlet desktop STILL RUNNING and SELinux STILL ENFORCING -
#         confined client pods requesting desktop.local/display and/or
#         desktop.local/audio, with CRI-O injecting from the matching
#         /etc/cdi spec. Kubernetes carries application containers here; it
#         never carries the desktop.
#
# Both phases run enforcing end to end. Nothing in this suite calls
# setenforce: a client that only works permissive is a client that does not
# work, and that is the whole point of the desktop-selinux labeling the
# deploy tree ships.
#
# podman flag conventions used throughout, stated once here rather than at
# each of the two dozen call sites:
#
#   podman exec -u desktop     Enter as the SESSION user, not root. Checks
#                              about the desktop (can it open the display, can
#                              it reach the audio socket, does ssh work) are
#                              only meaningful as the user that actually runs
#                              it; root would pass some of them for the wrong
#                              reason.
#   podman exec -e DISPLAY=... `podman exec` inherits the environment of the
#              -e HOME=...     container's PID 1, NOT of the logind session -
#              -e XDG_RUNTIME_DIR   so DISPLAY, HOME and XDG_RUNTIME_DIR are
#                              absent and have to be supplied. Getting this
#                              wrong looks like a broken desktop rather than a
#                              broken test.
#   podman exec -d             Detach, for the xterms that must stay up while
#                              the screendump is taken. Without it the exec
#                              blocks until the window is closed, which never
#                              happens.
#   podman run --rm            Every `podman run` here is a one-shot probe;
#                              leftovers would pollute the container list the
#                              later checks read.
#
# The flags NOT passed matter as much: no --security-opt label=disable and no
# --privileged on any client, because the point is that a CONFINED client
# works. See the block above the podman client probes in phase-deploy.
set -euo pipefail

REPO="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$REPO"

# Evidence (Requirements.md, "Evidence standard"). vm-e2e.sh switches it on
# per call with EV_ROOT=/var/tmp/ev and copies that tree back to the host's
# artifacts afterwards; without EV_ROOT every assertion still runs.
# shellcheck source=ci/evidence.sh
. ci/evidence.sh
[ -z "$EV_ROOT" ] || mkdir -p "$EV_ROOT"

# EL sudo's secure_path omits /usr/local/bin, where the k3s installer and
# our helm download land. Without this the k3s readiness loop silently
# spins on "command not found".
export PATH="/usr/local/bin:$PATH"

# The desktop's processes S7.3.7 follows across the k3s install.
S737_COMMS=desktop-init,xinit,Xorg,mwm,pipewire,wireplumber,pipewire-pulse

# CRI-O stream to install for phase 2 (the documented runtime for CDI). Kept
# near k3s's k8s minor; CRI-O interops across a minor or two if it drifts.
CRIO_VERSION="${CRIO_VERSION:-v1.31}"

log()  { echo "== vm-guest($1): $2"; }
fail() {
    # Kept in a variable so it can be repeated at the very end: what follows is
    # around 200 lines of diagnostics, which leaves the one line saying WHY
    # scrolled far off the bottom of the job log. Reading the tail of a failed
    # run should not require counting backwards past the Xorg log.
    _failmsg="FAIL: vm-guest: $*"
    echo "$_failmsg" >&2
    local d
    d=$(diagnostics 2>&1)
    printf '%s\n' "$d" >&2
    # A story open when it failed keeps them: a red story is reviewable from
    # its own directory, not only from the job log.
    ev_text failure-diagnostics "what fail() printed when this story failed: the desktop log, Xorg log, preflight, audio, SELinux and k3s state" "$d"
    ev_abort "$*"
    echo "$_failmsg" >&2
    exit 1
}

diagnostics() {
    echo "---- diagnostics: podman logs desktop (tail) ----"
    podman logs desktop 2>&1 | tail -80 || true
    echo "---- diagnostics: Xorg log (tail) ----"
    podman exec desktop sh -c 'tail -40 /home/desktop/.local/share/xorg/Xorg.0.log' 2>/dev/null || true
    echo "---- diagnostics: postmortem ----"
    podman logs desktop 2>&1 | grep 'postmortem:' | tail -30 || true
    echo "---- diagnostics: preflight ----"
    podman logs desktop 2>&1 | grep 'preflight:' || true
    echo "---- diagnostics: desktop-init state ----"
    podman exec desktop sh -c 'ls -l /run/desktop-init-ready /run/desktop-init.pid 2>&1; echo "-- session procs:"; ps -o pid,user,comm -u desktop 2>&1' 2>&1 || true
    echo "---- diagnostics: desktop audio (export sockets + pipewire procs) ----"
    podman exec desktop sh -c \
        'ls -la /run/desktop-audio 2>&1; echo "-- pipewire procs:"; ps -o pid,comm -C pipewire -C pipewire-pulse -C wireplumber 2>&1; echo "-- listening unix sockets:"; ss -lxn 2>&1 | grep desktop-audio' \
        2>&1 || true
    # phase-deploy runs enforcing, where a denial is often the whole story
    # and is invisible in every other log here.
    echo "---- diagnostics: SELinux mode + client-facing labels ----"
    getenforce 2>/dev/null || true
    ls -Zd /tmp/.X11-unix /run/desktop-audio /var/lib/desktop-container/bin 2>/dev/null || true
    systemctl status desktop-selinux.service --no-pager -l  2>/dev/null | head -20 || true
    echo "---- diagnostics: recent SELinux denials ----"
    ausearch -m avc -ts recent 2>/dev/null | tail -20  || echo "(none / ausearch unavailable)" 
    if command -v k3s >/dev/null; then
        echo "---- diagnostics: k3s state ----"
        k3s kubectl get nodes,pods -A -o wide 2>/dev/null || true
        echo "---- diagnostics: node allocatable ----"
        k3s kubectl get node -o jsonpath='{.items[0].status.allocatable}' 2>/dev/null || true
        echo "" 
        echo "---- diagnostics: pod images actually running ----"
        k3s kubectl get pods -A -o custom-columns='NAME:.metadata.name,IMAGE:.spec.containers[0].image,IMAGEID:.status.containerStatuses[0].imageID' 2>&1 || true
        echo "---- diagnostics: client CDI specs ----"
        for f in /etc/cdi/desktop-display.yaml /etc/cdi/desktop-audio.yaml; do
            echo "-- $f" 
            cat "$f"  2>/dev/null || echo "(missing)" 
        done
        echo "---- diagnostics: cdi-device-plugin logs ----"
        k3s kubectl logs -l app.kubernetes.io/name=cdi-device-plugin --tail=30 2>&1 || true
        echo "---- diagnostics: kubelet plugin dir ----"
        ls -la /var/lib/kubelet/device-plugins/ 2>/dev/null || true
        echo "---- diagnostics: crio CDI view ----"
        journalctl -u crio --no-pager -o cat 2>/dev/null | grep -i cdi | tail -20 || true
        k3s kubectl describe pod x11-client-demo cdi-verify display-only audio-only 2>/dev/null || true
        journalctl -u k3s --no-pager -o cat 2>/dev/null | tail -20 || true
    fi
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
    # desktop-init writes the marker after the boot oneshots; the session's
    # own health is asserted separately (session_up below), matching the old
    # split between is-system-running and the display checks.
    podman exec desktop test -f /run/desktop-init-ready 2>/dev/null
}

session_up() {
    # The replacement for the old loginctl seat0 assertion: with no logind
    # in the container the observable fact is the session itself - mwm
    # running as the session user.
    podman exec desktop pgrep -u desktop -x mwm >/dev/null 2>&1
}

phase_deploy() {
    log pd "SELinux must be enforcing for this phase to mean anything"
    [ "$(getenforce)" = Enforcing ] || fail "SELinux is not enforcing"

    # podman, psmisc and policycoreutils-python-utils are deploy-tree
    # prerequisites (HOST-REQUIRES.md); the cloud image already carries
    # openssh-server. rsync applies the tree and pulseaudio-utils (pactl) is
    # this test's own probe - neither is a prerequisite of the deployment.
    #
    # policycoreutils-python-utils matters here: it is what makes
    # desktop-selinux take its semanage path rather than the chcon fallback,
    # and the semanage path is the one hosts are meant to run.
    # `audit` is purely for diagnostics, and it earns its place: without
    # ausearch, fail() prints "(none / ausearch unavailable)" and an SELinux
    # failure costs a whole CI round just to find out what was denied.
    log pd "install the deploy tree's prerequisites plus this phase's probes"
    dnf -y -q install podman psmisc policycoreutils-python-utils \
        rsync pulseaudio-utils audit >/dev/null

    log pd "load prebuilt images"
    podman load -q -i /tmp/images-desktop.tar >/dev/null

    # The tree is applied to a STOCK host: nothing has prepared the seat, so
    # the boot getty still owns tty1. That is the production case seat-prep
    # exists for - assert the dirty seat is real before relying on it below.
    if ! systemctl is-active --quiet getty@tty1.service; then
        fail "getty@tty1 is not active - the seat is already clean, so seat-prep would prove nothing"
    fi

    log pd "apply the deploy tree (verbatim README command)"
    rsync -a --chown=root:root deploy/host/ /
    # S7.2.5's "before": /etc/cdi as the tree leaves it, before the desktop's
    # first start. Kept now, attached to the story once the spec appears.
    ls -l --full-time /etc/cdi > /tmp/ev-cdi-before-start.txt 2>&1 || true
    [ -L /etc/systemd/system/getty@tty1.service ] || fail "getty mask did not survive as a symlink"
    systemctl daemon-reload
    deploy_applied
    systemd-sysusers
    systemd-tmpfiles --create || true
    # the sshd_config.d drop-in (root-owned authorized_keys path) is only
    # read at sshd start; this VM's sshd predates it
    systemctl reload sshd

    log pd "desktop-seat-prep on its own must evict the boot getty (S5.3.1); then desktop.service"
    seat_prep_dirty
    systemctl start desktop.service
    for u in desktop-seat-prep desktop-cdi-refresh desktop-client-cdi desktop-host-shell desktop-selinux; do
        systemctl is-active --quiet "$u.service" || fail "$u.service not active"
    done
    # The tree ships this one pre-enabled (multi-user.target.wants symlink):
    # the client specs are host state that must exist whether or not the
    # desktop is up, so assert the symlink survived the rsync rather than
    # just that the unit happens to be active right now.
    [ "$(systemctl is-enabled desktop-client-cdi.service)" = enabled ] \
        || fail "desktop-client-cdi.service is not enabled for multi-user.target"
    if systemctl is-active --quiet getty@tty1.service; then
        fail "getty@tty1 survived seat-prep"
    fi

    log pd "container reaches running"
    wait_for 40 3 "desktop-init ready in container" container_running

    log pd "stub CDI spec resolved (no NVIDIA in the VM; marker on the init process)"
    ev_begin S5.4.1 "Stub on a GPU-less host, resolvable by podman" T3
    ev_copy /etc/cdi/nvidia.yaml nvidia-cdi-spec "EV-CONFIG: /etc/cdi/nvidia.yaml as desktop-cdi-refresh wrote it on this GPU-less VM: the stub, whose only edit is NVIDIA_CDI_STUB=1"
    grep -q NVIDIA_CDI_STUB /etc/cdi/nvidia.yaml || fail "stub CDI spec not written"
    ev_pass "with no toolkit and no NVIDIA hardware, desktop-cdi-refresh wrote the stub spec"
    # /proc/1 is the HOST's systemd under --pid=host; the CDI env edits land
    # on the container's init process, whose (host) pid desktop-init records.
    ev_save init-environ "EV-STATE: the NVIDIA lines of the container init's environment (/proc/<desktop-init>/environ); NVIDIA_CDI_STUB=1 there means podman resolved --device nvidia.com/gpu=all against the stub" \
        podman exec desktop sh -c 'tr "\0" "\n" </proc/$(cat /run/desktop-init.pid)/environ | grep NVIDIA' >/dev/null || true
    podman exec desktop sh -c 'tr "\0" "\n" </proc/$(cat /run/desktop-init.pid)/environ | grep -qx NVIDIA_CDI_STUB=1' \
        || fail "stub marker not on the container init process"
    ev_pass "NVIDIA_CDI_STUB=1 is in the container init's environment"
    ev_end

    log pd "the tree's oneshot wrote both client CDI specs"
    grep -q 'kind: desktop.local/display' /etc/cdi/desktop-display.yaml \
        || fail "desktop-client-cdi did not write a usable display spec"
    grep -q 'kind: desktop.local/audio' /etc/cdi/desktop-audio.yaml \
        || fail "desktop-client-cdi did not write a usable audio spec"

    log pd "the desktop published its toolkit and the watcher advertised it"
    # Unlike the two specs above, this one is not written at boot: the .path
    # unit fires only once the desktop has published. Asserting it HERE rather
    # than leaving it to phase2 keeps the whole chain (image -> publish-tools.sh
    # -> host dir -> .path -> generator) attributable to the phase that runs it;
    # a failure downstream in k8s otherwise looks like a device-plugin problem.
    wait_for 30 1 "tools CDI spec" test -s /etc/cdi/desktop-tools.yaml
    [ -s /var/lib/desktop-container/bin/screenshot ] \
        || fail "the desktop did not publish screenshot into /var/lib/desktop-container/bin"
    grep -q 'kind: desktop.local/tools' /etc/cdi/desktop-tools.yaml \
        || fail "desktop-tools-cdi.path did not advertise the toolkit after the desktop published"
    ev_begin S7.2.5 "Advertised only after provisioning" T3
    ev_copy /tmp/ev-cdi-before-start.txt cdi-before-first-start "EV-STATE: ls -l --full-time /etc/cdi right after the tree was applied, before the desktop's first start: no desktop-tools.yaml"
    cdi_before=$EV_LAST
    if grep -q desktop-tools.yaml /tmp/ev-cdi-before-start.txt; then
        fail "desktop-tools.yaml existed before the desktop's first start"
    fi
    ev_pass "no tools spec before the desktop's first start"
    ev_save cdi-after-publish "EV-STATE: ls -l --full-time /etc/cdi once the desktop has published its toolkit: desktop-tools.yaml is there" \
        ls -l --full-time /etc/cdi >/dev/null || true
    ev_diff cdi "EV-DIFF: /etc/cdi before the first start and after the desktop published; the tools spec is the line that appears" \
        "$cdi_before" "$EV_LAST"
    ev_pass "the tools spec is present (kind desktop.local/tools) once the desktop has published"
    ev_end

    log pd "Xorg serves the virtio display, rootless, under the deploy quadlet"
    wait_for 60 4 "X socket" podman exec desktop test -S /tmp/.X11-unix/X0
    podman exec -u desktop -e DISPLAY=:0 desktop xdpyinfo >/dev/null \
        || fail "xdpyinfo could not talk to :0"
    ev_begin S3.2.1 "Xorg runs as the session user" T3
    ev_save xorg-process "EV-PIDS: the running Xorg (pid, ppid, user, start time, command): its user is desktop" \
        podman exec desktop ps -o pid,ppid,user,lstart,args -C Xorg >/dev/null || true
    owner=$(podman exec desktop sh -c 'ps -o user= -C Xorg | head -1' || true)
    [ "$owner" = desktop ] || fail "Xorg runs as '${owner:-nobody}', want desktop"
    ev_pass "the running Xorg's user is desktop"
    wrapper=$(ev_save xwrapper-config "EV-CONFIG: /etc/X11/Xwrapper.config in the running container: needs_root_rights = no" \
        podman exec desktop cat /etc/X11/Xwrapper.config) || true
    grep -qE '^[[:space:]]*needs_root_rights[[:space:]]*=[[:space:]]*no' <<<"$wrapper" \
        || fail "Xwrapper.config does not set needs_root_rights = no"
    ev_pass "Xwrapper.config sets needs_root_rights = no"
    ev_end
    session_up || fail "mwm not running as the session user"

    # S3.1.3 on real KMS: virtio-gpu's card0 has the connected connector, so
    # xorg-gpu-conf must have chosen it, said so, and written it.
    ev_begin S3.1.3 "modesetting picks the first connected connector's card" T3
    ev_save sysfs "EV-STATE: the VM's DRM connectors (cat /sys/class/drm/card*-*/status), which the container's sysfs shows too" \
        sh -c 'for f in /sys/class/drm/card*-*/status; do echo "$f: $(cat "$f")"; done' >/dev/null || true
    first=$(sh -c 'for f in /sys/class/drm/card*-*/status; do [ "$(cat "$f")" = connected ] && { basename "$(dirname "$f")"; break; }; done' || true)
    [ -n "$first" ] || fail "no DRM connector reads connected on the VM"
    card=/dev/dri/${first%%-*}
    ev_pass "the first connected connector is $first, so the card is $card"
    decision=$(podman logs desktop 2>/dev/null | tr -d '\r' | grep '^xorg-gpu-conf: ' \
        | awk '{print} /^xorg-gpu-conf: decision:/{exit}' || true)
    ev_text log "EV-LOG-DESKTOP: xorg-gpu-conf's lines in the desktop's log this boot, up to its decision" "${decision:-(none)}"
    grep -qx "xorg-gpu-conf: decision: modesetting driver on $card" <<<"$decision" \
        || fail "xorg-gpu-conf did not log 'decision: modesetting driver on $card'"
    ev_pass "xorg-gpu-conf logged 'decision: modesetting driver on $card'"
    gpuconf=$(ev_save config "EV-CONFIG: /etc/X11/xorg.conf.d/20-gpu.conf in the running container" \
        podman exec desktop cat /etc/X11/xorg.conf.d/20-gpu.conf) || fail "no 20-gpu.conf in the container"
    grep -qF "Option     \"kmsdev\" \"$card\"" <<<"$gpuconf" || fail "20-gpu.conf does not name $card as kmsdev"
    ev_pass "20-gpu.conf names $card as kmsdev, with the modesetting driver"
    ev_end

    log pd "the HOST owns the seat: a real logind session for the desktop user on seat0"
    # The seat0 assertion the container's logind used to answer, back where
    # it truthfully lives: desktop-session.service (this tree) opens a
    # PAM/logind session on the host, pulled up by the quadlet's Wants=.
    ev_begin S2.2.1 "The host login session's runtime dir is adopted" T3
    wait_for 15 2 "host login session on seat0" \
        sh -c "loginctl list-sessions --no-pager | grep -Eq 'desktop +seat0'"
    ev_save loginctl "EV-STATE: loginctl list-sessions on the host: a session for desktop on seat0" \
        loginctl list-sessions --no-pager >/dev/null || true
    [ -d /run/user/61000 ] || fail "logind did not mount /run/user/61000 on the host"
    ev_save findmnt "EV-STATE: findmnt /run/user/61000 on the host: logind's tmpfs for the session" \
        findmnt /run/user/61000 >/dev/null || true
    # And the runtime dir the container session uses IS that dir, live:
    # logind mounted it after the container was created, so only the
    # quadlet's rslave /run/user bind can have carried it inside. Prove the
    # propagation with a marker rather than trusting mount flags.
    touch /run/user/61000/.host-probe
    podman exec desktop test -e /run/user/61000/.host-probe \
        || { rm -f /run/user/61000/.host-probe; fail "host runtime dir does not propagate into the container: the rslave /run/user bind is broken, desktop-init is running on a fabricated dir"; }
    ev_save container-ls "EV-STATE: ls -la /run/user/61000 inside the container while the host's probe file exists: .host-probe is listed" \
        podman exec desktop ls -la /run/user/61000 >/dev/null || true
    ev_pass "a file created on the host under /run/user/61000 is visible in the container"
    rm -f /run/user/61000/.host-probe
    # Polled, not read once. Every assertion above this one reads LIVE state -
    # pgrep for Xorg and mwm, loginctl for the session - which is current the
    # instant it is queried. This one reads a LOG LINE, which has to travel
    # from desktop-init through the --tty pty and conmon into the k8s-file log
    # before `podman logs` can see it, and that lag is real: this assertion
    # failed on main (dc1b3f0) and on this branch with the line already
    # written, present in the very diagnostic dump the failure handler printed
    # a moment later. Same wait_for shape as the seat0 check above.
    #
    # The meaning is unchanged: the standalone fallback logs a DIFFERENT line
    # ("no host login session appeared"), so a genuine regression still fails
    # here - it just takes the timeout to do it instead of failing instantly.
    wait_for 15 2 "desktop-init to log that it adopted the host session's runtime dir (a standalone fallback never logs this, so a real regression still fails here)" \
        sh -c "podman logs desktop 2>/dev/null | grep -q 'runtime dir /run/user/61000 provided by the host login session'"
    ev_save desktop-log "EV-LOG-DESKTOP: desktop-init's runtime-dir lines; the standalone fallback would log 'no host login session appeared' instead" \
        sh -c "podman logs desktop 2>/dev/null | grep -E 'runtime dir|no host login session'" >/dev/null || true
    ev_pass "desktop-init logged 'runtime dir /run/user/61000 provided by the host login session'"
    ev_end

    log pd "host terminal under SELinux enforcing: desktop-shell account, root-owned trust"
    # This is the path only this phase can prove: sshd reading the key from
    # /etc/ssh/authorized_keys.d (not a home dir) with SELinux enforcing.
    ev_begin S5.7.2 "Login works both directions" T3
    ev_note "the menu half (Host Terminal opens a host shell for the operator) is the operator phase's: artifacts/S11.1.1/ holds its screenshot and sshd's accepted-publickey line"
    who=$(ev_save ssh-from-host "EV-STATE: ssh -i <key> desktop-shell@127.0.0.1 whoami, run on the host: desktop-shell" \
        ssh -i /etc/desktop-container/host-shell-key -o BatchMode=yes -o ConnectTimeout=5 \
        -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null desktop-shell@127.0.0.1 whoami) || true
    who=$(tail -n1 <<<"$who")
    [ "$who" = desktop-shell ] || fail "host-side ssh whoami='$who', want desktop-shell"
    ev_pass "from the host, ssh with the desktop's key logs in as desktop-shell"
    who=$(ev_save ssh-from-container "EV-STATE: ssh host whoami, run in the desktop container as the session user: desktop-shell" \
        podman exec -u desktop -e HOME=/home/desktop desktop \
        ssh -o ConnectTimeout=5 -o BatchMode=yes host whoami) || true
    who=$(tail -n1 <<<"$who")
    [ "$who" = desktop-shell ] || fail "container 'ssh host' whoami='$who', want desktop-shell"
    ev_pass "from the container, 'ssh host' logs in as desktop-shell"
    ev_end

    log pd "desktop-preflight fully green on the VM"
    ev_begin S5.10.1 "Fully green on a provisioned host" T3
    rc=0
    out=$(ev_save desktop-preflight "EV-STATE: desktop-preflight's full report on the provisioned VM; the last line reads 'done: 0 FAIL(s)'" \
        desktop-preflight) || rc=$?
    echo "$out"
    [ "$rc" = 0 ] || fail "desktop-preflight exited $rc (it reported FAILs)"
    ev_pass "desktop-preflight exited 0"
    grep -q 'done: 0 FAIL' <<<"$out" || fail "preflight did not report 0 FAILs"
    ev_pass "its report ends 'done: 0 FAIL(s)'"
    ev_end

    if [ "${EV_PROFILE:-}" = soundless ]; then
        log pd "HOST audio: no sound card on this VM (the soundless profile): no ALSA device to look for"
    else
        log pd "HOST audio: HDA device visible, pulse socket reachable from the host"
        podman exec -u desktop -e XDG_RUNTIME_DIR=/run/user/61000 desktop \
            sh -c 'wpctl status | grep -qi alsa' || fail "no ALSA device in wireplumber"
    fi
    # S5.6.7 asks that nothing from here to its own story was denied; this
    # is where "here" starts (ausearch -ts takes a time of day).
    ev_t0=$(date +%H:%M:%S)
    ev_begin S4.1.1 "Both sockets are exported" T3
    ev_save export-dir "EV-STATE: ls -l /run/desktop-audio on the host while the desktop runs: pipewire-0 and pulse, both sockets (type s)" \
        ls -l /run/desktop-audio >/dev/null || true
    [ -S /run/desktop-audio/pipewire-0 ] || fail "no pipewire-0 socket in the host's /run/desktop-audio"
    ev_pass "/run/desktop-audio/pipewire-0 on the host is a socket"
    [ -S /run/desktop-audio/pulse ] || fail "no pulse socket in the host's /run/desktop-audio"
    ev_pass "/run/desktop-audio/pulse on the host is a socket"
    ev_save pactl-info "EV-STATE: pactl info from the host over the exported pulse socket (the server is PipeWire's pulse layer)" \
        env PULSE_SERVER=unix:/run/desktop-audio/pulse pactl info >/dev/null \
        || fail "pulse socket unreachable from VM host"
    ev_pass "pactl info over the exported pulse socket succeeds from the host"
    ev_end

    # Assert the labels BEFORE the confined clients below depend on them, so a
    # regression names its cause here instead of surfacing as an unexplained
    # connect(2) failure inside a client three tests later.
    log pd "desktop-selinux labeled every client-facing directory container_file_t"
    systemctl is-active --quiet desktop-selinux.service \
        || fail "desktop-selinux.service did not run"
    for d in /tmp/.X11-unix /run/desktop-audio /var/lib/desktop-container/bin; do
        ctx=$(ls -Zd "$d" | awk '{print $1}')
        case "$ctx" in
            *:container_file_t:*) log pd "  $d -> $ctx" ;;
            *) fail "$d is $ctx, want container_file_t (confined clients cannot reach it)" ;;
        esac
    done
    # The published binaries too, not just the directory that holds them:
    # clients EXECUTE these, and desktop-tools-cdi relabels after the desktop
    # publishes precisely so this holds.
    ctx=$(ls -Z /var/lib/desktop-container/bin/screenshot | awk '{print $1}')
    case "$ctx" in
        *:container_file_t:*) log pd "  published screenshot binary -> $ctx" ;;
        *) fail "published toolkit binary is $ctx, want container_file_t" ;;
    esac


    # THE HOST IS A FIRST-CLASS CLIENT TOO. Everything below this comment
    # tests containers; the host must render to the display, play audio and
    # run the published tools just as well, and the container_file_t relabel
    # is the thing most likely to take that away: a host process is
    # unconfined_t, and it now has to execute a file and connect to a socket
    # that both carry a CONTAINER type. Host audio is asserted above (pactl
    # over the exported socket); these two cover the other two capabilities.
    #
    # Split deliberately into exec and connect. Run as one command, a denial
    # on either would look identical, and they have different fixes: exec is
    # about the toolkit dir's label, connect is about the socket dir's.
    #
    # The screenshot binary is the right probe because it is static
    # (CGO_ENABLED=0) - the host needs no X client stack installed to run it,
    # which is also why this VM has none.
    log pd "HOST tools: the published binary is executable by an unconfined host process"
    TOOLKIT=/var/lib/desktop-container/bin
    "$TOOLKIT/screenshot" --help >/dev/null \
        || fail "host cannot EXECUTE $TOOLKIT/screenshot - container_file_t not executable by unconfined_t?"

    log pd "HOST display: that binary captures the live desktop from the host"
    ev_begin S3.2.6 "The X socket is shared through the host directory" T3
    ev_save x11-unix "EV-STATE: ls -l /tmp/.X11-unix on the host: Xorg's X0 socket, created inside the container, is here" \
        ls -l /tmp/.X11-unix >/dev/null || true
    [ -S /tmp/.X11-unix/X0 ] || fail "no X0 socket in the host's /tmp/.X11-unix"
    ev_pass "the host's /tmp/.X11-unix/X0 is a socket"
    hostshot=/tmp/host-toolkit-shot.png
    rm -f "$hostshot"
    DISPLAY=:0 "$TOOLKIT/screenshot" "$hostshot" \
        || fail "host could not capture :0 with the published binary - denied on the X socket?"
    [ -s "$hostshot" ] || fail "host screenshot produced an empty file"
    # PNG magic, so a truncated or half-written file cannot pass as success.
    head -c8 "$hostshot" | od -An -tx1 | tr -d ' \n' | grep -qi '^89504e470d0a1a0a' \
        || fail "host screenshot is not a PNG"
    log pd "  host captured $(stat -c%s "$hostshot") bytes with no X client stack installed"
    ev_copy "$hostshot" host-capture "EV-SHOT-CLIENT (host variant): the desktop as the published screenshot binary captured it from the host, over /tmp/.X11-unix/X0"
    ev_pass "the published screenshot binary, run on the host, captured :0 ($(stat -c%s "$hostshot") bytes, a PNG)"
    ev_end

    ev_begin S5.6.7 "The host keeps full access after relabeling" T3
    ev_save toolkit-exec "EV-STATE: the relabeled (container_file_t) screenshot binary executed by an unconfined host process: its --help, exit 0" \
        "$TOOLKIT/screenshot" --help >/dev/null \
        || fail "host cannot EXECUTE $TOOLKIT/screenshot - container_file_t not executable by unconfined_t?"
    ev_pass "an unconfined host process executes the relabeled toolkit binary"
    ev_copy "$hostshot" host-capture "EV-SHOT-CLIENT (host variant): the host's capture of :0 through the relabeled X socket (the same capture S3.2.6 keeps)"
    ev_pass "an unconfined host process connects to the relabeled X socket (it captured :0)"
    ev_save pactl-info "EV-STATE: pactl info from the host over the relabeled pulse socket" \
        env PULSE_SERVER=unix:/run/desktop-audio/pulse pactl info >/dev/null \
        || fail "the host cannot connect to the relabeled pulse socket"
    ev_pass "an unconfined host process connects to the relabeled pulse socket"
    avc=$(ev_save avc-since-host-checks "EV-STATE: ausearch -m avc -ts $ev_t0 - every SELinux denial since the host checks began; none" \
        sh -c "ausearch -m avc -ts $ev_t0 2>&1 || true") || true
    if grep -q 'type=AVC' <<<"$avc"; then
        fail "SELinux denied something while the host used the relabeled sockets and toolkit (see the ausearch output)"
    fi
    ev_pass "no SELinux denial since the host checks began"
    ev_end
    rm -f "$hostshot"

    # The whole client contract in one command, under podman: a SEPARATE
    # container that passes no -v and no -e reaches the display purely
    # because the runtime applied the spec's containerEdits. Same mechanism
    # k8s uses via the device plugin, minus kubernetes.
    #
    # Every podman flag on the three commands below, and why - including the
    # one that is deliberately NOT there:
    #
    #   --device desktop.local/<cap>=all   the point of the test: the ONLY
    #                                      thing granting access. No -v, no -e,
    #                                      so anything the client sees came
    #                                      from the CDI spec's containerEdits.
    #   --rm                               these are one-shot probes; leaving
    #                                      them behind would make the next
    #                                      phase's `podman ps` output lie.
    #   (no --security-opt label=disable)  LOAD-BEARING BY ITS ABSENCE. These
    #                                      run CONFINED under enforcing
    #                                      SELinux, which is what
    #                                      desktop-selinux.service labeling the
    #                                      export dirs container_file_t buys:
    #                                      without those labels each of these
    #                                      fails on connect(2) with the device
    #                                      resolved and the mounts in place.
    #                                      Adding the flag would make the test
    #                                      pass while proving nothing.
    #
    # The desktop container is exempt from SELinux separation
    # (SecurityLabelDisable=true in the quadlet - it is the trusted component,
    # and confining it needs a policy module of its own). Nothing downstream of
    # it is exempt, which is the asymmetry these commands exist to prove.
    log pd "a CONFINED podman client resolves desktop.local/display=all and opens :0"
    # S7.1.2 reads SELinux's denials from here on (ausearch -ts: a time of day).
    s712_t0=$(date +%H:%M:%S)
    ev_begin S7.1.1 "Each device grants only its own capability" T3
    # Every probe also prints its whole environment, the two mounts that
    # matter and its own SELinux label: what the device gave it, and proof
    # it ran confined (container_t), not as the desktop does.
    probe_tail='echo "-- env"; env | sort; echo "-- mounts"; grep -E " /tmp/.X11-unix | /run/desktop-audio " /proc/self/mountinfo || echo "(neither)"; echo "-- selinux label"; cat /proc/self/attr/current; echo'
    out=$(ev_save probe-display "EV-STATE: a confined client given only desktop.local/display=all: DISPLAY, the X socket, xdpyinfo working; no PULSE_SERVER and no audio mount; its label is container_t" \
        podman run --rm \
        --device desktop.local/display=all \
        localhost/desktop-container:latest sh -c '
            printenv DISPLAY
            test -S /tmp/.X11-unix/X0 && echo SOCKET_OK
            xdpyinfo >/dev/null && echo XDPYINFO_OK
            printenv PULSE_SERVER || echo NO_PULSE
            grep -q " /run/desktop-audio " /proc/self/mountinfo || echo NO_AUDIO_MOUNT
            '"$probe_tail") \
        || fail "podman display client failed (see output above)"
    for want in ':0' SOCKET_OK XDPYINFO_OK NO_PULSE NO_AUDIO_MOUNT; do
        echo "$out" | grep -qx "$want" \
            || fail "display client missing '$want' (got: $(echo "$out" | tr '\n' ' '))"
    done
    grep -q ':container_t:' <<<"$out" || fail "the display client did not run confined (no container_t label)"
    ev_pass "display alone: DISPLAY=:0, the X socket and a working xdpyinfo; no audio env or mount; confined"
    log pd "podman display client opened :0 and got NO audio - the split holds"

    # ...and the mirror image. An audio-only client must not be able to see
    # the display at all: with xhost +local: an X client can keylog the
    # whole session, which is precisely what a sound-only workload must not
    # be handed.
    log pd "a CONFINED podman client resolves desktop.local/audio=all and gets audio only"
    out=$(ev_save probe-audio "EV-STATE: a confined client given only desktop.local/audio=all: PULSE_SERVER, PIPEWIRE_REMOTE and the pulse socket; no DISPLAY and no X11 mount; its label is container_t" \
        podman run --rm \
        --device desktop.local/audio=all \
        localhost/desktop-container:latest sh -c '
            printenv PULSE_SERVER
            printenv PIPEWIRE_REMOTE
            test -S /run/desktop-audio/pulse && echo PULSE_SOCKET_OK
            printenv DISPLAY || echo NO_DISPLAY
            grep -q " /tmp/.X11-unix " /proc/self/mountinfo || echo NO_X11_MOUNT
            '"$probe_tail") \
        || fail "podman audio client failed (see output above)"
    for want in 'unix:/run/desktop-audio/pulse' '/run/desktop-audio/pipewire-0' \
                PULSE_SOCKET_OK NO_DISPLAY NO_X11_MOUNT; do
        echo "$out" | grep -qx "$want" \
            || fail "audio client missing '$want' (got: $(echo "$out" | tr '\n' ' '))"
    done
    grep -q ':container_t:' <<<"$out" || fail "the audio client did not run confined (no container_t label)"
    ev_pass "audio alone: both audio env vars and the pulse socket; no DISPLAY, no X11 mount; confined"
    log pd "podman audio client got the audio sockets and NO display"

    # Both together are the union: what a full desktop client asks for.
    out=$(ev_save probe-both "EV-STATE: a confined client given both devices: the union of their edits, xdpyinfo working" \
        podman run --rm \
        --device desktop.local/display=all --device desktop.local/audio=all \
        localhost/desktop-container:latest sh -c '
            test "$DISPLAY" = :0 && test -S /tmp/.X11-unix/X0 \
              && test -S /run/desktop-audio/pulse && xdpyinfo >/dev/null && echo UNION_OK
            '"$probe_tail") \
        || fail "requesting both devices did not yield the union of their edits"
    grep -qx UNION_OK <<<"$out" || fail "requesting both devices did not yield the union of their edits"
    ev_pass "both devices: the union (display and audio), xdpyinfo working"
    log pd "both devices together give display + audio"

    # ...and none: the control, so nothing above can have come from the
    # image itself.
    out=$(ev_save probe-none "EV-STATE: a container given no device: no DISPLAY, no audio env, neither mount (the control)" \
        podman run --rm localhost/desktop-container:latest sh -c '
            printenv DISPLAY || echo NO_DISPLAY
            printenv PULSE_SERVER || echo NO_PULSE
            grep -q " /tmp/.X11-unix " /proc/self/mountinfo || echo NO_X11_MOUNT
            grep -q " /run/desktop-audio " /proc/self/mountinfo || echo NO_AUDIO_MOUNT
            '"$probe_tail") \
        || fail "the no-device control container failed"
    for want in NO_DISPLAY NO_PULSE NO_X11_MOUNT NO_AUDIO_MOUNT; do
        grep -qx "$want" <<<"$out" || fail "a container with no device got something ('$want' missing)"
    done
    ev_pass "no device: nothing (no DISPLAY, no audio env, neither mount)"
    ev_end

    # S7.1.2's T3 half: those probes ran confined, under enforcing, and
    # SELinux denied them nothing. (Its static half is the static job's
    # ci/client-guard.py.)
    ev_begin S7.1.2 "Confined clients work under enforcing" T3
    ev_save getenforce "EV-STATE: getenforce on the VM host" getenforce >/dev/null || true
    [ "$(getenforce)" = Enforcing ] || fail "SELinux is $(getenforce) on the VM host, not Enforcing"
    ev_pass "SELinux is Enforcing on the VM host"
    lbl=$(ev_save probe-label "EV-STATE: a confined display client: its own SELinux label (/proc/self/attr/current), then xdpyinfo's verdict" \
        podman run --rm --device desktop.local/display=all localhost/desktop-container:latest \
        sh -c 'cat /proc/self/attr/current; echo; xdpyinfo >/dev/null && echo XDPYINFO_OK') || true
    grep -q ':container_t:' <<<"$lbl" || fail "the probe did not run as container_t: $(echo $lbl)"
    grep -q XDPYINFO_OK <<<"$lbl" || fail "the confined probe could not open :0"
    ev_pass "a client runs confined, as $(grep -o '[a-z_]*:[a-z_]*:container_t:[^[:space:]]*' <<<"$lbl" | sed -n 1p), and opens :0"
    avc=$(ev_save avc "EV-STATE: ausearch -m avc -ts $s712_t0: SELinux's denials since the probes began" \
        sh -c "ausearch -m avc -ts $s712_t0 2>&1 || true") || true
    ! grep -q 'scontext=[^ ]*:container_t:' <<<"$avc" \
        || fail "SELinux denied a confined client: $(grep -m1 'scontext=[^ ]*:container_t:' <<<"$avc")"
    ev_pass "no AVC denial since the probes began has a container_t subject"
    ev_end

    ev_begin S5.5.1 "Display and audio specs are disjoint, rw, directory mounts" T3
    ev_copy /etc/cdi/desktop-display.yaml display-spec "EV-CONFIG: /etc/cdi/desktop-display.yaml: DISPLAY and the /tmp/.X11-unix directory, rbind rw; nothing about audio"
    ev_copy /etc/cdi/desktop-audio.yaml audio-spec "EV-CONFIG: /etc/cdi/desktop-audio.yaml: both audio env vars and the /run/desktop-audio directory, rbind rw; nothing about the display"
    for f in probe-display probe-audio probe-both probe-none; do
        src=$(ls "$EV_ROOT/S7.1.1/"*"-$f.txt" 2>/dev/null | head -n1 || true)
        [ -z "$src" ] || ev_copy "$src" "$f" "EV-STATE: the $f client's env and mounts, as S7.1.1 ran it (copied here)"
    done
    grep -q 'kind: desktop.local/display' /etc/cdi/desktop-display.yaml || fail "display spec kind wrong"
    grep -q 'kind: desktop.local/audio' /etc/cdi/desktop-audio.yaml || fail "audio spec kind wrong"
    ev_pass "the two specs carry the kinds desktop.local/display and desktop.local/audio"
    if grep -qE 'PULSE_SERVER|PIPEWIRE_REMOTE|desktop-audio' /etc/cdi/desktop-display.yaml \
        || grep -qE 'DISPLAY=|X11-unix' /etc/cdi/desktop-audio.yaml; then
        fail "the specs are not disjoint: one carries the other's edits"
    fi
    ev_pass "disjoint: neither spec carries the other's env or mount"
    grep -q 'hostPath: /tmp/.X11-unix$' /etc/cdi/desktop-display.yaml \
        && grep -q 'hostPath: /run/desktop-audio$' /etc/cdi/desktop-audio.yaml \
        || fail "the specs do not mount the two directories"
    grep -q '"rbind", "rw"' /etc/cdi/desktop-display.yaml && grep -q '"rbind", "rw"' /etc/cdi/desktop-audio.yaml \
        || fail "the spec mounts are not rbind rw"
    ev_pass "each mounts its directory (not a socket file), rbind and rw"
    printf 'cdiVersion: 0.5.0\nkind: desktop.local/display\ndevices: []\n' > /etc/cdi/desktop.yaml
    ev_save legacy-spec "EV-STATE: desktop-client-cdi re-run with a superseded combined /etc/cdi/desktop.yaml in place: it removes it" \
        deploy/host/usr/local/libexec/desktop-client-cdi >/dev/null || fail "desktop-client-cdi failed when re-run"
    [ ! -e /etc/cdi/desktop.yaml ] || fail "the superseded combined spec survived a desktop-client-cdi run"
    ev_pass "the superseded combined spec is removed"
    ev_end

    # The fixed monitor layout follows as its own steps (layout-declare,
    # layout-roundtrip, layout-unplug, layout-restore), which vm-e2e.sh runs
    # one by one so it can look at the display between them; then
    # deploy-proof puts a window up for its screendump.
    log pd "phase-deploy passed"
}

deploy_proof() {
    log pd "spawn an xterm so the screendump shows a window"
    podman exec -d -u desktop -e DISPLAY=:0 -e HOME=/home/desktop desktop \
        xterm -T deploy-proof -geometry 80x24+80+80
    sleep 3
}

# --- fixed monitor layout ------------------------------------------------------
# The KVM video case, as far as a VM can honestly carry it.
#
# What this DOES prove, and it is the load-bearing claim: an output declared in
# monitors.conf comes up at its declared mode and position on a connector the
# driver reports as NOT CONNECTED, with the framebuffer pinned to the full
# declared size. The VM gets that connector for free - QEMU enables virtio
# scanout 0 only, and virtio-gpu reports connector status straight from the
# scanout's enabled bit, so Virtual-2 is disconnected from boot to shutdown
# (see the -device line in vm-e2e.sh). "Monitor was never there" is a strict
# superset of the hard part of "monitor went away".
#
# It also proves the live behaviour: a connector going down under a running X
# does not move the geometry.
#
# What it does NOT prove, and what "try it on real hardware early" in README.md
# is still there for:
#   - the physical layer. No EDID re-read, no link retraining, no sink that
#     takes a moment to come back. virtio has no DDC to model.
#   - a switch-away that is not a connector event at all. Some KVMs drop the
#     link without the sink ever going down, so nothing here is notified and
#     nothing reprobes; the static config is what covers that, and it is the
#     half this VM cannot stage.
#
# One thing this DOES reach, contrary to what the comment here first claimed:
# the sysfs connector force below is delivered to Xorg as an event. The run
# logs "X noticed on its own" - X had re-probed within three seconds, before
# anything asked it to. So the notification path is exercised, not stubbed.
# The explicit query afterwards stays anyway: it costs nothing and it makes
# the assertion independent of that timing rather than resting on it. Whether
# X noticed is logged as evidence, never asserted.
#
# Restores the shipped (empty) monitors.conf and the connector's forced status
# before returning, so nothing downstream - the screendumps, the testpattern
# comparison, phase2's client pods - sees a display this function set up.
dpy_dims() {
    podman exec -u desktop -e DISPLAY=:0 desktop \
        sh -c "xdpyinfo | awk '/dimensions:/{print \$2; exit}'"
}

xr() {
    podman exec -u desktop -e DISPLAY=:0 desktop xrandr --query
}

# One output's line from xrandr --query.
#
# NEVER `xr | grep -q` or `xr | grep -m1` here. This script runs under
# `set -o pipefail`, and those greps stop reading at the first match: the
# writer - a podman exec with the rest of the query still to send - takes
# SIGPIPE and exits 141, which pipefail reports as the whole pipeline
# failing. The match succeeded and the check says it failed. Worse, it is
# timing-dependent on WHERE the match is: it fires on the first output in the
# list, where most of the output is still unread, and usually not on the last.
# So capture the query whole and match against the variable.
xr_line() {
    local all
    all=$(xr) || return 1
    grep -m1 "^$1 " <<<"$all"
}

# Asserted by CONTENT rather than by field position: "primary" sits between
# the connection state and the geometry on the primary output only, and
# matching positionally silently expects one shape of line and fails on the
# other. Same containment test the watcher itself uses.
#   xr_is <output> <connected|disconnected> [geometry]
# With no geometry, asserts the output carries none - i.e. it is not enabled.
xr_is() {
    local want_out=$1 want_state=$2 want_geom=${3:-} line
    line=$(xr_line "$want_out") || return 1
    case "$line" in
        "$want_out $want_state "*) ;;
        *) return 1 ;;
    esac
    if [ -z "$want_geom" ]; then
        case "$line" in
            *\ [0-9]*x[0-9]*+[0-9]*+[0-9]*\ *) return 1 ;;
            *) return 0 ;;
        esac
    fi
    case " $line " in
        *" $want_geom "*) return 0 ;;
        *) return 1 ;;
    esac
}

# After a restart: container running AND X actually answering. Waiting on the
# socket FILE would not do - /tmp/.X11-unix is a host bind mount that survives
# the container, so a stale node from the instance just stopped can satisfy a
# test -S immediately and hand the next check a dead socket.
desktop_up() {
    wait_for 40 3 "desktop-init ready in container" container_running
    wait_for 60 4 "X answering on :0" \
        podman exec -u desktop -e DISPLAY=:0 desktop xdpyinfo
}

conn_connected() { [ "$(cat "$1/status")" = connected ]; }

# The two connectors' sysfs directories, into conn and conn2.
layout_connectors() {
    conn=$(ls -d /sys/class/drm/card*-Virtual-1 2>/dev/null | head -n1)
    conn2=$(ls -d /sys/class/drm/card*-Virtual-2 2>/dev/null | head -n1)
    [ -n "$conn" ] || fail "no Virtual-1 DRM connector: the virtio GPU is not what this expects"
    [ -n "$conn2" ] || fail "no Virtual-2 connector: vm-e2e.sh must boot virtio-vga with max_outputs=2"
}

# F3.10's common set, less the video (the host records that): the connectors'
# sysfs status, xrandr --verbose and the window tree, kept under
# $LAYOUT_TMP/<moment>-*.txt - what the checks read, with evidence on or off
# - and copied into the open story.
LAYOUT_TMP=/run/ev-layout
xrv() { podman exec -u desktop -e DISPLAY=:0 desktop xrandr --query --verbose; }
xtree() { podman exec -u desktop -e DISPLAY=:0 desktop xwininfo -root -tree; }
layout_set() { # <moment> <when>
    mkdir -p "$LAYOUT_TMP"
    sh -c 'grep -H . /sys/class/drm/card*-*/status' > "$LAYOUT_TMP/$1-sysfs.txt" 2>&1 || true
    xrv > "$LAYOUT_TMP/$1-xrandr.txt" 2>&1 || true
    xtree > "$LAYOUT_TMP/$1-tree.txt" 2>&1 || true
    layout_copy "$1" "$2"
}
# A layout_set's files (this story's or an earlier one's) into the open story.
layout_copy() { # <moment> <when>
    ev_copy "$LAYOUT_TMP/$1-sysfs.txt" "$1-sysfs" "EV-STATE: every DRM connector's status in sysfs (grep -H . .../status), $2"
    ev_copy "$LAYOUT_TMP/$1-xrandr.txt" "$1-xrandr" "EV-STATE: xrandr --query --verbose, $2"
    ev_copy "$LAYOUT_TMP/$1-tree.txt" "$1-tree" "EV-STATE: xwininfo -root -tree, $2"
}
# EV-DIFF of two files anywhere (ev_diff takes names inside the story).
ev_diff_paths() { # <moment> <what> <path a> <path b>
    [ -n "$EV_DIR" ] || return 0
    local name
    name=$(ev_name "$1" diff)
    diff -u "$3" "$4" > "$EV_DIR/$name" || true
    [ -s "$EV_DIR/$name" ] || echo "(no differences between $3 and $4)" > "$EV_DIR/$name"
    ev_attach "$name" "$2"
}
# The client windows in a saved xwininfo -root -tree (the ones with a
# WM_CLASS), each with its id, size and absolute position: what "no window
# moved" compares.
client_windows() { grep -E '^ +0x[0-9a-f]+ "[^"]*": \("' "$1" | sed 's/^ *//' | sort; }

# --- S7.7.3: a client's window across the declared layout's unplug ---------
# A podman client's xterm on Virtual-1's half, below the session's xterm,
# started before Virtual-1 is forced off: its window's xwininfo and the
# client's own screenshot before, while Virtual-1 is off, and after the
# re-plug, then its container before and after. Only where evidence is kept
# (the core shard); the host then compares the three screenshots.
S773=op-s773 S773_ON="" S773_WIN=""
s773_win() { local t; t=$(xtree) || return 1; awk '/\("s773app" "XTerm"\)/ {print $1; exit}' <<<"$t"; }
# The client's own capture, PNG on stdout. CDI gave the client DISPLAY and
# DESKTOP_TOOLS_BIN, which a podman exec does not see: they are read from
# its main process.
s773_shot() {
    podman exec "$S773" sh -c 'eval "$(tr "\0" "\n" < /proc/1/environ | grep -E "^(DISPLAY|DESKTOP_TOOLS_BIN)=" | sed "s/^/export /")"; exec "${DESKTOP_TOOLS_BIN:-/usr/libexec/desktop-tools}"/screenshot --to-stdout'
}
s773_open() { ev_begin S7.7.3 "Client windows stay put across a monitor plug-out and re-plug (layout declared)" T3; }
s773_moment() { # <moment: before|during|after> <when>
    [ -n "$S773_ON" ] || return 0
    local name
    s773_open
    ev_save "xwininfo-$1" "EV-STATE: xwininfo -id $S773_WIN, the client's window, $2" \
        podman exec -u desktop -e DISPLAY=:0 desktop xwininfo -id "$S773_WIN" >/dev/null || true
    case "$1" in
        before) S773_INFO_before=$EV_LAST ;;
        during) S773_INFO_during=$EV_LAST ;;
        after) S773_INFO_after=$EV_LAST ;;
    esac
    name=$(ev_name "client-view-$1" png)
    s773_shot > "$EV_DIR/$name" 2>/dev/null || true
    if [ -s "$EV_DIR/$name" ]; then
        ev_attach "$name" "EV-SHOT-CLIENT: the display as the client captures it from inside its own container (the toolkit's screenshot), $2"
    else
        rm -f "${EV_DIR:?}/${name:?}"
        ev_note "the client's own screenshot ($1) was not produced"
    fi
    ev_end
}
s773_before() {
    [ -n "${EV_ROOT:-}" ] || return 0
    podman rm -f "$S773" >/dev/null 2>&1 || true
    podman run -d --name "$S773" --device desktop.local/display=all --device desktop.local/tools=all \
        localhost/desktop-container:latest \
        xterm -name s773app -T s773app -xrm 'XTerm*allowTitleOps: false' -geometry 40x6+300+510 >/dev/null \
        || fail "S7.7.3's client container did not start"
    wait_for 30 1 "S7.7.3's client window on the display" win_up s773app
    S773_WIN=$(s773_win)
    [ -n "$S773_WIN" ] || fail "S7.7.3's client window is not in the window tree"
    S773_ON=1
    s773_open
    ev_note "the client: podman run --device desktop.local/display=all --device desktop.local/tools=all localhost/desktop-container:latest xterm -name s773app, its window $S773_WIN"
    ev_save client-before "EV-PIDS: the client container before Virtual-1 is forced off: its id, its main process's host pid, restart count and start time" \
        podman inspect --format '{{.Id}} pid={{.State.Pid}} restarts={{.RestartCount}} started={{.State.StartedAt}}' "$S773" >/dev/null || true
    S773_CB=$EV_LAST
    ev_save daemons-before "EV-PIDS: Xorg, mwm and the three audio daemons before Virtual-1 is forced off" \
        ctr_pids Xorg,mwm,pipewire,wireplumber,pipewire-pulse >/dev/null || true
    S773_DB=$EV_LAST
    ev_end
    s773_moment before "with the declared layout live, before Virtual-1 is forced off"
}
s773_after() {
    [ -n "$S773_ON" ] || return 0
    local cb ca db da
    s773_moment after "after Virtual-1 was set back to detect and reads connected"
    s773_open
    ev_save client-after "EV-PIDS: the client container after the re-plug" \
        podman inspect --format '{{.Id}} pid={{.State.Pid}} restarts={{.RestartCount}} started={{.State.StartedAt}}' "$S773" >/dev/null || true
    ev_diff client "EV-DIFF: the client container before and after (no differences: the same container and process, never restarted)" "$S773_CB" "$EV_LAST"
    cb=$(sed '1d;$d' "$EV_DIR/$S773_CB") ca=$(sed '1d;$d' "$EV_DIR/$EV_LAST")
    ev_save daemons-after "EV-PIDS: Xorg, mwm and the three audio daemons after the re-plug" \
        ctr_pids Xorg,mwm,pipewire,wireplumber,pipewire-pulse >/dev/null || true
    ev_diff daemons "EV-DIFF: Xorg, mwm and the audio daemons across the unplug and re-plug (no differences)" "$S773_DB" "$EV_LAST"
    db=$(sed '1d;$d' "$EV_DIR/$S773_DB") da=$(sed '1d;$d' "$EV_DIR/$EV_LAST")
    ev_save client-log "EV-LOG-CLIENT: the client container's own output (podman logs)" podman logs "$S773" >/dev/null || true
    ev_diff geometry-during "EV-DIFF: xwininfo of the client's window before the force and while Virtual-1 was off (no differences: it did not move or resize)" "$S773_INFO_before" "$S773_INFO_during"
    ev_diff geometry-after "EV-DIFF: xwininfo of the client's window before the force and after the re-plug (no differences)" "$S773_INFO_before" "$S773_INFO_after"
    [ "$(sed '1d;$d' "$EV_DIR/$S773_INFO_before")" = "$(sed '1d;$d' "$EV_DIR/$S773_INFO_during")" ] \
        || fail "the client's window changed while Virtual-1 was forced off (see the geometry-during diff)"
    [ "$(sed '1d;$d' "$EV_DIR/$S773_INFO_before")" = "$(sed '1d;$d' "$EV_DIR/$S773_INFO_after")" ] \
        || fail "the client's window changed across the re-plug (see the geometry-after diff)"
    ev_pass "the client's window, $S773_WIN, had the same xwininfo before, while Virtual-1 was off and after the re-plug: $(sed -n 's/^ *-geometry //p' "$EV_DIR/$S773_INFO_before" | sed -n 1p)"
    [ -n "$cb" ] && [ "$cb" = "$ca" ] && grep -q ' restarts=0 ' <<<"$ca" \
        || fail "the client container changed or restarted: '$cb' -> '$ca'"
    ev_pass "the same container and process before and after, restarts 0: $(awk '{print $2}' <<<"$ca")"
    [ -n "$db" ] && [ "$db" = "$da" ] || fail "Xorg, mwm or an audio daemon changed across the unplug and re-plug"
    ev_pass "Xorg, mwm and the three audio daemons kept their pids and start times"
    ev_end
}
# The client goes only once layout_unplug is done: S3.10.4 takes S3.10.3's
# snapshot as its "before", so the window must still be there for its
# "after" (run 37352221011 removed it in between, and S3.10.4 failed).
s773_cleanup() {
    [ -n "$S773_ON" ] || return 0
    podman rm -f "$S773" >/dev/null 2>&1 || true
    S773_ON=""
}

layout_declare() {
    local dims out before pf

    log pd "fixed monitor layout: the VM has a second connector, and it is disconnected"
    layout_connectors
    [ "$(cat "$conn/status")" = connected ] \
        || fail "Virtual-1 is not connected; nothing below would mean anything"
    [ "$(cat "$conn2/status")" = disconnected ] \
        || fail "Virtual-2 is connected - QEMU enabled a second scanout, so the hole this test needs is gone"

    # 1024x768 for both, and the reason is a virtio quirk rather than anything
    # about this feature. A mode Xorg marks preferred - which Option
    # "PreferredMode" does, and M_T_PREFERRED is bit-identical to
    # DRM_MODE_TYPE_PREFERRED - has to survive virtio_gpu_conn_mode_valid:
    #
    #     if (!(mode->type & DRM_MODE_TYPE_PREFERRED))       return MODE_OK;
    #     if (mode->hdisplay == XRES_DEF &&
    #         mode->vdisplay == YRES_DEF)                    return MODE_OK;
    #     if (mode->hdisplay <= width  && mode->hdisplay >= width  - 16 &&
    #         mode->vdisplay <= height && mode->vdisplay >= height - 16)
    #                                                        return MODE_OK;
    #     return MODE_BAD;
    #
    # XRES_DEF x YRES_DEF is 1024x768, and that second line is unconditional -
    # it does not consult the scanout's size at all. Which is what this test
    # needs, because Virtual-2's scanout was never enabled and so HAS no size:
    # the width/height check could never pass for it. Any other resolution
    # would fail here on the quirk and say nothing about the feature.
    #
    # Note what is deliberately NOT assumed: the size QEMU boots this display
    # at. That is a device property (xres/yres, 1280x800 on current QEMU), it
    # has no bearing on the rule above, and the restore check at the end
    # compares against whatever it actually is.
    before=$(dpy_dims)
    echo "$before" > /run/ev-layout-before-dims
    log pd "fixed monitor layout: declare both connectors side by side (display is $before)"
    cat > /etc/desktop-container/monitors.conf <<'EOF'
Virtual-1  1024x768@60  +0+0      primary
Virtual-2  1024x768@60  +1024+0
EOF
    systemctl restart desktop.service
    desktop_up

    ev_begin S3.4.9 "A declared output comes up on a disconnected connector" T3
    ev_copy /etc/desktop-container/monitors.conf monitors-conf "EV-CONFIG: the declared monitors.conf: Virtual-1 primary at +0+0, Virtual-2 at +1024+0, both 1024x768@60"
    log pd "fixed monitor layout: the generator wrote the modesetting config"
    out=$(ev_save generated "EV-CONFIG: the 30-monitors.conf the generator wrote from it" \
        podman exec desktop cat /etc/X11/xorg.conf.d/30-monitors.conf 2>/dev/null || true)
    if [ -z "$out" ]; then
        podman logs desktop 2>&1 | grep xorg-monitor-conf >&2 || true
        fail "the declared layout generated no /etc/X11/xorg.conf.d/30-monitors.conf"
    fi
    echo "$out" | grep -q 'Option      "Enable" "true"' \
        || fail "outputs were not forced enabled"
    echo "$out" | grep -q 'Modeline "1024x768_60.00"' \
        || fail "no derived timing for the declared mode"
    echo "$out" | grep -q 'Virtual 2048 768' \
        || fail "framebuffer not pinned to the declared extents"
    ev_pass "the generated config forces both outputs enabled, carries a derived 1024x768_60.00 Modeline and pins the framebuffer at 2048x768"
    ev_save sysfs "EV-STATE: every DRM connector's status in sysfs: Virtual-2 is disconnected" \
        sh -c 'grep -H . /sys/class/drm/card*-*/status' >/dev/null || true
    ev_save xrandr "EV-STATE: xrandr --query with the declared layout live" xr >/dev/null || true

    # THE ASSERTION THIS WHOLE ARRANGEMENT EXISTS FOR.
    log pd "fixed monitor layout: X came up at the full declared size"
    dims=$(dpy_dims)
    [ "$dims" = 2048x768 ] \
        || fail "screen is $dims, want 2048x768 - the declared layout did not take"
    ev_pass "X came up at the declared 2048x768"

    log pd "fixed monitor layout: the DISCONNECTED output is enabled, where it was declared"
    xr_is Virtual-1 connected 1024x768+0+0 \
        || fail "Virtual-1 not where it was declared: $(xr_line Virtual-1)"
    case "$(xr_line Virtual-1)" in
        "Virtual-1 connected primary "*) ;;
        *) fail "Virtual-1 was declared primary but is not: $(xr_line Virtual-1)" ;;
    esac
    ev_pass "Virtual-1 is connected, primary, at 1024x768+0+0"
    # One line, and it is the whole point: xrandr says "disconnected" and
    # prints a geometry anyway, because Option "Enable" plus a derived Modeline
    # gave the server a mode it never had to ask a monitor for.
    xr_is Virtual-2 disconnected 1024x768+1024+0 \
        || fail "Virtual-2 is not enabled on a disconnected connector: $(xr_line Virtual-2)"
    ev_pass "Virtual-2 reads disconnected and scans out 1024x768+1024+0 with nothing plugged into it"
    log pd "  Virtual-2 scans out 1024x768+1024+0 with nothing plugged into it"
    ev_end

    # S3.4.11's T3 half: names that exist pass the preflight.
    ev_begin S3.4.11 "Preflight warns about unknown output names" T3
    pf=$(podman logs desktop 2>&1 | tr -d '\r' | grep '^preflight: .*monitor layout' | tail -n1 || true)
    ev_text preflight "EV-LOG-DESKTOP: the container preflight's monitor-layout line, Virtual-1 and Virtual-2 declared" "${pf:-(none)}"
    ev_save drm "EV-STATE: ls /sys/class/drm: the connectors the declared names are matched against" ls /sys/class/drm >/dev/null || true
    [ "$pf" = "preflight: PASS: fixed monitor layout declares Virtual-1 Virtual-2, all present as DRM connectors" ] \
        || fail "the preflight did not pass the declared names: ${pf:-no monitor-layout line}"
    ev_pass "the preflight passes the declared names: $pf"
    ev_end
}

layout_roundtrip() {
    local dims cap lines xr_declared
    # S3.4.12 on the live layout: the capture tool reads it back as a
    # monitors.conf block, and that block, applied, gives the same geometry.
    log pd "fixed monitor layout: desktop-monitors-capture reads the live layout back"
    ev_begin S3.4.12 "desktop-monitors-capture prints a valid, round-trippable block" T3
    ev_save xrandr-declared "EV-STATE: xrandr --query with the declared two-output layout live" \
        xr >/dev/null || true
    xr_declared=$EV_LAST
    cap=$(ev_save capture "EV-STATE: desktop-monitors-capture on the host, the declared layout live: one line per enabled output" \
        desktop-monitors-capture) || fail "desktop-monitors-capture failed with the desktop up"
    lines=$(grep -v '^#' <<<"$cap" | grep . || true)
    [ "$(grep -c . <<<"$lines")" = 2 ] || fail "the capture printed $(grep -c . <<<"$lines") output line(s), want 2"
    grep -qE '^Virtual-1 +1024x768@[0-9.]+ +\+0\+0 primary$' <<<"$lines" \
        || fail "the capture's Virtual-1 line is not 1024x768 at +0+0, primary"
    grep -qE '^Virtual-2 +1024x768@[0-9.]+ +\+1024\+0$' <<<"$lines" \
        || fail "the capture's Virtual-2 line is not 1024x768 at +1024+0"
    ev_pass "the capture prints the two declared outputs: Virtual-1 primary at +0+0, Virtual-2 at +1024+0"
    ev_note "the refresh the capture reads back: $(grep -oE '@[0-9.]+' <<<"$lines" | sort -u | tr '\n' ' ')(declared @60; xrandr reports the derived mode's actual rate)"
    printf '%s\n' "$lines" > /etc/desktop-container/monitors.conf
    systemctl restart desktop.service
    desktop_up
    ev_save generated "EV-CONFIG: the 30-monitors.conf the generator wrote from the captured block" \
        podman exec desktop cat /etc/X11/xorg.conf.d/30-monitors.conf >/dev/null \
        || fail "the captured block generated no 30-monitors.conf"
    ev_save xrandr-roundtrip "EV-STATE: xrandr --query after applying the captured block" \
        xr >/dev/null || true
    ev_diff roundtrip "EV-DIFF: xrandr with the declared layout and with the captured block applied" \
        "$xr_declared" "$EV_LAST"
    dims=$(dpy_dims)
    [ "$dims" = 2048x768 ] || fail "the captured block gives a $dims screen, not the declared 2048x768"
    xr_is Virtual-1 connected 1024x768+0+0 || fail "round trip: Virtual-1 is not at 1024x768+0+0: $(xr_line Virtual-1)"
    xr_is Virtual-2 disconnected 1024x768+1024+0 || fail "round trip: Virtual-2 is not at 1024x768+1024+0: $(xr_line Virtual-2)"
    ev_pass "the captured block, applied, reproduces the geometry: 2048x768, Virtual-1 at +0+0, Virtual-2 at +1024+0"
    ev_end
}

layout_unplug() {
    local dims xl0 moved T=$LAYOUT_TMP
    layout_connectors
    # A connector going down UNDER a running X. The force is real: the kernel
    # reports this connector disconnected to every probe from here on. It
    # arrives without the uevent a physical unplug would carry, which is why
    # the probe is driven rather than waited for - see this section's header.
    #
    # S3.4.10 holds F3.10's common set (the host adds its video there);
    # S3.10.1, S3.10.2 and S3.10.3 each judge their own part of it.
    s773_before
    log pd "fixed monitor layout: a live disconnect does not move the geometry"
    ev_begin S3.4.10 "A live disconnect does not move the geometry" T3
    layout_set before "with the declared layout live, before Virtual-1 is forced off"
    xl0=$(xorg_log_lines 2>/dev/null || echo 0)
    echo off > "$conn/status"
    [ "$(cat "$conn/status")" = disconnected ] \
        || fail "forcing $conn off did not take (kernel without connector force?)"
    ev_note "$conn/status forced off at $(date -u +%Y-%m-%dT%H:%M:%S.%3NZ)"
    sleep 3
    case "$(xr_line Virtual-1)" in
        "Virtual-1 disconnected "*)
            log pd "  X noticed on its own - a uevent reached it" ;;
        *)
            log pd "  X has not re-probed yet; the query below forces one, as any client would" ;;
    esac
    # RRGetInfo -> xf86ProbeOutputModes: X re-reads the connector and sees it
    # disconnected. Nothing about the CRTC configuration may change.
    xr >/dev/null
    layout_set forced-off "after Virtual-1 was forced off under the running server"
    xorg_slice "$xl0" "$T/forced-off-xorg-log.txt"
    ev_copy "$T/forced-off-xorg-log.txt" xorg-log-off "EV-LOG-XORG: the Xorg log's lines since just before the force"
    ev_diff_paths xrandr-off "EV-DIFF: xrandr --verbose across the force" "$T/before-xrandr.txt" "$T/forced-off-xrandr.txt"
    ev_diff_paths tree-off "EV-DIFF: the window tree across the force (empty: no window changed)" "$T/before-tree.txt" "$T/forced-off-tree.txt"
    dims=$(dpy_dims)
    [ "$dims" = 2048x768 ] \
        || fail "screen collapsed to $dims when Virtual-1 went down - the layout did not hold"
    ev_pass "the screen stayed 2048x768 with Virtual-1 forced off"
    xr_is Virtual-1 disconnected 1024x768+0+0 \
        || fail "Virtual-1 lost its geometry on disconnect: $(xr_line Virtual-1)"
    xr_is Virtual-2 disconnected 1024x768+1024+0 \
        || fail "Virtual-2 moved when Virtual-1 went down: $(xr_line Virtual-2)"
    ev_pass "both outputs stayed where they were declared: Virtual-1 at 1024x768+0+0 (now disconnected), Virtual-2 at 1024x768+1024+0"
    [ -n "$(client_windows "$T/before-tree.txt")" ] || fail "the window tree before the force lists no client window to compare"
    moved=$(diff <(client_windows "$T/before-tree.txt") <(client_windows "$T/forced-off-tree.txt") || true)
    [ -z "$moved" ] || fail "a window changed when Virtual-1 went down: $(echo $moved)"
    ev_pass "no client window moved or resized: the same ids, sizes and positions before and after ($(client_windows "$T/before-tree.txt" | wc -l) windows)"
    log pd "  both outputs now disconnected, both still scanning out where they were declared"
    ev_end

    s773_moment during "while Virtual-1 is forced off"
    ev_begin S3.10.1 "Monitor plug-out with a declared layout holds the geometry" T3
    layout_copy before "before the force (taken in S3.4.10)"
    layout_copy forced-off "after Virtual-1 was forced off (taken in S3.4.10)"
    ev_copy "$T/forced-off-xorg-log.txt" xorg-log "EV-LOG-XORG: the Xorg log's lines since just before the force (taken in S3.4.10)"
    ev_diff_paths tree "EV-DIFF: the window tree across the force (empty: no window changed)" "$T/before-tree.txt" "$T/forced-off-tree.txt"
    ev_pass "the screen size held: 2048x768 before and after (asserted in S3.4.10)"
    ev_pass "every output's position held: Virtual-1 1024x768+0+0, Virtual-2 1024x768+1024+0 (asserted in S3.4.10)"
    ev_pass "every client window's id, size and position held (asserted in S3.4.10 on these two trees)"
    ev_end

    ev_begin S3.10.2 "Monitor plug-out is reported by RandR" T3
    layout_copy before "before the force (taken in S3.4.10)"
    layout_copy forced-off "after Virtual-1 was forced off (taken in S3.4.10)"
    grep -q 'card[0-9]*-Virtual-1/status:disconnected' "$T/forced-off-sysfs.txt" \
        || fail "sysfs does not read Virtual-1 disconnected after the force"
    ev_pass "the kernel reports Virtual-1 disconnected (sysfs)"
    xr_is Virtual-1 disconnected 1024x768+0+0 \
        || fail "RandR does not report Virtual-1 disconnected and still enabled: $(xr_line Virtual-1)"
    ev_pass "RandR reports it disconnected while it stays enabled: $(xr_line Virtual-1)"
    ev_end

    log pd "fixed monitor layout: re-plug Virtual-1 under the running server"
    ev_begin S3.10.3 "Monitor re-plug after plug-out restores connected status without moving anything" T3
    layout_copy before "before the force (taken in S3.4.10)"
    xl0=$(xorg_log_lines 2>/dev/null || echo 0)
    echo detect > "$conn/status"
    wait_for 10 1 "Virtual-1 connected again" conn_connected "$conn"
    ev_note "$conn/status set back to detect at $(date -u +%Y-%m-%dT%H:%M:%S.%3NZ)"
    replugged() { xr_is Virtual-1 connected 1024x768+0+0; }
    wait_for 10 1 "xrandr to report Virtual-1 connected at 1024x768+0+0 again" replugged
    layout_set replugged "after Virtual-1 was set back to detect"
    xorg_slice "$xl0" "$T/replugged-xorg-log.txt"
    ev_copy "$T/replugged-xorg-log.txt" xorg-log "EV-LOG-XORG: the Xorg log's lines since just before the re-plug"
    ev_diff_paths xrandr "EV-DIFF: xrandr --verbose before the force and after the re-plug" "$T/before-xrandr.txt" "$T/replugged-xrandr.txt"
    ev_diff_paths tree "EV-DIFF: the window tree before the force and after the re-plug (empty: no window changed)" "$T/before-tree.txt" "$T/replugged-tree.txt"
    grep -q 'card[0-9]*-Virtual-1/status:connected' "$T/replugged-sysfs.txt" \
        || fail "sysfs does not read Virtual-1 connected after the re-plug"
    ev_pass "RandR reports Virtual-1 connected at 1024x768+0+0 again: $(xr_line Virtual-1)"
    dims=$(dpy_dims)
    [ "$dims" = 2048x768 ] || fail "the screen is $dims after the re-plug, want 2048x768"
    xr_is Virtual-2 disconnected 1024x768+1024+0 \
        || fail "Virtual-2 moved across the re-plug: $(xr_line Virtual-2)"
    ev_pass "the screen is still 2048x768 and Virtual-2 still at 1024x768+1024+0"
    moved=$(diff <(client_windows "$T/before-tree.txt") <(client_windows "$T/replugged-tree.txt") || true)
    [ -z "$moved" ] || fail "a window changed across the unplug and re-plug: $(echo $moved)"
    ev_pass "no client window moved or resized across the unplug and re-plug"
    ev_end
    s773_after

    # The other direction, on the connector nothing is plugged into: a
    # monitor arriving where the layout already scans out. Only xrandr's word
    # for it may change.
    log pd "fixed monitor layout: force the empty connector on under the running server"
    ev_begin S3.10.4 "Monitor plug-in on an empty connector, layout declared" T3
    layout_copy replugged "before Virtual-2 is forced on (taken in S3.10.3)"
    xl0=$(xorg_log_lines 2>/dev/null || echo 0)
    echo on > "$conn2/status"
    wait_for 10 1 "sysfs to read Virtual-2 connected" conn_connected "$conn2"
    ev_note "$conn2/status forced on at $(date -u +%Y-%m-%dT%H:%M:%S.%3NZ)"
    v2_on() { xr_is Virtual-2 connected 1024x768+1024+0; }
    wait_for 10 1 "xrandr to report Virtual-2 connected at 1024x768+1024+0" v2_on
    layout_set v2-on "after Virtual-2 was forced on"
    xorg_slice "$xl0" "$T/v2-on-xorg-log.txt"
    ev_copy "$T/v2-on-xorg-log.txt" xorg-log "EV-LOG-XORG: the Xorg log's lines since just before Virtual-2 was forced on"
    ev_diff_paths xrandr "EV-DIFF: xrandr --verbose across Virtual-2's plug-in" "$T/replugged-xrandr.txt" "$T/v2-on-xrandr.txt"
    ev_diff_paths tree "EV-DIFF: the window tree across Virtual-2's plug-in (empty: no window changed)" "$T/replugged-tree.txt" "$T/v2-on-tree.txt"
    ev_pass "RandR reports Virtual-2 connected where the layout put it: $(xr_line Virtual-2)"
    dims=$(dpy_dims)
    [ "$dims" = 2048x768 ] || fail "the screen is $dims after Virtual-2 was forced on, want 2048x768"
    xr_is Virtual-1 connected 1024x768+0+0 \
        || fail "Virtual-1 changed when Virtual-2 was forced on: $(xr_line Virtual-1)"
    ev_pass "the screen is still 2048x768 and Virtual-1 still connected at 1024x768+0+0"
    moved=$(diff <(client_windows "$T/replugged-tree.txt") <(client_windows "$T/v2-on-tree.txt") || true)
    [ -z "$moved" ] || fail "a window changed when Virtual-2 was forced on: $(echo $moved)"
    ev_pass "no client window moved or resized"
    echo detect > "$conn2/status"
    ev_note "$conn2/status set back to detect at $(date -u +%Y-%m-%dT%H:%M:%S.%3NZ)"
    v2_off() { xr_is Virtual-2 disconnected 1024x768+1024+0; }
    wait_for 10 1 "xrandr to report Virtual-2 disconnected at 1024x768+1024+0 again" v2_off
    layout_set v2-detect "after Virtual-2 was set back to detect"
    ev_pass "set back to detect, Virtual-2 reads disconnected again, still at 1024x768+1024+0"
    ev_end
    s773_cleanup
}

layout_restore() {
    local dims before
    before=$(cat /run/ev-layout-before-dims 2>/dev/null || echo unknown)
    log pd "fixed monitor layout: restore the shipped (empty) config"
    ev_begin S3.4.12 "desktop-monitors-capture prints a valid, round-trippable block" T3
    systemctl stop desktop.service
    rc=0
    down=$(ev_save desktop-down "EV-STATE: desktop-monitors-capture with desktop.service stopped: exit 1 and the hint" \
        desktop-monitors-capture) || rc=$?
    [ "$rc" = 1 ] || fail "with the desktop stopped the capture exited $rc, want 1"
    grep -q 'is desktop.service running?' <<<"$down" || fail "with the desktop stopped the capture gave no hint"
    ev_pass "with desktop.service stopped the capture exits 1 with the hint"
    ev_end
    install -m644 deploy/host/etc/desktop-container/monitors.conf \
        /etc/desktop-container/monitors.conf
    systemctl restart desktop.service
    desktop_up
    # The shipped file is pure comments, so the feature must be OFF again: no
    # generated config, and a screen sized by autodetection alone. That is what
    # every other test in this suite - and every host that never opts in - gets,
    # so assert it rather than assume the restore worked.
    if podman exec desktop test -e /etc/X11/xorg.conf.d/30-monitors.conf; then
        fail "the shipped monitors.conf still generated a layout - it is not a no-op"
    fi
    xr_is Virtual-2 disconnected \
        || fail "Virtual-2 is still enabled after the layout was withdrawn: $(xr_line Virtual-2)"
    dims=$(dpy_dims)
    # Not an equality against $before: setting a scanout can leave QEMU
    # reporting the new size as that display's geometry, so autodetection may
    # legitimately settle somewhere other than where it started. What must be
    # true is that the declared layout is gone - one output, not two.
    [ "$dims" != 2048x768 ] \
        || fail "the screen is still the declared two-monitor size after the layout was withdrawn"
    log pd "fixed monitor layout: back to autodetection at $dims (was $before on entry)"
    ev_begin S3.4.1 "Opt-in: absent or output-less config generates nothing" T3
    ev_copy /etc/desktop-container/monitors.conf shipped-monitors "EV-CONFIG: the shipped monitors.conf, restored after the fixed-layout test: comments only"
    ev_save xorg-conf-d "EV-STATE: ls /etc/X11/xorg.conf.d in the container after the restore: no 30-monitors.conf" \
        podman exec desktop ls -l /etc/X11/xorg.conf.d >/dev/null || true
    ev_pass "after the restore the container has no 30-monitors.conf (asserted above)"
    noop=$(podman logs desktop 2>/dev/null | tr -d '\r' | grep '^xorg-monitor-conf: ' || true)
    ev_text generator-log "EV-LOG-DESKTOP: the generator's lines in the desktop's log at this start" "${noop:-(none)}"
    grep -q 'no fixed layout' <<<"$noop" || fail "the generator did not log its no-op after the restore"
    ev_pass "the generator logged its no-op"
    ev_save xrandr "EV-STATE: xrandr --query after the restore: Virtual-2 disconnected, the screen sized by autodetection" \
        xr >/dev/null || true
    ev_pass "xrandr: Virtual-2 disconnected and the screen autodetected at $dims, not the declared 2048x768 (asserted above)"
    ev_end
}

# --- monitors under autodetection (S3.10.5-S3.10.7) -------------------------
# After layout_restore: no layout declared, Virtual-1 the only output. A
# monitor is plugged into Virtual-2 the way QEMU plugs one: the host asks
# QEMU's VNC server on head 1 for a size (vnc-head.py), virtio-gpu enables
# the head with an EDID of that size, or disables it for 0x0, and raises a
# display event, and the guest's driver reads every head's EDID and geometry
# again and reports a hotplug. The connector force cannot stand in for that
# here: a connector forced on gets virtio-gpu's own mode list and no EDID,
# with an EDID override or drm.edid_firmware set (S3.10.7 records it). Each
# story is several calls with the host's plug or unplug between them; what a
# later call compares against is kept in $AD_TMP.
AD_TMP=/run/ev-ad
AD7_EDID=$AD_TMP/edid.bin
ad_v2_connected_unused() { xr_is Virtual-2 connected; }
ad_v2_disconnected() { xr_is Virtual-2 disconnected; }
# An output's status and geometry, without the physical size after them: a
# display event makes virtio-gpu read every head's EDID again, which can give
# Virtual-1 back the size its EDID states without anything having moved.
xr_head() { xr_line "$1" | sed 's/ (.*//'; }
ad_keep() { # <tag>: the screen, Virtual-1 and the Xorg log's length now
    mkdir -p "$AD_TMP"
    printf 'dims=%s\nv1=%s\nxl0=%s\n' "$(dpy_dims)" "$(xr_head Virtual-1)" "$(xorg_log_lines 2>/dev/null || echo 0)" \
        > "$AD_TMP/$1"
}
ad_get() { sed -n "s/^$2=//p" "$AD_TMP/$1" 2>/dev/null; }   # <tag> <key>
ad_now() { date -u +%Y-%m-%dT%H:%M:%S.%3NZ; }
# The client windows of two snapshots, compared: empty when none moved.
ad_moved() { diff <(client_windows "$1") <(client_windows "$2") || true; }

ad_plugin() { # before|on|off: S3.10.5, around the host's plug and unplug
    local T=$LAYOUT_TMP dims0 v1 xl0 moved
    layout_connectors
    ev_begin S3.10.5 "Monitor plug-in without a layout is detected and does not reflow" T3
    case "${1:-}" in
        before)
            log pd "autodetection: QEMU plugs a monitor into Virtual-2, no layout declared"
            ad_v2_disconnected || fail "Virtual-2 is not disconnected and unused before the plug-in: $(xr_line Virtual-2)"
            layout_set ad5-before "under autodetection, before QEMU plugs a monitor into Virtual-2"
            ad_keep ad5
            ev_pass "under autodetection Virtual-2 reads disconnected and unused; the screen is $(dpy_dims) and $(xr_head Virtual-1)"
            ;;
        on)
            dims0=$(ad_get ad5 dims) v1=$(ad_get ad5 v1) xl0=$(ad_get ad5 xl0)
            wait_for 20 1 "sysfs to read Virtual-2 connected" conn_connected "$conn2"
            wait_for 20 1 "xrandr to report Virtual-2 connected" ad_v2_connected_unused
            ev_note "Virtual-2 read connected at $(ad_now), in sysfs and in xrandr"
            layout_set ad5-on "with the monitor QEMU plugged into Virtual-2"
            xorg_slice "${xl0:-0}" "$T/ad5-xorg-log.txt"
            ev_copy "$T/ad5-xorg-log.txt" xorg-log "EV-LOG-XORG: the Xorg log's lines since just before the plug-in"
            ev_diff_paths xrandr "EV-DIFF: xrandr --verbose across the plug-in" "$T/ad5-before-xrandr.txt" "$T/ad5-on-xrandr.txt"
            ev_diff_paths tree "EV-DIFF: the window tree across the plug-in (empty: no window changed)" "$T/ad5-before-tree.txt" "$T/ad5-on-tree.txt"
            ev_pass "sysfs reads Virtual-2 connected, and RandR lists it connected and not enabled: $(xr_line Virtual-2)"
            [ "$(dpy_dims)" = "$dims0" ] || fail "the screen changed from $dims0 to $(dpy_dims) when the monitor arrived"
            [ "$(xr_head Virtual-1)" = "$v1" ] || fail "Virtual-1 changed when the monitor arrived: '$v1' -> '$(xr_head Virtual-1)'"
            ev_pass "the screen stayed $dims0 and Virtual-1 is where it was: $v1"
            [ -n "$(client_windows "$T/ad5-before-tree.txt")" ] || fail "the window tree before the plug-in lists no client window to compare"
            moved=$(ad_moved "$T/ad5-before-tree.txt" "$T/ad5-on-tree.txt")
            [ -z "$moved" ] || fail "a window changed when the monitor arrived: $(echo $moved)"
            ev_pass "no client window moved or resized ($(client_windows "$T/ad5-before-tree.txt" | wc -l) windows)"
            ;;
        off)
            dims0=$(ad_get ad5 dims)
            wait_for 20 1 "xrandr to report Virtual-2 disconnected again" ad_v2_disconnected
            ev_note "Virtual-2 read disconnected again at $(ad_now)"
            layout_set ad5-off "after QEMU took the monitor away"
            [ "$(dpy_dims)" = "$dims0" ] || fail "the screen is $(dpy_dims) after the monitor left, not $dims0"
            ev_pass "with the monitor gone Virtual-2 reads disconnected and unused again, and the screen is still $dims0"
            ;;
        *) fail "autodetect plugin: before, on or off" ;;
    esac
    ev_end
}

ad_unplug() { # S3.10.6: the only enabled output forced off, then back
    local T=$LAYOUT_TMP dims0 xl0 x0 x1 pb
    layout_connectors
    log pd "autodetection: Virtual-1, the only enabled output, forced off"
    ev_begin S3.10.6 "Monitor plug-out without a layout is characterised" T3
    ev_save pids-before "EV-PIDS: desktop-init, Xorg and mwm before Virtual-1 is forced off" \
        ctr_pids desktop-init,Xorg,mwm >/dev/null || true
    pb=$EV_LAST
    x0=$(podman exec desktop pgrep -x Xorg 2>/dev/null | sed -n 1p || true)
    layout_set ad6-before "under autodetection, before Virtual-1, the only enabled output, is forced off"
    dims0=$(dpy_dims)
    xl0=$(xorg_log_lines 2>/dev/null || echo 0)
    echo off > "$conn/status"
    [ "$(cat "$conn/status")" = disconnected ] || fail "forcing $conn off did not take"
    ev_note "$conn/status forced off at $(ad_now)"
    sleep 3
    xr >/dev/null || true          # a query makes X probe, as any client's would
    layout_set ad6-off "with Virtual-1, the only enabled output, forced off"
    ev_diff_paths xrandr "EV-DIFF: xrandr --verbose across the only output's plug-out" "$T/ad6-before-xrandr.txt" "$T/ad6-off-xrandr.txt"
    ev_diff_paths tree "EV-DIFF: the window tree across the only output's plug-out" "$T/ad6-before-tree.txt" "$T/ad6-off-tree.txt"
    x1=$(podman exec desktop pgrep -x Xorg 2>/dev/null | sed -n 1p || true)
    [ -n "$x0" ] && [ "$x1" = "$x0" ] || fail "Xorg did not live through the only output's plug-out: $x0 -> ${x1:-none}"
    ev_pass "Xorg kept running through the only output's plug-out: the same pid ($x0)"
    podman exec -u desktop -e DISPLAY=:0 desktop xdpyinfo >/dev/null 2>&1 || fail "xdpyinfo did not answer with Virtual-1 forced off"
    ev_pass "xdpyinfo answers with Virtual-1 forced off"
    ev_note "what X reports with its only output forced off (the characterisation): $(xr_line Virtual-1); the screen is $(dpy_dims), as it was $dims0 before"
    echo detect > "$conn/status"
    wait_for 10 1 "Virtual-1 connected again in sysfs" conn_connected "$conn"
    ev_note "$conn/status set back to detect at $(ad_now)"
    v1_back() { case "$(xr_line Virtual-1)" in "Virtual-1 connected "*[0-9]x[0-9]*+*) return 0 ;; esac; return 1; }
    wait_for 10 1 "xrandr to report Virtual-1 connected and enabled again" v1_back
    layout_set ad6-detect "after Virtual-1 was set back to detect"
    xorg_slice "$xl0" "$T/ad6-xorg-log.txt"
    ev_copy "$T/ad6-xorg-log.txt" xorg-log "EV-LOG-XORG: the Xorg log's lines from just before the force to after the re-detect"
    ev_save pids-after "EV-PIDS: desktop-init, Xorg and mwm after Virtual-1 came back" \
        ctr_pids desktop-init,Xorg,mwm >/dev/null || true
    ev_diff pids "EV-DIFF: desktop-init, Xorg and mwm across the plug-out and back (no differences: none restarted)" "$pb" "$EV_LAST"
    [ "$(sed '1d;$d' "$EV_DIR/$pb")" = "$(sed '1d;$d' "$EV_DIR/$EV_LAST")" ] \
        || fail "desktop-init, Xorg or mwm changed across the plug-out and back (see the pids diff)"
    ev_pass "desktop-init, Xorg and mwm kept their pids and start times across the plug-out and back"
    [ "$(dpy_dims)" = "$dims0" ] || fail "the screen is $(dpy_dims) after Virtual-1 came back, not $dims0"
    ev_pass "set back to detect, Virtual-1 reads connected and the screen is $dims0, as before: $(xr_head Virtual-1)"
    ev_end
}

# An EDID for a 1024x768@60 monitor (S3.10.7): 1024x768@60 preferred, the
# size QEMU is asked to enable head 1 at, which a preferred mode must match
# for virtio-gpu to keep it; 640x480@60 and 800x600@60 established; no
# continuous-frequency flag, so the kernel infers no modes from the range
# limits. X adds none of its own either: its default modes only when the
# driver gives none, and modesetting's only on an output with a panel fitter
# (a "scaling mode" property), which virtio-gpu's connectors lack. Both list
# exactly these three.
write_edid() { # <file>
    python3 - "$1" <<'EOF'
import sys
e = bytearray(128)
e[0:8] = b"\x00\xff\xff\xff\xff\xff\xff\x00"
e[8:10] = ((20 << 10) | (19 << 5) | 20).to_bytes(2, "big")          # "TST"
e[10:12], e[12:16], e[16], e[17] = (1).to_bytes(2, "little"), (1).to_bytes(4, "little"), 1, 30
e[18], e[19], e[20], e[21], e[22], e[23], e[24] = 1, 3, 0x80, 34, 27, 120, 0x0a
e[25:35] = bytes([0xee, 0x91, 0xa3, 0x54, 0x4c, 0x99, 0x26, 0x0f, 0x50, 0x54])
e[35], e[36], e[37] = 0x21, 0x08, 0x00                                # 640x480@60 800x600@60 1024x768@60
e[38:54] = b"\x01\x01" * 8
clk, ha, hb, va, vb, hfp, hsw, vfp, vsw, hmm, vmm = 6500, 1024, 320, 768, 38, 24, 136, 3, 6, 340, 270
d = bytearray(18)
d[0:2] = clk.to_bytes(2, "little")
d[2], d[3], d[4] = ha & 0xff, hb & 0xff, ((ha >> 8) << 4) | (hb >> 8)
d[5], d[6], d[7] = va & 0xff, vb & 0xff, ((va >> 8) << 4) | (vb >> 8)
d[8], d[9], d[10] = hfp & 0xff, hsw & 0xff, ((vfp & 0xf) << 4) | (vsw & 0xf)
d[11] = ((hfp >> 8) << 6) | ((hsw >> 8) << 4) | ((vfp >> 4) << 2) | (vsw >> 4)
d[12], d[13], d[14], d[17] = hmm & 0xff, vmm & 0xff, ((hmm >> 8) << 4) | (vmm >> 8), 0x18
e[54:72] = d
e[72:90] = b"\x00\x00\x00\xfc\x00" + b"EV-TEST\n".ljust(13, b" ")
e[90:108] = b"\x00\x00\x00\xfd\x00" + bytes([50, 75, 30, 80, 8, 0x00, 0x0a]) + b" " * 6
e[108:126] = b"\x00\x00\x00\x10\x00" + bytes(13)
e[127] = (-sum(e[:127])) & 0xff
open(sys.argv[1], "wb").write(bytes(e))
EOF
}

ad_edid() { # prep|on|off|gone: S3.10.7, around the host's plug, shot and unplug
    local T=$LAYOUT_TMP dbg dims0 v1 xl0 v2modes kmodes unoffered v1cur kedid xedid want=640x480,800x600,1024x768
    layout_connectors
    dbg=$(ls -d /sys/kernel/debug/dri/*/Virtual-2 2>/dev/null | head -n1 || true)
    ev_begin S3.10.7 "A plugged-in monitor with an EDID exposes modes" T3
    case "${1:-}" in
        prep)
            log pd "autodetection: an EDID injected for Virtual-2, before QEMU plugs a monitor in there"
            ev_text edid-route "EV-STATE: how the EDID is injected: Virtual-2's DRM debugfs edid_override (the kernel then reads it in place of the monitor's own EDID), and whether the kernel has the other route, CONFIG_DRM_LOAD_EDID_FIRMWARE" \
                "debugfs connector directory: ${dbg:-none}
edid_override present: $([ -n "$dbg" ] && [ -e "$dbg/edid_override" ] && echo yes || echo no)
$(grep -h 'CONFIG_DRM_LOAD_EDID_FIRMWARE' "/boot/config-$(uname -r)" 2>/dev/null || echo "CONFIG_DRM_LOAD_EDID_FIRMWARE: not in /boot/config-$(uname -r)")"
            [ -n "$dbg" ] && [ -e "$dbg/edid_override" ] || fail "no DRM debugfs edid_override for Virtual-2 (is debugfs mounted?)"
            mkdir -p "$AD_TMP"
            write_edid "$AD7_EDID"
            ev_save edid-injected "EV-STATE: the EDID injected (od -An -tx1 -v): monitor EV-TEST, 1024x768@60 preferred, 640x480@60 and 800x600@60 established, no continuous-frequency flag" \
                od -An -tx1 -v "$AD7_EDID" >/dev/null || true
            cat "$AD7_EDID" > "$dbg/edid_override" || fail "the kernel refused the EDID as Virtual-2's override"
            ev_pass "the kernel took the EDID as Virtual-2's override"
            # What the connector force gives with the override set: recorded,
            # not asserted. It is why the monitor comes from QEMU instead.
            echo on > "$conn2/status"
            ev_note "with the override set and Virtual-2 forced on: sysfs reads $(cat "$conn2/status"), its EDID is $(wc -c < "$conn2/edid") bytes and it has $(sort -u "$conn2/modes" | wc -l) mode sizes, the largest $(sort -t x -k1,1nr "$conn2/modes" | sed -n 1p): virtio-gpu's own list, not the EDID's"
            echo detect > "$conn2/status"
            wait_for 10 1 "xrandr to report Virtual-2 disconnected and unused again" ad_v2_disconnected
            layout_set ad7-before "under autodetection, with the EDID injected, before QEMU plugs a monitor into Virtual-2"
            ad_keep ad7
            ev_pass "Virtual-2 reads disconnected and unused before the plug-in"
            ;;
        on)
            dims0=$(ad_get ad7 dims) v1=$(ad_get ad7 v1) xl0=$(ad_get ad7 xl0)
            wait_for 20 1 "sysfs to read Virtual-2 connected" conn_connected "$conn2"
            wait_for 20 1 "xrandr to report Virtual-2 connected" ad_v2_connected_unused
            ev_note "Virtual-2 read connected at $(ad_now), in sysfs and in xrandr"
            ev_save edid-kernel "EV-STATE: Virtual-2's EDID as the kernel reports it, its sysfs edid (od -An -tx1 -v)" \
                od -An -tx1 -v "$conn2/edid" >/dev/null || true
            kedid=$(od -An -tx1 -v "$conn2/edid" | tr -d ' \n')
            [ -n "$kedid" ] && [ "$kedid" = "$(od -An -tx1 -v "$AD7_EDID" | tr -d ' \n')" ] \
                || fail "Virtual-2's EDID in sysfs is not the injected one ($(( ${#kedid} / 2 )) bytes)"
            ev_pass "the kernel gives the plugged-in Virtual-2 the injected EDID, byte for byte ($(( ${#kedid} / 2 )) bytes)"
            ev_save modes-kernel "EV-STATE: the modes the kernel offers on Virtual-2, its sysfs modes" \
                cat "$conn2/modes" >/dev/null || true
            kmodes=$(sort -u "$conn2/modes" | sort -t x -k1,1n | paste -sd, -)
            [ "$kmodes" = "$want" ] || fail "the kernel offers Virtual-2 the modes ${kmodes:-none}, not the EDID's $want"
            ev_pass "the kernel offers Virtual-2 exactly the EDID's modes: $kmodes"
            layout_set ad7-on "with the monitor plugged into Virtual-2"
            # X's modes for Virtual-2 from the plain query. After its last
            # output xrandr prints every mode no output offers, and --verbose
            # prints those just as it prints an output's modes, so they read
            # as the last output's. The plain query prints an output's modes
            # three spaces in, and those two in, with their ids.
            xr > "$T/ad7-on-query.txt" 2>&1 || true
            ev_copy "$T/ad7-on-query.txt" ad7-on-query "EV-STATE: xrandr --query, with the monitor plugged into Virtual-2 (an output's modes three spaces in; after the last output, two in and with their ids, the modes no output offers)"
            v2modes=$(awk '/^Virtual-2 /{f = 1; next} /^[^ ]/{f = 0} f && /^   [0-9]+x[0-9]+i? / {print $1}' "$T/ad7-on-query.txt" \
                | sort -u | sort -t x -k1,1n | paste -sd, -)
            [ "$v2modes" = "$want" ] || fail "xrandr lists Virtual-2's modes as ${v2modes:-none}, not the EDID's $want"
            ev_pass "xrandr lists exactly the EDID's modes for Virtual-2: $v2modes"
            unoffered=$(awk '/^  [0-9]+x[0-9]+i? \(0x[0-9a-f]+\)/ {print $1 " " $2}' "$T/ad7-on-query.txt" | paste -sd, -)
            v1cur=$(awk '/^Virtual-1 / {for (i = 2; i <= NF; i++) if ($i ~ /^\(0x[0-9a-f]+\)$/) {print $i; exit}}' "$T/ad7-on-xrandr.txt")
            [ -z "$unoffered" ] || ev_note "after its last output xrandr lists the modes no output offers: $unoffered; Virtual-1 runs mode ${v1cur:-none}"
            xedid=$(awk '/^Virtual-2 /{f = 1; next} /^[A-Za-z]/{f = 0; e = 0} f && /^\tEDID:/ {e = 1; next}
                         e && /^\t\t[0-9a-f]+$/ {printf "%s", $1; next} {e = 0}' "$T/ad7-on-xrandr.txt")
            [ "$xedid" = "$kedid" ] || fail "X's EDID property for Virtual-2 is not the injected EDID ($(( ${#xedid} / 2 )) bytes)"
            ev_pass "X's EDID property for Virtual-2 is the injected EDID"
            desk xrandr --output Virtual-2 --auto || fail "xrandr --output Virtual-2 --auto failed"
            ev_note "xrandr --output Virtual-2 --auto at $(ad_now)"
            v2_enabled() { case "$(xr_line Virtual-2)" in "Virtual-2 connected "*1024x768+*) return 0 ;; esac; return 1; }
            wait_for 10 1 "Virtual-2 enabled at 1024x768" v2_enabled
            layout_set ad7-enabled "after xrandr --output Virtual-2 --auto"
            xorg_slice "${xl0:-0}" "$T/ad7-xorg-log.txt"
            ev_copy "$T/ad7-xorg-log.txt" xorg-log "EV-LOG-XORG: the Xorg log's lines since just before the plug-in"
            ev_diff_paths xrandr "EV-DIFF: xrandr --verbose from before the plug-in to Virtual-2 enabled" "$T/ad7-before-xrandr.txt" "$T/ad7-enabled-xrandr.txt"
            ev_diff_paths tree "EV-DIFF: the window tree from before the plug-in to Virtual-2 enabled (empty: no window changed)" "$T/ad7-before-tree.txt" "$T/ad7-enabled-tree.txt"
            ev_pass "xrandr --auto enabled Virtual-2 at the EDID's preferred mode: $(xr_line Virtual-2)"
            [ "$(xr_head Virtual-1)" = "$v1" ] || fail "Virtual-1 changed when Virtual-2 was enabled: '$v1' -> '$(xr_head Virtual-1)'"
            ev_pass "Virtual-1 is where it was: $v1 (the screen was $dims0 and is $(dpy_dims))"
            ;;
        off)
            desk xrandr --output Virtual-2 --off || fail "xrandr --output Virtual-2 --off failed"
            wait_for 10 1 "Virtual-2 connected and no longer enabled" ad_v2_connected_unused
            ev_pass "xrandr --output Virtual-2 --off turned it off: $(xr_line Virtual-2)"
            ;;
        gone)
            dims0=$(ad_get ad7 dims) v1=$(ad_get ad7 v1)
            wait_for 20 1 "xrandr to report Virtual-2 disconnected and unused" ad_v2_disconnected
            ev_note "Virtual-2 read disconnected again at $(ad_now)"
            # Exactly "reset", five bytes: with echo's newline the kernel reads
            # the write as an EDID, refuses it and keeps the override.
            printf reset > "$dbg/edid_override" || fail "the kernel did not reset Virtual-2's EDID override"
            ev_note "Virtual-2's EDID override reset at $(ad_now)"
            layout_set ad7-after "after QEMU took the monitor away and the override was reset"
            [ "$(dpy_dims)" = "$dims0" ] || fail "the screen is $(dpy_dims) after the monitor left, not $dims0"
            [ "$(xr_head Virtual-1)" = "$v1" ] || fail "Virtual-1 changed: '$v1' -> '$(xr_head Virtual-1)'"
            ev_pass "with the monitor gone Virtual-2 reads disconnected and unused, the screen is $dims0 and Virtual-1 where it was"
            ;;
        *) fail "autodetect edid: prep, on, off or gone" ;;
    esac
    ev_end
}
autodetect() { # plugin before|on|off, unplug, edid prep|on|off|gone
    case "${1:-}" in
        plugin) ad_plugin "${2:-}" ;;
        unplug) ad_unplug ;;
        edid) ad_edid "${2:-}" ;;
        *) fail "autodetect: plugin, unplug or edid" ;;
    esac
}
# The operator phase's layout switch (S3.11.2): "two" declares Virtual-1 and
# Virtual-2 side by side, as layout_declare does; "shipped" puts the
# shipped, comment-only file back. Either way the desktop restarts on it.
monitors_set() { # two|shipped
    case "${1:-}" in
        two) printf 'Virtual-1  1024x768@60  +0+0      primary\nVirtual-2  1024x768@60  +1024+0\n' \
                > /etc/desktop-container/monitors.conf ;;
        shipped) install -m644 deploy/host/etc/desktop-container/monitors.conf /etc/desktop-container/monitors.conf ;;
        *) fail "monitors-set: two or shipped" ;;
    esac
    systemctl restart desktop.service
    desktop_up
    x_up_wait() { session_up; }
    wait_for 40 2 "the new session's mwm" x_up_wait
}

# --- the deploy tree on the host (E5) -----------------------------------------
# Every desktop restart below waits for the same thing: X answering, then the
# session's mwm.
desk_back() { desktop_up; wait_for 40 2 "the session's mwm" session_up; }
desk_down() {
    systemctl stop desktop.service
    wait_for 30 1 "desktop.service to stop" sh -c '! systemctl is-active --quiet desktop.service'
}
ev_since() { date '+%Y-%m-%d %H:%M:%S'; }
# The full SELinux context of a path (ls -Zd's first field).
ctx_of() { ls -Zd "$1" 2>/dev/null | awk '{print $1}'; }

# S5.1.1: deploy/README.md's "Apply" block, as written, installs the tree.
# phase_deploy runs its first two commands as they stand there; the reboot
# that ends the block is the deploy tail's (S5.1.3).
deploy_applied() {
    local block want st u
    ev_begin S5.1.1 "The documented rsync is the whole installation" T3
    block=$(awk '/^## Apply/ {a = 1; next} a && /^```sh/ {c = 1; next} c && /^```/ {exit} c' deploy/README.md)
    ev_text apply-block "EV-CONFIG: deploy/README.md's \"Apply\" block as this run read it; phase-deploy ran its first two commands as written, and the reboot that ends it is the deploy tail's (S5.1.3)" "$block"
    want=$(printf '%s\n' 'rsync -a --chown=root:root deploy/host/ /' 'systemctl daemon-reload' 'reboot')
    [ "$(grep -v '^#' <<<"$block" | sed '/^[[:space:]]*$/d')" = "$want" ] \
        || fail "deploy/README.md's Apply block is no longer rsync, daemon-reload and reboot; phase-deploy runs the first two as this check reads them"
    ev_pass "the README's Apply block is rsync -a --chown=root:root deploy/host/ /, systemctl daemon-reload and reboot, and phase-deploy ran the first two as written"
    ev_save symlinks "EV-STATE: find /etc/systemd/system -maxdepth 2 -type l -ls after the two commands" \
        find /etc/systemd/system -maxdepth 2 -type l -ls >/dev/null || true
    [ "$(readlink /etc/systemd/system/default.target)" = /usr/lib/systemd/system/multi-user.target ] \
        || fail "default.target is not the tree's symlink to multi-user.target: $(ls -l /etc/systemd/system/default.target 2>&1)"
    [ "$(readlink /etc/systemd/system/getty@tty1.service)" = /dev/null ] \
        || fail "getty@tty1.service is not the tree's symlink to /dev/null: $(ls -l /etc/systemd/system/getty@tty1.service 2>&1)"
    for u in desktop-client-cdi.service desktop-selinux.service desktop-session.service desktop-tools-cdi.path; do
        [ "$(readlink "/etc/systemd/system/multi-user.target.wants/$u")" = "../$u" ] \
            || fail "multi-user.target.wants/$u is not the tree's symlink to ../$u"
    done
    ev_pass "the two symlinks (default.target to multi-user.target, getty@tty1.service to /dev/null) and the four multi-user.target.wants links arrived as symlinks"
    st=$(ev_save is-enabled "EV-STATE: systemctl is-enabled of the four units the tree enables, in this order: desktop-client-cdi.service, desktop-selinux.service, desktop-session.service, desktop-tools-cdi.path" \
        systemctl is-enabled desktop-client-cdi.service desktop-selinux.service desktop-session.service desktop-tools-cdi.path) || true
    [ "$(sort -u <<<"$st")" = enabled ] && [ "$(wc -l <<<"$st")" = 4 ] \
        || fail "not all four units read enabled: $(echo $st)"
    ev_pass "systemctl is-enabled reads enabled for desktop-client-cdi, desktop-selinux, desktop-session and desktop-tools-cdi.path"
    ev_save units "EV-STATE: systemctl list-units --all 'desktop*' right after the two commands" \
        systemctl list-units --all --no-pager 'desktop*' >/dev/null || true
    ev_end
}

# S5.3.1: on the stock image the boot getty owns tty1. seat-prep, started on
# its own, must stop it and say so, and restart logind because it changed
# something. Starting the desktop instead would prove nothing: its
# Conflicts= stops that getty in the same transaction.
seat_prep_dirty() {
    local sb lp0 lp1 t0 journal
    ev_begin S5.3.1 "Dirty seat is walked back" T3
    ev_save status-before "EV-STATE: systemctl status getty@tty1 display-manager before desktop-seat-prep runs: the stock image's getty owns tty1, and there is no display manager" \
        systemctl --no-pager status getty@tty1.service display-manager.service >/dev/null || true
    sb=$EV_LAST
    lp0=$(systemctl show -p MainPID --value systemd-logind.service)
    t0=$(ev_since)
    sleep 1
    systemctl start desktop-seat-prep.service || fail "desktop-seat-prep.service failed on the stock host"
    wait_for 10 1 "seat-prep's journal lines" \
        sh -c "journalctl --no-pager -u desktop-seat-prep.service --since '$t0' | grep -q 'seat-prep: seat converged'"
    journal=$(ev_save journal "EV-LOG-JOURNAL: desktop-seat-prep's journal for this run, started on its own before the desktop" \
        journalctl --no-pager -o short-iso -u desktop-seat-prep.service --since "$t0") || true
    ev_save logind-journal "EV-LOG-JOURNAL: systemd-logind's journal since seat-prep started: its restart" \
        journalctl --no-pager -o short-iso -u systemd-logind.service --since "$t0" >/dev/null || true
    lp1=$(systemctl show -p MainPID --value systemd-logind.service)
    ev_save status-after "EV-STATE: systemctl status getty@tty1 display-manager after desktop-seat-prep ran on its own" \
        systemctl --no-pager status getty@tty1.service display-manager.service >/dev/null || true
    ev_diff status "EV-DIFF: getty@tty1 and display-manager before and after seat-prep ran on its own" "$sb" "$EV_LAST"
    ev_save default "EV-STATE: systemctl get-default, then systemctl is-enabled getty@tty1" \
        sh -c 'systemctl get-default; systemctl is-enabled getty@tty1.service' >/dev/null || true
    ! systemctl is-active --quiet getty@tty1.service || fail "getty@tty1 still runs after desktop-seat-prep ran on its own"
    ev_pass "desktop-seat-prep, started on its own before the desktop, stopped getty@tty1"
    grep -q 'seat-prep: stopping running getty@tty1.service' <<<"$journal" \
        || fail "seat-prep's journal does not say 'stopping running getty@tty1.service'"
    ev_pass "its journal names what it did: stopping running getty@tty1.service, then seat converged"
    [ -n "$lp1" ] && [ "$lp1" != 0 ] && [ "$lp1" != "$lp0" ] \
        || fail "systemd-logind was not restarted (MainPID $lp0 -> $lp1)"
    ev_pass "systemd-logind was restarted, because seat state changed: MainPID $lp0 -> $lp1"
    [ "$(systemctl get-default)" = multi-user.target ] || fail "the default target is $(systemctl get-default)"
    ev_pass "the default target is multi-user.target"
    ev_end
}

# After phase_deploy, with the desktop up: labels, policy, the host-shell
# key and its limits, the login session, the tty, the container preflight.
deploy_checks() {
    local f c rules pats spell out ak line ip t0 rc sp got lrc sid show w lead tty dlog hits block kv s
    local -a o
    # S5.6.2
    ev_begin S5.6.2 "Three directories and the published binary are container_file_t" T3
    ev_save getenforce "EV-STATE: getenforce" getenforce >/dev/null || true
    ev_save labels "EV-STATE: ls -Zd of the three client directories, then ls -Z of what the desktop published into the toolkit directory" \
        sh -c 'ls -Zd /tmp/.X11-unix /run/desktop-audio /var/lib/desktop-container/bin; ls -Z /var/lib/desktop-container/bin' >/dev/null || true
    for f in /tmp/.X11-unix /run/desktop-audio /var/lib/desktop-container/bin /var/lib/desktop-container/bin/screenshot; do
        c=$(ctx_of "$f")
        [ "$c" = system_u:object_r:container_file_t:s0 ] || fail "$f is labelled '${c:-?}', want exactly system_u:object_r:container_file_t:s0"
    done
    ev_pass "the three directories and the published screenshot binary are labelled exactly system_u:object_r:container_file_t:s0: no categories"
    ev_end

    # S5.6.3
    ev_begin S5.6.3 "The label is policy, including the /run equivalency workaround" T3
    rules=$(ev_save fcontext "EV-STATE: semanage fcontext -l -C, the host's local file-context rules" semanage fcontext -l -C) \
        || fail "semanage fcontext -l -C failed"
    pats=$(awk 'NF >= 3 && $NF ~ /:container_file_t:/ {print $1}' <<<"$rules")
    grep -qxF '/tmp/\.X11-unix(/.*)?' <<<"$pats" || fail "no local container_file_t rule for /tmp/.X11-unix"
    grep -qxF '/var/lib/desktop-container/bin(/.*)?' <<<"$pats" || fail "no local container_file_t rule for /var/lib/desktop-container/bin"
    if grep -qxF '/run/desktop-audio(/.*)?' <<<"$pats"; then spell=/run
    elif grep -qxF '/var/run/desktop-audio(/.*)?' <<<"$pats"; then spell=/var/run
    else fail "no local container_file_t rule for /run/desktop-audio, under /run or /var/run"; fi
    ev_pass "semanage lists a local container_file_t rule for each of the three directories; /run/desktop-audio's is stored under $spell"
    ev_note "the policy took /run/desktop-audio's rule spelled under $spell (desktop-selinux tries /run first, then /var/run)"
    out=$(ev_save restorecon "EV-STATE: restorecon -Rv of the three directories: no output means nothing was relabelled" \
        restorecon -Rv /tmp/.X11-unix /run/desktop-audio /var/lib/desktop-container/bin) || fail "restorecon -Rv failed"
    [ -z "$out" ] || fail "restorecon -Rv relabelled something: $(echo $out)"
    ev_pass "restorecon -Rv of the three directories changes nothing: what is on disk is what the policy says"
    ev_save labels-after "EV-STATE: ls -Zd of the three directories after restorecon" \
        ls -Zd /tmp/.X11-unix /run/desktop-audio /var/lib/desktop-container/bin >/dev/null || true
    ev_end

    # S5.7.1
    ev_begin S5.7.1 "Fresh key every boot, root-only, restricted trust" T3
    ev_save files "EV-STATE: ls -l /etc/desktop-container /etc/ssh/authorized_keys.d" \
        ls -l /etc/desktop-container /etc/ssh/authorized_keys.d >/dev/null || true
    ak=$(ev_save authorized-keys "EV-CONFIG: /etc/ssh/authorized_keys.d/desktop-shell, the trust desktop-host-shell-setup wrote" \
        cat /etc/ssh/authorized_keys.d/desktop-shell) || fail "no authorized_keys entry for desktop-shell"
    [ "$(stat -c '%a %U' /etc/desktop-container/host-shell-key)" = "400 root" ] || fail "host-shell-key is $(stat -c '%a %U' /etc/desktop-container/host-shell-key), want 400 root"
    [ "$(stat -c '%a %U' /etc/desktop-container/host-shell-key.pub)" = "644 root" ] || fail "host-shell-key.pub is $(stat -c '%a %U' /etc/desktop-container/host-shell-key.pub), want 644 root"
    [ "$(stat -c '%a %U' /etc/ssh/authorized_keys.d/desktop-shell)" = "644 root" ] || fail "the authorized_keys entry is $(stat -c '%a %U' /etc/ssh/authorized_keys.d/desktop-shell), want 644 root"
    ev_pass "the private key is 0400 root; the public key and the authorized_keys entry are 0644 root"
    [ "$(wc -l <<<"$ak")" = 1 ] || fail "the authorized_keys entry is $(wc -l <<<"$ak") lines, want one"
    line=$ak
    case "$line" in
        'from="127.0.0.1,::1",no-port-forwarding,no-agent-forwarding,no-X11-forwarding ssh-ed25519 '*) ;;
        *) fail "the authorized_keys entry does not carry the expected restrictions and an ed25519 key: $line" ;;
    esac
    ev_pass "the entry is one line: from=\"127.0.0.1,::1\", no-port-forwarding, no-agent-forwarding, no-X11-forwarding, then an ssh-ed25519 key"
    [ "${line#* }" = "$(cat /etc/desktop-container/host-shell-key.pub)" ] || fail "the entry's key is not host-shell-key.pub's"
    ev_pass "the entry's key is the one in host-shell-key.pub"
    ssh-keygen -lf /etc/desktop-container/host-shell-key.pub | awk '{print $2}' > /var/tmp/ev-host-shell-fp
    ev_save fingerprint "EV-STATE: ssh-keygen -lf host-shell-key.pub: this boot's key (the deploy tail's reboot compares it)" \
        ssh-keygen -lf /etc/desktop-container/host-shell-key.pub >/dev/null || true
    ev_end

    # S5.7.3
    ev_begin S5.7.3 "Restrictions are enforced" T3
    ip=$(ip -4 -o addr show scope global | awk '{print $4}' | cut -d/ -f1 | sed -n 1p)
    [ -n "$ip" ] || fail "the VM has no non-loopback IPv4 address to try"
    o=(-n -i /etc/desktop-container/host-shell-key -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10)
    t0=$(ev_since)
    sleep 1
    rc=0
    ev_save loopback "EV-STATE: ssh with the host-shell key to desktop-shell@127.0.0.1, running true: the control, allowed from loopback" \
        ssh "${o[@]}" desktop-shell@127.0.0.1 true >/dev/null || rc=$?
    [ "$rc" = 0 ] || fail "the key does not work even from loopback (exit $rc): nothing below would mean anything"
    rc=0
    ev_save non-loopback "EV-STATE: the same ssh to desktop-shell@$ip, this VM's own non-loopback address: refused by from=" \
        ssh "${o[@]}" "desktop-shell@$ip" true >/dev/null || rc=$?
    [ "$rc" != 0 ] || fail "the key was accepted from $ip"
    ev_pass "the key is accepted from 127.0.0.1 and refused from $ip (ssh exit $rc)"
    rc=0
    ev_save remote-forward "EV-STATE: ssh -o ExitOnForwardFailure=yes -R 127.0.0.1:40022:127.0.0.1:22 desktop-shell@127.0.0.1 true: a remote forward, refused when it is set up" \
        ssh "${o[@]}" -o ExitOnForwardFailure=yes -R 127.0.0.1:40022:127.0.0.1:22 desktop-shell@127.0.0.1 true >/dev/null || rc=$?
    [ "$rc" != 0 ] || fail "a remote port forward was set up"
    ev_pass "a remote port forward is refused when it is set up: ssh -R with ExitOnForwardFailure=yes exits $rc"
    # A local forward is refused only when something uses it: sshd turns
    # down the channel then, not the listening ssh's setup.
    ssh "${o[@]}" -o ExitOnForwardFailure=yes -L 127.0.0.1:40023:127.0.0.1:22 desktop-shell@127.0.0.1 'sleep 6' \
        > /tmp/ev-s573-local.log 2>&1 &
    sp=$!
    sleep 2
    got=$(timeout 4 bash -c 'exec 3<>/dev/tcp/127.0.0.1/40023 && timeout 2 head -c 32 <&3' 2>&1 || true)
    lrc=0
    wait "$sp" || lrc=$?
    ev_copy /tmp/ev-s573-local.log local-forward "EV-STATE: the stderr of ssh -o ExitOnForwardFailure=yes -L 127.0.0.1:40023:127.0.0.1:22 desktop-shell@127.0.0.1 'sleep 6', while a connection was made through the forward"
    ev_text local-forward-use "EV-STATE: what a connection through the local forward read back (sshd's banner would mean the forward worked)" "${got:-(nothing)}"
    grep -q 'administratively prohibited' /tmp/ev-s573-local.log || fail "the local forward was not refused when used: $(cat /tmp/ev-s573-local.log)"
    ! grep -q '^SSH-' <<<"$got" || fail "a connection through the local forward reached sshd: $got"
    ev_pass "a local forward is refused when used: the channel is administratively prohibited and the connection gets nothing"
    ev_note "ssh -L with ExitOnForwardFailure=yes exited $lrc: the refusal comes when the forward is used, after setup, so ExitOnForwardFailure does not see it"
    ev_save sshd-journal "EV-LOG-JOURNAL: sshd's journal since the first of these connections" \
        journalctl --no-pager -o short-iso -u sshd.service --since "$t0" >/dev/null || true
    ev_end

    # S5.8.1
    ev_begin S5.8.1 "A real logind session on seat0/tty1" T3
    ev_save sessions "EV-STATE: loginctl list-sessions" loginctl list-sessions --no-pager >/dev/null || true
    sid=""
    for s in $(loginctl list-sessions --no-legend --no-pager | awk '{print $1}'); do
        [ "$(loginctl show-session "$s" -p Name --value)" = desktop ] && { sid=$s; break; }
    done
    [ -n "$sid" ] || fail "no logind session for the desktop user"
    show=$(ev_save show-session "EV-STATE: loginctl show-session $sid, the desktop user's session" loginctl show-session "$sid") || true
    for kv in Name=desktop Seat=seat0 TTY=tty1 Class=user; do
        grep -qx "$kv" <<<"$show" || fail "the desktop session's $kv is not so: $(grep "^${kv%%=*}=" <<<"$show")"
    done
    ev_pass "logind holds a user session for desktop on seat0, on tty1 (session $sid)"
    ev_save findmnt "EV-STATE: findmnt /run/user/61000, and the unit that mounted it" \
        sh -c 'findmnt /run/user/61000; systemctl --no-pager status user-runtime-dir@61000.service | head -5' >/dev/null || true
    [ "$(findmnt -n -o FSTYPE /run/user/61000)" = tmpfs ] || fail "/run/user/61000 is not a tmpfs mount"
    systemctl is-active --quiet user-runtime-dir@61000.service || fail "user-runtime-dir@61000.service, logind's mounter, is not active"
    ev_pass "/run/user/61000 is a tmpfs mounted by logind's user-runtime-dir@61000.service"
    w=$(ev_save who "EV-STATE: who: utmp's login records" who) || true
    grep -Eq '^desktop +tty1 ' <<<"$w" || fail "utmp has no tty1 entry for desktop: $w"
    ev_pass "utmp records desktop on tty1"
    ev_end

    # S5.8.3
    ev_begin S5.8.3 "Does not steal the controlling tty" T3
    lead=$(systemctl show -p MainPID --value desktop-session.service)
    [ -n "$lead" ] && [ "$lead" != 0 ] || fail "desktop-session.service has no main process"
    ev_save lead "EV-PIDS: desktop-session-lead, desktop-session.service's main process: pid, controlling tty, user, command" \
        ps -o pid,tty,user,args -p "$lead" >/dev/null || true
    tty=$(ps -o tty= -p "$lead" | tr -d ' ')
    [ "$tty" = "?" ] || fail "desktop-session-lead has a controlling tty: $tty"
    ev_pass "the host session's lead process has no controlling tty ($lead: ?)"
    dlog=$(podman logs desktop 2>&1 | tr -d '\r')
    hits=$(grep 'failed to set the controlling terminal' <<<"$dlog" || true)
    ev_text grep "EV-LOG-DESKTOP: the desktop log's lines saying 'failed to set the controlling terminal'" "${hits:-(none)}"
    [ -z "$hits" ] || fail "the desktop's log says it failed to set the controlling terminal"
    ev_pass "the desktop's log never says it failed to set the controlling terminal"
    ev_save x-tty "EV-PIDS: Xorg in the container: its controlling tty" \
        podman exec desktop ps -o pid,tty,user,args -C Xorg >/dev/null || true
    ev_end

    # S5.11.1
    ev_begin S5.11.1 "Green on a provisioned KMS host" T3
    block=$(grep 'preflight:' <<<"$dlog" || true)
    ev_text preflight "EV-LOG-DESKTOP: the container preflight's lines in the desktop's log" "${block:-(none)}"
    [ -n "$block" ] || fail "the desktop's log has no preflight: lines"
    ! grep -q 'preflight: FAIL:' <<<"$block" || fail "the container preflight reports: $(grep 'preflight: FAIL:' <<<"$block" | head -3)"
    ev_pass "the container preflight ran ($(wc -l <<<"$block") lines) and reported no FAIL"
    ev_end
}

# The destructive tail, last in the core shard: oneshots and the gate with
# the desktop stopped, the .path unit, an image pin, the labeller on probe
# directories, and the Conflicts= backstop. Each step leaves the desktop up.
deploy_tail() {
    local b c d f out rc holder t0 journal xpid running img pf spec
    # S5.5.6
    ev_begin S5.5.6 "Specs are host state, independent of the desktop and of kubernetes" T3
    desk_down
    ev_save cdi-before "EV-STATE: ls -l --full-time /etc/cdi with desktop.service stopped" ls -l --full-time /etc/cdi >/dev/null || true
    b=$EV_LAST
    mkdir -p /run/ev-s556
    cp /etc/cdi/desktop-display.yaml /etc/cdi/desktop-audio.yaml /run/ev-s556/
    rm -f /etc/cdi/desktop-display.yaml /etc/cdi/desktop-audio.yaml
    ev_save cdi-removed "EV-STATE: ls -l --full-time /etc/cdi with the display and audio specs removed" ls -l --full-time /etc/cdi >/dev/null || true
    systemctl restart desktop-client-cdi.service || fail "desktop-client-cdi.service failed with the desktop down"
    ev_save cdi-after "EV-STATE: ls -l --full-time /etc/cdi after systemctl restart desktop-client-cdi, the desktop still stopped" \
        ls -l --full-time /etc/cdi >/dev/null || true
    ev_diff cdi "EV-DIFF: /etc/cdi before the removal and after desktop-client-cdi ran again: the two specs are back, rewritten" "$b" "$EV_LAST"
    for f in desktop-display.yaml desktop-audio.yaml; do
        [ -s "/etc/cdi/$f" ] || fail "desktop-client-cdi did not write $f with the desktop down"
        cmp -s "/run/ev-s556/$f" "/etc/cdi/$f" || fail "$f came back different"
    done
    ev_save specs-diff "EV-DIFF: the two specs before the removal against the rewritten ones (no output: the same bytes)" \
        sh -c 'diff -u /run/ev-s556/desktop-display.yaml /etc/cdi/desktop-display.yaml; diff -u /run/ev-s556/desktop-audio.yaml /etc/cdi/desktop-audio.yaml' >/dev/null || true
    ! systemctl is-active --quiet desktop.service || fail "the desktop started"
    ev_pass "with desktop.service stopped, desktop-client-cdi wrote the display and audio specs again, byte for byte the same"
    ev_end

    # S5.3.3 (the desktop is still down)
    ev_begin S5.3.3 "The gate names a culprit and fails" T3
    # The redirection is the point: the sleep holds card0 open, as a leftover
    # compositor would.
    # shellcheck disable=SC2217
    (exec sleep 600 < /dev/dri/card0) >/dev/null 2>&1 &
    holder=$!
    sleep 1
    ev_save holders "EV-PIDS: fuser -v /dev/dri/card0 /dev/tty1 with the desktop stopped and a sleep (pid $holder) holding card0" \
        sh -c 'fuser -v /dev/dri/card0 /dev/tty1 2>&1; true' >/dev/null || true
    t0=$(ev_since)
    sleep 1
    rc=0
    systemctl restart desktop-seat-prep.service || rc=$?
    [ "$rc" != 0 ] || { kill "$holder" 2>/dev/null || true; fail "desktop-seat-prep succeeded while pid $holder held /dev/dri/card0"; }
    wait_for 10 1 "seat-prep's ERROR line in the journal" \
        sh -c "journalctl --no-pager -u desktop-seat-prep.service --since '$t0' | grep -q 'ERROR: devices still held'"
    journal=$(ev_save journal "EV-LOG-JOURNAL: desktop-seat-prep's journal for the run with card0 held: its ERROR line and fuser's table" \
        journalctl --no-pager -o short-iso -u desktop-seat-prep.service --since "$t0") || true
    grep -Eq "ERROR: devices still held after convergence:.* /dev/dri/card0\(([0-9 ]* )?$holder( [0-9 ]*)?\)" <<<"$journal" \
        || { kill "$holder" 2>/dev/null || true; fail "seat-prep's ERROR line does not name pid $holder on /dev/dri/card0"; }
    ev_pass "systemctl restart desktop-seat-prep failed (exit $rc), its journal naming /dev/dri/card0 held by pid $holder, with fuser's table"
    systemctl start desktop.service || { kill "$holder" 2>/dev/null || true; fail "desktop.service did not start with seat-prep failed"; }
    wait_for 40 3 "desktop-init ready in container" container_running
    [ "$(systemctl is-active desktop.service)" = active ] || { kill "$holder" 2>/dev/null || true; fail "desktop.service is not active with seat-prep failed"; }
    ev_pass "desktop.service still starts with seat-prep failed: the quadlet only Wants= it"
    # Its Xorg then meets what the gate named. The first process to open a
    # DRM primary node is its master, so the sleep is, and the rootless
    # Xorg cannot take master from it (run 37356857793 waited for X).
    xconflict() { podman exec desktop grep -q 'drmSetMaster failed' "$XORG_LOG" 2>/dev/null; }
    wait_for 60 2 "Xorg's drmSetMaster failure, the sleep holding card0" xconflict
    ev_save x-conflict "EV-LOG-XORG: the Xorg log's DRM-master lines and its fatal error, the sleep holding card0" \
        podman exec desktop grep -A3 'drmSetMaster\|Fatal server error' "$XORG_LOG" >/dev/null || true
    ev_save status "EV-STATE: systemctl status desktop-seat-prep desktop with seat-prep failed and the desktop's unit started" \
        systemctl --no-pager status desktop-seat-prep.service desktop.service >/dev/null || true
    ev_pass "its Xorg met the conflict the gate named: drmSetMaster failed (the sleep, card0's first opener, is DRM master), as seat-prep's unit says it will"
    desk_down
    kill "$holder" 2>/dev/null || true
    wait "$holder" 2>/dev/null || true
    rc=0
    systemctl restart desktop-seat-prep.service || rc=$?
    [ "$rc" = 0 ] || fail "with the sleep gone and the desktop down, desktop-seat-prep still fails (exit $rc)"
    ev_pass "with the sleep gone, desktop-seat-prep succeeds again"
    systemctl start desktop.service || fail "desktop.service did not start again"
    desk_back
    ev_pass "the desktop comes up again, X answering"
    running=$(ev_save running-view "EV-STATE: fuser -v /dev/dri/card* /dev/tty1 on the host with the desktop running: what seat-prep's gate can see of the container's own Xorg" \
        sh -c 'fuser -v /dev/dri/card* /dev/tty1 2>&1; true') || true
    xpid=$(pgrep -x Xorg | sed -n 1p || true)
    if [ -n "$xpid" ] && grep -qw "$xpid" <<<"$running"; then
        ev_note "the host's fuser lists the container's Xorg (pid $xpid) on the DRM or VT devices"
    else
        ev_note "the host's fuser does not list the container's Xorg (pid ${xpid:-?}): podman gives the container device nodes of its own, and fuser matches an open file by its node"
    fi
    ev_end

    # S5.5.5
    ev_begin S5.5.5 "The .path unit advertises once per boot and parks" T3
    spec=/etc/cdi/desktop-tools.yaml
    wait_for 30 1 "the tools spec, after the desktop's restart" test -s "$spec"
    ev_save state-before "EV-STATE: desktop-tools-cdi.path and .service, and the tools spec" \
        sh -c 'systemctl --no-pager status desktop-tools-cdi.path desktop-tools-cdi.service; ls -l --full-time /etc/cdi/desktop-tools.yaml' >/dev/null || true
    t0=$(ev_since)
    rm -f "$spec"
    sleep 5
    ev_save state-removed "EV-STATE: the same 5 s after the spec was removed" \
        sh -c 'systemctl --no-pager status desktop-tools-cdi.path desktop-tools-cdi.service; ls -l --full-time /etc/cdi/desktop-tools.yaml' >/dev/null || true
    [ ! -e "$spec" ] || fail "the tools spec came back within 5 s by itself"
    [ "$(systemctl show -p ActiveState --value desktop-tools-cdi.service)" = active ] || fail "desktop-tools-cdi.service is not active (exited)"
    ev_pass "removed, the spec stays gone for 5 s: desktop-tools-cdi.service is still active, so the .path unit does not fire again"
    systemctl stop desktop-tools-cdi.service
    wait_for 15 1 "the tools spec to come back" test -s "$spec"
    ev_save state-after "EV-STATE: the same after systemctl stop desktop-tools-cdi.service" \
        sh -c 'systemctl --no-pager status desktop-tools-cdi.path desktop-tools-cdi.service; ls -l --full-time /etc/cdi/desktop-tools.yaml' >/dev/null || true
    ! systemctl is-failed --quiet desktop-tools-cdi.path || fail "desktop-tools-cdi.path failed"
    [ "$(systemctl show -p ActiveState --value desktop-tools-cdi.path)" = active ] || fail "desktop-tools-cdi.path is not active"
    ev_pass "stopping desktop-tools-cdi.service let the .path unit fire again: the spec is back, and the .path unit is active, not failed"
    ev_save journal "EV-LOG-JOURNAL: desktop-tools-cdi.path and .service since the spec was removed" \
        journalctl --no-pager -o short-iso -u desktop-tools-cdi.path -u desktop-tools-cdi.service --since "$t0" >/dev/null || true
    ev_end

    # S5.2.6
    ev_begin S5.2.6 "Image pin drop-in" T3
    ev_save podman-version "EV-STATE: podman --version" podman --version >/dev/null || true
    podman tag localhost/desktop-container:latest localhost/desktop-container:ev-pinned
    mkdir -p /etc/containers/systemd/desktop.container.d
    printf '[Container]\nImage=localhost/desktop-container:ev-pinned\n' > /etc/containers/systemd/desktop.container.d/50-image.conf
    ev_copy /etc/containers/systemd/desktop.container.d/50-image.conf drop-in "EV-CONFIG: the drop-in: desktop.container.d/50-image.conf, pinning localhost/desktop-container:ev-pinned (a second name for the same image)"
    systemctl daemon-reload
    c=$(ev_save unit "EV-CONFIG: systemctl cat desktop.service with the drop-in in place: the unit quadlet generated" \
        systemctl cat desktop.service) || fail "systemctl cat desktop.service failed"
    grep -q 'localhost/desktop-container:ev-pinned' <<<"$c" || fail "the generated desktop.service does not carry the drop-in's image"
    ev_pass "the generated desktop.service carries the drop-in's image"
    systemctl restart desktop.service
    desk_back
    img=$(podman inspect desktop --format '{{.ImageName}}')
    ev_text image "EV-STATE: podman inspect desktop --format '{{.ImageName}}' after the restart" "$img"
    [ "$img" = localhost/desktop-container:ev-pinned ] || fail "the restarted desktop runs $img, not the pinned image"
    ev_pass "restarted, the desktop runs the pinned image: $img"
    pf=$(ev_save preflight "EV-STATE: desktop-preflight with the drop-in in place" desktop-preflight) || true
    grep -qF 'host-preflight: PASS: quadlet drop-ins present in /etc/containers/systemd/desktop.container.d (podman merges them)' <<<"$pf" \
        || fail "desktop-preflight does not report the drop-in as merged"
    grep -qF 'host-preflight: PASS: image in podman storage: localhost/desktop-container:ev-pinned' <<<"$pf" \
        || fail "desktop-preflight does not report the pinned image"
    ev_pass "desktop-preflight reports the drop-in as merged and the pinned image in storage"
    rm -f /etc/containers/systemd/desktop.container.d/50-image.conf
    rmdir /etc/containers/systemd/desktop.container.d
    systemctl daemon-reload
    systemctl restart desktop.service
    desk_back
    img=$(podman inspect desktop --format '{{.ImageName}}')
    [ "$img" = localhost/desktop-container:latest ] || fail "with the drop-in removed the desktop runs $img"
    podman untag localhost/desktop-container:ev-pinned localhost/desktop-container:ev-pinned >/dev/null 2>&1 || true
    ev_pass "with the drop-in removed, the desktop runs localhost/desktop-container:latest again"
    ev_end

    # S5.6.4: no semanage on PATH (and with it, no policy rule for a probe).
    ev_begin S5.6.4 "chcon fallback without semanage" T3
    d=/var/tmp/ev-s564
    mkdir -p "$d"
    ev_save before "EV-STATE: ls -Zd of the probe directory before" ls -Zd "$d" >/dev/null || true
    rc=0
    out=$(ev_save run "EV-STATE: PATH=/usr/bin:/bin desktop-selinux $d (no semanage, restorecon or selinuxenabled on PATH): its output and exit status" \
        env PATH=/usr/bin:/bin /usr/local/libexec/desktop-selinux "$d") || rc=$?
    [ "$rc" = 0 ] || fail "desktop-selinux without semanage exited $rc"
    grep -qF 'note: policycoreutils-python-utils absent, so the labels cannot become policy' <<<"$out" || fail "desktop-selinux did not print the policy note"
    grep -qF "labeled container_file_t: $d" <<<"$out" || fail "desktop-selinux did not report the probe labelled"
    [ "$(ctx_of "$d" | cut -d: -f3)" = container_file_t ] || fail "the probe directory is $(ctx_of "$d")"
    ev_save after "EV-STATE: ls -Zd of the probe directory after" ls -Zd "$d" >/dev/null || true
    ! grep -qF "$d" <<<"$(semanage fcontext -l -C)" || fail "a policy rule for the probe directory appeared"
    ev_pass "without semanage on PATH, desktop-selinux printed the policy note, labelled the probe directory container_file_t with chcon and exited 0, and added no policy rule"
    ev_end

    # S5.6.5: a filesystem that refuses relabeling (a context= mount).
    ev_begin S5.6.5 "Verification fails the unit when a label does not land" T3
    d=/var/tmp/ev-s565
    mkdir -p "$d"
    mount -t tmpfs -o size=1m,context=system_u:object_r:tmp_t:s0 tmpfs "$d"
    mkdir -p "$d/dir"
    ev_save mount "EV-STATE: findmnt of the probe filesystem: a tmpfs mounted with context=, whose files cannot be relabelled" findmnt "$d" >/dev/null || true
    rc=0
    ev_save chcon "EV-STATE: chcon -t container_file_t on it by hand: refused" chcon -t container_file_t "$d/dir" >/dev/null || rc=$?
    [ "$rc" != 0 ] || { umount "$d"; fail "chcon relabelled a file on the context= mount; the probe proves nothing"; }
    rc=0
    out=$(ev_save run "EV-STATE: PATH=/usr/bin:/bin desktop-selinux $d/dir: its output and exit status" \
        env PATH=/usr/bin:/bin /usr/local/libexec/desktop-selinux "$d/dir") || rc=$?
    ev_save after "EV-STATE: ls -Zd of the probe directory after" ls -Zd "$d/dir" >/dev/null || true
    umount "$d"
    rmdir "$d"
    [ "$rc" = 1 ] || fail "desktop-selinux exited $rc on a directory it could not label, want 1"
    grep -qF 'FAILED to label for confined containers:' <<<"$out" || fail "desktop-selinux did not say FAILED to label"
    grep -qF "$d/dir: system_u:object_r:tmp_t:s0" <<<"$out" || fail "desktop-selinux did not name the directory and its label"
    ev_pass "on a directory it could not relabel, desktop-selinux said FAILED to label, named it with its tmp_t label, and exited 1"
    ev_end

    # S5.6.6
    ev_begin S5.6.6 "Missing directories are reported, not invented" T3
    d=/var/tmp/ev-s566
    mkdir -p "$d"
    rc=0
    out=$(ev_save two-bogus "EV-STATE: desktop-selinux /nonexistent/ev-a /nonexistent/ev-b (PATH=/usr/bin:/bin): its output and exit status" \
        env PATH=/usr/bin:/bin /usr/local/libexec/desktop-selinux /nonexistent/ev-a /nonexistent/ev-b) || rc=$?
    [ "$rc" = 1 ] || fail "with both paths missing desktop-selinux exited $rc, want 1"
    grep -qF 'WARNING: not created by tmpfiles.d, skipping: /nonexistent/ev-a /nonexistent/ev-b' <<<"$out" || fail "the warning does not name both paths"
    grep -qF 'none of the client directories exist yet' <<<"$out" || fail "desktop-selinux did not say none exist"
    ev_pass "two missing paths: both named in the warning, then 'none of the client directories exist yet', exit 1"
    rc=0
    out=$(ev_save one-bogus "EV-STATE: desktop-selinux /nonexistent/ev-a $d (PATH=/usr/bin:/bin): its output and exit status" \
        env PATH=/usr/bin:/bin /usr/local/libexec/desktop-selinux /nonexistent/ev-a "$d") || rc=$?
    [ "$rc" = 0 ] || fail "with one path missing desktop-selinux exited $rc, want 0"
    grep -qF 'WARNING: not created by tmpfiles.d, skipping: /nonexistent/ev-a' <<<"$out" || fail "the warning does not name the missing path"
    grep -qF "labeled container_file_t: $d" <<<"$out" || fail "the real directory was not reported labelled"
    [ ! -e /nonexistent/ev-a ] || fail "desktop-selinux created the missing directory"
    ev_pass "one missing path and one real: the missing one warned about and not created, the real one labelled, exit 0"
    ev_end

    # S5.2.5, then put everything back for the reboot.
    ev_begin S5.2.5 "Conflicts= backstop" T3
    c=$(ev_save conflicts "EV-CONFIG: systemctl show -p Conflicts desktop.service: the generated unit's conflicts" \
        systemctl show -p Conflicts desktop.service) || true
    grep -qw 'getty@tty1.service' <<<"$c" && grep -qw 'display-manager.service' <<<"$c" \
        || fail "desktop.service does not conflict with both getty@tty1 and display-manager: $c"
    systemctl is-active --quiet desktop.service || fail "the desktop is not running before the backstop test"
    t0=$(ev_since)
    systemctl unmask getty@tty1.service
    systemctl start getty@tty1.service
    wait_for 30 1 "desktop.service to stop once getty@tty1 started" sh -c '! systemctl is-active --quiet desktop.service'
    ev_save status-getty "EV-STATE: systemctl status getty@tty1 desktop with getty@tty1 started on purpose: the desktop stopped" \
        systemctl --no-pager status getty@tty1.service desktop.service >/dev/null || true
    ev_pass "starting getty@tty1 stopped desktop.service"
    systemctl stop getty@tty1.service
    ln -sfn /dev/null /etc/systemd/system/getty@tty1.service
    systemctl daemon-reload
    [ "$(systemctl is-enabled getty@tty1.service 2>/dev/null || true)" = masked ] || fail "getty@tty1 is not masked again"
    systemctl start desktop.service
    desk_back
    printf '[Unit]\nDescription=ev: a stand-in display manager (S5.2.5)\n[Service]\nExecStart=/usr/bin/sleep infinity\n' \
        > /etc/systemd/system/display-manager.service
    systemctl daemon-reload
    systemctl start display-manager.service
    wait_for 30 1 "desktop.service to stop once a display manager started" sh -c '! systemctl is-active --quiet desktop.service'
    ev_save status-dm "EV-STATE: systemctl status display-manager desktop with a stand-in display manager started: the desktop stopped" \
        systemctl --no-pager status display-manager.service desktop.service >/dev/null || true
    ev_pass "starting a display-manager.service stopped desktop.service"
    systemctl stop display-manager.service
    rm -f /etc/systemd/system/display-manager.service
    systemctl daemon-reload
    systemctl start desktop.service
    desk_back
    ev_save journal "EV-LOG-JOURNAL: desktop, getty@tty1 and display-manager through the test" \
        journalctl --no-pager -o short-iso -u desktop.service -u getty@tty1.service -u display-manager.service --since "$t0" >/dev/null || true
    ev_pass "restored: getty@tty1 masked again, no display manager, the desktop running"
    ev_end

    cat /proc/sys/kernel/random/boot_id > /var/tmp/ev-boot-id-before
}

# After the host rebooted the VM with nobody touching it.
deploy_reboot() {
    local old now u boot_epoch mt j fp0 fp1 st n
    ev_begin S5.1.3 "Reboot is sufficient, and the operator gets a desktop with no one touching the host" T3
    old=$(cat /var/tmp/ev-boot-id-before 2>/dev/null || true)
    now=$(cat /proc/sys/kernel/random/boot_id)
    [ -n "$old" ] && [ "$now" != "$old" ] || fail "this is not a new boot (boot id $now)"
    ev_note "boot id before the reboot $old, now $now"
    wait_for 60 3 "desktop.service active after the reboot" systemctl is-active --quiet desktop.service
    desk_back
    for u in desktop-seat-prep desktop-cdi-refresh desktop-client-cdi desktop-host-shell desktop-selinux; do
        st="$(systemctl show -p ActiveState --value "$u.service")/$(systemctl show -p Result --value "$u.service")"
        [ "$st" = active/success ] || fail "$u.service is $st after the reboot"
    done
    ev_pass "after the reboot desktop.service is active, X answers, mwm runs, and the five boot oneshots are active and succeeded"
    wait_for 60 2 "the tools spec, advertised this boot" test -s /etc/cdi/desktop-tools.yaml
    boot_epoch=$(( $(date +%s) - $(cut -d. -f1 /proc/uptime) ))
    mt=$(stat -c %Y /etc/cdi/desktop-tools.yaml)
    [ "$mt" -ge "$boot_epoch" ] || fail "the tools spec was not rewritten this boot (mtime $mt, boot $boot_epoch)"
    [ "$(systemctl show -p Result --value desktop-tools-cdi.service)" = success ] || fail "desktop-tools-cdi.service did not succeed this boot"
    ev_pass "desktop-tools-cdi rewrote the tools spec this boot ($(date -u -d "@$mt" +%H:%M:%S) UTC, boot at $(date -u -d "@$boot_epoch" +%H:%M:%S))"
    ev_save units "EV-STATE: systemctl status of the tree's units after the reboot" \
        systemctl --no-pager status desktop.service desktop-session.service desktop-seat-prep.service desktop-cdi-refresh.service \
            desktop-client-cdi.service desktop-host-shell.service desktop-selinux.service desktop-tools-cdi.path desktop-tools-cdi.service >/dev/null || true
    ev_save failed "EV-STATE: systemctl --failed after the reboot" systemctl --failed --no-pager >/dev/null || true
    ! grep -q 'desktop' <<<"$(systemctl --failed --no-legend --no-pager)" || fail "a desktop unit failed this boot"
    ev_pass "no desktop unit failed this boot"
    ev_save labels "EV-STATE: ls -Zd of the three client directories after the reboot" \
        ls -Zd /tmp/.X11-unix /run/desktop-audio /var/lib/desktop-container/bin >/dev/null || true
    for u in /tmp/.X11-unix /run/desktop-audio /var/lib/desktop-container/bin; do
        [ "$(ctx_of "$u")" = system_u:object_r:container_file_t:s0 ] || fail "$u is $(ctx_of "$u") after the reboot"
    done
    ev_pass "the three client directories are container_file_t again after the reboot (/run/desktop-audio is new this boot)"
    ev_save cdi "EV-STATE: ls -l --full-time /etc/cdi after the reboot" ls -l --full-time /etc/cdi >/dev/null || true
    j=$(ev_save seat-prep-journal "EV-LOG-JOURNAL: journalctl -b -u desktop-seat-prep: this boot's seat-prep, on a converged seat" \
        journalctl -b --no-pager -o short-iso -u desktop-seat-prep.service) || true
    ! grep -q 'seat-prep: ' <<<"$j" || fail "seat-prep changed something this boot: $(grep 'seat-prep: ' <<<"$j" | head -3)"
    ev_pass "seat-prep logged nothing this boot: on a converged seat it changes nothing"
    ev_save sessions "EV-STATE: loginctl list-sessions after the reboot" loginctl list-sessions --no-pager >/dev/null || true
    ev_end

    # S5.3.1's steady half: no change, so no logind restart either.
    ev_begin S5.3.1 "Dirty seat is walked back" T3
    ev_save logind-journal "EV-LOG-JOURNAL: journalctl -b -u systemd-logind: logind this boot, started once" \
        journalctl -b --no-pager -o short-iso -u systemd-logind.service >/dev/null || true
    n=$(journalctl -b --no-pager -o cat -u systemd-logind.service | grep -c '^Started ' || true)
    [ "$n" = 1 ] || fail "systemd-logind started $n times this boot, want once"
    ev_pass "on the steady-state boot seat-prep logged nothing, and logind started once, at boot: no restart"
    ev_end

    # S5.5.5's reboot half
    ev_begin S5.5.5 "The .path unit advertises once per boot and parks" T3
    ev_pass "after a reboot with the toolkit directory populated, the .path unit advertised again: the tools spec was rewritten this boot (S5.1.3)"
    ev_save state "EV-STATE: desktop-tools-cdi.path and .service after the reboot" \
        systemctl --no-pager status desktop-tools-cdi.path desktop-tools-cdi.service >/dev/null || true
    ev_end

    # S5.7.1's every-boot half
    ev_begin S5.7.1 "Fresh key every boot, root-only, restricted trust" T3
    fp0=$(cat /var/tmp/ev-host-shell-fp 2>/dev/null || true)
    fp1=$(ssh-keygen -lf /etc/desktop-container/host-shell-key.pub | awk '{print $2}')
    ev_text fingerprints "EV-STATE: the host-shell key's fingerprint before and after the reboot" "before: ${fp0:-?}
after:  $fp1"
    [ -n "$fp0" ] && [ "$fp1" != "$fp0" ] || fail "the host-shell key is the same after the reboot"
    [ "$(cut -d' ' -f2- /etc/ssh/authorized_keys.d/desktop-shell)" = "$(cat /etc/desktop-container/host-shell-key.pub)" ] \
        || fail "after the reboot the authorized_keys entry does not carry the new key"
    ev_pass "the reboot made a new key ($fp0 -> $fp1), and the authorized_keys entry carries it"
    ev_end
}

# --- the session's tail (E2, E3, E4, E5) ---------------------------------------
# Late in the core shard, before the deploy tail and its reboot: the device
# groups as the session sees them, mwm's own exit, a desktop with no host
# login session, a device tagged for another seat, and the host's own Pulse
# and ALSA clients. Each step leaves the desktop up.

# S3.2.2's T3 half: the container's device groups carry the host nodes' gids,
# so the session user opens DRM, evdev and ALSA. The table is the first one
# in this container's log, written at its start; an audio restart's narrow
# run (the audio group alone) comes after it.
session_groups() {
    local dlog table g line cg node hg pf k
    ev_begin S3.2.2 "Group gids are aligned to the host's device nodes" T3
    dlog=$(podman logs desktop 2>&1 | tr -d '\r' || true)
    ev_text align "EV-LOG-DESKTOP: align-device-groups' lines in this container's log (its start runs every group; an audio restart runs the audio group alone)" \
        "$(grep '^align-device-groups:' <<<"$dlog" || echo '(none)')"
    table=$(awk '/^align-device-groups: final state:/ {f = 1; next}
                 f && /^align-device-groups: desktop user:/ {print; exit}
                 f {print}' <<<"$dlog")
    [ -n "$table" ] || fail "align-device-groups logged no final-state table"
    for g in video render input audio; do
        line=$(grep -E "^align-device-groups: +$g: " <<<"$table" | head -n1 || true)
        [ -n "$line" ] || fail "align-device-groups' final state has no $g line"
        cg=$(sed -n 's/.*container gid \([0-9]*\),.*/\1/p' <<<"$line")
        node=$(sed -n 's/.*, device \(\/dev\/[^ ]*\) has gid.*/\1/p' <<<"$line")
        hg=$(stat -c %g "$node" 2>/dev/null || true)
        [ -n "$cg" ] && [ -n "$hg" ] && [ "$cg" = "$hg" ] \
            || fail "the container's $g group is gid ${cg:-?}, the host's ${node:-node} gid ${hg:-?}"
        ev_pass "$g: the container's group is gid $cg, as the host's $node"
    done
    grep -q '^align-device-groups: desktop user: uid=61000(desktop)' <<<"$table" \
        || fail "align-device-groups' final state does not end with id desktop"
    ev_pass "the table ends with id desktop: $(sed -n 's/^align-device-groups: desktop user: //p' <<<"$table")"
    pf=$(grep '^preflight: .*desktop user' <<<"$dlog" || true)
    ev_text preflight "EV-LOG-DESKTOP: the container preflight's lines on what the desktop user can open" "${pf:-(none)}"
    for k in /dev/dri/card /dev/input/event /dev/snd/controlC; do
        grep -q "^preflight: PASS: desktop user can read ${k}[0-9]" <<<"$pf" \
            || fail "the preflight has no PASS for the desktop user reading a $k node"
    done
    ev_pass "the preflight passes all three: $(grep -o 'can read /dev/[^ ]*' <<<"$pf" | sed 's/can read //' | paste -sd' ' -)"
    ev_save nodes-host "EV-STATE: ls -ln /dev/dri /dev/input /dev/snd on the host" \
        ls -ln /dev/dri /dev/input /dev/snd >/dev/null || true
    ev_save nodes-container "EV-STATE: ls -ln /dev/dri /dev/input /dev/snd in the container" \
        podman exec desktop ls -ln /dev/dri /dev/input /dev/snd >/dev/null || true
    ev_save groups "EV-STATE: getent group video render input audio and id desktop in the container" \
        podman exec desktop sh -c 'getent group video render input audio; id desktop' >/dev/null || true
    ev_end
}

# S2.3.6: mwm's own exit ends the session, and a new one starts. A plain
# kill's SIGTERM, as the session user: the image drops `kill` from mwm's
# showFeedback, so mwm quits without asking. The host records the display.
verify_mwm_exit() {
    local init xorg mwm n_lines since xorg2 mwm2 p_before
    wait_for 30 2 "an X session" session_up
    ev_begin S2.3.6 "mwm exit ends the session and it restarts" T3
    init=$(podman exec desktop cat /run/desktop-init.pid)
    xorg=$(podman exec desktop pgrep -x Xorg | sed -n 1p || true)
    mwm=$(podman exec desktop pgrep -u desktop -x mwm | sed -n 1p || true)
    [ -n "$xorg" ] && [ -n "$mwm" ] || fail "no Xorg or mwm in the session"
    ev_save pids-before "EV-PIDS: desktop-init, Xorg and mwm before mwm gets a SIGTERM" \
        ps -o pid,ppid,sess,lstart,comm -p "$init,$xorg,$mwm" >/dev/null || true
    p_before=$EV_LAST
    n_lines=$(podman logs desktop 2>&1 | wc -l)
    podman exec -u desktop desktop pkill -TERM -u desktop -x mwm || fail "no mwm to send SIGTERM to"
    ev_note "mwm (pid $mwm) sent SIGTERM, kill's default, as the session user at $(date -u +%Y-%m-%dT%H:%M:%S.%3NZ)"
    xn() { local p; p=$(podman exec desktop pgrep -x Xorg 2>/dev/null | sed -n 1p || true); [ -n "$p" ] && [ "$p" != "$xorg" ] && session_up; }
    wait_for 45 1 "a new X session (a new Xorg and mwm)" xn
    wait_for 15 1 "the display to answer" x_answers
    ev_note "a new Xorg and mwm up, the display answering, at $(date -u +%Y-%m-%dT%H:%M:%S.%3NZ)"
    xorg2=$(podman exec desktop pgrep -x Xorg | sed -n 1p || true)
    mwm2=$(podman exec desktop pgrep -u desktop -x mwm | sed -n 1p || true)
    ev_save pids-after "EV-PIDS: desktop-init, Xorg and mwm after the new session came up" \
        ps -o pid,ppid,sess,lstart,comm -p "$init,$xorg2,$mwm2" >/dev/null || true
    ev_diff pids "EV-DIFF: desktop-init, Xorg and mwm across mwm's exit (Xorg and mwm new, desktop-init the same)" "$p_before" "$EV_LAST"
    ev_save log "EV-LOG-DESKTOP: podman logs desktop from mwm's SIGTERM on" \
        sh -c "podman logs desktop 2>&1 | tail -n +$((n_lines + 1))" >/dev/null || true
    since=$(podman logs desktop 2>&1 | tail -n +$((n_lines + 1)) | tr -d '\r' || true)
    grep -q '^desktop-init: session exited (rc=0); restarting in 3s' <<<"$since" \
        || fail "desktop-init did not log a clean end after mwm's exit: no 'session exited (rc=0); restarting in 3s'"
    ! grep -q '^postmortem:' <<<"$since" || fail "a postmortem ran for mwm's clean exit"
    ev_pass "desktop-init logged 'session exited (rc=0); restarting in 3s', a clean end, and ran no postmortem"
    [ -n "$xorg2" ] && [ "$xorg2" != "$xorg" ] && [ -n "$mwm2" ] && [ "$mwm2" != "$mwm" ] \
        || fail "Xorg and mwm are not new: Xorg $xorg -> $xorg2, mwm $mwm -> $mwm2"
    [ "$(podman exec desktop cat /run/desktop-init.pid)" = "$init" ] || fail "desktop-init changed across mwm's exit"
    ev_pass "a new session: Xorg $xorg -> $xorg2, mwm $mwm -> $mwm2, under the same desktop-init ($init); the display answers"
    ev_end
}

# S2.2.2 and S5.8.4: the desktop with no host session unit. Neither of
# systemctl's ways of switching a unit off does it here. disable is not
# enough: desktop.container's Wants= starts desktop-session with the
# desktop, and S5.8.4 shows that first. mask is refused: the unit file is the
# tree's own, at /etc/systemd/system/desktop-session.service, where mask
# would have to put its /dev/null link. So the unit file is moved aside, as
# on a host without it. logind then takes /run/user/61000 away once the user
# has no session, and desktop-init, after waiting for it, makes it itself.
# "off" puts the unit back as the tree ships it, its multi-user.target.wants
# link relative, as rsync left it.
SESSION_UNIT=/etc/systemd/system/desktop-session.service
SESSION_AWAY=/etc/systemd/ev-desktop-session.service.away
SESSION_WANTS=/etc/systemd/system/multi-user.target.wants/desktop-session.service
standalone_desktop() { # on|off
    local st dlog ln out rc
    case "${1:-}" in
        on)
            ev_begin S5.8.4 "The desktop runs with the unit disabled" T3
            desk_down
            systemctl disable desktop-session.service >/dev/null 2>&1 || fail "systemctl disable desktop-session failed"
            ev_text disabled "EV-STATE: desktop-session after systemctl disable, the desktop stopped" \
                "is-enabled: $(systemctl is-enabled desktop-session.service 2>&1 || true)
is-active: $(systemctl is-active desktop-session.service 2>&1 || true)
$SESSION_WANTS: $(ls -l "$SESSION_WANTS" 2>&1 || true)"
            systemctl start desktop.service
            desk_back
            st=$(systemctl is-active desktop-session.service || true)
            dlog=$(podman logs desktop 2>&1 | tr -d '\r' || true)
            ln=$(grep '^desktop-init: .*runtime dir\|^desktop-init: no host login session' <<<"$dlog" || true)
            ev_text disabled-started "EV-STATE: desktop-session and desktop-init's runtime-dir line after the desktop started with the unit disabled" \
                "is-enabled: $(systemctl is-enabled desktop-session.service 2>&1 || true)
is-active: $st
$ln"
            [ "$st" = active ] || fail "disabled, desktop-session stayed down when the desktop started: disabling would be enough"
            grep -q 'runtime dir /run/user/61000 provided by the host login session' <<<"$ln" \
                || fail "with desktop-session disabled, desktop-init did not get the host's runtime dir: $ln"
            ev_pass "disabled, desktop-session still came up with the desktop (desktop.container's Wants=), and the runtime dir was the host's: disabling is not enough"
            desk_down
            rc=0
            out=$(systemctl mask desktop-session.service 2>&1) || rc=$?
            ev_text mask "EV-STATE: systemctl mask desktop-session, the unit file being the tree's own in /etc/systemd/system" \
                "$ ls -l $SESSION_UNIT
$(ls -l "$SESSION_UNIT" 2>&1)
$ systemctl mask desktop-session.service
$out
[exit $rc]"
            if [ "$rc" = 0 ]; then
                systemctl unmask desktop-session.service >/dev/null 2>&1 || true
                ev_note "systemctl mask succeeded and was undone; the unit file is moved aside below all the same"
            else
                ev_pass "systemctl mask is refused (exit $rc): the unit file is the tree's own, at the path mask's /dev/null link would take"
            fi
            [ -f "$SESSION_UNIT" ] || fail "$SESSION_UNIT is not a regular file"
            mv "$SESSION_UNIT" "$SESSION_AWAY"
            systemctl daemon-reload
            wait_for 40 1 "logind to take /run/user/61000 away" sh -c '! test -d /run/user/61000'
            ev_text away "EV-STATE: the unit file moved aside, the desktop stopped, and the host's runtime dir gone" \
                "$(ls -l "$SESSION_AWAY" 2>&1)
systemctl status desktop-session: $(systemctl show -p LoadState,ActiveState desktop-session.service 2>&1 | paste -sd' ' -)
loginctl list-sessions:
$(loginctl list-sessions --no-pager 2>&1)
/run/user/61000: $(ls -ld /run/user/61000 2>&1 || true)"
            ev_end

            ev_begin S2.2.2 "Standalone fallback fabricates the runtime dir" T3
            systemctl start desktop.service
            desk_back
            st=$(systemctl show -p LoadState --value desktop-session.service)
            [ "$st" = not-found ] || fail "desktop-session is still known to systemd: LoadState $st"
            dlog=$(podman logs desktop 2>&1 | tr -d '\r' || true)
            ev_text log "EV-LOG-DESKTOP: desktop-init's lines and the audio stack's start, with no desktop-session unit" \
                "$(grep '^desktop-init: \|^start-audio: ' <<<"$dlog" | head -20)"
            grep -q '^desktop-init: no host login session appeared; creating /run/user/61000 standalone' <<<"$dlog" \
                || fail "desktop-init did not log 'no host login session appeared; creating /run/user/61000 standalone'"
            ev_pass "desktop-init logged 'no host login session appeared; creating /run/user/61000 standalone'"
            ev_save runtime-dir "EV-STATE: /run/user/61000 in the container (made by desktop-init) and on the host (no logind mount)" \
                sh -c 'podman exec desktop stat -c "container: %n %A %U:%G" /run/user/61000; findmnt /run/user/61000 || echo "host: no mount at /run/user/61000"' >/dev/null || true
            [ "$(podman exec desktop stat -c '%a %U:%G' /run/user/61000)" = "700 desktop:desktop" ] \
                || fail "/run/user/61000 is $(podman exec desktop stat -c '%a %U:%G' /run/user/61000), not 700 desktop:desktop"
            ! mountpoint -q /run/user/61000 || fail "/run/user/61000 is a mount point: logind's, not desktop-init's"
            ev_pass "/run/user/61000 is 0700 desktop:desktop and no mount: desktop-init made it"
            wait_for 30 2 "the audio export" audio_reachable
            ev_save export "EV-STATE: the exported sockets and pactl info over them, from the host" \
                sh -c 'ls -l /run/desktop-audio; PULSE_SERVER=unix:/run/desktop-audio/pulse pactl info' >/dev/null || true
            ev_pass "the audio export answers: $(PULSE_SERVER=unix:/run/desktop-audio/pulse pactl info 2>/dev/null | sed -n 's/^Server Name: //p')"
            x_answers || fail "the display does not answer"
            ev_pass "X answers and the session's mwm runs, with no host login session"
            ev_end

            ev_begin S5.8.4 "The desktop runs with the unit disabled" T3
            ev_text running "EV-STATE: the desktop with no desktop-session unit" \
                "desktop-session: $(systemctl show -p LoadState,ActiveState desktop-session.service 2>&1 | paste -sd' ' -)
desktop.service: $(systemctl is-active desktop.service 2>&1 || true)"
            [ "$(systemctl is-active desktop.service)" = active ] || fail "desktop.service is not active"
            ev_pass "without the session unit the desktop runs: X answers and the audio export answers (S2.2.2 has the runtime dir)"
            ev_end
            ;;
        off)
            ev_begin S2.2.2 "Standalone fallback fabricates the runtime dir" T3
            desk_down
            # desktop-init's directory, not logind's: a desktop starting with
            # it there would take it for the host's before logind mounted
            # the real one over it.
            mountpoint -q /run/user/61000 || rm -rf /run/user/61000
            [ -f "$SESSION_AWAY" ] && mv "$SESSION_AWAY" "$SESSION_UNIT"
            [ -L "$SESSION_WANTS" ] || ln -s ../desktop-session.service "$SESSION_WANTS"
            systemctl daemon-reload
            systemctl start desktop.service
            desk_back
            wait_for 30 1 "desktop-session active again" systemctl is-active --quiet desktop-session.service
            dlog=$(podman logs desktop 2>&1 | tr -d '\r' || true)
            grep -q 'runtime dir /run/user/61000 provided by the host login session' <<<"$dlog" \
                || fail "back with desktop-session, desktop-init did not get the host's runtime dir"
            [ "$(systemctl is-enabled desktop-session.service)" = enabled ] || fail "desktop-session is not enabled again"
            mountpoint -q /run/user/61000 || fail "/run/user/61000 is not logind's mount again"
            ev_text restored "EV-STATE: desktop-session back as the tree ships it" \
                "is-enabled: $(systemctl is-enabled desktop-session.service 2>&1), is-active: $(systemctl is-active desktop-session.service 2>&1)
$(ls -l "$SESSION_UNIT" "$SESSION_WANTS" 2>&1)
$(findmnt /run/user/61000 2>&1)
$(grep 'runtime dir' <<<"$dlog")"
            ev_pass "the unit back, desktop-session runs again and /run/user/61000 is logind's again"
            ev_end
            ;;
        *) fail "standalone: on or off" ;;
    esac
}

# S3.8.6: a device attached to another seat. The USB keyboard (kvmkbd, which
# the host types through) goes to seat1 with loginctl attach, as an operator
# splitting seats would; a desktop started then warns. seat-prep runs with
# the desktop stopped, as at boot (Before=desktop.service); its gate would
# otherwise see the desktop's own hold on card0 and the VT.
kbd_sys() { # the USB keyboard's inputN directory
    local d
    for d in /sys/class/input/input*; do
        [ "$(cat "$d/name" 2>/dev/null)" = "QEMU QEMU USB Keyboard" ] && { readlink -f "$d"; return 0; }
    done
    return 1
}
kbd_event() { local e; e=$(ls -d "$1"/event* 2>/dev/null | head -n1); [ -n "$e" ] && echo "/dev/input/${e##*/}"; }
kbd_udev() { udevadm info "$1"; echo; udevadm info "$(kbd_event "$1")"; }
foreign_tags() { grep -hE '^E:ID_SEAT=' /run/udev/data/* 2>/dev/null | grep -v '=seat0$' | sort -u || true; }
# The same, entry by entry: the udev database file of each device tagged for
# another seat (the container preflight reads these files), and its seat.
foreign_entries() {
    grep -HE '^E:ID_SEAT=' /run/udev/data/* 2>/dev/null | grep -v '=seat0$' \
        | sed 's|^/run/udev/data/||; s|:E:ID_SEAT=| ID_SEAT=|' || true
}
seat_tags() { # attach|fix
    local sys ev b j0 j pf
    sys=$(kbd_sys) || fail "no 'QEMU QEMU USB Keyboard' input device on the VM host"
    ev=$(kbd_event "$sys")
    [ -n "$ev" ] || fail "the USB keyboard ($sys) has no event node"
    ev_begin S3.8.6 "Foreign seat tags are detected and undone" T3
    case "${1:-}" in
        attach)
            [ -z "$(ls /etc/udev/rules.d/72-seat-*.rules 2>/dev/null)" ] || fail "a 72-seat-*.rules is already there"
            ev_save rules-before "EV-STATE: ls -l /etc/udev/rules.d before: no 72-seat-* rule" ls -l /etc/udev/rules.d >/dev/null || true
            ev_save udev-before "EV-STATE: udevadm info of the USB keyboard ($sys) and its event node ($ev) before" kbd_udev "$sys" >/dev/null || true
            b=$EV_LAST
            loginctl attach seat1 "$sys" || fail "loginctl attach seat1 $sys failed"
            udevadm settle --timeout=15 || true
            ev_save rule "EV-CONFIG: the rule loginctl attach wrote" \
                sh -c 'for f in /etc/udev/rules.d/72-seat-*.rules; do echo "== $f"; cat "$f"; done' >/dev/null || true
            ev_save udev-attached "EV-STATE: udevadm info of the keyboard after loginctl attach seat1" kbd_udev "$sys" >/dev/null || true
            ev_diff udev-attach "EV-DIFF: udevadm info across loginctl attach seat1 (ID_SEAT=seat1 appears)" "$b" "$EV_LAST"
            udevadm info -q property -n "$ev" | grep -qx 'ID_SEAT=seat1' || fail "$ev is not tagged ID_SEAT=seat1 after loginctl attach"
            ev_save tagged-attached "EV-STATE: every udev database entry tagged for a seat other than seat0, after loginctl attach seat1: the keyboard's input device and the devices under it" \
                foreign_entries >/dev/null || true
            ev_pass "loginctl attach seat1 tagged the keyboard: $ev reads ID_SEAT=seat1 ($(foreign_tags | paste -sd' ' -) in the udev database)"
            systemctl restart desktop.service
            desk_back
            pf=$(podman logs desktop 2>&1 | tr -d '\r' | grep '^preflight: .*seat' || true)
            ev_text preflight "EV-LOG-DESKTOP: the container preflight's seat line, the desktop restarted with the keyboard on seat1" "${pf:-(none)}"
            grep -q '^preflight: WARN: devices tagged for a non-default seat (E:ID_SEAT=seat1' <<<"$pf" \
                || fail "the preflight did not warn about the seat1 tag: ${pf:-no seat line}"
            ev_pass "the preflight warns: $pf"
            ;;
        fix)
            desk_down
            j0=$(ev_since)
            systemctl restart desktop-seat-prep.service \
                || fail "desktop-seat-prep failed: $(journalctl --no-pager -o cat -u desktop-seat-prep.service --since "$j0" | tail -5)"
            j=$(ev_save seat-prep-journal "EV-LOG-JOURNAL: journalctl -u desktop-seat-prep from its restart, the desktop stopped" \
                journalctl --no-pager -o short-iso -u desktop-seat-prep.service --since "$j0") || true
            grep -q 'seat-prep: removing custom seat attachment rule /etc/udev/rules.d/72-seat-' <<<"$j" \
                || fail "seat-prep did not log removing the 72-seat-* rule"
            ev_pass "seat-prep logged: $(grep -o 'seat-prep: removing custom seat attachment rule [^ ]*' <<<"$j" | head -n1)"
            ev_save rules-after "EV-STATE: ls -l /etc/udev/rules.d after seat-prep: no 72-seat-* rule" ls -l /etc/udev/rules.d >/dev/null || true
            [ -z "$(ls /etc/udev/rules.d/72-seat-*.rules 2>/dev/null)" ] || fail "a 72-seat-*.rules is still there after seat-prep"
            ev_save udev-after "EV-STATE: udevadm info of the keyboard after seat-prep" kbd_udev "$sys" >/dev/null || true
            ev_save tagged-after "EV-STATE: every udev database entry tagged for a seat other than seat0, after seat-prep: none" \
                foreign_entries >/dev/null || true
            ! udevadm info -q property -n "$ev" | grep -q '^ID_SEAT=' || fail "$ev still carries $(udevadm info -q property -n "$ev" | grep '^ID_SEAT=')"
            [ -z "$(foreign_tags)" ] || fail "the udev database still has a foreign seat tag: $(foreign_entries | paste -sd' ' -)"
            ev_pass "the rule is gone and udev re-read the keyboard: $ev has no ID_SEAT, and no device in the udev database is tagged for another seat"
            systemctl start desktop.service
            desk_back
            pf=$(podman logs desktop 2>&1 | tr -d '\r' | grep '^preflight: .*seat' || true)
            ev_text preflight-after "EV-LOG-DESKTOP: the container preflight's seat line after seat-prep, the desktop started again" "${pf:-(none)}"
            grep -qx 'preflight: PASS: no foreign seat tags in the udev database' <<<"$pf" \
                || fail "the preflight does not pass the seat check after seat-prep: ${pf:-no seat line}"
            ev_pass "the preflight passes: $pf"
            ;;
        *) fail "seat-tags: attach or fix" ;;
    esac
    ev_end
}

# S4.2.1-S4.2.3: the host's own clients, as the unprivileged rocky user with
# a clean environment. EL9's libpulse does not autospawn unless asked
# (autospawn = yes): S4.2.1's autospawn check asks for it in a private mount
# namespace, the export hidden, so that the drop-in's autospawn = no is what
# stands between a client and a spawned daemon; a stub /usr/bin/pulseaudio
# records every start. alsa-plugins-pulseaudio ships its own
# 99-pulseaudio-default.conf, a server-less pcm.!default, so the ALSA checks
# keep libpulse's own default server out (an empty client config) and show
# that the deploy tree's drop-in alone routes ALSA to the export.
# runuser first: it is in /usr/sbin, outside the clean PATH.
ROCKY="runuser -u rocky -- env -i HOME=/home/rocky USER=rocky PATH=/usr/bin:/bin"
PA_STUB=/usr/bin/pulseaudio
pa_stub_install() {
    if [ -e "$PA_STUB" ] && ! grep -q 'ev-stub' "$PA_STUB" 2>/dev/null; then
        mv "$PA_STUB" "$PA_STUB.ev-real"
    fi
    printf '#!/bin/sh\n# ev-stub: records a start and refuses it (Requirements.md S4.2.1)\necho "$(date -u +%%Y-%%m-%%dT%%H:%%M:%%SZ) uid=$(id -u) $0 $*" >> "${EV_PA_LOG:-/run/ev-pulseaudio-starts.log}"\nexit 1\n' > "$PA_STUB"
    chmod 755 "$PA_STUB"
    : > /run/ev-pulseaudio-starts.log
    chmod 666 /run/ev-pulseaudio-starts.log
}
pa_stub_remove() {
    if grep -q 'ev-stub' "$PA_STUB" 2>/dev/null; then rm -f "$PA_STUB"; fi
    [ -e "$PA_STUB.ev-real" ] && mv "$PA_STUB.ev-real" "$PA_STUB"
    return 0
}
ALSA_DROPIN=/etc/alsa/conf.d/99-zz-desktop-container.conf
host_audio() { # pulse-play|autospawn|alsa-setup|alsa-play|alsa-control|null-on|null-play|null-off|cleanup
    local out pkgs
    case "${1:-}" in
        pulse-play) # S4.2.1, printed for the host, which captures around it
            gen_tone 440 /tmp/s421.wav 3
            chmod 644 /tmp/s421.wav
            pa_stub_install
            echo "== the drop-in, /etc/pulse/client.conf.d/50-desktop-container.conf"
            cat /etc/pulse/client.conf.d/50-desktop-container.conf
            echo "== env | grep PULSE, as rocky"
            $ROCKY env | grep '^PULSE' || echo "(none)"
            echo "== paplay of a 440 Hz tone, as rocky, no PULSE_SERVER"
            $ROCKY paplay /tmp/s421.wav; echo "paplay exited $?"
            echo "== pgrep -a pulseaudio"
            pgrep -a pulseaudio || echo "(none)"
            echo "== the stub's record of starts"
            cat /run/ev-pulseaudio-starts.log
            echo "(end of record)"
            ;;
        autospawn) # S4.2.1's guest half
            ev_begin S4.2.1 "Host Pulse clients are routed to the container" T3
            pa_stub_install
            cp /etc/pulse/client.conf /run/ev-s421-client.conf
            echo 'autospawn = yes' >> /run/ev-s421-client.conf
            # rocky's stub writes these: /run is root's.
            : > /run/ev-pa-dropin.log
            : > /run/ev-pa-control.log
            chmod 666 /run/ev-pa-dropin.log /run/ev-pa-control.log
            out=$(ev_save autospawn "EV-STATE: rocky's pactl info (PULSE_LOG=4) in a private mount namespace: the export hidden under an empty tmpfs, /etc/pulse/client.conf with autospawn = yes appended; first with the deploy tree's drop-in, then with /etc/pulse/client.conf.d hidden too. Each run's stub record follows it" \
                unshare -m --propagation private sh -c '
                    mount -t tmpfs -o mode=755 ev-s421 /run/desktop-audio
                    mount --bind /run/ev-s421-client.conf /etc/pulse/client.conf
                    echo "== with the drop-in"
                    '"$ROCKY"' EV_PA_LOG=/run/ev-pa-dropin.log PULSE_LOG=4 pactl info; echo "pactl exited $?"
                    echo "== starts recorded with the drop-in:"; cat /run/ev-pa-dropin.log 2>/dev/null; echo "(end of record)"
                    mount -t tmpfs -o mode=755 ev-s421-hidden /etc/pulse/client.conf.d
                    echo "== control, the drop-in hidden"
                    '"$ROCKY"' EV_PA_LOG=/run/ev-pa-control.log PULSE_LOG=4 pactl info; echo "pactl exited $?"
                    echo "== starts recorded without the drop-in:"; cat /run/ev-pa-control.log 2>/dev/null; echo "(end of record)"') || true
            [ -s /run/ev-pa-control.log ] \
                || fail "the control did not autospawn: with autospawn = yes and no drop-in, libpulse never ran the stub, so this check could not fail"
            ev_pass "control: with autospawn = yes, the export hidden and no drop-in, rocky's pactl ran the stub: $(head -n1 /run/ev-pa-control.log)"
            [ ! -s /run/ev-pa-dropin.log ] || fail "with the drop-in, libpulse still autospawned: $(head -n1 /run/ev-pa-dropin.log)"
            grep -q 'Trying to connect to unix:/run/desktop-audio/pulse' <<<"$out" || fail "with the drop-in, libpulse did not try the export first"
            ev_pass "with the deploy tree's drop-in, the same client tried only unix:/run/desktop-audio/pulse and spawned nothing: its autospawn = no wins over client.conf's yes"
            rm -f /run/ev-pa-dropin.log /run/ev-pa-control.log /run/ev-s421-client.conf
            ev_end
            ;;
        alsa-setup) # S4.2.2's packages and drop-ins, guest half
            ev_begin S4.2.2 "Host ALSA clients are routed through the pulse plugin" T3
            pkgs="alsa-utils alsa-plugins-pulseaudio"
            # shellcheck disable=SC2086
            rpm -q $pkgs >/dev/null 2>&1 || dnf -y -q install $pkgs >/dev/null 2>&1 || dnf -y -q install $pkgs >/dev/null \
                || fail "could not install $pkgs on the VM host"
            # shellcheck disable=SC2086
            ev_save packages "EV-STATE: the probe's packages on the VM host" rpm -q $pkgs >/dev/null || true
            ev_save conf-d "EV-CONFIG: /etc/alsa/conf.d, in the order alsa-lib loads it (the last pcm.!default wins), and each file" \
                sh -c 'ls -l /etc/alsa/conf.d; for f in /etc/alsa/conf.d/*.conf; do echo "== $f"; grep -v "^#" "$f" | grep .; done' >/dev/null || true
            [ -f "$ALSA_DROPIN" ] || fail "$ALSA_DROPIN is not installed"
            [ "$(ls /etc/alsa/conf.d/*.conf | tail -n1)" = "$ALSA_DROPIN" ] \
                || fail "$ALSA_DROPIN does not load last in /etc/alsa/conf.d: $(ls /etc/alsa/conf.d/*.conf | tail -n1) does"
            ev_pass "the deploy tree's drop-in loads last in /etc/alsa/conf.d, after alsa-plugins-pulseaudio's own 99-pulseaudio-default.conf"
            gen_tone 1320 /tmp/s422.wav 3
            chmod 644 /tmp/s422.wav
            : > /run/ev-empty-client.conf
            chmod 644 /run/ev-empty-client.conf
            ev_end
            ;;
        alsa-play) # S4.2.2, printed for the host, which captures around it
            echo "== aplay of a 1320 Hz tone, as rocky, libpulse with no default server of its own (PULSE_CLIENTCONFIG=/run/ev-empty-client.conf)"
            $ROCKY PULSE_CLIENTCONFIG=/run/ev-empty-client.conf aplay /tmp/s422.wav; echo "aplay exited $?"
            echo "== amixer info, the same way"
            $ROCKY PULSE_CLIENTCONFIG=/run/ev-empty-client.conf amixer info; echo "amixer exited $?"
            echo "== amixer, the same way"
            $ROCKY PULSE_CLIENTCONFIG=/run/ev-empty-client.conf amixer; echo "amixer exited $?"
            ;;
        alsa-control) # S4.2.2's control, guest half
            ev_begin S4.2.2 "Host ALSA clients are routed through the pulse plugin" T3
            out=$(ev_save control "EV-STATE: control: the same aplay with the deploy tree's drop-in hidden (/dev/null bound over it in a private mount namespace), alsa-plugins-pulseaudio's default left" \
                unshare -m --propagation private sh -c '
                    mount --bind /dev/null '"$ALSA_DROPIN"'
                    '"$ROCKY"' PULSE_CLIENTCONFIG=/run/ev-empty-client.conf aplay /tmp/s422.wav; echo "aplay exited $?"') || true
            if grep -q '^aplay exited 0$' <<<"$out"; then
                fail "with the drop-in hidden, aplay still played: the check above cannot tell the drop-in's routing from libpulse's"
            fi
            ev_pass "control: with the drop-in hidden, the same aplay fails ($(grep -m1 'error' <<<"$out" || grep '^aplay exited' <<<"$out")): the routing above is the drop-in's"
            ev_end
            ;;
        null-on) # S4.2.3
            ev_begin S4.2.3 "A host-local asound.conf still wins" T3
            [ ! -e /etc/asound.conf ] || cp -a /etc/asound.conf /etc/asound.conf.ev-saved
            printf 'pcm.!default {\n    type null\n}\n' > /etc/asound.conf
            ev_copy /etc/asound.conf asound-conf "EV-CONFIG: the host-local /etc/asound.conf: default routed to null"
            ev_end
            ;;
        null-play) # S4.2.3, printed for the host, which captures around it
            echo "== aplay -D default of a 1320 Hz tone, as rocky; /etc/asound.conf: $(ls -l /etc/asound.conf 2>&1)"
            $ROCKY PULSE_CLIENTCONFIG=/run/ev-empty-client.conf aplay -D default /tmp/s422.wav; echo "aplay exited $?"
            ;;
        null-off) # S4.2.3
            ev_begin S4.2.3 "A host-local asound.conf still wins" T3
            rm -f /etc/asound.conf
            [ -e /etc/asound.conf.ev-saved ] && mv /etc/asound.conf.ev-saved /etc/asound.conf
            ev_text removed "EV-STATE: /etc/asound.conf after the test" "$(ls -l /etc/asound.conf 2>&1 || true)"
            ev_end
            ;;
        cleanup)
            pa_stub_remove
            rm -f /run/ev-pulseaudio-starts.log /run/ev-empty-client.conf /tmp/s421.wav /tmp/s422.wav
            ;;
        *) fail "host-audio: pulse-play, autospawn, alsa-setup, alsa-play, alsa-control, null-on, null-play, null-off or cleanup" ;;
    esac
}

# --- k3s on CRI-O: phase2's node, and the maintainer's (maint-guest.sh) ---------
# Client pods reach the display through CDI, which only the CRI resolves - so
# k3s runs on an EXTERNAL CRI-O instead of the bundled containerd. CRI-O scans
# /etc/cdi, which is where the specs live. In three steps, so that a caller
# loads images into the storage CRI-O shares with podman, and writes its own
# crio.conf.d drop-ins (the cdi_spec_dirs one: phase2's, or README.md's
# block), after the package and before CRI-O first starts.
k8s_crio_pkg() { # <log tag>
    log "$1" "install CRI-O ${CRIO_VERSION} (the documented runtime for CDI clients)"
    cat > /etc/yum.repos.d/cri-o.repo <<EOF
[cri-o]
name=CRI-O ${CRIO_VERSION}
baseurl=https://pkgs.k8s.io/addons:/cri-o:/stable:/${CRIO_VERSION}/rpm/
enabled=1
gpgcheck=1
gpgkey=https://pkgs.k8s.io/addons:/cri-o:/stable:/${CRIO_VERSION}/rpm/repodata/repomd.xml.key
EOF
    dnf -y -q install cri-o >/dev/null
}
k8s_crio_start() {
    # k3s writes its flannel CNI config + plugin binaries under its own tree,
    # not CRI-O's default /etc/cni/net.d + /opt/cni/bin. Point CRI-O at k3s's
    # dirs so the pod network comes up (else kubelet stays NetworkNotReady).
    mkdir -p /etc/crio/crio.conf.d
    cat > /etc/crio/crio.conf.d/11-k3s-cni.conf <<'EOF'
[crio.network]
network_dir = "/var/lib/rancher/k3s/agent/etc/cni/net.d"
plugin_dirs = ["/var/lib/rancher/k3s/data/current/bin", "/opt/cni/bin"]
EOF
    systemctl enable --now crio >/dev/null 2>&1 \
        || { journalctl -u crio --no-pager -o cat 2>/dev/null | tail -20 >&2 || true
             fail "crio failed to start (bad crio.conf.d drop-in?)"; }
    wait_for 30 2 "crio socket" test -S /run/crio/crio.sock
}
k8s_k3s() { # <log tag>
    log "$1" "install k3s driving the external CRI-O (kubelet cgroup driver = systemd to match)"
    # On an enforcing EL host k3s needs its own policy module: its tree under
    # /var/lib/rancher and its agent processes are not covered by stock
    # container-selinux (which is what CRI-O and the client pods rely on).
    # The installer is supposed to detect enforcing SELinux and pull
    # k3s-selinux from rpm.rancher.io itself, so INSTALL_K3S_SKIP_SELINUX_RPM
    # is deliberately NOT set - but that is the INSTALLER's behaviour, not
    # ours, and it is exactly the kind of thing that changes upstream without
    # us noticing. Assert the result below rather than trusting it.
    #
    # Output goes to a file rather than /dev/null: a policy install that failed
    # or was skipped explains itself there, and discarding it is why this was
    # unverifiable in the first place.
    if ! curl -sfL https://get.k3s.io | INSTALL_K3S_EXEC="\
        --container-runtime-endpoint=unix:///run/crio/crio.sock \
        --kubelet-arg=cgroup-driver=systemd \
        --disable traefik --disable metrics-server" sh - >/tmp/k3s-install.log 2>&1
    then
        tail -40 /tmp/k3s-install.log >&2 || true
        fail "k3s install failed (see output above)"
    fi

    log "$1" "k3s brought its own SELinux policy module (required on an enforcing EL host)"
    if semodule -l 2>/dev/null | grep -qi '^k3s'; then
        log "$1" "  policy module loaded: $(semodule -l | grep -i '^k3s' | tr '\n' ' ')"
        rpm -q k3s-selinux >/dev/null 2>&1 && log "$1" "  from $(rpm -q k3s-selinux)"
    else
        echo "---- selinux lines from the k3s installer ----" >&2
        grep -i selinux /tmp/k3s-install.log >&2 || echo "(none)" >&2
        echo "---- loaded policy modules ----" >&2
        semodule -l 2>/dev/null | tail -20 >&2 || true
        fail "no k3s SELinux policy module loaded - the installer skipped it, and k3s is unconfined-by-omission on an enforcing host"
    fi
    wait_for 60 5 "k3s node ready" \
        sh -c "k3s kubectl get nodes | grep -q ' Ready'"
    # Prove the node really runs CRI-O, not the bundled containerd.
    k3s kubectl get node -o jsonpath='{.items[0].status.nodeInfo.containerRuntimeVersion}' \
        | grep -q cri-o || fail "node runtime is not cri-o"

    curl -fsSL https://get.helm.sh/helm-v3.16.4-linux-amd64.tar.gz \
        | tar -xz -C /usr/local/bin --strip-components=1 linux-amd64/helm

    export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
}

phase2() {
    # The quadlet desktop stays UP for the whole of this phase, and that is
    # the point: kubernetes here carries application containers, never the
    # desktop. Nothing contends for the VT or DRM master, because only one
    # thing on this host ever runs an X server.
    systemctl is-active --quiet desktop.service \
        || fail "desktop.service is not running - phase2 tests clients against the quadlet desktop"

    # This phase runs ENFORCING, like phase-deploy. It used to drop the host to
    # permissive, which meant the entire kubernetes client path - the half of
    # this design kubernetes actually carries - was never exercised the way it
    # ships. The client pods below declare no securityContext at all, so they
    # are confined container_t: they reach this desktop only because
    # desktop-selinux labeled the export dirs container_file_t, at level s0
    # with no MCS categories (CRI-O gives each pod its own category pair, and
    # the empty set is a subset of every set). If that labeling regresses,
    # these pods fail here rather than on someone's server.
    log p2 "SELinux must stay enforcing: the k8s client path ships this way"
    [ "$(getenforce)" = Enforcing ] || fail "SELinux is not enforcing"

    # S7.3.7: the desktop must come through CRI-O's and k3s's arrival
    # untouched - the same processes, not just an active unit and an X socket
    # file, which a restarted desktop would show as well. The story stays
    # open across the install, so a failure there is its failure too.
    ev_begin S7.3.7 "The desktop survives CRI-O and k3s arriving" T3
    s737_before=$(ctr_pids "$S737_COMMS") || fail "could not list the desktop's processes before the install"
    ev_text pids-before "EV-PIDS: the desktop's processes before CRI-O and k3s are installed: ps -o pid,ppid,lstart,comm -C $S737_COMMS, in the desktop container" "$s737_before"
    s737_before_f=$EV_LAST
    for c in desktop-init Xorg mwm pipewire; do
        grep -qw -- "$c" <<<"$s737_before" || fail "no $c among the desktop's processes before the install"
    done
    ev_pass "before the install: desktop-init, Xorg, mwm and pipewire are running"

    # Client pods reach the display through CDI, which only the CRI
    # resolves - so this phase runs k3s on an EXTERNAL CRI-O (k8s_crio_pkg).
    k8s_crio_pkg p2

    # podman and CRI-O share /var/lib/containers/storage by default, so a root
    # `podman load` is visible to CRI-O - no ctr import or skopeo needed. Load
    # before starting crio to avoid concurrent writers to the storage.
    log p2 "load images into shared containers-storage"
    for t in desktop plugin testclient; do
        podman load -q -i "/tmp/images-$t.tar" >/dev/null
    done
    # Guard against tag/content mix-ups in the archive plumbing (a combined
    # podman-save archive once shipped the desktop image under BOTH tags).
    ddig=$(podman image inspect localhost/desktop-container:latest --format '{{.Id}}' 2>/dev/null || true)
    pdig=$(podman image inspect localhost/cdi-device-plugin:latest --format '{{.Id}}' 2>/dev/null || true)
    if [ -z "$ddig" ] || [ -z "$pdig" ] || [ "$ddig" = "$pdig" ]; then
        fail "image load broken: desktop='$ddig' plugin='$pdig' (must both exist and differ)"
    fi
    ep=$(podman image inspect localhost/cdi-device-plugin:latest \
        --format '{{index .Config.Entrypoint 0}}' || true)
    [ "$ep" = /cdi-device-plugin ] \
        || fail "plugin image has wrong entrypoint '$ep' - archive tag mix-up?"

    # Everything downstream depends on this file; assert it before k3s so a
    # missing spec fails here instead of as an opaque pod creation error.
    # phase-deploy's desktop-client-cdi.service wrote them and the tree is
    # still applied - only the quadlet unit was removed above.
    log p2 "both client CDI specs are on the node"
    grep -q 'kind: desktop.local/display' /etc/cdi/desktop-display.yaml \
        || fail "/etc/cdi/desktop-display.yaml missing or malformed before k3s install"
    grep -q 'kind: desktop.local/audio' /etc/cdi/desktop-audio.yaml \
        || fail "/etc/cdi/desktop-audio.yaml missing or malformed before k3s install"

    # Everything downstream rests on CRI-O scanning /etc/cdi. That IS the
    # default, but state it explicitly rather than depend on it: the default
    # does not appear in `crio config` output (the man page documents the
    # option as cdi_spec_dirs=[], with the real list applied internally), so
    # relying on it is both invisible and unverifiable from outside.
    # An unknown key here would stop crio starting, which k8s_crio_start
    # catches - a loud, immediate failure rather than a puzzling one later.
    mkdir -p /etc/crio/crio.conf.d
    cat > /etc/crio/crio.conf.d/12-cdi.conf <<'EOF'
[crio.runtime]
cdi_spec_dirs = ["/etc/cdi", "/var/run/cdi"]
EOF
    k8s_crio_start
    log p2 "crio configured to scan /etc/cdi for device specs"

    k8s_k3s p2

    # The desktop must have survived the CRI-O + k3s install unscathed: a
    # container runtime arriving on the node is exactly the kind of thing
    # that could disturb it, and everything below asserts against its display.
    systemctl is-active --quiet desktop.service \
        || fail "desktop.service died while k3s/CRI-O were installed"
    podman exec desktop test -S /tmp/.X11-unix/X0 \
        || fail "the desktop's X socket vanished during the k3s/CRI-O install"
    ev_pass "after the install desktop.service is active and the X socket is there"
    s737_after=$(ctr_pids "$S737_COMMS") || fail "could not list the desktop's processes after the install"
    ev_text pids-after "EV-PIDS: the desktop's processes after CRI-O and k3s were installed (the same ps)" "$s737_after"
    ev_diff pids "EV-DIFF: the desktop's processes before and after the install (no differences: the same processes, none restarted)" "$s737_before_f" "$EV_LAST"
    [ "$s737_after" = "$s737_before" ] \
        || fail "the desktop's processes changed while CRI-O and k3s were installed (see the diff)"
    ev_pass "the same desktop-init, Xorg, mwm and audio daemons before and after: pids and start times unchanged"
    ev_end
    log p2 "quadlet desktop still serving :0 alongside k3s"

    log p2 "deploy one plugin release per device; all three resources become allocatable"
    # Three releases, not one: kubelet's Register takes a single resource
    # name. The chart is generic - each release differs only in cdiDevice.
    #
    # tools is the odd one out. display and audio are capabilities (they carry
    # the sockets); tools only distributes binaries, and its spec exists only
    # because the desktop has already published a toolkit - see
    # desktop-tools-cdi. Its plugin is Healthy for the same reason the others
    # are: the spec file is present.
    for cap in display audio tools; do
        helm install "$cap" charts/cdi-device-plugin \
            --set image.repository=localhost/cdi-device-plugin --set image.pullPolicy=Never \
            --set "cdiDevice=desktop.local/$cap=all" --set count=10
    done
    # Registration is where enforcing SELinux bites the PLUGIN (as opposed to
    # its clients): it means connecting to kubelet's socket, which a confined
    # container may not do. The chart's seLinuxOptions.type=spc_t is what makes
    # this pass; without it the plugin serves its own socket fine and loops on
    # "connect: permission denied", so the only symptom is that the resource
    # never appears. fail() dumps the plugin logs, where that loop is plain to
    # see; the description here says where to look.
    for cap in display audio tools; do
        wait_for 30 4 "desktop.local/$cap allocatable (plugin registered with kubelet?)" \
            sh -c "k3s kubectl get node -o jsonpath='{.items[0].status.allocatable.desktop\.local/$cap}' | grep -q 10"
    done

    log p2 "the node really is enforcing and k3s did not relax it"
    [ "$(getenforce)" = Enforcing ] \
        || fail "something set SELinux permissive during the k3s/CRI-O install"

    log p2 "client pod schedules and opens xterm on the desktop"
    # The example pod declares only the resource request - no volumes, no
    # env - so it running an X client at all means the plugin named the CDI
    # device and CRI-O applied the spec.
    sed 's|image: desktop-container:latest|image: localhost/desktop-container:latest|' \
        examples/x11-client-pod.yaml | k3s kubectl apply -f -
    wait_for 30 4 "client pod running" \
        sh -c "k3s kubectl get pod x11-client-demo -o jsonpath='{.status.phase}' | grep -q Running"
    sleep 5

    # The pod must be CONFINED for any of this to have meant anything. If
    # CRI-O had handed it spc_t (privileged) the display would work no matter
    # how the host directories were labeled, and this phase would pass while
    # proving nothing. Read the type the kernel actually gave it.
    log p2 "the client pod runs confined, and reached the display anyway"
    ev_begin S7.3.3 "Pods are confined and declare no securityContext" T3
    ev_copy examples/x11-client-pod.yaml demo-manifest "EV-CONFIG: examples/x11-client-pod.yaml, which phase2 applies with only its image pointed at the locally loaded one: a resource request and nothing else - no securityContext, volumes, env or CDI annotation"
    ev_save demo-spec "EV-STATE: the demo pod as the API server holds it: the pod's securityContext ({} is the API server's empty default), the container's (empty), the volumes (the service-account token's, which the API server adds) and the container's env (empty)" \
        k3s kubectl get pod x11-client-demo -o jsonpath='pod securityContext: {.spec.securityContext}{"\n"}container securityContext: {.spec.containers[0].securityContext}{"\n"}volumes: {.spec.volumes[*].name}{"\n"}container env: {.spec.containers[0].env}{"\n"}' >/dev/null || true
    pctx=$(k3s kubectl exec x11-client-demo -- sh -c 'tr -d "\000" < /proc/self/attr/current' 2>/dev/null || true)
    ev_text demo-label "EV-STATE: /proc/self/attr/current read inside the demo pod: the SELinux context CRI-O gave it" "$pctx"
    case "$pctx" in
        *:container_t:*) log p2 "  client pod context: $pctx" ;;
        "") fail "could not read the client pod's SELinux context" ;;
        *) fail "client pod runs as '$pctx', not container_t - the confined path is untested" ;;
    esac
    ev_pass "the demo pod runs confined: $pctx"
    csc=$(k3s kubectl get pod x11-client-demo -o jsonpath='{.spec.containers[0].securityContext}')
    psc=$(k3s kubectl get pod x11-client-demo -o jsonpath='{.spec.securityContext}')
    [ -z "$csc" ] && { [ -z "$psc" ] || [ "$psc" = "{}" ]; } \
        || fail "the demo pod carries a securityContext: pod '$psc', container '$csc'"
    ev_pass "and declares no securityContext: none on the container, the pod's the API server's empty default"
    ev_end
    log p2 "phase2 passed"
}

gen_tone() { # $1: frequency Hz, $2: outfile (.wav -> WAV, else raw s16le), $3: seconds (1.5)
    # A stereo sine at 60% full scale, 1.5 s unless asked: audibly a beep in
    # the artifact, and unmistakably non-silent for the host-side check.
    python3 - "$1" "$2" "${3:-1.5}" <<'EOF'
import math, sys, wave
freq, out = float(sys.argv[1]), sys.argv[2]
rate, dur, amp = 44100, float(sys.argv[3]), 0.6
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
    podman exec desktop rm -f /tmp/audio-ok /tmp/audio-done
    # The xterm is the X11 app doing the playing. Its exit status does not
    # reliably reflect the -e command, so the inner script leaves a marker
    # only when the player succeeded, and another once it has finished.
    # The window then stays up for a few seconds saying so, which is when
    # the host takes its screenshot of it (S4.1.2's EV-SHOT): this returns
    # as soon as the player is done, not when the window closes.
    podman exec -d -u desktop -e DISPLAY=:0 -e HOME=/home/desktop \
        -e XDG_RUNTIME_DIR=/run/user/61000 desktop \
        timeout 60 xterm -T "audio-$path" -geometry 80x12+120+320 -e \
        sh -c "$player; rc=\$?; [ \$rc = 0 ] && touch /tmp/audio-ok; echo; echo \"$path player ($player) finished, exit \$rc\"; touch /tmp/audio-done; sleep 6"
    wait_for 120 0.5 "the $path player in its xterm to finish" podman exec desktop test -f /tmp/audio-done
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
        || fail "socket $1 missing or not writable in the requesting pod"
    log vp "socket $1 present + writable"
}

# A mountinfo's mount points and filesystem types, sorted: the fields that
# stay put between two pods (mount ids and devices do not). The type is the
# field after the " - " separator, whose place varies with the optional
# fields before it.
mount_points() {
    awk '{for (i = 7; i <= NF; i++) if ($i == "-") {print $5, $(i + 1); break}}' | sort
}

verify_cdi() {
    # S7.3.1: what the three releases offer, and what a requesting pod gets
    # against an identical pod that requests nothing.
    ev_begin S7.3.1 "Resources become allocatable, pods get injected edits" T3
    alloc=$(k3s kubectl get node -o jsonpath='{.items[0].status.allocatable}') \
        || fail "could not read the node's allocatable resources"
    ev_text allocatable "EV-STATE: the node's allocatable resources (kubectl get node -o jsonpath={.items[0].status.allocatable})" "$alloc"
    for cap in display audio tools; do
        grep -q "\"desktop.local/$cap\":\"10\"" <<<"$alloc" \
            || fail "desktop.local/$cap is not allocatable at 10: $alloc"
    done
    ev_pass "three releases, three resources: desktop.local/display, audio and tools allocatable at 10 each"
    ev_save plugin-logs "EV-LOG-CLIENT: the three plugin releases' logs (kubectl logs -l app.kubernetes.io/name=cdi-device-plugin --prefix): each registered with kubelet, serving its own CDI device" \
        k3s kubectl logs -l app.kubernetes.io/name=cdi-device-plugin --prefix --tail=40 >/dev/null || true

    log vp "apply verifier pod: requests desktop.local/display, declares nothing else"
    k3s kubectl apply -f ci/vm/cdi-verify-pod.yaml
    wait_for 30 4 "verifier pod running" \
        sh -c "k3s kubectl get pod $VPOD -o jsonpath='{.status.phase}' | grep -q Running"

    log vp "CDI injected the DISPLAY + audio env vars"
    assert_pod_env DISPLAY :0
    assert_pod_env PULSE_SERVER unix:/run/desktop-audio/pulse
    assert_pod_env PIPEWIRE_REMOTE /run/desktop-audio/pipewire-0
    ev_pass "the verifier pod has DISPLAY=:0, PULSE_SERVER=unix:/run/desktop-audio/pulse and PIPEWIRE_REMOTE=/run/desktop-audio/pipewire-0, none of which its manifest declares"

    log vp "the injected X socket is mounted and the display works"
    assert_pod_socket /tmp/.X11-unix/X0
    # sh -c so it uses the injected DISPLAY, not a hardcoded one; bounded so
    # a broken connection fails instead of hanging.
    timeout 20 k3s kubectl exec "$VPOD" -- sh -c 'xdpyinfo >/dev/null' \
        || fail "xdpyinfo could not open the display from the requesting pod"
    log vp "xdpyinfo opened :0 from the pod"
    ev_pass "its X socket /tmp/.X11-unix/X0 is mounted writable, and xdpyinfo opens :0 with the injected DISPLAY"
    venv=$(k3s kubectl exec "$VPOD" -- env | sort) || fail "could not read the verifier pod's environment"
    ev_text verify-env "EV-STATE: the verifier pod's environment (env, sorted)" "$venv"
    venv_f=$EV_LAST
    vmnt=$(k3s kubectl exec "$VPOD" -- cat /proc/self/mountinfo | mount_points) \
        || fail "could not read the verifier pod's mounts"
    ev_text verify-mounts "EV-STATE: the verifier pod's mounts: mount point and filesystem type from /proc/self/mountinfo, sorted" "$vmnt"
    vmnt_f=$EV_LAST

    # Negative control: without the resource request the SAME image gets
    # none of it. Without this, a stray hostPath or a baked-in env in the
    # desktop image would make every assertion above pass for the wrong
    # reason. (It is also what caught the annotation-only design silently
    # injecting nothing: there, verify and control behaved identically.)
    log vp "control: an identical pod WITHOUT the resource request gets nothing"
    k3s kubectl delete pod cdi-control --ignore-not-found >/dev/null 2>&1 || true
    # resources: is the last block in the manifest, so cutting from it to
    # EOF leaves an otherwise identical pod.
    sed -e 's/^  name: cdi-verify$/  name: cdi-control/' \
        -e '/^      resources:$/,$d' ci/vm/cdi-verify-pod.yaml \
        | k3s kubectl apply -f -
    wait_for 30 4 "control pod running" \
        sh -c "k3s kubectl get pod cdi-control -o jsonpath='{.status.phase}' | grep -q Running"
    cenv=$(k3s kubectl exec cdi-control -- env | sort) || fail "could not read the control pod's environment"
    ev_text control-env "EV-STATE: the control pod's environment - the same image and manifest without the resource request (env, sorted)" "$cenv"
    ev_diff env "EV-DIFF: the control pod's environment against the verifier's: what the request injected (and HOSTNAME, each pod's own name)" "$EV_LAST" "$venv_f"
    cmnt=$(k3s kubectl exec cdi-control -- cat /proc/self/mountinfo | mount_points) \
        || fail "could not read the control pod's mounts"
    ev_text control-mounts "EV-STATE: the control pod's mounts (mount point and filesystem type, sorted)" "$cmnt"
    ev_diff mounts "EV-DIFF: the control pod's mounts against the verifier's: what the request mounted" "$EV_LAST" "$vmnt_f"
    for var in DISPLAY PULSE_SERVER PIPEWIRE_REMOTE; do
        ! grep -q "^$var=" <<<"$cenv" \
            || fail "control pod has $var without requesting the resource - injection is not what we measured"
    done
    for m in /tmp/.X11-unix /run/desktop-audio; do
        grep -q "^$m " <<<"$vmnt" || fail "the verifier pod has no $m mount"
        ! grep -q "^$m " <<<"$cmnt" || fail "control pod has the $m mount without requesting the resource"
    done
    if k3s kubectl exec cdi-control -- test -S /tmp/.X11-unix/X0 2>/dev/null; then
        fail "control pod can see the X socket without requesting the resource"
    fi
    k3s kubectl delete pod cdi-control --wait=true >/dev/null 2>&1 || true
    log vp "control pod saw no DISPLAY and no X socket - the request is the cause"
    ev_pass "the control pod got none of it: no DISPLAY, PULSE_SERVER or PIPEWIRE_REMOTE, no /tmp/.X11-unix or /run/desktop-audio mount, no X socket"

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
    ev_pass "its audio sockets are mounted writable, and pactl info answers over them"
    ev_end

    log vp "spawn an xterm from the pod so the screendump shows a client window"
    timeout 15 k3s kubectl exec "$VPOD" -- \
        sh -c 'setsid xterm -T cdi-verify -geometry 80x24+150+150 </dev/null >/dev/null 2>&1 &' \
        || true
    sleep 3
    log vp "verify-cdi passed"
}

play_audio_pod() { # $1: pulse|pipewire|alsa   $2: pod (default cdi-verify)   $3: seconds (1.5)
    # Same beep-per-path convention as the in-container test, but played from an
    # requesting pod using ONLY the injected env - so success proves the CDI spec
    # wired that client path, not the desktop image's own local session. Prints
    # the player's command, its own output and its exit status (EV-LOG-CLIENT).
    local path="${1:?pulse|pipewire|alsa}" pod="${2:-$VPOD}" player freq out
    case "$path" in
        pulse)    freq=440;  player='paplay /tmp/t.wav' ;;
        pipewire) freq=880;  player='pw-play /tmp/t.wav' ;;
        alsa)     freq=1320; player='aplay -q /tmp/t.wav' ;;
        *) fail "unknown audio path '$path'" ;;
    esac
    gen_tone "$freq" /tmp/tone-pod.wav "${3:-1.5}"
    # Stream the WAV in over exec stdin (no kubectl cp -> no tar dependency).
    timeout 20 k3s kubectl exec -i "$pod" -- sh -c 'cat > /tmp/t.wav' \
        < /tmp/tone-pod.wav || fail "could not copy tone into $pod"
    # Retry + hard timeout: the audio client can lag briefly, and a stuck
    # connect must fail rather than hang (see the earlier pacat hang).
    for _ in 1 2 3 4 5; do
        if out=$(timeout 30 k3s kubectl exec "$pod" -- sh -c "$player" 2>&1); then
            echo "player in $pod: $player"
            [ -z "$out" ] || printf '%s\n' "$out"
            echo "player exit: 0"
            log pa "$pod played ${freq}Hz via $path"
            return 0
        fi
        echo "player in $pod: $player failed, retrying in 3 s: $out"
        sleep 3
    done
    fail "$pod $path playback failed after 5 tries"
}

verify_testclient() {
    log tc "apply a LEAN non-desktop client (no server stack) requesting the resource"
    ev_begin S7.3.4 "A lean non-desktop image works" T3
    k3s kubectl apply -f ci/vm/testclient-pod.yaml
    wait_for 30 4 "testclient running" \
        sh -c "k3s kubectl get pod x11-testclient -o jsonpath='{.status.phase}' | grep -q Running"

    # Lean: no X server and no window manager in the image, and no audio
    # daemon running in the pod. The PipeWire daemon packages ARE installed
    # (pipewire-utils and pipewire-alsa pull them in); nothing starts them,
    # so the process list, not the package list, is the audio half's proof.
    pkgs=$(ev_save rpm-qa "EV-STATE: rpm -qa of the lean image, sorted: no X server (xorg-x11-server-*) and no window manager (motif, which ships mwm); the PipeWire packages there are dependencies of pipewire-utils and pipewire-alsa" \
        k3s kubectl exec x11-testclient -- sh -c 'rpm -qa | sort') \
        || fail "could not list the lean image's packages"
    if grep -E '^(xorg-x11-server-|motif-)' <<<"$pkgs"; then
        fail "the lean image carries an X server or a window manager (above)"
    fi
    ev_pass "the lean image has no X server package and no window manager"
    procs=$(ev_save processes "EV-STATE: every process in the pod, read from /proc (pid, command line): the pod's sleep and this probe; no pipewire, wireplumber or pipewire-pulse" \
        k3s kubectl exec x11-testclient -- sh -c 'for p in /proc/[0-9]*; do printf "%s %s\n" "${p#/proc/}" "$(tr "\0" " " <"$p/cmdline" 2>/dev/null)"; done') \
        || fail "could not list the lean client pod's processes"
    if grep -Eq '(^|[ /])(pipewire|wireplumber|pipewire-pulse)( |$)' <<<"$procs"; then
        fail "an audio daemon runs in the lean client pod (see the process list)"
    fi
    ev_pass "no audio daemon runs in the pod"

    # The image ships no Xorg server or session, so a working display here can
    # only come from the CDI spec's injected DISPLAY + X-socket mount.
    ev_save env "EV-STATE: the pod's environment: DISPLAY, PULSE_SERVER, PIPEWIRE_REMOTE and DESKTOP_TOOLS_BIN, all injected by CDI (ci/vm/testclient-pod.yaml declares no env)" \
        k3s kubectl exec x11-testclient -- env >/dev/null || true
    got=$(k3s kubectl exec x11-testclient -- printenv DISPLAY 2>/dev/null || true)
    [ "$got" = ":0" ] || fail "testclient DISPLAY='$got', want :0 (CDI injection)"
    ev_pass "the pod's DISPLAY is :0, injected by CDI"
    ev_save xdpyinfo "EV-STATE: xdpyinfo run in the lean client: the desktop's display :0, opened with the injected env and mount only" \
        timeout 20 k3s kubectl exec x11-testclient -- xdpyinfo >/dev/null \
        || fail "lean client could not open the display via injected env"
    ev_pass "xdpyinfo in the lean client opened :0"
    ev_end
    log tc "lean client opened the display with only injected env"
}

# png_size prints "WxH" from a PNG's IHDR header. Rocky has python3 (see the
# audio checks below); the testclient image has no imagemagick, so the size is
# read from the file rather than by asking a tool to decode it. Pixel-level
# assertions happen on the HOST, where imagemagick already lives (vm-e2e.sh).
png_size() { # $1: png file
    python3 - "$1" <<'EOF'
import struct, sys
data = open(sys.argv[1], "rb").read(24)
if len(data) < 24 or data[:8] != b"\x89PNG\r\n\x1a\n":
    sys.exit("not a PNG (%d bytes read)" % len(data))
w, h = struct.unpack(">II", data[16:24])
print("%dx%d" % (w, h))
EOF
}

# shot_to runs the screenshot binary in the lean client pod and streams the
# resulting file back out. `kubectl cp` would need tar in the image; `cat`
# needs nothing, and exec without -t leaves the bytes alone.
# TOOL is how a client actually invokes the toolkit: an absolute path under the
# directory the tools CDI device mounted, named by the env var it injected.
# Nothing is on PATH and nothing is baked into the image - if this resolves,
# the whole delivery chain (desktop publishes -> host dir -> CDI -> client)
# worked.
TOOL='"$DESKTOP_TOOLS_BIN"/screenshot'

shot_to() { # $1: local destination; $2: in-pod path; $3...: extra screenshot flags
    local dest="$1" remote="$2"
    shift 2
    k3s kubectl exec x11-testclient -- sh -c "$TOOL \"\$@\" \"$remote\"" _ "$@" || return 1
    k3s kubectl exec x11-testclient -- cat "$remote" > "$dest" || return 1
}

# screenshot_pattern_start puts a known, asymmetric pattern on the display and
# leaves it there. Everything the host asserts about captured PIXELS is
# asserted against this pattern, so it must be up before anything is captured
# and before the host's reference screendump is taken.
#
# It is a pod, not a backgrounded exec: the pattern has to outlive the command
# that starts it, and X frees a client's windows the instant it disconnects.
screenshot_pattern_start() {
    log ss "paint the known test pattern over the display"
    k3s kubectl apply -f ci/vm/testpattern-pod.yaml
    wait_for 30 2 "testpattern pod running" \
        sh -c "k3s kubectl get pod testpattern -o jsonpath='{.status.phase}' | grep -q Running"
    # The painter prints this only after a round trip that the server has
    # already processed, so it is a guarantee the pattern is on screen rather
    # than a sleep pretending to be one.
    wait_for 30 2 "test pattern painted" \
        sh -c "k3s kubectl logs testpattern 2>/dev/null | grep -q painted"
    k3s kubectl logs testpattern | sed 's/^/== vm-guest(ss): /'
}

# screenshot_pattern_stop takes the pattern down so later phases see the real
# desktop again (verify_concurrency screendumps the display after this).
screenshot_pattern_stop() {
    log ss "remove the test pattern"
    k3s kubectl delete pod testpattern --now --ignore-not-found
}

# verify_pod_identity proves the point of the host-pid-namespace container
# shape: every X client is attributable, from inside the desktop container,
# to the k8s pod that owns it.
#
# The chain under test, end to end:
#   X client connects -> Xorg's SO_PEERCRED sees a REAL host pid (only true
#   under --pid=host; sibling pid namespaces read 0) -> stock X-Resource
#   QueryClientIds reports it -> /proc/<pid>/cgroup (the host's proc, visible
#   in-container for the same reason) carries the owning pod's UID.
#
# Runs while the testpattern pod is painting, so there is a known pod-owned
# client on the display to attribute. The listing comes from the desktop's
# own staged copy of the screenshot tool - the same binary clients get.
verify_pod_identity() {
    log pi "every X client reports a real host pid via X-Resource"
    ev_begin S3.7.1 "X clients report real host pids" T3
    clients=$(ev_save list-clients "EV-STATE: screenshot --list-clients from inside the desktop container: every X client with the host pid X-Resource reports, none 0" \
        podman exec -u desktop -e DISPLAY=:0 desktop \
        /usr/libexec/desktop-tools/screenshot --list-clients) \
        || fail "screenshot --list-clients failed: $clients"
    echo "$clients" | sed 's/^/== vm-guest(pi): /'
    n=$(echo "$clients" | grep -c '^client-base=' || true)
    [ "$n" -ge 3 ] || fail "only $n X clients listed; expected at least mwm, xterm and the testpattern pod"
    ev_pass "$n X clients are listed (at least mwm, xterm and the testpattern pod)"
    if echo "$clients" | grep -q ' pid=0$'; then
        fail "an X client reports pid=0: Xorg is not seeing host pids - is --pid=host gone from the quadlet?"
    fi
    ev_pass "none reports pid=0"
    pids=$(echo "$clients" | sed -n 's/.* pid=//p' | paste -sd, -)
    ev_save client-processes "EV-STATE: ps -p <every listed pid> -o pid,user,comm,cgroup on the host: the listed pids as host processes, the pods' by their kubepods cgroup (the newest pid is usually the listing tool itself, gone by the time ps runs)" \
        ps -p "$pids" -o pid,user,comm,cgroup >/dev/null || true
    ev_end

    log pi "an X client resolves to the testpattern pod through /proc/<pid>/cgroup"
    ev_begin S3.7.2 "A client pid resolves to its pod from inside the container" T3
    uid=$(k3s kubectl get pod testpattern -o jsonpath='{.metadata.uid}')
    [ -n "$uid" ] || fail "could not read the testpattern pod UID"
    ev_text pod-uid "EV-STATE: the testpattern pod's UID, from kubectl (kubelet writes it into the pod's cgroup path, dashes or underscores)" "$uid"
    # kubelet spells the UID two ways depending on cgroup driver: verbatim
    # (cgroupfs) or dashes-to-underscores inside a .slice name (systemd).
    uidu=$(echo "$uid" | tr - _)
    match=""
    for pid in $(echo "$clients" | sed -n 's/.* pid=//p'); do
        cg=$(cat "/proc/$pid/cgroup" 2>/dev/null || true)
        case "$cg" in
            *"$uid"*|*"$uidu"*) match=$pid; break ;;
        esac
    done
    [ -n "$match" ] || fail "no X client's cgroup carries the testpattern pod UID $uid - window-to-pod attribution is broken"
    ev_save cgroup-on-host "EV-STATE: /proc/$match/cgroup read on the host for the X client pid $match: the path carries the pod UID" \
        cat "/proc/$match/cgroup" >/dev/null || true
    ev_pass "X client pid $match's cgroup carries the testpattern pod UID on the host"

    # And the same read must work from INSIDE the container: the compositor
    # is the eventual consumer, and it lives in there. Same pid, same file,
    # through the container's own /proc.
    ev_save cgroup-in-container "EV-STATE: the same /proc/$match/cgroup read from inside the desktop container: the same pod UID" \
        podman exec desktop cat "/proc/$match/cgroup" >/dev/null || true
    podman exec desktop grep -q -e "$uid" -e "$uidu" "/proc/$match/cgroup" \
        || fail "host pid $match resolves on the host but not inside the container - /proc is not the host's in there"
    ev_pass "and the same read from inside the desktop container finds it too"
    ev_end
    log pi "  X client pid $match belongs to pod testpattern ($uid), resolved from inside the container"
    log pi "verify-pod-identity passed"
}

# verify_screenshot proves the whole point of the binary: an ordinary client
# image, carrying no X client stack of its own and declaring no env or mounts,
# captures the real Xorg display using only what desktop.local/display injects.
#
# This phase asserts sizes, exit codes and the CLI contract. It does NOT assert
# pixels - it hands the captured PNGs back and vm-e2e.sh checks their contents
# with imagemagick, which the runner has and this VM does not.
verify_screenshot() {
    log ss "capture the live display from the lean client pod"
    wait_for 30 4 "testclient running" \
        sh -c "k3s kubectl get pod x11-testclient -o jsonpath='{.status.phase}' | grep -q Running"

    # The toolkit arrived by the real delivery path, not baked into the image.
    # Assert each link before trusting the binary: the desktop published to the
    # host directory, desktop-tools-cdi.path noticed and wrote the spec, and
    # CDI injected the mount and env into this pod. (S7.2.4's other half, a
    # pod that did not ask getting neither, is verify_split's.)
    ev_begin S7.2.4 "Clients receive it read-only via DESKTOP_TOOLS_BIN" T3
    [ -s /etc/cdi/desktop-tools.yaml ] \
        || fail "no /etc/cdi/desktop-tools.yaml: the .path unit never fired after the desktop published"
    ev_copy /etc/cdi/desktop-tools.yaml tools-spec "EV-CONFIG: /etc/cdi/desktop-tools.yaml, which the tools device resolves to: DESKTOP_TOOLS_BIN and a read-only bind of the published toolkit"
    local toolkit
    ev_save testclient-env "EV-STATE: the lean client pod's environment (it requests desktop.local/tools): DESKTOP_TOOLS_BIN is set" \
        k3s kubectl exec x11-testclient -- env >/dev/null || true
    toolkit=$(k3s kubectl exec x11-testclient -- printenv DESKTOP_TOOLS_BIN 2>/dev/null || true)
    [ -n "$toolkit" ] \
        || fail "the client pod has no DESKTOP_TOOLS_BIN: the tools device injected nothing"
    ev_pass "the pod that requested desktop.local/tools has DESKTOP_TOOLS_BIN=$toolkit"
    mnt=$(ev_save testclient-mountinfo "EV-STATE: the pod's mountinfo line for $toolkit: mounted, ro in its mount options (the sixth field)" \
        k3s kubectl exec x11-testclient -- grep " $toolkit " /proc/self/mountinfo) \
        || fail "the pod has no mount at $toolkit"
    opts=$(awk -v m="$toolkit" '$5 == m {print $6; exit}' <<<"$mnt")
    case ",$opts," in
        *,ro,*) ;;
        *) fail "the toolkit mount at $toolkit has options '$opts', not ro" ;;
    esac
    ev_pass "the toolkit is mounted at $toolkit with options $opts: read-only"
    k3s kubectl exec x11-testclient -- test -x "$toolkit/screenshot" \
        || fail "no executable screenshot in the injected toolkit at $toolkit"
    ev_save help "EV-STATE: the injected binary run in the pod with --help: its usage" \
        k3s kubectl exec x11-testclient -- sh -c "$TOOL --help" >/dev/null \
        || fail "the injected screenshot binary does not run in the pod"
    ev_pass "the injected screenshot binary executes in the pod"
    log ss "toolkit delivered to the client at $toolkit (published by the desktop, mounted by CDI)"

    # Read-only, as the spec declares: a client must not be able to replace a
    # binary that every other client executes.
    if ev_save touch-refused "EV-STATE: touch inside the toolkit from the pod: refused (read-only file system), non-zero exit" \
        k3s kubectl exec x11-testclient -- sh -c "touch $toolkit/.probe" >/dev/null; then
        fail "the injected toolkit is WRITABLE from the client; it must be mounted read-only"
    fi
    ev_pass "touch inside the toolkit fails: the pod cannot write it"
    ev_end
    log ss "injected toolkit is read-only from the client"
    ev_begin S7.4.1 "Captured pixels are the screen" T3

    # The display size as the CLIENT POD sees it, through the very display the
    # CDI device injected - not via the desktop, which by this phase is a
    # kubernetes pod and has no podman container to exec into at all.
    local want
    want=$(k3s kubectl exec x11-testclient -- \
        sh -c 'xdpyinfo | awk "/dimensions:/{print \$2; exit}"')
    [ -n "$want" ] || fail "could not read the display size from the client pod"
    log ss "the client pod sees a $want display"

    rm -rf /tmp/screenshots && mkdir -p /tmp/screenshots
    echo "$want" > /tmp/screenshots/geometry.txt

    ev_text display-size "EV-STATE: the display size the client pod reads with xdpyinfo, which every capture below is checked against" "$want"

    # --to-stdout: the PNG must arrive on stdout with nothing else mixed in,
    # which is also how it gets out of the pod here.
    k3s kubectl exec x11-testclient -- sh -c "$TOOL --to-stdout" \
        > /tmp/screenshots/full-stdout.png \
        || fail "screenshot --to-stdout failed in the client pod"
    local got
    got=$(png_size /tmp/screenshots/full-stdout.png) \
        || fail "screenshot --to-stdout did not produce a PNG"
    [ "$got" = "$want" ] || fail "--to-stdout captured $got, but the display is $want"
    ev_pass "--to-stdout wrote a PNG of the whole $want display to stdout"
    log ss "--to-stdout captured the full display at $got"

    # File mode must agree with stdout mode.
    shot_to /tmp/screenshots/full.png /tmp/full.png \
        || fail "screenshot to a file failed in the client pod"
    got=$(png_size /tmp/screenshots/full.png) || fail "file-mode output is not a PNG"
    [ "$got" = "$want" ] || fail "file-mode captured $got, but the display is $want"
    ev_pass "file mode wrote a PNG of the whole $want display"
    log ss "file mode captured the full display at $got"

    # Regions. Each is checked for size here and for CONTENT on the host: the
    # host crops the same rectangle out of the full capture and requires the
    # two to be identical, which is what pins the region's origin.
    #   region   - a plain sub-rectangle
    #   tl       - exactly the pattern's top-left block, so it must come back
    #              a single flat colour
    #   straddle - deliberately across that block's corner, so three of its
    #              quadrants are background
    #   odd      - an odd WIDTH, which is the case where a wrongly assumed
    #              scanline stride starts shearing rows
    local spec
    for spec in "region 200 100 10 20" "tl 64 64 0 0" "straddle 8 8 60 60" "odd 199 40 290 0"; do
        set -- $spec
        shot_to "/tmp/screenshots/$1.png" "/tmp/$1.png" -x "$4" -y "$5" -w "$2" -h "$3" \
            || fail "region capture '$1' failed in the client pod"
        got=$(png_size "/tmp/screenshots/$1.png") || fail "region '$1' output is not a PNG"
        [ "$got" = "${2}x${3}" ] || fail "region '$1' is $got, want ${2}x${3}"
        ev_pass "region '$1' (-x $4 -y $5 -w $2 -h $3) came back ${2}x${3}"
        log ss "region '$1' captured at $got"
    done

    # -h is HEIGHT, not help. This is the published CLI contract and the one
    # flag decision a future change is most likely to get backwards, so it is
    # asserted against the real binary and not only in the Go tests.
    shot_to /tmp/screenshots/hw.png /tmp/hw.png -w 160 -h 120 \
        || fail "-w/-h screenshot failed (is -h being parsed as --help?)"
    got=$(png_size /tmp/screenshots/hw.png) || fail "-w/-h output is not a PNG"
    [ "$got" = 160x120 ] || fail "-w 160 -h 120 produced $got, want 160x120"
    ev_pass "-h is height: -w 160 -h 120 came back 160x120"
    log ss "-h is height: -w 160 -h 120 captured at $got"

    # An out-of-bounds region is refused, not clamped, and says what the
    # screen actually is. Exit 2 is the usage-error contract.
    local out rc=0
    out=$(ev_save oversized "EV-STATE: an oversized region (-w 99999) in the pod: refused with exit 2, naming the real screen size $want" \
        k3s kubectl exec x11-testclient -- sh -c "$TOOL -w 99999 /tmp/bad.png") || rc=$?
    [ "$rc" = 2 ] || fail "an oversized region exited $rc, want 2 (usage error)"
    grep -q "$want" <<<"$out" \
        || fail "the oversized-region error does not name the real screen size ($want): $out"
    ev_pass "an oversized region exits 2 and names the screen's real size ($want)"
    log ss "oversized region refused with exit 2 naming $want"

    # No display granted: the binary must fail cleanly and point at the CDI
    # device, which is the error a mis-specified client pod actually hits.
    rc=0
    out=$(ev_save no-display "EV-STATE: the binary run in the pod with DISPLAY unset: exit 1, and the error names desktop.local/display" \
        k3s kubectl exec x11-testclient -- sh -c "env -u DISPLAY $TOOL /tmp/nodisplay.png") || rc=$?
    [ "$rc" = 1 ] || fail "screenshot without DISPLAY exited $rc, want 1 (runtime failure)"
    grep -q 'desktop.local/display' <<<"$out" \
        || fail "the no-DISPLAY error does not name the CDI device that grants one: $out"
    ev_pass "with no DISPLAY it exits 1 and names desktop.local/display"
    ev_end
    log ss "no DISPLAY: exits 1 pointing at desktop.local/display"

    log ss "captured from a client pod with only the injected display; pixels checked on the host"
}

verify_log_bounds() {
    # The sink the container's logging lands in must be BOUNDED, and it is
    # asserted on the running container rather than on the config that was
    # meant to produce it - a log option that silently did not apply looks
    # exactly like one that did, right up until the disk fills.
    #
    # Why this needs asserting at all: desktop-init and the whole session
    # write to /dev/console for the life of the container, so this is a
    # continuous stream on a machine meant to run for months, not a
    # boot-time burst. (With no systemd in the image there is no journald
    # and no second, container-side sink any more - podman's log file is
    # the one and only place this stream lands.)

    # 1. The HOST-side sink: podman's own log for the container.
    log lb "the container log has an explicit driver and a size bound"
    drv=$(podman inspect desktop --format '{{.HostConfig.LogConfig.Type}}' 2>/dev/null || echo unknown)
    [ "$drv" = k8s-file ] \
        || fail "container log driver is '$drv', want k8s-file: the quadlet's LogDriver= did not reach podman, so the bound below is on a sink that may not be the one in use"
    # Read the size back off the RUNNING container rather than off the unit
    # file: that proves podman ACCEPTED the option, which is the failure mode
    # worth catching (an unsupported spelling on an older podman is silently
    # dropped, and the .container file would still look correct).
    #
    # podman normalises the value - "64m" goes in, "64MB" comes back - so match
    # case-insensitively on the number rather than on the string we passed.
    # Getting that wrong is what made this assertion fail on its first run
    # while the bound itself was working perfectly.
    size=$(podman inspect desktop --format '{{.HostConfig.LogConfig.Size}}' 2>/dev/null || true)
    # Older podman may not expose .Size; fall back to the whole LogConfig blob.
    [ -n "$size" ] || size=$(podman inspect desktop --format '{{json .HostConfig.LogConfig}}' 2>/dev/null || echo '')
    echo "$size" | grep -qiE '64 ?mb|67108864' \
        || fail "no 64M max-size on the container log (got '$size'): --log-opt did not reach podman and the console stream lands in an unbounded sink"
    log lb "  driver=k8s-file, max-size=$size"

    log lb "verify-log-bounds passed"
}

pipewire_pid() { podman exec desktop sh -c 'pgrep -x pipewire | head -1' 2>/dev/null || true; }
pipewire_running() { [ -n "$(pipewire_pid)" ]; }

audio_reachable() {
    # The exported Pulse socket, from the HOST - the same probe phase-deploy
    # uses for host audio. "PipeWire is running" and "clients can reach the
    # export" are different claims, and a restart that leaves a stale socket
    # behind satisfies the first while breaking the second (PipeWire will not
    # re-bind over a leftover file), which is precisely the regression the
    # per-restart socket clearing exists to prevent.
    PULSE_SERVER=unix:/run/desktop-audio/pulse timeout 20 pactl info >/dev/null 2>&1
}

verify_audio_x_restart() {
    # The X direction of verify_audio_lifecycle (see there): the X server
    # dies, the session comes back, and the audio stack must not notice.
    # Its own step so the host can keep a tone playing across it (S4.5.1).
    log al "audio survives an X session restart"
    wait_for 30 2 "pipewire to be running" pipewire_running
    pw_before=$(pipewire_pid)
    [ -n "$pw_before" ] || fail "no pipewire process to start from"
    audio_reachable || fail "audio was not reachable before the test even began"
    session_up || fail "no X session to restart"
    ev_begin S4.5.1 "Audio survives an X session restart" T3
    ev_save pids-before "EV-PIDS: Xorg, mwm and the three audio daemons before Xorg is killed" \
        ctr_pids Xorg,mwm,pipewire,wireplumber,pipewire-pulse >/dev/null || true
    x_before=$(podman exec desktop pgrep -x Xorg 2>/dev/null | head -1 || true)

    # Kill the X server, not the container: the session dies, desktop-init
    # notices and starts a new one. That is the ordinary failure this is
    # about - Xorg crashing - rather than an operator restarting the unit.
    # As the desktop uid, NOT as container root: CAP_KILL is dropped from
    # this container (in the host pid namespace it would mean "may signal any
    # process on the host"), so root in here cannot signal the session user's
    # processes. Xorg runs rootless as 'desktop', and same-uid signaling needs
    # no capability - the same route desktop-init takes via setpriv.
    # The host marks the kill on S4.5.1's level plot from this time.
    date +%s.%N > /run/verify-audio-x.kill
    podman exec -u desktop desktop pkill -u desktop -x Xorg || true
    ev_note "Xorg (pid $x_before) killed at $(date -u +%Y-%m-%dT%H:%M:%S.%3NZ)"
    x_new() { local p; p=$(podman exec desktop pgrep -x Xorg 2>/dev/null | head -1); [ -n "$p" ] && [ "$p" != "$x_before" ] && session_up; }
    wait_for 45 2 "a new X session (a new Xorg and mwm)" x_new
    log al "  the X session restarted"
    ev_note "a new Xorg and mwm up at $(date -u +%Y-%m-%dT%H:%M:%S.%3NZ)"
    ev_save pids-after "EV-PIDS: Xorg, mwm and the three audio daemons after the session came back" \
        ctr_pids Xorg,mwm,pipewire,wireplumber,pipewire-pulse >/dev/null || true
    ev_pass "the X session restarted: Xorg $x_before -> $(podman exec desktop pgrep -x Xorg 2>/dev/null | head -1)"

    pw_after=$(pipewire_pid)
    [ "$pw_after" = "$pw_before" ] \
        || fail "pipewire pid changed from $pw_before to '$pw_after' across an X session restart: the audio stack is still in the X session's process session and gets killed with it"
    ev_pass "pipewire kept its pid across the X restart ($pw_before)"
    audio_reachable \
        || fail "the exported pulse socket is unreachable after an X session restart, though pipewire kept its pid"
    ev_save pactl-info "EV-STATE: pactl info from the host over the export, after the X restart" \
        env PULSE_SERVER=unix:/run/desktop-audio/pulse pactl info >/dev/null || true
    ev_pass "the export still answers pactl info"
    ev_end
    log al "  pipewire pid $pw_before unchanged, export still reachable"
}

verify_audio_lifecycle() {
    # The audio stack and the X session are supervised separately, and this
    # is the only test that can tell. Every other audio test here plays a
    # tone through a healthy stack, which passes identically whether the two
    # share a lifecycle or not.
    #
    # Two directions, and they used to fail differently:
    #
    #   X dies    -> the audio daemons were children of the X session, so
    #                desktop-init's sid-scoped cleanup killed them with it and
    #                every audio client on the host or in another pod got
    #                ECONNREFUSED until the session came back.
    #   audio dies-> nothing at all happened. The old start-session ended in a
    #                bare `wait`, which returns only once ALL its children have
    #                exited, so one dead daemon went unnoticed and the stack
    #                stayed down - with a stale socket - until Xorg happened to
    #                exit. There was no recovery path to test.
    # The X direction is verify_audio_x_restart's, run just before this so
    # the host can play a tone across it (S4.5.1).
    log al "audio recovers from its own crash"
    wait_for 30 2 "pipewire to be running" pipewire_running
    pw_before=$(pipewire_pid)
    [ -n "$pw_before" ] || fail "no pipewire process to start from"
    # S4.5.2's "before": the X session's pids as well as the audio stack's, so
    # a recovery that took the session down with it cannot pass.
    ev_begin S4.5.2 "Audio recovers from its own crash without disturbing X" T3
    ev_save pids-before "EV-PIDS: Xorg, mwm and the three audio daemons before pipewire is killed" \
        ctr_pids Xorg,mwm,pipewire,wireplumber,pipewire-pulse >/dev/null || true
    x_pids_before=$(podman exec desktop sh -c 'pgrep -x Xorg; pgrep -x mwm' 2>/dev/null | paste -sd' ' || true)
    [ "$(wc -w <<<"$x_pids_before")" -ge 2 ] || fail "no Xorg and mwm to compare across the audio crash (found: '$x_pids_before')"
    pw_since=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    sleep 1
    ev_begin S2.4.4 "WirePlumber waits for PipeWire's socket" T3
    ev_save pids-boot "EV-PIDS: the audio daemons as booted (pid, ppid, session, user, start time)" \
        podman exec desktop ps -o pid,ppid,sess,user,lstart,comm -C pipewire,wireplumber,pipewire-pulse >/dev/null || true
    wp_boot=$(podman exec desktop pgrep -x wireplumber 2>/dev/null | head -1 || true)
    [ -n "$wp_boot" ] || fail "no wireplumber after boot"
    ev_pass "wireplumber is alive after boot (pid $wp_boot)"
    ev_end
    ev_begin S2.4.3 "Stale export sockets are cleared before every audio start" T3
    ev_save export-before "EV-STATE: ls -li /run/desktop-audio before pipewire is killed (the first column is each file's inode)" \
        ls -li /run/desktop-audio >/dev/null || true
    export_before=$EV_LAST
    ino_before=$(stat -c %i /run/desktop-audio/pulse 2>/dev/null || echo none)
    # The half that had no answer at all before: kill PipeWire and require a
    # NEW one, plus a reachable export - which needs the stale socket files
    # cleared, or the restarted daemon cannot re-bind and every client keeps
    # getting ECONNREFUSED against a socket that looks present.
    podman exec -u desktop desktop pkill -u desktop -x pipewire || true
    recovered=""
    for _ in $(seq 30); do
        recovered=$(pipewire_pid)
        [ -n "$recovered" ] && [ "$recovered" != "$pw_before" ] && break
        recovered=""
        sleep 2
    done
    [ -n "$recovered" ] \
        || fail "pipewire never came back after being killed (was $pw_before): the audio stack has no supervisor of its own"
    log al "  pipewire restarted as pid $recovered"

    # wait_for fails the run on timeout, so the reason goes in the description.
    wait_for 30 2 \
        "the exported audio socket to be reachable again after a pipewire restart (stale socket files not cleared before the restart?)" \
        audio_reachable
    ev_save export-after "EV-STATE: ls -li /run/desktop-audio after the restart: new socket files (new inodes)" \
        ls -li /run/desktop-audio >/dev/null || true
    ev_diff export "EV-DIFF: the export dir across the pipewire restart; the socket lines change inode" \
        "$export_before" "$EV_LAST"
    ino_after=$(stat -c %i /run/desktop-audio/pulse 2>/dev/null || echo none)
    [ "$ino_after" != none ] && [ "$ino_after" != "$ino_before" ] \
        || fail "the pulse socket's inode did not change across the restart ($ino_before -> $ino_after): the stale file was not replaced"
    ev_pass "the pulse socket is a new file after the restart (inode $ino_before -> $ino_after)"
    ev_save pactl-info "EV-STATE: pactl info from the host over the export, after the restart" \
        env PULSE_SERVER=unix:/run/desktop-audio/pulse pactl info >/dev/null \
        || fail "pactl info over the export failed after the restart"
    ev_pass "pactl info over the export succeeds after the restart (pipewire $pw_before -> $recovered)"
    ev_end
    ev_begin S2.4.4 "WirePlumber waits for PipeWire's socket" T3
    wp_new() { local p; p=$(podman exec desktop pgrep -x wireplumber 2>/dev/null | head -1); [ -n "$p" ] && [ "$p" != "$wp_boot" ]; }
    wait_for 30 2 "a new wireplumber after the audio stack restarted" wp_new
    ev_save pids-restart "EV-PIDS: the audio daemons after pipewire was killed and the stack restarted" \
        podman exec desktop ps -o pid,ppid,sess,user,lstart,comm -C pipewire,wireplumber,pipewire-pulse >/dev/null || true
    ev_pass "wireplumber is alive after the stack restart (pid $wp_boot -> $(podman exec desktop pgrep -x wireplumber | head -1))"
    ev_end

    # And the session must not have been collateral damage in the other
    # direction either - killing audio must not disturb X: the same Xorg and
    # mwm, not just a session that is up (a restarted one would be).
    ev_begin S4.5.2 "Audio recovers from its own crash without disturbing X" T3
    ev_save pids-after "EV-PIDS: Xorg, mwm and the three audio daemons after pipewire was killed and the stack came back" \
        ctr_pids Xorg,mwm,pipewire,wireplumber,pipewire-pulse >/dev/null || true
    ev_save desktop-log "EV-LOG-DESKTOP: the desktop's log since just before pipewire was killed" \
        podman logs --since "$pw_since" desktop >/dev/null || true
    ev_pass "pipewire came back as a new process on its own: $pw_before -> $recovered"
    ev_save pactl-info "EV-STATE: pactl info from the host over the export, after the recovery" \
        env PULSE_SERVER=unix:/run/desktop-audio/pulse pactl info >/dev/null \
        || fail "pactl info over the export failed after pipewire's recovery"
    ev_pass "the export answers pactl info after the recovery"
    session_up \
        || fail "the X session died when the audio stack was killed: the two are still coupled, in the other direction"
    x_pids_after=$(podman exec desktop sh -c 'pgrep -x Xorg; pgrep -x mwm' 2>/dev/null | paste -sd' ' || true)
    [ "$x_pids_after" = "$x_pids_before" ] \
        || fail "the X session's pids changed across the audio crash ($x_pids_before -> $x_pids_after): killing audio disturbed X"
    ev_pass "Xorg and mwm kept their pids across the audio crash ($x_pids_before), and X answers"
    ev_end
    log al "  the X session was undisturbed"
    log al "verify-audio-lifecycle passed"
}

verify_postmortem() {
    # S2.3.5: an abnormal end leaves a postmortem in the desktop's log. Kill
    # the server outright (SIGKILL: no chance to tidy up), as the desktop uid
    # for the reason above, and read the log from just before the kill.
    log al "a killed X server leaves a postmortem"
    ev_begin S2.3.5 "Postmortem runs on abnormal exit only" T3
    x_before=$(podman exec desktop pgrep -x Xorg 2>/dev/null | head -1 || true)
    [ -n "$x_before" ] || fail "no Xorg to kill"
    since=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    sleep 1
    podman exec -u desktop desktop pkill -KILL -u desktop -x Xorg || true
    ev_note "Xorg (pid $x_before) killed with SIGKILL just after $since"
    x_new() { local p; p=$(podman exec desktop pgrep -x Xorg 2>/dev/null | head -1); [ -n "$p" ] && [ "$p" != "$x_before" ] && session_up; }
    wait_for 60 2 "a new X session after Xorg was killed with SIGKILL" x_new
    pm=$(ev_save desktop-log "EV-LOG-DESKTOP: the desktop's log from just before the kill (podman logs --since $since): the session's exit, the postmortem, the new session" \
        podman logs --since "$since" desktop) || true
    pm=$(tr -d '\r' <<<"$pm")
    # xinit exits 0 when its server dies, so the session's rc says nothing
    # here: desktop-init reads the server's log, says the server did not shut
    # down cleanly, and only then runs the postmortem. In that order, the
    # session's exit line last.
    line_of() { grep -n "$1" <<<"$pm" | head -1 | cut -d: -f1; }
    n_unclean=$(line_of '^desktop-init: the X server did not shut down cleanly')
    n_pm=$(line_of '^postmortem: X session ended abnormally')
    n_exit=$(line_of '^desktop-init: session exited (rc=')
    [ -n "$n_unclean" ] || fail "desktop-init did not log that the killed X server did not shut down cleanly"
    ev_pass "desktop-init logged that the X server did not shut down cleanly (line $n_unclean)"
    [ -n "$n_pm" ] && [ "$n_pm" -gt "$n_unclean" ] \
        || fail "no postmortem header after desktop-init's 'did not shut down cleanly' line"
    grep -q '^postmortem: ---- tail of ' <<<"$pm" && grep -q '^postmortem: ---- end of Xorg log ----' <<<"$pm" \
        || fail "the postmortem did not print the Xorg log's tail"
    ev_pass "then the postmortem ran (line $n_pm): its header and the tail of the killed server's log"
    [ -n "$n_exit" ] && [ "$n_exit" -gt "$n_pm" ] || fail "desktop-init did not log the session's exit after the postmortem"
    ev_pass "then desktop-init logged the session's exit (line $n_exit): $(sed -n "${n_exit}p" <<<"$pm")"
    ev_end

    log al "verify-postmortem passed"
}

# oci_spec_path prints the path of the desktop container's OCI runtime spec:
# the config.json podman wrote and crun started the container from, with the
# mounts, masked paths and device-cgroup entries exactly as it got them.
oci_spec_path() {
    local p
    p=$(podman inspect desktop --format '{{.OCIConfigPath}}' 2>/dev/null) || p=
    if [ -z "$p" ] || [ ! -f "$p" ]; then
        p=$(podman inspect desktop --format '{{.StaticDir}}' 2>/dev/null)/config.json || return 1
    fi
    [ -f "$p" ] || return 1
    printf '%s\n' "$p"
}

# spec_sys prints what an OCI spec puts at /sys and below: one
# "mount <destination> <type> <source> <options>" line per mount, then a
# "masked <path>" and a "readonly <path>" line per such path.
spec_sys() { # <config.json>
    python3 -c '
import json, sys
spec = json.load(open(sys.argv[1]))
def under(p):
    return p == "/sys" or p.startswith("/sys/")
for m in spec.get("mounts", []):
    if under(m.get("destination", "")):
        print("mount", m["destination"], m.get("type") or "-", m.get("source") or "-",
              ",".join(m.get("options") or []) or "-")
linux = spec.get("linux", {})
for p in linux.get("maskedPaths") or []:
    if under(p):
        print("masked", p)
for p in linux.get("readonlyPaths") or []:
    if under(p):
        print("readonly", p)
' "$1"
}

# spec_devices prints an OCI spec's device-cgroup list in order, one
# "allow|deny <type> <major>:<minor> <access>" line per entry (* for any).
spec_devices() { # <config.json>
    python3 -c '
import json, sys
spec = json.load(open(sys.argv[1]))
def num(v):
    return "*" if v is None or v < 0 else str(v)
for d in spec.get("linux", {}).get("resources", {}).get("devices") or []:
    print("allow" if d.get("allow") else "deny", d.get("type") or "a",
          num(d.get("major")) + ":" + num(d.get("minor")), d.get("access") or "-")
' "$1"
}

# The names of the capabilities in a hex mask (CapEff and friends), one per
# line, from linux/capability.h's numbering. No capsh needed.
cap_names() { # <hex mask>
    local names=(CHOWN DAC_OVERRIDE DAC_READ_SEARCH FOWNER FSETID KILL SETGID SETUID
        SETPCAP LINUX_IMMUTABLE NET_BIND_SERVICE NET_BROADCAST NET_ADMIN NET_RAW
        IPC_LOCK IPC_OWNER SYS_MODULE SYS_RAWIO SYS_CHROOT SYS_PTRACE SYS_PACCT
        SYS_ADMIN SYS_BOOT SYS_NICE SYS_RESOURCE SYS_TIME SYS_TTY_CONFIG MKNOD LEASE
        AUDIT_WRITE AUDIT_CONTROL SETFCAP MAC_OVERRIDE MAC_ADMIN SYSLOG WAKE_ALARM
        BLOCK_SUSPEND AUDIT_READ PERFMON BPF CHECKPOINT_RESTORE)
    local i
    for i in "${!names[@]}"; do
        [ $(( (0x$1 >> i) & 1 )) = 0 ] || echo "${names[$i]}"
    done
    [ $(( 0x$1 >> ${#names[@]} )) = 0 ] || echo "(bits above $(( ${#names[@]} - 1 )) set: 0x$1)"
}

verify_privileges() {
    # The container must be running with LESS than --privileged, and stay that
    # way. Without this, restoring --privileged would be invisible: everything
    # else in this suite passes either way, because privileged is a superset.
    log vp "the container is not --privileged"
    ev_begin S6.1.1 "Not privileged; seccomp active" T3
    priv=$(ev_save inspect-privileged "EV-STATE: podman inspect desktop .HostConfig.Privileged: false" \
        podman inspect desktop --format '{{.HostConfig.Privileged}}' 2>/dev/null) || priv=unknown
    priv=$(tail -n1 <<<"$priv")
    [ "$priv" = false ] || fail "podman reports Privileged=$priv, want false"
    ev_pass "podman reports Privileged=false for the running desktop"

    # Seccomp: 0 = disabled, 2 = filtered. --privileged gives 0. This is the
    # largest single piece of attack surface the change takes back, and it is
    # the one that would silently regress if someone re-added the flag.
    # Under --pid=host the container's /proc/1 is the HOST's systemd, so
    # every process-level assertion targets the container's own init via the
    # pid desktop-init records. First pin down that pid-namespace shape
    # itself - it is the feature this container exists for, and everything
    # below reads through it.
    log vp "the container shares the host pid namespace and init is visible on the host"
    initpid=$(podman exec desktop cat /run/desktop-init.pid 2>/dev/null || echo "")
    [ -n "$initpid" ] || fail "no /run/desktop-init.pid in the container"
    grep -q desktop-init "/proc/$initpid/comm" 2>/dev/null \
        || fail "host pid $initpid is not desktop-init: --pid=host not in effect, or stale pid file"

    log vp "a seccomp filter is applied to the container init"
    ev_save init-seccomp "EV-STATE: the Seccomp lines of /proc/<desktop-init>/status: Seccomp 2 means a filter is applied (0 would be none)" \
        grep -E '^(Name|Pid|Seccomp)' "/proc/$initpid/status" >/dev/null || true
    mode=$(podman exec desktop sh -c "awk '/^Seccomp:/{print \$2}' /proc/$initpid/status" 2>/dev/null || echo "")
    [ "$mode" = 2 ] || fail "desktop-init Seccomp=$mode, want 2 (filter). 0 means no filter - is --privileged back?"
    ev_pass "desktop-init (host pid $initpid) runs under a seccomp filter (Seccomp: 2)"
    ev_end

    # Capabilities: assert the dangerous ones are ABSENT rather than that the
    # expected ones are present. A list of what we granted would drift with the
    # quadlet; a list of what must never be granted is the actual invariant.
    log vp "the capability bounding set excludes the dangerous ones"
    ev_begin S6.1.2 "Forbidden capabilities absent" T3
    ev_save init-status "EV-STATE: /proc/<desktop-init>/status (the Cap* lines; CapEff is what the checks read)" \
        grep -E '^(Name|Pid|Cap[A-Za-z]+|Seccomp):' "/proc/$initpid/status" >/dev/null || true
    capeff=$(podman exec desktop sh -c "awk '/^CapEff:/{print \$2}' /proc/$initpid/status" 2>/dev/null || echo "")
    [ -n "$capeff" ] || fail "could not read CapEff from the container's init process"
    ev_save capsh-decode "EV-STATE: CapEff decoded to capability names by capsh (none of the 13 below may appear)" \
        capsh --decode="$capeff" >/dev/null || ev_note "capsh is not installed on this host; the bit checks below decode CapEff themselves"
    #             name            bit  why it must not be there
    for spec in  "SYS_MODULE      16   load kernel modules" \
                 "SYS_RAWIO       17   raw port and /dev/mem access" \
                 "SYS_PTRACE      19   trace any process" \
                 "SYS_BOOT        22   reboot the host" \
                 "SYS_TIME        25   set the host clock" \
                 "NET_ADMIN       12   reconfigure host networking" \
                 "NET_RAW         13   raw sockets" \
                 "DAC_READ_SEARCH  2   bypass file read permission checks" \
                 "SYSLOG          34   read the kernel ring buffer" \
                 "BPF             39   load BPF programs" \
                 "PERFMON         38   perf_event_open" \
                 "SYS_ADMIN       21   near-root; dropped with systemd, must stay dropped" \
                 "KILL             5   in the host pid namespace this signals ANY host process"
    do
        # shellcheck disable=SC2086
        set -- $spec
        if [ $(( (0x$capeff >> $2) & 1 )) = 1 ]; then
            fail "CAP_$1 is in the container's effective set (CapEff=$capeff): $3. --privileged back?"
        fi
        ev_pass "CAP_$1 (bit $2) is not in CapEff=$capeff"
    done
    ev_end
    log vp "  CapEff=$capeff - none of the 13 forbidden capabilities present"

    # S6.1.3: and what IS there is exactly what the quadlet adds back after
    # DropCapability=ALL - nothing podman or a drop-in slipped in.
    ev_begin S6.1.3 "Granted set is exactly what the quadlet lists" T3
    ev_save quadlet-caps "EV-CONFIG: the installed quadlet's capability lines (/etc/containers/systemd/desktop.container)" \
        grep -E '^(DropCapability|AddCapability)=' /etc/containers/systemd/desktop.container >/dev/null || true
    want=$(sed -n 's/^AddCapability=//p' /etc/containers/systemd/desktop.container | tr ' ' '\n' | sed '/^$/d' | sort)
    ev_text want "EV-STATE: the names the quadlet adds back, sorted" "$want"
    caps_want=$EV_LAST
    have=$(cap_names "$capeff" | sort)
    ev_text have "EV-STATE: CapEff=$capeff of desktop-init, decoded bit by bit, sorted" "$have"
    ev_diff caps "EV-DIFF: the quadlet's list against CapEff (no differences: exactly the granted set)" "$caps_want" "$EV_LAST"
    [ -n "$want" ] && [ "$have" = "$want" ] \
        || fail "CapEff=$capeff decodes to '$(echo $have)', and the quadlet adds back '$(echo $want)'"
    ev_pass "CapEff=$capeff decodes to exactly the $(wc -l <<<"$have") the quadlet adds back: $(echo $have)"
    ev_end

    # S6.1.4: the device cgroup really is bounded. A node outside the
    # allowlist (/dev/mem's 1:1) must be unreachable, and a node of each of
    # the five allowed majors reachable. In the container's own /dev: podman
    # mounts Tmpfs= nodev, so under /tmp every node is refused whatever the
    # device cgroup says, and a denial there proves nothing. Each node is
    # made with mknod and opened with dd (count=0 reads nothing); the error
    # text says which of the two the device cgroup refused.
    log vp "the device cgroup admits the five majors and nothing else"
    ev_begin S6.1.4 "Device cgroup is bounded" T3
    # The rules themselves: the quadlet's flags, and the device list of the
    # OCI spec crun ran the container from. Under cgroup v2 crun compiles that
    # list into a BPF program, which the kernel does not show as a list (and
    # podman inspect has no field for the rules), so the spec is the readable
    # form.
    ev_save cgroup-rules "EV-CONFIG: the quadlet's device-cgroup rules (its --device-cgroup-rule flags)" \
        grep -o -- '--device-cgroup-rule="[^"]*"' /etc/containers/systemd/desktop.container >/dev/null || true
    spec=$(oci_spec_path) \
        || fail "could not find the desktop container's OCI spec (podman inspect's OCIConfigPath, or config.json in its StaticDir)"
    devs=$(ev_save spec-devices "EV-STATE: the device list of the container's OCI spec ($spec), in order, which crun compiles into the cgroup v2 BPF program beside its own built-in allowances for standard nodes such as /dev/null (not listed here): deny everything, then the DRM nodes the quadlet adds as devices, then the quadlet's five rules" \
        spec_devices "$spec") \
        || fail "could not read the device list of the OCI spec $spec"
    for major in 13 116 226 4 5; do
        awk -v m="$major:*" '$1 == "allow" && $2 == "c" && $3 == m && $4 ~ /r/ && $4 ~ /w/ {f = 1} END {exit !f}' <<<"$devs" \
            || fail "the OCI spec's device list does not allow c $major:* for reading and writing: the quadlet's rule did not reach it"
    done
    ev_pass "the OCI spec's device list carries the quadlet's five rules: c 13:*, 116:*, 226:*, 4:* and 5:*, read and write"
    # One real minor per allowed major, read off the host's own nodes: an
    # evdev node, an ALSA control, a DRM render node (card0 if none), tty2
    # and ptmx - none of which an open with no read disturbs.
    probes="mem 1 1"
    for f in /dev/input/event0 /dev/snd/controlC0 /dev/dri/renderD128 /dev/tty2 /dev/ptmx; do
        [ "$f" != /dev/dri/renderD128 ] || [ -c "$f" ] || f=/dev/dri/card0
        [ -c "$f" ] || { ev_note "no $f on this host to take a minor from"; continue; }
        probes="$probes
$(basename "$f") $((0x$(stat -c %t "$f"))) $((0x$(stat -c %T "$f")))"
    done
    probe_out=$(ev_save probes "EV-STATE: mknod and open, as container root, in the container's own /dev: one line per node, with the error text where refused" \
        podman exec -i desktop sh -c '
            while read -r name major minor; do
                n=/dev/cgprobe-$name
                rm -f "$n"
                if ! out=$(mknod "$n" c "$major" "$minor" 2>&1); then
                    echo "$name $major:$minor mknod refused: $out"; continue
                fi
                if out=$(dd if="$n" of=/dev/null bs=1 count=0 2>&1); then
                    echo "$name $major:$minor opened"
                else
                    echo "$name $major:$minor open refused: $out"
                fi
                rm -f "$n"
            done' <<<"$probes") || true
    mem=$(grep '^mem 1:1 ' <<<"$probe_out" || true)
    grep -q 'refused: .*Operation not permitted' <<<"$mem" \
        || fail "/dev/mem (1:1) was not refused by the device cgroup: ${mem:-no result}"
    ev_pass "the device cgroup refuses /dev/mem: $mem"
    for major in 13 116 226 4 5; do
        line=$(awk -v m="$major" 'split($2, a, ":") && a[1] == m' <<<"$probe_out")
        [ -n "$line" ] || fail "no node of allowed major $major was probed"
        grep -q ' opened$' <<<"$line" || fail "a node of allowed major $major was refused: $line"
        ev_pass "a node of allowed major $major is reachable: $line"
    done
    ev_end
    log vp "  /dev/mem refused by the device cgroup; majors 13, 116, 226, 4 and 5 reachable"

    # /sys read-only. This is the sixth of the grants --privileged bundles and
    # the only one nothing else here would notice: a writable /sys is how a
    # container reaches host tunables (sysfs writes to kernel objects it does
    # not own), and the desktop never needs it - Xorg reads DRM through
    # /dev/dri, not through sysfs writes. Read it from the container's OWN
    # mount namespace: under --pid=host, /proc/1/mounts is the HOST's mount
    # table (whose /sys is legitimately rw) - reading it here failed this
    # assertion for two runs while the container's /sys was already ro, which
    # the in-container preflight had been reporting all along.
    #
    # Non-recursive: the quadlet's Mount= binds /sys without its submounts, so
    # none of the host's (securityfs, bpf, pstore, selinuxfs, its cgroup2 ...)
    # comes along. Podman still mounts its own there, from the OCI spec it
    # starts the container with: a read-only cgroup2 at /sys/fs/cgroup and
    # empty read-only tmpfs masks over its masked paths (/sys/firmware,
    # /sys/fs/selinux) - run 37328302222 found exactly those three. So every
    # mount under the container's /sys must be one the spec accounts for, in
    # the form the spec gives it, and none of the host's own may be there.
    log vp "/sys is read-only, and none of the host's mounts under it is in the container"
    ev_begin S6.1.5 "/sys is read-only and non-recursive" T3
    sys_mounts=$(ev_save sys-mounts "EV-STATE: the container's own mount table (desktop-init's /proc/<pid>/mounts) filtered to /sys and below" \
        podman exec desktop sh -c 'awk "\$2 == \"/sys\" || \$2 ~ \"^/sys/\"" "/proc/$(cat /run/desktop-init.pid)/mounts"') || true
    sysopts=$(awk '$2 == "/sys" {print $4}' <<<"$sys_mounts")
    [ -n "$sysopts" ] \
        || fail "could not read the container's /sys mount options from the init process's mount table"
    case ",$sysopts," in
        *,ro,*) log vp "  /sys mounted ro ($sysopts)" ;;
        *) fail "/sys is mounted '$sysopts', want ro - a writable /sys is one of the six grants --privileged bundles and nothing here needs it" ;;
    esac
    ev_pass "/sys is mounted ro ($sysopts) in the container's own mount table"
    spec=$(oci_spec_path) \
        || fail "could not find the desktop container's OCI spec (podman inspect's OCIConfigPath, or config.json in its StaticDir)"
    spec_sys=$(ev_save spec-sys "EV-CONFIG: what the container's OCI spec ($spec, the file crun started it from) puts at /sys and below: its mounts (destination, type, source, options), then its masked and read-only paths" \
        spec_sys "$spec") \
        || fail "could not read the /sys entries of the OCI spec $spec"
    host_sys=$(ev_save host-sys "EV-STATE: the VM host's own mounts under /sys (its /proc/self/mounts): what a recursive bind would have carried into the container" \
        awk '$2 ~ "^/sys/"' /proc/self/mounts) || true
    masks=
    while read -r path type opts; do
        [ -n "$path" ] || continue
        case ",$opts," in
            *,ro,*) ;;
            *) fail "$path ($type) under the container's /sys is mounted '$opts', not ro" ;;
        esac
        if [ "$path" = /sys/fs/cgroup ]; then
            grep -Eq '^mount /sys/fs/cgroup cgroup2? ' <<<"$spec_sys" \
                || fail "a $type is mounted at /sys/fs/cgroup in the container, and the OCI spec mounts nothing there"
            [ "$type" = cgroup2 ] || fail "/sys/fs/cgroup in the container is a $type, want the spec's cgroup2"
            ev_pass "/sys/fs/cgroup holds the container's own cgroup2, as its OCI spec asks, read-only ($opts)"
        elif grep -qxF "masked $path" <<<"$spec_sys"; then
            [ "$type" = tmpfs ] || fail "$path is one of the OCI spec's masked paths, but is mounted as $type, not podman's tmpfs mask"
            masks="$masks $path"
        elif grep -qxF "readonly $path" <<<"$spec_sys"; then
            ev_pass "$path is one of the OCI spec's read-only paths, bound onto itself read-only ($type, $opts)"
        else
            fail "$path ($type) is mounted under the container's /sys, and the OCI spec neither mounts, masks nor write-protects it: a host submount came along"
        fi
    done < <(awk '$2 ~ "^/sys/" {print $2, $3, $4}' <<<"$sys_mounts")
    if [ -n "$masks" ]; then
        # shellcheck disable=SC2086 # one argument per masked path
        mask_ls=$(ev_save masks "EV-STATE: podman's masks under /sys, listed inside the container: empty directories" \
            podman exec desktop sh -c 'for d; do echo "$d: $(ls -A "$d" | wc -l) entries"; done' sh $masks) || true
        for m in $masks; do
            grep -qxF "$m: 0 entries" <<<"$mask_ls" \
                || fail "podman's mask over $m is not empty: $(grep -F "$m: " <<<"$mask_ls" || echo 'no listing')"
        done
        ev_pass "podman's masks over$masks are empty read-only tmpfs mounts, as the OCI spec's masked paths ask"
    fi
    # The host's own: none of them may be in the container. At /sys/fs/cgroup
    # the container has its own cgroup2, checked above; a host cgroup2 carried
    # in would make it two there.
    carried=
    n_host=0
    while read -r _ path type _; do
        [ -n "$path" ] || continue
        n_host=$((n_host + 1))
        n=$(awk -v p="$path" -v t="$type" '$2 == p && $3 == t' <<<"$sys_mounts" | wc -l)
        if [ "$path" = /sys/fs/cgroup ] && [ "$type" = cgroup2 ]; then
            [ "$n" -le 1 ] || carried="$carried $path ($type)"
        elif [ "$n" -gt 0 ]; then
            carried="$carried $path ($type)"
        fi
    done <<<"$host_sys"
    [ "$n_host" -gt 0 ] || fail "the VM host shows no mounts under /sys, so their absence from the container proves nothing"
    [ -z "$carried" ] || fail "the host's own mounts under /sys reached the container:$carried"
    ev_pass "none of the VM host's $n_host mounts under /sys ($(awk '{print $3}' <<<"$host_sys" | sort -u | paste -sd' ')) is in the container: the bind is non-recursive"
    ev_save sys-fs "EV-STATE: /sys/fs inside the container, and how many entries /sys/fs/cgroup (the container's own cgroup tree) and /sys/fs/selinux (podman's mask) hold there" \
        podman exec desktop sh -c 'ls -la /sys/fs; for d in /sys/fs/cgroup /sys/fs/selinux; do echo "$d: $(ls -A "$d" 2>/dev/null | wc -l) entries"; done' >/dev/null || true
    ev_text cgroupns "EV-STATE: desktop-init's cgroup namespace and the VM host's (pid 1): if they differ, /sys/fs/cgroup in the container shows only the container's own cgroup subtree" \
        "desktop-init (host pid $initpid): $(readlink "/proc/$initpid/ns/cgroup" 2>&1)
host pid 1: $(readlink /proc/1/ns/cgroup 2>&1)"
    ev_end

    # S6.2.1: the host's pids are visible (the init pid check above) but
    # container root, which has no CAP_KILL and no CAP_SYS_PTRACE, can neither
    # signal a host process of another uid nor read pid 1's environ or
    # memory. A process of the same uid it can signal: with no user namespace
    # container root is host uid 0, and kill(2) needs no capability between
    # processes of one uid.
    log vp "container root cannot reach host processes beyond its own uid"
    ev_begin S6.2.1 "Host pid namespace, bounded by capability" T3
    # setpriv execs in place, so $! is the sleep itself, running as rocky.
    setpriv --reuid="$(id -u rocky)" --regid="$(id -g rocky)" --clear-groups sleep 300 &
    other=$!
    sleep 0.5
    ev_save other-proc "EV-PIDS: the host process of another uid the probe aims at: rocky's sleep" \
        ps -o pid,uid,user,comm -p "$other" >/dev/null || true
    ev_save proc-head "EV-STATE: ls /proc inside the container: the host's pids" \
        podman exec desktop sh -c 'ls /proc | grep -E "^[0-9]+$" | sort -n | head -5; echo "($(ls /proc | grep -cE "^[0-9]+$") pids)"' >/dev/null || true
    k=$(ev_save kill-other "EV-STATE: kill -0 $other (rocky's sleep) from container root, and its exit status" \
        podman exec desktop sh -c "kill -0 $other 2>&1; echo rc=\$?") || true
    e=$(ev_save environ-1 "EV-STATE: reading /proc/1/environ (the host's systemd) from container root, and its exit status" \
        podman exec desktop sh -c 'cat /proc/1/environ 2>&1 > /dev/null; echo rc=$?') || true
    m=$(ev_save mem-1 "EV-STATE: reading /proc/1/mem from container root, and its exit status" \
        podman exec desktop sh -c 'dd if=/proc/1/mem of=/dev/null bs=1 count=1 2>&1; echo rc=$?') || true
    kill "$other" 2>/dev/null || true
    grep -q 'Operation not permitted' <<<"$k" && ! grep -q '^rc=0$' <<<"$k" \
        || fail "container root could signal a host process of another uid: $(echo $k)"
    ev_pass "kill -0 on another uid's host process: $(grep -v '^rc=' <<<"$k" | head -1)"
    grep -qE 'Permission denied|Operation not permitted' <<<"$e" && ! grep -q '^rc=0$' <<<"$e" \
        || fail "container root could read pid 1's environ: $(echo $e)"
    ev_pass "pid 1's environ is refused: $(grep -v '^rc=' <<<"$e" | head -1)"
    grep -qE 'Permission denied|Operation not permitted' <<<"$m" && ! grep -q '^rc=0$' <<<"$m" \
        || fail "container root could read pid 1's memory: $(echo $m)"
    ev_pass "pid 1's memory is refused: $(grep -v '^rc=' <<<"$m" | head -1)"
    ev_end

    # S6.2.2: the host's network namespace, not a copy of it.
    ev_begin S6.2.2 "Host network namespace" T3
    ns_host=$(readlink /proc/self/ns/net)
    ns_ctr=$(podman exec desktop readlink /proc/self/ns/net 2>/dev/null || true)
    ev_text netns "EV-STATE: readlink /proc/self/ns/net on the VM host, then inside the container" "host: $ns_host
container: $ns_ctr"
    if_h=$(awk -F: 'NR > 2 {gsub(/ /, "", $1); print $1}' /proc/net/dev | sort)
    if_c=$(podman exec desktop sh -c "awk -F: 'NR > 2 {gsub(/ /, \"\", \$1); print \$1}' /proc/net/dev | sort" 2>/dev/null || true)
    ev_text ifaces-host "EV-STATE: the interface names in the VM host's /proc/net/dev" "$if_h"
    if_host=$EV_LAST
    ev_text ifaces-ctr "EV-STATE: the interface names in the container's /proc/net/dev (the image may not ship ip)" "$if_c"
    ev_diff ifaces "EV-DIFF: the interface names, host against container (no differences)" "$if_host" "$EV_LAST"
    [ -n "$ns_ctr" ] && [ "$ns_ctr" = "$ns_host" ] || fail "the container's network namespace is $ns_ctr, the host's $ns_host"
    ev_pass "the container's network namespace is the host's: $ns_host"
    [ -n "$if_c" ] && [ "$if_c" = "$if_h" ] || fail "the container's interfaces ($(echo $if_c)) differ from the host's ($(echo $if_h))"
    ev_pass "and it lists the host's interfaces: $(echo $if_h)"
    ev_end

    # S6.2.3, the SELinux half: label=disable runs the desktop as spc_t. The
    # AppArmor half is the runner's (smoke-deploy.sh): Rocky has no AppArmor.
    ev_begin S6.2.3 "SELinux separation off for the desktop, AppArmor unconfined" T3
    lbl=$(ev_save ps-z "EV-STATE: the SELinux label of desktop-init on the VM host (ps -o label)" ps -o label,pid,comm -p "$initpid") || true
    ev_save inspect-security "EV-STATE: podman inspect desktop: ProcessLabel, AppArmorProfile and the security options" \
        podman inspect desktop --format 'ProcessLabel={{.ProcessLabel}} AppArmorProfile={{.AppArmorProfile}} SecurityOpt={{json .HostConfig.SecurityOpt}}' >/dev/null || true
    grep -q ':spc_t:' <<<"$lbl" || fail "desktop-init does not run as spc_t: $(echo $lbl)"
    ev_pass "desktop-init runs as $(awk 'NR == 2 {print $1}' <<<"$lbl")"
    ev_end

    # rtkit is masked, so PipeWire's realtime priorities have to come from
    # RLIMIT_RTPRIO instead. Nothing else in this suite would notice if they
    # did not: the audio tests check that the right tone comes out, and
    # non-realtime audio still produces the right tone. Without this, the claim
    # that the rlimit replaces the capability would be untested.
    log vp "no rtkit and PipeWire has realtime anyway"
    ev_begin S4.3.2 "PipeWire holds SCHED_FIFO above priority 1 without rtkit" T3
    # rtkit used to be masked; with no systemd (and no D-Bus) in the image it
    # cannot even be activated. What must hold is the outcome: no rtkit
    # process, and PipeWire on the rlimit path regardless (asserted below).
    ev_save pgrep-rtkit "EV-STATE: pgrep -a rtkit-daemon on the host (the container shares its pid namespace): empty" \
        sh -c 'pgrep -a rtkit-daemon || echo "(no rtkit-daemon process)"' >/dev/null || true
    if podman exec desktop pgrep -x rtkit-daemon >/dev/null 2>&1; then
        fail "an rtkit-daemon process is running in the container - it cannot work without SYS_PTRACE/DAC_READ_SEARCH/NET_ADMIN and nothing should be starting it"
    fi
    ev_pass "no rtkit-daemon process is running"

    # The limit must have reached PIPEWIRE, which is not the same thing as
    # having reached the container. With no systemd the delivery is plain
    # rlimit inheritance (desktop-init -> start-session -> pipewire), which
    # removes the old DefaultLimit* relay failure mode entirely - but the
    # assertion deliberately stays on PipeWire's own /proc entry: it is the
    # process that needs the limit, and reading anything else (podman exec
    # ulimit, the quadlet file) has already produced a green while the real
    # stack ran with a limit of 0. The SCHED_FIFO assertion below is still
    # the one that matters.
    pwpid=$(podman exec desktop sh -c 'pgrep -x pipewire | head -1' 2>/dev/null || true)
    [ -n "$pwpid" ] || fail "no pipewire process in the container to check RLIMIT_RTPRIO on"
    ev_end
    # S4.3.1: all three of the quadlet's --ulimit values on PipeWire itself.
    ev_begin S4.3.1 "Rlimits reach PipeWire by inheritance" T3
    limits=$(ev_save pw-limits "EV-STATE: /proc/<pipewire>/limits (pid $pwpid): realtime priority 95, locked memory 67108864 bytes, nice 31, soft and hard" \
        cat "/proc/$pwpid/limits") || true
    for spec in "Max realtime priority:95" "Max locked memory:67108864" "Max nice priority:31"; do
        name=${spec%%:*} want=${spec##*:}
        got=$(awk -v n="$name" 'index($0, n) == 1 {sub(n, ""); print $1, $2}' <<<"$limits")
        [ "$got" = "$want $want" ] || fail "PipeWire's $name is '$got' (soft hard), want $want $want"
        ev_pass "PipeWire's $name: $want, soft and hard"
    done
    ev_end
    ev_begin S4.3.2 "PipeWire holds SCHED_FIFO above priority 1 without rtkit" T3
    # /proc/PID/limits column layout: Name (3 words here) Soft Hard Units.
    lim=$(podman exec desktop sh -c \
        "awk '/^Max realtime priority/{print \$5}' /proc/$pwpid/limits" 2>/dev/null || true)
    [ "$lim" = 95 ] \
        || fail "PipeWire's RLIMIT_RTPRIO hard limit is '$lim', want 95: the quadlet's --ulimit did not reach the audio stack (inheritance broke between desktop-init and pipewire)"

    # And the outcome: a PipeWire thread actually scheduled FIFO, at a priority
    # that means it got realtime PROPERLY.
    #
    # Two things here were wrong before and are worth stating so they are not
    # reintroduced. First, this used to filter threads by comm matching
    # /pipewire/, which cannot work: PipeWire's realtime threads are the data
    # loops, named data-loop.N, so the filter excluded exactly the threads it
    # was looking for and only ever saw the TS main threads. Select by the
    # daemon's PID and look at ALL of its threads instead.
    #
    # Second, SCHED_FIFO alone is too weak a claim. When module-rt falls back
    # to RTKit and RTKit is unavailable it logs "does not give us
    # MaxRealtimePriority, using 1" and takes SCHED_FIFO at priority 1 - still
    # FF, still a degraded audio stack. The configured priority is 60, so
    # requiring rtprio > 1 separates "got realtime" from "got the consolation
    # prize", which is the distinction this assertion exists to make.
    #
    # awk prints an integer and exits 0 on no match, so a count of zero arrives
    # as "0" rather than as a non-zero exit that the caller has to paper over.
    fifo=$(podman exec desktop sh -c \
        "ps -L -p $pwpid -o cls=,rtprio= 2>/dev/null | awk '\$1==\"FF\" && \$2+0 > 1 {n++} END{print n+0}'" \
        2>/dev/null || echo 0)
    if [ "${fifo:-0}" -le 0 ]; then
        # Three things can produce this, and they need different fixes, so say
        # which one it is rather than leaving the next reader to guess as I did
        # twice: module-rt never asked (it went to RTKit), it asked and the
        # kernel refused, or the limit is not where it needs to be.
        echo "---- diagnostics: why no realtime ----" >&2
        echo "-- every thread of the PipeWire daemon (FF = SCHED_FIFO, TS = normal)." >&2
        echo "   Not filtered by name: the realtime threads are the data loops," >&2
        echo "   named data-loop.N, so a /pipewire/ filter hides them:" >&2
        podman exec desktop sh -c "ps -L -p $pwpid -o pid,tid,cls,rtprio,comm" >&2 2>&1 || true
        echo "-- PipeWire's own rlimits:" >&2
        podman exec desktop sh -c "grep -iE 'realtime|locked' /proc/$pwpid/limits" >&2 2>&1 || true
        echo "-- can the desktop user take SCHED_FIFO at all? (separates 'module-rt" >&2
        echo "   never asked' from 'the kernel refused' - RT throttling in a" >&2
        echo "   non-root cgroup fails here even with the rlimit granted):" >&2
        podman exec -u desktop desktop sh -c '
            command -v chrt >/dev/null || { echo "   chrt not installed"; exit 0; }
            if chrt -f 10 true; then
                echo "   chrt -f 10: OK - the kernel allows it, so module-rt never asked"
            else
                echo "   chrt -f 10: REFUSED ($?) - the kernel is the blocker, not the config"
            fi' >&2 2>&1 || true
        echo "-- did module-rt consult RTKit? (any line here means rtkit.enabled" >&2
        echo "   did not reach it):" >&2
        podman logs desktop 2>&1 | grep 'mod.rt' | tail -8 >&2 || echo "   (none - good)" >&2
        echo "-- module-rt args as the daemon config actually has them:" >&2
        podman exec desktop sh -c \
            "grep -n -A 10 'libpipewire-module-rt' /usr/share/pipewire/pipewire.conf" >&2 2>&1 || true
        fail "no PipeWire thread holds SCHED_FIFO above priority 1: PipeWire did not get realtime properly, so masking rtkit cost the audio stack its priorities. The 'why no realtime' block above - just before the standard diagnostics dump - says which cause it is"
    fi
    ev_save pipewire-threads "EV-STATE: every thread of the PipeWire daemon (ps -L -p <pid> -o pid,tid,cls,rtprio,comm): the data-loop threads are FF (SCHED_FIFO) above priority 1" \
        podman exec desktop ps -L -p "$pwpid" -o pid,tid,cls,rtprio,comm >/dev/null || true
    ev_pass "$fifo PipeWire thread(s) hold SCHED_FIFO above priority 1 (RLIMIT_RTPRIO hard limit 95)"
    ev_end
    log vp "  rtkit masked, RLIMIT_RTPRIO=95, $fifo PipeWire thread(s) on SCHED_FIFO"

    log vp "verify-privileges passed"
}

hotplug_probe() {
    # Two numbers on one line, for the host to diff across a QEMU device_add:
    #   1. input device NODES visible inside the container
    #   2. input devices Xorg has actually added
    #
    # Both matter, and they fail differently. The node not appearing means the
    # container's /dev is not a live view of the host's - which is a real
    # question here, since ensure-vt-devices.sh notes /dev is a tmpfs and
    # creates the VT nodes itself. The node appearing but Xorg not adding it
    # means the uevent did not reach libinput, which is what Network=host is
    # for. Reporting one number could not tell those apart.
    local nodes adds
    nodes=$(podman exec desktop sh -c 'ls -1 /dev/input/event* 2>/dev/null | wc -l' 2>/dev/null || echo 0)
    # grep -c prints 0 and exits 1 when nothing matches; keep the 0, drop the status.
    adds=$(podman exec desktop sh -c \
        'grep -c "Adding input device" /home/desktop/.local/share/xorg/Xorg.0.log 2>/dev/null' \
        2>/dev/null || true)
    [ -n "${nodes:-}" ] || nodes=0
    [ -n "${adds:-}" ] || adds=0
    echo "$nodes $adds"
}

snd_probe() {
    # Two numbers on one line, for the host to diff across a QEMU
    # device_add of a usb-audio - the audio counterpart of hotplug_probe:
    #   1. ALSA card control NODES visible inside the container
    #   2. audio devices WirePlumber has actually picked up
    #
    # Both matter, and they fail differently. The node not appearing means
    # the container's /dev/snd is not a live view of the host's - which is
    # exactly what it was before it became a bind mount, and the bug this
    # probe exists to catch. The node appearing but WirePlumber not adding a
    # device means the uevent did not reach it, which is what Network=host
    # is for. Reporting one number could not tell those apart.
    local nodes devs
    nodes=$(podman exec desktop sh -c 'ls -1 /dev/snd/controlC* 2>/dev/null | wc -l' 2>/dev/null || echo 0)
    # Count PipeWire Device objects named alsa_card.*, via pw-cli rather than
    # `wpctl status`: wpctl prints friendly DESCRIPTIONS ("Built-in Audio"),
    # so there is no stable string to count, while pw-cli prints the object's
    # device.name. Devices only - wpctl's sinks/sources/streams are derived
    # from them and move for reasons unrelated to hotplug. The session user's
    # runtime dir has to be stated: `podman exec` inherits the container
    # init's environment, not the session's.
    devs=$(podman exec -u desktop -e XDG_RUNTIME_DIR=/run/user/61000 -e HOME=/home/desktop \
        desktop sh -c 'pw-cli ls Device 2>/dev/null | grep -c "device.name = \"alsa_card"' 2>/dev/null || true)
    [ -n "${nodes:-}" ] || nodes=0
    [ -n "${devs:-}" ] || devs=0
    echo "$nodes $devs"
}

input_sink_start() {
    # A sink xterm reads one line and records it. Geometry must match the
    # click coordinate the host computes (100x30 at +250+200 -> centre ~550,395).
    #
    # Called more than once (the plain input test, then again after the KVM
    # switch cycle), so retire any previous sink first: a leftover still inside
    # its `sleep 60` would sit at the same geometry and the click could land on
    # whichever ended up on top. pkill exits 1 when nothing matches, which is
    # the normal case on the first call.
    log is "launch a sink xterm that records one typed line"
    podman exec desktop pkill -f 'xterm -T inputtest' 2>/dev/null || true
    sleep 1
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

# --- read-only probes for the host's hotplug evidence -------------------------------
# What vm-e2e.sh saves before and after a QEMU device_add or device_del (the
# F3.9 and F4.7 stories), kept here so the host's ssh commands stay unquoted.
XORG_LOG=/home/desktop/.local/share/xorg/Xorg.0.log

# A command as the session user, with its runtime dir and display (see the
# podman flag conventions at the top): xinput, wpctl, pw-cli, pactl.
desk() { podman exec -u desktop -e XDG_RUNTIME_DIR=/run/user/61000 -e HOME=/home/desktop -e DISPLAY=:0 desktop "$@"; }

# The Xorg log's length now, and its lines after a length taken earlier.
xorg_log_lines() { podman exec desktop sh -c "wc -l < $XORG_LOG"; }
xorg_log_since() { podman exec desktop tail -n "+$(( ${1:?line count} + 1 ))" "$XORG_LOG"; }
# The same slice into a file. An empty slice says so, so that the file cannot
# be taken for a capture that failed.
xorg_slice() { # <line count> <file>
    xorg_log_since "$1" > "$2" 2>&1 || true
    [ -s "$2" ] || echo "(Xorg logged no line after line $1)" > "$2"
}

# pid, ppid, start time and name of the named processes in the container.
ctr_pids() { podman exec desktop ps -o pid,ppid,lstart,comm -C "${1:?comm,comm}"; }

# The X ids of the slave devices with exactly that name, one per line.
xi_id() { # <name>
    desk xinput list --short | awk -v want="$1" '
        /slave/ {
            line = $0; sub(/^.*↳ /, "", line)
            id = line; sub(/^.*id=/, "", id); sub(/[^0-9].*$/, "", id)
            name = line; sub(/[[:space:]]*id=.*$/, "", name)
            if (name == want) print id
        }'
}
# `xinput test` on one X device, in the background, line-buffered into
# /tmp/xinput-test.txt in the container: the events that device delivered.
xi_test_start() { # <X id>
    podman exec desktop rm -f /tmp/xinput-test.txt
    podman exec -d -u desktop -e DISPLAY=:0 -e HOME=/home/desktop desktop \
        sh -c "timeout 60 stdbuf -oL xinput test ${1:?X id} > /tmp/xinput-test.txt 2>&1"
}
xi_test_read() { podman exec desktop cat /tmp/xinput-test.txt 2>/dev/null || true; }
xi_test_stop() { podman exec desktop pkill -f 'xinput test' 2>/dev/null || true; }

# --- client journeys (F7.5, F7.6, F7.8): probes into a client pod --------------
# The host drives the desktop's events and keeps the evidence; these reach
# into a pod (ci/vm/journey-pod.yaml unless one is named) and look at the
# display. Files go into a pod through `kubectl exec -i ... cat`, never
# kubectl cp, which needs a tar the desktop image does not have. Anything that
# must keep running starts through journey_run, as a child of the pod's agent:
# started from a kubectl exec, it would last only as long as the exec (run
# 37325367423's first xterm never reached the display).
JPOD=journey
journey_start() { # [manifest] [pod]
    k3s kubectl apply -f "${1:-ci/vm/journey-pod.yaml}" >/dev/null
    k3s kubectl wait --for=condition=Ready "pod/${2:-$JPOD}" --timeout=180s >/dev/null
}
jx_in() { local pod=$1; shift; k3s kubectl exec "$pod" -- "$@"; }
# Start the script on stdin in the journey pod, as a child of its agent.
journey_run() { # <name> < script
    k3s kubectl exec -i "$JPOD" -- sh -c "cat > /tmp/run/.$1 && mv /tmp/run/.$1 /tmp/run/$1.sh"
}
# An xterm from the pod; its output in /tmp/<title>.log there. Its name
# (WM_CLASS instance) is what win_up looks for, and it keeps its title:
# without allowTitleOps off, the interactive bash it runs retitles it
# user@host:dir at its first prompt (EL's /etc/bashrc PROMPT_COMMAND).
journey_xterm() { # <title>
    journey_run "xterm-$1" <<EOF
exec xterm -name '$1' -T '$1' -xrm 'XTerm*allowTitleOps: false' -geometry 60x6+640+420 > /tmp/$1.log 2>&1
EOF
}
# The pod's applications, one per line: pid and command line.
journey_apps() { # [pod]
    k3s kubectl exec "${1:-$JPOD}" -- pgrep -a -f 'xterm|paplay|shot-loop|screenshot' || true
}
# Whether an xterm started with -name <name> is on the display, seen from
# the desktop: xwininfo -tree lists each window as
# 0x... "<title>": ("<name>" "XTerm"). The name, not the title: an xterm's
# shell can retitle its window, and EL's /etc/bashrc does at the first
# prompt - three runs (37325367423, 37327333528, 37328956567) looked for the
# title journey-1 under a window by then titled root@journey. The tree is
# read whole before it is searched: piped into grep -q under pipefail,
# xwininfo dies of SIGPIPE once grep has its match.
win_up() {
    local tree
    tree=$(podman exec -u desktop -e DISPLAY=:0 desktop xwininfo -root -tree 2>/dev/null) || return 1
    grep -qF "(\"$1\" \"XTerm\")" <<<"$tree"
}
win_wait() { wait_for "${2:-30}" 1 "an xterm named $1 on the display" win_up "$1"; }
# The display's windows, from the desktop (F7.5's xwininfo -root -tree).
win_tree() { podman exec -u desktop -e DISPLAY=:0 desktop xwininfo -root -tree; }
# EV-SHOT-CLIENT: the toolkit's screenshot run in the pod, its PNG on stdout.
client_shot() { # [pod]: the toolkit's binary, or the image's own where the pod has no toolkit
    k3s kubectl exec "${1:-$JPOD}" -- sh -c '"${DESKTOP_TOOLS_BIN:-/usr/libexec/desktop-tools}"/screenshot --to-stdout'
}
# A tone WAV put into the pod, and the tone played there by its pulse client
# in the background. The player's pid lands in /tmp/<tag>.pid, its start and
# end times (the guest's clock, which the pod shares) in .t0 and .t1, its
# exit status in .rc and its output in .log: a stream that stalls takes
# longer than the tone lasts.
journey_put() { # <tag> <hz> <seconds> [pod]
    gen_tone "$2" "/tmp/$1.wav" "$3"
    k3s kubectl exec -i "${4:-$JPOD}" -- sh -c "cat > /tmp/$1.wav" < "/tmp/$1.wav"
}
journey_tone() { # <tag> <hz> <seconds> [sink: PULSE_SINK, a sink by name]
    journey_put "$1" "$2" "$3"
    k3s kubectl exec "$JPOD" -- rm -f "/tmp/$1.rc" "/tmp/$1.t0" "/tmp/$1.t1" "/tmp/$1.pid"
    journey_run "tone-$1" <<EOF
date +%s.%N > /tmp/$1.t0
${4:+PULSE_SINK='$4' }paplay /tmp/$1.wav > /tmp/$1.log 2>&1 &
echo \$! > /tmp/$1.pid
wait \$!
r=\$?
date +%s.%N > /tmp/$1.t1
echo \$r > /tmp/$1.rc
EOF
}
# "exited N" and "played S s, from T0 to T1" once the player ended (else
# "running"), then "pid P", then its output.
journey_tone_status() { # <tag> [pod]
    local pod="${2:-$JPOD}" rc t
    rc=$(k3s kubectl exec "$pod" -- cat "/tmp/$1.rc" 2>/dev/null || true)
    if [ -n "$rc" ]; then
        echo "exited $rc"
        t=$(k3s kubectl exec "$pod" -- sh -c "cat /tmp/$1.t0 /tmp/$1.t1" 2>/dev/null | paste -sd' ')
        [ -z "$t" ] || awk '{printf "played %.2f s, from %s to %s\n", $2 - $1, $1, $2}' <<<"$t"
    else
        echo running
    fi
    echo "pid $(k3s kubectl exec "$pod" -- cat "/tmp/$1.pid" 2>/dev/null || echo unknown)"
    k3s kubectl exec "$pod" -- cat "/tmp/$1.log" 2>/dev/null || true
}
# A client records <source> for <seconds> into /tmp/<tag>.wav: the session
# user in the desktop container (rec-source), or a process of its own in the
# journey pod (journey-rec). SIGINT ends parecord, which then finishes the
# WAV; --preserve-status reports parecord's own exit status, not timeout's.
# --latency-msec=50, as in verify_record: with pipewire-pulse's default
# 64 KiB fragments a 3 s recording kept 1.11 s (run 37345104044's S4.7.9).
rec_source() { # <source> <seconds> <tag>
    local rc=0
    podman exec desktop rm -f "/tmp/${3:?tag}.wav"
    echo "\$ parecord --latency-msec=50 -d $1 /tmp/$3.wav, as the session user in the desktop container, ended by SIGINT after $2 s"
    desk timeout --preserve-status -s INT "${2:?seconds}" parecord --latency-msec=50 -d "${1:?source}" "/tmp/$3.wav" 2>&1 || rc=$?
    echo "parecord exited $rc"
    podman exec desktop ls -l "/tmp/$3.wav" 2>&1 || true
}
journey_rec() { # <source> <seconds> <tag>
    local rc=0
    k3s kubectl exec "$JPOD" -- rm -f "/tmp/${3:?tag}.wav"
    echo "\$ parecord --latency-msec=50 -d $1 /tmp/$3.wav, a new process in the journey pod, ended by SIGINT after $2 s"
    k3s kubectl exec "$JPOD" -- timeout --preserve-status -s INT "${2:?seconds}" parecord --latency-msec=50 -d "${1:?source}" "/tmp/$3.wav" 2>&1 || rc=$?
    echo "parecord exited $rc"
    k3s kubectl exec "$JPOD" -- ls -l "/tmp/$3.wav" 2>&1 || true
}
journey_file() { k3s kubectl exec "$JPOD" -- cat "${1:?path}"; }
# The audio graph's client streams through the export (F7.6's common set).
streams() {
    local t
    for t in sink-inputs source-outputs; do
        echo "== pactl list short $t"
        PULSE_SERVER=unix:/run/desktop-audio/pulse timeout 10 pactl list short "$t" 2>&1 \
            || echo "(no answer: the export is down)"
    done
}
# A file's identity in the pod: inode, change time (epoch seconds, then
# readable) and name. A socket made anew has a change time after the event
# that made it, whether or not the filesystem reused its inode number.
journey_stat() { # <path> [pod]
    k3s kubectl exec "${2:-$JPOD}" -- stat -c 'inode=%i ctime=%Z (%z) %n' "$1"
}
# The toolkit as the pod sees it (S7.8.2).
journey_tools_ls() { k3s kubectl exec "${1:-$JPOD}" -- sh -c 'ls -li "$DESKTOP_TOOLS_BIN"'; }
# S7.8.2's held screenshot: started before a desktop restart, it must still be
# running when the toolkit is republished, and finish once released. A full
# screen of random hex (the noise xterm) makes its PNG larger than a pipe
# holds, so writing it into a pipe that nobody reads yet blocks the binary
# mid-run, its executable mapped, until journey_held_release opens the tap.
journey_noise() { # an xterm over all of Virtual-1, filled with random hex
    journey_run noise <<'EOF'
exec xterm -name noise -T noise -geometry 170x58+0+0 -hold -e od -An -tx1 -w56 -N 4000 /dev/urandom > /tmp/noise.log 2>&1
EOF
}
journey_shot_size() { # the size of a PNG of the display as it is now
    k3s kubectl exec "$JPOD" -- sh -c '"$DESKTOP_TOOLS_BIN"/screenshot --to-stdout | wc -c'
}
journey_held_start() {
    k3s kubectl exec "$JPOD" -- rm -f /tmp/held.pid /tmp/held.rc /tmp/held.go /tmp/held.png /tmp/held.done
    journey_run held <<'EOF'
( sh -c 'echo $$ > /tmp/held.pid; exec "$DESKTOP_TOOLS_BIN"/screenshot --to-stdout'
  echo $? > /tmp/held.rc ) |
    ( while [ ! -f /tmp/held.go ]; do sleep 0.2; done; cat > /tmp/held.png )
touch /tmp/held.done
EOF
}
# The held screenshot as /proc shows it: alive or not, the executable it runs
# (a replaced file reads "(deleted)") and that executable's inode, then the
# toolkit file's own inode now.
journey_held_state() {
    k3s kubectl exec "$JPOD" -- sh -c 'p=$(cat /tmp/held.pid 2>/dev/null); echo "pid $p"
        if [ -n "$p" ] && kill -0 "$p" 2>/dev/null; then
            echo "alive yes"; echo "exe $(readlink /proc/$p/exe)"; echo "exe-inode $(stat -L -c %i /proc/$p/exe)"
        else
            echo "alive no"
        fi
        echo "file-inode $(stat -c %i "$DESKTOP_TOOLS_BIN"/screenshot)"'
}
# Open the tap: the held screenshot writes the rest of its PNG and exits.
journey_held_release() {
    k3s kubectl exec "$JPOD" -- sh -c 'touch /tmp/held.go
        for i in $(seq 100); do [ -f /tmp/held.done ] && break; sleep 0.2; done
        echo "rc $(cat /tmp/held.rc 2>/dev/null || echo none)"
        echo "png-bytes $(wc -c < /tmp/held.png 2>/dev/null || echo 0)"
        cat /tmp/run/held.out 2>/dev/null'
}
# S7.8.2's loop: the toolkit's screenshot every 0.5 s from the pod, each try
# logged as "<guest time> <try> <exit status> <its output>".
journey_loop_start() {
    k3s kubectl exec "$JPOD" -- rm -f /tmp/shot-loop.log
    journey_run shot-loop <<'EOF'
i=0
while :; do
    i=$((i + 1))
    t=$(date +%s.%N)
    "$DESKTOP_TOOLS_BIN"/screenshot /tmp/loop.png > /tmp/loop.out 2>&1
    r=$?
    echo "$t $i $r $(tr '\n' ' ' < /tmp/loop.out | cut -c1-160)"
    sleep 0.5
done >> /tmp/shot-loop.log 2>&1
EOF
}
journey_loop_stop() { k3s kubectl exec "$JPOD" -- pkill -f shot-loop.sh 2>/dev/null || true; }
journey_loop_log() { k3s kubectl exec "$JPOD" -- cat /tmp/shot-loop.log 2>/dev/null || true; }
# EV-LOG-DESKTOP for the toolkit: the publish lines of the desktop container
# now running (a restart makes a new one, with a log of its own).
# PipeWire's threads with their scheduling (class, realtime priority, nice)
# and pw-top's batch view, whose ERR column counts each node's xruns.
audio_sched() {
    local pw
    pw=$(pipewire_pid)
    echo "== ps -T -p ${pw:-?} -o tid,cls,rtprio,ni,comm (pipewire's threads)"
    [ -z "$pw" ] || ps -T -p "$pw" -o tid,cls,rtprio,ni,comm 2>&1
    echo "== pw-top -b -n 2 (the second iteration has the counts; ERR is each node's xruns)"
    desk timeout 10 pw-top -b -n 2 2>&1 || echo "(pw-top gave no answer)"
}
# The desktop container's log since a time (a Unix timestamp), its last 300 lines.
desktop_log_since() { podman logs --since "${1:?unix time}" desktop 2>&1 | tail -300; }
desktop_publish_log() {
    podman logs desktop 2>&1 | grep -E 'publish|Text file busy|ETXTBSY' || echo "(no publish line in podman logs desktop)"
}
journey_cleanup() { k3s kubectl delete pod journey early --ignore-not-found --wait=true >/dev/null 2>&1 || true; }
# X answering and the session's mwm up: the desktop is back.
x_up() { podman exec -u desktop -e DISPLAY=:0 desktop xdpyinfo >/dev/null 2>&1 && session_up; }

# A tone played by a pulse client in the background, as the session user:
# paplay, to <sink> (or the default sink with "-"), for <seconds>. Its output,
# exit status and pid land in /tmp/<tag>.log, .rc and .pid in the container,
# its start and end times (the guest's clock) in .t0 and .t1; tone_status
# says "running" until the .rc exists.
tone_start() { # <tag> <hz> <seconds> <sink|->
    local tag="${1:?tag}" hz="${2:?hz}" secs="${3:?seconds}" sink="${4:--}" dev=""
    gen_tone "$hz" "/tmp/$tag.wav" "$secs"
    podman cp "/tmp/$tag.wav" "desktop:/tmp/$tag.wav"
    podman exec desktop rm -f "/tmp/$tag.log" "/tmp/$tag.rc" "/tmp/$tag.t0" "/tmp/$tag.t1" "/tmp/$tag.pid"
    [ "$sink" = - ] || dev="--device=$sink"
    podman exec -d -u desktop -e XDG_RUNTIME_DIR=/run/user/61000 -e HOME=/home/desktop desktop \
        sh -c "date +%s.%N > /tmp/$tag.t0; paplay $dev /tmp/$tag.wav > /tmp/$tag.log 2>&1 & echo \$! > /tmp/$tag.pid; wait \$!; r=\$?; date +%s.%N > /tmp/$tag.t1; echo \$r > /tmp/$tag.rc"
}
# "exited N" and "played S s, from T0 to T1" once it ended (else "running"),
# then "pid P", then its output: the same report as journey_tone_status.
tone_status() { # <tag>
    local rc t
    rc=$(podman exec desktop cat "/tmp/${1:?tag}.rc" 2>/dev/null || true)
    if [ -n "$rc" ]; then
        echo "exited $rc"
        t=$(podman exec desktop sh -c "cat /tmp/$1.t0 /tmp/$1.t1" 2>/dev/null | paste -sd' ')
        [ -z "$t" ] || awk '{printf "played %.2f s, from %s to %s\n", $2 - $1, $1, $2}' <<<"$t"
    else
        echo running
    fi
    echo "pid $(podman exec desktop cat "/tmp/$1.pid" 2>/dev/null || echo unknown)"
    podman exec desktop cat "/tmp/$1.log" 2>/dev/null || true
}

# --- batch 4: the running session, X server and audio daemons -------------------
# The X session as it runs, read where it runs (Requirements.md S2.3.1,
# S3.2.4, S3.3.1, S3.8.5).
verify_runtime() {
    log rt "the session, the X server and the udev database as they run"
    wait_for 30 2 "an X session" session_up
    local xorg sid tty env_out keys want extra missing
    xorg=$(podman exec desktop pgrep -x Xorg | sed -n 1p || true)
    [ -n "$xorg" ] || fail "no Xorg to read"

    # S2.3.1: setsid -c made the session its own process session, with tty1
    # as its controlling tty; env -i made its environment exactly
    # run_session's list. The leader is startx (start-session execs it).
    ev_begin S2.3.1 "The session is its own process session on tty1" T3
    read -r sid tty <<<"$(ps -o sess=,tty= -p "$xorg")"
    ev_save session-procs "EV-PIDS: every process of the X session's process session, with its session id and tty (ps -s <sid>)" \
        ps -o pid,ppid,sess,tty,user,args -s "$sid" >/dev/null || true
    [ "$tty" = tty1 ] || fail "Xorg's controlling tty is '$tty', want tty1"
    ev_pass "Xorg (pid $xorg) is in process session $sid, with tty1 as its controlling tty"
    [ "$(ps -o comm= -p "$sid" 2>/dev/null)" = startx ] \
        || fail "the session's leader, pid $sid, is '$(ps -o comm= -p "$sid" 2>/dev/null)', not startx"
    [ "$(ps -o sess= -p "$sid" | tr -d ' ')" = "$sid" ] || fail "pid $sid does not lead its own process session"
    ev_pass "the session's leader is startx, pid $sid, leading its own process session"
    env_out=$(ev_save leader-environ "EV-STATE: the session leader's environment (tr '\\0' '\\n' < /proc/$sid/environ)" \
        sh -c "tr '\\0' '\\n' < /proc/$sid/environ") || true
    keys=$(sed -n 's/=.*//p' <<<"$env_out" | sort)
    want=$(printf '%s\n' DESKTOP_DISPLAY DESKTOP_SESSION_TAG DESKTOP_VT HOME LOGNAME PATH PWD SHELL SHLVL USER XDG_RUNTIME_DIR XDG_SESSION_TYPE | sort)
    extra=$(comm -13 <(echo "$want") <(echo "$keys") | paste -sd' ')
    missing=$(comm -23 <(echo "$want") <(echo "$keys") | paste -sd' ')
    [ -z "$extra" ] && [ -z "$missing" ] \
        || fail "the session leader's environment is not run_session's list plus PWD and SHLVL: extra '$extra', missing '$missing'"
    ev_pass "its environment is exactly run_session's ten variables plus PWD and SHLVL, with no container variable: $(echo $keys)"
    ev_end

    # S3.2.4: -nolisten tcp, and nothing on 6000-6063 on the host's network,
    # which the container shares.
    ev_begin S3.2.4 "Xorg does not listen on TCP" T3
    local ss_out args
    ss_out=$(ev_save ss "EV-STATE: ss -ltnp on the VM host (the container shares its network): every TCP listener" ss -ltnp) || true
    args=$(ev_save xorg-args "EV-STATE: Xorg's command line" ps -o args= -p "$xorg") || true
    grep -q -- '-nolisten tcp' <<<"$args" || fail "Xorg runs without -nolisten tcp: $args"
    ev_pass "Xorg runs with -nolisten tcp"
    ! awk 'NR > 1 {n = split($4, a, ":"); p = a[n] + 0; if (p >= 6000 && p <= 6063) found = 1} END {exit !found}' <<<"$ss_out" \
        || fail "something listens in the X range 6000-6063: $(awk 'NR > 1 && $4 ~ /:60[0-6][0-9]$/' <<<"$ss_out")"
    ev_pass "nothing listens on TCP 6000-6063 on the host"
    ev_end

    # S3.3.1: xhost +local: is in force, so a client of any uid, with the
    # socket and no cookie, connects.
    ev_begin S3.3.1 "Local access control is open" T3
    local xh probe
    xh=$(ev_save xhost "EV-STATE: xhost as the session user on :0" podman exec -u desktop -e DISPLAY=:0 desktop xhost) || true
    grep -qx 'LOCAL:' <<<"$xh" || fail "xhost does not list LOCAL: $(echo $xh)"
    ev_pass "xhost lists LOCAL:"
    probe=$(ev_save stranger "EV-STATE: a confined client of uid 4321 (no passwd entry, no cookie, no XAUTHORITY), given only desktop.local/display=all, runs xdpyinfo" \
        podman run --rm --user 4321:4321 --device desktop.local/display=all \
        localhost/desktop-container:latest sh -c 'id; printenv XAUTHORITY || echo NO_XAUTHORITY; xdpyinfo > /dev/null && echo XDPYINFO_OK') || true
    grep -q XDPYINFO_OK <<<"$probe" || fail "a client of uid 4321 with no cookie could not open :0: $(echo $probe)"
    ev_pass "a client of uid 4321, with no cookie, opens :0"
    ev_end

    # S3.8.5: the host's udev database, mounted ro, populated, and used.
    ev_begin S3.8.5 "The host udev database is mounted read-only and used" T3
    local udev_mnt n_data
    udev_mnt=$(ev_save udev-mount "EV-STATE: /run/udev in the container's own mount table (desktop-init's /proc/<pid>/mounts)" \
        podman exec desktop sh -c 'awk "\$2 == \"/run/udev\"" "/proc/$(cat /run/desktop-init.pid)/mounts"') || true
    n_data=$(podman exec desktop sh -c 'ls /run/udev/data | wc -l' 2>/dev/null || echo 0)
    ev_text udev-data "EV-STATE: the number of entries in the container's /run/udev/data" "$n_data"
    ev_save preflight "EV-LOG-DESKTOP: the container preflight's udev lines (podman logs desktop)" \
        sh -c "podman logs desktop 2>&1 | grep -E 'preflight: (PASS|WARN|FAIL): (host udev|no foreign seat|foreign seat)'" >/dev/null || true
    case ",$(awk '{print $4}' <<<"$udev_mnt")," in
        *,ro,*) ;;
        *) fail "/run/udev is not mounted ro in the container: $udev_mnt" ;;
    esac
    ev_pass "/run/udev is mounted ro: $(awk '{print $4}' <<<"$udev_mnt")"
    [ "${n_data:-0}" -gt 0 ] || fail "the container's /run/udev/data is empty"
    ev_pass "and it holds the host's database: $n_data entries in /run/udev/data"
    # Read whole, then searched: `podman logs | grep -q` under pipefail fails
    # on podman's SIGPIPE once grep has its match.
    local dlog
    dlog=$(podman logs desktop 2>&1 || true)
    grep -q 'preflight: PASS: host udev database mounted at /run/udev' <<<"$dlog" \
        || fail "the preflight did not pass its udev line"
    ev_pass "the container's preflight reports PASS: host udev database mounted at /run/udev"
    # The database is the host's, not a udevd's of the container's own. Under
    # --pid=host the host's systemd-udevd is in the container's process list
    # too, so the mount namespaces say whose each udevd is.
    local init_pid ctr_mnt udevds p
    init_pid=$(podman exec desktop cat /run/desktop-init.pid 2>/dev/null || true)
    ctr_mnt=$(readlink "/proc/${init_pid:-0}/ns/mnt" 2>/dev/null || true)
    [ -n "$ctr_mnt" ] || fail "could not read the container's mount namespace (desktop-init pid '${init_pid}')"
    udevds=$(for p in $(pgrep -x systemd-udevd; pgrep -x udevd); do
        printf '%s %s %s\n' "$p" "$(readlink "/proc/$p/ns/mnt" 2>/dev/null)" "$(tr '\0' ' ' < "/proc/$p/cmdline" 2>/dev/null)"
    done)
    ev_text udevds "EV-PIDS: every udevd process on the VM host (pid, mount namespace, command line), against the container's mount namespace, desktop-init's: $ctr_mnt" \
        "${udevds:-(no udevd process)}"
    if grep -qF " $ctr_mnt " <<<"$udevds"; then
        fail "a udevd runs in the container's mount namespace: $udevds"
    fi
    ev_pass "no udevd runs in the container's mount namespace ($ctr_mnt): $(grep -c . <<<"$udevds" || true) udevd process(es) on the host, none in it"
    ev_end
    log rt "verify-runtime passed"
}

# The active VT, from the kernel ("tty1").
active_vt() { cat /sys/class/tty/tty0/active; }
# Switch the console to VT n (chvt where kbd is installed, else VT_ACTIVATE).
switch_vt() { # <n>
    if command -v chvt >/dev/null; then chvt "$1"; return; fi
    python3 -c 'import fcntl, os, sys; fd = os.open("/dev/tty0", os.O_RDWR); fcntl.ioctl(fd, 0x5606, int(sys.argv[1])); fcntl.ioctl(fd, 0x5607, int(sys.argv[1]))' "$1"
}

# A killed X server, from everything around it (Requirements.md S2.3.2,
# S2.3.3, S3.2.5). Set up before the kill, the things that must go with the
# session and the things that must not:
#   - a sleep carrying the session's DESKTOP_SESSION_TAG, as one started from
#     the session's xterm would: it must die with the session;
#   - a sleep from `podman exec` without the tag, and a uid-61000 sleep on the
#     host: both must live, with PipeWire and the host's desktop-session-lead;
#   - the console on tty2: the new session must take tty1 back itself.
# The host records the display across the kill (EV-VIDEO) and after it.
verify_session_restart() {
    log sr "a killed X server: what goes with the session, what stays, and the VT"
    wait_for 30 2 "an X session" session_up
    local xorg sid tag mwm init pw lead t_kill t_clean n_lines
    xorg=$(podman exec desktop pgrep -x Xorg | sed -n 1p || true)
    [ -n "$xorg" ] || fail "no Xorg to kill"
    sid=$(ps -o sess= -p "$xorg" | tr -d ' ')
    tag=$(tr '\0' '\n' < "/proc/$sid/environ" | sed -n 's/^DESKTOP_SESSION_TAG=//p')
    [ -n "$tag" ] || fail "the session leader $sid carries no DESKTOP_SESSION_TAG"
    mwm=$(podman exec desktop pgrep -u desktop -x mwm | sed -n 1p || true)
    [ -n "$mwm" ] || fail "no mwm in the session"
    init=$(podman exec desktop cat /run/desktop-init.pid)
    pw=$(pipewire_pid)
    lead=$(systemctl show -p MainPID --value desktop-session.service)
    [ "${lead:-0}" != 0 ] || fail "desktop-session.service has no main process to watch"
    # The probes. The host's sleep has its own stdio: holding this ssh
    # session's, a failure here kept the session open until it ended
    # (run 37330812438: ten minutes). In the image, sleep is coreutils-single's
    # shebang script, so its command line reads
    # "/usr/bin/coreutils --coreutils-prog-shebang=sleep /usr/bin/sleep 600":
    # the probes are matched by how their command lines end.
    podman exec -d -u desktop -e DESKTOP_SESSION_TAG="$tag" desktop sleep 600
    podman exec -d -u desktop desktop sleep 601
    setpriv --reuid=61000 --regid=61000 --clear-groups sleep 602 </dev/null >/dev/null 2>&1 &
    sleep 1
    local tagged untagged hostside
    tagged=$(pgrep -u 61000 -f '(^|/)sleep 600$' | sed -n 1p || true)
    untagged=$(pgrep -u 61000 -f '(^|/)sleep 601$' | sed -n 1p || true)
    hostside=$(pgrep -u 61000 -f '(^|/)sleep 602$' | sed -n 1p || true)
    [ -n "$tagged" ] && [ -n "$untagged" ] && [ -n "$hostside" ] \
        || fail "the probe sleeps did not all start: tagged '$tagged', untagged '$untagged', host '$hostside'"

    ev_begin S2.3.3 "Session cleanup is scoped by session id and session tag, never by uid" T3
    ev_text roles "EV-STATE: what the uid-61000 listings below must show" "the session: leader $sid (startx), Xorg $xorg, mwm $mwm, tag $tag - must go
sleep 600, pid $tagged: podman exec WITH the session's tag, standing in for one started from the session's xterm - must go
sleep 601, pid $untagged: podman exec without the tag - must stay
sleep 602, pid $hostside: a uid-61000 process on the host - must stay
pipewire, pid $pw: the audio tree - must stay
desktop-session-lead, pid $lead: the host's login session - must stay"
    ev_save uid61000-before "EV-PIDS: every uid-61000 process on the host before Xorg is killed, with its session id" \
        ps -u 61000 -o pid,ppid,sess,tty,args >/dev/null || true
    u_before=$EV_LAST
    ev_end
    ev_begin S3.2.5 "The session activates its VT, so the operator sees it" T3
    ev_text vt-before "EV-STATE: the active VT before (/sys/class/tty/tty0/active)" "$(active_vt)"
    [ "$(active_vt)" = tty1 ] || fail "the active VT is $(active_vt) before the test, not tty1"
    switch_vt 2
    sleep 1
    ev_text vt-switched "EV-STATE: the active VT after switching the console to tty2" "$(active_vt)"
    [ "$(active_vt)" = tty2 ] || fail "the console did not switch to tty2: $(active_vt)"
    ev_pass "the console was on tty2 when Xorg was killed"
    ev_end

    ev_begin S2.3.2 "The session restarts after Xorg exits, and the operator gets the desktop back" T3
    ev_save pids-before "EV-PIDS: desktop-init, Xorg and mwm before the kill" \
        ps -o pid,ppid,sess,lstart,comm -p "$init,$xorg,$mwm" >/dev/null || true
    p_before=$EV_LAST
    n_lines=$(podman logs desktop 2>&1 | wc -l)
    t_kill=$(date +%s.%N)
    podman exec -u desktop desktop pkill -u desktop -x Xorg || true
    ev_note "Xorg (pid $xorg) killed at $(date -u +%Y-%m-%dT%H:%M:%S.%3NZ), the console on tty2"
    # Gone: no process left in the old session or carrying the old tag.
    t_clean=""
    for _ in $(seq 40); do
        if [ -z "$(ps -o pid= -s "$sid" 2>/dev/null)" ] && [ -z "$(grep -lzxF "DESKTOP_SESSION_TAG=$tag" /proc/[0-9]*/environ 2>/dev/null)" ]; then
            t_clean=$(date +%s.%N); break
        fi
        sleep 0.25
    done
    xn() { local p; p=$(podman exec desktop pgrep -x Xorg 2>/dev/null | sed -n 1p || true); [ -n "$p" ] && [ "$p" != "$xorg" ] && session_up; }
    wait_for 45 1 "a new X session (a new Xorg and mwm)" xn
    wait_for 15 1 "the display to answer" x_answers
    ev_note "a new Xorg and mwm up, the display answering, at $(date -u +%Y-%m-%dT%H:%M:%S.%3NZ)"
    local xorg2 mwm2
    xorg2=$(podman exec desktop pgrep -x Xorg | sed -n 1p || true)
    mwm2=$(podman exec desktop pgrep -u desktop -x mwm | sed -n 1p || true)
    ev_save pids-after "EV-PIDS: desktop-init, Xorg and mwm after the restart" \
        ps -o pid,ppid,sess,lstart,comm -p "$init,$xorg2,$mwm2" >/dev/null || true
    ev_diff pids "EV-DIFF: desktop-init, Xorg and mwm across the restart (Xorg and mwm new, desktop-init the same)" "$p_before" "$EV_LAST"
    ev_save log "EV-LOG-DESKTOP: podman logs desktop from the kill on" \
        sh -c "podman logs desktop 2>&1 | tail -n +$((n_lines + 1))" >/dev/null || true
    local since
    since=$(podman logs desktop 2>&1 | tail -n +$((n_lines + 1)) || true)
    grep -q 'desktop-init: session exited (rc=[0-9]*); restarting in 3s' <<<"$since" \
        || fail "desktop-init did not log 'session exited (rc=N); restarting in 3s' after the kill"
    ev_pass "desktop-init logged the session's exit and its restart in 3 s"
    [ -n "$xorg2" ] && [ "$xorg2" != "$xorg" ] && [ -n "$mwm2" ] && [ "$mwm2" != "$mwm" ] \
        || fail "Xorg and mwm are not new: Xorg $xorg -> $xorg2, mwm $mwm -> $mwm2"
    [ "$(podman exec desktop cat /run/desktop-init.pid)" = "$init" ] || fail "desktop-init changed: $init -> $(podman exec desktop cat /run/desktop-init.pid)"
    ev_pass "a new session: Xorg $xorg -> $xorg2, mwm $mwm -> $mwm2, under the same desktop-init ($init); the display answers"
    ev_end

    ev_begin S2.3.3 "Session cleanup is scoped by session id and session tag, never by uid" T3
    ev_save uid61000-after "EV-PIDS: every uid-61000 process on the host after the restart" \
        ps -u 61000 -o pid,ppid,sess,tty,args >/dev/null || true
    ev_diff uid61000 "EV-DIFF: the host's uid-61000 processes across the kill: the old session and the tagged sleep gone, the rest unchanged" "$u_before" "$EV_LAST"
    [ -n "$t_clean" ] || fail "10 s after the kill, processes of the old session ($sid) or its tag ($tag) were still running"
    local took
    took=$(awk -v a="$t_kill" -v b="$t_clean" 'BEGIN {printf "%.2f", b - a}')
    python3 -c 'import sys; sys.exit(0 if float(sys.argv[1]) <= 6.0 else 1)' "$took" \
        || fail "the old session's processes took $took s to go, more than the 6 s TERM-then-KILL allows"
    ev_pass "no process of the old session ($sid) or with its tag remained $took s after the kill"
    for p in "$mwm" "$tagged"; do
        ! kill -0 "$p" 2>/dev/null || fail "pid $p, which belonged to the old session, is still running"
    done
    ev_pass "the old mwm ($mwm) and the tagged sleep ($tagged) are gone"
    for p in "$untagged" "$hostside" "$pw" "$lead"; do
        kill -0 "$p" 2>/dev/null || fail "pid $p, outside the session, was killed with it"
    done
    ev_pass "the untagged podman-exec sleep ($untagged), the host's uid-61000 sleep ($hostside), PipeWire ($pw) and desktop-session-lead ($lead) all kept running"
    ev_end
    kill "$untagged" "$hostside" 2>/dev/null || true

    ev_begin S3.2.5 "The session activates its VT, so the operator sees it" T3
    ev_text vt-after "EV-STATE: the active VT after the new session came up" "$(active_vt)"
    [ "$(active_vt)" = tty1 ] || fail "after the restart the active VT is $(active_vt), not tty1: the new session did not take its VT"
    ev_pass "the new session switched the console back to tty1 by itself"
    ev_end
    log sr "verify-session-restart passed"
}
x_answers() { podman exec -u desktop -e DISPLAY=:0 desktop xdpyinfo >/dev/null 2>&1; }

# Each daemon's own exit restarts the whole stack (Requirements.md S2.4.2;
# what PipeWire's exit leaves alone is S4.5.2's). The host plays a tone
# through the result.
verify_audio_restarts() {
    log ar "pipewire, wireplumber, then pipewire-pulse, each alone: each takes the stack down and back"
    ev_begin S2.4.2 "Any daemon exiting restarts the whole stack" T3
    local victim before after n_lines b a since
    for victim in pipewire wireplumber pipewire-pulse; do
        wait_for 30 2 "the audio export" audio_reachable
        before=$(audio_trio)
        ev_save "pids-before-$victim" "EV-PIDS: the three audio daemons before $victim is killed" \
            ctr_pids pipewire,wireplumber,pipewire-pulse >/dev/null || true
        b=$EV_LAST
        n_lines=$(podman logs desktop 2>&1 | wc -l)
        podman exec -u desktop desktop pkill -u desktop -x "$victim" || true
        ev_note "$victim killed at $(date -u +%Y-%m-%dT%H:%M:%S.%3NZ)"
        trio_new() { a=$(audio_trio); [ -n "$a" ] && all_new "$before" "$a" && audio_reachable; }
        wait_for 45 1 "three new audio daemons and the export answering" trio_new
        after=$(audio_trio)
        ev_save "pids-after-$victim" "EV-PIDS: the three audio daemons after the stack came back" \
            ctr_pids pipewire,wireplumber,pipewire-pulse >/dev/null || true
        ev_diff "pids-$victim" "EV-DIFF: the audio daemons across $victim's exit (all three new)" "$b" "$EV_LAST"
        ev_save "log-$victim" "EV-LOG-DESKTOP: podman logs desktop from $victim's kill on" \
            sh -c "podman logs desktop 2>&1 | tail -n +$((n_lines + 1))" >/dev/null || true
        since=$(podman logs desktop 2>&1 | tail -n +$((n_lines + 1)) || true)
        grep -q "start-audio: $victim exited" <<<"$since" \
            || fail "start-audio did not log '$victim exited'"
        grep -q 'desktop-init: audio stack exited (rc=[0-9]*); restarting in 3s' <<<"$since" \
            || fail "desktop-init did not log the audio stack's restart after $victim's exit"
        ev_pass "killing $victim alone: start-audio logged '$victim exited', the stack restarted, all three daemons new ($before -> $after), the export answers"
    done
    ev_end
    log ar "verify-audio-restarts passed"
}
# "pipewire=P wireplumber=W pipewire-pulse=Q" (empty unless all three run).
audio_trio() {
    local pw wp pp
    pw=$(podman exec desktop pgrep -x pipewire 2>/dev/null | sed -n 1p || true)
    wp=$(podman exec desktop pgrep -x wireplumber 2>/dev/null | sed -n 1p || true)
    pp=$(podman exec desktop pgrep -x pipewire-pulse 2>/dev/null | sed -n 1p || true)
    [ -n "$pw" ] && [ -n "$wp" ] && [ -n "$pp" ] && echo "pipewire=$pw wireplumber=$wp pipewire-pulse=$pp"
}
all_new() { # <trio before> <trio after>: every daemon's pid changed
    local d
    for d in pipewire wireplumber pipewire-pulse; do
        [ "$(tr ' ' '\n' <<<"$1" | grep "^$d=")" != "$(tr ' ' '\n' <<<"$2" | grep "^$d=")" ] || return 1
    done
}

# S2.4.7: the unprivileged rocky user on the VM host reaches the export.
# Prints what the evidence needs; plays <hz> for <seconds>.
play_as_rocky() { # <hz> <seconds>
    gen_tone "${1:?hz}" /tmp/rocky.wav "${2:-3}"
    chmod 644 /tmp/rocky.wav
    echo "== id"; runuser -u rocky -- id
    echo "== ls -l /run/desktop-audio"; ls -l /run/desktop-audio
    echo "== pactl info, as rocky"
    runuser -u rocky -- env PULSE_SERVER=unix:/run/desktop-audio/pulse pactl info || { echo "pactl info failed: $?"; return 1; }
    echo "== paplay, as rocky"
    runuser -u rocky -- env PULSE_SERVER=unix:/run/desktop-audio/pulse paplay /tmp/rocky.wav; echo "paplay exited $?"
}

# --- operator stories (E11) -------------------------------------------------------
# ci/vm/operator-e2e.py drives the desktop the way the operator does - every
# pointer and key event through QEMU's devices - and LOOKS at X from here: a
# container of the lean client image holding only desktop.local/display, in
# which it runs xwininfo and xprop. The observer sends no input.
operator_setup() {
    # phase2 loads the same archive again; a second load of an image that is
    # already there changes nothing.
    log op "load the lean client image: the observer, and the sound story's player"
    podman load -q -i /tmp/images-testclient.tar >/dev/null
    log op "start the observer: a confined client holding the display device and nothing else"
    podman rm -f op-observer >/dev/null 2>&1 || true
    podman run -d --name op-observer --device desktop.local/display=all \
        localhost/desktop-testclient:latest >/dev/null
    # podman applies a CDI device's edits to the container's own process,
    # not to `podman exec` sessions: the X socket mount is there for every
    # process in the container, but the injected DISPLAY is in PID 1's
    # environment only. Read it from there, so the spec still says where the
    # display is; operator-e2e.py passes it to every exec into the observer.
    disp=$(podman exec op-observer sh -c 'tr "\0" "\n" </proc/1/environ' | sed -n 's/^DISPLAY=//p') \
        || fail "could not read the observer's environment"
    [ "$disp" = ":0" ] \
        || fail "the observer's CDI-injected DISPLAY is '$disp', want :0 (operator-e2e.py assumes :0)"
    wait_for 20 1 "the observer to read the window tree" \
        podman exec -e DISPLAY="$disp" op-observer xwininfo -root -tree

    # The terminals earlier phases leave up: phase-deploy's deploy-proof
    # xterm, which every shard runs first, and the input tests' sink
    # terminals, which idle in a `sleep 60` after their read. The operator's
    # first story looks at the desktop as the session leaves it, so they go
    # first - as the session user, since container root holds no CAP_KILL
    # (verify_audio_lifecycle). pgrep/pkill patterns are extended regexps.
    log op "retire the terminals earlier phases left up"
    podman exec -u desktop desktop pkill -u desktop -f 'xterm -T (deploy-proof|inputtest)' || true
    wait_for 15 1 "the earlier phases' terminals to exit" \
        sh -c '! podman exec desktop pgrep -u desktop -f "xterm -T (deploy-proof|inputtest)" >/dev/null'

    # One continuous 150 s stream for the sound story, long enough to outlast
    # every command typed under it. 441 frames hold exactly 11 cycles of
    # 1100 Hz at 44.1 kHz, so repeating them is seamless.
    log op "write the stories' tones: 1100 Hz for 150 s (the sound story's), 660 Hz for 3 s"
    python3 - <<'EOF'
import math, wave
rate, amp = 44100, 0.5
# Each file is one stretch repeated: rate / gcd(freq, rate) samples, the
# shortest that holds whole cycles of its pitch (441 for 1100 Hz, 735 for
# 660 Hz). A stretch that cut a cycle short would repeat as a different
# sound: 441 samples of 660 Hz, repeated, came out at 700 Hz.
for path, freq, secs in (("/tmp/op-tone-1100.wav", 1100, 150), ("/tmp/op-tone-660-3s.wav", 660, 3)):
    n = rate // math.gcd(freq, rate)
    cycle = bytearray()
    for i in range(n):
        s = int(amp * 32767 * math.sin(2 * math.pi * freq * i / rate))
        b = s.to_bytes(2, "little", signed=True)
        cycle += b + b
    w = wave.open(path, "wb")
    w.setnchannels(2)
    w.setsampwidth(2)
    w.setframerate(rate)
    w.writeframes(bytes(cycle) * (rate * secs // n))
    w.close()
EOF
    log op "operator-setup done"
}

operator_teardown() {
    # Every container the stories started is named op-*, the observer too.
    podman ps -a --format '{{.Names}}' | grep '^op-' | xargs -r podman rm -f -t 2 >/dev/null 2>&1 || true
    rm -f /tmp/op-tone-1100.wav /tmp/op-tone-660-3s.wav /tmp/op-host-whoami
    log op "operator-teardown done"
}

apply_client() { # $1: pod name; $2: xterm geometry (default: the example's)
    # Reuse the example client (a long-running xterm), renamed, titled after
    # the pod, placed where asked and pointed at the locally-imported image.
    sed -e "s/name: x11-client-demo/name: $1/" \
        -e "s/\"CDI demo\"/\"$1\"/" \
        -e "s/80x24+200+200/${2:-80x24+200+200}/" \
        -e 's|image: desktop-container:latest|image: localhost/desktop-container:latest|' \
        examples/x11-client-pod.yaml | k3s kubectl apply -f -
}

# verify_split is the test the capability split exists for: each device
# must grant its own half and NOTHING of the other's. Without it, "we split
# the device" is a statement about two YAML files rather than an observed
# property of running pods.
verify_split() {
    log vsp "apply the narrow pods: one requests display only, one audio only"
    k3s kubectl apply -f ci/vm/display-only-pod.yaml
    k3s kubectl apply -f ci/vm/audio-only-pod.yaml
    for pod in display-only audio-only; do
        wait_for 30 4 "$pod running" \
            sh -c "k3s kubectl get pod $pod -o jsonpath='{.status.phase}' | grep -q Running"
    done

    log vsp "display-only: has the display"
    got=$(k3s kubectl exec display-only -- printenv DISPLAY 2>/dev/null || true)
    [ "$got" = ":0" ] || fail "display-only DISPLAY='$got', want :0"
    timeout 20 k3s kubectl exec display-only -- sh -c 'xdpyinfo >/dev/null' \
        || fail "display-only could not open the display"

    log vsp "display-only: has NO toolkit (it never requested desktop.local/tools)"
    # Binaries are not a capability - a client with the display can already
    # screenshot for itself under X11 - but the toolkit must still arrive only
    # where it was asked for, or "one device, one thing" is just a claim about
    # yaml files. display-only requests display alone, so the mount must be
    # absent and the env var unset. (S7.2.4's other half, the pod that asks
    # getting both, is verify_screenshot's.)
    ev_begin S7.2.4 "Clients receive it read-only via DESKTOP_TOOLS_BIN" T3
    ev_save display-only-env "EV-STATE: the environment of the display-only pod, which requests desktop.local/display alone: no DESKTOP_TOOLS_BIN" \
        k3s kubectl exec display-only -- env >/dev/null || true
    if k3s kubectl exec display-only -- printenv DESKTOP_TOOLS_BIN >/dev/null 2>&1; then
        fail "display-only leaked DESKTOP_TOOLS_BIN - the tools device's edits reached a pod that never requested it"
    fi
    ev_pass "a pod that did not request desktop.local/tools has no DESKTOP_TOOLS_BIN"
    ev_save display-only-mountinfo "EV-STATE: the display-only pod's mountinfo: the X socket directory is there, /opt/desktop-tools/bin is not" \
        k3s kubectl exec display-only -- cat /proc/self/mountinfo >/dev/null || true
    if k3s kubectl exec display-only -- sh -c 'grep -q " /opt/desktop-tools/bin " /proc/self/mountinfo' 2>/dev/null; then
        fail "display-only has the toolkit mounted without requesting desktop.local/tools"
    fi
    ev_pass "and no toolkit mount"
    ev_end

    # S7.3.2: what each narrow pod holds, kept: its environment, its mounts
    # and whether xdpyinfo opens the display from it.
    ev_begin S7.3.2 "Split holds in pods" T3
    split_probe display-only
    d_env=$P_ENV d_mnt=$P_MNT d_rc=$P_RC
    split_probe audio-only
    a_env=$P_ENV a_mnt=$P_MNT a_rc=$P_RC

    log vsp "display-only: has NO audio (env or mount)"
    for var in PULSE_SERVER PIPEWIRE_REMOTE; do
        if k3s kubectl exec display-only -- printenv "$var" >/dev/null 2>&1; then
            fail "display-only leaked $var - the audio device's edits reached a display-only pod"
        fi
    done
    # mountinfo, not `test -e`: the image ships a tmpfiles.d entry for
    # /run/desktop-audio, so path existence would be the wrong question.
    # What must be absent is the INJECTED MOUNT.
    if k3s kubectl exec display-only -- \
        grep -q ' /run/desktop-audio ' /proc/self/mountinfo 2>/dev/null; then
        fail "display-only has the audio mount - the audio device's edits leaked"
    fi
    grep -qx 'DISPLAY=:0' <<<"$d_env" && [ "$d_rc" = 0 ] \
        || fail "display-only: DISPLAY '$(grep '^DISPLAY=' <<<"$d_env")', xdpyinfo exit $d_rc"
    ev_pass "display-only has the display: DISPLAY=:0, and xdpyinfo opens it (exit 0)"
    ! grep -Eq '^(PULSE_SERVER|PIPEWIRE_REMOTE|DESKTOP_TOOLS_BIN)=' <<<"$d_env" \
        || fail "display-only has audio or toolkit variables: $(grep -E '^(PULSE_SERVER|PIPEWIRE_REMOTE|DESKTOP_TOOLS_BIN)=' <<<"$d_env" | paste -sd' ')"
    ! grep -Eq '^(/run/desktop-audio|/opt/desktop-tools/bin) ' <<<"$d_mnt" \
        || fail "display-only has the audio or the toolkit mount"
    ev_pass "and no audio or toolkit: no PULSE_SERVER, PIPEWIRE_REMOTE or DESKTOP_TOOLS_BIN, no /run/desktop-audio or /opt/desktop-tools/bin mount"

    log vsp "audio-only: has working audio"
    got=$(k3s kubectl exec audio-only -- printenv PULSE_SERVER 2>/dev/null || true)
    [ "$got" = "unix:/run/desktop-audio/pulse" ] || fail "audio-only PULSE_SERVER='$got'"
    got=$(k3s kubectl exec audio-only -- printenv PIPEWIRE_REMOTE 2>/dev/null || true)
    [ "$got" = "/run/desktop-audio/pipewire-0" ] || fail "audio-only PIPEWIRE_REMOTE='$got'"
    # Not just present: actually usable, so the narrow device is a real
    # grant rather than two env vars pointing at nothing.
    timeout 60 k3s kubectl exec audio-only -- sh -c \
        'until pactl info >/dev/null 2>&1; do sleep 2; done' \
        || fail "audio-only could not talk to the pulse socket"
    ev_save audio-only-pactl "EV-STATE: pactl info run in the audio-only pod, over the injected PULSE_SERVER" \
        k3s kubectl exec audio-only -- pactl info >/dev/null || true
    ev_pass "audio-only has the audio: PULSE_SERVER and PIPEWIRE_REMOTE injected, and pactl info answers over them (the host hears it play next)"

    log vsp "audio-only: has NO display (env or mount)"
    if k3s kubectl exec audio-only -- printenv DISPLAY >/dev/null 2>&1; then
        fail "audio-only leaked DISPLAY - a sound-only workload must not reach the X session"
    fi
    if k3s kubectl exec audio-only -- \
        grep -q ' /tmp/.X11-unix ' /proc/self/mountinfo 2>/dev/null; then
        fail "audio-only has the X11 mount - the display device's edits leaked"
    fi
    # The capability it must not have, stated as the capability itself.
    if timeout 20 k3s kubectl exec audio-only -- sh -c 'xdpyinfo >/dev/null' 2>/dev/null; then
        fail "audio-only opened the X display - it can keylog the session"
    fi
    ! grep -q '^DISPLAY=' <<<"$a_env" && ! grep -q '^/tmp/.X11-unix ' <<<"$a_mnt" && [ "$a_rc" != 0 ] \
        || fail "audio-only: DISPLAY '$(grep '^DISPLAY=' <<<"$a_env")', X socket mount '$(grep '^/tmp/.X11-unix ' <<<"$a_mnt")', xdpyinfo exit $a_rc"
    ev_pass "audio-only has no display: no DISPLAY, no /tmp/.X11-unix mount, and xdpyinfo fails (exit $a_rc)"
    ev_end

    # The pods stay: the host plays a tone from audio-only and listens
    # (S7.3.2's EV-AUDIO), then removes them (split-cleanup).
    log vsp "each device grants its own half and nothing more"
    log vsp "verify-split passed"
}

# One narrow pod's environment, mounts and xdpyinfo verdict, kept in the open
# story; the values in P_ENV, P_MNT and P_RC.
split_probe() { # <pod>
    local out
    P_ENV=$(k3s kubectl exec "$1" -- env | sort) || fail "could not read the $1 pod's environment"
    ev_text "$1-env" "EV-STATE: the $1 pod's environment (env, sorted)" "$P_ENV"
    P_MNT=$(k3s kubectl exec "$1" -- cat /proc/self/mountinfo | mount_points) || fail "could not read the $1 pod's mounts"
    ev_text "$1-mounts" "EV-STATE: the $1 pod's mounts: mount point and filesystem type from /proc/self/mountinfo, sorted" "$P_MNT"
    P_RC=0
    out=$(timeout 20 k3s kubectl exec "$1" -- xdpyinfo 2>&1) || P_RC=$?
    ev_text "$1-xdpyinfo" "EV-STATE: xdpyinfo run in the $1 pod: its first lines, then its exit status" "$(printf '%s\n' "$out" | sed -n 1,6p)
xdpyinfo exit: $P_RC"
}
split_cleanup() { k3s kubectl delete pod display-only audio-only --ignore-not-found --wait=true >/dev/null 2>&1 || true; }

pod_state() { # $1: pod - who its container is, for EV-PIDS before and after an event
    local cid pid
    k3s kubectl get pod "$1" -o jsonpath='{range .status.containerStatuses[*]}container={.name} restartCount={.restartCount} containerID={.containerID} startedAt={.state.running.startedAt}{"\n"}{end}'
    cid=$(k3s kubectl get pod "$1" -o jsonpath='{.status.containerStatuses[0].containerID}')
    pid=$(k3s crictl -r unix:///run/crio/crio.sock inspect "${cid#*://}" 2>/dev/null \
        | python3 -c 'import json, sys; print(json.load(sys.stdin)["info"]["pid"])' 2>/dev/null) \
        || pid="unknown (crictl inspect gave no .info.pid)"
    echo "main process, host pid: $pid"
}

# The host pid of a pod's main process (its first container's), from CRI-O.
pod_main_pid() { # <pod>
    local cid info
    cid=$(k3s kubectl get pod "$1" -o jsonpath='{.status.containerStatuses[0].containerID}') || return 1
    [ -n "$cid" ] || return 1
    info=$(k3s crictl -r unix:///run/crio/crio.sock inspect "${cid#*://}" 2>/dev/null) || return 1
    python3 -c 'import json, sys; print(json.load(sys.stdin)["info"]["pid"])' <<<"$info"
}

# The windows of the X client a host process holds, as the server sees them:
# its client base from screenshot --list-clients (the X-Resource extension's
# view of each connection's peer pid), then every window in
# xwininfo -root -tree whose id X allocated from that base, each named one
# with its map state. A window found this way is that process's whatever its
# title says - and an xterm's shell retitles it (EL's /etc/bashrc). Returns 1
# when the process holds no X connection.
x_windows_of() { # <host pid>
    local clients base info mask tree line wid state
    clients=$(podman exec -u desktop -e DISPLAY=:0 desktop /usr/libexec/desktop-tools/screenshot --list-clients) || return 1
    base=$(awk -v want="pid=$1" '$2 == want && !f {sub(/^client-base=/, "", $1); print $1; f = 1}' <<<"$clients")
    [ -n "$base" ] || return 1
    info=$(podman exec -u desktop -e DISPLAY=:0 desktop xdpyinfo 2>/dev/null) || info=
    mask=$(awk '/resource-id-mask:/ && !f {print $2; f = 1}' <<<"$info")
    tree=$(podman exec -u desktop -e DISPLAY=:0 desktop xwininfo -root -tree) || return 1
    echo "X client: client-base=$base pid=$1 (resource-id-mask ${mask:-0x001fffff, assumed})"
    while read -r line; do
        wid=${line%% *}
        state=
        case "$line" in
            *'(has no name)'*) ;;
            *)
                info=$(podman exec -u desktop -e DISPLAY=:0 desktop xwininfo -id "$wid" 2>/dev/null) || info=
                state=$(awk '/Map State:/ {print $3}' <<<"$info")
                ;;
        esac
        echo "$line${state:+ map=$state}"
    done < <(python3 -c '
import re, sys
base, mask = int(sys.argv[1], 16), int(sys.argv[2], 16)
for line in sys.stdin:
    m = re.match(r"\s*(0x[0-9a-f]+) (.*\S)\s*$", line)
    if m and int(m.group(1), 16) & ~mask == base:
        print(m.group(1), m.group(2))
' "$base" "${mask:-0x001fffff}" <<<"$tree")
}

# The windows of a pod's main process (the xterm, in the client pods here).
pod_windows() { # <pod>
    local pid
    pid=$(pod_main_pid "$1") || { echo "pod $1: no main process found"; return 1; }
    echo "pod $1: main process, host pid $pid"
    x_windows_of "$pid"
}
# Whether a pod's main process has a window on the screen (IsViewable).
pod_window_up() { # <pod>
    local w
    w=$(pod_windows "$1") || return 1
    grep -q ' map=IsViewable$' <<<"$w"
}
# The first of a pod's windows on the screen, as "<id> <w> <h> <x> <y>"
# (absolute position), from a pod_windows listing on stdin.
viewable_rect() {
    sed -nE 's/^(0x[0-9a-f]+) .* ([0-9]+)x([0-9]+)\+-?[0-9]+\+-?[0-9]+ +\+(-?[0-9]+)\+(-?[0-9]+) map=IsViewable$/\1 \2 \3 \4 \5/p' | sed -n 1p
}

# F7.6's stream listing: pactl's short lists of the streams playing and
# recording now, then each playing stream's client, by pipewire-pulse's
# `pactl list clients`: its application name, executable and pid (in the
# client's own pid namespace). The client is where the executable is: a
# stream itself names it only for pulse clients, and then as the file it
# runs, so paplay's stream says pacat (paplay is a link to it), pw-play's
# client is pw-cat, and aplay's stream reaches PipeWire through
# pipewire-alsa as "PipeWire ALSA [aplay]".
stream_apps() {
    local short clients
    short=$(PULSE_SERVER=unix:/run/desktop-audio/pulse timeout 10 pactl list short sink-inputs 2>&1) \
        || { echo "(no answer: the export is down) $short"; return 0; }
    echo "== pactl list short sink-inputs (index, sink, client, driver, format)"
    echo "${short:-(no stream playing)}"
    echo "== pactl list short source-outputs"
    PULSE_SERVER=unix:/run/desktop-audio/pulse timeout 10 pactl list short source-outputs 2>&1 || true
    [ -n "$short" ] || return 0
    clients=$(PULSE_SERVER=unix:/run/desktop-audio/pulse timeout 10 pactl list clients 2>&1) || true
    echo "== each playing stream's client (pactl list clients): its application name, executable and pid"
    python3 -c '
import re, sys
info, cur = {}, None
for line in sys.argv[2].splitlines():
    m = re.match(r"Client #(\d+)", line)
    if m:
        cur = info.setdefault(m.group(1), {})
        continue
    m = re.match(r"\s+application\.(name|process\.binary|process\.id) = \"(.*)\"$", line)
    if m and cur is not None:
        cur[m.group(1)] = m.group(2)
for line in sys.argv[1].splitlines():
    f = line.split("\t")
    if len(f) >= 3:
        c = info.get(f[2], {})
        print("sink-input %s: client %s, application.name \"%s\", binary \"%s\", pid %s" % (
            f[0], f[2], c.get("name", "?"), c.get("process.binary", "?"), c.get("process.id", "?")))
' "$short" "$clients"
}
pod_logs() { k3s kubectl logs "$1" --tail="${2:-100}" 2>&1 || true; }

verify_concurrency() {
    # The display is shareable and CDI imposes no cap, so the property to
    # prove is that several independent clients hold LIVE connections to the
    # one display at the same time - not that a counter runs out.
    log vs "start from a clean slate"
    k3s kubectl delete pod cdi-verify x11-client-demo x11-testclient \
        --ignore-not-found --wait=true >/dev/null 2>&1 || true

    log vs "three clients open the shared display concurrently"
    ev_begin S7.3.5 "Concurrency" T3
    # Each pod's xterm - its main process, so a live X connection for as
    # long as the pod runs - gets its own place on the right of the screen,
    # clear of the session's xterm, so one screendump can show all three.
    local geom
    for n in a b c; do
        case $n in a) geom=50x6+720+60 ;; b) geom=50x6+720+240 ;; c) geom=50x6+720+420 ;; esac
        apply_client "x11-client-$n" "$geom"
    done
    for n in a b c; do
        wait_for 30 4 "client $n running" \
            sh -c "k3s kubectl get pod x11-client-$n -o jsonpath='{.status.phase}' | grep -q Running"
    done
    # S7.5.7's "before": the three pods as they started, ahead of the
    # concurrency checks; its "after" and its windows follow S7.3.5.
    ev_end
    ev_begin S7.5.7 "Many clients share one desktop" T3
    declare -A s757_b=() s757_bf=()
    for n in a b c; do
        s757_b[$n]=$(pod_state "x11-client-$n") || fail "could not read pod x11-client-$n's state"
        ev_text "pod-$n-before" "EV-PIDS: pod x11-client-$n's container (restartCount, id, start time) and its main process's host pid, before the shared-display checks" "${s757_b[$n]}"
        s757_bf[$n]=$EV_LAST
    done
    ev_end
    ev_begin S7.3.5 "Concurrency" T3
    for n in a b c; do
        timeout 20 k3s kubectl exec "x11-client-$n" -- sh -c 'xdpyinfo >/dev/null' \
            || fail "client $n could not open the shared display"
    done
    ev_pass "three pods requesting desktop.local/display each opened the display (xdpyinfo)"
    # ...and all three at once, not merely one after another: each holds an
    # X connection open while the next one connects.
    timeout 40 k3s kubectl exec x11-client-a -- \
        sh -c 'xterm -T hold-a -geometry 40x6+40+600 & sleep 25' >/dev/null 2>&1 &
    holder=$!
    sleep 5
    for n in b c; do
        timeout 20 k3s kubectl exec "x11-client-$n" -- sh -c 'xdpyinfo >/dev/null' \
            || { kill "$holder" 2>/dev/null; fail "client $n lost the display while a held it"; }
    done
    ev_pass "while pod a held a second connection, pods b and c opened the display again"

    # Who holds the display right now, from the server's side: each pod's
    # UID must be in the cgroup of one of the X clients the server lists.
    clients=$(ev_save list-clients "EV-STATE: screenshot --list-clients from inside the desktop container while the three pods hold the display: every X client and its host pid" \
        podman exec -u desktop -e DISPLAY=:0 desktop \
        /usr/libexec/desktop-tools/screenshot --list-clients) \
        || fail "screenshot --list-clients failed: $clients"
    local uid uidu match pid cg table=""
    for n in a b c; do
        uid=$(k3s kubectl get pod "x11-client-$n" -o jsonpath='{.metadata.uid}')
        [ -n "$uid" ] || fail "could not read pod x11-client-$n's UID"
        uidu=$(echo "$uid" | tr - _)
        match=""
        for pid in $(sed -n 's/.* pid=//p' <<<"$clients"); do
            cg=$(cat "/proc/$pid/cgroup" 2>/dev/null || true)
            case "$cg" in *"$uid"*|*"$uidu"*) match=$pid; break ;; esac
        done
        [ -n "$match" ] || fail "no X client listed belongs to pod x11-client-$n ($uid)"
        table+="x11-client-$n uid=$uid x-client-pid=$match cgroup=$(head -n1 "/proc/$match/cgroup" 2>/dev/null)"$'\n'
        ev_pass "pod x11-client-$n holds an X connection: listed client pid $match is in its cgroup"
    done
    ev_text pods-to-clients "EV-STATE: each pod's UID and the listed X client whose /proc/<pid>/cgroup carries it" "$table"
    kill "$holder" 2>/dev/null || true
    wait "$holder" 2>/dev/null || true
    ev_end

    # S7.5.7: the three windows, each its pod's main xterm - found by its X
    # client, not by its title - at its own place, none covering another,
    # while all three pods hold the display. The host shoots the screen next.
    ev_begin S7.5.7 "Many clients share one desktop" T3
    ev_text list-clients "EV-STATE: screenshot --list-clients from the desktop while the three pods hold the display (S7.3.5's listing): each X client's resource base and host pid" "$clients"
    local wins rect rects=""
    for n in a b c; do
        wait_for 20 1 "pod x11-client-$n's window on the screen" pod_window_up "x11-client-$n"
        wins=$(pod_windows "x11-client-$n") || fail "pod x11-client-$n's xterm holds no X connection"
        ev_text "windows-$n" "EV-STATE: pod x11-client-$n's main process, its X client and the windows X allocated to it in xwininfo -root -tree, each named one with its map state" "$wins"
        rect=$(viewable_rect <<<"$wins")
        [ -n "$rect" ] || fail "pod x11-client-$n's xterm has no window on the screen"
        rects+="$n ${rect#* }"$'\n'
        ev_pass "pod x11-client-$n's xterm is on the screen: window ${rect%% *}, $(awk '{print $2 "x" $3 " at +" $4 "+" $5}' <<<"$rect")"
    done
    ev_save tree "EV-STATE: xwininfo -root -tree with the three windows in it" win_tree >/dev/null || true
    overlap=$(python3 -c '
import sys
r = [l.split() for l in sys.stdin if l.strip()]
bad = []
for i, a in enumerate(r):
    for b in r[i + 1:]:
        aw, ah, ax, ay = map(int, a[1:5])
        bw, bh, bx, by = map(int, b[1:5])
        if ax < bx + bw and bx < ax + aw and ay < by + bh and by < ay + ah:
            bad.append(a[0] + "/" + b[0])
print(" ".join(bad))
' <<<"$rects")
    [ -z "$overlap" ] || fail "client windows overlap on the screen: $overlap"
    ev_pass "the three windows are at three places, none covering another"
    for n in a b c; do
        st=$(pod_state "x11-client-$n") || fail "could not read pod x11-client-$n's state"
        ev_text "pod-$n-after" "EV-PIDS: pod x11-client-$n after the shared-display checks" "$st"
        ev_diff "pod-$n" "EV-DIFF: pod x11-client-$n before and after (empty: the same container)" "${s757_bf[$n]}" "$EV_LAST"
        grep -q 'restartCount=0 ' <<<"$st" && [ "$st" = "${s757_b[$n]}" ] \
            || fail "pod x11-client-$n changed or restarted across the checks: '${s757_b[$n]}' -> '$st'"
    done
    ev_pass "the three pods are the same containers throughout, restartCount 0"
    ev_end
    log vs "three concurrent clients on one display, no cap in the way"
    log vs "verify-concurrency passed"
}

verify_teardown() {
    export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
    ev_begin S7.3.6 "Teardown seam" T3
    # A client already running when the plugins go: it holds its mounts, so
    # its window stays and it keeps the display.
    log td "a client pod is running when the plugin releases are uninstalled"
    apply_client x11-client-td 50x6+40+560
    wait_for 30 4 "x11-client-td running" \
        sh -c "k3s kubectl get pod x11-client-td -o jsonpath='{.status.phase}' | grep -q Running"
    wait_for 20 1 "x11-client-td's window on the screen" pod_window_up x11-client-td
    td_b=$(pod_state x11-client-td) || fail "could not read pod x11-client-td's state"
    ev_text pod-before "EV-PIDS: the running client pod x11-client-td before the uninstall" "$td_b"
    td_bf=$EV_LAST
    ev_save windows-before "EV-STATE: the client pod's main process, its X client and its windows before the uninstall" \
        pod_windows x11-client-td >/dev/null || true
    alloc_b=$(k3s kubectl get node -o jsonpath='{.items[0].status.allocatable}' | tr ',' '\n' | sort)
    ev_text allocatable-before "EV-STATE: the node's allocatable resources before the uninstall, one per line" "$alloc_b"
    alloc_bf=$EV_LAST
    cdi_b=$(ls -l --time-style=full-iso /etc/cdi)
    ev_text cdi-before "EV-STATE: ls -l --time-style=full-iso /etc/cdi before the uninstall" "$cdi_b"
    cdi_bf=$EV_LAST

    log td "helm uninstall one plugin release per capability"
    for r in display audio tools; do
        helm uninstall "$r" >/dev/null || fail "helm uninstall $r failed"
    done
    # Removing the plugin must make the node stop offering the resource.
    # kubelet drops the allocatable COUNT to 0 promptly but often keeps the
    # resource key in node status for a while, so assert the count is 0 (or
    # the key is gone), not that the key vanished.
    for cap in display audio tools; do
        wait_for 30 4 "desktop.local/$cap no longer allocatable" \
            sh -c "v=\$(k3s kubectl get node -o jsonpath='{.items[0].status.allocatable.desktop\.local/$cap}'); [ -z \"\$v\" ] || [ \"\$v\" = 0 ]"
    done
    # The chart-managed workloads must be gone (get returns non-zero once
    # the objects no longer exist).
    wait_for 20 3 "the three plugin daemonsets gone" \
        sh -c "! k3s kubectl get ds display-cdi-device-plugin >/dev/null 2>&1 && ! k3s kubectl get ds audio-cdi-device-plugin >/dev/null 2>&1 && ! k3s kubectl get ds tools-cdi-device-plugin >/dev/null 2>&1"
    alloc_a=$(k3s kubectl get node -o jsonpath='{.items[0].status.allocatable}' | tr ',' '\n' | sort)
    ev_text allocatable-after "EV-STATE: the node's allocatable resources after the uninstall" "$alloc_a"
    ev_diff allocatable "EV-DIFF: the node's allocatable resources before and after: the three desktop.local resources withdrawn (gone, or 0)" "$alloc_bf" "$EV_LAST"
    ev_pass "helm uninstall withdrew desktop.local/display, audio and tools: none is allocatable, and the three plugin daemonsets are gone"

    # The CDI spec is HOST state, not chart state: uninstalling must not
    # remove it (nothing in k8s owns it). This is the seam that makes one
    # spec definition serve podman and kubernetes alike.
    cdi_a=$(ls -l --time-style=full-iso /etc/cdi)
    ev_text cdi-after "EV-STATE: ls -l --time-style=full-iso /etc/cdi after the uninstall" "$cdi_a"
    ev_diff cdi "EV-DIFF: /etc/cdi before and after the uninstall (no differences: the host's specs untouched)" "$cdi_bf" "$EV_LAST"
    grep -q 'kind: desktop.local/display' /etc/cdi/desktop-display.yaml \
        || fail "helm uninstall removed the host display spec - it is host state"
    grep -q 'kind: desktop.local/audio' /etc/cdi/desktop-audio.yaml \
        || fail "helm uninstall removed the host audio spec - it is host state"
    [ "$cdi_a" = "$cdi_b" ] || fail "/etc/cdi changed with the uninstall (see the diff)"
    ev_pass "/etc/cdi is unchanged, every spec in it with the same size and time: the specs are the host's, not the charts'"

    # Same seam from the other side: the desktop is quadlet state, so nothing
    # helm does can touch it. Tearing kubernetes down leaves the display up.
    systemctl is-active --quiet desktop.service \
        || fail "the quadlet desktop went down with the helm releases - it is not kubernetes state"
    podman exec desktop test -S /tmp/.X11-unix/X0 \
        || fail "the desktop's X socket vanished on helm uninstall"
    ev_pass "the desktop survives: desktop.service active, its X socket there"

    # And the client that was running keeps working: the same container, its
    # window still on the screen, and the display opens from it anew.
    td_a=$(pod_state x11-client-td) || fail "could not read pod x11-client-td's state"
    ev_text pod-after "EV-PIDS: the client pod x11-client-td after the uninstall" "$td_a"
    ev_diff pod "EV-DIFF: the client pod before and after the uninstall (empty: the same container)" "$td_bf" "$EV_LAST"
    grep -q 'restartCount=0 ' <<<"$td_a" && [ "$td_a" = "$td_b" ] \
        || fail "the client pod changed across the uninstall: '$td_b' -> '$td_a'"
    wins=$(pod_windows x11-client-td) || fail "the client pod's xterm lost its X connection with the uninstall"
    ev_text windows-after "EV-STATE: the client pod's X client and its windows after the uninstall" "$wins"
    grep -q ' map=IsViewable$' <<<"$wins" || fail "the client pod's window left the screen with the uninstall"
    timeout 20 k3s kubectl exec x11-client-td -- sh -c 'xdpyinfo >/dev/null' \
        || fail "the running client pod can no longer open the display after the uninstall"
    ev_pass "the client pod that was running keeps working: the same container (restartCount 0), its window still on the screen, and xdpyinfo opens :0 from it after the uninstall"
    ev_end
    log td "charts uninstalled; resources withdrawn; host CDI specs, the desktop and a running client untouched"
    log td "verify-teardown passed"
}

verify_record() {
    # Capture direction: a client RECORDS from the desktop's audio, not just
    # plays. Loopback via the sink's monitor source - record it while playing a
    # known tone into the same sink, then confirm the recording carries that
    # tone. Runs in cdi-verify (a client pod) over the injected PULSE_SERVER.
    local pod=${1:-cdi-verify} freq=${2:-660}
    gen_tone "$freq" /tmp/rectone.wav
    timeout 20 k3s kubectl exec -i "$pod" -- sh -c 'cat > /tmp/rt.wav' \
        < /tmp/rectone.wav || fail "could not copy record tone into $pod"

    log rec "record the sink monitor while playing a ${freq}Hz tone"
    # --latency-msec=50: unless asked for less, pipewire-pulse hands a
    # recorder its audio in 64 KiB fragments (0.37 s at 44.1 kHz stereo), and
    # the SIGINT that ends parec drops whatever has not arrived. This
    # recording held two fragments, 0.74 s of its 2.5 s, in every run until
    # run 37345104044's held one, 0.37 s, and failed. With 50 ms fragments it
    # holds the whole window (2.6 s, measured in the desktop image).
    timeout 30 k3s kubectl exec "$pod" -- sh -c '
        sink=$(pactl get-default-sink) || exit 3
        parec --latency-msec=50 -d "${sink}.monitor" --file-format=wav \
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

# --- batch 8: a soundless host, then a card (S2.4.6, S4.7.10, S7.7.9) -----------
# The soundless shard's VM boots without intel-hda: no sound card at all, so
# the audio stack's first start has nothing to align its group to. The host
# side renumbered the host's audio group to SL_GID before the tree was
# applied: on a stock VM the host and the image agree on 63, and a check of
# the alignment could not fail. A usb-audio card plugged in later gets nodes
# on SL_GID, and the container's audio group keeps the image's gid until the
# stack starts again, when desktop-init's audio supervisor re-aligns it.
#
# A client started before any card exists (S7.7.9) is a podman client of
# the test image, given desktop.local/audio=all: it tries once a second
# until the default sink is a card's and paplay plays its tone, then holds.
# pipewire-pulse keeps a "Dummy Output" (auto_null) while there is no other
# sink, and paplay into that succeeds without a sound, so a try needs a sink
# that is not auto_null first.
SL_GID=1063
SL_CLIENT="ev-soundless-player"
SL_HZ=550
SL_IMAGE=localhost/desktop-testclient:latest
SL_LOOP='n=0
while :; do
    if pactl list short sinks 2>/dev/null | grep -v auto_null | grep -q . && paplay /tmp/tone.wav; then
        echo "played at $(date -u +%T) after $n failed tries"
        break
    fi
    n=$((n + 1))
    echo "try $n at $(date -u +%T): sinks: $(pactl list short sinks 2>&1 | cut -f2 | tr "\n" " ")"
    sleep 1
done
exec sleep infinity'
sl_node() { ls /dev/snd/controlC* 2>/dev/null | sed -n 1p; }
sl_node_up() { [ -n "$(sl_node)" ]; }
sl_ctr_gid() { podman exec desktop getent group audio | cut -d: -f3; }
sl_cards() { # alsa_card Devices in PipeWire, as snd_probe counts them
    local n
    n=$(podman exec -u desktop -e XDG_RUNTIME_DIR=/run/user/61000 -e HOME=/home/desktop desktop \
        sh -c 'pw-cli ls Device 2>/dev/null | grep -c "device.name = \"alsa_card"' 2>/dev/null || true)
    echo "${n:-0}"
}
sl_card_up() { [ "$(sl_cards)" -ge 1 ]; }
sl_played() { podman logs "$SL_CLIENT" 2>&1 | grep -q '^played at '; }
sl_inspect() { podman inspect "$SL_CLIENT" --format '{{.Id}} pid={{.State.Pid}} started={{.State.StartedAt}} restarts={{.RestartCount}} status={{.State.Status}}'; }
sl_wpctl() { podman exec -u desktop -e XDG_RUNTIME_DIR=/run/user/61000 -e HOME=/home/desktop desktop wpctl status; }
# The align-device-groups rows of every narrow (audio-only) pass in the log:
# a final-state table with the audio row alone, then id desktop.
sl_narrow_rows() {
    awk '/^align-device-groups: final state:$/ {
             if ((getline a) > 0 && (getline b) > 0 && a ~ /^align-device-groups:   audio: / && b ~ /^align-device-groups: desktop user:/) print a
         }' <<<"$1"
}

soundless() { # before|plugged|realign|played|after
    [ "${EV_PROFILE:-}" = soundless ] || fail "the soundless steps need the VM booted without a sound card (EV_PROFILE=soundless)"
    local log since rows node ngid cgid c0 c1 n_lines old
    case "${1:-}" in
        before)
            log sl "a soundless host: no card, the host's audio group on $SL_GID, the image's in the container"
            ev_begin S2.4.6 "Audio gid is re-aligned before every audio start" T3
            ev_save snd-host "EV-STATE: ls -ln /dev/snd on the host: no card's nodes" sh -c 'ls -ln /dev/snd 2>&1 || true' >/dev/null || true
            sl_node_up && fail "the host has a sound card ($(sl_node)): the VM was to boot without one"
            ev_pass "the host has no sound card: no /dev/snd/controlC*"
            ev_save group-host "EV-STATE: getent group audio on the host (renumbered to $SL_GID before the tree was applied)" getent group audio >/dev/null || true
            [ "$(getent group audio | cut -d: -f3)" = "$SL_GID" ] || fail "the host's audio group is not gid $SL_GID: $(getent group audio)"
            ev_pass "the host's audio group is gid $SL_GID"
            cgid=$(sl_ctr_gid)
            ev_save group-container "EV-STATE: getent group audio in the container: the image's gid, nothing having aligned it" podman exec desktop getent group audio >/dev/null || true
            [ -n "$cgid" ] && [ "$cgid" != "$SL_GID" ] || fail "the container's audio group is '${cgid:-absent}', not the image's own gid"
            ev_pass "the container's audio group is gid $cgid, the image's: it differs from the host's $SL_GID"
            log=$(podman logs desktop 2>&1 | tr -d '\r')
            ev_text align-boot "EV-LOG-DESKTOP: every align-device-groups line since the container started: the boot pass, then the audio supervisor's pass before the first audio start" \
                "$(grep '^align-device-groups:' <<<"$log" || echo '(none)')"
            rows=$(sl_narrow_rows "$log")
            grep -q "^align-device-groups:   audio: container gid $cgid, no device nodes$" <<<"$rows" \
                || fail "no audio-only alignment pass found no nodes before the first audio start: ${rows:-none}"
            grep -q '^align-device-groups: audio: no device nodes present, skipping$' <<<"$log" \
                || fail "align-device-groups did not log 'audio: no device nodes present, skipping'"
            ev_pass "the audio supervisor's pass before the first audio start found nothing to align: 'audio: no device nodes present, skipping', its table '$(sed -n 1p <<<"$rows" | sed 's/^align-device-groups: *//')'"
            ev_save wpctl-before "EV-STATE: wpctl status with no card" sl_wpctl >/dev/null || true
            [ "$(sl_cards)" = 0 ] || fail "PipeWire lists a card on a soundless host"
            ev_pass "PipeWire lists no card"
            ev_end
            log sl "a client started before any card exists: it tries until a card's sink is the default"
            ev_begin S7.7.9 "A client that started on a soundless host plays once a card arrives, without restarting" T3
            gen_tone "$SL_HZ" /tmp/sl-tone.wav 6
            podman image exists "$SL_IMAGE" || podman load -q -i /tmp/images-testclient.tar >/dev/null || fail "could not load $SL_IMAGE"
            podman rm -f "$SL_CLIENT" >/dev/null 2>&1 || true
            podman create --name "$SL_CLIENT" --device desktop.local/audio=all "$SL_IMAGE" sh -c "$SL_LOOP" >/dev/null \
                || fail "could not create the client"
            podman cp /tmp/sl-tone.wav "$SL_CLIENT:/tmp/tone.wav" || fail "could not copy the tone into the client"
            podman start "$SL_CLIENT" >/dev/null || fail "the client did not start"
            ev_text client-command "EV-STATE: the client: podman create --name $SL_CLIENT --device desktop.local/audio=all $SL_IMAGE sh -c <the loop below>, a ${SL_HZ} Hz tone copied in" "$SL_LOOP"
            sleep 4
            ev_save client-before "EV-PIDS: the client as it started: id, pid, start, restarts, status" sl_inspect >/dev/null || fail "no client to inspect"
            sl_inspect > /run/ev-sl-client
            ev_save client-log-early "EV-LOG-CLIENT: the client's first tries, with no card's sink to play to" podman logs "$SL_CLIENT" >/dev/null || true
            podman logs "$SL_CLIENT" 2>&1 | grep -q '^try 1 at ' || fail "the client logged no failed try with no card"
            ! sl_played || fail "the client played with no card"
            ev_pass "the client runs and keeps trying: no card's sink yet"
            ev_end
            ;;
        plugged)
            log sl "the card plugged in: nodes on the host's gid, the container's group not yet aligned"
            ev_begin S2.4.6 "Audio gid is re-aligned before every audio start" T3
            wait_for 30 1 "the card's nodes on the host" sl_node_up
            node=$(sl_node)
            ev_save snd-host-plugged "EV-STATE: ls -ln /dev/snd on the host with the card plugged in" ls -ln /dev/snd >/dev/null || true
            ev_save acl "EV-STATE: getfacl of $node on the host: any ACL logind's uaccess gave the active session's user" \
                sh -c "getfacl -p $node 2>&1 || true" >/dev/null || true
            ngid=$(stat -c %g "$node")
            [ "$ngid" = "$SL_GID" ] || fail "$node is on gid $ngid, not the host's audio group $SL_GID"
            ev_pass "the card's control node $node is on gid $ngid, the host's audio group"
            ev_save snd-container-plugged "EV-STATE: ls -ln /dev/snd in the container: the same nodes, through the live bind mount" \
                podman exec desktop ls -ln /dev/snd >/dev/null || true
            podman exec desktop test -e "$node" || fail "the container does not see $node"
            cgid=$(sl_ctr_gid)
            [ "$cgid" != "$SL_GID" ] || fail "the container's audio group is already $SL_GID before any restart"
            ev_pass "the container sees $node; its audio group is still gid $cgid until the stack starts again"
            ev_note "PipeWire Devices named alsa_card with the card plugged in and the stack not restarted: $(sl_cards)"
            ev_end
            ;;
        realign)
            log sl "the stack restarted: the supervisor aligns the audio group before the start"
            ev_begin S2.4.6 "Audio gid is re-aligned before every audio start" T3
            node=$(sl_node)
            old=$(sl_ctr_gid)
            n_lines=$(podman logs desktop 2>&1 | wc -l)
            podman exec -u desktop desktop pkill -u desktop -x pipewire || true
            ev_note "pipewire killed at $(date -u +%Y-%m-%dT%H:%M:%S.%3NZ), the audio group then gid $old"
            wait_for 45 1 "the container's audio group on gid $SL_GID" sh -c "[ \"\$(podman exec desktop getent group audio | cut -d: -f3)\" = $SL_GID ]"
            wait_for 45 1 "the export answering again" audio_reachable
            since=$(podman logs desktop 2>&1 | tail -n +$((n_lines + 1)) | tr -d '\r')
            ev_text log-realign "EV-LOG-DESKTOP: podman logs desktop from pipewire's kill on: the stack's exit, the alignment, the new start" "$since"
            grep -qE "^align-device-groups: audio: gid $old -> $SL_GID \\(from /dev/snd/controlC[0-9]+\\)$" <<<"$since" \
                || fail "no 'audio: gid $old -> $SL_GID' line from the alignment before the new start"
            ev_pass "before the new start the supervisor's pass logged '$(grep -m1 '^align-device-groups: audio: gid ' <<<"$since" | sed 's/^align-device-groups: //')'"
            grep -q 'desktop-init: audio stack exited (rc=[0-9]*); restarting in 3s' <<<"$since" \
                || fail "desktop-init did not log the audio stack's restart"
            cgid=$(sl_ctr_gid)
            ngid=$(stat -c %g "$node")
            ev_text gids-after "EV-STATE: the container's audio group and the host node's gid after the restart" \
                "container: $(podman exec desktop getent group audio)"$'\n'"host: $(stat -c '%g %A %n' "$node")"
            [ "$cgid" = "$ngid" ] || fail "the container's audio group is gid $cgid, the host's node $ngid"
            ev_pass "the container's audio group now equals the host node's gid: $cgid"
            wait_for 45 1 "PipeWire to list the card" sl_card_up
            ev_save wpctl-after "EV-STATE: wpctl status after the restart: the card" sl_wpctl >/dev/null || true
            ev_pass "PipeWire lists the card after the restart ($(sl_cards) alsa_card Device)"
            ev_end
            ev_begin S4.7.10 "A card that arrives after a soundless boot is openable" T3
            ev_save wpctl "EV-STATE: wpctl status after the stack's next start: the card and its sink" sl_wpctl >/dev/null || true
            ev_save sinks "EV-STATE: pactl list short sinks as the session user: the card's sink, no auto_null" \
                podman exec -u desktop -e XDG_RUNTIME_DIR=/run/user/61000 -e HOME=/home/desktop desktop pactl list short sinks >/dev/null || true
            sl_card_up || fail "PipeWire does not list the card"
            ev_pass "after the stack's next start PipeWire lists the card that arrived after the soundless boot"
            ev_end
            ;;
        played)
            log sl "the client, never restarted, plays once the card's sink is the default"
            ev_begin S7.7.9 "A client that started on a soundless host plays once a card arrives, without restarting" T3
            wait_for 60 1 "the client's tone to have played" sl_played
            ev_save client-log "EV-LOG-CLIENT: the client's whole log: its failed tries, then the play" podman logs "$SL_CLIENT" >/dev/null || true
            c0=$(podman logs "$SL_CLIENT" 2>&1 | grep -c '^try ' || true)
            ev_pass "the client played its tone after $c0 failed tries: $(podman logs "$SL_CLIENT" 2>&1 | grep '^played at ')"
            ev_end
            ;;
        after)
            ev_begin S7.7.9 "A client that started on a soundless host plays once a card arrives, without restarting" T3
            ev_save client-after "EV-PIDS: the client after it played: id, pid, start, restarts, status" sl_inspect >/dev/null || true
            c0=$(cat /run/ev-sl-client 2>/dev/null || true)
            c1=$(sl_inspect)
            [ -n "$c0" ] && [ "$c1" = "$c0" ] || fail "the client is not the same container and process: $c0 -> $c1"
            grep -q ' restarts=0 status=running$' <<<"$c1" || fail "the client restarted or stopped: $c1"
            ev_pass "the same container and process throughout, never restarted, still running: $c1"
            podman rm -f -t 2 "$SL_CLIENT" >/dev/null 2>&1 || true
            rm -f /run/ev-sl-client
            ev_end
            ;;
        *) fail "soundless: before, plugged, realign, played or after" ;;
    esac
}

# The maintainer's journeys (Requirements.md E10), one step per call:
# `maint <step>`, from ci/vm/maint-e2e.sh.
# shellcheck source=ci/vm/maint-guest.sh
. ci/vm/maint-guest.sh

case "${1:?phase-deploy|phase2|verify-privileges|verify-pod-identity|verify-audio-lifecycle|hotplug-probe|snd-probe|play-audio|play-audio-pod|verify-cdi|verify-split|verify-testclient|verify-record|verify-concurrency|verify-teardown|input-sink-start|input-sink-check|operator-setup|operator-teardown|pod-state|desk|xorg-log-lines|xorg-log-since|ctr-pids|xi-id|xi-test-start|xi-test-read|xi-test-stop|tone-start|tone-status|journey-start|jx|jx-in|journey-xterm|journey-apps|win-up|win-wait|win-tree|client-shot|journey-put|journey-tone|journey-tone-status|rec-source|journey-rec|journey-file|streams|journey-stat|journey-tools-ls|journey-noise|journey-shot-size|journey-held-start|journey-held-state|journey-held-release|journey-loop-start|journey-loop-stop|journey-loop-log|desktop-publish-log|audio-sched|desktop-log-since|x-up|journey-cleanup|verify-postmortem|verify-audio-x|verify-runtime|verify-session-restart|verify-audio-restarts|play-as-rocky|split-cleanup|pod-windows|stream-apps|pod-logs|layout-declare|layout-roundtrip|layout-unplug|layout-restore|autodetect|monitors-set|deploy-checks|deploy-tail|deploy-reboot|deploy-proof|session-groups|mwm-exit|standalone|seat-tags|host-audio|soundless|maint}" in
    phase-deploy) phase_deploy ;;
    phase2) phase2 ;;
    play-audio) play_audio "${2:-}" ;;
    play-audio-pod) play_audio_pod "${2:-}" "${3:-}" "${4:-}" ;;
    verify-cdi) verify_cdi ;;
    verify-split) verify_split ;;
    verify-testclient) verify_testclient ;;
    verify-screenshot) verify_screenshot ;;
    screenshot-pattern-start) screenshot_pattern_start ;;
    screenshot-pattern-stop) screenshot_pattern_stop ;;
    verify-record) verify_record "${2:-}" "${3:-}" ;;
    split-cleanup) split_cleanup ;;
    pod-windows) pod_windows "${2:?pod}" ;;
    stream-apps) stream_apps ;;
    pod-logs) pod_logs "${2:?pod}" ;;
    verify-concurrency) verify_concurrency ;;
    verify-teardown) verify_teardown ;;
    verify-privileges) verify_privileges ;;
    verify-pod-identity) verify_pod_identity ;;
    verify-log-bounds) verify_log_bounds ;;
    verify-audio-lifecycle) verify_audio_lifecycle ;;
    verify-postmortem) verify_postmortem ;;
    verify-audio-x) verify_audio_x_restart ;;
    verify-runtime) verify_runtime ;;
    verify-session-restart) verify_session_restart ;;
    verify-audio-restarts) verify_audio_restarts ;;
    play-as-rocky) play_as_rocky "${2:-}" "${3:-}" ;;
    layout-declare) layout_declare ;;
    layout-roundtrip) layout_roundtrip ;;
    layout-unplug) layout_unplug ;;
    layout-restore) layout_restore ;;
    autodetect) autodetect "${2:-}" "${3:-}" ;;
    monitors-set) monitors_set "${2:-}" ;;
    deploy-checks) deploy_checks ;;
    deploy-tail) deploy_tail ;;
    deploy-reboot) deploy_reboot ;;
    session-groups) session_groups ;;
    mwm-exit) verify_mwm_exit ;;
    standalone) standalone_desktop "${2:-}" ;;
    seat-tags) seat_tags "${2:-}" ;;
    soundless) soundless "${2:-}" ;;
    maint) shift; maint "$@" ;;
    host-audio) host_audio "${2:-}" ;;
    deploy-proof) deploy_proof ;;
    hotplug-probe) hotplug_probe ;;
    snd-probe) snd_probe ;;
    input-sink-start) input_sink_start ;;
    input-sink-check) input_sink_check "${2:-}" ;;
    operator-setup) operator_setup ;;
    pod-state) pod_state "${2:?pod}" ;;
    desk) shift; desk "$@" ;;
    xorg-log-lines) xorg_log_lines ;;
    xorg-log-since) xorg_log_since "${2:-}" ;;
    ctr-pids) ctr_pids "${2:-}" ;;
    xi-id) shift; xi_id "$*" ;;
    xi-test-start) xi_test_start "${2:-}" ;;
    xi-test-read) xi_test_read ;;
    xi-test-stop) xi_test_stop ;;
    tone-start) tone_start "${2:-}" "${3:-}" "${4:-}" "${5:-}" ;;
    journey-start) journey_start "${2:-}" "${3:-}" ;;
    jx) shift; jx_in "$JPOD" "$@" ;;
    jx-in) shift; jx_in "$@" ;;
    journey-xterm) journey_xterm "${2:-}" ;;
    journey-apps) journey_apps "${2:-}" ;;
    win-up) win_up "${2:-}" ;;
    win-wait) win_wait "${2:-}" "${3:-}" ;;
    win-tree) win_tree ;;
    client-shot) client_shot "${2:-}" ;;
    journey-put) journey_put "${2:-}" "${3:-}" "${4:-}" "${5:-}" ;;
    journey-tone) journey_tone "${2:-}" "${3:-}" "${4:-}" "${5:-}" ;;
    rec-source) rec_source "${2:-}" "${3:-}" "${4:-}" ;;
    journey-rec) journey_rec "${2:-}" "${3:-}" "${4:-}" ;;
    journey-file) journey_file "${2:-}" ;;
    journey-tone-status) journey_tone_status "${2:-}" "${3:-}" ;;
    streams) streams ;;
    journey-stat) journey_stat "${2:-}" "${3:-}" ;;
    journey-tools-ls) journey_tools_ls "${2:-}" ;;
    journey-noise) journey_noise ;;
    journey-shot-size) journey_shot_size ;;
    journey-held-start) journey_held_start ;;
    journey-held-state) journey_held_state ;;
    journey-held-release) journey_held_release ;;
    journey-loop-start) journey_loop_start ;;
    journey-loop-stop) journey_loop_stop ;;
    journey-loop-log) journey_loop_log ;;
    desktop-publish-log) desktop_publish_log ;;
    audio-sched) audio_sched ;;
    desktop-log-since) desktop_log_since "${2:-}" ;;
    x-up) x_up ;;
    journey-cleanup) journey_cleanup ;;
    tone-status) tone_status "${2:-}" ;;
    operator-teardown) operator_teardown ;;
    *) fail "unknown phase $1" ;;
esac
