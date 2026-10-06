# Requirements: containerized desktop — test coverage specification

**Purpose.** This document enumerates every behaviour the containerized desktop
is expected to have, in a form a test can be written against, and records for
each one (a) whether a test already exists and (b) what evidence that test
must collect so a human reviewer can see what happened without re-running it.
It is the backlog for reaching complete, *reviewable* test coverage of the
desktop: implement the ❌ and 🟡 stories, keep the ✅ ones green, make every
story emit its evidence, and run the 🔧 ones by hand on real hardware.

**Scope.** "Containerized desktop" means:

| In scope | Where it lives |
|---|---|
| the desktop image: base and application layers, boot supervisor, X session, audio stack, boot-time generators, published toolkit | `Containerfile`, `Containerfile.base`, `image/` |
| the host deploy tree that runs it: quadlet, converger oneshots, seat/session/SELinux/CDI/host-shell units, tmpfiles/sysusers, host audio client configs, debug tools | `deploy/host/` |
| the client contract the desktop exports: the three CDI devices and what they inject, under podman and under kubernetes | `/etc/cdi/desktop-*.yaml`, `/var/lib/desktop-container/bin` |
| **the operator's and client applications' experience**: what the operator sees and hears, and what an application container running against this desktop can rely on, including across hotplug and desktop lifecycle events **without the application container restarting** | E7 (F7.5–F7.8), the hotplug features, E8, E11 |
| **the maintainer's experience**: what the maintainer does and sees when provisioning, verifying, reconfiguring, upgrading, troubleshooting and recovering a host by this repo's documentation as written, and what the operator sees while it happens | E10 (F10.1–F10.6); the procedures in `README.md`, `deploy/README.md`, `deploy/HOST-REQUIRES.md` |

Out of scope: the internals of `cdi-device-plugin/` and `screenshot/` (each has
its own Go test suite and README). They appear below only where they are the
instrument of a desktop test or where the desktop's contract *with* them is
what is under test.

**Roles.** Stories name two people:

| Role | Who | Where their experience is specified |
|---|---|---|
| **Operator** | the person at the display, using the machine to do a job: reads the screen, types and clicks into applications, listens, plugs and unplugs devices, switches the KVM | every story that states what is seen or heard at the screen, wherever it sits; E11 for what the operator does through the desktop's own controls |
| **Maintainer** | the person who provisions, verifies, configures, upgrades, troubleshoots and recovers the host, working from this repo's documentation | E5 component by component; E10 end to end |

`README.md`, `deploy/README.md` and the scripts' comments call the maintainer
"the operator"; quotations from them keep their wording.

**Structure.** Epic → Feature → Story. Every story has:

- **Requirement** — what must be true, stated so that it can be false, and
  where there is an operator at the screen, stated as what the operator sees
  or hears.
- **Acceptance** — the observable(s) a test asserts.
- **Evidence** — what the test attaches to its report so a reviewer can
  confirm the outcome without trusting the assertion. Uses the evidence kinds
  defined in "Evidence standard" below; each entry says what the reviewer
  should see in it.
- **Tier** — where the test runs (below).
- **Coverage** — current status and the test that provides it.

**Companion.** `HotpluggingTestHelp.md` holds the mechanics (QEMU commands,
layer-by-layer probes, failure signatures, the hardware procedure) behind every
hotplug story in F3.9, F3.10, F3.11, F4.7 and F7.7.

**ID scheme.** `E<n>` epic, `F<n>.<m>` feature, `S<n>.<m>.<k>` story. IDs are
stable; retire a story by marking it *retired* in place rather than
renumbering.

## Test tiers

| Tier | Runs where | Can see | Today |
|---|---|---|---|
| **T0 static** | any machine, no root | files only | `ci.yml` `static`: go fmt/vet/test, shellcheck, `py_compile` of the VM harness, `ci/monitor-layout-tests.sh`, ARG-scoping check, helm/kubeconform |
| **T1 script-unit** | any machine, no root, or a scratch container of the image | one script with fabricated inputs | `ci.yml` `static`: `ci/script-unit-tests.sh`, for the scripts an Appendix A override or a fake on `PATH` already reaches; the scripts that need more (Appendix A) are still to come |
| **T2 build-smoke** | ubuntu runner, root, podman, systemd, **no sound card, no SELinux**; KMS not guaranteed (the Azure runners usually expose a Hyper-V DRM device, and X then really runs, per `ci/smoke-deploy.sh`) | the deploy tree booting a real container | `ci.yml` `build-smoke` + `ci/smoke-deploy.sh` |
| **T3 VM e2e** | Rocky 9 KVM guest, virtio GPU/input/HDA, **SELinux enforcing**, k3s + CRI-O | real Xorg on a real KMS device, hotplug via QEMU, confined clients, a capturable display and audio backend | `ci.yml` `images` → `vm` (shards `core`, `operator`, `k8s`, each its own VM) → `ci/vm/vm-e2e.sh` + `ci/vm/vm-guest.sh` + `ci/vm/operator-e2e.py` |
| **T4 hardware** | a provisioned physical host | NVIDIA, physical KVM switch, real monitors/EDID, USB audio, a person | manual checklist (Appendix C); to become a guided script that prompts the tester for each physical action and gathers the evidence itself |

A story's tier is the *lowest* tier that can prove it honestly. Pushing a
story down a tier (e.g. from T3 to T1) is a valid improvement if the proof
stays real.

## Coverage legend

| Mark | Meaning |
|---|---|
| ✅ | asserted by an existing test, **and every evidence item the story names is saved in the run's uploaded artifacts** (its own `artifacts/<story>/`, or another story's directory, which the line names); the reference names the function or step |
| 🟡 | the named evidence is saved, but the assertion is partial or only a side effect of another test; the gap is named |
| ❌ | no test, or some named evidence is not saved (when a test does assert the story, the line says which); the acceptance column is the spec for the one to write |
| 🔧 | needs real hardware or a person; manual acceptance procedure in Appendix C, to become a guided hardware script |

Text in a job log is not saved evidence here: it is not indexed per story,
and nothing checks that it was produced. This is the rule Appendix D counts
by; a story whose assertion exists but whose evidence is not saved is ❌.

CI holds the marks to it: `ci.yml`'s `coverage-gate` job reads every job's
evidence and fails the run when a story marked ✅ here has no passing
evidence in it, or when a story's directory is incomplete (S9.3.1). A ✅ line
that files its evidence under another story's directory names it as
`artifacts/<story>/`, which is how the gate finds it.

Reference shorthand: `smoke` = `ci/smoke-deploy.sh`; `guest:<fn>` =
`ci/vm/vm-guest.sh` function; `e2e` = `ci/vm/vm-e2e.sh`; `dryrun` = the
"deploy tree quadlet dry-run + CDI spec checks" step of `ci.yml`;
`layout-tests` = `ci/monitor-layout-tests.sh`; `script-unit` =
`ci/script-unit-tests.sh`; `operator-e2e:<fn>` = a
story function in `ci/vm/operator-e2e.py`, whose evidence is under
`artifacts/<story>/`.

## Evidence standard

A green assertion tells a reviewer that a script was satisfied. Evidence tells
them what the machine actually did. Every story names the evidence it attaches;
a test that passes without producing its evidence is incomplete. The standard
below defines the kinds, how each is captured in this rig, and the report
layout. Every tier writes evidence through one library, `ci/evidence.sh`
from the shell and `ci/evlib.py` from Python, in the layout below; Appendix E
lists the capture helpers that exist and the ones still to build.

### Evidence kinds

| Kind | What it is | How it is captured here | What makes it reviewable |
|---|---|---|---|
| **EV-SHOT** | a still of the virtual display at a named moment | QEMU monitor `screendump <file>.png -f png` (PPM fallback) | taken at the moments the story names (before / after / on failure), file named `<story>-<moment>.png`, and the index says what should be visible (a window at a position, a colour, a cursor) |
| **EV-SHOT-CLIENT** | a still captured **by a client container** of its own view of the display | the injected `screenshot` tool run inside the client (`"$DESKTOP_TOOLS_BIN"/screenshot`) | proves what the *client* could see, independently of QEMU's framebuffer; paired with an EV-SHOT of the same moment |
| **EV-VIDEO** | a recording of the display across a dynamic step (hotplug, restart, window movement) | a screendump loop at ≥ 2 fps for the step's duration, assembled with `ffmpeg -framerate 2 -i frame-%04d.png` into an mp4, or into an animated gif with imagemagick's `convert` where ffmpeg is not installed (the e2e runner installs imagemagick only); raw frames kept | the index names the frames / timestamps where the event happens ("device removed at frame 12, text appears at frame 31"); an EV-TIMELINE correlates |
| **EV-AUDIO** | what the machine's audio output actually carried | QEMU monitor `wavcapture <file>.wav <audiodev> 44100 16 2` … `stopcapture 0`; then `ci/vm/check-audio.py` output and a spectrogram PNG (`sox <wav> -n spectrogram` or `ffmpeg -lavfi showspectrumpic`), or, where neither tool is installed, a plot of the level at the story's pitch over time with each event marked, drawn by the harness (`ci/vm/operator-e2e.py` does this). `wavcapture` writes only while one of the guest's sound devices is running: a stretch with none running is missing from the file, not silent in it, so a story about gaps also compares the capture's length with the wall-clock time it ran | a reviewer can *listen*, see the tone at the expected frequency and time in the spectrogram, and read the analyser's verdict; each path uses a distinct pitch (pulse 440, pipewire 880, ALSA 1320, record 660, hot-added device 990 Hz, client-continuity 1100 Hz) so overlapping sources are distinguishable |
| **EV-AUDIO-REC** | a recording made **by a client** (capture direction) | `parec`/`arecord` inside the client, file pulled out via `kubectl exec … cat` / `podman cp`; spectrogram + analyser as above | proves the client's microphone/monitor path, not the machine output |
| **EV-STATE** | a command's output at a named moment, kept as text | `xrandr --query --verbose`, `xinput list`, `xwininfo -root -tree`, `wpctl status`, `pw-cli ls Device`, `pactl list short sinks/sources/sink-inputs`, `ls -l /dev/input /dev/snd` (host and container), `podman inspect`, `loginctl`, `systemctl status`, `ls -Z`, `cat /proc/<pid>/status`, `kubectl get pod -o wide` | always captured as **before / after pairs** for a change, with `diff -u` attached (**EV-DIFF**); the index says which lines must differ and which must not |
| **EV-PIDS** | the process table that proves what did and did not restart | `pid, ppid, sid, user, comm, start time` for desktop-init, Xorg, mwm, pipewire, wireplumber, pipewire-pulse, the client's processes; for pods `restartCount` and `containerID`; for podman clients `podman inspect … StartedAt` | before / after; the index states which pids must be unchanged (no restart) and which must have changed (a restart that was supposed to happen) |
| **EV-LOG-DESKTOP** | `podman logs desktop` for the step's window | bounded by a marker line the harness writes (`podman exec desktop sh -c 'echo "== <story> start" > /dev/console'`) or by `--since` | the index quotes the lines that must appear and the ones that must not |
| **EV-LOG-XORG** | the rootless Xorg log (`/home/desktop/.local/share/xorg/Xorg.0.log`) slice | tail or marker-bounded slice | the index quotes `Adding input device` / `removing device` / connector lines |
| **EV-LOG-JOURNAL** | host journal for named units | `journalctl -u <unit> --since <marker> -o short-precise` | the index names the units and the lines |
| **EV-LOG-CLIENT** | the client container's own output | `kubectl logs <pod>` / `podman logs <ctr>`, plus any file the client app wrote (the sink text file, the player's stderr) | proves what the *application* experienced (errors, reconnects, nothing) |
| **EV-QEMU** | the emulator's view | transcript of monitor commands issued and `info usb` / `info pci` / `info qtree` before and after | proves layer 1 for a hotplug event, so a failure elsewhere cannot be blamed on QEMU |
| **EV-CONFIG** | a generated artefact | `/etc/X11/xorg.conf.d/*.conf`, `/etc/cdi/*.yaml`, the quadlet-generated unit (`systemctl cat`), `~/.ssh/config`, `authorized_keys.d/*` | copied verbatim into the report |
| **EV-PROCEDURE** | a documented maintainer procedure, as written and as run | the fenced command block extracted from the named document and heading at the run's git sha (never retyped into the harness), then a transcript of running it: each command, its output and its exit code | the reviewer can diff the block against the document and see every command ran as written; placeholders (`<registry>`, `<ref>`) are the only substitutions and the index lists each; any harness-only step between commands is marked as such |
| **EV-TIMELINE** | one timestamped log of everything the harness did | every `mon_cmd`, QMP send, `kubectl apply`, `podman exec`, assertion, with ISO timestamps | the spine the other kinds hang off; a reviewer reads it top to bottom |
| **EV-PHOTO** / **EV-PHONEVIDEO** | T4 only: a photograph or phone video of the physical screen, the cable being pulled, the KVM being switched | taken by the tester | the only proof that photons reached a human; timestamp visible or stated |

Where a story below says "common set", it means the set its feature's preamble
defines.

### Report layout

Each CI job writes one directory, one subdirectory per story it ran, and
uploads it as its own artifact (`evidence-static`, `evidence-smoke`,
`evidence-vm-<shard>`); `coverage-gate` reads them side by side.
`ci/evlib.py`'s docstring is the format's reference.

```
artifacts/
  run.json                      # VM shards: QEMU, guest kernel and podman versions, image ids, git sha, date
  timeline.log                  # EV-TIMELINE for the job
  S7.7.4/
    evidence.md                 # the index: PASS/FAIL, every check in the order it ran, what was
                                #   recorded but not asserted, one line per file saying what to look for
    meta.tsv checks.tsv notes.tsv files.tsv result   # what evidence.md is rendered from
    timeline.log                # this story's lines of the EV-TIMELINE
    01-wpctl-status-before.txt  # EV-STATE; files are numbered in the order they were captured
    02-wpctl-status-after.txt
    03-wpctl-status.diff        # EV-DIFF
    04-audio-1100hz.wav         # EV-AUDIO
    05-level.png                # spectrogram, or the level plot at the story's pitch
    06-analysis.txt             # analyser verdict
    07-pids-before.txt 08-pids-after.txt   # EV-PIDS (incl. pod restartCount)
    09-client-log.txt           # EV-LOG-CLIENT
    10-desktop-log.txt          # EV-LOG-DESKTOP slice
    11-display/ 11-display.gif  # EV-VIDEO: raw frames with their index, and the assembled gif
    qemu.log                    # EV-QEMU: the QMP commands the story sent (operator phase)
    h-checks.tsv h01-shot.png   # a VM story written from both sides: the host's additions carry an h
  …                             #   prefix, so copying the guest's files back never overwrites them
```

`evidence.md` is the human entry point. It answers, in order: what was the
machine like before; what did the harness do; what is it like after; where in
the attached files is each claim visible; did the assertion pass. On failure
the same directory also receives the diagnostics the harness already prints
(`fail()` in `vm-guest.sh`), so a red story is reviewable too.

### Rules

1. **Before and after, never just after.** A single post-state cannot show a
   change happened. Every state capture is a pair plus a diff.
2. **Capture even on pass.** Evidence exists for the reviewer, not for
   debugging.
3. **Name the moment.** Each screenshot or capture is tied to a timeline entry.
4. **Prove the negative too.** Where a story says something must *not* happen
   (no restart, no reflow, no leak), the evidence must show the thing that
   would have changed if it had (the pid, the geometry, the env var,
   `restartCount`).
5. **The client's view counts.** Where a client container is involved, capture
   its view (EV-SHOT-CLIENT, EV-LOG-CLIENT, `restartCount`) alongside the
   machine's view.
6. **Audio is heard, not inferred.** Any story about sound attaches an
   EV-AUDIO or EV-AUDIO-REC; a socket being connectable is not sound. "No
   gap" is measured twice: as quiet inside the capture, and as capture time
   missing against the wall clock (EV-AUDIO above).
7. **"Without restarting" is a measurement.** It means the same container id,
   `restartCount` 0 (or unchanged), and the same application pid, captured
   before and after.
8. **Procedures are run as written.** A story that follows a documented
   maintainer procedure runs the block extracted from the document
   (EV-PROCEDURE), not a copy kept in the harness. A procedure that passes
   only with a harness-added step is at best 🟡, because the maintainer does
   not have the harness.

---

## E1 — Image build and supply chain

### F1.1 Base / application split

**S1.1.1 The application layer builds fully offline**
- Requirement: `Containerfile`, `Containerfile.plugin` and `Containerfile.screenshot` build with `--network=none` against their prebuilt bases.
- Acceptance: all three builds succeed under `podman build --network=none --pull=never` (`--network=none` alone governs only `RUN` steps; podman would still fetch a missing `FROM` or `COPY --from` image).
- Evidence: build output of each showing `--network=none` on the command line and the final image id; `podman image inspect` of each result (EV-STATE).
- Tier: T2 · Coverage: ✅ `ci.yml` "application layers (offline gate)" builds all three with `--network=none --pull=never` and saves each build's output (the command line, every step, the image id it ends with) and `podman image inspect` of the result under `artifacts/S1.1.1/` (artifact `evidence-smoke`). `ci.yml` `images` and `base-rebuild.yml` also build them with `--network=none` (job log only).

**S1.1.2 Bases rebuild from current upstream**
- Requirement: the three base images build from scratch against the live UBI image and Rocky repos, and the offline layers still build on the result.
- Acceptance: weekly `--pull --no-cache` rebuild succeeds and the offline builds pass on it.
- Evidence: build logs; `rpm -qa` of the fresh base (EV-STATE) diffed against the previous week's (EV-DIFF) so package drift is visible.
- Tier: T2 · Coverage: ❌ evidence not saved: `base-rebuild.yml` uploads nothing and records no `rpm -qa` list or week-on-week diff; the weekly rebuild and the offline builds on it are asserted by `base-rebuild.yml`.

**S1.1.3 Base images are content-addressed**
- Requirement: `ci/build-bases.sh` reuses a GHCR base whose tag is the hash of its inputs and rebuilds only on a miss.
- Acceptance: unchanged inputs → "reused cached base"; a changed input → a different tag and a rebuild; and the tag `base-rebuild.yml` pushes for the same inputs equals `content_tag`'s (it computes the hash with its own inline copy).
- Evidence: the script's stdout for both cases; the two computed tags (EV-STATE).
- Tier: T1 · Coverage: ✅ `script-unit` runs `ci/build-bases.sh` in a copy of its inputs against a fake registry (a fake `podman` first on `PATH`): an empty registry gives three misses and three builds; with those refs in it all three are reused and nothing is built; a changed input (`Containerfile.base`) gets a new tag and a rebuild while the other two are reused. `base-rebuild.yml`'s own push step, run on the same inputs, pushes exactly the tags `build-bases.sh` pulls. Each run's stdout, the third run's `podman` calls and both tag lists are under `artifacts/S1.1.3/` (artifact `evidence-static`).

**S1.1.4 Build ARGs are global**
- Requirement: every `ARG` in every `Containerfile*` precedes the first `FROM`.
- Acceptance: the ARG-scoping check passes.
- Evidence: the check's stdout listing the files inspected.
- Tier: T0 · Coverage: ✅ `ci.yml` "build args stay global (multi-stage ARG scoping)" saves the check's output under `artifacts/S1.1.4/` (artifact `evidence-static`): each `Containerfile*` it read, with its ARG count and the position of its first FROM (an ARG after that FROM would be quoted by name, and fail the check).

**S1.1.5 Rocky repos fill gaps only**
- Requirement: UBI packages win over Rocky (priority 99 vs 200); Rocky supplies only what UBI lacks.
- Acceptance: in the base image, `rpm -qi glibc` reports a Red Hat vendor; `rpm -qi xorg-x11-server-Xorg` reports Rocky.
- Evidence: `rpm -qa --qf '%{NAME} %{VENDOR}\n'` of the base (EV-STATE), with the two named rows quoted in the index.
- Tier: T2 · Coverage: ✅ `ci.yml` "the built image's contents" saves `rpm -qa --qf '%{NAME} %{VENDOR}'` of the base image, sorted, and checks glibc's vendor is `Red Hat, Inc.` and xorg-x11-server-Xorg's `Rocky Enterprise Software Foundation`, the two rows quoted in the index, under `artifacts/S1.1.5/` (artifact `evidence-smoke`).

**S1.1.6 The client toolkit is staged from the screenshot image**
- Requirement: `Containerfile`'s `tools` stage copies `/screenshot` into `/usr/libexec/desktop-tools/` with mode 0755, from `TOOLS_IMAGE`.
- Acceptance: `ls -l` in a scratch container shows `-rwxr-xr-x`; a build with `--build-arg TOOLS_IMAGE=<other>` stages that image's binary.
- Evidence: the `ls -l` and `sha256sum` of the staged binary vs the source image's (EV-STATE).
- Tier: T2 · Coverage: ✅ `ci.yml` "the built image's contents" saves `ls -l` and `sha256sum` of the staged `/usr/libexec/desktop-tools/screenshot` (`-rwxr-xr-x`) and the `sha256sum` of `/screenshot` in the screenshot image (equal); then rebuilds the desktop image with `--build-arg TOOLS_IMAGE=` a scratch image holding a marker file and checks the marker is what gets staged, keeping that build's output and both sums; under `artifacts/S1.1.6/` (artifact `evidence-smoke`).

### F1.2 Image contents

**S1.2.1 Session user identity**
- Requirement: user `desktop` uid 61000, group `desktop` gid 61000, supplementary groups `video input audio render tty`, home `/home/desktop`.
- Acceptance: `id desktop` in a scratch container matches exactly.
- Evidence: `id desktop`, `getent passwd desktop`, `getent group video input audio render tty` (EV-STATE).
- Tier: T2 · Coverage: ✅ `ci.yml` "the built image's contents" saves `id desktop`, `getent passwd desktop` and `getent group` of the six groups from a scratch container of the image, and checks uid and gid 61000, exactly the supplementary groups audio input render tty video, and the home, under `artifacts/S1.2.1/` (artifact `evidence-smoke`).

**S1.2.2 Session dotfiles come from `/etc/skel`**
- Requirement: `/home/desktop/.mwmrc` and `.Xdefaults` are byte-identical to the repo files.
- Acceptance: `cmp` inside a scratch container.
- Evidence: `sha256sum` of both pairs (EV-STATE).
- Tier: T2 · Coverage: ✅ `ci.yml` "the built image's contents" saves `sha256sum` of `/home/desktop/.mwmrc` and `.Xdefaults` in a scratch container of the image and of the repo files, and checks both pairs equal, under `artifacts/S1.2.2/` (artifact `evidence-smoke`).

**S1.2.3 PipeWire native socket exported**
- Requirement: `/usr/share/pipewire/pipewire.conf` lists `/run/desktop-audio/pipewire-0` in the `protocol-native` sockets.
- Acceptance: in the built image the `protocol-native` `sockets` entry lists `/run/desktop-audio/pipewire-0` (the build's `grep -q` gate only finds `desktop-audio` somewhere in the file); runtime proven by S4.1.1.
- Evidence: the patched config block (EV-CONFIG).
- Tier: T2 · Coverage: ✅ `ci.yml` "the built image's PipeWire patches" reads the `protocol-native` entry out of the built image, checks that its uncommented `sockets` line lists `/run/desktop-audio/pipewire-0`, and saves the entry under `artifacts/S1.2.3/` (artifact `evidence-smoke`); outcome by S4.1.1.

**S1.2.4 module-rt takes the rlimit path**
- Requirement: `rlimits.enabled = true`, `rtportal.enabled = false`, `rtkit.enabled = false` appear exactly once in the `module-rt` block of `pipewire.conf` (the daemon), `pipewire-pulse.conf` and `client.conf` (its clients). PipeWire 1.4 ships no `client-rt.conf`.
- Acceptance: in each of the three files (a missing file fails), the `module-rt` block holds each of the three settings exactly once (the build's gate counts only `rtkit.enabled`, over the whole file, and fails on a missing file); runtime outcome S4.3.2, for the daemon (no story checks a client's threads).
- Evidence: the three patched blocks (EV-CONFIG).
- Tier: T2 · Coverage: ✅ `ci.yml` "the built image's PipeWire patches" saves the `module-rt` entry of `pipewire.conf`, `pipewire-pulse.conf` and `client.conf` from the built image, with its `ls /usr/share/pipewire`, and checks each of the three settings exactly once in each (nine checks), under `artifacts/S1.2.4/` (artifact `evidence-smoke`); the build itself fails on a missing file. Outcome, for the daemon, by `guest:verify_privileges` (S4.3.2).

**S1.2.5 pipewire-pulse export drop-in installed**
- Requirement: the drop-in serves `unix:native` and `unix:/run/desktop-audio/pulse`.
- Acceptance: file present with both addresses; runtime S4.1.1.
- Evidence: the file (EV-CONFIG).
- Tier: T2 · Coverage: ✅ `ci.yml` "the built image's contents" saves the drop-in from a scratch container of the image and checks its `server.address` list has `"unix:native"` and `"unix:/run/desktop-audio/pulse"`, under `artifacts/S1.2.5/` (artifact `evidence-smoke`); the runtime half is S4.1.1.

**S1.2.6 All shipped scripts are executable and shellcheck-clean**
- Requirement: every script under `image/` and `deploy/host/usr/local/` passes `shellcheck -S error`; every script `Containerfile` installs is mode 0755; the shellcheck list in `ci.yml` is complete.
- Acceptance: a `find`-derived list equals the list in `ci.yml`; `find /usr/local/bin /etc/X11/xinit/xinitrc.desktop -type f ! -perm 0755` in the image is empty.
- Evidence: both lists and their diff (EV-DIFF); the `find` output (EV-STATE).
- Tier: T0/T2 · Coverage: ❌ list completeness and modes untested; `ci.yml` "shellcheck (error severity)" checks a hand list that already omits `image/session/xinitrc.desktop` and `deploy/host/usr/local/libexec/desktop-session-lead`.

**S1.2.7 Image carries no NVIDIA userspace**
- Requirement: no `nvidia_drv.so`, `libnvidia*`, `libglxserver_nvidia*` in the image.
- Acceptance: `find /usr/lib64 /usr/lib -name '*nvidia*'` is empty.
- Evidence: the (empty) find output and `rpm -qa | grep -i nvidia` (EV-STATE).
- Tier: T2 · Coverage: ✅ `ci.yml` "the built image's contents" saves `find /usr/lib64 /usr/lib -name '*nvidia*'` and `rpm -qa | grep -i nvidia` from a scratch container of the image, both empty, under `artifacts/S1.2.7/` (artifact `evidence-smoke`).

**S1.2.8 Entry point and stop signal**
- Requirement: `CMD` is `/usr/local/bin/desktop-init`; `STOPSIGNAL` is `SIGTERM`.
- Acceptance: `podman inspect` shows both.
- Evidence: `podman inspect --format '{{.Config.StopSignal}} {{.Config.Cmd}}'` (EV-STATE).
- Tier: T2 · Coverage: ✅ `ci.yml` "the built image's contents" saves `podman image inspect --format '{{.Config.StopSignal}} {{.Config.Cmd}}'` of the image and checks `SIGTERM` and `[/usr/local/bin/desktop-init]`, under `artifacts/S1.2.8/` (artifact `evidence-smoke`).

---

## E2 — Container boot and supervision (`desktop-init`)

### F2.1 Boot oneshots

**S2.1.1 Oneshots run in the documented order**
- Requirement: `ensure-vt-devices` → `align-device-groups` → `host-shell-setup` → `preflight-check` → `xorg-gpu-conf` → `xorg-monitor-conf` → `publish-tools`, each once per container start (`align-device-groups` also runs before every audio start, S2.4.6, and that run can begin before `oneshots done` is logged).
- Acceptance: the first log line of each boot oneshot appears in that order before `oneshots done` (`ensure-vt-devices` logs only when it creates a node).
- Evidence: EV-LOG-DESKTOP from container start to `oneshots done`, the seven first-lines highlighted in the index.
- Tier: T2 · Coverage: ✅ `smoke` saves the first boot's log up to `oneshots done` and checks each oneshot's first line in the documented order before it (`ensure-vt-devices` included: on this runner it creates the VT nodes), each checked line number in the index, and that the GPU decision, the monitor generator's line, `host shell configured` and `tools published to` each appear once, under `artifacts/S2.1.1/` (artifact `evidence-smoke`).

**S2.1.2 A failing oneshot never blocks the session**
- Requirement: any oneshot exiting nonzero is logged and the session still launches; `publish-tools` failure logs `ERROR: publish-tools failed`.
- Acceptance: with `/usr/libexec/desktop-tools` emptied, the container still writes `/run/desktop-init-ready` and starts the session; the ERROR line is present.
- Evidence: EV-LOG-DESKTOP showing the ERROR line followed by `oneshots done` and the session starting; EV-PIDS showing the session alive.
- Tier: T2 · Coverage: ✅ `smoke` restarts the desktop on an image rebuilt with `/usr/libexec/desktop-tools` emptied (the original is tagged back after) and saves the build, that start's log (`ERROR: publish-tools failed`, then `oneshots done`, then the X server starting, line numbers in the index), the empty directory, the ready marker and the X session's processes, xdpyinfo answering, under `artifacts/S2.1.2/` (artifact `evidence-smoke`).

**S2.1.3 Boot markers**
- Requirement: `/run/desktop-init.pid` holds desktop-init's own host pid; `/run/desktop-init-ready` is written after the oneshots and the runtime-dir wait, just before the first X session starts, so it never depends on the session (`desktop-init` writes it before its session loop).
- Acceptance: the pid resolves on the host to `desktop-init`; the ready marker's mtime precedes the first Xorg's start time.
- Evidence: `cat /run/desktop-init.pid`, host `cat /proc/<pid>/comm`, `ls -l /run/desktop-init-ready` (EV-STATE).
- Tier: T2 · Coverage: ✅ `smoke` saves the pid file and the host's `/proc/<pid>/comm` (`desktop-init`), `ls -l --full-time` of the ready marker and the first Xorg's process line, and checks the marker is older than that Xorg's start (boot instant from `CLOCK_BOOTTIME` plus its start ticks; a few hundredths of a second apart on the runner); and, from a scratch container of the image whose X session cannot start, the ready marker and its log, under `artifacts/S2.1.3/` (artifact `evidence-smoke`).

**S2.1.4 `/run` and `/tmp` are fresh per container start**
- Requirement: both are tmpfs, so nothing stale survives a restart.
- Acceptance: `/proc/self/mounts` in the running container shows tmpfs on `/run` and `/tmp`, before and after `systemctl restart desktop.service`. (A sentinel file proves nothing here: the unit runs `podman run --replace --rm`, so every start is a new container.)
- Evidence: the mount table lines (EV-STATE); `ls` of the sentinels before and after (EV-DIFF).
- Tier: T2 · Coverage: ✅ `smoke` saves the `/run` and `/tmp` lines of the container's `/proc/self/mounts` (tmpfs) before and after `systemctl restart desktop.service`, and `ls -l` of a sentinel written in each before, gone after, with their diff, under `artifacts/S2.1.4/` (artifact `evidence-smoke`).

### F2.2 Runtime directory and seat handover

**S2.2.1 The host login session's runtime dir is adopted**
- Requirement: when `/run/user/61000` appears within 15 s, desktop-init uses it and logs `runtime dir /run/user/61000 provided by the host login session`.
- Acceptance: a file created on the host under it is visible in the container; the log line appears (polled).
- Evidence: EV-LOG-DESKTOP line; host `findmnt /run/user/61000` and container `ls /run/user/61000` showing the probe file (EV-STATE); `loginctl list-sessions` (EV-STATE).
- Tier: T3 · Coverage: ✅ `guest:phase_deploy` saves `loginctl list-sessions`, the host's `findmnt /run/user/61000`, the container's `ls -la` of it with the host's probe file listed, and the adoption log line, under `artifacts/S2.2.1/` (artifact `evidence-vm-core`); `smoke` checks only the host side.

**S2.2.2 Standalone fallback fabricates the runtime dir**
- Requirement: with no host session unit, desktop-init creates `/run/user/61000` (0700, desktop) after the wait, logs `no host login session appeared; creating ... standalone`, and the desktop works.
- Acceptance: `systemctl mask --now desktop-session`, restart desktop; the fallback line is logged; audio sockets export; the X session starts (T3). Unmask and restart afterwards. (`disable` is not enough: the quadlet's `Wants=desktop-session.service` starts the unit again whenever `desktop.service` starts.)
- Evidence: EV-LOG-DESKTOP (fallback line); `stat` of the dir (EV-STATE); EV-SHOT of the desktop up (T3); EV-AUDIO of a tone (T3).
- Tier: T2 · Coverage: ❌ the acceptance's own procedure (desktop-session masked on a full deploy, the X session up, T3 EV-SHOT and EV-AUDIO) is not run. Saved: `smoke`'s scratch container of the image, with no host login session at all, logs the fallback line and makes `/run/user/61000` `drwx------ desktop:desktop`, under `artifacts/S2.2.2/` (artifact `evidence-smoke`).

**S2.2.3 tty1 is handed to the session user**
- Requirement: `/dev/tty1` in the container is owned `desktop:tty` before every session start.
- Acceptance: `stat -c %U:%G /dev/tty1` is `desktop:tty`, still after an X session restart.
- Evidence: the `stat` output before and after a session restart (EV-STATE pair).
- Tier: T2 · Coverage: ✅ `smoke` saves `stat -c '%U:%G %a'` of `/dev/tty1` in the container before and after an X session restart (mwm killed with SIGKILL; a new Xorg answers), `desktop:tty` both times, under `artifacts/S2.2.3/` (artifact `evidence-smoke`).

**S2.2.4 Audio export dir exists even without the host mount**
- Requirement: `/run/desktop-audio` is created 1777 inside the container if the bind mount is absent.
- Acceptance: `podman run` without that volume: dir exists, mode 1777, sockets appear in it.
- Evidence: `ls -ld` and `ls -l` of the dir (EV-STATE).
- Tier: T2 · Coverage: ✅ `smoke` runs a scratch container of the image with none of the quadlet's mounts and saves its mount table (nothing at `/run/desktop-audio`), `ls -ld` of the directory (`drwxrwxrwt`) and `ls -l` with PipeWire's `pipewire-0` and `pulse` sockets in it, under `artifacts/S2.2.4/` (artifact `evidence-smoke`).

### F2.3 X session supervision

**S2.3.1 The session is its own process session on tty1**
- Requirement: `start-session` runs via `setsid -c` as uid 61000 with the documented environment and tty1 as controlling tty.
- Acceptance: `ps -o sess=,tty= -p <Xorg pid>` shows sid == the session leader pid and `tty1`; the leader's environment (the leader is `startx`) holds exactly the variables `run_session` in `image/init/desktop-init` sets, plus the `PWD` and `SHLVL` bash adds to anything it execs, and no `NVIDIA_*` or other container variables.
- Evidence: EV-PIDS with sid and tty columns; `tr '\0' '\n' < /proc/<leader>/environ` (EV-STATE).
- Tier: T3 · Coverage: ❌.

**S2.3.2 The session restarts after Xorg exits, and the operator gets the desktop back**
- Requirement: when the session exits, desktop-init logs `session exited (rc=N); restarting in 3s`, a new session starts, and within ~45 s the operator sees the desktop again (root colour, initial xterm, mwm frames).
- Acceptance: kill Xorg as uid desktop; new Xorg and mwm pids; display answers.
- Evidence: EV-VIDEO of the display through the restart (blank → desktop back); EV-PIDS before/after (Xorg and mwm changed, desktop-init unchanged); EV-LOG-DESKTOP.
- Tier: T3 · Coverage: ❌ evidence not saved; `guest:verify_audio_lifecycle` kills Xorg but waits only for any mwm, not for new Xorg and mwm pids. The restart is proven with saved evidence only for "Quit session" (`operator-e2e:menu_quit_session`, in `artifacts/S11.1.1/`).

**S2.3.3 Session cleanup is scoped by session id and session tag, never by uid**
- Requirement: after a session exits, every pid in that session id, and every desktop-user process whose environment carries that run's `DESKTOP_SESSION_TAG`, is TERMed then KILLed after 5 s; same-uid processes outside it (the audio tree, the host's `desktop-session-lead`, any other uid-61000 process on the host, processes started by `podman exec`) are untouched. The session id is the one `startx`, `xinit` and Xorg share; xinit starts the X client in a session of its own, which mwm leads (and each xterm's shell leads another), and the tag is what reaches those and whatever was started from them. A process that starts itself with a scrubbed environment escapes the tag, and so the cleanup unless it is in the server's session.
- Acceptance: start a `nohup sleep` from the session's xterm, then kill Xorg; within 6 s no process carries the old leader's session id or the old tag; the old mwm, xterm and `sleep` are gone; PipeWire pid unchanged; host `desktop-session-lead` pid unchanged; a deliberately spawned uid-61000 `sleep` on the host survives.
- Evidence: EV-PIDS before/after listing every uid-61000 process on the **host**, the index marking which must persist.
- Tier: T3 · Coverage: ❌ evidence not saved; `guest:verify_audio_lifecycle` asserts only that PipeWire keeps its pid when Xorg is killed, and nothing checks the host's other uid-61000 processes.

**S2.3.4 Session leader sanity check never fires in a normal boot**
- Requirement: `WARNING: ... is not its own session leader` never appears in a normal boot or after a restart of either tree.
- Acceptance: grep is empty.
- Evidence: EV-LOG-DESKTOP with the (empty) grep result stated.
- Tier: T2 · Coverage: ✅ `smoke` saves the desktop's log after its boot, an audio stack restart and an X session restart (both counted in the index), with the grep for `is not its own session leader` over it stated empty, and the log of the start after a stop, checked the same way, under `artifacts/S2.3.4/` (artifact `evidence-smoke`).

**S2.3.5 Postmortem runs on abnormal exit only**
- Requirement: `session-postmortem` runs after every abnormal end of the X session and never after a clean one; it prints the Xorg log tail and a `LIKELY CAUSE` verdict for each known signature, and a distinct line when no Xorg log exists. Abnormal is a nonzero session exit, or an X server that did not shut down cleanly: xinit exits 0 whenever the server goes away, killed or crashed included, so `desktop-init` reads the server's log, which says `Server terminated successfully` only after a clean shutdown, and logs `the X server did not shut down cleanly` before the postmortem.
- Acceptance: T1 with a fabricated log per signature and with no log; T2/T3 the real `postmortem:` lines after Xorg is killed with SIGKILL (the session still exits `rc=0`; `desktop-init`'s `did not shut down cleanly` line comes first), and none after a clean end (Quit session, `rc=0`). Which ends get a postmortem is `desktop-init`'s doing, so only T2/T3 can prove it.
- Evidence: T1 the script's stdout per case (EV-STATE); T2 EV-LOG-DESKTOP slice containing `postmortem:` lines.
- Tier: T1/T2 · Coverage: ✅ the T1 half: `script-unit` runs the postmortem on fabricated Xorg logs, one per known signature (each gets the log's tail and its `LIKELY CAUSE`), one with no known signature (the tail, no verdict), none at all (its own line), and with `SERVICE_RESULT=success` (silent), under `artifacts/S2.3.5/` (artifact `evidence-static`). The T2/T3 half, at T3: `guest:verify_postmortem` kills Xorg with SIGKILL and saves the desktop's log from just before: `the X server did not shut down cleanly`, the postmortem with the killed server's log tail, then `session exited (rc=0)`, in that order, under `artifacts/S2.3.5/` (artifact `evidence-vm-core`); `operator-e2e:menu_quit_session` checks that Quit session logs `session exited (rc=0)` and no `postmortem:` line, its desktop log under `artifacts/S11.1.1/` (artifact `evidence-vm-operator`).

**S2.3.6 mwm exit ends the session and it restarts**
- Requirement: "Quit session" (or mwm dying) ends the X session and desktop-init starts a fresh one; the operator sees the desktop return.
- Acceptance: kill mwm as uid desktop (SIGTERM, `kill`'s default: mwm quits without asking, since the image drops `kill` from mwm's `showFeedback`); Xorg pid changes; new mwm; display answers.
- Evidence: EV-VIDEO; EV-PIDS before/after; EV-LOG-DESKTOP.
- Tier: T3 · Coverage: 🟡 the acceptance's trigger is asserted at T2, its own EV-VIDEO not taken: `smoke` sends mwm SIGTERM as the session user and saves desktop-init, Xorg and mwm before and after (a new Xorg and mwm, the same desktop-init, the display answering) and the log's clean end (`session exited (rc=0)`, no postmortem), under `artifacts/S2.3.6/` (artifact `evidence-smoke`). "Quit session" is asserted with its video, pid tables and desktop log by `operator-e2e:menu_quit_session` in `artifacts/S11.1.1/`.

### F2.4 Audio supervision

**S2.4.1 The audio tree is its own session with its own supervisor**
- Requirement: `start-audio` runs via `setsid` (no controlling tty) as uid 61000 under `supervise_audio`; the leader pid is in `/run/desktop-audio-leader.pid`.
- Acceptance: PipeWire's sid equals the recorded leader pid; `ps -o tty= -p <pipewire>` is `?`.
- Evidence: EV-PIDS with sid/tty; the leader pid file (EV-STATE).
- Tier: T2 · Coverage: ✅ `smoke` saves the leader pid file, the audio tree's process table (`ps -s <leader>`: pid, ppid, session, tty, user) and the leader's parent chain, and checks pipewire is in the leader's session with no tty (`?`) as uid 61000, the leader's parent a child of desktop-init, under `artifacts/S2.4.1/` (artifact `evidence-smoke`).

**S2.4.2 Any daemon exiting restarts the whole stack**
- Requirement: `start-audio` returns on the *first* of the three exiting, logs which, TERMs the survivors, and a complete new set starts after 3 s.
- Acceptance: kill pipewire → three new pids, line logged, export reachable (✅). Kill wireplumber alone → same with `wireplumber exited` (❌). Kill pipewire-pulse alone → same (❌).
- Evidence: EV-PIDS before/after for the three daemons; EV-LOG-DESKTOP with the `<name> exited` and `restarting in 3s` lines; EV-AUDIO of a tone after recovery.
- Tier: T2/T3 · Coverage: ❌ evidence not saved; `smoke`, `guest:verify_audio_lifecycle` and `operator-e2e:sound_persistence` kill only pipewire and check only its new pid.

**S2.4.3 Stale export sockets are cleared before every audio start**
- Requirement: the socket and lock files are removed before each start so PipeWire can re-bind.
- Acceptance: after a PipeWire restart, `pactl info` over the export succeeds.
- Evidence: `ls -li /run/desktop-audio` before/after (inodes changed) (EV-STATE); `pactl info` output.
- Tier: T2/T3 · Coverage: ✅ `guest:verify_audio_lifecycle` saves `ls -li /run/desktop-audio` before PipeWire is killed and after it is back, with the diff (every socket and lock file has a new inode), and `pactl info` over the export afterwards, under `artifacts/S2.4.3/` (artifact `evidence-vm-core`); `smoke` asserts only that the socket exists.

**S2.4.4 WirePlumber waits for PipeWire's socket**
- Requirement: `start-audio` waits up to 10 s for `$XDG_RUNTIME_DIR/pipewire-0` before launching wireplumber.
- Acceptance: T1 with a fake `pipewire` that binds after 2 s; T3 wireplumber alive after boot and after a stack restart.
- Evidence: T1 stdout with timestamps; T3 EV-PIDS.
- Tier: T1/T3 · Coverage: ✅ the T1 half: `script-unit` runs `start-audio` with fake daemons first on `PATH`; with a `pipewire` that binds after 2 s, wireplumber starts once the socket exists, and with one that never binds it starts after the bounded wait (about 10 s). The timestamped stdout and each fake's own log are under `artifacts/S2.4.4/` (artifact `evidence-static`). The T3 half: `guest:verify_audio_lifecycle` saves the audio daemons' process table (pid, ppid, session, user, start time) with the desktop up and again after pipewire is killed and the stack restarts, wireplumber alive both times with a new pid after the restart, under `artifacts/S2.4.4/` (artifact `evidence-vm-core`).

**S2.4.5 A daemon ignoring SIGTERM is escalated**
- Requirement: survivors not exited 5 s after TERM are KILLed; `start-audio` always returns.
- Acceptance: T1 fake daemon trapping TERM: exit within ~6 s, `ignored SIGTERM; killing` logged.
- Evidence: stdout with timestamps.
- Tier: T1 · Coverage: ✅ `script-unit` runs `start-audio` with fake daemons: when pipewire-pulse exits (status 7) and wireplumber ignores SIGTERM, start-audio names the first exit, TERMs the survivors, logs `ignored SIGTERM; killing` and KILLs the holdout after its 5 s of grace, then returns the first exit's status; none of the three daemons outlives it. The timestamped stdout and each fake's log are under `artifacts/S2.4.5/` (artifact `evidence-static`).

**S2.4.6 Audio gid is re-aligned before every audio start**
- Requirement: `align-device-groups.sh audio` runs before each stack start, so a card that appears after a soundless boot is openable.
- Acceptance: VM booted **without** `intel-hda`, and with the host's `audio` group renumbered away from the image's (on the stock VM both are 63, so the check could not fail): first audio start logs `audio: no device nodes present, skipping`; hot-add `usb-audio`; kill pipewire; after restart the container's `audio` gid equals the host node's gid and WirePlumber lists the card.
- Evidence: EV-LOG-DESKTOP (both align lines); `getent group audio` in the container and `stat -c %g` of the host node (EV-STATE pair); `wpctl status` after; EV-AUDIO of a tone through the card.
- Tier: T3 · Coverage: ❌ (see also S4.7.10, S7.7.9).

**S2.4.7 Export sockets are connectable by other uids**
- Requirement: `umask 0000` makes the exported sockets world-connectable.
- Acceptance: as the unprivileged `rocky` user on the VM host, `pactl info` succeeds and `paplay` of a tone is heard.
- Evidence: `ls -l /run/desktop-audio` (EV-STATE); `id` of the probe user; EV-AUDIO.
- Tier: T3 · Coverage: ❌.

### F2.5 Shutdown

**S2.5.1 SIGTERM stops both trees cleanly**
- Requirement: on SIGTERM desktop-init kills the audio supervisor loop first, stops both trees by sid, exits 0; the audio stack is not restarted during shutdown. Every process of both trees exits on the stop's SIGTERM (podman sends one to every process of the container, which has no pid namespace of its own; desktop-init sends its own): none lasts until the KILL desktop-init sends 5 s later.
- Acceptance: `systemctl stop desktop.service` returns well within the 10 s stop timeout; the exit code from a `podman wait desktop` started beforehand is 0; no Xorg, mwm, xterm, pipewire, wireplumber or pipewire-pulse process remains on the host; the desktop's log, followed from before the stop through its k8s-file (by descriptor: `podman logs -f` ends with the `--rm` container and can miss its last lines), has no `restarting in 3s` after `SIGTERM:`. (Not `podman stop`: the unit runs `podman run --replace --rm` with `Restart=always`, so systemd starts a new container at once and nothing is left to inspect. The host login session's own uid-61000 processes, the user manager and its bus, rightly remain.)
- Evidence: `time systemctl stop desktop.service` and the `podman wait` exit code (EV-STATE); EV-PIDS of all uid-61000 host processes before and after; EV-LOG-DESKTOP tail from `SIGTERM:` (the followed log).
- Tier: T2 · Coverage: ✅ `smoke` saves `time systemctl stop desktop.service` (well inside 10 s), the exit code from a `podman wait` started before (0), every uid-61000 host process before and after and sampled every 0.5 s during the stop (the last process of either tree gone within 4 s: none waits for desktop-init's KILL), and the log followed from before the stop, from `SIGTERM:` on, with no `restarting in 3s`, under `artifacts/S2.5.1/` (artifact `evidence-smoke`).

**S2.5.2 The X socket is unlinked by the server, not pinned by a mount**
- Requirement: after a stop, `/tmp/.X11-unix/X0` is gone or dead; the next start creates a fresh working socket.
- Acceptance: stop, start, `xdpyinfo` works.
- Evidence: `ls -li /tmp/.X11-unix` across the cycle (EV-STATE pair).
- Tier: T2 · Coverage: ✅ `smoke` saves `ls -li /tmp/.X11-unix` with the desktop running, after a stop (no `X0`) and after the next start (a new `X0`; xdpyinfo answers, saved), with the diff, under `artifacts/S2.5.2/` (artifact `evidence-smoke`). The inode number can repeat on the runner's ext4 `/tmp`, so the check is that the stop left none.

### F2.6 Logging

**S2.6.1 Everything lands in `podman logs`**
- Requirement: desktop-init, the oneshots, the session and the audio stack write to `/dev/console`.
- Acceptance: `podman logs desktop` contains lines from each of `desktop-init:`, `preflight:`, `align-device-groups:`, `xorg-gpu-conf:`, `xorg-monitor-conf:`, `start-audio:`, `published`.
- Evidence: EV-LOG-DESKTOP of a full boot with the seven prefixes indexed.
- Tier: T2 · Coverage: ✅ `smoke` saves the first boot's whole log and checks each of the seven prefixes, its first line quoted in the index, under `artifacts/S2.6.1/` (artifact `evidence-smoke`).

**S2.6.2 The container log is bounded**
- Requirement: `LogDriver=k8s-file` and `--log-opt max-size=64m` both reach the running container.
- Acceptance: `podman inspect` shows `k8s-file` and a 64 MB size.
- Evidence: the inspect output (EV-STATE).
- Tier: T2/T3 · Coverage: ✅ `smoke` saves `podman inspect`'s log configuration of the running container (`Type` k8s-file, `Size` 64MB) under `artifacts/S2.6.2/` (artifact `evidence-smoke`) and checks both. `guest:verify_log_bounds` asserts the same on the VM (job log only), and `dryrun` checks the generated unit (S5.2.1).

---

## E3 — Display server and session

### F3.1 GPU driver selection (`xorg-gpu-conf.sh`)

**S3.1.1 NVIDIA path**
- Requirement: with `/dev/nvidiactl` (or `nvidia0`) **and** an injected `nvidia_drv.so`, write `20-gpu.conf` with `Driver "nvidia"` and a `ModulePath` covering it.
- Acceptance: on a real NVIDIA host (T4). Proving the NVIDIA paths with fabricated device nodes and a fake module was considered and rejected: the hardware-only stories are proven on hardware, by the guided hardware script.
- Evidence: the generated file (EV-CONFIG); the script's evidence lines (EV-LOG-DESKTOP); `glxinfo -B` (EV-STATE) and EV-PHOTO of the desktop.
- Tier: T4 · Coverage: 🔧 guided hardware script, not yet written.

**S3.1.2 NVIDIA nodes without the X driver fall back to modesetting**
- Requirement: nodes present, no `nvidia_drv.so` → both `warning:` lines and the modesetting branch.
- Acceptance: on a real NVIDIA host with an old toolkit (T4), for the reason S3.1.1 gives.
- Evidence: EV-CONFIG + EV-LOG-DESKTOP warnings; EV-PHOTO.
- Tier: T4 · Coverage: 🔧 guided hardware script, not yet written.

**S3.1.3 modesetting picks the first connected connector's card**
- Requirement: the first `connected` connector's card becomes `kmsdev`; otherwise `card0`.
- Acceptance: T1 fabricated sysfs (card0 disconnected, card1 connected → card1; none → card0). T3: `decision: modesetting driver on /dev/dri/card0` logged and in the file.
- Evidence: EV-CONFIG; EV-LOG-DESKTOP decision line; `cat /sys/class/drm/card*-*/status` (EV-STATE).
- Tier: T1/T3 · Coverage: ✅ `script-unit` runs `xorg-gpu-conf.sh` on fabricated sysfs (`GPU_SYS_DRM`, `GPU_DEV_DIR`): with card0's connector disconnected and card1's connected, card1 becomes `kmsdev` and the decision is logged; with no connector connected, card0 does and the script says it defaulted; under `artifacts/S3.1.3/` (artifact `evidence-static`). `guest:phase_deploy` saves the VM's connector statuses, xorg-gpu-conf's lines up to `decision: modesetting driver on /dev/dri/card0` (its first connected connector is card0-Virtual-1) and the `20-gpu.conf` naming that card as `kmsdev`, under `artifacts/S3.1.3/` (artifact `evidence-vm-core`).

**S3.1.4 No KMS device removes the config**
- Requirement: if the chosen node is absent, delete stale `20-gpu.conf` and log it.
- Acceptance: T1 pre-created file removed; T2: a scratch `podman run` of the image without `/dev/dri`, with a `20-gpu.conf` written first, removes it. (The build-smoke runner usually has KMS, and the production container is recreated on every start, so neither shows a stale file on its own.)
- Evidence: `ls /etc/X11/xorg.conf.d/` before/after (EV-STATE pair); EV-LOG-DESKTOP line.
- Tier: T1/T2 · Coverage: ✅ `script-unit` runs `xorg-gpu-conf.sh` with a stale `20-gpu.conf` and no node for the chosen card: the file is removed and the removal logged, under `artifacts/S3.1.4/` (artifact `evidence-static`). `smoke` runs it in a scratch container of the image without `/dev/dri`, a stale `20-gpu.conf` written first, and saves `ls /etc/X11/xorg.conf.d` before (the stale file) and after (none) with the logged removal, under `artifacts/S3.1.4/` (artifact `evidence-smoke`).

**S3.1.5 Evidence is logged before the decision**
- Requirement: DRM nodes, every connector's status and NVIDIA nodes are logged before `decision:`.
- Acceptance: order of lines.
- Evidence: EV-LOG-DESKTOP slice.
- Tier: T1/T2 · Coverage: ✅ `script-unit` on fabricated sysfs with two connectors: the DRM nodes, both connectors' statuses and the NVIDIA nodes are each logged before the decision, under `artifacts/S3.1.5/` (artifact `evidence-static`). `smoke` reads the real container's log this boot up to its decision: the DRM nodes, the runner's one connector and the NVIDIA nodes come before it; the runner's sysfs statuses are saved beside it, under `artifacts/S3.1.5/` (artifact `evidence-smoke`).

### F3.2 Rootless Xorg and device access

**S3.2.1 Xorg runs as the session user**
- Requirement: `needs_root_rights = no`; the running Xorg's uid is `desktop`.
- Acceptance: `ps -o user= -C Xorg` is `desktop`.
- Evidence: EV-PIDS; `cat /etc/X11/Xwrapper.config` (EV-CONFIG).
- Tier: T3 · Coverage: ✅ `guest:phase_deploy` saves the running Xorg's process line (user `desktop`) and `/etc/X11/Xwrapper.config` (`needs_root_rights = no`), and checks both, under `artifacts/S3.2.1/` (artifact `evidence-vm-core`).

**S3.2.2 Group gids are aligned to the host's device nodes**
- Requirement: for video/render/input/audio, the container group is renumbered to the host node's gid; collisions move the other group to a free gid ≥ 60000; missing groups are created; root-group and absent nodes are skipped with a log line; the final-state table and `id desktop` are logged; the narrow form touches only the named groups.
- Acceptance: T1 in a scratch container with fabricated nodes per branch; T3 preflight `desktop user can read` PASS for all three node kinds.
- Evidence: T1 `getent group` before/after per branch (EV-DIFF); T3 EV-LOG-DESKTOP align table + preflight lines; `ls -ln /dev/dri /dev/input /dev/snd` host and container (EV-STATE).
- Tier: T1/T3 · Coverage: ❌ no branch test and no evidence saved; the container preflight's `desktop user can read` lines are never asserted, so alignment shows only through rootless Xorg opening DRM and evdev (`guest:phase_deploy`, `e2e` "input: type into an xterm").

**S3.2.3 VT nodes are created when the runtime does not expose them**
- Requirement: `ensure-vt-devices.sh` creates `/dev/tty0` (c 4:0) and `/dev/tty1` (c 4:1), mode 620, `root:tty` (desktop-init then hands `tty1` to the session user), no-op when present.
- Acceptance: `stat -c '%F %t:%T %a' /dev/tty1` in the container is `character special file 4:1 620`; log says `created /dev/tty1` once.
- Evidence: the `stat` (EV-STATE); EV-LOG-DESKTOP line.
- Tier: T2 · Coverage: ✅ `smoke` saves ensure-vt-devices' lines this boot (`created /dev/tty0 (c 4:0)` and `created /dev/tty1 (c 4:1)`, once each: the runner's runtime exposes neither) and `stat` of both nodes in the container (character special, 4:0 and 4:1, 620; tty1 handed to `desktop:tty`), under `artifacts/S3.2.3/` (artifact `evidence-smoke`).

**S3.2.4 Xorg does not listen on TCP**
- Requirement: `-nolisten tcp`; nothing listens on 6000+ on the host network.
- Acceptance: `ss -ltn` on the VM host shows no 6000-range listener.
- Evidence: `ss -ltnp` (EV-STATE); `ps -o args= -C Xorg` showing `-nolisten tcp`.
- Tier: T3 · Coverage: ❌.

**S3.2.5 The session activates its VT, so the operator sees it**
- Requirement: Xorg `VT_ACTIVATE`s tty1 at start; the desktop is visible even if the console was on another VT.
- Acceptance: `fgconsole` is `1` after boot; `chvt 2`, kill Xorg, after restart `fgconsole` is `1` and the display shows the desktop.
- Evidence: `fgconsole` before/after (EV-STATE); EV-SHOT after restart showing the desktop, not a text console.
- Tier: T3 · Coverage: ❌.

**S3.2.6 The X socket is shared through the host directory**
- Requirement: Xorg's socket appears at the host's `/tmp/.X11-unix/X0`; a host process can render/capture.
- Acceptance: `test -S` on the host; the published `screenshot` captures `:0` from the host.
- Evidence: `ls -l /tmp/.X11-unix` (EV-STATE); the host capture PNG (EV-SHOT-CLIENT, host variant).
- Tier: T3 · Coverage: ✅ `guest:phase_deploy` saves `ls -l /tmp/.X11-unix` on the host and the host's own capture of `:0` (a PNG, kept now) under `artifacts/S3.2.6/` (artifact `evidence-vm-core`).

### F3.3 Session startup (`xinitrc.desktop`)

**S3.3.1 Local access control is open**
- Requirement: `xhost +local:` ran; any local uid connects without a cookie.
- Acceptance: `xhost` lists `LOCAL:`; a client with only the socket connects.
- Evidence: `xhost` output (EV-STATE).
- Tier: T3 · Coverage: ❌ `xhost` is never run or saved; `guest:phase_deploy` asserts only that a confined client holding just the socket opens `:0`.

**S3.3.2 Screensaver and DPMS are off, so the screen never blanks on the user**
- Requirement: `xset s off` and `xset -dpms` took effect.
- Acceptance: `xset q` shows `timeout:  0` and `DPMS is Disabled`.
- Evidence: `xset q` (EV-STATE); optionally an EV-SHOT after 11 idle minutes, non-blank.
- Tier: T3 · Coverage: ✅ `operator-e2e:s3_3_2` (the optional idle-minutes shot is not taken).

**S3.3.3 Root window colour and initial xterm**
- Requirement: the operator sees a `#101216` root, one xterm at `100x30+60+60`, and mwm frames.
- Acceptance: screendump pixel at an uncovered root coordinate is `16,18,22`; an xterm window exists; mwm running.
- Evidence: EV-SHOT of the session as `xinitrc.desktop` leaves it (the operator phase's first look), with the sampled coordinate and value in the index; `xwininfo -root -tree` (EV-STATE).
- Tier: T3 · Coverage: ✅ `operator-e2e:s3_3_3` (the sampled root pixel, `xwininfo -geometry 100x30+60+60`, the mwm frame, mwm's pid as `desktop`).

### F3.4 Fixed monitor layout

**S3.4.1 Opt-in: absent or output-less config generates nothing**
- Requirement: no file, or comments/globals only → no `30-monitors.conf`, stale one removed, no-op logged.
- Acceptance: as stated.
- Evidence: `ls /etc/X11/xorg.conf.d/` (EV-STATE); EV-LOG-DESKTOP no-op line; T3 `xrandr` showing autodetected geometry.
- Tier: T0/T2/T3 · Coverage: ✅ `layout-tests` (no file, comments only, globals only: each removes a stale config and logs the no-op; `ls` of `xorg.conf.d` and the log per case) under `artifacts/S3.4.1/` (artifact `evidence-static`); `smoke` (the shipped comments-only file, the generator's no-op line, `ls` in the container) under `artifacts/S3.4.1/` (artifact `evidence-smoke`); and `guest:layout_restore`, once the declared layout is withdrawn: the restored comments-only file, `ls -l /etc/X11/xorg.conf.d` with no `30-monitors.conf`, the generator's no-op line, and `xrandr` with Virtual-2 disconnected and the screen autodetected, under `artifacts/S3.4.1/` (artifact `evidence-vm-core`).

**S3.4.2 modesetting emission**
- Requirement: per-output `Monitor` sections with the documented options, a `Screen` on `gpu0` with pinned `Virtual`, no `MetaModes`.
- Acceptance: `layout-tests` "modesetting".
- Evidence: the generated file (EV-CONFIG) per case.
- Tier: T0 · Coverage: ✅ `layout-tests` "modesetting" saves the input, the GPU config, the generated file, `ls` and the generator's log under `artifacts/S3.4.2/` (artifact `evidence-static`), and checks the outputs forced on, one `Monitor` section per output with wide sync ranges and its `PreferredMode`, the positions, exactly one primary, `Virtual` pinned to the layout's extents, the `Screen` on `gpu0`, and no `MetaModes`.

**S3.4.3 CVT timings match `cvt(1)`**
- Requirement: the integer derivation equals, field for field, the Modeline the image's own `cvt(1)` prints (xserver 1.20.11's `xf86CVTMode()`; libxcvt's newer cvt differs from it in hsync start and the back porch floor). The one exception is a value that lands exactly on a rounding step, where cvt's single-precision floats can round the other way: of 6884 modes compared, 3432x1931@60 (one more line of vertical total) and 3104x2328@60 (a clock 0.25 MHz higher). Open: a width that is not a multiple of 8, such as 1366x768: `cvt(1)` changes the mode itself to 1368 wide, while the generator keeps the declared width.
- Acceptance: field-for-field equality for a table exercising every aspect branch: 1920x1080 at 50/60/75/85 Hz, 2560x1440, 3840x2160, 1080x1920, 1280x1024 (5:4, also with no refresh given), 1600x1200 and 1024x768 (4:3), 1920x1200 (16:10), 1800x1080 (15:9), and 1280x768, which only the divisibility check keeps out of 15:9; 59.94 carried.
- Evidence: a table of declared mode → generated Modeline → `cvt` output (EV-STATE).
- Tier: T0 · Coverage: ✅ `layout-tests` holds the Modeline generated for 14 modes (16:9 at 50/60/75/85 Hz and at 1440p and 2160p, 5:4 with and without a refresh, 4:3 twice, 16:10, 15:9, portrait, 1280x768) to the line the image's `cvt(1)` prints, field for field, and checks that 59.94 is carried; the table of declared mode, generated line and cvt's line verbatim is saved under `artifacts/S3.4.3/` (artifact `evidence-static`). cvt's lines are pinned in the script, the runner having no cvt.

**S3.4.4 Rotation transposes extents**
- Requirement: `rotate=left|right` swaps width/height in the framebuffer computation.
- Acceptance: `layout-tests` "rotation".
- Evidence: EV-CONFIG.
- Tier: T0 · Coverage: ✅ `layout-tests` saves each case's input, GPU config, generated file, `ls` and log under `artifacts/S3.4.4/` (artifact `evidence-static`): `rotate=left` and `rotate=right` measure the output transposed (framebuffer 3000x1920), `rotate=inverted` does not (3840x1080), and none transposes the mode itself.

**S3.4.5 NVIDIA emission**
- Requirement: one `MetaModes`, `ModeValidation AllowNonEdidModes`, opt-in `ConnectedMonitor`/`CustomEDID`, pinned `Virtual`, no `Monitor` sections.
- Acceptance: `layout-tests` "nvidia"; T4 the layout survives a KVM switch.
- Evidence: EV-CONFIG; T4 `xrandr` before/after the switch (EV-DIFF empty) and EV-PHONEVIDEO of the switch.
- Tier: T0/T4 · Coverage: ✅ the T0 half: `layout-tests` "nvidia" saves both cases' input, generated file and log under `artifacts/S3.4.5/` (artifact `evidence-static`) and checks one `MetaModes` carrying the whole layout, `ModeValidation AllowNonEdidModes`, `ConnectedMonitor` and `CustomEDID` only when asked for, the pinned `Virtual`, and no `Monitor` sections or invented timings. 🔧 the KVM-switch half: guided hardware script, not yet written.

**S3.4.6 Degraded host: no Device section**
- Requirement: without `gpu0`, Monitor sections only and a warning.
- Acceptance: `layout-tests`.
- Evidence: EV-CONFIG + the warning.
- Tier: T0 · Coverage: ✅ `layout-tests` "no GPU device section" saves the input, the generated file and the generator's log under `artifacts/S3.4.6/` (artifact `evidence-static`): the `Monitor` sections are still written, no `Screen` names the missing Device, and the generator warns that the framebuffer is not pinned.

**S3.4.7 A bad config is rejected whole**
- Requirement: every validation failure logs `ERROR`, removes the output file, exits 0.
- Acceptance: `layout-tests` rejection table: a mode without a height, an xrandr-style position, an unknown flag, two primaries, a duplicate output, a non-numeric refresh, an implausible mode, a `virtual` smaller than the layout or without a height, `nvidia-connected` without a list, `nvidia-edid` without `=`, digit-leading and illegal-character output names, and a `watch` line (a keyword that went with the session-side re-assert loop; the generator reads it as an output name and rejects the whole layout).
- Evidence: per case: the input, the ERROR line, `ls` showing no output file.
- Tier: T0 · Coverage: ✅ `layout-tests` runs 14 rejections and saves each one's input, the `ls` showing no `30-monitors.conf`, and the generator's log with its `ERROR` line under `artifacts/S3.4.7/` (artifact `evidence-static`); the generator exits 0 in every case.

**S3.4.8 The host file reaches the container and is acted on at start**
- Requirement: `/etc/desktop-container/monitors.conf` is visible read-only in the container and consumed at every start.
- Acceptance: write a layout, restart, generated config names the outputs.
- Evidence: the host file and the generated file (EV-CONFIG); EV-LOG-DESKTOP `fixed layout` line.
- Tier: T2 · Coverage: ✅ `smoke` saves the host's `monitors.conf`, the same file read inside the container with its mount (`ro`), the generated `30-monitors.conf` and the generator's `fixed layout` line under `artifacts/S3.4.8/` (artifact `evidence-smoke`).

**S3.4.9 A declared output comes up on a disconnected connector**
- Requirement: with `Virtual-1`/`Virtual-2` declared, X starts at 2048x768; `xrandr` shows `Virtual-2 disconnected 1024x768+1024+0`; `Virtual-1` is primary.
- Acceptance: `guest:layout_declare`, and a screendump of each head showing what X drew there.
- Evidence: `xrandr --query` (EV-STATE); an EV-SHOT of each head (`screendump` takes a device id and head: head 0 shows `Virtual-1`'s half, head 1 `Virtual-2`'s once X drives it; the e2e must give the virtio-vga an `id=`); EV-CONFIG.
- Tier: T3 · Coverage: ✅ `guest:layout_declare` declares `Virtual-1` primary at +0+0 and `Virtual-2` at +1024+0, both 1024x768@60, and restarts the desktop: the generated `30-monitors.conf` forces both outputs enabled with a derived `1024x768_60.00` Modeline and pins a 2048x768 framebuffer, and X comes up at 2048x768 with `Virtual-1` connected and primary at 1024x768+0+0 and `Virtual-2` `disconnected` yet scanning out at 1024x768+1024+0. `e2e` then screendumps each head of the virtio-vga (`id=vga0`) and requires each to be 1024x768 and drawn (grayscale standard deviation above 0.02): head 0 shows the session's xterm, head 1 an xterm X drew at +1200+200. The declared file, the generated one, sysfs's connector states, `xrandr` and both shots, under `artifacts/S3.4.9/` (artifact `evidence-vm-core`).

**S3.4.10 A live disconnect does not move the geometry**
- Requirement: forcing `Virtual-1` off leaves the screen at 2048x768 and both outputs in place; the user's windows do not move.
- Acceptance: `guest:layout_unplug`.
- Evidence: `xrandr --verbose` before/after (EV-DIFF: the connection state changes, and with it the EDID, the physical size and the probed modes; the mode in use and every position do not); `xwininfo -root -tree` before/after (EV-DIFF empty); EV-VIDEO across the force; EV-LOG-XORG across the force.
- Tier: T3 · Coverage: ✅ `guest:layout_unplug` forces `Virtual-1` off through sysfs (`status` set to `off`) under the running server, then queries RandR: the screen stays 2048x768, `Virtual-1` stays at 1024x768+0+0 (now `disconnected`) and `Virtual-2` at 1024x768+1024+0, and no client window moved or resized (each one's id, size and position compared between `xwininfo -root -tree` before and after; the whole tree's diff is empty). Sysfs, `xrandr --verbose` and the tree before and after, both diffs, the Xorg log since just before the force, and `e2e`'s 2 fps video of head 0 across the force and the re-plug, under `artifacts/S3.4.10/` (artifact `evidence-vm-core`).

**S3.4.11 Preflight warns about unknown output names**
- Requirement: an output name with no matching DRM connector yields the WARN line; known names yield the PASS line.
- Acceptance: `smoke` (DP-1/DP-2 on the runner) asserts the WARN; T3 asserts the PASS.
- Evidence: EV-LOG-DESKTOP preflight lines; `ls /sys/class/drm/` (EV-STATE).
- Tier: T2/T3 · Coverage: ❌.

**S3.4.12 `desktop-monitors-capture` prints a valid, round-trippable block**
- Requirement: one line per enabled output; refuses non-root; fails cleanly when the desktop is down; its output through the generator reproduces the geometry.
- Acceptance: T3 with the two-output layout live: the two expected lines; T1 canned `xrandr` text; T3 desktop stopped → exit 1 with the hint.
- Evidence: the tool's stdout (EV-STATE); the generator's output from it (EV-CONFIG); `xrandr` after applying it (EV-DIFF vs the original).
- Tier: T1/T3 · Coverage: ✅ the T1 half: `script-unit` runs `desktop-monitors-capture` on canned `xrandr` text (`DESKTOP_XRANDR_CMD`): a non-root caller is refused (exit 2); the capture prints one line per enabled output, the rotated output's panel size restored with `rotate=left`; a failing query exits 1 with the hint; and the block, through the generator, gives back xrandr's framebuffer and positions; under `artifacts/S3.4.12/` (artifact `evidence-static`). The T3 half: `guest:layout_roundtrip` captures the live two-output layout (Virtual-1 primary at +0+0, Virtual-2 at +1024+0), applies the block, and saves the generated `30-monitors.conf` and `xrandr` before and after with their diff (the same 2048x768 geometry); in `guest:layout_restore`, with desktop.service stopped, the capture exits 1 with the hint; under `artifacts/S3.4.12/` (artifact `evidence-vm-core`). The refresh does not round-trip exactly (declared 60, read back as 59.92, re-derived as 59.68 Hz); the requirement asks for the geometry.

### F3.5 Rendering and theme

**S3.5.1 The server is drawing**
- Requirement: a screendump of the live display has grayscale stddev > 0.02.
- Acceptance: `e2e:assert_nonblank` on the three QEMU screendumps (`desktop-deploy`, `desktop-k3s-client`, `cdi-verify-window`) and on the client's capture `screenshot-full.png`.
- Evidence: the EV-SHOTs themselves with the measured stddev in the index.
- Tier: T3 · Coverage: ✅ `e2e` records every `assert_nonblank` measurement; the k8s shard saves the four captures with their grayscale stddev, one check each, under `artifacts/S3.5.1/` (artifact `evidence-vm-k8s`).

**S3.5.2 `~/.Xdefaults` is honoured because nothing sets `RESOURCE_MANAGER`**
- Requirement: no `RESOURCE_MANAGER` on the root; the operator sees the dark xterm, not a white one. That holds for the desktop's own applications only: a client container's Xt applications read the resources in their own home, so they are not themed (a client's xterm is the stock white one).
- Acceptance: `xprop -root RESOURCE_MANAGER` → no such atom; xterm background pixel `22,25,29`.
- Evidence: `xprop` output (EV-STATE); EV-SHOT with the sampled coordinate.
- Tier: T3 · Coverage: ✅ `operator-e2e:s3_5_2`.

**S3.5.3 mwm frame colours are applied**
- Requirement: focused frame `#41637f`, unfocused `#22262d`, menus `#22262d`. Those are all the palette reaches: mwm marks an armed (selected) menu entry with the menu's own shadow colours, not `#41637f`, and draws a focused icon in its built-in default, CadetBlue `#5f9ea0` with white text, because `Xdefaults` sets no `Mwm*icon*active*` resources.
- Acceptance: sample a flat stretch of each frame - the middle of the left border, clear of the title text and the bevels; mwm paints the whole frame in the frame's colour - for a focused and an unfocused window, and the menu's background between two entries.
- Evidence: EV-SHOT with two windows, sampled coordinates and values in the index.
- Tier: T3 · Coverage: ✅ `operator-e2e:s3_5_3`.

**S3.5.4 Palette keeps the render test's margin**
- Requirement: the theme's screendump stddev stays ≥ 2× the 0.02 threshold.
- Acceptance: ≥ 0.04 on the deploy screendump.
- Evidence: the measurement in the index.
- Tier: T3 · Coverage: ❌ not asserted (`e2e:assert_nonblank` checks > 0.02 only), and the measurement is only in the job log.

### F3.6 Window manager

**S3.6.1 mwm runs as the session user and owns the root menu**
- Requirement: `mwm` runs as `desktop` with `~/.mwmrc` loaded; the root menu has "Desktop", "New Terminal", "Host Terminal", "Refresh", "Pack Icons", "Restart mwm", "Quit session".
- Acceptance: `pgrep -u desktop -x mwm`; a synthetic root click (QMP button on bare root) shows the menu in a screendump.
- Evidence: EV-PIDS; EV-SHOT of the open root menu with the seven entries legible.
- Tier: T3 · Coverage: ✅ process (`guest:phase_deploy`; `operator-e2e:s3_3_3` checks mwm's user) and menu (`operator-e2e:s11_1_1`: every entry's menu posts at the pointer with seven legible rows, an EV-SHOT each time); evidence under `artifacts/S11.1.1/` (menu shots, pid tables).

**S3.6.2 Click-to-focus and keyboard delivery**
- Requirement: a left click focuses a window and subsequent keys reach it.
- Acceptance: `e2e` input test, and `operator-e2e:s11_1_3` (a title-bar click focuses the window and typed lines land in it).
- Evidence: EV-SHOT after typing (`input-typed.png`, already produced) showing the text; the sink file (EV-LOG-CLIENT); the QMP transcript (EV-QEMU).
- Tier: T3 · Coverage: ✅ `operator-e2e:s11_1_3`: after a click on the desktop xterm's title bar its frame shows focus and typed lines land in it (shots, sink files and `qemu.log` under `artifacts/S11.1.3/`); `e2e` "input: type into an xterm" asserts the same and keeps `input-typed.png`.

**S3.6.3 "Restart mwm" re-reads `.mwmrc` without a new X session**
- Requirement: `f.restart` replaces mwm in place; Xorg pid unchanged; windows stay.
- Acceptance: trigger via the menu (S11.1.1) or T4; mwm's connection to the X server is a new one (the socket inode in `/proc/<mwm>/fd` changes), the Xorg pid is the same, and every client window is still there in the state it was in, normal or iconic. Not "a new mwm pid": `f.restart` re-executes mwm in place, so its pid stays. Not new frame window ids either: the server hands the new connection the slot the old one freed, so the frames mwm makes again can carry the old ids.
- Evidence: EV-PIDS; EV-DIFF of the window tree; EV-SHOT; EV-VIDEO.
- Tier: T3/T4 · Coverage: ✅ `operator-e2e:menu_restart_mwm` (S11.1.1); evidence under `artifacts/S11.1.1/` (pid tables, window-tree diff, shots, video).

**S3.6.4 Host Terminal menu entry**
- Requirement: the entry opens an xterm whose shell is on the host as `desktop-shell`.
- Acceptance: `ssh host whoami` from the container returns `desktop-shell` (✅); the failure path keeps the window open with the hint (S5.7.8).
- Evidence: EV-SHOT of the host-terminal xterm showing `whoami` and its answer; the answer as text in the index; sshd's journal line for the login (EV-LOG-JOURNAL).
- Tier: T2/T3 · Coverage: 🟡 the success path is asserted by `operator-e2e:menu_host_terminal`, evidence under `artifacts/S11.1.1/` (the window showing `whoami` and its answer, sshd's journal); the failure path's hint is not asserted (S5.7.8 tracks it).

### F3.7 Window-to-pod identity

**S3.7.1 X clients report real host pids**
- Requirement: X-Resource returns a nonzero pid for every client.
- Acceptance: `screenshot --list-clients` lists ≥ 3 clients, none `pid=0`.
- Evidence: the listing (EV-STATE); `ps -p <pids> -o pid,user,comm,cgroup` (EV-STATE).
- Tier: T3 · Coverage: ✅ `guest:verify_pod_identity` saves `screenshot --list-clients` (none `pid=0`) and `ps -p <pids> -o pid,user,comm,cgroup` under `artifacts/S3.7.1/` (artifact `evidence-vm-k8s`); the newest pid listed is usually the listing tool itself, gone by the time `ps` runs.

**S3.7.2 A client pid resolves to its pod from inside the container**
- Requirement: `/proc/<pid>/cgroup` read in the container carries the pod UID.
- Acceptance: the testpattern pod's UID is found for one listed client, host-side and in-container.
- Evidence: the cgroup line and the pod UID side by side (EV-STATE).
- Tier: T3 · Coverage: ✅ `guest:verify_pod_identity` saves the testpattern pod's UID and the matching client's `/proc/<pid>/cgroup`, read on the host and from inside the desktop container, under `artifacts/S3.7.2/` (artifact `evidence-vm-k8s`).

**S3.7.3 Loss of `--pid=host` is detected at boot**
- Requirement: if desktop-init is pid 1, preflight reports `FAIL: container init is PID 1`.
- Acceptance: `podman run` the image without `--pid=host`; the FAIL line appears.
- Evidence: EV-LOG-DESKTOP of that run.
- Tier: T2 · Coverage: ✅ `smoke`'s scratch container of the image runs without `--pid=host`; its preflight block, with `FAIL: container init is PID 1`, is saved under `artifacts/S3.7.3/` (artifact `evidence-smoke`).

### F3.8 Input

**S3.8.1 Typed input reaches the focused application**
- Requirement: QEMU HID → evdev → Xorg → focused xterm; the operator sees their keystrokes.
- Acceptance: `e2e` "input: type into an xterm", and `operator-e2e:s11_1_3`.
- Evidence: EV-SHOT `input-typed.png`; sink file (EV-LOG-CLIENT); EV-QEMU transcript.
- Tier: T3 · Coverage: ✅ `e2e` "input: type into an xterm" saves the QMP transcript, the shot and the sink file under `artifacts/S3.8.1/` (artifact `evidence-vm-core`); `operator-e2e:s11_1_3` also types through QEMU's keyboard into focused xterms, with sink files, shots and `qemu.log` under `artifacts/S11.1.3/`.

> **Retired IDs:** S3.8.2 (hot-added input reaches the container), S3.8.3
> (KVM-style remove/re-add cycle) and S3.8.4 (the re-added device itself
> carries input) were split per device and per direction into **F3.9**; their
> coverage is carried by S3.9.1–S3.9.6.

**S3.8.5 The host udev database is mounted read-only and used**
- Requirement: `/run/udev` is mounted `ro` and non-empty; no udevd process shares the container's mount namespace (a process listing proves nothing: under `--pid=host` the host's `systemd-udevd` shows up inside).
- Acceptance: mount line shows `ro`; preflight PASS.
- Evidence: `/proc/self/mounts` line and `ls /run/udev/data | wc -l` (EV-STATE); EV-LOG-DESKTOP preflight line.
- Tier: T3 · Coverage: ❌ nothing asserts the mount, the database or the preflight line; typing working (`e2e` "input: type into an xterm") implies only that Xorg can read the udev database.

**S3.8.6 Foreign seat tags are detected and undone**
- Requirement: a device attached to another seat is reported by preflight as a WARN until `seat-prep` removes the rule and re-triggers udev.
- Acceptance: `loginctl attach seat1 <device>`; `udevadm info` shows `ID_SEAT=seat1`; restart `desktop-seat-prep`; rule gone, tag absent; restart desktop; preflight `PASS: no foreign seat tags`.
- Evidence: `udevadm info` before/after (EV-DIFF); `ls /etc/udev/rules.d/72-seat-*` before/after; EV-LOG-JOURNAL of `desktop-seat-prep`; EV-LOG-DESKTOP preflight line; the keyboard still types afterwards (EV-SHOT).
- Tier: T3 · Coverage: ❌ evidence not saved; `smoke` asserts only that `seat-prep` removes a fake empty `72-seat-*` rule, with no real attach, tag check or preflight line.

### F3.9 HMI hotplug: keyboards and pointers

Mechanics, QEMU commands and layer-by-layer probes for every story here are in
`HotpluggingTestHelp.md` §4.1–4.2. Plug-in and plug-out are separate stories
throughout because they fail differently. The operator-facing outcome every
story here serves: **an operator who unplugs or replugs a keyboard or mouse,
or whose KVM does it for them, keeps typing and clicking without anyone
restarting anything.** The client-application side of the same events is F7.7.
**Common set** for this feature: EV-QEMU (`info usb` before/after), EV-STATE
(`ls -l /dev/input` on host and in container, `xinput list`,
`cat /proc/bus/input/devices`) as before/after pairs with EV-DIFF, EV-LOG-XORG
slice, EV-TIMELINE.

**S3.9.1 Keyboard plug-in reaches the container**
- Requirement: a keyboard added while the desktop runs appears as a new `/dev/input/event*` inside the container.
- Acceptance: the container node count rises after `device_add` (USB `usb-kbd` on xHCI, and PCI `virtio-keyboard-pci`).
- Evidence: common set; the counter line from `xorg-input-count.txt`.
- Tier: T3 · Coverage: ✅ `e2e` "input hotplug" (PCI `virtio-keyboard-pci`) and "KVM switch simulation" (the USB keyboard re-added) each save F3.9's common set before and after the `device_add` (QEMU's `info usb` and its reply to the command, `ls -l /dev/input` on the host and in the container, `/proc/bus/input/devices`, `xinput list`, each pair diffed) and the Xorg log's lines since; the host's and the container's event-node counts rise, the USB re-add's back to at least the count before the switch; the counter lines are saved, under `artifacts/S3.9.1/` (artifact `evidence-vm-core`).

**S3.9.2 Keyboard plug-in is adopted by Xorg**
- Requirement: Xorg/libinput opens the new device and lists it.
- Acceptance: `xinput list` gains an entry named for the QEMU device, or the Xorg log gains `Adding input device` **and** `XINPUT: Adding extended input device` for it.
- Evidence: common set with the `xinput list` diff and the two log lines quoted.
- Tier: T3 · Coverage: ✅ `e2e` "input hotplug": the device the kernel gained (`QEMU Virtio Keyboard`, from the `/proc/bus/input/devices` diff) gains an entry in `xinput list`, and Xorg's two adding lines for it are quoted from the log's slice; the xinput pair and its diff under `artifacts/S3.9.2/`, the rest of the common set under `artifacts/S3.9.1/` (artifact `evidence-vm-core`).

**S3.9.3 Keyboard plug-out removes the node from the container**
- Requirement: after `device_del`, the node is gone inside the container.
- Acceptance: the container node count drops to the pre-add value.
- Evidence: common set.
- Tier: T3 · Coverage: ✅ `e2e` "KVM switch simulation": after `device_del kvmkbd` the USB keyboard's own event node(s), read from `/proc/bus/input/devices` before, are gone from the container's `/dev/input`, and its count is the one before less those nodes; the common set before and after, diffed, and the Xorg log since, under `artifacts/S3.9.3/` (artifact `evidence-vm-core`).

**S3.9.4 Keyboard plug-out is seen by Xorg**
- Requirement: the device leaves `xinput list`; the log records `removing device`.
- Acceptance: as stated, polled.
- Evidence: common set with the `removing device` line quoted.
- Tier: T3 · Coverage: ✅ `e2e` "KVM switch simulation": `QEMU QEMU USB Keyboard` leaves `xinput list` (polled), and the Xorg log since the removal has `config/udev: removing device QEMU QEMU USB Keyboard`, quoted; the xinput pair, its diff and the log slice under `artifacts/S3.9.4/`, the rest of the common set under `artifacts/S3.9.3/` (artifact `evidence-vm-core`).

**S3.9.5 A hot-added keyboard delivers keystrokes**
- Requirement: keys sent through the re-added device itself reach the focused application, and the operator sees them.
- Acceptance: the keyboard re-added with `display=<virtio-vga id>` (the e2e must give `-device virtio-vga` an `id=`), then `input-send-event` with `"device"` set to that virtio-vga id; the sink xterm records the text (or `xinput test <id>` shows the events). QMP's `device` names a display device, not an input device: `"device": "kvmkbd"` is refused ("not bound to a QemuConsole").
- Evidence: EV-QEMU transcript showing the `device` field; sink file (EV-LOG-CLIENT); EV-SHOT of the text on screen; `xinput test` output (EV-STATE).
- Tier: T3 · Coverage: ❌ not asserted: `e2e` "KVM switch simulation" already types `kvmok` through the re-added `kvmkbd`, because QEMU gives unrouted key events to the newest keyboard, but nothing checks or saves which device carried them.

**S3.9.6 The session accepts input after a keyboard cycle**
- Requirement: a remove/re-add cycle does not wedge the X session or its input stack.
- Acceptance: click + type after the cycle lands in the sink xterm.
- Evidence: EV-SHOT; EV-PIDS (Xorg pid unchanged across the cycle); EV-VIDEO of the cycle.
- Tier: T3 · Coverage: ✅ `e2e` "KVM switch simulation": after the remove/re-add cycle the sink xterm reads `kvmok` typed through QEMU, and Xorg keeps its pid; the cycle on video (2 fps frames with their times, and a gif), the screendump after the typing, the QMP transcript, the sink file and Xorg's and mwm's pid tables before and after, under `artifacts/S3.9.6/` (artifact `evidence-vm-core`).

**S3.9.7 Pointer plug-in reaches the container**
- Requirement: a mouse or tablet added while the desktop runs appears as a new `event*` node inside the container.
- Acceptance: node count rises after `device_add usb-mouse` (relative) and `device_add usb-tablet` (absolute).
- Evidence: common set.
- Tier: T3 · Coverage: ❌.

**S3.9.8 Pointer plug-in is adopted by Xorg**
- Requirement: the device appears in `xinput list` as a pointer.
- Acceptance: as stated, for a relative and an absolute device.
- Evidence: common set.
- Tier: T3 · Coverage: ❌.

**S3.9.9 Pointer plug-out removes the node from the container**
- Requirement and acceptance: as S3.9.3, for the pointer.
- Evidence: common set.
- Tier: T3 · Coverage: ❌.

**S3.9.10 Pointer plug-out is seen by Xorg**
- Requirement and acceptance: as S3.9.4, for the pointer.
- Evidence: common set.
- Tier: T3 · Coverage: ❌.

**S3.9.11 A hot-added pointer delivers motion and buttons**
- Requirement: events through the hot-added device move the pointer and click; the operator sees the cursor move and a window take focus.
- Acceptance: the events reach the hot-added device (a `usb-tablet` added with `display=<virtio-vga id>` and sent with that `device`; a `usb-mouse`, which has no `display` property, selected with HMP `mouse_set` and shown current by `query-mice`); `xinput test <id>` shows its motion/button events; a click on the sink xterm through the hot-added tablet focuses it and typed text lands.
- Evidence: EV-VIDEO (cursor crossing the screen, window frame turning the focused colour); `xinput test` output; sink file; EV-QEMU.
- Tier: T3 · Coverage: ❌.

**S3.9.12 Repeated input cycles leave no residue**
- Requirement: ≥ 5 remove/re-add cycles return node counts and `xinput list` to baseline.
- Acceptance: counts equal baseline after the last cycle; the session still accepts input.
- Evidence: per-cycle counter table (EV-STATE); `xinput list` baseline vs final (EV-DIFF empty); EV-PIDS Xorg unchanged.
- Tier: T3 · Coverage: ❌.

### F3.10 HMI hotplug: monitors

Under `-display none` nothing enables a second virtio-gpu scanout and no
QMP/HMP command can, so a monitor *appearing* is staged through the DRM
connector-force interface and, where modes are needed, an injected firmware
EDID; `HotpluggingTestHelp.md` §4.3. QEMU itself does enable or disable a head,
with an EDID of the requested size, when a display frontend reports a size for
it: a VNC server bound to that head (`-vnc …,display=<vga id>,head=1`)
receiving SetDesktopSize, or `-display dbus` SetUIInfo. That route is
untested here; the hot-plug batch tries it first, and what it cannot prove
honestly goes to the guided hardware script. The user-facing
outcome: **when the KVM takes the monitors away and brings them back, every
window is where it was.** **Common set**: `xrandr --query --verbose`
before/after (EV-DIFF), `xwininfo -root -tree` before/after (EV-DIFF, must be
empty wherever "nothing moves" is claimed), `cat /sys/class/drm/card*-*/status`
(EV-STATE), EV-LOG-XORG connector lines, EV-VIDEO of the display across the
event, EV-TIMELINE.

**S3.10.1 Monitor plug-out with a declared layout holds the geometry**
- Requirement: forcing a declared connector down under the running server changes neither the screen size nor any output's or window's position.
- Acceptance: S3.4.10.
- Evidence: common set.
- Tier: T3 · Coverage: ✅ `guest:layout_unplug`, on S3.4.10's force: the screen size (2048x768), every output's position (`Virtual-1` at +0+0, `Virtual-2` at +1024+0) and every client window's id, size and position held, asserted in S3.4.10 on the same snapshots; F3.10's common set before and after the force (sysfs, `xrandr --verbose`, `xwininfo -root -tree`), the tree's diff (empty) and the Xorg log since just before the force, under `artifacts/S3.10.1/`; the video and the `xrandr` diff under `artifacts/S3.4.10/` (artifact `evidence-vm-core`).

**S3.10.2 Monitor plug-out is reported by RandR**
- Requirement: after the connector goes down, `xrandr` reports it `disconnected` while it stays enabled.
- Acceptance: `xr_is Virtual-1 disconnected 1024x768+0+0`.
- Evidence: common set.
- Tier: T3 · Coverage: ✅ `guest:layout_unplug`: after S3.4.10's force sysfs reads `Virtual-1` `disconnected`, and `xrandr` reports `Virtual-1 disconnected primary 1024x768+0+0`, still enabled; the snapshots before and after the force under `artifacts/S3.10.2/`, their diffs under `artifacts/S3.4.10/` (artifact `evidence-vm-core`).

**S3.10.3 Monitor re-plug after plug-out restores connected status without moving anything**
- Requirement: `detect` under the running server returns `xrandr` to `connected` with the same geometry and windows.
- Acceptance: poll `xrandr` for `Virtual-1 connected 1024x768+0+0`; dims `2048x768`; window tree unchanged.
- Evidence: common set.
- Tier: T3 · Coverage: ✅ `guest:layout_unplug` sets `Virtual-1`'s `status` back to `detect`, waits for sysfs to read `connected`, then polls `xrandr` until it reads `Virtual-1 connected primary 1024x768+0+0`; the screen is still 2048x768, `Virtual-2` still at 1024x768+1024+0, and no client window moved or resized across the unplug and re-plug. Sysfs, `xrandr --verbose` and the tree before the force and after the re-plug, their diffs (the tree's empty) and the Xorg log since just before the re-plug, under `artifacts/S3.10.3/` (artifact `evidence-vm-core`).

**S3.10.4 Monitor plug-in on an empty connector, layout declared**
- Requirement: forcing `Virtual-2` to `on` under a layout that declares it changes nothing except `xrandr` now saying `connected`.
- Acceptance: `echo on`; `xr_is Virtual-2 connected 1024x768+1024+0`; dims `2048x768`; `echo detect` afterwards.
- Evidence: common set.
- Tier: T3 · Coverage: ❌.

**S3.10.5 Monitor plug-in without a layout is detected and does not reflow**
- Requirement: under autodetection a connector coming up is `connected` in `xrandr`; screen size and existing geometry unchanged (no auto-enable).
- Acceptance: as stated.
- Evidence: common set.
- Tier: T3 · Coverage: ❌.

**S3.10.6 Monitor plug-out without a layout is characterised**
- Requirement: under autodetection, forcing the only enabled connector down must not crash or restart X; the result is recorded.
- Acceptance: Xorg pid unchanged; `xdpyinfo` answers; `xrandr` captured.
- Evidence: common set + EV-PIDS.
- Tier: T3 · Coverage: ❌.

**S3.10.7 A plugged-in monitor with an EDID exposes modes**
- Requirement: with an injected EDID on the forced-on connector, `xrandr --verbose` lists its modes; `xrandr --output Virtual-2 --auto` enables it without disturbing `Virtual-1`.
- Acceptance: as stated; needs `CONFIG_DRM_LOAD_EDID_FIRMWARE` (confirm first).
- Evidence: common set; `cat /sys/class/drm/card*-Virtual-2/edid | od -An -tx1 | head` (EV-STATE); EV-SHOT after enabling.
- Tier: T3 · Coverage: ❌.

**S3.10.8 Physical monitor plug-out and plug-in**
- Requirement: S8.2.2 and S8.2.3.
- Evidence: EV-PHONEVIDEO of the cable/KVM action with the screen in frame; `xrandr` before/after (EV-DIFF); EV-PHOTO of the desktop after.
- Tier: T4 · Coverage: 🔧 guided hardware script, not yet written (manual steps for S8.2.2/S8.2.3 in Appendix C).

### F3.11 HMI hotplug: KVM switch composite

**S3.11.1 Keyboard, pointer and sound card leave and return together**
- Requirement: a KVM switch disconnects every USB device at once; the desktop survives all three leaving in the same instant and all three returning; the operator types, clicks and hears audio afterwards.
- Acceptance: `device_del` of the USB keyboard, tablet and sound card back to back; all node counts drop; re-add all three; all counts return; typed text lands, the hot-added tablet clicks, and a tone sent to the built-in sink **by name** is captured (WirePlumber makes a returning USB card the default, so an untargeted tone would prove the USB card); Xorg pid and PipeWire pid unchanged.
- Evidence: EV-VIDEO of the whole cycle; EV-TIMELINE; the three counter tables; EV-PIDS; EV-AUDIO after; EV-SHOT of typed text.
- Tier: T3 · Coverage: ❌.

**S3.11.2 Composite cycle with the video link down at the same time**
- Requirement: S3.11.1 with `Virtual-1` forced down during the away period and `detect`ed on return, layout declared; geometry and windows hold throughout.
- Acceptance: S3.11.1's assertions plus dims `2048x768` and an unchanged window tree at every step.
- Evidence: S3.11.1's set plus the F3.10 common set.
- Tier: T3 · Coverage: ❌.

---

## E4 — Audio stack

### F4.1 Export

**S4.1.1 Both sockets are exported**
- Requirement: `/run/desktop-audio/pipewire-0` and `/run/desktop-audio/pulse` exist on the host while the desktop runs.
- Acceptance: both are sockets; `pactl info` over the pulse one succeeds from the host.
- Evidence: `ls -l /run/desktop-audio` and `pactl info` output (EV-STATE).
- Tier: T2/T3 · Coverage: ✅ `guest:phase_deploy` saves `ls -l /run/desktop-audio` on the host (both sockets) and `pactl info` over the pulse one, and checks each, under `artifacts/S4.1.1/` (artifact `evidence-vm-core`); `guest:verify_cdi` also reaches both sockets from a pod.

**S4.1.2 In-container clients use the per-user sockets, and the operator hears them**
- Requirement: apps in the desktop session reach PipeWire via `$XDG_RUNTIME_DIR`, pulse via `unix:native`, ALSA via `pipewire-alsa`.
- Acceptance: `paplay`, `pw-play`, `aplay` from an xterm on `:0` each play their tone and it is captured at the right frequency.
- Evidence: three EV-AUDIO captures (440/880/1320 Hz) with spectrograms; EV-SHOT of the playing xterm.
- Tier: T3 · Coverage: ✅ `e2e` "audio: record each client path" saves, under `artifacts/S4.1.2/` (artifact `evidence-vm-core`), each path's capture with `check-audio.py`'s verdict and a level plot at its pitch (the evidence standard's stand-in for a spectrogram where none is installed), and a screendump of the xterm that ran each player, taken as it reports the player's exit status.

### F4.2 Host clients

**S4.2.1 Host Pulse clients are routed to the container**
- Requirement: the host Pulse client drop-in routes an unconfigured host client to the export and never autospawns a daemon.
- Acceptance: on the VM host **without** `PULSE_SERVER` set, `paplay tone.wav` plays and is captured; a stub `/usr/bin/pulseaudio` that logs every start shows none (without the stub, "no daemon was spawned" cannot fail on a host that has no daemon to spawn).
- Evidence: EV-AUDIO; `env | grep PULSE` (empty) and `pgrep pulseaudio` (empty) (EV-STATE); the drop-in (EV-CONFIG).
- Tier: T3 · Coverage: ❌.

**S4.2.2 Host ALSA clients are routed through the pulse plugin**
- Requirement: the ALSA drop-in routes `pcm.!default`/`ctl.!default` to the pulse socket.
- Acceptance: on the VM host (with `alsa-utils` + `alsa-plugins-pulseaudio`), `aplay tone.wav` plays and is captured at 1320 Hz; `amixer` lists the pulse control.
- Evidence: EV-AUDIO; `amixer` output (EV-STATE); the drop-in (EV-CONFIG).
- Tier: T3 · Coverage: ❌.

**S4.2.3 A host-local `asound.conf` still wins**
- Requirement: the drop-in loads before `/etc/asound.conf`, so a host override is honoured.
- Acceptance: with an `/etc/asound.conf` routing default to `null`, `aplay -D default` produces no capture; remove it.
- Evidence: EV-AUDIO (silence, analyser fails as expected); the override file.
- Tier: T3 · Coverage: ❌.

### F4.3 Realtime

**S4.3.1 Rlimits reach PipeWire by inheritance**
- Requirement: `RLIMIT_RTPRIO` hard = 95, memlock 64 MiB, nice 31 on the PipeWire process itself.
- Acceptance: `/proc/<pipewire>/limits`.
- Evidence: the limits file (EV-STATE).
- Tier: T3 · Coverage: ❌ evidence not saved (the limits file); `guest:verify_privileges` asserts only the rtprio hard limit, not memlock or nice.

**S4.3.2 PipeWire holds SCHED_FIFO above priority 1 without rtkit**
- Requirement: no `rtkit-daemon`; ≥ 1 PipeWire thread is `FF` with rtprio > 1.
- Acceptance: `ps -L` on the daemon.
- Evidence: `ps -L -p <pid> -o pid,tid,cls,rtprio,comm` (EV-STATE); `pgrep rtkit-daemon` (empty).
- Tier: T3 · Coverage: ✅ `guest:verify_privileges` saves `pgrep -a rtkit-daemon` (none) and `ps -L` of the PipeWire daemon (its `data-loop` thread `FF` at priority 60) under `artifacts/S4.3.2/` (artifact `evidence-vm-core`).

### F4.4 Soundless host

> **Retired ID:** S4.4.1 (sound-card hotplug, both directions) was split per
> direction and per layer into **F4.7** (S4.7.1–S4.7.6).

**S4.4.2 Soundless host boots and degrades gracefully**
- Requirement: with no `/dev/snd` on the host, tmpfiles creates an empty one, the container starts, preflight WARNs `no /dev/snd/controlC* visible`, PipeWire runs and exports sockets.
- Acceptance: `smoke`, after recording `ls -la /dev/snd` before tmpfiles runs and asserting it holds no `controlC*`, with the preflight WARN grepped (today nothing records that the runner has no card).
- Evidence: `ls -ld /dev/snd` on the host (EV-STATE); EV-LOG-DESKTOP preflight WARN; EV-PIDS (pipewire); `ls -l /run/desktop-audio`.
- Tier: T2 · Coverage: ✅ `smoke` saves `ls -la /dev/snd` before the tree's tmpfiles run (no `controlC*`: the runner has no sound card) and `ls -ld` after (the empty directory), the preflight's `no /dev/snd/controlC* visible` WARN, the running PipeWire daemons and `ls -l /run/desktop-audio` with both sockets, under `artifacts/S4.4.2/` (artifact `evidence-smoke`).

### F4.5 Lifecycle independence

**S4.5.1 Audio survives an X session restart**
- Requirement: PipeWire's pid is unchanged and the export reachable after Xorg is killed and the session restarts; a tone playing through the restart is heard without a gap.
- Acceptance: `guest:verify_audio_lifecycle` for the pid and the export; a 20 s tone captured across the Xorg kill, with no quiet stretch and no capture time missing against the wall clock.
- Evidence: EV-PIDS; `pactl info`; EV-AUDIO of a 20 s tone spanning the restart with the spectrogram showing no gap.
- Tier: T3 · Coverage: ❌ evidence not saved, and no tone is played across the restart; `guest:verify_audio_lifecycle` asserts that PipeWire keeps its pid and the export stays reachable.

**S4.5.2 Audio recovers from its own crash without disturbing X**
- Requirement: new PipeWire pid, export reachable, mwm still running.
- Acceptance: `guest:verify_audio_lifecycle` and `smoke` "RECOVERY": a new PipeWire pid, `pactl info` answering over the export (a socket file alone passes when it is stale), and the Xorg and mwm pids unchanged.
- Evidence: EV-PIDS before/after (pipewire changed, Xorg/mwm unchanged); EV-LOG-DESKTOP; EV-AUDIO after.
- Tier: T2/T3 · Coverage: ✅ the T2 half: `smoke` "RECOVERY" kills pipewire as the desktop user and requires a new pipewire pid, the pulse socket back in `/run/desktop-audio`, `pactl info` answering over it as the session user, and Xorg's and mwm's pids unchanged; the process tables before and after, `pactl info` and the desktop's log since the kill, under `artifacts/S4.5.2/` (artifact `evidence-smoke`). The T3 half: `guest:verify_audio_lifecycle` does the same in the VM, with `pactl info` from the host over the export, and `e2e` then captures a pulse client's 440 Hz tone at the machine's output through the recovered stack (the WAV, check-audio's verdict and its level plot), under `artifacts/S4.5.2/` (artifact `evidence-vm-core`).

### F4.6 Capture direction

**S4.6.1 A client can record**
- Requirement: a pod with `desktop.local/audio` records the sink monitor and the recording carries the played tone.
- Acceptance: `guest:verify_record` (660 Hz).
- Evidence: EV-AUDIO-REC (the pulled WAV, spectrogram, analyser verdict).
- Tier: T3 · Coverage: ✅ `guest:verify_record` asserts the pod's recording carries 660 Hz; `e2e` copies the recording out of the VM and saves it with `check-audio.py`'s verdict and a level plot under `artifacts/S4.6.1/` (artifact `evidence-vm-k8s`).

### F4.7 HMI hotplug: audio

The VM stages real USB sound-card hotplug today; `HotpluggingTestHelp.md` §4.4
documents the commands, the three counters, and why QEMU's limits do not
prevent it. Playback and capture are separate stories because QEMU's
`usb-audio` has only ever offered playback. The operator-facing outcome: **plug in
a headset and sound comes out of it; unplug it and sound comes back out of the
speakers; nothing restarts.** The client-container side (an application that
is already playing when the device arrives or leaves) is F7.7.
**Common set**: EV-QEMU (`info usb`), `ls -l /dev/snd` host and container,
`wpctl status`, `pw-cli ls Device`, `pactl list short sinks sources
sink-inputs` as before/after pairs with EV-DIFF, EV-PIDS for the three audio
daemons, EV-LOG-DESKTOP slice, EV-TIMELINE.

**S4.7.1 Sound card plug-in reaches the container**
- Requirement: a card added while the desktop runs produces a new `/dev/snd/controlC*` inside the container.
- Acceptance: the container node count rises after `device_add usb-audio,…,bus=xhci.0`.
- Evidence: common set; counter line.
- Tier: T3 · Coverage: ✅ `e2e` "audio hotplug": `device_add usb-audio` raises the host's and the container's `controlC*` counts; F4.7's common set before and after (QEMU's `info usb` and its reply, `ls -l /dev/snd` on the host and in the container, `wpctl status`, `pw-cli ls Device`, `pactl list short` sinks, sources and sink-inputs, `pactl get-default-sink`, the three daemons' pids), each pair diffed, the desktop's log since, and the counter line, under `artifacts/S4.7.1/` (artifact `evidence-vm-core`).

**S4.7.2 Sound card plug-in reaches WirePlumber**
- Requirement: WirePlumber gains an `alsa_card.*` Device object for it.
- Acceptance: the `pw-cli ls Device` count rises.
- Evidence: common set with the new Device object's block quoted.
- Tier: T3 · Coverage: ✅ `e2e` "audio hotplug": the `pw-cli ls Device` count of `alsa_card` devices rises, and the new Device object is quoted whole from the listing after; the before/after pair and its diff under `artifacts/S4.7.2/`, the rest of the common set under `artifacts/S4.7.1/` (artifact `evidence-vm-core`).

**S4.7.3 A hot-added card plays, and it is the new card that is heard**
- Requirement: audio routed to the hot-added card's sink is rendered by that device.
- Acceptance: `wpctl set-default <id>`; play a 990 Hz tone; `wavcapture` on the shared `audiodev` and `check-audio.py` assert it; `pactl list short sink-inputs` during playback shows the stream on the new sink; restore the default sink.
- Evidence: EV-AUDIO (990 Hz, spectrogram); `pactl list short sink-inputs` mid-playback naming the USB sink (EV-STATE); `wpctl status` with the default marker on the new sink; common set.
- Tier: T3 · Coverage: ❌ evidence incomplete (no `pactl list short sink-inputs` or `/dev/snd` listings saved); asserted as a side effect by `operator-e2e:s11_3_1`, whose capture follows the hot-added card's volume and mute once the client's stream is on it.

**S4.7.4 Sound card plug-out removes the node from the container**
- Requirement: after `device_del`, the `controlC*` node is gone inside the container.
- Acceptance: the container node count returns to baseline.
- Evidence: common set.
- Tier: T3 · Coverage: ✅ `e2e` "audio hotplug": after `device_del hotsnd` the container's `controlC*` count is back to its baseline, not just lower; the common set with the card plugged in and after, each pair diffed, and the counter line, under `artifacts/S4.7.4/`; the desktop's log across the cycle under `artifacts/S4.7.6/` (artifact `evidence-vm-core`).

**S4.7.5 Sound card plug-out removes the WirePlumber device and a default sink is re-selected**
- Requirement: WirePlumber drops the Device object and re-selects a default sink.
- Acceptance: the Device count returns to baseline (polled); `pactl get-default-sink` names a surviving sink.
- Evidence: common set; `pactl get-default-sink` before/after.
- Tier: T3 · Coverage: ✅ `e2e` "audio hotplug": WirePlumber's `alsa_card` Device count is back to its baseline after the unplug, and `pactl get-default-sink` names one of the sinks left (the built-in card's; with the card plugged in WirePlumber had moved the default to it); the `pw-cli ls Device` pair and diff, the default sink before, plugged in and after, and the sinks after, under `artifacts/S4.7.5/`, the rest of the common set under `artifacts/S4.7.4/` (artifact `evidence-vm-core`).

**S4.7.6 The built-in card plays after a cycle**
- Requirement: a plug/unplug cycle does not wedge the audio stack; the operator hears the speakers again.
- Acceptance: a pulse tone is captured at 440 Hz afterwards.
- Evidence: EV-AUDIO; EV-PIDS (the three daemons unchanged across the cycle).
- Tier: T3 · Coverage: ✅ `e2e` "audio hotplug": after the plug/unplug cycle a pulse client's 440 Hz tone is captured at the machine's output (the WAV, check-audio's verdict and its level plot), and pipewire, wireplumber and pipewire-pulse keep their pids (the tables before and after, their diff empty); the desktop's log across the cycle, under `artifacts/S4.7.6/` (artifact `evidence-vm-core`).

**S4.7.7 A stream playing on the card that is unplugged fails cleanly**
- Requirement: a client streaming to the hot-added card when it is removed is either moved to the remaining sink or gets a clean error; the three daemons keep their pids.
- Acceptance: start a long `pw-play`/`paplay` to the new sink; `device_del`; daemon pids unchanged; export reachable; the client exits or continues on the built-in sink within 10 s.
- Evidence: EV-AUDIO spanning the removal (spectrogram shows the tone continuing or stopping cleanly at the removal timestamp); EV-PIDS; EV-LOG-CLIENT (the player's stderr); `pactl list short sink-inputs` before/after.
- Tier: T3 · Coverage: ❌.

**S4.7.8 Capture device plug-in and plug-out reach WirePlumber**
- Requirement: a hot-added card with a capture path appears as an `alsa_input.*` source and disappears on removal.
- Acceptance: `pactl list short sources` gains and loses it. Vehicle: PCI hot-add of a capture-capable card with a built-in codec (`AC97` or `ES1370`, `audiodev=snd0`), if the guest image has its driver (untested); otherwise T4 only, with the attempt and its error recorded here. QEMU's HDA codec bus refuses `device_add`, and `usb-audio` has no capture path.
- Evidence: common set with sources; EV-QEMU including the `device_add` replies.
- Tier: T3/T4 · Coverage: ❌.

**S4.7.9 Recording from a hot-added capture device works**
- Requirement: a client can `parec`/`arecord` from the new source.
- Acceptance: the stream opens and delivers frames.
- Evidence: EV-AUDIO-REC (duration > 0, silence with the null backend is acceptable and stated); EV-LOG-CLIENT.
- Tier: T3/T4 · Coverage: ❌.

**S4.7.10 A card that arrives after a soundless boot is openable**
- Requirement: S2.4.6.
- Acceptance: VM profile without `intel-hda`; hot-add `usb-audio`; after the next stack start WirePlumber lists it and it plays.
- Evidence: as S2.4.6.
- Tier: T3 · Coverage: ❌.

**S4.7.11 Repeated audio cycles leave no phantom devices**
- Requirement: ≥ 5 plug/unplug cycles return node and Device counts to baseline; no `alsa_card` object outlives its node.
- Acceptance: counts equal baseline after the last cycle; the built-in tone still plays.
- Evidence: per-cycle counter table; `pw-cli ls Device` baseline vs final (EV-DIFF empty); EV-AUDIO.
- Tier: T3 · Coverage: ❌.

**S4.7.12 Physical USB audio plug-in and plug-out**
- Requirement: S8.3.1.
- Evidence: EV-PHONEVIDEO of the device being plugged with audible output; `wpctl status` before/after (EV-DIFF); for capture, an EV-AUDIO-REC of speech into the device's microphone.
- Tier: T4 · Coverage: 🔧 guided hardware script, not yet written (manual steps for S8.3.1 in Appendix C).

---

## E5 — Host deploy tree

### F5.1 Apply

**S5.1.1 The documented rsync is the whole installation**
- Requirement: `rsync -a --chown=root:root deploy/host/ /` and `systemctl daemon-reload` from `deploy/README.md` "Apply", run as written, install everything (the `reboot` that completes the block is S5.1.3); the two symlinks and the four `multi-user.target.wants` symlinks survive as symlinks.
- Acceptance: symlink checks; `is-enabled` = `enabled` for `desktop-client-cdi`, `desktop-selinux`, `desktop-session`, `desktop-tools-cdi.path`.
- Evidence: `find /etc/systemd/system -maxdepth 2 -type l -ls` (EV-STATE); `systemctl is-enabled` output; `systemctl list-units 'desktop*'` (EV-STATE).
- Tier: T2/T3 · Coverage: ❌ evidence not saved; `smoke` asserts both symlinks and all four `is-enabled` results (`guest:phase_deploy` only `desktop-client-cdi`), but after its own copy of the live-apply commands, not the `deploy/README.md` "Apply" block.

**S5.1.2 Files land root-owned with correct modes**
- Requirement: every file from the tree is `root:root`; scripts are executable.
- Acceptance: `find` over the installed paths.
- Evidence: `find <paths> -printf '%M %u %g %p\n'` (EV-STATE).
- Tier: T2 · Coverage: ✅ `smoke` saves `stat -c '%A %U %G %n'` of every file the tree installed (26) and checks all are `root:root`, none group- or world-writable, and every script under `/usr/local/bin` and `/usr/local/libexec` `rwxr-xr-x`, under `artifacts/S5.1.2/` (artifact `evidence-smoke`).

**S5.1.3 Reboot is sufficient, and the operator gets a desktop with no one touching the host**
- Requirement: after a reboot with no manual starts, `desktop.service` is active, all oneshots succeeded, the session is up and visible, the tools spec is rewritten, labels are present, and `seat-prep` changed nothing.
- Acceptance: T3 variant: reboot the VM after phase-deploy and assert the above.
- Evidence: EV-SHOT of the desktop after reboot; `systemctl status` of every unit (EV-STATE); EV-LOG-JOURNAL `-b` for `desktop-seat-prep` (no `seat-prep:` lines); `ls -Z` of the three dirs; `ls /etc/cdi` with mtimes.
- Tier: T3 · Coverage: ❌.

### F5.2 Quadlet unit

**S5.2.1 The generator accepts the unit and emits the privilege reduction**
- Requirement: `quadlet -dryrun` succeeds; `ExecStart` has `--cap-drop all`, `--security-opt label[=:]disable`, `--log-driver k8s-file`, `--log-opt max-size=64m`, `--device nvidia.com/gpu=all`, and no `--privileged`.
- Acceptance: `dryrun`.
- Evidence: the generated unit (EV-CONFIG).
- Tier: T2 · Coverage: ✅ `dryrun` saves the unit quadlet generated under `artifacts/S5.2.1/` (artifact `evidence-smoke`) and checks each flag on its `ExecStart` line, `--privileged` absent included; the evidence names the quadlet binary that ran and its podman version.

**S5.2.2 Every PodmanArgs flag reaches ExecStart intact**
- Requirement: `--pid=host`, `--systemd=false`, `--tty`, `--security-opt apparmor=unconfined`, the three `--ulimit`s, and five `--device-cgroup-rule` arguments each arriving as **one** argument.
- Acceptance: parse the generated `ExecStart` with shell word-splitting and assert each flag/value; exactly five cgroup rules.
- Evidence: the generated unit (EV-CONFIG); the parsed argument list, one per line (EV-STATE).
- Tier: T2 · Coverage: ✅ `dryrun` splits the generated `ExecStart` with shell word-splitting (Python's `shlex`) and saves the unit and the argument list, one per line, under `artifacts/S5.2.2/` (artifact `evidence-smoke`); it checks that each flag arrives whole and that there are exactly five `--device-cgroup-rule` arguments, none split.

**S5.2.3 Every unit directive is emitted**
- Requirement: `WantedBy`, both `Conflicts`, `Wants=`/`After=` for all six units, `Wants=desktop-session.service`, `Restart=always`, `TimeoutStartSec=300`.
- Acceptance: anchored greps on the dry-run output.
- Evidence: EV-CONFIG with the directives listed in the index.
- Tier: T2 · Coverage: ✅ `dryrun` reads the generated unit per section (`ci/unit-directives.py`) and checks `WantedBy=multi-user.target`, both `Conflicts`, `Wants=` and `After=` for the six units, `Wants=desktop-session.service`, `Restart=always` and `TimeoutStartSec=300`, each a check in the index, the unit saved under `artifacts/S5.2.3/` (artifact `evidence-smoke`).

**S5.2.4 Volumes, tmpfs and the `/sys` mount are emitted**
- Requirement: every `Volume=`, both `Tmpfs=`, the `/sys` `Mount=` and `AddDevice=nvidia.com/gpu=all` appear in `ExecStart`, and `--device /dev/dri` wherever `/dev/dri` exists when the unit is generated (`AddDevice=-/dev/dri` is optional).
- Acceptance: greps on `ExecStart`.
- Evidence: EV-CONFIG.
- Tier: T2 · Coverage: ✅ `dryrun` checks each `Volume=`, `Tmpfs=`, `Mount=` and `AddDevice=` line of the source as the podman argument it becomes in the generated `ExecStart` (`--device /dev/dri` included: the runner has it), each a check in the index, the unit and the source saved under `artifacts/S5.2.4/` (artifact `evidence-smoke`).

**S5.2.5 `Conflicts=` backstop**
- Requirement: `desktop.service` cannot run alongside `getty@tty1.service` or `display-manager.service`.
- Acceptance: unmask and start `getty@tty1` → desktop stops; restore. Destructive; run last.
- Evidence: EV-LOG-JOURNAL for both units; `systemctl status` pair.
- Tier: T3 · Coverage: ❌ no test; `guest:phase_deploy` only shows that starting the desktop stops getty, which seat-prep also does, so it does not isolate `Conflicts=`.

**S5.2.6 Image pin drop-in**
- Requirement: on podman ≥ 5.0 a `desktop.container.d/50-image.conf` `Image=` override lands in the generated unit.
- Acceptance: on the Rocky VM: add a drop-in, `daemon-reload`, `systemctl cat` shows it, restart works; `desktop-preflight` reports the drop-in as merged.
- Evidence: `systemctl cat desktop.service` (EV-CONFIG); `podman inspect desktop --format '{{.ImageName}}'`; preflight row.
- Tier: T3 · Coverage: ❌.

### F5.3 Seat convergence (`seat-prep.sh`)

**S5.3.1 Dirty seat is walked back**
- Requirement: seat rules removed, display manager disabled and stopped, default target set, getty masked and stopped, logind restarted only if something changed.
- Acceptance: `smoke` staged seat rule + fake DM; `guest:phase_deploy`: start `desktop-seat-prep` on its own before `desktop.service`, and assert `getty@tty1` stopped and the `seat-prep: stopping running getty@tty1.service` journal line. (Starting the desktop proves nothing here: its `Conflicts=getty@tty1.service` stops the getty in the same transaction.)
- Evidence: EV-LOG-JOURNAL of `desktop-seat-prep` and `systemd-logind` (restart present on the dirty run, absent on steady state); `systemctl status getty@tty1 display-manager` before/after (EV-DIFF); `systemctl get-default`.
- Tier: T2/T3 · Coverage: ❌ evidence not saved; `smoke` and `dryrun` assert the seat-rule removal, DM stop, default target and getty mask, but not the logind restart. `guest:phase_deploy`'s getty eviction does not show seat-prep working, because the quadlet's `Conflicts=` stops that getty anyway.

**S5.3.2 Steady state is silent and idempotent**
- Requirement: a second run changes nothing and prints nothing.
- Acceptance: `smoke` runs the second pass as `systemctl restart desktop-seat-prep` before the desktop starts (seat-prep's DRM/VT gate fails while Xorg holds the seat), and asserts exit 0, an empty journal slice and no logind restart.
- Evidence: the (empty) stdout, EV-LOG-JOURNAL of the second run.
- Tier: T2 · Coverage: ✅ `smoke` runs the second pass as `systemctl restart desktop-seat-prep.service` before the desktop starts, and saves its output (none), the journal slice of the unit's own process for that run (empty) and systemd-logind's MainPID before and after (unchanged) under `artifacts/S5.3.2/` (artifact `evidence-smoke`).

**S5.3.3 The gate names a culprit and fails**
- Requirement: a process holding `/dev/dri/card*` or `/dev/tty1` after convergence → exit 1 naming it; `desktop.service` still starts.
- Acceptance: stop `desktop.service`; hold `/dev/dri/card0` from a background `sleep`; `systemctl restart desktop-seat-prep` fails naming that pid; `systemctl start desktop.service` still starts it; release; `systemctl restart desktop-seat-prep` succeeds. (`start` is a no-op on the already-active `RemainAfterExit=yes` unit, and while the desktop runs Xorg holds `card0` too.)
- Evidence: EV-LOG-JOURNAL with the `ERROR: devices still held` line and the `fuser -v` table; `systemctl status` of both units.
- Tier: T3 · Coverage: ❌.

**S5.3.4 Degrades without `psmisc`**
- Requirement: without `fuser`, the gate is skipped with a notice, exit 0.
- Acceptance: run `seat-prep.sh` with `fuser` absent from `PATH`; assert exit 0 and the `fuser not available` notice.
- Evidence: the notice line.
- Tier: T2 · Coverage: ✅ `smoke` runs `seat-prep.sh` with a `PATH` of every command but `fuser` and saves its output (`fuser not available (install psmisc); skipping DRM/VT holder verification`) and exit status (0), under `artifacts/S5.3.4/` (artifact `evidence-smoke`).

**S5.3.5 Missing logind drop-in is warned about**
- Requirement: a changed seat with the drop-in absent logs `WARNING: logind drop-in missing`.
- Acceptance: T2 on a dirty seat with the drop-in absent (before the tree is applied, or moved aside).
- Evidence: the warning line.
- Tier: T2 · Coverage: ✅ `smoke`'s dirty-seat run, before the tree is applied, saves the logind drop-in directory without the drop-in and seat-prep's output, which changes the seat and says `WARNING: logind drop-in missing`, under `artifacts/S5.3.5/` (artifact `evidence-smoke`).

### F5.4 GPU CDI convergence (`desktop-cdi-refresh`)

**S5.4.1 Stub on a GPU-less host, resolvable by podman**
- Requirement: no toolkit/hardware → stub spec; `--device nvidia.com/gpu=all` resolves and the marker lands on the init's environment.
- Acceptance: `dryrun` + `smoke` + `guest:phase_deploy`.
- Evidence: the spec (EV-CONFIG); `/proc/<init>/environ` grep (EV-STATE).
- Tier: T2/T3 · Coverage: ✅ `guest:phase_deploy` saves the stub spec `desktop-cdi-refresh` wrote and the NVIDIA lines of the container init's environment (`NVIDIA_CDI_STUB=1`) under `artifacts/S5.4.1/` (artifact `evidence-vm-core`); `dryrun` and `smoke` assert the same on the runner (job log only).

**S5.4.2 Real generation, transient failure, no-downgrade, recovery to stub**
- Requirement: with `nvidia-ctk` and `/dev/nvidiactl` the real spec is written; a failing `nvidia-ctk` keeps an existing real spec; without a toolkit an existing real spec is kept while `/dev/nvidiactl` exists or the `nvidia` module is loaded (`/proc/modules`); with neither, the stub returns.
- Acceptance: `smoke` with a fake `nvidia-ctk` and fake `/dev/nvidiactl`; the `/proc/modules` trigger needs an override (Appendix A).
- Evidence: the spec after each step (EV-CONFIG × 4); the script's stdout.
- Tier: T2 · Coverage: 🟡 the `/proc/modules` leg is not tested: the script reads `/proc/modules` itself, with no override a test could use (Appendix A). The other legs are asserted by `smoke`, which saves the converger's output and the spec after each of five legs (stub; generated; a failing `nvidia-ctk` keeps the real spec; no toolkit with the device node present keeps it; neither, back to the stub) under `artifacts/S5.4.2/` (artifact `evidence-smoke`).

**S5.4.3 Stale real spec fails loudly, regenerates on restart**
- Requirement: after a driver update the stale spec fails container creation; `systemctl restart desktop-cdi-refresh` fixes it.
- Acceptance: manual.
- Evidence: EV-LOG-JOURNAL of `desktop.service` (the creation error) and `desktop-cdi-refresh`; the spec before/after (EV-DIFF).
- Tier: T4 · Coverage: 🔧 guided hardware script, not yet written.

### F5.5 Client CDI specs

**S5.5.1 Display and audio specs are disjoint, rw, directory mounts**
- Requirement: as stated; legacy spec removed.
- Acceptance: `smoke` + `dryrun` runtime probes.
- Evidence: both specs (EV-CONFIG); the probe containers' `env` and `/proc/self/mountinfo` (EV-STATE).
- Tier: T2 · Coverage: ✅ `guest:phase_deploy` saves both specs, copies of S7.1.1's four probes, and `desktop-client-cdi` removing a superseded combined spec, under `artifacts/S5.5.1/` (artifact `evidence-vm-core`), and checks kinds, disjointness and rbind rw directory mounts; `smoke` and the `dryrun` probes assert the same on the runner (job log only).

**S5.5.2 Overrides and validation**
- Requirement: `DISPLAY_VALUE` and `X11_DIR` apply to the display spec and `AUDIO_DIR` to the audio spec; malformed `DISPLAY_VALUE` is rejected before any write; no temp files remain; defaults return when the file is removed.
- Acceptance: `smoke`, `dryrun`.
- Evidence: the override file and the specs after each step (EV-CONFIG); `ls /etc/cdi` (EV-STATE).
- Tier: T2 · Coverage: ✅ `smoke` saves the override file (`DISPLAY_VALUE`, `X11_DIR`, `AUDIO_DIR`) and both specs it gives, each override in its own spec only; a malformed `DISPLAY_VALUE` rejected before any write (the message, both specs unchanged, `ls /etc/cdi` with no temp file); and the default specs once the file is removed; under `artifacts/S5.5.2/` (artifact `evidence-smoke`).

**S5.5.3 Atomic writes**
- Requirement: specs are written via temp file + rename.
- Acceptance: inode changes and no leftovers.
- Evidence: `ls -li /etc/cdi` before/after (EV-DIFF).
- Tier: T2 · Coverage: ✅ `smoke` saves `ls -li /etc/cdi` before and after a regeneration, with the diff: both specs are new inodes, and no temp file is left, under `artifacts/S5.5.3/` (artifact `evidence-smoke`).

**S5.5.4 Tools spec is gated on a populated directory**
- Requirement: empty dir or dotfiles only → no spec; one regular file → spec with `DESKTOP_TOOLS_BIN` and an `ro` mount; `TOOLS_DIR` overridable; the relabeler is invoked first.
- Acceptance: T2 with `TOOLS_DIR=/tmp/x` set in `/etc/desktop-container/client-cdi.conf` (or in the environment once the Appendix A override lands: today the script assigns `TOOLS_DIR` itself): empty, dotfile-only, populated.
- Evidence: the script's stdout per case; `ls -la /tmp/x`; the spec (EV-CONFIG).
- Tier: T2 · Coverage: ✅ `smoke` sets `TOOLS_DIR` in the override file and runs `desktop-tools-cdi` on it empty, with a dotfile only and with one regular file, saving `ls -la` and the output of each run and the one spec written (`DESKTOP_TOOLS_BIN`, the directory mounted `ro`); the relabeler's line comes before `wrote`; under `artifacts/S5.5.4/` (artifact `evidence-smoke`).

**S5.5.5 The `.path` unit advertises once per boot and parks**
- Requirement: the service stays active; removing the spec does not re-advertise until the service is stopped; a reboot with a populated dir rewrites it.
- Acceptance: `rm` the spec; still absent after 5 s; `systemctl stop desktop-tools-cdi.service`; spec reappears; `.path` unit not failed. The reboot half runs in the T3 reboot sub-phase.
- Evidence: `systemctl status desktop-tools-cdi.{path,service}` at each step (EV-STATE); `ls -l /etc/cdi/desktop-tools.yaml` with mtime; EV-LOG-JOURNAL.
- Tier: T2/T3 · Coverage: ❌.

**S5.5.6 Specs are host state, independent of the desktop and of kubernetes**
- Requirement: display/audio specs exist before the desktop is up and survive `helm uninstall`.
- Acceptance: with `desktop.service` stopped, remove both specs and `systemctl restart desktop-client-cdi`: both reappear; `guest:verify_teardown` with `ls -l --full-time /etc/cdi` before and after `helm uninstall`. (`guest:phase2` checks the specs only once the desktop is already running.)
- Evidence: `ls -l /etc/cdi` with mtimes before/after (EV-DIFF empty for the two specs).
- Tier: T3 · Coverage: ❌ evidence not saved; `guest:verify_teardown` asserts the specs survive `helm uninstall`, but nothing shows they exist before the desktop is up (`guest:phase2` checks them with the desktop running).

### F5.6 SELinux labeling (`desktop-selinux`)

**S5.6.1 No-op without SELinux**
- Requirement: exit 0 with the no-op message, touching nothing.
- Acceptance: `smoke`.
- Evidence: stdout; `getenforce`/absence of `/sys/fs/selinux/enforce` (EV-STATE).
- Tier: T2 · Coverage: ✅ `smoke` saves the runner's SELinux state (no `/sys/fs/selinux`, no `getenforce`), the labeler's output (`no SELinux on this host: nothing to label`, exit 0) and `ls -ld` of the three directories it would label, before and after, with their empty diff, under `artifacts/S5.6.1/` (artifact `evidence-smoke`).

**S5.6.2 Three directories and the published binary are `container_file_t`**
- Requirement: full context `system_u:object_r:container_file_t:s0` (no categories) on all three dirs and the binary, before any client runs.
- Acceptance: `ls -Zd`.
- Evidence: `ls -Zd` of the three and `ls -Z` of the binary (EV-STATE); `getenforce`.
- Tier: T3 · Coverage: ❌ evidence not saved; `guest:phase_deploy` asserts the type only, so a label carrying categories still passes.

**S5.6.3 The label is policy, including the `/run` equivalency workaround**
- Requirement: an fcontext rule governs each dir (for `/run/desktop-audio`, under whichever of `/run` or `/var/run` the policy accepts: `desktop-selinux` tries `/run` first, and which spelling Rocky 9 stores has not been recorded yet); `restorecon -R` keeps the labels.
- Acceptance: `semanage fcontext -l -C` lists three rules; `restorecon -Rv` changes nothing.
- Evidence: the `semanage` listing and `restorecon -Rv` output (EV-STATE); `ls -Zd` after.
- Tier: T3 · Coverage: ❌ no test; `guest:phase_deploy`'s type check passes the same way when `semanage` fails and the `chcon` fallback does the labeling.

**S5.6.4 chcon fallback without semanage**
- Requirement: without `semanage` on `PATH`, the dirs are still labelled and the policy note printed.
- Acceptance: run with a stubbed `PATH` against a probe dir.
- Evidence: stdout; `ls -Zd` of the probe dir.
- Tier: T3 · Coverage: ❌.

**S5.6.5 Verification fails the unit when a label does not land**
- Requirement: a dir still lacking the type → `FAILED to label` naming it, exit 1.
- Acceptance: a dir on a filesystem that refuses relabeling.
- Evidence: stdout/exit code; `ls -Zd`; `mount` line of the probe fs.
- Tier: T3 · Coverage: ❌.

**S5.6.6 Missing directories are reported, not invented**
- Requirement: a missing dir is warned and skipped; none present → exit 1.
- Acceptance: two bogus paths → exit 1; one bogus + one real → warning, labelled, exit 0.
- Evidence: stdout and exit codes for both runs.
- Tier: T3 · Coverage: ❌.

**S5.6.7 The host keeps full access after relabeling**
- Requirement: an unconfined host process can connect to the X and audio sockets and execute the toolkit.
- Acceptance: `guest:phase_deploy` host `pactl`, host `screenshot --help`, host capture of `:0`.
- Evidence: the host capture PNG (EV-SHOT-CLIENT host variant); `pactl info`; `ausearch -m avc -ts recent` (empty) (EV-STATE).
- Tier: T3 · Coverage: ✅ `guest:phase_deploy` saves an unconfined host process running the relabeled `screenshot --help`, its capture of `:0`, `pactl info` over the relabeled socket, and `ausearch -m avc -ts <the start of these checks>` (`<no matches>`), and asserts that last one empty, under `artifacts/S5.6.7/` (artifact `evidence-vm-core`).

### F5.7 Host Terminal

**S5.7.1 Fresh key every boot, root-only, restricted trust**
- Requirement: ed25519 keypair under `/etc/desktop-container` (0400/0644), `authorized_keys.d/desktop-shell` (0644) with the `from=` and `no-*-forwarding` options.
- Acceptance: `dryrun`/`smoke`; `guest:phase_deploy` under enforcing.
- Evidence: `ls -l /etc/desktop-container /etc/ssh/authorized_keys.d` (EV-STATE); the authorized_keys line (EV-CONFIG).
- Tier: T2/T3 · Coverage: ❌ evidence not saved; `dryrun` asserts the `from=` loopback restriction and `smoke` the key's 0400 mode, but nothing checks the `no-*-forwarding` options, the key type or the other files' modes.

**S5.7.2 Login works both directions, and the operator gets a host shell from the menu**
- Requirement: `ssh -i <key> desktop-shell@127.0.0.1 whoami` from the host and `ssh host whoami` from the container return `desktop-shell`; the "Host Terminal" menu entry shows a prompt on the host.
- Acceptance: `smoke`, `guest:phase_deploy`; T3 launch `host-terminal` in an xterm and screendump.
- Evidence: both `whoami` transcripts (EV-STATE); EV-SHOT of the host-terminal xterm showing `desktop-shell@<host>`; EV-LOG-JOURNAL of `sshd` (the accepted publickey line).
- Tier: T2/T3 · Coverage: ✅ `guest:phase_deploy` saves both `whoami` transcripts (from the host with the key, and `ssh host` from the container) under `artifacts/S5.7.2/` (artifact `evidence-vm-core`). The menu half is evidenced in `artifacts/S11.1.1/` by `operator-e2e:menu_host_terminal`: a shot of the `desktop-shell@` prompt with `whoami` typed and answered, and sshd's accepted-publickey line.

**S5.7.3 Restrictions are enforced**
- Requirement: the key is refused from a non-loopback source; port forwarding is refused.
- Acceptance: ssh to the VM's non-loopback IP fails; `-L` with `ExitOnForwardFailure=yes` exits nonzero.
- Evidence: both ssh transcripts with exit codes; EV-LOG-JOURNAL of `sshd` showing the refusals.
- Tier: T3 · Coverage: ❌.

**S5.7.4 Re-running rotates the key and invalidates the old one**
- Requirement: a second run writes a different key; the old private key no longer authenticates; the container regains access after `desktop.service` restarts.
- Acceptance: as stated.
- Evidence: `ssh-keygen -lf` of old and new public keys (EV-DIFF); old-key ssh transcript (refused); new-key transcript; container `ssh host` before and after the restart.
- Tier: T2 · Coverage: ✅ `smoke` re-runs `desktop-host-shell.service` and saves `ssh-keygen -lf` of the public key before and after (different, with the diff), the old private key refused by sshd, the new one logging in as `desktop-shell`, and the container's `ssh host` refused before `desktop.service` restarts and logging in after, under `artifacts/S5.7.4/` (artifact `evidence-smoke`).

**S5.7.5 Empty or missing shell-user / account**
- Requirement: empty `shell-user` → exit 0, nothing written; missing `shell-user` → exit 1 with a hint (the tree ships the file: re-apply it, or use the quadlet's off-switch to turn the feature off), nothing written; account missing → exit 1 with the sysusers hint.
- Acceptance: T1 with a temp `DIR` or T2 before the tree is applied.
- Evidence: stdout and exit codes; `ls` of the dir after.
- Tier: T1/T2 · Coverage: ✅ `script-unit` runs `desktop-host-shell-setup` against a scratch directory (`DESKTOP_CONTAINER_DIR`, `HOST_SHELL_AK_DIR`): a missing `shell-user` exits 1 with the hint, an empty one exits 0, an unknown account exits 1 with the sysusers hint, and no case writes anything. Each case's output and exit status, and `ls -laR` of its directory after, are under `artifacts/S5.7.5/` (artifact `evidence-static`).

**S5.7.6 The sshd drop-in keeps stock key logins working**
- Requirement: ordinary users' home-dir keys still work.
- Acceptance: every `vm_ssh` as `rocky` after the drop-in is active.
- Evidence: one `vm_ssh` transcript after `sshd` reload (EV-STATE); the drop-in (EV-CONFIG).
- Tier: T3 · Coverage: ✅ `e2e` "sshd": the deploy tree's drop-in is in `/etc/ssh/sshd_config.d/`; `sshd -T` gives `authorizedkeysfile .ssh/authorized_keys /etc/ssh/authorized_keys.d/%u`, the stock home-dir path first; a fresh ssh login lands as `rocky`, and sshd's journal has an accepted publickey login for rocky after sshd's first reload this boot; the drop-in, `sshd -T`'s line, and the login transcript with rocky's key file and both journal lines, under `artifacts/S5.7.6/` (artifact `evidence-vm-core`).

**S5.7.7 Container side degrades gracefully without key material**
- Requirement: no key → hint logged, exit 0; empty `shell-user` → warning, exit 0; both present → `~/.ssh/config` and a 0400 key copy; preflight WARNs `no host shell material`.
- Acceptance: T1 in a scratch container; T2 stop the unit, delete the key files, restart desktop.
- Evidence: EV-LOG-DESKTOP (the hint and the preflight WARN); `~/.ssh/config` (EV-CONFIG); `ls -l /home/desktop/.ssh`; T3 EV-SHOT of the host-terminal xterm showing the failure message and "Press Enter to close".
- Tier: T1/T2 · Coverage: ❌.

**S5.7.8 The menu wrapper keeps its window open on failure**
- Requirement: on `ssh host` failure, `host-terminal` prints the exit code, the enablement command and the common causes, waits for Enter, exits with ssh's code; on success exits 0 at once.
- Acceptance: T1 with a fake `ssh`.
- Evidence: stdout and exit codes for both cases; T3 EV-SHOT (see S5.7.7).
- Tier: T1 · Coverage: ❌ the T3 EV-SHOT the evidence names (the window showing the failure and "Press Enter to close", shared with S5.7.7) is not taken. The rest is asserted, its evidence saved: `script-unit` runs `host-terminal` with a fake `ssh`; on success it exits 0 at once with stdin held open; on failure it prints the exit code, the enablement command and the common causes, waits for Enter and exits with ssh's code (255). Output and exit codes are under `artifacts/S5.7.8/` (artifact `evidence-static`).

### F5.8 Host login session (`desktop-session.service`)

**S5.8.1 A real logind session on seat0/tty1**
- Requirement: `loginctl` shows `desktop` on `seat0`; `/run/user/61000` mounted by logind; utmp has an entry for tty1.
- Acceptance: `smoke`, `guest:phase_deploy`; ❌ utmp.
- Evidence: `loginctl list-sessions` and `loginctl show-session <id>` (EV-STATE); `who`; `findmnt /run/user/61000`.
- Tier: T2/T3 · Coverage: ❌ evidence not saved; `smoke` and `guest:phase_deploy` assert a `desktop` session on `seat0` and that `/run/user/61000` exists, but not tty1, the logind mount or utmp.

**S5.8.2 Moves with the container**
- Requirement: `PartOf=desktop.service` restarts the session with the container.
- Acceptance: `smoke`.
- Evidence: `systemctl show -p ActiveEnterTimestamp desktop.service desktop-session.service` before/after (EV-DIFF both moved); EV-LOG-JOURNAL.
- Tier: T2 · Coverage: ✅ `smoke` saves `systemctl show -p ActiveEnterTimestamp` of `desktop.service` and `desktop-session.service` before and after `systemctl restart desktop.service`, with the diff (both moved), and the session unit's journal since, under `artifacts/S5.8.2/` (artifact `evidence-smoke`).

**S5.8.3 Does not steal the controlling tty**
- Requirement: the container's `setsid -c` on tty1 succeeds.
- Acceptance: X comes up and `podman logs` has no `failed to set the controlling terminal`.
- Evidence: EV-LOG-DESKTOP grep (empty); `ps -o tty= -p <desktop-session-lead>` is `?`.
- Tier: T3 · Coverage: ❌ evidence not saved; `guest:phase_deploy` asserts only that X comes up, not that the desktop log lacks `failed to set the controlling terminal` or that the session lead has no tty.

**S5.8.4 The desktop runs with the unit disabled**
- Requirement: see S2.2.2.
- Evidence: as S2.2.2.
- Tier: T2 · Coverage: ❌ as S2.2.2: the fallback is shown only in a scratch container, not with the unit disabled on a full deploy.

### F5.9 Accounts, tmpfiles, sysusers

**S5.9.1 uid contract**
- Requirement: host `desktop` is uid 61000 with `nologin`; the image's `desktop` is uid 61000.
- Acceptance: compare host `getent` with `podman exec desktop id -u desktop`.
- Evidence: both outputs side by side (EV-STATE).
- Tier: T2 · Coverage: ✅ `smoke` saves the host's `getent passwd desktop` (uid 61000, `/usr/sbin/nologin`) beside the image's `id -u desktop` (61000), under `artifacts/S5.9.1/` (artifact `evidence-smoke`).

**S5.9.2 `desktop-shell` is boring**
- Requirement: no supplementary groups, locked password, `/bin/bash`, home 0700.
- Acceptance: `id`, `passwd -S`, `stat`.
- Evidence: the three outputs (EV-STATE).
- Tier: T2 · Coverage: ✅ `smoke` saves `id desktop-shell` (no supplementary group), `passwd -S desktop-shell` (`L`, locked) and its passwd entry and home (`/bin/bash`, `700 desktop-shell:desktop-shell`), under `artifacts/S5.9.2/` (artifact `evidence-smoke`).

**S5.9.3 tmpfiles entries**
- Requirement: the eight entries with their modes and owners (`/home/desktop`, added for the host login session, is the eighth).
- Acceptance: `stat -c '%a %U' …` for each.
- Evidence: one `stat` table (EV-STATE).
- Tier: T2 · Coverage: ✅ `smoke` saves the installed tmpfiles.d file and the `stat` table of its eight paths after `systemd-tmpfiles --create`, each with the mode, owner and group the entry gives it, under `artifacts/S5.9.3/` (artifact `evidence-smoke`).

### F5.10 Host preflight (`desktop-preflight`)

**S5.10.1 Fully green on a provisioned host**
- Requirement: `done: 0 FAIL(s)`, exit 0.
- Acceptance: `guest:phase_deploy`.
- Evidence: the full output (EV-STATE).
- Tier: T3 · Coverage: ✅ `guest:phase_deploy` saves `desktop-preflight`'s full report under `artifacts/S5.10.1/` (artifact `evidence-vm-core`) and checks its exit status and its last line.

**S5.10.2 Reports a partially-applied host accurately**
- Requirement: on the dry-run's partially applied runner the report ends `done: N FAIL(s)` and shows `FAIL: quadlet unit missing`, `PASS: GPU-less host: stub CDI spec`, `PASS: desktop-shell account exists` and `PASS: default target is multi-user.target`.
- Acceptance: `dryrun`, `smoke`.
- Evidence: the full output.
- Tier: T2 · Coverage: ✅ `dryrun` saves `desktop-preflight`'s full report on the partially applied runner under `artifacts/S5.10.2/` (artifact `evidence-smoke`) and checks the rows the requirement names: the closing FAIL count, `FAIL: quadlet unit missing`, `PASS: GPU-less host: stub CDI spec`, `PASS: desktop-shell account exists` and `PASS: default target is multi-user.target`.

**S5.10.3 Each FAIL/WARN branch fires on its condition**
- Requirement: every row listed in the script fires when its condition is staged.
- Acceptance: T2 table-driven: stage, run, grep, restore.
- Evidence: per condition: the staging command, the row, the restore (EV-STATE table).
- Tier: T2 · Coverage: ❌.

### F5.11 Container preflight (`preflight-check.sh`)

**S5.11.1 Green on a provisioned KMS host**
- Requirement: no `preflight: FAIL:` lines on the VM.
- Acceptance: grep.
- Evidence: EV-LOG-DESKTOP preflight block.
- Tier: T3 · Coverage: ❌ nothing asserts it: no test greps the desktop log for `preflight: FAIL:`, and `guest:fail` prints the preflight block only after another check has failed.

**S5.11.2 Each check fires**
- Requirement: every FAIL/WARN in the script fires when staged (omitted mounts/devices/flags via `podman run`).
- Acceptance: T2 table-driven.
- Evidence: per case: the `podman run` command and the preflight block (EV-LOG-DESKTOP).
- Tier: T2 · Coverage: ❌.

---

## E6 — Container privileges and isolation

### F6.1 Privilege reduction

**S6.1.1 Not privileged; seccomp active**
- Requirement: `Privileged=false`; init `Seccomp: 2`.
- Acceptance: `smoke`, `guest:verify_privileges`.
- Evidence: `podman inspect` field; `/proc/<init>/status` Seccomp line (EV-STATE).
- Tier: T2/T3 · Coverage: ✅ `guest:verify_privileges` saves `podman inspect`'s `Privileged` (`false`) and the Seccomp lines of the container init's `/proc/<pid>/status` (`Seccomp: 2`) under `artifacts/S6.1.1/` (artifact `evidence-vm-core`); `smoke` asserts the same on the runner.

**S6.1.2 Forbidden capabilities absent**
- Requirement: none of these 13 capabilities is in init's `CapEff`: `SYS_MODULE`, `SYS_RAWIO`, `SYS_PTRACE`, `SYS_BOOT`, `SYS_TIME`, `NET_ADMIN`, `NET_RAW`, `DAC_READ_SEARCH`, `SYSLOG`, `BPF`, `PERFMON`, `SYS_ADMIN`, `KILL` (the list `guest:verify_privileges` checks; `README.md` names a different 13).
- Acceptance: `guest:verify_privileges`.
- Evidence: `CapEff` and its `capsh --decode` (EV-STATE).
- Tier: T3 · Coverage: ✅ `guest:verify_privileges` saves init's `/proc/<pid>/status` and `capsh --decode` of its `CapEff` under `artifacts/S6.1.2/` (artifact `evidence-vm-core`), and checks each of the 13 bits on its own.

**S6.1.3 Granted set is exactly what the quadlet lists**
- Requirement: `CapEff` decodes to exactly the nine granted capabilities.
- Acceptance: `capsh --decode` equals the set.
- Evidence: the decode output vs the quadlet's `AddCapability` lines (EV-DIFF).
- Tier: T3 · Coverage: ❌ no test; `guest:verify_privileges` reads `CapEff` but checks only the forbidden bits.

**S6.1.4 Device cgroup is bounded**
- Requirement: `/dev/mem` cannot be read; the five allowed majors can.
- Acceptance: a `c 1:1` node created in the container's own `/dev` cannot be opened (EPERM), and one node of each allowed major (13, 116, 226, 4, 5) can. Not under `/tmp`: podman mounts `Tmpfs=` `nodev` by default, so a node there is refused whatever the device cgroup allows.
- Evidence: the `mknod`/`dd` transcript with errno (EV-STATE); `cat /sys/fs/cgroup/.../devices.list` or the eBPF equivalent where readable.
- Tier: T3 · Coverage: ❌ evidence not saved, and `guest:verify_privileges` cannot tell a device-cgroup denial from the nodev on `/tmp` (podman's default for `Tmpfs=`), where it makes the `/dev/mem` node; the allowed majors are exercised only as side effects of the X, input and audio tests.

**S6.1.5 `/sys` is read-only and non-recursive**
- Requirement: `/sys` mount is `ro`; nothing is mounted at `/sys/fs/cgroup` or `/sys/fs/selinux` inside (the empty mountpoint directories remain under a non-recursive bind).
- Acceptance: `guest:verify_privileges` (ro); ❌ submounts.
- Evidence: `/proc/<init>/mounts` filtered to `/sys` (EV-STATE); `ls /sys/fs`.
- Tier: T3 · Coverage: ❌ submounts untested and evidence not saved; `guest:verify_privileges` asserts `ro` from the init's own mount table.

### F6.2 Namespace sharing and mandatory access control

**S6.2.1 Host pid namespace, bounded by capability**
- Requirement: the container sees host pids but, as container root, cannot signal a host process of another uid (`kill -0 <pid>` → EPERM) nor read pid 1's memory or environ. kill(2) allows a signal between processes of the same uid without `CAP_KILL`, and with no user namespace container root is host uid 0, so signalling host processes that also run as root is not prevented by this design; the original `kill -0 1` → EPERM acceptance could not hold.
- Acceptance: as stated, as container root.
- Evidence: the three command transcripts with errno (EV-STATE); `ls /proc | head`.
- Tier: T3 · Coverage: ❌ negatives untested and evidence not saved; `smoke` and `guest:verify_privileges` assert visibility (the recorded init pid resolves to `desktop-init` on the host).

**S6.2.2 Host network namespace**
- Requirement: the container's interfaces equal the host's.
- Acceptance: `readlink /proc/self/ns/net` inside equals the host's, and the interface names in `/proc/net/dev` match (the image may not ship `ip`).
- Evidence: both outputs (EV-DIFF empty).
- Tier: T3 · Coverage: ❌ no direct test and no evidence; shared networking is exercised only as a side effect, by the container's `ssh host` (to `127.0.0.1`) reaching the host's sshd in `smoke` and `guest:phase_deploy`.

**S6.2.3 SELinux separation off for the desktop, AppArmor unconfined**
- Requirement: desktop processes run `spc_t`/unconfined; on an AppArmor host the profile is `unconfined`.
- Acceptance: `ps -Z -p <init>` on the VM; `podman inspect … AppArmorProfile` on the runner.
- Evidence: both outputs (EV-STATE).
- Tier: T2/T3 · Coverage: ❌ no test of the running labels; `dryrun` checks only that `label=disable` reaches the generated `ExecStart`, and `apparmor=unconfined` is not checked anywhere.

**S6.2.4 Not systemd mode**
- Requirement: `--systemd=false`: stop signal SIGTERM; no systemd-mode tmpfs set.
- Acceptance: the generated `ExecStart` carries `--systemd=false` (`dryrun`), and `podman inspect` `StopSignal` is SIGTERM. A missing `/run/systemd/system` inside proves nothing: with `desktop-init` as the command, podman's systemd mode would not create it either.
- Evidence: both (EV-STATE).
- Tier: T2 · Coverage: ✅ `dryrun` saves the generated `ExecStart` split into arguments, `--systemd=false` one of them, and `smoke` saves the running container's `podman inspect` stop signal (15, SIGTERM), both under `artifacts/S6.2.4/` (artifact `evidence-smoke`).

---

## E7 — Client contract and client-application experience

E7 is where the client's end-to-end claims live (the maintainer's are in E10,
the operator's own controls in E11). F7.1–F7.4 are the mechanics of the
contract (devices, toolkit, kubernetes, screenshot delivery). F7.5–F7.8 are
the **journeys**: what an application container, started once and never
restarted, can rely on from this desktop as the operator and the machine do
things around it. Every journey story captures `restartCount` (pods) or
container `StartedAt` (podman) and the application's own pid before and after,
because "it works" without "and nothing restarted" is not the claim.

### F7.1 podman clients

**S7.1.1 Each device grants only its own capability**
- Requirement: display alone → `DISPLAY` + X socket, no audio; audio alone → both audio env vars + audio dir, no display; both → union; none → nothing.
- Acceptance: `dryrun`, `guest:phase_deploy` (confined, real `xdpyinfo`).
- Evidence: per probe: `env`, `/proc/self/mountinfo`, `xdpyinfo` exit (EV-STATE); `ps -Z` of the probe (confined).
- Tier: T2/T3 · Coverage: ✅ `guest:phase_deploy` runs four confined podman probes (display alone, audio alone, both, none) and saves each one's markers, full `env`, the two mounts in its `/proc/self/mountinfo` and its SELinux label (`container_t`, read from `/proc/self/attr/current` rather than `ps -Z`) under `artifacts/S7.1.1/` (artifact `evidence-vm-core`); `xdpyinfo`'s exit shows as `XDPYINFO_OK`. `dryrun` runs the same four combinations unconfined (job log only).

**S7.1.2 Confined clients work under enforcing**
- Requirement: no `label=disable`, no `--privileged` on any client; a static guard keeps it that way.
- Acceptance: `guest:phase_deploy` probes; a static check finds no `--privileged` or `label=disable` on any `podman run`/`podman create` command or client manifest under `ci/` and `examples/` (a plain grep would match the log and failure messages that name `--privileged` when describing the desktop container).
- Evidence: `getenforce`; `ps -Z` of a probe; `ausearch -m avc -ts recent` (empty) (EV-STATE); the grep output.
- Tier: T3/T0 · Coverage: ❌ no static guard and no evidence saved; `guest:phase_deploy`'s podman probes run without `label=disable` or `--privileged` and pass under enforcing.

> **`podman exec` does not get a device's env.** podman applies the edits
> when the container starts, to the process it starts with: an exec session
> sees the mounts but not `DISPLAY`, `PULSE_SERVER` or `PIPEWIRE_REMOTE`.
> Found by the operator phase, whose observer runs its probes with `podman
> exec` and so passes `DISPLAY` itself (after checking the observer's own
> process got `:0` from the spec); seen with the podman the e2e VM installs
> and with podman 4.9. `kubectl exec` into a pod does get them
> (`guest:assert_pod_env`). The README's client sections say so.

### F7.2 Published toolkit

**S7.2.1 Published at boot, 0755, by rename**
- Requirement: `screenshot` appears in the host dir mode 0755; a republish produces a new inode.
- Acceptance: `smoke`; inode changes across a restart; no temp files.
- Evidence: `ls -li` before/after (EV-DIFF); `sha256sum`.
- Tier: T2 · Coverage: ✅ `smoke` saves `ls -li` and `sha256sum` of the toolkit directory before and after `systemctl restart desktop.service`, with the diff: `screenshot` republished 0755 as a new inode, no temp file left, under `artifacts/S7.2.1/` (artifact `evidence-smoke`).

**S7.2.2 Stale tools are pruned, dotfiles left alone**
- Requirement: an unshipped regular file is removed on the next publish; a dotfile is not.
- Acceptance: as stated.
- Evidence: `ls -la` before/after (EV-DIFF); EV-LOG-DESKTOP `pruned` line.
- Tier: T2 · Coverage: ✅ `smoke` plants an unshipped regular file and a dotfile in the toolkit directory, restarts the desktop, and saves `ls -la` before and after with the diff (the file gone, the dotfile kept) and publish-tools' `pruned stale-tool (no longer shipped by this image)` line, under `artifacts/S7.2.2/` (artifact `evidence-smoke`).

**S7.2.3 The directory is never emptied during a republish**
- Requirement: prune after publish, one entry at a time.
- Acceptance: an inotify watch never sees the directory empty.
- Evidence: the `inotifywait -m` transcript across a restart (EV-STATE).
- Tier: T2 · Coverage: ✅ `smoke` saves the directory's listing and an `inotifywait -m` transcript across the restart's republish (the temp file created and renamed over `screenshot`, the unshipped file deleted) and replays it: the directory always held a tool; under `artifacts/S7.2.3/` (artifact `evidence-smoke`).

**S7.2.4 Clients receive it read-only via `DESKTOP_TOOLS_BIN`**
- Requirement: the device injects the env and an `ro` mount; the binary executes; not writable; a pod without the request has neither.
- Acceptance: `smoke`, `guest:verify_screenshot`, `guest:verify_split`.
- Evidence: `env`, `mountinfo`, `touch` failure transcript (EV-STATE); the binary's `--help` output.
- Tier: T2/T3 · Coverage: ✅ `guest:verify_split` and `guest:verify_screenshot` save, under `artifacts/S7.2.4/` (artifact `evidence-vm-k8s`): a display-only pod's `env` and `mountinfo` (no toolkit), the tools spec, the requesting pod's `env`, its toolkit mount line (`ro`), the binary's `--help`, and `touch` refused (`Read-only file system`). `smoke` asserts the podman-client half (job log only).

**S7.2.5 Advertised only after provisioning**
- Requirement: no spec before the desktop's first start; present after.
- Acceptance: `smoke`.
- Evidence: `ls -l /etc/cdi` before and after the first start (EV-DIFF).
- Tier: T2 · Coverage: ✅ `guest:phase_deploy` saves `ls -l --full-time /etc/cdi` right after the tree is applied (no `desktop-tools.yaml`; on the VM no `/etc/cdi` at all yet) and after the desktop has published, with the diff, under `artifacts/S7.2.5/` (artifact `evidence-vm-core`); `smoke` asserts the same on the runner (job log only).

### F7.3 Kubernetes clients

**S7.3.1 Resources become allocatable, pods get injected edits**
- Requirement: three releases → three resources at 10; a requesting pod gets env + sockets; a control pod gets nothing.
- Acceptance: `guest:phase2`, `guest:verify_cdi`.
- Evidence: `kubectl get node -o jsonpath=allocatable` (EV-STATE); the verifier and control pods' `env`/`mountinfo` (EV-DIFF between them); plugin logs (EV-LOG-CLIENT).
- Tier: T3 · Coverage: ❌ evidence not saved; `guest:phase2` and `guest:verify_cdi` assert the three allocatable resources and the injected edits, but the control pod is checked only for `DISPLAY` and the X socket, not the audio env or mount.

**S7.3.2 Split holds in pods**
- Requirement: display-only has display, no audio, no toolkit; audio-only plays, has no display and cannot `xdpyinfo`.
- Acceptance: `guest:verify_split`.
- Evidence: per pod `env`, `mountinfo`, `xdpyinfo` exit (EV-STATE); EV-AUDIO from audio-only.
- Tier: T3 · Coverage: ❌ evidence not saved (no audio is captured from `audio-only`); `guest:verify_split` asserts the split, but its only check that `audio-only` can play is `pactl info` connecting.

**S7.3.3 Pods are confined and declare no securityContext**
- Requirement: `container_t`; manifests carry no `securityContext`, `volumes`, `env`, or CDI annotation.
- Acceptance: `guest:phase2`, `ci/helm-assertions.sh`.
- Evidence: `/proc/self/attr/current` from the pod (EV-STATE); the manifests (EV-CONFIG).
- Tier: T0/T3 · Coverage: ❌ evidence not saved; `ci/helm-assertions.sh` checks all four omissions only on the example, `cdi-verify` and `testclient` manifests (the narrow fixtures and `testpattern` only for `securityContext`), and `guest:phase2` reads `container_t` from one pod.

**S7.3.4 A lean non-desktop image works**
- Requirement: an image with no X server and no window manager, running no audio daemon of its own (no `pipewire`, `wireplumber` or `pipewire-pulse` process), opens the display and plays all three paths with injected env only. (The lean image does carry the daemon packages, pulled in as dependencies of `pipewire-utils` and `pipewire-alsa`; nothing starts them.)
- Acceptance: `guest:verify_testclient`, `e2e` lean-client tone loop.
- Evidence: `rpm -qa` of the lean image (no Xorg server, no WM) and a `ps` of the pod (no audio daemon) (EV-STATE); `xdpyinfo` output; three EV-AUDIO captures.
- Tier: T3 · Coverage: ✅ `guest:verify_testclient` saves `rpm -qa` of the lean image (no `xorg-x11-server-*`, no `motif`; `pipewire` and `wireplumber` are there as dependencies), the pod's processes read from `/proc` (only `sleep` and the probe), its `env` and `xdpyinfo`; the `e2e` lean-client loop adds the three tones with `check-audio.py`'s verdict and a level plot each; all under `artifacts/S7.3.4/` (artifact `evidence-vm-k8s`).

**S7.3.5 Concurrency**
- Requirement: three pods hold live X connections at once.
- Acceptance: `guest:verify_concurrency`, with each pod's window at its own position (today all three reuse the example's `-geometry 80x24+200+200` and stack, so the shot cannot show three).
- Evidence: EV-SHOT `concurrent-clients.png` with three windows; `screenshot --list-clients` showing three pod pids (EV-STATE).
- Tier: T3 · Coverage: ✅ `guest:verify_concurrency` places the three pods' xterms one above the other and saves `screenshot --list-clients` while they hold the display, with each pod's UID matched to the listed client whose cgroup carries it; `e2e` adds the screendump showing all three; under `artifacts/S7.3.5/` (artifact `evidence-vm-k8s`).

**S7.3.6 Teardown seam**
- Requirement: `helm uninstall` withdraws the resources; host specs and the desktop survive; existing client pods that were already running keep their windows (they hold their mounts).
- Acceptance: `guest:verify_teardown` (display, audio); ❌ extend to `tools`; ❌ a running client pod keeps working through the uninstall.
- Evidence: allocatable before/after (EV-DIFF); `ls -l /etc/cdi` unchanged; EV-SHOT of the client window still present; the client pod's `restartCount` (EV-PIDS).
- Tier: T3 · Coverage: ❌ evidence not saved; `guest:verify_teardown` covers the display and audio releases (resources withdrawn, host specs and the desktop kept), but not `tools`, and no running client pod is watched through the uninstall.

**S7.3.7 The desktop survives CRI-O and k3s arriving**
- Requirement: `desktop.service` active and `X0` present after the runtime install.
- Acceptance: `guest:phase2`.
- Evidence: EV-PIDS of Xorg/mwm/pipewire before and after the install (unchanged); EV-SHOT.
- Tier: T3 · Coverage: ❌ no pid proof and no EV-PIDS saved: `guest:phase2` asserts only that `desktop.service` is active and the `X0` socket file exists, which a restarted desktop also passes.

### F7.4 Screenshot delivery as the toolkit's proof

**S7.4.1 Captured pixels are the screen**
- Requirement: the injected binary's capture matches the painted pattern, regions equal crops, stdout equals file, orientation beats flipped variants, `-h` is height, oversize → exit 2, no `DISPLAY` → exit 1.
- Acceptance: `guest:verify_screenshot` + `e2e` pixel assertions.
- Evidence: all seven PNGs (EV-SHOT-CLIENT), the QEMU reference (EV-SHOT), the per-assertion pixel values and RMSE scores in the index.
- Tier: T3 · Coverage: ✅ under `artifacts/S7.4.1/` (artifact `evidence-vm-k8s`): `guest:verify_screenshot` saves the display size, the oversized-region (exit 2) and no-`DISPLAY` (exit 1) transcripts and a check per capture size; `e2e` adds the seven captures, the QEMU reference, every pixel value read (one check each), the five region comparisons and the four RMSE scores. The orientation cross-check now fails, rather than warning, when the reference is missing or of another size.

### F7.5 Client application journeys: display

The user starts an application container once and uses it. **Common set**:
`kubectl get pod -o wide` / `podman inspect` with `restartCount`/`StartedAt`
and the app's pid before and after (EV-PIDS); EV-SHOT of the desktop showing
the client window; EV-SHOT-CLIENT from inside the client; EV-LOG-CLIENT;
`xwininfo -root -tree` (EV-STATE); EV-TIMELINE.

**S7.5.1 A client application's window appears and is usable (podman)**
- Requirement: `podman run --device desktop.local/display=all <img> xterm` puts an xterm on the desktop; the user can click into it and type; the text appears in that window.
- Acceptance: window present in `xwininfo -root -tree` with the client's title; QMP click at its centre + typed text; the client-side sink file has the text.
- Evidence: common set; EV-SHOT with the typed text visible inside the client's window.
- Tier: T3 · Coverage: ❌ evidence incomplete (no client-side screenshot, no `podman inspect` before and after); asserted in part by `operator-e2e:s11_1_3` and `operator-e2e:s11_2_1`, which type and paste into podman client xterms and read the client-side sinks, but no story clicks a client window and then types into it.

**S7.5.2 The same under kubernetes**
- Requirement: S7.5.1 for `examples/x11-client-pod.yaml`.
- Acceptance: as S7.5.1 against the demo pod.
- Evidence: common set.
- Tier: T3 · Coverage: ❌ evidence not saved and no interaction: `guest:phase2` only waits for the demo pod to run, and `e2e` checks the screendump taken then (`desktop-k3s-client.png`) only for being non-blank.

**S7.5.3 A client window gets decoration, focus and keyboard**
- Requirement: a client window has an mwm frame, takes focus on click (frame turns the active colour) and receives keystrokes.
- Acceptance: pixel sample of the frame before/after the click; sink text.
- Evidence: EV-SHOT pair with sampled frame colours; sink file; EV-PIDS (`restartCount` or `StartedAt` and the app's pid, before and after).
- Tier: T3 · Coverage: ❌ evidence incomplete (no sink file for the window that was clicked); asserted in part by `operator-e2e:s3_5_3`, which samples a podman client's frame colour before and after a click (`artifacts/S3.5.3/`), while keystrokes reach client windows only in `operator-e2e:s11_1_3` and `operator-e2e:s11_2_1`.

**S7.5.4 A client started before the desktop is up works once it is, without restarting**
- Requirement: a pod started while `desktop.service` is stopped is admitted (specs are host state), its app retries the display, and when the desktop comes up its window appears, `restartCount` 0.
- Acceptance: stop desktop; apply a pod whose command loops on `xterm` until success; start desktop; window appears; `restartCount` 0.
- Evidence: common set; EV-LOG-CLIENT showing the retries then success; EV-VIDEO from desktop start to window appearance.
- Tier: T3 · Coverage: ❌.

**S7.5.5 After an X session restart, a client container reconnects without being recreated**
- Requirement: when Xorg restarts, X clients lose their connection (that is X11); the application container itself must not need recreating: its next `xterm` connects to the new server, `restartCount` 0, same container id.
- Acceptance: pod running `sleep infinity` spawns an xterm; kill Xorg; after the session returns, the pod spawns another xterm, which appears; the pod's container id unchanged.
- Evidence: common set across the restart; EV-LOG-CLIENT (the first xterm's "connection to X server lost" message is expected and quoted); EV-VIDEO.
- Tier: T3 · Coverage: ❌ evidence not saved; asserted only in part, as a side effect: after `operator-e2e:s11_1_1`'s Quit session the long-running `op-observer` client container must reach the new X server, but no window from it appears and its container id is not recorded.

**S7.5.6 A client's capture matches what the operator sees**
- Requirement: EV-SHOT-CLIENT from a client matches the QEMU screendump of the same moment far better than any flipped, mirrored or rotated version of it. They may legitimately differ (a pointer drawn into one capture and not the other), so the comparison is a margin, not equality.
- Acceptance: `e2e` "screenshot" orientation/margin test (`orientation_scores`, `orientation_ok`); a missing reference or one of another size fails.
- Evidence: both images and the RMSE scores; EV-PIDS (`restartCount` or `StartedAt` and the app's pid, before and after).
- Tier: T3 · Coverage: ✅ `e2e` "screenshot" saves the client's capture, QEMU's screendump of the same moment, the four RMSE scores, and the capturing pod's restart count, container id, start time and main pid before and after, under `artifacts/S7.5.6/` (artifact `evidence-vm-k8s`); a missing or mis-sized reference fails. On the e2e VM the two images were identical (RMSE 0): virtio-vga's pointer is a hardware cursor, which neither capture includes.

**S7.5.7 Many clients share one desktop**
- Requirement: three client pods hold live connections and all three windows are on screen.
- Acceptance: `guest:verify_concurrency` with each pod's window at its own position, three client windows found in `xwininfo -root -tree`, and `screenshot --list-clients` run while all three are connected.
- Evidence: EV-SHOT with three windows; `screenshot --list-clients`; EV-PIDS (`restartCount` or `StartedAt` and the app's pid, before and after).
- Tier: T3 · Coverage: ❌ evidence incomplete (`screenshot --list-clients` is not run for these pods); `guest:verify_concurrency` asserts three live X connections but not three windows on screen (all three xterms open at `+200+200`, so `concurrent-clients.png` cannot show them apart).

### F7.6 Client application journeys: audio

**Common set**: EV-PIDS (pod `restartCount`, app pid, the three audio daemons),
`pactl list short sink-inputs source-outputs` before/during/after (EV-STATE),
EV-LOG-CLIENT (the player's output), EV-AUDIO with spectrogram, EV-TIMELINE.

**S7.6.1 A client plays and the operator hears it**
- Requirement: a pod with `desktop.local/audio` plays via pulse, PipeWire-native and ALSA, and each is heard.
- Acceptance: `guest:play_audio_pod` × 3 with frequency checks.
- Evidence: common set; three EV-AUDIO captures.
- Tier: T3 · Coverage: ❌ evidence incomplete (no sink-input listing, pids or spectrograms; only the WAVs `artifacts/audio-cdi-*.wav` are saved); asserted by `guest:play_audio_pod` × 3 with frequency checks.

**S7.6.2 A client records**
- Requirement: a pod records the sink monitor and the recording carries the tone.
- Acceptance: `guest:verify_record`.
- Evidence: EV-AUDIO-REC; EV-PIDS (`restartCount` or `StartedAt` and the app's pid, before and after).
- Tier: T3 · Coverage: ✅ `e2e` "cdi: a client can RECORD": `guest:verify_record` has the cdi-verify pod record the default sink's monitor with `parec` while a 660 Hz tone plays (S4.6.1), and the recording, copied out of the VM, carries 660 Hz by `check-audio.py`; the pod's container (`restartCount`, id, start time) and its main process's host pid before and after, their diff empty (the same container, `restartCount` 0); the recording with its verdict and level plot, under `artifacts/S7.6.2/` (artifact `evidence-vm-k8s`).

**S7.6.3 A client's playback continues through an X session restart, uninterrupted**
- Requirement: an application container playing a 20 s tone when Xorg is killed keeps playing with no gap, `restartCount` 0, same app pid.
- Acceptance: start playback at 1100 Hz from a pod; kill Xorg; capture the whole span; the spectrogram shows a continuous 1100 Hz line across the restart; `check-audio.py` on a window straddling the restart passes.
- Evidence: common set; EV-AUDIO spanning the restart with the restart timestamp marked on the spectrogram; EV-VIDEO of the display going down and back while the tone continues.
- Tier: T3 · Coverage: ❌ (the desktop-side pid proof exists in `guest:verify_audio_lifecycle`; the client's uninterrupted experience is unproven).

**S7.6.4 A client recovers from an audio-stack restart without being recreated**
- Requirement: when PipeWire restarts, a client's current stream ends with a clean error; the same container's next playback succeeds; `restartCount` 0.
- Acceptance: pod plays; kill pipewire; the player exits nonzero within 10 s with a connection error; after the export is back, the same pod plays again and is heard.
- Evidence: common set; EV-LOG-CLIENT quoting the error; two EV-AUDIO captures (before: tone then stop at the kill timestamp; after: tone).
- Tier: T3 · Coverage: ❌.

**S7.6.5 A client started before the audio stack is up plays once it is, without restarting**
- Requirement: a pod admitted while the audio export is absent retries and succeeds when the export appears; `restartCount` 0.
- Acceptance: stop desktop; apply a pod whose command loops on `paplay` until success; start desktop; a tone is heard; `restartCount` 0.
- Evidence: common set; EV-LOG-CLIENT showing retries; EV-AUDIO.
- Tier: T3 · Coverage: ❌ no test: `guest:verify_cdi` only waits for an export that is already up; the desktop is never stopped before a pod is applied.

**S7.6.6 A lean client with no PipeWire of its own plays and records**
- Requirement: the testclient image plays all three paths and records via the injected env alone.
- Acceptance: `e2e` lean-client loop for playback; for recording, a `parec` loopback recorded in the lean client, pulled out and analysed.
- Evidence: three EV-AUDIO; EV-AUDIO-REC; EV-PIDS (`restartCount` or `StartedAt` and the app's pid, before and after).
- Tier: T3 · Coverage: ❌ the lean client never records, and its playback WAVs (`artifacts/audio-testclient-*.wav`) are saved without spectrograms; playback is asserted by `e2e` "cdi: a LEAN non-desktop image" with `check-audio.py`.

### F7.7 Hotplug continuity for running client applications

This is the feature that answers "will the application container keep working
when the user plugs or unplugs something, without being restarted?" Each story
pairs an F3.9/F3.10/F4.7 event with a client application that was already
running before the event and is still the same process afterwards.
**Common set**: EV-PIDS (the pod's `restartCount` and container id, or a
podman client's `RestartCount`, `StartedAt` and container id; the app's pid;
Xorg/mwm; the three audio daemons) before and after; EV-LOG-CLIENT; EV-TIMELINE;
EV-VIDEO of the display across the event; plus the device-specific set from
the referenced feature.

**S7.7.1 A client window keeps receiving keystrokes across a keyboard remove/re-add**
- Requirement: a client xterm that had focus before the KVM-style keyboard cycle receives text typed through the re-added keyboard afterwards; same pod, same app pid.
- Acceptance: focus a client xterm (sink); `device_del`/`device_add` the USB keyboard; type through `kvmkbd` (S3.9.5); the client's sink file has the text.
- Evidence: common set; sink file from inside the pod; EV-SHOT of the text in the client's window.
- Tier: T3 · Coverage: ❌.

**S7.7.2 A client window is clickable with a hot-added pointer**
- Requirement: a tablet added after the client started can click into the client's window and give it focus.
- Acceptance: `device_add usb-tablet`; click via that device on the client window; frame turns active; typed text lands.
- Evidence: common set; EV-SHOT pair (frame colour); sink file.
- Tier: T3 · Coverage: ❌.

**S7.7.3 Client windows stay put across a monitor plug-out and re-plug (layout declared)**
- Requirement: a client window's geometry (`xwininfo`) is identical before the connector goes down, while it is down, and after it returns; the client is not restarted.
- Acceptance: `xwininfo -id <client window>` at the three moments equal; `restartCount` 0.
- Evidence: common set; the three `xwininfo` outputs (EV-DIFF empty); EV-SHOT-CLIENT at the three moments (the client's own view is unchanged); EV-VIDEO.
- Tier: T3 · Coverage: ❌.

**S7.7.4 A client already playing is heard on a hot-added audio device, without restarting**
- Requirement: an application container playing a continuous tone to the default sink keeps playing while a USB sound card is added; once that card becomes the default sink (WirePlumber policy, or the test sets it), the client's **existing stream** is heard on the new device; the container and the player are the same process throughout.
- Acceptance: pod plays a 60 s 1100 Hz tone; `device_add usb-audio`; `wpctl set-default <new sink>` (or observe policy move it); `pactl list short sink-inputs` shows the client's stream now on the USB sink; `wavcapture` on the shared backend carries 1100 Hz throughout with no gap; `restartCount` 0; app pid unchanged.
- Evidence: common set; EV-AUDIO spanning the event with the `device_add` and default-change timestamps marked on the spectrogram; `pactl list short sink-inputs` at three moments (EV-STATE) showing the stream's sink id change; `wpctl status` pair; EV-QEMU.
- Tier: T3 · Coverage: 🟡 `operator-e2e:s11_3_1` asserts it with a podman client container in place of the pod (E11's definition of a client); no kubernetes pod variant is run. Under `artifacts/S11.3.1/`: the capture with each mark on a level plot, `info usb`, `/dev/snd` on the host and in the container, `pw-cli ls Device` and `pactl list short` sinks, sources and sink-inputs at four moments with diffs (the stream's sink id moving), a video of the plug, `wpctl status` after every step, the player's inspect before and after, pid tables and the desktop's log.

**S7.7.5 A client playing on the hot-added device survives its removal**
- Requirement: with the client's stream on the USB sink, `device_del` moves the stream back to the built-in sink (or ends it cleanly); the client is not restarted; its next playback is heard.
- Acceptance: continuation of S7.7.4: `device_del`; `pactl list short sink-inputs` shows the stream on the built-in sink or gone with a clean client error; capture continues or resumes; `restartCount` 0.
- Evidence: common set; EV-AUDIO continuing from S7.7.4 with the removal timestamp marked; EV-LOG-CLIENT.
- Tier: T3 · Coverage: ❌.

**S7.7.6 A client started while the hot-added device is present can target it by name**
- Requirement: a new client can `pw-play --target` / `PULSE_SINK=<usb sink>` and be heard on it.
- Acceptance: as stated with a 990 Hz tone.
- Evidence: EV-AUDIO; `pactl list short sink-inputs` naming the sink; EV-PIDS (`restartCount` or `StartedAt` and the app's pid, before and after).
- Tier: T3 · Coverage: ❌.

**S7.7.7 A client records from a hot-added capture device without restarting**
- Requirement: a running pod can open the new source and deliver frames.
- Acceptance: S4.7.8/S4.7.9 from a pod that was running before the hot-add.
- Evidence: common set; EV-AUDIO-REC.
- Tier: T3/T4 · Coverage: ❌.

**S7.7.8 A client survives the KVM composite event**
- Requirement: a client xterm and a client audio stream both continue across S3.11.1; afterwards the xterm takes typed text through the re-added keyboard and the stream is still heard; `restartCount` 0 for both pods.
- Acceptance: S3.11.1 with two client pods in play.
- Evidence: common set for both pods; EV-AUDIO spanning the event; EV-SHOT of typed text.
- Tier: T3 · Coverage: ❌.

**S7.7.9 A client that started on a soundless host plays once a card arrives, without restarting**
- Requirement: on the no-`intel-hda` profile, a pod whose player loops until success starts before any card exists; after `usb-audio` is added and the stack re-aligns, the tone is heard; `restartCount` 0.
- Acceptance: S2.4.6 with the pod in play.
- Evidence: common set; EV-LOG-CLIENT (retries then success); EV-LOG-DESKTOP align lines; EV-AUDIO.
- Tier: T3 · Coverage: ❌.

### F7.8 Desktop lifecycle as seen by running clients

**S7.8.1 A `desktop.service` restart does not recreate client pods**
- Requirement: client pods lose their X connection and audio stream (expected), are not restarted by kubernetes, and work again against the new desktop with the same container id.
- Acceptance: pods running `sleep infinity` with child apps; `systemctl restart desktop.service`; `restartCount` 0, container id unchanged; new xterm and new tone succeed.
- Evidence: common set from F7.7; EV-SHOT after; EV-AUDIO after; EV-LOG-CLIENT quoting the expected disconnect messages.
- Tier: T3 · Coverage: ❌.

**S7.8.2 Toolkit republish under a running client is harmless**
- Requirement: a client that has the toolkit mounted keeps a working `screenshot` across a desktop restart (new inode, old mapping intact).
- Acceptance: run `screenshot` in a loop from a pod across the restart; every invocation after the desktop is back succeeds; none fails with `ETXTBSY`/`Text file busy` on the desktop side (EV-LOG-DESKTOP has `published screenshot`).
- Evidence: the loop's log (EV-LOG-CLIENT); `ls -li` of the published binary before/after; EV-LOG-DESKTOP; EV-PIDS (`restartCount` or `StartedAt` and the app's pid, before and after).
- Tier: T3 · Coverage: ❌.

**S7.8.3 Socket recreation does not invalidate client mounts**
- Requirement: because the CDI mounts are directories, a client's `/tmp/.X11-unix` and `/run/desktop-audio` show the **new** sockets after Xorg or PipeWire recreate them.
- Acceptance: `ls -li` of both dirs from inside a long-running pod before and after the respective restart: inode numbers changed, the pod sees the new ones, and connects.
- Evidence: the two `ls -li` pairs from inside the pod (EV-DIFF); `xdpyinfo`/`pactl info` from the pod after; EV-PIDS (`restartCount` or `StartedAt` and the app's pid, before and after).
- Tier: T3 · Coverage: ❌ evidence not saved; asserted only for the display half, as a side effect: after `operator-e2e:s11_1_1`'s Quit session the long-running `op-observer` client must reach the new X server through its `/tmp/.X11-unix` mount; the audio half is never exercised.

---

## E8 — Hardware-only behaviours (manual acceptance)

Evidence for every story here is captured by a person: EV-PHOTO of the screen,
EV-PHONEVIDEO of the physical action with the screen (and where relevant the
speakers) in frame, plus the same EV-STATE / EV-LOG pairs the automated stories
use, collected with the commands in Appendix C and the hardware table in
`HotpluggingTestHelp.md` §6, and attached to the report with the tester's name
and date. A T4 result without a photo or video is a note,
not evidence.

### F8.1 NVIDIA GPU mode

**S8.1.1 NVIDIA GPU mode**
- Requirement: with the driver and a toolkit that ships `nvidia_drv.so`: real CDI spec, `Driver "nvidia"`, `glxinfo -B` reports NVIDIA, preflight `PASS: NVIDIA GPU injected together with X driver module`; the operator sees an accelerated desktop.
- Evidence: EV-PHOTO; `glxinfo -B`, `head -5 /etc/cdi/nvidia.yaml`, `20-gpu.conf`, preflight block (EV-STATE/EV-CONFIG).
- Tier: T4 · Coverage: 🔧 Appendix C; guided hardware script, not yet written.

**S8.1.2 NVIDIA host with missing/broken toolkit**
- Requirement: stub spec, modesetting desktop comes up, both preflights FAIL on "stub + hardware".
- Evidence: EV-PHOTO of the (working) desktop; both preflight outputs with the FAIL rows; the stub spec.
- Tier: T4 · Coverage: 🔧 guided hardware script, not yet written.

**S8.1.3 NVIDIA host without `nvidia_drm.modeset=1` and no injection**
- Requirement: preflight `FAIL: no /dev/dri/card* visible` with the kernel-cmdline hint.
- Evidence: `cat /proc/cmdline`, `ls /dev/dri`, the preflight row.
- Tier: T4 · Coverage: 🔧 guided hardware script, not yet written.

**S8.1.4 Old toolkit without `nvidia_drv.so`**
- Requirement: preflight `WARN: nvidia_drv.so NOT injected`; the documented bind-mount fallback restores NVIDIA mode.
- Evidence: preflight before/after the drop-in (EV-DIFF); `systemctl cat desktop.service` showing the merged `Volume=` lines; `glxinfo -B` after.
- Tier: T4 · Coverage: 🔧 guided hardware script, not yet written.

### F8.2 Physical KVM switch and monitors

**S8.2.1 Physical KVM: input**
- Requirement: a non-HID-emulating USB KVM switched away and back leaves keyboard and mouse working without a service restart, on the first switch back and on the tenth.
- Evidence: EV-PHONEVIDEO of the switch and of typing afterwards; `ls /dev/input/by-id` before/after (EV-DIFF showing re-enumeration); `xinput list` pair; `podman logs desktop` has no restart in the window (EV-LOG-DESKTOP); the KVM model stated.
- Tier: T4 · Coverage: 🔧 `e2e` "KVM switch simulation: remove the keyboard and bring it back" covers one USB keyboard re-enumeration, with typing working afterwards and no restart; guided hardware script, not yet written.

**S8.2.2 Physical KVM: video, modesetting and NVIDIA**
- Requirement: with a declared layout, `xrandr` geometry and window positions are unchanged across a switch cycle; the panel shows the picture after link retraining.
- Evidence: EV-PHONEVIDEO with the monitor in frame through the whole cycle; `xrandr --query` and `xwininfo -root -tree` before/after (EV-DIFF empty); `cat /sys/class/drm/card*-*/status` during the away period; EV-LOG-XORG connector lines.
- Tier: T4 · Coverage: 🔧 `guest:layout_unplug` forces a connector off under a running X and asserts the declared geometry holds; guided hardware script, not yet written.

**S8.2.3 Real EDID and `desktop-monitors-capture`**
- Requirement: the capture tool prints the real output names and rates; pasting them yields the same arrangement after restart.
- Evidence: the tool's output; `monitors.conf` as installed; `xrandr` before/after the restart (EV-DIFF empty); `cat /sys/class/drm/*/edid | edid-decode` (EV-STATE).
- Tier: T4 · Coverage: 🔧 guided hardware script, not yet written.

### F8.3 Audio hardware and long-run behaviour

**S8.3.1 USB audio devices**
- Requirement: a USB headset/DAC plugged in after boot appears in `wpctl status` and is audible; its microphone records from a client; unplugging returns sound to the speakers; a client application playing throughout is not restarted.
- Evidence: EV-PHONEVIDEO with audible output from the device; `wpctl status` pair (EV-DIFF); EV-AUDIO-REC of speech into the device's microphone from a client pod; the pod's `restartCount` (EV-PIDS).
- Tier: T4 · Coverage: 🔧 `e2e` "audio hotplug: plug and unplug a USB sound card while the desktop runs" covers plug and unplug with QEMU's `usb-audio`; guided hardware script, not yet written.

**S8.3.2 Long-run log bound**
- Requirement: over days of uptime the container log never exceeds ~64 MB.
- Evidence: `ls -l` of the log file daily (EV-STATE table); `podman inspect` LogConfig.
- Tier: T4 · Coverage: 🔧 `smoke` and `guest:verify_log_bounds` assert the 64 MB bound is set on the running container; guided hardware script, not yet written.

---

## E9 — Test-suite quality requirements (cross-cutting)

These govern every test written against the stories in this document (E10
and E11, which follow, included); the suite's own history (see comments in
`ci/`) is the reason each exists.

### F9.1 Assertion discipline

**S9.1.1 Every assertion has been seen to fail**
- Requirement: a new assertion is verified against a deliberate mutation before it is merged.
- Acceptance: the PR description names the mutation.

**S9.1.2 Assert generated output, not source text**
- Requirement: quadlet/CDI/config assertions read the *generated* artefact, anchored so comments cannot match.

**S9.1.3 Read the container's init, never `/proc/1`**
- Requirement: under `--pid=host`, process-level assertions use `/run/desktop-init.pid`.

**S9.1.4 Poll log lines; read live state once**
- Requirement: a log-line assertion is polled; process/socket state may be read directly.

**S9.1.5 No early-exiting reader (`grep -q`, `grep -m`, `head`) on a live pipeline under `pipefail`**
- Requirement: capture output to a variable first.

### F9.2 Fixture and environment discipline

**S9.2.1 Nothing weakens the system under test**
- Requirement: no `setenforce`, no `label=disable`, no `--privileged` on clients, no `-v`/`-e` that duplicates a CDI edit (except `-e` on a `podman exec` into a CDI client, with the value read from that container's PID 1: podman applies a CDI device's env edits only to the process the container starts with), no test-only quadlet changes.

**S9.2.2 Narrow fixtures stay narrow**
- Requirement: `display-only`/`audio-only` request exactly one resource; verifier pods declare nothing but requests.

**S9.2.3 Failures are diagnosable from the job log**
- Requirement: every failure handler tees diagnostics to stdout as well as to an artifact; the failing message is repeated last.

**S9.2.4 Probes default to integers**
- Requirement: counters read over ssh default to `0` on error.

**S9.2.5 Restore what you changed**
- Requirement: a test that writes host config restores the shipped state and *asserts* the restore took effect.

**S9.2.6 Documented procedures are run from the document**
- Requirement: a test of a documented maintainer procedure extracts the block from the document at the run's git sha and runs it unmodified; placeholders are the only substitutions, each listed in the index; a harness step interleaved with the procedure is named there as harness-only. A procedure retyped into the harness tests the harness, and drifts from the document unnoticed.

### F9.3 Evidence discipline

**S9.3.1 Every story emits its named evidence on pass and on fail**
- Requirement: a story's test writes `artifacts/<story>/evidence.md` and the files it names, whichever way the assertion went; a missing evidence file fails the run.
- Acceptance: a post-run check lists every executed story id and every file its `evidence.md` references, and each exists and is non-empty.

**S9.3.2 Before/after pairs are diffed, not eyeballed**
- Requirement: every EV-STATE pair ships with its `diff -u`, and the index states which lines are expected to differ.

**S9.3.3 "No restart" is measured**
- Requirement: a claim that a container or process survived an event carries its container id / `restartCount` / pid before and after.

**S9.3.4 Audio evidence is audible and visible**
- Requirement: every EV-AUDIO/EV-AUDIO-REC is a WAV plus a spectrogram (or, where no spectrogram tool is installed, the harness's level plot at the story's pitch with each event marked) plus the analyser verdict; distinct frequencies per source as listed in the evidence standard.

**S9.3.5 Video covers every dynamic step**
- Requirement: any story whose event changes the screen over time (a restart, a reflow, a display or input hotplug) attaches an EV-VIDEO with the event frames named in the index.

**S9.3.6 The timeline is the spine**
- Requirement: every harness action is appended to `timeline.log` with an ISO timestamp, and every evidence file name appears in the timeline at the moment it was captured.

---

## E10 — Maintainer experience, end to end

E10 is the maintainer's counterpart of E7's client journeys. The maintainer
(see "Roles") provisions a host, verifies it, changes its configuration,
upgrades it, and diagnoses and recovers it, working from `README.md`,
`deploy/README.md` and `deploy/HOST-REQUIRES.md` and nothing else.

E1–E7 prove the parts; E10 proves the maintainer's procedures. Each story runs
a documented sequence of commands as written (Rule 8), on a host in the
starting state the document assumes, and asserts what the document says will
happen, both on the maintainer's terminal and on the operator's screen:
maintenance happens on a machine someone uses to do a job. A documented remedy
must recover the fault it names with no step the document leaves out, and
without a reboot unless the document says one is needed.

Several of these procedures, read side by side with the code, look broken
today. Each such story says so in its coverage note, with the reason. Those
notes are predictions from reading the code, not test results: none has been
run, except where a note says it was.

"Stock host" means a fresh qcow2 overlay over the Rocky 9 GenericCloud image
(`vm-e2e.sh` already builds one per run), booted, with nothing installed
beyond what the story names.
**Common set**: EV-PROCEDURE; EV-TIMELINE; EV-SHOT of the screen before and
after, and EV-VIDEO across any step during which the screen changes;
`desktop-preflight` before and after (EV-STATE pair with EV-DIFF);
`systemctl status 'desktop*'` before and after; EV-LOG-DESKTOP and
EV-LOG-JOURNAL for the step's window; EV-PIDS wherever a restart is, or is
not, supposed to happen.

### F10.1 Provisioning a host from the documentation

**S10.1.1 The documented package line is all a host needs**
- Requirement: on a stock minimal EL9 host with no GPU, installing exactly the "Every host" line of `deploy/HOST-REQUIRES.md`, loading the image and applying the tree (S10.1.2) leaves `desktop-preflight` nothing to report (0 FAILs and 0 WARNs), and the host-side paths the documentation promises work: host Pulse and ALSA clients (S4.2.1, S4.2.2) and Host Terminal (S5.7.2).
- Acceptance: the `dnf install` line extracted from the file and run unmodified; `rsync` (the provisioning tool, not a host requirement) and the probe players are installed separately and listed in the index; `desktop-preflight` exits 0 with no `WARN:` line; host `paplay` and `aplay` tones are heard.
- Evidence: common set; `rpm -qa | sort` before and after (EV-DIFF), so the reviewer sees exactly what was installed; the full preflight output; EV-AUDIO for both host clients.
- Tier: T3 · Coverage: ❌. `guest:phase_deploy` installs its own list (`podman psmisc policycoreutils-python-utils rsync pulseaudio-utils audit`), not the documented line, and asserts only `0 FAIL`. `alsa-plugins-pulseaudio` is not in that list, so a gap in the documented line that costs a WARN would pass unnoticed.

**S10.1.2 The production path is rsync, daemon-reload, reboot, and the desktop is on the screen**
- Requirement: on a stock host with the documented packages and the image loaded, the three commands of `deploy/README.md` "Apply" (`rsync -a --chown=root:root deploy/host/ /`, `systemctl daemon-reload`, `reboot`) are the whole installation. The first boot creates the accounts and directories, converges the seat, writes the specs and labels and starts the desktop, and the operator sees it without anyone logging in to the host.
- Acceptance: no `systemd-sysusers`, `systemd-tmpfiles`, `systemctl start` or `restorecon` by hand; after the reboot, with read-only probes only: `desktop.service` active; `desktop-preflight` 0 FAILs; the screen shows the root colour, the initial xterm and mwm frames (S3.3.3's probes); typed text reaches the xterm (S3.8.1); a pulse tone is heard (S4.1.2); `ssh host whoami` from the container is `desktop-shell` (S5.7.2). The time from power-on to the desktop being visible is recorded.
- Evidence: common set; EV-VIDEO from power-on to the desktop, with the serial log alongside; `journalctl -b -o short-precise -u systemd-sysusers -u systemd-tmpfiles-setup -u 'desktop*'` (EV-LOG-JOURNAL) showing the first-boot order; `id desktop` and `id desktop-shell` (EV-STATE); the time to desktop in the index.
- Tier: T3 · Coverage: ❌. Nothing in the suite reboots: `smoke` and `guest:phase_deploy` run `systemd-sysusers`, `systemd-tmpfiles` and `systemctl start desktop.service` by hand, so no test shows that the first boot of an rsync'd host creates `desktop` and `desktop-shell` before tmpfiles builds their homes and before `desktop-session.service` logs in as `desktop` (S5.1.3, the reboot of a host the live path set up, is untested too).

**S10.1.3 The optional `restorecon` step is optional, and runs clean when taken**
- Requirement: on an enforcing host the desktop and confined clients work whether or not the maintainer runs the "cheap insurance" `restorecon -R …` line in `deploy/README.md` "Apply"; a maintainer who does run it, after `rsync` where the document places it, sees it succeed.
- Acceptance: two stock hosts through S10.1.2, one with the line and one without; on both, S10.1.2's acceptance plus S7.1.1's confined display and audio probes; the line's exit status is 0; `restorecon -R -n -v` over the same paths on the host that skipped it shows where the rsync-applied labels disagree (expected: nowhere).
- Evidence: common set; the `restorecon` transcript with its exit code (EV-PROCEDURE); the `-n -v` output (EV-STATE); `ls -Z` of the installed units, scripts and `/etc/desktop-container` on both hosts (EV-DIFF between them).
- Tier: T3 · Coverage: ❌. No test runs the `restorecon` line; right after `rsync` on a stock host it is predicted to exit nonzero, because it names `/var/lib/desktop-container`, which the tree does not ship and only tmpfiles creates, and it does not pass `-i`.

**S10.1.4 The live-apply paths work as written on a host whose sshd is already running**
- Requirement: both documented live paths, the `README.md` "Install" block and the one-line sequence in `deploy/README.md` "Apply" (with its "if sshd was already running, `systemctl reload sshd`" clause), run verbatim on a stock, never-graphical host whose sshd started before the tree arrived (the stock case), and give S10.1.2's end state without a reboot, Host Terminal included.
- Acceptance: each path on its own stock host, run unmodified; then S10.1.2's acceptance.
- Evidence: common set; EV-LOG-JOURNAL of `sshd` for the container's `ssh host` attempt (accepted, or the failure and its reason).
- Tier: T3 · Coverage: ❌ neither block runs as written and no evidence is saved: `guest:phase_deploy` and `smoke` apply a retyped hybrid (the `README.md` block plus `systemctl reload sshd`, without the `systemctl restart systemd-logind` of the `deploy/README.md` sequence) and then assert `ssh host whoami`. Predicted: the `README.md` block as written leaves Host Terminal broken until sshd reloads or the host reboots, because the `sshd_config.d` drop-in is read only at sshd start.

**S10.1.5 Converting a running graphical host ends in the desktop, or in a named culprit that a reboot clears**
- Requirement: applying the tree live to a host showing a graphical login (a display manager's greeter on tty1, holding DRM master) ends in one of the two states `deploy/README.md` describes. Either the desktop is on the screen with the display manager disabled and stopped, or `desktop-seat-prep` has failed with `ERROR: devices still held after convergence` naming the holder and a plain `reboot` then gives the first state with no further action by the maintainer. A dark screen with no culprit named, or a display manager back after the reboot, fails.
- Acceptance: a VM profile with `gdm` (AppStream) installed and `graphical.target` as default, booted to the greeter (EV-SHOT shows it); `rsync`, then the `deploy/README.md` live sequence verbatim (the document gives that sequence for never-graphical hosts and leaves conversion to `seat-prep.sh`, which runs ahead of the desktop start the sequence ends in); the outcome classified, and if it is the second, `reboot`; afterwards `systemctl get-default` is `multi-user.target`, `systemctl is-enabled gdm` is `disabled`, `fuser -v /dev/dri/card0` names only the desktop's Xorg, and S10.1.2's screen and input checks hold.
- Evidence: common set; EV-VIDEO from the greeter to the desktop, across the reboot if one was taken; EV-LOG-JOURNAL of `desktop-seat-prep` and `systemd-logind`; `fuser -v /dev/dri/card* /dev/tty1` before, between and after (EV-STATE).
- Tier: T3 · Coverage: ❌. `smoke` converges a fake display-manager unit that holds no device (S5.3.1), and `guest:phase_deploy` evicts only a getty; no test starts from a real greeter.

**S10.1.6 A GPU host provisioned from the documentation comes up accelerated on its first boot**
- Requirement: a physical NVIDIA host given both lines of `deploy/HOST-REQUIRES.md` (with the driver stack it describes), the image and S10.1.2's three commands shows an accelerated desktop on its first boot, with S8.1.1's checks passing, both preflights at 0 FAILs, and no step beyond those documents.
- Acceptance: S8.1.1's assertions after S10.1.2's procedure.
- Evidence: every command the tester typed, as typed (EV-PROCEDURE); EV-PHOTO of the desktop; S8.1.1's state set.
- Tier: T4 · Coverage: 🔧 Appendix C; guided hardware script, not yet written.

### F10.2 Verifying a host the way the documentation says to

**S10.2.1 Every documented verification command runs as written and shows what its comment promises**
- Requirement: on a host provisioned per S10.1.2, every line of the `README.md` "Verification checklist (on the target host)" block and of the `deploy/README.md` "Verify" block runs as root without error and prints what its inline comment says it shows. A line that needs a tool the host does not have per `deploy/HOST-REQUIRES.md` is a defect in the checklist, not in the host.
- Acceptance: each line run as written, with one row per line in the index: command, comment, output, exit status, verdict. A line its comment makes conditional ("if declared") is judged on that condition. The host-side audio players (`pw-play`, `paplay`, `aplay`) are client applications the checklist presupposes; they are installed as declared probes.
- Evidence: EV-PROCEDURE of both blocks; the per-line table.
- Tier: T3 · Coverage: ❌. No test runs either checklist; predicted to fail as written: `DISPLAY=:0 xrandr` and `DISPLAY=:0 glxinfo -B` run on a host that `HOST-REQUIRES.md` gives no X client tools, and `podman exec -u desktop desktop wpctl status` passes no `XDG_RUNTIME_DIR`, which neither the image nor the quadlet sets, so it cannot reach PipeWire.

**S10.2.2 Verifying a live host disturbs nothing**
- Requirement: running the two checklists, `desktop-preflight` and `desktop-monitors-capture` on a host whose desktop is in use changes nothing the operator or a client can observe: no process restarts, no configuration changes, no geometry moves, no sound drops.
- Acceptance: across a full S10.2.1 run, the following are unchanged: the pids of desktop-init, Xorg, mwm, the three audio daemons and a running client pod's application, and that pod's `restartCount`; `xrandr --query --verbose` and `xwininfo -root -tree`; `ls -l --time-style=full-iso` of `/etc/cdi`, `/etc/desktop-container` and (in the container) `/etc/X11/xorg.conf.d`. A client tone playing throughout is uninterrupted.
- Evidence: EV-PIDS; the state pairs with their (empty) EV-DIFFs; EV-SHOT before and after; EV-AUDIO spanning the run.
- Tier: T3 · Coverage: ❌. Both tools are documented as read-only; nothing asserts it.

### F10.3 Changing a running host's configuration

**S10.3.1 Declaring the monitor layout the documented way: capture, paste, restart**
- Requirement: starting from an autodetected desktop, the maintainer runs `desktop-monitors-capture`, pastes its output into `/etc/desktop-container/monitors.conf` and runs `systemctl restart desktop.service`, as `deploy/README.md` "Fixed monitor layout" says; the desktop returns with the same arrangement, now pinned.
- Acceptance: the tool's stdout written to the file unmodified; after the restart, `30-monitors.conf` exists in the container and names the captured outputs; per output, the `xrandr --query` geometry equals the captured one (mode names may change to the `cvt(1)` names, as `monitors.conf`'s comments say); preflight prints its fixed-layout PASS line; S3.4.10's live disconnect then holds the geometry.
- Evidence: common set; the captured block and the generated file (EV-CONFIG); `xrandr --query --verbose` before and after (EV-DIFF, with the expected mode-name changes listed in the index); EV-LOG-DESKTOP `xorg-monitor-conf:` and `preflight:` lines.
- Tier: T3 · Coverage: ❌. `guest:layout_declare` starts from the autodetected desktop but writes its layout by hand; `guest:layout_roundtrip` (S3.4.12) runs `desktop-monitors-capture` on that declared layout, writes the block's output lines (its comments dropped) to `monitors.conf` and restarts the desktop, and S3.4.10's disconnect then holds. Nothing captures an autodetected arrangement, pastes the output unmodified, or reads preflight's fixed-layout line.

**S10.3.2 A layout the maintainer gets wrong costs no desktop, and the documented checks say what was wrong**
- Requirement: whatever the maintainer writes in `monitors.conf`, the desktop comes up after the restart, and `podman logs desktop | grep xorg-monitor-conf` or `podman logs desktop | grep preflight:` (both in `deploy/README.md` "Verify") names the problem; every keyword the documentation offers is one the generator accepts.
- Acceptance: one restart per case, with the desktop visible each time (EV-SHOT): (a) a malformed position gives an `ERROR` line with the line number, and autodetected geometry; (b) an output name that matches no connector gives preflight's WARN naming it; (c) each global keyword named in `README.md` "Fixed monitor layout (KVM video)" or in `monitors.conf`'s comments, with a valid value and beside a valid output line, gives the layout applied. T0 part: the keywords the documents name, the keywords `xorg-monitor-conf.sh` accepts and the keywords `preflight-check.sh` skips are the same set.
- Evidence: per case, the file (EV-CONFIG), the two log slices and `xrandr --query`; the three keyword lists (EV-DIFF).
- Tier: T0/T3 · Coverage: ❌. Nothing tests what the maintainer sees (`layout-tests` covers only the generator's rejections, S3.4.7), and no T0 check compares the three keyword lists. They agree now: `README.md` and `preflight-check.sh` still named a `watch` keyword that `xorg-monitor-conf.sh` had dropped with its re-assert loop (it rejected the whole layout, `mode wants WxH[@Hz], got '5'`), and both were corrected.

**S10.3.3 Upgrading and rolling back the desktop image**
- Requirement: the maintainer brings a new desktop image into podman storage, points the unit at it, either by the documented digest pin (`/etc/containers/systemd/desktop.container.d/50-image.conf`, podman ≥ 5.0) or by re-tagging `localhost/desktop-container:latest` (the unit's default), and runs `systemctl restart desktop.service`. The new image runs; the published toolkit becomes the new image's (the "tool versions track the desktop image" claim); the operator gets the desktop back (S10.4.1); running clients behave as S7.8.1 and S7.8.2 require. Pointing back at the previous image and restarting restores it the same way.
- Acceptance: a second image that differs from the first visibly (e.g. another root colour in `xinitrc.desktop`) and in its toolkit binary's sha256; per route, forward then back: `podman inspect desktop --format '{{.Image}}'` is the intended image id; `sha256sum /var/lib/desktop-container/bin/screenshot` equals that image's `/usr/libexec/desktop-tools/screenshot`; the sampled root-colour pixel is the running image's (S3.3.3's probe); `desktop-preflight` reports 0 FAILs, and on the pin route its `quadlet drop-ins present … (podman merges them)` PASS line; the downtime is recorded.
- Evidence: common set; `systemctl cat desktop.service` at each state (EV-CONFIG); the inspect and checksum outputs at each state (EV-STATE); EV-SHOT with the sampled pixel at each state; EV-VIDEO of each restart.
- Tier: T3 · Coverage: ❌. No test upgrades or rolls back the image or checks that the published toolkit follows it; even the drop-in landing in the generated unit (S5.2.6) is untested.

**S10.3.4 A missing image is named by the first-stop tool, and loading it is the whole fix**
- Requirement: when the image the unit names is not in podman storage (never loaded, or a mistyped pin), `desktop-preflight` names it, and loading the image then running `systemctl restart desktop.service` restores the desktop without a reboot.
- Acceptance: on a host with no route to the image's registry (the documents assume provisioning supplies images; the unit sets no `Pull=`, so on a host that can reach the registry podman's default `missing` pull policy would try to fetch it instead): pin an absent digest, or remove the default image with the unit stopped; `systemctl restart desktop.service`; `desktop.service` is not active; `desktop-preflight` exits 1 with `FAIL: image NOT in podman storage: <ref>`; load the image; `systemctl restart desktop.service`; the desktop is visible.
- Evidence: common set; EV-LOG-JOURNAL of `desktop.service` (the error as the maintainer sees it); `systemctl status desktop.service` at each step.
- Tier: T3 · Coverage: ❌ (the preflight row is one line of S5.10.3's table; the journey is untested).

**S10.3.5 Switching Host Terminal off revokes it, on a host where it has already run**
- Requirement: after the documented off-switch (comment out the quadlet's `Wants=`/`After=desktop-host-shell.service` lines, `systemctl daemon-reload`, reboot) on a host where Host Terminal was working, no key authenticates as `desktop-shell`; the menu entry shows its failure text and stays open (S5.7.8); the container's preflight WARNs `no host shell material`; the rest of the desktop is unaffected. This is what `deploy/README.md` promises: "With no key generated, nothing can log into the account".
- Acceptance: before the switch, the container's `ssh host whoami` is `desktop-shell`, and a copy of the then-current private key is kept; apply the switch and reboot; the kept key and the container's `ssh host` are both refused; "Host Terminal" from the menu shows the failure screen (EV-SHOT); neither `/etc/desktop-container/host-shell-key` nor `/etc/ssh/authorized_keys.d/desktop-shell` exists.
- Evidence: common set; both ssh transcripts with exit codes; EV-LOG-JOURNAL of `sshd` showing the refusals; `ls -l /etc/desktop-container /etc/ssh/authorized_keys.d` before and after (EV-DIFF).
- Tier: T3 · Coverage: ❌. No test applies the off-switch; predicted to fail: nothing removes the last boot's key or `authorized_keys.d` entry (the unit has no stop action and tmpfiles does not manage those files), so that key keeps working after the switch and a reboot.

**S10.3.6 Turning Host Terminal on, from its own failure screen**
- Requirement: the failure screen the operator sees when "Host Terminal" fails (S5.7.8) says what to run on the host (`systemctl start desktop-host-shell.service`); the maintainer running exactly that makes the operator's next "Host Terminal" click open a host shell, or the screen names whatever else is needed.
- Acceptance: start from S10.3.5's intended end state (switch applied, its files removed, desktop restarted without host-shell material); click "Host Terminal" and get the failure screen, its text quoted in the index; run the command it shows, verbatim, on the host; click "Host Terminal" again and get a `desktop-shell` prompt.
- Evidence: common set; both EV-SHOTs; `ls -la /home/desktop/.ssh` in the container before and after (EV-STATE); EV-LOG-JOURNAL of `sshd`.
- Tier: T3 · Coverage: ❌. Predicted: the container installs the key and writes `~/.ssh/config` only at container start (`host-shell-setup.sh` is one of `desktop-init`'s boot oneshots), so a key generated afterwards is not used until `desktop.service` restarts, a step the screen does not mention.

**S10.3.7 The documented look-and-feel loops work as written**
- Requirement: each procedure in `README.md` "Look and feel (dark theme)" does what it says: an edit to `/home/desktop/.mwmrc` in the running container takes effect through the root menu's "Restart mwm" with no new X session; an `~/.Xdefaults` edit takes effect after a new X session started the way the README says; a repo-file change, rebuilt offline and deployed with `systemctl restart desktop.service`, is on the screen.
- Acceptance: a root-menu label edit appears after "Restart mwm" (EV-SHOT; Xorg pid unchanged); an xterm background edit appears on the next xterm after the documented session restart (pixel sample); a rebuilt image with another root colour shows it after the service restart (pixel sample).
- Evidence: common set; the edited files (EV-CONFIG); EV-PIDS showing which restarts happened.
- Tier: T3 · Coverage: ❌. No test edits a dotfile or deploys a rebuild (`operator-e2e:menu_restart_mwm` chooses "Restart mwm" without editing `.mwmrc`); the `~/.Xdefaults` loop is expected to fail as written, because the README's `systemctl restart desktop-session.service` "in the container" has no systemd to run it and the host unit of that name does not start a new X session.

### F10.4 Routine operations

**S10.4.1 A maintainer's restart gives the operator the whole desktop back, within a stated time**
- Requirement: `systemctl restart desktop.service`, the step several documented procedures end in, gives the operator the desktop back (root colour, initial xterm, mwm frames), with typing and sound working, within a stated budget; nothing in between offers a login prompt on the screen. Proposed budget: 60 s from the command; confirm it against measured runs before it gates anything.
- Acceptance: EV-VIDEO from the command to the first frame showing the desktop, with the elapsed time in the index; typed text lands (S3.8.1); a pulse tone is heard; every desktop pid changed (a restart that was supposed to happen) and the host session moved with it (S5.8.2).
- Evidence: common set; the time to desktop; EV-AUDIO.
- Tier: T3 · Coverage: ❌ evidence not saved, and nothing checks what the operator gets back or how long it takes: `smoke` asserts the container and host session return (S5.8.2), `guest:layout_declare`, `guest:layout_roundtrip` and `guest:layout_restore` each wait for X to answer after their restart, and `operator-e2e:s11_3_1` waits for the ready marker and mwm after its own restart.

**S10.4.2 A maintenance stop leaves the seat free and the host quiet; a start restores everything**
- Requirement: `systemctl stop desktop.service` stops the desktop and its host login session, leaves no `desktop` process on the host, frees `/dev/dri/card*` and `/dev/tty1`, puts no getty on any VT, and nothing restarts the desktop until the maintainer starts it; `desktop-preflight` describes that state accurately; `systemctl start desktop.service` brings back S10.4.1's outcome.
- Acceptance: after the stop, polled for up to 30 s (logind keeps the user manager for its stop delay): `pgrep -u desktop` on the host is empty; `fuser /dev/dri/card* /dev/tty1` is empty; `systemctl list-units 'getty@tty*' 'autovt@*'` lists nothing; `desktop.service` is still inactive 120 s later; `desktop-preflight` shows `desktop.service not started` (WARN), `no DRM/VT holders` (PASS) and 0 FAILs; a client's connect attempt fails cleanly. After the start: S10.4.1's checks.
- Evidence: common set; EV-PIDS of every uid-61000 host process at each step; EV-SHOT of the screen while stopped.
- Tier: T3 · Coverage: ❌. No test stops `desktop.service` and inspects the host it leaves (the container's own SIGTERM path is S2.5.1, also untested).

### F10.5 Diagnosing and recovering from documented faults

Each story stages one fault from `README.md` "Troubleshooting" on a working
host, then plays the maintainer: the symptom the operator sees at the screen
is captured; the documented first stops are run and kept
(`desktop-preflight`, then
`podman logs desktop | grep -E 'preflight:|postmortem:'`); the entry's own
checks and remedy are run verbatim; recovery is measured at the operator's
screen. A story passes when the documented path names the cause and the
documented remedy recovers it with no step the documentation leaves out. Each
restores the host after itself (S9.2.5).

**S10.5.1 A process holding DRM master: named, removed, recovered without a reboot**
- Requirement: when a host process holds DRM master on the card, the maintainer can name it from the documented first stops, including `desktop-preflight`, which `deploy/README.md` calls the first stop; once it is gone, the desktop recovers by itself, without a reboot or a service restart (`desktop-init` retries the session every 3 s).
- Acceptance: with the desktop stopped, a root process opens `/dev/dri/card0` first and keeps it open (S5.3.3's `sleep` holder); start the desktop; the desktop does not appear; `systemctl status desktop-seat-prep` shows `ERROR: devices still held` naming the pid; `podman logs desktop | grep postmortem:` shows `LIKELY CAUSE: another process holds DRM master`; `desktop-preflight` reports a FAIL naming the holder; `fuser -v /dev/dri/card0` (the README's command) names it; kill it; the desktop appears within one session-restart cycle (the 3 s back-off plus Xorg start-up) with no further command.
- Evidence: common set; EV-VIDEO from the start to recovery; the `fuser -v` output; the three log slices.
- Tier: T3 · Coverage: ❌. Predicted: `desktop-preflight` skips its DRM/VT holder check whenever `desktop.service` is active ("Xorg legitimately holds them"), and a desktop whose X session is crash-looping on this fault is active, so the documented first stop is expected to print no FAIL while the desktop is down.

**S10.5.2 Input devices on another seat: the documented remedy gives typing and clicking back**
- Requirement: when the keyboard and mouse are attached to another seat (`loginctl attach`), the README's "No input devices" entry (its `udevadm info … | grep -i seat` check and `systemctl restart desktop-seat-prep.service`) identifies the cause and restores typing and clicking at the screen, with no step the entry does not list.
- Acceptance: S3.8.6's staging, applied to the session's keyboard and pointer; the symptom captured (typed text does not land); the entry's check, run as written and against the attached nodes, shows the foreign `ID_SEAT`; the remedy run verbatim; typed text and a click land afterwards. Whether Xorg or the desktop restarted is recorded (EV-PIDS); the requirement is that neither had to.
- Evidence: common set; `udevadm info` before and after (EV-DIFF); EV-LOG-XORG device removal and addition lines; EV-SHOT of typed text.
- Tier: T3 · Coverage: ❌ (S3.8.6 restarts the desktop as part of its own procedure, so it cannot show whether the documented remedy alone recovers a running session).

**S10.5.3 A confined client denied by SELinux: the documented checks name the label, the documented restart fixes it, nothing else restarts**
- Requirement: when a client-facing directory loses its `container_file_t` label on an enforcing host, a confined client fails; the README's checks (`systemctl status desktop-selinux`, `ls -Zd …`, `ausearch -m avc -ts recent | audit2why`) show the wrong label and the denial; `systemctl restart desktop-selinux` restores access for a client pod that is already running, without restarting the desktop or the pod.
- Acceptance: a running pod opens the display in a loop (`xdpyinfo` every 2 s, logging each result); the directory and its socket are relabelled to a host type the policy denies to `container_t` (`chcon -R -t tmp_t /tmp/.X11-unix` is the obvious candidate); the loop fails and an AVC is logged; the documented checks run; `systemctl restart desktop-selinux`; the loop succeeds again; the pod's `restartCount` is 0 and the Xorg pid is unchanged.
- Evidence: common set; `ls -Zd /tmp/.X11-unix` and `ls -Z /tmp/.X11-unix/X0` before, during and after (EV-STATE); the `ausearch | audit2why` output; EV-LOG-CLIENT of the loop, with the failure and recovery timestamps.
- Tier: T3 · Coverage: ❌. `guest:phase_deploy` asserts the labels once, after the tree is applied (F5.6); no test loses one and recovers a running client.

**S10.5.4 Device permission errors: found from the documented log lines; the escape hatch works as the README describes it**
- Requirement: when the session user cannot open a device node (its gid out of step with the host's), the README's EACCES entry leads the maintainer to the cause through `podman logs desktop` (the `align-device-groups` and `postmortem:` lines); `systemctl restart desktop.service`, which re-runs the alignment, recovers; and the entry's escape hatch (`needs_root_rights = yes` in `/etc/X11/Xwrapper.config`), applied as the entry describes, gives a running session too.
- Acceptance: with the desktop up, run `groupmod -g <fresh gid> video` inside the container (the misalignment `align-device-groups.sh` exists to prevent), then kill Xorg; the desktop does not come back; the postmortem shows `LIKELY CAUSE: device group permissions`, and the commands it names (`id desktop`, `ls -ln /dev/dri /dev/input`) show the mismatch. Path A: `systemctl restart desktop.service`, and the desktop is visible. Restage. Path B: apply the escape hatch in the running container and kill Xorg; the next session comes up with `ps -o user= -C Xorg` showing `root`. Finally `systemctl restart desktop.service`, asserting that the shipped `Xwrapper.config` and a rootless Xorg are back (S9.2.5).
- Evidence: common set; `ls -ln /dev/dri` on the host and in the container at each step; `getent group video` in the container; the log slices; EV-PIDS.
- Tier: T3 · Coverage: ❌. No test stages the gid mismatch or tries the escape hatch, so nothing shows that a root Xorg starts under this unit's capability set.

### F10.6 Bringing client workloads to a host

The maintainer's side of E7: the documented steps that take a provisioned
host to one that runs client pods, and what kubernetes shows the maintainer
when a node is not ready for them.

**S10.6.1 The README's Kubernetes steps, as written, put the example client on the screen**
- Requirement: on a node provisioned per S10.1.2 with k3s and CRI-O, the steps in `README.md` "Kubernetes (single-node k3s + CRI-O)" and "Kubernetes: a device plugin per capability" (the CRI-O `cdi_spec_dirs` drop-in, the three `helm install` commands, `kubectl describe node | grep -A1 desktop.local/`, `kubectl apply -f examples/x11-client-pod.yaml`) give 10 allocatable of each resource and put the demo xterm ("CDI demo") on the screen, where the operator can click into it and type.
- Acceptance: the blocks run verbatim, `<registry>` the only substitution; the three resources at 10; the xterm visible (EV-SHOT); typed text lands in it (S7.5.2).
- Evidence: common set; the `kubectl describe node` excerpt; `kubectl describe pod x11-client-demo` (its events).
- Tier: T3 · Coverage: ❌ evidence not saved, and the blocks are not run as written: `guest:phase2` adds `--set image.pullPolicy=Never` to each `helm install` (the chart already defaults to `IfNotPresent`), rewrites the example's image to `localhost/desktop-container:latest` with `sed`, and never types into the demo xterm. Whether CRI-O resolves the unqualified `desktop-container:latest` to the `localhost/` image is unverified.

**S10.6.2 A node the desktop has not provisioned is a visible scheduling failure that heals in place**
- Requirement: as `deploy/README.md` promises, a node without the toolkit turns "this node was never set up" into "a scheduling failure an operator can see" (that document's operator is this one's maintainer). A pod requesting `desktop.local/tools` stays `Pending` with an `Insufficient desktop.local/tools` event instead of starting and failing; once the desktop publishes, the same pod object schedules and runs, with no one deleting or recreating it.
- Acceptance: a never-provisioned node, staged: desktop stopped, `/var/lib/desktop-container/bin` emptied, `/etc/cdi/desktop-tools.yaml` removed, and `systemctl stop desktop-tools-cdi.service` (which `deploy/README.md` requires of any teardown, or the `.path` unit stays parked); allocatable `desktop.local/tools` falls to 0 (polled); a pod requesting display and tools, running `"$DESKTOP_TOOLS_BIN"/screenshot`, is `Pending` with the event; `systemctl start desktop.service`; the same pod (same uid) schedules and runs, and its capture succeeds.
- Evidence: common set; the pod's events; allocatable at each step; the pod uid before and after; `ls -l /etc/cdi /var/lib/desktop-container/bin` at each step.
- Tier: T3 · Coverage: ❌ (S7.2.5 asserts the spec is absent before the first start; nothing asserts what kubernetes shows the maintainer).

---

## E11 — Operator experience, end to end

The operator is the person at the display, using the machine to do a job (see
"Roles"). Most of what the operator sees and hears is specified where the
behaviour lives, and those stories are written from the operator's side:

| The operator… | Stories |
|---|---|
| finds the desktop on the screen at power-on, with no login | S3.3.3, S5.1.3, S10.1.2 |
| works in client applications' windows: focus, typing, decoration | S3.6.2, S3.8.1, F7.5 |
| hears applications, and speaks into microphones they record | F4.1, F4.6, F7.6, S8.3.1 |
| keeps working through keyboard, mouse, monitor and headset hotplug and KVM switches | F3.9–F3.11, F4.7, F7.7, F8.2, F8.3 |
| gets the desktop back after the X session, the audio stack or the whole desktop restarts | S2.3.2, S4.5.1, S4.5.2, S7.8.1, S10.4.1 |
| never faces a blanked screen, or a login prompt during maintenance | S3.3.2, S10.4.1, S10.4.2 |

E11 holds what the operator does through the desktop's own controls, which no
other epic owns. The session is mwm alone, with no panel and no desktop
environment (`README.md` "Look and feel (dark theme)"), so the root menu, the
window frames, the key bindings, the X selections and a terminal are the
operator's whole toolset.

How these stories are run (`ci/vm/operator-e2e.py`: in CI the
`vm (operator)` job, which boots its own VM and runs them right after
phase-deploy; in a single-VM run of `ci/vm/vm-e2e.sh`, between the hotplug
checks and phase 2), and what that takes for granted:

- The input is QEMU's: pointer and key events go over QMP to QEMU's own
  devices, never into the X server. Pointer events reach the virtio tablet.
  Key events reach whichever keyboard QEMU activated last: the virtio
  keyboard after boot, which is the CI case, or the USB keyboard `kvmkbd`
  once the KVM-switch simulation has re-added it (QEMU makes a newly added
  USB keyboard the active one), which is the single-VM case. The harness only looks at X, with `xwininfo` and
  `xprop` in an observer container of the lean client image that holds
  `desktop.local/display` and nothing else (the host has no X tools), and
  at QEMU's screendumps. The observer sends no input; its one write is
  S11.2.1's cut-buffer control.
- "A client pod" is a podman client container (F7.1): the desktop image
  holding only `desktop.local/display`, or for S11.3.1's player the lean
  image holding only `desktop.local/audio`. It is the same CDI contract
  and the same SELinux confinement as a pod, without kubernetes, which
  nothing in E11 looks at. A pod's `restartCount` reads as the
  container's `RestartCount`, start time and pid.
- "The desktop's xterm" is the session's own (`xinitrc.desktop`) where a
  story moves, closes or types into it; where a story needs one that
  records its input, it runs in the desktop container as the session user.
- Order matters: S11.1.1's last entry ends the X session and S11.3.1 ends
  by restarting `desktop.service`, so those two run last, in that order.
  The operator-facing F3.3 and F3.5 checks (S3.3.2, S3.3.3, S3.5.2,
  S3.5.3) run first, on the desktop as the session leaves it; the setup
  before them closes the terminals earlier phases left up (phase-deploy's
  among them).

**Common set**: EV-SHOT before and after each action, and EV-VIDEO across any
action with movement; the EV-QEMU transcript of every pointer and key event
sent, because these stories drive the machine only through QEMU's input
devices, as a person would, never by injecting events into the X server;
EV-PIDS for Xorg, mwm and any client application involved; EV-TIMELINE.

### F11.1 Working the desktop

**S11.1.1 Every root-menu action does what its label says when chosen with the mouse**
- Requirement: the operator opens the root menu by pressing a button on the bare root window (left or right, per `.mwmrc`): mwm posts it on the press, with its top-left corner at the pointer, and an entry is chosen by letting go on it. Each action works. "New Terminal" opens an xterm. "Host Terminal" opens an xterm showing a `desktop-shell` prompt on the host (S5.7.2); xterm titles it `host`, but the host shell's prompt retitles it at once (`desktop-shell@<host>:~`), so the title does not identify it. "Refresh" and "Pack Icons" leave every window and process in place ("Pack Icons", with two windows iconified and their icons moved apart, puts the icons back in the places mwm first gave them). "Restart mwm" replaces mwm with no new X session (S3.6.3). "Quit session" ends the session, and the desktop comes back (S2.3.6). Both of those last two ask first: the image's `showFeedback` is mwm's default less `kill` (no dialog on SIGTERM), so each posts a confirmation dialog centred on the screen, OK the default button, and the journey answers it through the dialog.
- Acceptance: per entry: QMP pointer to a point on bare root with room for the menu below and to the right, button press, EV-SHOT of the open menu (its seven rows legible, S3.6.1), pointer to the entry with the button held, release; then the entry's observable; the Xorg pid unchanged except for "Quit session". For "Host Terminal", `whoami` typed into the window answers `desktop-shell` on the host, and sshd logs the key login.
- Evidence: per entry an EV-SHOT pair (menu open, result) and EV-PIDS; EV-VIDEO for "Restart mwm" and "Quit session"; `xwininfo -root -tree` before and after (EV-DIFF).
- Tier: T3 · Coverage: ✅ `operator-e2e:s11_1_1`, one `menu_*` step per entry.

**S11.1.2 Windows can be arranged with the mouse**
- Requirement: the operator arranges windows with the controls mwm draws on every frame and with the `.mwmrc` button bindings, and a client application's window behaves exactly like the desktop's own xterm. Dragging the title bar moves the window; dragging the border resizes it; the minimize button iconifies it, and its icon (double-click, or Restore from the icon's window menu) brings it back where it was; the maximize button enlarges it and a second press restores it; button 3 on a frame posts the window menu (`<Btn3Down> icon|frame f.post_wmenu`), whose Close closes the window; button 1 on a frame raises the window (`<Btn1Down> icon|frame f.raise`). mwm posts the window menu on the button-3 press and takes it down on a release anywhere but an entry, so Close is chosen by dragging to it with the button held. A single click on an icon posts the icon's window menu and leaves it posted (mwm's `iconClick` default). In a normal window's menu Restore is insensitive.
- Acceptance: the desktop's xterm and a client pod's xterm, overlapping; QMP pointer events only; per action, `xwininfo -id` of the window before and after matches the drag, resize, iconify, restore or maximize; `xwininfo -root -tree` shows the stacking change after a raise; on a two-output layout, whether maximize fills one output or the whole screen is recorded; Close ends the client's xterm (its pid exits) and leaves the desktop's xterm untouched. A corner drag puts the frame's corner where the pointer stops, not where in the handle it was grabbed, and xterm's size snaps down to its character grid: a drag ending n columns and m rows of that grid beyond the frame's corner resizes it by exactly n by m. A raised window can bury the other completely, so the order of the actions keeps a stretch of each frame visible.
- Evidence: common set; per action an EV-SHOT pair and the `xwininfo` output before and after (EV-DIFF); EV-VIDEO of the drags.
- Tier: T3 · Coverage: ✅ `operator-e2e:s11_1_2`, both windows taken through every action, now with a shot after the icon-menu Restore too. The e2e VM has one output; maximize gives a `1275x789+5+11` frame on its 1280x800 screen, the character grid keeping it short of the edges.

**S11.1.3 Windows can be managed from the keyboard alone**
- Requirement: an operator whose pointer is gone (a KVM that dropped the mouse) can still manage windows through the `.mwmrc` bindings: `Alt+Tab` and `Alt+Shift+Tab` move keyboard focus between windows, `Shift+Escape` and `Alt+Space` post the window menu, and the window menu's accelerators act on the focused window (`Alt+F9` minimize, `Alt+F4` close). `Alt+Tab` cycles icons as well as windows. A window menu posted from the keyboard appears at the top-left corner of the focused window's client area, or just above a focused icon, and its entries can also be chosen by mnemonic (R for Restore).
- Acceptance: two xterms on screen, one of them from a client pod, and no pointer events after setup; `Alt+Tab` moves focus (the frame colours swap, by S3.5.3's samples, and typed text lands in the newly focused window); `Shift+Escape` shows the window menu (EV-SHOT); `Alt+F9` iconifies the focused window and the window menu's Restore brings it back (`Alt+Tab` to the icon, `Shift+Escape`, R); `Alt+F4` closes the local xterm (its pid exits), and focus can then be moved to the remaining window by keyboard. The local xterm is the session's own: nothing starts another, and the session carries on without a terminal until the operator opens one.
- Evidence: EV-SHOT per step with sampled frame colours; the sink files; the EV-QEMU transcript of the key events; EV-PIDS.
- Tier: T3 · Coverage: ✅ `operator-e2e:s11_1_3`, the last clause included: 5 s after `Alt+F4` no xterm has taken the session's place (the window tree is saved), and Xorg and mwm keep their pids from `pids-start` to `pids-end`. Recorded on the e2e VM: after `Alt+F9`, and again after `Alt+F4`, mwm put the keyboard focus on the remaining window, and one `Alt+Tab` then reached the icon.

### F11.2 Working across applications

**S11.2.1 Text moves between applications by selection and paste, across containers**
- Requirement: text the operator selects in one window can be pasted into another. The applications share one X server whichever containers they run in, so the X selections work between the desktop's own xterm and a client pod's window, and between two client pods' windows, in both directions. That holds for PRIMARY (select, then middle-click; xterm's default) and for CLIPBOARD (xterm with its `selectToClipboard` resource set; the selection toolkit applications use for copy and paste).
- Acceptance: three xterms (the desktop's, pod A's, pod B's), each showing a word of its own and reading its input into a sink file; for each pair, in both directions and for both selections: QMP double-click on the source's word, middle-click in the target, Enter; the target's sink records the word. Before each paste the harness overwrites the root's cut buffer with a decoy word, so a word that arrives can only have come through the selection. Then pod A's xterm exits, and what a paste into pod B yields is recorded: the session runs no clipboard manager, and xterm also writes the X cut buffer, which outlives it.
- Evidence: common set; per pair an EV-SHOT of the selected word and of the pasted text; the sink files (EV-LOG-CLIENT).
- Tier: T3 · Coverage: ✅ `operator-e2e:s11_2_1`, all twelve transfers. Recorded on the e2e VM: with pod A's xterm gone, a paste into pod B gave pod A's word, from the cut buffer (`CUT_BUFFER0`) xterm had written.

### F11.3 Sound under the operator's control

**S11.3.1 The operator can set the volume, mute, and choose the output from the desktop**
- Requirement: the session has no graphical mixer and no volume keys (`.mwmrc` binds none), so the operator's sound controls are commands in a desktop terminal ("New Terminal"), whose environment already carries the session's runtime directory: `wpctl` (the image also carries `pactl` and `alsamixer`). From there, changing the default output's volume, muting and unmuting, and choosing the output device (`wpctl set-default`, for example a headset just plugged in, S4.7.3) take effect on what is already playing, a client pod's stream included, with no restart of anything. What survives an audio-stack restart and a `systemctl restart desktop.service` is recorded: WirePlumber keeps such choices in state files under the session user's home (`/home/desktop`), which does not survive the container being recreated (`README.md` "Look and feel" says the same of the dotfiles), so a reset at that point is expected. Two things the operator should know, seen on the e2e VM: WirePlumber starts an output it has not seen before at 0.40 on wpctl's scale, not 100%; and a USB card plugged in becomes the default output, WirePlumber moving what is playing onto it by itself.
- Acceptance: a client pod plays a continuous 1100 Hz tone; in a "New Terminal" xterm, typed through QMP: with a USB card hot-added (S4.7.1), `wpctl set-default <sink id>` moves the client's stream from the card to the built-in output and back (`pactl list sink-inputs`), with no gap in the capture; then on the card, `wpctl set-volume @DEFAULT_AUDIO_SINK@ 100%` and then `50%` lowers the captured level (by 18 dB on wpctl's cubic scale), and `wpctl set-mute @DEFAULT_AUDIO_SINK@ 1` silences it and `0` restores it; the client pod's `restartCount` and the player's pid are unchanged throughout. Then the volume, mute state and default output are read after killing `pipewire`, and again after restarting the desktop. pactl's sink indexes are not the PipeWire ids wpctl prints, so the stream's sink is compared by name. The volume and mute steps are made on the USB card because QEMU's emulated HDA output does not follow the volume it is set to: on the e2e VM it played the tone 0.8 dB down at WirePlumber's 0.40, at full level at 100% and 2.5 dB down at 50%, while the emulated card followed the cubic scale to within half a decibel. The built-in output's own response is still captured and recorded each run. A gap with no sound device running at all would be missing from the capture rather than silent in it, so the capture's length is checked against the wall clock (EV-AUDIO).
- Evidence: common set; EV-AUDIO across the sequence, with each command's timestamp marked on a level plot of the 1100 Hz tone (the runner has no spectrogram tool); `wpctl status` after each step (EV-STATE); EV-LOG-CLIENT of the player.
- Tier: T3 · Coverage: ✅ `operator-e2e:s11_3_1`, with `wpctl status` and a shot after every command, and the 50% step on the USB card held to -16..-20 dB (measured -18.1 dB). Recorded on the e2e VM: after `pipewire` was killed the card stayed the default at 50%; after `systemctl restart desktop.service` the card was the default again (also WirePlumber's own pick for a present USB card, so this cannot tell whether the choice survived) and its volume was back at 0.40.

---

## Appendix A — Testability prerequisites for the T1 tier and the probes

Several scripts hard-code the paths they read, which is why their branch
coverage sits at ❌. Each needs an environment override (the pattern
`xorg-monitor-conf.sh` already uses) so a `ci/script-unit-tests.sh` can drive
them without root or a container. Defaults must remain the production paths.

| Script | Hard-coded today | Proposed override | Unblocks |
|---|---|---|---|
| `image/xorg/xorg-gpu-conf.sh` | `/dev/dri`, `/dev/nvidia*`, `/sys/class/drm`, lib dirs, output path | `GPU_DEV_DIR`, `GPU_SYS_DRM`, `GPU_LIB_DIRS`, `GPU_OUT` | S3.1.1–S3.1.5 |
| `image/xorg/align-device-groups.sh` | node globs under `/dev` | `DEV_ROOT` prefix | S3.2.2 |
| `image/xorg/ensure-vt-devices.sh` | `/dev` | `DEV_ROOT` | S3.2.3 |
| `image/xorg/preflight-check.sh` | all of the above plus `/run/udev`, the pid file, `/proc/self/mounts`, `/etc/desktop-container` | one `PREFLIGHT_ROOT` prefix, or `podman run` with mounts omitted | S5.11.2 |
| `image/session/session-postmortem` | Xorg log glob | **built**: `POSTMORTEM_XLOG_GLOB` | S2.3.5 |
| `image/session/start-audio` | daemons by name | `PATH` (used: fake daemons) | S2.4.4, S2.4.5 |
| `image/session/host-shell-setup.sh` | `SRC`, `DHOME` | export the existing variables | S5.7.7 |
| `image/session/host-terminal` | `ssh` by name | `PATH` (used: a fake `ssh`) | S5.7.8 |
| `image/tools/publish-tools.sh` | `SRC`, `DEST` | export the existing variables | S7.2.2, S7.2.3 |
| `deploy/host/usr/local/libexec/desktop-host-shell-setup` | `/etc/desktop-container`, `/etc/ssh/authorized_keys.d` | **built**: `DESKTOP_CONTAINER_DIR`, `HOST_SHELL_AK_DIR` | S5.7.5 |
| `deploy/host/usr/local/bin/desktop-monitors-capture` | `podman exec … xrandr --query` | **built**: `DESKTOP_XRANDR_CMD` | S3.4.12 |
| `deploy/host/usr/local/libexec/desktop-selinux` | takes paths as args already | — | S5.6.4–S5.6.6 |
| `deploy/host/usr/local/libexec/desktop-tools-cdi` | `TOOLS_DIR` via `client-cdi.conf` | also honour an env override | S5.5.4 |
| `deploy/host/usr/local/libexec/desktop-cdi-refresh` | `/proc/modules` (the loaded-`nvidia` trigger of the no-downgrade rule) | `CDI_PROC_MODULES` | S5.4.2 (module half) |

Probe tooling the client-side and hotplug stories need, and where it stands:

| Tool | Needed by | Where |
|---|---|---|
| `xinput` | S3.9.2, S3.9.4, S3.9.5, S3.9.8, S3.9.10, S3.9.11, S3.9.12 | `Containerfile.testclient` (CI-only); run as a podman client in phase-deploy or from `x11-testclient` in phase 2 |
| `xwininfo`, `xprop` | S3.3.3, S3.5.2, S3.5.3, S3.6.3, S3.10.*, S7.5.*, S7.7.3, S10.2.2, S11.1.1–S11.1.3, S11.2.1 | **shipped**: `Containerfile.testclient` carries both, and the operator phase runs them in its observer container; on a T4 host, built and loaded there too (Appendix C) |
| `ffmpeg` or imagemagick `convert` for gif | EV-VIDEO | **shipped**: imagemagick is on the `ci.yml` `vm` job's apt line and makes the gifs; ffmpeg is not installed |
| `sox` or `ffmpeg` | spectrograms for EV-AUDIO | not installed; the operator phase draws a level plot at the story's pitch instead (EV-AUDIO) |
| `inotify-tools` | S7.2.3 | the `build-smoke` runner (apt), S7.2.3 being T2 |
| `alsa-utils` + `alsa-plugins-pulseaudio` | S4.2.2 | VM guest |
| `pipewire-utils`, `pulseaudio-utils`, `alsa-utils` as declared host probes | S10.1.1, S10.2.1 | VM guest, installed after the documented package line, so S10.1.1 can tell the two apart |
| `gdm` (AppStream) | S10.1.5 | a second VM profile, booted to `graphical.target` before the tree is applied |
| `edid-decode` | S8.2.3 | T4 host |

The `script-unit` step of `ci.yml` `static` covers S1.1.3, S2.3.5, S2.4.4,
S2.4.5, S3.4.12, S5.7.5 and S5.7.8 so far. S3.1.x need the `xorg-gpu-conf.sh`
overrides above; S5.7.7, S3.2.2 and S3.2.3 need root or a scratch container of
the image, since they install files as the session user or create groups and
device nodes.

## Appendix B — Suggested new VM e2e phases

| New phase | Stories |
|---|---|
| `verify-session-tree` | S2.3.1, S2.3.3 (host-process half), S2.3.4, S2.3.6 (mwm killed; Quit session is the operator phase's), S2.4.2 (wireplumber / pipewire-pulse), S2.4.7, S3.2.4, S3.2.5 |
| `verify-shutdown` | S2.5.1 |
| `verify-host-audio-clients` | S4.2.1, S4.2.2 |
| `verify-host-shell-hardening` | S5.7.3, S5.7.4 |
| `verify-selinux-policy` | S5.6.2 (full context), S5.6.3, S5.6.4, S5.6.5, S5.6.6 |
| `verify-seat-gate` | S5.3.3, S3.8.6 |
| `verify-isolation-negatives` | S6.1.3, S6.1.5 (submounts), S6.2.1, S6.2.3 |
| `verify-fixed-layout` (extend) | S3.4.10 (window tree + video), S3.4.11, S3.4.12 |
| `verify-hotplug-input` (new; pointers, per-device proof, Xorg plug-out) | S3.9.2, S3.9.4, S3.9.5, S3.9.7–S3.9.12 |
| `verify-hotplug-monitor` (new; DRM force on + firmware EDID) | S3.10.3–S3.10.7 |
| `verify-hotplug-audio` (extend) | S4.7.3, S4.7.5 (default sink), S4.7.7, S4.7.8, S4.7.9, S4.7.11 |
| `verify-kvm-composite` (new) | S3.11.1, S3.11.2 |
| `verify-client-journeys` (new; display + audio journeys) | S7.5.1–S7.5.5, S7.6.3–S7.6.5, S7.6.6 (record) |
| `verify-client-hotplug-continuity` (new; the "no restart" proofs) | S7.7.1–S7.7.8 |
| `verify-client-lifecycle` (new) | S7.8.1–S7.8.3, S7.3.6 (running client through uninstall) |
| reboot sub-phase after `phase-deploy` | S5.1.3, S5.5.5 (reboot half) |
| second VM profile booted without `intel-hda` | S2.4.6 / S4.7.10 / S7.7.9 |
| `verify-maintainer-provisioning` (new; a fresh overlay per variant, procedures from the documents, reboots) | S10.1.1–S10.1.4 |
| VM profile with `gdm`, booted to `graphical.target` | S10.1.5 |
| `verify-maintainer-checklists` (new) | S10.2.1, S10.2.2 |
| `verify-maintainer-day2` (new) | S10.3.1–S10.3.7 |
| `verify-maintainer-routine` (new) | S10.4.1, S10.4.2 |
| `verify-maintainer-troubleshooting` (new; one documented fault per story, staged and restored) | S10.5.1–S10.5.4 |
| `verify-maintainer-onboarding` (extend phase 2; the README's steps verbatim) | S10.6.1, S10.6.2 |
| operator phase (**exists**: `ci/vm/operator-e2e.py`, between the hotplug checks and phase 2; QMP pointer and key events only) | S3.3.2, S3.3.3, S3.5.2, S3.5.3, S11.1.1–S11.1.3, S11.2.1, S11.3.1; with them S2.3.6 (Quit session), S3.6.1 (menu), S3.6.3, S5.7.2 (menu-launched shell) |

## Appendix C — Hardware acceptance checklist (T4)

Run on a provisioned physical host after each image or tree release. For each
row record the command output **and** the photo/video named in the story.

The host has no X client tools (`deploy/HOST-REQUIRES.md`), so X queries run
inside the desktop image, which carries `xrandr`, `xdpyinfo` and `glxinfo`
(`xq` below). `xinput` and `xwininfo` are in neither the image nor the host:
the lines using them need the Appendix A probe image
(`Containerfile.testclient`, which carries `xwininfo` and `xprop`; `xinput`
is still to be added), built and loaded onto the T4 host first (`probe`
below).

```sh
xq()    { podman exec -u desktop -e DISPLAY=:0 desktop "$@"; }
probe() { podman run --rm --device desktop.local/display=all localhost/desktop-testclient "$@"; }

# S10.1.6 — GPU host from the documents: record every command typed, from the
# HOST-REQUIRES.md lines through the deploy/README.md "Apply" block; then S8.1.x

# S8.1.x — GPU mode
desktop-preflight
podman logs desktop | grep -E 'preflight:|xorg-gpu-conf: decision'
podman exec desktop cat /etc/X11/xorg.conf.d/20-gpu.conf
head -5 /etc/cdi/nvidia.yaml
xq glxinfo -B | grep -E 'OpenGL (vendor|renderer)'
systemctl cat desktop.service | grep -E '^Image=|nvidia_drv'
# photo of the desktop

# S8.2.1 — KVM input: film the switch; then
ls -l /dev/input/by-id; podman exec desktop ls /dev/input
probe xinput list
# type into a CLIENT xterm; it must respond without `systemctl restart desktop.service`

# S8.2.2 / S8.2.3 — KVM video: film the monitor through the whole cycle
desktop-monitors-capture            # paste into monitors.conf, restart, then:
xq xrandr --query; probe xwininfo -root -tree      # before
# switch away, wait, switch back
xq xrandr --query; probe xwininfo -root -tree      # must be identical
podman logs desktop | grep xorg-monitor-conf
for e in /sys/class/drm/card*-*/edid; do [ "$(wc -c <"$e")" -gt 0 ] && { echo "== $e"; edid-decode "$e"; }; done

# S8.3.1 — USB audio: film with sound; a client pod playing throughout
podman exec desktop ls /dev/snd     # before and after plugging the device
podman exec -u desktop -e XDG_RUNTIME_DIR=/run/user/61000 desktop wpctl status
kubectl get pod <player> -o jsonpath='{.status.containerStatuses[0].restartCount}'
# record speech from the device's microphone in a client pod; attach the WAV

# S8.3.2 — log bound (daily)
ls -l /var/lib/containers/storage/overlay-containers/*/userdata/ctr.log*
```

## Appendix D — Coverage summary

Counts are of stories in E1–E7, E10 and E11 (E8 is all 🔧, E9 is cross-cutting). A story
with a mixed mark is counted under its weakest mark; a story whose only mark
is 🔧 is counted in that column. Since the evidence standard was added, a
story whose assertion exists but whose named evidence is not yet captured
(e.g. "✅ captures; ❌ spectrograms") counts as ❌: an unreviewable pass is a
gap by this document's definition. The coverage lines were re-checked against
the code story by story on 2026-10-05 and now follow this rule; the counts
before that review were 69 ✅, 42 🟡, 136 ❌ and 4 🔧. Since then each story
moves to ✅ only when a CI run has saved its evidence, which the
`coverage-gate` job then keeps true.

| Epic | Stories | ✅ | 🟡 | ❌ | 🔧 |
|---|---|---|---|---|---|
| E1 Image build | 14 | 12 | 0 | 2 | 0 |
| E2 Boot & supervision | 25 | 17 | 1 | 7 | 0 |
| E3 Display & session | 62 | 37 | 1 | 21 | 3 |
| E4 Audio | 23 | 11 | 0 | 11 | 1 |
| E5 Deploy tree | 50 | 25 | 1 | 23 | 1 |
| E6 Privileges | 9 | 3 | 0 | 6 | 0 |
| E7 Client contract & journeys | 40 | 11 | 1 | 28 | 0 |
| E10 Maintainer experience | 23 | 0 | 0 | 22 | 1 |
| E11 Operator experience | 5 | 5 | 0 | 0 | 0 |
| **Total** | **251** | **121** | **4** | **120** | **6** |

Regenerate after editing with:

```sh
for e in 1 2 3 4 5 6 7 10 11; do
  printf 'E%s ' "$e"
  awk -v e="$e" '/^## /{on=($0 ~ "^## E"e" ")} on && /^\*\*S/{n++} on && /^\*\*S/{s=$0} on && /Coverage:/{ if($0~/❌/)x++; else if($0~/🟡/)p++; else if($0~/✅/)c++ } END{printf "stories=%d ok=%d partial=%d gap=%d hw=%d\n", n, c, p, x, n-c-p-x}' Requirements.md
done
```

## Appendix E — Evidence capture helpers

The evidence standard needs a handful of harness functions, written once and
reused by every story. Each story's directory is written in one format
(`ci/evlib.py`'s docstring; "Report layout" above) by one of two writers.

**Built:**

| Helper | Where | Does |
|---|---|---|
| `ev_begin <story> <title> [tier]` / `ev_end [reason]` / `ev_abort <reason>` | `ci/evidence.sh`, any shell tier | opens `artifacts/<story>/` and its `meta.tsv`; settles PASS/FAIL and renders `evidence.md`; `ev_abort` is what `fail()` calls, so a red story is still written |
| `ev_check <claim> <cmd…>` / `ev_pass` / `ev_fail` | `ci/evidence.sh` | one line in `checks.tsv` per assertion, in order |
| `ev_note <text>` | `ci/evidence.sh` | observed and recorded, deliberately not asserted (`notes.tsv`) |
| `ev_save <moment> <what> <cmd…>` | `ci/evidence.sh` | runs the command and keeps the command line, its output (stderr included) and its exit status as the next numbered file (EV-STATE, EV-LOG-*); `$EV_LAST` names the file for a later `ev_diff` |
| `ev_text`, `ev_copy`, `ev_diff`, `ev_attach` | `ci/evidence.sh` | text already in hand, a copied file (EV-CONFIG), `diff -u` of two kept files (EV-DIFF), a file already written |
| `EV_SIDE=h-` | `ci/evidence.sh` | a VM story written from the guest and the host at once; the host's files carry an `h` prefix |
| `StoryWriter` | `ci/evlib.py` | the same, from Python; the operator phase's `Story` builds on it and adds `qemu.log`, its QMP transcript |
| `Ctx.shot`, `Ctx.video`, `Ctx.pids`, `Ctx.diff`, `Ctx.save_cmd`, `Ctx.diagnostics` | `ci/vm/operator-e2e.py` | EV-SHOT, EV-VIDEO (frames, index, gif), EV-PIDS, EV-DIFF with both sides kept, command output, and the failure shot, tree, process table and desktop log |
| `ev_shot <moment> <what>` | `ci/vm/vm-e2e.sh` (host) | QEMU screendump into the open story |
| `guest_ev <root\|""> <phase…>`, `ev_pull` | `ci/vm/vm-e2e.sh` (host) | runs a `vm-guest.sh` phase with evidence on and copies the guest's story directories back |
| `ev_audio_start <moment> <hz>` / `ev_audio_stop <what> <secs> <peak> <hz>`, `ev_audio_check` | `ci/vm/vm-e2e.sh` (host) | `wavcapture` straight into the open story; on stop the WAV is indexed and `check-audio.py --report --plot` keeps its verdict and a level plot at the story's pitch beside it |
| `QMP_TRANSCRIPT=<file>` | `ci/vm/qmp-type.py` | writes every QMP command it sends, timestamped (EV-QEMU) |
| `write_manifest` | `ci/vm/vm-e2e.sh` (host) | `run.json`: image ids, QEMU, guest kernel and podman versions, git sha, date |
| `evlib.py render` / `check` / `gate` | `ci/evlib.py`; `gate` runs in `ci.yml` `coverage-gate` | renders `evidence.md`; checks every story directory is complete (S9.3.1's acceptance); holds the ✅ marks in this document to the run's evidence |

**Still to build** (the stories that name them stay ❌ until they exist):

| Helper | Side | Does |
|---|---|---|
| `ev_video_start <fps>` / `ev_video_stop` | host | the shell phases' EV-VIDEO: a background screendump loop; on stop the gif and the frame list |
| `ev_pids <moment> [pod…]` | guest | the shell phases' EV-PIDS table, plus any pods' `restartCount`/container id |
| `ev_desktop_log` | guest | `podman logs desktop` from the story's start marker |
| `ev_client_log <pod\|ctr>` | guest | `kubectl logs` / `podman logs` plus any sink file |
| `ev_qemu <moment>` | host | `info usb`, `info pci`, `info qtree` into the story |
| `ev_procedure <doc> <heading> [n]` | host extracts, guest runs | copies the n-th fenced block under `<heading>` in `<doc>`, at the run's git sha, into `procedure.sh`; runs it one command at a time as the maintainer would (a root shell on the guest); writes `procedure-transcript.txt` with each command's output and exit status (EV-PROCEDURE). Placeholders come from a declared map that the index lists |
| `ev_fresh_host [profile]` | host | a new qcow2 overlay on the stock cloud image, booted, so a provisioning story starts from a host nothing has touched; `profile` selects variants such as the `gdm` image for S10.1.5 |
| `ev_time_to_desktop <mark>` | host | from a timeline mark, polls until the display shows the desktop by S3.3.3's probes (root-colour pixel, an xterm in the window tree); writes the elapsed seconds to the index |

Audio frequency registry (keep in `freq_for` in `vm-e2e.sh` and `gen_tone` in
`vm-guest.sh`):

| Hz | Used by |
|---|---|
| 440 | pulse path (desktop and pods) |
| 880 | PipeWire-native path |
| 1320 | ALSA path |
| 660 | record-direction loopback |
| 990 | playback through a hot-added device (S4.7.3, S7.7.6) |
| 1100 | client continuity across restarts and hotplug (S7.6.3, S7.7.4, S7.7.5, S7.7.8); the operator's sound controls (S11.3.1) |
