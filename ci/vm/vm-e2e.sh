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

log "input hotplug: add a virtio keyboard while X runs"
before=$(vm_ssh 'ls /dev/input/event* | wc -l')
mon_cmd "device_add virtio-keyboard-pci,id=hotkbd"
sleep 5
after=$(vm_ssh 'ls /dev/input/event* | wc -l')
[ "$after" -gt "$before" ] || fail "hotplugged keyboard did not appear ($before -> $after)"
vm_ssh 'sudo podman exec desktop sh -c "grep -c \"Adding input device\" /home/desktop/.local/share/xorg/Xorg.0.log"' \
    > "$ART/xorg-input-count.txt" || true

log "phase 2: k3s + charts (client pod on the same display)"
vm_ssh 'sudo repo/ci/vm/vm-guest.sh phase2' \
    || { vm_ssh 'sudo journalctl -b --no-pager | tail -150' > "$ART/guest-journal-fail.log" || true; fail "guest phase2 failed"; }
screendump desktop-k3s-client

log "collect guest diagnostics"
vm_ssh 'sudo podman logs desktop 2>&1 | tail -60; echo ---; sudo k3s kubectl get pods -A -o wide' \
    > "$ART/guest-final-state.log" 2>&1 || true

log "vm e2e passed"
