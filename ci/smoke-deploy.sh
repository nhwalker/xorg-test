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
# Evidence (Requirements.md, "Evidence standard"): stories write
# $EV_ROOT/<story>/ through ci/evidence.sh; ci.yml uploads it. A failure inside
# an open story records that story as FAIL before the script exits.
# shellcheck source=ci/evidence.sh
. ci/evidence.sh
fail() { echo "FAIL: $*" >&2; ev_abort "$*"; exit 1; }
[ -z "$EV_ROOT" ] || mkdir -p "$EV_ROOT"
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

# Each leg keeps what the converger printed and the spec it left (S5.4.2).
# The fake toolkit and /dev/nvidiactl stand in for a GPU host; the leg where
# a loaded nvidia module alone keeps the real spec needs a /proc/modules
# override the script does not have yet (Requirements.md, Appendix A).
cdi_leg() { # <moment> <what the leg does> [VAR=value...]: run the converger, keep its output and spec
    local moment=$1 what=$2 rc=0
    shift 2
    CDI_OUT=$(ev_save "$moment-run" "the converger's output: $what" env "$@" "$CDI") || rc=$?
    ev_copy "$SPEC" "$moment-spec" "EV-CONFIG: /etc/cdi/nvidia.yaml after: $what"
    return "$rc"
}
ev_begin S5.4.2 "Real generation, transient failure, no-downgrade, recovery to stub" T2

log "cdi converger: stub on a GPU-less host"
rm -f "$SPEC"
cdi_leg 1-stub "no toolkit, no hardware" || fail "the converger failed on a GPU-less host"
grep -q NVIDIA_CDI_STUB "$SPEC" || fail "stub spec not written"
ev_pass "no toolkit and no hardware: the stub (NVIDIA_CDI_STUB=1)"

log "cdi converger: real generation with (fake) toolkit + hardware"
cat > "$FAKEBIN/nvidia-ctk" <<'EOF'
#!/bin/sh
# fake nvidia-ctk: expects "cdi generate --output=PATH"
out="${3#--output=}"
printf 'cdiVersion: 0.5.0\nkind: nvidia.com/gpu\ndevices:\n  - name: all\n    containerEdits:\n      env:\n        - GENERATED=1\n' > "$out"
EOF
chmod +x "$FAKEBIN/nvidia-ctk"
touch /dev/nvidiactl
cdi_leg 2-generate "a (fake) toolkit and /dev/nvidiactl: nvidia-ctk generates the real spec" PATH="$FAKEBIN:$PATH" \
    || fail "the converger failed with a working toolkit"
grep -q GENERATED "$SPEC" || fail "generation path did not write the real spec"
ev_pass "toolkit and hardware: the real spec nvidia-ctk generated (GENERATED=1)"

log "cdi converger: transient toolkit failure keeps the real spec"
printf '#!/bin/sh\nexit 1\n' > "$FAKEBIN/nvidia-ctk"
cdi_leg 3-transient "nvidia-ctk fails while the hardware is still there" PATH="$FAKEBIN:$PATH" || true
grep -q keeping <<<"$CDI_OUT" || fail "no keep on transient failure"
grep -q GENERATED "$SPEC" || fail "real spec lost on transient failure"
ev_pass "a failing nvidia-ctk keeps the real spec (the converger says it is keeping it)"

log "cdi converger: no downgrade while hardware visible; stub after removal"
rm -f "$FAKEBIN/nvidia-ctk"
cdi_leg 4-no-toolkit "the toolkit gone, /dev/nvidiactl still there" || true
grep -q keeping <<<"$CDI_OUT" || fail "downgraded to stub despite visible hardware"
grep -q GENERATED "$SPEC" || fail "real spec lost while hardware visible"
ev_pass "no toolkit but the hardware visible: the real spec is kept, no downgrade"
rm -f /dev/nvidiactl
cdi_leg 5-recovered "neither the toolkit nor the hardware" || fail "the converger failed after the hardware went"
grep -q NVIDIA_CDI_STUB "$SPEC" || fail "stub not restored after hardware removal"
ev_pass "neither toolkit nor hardware: back to the stub"
ev_note "not tested here: the nvidia module loaded (/proc/modules) with no device node; the script reads /proc/modules directly and has no override a test could use"
ev_end

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
    ev_begin S5.6.1 "No-op without SELinux" T2
    ev_save selinuxfs "EV-STATE: the runner's SELinux state: no /sys/fs/selinux/enforce (the file the labeler checks), and no getenforce" \
        sh -c 'ls -l /sys/fs/selinux/enforce; ls -ld /sys/fs/selinux; command -v getenforce || echo "(no getenforce on this host)"' >/dev/null || true
    # The no-op must be reached before anything touches the filesystem: the
    # directories do not exist yet on this runner at this point in the script.
    targets="/tmp/.X11-unix /run/desktop-audio /var/lib/desktop-container/bin"
    ev_save targets-before "EV-STATE: the directories the labeler would relabel, before it runs" \
        sh -c "ls -ld $targets 2>&1; true" >/dev/null || true
    before=$EV_LAST
    out=$(ev_save labeler "the labeler's output on a host without SELinux: its no-op message, exit 0" "$SELINUX_LABEL") \
        || fail "labeler exited non-zero on a host without SELinux: $out"
    ev_pass "the labeler exits 0 on a host without SELinux"
    echo "$out" | grep -qi 'no selinux\|selinux disabled' \
        || fail "labeler did not report the no-op it took (got: $out)"
    ev_pass "it reports the no-op it took"
    ev_save targets-after "EV-STATE: the same directories after it ran: unchanged" \
        sh -c "ls -ld $targets 2>&1; true" >/dev/null || true
    if [ -n "$EV_DIR" ]; then
        ev_diff targets "EV-DIFF: before and after the labeler; no line may differ" "$before" "$EV_LAST"
        [ "$(sed 1d "$EV_DIR/$before")" = "$(sed 1d "$EV_DIR/$EV_LAST")" ] \
            || fail "the labeler changed something on a host without SELinux (see the diff)"
        ev_pass "it touched nothing: the directories it would label are as they were"
    fi
    ev_end
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
# /dev/snd is a bind mount now, not an AddDevice=, so it must EXIST or podman
# refuses to create the container at all ("statfs /dev/snd: no such file or
# directory") - there is no optional marker for Volume= the way AddDevice= has
# its '-' prefix. This runner has no sound card, which makes it precisely the
# host class that would break, and the container coming up below is the real
# assertion; this one just names the cause if it does not.
[ -d /dev/snd ] \
    || fail "/dev/snd does not exist after tmpfiles: the quadlet's Volume=/dev/snd will fail container creation on any host without a sound card"
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

# S5.3.2: seat-prep's steady state, run the way the host runs it - as its
# unit - before desktop.service starts. Not after: its last step fails if
# anything holds the DRM device or the VT, and once the desktop runs, Xorg
# does. The direct runs above already converged this seat.
log "seat-prep: the steady state as its unit is silent and changes nothing"
ev_begin S5.3.2 "Steady state is silent and idempotent" T2
systemctl start desktop-seat-prep.service \
    || { systemctl status desktop-seat-prep.service --no-pager >&2 || true
         fail "desktop-seat-prep.service failed on a seat already converged"; }
journalctl --sync 2>/dev/null || true
# The cursor of the newest entry: the slice read below starts after it.
cursor=$(journalctl -q -n 1 -o cat --show-cursor 2>/dev/null | sed -n 's/^-- cursor: //p')
[ -n "$cursor" ] || fail "could not read a journal cursor to bound seat-prep's second run"
logind_before=$(systemctl show -p MainPID --value systemd-logind)
ev_save restart "EV-STATE: systemctl restart desktop-seat-prep.service, the second run: exit 0" \
    systemctl restart desktop-seat-prep.service >/dev/null \
    || fail "the second run of desktop-seat-prep.service did not exit 0"
ev_pass "the second run, as the unit, exits 0"
journalctl --sync 2>/dev/null || true
slice=$(journalctl --after-cursor="$cursor" _SYSTEMD_UNIT=desktop-seat-prep.service -o cat --no-pager 2>/dev/null || true)
ev_text journal "EV-LOG-JOURNAL: everything desktop-seat-prep.service's own process logged on the second run (journalctl _SYSTEMD_UNIT=desktop-seat-prep.service after a cursor taken just before it)" \
    "${slice:-(nothing)}"
# Nothing at all, not even seat-prep's "fuser not available": this runner
# has psmisc (desktop-preflight's DRM/VT holder check runs here), so a
# silent steady state is a fully silent slice.
[ -z "$slice" ] || fail "seat-prep's steady state was not silent: $slice"
ev_pass "and its process logs nothing at all"
logind_after=$(systemctl show -p MainPID --value systemd-logind)
ev_text logind "EV-PIDS: systemd-logind's MainPID before and after the second run (seat-prep restarts logind only when it changed something)" \
    "before: $logind_before"$'\n'"after:  $logind_after"
[ "$logind_after" = "$logind_before" ] || fail "the steady state restarted logind ($logind_before -> $logind_after)"
ev_pass "it did not restart logind (MainPID $logind_before)"
ev_end

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

log "wait for the container to settle (desktop-init ready marker)"
# The replacement for `systemctl is-system-running`: desktop-init writes the
# marker once the boot oneshots have run and the session has been launched.
# Deliberately NOT gated on the session surviving - on a GPU-less runner the
# X session may fail exactly like the old suite tolerated a failed
# desktop-session.service.
up=0
for _ in $(seq 40); do
    podman exec desktop test -f /run/desktop-init-ready 2>/dev/null && { up=1; break; }
    sleep 3
done
[ "$up" = 1 ] || fail "desktop-init never wrote /run/desktop-init-ready"

log "audio stack is supervised independently of the X session"
# Two deterministic checks, neither of which needs an X server - which
# matters, because this runner has no KMS and, as the first run of this
# assertion showed, its X session does NOT crash-loop the way I assumed.
# An earlier version of this waited for spontaneous session restarts and
# skipped itself when none came, which is a test that never tests anything.
#
# The e2e proves the X-restart half properly, against a real Xorg it can
# kill (verify-audio-lifecycle). What is provable HERE, on a machine with
# neither a GPU nor a sound card, is the structure and the recovery.
pw_before=""
for _ in $(seq 30); do
    pw_before=$(podman exec desktop sh -c 'pgrep -x pipewire | head -1' 2>/dev/null || true)
    [ -n "$pw_before" ] && break
    sleep 2
done
[ -n "$pw_before" ] \
    || { podman logs desktop 2>&1 | tail -40 >&2 || true
         fail "no pipewire process in the container: the audio stack never started (it no longer waits on X, so a GPU-less host is not an excuse)"; }

# 1. STRUCTURE: PipeWire must live in the audio tree's own process session,
#    not the X session's. That is the whole change, and it is a property of
#    the running system rather than of a restart having happened - so it is
#    checkable at any moment, on any host. desktop-init records the audio
#    tree's leader pid precisely because its supervisor is a separate
#    process; the sid of PipeWire must be that pid.
leader=$(podman exec desktop cat /run/desktop-audio-leader.pid 2>/dev/null || true)
[ -n "$leader" ] \
    || fail "no /run/desktop-audio-leader.pid: desktop-init never launched the audio tree through supervise_audio"
pw_sid=$(podman exec desktop sh -c "ps -o sess= -p $pw_before 2>/dev/null | tr -d ' '" 2>/dev/null || true)
[ "$pw_sid" = "$leader" ] \
    || { podman logs desktop 2>&1 | tail -40 >&2 || true
         fail "pipewire (pid $pw_before) has sid '$pw_sid', want the audio leader $leader: the audio stack is not in its own process session, so stopping the X session would kill it"; }
log "  pipewire pid $pw_before is in the audio tree (sid $leader), not the X session's"

# 2. RECOVERY: the half that had no answer at all before - a daemon dying
#    alone went unnoticed, because the old bare `wait` only returned once
#    every daemon had exited. Kill it and require a NEW one, with the
#    exported socket back: the socket needs the stale file cleared first, or
#    the restarted daemon cannot re-bind and clients keep getting
#    ECONNREFUSED against a socket that looks present.
# As the desktop uid, NOT as container root: CAP_KILL is deliberately
# dropped from this container (in the host pid namespace it would mean
# "may signal any process on the host"), so root in here cannot signal the
# session user's processes at all. desktop-init has the same constraint and
# solves it the same way, via setpriv. Same-uid signaling needs no capability.
podman exec -u desktop desktop pkill -u desktop -x pipewire 2>/dev/null || true
pw_after=""
for _ in $(seq 30); do
    pw_after=$(podman exec desktop sh -c 'pgrep -x pipewire | head -1' 2>/dev/null || true)
    [ -n "$pw_after" ] && [ "$pw_after" != "$pw_before" ] && break
    pw_after=""
    sleep 2
done
[ -n "$pw_after" ] \
    || { podman logs desktop 2>&1 | tail -40 >&2 || true
         fail "pipewire never came back after being killed (was $pw_before): the audio stack has no supervisor of its own"; }
sock=0
for _ in $(seq 30); do
    [ -S /run/desktop-audio/pulse ] && { sock=1; break; }
    sleep 2
done
[ "$sock" = 1 ] \
    || { podman logs desktop 2>&1 | tail -40 >&2 || true
         fail "pipewire restarted as $pw_after but /run/desktop-audio/pulse was not re-exported: stale socket files were not cleared before the restart"; }
log "  pipewire recovered on its own ($pw_before -> $pw_after) and re-exported its socket"

log "host login session: enabled by the tree, active, real seat bookkeeping"
# desktop-session.service ships pre-enabled (a .wants symlink the rsync must
# preserve, like desktop-client-cdi's) and is pulled up by the quadlet's
# Wants=. Even this GPU-less runner has a tty1, so the session itself must
# open; only the X session inside the container is allowed to fail here.
[ "$(systemctl is-enabled desktop-session.service)" = enabled ] \
    || fail "desktop-session.service not enabled after rsync"
sess=0
for _ in $(seq 15); do
    systemctl is-active --quiet desktop-session.service && { sess=1; break; }
    sleep 2
done
[ "$sess" = 1 ] || { systemctl status desktop-session.service --no-pager -l || true; \
    fail "desktop-session.service did not become active"; }
loginctl list-sessions --no-pager | grep -Eq 'desktop +seat0' \
    || { loginctl list-sessions --no-pager || true; fail "no logind session for desktop on seat0"; }
[ -d /run/user/61000 ] || fail "logind did not mount /run/user/61000"

log "stub CDI resolved through the container start (marker env on the init process)"
# CDI env edits apply to the container's INIT process; podman exec sessions
# do not get them. The container shares the HOST pid namespace (--pid=host),
# so /proc/1 is the host's systemd - read desktop-init's own environ via the
# pid it records, not PID 1's.
podman exec desktop sh -c 'tr "\0" "\n" </proc/$(cat /run/desktop-init.pid)/environ | grep -qx NVIDIA_CDI_STUB=1' \
    || fail "NVIDIA_CDI_STUB not injected via AddDevice + stub spec"

log "host terminal: loopback ssh as desktop-shell with the boot-fresh key"
[ -f /etc/desktop-container/host-shell-key ] || fail "boot-fresh key missing"
[ "$(stat -c %a /etc/desktop-container/host-shell-key)" = 400 ] || fail "key perms not 0400"
who=$(ssh -i /etc/desktop-container/host-shell-key -o BatchMode=yes -o ConnectTimeout=5 \
    -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null desktop-shell@127.0.0.1 whoami)
[ "$who" = desktop-shell ] || fail "host ssh whoami returned '$who', want desktop-shell"

log "host terminal: same path from inside the container ('ssh host')"
# -u desktop because the Host Terminal menu entry runs as the session user, and
# -e HOME because `podman exec` inherits the init process's environment rather
# than the session's, so ssh would otherwise look for its config under /root.
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
# /proc/1 is the host's systemd under --pid=host; check the container's own
# init process. Also assert the pid-namespace shape itself, both ways: the
# recorded pid must be meaningful on the HOST (that is the whole feature),
# and its absence would mean the quadlet lost --pid=host.
initpid=$(podman exec desktop cat /run/desktop-init.pid)
[ -d "/proc/$initpid" ] || fail "desktop-init pid $initpid is not visible on the host: --pid=host not in effect?"
grep -q desktop-init "/proc/$initpid/comm" \
    || fail "host pid $initpid is not desktop-init ($(cat /proc/$initpid/comm 2>/dev/null)): stale pid file or pid-ns mismatch"
seccomp=$(podman exec desktop sh -c "awk '/^Seccomp:/{print \$2}' /proc/$initpid/status")
[ "$seccomp" = 2 ] || fail "desktop-init Seccomp=$seccomp, want 2 (filter active)"
log "  Privileged=false, Seccomp=2, init is host pid $initpid"

log "logging: the container log is bounded, not inherited from the host default"
# The cheap half of verify-log-bounds in the VM e2e. Worth repeating here for
# the same reason the privilege checks are: desktop-init and the whole session
# stream to /dev/console continuously, so an unbounded sink is a slow
# disk-filling bug that nothing else in the suite would notice.
ev_begin S2.6.2 "The container log is bounded" T2
ev_save inspect-logconfig "EV-STATE: podman inspect of the running container's log configuration (Type k8s-file, Size 64MB)" \
    podman inspect desktop --format '{{json .HostConfig.LogConfig}}' >/dev/null || true
drv=$(podman inspect desktop --format '{{.HostConfig.LogConfig.Type}}')
[ "$drv" = k8s-file ] || fail "container log driver is '$drv', want k8s-file (LogDriver= did not reach podman)"
ev_pass "the running container's log driver is k8s-file"
# podman normalises the value: "64m" goes in, "64MB" comes back - match the
# number case-insensitively, not the string we passed in.
lc=$(podman inspect desktop --format '{{.HostConfig.LogConfig.Size}}' 2>/dev/null || true)
[ -n "$lc" ] || lc=$(podman inspect desktop --format '{{json .HostConfig.LogConfig}}')
grep -qiE '64 ?mb|67108864' <<<"$lc" \
    || fail "no 64M max-size on the container log (got '$lc'): --log-opt did not reach podman"
ev_pass "its log is capped at 64 MB (podman reports '$lc')"
ev_end
log "  driver=k8s-file, max-size=$lc"

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
# Both halves wait on the ready marker, never on the container merely being
# reachable: desktop-init writes it AFTER the oneshots (the generator among
# them), and `podman exec` starts working seconds earlier. Reading the
# output early is not just a flaky failure - it would let the no-op
# assertion pass vacuously, on a container that had not yet had the chance
# to write anything.
wait_xorg_conf() {
    for _ in $(seq 30); do
        podman exec desktop test -f /run/desktop-init-ready 2>/dev/null && return 0
        sleep 2
    done
    podman logs --tail 40 desktop >&2 2>&1 || true
    fail "desktop-init oneshots never completed in the container"
}

log "fixed monitor layout: the shipped default is a genuine no-op"
ev_begin S3.4.1 "Opt-in: absent or output-less config generates nothing" T2
[ -f /etc/desktop-container/monitors.conf ] || fail "the tree did not ship monitors.conf"
ev_copy /etc/desktop-container/monitors.conf shipped-monitors "EV-CONFIG: the monitors.conf the tree ships: comments only, no output lines"
wait_xorg_conf
# Captured, not piped into grep -q: this script runs under `set -o pipefail`,
# and a grep that stops at the first match leaves podman writing into a closed
# pipe - SIGPIPE, exit 141, and a passing check reported as a failure.
gen_log=$(podman logs desktop 2>/dev/null || true)
case "$gen_log" in
    *xorg-monitor-conf*) ;;
    *) fail "the layout generator never ran" ;;
esac
ev_text generator-log "EV-LOG-DESKTOP: the generator's lines in the desktop's log: the no-op" \
    "$(grep xorg-monitor-conf <<<"$gen_log" || true)"
grep -q 'no fixed layout' <<<"$gen_log" || fail "the generator did not log its no-op"
ev_pass "the generator ran and logged that it applied no fixed layout"
ev_save xorg-conf-d "EV-STATE: ls /etc/X11/xorg.conf.d in the container: 20-gpu.conf, no 30-monitors.conf" \
    podman exec desktop ls -l /etc/X11/xorg.conf.d >/dev/null || true
if podman exec desktop test -e /etc/X11/xorg.conf.d/30-monitors.conf; then
    fail "a config with no output lines still generated a layout"
fi
ev_pass "the shipped comments-only file generated no 30-monitors.conf"
ev_end

# S3.1.5: xorg-gpu-conf logs what it saw before what it decided. The real
# container's own log, this boot: every xorg-gpu-conf line up to the first
# decision. podman's --tty console ends lines with CR, stripped here.
log "xorg-gpu-conf: the evidence lines come before the decision"
ev_begin S3.1.5 "Evidence is logged before the decision" T2
# Read whole, then cut: an awk that exits at the decision inside the pipe
# would leave tr writing into a closed pipe (SIGPIPE, "Broken pipe").
gpu_block=$(podman logs desktop 2>/dev/null | tr -d '\r' || true)
gpu_block=$(awk '/^xorg-gpu-conf: /{print} /^xorg-gpu-conf: decision:/{exit}' <<<"$gpu_block")
ev_text log "EV-LOG-DESKTOP: xorg-gpu-conf's lines in the desktop's log this boot, up to its decision" "${gpu_block:-(none)}"
ev_save sysfs "EV-STATE: the runner's DRM connectors, which the container's sysfs shows too (cat /sys/class/drm/card*-*/status)" \
    sh -c 'for f in /sys/class/drm/card*-*/status; do [ -e "$f" ] && echo "$f: $(cat "$f")"; done; true' >/dev/null || true
grep -q '^xorg-gpu-conf: decision:' <<<"$gpu_block" || fail "xorg-gpu-conf's log has no decision line"
dline=$(grep -n '^xorg-gpu-conf: decision:' <<<"$gpu_block" | head -1 | cut -d: -f1)
for what in "DRM nodes:" "NVIDIA nodes:"; do
    n=$(grep -nF "xorg-gpu-conf: $what" <<<"$gpu_block" | head -1 | cut -d: -f1)
    [ -n "$n" ] && [ "$n" -lt "$dline" ] || fail "\"$what\" is not logged before the decision"
    ev_pass "\"$what\" is logged (line $n) before the decision (line $dline)"
done
shopt -s nullglob
conns=(/sys/class/drm/card*-*/status)
shopt -u nullglob
logged=$(grep -c '^xorg-gpu-conf: connector ' <<<"$gpu_block" || true)
[ "$logged" = "${#conns[@]}" ] || fail "xorg-gpu-conf logged $logged connector line(s) before deciding; the runner has ${#conns[@]}"
ev_pass "every connector's status is logged before the decision (${#conns[@]} on this runner)"
ev_end

# S3.1.4: with no KMS device, a stale 20-gpu.conf goes. The production
# container is recreated at every start and this runner usually has KMS, so
# neither shows it; a scratch container of the image without /dev/dri does.
log "xorg-gpu-conf: no KMS device removes a stale config (scratch container)"
ev_begin S3.1.4 "No KMS device removes the config" T2
scratch=$(ev_save scratch "a scratch container of the image with no /dev/dri passed in: a stale 20-gpu.conf written, xorg-gpu-conf run, the directory listed before and after" \
    podman run --rm --network=none --entrypoint /bin/bash localhost/desktop-container:latest -c '
        mkdir -p /etc/X11/xorg.conf.d
        echo "# stale, from an earlier boot" > /etc/X11/xorg.conf.d/20-gpu.conf
        echo "-- before:"; ls -l /etc/X11/xorg.conf.d
        echo "-- /dev/dri:"; ls -d /dev/dri 2>&1
        /usr/local/bin/xorg-gpu-conf.sh
        echo "-- after:"; ls -l /etc/X11/xorg.conf.d') \
    || fail "the scratch run of xorg-gpu-conf failed"
ev_text before "EV-STATE: ls /etc/X11/xorg.conf.d in the scratch container before the run: the stale 20-gpu.conf" \
    "$(sed -n '/^-- before:/,/^-- \/dev\/dri:/p' <<<"$scratch" | sed '1d;$d')"
ev_text after "EV-STATE: ls /etc/X11/xorg.conf.d after the run: no 20-gpu.conf" \
    "$(sed -n '/^-- after:/,$p' <<<"$scratch" | sed '1d')"
grep -q '20-gpu.conf' <<<"$(sed -n '/^-- before:/,/^-- \/dev\/dri:/p' <<<"$scratch")" \
    || fail "the stale 20-gpu.conf was not in place before the run"
grep -q 'does not exist; removing generated config' <<<"$scratch" \
    || fail "xorg-gpu-conf did not log the removal"
ev_pass "xorg-gpu-conf logs that the card does not exist and the config goes"
if grep -q '20-gpu.conf' <<<"$(sed -n '/^-- after:/,$p' <<<"$scratch")"; then
    fail "the stale 20-gpu.conf survived a boot with no KMS device"
fi
ev_pass "the stale 20-gpu.conf is gone after the run"
ev_end

log "fixed monitor layout: a declared layout is applied at the next start"
cat > /etc/desktop-container/monitors.conf <<'EOF'
DP-1  1920x1080@60  +0+0     primary
DP-2  1920x1080@60  +1920+0
EOF

log "desktop.service survives a restart (and the host session moves with it)"
systemctl restart desktop.service
up=0
for _ in $(seq 20); do
    podman exec desktop true 2>/dev/null && { up=1; break; }
    sleep 2
done
[ "$up" = 1 ] || fail "container did not come back after restart"
# PartOf=desktop.service restarted the session too; give PAM a moment.
sess=0
for _ in $(seq 15); do
    systemctl is-active --quiet desktop-session.service && { sess=1; break; }
    sleep 2
done
[ "$sess" = 1 ] || fail "desktop-session.service did not come back with the container (PartOf= broken?)"

# The restart above is what re-runs xorg-conf.service, so the assertions on
# the declared layout land here rather than beside the config that set it up.
wait_xorg_conf
ev_begin S3.4.8 "The host file reaches the container and is acted on at start" T2
ev_copy /etc/desktop-container/monitors.conf host-monitors "EV-CONFIG: the layout declared on the host, /etc/desktop-container/monitors.conf: DP-1 and DP-2 side by side"
ev_save container-view "EV-STATE: the same file read inside the container, and its mount there (ro in the mount options)" \
    podman exec desktop sh -c 'cat /etc/desktop-container/monitors.conf; echo "-- mount"; grep " /etc/desktop-container " /proc/self/mountinfo' >/dev/null \
    || fail "the container cannot read /etc/desktop-container/monitors.conf"
opts=$(podman exec desktop sh -c 'grep " /etc/desktop-container " /proc/self/mountinfo' | awk '{print $6; exit}')
case ",$opts," in
    *,ro,*) ;;
    *) fail "/etc/desktop-container is mounted '$opts' in the container, not read-only" ;;
esac
ev_pass "the container sees the host's file, read-only (mount options $opts)"
mon=$(podman exec desktop cat /etc/X11/xorg.conf.d/30-monitors.conf 2>/dev/null || true)
if [ -z "$mon" ]; then
    podman logs desktop 2>/dev/null | grep xorg-monitor-conf >&2 || true
    fail "the declared layout produced no /etc/X11/xorg.conf.d/30-monitors.conf"
fi
ev_text generated "EV-CONFIG: the 30-monitors.conf the container generated from it at this start" "$mon"
echo "$mon" | grep -q 'Identifier  "DP-2"' || fail "generated config does not name the declared outputs"
ev_pass "the generated config names the declared outputs"
# A runner with no KMS falls through to the modesetting branch, which is the
# one that has to invent a timing; on a runner with a DRM device it is the
# same branch, because no runner has an NVIDIA GPU.
echo "$mon" | grep -q 'Option      "Enable" "true"' || fail "outputs not forced enabled"
echo "$mon" | grep -q 'Modeline "1920x1080_60.00"' || fail "no derived timing for the declared mode"
ev_pass "it forces them enabled, with the derived 1920x1080_60.00 timing"
layout_log=$(podman logs desktop 2>/dev/null | grep 'xorg-monitor-conf: fixed layout' || true)
ev_text generator-log "EV-LOG-DESKTOP: the generator's 'fixed layout' lines in the desktop's log (one per start that applied a layout)" \
    "${layout_log:-(none)}"
[ -n "$layout_log" ] || fail "the generator did not log the fixed layout it applied"
ev_pass "the desktop's log has the generator's 'fixed layout' line"
ev_end
# Put the shipped default back, so nothing after this point sees a layout the
# tree does not actually ship.
install -m644 deploy/host/etc/desktop-container/monitors.conf /etc/desktop-container/monitors.conf

log "deploy smoke passed"
