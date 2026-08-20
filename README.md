# Containerized desktop: UBI9 + Xorg + mwm + PipeWire

Replaces a bare-metal desktop install with a container. The container runs a
full systemd (PID 1) with its own `systemd-logind` seat, an Xorg server on the
host's tty1/GPU/input devices, the Motif window manager (`mwm`), and a
PipeWire audio stack whose sockets are shared with the host and other
containers.

Works in two modes:

| Mode | Requirement | X driver |
|---|---|---|
| **GPU** | NVIDIA driver + [nvidia container toolkit](https://docs.nvidia.com/datacenter/cloud-native/container-toolkit/) on the host | `nvidia` (driver userspace injected via CDI) |
| **No GPU** | just `/dev/dri` on the host | `modesetting`, unaccelerated |

The mode is chosen automatically at every container boot by
`xorg-gpu-conf.sh` — the same image serves both.

## Layout

```
Containerfile.base          BASE image: UBI9 + Rocky9 repos + all packages (network build)
Containerfile               APPLICATION layer: config/services on the base (offline build)
Containerfile.plugin[.base] cdi-device-plugin image (same base/app offline split)
cdi-device-plugin/          generic CDI device plugin: one CDI device -> one k8s
                            resource; reusable on its own, see its README
Containerfile.screenshot[.base]
                            screenshot image (same base/app offline split)
screenshot/                 static X11 screen-capture binary for client
                            containers; the stable CLI the Wayland move hides
                            behind, see its README. Ships inside the desktop
                            image, published to the host at boot, and mounted
                            into clients by desktop.local/tools
install.sh                  host setup / teardown (run as root)
quadlet/desktop.container   podman quadlet unit -> desktop.service
deploy/                     declarative deployment: the same host end state as
                            plain files (quadlet + systemd drop-ins/masks), no
                            install script, image assumed prebuilt
image/                      files baked into the image
  rocky9.repo               Rocky 9 BaseOS/AppStream/CRB at priority=200
  xorg/                     Xwrapper.config, boot-time GPU config generator
  systemd/                  xorg-conf.service, desktop-session.service, drop-ins
  session/                  start-session, xinitrc.desktop, mwmrc, Xdefaults
  pipewire/                 socket-export config drop-ins
```

### Base image vs application layer

The desktop image is built in two stages with separate Containerfiles:

- **`Containerfile.base`** → `desktop-container-base` — everything that
  needs the network: the Rocky GPG key fetch and every FOSS package
  (Xorg, Motif, PipeWire, …). Rebuild only when the package set changes
  or for security updates.
- **`Containerfile`** → `desktop-container` — pure application logic and
  configuration on top (`FROM` the base via the `BASE_IMAGE` build arg):
  scripts, systemd units, user creation, config patches. It is built with
  **`--network=none`**, which both proves and enforces that config
  iteration works completely offline:

```sh
podman build -t localhost/desktop-container-base:latest -f Containerfile.base .
podman build --network=none -t localhost/desktop-container:latest -f Containerfile .
```

`install.sh` runs both stages (the app layer always with `--network=none`);
`--no-base` reuses an existing base so day-to-day config changes never
touch the network. `--base-image REF` points the app build at a base from
a registry instead.

> **Point-release drift:** the Rocky repos pin major version `9` while
> UBI tracks the current 9.x point release. Around release boundaries the
> two package sets can briefly conflict and the base build fails (loudly,
> at dnf resolution). Workaround: temporarily pin the Rocky baseurls to
> the matching point release under `dl.rockylinux.org/vault/rocky/`, or
> wait for the mirrors to catch up.

### Why UBI + Rocky repos?

The image is based on `registry.access.redhat.com/ubi9/ubi`, but UBI's repos
don't ship an X server, Motif, or PipeWire. `image/rocky9.repo` adds Rocky
Linux 9 BaseOS/AppStream/CRB with `priority=200`; UBI repos default to
priority 99 and **lower wins**, so every package UBI provides comes from Red
Hat and Rocky only fills the gaps.

## Install

On the target host (RHEL/Rocky 9 or similar, podman ≥ 4.4):

```sh
sudo ./install.sh            # build image, reconfigure host, start desktop.service
sudo ./install.sh --no-gpu   # force modesetting even if an NVIDIA GPU exists
sudo ./install.sh --no-build --image <ref>   # use a prebuilt image
sudo ./install.sh --uninstall                # restore the host
```

### Declarative install (production)

`install.sh` converts an existing host and can undo itself. For hosts that
are *provisioned* rather than converted — the planned production shape —
use the `deploy/` tree instead: the same end state as plain files (quadlet,
getty mask, logind/tmpfiles/audio drop-ins, sysusers) plus four
converge-at-boot oneshots (seat state, GPU CDI spec, the client CDI specs,
host-shell key material)
and a read-only `desktop-preflight` debug tool — applied with
rsync/RPM/Ansible, no install script, image assumed already built. One
tree serves GPU and GPU-less hosts alike. See `deploy/README.md`.

### What install.sh does to the host (all reverted by `--uninstall`)

Seat handover — the host must stop claiming the devices the container needs:

1. Disables `display-manager.service` (gdm/sddm/…) and sets the default boot
   target to `multi-user.target`.
2. Deletes `/etc/udev/rules.d/72-seat-*.rules` (created by `loginctl attach`)
   and re-triggers udev for the `drm`/`input`/`sound`/`graphics` subsystems,
   so all devices fall back to default `seat0` tagging. Custom multi-seat
   splits would otherwise hide devices from the container's logind.
3. Masks `getty@tty1.service` and sets `NAutoVTs=0`, `ReserveVT=0` for host
   logind — nothing on the host touches the VT the container's Xorg runs on.
   Host logind itself keeps running (ssh logins etc. still work); with no
   graphical session it holds no DRM master and no input devices.

Plus: a tmpfiles.d entry for `/run/desktop-audio` and `/tmp/.X11-unix`, host
audio client configs (see below), optional GPU CDI spec + quadlet drop-in,
and the quadlet unit itself. Prior state (display manager, default target,
replaced files) is saved in `/var/lib/desktop-container/`.

## Seat model inside the container

The container boots systemd with its own `systemd-logind` and a
container-internal `seat0`:

- `--privileged` exposes the host's `/dev` (DRM, input, sound, ttys).
- `/run/udev` is mounted read-only from the host, so libudev/logind/libinput
  in the container see the host's udev database including its seat tags —
  no udevd runs in the container (it's masked).
- `Network=host` lets libinput receive kernel uevents for input hotplug.
- `desktop-session.service` uses the kiosk pattern (`User=desktop`,
  `PAMName=login`, `TTYPath=/dev/tty1`): pam_systemd registers a real logind
  session on the container's seat0 and starts the user manager, which brings
  up PipeWire. The session then runs `startx` → `xinitrc.desktop` → `mwm`.
- Xorg runs **rootless**, as the `desktop` user (`needs_root_rights = no`
  in `image/xorg/Xwrapper.config`). Device access works by plain group
  permission: `/dev/dri/*` is group `video`, `/dev/input/*` is group
  `input`, and at every boot `align-device-groups.sh` renumbers the
  container's groups to match the gids actually on the host's device nodes
  (numeric gids are what the kernel checks, and dynamically-allocated
  groups like `input`/`render` need not match between host and image).
  DRM master is acquired by the first-opener rule — nothing else on the
  host uses the GPU — and systemd hands tty1 to the session user via
  `TTYPath=`. Xorg still tries logind device handover first and falls back
  to direct opens.

### Changing the VT

tty1 is assumed in three places: `getty@tty1` masking in `install.sh`, and
`TTYPath=`/`DESKTOP_VT=` in `image/systemd/desktop-session.service`. Change
all of them (a systemd drop-in works for the unit) to move the session.

## GPU notes

- The image contains **no** NVIDIA bits. `install.sh` runs
  `nvidia-ctk cdi generate --output=/etc/cdi/nvidia.yaml` and adds a quadlet
  drop-in with `AddDevice=nvidia.com/gpu=all` when a GPU + toolkit are found.
  Beware: quadlet only merges drop-ins with podman >= 5.0 (RHEL/Rocky 9.5+);
  older podman ignores the GPU drop-in **silently** and the desktop comes up
  unaccelerated. `systemctl cat desktop.service` shows what actually landed.
- At container boot, `xorg-gpu-conf.sh` writes
  `/etc/X11/xorg.conf.d/20-gpu.conf`: `nvidia` if device nodes **and** an
  injected `nvidia_drv.so` are present, else `modesetting` on the first
  connected `/dev/dri/card*`.
- **nvidia_drv.so missing:** older toolkits don't include the Xorg driver
  module in the CDI spec. `install.sh` detects this and appends `Volume=`
  bind-mounts for the host's `nvidia_drv.so` / `libglxserver_nvidia.so` to
  the GPU drop-in. If your host keeps them elsewhere, add the mounts to
  `/etc/containers/systemd/desktop.container.d/10-gpu.conf` manually.
- **No-GPU mode on an NVIDIA-driver host:** `/dev/dri/card*` is provided
  by the `nvidia-drm` module, which only registers a KMS node with
  `nvidia_drm.modeset=1` on the kernel command line. Without it, the
  modesetting fallback has no device and preflight reports
  "no /dev/dri/card* visible".
- **CDI spec staleness:** `/etc/cdi/nvidia.yaml` pins driver library paths
  and versions. After a host driver update, container creation fails until
  you rerun `nvidia-ctk cdi generate --output=/etc/cdi/nvidia.yaml` (or
  rerun `install.sh`).

## Using the display

Xorg listens on the shared `/tmp/.X11-unix`; the session runs `xhost +local:`
so any local process may connect (see Security below).

```sh
DISPLAY=:0 glxinfo -B                          # from the host
podman run -e DISPLAY=:0 -v /tmp/.X11-unix:/tmp/.X11-unix <img> xclock
```

## Look and feel (dark theme)

The session ships a dark theme. Its appearance lives in three files, the
first two baked into `/etc/skel` and picked up by the `desktop` user at image
build time:

| File | In the image | Covers |
|---|---|---|
| `image/session/mwmrc` | `~/.mwmrc` | root menu, window menu, key bindings, button bindings |
| `image/session/Xdefaults` | `~/.Xdefaults` | frame/menu/icon colors, xterm colors — and where fonts, focus policy and decorations would go |
| `image/session/xinitrc.desktop` | `/etc/X11/xinit/xinitrc.desktop` | root window color (`xsetroot`) |

The palette, shared by all three:

| Role | Color | Used for |
|---|---|---|
| base | `#101216` | root window |
| surface | `#22262d` | unfocused frames, menus, icons |
| accent | `#41637f` | focused frame, selected menu entry |
| accent+ | `#6b8ba6` | accent bevel highlight, terminal cursor |
| text | `#d7dae0` | foreground on surfaces |
| dim | `#9aa1ab` | foreground on unfocused frames |

The accent is deliberately desaturated: mwm paints the **whole frame** with
the active color, not just the title bar, so a saturated accent dominates the
screen. With a muted fill the bevel highlight does most of the focus
signalling.

xterm gets a matching background, a themed scrollbar, and a desaturated
16-color ANSI palette. Only colors are set: the e2e input test computes a
click coordinate from the xterm's centre (`ci/vm/vm-guest.sh`), so resources
that change the window's size (`scrollBar`, `scrollbar.width`, `borderWidth`)
would break it.

`~/.Xdefaults` is read directly by Xt because nothing in the session sets a
`RESOURCE_MANAGER` property — the image needs no `xrdb`. **If an `xrdb` call
is ever added to `xinitrc.desktop`, that property starts existing and this
file is silently ignored**; load it explicitly (`xrdb -merge`) at that point.

One constraint when retuning the palette: `ci/vm/vm-e2e.sh` proves the X
server is actually drawing by asserting the screendump's grayscale stddev is
above 0.02, and an all-dark scheme can flatten that. Measured against the
real e2e screendump this palette lands at ~0.051, a 2.5x margin carried
mostly by the light terminal text against the near-black root — keep
something bright.

Client windows from *other* images (the k8s client pods) get themed mwm
frames, because mwm is ours, but keep their own stock app colors: the
resources live in this image's `/etc/skel`, not in theirs.

Other commonly wanted `Mwm*` resources, none of which are set here:

```
Mwm*keyboardFocusPolicy:  pointer    ! focus follows mouse (default: explicit)
Mwm*focusAutoRaise:       True
Mwm*moveOpaque:           True       ! drag contents, not a wireframe
Mwm*fontList:             9x15bold   ! title/menu font
Mwm*clientDecoration:     -maximize  ! per-app forms too: Mwm*XTerm*clientDecoration
Mwm*iconPlacement:        bottom left
```

To change any of it, edit the file in `image/session/` and rebuild the
application layer — offline, so no base rebuild and no network:

```sh
podman build --network=none -t localhost/desktop-container:latest -f Containerfile .
sudo systemctl restart desktop.service
```

For faster iteration, edit `/home/desktop/.mwmrc` inside the running
container and pick **"Restart mwm"** from the root menu; `f.restart` re-reads
the menus and bindings in place. Resources are **not** re-read by
`f.restart`, so an `~/.Xdefaults` change needs a new X session
(`systemctl restart desktop-session.service` in the container). Either way
the edit lives only in the container's writable layer — nothing mounts a
persistent `/home/desktop`, so `podman rm`/recreate or a k8s pod restart
drops it. Land the real change in the repo file.

mwm is ICCCM-only: no virtual desktops, no panel or systray, no compositing,
and no EWMH — so toolkits' fullscreen/always-on-top requests are ignored.
Those need a different window manager in `xinitrc.desktop`, not a resource.

## Audio: pulse, PipeWire, and ALSA clients — container, host, or other containers

PipeWire inside the container is the only owner of `/dev/snd`. It publishes
two extra sockets in `/run/desktop-audio` (bind-mounted from the host):

| Protocol | Socket | Client setup |
|---|---|---|
| PipeWire native | `/run/desktop-audio/pipewire-0` | `PIPEWIRE_REMOTE=/run/desktop-audio/pipewire-0` |
| PulseAudio | `/run/desktop-audio/pulse` | `PULSE_SERVER=unix:/run/desktop-audio/pulse` |
| ALSA | (via pulse plugin) | `/etc/asound.conf` routing `pcm.!default` to the pulse socket |

- **Host**: `install.sh` already writes `/etc/pulse/client.conf.d/…` and
  `/etc/asound.conf`, so unmodified pulse and ALSA apps just work
  (host needs `alsa-plugins-pulseaudio`, standard on EL).
- **Inside this container**: apps use the default per-user sockets;
  ALSA apps go through `pipewire-alsa`.
- **Other containers**: mount the socket dir and set the env var, e.g.

```sh
podman run -v /run/desktop-audio:/run/desktop-audio \
    -e PULSE_SERVER=unix:/run/desktop-audio/pulse <img> paplay /usr/share/sounds/...
```

For ALSA-only apps in other containers, add the same two-stanza
`/etc/asound.conf` as `install.sh` writes on the host (requires
`alsa-plugins-pulseaudio` in that image).

## Kubernetes (single-node k3s + CRI-O)

`charts/desktop-container` deploys the same image as a Deployment
(replicas=1, Recreate) instead of the quadlet. Everything podman's
`--systemd`/`--privileged`/`--tty` provided is reconstructed in the pod
spec: privileged container with host `/dev`, Memory-backed `emptyDir` on
`/run` and `/tmp`, `tty: true` (so `journal-console.service` mirrors the
journal into `kubectl logs`), `hostNetwork`, the same three host mounts,
and a privileged initContainer that does tmpfiles.d's `chmod 1777` job on
the exported socket dirs.

Prerequisites on the node:
- privileged pods allowed in the target namespace (k3s default: yes)
- CRI-O scanning `/etc/cdi` — required for GPU mode and for client
  containers (see below). This is the default, but the default is not
  echoed in `crio config` output, so it is worth stating explicitly in a
  drop-in rather than assuming:

  ```toml
  # /etc/crio/crio.conf.d/12-cdi.conf
  [crio.runtime]
  cdi_spec_dirs = ["/etc/cdi", "/var/run/cdi"]
  ```
- the image reachable from the node: pushed to a registry (default), or
  imported into the runtime locally — then set `image.repository` to the
  imported name and `image.pullPolicy=Never`
- host prep run once: `sudo ./install.sh --host-prep-only` (seat undo,
  audio client configs, `/etc/cdi/nvidia.yaml` and the client specs
  `/etc/cdi/desktop-{display,audio}.yaml`; no podman service is installed)
- for client pods (and for GPU mode): a device plugin advertising each CDI
  device as a resource — `charts/cdi-device-plugin` (one release per
  device: display, audio), or NVIDIA's own for `nvidia.com/gpu`.
  Kubernetes has no pod field that names a CDI device, so nothing reaches
  CDI injection without one; see "Client containers via CDI"

Install:

```sh
helm install desktop charts/desktop-container \
    --set image.repository=<registry>/desktop-container
# with NVIDIA GPU injection:
helm install desktop charts/desktop-container \
    --set image.repository=<registry>/desktop-container --set gpu.enabled=true
```

GPU mode makes the pod request `gpu.resourceName` (default
`nvidia.com/gpu`, what NVIDIA's own device plugin advertises); the plugin
behind that resource names the CDI device and CRI-O injects the devices
and driver userspace from `/etc/cdi/nvidia.yaml`. On a node without
NVIDIA's plugin, serve the same spec with `charts/cdi-device-plugin` and
point `gpu.resourceName` at it. With `gpu.enabled=false` the container
uses modesetting on `/dev/dri` exactly like the no-GPU podman flow.
Client pods reach this desktop the same way — see "Client containers via
CDI".

> **Changed:** this used to be documented as the pod annotation
> `cdi.k8s.io/gpu: nvidia.com/gpu=all`, which never worked — kubelet does
> not pass pod annotations to the runtime's CDI injection, so the pod
> started with no GPU and no error. The mechanism was never exercised in
> CI because no runner has a GPU. See the note under "Client containers
> via CDI".

Verify: `kubectl logs deploy/desktop | grep preflight:` (same
PASS/WARN/FAIL report), `grep postmortem:` on session failures, and the
same `kubectl exec` spot-checks as the podman checklist below. The pod
turns Ready only when a real X connection succeeds (`xdpyinfo`), so a
stale socket file never reads as Ready.

> **One desktop per host:** never run the quadlet service and the k8s
> deployment at the same time — two X servers would contend for the VT
> and DRM master. On a k8s node, use `install.sh --host-prep-only` (it
> never installs the quadlet); `install.sh` warns if it detects an active
> kubelet/k3s when installing the podman service.

## Client containers via CDI

Any container gets the desktop by resolving
[CDI](https://github.com/cncf-tags/container-device-interface) devices.
There are **two**, one capability each, so a client asks for what it needs
and nothing more:

| device | grants |
|---|---|
| `desktop.local/display=all` | `DISPLAY`, the `/tmp/.X11-unix` socket dir |
| `desktop.local/audio=all` | `PULSE_SERVER`, `PIPEWIRE_REMOTE`, the `/run/desktop-audio` socket dir |
| `desktop.local/tools=all` | `DESKTOP_TOOLS_BIN`, the client toolkit at `/opt/desktop-tools/bin` (read-only) |

The first two are about privilege, not tidiness. Neither half is harmless:

- X11 here runs with `xhost +local:`, so **any** client on the display can
  read every keystroke, screenshot other windows and inject events. A
  sound-only workload has no business holding that.
- The audio socket allows **recording**, not just playback — the
  microphone included. A GUI app that makes no sound should not get it.

**`tools` is not a third capability.** A binary grants nothing on its own — a
socket does. `screenshot` in a container that holds no display is an inert
file; what makes it work is `desktop.local/display`. So the toolkit is
distributed freely and capability stays enforced by the other two devices,
which is why one device covers the whole toolkit rather than one per tool.

The toolkit ships **inside the desktop image** and the desktop publishes it to
`/var/lib/desktop-container/bin` at startup, so a tool's version is an
attribute of the desktop: the display server and the tools that speak to it
update together and cannot disagree about the protocol. That is what makes the
eventual move to Wayland a single-artifact change rather than a coordinated
re-pull of every client.

Its spec is written **only once that directory is populated** (by
`desktop-tools-cdi`, triggered by a `.path` unit watching the directory) —
unlike display and audio, which are written unconditionally at boot. Sockets
are live state that comes and goes with the desktop process; the toolkit is
provisioning state. Gating on it means a node where the desktop has never
started fails at *scheduling* (`Insufficient desktop.local/tools`) instead of
running a container that dies on `command not found`. The resource therefore
means "this node has been provisioned with the toolkit", not "the toolkit is
current".

```sh
podman run --rm --device desktop.local/display=all --device desktop.local/tools=all \
    <image> sh -c '"$DESKTOP_TOOLS_BIN"/screenshot /tmp/out.png'
```

`desktop-client-cdi` writes the display and audio specs
(`/etc/cdi/desktop-display.yaml` and `/etc/cdi/desktop-audio.yaml`). The `deploy/` tree ships it as a
boot-time oneshot; `install.sh` runs it during host prep, including
`--host-prep-only`. Mounts are **rw** — unix `connect(2)` needs write
access to the socket inode — and they mount the *directories*, because
Xorg and PipeWire unlink and recreate their sockets on restart, which
would leave a file bind mount pinned to a dead inode.

A client declares **no** volumes and **no** env of its own. Under podman
it names the devices it wants:

```sh
podman run --rm --device desktop.local/display=all <image> xterm
podman run --rm --device desktop.local/audio=all   <image> paplay sound.wav
podman run --rm --device desktop.local/display=all --device desktop.local/audio=all <image>
```

### Kubernetes: a device plugin per capability

Kubernetes has no pod field that names a CDI device, so
`charts/cdi-device-plugin` bridges the gap: it advertises one CDI device
as one extended resource, and its `Allocate()` returns `CDIDevices` naming
that device — kubelet passes those through the CRI, and CRI-O applies the
spec. The plugin never constructs mounts or env, so the specs stay the
single definition shared with the podman flow.

Kubelet's `Register` takes a single resource name, so install one release
per capability:

```sh
helm install display charts/cdi-device-plugin \
    --set image.repository=<registry>/cdi-device-plugin \
    --set cdiDevice=desktop.local/display=all --set count=10
helm install audio charts/cdi-device-plugin \
    --set image.repository=<registry>/cdi-device-plugin \
    --set cdiDevice=desktop.local/audio=all --set count=10
helm install tools charts/cdi-device-plugin \
    --set image.repository=<registry>/cdi-device-plugin \
    --set cdiDevice=desktop.local/tools=all --set count=10
```

A client pod then requests what it needs — both for a full desktop client,
one for a narrow one:

```yaml
resources:
  limits:
    desktop.local/display: 1
    desktop.local/audio: 1
```

See `examples/x11-client-pod.yaml` for a complete demo pod:

```sh
kubectl describe node | grep -A1 desktop.local/   # 10 of each allocatable
kubectl apply -f examples/x11-client-pod.yaml     # xterm appears
```

> **Why not a `cdi.k8s.io/...` pod annotation?** Because it silently does
> nothing. Kubelet builds a container's CRI annotations from device-plugin
> output only — upstream calls them "generated by other components (i.e.,
> not users)" — so a pod-spec annotation never reaches the runtime's CDI
> injection, and containers start with nothing injected and no error.
> There is no container-level annotation either: `v1.Container` has no
> metadata. A device plugin (or DRA) is the only supported route.

The plugin is deliberately generic: it knows nothing about displays or
audio. Point it at any CDI device on the node and install one release per
device — it is usable outside this project, and
`cdi-device-plugin/README.md` documents it standalone.

- **Resource name** defaults to the device's CDI kind
  (`desktop.local/audio`), overridable with `resourceName` when that would
  collide with another plugin — e.g. use `desktop.local/gpu` when NVIDIA's
  own plugin already owns `nvidia.com/gpu`.
- **`count`** is how many interchangeable copies to advertise. Device
  plugin allocation is exclusive, so for a *shareable* device like these
  it is simply the maximum number of concurrent client pods; the two
  counts are independent.
- **Health is spec presence.** A resource is Healthy only while its device
  resolves in the CDI spec dirs, so pods stay Pending rather than failing
  at container creation on a node whose spec is missing. The check is the
  same lookup the runtime performs.

Other semantics worth knowing:

- **Why audio is one device and not several.** Splitting it by protocol
  (pulse vs PipeWire-native) would reduce no privilege — both front the
  same daemon with the same rights — and ALSA clients reach audio
  *through* the pulse socket, so the names would mislead. The split that
  would matter, playback vs capture, is not expressible in CDI at all:
  both directions travel the same socket, and restricting them is
  PipeWire-side policy (a second restricted instance exporting its own
  socket dir). Until that exists, `desktop.local/audio` is honestly
  "audio, including the microphone".
- **The specs are host state.** They describe the export contract — paths
  and `DISPLAY` — not the desktop's current status, so they are a pure
  function of configuration with nothing to converge, and `helm uninstall`
  does not touch them. Override per host by dropping assignments
  (`DISPLAY_VALUE=:1`, `AUDIO_DIR=...`) into
  `/etc/desktop-container/client-cdi.conf` and rerunning the generator;
  the values must match what the desktop exports.
- **Node prep is required.** The specs must exist on every node that runs
  clients: `sudo ./install.sh --host-prep-only`, or apply the `deploy/`
  tree.
- **SELinux: confined clients need the export dirs labeled.** On an
  enforcing host the exported socket dirs carry host labels, so a confined
  container is denied when it connects — it gets its env and mounts, then
  fails. CDI cannot fix this from the spec: `containerEdits` has no
  equivalent of `-v src:dst:z`, so the labeling is host-side. Until the
  dirs are labeled `container_file_t` (`semanage fcontext` +
  `restorecon`), clients need label separation turned off —
  `--security-opt label=disable` for podman, an `seLinuxOptions`/privileged
  pod spec for kubernetes. The desktop container itself is unaffected:
  `--privileged` already disables label separation.
- **Audio clients**: pulse and PipeWire-native work via the injected env
  alone. ALSA-only apps additionally need `alsa-plugins-pulseaudio` in
  their image plus the two-stanza `/etc/asound.conf` shown in the Audio
  section, pointing at the injected `PULSE_SERVER` path.
- **GL**: clients get software rendering. Hardware GL would need render
  nodes/driver userspace in the client (deliberately out of scope — the
  GPU is a separate CDI device, `nvidia.com/gpu`).

## Host terminal from the desktop

The mwm root menu has a **"Host Terminal"** entry: an xterm (in the
container, where the X stack lives — the host deliberately has no GUI
packages) whose shell is on the **host**, via ssh over loopback (the
container shares the host network namespace).

Enable it by giving host-prep a target account:

```sh
sudo ./install.sh --shell-user alice          # podman flow
sudo ./install.sh --host-prep-only --shell-user alice   # k8s flow
# --shell-user defaults to $SUDO_USER (whoever ran sudo)
```

(The declarative `deploy/` tree does this differently: a dedicated
unprivileged `desktop-shell` account, a fresh key on every boot, and
root-owned trust under `/etc/ssh/authorized_keys.d` — always on, with a
commented off-switch. See `deploy/README.md` "Host Terminal".)

What that sets up:

- a dedicated ed25519 keypair in `/etc/desktop-container/` — **root-only
  on the host** (no non-root host user can read it) and mounted read-only
  into the container, where a boot script installs a `desktop`-owned copy
  and generates the `ssh host` client config (loopback, fixed user,
  `NoHostAuthenticationForLocalhost`);
- a restricted `authorized_keys` entry for the target user:
  `from="127.0.0.1,::1"`, no port/agent/X11 forwarding;
- sshd enabled if it wasn't running. `--uninstall` removes the key
  material and the authorized_keys entry but deliberately leaves sshd
  as-is — whether the host runs sshd is the admin's call.

A failed "Host Terminal" click keeps its window open with the reason and
the enablement command (`/usr/local/bin/host-terminal` wrapper) instead of
flashing shut.

Security framing: the desktop container is `--privileged`, so container
root already has host-root-equivalent power; this key adds a *convenient*
path for the unprivileged `desktop` user to a *specific* host account,
with the ssh audit trail in the host journal. Without `--shell-user`
everything degrades gracefully — preflight WARNs and the menu entry
fails; the rest of the desktop is unaffected.

## CI

Three workflows verify everything short of NVIDIA hardware, on every PR:

- **`ci.yml`** — static checks (go fmt/vet/test for the plugin,
  shellcheck, helm lint + golden template assertions in
  `ci/helm-assertions.sh`, kubeconform over both charts and the client
  manifests) and the builds: base images are pulled from GHCR by content
  hash (`ci/build-bases.sh`, rebuilt only when their inputs change) and
  the application layers build with `--network=none` — the offline
  invariant is a CI gate. The same job resolves every CDI device against a
  real podman: the NVIDIA stub, and the client specs — display alone,
  audio alone, both together, each asserted to grant its own capability
  and **not** the other's, with a no-device control proving nothing is
  baked into the image.
  Then `ci/smoke-podman.sh` runs the **real `install.sh`**
  on the ephemeral runner (quadlet install, seat undo, sshd/key
  provisioning) and asserts the boot: seat0 session, audio sockets +
  cross-uid connects, preflight/postmortem in the logs, the tty-less
  journal-mirror guard, end-to-end `ssh host`, and clean `--uninstall`.
  After that, `ci/smoke-deploy.sh` proves the **declarative `deploy/`
  tree** on the same restored runner: script-level branch tests (CDI
  converger no-downgrade rules, client-spec disjointness, overrides and
  atomic write, removal of the superseded combined spec, seat-prep on a
  staged dirty seat), then
  the full composition — rsync-apply, boot from the tree's quadlet,
  converger oneshots, stub-CDI marker on container PID 1, `desktop-shell`
  ssh in both directions, `desktop-preflight` green, service restart. A
  static-job guard also keeps the two quadlet variants' `[Container]`
  sections in sync.
- **`e2e-vm.yml`** — the full stack in a KVM-booted **Rocky 9 VM** with
  virtio display/input/sound and **SELinux enforcing**
  (`ci/vm/vm-e2e.sh` + `ci/vm/vm-guest.sh`): real Xorg starts rootless on
  a real KMS device, mwm runs, audio devices appear, the host-terminal
  ssh path works under SELinux (validating the restorecon handling),
  input hotplug is exercised via QEMU device_add; then the **declarative
  `deploy/` tree** takes over the same machine (install.sh uninstalled,
  tree rsync-applied, seat-prep evicting the restored getty, the
  root-owned `desktop-shell` ssh trust proven under enforcing,
  `desktop-preflight` asserted fully green); then the machine switches to
  k3s and deploys the desktop chart plus one `cdi-device-plugin` release
  per capability — real readiness, both resources becoming allocatable,
  then client pods drawing on the display and playing/recording audio
  purely through CDI injection, checked against a control pod that
  requests nothing and must get nothing, and against narrow pods proving a
  display-only client gets no audio and an audio-only client cannot open
  the display at all. Screendumps of the virtual display are uploaded as
  artifacts.
- **`base-rebuild.yml`** — weekly from-scratch base rebuilds pushed to
  GHCR: early warning for Rocky/UBI point-release drift.

Not covered by CI (needs the real machine): everything NVIDIA (CDI
injection, `nvidia_drv.so`, GL acceleration) and physical-input quirks
beyond what virtio emulates.

## Verification checklist (on the target host)

```sh
systemctl status desktop.service
podman exec desktop systemctl status desktop-session xorg-conf
podman exec desktop loginctl                   # session for "desktop" on seat0
podman exec desktop cat /etc/X11/xorg.conf.d/20-gpu.conf   # nvidia vs modesetting
DISPLAY=:0 xrandr                              # display up, modes listed
DISPLAY=:0 glxinfo -B                          # GPU mode: "NVIDIA"; else llvmpipe
fgconsole                                      # VT 1 active
podman exec desktop ps -o user= -C Xorg        # "desktop", not root (rootless X)
podman exec desktop journalctl -u xorg-conf -o cat | grep align  # gid alignment log
podman exec -u desktop desktop wpctl status    # sound devices present
# audio, one per protocol (repeat from host and from a scratch container):
pw-play      /usr/share/sounds/alsa/Front_Center.wav   # PIPEWIRE_REMOTE set
paplay       /usr/share/sounds/alsa/Front_Center.wav   # PULSE_SERVER set
aplay        /usr/share/sounds/alsa/Front_Center.wav   # via /etc/asound.conf
```

Input hotplug: unplug/replug a keyboard; it should re-appear in the session
(uevents arrive because the container shares the host network namespace).

## Security notes

- The container is `--privileged` with host network — treat the image and
  everything allowed to start containers as fully trusted.
- Xorg runs rootless (as `desktop`), so an X server compromise yields that
  user, not root. Note the `desktop` user is still in the `input` group and
  can read every keyboard from `/dev/input` — inherent to running the
  display server.
- `xhost +local:` grants any local uid access to the display; keys typed into
  the session are visible to any local process that connects. Tighten by
  removing it from `image/session/xinitrc.desktop` and distributing the xauth
  cookie instead.
- Exported audio sockets are world-connectable (`UMask=0000` drop-ins);
  restrict `/run/desktop-audio` permissions in the tmpfiles.d entry if that
  matters on your host.

## Troubleshooting

**Start here:** `podman logs desktop` — the container's full journal is
mirrored to the console by `journal-console.service`, a `journalctl -f`
forwarder writing to `/dev/console`. (This is why the quadlet passes
`--tty`: without it the runtime creates no `/dev/console`, and PID 1's
stdout is no alternative — systemd redirects its own stdio to `/dev/null`
during boot. Without a tty the unit fails loudly rather than silently
writing the journal into a RAM-backed file.) Two things to look for:

- the boot-time preflight report: one `PASS`/`WARN`/`FAIL` line per
  assumption (devices visible, udev db mounted, gid alignment, seat tags,
  logind, shared socket dirs, NVIDIA coherence) with a remediation hint on
  each failure — `podman logs desktop | grep preflight:`
- the X session postmortem on every abnormal session exit: tail of the Xorg
  log plus a `LIKELY CAUSE:` verdict — `podman logs desktop | grep postmortem:`

For filtered queries, the journal itself is still available:
`podman exec desktop journalctl -u desktop-session` (note the postmortem
runs from `ExecStopPost=` after the session cgroup is gone, so it appears
under `journalctl -t session-postmortem`, not under the unit).

- **Xorg: "cannot open /dev/tty1"** — something on the host owns the VT;
  check `getty@tty1` is masked and no host display manager is running.
- **Xorg: "cannot become DRM master" / `drmSetMaster failed`** — some host
  process is *currently* holding the GPU (display manager still running or
  re-enabled, another compositor). DRM master is released automatically
  when its holder's fd closes, so a previously-stopped X server is never
  the cause — a live one is. `fuser -v /dev/dri/card0` on the host shows
  the culprit; rerun `install.sh` to re-disable the display manager.
- **Keyboard/mouse/GPU dead with rootless X (EACCES opening devices)** —
  gid alignment likely failed: check
  `journalctl -u xorg-conf` inside the container for `align-device-groups`
  lines. Escape hatch: set `needs_root_rights = yes` in
  `/etc/X11/Xwrapper.config` (root Xorg) and report the alignment log.
- **Xorg: "no screens found" without GPU** — no `/dev/dri/card*` with a
  connected output; check the container log for `xorg-gpu-conf` lines.
- **Wrong GPU mode picked** — the config is regenerated on every container
  boot; restart with `systemctl restart desktop.service` after fixing the
  device situation.
- **No input devices** — `/run/udev` mount missing, or devices still tagged
  for another seat: rerun `install.sh` (removes `72-seat-*.rules`) or check
  `udevadm info /dev/input/event0 | grep -i seat`.
- **SELinux denials** — `--privileged` disables label separation; if you
  tightened the unit, host clients may need extra policy for the shared
  sockets.
