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
    -device virtio-vga,max_outputs=2 -display none \
    -device virtio-keyboard-pci -device virtio-tablet-pci \
    -device qemu-xhci,id=xhci -device usb-kbd,id=kvmkbd,bus=xhci.0 \
    -audiodev none,id=snd0 -device intel-hda -device hda-duplex,audiodev=snd0 \
    -netdev "user,id=n0,hostfwd=tcp:127.0.0.1:$SSHPORT-:22" -device virtio-net-pci,netdev=n0 \
    -monitor "unix:$MON,server,nowait" \
    -qmp "unix:$QMP,server,nowait" \
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
write_manifest
screendump desktop-deploy
assert_nonblank desktop-deploy

# ---- shard: core -------------------------------------------------------------
if in_shard core; then

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

log "input: type into an xterm with the real virtual keyboard, verify the app got it"
# Prove the whole input path (QEMU HID -> evdev -> Xorg -> focused app), not
# just that a device enumerates. A sink xterm runs `read`; we click it to
# focus (mwm is click-to-focus) and type via QMP input-send-event. Runs
# BEFORE the hotplug test: a rootless-X session cannot take a hotplugged
# input device via logind, so the boot-time keyboard is the working one.
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
before_host=$(vm_ssh_quick 'ls /dev/input/event* | wc -l')
read -r before_nodes before_adds <<<"$(hotplug_probe)"
log "  before: host=$before_host container-nodes=$before_nodes xorg-adds=$before_adds"

mon_cmd "device_add virtio-keyboard-pci,id=hotkbd"

after_host=$before_host after_nodes=$before_nodes after_adds=$before_adds
for _ in $(seq 20); do
    after_host=$(vm_ssh_quick 'ls /dev/input/event* | wc -l')
    read -r after_nodes after_adds <<<"$(hotplug_probe)"
    [ "$after_host" -gt "$before_host" ] && [ "$after_nodes" -gt "$before_nodes" ] && break
    sleep 1
done
log "  after:  host=$after_host container-nodes=$after_nodes xorg-adds=$after_adds"

[ "$after_host" -gt "$before_host" ] \
    || fail "hotplugged keyboard never appeared on the VM host ($before_host -> $after_host)"
[ "$after_nodes" -gt "$before_nodes" ] \
    || fail "the new input node never reached the container ($before_nodes -> $after_nodes): the /dev/input bind mount is missing or not live"
# Recorded, not asserted: "Adding input device" is logged when Xorg BEGINS
# handling a device, including ones it then ignores, so an increment is
# suggestive rather than proof that the device works.
log "  note: xorg-adds $before_adds -> $after_adds (log lines, not proof of a working device)"

log "KVM switch simulation: remove the keyboard and bring it back"
# What a USB KVM without HID emulation does on every switch: the devices are
# electrically disconnected from this host and re-enumerated on the way back,
# often at a different eventN. The failure this guards against is not "the new
# device does not work" but "input is dead until desktop.service restarts",
# which is far worse and only shows up on the FIRST switch back.
#
# Asserted on the node counts, in both directions. The removal half matters as
# much as the addition: a stale node that never disappears is exactly what a
# snapshot /dev looks like, and it would let the re-add half pass for the wrong
# reason.
kvm_base_host=$(vm_ssh_quick 'ls /dev/input/event* | wc -l')
read -r kvm_base_nodes _ <<<"$(hotplug_probe)"
log "  base:    host=$kvm_base_host container-nodes=$kvm_base_nodes"

mon_cmd "device_del kvmkbd"
kvm_off_host=$kvm_base_host kvm_off_nodes=$kvm_base_nodes
for _ in $(seq 20); do
    kvm_off_host=$(vm_ssh_quick 'ls /dev/input/event* | wc -l')
    read -r kvm_off_nodes _ <<<"$(hotplug_probe)"
    [ "$kvm_off_host" -lt "$kvm_base_host" ] && [ "$kvm_off_nodes" -lt "$kvm_base_nodes" ] && break
    sleep 1
done
log "  switched away: host=$kvm_off_host container-nodes=$kvm_off_nodes"
[ "$kvm_off_host" -lt "$kvm_base_host" ] \
    || fail "device_del kvmkbd did not remove the node on the VM host ($kvm_base_host -> $kvm_off_host)"
[ "$kvm_off_nodes" -lt "$kvm_base_nodes" ] \
    || fail "the container still sees the removed keyboard ($kvm_base_nodes -> $kvm_off_nodes): its /dev/input is a stale snapshot, so a KVM switch would leave a dead node behind"

# Safe to re-add immediately: USB removal completes without waiting on the
# guest, so the id is free by the time the removal shows up in /dev.
mon_cmd "device_add usb-kbd,id=kvmkbd,bus=xhci.0"
kvm_on_host=$kvm_off_host kvm_on_nodes=$kvm_off_nodes
for _ in $(seq 20); do
    kvm_on_host=$(vm_ssh_quick 'ls /dev/input/event* | wc -l')
    read -r kvm_on_nodes _ <<<"$(hotplug_probe)"
    [ "$kvm_on_host" -ge "$kvm_base_host" ] && [ "$kvm_on_nodes" -ge "$kvm_base_nodes" ] && break
    sleep 1
done
log "  switched back: host=$kvm_on_host container-nodes=$kvm_on_nodes"
[ "$kvm_on_host" -ge "$kvm_base_host" ] \
    || fail "the keyboard never came back on the VM host ($kvm_off_host -> $kvm_on_host)"
[ "$kvm_on_nodes" -ge "$kvm_base_nodes" ] \
    || fail "the re-added keyboard never reached the container ($kvm_off_nodes -> $kvm_on_nodes): a KVM switch would leave input dead until desktop.service restarts"

# Session health after the cycle. NOT proof that the re-added virtio keyboard
# is carrying these keystrokes - QEMU always provides a PS/2 keyboard too, and
# input-send-event goes to whatever the input core has. What it does prove is
# that a remove/re-add cycle did not wedge the X session or its input stack,
# which is the other way a KVM switch could ruin the desktop.
vm_ssh 'sudo repo/ci/vm/vm-guest.sh input-sink-start'
sleep 2
python3 qmp-type.py "$QMP" "$res" 550 395 kvmok
sleep 2
vm_ssh 'sudo repo/ci/vm/vm-guest.sh input-sink-check kvmok' \
    || { vm_ssh 'sudo podman exec desktop cat /tmp/inputproof 2>/dev/null' \
         2>&1 | tee "$ART/input-proof-kvm.txt" || true
         fail "the session stopped accepting input after a remove/re-add cycle"; }
log "  the session still accepts input after a full switch cycle"

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
read -r snd_base_nodes snd_base_devs <<<"$(snd_probe)"
snd_base_host=$(vm_ssh_quick 'ls /dev/snd/controlC* 2>/dev/null | wc -l')
log "  base:      host=$snd_base_host container-nodes=$snd_base_nodes wireplumber-devices=$snd_base_devs"

mon_cmd "device_add usb-audio,id=hotsnd,audiodev=snd0,bus=xhci.0"
snd_on_host=$snd_base_host snd_on_nodes=$snd_base_nodes snd_on_devs=$snd_base_devs
for _ in $(seq 30); do
    snd_on_host=$(vm_ssh_quick 'ls /dev/snd/controlC* 2>/dev/null | wc -l')
    read -r snd_on_nodes snd_on_devs <<<"$(snd_probe)"
    [ "$snd_on_host" -gt "$snd_base_host" ] && [ "$snd_on_nodes" -gt "$snd_base_nodes" ] \
        && [ "$snd_on_devs" -gt "$snd_base_devs" ] && break
    sleep 1
done
log "  plugged in: host=$snd_on_host container-nodes=$snd_on_nodes wireplumber-devices=$snd_on_devs"
[ "$snd_on_host" -gt "$snd_base_host" ] \
    || fail "device_add usb-audio did not create a card on the VM host ($snd_base_host -> $snd_on_host): QEMU never attached it, so nothing below means anything"
[ "$snd_on_nodes" -gt "$snd_base_nodes" ] \
    || fail "the hot-added sound card never reached the container ($snd_base_nodes -> $snd_on_nodes): its /dev/snd is a stale snapshot, so a USB headset plugged in after boot stays invisible until desktop.service restarts"
[ "$snd_on_devs" -gt "$snd_base_devs" ] \
    || fail "the container has the new /dev/snd node but WirePlumber never added a device ($snd_base_devs -> $snd_on_devs): the node arrived and the uevent did not (Network=host), or the session user cannot open it (audio gid alignment)"

mon_cmd "device_del hotsnd"
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
[ "$snd_off_host" -lt "$snd_on_host" ] \
    || fail "device_del hotsnd did not remove the card on the VM host ($snd_on_host -> $snd_off_host)"
[ "$snd_off_nodes" -lt "$snd_on_nodes" ] \
    || fail "the container still sees the removed sound card ($snd_on_nodes -> $snd_off_nodes): its /dev/snd is a stale snapshot, and the add half above passed for the wrong reason"
[ "$snd_off_devs" -le "$snd_base_devs" ] \
    || fail "WirePlumber still lists $snd_off_devs alsa devices after the card was unplugged (baseline $snd_base_devs): the node went away but the graph kept a phantom device"

# Health after the cycle, the audio counterpart of the input-sink check: the
# built-in card must still play. A remove/re-add that wedges WirePlumber is
# the other way this could ruin the desktop.
audio_capture_start "audio-after-hotplug"
vm_ssh 'sudo repo/ci/vm/vm-guest.sh play-audio pulse' \
    || { audio_capture_stop; fail "audio stopped working after a sound-card hotplug cycle"; }
audio_capture_stop
python3 check-audio.py "$ART/audio-after-hotplug.wav" 1 0.05 "$(freq_for pulse)" \
    || fail "audio is silent after a sound-card hotplug cycle"
log "  the built-in card still plays after a full plug/unplug cycle"

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
