#!/bin/bash
# Guided hardware acceptance: the T4 stories of Requirements.md (Appendix C),
# run by a person at a provisioned physical host. Each story writes the same
# evidence directory as CI (ci/evidence.sh; evlib.py renders evidence.md).
# What the host and the desktop report is saved and checked here. What only
# a person can see or hear (a picture on a panel, a tone from a speaker) is
# asked of the tester, and the photo, video or recording the story names is
# attached from a path the tester gives.
#
#   sudo ci/hw/acceptance.sh list              the stories and what each needs
#   sudo ci/hw/acceptance.sh run STORY...      run stories, e.g. run S8.1.1 S8.2.1
#   sudo ci/hw/acceptance.sh S8.3.2 sample     one row of the log-bound table
#                                              (daily; needs no terminal, so
#                                              cron can run it)
#   sudo ci/hw/acceptance.sh pack              a tarball of the evidence so far
#
# The first run asks the tester's name (or takes HW_TESTER) and keeps it in
# $HW_STATE/tester: every story's evidence names who ran it, and when.
#
# Run it as root from a checkout of this repository, over ssh from a machine
# that is not behind the host's KVM: a provisioned host's console is the
# desktop (no getty on any VT), and the KVM stories switch its keyboard away.
# Evidence goes under $HW_STATE/artifacts (default /var/lib/hw-acceptance),
# which survives the reboots some stories need. Whatever a story stages (a
# spec set aside, a drop-in, a kernel argument) is undone before it ends;
# the stories that reboot keep their place in $HW_STATE and undo it on their
# last run. The evidence keeps what was staged and how it was undone.
#
# HW_REHEARSE=1 answers every question yes and attaches no media, so the
# machine side runs on any host. Its evidence says it was a rehearsal, and
# no observation or media check passes in it: a rehearsal is not hardware
# acceptance.
set -uo pipefail

REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
HW_STATE=${HW_STATE:-/var/lib/hw-acceptance}
HW_REHEARSE=${HW_REHEARSE:-}
export EV_ROOT=${EV_ROOT:-$HW_STATE/artifacts}
EV_SOURCE="ci/hw/acceptance.sh on $(hostname -s)${HW_REHEARSE:+, a REHEARSAL (not hardware acceptance)}"
export EV_SOURCE
# shellcheck source=../evidence.sh
. "$REPO/ci/evidence.sh"

XORG_LOG=/home/desktop/.local/share/xorg/Xorg.0.log
PROBE_IMG=localhost/desktop-testclient:latest
SPEC=/etc/cdi/nvidia.yaml
DROPIN_DIR=/etc/containers/systemd/desktop.container.d
DROPIN=$DROPIN_DIR/90-hw-acceptance-nvidia-x.conf
LOG_BOUND=$((64 * 1024 * 1024))

# --- talking to the tester -----------------------------------------------------
say() { printf '\n%s\n' "$*" | fold -s -w 78 >&2; }
ask() { # <prompt> [rehearsal answer]: one line from the tester
    local a=""
    if [ -n "$HW_REHEARSE" ]; then printf '%s\n' "${2:-}"; return 0; fi
    printf '%s ' "$1" >&2
    IFS= read -r a < /dev/tty || true
    printf '%s\n' "$a"
}
enter() { # <what to do first>
    say "$1"
    if [ -n "$HW_REHEARSE" ]; then echo "(rehearsal: not waiting)" >&2; return 0; fi
    printf '[Enter when done] ' >&2
    read -r _ < /dev/tty || true
}
yes_no() { # <question>: 0 for yes
    local a
    [ -n "$HW_REHEARSE" ] && return 0
    while :; do
        printf '%s [y/n] ' "$1" >&2
        read -r a < /dev/tty || return 1
        case "$a" in y|Y|yes) return 0 ;; n|N|no) return 1 ;; esac
    done
}
# Who ran it, for every story's meta.tsv (E8: a T4 result carries the
# tester's name and date): HW_TESTER, else the name given at the first run,
# kept in $HW_STATE/tester so that later runs and the cron samples carry it.
tester() {
    local name=${HW_TESTER:-}
    [ -n "$name" ] || name=$(cat "$HW_STATE/tester" 2>/dev/null || true)
    if [ -z "$name" ]; then
        name=$(ask "Your name, for the evidence:" rehearsal)
        if [ -n "$name" ] && [ -z "$HW_REHEARSE" ]; then printf '%s\n' "$name" > "$HW_STATE/tester"; fi
    fi
    printf '%s' "${name:-not given}"
}
# What only a person can see or hear, as a check.
observe() { # <claim>
    if [ -n "$HW_REHEARSE" ]; then ev_note "rehearsal: no person observed: $1"; return 0; fi
    if yes_no "$1?"; then ev_pass "the tester confirms: $1"; else ev_fail "the tester does not confirm: $1"; fi
}
# A photo, video or recording the tester made, copied into the story.
MEDIA_LAST=""
media() { # <EV-PHOTO|EV-PHONEVIDEO|EV-AUDIO-REC> <moment> <what>
    local path
    MEDIA_LAST=""
    if [ -n "$HW_REHEARSE" ]; then ev_note "rehearsal: no $1 attached ($3)"; return 0; fi
    say "$1 for the record: $3. Copy the file onto this host and give its path, or type skip."
    while :; do
        path=$(ask "path:")
        if [ "$path" = skip ]; then ev_fail "no $1 attached: $3"; return 1; fi
        [ -f "$path" ] && break
        echo "no such file: $path" >&2
    done
    ev_copy "$path" "$2" "$1: $3"
    ev_pass "$1 attached: $3 ($(basename "$path"))"
    MEDIA_LAST=$path
}

# --- the desktop ---------------------------------------------------------------
# The desktop image's own X tools: xrandr, xdpyinfo and glxinfo, and with them
# xinput, xwininfo and xprop (xorg-x11-server-utils and xorg-x11-utils, the
# packages its xrandr and xdpyinfo resolve to on Rocky 9).
xq()   { podman exec -u desktop -e DISPLAY=:0 desktop "$@"; }
desk() { podman exec -u desktop -e XDG_RUNTIME_DIR=/run/user/61000 -e HOME=/home/desktop -e DISPLAY=:0 desktop "$@"; }
probe() { podman run --rm --device desktop.local/display=all "$PROBE_IMG" "$@"; }
have_probe() { podman image exists "$PROBE_IMG"; }
ctr_state() { podman inspect -f 'id={{.Id}} started={{.State.StartedAt}} restarts={{.RestartCount}} status={{.State.Status}}' "${1:-desktop}"; }
# The desktop's own processes by name: the container shares the host's pid
# namespace, so its ps lists host processes too; its cgroup tells them apart.
ctr_pids() { # <comm,comm>
    local id pid rest
    id=$(podman inspect -f '{{.Id}}' desktop) || return 1
    podman exec desktop ps -o pid=,lstart=,comm= -C "$1" | while read -r pid rest; do
        grep -qs "$id" "/proc/$pid/cgroup" && printf '%s %s\n' "$pid" "$rest"
    done
}
x_up() { xq xdpyinfo >/dev/null 2>&1; }
wait_desktop() { # [seconds]: desktop.service active and X answering
    local _i
    for _i in $(seq "${1:-120}"); do
        systemctl is-active --quiet desktop.service && x_up && return 0
        sleep 1
    done
    return 1
}
restart_desktop() { # <moment>
    ev_save "$1" "EV-PROCEDURE: systemctl restart desktop.service" systemctl restart desktop.service >/dev/null || true
    wait_desktop 120
}
xorg_lines() { podman exec desktop sh -c "wc -l < $XORG_LOG" 2>/dev/null || echo 0; }
xorg_since() { podman exec desktop sh -c "tail -n +$(( $1 + 1 )) $XORG_LOG"; }
nvidia_host() { [ -e /dev/nvidiactl ] || grep -q '^nvidia ' /proc/modules; }
# The checks below read generated files (the CDI spec, 20-gpu.conf, the
# quadlet's unit) by their content lines only: the generators write comments
# too, and quadlet copies the .container's comments into the unit, its
# commented nvidia_drv.so Volume= lines among them (Requirements.md S9.1.2).
# A command's output is captured before a reader that stops early sees it: a
# producer killed by SIGPIPE would fail the pipeline under pipefail (S9.1.5).
spec_is_stub() { grep -qE '^[[:space:]]*-[[:space:]]*NVIDIA_CDI_STUB=1' "$SPEC" 2>/dev/null; }
# stdin: a 20-gpu.conf; $1: the driver its Device section names.
conf_driver_is() { grep -qE "^[[:space:]]*Driver[[:space:]]+\"$1\""; }
# stdin: a 20-gpu.conf; $1: a module directory one of its ModulePath lines names.
conf_has_modpath() { awk -v d="\"$1\"" '$1 == "ModulePath" && $2 == d {f = 1} END {exit !f}'; }
# stdin: `systemctl cat desktop.service`. A drop-in's Volume= lines reach the
# container as ExecStart's -v arguments, which is what this reads.
unit_has_x_driver() { grep -qE '^ExecStart=.*nvidia_drv\.so'; }
# $1: a CDI spec; the driver version its versioned library paths carry.
spec_version() {
    local v
    v=$(gen_grep -m1 -oE 'libnvidia-glcore\.so\.[0-9][0-9.]*' "$1" 2>/dev/null)
    v=${v%%$'\n'*}
    printf '%s' "${v#libnvidia-glcore.so.}"
}
glx_is_nvidia() {
    local g
    g=$(xq glxinfo -B 2>/dev/null) || return 1
    grep -qi 'OpenGL vendor string: *NVIDIA' <<<"$g"
}
gpu_lines() { podman logs desktop 2>&1 | grep -E 'xorg-gpu-conf|preflight:'; }

# --- staging, and undoing it ---------------------------------------------------
# Each step that changes the host registers its undo here; the story's end,
# and an interrupted run, run them last first. A story that reboots keeps its
# undo in its own phase file instead (S8.1.3, S10.1.6).
UNDO=()
undo_later() { UNDO+=("$1"); }
undo_all() {
    local i
    for ((i=${#UNDO[@]}-1; i>=0; i--)); do
        ev_save undo "EV-PROCEDURE: undoing what the story staged: ${UNDO[$i]}" sh -c "${UNDO[$i]}" >/dev/null \
            || say "could not undo, do it by hand: ${UNDO[$i]}"
    done
    UNDO=()
}
trap 'undo_all' EXIT
trap 'say "interrupted: undoing what was staged"; undo_all; exit 130' INT TERM

CTK=""
ctk_aside() { # nvidia-ctk off PATH, so desktop-cdi-refresh cannot regenerate the spec
    CTK=$(command -v nvidia-ctk) || return 1
    mv "$CTK" "$CTK.hw-aside" || return 1
    ev_note "harness-only staging: $CTK set aside as $CTK.hw-aside"
}
ctk_back_cmd() { echo "[ -e '$CTK.hw-aside' ] && mv '$CTK.hw-aside' '$CTK'; true"; }

# The X driver's mounts dropped from a copy of the real spec, the way an older
# toolkit generates it: every mount item (a "- containerPath:" or
# "- hostPath:" entry and the lines indented under it) naming nvidia_drv.so or
# libglxserver_nvidia.so.
spec_without_xdriver() { # <in> <out>: prints how many mounts were dropped
    { awk -v pat='nvidia_drv\\.so|libglxserver_nvidia\\.so' '
        function ind(s) { match(s, /^ */); return RLENGTH }
        function flush() { if (item) { if (drop) n++; else printf "%s", buf } item = 0; buf = ""; drop = 0 }
        {
            if (item && ($0 ~ /^ *$/ || ind($0) > iind)) { buf = buf $0 "\n"; if ($0 ~ pat) drop = 1; next }
            flush()
            if ($0 ~ /^ *- (containerPath|hostPath): /) { item = 1; iind = ind($0); buf = $0 "\n"; drop = ($0 ~ pat); next }
            print
        }
        END { flush(); print n + 0 > "/dev/stderr" }' "$1" > "$2"; } 2>&1
}

# The documented X-driver fallback (README.md "nvidia_drv.so missing"): the
# quadlet's commented Volume= lines, as a drop-in.
fallback_lines() {
    sed -n 's/^#[[:space:]]*\(Volume=.*nvidia.*\)$/\1/p' /etc/containers/systemd/desktop.container
}

# --- the stories ---------------------------------------------------------------

# A story's first ev_begin in an attempt: an earlier attempt's directory is
# moved aside (<story>.<UTC time>), so that its checks do not count in this
# one. The later phases of a story that reboots, and S8.3.2's daily samples,
# add to the directory they find (ev_begin).
story_begin() { # <story> <title> [tier]
    if [ -n "$EV_ROOT" ] && [ -d "$EV_ROOT/$1" ]; then
        mv "$EV_ROOT/$1" "$EV_ROOT/$1.$(date -u +%Y%m%dT%H%M%SZ)"
    fi
    ev_begin "$@"
}

# S8.1.1 and S3.1.1: an NVIDIA host whose toolkit injects the X driver.
gpu_mode_checks() { # the GPU mode, into the open story; sets GPU_CONF GPU_LOG GPU_GLX
    ev_save cmdline "EV-STATE: /proc/cmdline and nvidia_drm's modeset parameter" \
        sh -c 'cat /proc/cmdline; echo "nvidia_drm modeset: $(cat /sys/module/nvidia_drm/parameters/modeset 2>/dev/null || echo "(module not loaded)")"' >/dev/null
    ev_save driver "EV-STATE: nvidia-smi and the NVIDIA packages" \
        sh -c 'nvidia-smi 2>&1 | head -20; rpm -qa | grep -iE "nvidia|cuda" | sort' >/dev/null
    ev_save cdi-head "EV-STATE: head -5 /etc/cdi/nvidia.yaml" head -5 "$SPEC" >/dev/null
    if spec_is_stub; then ev_fail "the CDI spec is the stub (NVIDIA_CDI_STUB): the toolkit made no real spec"
    else ev_pass "the CDI spec is a real one, not the stub"; fi
    GPU_CONF=$(ev_save gpu-conf "EV-CONFIG: /etc/X11/xorg.conf.d/20-gpu.conf in the desktop" podman exec desktop cat /etc/X11/xorg.conf.d/20-gpu.conf) || true
    if conf_driver_is nvidia <<<"$GPU_CONF"; then ev_pass '20-gpu.conf says Driver "nvidia"'
    else ev_fail '20-gpu.conf does not say Driver "nvidia"'; fi
    # xorg-gpu-conf's decision comes after the preflight's lines in a start's log.
    log_wait 60 2 'xorg-gpu-conf: decision:' gpu_lines >/dev/null || true
    GPU_LOG=$(ev_save gpu-log "EV-LOG-DESKTOP: podman logs desktop | grep -E 'xorg-gpu-conf|preflight:'" gpu_lines) || true
    if grep -q 'preflight: PASS: NVIDIA GPU injected together with X driver module' <<<"$GPU_LOG"; then
        ev_pass "the container preflight: PASS: NVIDIA GPU injected together with X driver module"
    else ev_fail "the container preflight does not PASS the NVIDIA injection: $(grep -m1 -i nvidia <<<"$GPU_LOG")"; fi
    GPU_GLX=$(ev_save glxinfo "EV-STATE: glxinfo -B in the desktop" xq glxinfo -B) || true
    if grep -qi 'OpenGL vendor string: *NVIDIA' <<<"$GPU_GLX"; then ev_pass "glxinfo -B: $(grep -m1 -i 'OpenGL renderer' <<<"$GPU_GLX")"
    else ev_fail "glxinfo -B does not report NVIDIA: $(grep -m1 -i 'OpenGL vendor' <<<"$GPU_GLX")"; fi
    ev_save unit "EV-STATE: systemctl cat desktop.service: its Image= and ExecStart= lines and the other uncommented lines naming nvidia" \
        sh -c "systemctl cat desktop.service | grep -E '^(Image|ExecStart)=|^[^#;]*nvidia'" >/dev/null
}
gpu_mode() {
    local photo moddir
    nvidia_host || { say "S8.1.1 and S3.1.1 need an NVIDIA host: no /dev/nvidiactl and no nvidia module here."; return 1; }
    wait_desktop 30 || say "the desktop is not up; the checks will say why"
    story_begin S8.1.1 "NVIDIA GPU mode" T4
    gpu_mode_checks
    ev_save host-preflight "EV-STATE: desktop-preflight on the host" desktop-preflight >/dev/null
    observe "the desktop is on this host's monitor: the dark root, the session xterm in mwm's frame"
    media EV-PHOTO desktop "the desktop on this host's monitor, NVIDIA mode"
    photo=$MEDIA_LAST
    ev_end

    story_begin S3.1.1 "NVIDIA path" T4
    ev_text gpu-conf "EV-CONFIG: /etc/X11/xorg.conf.d/20-gpu.conf, the file xorg-gpu-conf.sh generated (S8.1.1's run)" "$GPU_CONF"
    ev_text gpu-log "EV-LOG-DESKTOP: xorg-gpu-conf.sh's evidence lines and decision (S8.1.1's run)" "$(grep xorg-gpu-conf <<<"$GPU_LOG")"
    ev_text glxinfo "EV-STATE: glxinfo -B in the desktop (S8.1.1's run)" "$GPU_GLX"
    if conf_driver_is nvidia <<<"$GPU_CONF"; then ev_pass '20-gpu.conf says Driver "nvidia"'
    else ev_fail '20-gpu.conf does not say Driver "nvidia"'; fi
    moddir=$(sed -n 's/.*decision: NVIDIA driver (module dir \(.*\))$/\1/p' <<<"$GPU_LOG")
    moddir=${moddir%%$'\n'*}
    if [ -n "$moddir" ] && conf_has_modpath "$moddir" <<<"$GPU_CONF"; then
        ev_pass "a ModulePath covers the injected nvidia_drv.so: $moddir"
    else ev_fail "no ModulePath for the injected nvidia_drv.so's directory (${moddir:-not in the log})"; fi
    if grep -qi 'OpenGL vendor string: *NVIDIA' <<<"$GPU_GLX"; then ev_pass "glxinfo -B reports NVIDIA"
    else ev_fail "glxinfo -B does not report NVIDIA"; fi
    if [ -n "$photo" ]; then ev_copy "$photo" desktop "EV-PHOTO: the desktop on this host's monitor (S8.1.1's photo)"
    elif [ -z "$HW_REHEARSE" ]; then ev_fail "no EV-PHOTO of the desktop"; fi
    ev_end
}

# S3.1.2 and S8.1.4: NVIDIA nodes with no X driver injected, then the
# documented fallback.
no_xdriver() {
    local keep="$HW_STATE/nvidia.yaml.real" n conf log glx pf0 pf1 unit real_f staged=no entry
    nvidia_host || { say "S3.1.2 and S8.1.4 need an NVIDIA host."; return 1; }
    story_begin S3.1.2 "NVIDIA nodes without the X driver fall back to modesetting" T4
    ev_copy "$SPEC" spec-real "EV-CONFIG: /etc/cdi/nvidia.yaml as this host's toolkit generated it"
    real_f=$EV_LAST
    if gen_grep -q 'hostPath: .*nvidia_drv\.so' "$SPEC"; then
        staged=yes
        say "This host's toolkit injects nvidia_drv.so. The stories are about an older toolkit that does not. The script can stage that: a copy of the spec with the X driver's mounts dropped, and nvidia-ctk set aside so nothing regenerates it, both undone at the end."
        yes_no "Stage it?" || { ev_abort "not staged: this toolkit injects the X driver and the tester declined the staging"; return 1; }
        cp -a "$SPEC" "$keep" || { ev_abort "could not keep a copy of $SPEC"; return 1; }
        ctk_aside || { ev_abort "could not set nvidia-ctk aside"; return 1; }
        undo_later "$(ctk_back_cmd); cp -a '$keep' '$SPEC'; systemctl restart desktop-cdi-refresh.service; systemctl restart desktop.service"
        n=$(spec_without_xdriver "$keep" "$SPEC")
        if [ "${n:-0}" -lt 1 ] || gen_grep -q 'hostPath: .*nvidia_drv\.so' "$SPEC"; then
            ev_abort "the X driver's mounts could not be dropped from the spec (dropped ${n:-0})"; return 1
        fi
        ev_note "harness-only staging: the spec without the X driver's $n mount(s), as an older toolkit writes it"
        ev_copy "$SPEC" spec-staged "EV-CONFIG: the staged spec, the X driver's mounts dropped"
        ev_diff spec "EV-DIFF: the toolkit's spec (-) against the staged one (+)" "$real_f" "$EV_LAST"
    else
        ev_note "this host's toolkit does not inject nvidia_drv.so: the older toolkit the stories ask for, as installed"
    fi
    restart_desktop restart-staged || ev_fail "the desktop did not come back after the restart"
    conf=$(ev_save gpu-conf "EV-CONFIG: /etc/X11/xorg.conf.d/20-gpu.conf in the desktop" podman exec desktop cat /etc/X11/xorg.conf.d/20-gpu.conf) || true
    log_wait 60 2 'xorg-gpu-conf: decision:' gpu_lines >/dev/null || true
    log=$(ev_save gpu-log "EV-LOG-DESKTOP: podman logs desktop | grep -E 'xorg-gpu-conf|preflight:'" gpu_lines) || true
    if conf_driver_is modesetting <<<"$conf"; then ev_pass "20-gpu.conf takes the modesetting branch"
    else ev_fail "20-gpu.conf is not the modesetting branch"; fi
    if grep -q 'warning: NVIDIA device nodes present but no nvidia_drv.so was injected' <<<"$log" \
       && grep -q 'warning: falling back to modesetting' <<<"$log"; then
        ev_pass "xorg-gpu-conf logs both warning lines"
    else ev_fail "xorg-gpu-conf does not log both warning lines"; fi
    observe "the desktop is on the monitor, unaccelerated (modesetting)"
    media EV-PHOTO desktop "the desktop on this host's monitor, modesetting with NVIDIA nodes present"
    ev_end

    story_begin S8.1.4 "Old toolkit without nvidia_drv.so" T4
    ev_save preflight-before "EV-LOG-DESKTOP: the container preflight, the X driver not injected" sh -c 'podman logs desktop 2>&1 | grep preflight:' >/dev/null || true
    pf0=$EV_LAST
    if grep -q 'WARN: NVIDIA device nodes present but nvidia_drv.so NOT injected' "$EV_DIR/$pf0"; then
        ev_pass "the container preflight WARNs: nvidia_drv.so NOT injected"
    else ev_fail "the container preflight does not WARN that nvidia_drv.so is not injected"; fi
    entry=$(python3 "$REPO/ci/doc-blocks.py" "$REPO/README.md" "GPU notes" --entry 'nvidia_drv.so missing' 2>&1) \
        || { ev_abort "README.md has no \"nvidia_drv.so missing\" entry under \"GPU notes\" any more: $entry"; return 1; }
    ev_text readme "EV-PROCEDURE: README.md's \"nvidia_drv.so missing\" entry (\"GPU notes\"), as this run read it" "$entry"
    if [ -z "$(fallback_lines)" ]; then ev_abort "the quadlet has no commented Volume= lines for the X driver to make the fallback from"; return 1; fi
    mkdir -p "$DROPIN_DIR"
    { echo "# ci/hw/acceptance.sh S8.1.4: README.md's fallback, the quadlet's commented lines"; echo "[Container]"; fallback_lines; } > "$DROPIN"
    undo_later "rm -f '$DROPIN'; systemctl daemon-reload; systemctl restart desktop.service"
    ev_copy "$DROPIN" dropin "EV-CONFIG: the fallback drop-in, from the quadlet's commented Volume= lines"
    ev_save daemon-reload "EV-PROCEDURE: harness-only: systemctl daemon-reload, which a new quadlet drop-in needs before it reaches the unit (the entry gives no command for it)" \
        systemctl daemon-reload >/dev/null || true
    unit=$(ev_save unit "EV-STATE: systemctl cat desktop.service with the drop-in: the drop-in's Volume= lines reach ExecStart as -v (quadlet merges drop-ins from podman 5.0)" \
        systemctl cat desktop.service) || true
    if unit_has_x_driver <<<"$unit"; then ev_pass "the generated unit's ExecStart carries the drop-in's X driver volume"
    else ev_fail "the generated unit's ExecStart does not carry the drop-in (podman $(podman --version | awk '{print $3}'); quadlet merges drop-ins only from 5.0)"; fi
    restart_desktop restart-fallback || ev_fail "the desktop did not come back with the fallback"
    glx=$(ev_save glxinfo "EV-STATE: glxinfo -B with the fallback" xq glxinfo -B) || true
    if grep -qi 'OpenGL vendor string: *NVIDIA' <<<"$glx"; then ev_pass "with the fallback glxinfo -B reports NVIDIA again"
    else ev_fail "with the fallback glxinfo -B does not report NVIDIA: $(grep -m1 -i 'OpenGL vendor' <<<"$glx")"; fi
    ev_save preflight-after "EV-LOG-DESKTOP: the container preflight with the fallback" sh -c 'podman logs desktop 2>&1 | grep preflight:' >/dev/null || true
    pf1=$EV_LAST
    ev_diff preflight "EV-DIFF: the container preflight, the X driver missing (-) against the fallback (+)" "$pf0" "$pf1"
    if grep -q 'PASS: NVIDIA GPU injected together with X driver module' "$EV_DIR/$pf1"; then
        ev_pass "with the fallback the container preflight PASSes the NVIDIA injection"
    else ev_fail "with the fallback the container preflight does not PASS the NVIDIA injection"; fi
    undo_all
    # Back as it was: NVIDIA mode where the X driver was staged away, the
    # older toolkit's modesetting where it was installed that way.
    if [ "$staged" = yes ]; then
        if wait_desktop 120 && glx_is_nvidia; then
            ev_pass "undone: the toolkit's own spec back, the desktop in NVIDIA mode"
        else ev_fail "after undoing, the desktop is not back in NVIDIA mode"; fi
    else
        if wait_desktop 120 && conf=$(podman exec desktop cat /etc/X11/xorg.conf.d/20-gpu.conf) \
           && conf_driver_is modesetting <<<"$conf"; then
            ev_pass "undone: the drop-in gone, the desktop back on modesetting as installed"
        else ev_fail "after undoing, the desktop is not back as it was"; fi
    fi
    ev_end
}

# S8.1.2: an NVIDIA host whose toolkit is missing: the stub, and both
# preflights FAIL on it.
stub_toolkit() {
    local keep="$HW_STATE/nvidia.yaml.real" conf hpf cpf
    nvidia_host || { say "S8.1.2 needs an NVIDIA host."; return 1; }
    say "S8.1.2 stages a missing toolkit: nvidia-ctk set aside and the real spec moved away, so desktop-cdi-refresh writes the stub. Both are put back at the end."
    yes_no "Stage it?" || return 1
    story_begin S8.1.2 "NVIDIA host with missing/broken toolkit" T4
    if command -v nvidia-ctk >/dev/null; then
        ctk_aside || { ev_abort "could not set nvidia-ctk aside"; return 1; }
    else ev_note "this host has no nvidia-ctk: the missing toolkit, as installed"; fi
    mv "$SPEC" "$keep" || { ev_abort "could not move $SPEC away"; return 1; }
    undo_later "$(ctk_back_cmd); [ -e '$SPEC' ] || cp -a '$keep' '$SPEC'; systemctl restart desktop-cdi-refresh.service; systemctl restart desktop.service"
    ev_save cdi-refresh "EV-PROCEDURE: systemctl restart desktop-cdi-refresh.service, the toolkit gone" systemctl restart desktop-cdi-refresh.service >/dev/null || true
    ev_save cdi-journal "EV-LOG-JOURNAL: desktop-cdi-refresh's journal: the stub written" \
        journalctl --no-pager -o short-precise -u desktop-cdi-refresh.service -n 10 >/dev/null || true
    ev_copy "$SPEC" stub "EV-CONFIG: /etc/cdi/nvidia.yaml: the stub"
    if spec_is_stub; then ev_pass "desktop-cdi-refresh wrote the stub"; else ev_fail "the spec is not the stub"; fi
    restart_desktop restart-stub || ev_fail "the desktop did not come up on the stub"
    conf=$(ev_save gpu-conf "EV-CONFIG: 20-gpu.conf in the desktop" podman exec desktop cat /etc/X11/xorg.conf.d/20-gpu.conf) || true
    if conf_driver_is modesetting <<<"$conf"; then ev_pass "the desktop came up on modesetting"; else ev_fail "20-gpu.conf is not modesetting"; fi
    hpf=$(ev_save host-preflight "EV-STATE: desktop-preflight on the host" desktop-preflight) || true
    if grep -q 'FAIL: STUB CDI spec but NVIDIA hardware present' <<<"$hpf"; then ev_pass "the host preflight FAILs: STUB CDI spec but NVIDIA hardware present"
    else ev_fail "the host preflight does not FAIL on the stub with hardware"; fi
    log_wait 60 2 'xorg-gpu-conf: decision:' podman logs desktop >/dev/null || true
    cpf=$(ev_save ctr-preflight "EV-LOG-DESKTOP: the container preflight" sh -c 'podman logs desktop 2>&1 | grep preflight:') || true
    if grep -q 'FAIL: NVIDIA hardware visible but the host injected a STUB CDI spec' <<<"$cpf"; then ev_pass "the container preflight FAILs: NVIDIA hardware visible but a STUB CDI spec"
    else ev_fail "the container preflight does not FAIL on the stub with hardware"; fi
    observe "the desktop is on the monitor and works (unaccelerated)"
    media EV-PHOTO desktop "the working desktop on the stub"
    undo_all
    if wait_desktop 120 && ! spec_is_stub; then ev_pass "undone: the toolkit back, a real spec regenerated, the desktop up"
    else ev_fail "after undoing, the real spec or the desktop is not back"; fi
    ev_end
}

# S8.1.3: no KMS from nvidia-drm and no injection: across two reboots.
no_modeset() {
    local phase_f="$HW_STATE/S8.1.3.phase" phase keep="$HW_STATE/nvidia.yaml.real" args old cpf
    phase=$(cat "$phase_f" 2>/dev/null || echo new)
    nvidia_host || { say "S8.1.3 needs an NVIDIA host."; return 1; }
    case "$phase" in
    new)
        say "S8.1.3 needs nvidia-drm without modeset and no GPU injection. The script sets nvidia_drm.modeset=0 on the default kernel's command line (grubby), sets nvidia-ctk aside and moves the real spec away (desktop-cdi-refresh then writes the stub), and reboots. Run 'run S8.1.3' again after the boot; that run checks, puts everything back and reboots once more; a third run checks the host is whole."
        yes_no "Stage it and reboot?" || return 1
        story_begin S8.1.3 "NVIDIA host without nvidia_drm.modeset=1 and no injection" T4
        args=$(grubby --info=DEFAULT | sed -n 's/^args="\(.*\)"$/\1/p')
        printf '%s\n' "$args" > "$HW_STATE/S8.1.3.args"
        ev_text args-before "EV-STATE: the default kernel's arguments before the staging" "$args"
        ctk_aside || { ev_abort "no nvidia-ctk to set aside"; return 1; }
        printf '%s\n' "$CTK" > "$HW_STATE/S8.1.3.ctk"
        mv "$SPEC" "$keep" || { mv "$CTK.hw-aside" "$CTK"; ev_abort "could not move $SPEC away"; return 1; }
        old=$(tr ' ' '\n' <<<"$args" | grep '^nvidia_drm\.modeset=' || true)
        ev_save grubby "EV-PROCEDURE: harness-only staging: grubby --update-kernel=DEFAULT${old:+ --remove-args=$old} --args=nvidia_drm.modeset=0" \
            grubby --update-kernel=DEFAULT ${old:+--remove-args="$old"} --args=nvidia_drm.modeset=0 >/dev/null || true
        echo staged > "$phase_f"
        ev_note "staged, rebooting: run 'run S8.1.3' after the boot"
        ev_end
        say "Rebooting. Run 'run S8.1.3' again when the host is back."
        systemctl reboot
        ;;
    staged)
        ev_begin S8.1.3 "NVIDIA host without nvidia_drm.modeset=1 and no injection" T4
        ev_save cmdline "EV-STATE: cat /proc/cmdline, and nvidia_drm's modeset parameter" \
            sh -c 'cat /proc/cmdline; echo "nvidia_drm modeset: $(cat /sys/module/nvidia_drm/parameters/modeset 2>/dev/null || echo "(module not loaded)")"' >/dev/null
        ev_save dri "EV-STATE: ls -l /dev/dri on the host" sh -c 'ls -l /dev/dri 2>&1; true' >/dev/null
        if ls /dev/dri/card* >/dev/null 2>&1; then
            ev_fail "the host still has a DRM card ($(ls /dev/dri | tr '\n' ' ')): another GPU, or nvidia-drm kept KMS; the story needs an NVIDIA-only host"
        else ev_pass "no /dev/dri/card* on the host"; fi
        if spec_is_stub; then ev_pass "no injection: the stub spec"; else ev_fail "the spec is not the stub"; fi
        sleep 20
        log_wait 30 2 'preflight: FAIL: no /dev/dri/card' podman logs desktop >/dev/null || true
        cpf=$(ev_save ctr-preflight "EV-LOG-DESKTOP: podman logs desktop | grep preflight:, the desktop's last start" sh -c 'podman logs desktop 2>&1 | grep preflight:') || true
        if grep -q 'FAIL: no /dev/dri/card\* visible.*nvidia_drm.modeset=1' <<<"$cpf"; then
            ev_pass "the container preflight FAILs: no /dev/dri/card* visible, naming nvidia_drm.modeset=1"
        else ev_fail "the container preflight does not FAIL on the missing card with the kernel-cmdline hint"; fi
        ev_save host-preflight "EV-STATE: desktop-preflight on the host" desktop-preflight >/dev/null || true
        say "Now the script puts the kernel argument, nvidia-ctk and the spec back, and reboots."
        yes_no "Undo and reboot?" || { ev_end; return 1; }
        CTK=$(cat "$HW_STATE/S8.1.3.ctk")
        ev_save undo-ctk "EV-PROCEDURE: undoing: nvidia-ctk back" sh -c "$(ctk_back_cmd)" >/dev/null || true
        ev_save undo-spec "EV-PROCEDURE: undoing: the real spec back" cp -a "$keep" "$SPEC" >/dev/null || true
        ev_save undo-grubby "EV-PROCEDURE: undoing: the modeset argument back as it was" \
            sh -c "grubby --update-kernel=DEFAULT --remove-args=nvidia_drm.modeset=0; a=\$(tr ' ' '\n' < '$HW_STATE/S8.1.3.args' | grep '^nvidia_drm\.modeset=' || true); [ -z \"\$a\" ] || grubby --update-kernel=DEFAULT --args=\"\$a\"" >/dev/null || true
        echo restored > "$phase_f"
        ev_end
        systemctl reboot
        ;;
    restored)
        ev_begin S8.1.3 "NVIDIA host without nvidia_drm.modeset=1 and no injection" T4
        ev_save args-after "EV-STATE: the default kernel's arguments after the undo" grubby --info=DEFAULT >/dev/null || true
        if wait_desktop 120 && ! spec_is_stub && glx_is_nvidia; then
            ev_pass "undone: the host is back in NVIDIA mode after the reboot"
        else ev_fail "after the undo and reboot the host is not back in NVIDIA mode"; fi
        rm -f "$phase_f" "$HW_STATE/S8.1.3.args" "$HW_STATE/S8.1.3.ctk"
        ev_end
        ;;
    esac
}

# S5.4.3: a stale real spec fails container creation; README's remedy.
stale_spec() {
    local ver real stale jr out entry spans remedy
    nvidia_host || { say "S5.4.3 needs an NVIDIA host with a real spec."; return 1; }
    spec_is_stub && { say "S5.4.3 needs a real spec; this one is the stub."; return 1; }
    ver=$(spec_version "$SPEC")
    if [ -z "$ver" ]; then
        ver=$(nvidia-smi --query-gpu=driver_version --format=csv,noheader 2>/dev/null)
        ver=${ver%%$'\n'*}
    fi
    [ -n "$ver" ] || { say "could not tell the driver version from the spec or nvidia-smi"; return 1; }
    say "S5.4.3 stages what a driver update leaves behind: the spec's versioned paths ($ver) point at files that are gone. nvidia-ctk is set aside meanwhile so the desktop's restart cannot regenerate it. Then README.md's remedy."
    yes_no "Stage it?" || return 1
    story_begin S5.4.3 "Stale real spec fails loudly, regenerates on restart" T4
    ev_copy "$SPEC" spec-real "EV-CONFIG: the real spec, driver $ver"
    real=$EV_LAST
    ctk_aside || { ev_abort "could not set nvidia-ctk aside"; return 1; }
    undo_later "$(ctk_back_cmd); systemctl restart desktop-cdi-refresh.service; systemctl restart desktop.service"
    sed -i "s/\\.so\\.${ver//./\\.}/.so.${ver}-gone/g" "$SPEC"
    ev_copy "$SPEC" spec-stale "EV-CONFIG: the staged stale spec: every .so.$ver path is .so.$ver-gone"
    stale=$EV_LAST
    ev_diff staging "EV-DIFF: the real spec (-) against the stale one (+)" "$real" "$stale"
    ev_note "harness-only staging: the spec's .so.$ver paths renamed, as after a driver update"
    jr=$(date '+%Y-%m-%d %H:%M:%S')
    ev_save restart "EV-PROCEDURE: harness-only staging: systemctl restart desktop.service on the stale spec, as the first start after a driver update" \
        systemctl restart desktop.service >/dev/null || true
    sleep 20
    if systemctl is-active --quiet desktop.service; then ev_fail "the desktop started on a stale spec"
    else ev_pass "the desktop does not start on the stale spec ($(systemctl show -p ActiveState --value desktop.service))"; fi
    log_wait 30 2 "$ver-gone|[Nn]o such file" journalctl --no-pager -o short-precise -u desktop.service --since "$jr" >/dev/null || true
    out=$(ev_save journal-stale "EV-LOG-JOURNAL: journalctl -u desktop.service since the restart: the creation error" \
        journalctl --no-pager -o short-precise -u desktop.service --since "$jr") || true
    if grep -qiE "$ver-gone|no such file" <<<"$out"; then ev_pass "the journal names the failure: $(grep -m1 -iE "$ver-gone|no such file" <<<"$out" | cut -c1-200)"
    else ev_fail "the journal does not name the stale spec"; fi
    ev_save ctk-back "EV-PROCEDURE: harness-only staging: the toolkit back (nvidia-ctk), as on the host after its driver update" \
        sh -c "$(ctk_back_cmd)" >/dev/null || true
    jr=$(date '+%Y-%m-%d %H:%M:%S')
    entry=$(python3 "$REPO/ci/doc-blocks.py" "$REPO/README.md" "GPU notes" --entry 'CDI spec staleness' 2>&1) \
        || { ev_abort "README.md has no \"CDI spec staleness\" entry under \"GPU notes\" any more: $entry"; return 1; }
    ev_text readme "EV-PROCEDURE: README.md's \"CDI spec staleness\" entry (\"GPU notes\"), as this run read it" "$entry"
    spans=$(python3 "$REPO/ci/doc-blocks.py" "$REPO/README.md" "GPU notes" --entry 'CDI spec staleness' --spans)
    remedy=$(grep -m1 '^systemctl ' <<<"$spans") \
        || { ev_abort "README.md's \"CDI spec staleness\" entry no longer gives a systemctl command: $entry"; return 1; }
    ev_save remedy "EV-PROCEDURE: \`$remedy\`, the entry's remedy, as the entry writes it" sh -c "$remedy" >/dev/null || true
    ev_save cdi-journal "EV-LOG-JOURNAL: desktop-cdi-refresh's journal after the remedy" \
        journalctl --no-pager -o short-precise -u desktop-cdi-refresh.service --since "$jr" >/dev/null || true
    ev_copy "$SPEC" spec-regenerated "EV-CONFIG: the spec after the remedy"
    ev_diff remedy "EV-DIFF: the stale spec (-) against the regenerated one (+)" "$stale" "$EV_LAST"
    if ! gen_grep -q "$ver-gone" "$SPEC" && ! spec_is_stub; then ev_pass "the remedy regenerated a real spec"
    else ev_fail "after the remedy the spec is still stale or the stub"; fi
    if wait_desktop 60; then ev_pass "after the remedy alone the desktop is back"
    else
        ev_fail "after the remedy alone the desktop is not back within 60 s ($(systemctl show -p ActiveState,Result --value desktop.service | tr '\n' ' ')): README.md's remedy does not say to start it again"
        restart_desktop restart-after-remedy && ev_note "a systemctl restart desktop.service then brought it back"
    fi
    wait_desktop 5 && UNDO=()
    ev_end
}

# Each connected output's name, whether primary, and geometry, from a saved
# xrandr --query: the arrangement, whatever the current mode is named (an
# EDID mode autodetected, a generated modeline declared).
arrangement() { # <xrandr file>
    awk '/ connected/ { g = ($3 == "primary") ? $4 : $3; print $1, ($3 == "primary" ? "primary" : ""), g }' "$1"
}

# S8.2.3: desktop-monitors-capture's output, installed, gives the same
# arrangement; the monitors' EDIDs.
capture_layout() {
    local cap x0 x1 e
    wait_desktop 30 || say "the desktop is not up"
    story_begin S8.2.3 "Real EDID and desktop-monitors-capture" T4
    ev_save xrandr-before "EV-STATE: xrandr --query before the capture" xq xrandr --query >/dev/null || true
    x0=$EV_LAST
    ev_save capture "EV-STATE: desktop-monitors-capture: the real output names and rates (stdout and stderr)" desktop-monitors-capture >/dev/null || true
    cap=$(desktop-monitors-capture 2>/dev/null) || true
    if grep -qE '^[A-Za-z]+-[0-9A-Za-z-]+ +[0-9]+x[0-9]+' <<<"$cap"; then ev_pass "desktop-monitors-capture printed $(grep -cE '^[A-Za-z]+-[0-9A-Za-z-]+ +[0-9]+x[0-9]+' <<<"$cap") output line(s)"
    else ev_fail "desktop-monitors-capture printed no output line"; fi
    observe "the output names and rates it printed are this desk's monitors"
    ev_copy /etc/desktop-container/monitors.conf monitors-before "EV-CONFIG: monitors.conf before"
    cp -a /etc/desktop-container/monitors.conf "$HW_STATE/monitors.conf.before"
    printf '%s\n' "$cap" > /etc/desktop-container/monitors.conf
    ev_copy /etc/desktop-container/monitors.conf monitors-installed "EV-CONFIG: monitors.conf as installed: the capture, pasted as it is"
    restart_desktop restart || ev_fail "the desktop did not come back with the captured layout"
    ev_save xorg-monitor-conf "EV-LOG-DESKTOP: podman logs desktop | grep xorg-monitor-conf" sh -c 'podman logs desktop 2>&1 | grep xorg-monitor-conf' >/dev/null || true
    ev_save xrandr-after "EV-STATE: xrandr --query after the restart, the captured layout declared" xq xrandr --query >/dev/null || true
    x1=$EV_LAST
    ev_diff xrandr "EV-DIFF: xrandr --query autodetected (-) against the declared capture (+)" "$x0" "$x1"
    if diff -q <(arrangement "$EV_DIR/$x0") <(arrangement "$EV_DIR/$x1") >/dev/null; then
        ev_pass "the same arrangement after the restart: $(arrangement "$EV_DIR/$x1" | tr '\n' ';')"
    else ev_fail "the arrangement changed: $(arrangement "$EV_DIR/$x0" | tr '\n' ';') -> $(arrangement "$EV_DIR/$x1" | tr '\n' ';')"; fi
    for e in /sys/class/drm/card*-*/edid; do
        [ -s "$e" ] || continue
        if command -v edid-decode >/dev/null; then
            ev_save "edid-$(basename "$(dirname "$e")")" "EV-STATE: edid-decode $e" edid-decode "$e" >/dev/null || true
        else
            ev_save "edid-$(basename "$(dirname "$e")")" "EV-STATE: $e as hex (edid-decode is not installed on this host)" od -An -tx1 "$e" >/dev/null || true
        fi
    done
    if yes_no "Keep the captured layout installed (the KVM video stories need a declared layout)?"; then
        ev_note "the captured layout stays installed; the shipped file is at $HW_STATE/monitors.conf.before"
    else
        cp -a "$HW_STATE/monitors.conf.before" /etc/desktop-container/monitors.conf
        if cmp -s "$HW_STATE/monitors.conf.before" /etc/desktop-container/monitors.conf && restart_desktop restore; then
            ev_pass "monitors.conf put back as it was, and the desktop restarted on it"
        else ev_fail "monitors.conf is not back as it was, or the desktop did not restart on it"; fi
    fi
    ev_end
}

# S8.2.2, S3.4.5 (its T4 half) and S3.10.8: the declared geometry across a
# switch cycle, or a cable pulled and put back. The tester's keyboard may be
# behind the KVM, so the cycle runs on a timer: switch away when told, come
# back when told, and the script samples the connectors meanwhile.
video_cycle() { # <story> <title> <what the tester does>
    local story=$1 how=$3 x0 x1 t0 t1 lines conf secs=${HW_AWAY:-30}
    wait_desktop 30 || say "the desktop is not up"
    grep -qE '^[^#[:space:]]+[[:space:]]+[0-9]+x[0-9]+' /etc/desktop-container/monitors.conf \
        || { say "$story needs a declared layout: run S8.2.3 first and keep its capture."; return 1; }
    story_begin "$story" "$2" T4
    if [ "$story" = S3.4.5 ]; then
        conf=$(podman exec desktop cat /etc/X11/xorg.conf.d/20-gpu.conf 2>/dev/null)
        conf_driver_is nvidia <<<"$conf" \
            || { ev_abort "S3.4.5's T4 half is the NVIDIA driver's: this desktop is not on it"; return 1; }
    fi
    ev_save gpu-conf "EV-CONFIG: 20-gpu.conf: the driver this cycle runs on" podman exec desktop cat /etc/X11/xorg.conf.d/20-gpu.conf >/dev/null || true
    ev_copy /etc/desktop-container/monitors.conf layout "EV-CONFIG: the declared layout (monitors.conf)"
    ev_save xrandr-before "EV-STATE: xrandr --query before" xq xrandr --query >/dev/null || true
    x0=$EV_LAST
    ev_save tree-before "EV-STATE: xwininfo -root -tree before" xq xwininfo -root -tree >/dev/null || true
    t0=$EV_LAST
    lines=$(xorg_lines)
    say "Start the phone video now, with the monitor in frame, and keep it running. When you press Enter: within 10 s, $how. Stay that way for $secs s while the script records the connectors, then undo it when this terminal says so (or when $secs s have passed). Then wait 20 s for the picture."
    enter "Ready?"
    ( for _ in $(seq $(( (secs + 30) / 2 ))); do
          printf '%s ' "$(date -u +%T)"; cat /sys/class/drm/card*-*/status 2>/dev/null | tr '\n' ' '; echo
          sleep 2
      done ) > "$HW_STATE/connectors.log" &
    sleep $((secs + 10))
    say "Undo it now: switch back, or plug the cable back in."
    sleep 20
    wait
    ev_copy "$HW_STATE/connectors.log" connectors "EV-STATE: cat /sys/class/drm/card*-*/status every 2 s through the cycle"
    if grep -q disconnected "$HW_STATE/connectors.log"; then ev_note "a connector read disconnected during the cycle"
    else ev_note "no connector read disconnected during the cycle (the KVM may emulate the monitor)"; fi
    ev_save xrandr-after "EV-STATE: xrandr --query after" xq xrandr --query >/dev/null || true
    x1=$EV_LAST
    ev_save tree-after "EV-STATE: xwininfo -root -tree after" xq xwininfo -root -tree >/dev/null || true
    t1=$EV_LAST
    ev_diff xrandr "EV-DIFF: xrandr --query before (-) and after (+): empty" "$x0" "$x1"
    ev_diff tree "EV-DIFF: the window tree before (-) and after (+): empty" "$t0" "$t1"
    if diff -q <(sed 1d "$EV_DIR/$x0") <(sed 1d "$EV_DIR/$x1") >/dev/null; then ev_pass "xrandr --query is the same after the cycle"
    else ev_fail "xrandr --query changed across the cycle"; fi
    if diff -q <(sed 1d "$EV_DIR/$t0") <(sed 1d "$EV_DIR/$t1") >/dev/null; then ev_pass "every window is where it was"
    else ev_fail "the window tree changed across the cycle"; fi
    ev_save xorg "EV-LOG-XORG: the Xorg log's lines from the cycle (connector events)" xorg_since "$lines" >/dev/null || true
    observe "the panel shows the picture again, unchanged, after the link retrained"
    media EV-PHONEVIDEO cycle "the monitor through the whole cycle"
    if [ "$story" = S3.10.8 ]; then
        media EV-PHOTO after "the desktop after the cable went back in"
    fi
    ev_end
}

# S8.2.1: the keyboard and mouse through a physical KVM, ten switches.
kvm_input() {
    local model n=${HW_SWITCHES:-10} b0 b1 c0 c1 s0 s1 p0 p1 x0 x1 since mon
    wait_desktop 30 || say "the desktop is not up"
    story_begin S8.2.1 "Physical KVM: input" T4
    model=$(ask "The KVM's make and model:" "rehearsal")
    ev_note "the KVM: $model"
    since=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    ev_save by-id-before "EV-STATE: ls -l /dev/input/by-id before" sh -c 'ls -l /dev/input/by-id' >/dev/null || true
    b0=$EV_LAST
    ev_save ctr-input-before "EV-STATE: ls /dev/input in the desktop before" podman exec desktop ls /dev/input >/dev/null || true
    c0=$EV_LAST
    ev_save xinput-before "EV-STATE: xinput list before" desk xinput list >/dev/null || true
    x0=$EV_LAST
    ev_save ctr-before "EV-PIDS: the container before" ctr_state >/dev/null || true
    s0=$EV_LAST
    ev_save pids-before "EV-PIDS: Xorg and mwm before" ctr_pids Xorg,mwm >/dev/null || true
    p0=$EV_LAST
    ( udevadm monitor --kernel --subsystem-match=input ) > "$HW_STATE/udev-input.log" 2>&1 &
    mon=$!
    say "Start the phone video. Switch the KVM away from this host and back once."
    enter "Back on this host?"
    type_check first
    say "Now switch away and back $((n - 1)) more times, at your own pace."
    enter "All $n switches done, the KVM back on this host?"
    type_check "switch $n"
    kill "$mon" 2>/dev/null; wait "$mon" 2>/dev/null
    ev_copy "$HW_STATE/udev-input.log" udev "EV-STATE: udevadm monitor --kernel --subsystem-match=input through the switches: the keyboard and mouse leaving and coming back"
    ev_note "input add events through the switches: $(grep -c ' add ' "$HW_STATE/udev-input.log")"
    ev_save by-id-after "EV-STATE: ls -l /dev/input/by-id after" sh -c 'ls -l /dev/input/by-id' >/dev/null || true
    b1=$EV_LAST
    ev_diff by-id "EV-DIFF: /dev/input/by-id before (-) and after (+): the re-enumeration" "$b0" "$b1"
    ev_save ctr-input-after "EV-STATE: ls /dev/input in the desktop after" podman exec desktop ls /dev/input >/dev/null || true
    c1=$EV_LAST
    ev_diff ctr-input "EV-DIFF: /dev/input in the desktop before (-) and after (+)" "$c0" "$c1"
    ev_save xinput-after "EV-STATE: xinput list after" desk xinput list >/dev/null || true
    x1=$EV_LAST
    ev_diff xinput "EV-DIFF: xinput list before (-) and after (+)" "$x0" "$x1"
    ev_save ctr-after "EV-PIDS: the container after" ctr_state >/dev/null || true
    s1=$EV_LAST
    ev_save pids-after "EV-PIDS: Xorg and mwm after" ctr_pids Xorg,mwm >/dev/null || true
    p1=$EV_LAST
    if diff -q <(sed 1d "$EV_DIR/$s0") <(sed 1d "$EV_DIR/$s1") >/dev/null && diff -q <(sed 1d "$EV_DIR/$p0") <(sed 1d "$EV_DIR/$p1") >/dev/null; then
        ev_pass "no restart: the same container, Xorg and mwm throughout"
    else ev_fail "the container, Xorg or mwm changed during the switches"; fi
    ev_save desktop-log "EV-LOG-DESKTOP: podman logs --since $since desktop: nothing restarted" podman logs --since "$since" desktop >/dev/null || true
    if grep -qE 'session exited|restarting in|postmortem' "$EV_DIR/$EV_LAST"; then ev_fail "the desktop log shows the session restarting"
    else ev_pass "the desktop log shows no session restart"; fi
    media EV-PHONEVIDEO switch "the KVM switched away and back, and typing afterwards"
    ev_end
}
# Typing through the keyboard the KVM just gave back, into a sink xterm.
type_check() { # <label>
    local word got
    word="kvm$(od -An -N5 -tu1 /dev/urandom | awk '{for (i = 1; i <= NF; i++) printf "%c", 97 + $i % 26}')"
    podman exec desktop rm -f /tmp/hw-sink
    podman exec -d -u desktop -e DISPLAY=:0 -e HOME=/home/desktop desktop \
        xterm -title hw-sink -geometry 40x5+200+200 -e sh -c 'IFS= read -r l; printf "%s" "$l" > /tmp/hw-sink'
    sleep 2
    say "On this host's keyboard (through the KVM): click the small xterm titled hw-sink and type  $word  then Return."
    enter "Typed it?"
    got=$(podman exec desktop cat /tmp/hw-sink 2>/dev/null || true)
    if [ -n "$HW_REHEARSE" ]; then ev_note "rehearsal: nobody typed ($1)"; podman exec desktop pkill -f 'xterm -title hw-sink' 2>/dev/null; return 0; fi
    if [ "$got" = "$word" ]; then ev_pass "after the $1 the keyboard types: the sink xterm read '$word'"
    else ev_fail "after the $1 the sink xterm read '${got:-nothing}', not '$word'"; podman exec desktop pkill -f 'xterm -title hw-sink' 2>/dev/null; fi
    # mwm may focus a new window by itself, so the typing does not prove the
    # mouse: the tester says whether it moved the pointer and clicked.
    observe "after the $1 the mouse moves the pointer, and its click raised or focused the xterm"
}

# The Audio section's device lines in wpctl status ("42. Built-in Audio  [alsa]").
wp_devices() {
    desk wpctl status 2>/dev/null | awk '/^Audio/ {a = 1} /^Video/ {a = 0}
        a && /Devices:/ {d = 1; next} d && /(├─|└─)/ {d = 0} d && /[0-9]+\./ {sub(/^[^0-9]*/, ""); print}'
}

# S8.3.1 and S4.7.12: a USB headset or DAC plugged in after boot, with a
# client playing throughout.
usb_audio() {
    local tone="$HW_STATE/tone.wav" w0 w1 w2 s0 s1 d0 d1 card sinks sources sink src rec peak f m what
    wait_desktop 30 || say "the desktop is not up"
    have_probe || { say "S8.3.1 plays and records through the probe image ($PROBE_IMG): build it from Containerfile.testclient (Appendix A) and load it."; return 1; }
    story_begin S8.3.1 "USB audio devices" T4
    python3 - "$tone" <<'PY'
import math, struct, sys, wave
w = wave.open(sys.argv[1], "wb"); w.setnchannels(2); w.setsampwidth(2); w.setframerate(48000)
w.writeframes(b"".join(struct.pack("<hh", v, v) for v in (int(12000 * math.sin(2 * math.pi * 440 * i / 48000)) for i in range(48000 * 5))))
w.close()
PY
    podman rm -f hw-player >/dev/null 2>&1
    podman create --name hw-player --device desktop.local/audio=all "$PROBE_IMG" \
        sh -c 'while :; do paplay /tmp/tone.wav || sleep 1; done' >/dev/null || { ev_abort "could not create the client"; return 1; }
    undo_later "podman rm -f hw-player"
    podman cp "$tone" hw-player:/tmp/tone.wav && podman start hw-player >/dev/null
    ev_save client "EV-STATE: the client: podman create --device desktop.local/audio=all $PROBE_IMG, a 440 Hz tone on a loop (a podman client stands in for the pod, as F7.7's common set allows)" ctr_state hw-player >/dev/null || true
    s0=$EV_LAST
    ev_save snd-before "EV-STATE: ls /dev/snd in the desktop before" podman exec desktop ls /dev/snd >/dev/null || true
    ev_save wpctl-before "EV-STATE: wpctl status before" desk wpctl status >/dev/null || true
    w0=$EV_LAST
    d0=$(wp_devices)
    say "Start the phone video, with the sound on. The client plays a 440 Hz tone on a loop."
    enter "Plug the USB headset or DAC in now."
    for _ in $(seq 20); do sleep 1; [ "$(wp_devices)" != "$d0" ] && break; done
    sleep 3
    ev_save snd-plugged "EV-STATE: ls /dev/snd in the desktop, plugged" podman exec desktop ls /dev/snd >/dev/null || true
    ev_save wpctl-plugged "EV-STATE: wpctl status, plugged" desk wpctl status >/dev/null || true
    w1=$EV_LAST
    ev_diff wpctl-plug "EV-DIFF: wpctl status before (-) and plugged (+): the device" "$w0" "$w1"
    d1=$(wp_devices)
    card=$(comm -13 <(sort <<<"$d0") <(sort <<<"$d1"))
    if [ -n "$card" ]; then ev_pass "the device appears in wpctl status: $(tr -s ' ' <<<"$card" | tr '\n' ';')"
    else ev_fail "wpctl status lists no new device after the plug"; fi
    sinks=$(desk pactl list short sinks 2>/dev/null)
    sources=$(desk pactl list short sources 2>/dev/null)
    sink=$(awk '/usb/ {print $2; exit}' <<<"$sinks")
    src=$(awk '/usb/ && !/monitor/ {print $2; exit}' <<<"$sources")
    ev_note "the device's sink: ${sink:-none}; its source: ${src:-none}"
    if [ -n "$sink" ]; then
        ev_save default "EV-PROCEDURE: pactl set-default-sink $sink: the client's stream follows the default" desk pactl set-default-sink "$sink" >/dev/null || true
    fi
    observe "the client's tone is coming out of the USB device"
    media EV-PHONEVIDEO plug "the device plugged in, the tone audible from it"
    if [ -n "$src" ]; then
        say "Recording 6 s from the device's microphone in a client, after Enter: speak into it."
        enter "Ready to speak?"
        rec=$(mktemp -d "$HW_STATE/rec.XXXX")
        podman run --rm --device desktop.local/audio=all -v "$rec:/out:z" "$PROBE_IMG" \
            timeout 6 parecord --device="$src" --file-format=wav /out/speech.wav >/dev/null 2>&1
        if [ -s "$rec/speech.wav" ]; then
            ev_copy "$rec/speech.wav" speech "EV-AUDIO-REC: 6 s from the device's microphone, recorded by a client"
            peak=$(python3 - "$rec/speech.wav" <<'PY'
import struct, sys, wave
w = wave.open(sys.argv[1]); n = w.getnframes(); d = w.readframes(n)
s = struct.unpack("<%dh" % (len(d) // 2), d) if w.getsampwidth() == 2 else (0,)
print("%.3f" % (max(abs(x) for x in s) / 32768.0 if s else 0))
PY
)
            ev_note "the recording's peak: $peak of full scale"
            if awk -v p="$peak" 'BEGIN{exit !(p >= 0.02)}'; then ev_pass "the client recorded sound from the device's microphone (peak $peak)"
            else ev_fail "the recording is silent (peak $peak)"; fi
        else ev_fail "the client recorded nothing from $src"; fi
        rm -rf "${rec:?}"
    else ev_note "the device has no microphone source: no recording"; fi
    enter "Unplug the USB device now."
    for _ in $(seq 20); do sleep 1; [ "$(wp_devices)" != "$d1" ] && break; done
    sleep 3
    ev_save wpctl-unplugged "EV-STATE: wpctl status, unplugged" desk wpctl status >/dev/null || true
    w2=$EV_LAST
    ev_diff wpctl-unplug "EV-DIFF: wpctl status plugged (-) and unplugged (+)" "$w1" "$w2"
    if [ "$(wp_devices)" = "$d0" ]; then ev_pass "the device left wpctl status: the devices are the ones before the plug"
    else ev_fail "after the unplug wpctl status does not list the devices from before the plug"; fi
    observe "the tone came back on the speakers after the unplug"
    ev_save client-after "EV-STATE: the client after: the same container, never restarted" ctr_state hw-player >/dev/null || true
    s1=$EV_LAST
    if diff -q <(sed '1d;s/ status=.*//' "$EV_DIR/$s0") <(sed '1d;s/ status=.*//' "$EV_DIR/$s1") >/dev/null \
       && grep -q 'restarts=0 status=running' "$EV_DIR/$s1"; then
        ev_pass "the client played throughout: the same container, restarts 0, still running"
    else ev_fail "the client changed or stopped across the plug and unplug"; fi
    undo_all
    ev_end
    # S4.7.12: the same run, its own story.
    story_begin S4.7.12 "Physical USB audio plug-in and plug-out" T4
    while IFS=$'\t' read -r _ f what; do
        case "$what" in
            "EV-STATE: wpctl"*|"EV-DIFF: wpctl"*|EV-PHONEVIDEO*|EV-AUDIO-REC*)
                m=${f#[0-9][0-9]-}; m=${m%.*}
                ev_copy "$EV_ROOT/S8.3.1/$f" "$m" "$what (S8.3.1's run)" ;;
        esac
    done < "$EV_ROOT/S8.3.1/files.tsv"
    if grep -q $'\tFAIL\t' "$EV_ROOT/S8.3.1/checks.tsv" 2>/dev/null; then ev_fail "S8.3.1's run failed a check: see its evidence"
    else ev_pass "S8.3.1's run passed every check: the device plugged, audible, recorded from and unplugged"; fi
    ev_end
}

# S8.3.2: the container log stays bounded over days.
log_sample() {
    local path size
    ev_begin S8.3.2 "Long-run log bound" T4
    path=$(podman inspect -f '{{.HostConfig.LogConfig.Path}}' desktop 2>/dev/null)
    [ -n "$path" ] || path=$(podman inspect -f '{{.LogPath}}' desktop 2>/dev/null)
    size=$(stat -c %s "$path" 2>/dev/null || echo 0)
    [ -s "$HW_STATE/log-bound.tsv" ] || printf 'utc\tuptime_s\tcontainer_started\tbytes\tpath\n' > "$HW_STATE/log-bound.tsv"
    printf '%s\t%s\t%s\t%s\t%s\n' "$(date -u +%FT%TZ)" "$(cut -d. -f1 /proc/uptime)" \
        "$(podman inspect -f '{{.State.StartedAt}}' desktop 2>/dev/null)" "$size" "$path" >> "$HW_STATE/log-bound.tsv"
    ev_save logconfig "EV-STATE: podman inspect: the container's LogConfig" podman inspect -f '{{json .HostConfig.LogConfig}}' desktop >/dev/null || true
    ev_save ls "EV-STATE: ls -l of the container log" sh -c "ls -l '$path'*" >/dev/null || true
    ev_copy "$HW_STATE/log-bound.tsv" table "EV-STATE: every sample so far: time, uptime, the container's start, the log's size"
    if [ "$size" -le $((LOG_BOUND + LOG_BOUND / 20)) ]; then ev_pass "this sample: $size bytes, within ~64 MB"
    else ev_fail "this sample: $size bytes, over ~64 MB"; fi
    ev_end
}
log_check() {
    local rows span max logcfg
    log_sample
    rows=$(($(wc -l < "$HW_STATE/log-bound.tsv") - 1))
    span=$(awk -F'\t' 'NR==2{a=$2} NR>1{b=$2} END{print b-a}' "$HW_STATE/log-bound.tsv")
    max=$(awk -F'\t' 'NR>1 && $4>m{m=$4} END{print m+0}' "$HW_STATE/log-bound.tsv")
    ev_begin S8.3.2 "Long-run log bound" T4
    if [ "$rows" -ge 3 ] && [ "${span:-0}" -ge 172800 ]; then ev_pass "$rows samples over $((span / 3600)) h of uptime"
    else ev_fail "$rows samples over $((${span:-0} / 3600)) h: the story wants daily samples over days (3 or more, 48 h or more of one uptime)"; fi
    if [ "$max" -le $((LOG_BOUND + LOG_BOUND / 20)) ]; then ev_pass "the log never exceeded ~64 MB: the largest sample $max bytes"
    else ev_fail "the log reached $max bytes, over ~64 MB"; fi
    logcfg=$(podman inspect -f '{{json .HostConfig.LogConfig}}' desktop 2>/dev/null)
    if grep -qiE '64 ?mb|67108864' <<<"$logcfg"; then ev_pass "the running container's LogConfig carries the 64 MB bound: $logcfg"
    else ev_fail "the running container's LogConfig has no 64 MB bound: ${logcfg:-podman inspect gave nothing}"; fi
    ev_end
}

# S10.1.6: a GPU host from the documents alone, then S8.1.1's checks on its
# first boot. Two runs: provision (it reboots), then check.
gpu_from_docs() {
    local phase_f="$HW_STATE/S10.1.6.phase" phase line rc i=0 hpf cpf pci
    phase=$(cat "$phase_f" 2>/dev/null || echo new)
    case "$phase" in
    new)
        pci=$(lspci 2>/dev/null)
        grep -qi nvidia <<<"$pci" || { say "S10.1.6 needs a host with an NVIDIA GPU."; return 1; }
        say "S10.1.6 starts on a stock EL9 host, before the deploy tree: the NVIDIA driver stack installed as deploy/HOST-REQUIRES.md describes it, and the desktop image loaded or at hand. The script runs each documented command as written, at this terminal (answer dnf's questions yourself), keeps every command and its transcript, and the last one reboots."
        yes_no "Is the NVIDIA driver stack installed as HOST-REQUIRES.md describes (the kernel module and the Xorg driver pieces)?" \
            || { say "Install it first: deploy/HOST-REQUIRES.md, 'GPU hosts, additionally'."; return 1; }
        story_begin S10.1.6 "A GPU host provisioned from the documentation comes up accelerated on its first boot" T4
        ev_save stock "EV-STATE: the stock host: release, kernel, cmdline, the NVIDIA packages" \
            sh -c 'cat /etc/redhat-release; uname -r; cat /proc/cmdline; rpm -qa | grep -iE "nvidia|cuda" | sort; nvidia-smi 2>&1 | head -12' >/dev/null || true
        ev_save rpm-stock "EV-STATE: rpm -qa | sort, the stock host" sh -c 'rpm -qa | sort' >/dev/null || true
        while IFS= read -r line; do
            [ -n "$line" ] || continue
            i=$((i + 1)); line=${line%%$'\t'*}
            run_documented "$line" "deploy/HOST-REQUIRES.md, line $i" || return 1
        done < <(python3 "$REPO/ci/doc-blocks.py" "$REPO/deploy/HOST-REQUIRES.md" "Every host" 1 --commands
                 python3 "$REPO/ci/doc-blocks.py" "$REPO/deploy/HOST-REQUIRES.md" "GPU hosts" 1 --commands)
        if ! podman image exists localhost/desktop-container:latest; then
            line=$(ask "The desktop image is not loaded. Path to its tarball (podman save output), to podman load:")
            run_documented "podman load -i $line" "the image, loaded" || return 1
        fi
        ev_save image "EV-STATE: podman images: the desktop image" podman images >/dev/null || true
        mapfile -t apply < <(python3 "$REPO/ci/doc-blocks.py" "$REPO/deploy/README.md" "Apply" 1 --commands | cut -f1)
        ev_text apply "EV-PROCEDURE: deploy/README.md's \"Apply\" block, as this run read it" "$(printf '%s\n' "${apply[@]}")"
        for line in "${apply[@]}"; do
            [ "$line" = reboot ] && break
            run_documented "$line" "deploy/README.md, Apply" || return 1
        done
        echo booted > "$phase_f"
        ev_note "the documented commands ran; rebooting with the block's last command: run 'run S10.1.6' after the boot"
        ev_end
        say "Rebooting (the Apply block's last command). Run 'run S10.1.6' again after the boot."
        (cd "$REPO" && reboot)
        ;;
    booted)
        ev_begin S10.1.6 "A GPU host provisioned from the documentation comes up accelerated on its first boot" T4
        if wait_desktop 120; then ev_pass "the desktop is up on the first boot"; else ev_fail "the desktop is not up on the first boot"; fi
        gpu_mode_checks
        hpf=$(ev_save host-preflight "EV-STATE: desktop-preflight on the host" desktop-preflight) || true
        if grep -q 'done: 0 FAIL' <<<"$hpf"; then ev_pass "the host preflight: 0 FAILs"; else ev_fail "the host preflight has FAILs: $(grep -m1 'FAIL:' <<<"$hpf")"; fi
        # An absence: read once xorg-gpu-conf's decision, which follows the
        # preflight's lines, is in the log.
        log_wait 60 2 'xorg-gpu-conf: decision:' podman logs desktop >/dev/null || true
        cpf=$(ev_save ctr-preflight "EV-LOG-DESKTOP: the container preflight" sh -c 'podman logs desktop 2>&1 | grep preflight:') || true
        if ! grep -q 'preflight: FAIL:' <<<"$cpf"; then ev_pass "the container preflight: 0 FAILs"; else ev_fail "the container preflight has FAILs: $(grep -m1 'FAIL:' <<<"$cpf")"; fi
        observe "the desktop came up on its own after the documented reboot, accelerated, with no step beyond the documents"
        media EV-PHOTO desktop "the desktop on the first boot"
        rm -f "$phase_f"
        ev_end
        ;;
    esac
}
# One documented command, as written, at this terminal, its transcript kept.
run_documented() { # <command> <where it is from>
    local t rc=0
    t=$(mktemp)
    say "Next, from $2:  $1"
    if ! yes_no "Run it?"; then ev_fail "the tester did not run: $1"; return 1; fi
    if [ -n "$HW_REHEARSE" ]; then ev_note "rehearsal: not run: $1"; rm -f "$t"; return 0; fi
    (cd "$REPO" && script -q -e -c "$1" "$t" < /dev/tty) || rc=$?
    ev_copy "$t" cmd "EV-PROCEDURE: $1 (from $2), run as written at this terminal: its transcript; exit $rc"
    rm -f "$t"
    if [ "$rc" = 0 ]; then ev_pass "\`$1\` exited 0"; else ev_fail "\`$1\` exited $rc"; return 1; fi
}

# --- the command line ----------------------------------------------------------
story_fn() {
    case "$1" in
        S8.1.1|S3.1.1) echo gpu_mode ;;
        S3.1.2|S8.1.4) echo no_xdriver ;;
        S8.1.2) echo stub_toolkit ;;
        S8.1.3) echo no_modeset ;;
        S5.4.3) echo stale_spec ;;
        S8.2.3) echo capture_layout ;;
        S8.2.2) echo "video_cycle S8.2.2 'Physical KVM: video, modesetting and NVIDIA' 'switch the KVM away from this host'" ;;
        S3.4.5) echo "video_cycle S3.4.5 'NVIDIA emission' 'switch the KVM away from this host'" ;;
        S3.10.8) echo "video_cycle S3.10.8 'Physical monitor plug-out and plug-in' 'pull the video cable out of one declared monitor'" ;;
        S8.2.1) echo kvm_input ;;
        S8.3.1|S4.7.12) echo usb_audio ;;
        S8.3.2) echo log_check ;;
        S10.1.6) echo gpu_from_docs ;;
        *) return 1 ;;
    esac
}
usage() { sed -n '2,/^set -uo/p' "$0" | sed '$d; s/^# \{0,1\}//' >&2; }
list() {
    cat >&2 <<'EOF'
The T4 stories (Requirements.md Appendix C). Pairs are one run writing both.
  S8.1.1 S3.1.1    NVIDIA host, toolkit injecting the X driver: GPU mode
  S3.1.2 S8.1.4    NVIDIA host, no X driver injected (staged if the toolkit
                   injects it), then README.md's bind-mount fallback
  S8.1.2           NVIDIA host, toolkit missing (staged): the stub, both
                   preflights FAIL
  S8.1.3           NVIDIA host, nvidia_drm.modeset=0 and no injection (staged;
                   reboots twice, run it three times)
  S5.4.3           NVIDIA host: a stale spec (staged), README.md's remedy
  S8.2.3           desktop-monitors-capture pasted as it is; the EDIDs
  S8.2.2 S3.4.5    a KVM switch cycle with a declared layout (S3.4.5: on an
                   NVIDIA desktop); needs S8.2.3's layout
  S3.10.8          a monitor's cable pulled and put back; the same needs
  S8.2.1           ten KVM switches: typing after the first and the last
  S8.3.1 S4.7.12   a USB headset or DAC, a client playing throughout; the
                   probe image
  S8.3.2           the log bound: 'S8.3.2 sample' daily (cron), 'run S8.3.2'
                   after 48 h or more
  S10.1.6          a stock NVIDIA host from the documents (reboots; run it
                   twice)
EOF
}
pack() {
    local out
    out="$HW_STATE/hw-evidence-$(hostname -s)-$(date -u +%Y%m%dT%H%M%SZ).tar.gz"
    tar -C "$EV_ROOT" -czf "$out" . && echo "$out"
}

[ "$(id -u)" = 0 ] || { echo "acceptance: run as root" >&2; exit 2; }
mkdir -p "$HW_STATE" "$EV_ROOT"
case "${1:-}" in
    list) list ;;
    pack) pack ;;
    S8.3.2)
        [ "${2:-}" = sample ] || { usage; exit 2; }
        EV_SOURCE="$EV_SOURCE; tester: $(tester)"
        log_sample ;;
    run)
        shift
        [ $# -gt 0 ] || { list; exit 2; }
        EV_SOURCE="$EV_SOURCE; tester: $(tester)"
        done_fns=" "
        for s in "$@"; do
            fn=$(story_fn "$s") || { echo "acceptance: no T4 story $s (list shows them)" >&2; exit 2; }
            case "$done_fns" in *" $fn "*) continue ;; esac
            done_fns="$done_fns$fn "
            eval "$fn" || echo "acceptance: $s did not run through; its evidence says why" >&2
            undo_all
        done
        echo "evidence: $EV_ROOT (pack makes a tarball of it)" >&2
        # Each failed check of the stories run, again, last (Requirements.md S9.2.3).
        ev_failures
        ;;
    *) usage; exit 2 ;;
esac
