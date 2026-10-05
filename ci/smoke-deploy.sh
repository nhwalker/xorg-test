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
# First line of <text> matching <regex>, as a line number (empty when none:
# under pipefail grep's no-match status would otherwise end the script, with
# no FAIL saying why, at the caller's assignment).
line_in() { grep -n -m1 -e "$2" <<<"$1" | cut -d: -f1 || true; }
# The desktop's console log so far; podman's --tty console ends lines with CR.
desktop_log() { podman logs desktop 2>/dev/null | tr -d '\r' || true; }
# The X session is up: mwm (its client) running and the server answering.
x_up() {
    podman exec desktop pgrep -u desktop -x mwm >/dev/null 2>&1 \
        && podman exec -u desktop -e DISPLAY=:0 desktop xdpyinfo >/dev/null 2>&1
}
wait_x_up() { # <when>
    for _ in $(seq 30); do x_up && return 0; sleep 2; done
    podman logs --tail 60 desktop >&2 2>&1 || true
    fail "the X session is not up ($1): no mwm, or xdpyinfo gets no answer on :0"
}
first_xorg() { local p; p=$(podman exec desktop pgrep -x Xorg 2>/dev/null || true); head -n 1 <<<"$p"; }
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
ev_begin S5.5.3 "Atomic writes" T2
ev_save cdi-before "EV-STATE: ls -li /etc/cdi before a regeneration" ls -li /etc/cdi >/dev/null || true
cdi_before=$EV_LAST
ino_display=$(stat -c %i "$DISPLAY_SPEC")
ino_audio=$(stat -c %i "$AUDIO_SPEC")
ev_end
ev_begin S5.5.2 "Overrides and validation" T2
mkdir -p /etc/desktop-container
cat > /etc/desktop-container/client-cdi.conf <<'EOF'
DISPLAY_VALUE=:3
X11_DIR=/tmp/other-x11
AUDIO_DIR=/run/other-audio
EOF
ev_copy /etc/desktop-container/client-cdi.conf override "EV-CONFIG: the override file: DISPLAY_VALUE, X11_DIR and AUDIO_DIR"
"$CLIENT_CDI" >/dev/null
ev_copy "$DISPLAY_SPEC" display-overridden "EV-CONFIG: the display spec written with the override file"
ev_copy "$AUDIO_SPEC" audio-overridden "EV-CONFIG: the audio spec written with the override file"
grep -q 'DISPLAY=:3' "$DISPLAY_SPEC" || fail "override DISPLAY not applied"
ev_pass "DISPLAY_VALUE reaches the display spec (DISPLAY=:3)"
grep -q 'hostPath: /tmp/other-x11' "$DISPLAY_SPEC" && grep -q 'containerPath: /tmp/other-x11' "$DISPLAY_SPEC" \
    || fail "override X11_DIR not applied to the display spec's mount"
ev_pass "X11_DIR reaches the display spec's mount (/tmp/other-x11, both ends)"
grep -q 'PULSE_SERVER=unix:/run/other-audio/pulse' "$AUDIO_SPEC" \
    && grep -q 'PIPEWIRE_REMOTE=/run/other-audio/pipewire-0' "$AUDIO_SPEC" \
    && grep -q 'hostPath: /run/other-audio' "$AUDIO_SPEC" \
    || fail "override AUDIO_DIR not applied to the audio spec"
ev_pass "AUDIO_DIR reaches the audio spec: PULSE_SERVER, PIPEWIRE_REMOTE and the mount"
if grep -q 'other-x11' "$AUDIO_SPEC" || grep -q 'other-audio' "$DISPLAY_SPEC"; then
    fail "an override crossed into the other device's spec"
fi
ev_pass "each override lands in its own spec only"
ev_end

ev_begin S5.5.3 "Atomic writes" T2
ev_save cdi-after "EV-STATE: ls -li /etc/cdi after the regeneration" ls -li /etc/cdi >/dev/null || true
ev_diff cdi "EV-DIFF: /etc/cdi before and after the regeneration: both specs are new inodes" "$cdi_before" "$EV_LAST"
[ "$(stat -c %i "$DISPLAY_SPEC")" != "$ino_display" ] && [ "$(stat -c %i "$AUDIO_SPEC")" != "$ino_audio" ] \
    || fail "a spec kept its inode across a regeneration: written in place, not renamed over"
ev_pass "both specs are new inodes (display $ino_display -> $(stat -c %i "$DISPLAY_SPEC"), audio $ino_audio -> $(stat -c %i "$AUDIO_SPEC")): written to a temp file and renamed over"
leftovers=$(find /etc/cdi -name 'desktop-*.yaml.*' | wc -l)
[ "$leftovers" = 0 ] || fail "generator left $leftovers temp file(s) in /etc/cdi"
ev_pass "no temp file is left in /etc/cdi"
ev_end

log "client cdi: a bad DISPLAY value is rejected, leaving both specs intact"
ev_begin S5.5.2 "Overrides and validation" T2
echo 'DISPLAY_VALUE=nonsense' > /etc/desktop-container/client-cdi.conf
ev_copy /etc/desktop-container/client-cdi.conf bad-override "EV-CONFIG: an override file with a malformed DISPLAY_VALUE"
if ev_save rejected "the generator on the malformed value: its message and exit status" "$CLIENT_CDI" >/dev/null; then
    fail "generator accepted a malformed DISPLAY_VALUE"
fi
ev_pass "the generator rejects DISPLAY_VALUE=nonsense (non-zero exit)"
grep -q 'DISPLAY=:3' "$DISPLAY_SPEC" \
    || fail "failed run clobbered the display spec (validation must precede any write)"
grep -q '/run/other-audio' "$AUDIO_SPEC" \
    || fail "failed run clobbered the audio spec (validation must precede any write)"
ev_pass "before any write: both specs still carry the previous overrides"
ev_save cdi-rejected "EV-STATE: ls -la /etc/cdi after the rejected run" ls -la /etc/cdi >/dev/null || true
leftovers=$(find /etc/cdi -name 'desktop-*.yaml.*' | wc -l)
[ "$leftovers" = 0 ] || fail "generator left $leftovers temp file(s) in /etc/cdi"
ev_pass "and no temp file is left"
rm -f /etc/desktop-container/client-cdi.conf
"$CLIENT_CDI" >/dev/null
ev_copy "$DISPLAY_SPEC" display-defaults "EV-CONFIG: the display spec once the override file is removed"
ev_copy "$AUDIO_SPEC" audio-defaults "EV-CONFIG: the audio spec once the override file is removed"
grep -q 'DISPLAY=:0' "$DISPLAY_SPEC" && grep -q 'hostPath: /tmp/.X11-unix' "$DISPLAY_SPEC" \
    && grep -q 'hostPath: /run/desktop-audio' "$AUDIO_SPEC" \
    || fail "defaults not restored after removing the override"
ev_pass "with the file removed the defaults return (DISPLAY=:0, /tmp/.X11-unix, /run/desktop-audio)"
ev_end

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
# S5.3.5: the tree is not applied yet, so logind's drop-in is absent, and
# this run changes the seat: the warning must say so.
ev_begin S5.3.5 "Missing logind drop-in is warned about" T2
ev_save dropin "EV-STATE: /etc/systemd/logind.conf.d before the tree is applied: no 50-desktop-container.conf" \
    sh -c 'ls -la /etc/systemd/logind.conf.d 2>&1; test -e /etc/systemd/logind.conf.d/50-desktop-container.conf || echo "(50-desktop-container.conf absent)"' >/dev/null || true
ev_text seat-prep "the dirty-seat run's output: a seat rule and a running display manager, so the seat changed" "$out"
grep -q 'WARNING: logind drop-in missing' <<<"$out" || fail "seat-prep changed the seat with the logind drop-in absent and did not warn"
ev_pass "seat-prep changed the seat and warned 'logind drop-in missing'"
ev_end
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

log "a soundless host: no sound card before the tree's tmpfiles run"
ev_begin S4.4.2 "Soundless host boots and degrades gracefully" T2
ev_save snd-before "EV-STATE: ls -la /dev/snd on the host before the tree's tmpfiles run" sh -c 'ls -la /dev/snd 2>&1; true' >/dev/null
shopt -s nullglob
cards=(/dev/snd/controlC*)
shopt -u nullglob
[ "${#cards[@]}" = 0 ] || fail "this runner has a sound card (${cards[*]}): S4.4.2 needs a soundless host"
ev_pass "the runner has no sound card: no /dev/snd/controlC*"
ev_end

log "apply the deploy tree (verbatim README command)"
rsync -a --chown=root:root deploy/host/ /
[ -L /etc/systemd/system/getty@tty1.service ] || fail "getty mask did not survive as a symlink"
[ "$(readlink /etc/systemd/system/default.target)" = /usr/lib/systemd/system/multi-user.target ] \
    || fail "default.target symlink wrong"
systemctl daemon-reload
systemd-sysusers
systemd-tmpfiles --create || true   # unrelated runner entries may fail; ours asserted below
[ -d /run/desktop-audio ] && [ -d /tmp/.X11-unix ] || fail "tmpfiles dirs missing"

log "the tree's files land root-owned, its scripts executable"
ev_begin S5.1.2 "Files land root-owned with correct modes" T2
mapfile -t tree_files < <(cd deploy/host && find . -type f | sed 's|^\.||' | sort)
listing=$(stat -c '%A %U %G %n' "${tree_files[@]}") || fail "a file of the tree is missing from the host after the rsync"
ev_text files "EV-STATE: mode, owner and group of every file the tree installed (stat -c '%A %U %G %n')" "$listing"
bad=$(awk '$2 != "root" || $3 != "root"' <<<"$listing")
[ -z "$bad" ] || fail "files not root:root: $bad"
ev_pass "all ${#tree_files[@]} files are root:root"
bad=$(awk 'substr($1,6,1) == "w" || substr($1,9,1) == "w"' <<<"$listing")
[ -z "$bad" ] || fail "group- or world-writable files: $bad"
ev_pass "none is writable by group or others"
bad=$(awk '$4 ~ "^/usr/local/(bin|libexec)/" && (substr($1,4,1) != "x" || substr($1,7,1) != "x" || substr($1,10,1) != "x")' <<<"$listing")
[ -z "$bad" ] || fail "scripts that are not executable by all: $bad"
ev_pass "every script under /usr/local/bin and /usr/local/libexec is executable (rwxr-xr-x)"
ev_end

log "tmpfiles: the eight entries, with their modes and owners"
ev_begin S5.9.3 "tmpfiles entries" T2
ev_copy /etc/tmpfiles.d/desktop-container.conf tmpfiles "EV-CONFIG: the tree's tmpfiles.d entries, as installed"
table=$(awk '$1 == "d" {print $2}' /etc/tmpfiles.d/desktop-container.conf | xargs stat -c '%a %U %G %n' 2>&1 || true)
ev_text stat "EV-STATE: stat -c '%a %U %G' of each entry's path after systemd-tmpfiles --create" "$table"
n=0
while read -r type path mode user group _; do
    [ "$type" = d ] || continue
    n=$((n + 1))
    want="$(printf '%o' "$((8#$mode))") $user $group"
    got=$(stat -c '%a %U %G' "$path" 2>/dev/null || echo missing)
    [ "$got" = "$want" ] || fail "tmpfiles entry $path is '$got', want '$want'"
done < <(grep -v '^#' /etc/tmpfiles.d/desktop-container.conf | grep .)
[ "$n" = 8 ] || fail "the tree has $n tmpfiles entries, want the eight"
ev_pass "all eight entries exist with the mode, owner and group the tree gives them"
ev_end

ev_begin S4.4.2 "Soundless host boots and degrades gracefully" T2
ev_save snd-after-tmpfiles "EV-STATE: ls -ld /dev/snd after the tree's tmpfiles: the empty directory it makes" \
    ls -ld /dev/snd >/dev/null || fail "tmpfiles did not make /dev/snd"
ev_pass "tmpfiles made an empty /dev/snd, so the quadlet's Volume=/dev/snd can mount"
ev_end
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

# S5.5.4: the tools spec is written only for a directory holding a regular
# file. TOOLS_DIR comes from the override file the generator reads; the spec
# it writes here is removed again, since the desktop's own first publish
# below must be what creates it.
log "tools spec: written only for a directory that holds a regular file"
ev_begin S5.5.4 "Tools spec is gated on a populated directory" T2
tx=$(mktemp -d)
echo "TOOLS_DIR=$tx" > /etc/desktop-container/client-cdi.conf
ev_copy /etc/desktop-container/client-cdi.conf override "EV-CONFIG: the override file: TOOLS_DIR=$tx"
tools_case() { # <moment> <what>
    ev_save "$1-dir" "EV-STATE: ls -la $tx ($2)" ls -la "$tx" >/dev/null || true
    ev_save "$1-run" "desktop-tools-cdi's output ($2)" /usr/local/libexec/desktop-tools-cdi
}
out=$(tools_case empty "empty") || fail "desktop-tools-cdi failed on an empty TOOLS_DIR"
[ ! -e "$TOOLS_SPEC" ] || fail "an empty TOOLS_DIR produced a spec"
grep -q 'is empty or missing: not advertising' <<<"$out" || fail "no 'empty or missing' line for an empty TOOLS_DIR"
ev_pass "empty: no spec, and it says so"
touch "$tx/.hidden"
out=$(tools_case dotfile "a dotfile only") || fail "desktop-tools-cdi failed on a dotfile-only TOOLS_DIR"
[ ! -e "$TOOLS_SPEC" ] || fail "a dotfile-only TOOLS_DIR produced a spec"
ev_pass "a dotfile only: no spec"
printf '#!/bin/sh\n' > "$tx/tool"
chmod 755 "$tx/tool"
out=$(tools_case populated "one regular file") || fail "desktop-tools-cdi failed on a populated TOOLS_DIR"
[ -e "$TOOLS_SPEC" ] || fail "a populated TOOLS_DIR produced no spec"
ev_copy "$TOOLS_SPEC" spec "EV-CONFIG: the spec written for the populated directory"
grep -q 'DESKTOP_TOOLS_BIN=/opt/desktop-tools/bin' "$TOOLS_SPEC" && grep -q "hostPath: $tx" "$TOOLS_SPEC" \
    && grep -q '"rbind", "ro"' "$TOOLS_SPEC" || fail "the spec lacks DESKTOP_TOOLS_BIN, the TOOLS_DIR mount or ro"
ev_pass "one regular file: a spec with DESKTOP_TOOLS_BIN and a read-only mount of TOOLS_DIR"
n_rel=$(line_in "$out" 'nothing to label')
n_wrote=$(line_in "$out" '^wrote ')
[ -n "$n_rel" ] && [ -n "$n_wrote" ] && [ "$n_rel" -lt "$n_wrote" ] \
    || fail "the relabeler's line does not come before 'wrote' in desktop-tools-cdi's output"
ev_pass "the relabeler ran first: its line ($n_rel) comes before 'wrote' ($n_wrote); on this SELinux-less runner it labels nothing"
rm -f "$TOOLS_SPEC" /etc/desktop-container/client-cdi.conf
rm -r "$tx"
ev_end

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

# S5.3.4: without psmisc the DRM/VT holder gate is skipped, with a notice.
# The PATH here is a directory of links to every command in the usual
# PATH directories except fuser.
log "seat-prep without psmisc: the holder gate is skipped with a notice"
ev_begin S5.3.4 "Degrades without psmisc" T2
nofuser=$(mktemp -d)
# /bin is /usr/bin here, so names repeat: the first one wins, and -L also
# catches a link already made to a dangling target, which -e would miss.
shopt -s nullglob
for d in /usr/local/sbin /usr/local/bin /usr/sbin /usr/bin /sbin /bin; do
    for e in "$d"/*; do
        n=${e##*/}
        [ "$n" = fuser ] || [ -e "$nofuser/$n" ] || [ -L "$nofuser/$n" ] || ln -s "$e" "$nofuser/$n"
    done
done
shopt -u nullglob
if PATH="$nofuser" command -v fuser >/dev/null; then
    fail "fuser is still on the test PATH"
fi
ev_note "PATH for this run: $nofuser, links to every command in the usual PATH directories except fuser (command -v fuser finds nothing there)"
out=$(ev_save run "EV-STATE: seat-prep.sh with fuser absent from PATH: its output and exit status" \
    env PATH="$nofuser" "$SEATPREP") || fail "seat-prep exited non-zero without fuser"
ev_pass "seat-prep exits 0 without fuser"
grep -q 'fuser not available (install psmisc); skipping DRM/VT holder verification' <<<"$out" \
    || fail "no 'fuser not available' notice without fuser"
ev_pass "and says it skipped the DRM/VT holder check"
rm -r "$nofuser"
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

# --- E2 on the first boot: order, markers, logging, the two trees -------------
# The runner's real deploy, first start. Azure runners expose a Hyper-V DRM
# device and this is a real X session: wait_x_up holds the stories below to
# that rather than assuming it.


log "E2 on the first boot: the X session is up"
wait_x_up "first boot"
boot_log=$(desktop_log)

log "logging: every part of the desktop writes to its console log"
ev_begin S2.6.1 "Everything lands in podman logs" T2
ev_text boot-log "EV-LOG-DESKTOP: podman logs desktop from the container's start: the first boot, with the audio stack's restart from the recovery check above" "$boot_log"
for p in 'desktop-init:' 'preflight:' 'align-device-groups:' 'xorg-gpu-conf:' 'xorg-monitor-conf:' 'start-audio:' 'published'; do
    n=$(line_in "$boot_log" "^$p")
    [ -n "$n" ] || fail "no line starting '$p' in the desktop's log"
    ev_pass "'$p' lines are in it, the first at line $n: $(sed -n "${n}p" <<<"$boot_log" | cut -c1-100)"
done
ev_end

log "a soundless host degrades gracefully: the preflight warns, PipeWire runs and exports"
ev_begin S4.4.2 "Soundless host boots and degrades gracefully" T2
w=$(grep 'preflight: WARN: no /dev/snd/controlC\* visible' <<<"$boot_log" || true)
ev_text preflight-warn "EV-LOG-DESKTOP: the preflight's sound line in the desktop's log" "${w:-(none)}"
[ -n "$w" ] || fail "the preflight did not warn that no /dev/snd/controlC* is visible"
ev_pass "the preflight WARNs: no /dev/snd/controlC* visible"
ev_save pipewire "EV-PIDS: the audio daemons on the soundless host" \
    podman exec desktop ps -o pid,user,lstart,comm -C pipewire,wireplumber,pipewire-pulse >/dev/null \
    || fail "no audio daemon running on the soundless host"
ev_save export "EV-STATE: ls -l /run/desktop-audio on the host" ls -l /run/desktop-audio >/dev/null || true
[ -S /run/desktop-audio/pulse ] && [ -S /run/desktop-audio/pipewire-0 ] || fail "the audio sockets are not exported"
ev_pass "PipeWire, WirePlumber and pipewire-pulse run, and both sockets are exported"
ev_end

log "VT nodes: made by ensure-vt-devices, the runtime not exposing them"
ev_begin S3.2.3 "VT nodes are created when the runtime does not expose them" T2
made=$(grep '^ensure-vt-devices: ' <<<"$boot_log" || true)
ev_text log "EV-LOG-DESKTOP: ensure-vt-devices' lines in the desktop's log this boot" "${made:-(none)}"
for t in "tty0 (c 4:0)" "tty1 (c 4:1)"; do
    c=$(grep -cF "ensure-vt-devices: created /dev/$t" <<<"$made" || true)
    [ "$c" = 1 ] || fail "'created /dev/$t' appears $c time(s), want once"
done
ev_pass "it logged 'created /dev/tty0 (c 4:0)' and 'created /dev/tty1 (c 4:1)', once each"
nodes=$(ev_save stat "EV-STATE: stat of /dev/tty0 and /dev/tty1 in the container: type, major:minor, mode, owner" \
    podman exec desktop stat -c '%F %t:%T %a %U:%G %n' /dev/tty0 /dev/tty1) || fail "no VT nodes in the container"
grep -qx 'character special file 4:0 620 root:tty /dev/tty0' <<<"$nodes" || fail "/dev/tty0 is not c 4:0 620 root:tty: $nodes"
grep -qx 'character special file 4:1 620 desktop:tty /dev/tty1' <<<"$nodes" || fail "/dev/tty1 is not c 4:1 620 desktop:tty: $nodes"
ev_pass "/dev/tty0 is c 4:0, 620, root:tty; /dev/tty1 is c 4:1, 620, handed to desktop:tty"
ev_end

log "accounts: the uid contract and a boring desktop-shell"
ev_begin S5.9.1 "uid contract" T2
both=$(ev_save both "EV-STATE: the host's getent passwd desktop, then the image's id -u desktop" \
    sh -c 'getent passwd desktop; podman exec desktop id -u desktop') || fail "could not read the desktop account on both sides"
host_line=$(sed -n 1p <<<"$both")
[ "$(cut -d: -f3 <<<"$host_line")" = 61000 ] || fail "the host's desktop is not uid 61000: $host_line"
[ "$(cut -d: -f7 <<<"$host_line")" = /usr/sbin/nologin ] || fail "the host's desktop has a login shell: $host_line"
ev_pass "the host's desktop is uid 61000 with /usr/sbin/nologin"
[ "$(sed -n 2p <<<"$both")" = 61000 ] || fail "the image's desktop is uid $(sed -n 2p <<<"$both"), not 61000"
ev_pass "the image's desktop is uid 61000 too"
ev_end
ev_begin S5.9.2 "desktop-shell is boring" T2
idl=$(ev_save id "EV-STATE: id desktop-shell" id desktop-shell) || fail "no desktop-shell account"
grep -qE '^uid=[0-9]+\(desktop-shell\) gid=[0-9]+\(desktop-shell\) groups=[0-9]+\(desktop-shell\)$' <<<"$idl" \
    || fail "desktop-shell has supplementary groups: $idl"
ev_pass "no supplementary groups (only its own)"
pw=$(ev_save passwd-status "EV-STATE: passwd -S desktop-shell" passwd -S desktop-shell) || fail "passwd -S failed"
[ "$(awk '{print $2}' <<<"$pw")" = L ] || fail "desktop-shell's password is not locked: $pw"
ev_pass "its password is locked (passwd -S: L)"
acct=$(ev_save account "EV-STATE: getent passwd desktop-shell and stat of its home" \
    sh -c 'getent passwd desktop-shell; stat -c "%a %U:%G %n" /home/desktop-shell') || fail "could not read desktop-shell's entry or home"
[ "$(sed -n 1p <<<"$acct" | cut -d: -f7)" = /bin/bash ] || fail "desktop-shell's shell is not /bin/bash"
ev_pass "its shell is /bin/bash"
[ "$(sed -n 2p <<<"$acct")" = "700 desktop-shell:desktop-shell /home/desktop-shell" ] || fail "desktop-shell's home is not 0700 and its own: $(sed -n 2p <<<"$acct")"
ev_pass "its home is 0700 and its own"
ev_end

ev_begin S6.2.4 "Not systemd mode" T2
sig=$(ev_save stop-signal "EV-STATE: podman inspect desktop --format '{{.Config.StopSignal}}' (the running container)" \
    podman inspect desktop --format '{{.Config.StopSignal}}') || fail "could not inspect the running container"
case "$sig" in
    SIGTERM|15) ev_pass "the running container stops with SIGTERM ($sig)" ;;
    *) fail "the running container's stop signal is '$sig', not SIGTERM" ;;
esac
ev_end

log "boot oneshots: each one's first line, in the documented order, before 'oneshots done'"
ev_begin S2.1.1 "Oneshots run in the documented order" T2
done_n=$(line_in "$boot_log" '^desktop-init: oneshots done')
[ -n "$done_n" ] || fail "desktop-init never logged 'oneshots done'"
ev_text to-oneshots-done "EV-LOG-DESKTOP: the desktop's log from the container's start to 'oneshots done' (line $done_n)" \
    "$(sed -n "1,${done_n}p" <<<"$boot_log")"
prev=0
for p in 'ensure-vt-devices:' 'align-device-groups:' 'host-shell-setup:' 'preflight:' 'xorg-gpu-conf:' 'xorg-monitor-conf:' 'published '; do
    n=$(line_in "$boot_log" "^$p")
    if [ -z "$n" ] && [ "$p" = 'ensure-vt-devices:' ]; then
        ev_note "ensure-vt-devices logged nothing: it logs only when it creates a node, and this container had them all"
        continue
    fi
    [ -n "$n" ] && [ "$n" -gt "$prev" ] && [ "$n" -lt "$done_n" ] \
        || fail "'$p' first at line ${n:-none}: want after line $prev (the previous oneshot's first) and before 'oneshots done' (line $done_n)"
    ev_pass "'$p' first at line $n: after line $prev and before 'oneshots done' (line $done_n)"
    prev=$n
done
# Once per start: lines each of these oneshots writes exactly once a run.
# (align-device-groups runs again before every audio start, S2.4.6.)
for once in '^xorg-gpu-conf: decision:' '^xorg-monitor-conf: ' '^host-shell-setup: host shell configured' '^tools published to '; do
    c=$(grep -c -e "$once" <<<"$boot_log" || true)
    [ "$c" = 1 ] || fail "'$once' appears $c time(s) in the first boot's log, want once"
done
ev_pass "each ran once: the GPU decision, the monitor generator's line, 'host shell configured' and 'tools published to' appear exactly once"
ev_end

log "boot markers: the pid file names desktop-init on the host; the ready marker predates the first Xorg"
ev_begin S2.1.3 "Boot markers" T2
initpid=$(ev_save pid-file "EV-STATE: cat /run/desktop-init.pid in the container" \
    podman exec desktop cat /run/desktop-init.pid) || fail "no /run/desktop-init.pid in the container"
comm=$(ev_save host-comm "EV-STATE: on the host, cat /proc/<that pid>/comm" cat "/proc/$initpid/comm") \
    || fail "pid $initpid from the pid file is not a host process"
[ "$comm" = desktop-init ] || fail "host pid $initpid is '$comm', not desktop-init"
ev_pass "the pid file holds $initpid, which on the host is desktop-init"
exits=$(grep -c '^desktop-init: session exited' <<<"$boot_log" || true)
[ "$exits" = 0 ] || fail "the X session already ended $exits time(s) this boot: the running Xorg is not the first"
xpid=$(first_xorg)
[ -n "$xpid" ] || fail "no Xorg running"
ev_save marker "EV-STATE: ls -l --full-time /run/desktop-init-ready in the container" \
    podman exec desktop ls -l --full-time /run/desktop-init-ready >/dev/null || fail "no ready marker"
ev_save first-xorg "EV-PIDS: this boot's first Xorg (no session has exited yet), as the host sees it" \
    ps -o pid,user,lstart,args -p "$xpid" >/dev/null || true
ready=$(podman exec desktop date -r /run/desktop-init-ready +%s.%N)
# The process's start in wall-clock time: the boot instant (the realtime
# clock less CLOCK_BOOTTIME, to the microsecond) plus its start ticks. The
# kernel floors those ticks, so the real start is at or after this figure,
# and a marker older than it is older than the process.
xstart=$(python3 -c '
import os, sys, time
st = open("/proc/%s/stat" % sys.argv[1]).read()
ticks = int(st[st.rindex(")") + 2:].split()[19])
boot = time.time() - time.clock_gettime(time.CLOCK_BOOTTIME)
print("%.6f" % (boot + ticks / os.sysconf("SC_CLK_TCK")))' "$xpid")
gap=$(python3 -c 'import sys; print("%.3f" % (float(sys.argv[2]) - float(sys.argv[1])))' "$ready" "$xstart")
ev_note "ready marker mtime $ready; Xorg (pid $xpid) started at or after $xstart (boot instant plus its start ticks, floored to 10 ms): $gap s later"
python3 -c 'import sys; sys.exit(0 if float(sys.argv[1]) > 0 else 1)' "$gap" \
    || fail "the ready marker ($ready) is not older than the first Xorg ($xstart)"
ev_pass "the ready marker was written $gap s before the first Xorg started"
ev_end

log "audio tree: its own session, no controlling tty, the session user, under supervise_audio"
ev_begin S2.4.1 "The audio tree is its own session with its own supervisor" T2
leader=$(ev_save leader-file "EV-STATE: cat /run/desktop-audio-leader.pid in the container" \
    podman exec desktop cat /run/desktop-audio-leader.pid) || fail "no /run/desktop-audio-leader.pid"
ev_save tree "EV-PIDS: the audio tree on the host (ps -s <leader>): pid, ppid, session, tty, user" \
    ps -o pid,ppid,sess,tty,user,lstart,comm -s "$leader" >/dev/null || fail "no process in session $leader"
pw=$(podman exec desktop pgrep -x pipewire 2>/dev/null || true)
pw=$(head -n 1 <<<"$pw")
[ -n "$pw" ] || fail "no pipewire running"
read -r sid tty uid <<<"$(ps -o sess=,tty=,uid= -p "$pw")"
[ "$sid" = "$leader" ] || fail "pipewire (pid $pw) is in session $sid, not the recorded leader's ($leader)"
ev_pass "pipewire (pid $pw) is in session $leader, the leader the pid file records"
[ "$tty" = "?" ] || fail "pipewire has controlling tty '$tty', want none"
ev_pass "it has no controlling tty (ps: '?')"
[ "$uid" = 61000 ] || fail "pipewire runs as uid $uid, want 61000"
ev_pass "it runs as uid 61000"
sup=$(ps -o ppid= -p "$leader" | tr -d ' ')
supparent=$(ps -o ppid= -p "$sup" | tr -d ' ')
ev_save supervisor "EV-PIDS: the leader's parent and its parent" \
    ps -o pid,ppid,sess,user,args -p "$sup,$supparent" >/dev/null || true
[ "$sup" != "$initpid" ] && [ "$supparent" = "$initpid" ] \
    || fail "the audio leader's parent ($sup) is not a child of desktop-init ($initpid); its parent is $supparent"
ev_pass "the leader's parent (pid $sup) is supervise_audio, a child of desktop-init (pid $initpid)"
ev_end

log "X session restart: tty1 is handed back to the session user"
ev_begin S2.2.3 "tty1 is handed to the session user" T2
own=$(ev_save tty1-before "EV-STATE: stat -c '%U:%G %a %n' /dev/tty1 in the container, before an X session restart" \
    podman exec desktop stat -c '%U:%G %a %n' /dev/tty1) || fail "no /dev/tty1 in the container"
[ "${own%% *}" = desktop:tty ] || fail "/dev/tty1 is ${own%% *} before the restart, want desktop:tty"
ev_pass "before: /dev/tty1 is desktop:tty"
# SIGKILL, mwm dying: a SIGTERM only opens mwm's "Quit Mwm?" confirmation
# (its default showFeedback includes kill), and the session stays up - the
# first run of this check waited 60 s for a restart that never came.
podman exec -u desktop desktop pkill -KILL -u desktop -x mwm || fail "could not end the X session: no mwm to kill"
ev_note "ended the X session by killing mwm, its client, with SIGKILL as the session user (Xorg was pid $xpid)"
x_restarted() { local p; p=$(first_xorg); [ -n "$p" ] && [ "$p" != "$xpid" ] && x_up; }
ok=0
for _ in $(seq 30); do x_restarted && { ok=1; break; }; sleep 2; done
[ "$ok" = 1 ] || fail "no new X session within 60 s of killing mwm"
own=$(ev_save tty1-after "EV-STATE: the same stat once the X session restarted" \
    podman exec desktop stat -c '%U:%G %a %n' /dev/tty1) || fail "no /dev/tty1 after the restart"
[ "${own%% *}" = desktop:tty ] || fail "/dev/tty1 is ${own%% *} after the restart, want desktop:tty"
ev_pass "after the X session restarted (Xorg $xpid -> $(first_xorg)): /dev/tty1 is still desktop:tty"
ev_end

log "mwm killed with a plain kill (SIGTERM): the session ends and a new one starts"
ev_begin S2.3.6 "mwm exit ends the session and it restarts" T2
x_term_before=$(first_xorg)
since_term=$(date -u +%Y-%m-%dT%H:%M:%SZ)
sleep 1
ev_save pids-before "EV-PIDS: desktop-init, Xorg and mwm before mwm gets a SIGTERM" \
    sh -c "ps -o pid,user,lstart,comm -p $initpid; podman exec desktop ps -o pid,user,lstart,comm -C Xorg,mwm" >/dev/null || true
podman exec -u desktop desktop pkill -TERM -u desktop -x mwm || fail "no mwm to send SIGTERM to"
ev_note "sent mwm SIGTERM, a plain kill's signal, as the session user (Xorg was pid $x_term_before)"
term_restarted() { local p; p=$(first_xorg); [ -n "$p" ] && [ "$p" != "$x_term_before" ] && x_up; }
ok=0
for _ in $(seq 20); do term_restarted && { ok=1; break; }; sleep 1; done
[ "$ok" = 1 ] || fail "a SIGTERM to mwm did not end the session within 20 s (mwm asking 'Quit Mwm?' instead?)"
ev_save pids-after "EV-PIDS: the same after the session restarted: new Xorg and mwm, the same desktop-init" \
    sh -c "ps -o pid,user,lstart,comm -p $initpid; podman exec desktop ps -o pid,user,lstart,comm -C Xorg,mwm" >/dev/null || true
ev_pass "a SIGTERM to mwm ended the session: Xorg $x_term_before -> $(first_xorg), a new mwm, and the display answers"
[ -d "/proc/$initpid" ] || fail "desktop-init (pid $initpid) did not survive the session's end"
ev_pass "desktop-init carried on (pid $initpid)"
term_log=$(podman logs --since "$since_term" desktop 2>/dev/null | tr -d '\r' || true)
ev_text log "EV-LOG-DESKTOP: the desktop's log from just before the SIGTERM: the session's clean end and the new session" "$term_log"
grep -q '^desktop-init: session exited (rc=0)' <<<"$term_log" || fail "desktop-init did not log the session's end"
if grep -q '^postmortem:' <<<"$term_log"; then fail "a postmortem ran for mwm's clean exit"; fi
ev_pass "desktop-init logged 'session exited (rc=0)' and ran no postmortem: a clean end"
ev_end

log "session-leader check: silent through the boot and a restart of each tree"
ev_begin S2.3.4 "Session leader sanity check never fires in a normal boot" T2
now_log=$(desktop_log)
ev_text log "EV-LOG-DESKTOP: the desktop's log after its boot, the audio stack's restart (pipewire killed above) and the X session's (mwm killed above)" "$now_log"
a=$(grep -c '^desktop-init: audio stack exited' <<<"$now_log" || true)
x=$(grep -c '^desktop-init: session exited' <<<"$now_log" || true)
[ "$a" -ge 1 ] && [ "$x" -ge 1 ] || fail "the log does not show both trees restarting (audio stack exits: $a, X session exits: $x)"
ev_pass "the log covers a restart of each tree (audio stack exits: $a, X session exits: $x)"
warn=$(grep 'is not its own session leader' <<<"$now_log" || true)
ev_text grep "grep 'is not its own session leader' over that log" "${warn:-(no match)}"
[ -z "$warn" ] || fail "the session-leader warning fired: $warn"
ev_pass "the session-leader warning never fired"
ev_end

log "/run and /tmp: tmpfs in this container; a sentinel in each, looked for after the restart below"
ev_begin S2.1.4 "/run and /tmp are fresh per container start" T2
m=$(ev_save mounts-first "EV-STATE: the /run and /tmp lines of /proc/self/mounts in the container (first start)" \
    podman exec desktop sh -c 'grep -E "^[^ ]+ /(run|tmp) " /proc/self/mounts') || fail "no /run or /tmp line in the container's mount table"
for d in /run /tmp; do
    awk -v d="$d" '$2==d && $3=="tmpfs"{f=1} END{exit !f}' <<<"$m" || fail "$d is not a tmpfs in the container"
done
ev_pass "first start: /run and /tmp are tmpfs"
podman exec desktop touch /run/ev-sentinel /tmp/ev-sentinel || fail "could not write the sentinels"
ev_save sentinels-first "EV-STATE: ls -l of a sentinel written in /run and in /tmp" \
    podman exec desktop ls -l /run/ev-sentinel /tmp/ev-sentinel >/dev/null || fail "the sentinels are not there"
sentinels_first=$EV_LAST
ev_end

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

# Before the restart below: what it should change, recorded.
log "before the restart: unit start times, the published toolkit, the host-shell key"
ev_begin S5.8.2 "Moves with the container" T2
ev_save started-before "EV-STATE: ActiveEnterTimestamp of desktop.service and desktop-session.service before the restart" \
    systemctl show -p Id -p ActiveEnterTimestamp desktop.service desktop-session.service >/dev/null || true
started_before=$EV_LAST
t_desk=$(systemctl show -p ActiveEnterTimestampMonotonic --value desktop.service)
t_sess=$(systemctl show -p ActiveEnterTimestampMonotonic --value desktop-session.service)
since_restart=$(date '+%Y-%m-%d %H:%M:%S')
ev_end

ev_begin S7.2.1 "Published at boot, 0755, by rename" T2
ev_save bin-before "EV-STATE: ls -li and sha256sum of the published toolkit before the restart" \
    sh -c 'ls -lia /var/lib/desktop-container/bin; sha256sum /var/lib/desktop-container/bin/screenshot' >/dev/null || true
bin_before=$EV_LAST
ino_tool=$(stat -c %i /var/lib/desktop-container/bin/screenshot)
ev_end

ev_begin S7.2.2 "Stale tools are pruned, dotfiles left alone" T2
printf 'not shipped by this image\n' > /var/lib/desktop-container/bin/stale-tool
printf 'a dotfile\n' > /var/lib/desktop-container/bin/.keep
ev_save bin-planted "EV-STATE: ls -la of the toolkit dir with an unshipped file and a dotfile planted" \
    ls -la /var/lib/desktop-container/bin >/dev/null || true
planted=$EV_LAST
ev_end

# S7.2.3: watch the directory across the republish. apt only if needed.
command -v inotifywait >/dev/null || { apt-get update -q >/dev/null && apt-get install -y -q inotify-tools >/dev/null; } \
    || fail "could not install inotify-tools for the republish watch"
watch_dir=/var/lib/desktop-container/bin
initial=$(ls -A "$watch_dir")
# Line-buffered, so stopping it loses no event.
stdbuf -oL inotifywait -m -q -e create,delete,moved_to,moved_from --format '%e %f' "$watch_dir" > /tmp/ev-inotify.log 2>&1 &
watcher=$!
sleep 1

ev_begin S5.7.4 "Re-running rotates the key and invalidates the old one" T2
cp /etc/desktop-container/host-shell-key /tmp/ev-old-key
chmod 600 /tmp/ev-old-key
fp_old=$(ssh-keygen -lf /etc/desktop-container/host-shell-key.pub | awk '{print $2}')
ev_save key-old "EV-STATE: ssh-keygen -lf of the host-shell public key in use" \
    ssh-keygen -lf /etc/desktop-container/host-shell-key.pub >/dev/null || fail "no host-shell public key"
key_old=$EV_LAST
systemctl restart desktop-host-shell.service || fail "a second run of desktop-host-shell.service failed"
ev_save key-new "EV-STATE: ssh-keygen -lf of the public key after a second run" \
    ssh-keygen -lf /etc/desktop-container/host-shell-key.pub >/dev/null || fail "no public key after the second run"
ev_diff key "EV-DIFF: the public key's fingerprint before and after the second run" "$key_old" "$EV_LAST"
fp_new=$(ssh-keygen -lf /etc/desktop-container/host-shell-key.pub | awk '{print $2}')
[ -n "$fp_new" ] && [ "$fp_new" != "$fp_old" ] || fail "the second run kept the same key ($fp_old)"
ev_pass "a second run writes a different key ($fp_old -> $fp_new)"
sshopt=(-o BatchMode=yes -o ConnectTimeout=5 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null)
if ev_save old-key-ssh "the old private key against sshd: refused" \
        ssh "${sshopt[@]}" -i /tmp/ev-old-key desktop-shell@127.0.0.1 whoami >/dev/null; then
    fail "the old key still logs in after the rotation"
fi
ev_pass "the old private key no longer authenticates"
who=$(ev_save new-key-ssh "the new private key: whoami" \
    ssh "${sshopt[@]}" -i /etc/desktop-container/host-shell-key desktop-shell@127.0.0.1 whoami) || fail "the new key does not log in"
[ "$(tail -n 1 <<<"$who")" = desktop-shell ] || fail "the new key logged in as '$who'"
ev_pass "the new private key logs in as desktop-shell"
if ev_save container-before "the container's ssh host before desktop.service restarts: it still holds the old key" \
        podman exec -u desktop -e HOME=/home/desktop desktop ssh -o ConnectTimeout=5 -o BatchMode=yes host whoami >/dev/null; then
    fail "the container still logs in with its copy of the old key"
fi
ev_pass "until desktop.service restarts the container, holding the old key, is refused"
rm -f /tmp/ev-old-key
ev_end

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

ev_begin S2.1.4 "/run and /tmp are fresh per container start" T2
m=$(ev_save mounts-restarted "EV-STATE: the same mount lines after systemctl restart desktop.service" \
    podman exec desktop sh -c 'grep -E "^[^ ]+ /(run|tmp) " /proc/self/mounts') || fail "no /run or /tmp line after the restart"
for d in /run /tmp; do
    awk -v d="$d" '$2==d && $3=="tmpfs"{f=1} END{exit !f}' <<<"$m" || fail "$d is not a tmpfs after the restart"
done
ev_pass "after the restart: /run and /tmp are tmpfs again"
ev_save sentinels-restarted "EV-STATE: ls -l of the two sentinels after the restart: gone" \
    podman exec desktop sh -c 'ls -l /run/ev-sentinel /tmp/ev-sentinel 2>&1; true' >/dev/null
ev_diff sentinels "EV-DIFF: the sentinels before and after the restart" "$sentinels_first" "$EV_LAST"
if podman exec desktop sh -c 'test -e /run/ev-sentinel || test -e /tmp/ev-sentinel'; then
    fail "a sentinel survived the restart"
fi
ev_pass "neither sentinel survived the restart"
ev_end

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

# After the restart above: what it changed.
log "after the restart: both units moved, the toolkit republished, the container's key renewed"
ev_begin S5.8.2 "Moves with the container" T2
ev_save started-after "EV-STATE: ActiveEnterTimestamp of the two units after systemctl restart desktop.service" \
    systemctl show -p Id -p ActiveEnterTimestamp desktop.service desktop-session.service >/dev/null || true
ev_diff started "EV-DIFF: the two units' ActiveEnterTimestamp before and after: both moved" "$started_before" "$EV_LAST"
[ "$(systemctl show -p ActiveEnterTimestampMonotonic --value desktop.service)" -gt "$t_desk" ] \
    || fail "desktop.service did not restart"
[ "$(systemctl show -p ActiveEnterTimestampMonotonic --value desktop-session.service)" -gt "$t_sess" ] \
    || fail "desktop-session.service did not restart with desktop.service (PartOf= lost?)"
ev_pass "restarting desktop.service restarted desktop-session.service too: both start times moved"
ev_save journal "EV-LOG-JOURNAL: desktop-session.service's journal since the restart: stopped and started with the container" \
    journalctl -u desktop-session.service --since "$since_restart" --no-pager -o short-iso >/dev/null || true
ev_end

ev_begin S7.2.1 "Published at boot, 0755, by rename" T2
ev_save bin-after "EV-STATE: ls -li and sha256sum of the published toolkit after the restart" \
    sh -c 'ls -lia /var/lib/desktop-container/bin; sha256sum /var/lib/desktop-container/bin/screenshot' >/dev/null || true
ev_diff bin "EV-DIFF: the toolkit dir before and after the restart's republish" "$bin_before" "$EV_LAST"
[ "$(stat -c %a /var/lib/desktop-container/bin/screenshot)" = 755 ] || fail "the republished screenshot is not 0755"
ev_pass "the republished screenshot is 0755"
[ "$(stat -c %i /var/lib/desktop-container/bin/screenshot)" != "$ino_tool" ] || fail "the republish wrote the old file in place"
ev_pass "it is a new inode ($ino_tool -> $(stat -c %i /var/lib/desktop-container/bin/screenshot)): copied to a temp file and renamed over"
left=$(find /var/lib/desktop-container/bin -maxdepth 1 -name '.screenshot.*')
[ -z "$left" ] || fail "temp files left by the republish: $left"
ev_pass "no temp file is left"
ev_end

ev_begin S7.2.2 "Stale tools are pruned, dotfiles left alone" T2
ev_save bin-pruned "EV-STATE: ls -la of the toolkit dir after the restart" ls -la /var/lib/desktop-container/bin >/dev/null || true
ev_diff bin "EV-DIFF: the toolkit dir with the planted files, then after the republish" "$planted" "$EV_LAST"
[ ! -e /var/lib/desktop-container/bin/stale-tool ] || fail "the unshipped stale-tool survived the republish"
ev_pass "the unshipped regular file is gone"
[ -e /var/lib/desktop-container/bin/.keep ] || fail "the dotfile was removed"
ev_pass "the dotfile is left alone"
pr=$(desktop_log | grep '^pruned ' || true)
ev_text log "EV-LOG-DESKTOP: publish-tools' 'pruned' lines in the desktop's log" "${pr:-(none)}"
grep -qx 'pruned stale-tool (no longer shipped by this image)' <<<"$pr" || fail "no 'pruned stale-tool' line"
ev_pass "publish-tools logged 'pruned stale-tool (no longer shipped by this image)'"
rm -f /var/lib/desktop-container/bin/.keep
ev_end

ev_begin S7.2.3 "The directory is never emptied during a republish" T2
sleep 1
kill "$watcher" 2>/dev/null || true
wait "$watcher" 2>/dev/null || true
ev_text initial "EV-STATE: ls -A of the toolkit dir when the watch began" "$initial"
ev_copy /tmp/ev-inotify.log inotify "EV-STATE: the inotifywait -m transcript across the restart (event, name)"
replay=$(python3 -c '
import sys
entries = set(sys.argv[1].split())
low = len([e for e in entries if not e.startswith(".")])
for line in open(sys.argv[2]):
    ev, _, name = line.strip().partition(" ")
    if not name:
        continue
    if "CREATE" in ev or "MOVED_TO" in ev:
        entries.add(name)
    elif "DELETE" in ev or "MOVED_FROM" in ev:
        entries.discard(name)
    low = min(low, len([e for e in entries if not e.startswith(".")]))
print(low)' "$initial" /tmp/ev-inotify.log)
events=$(grep -c . /tmp/ev-inotify.log || true)
[ "$events" -gt 0 ] || fail "the watch saw no events: the republish did not happen in the watched directory"
ev_note "replayed $events events from the starting listing; the fewest non-dot entries at any point: $replay"
[ "$replay" -ge 1 ] || fail "at some point during the republish the toolkit directory held no tool"
ev_pass "across the republish the directory always held at least one tool ($replay at its lowest)"
rm -f /tmp/ev-inotify.log
ev_end

ev_begin S5.7.4 "Re-running rotates the key and invalidates the old one" T2
cwho=$(ev_save container-after "the container's ssh host after desktop.service restarted: the new key" \
    podman exec -u desktop -e HOME=/home/desktop desktop ssh -o ConnectTimeout=5 -o BatchMode=yes host whoami) \
    || fail "the container could not ssh to the host after the restart"
[ "$(tail -n 1 <<<"$cwho")" = desktop-shell ] || fail "the container's ssh host answered '$cwho'"
ev_pass "after desktop.service restarted, the container logs in again (whoami: desktop-shell)"
ev_end

# --- a scratch desktop container: no host mounts, no host session, no VT ------
# Plain `podman run` of the image with none of the quadlet's mounts or
# devices: desktop-init's fallbacks are all that stands between it and a
# working audio export, and its X session cannot start at all.
log "scratch desktop container: no host mounts, no host session, no VT"
podman run -d --name ev-scratch --network=none localhost/desktop-container:latest >/dev/null \
    || fail "a scratch container of the image did not start"
ok=0
for _ in $(seq 45); do
    if podman exec ev-scratch test -S /run/desktop-audio/pulse 2>/dev/null \
        && [ "$(podman logs ev-scratch 2>/dev/null | grep -c 'session exited' || true)" -ge 1 ]; then
        ok=1; break
    fi
    sleep 2
done
scratch_log=$(podman logs ev-scratch 2>/dev/null | tr -d '\r' || true)
[ "$ok" = 1 ] || { tail -n 40 <<<"$scratch_log" >&2
                   fail "within 90 s the scratch container exported no pulse socket, or never tried its X session"; }

ev_begin S2.2.4 "Audio export dir exists even without the host mount" T2
ev_save mounts "EV-STATE: the scratch container's mount table at /run/desktop-audio: no entry, the dir is not a mount" \
    podman exec ev-scratch sh -c 'grep " /run/desktop-audio " /proc/self/mounts || echo "(no mount at /run/desktop-audio)"' >/dev/null || true
if podman exec ev-scratch grep -q ' /run/desktop-audio ' /proc/self/mounts; then
    fail "/run/desktop-audio is a mount in the scratch container"
fi
ev_pass "nothing is mounted at /run/desktop-audio in the scratch container"
d=$(ev_save dir "EV-STATE: ls -ld /run/desktop-audio in the scratch container" \
    podman exec ev-scratch ls -ld /run/desktop-audio) || fail "no /run/desktop-audio in the scratch container"
grep -q '^drwxrwxrwt' <<<"$d" || fail "/run/desktop-audio is not 1777: $d"
ev_pass "desktop-init created it, mode 1777 (drwxrwxrwt)"
socks=$(ev_save sockets "EV-STATE: ls -l /run/desktop-audio in the scratch container" \
    podman exec ev-scratch ls -l /run/desktop-audio) || fail "could not list /run/desktop-audio"
for k in pipewire-0 pulse; do
    grep -qE "^s.* $k\$" <<<"$socks" || fail "no $k socket in the scratch container's /run/desktop-audio"
done
ev_pass "PipeWire's sockets appear in it: pipewire-0 and pulse"
ev_end

ev_begin S2.2.2 "Standalone fallback fabricates the runtime dir" T2
fb=$(grep 'no host login session appeared; creating' <<<"$scratch_log" || true)
ev_text fallback-scratch "EV-LOG-DESKTOP: the scratch container's fallback line (a plain podman run: no host login session at all)" "${fb:-(none)}"
[ -n "$fb" ] || fail "the scratch container did not log the standalone fallback"
ev_pass "plain podman run: desktop-init logs the standalone fallback"
st=$(ev_save stat-scratch "EV-STATE: stat of /run/user/61000 in the scratch container" \
    podman exec ev-scratch stat -c '%A %U:%G %n' /run/user/61000) || fail "no /run/user/61000 in the scratch container"
[ "${st%% /*}" = "drwx------ desktop:desktop" ] || fail "/run/user/61000 is '$st', want drwx------ desktop:desktop"
ev_pass "and makes /run/user/61000 itself: drwx------ desktop:desktop"
ev_end

ev_begin S3.7.3 "Loss of --pid=host is detected at boot" T2
pf=$(grep '^preflight: ' <<<"$scratch_log" || true)
ev_text preflight "EV-LOG-DESKTOP: the preflight block of the scratch container, run without --pid=host" "${pf:-(none)}"
grep -q '^preflight: FAIL: container init is PID 1' <<<"$pf" || fail "the preflight did not report init as PID 1 without --pid=host"
ev_pass "without --pid=host the preflight reports 'FAIL: container init is PID 1'"
ev_end

ev_begin S2.1.3 "Boot markers" T2
n=$(grep -c '^desktop-init: session exited' <<<"$scratch_log" || true)
ev_text scratch-log "EV-LOG-DESKTOP: the scratch container's log: its X session cannot start (no tty1, no DRM) and keeps failing" "$scratch_log"
ev_save scratch-marker "EV-STATE: ls -l --full-time /run/desktop-init-ready in the scratch container" \
    podman exec ev-scratch ls -l --full-time /run/desktop-init-ready >/dev/null \
    || fail "the scratch container, whose X session cannot start, wrote no ready marker"
ev_pass "with its X session failing ($n session exits logged), the scratch container still wrote the ready marker"
ev_end
podman rm -f ev-scratch >/dev/null

# --- a failing oneshot, then a stop and a start --------------------------------
log "a failing oneshot never blocks the session: an image with no tools to publish"
ev_begin S2.1.2 "A failing oneshot never blocks the session" T2
orig_img=$(podman image inspect --format '{{.Id}}' localhost/desktop-container:latest)
ctx=$(mktemp -d)
printf 'FROM localhost/desktop-container:latest\nRUN rm -f /usr/libexec/desktop-tools/*\n' > "$ctx/Containerfile"
ev_save build "EV-STATE: localhost/desktop-container:latest rebuilt for this check with /usr/libexec/desktop-tools emptied (the original, $orig_img, is tagged back after)" \
    podman build --no-cache --network=none --pull=never -t localhost/desktop-container:latest "$ctx" >/dev/null \
    || fail "could not build the image with no tools"
rm -r "$ctx"
no_tools_img=$(podman image inspect --format '{{.Id}}' localhost/desktop-container:latest)
systemctl restart desktop.service
wait_xorg_conf
wait_x_up "with publish-tools failing"
pt_log=$(desktop_log)
ev_text log "EV-LOG-DESKTOP: this start's log: publish-tools' ERROR, then 'oneshots done', then the X server starting" "$pt_log"
n_err=$(line_in "$pt_log" '^desktop-init: ERROR: publish-tools failed')
n_done=$(line_in "$pt_log" '^desktop-init: oneshots done')
n_x=$(line_in "$pt_log" '^X.Org X Server')
[ -n "$n_err" ] || fail "no 'ERROR: publish-tools failed' line"
ev_pass "desktop-init logged 'ERROR: publish-tools failed' (line $n_err)"
[ -n "$n_done" ] && [ "$n_done" -gt "$n_err" ] || fail "'oneshots done' does not follow the ERROR line"
[ -n "$n_x" ] && [ "$n_x" -gt "$n_done" ] || fail "the X server did not start after 'oneshots done'"
ev_pass "then 'oneshots done' (line $n_done), then the X server starting (line $n_x)"
ev_save staged "EV-STATE: ls -la /usr/libexec/desktop-tools in this container: nothing to publish" \
    podman exec desktop ls -la /usr/libexec/desktop-tools >/dev/null || true
ev_save ready "EV-STATE: ls -l /run/desktop-init-ready in this container" \
    podman exec desktop ls -l /run/desktop-init-ready >/dev/null || fail "no ready marker with publish-tools failing"
ev_pass "the ready marker is written"
ev_save pids "EV-PIDS: the X session with publish-tools failed: Xorg, mwm, xterm" \
    podman exec desktop ps -o pid,user,lstart,comm -C Xorg,mwm,xterm >/dev/null || fail "no X session processes"
ev_pass "and the session is alive: Xorg, mwm and xterm running, xdpyinfo answering"
ev_end
podman tag "$orig_img" localhost/desktop-container:latest

log "stop and start: SIGTERM stops both trees; the X socket goes with the server"
ev_begin S2.5.2 "The X socket is unlinked by the server, not pinned by a mount" T2
ev_save x11-running "EV-STATE: ls -li /tmp/.X11-unix on the host, the desktop running" ls -li /tmp/.X11-unix >/dev/null || true
x11_running=$EV_LAST
[ -S /tmp/.X11-unix/X0 ] || fail "no X0 socket on the host while the desktop runs"
ino_before=$(stat -c %i /tmp/.X11-unix/X0)
ev_pass "running: /tmp/.X11-unix/X0 is a socket (inode $ino_before)"
ev_end

ev_begin S2.5.1 "SIGTERM stops both trees cleanly" T2
tmp=$(mktemp -d)
podman wait desktop > "$tmp/wait" 2>&1 &
waiter=$!
# The log is followed through its k8s-file, by descriptor, rather than with
# `podman logs -f`, which ends when the container does (with --rm, at once):
# in one run its output lacked desktop-init's "SIGTERM:" line, written just
# before the exit. An open descriptor reads everything written before the
# file was removed. Each line is "<time> stdout|stderr F|P <text>".
ctr_log=$(podman inspect desktop --format '{{.HostConfig.LogConfig.Path}}' 2>/dev/null || true)
[ -n "$ctr_log" ] && [ -f "$ctr_log" ] || fail "the container's k8s-file log is not at '$ctr_log'"
tail -n +1 -f "$ctr_log" > "$tmp/follow" 2>&1 &
follower=$!
sleep 1
ev_save pids-before "EV-PIDS: every uid-61000 process on the host before the stop" \
    ps -o pid,ppid,sess,tty,lstart,comm -u 61000 >/dev/null || true
stop_epoch=$(date +%s)
stop_t0=$(date +%s.%N)
# Which processes outlive the SIGTERM, and for how long: desktop-init gives
# each tree 5 s before it KILLs what is left.
( for _ in $(seq 24); do
      echo "-- $(date +%s.%N | cut -c1-14) $(date +%T.%N | cut -c1-12)"
      ps -o pid,ppid,stat,comm -u 61000 --no-headers 2>/dev/null || true
      sleep 0.5
  done ) > "$tmp/samples" 2>&1 &
sampler=$!
took=$(ev_save stop "EV-STATE: time systemctl stop desktop.service (podman's stop timeout, after which it would SIGKILL, is 10 s)" \
    bash -c 'TIMEFORMAT="took %R s"; time systemctl stop desktop.service') || fail "systemctl stop desktop.service failed"
took=$(sed -n 's/^took \([0-9.]*\) s$/\1/p' <<<"$took")
python3 -c 'import sys; sys.exit(0 if float(sys.argv[1]) < 10 else 1)' "${took:-99}" \
    || fail "systemctl stop desktop.service took ${took:-?} s: not within podman's 10 s stop timeout"
ev_pass "systemctl stop desktop.service returned in $took s, within the 10 s stop timeout"
for _ in $(seq 20); do kill -0 "$waiter" 2>/dev/null || break; sleep 0.5; done
kill "$waiter" 2>/dev/null || true
wait_out=$(cat "$tmp/wait")
ev_text podman-wait "EV-STATE: what 'podman wait desktop', started before the stop, printed: the container's exit code" "${wait_out:-(nothing)}"
[ "$(tail -n 1 <<<"$wait_out")" = 0 ] || fail "podman wait printed '$wait_out', want exit code 0"
ev_pass "podman wait, started before the stop, reports exit code 0"
wait "$sampler" 2>/dev/null || true
ev_copy "$tmp/samples" during-stop "EV-PIDS: every uid-61000 process on the host, sampled every 0.5 s from just before the stop (what outlives the SIGTERM, and for how long)"
# The last sample any process of the two trees appears in, in seconds after
# the stop began.
last=$(awk -v t0="$stop_t0" '
    /^-- / { t = $2 - t0; next }
    $4 ~ /^(Xorg|mwm|xterm|pipewire|wireplumber|pipewire-pulse|start-audio|startx|xinit)$/ { if (t > last) last = t }
    END { printf "%.1f", last }' "$tmp/samples")
ev_note "the last sample showing any process of the two trees came $last s after the stop began"
python3 -c 'import sys; sys.exit(0 if float(sys.argv[1]) < 4.0 else 1)' "$last" \
    || fail "a process of the trees was still there $last s into the stop: it waited for desktop-init's KILL at 5 s"
ev_pass "every process of both trees was gone within $last s: none waited for desktop-init's KILL at 5 s"
ev_save unit "EV-STATE: systemctl show of desktop.service after the stop" \
    systemctl show -p Result,ExecMainCode,ExecMainStatus,ActiveState desktop.service >/dev/null || true
ev_save pids-after "EV-PIDS: every uid-61000 process on the host after the stop" \
    sh -c 'ps -o pid,ppid,sess,tty,lstart,comm -u 61000 || echo "(no uid-61000 process left)"' >/dev/null || true
left=$(pgrep -l -u 61000 -x 'Xorg|mwm|xterm|pipewire|wireplumber|pipewire-pulse' || true)
[ -z "$left" ] || fail "processes of the desktop's two trees outlived the stop: $left"
ev_pass "no Xorg, mwm, xterm, pipewire, wireplumber or pipewire-pulse is left on the host"
sleep 1
kill "$follower" 2>/dev/null || true
follow=$(sed -E 's/^[^ ]+ (stdout|stderr) [FP] //' "$tmp/follow" | tr -d '\r')
rm -r "$tmp"
n_term=$(line_in "$follow" '^desktop-init: SIGTERM:')
[ -n "$n_term" ] || { ev_text follow "EV-LOG-DESKTOP: the desktop's log, followed from before the stop" "$follow"
                      fail "desktop-init logged no 'SIGTERM:' line on the stop"; }
after_term=$(sed -n "${n_term},\$p" <<<"$follow")
ev_text follow-tail "EV-LOG-DESKTOP: the desktop's log, followed (its k8s-file, by descriptor) from before the stop, from desktop-init's 'SIGTERM:' line to the end" "$after_term"
if grep -q 'restarting in 3s' <<<"$after_term"; then
    fail "a tree restarted during the shutdown: $(grep 'restarting in 3s' <<<"$after_term")"
fi
ev_pass "after 'SIGTERM:' nothing logs 'restarting in 3s': neither tree came back during the shutdown"
ev_end

ev_begin S2.5.2 "The X socket is unlinked by the server, not pinned by a mount" T2
ev_save x11-stopped "EV-STATE: ls -li /tmp/.X11-unix after the stop" ls -li /tmp/.X11-unix >/dev/null || true
if [ -e /tmp/.X11-unix/X0 ]; then
    x0_gone=0
    lst=$(ss -xlH 2>/dev/null | grep -F '/tmp/.X11-unix/X0' || true)
    [ -z "$lst" ] || fail "X0 is still served after the stop: $lst"
    ev_pass "after the stop X0 is a dead file: nothing listens on it"
else
    x0_gone=1
    ev_pass "after the stop /tmp/.X11-unix/X0 is gone"
fi
ev_end
podman rmi "$no_tools_img" >/dev/null 2>&1 || true

systemctl start desktop.service
wait_xorg_conf
wait_x_up "after the stop and start"
ev_begin S2.5.2 "The X socket is unlinked by the server, not pinned by a mount" T2
ev_save x11-started "EV-STATE: ls -li /tmp/.X11-unix after the next start" ls -li /tmp/.X11-unix >/dev/null || true
[ -S /tmp/.X11-unix/X0 ] || fail "no X0 socket after the start"
ev_diff x11 "EV-DIFF: /tmp/.X11-unix with the desktop running, then after the stop and the next start" "$x11_running" "$EV_LAST"
# Not the inode number: this runner's /tmp is ext4, which hands a freed
# number to the next file made, so a new X0 can carry the old one's
# (the first run of this check saw exactly that, 533211 both times).
born=$(stat -c %W /tmp/.X11-unix/X0)
ev_note "X0 after the start: inode $(stat -c %i /tmp/.X11-unix/X0) (was $ino_before), born $born (epoch s; 0 if the filesystem does not say); the stop began at $stop_epoch"
if [ "$x0_gone" = 1 ]; then
    ev_pass "the next start made X0 anew: the stop left none, so this one is the new server's"
elif [ "$born" -ge "$stop_epoch" ]; then
    ev_pass "the next start replaced the dead X0: this one was born at or after the stop"
else
    fail "X0 after the start predates the stop (born $born, stop at $stop_epoch): the server did not make a fresh socket"
fi
ev_save xdpyinfo "EV-STATE: xdpyinfo on :0 in the container after the start" \
    podman exec -u desktop -e DISPLAY=:0 desktop xdpyinfo >/dev/null || fail "xdpyinfo failed after the start"
ev_pass "xdpyinfo answers on it"
ev_end

ev_begin S2.3.4 "Session leader sanity check never fires in a normal boot" T2
restart_log=$(desktop_log)
ev_text log-restarted "EV-LOG-DESKTOP: the log of the desktop's start after the stop" "$restart_log"
warn=$(grep 'is not its own session leader' <<<"$restart_log" || true)
[ -z "$warn" ] || fail "the session-leader warning fired after the restart: $warn"
ev_pass "and none in the start after desktop.service was stopped and started"
ev_end

log "deploy smoke passed"
