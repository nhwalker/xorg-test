#!/bin/bash
# Deploy-tree boot smoke for CI (run as root on an EPHEMERAL runner): proves
# the declarative deploy/ tree brings up a stock host from scratch - apply,
# converge, boot, verify - with no install script anywhere in the flow.
# Assumes localhost/desktop-container:latest already built.
#
# Also carries the script-level branch tests that need root and a live
# systemd (CDI converger no-downgrade rules, client-CDI split/overrides
# and atomic write, seat-prep on a deliberately dirty seat) - the quadlet
# dry-run step earlier in the job covers only the happy paths.
set -euo pipefail
cd "$(dirname "$0")/.."

CDI=deploy/host/usr/local/libexec/desktop-cdi-refresh
CLIENT_CDI=deploy/host/usr/local/libexec/desktop-client-cdi
SELINUX_LABEL=deploy/host/usr/local/libexec/desktop-selinux
SEATPREP=deploy/host/usr/local/libexec/seat-prep.sh
SPEC=/etc/cdi/nvidia.yaml
DISPLAY_SPEC=/etc/cdi/desktop-display.yaml
AUDIO_SPEC=/etc/cdi/desktop-audio.yaml
TOOLS_SPEC=/etc/cdi/desktop-tools.yaml
TOOLS_BIN=/var/lib/desktop-container/bin
log()  { echo "== $*"; }
fail() { echo "FAIL: $*" >&2; exit 1; }
# The toolkit chain has three places to die (watcher never started, watcher
# started but never triggered, generator ran and declined) and they look
# identical from the outside: a published binary and no spec. Print enough to
# tell them apart, so a red run does not cost a whole cycle just to diagnose.
tools_diag() {
    echo "--- desktop-tools-cdi.path" >&2
    systemctl status desktop-tools-cdi.path --no-pager -l 2>&1 | head -20 >&2 || true
    echo "--- desktop-tools-cdi.service" >&2
    systemctl status desktop-tools-cdi.service --no-pager -l 2>&1 | head -20 >&2 || true
    journalctl -u desktop-tools-cdi.service --no-pager -o cat 2>&1 | tail -20 >&2 || true
    echo "--- $TOOLS_BIN" >&2
    ls -la "$TOOLS_BIN" >&2 || true
}

[ "$(id -u)" = 0 ] || fail "must run as root (sudo)"

# --- CDI converger branch tests ----------------------------------------------
FAKEBIN=$(mktemp -d)

log "cdi converger: stub on a GPU-less host"
rm -f "$SPEC"
"$CDI" >/dev/null
grep -q NVIDIA_CDI_STUB "$SPEC" || fail "stub spec not written"

log "cdi converger: real generation with (fake) toolkit + hardware"
cat > "$FAKEBIN/nvidia-ctk" <<'EOF'
#!/bin/sh
# fake nvidia-ctk: expects "cdi generate --output=PATH"
out="${3#--output=}"
printf 'cdiVersion: 0.5.0\nkind: nvidia.com/gpu\ndevices:\n  - name: all\n    containerEdits:\n      env:\n        - GENERATED=1\n' > "$out"
EOF
chmod +x "$FAKEBIN/nvidia-ctk"
touch /dev/nvidiactl
PATH="$FAKEBIN:$PATH" "$CDI" >/dev/null
grep -q GENERATED "$SPEC" || fail "generation path did not write the real spec"

log "cdi converger: transient toolkit failure keeps the real spec"
printf '#!/bin/sh\nexit 1\n' > "$FAKEBIN/nvidia-ctk"
PATH="$FAKEBIN:$PATH" "$CDI" 2>&1 | grep -q keeping || fail "no keep on transient failure"
grep -q GENERATED "$SPEC" || fail "real spec lost on transient failure"

log "cdi converger: no downgrade while hardware visible; stub after removal"
rm -f "$FAKEBIN/nvidia-ctk"
"$CDI" 2>&1 | grep -q keeping || fail "downgraded to stub despite visible hardware"
grep -q GENERATED "$SPEC" || fail "real spec lost while hardware visible"
rm -f /dev/nvidiactl
"$CDI" >/dev/null
grep -q NVIDIA_CDI_STUB "$SPEC" || fail "stub not restored after hardware removal"

# --- client CDI generator branch tests ---------------------------------------
log "client cdi: defaults write two disjoint specs"
rm -f "$DISPLAY_SPEC" "$AUDIO_SPEC"
"$CLIENT_CDI" >/dev/null
grep -q 'kind: desktop.local/display' "$DISPLAY_SPEC" || fail "display spec kind wrong"
grep -q 'kind: desktop.local/audio'   "$AUDIO_SPEC"   || fail "audio spec kind wrong"
grep -q 'DISPLAY=:0' "$DISPLAY_SPEC" || fail "display spec missing default DISPLAY"
grep -q 'hostPath: /tmp/.X11-unix' "$DISPLAY_SPEC" || fail "display spec missing X11 mount"
grep -q 'hostPath: /run/desktop-audio' "$AUDIO_SPEC" || fail "audio spec missing audio mount"
# The whole point of the split: neither device carries the other's edits.
if grep -qE 'PULSE_SERVER|PIPEWIRE_REMOTE|desktop-audio' "$DISPLAY_SPEC"; then
    fail "display spec leaks audio edits"
fi
if grep -qE 'DISPLAY=|X11-unix' "$AUDIO_SPEC"; then
    fail "audio spec leaks display edits"
fi
# rw, not ro: a read-only bind would let a client see the socket and then
# fail connect(2) on it - the single most likely silent regression here.
grep -q '"rbind", "rw"' "$DISPLAY_SPEC" || fail "display spec mounts are not rw"
grep -q '"rbind", "rw"' "$AUDIO_SPEC"   || fail "audio spec mounts are not rw"

log "client cdi: the superseded combined spec is removed"
printf 'cdiVersion: 0.5.0\nkind: desktop.local/display\ndevices: []\n' > /etc/cdi/desktop.yaml
"$CLIENT_CDI" >/dev/null
if [ -e /etc/cdi/desktop.yaml ]; then
    fail "legacy combined spec survived: it would still grant audio to display clients"
fi

log "client cdi: the override file is honored by both specs"
mkdir -p /etc/desktop-container
cat > /etc/desktop-container/client-cdi.conf <<'EOF'
DISPLAY_VALUE=:3
AUDIO_DIR=/run/other-audio
EOF
"$CLIENT_CDI" >/dev/null
grep -q 'DISPLAY=:3' "$DISPLAY_SPEC" || fail "override DISPLAY not applied"
grep -q 'PULSE_SERVER=unix:/run/other-audio/pulse' "$AUDIO_SPEC" \
    || fail "override AUDIO_DIR not applied to PULSE_SERVER"

log "client cdi: a bad DISPLAY value is rejected, leaving both specs intact"
echo 'DISPLAY_VALUE=nonsense' > /etc/desktop-container/client-cdi.conf
if "$CLIENT_CDI" >/dev/null 2>&1; then
    fail "generator accepted a malformed DISPLAY_VALUE"
fi
grep -q 'DISPLAY=:3' "$DISPLAY_SPEC" \
    || fail "failed run clobbered the display spec (validation must precede any write)"
grep -q '/run/other-audio' "$AUDIO_SPEC" \
    || fail "failed run clobbered the audio spec (validation must precede any write)"
# No temp files left behind by the rejected run.
leftovers=$(find /etc/cdi -name 'desktop-*.yaml.*' | wc -l)
[ "$leftovers" = 0 ] || fail "generator left $leftovers temp file(s) in /etc/cdi"
rm -f /etc/desktop-container/client-cdi.conf
"$CLIENT_CDI" >/dev/null
grep -q 'DISPLAY=:0' "$DISPLAY_SPEC" || fail "defaults not restored after removing the override"

# --- SELinux labeling: the no-SELinux path -----------------------------------
# GitHub's runners are Ubuntu with AppArmor and no SELinux, so this asserts the
# branch that matters here: the labeler must no-op CLEANLY, never fail a boot on
# a host that has no SELinux at all. The enforcing path is the VM e2e's job
# (phase-deploy asserts the resulting labels; phase2 runs confined pods against
# them), because it needs a real policy to be meaningful.
log "selinux labeler: clean no-op where SELinux is absent"
# /sys/fs/selinux/enforce, not the DIRECTORY: the selinuxfs mount point exists
# empty on plenty of kernels with SELinux inactive, so guarding on the
# directory would skip this test on exactly the hosts it is meant to cover.
# Same trap the labeler itself had - see deploy/README.md "SELinux".
if [ -e /sys/fs/selinux/enforce ]; then
    log "  (skipped: this runner HAS SELinux, so the no-op branch is untestable here)"
else
    out=$("$SELINUX_LABEL" 2>&1)         || fail "labeler exited non-zero on a host without SELinux: $out"
    echo "$out" | grep -qi 'no selinux\|selinux disabled'         || fail "labeler did not report the no-op it took (got: $out)"
    # The no-op must be reached before anything touches the filesystem: the
    # directories do not exist yet on this runner at this point in the script.
    log "  $out"
fi

# --- seat-prep on a deliberately dirty seat ----------------------------------
log "seat-prep: converges seat rules + a running display manager"
touch /etc/udev/rules.d/72-seat-ci-test.rules
cat > /etc/systemd/system/ci-fake-dm.service <<'EOF'
[Unit]
Description=fake display manager (CI)
[Service]
ExecStart=/bin/sleep infinity
EOF
ln -sf /etc/systemd/system/ci-fake-dm.service /etc/systemd/system/display-manager.service
systemctl daemon-reload
systemctl start display-manager.service
out=$("$SEATPREP")
echo "$out" | grep -q 'removing custom seat attachment rule' || fail "seat rule not handled"
echo "$out" | grep -q 'disabling display manager' || fail "display manager not handled"
[ ! -e /etc/udev/rules.d/72-seat-ci-test.rules ] || fail "seat rule file survived"
if systemctl is-active --quiet ci-fake-dm.service; then
    fail "fake display manager still running after seat-prep"
fi
rm -f /etc/systemd/system/display-manager.service /etc/systemd/system/ci-fake-dm.service
systemctl daemon-reload
out2=$("$SEATPREP" | grep -v 'fuser not available' || true)
[ -z "$out2" ] || fail "seat-prep second run not silent: $out2"

# --- apply the tree and boot the desktop -------------------------------------
log "ensure sshd exists for the host-terminal path"
if ! systemctl is-active --quiet ssh && ! systemctl is-active --quiet sshd; then
    apt-get update -q && apt-get install -y -q openssh-server
    systemctl enable --now ssh
fi

log "apply the deploy tree (verbatim README command)"
rsync -a --chown=root:root deploy/host/ /
[ -L /etc/systemd/system/getty@tty1.service ] || fail "getty mask did not survive as a symlink"
[ "$(readlink /etc/systemd/system/default.target)" = /usr/lib/systemd/system/multi-user.target ] \
    || fail "default.target symlink wrong"
systemctl daemon-reload
systemd-sysusers
systemd-tmpfiles --create || true   # unrelated runner entries may fail; ours asserted below
[ -d /run/desktop-audio ] && [ -d /tmp/.X11-unix ] || fail "tmpfiles dirs missing"
[ -d "$TOOLS_BIN" ] || fail "toolkit dir $TOOLS_BIN not created by tmpfiles"
# 0755, not the 1777 the two socket dirs use. This directory holds executables
# that get mounted into every client, so world-writable would let anything on
# the host control code running in all of them.
mode=$(stat -c %a "$TOOLS_BIN")
[ "$mode" = 755 ] || fail "toolkit dir is mode $mode, want 755 (never 1777 - it holds executables)"
# It must be EMPTY before the desktop runs, and therefore not yet advertised.
if [ -e "$TOOLS_SPEC" ]; then
    fail "$TOOLS_SPEC exists before the desktop ever published a toolkit"
fi
# the sshd_config.d drop-in is read at sshd start; this runner's sshd predates it
systemctl reload ssh 2>/dev/null || systemctl reload sshd 2>/dev/null || true

log "start desktop.service (generated from the tree's quadlet)"
systemctl start desktop.service

log "converger oneshots all pulled in and succeeded"
for u in desktop-seat-prep desktop-cdi-refresh desktop-client-cdi desktop-host-shell desktop-selinux; do
    systemctl is-active --quiet "$u.service" \
        || { systemctl status "$u.service" --no-pager || true; fail "$u.service not active"; }
done
# Two oneshots must ALSO run before a client starts on a boot where
# desktop.service has not: the CDI specs and the labels those specs' mounts
# depend on. The tree ships both pre-enabled, which only holds if the rsync
# preserved their .wants symlinks.
for u in desktop-client-cdi desktop-selinux; do
    [ "$(systemctl is-enabled "$u.service")" = enabled ] \
        || fail "$u.service not enabled for multi-user.target after rsync"
done
grep -q 'kind: desktop.local/display' "$DISPLAY_SPEC" \
    || fail "display CDI spec missing after the tree boot"
grep -q 'kind: desktop.local/audio' "$AUDIO_SPEC" \
    || fail "audio CDI spec missing after the tree boot"

# The toolkit delivery chain, end to end on this runner: the desktop container
# published its tools into the host directory, and desktop-tools-cdi.path
# noticed and advertised the device. Unlike the two specs above this one did
# NOT exist a moment ago - it appears only because the desktop ran.
[ "$(systemctl is-enabled desktop-tools-cdi.path)" = enabled ] \
    || fail "desktop-tools-cdi.path not enabled for multi-user.target after rsync"
for _ in $(seq 30); do
    [ -e "$TOOLS_SPEC" ] && break
    sleep 1
done
[ -s "$TOOLS_BIN/screenshot" ] \
    || fail "the desktop did not publish screenshot into $TOOLS_BIN"
[ "$(stat -c %a "$TOOLS_BIN/screenshot")" = 755 ] \
    || fail "published screenshot is not mode 755"
grep -q 'kind: desktop.local/tools' "$TOOLS_SPEC" \
    || { tools_diag; fail "tools CDI spec missing after the desktop published its toolkit"; }
grep -q 'DESKTOP_TOOLS_BIN=/opt/desktop-tools/bin' "$TOOLS_SPEC" \
    || fail "tools spec does not inject DESKTOP_TOOLS_BIN"
log "toolkit published and desktop.local/tools advertised by the .path unit"

# And a real client gets it, read-only, without baking anything in.
#
# NOTE: this runner is not SELinux-enforcing, so this proves the mount and the
# exec, NOT that a CONFINED container may execute from the injected directory.
# That case is still uncovered - see the delivery notes in screenshot/README.md.
#
# No `| head` inside the container: under pipefail an early-exiting consumer
# SIGPIPEs the producer, which this repo has been bitten by before.
#
# Flags: --device desktop.local/tools=all is the whole point - no -v and no -e,
# so the mount and DESKTOP_TOOLS_BIN can only have come from the CDI spec's
# containerEdits. --rm because these are one-shot probes and a leftover
# container would pollute the container list the checks below read.
out=$(podman run --rm --device desktop.local/tools=all \
    localhost/desktop-container:latest \
    sh -c 'printenv DESKTOP_TOOLS_BIN; "$DESKTOP_TOOLS_BIN"/screenshot --help' 2>&1) \
    || fail "a client requesting desktop.local/tools could not run the injected binary: $out"
grep -q '/opt/desktop-tools/bin' <<<"$out" \
    || fail "client did not receive DESKTOP_TOOLS_BIN: $out"
grep -qi 'usage' <<<"$out" \
    || fail "the injected screenshot binary did not run: $out"
if podman run --rm --device desktop.local/tools=all localhost/desktop-container:latest \
        sh -c 'touch "$DESKTOP_TOOLS_BIN"/.probe' 2>/dev/null; then
    fail "the injected toolkit is writable from a client; it must be read-only"
fi
log "a client resolved desktop.local/tools and ran the injected binary (read-only)"

log "wait for the container to answer"
up=0
for _ in $(seq 20); do
    podman exec desktop true 2>/dev/null && { up=1; break; }
    sleep 2
done
[ "$up" = 1 ] || fail "container never answered exec"

log "stub CDI resolved through the systemd start (marker env on PID 1)"
# CDI env edits apply to the container's INIT process; podman exec sessions
# do not get them - read PID 1's environment, not the exec env.
podman exec desktop sh -c "tr '\0' '\n' </proc/1/environ | grep -qx NVIDIA_CDI_STUB=1" \
    || fail "NVIDIA_CDI_STUB not injected via AddDevice + stub spec"

log "wait for the container to settle"
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

log "host terminal: loopback ssh as desktop-shell with the boot-fresh key"
[ -f /etc/desktop-container/host-shell-key ] || fail "boot-fresh key missing"
[ "$(stat -c %a /etc/desktop-container/host-shell-key)" = 400 ] || fail "key perms not 0400"
who=$(ssh -i /etc/desktop-container/host-shell-key -o BatchMode=yes -o ConnectTimeout=5 \
    -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null desktop-shell@127.0.0.1 whoami)
[ "$who" = desktop-shell ] || fail "host ssh whoami returned '$who', want desktop-shell"

log "host terminal: same path from inside the container ('ssh host')"
# -u desktop because the Host Terminal menu entry runs as the session user, and
# -e HOME because `podman exec` inherits PID 1's environment rather than the
# logind session's, so ssh would otherwise look for its config under /root.
cwho=""
for _ in $(seq 10); do
    cwho=$(podman exec -u desktop -e HOME=/home/desktop desktop \
        ssh -o ConnectTimeout=5 -o BatchMode=yes host whoami 2>/dev/null || true)
    [ "$cwho" = desktop-shell ] && break
    sleep 3
done
[ "$cwho" = desktop-shell ] || fail "container ssh host returned '$cwho', want desktop-shell"

log "privileges: not --privileged, and a seccomp filter is applied"
# The full set of assertions lives in the VM e2e (verify-privileges); these two
# are the ones that catch a restored --privileged, and this job is a third of
# the e2e's runtime, so the regression surfaces sooner.
priv=$(podman inspect desktop --format '{{.HostConfig.Privileged}}')
[ "$priv" = false ] || fail "podman reports Privileged=$priv, want false"
seccomp=$(podman exec desktop sh -c "awk '/^Seccomp:/{print \$2}' /proc/1/status")
[ "$seccomp" = 2 ] || fail "PID 1 Seccomp=$seccomp, want 2 (filter active)"
log "  Privileged=false, Seccomp=2"

log "desktop-preflight: fully green (no-KMS FAIL tolerated on KMS-less runners)"
# Azure runners expose a Hyper-V DRM device, so preflight is normally 0
# FAILs here and X genuinely runs; a runner image without /dev/dri may
# legitimately report the single no-KMS FAIL instead. Anything else is red.
pf=$(deploy/host/usr/local/bin/desktop-preflight || true)
echo "$pf"
nfail=$(echo "$pf" | grep -c 'FAIL:' || true)
if [ "$nfail" != 0 ]; then
    if [ "$nfail" != 1 ] || ! echo "$pf" | grep -q 'FAIL: no /dev/dri/card\*'; then
        fail "unexpected preflight FAILs on this runner ($nfail)"
    fi
fi

# --- fixed monitor layout: the host file reaches the container ---------------
# ci/monitor-layout-tests.sh covers the generator's own branches; what only a
# real deploy can show is the wiring - that a file dropped in the tree's
# /etc/desktop-container is visible inside through the quadlet's existing
# read-only mount, and is acted on at container start. No quadlet change was
# needed for this feature, and that claim is exactly what would rot silently.
#
# Both halves wait on xorg-conf.service, never on the container merely being
# reachable: the generator runs from that oneshot, which finishes seconds
# AFTER `podman exec` starts working. Reading its output early is not just a
# flaky failure - it would let the no-op assertion pass vacuously, on a
# container that had not yet had the chance to write anything.
wait_xorg_conf() {
    for _ in $(seq 30); do
        podman exec desktop systemctl is-active --quiet xorg-conf.service && return 0
        sleep 2
    done
    podman exec desktop systemctl status xorg-conf.service --no-pager -l >&2 2>&1 || true
    fail "xorg-conf.service never completed in the container"
}

log "fixed monitor layout: the shipped default is a genuine no-op"
[ -f /etc/desktop-container/monitors.conf ] || fail "the tree did not ship monitors.conf"
wait_xorg_conf
# Captured, not piped into grep -q: this script runs under `set -o pipefail`,
# and a grep that stops at the first match leaves podman writing into a closed
# pipe - SIGPIPE, exit 141, and a passing check reported as a failure.
gen_log=$(podman exec desktop journalctl -u xorg-conf -o cat 2>/dev/null || true)
case "$gen_log" in
    *xorg-monitor-conf*) ;;
    *) fail "the layout generator never ran" ;;
esac
if podman exec desktop test -e /etc/X11/xorg.conf.d/30-monitors.conf; then
    fail "a config with no output lines still generated a layout"
fi

log "fixed monitor layout: a declared layout is applied at the next start"
cat > /etc/desktop-container/monitors.conf <<'EOF'
DP-1  1920x1080@60  +0+0     primary
DP-2  1920x1080@60  +1920+0
EOF

log "desktop.service survives a restart"
systemctl restart desktop.service
up=0
for _ in $(seq 20); do
    podman exec desktop true 2>/dev/null && { up=1; break; }
    sleep 2
done
[ "$up" = 1 ] || fail "container did not come back after restart"

# The restart above is what re-runs xorg-conf.service, so the assertions on
# the declared layout land here rather than beside the config that set it up.
wait_xorg_conf
mon=$(podman exec desktop cat /etc/X11/xorg.conf.d/30-monitors.conf 2>/dev/null || true)
if [ -z "$mon" ]; then
    podman exec desktop journalctl -u xorg-conf -o cat 2>/dev/null | grep xorg-monitor-conf >&2 || true
    fail "the declared layout produced no /etc/X11/xorg.conf.d/30-monitors.conf"
fi
echo "$mon" | grep -q 'Identifier  "DP-2"' || fail "generated config does not name the declared outputs"
# A runner with no KMS falls through to the modesetting branch, which is the
# one that has to invent a timing; on a runner with a DRM device it is the
# same branch, because no runner has an NVIDIA GPU.
echo "$mon" | grep -q 'Option      "Enable" "true"' || fail "outputs not forced enabled"
echo "$mon" | grep -q 'Modeline "1920x1080_60.00"' || fail "no derived timing for the declared mode"
# Put the shipped default back, so nothing after this point sees a layout the
# tree does not actually ship.
install -m644 deploy/host/etc/desktop-container/monitors.conf /etc/desktop-container/monitors.conf

log "deploy smoke passed"
