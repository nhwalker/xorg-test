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
install.sh                  host setup / teardown (run as root)
quadlet/desktop.container   podman quadlet unit -> desktop.service
image/                      files baked into the image
  rocky9.repo               Rocky 9 BaseOS/AppStream/CRB at priority=200
  xorg/                     Xwrapper.config, boot-time GPU config generator
  systemd/                  xorg-conf.service, desktop-session.service, drop-ins
  session/                  start-session, xinitrc.desktop, mwmrc
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
- At container boot, `xorg-gpu-conf.sh` writes
  `/etc/X11/xorg.conf.d/20-gpu.conf`: `nvidia` if device nodes **and** an
  injected `nvidia_drv.so` are present, else `modesetting` on the first
  connected `/dev/dri/card*`.
- **nvidia_drv.so missing:** older toolkits don't include the Xorg driver
  module in the CDI spec. `install.sh` detects this and appends `Volume=`
  bind-mounts for the host's `nvidia_drv.so` / `libglxserver_nvidia.so` to
  the GPU drop-in. If your host keeps them elsewhere, add the mounts to
  `/etc/containers/systemd/desktop.container.d/10-gpu.conf` manually.

## Using the display

Xorg listens on the shared `/tmp/.X11-unix`; the session runs `xhost +local:`
so any local process may connect (see Security below).

```sh
DISPLAY=:0 glxinfo -B                          # from the host
podman run -e DISPLAY=:0 -v /tmp/.X11-unix:/tmp/.X11-unix <img> xclock
```

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
- CRI-O with CDI support enabled (for GPU mode)
- the image reachable from the node: pushed to a registry (default), or
  imported into the runtime locally — then set `image.repository` to the
  imported name and `image.pullPolicy=Never`
- host prep run once: `sudo ./install.sh --host-prep-only` (seat undo,
  audio client configs, `/etc/cdi/nvidia.yaml` generation; no podman
  service is installed)

Install:

```sh
helm install desktop charts/desktop-container \
    --set image.repository=<registry>/desktop-container
# with NVIDIA GPU injection via the cdi.k8s.io annotation:
helm install desktop charts/desktop-container \
    --set image.repository=<registry>/desktop-container --set gpu.enabled=true
```

GPU mode adds the pod annotation `cdi.k8s.io/gpu: nvidia.com/gpu=all`;
CRI-O injects devices and driver userspace straight from the CDI spec — no
device plugin needed. With `gpu.enabled=false` the container uses
modesetting on `/dev/dri` exactly like the no-GPU podman flow.

Verify: `kubectl logs deploy/desktop | grep preflight:` (same
PASS/WARN/FAIL report), `grep postmortem:` on session failures, and the
same `kubectl exec` spot-checks as the podman checklist below. The pod
turns Ready only when Xorg serves `/tmp/.X11-unix/X0`.

## Client pods via the desktop device plugin

`charts/desktop-device-plugin` + `device-plugin/` turn "an app pod that can
draw on the desktop" into a one-line resource request. The plugin (a
DaemonSet, image built from `Containerfile.plugin`) registers the custom
resource `desktop.local/display` with kubelet; when a pod requests it,
kubelet's `Allocate()` call returns the socket-dir mounts
(`/tmp/.X11-unix`, `/run/desktop-audio`, rw — unix `connect(2)` needs write
access) and env (`DISPLAY=:0`, `PULSE_SERVER=…/pulse`,
`PIPEWIRE_REMOTE=…/pipewire-0`), so the client needs **no** volumes or env
of its own:

```yaml
resources:
  limits:
    desktop.local/display: 1
```

See `examples/x11-client-pod.yaml` for a complete demo pod (xterm on the
desktop, reusing the desktop image).

Semantics worth knowing:

- **Slots**: the plugin advertises `slots` (default 10) virtual copies —
  the display is shareable; the count is just the max number of concurrent
  client pods. Resource name, slot count, DISPLAY, and paths are all chart
  values (must match the desktop deployment's).
- **Health gating**: slots are Healthy only while `X<display>` exists in
  the X socket dir, so client pods stay Pending until the desktop's Xorg
  is actually serving. Audio sockets don't gate health.
- **Audio**: pulse and PipeWire-native clients work via the injected env
  alone. ALSA-only apps additionally need `alsa-plugins-pulseaudio` in
  their image plus the two-stanza `/etc/asound.conf` shown in the Audio
  section, pointing at the injected `PULSE_SERVER` path.
- **GL**: clients get software rendering. Hardware GL would need render
  nodes/driver userspace in the client (out of the plugin's scope by
  design).

Install (after the desktop chart):

```sh
helm install desktop-plugin charts/desktop-device-plugin \
    --set image.repository=<registry>/desktop-device-plugin
kubectl describe node | grep -A1 desktop.local/display   # 10 allocatable
kubectl apply -f examples/x11-client-pod.yaml            # xterm appears
```

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
during boot.) Two things to look for:

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
