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

log()  { echo "== vm-e2e: $*"; }
# Pitch each audio path plays (must match gen_tone in vm-guest.sh), so the
# capture check can confirm the RIGHT tone came through, not just some sound.
freq_for() { case "$1" in pulse) echo 440;; pipewire) echo 880;; alsa) echo 1320;; *) echo 0;; esac; }
fail() { echo "FAIL: vm-e2e: $*" >&2; exit 1; }

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
# hotplug_probe echoes "<container input nodes> <Xorg input adds>", always as
# two integers. Defaults to "0 0" rather than letting an ssh hiccup produce an
# empty string that the arithmetic comparisons below would choke on.
hotplug_probe() {
    local out nodes adds
    out=$(vm_ssh_quick 'sudo repo/ci/vm/vm-guest.sh hotplug-probe' 2>/dev/null || true)
    read -r nodes adds <<<"$out"
    echo "${nodes:-0} ${adds:-0}"
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
    # A live X server that is drawing nothing produces a solid frame; the
    # grayscale standard deviation collapses to ~0. Real content (the mwm
    # root stipple + a window) is well above the threshold. This turns the
    # screendump from a human-eyeball artifact into a pass/fail signal.
    local f="$ART/$1.png" sd
    [ -s "$f" ] || f="$ART/$1.ppm"
    [ -s "$f" ] || fail "screendump $1 was not produced"
    sd=$(convert "$f" -colorspace Gray -format '%[fx:standard_deviation]' info: 2>/dev/null) \
        || fail "could not analyze screendump $1 (imagemagick missing?)"
    awk "BEGIN{ exit !($sd > 0.02) }" \
        || fail "screendump $1 is blank/near-uniform (grayscale stddev=$sd); X is up but rendering nothing"
    log "render: $1 is non-blank (grayscale stddev=$sd)"
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
    log "region: $(basename "$2") is exactly $3 of the full capture"
}

# assert_orientation_vs_reference cross-checks the capture against QEMU's own
# screendump of the same display - a completely independent capture path (the
# emulator reading its framebuffer vs. our X11 GetImage).
#
# Scored by margin, not by an absolute threshold: QEMU composites the pointer
# cursor, which GetImage never returns, so the identity comparison is close to
# but not exactly zero. What must hold is that it beats every flipped, mirrored
# and rotated variant by a wide margin.
assert_orientation_vs_reference() { # $1: capture; $2: reference screendump basename
    local ref="$ART/$2.png"
    [ -s "$ref" ] || ref="$ART/$2.ppm"
    [ -s "$ref" ] || { log "WARNING: no reference screendump $2; skipping the cross-check"; return 0; }
    local cap_geom ref_geom
    cap_geom=$(identify -format '%wx%h' "$1") || fail "could not read the size of $1"
    ref_geom=$(identify -format '%wx%h' "$ref") || fail "could not read the size of $ref"
    if [ "$cap_geom" != "$ref_geom" ]; then
        log "WARNING: capture is $cap_geom but the reference screendump is $ref_geom; skipping the cross-check"
        return 0
    fi
    local s0 s1 s2 s3
    s0=$(rmse "$1" "$ref" "")           || fail "could not score the capture against the reference screendump"
    s1=$(rmse "$1" "$ref" "-flip")      || fail "could not score the capture against the flipped screendump"
    s2=$(rmse "$1" "$ref" "-flop")      || fail "could not score the capture against the mirrored screendump"
    s3=$(rmse "$1" "$ref" "-rotate 180") || fail "could not score the capture against the rotated screendump"
    rm -f "$ART/.ref.png"
    awk -v s0="$s0" -v s1="$s1" -v s2="$s2" -v s3="$s3" '
        BEGIN {
            worst = s1; if (s2 < worst) worst = s2; if (s3 < worst) worst = s3;
            printf "identity=%.6f flipped=%.6f mirrored=%.6f rotated=%.6f\n", s0, s1, s2, s3;
            exit !(s0 < 0.25 * worst);
        }' \
        || fail "the capture matches a flipped/mirrored/rotated QEMU screendump about as well as the upright one: it is not oriented like the real screen"
    log "orientation: the capture matches QEMU's own screendump far better than any flipped variant"
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
vm_ssh 'mkdir -p repo && tar -xzf /tmp/repo.tgz -C repo && sudo repo/ci/vm/vm-guest.sh phase-deploy' \
    || { vm_ssh 'sudo journalctl -b --no-pager | tail -150; echo ---; sudo ausearch -m avc -ts recent 2>/dev/null | tail -40' \
         2>&1 | tee "$ART/guest-deploy-fail.log" || true; fail "guest phase-deploy failed"; }
screendump desktop-deploy
assert_nonblank desktop-deploy

log "privileges: the desktop container runs with less than --privileged"
vm_ssh 'sudo repo/ci/vm/vm-guest.sh verify-privileges' \
    || { vm_ssh 'sudo podman inspect desktop --format "{{.HostConfig.Privileged}} {{.HostConfig.CapAdd}}"; sudo podman exec desktop grep -E "^(Cap|Seccomp)" /proc/1/status' \
         2>&1 | tee "$ART/privileges-fail.log" || true; fail "privilege assertions failed"; }

log "audio: record each client path (pulse, pipewire, ALSA) individually"
# One capture cycle per player so every path is acoustically verified on
# its own - an aggregate capture would let one silent path hide behind
# the others. Each guest call blocks until its 1.5s burst finishes, so
# the capture window brackets it. On failure still stop the capture: the
# partial WAV is a debugging artifact and stopping finalizes its header.
for path in pulse pipewire alsa; do
    audio_capture_start "audio-deploy-$path"
    vm_ssh "sudo repo/ci/vm/vm-guest.sh play-audio $path" \
        || { audio_capture_stop; fail "guest play-audio $path failed"; }
    audio_capture_stop
    python3 check-audio.py "$ART/audio-deploy-$path.wav" 1 0.05 "$(freq_for "$path")" \
        || fail "$path audio capture is empty or silent"
done

log "input: type into an xterm with the real virtual keyboard, verify the app got it"
# Prove the whole input path (QEMU HID -> evdev -> Xorg -> focused app), not
# just that a device enumerates. A sink xterm runs `read`; we click it to
# focus (mwm is click-to-focus) and type via QMP input-send-event. Runs
# BEFORE the hotplug test: a rootless-X session cannot take a hotplugged
# input device via logind, so the boot-time keyboard is the working one.
res=$(vm_ssh 'sudo podman exec -u desktop -e DISPLAY=:0 desktop \
    sh -c "xdpyinfo | awk \"/dimensions:/{print \\\$2; exit}\""')
[ -n "$res" ] || fail "could not read display resolution for input injection"
vm_ssh 'sudo repo/ci/vm/vm-guest.sh input-sink-start'
sleep 2
# Click + type at the centre of the sink window (geometry 100x30+250+200).
python3 qmp-type.py "$QMP" "$res" 550 395 inputok
sleep 2
screendump input-typed
vm_ssh 'sudo repo/ci/vm/vm-guest.sh input-sink-check inputok' \
    || { vm_ssh 'sudo podman exec desktop cat /tmp/inputproof 2>/dev/null' \
         2>&1 | tee "$ART/input-proof.txt" || true; fail "typed text did not reach the app"; }

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
vm_ssh 'sudo repo/ci/vm/vm-guest.sh verify-split' \
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
# plays and confirm the recording carries it. Checked inside the VM.
vm_ssh 'sudo repo/ci/vm/vm-guest.sh verify-record' \
    || { vm_ssh 'sudo /usr/local/bin/k3s kubectl exec cdi-verify -- sh -c "pactl info; pactl list short sources"' \
         2>&1 | tee "$ART/record-fail.log" || true; fail "audio record-direction check failed"; }

log "cdi: a LEAN non-desktop image works with only the injected env/mounts"
# Proves the CDI contract holds for an ordinary app container (no Xorg
# server, pipewire daemon, session or WM), not just the desktop image.
vm_ssh 'sudo repo/ci/vm/vm-guest.sh verify-testclient' \
    || { vm_ssh 'sudo /usr/local/bin/k3s kubectl describe pod x11-testclient' \
         2>&1 | tee "$ART/testclient-fail.log" || true; fail "lean client display check failed"; }
for path in pulse pipewire alsa; do
    audio_capture_start "audio-testclient-$path"
    vm_ssh "sudo repo/ci/vm/vm-guest.sh play-audio-pod $path x11-testclient" \
        || { audio_capture_stop; fail "lean client $path playback failed"; }
    audio_capture_stop
    python3 check-audio.py "$ART/audio-testclient-$path.wav" 1 0.05 "$(freq_for "$path")" \
        || fail "lean client $path audio capture is empty or silent"
done

log "screenshot: the injected binary captures the live display from a client pod"
# The lean client image carries the screenshot binary and no other X client
# stack, so the display it captures can only come from desktop.local/display.
#
# A known pattern goes up first and everything below is checked against it.
# Size and "not blank" alone would pass a capture that is upside down,
# mirrored, red/blue swapped or shifted; the pattern is what turns this from
# "it produced a PNG" into "it produced THE SCREEN".
vm_ssh 'sudo repo/ci/vm/vm-guest.sh screenshot-pattern-start' \
    || { vm_ssh 'sudo /usr/local/bin/k3s kubectl describe pod testpattern; echo ---; sudo /usr/local/bin/k3s kubectl logs testpattern' \
         2>&1 | tee "$ART/screenshot-pattern-fail.log" || true; fail "could not paint the test pattern"; }
# QEMU's own view of the same display, taken while the pattern is up: an
# independent capture path to cross-check orientation against.
screendump screenshot-reference
vm_ssh 'sudo repo/ci/vm/vm-guest.sh verify-screenshot' \
    || { vm_ssh 'sudo /usr/local/bin/k3s kubectl describe pod x11-testclient; echo ---; sudo cat /etc/cdi/desktop-display.yaml' \
         2>&1 | tee "$ART/screenshot-fail.log" || true; fail "screenshot capture check failed"; }
vm_ssh 'sudo tar -C /tmp/screenshots -cf - .' | tar -C "$ART" -xf - \
    || fail "could not retrieve the captured screenshots from the VM"
# Down again before the concurrency phase screendumps the display.
vm_ssh 'sudo repo/ci/vm/vm-guest.sh screenshot-pattern-stop' || true

for f in full full-stdout region tl straddle odd hw; do
    [ -s "$ART/$f.png" ] || fail "screenshot artifact $f.png was not retrieved"
    mv "$ART/$f.png" "$ART/screenshot-$f.png"
done
SS_GEOM=$(cat "$ART/geometry.txt")
rm -f "$ART/geometry.txt"
SS_W=${SS_GEOM%x*}
SS_H=${SS_GEOM#*x}
[ "$(identify -format '%wx%h' "$ART/screenshot-full.png")" = "$SS_GEOM" ] \
    || fail "the full capture is not the $SS_GEOM the client pod reported"

# 1. the capture shows the pattern, in the right colours at the right places
assert_pattern "$ART/screenshot-full.png" "$SS_W" "$SS_H"
# 2. stdout mode and file mode are the same bytes for the same static screen
[ "$(compare -metric AE "$ART/screenshot-full.png" "$ART/screenshot-full-stdout.png" null: 2>&1 || true)" = 0 ] \
    || fail "--to-stdout and file mode produced different images of the same static screen"
# 3. every region is exactly the corresponding crop of the full capture
assert_same "$ART/screenshot-full.png" "$ART/screenshot-region.png"   200x100+10+20
assert_same "$ART/screenshot-full.png" "$ART/screenshot-tl.png"       64x64+0+0
assert_same "$ART/screenshot-full.png" "$ART/screenshot-straddle.png" 8x8+60+60
assert_same "$ART/screenshot-full.png" "$ART/screenshot-odd.png"      199x40+290+0
assert_same "$ART/screenshot-full.png" "$ART/screenshot-hw.png"       160x120+0+0
# 4. the top-left region lands exactly on the pattern's flat red block, so a
#    region origin off by even one pixel shows up as a second colour
[ "$(identify -format '%k' "$ART/screenshot-tl.png")" = 1 ] \
    || fail "the 64x64+0+0 region is not a single flat colour: its origin is off"
assert_px "$ART/screenshot-tl.png" 0 0 255,0,0 "top-left region origin"
assert_px "$ART/screenshot-tl.png" 63 63 255,0,0 "top-left region far corner"
# 5. cross-check orientation against QEMU's own framebuffer dump
assert_orientation_vs_reference "$ART/screenshot-full.png" screenshot-reference
assert_nonblank screenshot-full

log "cdi: concurrent clients share one display"
# Three requesting pods open the display, and two of them re-open it while
# the third holds a connection. Proves the shareable-device concurrency the
# advertised count is there to permit.
vm_ssh 'sudo repo/ci/vm/vm-guest.sh verify-concurrency' \
    || { vm_ssh 'sudo /usr/local/bin/k3s kubectl get pods -o wide; echo ---; sudo /usr/local/bin/k3s kubectl describe pod x11-client-c' \
         2>&1 | tee "$ART/verify-concurrency-fail.log" || true; fail "concurrency check failed"; }
screendump concurrent-clients

log "k8s teardown: uninstall the plugin releases; resources withdrawn, host CDI specs and the desktop survive"
vm_ssh 'sudo repo/ci/vm/vm-guest.sh verify-teardown' \
    || { vm_ssh 'sudo /usr/local/bin/k3s kubectl get deploy,ds,pods -A -o wide; echo ---; sudo /usr/local/bin/k3s kubectl get node -o jsonpath="{.items[0].status.allocatable}"; echo ---; sudo cat /etc/cdi/desktop-display.yaml /etc/cdi/desktop-audio.yaml' \
         2>&1 | tee "$ART/teardown-fail.log" || true; fail "k8s teardown check failed"; }

log "collect guest diagnostics"
vm_ssh 'sudo podman logs desktop 2>&1 | tail -60; echo ---; sudo /usr/local/bin/k3s kubectl get pods -A -o wide' \
    > "$ART/guest-final-state.log" 2>&1 || true

log "vm e2e passed"
