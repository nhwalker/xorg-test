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
    [ -z "${EV_VID_PID:-}" ] || kill "$EV_VID_PID" 2>/dev/null || true
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
ev_audio_stop() { # <what> <min seconds> <min peak> <hz>
    audio_capture_stop
    if [ -s "$EV_DIR/$EV_WAV" ]; then ev_attach "$EV_WAV" "$1"; else ev_note "no capture was written for: $1"; fi
    local moment=${EV_WAV%.wav}
    ev_audio_check "${moment#*-}" "$EV_WAV" "$2" "$3" "$4"
}

# EV-AUDIO's verdict and picture for a WAV already in the open story:
# check-audio.py's report and a level plot at the story's pitch (no
# spectrogram tool is installed). Returns check-audio's status.
ev_audio_check() { # <moment> <wav name in the story dir> <min seconds> <min peak> <hz>
    local rep plot rc=0
    if [ -z "$EV_DIR" ]; then
        python3 check-audio.py "$2" "$3" "$4" "$5"
        return
    fi
    rep=$(ev_name "$1-verdict" txt)
    plot=$(ev_name "$1-level" png)
    python3 check-audio.py --report "$EV_DIR/$rep" --plot "$EV_DIR/$plot" "$EV_DIR/$2" "$3" "$4" "$5" || rc=$?
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

# EV-QEMU into the open story: one monitor command and QEMU's reply, through
# QMP (qmp-tool.py). device_add and device_del answer with an empty reply when
# they accept; returns 1 when QEMU says Error.
ev_qemu() { # <moment> <what> <monitor command>
    ev_save "$1" "$2" python3 qmp-tool.py hmp "$QMP" "$3"
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
    ev_attach "$EV_VID/" "EV-VIDEO raw frames at 2 fps; index.txt gives each frame's UTC time, to read against timeline.log"
    if convert -delay 50 -loop 0 "$EV_DIR/$EV_VID"/frame-*.png -resize 50% "$EV_DIR/$EV_VID.gif" 2>/dev/null; then
        ev_attach "$EV_VID.gif" "$1"
    else
        ev_note "the frames in $EV_VID/ could not be assembled into a gif"
    fi
}

# A saved command's output, without ev_save's "$ command" and "[exit N]" lines.
ev_payload() { sed '1d;$d' "$1"; }

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
# S3.9.4: the removed device left xinput list, and Xorg logged its removal.
xi_judge_removed() { # <story> <xinput before> <xinput after> <xorg log> <name>
    local src="$ART/$1" xb xa xl nb na
    ev_copy "$src/$2" xinput-before "EV-STATE: xinput list before the removal (taken in $1)"; xb=$EV_LAST
    ev_copy "$src/$3" xinput-after "EV-STATE: xinput list after the removal, polled until '$5' left or 10 s passed (taken in $1)"; xa=$EV_LAST
    ev_diff xinput "EV-DIFF: xinput list across the removal" "$xb" "$xa"
    ev_copy "$src/$4" xorg-log "EV-LOG-XORG: the Xorg log's lines since just before the removal (taken in $1)"; xl=$EV_LAST
    nb=$(xi_count "$EV_DIR/$xb" "$5")
    na=$(xi_count "$EV_DIR/$xa" "$5")
    [ "$nb" -gt 0 ] || fail "xinput list had no '$5' before the removal, so its leaving would prove nothing"
    [ "$na" -lt "$nb" ] || fail "'$5' did not leave xinput list after the removal ($nb -> $na entries)"
    ev_pass "'$5' left xinput list: $nb -> $na entries"
    grep -qF "removing device $5" "$EV_DIR/$xl" \
        || fail "the Xorg log has no 'removing device $5' since the removal"
    ev_pass "the Xorg log records the removal: $(grep -F "removing device $5" "$EV_DIR/$xl" | head -1 | sed 's/^ *//')"
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
log "boot VM (KVM, virtio-vga with 2 connectors, virtio input, intel-hda)"
qemu-system-x86_64 \
    -enable-kvm -cpu host -m 6144 -smp 3 \
    -drive "file=$DISK,if=virtio" \
    -drive "file=seed.img,if=virtio,format=raw" \
    -device virtio-vga,max_outputs=2,id=vga0 -display none \
    -device virtio-keyboard-pci -device virtio-tablet-pci \
    -device qemu-xhci,id=xhci -device usb-kbd,id=kvmkbd,bus=xhci.0 \
    -audiodev none,id=snd0 -device intel-hda -device hda-duplex,audiodev=snd0 \
    -netdev "user,id=n0,hostfwd=tcp:127.0.0.1:$SSHPORT-:22" -device virtio-net-pci,netdev=n0 \
    -monitor "unix:$MON,server,nowait" \
    -qmp "unix:$QMP,server,nowait" \
    -qmp "unix:$QMPV,server,nowait" \
    -serial "file:$ART/serial.log" \
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
    EV_SIDE=
fi
guest_ev "$pd_ev" layout-restore || fail "fixed monitor layout: the shipped config did not restore autodetection"
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
log "a killed X server leaves a postmortem"
guest_ev "$GUEST_EV" verify-postmortem \
    || fail "postmortem assertions failed"

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

printf 'hotplug-add     host %s -> %s / container-nodes %s -> %s / xorg-adds %s -> %s\n' \
    "$before_host" "$after_host" "$before_nodes" "$after_nodes" "$before_adds" "$after_adds" \
    > "$ART/xorg-input-count.txt"
printf 'kvm-cycle       host %s -> %s -> %s / container-nodes %s -> %s -> %s\n' \
    "$kvm_base_host" "$kvm_off_host" "$kvm_on_host" \
    "$kvm_base_nodes" "$kvm_off_nodes" "$kvm_on_nodes" >> "$ART/xorg-input-count.txt"

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
vm_ssh 'sudo repo/ci/vm/vm-guest.sh phase2' \
    || { vm_ssh 'sudo journalctl -b --no-pager | tail -150' 2>&1 | tee "$ART/guest-journal-fail.log" || true; fail "guest phase2 failed"; }
screendump desktop-k3s-client
assert_nonblank desktop-k3s-client

log "cdi: a requesting pod gets DISPLAY + sockets injected by the runtime"
# The verifier pod declares no env/mounts of its own and an identical pod
# WITHOUT the resource request is checked to get nothing, so these
# assertions prove the plugin -> CRI-O CDI path end to end in a live pod.
vm_ssh 'sudo repo/ci/vm/vm-guest.sh verify-cdi' \
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

log "cdi: each audio path works from the requesting pod (injected env only)"
# One capture per path, played from the verifier pod using only injected
# env - proves the CDI spec wired pulse/pipewire/ALSA, not the desktop
# image's own local session.
for path in pulse pipewire alsa; do
    audio_capture_start "audio-cdi-$path"
    vm_ssh "sudo repo/ci/vm/vm-guest.sh play-audio-pod $path" \
        || { audio_capture_stop; fail "client pod $path playback failed"; }
    audio_capture_stop
    python3 check-audio.py "$ART/audio-cdi-$path.wav" 1 0.05 "$(freq_for "$path")" \
        || fail "client pod $path audio capture is empty or silent"
done

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
EV_SIDE=

log "k8s teardown: uninstall the plugin releases; resources withdrawn, host CDI specs and the desktop survive"
vm_ssh 'sudo repo/ci/vm/vm-guest.sh verify-teardown' \
    || { vm_ssh 'sudo /usr/local/bin/k3s kubectl get deploy,ds,pods -A -o wide; echo ---; sudo /usr/local/bin/k3s kubectl get node -o jsonpath="{.items[0].status.allocatable}"; echo ---; sudo cat /etc/cdi/desktop-display.yaml /etc/cdi/desktop-audio.yaml' \
         2>&1 | tee "$ART/teardown-fail.log" || true; fail "k8s teardown check failed"; }

# Every screendump this shard measured, the client's capture among them:
# this shard is the one that takes all four S3.5.1 names.
s3_5_1_story

fi # ---- end shard: k8s -----------------------------------------------------------

log "collect guest diagnostics"
vm_ssh 'sudo podman logs desktop 2>&1 | tail -60; echo ---; sudo /usr/local/bin/k3s kubectl get pods -A -o wide 2>/dev/null' \
    > "$ART/guest-final-state.log" 2>&1 || true

log "vm e2e passed (shard: $SHARD)"
