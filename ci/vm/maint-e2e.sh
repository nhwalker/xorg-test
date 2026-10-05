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
    log "FAIL, and the journey goes on: $1: $2"
    if [ -n "$EV_STORY" ]; then ev_fail "$2"; mt_close; fi
}
mt_unpack() { vm_ssh 'mkdir -p repo && tar -xzf /tmp/repo.tgz -C repo' || fail "could not unpack the repository in the VM"; }

# --- the screen ------------------------------------------------------------------
# The desktop as the operator sees it, in one screendump: the root window's
# #101216 in the bottom-right corner and the session xterm's #16191d well
# inside its 100x30+60+60 window (S3.3.3's and S3.5.2's colours).
mt_is_desktop() { # <image>
    local w="" h=""
    read -r w h < <(identify -format '%w %h\n' "$1" 2>/dev/null) || true
    [ -n "$h" ] || return 1
    [ "$(px "$1" $((w - 12)) $((h - 12)))" = 16,18,22 ] && [ "$(px "$1" 360 260)" = 22,25,29 ]
}
# Follow a recording (ev_video_start) frame by frame until the desktop has
# gone from the screen and come back, for up to <seconds>, looking only at
# the screen: nothing logs in to the guest meanwhile. Sets MT_BACK to the
# first frame showing the desktop again and its UTC time.
MT_BACK=""
mt_wait_screen() { # <video dir> <seconds>
    local end=$((SECONDS + $2)) n=0 m name t gone=0
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
    ev_pass "the screen shows the desktop: the root window's #101216 at the bottom-right corner and the session xterm's #16191d inside it ($f)"
}

# --- typing and sound ------------------------------------------------------------
# S3.8.1's probe: a sink xterm, a click into it and a word typed, all through
# QEMU's own devices.
mt_typing() { # <story> <word>
    local res qlog
    res=$(gq desk xdpyinfo 2>/dev/null | awk '/dimensions:/ {print $2; exit}')
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
        ev_pass "the focused xterm's shell read '$2', typed through QEMU's keyboard (S3.8.1)"
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
        *) fail "no maintainer journey named '$1'" ;;
    esac
    write_manifest
    [ -z "$MT_FAILED" ] || fail "maintainer stories failed:$MT_FAILED (each story's evidence.md says why)"
    bad=$(mt_verdict) || fail "maintainer stories did not pass: $bad"
}
