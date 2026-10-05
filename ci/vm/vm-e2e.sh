#!/bin/bash
# Host-side orchestration for the Rocky 9 VM e2e test. Boots a KVM guest
# with virtio graphics/input/sound, drives ci/vm/vm-guest.sh over ssh, hot-
# adds an input device mid-test, and captures screendumps of the virtual
# display as artifacts. The GPU carries two connectors, only one of which
# QEMU ever enables - see the boot command below.
set -euo pipefail
cd "$(dirname "$0")"

ART=artifacts
IMG=Rocky-9-GenericCloud.qcow2
DISK=disk.qcow2
MON=mon.sock
QMP=qmp.sock
# A second QMP monitor for EV-VIDEO alone (qmp-tool.py video): QMP serves one
# client at a time, and a recorder on the first would hold up everything else.
QMPV=qmpv.sock
# QEMU's VNC server bound to the virtio-vga's head 1 (vnc-head.py): how a
# monitor is plugged into Virtual-2 and taken away (S3.10.5, S3.10.7).
VNC1=vnc-head1.sock
SSHPORT=2222
mkdir -p "$ART"

# Which part of the suite this VM runs: ci.yml's vm job is a matrix over the
# shards, each booting its own VM from the same images so they run in
# parallel. "all" runs every part in one VM, in the order below (local runs).
SHARD=${1:-all}
case "$SHARD" in
    all|core|operator|k8s) ;;
    *) echo "usage: $0 [all|core|operator|k8s]" >&2; exit 2 ;;
esac
in_shard() { [ "$SHARD" = all ] || [ "$SHARD" = "$1" ]; }

# Evidence (Requirements.md, "Evidence standard"). Host-side stories write
# $ART/<story>/ directly. Guest phases write /var/tmp/ev/<story>/ in the VM,
# which ev_pull copies here; they never collide, because the host adds to a
# guest story only under h-prefixed names (ci/evlib.py).
export EV_ROOT="$PWD/$ART" EV_SOURCE="${EV_SOURCE:-vm-e2e.sh $SHARD}"
# shellcheck source=ci/evidence.sh
. ../evidence.sh
GUEST_EV=/var/tmp/ev
VM_UP=0

log()  { echo "== vm-e2e: $*"; }
# Pitch each audio path plays (must match gen_tone in vm-guest.sh), so the
# capture check can confirm the RIGHT tone came through, not just some sound.
freq_for() { case "$1" in pulse) echo 440;; pipewire) echo 880;; alsa) echo 1320;; *) echo 0;; esac; }
fail() { echo "FAIL: vm-e2e: $*" >&2; ev_abort "$*"; exit 1; }

# ConnectTimeout only bounds the handshake, so a guest that accepts the
# connection and then wedges would hang here indefinitely - and inside a
# 20-iteration poll loop that silently eats the job's whole 30-minute budget
# instead of failing. The outer timeout bounds the command itself; ServerAlive
# turns a dead-but-open connection into an error.
#
# The default is deliberately LARGE. A single flat bound cannot serve both
# kinds of call this script makes, and choosing one that fit the probes broke
# the phases: at 60s, `vm-guest.sh phase-deploy` - which installs packages,
# loads images and brings up the desktop - was killed mid-package-install
# every run, and reported itself as whatever step it happened to be on when
# the axe fell. Two runs were diagnosed as an rtkit failure and a dnf mirror
# problem on that evidence; both were this timeout. So the default bounds a
# wedged guest without bounding legitimate work, and the poll loops use
# vm_ssh_quick, which is where a hang actually needs catching fast.
vm_ssh() {
    timeout "${VM_SSH_TIMEOUT:-900}" ssh -q -p "$SSHPORT" -i id_ed25519 \
        -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        -o ConnectTimeout=10 -o ServerAliveInterval=5 -o ServerAliveCountMax=3 \
        rocky@127.0.0.1 "$@"
}
# For probes inside poll loops: a command that should answer in under a second,
# so twenty iterations of it cannot consume the job.
vm_ssh_quick() { VM_SSH_TIMEOUT=20 vm_ssh "$@"; }

mon_cmd() {
    echo "$1" | socat - "UNIX-CONNECT:$MON" >/dev/null
}

# Copy the guest's evidence tree over the host's (see EV_ROOT above).
ev_pull() {
    [ "$VM_UP" = 1 ] || return 0
    VM_SSH_TIMEOUT=120 vm_ssh "sudo tar -C $GUEST_EV -cf - . 2>/dev/null" 2>/dev/null \
        | tar -C "$ART" -xf - 2>/dev/null || true
}
# Whatever happened, leave every story directory rendered and the guest's
# half copied back: a red run must be as reviewable as a green one.
ev_finish() {
    # A recording still running turns its frames into PNGs once stopped:
    # give it up to 20 s, so the artifact holds PNGs, not raw frames.
    if [ -n "${EV_VID_PID:-}" ] && kill "$EV_VID_PID" 2>/dev/null; then
        for _ in $(seq 40); do kill -0 "$EV_VID_PID" 2>/dev/null || break; sleep 0.5; done
    fi
    ev_pull
    python3 ../evlib.py render "$ART" >/dev/null 2>&1 || true
}
trap ev_finish EXIT

# Run a vm-guest.sh phase with the guest's evidence switched on ($1 =
# $GUEST_EV) or off ($1 empty), then copy what it wrote back.
guest_ev() { # <ev-root or ""> <vm-guest.sh args...>
    local root=$1 rc=0
    shift
    vm_ssh "sudo EV_ROOT=$root EV_SOURCE='$EV_SOURCE' repo/ci/vm/vm-guest.sh $*" || rc=$?
    [ -z "$root" ] || ev_pull
    return "$rc"
}

# EV-AUDIO into the open story: wavcapture straight into its directory;
# ev_audio_stop ends the capture, indexes the WAV and keeps check-audio.py's
# verdict and level plot beside it (ev_audio_check). Returns check-audio's
# status, so `ev_audio_stop ... || fail ...` asserts the tone.
ev_audio_start() { # <moment> <hz>
    EV_WAV=$(ev_name "$1-$2hz" wav)
    mon_cmd "wavcapture $EV_DIR/$EV_WAV snd0 44100 16 2"
    sleep 1
}
ev_audio_stop() { # <what> <min seconds> <min peak> <hz> [check-audio options...]
    audio_capture_stop
    if [ -s "$EV_DIR/$EV_WAV" ]; then ev_attach "$EV_WAV" "$1"; else ev_note "no capture was written for: $1"; fi
    local moment=${EV_WAV%.wav}
    ev_audio_check "${moment#*-}" "$EV_WAV" "$2" "$3" "$4" "${@:5}"
}

# EV-AUDIO's verdict and picture for a WAV already in the open story:
# check-audio.py's report and a level plot at the story's pitch (no
# spectrogram tool is installed). Returns check-audio's status.
ev_audio_check() { # <moment> <wav name in the story dir> <min seconds> <min peak> <hz> [check-audio options...]
    local rep plot rc=0
    if [ -z "$EV_DIR" ]; then
        python3 check-audio.py "${@:6}" "$2" "$3" "$4" "$5"
        return
    fi
    rep=$(ev_name "$1-verdict" txt)
    plot=$(ev_name "$1-level" png)
    python3 check-audio.py --report "$EV_DIR/$rep" --plot "$EV_DIR/$plot" "${@:6}" "$EV_DIR/$2" "$3" "$4" "$5" || rc=$?
    [ -s "$EV_DIR/$rep" ] && ev_attach "$rep" "check-audio.py's verdict on $2: its duration, peak and dominant frequency (want $5 Hz)"
    [ -s "$EV_DIR/$plot" ] && ev_attach "$plot" "the level at $5 Hz across $2, one bar per 0.1 s on a -60..0 dBFS scale (the picture of the tone; no spectrogram tool is installed)"
    return "$rc"
}

# EV-SHOT into the open story: a QEMU screendump, indexed with what to look for.
ev_shot() { # <moment> <what>
    [ -n "$EV_DIR" ] || return 0
    local name
    name=$(ev_name "$1" png)
    mon_cmd "screendump $EV_DIR/$name -f png"
    sleep 2
    if [ -s "$EV_DIR/$name" ]; then ev_attach "$name" "$2"; else ev_note "screendump $1 was not produced"; fi
}
# EV-SHOT of one head of the virtio-vga into the open story (qmp-tool.py
# shot): head 0 is Virtual-1's scanout, head 1 Virtual-2's. Echoes the
# image's "<width>x<height> <grayscale stddev>"; returns 1 without an image.
ev_shot_head() { # <moment> <head> <what>
    local name
    name=$(ev_name "$1" png)
    python3 qmp-tool.py shot "$QMP" "$EV_DIR/$name" vga0 "$2" >/dev/null && [ -s "$EV_DIR/$name" ] || return 1
    ev_attach "$name" "$3"
    convert "$EV_DIR/$name" -colorspace Gray -format '%wx%h %[fx:standard_deviation]' info: 2>/dev/null
}
# hotplug_probe echoes "<container input nodes> <Xorg input adds>", always as
# two integers. Defaults to "0 0" rather than letting an ssh hiccup produce an
# empty string that the arithmetic comparisons below would choke on.
hotplug_probe() {
    local out nodes adds
    out=$(vm_ssh_quick 'sudo repo/ci/vm/vm-guest.sh hotplug-probe' 2>/dev/null || true)
    read -r nodes adds <<<"$out"
    echo "${nodes:-0} ${adds:-0}"
}
# snd_probe echoes "<container ALSA control nodes> <WirePlumber alsa devices>",
# always as two integers, for the same reason and with the same defaulting as
# hotplug_probe above.
snd_probe() {
    local out nodes devs
    out=$(vm_ssh_quick 'sudo repo/ci/vm/vm-guest.sh snd-probe' 2>/dev/null || true)
    read -r nodes devs <<<"$out"
    echo "${nodes:-0} ${devs:-0}"
}
# --- hotplug evidence (Requirements.md F3.9 and F4.7 common sets) ---------------
# One of vm-guest.sh's read-only probes (desk, ctr-pids, xorg-log-lines,
# xorg-log-since), so the commands here need no quoting through ssh.
gq() { vm_ssh_quick "sudo repo/ci/vm/vm-guest.sh $*"; }
# The same for a step that waits on the guest (win-wait, journey-held-release)
# and may take longer than vm_ssh_quick's 20 s cap allows.
gqw() { vm_ssh "sudo repo/ci/vm/vm-guest.sh $*"; }

# EV-QEMU into the open story: one monitor command and QEMU's reply, through
# QMP (qmp-tool.py). device_add and device_del answer with an empty reply when
# they accept; returns 1 when QEMU says Error.
ev_qemu() { # <moment> <what> <monitor command>
    ev_save "$1" "$2" python3 qmp-tool.py hmp "$QMP" "$3"
}
# EV-QEMU into the open story: QEMU plugs a WIDTHxHEIGHT monitor into the
# virtio-vga's head 1, or takes it away for 0x0 (vnc-head.py), and its
# answer. Returns 1 unless QEMU says it forwarded the request.
vnc_head() { # <moment> <width> <height> <what>
    ev_save "$1" "$4" python3 vnc-head.py "$VNC1" "$2" "$3" >/dev/null
}

# EV-VIDEO into the open story: screendumps at 2 fps on the video monitor (a
# QMP socket of its own, so the hotplug commands never queue behind a frame)
# until ev_video_stop, which indexes the frames and a gif of them. The
# recorder keeps the directory it started in; reopen that story before
# ev_video_stop, which attaches to the open one.
EV_VID="" EV_VID_PID=""
ev_video_start() { # <moment>
    EV_VID="" EV_VID_PID=""
    [ -n "$EV_DIR" ] || return 0
    EV_VID=$(ev_name "$1" "")
    python3 qmp-tool.py video "$QMPV" "$EV_DIR/$EV_VID" 2 &
    EV_VID_PID=$!
    sleep 1
}
ev_video_stop() { # <what>
    [ -n "$EV_VID_PID" ] || return 0
    sleep 1
    kill "$EV_VID_PID" 2>/dev/null || true
    wait "$EV_VID_PID" 2>/dev/null || true
    EV_VID_PID=""
    ev_attach "$EV_VID/" "EV-VIDEO raw frames at 2 fps; index.txt gives each frame's UTC time, to read against timeline.log, and how long QEMU took to write it"
    if convert -delay 50 -loop 0 "$EV_DIR/$EV_VID"/frame-*.png -resize 50% "$EV_DIR/$EV_VID.gif" 2>/dev/null; then
        ev_attach "$EV_VID.gif" "$1"
    else
        ev_note "the frames in $EV_VID/ could not be assembled into a gif"
    fi
}

# A saved command's output, without ev_save's "$ command" and "[exit N]" lines.
ev_payload() { sed '1d;$d' "$1"; }
# The output of the command the last ev_save kept, without its "$ command"
# and "[exit N]" lines.
ev_out() { ev_payload "$EV_DIR/$EV_LAST"; }
# The same container before and after: its pod-state lines unchanged and
# restartCount 0. Both files are in the open story.
pod_same() { # <before file> <after file>
    local pb pa
    pb=$(ev_payload "$EV_DIR/$1"); pa=$(ev_payload "$EV_DIR/$2")
    grep -q 'restartCount=0 ' <<<"$pa" && [ -n "$pb" ] && [ "$pb" = "$pa" ]
}
# EV-SHOT-CLIENT into the open story: the screenshot run in a pod (the
# toolkit's, or its image's own where the pod has no toolkit).
ev_client_shot() { # <moment> <pod> <what>
    local name
    name=$(ev_name "$1" png)
    vm_ssh_quick "sudo repo/ci/vm/vm-guest.sh client-shot $2" > "$EV_DIR/$name" 2>/dev/null || true
    if [ -s "$EV_DIR/$name" ]; then ev_attach "$name" "$3"; return 0; fi
    rm -f "${EV_DIR:?}/${name:?}"
    ev_note "the pod's own screenshot ($1) was not produced"
    return 1
}
# The first window on the screen in a pod-windows listing (stdin), as
# "<id> <width> <height> <x> <y>" with the absolute position.
win_rect() {
    sed -nE 's/^(0x[0-9a-f]+) .* ([0-9]+)x([0-9]+)\+-?[0-9]+\+-?[0-9]+ +\+(-?[0-9]+)\+(-?[0-9]+) map=IsViewable$/\1 \2 \3 \4 \5/p' | sed -n 1p
}
# The guest's clock now, as a Unix time with nanoseconds.
gnow() { vm_ssh_quick 'date +%s.%N' 2>/dev/null | tail -1; }
# QEMU's own trace of its emulated HDA codec (-trace on the command line)
# between two host times, into the open story; prints how many overruns.
# hda_audio_overrun is the codec dropping its 8 KiB buffer because QEMU's
# audio backend did not take it; hda_audio_adjust is the codec re-timing its
# read of the guest's audio to keep that buffer half full. Neither is the
# desktop's doing: they say whether the emulator itself kept up.
ev_qemu_hda() { # <moment> <host t0> <host t1>
    local lines n
    lines=$(awk -F'[@:]' -v a="$2" -v b="$3" '$3 ~ /^hda_audio_/ && $2 + 0 >= a + 0 && $2 + 0 <= b + 0' "$ART/qemu-trace.log" 2>/dev/null || true)
    n=$(grep -c 'hda_audio_overrun' <<<"$lines" || true)
    ev_text "$1" "EV-QEMU: QEMU's own trace of its HDA codec while the tone played (pid@host time:event): $n hda_audio_overrun (the codec dropping its 8 KiB buffer, QEMU's backend not having taken it) and $(grep -c 'hda_audio_adjust' <<<"$lines" || true) hda_audio_adjust (the codec re-timing its read of the guest's audio)" \
        "${lines:-(no hda_audio trace line in the window)}"
    echo "${n:-0}"
}
# What the guest and QEMU said about the audio across a capture window: the
# scheduling and xruns after, the desktop's log since the window opened, and
# QEMU's HDA trace. Kept with the story because S7.6.3's tone has come out
# short with no gap in it (run 37335026876: 20 s played in 18.64 s). Run
# 37338352192 said why: QEMU's sound card dropped its buffer 18 times, each
# at a frame of the story's own PNG video, which QEMU compressed in the
# loop its audio runs in. The video now takes raw frames (qmp-tool.py).
audio_window_record() { # <host t0> <host t1> <guest t0>
    ev_save sched-after "EV-STATE: PipeWire's threads and pw-top's batch view after the tone: an ERR count above the one before is an xrun during it" \
        gq audio-sched >/dev/null || true
    ev_save desktop-log "EV-LOG-DESKTOP: the desktop container's log from the tone's start on (PipeWire's own warnings, xruns among them, land here)" \
        gq desktop-log-since "$3" >/dev/null || true
    local n
    n=$(ev_qemu_hda qemu-hda "$1" "$2")
    ev_note "QEMU's HDA codec overran ${n:-0} time(s) while the tone played"
}

# F3.9's common set into the open story as <moment>-* files: QEMU's USB
# devices, /dev/input on the host and in the container, the kernel's input
# devices and xinput. Each file's name lands in IN_USB IN_HOST IN_CTR IN_DEV
# IN_XI; input_keep makes them the "before" side (B_*) of input_diffs.
input_set() { # <moment> <when>
    ev_save "$1-info-usb" "EV-QEMU: info usb, $2" python3 qmp-tool.py hmp "$QMP" "info usb" >/dev/null || true
    IN_USB=$EV_LAST
    ev_save "$1-host-input" "EV-STATE: ls -l /dev/input on the VM host, $2" vm_ssh_quick 'ls -l /dev/input' >/dev/null || true
    IN_HOST=$EV_LAST
    ev_save "$1-ctr-input" "EV-STATE: ls -l /dev/input inside the desktop container, $2" \
        vm_ssh_quick 'sudo podman exec desktop ls -l /dev/input' >/dev/null || true
    IN_CTR=$EV_LAST
    ev_save "$1-devices" "EV-STATE: /proc/bus/input/devices on the VM host, $2" \
        vm_ssh_quick 'cat /proc/bus/input/devices' >/dev/null || true
    IN_DEV=$EV_LAST
    ev_save "$1-xinput" "EV-STATE: xinput list as the session user, $2" gq desk xinput list >/dev/null || true
    IN_XI=$EV_LAST
}
input_keep() { B_USB=$IN_USB B_HOST=$IN_HOST B_CTR=$IN_CTR B_DEV=$IN_DEV B_XI=$IN_XI; }
# The set another story took (its names still in IN_*), copied into the open
# story as the "before" side.
input_import() { # <story> <moment> <when>
    ev_copy "$ART/$1/$IN_USB" "$2-info-usb" "EV-QEMU: info usb, $3 (taken in $1)"; B_USB=$EV_LAST
    ev_copy "$ART/$1/$IN_HOST" "$2-host-input" "EV-STATE: ls -l /dev/input on the VM host, $3 (taken in $1)"; B_HOST=$EV_LAST
    ev_copy "$ART/$1/$IN_CTR" "$2-ctr-input" "EV-STATE: ls -l /dev/input inside the desktop container, $3 (taken in $1)"; B_CTR=$EV_LAST
    ev_copy "$ART/$1/$IN_DEV" "$2-devices" "EV-STATE: /proc/bus/input/devices on the VM host, $3 (taken in $1)"; B_DEV=$EV_LAST
    ev_copy "$ART/$1/$IN_XI" "$2-xinput" "EV-STATE: xinput list as the session user, $3 (taken in $1)"; B_XI=$EV_LAST
}
input_diffs() { # <moment> <event>
    ev_diff "$1-info-usb" "EV-DIFF: info usb across $2" "$B_USB" "$IN_USB"
    ev_diff "$1-host-input" "EV-DIFF: /dev/input on the VM host across $2" "$B_HOST" "$IN_HOST"
    ev_diff "$1-ctr-input" "EV-DIFF: /dev/input in the container across $2" "$B_CTR" "$IN_CTR"
    ev_diff "$1-devices" "EV-DIFF: /proc/bus/input/devices across $2" "$B_DEV" "$IN_DEV"
    ev_diff "$1-xinput" "EV-DIFF: xinput list across $2" "$B_XI" "$IN_XI"
}

# Kernel input device names (N: Name="...") in a saved
# /proc/bus/input/devices, one per line, sorted, repeats kept.
dev_names() { sed -n 's/^N: Name="\(.*\)"$/\1/p' "$1" | sort; }
# The event nodes of the devices with that name, from the same file.
dev_events() { # <file> <name>
    awk -v n="N: Name=\"$2\"" '
        $0 == n { on = 1 }
        /^$/ { on = 0 }
        on && /^H: Handlers=/ { sub(/^H: Handlers=/, ""); for (i = 1; i <= NF; i++) if ($i ~ /^event[0-9]+$/) print $i }' "$1" \
        | paste -sd' '
}
# The device names in xinput list's output (stdin), and how many entries a
# saved one has for a name.
xi_names() { sed -n 's/^.*↳ \(.*[^[:space:]]\)[[:space:]]*id=[0-9].*$/\1/p'; }
xi_count() { xi_names < "$1" | grep -cxF -- "$2" || true; }
# Poll until xinput lists fewer than <count> entries for the name (10 s at
# most): the judgement is the story's, on the picture taken after.
xi_wait_gone() { # <name> <count before>
    local n
    for _ in $(seq 10); do
        n=$(gq desk xinput list 2>/dev/null | xi_names | grep -cxF -- "$1" || true)
        [ "${n:-0}" -lt "$2" ] && return 0
        sleep 1
    done
}

# S3.9.2: did Xorg adopt each device the kernel gained? From another story's
# files: /proc/bus/input/devices and xinput list before and after, and the
# Xorg log's lines since. Either xinput gains an entry for the name, or the
# log has both of Xorg's "adding" lines for it.
xi_judge_added() { # <story> <devices before> <devices after> <xinput before> <xinput after> <xorg log> <event>
    local src="$ART/$1" db da xb xa xl names name nb na logged
    ev_copy "$src/$2" devices-before "EV-STATE: /proc/bus/input/devices before $7 (taken in $1)"; db=$EV_LAST
    ev_copy "$src/$3" devices-after "EV-STATE: /proc/bus/input/devices after $7 (taken in $1)"; da=$EV_LAST
    ev_copy "$src/$4" xinput-before "EV-STATE: xinput list before $7 (taken in $1)"; xb=$EV_LAST
    ev_copy "$src/$5" xinput-after "EV-STATE: xinput list after $7 (taken in $1)"; xa=$EV_LAST
    ev_diff xinput "EV-DIFF: xinput list across $7" "$xb" "$xa"
    ev_copy "$src/$6" xorg-log "EV-LOG-XORG: the Xorg log's lines since just before $7 (taken in $1)"; xl=$EV_LAST
    names=$(comm -13 <(dev_names "$EV_DIR/$db") <(dev_names "$EV_DIR/$da") | sort -u)
    [ -n "$names" ] || fail "no new device in /proc/bus/input/devices across $7"
    while IFS= read -r name; do
        nb=$(xi_count "$EV_DIR/$xb" "$name")
        na=$(xi_count "$EV_DIR/$xa" "$name")
        logged=no
        grep -qF "Adding input device $name (" "$EV_DIR/$xl" \
            && grep -qF "XINPUT: Adding extended input device \"$name\"" "$EV_DIR/$xl" && logged=yes
        ev_note "'$name': xinput entries $nb -> $na; both of Xorg's adding lines in the log: $logged"
        ev_text "adding-lines" "EV-LOG-XORG: Xorg's two adding lines for '$name', quoted from the slice" \
            "$(grep -F -e "Adding input device $name (" -e "XINPUT: Adding extended input device \"$name\"" "$EV_DIR/$xl" || echo "(neither line is in the slice)")"
        if [ "$na" -gt "$nb" ]; then
            ev_pass "xinput list gained an entry for '$name' ($nb -> $na)"
        elif [ "$logged" = yes ]; then
            ev_pass "the Xorg log has 'Adding input device $name' and 'XINPUT: Adding extended input device \"$name\"' (xinput list: $nb -> $na)"
        else
            fail "Xorg did not adopt '$name' after $7: xinput list has $nb -> $na entries for it, and the log lacks its 'Adding input device' and 'XINPUT: Adding extended input device' lines"
        fi
    done <<<"$names"
}
# S3.9.4, S3.9.10: each removed device left xinput list, and Xorg logged
# its removal.
xi_judge_removed() { # <story> <xinput before> <xinput after> <xorg log> <name>...
    local src="$ART/$1" xb xa xl nb na name
    ev_copy "$src/$2" xinput-before "EV-STATE: xinput list before the removal (taken in $1)"; xb=$EV_LAST
    ev_copy "$src/$3" xinput-after "EV-STATE: xinput list after the removal, polled until the removed device left or 10 s passed (taken in $1)"; xa=$EV_LAST
    ev_diff xinput "EV-DIFF: xinput list across the removal" "$xb" "$xa"
    ev_copy "$src/$4" xorg-log "EV-LOG-XORG: the Xorg log's lines since just before the removal (taken in $1)"; xl=$EV_LAST
    shift 4
    for name in "$@"; do
        nb=$(xi_count "$EV_DIR/$xb" "$name")
        na=$(xi_count "$EV_DIR/$xa" "$name")
        [ "$nb" -gt 0 ] || fail "xinput list had no '$name' before the removal, so its leaving would prove nothing"
        [ "$na" -lt "$nb" ] || fail "'$name' did not leave xinput list after the removal ($nb -> $na entries)"
        ev_pass "'$name' left xinput list: $nb -> $na entries"
        grep -qF "removing device $name" "$EV_DIR/$xl" \
            || fail "the Xorg log has no 'removing device $name' since the removal"
        ev_pass "the Xorg log records the removal: $(grep -F "removing device $name" "$EV_DIR/$xl" | head -1 | sed 's/^ *//')"
    done
}
# The role of each entry with that name in a saved xinput list: pointer or
# keyboard (xinput's "slave pointer" and "slave keyboard").
xi_roles() { # <saved xinput list> <name>
    awk -v want="$2" '/slave/ {
        line = $0; sub(/^.*↳ /, "", line); name = line; sub(/[[:space:]]*id=.*$/, "", name)
        if (name != want) next
        if (line ~ /slave +pointer/) print "pointer"; else if (line ~ /slave +keyboard/) print "keyboard"; else print "other" }' "$1"
}

# F4.7's common set into the open story as <moment>-* files: QEMU's USB
# devices, /dev/snd on the host and in the container, the graph as wpctl,
# pw-cli and pactl show it, the default sink, and the three daemons. Names in
# SN_*; snd_keep and snd_import set the "before" side (SB_*) of snd_diffs.
# shellcheck disable=SC2034  # the SN_* names are read through eval below
snd_set() { # <moment> <when>
    ev_save "$1-info-usb" "EV-QEMU: info usb, $2" python3 qmp-tool.py hmp "$QMP" "info usb" >/dev/null || true
    SN_USB=$EV_LAST
    ev_save "$1-host-snd" "EV-STATE: ls -l /dev/snd on the VM host, $2" vm_ssh_quick 'ls -l /dev/snd' >/dev/null || true
    SN_HOST=$EV_LAST
    ev_save "$1-ctr-snd" "EV-STATE: ls -l /dev/snd inside the desktop container, $2" \
        vm_ssh_quick 'sudo podman exec desktop ls -l /dev/snd' >/dev/null || true
    SN_CTR=$EV_LAST
    ev_save "$1-wpctl" "EV-STATE: wpctl status as the session user, $2" gq desk wpctl status >/dev/null || true
    SN_WP=$EV_LAST
    ev_save "$1-pw-devices" "EV-STATE: pw-cli ls Device as the session user, $2" gq desk pw-cli ls Device >/dev/null || true
    SN_PW=$EV_LAST
    ev_save "$1-sinks" "EV-STATE: pactl list short sinks, $2" gq desk pactl list short sinks >/dev/null || true
    SN_SINKS=$EV_LAST
    ev_save "$1-sources" "EV-STATE: pactl list short sources, $2" gq desk pactl list short sources >/dev/null || true
    SN_SOURCES=$EV_LAST
    ev_save "$1-sink-inputs" "EV-STATE: pactl list short sink-inputs, $2" gq desk pactl list short sink-inputs >/dev/null || true
    SN_INPUTS=$EV_LAST
    ev_save "$1-default-sink" "EV-STATE: pactl get-default-sink, $2" gq desk pactl get-default-sink >/dev/null || true
    SN_DEF=$EV_LAST
    ev_save "$1-pids" "EV-PIDS: the three audio daemons in the desktop container, $2" \
        gq ctr-pids pipewire,wireplumber,pipewire-pulse >/dev/null || true
    SN_PIDS=$EV_LAST
}
# Each kind in the set, and the slug its files are named by.
declare -A SND_SLUG=([USB]=info-usb [HOST]=host-snd [CTR]=ctr-snd [WP]=wpctl [PW]=pw-devices
                     [SINKS]=sinks [SOURCES]=sources [INPUTS]=sink-inputs [DEF]=default-sink [PIDS]=pids)
SND_KINDS="USB HOST CTR WP PW SINKS SOURCES INPUTS DEF PIDS"
snd_keep() { local k; for k in $SND_KINDS; do eval "SB_$k=\$SN_$k"; done; }
# The set another story took (its names still in SN_*), copied into the open
# story as the "before" side.
snd_import() { # <story> <moment> <when>
    local k f
    for k in $SND_KINDS; do
        eval "f=\$SN_$k"
        ev_copy "$ART/$1/$f" "$2-${SND_SLUG[$k]}" "EV-STATE (or EV-QEMU, EV-PIDS): ${SND_SLUG[$k]}, $3 (taken in $1)"
        eval "SB_$k=\$EV_LAST"
    done
}
snd_diffs() { # <moment> <event>
    local k a b
    for k in $SND_KINDS; do
        eval "b=\$SB_$k a=\$SN_$k"
        ev_diff "$1-${SND_SLUG[$k]}" "EV-DIFF: ${SND_SLUG[$k]} across $2" "$b" "$a"
    done
}
# The three audio daemons' pids on one line, for a before/after comparison.
audio_pids() {
    vm_ssh_quick 'sudo podman exec desktop sh -c "pgrep -x pipewire; pgrep -x wireplumber; pgrep -x pipewire-pulse"' \
        2>/dev/null | paste -sd' ' || true
}
# EV-AUDIO-REC's facts about a recording: frames, duration, format and peak.
# Exits 1 when it holds less than <min seconds>.
rec_facts() { # <wav> <min seconds>
    python3 - "$1" "$2" <<'EOF'
import array, sys, wave
w = wave.open(sys.argv[1])
n, rate, ch, width = w.getnframes(), w.getframerate(), w.getnchannels(), w.getsampwidth()
data = w.readframes(n)
peak = max((abs(x) for x in array.array("h", data)), default=0) / 32768 if width == 2 else 0.0
dur = n / rate if rate else 0.0
print(f"{n} frames: {dur:.2f} s at {rate} Hz, {ch} channel(s), {8 * width}-bit; peak {peak:.4f} of full scale")
sys.exit(0 if dur >= float(sys.argv[2]) else 1)
EOF
}
# The PCI sound card with a capture path QEMU can hot-add here, if the guest
# kernel has its driver: usb-audio has no capture path and QEMU's HDA codec
# bus refuses device_add, so AC97 (snd-intel8x0) or ES1370 (snd-ens1370).
# Sets cap_probe (modinfo's answer for both) and cap_model (empty: neither).
cap_card_probe() {
    cap_probe=$(vm_ssh_quick 'for m in snd-intel8x0 snd-ens1370; do printf "%s: " "$m"; modinfo -n "$m" 2>&1 | head -1; done' || true)
    cap_model=""
    grep -q '^snd-intel8x0: /' <<<"$cap_probe" && cap_model=AC97
    [ -z "$cap_model" ] && grep -q '^snd-ens1370: /' <<<"$cap_probe" && cap_model=ES1370
    return 0
}
# Poll (10 s at most) until the default sink is one of the sinks there are:
# the judgement is S4.7.5's, on the picture taken after.
snd_wait_default() {
    local d s
    for _ in $(seq 10); do
        d=$(gq desk pactl get-default-sink 2>/dev/null || true)
        s=$(gq desk pactl list short sinks 2>/dev/null | awk '{print $2}' || true)
        [ -n "$d" ] && grep -qxF -- "$d" <<<"$s" && return 0
        sleep 1
    done
}
# alsa_card device.name values in a saved pw-cli ls Device, sorted; and the
# whole block of the object with one of them.
pw_card_names() { grep -o 'device.name = "alsa_card[^"]*"' "$1" | sed 's/.*= "\(.*\)"$/\1/' | sort; }
pw_block() { # <file> <device.name>
    awk -v n="device.name = \"$2\"" '
        /^\[exit [0-9]+\]$/ { next }
        /^[[:space:]]*id [0-9]+, type / { if (blk != "" && index(blk, n)) print blk; blk = $0; next }
        blk != "" { blk = blk "\n" $0 }
        END { if (blk != "" && index(blk, n)) print blk }' "$1"
}

screendump() {
    # -f png needs QEMU >= 7.1. Monitor errors are invisible (socat output
    # is discarded), so check the file materialized and fall back to the
    # universally supported PPM dump if it didn't.
    mon_cmd "screendump $PWD/$ART/$1.png -f png"
    sleep 2
    if ! [ -s "$ART/$1.png" ]; then
        log "WARNING: png screendump failed (qemu < 7.1?); falling back to ppm"
        mon_cmd "screendump $PWD/$ART/$1.ppm"
        sleep 2
    fi
}
assert_nonblank() { # $1: screendump basename (as passed to screendump)
    local f="$ART/$1.png"
    [ -s "$f" ] || f="$ART/$1.ppm"
    measure_nonblank "$f" "$1"
}
measure_nonblank() { # $1: image file; $2: its name in the log and in S3.5.1
    # A live X server that is drawing nothing produces a solid frame; the
    # grayscale standard deviation collapses to ~0. Real content (the mwm
    # root stipple + a window) is well above the threshold. This turns the
    # screendump from a human-eyeball artifact into a pass/fail signal.
    # Each measurement is kept for S3.5.1's evidence (s3_5_1_story).
    local f="$1" sd
    [ -s "$f" ] || fail "screendump $2 was not produced"
    sd=$(convert "$f" -colorspace Gray -format '%[fx:standard_deviation]' info: 2>/dev/null) \
        || fail "could not analyze screendump $2 (imagemagick missing?)"
    printf '%s\t%s\t%s\n' "$2" "$f" "$sd" >> "$ART/.nonblank.tsv"
    awk "BEGIN{ exit !($sd > 0.02) }" \
        || fail "screendump $2 is blank/near-uniform (grayscale stddev=$sd); X is up but rendering nothing"
    log "render: $2 is non-blank (grayscale stddev=$sd)"
}
# S3.5.1: every measurement this run made, each image with its stddev.
s3_5_1_story() {
    local name f sd
    ev_begin S3.5.1 "The server is drawing" T3
    while IFS=$'\t' read -r name f sd; do
        if [ -s "$f" ]; then
            ev_copy "$f" "$name" "EV-SHOT: $name, grayscale standard deviation $sd (a blank or one-colour frame is near 0; the threshold is 0.02)"
        else
            ev_note "$name's image is no longer at $f; its measured stddev was $sd"
        fi
        if awk "BEGIN{ exit !($sd > 0.02) }"; then
            ev_pass "$name is drawn: grayscale stddev $sd > 0.02"
        else
            ev_fail "$name is blank: grayscale stddev $sd"
        fi
    done < "$ART/.nonblank.tsv"
    ev_end
}
# --- screenshot pixel assertions ------------------------------------------
# The screenshot phase paints a known pattern (screenshot/testpattern) and then
# checks what the binary captured against it. Size and "not blank" are NOT
# enough on their own: a vertically flipped, horizontally mirrored, rotated,
# channel-swapped or offset capture has exactly the same dimensions and the
# same grayscale standard deviation as a correct one. These assertions name a
# colour at a coordinate, so each of those defects fails a specific line.
#
# The pattern's geometry, repeated from screenshot/testpattern/main.go - keep
# the two in sync.
PAT_BLOCK=64
PAT_FIDX=300
PAT_FIDY=200
PAT_ODDX=37
PAT_ODDY=91

# px prints "r,g,b" for one pixel. The %[pixel:] format is NOT usable here: it
# returns colour names for some values ("gray(0)" for black), so comparisons
# against it silently depend on which colour you picked.
px() { # $1: image; $2: x; $3: y
    convert "$1" -crop "1x1+$2+$3" +repage -depth 8 \
        -format '%[fx:int(255*r+0.5)],%[fx:int(255*g+0.5)],%[fx:int(255*b+0.5)]' info:
}
assert_px() { # $1: image; $2: x; $3: y; $4: expected "r,g,b"; $5: what this proves
    local got
    got=$(px "$1" "$2" "$3") || fail "could not read pixel ($2,$3) of $1"
    [ "$got" = "$4" ] || fail "$5: pixel ($2,$3) of $(basename "$1") is $got, want $4"
    ev_pass "$5: pixel ($2,$3) of $(basename "$1") is $got"
}

# assert_pattern checks a full-screen capture against the painted pattern.
assert_pattern() { # $1: image; $2: width; $3: height
    local f="$1" w="$2" h="$3" right=$(( $2 - 3 )) bottom=$(( $3 - 3 ))
    # Orientation: a different colour in each corner, so a flip, a mirror or a
    # 180-degree rotation each permutes them in its own recognisable way.
    assert_px "$f" 2 2 255,0,0 "top-left corner (vertical flip / mirror / rotation)"
    assert_px "$f" "$right" 2 0,255,0 "top-right corner (horizontal mirror)"
    assert_px "$f" 2 "$bottom" 0,0,255 "bottom-left corner (vertical flip)"
    assert_px "$f" "$right" "$bottom" 255,255,255 "bottom-right corner (180-degree rotation)"
    # Channel order: the background's three channels differ, so a red/blue
    # swap reads back as 96,64,32.
    assert_px "$f" $((w/2)) $((h/2)) 32,64,96 "background colour (red/blue channel swap)"
    # Off-by-one: the two pixels either side of a block edge.
    assert_px "$f" $((PAT_BLOCK-1)) 2 255,0,0 "last column inside the top-left block (off-by-one)"
    assert_px "$f" "$PAT_BLOCK" 2 32,64,96 "first column outside the top-left block (off-by-one)"
    # Shear: the 1px vertical fiducial must sit at the same x on the first row
    # and the last row. A wrongly assumed scanline stride drifts it down the
    # image instead of failing outright.
    assert_px "$f" "$PAT_FIDX" 0 255,255,0 "vertical fiducial on the first row"
    assert_px "$f" "$PAT_FIDX" $((h-1)) 255,255,0 "vertical fiducial on the last row (shear)"
    assert_px "$f" $((PAT_FIDX-1)) 0 32,64,96 "left of the vertical fiducial"
    assert_px "$f" $((PAT_FIDX+1)) $((h-1)) 32,64,96 "right of the vertical fiducial"
    # The horizontal fiducial, and a block at deliberately un-round coordinates.
    assert_px "$f" $((w/2)) "$PAT_FIDY" 255,0,255 "horizontal fiducial"
    assert_px "$f" $((PAT_ODDX+2)) $((PAT_ODDY+2)) 0,255,255 "block at un-round coordinates"
    assert_px "$f" $((PAT_ODDX-1)) $((PAT_ODDY+2)) 32,64,96 "left of the un-round block"
    log "pixels: $(basename "$f") matches the painted pattern in colour and position"
}

# assert_same crops the region out of the full capture and requires the region
# capture to be identical to it.
#
# This pins the region's ORIGIN without needing any pattern at all: if the
# decoder applied any position-dependent transform, cropping the transformed
# full image would not equal the transform of the server-side sub-rectangle.
# (It says nothing about channel swaps, which are position-independent.)
assert_same() { # $1: full capture; $2: region capture; $3: WxH+X+Y
    local diff
    convert "$1" -crop "$3" +repage "$ART/.crop.png" \
        || fail "could not crop $3 out of $(basename "$1")"
    diff=$(compare -metric AE "$ART/.crop.png" "$2" null: 2>&1) \
        || true   # compare exits non-zero whenever the images differ at all
    [ "$diff" = 0 ] \
        || fail "region $(basename "$2") differs from the same crop of the full capture in $diff pixel(s): the region origin is wrong"
    rm -f "$ART/.crop.png"
    ev_pass "region $(basename "$2") is exactly the $3 crop of the full capture (compare -metric AE: 0 pixels differ)"
    log "region: $(basename "$2") is exactly $3 of the full capture"
}

# orientation_scores cross-checks the capture against QEMU's own screendump of
# the same display - a completely independent capture path (the emulator
# reading its framebuffer vs. our X11 GetImage) - and sets ORI_S0..ORI_S3 to
# the four RMSE scores: upright, flipped, mirrored, rotated 180 degrees. (Not
# printed: called as $(...), its fail() would end only the subshell.)
#
# Scored by margin, not by demanding identity: a pointer drawn into one
# capture and not the other, or any pixel the emulator and X disagree on,
# would fail an exact comparison without the capture being wrong. What must
# hold is that the upright comparison beats every flipped, mirrored and
# rotated variant by a wide margin (S7.5.6). On the e2e VM the two are in
# fact identical (RMSE 0): virtio-vga's pointer is a hardware cursor, which
# neither capture includes. A missing reference or one of another size
# fails: it used to skip with a warning, which let the check pass without
# ever running.
orientation_scores() { # $1: capture; $2: reference screendump
    local ref="$2" cap_geom ref_geom
    [ -s "$ref" ] || fail "no reference screendump at $ref to cross-check the capture against"
    cap_geom=$(identify -format '%wx%h' "$1") || fail "could not read the size of $1"
    ref_geom=$(identify -format '%wx%h' "$ref") || fail "could not read the size of $ref"
    [ "$cap_geom" = "$ref_geom" ] \
        || fail "the capture is $cap_geom but QEMU's screendump of the same moment is $ref_geom"
    ORI_S0=$(rmse "$1" "$ref" "")           || fail "could not score the capture against the reference screendump"
    ORI_S1=$(rmse "$1" "$ref" "-flip")      || fail "could not score the capture against the flipped screendump"
    ORI_S2=$(rmse "$1" "$ref" "-flop")      || fail "could not score the capture against the mirrored screendump"
    ORI_S3=$(rmse "$1" "$ref" "-rotate 180") || fail "could not score the capture against the rotated screendump"
    rm -f "$ART/.ref.png"
}
# orientation_ok <s0> <s1> <s2> <s3>: the upright score is under a quarter of
# the best (lowest) score of the three transformed variants.
orientation_ok() {
    awk -v s0="$1" -v s1="$2" -v s2="$3" -v s3="$4" 'BEGIN {
        best = s1; if (s2 < best) best = s2; if (s3 < best) best = s3;
        exit !(s0 < 0.25 * best) }'
}

# rmse scores two images, optionally transforming the second first, and prints
# the normalised 0..1 distance.
#
# `compare` exits NON-ZERO whenever the images differ at all, which is the
# normal case here - the cursor alone guarantees it - so its status must be
# discarded explicitly. Under this script's `set -e`, letting it escape makes
# `s=$(rmse ...)` abort the whole run with no message at all.
rmse() { # $1: image; $2: reference; $3: imagemagick transform for the reference
    local ref="$2" out score
    if [ -n "$3" ]; then
        # shellcheck disable=SC2086
        convert "$2" $3 "$ART/.ref.png" || { echo "rmse: could not transform the reference" >&2; return 1; }
        ref="$ART/.ref.png"
    fi
    out=$(compare -metric RMSE "$1" "$ref" null: 2>&1 || true)
    score=$(sed -n 's/.*(\([0-9.]*\)).*/\1/p' <<<"$out")
    [ -n "$score" ] || { echo "rmse: could not read a score from: $out" >&2; return 1; }
    printf '%s\n' "$score"
}

# Audio analogue of screendump: wavcapture taps the guest's HDA output
# into a WAV in the artifacts dir. Each start/stop cycle occupies capture
# index 0 (verified: the index is a list position, freed by stopcapture).
# stopcapture also finalizes the WAV header - never skip it.
audio_capture_start() { mon_cmd "wavcapture $PWD/$ART/$1.wav snd0 44100 16 2"; sleep 1; }
audio_capture_stop()  { mon_cmd "stopcapture 0"; sleep 1; }

log "prepare disk and cloud-init seed"
qemu-img create -f qcow2 -b "$IMG" -F qcow2 "$DISK" 20G >/dev/null
ssh-keygen -q -t ed25519 -N '' -f id_ed25519
cat > user-data <<EOF
#cloud-config
users:
  - name: rocky
    sudo: ALL=(ALL) NOPASSWD:ALL
    ssh_authorized_keys:
      - $(cat id_ed25519.pub)
EOF
printf 'instance-id: e2e\nlocal-hostname: e2e\n' > meta-data
cloud-localds seed.img user-data meta-data

# Two keyboards, on purpose.
#
# virtio-keyboard-pci is the session's keyboard and stays put. kvmkbd is a USB
# keyboard on an xHCI controller, and it is the one the KVM-switch simulation
# unplugs and replugs.
#
# USB rather than PCI because that is what a KVM switch actually is, and
# because PCI hot-unplug is the wrong tool: device_del on a PCI device asks the
# guest to release it over ACPI and WAITS for the acknowledgement, which a
# device X currently holds open may never send. USB device removal is immediate
# and needs no guest cooperation - exactly like yanking the cable a KVM
# switches.
#
# Keeping the virtio keyboard also means the guest is never left with no
# keyboard, which is why the typing check after the cycle is a session-health
# check rather than proof about which device carried the keystrokes.
#
# Two display connectors, on purpose - max_outputs=2 on the virtio-vga.
#
# virtio-gpu derives connector status straight from whether QEMU has that
# scanout enabled, and QEMU enables scanout 0 at realize and only ever adds
# more when a UI frontend reports geometry for them. Under `-display none`
# nothing ever does. So the guest boots with Virtual-1 connected and
# Virtual-2 PERMANENTLY DISCONNECTED - a monitor-shaped hole, free, with no
# DDC emulation involved.
#
# That hole is what makes the fixed monitor layout testable here. Its
# load-bearing claim is that a declared output comes up at the declared
# geometry on a connector the driver says is not connected, which is the hard
# half of surviving a KVM switch; phase-deploy declares a two-monitor layout
# across these two connectors and asserts exactly that. See "fixed monitor
# layout" in vm-guest.sh for what this does and does not prove.
#
# Everything else on the display is unaffected: with no layout declared, X
# autodetects and never enables a disconnected output, so the second
# connector is inert for the rest of the suite.
#
# One frontend is attached all the same: a VNC server bound to head 1, which
# nothing talks to until the monitor stories under autodetection (S3.10.5,
# S3.10.7). There vnc-head.py asks it for a size with SetDesktopSize, and
# QEMU does what it does for any frontend that reports one: it enables head
# 1 with an EDID of that size and tells the guest, which sees a monitor
# plugged in. 0x0 takes it away. With no VNC client connected the server
# only re-arms its refresh timer every 3 s.
log "boot VM (KVM, virtio-vga with 2 connectors, virtio input, intel-hda)"
qemu-system-x86_64 \
    -enable-kvm -cpu host -m 6144 -smp 3 \
    -drive "file=$DISK,if=virtio" \
    -drive "file=seed.img,if=virtio,format=raw" \
    -device virtio-vga,max_outputs=2,id=vga0 -display none \
    -vnc "unix:$VNC1,display=vga0,head=1" \
    -device virtio-keyboard-pci -device virtio-tablet-pci \
    -device qemu-xhci,id=xhci -device usb-kbd,id=kvmkbd,bus=xhci.0 \
    -audiodev none,id=snd0 -device intel-hda -device hda-duplex,audiodev=snd0 \
    -netdev "user,id=n0,hostfwd=tcp:127.0.0.1:$SSHPORT-:22" -device virtio-net-pci,netdev=n0 \
    -monitor "unix:$MON,server,nowait" \
    -qmp "unix:$QMP,server,nowait" \
    -qmp "unix:$QMPV,server,nowait" \
    -serial "file:$ART/serial.log" \
    -msg timestamp=on -D "$PWD/$ART/qemu-trace.log" \
    -trace enable=hda_audio_overrun -trace enable=hda_audio_adjust \
    -daemonize -pidfile qemu.pid

log "wait for ssh"
for _ in $(seq 60); do
    vm_ssh_quick true 2>/dev/null && break
    sleep 5
done
vm_ssh_quick true || fail "VM never became reachable"
VM_UP=1

# The run's manifest (Requirements.md, report layout): what was tested, on
# what, so evidence from different shards and runs can be compared. Written
# now and again once phase-deploy has installed podman, which the stock cloud
# image lacks.
write_manifest() {
python3 - "$ART/run.json" "$SHARD" \
    "$(vm_ssh_quick 'uname -r; cat /etc/rocky-release; getenforce; podman --version 2>/dev/null || echo "not installed yet"' 2>/dev/null | paste -sd'|')" <<'PY' || true
import json, os, platform, subprocess, sys
def out(*cmd):
    try:
        return subprocess.run(cmd, capture_output=True, text=True, timeout=20).stdout.strip()
    except Exception as e:  # recorded, not fatal: the manifest describes, it does not test
        return f"unavailable: {e}"
images = {}
if os.path.exists("image-ids.txt"):
    for line in open("image-ids.txt"):
        name, _, ident = line.strip().partition(" ")
        if name:
            images[name] = ident
guest = sys.argv[3].split("|") + ["", "", "", ""]
json.dump({"shard": sys.argv[2], "source": os.environ.get("EV_SOURCE", ""),
           "git": out("git", "-C", "../..", "rev-parse", "HEAD"),
           "date": out("date", "-u", "+%Y-%m-%dT%H:%M:%SZ"),
           "qemu": (out("qemu-system-x86_64", "--version").splitlines() or [""])[0],
           "runner_kernel": platform.release(),
           "guest": {"kernel": guest[0], "release": guest[1], "selinux": guest[2], "podman": guest[3]},
           "images": images}, open(sys.argv[1], "w"), indent=1)
PY
}
write_manifest

log "transfer repo + images"
git -C ../.. archive --format=tar.gz -o "$PWD/repo.tgz" HEAD
scp -q -P "$SSHPORT" -i id_ed25519 -o StrictHostKeyChecking=no \
    -o UserKnownHostsFile=/dev/null repo.tgz \
    images-desktop.tar images-plugin.tar images-testclient.tar \
    rocky@127.0.0.1:/tmp/

# Every failure handler below tees its diagnostic rather than redirecting it.
# Redirecting put the journal, the AVC denials and the pod descriptions in an
# artifact zip and NOWHERE else, so a red run showed only "guest phase-deploy
# failed" and finding out why meant downloading it. The artifact is still
# written; the job log just stops being useless.
log "phase deploy: the declarative tree on a stock host (SELinux enforcing)"
# The one host-setup path there is: the deploy tree applied over a stock
# Rocky host - the boot getty seat-prep must evict, the root-owned
# desktop-shell ssh trust under enforcing SELinux, the stub CDI path next
# to a REAL KMS display, the podman client CDI contract, and
# desktop-preflight fully green.
#
# Every shard deploys; only the shard that runs the rest of the deploy-tree
# checks (core) records phase deploy's stories, so they are not filed three
# times.
vm_ssh 'mkdir -p repo && tar -xzf /tmp/repo.tgz -C repo' || fail "could not unpack the repo in the VM"
pd_ev=""
in_shard core && pd_ev=$GUEST_EV
guest_ev "$pd_ev" phase-deploy \
    || { vm_ssh 'sudo journalctl -b --no-pager | tail -150; echo ---; sudo ausearch -m avc -ts recent 2>/dev/null | tail -40' \
         2>&1 | tee "$ART/guest-deploy-fail.log" || true; fail "guest phase-deploy failed"; }

log "fixed monitor layout: declared across a connector QEMU never connects, then unplugged and restored"
# vm-guest.sh's layout steps, one call each, so this side can look at the
# display between them. Every shard runs them, as phase deploy always did;
# only core records their stories, and only core adds what QEMU sees.
guest_ev "$pd_ev" layout-declare || fail "fixed monitor layout: the declared layout did not come up"
if in_shard core; then
    # S3.4.9: one screendump per head while the declared layout is live. An
    # xterm placed on Virtual-2's half gives that head something X drew.
    EV_SIDE=h-
    ev_begin S3.4.9 "A declared output comes up on a disconnected connector" T3
    vm_ssh 'sudo podman exec -d -u desktop -e DISPLAY=:0 -e HOME=/home/desktop desktop xterm -T head2-proof -geometry 60x12+1200+200'
    sleep 3
    for head in 0 1; do
        if [ "$head" = 0 ]; then what="Virtual-1, the connected output: the session's xterm on it"
        else what="Virtual-2, the disconnected output: the head2-proof xterm X drew at +1200+200"; fi
        shot=$(ev_shot_head "head$head" "$head" "EV-SHOT: QEMU's screendump of the virtio-vga's head $head - $what") \
            || fail "no screendump of head $head"
        read -r size sd <<<"$shot"
        [ "$size" = 1024x768 ] || fail "head $head's screendump is $size, want the declared 1024x768"
        awk "BEGIN{ exit !($sd > 0.02) }" || fail "head $head is blank (grayscale stddev $sd): X does not draw there"
        ev_pass "head $head scans out 1024x768 and X draws on it (grayscale stddev $sd)"
    done
    ev_end
    EV_SIDE=
fi
guest_ev "$pd_ev" layout-roundtrip || fail "fixed monitor layout: the captured block did not round-trip"
if in_shard core; then
    # The video of the live disconnect and re-plug: S3.4.10 holds it, and
    # S3.10.1-S3.10.3 cite it.
    EV_SIDE=h-
    ev_begin S3.4.10 "A live disconnect does not move the geometry" T3
    ev_video_start live-disconnect
fi
guest_ev "$pd_ev" layout-unplug || fail "fixed monitor layout: the live disconnect or the re-plug moved something"
if in_shard core; then
    ev_video_stop "EV-VIDEO: head 0 across Virtual-1's forced disconnect and its re-plug (the guest's notes give both times); nothing on it should move"
    ev_end
    # S7.7.3: the client's own view before, while Virtual-1 was off and after
    # the re-plug, compared over its window and over the whole screen.
    ev_begin S7.7.3 "Client windows stay put across a monitor plug-out and re-plug (layout declared)" T3
    s773_view() { ls "$EV_ROOT/S7.7.3/"*"-client-view-$1.png" 2>/dev/null | sed -n 1p; }
    s773_rect=$(awk '/Absolute upper-left X/ {x = $NF} /Absolute upper-left Y/ {y = $NF} /^ *Width:/ {w = $NF} /^ *Height:/ {h = $NF} END {if (w) printf "%dx%d+%d+%d", w, h, x, y}' \
        "$(ls "$EV_ROOT/S7.7.3/"*-xwininfo-before.txt 2>/dev/null | sed -n 1p)")
    [ -n "$s773_rect" ] || fail "S7.7.3: no window rectangle in the client's xwininfo"
    for s773_m in during after; do
        s773_a=$(s773_view before) s773_b=$(s773_view "$s773_m")
        [ -n "$s773_a" ] && [ -n "$s773_b" ] || fail "S7.7.3: the client's own screenshot before or $s773_m is missing"
        convert "$s773_a" -crop "$s773_rect" +repage "${ART:?}/.s773-a.png" \
            && convert "$s773_b" -crop "$s773_rect" +repage "${ART:?}/.s773-b.png" \
            || fail "S7.7.3: could not cut the client's window out of its screenshots"
        s773_win_ae=$(compare -metric AE "${ART:?}/.s773-a.png" "${ART:?}/.s773-b.png" null: 2>&1 | awk '{print $1}' || true)
        s773_all_ae=$(compare -metric AE "$s773_a" "$s773_b" null: 2>&1 | awk '{print $1}' || true)
        rm -f "${ART:?}/.s773-a.png" "${ART:?}/.s773-b.png"
        ev_note "the client's own view, before against $s773_m: ${s773_win_ae:-?} pixels differ over its window ($s773_rect), ${s773_all_ae:-?} over the whole screen"
        [ "${s773_win_ae:-x}" = 0 ] || fail "S7.7.3: the client's own view of its window differs before and $s773_m (${s773_win_ae:-?} pixels)"
        ev_pass "the client's own view of its window ($s773_rect) is the same before and $s773_m: 0 pixels differ (over the whole screen: ${s773_all_ae:-?})"
    done
    ev_end
    EV_SIDE=
fi
guest_ev "$pd_ev" layout-restore || fail "fixed monitor layout: the shipped config did not restore autodetection"
if in_shard core; then
    # S3.10.5-S3.10.7 under autodetection. QEMU itself plugs a monitor into
    # Virtual-2 and takes it away again (vnc_head, through the VNC server on
    # head 1); the guest's steps run one at a time so that this side can
    # plug, unplug, shoot and record between them.
    log "monitors under autodetection: a plug-in, the only output's plug-out, an EDID's modes"
    EV_SIDE=h-
    S5_T="Monitor plug-in without a layout is detected and does not reflow"
    S6_T="Monitor plug-out without a layout is characterised"
    S7_T="A plugged-in monitor with an EDID exposes modes"
    ev_begin S3.10.5 "$S5_T" T3; ev_video_start ad-plugin; ev_end
    guest_ev "$GUEST_EV" autodetect plugin before || fail "S3.10.5: the state before the plug-in is not what it should be"
    ev_begin S3.10.5 "$S5_T" T3
    vnc_head vnc-plug 1024 768 "EV-QEMU: vnc-head.py 1024 768: QEMU asked, through its VNC server on head 1, to plug a 1024x768 monitor into Virtual-2, and its answer" \
        || fail "S3.10.5: QEMU did not take the request to plug a monitor into head 1"
    ev_end
    guest_ev "$GUEST_EV" autodetect plugin on || fail "S3.10.5: the plugged-in monitor was not detected as it should be, or something moved"
    ev_begin S3.10.5 "$S5_T" T3
    vnc_head vnc-unplug 0 0 "EV-QEMU: vnc-head.py 0 0: QEMU asked to take the monitor away from head 1, and its answer" \
        || fail "S3.10.5: QEMU did not take the request to unplug head 1"
    ev_end
    guest_ev "$GUEST_EV" autodetect plugin off || fail "S3.10.5: Virtual-2 did not go back to disconnected"
    ev_begin S3.10.5 "$S5_T" T3
    ev_video_stop "EV-VIDEO: head 0 while QEMU plugged a monitor into Virtual-2 and took it away, no layout declared (the notes give the times): nothing on it should move"
    ev_end
    ev_begin S3.10.6 "$S6_T" T3; ev_video_start ad-unplug; ev_end
    guest_ev "$GUEST_EV" autodetect unplug || fail "S3.10.6: X did not live through its only output's plug-out as it should"
    ev_begin S3.10.6 "$S6_T" T3
    ev_video_stop "EV-VIDEO: head 0 while Virtual-1, the only enabled output, was forced off and set back to detect"
    ev_end
    ev_begin S3.10.7 "$S7_T" T3; ev_video_start ad-edid; ev_end
    guest_ev "$GUEST_EV" autodetect edid prep || fail "S3.10.7: the EDID could not be injected"
    ev_begin S3.10.7 "$S7_T" T3
    vnc_head vnc-plug 1024 768 "EV-QEMU: vnc-head.py 1024 768: QEMU asked, through its VNC server on head 1, to plug a 1024x768 monitor into Virtual-2, and its answer" \
        || fail "S3.10.7: QEMU did not take the request to plug a monitor into head 1"
    ev_end
    guest_ev "$GUEST_EV" autodetect edid on || fail "S3.10.7: the monitor's EDID or modes were not the injected ones, or it would not enable"
    ev_begin S3.10.7 "$S7_T" T3
    shot=$(ev_shot_head head1-enabled 1 "EV-SHOT: QEMU's screendump of head 1, Virtual-2's scanout, enabled at 1024x768 by xrandr --auto at +0+0: the desktop's top-left 1024x768") \
        || fail "S3.10.7: no screendump of head 1"
    [ "${shot%% *}" = 1024x768 ] || fail "S3.10.7: head 1's screendump is ${shot%% *}, not 1024x768"
    awk -v s="${shot#* }" 'BEGIN { exit !(s > 0.01) }' || fail "S3.10.7: head 1's screendump is blank (grayscale stddev ${shot#* })"
    ev_pass "QEMU's head 1 shows Virtual-2's scanout: a ${shot%% *} image, not blank (grayscale stddev ${shot#* })"
    ev_end
    guest_ev "$GUEST_EV" autodetect edid off || fail "S3.10.7: Virtual-2 would not turn off"
    ev_begin S3.10.7 "$S7_T" T3
    vnc_head vnc-unplug 0 0 "EV-QEMU: vnc-head.py 0 0: QEMU asked to take the monitor away from head 1, and its answer" \
        || fail "S3.10.7: QEMU did not take the request to unplug head 1"
    ev_end
    guest_ev "$GUEST_EV" autodetect edid gone || fail "S3.10.7: Virtual-2 did not withdraw cleanly"
    ev_begin S3.10.7 "$S7_T" T3
    ev_video_stop "EV-VIDEO: head 0 while Virtual-2 got its EDID, was plugged in, enabled with xrandr --auto, turned off and taken away: Virtual-1 should not change"
    ev_end
    EV_SIDE=
fi
vm_ssh 'sudo repo/ci/vm/vm-guest.sh deploy-proof' || fail "could not put the deploy-proof xterm up"
write_manifest
screendump desktop-deploy
assert_nonblank desktop-deploy

# ---- shard: core -------------------------------------------------------------
if in_shard core; then

log "sshd: the deploy tree's drop-in keeps stock home-dir key logins working"
# Every vm_ssh since phase deploy reloaded sshd has needed this; here it is
# looked at: the drop-in, what sshd makes of it, and a login that used the
# home-dir key after the reload.
ev_begin S5.7.6 "The sshd drop-in keeps stock key logins working" T3
ev_save drop-in "EV-CONFIG: the sshd_config.d drop-in the deploy tree installed: the stock path first, then the root-owned one" \
    vm_ssh_quick 'cat /etc/ssh/sshd_config.d/40-desktop-container.conf' >/dev/null \
    || fail "the deploy tree's sshd drop-in is missing"
eff=$(ev_save sshd-config "EV-STATE: sshd -T's authorizedkeysfile: what sshd makes of its config with the drop-in in place" \
    vm_ssh_quick 'sudo sshd -T | grep -i "^authorizedkeysfile"') || fail "sshd -T failed"
grep -qix 'authorizedkeysfile .ssh/authorized_keys /etc/ssh/authorized_keys.d/%u' <<<"$eff" \
    || fail "sshd's AuthorizedKeysFile is '$eff', want the stock .ssh/authorized_keys first and /etc/ssh/authorized_keys.d/%u after it"
ev_pass "sshd reads both paths, the stock home-dir one first: $eff"
login=$(ev_save login "EV-STATE: a fresh ssh login as rocky, its home-dir key file, and from sshd's journal this boot: the reload, then the newest accepted key login for rocky" \
    vm_ssh_quick 'echo "logged in as $(id -un)"; ls -l ~/.ssh/authorized_keys; sudo journalctl -u sshd -b --no-pager -o short-iso | grep -m1 "Received SIGHUP"; sudo journalctl -u sshd -b --no-pager -o short-iso | grep "Accepted publickey for rocky" | tail -1') \
    || fail "ssh as rocky failed with the drop-in active"
grep -qx 'logged in as rocky' <<<"$login" || fail "the login did not land as rocky"
hup=$(grep -m1 'Received SIGHUP' <<<"$login" | cut -d' ' -f1)
acc=$(grep 'Accepted publickey for rocky' <<<"$login" | tail -1 | cut -d' ' -f1)
[ -n "$hup" ] || fail "sshd's journal shows no reload this boot, so the drop-in may not be what it runs with"
[ -n "$acc" ] && [[ ! "$acc" < "$hup" ]] \
    || fail "no key login for rocky accepted after sshd's reload at $hup (newest: ${acc:-none})"
ev_pass "rocky's home-dir key was accepted after sshd reloaded with the drop-in (reload $hup, login $acc)"
ev_end

log "privileges: the desktop container runs with less than --privileged"
guest_ev "$GUEST_EV" verify-privileges \
    || { vm_ssh 'sudo podman inspect desktop --format "{{.HostConfig.Privileged}} {{.HostConfig.CapAdd}}"; sudo podman exec desktop sh -c "grep -E \"^(Cap|Seccomp)\" /proc/\$(cat /run/desktop-init.pid)/status"' \
         2>&1 | tee "$ART/privileges-fail.log" || true; fail "privilege assertions failed"; }

log "runtime: the session's process session, no TCP listener, open local access, the udev database"
guest_ev "$GUEST_EV" verify-runtime \
    || fail "the running session, X server or udev database is not as specified"

log "logging: both log sinks are bounded, on the running container"
# Reports the host's DEFAULT log driver alongside the assertion: that default
# is what this unit would have inherited without LogDriver=, and it is the
# thing that made the old behaviour unpredictable per distro.
vm_ssh 'sudo repo/ci/vm/vm-guest.sh verify-log-bounds' \
    || { vm_ssh 'echo "-- host podman default log driver (what we would have inherited):"; sudo podman info --format "{{.Host.LogDriver}}"; echo "-- this container:"; sudo podman inspect desktop --format "{{json .HostConfig.LogConfig}}"; echo "-- journald config in the container:"; sudo podman exec desktop systemd-analyze cat-config systemd/journald.conf' \
         2>&1 | tee "$ART/log-bounds-fail.log" || true; fail "log bound assertions failed"; }

log "audio: record each client path (pulse, pipewire, ALSA) individually"
# One capture cycle per player so every path is acoustically verified on
# its own - an aggregate capture would let one silent path hide behind
# the others. Each guest call blocks until its 1.5s burst finishes, so
# the capture window brackets it. On failure still stop the capture: the
# partial WAV is a debugging artifact and stopping finalizes its header.
ev_begin S4.1.2 "In-container clients use the per-user sockets, and the operator hears them" T3
for path in pulse pipewire alsa; do
    hz=$(freq_for "$path")
    ev_audio_start "audio-$path" "$hz"
    vm_ssh "sudo repo/ci/vm/vm-guest.sh play-audio $path" \
        || { audio_capture_stop; fail "guest play-audio $path failed"; }
    ev_shot "xterm-$path" "EV-SHOT: the xterm (title audio-$path) on :0 that ran the $path player, still up and showing that it finished with exit 0"
    ev_audio_stop "EV-AUDIO: the machine's output while the desktop session's $path client played its $hz Hz tone - listen for one beep" 1 0.05 "$hz" \
        || fail "$path audio capture is empty or silent"
    ev_pass "the $path path ($([ "$path" = alsa ] && echo "ALSA via pipewire-alsa" || echo "$path")) played from an xterm in the session and the machine's output carried its $hz Hz tone"
done
ev_end

log "audio lifecycle: independent of the X session, and recovers on its own"
# Deliberately AFTER the three tone tests: they establish that a healthy
# stack works, and this one then kills things. It restarts the X session
# and PipeWire, so anything ordered after it must not assume either kept
# its pid - the input tests below re-establish their own state anyway.
# S4.5.1: a 20 s tone from a pulse client outside the X session plays while
# the guest kills Xorg and waits for the new session (verify-audio-x); it
# must play on with no gap, no stall and none of it missing.
EV_SIDE=h-
ev_begin S4.5.1 "Audio survives an X session restart" T3
ev_save sched-before "EV-STATE: PipeWire's threads with their scheduling class and realtime priority, and pw-top's batch view (each node's ERR column counts its xruns), before the tone" \
    gq audio-sched >/dev/null || true
t_cap0=$(date +%s.%N) g_cap0=$(gnow)
ev_audio_start through-x 1100
gq tone-start s451 1100 20 - >/dev/null || { audio_capture_stop; fail "could not start the 20 s tone for S4.5.1"; }
ev_end
EV_SIDE=
sleep 3
guest_ev "$GUEST_EV" verify-audio-x || { audio_capture_stop; fail "audio did not survive an X session restart"; }
EV_SIDE=h-
ev_begin S4.5.1 "Audio survives an X session restart" T3
for _ in $(seq 40); do st=$(gq tone-status s451 2>/dev/null | sed -n 1p || true); [ "${st%% *}" = exited ] && break; sleep 1; done
ev_save player "EV-LOG-CLIENT: the pulse client's player (paplay, in the desktop container but outside the X session): its exit status, how long it played and from when to when, its pid, its output" \
    gq tone-status s451 >/dev/null || true
player=$(ev_payload "$EV_DIR/$EV_LAST")
# The kill's time on the guest's clock, which the player's times share.
t_kill=$(vm_ssh_quick 'cat /run/verify-audio-x.kill' 2>/dev/null || true)
p_t0=$(awk '/^played/ {print $5}' <<<"$player")
mark=$(awk -v k="$t_kill" -v s="$p_t0" 'BEGIN {if (k != "" && s != "") printf "%.2f", k - s}')
heard=yes
t_cap1=$(date +%s.%N)
ev_audio_stop "EV-AUDIO: the machine's output while a pulse client played a 20 s 1100 Hz tone, the X server killed a few seconds in (the plot's red line, timed by the player's clock): it must play on with no gap and none of it missing" \
    15 0.05 1100 --max-gap 0.1 --span 19.6 20.6 ${mark:+--mark "$mark"} || heard=no
audio_window_record "$t_cap0" "$t_cap1" "$g_cap0"
grep -q '^exited 0$' <<<"$player" || fail "the S4.5.1 player did not end cleanly: $(echo $player)"
played=$(awk '/^played/ {print $2}' <<<"$player")
python3 -c 'import sys; sys.exit(0 if float(sys.argv[1]) <= 21.0 else 1)' "${played:-99}" \
    || fail "the 20 s tone took ${played:-?} s to play: its stream stalled across the X restart"
ev_pass "the player played its 20 s tone in ${played} s and exited 0: the stream never stalled"
[ "$heard" = yes ] || fail "the tone did not play on whole across the X restart (check-audio's verdict says where)"
ev_pass "the machine's output carried the tone across the X restart: no stretch below -40 dBFS longer than 0.1 s, and its 20 s span with nothing missing"
ev_end
EV_SIDE=
guest_ev "$GUEST_EV" verify-audio-lifecycle \
    || fail "audio lifecycle assertions failed"
# S4.5.2's EV-AUDIO: the recovered stack plays, heard at the machine's
# output - before S2.3.5's step kills Xorg.
EV_SIDE=h-
ev_begin S4.5.2 "Audio recovers from its own crash without disturbing X" T3
hz=$(freq_for pulse)
ev_audio_start after-recovery "$hz"
vm_ssh 'sudo repo/ci/vm/vm-guest.sh play-audio pulse' \
    || { audio_capture_stop; fail "a pulse client could not play after pipewire's recovery"; }
ev_audio_stop "EV-AUDIO: the machine's output after PipeWire was killed and came back on its own, while a pulse client played its $hz Hz tone - listen for one beep" 1 0.05 "$hz" \
    || fail "audio is silent after pipewire's recovery"
ev_pass "after the recovery a pulse client's $hz Hz tone came out of the machine"
ev_end
EV_SIDE=

log "audio daemons: wireplumber alone, then pipewire-pulse alone, each restarts the whole stack"
guest_ev "$GUEST_EV" verify-audio-restarts \
    || fail "a single audio daemon's exit did not restart the whole stack"
EV_SIDE=h-
ev_begin S2.4.2 "Any daemon exiting restarts the whole stack" T3
hz=$(freq_for pulse)
ev_audio_start after-restarts "$hz"
vm_ssh 'sudo repo/ci/vm/vm-guest.sh play-audio pulse' \
    || { audio_capture_stop; fail "a pulse client could not play after the stack's restarts"; }
ev_audio_stop "EV-AUDIO: the machine's output after the two restarts, while a pulse client played its $hz Hz tone - listen for one beep" 1 0.05 "$hz" \
    || fail "audio is silent after the stack's restarts"
ev_pass "after both restarts a pulse client's $hz Hz tone came out of the machine"
ev_end
EV_SIDE=

log "audio export: the unprivileged rocky user on the VM host plays through it"
ev_begin S2.4.7 "Export sockets are connectable by other uids" T3
ev_audio_start rocky 880
ev_save as-rocky "EV-STATE: as the unprivileged rocky user on the VM host: id, ls -l /run/desktop-audio, pactl info over the export, then paplay of an 880 Hz tone" \
    vm_ssh 'sudo repo/ci/vm/vm-guest.sh play-as-rocky 880 3' >/dev/null || true
rocky=$(ev_payload "$EV_DIR/$EV_LAST")
ev_audio_stop "EV-AUDIO: the machine's output while rocky's paplay played 880 Hz through the export - listen for one beep" 2 0.05 880 \
    || fail "rocky's 880 Hz tone was not heard"
grep -q '^uid=[1-9][0-9]*(rocky)' <<<"$rocky" || fail "the probe did not run as the unprivileged rocky user: $(grep '^uid=' <<<"$rocky")"
ev_pass "the probe ran as $(grep -o '^uid=[0-9]*(rocky)' <<<"$rocky"), not root"
grep -q '^Server Name: ' <<<"$rocky" || fail "rocky's pactl info over the export failed"
ev_pass "rocky's pactl info over the export answered: $(grep '^Server Name: ' <<<"$rocky")"
grep -q '^paplay exited 0$' <<<"$rocky" || fail "rocky's paplay did not exit 0: $(grep '^paplay exited' <<<"$rocky")"
ev_pass "rocky's paplay played its 880 Hz tone through the export, heard at the machine's output"
ev_end

log "a killed X server leaves a postmortem"
guest_ev "$GUEST_EV" verify-postmortem \
    || fail "postmortem assertions failed"

log "session restart: what goes with a killed X server, what stays, and the VT"
# The guest moves the console to tty2, kills Xorg and judges what went and
# what stayed (verify-session-restart); the display is recorded from before
# the kill until the new session's desktop is back (S2.3.2), then shot
# (S3.2.5: the desktop on tty1, not a text console).
EV_SIDE=h-
ev_begin S2.3.2 "The session restarts after Xorg exits, and the operator gets the desktop back" T3
ev_video_start session-restart
ev_end
EV_SIDE=
guest_ev "$GUEST_EV" verify-session-restart \
    || fail "the session restart was not as specified"
EV_SIDE=h-
ev_begin S2.3.2 "The session restarts after Xorg exits, and the operator gets the desktop back" T3
ev_video_stop "EV-VIDEO: the display from before the kill (the console moved to tty2 first) until the new session's desktop is back (index.txt and the guest's notes give the times)"
ev_end
ev_begin S3.2.5 "The session activates its VT, so the operator sees it" T3
ev_shot desktop-back "EV-SHOT: the display once the new session is up: the desktop on tty1, not tty2's text console"
ev_end
EV_SIDE=

log "input: type into an xterm with the real virtual keyboard, verify the app got it"
# Prove the whole input path (QEMU HID -> evdev -> Xorg -> focused app), not
# just that a device enumerates. A sink xterm runs `read`; we click it to
# focus (mwm is click-to-focus) and type via QMP input-send-event. Runs
# BEFORE the hotplug tests, so it is the boot-time keyboard on a desktop
# nothing has changed yet. (Xorg does adopt a hot-added keyboard: S3.9.2
# checks that xinput lists it.)
res=$(vm_ssh 'sudo podman exec -u desktop -e DISPLAY=:0 desktop \
    sh -c "xdpyinfo | awk \"/dimensions:/{print \\\$2; exit}\""')
[ -n "$res" ] || fail "could not read display resolution for input injection"
ev_begin S3.8.1 "Typed input reaches the focused application" T3
vm_ssh 'sudo repo/ci/vm/vm-guest.sh input-sink-start'
sleep 2
# Click + type at the centre of the sink window (geometry 100x30+250+200).
qlog=$(ev_name qmp-input txt)
QMP_TRANSCRIPT="$EV_DIR/$qlog" python3 qmp-type.py "$QMP" "$res" 550 395 inputok
ev_attach "$qlog" "EV-QEMU: every QMP command sent - the pointer to the sink xterm's centre (550,395 on $res), a left click to focus it, then i n p u t o k Return as key events"
sleep 2
ev_shot input-typed "EV-SHOT: the sink xterm (title inputtest) right after the keystrokes"
ev_save sink-file "EV-LOG-CLIENT: what the sink xterm's shell read from the keyboard (/tmp/inputproof in the desktop container); must be exactly 'inputok'" \
    vm_ssh 'sudo podman exec desktop cat /tmp/inputproof 2>/dev/null; echo' >/dev/null || true
vm_ssh 'sudo repo/ci/vm/vm-guest.sh input-sink-check inputok' \
    || { vm_ssh 'sudo podman exec desktop cat /tmp/inputproof 2>/dev/null' \
         2>&1 | tee "$ART/input-proof.txt" || true; fail "typed text did not reach the app"; }
ev_pass "the focused xterm's shell read 'inputok', typed through QEMU's keyboard"
ev_end

log "input hotplug: add a virtio keyboard while X runs"
# Three layers, measured separately, because they fail for different reasons:
#   host   the VM sees the new evdev node       (QEMU + kernel)
#   nodes  it reaches the CONTAINER's /dev      (the /dev/input bind mount)
#   adds   Xorg logs an "Adding input device"   (the uevent; Network=host)
#
# The middle layer used to be broken and unmeasured: podman gives the container
# its own /dev, a tmpfs populated at creation, so nodes the host gained later
# never appeared inside. The quadlet now bind-mounts /dev/input; this is what
# holds that in place.
#
# Evidence: F3.9's common set before and after (input_set), the Xorg log's
# lines since just before the event, and the counts. S3.9.2 then reads the
# same files for Xorg's side.
ev_begin S3.9.1 "Keyboard plug-in reaches the container" T3
input_set before-pci "before device_add virtio-keyboard-pci"
input_keep
xl0=$(gq xorg-log-lines 2>/dev/null || echo 0)
before_host=$(vm_ssh_quick 'ls /dev/input/event* | wc -l')
read -r before_nodes before_adds <<<"$(hotplug_probe)"
log "  before: host=$before_host container-nodes=$before_nodes xorg-adds=$before_adds"

ev_qemu device-add-pci "EV-QEMU: device_add virtio-keyboard-pci,id=hotkbd and QEMU's reply (empty: accepted)" \
    "device_add virtio-keyboard-pci,id=hotkbd" >/dev/null \
    || fail "QEMU refused device_add virtio-keyboard-pci"

after_host=$before_host after_nodes=$before_nodes after_adds=$before_adds
for _ in $(seq 20); do
    after_host=$(vm_ssh_quick 'ls /dev/input/event* | wc -l')
    read -r after_nodes after_adds <<<"$(hotplug_probe)"
    [ "$after_host" -gt "$before_host" ] && [ "$after_nodes" -gt "$before_nodes" ] && break
    sleep 1
done
log "  after:  host=$after_host container-nodes=$after_nodes xorg-adds=$after_adds"
# Xorg adds a device after the node appears; give it a moment before the
# "after" picture, which S3.9.2 judges.
sleep 2
input_set after-pci "after the virtio keyboard was added"
input_diffs pci "the virtio keyboard's arrival"
ev_save xorg-log-pci "EV-LOG-XORG: the Xorg log's lines since just before the add" \
    gq xorg-log-since "$xl0" >/dev/null || true
PCI_XLOG=$EV_LAST PCI_B_DEV=$B_DEV PCI_A_DEV=$IN_DEV PCI_B_XI=$B_XI PCI_A_XI=$IN_XI

[ "$after_host" -gt "$before_host" ] \
    || fail "hotplugged keyboard never appeared on the VM host ($before_host -> $after_host)"
ev_pass "the VM host gained an input node: $before_host -> $after_host event nodes"
[ "$after_nodes" -gt "$before_nodes" ] \
    || fail "the new input node never reached the container ($before_nodes -> $after_nodes): the /dev/input bind mount is missing or not live"
ev_pass "the container gained it too: $before_nodes -> $after_nodes event nodes in its /dev/input"
# Recorded, not asserted here: "Adding input device" is logged when Xorg BEGINS
# handling a device, including ones it then ignores, so an increment is
# suggestive rather than proof that the device works. S3.9.2 asks for more.
log "  note: xorg-adds $before_adds -> $after_adds (log lines, not proof of a working device)"
ev_text counter-pci "the counter line for this add, as xorg-input-count.txt records it" \
    "hotplug-add     host $before_host -> $after_host / container-nodes $before_nodes -> $after_nodes / xorg-adds $before_adds -> $after_adds"
ev_end

ev_begin S3.9.2 "Keyboard plug-in is adopted by Xorg" T3
xi_judge_added S3.9.1 "$PCI_B_DEV" "$PCI_A_DEV" "$PCI_B_XI" "$PCI_A_XI" "$PCI_XLOG" "the virtio keyboard's add"
ev_end

log "KVM switch simulation: remove the keyboard and bring it back"
# What a USB KVM without HID emulation does on every switch: the devices are
# electrically disconnected from this host and re-enumerated on the way back,
# often at a different eventN. The failure this guards against is not "the new
# device does not work" but "input is dead until desktop.service restarts",
# which is far worse and only shows up on the FIRST switch back.
#
# Asserted on the node counts, in both directions, and on the removed device's
# own nodes. The removal half matters as much as the addition: a stale node
# that never disappears is exactly what a snapshot /dev looks like, and it
# would let the re-add half pass for the wrong reason.
#
# Stories: S3.9.6 holds the whole cycle (the video, the X pids, the typing
# after); S3.9.3 and S3.9.4 the removal, the container's and Xorg's side; and
# S3.9.1 again for the USB re-add, its second vehicle.
ev_begin S3.9.6 "The session accepts input after a keyboard cycle" T3
ev_save pids-before "EV-PIDS: Xorg and mwm in the desktop container before the cycle" \
    gq ctr-pids Xorg,mwm >/dev/null || true
x_pids_before=$(vm_ssh_quick 'sudo podman exec desktop pgrep -x Xorg' 2>/dev/null | paste -sd' ' || true)
ev_video_start kvm-cycle

ev_begin S3.9.3 "Keyboard plug-out removes the node from the container" T3
input_set base "before device_del kvmkbd"
input_keep
xl1=$(gq xorg-log-lines 2>/dev/null || echo 0)
kvm_base_host=$(vm_ssh_quick 'ls /dev/input/event* | wc -l')
read -r kvm_base_nodes _ <<<"$(hotplug_probe)"
log "  base:    host=$kvm_base_host container-nodes=$kvm_base_nodes"
# The keyboard's own nodes, from the kernel's table: the event handlers of
# the device named for QEMU's USB keyboard.
kvm_nodes=$(dev_events "$EV_DIR/$B_DEV" "QEMU QEMU USB Keyboard")
[ -n "$kvm_nodes" ] || fail "no 'QEMU QEMU USB Keyboard' in /proc/bus/input/devices before the switch: the boot-time USB keyboard is missing"
ev_note "the USB keyboard's event node(s) before the switch: $kvm_nodes"

ev_qemu device-del "EV-QEMU: device_del kvmkbd (the KVM switches away) and QEMU's reply (empty: accepted)" \
    "device_del kvmkbd" >/dev/null || fail "QEMU refused device_del kvmkbd"
kvm_off_host=$kvm_base_host kvm_off_nodes=$kvm_base_nodes
for _ in $(seq 20); do
    kvm_off_host=$(vm_ssh_quick 'ls /dev/input/event* | wc -l')
    read -r kvm_off_nodes _ <<<"$(hotplug_probe)"
    [ "$kvm_off_host" -lt "$kvm_base_host" ] && [ "$kvm_off_nodes" -lt "$kvm_base_nodes" ] && break
    sleep 1
done
log "  switched away: host=$kvm_off_host container-nodes=$kvm_off_nodes"
# Xorg's side of the removal (S3.9.4) is polled: xinput may lag the node.
xi_wait_gone "QEMU QEMU USB Keyboard" "$(xi_count "$EV_DIR/$B_XI" "QEMU QEMU USB Keyboard")"
input_set off "after device_del kvmkbd"
input_diffs off "the keyboard's removal"
ev_save xorg-log-off "EV-LOG-XORG: the Xorg log's lines since just before the removal" \
    gq xorg-log-since "$xl1" >/dev/null || true
OFF_XLOG=$EV_LAST OFF_B_XI=$B_XI OFF_A_XI=$IN_XI

[ "$kvm_off_host" -lt "$kvm_base_host" ] \
    || fail "device_del kvmkbd did not remove the node on the VM host ($kvm_base_host -> $kvm_off_host)"
ev_pass "the VM host lost the keyboard's node: $kvm_base_host -> $kvm_off_host event nodes"
[ "$kvm_off_nodes" -lt "$kvm_base_nodes" ] \
    || fail "the container still sees the removed keyboard ($kvm_base_nodes -> $kvm_off_nodes): its /dev/input is a stale snapshot, so a KVM switch would leave a dead node behind"
left=""
for n in $kvm_nodes; do
    grep -qE " $n\$" "$EV_DIR/$IN_CTR" && left="$left $n"
done
[ -z "$left" ] || fail "the removed keyboard's node(s)$left are still in the container's /dev/input"
want=$(( kvm_base_nodes - $(wc -w <<<"$kvm_nodes") ))
[ "$kvm_off_nodes" = "$want" ] \
    || fail "the container has $kvm_off_nodes event nodes after the removal, want $want (the $kvm_base_nodes before, less the keyboard's $(wc -w <<<"$kvm_nodes"))"
ev_pass "the keyboard's own node(s) ($kvm_nodes) are gone from the container, and its count is back to the value without the keyboard: $kvm_base_nodes -> $kvm_off_nodes"
ev_end

ev_begin S3.9.4 "Keyboard plug-out is seen by Xorg" T3
xi_judge_removed S3.9.3 "$OFF_B_XI" "$OFF_A_XI" "$OFF_XLOG" "QEMU QEMU USB Keyboard"
ev_end

# Safe to re-add immediately: USB removal completes without waiting on the
# guest, so the id is free by the time the removal shows up in /dev.
ev_begin S3.9.1 "Keyboard plug-in reaches the container" T3
input_import S3.9.3 switched-away "after device_del kvmkbd (the KVM switched away)"
xl2=$(gq xorg-log-lines 2>/dev/null || echo 0)
ev_qemu device-add-usb "EV-QEMU: device_add usb-kbd,id=kvmkbd,bus=xhci.0 (the KVM switches back) and QEMU's reply (empty: accepted)" \
    "device_add usb-kbd,id=kvmkbd,bus=xhci.0" >/dev/null || fail "QEMU refused to re-add the USB keyboard"
kvm_on_host=$kvm_off_host kvm_on_nodes=$kvm_off_nodes
for _ in $(seq 20); do
    kvm_on_host=$(vm_ssh_quick 'ls /dev/input/event* | wc -l')
    read -r kvm_on_nodes _ <<<"$(hotplug_probe)"
    [ "$kvm_on_host" -ge "$kvm_base_host" ] && [ "$kvm_on_nodes" -ge "$kvm_base_nodes" ] && break
    sleep 1
done
log "  switched back: host=$kvm_on_host container-nodes=$kvm_on_nodes"
sleep 2
input_set back "after the USB keyboard was re-added (the KVM switched back)"
input_diffs back "the USB keyboard's return"
ev_save xorg-log-usb "EV-LOG-XORG: the Xorg log's lines since just before the USB keyboard was re-added" \
    gq xorg-log-since "$xl2" >/dev/null || true
[ "$kvm_on_host" -ge "$kvm_base_host" ] \
    || fail "the keyboard never came back on the VM host ($kvm_off_host -> $kvm_on_host)"
ev_pass "the VM host has the keyboard's node again: $kvm_off_host -> $kvm_on_host event nodes"
[ "$kvm_on_nodes" -ge "$kvm_base_nodes" ] \
    || fail "the re-added keyboard never reached the container ($kvm_off_nodes -> $kvm_on_nodes): a KVM switch would leave input dead until desktop.service restarts"
ev_pass "the re-added USB keyboard reached the container: $kvm_off_nodes -> $kvm_on_nodes event nodes, at least the $kvm_base_nodes before the switch"
ev_text counter-kvm "the counter line for the KVM cycle, as xorg-input-count.txt records it" \
    "kvm-cycle       host $kvm_base_host -> $kvm_off_host -> $kvm_on_host / container-nodes $kvm_base_nodes -> $kvm_off_nodes -> $kvm_on_nodes"
ev_end

# Session health after the cycle. NOT proof that the re-added keyboard is
# carrying these keystrokes - QEMU always provides a PS/2 keyboard too, and
# input-send-event goes to whatever the input core has (S3.9.5 asks for
# that). What it does prove is that a remove/re-add cycle did not wedge the
# X session or its input stack, which is the other way a KVM switch could
# ruin the desktop.
ev_begin S3.9.6 "The session accepts input after a keyboard cycle" T3
vm_ssh 'sudo repo/ci/vm/vm-guest.sh input-sink-start'
sleep 2
qlog=$(ev_name qmp-input txt)
QMP_TRANSCRIPT="$EV_DIR/$qlog" python3 qmp-type.py "$QMP" "$res" 550 395 kvmok
ev_attach "$qlog" "EV-QEMU: every QMP command sent after the cycle - the pointer to the sink xterm's centre (550,395 on $res), a click to focus it, then k v m o k Return"
sleep 2
ev_shot after-cycle "EV-SHOT: the sink xterm (title inputtest) right after kvmok was typed, the keyboard cycle behind it"
ev_video_stop "EV-VIDEO: the display across the whole cycle - removal, re-add, then the sink xterm opening and kvmok typed into it (index.txt and timeline.log give the times)"
ev_save sink-file "EV-LOG-CLIENT: what the sink xterm's shell read (/tmp/inputproof in the desktop container); must be exactly 'kvmok'" \
    vm_ssh 'sudo podman exec desktop cat /tmp/inputproof 2>/dev/null; echo' >/dev/null || true
vm_ssh 'sudo repo/ci/vm/vm-guest.sh input-sink-check kvmok' \
    || { vm_ssh 'sudo podman exec desktop cat /tmp/inputproof 2>/dev/null' \
         2>&1 | tee "$ART/input-proof-kvm.txt" || true
         fail "the session stopped accepting input after a remove/re-add cycle"; }
ev_pass "after the cycle, the focused xterm's shell read 'kvmok'"
ev_save pids-after "EV-PIDS: Xorg and mwm in the desktop container after the cycle" \
    gq ctr-pids Xorg,mwm >/dev/null || true
x_pids_after=$(vm_ssh_quick 'sudo podman exec desktop pgrep -x Xorg' 2>/dev/null | paste -sd' ' || true)
[ -n "$x_pids_before" ] && [ "$x_pids_before" = "$x_pids_after" ] \
    || fail "Xorg's pid changed across the keyboard cycle ($x_pids_before -> $x_pids_after): the session restarted rather than carried on"
ev_pass "Xorg kept its pid across the cycle ($x_pids_before): the session carried on, it did not restart"
log "  the session still accepts input after a full switch cycle"
ev_end

log "input routing: keys sent to the display reach the keyboard bound to it"
# S3.9.6's kvmok proves the session, not the device: QEMU gives a key event
# that names no display to the newest keyboard bound to none. Re-added with
# display=vga0, the USB keyboard is bound to the virtio-vga's console, and the
# key events sent to that console go to it alone: `xinput test` on its own X
# device sees them while the sink xterm reads the text.
#
# The events name the display (vga0, head 0), never the keyboard. QMP's
# device is a display device, and this QEMU (8.2.2) aborts on a lookup that
# matches no display head: the search reaches a text console without a
# "device" property and dies on error_abort ("Property
# 'qemu-fixed-text-console.device' not found"). Run 37318468363 lost its VM
# that way, to an input-send-event naming kvmkbd.
ev_begin S3.9.5 "A hot-added keyboard delivers keystrokes" T3
kb_n=$(gq desk xinput list 2>/dev/null | xi_names | grep -cxF "QEMU QEMU USB Keyboard" || true)
ev_qemu device-del "EV-QEMU: device_del kvmkbd, to bring it back bound to the display, and QEMU's reply (empty: accepted)" \
    "device_del kvmkbd" >/dev/null || fail "QEMU refused device_del kvmkbd"
xi_wait_gone "QEMU QEMU USB Keyboard" "${kb_n:-1}"
ev_qemu device-add-bound "EV-QEMU: device_add usb-kbd,id=kvmkbd,bus=xhci.0,display=vga0 (the keyboard bound to the virtio-vga's console) and QEMU's reply (empty: accepted)" \
    "device_add usb-kbd,id=kvmkbd,bus=xhci.0,display=vga0" >/dev/null || fail "QEMU refused to add the keyboard bound to vga0"
kid=""
for _ in $(seq 15); do
    kid=$(gq xi-id QEMU QEMU USB Keyboard 2>/dev/null | head -1 || true)
    [ -n "$kid" ] && break
    sleep 1
done
ev_save xinput "EV-STATE: xinput list with the bound keyboard back" gq desk xinput list >/dev/null || true
[ -n "$kid" ] || fail "xinput never listed 'QEMU QEMU USB Keyboard' after it was re-added bound to vga0"
ev_note "the bound keyboard's X device: id $kid"
gq xi-test-start "$kid" >/dev/null || fail "could not start xinput test on id $kid"
sleep 1
vm_ssh 'sudo repo/ci/vm/vm-guest.sh input-sink-start'
sleep 2
qlog=$(ev_name qmp-input txt)
QMP_TRANSCRIPT="$EV_DIR/$qlog" QMP_KEY_DEVICE=vga0 QMP_KEY_HEAD=0 python3 qmp-type.py "$QMP" "$res" 550 395 boundkey
ev_attach "$qlog" "EV-QEMU: every QMP command sent: the pointer to the sink xterm's centre (550,395 on $res) and a click, naming no display, then b o u n d k e y Return, every key event naming device vga0, head 0"
sleep 2
ev_shot typed "EV-SHOT: the sink xterm (title inputtest) right after boundkey was typed through the bound keyboard"
xt=$(ev_save xinput-test "EV-STATE: xinput test on the bound keyboard's own X device (id $kid) while the keys were sent: a key press and a key release per key" \
    gq xi-test-read) || true
gq xi-test-stop >/dev/null 2>&1 || true
ev_save sink-file "EV-LOG-CLIENT: what the sink xterm's shell read (/tmp/inputproof in the desktop container); must be exactly 'boundkey'" \
    vm_ssh 'sudo podman exec desktop cat /tmp/inputproof 2>/dev/null; echo' >/dev/null || true
vm_ssh 'sudo repo/ci/vm/vm-guest.sh input-sink-check boundkey' \
    || fail "the sink xterm did not read 'boundkey' typed through the keyboard bound to vga0"
ev_pass "the focused xterm's shell read 'boundkey', every key event sent to display vga0"
presses=$(grep -c '^key press' <<<"$xt" || true)
[ "${presses:-0}" -ge 9 ] \
    || fail "xinput test on the bound keyboard (id $kid) saw ${presses:-0} key presses, want at least 9 (b o u n d k e y and Return): the keys did not come through it"
ev_pass "xinput test on the bound keyboard's own device (id $kid) saw $presses key presses for the 9 keys sent: they came through the re-added keyboard"
ev_end

printf 'hotplug-add     host %s -> %s / container-nodes %s -> %s / xorg-adds %s -> %s\n' \
    "$before_host" "$after_host" "$before_nodes" "$after_nodes" "$before_adds" "$after_adds" \
    > "$ART/xorg-input-count.txt"
printf 'kvm-cycle       host %s -> %s -> %s / container-nodes %s -> %s -> %s\n' \
    "$kvm_base_host" "$kvm_off_host" "$kvm_on_host" \
    "$kvm_base_nodes" "$kvm_off_nodes" "$kvm_on_nodes" >> "$ART/xorg-input-count.txt"

log "pointer hotplug: a USB mouse (relative) and a USB tablet (absolute), in and out"
# The pointer side of the KVM cable, both kinds: a relative mouse moves the
# pointer by deltas, an absolute tablet places it. The same evidence as the
# keyboard cycle above.
PTRS=("QEMU QEMU USB Mouse" "QEMU QEMU USB Tablet")
ev_begin S3.9.7 "Pointer plug-in reaches the container" T3
input_set base-ptr "before device_add usb-mouse and usb-tablet"
input_keep
xlp=$(gq xorg-log-lines 2>/dev/null || echo 0)
ptr_base_host=$(vm_ssh_quick 'ls /dev/input/event* | wc -l')
read -r ptr_base_nodes _ <<<"$(hotplug_probe)"
ev_qemu device-add-mouse "EV-QEMU: device_add usb-mouse,id=hotmouse,bus=xhci.0 (relative) and QEMU's reply (empty: accepted)" \
    "device_add usb-mouse,id=hotmouse,bus=xhci.0" >/dev/null || fail "QEMU refused device_add usb-mouse"
ev_qemu device-add-tablet "EV-QEMU: device_add usb-tablet,id=hottablet,bus=xhci.0 (absolute) and QEMU's reply (empty: accepted)" \
    "device_add usb-tablet,id=hottablet,bus=xhci.0" >/dev/null || fail "QEMU refused device_add usb-tablet"
ptr_on_host=$ptr_base_host ptr_on_nodes=$ptr_base_nodes
for _ in $(seq 20); do
    ptr_on_host=$(vm_ssh_quick 'ls /dev/input/event* | wc -l')
    read -r ptr_on_nodes _ <<<"$(hotplug_probe)"
    [ "$ptr_on_host" -ge $((ptr_base_host + 2)) ] && [ "$ptr_on_nodes" -ge $((ptr_base_nodes + 2)) ] && break
    sleep 1
done
# Xorg's side (S3.9.8) is polled too: xinput may lag the nodes.
for _ in $(seq 10); do
    xn=$(gq desk xinput list 2>/dev/null | xi_names || true)
    grep -qxF "${PTRS[0]}" <<<"$xn" && grep -qxF "${PTRS[1]}" <<<"$xn" && break
    sleep 1
done
log "  plugged in: host=$ptr_on_host container-nodes=$ptr_on_nodes"
input_set on-ptr "with the USB mouse and tablet plugged in"
input_diffs on-ptr "the pointers' arrival"
ev_save xorg-log "EV-LOG-XORG: the Xorg log's lines since just before the pointers were added" \
    gq xorg-log-since "$xlp" >/dev/null || true
PTR_B_DEV=$B_DEV PTR_A_DEV=$IN_DEV PTR_B_XI=$B_XI PTR_A_XI=$IN_XI PTR_XLOG=$EV_LAST
[ "$ptr_on_host" -ge $((ptr_base_host + 2)) ] \
    || fail "the VM host did not gain the two pointers' event nodes ($ptr_base_host -> $ptr_on_host)"
ev_pass "the VM host gained the pointers' event nodes: $ptr_base_host -> $ptr_on_host"
missing=""
for name in "${PTRS[@]}"; do
    nodes=$(dev_events "$EV_DIR/$IN_DEV" "$name")
    [ -n "$nodes" ] || { missing="$missing '$name' (not in /proc/bus/input/devices)"; continue; }
    for n in $nodes; do grep -qE " $n\$" "$EV_DIR/$IN_CTR" || missing="$missing $n ($name)"; done
    ev_note "'$name': event node(s) $nodes"
done
[ -z "$missing" ] || fail "the new pointers' nodes are not all in the container's /dev/input:$missing"
[ "$ptr_on_nodes" -ge $((ptr_base_nodes + 2)) ] \
    || fail "the container's event-node count rose only $ptr_base_nodes -> $ptr_on_nodes for two new pointers"
ev_pass "both pointers' own event nodes are in the container's /dev/input, and its count rose $ptr_base_nodes -> $ptr_on_nodes"
ev_end

ev_begin S3.9.8 "Pointer plug-in is adopted by Xorg" T3
xi_judge_added S3.9.7 "$PTR_B_DEV" "$PTR_A_DEV" "$PTR_B_XI" "$PTR_A_XI" "$PTR_XLOG" "the pointers' add"
for name in "${PTRS[@]}"; do
    roles=$(xi_roles "$ART/S3.9.7/$PTR_A_XI" "$name" | paste -sd' ')
    grep -qw pointer <<<"$roles" || fail "'$name' is not in xinput list as a pointer: ${roles:-absent}"
    ev_pass "'$name' is listed as a pointer (slave pointer)"
done
ev_end

ev_begin S3.9.9 "Pointer plug-out removes the node from the container" T3
input_import S3.9.7 plugged "with the USB mouse and tablet plugged in"
xlq=$(gq xorg-log-lines 2>/dev/null || echo 0)
ptr_nodes=""
for name in "${PTRS[@]}"; do ptr_nodes="$ptr_nodes $(dev_events "$EV_DIR/$B_DEV" "$name")"; done
ptr_nodes=$(echo $ptr_nodes)
[ -n "$ptr_nodes" ] || fail "no USB mouse or tablet node in /proc/bus/input/devices before the removal"
ev_note "the pointers' event node(s) before the removal: $ptr_nodes"
mouse_n=$(xi_count "$EV_DIR/$B_XI" "${PTRS[0]}")
tablet_n=$(xi_count "$EV_DIR/$B_XI" "${PTRS[1]}")
ev_qemu device-del-mouse "EV-QEMU: device_del hotmouse and QEMU's reply (empty: accepted)" \
    "device_del hotmouse" >/dev/null || fail "QEMU refused device_del hotmouse"
ev_qemu device-del-tablet "EV-QEMU: device_del hottablet and QEMU's reply (empty: accepted)" \
    "device_del hottablet" >/dev/null || fail "QEMU refused device_del hottablet"
ptr_off_host=$ptr_on_host ptr_off_nodes=$ptr_on_nodes
for _ in $(seq 20); do
    ptr_off_host=$(vm_ssh_quick 'ls /dev/input/event* | wc -l')
    read -r ptr_off_nodes _ <<<"$(hotplug_probe)"
    [ "$ptr_off_host" -le "$ptr_base_host" ] && [ "$ptr_off_nodes" -le "$ptr_base_nodes" ] && break
    sleep 1
done
xi_wait_gone "${PTRS[0]}" "$mouse_n"
xi_wait_gone "${PTRS[1]}" "$tablet_n"
log "  unplugged: host=$ptr_off_host container-nodes=$ptr_off_nodes"
input_set off-ptr "after device_del hotmouse and hottablet"
input_diffs off-ptr "the pointers' removal"
ev_save xorg-log-off "EV-LOG-XORG: the Xorg log's lines since just before the removal" \
    gq xorg-log-since "$xlq" >/dev/null || true
PTR_OFF_XLOG=$EV_LAST PTR_OFF_B_XI=$B_XI PTR_OFF_A_XI=$IN_XI
[ "$ptr_off_host" -le "$ptr_base_host" ] \
    || fail "the VM host kept the pointers' nodes after device_del ($ptr_on_host -> $ptr_off_host, baseline $ptr_base_host)"
ev_pass "the VM host lost the pointers' nodes: $ptr_on_host -> $ptr_off_host event nodes"
left=""
for n in $ptr_nodes; do grep -qE " $n\$" "$EV_DIR/$IN_CTR" && left="$left $n"; done
[ -z "$left" ] || fail "the removed pointers' node(s)$left are still in the container's /dev/input"
[ "$ptr_off_nodes" = "$ptr_base_nodes" ] \
    || fail "the container has $ptr_off_nodes event nodes after the removal, want the $ptr_base_nodes from before the pointers were added"
ev_pass "the pointers' own node(s) ($ptr_nodes) are gone from the container, and its count is back to its baseline: $ptr_base_nodes -> $ptr_on_nodes -> $ptr_off_nodes"
ev_end

ev_begin S3.9.10 "Pointer plug-out is seen by Xorg" T3
xi_judge_removed S3.9.9 "$PTR_OFF_B_XI" "$PTR_OFF_A_XI" "$PTR_OFF_XLOG" "${PTRS[@]}"
ev_end
printf 'ptr-hotplug     host %s -> %s -> %s / container-nodes %s -> %s -> %s\n' \
    "$ptr_base_host" "$ptr_on_host" "$ptr_off_host" \
    "$ptr_base_nodes" "$ptr_on_nodes" "$ptr_off_nodes" >> "$ART/xorg-input-count.txt"

log "audio hotplug: plug and unplug a USB sound card while the desktop runs"
# The same test as the KVM input cycle, on the other cable. /dev/snd was an
# AddDevice= - a creation-time snapshot - so a USB headset, DAC or dock
# connected after boot never produced a controlC* inside the container and
# never reached WirePlumber, until desktop.service restarted. It is a bind
# mount now, and this is what says so.
#
# usb-audio on the xHCI controller the KVM keyboard already uses: USB because
# that is what the real device is, and because PCI hot-unplug waits on a guest
# acknowledgement a busy device may never send. No boot-line change - the
# controller is already there, and the card is added only here so the "before"
# state is a machine that genuinely lacks it.
#
# Asserted in BOTH directions, like the input cycle: a node that never
# disappears is exactly what a snapshot /dev looks like, and it would let the
# add half pass for the wrong reason.
#
# Stories: S4.7.1 and S4.7.2 the plug-in (the container's node, WirePlumber's
# device), S4.7.4 and S4.7.5 the plug-out, S4.7.6 the built-in card after the
# cycle. F4.7's common set is taken three times (snd_set): base, plugged in,
# unplugged.
snd_t0=$(vm_ssh_quick 'date -u +%Y-%m-%dT%H:%M:%SZ')
ev_begin S4.7.1 "Sound card plug-in reaches the container" T3
snd_set base "before device_add usb-audio"
snd_keep
SND_BASE_PIDS=$SN_PIDS SND_BASE_PW=$SN_PW SND_BASE_DEF=$SN_DEF
read -r snd_base_nodes snd_base_devs <<<"$(snd_probe)"
snd_base_host=$(vm_ssh_quick 'ls /dev/snd/controlC* 2>/dev/null | wc -l')
audio_pids_base=$(audio_pids)
log "  base:      host=$snd_base_host container-nodes=$snd_base_nodes wireplumber-devices=$snd_base_devs"

ev_qemu device-add "EV-QEMU: device_add usb-audio,id=hotsnd,audiodev=snd0,bus=xhci.0 and QEMU's reply (empty: accepted)" \
    "device_add usb-audio,id=hotsnd,audiodev=snd0,bus=xhci.0" >/dev/null || fail "QEMU refused device_add usb-audio"
snd_on_host=$snd_base_host snd_on_nodes=$snd_base_nodes snd_on_devs=$snd_base_devs
for _ in $(seq 30); do
    snd_on_host=$(vm_ssh_quick 'ls /dev/snd/controlC* 2>/dev/null | wc -l')
    read -r snd_on_nodes snd_on_devs <<<"$(snd_probe)"
    [ "$snd_on_host" -gt "$snd_base_host" ] && [ "$snd_on_nodes" -gt "$snd_base_nodes" ] \
        && [ "$snd_on_devs" -gt "$snd_base_devs" ] && break
    sleep 1
done
log "  plugged in: host=$snd_on_host container-nodes=$snd_on_nodes wireplumber-devices=$snd_on_devs"
snd_set on "with the USB sound card plugged in"
snd_diffs on "the card's arrival"
ev_save desktop-log "EV-LOG-DESKTOP: the desktop's log since just before the card was plugged in" \
    vm_ssh_quick "sudo podman logs --since '$snd_t0' desktop" >/dev/null || true
SND_ON_PW=$SN_PW SND_ON_DEF=$SN_DEF
[ "$snd_on_host" -gt "$snd_base_host" ] \
    || fail "device_add usb-audio did not create a card on the VM host ($snd_base_host -> $snd_on_host): QEMU never attached it, so nothing below means anything"
ev_pass "the VM host gained a card: $snd_base_host -> $snd_on_host controlC* nodes"
[ "$snd_on_nodes" -gt "$snd_base_nodes" ] \
    || fail "the hot-added sound card never reached the container ($snd_base_nodes -> $snd_on_nodes): its /dev/snd is a stale snapshot, so a USB headset plugged in after boot stays invisible until desktop.service restarts"
ev_pass "the container gained it too: $snd_base_nodes -> $snd_on_nodes controlC* nodes in its /dev/snd"
ev_text counter-snd-on "the counts so far (the full line, with the unplug, is in xorg-input-count.txt and S4.7.4)" \
    "snd-hotplug     host $snd_base_host -> $snd_on_host / container-nodes $snd_base_nodes -> $snd_on_nodes / wp-devices $snd_base_devs -> $snd_on_devs"
ev_end

ev_begin S4.7.2 "Sound card plug-in reaches WirePlumber" T3
ev_copy "$ART/S4.7.1/$SND_BASE_PW" pw-devices-before "EV-STATE: pw-cli ls Device before the card was added (taken in S4.7.1)"
pwb=$EV_LAST
ev_copy "$ART/S4.7.1/$SND_ON_PW" pw-devices-after "EV-STATE: pw-cli ls Device with the card plugged in (taken in S4.7.1)"
pwa=$EV_LAST
ev_diff pw-devices "EV-DIFF: pw-cli ls Device across the card's arrival" "$pwb" "$pwa"
new_cards=$(comm -13 <(pw_card_names "$EV_DIR/$pwb") <(pw_card_names "$EV_DIR/$pwa") | paste -sd' ')
ev_text new-device "the new Device object, quoted whole from pw-cli ls Device: ${new_cards:-none}" \
    "$(for c in $new_cards; do pw_block "$EV_DIR/$pwa" "$c"; done)"
[ "$snd_on_devs" -gt "$snd_base_devs" ] \
    || fail "the container has the new /dev/snd node but WirePlumber never added a device ($snd_base_devs -> $snd_on_devs): the node arrived and the uevent did not (Network=host), or the session user cannot open it (audio gid alignment)"
[ -n "$new_cards" ] || fail "pw-cli ls Device counts $snd_base_devs -> $snd_on_devs alsa_card devices but names no new one"
ev_pass "WirePlumber added an alsa_card Device for the card: $snd_base_devs -> $snd_on_devs, the new one $new_cards"
ev_end

ev_begin S4.7.4 "Sound card plug-out removes the node from the container" T3
snd_import S4.7.1 plugged "with the card plugged in"
ev_qemu device-del "EV-QEMU: device_del hotsnd and QEMU's reply (empty: accepted)" \
    "device_del hotsnd" >/dev/null || fail "QEMU refused device_del hotsnd"
snd_off_host=$snd_on_host snd_off_nodes=$snd_on_nodes snd_off_devs=$snd_on_devs
for _ in $(seq 30); do
    snd_off_host=$(vm_ssh_quick 'ls /dev/snd/controlC* 2>/dev/null | wc -l')
    read -r snd_off_nodes snd_off_devs <<<"$(snd_probe)"
    # Wait for the WirePlumber count to settle back too, not just the nodes:
    # the tone check below needs a default sink, and WirePlumber has to pick
    # one again after the card it may have switched to disappeared.
    [ "$snd_off_host" -lt "$snd_on_host" ] && [ "$snd_off_nodes" -lt "$snd_on_nodes" ] \
        && [ "$snd_off_devs" -le "$snd_base_devs" ] && break
    sleep 1
done
log "  unplugged: host=$snd_off_host container-nodes=$snd_off_nodes wireplumber-devices=$snd_off_devs"
# A default sink is re-selected after the device goes (S4.7.5): poll for a
# default that is one of the sinks left before taking the picture.
snd_wait_default
snd_set off "after device_del hotsnd"
snd_diffs off "the card's removal"
SND_OFF_PW=$SN_PW SND_OFF_DEF=$SN_DEF SND_OFF_SINKS=$SN_SINKS
[ "$snd_off_host" -lt "$snd_on_host" ] \
    || fail "device_del hotsnd did not remove the card on the VM host ($snd_on_host -> $snd_off_host)"
ev_pass "the VM host lost the card: $snd_on_host -> $snd_off_host controlC* nodes"
[ "$snd_off_nodes" = "$snd_base_nodes" ] \
    || fail "the container has $snd_off_nodes controlC* nodes after the card was unplugged, want the $snd_base_nodes from before it was plugged in: its /dev/snd is a stale snapshot, and the add half passed for the wrong reason"
ev_pass "the container's controlC* count is back to its baseline: $snd_base_nodes -> $snd_on_nodes -> $snd_off_nodes"
ev_text counter-snd "the counter line for the cycle, as xorg-input-count.txt records it" \
    "snd-hotplug     host $snd_base_host -> $snd_on_host -> $snd_off_host / container-nodes $snd_base_nodes -> $snd_on_nodes -> $snd_off_nodes / wp-devices $snd_base_devs -> $snd_on_devs -> $snd_off_devs"
ev_end

ev_begin S4.7.5 "Sound card plug-out removes the WirePlumber device and a default sink is re-selected" T3
ev_copy "$ART/S4.7.1/$SND_ON_PW" pw-devices-plugged "EV-STATE: pw-cli ls Device with the card plugged in (taken in S4.7.1)"
pwa=$EV_LAST
ev_copy "$ART/S4.7.4/$SND_OFF_PW" pw-devices-unplugged "EV-STATE: pw-cli ls Device after the card was unplugged (taken in S4.7.4)"
pwo=$EV_LAST
ev_diff pw-devices "EV-DIFF: pw-cli ls Device across the card's removal" "$pwa" "$pwo"
ev_copy "$ART/S4.7.1/$SND_BASE_DEF" default-sink-base "EV-STATE: pactl get-default-sink before the card was plugged in (taken in S4.7.1)"
ev_copy "$ART/S4.7.1/$SND_ON_DEF" default-sink-plugged "EV-STATE: pactl get-default-sink with the card plugged in (taken in S4.7.1)"
ev_copy "$ART/S4.7.4/$SND_OFF_DEF" default-sink-unplugged "EV-STATE: pactl get-default-sink after the card was unplugged (taken in S4.7.4)"
ev_copy "$ART/S4.7.4/$SND_OFF_SINKS" sinks-unplugged "EV-STATE: pactl list short sinks after the card was unplugged (taken in S4.7.4)"
[ "$snd_off_devs" -le "$snd_base_devs" ] \
    || fail "WirePlumber still lists $snd_off_devs alsa devices after the card was unplugged (baseline $snd_base_devs): the node went away but the graph kept a phantom device"
[ "$snd_off_devs" = "$snd_base_devs" ] \
    || fail "WirePlumber lists $snd_off_devs alsa devices after the unplug, want the $snd_base_devs from before the plug-in"
ev_pass "WirePlumber's alsa_card Device count is back to its baseline: $snd_base_devs -> $snd_on_devs -> $snd_off_devs"
def_off=$(ev_payload "$ART/S4.7.4/$SND_OFF_DEF" | head -1)
sinks_off=$(ev_payload "$ART/S4.7.4/$SND_OFF_SINKS" | awk '{print $2}')
[ -n "$def_off" ] && grep -qxF -- "$def_off" <<<"$sinks_off" \
    || fail "after the unplug the default sink is '$def_off', which is not one of the sinks left: $(echo $sinks_off)"
ev_pass "a default sink is re-selected among the sinks left: $def_off (with the card plugged in it was $(ev_payload "$ART/S4.7.1/$SND_ON_DEF" | head -1))"
ev_end

# Health after the cycle, the audio counterpart of the input-sink check: the
# built-in card must still play, and the three daemons must be the ones from
# before the cycle. A remove/re-add that wedges WirePlumber, or one the
# supervisor answers with a restart, is the other way this could ruin the
# desktop.
ev_begin S4.7.6 "The built-in card plays after a cycle" T3
ev_copy "$ART/S4.7.1/$SND_BASE_PIDS" pids-before "EV-PIDS: the three audio daemons before the card was plugged in (taken in S4.7.1)"
pb=$EV_LAST
ev_save pids-after "EV-PIDS: the three audio daemons after the plug/unplug cycle" \
    gq ctr-pids pipewire,wireplumber,pipewire-pulse >/dev/null || true
ev_diff pids "EV-DIFF: the audio daemons across the cycle (empty: none restarted)" "$pb" "$EV_LAST"
ev_save desktop-log "EV-LOG-DESKTOP: the desktop's log since just before the card was plugged in" \
    vm_ssh_quick "sudo podman logs --since '$snd_t0' desktop" >/dev/null || true
hz=$(freq_for pulse)
ev_audio_start after-cycle "$hz"
vm_ssh 'sudo repo/ci/vm/vm-guest.sh play-audio pulse' \
    || { audio_capture_stop; fail "audio stopped working after a sound-card hotplug cycle"; }
ev_audio_stop "EV-AUDIO: the machine's output after the plug/unplug cycle while a pulse client played its $hz Hz tone on the built-in card - listen for one beep" 1 0.05 "$hz" \
    || fail "audio is silent after a sound-card hotplug cycle"
ev_pass "after the cycle the built-in card played the pulse client's $hz Hz tone"
audio_pids_after=$(audio_pids)
[ -n "$audio_pids_base" ] && [ "$audio_pids_base" = "$audio_pids_after" ] \
    || fail "the audio daemons changed across the hotplug cycle ($audio_pids_base -> $audio_pids_after): the stack restarted rather than carried on"
ev_pass "pipewire, wireplumber and pipewire-pulse kept their pids across the cycle ($audio_pids_base)"
log "  the built-in card still plays after a full plug/unplug cycle"
ev_end

printf 'snd-hotplug     host %s -> %s -> %s / container-nodes %s -> %s -> %s / wp-devices %s -> %s -> %s\n' \
    "$snd_base_host" "$snd_on_host" "$snd_off_host" \
    "$snd_base_nodes" "$snd_on_nodes" "$snd_off_nodes" \
    "$snd_base_devs" "$snd_on_devs" "$snd_off_devs" >> "$ART/xorg-input-count.txt"

log "audio hotplug, again: the new card is the one heard, and a stream on it when it goes"
# A second cycle of the same card. Both cards feed QEMU's one audiodev, so for
# S4.7.3 the built-in card's sink is muted while the new card's is the
# default: a tone heard then came out of the new card. For S4.7.7 a long
# stream is playing on the new card when it is unplugged.
ev_begin S4.7.3 "A hot-added card plays, and it is the new card that is heard" T3
snd_set base "before the card is plugged in again"
snd_keep
read -r s2_base_nodes s2_base_devs <<<"$(snd_probe)"
builtin_sink=$(ev_payload "$EV_DIR/$SN_DEF" | head -1)
ev_qemu device-add "EV-QEMU: device_add usb-audio,id=hotsnd2,audiodev=snd0,bus=xhci.0 and QEMU's reply (empty: accepted)" \
    "device_add usb-audio,id=hotsnd2,audiodev=snd0,bus=xhci.0" >/dev/null || fail "QEMU refused device_add usb-audio"
s2_on_nodes=$s2_base_nodes s2_on_devs=$s2_base_devs
for _ in $(seq 30); do
    read -r s2_on_nodes s2_on_devs <<<"$(snd_probe)"
    [ "$s2_on_nodes" -gt "$s2_base_nodes" ] && [ "$s2_on_devs" -gt "$s2_base_devs" ] && break
    sleep 1
done
# The new card's sink shows in pactl a moment after its Device.
usb_sink=""
for _ in $(seq 15); do
    usb_sink=$(comm -13 <(ev_payload "$EV_DIR/$SB_SINKS" | awk '{print $2}' | sort) \
                        <(gq desk pactl list short sinks 2>/dev/null | awk '{print $2}' | sort) | head -1)
    [ -n "$usb_sink" ] && break
    sleep 1
done
snd_set on "with the USB sound card plugged in again"
snd_diffs on "the card's arrival"
[ -n "$usb_sink" ] || fail "no new sink appeared after the card was plugged in again ($s2_base_devs -> $s2_on_devs alsa devices)"
[ -n "$builtin_sink" ] || fail "there was no default sink before the card was plugged in: nothing to mute"
ev_note "the new card's sink: $usb_sink; the built-in card's: $builtin_sink"
gq desk pactl set-default-sink "$usb_sink" >/dev/null || fail "pactl set-default-sink $usb_sink failed"
gq desk pactl set-sink-mute "$builtin_sink" 1 >/dev/null || fail "pactl set-sink-mute $builtin_sink 1 failed"
# WirePlumber gives a new device 0.40 on wpctl's cubic scale: 0.064 linear,
# about -24 dB, and the USB card applies it as such. A tone at 0.6 of full
# scale then peaks near 0.04, under check-audio's silence floor of 0.05 (run
# 37321986539 measured 0.036). At full volume the question is only which
# card is heard.
gq desk pactl set-sink-volume "$usb_sink" 100% >/dev/null || fail "pactl set-sink-volume $usb_sink 100% failed"
ev_save wpctl-selected "EV-STATE: wpctl status with the new card's sink made the default (marked *) at full volume, and the built-in card's sink muted" \
    gq desk wpctl status >/dev/null || true
ev_save builtin-mute "EV-STATE: pactl get-sink-mute for the built-in card's sink" gq desk pactl get-sink-mute "$builtin_sink" >/dev/null || true
heard=yes
ev_audio_start new-card 990
gq tone-start newcard 990 4 - >/dev/null || { audio_capture_stop; fail "could not start the 990 Hz player"; }
sleep 2
mid=$(ev_save sink-inputs-mid "EV-STATE: pactl list short sink-inputs mid-playback (the second column is the sink's index)" \
    gq desk pactl list short sink-inputs) || true
sinks_mid=$(ev_save sinks-mid "EV-STATE: pactl list short sinks mid-playback (index, then name)" gq desk pactl list short sinks) || true
for _ in $(seq 15); do st=$(gq tone-status newcard 2>/dev/null | sed -n 1p || true); [ "${st%% *}" = exited ] && break; sleep 1; done
ev_save player "EV-LOG-CLIENT: the 990 Hz player's status (exited and its code) and its stderr" gq tone-status newcard >/dev/null || true
ev_audio_stop "EV-AUDIO: the machine's output while a pulse client played 990 Hz on the default sink, the new card's, with the built-in card's sink muted: what is heard came out of the new card - listen for one beep" 1 0.05 990 \
    || heard=no
gq desk pactl set-sink-mute "$builtin_sink" 0 >/dev/null || true
gq desk pactl set-default-sink "$builtin_sink" >/dev/null || true
ev_save restored "EV-STATE: wpctl status after the built-in card's sink was unmuted and made the default again" \
    gq desk wpctl status >/dev/null || true
usb_idx=$(awk -v n="$usb_sink" '$2 == n {print $1}' <<<"$sinks_mid")
[ -n "$usb_idx" ] || fail "the new card's sink $usb_sink is not among the sinks listed mid-playback"
on_usb=$(awk -v i="$usb_idx" 'NF > 2 && $2 == i' <<<"$mid" | wc -l)
[ "$on_usb" -ge 1 ] || fail "mid-playback no stream sat on the new card's sink (index $usb_idx): $(echo $mid)"
ev_pass "mid-playback the player's stream sat on the new card's sink: $usb_sink (index $usb_idx)"
[ "$heard" = yes ] || fail "the 990 Hz tone was not heard with the built-in card's sink muted: the new card did not render it"
ev_pass "with the built-in card's sink muted, the machine's output carried the 990 Hz tone: the new card rendered it"
ev_end

ev_begin S4.7.7 "A stream playing on the card that is unplugged fails cleanly" T3
pids_b=$(audio_pids)
ev_save pids-before "EV-PIDS: the three audio daemons before the card is unplugged under a playing stream" \
    gq ctr-pids pipewire,wireplumber,pipewire-pulse >/dev/null || true
pb=$EV_LAST
ev_audio_start removal 660
gq tone-start longplay 660 15 "$usb_sink" >/dev/null || { audio_capture_stop; fail "could not start the long player on $usb_sink"; }
sleep 3
ev_save sink-inputs-before "EV-STATE: pactl list short sink-inputs with the long stream playing on the new card" \
    gq desk pactl list short sink-inputs >/dev/null || true
ev_save sinks-before "EV-STATE: pactl list short sinks with the long stream playing" gq desk pactl list short sinks >/dev/null || true
ev_note "device_del hotsnd2 sent at $(date -u +%Y-%m-%dT%H:%M:%S.%3NZ), about 3 s into the 15 s stream"
ev_qemu device-del "EV-QEMU: device_del hotsnd2 under the playing stream, and QEMU's reply (empty: accepted)" \
    "device_del hotsnd2" >/dev/null || { audio_capture_stop; fail "QEMU refused device_del hotsnd2"; }
t_del=$(date +%s)
outcome=""
for _ in $(seq 10); do
    st=$(gq tone-status longplay 2>/dev/null | sed -n 1p || true)
    if [ "${st%% *}" = exited ]; then
        outcome="exited (code ${st#exited }) $(( $(date +%s) - t_del )) s after the removal"
        break
    fi
    sk=$(gq desk pactl list short sinks 2>/dev/null || true)
    if ! awk -v n="$usb_sink" '$2 == n {f = 1} END {exit !f}' <<<"$sk"; then
        moved=$(gq desk pactl list short sink-inputs 2>/dev/null \
            | awk 'NR == FNR {name[$1] = $2; next} NF > 2 && ($2 in name) {print name[$2]; exit}' <(printf '%s\n' "$sk") - || true)
        if [ -n "$moved" ]; then
            outcome="kept playing, its stream moved to $moved $(( $(date +%s) - t_del )) s after the removal"
            break
        fi
    fi
    sleep 1
done
ev_save sink-inputs-after "EV-STATE: pactl list short sink-inputs after the removal" gq desk pactl list short sink-inputs >/dev/null || true
ev_save sinks-after "EV-STATE: pactl list short sinks after the removal" gq desk pactl list short sinks >/dev/null || true
for _ in $(seq 15); do st=$(gq tone-status longplay 2>/dev/null | sed -n 1p || true); [ "${st%% *}" = exited ] && break; sleep 1; done
ev_save player "EV-LOG-CLIENT: the long player's status (exited and its code, or running) and its stderr" gq tone-status longplay >/dev/null || true
ev_audio_stop "EV-AUDIO: the machine's output from the stream's start, about 3 s before device_del (see notes), to its end: the tone goes on where the stream was moved to a remaining sink, and stops where the player ended - listen across the removal" 1 0.05 660 \
    || ev_note "check-audio's verdict on the capture is not a pass (see its report): judged on the player and the graph instead"
vm_ssh_quick 'sudo podman exec desktop pkill -x paplay' >/dev/null 2>&1 || true
pids_a=$(audio_pids)
ev_save pids-after "EV-PIDS: the three audio daemons after the removal" gq ctr-pids pipewire,wireplumber,pipewire-pulse >/dev/null || true
ev_diff pids "EV-DIFF: the audio daemons across the removal (empty: none restarted)" "$pb" "$EV_LAST"
export_ok=yes
ev_save pactl-info "EV-STATE: pactl info from the VM host over the export, after the removal" \
    vm_ssh_quick 'sudo env PULSE_SERVER=unix:/run/desktop-audio/pulse pactl info' >/dev/null || export_ok=no
[ -n "$pids_b" ] && [ "$pids_b" = "$pids_a" ] \
    || fail "the audio daemons changed across the removal ($pids_b -> $pids_a): the stack restarted rather than carried on"
ev_pass "pipewire, wireplumber and pipewire-pulse kept their pids across the removal ($pids_b)"
[ "$export_ok" = yes ] || fail "pactl info over the export failed after the removal"
ev_pass "the export still answers pactl info"
[ -n "$outcome" ] || fail "10 s after the card went, the player neither had exited nor had its stream on a remaining sink"
ev_pass "within 10 s of the removal the player $outcome"
ev_end
snd_wait_default

log "audio hotplug: five plug/unplug cycles leave no phantom devices"
# Requirements.md S4.7.11: after each removal every count is back at its
# baseline, and after the fifth PipeWire's Device objects are the
# baseline's, byte for byte. Each cycle's card has an id of its own, so a
# removal QEMU had not finished could not make the next add a duplicate.
ev_begin S4.7.11 "Repeated audio cycles leave no phantom devices" T3
snd_set base "before the first of five plug/unplug cycles"
snd_keep
read -r cyc_n0 cyc_d0 <<<"$(snd_probe)"
cyc_h0=$(vm_ssh_quick 'ls /dev/snd | wc -l' 2>/dev/null || echo 0)
cyc_rows=$(printf '%-6s %-9s %-15s %-20s %s' cycle state host-snd-nodes container-controlC wireplumber-alsa-cards)
cyc_row() { cyc_rows+=$'\n'$(printf '%-6s %-9s %-15s %-20s %s' "$@"); }
cyc_row 0 baseline "$cyc_h0" "$cyc_n0" "$cyc_d0"
cyc_in=yes cyc_out=yes
for i in 1 2 3 4 5; do
    python3 qmp-tool.py hmp "$QMP" "device_add usb-audio,id=cyc$i,audiodev=snd0,bus=xhci.0" >/dev/null \
        || fail "QEMU refused device_add usb-audio in cycle $i"
    n=0 d=0
    for _ in $(seq 30); do
        read -r n d <<<"$(snd_probe)"
        [ "$n" -gt "$cyc_n0" ] && [ "$d" -gt "$cyc_d0" ] && break
        sleep 1
    done
    hn=$(vm_ssh_quick 'ls /dev/snd | wc -l' 2>/dev/null || echo 0)
    cyc_row "$i" plugged "$hn" "$n" "$d"
    { [ "$n" -gt "$cyc_n0" ] && [ "$d" -gt "$cyc_d0" ]; } || cyc_in=no
    python3 qmp-tool.py hmp "$QMP" "device_del cyc$i" >/dev/null || fail "QEMU refused device_del cyc$i"
    for _ in $(seq 30); do
        read -r n d <<<"$(snd_probe)"
        hn=$(vm_ssh_quick 'ls /dev/snd | wc -l' 2>/dev/null || echo 0)
        [ "$n" = "$cyc_n0" ] && [ "$d" = "$cyc_d0" ] && [ "$hn" = "$cyc_h0" ] && break
        sleep 1
    done
    cyc_row "$i" removed "$hn" "$n" "$d"
    { [ "$n" = "$cyc_n0" ] && [ "$d" = "$cyc_d0" ] && [ "$hn" = "$cyc_h0" ]; } || cyc_out=no
done
ev_text cycles "EV-STATE: the counter table, one row per plug-in and per removal: sound nodes on the VM host, controlC* nodes in the container, WirePlumber's alsa_card Devices" "$cyc_rows"
snd_wait_default
snd_set final "after the fifth cycle"
snd_diffs final "the five cycles"
[ "$cyc_in" = yes ] || fail "a plug-in did not raise the container's controlC* nodes and WirePlumber's devices (see the counter table)"
ev_pass "each of the five plug-ins raised the container's controlC* nodes and WirePlumber's alsa_card devices"
[ "$cyc_out" = yes ] || fail "a removal did not bring every count back to its baseline (see the counter table)"
ev_pass "each of the five removals brought the host's nodes, the container's and WirePlumber's devices back to the baseline ($cyc_h0, $cyc_n0, $cyc_d0)"
[ "$(ev_payload "$EV_DIR/$SB_PW")" = "$(ev_payload "$EV_DIR/$SN_PW")" ] \
    || fail "pw-cli ls Device after the fifth cycle is not the baseline's (see the pw-devices diff)"
ev_pass "pw-cli ls Device after the fifth cycle is the baseline's, byte for byte: no alsa_card object outlived its card"
hz=$(freq_for pulse)
ev_audio_start after-cycles "$hz"
vm_ssh 'sudo repo/ci/vm/vm-guest.sh play-audio pulse' \
    || { audio_capture_stop; fail "a pulse client could not play after the five cycles"; }
ev_audio_stop "EV-AUDIO: the machine's output after the five cycles, while a pulse client played its $hz Hz tone on the built-in card - listen for one beep" 1 0.05 "$hz" \
    || fail "the built-in card is silent after the five cycles"
ev_pass "after the five cycles the built-in card plays: a pulse client's $hz Hz tone came out of the machine"
ev_end

log "audio hotplug: a capture-capable card on PCI"
cap_card_probe
if [ -z "$cap_model" ]; then
    # S4.7.8 stays T4: its attempt is kept, outside any story.
    mkdir -p "$ART/S4.7.8-attempt"
    printf '%s\n' "$cap_probe" > "$ART/S4.7.8-attempt/modinfo.txt"
    log "  no AC97 or ES1370 driver in the guest kernel; S4.7.8's attempt is in S4.7.8-attempt/"
else
    ev_begin S4.7.8 "Capture device plug-in and plug-out reach WirePlumber" T3
    ev_text modinfo "EV-STATE: modinfo -n for the two candidate drivers on the VM host" "$cap_probe"
    snd_set base "before device_add $cap_model"
    snd_keep
    ev_qemu device-add "EV-QEMU: device_add $cap_model,id=hotcap,audiodev=snd0 and QEMU's reply (empty: accepted)" \
        "device_add $cap_model,id=hotcap,audiodev=snd0" >/dev/null || fail "QEMU refused device_add $cap_model"
    new_src=""
    for _ in $(seq 30); do
        new_src=$(comm -13 <(ev_payload "$EV_DIR/$SB_SOURCES" | awk '{print $2}' | sort) \
                           <(gq desk pactl list short sources 2>/dev/null | awk '{print $2}' | sort) | grep '^alsa_input\.' | head -1 || true)
        [ -n "$new_src" ] && break
        sleep 1
    done
    snd_set on "with the $cap_model card plugged in"
    snd_diffs on "the $cap_model card's arrival"
    [ -n "$new_src" ] || fail "no alsa_input source appeared within 30 s of device_add $cap_model"
    ev_pass "the $cap_model card brought a capture source: $new_src"
    snd_keep
    ev_end

    # S4.7.9: a client records from it. QEMU's audiodev here is "none", whose
    # capture side is silence: the recording proves the stream opened and
    # delivered frames, not what a microphone would have heard.
    ev_begin S4.7.9 "Recording from a hot-added capture device works" T3
    rec=$(ev_save recorder "EV-LOG-CLIENT: the session user's parecord from $new_src for 3 s (SIGINT ends it, so the WAV is finished): its command, its output, its exit status and the file" \
        gq rec-source "$new_src" 3 s479) || true
    rname=$(ev_name rec-from-capture-card wav)
    vm_ssh_quick 'sudo podman exec desktop cat /tmp/s479.wav' > "$EV_DIR/$rname" 2>/dev/null || true
    [ -s "$EV_DIR/$rname" ] && ev_attach "$rname" "EV-AUDIO-REC: what the session user's parecord recorded from $new_src: silence, which is all QEMU's none backend gives a capture, so its frames are the proof"
    rfacts_ok=yes
    rfacts=$(rec_facts "$EV_DIR/$rname" 2 2>&1) || rfacts_ok=no
    ev_text rec-facts "EV-AUDIO-REC: the recording's frames, duration, format and peak (python's wave module)" "$rfacts"
    grep -q '^parecord exited 0$' <<<"$rec" || fail "parecord from $new_src did not exit 0: $(grep '^parecord exited' <<<"$rec")"
    ev_pass "the session user's parecord opened $new_src and exited 0"
    [ "$rfacts_ok" = yes ] || fail "the recording from $new_src holds less than 2 s of its 3: $rfacts"
    ev_pass "it delivered frames: $rfacts (silence: all QEMU's none backend gives a capture)"
    ev_end

    ev_begin S4.7.8 "Capture device plug-in and plug-out reach WirePlumber" T3
    ev_qemu device-del "EV-QEMU: device_del hotcap and QEMU's reply (empty: accepted; the PCI unplug then waits on the guest)" \
        "device_del hotcap" >/dev/null || fail "QEMU refused device_del hotcap"
    gone=no
    for _ in $(seq 30); do
        gq desk pactl list short sources 2>/dev/null | awk '{print $2}' | grep -qxF -- "$new_src" || { gone=yes; break; }
        sleep 1
    done
    snd_set off "after device_del hotcap"
    snd_diffs off "the $cap_model card's removal"
    [ "$gone" = yes ] || fail "the capture source $new_src was still listed 30 s after device_del hotcap"
    ev_pass "the capture source left with the card: $new_src is gone from pactl list short sources"
    ev_end
fi

fi # ---- end shard: core ----------------------------------------------------------

# ---- shard: operator ---------------------------------------------------------
if in_shard operator; then

log "operator: the person at the display, through QEMU's own input devices (E11)"
# Requirements.md E11, and the parts of F3.3 and F3.5 only a screen can show:
# the desktop as the operator finds it, windows arranged with the mouse and
# from the keyboard alone, text moved between applications in different
# containers, every root-menu entry, and the operator's own sound controls.
# operator-e2e.py sends every pointer and key event over QMP to QEMU's virtio
# devices - never into the X server - and looks at X from a confined observer
# container. Each story leaves $ART/<story>/evidence.md, indexing its
# screendumps, video frames, state diffs, pid tables and audio capture.
#
# A failed story does not stop the others; the step fails once they have all
# run. In CI this shard boots its own VM, so the desktop it finds is the one
# phase-deploy left (operator-setup retires phase-deploy's xterm). In a
# single-VM run (shard "all") it comes after the core shard and before phase
# 2, which it hands a freshly restarted desktop: the sound story ends with
# systemctl restart desktop.service.
vm_ssh 'sudo repo/ci/vm/vm-guest.sh operator-setup' || fail "operator setup failed"
op_rc=0
python3 operator-e2e.py --qmp "$QMP" --ssh-port "$SSHPORT" --ssh-key id_ed25519 --art "$ART" \
    || op_rc=$?
vm_ssh 'sudo repo/ci/vm/vm-guest.sh operator-teardown' || true
[ "$op_rc" = 0 ] || fail "operator stories failed: see $ART/operator-summary.md and $ART/S*/evidence.md"

fi # ---- end shard: operator ------------------------------------------------------

# ---- shard: k8s ----------------------------------------------------------------
if in_shard k8s; then

log "phase 2: k3s + a cdi-device-plugin release per capability, desktop still on the quadlet"
guest_ev "$GUEST_EV" phase2 \
    || { vm_ssh 'sudo journalctl -b --no-pager | tail -150' 2>&1 | tee "$ART/guest-journal-fail.log" || true; fail "guest phase2 failed"; }
screendump desktop-k3s-client
assert_nonblank desktop-k3s-client
# S7.3.7's picture: the desktop after CRI-O and k3s arrived (the guest kept
# the proof that its processes are the same ones).
EV_SIDE=h-
ev_begin S7.3.7 "The desktop survives CRI-O and k3s arriving" T3
ev_shot after-install "EV-SHOT: the desktop after CRI-O and k3s were installed and the demo pod started: the session's xterm, and the demo pod's xterm over it"
ev_end
EV_SIDE=

log "the demo pod's window is usable: clicked at its centre and typed into"
# Requirements.md S7.5.2: S7.5.1 for examples/x11-client-pod.yaml. The demo's
# window is found by its X client - the pod's main process, its xterm - not
# by its title: the image's /etc/bashrc retitles an xterm at its shell's
# first prompt, so the example's -title "CDI demo" does not last. The click
# lands at the window's centre, and the line typed runs in the demo's shell,
# which writes it to a file in the pod.
res=$(vm_ssh 'sudo podman exec -u desktop -e DISPLAY=:0 desktop \
    sh -c "xdpyinfo | awk \"/dimensions:/{print \\\$2; exit}\""')
[ -n "$res" ] || fail "could not read the display's size for input injection"
ev_begin S7.5.2 "The same under kubernetes" T3
ev_save pod-before "EV-PIDS: the demo pod x11-client-demo's container (restartCount, id, start time) and its main process's host pid - its xterm - before it is used" \
    gq pod-state x11-client-demo >/dev/null || true
D_POD_B=$EV_LAST
ev_save windows "EV-STATE: the demo pod's main process (its xterm), the X client it holds (screenshot --list-clients) and the windows X allocated to that client in xwininfo -root -tree, each named one with its map state" \
    gq pod-windows x11-client-demo >/dev/null || fail "the demo pod's xterm holds no X connection"
rect=$(ev_out | win_rect || true)
[ -n "$rect" ] || fail "the demo pod's xterm has no window on the screen"
read -r d_wid d_w d_h d_x d_y <<<"$rect"
d_cx=$((d_x + d_w / 2)) d_cy=$((d_y + d_h / 2))
ev_pass "the demo pod's xterm is on the desktop: window $d_wid, ${d_w}x${d_h} at +$d_x+$d_y, found as its pod's X client"
ev_save tree "EV-STATE: xwininfo -root -tree with the demo's window in it" gq win-tree >/dev/null || true
qlog=$(ev_name qmp txt)
QMP_TRANSCRIPT="$EV_DIR/$qlog" python3 qmp-type.py "$QMP" "$res" "$d_cx" "$d_cy" "echo typedintodemo752 >/tmp/s752" \
    || fail "QMP input to the demo pod's window failed"
ev_attach "$qlog" "EV-QEMU: every QMP command sent: the absolute pointer to the window's centre ($d_cx,$d_cy), a click, then the keys of the line typed and Return"
got=""
for _ in $(seq 8); do
    got=$(gq jx-in x11-client-demo cat /tmp/s752 2>/dev/null || true)
    [ -n "$got" ] && break
    sleep 1
done
ev_text sink "EV-STATE: /tmp/s752 read inside the demo pod: what the shell in its xterm wrote when the typed line ran" "${got:-(no file)}"
[ "$got" = typedintodemo752 ] || fail "the demo pod's shell did not run the typed line: /tmp/s752 holds '${got:-nothing}'"
ev_pass "the click at the window's centre and the line typed reached the demo pod: its shell ran it, and /tmp/s752 holds typedintodemo752"
ev_shot typed "EV-SHOT: the desktop with the demo pod's xterm: the line typed into it, echo typedintodemo752 >/tmp/s752, at its prompt"
ev_client_shot client-view x11-client-demo "EV-SHOT-CLIENT: the display as the demo pod captures it from inside (with the screenshot binary its image ships: the demo requests no toolkit), the typed line in its window" \
    || fail "the demo pod could not capture the display from inside"
ev_save pod-log "EV-LOG-CLIENT: kubectl logs x11-client-demo: its xterm's own output" gq pod-logs x11-client-demo >/dev/null || true
ev_save pod-after "EV-PIDS: the demo pod after it was used" gq pod-state x11-client-demo >/dev/null || true
ev_diff pod "EV-DIFF: the demo pod before and after (empty: the same container)" "$D_POD_B" "$EV_LAST"
pod_same "$D_POD_B" "$EV_LAST" || fail "the demo pod changed or restarted while it was used"
ev_pass "the same container and xterm before and after, restartCount 0"
ev_end

log "cdi: a requesting pod gets DISPLAY + sockets injected by the runtime"
# The verifier pod declares no env/mounts of its own and an identical pod
# WITHOUT the resource request is checked to get nothing, so these
# assertions prove the plugin -> CRI-O CDI path end to end in a live pod.
guest_ev "$GUEST_EV" verify-cdi \
    || { vm_ssh 'sudo /usr/local/bin/k3s kubectl describe pod cdi-verify; echo ---; sudo /usr/local/bin/k3s kubectl get pods -o wide; echo ---; sudo cat /etc/cdi/desktop-display.yaml /etc/cdi/desktop-audio.yaml' \
         2>&1 | tee "$ART/cdi-verify-fail.log" || true; fail "CDI injection verification failed"; }
screendump cdi-verify-window
assert_nonblank cdi-verify-window

log "cdi: each device grants ONLY its own capability"
# The narrow pods are the point of the split: display-only must reach the X
# display and have no audio at all; audio-only must play sound and be unable
# to open the display (X11 here would let it keylog the whole session).
guest_ev "$GUEST_EV" verify-split \
    || { vm_ssh 'sudo /usr/local/bin/k3s kubectl describe pod display-only audio-only; echo ---; sudo cat /etc/cdi/desktop-display.yaml /etc/cdi/desktop-audio.yaml' \
         2>&1 | tee "$ART/verify-split-fail.log" || true; fail "capability split verification failed"; }
# S7.3.2's EV-AUDIO: the audio-only pod plays, and the machine's output
# carries it. Then the narrow pods go.
EV_SIDE=h-
ev_begin S7.3.2 "Split holds in pods" T3
ev_audio_start audio-only 440
vm_ssh 'sudo repo/ci/vm/vm-guest.sh play-audio-pod pulse audio-only' \
    || { audio_capture_stop; fail "the audio-only pod could not play"; }
ev_audio_stop "EV-AUDIO: the machine's output while the audio-only pod played a 440 Hz tone over pulse - listen for one beep" 1 0.05 440 \
    || fail "the audio-only pod's tone was not heard"
ev_pass "audio-only plays: its 440 Hz tone came out of the machine"
ev_end
EV_SIDE=
vm_ssh 'sudo repo/ci/vm/vm-guest.sh split-cleanup' || true

log "cdi: each audio path works from the requesting pod (injected env only)"
# One capture per path, played from the verifier pod using only injected
# env - proves the CDI spec wired pulse/pipewire/ALSA, not the desktop
# image's own local session. Requirements.md S7.6.1 with F7.6's common set:
# for each path the streams before, during (polled until the player's own
# stream shows) and after, the player's own output and the capture with its
# verdict; the pod and the three audio daemons before and after.
# The host's side is S7.6.1's own: nothing in the guest writes to it, so
# the host keeps its title, tier and result (ev_begin with EV_SIDE empty).
EV_SIDE=
ev_begin S7.6.1 "A client plays and the operator hears it" T3
ev_save pod-before "EV-PIDS: the cdi-verify pod's container and its main process's host pid, before it plays" \
    gq pod-state cdi-verify >/dev/null || true
A_POD_B=$EV_LAST
ev_save daemons-before "EV-PIDS: the desktop's three audio daemons before the pod plays" \
    gq ctr-pids pipewire,wireplumber,pipewire-pulse >/dev/null || true
A_DMN_B=$EV_LAST
# Each player's stream is found by its client's executable: paplay and
# pw-play are links to pacat and pw-cat, which is what their clients run
# (stream_apps says more).
for path in pulse pipewire alsa; do
    hz=$(freq_for "$path")
    case $path in pulse) pbin=pacat ;; pipewire) pbin=pw-cat ;; alsa) pbin=aplay ;; esac
    ev_save "streams-before-$path" "EV-STATE: the streams playing before the pod's $path tone" gq stream-apps >/dev/null || true
    ev_audio_start "cdi-$path" "$hz"
    vm_ssh "sudo repo/ci/vm/vm-guest.sh play-audio-pod $path cdi-verify 3" > "$ART/.player-$path.out" 2>&1 &
    pl=$!
    during="" s="" polls=""
    for _ in $(seq 16); do
        sleep 0.5
        s=$(gq stream-apps 2>/dev/null || true)
        polls+="--- $(date -u +%H:%M:%S.%3N)"$'\n'"$s"$'\n'
        if grep -Eq "binary \"$pbin\"" <<<"$s"; then during=$s; break; fi
    done
    pl_rc=0
    wait "$pl" || pl_rc=$?
    if [ -n "$during" ]; then
        ev_text "streams-during-$path" "EV-STATE: the streams while the pod's $path player played (polled every 0.5 s until its stream showed): its stream, its client's executable $pbin and pid" "$during"
    else
        ev_text "streams-during-$path" "EV-STATE: every listing taken while the pod's $path player played, each with its time (UTC): none shows a stream whose client runs $pbin" "${polls:-(no listing)}"
    fi
    ev_audio_stop "EV-AUDIO: the machine's output while the cdi-verify pod played its $hz Hz tone over the $path path, with only the injected env - listen for one beep" 1 0.05 "$hz" \
        || fail "client pod $path audio capture is empty or silent"
    ev_copy "$ART/.player-$path.out" "player-$path" "EV-LOG-CLIENT: the pod's $path player: its command, its own output and its exit status"
    ev_save "streams-after-$path" "EV-STATE: the streams after the $path player ended" gq stream-apps >/dev/null || true
    [ "$pl_rc" = 0 ] || fail "client pod $path playback failed (see the player's log)"
    [ -n "$during" ] || fail "no stream of the pod's $path player was listed while it played"
    ev_pass "over $path the pod's player played: its stream was listed while it played ($(grep -E "binary \"$pbin\"" <<<"$during" | sed -n 1p)), and the machine's output carried its $hz Hz tone"
done
ev_save pod-after "EV-PIDS: the cdi-verify pod after the three paths played" gq pod-state cdi-verify >/dev/null || true
ev_diff pod "EV-DIFF: the cdi-verify pod before and after (empty: the same container)" "$A_POD_B" "$EV_LAST"
pod_same "$A_POD_B" "$EV_LAST" || fail "the cdi-verify pod changed or restarted while it played"
ev_save daemons-after "EV-PIDS: the desktop's three audio daemons after the pod played" \
    gq ctr-pids pipewire,wireplumber,pipewire-pulse >/dev/null || true
ev_diff daemons "EV-DIFF: the audio daemons before and after (empty: none restarted)" "$A_DMN_B" "$EV_LAST"
[ "$(ev_payload "$EV_DIR/$A_DMN_B")" = "$(ev_out)" ] || fail "an audio daemon restarted while the pod played"
ev_pass "the same pod (restartCount 0) and the same three audio daemons before and after"
ev_end
EV_SIDE=

log "cdi: a client can RECORD from the desktop audio (loopback via monitor)"
# Capture direction, not just playback: record the sink monitor while a tone
# plays and confirm the recording carries it. Checked inside the VM, then the
# recording itself comes back here as the story's evidence and is checked
# again with its verdict and level plot kept.
ev_begin S7.6.2 "A client records" T3
ev_save pod-before "EV-PIDS: the cdi-verify pod's container (restartCount, id, start time) and its main process's host pid, before it records" \
    gq pod-state cdi-verify >/dev/null || true
pod_before=$EV_LAST
ev_begin S4.6.1 "A client can record" T3
vm_ssh 'sudo repo/ci/vm/vm-guest.sh verify-record' \
    || { vm_ssh 'sudo /usr/local/bin/k3s kubectl exec cdi-verify -- sh -c "pactl info; pactl list short sources"' \
         2>&1 | tee "$ART/record-fail.log" || true; fail "audio record-direction check failed"; }
recwav=$(ev_name recording-660hz wav)
vm_ssh 'cat /tmp/rec-pulled.wav' > "$EV_DIR/$recwav" \
    || fail "could not copy the client's recording out of the VM"
ev_attach "$recwav" "EV-AUDIO-REC: what the cdi-verify pod recorded with parec from the default sink's monitor while a 660 Hz tone played through the same sink - listen for the beep"
ev_audio_check recording "$recwav" 0.5 0.02 660 \
    || fail "the client's recording is silent or not 660 Hz"
ev_pass "a pod holding only desktop.local/audio recorded the sink's monitor, and the recording carries the 660 Hz tone that played"
ev_end
ev_begin S7.6.2 "A client records" T3
ev_save pod-after "EV-PIDS: the cdi-verify pod's container and its main process's host pid, after it recorded" \
    gq pod-state cdi-verify >/dev/null || true
ev_diff pod "EV-DIFF: the cdi-verify pod across the recording (empty: the same container, not restarted)" "$pod_before" "$EV_LAST"
pb=$(ev_payload "$EV_DIR/$pod_before")
pa=$(ev_payload "$EV_DIR/$EV_LAST")
ev_copy "$ART/S4.6.1/$recwav" recording-660hz "EV-AUDIO-REC: what the cdi-verify pod recorded with parec from the default sink's monitor while a 660 Hz tone played (taken in S4.6.1) - listen for the beep"
ev_audio_check recording "$EV_LAST" 0.5 0.02 660 \
    || fail "the client's recording is silent or not 660 Hz"
ev_pass "the pod's recording carries the 660 Hz tone that played through the sink it monitored"
grep -q 'restartCount=0 ' <<<"$pa" || fail "the cdi-verify pod has restarted: $pa"
[ -n "$pb" ] && [ "$pb" = "$pa" ] || fail "the cdi-verify pod changed across the recording: '$pb' -> '$pa'"
ev_pass "the same container before and after (id, start time and host pid unchanged), restartCount 0"
ev_end

log "cdi: a LEAN non-desktop image works with only the injected env/mounts"
# Proves the CDI contract holds for an ordinary app container (no Xorg
# server, pipewire daemon, session or WM), not just the desktop image.
guest_ev "$GUEST_EV" verify-testclient \
    || { vm_ssh 'sudo /usr/local/bin/k3s kubectl describe pod x11-testclient' \
         2>&1 | tee "$ART/testclient-fail.log" || true; fail "lean client display check failed"; }
# The guest wrote S7.3.4's packages, processes and xdpyinfo; the host adds
# what the machine played (h-prefixed files, ci/evlib.py).
EV_SIDE=h-
ev_begin S7.3.4 "A lean non-desktop image works" T3
for path in pulse pipewire alsa; do
    hz=$(freq_for "$path")
    ev_audio_start "testclient-$path" "$hz"
    vm_ssh "sudo repo/ci/vm/vm-guest.sh play-audio-pod $path x11-testclient" \
        || { audio_capture_stop; fail "lean client $path playback failed"; }
    ev_audio_stop "EV-AUDIO: the machine's output while the lean client pod played its $hz Hz tone over the $path path, with only the injected env - listen for one beep" 1 0.05 "$hz" \
        || fail "lean client $path audio capture is empty or silent"
    ev_pass "the lean client played over the $path path and the machine's output carried its $hz Hz tone"
done
ev_end

log "the lean client plays all three paths and records, with the injected env alone"
# Requirements.md S7.6.6. The lean image runs no PipeWire of its own (S7.3.4
# lists its processes). Its three tones were just heard, in S7.3.4; their
# captures are kept here again with their verdicts, and then the lean client
# records the default sink's monitor while a tone plays through it.
# S7.6.6, like S7.6.1, is the host's alone: its own side.
EV_SIDE=
ev_begin S7.6.6 "A lean client with no PipeWire of its own plays and records" T3
ev_save pod-before "EV-PIDS: the lean client pod x11-testclient's container and its main process's host pid" \
    gq pod-state x11-testclient >/dev/null || true
L_POD_B=$EV_LAST
for path in pulse pipewire alsa; do
    hz=$(freq_for "$path")
    src=$(ls "$EV_ROOT/S7.3.4/"*"-testclient-$path-${hz}hz.wav" 2>/dev/null | sed -n 1p || true)
    [ -n "$src" ] || fail "S7.3.4 kept no capture of the lean client's $path tone"
    ev_copy "$src" "testclient-$path-${hz}hz" "EV-AUDIO: the machine's output while the lean client played its $hz Hz tone over $path (captured in S7.3.4) - listen for one beep"
    ev_audio_check "testclient-$path" "$EV_LAST" 1 0.05 "$hz" \
        || fail "the lean client's $path capture is silent or not $hz Hz"
    ev_pass "the lean client's $path tone was heard: $hz Hz at the machine's output"
done
vm_ssh 'sudo repo/ci/vm/vm-guest.sh verify-record x11-testclient 660' \
    || fail "the lean client could not record the sink's monitor"
recwav=$(ev_name recording-660hz wav)
vm_ssh 'cat /tmp/rec-pulled.wav' > "$EV_DIR/$recwav" \
    || fail "could not copy the lean client's recording out of the VM"
ev_attach "$recwav" "EV-AUDIO-REC: what the lean client recorded with parec from the default sink's monitor while a 660 Hz tone played through it - listen for the beep"
ev_audio_check recording "$recwav" 0.5 0.02 660 \
    || fail "the lean client's recording is silent or not 660 Hz"
ev_pass "the lean client recorded the sink's monitor with only the injected env: its recording carries the 660 Hz tone"
ev_save pod-after "EV-PIDS: the lean client pod after it played and recorded" gq pod-state x11-testclient >/dev/null || true
ev_diff pod "EV-DIFF: the lean client pod before and after (empty: the same container)" "$L_POD_B" "$EV_LAST"
pod_same "$L_POD_B" "$EV_LAST" || fail "the lean client pod changed or restarted"
ev_pass "the same container throughout, restartCount 0"
ev_end
EV_SIDE=

log "screenshot: the injected binary captures the live display from a client pod"
# The lean client image carries the screenshot binary and no other X client
# stack, so the display it captures can only come from desktop.local/display.
#
# A known pattern goes up first and everything below is checked against it.
# Size and "not blank" alone would pass a capture that is upside down,
# mirrored, red/blue swapped or shifted; the pattern is what turns this from
# "it produced a PNG" into "it produced THE SCREEN".
# S7.5.6's EV-PIDS: the capturing pod as it is before any capture.
ss_pod_before=$(vm_ssh 'sudo repo/ci/vm/vm-guest.sh pod-state x11-testclient' 2>&1) \
    || fail "could not read the x11-testclient pod's state: $ss_pod_before"
vm_ssh 'sudo repo/ci/vm/vm-guest.sh screenshot-pattern-start' \
    || { vm_ssh 'sudo /usr/local/bin/k3s kubectl describe pod testpattern; echo ---; sudo /usr/local/bin/k3s kubectl logs testpattern' \
         2>&1 | tee "$ART/screenshot-pattern-fail.log" || true; fail "could not paint the test pattern"; }
# QEMU's own view of the same display, taken while the pattern is up: an
# independent capture path to cross-check orientation against.
screendump screenshot-reference
guest_ev "$GUEST_EV" verify-screenshot \
    || { vm_ssh 'sudo /usr/local/bin/k3s kubectl describe pod x11-testclient; echo ---; sudo cat /etc/cdi/desktop-display.yaml' \
         2>&1 | tee "$ART/screenshot-fail.log" || true; fail "screenshot capture check failed"; }
vm_ssh 'sudo tar -C /tmp/screenshots -cf - .' | tar -C "$ART" -xf - \
    || fail "could not retrieve the captured screenshots from the VM"
# While the pattern pod is still connected: every X client must be
# attributable to its k8s pod from inside the desktop container - the
# window-to-pod identity chain the host-pid-namespace shape exists for
# (SO_PEERCRED -> X-Resource pid -> /proc/<pid>/cgroup -> pod UID).
guest_ev "$GUEST_EV" verify-pod-identity \
    || fail "pod identity check failed"
# Down again before the concurrency phase screendumps the display.
vm_ssh 'sudo repo/ci/vm/vm-guest.sh screenshot-pattern-stop' || true

# The guest wrote S7.4.1's sizes and exit codes; the host adds the pixels
# (h-prefixed files): the seven captures move into the story, and every
# value read from them is a check.
EV_SIDE=h-
ev_begin S7.4.1 "Captured pixels are the screen" T3
declare -A SS
ss_what() {
    case "$1" in
        full) echo "the whole display in file mode, the test pattern up: a different colour in each corner, a dark blue-grey background, yellow and magenta fiducial lines" ;;
        full-stdout) echo "the whole display with --to-stdout: identical to the file-mode capture" ;;
        region) echo "-x 10 -y 20 -w 200 -h 100: the same rectangle of the full capture" ;;
        tl) echo "-w 64 -h 64 at the origin: the pattern's flat red top-left block, nothing else" ;;
        straddle) echo "8x8 at +60+60, across the red block's corner: red in one quadrant, background in three" ;;
        odd) echo "199x40 at +290+0, an odd width: the yellow fiducial at x=300 stays one straight column" ;;
        hw) echo "-w 160 -h 120 (-h is height, not help)" ;;
    esac
}
for f in full full-stdout region tl straddle odd hw; do
    [ -s "$ART/$f.png" ] || fail "screenshot artifact $f.png was not retrieved"
    SS[$f]=$(ev_name "screenshot-$f" png)
    mv "$ART/$f.png" "$EV_DIR/${SS[$f]}"
    ev_attach "${SS[$f]}" "EV-SHOT-CLIENT: $(ss_what "$f")"
    SS[$f]=$EV_DIR/${SS[$f]}
done
ev_copy "$ART/screenshot-reference.png" screenshot-reference "EV-SHOT: QEMU's own screendump of the same moment, the independent view the capture is scored against"
SS_GEOM=$(cat "$ART/geometry.txt")
rm -f "$ART/geometry.txt"
SS_W=${SS_GEOM%x*}
SS_H=${SS_GEOM#*x}
[ "$(identify -format '%wx%h' "${SS[full]}")" = "$SS_GEOM" ] \
    || fail "the full capture is not the $SS_GEOM the client pod reported"
ev_pass "the full capture is $SS_GEOM, the size the client pod reported"

# 1. the capture shows the pattern, in the right colours at the right places
assert_pattern "${SS[full]}" "$SS_W" "$SS_H"
# 2. stdout mode and file mode are the same bytes for the same static screen
[ "$(compare -metric AE "${SS[full]}" "${SS[full-stdout]}" null: 2>&1 || true)" = 0 ] \
    || fail "--to-stdout and file mode produced different images of the same static screen"
ev_pass "--to-stdout and file mode gave the same image (compare -metric AE: 0 pixels differ)"
# 3. every region is exactly the corresponding crop of the full capture
assert_same "${SS[full]}" "${SS[region]}"   200x100+10+20
assert_same "${SS[full]}" "${SS[tl]}"       64x64+0+0
assert_same "${SS[full]}" "${SS[straddle]}" 8x8+60+60
assert_same "${SS[full]}" "${SS[odd]}"      199x40+290+0
assert_same "${SS[full]}" "${SS[hw]}"       160x120+0+0
# 4. the top-left region lands exactly on the pattern's flat red block, so a
#    region origin off by even one pixel shows up as a second colour
[ "$(identify -format '%k' "${SS[tl]}")" = 1 ] \
    || fail "the 64x64+0+0 region is not a single flat colour: its origin is off"
ev_pass "the 64x64+0+0 region is one flat colour (identify %k: 1)"
assert_px "${SS[tl]}" 0 0 255,0,0 "top-left region origin"
assert_px "${SS[tl]}" 63 63 255,0,0 "top-left region far corner"
# 5. cross-check orientation against QEMU's own framebuffer dump
orientation_scores "${SS[full]}" "$ART/screenshot-reference.png"
ss_s0=$ORI_S0 ss_s1=$ORI_S1 ss_s2=$ORI_S2 ss_s3=$ORI_S3
ss_scores="RMSE of the capture against QEMU's screendump (0 is identical; compare -metric RMSE, normalized):
  upright      $ss_s0
  flipped      $ss_s1   (convert -flip: upside down)
  mirrored     $ss_s2   (convert -flop: left-right)
  rotated 180  $ss_s3
The upright score must be under a quarter of the lowest of the other three."
ev_text orientation-scores "the four RMSE scores of the orientation cross-check" "$ss_scores"
orientation_ok "$ss_s0" "$ss_s1" "$ss_s2" "$ss_s3" \
    || fail "the capture matches a flipped/mirrored/rotated QEMU screendump about as well as the upright one: it is not oriented like the real screen"
ev_pass "oriented like the real screen: upright RMSE $ss_s0 against flipped $ss_s1, mirrored $ss_s2, rotated $ss_s3"
log "orientation: the capture matches QEMU's own screendump far better than any flipped variant"
measure_nonblank "${SS[full]}" screenshot-full
ev_end
EV_SIDE=

ev_begin S7.5.6 "A client's capture matches what the operator sees" T3
ev_copy "${SS[full]}" client-capture "EV-SHOT-CLIENT: the lean client pod's capture of the display, the test pattern up"
ev_copy "$ART/screenshot-reference.png" qemu-screendump "EV-SHOT: QEMU's screendump of the same moment: what the operator sees"
ev_text orientation-scores "the four RMSE scores (the same cross-check S7.4.1 records)" "$ss_scores"
orientation_ok "$ss_s0" "$ss_s1" "$ss_s2" "$ss_s3" \
    || fail "the client's capture is no closer to the operator's view than a flipped version of it"
ev_pass "the client's capture matches QEMU's screendump far better than any flipped, mirrored or rotated version (upright $ss_s0; others $ss_s1, $ss_s2, $ss_s3)"
ev_text pod-before "EV-PIDS: the capturing pod (x11-testclient) before the captures: restart count, container id, start time and main process pid" "$ss_pod_before"
ss_pod_after=$(vm_ssh 'sudo repo/ci/vm/vm-guest.sh pod-state x11-testclient' 2>&1) \
    || fail "could not read the x11-testclient pod's state: $ss_pod_after"
ev_text pod-after "EV-PIDS: the same pod after every capture and check" "$ss_pod_after"
[ "$ss_pod_after" = "$ss_pod_before" ] \
    || fail "the capturing pod changed across the captures (see pod-before and pod-after)"
ev_pass "the capturing pod was not restarted: same restart count, container id, start time and main process"
ev_end

log "cdi: concurrent clients share one display"
# Three requesting pods open the display, and two of them re-open it while
# the third holds a connection. Proves the shareable-device concurrency the
# advertised count is there to permit.
guest_ev "$GUEST_EV" verify-concurrency \
    || { vm_ssh 'sudo /usr/local/bin/k3s kubectl get pods -o wide; echo ---; sudo /usr/local/bin/k3s kubectl describe pod x11-client-c' \
         2>&1 | tee "$ART/verify-concurrency-fail.log" || true; fail "concurrency check failed"; }
EV_SIDE=h-
ev_begin S7.3.5 "Concurrency" T3
ev_shot concurrent-clients "EV-SHOT: the three pods' xterms one above the other on the right of the screen, each title bar naming its pod (x11-client-a, -b, -c), each its pod's live X connection; bottom left, pod a's second xterm (the hold), if it has not exited yet"
ev_end
ev_begin S7.5.7 "Many clients share one desktop" T3
ev_shot three-clients "EV-SHOT: the three pods' xterms at their own places on the right of the screen, none covering another (each window's place is in the guest's windows-a, -b and -c files)"
ev_end
EV_SIDE=

log "client journeys: long-running pods through the desktop's own restarts"
# Requirements.md F7.5, F7.6 and F7.8: what a client lives through. The
# journey pod (ci/vm/journey-pod.yaml) holds the display, audio and the
# toolkit, sleeps, and must come out of each event the same container (its
# pod-state lines unchanged, restartCount 0), its applications reconnecting
# or retrying on their own:
#   - the X server killed while the pod shows an xterm and plays a 20 s tone
#     (S7.5.5, S7.6.3, the display half of S7.8.3);
#   - PipeWire killed while the pod plays (S7.6.4, the audio half of S7.8.3);
#   - desktop.service restarted under an xterm, a tone, a screenshot loop and
#     a screenshot held mid-write (S7.8.1, S7.8.2).
# Then a second pod, started while the desktop is down, must work once it is
# up (S7.5.4, S7.6.5). The times in the notes are the guest's clock, which
# the pods share.
vm_ssh 'sudo repo/ci/vm/vm-guest.sh journey-start' || fail "the journey pod did not become Ready"
xorg_pid() { vm_ssh_quick 'sudo podman exec desktop pgrep -x Xorg' 2>/dev/null | sed -n 1p || true; }
# Until a new X session answers: an Xorg other than <old pid>, and mwm up.
x_wait() { # <old Xorg pid>
    local _ p
    for _ in $(seq 60); do
        p=$(xorg_pid)
        if [ -n "$p" ] && [ "$p" != "$1" ] && gq x-up >/dev/null 2>&1; then return 0; fi
        sleep 1
    done
    return 1
}
tone_wait() { # <tag> [pod] [seconds]: until the pod's player has ended
    local st _
    for _ in $(seq "${3:-40}"); do
        st=$(gq journey-tone-status "$1" "${2:-journey}" 2>/dev/null | sed -n 1p || true)
        [ "${st%% *}" = exited ] && return 0
        sleep 1
    done
    return 1
}
# The sink-input indexes in a `streams` listing.
sink_inputs() { awk '/^== pactl list short sink-inputs/ {s = 1; next} /^==/ {s = 0} s && /^[0-9]/ {print $1}' <<<"$1" | paste -sd' '; }
# One field of a journey-stat line: inode or ctime.
stat_field() { sed -n "s/.*$2=\([0-9]*\).*/\1/p" <<<"$1" | sed -n 1p; }
# "comm=pid ..." for the named daemons in a ctr-pids listing.
pids_of() { # <ctr-pids output> <comm...>
    local out=$1
    shift
    awk -v want=" $* " '$1 ~ /^[0-9]+$/ && index(want, " " $NF " ") {print $NF "=" $1}' <<<"$out" | sort | paste -sd' '
}
# What a player or an xterm said last: the last two non-empty lines.
said() { grep -v '^[[:space:]]*$' | tail -2 | paste -sd' '; }

# --- the X server killed under the pod (S7.5.5, S7.6.3, S7.8.3) --------------
ev_begin S7.5.5 "After an X session restart, a client container reconnects without being recreated" T3
ev_save pod-before "EV-PIDS: the journey pod's container (restartCount, id, start time) and its main process's host pid, before the X server is killed" \
    gq pod-state journey >/dev/null || true
J_POD_B=$EV_LAST
gq journey-xterm journey-1 >/dev/null || fail "could not start the pod's first xterm"
gqw win-wait journey-1 30 >/dev/null || fail "the journey pod's first xterm never appeared"
ev_save apps-before "EV-PIDS: the pod's applications before the kill: its first xterm" gq journey-apps >/dev/null || true
grep -q -- '-T journey-1' <<<"$(ev_out)" || fail "the pod's first xterm is not running before the kill"
ev_shot first-xterm "EV-SHOT: the desktop with the journey pod's first xterm (title journey-1), before the X server is killed"
ev_client_shot first-xterm-own journey "EV-SHOT-CLIENT: the same moment as the pod sees it: the toolkit's screenshot run in the pod" \
    || fail "the journey pod could not take its own screenshot before the kill"
ev_save windows-before "EV-STATE: xwininfo -root -tree before the kill, journey-1 among the windows" gq win-tree >/dev/null || true
ev_end

ev_begin S7.8.3 "Socket recreation does not invalidate client mounts" T3
ev_save pod-before-x "EV-PIDS: the journey pod's container before the X server is killed" gq pod-state journey >/dev/null || true
K_POD_BX=$EV_LAST
ev_save x11-before "EV-STATE: ls -li /tmp/.X11-unix inside the journey pod before the X server is killed (the first column is each file's inode)" \
    gq jx ls -li /tmp/.X11-unix >/dev/null || true
K_X11_B=$EV_LAST
ev_save x0-before "EV-STATE: /tmp/.X11-unix/X0 in the pod before the kill: its inode and change time" \
    gq journey-stat /tmp/.X11-unix/X0 >/dev/null || true
x0_b=$(ev_out)
ev_end

ev_begin S7.6.3 "A client's playback continues through an X session restart, uninterrupted" T3
ev_save pod-before "EV-PIDS: the journey pod's container before the X server is killed" gq pod-state journey >/dev/null || true
T_POD_B=$EV_LAST
ev_save daemons-before "EV-PIDS: Xorg, mwm and the three audio daemons before the X server is killed" \
    gq ctr-pids Xorg,mwm,pipewire,wireplumber,pipewire-pulse >/dev/null || true
T_D_B=$EV_LAST
aud_b=$(pids_of "$(ev_out)" pipewire wireplumber pipewire-pulse)
x_old=$(xorg_pid)
[ -n "$x_old" ] || fail "no Xorg to kill"
ev_save sched-before "EV-STATE: PipeWire's threads with their scheduling class and realtime priority, and pw-top's batch view (each node's ERR column counts its xruns), before the tone" \
    gq audio-sched >/dev/null || true
ev_video_start x-restart
t_cap0=$(date +%s.%N) g_cap0=$(gnow)
ev_audio_start through-restart 1100
gq journey-tone through 1100 20 >/dev/null || { audio_capture_stop; fail "could not start the pod's 20 s tone"; }
sleep 3
ev_save streams-before "EV-STATE: pactl list short sink-inputs and source-outputs over the export while the pod plays, before the kill" \
    gq streams >/dev/null || true
si_b=$(sink_inputs "$(ev_out)")
ev_save player-before "EV-PIDS: the pod's applications before the kill: its player" gq journey-apps >/dev/null || true
pl_b=$(awk '$2 == "paplay" {print $1; exit}' <<<"$(ev_out)")
sleep 2
t_kill=$(vm_ssh_quick 'date +%s.%N; sudo podman exec -u desktop desktop pkill -u desktop -x Xorg' 2>/dev/null | sed -n 1p || true)
ev_note "Xorg (pid $x_old) killed (SIGTERM, as the desktop user) at $t_kill, about 5 s into the pod's 20 s tone"
ev_save streams-during "EV-STATE: the sink-inputs and source-outputs right after the kill, while the X session restarts" \
    gq streams >/dev/null || true
si_d=$(sink_inputs "$(ev_out)")
x_wait "$x_old" || { audio_capture_stop; fail "no new X session within 60 s of the kill"; }
ev_note "a new X session (Xorg $(xorg_pid)) answered at $(gnow)"
ev_save streams-after "EV-STATE: the sink-inputs and source-outputs once the X session is back, the tone still playing" \
    gq streams >/dev/null || true
si_a=$(sink_inputs "$(ev_out)")
ev_save player-after "EV-PIDS: the pod's applications once the X session is back: its player" gq journey-apps >/dev/null || true
pl_a=$(awk '$2 == "paplay" {print $1; exit}' <<<"$(ev_out)")
tone_wait through || ev_note "the pod's tone had not ended 40 s after the session came back"
ev_save player "EV-LOG-CLIENT: the pod's player (paplay): its exit status, how long it played and from when to when, its pid, its output" \
    gq journey-tone-status through >/dev/null || true
player=$(ev_out)
p_t0=$(awk '/^played/ {print $5}' <<<"$player")
mark=$(awk -v k="$t_kill" -v s="$p_t0" 'BEGIN {if (k != "" && s != "") printf "%.2f", k - s}')
heard=yes
t_cap1=$(date +%s.%N)
ev_audio_stop "EV-AUDIO: the machine's output while the journey pod played a 20 s 1100 Hz tone, the X server killed about 5 s in (the plot's red line, timed by the player's clock): the tone must play on with no gap and none of it missing" \
    15 0.05 1100 --max-gap 0.1 --span 19.6 20.6 ${mark:+--mark "$mark"} || heard=no
audio_window_record "$t_cap0" "$t_cap1" "$g_cap0"
ev_video_stop "EV-VIDEO: the display going down and coming back while the pod's tone plays (index.txt and the notes give the times)"
T_VID=$EV_VID
ev_save pod-after "EV-PIDS: the journey pod's container after the X session came back" gq pod-state journey >/dev/null || true
T_POD_A=$EV_LAST
ev_diff pod "EV-DIFF: the journey pod across the X restart (no differences: the same container, not restarted)" "$T_POD_B" "$T_POD_A"
ev_save daemons-after "EV-PIDS: Xorg, mwm and the three audio daemons after the X session came back" \
    gq ctr-pids Xorg,mwm,pipewire,wireplumber,pipewire-pulse >/dev/null || true
aud_a=$(pids_of "$(ev_out)" pipewire wireplumber pipewire-pulse)
ev_diff daemons "EV-DIFF: the daemons across the X restart (Xorg and mwm new, the audio daemons not)" "$T_D_B" "$EV_LAST"
grep -q '^exited 0$' <<<"$player" || fail "the pod's player did not end cleanly: $(echo $player)"
played=$(awk '/^played/ {print $2}' <<<"$player")
python3 -c 'import sys; sys.exit(0 if float(sys.argv[1]) <= 21.0 else 1)' "${played:-99}" \
    || fail "the pod's 20 s tone took ${played:-?} s to play: its stream stalled across the X restart"
ev_pass "the pod's player played its 20 s tone in ${played} s and exited 0: the stream never stalled"
p_f=$(awk '/^pid / {print $2}' <<<"$player")
[ -n "$pl_b" ] && [ "$pl_b" = "$pl_a" ] && [ "$pl_b" = "$p_f" ] \
    || fail "the pod's player is not one process across the restart: $pl_b before, $pl_a after, $p_f by its own record"
ev_pass "one player process (pid $pl_b) played before and after the restart"
[ -n "$si_b" ] && [ "$si_d" = "$si_b" ] && [ "$si_a" = "$si_b" ] \
    || fail "the pod's stream did not keep its sink-input across the restart: '$si_b' before, '$si_d' during, '$si_a' after"
ev_pass "its stream kept sink-input $si_b before, during and after the restart: it was never re-created"
[ "$heard" = yes ] || fail "the tone did not play on whole across the X restart (check-audio's verdict says where)"
ev_pass "the machine's output carried the tone across the restart: no stretch below -40 dBFS longer than 0.1 s, and its 20 s span with nothing missing"
[ -n "$aud_b" ] && [ "$aud_b" = "$aud_a" ] || fail "the audio daemons changed across the X restart: $aud_b -> $aud_a"
ev_pass "the three audio daemons kept their pids ($aud_b)"
pod_same "$T_POD_B" "$T_POD_A" || fail "the journey pod's container changed across the X restart"
ev_pass "the pod is the same container, restartCount 0"
ev_end

ev_begin S7.5.5 "After an X session restart, a client container reconnects without being recreated" T3
ev_copy "$ART/S7.6.3/$T_POD_A" pod-after "EV-PIDS: the journey pod's container after the X session came back (taken in S7.6.3)"
J_POD_A=$EV_LAST
ev_diff pod "EV-DIFF: the journey pod across the X restart (no differences: the same container, not restarted)" "$J_POD_B" "$J_POD_A"
ev_save xterm1-log "EV-LOG-CLIENT: the pod's first xterm's own output: it lost its X server with the kill (expected)" \
    gq jx cat /tmp/journey-1.log >/dev/null || true
x1_said=$(ev_out | said)
ev_save apps-after "EV-PIDS: the pod's applications after the X session came back" gq journey-apps >/dev/null || true
x1_left=$(grep -- '-T journey-1' <<<"$(ev_out)" || true)
gq journey-xterm journey-2 >/dev/null || fail "could not start the pod's second xterm"
gqw win-wait journey-2 30 >/dev/null || fail "the pod's second xterm never appeared on the new X server"
ev_shot second-xterm "EV-SHOT: the desktop after the X restart, with the journey pod's second xterm (title journey-2) on it"
ev_client_shot second-xterm-own journey "EV-SHOT-CLIENT: the same moment as the pod sees it, through the new X server" \
    || fail "the journey pod could not take its own screenshot of the new X server"
ev_save windows-after "EV-STATE: xwininfo -root -tree after the restart: journey-2 among the windows, journey-1 gone" gq win-tree >/dev/null || true
ev_copy "$ART/S7.6.3/$T_VID.gif" x-restart "EV-VIDEO: the display going down and coming back across the kill (S7.6.3's recording; its frames are in S7.6.3)"
[ -z "$x1_left" ] || fail "the pod's first xterm is still running after its X server died: $x1_left"
ev_pass "the pod's first xterm ended with its X server${x1_said:+, saying: $x1_said}"
ev_pass "the pod's second xterm appeared on the new X server, and the pod's own screenshot reached it"
pod_same "$J_POD_B" "$J_POD_A" || fail "the journey pod's container changed across the X restart"
ev_pass "the pod is the same container, restartCount 0: it reconnected without being recreated"
ev_end

ev_begin S7.8.3 "Socket recreation does not invalidate client mounts" T3
ev_copy "$ART/S7.6.3/$T_POD_A" pod-after-x "EV-PIDS: the journey pod's container after the X session came back (taken in S7.6.3)"
K_POD_AX=$EV_LAST
ev_diff pod-x "EV-DIFF: the journey pod across the X restart (no differences: the same container)" "$K_POD_BX" "$K_POD_AX"
ev_save x11-after "EV-STATE: ls -li /tmp/.X11-unix inside the journey pod after the X session came back" \
    gq jx ls -li /tmp/.X11-unix >/dev/null || true
ev_diff x11 "EV-DIFF: /tmp/.X11-unix in the pod across the X restart" "$K_X11_B" "$EV_LAST"
ev_save x0-after "EV-STATE: /tmp/.X11-unix/X0 in the pod after the X session came back: its inode and change time" \
    gq journey-stat /tmp/.X11-unix/X0 >/dev/null || true
x0_a=$(ev_out)
ev_save xdpyinfo "EV-STATE: xdpyinfo from the journey pod through its /tmp/.X11-unix mount, after the X restart" \
    gq jx xdpyinfo >/dev/null || fail "xdpyinfo from the pod failed after the X restart"
ino_b=$(stat_field "$x0_b" inode); ino_a=$(stat_field "$x0_a" inode); ct_a=$(stat_field "$x0_a" ctime)
[ -n "$ct_a" ] && [ -n "$t_kill" ] && [ "$ct_a" -ge "${t_kill%.*}" ] \
    || fail "the pod's /tmp/.X11-unix/X0 is not a socket made after the kill (changed at ${ct_a:-?}, the kill at ${t_kill:-?})"
reused=""
[ "$ino_a" != "$ino_b" ] || reused=", the filesystem reusing the number"
ev_pass "the pod sees a new X0: changed at $ct_a, after the kill at ${t_kill%.*} (inode $ino_b -> $ino_a$reused)"
ev_pass "and the pod connects through it: xdpyinfo answers"
pod_same "$K_POD_BX" "$K_POD_AX" || fail "the journey pod's container changed across the X restart"
ev_pass "the pod is the same container across the X restart, restartCount 0"
ev_end

# --- PipeWire killed under the pod (S7.6.4, S7.8.3) --------------------------
ev_begin S7.8.3 "Socket recreation does not invalidate client mounts" T3
ev_save pod-before-audio "EV-PIDS: the journey pod's container before PipeWire is killed" gq pod-state journey >/dev/null || true
K_POD_BA=$EV_LAST
ev_save audio-before "EV-STATE: ls -li /run/desktop-audio inside the journey pod before PipeWire is killed" \
    gq jx ls -li /run/desktop-audio >/dev/null || true
K_AUD_B=$EV_LAST
ev_save pulse-before "EV-STATE: /run/desktop-audio/pulse in the pod before the kill: its inode and change time" \
    gq journey-stat /run/desktop-audio/pulse >/dev/null || true
pu_b=$(ev_out)
ev_end

ev_begin S7.6.4 "A client recovers from an audio-stack restart without being recreated" T3
ev_save pod-before "EV-PIDS: the journey pod's container before PipeWire is killed" gq pod-state journey >/dev/null || true
S_POD_B=$EV_LAST
ev_save daemons-before "EV-PIDS: the three audio daemons before PipeWire is killed" \
    gq ctr-pids pipewire,wireplumber,pipewire-pulse >/dev/null || true
S_D_B=$EV_LAST
pw_old=$(pids_of "$(ev_out)" pipewire)
pw_old=${pw_old#pipewire=}
ev_audio_start before-kill 880
gq journey-tone doomed 880 20 >/dev/null || { audio_capture_stop; fail "could not start the pod's 20 s tone"; }
sleep 3
ev_save streams-before "EV-STATE: pactl list short sink-inputs and source-outputs while the pod plays, before the kill" \
    gq streams >/dev/null || true
[ -n "$(sink_inputs "$(ev_out)")" ] || { audio_capture_stop; fail "no sink-input for the pod's player before the kill"; }
ev_save player-before "EV-PIDS: the pod's applications before the kill: its player" gq journey-apps >/dev/null || true
sleep 1
t_kill_a=$(vm_ssh_quick 'date +%s.%N; sudo podman exec -u desktop desktop pkill -u desktop -x pipewire' 2>/dev/null | sed -n 1p || true)
ev_note "pipewire (pid $pw_old) killed at $t_kill_a, about 4 s into the pod's 20 s tone"
for _ in $(seq 15); do st=$(gq journey-tone-status doomed 2>/dev/null | sed -n 1p || true); [ "${st%% *}" = exited ] && break; sleep 1; done
ev_save streams-during "EV-STATE: the sink-inputs and source-outputs just after the kill" gq streams >/dev/null || true
ev_save player "EV-LOG-CLIENT: the pod's player across the kill: its exit status, when it ended, its pid, and its error" \
    gq journey-tone-status doomed >/dev/null || true
player=$(ev_out)
p_t0=$(awk '/^played/ {print $5}' <<<"$player"); p_t1=$(awk '/^played/ {print $7}' <<<"$player")
mark=$(awk -v k="$t_kill_a" -v s="$p_t0" 'BEGIN {if (k != "" && s != "") printf "%.2f", k - s}')
span=()
[ -z "$mark" ] || span=(--mark "$mark" --span "$(awk -v m="$mark" 'BEGIN {printf "%.1f", m - 1}')" "$(awk -v m="$mark" 'BEGIN {printf "%.1f", m + 1}')")
heard=yes
ev_audio_stop "EV-AUDIO (before): the machine's output while the pod played 880 Hz and PipeWire was killed about 4 s in: the tone, then nothing from the kill on (the red line marks the kill, timed by the player's clock)" \
    1 0.05 880 "${span[@]}" || heard=no
rc=$(sed -n 's/^exited \([0-9]*\)$/\1/p' <<<"$player")
[ -n "$rc" ] || fail "the pod's player was still running 15 s after PipeWire was killed: $(echo $player)"
[ "$rc" != 0 ] || fail "the pod's player exited 0 across PipeWire's kill: its stream did not end with an error"
within=$(awk -v k="$t_kill_a" -v e="$p_t1" 'BEGIN {if (k != "" && e != "") printf "%.1f", e - k}')
python3 -c 'import sys; sys.exit(0 if float(sys.argv[1]) <= 10.0 else 1)' "${within:-99}" \
    || fail "the pod's player ended ${within:-?} s after the kill, not within 10 s"
err=$(awk 'f; /^pid / {f = 1}' <<<"$player" | said)
[ -n "$err" ] || fail "the pod's player exited $rc without a word about why"
ev_pass "the pod's player exited $rc, ${within} s after the kill, with: $err"
[ "$heard" = yes ] || fail "the tone before the kill was not heard, or did not stop at the kill (check-audio's verdict says which)"
ev_pass "the tone was heard up to the kill and stopped there"
pw_new="" ok=no
for _ in $(seq 60); do
    pw_new=$(vm_ssh_quick 'sudo podman exec desktop pgrep -x pipewire' 2>/dev/null | sed -n 1p || true)
    if [ -n "$pw_new" ] && [ "$pw_new" != "$pw_old" ] && gq jx pactl info >/dev/null 2>&1; then ok=yes; break; fi
    sleep 1
done
ev_note "a new pipewire (pid ${pw_new:-none}), the pod's pactl info answering: $ok, at $(gnow)"
[ "$ok" = yes ] || fail "within 60 s of the kill there was no new pipewire the pod could reach"
ev_save daemons-after "EV-PIDS: the three audio daemons after the recovery" gq ctr-pids pipewire,wireplumber,pipewire-pulse >/dev/null || true
ev_diff daemons "EV-DIFF: the audio daemons across the kill (the stack restarted)" "$S_D_B" "$EV_LAST"
ev_save pactl-info "EV-STATE: pactl info from the journey pod after the recovery" gq jx pactl info >/dev/null || true
ev_audio_start after-recovery 770
gq journey-tone recovered 770 4 >/dev/null || { audio_capture_stop; fail "could not start the pod's tone after the recovery"; }
sleep 2
ev_save streams-after "EV-STATE: the sink-inputs and source-outputs while the pod plays again after the recovery" gq streams >/dev/null || true
si_n=$(sink_inputs "$(ev_out)")
tone_wait recovered || true
ev_save player-after "EV-LOG-CLIENT: the pod's next player after the recovery: its exit status, times, pid and output" \
    gq journey-tone-status recovered >/dev/null || true
player2=$(ev_out)
ev_audio_stop "EV-AUDIO (after): the machine's output while the journey pod played 770 Hz after PipeWire came back: one 4 s beep" 2 0.05 770 \
    || fail "the pod's tone after PipeWire's recovery was not heard"
grep -q '^exited 0$' <<<"$player2" || fail "the pod's player after the recovery did not exit 0: $(echo $player2)"
[ -n "$si_n" ] || fail "the pod's new stream never showed as a sink-input"
ev_pass "after the recovery the same pod's next player was heard at 770 Hz and exited 0 (sink-input $si_n)"
ev_save pod-after "EV-PIDS: the journey pod's container after the recovery" gq pod-state journey >/dev/null || true
S_POD_A=$EV_LAST
ev_diff pod "EV-DIFF: the journey pod across the audio restart (no differences: the same container)" "$S_POD_B" "$S_POD_A"
pod_same "$S_POD_B" "$S_POD_A" || fail "the journey pod's container changed across the audio restart"
ev_pass "the pod is the same container, restartCount 0: it recovered without being recreated"
ev_end

ev_begin S7.8.3 "Socket recreation does not invalidate client mounts" T3
ev_copy "$ART/S7.6.4/$S_POD_A" pod-after-audio "EV-PIDS: the journey pod's container after PipeWire came back (taken in S7.6.4)"
K_POD_AA=$EV_LAST
ev_diff pod-audio "EV-DIFF: the journey pod across the audio restart (no differences: the same container)" "$K_POD_BA" "$K_POD_AA"
ev_save audio-after "EV-STATE: ls -li /run/desktop-audio inside the journey pod after PipeWire came back" \
    gq jx ls -li /run/desktop-audio >/dev/null || true
ev_diff audio "EV-DIFF: /run/desktop-audio in the pod across the audio restart" "$K_AUD_B" "$EV_LAST"
ev_save pulse-after "EV-STATE: /run/desktop-audio/pulse in the pod after the recovery: its inode and change time" \
    gq journey-stat /run/desktop-audio/pulse >/dev/null || true
pu_a=$(ev_out)
ev_save pactl-info "EV-STATE: pactl info from the journey pod through its /run/desktop-audio mount, after the audio restart" \
    gq jx pactl info >/dev/null || fail "pactl info from the pod failed after the audio restart"
pi_b=$(stat_field "$pu_b" inode); pi_a=$(stat_field "$pu_a" inode); pc_a=$(stat_field "$pu_a" ctime)
[ -n "$pc_a" ] && [ -n "$t_kill_a" ] && [ "$pc_a" -ge "${t_kill_a%.*}" ] \
    || fail "the pod's /run/desktop-audio/pulse is not a socket made after the kill (changed at ${pc_a:-?}, the kill at ${t_kill_a:-?})"
reused=""
[ "$pi_a" != "$pi_b" ] || reused=", the filesystem reusing the number"
ev_pass "the pod sees a new pulse socket: changed at $pc_a, after the kill at ${t_kill_a%.*} (inode $pi_b -> $pi_a$reused)"
ev_pass "and the pod connects through it: pactl info answers"
pod_same "$K_POD_BA" "$K_POD_AA" || fail "the journey pod's container changed across the audio restart"
ev_pass "the pod is the same container across the audio restart, restartCount 0"
ev_end

# --- desktop.service restarted under the pod (S7.8.1, S7.8.2) ----------------
ev_begin S7.8.2 "Toolkit republish under a running client is harmless" T3
ev_save pod-before "EV-PIDS: the journey pod's container before desktop.service restarts" gq pod-state journey >/dev/null || true
R_POD_B=$EV_LAST
ev_save tools-before "EV-STATE: ls -li \$DESKTOP_TOOLS_BIN inside the journey pod before the restart" gq journey-tools-ls >/dev/null || true
R_TOOLS_B=$EV_LAST
gq journey-noise >/dev/null || fail "could not open the noise xterm"
gqw win-wait noise 30 >/dev/null || fail "the noise xterm never appeared"
sleep 1
ev_save png-size "EV-STATE: the size in bytes of a PNG of the display with the noise xterm over it, from the pod's screenshot: more than a pipe's 65536 holds" \
    gq journey-shot-size >/dev/null || true
png=$(ev_out | tail -1 | tr -d ' ')
[ "${png:-0}" -gt 70000 ] 2>/dev/null || fail "a screenshot of the noise screen is ${png:-?} bytes: too small to hold the binary on a pipe"
gq journey-held-start >/dev/null || fail "could not start the held screenshot"
sleep 2
ev_save held-before "EV-PIDS: the held screenshot before the restart: alive, the executable it runs and that file's inode, beside the toolkit file's own inode" \
    gq journey-held-state >/dev/null || true
held_b=$(ev_out)
grep -q '^alive yes' <<<"$held_b" || fail "the held screenshot is not running before the restart: $(echo $held_b)"
gq journey-loop-start >/dev/null || fail "could not start the screenshot loop"
sleep 2
ev_save loop-before "EV-PIDS: the screenshot loop's shell in the pod before the restart" gq jx pgrep -f shot-loop.sh >/dev/null || true
loop_b=$(ev_out | sed -n 1p)
ev_end

ev_begin S7.8.1 "A desktop.service restart does not recreate client pods" T3
ev_save pod-before "EV-PIDS: the journey pod's container before desktop.service restarts" gq pod-state journey >/dev/null || true
D_POD_B=$EV_LAST
ev_save daemons-before "EV-PIDS: Xorg, mwm and the three audio daemons before the restart" \
    gq ctr-pids Xorg,mwm,pipewire,wireplumber,pipewire-pulse >/dev/null || true
D_D_B=$EV_LAST
gq journey-xterm journey-3 >/dev/null || fail "could not start the pod's xterm journey-3"
gqw win-wait journey-3 30 >/dev/null || fail "the pod's xterm journey-3 never appeared"
gq journey-tone cutoff 550 30 >/dev/null || fail "could not start the pod's 30 s tone"
sleep 3
ev_save apps-before "EV-PIDS: the pod's applications before the restart: xterms, the player, the screenshot loop and the held screenshot" \
    gq journey-apps >/dev/null || true
apps_b=$(ev_out)
grep -q -- '-T journey-3' <<<"$apps_b" && grep -q paplay <<<"$apps_b" \
    || fail "the pod's xterm and player are not both running before the restart: $(echo $apps_b)"
ev_save streams-before "EV-STATE: the sink-inputs and source-outputs before the restart, the pod's tone playing" gq streams >/dev/null || true
x_old=$(xorg_pid)
[ -n "$x_old" ] || fail "no Xorg running before the restart"
ev_video_start desktop-restart
ev_note "systemctl restart desktop.service at $(gnow)"
vm_ssh 'sudo systemctl restart desktop.service' || fail "systemctl restart desktop.service failed"
x_wait "$x_old" || fail "no new X session within 60 s of the restart"
t_back=$(gnow)
aud=no
for _ in $(seq 60); do gq jx pactl info >/dev/null 2>&1 && { aud=yes; break; }; sleep 1; done
ev_note "a new X session answered at $t_back; the pod's pactl info answered again: $aud, at $(gnow)"
sleep 3
ev_video_stop "EV-VIDEO: the display across desktop.service's restart (index.txt and the notes give the times)"
ev_end

ev_begin S7.8.2 "Toolkit republish under a running client is harmless" T3
ev_save held-after "EV-PIDS: the held screenshot after the restart: still alive, its executable the replaced file, (deleted), with the old inode, while the toolkit file has a new one" \
    gq journey-held-state >/dev/null || true
held_a=$(ev_out)
ev_save loop-after "EV-PIDS: the screenshot loop's shell after the restart" gq jx pgrep -f shot-loop.sh >/dev/null || true
loop_a=$(ev_out | sed -n 1p)
gq journey-loop-stop >/dev/null || true
ev_save loop-log "EV-LOG-CLIENT: the screenshot loop's log across the restart: guest time, try, exit status, the tool's output" \
    gq journey-loop-log >/dev/null || true
loop=$(ev_out)
ev_save held-release "EV-LOG-CLIENT: the held screenshot, released after the restart: its exit status and the size of the PNG it finished" \
    gqw journey-held-release >/dev/null || true
rel=$(ev_out)
ev_save tools-after "EV-STATE: ls -li \$DESKTOP_TOOLS_BIN inside the journey pod after the restart" gq journey-tools-ls >/dev/null || true
ev_diff tools "EV-DIFF: the toolkit in the pod across the restart (each republished file has a new inode)" "$R_TOOLS_B" "$EV_LAST"
ev_save desktop-log "EV-LOG-DESKTOP: the restarted desktop container's publish lines (podman logs desktop)" \
    gq desktop-publish-log >/dev/null || true
dlog=$(ev_out)
ev_save pod-after "EV-PIDS: the journey pod's container after the restart" gq pod-state journey >/dev/null || true
R_POD_A=$EV_LAST
ev_diff pod "EV-DIFF: the journey pod across the restart (no differences: the same container)" "$R_POD_B" "$R_POD_A"
grep -q 'published screenshot' <<<"$dlog" || fail "the restarted desktop did not log 'published screenshot'"
! grep -qE 'Text file busy|ETXTBSY|publish-tools failed' <<<"$dlog" \
    || fail "the republish hit an error: $(grep -E 'Text file busy|ETXTBSY|publish-tools failed' <<<"$dlog" | head -2)"
ev_pass "the restarted desktop logged 'published screenshot', with no Text file busy and no failed publish"
ino_old=$(awk '/^file-inode/ {print $2}' <<<"$held_b"); exe_b=$(awk '/^exe-inode/ {print $2}' <<<"$held_b")
ino_new=$(awk '/^file-inode/ {print $2}' <<<"$held_a"); exe_a=$(awk '/^exe-inode/ {print $2}' <<<"$held_a")
grep -q '^alive yes' <<<"$held_a" || fail "the held screenshot did not live through the restart: $(echo $held_a)"
grep -q '^exe .*(deleted)$' <<<"$held_a" || fail "the held screenshot's executable was not replaced under it: $(grep '^exe ' <<<"$held_a")"
[ -n "$ino_old" ] && [ "$exe_b" = "$ino_old" ] && [ "$exe_a" = "$ino_old" ] && [ -n "$ino_new" ] && [ "$ino_new" != "$ino_old" ] \
    || fail "the inodes do not show a republish under the held screenshot: the file $ino_old -> $ino_new, its executable $exe_b -> $exe_a"
ev_pass "the republish gave screenshot a new inode ($ino_old -> $ino_new) while the held screenshot ran on from the old one, now (deleted)"
rc_h=$(awk '/^rc / {print $2}' <<<"$rel"); bytes_h=$(awk '/^png-bytes/ {print $2}' <<<"$rel")
[ "$rc_h" = 0 ] && [ "${bytes_h:-0}" -gt 65536 ] \
    || fail "the held screenshot did not finish cleanly once released: exit ${rc_h:-?}, ${bytes_h:-0} bytes"
ev_pass "released, it wrote the rest of its ${bytes_h}-byte PNG and exited 0: the old mapping stayed intact"
read -r n_after n_bad <<<"$(awk -v t="$t_back" '$1 > t {n++; if ($3 != 0) b++} END {print n + 0, b + 0}' <<<"$loop")"
n_down=$(awk '$3 != 0 {b++} END {print b + 0}' <<<"$loop")
[ "$n_after" -ge 4 ] && [ "$n_bad" = 0 ] \
    || fail "of the loop's $n_after tries after the desktop was back (at $t_back), $n_bad failed"
ev_pass "every one of the loop's $n_after tries after the desktop was back succeeded ($n_down failed while it was down)"
[ -n "$loop_b" ] && [ "$loop_b" = "$loop_a" ] || fail "the screenshot loop did not run on as one process: ${loop_b:-none} -> ${loop_a:-none}"
ev_pass "the loop ran on as one process (pid $loop_b) across the restart"
pod_same "$R_POD_B" "$R_POD_A" || fail "the journey pod's container changed across the restart"
ev_pass "the pod is the same container, restartCount 0"
ev_end

ev_begin S7.8.1 "A desktop.service restart does not recreate client pods" T3
ev_copy "$ART/S7.8.2/$R_POD_A" pod-after "EV-PIDS: the journey pod's container after the restart (taken in S7.8.2)"
D_POD_A=$EV_LAST
ev_diff pod "EV-DIFF: the journey pod across the restart (no differences: the same container)" "$D_POD_B" "$D_POD_A"
ev_save daemons-after "EV-PIDS: Xorg, mwm and the three audio daemons after the restart" \
    gq ctr-pids Xorg,mwm,pipewire,wireplumber,pipewire-pulse >/dev/null || true
ev_diff daemons "EV-DIFF: the desktop's daemons across the restart (all new)" "$D_D_B" "$EV_LAST"
ev_save xterm3-log "EV-LOG-CLIENT: the pod's xterm journey-3: what it said when the restart took its X server (expected)" \
    gq jx cat /tmp/journey-3.log >/dev/null || true
x3_said=$(ev_out | said)
ev_save player-cut "EV-LOG-CLIENT: the pod's 30 s player that the restart cut off: its exit status, times, pid and error (expected)" \
    gq journey-tone-status cutoff >/dev/null || true
cut=$(ev_out)
ev_save apps-after "EV-PIDS: the pod's applications after the restart" gq journey-apps >/dev/null || true
apps_a=$(ev_out)
gq journey-xterm journey-4 >/dev/null || fail "could not start the pod's xterm journey-4"
gqw win-wait journey-4 30 >/dev/null || fail "the pod's new xterm never appeared after the restart"
ev_shot after "EV-SHOT: the desktop after the restart, with the pod's new xterm (title journey-4)"
ev_audio_start after-restart 660
gq journey-tone fresh 660 3 >/dev/null || { audio_capture_stop; fail "could not start the pod's tone after the restart"; }
tone_wait fresh || true
ev_save player-after "EV-LOG-CLIENT: the pod's new player after the restart: its exit status, times, pid and output" \
    gq journey-tone-status fresh >/dev/null || true
fresh=$(ev_out)
ev_audio_stop "EV-AUDIO: the machine's output while the journey pod played 660 Hz after the restart: one 3 s beep" 1 0.05 660 \
    || fail "the pod's tone after the restart was not heard"
! grep -q -- '-T journey-3' <<<"$apps_a" || fail "the pod's xterm journey-3 outlived its X server"
ev_pass "the pod's xterm journey-3 lost its X connection with the restart (expected)${x3_said:+: $x3_said}"
rc_c=$(sed -n 's/^exited \([0-9]*\)$/\1/p' <<<"$cut")
[ -n "$rc_c" ] && [ "$rc_c" != 0 ] || fail "the pod's 30 s player was not cut off by the restart: $(echo $cut)"
cut_said=$(awk 'f; /^pid / {f = 1}' <<<"$cut" | said)
ev_pass "the pod's 30 s player lost its stream with the restart and exited $rc_c (expected)${cut_said:+: $cut_said}"
ev_pass "a new xterm from the same pod appeared on the restarted desktop"
grep -q '^exited 0$' <<<"$fresh" || fail "the pod's new player did not exit 0: $(echo $fresh)"
ev_pass "a new tone from the same pod was heard at 660 Hz and its player exited 0"
pod_same "$D_POD_B" "$D_POD_A" || fail "the journey pod's container changed across desktop.service's restart"
ev_pass "the pod is the same container across the restart: restartCount 0, its container id unchanged"
ev_end

# --- a pod started while the desktop is down (S7.5.4, S7.6.5) ----------------
ev_begin S7.5.4 "A client started before the desktop is up works once it is, without restarting" T3
vm_ssh 'sudo systemctl stop desktop.service' || fail "systemctl stop desktop.service failed"
ev_note "desktop.service stopped at $(gnow)"
ev_save desktop-down "EV-STATE: desktop.service with the desktop stopped, and the X socket directory" \
    vm_ssh_quick 'systemctl is-active desktop.service; ls -l /tmp/.X11-unix' >/dev/null || true
vm_ssh 'sudo repo/ci/vm/vm-guest.sh journey-start ci/vm/early-pod.yaml early' \
    || fail "the early pod was not admitted and Ready while the desktop was down"
ev_save pod-before "EV-PIDS: the early pod's container, admitted and running with the desktop down" gq pod-state early >/dev/null || true
E_POD_B=$EV_LAST
gq journey-put early 990 6 early >/dev/null || fail "could not put the tone into the early pod"
sleep 4
ev_save x-tries-down "EV-LOG-CLIENT: the early pod's xterm tries with the desktop down: each fails to open the display" \
    gq jx-in early cat /tmp/x-tries.log >/dev/null || true
ev_end
ev_begin S7.6.5 "A client started before the audio stack is up plays once it is, without restarting" T3
ev_copy "$ART/S7.5.4/$E_POD_B" pod-before "EV-PIDS: the early pod's container with the desktop down (taken in S7.5.4)"
F_POD_B=$EV_LAST
ev_save audio-tries-down "EV-LOG-CLIENT: the early pod's paplay tries with the desktop down: each fails to connect" \
    gq jx-in early cat /tmp/audio-tries.log >/dev/null || true
ev_save streams-down "EV-STATE: pactl list short sink-inputs and source-outputs over the export with the desktop down" gq streams >/dev/null || true
ev_audio_start early 990
ev_end
ev_begin S7.5.4 "A client started before the desktop is up works once it is, without restarting" T3
ev_video_start desktop-start
ev_note "systemctl start desktop.service at $(gnow)"
vm_ssh 'sudo systemctl start desktop.service' || fail "systemctl start desktop.service failed"
ev_end
ev_begin S7.6.5 "A client started before the audio stack is up plays once it is, without restarting" T3
si_e=""
for _ in $(seq 60); do
    si_e=$(sink_inputs "$(gq streams 2>/dev/null)")
    [ -n "$si_e" ] && break
    [ -z "$(gq jx-in early cat /tmp/early.rc 2>/dev/null)" ] || break
    sleep 1
done
ev_save streams-playing "EV-STATE: the sink-inputs and source-outputs once the audio stack was up, the early pod playing" gq streams >/dev/null || true
done_rc=""
for _ in $(seq 60); do done_rc=$(gq jx-in early cat /tmp/early.rc 2>/dev/null || true); [ -n "$done_rc" ] && break; sleep 1; done
ev_save audio-tries "EV-LOG-CLIENT: the early pod's paplay tries: the failures while the audio stack was down, then the one that played" \
    gq jx-in early cat /tmp/audio-tries.log >/dev/null || true
at=$(ev_out)
ev_audio_stop "EV-AUDIO: the machine's output from before desktop.service started until the early pod's player ended: its 990 Hz tone, played once the audio stack was up - one 6 s beep" 2 0.05 990 \
    || fail "the early pod's tone was not heard once the audio stack was up"
ev_save pod-after "EV-PIDS: the early pod's container once the desktop was up" gq pod-state early >/dev/null || true
F_POD_A=$EV_LAST
ev_diff pod "EV-DIFF: the early pod across the desktop's start (no differences: the same container)" "$F_POD_B" "$F_POD_A"
a_fail=$(grep -c 'paplay exited' <<<"$at" || true)
[ "$done_rc" = 0 ] && grep -q 'paplay played the tone' <<<"$at" \
    || fail "the early pod's player never played its tone: rc '${done_rc:-none}'"
[ "${a_fail:-0}" -ge 1 ] || fail "the early pod's player never had to retry: the audio stack was not down when it tried"
ev_pass "the early pod's paplay failed $a_fail times while the audio stack was down, then played its tone, heard at 990 Hz"
if [ -n "$si_e" ]; then
    ev_pass "its stream showed as sink-input $si_e while it played"
else
    ev_note "its stream was not caught in pactl list short sink-inputs while it played"
fi
pod_same "$F_POD_B" "$F_POD_A" || fail "the early pod's container changed while it waited for audio"
ev_pass "the early pod is the same container it started as, restartCount 0"
ev_end
ev_begin S7.5.4 "A client started before the desktop is up works once it is, without restarting" T3
gqw win-wait early-client 120 >/dev/null || fail "the early pod's xterm never appeared once the desktop was up"
ev_note "the early pod's xterm was on the display at $(gnow)"
ev_video_stop "EV-VIDEO: the display from desktop.service's start until the early pod's xterm is on it (index.txt and the notes give the times)"
ev_shot early-client "EV-SHOT: the desktop once it came up, with the early pod's xterm (title early-client)"
ev_client_shot early-client-own early "EV-SHOT-CLIENT: the early pod's own screenshot once the desktop was up" \
    || fail "the early pod could not take its own screenshot once the desktop was up"
ev_save windows "EV-STATE: xwininfo -root -tree with the early pod's xterm" gq win-tree >/dev/null || true
ev_save apps "EV-PIDS: the early pod's applications once the desktop was up" gq journey-apps early >/dev/null || true
ev_save x-tries "EV-LOG-CLIENT: the early pod's xterm tries: the failures while the desktop was down, then the try that stayed up" \
    gq jx-in early cat /tmp/x-tries.log >/dev/null || true
xt=$(ev_out)
ev_copy "$ART/S7.6.5/$F_POD_A" pod-after "EV-PIDS: the early pod's container once the desktop was up (taken in S7.6.5)"
E_POD_A=$EV_LAST
ev_diff pod "EV-DIFF: the early pod across the desktop's start (no differences: the same container)" "$E_POD_B" "$E_POD_A"
x_fail=$(grep -c 'xterm exited' <<<"$xt" || true)
last=$(grep 'try [0-9]*: xterm' <<<"$xt" | tail -1)
[ "${x_fail:-0}" -ge 1 ] || fail "the early pod's xterm never had to retry: the desktop was not down when it started"
grep -q ': xterm$' <<<"$last" || fail "the early pod's last xterm try is not one still running: $last"
ev_pass "the early pod's xterm failed $x_fail times while the desktop was down; the next try stayed up, and its window appeared"
pod_same "$E_POD_B" "$E_POD_A" || fail "the early pod's container changed while it waited for the desktop"
ev_pass "the early pod is the same container it started as, restartCount 0"
ev_end

# --- the pod's audio across hot-added sound cards (S7.7.4-S7.7.7) -----------
# The journey pod has run since the journeys began. A USB sound card arrives
# under its tone and becomes the default (S7.7.4); a new player in the pod
# targets the card by name (S7.7.6); the card leaves under the pod's next
# tone (S7.7.5); the pod records from a capture card hot-added on PCI
# (S7.7.7). Every card QEMU adds plays into the audiodev the capture reads.
log "client journeys: the pod's audio across hot-added sound cards (F7.7)"
# The sink-input <id>'s sink index in a `streams` listing.
si_sink() { awk -v s="$2" '/^== pactl list short sink-inputs/ {f = 1; next} /^==/ {f = 0} f && $1 == s {print $2}' <<<"$1"; }
# A sink's index by name, now.
sink_idx() { gq desk pactl list short sinks 2>/dev/null | awk -v n="$1" '$2 == n {print $1}'; }
ev_begin S7.7.4 "A client already playing is heard on a hot-added audio device, without restarting" T3
ev_save pod-before "EV-PIDS: the journey pod's container before the USB card arrives" gq pod-state journey >/dev/null || true
U_POD_B=$EV_LAST
ev_save daemons-before "EV-PIDS: Xorg, mwm and the three audio daemons before the USB card arrives" \
    gq ctr-pids Xorg,mwm,pipewire,wireplumber,pipewire-pulse >/dev/null || true
U_D_B=$EV_LAST
u_dmn_b=$(pids_of "$(ev_out)" Xorg mwm pipewire wireplumber pipewire-pulse)
snd_set base "before the USB sound card arrives"
snd_keep
u_builtin=$(ev_payload "$EV_DIR/$SN_DEF" | head -1)
[ -n "$u_builtin" ] || fail "no default sink before the USB card arrives"
ev_video_start usb-arrives
ev_audio_start arrival 1100
gq journey-tone usb774 1100 20 >/dev/null || { audio_capture_stop; fail "could not start the pod's 20 s tone"; }
sleep 4
ev_save streams-before "EV-STATE: the streams (pactl list short sink-inputs and source-outputs) with the pod's tone on the built-in card, before the USB card arrives" \
    gq streams >/dev/null || true
u_si=$(sink_inputs "$(ev_out)")
ev_save player-before "EV-PIDS: the pod's applications before the USB card arrives: its player" gq journey-apps >/dev/null || true
u_pl_b=$(awk '$2 == "paplay" {print $1; exit}' <<<"$(ev_out)")
t_plug=$(gnow)
ev_qemu device-add "EV-QEMU: device_add usb-audio,id=s774snd,audiodev=snd0,bus=xhci.0 under the pod's tone, and QEMU's reply (empty: accepted)" \
    "device_add usb-audio,id=s774snd,audiodev=snd0,bus=xhci.0" >/dev/null || { audio_capture_stop; fail "QEMU refused device_add usb-audio"; }
ev_note "device_add usb-audio at $t_plug (the guest's clock), about 4 s into the pod's 20 s tone"
u_sink=""
for _ in $(seq 15); do
    u_sink=$(comm -13 <(ev_payload "$EV_DIR/$SB_SINKS" | awk '{print $2}' | sort) \
                      <(gq desk pactl list short sinks 2>/dev/null | awk '{print $2}' | sort) | head -1)
    [ -n "$u_sink" ] && break
    sleep 1
done
[ -n "$u_sink" ] || { audio_capture_stop; fail "no sink appeared for the USB card within 15 s"; }
# WirePlumber gives a new device 0.40, which the USB card renders at about
# -24 dB (S4.7.3): full volume, so the level plot shows the move, not a drop.
gq desk pactl set-sink-volume "$u_sink" 100% >/dev/null || true
gq desk pactl set-default-sink "$u_sink" >/dev/null || { audio_capture_stop; fail "pactl set-default-sink $u_sink failed"; }
ev_note "the USB card's sink, $u_sink, made the default at full volume at $(gnow)"
u_on=""
for _ in $(seq 10); do
    u_idx=$(sink_idx "$u_sink")
    [ -n "$u_idx" ] && [ "$(si_sink "$(gq streams 2>/dev/null || true)" "$u_si")" = "$u_idx" ] && { u_on=yes; break; }
    sleep 1
done
ev_save streams-on "EV-STATE: the streams once the USB card is the default: the pod's sink-input $u_si on the card's sink" gq streams >/dev/null || true
ev_save sinks-on "EV-STATE: pactl list short sinks with the USB card plugged in (index, then name)" gq desk pactl list short sinks >/dev/null || true
ev_save player-on "EV-PIDS: the pod's applications with its stream on the USB card" gq journey-apps >/dev/null || true
u_pl_on=$(awk '$2 == "paplay" {print $1; exit}' <<<"$(ev_out)")
snd_set on "with the USB card plugged in and the default, the pod's tone playing on it"
snd_diffs on "the USB card's arrival"
tone_wait usb774 journey 30 || ev_note "the pod's tone had not ended 30 s after the card arrived"
ev_save player "EV-LOG-CLIENT: the pod's player (paplay): its exit status, how long it played and from when to when, its pid, its output" \
    gq journey-tone-status usb774 >/dev/null || true
u_player=$(ev_out)
u_t0=$(awk '/^played/ {print $5}' <<<"$u_player")
m_plug=$(awk -v k="$t_plug" -v s="$u_t0" 'BEGIN {if (k != "" && s != "") printf "%.2f", k - s}')
u_heard=yes
ev_audio_stop "EV-AUDIO: the machine's output while the journey pod played a 20 s 1100 Hz tone, the USB card plugged in about 4 s in (the red line, timed by the player's clock) and made the default: the tone must play on, the second part from the USB card, with no gap and none of it missing" \
    15 0.05 1100 --max-gap 0.1 --span 19.6 20.6 ${m_plug:+--mark "$m_plug"} || u_heard=no
ev_video_stop "EV-VIDEO: the display while the USB card arrives under the pod's tone (index.txt and the notes give the times)"
ev_save pod-after "EV-PIDS: the journey pod's container after the USB card arrived" gq pod-state journey >/dev/null || true
U_POD_A=$EV_LAST
ev_diff pod "EV-DIFF: the journey pod across the card's arrival (no differences: the same container, not restarted)" "$U_POD_B" "$U_POD_A"
ev_save daemons-after "EV-PIDS: Xorg, mwm and the three audio daemons after the USB card arrived" \
    gq ctr-pids Xorg,mwm,pipewire,wireplumber,pipewire-pulse >/dev/null || true
u_dmn_a=$(pids_of "$(ev_out)" Xorg mwm pipewire wireplumber pipewire-pulse)
ev_diff daemons "EV-DIFF: Xorg, mwm and the audio daemons across the card's arrival (no differences: none restarted)" "$U_D_B" "$EV_LAST"
[ "$u_on" = yes ] || fail "the pod's stream (sink-input $u_si) never sat on the USB card's sink $u_sink"
ev_pass "with the USB card the default, the pod's existing stream, sink-input $u_si, moved onto its sink $u_sink"
grep -q '^exited 0$' <<<"$u_player" || fail "the pod's player did not end cleanly: $(echo $u_player)"
u_played=$(awk '/^played/ {print $2}' <<<"$u_player")
python3 -c 'import sys; sys.exit(0 if float(sys.argv[1]) <= 21.0 else 1)' "${u_played:-99}" \
    || fail "the pod's 20 s tone took ${u_played:-?} s to play: its stream stalled when the card arrived"
u_pid=$(awk '/^pid / {print $2}' <<<"$u_player")
[ -n "$u_pl_b" ] && [ "$u_pl_b" = "$u_pl_on" ] && [ "$u_pl_b" = "$u_pid" ] \
    || fail "the pod's player is not one process across the card's arrival: $u_pl_b before, $u_pl_on on the USB card, $u_pid by its own record"
ev_pass "one player process (pid $u_pl_b) played before and after the card arrived, and exited 0 after ${u_played} s"
[ "$u_heard" = yes ] || fail "the machine's output did not carry the tone whole across the card's arrival (check-audio's verdict says where)"
ev_pass "the machine's output carried the tone across the arrival: no stretch below -40 dBFS longer than 0.1 s, and its 20 s span with nothing missing"
[ -n "$u_dmn_b" ] && [ "$u_dmn_b" = "$u_dmn_a" ] || fail "Xorg, mwm or an audio daemon changed: $u_dmn_b -> $u_dmn_a"
ev_pass "Xorg, mwm and the three audio daemons kept their pids ($u_dmn_b)"
pod_same "$U_POD_B" "$U_POD_A" || fail "the journey pod's container changed across the card's arrival"
ev_pass "the pod is the same container, restartCount 0"
ev_end

ev_begin S7.7.6 "A client started while the hot-added device is present can target it by name" T3
ev_save pod-before "EV-PIDS: the journey pod's container before its new player starts" gq pod-state journey >/dev/null || true
W_POD_B=$EV_LAST
# The default back on the built-in card, muted: a player that did not name
# the USB card would go there and not be heard.
gq desk pactl set-default-sink "$u_builtin" >/dev/null || fail "pactl set-default-sink $u_builtin failed"
gq desk pactl set-sink-mute "$u_builtin" 1 >/dev/null || fail "pactl set-sink-mute $u_builtin 1 failed"
ev_save wpctl "EV-STATE: wpctl status with the built-in card the default (marked *) and muted, the USB card at full volume" \
    gq desk wpctl status >/dev/null || true
ev_audio_start by-name 990
gq journey-tone named776 990 4 "$u_sink" >/dev/null || { audio_capture_stop; fail "could not start the pod's player with PULSE_SINK=$u_sink"; }
w_on=""
for _ in $(seq 6); do
    sleep 0.5
    w_ls=$(gq streams 2>/dev/null || true)
    w_idx=$(sink_idx "$u_sink")
    for w_si in $(sink_inputs "$w_ls"); do
        [ -n "$w_idx" ] && [ "$(si_sink "$w_ls" "$w_si")" = "$w_idx" ] && { w_on=$w_si; break; }
    done
    [ -n "$w_on" ] && break
done
ev_text streams-during "EV-STATE: the streams while the new player played: its sink-input on the USB card's sink (index ${w_idx:-?})" "${w_ls:-(no listing)}"
ev_save sinks-during "EV-STATE: pactl list short sinks while the new player played (index, then name)" gq desk pactl list short sinks >/dev/null || true
tone_wait named776 journey 15 || true
ev_save player "EV-LOG-CLIENT: the pod's new player (PULSE_SINK=$u_sink paplay): its exit status, how long it played, its pid, its output" \
    gq journey-tone-status named776 >/dev/null || true
w_player=$(ev_out)
w_heard=yes
ev_audio_stop "EV-AUDIO: the machine's output while the pod's new player played 990 Hz to the USB card by name, the built-in card the default and muted: what is heard came out of the USB card - listen for one beep" \
    2 0.05 990 || w_heard=no
gq desk pactl set-sink-mute "$u_builtin" 0 >/dev/null || true
ev_save pod-after "EV-PIDS: the journey pod's container after its new player ended" gq pod-state journey >/dev/null || true
W_POD_A=$EV_LAST
ev_diff pod "EV-DIFF: the journey pod across its new player (no differences: the same container)" "$W_POD_B" "$W_POD_A"
grep -q '^exited 0$' <<<"$w_player" || fail "the pod's player for $u_sink did not end cleanly: $(echo $w_player)"
[ -n "$w_on" ] || fail "no stream sat on the USB card's sink while the player that named it played"
ev_pass "the new player, PULSE_SINK=$u_sink paplay (pid $(awk '/^pid / {print $2}' <<<"$w_player")), played to the USB card by name: its sink-input $w_on sat on that sink (index $w_idx), and it exited 0"
[ "$w_heard" = yes ] || fail "the 990 Hz tone sent to the USB card by name was not heard"
ev_pass "with the default on the muted built-in card, the machine's output carried the 990 Hz tone: the USB card rendered it"
pod_same "$W_POD_B" "$W_POD_A" || fail "the journey pod's container changed"
ev_pass "the pod is the same container, restartCount 0"
ev_end

ev_begin S7.7.5 "A client playing on the hot-added device survives its removal" T3
ev_save pod-before "EV-PIDS: the journey pod's container before the USB card is removed" gq pod-state journey >/dev/null || true
V_POD_B=$EV_LAST
ev_save daemons-before "EV-PIDS: Xorg, mwm and the three audio daemons before the USB card is removed" \
    gq ctr-pids Xorg,mwm,pipewire,wireplumber,pipewire-pulse >/dev/null || true
V_D_B=$EV_LAST
v_dmn_b=$(pids_of "$(ev_out)" Xorg mwm pipewire wireplumber pipewire-pulse)
gq desk pactl set-default-sink "$u_sink" >/dev/null || fail "pactl set-default-sink $u_sink failed"
snd_set plugged "with the USB card plugged in and the default, before the pod's tone"
snd_keep
ev_video_start usb-leaves
ev_audio_start removal 880
gq journey-tone usb775 880 20 >/dev/null || { audio_capture_stop; fail "could not start the pod's 20 s tone"; }
sleep 4
ev_save streams-before "EV-STATE: the streams with the pod's tone playing, before the USB card is removed" gq streams >/dev/null || true
v_ls=$(ev_out)
v_si=$(sink_inputs "$v_ls")
v_on_usb=no
[ -n "$v_si" ] && [ "$(si_sink "$v_ls" "$v_si")" = "$(sink_idx "$u_sink")" ] && v_on_usb=yes
ev_save sinks-before "EV-STATE: pactl list short sinks before the removal (index, then name)" gq desk pactl list short sinks >/dev/null || true
ev_save player-before "EV-PIDS: the pod's applications before the removal: its player" gq journey-apps >/dev/null || true
v_pl_b=$(awk '$2 == "paplay" {print $1; exit}' <<<"$(ev_out)")
t_unplug=$(gnow)
ev_qemu device-del "EV-QEMU: device_del s774snd under the pod's tone, and QEMU's reply (empty: accepted)" \
    "device_del s774snd" >/dev/null || { audio_capture_stop; fail "QEMU refused device_del s774snd"; }
ev_note "device_del s774snd at $t_unplug (the guest's clock), about 4 s into the pod's 20 s tone"
v_out=""
for _ in $(seq 10); do
    st=$(gq journey-tone-status usb775 2>/dev/null | sed -n 1p || true)
    if [ "${st%% *}" = exited ]; then v_out="ended ($st)"; break; fi
    b_idx=$(sink_idx "$u_builtin")
    if [ -n "$b_idx" ] && [ "$(si_sink "$(gq streams 2>/dev/null || true)" "$v_si")" = "$b_idx" ]; then
        v_out="kept playing, its sink-input $v_si moved to the built-in card's sink $u_builtin"
        break
    fi
    sleep 1
done
ev_note "the pod's stream after the removal: ${v_out:-neither moved nor ended within 10 s}, at $(gnow)"
ev_save streams-after "EV-STATE: the streams after the removal" gq streams >/dev/null || true
ev_save sinks-after "EV-STATE: pactl list short sinks after the removal" gq desk pactl list short sinks >/dev/null || true
snd_set off "after the USB card's removal"
snd_diffs off "the USB card's removal"
tone_wait usb775 journey 30 || ev_note "the pod's tone had not ended 30 s after the removal"
ev_save player "EV-LOG-CLIENT: the pod's player (paplay): its exit status, how long it played and from when to when, its pid, its output" \
    gq journey-tone-status usb775 >/dev/null || true
v_player=$(ev_out)
v_t0=$(awk '/^played/ {print $5}' <<<"$v_player")
m_unplug=$(awk -v k="$t_unplug" -v s="$v_t0" 'BEGIN {if (k != "" && s != "") printf "%.2f", k - s}')
# Moved, the tone must go on (resuming within 1 s, at most 1.5 s of it
# lost); ended, the capture holds it up to the removal, and the next
# playback below is the proof.
v_heard=yes
case $v_out in
    "kept playing"*)
        ev_audio_stop "EV-AUDIO: the machine's output while the journey pod played a 20 s 880 Hz tone on the USB card, the card removed about 4 s in (the red line, timed by the player's clock): the tone must go on from the built-in card" \
            15 0.05 880 --max-gap 1.0 --span 18.5 20.6 ${m_unplug:+--mark "$m_unplug"} || v_heard=no ;;
    *)
        ev_audio_stop "EV-AUDIO: the machine's output while the journey pod played a 20 s 880 Hz tone on the USB card, the card removed about 4 s in (the red line, timed by the player's clock): the stream ended with the card" \
            2 0.05 880 ${m_unplug:+--mark "$m_unplug"} || v_heard=no ;;
esac
ev_video_stop "EV-VIDEO: the display while the USB card leaves under the pod's tone (index.txt and the notes give the times)"
ev_audio_start next 660
gq journey-tone next775 660 3 >/dev/null || { audio_capture_stop; fail "could not start the pod's next tone"; }
tone_wait next775 journey 15 || true
ev_save next-player "EV-LOG-CLIENT: the pod's next player, after the card was gone" gq journey-tone-status next775 >/dev/null || true
v_next=$(ev_out)
v_next_heard=yes
ev_audio_stop "EV-AUDIO: the machine's output while the same pod played its next tone, 660 Hz, after the card was gone - listen for one beep" 2 0.05 660 \
    || v_next_heard=no
ev_save pod-after "EV-PIDS: the journey pod's container after the USB card's removal and its next tone" gq pod-state journey >/dev/null || true
V_POD_A=$EV_LAST
ev_diff pod "EV-DIFF: the journey pod across the card's removal (no differences: the same container, not restarted)" "$V_POD_B" "$V_POD_A"
ev_save daemons-after "EV-PIDS: Xorg, mwm and the three audio daemons after the removal" \
    gq ctr-pids Xorg,mwm,pipewire,wireplumber,pipewire-pulse >/dev/null || true
v_dmn_a=$(pids_of "$(ev_out)" Xorg mwm pipewire wireplumber pipewire-pulse)
ev_diff daemons "EV-DIFF: Xorg, mwm and the audio daemons across the removal (no differences: none restarted)" "$V_D_B" "$EV_LAST"
[ "$v_on_usb" = yes ] || fail "the pod's stream (sink-input ${v_si:-?}) was not on the USB card's sink before the removal"
ev_pass "before the removal the pod's stream, sink-input $v_si, played on the USB card's sink $u_sink"
[ -n "$v_out" ] || fail "10 s after the removal the pod's stream had neither moved to the built-in card nor ended"
case $v_out in
    "kept playing"*)
        ev_pass "within 10 s of the removal the pod's player $v_out"
        grep -q '^exited 0$' <<<"$v_player" || fail "the moved stream's player did not end cleanly: $(echo $v_player)"
        [ "$(awk '/^pid / {print $2}' <<<"$v_player")" = "$v_pl_b" ] || fail "the player is not the one that played before the removal"
        ev_pass "the same player (pid $v_pl_b) played on to its end and exited 0"
        [ "$v_heard" = yes ] || fail "the tone did not go on from the built-in card after the removal (check-audio's verdict says where)"
        ev_pass "the machine's output carried the tone on through the removal: no quiet stretch longer than 1 s, and at most 1.5 s of its 20 s lost" ;;
    *)
        grep -q '^exited [1-9]' <<<"$v_player" || fail "the stream ended with the card, but its player did not report an error: $(echo $v_player)"
        ev_pass "within 10 s of the removal the pod's player $v_out, its error quoted in its record"
        [ "$v_heard" = yes ] || fail "the capture does not hold the tone up to the removal" ;;
esac
grep -q '^exited 0$' <<<"$v_next" || fail "the pod's next player after the removal did not end cleanly: $(echo $v_next)"
[ "$v_next_heard" = yes ] || fail "the pod's next tone after the removal was not heard"
ev_pass "the pod's next playback after the removal, 660 Hz, was heard, and its player exited 0"
[ -n "$v_dmn_b" ] && [ "$v_dmn_b" = "$v_dmn_a" ] || fail "Xorg, mwm or an audio daemon changed: $v_dmn_b -> $v_dmn_a"
ev_pass "Xorg, mwm and the three audio daemons kept their pids ($v_dmn_b)"
pod_same "$V_POD_B" "$V_POD_A" || fail "the journey pod's container changed across the card's removal"
ev_pass "the pod is the same container, restartCount 0"
ev_end
snd_wait_default

cap_card_probe
if [ -z "$cap_model" ]; then
    mkdir -p "$ART/S7.7.7-attempt"
    printf '%s\n' "$cap_probe" > "$ART/S7.7.7-attempt/modinfo.txt"
    log "  no AC97 or ES1370 driver in the guest kernel; S7.7.7's attempt is in S7.7.7-attempt/"
else
    ev_begin S7.7.7 "A client records from a hot-added capture device without restarting" T3
    ev_text modinfo "EV-STATE: modinfo -n for the two candidate drivers on the VM host" "$cap_probe"
    ev_save pod-before "EV-PIDS: the journey pod's container before the capture card arrives" gq pod-state journey >/dev/null || true
    R_POD_B=$EV_LAST
    ev_save daemons-before "EV-PIDS: Xorg, mwm and the three audio daemons before the capture card arrives" \
        gq ctr-pids Xorg,mwm,pipewire,wireplumber,pipewire-pulse >/dev/null || true
    R_D_B=$EV_LAST
    r_dmn_b=$(pids_of "$(ev_out)" Xorg mwm pipewire wireplumber pipewire-pulse)
    snd_set base "before device_add $cap_model"
    snd_keep
    ev_video_start capture-card
    ev_qemu device-add "EV-QEMU: device_add $cap_model,id=s777cap,audiodev=snd0 and QEMU's reply (empty: accepted)" \
        "device_add $cap_model,id=s777cap,audiodev=snd0" >/dev/null || fail "QEMU refused device_add $cap_model"
    r_src=""
    for _ in $(seq 30); do
        r_src=$(comm -13 <(ev_payload "$EV_DIR/$SB_SOURCES" | awk '{print $2}' | sort) \
                         <(gq desk pactl list short sources 2>/dev/null | awk '{print $2}' | sort) | grep '^alsa_input\.' | head -1 || true)
        [ -n "$r_src" ] && break
        sleep 1
    done
    snd_set on "with the $cap_model card plugged in"
    snd_diffs on "the $cap_model card's arrival"
    [ -n "$r_src" ] || fail "no alsa_input source appeared within 30 s of device_add $cap_model"
    ev_pass "the $cap_model card brought a capture source: $r_src"
    rec=$(ev_save recorder "EV-LOG-CLIENT: parecord from $r_src for 3 s, a new process in the journey pod (SIGINT ends it, so the WAV is finished): its command, its output, its exit status and the file" \
        gq journey-rec "$r_src" 3 s777) || true
    rname=$(ev_name rec-in-pod wav)
    vm_ssh_quick 'sudo repo/ci/vm/vm-guest.sh journey-file /tmp/s777.wav' > "$EV_DIR/$rname" 2>/dev/null || true
    [ -s "$EV_DIR/$rname" ] && ev_attach "$rname" "EV-AUDIO-REC: what the pod's parecord recorded from $r_src: silence, which is all QEMU's none backend gives a capture, so its frames are the proof"
    rfacts_ok=yes
    rfacts=$(rec_facts "$EV_DIR/$rname" 2 2>&1) || rfacts_ok=no
    ev_text rec-facts "EV-AUDIO-REC: the recording's frames, duration, format and peak (python's wave module)" "$rfacts"
    snd_keep
    ev_qemu device-del "EV-QEMU: device_del s777cap and QEMU's reply (empty: accepted; the PCI unplug then waits on the guest)" \
        "device_del s777cap" >/dev/null || fail "QEMU refused device_del s777cap"
    r_gone=no
    for _ in $(seq 30); do
        gq desk pactl list short sources 2>/dev/null | awk '{print $2}' | grep -qxF -- "$r_src" || { r_gone=yes; break; }
        sleep 1
    done
    snd_set off "after device_del s777cap"
    snd_diffs off "the $cap_model card's removal"
    ev_video_stop "EV-VIDEO: the display while the capture card arrives and leaves, the journey pod recording from it (index.txt and the notes give the times)"
    ev_save pod-after "EV-PIDS: the journey pod's container after it recorded from the card and the card left" gq pod-state journey >/dev/null || true
    R_POD_A=$EV_LAST
    ev_diff pod "EV-DIFF: the journey pod across the capture card's arrival and removal (no differences: the same container)" "$R_POD_B" "$R_POD_A"
    ev_save daemons-after "EV-PIDS: Xorg, mwm and the three audio daemons after the capture card left" \
        gq ctr-pids Xorg,mwm,pipewire,wireplumber,pipewire-pulse >/dev/null || true
    r_dmn_a=$(pids_of "$(ev_out)" Xorg mwm pipewire wireplumber pipewire-pulse)
    ev_diff daemons "EV-DIFF: Xorg, mwm and the audio daemons across the capture card's arrival and removal (no differences)" "$R_D_B" "$EV_LAST"
    grep -q '^parecord exited 0$' <<<"$rec" || fail "the pod's parecord from $r_src did not exit 0: $(grep '^parecord exited' <<<"$rec")"
    ev_pass "the pod, running since before the card arrived, opened $r_src with parecord, which exited 0"
    [ "$rfacts_ok" = yes ] || fail "the pod's recording from $r_src holds less than 2 s of its 3: $rfacts"
    ev_pass "it delivered frames: $rfacts (silence: all QEMU's none backend gives a capture)"
    [ "$r_gone" = yes ] || fail "the capture source $r_src was still listed 30 s after device_del s777cap"
    [ -n "$r_dmn_b" ] && [ "$r_dmn_b" = "$r_dmn_a" ] || fail "Xorg, mwm or an audio daemon changed: $r_dmn_b -> $r_dmn_a"
    ev_pass "Xorg, mwm and the three audio daemons kept their pids ($r_dmn_b); the card's source left with it"
    pod_same "$R_POD_B" "$R_POD_A" || fail "the journey pod's container changed across the capture card"
    ev_pass "the pod is the same container, restartCount 0"
    ev_end
fi
vm_ssh 'sudo repo/ci/vm/vm-guest.sh journey-cleanup' || true

log "k8s teardown: uninstall the plugin releases; resources withdrawn, host CDI specs and the desktop survive"
guest_ev "$GUEST_EV" verify-teardown \
    || { vm_ssh 'sudo /usr/local/bin/k3s kubectl get deploy,ds,pods -A -o wide; echo ---; sudo /usr/local/bin/k3s kubectl get node -o jsonpath="{.items[0].status.allocatable}"; echo ---; sudo cat /etc/cdi/desktop-display.yaml /etc/cdi/desktop-audio.yaml' \
         2>&1 | tee "$ART/teardown-fail.log" || true; fail "k8s teardown check failed"; }
EV_SIDE=h-
ev_begin S7.3.6 "Teardown seam" T3
ev_shot after-uninstall "EV-SHOT: the desktop after the three plugin releases were uninstalled: the client pod that was running, x11-client-td, still has its xterm on it (bottom left)"
ev_end
EV_SIDE=

# Every screendump this shard measured, the client's capture among them:
# this shard is the one that takes all four S3.5.1 names.
s3_5_1_story

fi # ---- end shard: k8s -----------------------------------------------------------

log "collect guest diagnostics"
vm_ssh 'sudo podman logs desktop 2>&1 | tail -60; echo ---; sudo /usr/local/bin/k3s kubectl get pods -A -o wide 2>/dev/null' \
    > "$ART/guest-final-state.log" 2>&1 || true

log "vm e2e passed (shard: $SHARD)"
