# Declarative host deployment (no install.sh)

`install.sh` mutates a host imperatively, autodetects what it can, and
records state so it can undo itself — right for a dev box, wrong for
production. This tree is the **same host end state expressed as plain
files**: a podman quadlet plus systemd drop-ins, masks, symlinks, and
tmpfiles.d entries. Lay it onto the filesystem with whatever provisioning
you already use (rsync, RPM/ostree packaging, Ansible `copy`, image build),
reload systemd, and the desktop comes up on every boot of
`multi-user.target`. Nothing here is a script that runs once at install
time; the few steps that are inherently runtime (CDI spec generation, ssh
key material) are systemd oneshot units that converge at every boot.

Nothing in the tree builds or pulls images: **the desktop image must
already be in podman's storage** (`podman load` / `podman pull` during
provisioning). See "Overriding the image reference" below.

## Requirements

- podman >= 4.4; **podman >= 5.0 additionally for the `host-shell/`
  overlay and the image-pinning drop-in** — quadlet only learned to merge
  drop-in directories (`desktop.container.d/*.conf`) in 5.0, and older
  versions ignore them *silently*. On RHEL/Rocky that means 9.5 or newer
  (9.4's podman 4.9 predates it). After applying, `systemctl cat
  desktop.service` and check the drop-in content actually landed in the
  generated unit. The GPU path does NOT depend on drop-ins (see below).
- the desktop image already present in podman's storage.

## Layout

```
host/         every desktop host, with or without a GPU
host-shell/   overlay: hosts where the "Host Terminal" menu entry should work
```

Each directory mirrors the host filesystem from `/`. Overlays are additive —
apply `host/` first, then the overlays that match the host class.

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
rsync -a --chown=root:root deploy/host-shell/ /    # if Host Terminal is wanted
echo alice > /etc/desktop-container/shell-user     # host-shell: per-host config

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
never graphical, `systemctl daemon-reload && systemctl restart
systemd-tmpfiles-setup systemd-logind && systemctl start desktop.service`
works too; on a host that currently runs a display manager or getty, just
reboot (the quadlet's `Conflicts=` would stop them, but logind's
`NAutoVTs=`/`ReserveVT=` only take effect on logind restart, and a
half-live seat handover is not a state worth debugging).

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
| `etc/systemd/system/desktop-cdi-refresh.service` | oneshot before `desktop.service`: converge `/etc/cdi/nvidia.yaml` (real spec or no-op stub, see "GPU" above); pulled in by the quadlet's `[Unit] Wants=`, needs no enablement |
| `usr/local/libexec/desktop-cdi-refresh` | the script that unit runs (boot-time convergence agent, not an installer) |

| File (overlay) | Purpose |
|---|---|
| `host-shell/…/desktop.container.d/20-host-shell.conf` | quadlet drop-in: pulls in the key-provisioning unit (**podman >= 5.0**) |
| `host-shell/…/desktop-host-shell.service` | oneshot before `desktop.service`: converge keypair + restricted `authorized_keys` for the account in `/etc/desktop-container/shell-user` |
| `host-shell/usr/local/libexec/desktop-host-shell-setup` | the script that unit runs (boot-time convergence agent, not an installer) |

The overlay oneshot is pulled in by its quadlet drop-in (`Wants=`/`After=`
on `desktop.service`), so it needs no enablement either: copying the files
is the whole installation.

## What install.sh does that this tree deliberately doesn't

- **Disable a display manager / undo `loginctl attach` seat rules.** A
  production host is provisioned headless from the start: no display
  manager installed, no `/etc/udev/rules.d/72-seat-*.rules`. The quadlet
  carries `Conflicts=display-manager.service getty@tty1.service` as a
  runtime backstop, but converting a formerly-graphical host is
  install.sh's job, not this tree's.
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

Same checklist as the main README ("Verification checklist"), plus the
deploy-specific bits:

```sh
systemctl status desktop.service            # generated from the quadlet
systemctl is-enabled getty@tty1.service     # masked
systemctl get-default                       # multi-user.target
systemctl status desktop-cdi-refresh        # ran; log says real spec vs stub
head -5 /etc/cdi/nvidia.yaml                # real (nvidia-ctk) or stub marker
systemctl status desktop-host-shell         # host-shell overlay, if applied
podman logs desktop | grep preflight:       # container-side assumptions;
                                            # FAILs on stub spec + visible GPU
```
