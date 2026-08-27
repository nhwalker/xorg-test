# Host package requirements (EL9)

What must be `dnf install`ed on top of a standard minimal RHEL/Rocky 9
(`@core`) install for the deploy tree to work. Direct requirements only —
dependency resolution pulls the rest (conmon/crun/container-selinux behind
podman, the `openssh` client tools behind openssh-server, and so on).

## Every host

```sh
dnf install podman openssh-server psmisc alsa-plugins-pulseaudio \
            policycoreutils-python-utils
```

| Package | Why | If you skip it |
|---|---|---|
| `podman` | quadlet generator + container runtime. >= 4.4 (any EL 9.4+); >= 5.0 only if you use the optional image-pinning drop-in (EL 9.5+) | nothing works |
| `openssh-server` | sshd for the Host Terminal's loopback ssh; also pulls the `ssh-keygen` used by the per-boot key oneshot | only Host Terminal breaks — skippable on hosts that comment out its two `Wants=`/`After=` lines in the quadlet |
| `psmisc` | `fuser`, used by `seat-prep.sh`'s DRM/VT verification gate and by `desktop-preflight` | everything runs; the holder checks degrade to a logged warning |
| `alsa-plugins-pulseaudio` | the pulse route for **host-side** ALSA clients to reach the container's audio | desktop + container audio unaffected; only host ALSA clients lose sound |
| `policycoreutils-python-utils` | `semanage`, used by `desktop-selinux` to make the client-directory labels part of POLICY (see deploy/README.md "SELinux") | on an SELinux host the labeler falls back to `chcon`: still correct every boot, but the labels are not policy, so a `restorecon` or a filesystem relabel undoes them until the next boot. No effect on a host without SELinux |

## GPU hosts, additionally

```sh
dnf install nvidia-container-toolkit
```

| Package | Why |
|---|---|
| `nvidia-container-toolkit` | `nvidia-ctk`, used by `desktop-cdi-refresh` to generate the real CDI spec every boot. Use a version recent enough to include the Xorg driver module (`nvidia_drv.so`) in the generated spec — otherwise the container falls back to modesetting and you need the bind-mount fallback commented in the quadlet |
| NVIDIA driver stack | from NVIDIA's EL9 repository (e.g. `dnf module install nvidia-driver:latest-dkms`, or your pinned precompiled equivalent). Exact package names depend on the repo; whatever you choose must end up shipping the kernel module **and** the Xorg driver pieces (`nvidia_drv.so`, `libglxserver_nvidia.so`) on the host |

Without these on a host that has NVIDIA hardware, the desktop still boots
(stub CDI spec, modesetting, unaccelerated) and both preflights flag it as
a FAIL. On a genuinely GPU-less host, install neither — the stub path is
the intended state there.

## Explicitly NOT required on the host

- **No X/graphics stack, no display manager** — the container owns the
  display; a host display manager would fight it for the seat.
- **No PipeWire/PulseAudio daemon** — the container owns `/dev/snd`; host
  *clients* talk to its sockets via the configs this tree ships.
- **No build tooling, no git** — the image arrives prebuilt.
- **`@core` covers the rest** — systemd (sysusers/tmpfiles/udevadm),
  policycoreutils (`restorecon`), glibc-common (`getent`), coreutils —
  all assumed present as part of any standard EL9 install.
