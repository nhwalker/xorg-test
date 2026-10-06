# shellcheck shell=bash
# The maintainer's journeys (Requirements.md E10), the VM host's half. Sourced
# by vm-e2e.sh for a maint-<journey> shard, once its stock VM is up with the
# repository and the images in /tmp and nothing else done to it. The guest's
# steps (ci/vm/maint-guest.sh, `vm-guest.sh maint <step>`) run the documents'
# own commands; this side watches the screen and listens to the sound card
# around them, and asks vm_fresh_host for another stock host when a journey
# needs one.
#
# A story that fails does not stop the journey where the rest does not depend
# on it: the shard fails at the end, naming every story that failed.

MT_FAILED=""
MT_WHY=()
# A maint step on the guest, its evidence copied back afterwards.
mg() { guest_ev "$GUEST_EV" maint "$@"; }
# A maint step that ends by rebooting the guest: the connection goes with the
# guest, so nothing is copied back now; the next step's copy brings the
# evidence, which waits on the guest's disk.
mg_reboot() { vm_ssh "sudo EV_ROOT=$GUEST_EV EV_SOURCE='$EV_SOURCE' EV_PROFILE=$PROFILE repo/ci/vm/vm-guest.sh maint $*"; }
mt_title() { sed -n "s/^\*\*$1 \(.*\)\*\*\$/\1/p" ../../Requirements.md; }
# The host's half of a story, beside the guest's (the h- files, ci/evlib.py).
mt_open() { EV_SIDE=h-; ev_begin "$1" "$(mt_title "$1")" T3; }
mt_close() { ev_end; EV_SIDE=; }
mt_failed() { # <story> <why>: the story failed; the journey goes on where it can
    MT_FAILED="$MT_FAILED $1"
    MT_WHY+=("$1: $2")
    log "FAIL, and the journey goes on: $1: $2"
    if [ -n "$EV_STORY" ]; then ev_fail "$2"; mt_close; fi
}
mt_unpack() { vm_ssh 'mkdir -p repo && tar -xzf /tmp/repo.tgz -C repo' || fail "could not unpack the repository in the VM"; }

# --- the screen ------------------------------------------------------------------
# The desktop as the operator sees it, in one screendump: the root window's
# colour in the bottom-right corner (#101216, S3.3.3's; MT_ROOT_RGB when an
# image with another one runs) and the session xterm's #16191d well inside its
# 100x30+60+60 window (S3.5.2's).
MT_ROOT_RGB=16,18,22
mt_is_desktop() { # <image>
    local w="" h="" c
    read -r w h < <(identify -format '%w %h\n' "$1" 2>/dev/null) || true
    [ -n "$h" ] || return 1
    # MT_ROOT_RGB may name alternatives, "r,g,b|r,g,b": any of them will do.
    c=$(px "$1" $((w - 12)) $((h - 12)))
    case "|$MT_ROOT_RGB|" in *"|$c|"*) ;; *) return 1 ;; esac
    [ "$(px "$1" 360 260)" = 22,25,29 ]
}
# Follow a recording (ev_video_start) frame by frame until the desktop has
# gone from the screen and come back, for up to <seconds>, looking only at
# the screen: nothing logs in to the guest meanwhile. Sets MT_BACK to the
# first frame showing the desktop again and its UTC time.
MT_BACK=""
mt_wait_screen() { # <video dir> <seconds> [index lines to skip: the frames from before a moment]
    local end=$((SECONDS + $2)) n=${3:-0} m name t gone=0
    MT_BACK=""
    while [ "$SECONDS" -lt "$end" ]; do
        m=$(cat "$1/index.txt" 2>/dev/null | wc -l)
        if [ "$m" -le "$n" ]; then sleep 1; continue; fi
        while read -r name t _; do
            case "$t" in *Z) ;; *) continue ;; esac
            if mt_is_desktop "$1/${name%.png}.ppm"; then
                if [ "$gone" = 1 ]; then MT_BACK="$name $t"; return 0; fi
            else
                gone=1
            fi
        done < <(sed -n "$((n + 1)),${m}p" "$1/index.txt" 2>/dev/null)
        n=$m
        sleep 1
    done
    return 1
}
# Seconds from <t0> (the host's clock, read just before the command) to the
# frame MT_BACK names.
mt_elapsed() { # <t0 epoch>
    awk -v a="$1" -v b="$(date -d "${MT_BACK#* }" +%s.%N)" 'BEGIN {printf "%.1f", b - a}'
}
# The screen now, as S3.3.3 has it: the root's colour and the xterm's.
mt_screen_check() { # <moment> <what>
    local f
    f=$(ev_name "$1" png)
    python3 qmp-tool.py shot "$QMP" "$EV_DIR/$f" >/dev/null && [ -s "$EV_DIR/$f" ] || return 1
    ev_attach "$f" "$2"
    mt_is_desktop "$EV_DIR/$f" || return 1
    ev_pass "the screen shows the desktop: the root window's colour ($MT_ROOT_RGB) at the bottom-right corner and the session xterm's #16191d inside it ($f)"
}

# --- typing and sound ------------------------------------------------------------
# S3.8.1's probe: a sink xterm, a click into it and a word typed, all through
# QEMU's own devices.
mt_typing() { # <story> <word> [absent]: typed text lands; "absent", that it does not (a fault's symptom)
    local res qlog xd
    xd=$(gq desk xdpyinfo 2>/dev/null) || xd=""
    res=$(awk '/dimensions:/ {print $2; exit}' <<<"$xd")
    [ -n "$res" ] || return 1
    vm_ssh 'sudo repo/ci/vm/vm-guest.sh input-sink-start' || return 1
    sleep 2
    mt_open "$1"
    qlog=$(ev_name qmp-input txt)
    QMP_TRANSCRIPT="$EV_DIR/$qlog" python3 qmp-type.py "$QMP" "$res" 550 395 "$2"
    ev_attach "$qlog" "EV-QEMU: every QMP command sent: the pointer to the sink xterm's centre (550,395 on $res), a click to focus it, then the keys of '$2' and Return"
    sleep 2
    ev_shot typed "EV-SHOT: the sink xterm (title inputtest) right after the keystrokes"
    if vm_ssh "sudo repo/ci/vm/vm-guest.sh input-sink-check $2"; then
        if [ "${3:-}" = absent ]; then
            ev_fail "typed text still lands: the focused xterm's shell read '$2'"
            mt_close
            return 1
        fi
        ev_pass "the focused xterm's shell read '$2', typed through QEMU's keyboard (S3.8.1)"
        mt_close
        return 0
    fi
    if [ "${3:-}" = absent ]; then
        ev_pass "the symptom: the click and the keys of '$2' did not land, no shell read it"
        mt_close
        return 0
    fi
    ev_fail "the focused xterm's shell did not read '$2'"
    mt_close
    return 1
}
# A pulse tone from the session (S4.1.2's paplay, as the desktop user in the
# container), captured from the machine's sound card.
mt_tone() { # <story> <tag> <hz>
    local st=""
    mt_open "$1"
    ev_audio_start "$2" "$3"
    gq tone-start "$2" "$3" 3 - >/dev/null || { audio_capture_stop; ev_fail "could not start the session's $3 Hz player"; mt_close; return 1; }
    for _ in $(seq 15); do
        st=$(gq tone-status "$2" 2>/dev/null | sed -n 1p || true)
        [ "${st%% *}" = exited ] && break
        sleep 1
    done
    ev_save "player-$3" "EV-LOG-CLIENT: the session's player (paplay as the desktop user in the container): its exit status, how long it played, its output" \
        gq tone-status "$2" >/dev/null || true
    if ev_audio_stop "EV-AUDIO: the machine's output while the session played a $3 Hz tone through PipeWire's pulse server" 2 0.05 "$3"; then
        ev_pass "the session's $3 Hz pulse tone is heard"
        mt_close
        return 0
    fi
    ev_fail "the session's $3 Hz pulse tone was not heard"
    mt_close
    mg audio-diag "$1" || true
    return 1
}

# --- F10.1: a stock host provisioned from the documents ---------------------------
# deploy/HOST-REQUIRES.md's line, the image, deploy/README.md's Apply block
# with its reboot, and the first boot watched from QEMU's side until the
# desktop shows; then the read-only probes, the typing and the sound.
mt_provision() { # took|skipped: S10.1.3's restorecon line
    local vid t0 lines b0 b1 took
    mg packages || fail "S10.1.1: the documented package line did not provision the host"
    mg image || fail "S10.1.2: the desktop image could not be loaded"
    mt_open S10.1.2
    ev_shot stock "EV-SHOT: the stock host's screen before the tree: the image's own login prompt on tty1"
    EV_VID_FPS=1 ev_video_start first-boot
    vid="$EV_DIR/$EV_VID"
    mt_close
    lines=$(wc -l < "$VM_SERIAL")
    b0=$(vm_ssh_quick 'cat /proc/sys/kernel/random/boot_id' 2>/dev/null | tail -n1)
    # The step ends in the block's own reboot. Exit 1 is the step failing
    # before it got there; anything else is the connection going with the
    # guest.
    mg_reboot apply "$1" && took=0 || took=$?
    t0=$(date +%s.%N)
    [ "$took" != 1 ] || { ev_pull; fail "S10.1.2: deploy/README.md's Apply block failed before its reboot"; }
    log "the Apply block's reboot is under way: watching the screen, without logging in, until the desktop shows"
    if ! mt_wait_screen "$vid" 300; then
        mt_open S10.1.2
        ev_video_stop "EV-VIDEO: the screen from before the reboot for 300 s: the desktop never appeared"
        ev_text serial "EV-LOG: the serial console from the reboot on" "$(tail -n +"$((lines + 1))" "$VM_SERIAL")"
        mt_close
        fail "S10.1.2: 300 s after the Apply block's reboot the desktop is not on the screen"
    fi
    sleep 3
    mt_open S10.1.2
    ev_video_stop "EV-VIDEO: the screen at 1 fps from before the Apply block's reboot until the desktop was on it; index.txt gives each frame's UTC time"
    ev_note "time to desktop: $(mt_elapsed "$t0") s from the reboot (the host's clock when the Apply step's connection ended, which the reboot ended) to the first frame showing the desktop, ${MT_BACK%% *} at ${MT_BACK#* }; nobody had logged in to the host by then"
    ev_text serial "EV-LOG: the serial console from the Apply block's reboot until the desktop was on the screen" "$(tail -n +"$((lines + 1))" "$VM_SERIAL")"
    b1=$(vm_ssh_quick 'cat /proc/sys/kernel/random/boot_id' 2>/dev/null | tail -n1)
    [ -n "$b1" ] && [ "$b1" != "$b0" ] || fail "S10.1.2: the VM did not reboot (boot id ${b1:-unreadable}, before $b0)"
    ev_pass "the VM rebooted (boot id $b0 -> $b1), and the desktop came on the screen with nobody logged in"
    mt_screen_check after-boot "EV-SHOT: the screen on the first boot: the #101216 root, the session's xterm in mwm's frame" \
        || fail "S10.1.2: the screen does not show the desktop on the first boot"
    mt_close
    mg firstboot || fail "S10.1.2: the first boot did not bring the host to the documented end state"
    mt_typing S10.1.2 firstbootok || fail "S10.1.2: typed text did not reach the focused xterm on the first boot"
    mt_tone S10.1.2 mt-first 660 || fail "S10.1.2: the session's pulse tone was not heard on the first boot"
}

# S10.1.1's host clients: an ordinary user's paplay and aplay, heard.
mt_host_clients() {
    local tool hz probe
    for tool in paplay aplay; do
        hz=440
        [ "$tool" = aplay ] && hz=1320
        mt_open S10.1.1
        ev_audio_start "$tool" "$hz"
        ev_save "$tool" "EV-STATE: $tool of a $hz Hz tone as rocky, an ordinary host user, with a clean environment: its output and exit status" \
            vm_ssh "sudo repo/ci/vm/vm-guest.sh maint host-play $tool" >/dev/null || true
        probe=$(ev_payload "$EV_DIR/$EV_LAST")
        if ev_audio_stop "EV-AUDIO: the machine's output while rocky's $tool played $hz Hz" 2 0.05 "$hz" \
            && grep -q "^$tool exited 0\$" <<<"$probe"; then
            ev_pass "rocky's $tool, with nothing set in its environment, exited 0 and its $hz Hz tone was heard"
            mt_close
        else
            mt_failed S10.1.1 "rocky's $tool tone was not heard, or $tool failed: $(grep "^$tool exited" <<<"$probe")"
        fi
    done
}

# --- F10.2: the documents' checklists, on a host in use ---------------------------
# A screendump QEMU writes raw (PPM) and this side converts: a PNG one is
# compressed in QEMU's main loop, where the sound card runs, and costs a
# capture running across it 46 ms of sound (qmp-tool.py).
mt_shot_quiet() { # <moment> <what>
    local png ppm
    png=$(ev_name "$1" png)
    ppm="${EV_DIR:?}/.${png%.png}.ppm"
    if python3 qmp-tool.py hmp "$QMP" "screendump $ppm" >/dev/null && convert "$ppm" "$EV_DIR/$png" 2>/dev/null; then
        ev_attach "$png" "$2"
    else
        ev_note "the screendump $1 was not produced"
    fi
    rm -f "$ppm"
}
# A capture with no pitch to check (the checklist's audio lines play a voice
# sample): check-audio.py's duration and level alone. 0 when it was heard.
mt_heard() { # <wav name in the open story> <what>
    local rep rc=0
    audio_capture_stop
    [ -s "$EV_DIR/$1" ] || { ev_note "no capture was written for: $2"; return 1; }
    ev_attach "$1" "$2"
    rep=$(ev_name "${1%.wav}-verdict" txt)
    python3 check-audio.py --report "$EV_DIR/$rep" "$EV_DIR/$1" 0.8 0.02 || rc=$?
    [ -s "$EV_DIR/$rep" ] && ev_attach "$rep" "check-audio.py's verdict on $1: its duration and peak level (no pitch: the line plays a voice sample)"
    return "$rc"
}

# S10.2.1 and S10.2.2: both checklists, every line as written, on the
# provisioned host, with a client of the desktop's running throughout: its
# xterm on the screen and a tone that must not stop. Then each audio line of
# the README checklist again, alone, so it can be heard.
mt_verify() {
    local tone=90 tool v wav probe judged
    log "S10.2.1, S10.2.2: the two verification checklists as written, on the provisioned host, with a client running"
    mg checklist-tools || fail "S10.2.1: could not install the checklist's own probe"
    mt_open S10.2.2
    ev_shot before "EV-SHOT: the screen before the client and the checklists"
    ev_audio_start client 330
    mt_close
    mg quiet start "$tone" || { audio_capture_stop; fail "S10.2.2: the client did not start"; }
    mt_open S10.2.2
    mt_shot_quiet client-up "EV-SHOT (raw, so the capture runs on undisturbed): the client's xterm (mt-client) on the screen, before the checklists"
    mt_close
    mg quiet state before || { audio_capture_stop; fail "S10.2.2: could not record the state before the checklists"; }
    mg checklist readme || mt_failed S10.2.1 "README.md's checklist did not run through"
    mg checklist deploy || mt_failed S10.2.1 "deploy/README.md's checklist did not run through"
    mg quiet state after || mt_failed S10.2.2 "the state after the checklists differs, or could not be recorded"
    mt_open S10.2.2
    mt_shot_quiet client-after "EV-SHOT (raw): the screen after the checklists, the client's xterm still on it"
    mt_close
    mg quiet ended || mt_failed S10.2.2 "the client's player did not play its tone through"
    mt_open S10.2.2
    if ev_audio_stop "EV-AUDIO: the machine's output from before the client's ${tone} s 330 Hz tone began until it ended, both checklists run meanwhile: it must not stop" \
        $((tone - 10)) 0.05 330 --max-gap 0.3 --span $((tone - 2)) $((tone + 2)); then
        ev_pass "the client's 330 Hz tone played through both checklists for its whole ${tone} s, with no gap longer than 0.3 s"
        ev_shot after "EV-SHOT: the screen once the client's tone ended"
        mt_close
    else
        mt_failed S10.2.2 "the client's tone was interrupted while the checklists ran"
    fi
    mg quiet remove || true
    for tool in pw-play paplay aplay; do
        for v in written met container; do
            # aplay's comment names no condition to meet.
            [ "$tool:$v" != aplay:met ] || continue
            judged=no
            case "$tool:$v" in pw-play:met|paplay:met|aplay:written) judged=yes ;; esac
            mt_open S10.2.1
            wav=$(ev_name "$tool-$v" wav)
            mon_cmd "wavcapture $EV_DIR/$wav snd0 44100 16 2"
            sleep 1
            ev_save "$tool-$v" "EV-STATE: the README checklist's $tool line ($v): what it printed and its exit status" \
                vm_ssh "sudo repo/ci/vm/vm-guest.sh maint checklist-play $tool $v" >/dev/null || true
            probe=$(ev_payload "$EV_DIR/$EV_LAST")
            if mt_heard "$wav" "EV-AUDIO: the machine's output while the README checklist's $tool line ran ($v)" \
                && grep -q '^exited 0$' <<<"$probe"; then
                if [ "$judged" = yes ]; then ev_pass "README checklist, $tool ($v): it exited 0 and was heard"
                else ev_note "README checklist, $tool ($v), recorded and not judged: it exited 0 and was heard"; fi
            elif [ "$judged" = yes ]; then
                ev_fail "README checklist, $tool ($v): not heard, or it failed ($(grep '^exited' <<<"$probe"))"
            else
                ev_note "README checklist, $tool ($v), recorded and not judged: not heard, or it failed ($(grep '^exited' <<<"$probe"))"
            fi
            mt_close
        done
    done
}

# A guest step that restarts the desktop, watched from QEMU's side: the
# screen recorded from the command until the desktop is back, the time it
# took, and a look at it once it is.
mt_watch() { # <story> <moment> <guest step...>
    local story=$1 moment=$2 vid t0
    shift 2
    mt_open "$story"
    ev_shot "before-$moment" "EV-SHOT: the screen right before '$*' ($moment)"
    ev_video_start "$moment"
    vid="$EV_DIR/$EV_VID"
    mt_close
    t0=$(date +%s.%N)
    if ! mg "$@"; then
        mt_open "$story"
        ev_video_stop "EV-VIDEO: the screen while '$*' failed"
        mt_failed "$story" "$moment: '$*' failed"
        return 1
    fi
    if ! mt_wait_screen "$vid" 180; then
        mt_open "$story"
        ev_video_stop "EV-VIDEO: the screen for 180 s from '$*': the desktop did not come back"
        mt_failed "$story" "$moment: 180 s after '$*' the desktop is not back on the screen"
        return 1
    fi
    sleep 2
    mt_open "$story"
    ev_video_stop "EV-VIDEO: the screen from '$*' until the desktop was back ($moment); index.txt gives each frame's UTC time"
    ev_note "$moment: the desktop was back on the screen $(mt_elapsed "$t0") s after the command (${MT_BACK%% *} at ${MT_BACK#* })"
    if ! mt_screen_check "$moment" "EV-SHOT: the screen once the desktop was back ($moment)"; then
        mt_failed "$story" "$moment: the screen does not show the desktop"
        return 1
    fi
    mt_close
}
# The same wait without a recording, for a boot nothing keeps evidence of.
mt_wait_quiet() { # <seconds>
    local end=$((SECONDS + $1)) f=.quiet-shot.png gone=0
    while [ "$SECONDS" -lt "$end" ]; do
        if python3 qmp-tool.py shot "$QMP" "$PWD/$f" >/dev/null 2>&1 && [ -s "$f" ]; then
            if mt_is_desktop "$f"; then
                [ "$gone" = 0 ] || { rm -f "$f"; return 0; }
            else
                gone=1
            fi
        fi
        sleep 3
    done
    rm -f "$f"
    return 1
}
# A host provisioned the documented way for a journey that starts after it:
# mt_provision's steps with no evidence kept (the docpath journey keeps it).
mt_provision_quiet() {
    local took
    guest_ev "" maint packages || fail "the documented package line did not provision the host"
    guest_ev "" maint image || fail "the desktop image could not be loaded"
    vm_ssh "sudo repo/ci/vm/vm-guest.sh maint apply skipped" && took=0 || took=$?
    [ "$took" != 1 ] || fail "deploy/README.md's Apply block failed before its reboot"
    mt_wait_quiet 300 || fail "300 s after the Apply block's reboot the desktop is not on the screen"
    vm_ssh 'sudo repo/ci/vm/vm-guest.sh x-up' || fail "the desktop is on the screen, but X or mwm does not answer"
}

# --- F10.3: a running host's configuration, changed the documented ways -----------
# A new tone from S10.3.3's client after a switch (S7.8.1), heard.
mt_upc_heard() { # <moment> <hz>
    local probe
    mt_open S10.3.3
    ev_audio_start "client-$1" "$2"
    ev_save "client-tone-$1" "EV-LOG-CLIENT: a new tone from the client ($1): its player's output and exit status" \
        vm_ssh "sudo repo/ci/vm/vm-guest.sh maint upc-tone $2" >/dev/null || true
    probe=$(ev_payload "$EV_DIR/$EV_LAST")
    if ev_audio_stop "EV-AUDIO: the machine's output while the client played a new $2 Hz tone ($1)" 2 0.05 "$2" \
        && grep -q '^paplay exited 0$' <<<"$probe"; then
        ev_pass "a new $2 Hz tone from the client is heard ($1): the client works against the restarted desktop (S7.8.1)"
        mt_close
    else
        mt_failed S10.3.3 "$1: the client's new tone was not heard, or its player failed"
    fi
}

maint_config() {
    local c route dir want
    log "maintainer, host C: provisioned the documented way, then its configuration changed the documented ways (F10.3)"
    mt_unpack
    mt_provision_quiet
    log "S10.3.1: capture the autodetected arrangement, paste it, restart"
    mg before S10.3.1 autodetected || fail "S10.3.1: could not record the state before the capture"
    mg layout-capture || fail "S10.3.1: the capture could not be pasted"
    if mt_watch S10.3.1 pinned svc S10.3.1 restart; then
        mg after S10.3.1 autodetected pinned || mt_failed S10.3.1 "the desktop came back other than whole: see the guest's checks"
    fi
    mg layout-pinned || mt_failed S10.3.1 "the pinned layout is not the captured one, or it did not hold"
    log "S10.3.2: layouts the maintainer gets wrong, and every global keyword the documents offer"
    for c in malformed unknown virtual nvidia-connected nvidia-edid restore; do
        mg before S10.3.2 "before-$c" || { mt_failed S10.3.2 "the case $c: could not record the state before it"; continue; }
        mg layout-case "$c" || { mt_failed S10.3.2 "the case $c could not be written"; continue; }
        if mt_watch S10.3.2 "$c" svc S10.3.2 restart; then
            mg after S10.3.2 "before-$c" "after-$c" || mt_failed S10.3.2 "the case $c: the desktop came back other than whole"
        fi
        # Run whatever the screen showed: its log slices say what the
        # maintainer would have read.
        mg layout-case-check "$c" || mt_failed S10.3.2 "the case $c"
    done
    log "S10.3.4: the image the unit names, gone; then loaded back"
    mg before S10.3.4 running || fail "S10.3.4: could not record the state before the image went"
    if mg image-gone; then
        mt_open S10.3.4
        ev_shot gone "EV-SHOT: the screen with the image gone and the restart failed: no desktop"
        mt_close
    else
        mt_failed S10.3.4 "with the image gone, desktop.service or desktop-preflight did not behave as documented"
    fi
    mg image-load || fail "S10.3.4: the image could not be loaded back"
    if mt_watch S10.3.4 back svc S10.3.4 restart; then
        mg after S10.3.4 running back || mt_failed S10.3.4 "the desktop came back other than whole: see the guest's checks"
    fi
    mg image-back || mt_failed S10.3.4 "after the load and the restart the host is not whole"
    log "S10.3.3: upgrade to a second image and roll back, by the digest pin and by re-tagging, with a client running"
    mg upgrade-prep || fail "S10.3.3: the second image or the client could not be set up"
    for route in pin tag; do
        for dir in forward back; do
            want=orig
            [ "$dir" = back ] || want=alt
            MT_ROOT_RGB=16,18,22
            [ "$want" = orig ] || MT_ROOT_RGB=43,27,23
            mg before S10.3.3 "before-$route-$dir" || { mt_failed S10.3.3 "$route $dir: could not record the state before it"; continue; }
            mg route "$route" "$dir" || { mt_failed S10.3.3 "$route $dir: the change could not be made"; continue; }
            if mt_watch S10.3.3 "$route-$dir" svc S10.3.3 restart; then
                mg after S10.3.3 "before-$route-$dir" "after-$route-$dir" || mt_failed S10.3.3 "$route $dir: the desktop came back other than whole"
            fi
            # Whatever the screen showed, which image runs and what the
            # client sees are the facts that say why.
            mg route-check "$want" "$route" || { mt_failed S10.3.3 "$route $dir: not the $want image, or the client did not carry on"; continue; }
            mt_upc_heard "$route-$dir" 550
        done
    done
    MT_ROOT_RGB=16,18,22
    mg upgrade-done || true
}

# --- F10.3, in the operator's session: Host Terminal off and on, look and feel ------
# One step of the operator's half (operator-e2e.py --maint): a menu entry
# chosen through QEMU's own devices and the screen read, into the h- files of
# the step's story. It looks at X from a confined observer container, which a
# boot takes away with the desktop.
mt_op() { # <step> [arg] [out file]
    python3 operator-e2e.py --qmp "$QMP" --ssh-port "$SSHPORT" --ssh-key id_ed25519 --art "$EV_ROOT" \
        --maint "$1" --arg "${2:-}" --out "${3:-}"
}
mt_observer() { vm_ssh 'sudo repo/ci/vm/vm-guest.sh operator-setup' || fail "the operator's observer could not start"; }

# S10.3.5, then S10.3.6 from the state S10.3.5 should have left.
mt_hostterm() {
    local vid t0 lines rc out cmd
    log "S10.3.5: Host Terminal switched off the documented way, on a host where it works"
    mg before S10.3.5 on || { mt_failed S10.3.5 "could not record the state before the switch"; return 1; }
    mg hostterm-before || { mt_failed S10.3.5 "Host Terminal does not work before the switch"; return 1; }
    mt_op hostterm-works || mt_failed S10.3.5 "before the switch, 'Host Terminal' did not open a shell on the host"
    mt_open S10.3.5
    ev_shot before-switch "EV-SHOT: the screen before the switch"
    EV_VID_FPS=1 ev_video_start switch-reboot
    vid="$EV_DIR/$EV_VID"
    mt_close
    lines=$(wc -l < "$VM_SERIAL")
    # The step ends in the reboot: exit 1 is the step failing before it.
    mg_reboot hostterm-switch && rc=0 || rc=$?
    t0=$(date +%s.%N)
    if [ "$rc" = 1 ]; then
        ev_pull
        mt_open S10.3.5
        ev_video_stop "EV-VIDEO: the screen while the switch failed"
        mt_failed S10.3.5 "the switch could not be applied"
        return 1
    fi
    log "the switch's reboot is under way: watching the screen until the desktop is back"
    if ! mt_wait_screen "$vid" 300; then
        mt_open S10.3.5
        ev_video_stop "EV-VIDEO: the screen from before the switch's reboot for 300 s: the desktop never came back"
        ev_text serial "EV-LOG: the serial console from the reboot on" "$(tail -n +"$((lines + 1))" "$VM_SERIAL")"
        mt_failed S10.3.5 "300 s after the switch's reboot the desktop is not on the screen"
        return 1
    fi
    sleep 3
    mt_open S10.3.5
    ev_video_stop "EV-VIDEO: the screen at 1 fps from before the switch's reboot until the desktop was back; index.txt gives each frame's UTC time"
    ev_note "time to desktop: $(mt_elapsed "$t0") s from the reboot to the first frame showing the desktop, ${MT_BACK%% *} at ${MT_BACK#* }"
    if ! mt_screen_check after-reboot "EV-SHOT: the screen after the switch and the reboot: the desktop, the rest of it unaffected"; then
        mt_failed S10.3.5 "the screen does not show the desktop after the switch and the reboot"
        return 1
    fi
    mt_close
    vm_ssh 'sudo repo/ci/vm/vm-guest.sh x-up' || { mt_failed S10.3.5 "the desktop is on the screen, but X or mwm does not answer"; return 1; }
    mt_observer
    mg after S10.3.5 on off || mt_failed S10.3.5 "the desktop came back other than whole after the switch's reboot"
    mg hostterm-after || mt_failed S10.3.5 "the host's checks after the switch could not run"
    mt_op hostterm-refused || mt_failed S10.3.5 "after the switch, 'Host Terminal' did not show its failure text"

    log "S10.3.6: Host Terminal on again, from its own failure screen"
    mg before S10.3.6 off || { mt_failed S10.3.6 "could not record the state before"; return 1; }
    mg hostterm-strip || { mt_failed S10.3.6 "could not reach S10.3.5's intended end state"; return 1; }
    mt_watch S10.3.6 stripped svc S10.3.6 restart || return 1
    mg after S10.3.6 off stripped || mt_failed S10.3.6 "the desktop came back other than whole"
    mg hostterm-start-state || { mt_failed S10.3.6 "the start state is not S10.3.5's intended one"; return 1; }
    out="$PWD/.hostterm-command"
    rm -f "${out:?}"
    mt_op hostterm-screen "" "$out" || mt_failed S10.3.6 "the failure screen did not show, or gave no command"
    cmd=$(cat "$out" 2>/dev/null || true)
    [ -n "$cmd" ] || { mt_failed S10.3.6 "no command was read off the failure screen"; return 1; }
    log "the failure screen says to run, on the host: $cmd"
    mg hostterm-enable "$(printf '%s' "$cmd" | base64 -w0)" || mt_failed S10.3.6 "the screen's command could not be run"
    mt_op hostterm-prompt || mt_failed S10.3.6 "after the screen's command, 'Host Terminal' still gave no shell on the host"
    mg hostterm-journal || true
}

# S10.3.7. The colours are hex without '#': a word starting with one is a
# comment to the shell that runs a guest step.
MT_LF_TERM=1f2f22           # XTerm*background, edited from #16191d
MT_LF_MENU=2f2219           # Mwm*menu*background, edited from #22262d
MT_LF_ROOT=1b2b17           # the root colour of the rebuilt image: 27,43,23
mt_look() {
    log "S10.3.7: the look-and-feel loops, as README.md gives them"
    mg before S10.3.7 look || { mt_failed S10.3.7 "could not record the state before"; return 1; }
    mt_op menu-look before || mt_failed S10.3.7 "the root menu could not be measured"
    log "S10.3.7: ~/.mwmrc edited in the running container, then Restart mwm"
    mg lf-mwmrc || { mt_failed S10.3.7 "the container's .mwmrc could not be edited"; return 1; }
    mt_op restart-mwm 1 || mt_failed S10.3.7 "Restart mwm did not restart mwm in the same X session"
    mt_op menu-look after-mwmrc || mt_failed S10.3.7 "the edited label is not on the root menu after Restart mwm"
    log "S10.3.7: ~/.Xdefaults edited, then the next xterm and Restart mwm, as README.md says"
    mg lf-xdefaults "$MT_LF_TERM" "$MT_LF_MENU" || mt_failed S10.3.7 "the container's .Xdefaults could not be edited"
    mt_op new-xterm "#$MT_LF_TERM" || mt_failed S10.3.7 "the next xterm does not draw the edited background"
    mt_op menu-look after-xdefaults || mt_failed S10.3.7 "the root menu could not be measured before Restart mwm"
    mt_op restart-mwm 2 || mt_failed S10.3.7 "Restart mwm did not restart mwm in the same X session"
    mt_op menu-look after-restart-2 || mt_failed S10.3.7 "after Restart mwm the root menu does not draw the edited Mwm*menu*background"
    log "S10.3.7: a repo file changed, rebuilt and deployed the way README.md says"
    MT_LF_RESTARTED=0
    mt_rebuild || true
    if [ "$MT_LF_RESTARTED" = 1 ]; then
        mg after S10.3.7 look rebuilt || mt_failed S10.3.7 "the desktop came back other than whole after the rebuild loop's restart"
    fi
}
# README.md's rebuild block, run as an unprivileged maintainer would run it:
# rocky, with sudo, as the block's own `sudo` implies, in its checkout with
# one repo file changed. The build stops the block if it fails.
mt_rebuild() {
    local raw line n=0 rc vid t0 built rgb w h f
    local -a cmds
    mt_open S10.3.7
    VM_SSH_TIMEOUT=600 ev_save rebuild-bases "EV-PROCEDURE: harness-only, not a documented step: the images an earlier documented build leaves in root's storage (README.md \"Base image vs application layer\", as root: desktop-container-base, and the screenshot image the Containerfile's tools stage needs), loaded rather than rebuilt: sudo podman load" \
        vm_ssh 'sudo podman load -i /tmp/images-desktop-base.tar && sudo podman load -i /tmp/images-screenshot.tar' >/dev/null \
        || { mt_failed S10.3.7 "the bases could not be loaded into root's storage"; return 1; }
    ev_save repo-edit "EV-PROCEDURE: the repo-file change the loop starts from (README.md: \"edit the file in image/session/\"): image/session/xinitrc.desktop's root colour, #101216 -> #$MT_LF_ROOT, in rocky's checkout (sed, standing in for an editor)" \
        vm_ssh "cd repo && cp image/session/xinitrc.desktop /tmp/xinitrc.desktop.orig && sed -i 's/#101216/#$MT_LF_ROOT/' image/session/xinitrc.desktop && { diff -u /tmp/xinitrc.desktop.orig image/session/xinitrc.desktop; grep -q '#$MT_LF_ROOT' image/session/xinitrc.desktop; }" >/dev/null \
        || { mt_failed S10.3.7 "the repo file could not be edited"; return 1; }
    raw=$(python3 ../doc-blocks.py ../../README.md "Look and feel" 2) \
        || { mt_failed S10.3.7 "README.md's \"Look and feel\" has no second command block: $raw"; return 1; }
    ev_text rebuild-block "EV-PROCEDURE: README.md \"Look and feel\"'s rebuild block, as this run read it; each command follows, run as written by rocky in its checkout" "$raw"
    mapfile -t cmds < <(python3 ../doc-blocks.py ../../README.md "Look and feel" 2 --commands | cut -f1)
    for line in "${cmds[@]}"; do
        n=$((n + 1)) rc=0
        case "$line" in
            *"systemctl restart desktop.service"*)
                ev_shot before-restart "EV-SHOT: the screen right before \`$line\`"
                ev_video_start rebuild-restart
                vid="$EV_DIR/$EV_VID"
                t0=$(date +%s.%N)
                MT_LF_RESTARTED=1
                ev_save "rebuild-$n" "EV-PROCEDURE: \`$line\`, as written, by rocky in its checkout: its output and exit status" \
                    vm_ssh "cd repo && $line" >/dev/null || rc=$?
                # Whichever image comes back, the old root colour or the
                # rebuilt one: which it is, is the check below.
                MT_ROOT_RGB='16,18,22|27,43,23'
                if [ "$rc" = 0 ] && mt_wait_screen "$vid" 180; then
                    sleep 2
                    ev_video_stop "EV-VIDEO: the screen from \`$line\` until the desktop was back; index.txt gives each frame's UTC time"
                    ev_note "the desktop was back $(mt_elapsed "$t0") s after \`$line\` (${MT_BACK%% *} at ${MT_BACK#* })"
                    ev_pass "\`$line\` exited 0 and the desktop came back"
                else
                    ev_video_stop "EV-VIDEO: the screen for up to 180 s from \`$line\`"
                    ev_fail "\`$line\` exited $rc, or the desktop did not come back within 180 s"
                fi
                MT_ROOT_RGB=16,18,22
                ;;
            *)
                VM_SSH_TIMEOUT=1200 ev_save "rebuild-$n" "EV-PROCEDURE: \`$line\`, as written, by rocky in its checkout: its output and exit status" \
                    vm_ssh "cd repo && $line" >/dev/null || rc=$?
                if [ "$rc" != 0 ]; then
                    ev_fail "\`$line\` exited $rc, so the block stops there: $(tail -n 3 "$EV_DIR/$EV_LAST" | sed -n '1,2p' | tr '\n' ' ')"
                    break
                fi
                ev_pass "\`$line\` exited 0"
                ;;
        esac
    done
    f=$(ev_name rebuilt png)
    if python3 qmp-tool.py shot "$QMP" "$EV_DIR/$f" >/dev/null && [ -s "$EV_DIR/$f" ]; then
        ev_attach "$f" "EV-SHOT: the screen after README.md's rebuild loop; the root colour is sampled 12 px in from its bottom-right corner"
        read -r w h < <(identify -format '%w %h\n' "$EV_DIR/$f" 2>/dev/null) || true
        rgb=$(px "$EV_DIR/$f" $((w - 12)) $((h - 12)))
        if [ "$rgb" = 27,43,23 ]; then
            ev_pass "the rebuilt image's root colour, #$MT_LF_ROOT, is on the screen after README.md's loop"
        else
            ev_fail "after README.md's loop the root colour is $rgb, not the rebuilt image's #$MT_LF_ROOT (27,43,23)"
        fi
    else
        ev_fail "no screendump after README.md's loop"
    fi
    ev_save root-images "EV-STATE: root's podman storage after the loop: its images, and the id of its localhost/desktop-container:latest, the one the README's build made" \
        vm_ssh "sudo podman images; sudo podman image inspect --format '{{.Id}} {{.Created}}' localhost/desktop-container:latest" >/dev/null || true
    built=$(vm_ssh "sudo podman image inspect --format '{{.Id}}' localhost/desktop-container:latest" 2>/dev/null | tail -n 1)
    mt_close
    if [ -n "$built" ]; then
        mg lf-image "$built" || mt_failed S10.3.7 "the image check could not run"
    else
        mt_failed S10.3.7 "README.md's build left no localhost/desktop-container:latest in root's storage"
    fi
}

maint_session() {
    log "maintainer, host D: provisioned the documented way; Host Terminal switched off and on, and the look-and-feel loops (S10.3.5-S10.3.7)"
    mt_unpack
    mt_provision_quiet
    mt_observer
    mt_hostterm || true
    mt_look || true
}

# --- F10.5: documented faults, staged on a working host -----------------------------
# The symptom at the screen: <seconds> after the fault, no desktop.
mt_no_desktop() { # <story> <moment> <seconds>
    local f
    sleep "$3"
    mt_open "$1"
    f=$(ev_name "$2" png)
    if python3 qmp-tool.py shot "$QMP" "$EV_DIR/$f" >/dev/null && [ -s "$EV_DIR/$f" ]; then
        ev_attach "$f" "EV-SHOT: the screen $3 s after the fault: what the operator sees"
        if mt_is_desktop "$EV_DIR/$f"; then
            ev_fail "$3 s after the fault the desktop is still on the screen: the fault did not take"
        else
            ev_pass "the symptom: $3 s after the fault there is no desktop on the screen"
        fi
    else
        ev_fail "no screendump of the symptom"
    fi
    mt_close
}
mt_shot() { # <story> <moment> <what>
    mt_open "$1"
    ev_shot "$2" "$3"
    mt_close
}

mt_fault_drm() {
    local vid n0 t0
    log "S10.5.1: a host process holding DRM master"
    mg before S10.5.1 running || { mt_failed S10.5.1 "could not record the state before the fault"; return 1; }
    mt_open S10.5.1
    ev_shot before "EV-SHOT: the screen before the fault"
    EV_VID_FPS=1 ev_video_start drm
    vid="$EV_DIR/$EV_VID"
    mt_close
    if ! mg drm-stage; then
        mt_open S10.5.1
        ev_video_stop "EV-VIDEO: the screen while the staging failed"
        mt_failed S10.5.1 "the fault could not be staged"
        return 1
    fi
    mt_no_desktop S10.5.1 symptom 30
    mg drm-diagnose || mt_failed S10.5.1 "the documented first stops and checks could not run"
    n0=$(wc -l < "$vid/index.txt" 2>/dev/null || echo 0)
    t0=$(date +%s.%N)
    mg drm-remedy || { mt_failed S10.5.1 "the holder could not be killed"; return 1; }
    if mt_wait_screen "$vid" 60 "$n0"; then
        sleep 2
        mt_open S10.5.1
        ev_video_stop "EV-VIDEO: the screen at 1 fps from before the fault until the desktop was back; index.txt gives each frame's UTC time"
        ev_note "the desktop was back $(mt_elapsed "$t0") s after the kill, with no other command (${MT_BACK%% *} at ${MT_BACK#* })"
        ev_pass "with the holder gone, the desktop came back by itself: no reboot, no service restart"
        mt_screen_check recovered "EV-SHOT: the screen once the desktop was back" || ev_fail "the screen does not show the desktop"
        mt_close
    else
        mt_open S10.5.1
        ev_video_stop "EV-VIDEO: the screen at 1 fps from before the fault until 60 s after the kill: the desktop did not come back"
        mt_failed S10.5.1 "60 s after the kill the desktop is not back on the screen"
    fi
    mg drm-after || true
    mg after S10.5.1 running recovered || mt_failed S10.5.1 "the desktop came back other than whole"
}

mt_fault_seat() {
    log "S10.5.2: the session's input devices attached to another seat"
    mg before S10.5.2 running || { mt_failed S10.5.2 "could not record the state before the fault"; return 1; }
    mt_shot S10.5.2 before "EV-SHOT: the screen before the fault"
    mg seat-stage || { mt_failed S10.5.2 "the fault could not be staged"; mg seat-restore || true; return 1; }
    mt_typing S10.5.2 seatgone absent || mt_failed S10.5.2 "typed text still landed with the devices on seat1: the fault did not take"
    mg seat-diagnose || mt_failed S10.5.2 "the entry's check and remedy could not run"
    if ! mt_typing S10.5.2 seatback; then
        mt_failed S10.5.2 "typed text and a click do not land after the entry's remedy"
        mg seat-restore || true
    fi
    mg after-kept S10.5.2 running recovered || mt_failed S10.5.2 "the state after the remedy could not be recorded"
    mt_shot S10.5.2 after "EV-SHOT: the screen after the remedy"
}

mt_fault_selinux() {
    log "S10.5.3: a client-facing directory relabelled under a running client"
    mg before S10.5.3 running || { mt_failed S10.5.3 "could not record the state before the fault"; return 1; }
    mt_shot S10.5.3 before "EV-SHOT: the screen before the fault"
    mg sel-client || { mt_failed S10.5.3 "the client could not be started"; return 1; }
    mg sel-break || mt_failed S10.5.3 "the relabel could not be staged"
    mg sel-diagnose || mt_failed S10.5.3 "the entry's checks and remedy could not run"
    mg after-kept S10.5.3 running recovered || mt_failed S10.5.3 "the state after the remedy could not be recorded"
    mt_shot S10.5.3 after "EV-SHOT: the screen after the remedy: the desktop as it was"
}

mt_fault_gid() {
    local vid t0
    log "S10.5.4: the session user's device group out of step with the host's"
    mg before S10.5.4 running || { mt_failed S10.5.4 "could not record the state before the fault"; return 1; }
    mt_shot S10.5.4 before "EV-SHOT: the screen before the fault"
    mg gid-stage a || { mt_failed S10.5.4 "the fault could not be staged"; return 1; }
    mt_no_desktop S10.5.4 symptom-a 20
    mg gid-diagnose || mt_failed S10.5.4 "the entry's checks could not run"
    log "S10.5.4, path A: systemctl restart desktop.service"
    mt_watch S10.5.4 path-a svc S10.5.4 restart || true
    mg gid-check a || mt_failed S10.5.4 "path A did not give the session back"
    log "S10.5.4, path B: staged again, then the entry's escape hatch"
    mg gid-stage b || { mt_failed S10.5.4 "the fault could not be staged again"; return 1; }
    mt_no_desktop S10.5.4 symptom-b 20
    mt_open S10.5.4
    EV_VID_FPS=1 ev_video_start path-b
    vid="$EV_DIR/$EV_VID"
    mt_close
    t0=$(date +%s.%N)
    mg gid-hatch || mt_failed S10.5.4 "the escape hatch could not be applied"
    if mt_wait_screen "$vid" 90; then
        sleep 2
        mt_open S10.5.4
        ev_video_stop "EV-VIDEO: the screen at 1 fps from the escape hatch until the desktop was back"
        ev_note "the desktop was back $(mt_elapsed "$t0") s after the escape hatch (${MT_BACK%% *} at ${MT_BACK#* })"
        ev_pass "path B: under the escape hatch the next session came up"
        mt_close
    else
        mt_open S10.5.4
        ev_video_stop "EV-VIDEO: the screen at 1 fps for 90 s from the escape hatch: no desktop"
        mt_failed S10.5.4 "path B: 90 s after the escape hatch the desktop is not on the screen"
    fi
    mg gid-check b || mt_failed S10.5.4 "path B: the session is not the escape hatch's"
    log "S10.5.4: the final restart puts the shipped configuration back"
    mt_watch S10.5.4 final svc S10.5.4 restart || true
    mg gid-check final || mt_failed S10.5.4 "the final restart did not put the shipped configuration back"
    mg after S10.5.4 running final || mt_failed S10.5.4 "the desktop came back other than whole"
}

maint_faults() {
    log "maintainer, host E: provisioned the documented way; four README.md Troubleshooting faults staged and recovered (S10.5.1-S10.5.4)"
    mt_unpack
    mt_provision_quiet
    # The ones that should restart nothing first; each restores the host.
    mt_fault_selinux || true
    mt_fault_seat || true
    mt_fault_drm || true
    mt_fault_gid || true
}

# --- F10.4: a restart, and a maintenance stop and start ---------------------------
# What the operator gets back after <command>: the screen recorded from the
# command until the desktop shows, the time it took, the typing and the
# sound, every desktop process new, no login prompt on the way.
mt_back() { # <story> <guest step> <moment before> <moment after> <tag> <word>
    local vid t0 dt
    mt_open "$1"
    ev_shot "before-$2" "EV-SHOT: the screen right before systemctl $2 desktop.service"
    ev_video_start "$2"
    vid="$EV_DIR/$EV_VID"
    mt_close
    t0=$(date +%s.%N)
    if ! mg "$2"; then
        mt_open "$1"
        ev_video_stop "EV-VIDEO: the screen while systemctl $2 desktop.service failed"
        mt_failed "$1" "systemctl $2 desktop.service failed"
        return 1
    fi
    if ! mt_wait_screen "$vid" 180; then
        mt_open "$1"
        ev_video_stop "EV-VIDEO: the screen for 180 s from the command: the desktop did not come back"
        mt_failed "$1" "180 s after the command the desktop is not back on the screen"
        return 1
    fi
    sleep 2
    mt_open "$1"
    ev_video_stop "EV-VIDEO: the screen from the command until the desktop was back; index.txt gives each frame's UTC time"
    dt=$(mt_elapsed "$t0")
    ev_note "time to desktop: $dt s from the command (the host's clock, just before it was sent) to the first frame showing the desktop again, ${MT_BACK%% *} at ${MT_BACK#* }"
    if awk -v d="$dt" 'BEGIN {exit !(d <= 60)}'; then
        ev_note "within the proposed 60 s budget (Requirements.md S10.4.1: confirm it against measured runs before it gates anything)"
    else
        ev_note "over the proposed 60 s budget, which does not gate yet (Requirements.md S10.4.1)"
    fi
    mt_screen_check "$4" "EV-SHOT: the screen with the desktop back" || { mt_failed "$1" "the screen does not show the desktop"; return 1; }
    mt_close
    mg after "$1" "$3" "$4" || { mt_failed "$1" "the desktop came back other than whole: see the guest's checks"; return 1; }
    mt_typing "$1" "$6" || { mt_failed "$1" "typed text did not reach the focused xterm"; return 1; }
    mt_tone "$1" "$5" 660 || { mt_failed "$1" "the session's pulse tone was not heard"; return 1; }
}

mt_routine() {
    log "S10.4.1: a maintainer's restart, and what the operator gets back"
    mg before S10.4.1 running || fail "S10.4.1: could not record the state before the restart"
    mt_back S10.4.1 restart running restarted mt-restart restartok || true
    log "S10.4.2: a maintenance stop, the host it leaves, and the start"
    mg before S10.4.2 running || fail "S10.4.2: could not record the state before the stop"
    mt_open S10.4.2
    ev_shot running "EV-SHOT: the screen before the stop: the desktop"
    mt_close
    if mg stop; then
        mt_open S10.4.2
        ev_shot stopped "EV-SHOT: the screen while the desktop is stopped: no desktop, and no login prompt"
        mt_close
        mg held || mt_failed S10.4.2 "the desktop did not stay stopped, or the host was not quiet, for 120 s"
    else
        mt_failed S10.4.2 "the stop did not leave the seat free and the host quiet"
    fi
    # The start brings S10.4.1's outcome back, whatever the stop did.
    mt_back S10.4.2 start running started mt-start startok || true
}

# --- the journeys ------------------------------------------------------------------
maint_docpath() {
    log "maintainer, host A: the documents' provisioning path, the optional restorecon line skipped (S10.1.1, S10.1.2, S10.1.3)"
    mt_unpack
    mt_provision skipped
    mt_host_clients
    mg selinux skipped || mt_failed S10.1.3 "on the host that skipped the restorecon line, a check failed"
    mt_verify
    mt_routine
    log "maintainer, host B: a second stock host, the same path with the restorecon line taken (S10.1.2, S10.1.3)"
    vm_fresh_host host-b
    mt_unpack
    mt_provision took
    mg selinux took || mt_failed S10.1.3 "on the host that took the restorecon line, a check failed"
    # The two hosts' labels side by side (S10.1.3's EV-DIFF).
    mt_open S10.1.3
    local a b
    a=$(ls "$ART"/S10.1.3/[0-9]*-labels.txt 2>/dev/null | tail -n1 || true)
    b=$(ls "$ART"/host-b/S10.1.3/[0-9]*-labels.txt 2>/dev/null | tail -n1 || true)
    if [ -n "$a" ] && [ -n "$b" ]; then
        ev_copy "$a" labels-host-a "EV-STATE: the same listing on host A, which skipped the restorecon line (copied from its S10.1.3)"
        ev_diff labels-a-b "EV-DIFF: the labels of every installed path, host A (skipped the line, -) against host B (took it, +): where the line made a difference" \
            "$EV_LAST" "$(basename "$b")"
    else
        ev_note "a host's label listing is missing (host A: ${a:-none}, host B: ${b:-none})"
    fi
    mt_close
}

# --- F10.1: the live paths (S10.1.4), and a graphical host converted (S10.1.5) ----
# After a reboot to a screen that is not the desktop (a greeter), ssh tells
# when the host is back.
mt_wait_boot() { # <boot id before the reboot>
    local b
    sleep 15
    for _ in $(seq 60); do
        b=$(vm_ssh_quick 'cat /proc/sys/kernel/random/boot_id' 2>/dev/null | tail -n1 || true)
        [ -n "$b" ] && [ "$b" != "$1" ] && return 0
        sleep 5
    done
    return 1
}

# S10.1.4: one live path on a stock host. The documents' packages and the
# image first (S10.1.1's and S10.1.2's steps; the docpath journey keeps
# their evidence), then the path, watched from QEMU's side until the
# desktop shows, then S10.1.2's end state with no reboot: the read-only
# probes, the typing and a tone.
mt_live_host() { # readme|deploy <word> <hz>
    local vid t0
    guest_ev "" maint packages || fail "S10.1.4: the documented package line did not provision the host"
    guest_ev "" maint image || fail "S10.1.4: the desktop image could not be loaded"
    mt_open S10.1.4
    ev_note "the $1 path's host: provisioned with deploy/HOST-REQUIRES.md's package line and the image loaded (S10.1.1's and S10.1.2's steps; the docpath journey keeps their evidence)"
    ev_shot "stock-$1" "EV-SHOT: the stock host's screen before the $1 path: the image's own login prompt on tty1"
    EV_VID_FPS=1 ev_video_start "live-$1"
    vid="$EV_DIR/$EV_VID"
    mt_close
    t0=$(date +%s.%N)
    mg live "$1" || mt_failed S10.1.4 "the $1 path's step did not run through"
    if ! mt_wait_screen "$vid" 180; then
        mt_open S10.1.4
        ev_video_stop "EV-VIDEO: the screen from the $1 path's first command for 180 s: the desktop never appeared"
        mt_failed S10.1.4 "180 s after the $1 path began the desktop is not on the screen"
        mg live-state "$1" || true
        return 1
    fi
    sleep 3
    mt_open S10.1.4
    ev_video_stop "EV-VIDEO: the screen at 1 fps from the $1 path's first command until the desktop was on it; index.txt gives each frame's UTC time"
    ev_note "the $1 path: the desktop was on the screen $(mt_elapsed "$t0") s after the step began (${MT_BACK%% *} at ${MT_BACK#* }), with no reboot"
    if ! mt_screen_check "live-$1" "EV-SHOT: the screen after the $1 path: the #101216 root, the session's xterm in mwm's frame"; then
        mt_failed S10.1.4 "the screen does not show the desktop after the $1 path"
        return 1
    fi
    mt_close
    mg live-state "$1" || mt_failed S10.1.4 "after the $1 path, the end state could not be checked through"
    mt_typing S10.1.4 "$2" || mt_failed S10.1.4 "after the $1 path, typed text did not reach the focused xterm"
    mt_tone S10.1.4 "mt-live-$1" "$3" || mt_failed S10.1.4 "after the $1 path, the session's pulse tone was not heard"
}
maint_live() {
    log "maintainer, host A: README.md's Install block as written, on a stock host whose sshd is running (S10.1.4)"
    mt_unpack
    mt_live_host readme livereadme 550
    log "maintainer, host B: deploy/README.md's live sequence as written, on another stock host (S10.1.4)"
    vm_fresh_host host-b
    mt_unpack
    mt_live_host deploy livedeploy 770
}

# S10.1.5: a host showing gdm's greeter on tty1, converted live with
# deploy/README.md's sequence; the outcome classified against the two the
# document describes, and the second one's remedy, a reboot, taken if it
# is the one.
maint_gdm() {
    local vid t0 b0 rc outcome shown skip
    log "maintainer: a graphical host, gdm's greeter on tty1, converted live with deploy/README.md's sequence (S10.1.5)"
    mt_unpack
    guest_ev "" maint packages || fail "S10.1.5: the documented package line did not provision the host"
    guest_ev "" maint image || fail "S10.1.5: the desktop image could not be loaded"
    b0=$(vm_ssh_quick 'cat /proc/sys/kernel/random/boot_id' 2>/dev/null | tail -n1)
    mg_reboot gdm-profile && rc=0 || rc=$?
    [ "$rc" != 1 ] || { ev_pull; fail "S10.1.5: the gdm profile could not be applied"; }
    mt_wait_boot "$b0" || fail "S10.1.5: the host did not come back from the profile's reboot"
    mg gdm-greeter || fail "S10.1.5: the host does not show gdm's greeter"
    mt_open S10.1.5
    ev_shot greeter "EV-SHOT: the graphical host's screen before the tree: gdm's greeter"
    EV_VID_FPS=1 ev_video_start greeter-to-desktop
    vid="$EV_DIR/$EV_VID"
    mt_close
    t0=$(date +%s.%N)
    mg gdm-live || mt_failed S10.1.5 "the live sequence's step did not run through"
    if mt_wait_screen "$vid" 150; then shown=desktop; else shown=dark; fi
    mg gdm-classify "$shown" || mt_failed S10.1.5 "the outcome could not be classified"
    outcome=$(vm_ssh_quick 'sudo cat /var/tmp/maint/gdm-outcome' 2>/dev/null | tail -n1 || true)
    log "S10.1.5: the screen ${shown}; the outcome: ${outcome:-unknown}"
    case "$outcome" in
        converted) ;;
        held)
            b0=$(vm_ssh_quick 'cat /proc/sys/kernel/random/boot_id' 2>/dev/null | tail -n1)
            skip=$(wc -l < "$vid/index.txt")
            mg_reboot gdm-reboot && rc=0 || rc=$?
            [ "$rc" != 1 ] || { ev_pull; fail "S10.1.5: the reboot could not be started"; }
            if ! mt_wait_screen "$vid" 300 "$skip"; then
                mt_open S10.1.5
                ev_video_stop "EV-VIDEO: the screen from the greeter, through the live sequence and the reboot, for 300 s after it: no desktop"
                mt_failed S10.1.5 "300 s after the second outcome's reboot the desktop is not on the screen"
                return 0
            fi
            ;;
        *)
            mt_open S10.1.5
            ev_video_stop "EV-VIDEO: the screen from the greeter through the live sequence: neither of the document's outcomes"
            mt_failed S10.1.5 "the live sequence ended in neither outcome deploy/README.md describes"
            return 0
            ;;
    esac
    sleep 3
    mt_open S10.1.5
    ev_video_stop "EV-VIDEO: the screen at 1 fps from the greeter to the desktop$([ "$outcome" = held ] && echo ', across the reboot'); index.txt gives each frame's UTC time"
    ev_note "outcome '$outcome': the desktop on the screen $(mt_elapsed "$t0") s after the live sequence began (${MT_BACK%% *} at ${MT_BACK#* })"
    if ! mt_screen_check end "EV-SHOT: the end state's screen: the #101216 root, the session's xterm in mwm's frame"; then
        mt_failed S10.1.5 "the screen does not show the desktop in the end state"
        return 0
    fi
    mt_close
    mg gdm-after || mt_failed S10.1.5 "the end state is not the one deploy/README.md describes"
    mt_typing S10.1.5 gdmconverted || mt_failed S10.1.5 "in the end state, typed text did not reach the focused xterm"
}

# --- F10.6: client workloads on a provisioned host --------------------------------
# S10.6.1's demo xterm, used the way the operator would: a click at its centre
# and a line typed, through QEMU's own devices, which its shell runs in the pod
# (S7.5.2's check, here after README.md's steps as written).
mt_k8s_type() {
    local res rect d_wid d_w d_h d_x d_y qlog got="" xd
    xd=$(gq desk xdpyinfo 2>/dev/null) || xd=""
    res=$(awk '/dimensions:/ {print $2; exit}' <<<"$xd")
    mt_open S10.6.1
    [ -n "$res" ] || { ev_fail "could not read the display's size for the input"; mt_close; return 1; }
    ev_save windows "EV-STATE: the demo pod's main process (its xterm), the X client it holds and its windows, read just before the click" \
        gq pod-windows x11-client-demo >/dev/null || true
    rect=$(ev_out | win_rect || true)
    [ -n "$rect" ] || { ev_fail "the demo pod's xterm has no window on the screen"; mt_close; return 1; }
    read -r d_wid d_w d_h d_x d_y <<<"$rect"
    qlog=$(ev_name qmp-input txt)
    if ! QMP_TRANSCRIPT="$EV_DIR/$qlog" python3 qmp-type.py "$QMP" "$res" $((d_x + d_w / 2)) $((d_y + d_h / 2)) "echo typedintodemo1061 >/tmp/s1061"; then
        ev_fail "QMP input to the demo pod's window failed"
        mt_close
        return 1
    fi
    ev_attach "$qlog" "EV-QEMU: every QMP command sent: the pointer to the centre of the demo's window $d_wid (${d_w}x${d_h}+$d_x+$d_y on $res), a click, then the keys of the line and Return"
    for _ in $(seq 8); do
        got=$(gq jx-in x11-client-demo cat /tmp/s1061 2>/dev/null || true)
        [ -z "$got" ] || break
        sleep 1
    done
    ev_text typed-file "EV-STATE: /tmp/s1061 read inside the demo pod: what the shell in its xterm wrote when the typed line ran" "${got:-(no file)}"
    ev_shot typed "EV-SHOT: the demo pod's xterm with the line typed into it"
    if [ "$got" = typedintodemo1061 ]; then
        ev_pass "the operator can click into the demo's xterm and type: the line typed through QEMU's devices ran in the pod's shell, which wrote typedintodemo1061 to /tmp/s1061 (S7.5.2's check)"
        mt_close
        return 0
    fi
    ev_fail "the demo pod's shell did not run the typed line: /tmp/s1061 holds '${got:-nothing}'"
    mt_close
    return 1
}

# S10.6.2: the node staged as never provisioned; a client that needs the
# toolkit is Pending until the desktop's start publishes it, then runs.
mt_unprovisioned() {
    local vid t0
    log "S10.6.2: the node staged as one the desktop never provisioned; a client needing the toolkit, Pending until the desktop's start publishes it"
    mg unprov-stage || { mt_failed S10.6.2 "the node could not be staged as never provisioned"; return 0; }
    mt_open S10.6.2
    ev_shot stopped "EV-SHOT: the screen with the desktop stopped and the node staged as never provisioned"
    mt_close
    mg unprov-pod || mt_failed S10.6.2 "the client needing the toolkit was not a visible scheduling failure"
    mt_open S10.6.2
    EV_VID_FPS=1 ev_video_start start
    vid="$EV_DIR/$EV_VID"
    mt_close
    t0=$(date +%s.%N)
    mg unprov-start || mt_failed S10.6.2 "after the desktop's start, the same pod did not schedule, run and capture"
    if ! mt_wait_screen "$vid" 180; then
        mt_open S10.6.2
        ev_video_stop "EV-VIDEO: the screen for 180 s from systemctl start desktop.service: the desktop did not appear"
        mt_failed S10.6.2 "180 s after the start the desktop is not on the screen"
        return 0
    fi
    sleep 2
    mt_open S10.6.2
    ev_video_stop "EV-VIDEO: the screen at 1 fps from systemctl start desktop.service until the desktop was on it; index.txt gives each frame's UTC time"
    ev_note "the desktop was on the screen $(mt_elapsed "$t0") s after the start (${MT_BACK%% *} at ${MT_BACK#* })"
    mt_screen_check started "EV-SHOT: the screen after the start: the #101216 root, the session's xterm in mwm's frame" \
        || ev_fail "the screen does not show the desktop after the start"
    mt_close
    mg unprov-after || mt_failed S10.6.2 "the desktop did not come back whole, or the state after the start could not be recorded"
}

maint_k8s() {
    log "maintainer: a host provisioned the documented way, k3s and CRI-O on it, then README.md's Kubernetes steps as written (S10.6.1); then the node staged as never provisioned (S10.6.2)"
    mt_unpack
    mt_provision_quiet
    mg k8s-node || fail "S10.6.1: k3s and CRI-O could not be brought up on the provisioned host"
    if ! mg k8s-plugins; then
        mt_failed S10.6.1 "README.md's helm installs did not give 10 of each resource"
        mt_failed S10.6.2 "not run: the node has none of README.md's plugins"
        return 0
    fi
    mt_open S10.6.1
    ev_shot before-apply "EV-SHOT: the screen before README.md's apply line: the desktop, nothing of the demo pod's"
    ev_video_start apply
    mt_close
    if mg k8s-apply; then
        mt_open S10.6.1
        ev_video_stop "EV-VIDEO: the screen from before README.md's apply line until the demo pod's xterm was on it; index.txt gives each frame's UTC time"
        ev_shot demo "EV-SHOT: the screen with the demo pod's xterm on it"
        mt_close
        mt_k8s_type || mt_failed S10.6.1 "the click and the line typed did not reach the demo pod's xterm"
    else
        mt_open S10.6.1
        ev_video_stop "EV-VIDEO: the screen from before README.md's apply line, while it failed"
        mt_close
        mt_failed S10.6.1 "README.md's apply line did not put the demo pod's xterm on the screen"
    fi
    mg k8s-after || mt_failed S10.6.1 "the desktop restarted during README.md's steps, or the state after them could not be recorded"
    mt_unprovisioned
}

# Every story the journey wrote, as the gate will read it: a story can fail
# a check without failing the step that ran it (a checklist's line, say).
mt_verdict() {
    ev_pull
    python3 - "$ART" <<'PY'
import sys
sys.path.insert(0, "..")
import evlib
bad = [f"{d}: {st}: {why}" for d in evlib.story_dirs(sys.argv[1])
       for st, why in [evlib.read_result(d)] if st != "PASS"]
print("\n".join(bad))
sys.exit(1 if bad else 0)
PY
}

maint_main() { # <journey>
    local bad
    case "$1" in
        docpath) maint_docpath ;;
        config) maint_config ;;
        session) maint_session ;;
        faults) maint_faults ;;
        live) maint_live ;;
        gdm) maint_gdm ;;
        k8s) maint_k8s ;;
        *) fail "no maintainer journey named '$1'" ;;
    esac
    write_manifest
    # fail() repeats its message last (Requirements.md S9.2.3): each failed
    # story, with why.
    [ -z "$MT_FAILED" ] || fail "maintainer stories failed:$MT_FAILED (each story's evidence.md says more):$(printf '\n  %s' "${MT_WHY[@]}")"
    bad=$(mt_verdict) || fail "maintainer stories did not pass: $bad"
}
