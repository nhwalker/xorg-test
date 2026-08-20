# Declarative host deployment (no install.sh)

`install.sh` mutates a host imperatively, autodetects what it can, and
records state so it can undo itself — right for a dev box, wrong for
production. This tree is the **same host end state expressed as plain
files**: a podman quadlet plus systemd drop-ins, masks, symlinks, and
tmpfiles.d entries. Lay it onto the filesystem with whatever provisioning
you already use (rsync, RPM/ostree packaging, Ansible `copy`, image build),
reload systemd, and the desktop comes up on every boot of
`multi-user.target`. Nothing here is a script that runs once at install
time; the steps that are inherently runtime — seat convergence, CDI spec
generation, ssh key material — are systemd oneshot units that converge at
every boot.

Nothing in the tree builds or pulls images: **the desktop image must
already be in podman's storage** (`podman load` / `podman pull` during
provisioning). See "Overriding the image reference" below.

## Requirements

- podman >= 4.4. Nothing the tree itself ships depends on quadlet drop-in
  directories — quadlet only learned to merge those in podman 5.0 and
  older versions ignore them *silently*, which is why every feature here
  lives in the base unit and no-ops at runtime instead. The one documented
  drop-in (the optional image pin below) therefore needs podman >= 5.0
  (RHEL/Rocky 9.5+); after applying one, `systemctl cat desktop.service`
  and check it actually landed in the generated unit.
- the desktop image already present in podman's storage.
- host packages: see `HOST-REQUIRES.md` (the bare-minimum `dnf install`
  line, per host class).

## Layout

One tree, `host/`, for every desktop host — with or without a GPU, Host
Terminal always provisioned. It mirrors the host filesystem from `/`.
Anything per-host-class is handled by runtime no-ops (GPU) or a commented
off-switch (Host Terminal), not by different file sets.

## GPU: one tree serves GPU and GPU-less hosts

Most deployments have an NVIDIA GPU, so the base unit carries the GPU
wiring unconditionally and GPU-less hosts no-op at runtime instead of
using a different unit:

- `Environment=NVIDIA_DRIVER_CAPABILITIES=all` — inert without the NVIDIA
  stack.
- `AddDevice=nvidia.com/gpu=all` — resolved against `/etc/cdi/nvidia.yaml`
  at every container start. This is the piece that is *not* naturally a
  no-op (an unresolvable CDI device fails container creation), which is
  why:
- `desktop-cdi-refresh.service` runs before every desktop start and
  **converges** the spec: `nvidia-ctk cdi generate` where GPU + toolkit
  exist, otherwise a **stub spec** defining `nvidia.com/gpu=all` with a
  single marker edit (`NVIDIA_CDI_STUB=1` — CDI rejects a device with no
  edits, so the marker doubles as what makes the stub valid). It never
  overwrites a real spec with a stub while NVIDIA hardware is visible, so
  losing a boot race against the driver module load fails loudly instead
  of silently degrading.

The failure mode this buys and its cost: a GPU host with a missing/broken
container toolkit comes up as a *working modesetting desktop* instead of
failing. The container's preflight flags exactly that case — the stub
marker plus visible NVIDIA hardware — as `preflight: FAIL` in
`podman logs desktop`; monitoring on GPU hosts should key on it.

## Client containers: the other CDI specs

`desktop-cdi-refresh` writes the spec this desktop *consumes* (the GPU).
Two generators write the specs other containers consume to reach *this
desktop* — `desktop-client-cdi` for the two capabilities, and
`desktop-tools-cdi` for the toolkit:

| spec | device | grants |
|---|---|---|
| `/etc/cdi/desktop-display.yaml` | `desktop.local/display=all` | `DISPLAY` + `/tmp/.X11-unix` |
| `/etc/cdi/desktop-audio.yaml` | `desktop.local/audio=all` | `PULSE_SERVER`, `PIPEWIRE_REMOTE` + `/run/desktop-audio` |
| `/etc/cdi/desktop-tools.yaml` | `desktop.local/tools=all` | `DESKTOP_TOOLS_BIN` + `/opt/desktop-tools/bin` (ro) |

Display and audio are split for privilege, not tidiness. X11 here runs with
`xhost +local:`, so any client on the display can keylog the session,
screenshot other windows and inject events; and the audio socket permits
**recording**, microphone included. Few clients need both, so they are granted
separately.

`tools` is not a third capability — a binary grants nothing without the socket
it talks to. It carries the client tools the desktop publishes to
`/var/lib/desktop-container/bin` at startup (see `publish-tools.sh` inside the
image), so tool versions track the desktop image rather than the host.

**Its spec is conditional, and that is deliberate.** `desktop-tools-cdi` runs
from `desktop-tools-cdi.path`, which watches that directory and fires when it
becomes non-empty; a boot-time oneshot could not work, since it would run
before the desktop had published anything and never run again. Display and
audio specs describe an export contract and are written unconditionally;
sockets are live state whose absence is a clean connect error. The toolkit is
*provisioning* state, so gating on it turns "this node was never set up" into
a scheduling failure an operator can see. The resource means "this node has
been provisioned with the toolkit", not "the toolkit is current" — nothing
removes the spec if the directory is later emptied.

The unit the watcher triggers is `RemainAfterExit=yes`, and it has to be:
`DirectoryNotEmpty=` is a level condition, so a unit that exited would be
retriggered immediately, over and over, until systemd failed the `.path` unit
on its start limit. Staying active parks the watcher — at the cost that the
generator runs **at most once per boot**. Anything that tears the spec down
must therefore also `systemctl stop desktop-tools-cdi.service`, or the host
cannot advertise the device again until it reboots (`install.sh --uninstall`
does this).

Mounts are rw (unix `connect(2)` needs write access to the socket inode)
and are of the **directories**, not the socket files: Xorg and PipeWire
unlink and recreate their sockets on restart, and a file bind mount would
pin the dead inode.

A client declares nothing of its own:

```sh
podman run --rm --device desktop.local/display=all <image> xterm
podman run --rm --device desktop.local/audio=all   <image> paplay sound.wav
```

In kubernetes there is no pod field naming a CDI device, so a device
plugin bridges the gap (`charts/cdi-device-plugin` in this repo), one
release per device since kubelet's `Register` takes a single resource
name. A client pod then requests what it needs:

```yaml
resources:
  limits:
    desktop.local/display: 1
    desktop.local/audio: 1     # omit for a GUI app that makes no sound
```

A `cdi.k8s.io/...` pod annotation does NOT work and fails silently -
kubelet builds a container's CRI annotations from device-plugin output
only, so the annotation never reaches CDI injection. See
`cdi-device-plugin/README.md` for the details and the upstream citations.

**Why audio is one device.** Splitting it by protocol (pulse vs
PipeWire-native) reduces no privilege — both front the same daemon — and
ALSA clients reach audio through the pulse socket, so the names would
mislead. The split that would matter, playback vs capture, is not
expressible in CDI: both directions share the socket, and restricting them
is PipeWire-side policy.

Two things make this unit unlike its siblings:

- **It ships enabled.** The others are pulled in by `desktop.container`'s
  `Wants=`, which is enough because they only matter when the quadlet
  desktop starts. This one also matters where there is no quadlet at all —
  a kubernetes node runs the desktop as a pod, and its client pods still
  need the specs — so the tree carries a `multi-user.target.wants` symlink
  alongside the `Wants=`.
- **There is nothing to converge.** The specs are a pure function of the
  paths and `DISPLAY` the desktop exports, not a report on its state, so
  they are simply rewritten (atomically, via temp file + rename) on every
  boot. Writing them while the desktop is down is correct: a client that
  starts early gets its mounts and finds no socket behind them.

Override per host with assignments in
`/etc/desktop-container/client-cdi.conf` (`DISPLAY_VALUE`, `X11_DIR`,
`AUDIO_DIR`) — they must match what the desktop actually exports.
Validation runs before any write, so a rejected config leaves both
existing specs untouched.

**SELinux caveat.** This tree does not label the exported socket dirs, so
on an enforcing host a *confined* client resolves its device, receives the
mounts and env, and is then denied on `connect(2)`. CDI cannot express a
relabel (no `:z` equivalent in `containerEdits`), so fixing it properly
means labeling `/tmp/.X11-unix` and `/run/desktop-audio`
`container_file_t` on the host. Until then, clients need label separation
off (`--security-opt label=disable`, or a privileged pod). The desktop
container is unaffected — it is `--privileged`. See README.md "Client
containers via CDI".

## Apply

```sh
# as root, from the repo:
rsync -a --chown=root:root deploy/host/ /

systemctl daemon-reload
reboot
```

`--chown=root:root` matters: `rsync -a` would otherwise preserve the repo
checkout's owner on files under `/etc`. `-a` also copies the two symlinks
in the tree as symlinks — keep that in mind if your provisioning tool
flattens links (`default.target` and the `getty@tty1.service` mask are
symlinks, see below).

A reboot is the clean path and the honest production test — everything is
wired into the boot transaction, and a host that only works after manual
`systemctl start`s is misprovisioned. To apply live on a host that was
never graphical, `systemctl daemon-reload && systemd-sysusers &&
systemd-tmpfiles --create && systemctl restart systemd-logind &&
systemctl start desktop.service` works too (sysusers before tmpfiles: the
desktop-shell home dir references the user; and if sshd was already
running, `systemctl reload sshd` — the `sshd_config.d` drop-in is only
read at sshd start). Converting a currently
*graphical* host live is `seat-prep.sh`'s job (see "Seat state" below) —
it runs before every desktop start anyway, and its verification gate tells
you if a leftover session still holds the GPU, in which case reboot.

There is no uninstall: reprovision the host instead (that asymmetry is the
point of the declarative form — the file list above *is* the state).

## What each file does

| File (under `host/`) | Replaces (install.sh step) |
|---|---|
| `etc/containers/systemd/desktop.container` | the quadlet install; `[Install]` is honored by the quadlet generator, so there is no `systemctl enable` |
| `etc/systemd/system/default.target` → `multi-user.target` | `systemctl set-default multi-user.target` |
| `etc/systemd/system/getty@tty1.service` → `/dev/null` | `systemctl mask getty@tty1.service` (frees the VT) |
| `etc/systemd/logind.conf.d/50-desktop-container.conf` | logind `NAutoVTs=0` / `ReserveVT=0` drop-in |
| `etc/tmpfiles.d/desktop-container.conf` | shared socket dirs `/run/desktop-audio`, `/tmp/.X11-unix` |
| `etc/pulse/client.conf.d/50-desktop-container.conf` | host Pulse clients → container socket |
| `etc/alsa/conf.d/60-desktop-container.conf` | host ALSA clients → pulse plugin → container socket (install.sh writes `/etc/asound.conf` instead; the drop-in form doesn't clobber host files but is EL/Fedora packaging) |
| `usr/local/bin/desktop-preflight` | read-only debug tool: PASS/WARN/FAIL per host-side assumption; not wired into boot |
| `etc/systemd/system/desktop-seat-prep.service` | oneshot before `desktop.service`: converge + verify the seat (see "Seat state" below) |
| `usr/local/libexec/seat-prep.sh` | the script that unit runs (boot-time convergence agent, not an installer) |
| `etc/systemd/system/desktop-cdi-refresh.service` | oneshot before `desktop.service`: converge `/etc/cdi/nvidia.yaml` (real spec or no-op stub, see "GPU" above) |
| `usr/local/libexec/desktop-cdi-refresh` | the script that unit runs (boot-time convergence agent, not an installer) |
| `etc/systemd/system/desktop-client-cdi.service` | oneshot writing the two specs **client** containers resolve to reach this desktop, one per capability (see "Client containers" below); the only oneshot shipped enabled for `multi-user.target`, because k8s nodes never start `desktop.service` |
| `etc/systemd/system/multi-user.target.wants/desktop-client-cdi.service` → `../desktop-client-cdi.service` | that enablement, as a symlink, so the tree stays a pure `rsync` with no `systemctl enable` step |
| `usr/local/libexec/desktop-client-cdi` | the script that unit runs (pure config → specs; overridable via `/etc/desktop-container/client-cdi.conf`) |
| `etc/sysusers.d/desktop-container.conf` | the dedicated `desktop-shell` account (see "Host Terminal" below) |
| `etc/ssh/sshd_config.d/40-desktop-container.conf` | root-owned `authorized_keys` location for `desktop-shell` |
| `etc/desktop-container/shell-user` | account name the container's `ssh host` targets (static: `desktop-shell`) |
| `etc/systemd/system/desktop-host-shell.service` | oneshot before `desktop.service`: fresh keypair every boot + root-owned trust entry |
| `usr/local/libexec/desktop-host-shell-setup` | the script that unit runs (boot-time convergence agent, not an installer) |

All three oneshots are pulled in by the quadlet's own `[Unit] Wants=` lines —
deliberately not by quadlet *drop-ins*, which pre-5.0 podman ignores — so
nothing needs enablement: copying the files is the whole installation.

## Seat state: converged every boot, assumed never

`seat-prep.sh` (run by `desktop-seat-prep.service` before every desktop
start, and safe to run by hand when converting a live host) makes no
assumptions about the seat state it finds. Whatever is there — a running
display manager, spawned gettys, `loginctl attach` seat splits, a
graphical default target — is walked back to what the quadlet needs:
seat-attachment udev rules removed (with a device retrigger), the display
manager disabled and stopped, `multi-user.target` re-asserted as default,
`getty@tty1` masked and stopped, and logind restarted to pick up
`NAutoVTs=0`/`ReserveVT=0` when anything actually changed. Steady-state
boots change nothing and log nothing.

Convergence deletes rather than backs up (no `/var/lib` state, same
philosophy as the rest of the tree), and it ends with a verification gate:
if some process this script doesn't know about still holds a DRM device or
the VT — a compositor, a session that outlived its display manager — it
fails loudly naming the culprit, instead of letting the desktop boot into
`drmSetMaster failed`. `desktop.service` still starts (`Wants=`, not
`Requires=`), hits the same conflict, and the seat-prep log explains why.
The static `default.target` / getty-mask symlinks in the tree remain the
boot-time baseline; the script is what makes them true again after drift.

## Host Terminal: always on, dedicated account, boot-fresh key

The desktop's "Host Terminal" menu entry lands in **`desktop-shell`**, a
deliberately boring unprivileged account created declaratively by
sysusers.d (no groups, no sudo, locked password — the container is
`--privileged` anyway, so this path is convenience + audit trail, not a
boundary). Differences from the install.sh flow:

- **Fresh key every boot.** `desktop-host-shell.service` regenerates the
  ed25519 keypair under `/etc/desktop-container` on every boot; key
  material never outlives the boot that made it, and there is no rotation
  procedure to remember.
- **Root-owned trust.** The restricted entry (`from=` loopback only, no
  forwarding) is written to `/etc/ssh/authorized_keys.d/desktop-shell`,
  wired by the sshd_config.d drop-in — nothing under `/home` is touched
  and the account cannot extend its own access.
- **Always on.** No per-host input. The off-switch is in
  `etc/containers/systemd/desktop.container`: comment out the two
  `Wants=`/`After=desktop-host-shell.service` lines. With no key
  generated, nothing can log into the account and the container's menu
  entry degrades gracefully.

sshd itself: the unit `Wants=sshd.service` (started each boot while the
desktop is deployed), but whether sshd is *enabled* on the host stays the
admin's/provisioning's call, as with install.sh.

## What install.sh does that this tree deliberately doesn't

- **The `nvidia_drv.so` bind-mount fallback for old toolkits.** Pin your
  toolkit version instead, or add the `Volume=` lines shown in the quadlet
  unit's GPU comment. (GPU detection itself IS carried over, as the
  converging CDI refresh unit — see "GPU" above.)
- **Building images.** Provisioning supplies the image; CI builds it.
- **State backup / `--uninstall`.** Reprovision instead.
- **The kubelet/k3s "two desktops" check.** Same rule applies (never run
  the quadlet service and the k8s chart on one host — two X servers would
  fight over the VT and DRM master); enforce it in provisioning.

## Overriding the image reference

The unit defaults to `localhost/desktop-container:latest` to match the rest
of the repo. Production should pin by digest with a drop-in rather than
editing the unit:

```ini
# /etc/containers/systemd/desktop.container.d/50-image.conf
[Container]
Image=registry.example.com/desktop-container@sha256:...
```

## Verify

First stop: `desktop-preflight` (ships with the tree, root, read-only) —
one PASS/WARN/FAIL line per host-side assumption with a remediation hint,
exit 1 on any FAIL. Then the main README's checklist, plus the
deploy-specific bits:

```sh
desktop-preflight                           # the whole host-side story
systemctl status desktop.service            # generated from the quadlet
systemctl cat desktop.service               # what the quadlet actually generated
systemctl is-enabled getty@tty1.service     # masked
systemctl get-default                       # multi-user.target
systemctl status desktop-seat-prep          # seat converged; culprit named if not
systemctl status desktop-cdi-refresh        # ran; log says real spec vs stub
head -5 /etc/cdi/nvidia.yaml                # real (nvidia-ctk) or stub marker
systemctl status desktop-host-shell         # fresh key generated this boot
ls -l /etc/ssh/authorized_keys.d/           # root-owned desktop-shell entry
podman logs desktop | grep preflight:       # container-side assumptions;
                                            # FAILs on stub spec + visible GPU
```

## How CI validates this tree

- `ci.yml` static job: shellcheck on all four scripts, plus a guard that
  the `[Container]` sections of this quadlet and `quadlet/desktop.container`
  (the install.sh flow) only differ by the intended GPU lines.
- `ci.yml` build-smoke: a quadlet `-dryrun` fast-fail, then
  `ci/smoke-deploy.sh` — CDI converger branch tests (stub / generate /
  transient-failure / no-downgrade), seat-prep against a staged dirty seat,
  and the full composition on the runner: rsync-apply (the verbatim command
  above), boot from this quadlet, all three oneshots, stub marker on
  container PID 1, `desktop-shell` ssh from the host and from inside the
  container, `desktop-preflight` green, and a service restart.
- `e2e-vm.yml` phase-deploy: the same flow on a Rocky 9 VM with **SELinux
  enforcing** and a real KMS display — seat-prep evicting a genuinely
  running getty, rootless Xorg + mwm + seat0 under this quadlet, the
  root-owned `desktop-shell` trust path through a real sshd under
  enforcing, `desktop-preflight` at 0 FAILs, and a non-blank screendump
  artifact.
