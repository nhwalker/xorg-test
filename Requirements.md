# Requirements: containerized desktop — test coverage specification

**Purpose.** This document enumerates every behaviour the containerized desktop
is expected to have, in a form a test can be written against, and records for
each one whether a test already exists. It is the backlog for reaching
complete test coverage of the desktop: implement the ❌ and 🟡 stories, keep
the ✅ ones green, and run the 🔧 ones by hand on real hardware.

**Scope.** "Containerized desktop" means:

| In scope | Where it lives |
|---|---|
| the desktop image: base and application layers, boot supervisor, X session, audio stack, boot-time generators, published toolkit | `Containerfile`, `Containerfile.base`, `image/` |
| the host deploy tree that runs it: quadlet, converger oneshots, seat/session/SELinux/CDI/host-shell units, tmpfiles/sysusers, host audio client configs, debug tools | `deploy/host/` |
| the client contract the desktop exports: the three CDI devices and what they inject, under podman and under kubernetes | `/etc/cdi/desktop-*.yaml`, `/var/lib/desktop-container/bin` |

Out of scope: the internals of `cdi-device-plugin/` and `screenshot/` (each has
its own Go test suite and README). They appear below only where they are the
instrument of a desktop test or where the desktop's contract *with* them is
what is under test.

**Structure.** Epic → Feature → Story. Every story has:

- **Requirement** — what must be true, stated so that it can be false.
- **Acceptance** — the observable(s) a test asserts.
- **Tier** — where the test runs (below).
- **Coverage** — current status and the test that provides it.

**Companion.** `HotpluggingTestHelp.md` holds the mechanics (QEMU commands,
layer-by-layer probes, failure signatures, the hardware procedure) behind every
hotplug story in F3.9, F3.10, F3.11 and F4.7.

**ID scheme.** `E<n>` epic, `F<n>.<m>` feature, `S<n>.<m>.<k>` story. IDs are
stable; retire a story by marking it *withdrawn* rather than renumbering.

## Test tiers

| Tier | Runs where | Can see | Today |
|---|---|---|---|
| **T0 static** | any machine, no root | files only | `ci.yml` `static`: shellcheck, `ci/monitor-layout-tests.sh`, ARG-scoping check, helm/kubeconform |
| **T1 script-unit** | any machine, no root, or a scratch container of the image | one script with fabricated inputs | *does not exist yet* — see Appendix A for the refactors it needs |
| **T2 build-smoke** | ubuntu runner, root, podman, systemd, **no KMS, no sound card, no SELinux** | the deploy tree booting a real container | `ci.yml` `build-smoke` + `ci/smoke-deploy.sh` |
| **T3 VM e2e** | Rocky 9 KVM guest, virtio GPU/input/HDA, **SELinux enforcing**, k3s + CRI-O | real Xorg on a real KMS device, hotplug via QEMU, confined clients | `e2e-vm.yml` → `ci/vm/vm-e2e.sh` + `ci/vm/vm-guest.sh` |
| **T4 hardware** | a provisioned physical host | NVIDIA, physical KVM switch, real monitors/EDID, USB audio | manual checklist (Appendix C) |

A story's tier is the *lowest* tier that can prove it honestly. Pushing a
story down a tier (e.g. from T3 to T1) is a valid improvement if the proof
stays real.

## Coverage legend

| Mark | Meaning |
|---|---|
| ✅ | asserted by an existing test; the reference names the function or step |
| 🟡 | partially asserted, or asserted only as a side effect of another test; the gap is named |
| ❌ | no test; the acceptance column is the spec for the one to write |
| 🔧 | needs real hardware; manual acceptance procedure in Appendix C |

Reference shorthand: `smoke` = `ci/smoke-deploy.sh`; `guest:<fn>` =
`ci/vm/vm-guest.sh` function; `e2e` = `ci/vm/vm-e2e.sh`; `dryrun` = the
"deploy tree quadlet dry-run + CDI spec checks" step of `ci.yml`;
`layout-tests` = `ci/monitor-layout-tests.sh`.

---

## E1 — Image build and supply chain

### F1.1 Base / application split

**S1.1.1 The application layer builds fully offline**
- Requirement: `Containerfile`, `Containerfile.plugin` and `Containerfile.screenshot` build with `--network=none` against their prebuilt bases.
- Acceptance: all three builds succeed under `podman build --network=none`.
- Tier: T2 · Coverage: ✅ `ci.yml` "application layers (offline gate)" (also `e2e-vm.yml`, `base-rebuild.yml`).

**S1.1.2 Bases rebuild from current upstream**
- Requirement: the three base images build from scratch against the live UBI image and Rocky repos, and the offline layers still build on the result.
- Acceptance: weekly `--pull --no-cache` rebuild succeeds and the offline builds pass on it.
- Tier: T2 · Coverage: ✅ `base-rebuild.yml`.

**S1.1.3 Base images are content-addressed**
- Requirement: `ci/build-bases.sh` reuses a GHCR base whose tag is the hash of its inputs (`Containerfile.*.base`, `rocky9.repo`, `go.mod`/`go.sum`) and rebuilds only on a miss.
- Acceptance: unchanged inputs → "reused cached base"; a changed input → a different tag and a rebuild.
- Tier: T1 · Coverage: 🟡 exercised on every CI run but never asserted (a script that always rebuilt would pass). Test: compute `content_tag` for two input sets, assert different; stub `podman pull` success and assert no build.

**S1.1.4 Build ARGs are global**
- Requirement: every `ARG` in every `Containerfile*` precedes the first `FROM`.
- Acceptance: the ARG-scoping check passes.
- Tier: T0 · Coverage: ✅ `ci.yml` "build args stay global".

**S1.1.5 Rocky repos fill gaps only**
- Requirement: UBI packages win over Rocky (priority 99 vs 200); Rocky supplies only what UBI lacks (Xorg, motif, pipewire).
- Acceptance: in the base image, `rpm -qi glibc` (and other UBI-shipped packages) reports a Red Hat vendor; `rpm -qi xorg-x11-server-Xorg` reports Rocky.
- Tier: T2 · Coverage: ❌.

**S1.1.6 The client toolkit is staged from the screenshot image**
- Requirement: `Containerfile`'s `tools` stage copies `/screenshot` into `/usr/libexec/desktop-tools/` with mode 0755, from `TOOLS_IMAGE`.
- Acceptance: `podman run --rm desktop-container ls -l /usr/libexec/desktop-tools/screenshot` shows `-rwxr-xr-x`; a build with `--build-arg TOOLS_IMAGE=<other>` stages that image's binary instead.
- Tier: T2 · Coverage: 🟡 the publish step in `smoke` proves the file exists; the staging mode and the `TOOLS_IMAGE` override are unasserted.

### F1.2 Image contents

**S1.2.1 Session user identity**
- Requirement: the image has user `desktop` uid 61000, primary group `desktop` gid 61000, supplementary groups `video input audio render tty`, home `/home/desktop`.
- Acceptance: `id desktop` in a scratch container matches exactly.
- Tier: T2 · Coverage: ❌ (the `align-device-groups` summary logs `id desktop` but nothing asserts it).

**S1.2.2 Session dotfiles come from `/etc/skel`**
- Requirement: `/home/desktop/.mwmrc` and `/home/desktop/.Xdefaults` are byte-identical to `image/session/mwmrc` and `image/session/Xdefaults`.
- Acceptance: `cmp` inside a scratch container.
- Tier: T2 · Coverage: ❌.

**S1.2.3 PipeWire native socket exported**
- Requirement: `/usr/share/pipewire/pipewire.conf` lists `/run/desktop-audio/pipewire-0` in `protocol-native` sockets (the build fails otherwise).
- Acceptance: `grep desktop-audio /usr/share/pipewire/pipewire.conf` matches; the build step's own `grep -q` gate holds.
- Tier: T2 · Coverage: ✅ build-time gate in `Containerfile`; runtime proven by S4.1.1.

**S1.2.4 module-rt takes the rlimit path**
- Requirement: `rlimits.enabled = true`, `rtportal.enabled = false`, `rtkit.enabled = false` appear exactly once in the `module-rt` block of both `pipewire.conf` and `client-rt.conf`.
- Acceptance: the build's "exactly once" gate; runtime outcome in S4.4.2.
- Tier: T2 · Coverage: ✅ build-time gate; ✅ outcome `guest:verify_privileges`.

**S1.2.5 pipewire-pulse export drop-in installed**
- Requirement: `/etc/pipewire/pipewire-pulse.conf.d/10-desktop-audio-export.conf` serves `unix:native` and `unix:/run/desktop-audio/pulse`.
- Acceptance: file present with both addresses; runtime proven by S4.1.1.
- Tier: T2 · Coverage: 🟡 runtime only.

**S1.2.6 All shipped scripts are executable and shellcheck-clean**
- Requirement: every script under `image/` and `deploy/host/usr/local/` passes `shellcheck -S error`; every script `Containerfile` installs is mode 0755.
- Acceptance: shellcheck list in `ci.yml` is complete (a new script not on the list is a regression); `find /usr/local/bin -type f ! -perm -u+x` in the image is empty.
- Tier: T0/T2 · Coverage: ✅ shellcheck; ❌ the list's completeness and the modes.

**S1.2.7 Image carries no NVIDIA userspace**
- Requirement: no `nvidia_drv.so`, `libnvidia*`, `libglxserver_nvidia*` in the image.
- Acceptance: `find /usr/lib64 /usr/lib -name '*nvidia*'` in a scratch container is empty.
- Tier: T2 · Coverage: ❌ (a stray package would silently mask S3.1.2).

**S1.2.8 Entry point and stop signal**
- Requirement: `CMD` is `/usr/local/bin/desktop-init`; `STOPSIGNAL` is `SIGTERM`.
- Acceptance: `podman inspect desktop --format '{{.Config.StopSignal}}'` is `SIGTERM`, `{{.Config.Cmd}}` is the init script.
- Tier: T2 · Coverage: ❌.

---

## E2 — Container boot and supervision (`desktop-init`)

### F2.1 Boot oneshots

**S2.1.1 Oneshots run in the documented order**
- Requirement: `ensure-vt-devices` → `align-device-groups` → `host-shell-setup` → `preflight-check` → `xorg-gpu-conf` → `xorg-monitor-conf` → `publish-tools`, each once per container start.
- Acceptance: the first log line of each appears in `podman logs desktop` in that order, once, before `oneshots done`.
- Tier: T2 · Coverage: ❌ (order matters: preflight reads aligned gids; monitor-conf reads gpu-conf's output).

**S2.1.2 A failing oneshot never blocks the session**
- Requirement: any oneshot exiting nonzero is logged and the session still launches; `publish-tools` failure logs `ERROR: publish-tools failed`.
- Acceptance: with `/usr/libexec/desktop-tools` emptied (bind an empty dir over it), the container still writes `/run/desktop-init-ready` and starts the session; the ERROR line is present.
- Tier: T2 · Coverage: ❌.

**S2.1.3 Boot markers**
- Requirement: `/run/desktop-init.pid` holds desktop-init's own pid (a host pid); `/run/desktop-init-ready` is written after the oneshots and the session launch, and is *not* gated on the session surviving.
- Acceptance: pid file resolves on the host to `desktop-init`; ready marker appears on a KMS-less host whose X session fails.
- Tier: T2 · Coverage: ✅ `smoke` (ready marker, pid visible on host, comm check); ✅ `guest:verify_privileges`.

**S2.1.4 `/run` and `/tmp` are fresh per container start**
- Requirement: both are tmpfs (`Tmpfs=` in the quadlet), so no stale pid file, ready marker or `.X0-lock` survives a restart.
- Acceptance: write a sentinel under `/run` and `/tmp` in the container, `systemctl restart desktop.service`, sentinel gone; `/proc/self/mounts` shows tmpfs on both.
- Tier: T2 · Coverage: ❌.

### F2.2 Runtime directory and seat handover

**S2.2.1 The host login session's runtime dir is adopted**
- Requirement: when `/run/user/61000` appears (mounted by logind on the host, propagated by the rslave `/run/user` bind) within 15 s, desktop-init uses it and logs `runtime dir /run/user/61000 provided by the host login session`.
- Acceptance: a file created on the host under `/run/user/61000` is visible in the container; the log line appears (polled).
- Tier: T3 · Coverage: ✅ `guest:phase_deploy` (propagation probe + polled log line); 🟡 `smoke` asserts the host side only.

**S2.2.2 Standalone fallback fabricates the runtime dir**
- Requirement: with no host session unit (plain `podman run`, or `desktop-session.service` disabled), desktop-init creates `/run/user/61000` (0700, owned by desktop) after the wait and logs `no host login session appeared; creating ... standalone`; the desktop works.
- Acceptance: `systemctl disable --now desktop-session`, restart desktop; the fallback line is logged; audio sockets still export; X session starts (T3). Re-enable afterwards.
- Tier: T2 · Coverage: ❌.

**S2.2.3 tty1 is handed to the session user**
- Requirement: `/dev/tty1` in the container is owned `desktop:tty` before every session start.
- Acceptance: `stat -c %U:%G /dev/tty1` in the container is `desktop:tty`; still true after an X session restart.
- Tier: T2 · Coverage: ❌ (only implied by X coming up rootless in T3).

**S2.2.4 Audio export dir exists even without the host mount**
- Requirement: `/run/desktop-audio` is created 1777 inside the container if the bind mount is absent.
- Acceptance: `podman run` without the `/run/desktop-audio` volume: dir exists, mode 1777, sockets appear in it.
- Tier: T2 · Coverage: ❌.

### F2.3 X session supervision

**S2.3.1 The session is its own process session on tty1**
- Requirement: `start-session` is launched via `setsid -c` as uid 61000 with the documented environment (`HOME`, `USER`, `LOGNAME`, `SHELL`, `PATH`, `XDG_RUNTIME_DIR`, `XDG_SESSION_TYPE=x11`, `DESKTOP_VT=vt1`, `DESKTOP_DISPLAY=:0`) and its controlling tty is tty1.
- Acceptance: `ps -o sess=,tty= -p <Xorg pid>` shows sid == the session leader pid and tty1; the leader's `/proc/<pid>/environ` contains exactly those variables and no leaked `NVIDIA_*`/container env.
- Tier: T3 · Coverage: ❌ (sid property is asserted for the *audio* tree in `smoke`, not for X).

**S2.3.2 The session restarts after Xorg exits**
- Requirement: when the session exits, desktop-init logs `session exited (rc=N); restarting in 3s` and a new session starts; mwm is running again within ~45 s.
- Acceptance: kill Xorg as uid desktop; new Xorg and mwm pids appear; display answers.
- Tier: T3 · Coverage: ✅ `guest:verify_audio_lifecycle` (first half).

**S2.3.3 Session cleanup is scoped by session id, never by uid**
- Requirement: after a session exits, every pid in that session id is TERMed, then KILLed after 5 s; same-uid processes outside it (the audio tree, the host's `desktop-session-lead`) are untouched.
- Acceptance: kill Xorg; old xterm/mwm pids are gone; PipeWire pid unchanged; the host `desktop-session-lead` pid unchanged; a deliberately spawned `sleep` as uid 61000 *outside* both trees on the host survives.
- Tier: T3 · Coverage: 🟡 PipeWire half in `guest:verify_audio_lifecycle`; host-process half unasserted.

**S2.3.4 Session leader sanity check never fires in a normal boot**
- Requirement: `assert_session_leader` logs `WARNING: ... is not its own session leader` only when `setsid` forked; a normal boot logs no such warning for either tree.
- Acceptance: `podman logs desktop | grep 'not its own session leader'` is empty after boot and after one restart of each tree.
- Tier: T2 · Coverage: ❌.

**S2.3.5 Postmortem runs on abnormal exit only**
- Requirement: `session-postmortem` is invoked with `SERVICE_RESULT=exit-code EXIT_CODE=exited EXIT_STATUS=<rc>` when the session exits nonzero, never when it exits 0; it prints the tail of the newest Xorg log and a `LIKELY CAUSE` verdict for each known signature (`drmSetMaster`, device `Permission denied`, `no screens found`, `xf86OpenConsole`/`cannot open /dev/tty`), and a distinct line when no Xorg log exists.
- Acceptance: T1 — run the script with a fabricated log for each signature and assert the verdict; with no log assert the "no Xorg log file found" line; with `SERVICE_RESULT=success` assert no output. T2 — on the KMS-less runner the real postmortem lines appear in `podman logs`.
- Tier: T1/T2 · Coverage: ❌.

**S2.3.6 mwm exit ends the session and it restarts**
- Requirement: `xinitrc.desktop` `exec`s mwm, so "Quit session" (or mwm dying) ends the X session and desktop-init starts a fresh one.
- Acceptance: kill mwm as uid desktop; Xorg pid changes; new mwm appears; display answers.
- Tier: T3 · Coverage: ❌.

### F2.4 Audio supervision

**S2.4.1 The audio tree is its own session with its own supervisor**
- Requirement: `start-audio` runs via `setsid` (no controlling tty) as uid 61000 under `supervise_audio`, a background child of desktop-init; the leader pid is recorded in `/run/desktop-audio-leader.pid`.
- Acceptance: PipeWire's sid equals the recorded leader pid; `ps -o tty= -p <pipewire>` is `?`.
- Tier: T2 · Coverage: ✅ `smoke` "STRUCTURE"; 🟡 no-tty unasserted.

**S2.4.2 Any daemon exiting restarts the whole stack**
- Requirement: `start-audio` returns on the *first* of pipewire/wireplumber/pipewire-pulse exiting, logs which one (`<name> exited`), TERMs the survivors, and the supervisor starts a complete new set after 3 s.
- Acceptance: kill **pipewire** → three new pids, `pipewire exited` logged, export reachable (✅). Kill **wireplumber** alone → same outcome with `wireplumber exited` (❌). Kill **pipewire-pulse** alone → same (❌).
- Tier: T2/T3 · Coverage: 🟡 `smoke` "RECOVERY" and `guest:verify_audio_lifecycle` cover pipewire only; the log line and the other two daemons are unasserted.

**S2.4.3 Stale export sockets are cleared before every audio start**
- Requirement: `pulse`, `pipewire-0`, `pipewire-0-manager` and their `.lock` files in `/run/desktop-audio` are removed before each start, so PipeWire can re-bind.
- Acceptance: after a PipeWire restart, `pactl info` over `/run/desktop-audio/pulse` succeeds (a stale inode would give ECONNREFUSED).
- Tier: T2/T3 · Coverage: ✅ `smoke`, `guest:verify_audio_lifecycle` (`audio_reachable`).

**S2.4.4 WirePlumber waits for PipeWire's socket**
- Requirement: `start-audio` waits up to 10 s for `$XDG_RUNTIME_DIR/pipewire-0` before launching wireplumber, so a slow PipeWire start does not lose the session manager.
- Acceptance: T1 with a fake `pipewire` on `PATH` that delays binding by 2 s: wireplumber is launched *after* the socket exists (fake wireplumber asserts the socket at start). T3: wireplumber is alive after boot and after a stack restart.
- Tier: T1/T3 · Coverage: 🟡 presence of wireplumber is implied by `wpctl status`; the ordering is untested.

**S2.4.5 A daemon ignoring SIGTERM is escalated**
- Requirement: survivors that have not exited 5 s after TERM are KILLed; `start-audio` always returns.
- Acceptance: T1 with a fake daemon that traps TERM: `start-audio` exits within ~6 s and logs `ignored SIGTERM; killing`.
- Tier: T1 · Coverage: ❌.

**S2.4.6 Audio gid is re-aligned before every audio start**
- Requirement: `align-device-groups.sh audio` runs before each stack start, so a card that appears after a soundless boot is openable.
- Acceptance: T3 variant: boot the VM **without** `intel-hda`; the first audio start logs `audio: no device nodes present, skipping`; hot-add `usb-audio`; kill pipewire; after restart the container's `audio` gid equals the host node's gid and WirePlumber lists the card.
- Tier: T3 · Coverage: ❌ (the current VM has a card at boot, so this branch never runs).

**S2.4.7 Export sockets are connectable by other uids**
- Requirement: `umask 0000` in `start-audio` makes the exported sockets world-connectable.
- Acceptance: on the VM host, as the unprivileged `rocky` user, `PULSE_SERVER=unix:/run/desktop-audio/pulse pactl info` succeeds.
- Tier: T3 · Coverage: ❌ (every existing client probe runs as root, which bypasses socket permissions).

### F2.5 Shutdown

**S2.5.1 SIGTERM stops both trees cleanly**
- Requirement: on SIGTERM desktop-init kills the audio supervisor loop first, stops the X tree and the audio tree by sid, and exits 0; the audio stack is not restarted during shutdown.
- Acceptance: `podman stop desktop` completes well within `TimeoutStopSec` (no SIGKILL by podman: `podman inspect --format '{{.State.ExitCode}}'` is 0); no process with uid 61000 remains on the host except `desktop-session-lead`; no `restarting in 3s` line is logged after `SIGTERM:`.
- Tier: T2 · Coverage: ❌ (`smoke` restarts the service but asserts nothing about the stop).

**S2.5.2 The X socket is unlinked by the server, not pinned by a mount**
- Requirement: after a stop, `/tmp/.X11-unix/X0` on the host is either gone or dead; the next start creates a fresh working socket.
- Acceptance: stop, start, `xdpyinfo` works (the directory, not the file, is the mount).
- Tier: T2 · Coverage: 🟡 restart works in `smoke`/`guest:desktop_up`; stale-socket handling is implicit.

### F2.6 Logging

**S2.6.1 Everything lands in `podman logs`**
- Requirement: desktop-init, the oneshots, the session and the audio stack write to `/dev/console` (the `--tty` pty); there is no journald in the image.
- Acceptance: `podman logs desktop` contains lines from each of: `desktop-init:`, `preflight:`, `align-device-groups:`, `xorg-gpu-conf:`, `xorg-monitor-conf:`, `start-audio:`, `published`.
- Tier: T2 · Coverage: 🟡 individual greps exist across `smoke`/`guest`; no single assertion of the set.

**S2.6.2 The container log is bounded**
- Requirement: `LogDriver=k8s-file` and `--log-opt max-size=64m` both reach the running container.
- Acceptance: `podman inspect` shows `k8s-file` and a 64 MB size.
- Tier: T2/T3 · Coverage: ✅ `smoke` "logging", `guest:verify_log_bounds`, `dryrun`.

---

## E3 — Display server and session

### F3.1 GPU driver selection (`xorg-gpu-conf.sh`)

**S3.1.1 NVIDIA path**
- Requirement: with `/dev/nvidiactl` (or `nvidia0`) present **and** an injected `nvidia_drv.so`, write `20-gpu.conf` with `Driver "nvidia"` and a `ModulePath` pointing at the module dir containing it, plus the stock module path.
- Acceptance: T1 with fabricated `/dev` nodes and a fake `.../xorg/modules/drivers/nvidia_drv.so`: config matches. T4: real host.
- Tier: T1/T4 · Coverage: ❌ / 🔧.

**S3.1.2 NVIDIA nodes without the X driver fall back to modesetting**
- Requirement: nodes present, no `nvidia_drv.so` → log both `warning:` lines and take the modesetting branch.
- Acceptance: T1 as above without the `.so`; T4 with an old toolkit.
- Tier: T1/T4 · Coverage: ❌ / 🔧.

**S3.1.3 modesetting picks the first connected connector's card**
- Requirement: scan `/sys/class/drm/card*-*/status`; the first `connected` one names the card (`kmsdev`); otherwise default to `card0`.
- Acceptance: T1 with a fabricated sysfs (card0 disconnected, card1 connected → `kmsdev /dev/dri/card1`; none connected → `card0`). T3: `podman logs` shows `decision: modesetting driver on /dev/dri/card0` and the generated file names it.
- Tier: T1/T3 · Coverage: 🟡 T3 outcome implied by X starting; the decision line and T1 branches are unasserted.

**S3.1.4 No KMS device removes the config**
- Requirement: if the chosen card node does not exist, delete any stale `20-gpu.conf` and log that autodetection will likely fail.
- Acceptance: T1: pre-create the file, run with no `/dev/dri`, file absent, log line present. T2 (KMS-less runner): the same in the real container.
- Tier: T1/T2 · Coverage: ❌.

**S3.1.5 Evidence is logged before the decision**
- Requirement: the log lists DRM nodes, every connector's status and NVIDIA nodes before `decision:`.
- Acceptance: order of lines in `podman logs`.
- Tier: T2 · Coverage: ❌.

### F3.2 Rootless Xorg and device access

**S3.2.1 Xorg runs as the session user**
- Requirement: `Xwrapper.config` has `needs_root_rights = no`, `allowed_users = anybody`; the running Xorg's uid is `desktop`.
- Acceptance: `ps -o user= -C Xorg` is `desktop`.
- Tier: T3 · Coverage: ✅ `guest:phase_deploy`.

**S3.2.2 Group gids are aligned to the host's device nodes**
- Requirement: for each of video/render/input/audio, if a node exists and its gid is non-zero, the container group is renumbered to it; a group already holding that gid is moved to a free gid ≥ 60000; a missing group is created; root-group nodes and absent nodes are skipped with a log line; the final-state table and `id desktop` are logged; the narrow form touches only the named groups.
- Acceptance: T1 inside a scratch container of the image (root, `CAP_MKNOD`): fabricate nodes with chosen gids and assert `getent group` after each branch, including the gid-collision move and `align-device-groups.sh audio` leaving `video` untouched. T3: preflight `desktop user can read` PASS for card, event and controlC nodes.
- Tier: T1/T3 · Coverage: 🟡 T3 outcome via `desktop-preflight` 0-FAIL; branches unasserted.

**S3.2.3 VT nodes are created when the runtime does not expose them**
- Requirement: `ensure-vt-devices.sh` creates `/dev/tty0` (c 4:0) and `/dev/tty1` (c 4:1), mode 620, `root:tty`, on the container's own `/dev`, and is a no-op when they exist.
- Acceptance: in the running container `stat -c '%F %t:%T %a' /dev/tty1` is `character special device 4:1 620`; the log says `created /dev/tty1` (rootful podman) exactly once.
- Tier: T2 · Coverage: 🟡 preflight `PASS: /dev/tty1 present`; mode/major/minor unasserted.

**S3.2.4 Xorg does not listen on TCP**
- Requirement: `-nolisten tcp`; with `Network=host` nothing may listen on 6000+.
- Acceptance: on the VM host `ss -ltn` shows no listener on port 6000; `/tmp/.X11-unix/X0` is the only X endpoint besides the abstract one.
- Tier: T3 · Coverage: ❌.

**S3.2.5 The session activates its VT**
- Requirement: without `-novtswitch`, Xorg `VT_ACTIVATE`s tty1 at start, so the desktop is visible even if the console was on another VT.
- Acceptance: `fgconsole` on the VM host is `1` after boot; `chvt 2`, kill Xorg, after restart `fgconsole` is `1` again.
- Tier: T3 · Coverage: ❌.

**S3.2.6 The X socket is shared through the host directory**
- Requirement: Xorg's socket appears at the host's `/tmp/.X11-unix/X0` (the quadlet volume).
- Acceptance: `test -S /tmp/.X11-unix/X0` on the host; `DISPLAY=:0 xdpyinfo`-equivalent from a host process works (the published `screenshot` binary).
- Tier: T3 · Coverage: ✅ `guest:phase_deploy` (host capture with the toolkit binary).

### F3.3 Session startup (`xinitrc.desktop`)

**S3.3.1 Local access control is open**
- Requirement: `xhost +local:` ran, so any local uid connects without a cookie.
- Acceptance: `xhost` as the session user lists `LOCAL:`; a client container with only the socket (no `XAUTHORITY`) connects.
- Tier: T3 · Coverage: 🟡 proven by every client probe; the `xhost` state itself is unasserted.

**S3.3.2 Screensaver and DPMS are off**
- Requirement: `xset s off` and `xset -dpms` took effect.
- Acceptance: `xset q` shows `timeout:  0` and `DPMS is Disabled`.
- Tier: T3 · Coverage: ❌.

**S3.3.3 Root window colour and initial xterm**
- Requirement: root is `#101216`; one xterm at `100x30+60+60` is spawned; mwm is the session's last process.
- Acceptance: screendump pixel at an uncovered root coordinate is `16,18,22`; an xterm window exists at boot; `pgrep -u desktop -x mwm`.
- Tier: T3 · Coverage: 🟡 mwm ✅ `guest:session_up`; root colour and xterm unasserted (the screendump stddev test only proves "something is drawn").

### F3.4 Fixed monitor layout

**S3.4.1 Opt-in: absent or output-less config generates nothing**
- Requirement: no file, or only comments/globals, → no `30-monitors.conf`, stale one removed, no-op logged.
- Acceptance: as stated.
- Tier: T0/T2/T3 · Coverage: ✅ `layout-tests`; ✅ `smoke` "shipped default is a genuine no-op"; ✅ `guest:verify_fixed_layout` (restore).

**S3.4.2 modesetting emission**
- Requirement: per-output `Monitor` sections with identifier = output name, wide sync ranges, a CVT `Modeline`, `Enable true`, `PreferredMode`, `Position`, optional `Rotate` and `Primary`; a `Screen` on `gpu0` with `Virtual` pinned to the layout extents; no `MetaModes`.
- Acceptance: `layout-tests` "modesetting" block.
- Tier: T0 · Coverage: ✅.

**S3.4.3 CVT timings match `cvt(1)`**
- Requirement: the integer derivation equals cvt's output for the declared modes.
- Acceptance: verbatim Modeline equality for 1920x1080@60 and 1280x1024@60; fractional 59.94 carried into the mode name.
- Tier: T0 · Coverage: ✅ `layout-tests` (two modes). ❌ a wider table (e.g. 2560x1440, 3840x2160, 1080x1920, 75 Hz, 4:3 and 5:4 aspect branches) to exercise every `vsync` branch of `cvt_mode`.

**S3.4.4 Rotation transposes extents**
- Requirement: `rotate=left|right` swaps width/height in the framebuffer computation.
- Acceptance: `layout-tests` "rotation".
- Tier: T0 · Coverage: ✅.

**S3.4.5 NVIDIA emission**
- Requirement: one `MetaModes` option, `ModeValidation AllowNonEdidModes`, opt-in `ConnectedMonitor` and `CustomEDID`, pinned `Virtual`, no `Monitor` sections, no Modelines.
- Acceptance: `layout-tests` "nvidia" blocks; T4 on a real NVIDIA host the layout survives a KVM switch.
- Tier: T0/T4 · Coverage: ✅ / 🔧.

**S3.4.6 Degraded host: no Device section**
- Requirement: without `gpu0`, emit Monitor sections only and warn that the framebuffer is not pinned.
- Acceptance: `layout-tests` "no GPU device section".
- Tier: T0 · Coverage: ✅.

**S3.4.7 A bad config is rejected whole**
- Requirement: every validation failure (bad mode, bad position, unknown flag, two primaries, duplicate output, bad refresh, implausible mode, `virtual` smaller than layout, bad `virtual`/`nvidia-*` syntax, bad output name) logs `ERROR`, removes the output file, exits 0.
- Acceptance: `layout-tests` rejection table (8 cases). ❌ add: bad `virtual` value, `nvidia-connected` with no list, `nvidia-edid` without `=`, output name starting with a digit, output name with illegal characters.
- Tier: T0 · Coverage: 🟡.

**S3.4.8 The host file reaches the container and is acted on at start**
- Requirement: `/etc/desktop-container/monitors.conf` is visible read-only in the container and consumed at every `desktop.service` start, with no quadlet change.
- Acceptance: write a layout on the host, restart, generated config names the outputs.
- Tier: T2 · Coverage: ✅ `smoke` "a declared layout is applied at the next start".

**S3.4.9 A declared output comes up on a disconnected connector**
- Requirement: with `Virtual-1`/`Virtual-2` declared side by side, X starts at 2048x768; `xrandr` shows `Virtual-2 disconnected 1024x768+1024+0`; `Virtual-1` is primary.
- Acceptance: `guest:verify_fixed_layout`.
- Tier: T3 · Coverage: ✅.

**S3.4.10 A live disconnect does not move the geometry**
- Requirement: forcing `Virtual-1` off under the running server leaves the screen at 2048x768 and both outputs at their declared positions.
- Acceptance: `guest:verify_fixed_layout` (sysfs force, query, dims).
- Tier: T3 · Coverage: ✅.

**S3.4.11 Preflight warns about unknown output names**
- Requirement: an output name with no matching `/sys/class/drm/card*-<name>` yields `preflight: WARN: fixed monitor layout names output(s) ...`; all-known names yield the PASS line listing them.
- Acceptance: `smoke` already declares `DP-1`/`DP-2` on a runner whose DRM device (if any) has other names: assert the WARN line; T3 with the Virtual layout assert the PASS line.
- Tier: T2/T3 · Coverage: ❌.

**S3.4.12 `desktop-monitors-capture` prints a valid, round-trippable block**
- Requirement: the tool prints one line per enabled output (`name WxH@rate +X+Y [primary] [rotate=...]`), refuses when not root, fails cleanly when the desktop is down, and its output fed back through the generator reproduces the same geometry.
- Acceptance: T3 while the two-output layout is live: output contains `Virtual-1  1024x768@60.00   +0+0 primary` and `Virtual-2  1024x768@60.00   +1024+0`; T1: feed canned `xrandr --query` text (including a rotated output) through the awk and compare. T3: with `desktop.service` stopped, exit 1 with the "is desktop.service running?" hint.
- Tier: T1/T3 · Coverage: ❌ (needs an override hook for the `podman exec … xrandr` source; Appendix A).

### F3.5 Rendering and theme

**S3.5.1 The server is drawing**
- Requirement: a screendump of the live display has grayscale stddev > 0.02.
- Acceptance: `e2e:assert_nonblank` after deploy, after k3s client, after cdi-verify, after the screenshot pattern.
- Tier: T3 · Coverage: ✅.

**S3.5.2 `~/.Xdefaults` is honoured because nothing sets `RESOURCE_MANAGER`**
- Requirement: the root window has no `RESOURCE_MANAGER` property (no `xrdb` in the session), so Xt reads `~/.Xdefaults` directly.
- Acceptance: `xprop -root RESOURCE_MANAGER` reports "no such atom"; an xterm's background pixel sampled from a screendump is `22,25,29` (`#16191d`), not white.
- Tier: T3 · Coverage: ❌ (documented trap, currently unguarded).

**S3.5.3 mwm frame colours are applied**
- Requirement: the focused frame is `#41637f`, unfocused `#22262d`, menus `#22262d`.
- Acceptance: sample a title-bar pixel of the focused xterm in a screendump; focus a second window and sample both.
- Tier: T3 · Coverage: ❌ (low priority; S3.5.2 covers the delivery mechanism).

**S3.5.4 Palette keeps the render test's margin**
- Requirement: the theme's screendump stddev stays ≥ 2× the 0.02 threshold.
- Acceptance: `assert_nonblank` logs the measured value; assert ≥ 0.04 on the deploy screendump.
- Tier: T3 · Coverage: 🟡 threshold is 0.02; the margin is logged, not asserted.

### F3.6 Window manager

**S3.6.1 mwm runs as the session user and owns the root menu**
- Requirement: `mwm` is running as `desktop` with `~/.mwmrc` loaded (root menu has "Desktop", "New Terminal", "Host Terminal", "Refresh", "Pack Icons", "Restart mwm", "Quit session").
- Acceptance: `pgrep -u desktop -x mwm`; the menu test is manual (T4) or via a screendump after a synthetic root click (QMP button on the root).
- Tier: T3/T4 · Coverage: ✅ process; ❌ menu contents.

**S3.6.2 Click-to-focus and keyboard delivery**
- Requirement: a left click on a window focuses it and subsequent keys reach it.
- Acceptance: `e2e` input test (click centre of sink xterm, type, read back).
- Tier: T3 · Coverage: ✅.

**S3.6.3 "Restart mwm" re-reads `.mwmrc` without a new X session**
- Requirement: `f.restart` replaces mwm in place; Xorg pid unchanged.
- Acceptance: trigger via a synthetic menu interaction or `mwm`'s restart protocol; assert new mwm pid, same Xorg pid.
- Tier: T3/T4 · Coverage: ❌ (likely T4 unless a reliable synthetic path is found).

**S3.6.4 Host Terminal menu entry**
- Requirement: the entry runs `xterm -T host -e /usr/local/bin/host-terminal`, which `ssh host`es as `desktop-shell`.
- Acceptance: `ssh host whoami` from the container as desktop returns `desktop-shell` (✅); the wrapper's failure path keeps the window open with the enablement hint (❌, see S5.7.8).
- Tier: T2/T3 · Coverage: 🟡.

### F3.7 Window-to-pod identity

**S3.7.1 X clients report real host pids**
- Requirement: under `--pid=host`, X-Resource `QueryClientIds` returns a nonzero pid for every client.
- Acceptance: `screenshot --list-clients` lists ≥ 3 clients, none `pid=0`.
- Tier: T3 · Coverage: ✅ `guest:verify_pod_identity`.

**S3.7.2 A client pid resolves to its pod from inside the container**
- Requirement: `/proc/<pid>/cgroup` read in the container carries the owning pod's UID (verbatim or underscore form).
- Acceptance: the testpattern pod's UID is found for one listed client, from the host and from inside the container.
- Tier: T3 · Coverage: ✅ `guest:verify_pod_identity`.

**S3.7.3 Loss of `--pid=host` is detected at boot**
- Requirement: if desktop-init is pid 1, preflight reports `FAIL: container init is PID 1`.
- Acceptance: `podman run` the image **without** `--pid=host`; the FAIL line appears in its log.
- Tier: T2 · Coverage: ❌ (the positive case is covered; the detector itself is untested).

### F3.8 Input

**S3.8.1 Typed input reaches the focused application**
- Requirement: QEMU HID → evdev → Xorg → focused xterm.
- Acceptance: `e2e` "input: type into an xterm".
- Tier: T3 · Coverage: ✅.

> **Retired IDs:** S3.8.2 (hot-added input reaches the container), S3.8.3
> (KVM-style remove/re-add cycle) and S3.8.4 (the re-added device itself
> carries input) were split per device and per direction into **F3.9**; their
> coverage is carried by S3.9.1–S3.9.6.

**S3.8.5 The host udev database is mounted read-only and used**
- Requirement: `/run/udev` is mounted `ro` and non-empty; no udevd runs in the container.
- Acceptance: `/proc/self/mounts` in the container shows `/run/udev … ro`; `pgrep udevd` in the container's view is only the host's (and the container has no `/usr/lib/systemd/systemd-udevd` running as its child); preflight PASS line.
- Tier: T3 · Coverage: 🟡 preflight PASS via 0-FAIL; `ro` flag unasserted.

**S3.8.6 Foreign seat tags are detected and undone**
- Requirement: a device attached to another seat (`loginctl attach seat1 …` → `72-seat-*.rules`, `ID_SEAT=seat1`) is reported by the container preflight as a WARN until `seat-prep` removes the rule and re-triggers udev, after which `ID_SEAT` is gone.
- Acceptance: on the VM: attach the virtio keyboard to `seat1`, assert `udevadm info` shows `ID_SEAT=seat1`; restart `desktop-seat-prep`; assert the rule is gone and `ID_SEAT` absent; restart desktop; preflight `PASS: no foreign seat tags`.
- Tier: T3 · Coverage: 🟡 `smoke` removes a staged rule *file* only; the udev effect and the preflight WARN are unasserted.

### F3.9 HMI hotplug: keyboards and pointers

Mechanics, QEMU commands and layer-by-layer probes for every story here are in
`HotpluggingTestHelp.md` §4.1–4.2. Plug-in and plug-out are separate stories
throughout because they fail differently: a stale node that never disappears is
what a snapshot `/dev` looks like, and it lets a plug-in assertion pass for the
wrong reason.

**S3.9.1 Keyboard plug-in reaches the container**
- Requirement: a keyboard added while the desktop runs appears as a new `/dev/input/event*` inside the container.
- Acceptance: the container node count rises after `device_add` (USB `usb-kbd` on xHCI, and PCI `virtio-keyboard-pci`).
- Tier: T3 · Coverage: ✅ `e2e` "input hotplug" and "KVM switch simulation" (re-add half).

**S3.9.2 Keyboard plug-in is adopted by Xorg**
- Requirement: Xorg/libinput opens the new device and lists it as an input device.
- Acceptance: `xinput list` (from a display client) gains an entry named for the QEMU device, or the Xorg log gains an `Adding input device` **and** a matching `XINPUT: Adding extended input device` line for it.
- Tier: T3 · Coverage: 🟡 the `Adding input device` count is recorded, not asserted, and it also increments for devices Xorg then ignores.

**S3.9.3 Keyboard plug-out removes the node from the container**
- Requirement: after `device_del`, the node is gone inside the container.
- Acceptance: the container node count drops to the pre-add value.
- Tier: T3 · Coverage: ✅ `e2e` "KVM switch simulation" (USB keyboard).

**S3.9.4 Keyboard plug-out is seen by Xorg**
- Requirement: Xorg/libinput closes the device: it leaves `xinput list` and the log records `removing device` for it.
- Acceptance: as stated, polled.
- Tier: T3 · Coverage: ❌.

**S3.9.5 A hot-added keyboard delivers keystrokes**
- Requirement: keys sent specifically through the re-added device reach the focused application.
- Acceptance: `input-send-event` with `"device": "kvmkbd"` after the re-add; the sink xterm records the text (or `xinput test <id>` shows the key events).
- Tier: T3 · Coverage: ❌ (the post-cycle typing today goes through whatever keyboard the input core has, the PS/2 one included).

**S3.9.6 The session accepts input after a keyboard cycle**
- Requirement: a remove/re-add cycle does not wedge the X session or its input stack.
- Acceptance: click + type after the cycle lands in the sink xterm.
- Tier: T3 · Coverage: ✅ `e2e` ("kvmok").

**S3.9.7 Pointer plug-in reaches the container**
- Requirement: a mouse or tablet added while the desktop runs appears as a new `event*` node inside the container.
- Acceptance: the node count rises after `device_add usb-mouse` (relative) and after `device_add usb-tablet` (absolute), both on xHCI.
- Tier: T3 · Coverage: ❌ (no pointer is hot-plugged today; only the boot-time virtio tablet exists).

**S3.9.8 Pointer plug-in is adopted by Xorg**
- Requirement: the device appears in `xinput list` as a pointer.
- Acceptance: as stated, for a relative and for an absolute device.
- Tier: T3 · Coverage: ❌.

**S3.9.9 Pointer plug-out removes the node from the container**
- Requirement and acceptance: as S3.9.3, for the pointer.
- Tier: T3 · Coverage: ❌.

**S3.9.10 Pointer plug-out is seen by Xorg**
- Requirement and acceptance: as S3.9.4, for the pointer.
- Tier: T3 · Coverage: ❌.

**S3.9.11 A hot-added pointer delivers motion and buttons**
- Requirement: events sent through the hot-added device move the pointer and click.
- Acceptance: `xinput test <id>` shows motion and button events sent via `input-send-event` with that device id; a click on the sink xterm through the hot-added tablet focuses it, so typed text then lands.
- Tier: T3 · Coverage: ❌.

**S3.9.12 Repeated input cycles leave no residue**
- Requirement: at least five remove/re-add cycles of the same device return node counts and `xinput list` to baseline, with no stale device entries.
- Acceptance: counts equal baseline after the last cycle; the session still accepts input.
- Tier: T3 · Coverage: ❌.

### F3.10 HMI hotplug: monitors

A headless QEMU cannot enable a second scanout, so a monitor *appearing* is
staged through the DRM connector-force interface and, where modes are needed,
an injected firmware EDID; `HotpluggingTestHelp.md` §4.3 has the exact writes
and their limits. Everything about the physical link is T4.

**S3.10.1 Monitor plug-out with a declared layout holds the geometry**
- Requirement: forcing a declared connector down under the running server changes neither the screen size nor any output's position.
- Acceptance: S3.4.10.
- Tier: T3 · Coverage: ✅ `guest:verify_fixed_layout`.

**S3.10.2 Monitor plug-out is reported by RandR**
- Requirement: after the connector goes down, `xrandr` reports it `disconnected` while it stays enabled under the layout.
- Acceptance: `xr_is Virtual-1 disconnected 1024x768+0+0`.
- Tier: T3 · Coverage: ✅ `guest:verify_fixed_layout`.

**S3.10.3 Monitor re-plug after plug-out restores connected status without moving anything**
- Requirement: returning the connector (`detect`) under the running server brings `xrandr` back to `connected` with the same geometry.
- Acceptance: after `echo detect`, poll `xrandr` for `Virtual-1 connected 1024x768+0+0`; dims still `2048x768`.
- Tier: T3 · Coverage: 🟡 the e2e restores the connector and waits for sysfs to say `connected`, but restarts the desktop before querying X; the running-server half is unasserted.

**S3.10.4 Monitor plug-in on an empty connector, layout declared**
- Requirement: forcing the never-connected `Virtual-2` to `on` under a layout that already declares it changes nothing: same dims, same positions, and `xrandr` now says `connected`.
- Acceptance: `echo on > /sys/class/drm/card*-Virtual-2/status`; `xr_is Virtual-2 connected 1024x768+1024+0`; dims `2048x768`; `echo detect` afterwards.
- Tier: T3 · Coverage: ❌.

**S3.10.5 Monitor plug-in without a layout is detected and does not reflow**
- Requirement: under autodetection a connector coming up is reported `connected` by `xrandr`, and because nothing in this session listens to RandR the screen size and the existing output's geometry are unchanged (no auto-enable).
- Acceptance: record `xrandr` and dims before; force `Virtual-2` on; `xrandr` shows it connected; dims and `Virtual-1` geometry unchanged.
- Tier: T3 · Coverage: ❌.

**S3.10.6 Monitor plug-out without a layout is characterised**
- Requirement: under autodetection with one output enabled, forcing its connector down must not crash or restart X, and the resulting `xrandr`/dims are recorded so the README's description of the degradation rests on an observation.
- Acceptance: Xorg pid unchanged; `xdpyinfo` answers; the observed `xrandr` output is written to the artifacts.
- Tier: T3 · Coverage: ❌.

**S3.10.7 A plugged-in monitor with an EDID exposes modes**
- Requirement: when the forced-on connector carries an injected EDID (`drm_kms_helper.edid_firmware=Virtual-2:edid/1024x768.bin`), `xrandr --verbose` lists that EDID's modes for it, and under autodetection an explicit `xrandr --output Virtual-2 --auto` enables it without disturbing `Virtual-1`.
- Acceptance: as stated; needs `CONFIG_DRM_LOAD_EDID_FIRMWARE` in the guest kernel (confirm on Rocky 9 first).
- Tier: T3 · Coverage: ❌.

**S3.10.8 Physical monitor plug-out and plug-in**
- Requirement: S8.2.2 and S8.2.3 (real EDID re-read, link retraining, KVM video).
- Tier: T4 · Coverage: 🔧.

### F3.11 HMI hotplug: KVM switch composite

**S3.11.1 Keyboard, pointer and sound card leave and return together**
- Requirement: a KVM switch disconnects every USB device at once; the desktop survives all three leaving in the same instant and all three returning.
- Acceptance: `device_del` of the USB keyboard, tablet and sound card back to back; all node counts drop; re-add all three; all counts return; typed text lands, the hot-added tablet clicks, the built-in card still plays; Xorg pid and PipeWire pid unchanged throughout.
- Tier: T3 · Coverage: ❌.

**S3.11.2 Composite cycle with the video link down at the same time**
- Requirement: S3.11.1 with `Virtual-1` forced down during the away period and `detect`ed on return, layout declared; geometry holds throughout.
- Acceptance: S3.11.1's assertions plus dims `2048x768` at every step.
- Tier: T3 · Coverage: ❌.

---

## E4 — Audio stack

### F4.1 Export

**S4.1.1 Both sockets are exported**
- Requirement: `/run/desktop-audio/pipewire-0` and `/run/desktop-audio/pulse` exist on the host while the desktop runs.
- Acceptance: both are sockets; `pactl info` over the pulse one succeeds from the host.
- Tier: T2/T3 · Coverage: ✅ `smoke` (pulse socket), `guest:phase_deploy` (host `pactl`), `desktop-preflight` row.

**S4.1.2 In-container clients use the per-user sockets**
- Requirement: apps in the desktop session reach PipeWire via `$XDG_RUNTIME_DIR` (pulse via `unix:native`), and ALSA apps via `pipewire-alsa`.
- Acceptance: `paplay`, `pw-play`, `aplay` from an xterm on `:0` each play their tone and it is captured at the right frequency.
- Tier: T3 · Coverage: ✅ `guest:play_audio` × 3 + `check-audio.py` (440/880/1320 Hz).

### F4.2 Host clients

**S4.2.1 Host Pulse clients are routed to the container**
- Requirement: `/etc/pulse/client.conf.d/50-desktop-container.conf` points `default-server` at the export and sets `autospawn = no`.
- Acceptance: on the VM host **without** `PULSE_SERVER` set, `paplay tone.wav` plays and is captured; no `pulseaudio` process was spawned on the host.
- Tier: T3 · Coverage: ❌ (host probes set `PULSE_SERVER` explicitly, so the drop-in is untested).

**S4.2.2 Host ALSA clients are routed through the pulse plugin**
- Requirement: `/etc/alsa/conf.d/60-desktop-container.conf` routes `pcm.!default`/`ctl.!default` to the pulse socket (needs `alsa-plugins-pulseaudio`).
- Acceptance: on the VM host (install `alsa-utils` + `alsa-plugins-pulseaudio`), `aplay tone.wav` plays and is captured at 1320 Hz; `amixer` lists the pulse control.
- Tier: T3 · Coverage: ❌.

**S4.2.3 A host-local `asound.conf` still wins**
- Requirement: the drop-in loads before `/etc/asound.conf`, so a host override is honoured.
- Acceptance: write an `/etc/asound.conf` defining `pcm.!default` as `null`; `aplay -D default` goes nowhere (no capture); remove it.
- Tier: T3 · Coverage: ❌ (low priority).

### F4.3 Realtime

**S4.3.1 Rlimits reach PipeWire by inheritance**
- Requirement: `RLIMIT_RTPRIO` hard = 95 (and memlock 64 MiB, nice 31) on the PipeWire process itself.
- Acceptance: `/proc/<pipewire>/limits`.
- Tier: T3 · Coverage: ✅ rtprio `guest:verify_privileges`; ❌ memlock and nice rows.

**S4.3.2 PipeWire holds SCHED_FIFO above priority 1 without rtkit**
- Requirement: no `rtkit-daemon` process; ≥ 1 PipeWire thread is `FF` with rtprio > 1.
- Acceptance: `ps -L` on the daemon.
- Tier: T3 · Coverage: ✅ `guest:verify_privileges`.

### F4.4 Soundless host

> **Retired ID:** S4.4.1 (sound-card hotplug, both directions) was split per
> direction and per layer into **F4.7** (S4.7.1–S4.7.6).

**S4.4.2 Soundless host boots and degrades gracefully**
- Requirement: with no `/dev/snd` on the host, tmpfiles creates an empty one, the container starts, preflight WARNs `no /dev/snd/controlC* visible`, PipeWire runs and exports sockets.
- Acceptance: `smoke` on the card-less runner: `/dev/snd` exists; container up; pipewire pid; pulse socket.
- Tier: T2 · Coverage: ✅ `smoke`; 🟡 the WARN line itself is not grepped.

### F4.5 Lifecycle independence

**S4.5.1 Audio survives an X session restart**
- Requirement: PipeWire's pid is unchanged and the export reachable after Xorg is killed and the session restarts.
- Acceptance: `guest:verify_audio_lifecycle`.
- Tier: T3 · Coverage: ✅ (and `smoke` asserts the structural sid property).

**S4.5.2 Audio recovers from its own crash without disturbing X**
- Requirement: new PipeWire pid, export reachable, mwm still running.
- Acceptance: `guest:verify_audio_lifecycle`, `smoke` "RECOVERY".
- Tier: T2/T3 · Coverage: ✅.

### F4.6 Capture direction

**S4.6.1 A client can record**
- Requirement: a pod with `desktop.local/audio` records the sink monitor and the recording carries the played tone.
- Acceptance: `guest:verify_record` (660 Hz).
- Tier: T3 · Coverage: ✅.

### F4.7 HMI hotplug: audio

The VM stages real USB sound-card hotplug today; `HotpluggingTestHelp.md` §4.4
documents the commands, the three counters, and why QEMU's limits do not
prevent it. Playback and capture are separate stories because QEMU's
`usb-audio` has only ever offered playback; a capture-capable hot-add needs a
different vehicle (see the guide).

**S4.7.1 Sound card plug-in reaches the container**
- Requirement: a card added while the desktop runs produces a new `/dev/snd/controlC*` inside the container.
- Acceptance: the container node count rises after `device_add usb-audio,…,bus=xhci.0`.
- Tier: T3 · Coverage: ✅ `e2e` "audio hotplug".

**S4.7.2 Sound card plug-in reaches WirePlumber**
- Requirement: WirePlumber gains an `alsa_card.*` Device object for it.
- Acceptance: the `pw-cli ls Device` count rises (as the session user, with its runtime dir).
- Tier: T3 · Coverage: ✅ `e2e` "audio hotplug".

**S4.7.3 A hot-added card plays**
- Requirement: audio routed to the hot-added card's sink is rendered by that device.
- Acceptance: `wpctl set-default <id>`; play a tone at a frequency no other test uses (e.g. 990 Hz); `wavcapture` on the shared `audiodev` and `check-audio.py` assert it; restore the default sink.
- Tier: T3 · Coverage: ❌.

**S4.7.4 Sound card plug-out removes the node from the container**
- Requirement: after `device_del`, the `controlC*` node is gone inside the container.
- Acceptance: the container node count returns to baseline.
- Tier: T3 · Coverage: ✅ `e2e` "audio hotplug".

**S4.7.5 Sound card plug-out removes the WirePlumber device**
- Requirement: WirePlumber drops the Device object and re-selects a default sink.
- Acceptance: the `pw-cli ls Device` count returns to baseline (polled); `pactl get-default-sink` names a surviving sink.
- Tier: T3 · Coverage: ✅ count; 🟡 the default-sink re-selection is implied by the tone that follows, not asserted.

**S4.7.6 The built-in card plays after a cycle**
- Requirement: a plug/unplug cycle does not wedge the audio stack.
- Acceptance: a pulse tone is captured at 440 Hz afterwards.
- Tier: T3 · Coverage: ✅ `e2e` "audio-after-hotplug".

**S4.7.7 A stream playing on the card that is unplugged fails cleanly**
- Requirement: a client streaming to the hot-added card when it is removed is either moved to the remaining sink or gets a clean error; `pipewire`, `wireplumber` and `pipewire-pulse` keep their pids.
- Acceptance: start a long `pw-play`/`paplay` to the new sink; `device_del`; the three daemon pids are unchanged; the export stays reachable; the client exits or continues on the built-in sink within 10 s.
- Tier: T3 · Coverage: ❌.

**S4.7.8 Capture device plug-in and plug-out reach WirePlumber**
- Requirement: a hot-added card with a capture path appears as an `alsa_input.*` source and disappears on removal.
- Acceptance: `pactl list short sources` gains and loses the source. Vehicle: PCI hot-add of `intel-hda` plus `hda-duplex` (or `hda-micro`) on the shared `audiodev`, if the HDA codec bus accepts `device_add`; otherwise T4 only, with the attempt and its error recorded here.
- Tier: T3/T4 · Coverage: ❌.

**S4.7.9 Recording from a hot-added capture device works**
- Requirement: a client can `parec`/`arecord` from the new source.
- Acceptance: the stream opens and delivers frames (with QEMU's null backend the content is silence, so no frequency assertion).
- Tier: T3/T4 · Coverage: ❌.

**S4.7.10 A card that arrives after a soundless boot is openable**
- Requirement: S2.4.6 (the audio gid is re-aligned before each stack start).
- Acceptance: a VM profile booted without `intel-hda`; hot-add `usb-audio`; after the next stack start WirePlumber lists it and it plays.
- Tier: T3 · Coverage: ❌.

**S4.7.11 Repeated audio cycles leave no phantom devices**
- Requirement: at least five plug/unplug cycles return node and Device counts to baseline; no `alsa_card` object outlives its node.
- Acceptance: counts equal baseline after the last cycle; the built-in tone still plays.
- Tier: T3 · Coverage: ❌.

**S4.7.12 Physical USB audio plug-in and plug-out**
- Requirement: S8.3.1 (headset, DAC, dock; microphone capture).
- Tier: T4 · Coverage: 🔧.

---

## E5 — Host deploy tree

### F5.1 Apply

**S5.1.1 The documented rsync is the whole installation**
- Requirement: `rsync -a --chown=root:root deploy/host/ /` + `daemon-reload` + `systemd-sysusers` + `systemd-tmpfiles --create` yields a bootable desktop; the two symlinks (`default.target`, `getty@tty1.service` mask) and the four `multi-user.target.wants` symlinks survive as symlinks.
- Acceptance: symlink checks; `is-enabled` = `enabled` for `desktop-client-cdi`, `desktop-selinux`, `desktop-session`, `desktop-tools-cdi.path`.
- Tier: T2/T3 · Coverage: ✅ `smoke` (all four enabled), `guest:phase_deploy` (client-cdi only).

**S5.1.2 Files land root-owned with correct modes**
- Requirement: every file under `/etc`, `/usr/local` from the tree is `root:root`; scripts in `usr/local/{bin,libexec}` are executable.
- Acceptance: `find` over the installed paths.
- Tier: T2 · Coverage: ❌.

**S5.1.3 Reboot is sufficient**
- Requirement: after a reboot, with no manual `systemctl start`, `desktop.service` is active, all oneshots succeeded, the session is up, the tools spec is rewritten by the `.path` unit, labels are present, and `seat-prep` changed nothing (steady state logs nothing).
- Acceptance: T3 variant: reboot the VM after phase-deploy; assert the above; `journalctl -u desktop-seat-prep -b` has no `seat-prep:` lines except possibly `fuser` notices.
- Tier: T3 · Coverage: ❌ (the e2e never reboots; README calls reboot "the honest production test").

### F5.2 Quadlet unit

**S5.2.1 The generator accepts the unit and emits the privilege reduction**
- Requirement: `quadlet -dryrun` succeeds; `ExecStart` has `--cap-drop all`, `--security-opt label=disable`, `--log-driver k8s-file`, `--log-opt max-size=64m`, `--device nvidia.com/gpu=all`, and no `--privileged`.
- Acceptance: `dryrun`.
- Tier: T2 · Coverage: ✅.

**S5.2.2 Every PodmanArgs flag reaches ExecStart intact**
- Requirement: `--pid=host`, `--systemd=false`, `--tty`, `--security-opt apparmor=unconfined`, the three `--ulimit`s, and five `--device-cgroup-rule` arguments each arriving as **one** argument (`"c 13:* rwm"`, not three tokens).
- Acceptance: parse the generated `ExecStart` with shell word-splitting rules and assert each flag/value pair; assert exactly five cgroup rules.
- Tier: T2 · Coverage: ❌ (the quoting trap is documented in the unit and unguarded).

**S5.2.3 Every unit directive is emitted**
- Requirement: `WantedBy=multi-user.target`; `Conflicts=` getty@tty1 and display-manager; `Wants=`/`After=` for seat-prep, cdi-refresh, client-cdi, selinux, tools-cdi.path, host-shell; `Wants=desktop-session.service`; `Restart=always`; `TimeoutStartSec=300`.
- Acceptance: anchored `^Directive=` greps on the dry-run output.
- Tier: T2 · Coverage: 🟡 `dryrun` checks WantedBy, both Conflicts and four Wants; ❌ `desktop-selinux`, `desktop-tools-cdi.path`, `desktop-session`, `After=` lines, `Restart`, `TimeoutStartSec`.

**S5.2.4 Volumes, tmpfs and the `/sys` mount are emitted**
- Requirement: `--volume` for `/dev/input`, `/run/udev:ro`, `/tmp/.X11-unix`, `/run/desktop-audio`, `/var/lib/desktop-container/bin`, `/etc/desktop-container:ro`, `/run/user:rslave`, `/dev/snd`; `--tmpfs /run`, `--tmpfs /tmp`; `--mount type=bind,source=/sys,…,ro=true,bind-nonrecursive=true`; `--device -/dev/dri`? (podman spells the optional device without the dash: assert `--device /dev/dri` or its optional form as the installed podman emits it).
- Acceptance: greps on `ExecStart`.
- Tier: T2 · Coverage: ❌ (the `/sys` `Mount=` was once dropped silently when carried in `PodmanArgs`; only the runtime effect is asserted today).

**S5.2.5 `Conflicts=` backstop**
- Requirement: `desktop.service` cannot run alongside `getty@tty1.service` or `display-manager.service`.
- Acceptance: with the desktop running, unmask and `systemctl start getty@tty1` → desktop stops (then restore the mask and restart). Destructive; run last.
- Tier: T3 · Coverage: ❌ (low priority; `seat-prep` makes it a no-op on provisioned hosts).

**S5.2.6 Image pin drop-in**
- Requirement: on podman ≥ 5.0 a `desktop.container.d/50-image.conf` `Image=` override lands in the generated unit.
- Acceptance: on the Rocky VM (podman 5.x): add a drop-in pinning `localhost/desktop-container:pinned` (tag the same image), `daemon-reload`, `systemctl cat` shows it, restart works; `desktop-preflight` reports the drop-in as merged.
- Tier: T3 · Coverage: ❌.

### F5.3 Seat convergence (`seat-prep.sh`)

**S5.3.1 Dirty seat is walked back**
- Requirement: `72-seat-*.rules` removed (+ udev retrigger), display manager disabled and stopped (resolved unit, not the alias), default target set, getty masked and stopped, logind restarted only if something changed.
- Acceptance: `smoke` staged seat rule + fake DM; `guest:phase_deploy` real boot getty evicted.
- Tier: T2/T3 · Coverage: ✅ rules, DM, target, getty; ❌ the logind `try-restart` (assert via `journalctl -u systemd-logind` that a restart happened on the dirty run and *not* on the steady-state run).

**S5.3.2 Steady state is silent and idempotent**
- Requirement: a second run changes nothing and prints nothing (except the `fuser` availability notice).
- Acceptance: `smoke`.
- Tier: T2 · Coverage: ✅.

**S5.3.3 The gate names a culprit and fails**
- Requirement: if any process holds `/dev/dri/card*` or `/dev/tty1` after convergence, exit 1 with `ERROR: devices still held … <dev>(<pids>)` and the `fuser -v` table; `desktop.service` still starts (`Wants=`).
- Acceptance: on the VM with the desktop stopped, hold `/dev/dri/card0` open from a background `sleep`; `systemctl start desktop-seat-prep` fails naming that pid; release; restart succeeds.
- Tier: T3 · Coverage: ❌.

**S5.3.4 Degrades without `psmisc`**
- Requirement: without `fuser`, the gate is skipped with a logged notice, exit 0.
- Acceptance: `smoke` runner lacks `psmisc` and the script passes.
- Tier: T2 · Coverage: 🟡 implied (the notice is filtered out, never asserted).

**S5.3.5 Missing logind drop-in is warned about**
- Requirement: when a change happened and `50-desktop-container.conf` is absent, log `WARNING: logind drop-in missing`.
- Acceptance: T1 with a temporarily moved drop-in on a dirty seat.
- Tier: T2 · Coverage: ❌.

### F5.4 GPU CDI convergence (`desktop-cdi-refresh`)

**S5.4.1 Stub on a GPU-less host, resolvable by podman**
- Requirement: no toolkit/hardware → stub spec with only `NVIDIA_CDI_STUB=1`; `--device nvidia.com/gpu=all` resolves and the marker lands on the container init's environment.
- Acceptance: `dryrun` + `smoke` + `guest:phase_deploy`.
- Tier: T2/T3 · Coverage: ✅.

**S5.4.2 Real generation, transient failure, no-downgrade, recovery to stub**
- Requirement: toolkit + hardware → `nvidia-ctk cdi generate`; generate failure keeps the real spec; hardware visible with no toolkit keeps the real spec; hardware gone → stub.
- Acceptance: `smoke` "cdi converger" with a fake `nvidia-ctk` and a fake `/dev/nvidiactl`.
- Tier: T2 · Coverage: ✅.

**S5.4.3 Stale real spec fails loudly, regenerates on restart**
- Requirement: after a host driver update the stale spec fails container creation; `systemctl restart desktop-cdi-refresh` fixes it.
- Acceptance: manual on an NVIDIA host.
- Tier: T4 · Coverage: 🔧.

### F5.5 Client CDI specs

**S5.5.1 Display and audio specs are disjoint, rw, directory mounts**
- Requirement: as stated; legacy `/etc/cdi/desktop.yaml` removed.
- Acceptance: `smoke` "client cdi" + `dryrun` runtime probes (display/audio/both/none).
- Tier: T2 · Coverage: ✅.

**S5.5.2 Overrides and validation**
- Requirement: `client-cdi.conf` `DISPLAY_VALUE`, `X11_DIR`, `AUDIO_DIR` apply to both specs; malformed `DISPLAY_VALUE` is rejected before any write; no temp files remain; defaults return when the file is removed.
- Acceptance: `smoke`, `dryrun` (`DISPLAY_VALUE=:7` through a real container).
- Tier: T2 · Coverage: ✅ `DISPLAY_VALUE`, `AUDIO_DIR`; ❌ `X11_DIR`.

**S5.5.3 Atomic writes**
- Requirement: specs are written via temp file + rename in `/etc/cdi`.
- Acceptance: `strace -e rename` or an inotify watch during a run shows no partial file ever at the final path; simpler: assert the inode changes and no `desktop-*.yaml.*` leftovers (✅).
- Tier: T2 · Coverage: 🟡 leftovers checked; atomicity itself inferred.

**S5.5.4 Tools spec is gated on a populated directory**
- Requirement: empty dir, or a dir holding only dotfiles (a dead `.name.XXXXXX` temp), → `not advertising … yet`, exit 0, no spec; one regular file → spec with `DESKTOP_TOOLS_BIN=/opt/desktop-tools/bin` and an `ro` mount of `TOOLS_DIR`; `TOOLS_DIR` is overridable via `client-cdi.conf`; the relabeler is invoked on the dir first.
- Acceptance: T2 before the tree boots, with `TOOLS_DIR=/tmp/x` in the conf: run with empty dir (no spec), with only `.probe` (no spec), with `tool` (spec, hostPath `/tmp/x`); clean up. The populated path end-to-end is ✅ `smoke`/`guest`.
- Tier: T2 · Coverage: 🟡 populated path only.

**S5.5.5 The `.path` unit advertises once per boot and parks**
- Requirement: `desktop-tools-cdi.service` stays active (`RemainAfterExit`) so `DirectoryNotEmpty=` does not retrigger; removing the spec does **not** re-advertise until the service is stopped; a reboot with a populated dir rewrites the spec immediately.
- Acceptance: T2: `rm /etc/cdi/desktop-tools.yaml`; wait 5 s; still absent; `systemctl stop desktop-tools-cdi.service`; spec reappears within 5 s; the `.path` unit is not in `failed` state. Reboot half under S5.1.3.
- Tier: T2 · Coverage: ❌.

**S5.5.6 Specs are host state, independent of the desktop and of kubernetes**
- Requirement: display/audio specs exist before the desktop is up and survive `helm uninstall`.
- Acceptance: `guest:phase2` (before k3s), `guest:verify_teardown`.
- Tier: T3 · Coverage: ✅.

### F5.6 SELinux labeling (`desktop-selinux`)

**S5.6.1 No-op without SELinux**
- Requirement: on a host without SELinux, exit 0 with `no SELinux`/`SELinux disabled`, touching nothing.
- Acceptance: `smoke`.
- Tier: T2 · Coverage: ✅.

**S5.6.2 Three directories and the published binary are `container_file_t`**
- Requirement: `/tmp/.X11-unix`, `/run/desktop-audio`, `/var/lib/desktop-container/bin` and `…/bin/screenshot` carry `container_file_t` at `s0` with no categories, before any client runs.
- Acceptance: `guest:phase_deploy` (`ls -Zd`); confined podman and k8s clients then work.
- Tier: T3 · Coverage: ✅ type; ❌ the `s0` level and empty category set (assert the full context, e.g. `system_u:object_r:container_file_t:s0`).

**S5.6.3 The label is policy (semanage), including the `/run` equivalency workaround**
- Requirement: with `policycoreutils-python-utils` present, an fcontext rule exists for each dir (`/run/desktop-audio` stored under `/var/run/...`), so `restorecon -R` keeps the label.
- Acceptance: `semanage fcontext -l | grep -E 'desktop-audio|X11-unix|desktop-container/bin'` lists three rules; `restorecon -Rv` on the three dirs changes nothing and the labels remain.
- Tier: T3 · Coverage: ❌.

**S5.6.4 chcon fallback without semanage**
- Requirement: without `semanage` on `PATH`, the dirs are still labelled via `chcon` and the script reports the policy note.
- Acceptance: on the VM, run `PATH=/usr/bin:/bin desktop-selinux /tmp/probe-dir` with a `PATH` lacking `semanage` (or a shadowing stub returning 127): dir labelled, note printed, exit 0.
- Tier: T3 · Coverage: ❌.

**S5.6.5 Verification fails the unit when a label does not land**
- Requirement: if any present directory still lacks the type after both mechanisms, print `FAILED to label` naming it and exit 1.
- Acceptance: point the script at a directory on a filesystem that refuses relabeling (e.g. a `vfat` loop mount, or a bind mount with `context=` set) and assert exit 1 + message.
- Tier: T3 · Coverage: ❌.

**S5.6.6 Missing directories are reported, not invented**
- Requirement: a listed dir that does not exist is warned about and skipped; if none exist, exit 1.
- Acceptance: run with two bogus paths → exit 1 `none of the client directories exist yet`; one bogus + one real → warning, real one labelled, exit 0.
- Tier: T3 · Coverage: ❌.

**S5.6.7 The host keeps full access after relabeling**
- Requirement: an unconfined host process can connect to the X and audio sockets and execute the toolkit.
- Acceptance: `guest:phase_deploy` host `pactl`, host `screenshot --help`, host capture of `:0`.
- Tier: T3 · Coverage: ✅.

### F5.7 Host Terminal (`desktop-host-shell-setup`, sshd drop-in, `host-shell-setup.sh`, `host-terminal`)

**S5.7.1 Fresh key every boot, root-only, restricted trust**
- Requirement: an ed25519 keypair under `/etc/desktop-container` (0400 private, 0644 public), and `/etc/ssh/authorized_keys.d/desktop-shell` (0644) with `from="127.0.0.1,::1",no-port-forwarding,no-agent-forwarding,no-X11-forwarding`.
- Acceptance: `dryrun`/`smoke` (perms, `from=` string); `guest:phase_deploy` under enforcing.
- Tier: T2/T3 · Coverage: ✅.

**S5.7.2 Login works both directions**
- Requirement: `ssh -i <key> desktop-shell@127.0.0.1 whoami` from the host and `ssh host whoami` from the container (as desktop) both return `desktop-shell`.
- Acceptance: `smoke`, `guest:phase_deploy`.
- Tier: T2/T3 · Coverage: ✅.

**S5.7.3 Restrictions are enforced**
- Requirement: the key is refused from a non-loopback source address; port forwarding is refused.
- Acceptance: from the VM, `ssh -i <key> desktop-shell@<the VM's own non-loopback IP> whoami` fails; `ssh -L` with the key over loopback is refused/ignored (`-o ExitOnForwardFailure=yes` exits nonzero).
- Tier: T3 · Coverage: ❌.

**S5.7.4 Re-running rotates the key and invalidates the old one**
- Requirement: a second run writes a different public key; the previous private key no longer authenticates.
- Acceptance: save the old key, `systemctl restart desktop-host-shell`, old key fails, new key works; the container keeps the old (dead) copy until `desktop.service` restarts, after which `ssh host` works again.
- Tier: T2 · Coverage: ❌.

**S5.7.5 Empty or missing shell-user / account**
- Requirement: empty `shell-user` → exit 0, nothing written; named account missing from passwd → exit 1 with the sysusers hint.
- Acceptance: T1 with a temp `DIR` (needs the `DIR` path overridable; Appendix A) or T2 before the tree is applied.
- Tier: T1/T2 · Coverage: ❌.

**S5.7.6 The sshd drop-in keeps stock key logins working**
- Requirement: `AuthorizedKeysFile .ssh/authorized_keys /etc/ssh/authorized_keys.d/%u` — ordinary users' home-dir keys still work.
- Acceptance: every `vm_ssh` as `rocky` after the drop-in is active.
- Tier: T3 · Coverage: ✅ implicit (the harness would lose its own login); 🟡 not stated as an assertion.

**S5.7.7 Container side degrades gracefully without key material**
- Requirement: `host-shell-setup.sh` with no `host-shell-key` logs the enablement hint and exits 0; with an empty `shell-user` logs a warning and exits 0; with both present writes `~/.ssh/config` (`Host host`, loopback, `IdentitiesOnly`, `NoHostAuthenticationForLocalhost`) and a 0400 key copy owned by desktop; preflight WARNs `no host shell material`.
- Acceptance: T1 in a scratch container with fabricated `/etc/desktop-container` (needs `SRC`/`DHOME` overridable; Appendix A). T2: comment out the two `Wants=/After=` lines (or stop the unit and delete the key files), restart desktop, assert the preflight WARN and that `ssh host` fails.
- Tier: T1/T2 · Coverage: ❌.

**S5.7.8 The menu wrapper keeps its window open on failure**
- Requirement: when `ssh host` fails, `host-terminal` prints the exit code, the enablement command and the common causes, waits for Enter, and exits with ssh's code; on success it exits 0 immediately.
- Acceptance: T1 with a fake `ssh` on `PATH` (exit 255) and stdin from `echo`: output contains `systemctl start desktop-host-shell.service`, exit code 255; with fake `ssh` exit 0: no prompt, exit 0.
- Tier: T1 · Coverage: ❌.

### F5.8 Host login session (`desktop-session.service`)

**S5.8.1 A real logind session on seat0/tty1**
- Requirement: `loginctl list-sessions` shows `desktop` on `seat0`; `/run/user/61000` is mounted by logind; utmp has an entry for tty1.
- Acceptance: `smoke`, `guest:phase_deploy` (loginctl + dir); ❌ `who | grep -w desktop` / `UtmpIdentifier` row.
- Tier: T2/T3 · Coverage: ✅ / 🟡 utmp.

**S5.8.2 Moves with the container**
- Requirement: `PartOf=desktop.service` restarts the session with the container; the quadlet's `Wants=` brings it up.
- Acceptance: `smoke` "survives a restart (and the host session moves with it)".
- Tier: T2 · Coverage: ✅.

**S5.8.3 Does not steal the controlling tty**
- Requirement: `StandardInput=null` + `TTYPath=` only: the container's `setsid -c` on tty1 succeeds (no "failed to set the controlling terminal").
- Acceptance: X comes up (✅ T3) and `podman logs` has no `failed to set the controlling terminal`.
- Tier: T3 · Coverage: 🟡 outcome only.

**S5.8.4 The desktop runs with the unit disabled**
- Requirement: see S2.2.2.
- Tier: T2 · Coverage: ❌.

### F5.9 Accounts, tmpfiles, sysusers

**S5.9.1 uid contract**
- Requirement: host `getent passwd desktop` is uid 61000 with `/usr/sbin/nologin`; the image's `desktop` is uid 61000; the two agree.
- Acceptance: compare host `getent` with `podman exec desktop id -u desktop`.
- Tier: T2 · Coverage: ❌ (asserted indirectly by `/run/user/61000` appearing).

**S5.9.2 `desktop-shell` is boring**
- Requirement: no supplementary groups, locked password, shell `/bin/bash`, home `/home/desktop-shell` 0700 owned by it.
- Acceptance: `id desktop-shell` shows one group; `passwd -S` locked; `stat` home.
- Tier: T2 · Coverage: 🟡 `smoke` asserts existence (`desktop-preflight` row) only.

**S5.9.3 tmpfiles entries**
- Requirement: `/run/desktop-audio` 1777, `/tmp/.X11-unix` 1777, `/dev/snd` 0755, `/var/lib/desktop-container{,/bin}` 0755, `/home/desktop-shell` 0700, `/etc/ssh/authorized_keys.d` 0755, `/home/desktop` 0700.
- Acceptance: `stat -c '%a %U' …` for each.
- Tier: T2 · Coverage: 🟡 `smoke` (`/dev/snd` exists, bin dir 755, socket dirs exist); preflight checks 1777; the rest unasserted.

### F5.10 Host preflight (`desktop-preflight`)

**S5.10.1 Fully green on a provisioned host**
- Requirement: `done: 0 FAIL(s)`, exit 0, on the VM.
- Acceptance: `guest:phase_deploy`.
- Tier: T3 · Coverage: ✅.

**S5.10.2 Reports a partially-applied host accurately**
- Requirement: specific FAIL/PASS rows for the staged runner state.
- Acceptance: `dryrun` (quadlet missing FAIL, stub spec PASS, account PASS, target PASS); `smoke` (0 or the single no-KMS FAIL).
- Tier: T2 · Coverage: ✅.

**S5.10.3 Each FAIL/WARN branch fires on its condition**
- Requirement: at minimum: getty running FAIL; display manager running FAIL / installed WARN; seat rules FAIL; logind drop-in missing FAIL; DRM/VT holder FAIL when desktop inactive; `nvidia.yaml` missing FAIL; stub+hardware FAIL; client spec missing/wrong-kind/missing-hostPath WARNs; legacy spec WARN; socket dir mode WARN; pulse/ALSA config missing WARNs; `desktop-shell` missing FAIL; sshd drop-in missing FAIL; key perms WARN; key without trust file FAIL; `desktop.service` failed FAIL; drop-ins on podman < 5 FAIL; not root → exit 2.
- Acceptance: T2 table-driven: stage each condition, run, grep the row, restore.
- Tier: T2 · Coverage: ❌ (beyond the handful in S5.10.2).

### F5.11 Container preflight (`preflight-check.sh`)

**S5.11.1 Green on a provisioned KMS host**
- Requirement: no `preflight: FAIL:` lines in `podman logs` on the VM.
- Acceptance: grep.
- Tier: T3 · Coverage: 🟡 the host preflight is asserted at 0 FAIL; the container preflight's lines are dumped on failure but not asserted on success.

**S5.11.2 Each check fires**
- Requirement: at minimum: no `/dev/dri/card*` FAIL (✅ tolerated on the KMS-less runner, not asserted); no `event*` FAIL; no `controlC*` WARN; `/dev/tty1` missing FAIL; udev db missing FAIL; foreign seat WARN (S3.8.6); desktop cannot read node FAIL; init is PID 1 FAIL (S3.7.3); `/sys` writable FAIL; socket dir not writable WARN; no host shell material WARN (S5.7.7); monitor layout PASS/WARN (S3.4.11); stub+`nvidiactl` FAIL, `nvidia_drv.so` present/absent WARNs (T4).
- Acceptance: T2 via `podman run` of the image with deliberately omitted mounts/devices/flags (no `/run/udev` volume → FAIL line; no `--pid=host` → FAIL line; no `/sys` ro mount → FAIL line; no `/dev/input` → FAIL line; no `/tmp/.X11-unix` volume → WARN line).
- Tier: T2 · Coverage: ❌.

---

## E6 — Container privileges and isolation

### F6.1 Privilege reduction

**S6.1.1 Not privileged; seccomp active**
- Requirement: `Privileged=false`; init `Seccomp: 2`.
- Acceptance: `smoke`, `guest:verify_privileges`.
- Tier: T2/T3 · Coverage: ✅.

**S6.1.2 Forbidden capabilities absent**
- Requirement: `SYS_MODULE SYS_RAWIO SYS_PTRACE SYS_BOOT SYS_TIME NET_ADMIN NET_RAW DAC_READ_SEARCH SYSLOG BPF PERFMON SYS_ADMIN KILL` are not in init's `CapEff`.
- Acceptance: `guest:verify_privileges`.
- Tier: T3 · Coverage: ✅.

**S6.1.3 Granted set is exactly what the quadlet lists**
- Requirement: `CapEff` decodes to exactly `SYS_TTY_CONFIG MKNOD CHOWN SETUID SETGID DAC_OVERRIDE FOWNER FSETID SETPCAP`.
- Acceptance: `capsh --decode` on `CapEff` equals that set (catches an accidental *addition* outside the forbidden list).
- Tier: T3 · Coverage: ❌.

**S6.1.4 Device cgroup is bounded**
- Requirement: `/dev/mem` (major 1) cannot be read; majors 13, 4, 5, 226, 116 can.
- Acceptance: `guest:verify_privileges` (`/dev/mem`); 🟡 positive majors implied by the desktop working.
- Tier: T3 · Coverage: ✅ / 🟡.

**S6.1.5 `/sys` is read-only and non-recursive**
- Requirement: the container's `/sys` mount is `ro`; `/sys/fs/cgroup`, `/sys/fs/selinux` are absent inside.
- Acceptance: `guest:verify_privileges` (ro); ❌ absence of submounts.
- Tier: T3 · Coverage: ✅ / ❌.

### F6.2 Namespace sharing and mandatory access control

**S6.2.1 Host pid namespace, bounded by capability**
- Requirement: the container sees host pids (`/proc/1` is the host's systemd) but cannot signal them (`kill -0 1` → EPERM) nor read their memory/environ (`cat /proc/1/environ` → EACCES).
- Acceptance: as stated, as container root.
- Tier: T3 · Coverage: 🟡 visibility ✅ (`comm` check on the host); the two negative checks ❌.

**S6.2.2 Host network namespace**
- Requirement: `Network=host`: the container's interfaces equal the host's (needed for uevents).
- Acceptance: `ip -o link` inside equals outside; hot-add tests depend on it (✅ indirectly).
- Tier: T3 · Coverage: 🟡.

**S6.2.3 SELinux separation off for the desktop, AppArmor unconfined**
- Requirement: the desktop's processes run `spc_t`/unconfined (`SecurityLabelDisable=true`); on an AppArmor host `podman inspect … AppArmorProfile` is `unconfined`.
- Acceptance: `ps -Z -p <initpid>` on the VM shows `spc_t`; on the Ubuntu runner the inspect field is `unconfined`.
- Tier: T2/T3 · Coverage: ❌.

**S6.2.4 Not systemd mode**
- Requirement: `--systemd=false`: the stop signal is SIGTERM and podman did not mount its systemd-mode tmpfs set.
- Acceptance: `podman inspect` `StopSignal` = SIGTERM (S1.2.8); no `/run/systemd/system` directory created by podman inside (only the host's view, if any, via `/run` tmpfs → absent).
- Tier: T2 · Coverage: ❌.

---

## E7 — Client contract

### F7.1 podman clients

**S7.1.1 Each device grants only its own capability**
- Requirement: display alone → `DISPLAY=:0` + X socket, no audio env or mount; audio alone → both audio env vars + audio dir, no display; both → union; none → nothing.
- Acceptance: `dryrun` (env/mounts), `guest:phase_deploy` (confined, real `xdpyinfo`).
- Tier: T2/T3 · Coverage: ✅.

**S7.1.2 Confined clients work under enforcing**
- Requirement: no `label=disable`, no `--privileged` on any client.
- Acceptance: `guest:phase_deploy` podman probes; `ci/vm` greps for the flag (❌ a static guard: `grep -r 'label=disable\|--privileged' ci/` matches only comments).
- Tier: T3/T0 · Coverage: ✅ / ❌ guard.

### F7.2 Published toolkit (`publish-tools.sh`, `desktop.local/tools`)

**S7.2.1 Published at boot, 0755, by rename**
- Requirement: `screenshot` appears in `/var/lib/desktop-container/bin` mode 0755; a republish produces a new inode (rename, not overwrite).
- Acceptance: `smoke` (presence, mode); ❌ record `stat -c %i` before and after a desktop restart and assert it changed; ❌ no `.screenshot.*` temp files remain.
- Tier: T2 · Coverage: 🟡.

**S7.2.2 Stale tools are pruned, dotfiles left alone**
- Requirement: a regular file in the directory that the image no longer ships is removed on the next publish; a dotfile is not.
- Acceptance: drop `/var/lib/desktop-container/bin/oldtool` and `.tmpfile`, restart desktop, `oldtool` gone (`pruned oldtool` logged), `.tmpfile` present.
- Tier: T2 · Coverage: ❌.

**S7.2.3 The directory is never emptied during a republish**
- Requirement: the prune happens after publishing, one entry at a time, so `DirectoryNotEmpty=` never observes an empty directory.
- Acceptance: an inotify watch (or a tight poll) during a restart never sees the directory empty.
- Tier: T2 · Coverage: ❌ (low priority).

**S7.2.4 Clients receive it read-only via `DESKTOP_TOOLS_BIN`**
- Requirement: `--device desktop.local/tools=all` injects `DESKTOP_TOOLS_BIN=/opt/desktop-tools/bin`, mount `ro`; the binary executes; the mount is not writable; a pod without the request has neither.
- Acceptance: `smoke`, `guest:verify_screenshot`, `guest:verify_split` (display-only has no toolkit).
- Tier: T2/T3 · Coverage: ✅.

**S7.2.5 Advertised only after provisioning**
- Requirement: no spec before the desktop's first start; present after.
- Acceptance: `smoke`.
- Tier: T2 · Coverage: ✅.

### F7.3 Kubernetes clients

**S7.3.1 Resources become allocatable, pods get injected edits**
- Requirement: three plugin releases → `desktop.local/{display,audio,tools}` allocatable at 10; a pod declaring only requests gets env + sockets; a control pod gets nothing.
- Acceptance: `guest:phase2`, `guest:verify_cdi`.
- Tier: T3 · Coverage: ✅.

**S7.3.2 Split holds in pods**
- Requirement: display-only has display, no audio, no toolkit; audio-only plays, has no display and cannot `xdpyinfo`.
- Acceptance: `guest:verify_split`.
- Tier: T3 · Coverage: ✅.

**S7.3.3 Pods are confined and declare no securityContext**
- Requirement: client pods are `container_t`; manifests carry no `securityContext`, `volumes`, `env` or `cdi.k8s.io` annotation.
- Acceptance: `guest:phase2` (`/proc/self/attr/current`), `ci/helm-assertions.sh`.
- Tier: T0/T3 · Coverage: ✅.

**S7.3.4 A lean non-desktop image works**
- Requirement: an image with no X server, no PipeWire, no WM opens the display and plays all three audio paths with injected env only.
- Acceptance: `guest:verify_testclient`, `e2e` lean-client tone loop.
- Tier: T3 · Coverage: ✅.

**S7.3.5 Concurrency**
- Requirement: three pods hold live X connections at once.
- Acceptance: `guest:verify_concurrency`.
- Tier: T3 · Coverage: ✅.

**S7.3.6 Teardown seam**
- Requirement: `helm uninstall` withdraws the resources; host specs and the desktop survive.
- Acceptance: `guest:verify_teardown` (display, audio); ❌ the `tools` release is never uninstalled — extend to all three.
- Tier: T3 · Coverage: 🟡.

**S7.3.7 The desktop survives CRI-O and k3s arriving**
- Requirement: `desktop.service` active and `X0` present after the runtime install.
- Acceptance: `guest:phase2`.
- Tier: T3 · Coverage: ✅.

### F7.4 Screenshot delivery as the toolkit's proof

**S7.4.1 Captured pixels are the screen**
- Requirement: the injected binary's full capture matches the painted test pattern (corners, channel order, off-by-one, stride, odd coordinates); regions equal crops of the full capture; `--to-stdout` equals file mode; orientation beats flipped/mirrored/rotated QEMU dumps by margin; `-h` is height; oversize → exit 2 naming the screen; no `DISPLAY` → exit 1 naming the device.
- Acceptance: `guest:verify_screenshot` + `e2e:assert_pattern/assert_same/assert_orientation_vs_reference`.
- Tier: T3 · Coverage: ✅.

---

## E8 — Hardware-only behaviours (manual acceptance)

### F8.1 NVIDIA GPU mode

**S8.1.1 NVIDIA GPU mode**
- Requirement: on a host with the driver and a toolkit that ships `nvidia_drv.so`: real CDI spec, `20-gpu.conf` `Driver "nvidia"`, `glxinfo -B` reports NVIDIA, preflight `PASS: NVIDIA GPU injected together with X driver module`.
- Tier: T4 · Coverage: 🔧 Appendix C.

**S8.1.2 NVIDIA host with missing/broken toolkit**
- Requirement: stub spec, modesetting desktop comes up, host and container preflight both FAIL on "stub + hardware".
- Tier: T4 · Coverage: 🔧.

**S8.1.3 NVIDIA host without `nvidia_drm.modeset=1` and no injection**
- Requirement: preflight `FAIL: no /dev/dri/card* visible` with the kernel-cmdline hint.
- Tier: T4 · Coverage: 🔧.

**S8.1.4 Old toolkit without `nvidia_drv.so`**
- Requirement: preflight `WARN: nvidia_drv.so NOT injected`; the documented `Volume=` bind-mount fallback restores NVIDIA mode (podman ≥ 5 drop-in merging verified with `systemctl cat`).
- Tier: T4 · Coverage: 🔧.

### F8.2 Physical KVM switch and monitors

**S8.2.1 Physical KVM: input**
- Requirement: a non-HID-emulating USB KVM switched away and back leaves keyboard and mouse working without a service restart.
- Tier: T4 · Coverage: 🔧.

**S8.2.2 Physical KVM: video, modesetting and NVIDIA**
- Requirement: with a declared layout, `xrandr` geometry and window positions are unchanged across a switch cycle; on NVIDIA with `nvidia-connected`/`nvidia-edid` as needed; the panel actually shows the picture after link retraining.
- Tier: T4 · Coverage: 🔧.

**S8.2.3 Real EDID and `desktop-monitors-capture`**
- Requirement: the capture tool prints the real output names and rates; pasting them yields the same arrangement after restart.
- Tier: T4 · Coverage: 🔧.

### F8.3 Audio hardware and long-run behaviour

**S8.3.1 USB audio devices**
- Requirement: a USB headset/DAC plugged in after boot appears in `wpctl status`; microphone capture works from a client.
- Tier: T4 · Coverage: 🔧.

**S8.3.2 Long-run log bound**
- Requirement: over days of uptime the container log file never exceeds ~64 MB (podman rotates/truncates).
- Tier: T4 · Coverage: 🔧.

---

## E9 — Test-suite quality requirements (cross-cutting)

These govern every test written against the stories above; the suite's own
history (see comments in `ci/`) is the reason each exists.

### F9.1 Assertion discipline

**S9.1.1 Every assertion has been seen to fail**
- Requirement: a new assertion is verified against a deliberate mutation (the wrong flag, a comment-only match, a stale value) before it is merged.
- Acceptance: the PR description names the mutation.

**S9.1.2 Assert generated output, not source text**
- Requirement: quadlet/CDI/config assertions read the *generated* artefact (`ExecStart=`, the written YAML, `podman inspect`, `/proc/<pid>`), anchored so comments cannot match.

**S9.1.3 Read the container's init, never `/proc/1`**
- Requirement: under `--pid=host`, process-level assertions use `/run/desktop-init.pid`.

**S9.1.4 Poll log lines; read live state once**
- Requirement: a log-line assertion is polled (console → conmon → k8s-file lag); process/socket state may be read directly.

**S9.1.5 No `grep -q`/`-m1` on a live pipeline under `pipefail`**
- Requirement: capture output to a variable first (SIGPIPE → exit 141 false failures).

### F9.2 Fixture and environment discipline

**S9.2.1 Nothing weakens the system under test**
- Requirement: no `setenforce`, no `--security-opt label=disable`, no `--privileged` on clients, no `-v`/`-e` that duplicates a CDI edit, no test-only quadlet changes.

**S9.2.2 Narrow fixtures stay narrow**
- Requirement: `display-only`/`audio-only` request exactly one resource; `cdi-verify`/`testclient` declare nothing but requests (guarded by `ci/helm-assertions.sh`).

**S9.2.3 Failures are diagnosable from the job log**
- Requirement: every failure handler tees diagnostics to stdout as well as to an artifact; the failing message is repeated last.

**S9.2.4 Probes default to integers**
- Requirement: counters read over ssh default to `0` on error so arithmetic comparisons cannot crash the harness.

**S9.2.5 Restore what you changed**
- Requirement: a test that writes host config (`monitors.conf`, `client-cdi.conf`, connector force, drop-ins) restores the shipped state and *asserts* the restore took effect.

---

## Appendix A — Testability prerequisites for the T1 tier

Several scripts hard-code the paths they read, which is why their branch
coverage sits at ❌. Each needs an environment override (the pattern
`xorg-monitor-conf.sh` already uses with `MONITORS_CONF`/`MONITORS_OUT`/
`XORG_GPU_CONF`) so a `ci/script-unit-tests.sh` can drive them without root
or a container. Defaults must remain the production paths.

| Script | Hard-coded today | Proposed override | Unblocks |
|---|---|---|---|
| `image/xorg/xorg-gpu-conf.sh` | `/dev/dri`, `/dev/nvidia*`, `/sys/class/drm`, `/usr/lib64`+`/usr/lib`, output path | `GPU_DEV_DIR`, `GPU_SYS_DRM`, `GPU_LIB_DIRS`, `GPU_OUT` | S3.1.1–S3.1.5 |
| `image/xorg/align-device-groups.sh` | node globs under `/dev` | `DEV_ROOT` prefix | S3.2.2 (alternative: run inside a scratch container with `mknod`) |
| `image/xorg/ensure-vt-devices.sh` | `/dev` | `DEV_ROOT` | S3.2.3 |
| `image/xorg/preflight-check.sh` | all of the above plus `/run/udev`, `/run/desktop-init.pid`, `/proc/self/mounts`, `/etc/desktop-container` | one `PREFLIGHT_ROOT` prefix, or run inside `podman run` with mounts omitted (S5.11.2 approach) | S5.11.2 |
| `image/session/session-postmortem` | Xorg log glob | `POSTMORTEM_XLOG_GLOB` | S2.3.5 |
| `image/session/start-audio` | daemons by name | already PATH-overridable | S2.4.4, S2.4.5 |
| `image/session/host-shell-setup.sh` | `/etc/desktop-container`, `/home/desktop` | `SRC`, `DHOME` (already variables; export them) | S5.7.7 |
| `image/session/host-terminal` | `ssh` by name | already PATH-overridable | S5.7.8 |
| `image/tools/publish-tools.sh` | `SRC`, `DEST` | export the existing variables | S7.2.2, S7.2.3 |
| `deploy/host/usr/local/libexec/desktop-host-shell-setup` | `/etc/desktop-container`, `/etc/ssh/authorized_keys.d` | `DIR`, `AK_DIR` | S5.7.5 |
| `deploy/host/usr/local/bin/desktop-monitors-capture` | `podman exec … xrandr --query` | `DESKTOP_XRANDR_CMD` | S3.4.12 |
| `deploy/host/usr/local/libexec/desktop-selinux` | takes paths as args already | — | S5.6.4–S5.6.6 |
| `deploy/host/usr/local/libexec/desktop-tools-cdi` | `TOOLS_DIR` via `client-cdi.conf` | also honour an env override so tests need not write `/etc` | S5.5.4 |

Proposed job: add `script-unit` to `ci.yml` `static` (no root), covering
S1.1.3, S2.3.5, S2.4.4, S2.4.5, S3.1.x, S3.4.12, S5.7.5, S5.7.7, S5.7.8.

## Appendix B — Suggested new VM e2e phases

The T3 gaps above group naturally into a few additions to `vm-guest.sh`:

| New phase | Stories |
|---|---|
| `verify-session-tree` | S2.3.1, S2.3.3 (host-process half), S2.3.4, S2.3.6, S2.4.2 (wireplumber / pipewire-pulse), S2.4.7, S3.2.4, S3.2.5, S3.3.2, S3.5.2 |
| `verify-shutdown` | S2.5.1 |
| `verify-host-audio-clients` | S4.2.1, S4.2.2 |
| `verify-host-shell-hardening` | S5.7.3, S5.7.4 |
| `verify-selinux-policy` | S5.6.2 (full context), S5.6.3, S5.6.4, S5.6.6 |
| `verify-seat-gate` | S5.3.3, S3.8.6 |
| `verify-isolation-negatives` | S6.1.3, S6.1.5 (submounts), S6.2.1, S6.2.3 |
| `verify-fixed-layout` (extend) | S3.4.11, S3.4.12 |
| `verify-hotplug-input` (new; pointers, per-device proof, Xorg plug-out) | S3.9.2, S3.9.4, S3.9.5, S3.9.7–S3.9.12 |
| `verify-hotplug-monitor` (new; DRM force on + firmware EDID) | S3.10.3–S3.10.7 |
| `verify-hotplug-audio` (extend) | S4.7.3, S4.7.5 (default sink), S4.7.7, S4.7.8, S4.7.9, S4.7.11 |
| `verify-kvm-composite` (new) | S3.11.1, S3.11.2 |
| reboot sub-phase after `phase-deploy` | S5.1.3, S5.5.5 (reboot half) |
| second VM profile booted without `intel-hda` | S2.4.6 / S4.7.10 |

## Appendix C — Hardware acceptance checklist (T4)

Run on a provisioned physical host after each image or tree release. Record
the output of each command with the result.

```sh
# S8.1.1 / S8.1.2 / S8.1.3 / S8.1.4 — GPU mode
desktop-preflight
podman logs desktop | grep -E 'preflight:|xorg-gpu-conf: decision'
podman exec desktop cat /etc/X11/xorg.conf.d/20-gpu.conf
head -5 /etc/cdi/nvidia.yaml
DISPLAY=:0 glxinfo -B | grep -E 'OpenGL (vendor|renderer)'
systemctl cat desktop.service | grep -E '^Image=|nvidia_drv'

# S8.2.1 — KVM input: switch away and back, then
podman exec desktop ls /dev/input
# type into the desktop; it must respond without `systemctl restart desktop.service`

# S8.2.2 / S8.2.3 — KVM video
desktop-monitors-capture            # paste into monitors.conf, restart, then:
DISPLAY=:0 xrandr                   # before switch
# switch away, wait, switch back
DISPLAY=:0 xrandr                   # must be identical; windows must not have moved
podman logs desktop | grep xorg-monitor-conf

# S8.3.1 — USB audio
podman exec desktop ls /dev/snd     # before and after plugging the device
podman exec -u desktop -e XDG_RUNTIME_DIR=/run/user/61000 desktop wpctl status
# record from a client pod / podman client with desktop.local/audio

# S8.3.2 — log bound (after days of uptime)
ls -l /var/lib/containers/storage/overlay-containers/*/userdata/ctr.log*
```

## Appendix D — Coverage summary

Counts are of stories in E1–E7 (E8 is all 🔧, E9 is cross-cutting). A story
with a mixed mark is counted under its weakest mark; a story whose only mark
is 🔧 is counted in that column.

| Epic | Stories | ✅ | 🟡 | ❌ | 🔧 |
|---|---|---|---|---|---|
| E1 Image build | 14 | 5 | 3 | 6 | 0 |
| E2 Boot & supervision | 25 | 4 | 7 | 14 | 0 |
| E3 Display & session | 62 | 20 | 12 | 29 | 1 |
| E4 Audio | 23 | 10 | 2 | 10 | 1 |
| E5 Deploy tree | 50 | 14 | 9 | 26 | 1 |
| E6 Privileges | 9 | 2 | 2 | 5 | 0 |
| E7 Client contract | 15 | 10 | 2 | 3 | 0 |
| **Total** | **198** | **65** | **37** | **93** | **3** |

Regenerate after editing with:

```sh
for e in 1 2 3 4 5 6 7; do
  printf 'E%s ' "$e"
  awk -v e="$e" '/^## E/{on=($0 ~ "^## E"e" ")} on && /^\*\*S/{n++} on && /^\*\*S/{s=$0} on && /Coverage:/{ if($0~/❌/)x++; else if($0~/🟡/)p++; else if($0~/✅/)c++ } END{printf "stories=%d ok=%d partial=%d gap=%d hw=%d\n", n, c, p, x, n-c-p-x}' Requirements.md
done
```
