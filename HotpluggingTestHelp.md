# Hotplug testing guide: keyboards, pointers, monitors and audio

**BLUF.** Every HMI device class this desktop cares about can be hot-plugged
*and* hot-unplugged in the existing QEMU/KVM e2e, with one honest exception
(a monitor physically *appearing* is staged through the kernel's DRM
connector-force interface rather than through QEMU, because a headless QEMU
never enables a second scanout). Audio hotplug in particular is **not** blocked
by QEMU: `ci/vm/vm-e2e.sh` already adds and removes a USB sound card under the
running desktop and asserts the result at three layers, down to WirePlumber's
device list. This document records how each class is staged, what to observe
at every layer, how to prove the device *works* and not merely *exists*, what
a VM cannot stage, and the exact procedure for the hardware half.

It is the companion to `Requirements.md` features **F3.9** (keyboards and
pointers), **F3.10** (monitors), **F3.11** (KVM composite) and **F4.7**
(audio). Story IDs below refer to that file.

---

## 1. The model: four layers, four different failures

A hotplug event has to cross four boundaries before a user would call it
"working". Each one fails for a different reason and is probed separately;
reporting only the last one cannot tell them apart.

| Layer | What must happen | What makes it happen here | What it looks like when broken |
|---|---|---|---|
| **1. Emulator / hardware** | the device is attached to or detached from the machine | `device_add` / `device_del` over the QEMU monitor, or a physical cable | QEMU refuses the command, or `info usb` / `info pci` does not list it |
| **2. Guest kernel + udev** | a device node appears or disappears on the **host** (`/dev/input/event*`, `/dev/snd/controlC*`), and a uevent is emitted | the guest kernel's driver + host `udevd` | node count on the VM host does not change; `udevadm monitor` is silent |
| **3. Container `/dev` and uevent delivery** | the node appears or disappears **inside the container**, and the uevent reaches the container's listeners | `Volume=/dev/input:/dev/input` and `Volume=/dev/snd:/dev/snd` (live bind mounts, not `AddDevice=` snapshots); `Network=host` (netlink uevents are per-netns); `Volume=/run/udev:/run/udev:ro` (udev db); device-cgroup rules for majors 13 and 116; `align-device-groups.sh` (numeric gids) | node count inside the container does not change; a removed node stays (snapshot `/dev`); node present but consumer never notices (uevent lost); node present but not openable (gid) |
| **4. Consumer** | Xorg/libinput opens or closes the input device; WirePlumber creates or destroys the ALSA device; Xorg re-probes the connector | the consumers' own udev monitoring | `xinput list` / Xorg log / `pw-cli ls Device` / `xrandr` do not reflect the change |

The quadlet comments and `README.md` ("Input and audio hotplug, and KVM
switches") explain *why* each layer-3 piece exists. The point for testing is
that **every assertion must name its layer**, and that plug-**out** must be
asserted as carefully as plug-**in**: a stale node that never disappears is
exactly what a snapshot `/dev` looks like, and it lets the re-add half pass for
the wrong reason.

---

## 2. The rig

### 2.1 The VM

`ci/vm/vm-e2e.sh` boots:

```sh
qemu-system-x86_64 \
    -enable-kvm -cpu host -m 6144 -smp 3 \
    -drive "file=$DISK,if=virtio" -drive "file=seed.img,if=virtio,format=raw" \
    -device virtio-vga,max_outputs=2 -display none \
    -device virtio-keyboard-pci -device virtio-tablet-pci \
    -device qemu-xhci,id=xhci -device usb-kbd,id=kvmkbd,bus=xhci.0 \
    -audiodev none,id=snd0 -device intel-hda -device hda-duplex,audiodev=snd0 \
    -netdev "user,id=n0,hostfwd=tcp:127.0.0.1:$SSHPORT-:22" -device virtio-net-pci,netdev=n0 \
    -monitor "unix:$MON,server,nowait" -qmp "unix:$QMP,server,nowait" \
    -serial "file:$ART/serial.log" -daemonize -pidfile qemu.pid
```

The parts that matter for hotplug:

- **`-device qemu-xhci,id=xhci`** — a USB 3 controller. Every USB hot-add names
  `bus=xhci.0`. Without a controller there is nothing to plug into.
- **`usb-kbd,id=kvmkbd`** — the keyboard the KVM-switch simulation removes and
  re-adds. The `id` is what `device_del` takes.
- **`virtio-keyboard-pci` / `virtio-tablet-pci`** — permanent input devices.
  They keep the guest typeable and clickable during USB cycles. QEMU sends
  unrouted key events to the keyboard it activated last: a newly added USB
  keyboard activates itself, a virtio keyboard activates when its guest driver
  starts. So after the KVM cycle the typing does go through the re-added
  `kvmkbd`, and Xorg must have opened it; what the check lacks is any record of
  that (§4.1.4).
- **`-audiodev none,id=snd0`** — the audio backend. It renders nothing, but
  QEMU's `wavcapture` taps the backend's mixing engine regardless, so anything
  played by *any* device attached to `snd0` can be captured and analysed.
- **`intel-hda` + `hda-duplex`** — the built-in, boot-time sound card (playback
  and capture).
- **`virtio-vga,max_outputs=2`** — two DRM connectors, `Virtual-1` (connected)
  and `Virtual-2` (permanently disconnected under `-display none`). §4.3
  explains why that is both a limitation and a gift.
- Default machine type (i440fx). PCI hot-add via `device_add` works there
  (ACPI PCI hotplug); PCI hot-*remove* asks the guest to eject and waits for an
  acknowledgement a busy device may never send. USB removal is immediate and
  needs no guest cooperation — exactly like yanking a cable.

### 2.2 Driving QEMU

Two sockets, two jobs:

- **HMP monitor** (`mon.sock`): `device_add`, `device_del`, `screendump`,
  `wavcapture`, `stopcapture`, `info usb`, `info pci`, `info qtree`.
  `vm-e2e.sh` wraps it as `mon_cmd "<command>"` via `socat`. Interactively:
  `socat - UNIX-CONNECT:mon.sock`.
- **QMP** (`qmp.sock`): `input-send-event`, used by `ci/vm/qmp-type.py` to
  inject real HID events (absolute pointer position, button, key qcodes).
  Interactively: `socat - UNIX-CONNECT:qmp.sock`, send
  `{"execute":"qmp_capabilities"}` first.

### 2.3 Probes

`ci/vm/vm-guest.sh` runs inside the VM (as root) and exposes probes the host
diffs before and after a QEMU action. Each prints **two integers on one line**,
defaulting to `0` on any error so arithmetic on the host cannot crash:

| Probe | Prints | Layer 3 | Layer 4 |
|---|---|---|---|
| `hotplug-probe` | `<container input nodes> <Xorg "Adding input device" lines>` | `ls /dev/input/event*` inside the container | `grep -c 'Adding input device'` in `/home/desktop/.local/share/xorg/Xorg.0.log` |
| `snd-probe` | `<container controlC nodes> <WirePlumber alsa_card devices>` | `ls /dev/snd/controlC*` inside the container | `pw-cli ls Device \| grep -c 'device.name = "alsa_card'` as the session user with `XDG_RUNTIME_DIR=/run/user/61000` |

Layer 2 is read directly on the VM host (`ls /dev/input/event* | wc -l`,
`ls /dev/snd/controlC* | wc -l`).

Two conventions that have bitten before, from `vm-guest.sh`'s header:

- `podman exec` inherits the container **init's** environment, not the
  session's. Any probe that talks to X or PipeWire needs `-u desktop` plus
  explicit `-e DISPLAY=:0`, `-e HOME=/home/desktop`,
  `-e XDG_RUNTIME_DIR=/run/user/61000`.
- Never `podman exec … | grep -q` under `set -o pipefail`: the early-exiting
  grep SIGPIPEs the producer and a passing check reports exit 141. Capture to
  a variable, then match.

### 2.4 Polling discipline

Every post-action check is a bounded poll (20–30 iterations, 1 s apart) that
reads **all** the relevant counters each iteration and breaks when all have
moved. After the loop, each counter is asserted individually with a message
naming the layer. Log lines (Xorg log, `podman logs`) lag live state by
seconds; process/socket/node state does not.

### 2.5 Artifacts

Counters are written to `ci/vm/artifacts/xorg-input-count.txt`; WAV captures
and PNG screendumps land next to it. The job uploads the directory even on
failure.

### 2.6 Running it yourself

```sh
# host prerequisites: /dev/kvm access, qemu-system-x86, qemu-utils,
# cloud-image-utils, socat, imagemagick, python3
sudo podman login ghcr.io …                      # optional base cache
REGISTRY=ghcr.io/<owner> PUSH_BASES=0 sudo -E ci/build-bases.sh
sudo podman build --network=none -t localhost/screenshot:latest -f Containerfile.screenshot .
sudo podman build --network=none -t localhost/desktop-container:latest -f Containerfile .
sudo podman build --network=none -t localhost/cdi-device-plugin:latest -f Containerfile.plugin .
sudo podman build -t localhost/desktop-testclient:latest -f Containerfile.testclient .
for t in desktop-container cdi-device-plugin desktop-testclient; do
  sudo podman save -o ci/vm/images-${t%%-*}.tar localhost/$t:latest   # names: images-desktop/plugin/testclient.tar
done
curl -fL -o ci/vm/Rocky-9-GenericCloud.qcow2 \
  https://dl.rockylinux.org/pub/rocky/9/images/x86_64/Rocky-9-GenericCloud-Base.latest.x86_64.qcow2
ci/vm/vm-e2e.sh
```

(Check `e2e-vm.yml` for the exact `podman save` file names; the loop above is
illustrative.) To explore by hand, copy the `qemu-system-x86_64` line out of
`vm-e2e.sh`, drop `-daemonize` if you want it in the foreground, then drive
`mon.sock` with `socat` while `ssh -p 2222 rocky@127.0.0.1` watches the guest.

---

## 3. Tooling the probes need and do not yet have

| Need | Why | Where to add it |
|---|---|---|
| `xinput` | the only clean way to list X input devices by name and to stream events from **one specific device** (`xinput test <id>`); replaces counting `Adding input device` log lines, which also fire for devices Xorg then ignores | `Containerfile.testclient` (CI-only, networked build; run it as a podman client with `--device desktop.local/display=all` in phase-deploy, or from the `x11-testclient` pod in phase 2). Adding it to `Containerfile.base` also works but forces a base rebuild. |
| `xev` | optional: root-window event stream for pointer motion | same |
| `pw-cli`, `wpctl`, `pactl`, `pw-play`, `paplay`, `parec`, `aplay`, `arecord` | already in the desktop image and in the testclient | — |
| `alsa-utils` + `alsa-plugins-pulseaudio` on the VM **host** | host-side ALSA probes (Requirements S4.2.2); not hotplug-specific | `vm-guest.sh phase_deploy` dnf line |

Package names on Rocky 9 AppStream: `xinput`, `xev` (split out of the old
`xorg-x11-utils`; confirm with `dnf provides '*/xinput'` on first use).

---

## 4. Per device class

### 4.1 Keyboards

#### 4.1.1 Devices QEMU offers

| QEMU device | Bus | Hot-add | Hot-remove | Notes |
|---|---|---|---|---|
| `usb-kbd` | `bus=xhci.0` | `device_add usb-kbd,id=<id>,bus=xhci.0` | `device_del <id>` — immediate | **the KVM-switch model**: USB is what a KVM switches, and removal needs no guest ACK |
| `virtio-keyboard-pci` | PCI | `device_add virtio-keyboard-pci,id=<id>` | `device_del <id>` — waits for guest ACPI eject; may hang on a busy device | used today for the plain hot-add test |
| PS/2 (i8042) | — | always present | never | always there, but QEMU never makes it the active keyboard while another exists, so it does not carry the typing in this rig |

#### 4.1.2 What the e2e does today

```sh
# plain hot-add (PCI)
mon_cmd "device_add virtio-keyboard-pci,id=hotkbd"
# KVM-style cycle (USB), both directions
mon_cmd "device_del kvmkbd"
mon_cmd "device_add usb-kbd,id=kvmkbd,bus=xhci.0"
```

Asserted: host node count (layer 2), container node count (layer 3), in both
directions for the USB cycle; then a click+type into a sink xterm proves the
session still accepts input. Because QEMU routes keys to the newest keyboard,
that typing goes through the re-added `kvmkbd`, but nothing records it.
Recorded but not asserted: the Xorg `Adding input device` count (layer 4).

#### 4.1.3 Observing each layer

```sh
# layer 1
echo 'info usb'   | socat - UNIX-CONNECT:mon.sock       # "Device 0.2, Port 1, …, Product QEMU USB Keyboard"
# layer 2 (VM host)
ls -l /dev/input/by-id/ /dev/input/event*
udevadm monitor --udev --subsystem-match=input          # run before the device_add; shows add/remove
cat /proc/bus/input/devices                              # N: Name="QEMU QEMU USB Keyboard"
# layer 3 (container)
sudo podman exec desktop ls -l /dev/input/
# layer 4 (Xorg)
sudo podman exec desktop grep -E 'Adding input device|removing device|XINPUT: Adding' \
    /home/desktop/.local/share/xorg/Xorg.0.log
sudo podman run --rm --device desktop.local/display=all localhost/desktop-testclient xinput list
```

Removal in the Xorg log looks like:

```
(II) config/udev: removing device QEMU QEMU USB Keyboard
(II) event5  - QEMU QEMU USB Keyboard: device removed
(II) UnloadModule: "libinput"
```

#### 4.1.4 Proving the hot-added keyboard itself carries keystrokes (S3.9.5)

`input-send-event`'s optional `"device"` names a **display** device, not an
input device: `"device":"kvmkbd"` is refused ("not bound to a QemuConsole").
To aim events at one input device, create it bound to the display —
`usb-kbd`, `usb-tablet` and virtio-input take `display=<id>` — and send with
`"device"` set to that display's id; a bound device takes precedence over the
unbound ones. That needs an `id=` on the e2e's `-device virtio-vga`:

```json
{"execute":"device_add","arguments":{"driver":"usb-kbd","id":"kvmkbd","bus":"xhci.0","display":"vga0"}}
{"execute":"input-send-event","arguments":{"device":"vga0","events":[
  {"type":"key","data":{"key":{"type":"qcode","data":"k"},"down":true}},
  {"type":"key","data":{"key":{"type":"qcode","data":"k"},"down":false}}]}}
```

Extend `ci/vm/qmp-type.py` with an optional `--device <display id>` argument
that adds that field to the command. Then, after the re-add, type `kvmdev`
through `kvmkbd` and read it back from the sink xterm — or run
`xinput test <id-of-"QEMU QEMU USB Keyboard">` in the background from the
testclient and assert `key press`/`key release` lines appear.

#### 4.1.5 Gotchas

- The `id` must be free before re-adding. USB `device_del` frees it at once;
  PCI `device_del` frees it only after the guest ejects, so re-adding a PCI
  device under the same id can fail with "Duplicate device ID".
- `Adding input device` is logged when Xorg *begins* handling a device,
  including ones it then declines; it is an upper bound, not adoption. Use
  `xinput list` for adoption.
- libinput may log `event7 - QEMU QEMU USB Keyboard: is tagged by udev as:
  Keyboard` only when `/run/udev` is mounted and non-empty in the container
  (that is the udev-database bind mount; container preflight checks it).

### 4.2 Pointers (mice, tablets, touch)

#### 4.2.1 Devices QEMU offers

| QEMU device | Reports | Hot-add | Hot-remove |
|---|---|---|---|
| `usb-mouse` | relative motion + buttons | `device_add usb-mouse,id=hotmouse,bus=xhci.0` | immediate |
| `usb-tablet` | absolute position + buttons | `device_add usb-tablet,id=hottab,bus=xhci.0` | immediate |
| `virtio-mouse-pci` | relative | `device_add virtio-mouse-pci,id=…` | guest ACK |
| `virtio-tablet-pci` | absolute (the boot-time pointer) | `device_add virtio-tablet-pci,id=…` | guest ACK |

Nothing hot-plugs a pointer today (S3.9.7–S3.9.11 are all ❌). Both a relative
and an absolute device should be exercised: libinput configures them
differently (acceleration vs. calibration matrix) and a KVM may present either.

#### 4.2.2 Observing

Same four layers as the keyboard. Names in `/proc/bus/input/devices` and
`xinput list`: `QEMU QEMU USB Mouse`, `QEMU QEMU USB Tablet`.

#### 4.2.3 Proving the hot-added pointer works (S3.9.11)

- **Relative** (`usb-mouse`): it has no `display` property, so it cannot be
  aimed at with `"device"`. Make it QEMU's current mouse with HMP
  `mouse_set <index>` (indexes from `query-mice`, which then shows it current),
  send `{"type":"rel","data":{"axis":"x","value":40}}`, and assert motion
  lines from `xinput test <id>`.
- **Absolute** (`usb-tablet`): `{"type":"abs","data":{"axis":"x","value":N}}`
  (0..32767 across the screen, as `qmp-type.py` computes) plus
  `{"type":"btn","data":{"button":"left","down":true}}`/`false`; assert the
  click focused the sink xterm by then typing through any keyboard and reading
  the text back. That is the pointer analogue of the keyboard sink test and
  needs no extra tooling.

#### 4.2.4 Gotcha

mwm is click-to-focus. A pointer test that moves without clicking proves
delivery to X (via `xinput test`) but not to an application; a click does.

### 4.3 Monitors

#### 4.3.1 What QEMU can and cannot do headless

`virtio-gpu` reports a connector as *connected* exactly when QEMU has that
scanout enabled. QEMU enables scanout 0 at realize and enables further
scanouts only when a UI frontend reports geometry for them. Under
`-display none` nothing ever does, so with `max_outputs=2`:

- `Virtual-1` is connected from boot and carries an EDID (virtio-gpu
  `edid=on` is the default since QEMU 5.0).
- `Virtual-2` is **permanently disconnected**: a monitor-shaped hole, with no
  EDID, that no QMP or HMP command can fill.

So QMP cannot stage "a second monitor is plugged in". QEMU itself can: it
enables or disables a virtio-gpu head, and gives it an EDID of the requested
size, whenever a display frontend reports a size for that head. Two frontends
need no window: a VNC server bound to the head (`-vnc …,display=<vga id>,head=1`)
receiving SetDesktopSize (0x0 unplugs), or `-display dbus` with SetUIInfo.
That route is untested here. What it gives
for free is the hard half of the problem — an output that must be driven with
nothing on the other end — and that is what the fixed-layout e2e uses
(S3.4.9).

#### 4.3.2 The DRM connector force interface (what the e2e uses for plug-out)

Every connector has `/sys/class/drm/card<N>-<name>/status`, writable by root:

| Write | Effect |
|---|---|
| `off` | force **disconnected**: every probe from now on reports disconnected (plug-**out**) |
| `on` | force **connected** (plug-**in** at the DRM level; no EDID, so no modes unless supplied) |
| `on-digital` | force connected, digital |
| `detect` | clear the force; go back to real detection |

The e2e does:

```sh
conn=$(ls -d /sys/class/drm/card*-Virtual-1 | head -n1)
echo off    > "$conn/status"     # plug-out under the running server
# … assert xrandr geometry unchanged …
echo detect > "$conn/status"     # plug back in
```

Observation recorded in the run logs: the force reaches Xorg as an event
(`X noticed on its own` — it had re-probed within three seconds before any
client asked). The assertion is still made after an explicit `xrandr --query`
(`RRGetInfo` → `xf86ProbeOutputModes`) so it does not rest on that timing.

#### 4.3.3 Staging plug-**in** on the empty connector (S3.10.4, S3.10.5)

```sh
conn2=$(ls -d /sys/class/drm/card*-Virtual-2 | head -n1)
echo on > "$conn2/status"
cat "$conn2/status"              # connected
# as the session user:
xrandr --query                   # Virtual-2 connected …
echo detect > "$conn2/status"    # back to disconnected (scanout still disabled)
```

Expected results, which the stories pin:

- **Layout declared** (the e2e's `Virtual-1`/`Virtual-2` config): nothing moves.
  `Virtual-2` was already enabled at `1024x768+1024+0`; it now reads
  `connected` instead of `disconnected`. Dims stay `2048x768`.
- **No layout (autodetect)**: `xrandr` lists `Virtual-2 connected` with no
  modes (no EDID) and leaves it off. The screen size and `Virtual-1` do not
  change, because nothing in this session listens to RandR and Xorg does not
  auto-enable outputs on hotplug. This is the documented limitation made
  observable.

#### 4.3.4 Giving the plugged-in monitor an EDID (S3.10.7)

The kernel can attach a firmware EDID to a connector:

```sh
# at boot, kernel command line:
drm_kms_helper.edid_firmware=Virtual-2:edid/1280x1024.bin
# or at runtime, before forcing the connector on:
echo 'Virtual-2:edid/1280x1024.bin' > /sys/module/drm_kms_helper/parameters/edid_firmware
```

Built-in EDIDs (no file needed): `edid/800x600.bin`, `edid/1024x768.bin`,
`edid/1280x1024.bin`, `edid/1600x1200.bin`, `edid/1680x1050.bin`,
`edid/1920x1080.bin`. A custom one can be dropped in `/lib/firmware/edid/`.
Requires `CONFIG_DRM_LOAD_EDID_FIRMWARE` in the guest kernel — **confirm on
the Rocky 9 kernel** (`grep DRM_LOAD_EDID_FIRMWARE /boot/config-$(uname -r)`)
before building a test on it. With it, `xrandr --verbose` shows the EDID's
modes on `Virtual-2`, and under autodetection
`xrandr --output Virtual-2 --auto --right-of Virtual-1` from a client enables
it — which is also the only way an output gets enabled in this session, since
no desktop environment runs.

Note the 1024x768 quirk in `vm-guest.sh`'s `verify_fixed_layout`: virtio-gpu
accepts a *preferred* mode on a never-enabled scanout only if it is exactly
`XRES_DEF x YRES_DEF` (1024x768) or within 16 px of the scanout's size, which
a disabled scanout does not have. A firmware EDID whose preferred mode is
anything else may be listed and still refused at modeset. Prefer
`edid/1024x768.bin` for `Virtual-2`.

#### 4.3.5 What stays on hardware (S3.10.8, S8.2.2)

- DDC/EDID re-read latency, link training, a sink that takes a second to
  answer, HDMI vs DisplayPort differences, DP MST.
- KVMs that drop the link **without** the sink ever reporting disconnect:
  nothing is notified and nothing re-probes. The static layout covers it; a VM
  cannot stage it.
- Whether a connector-force write generates the same uevent a real unplug
  does. The e2e observed Xorg re-probing after the write; treat that as
  evidence, not as a guarantee about real hardware.

#### 4.3.6 Not an HMI case: GPU hot-add

`device_add virtio-gpu-pci` creates `/dev/dri/card1`, but Xorg is bound to the
card `xorg-gpu-conf.sh` chose at boot and nothing in this design uses a second
GPU. Out of scope.

### 4.4 Audio

#### 4.4.1 The claim "QEMU cannot test audio hotplug", and why it is wrong

`ci/vm/vm-e2e.sh` (section "audio hotplug: plug and unplug a USB sound card
while the desktop runs") does this on every PR:

```sh
mon_cmd "device_add usb-audio,id=hotsnd,audiodev=snd0,bus=xhci.0"
# poll: host controlC count ↑, container controlC count ↑, WirePlumber alsa_card count ↑
mon_cmd "device_del hotsnd"
# poll: all three ↓ (WirePlumber back to ≤ baseline)
# then play a 440 Hz tone through pulse and assert it in the wavcapture
```

What makes it work, and what someone who concluded otherwise probably hit:

| Requirement | Detail |
|---|---|
| a USB controller | `-device qemu-xhci,id=xhci`. Without one `device_add usb-audio` fails with "no bus"; that is the usual reason the attempt "proved" it impossible. |
| an `audiodev` | since QEMU 7.x every sound device needs `audiodev=<id>`; `usb-audio` without it is refused. `-audiodev none,id=snd0` is a valid, silent backend. |
| a guest driver | `snd-usb-audio` is in the Rocky 9 kernel; the card enumerates as a normal ALSA card (`aplay -l` on the VM host shows "QEMU USB Audio"). |
| USB, not PCI, for removal | `device_del` on USB completes without guest cooperation; a PCI card held open by PipeWire might never be ejected. |
| capture of the result | `wavcapture <file> snd0 44100 16 2` records everything the `snd0` backend mixes, from **any** device attached to it, HDA and USB alike, even with the `none` backend. `stopcapture 0` finalizes the WAV. `ci/vm/check-audio.py` then asserts duration, peak and dominant frequency (Goertzel). |

#### 4.4.2 The three counters (S4.7.1, S4.7.2, S4.7.4, S4.7.5)

| Counter | Read where | Failure it isolates |
|---|---|---|
| `ls /dev/snd/controlC* \| wc -l` on the VM host | layer 2 | QEMU never attached the card, or the guest has no driver |
| the same inside the container | layer 3 | `/dev/snd` is a creation-time snapshot (it was, when it was an `AddDevice=`), or the device cgroup lacks major 116 |
| `pw-cli ls Device \| grep -c 'device.name = "alsa_card'` as the session user | layer 4 | the uevent did not arrive (`Network=host` missing), or the session user cannot open the node (audio gid not aligned) |

Count **Device** objects, not sinks/sources/streams: `wpctl status` prints
friendly descriptions ("Built-in Audio") that are not stable to count, and
derived objects move for reasons unrelated to hotplug. On removal, wait for the
WirePlumber count to settle back **before** the follow-up tone: WirePlumber
has to choose a default sink again after the card it may have switched to
disappears.

#### 4.4.3 Proving the hot-added card plays (S4.7.3)

Existing tests prove the card *exists* at every layer and that the built-in
card still plays afterwards. To prove the new card itself renders audio:

```sh
# as the session user inside the container
wpctl status                                   # find the new sink's id (Audio ▸ Sinks)
wpctl set-default <id>
# host side: audio_capture_start; guest: play a frequency no other test uses
pw-play tone-990.wav                           # 440/880/1320/660 are taken
# host side: audio_capture_stop; check-audio.py … 990
wpctl set-default <builtin-id>
```

Because `usb-audio` shares `audiodev=snd0` with the HDA codec, the capture
sees it. Pick the frequency table up from `vm-e2e.sh`'s `freq_for` and
`vm-guest.sh`'s `gen_tone` so a human can tell the beeps apart in the
artifacts. Confirmed by `operator-e2e:s11_3_1`: `wavcapture` on `snd0`
carries a stream played on the hot-added `usb-audio`, at the level the card
is set to (0.4697 at 100%, 0.0587 at 50%, 0.0000 muted on the e2e VM).

#### 4.4.4 Plug-out under a live stream (S4.7.7)

Start a long playback to the hot-added sink (`pw-play --target <node>` or set
it default and `paplay` a 10 s file), then `device_del hotsnd`. Assert:

- pids of `pipewire`, `wireplumber`, `pipewire-pulse` unchanged (the stack
  did not crash — `supervise_audio` would restart it and the pids would move);
- the export socket still answers (`pactl info` from the VM host);
- the client either finished on the surviving sink or exited with an error
  within 10 s (no hung client).

#### 4.4.5 Capture devices (S4.7.8, S4.7.9)

QEMU's `usb-audio` has historically implemented **playback only** (an
isochronous OUT endpoint; check `qemu-system-x86_64 -device usb-audio,help` on
the runner's QEMU for a capture property before assuming otherwise). Options
for a hot-added *source*:

1. **PCI HDA controller + duplex codec**, both hot-added:
   `device_add intel-hda,id=hda2` then
   `device_add hda-duplex,id=hda2c,bus=hda2.0,audiodev=snd0` (or `hda-micro`
   for a capture-biased codec). Whether the HDA codec bus accepts a hot-added
   codec is **not verified in this repo**; if the second command is refused,
   try adding both at once is not possible, and this route is closed.
   Removal is PCI (`device_del hda2`) and waits for the guest.
2. If no QEMU vehicle exists, the capture direction of hotplug is a hardware
   story (S8.3.1) and should be marked so explicitly, with the attempt and its
   error pasted into the story.

What *is* already covered for capture: the boot-time `hda-duplex` provides a
source, and `verify_record` records the sink **monitor** (loopback) from a
client pod. That proves the capture *path* works, not capture from a
microphone and not capture hotplug.

With `-audiodev none`, a hot-added source delivers silence; the assertion is
"`parec`/`arecord` opens the source and delivers frames", not a frequency.

#### 4.4.6 The soundless-boot path (S2.4.6 / S4.7.10)

On a host with no sound card at boot, `align-device-groups.sh` has no
`controlC*` to measure and leaves the container's `audio` gid at the image
value. A card arriving later would be visible but not openable by the session
user, which is why `supervise_audio` re-runs `align-device-groups.sh audio`
before every stack start. The e2e VM always has `intel-hda`, so this branch
never runs in CI. To cover it:

- boot a second VM profile without `-device intel-hda -device hda-duplex`
  (keep `-audiodev none,id=snd0`; `usb-audio` still needs it);
- assert the first audio start logs `align-device-groups: audio: no device
  nodes present, skipping` and preflight says `no /dev/snd/controlC* visible`;
- `device_add usb-audio,…`; kill `pipewire` as the session user to force a
  stack restart (or wait for the next restart you cause);
- assert the container's `audio` gid now equals `stat -c %g` of the host node,
  WirePlumber lists the card, and a tone through it is captured.

The tmpfiles.d entry that creates an empty `/dev/snd` on soundless hosts is
what lets the container start at all there (`smoke` covers that half).

#### 4.4.7 Phantoms and repeated cycles (S4.7.11)

Run the add/remove cycle five times with the same id. After the last removal:
node counts at baseline, `pw-cli ls Device` at baseline, `pactl list short
sinks` shows no `alsa_output.usb-*`, and the built-in tone plays. A
WirePlumber that keeps a device object for a node that is gone is the failure
this catches.

### 4.5 KVM switch composite (F3.11)

A USB KVM without HID emulation disconnects **everything** on its USB port at
once: keyboard, mouse, and often the audio dongle or hub-attached headset. The
per-device tests prove each path; the composite proves they do not interfere:

```sh
mon_cmd "device_del kvmkbd"; mon_cmd "device_del hottab"; mon_cmd "device_del hotsnd"
# poll all counters down
mon_cmd "device_add usb-kbd,id=kvmkbd,bus=xhci.0"
mon_cmd "device_add usb-tablet,id=hottab,bus=xhci.0"
mon_cmd "device_add usb-audio,id=hotsnd,audiodev=snd0,bus=xhci.0"
# poll all counters up; then: click through hottab, type through kvmkbd,
# tone through the built-in card; Xorg pid and PipeWire pid unchanged
```

S3.11.2 adds the video link: `echo off > …Virtual-1/status` while "away",
`echo detect` on return, with the layout declared, asserting dims at every
step.

---

## 5. Debugging cookbook

```sh
# QEMU: what is attached
echo 'info usb'   | socat - UNIX-CONNECT:ci/vm/mon.sock
echo 'info pci'   | socat - UNIX-CONNECT:ci/vm/mon.sock
echo 'info qtree' | socat - UNIX-CONNECT:ci/vm/mon.sock

# VM host: kernel and udev
udevadm monitor --kernel --udev --subsystem-match=input --subsystem-match=sound --subsystem-match=drm
cat /proc/bus/input/devices
aplay -l; arecord -l
cat /sys/class/drm/card*-*/status
udevadm info /dev/input/event5 | grep -E 'ID_SEAT|ID_INPUT'

# container: nodes, gids, consumers
sudo podman exec desktop ls -ln /dev/input /dev/snd
sudo podman logs desktop | grep -E 'align-device-groups|preflight:'
sudo podman exec desktop tail -50 /home/desktop/.local/share/xorg/Xorg.0.log
sudo podman exec -u desktop -e XDG_RUNTIME_DIR=/run/user/61000 -e HOME=/home/desktop desktop \
    sh -c 'wpctl status; pw-cli ls Device; pactl list short sinks sources'
sudo podman exec -u desktop -e DISPLAY=:0 desktop xrandr --query --verbose
sudo podman run --rm --device desktop.local/display=all localhost/desktop-testclient xinput list

# audio stack health across an event
sudo podman exec desktop sh -c 'pgrep -x pipewire; pgrep -x wireplumber; pgrep -x pipewire-pulse'
PULSE_SERVER=unix:/run/desktop-audio/pulse pactl info
```

Failure signatures by layer are in §1. Two more that are easy to misread:

- **`device_del` printed nothing and nothing changed**: a PCI device waiting
  for guest eject. `info pci` still lists it. Use USB for anything you need to
  remove deterministically.
- **Container node present, WirePlumber silent, no error anywhere**: check
  `Network=host` is in effect (`sudo podman inspect desktop --format
  '{{.HostConfig.NetworkMode}}'` = `host`) and that `/run/udev/data` is
  non-empty inside the container.

---

## 6. Hardware procedure (T4)

Run on a provisioned physical host with the desktop up. Record each command's
output next to the result. Every row is a plug-in **and** a plug-out.

| # | Device | Action | Assert (host) | Assert (container) | Assert (consumer) |
|---|---|---|---|---|---|
| H1 | USB keyboard | plug into a root port | `udevadm monitor` add; `/dev/input/by-id/*-kbd` appears | `podman exec desktop ls /dev/input` gains the node | `xinput list` gains it; typing into an xterm works **with the boot keyboard unplugged** |
| H2 | USB keyboard | unplug | remove event; node gone | node gone | `xinput list` drops it; Xorg log `removing device` |
| H3 | USB mouse | plug / unplug | as H1/H2 | as H1/H2 | pointer moves and clicks with the boot pointer unplugged; `xinput list` tracks it |
| H4 | USB hub with keyboard + mouse + audio | plug / unplug the **hub** | all children appear / disappear together | same | H1–H3 and H8 hold simultaneously |
| H5 | KVM switch (no HID emulation) | switch away, wait 30 s, switch back; repeat 10× | devices re-enumerate, usually at new `eventN` | nodes track | typing and pointer work after every return, **without** `systemctl restart desktop.service` |
| H6 | KVM switch (HID emulation / DDM) | same | devices never disappear | unchanged | input uninterrupted |
| H7 | Monitor, layout declared | unplug cable 30 s, replug | `cat /sys/class/drm/card*-DP-1/status` disconnected → connected; `edid` file empties and refills | — | `DISPLAY=:0 xrandr` identical throughout; no window moved; panel shows the desktop after replug |
| H7b | Monitor via KVM, layout declared | switch away/back | as H7 (some KVMs never report disconnect) | — | as H7; if the panel stays dark with X unchanged, the link did not retrain: note the KVM model |
| H8 | USB headset / DAC | plug / unplug | `aplay -l` gains/loses the card | `/dev/snd/controlC*` tracks | `wpctl status` gains/loses sink **and source**; `pw-play` to the new sink is audible; `arecord -D` / `parec` from its source captures speech |
| H9 | USB audio while streaming | unplug mid-playback | — | PipeWire pids unchanged | playback moves to the built-in sink or stops cleanly; no restart of the audio stack |
| H10 | Dock (keyboard + mouse + audio + display) | plug / unplug | all of the above | all | all |
| H11 | Soundless boot | boot with no card, then plug a USB headset | card appears | node appears; `podman logs desktop \| grep 'align-device-groups: audio'` shows the re-align | `wpctl status` lists it and it plays |

Tools that help on hardware: `desktop-monitors-capture` (names and rates
straight from the server), `xrandr --verbose` (EDID bytes), `cat
/sys/class/drm/card*-*/edid | edid-decode`, `pw-top` (live streams),
`journalctl -k -f` (USB enumeration), `podman logs desktop | grep -E
'preflight|align'` after each boot variant.

---

## 7. Mapping to `Requirements.md`

| This guide | Stories |
|---|---|
| §4.1 keyboards | S3.9.1–S3.9.6, S3.9.12 |
| §4.2 pointers | S3.9.7–S3.9.12 |
| §4.3 monitors | S3.4.9, S3.4.10, S3.10.1–S3.10.8 |
| §4.4 audio | S4.7.1–S4.7.12, S2.4.6, and the client-side proofs S7.7.4–S7.7.7, S7.7.9 |
| §4.5 composite | S3.11.1, S3.11.2, S7.7.8 |
| §4.1–4.3 from a running client container | S7.7.1, S7.7.2, S7.7.3 |
| §6 hardware | S8.2.1, S8.2.2, S8.2.3, S8.3.1 |

---

## 8. Known unknowns (verify before relying on them)

These are stated as expectations from kernel and QEMU documentation, not as
facts observed in this repository's CI:

1. `echo on > …/status` on `Virtual-2` makes Xorg report it `connected` under
   the running server (the `off`/`detect` pair on `Virtual-1` is observed; `on`
   on a never-enabled scanout is not).
2. The Rocky 9 guest kernel has `CONFIG_DRM_LOAD_EDID_FIRMWARE` and the
   runtime `edid_firmware` parameter write is accepted.
3. ~~`wavcapture` on `snd0` captures a stream rendered by the hot-added
   `usb-audio` device~~ — confirmed by `operator-e2e:s11_3_1` (§4.4.3).
4. A capture vehicle for hotplug. Settled from QEMU's source: the HDA codec
   bus refuses `device_add`, and `usb-audio` is playback-only. Still to try:
   a PCI hot-add of `AC97` or `ES1370` (both capture), if the guest image has
   the driver. If not, capture hotplug is T4 only.
5. Package names `xinput` and `xev` on Rocky 9 AppStream.
6. The runner's QEMU version supports `screendump -f png` (the script already
   falls back to PPM). `input-send-event`'s `"device"` routes by display
   device, not by input device id (§4.1.4); `usb-mouse` cannot be routed that
   way and needs HMP `mouse_set`.

Each of these should be turned into a one-line assertion in the first test
that depends on it, so the unknown becomes a recorded fact or a recorded
limitation.
