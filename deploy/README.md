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

- podman >= 4.4 for quadlet at all; **podman >= 5.0 for the overlays** —
  quadlet only learned to merge drop-in directories
  (`desktop.container.d/*.conf`) in 5.0, and older versions ignore them
  *silently*: the desktop still starts, just without GPU injection /
  host-shell provisioning. On RHEL/Rocky that means 9.5 or newer (9.4's
  podman 4.9 predates it). After applying, `systemctl cat desktop.service`
  and check the drop-in content actually landed in the generated unit.
- the desktop image already present in podman's storage.

## Layout

```
host/         every desktop host
host-gpu/     overlay: hosts with NVIDIA driver + nvidia container toolkit
host-shell/   overlay: hosts where the "Host Terminal" menu entry should work
```

Each directory mirrors the host filesystem from `/`. Overlays are additive —
apply `host/` first, then the overlays that match the host class. Whether a
host gets an overlay is a provisioning decision, not runtime autodetection:
`host-gpu/` on a GPU-less host makes `desktop.service` fail (its
`AddDevice=nvidia.com/gpu=all` cannot be satisfied).

## Apply

```sh
# as root, from the repo:
rsync -a --chown=root:root deploy/host/ /
rsync -a --chown=root:root deploy/host-gpu/ /      # GPU hosts only
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

| File (overlay) | Purpose |
|---|---|
| `host-gpu/…/desktop.container.d/10-gpu.conf` | quadlet drop-in: CDI GPU injection + pulls in the CDI refresh unit |
| `host-gpu/…/desktop-cdi-refresh.service` | oneshot before `desktop.service`: `nvidia-ctk cdi generate` on every boot, so a host driver update never leaves a stale `/etc/cdi/nvidia.yaml` |
| `host-shell/…/desktop.container.d/20-host-shell.conf` | quadlet drop-in: pulls in the key-provisioning unit |
| `host-shell/…/desktop-host-shell.service` | oneshot before `desktop.service`: converge keypair + restricted `authorized_keys` for the account in `/etc/desktop-container/shell-user` |
| `host-shell/usr/local/libexec/desktop-host-shell-setup` | the script that unit runs (boot-time convergence agent, not an installer) |

The two overlay oneshots are pulled in by their quadlet drop-ins
(`Wants=`/`After=` on `desktop.service`), so they need no enablement either:
copying the files is the whole installation.

## What install.sh does that this tree deliberately doesn't

- **Disable a display manager / undo `loginctl attach` seat rules.** A
  production host is provisioned headless from the start: no display
  manager installed, no `/etc/udev/rules.d/72-seat-*.rules`. The quadlet
  carries `Conflicts=display-manager.service getty@tty1.service` as a
  runtime backstop, but converting a formerly-graphical host is
  install.sh's job, not this tree's.
- **GPU / toolkit autodetection.** Host class is declared by applying (or
  not applying) `host-gpu/`. Same for the `nvidia_drv.so` bind-mount
  fallback for old toolkits: pin your toolkit version instead, or add the
  `Volume=` lines shown in `10-gpu.conf`.
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
systemctl status desktop-cdi-refresh desktop-host-shell   # overlays, if applied
podman logs desktop | grep preflight:       # container-side assumptions
```
