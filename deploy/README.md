# Declarative host deployment

This tree is the desktop's **host end state expressed as plain files**: a
podman quadlet plus systemd drop-ins, masks, symlinks, and tmpfiles.d
entries. It is the only way the desktop is deployed — hosts are
*provisioned*, not converted, so nothing here autodetects, mutates a host
imperatively, or records state in order to undo itself. Lay it onto the filesystem with whatever provisioning
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
cannot advertise the device again until it reboots.

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

**SELinux is handled** — `desktop-selinux.service` labels the three
directories the specs mount into clients (`/tmp/.X11-unix`,
`/run/desktop-audio`, `/var/lib/desktop-container/bin`) `container_file_t`
before the desktop starts. Confined clients need no `label=disable` and no
privileged pod spec. See "SELinux" below for how and why.

## SELinux

The tree ships enforcing-ready. There is one thing an enforcing host needs
that CDI cannot express, and `desktop-selinux.service` does it at every boot.

**The problem.** Three host directories are bind-mounted into *client*
containers by the CDI specs:

| Directory | Mounted | Client does |
|---|---|---|
| `/tmp/.X11-unix` | rw | `connect(2)` to the X socket |
| `/run/desktop-audio` | rw | `connect(2)` to the audio sockets |
| `/var/lib/desktop-container/bin` | ro | **executes** the toolkit binaries |

tmpfiles.d creates them as ordinary host directories, so they carry ordinary
host types. A confined container runs as `container_t`, which has no rule
letting it connect to or execute those types. On an enforcing host the client
resolves its device, receives the mounts and the env, and is then denied —
with everything looking correct from the outside. Podman's `-v src:dst:z`
would relabel a mount, but `containerEdits` has no equivalent, so CDI cannot
fix this from the spec. It has to happen host-side.

**The fix.** `usr/local/libexec/desktop-selinux` labels all three
`container_file_t` — the type confined containers may use — at level `s0`
with no MCS categories. That last detail is what makes it work under
kubernetes: CRI-O gives each pod its own category pair, and a file's
categories must be a subset of the process's; the empty set is a subset of
every set, so one label serves every client and **no pod needs
`seLinuxOptions` or `privileged`**. It is the same mechanism `:z` uses.

Sockets and binaries *inside* the directories inherit the directory's type,
so labeling the directories covers the sockets Xorg and PipeWire create in
them. The toolkit is the exception — the desktop publishes it *after* this
unit has run — so `desktop-tools-cdi` re-runs the labeler for that directory
once its contents exist, before advertising the device.

It runs every boot because `/run/desktop-audio` is on tmpfs: destroyed and
recreated by tmpfiles at each boot, so a one-off relabel would not survive.
Two mechanisms, preferred in order:

1. **`semanage fcontext` + `restorecon`** — best effort, so the label becomes
   *policy* and survives a full filesystem relabel. Needs
   `policycoreutils-python-utils` (see `HOST-REQUIRES.md`).
2. **`chcon`** for anything policy did not cover — no extra package needed,
   but not policy: undone by any `restorecon` and by a relabel. Converging
   every boot is what makes it hold.
3. **Verification**, and the unit fails if any directory is still wrong.
   Running the commands is not the same as the labels landing, and that
   distinction is not hypothetical — see below.

> **`/run` needs the equivalency workaround.** The distribution ships a
> file-context equivalency between `/var/run` and `/run`, and `semanage`
> *refuses* an fcontext rule written against one side of it, naming the other
> spelling in the error. The first version of this script swallowed that
> error, so `/run/desktop-audio` silently kept `var_run_t` while
> `/tmp/.X11-unix` relabeled fine — and it reported success. The script now
> retries as `/var/run/...` (a rule stored there still governs `/run`), and
> then verifies the result regardless.

On a host without SELinux the script exits 0 having done nothing.

**The host keeps full access.** Relabeling is for the benefit of confined
containers, and it must not cost the host the desktop it is hosting. A host
process is `unconfined_t`, which may use `container_file_t`, and the label
goes on at `s0` with no categories, which `unconfined_t`'s range dominates —
so rendering to the display, playing audio and running the published toolkit
from a host shell all keep working. The e2e asserts each of those from the VM
host under enforcing (`pactl` over the exported socket; the published
`screenshot` binary executed, then run against `:0`), separately from the
container tests, because a relabel is exactly the kind of change that could
fix containers by breaking the host.

Confined *host services* are the one case this does not serve — a daemon
running in its own domain would need its own policy. Nothing in the tree runs
that way.

**Kubernetes device plugins are the other asymmetry.** Labeling gets *client*
pods to the desktop, but a device plugin also has to register with **kubelet**,
by connecting to kubelet's own socket — which a confined container may not do,
and which is not something this tree should relabel (it is kubelet's state, not
container content). So `charts/cdi-device-plugin` gives the plugin pod
`seLinuxOptions.type: spc_t`. That grant is the plugin's alone: client pods
still declare no `securityContext` at all, and `ci/helm-assertions.sh` asserts
both halves so the two never blur together.

**Not covered.** The desktop container runs with `SecurityLabelDisable=true`,
so label separation is off for it — none of this applies there. Confining it
would need a policy module of its own for DRM, evdev and VT access; see
"Container privileges".

To check a running host:

```sh
systemctl status desktop-selinux
ls -Zd /tmp/.X11-unix /run/desktop-audio /var/lib/desktop-container/bin
ausearch -m avc -ts boot          # expect nothing
```

## Apply

```sh
# as root, from the repo:
rsync -a --chown=root:root deploy/host/ /

systemctl daemon-reload
reboot
```

On an SELinux host, `rsync -a` does not carry labels (that would need `-X`),
so the copied files are labeled by the kernel's transition rules rather than
by `restorecon`'s. Those usually agree, but it is cheap insurance not to
depend on it:

```sh
restorecon -R /etc/systemd /etc/ssh /etc/desktop-container \
              /usr/local/bin /usr/local/libexec /var/lib/desktop-container
```

(RPM-based provisioning sets labels correctly on its own; this is an
rsync-specific step.)

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

| File (under `host/`) | What it does |
|---|---|
| `etc/containers/systemd/desktop.container` | the quadlet unit that becomes `desktop.service`; `[Install]` is honored by the quadlet generator, so there is no `systemctl enable` |
| `etc/systemd/system/default.target` → `multi-user.target` | the default boot target, as a symlink rather than `systemctl set-default` |
| `etc/systemd/system/getty@tty1.service` → `/dev/null` | masks the getty (frees the VT), as a symlink rather than `systemctl mask` |
| `etc/systemd/logind.conf.d/50-desktop-container.conf` | logind `NAutoVTs=0` / `ReserveVT=0` drop-in |
| `etc/tmpfiles.d/desktop-container.conf` | shared socket dirs `/run/desktop-audio`, `/tmp/.X11-unix` |
| `etc/pulse/client.conf.d/50-desktop-container.conf` | host Pulse clients → container socket |
| `etc/alsa/conf.d/60-desktop-container.conf` | host ALSA clients → pulse plugin → container socket. A drop-in rather than `/etc/asound.conf`, so a host-local `asound.conf` still wins; the `/etc/alsa/conf.d` mechanism is EL/Fedora packaging |
| `usr/local/bin/desktop-preflight` | read-only debug tool: PASS/WARN/FAIL per host-side assumption; not wired into boot |
| `etc/systemd/system/desktop-seat-prep.service` | oneshot before `desktop.service`: converge + verify the seat (see "Seat state" below) |
| `usr/local/libexec/seat-prep.sh` | the script that unit runs (boot-time convergence agent, not an installer) |
| `etc/systemd/system/desktop-cdi-refresh.service` | oneshot before `desktop.service`: converge `/etc/cdi/nvidia.yaml` (real spec or no-op stub, see "GPU" above) |
| `usr/local/libexec/desktop-cdi-refresh` | the script that unit runs (boot-time convergence agent, not an installer) |
| `etc/systemd/system/desktop-selinux.service` | oneshot before `desktop.service` and before any CRI: label the three client-facing directories `container_file_t` so confined containers can use them (see "SELinux" above); pre-enabled for `multi-user.target` for the same reason `desktop-client-cdi` is |
| `usr/local/libexec/desktop-selinux` | the script that unit runs (no-ops without SELinux; also re-run by `desktop-tools-cdi` for the toolkit dir) |
| `etc/systemd/system/multi-user.target.wants/desktop-selinux.service` → `../desktop-selinux.service` | that enablement, as a symlink |
| `etc/systemd/system/desktop-client-cdi.service` | oneshot writing the two specs **client** containers resolve to reach this desktop, one per capability (see "Client containers" below); the only oneshot shipped enabled for `multi-user.target`, because kubelet must find the specs before it admits a client pod that requests one, which can happen on a boot where `desktop.service` has not come up yet |
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
holding `CAP_SYS_ADMIN` anyway, so this path is convenience + audit trail, not a
boundary). Three properties are worth calling out:

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
admin's/provisioning's call.

## Input hotplug and KVM switches

`Volume=/dev/input:/dev/input` gives the container a live view of the host's
input devices. Without it podman's own `/dev` is a snapshot taken at creation,
so devices added later never appear inside and libinput has nothing to open.

The case that makes this load-bearing rather than cosmetic is a **USB KVM
switch without HID emulation**: it disconnects and re-enumerates the keyboard
and mouse on every switch, so a snapshot `/dev` leaves input dead from the
first switch back until `desktop.service` restarts.

Only `/dev/input`, not all of `/dev` — podman's `/dev/console`, `/dev/pts` and
`/dev/shm` are what `--systemd=always` and `--tty` rely on, and a blanket
`/dev:/dev` would shadow them.

The device cgroup allows major 13 (input) explicitly for this reason — a bind
mount is not a device as far as the cgroup is concerned, so without that rule
it would resolve to nodes the container may not open. See README.md for the
video-switching caveat, which this does not address.

## Container privileges

The quadlet does not use `--privileged`. Devices are granted explicitly
(`AddDevice=-/dev/dri` and `-/dev/snd` — the `-` makes them optional, so a host
without a GPU or a sound card still starts and lets `desktop-preflight` name
what is missing — the `/dev/input` bind mount, and device cgroup rules for
majors 13/4/5/226/116), capabilities are dropped to a named set, and podman's
default seccomp filter stays in place. `SecurityLabelDisable=true` remains,
because confining this container needs a policy module of its own; AppArmor is
disabled alongside it (`--security-opt apparmor=unconfined`) for the same
reason, so a Debian-family host does not silently get a different answer than
a RHEL one.

`rtkit-daemon` is masked in the image — it cannot work without
`SYS_PTRACE`/`DAC_READ_SEARCH`/`NET_ADMIN`, and a *failed* unit would leave
`systemctl is-system-running` reporting `degraded`. PipeWire gets its realtime
priorities from the quadlet's `--ulimit rtprio=95` instead — together with a
systemd drop-in *inside* the image, because `--ulimit` reaches PID 1 and no
further (systemd applies its own `DefaultLimitRTPRIO=`, which is 0). Both
halves are needed; see README.md "Container privileges".

`CAP_SYS_ADMIN` is still required by systemd and logind as PID 1, so this
reduces attack surface without changing the trust boundary. See README.md
"Container privileges" for the full table and reasoning.

## Log growth

`journal-console.service` streams the container's journal into `/dev/console`
continuously, which is what `podman logs desktop` reads. The quadlet bounds that
sink explicitly — `LogDriver=k8s-file` plus `--log-opt max-size=64m` — rather
than inheriting whatever the host's `containers.conf` sets, because podman's own
default is an unbounded file and some distros default to `journald`, which would
push the desktop's entire journal into the host journal. The container's own
volatile journal is capped separately inside the image. See "Log growth" in
README.md for the full reasoning and the numbers.

## Deliberately out of scope

- **Building or pulling images.** Provisioning supplies the image; CI
  builds it. See "Overriding the image reference" below.
- **Uninstall / state backup.** Reprovision the host instead — that
  asymmetry is the point of the declarative form: the file list above *is*
  the state.
- **An automatic `nvidia_drv.so` bind-mount for old toolkits.** Pin a
  toolkit version that ships the Xorg driver module in its CDI spec, or add
  the `Volume=` lines shown in the quadlet unit's GPU comment. (GPU
  *detection* is in scope, as the converging CDI refresh unit — see "GPU"
  above.)
- **Running the desktop under kubernetes.** The desktop is a quadlet
  service on the host, full stop; k8s on the same node carries application
  containers, which reach this desktop through the client CDI devices (see
  "Client containers" below). Nothing schedules an X server, so nothing can
  contend for the VT or DRM master.

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

- `ci.yml` static job: shellcheck on every script in this tree.
- `ci.yml` build-smoke also asserts the SELinux labeler's no-op branch: the
  runner is Ubuntu with no SELinux, and a deploy there must not fail because
  of it.
- `ci.yml` build-smoke: a quadlet `-dryrun` fast-fail, then
  `ci/smoke-deploy.sh` — CDI converger branch tests (stub / generate /
  transient-failure / no-downgrade), seat-prep against a staged dirty seat,
  and the full composition on the runner: rsync-apply (the verbatim command
  above), boot from this quadlet, all three oneshots, stub marker on
  container PID 1, `desktop-shell` ssh from the host and from inside the
  container, `desktop-preflight` green, and a service restart.
- `e2e-vm.yml` phase-deploy: the same flow on a Rocky 9 VM with **SELinux
  enforcing** and a real KMS display — seat-prep evicting the genuinely
  running boot getty, rootless Xorg + mwm + seat0 under this quadlet, real
  audio over all three client paths, the root-owned `desktop-shell` trust
  path through a real sshd under enforcing, **confined** podman clients
  resolving each client CDI device with no `label=disable` anywhere,
  `desktop-preflight` at 0 FAILs, and a non-blank screendump artifact. It
  asserts the resulting labels directly (all three directories and a
  published toolkit binary) before the clients that depend on them run. The
  desktop then stays up for the k3s phase, which runs confined client pods
  against it **still enforcing** — nothing in the suite calls `setenforce`.
