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
| **T3 VM e2e** | Rocky 9 KVM guest, virtio GPU/input/HDA, **SELinux enforcing**, k3s + CRI-O | real Xorg on a real KMS device, hotplug via QEMU, confined clients, a capturable display and audio backend | `ci.yml` `images` → `vm` (shards `core`, `operator`, `k8s`, `soundless`, each its own VM) → `ci/vm/vm-e2e.sh` + `ci/vm/vm-guest.sh` + `ci/vm/operator-e2e.py`; the maintainer's journeys (E10) in `maintainer.yml`, a stock VM each → `ci/vm/maint-e2e.sh` + `ci/vm/maint-guest.sh` |
| **T4 hardware** | a provisioned physical host | NVIDIA, physical KVM switch, real monitors/EDID, USB audio, a person | `ci/hw/acceptance.sh` (Appendix C): a guided script that prompts the tester for each physical action, asks for what only a person can see or hear and for the photos and videos, and gathers the rest of the evidence itself, in CI's layout; not yet run on hardware |

A story's tier is the *lowest* tier that can prove it honestly. Pushing a
story down a tier (e.g. from T3 to T1) is a valid improvement if the proof
stays real.

## Coverage legend

| Mark | Meaning |
|---|---|
| ✅ | asserted by an existing test, **and every evidence item the story names is saved in the run's uploaded artifacts** (its own `artifacts/<story>/`, or another story's directory, which the line names); the reference names the function or step |
| 🟡 | the named evidence is saved, but the assertion is partial or only a side effect of another test; the gap is named |
| ❌ | no test, or some named evidence is not saved (when a test does assert the story, the line says which); the acceptance column is the spec for the one to write |
| 🔧 | needs real hardware or a person: `ci/hw/acceptance.sh` (Appendix C) runs the story at a provisioned host and saves its evidence there; no hardware run's evidence has been reviewed yet |

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
- Tier: T2 · Coverage: ✅ (workflow `base-rebuild.yml`) `ci/base-rebuild.sh` runs the rebuild and keeps its evidence, and the workflow uploads it as `evidence-base-rebuild` whether the builds pass or not. The three bases build from current upstream (`--pull --no-cache`) and the three application layers build offline (`--network=none`) on them, a check and the build's log for each. `rpm -qa` of the desktop base GHCR held before the run (its `:latest`, pulled first) and of the fresh base are kept, with their diff: the week's package drift. The bases are pushed only after a successful rebuild, by every scheduled run and by a dispatched one whose `push` input is on. Under `S1.1.2/` (artifact `evidence-base-rebuild` of a `base-rebuild.yml` run).

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
- Tier: T0/T2 · Coverage: ✅ `static`'s "every shipped script is shellchecked (S1.2.6's list)" step: `ci/script-list.py` finds every shell script git tracks under `image/` and `deploy/host/usr/local/` by its `#!` line (22 of them) and the scripts the "shellcheck (error severity)" step names there, its globs expanded; the two lists' diff is empty. Its self-test takes a listed script out of the step and must name it. Both lists, their diff and the self-test are under `artifacts/S1.2.6/` (artifact `evidence-static`); the shellcheck step itself passes in the same job. `smoke` runs `find /usr/local/bin /etc/X11/xinit/xinitrc.desktop -type f ! -perm 0755` in a scratch container of the image: empty, the twelve files under `/usr/local/bin` and `xinitrc.desktop` all `755 root:root`, under `artifacts/S1.2.6/` (artifact `evidence-smoke`).

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
- Acceptance: with the desktop stopped, move the tree's unit file aside, as on a host without it, and `daemon-reload` (`systemctl mask` is refused: the unit file is the tree's own, at `/etc/systemd/system/desktop-session.service`, the path mask's `/dev/null` link would take); start the desktop; the fallback line is logged; the dir is desktop-init's (0700, desktop, no mount); audio sockets export; the X session starts (T3). Put the unit file back and restart afterwards. (`disable` is not enough: the quadlet's `Wants=desktop-session.service` starts the unit again whenever `desktop.service` starts.)
- Evidence: EV-LOG-DESKTOP (fallback line); `stat` of the dir (EV-STATE); EV-SHOT of the desktop up (T3); EV-AUDIO of a tone (T3).
- Tier: T2/T3 · Coverage: ✅ `guest:standalone_desktop`, in the core shard, moves the unit file aside with the desktop stopped, and logind takes `/run/user/61000` away. desktop-init then logs `no host login session appeared; creating /run/user/61000 standalone` and makes the dir itself: `0700 desktop:desktop`, no mount. The audio export answers (`pactl info` over it from the host: `PulseAudio (on PipeWire 1.4.11)`), X answers and the session's mwm runs. The VM host shoots the screen and hears a pulse client in the session play 440 Hz (1.97 s, peak 0.547). The unit file then goes back as the tree ships it, and the runtime dir is logind's again. Under `artifacts/S2.2.2/` (artifact `evidence-vm-core`): the log, the dir in the container and on the host, the export, the screendump, the recording with check-audio.py's verdict and level plot, and the restored state. `smoke`'s scratch container, with no host login session at all, shows the same fallback and dir, under `artifacts/S2.2.2/` (artifact `evidence-smoke`).

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
- Tier: T3 · Coverage: ✅ `guest:verify_runtime`: Xorg is in the process session `startx` leads, with tty1 as its controlling tty, and the leader's environment is exactly `run_session`'s ten variables plus the `PWD` and `SHLVL` bash adds, with no container variable. `artifacts/S2.3.1/` (artifact `evidence-vm-core`) holds the session's processes with their session ids and ttys (`ps -s`) and the leader's environment.

**S2.3.2 The session restarts after Xorg exits, and the operator gets the desktop back**
- Requirement: when the session exits, desktop-init logs `session exited (rc=N); restarting in 3s`, a new session starts, and within ~45 s the operator sees the desktop again (root colour, initial xterm, mwm frames).
- Acceptance: kill Xorg as uid desktop; new Xorg and mwm pids; display answers.
- Evidence: EV-VIDEO of the display through the restart (blank → desktop back); EV-PIDS before/after (Xorg and mwm changed, desktop-init unchanged); EV-LOG-DESKTOP.
- Tier: T3 · Coverage: ✅ `guest:verify_session_restart` kills Xorg as the desktop user, the console moved to tty2 first: within 45 s a new Xorg and mwm are up under the same desktop-init and the display answers, and desktop-init has logged the session's exit and its restart in 3 s; `e2e` records the display from before the kill until the desktop is back. `artifacts/S2.3.2/` (artifact `evidence-vm-core`) holds desktop-init, Xorg and mwm before and after with the diff, the desktop's log from the kill on, and the video.

**S2.3.3 Session cleanup is scoped by session id and session tag, never by uid**
- Requirement: after a session exits, every pid in that session id, and every desktop-user process whose environment carries that run's `DESKTOP_SESSION_TAG`, is TERMed then KILLed after 5 s; same-uid processes outside it (the audio tree, the host's `desktop-session-lead`, any other uid-61000 process on the host, processes started by `podman exec`) are untouched. The session id is the one `startx`, `xinit` and Xorg share; xinit starts the X client in a session of its own, which mwm leads (and each xterm's shell leads another), and the tag is what reaches those and whatever was started from them. A process that starts itself with a scrubbed environment escapes the tag, and so the cleanup unless it is in the server's session.
- Acceptance: start a `sleep` carrying the session's `DESKTOP_SESSION_TAG` (`podman exec -e`, as a process started from the session's xterm inherits it), a `podman exec` `sleep` without it, and a uid-61000 `sleep` on the host; kill Xorg; within 6 s no process carries the old leader's session id or the old tag; the old mwm, xterm and tagged `sleep` are gone; PipeWire pid unchanged; host `desktop-session-lead` pid unchanged; the untagged `sleep` and the host's survive.
- Evidence: EV-PIDS before/after listing every uid-61000 process on the **host**, the index marking which must persist.
- Tier: T3 · Coverage: ✅ `guest:verify_session_restart`: before the kill a `sleep` carrying the session's tag, a `podman exec` `sleep` without it and a uid-61000 `sleep` on the host are started; within 6 s of the kill no process of the old session id or with the old tag is left, the old mwm and the tagged `sleep` among them, while the untagged `sleep`, the host's, PipeWire and `desktop-session-lead` keep their pids. `artifacts/S2.3.3/` (artifact `evidence-vm-core`) holds what each probe must do, every uid-61000 process on the host before and after with its session id, and the diff (the old session, its xterm and the tagged `sleep` gone, the rest unchanged).

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
- Tier: T3 · Coverage: ✅ `guest:verify_mwm_exit`, in the core shard, sends mwm SIGTERM (`kill`'s default) as the session user. desktop-init logs `session exited (rc=0); restarting in 3s` and runs no postmortem; Xorg and mwm are new (40291 → 58054, 40301 → 58064) under the same desktop-init, and the display answers 4.5 s after the signal. The VM host records the display throughout. Under `artifacts/S2.3.6/` (artifact `evidence-vm-core`): the pids before and after with their diff, the desktop log from the SIGTERM on, the video (its index.txt timed against the guest's notes) and the new session's screendump. `smoke` asserts the same at T2, under `artifacts/S2.3.6/` (artifact `evidence-smoke`). "Quit session" is asserted with its video, pid tables and desktop log by `operator-e2e:menu_quit_session` in `artifacts/S11.1.1/`.

### F2.4 Audio supervision

**S2.4.1 The audio tree is its own session with its own supervisor**
- Requirement: `start-audio` runs via `setsid` (no controlling tty) as uid 61000 under `supervise_audio`; the leader pid is in `/run/desktop-audio-leader.pid`.
- Acceptance: PipeWire's sid equals the recorded leader pid; `ps -o tty= -p <pipewire>` is `?`.
- Evidence: EV-PIDS with sid/tty; the leader pid file (EV-STATE).
- Tier: T2 · Coverage: ✅ `smoke` saves the leader pid file, the audio tree's process table (`ps -s <leader>`: pid, ppid, session, tty, user) and the leader's parent chain, and checks pipewire is in the leader's session with no tty (`?`) as uid 61000, the leader's parent a child of desktop-init, under `artifacts/S2.4.1/` (artifact `evidence-smoke`).

**S2.4.2 Any daemon exiting restarts the whole stack**
- Requirement: `start-audio` returns on the *first* of the three exiting, logs which, TERMs the survivors, and a complete new set starts after 3 s.
- Acceptance: kill pipewire, then wireplumber, then pipewire-pulse, each alone → each time three new pids, `<name> exited` and the restart logged, the export reachable.
- Evidence: EV-PIDS before/after for the three daemons; EV-LOG-DESKTOP with the `<name> exited` and `restarting in 3s` lines; EV-AUDIO of a tone after recovery.
- Tier: T3 · Coverage: ✅ `guest:verify_audio_restarts` kills pipewire, wireplumber and pipewire-pulse in turn, each alone, as the desktop user: each time start-audio logs `<name> exited`, desktop-init logs the stack's restart in 3 s, all three daemons come back with new pids, and the export answers; `e2e` then hears a pulse client's 440 Hz tone through the restarted stack. `artifacts/S2.4.2/` (artifact `evidence-vm-core`) holds the daemons before and after each kill with the diffs, the desktop's log from each kill on, and the capture with its verdict and level plot.

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
- Tier: T3 · Coverage: ✅ `guest:soundless`, in the soundless shard: a second VM booted without `intel-hda`, so with no sound card, its `audio` group renumbered to 1063 before the tree is applied (the image's is 63). The audio supervisor's pass before the first audio start logs `audio: no device nodes present, skipping`, and PipeWire lists no card. The VM host hot-adds `usb-audio`, the VM's first card: its control node is on gid 1063, and the container sees it through the live bind mount, its own `audio` group still 63. pipewire is killed. Before the new start the supervisor's pass logs `audio: gid 63 -> 1063 (from /dev/snd/controlC0)`; the container's `audio` group then equals the host node's gid, WirePlumber lists the card, and a 770 Hz tone the session user plays through it is heard. Under `artifacts/S2.4.6/` (artifact `evidence-vm-soundless`): `/dev/snd` and the `audio` group on the host and in the container before and after, every align line from the container's start on, `podman logs` across the realignment, `wpctl status` before and after, QEMU's `device_add`, and the tone with its verdict. Recorded: with the card plugged in and the stack not yet restarted, PipeWire already listed it, the container's gid 63 against the node's 1063. The nodes carry logind's uaccess ACL for the desktop user (`user:desktop:rw-`, kept in `07-acl.txt`), and the container's desktop user is the same uid. logind gives that ACL to the active session's user, so while desktop-session holds seat0 the nodes are open to the desktop user without the alignment; the alignment is what opens them to a desktop without that session (S5.8.4's standalone desktop). See also S4.7.10, S7.7.9.

**S2.4.7 Export sockets are connectable by other uids**
- Requirement: `umask 0000` makes the exported sockets world-connectable.
- Acceptance: as the unprivileged `rocky` user on the VM host, `pactl info` succeeds and `paplay` of a tone is heard.
- Evidence: `ls -l /run/desktop-audio` (EV-STATE); `id` of the probe user; EV-AUDIO.
- Tier: T3 · Coverage: ✅ `guest:play_as_rocky`: as the unprivileged `rocky` user on the VM host, `pactl info` answers over the export, and `paplay` of an 880 Hz tone is heard at the machine's output. `artifacts/S2.4.7/` (artifact `evidence-vm-core`) holds rocky's `id`, `ls -l /run/desktop-audio`, the `pactl info` and `paplay` transcript, and the capture with its verdict and level plot.

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
- Acceptance: on a real NVIDIA host (T4). Proving the NVIDIA paths with fabricated device nodes and a fake module was considered and rejected: the hardware-only stories are proven on hardware, by the guided hardware script (`ci/hw/acceptance.sh`).
- Evidence: the generated file (EV-CONFIG); the script's evidence lines (EV-LOG-DESKTOP); `glxinfo -B` (EV-STATE) and EV-PHOTO of the desktop.
- Tier: T4 · Coverage: 🔧 `ci/hw/acceptance.sh run S3.1.1` (Appendix C), not yet run on hardware. One run with S8.1.1, on an NVIDIA host whose toolkit injects the X driver: `20-gpu.conf` from the desktop, which must say `Driver "nvidia"` with a `ModulePath` naming the module directory of `xorg-gpu-conf.sh`'s decision line; that script's evidence lines and decision; `glxinfo -B` reporting NVIDIA; S8.1.1's EV-PHOTO of the desktop.

**S3.1.2 NVIDIA nodes without the X driver fall back to modesetting**
- Requirement: nodes present, no `nvidia_drv.so` → both `warning:` lines and the modesetting branch.
- Acceptance: on a real NVIDIA host with an old toolkit (T4), for the reason S3.1.1 gives.
- Evidence: EV-CONFIG + EV-LOG-DESKTOP warnings; EV-PHOTO.
- Tier: T4 · Coverage: 🔧 `ci/hw/acceptance.sh run S3.1.2` (Appendix C), not yet run on hardware. One run with S8.1.4, on an NVIDIA host. A toolkit that does not inject `nvidia_drv.so` is taken as installed; one that does is made into an older one, if the tester agrees: a copy of the spec without the X driver's mounts, with `nvidia-ctk` set aside so nothing regenerates it, both undone at the end. After `systemctl restart desktop.service`: `20-gpu.conf` takes the modesetting branch, `xorg-gpu-conf.sh` logs both `warning:` lines, the tester confirms an unaccelerated desktop on the monitor, and an EV-PHOTO of it.

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
- Tier: T1/T3 · Coverage: ✅ the T1 half: `build-smoke`'s "align-device-groups' branches (S3.2.2's T1 half)" step (`ci/align-groups-tests.sh`) runs `align-device-groups.sh` as root in a scratch container of the image per branch, a plain file with the wanted group standing in for each node (the script reads only whether a node exists and its group). Renumber: video 39 becomes the node's 2001, the desktop user in it. Collision: the group squatting on the target gid moves to 60001, the first free gid from 60000 (60000 taken), and render takes 2002. Missing group: input is created with the node's gid. A root-group node and an absent node are skipped with their log lines, the gids unchanged. Already aligned: nothing moves, and the final table names all four groups with their devices' gids and ends with `id desktop`. The narrow form renumbers audio alone, the table its one row. An unknown group is named and changes nothing. Per branch under `artifacts/S3.2.2/` (artifact `evidence-smoke`): the setup, the transcript, `getent group` before and after, and their diff. ✅ the T3 half: `guest:session_groups`, in the core shard. Every group in align-device-groups' final-state table carries the gid of the host node it names: video 39 (`/dev/dri/card0`), render 105 (`/dev/dri/renderD128`), input 104 (`/dev/input/event0`), audio 63 (`/dev/snd/controlC0`). The table ends with `id desktop`, and the container preflight passes `desktop user can read` for `/dev/dri/card0`, `/dev/input/event0` and `/dev/snd/controlC0`. Under `artifacts/S3.2.2/` (artifact `evidence-vm-core`): the align lines, the preflight lines, `ls -ln` of the nodes on the host and in the container, and `getent group` with `id desktop`.

**S3.2.3 VT nodes are created when the runtime does not expose them**
- Requirement: `ensure-vt-devices.sh` creates `/dev/tty0` (c 4:0) and `/dev/tty1` (c 4:1), mode 620, `root:tty` (desktop-init then hands `tty1` to the session user), no-op when present.
- Acceptance: `stat -c '%F %t:%T %a' /dev/tty1` in the container is `character special file 4:1 620`; log says `created /dev/tty1` once.
- Evidence: the `stat` (EV-STATE); EV-LOG-DESKTOP line.
- Tier: T2 · Coverage: ✅ `smoke` saves ensure-vt-devices' lines this boot (`created /dev/tty0 (c 4:0)` and `created /dev/tty1 (c 4:1)`, once each: the runner's runtime exposes neither) and `stat` of both nodes in the container (character special, 4:0 and 4:1, 620; tty1 handed to `desktop:tty`), under `artifacts/S3.2.3/` (artifact `evidence-smoke`).

**S3.2.4 Xorg does not listen on TCP**
- Requirement: `-nolisten tcp`; nothing listens on 6000+ on the host network.
- Acceptance: `ss -ltn` on the VM host shows no 6000-range listener.
- Evidence: `ss -ltnp` (EV-STATE); `ps -o args= -C Xorg` showing `-nolisten tcp`.
- Tier: T3 · Coverage: ✅ `guest:verify_runtime`: Xorg's command line carries `-nolisten tcp`, and `ss -ltnp` on the VM host, whose network the container shares, lists no listener on TCP 6000–6063. `artifacts/S3.2.4/` (artifact `evidence-vm-core`) holds `ss -ltnp` and Xorg's command line.

**S3.2.5 The session activates its VT, so the operator sees it**
- Requirement: Xorg `VT_ACTIVATE`s tty1 at start; the desktop is visible even if the console was on another VT.
- Acceptance: the active VT (`/sys/class/tty/tty0/active`, what `fgconsole` reports) is tty1 after boot; switch the console to tty2, kill Xorg; after the restart the active VT is tty1 and the display shows the desktop.
- Evidence: the active VT before, after the switch and after the restart (EV-STATE); EV-SHOT after restart showing the desktop, not a text console.
- Tier: T3 · Coverage: ✅ `guest:verify_session_restart`: the active VT is tty1, the console is switched to tty2 before Xorg is killed, and the new session takes it back to tty1 by itself; `e2e` then shoots the display, the desktop on tty1. `artifacts/S3.2.5/` (artifact `evidence-vm-core`) holds the active VT before, after the switch and after the restart, and the screenshot.

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
- Tier: T3 · Coverage: ✅ `guest:verify_runtime`: `xhost` as the session user lists `LOCAL:`, and a confined client of uid 4321 with no passwd entry, no cookie and no `XAUTHORITY`, given only `desktop.local/display=all`, opens `:0` with `xdpyinfo`. `artifacts/S3.3.1/` (artifact `evidence-vm-core`) holds the `xhost` output and the client's run.

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
- Tier: T0/T4 · Coverage: ✅ the T0 half: `layout-tests` "nvidia" saves both cases' input, generated file and log under `artifacts/S3.4.5/` (artifact `evidence-static`) and checks one `MetaModes` carrying the whole layout, `ModeValidation AllowNonEdidModes`, `ConnectedMonitor` and `CustomEDID` only when asked for, the pinned `Virtual`, and no `Monitor` sections or invented timings. 🔧 the KVM-switch half: `ci/hw/acceptance.sh run S3.4.5` (Appendix C), not yet run on hardware. S8.2.2's cycle, on a desktop whose `20-gpu.conf` says `Driver "nvidia"` (the story stops otherwise), with S8.2.3's layout declared: `20-gpu.conf` and `monitors.conf`; `xrandr --query` and `xwininfo -root -tree` before and after the switch away and back, each pair's diff required empty; the connectors' status every 2 s through the cycle; the Xorg log's lines from it; the tester confirms the picture came back unchanged; EV-PHONEVIDEO of the cycle.

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
- Tier: T2/T3 · Coverage: ✅ `smoke` declares DP-1 and DP-2 on a runner that has neither: the preflight WARNs about both (`fixed monitor layout names output(s) DP-1 DP-2 with no matching DRM connector (Virtual-1 )`), under `artifacts/S3.4.11/` (artifact `evidence-smoke`) with the runner's `ls /sys/class/drm`. `guest:layout_declare` declares Virtual-1 and Virtual-2 in the VM: the preflight PASSes both (`fixed monitor layout declares Virtual-1 Virtual-2, all present as DRM connectors`), under `artifacts/S3.4.11/` (artifact `evidence-vm-core`) with the VM's `ls /sys/class/drm`.

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
- Tier: T3 · Coverage: ✅ `e2e` keeps `assert_nonblank`'s measurement of the deploy screendump (mwm's root and the deploy-proof xterm) and checks it against twice the render test's 0.02: 0.0510978 ≥ 0.04. The screendump and the measurement are under `artifacts/S3.5.4/` (artifact `evidence-vm-core`).

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
- Tier: T2/T3 · Coverage: ✅ the success path: `operator-e2e:menu_host_terminal`, under `artifacts/S11.1.1/` (artifact `evidence-vm-operator`): the window showing `whoami` and its answer, and sshd's journal. ✅ the failure path: `operator-e2e:s5_7_8` (S5.7.8's T3 half) opens the entry with the host refusing the key; the window keeps the reason, the enablement command and `Press Enter to close.` until Enter, under `artifacts/S5.7.8/` (artifact `evidence-vm-operator`).

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
- Tier: T3 · Coverage: ✅ `guest:verify_runtime`: `/run/udev` is mounted `ro` in the container's own mount table and holds the host's database (`/run/udev/data` is not empty), the preflight logs `PASS: host udev database mounted at /run/udev`, and no udevd on the host is in the container's mount namespace. `artifacts/S3.8.5/` (artifact `evidence-vm-core`) holds the mount line, the database's entry count, the preflight's lines, and every udevd with its mount namespace beside desktop-init's.

**S3.8.6 Foreign seat tags are detected and undone**
- Requirement: a device attached to another seat is reported by preflight as a WARN until `seat-prep` removes the rule and re-triggers udev.
- Acceptance: `loginctl attach seat1 <device>`; `udevadm info` shows `ID_SEAT=seat1`; with the desktop running, `desktop-preflight` FAILs naming the rule and the container's preflight, run in the running desktop, WARNs; restart the desktop: seat-prep, which runs before every desktop start, removes the rule and re-triggers udev, and no entry in the udev database is tagged for another seat, the device's children (a keyboard's LEDs) included; the preflight at that start prints `PASS: no foreign seat tags`.
- Evidence: `udevadm info` before/after (EV-DIFF); `ls /etc/udev/rules.d/72-seat-*` before/after; both preflights while the tag is in place; EV-LOG-JOURNAL of `desktop-seat-prep` at the restart; EV-LOG-DESKTOP preflight line; the keyboard still types afterwards (EV-SHOT).
- Tier: T3 · Coverage: ✅ `guest:seat_tags`, in the core shard. `loginctl attach seat1` puts the USB keyboard (kvmkbd) on seat1 (`/dev/input/event4` reads `ID_SEAT=seat1`). With the desktop running, `desktop-preflight` FAILs naming the `72-seat-*` rule, and the container's preflight, run in the running desktop, WARNs about the foreign tag. The desktop restarted: seat-prep, which runs before every desktop start since `claude/fix-oneshots-every-start`, logs the rule's removal; the rule is gone, no udev database entry is tagged for another seat, and the preflight at that start PASSes the seat check. Before that fix, seat-prep ran once per boot and this story restarted it by hand with the desktop stopped. The keyboard types again: the VM host types `seatok` into a sink xterm through QEMU's keyboard, the sink's shell reads exactly that, and `xinput test` on the USB keyboard's own X device sees the key presses. Under `artifacts/S3.8.6/` (artifact `evidence-vm-core`): the rules directory and `udevadm info` before and after with their diff, the rule loginctl wrote, every foreign-tagged udev entry after the attach and after seat-prep, both preflights with the tag in place, seat-prep's journal at the restart, the preflight line after it, `xinput list`, the QMP transcript, the screendump, the xinput test and the sink's file.

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
- Acceptance: the keyboard re-added with `display=<virtio-vga id>` (the e2e must give `-device virtio-vga` an `id=`), then `input-send-event` with `"device"` set to that virtio-vga id; the sink xterm records the text (or `xinput test <id>` shows the events). QMP's `device` names a display device, not an input device. The e2e's QEMU (8.2.2) does not refuse an event that names the keyboard: it aborts, its console lookup reaching a text console that has no `device` property (`Property 'qemu-fixed-text-console.device' not found`), so the e2e names only the display.
- Evidence: EV-QEMU transcript showing the `device` field; sink file (EV-LOG-CLIENT); EV-SHOT of the text on screen; `xinput test` output (EV-STATE).
- Tier: T3 · Coverage: ✅ `e2e` "input routing" re-adds the USB keyboard bound to the virtio-vga's console (`device_add usb-kbd,id=kvmkbd,bus=xhci.0,display=vga0`) and types `boundkey` through `qmp-type.py`, every key event naming `device` vga0, head 0: the sink xterm reads `boundkey`, and `xinput test` on the re-added keyboard's own X device sees all nine key presses. `artifacts/S3.9.5/` (artifact `evidence-vm-core`) holds the QMP transcript, the screendump, the sink file and the `xinput test` output.

**S3.9.6 The session accepts input after a keyboard cycle**
- Requirement: a remove/re-add cycle does not wedge the X session or its input stack.
- Acceptance: click + type after the cycle lands in the sink xterm.
- Evidence: EV-SHOT; EV-PIDS (Xorg pid unchanged across the cycle); EV-VIDEO of the cycle.
- Tier: T3 · Coverage: ✅ `e2e` "KVM switch simulation": after the remove/re-add cycle the sink xterm reads `kvmok` typed through QEMU, and Xorg keeps its pid; the cycle on video (2 fps frames with their times, and a gif), the screendump after the typing, the QMP transcript, the sink file and Xorg's and mwm's pid tables before and after, under `artifacts/S3.9.6/` (artifact `evidence-vm-core`).

**S3.9.7 Pointer plug-in reaches the container**
- Requirement: a mouse or tablet added while the desktop runs appears as a new `event*` node inside the container.
- Acceptance: node count rises after `device_add usb-mouse` (relative) and `device_add usb-tablet` (absolute).
- Evidence: common set.
- Tier: T3 · Coverage: ✅ `e2e` "pointer hotplug": `device_add usb-mouse` (relative) and `usb-tablet` (absolute) each add an event node on the VM host and in the container, the pointers' own nodes among the container's. `artifacts/S3.9.7/` (artifact `evidence-vm-core`) holds F3.9's common set before and after with the diffs, QEMU's replies and the Xorg log from just before.

**S3.9.8 Pointer plug-in is adopted by Xorg**
- Requirement: the device appears in `xinput list` as a pointer.
- Acceptance: as stated, for a relative and an absolute device.
- Evidence: common set.
- Tier: T3 · Coverage: ✅ `e2e` "pointer hotplug": `xinput list` gains `QEMU QEMU USB Mouse` and `QEMU QEMU USB Tablet`, each a slave pointer, and Xorg's two adding lines for each are quoted from its log. In `artifacts/S3.9.8/` (artifact `evidence-vm-core`).

**S3.9.9 Pointer plug-out removes the node from the container**
- Requirement and acceptance: as S3.9.3, for the pointer.
- Evidence: common set.
- Tier: T3 · Coverage: ✅ `e2e` "pointer hotplug": after `device_del hotmouse` and `hottablet` the VM host loses both nodes and the pointers' own nodes are gone from the container, its count back to the baseline. `artifacts/S3.9.9/` (artifact `evidence-vm-core`) holds F3.9's common set plugged in and after, with the diffs and QEMU's replies.

**S3.9.10 Pointer plug-out is seen by Xorg**
- Requirement and acceptance: as S3.9.4, for the pointer.
- Evidence: common set.
- Tier: T3 · Coverage: ✅ `e2e` "pointer hotplug": both pointers leave `xinput list`, and Xorg's log records `config/udev: removing device` for each. In `artifacts/S3.9.10/` (artifact `evidence-vm-core`).

**S3.9.11 A hot-added pointer delivers motion and buttons**
- Requirement: events through the hot-added device move the pointer and click; the operator sees the cursor move and a window take focus.
- Acceptance: the events reach the hot-added device (a `usb-tablet` added with `display=<virtio-vga id>` and sent with that `device`; a `usb-mouse`, which has no `display` property, selected with HMP `mouse_set` and shown current by `query-mice`); `xinput test <id>` shows its motion/button events; a click on the sink xterm through the hot-added tablet focuses it and typed text lands.
- Evidence: EV-VIDEO (cursor crossing the screen, window frame turning the focused colour); `xinput test` output; sink file; EV-QEMU.
- Tier: T3 · Coverage: ✅ `operator-e2e:s3_9_11`: a `usb-tablet` added with `display=vga0` is listed by Xorg; driven alone (its events naming `vga0`), it carries the pointer across the screen and clicks the sink xterm. Its own X device sees the motion and the click (`xinput test`), the focus moves from the session's xterm to the sink (the frames `#41637f` and `#22262d`), and the line typed next lands in the sink. A `usb-mouse` added beside it, made QEMU's current mouse with `mouse_set` (`query-mice` before and after), moves the pointer by relative motion and clicks inside the session's xterm, and its own X device sees both. `artifacts/S3.9.11/` (artifact `evidence-vm-operator`) holds F3.9's common set before and with the tablet, each device's `xinput test`, `query-mice` before and after `mouse_set`, a video of each pointer's motion and click, the screen after the tablet's click, and the sink file.

**S3.9.12 Repeated input cycles leave no residue**
- Requirement: ≥ 5 remove/re-add cycles return node counts and `xinput list` to baseline.
- Acceptance: counts equal baseline after the last cycle; the session still accepts input.
- Evidence: per-cycle counter table (EV-STATE); `xinput list` baseline vs final (EV-DIFF empty); EV-PIDS Xorg unchanged.
- Tier: T3 · Coverage: ✅ `operator-e2e:s3_9_12`: five remove/re-add cycles of the USB keyboard. Each removal takes it out of `xinput` and its nodes off the host and out of the container, and each return brings the counts back to the baseline (host 8, container 8, one USB keyboard in `xinput`). After the fifth, `xinput` lists the same device names as before the first, Xorg has kept its pid, and a sink xterm still takes a typed line. `artifacts/S3.9.12/` (artifact `evidence-vm-operator`) holds F3.9's common set at the baseline and after the fifth cycle, the counter table (a row per removal and per return), `xinput`'s names before and after with their diff (empty), the sink file and the screen with the typed line.

### F3.10 HMI hotplug: monitors

Under `-display none` no QMP or HMP command enables a second virtio-gpu
scanout. QEMU itself enables or disables a head, with an EDID of the requested
size, when a display frontend reports a size for it: the e2e binds a VNC server
to head 1 (`-vnc unix:…,display=vga0,head=1`), and `ci/vm/vnc-head.py` sends it
RFB SetDesktopSize (0x0 takes the monitor away). virtio-gpu then raises a
display event, and the guest reads every head's EDID and geometry again. That
is how a monitor is plugged in here (S3.10.5, S3.10.7). Plug-outs, and the
plug-in under a declared layout (S3.10.4), go through the DRM connector-force
interface; a connector forced on gets virtio-gpu's own mode list and no EDID,
even with an EDID override or `drm.edid_firmware` set, because virtio-gpu
reads an EDID only at boot and on a display event. `HotpluggingTestHelp.md`
§4.3 has the mechanics. The user-facing
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
- Tier: T3 · Coverage: ✅ `guest:layout_unplug`: with the layout declared, Virtual-2 forced `on` reads `connected 1024x768+1024+0`, the screen stays 2048x768 with Virtual-1 at `1024x768+0+0`, and no client window moves or resizes (the window-tree diff is empty); set back to `detect`, Virtual-2 reads disconnected again at the same place. `artifacts/S3.10.4/` (artifact `evidence-vm-core`) holds sysfs, `xrandr --verbose` and the window tree at each step, with the diffs and the Xorg log.

**S3.10.5 Monitor plug-in without a layout is detected and does not reflow**
- Requirement: under autodetection a connector coming up is `connected` in `xrandr`; screen size and existing geometry unchanged (no auto-enable).
- Acceptance: as stated.
- Evidence: common set.
- Tier: T3 · Coverage: ✅ `guest:ad_plugin`, with the host's `vnc-head.py`: QEMU plugs a 1024x768 monitor into Virtual-2 (SetDesktopSize answered `request forwarded`). Under autodetection Virtual-2 reads connected in sysfs and in `xrandr` and is not enabled; the screen stays 1280x800, Virtual-1 stays at `1280x800+0+0`, and no client window moves or resizes. Taken away (0x0), Virtual-2 reads disconnected and unused again. `artifacts/S3.10.5/` (artifact `evidence-vm-core`) holds F3.10's common set before, plugged in and after (sysfs, `xrandr --verbose`, the window tree), the `xrandr` and tree diffs (the tree's empty), the Xorg log since the plug-in, QEMU's answers to the plug and unplug, and a video of head 0 across both.

**S3.10.6 Monitor plug-out without a layout is characterised**
- Requirement: under autodetection, forcing the only enabled connector down must not crash or restart X; the result is recorded.
- Acceptance: Xorg pid unchanged; `xdpyinfo` answers; `xrandr` captured.
- Evidence: common set + EV-PIDS.
- Tier: T3 · Coverage: ✅ `guest:ad_unplug`: under autodetection Virtual-1, the only enabled output, is forced off. Xorg keeps its pid and `xdpyinfo` answers. What X reports is recorded: `Virtual-1 disconnected primary 1280x800+0+0`, the screen still 1280x800. Set back to `detect`, Virtual-1 reads connected and the screen is 1280x800; desktop-init, Xorg and mwm kept their pids and start times. `artifacts/S3.10.6/` (artifact `evidence-vm-core`) holds the pids before and after with their diff (empty), F3.10's common set before, forced off and after the re-detect with the diffs, the Xorg log across it, and a video of head 0.

**S3.10.7 A plugged-in monitor with an EDID exposes modes**
- Requirement: with an EDID injected for `Virtual-2` (its debugfs `edid_override`), a monitor QEMU plugs in there carries that EDID: the kernel and X both list exactly its modes; `xrandr --output Virtual-2 --auto` enables it without disturbing `Virtual-1`.
- Acceptance: the EDID (1024x768@60 preferred, 640x480@60 and 800x600@60 established, no continuous-frequency flag) written to the override; QEMU plugs a 1024x768 monitor into Virtual-2 (`vnc-head.py`); the kernel's sysfs `edid` equals the injected bytes and its `modes` are exactly the three, `xrandr`'s plain query lists exactly the three for Virtual-2 and X's EDID property is the injected EDID; `--auto` enables Virtual-2 at 1024x768 with Virtual-1 unmoved; QEMU's head 1 shows the scanout; off, unplugged, and the override reset with `printf reset` (exactly five bytes: with echo's newline the kernel reads the write as an EDID and refuses it). The connector force cannot carry this story: forced on, virtio-gpu gives its own mode list and no EDID, override or not.
- Evidence: common set; `cat /sys/class/drm/card*-Virtual-2/edid | od -An -tx1 | head` (EV-STATE); EV-SHOT after enabling.
- Tier: T3 · Coverage: ✅ `guest:ad_edid`, with the host's `vnc-head.py`: the kernel takes the EDID as Virtual-2's override; forced on, Virtual-2 still has no EDID and virtio-gpu's own 24 mode sizes (recorded). QEMU plugs the monitor in, and the kernel gives Virtual-2 the injected EDID byte for byte (128 bytes) and offers exactly its modes, `640x480,800x600,1024x768`. `xrandr` lists exactly those for Virtual-2, and X's EDID property is the injected EDID. After its last output `xrandr` also lists the modes no output offers, here `1280x800 (0x44)`, which Virtual-1 still runs; `--verbose` prints those as it prints an output's own, so the modes are read from the plain query. `xrandr --output Virtual-2 --auto` enables it at `1024x768+0+0` with Virtual-1 at `1280x800+0+0` and the screen 1280x800, and QEMU's head 1 shows the scanout (1024x768, not blank). Turned off and taken away, Virtual-2 reads disconnected and unused, Virtual-1 where it was. `artifacts/S3.10.7/` (artifact `evidence-vm-core`) holds the injection route, the EDID injected and as the kernel reports it, the kernel's modes, F3.10's common set before, plugged in, enabled and after, the plain query, the Xorg log, the `xrandr` and tree diffs (the tree's empty), QEMU's answers, head 1's screendump and a video of head 0.

**S3.10.8 Physical monitor plug-out and plug-in**
- Requirement: S8.2.2 and S8.2.3.
- Evidence: EV-PHONEVIDEO of the cable/KVM action with the screen in frame; `xrandr` before/after (EV-DIFF); EV-PHOTO of the desktop after.
- Tier: T4 · Coverage: 🔧 `ci/hw/acceptance.sh run S3.10.8` (Appendix C), not yet run on hardware: S8.2.2's cycle, its action a video cable pulled out of one declared monitor for 30 s (`HW_AWAY`) and put back, with the same checks and EV-PHONEVIDEO, then an EV-PHOTO of the desktop after. Needs S8.2.3's layout installed.

### F3.11 HMI hotplug: KVM switch composite

**S3.11.1 Keyboard, pointer and sound card leave and return together**
- Requirement: a KVM switch disconnects every USB device at once; the desktop survives all three leaving in the same instant and all three returning; the operator types, clicks and hears audio afterwards.
- Acceptance: `device_del` of the USB keyboard, tablet and sound card back to back; all node counts drop; re-add all three; all counts return; typed text lands, the hot-added tablet clicks, and a tone sent to the built-in sink **by name** is captured (WirePlumber makes a returning USB card the default, so an untargeted tone would prove the USB card); Xorg pid and PipeWire pid unchanged.
- Evidence: EV-VIDEO of the whole cycle; EV-TIMELINE; the three counter tables; EV-PIDS; EV-AUDIO after; EV-SHOT of typed text.
- Tier: T3 · Coverage: ✅ `operator-e2e:s3_11_1`: with the KVM's tablet and sound card plugged in beside its keyboard and the built-in card's sink the default, the three are deleted back to back. Every count drops (input and sound nodes on the host and in the container, PipeWire's devices, the keyboard and tablet in `xinput`), and every count returns when the three are added back; Xorg and PipeWire keep their pids. The returned tablet clicks a sink xterm (its own X device sees the press), the line typed next comes through the returned keyboard (13 key presses on its own device) and lands there, and a client's 660 Hz tone sent to the built-in sink by name is heard, its `paplay` exiting 0. `artifacts/S3.11.1/` (artifact `evidence-vm-operator`) holds F3.9's and F4.7's common sets before and away, the three counter tables in one, the desktop's processes before and after, a video of the cycle, each returned device's `xinput test`, the sink file, the screen with the typed line, and the tone's capture with the player's exit status, verdict and level plot.

**S3.11.2 Composite cycle with the video link down at the same time**
- Requirement: S3.11.1 with `Virtual-1` forced down during the away period and `detect`ed on return, layout declared; geometry and windows hold throughout.
- Acceptance: S3.11.1's assertions plus dims `2048x768` and an unchanged window tree at every step.
- Evidence: S3.11.1's set plus the F3.10 common set.
- Tier: T3 · Coverage: ✅ `operator-e2e:s3_11_2`, last in the operator shard, under the declared two-monitor layout (2048x768): S3.11.1's cycle with Virtual-1 forced off while the devices are away and set back to `detect` as they return. Every count drops and returns. While away the screen stays 2048x768 and Virtual-1 reads disconnected at `1024x768+0+0`; after the return it reads connected there, and no window moves or resizes at either step. Xorg and PipeWire keep their pids, the returned tablet clicks, the returned keyboard types into the sink it clicked, and the tone sent to the built-in sink by name is heard. `artifacts/S3.11.2/` (artifact `evidence-vm-operator`) holds S3.11.1's set plus F3.10's (sysfs and `xrandr --verbose` before, away and after) and the window tree at each step.

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
- Acceptance: on the VM host **without** `PULSE_SERVER` set, `paplay tone.wav` plays and is captured, and a stub `/usr/bin/pulseaudio` that logs every start shows none. EL9's libpulse does not autospawn unless its client configuration asks it to, so the stub alone could not fail: in a private mount namespace, with the export hidden and `/etc/pulse/client.conf` saying `autospawn = yes`, a client with the drop-in starts no stub, and the control, the drop-in hidden, does.
- Evidence: EV-AUDIO; `env | grep PULSE` (empty) and `pgrep pulseaudio` (empty) (EV-STATE); the drop-in (EV-CONFIG).
- Tier: T3 · Coverage: ✅ `guest:host_audio`, in the core shard. rocky, with a clean environment and no `PULSE_` variable, plays a 440 Hz tone with `paplay` (exit 0), and the VM host hears it (3.08 s, peak 0.547); the stub `/usr/bin/pulseaudio` records no start, and no pulseaudio runs. In a private mount namespace, the export hidden under an empty tmpfs and `client.conf` saying `autospawn = yes`, rocky's `pactl info` with the drop-in tries only `unix:/run/desktop-audio/pulse` and starts nothing; the control, the drop-in hidden, runs the stub (`/usr/bin/pulseaudio --start`). Under `artifacts/S4.2.1/` (artifact `evidence-vm-core`): the namespace transcript, the probe (the drop-in, `env | grep PULSE`, `pgrep -a pulse`), and the recording with check-audio.py's verdict and level plot.

**S4.2.2 Host ALSA clients are routed through the pulse plugin**
- Requirement: the ALSA drop-in routes `pcm.!default`/`ctl.!default` to the pulse socket.
- Acceptance: on the VM host (with `alsa-utils` + `alsa-plugins-pulseaudio`), the deploy tree's drop-in loads last in `/etc/alsa/conf.d`, after the package's own `99-pulseaudio-default.conf`, whose server-less `pcm.!default` would otherwise win; `aplay tone.wav`, with libpulse given no default server of its own, plays and is captured at 1320 Hz; `amixer` lists the pulse control; the control, the same aplay with the drop-in hidden, is refused.
- Evidence: EV-AUDIO; `amixer` output (EV-STATE); the drop-in (EV-CONFIG).
- Tier: T3 · Coverage: ✅ `guest:host_audio`, in the core shard. `/etc/alsa/conf.d` in load order ends with `99-zz-desktop-container.conf`. rocky's `aplay` through ALSA's default, with an empty client config (no default server), exits 0 and the VM host hears 1320 Hz (3.23 s, peak 0.547); `amixer info` names `'pulse'/'PulseAudio'`. With the drop-in hidden (`/dev/null` bound over it in a private mount namespace) the same aplay is refused (`PulseAudio: Unable to connect: Connection refused`). Under `artifacts/S4.2.2/` (artifact `evidence-vm-core`): the packages, `/etc/alsa/conf.d` with each file, the control, the probe, and the recording with its verdict and level plot.

**S4.2.3 A host-local `asound.conf` still wins**
- Requirement: the drop-in loads before `/etc/asound.conf`, so a host override is honoured.
- Acceptance: with an `/etc/asound.conf` routing default to `null`, `aplay -D default` produces no capture; remove it.
- Evidence: EV-AUDIO (silence, analyser fails as expected); the override file.
- Tier: T3 · Coverage: ✅ `guest:host_audio`, in the core shard. With an `/etc/asound.conf` routing default to `null`, rocky's `aplay -D default` of 1320 Hz exits 0 and the VM host hears nothing (peak 0.000; check-audio.py fails, as expected). With the file removed, the same aplay is heard at 1320 Hz (3.20 s, peak 0.547). Under `artifacts/S4.2.3/` (artifact `evidence-vm-core`): the override file, both probes, both recordings with their verdicts and level plots, and `/etc/asound.conf`'s absence afterwards.

### F4.3 Realtime

**S4.3.1 Rlimits reach PipeWire by inheritance**
- Requirement: `RLIMIT_RTPRIO` hard = 95, memlock 64 MiB, nice 31 on the PipeWire process itself.
- Acceptance: `/proc/<pipewire>/limits`.
- Evidence: the limits file (EV-STATE).
- Tier: T3 · Coverage: ✅ `guest:verify_privileges` reads `/proc/<pipewire>/limits`: realtime priority 95, locked memory 64 MiB (67108864 bytes) and nice 31, each soft and hard. `artifacts/S4.3.1/` (artifact `evidence-vm-core`) holds the limits file.

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
- Acceptance: `guest:verify_audio_x_restart` for the pid and the export; a 20 s tone captured across the Xorg kill, with no quiet stretch and no capture time missing against the wall clock.
- Evidence: EV-PIDS; `pactl info`; EV-AUDIO of a 20 s tone spanning the restart with the spectrogram showing no gap.
- Tier: T3 · Coverage: ✅ `guest:verify_audio_x_restart` kills Xorg as the desktop user while a pulse client in the desktop container, outside the X session, plays a 20 s 1100 Hz tone: a new Xorg and mwm come up, PipeWire keeps its pid, the export answers `pactl info`, the player exits 0 within 21 s, and `check-audio.py` finds the tone unbroken across the kill (no stretch below −40 dBFS longer than 0.1 s; its span within 19.6–20.6 s). `artifacts/S4.5.1/` (artifact `evidence-vm-core`) holds the pids before and after, `pactl info`, the player's record, the capture with its verdict and a level plot marking the kill, and what says where any lost audio went: PipeWire's thread scheduling and `pw-top` before and after, the desktop's log, and QEMU's own trace of its emulated HDA codec over the capture.

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
- Acceptance: the new card's sink made the default (`pactl set-default-sink`) at full volume and the built-in card's sink muted, so that only the new card can carry the tone; play a 990 Hz tone; `wavcapture` on the shared `audiodev` and `check-audio.py` assert it; `pactl list short sink-inputs` during playback shows the stream on the new sink; unmute and restore the default sink. Full volume because WirePlumber starts a new device at 0.40, which the USB card renders as −24 dB: a tone at 0.6 of full scale then peaks near 0.04, under `check-audio.py`'s silence floor.
- Evidence: EV-AUDIO (990 Hz, spectrogram); `pactl list short sink-inputs` mid-playback naming the USB sink (EV-STATE); `wpctl status` with the default marker on the new sink; common set.
- Tier: T3 · Coverage: ✅ `e2e` "audio hotplug, again": with the USB card's sink the default at full volume and the built-in card's sink muted, a pulse client's 990 Hz tone is heard at the machine's output (`check-audio.py` at 990 Hz), and mid-playback its stream sits on the USB sink. `artifacts/S4.7.3/` (artifact `evidence-vm-core`) holds F4.7's common set across the card's arrival, `wpctl status` with the `*` on the USB sink and the built-in one `MUTED`, the sink-inputs and sinks mid-playback, and the capture with its verdict and level plot.

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
- Tier: T3 · Coverage: ✅ `e2e` "audio hotplug, again": a 15 s 660 Hz stream plays on the USB card when it is unplugged; by the first check after the removal its stream is on the built-in card's sink, and it plays on to the end (the player exits 0); the three daemons keep their pids and the export answers `pactl info`. `artifacts/S4.7.7/` (artifact `evidence-vm-core`) holds the capture across the removal, whose level plot shows the tone continuing, the sink-inputs and sinks before and after, the player's record, and the daemons' pids with the diff.

**S4.7.8 Capture device plug-in and plug-out reach WirePlumber**
- Requirement: a hot-added card with a capture path appears as an `alsa_input.*` source and disappears on removal.
- Acceptance: `pactl list short sources` gains and loses it. Vehicle: PCI hot-add of `AC97` (`audiodev=snd0`), whose driver the e2e's guest kernel ships (`snd-intel8x0`; `snd-ens1370`, for `ES1370`, too). QEMU's HDA codec bus refuses `device_add`, and `usb-audio` has no capture path.
- Evidence: common set with sources; EV-QEMU including the `device_add` replies.
- Tier: T3 · Coverage: ✅ `e2e` "audio hotplug: a capture-capable card on PCI": `device_add AC97,id=hotcap,audiodev=snd0` brings `alsa_input.pci-0000_00_0b.0.analog-stereo` into `pactl list short sources`, and `device_del hotcap` takes it away. `artifacts/S4.7.8/` (artifact `evidence-vm-core`) holds `modinfo`'s answer for both candidate drivers, QEMU's replies, and F4.7's common set with sources before, plugged in and after, with the diffs.

**S4.7.9 Recording from a hot-added capture device works**
- Requirement: a client can `parec`/`arecord` from the new source.
- Acceptance: the stream opens and delivers frames.
- Evidence: EV-AUDIO-REC (duration > 0, silence with the null backend is acceptable and stated); EV-LOG-CLIENT.
- Tier: T3 · Coverage: ✅ `e2e` "audio hotplug: a capture-capable card on PCI": with the AC97 card hot-added (S4.7.8), the session user's `parecord` records its source, `alsa_input.pci-0000_00_0b.0.analog-stereo`, for 3 s and exits 0, and the WAV holds 2.90 s of frames at 44.1 kHz stereo (silence: QEMU's `none` audiodev captures nothing else). What a real microphone records is S4.7.12's, on hardware. `artifacts/S4.7.9/` (artifact `evidence-vm-core`) holds the recorder's command, output and exit status, the recording, and its frames, duration, format and peak.

**S4.7.10 A card that arrives after a soundless boot is openable**
- Requirement: S2.4.6.
- Acceptance: VM profile without `intel-hda`; hot-add `usb-audio`; after the next stack start WirePlumber lists it and it plays.
- Evidence: as S2.4.6.
- Tier: T3 · Coverage: ✅ `guest:soundless` (S2.4.6's run): after the stack's next start WirePlumber lists the card that arrived after the soundless boot, `pactl list short sinks` gives its sink alone (no `auto_null`), and a 990 Hz tone the session user plays through it is heard. Under `artifacts/S4.7.10/` (artifact `evidence-vm-soundless`): `wpctl status`, the sinks, the player's log, and the tone with its verdict; the rest of S2.4.6's set under `artifacts/S2.4.6/`.

**S4.7.11 Repeated audio cycles leave no phantom devices**
- Requirement: ≥ 5 plug/unplug cycles return node and Device counts to baseline; no `alsa_card` object outlives its node.
- Acceptance: counts equal baseline after the last cycle; the built-in tone still plays.
- Evidence: per-cycle counter table; `pw-cli ls Device` baseline vs final (EV-DIFF empty); EV-AUDIO.
- Tier: T3 · Coverage: ✅ `e2e` "audio hotplug: five plug/unplug cycles leave no phantom devices": five `usb-audio` plug/unplug cycles, each card with an id of its own. Each plug-in raises the container's `controlC*` nodes and WirePlumber's `alsa_card` devices, and each removal brings the host's `/dev/snd` nodes, the container's and WirePlumber's devices back to the baseline (7, 1, 1). After the fifth, `pw-cli ls Device` is the baseline's byte for byte, and the built-in card plays a pulse client's 440 Hz tone, heard. `artifacts/S4.7.11/` (artifact `evidence-vm-core`) holds F4.7's common set before the first cycle and after the fifth with the diffs, the counter table (a row per plug-in and per removal), and the tone's capture with its verdict and level plot.

**S4.7.12 Physical USB audio plug-in and plug-out**
- Requirement: S8.3.1.
- Evidence: EV-PHONEVIDEO of the device being plugged with audible output; `wpctl status` before/after (EV-DIFF); for capture, an EV-AUDIO-REC of speech into the device's microphone.
- Tier: T4 · Coverage: 🔧 `ci/hw/acceptance.sh run S4.7.12` (Appendix C), not yet run on hardware: one run with S8.3.1, whose `wpctl status` states and diffs, EV-PHONEVIDEO and EV-AUDIO-REC it copies; it passes when S8.3.1's run passed every check.

---

## E5 — Host deploy tree

### F5.1 Apply

**S5.1.1 The documented rsync is the whole installation**
- Requirement: `rsync -a --chown=root:root deploy/host/ /` and `systemctl daemon-reload` from `deploy/README.md` "Apply", run as written, install everything (the `reboot` that completes the block is S5.1.3); the two symlinks and the four `multi-user.target.wants` symlinks survive as symlinks.
- Acceptance: symlink checks; `is-enabled` = `enabled` for `desktop-client-cdi`, `desktop-selinux`, `desktop-session`, `desktop-tools-cdi.path`.
- Evidence: `find /etc/systemd/system -maxdepth 2 -type l -ls` (EV-STATE); `systemctl is-enabled` output; `systemctl list-units 'desktop*'` (EV-STATE).
- Tier: T2/T3 · Coverage: ✅ `guest:deploy_applied`, in phase-deploy, reads `deploy/README.md`'s "Apply" block and checks it is still `rsync`, `daemon-reload` and `reboot`; phase-deploy runs the first two as written. It checks the two symlinks and the four `multi-user.target.wants` links arrived as symlinks and the four units read `enabled`, and saves the block, `find /etc/systemd/system -maxdepth 2 -type l -ls`, `systemctl is-enabled` of the four and `systemctl list-units --all 'desktop*'` under `artifacts/S5.1.1/` (artifact `evidence-vm-core`). `smoke` asserts the symlinks and `is-enabled` on the runner (job log only).

**S5.1.2 Files land root-owned with correct modes**
- Requirement: every file from the tree is `root:root`; scripts are executable.
- Acceptance: `find` over the installed paths.
- Evidence: `find <paths> -printf '%M %u %g %p\n'` (EV-STATE).
- Tier: T2 · Coverage: ✅ `smoke` saves `stat -c '%A %U %G %n'` of every file the tree installed (26) and checks all are `root:root`, none group- or world-writable, and every script under `/usr/local/bin` and `/usr/local/libexec` `rwxr-xr-x`, under `artifacts/S5.1.2/` (artifact `evidence-smoke`).

**S5.1.3 Reboot is sufficient, and the operator gets a desktop with no one touching the host**
- Requirement: after a reboot with no manual starts, `desktop.service` is active, all oneshots succeeded, the session is up and visible, the tools spec is rewritten, labels are present, and `seat-prep` changed nothing.
- Acceptance: T3 variant: reboot the VM after phase-deploy and assert the above.
- Evidence: EV-SHOT of the desktop after reboot; `systemctl status` of every unit (EV-STATE); EV-LOG-JOURNAL `-b` for `desktop-seat-prep` (no `seat-prep:` lines); `ls -Z` of the three dirs; `ls /etc/cdi` with mtimes.
- Tier: T3 · Coverage: ✅ `e2e` reboots the VM last in the core shard, after `guest:deploy_tail`, and nothing touches it afterwards. `guest:deploy_reboot` checks a new boot id; `desktop.service` active with X answering and mwm running; the five boot oneshots active and succeeded, and no desktop unit failed; the tools spec rewritten that boot; the three client directories `container_file_t` again; `desktop-seat-prep` logging nothing. It saves the units' status, `systemctl --failed`, `ls -Zd` of the three directories, `ls -l --full-time /etc/cdi`, seat-prep's journal for the boot and `loginctl list-sessions`, and the VM host adds a screendump of the desktop after the reboot, under `artifacts/S5.1.3/` (artifact `evidence-vm-core`).

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
- Tier: T3 · Coverage: ✅ `guest:deploy_tail`, with the desktop running, starts `getty@tty1` (unmasked for the test) and then a stand-in `display-manager.service`: each stops `desktop.service`. Both are then put back: the getty masked again, no display manager, the desktop running. The generated unit's `Conflicts=`, `systemctl status` for each case and the three units' journal through the test are under `artifacts/S5.2.5/` (artifact `evidence-vm-core`).

**S5.2.6 Image pin drop-in**
- Requirement: on podman ≥ 5.0 a `desktop.container.d/50-image.conf` `Image=` override lands in the generated unit.
- Acceptance: on the Rocky VM: add a drop-in, `daemon-reload`, `systemctl cat` shows it, restart works; `desktop-preflight` reports the drop-in as merged.
- Evidence: `systemctl cat desktop.service` (EV-CONFIG); `podman inspect desktop --format '{{.ImageName}}'`; preflight row.
- Tier: T3 · Coverage: ✅ `guest:deploy_tail` writes `desktop.container.d/50-image.conf` pinning `localhost/desktop-container:ev-pinned`, a second name for the same image, runs `daemon-reload` and restarts the desktop: the generated unit carries the pin, the desktop runs the pinned image, and `desktop-preflight` reports the drop-in merged and the pinned image in storage. With the drop-in removed the desktop runs `:latest` again. `podman --version`, the drop-in, `systemctl cat desktop.service`, `podman inspect desktop --format '{{.ImageName}}'` and the preflight report are under `artifacts/S5.2.6/` (artifact `evidence-vm-core`).

### F5.3 Seat convergence (`seat-prep.sh`)

**S5.3.1 Dirty seat is walked back**
- Requirement: seat rules removed, display manager disabled and stopped, default target set, getty masked and stopped, logind restarted only if something changed.
- Acceptance: `smoke` staged seat rule + fake DM; `guest:phase_deploy`: start `desktop-seat-prep` on its own before `desktop.service`, and assert `getty@tty1` stopped and the `seat-prep: stopping running getty@tty1.service` journal line. (Starting the desktop proves nothing here: its `Conflicts=getty@tty1.service` stops the getty in the same transaction.)
- Evidence: EV-LOG-JOURNAL of `desktop-seat-prep` and `systemd-logind` (restart present on the dirty run, absent on steady state); `systemctl status getty@tty1 display-manager` before/after (EV-DIFF); `systemctl get-default`.
- Tier: T2/T3 · Coverage: ✅ the getty, the default target and logind: `guest:seat_prep_dirty`, in phase-deploy, starts `desktop-seat-prep` on its own on the stock host, before the desktop. `getty@tty1` stops, the journal says `stopping running getty@tty1.service` and `seat converged`, `systemd-logind` restarts (a new MainPID), and the default target is `multi-user.target`. `guest:deploy_reboot` adds the steady half: on the rebooted, converged host seat-prep logs nothing and logind starts once. Both halves' evidence is under `artifacts/S5.3.1/` (artifact `evidence-vm-core`): `getty@tty1`'s and `display-manager`'s status before and after with their diff, seat-prep's and logind's journals, `get-default`. ✅ the seat-rule and display-manager clauses, at T2: the stock VM has neither, so `smoke` stages both on the runner, a `72-seat-*.rules` file and a display manager (`ci-fake-dm.service`, aliased as `display-manager.service`) enabled and running. seat-prep removes the rule and disables and stops the manager, saying so for each; run again on the converged seat, it says nothing. Under `artifacts/S5.3.1/` (artifact `evidence-smoke`): the staged seat, seat-prep's output, the seat after it with the diff, and the second run's output.

**S5.3.2 Steady state is silent and idempotent**
- Requirement: a second run changes nothing and prints nothing.
- Acceptance: `smoke` runs the second pass as `systemctl restart desktop-seat-prep` before the desktop starts (seat-prep's DRM/VT gate fails while Xorg holds the seat), and asserts exit 0, an empty journal slice and no logind restart.
- Evidence: the (empty) stdout, EV-LOG-JOURNAL of the second run.
- Tier: T2 · Coverage: ✅ `smoke` runs the second pass as `systemctl restart desktop-seat-prep.service` before the desktop starts, and saves its output (none), the journal slice of the unit's own process for that run (empty) and systemd-logind's MainPID before and after (unchanged) under `artifacts/S5.3.2/` (artifact `evidence-smoke`).

**S5.3.3 The gate names a culprit and fails**
- Requirement: a process holding `/dev/dri/card*` or `/dev/tty1` after convergence → exit 1 naming it; `desktop.service` still starts.
- Acceptance: stop `desktop.service`; hold `/dev/dri/card0` from a background `sleep`; `systemctl restart desktop-seat-prep` fails naming that pid; `systemctl start desktop.service` still starts it, and its Xorg meets the conflict the gate named: the sleep opened card0 first, so it is card0's DRM master and the rootless Xorg's `drmSetMaster` fails, as `desktop-seat-prep.service` says it will; release; `systemctl restart desktop-seat-prep` succeeds and the desktop comes up. (`start` is a no-op on the already-active `RemainAfterExit=yes` unit, and while the desktop runs Xorg holds `card0` too.)
- Evidence: EV-LOG-JOURNAL with the `ERROR: devices still held` line and the `fuser -v` table; `systemctl status` of both units.
- Tier: T3 · Coverage: ✅ `guest:deploy_tail` stops the desktop and holds `/dev/dri/card0` from a root `sleep`. `systemctl restart desktop-seat-prep` exits 1, its journal naming card0, the sleep's pid and fuser's table. `desktop.service` still starts (the quadlet only `Wants=` seat-prep), and the Xorg log shows `drmSetMaster` failing. With the sleep gone, seat-prep succeeds and the desktop comes up with X answering. Under `artifacts/S5.3.3/` (artifact `evidence-vm-core`): the holders, seat-prep's journal, the Xorg log's DRM-master lines, both units' status, and what the host's `fuser` shows with the desktop running. Recorded there: the host's `fuser` does not list the container's Xorg, because podman gives the container device nodes of its own and `fuser` matches an open file by its node. The gate runs before the desktop starts, so that does not weaken it, but no host-side `fuser` can show whether the desktop itself holds the card.

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
- Acceptance: `smoke` with a fake `nvidia-ctk` and fake `/dev/nvidiactl`; the `/proc/modules` trigger through the script's `CDI_PROC_MODULES` (Appendix A).
- Evidence: the spec after each step (EV-CONFIG × 4); the script's stdout.
- Tier: T2 · Coverage: ✅ `smoke` runs the converger through six legs, saving its output and the spec after each, under `artifacts/S5.4.2/` (artifact `evidence-smoke`): no toolkit and no hardware, the stub; a fake `nvidia-ctk` and a fake `/dev/nvidiactl`, the real spec it generates; a failing `nvidia-ctk` keeps the real spec; no toolkit with the device node present keeps it; no toolkit and no device node with the `nvidia` module loaded keeps it (the module list given as `CDI_PROC_MODULES` is the runner's `/proc/modules` with an `nvidia` line added, kept as evidence); neither, the runner's own `/proc/modules` (no `nvidia` line, its count kept), back to the stub.

**S5.4.3 Stale real spec fails loudly, regenerates on restart**
- Requirement: after a driver update the stale spec fails container creation; `systemctl restart desktop-cdi-refresh` fixes it.
- Acceptance: manual.
- Evidence: EV-LOG-JOURNAL of `desktop.service` (the creation error) and `desktop-cdi-refresh`; the spec before/after (EV-DIFF).
- Tier: T4 · Coverage: 🔧 `ci/hw/acceptance.sh run S5.4.3` (Appendix C), not yet run on hardware. On an NVIDIA host with a real spec, what a driver update leaves behind is staged: every `.so.<driver version>` path in the spec renamed, and `nvidia-ctk` set aside so that the restart cannot regenerate it; the spec before and after is diffed. `systemctl restart desktop.service` must leave the desktop down, its journal naming the missing file. Then, the toolkit back, `README.md`'s "CDI spec staleness" entry is read out of the document and its remedy, `systemctl restart desktop-cdi-refresh.service`, run: a real spec regenerated (diffed against the stale one), and `desktop-cdi-refresh`'s journal. The story also requires the desktop back within 60 s of the remedy alone, which this run settles: the entry does not say to start the desktop again, and with the quadlet's `Restart=always` and systemd's default start limit, a creation error that fails fast may leave the unit failed at its limit. If so the story fails there, and the script restarts the desktop.

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
- Tier: T2/T3 · Coverage: ✅ `guest:deploy_tail` removes the tools spec while `desktop-tools-cdi.service` is active: still absent 5 s later. `systemctl stop desktop-tools-cdi.service` lets the `.path` unit fire again: the spec is back, and the `.path` unit is active, not failed. `guest:deploy_reboot` adds the reboot half: the spec rewritten that boot. The units' and the spec's state at each step, their journal since the removal and their state after the reboot are under `artifacts/S5.5.5/` (artifact `evidence-vm-core`).

**S5.5.6 Specs are host state, independent of the desktop and of kubernetes**
- Requirement: display/audio specs exist before the desktop is up and survive `helm uninstall`.
- Acceptance: with `desktop.service` stopped, remove both specs and `systemctl restart desktop-client-cdi`: both reappear; `guest:verify_teardown` with `ls -l --full-time /etc/cdi` before and after `helm uninstall`. (`guest:phase2` checks the specs only once the desktop is already running.)
- Evidence: `ls -l /etc/cdi` with mtimes before/after (EV-DIFF empty for the two specs).
- Tier: T3 · Coverage: ✅ `guest:deploy_tail`, with `desktop.service` stopped, removes both client specs and restarts `desktop-client-cdi`: both are back, byte for byte the same. `ls -l --full-time /etc/cdi` before, removed and after, with the diffs, are under `artifacts/S5.5.6/` (artifact `evidence-vm-core`). The `helm uninstall` half is `guest:verify_teardown`'s, its evidence under `artifacts/S7.3.6/` (artifact `evidence-vm-k8s`): `/etc/cdi` before and after the uninstall, EV-DIFF empty.

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
- Tier: T3 · Coverage: ✅ `guest:deploy_checks` checks the full context, `system_u:object_r:container_file_t:s0` with no categories, on the three client directories and on the published `screenshot` binary; `getenforce` and the `ls -Zd`/`ls -Z` listing are under `artifacts/S5.6.2/` (artifact `evidence-vm-core`).

**S5.6.3 The label is policy, including the `/run` equivalency workaround**
- Requirement: an fcontext rule governs each dir (for `/run/desktop-audio`, under whichever of `/run` or `/var/run` the policy accepts: `desktop-selinux` tries `/run` first; Rocky 9 stores it under `/var/run`); `restorecon -R` keeps the labels.
- Acceptance: `semanage fcontext -l -C` lists three rules; `restorecon -Rv` changes nothing.
- Evidence: the `semanage` listing and `restorecon -Rv` output (EV-STATE); `ls -Zd` after.
- Tier: T3 · Coverage: ✅ `guest:deploy_checks`: `semanage fcontext -l -C` lists a local `container_file_t` rule for each of the three directories, `/run/desktop-audio`'s stored under `/var/run`, and `restorecon -Rv` of the three relabels nothing. The listing, the `restorecon` output and `ls -Zd` after are under `artifacts/S5.6.3/` (artifact `evidence-vm-core`).

**S5.6.4 chcon fallback without semanage**
- Requirement: without `semanage` on `PATH`, the dirs are still labelled and the policy note printed.
- Acceptance: run with a stubbed `PATH` against a probe dir.
- Evidence: stdout; `ls -Zd` of the probe dir.
- Tier: T3 · Coverage: ✅ `guest:deploy_tail` runs `desktop-selinux` on a probe directory with `PATH=/usr/bin:/bin`, so no `semanage`, `restorecon` or `selinuxenabled`: it prints the policy note, labels the probe `container_file_t` with `chcon`, exits 0 and adds no policy rule. `ls -Zd` before and after and the run's output are under `artifacts/S5.6.4/` (artifact `evidence-vm-core`).

**S5.6.5 Verification fails the unit when a label does not land**
- Requirement: a dir still lacking the type → `FAILED to label` naming it, exit 1.
- Acceptance: a dir on a filesystem that refuses relabeling.
- Evidence: stdout/exit code; `ls -Zd`; `mount` line of the probe fs.
- Tier: T3 · Coverage: ✅ `guest:deploy_tail` points `desktop-selinux` at a directory on a tmpfs mounted with `context=`, which nothing can relabel (a `chcon` by hand is refused too): it says `FAILED to label`, names the directory with its `tmp_t` label and exits 1. `findmnt`, the refused `chcon`, the run and `ls -Zd` after are under `artifacts/S5.6.5/` (artifact `evidence-vm-core`).

**S5.6.6 Missing directories are reported, not invented**
- Requirement: a missing dir is warned and skipped; none present → exit 1.
- Acceptance: two bogus paths → exit 1; one bogus + one real → warning, labelled, exit 0.
- Evidence: stdout and exit codes for both runs.
- Tier: T3 · Coverage: ✅ `guest:deploy_tail` runs `desktop-selinux` on two missing paths: both named in the warning, then `none of the client directories exist yet`, exit 1. Then on one missing and one real: the missing one warned about and not created, the real one labelled, exit 0. Both runs' output and exit status are under `artifacts/S5.6.6/` (artifact `evidence-vm-core`).

**S5.6.7 The host keeps full access after relabeling**
- Requirement: an unconfined host process can connect to the X and audio sockets and execute the toolkit.
- Acceptance: `guest:phase_deploy` host `pactl`, host `screenshot --help`, host capture of `:0`.
- Evidence: the host capture PNG (EV-SHOT-CLIENT host variant); `pactl info`; `ausearch -m avc -ts recent` (empty) (EV-STATE).
- Tier: T3 · Coverage: ✅ `guest:phase_deploy` saves an unconfined host process running the relabeled `screenshot --help`, its capture of `:0`, `pactl info` over the relabeled socket, and `ausearch --input-logs -m avc -ts <the start of these checks>`, and asserts that last one holds no AVC record. A control comes first: `ausearch --input-logs -m DAEMON_START` must find auditd's own start record, so the search is shown to read the audit log. Before batch 8 the search had no `--input-logs`, and ausearch reads its standard input instead of the log when that is a pipe, as the guest script's is over ssh (the evidence notes it: a fifo), so it read nothing and could not fail. Under `artifacts/S5.6.7/` (artifact `evidence-vm-core`): the binary's `--help`, the capture, `pactl info`, the control and the search.

### F5.7 Host Terminal

**S5.7.1 Fresh key every boot, root-only, restricted trust**
- Requirement: ed25519 keypair under `/etc/desktop-container` (0400/0644), `authorized_keys.d/desktop-shell` (0644) with the `from=` and `no-*-forwarding` options.
- Acceptance: `dryrun`/`smoke`; `guest:phase_deploy` under enforcing.
- Evidence: `ls -l /etc/desktop-container /etc/ssh/authorized_keys.d` (EV-STATE); the authorized_keys line (EV-CONFIG).
- Tier: T2/T3 · Coverage: ✅ `guest:deploy_checks` checks the private key 0400 root, and the public key and the `authorized_keys.d` entry 0644 root. The entry is one line: `from="127.0.0.1,::1"`, `no-port-forwarding`, `no-agent-forwarding`, `no-X11-forwarding`, then an `ssh-ed25519` key, the one in `host-shell-key.pub`. `guest:deploy_reboot` adds that the reboot makes a new key and the entry carries it. `ls -l` of both directories, the entry and the key's fingerprint before and after the reboot are under `artifacts/S5.7.1/` (artifact `evidence-vm-core`). `dryrun` and `smoke` assert the loopback restriction and the key's mode on the runner (job log only).

**S5.7.2 Login works both directions, and the operator gets a host shell from the menu**
- Requirement: `ssh -i <key> desktop-shell@127.0.0.1 whoami` from the host and `ssh host whoami` from the container return `desktop-shell`; the "Host Terminal" menu entry shows a prompt on the host.
- Acceptance: `smoke`, `guest:phase_deploy`; T3 launch `host-terminal` in an xterm and screendump.
- Evidence: both `whoami` transcripts (EV-STATE); EV-SHOT of the host-terminal xterm showing `desktop-shell@<host>`; EV-LOG-JOURNAL of `sshd` (the accepted publickey line).
- Tier: T2/T3 · Coverage: ✅ `guest:phase_deploy` saves both `whoami` transcripts (from the host with the key, and `ssh host` from the container) under `artifacts/S5.7.2/` (artifact `evidence-vm-core`). The menu half is evidenced in `artifacts/S11.1.1/` by `operator-e2e:menu_host_terminal`: a shot of the `desktop-shell@` prompt with `whoami` typed and answered, and sshd's accepted-publickey line.

**S5.7.3 Restrictions are enforced**
- Requirement: the key is refused from a non-loopback source; port forwarding is refused.
- Acceptance: ssh to the VM's non-loopback IP fails; `-R` with `ExitOnForwardFailure=yes` exits nonzero when the forward is set up; a connection through a `-L` forward is refused when it is made. `ExitOnForwardFailure` does not see that refusal: sshd refuses the channel, not the forward, so `-L` itself exits 0.
- Evidence: both ssh transcripts with exit codes; EV-LOG-JOURNAL of `sshd` showing the refusals.
- Tier: T3 · Coverage: ✅ `guest:deploy_checks`: the key is accepted from 127.0.0.1 and refused from the VM's own non-loopback address (ssh exit 255). `ssh -R` with `ExitOnForwardFailure=yes` exits 255 at setup. A connection through an `ssh -L` forward gets nothing back: the channel is administratively prohibited. Recorded: the `-L` ssh itself exited 0. The transcripts and sshd's journal are under `artifacts/S5.7.3/` (artifact `evidence-vm-core`).

**S5.7.4 Re-running rotates the key and invalidates the old one**
- Requirement: a second run writes a different key; the old private key no longer authenticates; the running container takes the new key at once (the unit hands it to a running desktop), and still has access after `desktop.service` restarts.
- Acceptance: as stated.
- Evidence: `ssh-keygen -lf` of old and new public keys (EV-DIFF); old-key ssh transcript (refused); new-key transcript; the unit's journal of the hand-off; container `ssh host` right after the second run and after the restart.
- Tier: T2 · Coverage: ✅ `smoke` re-runs `desktop-host-shell.service` and saves `ssh-keygen -lf` of the public key before and after (different, with the diff), the old private key refused by sshd, the new one logging in as `desktop-shell`, the unit's journal of its hand-off to the running desktop, and the container's `ssh host` logging in right after the second run, with no desktop restart, and again after `desktop.service` restarts, under `artifacts/S5.7.4/` (artifact `evidence-smoke`). Before `claude/fix-host-shell-live` the running container was refused until that restart, as this story then required.

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
- Tier: T1/T2 · Coverage: ✅ the T1 half: `build-smoke`'s "host-shell-setup's cases (S5.7.7's T1 half)" step (`ci/host-shell-setup-tests.sh`) runs the image's `host-shell-setup.sh` in a scratch container per case, `/etc/desktop-container` written there as the quadlet's read-only mount would give it. No key: the hint names the missing key and how to enable it, exit 0, no `~/.ssh`, and the preflight WARNs `no host shell material`. No `shell-user` file, and an empty one: a warning naming it, exit 0, no ssh config. Both present: `~/.ssh` 0700, a 0400 key copy byte-identical to the mounted key and a 0600 config (`Host host`, `HostName 127.0.0.1`, the user, `IdentityFile`, `IdentitiesOnly yes`), all `desktop:desktop`, and the preflight PASSes the material. Per case under `artifacts/S5.7.7/` (artifact `evidence-smoke`): the setup and the transcript; the config. ✅ the T2 half: `smoke` applies the documented off-switch (the quadlet's two lines commented out, `daemon-reload`: the unit quadlet generated neither wants nor orders itself after `desktop-host-shell.service`), stops the unit and deletes the key files. The desktop starts and its X session comes up; nothing made a key; host-shell-setup logs the missing key and how to enable it; the preflight WARNs; the container has no `~/.ssh/config`. With the quadlet put back, the next start makes a fresh key and host-shell-setup configures the host shell. The quadlet's lines, the generated unit's dependencies, `/etc/desktop-container`, both starts' log lines and `~/.ssh` are under `artifacts/S5.7.7/` (artifact `evidence-smoke`). ✅ the T3 EV-SHOT the evidence names, shared with S5.7.8: `operator-e2e:s5_7_8` shoots the Host Terminal window showing the failure and "Press Enter to close", under `artifacts/S5.7.8/` (artifact `evidence-vm-operator`). There the host refuses the key rather than the container lacking it; `host-terminal` prints the same text for any failure of `ssh host`.

**S5.7.8 The menu wrapper keeps its window open on failure**
- Requirement: on `ssh host` failure, `host-terminal` prints the exit code, the enablement command and the common causes, waits for Enter, exits with ssh's code; on success exits 0 at once.
- Acceptance: T1 with a fake `ssh`.
- Evidence: stdout and exit codes for both cases; T3 EV-SHOT (see S5.7.7).
- Tier: T1/T3 · Coverage: ✅ the T1 half: `script-unit` runs `host-terminal` with a fake `ssh`. On success it exits 0 at once, its stdin held open; on failure it prints the exit code, the enablement command and the common causes, waits for Enter and exits with ssh's code (255). Output and exit codes are under `artifacts/S5.7.8/` (artifact `evidence-static`). ✅ the T3 half: `operator-e2e:s5_7_8` moves the host's trust entry for desktop-shell (`/etc/ssh/authorized_keys.d/desktop-shell`) aside, so the key the container holds is refused, and opens Host Terminal from the root menu through QEMU's input devices. The window's text, read back through CUT_BUFFER0, gives the failure with ssh's exit code (255), the enablement command, the other common causes and, last, `Press Enter to close.`; the window is still open seconds later, and Enter closes it. Under `artifacts/S5.7.8/` (artifact `evidence-vm-operator`): the menu and the armed entry, the window's EV-SHOT and its text, sshd's effective authentication settings and its journal on the refused login.

### F5.8 Host login session (`desktop-session.service`)

**S5.8.1 A real logind session on seat0/tty1**
- Requirement: `loginctl` shows `desktop` on `seat0`; `/run/user/61000` mounted by logind; utmp has an entry for tty1.
- Acceptance: `smoke`, `guest:deploy_checks` (tty1, the logind mount and utmp included).
- Evidence: `loginctl list-sessions` and `loginctl show-session <id>` (EV-STATE); `who`; `findmnt /run/user/61000`.
- Tier: T2/T3 · Coverage: ✅ `guest:deploy_checks`: logind holds a user session for `desktop` on `seat0`, on `tty1`; `/run/user/61000` is a tmpfs mounted by `user-runtime-dir@61000.service`; utmp records `desktop` on `tty1`. `loginctl list-sessions`, `loginctl show-session`, `findmnt` with the unit that mounted it and `who` are under `artifacts/S5.8.1/` (artifact `evidence-vm-core`). `smoke` asserts the session on the runner (job log only).

**S5.8.2 Moves with the container**
- Requirement: `PartOf=desktop.service` restarts the session with the container.
- Acceptance: `smoke`.
- Evidence: `systemctl show -p ActiveEnterTimestamp desktop.service desktop-session.service` before/after (EV-DIFF both moved); EV-LOG-JOURNAL.
- Tier: T2 · Coverage: ✅ `smoke` saves `systemctl show -p ActiveEnterTimestamp` of `desktop.service` and `desktop-session.service` before and after `systemctl restart desktop.service`, with the diff (both moved), and the session unit's journal since, under `artifacts/S5.8.2/` (artifact `evidence-smoke`).

**S5.8.3 Does not steal the controlling tty**
- Requirement: the container's `setsid -c` on tty1 succeeds.
- Acceptance: X comes up and `podman logs` has no `failed to set the controlling terminal`.
- Evidence: EV-LOG-DESKTOP grep (empty); `ps -o tty= -p <desktop-session-lead>` is `?`.
- Tier: T3 · Coverage: ✅ `guest:deploy_checks`: the host session's lead (`desktop-session-lead`) has no controlling tty, and the desktop's log never says `failed to set the controlling terminal`. The lead's `ps` line, the (empty) grep and Xorg's controlling tty in the container are under `artifacts/S5.8.3/` (artifact `evidence-vm-core`).

**S5.8.4 The desktop runs with the unit disabled**
- Requirement: see S2.2.2.
- Acceptance: `systemctl disable desktop-session` does not take the unit out of the desktop's start (the quadlet's `Wants=`), and `systemctl mask` is refused, the unit file being the tree's own; with the unit file moved aside (S2.2.2's procedure) the desktop runs.
- Evidence: as S2.2.2.
- Tier: T3 · Coverage: ✅ `guest:standalone_desktop`, in the core shard. With the unit disabled and the desktop started, desktop-session still came up (desktop.container's `Wants=`) and the runtime dir was the host's: disabling is not enough. `systemctl mask desktop-session` is refused (exit 1): the unit file is the tree's own, at the path mask's link would take. With the unit file moved aside the desktop runs: X answers and the audio export answers (S2.2.2 has the runtime dir), and the VM host shoots the screen. Each state is under `artifacts/S5.8.4/` (artifact `evidence-vm-core`).

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
- Tier: T2 · Coverage: ✅ `smoke` runs `ci/preflight-rows.py host` on the runner the tree is applied to. It reads every FAIL and WARN row out of `desktop-preflight` itself (40), stages each row's condition in a case of its own, and checks that the case makes its row fire; a row no case names fails the story, so a row added to the script fails it until a case stages it. Cases run the preflight in a private mount namespace: a path hidden under `/dev/null`, a directory covered by a tmpfs, a command taken off `PATH`, fakes of `systemctl` and `podman` first on `PATH` answering the calls a case lists, a sleep holding the host's first DRM card. All 40 rows fired. Under `artifacts/S5.10.3/` (artifact `evidence-smoke`): the rows read from the source, the preflight with nothing staged, each case's staging and report, and the table of every row, the case that staged it and the line it printed.

### F5.11 Container preflight (`preflight-check.sh`)

**S5.11.1 Green on a provisioned KMS host**
- Requirement: no `preflight: FAIL:` lines on the VM.
- Acceptance: grep.
- Evidence: EV-LOG-DESKTOP preflight block.
- Tier: T3 · Coverage: ✅ `guest:deploy_checks` reads the container preflight's lines from the desktop's log: it ran (16 lines) and reported no FAIL. The lines are under `artifacts/S5.11.1/` (artifact `evidence-vm-core`).

**S5.11.2 Each check fires**
- Requirement: every FAIL/WARN in the script fires when staged (omitted mounts/devices/flags via `podman run`).
- Acceptance: T2 table-driven.
- Evidence: per case: the `podman run` command and the preflight block (EV-LOG-DESKTOP).
- Tier: T2 · Coverage: ✅ `build-smoke`'s "every row of the container preflight fires (S5.11.2)" step runs `ci/preflight-rows.py container`: every FAIL and WARN row read out of `preflight-check.sh` (18), each staged in `podman run --rm` of the image with none of the quadlet's devices or mounts and a setup of its own (an unreadable card, a foreign-seat tag, the host pid namespace missing, `/sys` absent or writable, a stub spec with an NVIDIA device node, and the rest); all 18 fired. Under `artifacts/S5.11.2/` (artifact `evidence-smoke`): the rows read from the source, each case's `podman run` command and preflight block, and the table. Its `/sys` cases found a defect, fixed by `claude/fix-preflight-sys-missing` and merged into this branch: with no `/sys` mount the script printed `FAIL: /sys is mounted WRITABLE ()` instead of its own `WARN: /sys not found in /proc/self/mounts`.

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
- Tier: T3 · Coverage: ✅ `guest:verify_privileges` decodes desktop-init's `CapEff` bit by bit and compares it with the installed quadlet's `AddCapability` lines: the same nine, no difference. `artifacts/S6.1.3/` (artifact `evidence-vm-core`) holds the quadlet's capability lines, both sorted lists and the empty diff.

**S6.1.4 Device cgroup is bounded**
- Requirement: `/dev/mem` cannot be read; the five allowed majors can.
- Acceptance: a `c 1:1` node created in the container's own `/dev` cannot be opened (EPERM), and one node of each allowed major (13, 116, 226, 4, 5) can. Not under `/tmp`: podman mounts `Tmpfs=` `nodev` by default, so a node there is refused whatever the device cgroup allows.
- Evidence: the `mknod`/`dd` transcript with errno (EV-STATE); the quadlet's `--device-cgroup-rule` flags and the device list of the container's OCI spec, which crun compiles into the cgroup v2 BPF program (cgroup v2 has no `devices.list`).
- Tier: T3 · Coverage: ✅ `guest:verify_privileges`, as container root in the container's own `/dev`: a `c 1:1` node is refused (`Operation not permitted`) and a node of each allowed major (13, 116, 226, 4, 5) opens; the container's OCI spec lists the quadlet's five rules after its deny-all. `artifacts/S6.1.4/` (artifact `evidence-vm-core`) holds the quadlet's rules, the spec's device list in order, and each probe with its error.

**S6.1.5 `/sys` is read-only and non-recursive**
- Requirement: `/sys` mount is `ro`, and the bind is non-recursive: none of the host's mounts under `/sys` (its cgroup2, selinuxfs, debugfs and the rest) is in the container. The only mounts under the container's `/sys` are podman's own, from the container's OCI spec: the container's own cgroup2 at `/sys/fs/cgroup`, read-only, and empty read-only tmpfs masks over the spec's masked paths (`/sys/firmware`, `/sys/fs/selinux`).
- Acceptance: `guest:verify_privileges`: `/sys` is `ro` in the container's own mount table; every mount under it is one the OCI spec makes, in the form the spec gives it (its cgroup mount a read-only cgroup2, each masked path an empty read-only tmpfs); none of the VM host's mounts under `/sys` is among them.
- Evidence: `/proc/<init>/mounts` filtered to `/sys` (EV-STATE); the OCI spec's mounts, masked and read-only paths under `/sys` (EV-CONFIG); the VM host's own mounts under `/sys` (EV-STATE); the masks' listing and `ls /sys/fs`; the container's and the host's cgroup namespaces.
- Tier: T3 · Coverage: ✅ `guest:verify_privileges`: `/sys` is `ro` in the container's own mount table; the mounts under it are the container's own read-only cgroup2 at `/sys/fs/cgroup`, as its OCI spec asks, and podman's empty read-only tmpfs masks over `/sys/firmware` and `/sys/fs/selinux`, the spec's masked paths; none of the VM host's nine mounts under `/sys` is in the container. `artifacts/S6.1.5/` (artifact `evidence-vm-core`) holds the container's `/sys` mounts, the spec's, the host's, the masks' listing, `/sys/fs`, and the two cgroup namespaces (they differ: the container sees only its own cgroup tree).

### F6.2 Namespace sharing and mandatory access control

**S6.2.1 Host pid namespace, bounded by capability**
- Requirement: the container sees host pids but, as container root, cannot signal a host process of another uid (`kill -0 <pid>` → EPERM) nor read pid 1's memory or environ. kill(2) allows a signal between processes of the same uid without `CAP_KILL`, and with no user namespace container root is host uid 0, so signalling host processes that also run as root is not prevented by this design; the original `kill -0 1` → EPERM acceptance could not hold.
- Acceptance: as stated, as container root.
- Evidence: the three command transcripts with errno (EV-STATE); `ls /proc | head`.
- Tier: T3 · Coverage: ✅ `guest:verify_privileges`, as container root: `/proc` lists the host's pids, but `kill -0` on a `sleep` of the unprivileged `rocky` user is refused (`Operation not permitted`), and pid 1's `environ` and `mem` cannot be read (`Permission denied`). `artifacts/S6.2.1/` (artifact `evidence-vm-core`) holds the target process, `ls /proc`, and the three transcripts with their exit statuses.

**S6.2.2 Host network namespace**
- Requirement: the container's interfaces equal the host's.
- Acceptance: `readlink /proc/self/ns/net` inside equals the host's, and the interface names in `/proc/net/dev` match (the image may not ship `ip`).
- Evidence: both outputs (EV-DIFF empty).
- Tier: T3 · Coverage: ✅ `guest:verify_privileges`: `readlink /proc/self/ns/net` is the same inside the container as on the VM host, and so are the interface names in `/proc/net/dev`. `artifacts/S6.2.2/` (artifact `evidence-vm-core`) holds both namespace links, both interface lists and their empty diff.

**S6.2.3 SELinux separation off for the desktop, AppArmor unconfined**
- Requirement: desktop processes run `spc_t`/unconfined; on an AppArmor host the profile is `unconfined`.
- Acceptance: `ps -Z -p <init>` on the VM; `podman inspect … AppArmorProfile` on the runner.
- Evidence: both outputs (EV-STATE).
- Tier: T2/T3 · Coverage: ✅ the T3 half: `guest:verify_privileges` finds desktop-init running as `system_u:system_r:spc_t:s0` on the VM, SELinux enforcing; `artifacts/S6.2.3/` (artifact `evidence-vm-core`) holds its label and `podman inspect`'s process label, AppArmor profile and security options. The T2 half: `smoke` on the runner, an AppArmor host, finds `podman inspect` reporting `AppArmorProfile=unconfined` and desktop-init's `/proc/<pid>/attr/current` reading `unconfined`; `artifacts/S6.2.3/` (artifact `evidence-smoke`) holds both.

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
- Evidence: `getenforce`; a probe's own SELinux label (`/proc/self/attr/current`, what `ps -Z` shows); `ausearch -m avc` since the probes began (no denial with a `container_t` subject) (EV-STATE); the static guard's verdict.
- Tier: T3/T0 · Coverage: ✅ the T0 half: `ci/client-guard.py`, run by the static job, reads every `podman run` and `podman create` under `ci/` and `examples/` as the shell would (continuations, quoting, heredoc bodies skipped) and every argv list the Python there builds, and finds none passing `--privileged` or `label=disable`, and no client manifest asking for `privileged: true` or `spc_t`; its self-test first shows that it flags each kind of violation and passes a mere mention. The guard's whole verdict is under `artifacts/S7.1.2/` (artifact `evidence-static`). The T3 half: `guest:phase_deploy` finds SELinux `Enforcing` on the VM host, a confined display client labelled `container_t` that opens `:0`, and no AVC denial with a `container_t` subject since the probes began, read with `ausearch --input-logs` after the control S5.6.7 describes (before batch 8 the search read the script's stdin pipe and could not fail); `getenforce`, the probe's label with `xdpyinfo`'s verdict, the control and `ausearch --input-logs -m avc` since the probes began are under `artifacts/S7.1.2/` (artifact `evidence-vm-core`).

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
- Tier: T3 · Coverage: ✅ `guest:phase2` and `guest:verify_cdi`: the three releases make `desktop.local/display`, `audio` and `tools` allocatable at 10 each. The verifier pod, whose manifest declares nothing but its request, gets `DISPLAY=:0`, `PULSE_SERVER` and `PIPEWIRE_REMOTE`; its X socket is mounted writable and `xdpyinfo` opens `:0`, and its audio sockets are mounted writable and `pactl info` answers. The control pod, the same image and manifest without the request, gets no `DISPLAY`, `PULSE_SERVER` or `PIPEWIRE_REMOTE` and no `/tmp/.X11-unix` or `/run/desktop-audio` mount. `artifacts/S7.3.1/` (artifact `evidence-vm-k8s`) holds the node's allocatable resources, the three plugins' logs, both pods' environments and mounts, and the control pod's against the verifier's as diffs.

**S7.3.2 Split holds in pods**
- Requirement: display-only has display, no audio, no toolkit; audio-only plays, has no display and cannot `xdpyinfo`.
- Acceptance: `guest:verify_split`.
- Evidence: per pod `env`, `mountinfo`, `xdpyinfo` exit (EV-STATE); EV-AUDIO from audio-only.
- Tier: T3 · Coverage: ✅ `guest:verify_split`: the display-only pod has `DISPLAY=:0` and `xdpyinfo` opens it, with no `PULSE_SERVER`, `PIPEWIRE_REMOTE` or `DESKTOP_TOOLS_BIN` and no audio or toolkit mount. The audio-only pod has `PULSE_SERVER` and `PIPEWIRE_REMOTE`, `pactl info` answers over them and its 440 Hz tone is heard at the machine's output, while it has no `DISPLAY`, no `/tmp/.X11-unix` mount, and `xdpyinfo` fails. `artifacts/S7.3.2/` (artifact `evidence-vm-k8s`) holds each pod's environment, mounts and `xdpyinfo` verdict, the audio-only pod's `pactl info`, and its capture with its verdict and level plot.

**S7.3.3 Pods are confined and declare no securityContext**
- Requirement: `container_t`; manifests carry no `securityContext`, `volumes`, `env`, or CDI annotation.
- Acceptance: `guest:phase2`, `ci/helm-assertions.sh`.
- Evidence: `/proc/self/attr/current` from the pod (EV-STATE); the manifests (EV-CONFIG).
- Tier: T0/T3 · Coverage: ✅ the T0 half: `ci/helm-assertions.sh`, run by the static job, checks all eight client manifests (the example, `cdi-verify`, `testclient`, `display-only`, `audio-only`, `testpattern`, `journey` and `early`): each requests a `desktop.local` resource and declares no `securityContext`, `volumes`, `volumeMounts`, `env`, CDI annotation or privilege. The assertions' output and the eight manifests as committed are under `artifacts/S7.3.3/` (artifact `evidence-static`). The T3 half: the demo pod runs as `container_t`, and the API server holds no `securityContext` for it beyond its empty default; the manifest as applied, the pod as the API server holds it and the pod's own label are under `artifacts/S7.3.3/` (artifact `evidence-vm-k8s`).

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
- Acceptance: `guest:verify_teardown` for the display, audio and tools releases, with a client pod running through the uninstall.
- Evidence: allocatable before/after (EV-DIFF); `ls -l /etc/cdi` unchanged; EV-SHOT of the client window still present; the client pod's `restartCount` (EV-PIDS).
- Tier: T3 · Coverage: ✅ `guest:verify_teardown`: `helm uninstall` of the display, audio and tools releases leaves none of the three resources allocatable and their daemonsets gone; `/etc/cdi` is unchanged, every spec the same size and time; `desktop.service` stays active with its X socket. A client pod running through the uninstall is the same container (`restartCount` 0), keeps its window on the screen and opens `:0` with `xdpyinfo` afterwards. `artifacts/S7.3.6/` (artifact `evidence-vm-k8s`) holds the allocatable resources and `/etc/cdi` before and after with the diffs, the client pod and its windows before and after with the diff, and the screen after the uninstall.

**S7.3.7 The desktop survives CRI-O and k3s arriving**
- Requirement: `desktop.service` active and `X0` present after the runtime install.
- Acceptance: `guest:phase2`.
- Evidence: EV-PIDS of Xorg/mwm/pipewire before and after the install (unchanged); EV-SHOT.
- Tier: T3 · Coverage: ✅ `guest:phase2`: desktop-init, Xorg, mwm and the audio daemons have the same pids and start times before and after CRI-O and k3s are installed, `desktop.service` is active and the X socket is there; `e2e` shoots the desktop after. `artifacts/S7.3.7/` (artifact `evidence-vm-k8s`) holds the processes before and after (`ps -o pid,ppid,lstart,comm`) with their empty diff, and the screenshot.

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
- Tier: T3 · Coverage: ✅ `operator-e2e:s7_5_1`: a podman client of the desktop image (`podman run --device desktop.local/display=all`) opens a sink xterm titled `s751app`, which `xwininfo -root -tree` lists under its title. With the session's xterm focused first, a click at the client's centre and a typed line land in its sink, read inside its own container; its own capture (the toolkit's screenshot) is of the whole screen; it is the same container and application before and after, `restartCount` 0. `artifacts/S7.5.1/` (artifact `evidence-vm-operator`) holds the window tree, the client before and after (id, the application's host pid, restart count, start time) with the diff, the sink file, the screen with the typed line, the client's own capture, and its log.

**S7.5.2 The same under kubernetes**
- Requirement: S7.5.1 for `examples/x11-client-pod.yaml`.
- Acceptance: as S7.5.1 against the demo pod, its window found as the pod's own X client rather than by its title: EL's `/etc/bashrc` retitles an xterm whose shell is interactive at the first prompt, so the demo's `-title` does not last.
- Evidence: common set.
- Tier: T3 · Coverage: ✅ `e2e` with `guest:pod_windows`: the demo pod's xterm, found as the pod's own X client (`screenshot --list-clients` gives each client's resource base and pid; the window is the one X allocated from it), is on the screen; a QMP click at its centre and a typed line run in the pod's shell, and `/tmp/s752` holds the word; it is the same container and xterm before and after, `restartCount` 0. `artifacts/S7.5.2/` (artifact `evidence-vm-k8s`) holds the pod before and after with the diff, its X client and windows, the window tree, the QMP commands, the file the line wrote, the screen with the typed line, the pod's own capture (with its image's screenshot binary: the demo requests no toolkit), and its log.

**S7.5.3 A client window gets decoration, focus and keyboard**
- Requirement: a client window has an mwm frame, takes focus on click (frame turns the active colour) and receives keystrokes.
- Acceptance: pixel sample of the frame before/after the click; sink text.
- Evidence: EV-SHOT pair with sampled frame colours; sink file; EV-PIDS (`restartCount` or `StartedAt` and the app's pid, before and after).
- Tier: T3 · Coverage: ✅ `operator-e2e:s7_5_3`: a podman client's sink xterm sits in an mwm frame with a title bar. With the session's xterm focused, the client's frame is the inactive `#22262d`; a click at its centre turns it the active `#41637f` and the session xterm's inactive, and the keys typed next land in the client's sink; it is the same container and application before and after, `restartCount` 0. `artifacts/S7.5.3/` (artifact `evidence-vm-operator`) holds the window tree with the frame, the screens before and after the click (the sampled colours are in the checks), the sink file, the screen with the typed line, the client before and after with the diff, and its log.

**S7.5.4 A client started before the desktop is up works once it is, without restarting**
- Requirement: a pod started while `desktop.service` is stopped is admitted (specs are host state), its app retries the display, and when the desktop comes up its window appears, `restartCount` 0.
- Acceptance: stop desktop; apply a pod whose command loops on `xterm` until success; start desktop; window appears; `restartCount` 0.
- Evidence: common set; EV-LOG-CLIENT showing the retries then success; EV-VIDEO from desktop start to window appearance.
- Tier: T3 · Coverage: ✅ `e2e` "client journeys": with `desktop.service` stopped, the early pod (`ci/vm/early-pod.yaml`) is admitted and its xterm fails to open the display, try after try; once the desktop starts, its next try stays up and its window appears, and the pod is the same container, `restartCount` 0. `artifacts/S7.5.4/` (artifact `evidence-vm-k8s`) holds the stopped desktop, the xterm's tries, a video from the desktop's start until the window is on it, the screen and the pod's own screenshot, the window tree, and the pod before and after with the diff.

**S7.5.5 After an X session restart, a client container reconnects without being recreated**
- Requirement: when Xorg restarts, X clients lose their connection (that is X11); the application container itself must not need recreating: its next `xterm` connects to the new server, `restartCount` 0, same container id.
- Acceptance: pod running `sleep infinity` spawns an xterm; kill Xorg; after the session returns, the pod spawns another xterm, which appears; the pod's container id unchanged.
- Evidence: common set across the restart; EV-LOG-CLIENT (the first xterm's error on losing its server is expected and quoted); EV-VIDEO.
- Tier: T3 · Coverage: ✅ `e2e` "client journeys": the journey pod's xterm journey-1 is on the screen when Xorg is killed; it ends with its X server, its own error quoted; once the session is back, the same pod's next xterm, journey-2, appears and the pod's own screenshot reaches the new server; the pod is the same container, `restartCount` 0. `artifacts/S7.5.5/` (artifact `evidence-vm-k8s`) holds the pod and its applications before and after with the diff, both screens with the pod's own screenshots, the window trees, the first xterm's log and the video across the restart.

**S7.5.6 A client's capture matches what the operator sees**
- Requirement: EV-SHOT-CLIENT from a client matches the QEMU screendump of the same moment far better than any flipped, mirrored or rotated version of it. They may legitimately differ (a pointer drawn into one capture and not the other), so the comparison is a margin, not equality.
- Acceptance: `e2e` "screenshot" orientation/margin test (`orientation_scores`, `orientation_ok`); a missing reference or one of another size fails.
- Evidence: both images and the RMSE scores; EV-PIDS (`restartCount` or `StartedAt` and the app's pid, before and after).
- Tier: T3 · Coverage: ✅ `e2e` "screenshot" saves the client's capture, QEMU's screendump of the same moment, the four RMSE scores, and the capturing pod's restart count, container id, start time and main pid before and after, under `artifacts/S7.5.6/` (artifact `evidence-vm-k8s`); a missing or mis-sized reference fails. On the e2e VM the two images were identical (RMSE 0): virtio-vga's pointer is a hardware cursor, which neither capture includes.

**S7.5.7 Many clients share one desktop**
- Requirement: three client pods hold live connections and all three windows are on screen.
- Acceptance: `guest:verify_concurrency` with each pod's window at its own position, three client windows found in `xwininfo -root -tree`, and `screenshot --list-clients` run while all three are connected.
- Evidence: EV-SHOT with three windows; `screenshot --list-clients`; EV-PIDS (`restartCount` or `StartedAt` and the app's pid, before and after).
- Tier: T3 · Coverage: ✅ `guest:verify_concurrency`: three pods' xterms, placed at three places on the right of the screen and each found as its pod's own X client, are on the screen with none covering another, while `screenshot --list-clients` lists their connections; the three pods are the same containers throughout, `restartCount` 0. `artifacts/S7.5.7/` (artifact `evidence-vm-k8s`) holds each pod before and after with the diffs, `screenshot --list-clients`, each pod's X client and windows, the window tree, and the screen with the three windows.

### F7.6 Client application journeys: audio

**Common set**: EV-PIDS (pod `restartCount`, app pid, the three audio daemons),
`pactl list short sink-inputs source-outputs` before/during/after (EV-STATE),
EV-LOG-CLIENT (the player's output), EV-AUDIO with spectrogram, EV-TIMELINE.

**S7.6.1 A client plays and the operator hears it**
- Requirement: a pod with `desktop.local/audio` plays via pulse, PipeWire-native and ALSA, and each is heard.
- Acceptance: `guest:play_audio_pod` × 3 with frequency checks.
- Evidence: common set; three EV-AUDIO captures.
- Tier: T3 · Coverage: ✅ `e2e` with `guest:play_audio_pod` × 3: the cdi-verify pod, with only the injected env, plays 440 Hz over pulse (`paplay`), 880 Hz over PipeWire (`pw-play`) and 1320 Hz over ALSA (`aplay`), and each is heard at the machine's output at its pitch. Each player's stream is listed while it plays, found by its client's executable (`paplay` and `pw-play` run as `pacat` and `pw-cat`). The pod and the three audio daemons are the same before and after. `artifacts/S7.6.1/` (artifact `evidence-vm-k8s`) holds, per path, the streams before, during and after (pactl's short lists, and each playing stream's client: its name, executable and pid), the player's output, and the capture with its verdict and level plot; and the pod and the daemons before and after with the diffs.

**S7.6.2 A client records**
- Requirement: a pod records the sink monitor and the recording carries the tone.
- Acceptance: `guest:verify_record`.
- Evidence: EV-AUDIO-REC; EV-PIDS (`restartCount` or `StartedAt` and the app's pid, before and after).
- Tier: T3 · Coverage: ✅ `e2e` "cdi: a client can RECORD": `guest:verify_record` has the cdi-verify pod record the default sink's monitor with `parec` while a 660 Hz tone plays (S4.6.1), and the recording, copied out of the VM, carries 660 Hz by `check-audio.py`; the pod's container (`restartCount`, id, start time) and its main process's host pid before and after, their diff empty (the same container, `restartCount` 0); the recording with its verdict and level plot, under `artifacts/S7.6.2/` (artifact `evidence-vm-k8s`).

**S7.6.3 A client's playback continues through an X session restart, uninterrupted**
- Requirement: an application container playing a 20 s tone when Xorg is killed keeps playing with no gap, `restartCount` 0, same app pid.
- Acceptance: start playback at 1100 Hz from a pod; kill Xorg; capture the whole span; `check-audio.py` over the whole capture finds no stretch below −40 dBFS longer than 0.1 s and the tone's full 20 s span, its level plot marking the kill; the player is one process throughout, its stream one sink-input.
- Evidence: common set; EV-AUDIO spanning the restart with the restart timestamp marked on the spectrogram; EV-VIDEO of the display going down and back while the tone continues.
- Tier: T3 · Coverage: ✅ `e2e` "client journeys": a 20 s 1100 Hz tone from the journey pod plays while Xorg is killed about 5 s in: one player process before and after, its stream the same sink-input before, during and after, and it exits 0 within 21 s; `check-audio.py` finds the tone unbroken across the kill (no stretch below −40 dBFS longer than 0.1 s; its span within 19.6–20.6 s); the three audio daemons keep their pids, and the pod is the same container, `restartCount` 0. `artifacts/S7.6.3/` (artifact `evidence-vm-k8s`) holds the streams before, during and after, the player's record, the capture with its verdict and a level plot marking the kill, the video, the pod and the daemons before and after with the diffs, and, as in S4.5.1, the scheduling, the desktop's log and QEMU's HDA trace.

**S7.6.4 A client recovers from an audio-stack restart without being recreated**
- Requirement: when PipeWire restarts, a client's current stream ends with a clean error; the same container's next playback succeeds; `restartCount` 0.
- Acceptance: pod plays; kill pipewire; the player exits nonzero within 10 s with a connection error; after the export is back, the same pod plays again and is heard.
- Evidence: common set; EV-LOG-CLIENT quoting the error; two EV-AUDIO captures (before: tone then stop at the kill timestamp; after: tone).
- Tier: T3 · Coverage: ✅ `e2e` "client journeys": PipeWire is killed about 4 s into a 20 s 880 Hz tone from the journey pod: the player exits nonzero within 10 s with its connection error, and the capture holds the tone up to the kill and nothing after it (its span checked against the kill's time on the level plot); once the export is back, the same pod's next player is heard at 770 Hz and exits 0; the pod is the same container, `restartCount` 0. `artifacts/S7.6.4/` (artifact `evidence-vm-k8s`) holds both captures with their verdicts and level plots, the players' records with the error, the streams before, during and after, the daemons before and after, `pactl info` from the pod, and the pod before and after.

**S7.6.5 A client started before the audio stack is up plays once it is, without restarting**
- Requirement: a pod admitted while the audio export is absent retries and succeeds when the export appears; `restartCount` 0.
- Acceptance: stop desktop; apply a pod whose command loops on `paplay` until success; start desktop; a tone is heard; `restartCount` 0.
- Evidence: common set; EV-LOG-CLIENT showing retries; EV-AUDIO.
- Tier: T3 · Coverage: ✅ `e2e` "client journeys": the early pod, applied with the desktop stopped, tries `paplay` until one works: the tries fail while the audio stack is down, then its 990 Hz tone plays and is heard, its stream listed while it plays; the pod is the same container, `restartCount` 0. `artifacts/S7.6.5/` (artifact `evidence-vm-k8s`) holds the tries, the streams with the desktop down and while it played, the capture with its verdict and level plot, and the pod before and after.

**S7.6.6 A lean client with no PipeWire of its own plays and records**
- Requirement: the testclient image plays all three paths and records via the injected env alone.
- Acceptance: `e2e` lean-client loop for playback; for recording, a `parec` loopback recorded in the lean client, pulled out and analysed.
- Evidence: three EV-AUDIO; EV-AUDIO-REC; EV-PIDS (`restartCount` or `StartedAt` and the app's pid, before and after).
- Tier: T3 · Coverage: ✅ `e2e` "cdi: a LEAN non-desktop image": the testclient pod plays 440, 880 and 1320 Hz over pulse, PipeWire and ALSA with only the injected env, each heard at its pitch, and records the default sink's monitor with `parec` while a 660 Hz tone plays; the recording, copied out of the VM, carries 660 Hz. The pod is the same container throughout, `restartCount` 0. `artifacts/S7.6.6/` (artifact `evidence-vm-k8s`) holds the three captures (taken in S7.3.4) with their verdicts and level plots, the recording with its verdict and level plot, and the pod before and after with the diff.

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
- Requirement: a client xterm that had focus before the KVM-style keyboard cycle receives text typed through the re-added keyboard afterwards; the same client container, the same app pid.
- Acceptance: focus a client xterm (sink); `device_del`/`device_add` the USB keyboard; type through `kvmkbd` (S3.9.5); the client's sink file has the text.
- Evidence: common set; sink file from inside the client; EV-SHOT of the text in the client's window.
- Tier: T3 · Coverage: ✅ `operator-e2e:s7_7_1`: a podman client's xterm (holding the CDI display device, as F7.7's common set allows) takes a line typed before the USB keyboard goes. The keyboard is removed and re-added bound to `vga0`, so keys sent to the display come through it alone, and `xinput` lists it again. With no click between, the still-focused client xterm takes the line typed through it (12 key presses on its own X device). Xorg, mwm and the three audio daemons keep their pids; the client is the same container and application (`RestartCount` 0, the application's host pid and start time unchanged), still running. `artifacts/S7.7.1/` (artifact `evidence-vm-operator`) holds the client before and after with the diff (empty), the desktop's processes, F3.9's common set before and after, a video of the cycle, the keyboard's `xinput test`, the client-side sink file with both lines, the screen with them, and the client's log.

**S7.7.2 A client window is clickable with a hot-added pointer**
- Requirement: a tablet added after the client started can click into the client's window and give it focus.
- Acceptance: `device_add usb-tablet`; click via that device on the client window; frame turns active; typed text lands.
- Evidence: common set; EV-SHOT pair (frame colour); sink file.
- Tier: T3 · Coverage: ✅ `operator-e2e:s7_7_2`: a tablet plugged in after a podman client started. What the screen shows just after the plug is recorded; then the session's xterm is clicked through the boot pointer, and the client's frame reads the inactive `#22262d`. A click on the client's window through the hot-added tablet (its own X device sees the press) turns the frame the focused `#41637f`, and the keys typed next land in the client's xterm. Xorg, mwm and the three audio daemons keep their pids; the client is the same container and application (`RestartCount` 0). `artifacts/S7.7.2/` (artifact `evidence-vm-operator`) holds the client before and after with the diff (empty), the desktop's processes, F3.9's common set before and with the tablet, the screen just after the plug, before the click and after it, a video, the tablet's `xinput test`, the client-side sink file and the client's log.

**S7.7.3 Client windows stay put across a monitor plug-out and re-plug (layout declared)**
- Requirement: a client window's geometry (`xwininfo`) is identical before the connector goes down, while it is down, and after it returns; the client is not restarted.
- Acceptance: `xwininfo -id <client window>` at the three moments equal; `restartCount` 0.
- Evidence: common set; the three `xwininfo` outputs (EV-DIFF empty); EV-SHOT-CLIENT at the three moments (the client's own view is unchanged); EV-VIDEO.
- Tier: T3 · Coverage: ✅ `guest:layout_unplug`, with the host comparing the client's own captures: a podman client's xterm (holding the display and tools devices) on Virtual-1's half of the declared layout lives through S3.4.10's force. Its window's `xwininfo` is the same before, while Virtual-1 is off and after the re-plug. The client's own capture (the toolkit's screenshot), compared on the host over its window (259x82+307+534), has 0 pixels changed during and after, and 0 over the whole screen. The client is the same container and process (`RestartCount` 0); Xorg, mwm and the three audio daemons kept their pids and start times. `artifacts/S7.7.3/` (artifact `evidence-vm-core`) holds the client and the daemons before and after with the diffs (empty), the window's `xwininfo` at the three moments with the diffs (empty), the client's three captures, and its log.

**S7.7.4 A client already playing is heard on a hot-added audio device, without restarting**
- Requirement: an application container playing a continuous tone to the default sink keeps playing while a USB sound card is added; once that card becomes the default sink (WirePlumber policy, or the test sets it), the client's **existing stream** is heard on the new device; the container and the player are the same process throughout.
- Acceptance: the pod plays a 20 s 1100 Hz tone; about 4 s in, `device_add usb-audio`, and the test makes its sink the default (at full volume); `pactl list short sink-inputs` shows the client's stream now on the USB sink; `wavcapture` on the shared backend carries 1100 Hz throughout with no gap; `restartCount` 0; app pid unchanged.
- Evidence: common set; EV-AUDIO spanning the event with the `device_add` and default-change times marked on a level plot (no spectrogram tool is installed); `pactl list short sink-inputs` before and on (EV-STATE) showing the stream's sink change; `wpctl status` pair; EV-QEMU.
- Tier: T3 · Coverage: ✅ `e2e` "client journeys: the pod's audio across hot-added sound cards (F7.7)": the journey pod, running since the journeys began, plays a 20 s 1100 Hz tone; about 4 s in a USB card arrives and its sink is made the default. The pod's existing sink-input moves onto the card's sink; one player process plays before and after and exits 0 after 20.11 s. The capture carries the tone across the arrival with no stretch below -40 dBFS longer than 0.1 s and its whole 20 s span present. Xorg, mwm and the three audio daemons keep their pids, and the pod is the same container, `restartCount` 0. `operator-e2e:s11_3_1` asserts the move for a podman client too: its stream follows `wpctl set-default` onto a hot-added USB card with no drop longer than 0.5 s, and the player is not restarted. `artifacts/S7.7.4/` (artifact `evidence-vm-k8s`) holds the pod, the player and the daemons before and after with the diffs, the streams before and on, F4.7's device set before and on with the diffs, QEMU's reply, a video of the arrival, the player's log, and the capture with its verdict and the level plot marking the plug.

**S7.7.5 A client playing on the hot-added device survives its removal**
- Requirement: with the client's stream on the USB sink, `device_del` moves the stream back to the built-in sink (or ends it cleanly); the client is not restarted; its next playback is heard.
- Acceptance: continuation of S7.7.4: `device_del`; `pactl list short sink-inputs` shows the stream on the built-in sink or gone with a clean client error; capture continues or resumes; `restartCount` 0.
- Evidence: common set; EV-AUDIO continuing from S7.7.4 with the removal timestamp marked; EV-LOG-CLIENT.
- Tier: T3 · Coverage: ✅ `e2e` "client journeys: the pod's audio across hot-added sound cards (F7.7)": the pod's 20 s 880 Hz tone plays on the USB card, and the card is removed about 4 s in. Within 10 s its sink-input moves to the built-in card's sink, and the same player plays on to its end and exits 0. The capture carries the tone through the removal with no quiet stretch longer than 1 s and at most 1.5 s of the 20 lost. The pod's next tone, 660 Hz, is heard, its player exiting 0. Xorg, mwm and the three audio daemons keep their pids, and the pod is the same container, `restartCount` 0. `artifacts/S7.7.5/` (artifact `evidence-vm-k8s`) holds the pod and the daemons before and after with the diffs, the streams and sinks before and after the removal, F4.7's device set plugged in and after with the diffs, QEMU's reply, a video, both players' logs, and both captures with their verdicts and level plots (the removal marked).

**S7.7.6 A client started while the hot-added device is present can target it by name**
- Requirement: a new client can `pw-play --target` / `PULSE_SINK=<usb sink>` and be heard on it.
- Acceptance: as stated with a 990 Hz tone.
- Evidence: EV-AUDIO; `pactl list short sink-inputs` naming the sink; EV-PIDS (`restartCount` or `StartedAt` and the app's pid, before and after).
- Tier: T3 · Coverage: ✅ `e2e` "client journeys: the pod's audio across hot-added sound cards (F7.7)": with the USB card present, the default is the built-in card, muted, and the USB card is at full volume. A new player in the pod, `PULSE_SINK=<the USB card's sink> paplay`, plays 990 Hz: its sink-input sits on that sink and it exits 0, and the tone is heard, so the USB card rendered it. The pod is the same container, `restartCount` 0. `artifacts/S7.7.6/` (artifact `evidence-vm-k8s`) holds `wpctl status` (the default and its mute), the streams and sinks while it played, the player's log, the capture with its verdict and level plot, and the pod before and after with the diff (empty).

**S7.7.7 A client records from a hot-added capture device without restarting**
- Requirement: a running pod can open the new source and deliver frames.
- Acceptance: S4.7.8/S4.7.9 from a pod that was running before the hot-add.
- Evidence: common set; EV-AUDIO-REC.
- Tier: T3 · Coverage: ✅ `e2e` "client journeys: the pod's audio across hot-added sound cards (F7.7)": an AC97 card is hot-added under the journey pod, which has run since before it arrived, and brings a capture source. The pod opens it with `parecord`, which exits 0 and delivers 2.90 s of frames at 44.1 kHz stereo (silence: QEMU's `none` audiodev captures nothing else); removed, the card's source leaves with it. Xorg, mwm and the three audio daemons keep their pids, and the pod is the same container, `restartCount` 0. What a real microphone records into a client is S8.3.1's, on hardware. `artifacts/S7.7.7/` (artifact `evidence-vm-k8s`) holds `modinfo`'s answer for the candidate drivers, the pod and the daemons before and after with the diffs, F4.7's device set before, plugged in and after with the diffs, QEMU's replies, a video, the recorder's log, the recording and its frames, duration, format and peak.

**S7.7.8 A client survives the KVM composite event**
- Requirement: a client xterm and a client audio stream both continue across S3.11.1; afterwards the xterm takes typed text through the re-added keyboard and the stream is still heard; both clients unrestarted (`restartCount` 0).
- Acceptance: S3.11.1 with two client containers in play.
- Evidence: common set for both clients; EV-AUDIO spanning the event; EV-SHOT of typed text.
- Tier: T3 · Coverage: ✅ `operator-e2e:s7_7_8`: two podman clients, an xterm and a player of a 1100 Hz tone, through the KVM switch. The stream plays on the KVM's USB card before the switch; the keyboard, tablet and sound card leave together and come back, every count back to its value before. Afterwards the stream is still playing, on the returned card, and the capture's end carries it (median level 0.0301; -40 dBFS is 0.01). The xterm takes the line typed through the returned keyboard (12 key presses on its own X device). Xorg keeps its pid; both clients are the same containers and applications (`RestartCount` 0), still running. `artifacts/S7.7.8/` (artifact `evidence-vm-operator`) holds both clients before and after with the diffs (empty) and their logs, the desktop's processes, F3.9's and F4.7's common sets away, the counter tables, a video, the capture through the switch with its tail level, the streams after, the keyboard's `xinput test`, the client-side sink file and the screen with the typed line.

**S7.7.9 A client that started on a soundless host plays once a card arrives, without restarting**
- Requirement: on the no-`intel-hda` profile, a pod whose player loops until success starts before any card exists; after `usb-audio` is added and the stack re-aligns, the tone is heard; `restartCount` 0.
- Acceptance: S2.4.6 with the pod in play.
- Evidence: common set; EV-LOG-CLIENT (retries then success); EV-LOG-DESKTOP align lines; EV-AUDIO.
- Tier: T3 · Coverage: ✅ `guest:soundless`: a podman client stands in for the pod, as F7.7's common set allows (the soundless shard runs no cluster): the testclient image holding the CDI audio device, its shell looping once a second until a sink other than `auto_null` is listed and `paplay` of its tone succeeds. It starts before any card exists. Its first tries find no card's sink (`auto_null`), then the stack's restart refuses them; once the card is there and the stack has re-aligned it plays (after 10 failed tries in run 37390904377), and its 550 Hz tone is heard. It is the same container and process throughout: id, pid and start unchanged, `RestartCount` 0, still running. Xorg and mwm are the same processes across the card's arrival and the stack's restart; the three audio daemons are new, by design. Under `artifacts/S7.7.9/` (artifact `evidence-vm-soundless`): the client's command; its EV-PIDS before and after; Xorg, mwm and the audio daemons before and after, with their diff; its early and whole logs; the tone with its verdict; and the EV-VIDEO of the display from before the card was plugged in until after the client played (2 fps, `index.txt` timed). The align lines are under `artifacts/S2.4.6/`.

### F7.8 Desktop lifecycle as seen by running clients

**S7.8.1 A `desktop.service` restart does not recreate client pods**
- Requirement: client pods lose their X connection and audio stream (expected), are not restarted by kubernetes, and work again against the new desktop with the same container id.
- Acceptance: pods running `sleep infinity` with child apps; `systemctl restart desktop.service`; `restartCount` 0, container id unchanged; new xterm and new tone succeed.
- Evidence: common set from F7.7; EV-SHOT after; EV-AUDIO after; EV-LOG-CLIENT quoting the expected disconnect messages.
- Tier: T3 · Coverage: ✅ `e2e` "client journeys": `systemctl restart desktop.service` under the journey pod: its xterm journey-3 loses its X connection and its 30 s player its stream, both expected and quoted; then a new xterm from the same pod, journey-4, appears and a new 660 Hz tone from it is heard; the pod is the same container, `restartCount` 0, its container id unchanged. `artifacts/S7.8.1/` (artifact `evidence-vm-k8s`) holds the pod, its applications and the daemons before and after with the diffs, the streams, the disconnect messages, a video across the restart, the screen after, and the capture with its verdict and level plot.

**S7.8.2 Toolkit republish under a running client is harmless**
- Requirement: a client that has the toolkit mounted keeps a working `screenshot` across a desktop restart (new inode, old mapping intact).
- Acceptance: run `screenshot` in a loop from a pod across the restart; every invocation after the desktop is back succeeds; none fails with `ETXTBSY`/`Text file busy` on the desktop side (EV-LOG-DESKTOP has `published screenshot`).
- Evidence: the loop's log (EV-LOG-CLIENT); `ls -li` of the published binary before/after; EV-LOG-DESKTOP; EV-PIDS (`restartCount` or `StartedAt` and the app's pid, before and after).
- Tier: T3 · Coverage: ✅ `e2e` "client journeys": across `desktop.service`'s restart, a screenshot held mid-write in the pod (its PNG larger than a pipe holds) keeps running from the replaced binary, its executable `(deleted)` at the old inode while the toolkit file has a new one, and, released, writes its PNG and exits 0; a screenshot loop in the pod fails while the desktop is down and succeeds on every try once it is back, as one process; the restarted desktop logs `published screenshot`, with no `Text file busy`; the pod is the same container, `restartCount` 0. `artifacts/S7.8.2/` (artifact `evidence-vm-k8s`) holds `ls -li` of the toolkit in the pod before and after with the diff, the held screenshot's state before and after and its release, the loop's log, the desktop's publish lines, and the pod before and after.

**S7.8.3 Socket recreation does not invalidate client mounts**
- Requirement: because the CDI mounts are directories, a client's `/tmp/.X11-unix` and `/run/desktop-audio` show the **new** sockets after Xorg or PipeWire recreate them.
- Acceptance: `ls -li` of both dirs from inside a long-running pod before and after the respective restart: each socket is new, its change time after the kill (the inode number is no proof: the filesystem may reuse it, as XFS did for X0), the pod sees the new ones, and connects.
- Evidence: the two `ls -li` pairs from inside the pod (EV-DIFF); `xdpyinfo`/`pactl info` from the pod after; EV-PIDS (`restartCount` or `StartedAt` and the app's pid, before and after).
- Tier: T3 · Coverage: ✅ `e2e` "client journeys": inside the journey pod, `/tmp/.X11-unix/X0` after Xorg's restart and `/run/desktop-audio/pulse` after PipeWire's are new sockets, each changed after its kill, and the pod connects through each (`xdpyinfo`, `pactl info`); the pod is the same container across both, `restartCount` 0. XFS reused X0's inode number, so the change time is the proof. `artifacts/S7.8.3/` (artifact `evidence-vm-k8s`) holds `ls -li` of both directories from inside the pod before and after with the diffs, each socket's inode and change time, `xdpyinfo` and `pactl info` from the pod, and the pod before and after each restart.

---

## E8 — Hardware-only behaviours (manual acceptance)

Evidence for every story here needs a person: EV-PHOTO of the screen,
EV-PHONEVIDEO of the physical action with the screen (and where relevant the
speakers) in frame, plus the same EV-STATE / EV-LOG pairs the automated stories
use. `ci/hw/acceptance.sh` (Appendix C) collects them: it saves the state and
the logs itself, asks the tester for each photo and video, and keeps every
story's evidence with the tester's name and the date. `HotpluggingTestHelp.md`
§6 has the wider hardware table. A T4 result without a photo or video is a
note, not evidence.

### F8.1 NVIDIA GPU mode

**S8.1.1 NVIDIA GPU mode**
- Requirement: with the driver and a toolkit that ships `nvidia_drv.so`: real CDI spec, `Driver "nvidia"`, `glxinfo -B` reports NVIDIA, preflight `PASS: NVIDIA GPU injected together with X driver module`; the operator sees an accelerated desktop.
- Evidence: EV-PHOTO; `glxinfo -B`, `head -5 /etc/cdi/nvidia.yaml`, `20-gpu.conf`, preflight block (EV-STATE/EV-CONFIG).
- Tier: T4 · Coverage: 🔧 `ci/hw/acceptance.sh run S8.1.1` (Appendix C), not yet run on hardware. One run with S3.1.1, on an NVIDIA host whose toolkit injects the X driver: `/proc/cmdline` and `nvidia_drm`'s modeset parameter, `nvidia-smi` and the NVIDIA packages, `head -5 /etc/cdi/nvidia.yaml` (a real spec, not the stub), `20-gpu.conf` (`Driver "nvidia"`), the container preflight's `PASS: NVIDIA GPU injected together with X driver module`, `glxinfo -B` reporting NVIDIA, the unit's `Image=` and NVIDIA lines, and `desktop-preflight`; the tester confirms the desktop on the monitor, and an EV-PHOTO of it.

**S8.1.2 NVIDIA host with missing/broken toolkit**
- Requirement: stub spec, modesetting desktop comes up, both preflights FAIL on "stub + hardware".
- Evidence: EV-PHOTO of the (working) desktop; both preflight outputs with the FAIL rows; the stub spec.
- Tier: T4 · Coverage: 🔧 `ci/hw/acceptance.sh run S8.1.2` (Appendix C), not yet run on hardware. On an NVIDIA host, a missing toolkit staged if the tester agrees (`nvidia-ctk` set aside, the real spec moved away): `desktop-cdi-refresh` writes the stub, its journal and the stub kept; after a restart the desktop is on modesetting; `desktop-preflight` FAILs `STUB CDI spec but NVIDIA hardware present` and the container preflight `NVIDIA hardware visible but the host injected a STUB CDI spec`; the tester confirms a working desktop, and an EV-PHOTO of it. Undone: the toolkit back and a real spec regenerated.

**S8.1.3 NVIDIA host without `nvidia_drm.modeset=1` and no injection**
- Requirement: preflight `FAIL: no /dev/dri/card* visible` with the kernel-cmdline hint.
- Evidence: `cat /proc/cmdline`, `ls /dev/dri`, the preflight row.
- Tier: T4 · Coverage: 🔧 `ci/hw/acceptance.sh run S8.1.3` (Appendix C), not yet run on hardware, three times across two reboots. On an NVIDIA-only host: `nvidia_drm.modeset=0` on the default kernel's command line (`grubby`), `nvidia-ctk` set aside and the real spec moved away, then a reboot. After it: `/proc/cmdline` and the modeset parameter, `ls -l /dev/dri` with no `card*`, the stub spec, the container preflight's `FAIL: no /dev/dri/card* visible` with its `nvidia_drm.modeset=1` hint, and `desktop-preflight`. Then everything is put back and the host reboots; the third run checks it is in NVIDIA mode again.

**S8.1.4 Old toolkit without `nvidia_drv.so`**
- Requirement: preflight `WARN: nvidia_drv.so NOT injected`; the documented bind-mount fallback restores NVIDIA mode.
- Evidence: preflight before/after the drop-in (EV-DIFF); `systemctl cat desktop.service` showing the merged `Volume=` lines; `glxinfo -B` after.
- Tier: T4 · Coverage: 🔧 `ci/hw/acceptance.sh run S8.1.4` (Appendix C), not yet run on hardware. One run with S3.1.2, from its state without the X driver: the container preflight's `WARN: NVIDIA device nodes present but nvidia_drv.so NOT injected`; `README.md`'s "nvidia_drv.so missing" entry read out of the document; its fallback, the quadlet's commented `Volume=` lines, written as a drop-in, then `systemctl daemon-reload`: the generated unit's `ExecStart` carries them as `-v` (quadlet merges drop-ins from podman 5.0; the comments it copies into the unit, the commented lines among them, do not count). After a restart `glxinfo -B` reports NVIDIA again and the container preflight PASSes the injection, the preflight before and after diffed. Undone: the drop-in removed and the desktop back as it was.

### F8.2 Physical KVM switch and monitors

**S8.2.1 Physical KVM: input**
- Requirement: a non-HID-emulating USB KVM switched away and back leaves keyboard and mouse working without a service restart, on the first switch back and on the tenth.
- Evidence: EV-PHONEVIDEO of the switch and of typing afterwards; `ls /dev/input/by-id` before/after (EV-DIFF showing re-enumeration); `xinput list` pair; `podman logs desktop` has no restart in the window (EV-LOG-DESKTOP); the KVM model stated.
- Tier: T4 · Coverage: 🔧 `e2e` "KVM switch simulation: remove the keyboard and bring it back" covers one USB keyboard re-enumeration, with typing working afterwards and no restart. `ci/hw/acceptance.sh run S8.2.1` (Appendix C), not yet run on hardware: ten KVM switches (`HW_SWITCHES`), the KVM's make and model kept. Before and after: `ls -l /dev/input/by-id`, `/dev/input` in the desktop and `xinput list`, each pair diffed; `udevadm monitor` of input events through the switches; the container, Xorg and mwm the same throughout, and no session restart in the desktop log. After the first switch back and after the tenth, a word the script picks, typed through the KVM into a sink xterm, must arrive exactly, and the tester confirms the mouse moves the pointer and clicks (mwm may focus a new window by itself, so the typing does not prove the mouse). EV-PHONEVIDEO of the switching and typing.

**S8.2.2 Physical KVM: video, modesetting and NVIDIA**
- Requirement: with a declared layout, `xrandr` geometry and window positions are unchanged across a switch cycle; the panel shows the picture after link retraining.
- Evidence: EV-PHONEVIDEO with the monitor in frame through the whole cycle; `xrandr --query` and `xwininfo -root -tree` before/after (EV-DIFF empty); `cat /sys/class/drm/card*-*/status` during the away period; EV-LOG-XORG connector lines.
- Tier: T4 · Coverage: 🔧 `guest:layout_unplug` forces a connector off under a running X and asserts the declared geometry holds. `ci/hw/acceptance.sh run S8.2.2` (Appendix C), not yet run on hardware, with S8.2.3's layout declared, on whichever driver the desktop runs (S3.4.5's run is the same cycle on NVIDIA): `20-gpu.conf` and `monitors.conf`; `xrandr --query` and `xwininfo -root -tree` before and after the switch away and back, each pair's diff required empty; `cat /sys/class/drm/card*-*/status` every 2 s through the away period; the Xorg log's lines from the cycle; the tester confirms the panel shows the picture again after the link retrained; EV-PHONEVIDEO of the cycle.

**S8.2.3 Real EDID and `desktop-monitors-capture`**
- Requirement: the capture tool prints the real output names and rates; pasting them yields the same arrangement after restart.
- Evidence: the tool's output; `monitors.conf` as installed; `xrandr` before/after the restart (EV-DIFF empty); `cat /sys/class/drm/*/edid | edid-decode` (EV-STATE).
- Tier: T4 · Coverage: 🔧 `ci/hw/acceptance.sh run S8.2.3` (Appendix C), not yet run on hardware: `desktop-monitors-capture`'s output, which the tester confirms names this desk's monitors and rates, installed as `monitors.conf` as it is; after `systemctl restart desktop.service`, each connected output's name, primary flag and geometry from `xrandr --query` must be the same as autodetected before. The full diff is kept and need not be empty: the declared layout's modes may be named differently from the EDID's. Also `xorg-monitor-conf`'s lines and every connected monitor's EDID (`edid-decode`, or hex when it is not installed). The tester decides whether the layout stays installed for the KVM stories.

### F8.3 Audio hardware and long-run behaviour

**S8.3.1 USB audio devices**
- Requirement: a USB headset/DAC plugged in after boot appears in `wpctl status` and is audible; its microphone records from a client; unplugging returns sound to the speakers; a client application playing throughout is not restarted.
- Evidence: EV-PHONEVIDEO with audible output from the device; `wpctl status` pair (EV-DIFF); EV-AUDIO-REC of speech into the device's microphone from a client pod; the pod's `restartCount` (EV-PIDS).
- Tier: T4 · Coverage: 🔧 `e2e` "audio hotplug: plug and unplug a USB sound card while the desktop runs" covers plug and unplug with QEMU's `usb-audio`. `ci/hw/acceptance.sh run S8.3.1` (Appendix C), not yet run on hardware, with the probe image loaded: a podman client of it, holding `desktop.local/audio=all`, plays a 440 Hz tone on a loop throughout (standing in for the pod, as F7.7's common set allows). The device plugged in: `wpctl status` lists it (diffed against before), the default sink is set to it, the tester confirms the tone from it, and EV-PHONEVIDEO. Where the device has a microphone, a client records 6 s from it while the tester speaks (EV-AUDIO-REC, peak at least 2% of full scale); a device without one, a DAC, is noted and not recorded. Unplugged: `wpctl status` lists the devices from before, and the tester confirms the tone back on the speakers. The client is the same container throughout, with 0 restarts.

**S8.3.2 Long-run log bound**
- Requirement: over days of uptime the container log never exceeds ~64 MB.
- Evidence: `ls -l` of the log file daily (EV-STATE table); `podman inspect` LogConfig.
- Tier: T4 · Coverage: 🔧 `smoke` and `guest:verify_log_bounds` assert the 64 MB bound is set on the running container. `ci/hw/acceptance.sh S8.3.2 sample` (Appendix C), daily from cron, adds a row to a table (time, uptime, the container's start, the log's size), each sample a check within ~64 MB; `ci/hw/acceptance.sh run S8.3.2`, after 48 h or more, requires three samples or more over 48 h or more of uptime, the largest within ~64 MB, and the running container's `LogConfig` carrying the bound. Not yet run on hardware.

---

## E9 — Test-suite quality requirements (cross-cutting)

These govern every test written against the stories in this document (E10
and E11, which follow, included); the suite's own history (see comments in
`ci/`) is the reason each exists.

`ci/e9-guard.py`, in the static job, holds the rules that a read of the tree
can check: S9.1.3, S9.1.5, S9.2.1, S9.2.2, S9.2.4 and S9.3.1's static half,
each as its own story with its own evidence. Nothing checks the others yet;
their Coverage lines say what holds them today.

### F9.1 Assertion discipline

**S9.1.1 Every assertion has been seen to fail**
- Requirement: a new assertion is verified against a deliberate mutation before it is merged.
- Acceptance: the PR description names the mutation.
- Tier: T0 · Coverage: ❌ no check reads a pull request's description: the repository has no PR template, and no workflow reads the event's body. The static guards hold the rule for themselves: `ci/client-guard.py`, `ci/e9-guard.py`, `ci/script-list.py` and `ci/layout-keywords.py` each run a self-test first that plants what their checks must flag.

**S9.1.2 Assert generated output, not source text**
- Requirement: quadlet/CDI/config assertions read the *generated* artefact, anchored so comments cannot match.
- Tier: T0 · Coverage: ❌ no check finds an assertion that reads source text, or one that a comment in a generated file could satisfy. Some reads are anchored by construction: `ci.yml`'s quadlet dry-run and `ci/unit-directives.py` read the generated unit's directives and skip its comments, and `ci/hw/acceptance.sh` reads the generated unit's `ExecStart` (S8.1.4). An audit of the tree found `ci/helm-assertions.sh` reading the CDI kinds from the generator's source text, and about a hundred greps over generated files that carry comments (the CDI specs, `30-monitors.conf`, `20-gpu.conf`, the chart's rendered output) that a comment could match, though none does today.

**S9.1.3 Read the container's init, never `/proc/1`**
- Requirement: under `--pid=host`, process-level assertions use `/run/desktop-init.pid`.
- Tier: T0 · Coverage: ✅ `ci/e9-guard.py --rule S9.1.3`, run by the static job, reads every shell script and Python file under `ci/` for `/proc/1`, `pidof`, and `pgrep` or `ps -C` of `desktop-init`, and finds each such read to be one its ALLOW list names, with the reason: a client container's own pid 1 (op-observer, S7.7.3's client, S10.3.4's client, `operator-e2e.py`'s client capture), the host's pid 1 on purpose (its cgroup namespace compared with the container's), the reads of the host's pid 1 that S6.2.1 requires container root to be refused, and one listing by name kept as S10.2.2's evidence beside the pid file's. Its self-test flags a planted `/proc/1` read and a `pidof`, passes a read of `/run/desktop-init.pid`, and requires each ALLOW entry to still excuse a line. The guard's output is under `artifacts/S9.1.3/` (artifact `evidence-static`).

**S9.1.4 Poll log lines; read live state once**
- Requirement: a log-line assertion is polled; process/socket state may be read directly.
- Tier: T0 · Coverage: ❌ no check finds a log line read once where it must be polled. Some reads poll (`vm-guest.sh` polls the journal where it documents the journal's lag), but an audit counted about 43 one-shot reads of `podman logs`, `journalctl` or `kubectl logs` that feed an assertion, 16 of them confirmed by reading the code.

**S9.1.5 No early-exiting reader (`grep -q`, `grep -m`, `head`) on a live pipeline under `pipefail`**
- Requirement: capture output to a variable first.
- Tier: T0 · Coverage: ✅ `ci/e9-guard.py --rule S9.1.5`, run by the static job, reads every shell script under `ci/` and every workflow `run:` block the way the shell does (quotes, comments, heredoc bodies, `case` patterns, `$(…)` nesting). It knows where `pipefail` is on: a script's own `set`, the sourcing script's for `maint-e2e.sh`, `maint-guest.sh` and `evidence.sh`, `acceptance-tests.sh`'s from the line that sources `acceptance.sh`, and a workflow step's `shell: bash` or its own `set`. It finds no reader that can stop early (`grep -q`/`-m`/`-l`, `head`, `sed …q`, `awk …exit`, `read`, `cmp`, a loop that breaks, python that exits) on a live pipeline under it; a print of a variable already captured, the requirement's own remedy, passes. Its self-test flags planted pipes into `grep -q`, `head`, `awk …exit` and a loop that breaks, and passes a here-string, a pipe inside a quoted `sh -c`, a print of a captured variable, a pipe in a comment, a `case` pattern, `grep -c`, `head -n -1` and a script without `pipefail`. It flagged 75 such pipes before the harness was rewritten to capture first. The guard's output is under `artifacts/S9.1.5/` (artifact `evidence-static`).

### F9.2 Fixture and environment discipline

**S9.2.1 Nothing weakens the system under test**
- Requirement: no `setenforce`, no `label=disable`, no `--privileged` on clients, no `-v`/`-e` that duplicates a CDI edit (except `-e` on a `podman exec` into a CDI client, with the value read from that container's PID 1: podman applies a CDI device's env edits only to the process the container starts with), no test-only quadlet changes.
- Tier: T0 · Coverage: ✅ `ci/e9-guard.py --rule S9.2.1`, run by the static job, reads every shell script under `ci/` and every workflow `run:` block, with the command lines quoted inside them (`ssh`, `sh -c`, `undo_later`), every Python file and every pod manifest. It finds no `setenforce`; no `--privileged` or `label=disable` on a `podman run`, `create` or `exec` (`ci/client-guard.py`'s checks of the Python and the manifests included); no `-e` or `-v` that duplicates an edit of a CDI device the container requests, the edits read from the generators' spec templates (display: `DISPLAY`, `/tmp/.X11-unix`; audio: `PULSE_SERVER`, `PIPEWIRE_REMOTE`, `/run/desktop-audio`; tools: `DESKTOP_TOOLS_BIN`, `/opt/desktop-tools/bin`; `nvidia.com/gpu`: `NVIDIA_CDI_STUB`); an `-e` of one of those variables into a container other than the desktop only with a value read from that container's own `/proc/1/environ`; and no write under `/etc/containers/systemd` but the documented procedures its ALLOW list names (`README.md`'s NVIDIA fallback drop-in, S8.1.4; `deploy/README.md`'s image pin, S5.2.6 and S10.3.3, and its Host Terminal off-switch, S5.7.7 and S10.3.5). Options a shell array holds are not seen. Its self-test flags ten planted violations, one inside an `ssh` string and one in a workflow, and passes three allowed forms. Two violations it found are fixed: `operator-e2e.py`'s probes passed `-e DISPLAY=:0` into the observer, and S5.11.2's stub case set `NVIDIA_CDI_STUB=1` by `-e`. The guard's output is under `artifacts/S9.2.1/` (artifact `evidence-static`).

**S9.2.2 Narrow fixtures stay narrow**
- Requirement: `display-only`/`audio-only` request exactly one resource; verifier pods declare nothing but requests.
- Tier: T0 · Coverage: ✅ `ci/e9-guard.py --rule S9.2.2`, run by the static job, reads every pod manifest (`examples/*.yaml`, `ci/vm/*-pod.yaml`) by indentation: no pod declares `securityContext`, `volumes`, `hostNetwork`, `hostPID`, `hostIPC` or `annotations`; each container declares only `name`, `image`, `imagePullPolicy`, `command`, `args`, `resources` and `workingDir`; and each `*-only` pod requests exactly one `desktop.local` resource. Its self-test flags a narrow pod that requests two resources and a pod with `env`, and passes a narrow pod whose comment names `env:`. `ci/helm-assertions.sh` (S7.3.3) checks the same manifests from its own list. The guard's output is under `artifacts/S9.2.2/` (artifact `evidence-static`).

**S9.2.3 Failures are diagnosable from the job log**
- Requirement: every failure handler tees diagnostics to stdout as well as to an artifact; the failing message is repeated last.
- Tier: T0 · Coverage: ❌ no check that a failure is diagnosable from the job log. `vm-guest.sh`'s `fail` prints its diagnostics to the log and into the open story's evidence, and repeats the message last; an audit found 23 places where a failing command ends a shell script under `errexit` with no message, about 9 checks in `ci.yml` that fail without one, and three failure handlers missing a part.

**S9.2.4 Probes yield integers, or fail**
- Requirement: a count read from the guest is an integer, or a failed read: a poll retries it, a one-shot read fails the story with a message. No number stands in for a failed read: a `0` for one can pass a check that a count dropped, or start a log slice at the top of the log.
- Tier: T0 · Coverage: ✅ `ci/e9-guard.py --rule S9.2.4`, run by the static job, follows each variable a shell script assigns from an ssh reader (`vm_ssh`, `vm_ssh_quick`, `gq`, `gqw`, `guest_ev`, `ssh`) within its function. It flags a number standing in for a failed read (`|| echo 0` on the read, `${n:-0}` in a comparison) and a numeric use with no check, and passes a read whose failure fails (`|| fail`, `|| return`) or one tested for presence before it is compared; in the Python, it flags an `int()` of a guest read outside a `try`, or in one whose handler returns a number. `vm-e2e.sh` reads its counts and Xorg log offsets through `host_count` and `read_pair`, an integer or status 1, and `operator-e2e.py` through `guest_count`, which retries three times and then fails the story. Its self-test flags each stand-in, an unchecked comparison, arithmetic in a loop and an `int()` with no `try`, and passes a guarded read, the same name in another function, a presence test and an `int()` whose failure yields `None`. On the tree before the harness was rewritten it finds 42: 28 unchecked comparisons, 5 `int()`s with no `try`, and 9 stand-ins, five of them Xorg log offsets and one a wait that took a failed read for a count of 0. The guard's output is under `artifacts/S9.2.4/` (artifact `evidence-static`).

**S9.2.5 Restore what you changed**
- Requirement: a test that writes host config restores the shipped state and *asserts* the restore took effect.
- Tier: T0 · Coverage: ❌ no check that a test restores what it changed and asserts the restore. Some do both (S5.2.6 removes its drop-in, restarts the desktop and checks it runs `:latest` again), but an audit found four restores that are not asserted, in `ci.yml`, `smoke-deploy.sh`, `vm-guest.sh` and `operator-e2e.py`.

**S9.2.6 Documented procedures are run from the document**
- Requirement: a test of a documented maintainer procedure extracts the block from the document at the run's git sha and runs it unmodified; placeholders are the only substitutions, each listed in the index; a harness step interleaved with the procedure is named there as harness-only. A procedure retyped into the harness tests the harness, and drifts from the document unnoticed.
- Tier: T0 · Coverage: ❌ no check that a documented procedure is run from the document. The maintainer journeys and `ci/hw/acceptance.sh` run theirs that way (`ci/doc-blocks.py` extracts each block at the run's commit, and a moved heading or block fails the run), but an audit found five places where the harness retypes a documented procedure, or interleaves its own steps without naming them harness-only: `smoke-deploy.sh` twice, `maint-guest.sh` twice and `vm-guest.sh` once.

### F9.3 Evidence discipline

**S9.3.1 Every story emits its named evidence on pass and on fail**
- Requirement: a story's test writes `artifacts/<story>/evidence.md` and the files it names, whichever way the assertion went; a missing evidence file fails the run.
- Acceptance: a post-run check lists every executed story id and every file its `evidence.md` references, and each exists and is non-empty.
- Tier: T0 · Coverage: ✅ at run time, `ci/evlib.py`'s `check` and `gate` (`ci.yml`'s `coverage-gate` job, `maintainer.yml`'s gate, `base-rebuild.yml`'s check) require each story directory's `evidence.md`, `meta.tsv`, `result` and every file its index names, present and non-empty, nothing unindexed, and fail a FAIL result; a failing story still writes its directory (the shell's `fail` ends the open story through `ev_abort`, and `operator-e2e.py` finishes a failed story with its error). At T0, `ci/e9-guard.py --rule S9.3.1` checks that every story id the harness begins (`ev_begin`, `story_begin`, `mt_begin`, a story id in the Python) is one this document defines, and that `check_dir` fails each of five incomplete directories (an indexed file missing, one empty, a file nothing indexes, no `result`, no `evidence.md`) and passes a complete one. A story that runs without ever beginning its directory is caught only if it is marked ✅. The guard's output is under `artifacts/S9.3.1/` (artifact `evidence-static`).

**S9.3.2 Before/after pairs are diffed, not eyeballed**
- Requirement: every EV-STATE pair ships with its `diff -u`, and the index states which lines are expected to differ.
- Tier: T0 · Coverage: ❌ no check that each before/after pair has its diff: the harness makes one with `ev_diff` (`ci/evidence.sh`) where it calls it, and the gate does not look for pairs without one.

**S9.3.3 "No restart" is measured**
- Requirement: a claim that a container or process survived an event carries its container id / `restartCount` / pid before and after.
- Tier: T0 · Coverage: ❌ no check: nothing lists the stories that claim a survival, or checks that each carries the container id, restart count and pids from before and after.

**S9.3.4 Audio evidence is audible and visible**
- Requirement: every EV-AUDIO/EV-AUDIO-REC is a WAV plus a spectrogram (or, where no spectrogram tool is installed, the harness's level plot at the story's pitch with each event marked) plus the analyser verdict; distinct frequencies per source as listed in the evidence standard.
- Tier: T0 · Coverage: ❌ no check. The VM harness's audio helpers save the WAV, the level plot and the analyser's verdict together (`ev_audio_stop` and `ev_audio_check` in `vm-e2e.sh`, `tone_to` in `operator-e2e.py`), but nothing checks that every recording goes through them; an audit found one that does not, `maint-e2e.sh`'s `mt_heard`, with a verdict and no plot.

**S9.3.5 Video covers every dynamic step**
- Requirement: any story whose event changes the screen over time (a restart, a reflow, a display or input hotplug) attaches an EV-VIDEO with the event frames named in the index.
- Tier: T0 · Coverage: ❌ no check: nothing lists the stories whose event changes the screen over time, or checks that each attaches an EV-VIDEO with its event frames named.

**S9.3.6 The timeline is the spine**
- Requirement: every harness action is appended to `timeline.log` with an ISO timestamp, and every evidence file name appears in the timeline at the moment it was captured.
- Tier: T0 · Coverage: ❌ no check. Each evidence file is logged to `timeline.log` as it is attached (`ev_attach`; `StoryWriter`), but the harness's transport actions (`vm_ssh`, the QEMU monitor's commands) are not, and nothing checks either.

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

Several of these procedures, read side by side with the code, looked broken.
`maintainer.yml` now runs every T3 story here, each in its own stock VM, the
documents' commands read out of them (`ci/doc-blocks.py`) and run as written.
Where a prediction held, the story's coverage note says what the journey found
and names the fix it led to.

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
- Tier: T3 · Coverage: ✅ (workflow `maintainer.yml`) `maint-docpath`, on two stock hosts: `deploy/HOST-REQUIRES.md`'s "Every host" line, read out of the file and run unmodified as root at a terminal (dnf's questions answered y); every package it names installed; the journey's own tools (`rsync`, the players) installed apart and kept apart in the evidence. After S10.1.2's Apply block and reboot: `desktop-preflight` exits 0 with no `WARN:` line; the container's `ssh host` is `desktop-shell`; the desktop user's host session runs no PipeWire or WirePlumber unit; and an ordinary user's `paplay` (440 Hz) and `aplay` (1320 Hz), nothing set in their environment, exit 0 and are heard. The journey found the documented line itself bringing a second PipeWire onto the host: `alsa-plugins-pulseaudio` pulls in `pipewire-pulseaudio` and `wireplumber`, whose user units systemd's presets enable for every user, so the desktop user's host session listened on the paths the container's PipeWire serves, and the session's first `paplay` never finished. `claude/fix-host-pipewire-masks` masks the five user units in the tree. Under `artifacts/S10.1.1/` (artifact `evidence-vm-maint-docpath`; the second host under `host-b/`): the stock host, `rpm -qa` before and after the documented line and after the journey's tools (EV-DIFF each), the block and dnf's transcript, the preflight, the container's `ssh host`, the user units, and both players' output, captures and verdicts.

**S10.1.2 The production path is rsync, daemon-reload, reboot, and the desktop is on the screen**
- Requirement: on a stock host with the documented packages and the image loaded, the three commands of `deploy/README.md` "Apply" (`rsync -a --chown=root:root deploy/host/ /`, `systemctl daemon-reload`, `reboot`) are the whole installation. The first boot creates the accounts and directories, converges the seat, writes the specs and labels and starts the desktop, and the operator sees it without anyone logging in to the host.
- Acceptance: no `systemd-sysusers`, `systemd-tmpfiles`, `systemctl start` or `restorecon` by hand; after the reboot, with read-only probes only: `desktop.service` active; `desktop-preflight` 0 FAILs; the screen shows the root colour, the initial xterm and mwm frames (S3.3.3's probes); typed text reaches the xterm (S3.8.1); a pulse tone is heard (S4.1.2); `ssh host whoami` from the container is `desktop-shell` (S5.7.2). The time from power-on to the desktop being visible is recorded.
- Evidence: common set; EV-VIDEO from power-on to the desktop, with the serial log alongside; `journalctl -b -o short-precise -u systemd-sysusers -u systemd-tmpfiles-setup -u 'desktop*'` (EV-LOG-JOURNAL) showing the first-boot order; `id desktop` and `id desktop-shell` (EV-STATE); the time to desktop in the index.
- Tier: T3 · Coverage: ✅ (workflow `maintainer.yml`) `maint-docpath`, on two stock hosts: the image loaded with `podman load`, then `deploy/README.md`'s "Apply" block read out of the document and run as written, its `reboot` included. Nobody logs in to the host until the desktop is on the screen, which the VM host watches from QEMU's side. On the first boot, with read-only probes: a new boot id; `desktop` (uid 61000) and `desktop-shell` created, `systemd-sysusers` done before `systemd-tmpfiles-setup` started and before `desktop-session` logged in as `desktop`; `desktop.service` active, mwm running and the five boot oneshots succeeded; the session's xterm in mwm's frame; `desktop-preflight` at 0 FAILs; the container's `ssh host` is `desktop-shell`; the screen's root and xterm colours; a word typed through QEMU's keyboard reaches the xterm; a 660 Hz pulse tone is heard. The time from the reboot to the desktop is recorded (19.2 s and 18.5 s in run 37390730582). Under `artifacts/S10.1.2/` (artifact `evidence-vm-maint-docpath`; the second host under `host-b/`): the stock host's state and screen, the block and each command's output, the stat of `/`, `/etc` and `/usr` before and after the rsync, preflight and `systemctl status 'desktop*'` on the stock host, after the commands and on the first boot with their diffs, the first boot's journal and unit timestamps, the EV-VIDEO from before the reboot to the desktop with the serial console, and the typing and tone.

**S10.1.3 The optional `restorecon` step is optional, and runs clean when taken**
- Requirement: on an enforcing host the desktop and confined clients work whether or not the maintainer runs the "cheap insurance" `restorecon -R …` line in `deploy/README.md` "Apply"; a maintainer who does run it, after `rsync` where the document places it, sees it succeed.
- Acceptance: two stock hosts through S10.1.2, one with the line and one without; on both, S10.1.2's acceptance plus S7.1.1's confined display and audio probes; the line's exit status is 0; `restorecon -R -n -v` over the same paths on the host that skipped it shows where the rsync-applied labels disagree (expected: nowhere).
- Evidence: common set; the `restorecon` transcript with its exit code (EV-PROCEDURE); the `-n -v` output (EV-STATE); `ls -Z` of the installed units, scripts and `/etc/desktop-container` on both hosts (EV-DIFF between them).
- Tier: T3 · Coverage: ✅ (workflow `maintainer.yml`) `maint-docpath`: host A skips the optional line and keeps a dry run of it (`restorecon -R -n -v`) right after the rsync and on the first boot; host B runs it as written right after the rsync, where `deploy/README.md` places it, and it exits 0. On both hosts, enforcing, a confined (`container_t`) display client opens `:0` and a confined audio client reaches the export, and the dry run on the first boot would relabel nothing under the line's paths. As predicted, the line as first written exited 255 right after the rsync (`lstat(/var/lib/desktop-container) failed`: the tree does not ship that directory; tmpfiles creates it at boot). `claude/fix-restorecon-line` names only the five paths the rsync fills. Under `artifacts/S10.1.3/` (artifact `evidence-vm-maint-docpath`; host B under `host-b/`): the line as read, its transcript or the dry runs, both probes, and `ls -Z` of every installed path on each host, with the diff between them.

**S10.1.4 The live-apply paths work as written on a host whose sshd is already running**
- Requirement: both documented live paths, the `README.md` "Install" block and the one-line sequence in `deploy/README.md` "Apply" (with its "if sshd was already running, `systemctl reload sshd`" clause), run verbatim on a stock, never-graphical host whose sshd started before the tree arrived (the stock case), and give S10.1.2's end state without a reboot, Host Terminal included.
- Acceptance: each path on its own stock host, run unmodified; then S10.1.2's acceptance.
- Evidence: common set; EV-LOG-JOURNAL of `sshd` for the container's `ssh host` attempt (accepted, or the failure and its reason).
- Tier: T3 · Coverage: ✅ (workflow `maintainer.yml`) `maint-live`, each path on its own stock host whose sshd ran from boot, with the documented packages and the image: host A runs `README.md`'s "Install" block; host B runs the rsync and `deploy/README.md`'s live sequence, then its "if sshd was already running" `systemctl reload sshd`. Every command is read out of the documents and run as written. Neither host reboots; the VM host watches the screen until the desktop is on it. Then S10.1.2's end state: `desktop.service` active and mwm running, both accounts, the session's xterm in mwm's frame, `desktop-preflight` at 0 FAILs, the container's `ssh host` logging in as `desktop-shell`, a word typed and a pulse tone heard. As predicted, the "Install" block as first written left Host Terminal refused (`Permission denied (publickey)`): the sshd that started before the rsync had never read the tree's `sshd_config.d` drop-in. `claude/fix-readme-install-sshd` adds `sudo systemctl try-reload-or-restart sshd` to the block. Under `artifacts/S10.1.4/` (artifact `evidence-vm-maint-live`; host B under `host-b/`): sshd's start time before the tree, the block or sequence as read and each command's output, preflight and status at each moment with their diffs, `sshd -T`, the container's `ssh host`, sshd's journal, the EV-VIDEO, and the typing and tone.

**S10.1.5 Converting a running graphical host ends in the desktop, or in a named culprit that a reboot clears**
- Requirement: applying the tree live to a host showing a graphical login (a display manager's greeter on tty1, holding DRM master) ends in one of the two states `deploy/README.md` describes. Either the desktop is on the screen with the display manager disabled and stopped, or `desktop-seat-prep` has failed with `ERROR: devices still held after convergence` naming the holder and a plain `reboot` then gives the first state with no further action by the maintainer. A dark screen with no culprit named, or a display manager back after the reboot, fails.
- Acceptance: a VM profile with `gdm` (AppStream) installed and `graphical.target` as default, booted to the greeter (EV-SHOT shows it); `rsync`, then the `deploy/README.md` live sequence verbatim (the document gives that sequence for never-graphical hosts and leaves conversion to `seat-prep.sh`, which runs ahead of the desktop start the sequence ends in); the outcome classified, and if it is the second, `reboot`; afterwards `systemctl get-default` is `multi-user.target`, `systemctl is-enabled gdm` is `disabled`, `fuser -v /dev/dri/card0` names only the desktop's Xorg, and S10.1.2's screen and input checks hold.
- Evidence: common set; EV-VIDEO from the greeter to the desktop, across the reboot if one was taken; EV-LOG-JOURNAL of `desktop-seat-prep` and `systemd-logind`; `fuser -v /dev/dri/card* /dev/tty1` before, between and after (EV-STATE).
- Tier: T3 · Coverage: ✅ (workflow `maintainer.yml`) `maint-gdm`: a stock host given `gdm` from AppStream and `graphical.target` (a profile the harness applies), booted to the greeter, which holds the card (`gnome-shell` among the holders; EV-SHOT). Then the rsync and `deploy/README.md`'s live sequence, read out of the document and run as written, with its `systemctl reload sshd`. The outcome is classified against the document's two; the second would get its reboot and the same checks. In run 37390730582 it was the first: the desktop on the screen 8 s after the sequence began; `desktop-seat-prep` succeeded; `gdm` disabled and inactive; `systemctl get-default` `multi-user.target`; only the desktop's Xorg holds a DRM card (read from `/proc/<pid>/fd`: the host's `fuser` cannot see a container's own device nodes); a word typed reaches the xterm. Under `artifacts/S10.1.5/` (artifact `evidence-vm-maint-gdm`): the profile, the greeter's screen and holders, the sequence as read and each command's output, `fuser -v` and the holders before, between and after, the journals of `desktop-seat-prep` and `systemd-logind`, preflight and status before and after with their diffs, the EV-VIDEO from the greeter to the desktop, and the typing.

**S10.1.6 A GPU host provisioned from the documentation comes up accelerated on its first boot**
- Requirement: a physical NVIDIA host given both lines of `deploy/HOST-REQUIRES.md` (with the driver stack it describes), the image and S10.1.2's three commands shows an accelerated desktop on its first boot, with S8.1.1's checks passing, both preflights at 0 FAILs, and no step beyond those documents.
- Acceptance: S8.1.1's assertions after S10.1.2's procedure.
- Evidence: every command the tester typed, as typed (EV-PROCEDURE); EV-PHOTO of the desktop; S8.1.1's state set.
- Tier: T4 · Coverage: 🔧 `ci/hw/acceptance.sh run S10.1.6` (Appendix C), not yet run on hardware, twice across the documented reboot. On a stock EL9 host with the NVIDIA driver stack installed as `deploy/HOST-REQUIRES.md` describes: the host's state and package list kept; `HOST-REQUIRES.md`'s "Every host" and "GPU hosts" lines, the image's `podman load` (when it is not loaded yet), and `deploy/README.md`'s "Apply" block, each read out of the document and run as written at the terminal with its transcript kept, the last one the reboot. On the first boot: the desktop up, S8.1.1's checks, both preflights at 0 FAILs, the tester confirms, and an EV-PHOTO.

### F10.2 Verifying a host the way the documentation says to

**S10.2.1 Every documented verification command runs as written and shows what its comment promises**
- Requirement: on a host provisioned per S10.1.2, every line of the `README.md` "Verification checklist (on the target host)" block and of the `deploy/README.md` "Verify" block runs as root without error and prints what its inline comment says it shows. A line that needs a tool the host does not have per `deploy/HOST-REQUIRES.md` is a defect in the checklist, not in the host.
- Acceptance: each line run as written, with one row per line in the index: command, comment, output, exit status, verdict. A line its comment makes conditional ("if declared") is judged on that condition. The host-side audio players (`pw-play`, `paplay`, `aplay`) are client applications the checklist presupposes; they are installed as declared probes.
- Evidence: EV-PROCEDURE of both blocks; the per-line table.
- Tier: T3 · Coverage: ✅ (workflow `maintainer.yml`) `maint-docpath`, on the provisioned host with a client running (S10.2.2): every line of `README.md`'s "Verification checklist" block (15) and of `deploy/README.md`'s "Verify" block (13), read out of the documents and run as root, each judged against its own comment, one row per line in the index. The host-side players are installed as declared probes; `pipewire-utils`, for `pw-play`, also brings PipeWire's daemon package, which the evidence notes. Each audio line runs as written, with its comment's condition met (`PIPEWIRE_REMOTE`, `PULSE_SERVER`) and from a scratch container of the image, and every run is listened to. The judged runs (`pw-play` and `paplay` with the condition met, `aplay` as written) exit 0 and are heard. The rest are recorded: `pw-play` as written cannot reach PipeWire (exit 1), as its comment's condition implies; `aplay` in a scratch container of the desktop image exits 1, the image having no `libasound_module_pcm_pulse.so`, which README.md's audio section asks of an ALSA client's image. As predicted, three lines failed as first written: `DISPLAY=:0 xrandr` and `DISPLAY=:0 glxinfo -B` ran on a host with no X client tools (exit 127), and `wpctl status` had no `XDG_RUNTIME_DIR` (exit 2). `claude/fix-checklist-probes` runs them in the container as the session user. Under `artifacts/S10.2.1/` (artifact `evidence-vm-maint-docpath`): both blocks as read, each line's output and verdict, the probes' install, and each audio run's output, capture and verdict.

**S10.2.2 Verifying a live host disturbs nothing**
- Requirement: running the two checklists, `desktop-preflight` and `desktop-monitors-capture` on a host whose desktop is in use changes nothing the operator or a client can observe: no process restarts, no configuration changes, no geometry moves, no sound drops.
- Acceptance: across a full S10.2.1 run, the following are unchanged: the pids of desktop-init, Xorg, mwm, the three audio daemons and a running client pod's application, and that pod's `restartCount`; `xrandr --query --verbose` and `xwininfo -root -tree`; `ls -l --time-style=full-iso` of `/etc/cdi`, `/etc/desktop-container` and (in the container) `/etc/X11/xorg.conf.d`. A client tone playing throughout is uninterrupted.
- Evidence: EV-PIDS; the state pairs with their (empty) EV-DIFFs; EV-SHOT before and after; EV-AUDIO spanning the run.
- Tier: T3 · Coverage: ✅ (workflow `maintainer.yml`) `maint-docpath`: a client of the desktop runs while S10.2.1 runs both checklists, `desktop-preflight` and `desktop-monitors-capture` among their lines. It is a podman client, standing in for the requirement's pod (this journey runs no cluster), with an xterm on the screen and a 90 s 330 Hz tone. Before and after: the pids of the desktop's processes and the client's; `xrandr --query --verbose`; `xwininfo -root -tree`; and `ls -l --time-style=full-iso` of `/etc/cdi`, `/etc/desktop-container` and the container's `/etc/X11/xorg.conf.d`. Each pair is the same (empty EV-DIFFs). The client's player played its whole tone and exited 0, and the capture across the checklists has no gap longer than 0.3 s in the tone's 90 s. Under `artifacts/S10.2.2/` (artifact `evidence-vm-maint-docpath`): the client, the four state pairs and their diffs, the client's log, the screen before, during and after, and the capture with its verdict.

### F10.3 Changing a running host's configuration

**S10.3.1 Declaring the monitor layout the documented way: capture, paste, restart**
- Requirement: starting from an autodetected desktop, the maintainer runs `desktop-monitors-capture`, pastes its output into `/etc/desktop-container/monitors.conf` and runs `systemctl restart desktop.service`, as `deploy/README.md` "Fixed monitor layout" says; the desktop returns with the same arrangement, now pinned.
- Acceptance: the tool's stdout written to the file unmodified; after the restart, `30-monitors.conf` exists in the container and names the captured outputs; per output, the `xrandr --query` geometry equals the captured one (mode names may change to the `cvt(1)` names, as `monitors.conf`'s comments say); preflight prints its fixed-layout PASS line; S3.4.10's live disconnect then holds the geometry.
- Evidence: common set; the captured block and the generated file (EV-CONFIG); `xrandr --query --verbose` before and after (EV-DIFF, with the expected mode-name changes listed in the index); EV-LOG-DESKTOP `xorg-monitor-conf:` and `preflight:` lines.
- Tier: T3 · Coverage: ✅ (workflow `maintainer.yml`) `maint-config`: from the autodetected desktop, `desktop-monitors-capture` run as root, its stdout written to `/etc/desktop-container/monitors.conf` unmodified, and `systemctl restart desktop.service`, watched until the desktop is back. Every desktop process and the container are new, the host session moved with them, and no getty ran. `30-monitors.conf` exists in the container and names the captured output at the captured geometry (`Virtual-1` at `1280x800+0+0`; the mode's name changed to cvt(1)'s `1280x800_74.99`, as `monitors.conf`'s comments say). The container preflight prints its fixed-layout PASS line, and S3.4.10's live disconnect, the connector forced off under the running server, then holds the geometry. Under `artifacts/S10.3.1/` (artifact `evidence-vm-maint-config`): the capture, the pasted file and the generated one, `xrandr --query --verbose` before and after with the diff, the `xorg-monitor-conf:` and `preflight:` lines, preflight and status before and after with their diffs, EV-PIDS, the journals, and the restart's EV-VIDEO.

**S10.3.2 A layout the maintainer gets wrong costs no desktop, and the documented checks say what was wrong**
- Requirement: whatever the maintainer writes in `monitors.conf`, the desktop comes up after the restart, and `podman logs desktop | grep xorg-monitor-conf` or `podman logs desktop | grep preflight:` (both in `deploy/README.md` "Verify") names the problem; every keyword the documentation offers is one the generator accepts.
- Acceptance: one restart per case, with the desktop visible each time (EV-SHOT): (a) a malformed position gives an `ERROR` line with the line number, and autodetected geometry; (b) an output name that matches no connector gives preflight's WARN naming it; (c) each global keyword named in `README.md` "Fixed monitor layout (KVM video)" or in `monitors.conf`'s comments, with a valid value and beside a valid output line, gives the layout applied. T0 part: the keywords the documents name, the keywords `xorg-monitor-conf.sh` accepts and the keywords `preflight-check.sh` skips are the same set.
- Evidence: per case, the file (EV-CONFIG), the two log slices and `xrandr --query`; the three keyword lists (EV-DIFF).
- Tier: T0/T3 · Coverage: ✅ (workflow `maintainer.yml`) the T3 half, `maint-config`: one restart per case, the desktop on the screen after each (EV-SHOT). (a) A malformed position gives `monitors.conf:2: position wants +X+Y`, nothing generated, and the output autodetects. (b) An output name with no connector gives the container preflight's WARN naming it (`HDMI-9`). (c) Each global keyword the documents name (`virtual`, `nvidia-connected`, `nvidia-edid`), with a valid value beside a valid output line, gives the layout applied. On modesetting `virtual` is checked for what `monitors.conf` says it does: `Virtual 2560 800` is in the generated config and the server read it (modes too large for it left out at start), and the screen starts at the declared output's extents (1280x800); xrandr's screen line is recorded. The journey found the documents claiming more for `Virtual` than xserver 1.20's modesetting gives (the screen held at the virtual size); `claude/fix-virtual-docs` corrects them. The shipped `monitors.conf` is restored last. The T0 half: `static`'s `ci/layout-keywords.py` compares the keywords the documents name, those `xorg-monitor-conf.sh` accepts and those `preflight-check.sh` skips, and finds one set; its self-test plants a keyword nothing accepts, which the check must name. Under `artifacts/S10.3.2/` (artifact `evidence-vm-maint-config`): per case the file, the two log slices, `xrandr --query`, preflight and status with their diffs, EV-PIDS and the restart's EV-VIDEO; and (artifact `evidence-static`) the three keyword lists with their diff.

**S10.3.3 Upgrading and rolling back the desktop image**
- Requirement: the maintainer brings a new desktop image into podman storage, points the unit at it, either by the documented digest pin (`/etc/containers/systemd/desktop.container.d/50-image.conf`, podman ≥ 5.0) or by re-tagging `localhost/desktop-container:latest` (the unit's default), and runs `systemctl restart desktop.service`. The new image runs; the published toolkit becomes the new image's (the "tool versions track the desktop image" claim); the operator gets the desktop back (S10.4.1); running clients behave as S7.8.1 and S7.8.2 require. Pointing back at the previous image and restarting restores it the same way.
- Acceptance: a second image that differs from the first visibly (e.g. another root colour in `xinitrc.desktop`) and in its toolkit binary's sha256; per route, forward then back: `podman inspect desktop --format '{{.Image}}'` is the intended image id; `sha256sum /var/lib/desktop-container/bin/screenshot` equals that image's `/usr/libexec/desktop-tools/screenshot`; the sampled root-colour pixel is the running image's (S3.3.3's probe); `desktop-preflight` reports 0 FAILs, and on the pin route its `quadlet drop-ins present … (podman merges them)` PASS line; the downtime is recorded.
- Evidence: common set; `systemctl cat desktop.service` at each state (EV-CONFIG); the inspect and checksum outputs at each state (EV-STATE); EV-SHOT with the sampled pixel at each state; EV-VIDEO of each restart.
- Tier: T3 · Coverage: ✅ (workflow `maintainer.yml`) `maint-config`: a second image built from the first, with another root colour (`#2b1b17`) and a toolkit binary with another checksum, and a podman client of the desktop running throughout. Each route goes forward to the second image and back with `systemctl restart desktop.service`: the digest pin (`desktop.container.d/50-image.conf`), then re-tagging `localhost/desktop-container:latest`. At each state: the desktop runs the intended image id; the published toolkit's sha256 is that image's; the screen's root colour is that image's; `desktop-preflight` is at 0 FAILs, with its drop-in PASS line on the pin route; every desktop process is new. The client is the same container (restart count 0), its new xterm is on the screen, the toolkit it sees is the one published, and a new 550 Hz tone from it is heard (S7.8.1). Under `artifacts/S10.3.3/` (artifact `evidence-vm-maint-config`): the two images, `systemctl cat desktop.service` at each state, the inspect and checksum outputs, the client's state and tones, preflight and status with their diffs, EV-PIDS, and each restart's EV-VIDEO and screen.

**S10.3.4 A missing image is named by the first-stop tool, and loading it is the whole fix**
- Requirement: when the image the unit names is not in podman storage (never loaded, or a mistyped pin), `desktop-preflight` names it, and loading the image then running `systemctl restart desktop.service` restores the desktop without a reboot.
- Acceptance: on a host with no route to the image's registry (the documents assume provisioning supplies images; the unit sets no `Pull=`, so on a host that can reach the registry podman's default `missing` pull policy would try to fetch it instead): pin an absent digest, or remove the default image with the unit stopped; `systemctl restart desktop.service`; `desktop.service` is not active; `desktop-preflight` exits 1 with `FAIL: image NOT in podman storage: <ref>`; load the image; `systemctl restart desktop.service`; the desktop is visible.
- Evidence: common set; EV-LOG-JOURNAL of `desktop.service` (the error as the maintainer sees it); `systemctl status desktop.service` at each step.
- Tier: T3 · Coverage: ✅ (workflow `maintainer.yml`) `maint-config`: the default image removed with the unit stopped (its `localhost/` name has no registry podman could pull it from); `systemctl restart desktop.service` exits 1 and the unit is not active; `desktop-preflight` exits 1 with `FAIL: image NOT in podman storage: localhost/desktop-container:latest`. The image loaded with `podman load` and the unit restarted, the desktop is back, every process new and the preflight at 0 FAILs. Under `artifacts/S10.3.4/` (artifact `evidence-vm-maint-config`): `desktop.service`'s journal with the error, `systemctl status` at each step, the preflight, the load, EV-PIDS and the restart's EV-VIDEO.

**S10.3.5 Switching Host Terminal off revokes it, on a host where it has already run**
- Requirement: after the documented off-switch (comment out the quadlet's `Wants=`/`After=desktop-host-shell.service` lines, `systemctl daemon-reload`, reboot) on a host where Host Terminal was working, no key authenticates as `desktop-shell`; the menu entry shows its failure text and stays open (S5.7.8); the container's preflight WARNs `no host shell material`; the rest of the desktop is unaffected. This is what `deploy/README.md` promises: "With no key generated, nothing can log into the account".
- Acceptance: before the switch, the container's `ssh host whoami` is `desktop-shell`, and a copy of the then-current private key is kept; apply the switch and reboot; the kept key and the container's `ssh host` are both refused; "Host Terminal" from the menu shows the failure screen (EV-SHOT); neither `/etc/desktop-container/host-shell-key` nor `/etc/ssh/authorized_keys.d/desktop-shell` exists.
- Evidence: common set; both ssh transcripts with exit codes; EV-LOG-JOURNAL of `sshd` showing the refusals; `ls -l /etc/desktop-container /etc/ssh/authorized_keys.d` before and after (EV-DIFF).
- Tier: T3 · Coverage: ✅ (workflow `maintainer.yml`) `maint-session`: before the switch the container's `ssh host whoami` is `desktop-shell`, a copy of the private key is kept, and "Host Terminal" from the root menu (clicked through QEMU's input devices, `operator-e2e.py --maint`) opens a shell on the host as `desktop-shell`. Then the off-switch as `deploy/README.md` gives it: the quadlet's two lines commented out (no active line names the unit), `systemctl daemon-reload` (the generated unit's `Wants=` and `After=` no longer name it), and `reboot`. After it: `desktop-host-shell.service` did not run; the kept key and the container's `ssh host` are both refused (exit 255); neither key file nor `/etc/ssh/authorized_keys.d/desktop-shell` exists; the container preflight WARNs `no host shell material`; the desktop is back; "Host Terminal" shows its failure text and stays open until Enter (S5.7.8). As predicted, the kept key at first still logged in after the switch and the reboot: nothing removed the last boot's key or its trust entry. `claude/fix-host-shell-revoke` has tmpfiles remove both at boot. Under `artifacts/S10.3.5/` (artifact `evidence-vm-maint-session`): the quadlet before and after with the diff, the generated unit, both ssh transcripts, the key material before and after with the diff, sshd's journal with the refusals, the preflight's lines, the menu and the window's text, and the reboot's EV-VIDEO.

**S10.3.6 Turning Host Terminal on, from its own failure screen**
- Requirement: the failure screen the operator sees when "Host Terminal" fails (S5.7.8) says what to run on the host (`systemctl start desktop-host-shell.service`); the maintainer running exactly that makes the operator's next "Host Terminal" click open a host shell, or the screen names whatever else is needed.
- Acceptance: start from S10.3.5's intended end state (switch applied, its files removed, desktop restarted without host-shell material); click "Host Terminal" and get the failure screen, its text quoted in the index; run the command it shows, verbatim, on the host; click "Host Terminal" again and get a `desktop-shell` prompt.
- Evidence: common set; both EV-SHOTs; `ls -la /home/desktop/.ssh` in the container before and after (EV-STATE); EV-LOG-JOURNAL of `sshd`.
- Tier: T3 · Coverage: ✅ (workflow `maintainer.yml`) `maint-session`, from S10.3.5's end state, its files removed and the desktop restarted without host-shell material (its preflight WARNs). "Host Terminal" from the menu shows the failure screen, whose text gives `systemctl start desktop-host-shell.service`. That command, read off the screen, is run on the host, and the next "Host Terminal" opens a shell on the host as `desktop-shell`. As predicted, the command at first made a key the running container never took: `host-shell-setup.sh` installs it only at container start. `claude/fix-host-shell-live` has the unit hand a new key to a running desktop. Under `artifacts/S10.3.6/` (artifact `evidence-vm-maint-session`): the start state, the screen's text and the command read from it, the unit's run, the key material, `ls -la /home/desktop/.ssh` before and after with the diff, sshd's journal, both clicks' screens, and the restart's EV-VIDEO.

**S10.3.7 The documented look-and-feel loops work as written**
- Requirement: each procedure in `README.md` "Look and feel (dark theme)" does what it says: an edit to `/home/desktop/.mwmrc` in the running container takes effect through the root menu's "Restart mwm" with no new X session; an `~/.Xdefaults` edit takes effect where the README says, in the next client started and in mwm after "Restart mwm", in the same X session; a repo-file change, rebuilt offline and deployed with `systemctl restart desktop.service`, is on the screen.
- Acceptance: a root-menu label edit appears after "Restart mwm" (EV-SHOT; Xorg pid unchanged); an xterm background edit appears on the next xterm, and a menu background edit on the root menu after "Restart mwm" (pixel samples; Xorg pid unchanged); a rebuilt image with another root colour shows it after the service restart (pixel sample).
- Evidence: common set; the edited files (EV-CONFIG); EV-PIDS showing which restarts happened.
- Tier: T3 · Coverage: ✅ (workflow `maintainer.yml`) `maint-session`, the loops as `README.md` "Look and feel" gives them, the menu clicked through QEMU's devices. `.mwmrc`'s root menu given a longer label, then "Restart mwm" (confirmed in its dialog): mwm's X connection is new, the Xorg pid the same, and the edited label is on the menu (the entry and the menu wider). `~/.Xdefaults` given another `XTerm*background` and `Mwm*menu*background`: the next xterm ("New Terminal") draws the new background, and after a second "Restart mwm", in the same X session, the root menu draws the edited one. The rebuild loop as written, as root: the image built with another root colour, `systemctl restart desktop.service`, the colour on the screen, and the desktop running the image the build made. The journey found the README wrong twice, and `claude/fix-look-and-feel-loops` corrects it. An `~/.Xdefaults` change needs no new X session: the next client reads it, and Restart mwm re-reads it. The README's `systemctl restart desktop-session.service` "in the container" had no systemd to run it there. And a build run as the maintainer put the image in the maintainer's own storage, not root's, so the restart ran the old one. Under `artifacts/S10.3.7/` (artifact `evidence-vm-maint-session`): each file before and after with its diff, the menu's measures and screens around each Restart mwm, EV-PIDS around each, the new xterm, the build and the image the desktop runs, preflight and status with their diffs, and the restarts' EV-VIDEOs.

### F10.4 Routine operations

**S10.4.1 A maintainer's restart gives the operator the whole desktop back, within a stated time**
- Requirement: `systemctl restart desktop.service`, the step several documented procedures end in, gives the operator the desktop back (root colour, initial xterm, mwm frames), with typing and sound working, within a stated budget; nothing in between offers a login prompt on the screen. Proposed budget: 60 s from the command; confirm it against measured runs before it gates anything.
- Acceptance: EV-VIDEO from the command to the first frame showing the desktop, with the elapsed time in the index; typed text lands (S3.8.1); a pulse tone is heard; every desktop pid changed (a restart that was supposed to happen) and the host session moved with it (S5.8.2).
- Evidence: common set; the time to desktop; EV-AUDIO.
- Tier: T3 · Coverage: ✅ (workflow `maintainer.yml`) `maint-docpath`: `systemctl restart desktop.service` on the provisioned host, the screen recorded from the command until the desktop is back. The time is recorded against the proposed 60 s, which does not gate yet: 2.5 s in run 37390730582. Every desktop process and the container are new, and the host session moved with them; no getty ran on any VT; the screen's root and xterm colours; a word typed reaches the xterm; a 660 Hz pulse tone is heard. Under `artifacts/S10.4.1/` (artifact `evidence-vm-maint-docpath`): preflight and status before and after with their diffs, EV-PIDS, the gettys, the journals, the EV-VIDEO with the time to desktop, and the typing and tone.

**S10.4.2 A maintenance stop leaves the seat free and the host quiet; a start restores everything**
- Requirement: `systemctl stop desktop.service` stops the desktop and its host login session, leaves no `desktop` process on the host, frees `/dev/dri/card*` and `/dev/tty1`, puts no getty on any VT, and nothing restarts the desktop until the maintainer starts it; `desktop-preflight` describes that state accurately; `systemctl start desktop.service` brings back S10.4.1's outcome.
- Acceptance: after the stop, polled for up to 30 s (logind keeps the user manager for its stop delay): `pgrep -u desktop` on the host is empty; `fuser /dev/dri/card* /dev/tty1` is empty; `systemctl list-units 'getty@tty*' 'autovt@*'` lists nothing; `desktop.service` is still inactive 120 s later; `desktop-preflight` shows `desktop.service not started` (WARN), `no DRM/VT holders` (PASS) and 0 FAILs; a client's connect attempt fails cleanly. After the start: S10.4.1's checks.
- Evidence: common set; EV-PIDS of every uid-61000 host process at each step; EV-SHOT of the screen while stopped.
- Tier: T3 · Coverage: ✅ (workflow `maintainer.yml`) `maint-docpath`: `systemctl stop desktop.service`. Within 10 s no process of the desktop's user is left on the host (`pgrep -u desktop`, the container's processes included: the host's `fuser` cannot see a container's own device nodes, S5.3.3), nobody holds `/dev/dri/card*` or `/dev/tty1`, and no getty runs on any VT. `desktop-preflight` shows `desktop.service not started` (WARN), `no DRM/VT holders` (PASS) and 0 FAILs. A client's connect attempt fails cleanly (`xdpyinfo` exits 1 in 0.4 s). 120 s later the unit is still inactive with the same activation times and restart count, and still no getty runs. `systemctl start desktop.service` then brings back S10.4.1's outcome. Under `artifacts/S10.4.2/` (artifact `evidence-vm-maint-docpath`): every uid-61000 process at each step, `fuser`, the gettys, the client's attempt, the unit's properties at the stop and 120 s on, preflight and status at each step with their diffs, the journals, the screen while stopped, and the start's EV-VIDEO, typing and tone.

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
- Acceptance: with the desktop stopped, a root process opens `/dev/dri/card0` first and keeps it open (S5.3.3's `sleep` holder); start the desktop; the desktop does not appear; `systemctl status desktop-seat-prep` shows `ERROR: devices still held` naming the pid; `podman logs desktop | grep postmortem:` shows `LIKELY CAUSE: another process holds DRM master`; `desktop-preflight` reports a FAIL for the held card, pointing at `fuser -v`; `fuser -v /dev/dri/card0` (the README's command) names it; kill it; the desktop appears within one session-restart cycle (the 3 s back-off plus Xorg start-up) with no further command.
- Evidence: common set; EV-VIDEO from the start to recovery; the `fuser -v` output; the three log slices.
- Tier: T3 · Coverage: ✅ (workflow `maintainer.yml`) `maint-faults`: with the desktop stopped, a root `sleep` opens `/dev/dri/card0`; the desktop is started; 30 s on there is no desktop on the screen. The first stops: `desktop-preflight` FAILs on the held card (`processes other than the desktop hold /dev/dri/card0 ... (fuser -v shows who)`); the desktop log's postmortem says `LIKELY CAUSE: another process holds DRM master`; `systemctl status desktop-seat-prep` shows its ERROR naming the pid; the README's `fuser -v /dev/dri/card0` names it. With the holder killed, the desktop came back by itself, with no reboot and no service restart (one session end logged since). Two predictions held, each met by a fix merged before the run. The preflight skipped its holder check while `desktop.service` was active (`claude/fix-preflight-holders-active`). seat-prep, a `RemainAfterExit=` oneshot, did not run again at the desktop's next start (`claude/fix-oneshots-every-start` makes it and `desktop-cdi-refresh` `PartOf=desktop.service`). Under `artifacts/S10.5.1/` (artifact `evidence-vm-maint-faults`): the entry, the staging, the three first stops, `fuser -v`, the kill and the remedy's log, preflight and status before and after with their diffs, EV-PIDS, and the EV-VIDEO from the start to the recovery.

**S10.5.2 Input devices on another seat: the documented remedy gives typing and clicking back**
- Requirement: when the keyboard and mouse are attached to another seat (`loginctl attach`), the README's "No input devices" entry (its `udevadm info … | grep -i seat` check and `systemctl restart desktop-seat-prep.service`) identifies the cause and restores typing and clicking at the screen, with no step the entry does not list.
- Acceptance: S3.8.6's staging, applied to the session's keyboard and pointer; the symptom captured (typed text does not land); the entry's check, run as written and against the attached nodes, shows the foreign `ID_SEAT`; the remedy run verbatim; typed text and a click land afterwards. Whether Xorg or the desktop restarted is recorded (EV-PIDS); the requirement is that neither had to.
- Evidence: common set; `udevadm info` before and after (EV-DIFF); EV-LOG-XORG device removal and addition lines; EV-SHOT of typed text.
- Tier: T3 · Coverage: ✅ (workflow `maintainer.yml`) `maint-faults`: every input device with an event node attached to `seat1` (S3.8.6's staging applied to all eight, each followed by a udev change event); a click and a word typed through QEMU's devices do not land. The entry's check, run as written against each staged node, shows `ID_SEAT=seat1`. Its remedy, `systemctl restart desktop-seat-prep.service`, exits 0; no staged node is tagged for `seat1` any more; a word typed lands again. Nothing restarted: every desktop process and the container are the ones from before the fault. Under `artifacts/S10.5.2/` (artifact `evidence-vm-maint-faults`): the entry, the devices and rules, the first stops, the check per node, `udevadm info` before and after with the diff, Xorg's device lines, EV-PIDS, preflight and status with their diffs, and both typing attempts.

**S10.5.3 A confined client denied by SELinux: the documented checks name the label, the documented restart fixes it, nothing else restarts**
- Requirement: when a client-facing directory loses its `container_file_t` label on an enforcing host, a confined client fails; the README's checks (`systemctl status desktop-selinux`, `ls -Zd …`, `ausearch -m avc -ts recent | audit2why`) show the wrong label and the denial; `systemctl restart desktop-selinux` restores access for a client pod that is already running, without restarting the desktop or the pod.
- Acceptance: a running pod opens the display in a loop (`xdpyinfo` every 2 s, logging each result); the directory and its socket are relabelled to a host type the policy denies to `container_t` (`chcon -R -t tmp_t /tmp/.X11-unix` is the obvious candidate); the loop fails and an AVC is logged; the documented checks run; `systemctl restart desktop-selinux`; the loop succeeds again; the pod's `restartCount` is 0 and the Xorg pid is unchanged.
- Evidence: common set; `ls -Zd /tmp/.X11-unix` and `ls -Z /tmp/.X11-unix/X0` before, during and after (EV-STATE); the `ausearch | audit2why` output; EV-LOG-CLIENT of the loop, with the failure and recovery timestamps.
- Tier: T3 · Coverage: ✅ (workflow `maintainer.yml`) `maint-faults`: a confined podman client (`container_t`), standing in for the requirement's pod (this journey runs no cluster), opens the display every 2 s, logging each try. `/tmp/.X11-unix` is relabelled `tmp_t` (`chcon -R`): the loop fails and an AVC denial is logged. The README's checks, as written: `systemctl status desktop-selinux`; `ls -Zd` shows the wrong label; `ausearch -m avc -ts recent | audit2why`, at a terminal as a maintainer runs it, names the denial. After `systemctl restart desktop-selinux` the loop opens the display again; the client is the same container (restart count 0), the X server the same pid, and no desktop process restarted. The harness's own searches pass `--input-logs`: run 37387054418 found ausearch reading the guest script's standard input (a pipe over ssh) instead of the log. Under `artifacts/S10.5.3/` (artifact `evidence-vm-maint-faults`): the entry, the client and its log, the labels before, during and after, the denial, the script's stdin type, the three checks and the remedy, EV-PIDS, and preflight and status with their diffs.

**S10.5.4 Device permission errors: found from the documented log lines; the escape hatch works as the README describes it**
- Requirement: when the session user cannot open a device node (its gid out of step with the host's), the README's EACCES entry leads the maintainer to the cause through `podman logs desktop` (the `align-device-groups` and `postmortem:` lines); `systemctl restart desktop.service`, which re-runs the alignment, recovers; and the entry's escape hatch (`needs_root_rights = yes` in `/etc/X11/Xwrapper.config`), applied as the entry describes, gives a running session too.
- Acceptance: with the desktop up, run `groupmod -g <fresh gid> video` inside the container (the misalignment `align-device-groups.sh` exists to prevent), then kill Xorg; the desktop does not come back; the postmortem shows `LIKELY CAUSE: device group permissions`, and the commands it names (`id desktop`, `ls -ln /dev/dri /dev/input`) show the mismatch. Path A: `systemctl restart desktop.service`, and the desktop is visible. Restage. Path B: apply the escape hatch in the running container and kill Xorg; the next session comes up with `ps -o user= -C Xorg` showing `root`. Finally `systemctl restart desktop.service`, asserting that the shipped `Xwrapper.config` and a rootless Xorg are back (S9.2.5).
- Evidence: common set; `ls -ln /dev/dri` on the host and in the container at each step; `getent group video` in the container; the log slices; EV-PIDS.
- Tier: T3 · Coverage: ✅ (workflow `maintainer.yml`) `maint-faults`: with the desktop up, `groupmod -g 64999 video` in the container, then Xorg killed; 20 s on there is no desktop. The desktop log's postmortem says `LIKELY CAUSE: device group permissions (gid misalignment)`, and the commands it names (`id desktop`, `ls -ln /dev/dri /dev/input`) show the mismatch. Path A, `systemctl restart desktop.service`: the session is back, Xorg rootless. Restaged, path B: the escape hatch (`needs_root_rights = yes` in `/etc/X11/Xwrapper.config`) applied in the running container and Xorg killed; the next session comes up with Xorg as root. A last `systemctl restart desktop.service` brings back the shipped `Xwrapper.config` and a rootless Xorg. Under `artifacts/S10.5.4/` (artifact `evidence-vm-maint-faults`): the entry, the gids on the host and in the container at each step, the staging, the first stops and the align lines, the commands the postmortem names, `Xwrapper.config` before, during and after, Xorg's user on each path, EV-PIDS, and preflight and status with their diffs.

### F10.6 Bringing client workloads to a host

The maintainer's side of E7: the documented steps that take a provisioned
host to one that runs client pods, and what kubernetes shows the maintainer
when a node is not ready for them.

**S10.6.1 The README's Kubernetes steps, as written, put the example client on the screen**
- Requirement: on a node provisioned per S10.1.2 with k3s and CRI-O, the steps in `README.md` "Kubernetes (single-node k3s + CRI-O)" and "Kubernetes: a device plugin per capability" (the CRI-O `cdi_spec_dirs` drop-in, the three `helm install` commands, `kubectl describe node | grep -A1 desktop.local/`, `kubectl apply -f examples/x11-client-pod.yaml`) give 10 allocatable of each resource and put the demo xterm ("CDI demo") on the screen, where the operator can click into it and type.
- Acceptance: the blocks run verbatim, `<registry>` the only substitution; the three resources at 10; the xterm visible (EV-SHOT); typed text lands in it (S7.5.2).
- Evidence: common set; the `kubectl describe node` excerpt; `kubectl describe pod x11-client-demo` (its events).
- Tier: T3 · Coverage: ✅ (workflow `maintainer.yml`) `maint-k8s`, on the host provisioned the documented way: CRI-O and k3s installed as phase 2 installs them (the README assumes both and does not say how, nor does it give the drop-in pointing CRI-O at k3s's pod network, `11-k3s-cni.conf`, which phase 2 also writes), with the README's CRI-O drop-in (its `toml` block, at the path its first line names) written before CRI-O first starts; the node is Ready on CRI-O and SELinux is still enforcing. The three `helm install` commands run as written, `<registry>` → `localhost` the only substitution, and each exits 0. The describe line, as written, shows `desktop.local/display`, `audio` and `tools` at 10 under Capacity and Allocatable, and the API agrees. `kubectl apply -f examples/x11-client-pod.yaml` (the repo file, byte for byte) exits 0; the pod runs this host's `localhost/desktop-container:latest`, unpulled (its image ID is podman's digest), and its xterm is on the screen (IsViewable), found as the pod's X client. A click into it, then a line typed through QEMU's devices, runs in the pod's shell (S7.5.2's check). Every desktop process and the container are the ones from before k3s and CRI-O. The journey found the example wrong: it named the image unqualified, `desktop-container:latest`, which CRI-O does not take for podman's `localhost/` image; it pulled the name from its search registries instead (quay.io: 404, `ImagePullBackOff`; run 37394752689). `claude/fix-example-image` names the image in full. The xterm's title is not the example's "CDI demo": the image's stock `/etc/bashrc` retitles an xterm at its shell's first prompt (`@x11-client-demo:/`; `USER` is unset in the pod). Under `artifacts/S10.6.1/` (artifact `evidence-vm-maint-k8s`): the README's blocks and the drop-in, the node, each install, the describe line's output and allocatable, the plugin pods, the manifest, the apply, the pod's events and image against podman's, the pod's windows, the typed line, EV-PIDS before and after, preflight and status with their diffs, and the screens around the apply.

**S10.6.2 A node the desktop has not provisioned is a visible scheduling failure that heals in place**
- Requirement: as `deploy/README.md` promises, a node without the toolkit turns "this node was never set up" into "a scheduling failure an operator can see" (that document's operator is this one's maintainer). A pod requesting `desktop.local/tools` stays `Pending` with an `Insufficient desktop.local/tools` event instead of starting and failing; once the desktop publishes, the same pod object schedules and runs, with no one deleting or recreating it.
- Acceptance: a never-provisioned node, staged: desktop stopped, `/var/lib/desktop-container/bin` emptied, `/etc/cdi/desktop-tools.yaml` removed, and `systemctl stop desktop-tools-cdi.service` (which `deploy/README.md` requires of any teardown, or the `.path` unit stays parked); allocatable `desktop.local/tools` falls to 0 (polled); a pod requesting display and tools, running `"$DESKTOP_TOOLS_BIN"/screenshot`, is `Pending` with the event; `systemctl start desktop.service`; the same pod (same uid) schedules and runs, and its capture succeeds.
- Evidence: common set; the pod's events; allocatable at each step; the pod uid before and after; `ls -l /etc/cdi /var/lib/desktop-container/bin` at each step.
- Tier: T3 · Coverage: ✅ (workflow `maintainer.yml`) `maint-k8s`, on S10.6.1's node with the three plugins registered: the never-provisioned node staged as the Acceptance gives it (the desktop stopped, `/var/lib/desktop-container/bin` emptied, `/etc/cdi/desktop-tools.yaml` removed, `desktop-tools-cdi.service` stopped); allocatable `desktop.local/tools` falls to 0 while display and audio stay at 10. A pod requesting display and tools that captures the display with `"$DESKTOP_TOOLS_BIN"/screenshot` (`ci/vm/unprovisioned-pod.yaml`) stays `Pending` for 20 s: on no node, no container created, `PodScheduled` False `Unschedulable`, and its event says `0/1 nodes are available: 1 Insufficient desktop.local/tools`. After `systemctl start desktop.service` the desktop publishes, the watcher writes the spec, and allocatable `tools` is back at 10. The same pod object (the same uid) schedules and runs, its container never restarted, and its first capture succeeds: a 1280x800 PNG of the whole screen. Every desktop process and the container are new, as a start leaves them, and the host login session moved with them. Under `artifacts/S10.6.2/` (artifact `evidence-vm-maint-k8s`): `ls -l /etc/cdi /var/lib/desktop-container/bin` and allocatable at each step, the staging, the plugin's log, the pod's manifest, the apply, its events, state and describe while Pending and after the start, its log and capture, EV-PIDS, preflight and status with their diffs, the screen while stopped, and the start's EV-VIDEO.

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
| `image/xorg/align-device-groups.sh` | node globs under `/dev` | **not needed**: a scratch container of the image per branch, plain files with the wanted group standing in for the nodes (`ci/align-groups-tests.sh`) | S3.2.2 |
| `image/xorg/ensure-vt-devices.sh` | `/dev` | `DEV_ROOT` | S3.2.3 |
| `image/xorg/preflight-check.sh` | all of the above plus `/run/udev`, the pid file, `/proc/self/mounts`, `/etc/desktop-container` | **used**: `podman run` with the quadlet's mounts and devices omitted (`ci/preflight-rows.py container`) | S5.11.2 |
| `image/session/session-postmortem` | Xorg log glob | **built**: `POSTMORTEM_XLOG_GLOB` | S2.3.5 |
| `image/session/start-audio` | daemons by name | `PATH` (used: fake daemons) | S2.4.4, S2.4.5 |
| `image/session/host-shell-setup.sh` | `SRC`, `DHOME` | **not needed**: a scratch container of the image per case (`ci/host-shell-setup-tests.sh`) | S5.7.7 |
| `image/session/host-terminal` | `ssh` by name | `PATH` (used: a fake `ssh`) | S5.7.8 |
| `image/tools/publish-tools.sh` | `SRC`, `DEST` | export the existing variables | S7.2.2, S7.2.3 |
| `deploy/host/usr/local/libexec/desktop-host-shell-setup` | `/etc/desktop-container`, `/etc/ssh/authorized_keys.d` | **built**: `DESKTOP_CONTAINER_DIR`, `HOST_SHELL_AK_DIR` | S5.7.5 |
| `deploy/host/usr/local/bin/desktop-monitors-capture` | `podman exec … xrandr --query` | **built**: `DESKTOP_XRANDR_CMD` | S3.4.12 |
| `deploy/host/usr/local/libexec/desktop-selinux` | takes paths as args already | — | S5.6.4–S5.6.6 |
| `deploy/host/usr/local/libexec/desktop-tools-cdi` | `TOOLS_DIR` via `client-cdi.conf` | also honour an env override | S5.5.4 |
| `deploy/host/usr/local/libexec/desktop-cdi-refresh` | `/proc/modules` (the loaded-`nvidia` trigger of the no-downgrade rule) | **built**: `CDI_PROC_MODULES` | S5.4.2 (module half) |

Probe tooling the client-side and hotplug stories need, and where it stands:

| Tool | Needed by | Where |
|---|---|---|
| `xinput` | S3.9.2, S3.9.4, S3.9.5, S3.9.8, S3.9.10, S3.9.11, S3.9.12, S8.2.1 | **in the desktop image**: `xorg-x11-server-utils`, which the image's `xrandr`, `xset`, `xsetroot` and `xhost` resolve to on Rocky 9, ships it. The VM shards run it in the desktop container (`desk xinput`), and so does `ci/hw/acceptance.sh`; `Containerfile.testclient` does not carry it |
| `xwininfo`, `xprop` | S3.3.3, S3.5.2, S3.5.3, S3.6.3, S3.10.*, S7.5.*, S7.7.3, S8.2.2, S10.2.2, S11.1.1–S11.1.3, S11.2.1 | **shipped**, twice: in the desktop image (`xorg-x11-utils`, which its `xdpyinfo` resolves to on Rocky 9, ships both), and in `Containerfile.testclient`, whose observer container the operator phase runs them in; `ci/hw/acceptance.sh` runs them in the desktop |
| `ffmpeg` or imagemagick `convert` for gif | EV-VIDEO | **shipped**: imagemagick is on the `ci.yml` `vm` job's apt line and makes the gifs; ffmpeg is not installed |
| `sox` or `ffmpeg` | spectrograms for EV-AUDIO | not installed; the operator phase draws a level plot at the story's pitch instead (EV-AUDIO) |
| `inotify-tools` | S7.2.3 | the `build-smoke` runner (apt), S7.2.3 being T2 |
| `alsa-utils` + `alsa-plugins-pulseaudio` | S4.2.2 | VM guest |
| `pipewire-utils`, `pulseaudio-utils`, `alsa-utils` as declared host probes | S10.1.1, S10.2.1 | VM guest, installed after the documented package line, so S10.1.1 can tell the two apart |
| `gdm` (AppStream) | S10.1.5 | a second VM profile, booted to `graphical.target` before the tree is applied |
| `edid-decode` | S8.2.3 | T4 host |

The `script-unit` step of `ci.yml` `static` covers S1.1.3, S2.3.5, S2.4.4,
S2.4.5, S3.4.12, S5.7.5 and S5.7.8 so far. S3.1.x need the `xorg-gpu-conf.sh`
overrides above. S5.7.7's and S3.2.2's T1 halves run in scratch containers of
the image in `build-smoke`, since they install files as the session user or
create groups; S3.2.3, which creates device nodes, needs the same.

## Appendix B — VM e2e phases, as suggested and as built

Every phase this appendix suggested is built. The table keeps each
suggestion and names the steps that were built for its stories, as their
Coverage lines give them: `guest:` steps of `ci/vm/vm-guest.sh`, `operator-e2e:`
stories of `ci/vm/operator-e2e.py`, the host-side checks of `ci/vm/vm-e2e.sh`, and
`maintainer.yml`'s shards.

| Suggested phase | Stories | Built as |
|---|---|---|
| `verify-session-tree` | S2.3.1, S2.3.3 (host-process half), S2.3.4, S2.3.6 (mwm killed; Quit session is the operator phase's), S2.4.2 (wireplumber / pipewire-pulse), S2.4.7, S3.2.4, S3.2.5 | `guest:verify_runtime`, `guest:verify_session_restart`, `guest:verify_mwm_exit`, `guest:verify_audio_restarts`, `guest:play_as_rocky`, the e2e's host-side checks and `smoke`; Quit session in `operator-e2e:menu_quit_session` |
| `verify-shutdown` | S2.5.1 | `smoke` |
| `verify-host-audio-clients` | S4.2.1, S4.2.2 | `guest:host_audio` |
| `verify-host-shell-hardening` | S5.7.3, S5.7.4 | `guest:deploy_checks`, `smoke` |
| `verify-selinux-policy` | S5.6.2 (full context), S5.6.3, S5.6.4, S5.6.5, S5.6.6 | `guest:deploy_checks`, `guest:deploy_tail` |
| `verify-seat-gate` | S5.3.3, S3.8.6 | `guest:deploy_tail`, `guest:seat_tags` |
| `verify-isolation-negatives` | S6.1.3, S6.1.5 (submounts), S6.2.1, S6.2.3 | `guest:verify_privileges`, `smoke` |
| `verify-fixed-layout` (extend) | S3.4.10 (window tree + video), S3.4.11, S3.4.12 | `guest:layout_declare`, `guest:layout_unplug`, `guest:layout_roundtrip`, `guest:layout_restore`, `smoke`, `script-unit` |
| `verify-hotplug-input` (new; pointers, per-device proof, Xorg plug-out) | S3.9.2, S3.9.4, S3.9.5, S3.9.7–S3.9.12 | the e2e's host-side QMP checks; `operator-e2e:s3_9_11`, `operator-e2e:s3_9_12` |
| `verify-hotplug-monitor` (new; the DRM force for plug-outs, QEMU plugging a monitor in through a VNC server on the head, an EDID through debugfs: F3.10's introduction) | S3.10.3–S3.10.7 | `guest:layout_unplug`, `guest:ad_plugin`, `guest:ad_unplug`, `guest:ad_edid`, with the host's `vnc-head.py` |
| `verify-hotplug-audio` (extend) | S4.7.3, S4.7.5 (default sink), S4.7.7, S4.7.8, S4.7.9, S4.7.11 | the e2e's host-side checks |
| `verify-kvm-composite` (new) | S3.11.1, S3.11.2 | `operator-e2e:s3_11_1`, `operator-e2e:s3_11_2` |
| `verify-client-journeys` (new; display + audio journeys) | S7.5.1–S7.5.5, S7.6.3–S7.6.5, S7.6.6 (record) | `operator-e2e:s7_5_1`, `operator-e2e:s7_5_3`, `guest:pod_windows` and the e2e's host-side checks |
| `verify-client-hotplug-continuity` (new; the "no restart" proofs) | S7.7.1–S7.7.8 | `operator-e2e:s7_7_1`, `operator-e2e:s7_7_2`, `operator-e2e:s7_7_8`, `operator-e2e:s11_3_1`, `guest:layout_unplug` and the e2e's host-side checks |
| `verify-client-lifecycle` (new) | S7.8.1–S7.8.3, S7.3.6 (running client through uninstall) | the e2e's host-side checks, `guest:verify_teardown` |
| reboot sub-phase after `phase-deploy` | S5.1.3, S5.5.5 (reboot half) | `guest:deploy_tail`, `guest:deploy_reboot`, last in the core shard |
| second VM profile booted without `intel-hda` | S2.4.6 / S4.7.10 / S7.7.9 | the `soundless` shard, `guest:soundless` |
| `verify-maintainer-provisioning` (new; a fresh overlay per variant, procedures from the documents, reboots) | S10.1.1–S10.1.4 | `maintainer.yml`: `maint-docpath`, `maint-live` |
| VM profile with `gdm`, booted to `graphical.target` | S10.1.5 | `maintainer.yml`: `maint-gdm` |
| `verify-maintainer-checklists` (new) | S10.2.1, S10.2.2 | `maintainer.yml`: `maint-docpath` |
| `verify-maintainer-day2` (new) | S10.3.1–S10.3.7 | `maintainer.yml`: `maint-config`, `maint-session` |
| `verify-maintainer-routine` (new) | S10.4.1, S10.4.2 | `maintainer.yml`: `maint-docpath` |
| `verify-maintainer-troubleshooting` (new; one documented fault per story, staged and restored) | S10.5.1–S10.5.4 | `maintainer.yml`: `maint-faults` |
| `verify-maintainer-onboarding` (extend phase 2; the README's steps verbatim) | S10.6.1, S10.6.2 | `maintainer.yml`: `maint-k8s` |
| operator phase | S3.3.2, S3.3.3, S3.5.2, S3.5.3, S11.1.1–S11.1.3, S11.2.1, S11.3.1; with them S2.3.6 (Quit session), S3.6.1 (menu), S3.6.3, S5.7.2 (menu-launched shell) | `ci/vm/operator-e2e.py`, the `operator` shard (QMP pointer and key events only) |

## Appendix C — Hardware acceptance (T4)

`ci/hw/acceptance.sh` runs the T4 stories at a provisioned physical host,
after each image or tree release, and writes each story's evidence in CI's
layout (`ci/evidence.sh`; `ci/evlib.py` renders its `evidence.md`). It checks
what the host and the desktop report itself. What only a person can see or
hear (a picture on a panel, a tone from a speaker) it asks the tester, as a
check that passes or fails, and the photo, video or recording a story names
is copied in from a path the tester gives. It has not yet been run on
hardware: every story here stays 🔧 until a run's evidence is reviewed.

```sh
sudo ci/hw/acceptance.sh list                 # the stories and what each needs
sudo ci/hw/acceptance.sh run S8.1.1 S8.2.3    # run stories (a pair runs once for both)
sudo ci/hw/acceptance.sh S8.3.2 sample        # S8.3.2's daily row (cron; no terminal)
sudo ci/hw/acceptance.sh pack                 # a tarball of the evidence: the report
```

- Run it as root, from a checkout of this repository, over ssh from a
  machine that is not behind the host's KVM: a provisioned host's console is
  the desktop (no getty on any VT), and the KVM stories switch its keyboard
  away.
- Evidence goes under `/var/lib/hw-acceptance/artifacts/<story>/`
  (`HW_STATE`), which survives the reboots S8.1.3 and S10.1.6 take. Each
  story's `meta.tsv` names the host and the tester (asked at the first run
  and kept, or `HW_TESTER`), and every row is timestamped. A new attempt at
  a story sets the last one's directory aside.
- Whatever a story stages (a spec set aside, a drop-in, a kernel argument)
  is undone before it ends, and on an interrupt; a story that reboots keeps
  its place in `HW_STATE` and undoes its staging on its last run. The
  evidence keeps both the staging and the undoing.
- `HW_REHEARSE=1` answers every question yes and attaches no media, so the
  machine side can be tried on any host; its evidence says it was a
  rehearsal, and no observation or media check passes in it.

| Stories | The tester provides | The script stages and checks |
|---|---|---|
| S8.1.1, S3.1.1 | an NVIDIA host whose toolkit injects the X driver; a photo | the GPU mode, read from the host and the desktop |
| S3.1.2, S8.1.4 | an NVIDIA host; a photo | an older toolkit (staged where this one injects the X driver), then `README.md`'s bind-mount fallback |
| S8.1.2 | an NVIDIA host; a photo | a missing toolkit (staged): the stub, and both preflights' FAILs |
| S8.1.3 | an NVIDIA-only host; three runs across two reboots | `nvidia_drm.modeset=0` and no injection (staged) |
| S5.4.3 | an NVIDIA host with a real spec | a stale spec (staged), then `README.md`'s remedy |
| S8.2.3 | the desk's monitors; `edid-decode`, if installed | `desktop-monitors-capture` installed as it is |
| S8.2.2, S3.4.5, S3.10.8 | a KVM switch cycle, or a cable pulled and put back; a phone video (S3.10.8: and a photo) | the declared layout across it (S3.4.5: on an NVIDIA desktop); needs S8.2.3's layout |
| S8.2.1 | ten KVM switches, typing and clicking after the first and the last; a phone video | the input devices and the desktop's processes across them |
| S8.3.1, S4.7.12 | a USB headset or DAC; speech; a phone video | a client playing throughout, from the probe image |
| S8.3.2 | days of uptime | the container log's size, daily |
| S10.1.6 | a stock NVIDIA host; two runs across the documented reboot | the documents' commands as written, then S8.1.1's checks |

The X tools the stories use are the desktop image's own: `xrandr`,
`xdpyinfo` and `glxinfo`, and with them `xinput`, `xwininfo` and `xprop`
(`xorg-x11-server-utils` and `xorg-x11-utils`, the packages its `xrandr` and
`xdpyinfo` resolve to on Rocky 9). Only S8.3.1 needs the Appendix A probe
image (`Containerfile.testclient`), built and loaded onto the host first,
for its player and recorder.

## Appendix D — Coverage summary

Counts are of stories in E1–E7 and E9–E11 (E8 is all 🔧). A story
with a mixed mark is counted under its weakest mark; a story whose only mark
is 🔧 is counted in that column. Since the evidence standard was added, a
story whose assertion exists but whose named evidence is not yet captured
(e.g. "✅ captures; ❌ spectrograms") counts as ❌: an unreviewable pass is a
gap by this document's definition. The coverage lines were re-checked against
the code story by story on 2026-10-05 and now follow this rule; the counts
before that review were 69 ✅, 42 🟡, 136 ❌ and 4 🔧. Since then each story
moves to ✅ only when a CI run has saved its evidence, which the
`coverage-gate` job then keeps true. E9, the test suite's own rules, is
counted since its stories got Coverage lines (2026-10-06).

| Epic | Stories | ✅ | 🟡 | ❌ | 🔧 |
|---|---|---|---|---|---|
| E1 Image build | 14 | 14 | 0 | 0 | 0 |
| E2 Boot & supervision | 25 | 25 | 0 | 0 | 0 |
| E3 Display & session | 62 | 59 | 0 | 0 | 3 |
| E4 Audio | 23 | 22 | 0 | 0 | 1 |
| E5 Deploy tree | 50 | 49 | 0 | 0 | 1 |
| E6 Privileges | 9 | 9 | 0 | 0 | 0 |
| E7 Client contract & journeys | 40 | 40 | 0 | 0 | 0 |
| E9 Test-suite quality | 17 | 6 | 0 | 11 | 0 |
| E10 Maintainer experience | 23 | 22 | 0 | 0 | 1 |
| E11 Operator experience | 5 | 5 | 0 | 0 | 0 |
| **Total** | **268** | **251** | **0** | **11** | **6** |

Regenerate after editing with:

```sh
for e in 1 2 3 4 5 6 7 9 10 11; do
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
