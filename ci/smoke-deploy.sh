#!/bin/bash
# Deploy-tree boot smoke for CI (run as root on an EPHEMERAL runner, AFTER
# ci/smoke-podman.sh: that suite ends with install.sh --uninstall, so this
# one proves the declarative deploy/ tree converts a just-restored host
# from scratch - apply, converge, boot, verify - with no install script).
# Assumes localhost/desktop-container:latest already built.
#
# Also carries the script-level branch tests that need root and a live
# systemd (CDI converger no-downgrade rules, seat-prep on a deliberately
# dirty seat) - the quadlet dry-run step earlier in the job covers only
# the happy paths.
set -euo pipefail
cd "$(dirname "$0")/.."

CDI=deploy/host/usr/local/libexec/desktop-cdi-refresh
SEATPREP=deploy/host/usr/local/libexec/seat-prep.sh
SPEC=/etc/cdi/nvidia.yaml
log()  { echo "== $*"; }
fail() { echo "FAIL: $*" >&2; exit 1; }

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
# the sshd_config.d drop-in is read at sshd start; this runner's sshd predates it
systemctl reload ssh 2>/dev/null || systemctl reload sshd 2>/dev/null || true

log "start desktop.service (generated from the tree's quadlet)"
systemctl start desktop.service

log "converger oneshots all pulled in and succeeded"
for u in desktop-seat-prep desktop-cdi-refresh desktop-host-shell; do
    systemctl is-active --quiet "$u.service" \
        || { systemctl status "$u.service" --no-pager || true; fail "$u.service not active"; }
done

log "wait for the container to answer"
up=0
for _ in $(seq 20); do
    podman exec desktop true 2>/dev/null && { up=1; break; }
    sleep 2
done
[ "$up" = 1 ] || fail "container never answered exec"

log "stub CDI resolved through the systemd start (marker env visible inside)"
podman exec desktop sh -c 'test "$NVIDIA_CDI_STUB" = 1' \
    || fail "NVIDIA_CDI_STUB not injected via AddDevice + stub spec"

log "wait for the container to settle (same envelope as smoke-podman)"
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
cwho=""
for _ in $(seq 10); do
    cwho=$(podman exec -u desktop -e HOME=/home/desktop desktop \
        ssh -o ConnectTimeout=5 -o BatchMode=yes host whoami 2>/dev/null || true)
    [ "$cwho" = desktop-shell ] && break
    sleep 3
done
[ "$cwho" = desktop-shell ] || fail "container ssh host returned '$cwho', want desktop-shell"

log "desktop-preflight: green except the runner's known gap (no KMS device)"
pf=$(deploy/host/usr/local/bin/desktop-preflight || true)
echo "$pf"
nfail=$(echo "$pf" | grep -c 'FAIL:' || true)
[ "$nfail" = 1 ] || fail "expected exactly 1 preflight FAIL on this runner, got $nfail"
echo "$pf" | grep -q 'FAIL: no /dev/dri/card\*' || fail "the one FAIL is not the expected no-KMS gap"

log "desktop.service survives a restart"
systemctl restart desktop.service
up=0
for _ in $(seq 20); do
    podman exec desktop true 2>/dev/null && { up=1; break; }
    sleep 2
done
[ "$up" = 1 ] || fail "container did not come back after restart"

log "deploy smoke passed"
