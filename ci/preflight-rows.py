#!/usr/bin/env python3
"""Every FAIL and WARN row of the two preflights fires when its condition is
staged (Requirements.md S5.10.3, the host's desktop-preflight, and S5.11.2,
the container's preflight-check.sh).

  preflight-rows.py rows <script>      the script's FAIL/WARN rows: level,
                                       line, message template
  preflight-rows.py host               S5.10.3, as root on a host the deploy
                                       tree is applied to, the desktop up
  preflight-rows.py container [IMAGE]  S5.11.2, scratch containers of the
                                       image (default localhost/desktop-
                                       container:latest)

The rows are read from the script itself: every `fail "..."` and `warn
"..."`, its variables and command substitutions standing for any text. Each
case below stages a condition and names the rows it must make fire; a row
no case names fails the story, so a row added to a script fails this test
until a case stages it.

Host cases run desktop-preflight in a private mount namespace (unshare -m):
a path hidden under /dev/null (no longer a regular file, nor executable), a
file replaced, a directory covered by a tmpfs holding only what the case
puts there. A command is hidden from PATH itself: bash's `command -v` still
names a file that is not executable when it finds nothing better, so each
PATH directory holding it is swapped for a farm of symlinks to everything
else there. Fakes of systemctl and podman first on PATH answer the calls a
case lists and hand every other call to the real command. Nothing staged
outlives its run but /dev/nvidiactl and any directory a tmpfs needed, which
the run creates and removes.

Container cases run preflight-check.sh in `podman run --rm` of the image
with none of the quadlet's devices or mounts, after a setup of their own.

Evidence: ci/evlib.py's StoryWriter under $EV_ROOT (default artifacts/).
"""
import os
import re
import shutil
import subprocess
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from evlib import StoryWriter  # noqa: E402

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
HOST_SCRIPT = os.path.join(ROOT, "deploy/host/usr/local/bin/desktop-preflight")
CONTAINER_SCRIPT = os.path.join(ROOT, "image/xorg/preflight-check.sh")


# --- the rows -------------------------------------------------------------------

def _dq_end(s, i):
    """Index just past the double-quoted string that starts after s[i-1] == '"',
    honouring backslashes and nested $(...) (which may hold quotes of its own)."""
    while i < len(s):
        c = s[i]
        if c == "\\":
            i += 2
        elif c == '"':
            return i + 1
        elif s.startswith("$(", i):
            i = _paren_end(s, i + 2)
        else:
            i += 1
    raise ValueError("unterminated string")


def _paren_end(s, i):
    """Index just past the ')' closing a $( that ended at i."""
    depth = 1
    while i < len(s):
        c = s[i]
        if c == "\\":
            i += 2
            continue
        if c == "'":
            i = s.index("'", i + 1) + 1
            continue
        if c == '"':
            i = _dq_end(s, i + 1)
            continue
        if c == "(":
            depth += 1
        elif c == ")":
            depth -= 1
            if depth == 0:
                return i + 1
        i += 1
    raise ValueError("unterminated $(")


def rows(path):
    """[(level, line, template)] for every fail "..." / warn "..." call."""
    text = open(path, encoding="utf-8").read()
    out = []
    for m in re.finditer(r'(?<![\w-])(fail|warn) "', text):
        start = m.end()
        end = _dq_end(text, start)
        line = text.count("\n", 0, m.start()) + 1
        out.append((m.group(1).upper(), line, text[start:end - 1]))
    return out


def pattern(template):
    """A regex for the message the template prints: every $var, ${...} and
    $(...) stands for any text, everything else for itself."""
    parts, i = [], 0
    while i < len(template):
        c = template[i]
        if template.startswith("$(", i):
            i = _paren_end(template, i + 2)
            parts.append(".*")
        elif template.startswith("${", i):
            i = template.index("}", i) + 1
            parts.append(".*")
        elif c == "$" and i + 1 < len(template) and (template[i + 1].isalnum() or template[i + 1] in "_*@#?"):
            i += 1
            while i < len(template) and (template[i].isalnum() or template[i] == "_"):
                i += 1
            parts.append(".*")
        elif c == "\\" and i + 1 < len(template):
            parts.append(re.escape(template[i + 1]))
            i += 2
        else:
            parts.append(re.escape(c))
            i += 1
    return "".join(parts)


# --- running a case ---------------------------------------------------------------

def run(cmd, **kw):
    return subprocess.run(cmd, capture_output=True, text=True, **kw)


class Story:
    """One preflight, its rows, and the cases that stage them."""

    def __init__(self, w, script, prefix):
        self.w, self.prefix = w, prefix
        self.rows = rows(script)
        self.fired = {}                         # template -> (case, line)
        self.named = set()
        listing = "\n".join(f"{lvl:4} line {ln:3}  {t}" for lvl, ln, t in self.rows)
        w.write("rows", listing + "\n", f"EV-STATE: every FAIL and WARN row of {os.path.relpath(script, ROOT)}, "
                f"read from its source ({len(self.rows)}): level, line, message template")
        w.note(f"{len(self.rows)} FAIL/WARN rows in {os.path.relpath(script, ROOT)}")

    def row(self, template):
        hits = [r for r in self.rows if r[2] == template]
        if not hits:
            raise SystemExit(f"no row prints exactly: {template}")
        return hits[0]

    def expect(self, case, output, templates, extra=None):
        """Each named row must print at least once in this case's output."""
        lines = output.splitlines()
        for t in templates:
            self.named.add(t)
            level, ln, _ = self.row(t)
            rx = re.compile(rf"^{re.escape(self.prefix)}: {level}: {pattern(t)}$")
            got = [l for l in lines if rx.match(l)]
            want = (extra or {}).get(t)
            ok = bool(got) and (want is None or all(any(w in g for g in got) for w in want))
            if ok:
                self.fired.setdefault(t, (case, got[0]))
            short = t if len(t) <= 90 else t[:87] + "..."
            more = f" (each of: {', '.join(want)})" if want else ""
            self.w.check(ok, f"{case}: the {level} row at line {ln} fires{more}: {short}")

    def finish(self):
        missing = [r for r in self.rows if r[2] not in self.named]
        for lvl, ln, t in missing:
            self.w.check(False, f"no case stages the {lvl} row at line {ln}: {t}")
        table = []
        for lvl, ln, t in self.rows:
            case, line = self.fired.get(t, ("-", "(did not fire)"))
            table.append(f"line {ln:3}  {lvl:4}  {case:24}  {line}")
        self.w.write("table", "\n".join(table) + "\n",
                     "EV-STATE: the table: every row, the case that staged it, and the line it printed")
        fired = sum(1 for r in self.rows if r[2] in self.fired)
        self.w.check(fired == len(self.rows) and not missing,
                     f"all {len(self.rows)} FAIL/WARN rows fired, each in a case that staged its condition ({fired} did)")


# --- S5.10.3: the host's desktop-preflight -----------------------------------------

QUADLET = "/etc/containers/systemd/desktop.container"
WORK = "/var/tmp/ev-preflight"                  # not under /tmp or /run: cases cover those
STUB_SPEC = ("# Stub CDI spec (a test's copy)\ncdiVersion: 0.5.0\nkind: nvidia.com/gpu\ndevices:\n"
             "  - name: all\n    containerEdits:\n      env:\n        - NVIDIA_CDI_STUB=1\n")
REAL_SPEC = ("cdiVersion: 0.5.0\nkind: nvidia.com/gpu\ndevices:\n  - name: all\n    containerEdits:\n"
             "      env:\n        - GENERATED=1\n")
FAKE = r"""#!/bin/bash
# A fake %(name)s for S5.10.3: answers the calls listed in $%(var)s, one per
# line as "arguments|exit status|output", and hands every other to the real one.
if [ -n "${%(var)s:-}" ] && [ -f "$%(var)s" ]; then
    while IFS='|' read -r args rc out; do
        if [ "$args" = "$*" ]; then
            [ -z "$out" ] || printf '%%s\n' "$out"
            exit "$rc"
        fi
    done < "$%(var)s"
fi
exec %(real)s "$@"
"""


def host_cases(w):
    alsa = [d for d in ("/usr/lib64/alsa-lib", "/usr/lib/x86_64-linux-gnu/alsa-lib") if os.path.isdir(d)]
    inactive = {"is-active --quiet desktop.service": (3, "")}
    with open("/etc/passwd") as f:
        no_shell_user = "".join(l for l in f if not l.startswith("desktop-shell:"))
    cdi = {n: open(os.path.join("/etc/cdi", n)).read() for n in os.listdir("/etc/cdi")
           if os.path.isfile(os.path.join("/etc/cdi", n))}
    cards = sorted((n for n in os.listdir("/dev/dri") if re.fullmatch(r"card\d+", n)), key=lambda n: int(n[4:])) \
        if os.path.isdir("/dev/dri") else []
    card = "/dev/dri/" + cards[0] if cards else "/dev/dri/card0"    # the runner's is card1
    return [
        dict(id="podman-old", what="podman reports 4.3.1 (the fake)",
             podman={"--version": (0, "podman version 4.3.1")},
             rows=["podman $pv: quadlet needs >= 4.4"]),
        dict(id="no-podman", what="no podman on PATH (each PATH directory holding it swapped for a farm of links to the rest)",
             hide_cmd=["podman"], rows=["podman not installed"]),
        dict(id="no-quadlet", what="the quadlet hidden under /dev/null",
             hide=[QUADLET], rows=["quadlet unit missing at $QUADLET: deploy tree not applied"]),
        dict(id="no-unit", what="systemd knows no desktop.service (systemctl cat fails, the fake)",
             sc={"cat desktop.service": (1, "")},
             rows=["desktop.service unknown to systemd: run systemctl daemon-reload (or quadlet generation failed)"]),
        dict(id="dropin-old-podman", what="a quadlet drop-in present (a tmpfs over desktop.container.d holding ev.conf) with podman 4.9.3 (the fake)",
             tmpfs=[(QUADLET + ".d", "0755", {"ev.conf": "[Container]\n# a test's drop-in\n"})],
             podman={"--version": (0, "podman version 4.9.3")},
             rows=["quadlet drop-ins in $QUADLET.d are SILENTLY IGNORED by podman < 5.0; verify with: systemctl cat desktop.service"]),
        dict(id="no-image", what="the quadlet's image not in podman storage (podman image exists fails, the fake)",
             podman={"image exists localhost/desktop-container:latest": (1, "")},
             rows=["image NOT in podman storage: $img - the deploy tree never builds or pulls; podman pull/load it"]),
        dict(id="no-oneshots", what="systemd knows none of the four oneshots (systemctl cat fails for each, the fake)",
             sc={f"cat {u}.service": (1, "") for u in ("desktop-seat-prep", "desktop-cdi-refresh", "desktop-client-cdi", "desktop-host-shell")},
             rows=["$u.service missing: deploy tree not fully applied"],
             each={"$u.service missing: deploy tree not fully applied":
                   ["desktop-seat-prep.service", "desktop-cdi-refresh.service", "desktop-client-cdi.service", "desktop-host-shell.service"]}),
        dict(id="graphical", what="the default target graphical.target (the fake)",
             sc={"get-default": (0, "graphical.target")},
             rows=["default target is '${dt:-unknown}', not multi-user.target (seat-prep.sh converges this at desktop start)"]),
        dict(id="getty-enabled", what="getty@tty1 enabled, not masked (the fake)",
             sc={"is-enabled getty@tty1.service": (0, "enabled")},
             rows=["getty@$VT.service is '${ge:-unknown}', not masked (seat-prep.sh converges this at desktop start)"]),
        dict(id="getty-running", what="a getty running on tty1 (the fake)",
             sc={"is-active --quiet getty@tty1.service": (0, "")},
             rows=["a getty is RUNNING on $VT right now - it will fight Xorg for the VT"]),
        dict(id="dm-running", what="a display-manager.service (a tmpfs over /etc/systemd/system holding one), active (the fake)",
             tmpfs=[("/etc/systemd/system", "0755", {"display-manager.service": "[Service]\nExecStart=/bin/true\n"})],
             sc={"is-active --quiet display-manager.service": (0, "")},
             rows=["a display manager is RUNNING - it holds DRM master; seat-prep.sh stops it at desktop start"]),
        dict(id="dm-installed", what="the same display-manager.service, inactive (the fake)",
             tmpfs=[("/etc/systemd/system", "0755", {"display-manager.service": "[Service]\nExecStart=/bin/true\n"})],
             sc={"is-active --quiet display-manager.service": (3, "")},
             rows=["a display manager is installed (inactive); expect seat-prep.sh to keep it disabled"]),
        dict(id="seat-rule", what="a 72-seat-*.rules (a tmpfs over /etc/udev/rules.d holding one)",
             tmpfs=[("/etc/udev/rules.d", "0755", {"72-seat-ev.rules": "# a test's seat rule\n"})],
             rows=["custom seat attachment rules present ($seat_rules) - devices hidden from the container's seat0; seat-prep.sh removes them at desktop start"]),
        dict(id="no-logind-dropin", what="the logind drop-in hidden under /dev/null",
             hide=["/etc/systemd/logind.conf.d/50-desktop-container.conf"],
             rows=["logind drop-in missing: host logind may spawn gettys on VT switches"]),
        dict(id="holder", what=f"desktop.service inactive (the fake) while a sleep holds {card}, the host's first DRM card",
             sc=inactive, holder=card,
             rows=["processes hold$holders while desktop.service is inactive - Xorg would fail drmSetMaster (fuser -v shows who)"]),
        dict(id="no-fuser", what="desktop.service inactive (the fake), no fuser on PATH",
             sc=inactive, hide_cmd=["fuser"],
             rows=["fuser not available (install psmisc); cannot check DRM/VT holders"]),
        dict(id="no-kms", what="no /dev/dri/card* (a tmpfs over /dev/dri) and no /dev/nvidiactl",
             tmpfs=[("/dev/dri", "0755", {})] if os.path.isdir("/dev/dri") else [],
             rows=["no /dev/dri/card* and no NVIDIA device: X has no KMS device (NVIDIA-driver host? nvidia_drm.modeset=1 missing from kernel cmdline)"]),
        dict(id="stub-with-nvidia", what="the stub spec (a copy over /etc/cdi/nvidia.yaml) and /dev/nvidiactl (created for the run), no nvidia-ctk",
             replace=[("/etc/cdi/nvidia.yaml", STUB_SPEC, 0o644)], host_files=["/dev/nvidiactl"],
             rows=["STUB CDI spec but NVIDIA hardware present: container toolkit missing/broken (desktop-cdi-refresh fell back); GPU acceleration is OFF",
                   "NVIDIA device present but nvidia-ctk not installed: only a stub spec can be generated"]),
        dict(id="real-no-nvidia", what="a real spec (no NVIDIA_CDI_STUB, over /etc/cdi/nvidia.yaml) and no /dev/nvidiactl",
             replace=[("/etc/cdi/nvidia.yaml", REAL_SPEC, 0o644)],
             rows=["real CDI spec but no /dev/nvidiactl (driver not loaded yet, or GPU removed); desktop-cdi-refresh reconciles at desktop start"]),
        dict(id="no-nvidia-spec", what="/etc/cdi/nvidia.yaml hidden under /dev/null",
             hide=["/etc/cdi/nvidia.yaml"],
             rows=["/etc/cdi/nvidia.yaml missing: AddDevice=nvidia.com/gpu=all cannot resolve; run: systemctl start desktop-cdi-refresh"]),
        dict(id="no-client-specs", what="both client specs hidden under /dev/null",
             hide=["/etc/cdi/desktop-display.yaml", "/etc/cdi/desktop-audio.yaml"],
             rows=["$spec missing: client containers cannot resolve $kind=all; run: systemctl start desktop-client-cdi"],
             each={"$spec missing: client containers cannot resolve $kind=all; run: systemctl start desktop-client-cdi":
                   ["desktop.local/display=all", "desktop.local/audio=all"]}),
        dict(id="client-spec-kind", what="the display spec replaced by one declaring another kind",
             replace=[("/etc/cdi/desktop-display.yaml", "cdiVersion: 0.5.0\nkind: desktop.local/other\ndevices: []\n", 0o644)],
             rows=["$spec does not declare kind $kind: rewrite it with: systemctl restart desktop-client-cdi"]),
        dict(id="client-spec-mounts", what="the audio spec replaced by one mounting a directory this host does not have",
             replace=[("/etc/cdi/desktop-audio.yaml", "cdiVersion: 0.5.0\nkind: desktop.local/audio\ndevices:\n  - name: all\n"
                       "    containerEdits:\n      mounts:\n        - hostPath: /run/ev-not-there\n"
                       "          containerPath: /run/ev-not-there\n", 0o644)],
             rows=["$kind=all mounts$missing, which do(es) not exist on this host"]),
        dict(id="combined-spec", what="the superseded /etc/cdi/desktop.yaml (a tmpfs over /etc/cdi holding copies of its specs and that one)",
             tmpfs=[("/etc/cdi", "0755", dict(cdi, **{"desktop.yaml": "cdiVersion: 0.5.0\nkind: desktop.local/display\ndevices: []\n"}))],
             rows=["/etc/cdi/desktop.yaml is superseded by the split display/audio specs and still resolves: remove it (desktop-client-cdi does this automatically)"]),
        dict(id="dir-modes", what="tmpfs mode 0755 over /run/desktop-audio and over /tmp/.X11-unix",
             tmpfs=[("/run/desktop-audio", "0755", {}), ("/tmp/.X11-unix", "0755", {})],
             rows=["$d mode is $m, expected 1777 (cross-uid clients may fail to connect)"],
             each={"$d mode is $m, expected 1777 (cross-uid clients may fail to connect)": ["/run/desktop-audio mode is 755", "/tmp/.X11-unix mode is 755"]}),
        dict(id="no-audio-dir", what="no /run/desktop-audio: a tmpfs over /run holding only the runtime dirs of systemd, D-Bus, podman, logind's users and udev, bound back in",
             run_tmpfs=True,
             rows=["$d missing: systemd-tmpfiles --create (tree's tmpfiles.d not applied?)"],
             each={"$d missing: systemd-tmpfiles --create (tree's tmpfiles.d not applied?)": ["/run/desktop-audio missing"]}),
        dict(id="no-x11-dir", what="no /tmp/.X11-unix: a tmpfs over /tmp",
             tmpfs=[("/tmp", "1777", {})],
             rows=["$d missing: systemd-tmpfiles --create (tree's tmpfiles.d not applied?)"],
             each={"$d missing: systemd-tmpfiles --create (tree's tmpfiles.d not applied?)": ["/tmp/.X11-unix missing"]}),
        dict(id="no-pulse-conf", what="the host Pulse client drop-in hidden under /dev/null",
             hide=["/etc/pulse/client.conf.d/50-desktop-container.conf"],
             rows=["host Pulse client config missing: host pulse clients won't reach the container"]),
        dict(id="no-alsa-conf", what="the host ALSA drop-in hidden under /dev/null",
             hide=["/etc/alsa/conf.d/99-zz-desktop-container.conf"],
             rows=["host ALSA client config missing: host alsa clients won't reach the container"]),
        dict(id="no-alsa-plugin", what="no pulse plugin for alsa-lib: a tmpfs over " + (" and ".join(alsa) if alsa else "nothing (neither alsa-lib dir exists here)"),
             tmpfs=[(d, "0755", {}) for d in alsa],
             rows=["alsa-plugins-pulseaudio not installed: host ALSA clients cannot use the pulse route"]),
        dict(id="no-sockets", what="desktop.service active, /run/desktop-audio an empty tmpfs (mode 1777)",
             tmpfs=[("/run/desktop-audio", "1777", {})],
             rows=["desktop active but audio sockets not (yet) in /run/desktop-audio"]),
        dict(id="no-shell-account", what="/etc/passwd replaced by a copy without desktop-shell",
             replace=[("/etc/passwd", no_shell_user, 0o644)],
             rows=["desktop-shell account missing: systemd-sysusers (tree's sysusers.d not applied?)"]),
        dict(id="no-sshd-dropin", what="the sshd drop-in hidden under /dev/null",
             hide=["/etc/ssh/sshd_config.d/40-desktop-container.conf"],
             rows=["sshd drop-in missing: root-owned trust path not wired"]),
        dict(id="sshd-inactive", what="sshd inactive (the fake)",
             sc={"is-active --quiet sshd": (3, "")},
             rows=["sshd not active (desktop-host-shell starts it at desktop start via Wants=)"]),
        dict(id="no-sshd", what="no sshd on PATH, and /usr/sbin/sshd (if any) under /dev/null",
             hide_cmd=["sshd"], hide=["/usr/sbin/sshd"] if os.path.exists("/usr/sbin/sshd") else [],
             rows=["openssh-server not installed: 'Host Terminal' cannot work"]),
        dict(id="key-mode", what="the host-shell key replaced by a 0644 file",
             replace=[("/etc/desktop-container/host-shell-key", "not a key\n", 0o644)],
             rows=["host-shell key mode is $kp, expected 0400"]),
        dict(id="no-trust-entry", what="/etc/ssh/authorized_keys.d/desktop-shell hidden under /dev/null",
             hide=["/etc/ssh/authorized_keys.d/desktop-shell"],
             rows=["key exists but /etc/ssh/authorized_keys.d/desktop-shell missing: rerun desktop-host-shell.service"]),
        dict(id="no-key", what="the host-shell key hidden under /dev/null",
             hide=["/etc/desktop-container/host-shell-key"],
             rows=["no host-shell key yet (generated fresh at every desktop start by desktop-host-shell.service)"]),
        dict(id="desktop-failed", what="desktop.service failed (the fake: not active, failed)",
             sc={"is-active --quiet desktop.service": (3, ""), "is-failed --quiet desktop.service": (0, "")},
             rows=["desktop.service FAILED: journalctl -u desktop.service, then podman logs desktop"]),
        dict(id="desktop-stopped", what="desktop.service not started (the fake: not active, not failed)",
             sc={"is-active --quiet desktop.service": (3, ""), "is-failed --quiet desktop.service": (1, "")},
             rows=["desktop.service not started (systemctl start desktop.service, or reboot)"]),
    ]


def path_without(cmds, d):
    """PATH with every directory holding one of cmds swapped for a farm of
    symlinks to everything else in it."""
    dirs = []
    for p in os.environ.get("PATH", "/usr/sbin:/usr/bin:/sbin:/bin").split(":"):
        if not os.path.isdir(p):
            continue
        if not any(os.path.lexists(os.path.join(p, c)) for c in cmds):
            dirs.append(p)
            continue
        farm = os.path.join(d, "path" + p.replace("/", "_"))
        os.makedirs(farm, exist_ok=True)
        for e in os.listdir(p):
            if e not in cmds:
                os.symlink(os.path.join(p, e), os.path.join(farm, e))
        dirs.append(farm)
    return ":".join(dirs)


def host_script(case, n, fakebin):
    """The bash run inside the namespace: the mounts, then the preflight."""
    d = os.path.join(WORK, f"{n:02d}-{case['id']}")
    os.makedirs(d, exist_ok=True)
    lines = ["set -e"]
    for p in case.get("hide", []):
        lines.append(f"mount --bind /dev/null {p}")
    for i, (p, content, mode) in enumerate(case.get("replace", [])):
        src = os.path.join(d, f"replace{i}")
        with open(src, "w") as f:
            f.write(content)
        os.chmod(src, mode)
        lines.append(f"mount --bind {src} {p}")
    if case.get("run_tmpfs"):
        keep = [p for p in ("/run/systemd", "/run/dbus", "/run/containers", "/run/libpod", "/run/user", "/run/udev")
                if os.path.isdir(p)]
        lines.append(f"mkdir -p {d}/run && mount --bind /run {d}/run && mount -t tmpfs -o mode=0755 ev-run /run")
        for p in keep:
            lines.append(f"mkdir -p {p} && mount --bind {d}/run{p[len('/run'):]} {p}")
    for p, mode, files in case.get("tmpfs", []):
        lines.append(f"mount -t tmpfs -o mode={mode} ev-tmpfs {p}")
        for name, content in files.items():
            src = os.path.join(d, "tmpfs-" + p.strip("/").replace("/", "_") + "-" + name)
            with open(src, "w") as f:
                f.write(content)
            lines.append(f"cp {src} {p}/{name}")
    path = path_without(case["hide_cmd"], d) if case.get("hide_cmd") else "$PATH"
    fakes = not any(c in ("systemctl", "podman") for c in case.get("hide_cmd", []))
    env = [f"PATH={fakebin}:{path}" if fakes else f"PATH={path}"]
    for key, var in (("sc", "EV_SC_RULES"), ("podman", "EV_PODMAN_RULES")):
        if case.get(key):
            rules = os.path.join(d, key + ".rules")
            with open(rules, "w") as f:
                for args, (rc, out) in case[key].items():
                    f.write(f"{args}|{rc}|{out}\n")
            env.append(f"{var}={rules}")
    lines.append("exec env " + " ".join(env) + f" {HOST_SCRIPT}")
    return "\n".join(lines) + "\n"


def cmd_host():
    if os.geteuid() != 0:
        raise SystemExit("host: run as root")
    w = StoryWriter(os.environ.get("EV_ROOT", "artifacts"), "S5.10.3", "Each FAIL/WARN branch fires on its condition", "T2",
                    os.environ.get("EV_SOURCE", "ci/preflight-rows.py host"))
    story = Story(w, HOST_SCRIPT, "host-preflight")
    shutil.rmtree(WORK, ignore_errors=True)
    os.makedirs(WORK)
    fakebin = os.path.join(WORK, "bin")
    os.makedirs(fakebin)
    for name, var in (("systemctl", "EV_SC_RULES"), ("podman", "EV_PODMAN_RULES")):
        real = shutil.which(name)
        with open(os.path.join(fakebin, name), "w") as f:
            f.write(FAKE % {"name": name, "var": var, "real": real or f"/usr/bin/{name}"})
        os.chmod(os.path.join(fakebin, name), 0o755)
    base = run([HOST_SCRIPT])
    w.write("baseline", base.stdout + base.stderr,
            "EV-STATE: desktop-preflight with nothing staged: the rows that already fire on this host")
    already = [l for l in base.stdout.splitlines() if ": FAIL: " in l or ": WARN: " in l]
    w.note(f"with nothing staged, {len(already)} FAIL/WARN line(s): " + (" | ".join(already) or "none"))
    error = None
    try:
        for n, case in enumerate(host_cases(w), 1):
            script = host_script(case, n, fakebin)
            holder = made = None
            dirs = []                           # every missing directory a tmpfs needs, top first
            for target, _, _ in case.get("tmpfs", []):
                chain, q = [], target
                while q != "/" and not os.path.isdir(q):
                    chain.append(q)
                    q = os.path.dirname(q)
                dirs += [c for c in reversed(chain) if c not in dirs]
            try:
                for p in dirs:
                    os.mkdir(p)
                made = [p for p in case.get("host_files", []) if not os.path.exists(p)]
                for p in made:
                    open(p, "w").close()
                if case.get("holder"):          # no card to hold: the case cannot be staged
                    if not os.path.exists(case["holder"]):
                        raise RuntimeError(f"{case['id']}: {case['holder']} does not exist; nothing to hold")
                    holder = subprocess.Popen(["sleep", "60"], stdin=open(case["holder"]))
                r = run(["unshare", "-m", "--propagation", "private", "bash", "-c", script])
            finally:
                if holder:
                    holder.kill()
                for p in made or []:
                    os.remove(p)
                for p in reversed(dirs):
                    os.rmdir(p)
            out = r.stdout + r.stderr
            made_note = "".join(f"# created for the run, removed after: {p}\n" for p in dirs + (made or []))
            w.write(f"{case['id']}", f"# staged: {case['what']}\n{made_note}# in: unshare -m --propagation private\n{script}"
                    f"# desktop-preflight's output (exit {r.returncode}):\n{out}",
                    f"EV-STATE: {case['id']}: {case['what']}: the staging and the preflight's report")
            story.expect(case["id"], r.stdout, case["rows"], case.get("each"))
        story.finish()
    except Exception as e:                      # a broken case is a FAIL, not a crash
        error = f"{type(e).__name__}: {e}"
    finally:
        shutil.rmtree(WORK, ignore_errors=True)
    return 0 if w.finish(error) == "PASS" else 1


# --- S5.11.2: the container's preflight-check.sh -----------------------------------

def container_cases():
    bare = "(none: no devices, no mounts, no desktop-init)"
    return [
        dict(id="bare", what="the image alone: none of the quadlet's devices or mounts", setup="",
             rows=["no /dev/dri/card* visible: X cannot start. The quadlet's AddDevice= for /dev/dri did not resolve, host has no KMS video device, or (NVIDIA-driver host without GPU injection) nvidia_drm.modeset=1 is missing from the kernel cmdline",
                   "no /dev/input/event* visible: no keyboard/mouse will work. The quadlet's /dev/input bind mount is missing, device cgroup does not allow major 13, or host input drivers missing",
                   "no /dev/snd/controlC* visible: PipeWire will run but expose no audio devices",
                   "/dev/tty1 missing: the session cannot attach to a VT. The runtime did not expose VT devices AND the ensure-vt-devices mknod fallback failed (kernel without VT support?)",
                   "host udev database missing or empty: libinput/logind cannot enumerate devices. Mount the host's /run/udev read-only into the container (quadlet Volume=/run/udev:/run/udev:ro)",
                   "no /run/desktop-init.pid: preflight running outside desktop-init?",
                   "$d missing or not writable by desktop: exported sockets unavailable. Check the quadlet Volume= entries and the host tmpfiles.d config",
                   "no host shell material at /etc/desktop-container: the 'Host Terminal' menu entry will fail. Enable: the desktop-host-shell lines in the deploy tree's quadlet (deploy/README.md)"],
             each={"$d missing or not writable by desktop: exported sockets unavailable. Check the quadlet Volume= entries and the host tmpfiles.d config":
                   ["/tmp/.X11-unix missing", "/run/desktop-audio missing"]},
             note=bare),
        dict(id="no-setpriv", what="setpriv removed from the scratch container", setup='rm -f "$(command -v setpriv)"',
             rows=["setpriv not available; user-perspective checks run as root (less accurate)"]),
        dict(id="foreign-seat", what="a udev database entry tagged for seat1",
             setup="mkdir -p /run/udev/data && printf 'E:ID_SEAT=seat1\\n' > /run/udev/data/+input:input4",
             rows=["devices tagged for a non-default seat ($(echo \"$foreign\" | tr '\\n' ' ')): host 72-seat-*.rules not removed? desktop-seat-prep.service undoes these"]),
        dict(id="unreadable-card", what="a /dev/dri/card0 the desktop user cannot read (root's, mode 0600)",
             setup="mkdir -p /dev/dri && : > /dev/dri/card0 && chmod 0600 /dev/dri/card0",
             rows=["desktop user CANNOT read $n ($(stat -c '%a %U:%G' \"$n\")): gid alignment failed, see align-device-groups lines above. Escape hatch: needs_root_rights=yes in /etc/X11/Xwrapper.config"]),
        dict(id="pid-1", what="desktop-init's pid file says 1 (a private pid namespace)",
             setup="echo 1 > /run/desktop-init.pid",
             rows=["container init is PID 1: the container is NOT in the host pid namespace (--pid=host missing from the quadlet), so X clients cannot be attributed to pods"]),
        dict(id="sys-rw", what="the host's /sys bound in writable (--mount type=bind,src=/sys,dst=/sys)", setup="",
             opts=["--mount", "type=bind,source=/sys,destination=/sys"],
             rows=["/sys is mounted WRITABLE ($sysopts): the quadlet's Mount= for /sys did not apply - a writable /sys is one of the grants --privileged bundles"]),
        dict(id="no-sys", what="/sys unmounted inside the container (--cap-add SYS_ADMIN, umount -l /sys)",
             setup="umount -l /sys", opts=["--cap-add", "SYS_ADMIN", "--security-opt", "apparmor=unconfined"],
             rows=["/sys not found in /proc/self/mounts"]),
        dict(id="unknown-output", what="a monitors.conf declaring DP-9, which no DRM connector has (MONITORS_CONF)",
             setup="printf 'DP-9 1920x1080 +0+0\\n' > /tmp/ev-monitors.conf; export MONITORS_CONF=/tmp/ev-monitors.conf",
             rows=["fixed monitor layout names output(s)$unknown with no matching DRM connector ($(ls -d /sys/class/drm/card*-* 2>/dev/null | sed 's|.*/card[0-9]*-||' | tr '\\n' ' ')). Expected on NVIDIA (its output names differ from the kernel's); a typo anywhere else - that output would never be configured"]),
        dict(id="stub-with-nvidia", what="NVIDIA_CDI_STUB=1 in the environment (as the stub spec injects it) and a /dev/nvidiactl",
             setup=": > /dev/nvidiactl", opts=["-e", "NVIDIA_CDI_STUB=1"],
             rows=["NVIDIA hardware visible but the host injected a STUB CDI spec: nvidia container toolkit missing/broken on the host (desktop-cdi-refresh fell back). GPU acceleration is OFF; fix the host toolkit and restart",
                   "NVIDIA device nodes present but nvidia_drv.so NOT injected: X falls back to unaccelerated modesetting. Toolkit CDI spec lacks the X driver, see README ('nvidia_drv.so missing')"]),
        dict(id="driver-no-device", what="an nvidia_drv.so and no NVIDIA device node",
             setup="mkdir -p /usr/lib64/xorg/modules/drivers && : > /usr/lib64/xorg/modules/drivers/nvidia_drv.so",
             rows=["nvidia_drv.so present but no NVIDIA device nodes: GPU not injected (missing AddDevice=nvidia.com/gpu=all drop-in?)"]),
    ]


def cmd_container(image):
    w = StoryWriter(os.environ.get("EV_ROOT", "artifacts"), "S5.11.2", "Each check fires", "T2",
                    os.environ.get("EV_SOURCE", "ci/preflight-rows.py container"))
    story = Story(w, CONTAINER_SCRIPT, "preflight")
    runner = os.environ.get("RUN", "sudo podman run").split()
    error = None
    try:
        for case in container_cases():
            inner = (case["setup"] + "\n" if case["setup"] else "") + "/usr/local/bin/preflight-check.sh"
            cmd = runner + ["--rm", "--network=none", "--user", "0"] + case.get("opts", []) + [image, "bash", "-c", inner]
            r = run(cmd)
            shown = " ".join(c if re.fullmatch(r"[\w@%+=:,./-]+", c) else "'" + c.replace("'", "'\\''") + "'" for c in cmd)
            w.write(case["id"], f"# staged: {case['what']}\n$ {shown}\n# exit {r.returncode}\n{r.stdout}{r.stderr}",
                    f"EV-LOG-DESKTOP: {case['id']}: {case['what']}: the podman run command and the preflight block")
            story.expect(case["id"], r.stdout, case["rows"], case.get("each"))
        story.finish()
    except Exception as e:
        error = f"{type(e).__name__}: {e}"
    return 0 if w.finish(error) == "PASS" else 1


def main():
    if len(sys.argv) < 2:
        raise SystemExit(__doc__)
    what = sys.argv[1]
    if what == "rows":
        for lvl, ln, t in rows(sys.argv[2]):
            print(f"{lvl}\t{ln}\t{t}\t{pattern(t)}")
    elif what == "host":
        sys.exit(cmd_host())
    elif what == "container":
        sys.exit(cmd_container(sys.argv[2] if len(sys.argv) > 2 else "localhost/desktop-container:latest"))
    else:
        raise SystemExit(__doc__)


if __name__ == "__main__":
    main()
