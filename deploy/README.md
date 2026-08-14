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
