#!/bin/bash
# Host-side orchestration for the Rocky 9 VM e2e test. Boots a KVM guest
# with virtio graphics/input/sound, drives ci/vm/vm-guest.sh over ssh, hot-
# adds an input device mid-test, and captures screendumps of the virtual
# display as artifacts.
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
fail() { echo "FAIL: vm-e2e: $*" >&2; exit 1; }

vm_ssh() {
    ssh -q -p "$SSHPORT" -i id_ed25519 \
        -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        -o ConnectTimeout=10 rocky@127.0.0.1 "$@"
}
mon_cmd() {
    echo "$1" | socat - "UNIX-CONNECT:$MON" >/dev/null
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

log "boot VM (KVM, virtio-vga, virtio input, intel-hda)"
qemu-system-x86_64 \
    -enable-kvm -cpu host -m 6144 -smp 3 \
    -drive "file=$DISK,if=virtio" \
    -drive "file=seed.img,if=virtio,format=raw" \
    -device virtio-vga -display none \
    -device virtio-keyboard-pci -device virtio-tablet-pci \
    -audiodev none,id=snd0 -device intel-hda -device hda-duplex,audiodev=snd0 \
    -netdev "user,id=n0,hostfwd=tcp:127.0.0.1:$SSHPORT-:22" -device virtio-net-pci,netdev=n0 \
    -monitor "unix:$MON,server,nowait" \
    -qmp "unix:$QMP,server,nowait" \
    -serial "file:$ART/serial.log" \
    -daemonize -pidfile qemu.pid

log "wait for ssh"
for _ in $(seq 60); do
    vm_ssh true 2>/dev/null && break
    sleep 5
done
vm_ssh true || fail "VM never became reachable"

log "transfer repo + images"
git -C ../.. archive --format=tar.gz -o "$PWD/repo.tgz" HEAD
scp -q -P "$SSHPORT" -i id_ed25519 -o StrictHostKeyChecking=no \
    -o UserKnownHostsFile=/dev/null repo.tgz images-desktop.tar images-plugin.tar \
    rocky@127.0.0.1:/tmp/

log "phase 1: quadlet flow (real install.sh, real Xorg, SELinux enforcing)"
vm_ssh 'mkdir -p repo && tar -xzf /tmp/repo.tgz -C repo && sudo repo/ci/vm/vm-guest.sh phase1' \
    || { vm_ssh 'sudo journalctl -b --no-pager | tail -150' > "$ART/guest-journal-fail.log" || true; fail "guest phase1 failed"; }
screendump desktop-quadlet
assert_nonblank desktop-quadlet

log "audio: record each client path (pulse, pipewire, ALSA) individually"
# One capture cycle per player so every path is acoustically verified on
# its own - an aggregate capture would let one silent path hide behind
# the others. Each guest call blocks until its 1.5s burst finishes, so
# the capture window brackets it. On failure still stop the capture: the
# partial WAV is a debugging artifact and stopping finalizes its header.
for path in pulse pipewire alsa; do
    audio_capture_start "audio-quadlet-$path"
    vm_ssh "sudo repo/ci/vm/vm-guest.sh play-audio $path" \
        || { audio_capture_stop; fail "guest play-audio $path failed"; }
    audio_capture_stop
    python3 check-audio.py "$ART/audio-quadlet-$path.wav" 1 0.05 \
        || fail "$path audio capture is empty or silent"
done

log "input hotplug: add a virtio keyboard while X runs"
before=$(vm_ssh 'ls /dev/input/event* | wc -l')
mon_cmd "device_add virtio-keyboard-pci,id=hotkbd"
sleep 5
after=$(vm_ssh 'ls /dev/input/event* | wc -l')
[ "$after" -gt "$before" ] || fail "hotplugged keyboard did not appear ($before -> $after)"
vm_ssh 'sudo podman exec desktop sh -c "grep -c \"Adding input device\" /home/desktop/.local/share/xorg/Xorg.0.log"' \
    > "$ART/xorg-input-count.txt" || true

log "input: type into an xterm with the real virtual keyboard, verify the app got it"
# Prove the whole input path (QEMU HID -> evdev -> Xorg -> focused app), not
# just that a device enumerates. A sink xterm runs `read`; we click it to
# focus (mwm is click-to-focus) and type via QMP input-send-event.
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
         > "$ART/input-proof.txt" 2>&1 || true; fail "typed text did not reach the app"; }

log "phase 2: k3s + charts (client pod on the same display)"
vm_ssh 'sudo repo/ci/vm/vm-guest.sh phase2' \
    || { vm_ssh 'sudo journalctl -b --no-pager | tail -150' > "$ART/guest-journal-fail.log" || true; fail "guest phase2 failed"; }
screendump desktop-k3s-client
assert_nonblank desktop-k3s-client

log "plugin: a pod requesting desktop.local/display gets DISPLAY + sockets injected"
# The verifier pod declares no env/mounts of its own, so these assertions
# prove the device plugin's Allocate injection end to end in a live pod.
vm_ssh 'sudo repo/ci/vm/vm-guest.sh verify-plugin' \
    || { vm_ssh 'sudo /usr/local/bin/k3s kubectl describe pod plugin-verify; echo ---; sudo /usr/local/bin/k3s kubectl get pods -o wide' \
         > "$ART/plugin-verify-fail.log" 2>&1 || true; fail "plugin injection verification failed"; }
screendump plugin-verify-window
assert_nonblank plugin-verify-window

log "plugin: each audio path works from the requesting pod (injected env only)"
# One capture per path, played from the verifier pod using only injected
# env - proves the plugin wired pulse/pipewire/ALSA, not the desktop image's
# own local session.
for path in pulse pipewire alsa; do
    audio_capture_start "audio-plugin-$path"
    vm_ssh "sudo repo/ci/vm/vm-guest.sh play-audio-pod $path" \
        || { audio_capture_stop; fail "client pod $path playback failed"; }
    audio_capture_stop
    python3 check-audio.py "$ART/audio-plugin-$path.wav" 1 0.05 \
        || fail "client pod $path audio capture is empty or silent"
done

log "collect guest diagnostics"
vm_ssh 'sudo podman logs desktop 2>&1 | tail -60; echo ---; sudo /usr/local/bin/k3s kubectl get pods -A -o wide' \
    > "$ART/guest-final-state.log" 2>&1 || true

log "vm e2e passed"
