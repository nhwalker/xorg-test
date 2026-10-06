#!/bin/bash
# T1 tier: host and image scripts driven on the CI runner without the image,
# a VM or the network - through their test overrides (Requirements.md,
# Appendix A) and fakes put first on PATH. Production defaults are untouched:
# every override is unset in the units and the image.
#
# Each story writes artifacts/<story>/ when EV_ROOT is set (ci/evidence.sh).
# Needs: bash, python3 (a fake PipeWire binds a unix socket), and root or
# passwordless sudo for desktop-monitors-capture, which refuses non-root.
set -u
cd "$(dirname "$0")/.." || exit 1
. ci/evidence.sh
[ -z "$EV_ROOT" ] || mkdir -p "$EV_ROOT"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
fails=0

log()  { echo "== $*"; }
fail() { echo "FAIL: $*" >&2; fails=$((fails + 1)); ev_fail "$*"; }
ok()   { ev_pass "$*"; }
want() { # <claim> <cmd...>: a check that must hold
    if "${@:2}"; then ok "$1"; else fail "NOT: $1"; fi
}
ok_if() { # <claim> <condition, as shell text>: for negations and && chains
    if eval "$2"; then ok "$1"; else fail "NOT: $1"; fi
}
has()   { grep -qF -- "$2" <<<"$1"; }     # <text> <fixed string>
stamp() { while IFS= read -r l; do printf '%s %s\n' "$(date -u +%H:%M:%S.%3N)" "$l"; done; }
now()   { date +%s.%N; }
since() { # <t0> <t1> -> seconds between them, "?" if either is missing
    if [ -z "$1" ] || [ -z "$2" ]; then echo "?"; return; fi
    awk -v a="$1" -v b="$2" 'BEGIN{printf "%.1f", b - a}'
}
between() { [ "$1" != "?" ] && awk -v x="$1" -v lo="$2" -v hi="$3" 'BEGIN{exit !(x >= lo && x <= hi)}'; }
as_root() { if [ "$(id -u)" = 0 ]; then "$@"; else sudo "$@"; fi; }
as_nobody() { # run a command as a non-root uid, whoever runs this script
    if [ "$(id -u)" = 0 ]; then setpriv --reuid=65534 --regid=65534 --clear-groups "$@"; else "$@"; fi
}

# --- S1.1.3: base images are content-addressed ------------------------------
ev_begin S1.1.3 "Base images are content-addressed" T1
W=$TMP/bases
mkdir -p "$W/bin" "$W/src"
# A copy of every input, so one can change without touching the checkout.
for f in ci/build-bases.sh Containerfile.base image/rocky9.repo \
         Containerfile.plugin.base cdi-device-plugin/go.mod cdi-device-plugin/go.sum \
         Containerfile.screenshot.base screenshot/go.mod screenshot/go.sum; do
    mkdir -p "$W/src/$(dirname "$f")"
    cp "$f" "$W/src/$f"
done
# Fake podman: every call is logged; `pull` succeeds only for a ref listed in
# the fake registry. Fake sudo for base-rebuild.yml's step, which uses it.
cat > "$W/bin/podman" <<'EOF'
#!/bin/sh
echo "podman $*" >> "$FAKE_LOG"
[ "$1" = pull ] || exit 0
grep -qxF "$2" "$FAKE_REGISTRY"
EOF
printf '#!/bin/sh\nexec "$@"\n' > "$W/bin/sudo"
chmod +x "$W/bin/podman" "$W/bin/sudo"
: > "$W/registry"
bases() { # <run label>: build-bases.sh in the copy, against the fake registry
    : > "$W/calls-$1"
    (cd "$W/src" && PATH="$W/bin:$PATH" REGISTRY=ghcr.io/ci-test FAKE_LOG="$W/calls-$1" \
        FAKE_REGISTRY="$W/registry" bash ci/build-bases.sh)
}
refs() { sed -n 's/^podman pull //p' "$W/calls-$1"; }   # the refs a run asked for

out=$(ev_save run1-empty "build-bases.sh's stdout with nothing in the registry: three cache misses, three builds" bases run1)
want "an empty registry: three cache misses" [ "$(grep -c 'cache miss for' <<<"$out")" = 3 ]
want "and three builds" [ "$(grep -c '^podman build' "$W/calls-run1")" = 3 ]
refs run1 > "$W/registry"      # the "push": now the registry holds those refs
out=$(ev_save run2-cached "build-bases.sh's stdout with those three refs in the registry: all reused, nothing built" bases run2)
want "unchanged inputs: all three reused (\"reused cached base\")" [ "$(grep -c 'reused cached base' <<<"$out")" = 3 ]
want "and nothing built" [ "$(grep -c '^podman build' "$W/calls-run2")" = 0 ]
want "the same inputs give the same three tags" [ "$(refs run1)" = "$(refs run2)" ]

# base-rebuild.yml computes the tags it pushes with its own inline copy of
# content_tag: run that step's script on the same inputs, against fakes.
awk '/- name: push refreshed bases/{f=1} f && /run: \|/{r=1; next} r && /^ {0,6}[^ ]/{exit} r{print}' \
    .github/workflows/base-rebuild.yml > "$W/base-rebuild-push.sh"
: > "$W/calls-rebuild"
(cd "$W/src" && PATH="$W/bin:$PATH" REGISTRY=ghcr.io/ci-test FAKE_LOG="$W/calls-rebuild" \
    FAKE_REGISTRY="$W/registry" bash "$W/base-rebuild-push.sh") \
    || fail "base-rebuild.yml's push step failed against the fakes"
pushed=$(sed -n 's/^podman push \(.*:base-.*\)$/\1/p' "$W/calls-rebuild")
ev_text tags "EV-STATE: the content-addressed refs build-bases.sh pulls and the ones base-rebuild.yml pushes, for the same inputs" \
"build-bases.sh (content_tag):
$(refs run2)
base-rebuild.yml (its inline tag()):
$pushed"
want "base-rebuild.yml pushes the very tags build-bases.sh looks for" [ "$pushed" = "$(refs run2)" ]

echo "# a changed input" >> "$W/src/Containerfile.base"
out=$(ev_save run3-changed "build-bases.sh's stdout after one input changed (a comment appended to Containerfile.base): that base misses and is rebuilt, the other two are reused" bases run3)
old=$(grep desktop-container-base <<<"$(refs run2)")
new=$(grep desktop-container-base <<<"$(refs run3)")
ok_if "a changed input gives a different tag ($old -> $new)" '[ -n "$new" ] && [ "$new" != "$old" ]'
want "that base is rebuilt" grep -q '^podman build -t localhost/desktop-container-base:latest' "$W/calls-run3"
want "the other two are still reused" [ "$(grep -c 'reused cached base' <<<"$out")" = 2 ]
ev_copy "$W/calls-run3" podman-calls-run3 "every podman call the third run made (the fake logs them): one pull miss and one build"
ev_end

# --- S2.3.5: the postmortem's verdicts --------------------------------------
ev_begin S2.3.5 "Postmortem runs on abnormal exit only" T1
X=$TMP/xlogs
mkdir -p "$X"
postmortem() { # <case dir> [SERVICE_RESULT]: run it on that case's logs
    SERVICE_RESULT=${2:-exit-code} EXIT_CODE=exited EXIT_STATUS=1 \
        POSTMORTEM_XLOG_GLOB="$1/Xorg.*.log" image/session/session-postmortem
}
xlog_case() { # <case> <the line that carries the signature>
    mkdir -p "$X/$1"
    printf '[    10.000] (II) Loading /usr/lib64/xorg/modules/libglx.so\n%s\n[    10.200] (EE) Fatal server error:\n' "$2" \
        > "$X/$1/Xorg.0.log"
}
xlog_case drm     '[    10.100] (EE) modeset(0): drmSetMaster failed: Device or resource busy'
xlog_case perm    '[    10.100] (EE) xf86OpenSerial: Cannot open device /dev/input/event3: Permission denied'
xlog_case noscr   '[    10.100] (EE) no screens found(EE)'
xlog_case vt      '[    10.100] (EE) xf86OpenConsole: Cannot open virtual console 1 (Permission denied)'
xlog_case unknown '[    10.100] (EE) something no signature names'
mkdir -p "$X/none"
for c in drm:'another process holds DRM master' perm:'device group permissions' \
         noscr:'no usable GPU' vt:'VT not available'; do
    name=${c%%:*} verdict=${c#*:}
    out=$(ev_save "$name" "the postmortem on an Xorg log with the $name signature: the tail, then its LIKELY CAUSE" postmortem "$X/$name")
    want "$name: the log's tail is printed" has "$out" "---- tail of $X/$name/Xorg.0.log ----"
    want "$name: LIKELY CAUSE: $verdict" has "$out" "LIKELY CAUSE: $verdict"
done
out=$(ev_save unknown "the postmortem on an Xorg log with no known signature: the tail, and no verdict" postmortem "$X/unknown")
want "an unknown failure: the tail is printed" has "$out" "---- end of Xorg log ----"
ok_if "and no LIKELY CAUSE is guessed" '! has "$out" "LIKELY CAUSE"'
out=$(ev_save no-log "the postmortem with no Xorg log at all: its own line" postmortem "$X/none")
want "no Xorg log: a distinct line says so" has "$out" "no Xorg log file found"
out=$(ev_save success "the postmortem called with SERVICE_RESULT=success: silent, exit 0" postmortem "$X/drm" success) \
    || fail "the postmortem exited non-zero for a successful session"
want "SERVICE_RESULT=success: it prints nothing (desktop-init only calls it for a nonzero exit; this is its own guard)" [ -z "$out" ]
ev_end

# --- S2.4.4 and S2.4.5: start-audio with fake daemons -----------------------
A=$TMP/audio
mkdir -p "$A/bin" "$A/run"
# Each fake logs "<epoch> <name> <event>" to $FAKE_LOG. pipewire binds its
# socket after FAKE_PW_BIND seconds ("never": it doesn't); pipewire-pulse
# exits with status 7 after FAKE_PULSE_EXIT seconds, which ends the run; with
# FAKE_WP_STUBBORN=1 wireplumber ignores SIGTERM.
cat > "$A/bin/pipewire" <<'EOF'
#!/bin/bash
exec >/dev/null 2>&1   # never hold start-audio's output open
echo "$(date +%s.%N) pipewire started" >> "$FAKE_LOG"
if [ "$FAKE_PW_BIND" != never ]; then
    sleep "$FAKE_PW_BIND"
    python3 -c 'import socket, sys; socket.socket(socket.AF_UNIX).bind(sys.argv[1])' "$XDG_RUNTIME_DIR/pipewire-0"
    echo "$(date +%s.%N) pipewire bound $XDG_RUNTIME_DIR/pipewire-0" >> "$FAKE_LOG"
fi
exec sleep 600
EOF
cat > "$A/bin/wireplumber" <<'EOF'
#!/bin/bash
exec >/dev/null 2>&1
if [ -S "$XDG_RUNTIME_DIR/pipewire-0" ]; then s=present; else s=missing; fi
echo "$(date +%s.%N) wireplumber started (socket $s)" >> "$FAKE_LOG"
if [ "${FAKE_WP_STUBBORN:-0}" = 1 ]; then
    trap 'echo "$(date +%s.%N) wireplumber ignored SIGTERM" >> "$FAKE_LOG"' TERM
    while :; do sleep 0.2; done
fi
exec sleep 600
EOF
cat > "$A/bin/pipewire-pulse" <<'EOF'
#!/bin/bash
exec >/dev/null 2>&1
echo "$(date +%s.%N) pipewire-pulse started" >> "$FAKE_LOG"
sleep "$FAKE_PULSE_EXIT"
echo "$(date +%s.%N) pipewire-pulse exits 7" >> "$FAKE_LOG"
exit 7
EOF
chmod +x "$A/bin/"*
audio() { # <label> <bind> <pulse exit> [stubborn]: one start-audio run
    rm -f "$A/run/pipewire-0"
    : > "$A/$1.log"
    echo "$(date +%s.%N) start-audio launched" >> "$A/$1.log"
    # Bounded: a start-audio that never returns fails here (124) instead of
    # hanging the job. Mode 644 in git; the image chmods it.
    PATH="$A/bin:$PATH" XDG_RUNTIME_DIR="$A/run" FAKE_LOG="$A/$1.log" \
        FAKE_PW_BIND=$2 FAKE_PULSE_EXIT=$3 FAKE_WP_STUBBORN=${4:-0} \
        timeout 40 bash image/session/start-audio 2>&1 | stamp
    return "${PIPESTATUS[0]}"
}
fakes_alive() { # the pids of anything a fake left running (found by FAKE_LOG)
    local p
    for p in $(pgrep -u "$(id -u)" .); do
        { tr '\0' '\n' < "/proc/$p/environ"; } 2>/dev/null | grep -q "^FAKE_LOG=$A/" && echo "$p"
    done
}
gone() { # <pid...>: true once none of them exists, waiting up to 2 s (KILL is async)
    local p alive _
    for _ in $(seq 20); do
        alive=""
        for p in "$@"; do kill -0 "$p" 2>/dev/null && alive=1; done
        [ -z "$alive" ] && return 0
        sleep 0.1
    done
    return 1
}
reap() { local p; for p in $(fakes_alive); do kill -9 "$p" 2>/dev/null; done; }
at() { awk -v k="$2" 'index($0, k) {print $1; exit}' "$A/$1.log"; }   # <label> <event>

ev_begin S2.4.4 "WirePlumber waits for PipeWire's socket" T1
rc=0; ev_save slow-bind "start-audio's stdout, timestamped, with a fake pipewire that binds its socket 2 s after starting (and a fake pipewire-pulse that exits after 4 s to end the run)" \
    audio slow-bind 2 4 >/dev/null || rc=$?
ev_copy "$A/slow-bind.log" slow-bind-daemons "what each fake daemon did and when (epoch seconds)"
t0=$(at slow-bind 'start-audio launched'); tb=$(at slow-bind 'pipewire bound'); tw=$(at slow-bind 'wireplumber started')
want "wireplumber started only once the socket existed" grep -q 'wireplumber started (socket present)' "$A/slow-bind.log"
want "it waited for the bind: wireplumber started $(since "$t0" "$tw") s after launch, the socket appeared at $(since "$t0" "$tb") s" \
    between "$(since "$tb" "$tw")" 0 0.5
want "start-audio returned the first exit's status (7)" [ "$rc" = 7 ]
rc=0; ev_save never-binds "start-audio's stdout, timestamped, with a fake pipewire that never binds: the wait is bounded" \
    audio never-binds never 12 >/dev/null || rc=$?
ev_copy "$A/never-binds.log" never-binds-daemons "what each fake daemon did and when (epoch seconds): no bind, wireplumber started anyway"
t0=$(at never-binds 'start-audio launched'); tw=$(at never-binds 'wireplumber started')
want "with no socket at all, wireplumber still starts after the bounded wait ($(since "$t0" "$tw") s; the loop is 100 x 0.1 s)" \
    between "$(since "$t0" "$tw")" 9.5 13
reap
ev_end

ev_begin S2.4.5 "A daemon ignoring SIGTERM is escalated" T1
rc=0
out=$(ev_save stubborn "start-audio's stdout, timestamped, when pipewire-pulse exits (status 7) and wireplumber ignores SIGTERM" \
    audio stubborn 0 2 1) || rc=$?
tend=$(now)
ev_copy "$A/stubborn.log" stubborn-daemons "what each fake daemon did and when (epoch seconds): wireplumber ignoring SIGTERM"
tx=$(at stubborn 'pipewire-pulse exits')
want "the first exit is named" has "$out" "start-audio: pipewire-pulse exited"
want "survivors get SIGTERM" grep -q 'wireplumber ignored SIGTERM' "$A/stubborn.log"
want "the holdout is named and killed (\"ignored SIGTERM; killing\")" has "$out" "ignored SIGTERM; killing"
want "start-audio returned $(since "$tx" "$tend") s after the first exit (5 s of grace, then KILL)" between "$(since "$tx" "$tend")" 4.5 7.5
want "with the first exit's status (7)" [ "$rc" = 7 ]
# The three daemons start-audio launched, by the pids its "started" line names
# (not anything carrying the fakes' environment: a KILLed fake's own short
# sleep can outlive it by a moment, and is not a daemon).
daemons=$(sed -n 's/.*started (pipewire=\([0-9]*\) wireplumber=\([0-9]*\) pipewire-pulse=\([0-9]*\)).*/\1 \2 \3/p' <<<"$out")
# shellcheck disable=SC2086 # three pids
ok_if "none of the three daemons ($daemons) outlives start-audio" '[ -n "$daemons" ] && gone $daemons'
reap
ev_end

# --- S5.7.5: desktop-host-shell-setup's empty, missing and unknown cases ----
ev_begin S5.7.5 "Empty or missing shell-user / account" T1
H=$TMP/host-shell
shellsetup() { # <case>: run it against that case's directory
    DESKTOP_CONTAINER_DIR="$H/$1/etc" HOST_SHELL_AK_DIR="$H/$1/ak" \
        deploy/host/usr/local/libexec/desktop-host-shell-setup
}
mkdir -p "$H/missing/etc" "$H/empty/etc" "$H/unknown/etc"
: > "$H/empty/etc/shell-user"
echo "no-such-user-$$" > "$H/unknown/etc/shell-user"
for c in missing:1:'is missing: the deploy tree ships it' empty:0:'is empty; nothing to do' \
         unknown:1:'sysusers.d fragment not applied?'; do
    name=${c%%:*} rest=${c#*:}; want_rc=${rest%%:*} said=${rest#*:}
    rc=0
    out=$(ev_save "$name" "desktop-host-shell-setup with shell-user $name: its output and exit status" shellsetup "$name") || rc=$?
    want "$name shell-user: exit $want_rc" [ "$rc" = "$want_rc" ]
    want "$name shell-user: it says \"$said\"" has "$out" "$said"
    ev_save "$name-after" "EV-STATE: the directories after the $name case: no key, no trust entry" \
        sh -c "cd '$H/$name' && ls -laR" >/dev/null || true
    want "$name shell-user: nothing written (no key, no authorized_keys.d entry)" \
        [ -z "$(find "$H/$name" -name 'host-shell-key*' -o -path '*/ak/*' -type f)" ]
done
ev_end

# --- S5.7.8: host-terminal keeps the window open on failure ------------------
ev_begin S5.7.8 "The menu wrapper keeps its window open on failure" T1
F=$TMP/fakessh
mkdir -p "$F"
printf '#!/bin/sh\necho "fake ssh $* (exit $FAKE_SSH_RC)"\nexit "$FAKE_SSH_RC"\n' > "$F/ssh"
chmod +x "$F/ssh"
hostterm() { # <fake ssh's exit code> <stdin feeder...>: host-terminal, ssh faked
    local rc=$1
    shift
    PATH="$F:$PATH" FAKE_SSH_RC=$rc image/session/host-terminal < <(exec 2>/dev/null; "$@")
}
t0=$(now); rc=0
out=$(ev_save success "host-terminal with a fake ssh that exits 0, its stdin held open for 5 s: it exits at once" \
    hostterm 0 sleep 5) || rc=$?
dt=$(since "$t0" "$(now)")
want "ssh succeeds: exit 0" [ "$rc" = 0 ]
want "and at once, without waiting for Enter (returned in $dt s with stdin still open)" between "$dt" 0 1.5
ok_if "and no failure text" '! has "$out" "failed"'
t0=$(now); rc=0
out=$(ev_save failure "host-terminal with a fake ssh that exits 255, Enter pressed 2 s later" \
    hostterm 255 sh -c 'sleep 2; echo') || rc=$?
dt=$(since "$t0" "$(now)")
want "ssh fails: the exit code is printed" has "$out" "ssh to the host failed (exit 255)"
want "the enablement command is printed" has "$out" "systemctl start desktop-host-shell.service"
want "the common causes are printed" has "$out" "Other common causes: sshd not running"
want "it waits for Enter (returned after $dt s; Enter came at 2 s)" between "$dt" 1.8 4
want "and exits with ssh's code (255)" [ "$rc" = 255 ]
ev_end

# --- S3.4.12: desktop-monitors-capture on canned xrandr ----------------------
ev_begin S3.4.12 "desktop-monitors-capture prints a valid, round-trippable block" T1
C=$TMP/capture
mkdir -p "$C/etc" "$C/xorg.conf.d"
CAP=deploy/host/usr/local/bin/desktop-monitors-capture
cat > "$C/xrandr.txt" <<'EOF'
Screen 0: minimum 320 x 200, current 3000 x 1920, maximum 16384 x 16384
DP-1 connected primary 1920x1080+0+0 (normal left inverted right x axis y axis) 527mm x 296mm
   1920x1080     60.00*+  50.00    59.94
   1680x1050     59.88
DP-2 connected 1080x1920+1920+0 left (normal left inverted right x axis y axis) 527mm x 296mm
   1920x1080     60.00*+
   1280x1024     60.02
HDMI-1 disconnected (normal left inverted right x axis y axis)
EOF
ev_copy "$C/xrandr.txt" xrandr-canned "the canned xrandr --query the tool reads (DP-1 primary, DP-2 rotated left, HDMI-1 disconnected)"
rc=0
out=$(ev_save non-root "desktop-monitors-capture run as a non-root uid: refused" as_nobody "$CAP") || rc=$?
ok_if "a non-root caller is refused (exit 2, \"run as root\")" '[ "$rc" = 2 ] && has "$out" "run as root"'
rc=0
out=$(ev_save capture "desktop-monitors-capture as root on the canned xrandr: one line per enabled output" \
    as_root env DESKTOP_XRANDR_CMD="cat '$C/xrandr.txt'" "$CAP") || rc=$?
want "the capture exits 0" [ "$rc" = 0 ]
lines=$(grep -v '^#' <<<"$out")
want "one line per enabled output (2; the disconnected HDMI-1 is left out)" [ "$(grep -c . <<<"$lines")" = 2 ]
want "DP-1: its mode, refresh, position and primary" grep -qE '^DP-1 +1920x1080@60\.00 +\+0\+0 primary$' <<<"$lines"
want "DP-2: the panel size (transposition undone), position and rotate=left" grep -qE '^DP-2 +1920x1080@60\.00 +\+1920\+0 rotate=left$' <<<"$lines"
rc=0
out=$(ev_save desktop-down "desktop-monitors-capture when the query fails (the desktop is down): exit 1 and the hint" \
    as_root env DESKTOP_XRANDR_CMD="echo \"Can't open display :0\" >&2; exit 1" "$CAP") || rc=$?
want "a failing query: exit 1" [ "$rc" = 1 ]
want "with the hint to check desktop.service" has "$out" "is desktop.service running?"
# The round trip: the captured block, through the generator, gives back the
# same geometry - the framebuffer xrandr reported and each output's place.
printf '%s\n' "$lines" > "$C/etc/monitors.conf"
printf 'Section "Device"\n    Identifier "gpu0"\n    Driver     "modesetting"\nEndSection\n' > "$C/xorg.conf.d/20-gpu.conf"
MONITORS_CONF="$C/etc/monitors.conf" MONITORS_OUT="$C/xorg.conf.d/30-monitors.conf" \
    XORG_GPU_CONF="$C/xorg.conf.d/20-gpu.conf" image/xorg/xorg-monitor-conf.sh > "$C/gen.log" 2>&1 \
    || fail "the generator failed on the captured block"
ev_copy "$C/xorg.conf.d/30-monitors.conf" round-trip "EV-CONFIG: the 30-monitors.conf the generator writes from the captured block"
gen=$(cat "$C/xorg.conf.d/30-monitors.conf" 2>/dev/null)
want "round trip: the framebuffer is xrandr's 3000 x 1920" has "$gen" "Virtual 3000 1920"
ok_if "round trip: DP-2 is placed at 1920,0 and rotated left" "has \"\$gen\" 'Option      \"Position\" \"1920 0\"' && has \"\$gen\" 'Option      \"Rotate\" \"left\"'"
ok_if "round trip: DP-1 is primary at 0,0" "has \"\$gen\" 'Option      \"Position\" \"0 0\"' && has \"\$gen\" 'Option      \"Primary\" \"true\"'"
ev_end

if [ "$fails" -gt 0 ]; then
    echo "script unit tests: $fails failure(s)" >&2
    exit 1
fi
echo "script unit tests passed"
