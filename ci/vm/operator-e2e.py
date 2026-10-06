#!/usr/bin/env python3
"""E11, the operator's experience end to end: a person at the display working
the desktop through its own controls, driven the way that person drives it.

Usage: operator-e2e.py [--only ID[,ID...]] [--qmp SOCK] [--ssh-port PORT]
                       [--ssh-key FILE] [--art DIR]
       operator-e2e.py --maint STEP [--arg ARG] [--out FILE] [...]
                       one step of a maintainer journey's operator half
                       (MAINT_STEPS; ci/vm/maint-e2e.sh calls it)

Run from ci/vm by vm-e2e.sh after the hotplug checks and before phase 2, once
`vm-guest.sh operator-setup` has started the observer container.

THE ONE RULE. Every pointer and key event reaches the machine through QEMU's
own input devices - QMP input-send-event, the virtio tablet and keyboard,
evdev, Xorg - the way a hand on a mouse would, never through XTEST or any
other injection into the X server. Injecting into X would skip the half of
the path an operator depends on and would not even see the same thing: mwm
grabs the server while it drags a window outline, which stalls an injecting
client and does not stall a device. The harness only LOOKS at X - xwininfo
and xprop run from a separate, confined observer container - and at QEMU's
own screendumps.

EVIDENCE. Each story writes <art>/<story>/ (Requirements.md, "Evidence
standard"): evidence.md is the reviewer's entry point; timeline.log is every
input event, guest command and check of that story with its timestamp;
qemu.log is the QMP transcript (EV-QEMU) - the proof that the input came from
QEMU's devices. <art>/timeline.log is the same for the whole phase.

A failed story does not stop the run. Its directory records the failure with
diagnostics, the desktop is put back (menus closed, test windows gone) and the
next story runs, so one red run shows every operator regression at once. The
exit status is non-zero if any story failed.
"""
import argparse
import codecs
import contextlib
import difflib
import json
import math
import os
import re
import shlex
import socket
import struct
import subprocess
import sys
import threading
import time
import traceback
import wave
from datetime import datetime, timezone

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
import evlib  # noqa: E402  (ci/evlib.py: the evidence format every tier shares)

DESKTOP_IMAGE = "localhost/desktop-container:latest"
TESTCLIENT_IMAGE = "localhost/desktop-testclient:latest"
OBSERVER = "op-observer"

# The palette the operator is promised (image/session/Xdefaults and the
# xsetroot in xinitrc.desktop), as the 8-bit RGB a screendump reads back.
ROOT_RGB = (0x10, 0x12, 0x16)
XTERM_BG = (0x16, 0x19, 0x1D)
FOCUSED = (0x41, 0x63, 0x7F)
UNFOCUSED = (0x22, 0x26, 0x2D)
MENU_BG = (0x22, 0x26, 0x2D)

# DefaultRootMenu in image/session/mwmrc, top to bottom: the f.title, then the
# six entries. The separator draws no text, so it is not a row here.
ROOT_MENU = ["Desktop", "New Terminal", "Host Terminal", "Refresh",
             "Pack Icons", "Restart mwm", "Quit session"]

# A sink terminal: shows its word on the first row, then appends every line
# typed or pasted into it to a file the harness reads back.
SINK = 'printf "%s\\n" "$0"; while read -r l; do printf "%s\\n" "$l" >> "$1"; done'

# One probe for the whole window tree plus each top-level window's map state:
# `xwininfo -tree` lists unmapped windows too (iconified frames, posted-then-
# withdrawn menus), so the tree alone cannot say what is on screen.
TREE_SCRIPT = r'''
xwininfo -root -tree
echo "@@tops"
xwininfo -root -children | while read -r id rest; do
    case "$id" in
        0x*) printf '%s %s\n' "$id" "$(xwininfo -id "$id" 2>/dev/null | grep -E 'Map State|Override Redirect' | tr -s ' \n' ' ')" ;;
    esac
done
'''
# Geometry, state and identity of specific windows.
INFO_SCRIPT = r'''
for w in "$@"; do
    echo "@@win $w"
    xwininfo -id "$w" 2>&1
    xprop -id "$w" WM_STATE WM_NAME WM_CLASS _NET_WM_PID WM_NORMAL_HINTS 2>&1
done
'''


def stamp():
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.%f")[:-3] + "Z"


def wait_until(fn, timeout, interval=0.5):
    """Poll fn until it returns something truthy; return its last value."""
    end = time.monotonic() + timeout
    while True:
        value = fn()
        if value or time.monotonic() >= end:
            return value
        time.sleep(interval)


class StoryFailed(Exception):
    """An assertion about what the operator sees or gets did not hold."""


# --- evidence -----------------------------------------------------------------

class Run:
    """The whole phase: the run-wide timeline (EV-TIMELINE) and the story
    whose evidence directory is open."""

    def __init__(self, art):
        self.art = art
        os.makedirs(art, exist_ok=True)
        self._timeline = open(os.path.join(art, "timeline.log"), "a", buffering=1)
        self._lock = threading.Lock()
        self.story = None

    def log(self, kind, text, echo=False):
        sid = self.story.sid if self.story else "-"
        line = f"{stamp()} {sid:<8} {kind:<6} {text}"
        with self._lock:
            self._timeline.write(line + "\n")
            if self.story:
                self.story.log_line(kind, line)
        if echo:
            print(f"== operator({sid}): {text}", flush=True)


# What every operator story's evidence.md says about how it was driven.
INTRO = ("Every pointer and key event went through QEMU's own input devices "
         "(`qemu.log`); the harness only looked at X (xwininfo/xprop from the "
         "observer container) and at QEMU screendumps.")


class Story(evlib.StoryWriter):
    """One story's evidence directory, in the format every tier shares
    (ci/evlib.py), plus the operator phase's QMP transcript (qemu.log)."""

    def __init__(self, run, sid, title):
        self.run = run
        self.sid = sid
        d = os.path.join(run.art, sid)
        os.makedirs(d, exist_ok=True)
        # Opened first, so the story's own timeline has its "begin" line too.
        self._tl = open(os.path.join(d, "timeline.log"), "w", buffering=1)
        self._qemu = open(os.path.join(d, "qemu.log"), "w", buffering=1)
        run.story = self
        super().__init__(run.art, sid, title, tier="T3",
                         source=os.environ.get("EV_SOURCE", "the VM e2e operator phase"),
                         intro=INTRO)

    def log(self, kind, text):
        # evlib's own timeline writes go through the run, so the run-wide and
        # the story's timeline get one line each, not two.
        self.run.log(kind, text)

    def log_line(self, kind, line):
        if self._tl:
            self._tl.write(line + "\n")
        if kind == "qmp" and self._qemu:
            self._qemu.write(line + "\n")

    def check(self, ok, claim, detail=""):
        text = claim + (f" ({detail})" if detail else "")
        ok = super().check(ok, text)
        print(f"== operator({self.sid}): {'PASS' if ok else 'FAIL'} {text}", flush=True)
        if not ok:
            raise StoryFailed(claim + (f": {detail}" if detail else ""))

    def record(self, text):
        self.note(text)
        print(f"== operator({self.sid}): {text}", flush=True)

    def finish(self, error=None, trace=None):
        status = super().finish(error, trace)
        self.run.story = None
        self._tl.close()
        self._qemu.close()
        return status


# --- the machine: QMP ---------------------------------------------------------

class QMP:
    def __init__(self, path, run):
        self.run = run
        self._lock = threading.Lock()
        self._sock = socket.socket(socket.AF_UNIX)
        self._sock.settimeout(120)
        self._sock.connect(path)
        self._f = self._sock.makefile("rw")
        self._f.readline()                                  # greeting
        self.cmd("qmp_capabilities")

    def cmd(self, execute, arguments=None, note=None, log=True):
        msg = {"execute": execute}
        if arguments is not None:
            msg["arguments"] = arguments
        text = json.dumps(msg, separators=(",", ":"))
        with self._lock:
            if log:
                self.run.log("qmp", text + (f"   # {note}" if note else ""))
            self._f.write(text + "\n")
            self._f.flush()
            while True:
                line = self._f.readline()
                if not line:
                    raise RuntimeError("QMP connection closed")
                reply = json.loads(line)
                if "error" in reply:
                    raise RuntimeError(f"QMP {execute}: {reply['error'].get('desc', reply['error'])}")
                if "return" in reply:
                    return reply["return"]
                # anything else is an asynchronous event

    def close(self):
        with contextlib.suppress(OSError):
            self._sock.close()


class Machine:
    """The VM as the operator meets it: a screen, a tablet, a keyboard and a
    sound output, all of them QEMU's."""

    def __init__(self, run, qmp_path):
        self.run = run
        self.qmp = QMP(qmp_path, run)
        self.width = self.height = None
        self._last_abs = {}         # the last absolute position sent, per device

    @staticmethod
    def abs_value(p, dim):
        # Where X lands an absolute value v from the virtio tablet (range
        # 0..0x7fff): libinput scales it over max-min+1 to xf86-input-libinput's
        # 0..0xffff axis, and the server scales that over 0x10000 to the screen,
        # truncating. So pixel = v * 0xffff/0x8000 * dim/0x10000. Aiming at the
        # pixel's centre keeps the truncation on the pixel asked for; the naive
        # p/dim*0x7fff lands one pixel short over most of the screen, which an
        # exact-geometry assertion would read as a window moving wrongly.
        v = round((p + 0.5) * 0x8000 * 0x10000 / (0xFFFF * dim))
        return max(0, min(0x7FFF, v))

    @staticmethod
    def _to(events, device):
        """input-send-event's arguments. With a device (a display: vga0), the
        events go to the input device bound to that display's head 0 - one
        added with display=vga0 - and not to the unbound ones."""
        args = {"events": events}
        if device:
            args["device"], args["head"] = device, 0
        return args

    def pointer(self, x, y, log=True, device=None):
        vx, vy = self.abs_value(x, self.width), self.abs_value(y, self.height)
        key = device or ""
        if self._last_abs.get(key, (vx, vy)) == (vx, vy):
            # The guest's input core drops an absolute value equal to the
            # device's last one. A move to where this device already was would
            # leave X's pointer wherever another device had taken it, and the
            # click after it would land there: S7.7.2's click on the session's
            # xterm in run 37345104044 went to bare root that way. So first
            # one unit off, as an event of its own: a USB tablet reports only
            # its latest position at each poll.
            self.qmp.cmd("input-send-event", self._to([
                {"type": "abs", "data": {"axis": "x", "value": vx - 1 if vx else vx + 1}},
                {"type": "abs", "data": {"axis": "y", "value": vy}},
            ], device), note=f"pointer one unit off ({x},{y}) first, so that the move to it registers", log=log)
            time.sleep(0.05)
        self.qmp.cmd("input-send-event", self._to([
            {"type": "abs", "data": {"axis": "x", "value": vx}},
            {"type": "abs", "data": {"axis": "y", "value": vy}},
        ], device), note=f"pointer to ({x},{y})" + (f" through {device}'s device" if device else ""), log=log)
        self._last_abs[key] = (vx, vy)

    def button(self, button, down, device=None):
        self.qmp.cmd("input-send-event", self._to([
            {"type": "btn", "data": {"button": button, "down": down}}], device),
            note=f"{button} button {'down' if down else 'up'}" + (f" through {device}'s device" if device else ""))

    def key(self, qcode, down, device=None):
        self.qmp.cmd("input-send-event", self._to([
            {"type": "key", "data": {"key": {"type": "qcode", "data": qcode}, "down": down}}], device),
            note=f"key {qcode} {'down' if down else 'up'}" + (f" through {device}'s device" if device else ""))

    def rel(self, dx, dy):
        """Relative motion, which QEMU gives to the current mouse (mouse_set)."""
        self.qmp.cmd("input-send-event", {"events": [
            {"type": "rel", "data": {"axis": "x", "value": dx}},
            {"type": "rel", "data": {"axis": "y", "value": dy}}]}, note=f"relative motion ({dx},{dy})")

    def screendump(self, path, log=True):
        path = os.path.abspath(path)
        try:
            self.qmp.cmd("screendump", {"filename": path, "format": "png"}, log=log)
        except RuntimeError as e:
            if "format" not in str(e):
                raise
            # QEMU < 7.1 has no PNG screendump: take PPM and convert it.
            self.qmp.cmd("screendump", {"filename": path + ".ppm"}, log=log)
            subprocess.run(["convert", path + ".ppm", path], check=True, timeout=60)
            os.unlink(path + ".ppm")
        if not wait_until(lambda: os.path.exists(path) and os.path.getsize(path) > 0, 10, 0.1):
            raise RuntimeError(f"screendump {path} was not written")

    def hmp(self, line):
        return self.qmp.cmd("human-monitor-command", {"command-line": line})

    def device_add(self, **props):
        self.qmp.cmd("device_add", props)

    def device_del(self, dev_id):
        self.qmp.cmd("device_del", {"id": dev_id})

    def close(self):
        self.qmp.close()


# --- the machine: the guest, over ssh -----------------------------------------

class Guest:
    """Commands on the VM host, as root. Everything about X goes through the
    observer container; everything about the session through the desktop
    container, as its user."""

    def __init__(self, run, port, key):
        self.run = run
        # A multiplexed connection: the stories make hundreds of short probes,
        # and a fresh handshake each would cost more than the probes do.
        self.ssh = ["ssh", "-q", "-p", str(port), "-i", key,
                    "-o", "StrictHostKeyChecking=no", "-o", "UserKnownHostsFile=/dev/null",
                    "-o", "ConnectTimeout=10", "-o", "ServerAliveInterval=5",
                    "-o", "ServerAliveCountMax=3", "-o", "ControlMaster=auto",
                    "-o", "ControlPath=/tmp/op-e2e-ssh-%C", "-o", "ControlPersist=300",
                    "rocky@127.0.0.1"]

    def sh(self, script, timeout=90, check=True, label=None):
        self.run.log("guest", label or script)
        try:
            p = subprocess.run(self.ssh + ["sudo bash -c " + shlex.quote(script)],
                               capture_output=True, encoding="utf-8", errors="replace",
                               timeout=timeout)
        except subprocess.TimeoutExpired:
            raise RuntimeError(f"guest command timed out after {timeout}s: {label or script}")
        if check and p.returncode != 0:
            raise RuntimeError(f"guest command failed (rc={p.returncode}): {label or script}\n"
                               f"{p.stdout}{p.stderr}")
        return p.stdout

    def xprobe(self, script, *args, label=None, check=True):
        # CDI's env edits reach the observer's own process (its pid 1) but not
        # a `podman exec` session, so the session takes DISPLAY from pid 1:
        # Requirements.md S9.2.1 allows that, and no -e with a value of ours.
        label = label or f"observer: {script.strip()}"
        script = "export \"$(tr '\\0' '\\n' </proc/1/environ | grep '^DISPLAY=')\"; " + script
        return self.sh(shlex.join(["podman", "exec", OBSERVER, "sh", "-c", script, "sh", *args]),
                       label=label, check=check)

    def desk(self, argv, user="desktop", detach=False, check=True, timeout=60):
        return self.sh(shlex.join(
            ["podman", "exec"] + (["-d"] if detach else [])
            + ["-u", user, "-e", "DISPLAY=:0", "-e", "HOME=/home/desktop",
               "-e", "XDG_RUNTIME_DIR=/run/user/61000", "desktop"] + list(argv)),
            check=check, timeout=timeout)

    def client_run(self, name, argv, devices=("display",), image=DESKTOP_IMAGE, copy_in=None):
        # A separate, confined container per application, holding nothing
        # but the CDI device it asks for - the client contract (F7.1).
        ctr = f"op-{name}"
        devs = [f"--device=desktop.local/{d}=all" for d in devices]
        if copy_in:
            self.sh(shlex.join(["podman", "create", "--rm", "--name", ctr, *devs, image, *argv]))
            for dst, src in copy_in.items():
                self.sh(shlex.join(["podman", "cp", src, f"{ctr}:{dst}"]))
            self.sh(shlex.join(["podman", "start", ctr]))
        else:
            self.sh(shlex.join(["podman", "run", "-d", "--rm", "--name", ctr, *devs, image, *argv]))

    def client_exec(self, name, argv, check=True):
        return self.sh(shlex.join(["podman", "exec", f"op-{name}", *argv]), check=check)

    def client_stop(self, name):
        self.sh(f"podman rm -f -t 2 op-{name} >/dev/null 2>&1 || true")

    def client_exists(self, name):
        return self.sh(f"podman container exists op-{name} && echo yes || echo no").strip() == "yes"

    def client_inspect(self, name):
        out = self.sh(shlex.join(["podman", "inspect", f"op-{name}", "--format",
                                  "{{.Id}} {{.State.Pid}} {{.RestartCount}} {{.State.StartedAt}}"]))
        cid, pid, restarts, started = out.strip().split(" ", 3)
        return {"id": cid, "pid": int(pid), "restarts": int(restarts), "started": started}

    def stop_clients(self):
        self.sh("podman ps -a --format '{{.Names}}' | grep '^op-' | grep -vx " + OBSERVER
                + " | xargs -r podman rm -f -t 2 >/dev/null 2>&1; true", label="remove the test's client containers")

    def ps(self):
        return self.sh("ps -eo pid,ppid,sid,user:16,lstart,comm,args --no-headers", label="ps")

    def pid_alive(self, pid):
        return self.sh(f"test -d /proc/{int(pid)} && echo yes || echo no").strip() == "yes"

    def fetch(self, path, timeout=60):
        """A file's bytes from the VM host: sh() reads text, and a PNG is not."""
        self.run.log("guest", f"fetch {path}")
        p = subprocess.run(self.ssh + ["sudo cat " + shlex.quote(path)], capture_output=True,
                           timeout=timeout)
        if p.returncode != 0:
            raise RuntimeError(f"could not fetch {path} from the VM (rc={p.returncode}): "
                               f"{p.stderr.decode('utf-8', 'replace')}")
        return p.stdout

    def close(self):
        # End the multiplexed connection's master rather than leave it to
        # time out on its own.
        subprocess.run(self.ssh[:-1] + ["-O", "exit", self.ssh[-1]], capture_output=True, timeout=20)


# --- looking at the screen ------------------------------------------------------

class Image:
    """A screendump's pixels, decoded on first use: most screendumps are
    evidence only and are never read back."""

    def __init__(self, path):
        self.path = path
        self.w = self.h = None
        self._data = None

    def _pixels(self):
        if self._data is None:
            raw = subprocess.run(["convert", self.path, "-depth", "8", "ppm:-"], check=True,
                                 capture_output=True, timeout=60).stdout
            fields, pos = [], 0
            while len(fields) < 4:             # P6, width, height, maxval
                while raw[pos:pos + 1].isspace():
                    pos += 1
                start = pos
                while not raw[pos:pos + 1].isspace():
                    pos += 1
                fields.append(raw[start:pos])
            self.w, self.h = int(fields[1]), int(fields[2])
            self._data = raw[pos + 1:]
        return self._data

    def px(self, x, y):
        data = self._pixels()
        i = (y * self.w + x) * 3
        return tuple(data[i:i + 3])

    def text_rows(self, rect, thresh=150, margin=3, min_h=4):
        """Bands of rows holding light text inside rect, top to bottom: one per
        menu entry. Insensitive (greyed) entries draw no light pixels, so they
        are not bands - which is how a disabled entry shows up here."""
        self._pixels()
        x0, y0, w, h = rect
        rows = []
        for y in range(max(0, y0), min(self.h, y0 + h)):
            hit = False
            for x in range(max(0, x0 + margin), min(self.w, x0 + w - margin)):
                r, g, b = self.px(x, y)
                if r + g + b > 3 * thresh:
                    hit = True
                    break
            rows.append(hit)
        bands, start = [], None
        for i, hit in enumerate(rows + [False]):
            if hit and start is None:
                start = i
            elif not hit and start is not None:
                if i - start >= min_h:
                    bands.append((y0 + start, y0 + i - 1))
                start = None
        return bands

    def bbox(self, rect, rgb):
        """Bounding box (x0, y0, x1, y1) of the pixels of exactly rgb in rect."""
        self._pixels()
        x0, y0, w, h = rect
        xs, ys = [], []
        for y in range(max(0, y0), min(self.h, y0 + h)):
            for x in range(max(0, x0), min(self.w, x0 + w)):
                if self.px(x, y) == rgb:
                    xs.append(x)
                    ys.append(y)
        return (min(xs), min(ys), max(xs), max(ys)) if xs else None


# --- looking at X -----------------------------------------------------------------

TREE_LINE = re.compile(
    r'^(?P<indent>\s*)(?P<id>0x[0-9a-f]+) (?P<name>"(?:[^"\\]|\\.)*"|\(has no name\)): '
    r'\((?P<cls>[^)]*)\)\s+(?P<w>\d+)x(?P<h>\d+)\+(?P<x>-?\d+)\+(?P<y>-?\d+)'
    r'\s+\+(?P<ax>-?\d+)\+(?P<ay>-?\d+)')


class Win:
    def __init__(self, m):
        self.id = m["id"]
        self.name = m["name"][1:-1] if m["name"].startswith('"') else None
        self.cls = m["cls"]
        self.w, self.h = int(m["w"]), int(m["h"])
        self.x, self.y = int(m["x"]), int(m["y"])
        self.ax, self.ay = int(m["ax"]), int(m["ay"])
        self.depth = len(m["indent"])
        self.parent, self.children = None, []

    @property
    def instance(self):
        m = re.match(r'"([^"]*)"', self.cls)
        return m.group(1) if m else None

    def rect(self):
        return (self.ax, self.ay, self.w, self.h)

    def __repr__(self):
        return f"{self.id} {self.w}x{self.h}+{self.ax}+{self.ay}"


def contains(rect, x, y):
    rx, ry, rw, rh = rect
    return rx <= x < rx + rw and ry <= y < ry + rh


def overlaps(a, b):
    return a[0] < b[0] + b[2] and b[0] < a[0] + a[2] and a[1] < b[1] + b[3] and b[1] < a[1] + a[3]


class XState:
    """One look at the window tree. Top-level windows are listed top-most
    first: xwininfo prints XQueryTree's bottom-to-top list in reverse."""

    def __init__(self, text):
        self.text = text
        tree, _, tops = text.partition("@@tops")
        self.tops, stack = [], []
        for line in tree.splitlines():
            m = TREE_LINE.match(line)
            if not m:
                continue
            w = Win(m)
            while stack and stack[-1].depth >= w.depth:
                stack.pop()
            if stack:
                w.parent = stack[-1]
                stack[-1].children.append(w)
            else:
                self.tops.append(w)
            stack.append(w)
        self.map_state, self.override = {}, {}
        for line in tops.splitlines():
            m = re.match(r"(0x[0-9a-f]+)\s.*Map State:\s*(\w+)", line)
            if m:
                self.map_state[m.group(1)] = m.group(2)
            m = re.match(r"(0x[0-9a-f]+)\s.*Override Redirect State:\s*(\w+)", line)
            if m:
                self.override[m.group(1)] = m.group(2)

    def walk(self, wins=None):
        for w in self.tops if wins is None else wins:
            yield w
            yield from self.walk(w.children)

    def by_id(self, wid):
        return next((w for w in self.walk() if w.id == wid), None)

    def clients(self, instance):
        return [w for w in self.walk() if w.instance == instance]

    def client(self, instance):
        found = self.clients(instance)
        return found[0] if found else None

    def resolve(self, win):
        """This look's copy of a window, by id: a Win from an earlier look
        carries that look's geometry and parents."""
        wid = win.id if isinstance(win, Win) else win
        found = self.by_id(wid)
        if found is None:
            raise StoryFailed(f"window {wid} is no longer in the window tree")
        return found

    def frame_of(self, win):
        win = self.resolve(win)
        while win.parent is not None:
            win = win.parent
        return win

    def mapped(self, top):
        return self.map_state.get(top.id) == "IsViewable"

    def mapped_tops(self):
        return [t for t in self.tops if self.mapped(t)]

    def new_mapped(self, before):
        old = {t.id for t in before.mapped_tops()}
        return [t for t in self.mapped_tops() if t.id not in old]

    def stack_pos(self, win):
        frame = self.frame_of(win)
        return next(i for i, t in enumerate(self.tops) if t.id == frame.id)

    def parts(self, client):
        """mwm's frame around a client: where its controls are."""
        client = self.resolve(client)
        frame = self.frame_of(client)
        wrapper = next(ch for ch in frame.children if client in self.walk([ch]))
        border = wrapper.x
        title = next(ch for ch in frame.children
                     if ch.x == border and ch.y == border and ch.h == wrapper.y - border)
        t, mid = title.h, title.ay + title.h // 2
        return {
            "frame": frame, "border": border, "title": title,
            "drag": (title.ax + title.w // 2, mid),
            "menu_btn": (title.ax + t // 2, mid),
            "min_btn": (title.ax + title.w - t - t // 2, mid),
            "max_btn": (title.ax + title.w - t // 2, mid),
            # The corner handle, on the frame's outer edge: the inner corner is
            # covered by the client window.
            "corner": (frame.ax + frame.w - 1 - border // 2, frame.ay + frame.h - 1 - border // 2),
            # A flat stretch of the left border, clear of its bevel: where the
            # focused/unfocused colour is sampled.
            "swatch": (frame.ax + border // 2, frame.ay + frame.h // 2),
        }


class WinInfo:
    def __init__(self, wid, text):
        self.id, self.text = wid, text
        self.gone = "BadWindow" in text or "No such window" in text

        def grab(rx, cast=str):
            m = re.search(rx, text, re.M)
            return cast(m.group(1)) if m else None

        self.ax = grab(r"Absolute upper-left X:\s+(-?\d+)", int)
        self.ay = grab(r"Absolute upper-left Y:\s+(-?\d+)", int)
        self.w = grab(r"^\s*Width:\s+(\d+)", int)
        self.h = grab(r"^\s*Height:\s+(\d+)", int)
        self.map_state = grab(r"Map State:\s+(\w+)")
        self.geometry = grab(r"-geometry\s+(\S+)")
        self.wm_state = grab(r"window state:\s+(\w+)")
        self.icon = grab(r"icon window:\s+(0x[0-9a-f]+)")
        self.name = grab(r'^WM_NAME\(\w+\) = "(.*)"$')
        self.pid = grab(r"_NET_WM_PID\(CARDINAL\) = (\d+)", int)
        m = re.search(r"resize increment: (\d+) by (\d+)", text)
        self.inc = (int(m.group(1)), int(m.group(2))) if m else None
        m = re.search(r"base size: (\d+) by (\d+)", text)
        self.base = (int(m.group(1)), int(m.group(2))) if m else None

    @property
    def rect(self):
        return (self.ax, self.ay, self.w, self.h)

    @property
    def cells(self):
        """xterm's own idea of its size, columns x rows, from -geometry."""
        m = re.match(r"(\d+)x(\d+)", self.geometry or "")
        return (int(m.group(1)), int(m.group(2))) if m else None


# --- the context the stories run in -------------------------------------------------

class Ctx:
    def __init__(self, run, machine, guest):
        self.run, self.m, self.g = run, machine, guest
        self.st = None
        self.width = self.height = None

    # -- setup --
    def measure_screen(self):
        out = self.g.xprobe("xdpyinfo | grep dimensions:", label="observer: xdpyinfo dimensions")
        m = re.search(r"(\d+)x(\d+) pixels", out)
        if not m:
            raise RuntimeError(f"could not read the screen size from: {out!r}")
        self.width, self.height = int(m.group(1)), int(m.group(2))
        self.m.width, self.m.height = self.width, self.height
        self.run.log("note", f"screen is {self.width}x{self.height}", echo=True)

    # -- looking --
    def xstate(self, check=True):
        out = self.g.xprobe(TREE_SCRIPT, label="observer: window tree + map states", check=check)
        return XState(out)

    def info(self, *wids):
        out = self.g.xprobe(INFO_SCRIPT, *wids, label=f"observer: xwininfo/xprop {' '.join(wids)}",
                            check=False)
        result = {}
        for chunk in out.split("@@win ")[1:]:
            wid, _, body = chunk.partition("\n")
            result[wid.strip()] = WinInfo(wid.strip(), body)
        for wid in wids:
            result.setdefault(wid, WinInfo(wid, "BadWindow (no output)"))
        return result

    def one(self, wid):
        return self.info(wid)[wid]

    def shot(self, moment, what):
        name = self.st.name(moment, "png")
        self.m.screendump(self.st.path(name))
        self.st.attach(name, what)
        return Image(self.st.path(name))

    def save_state(self, moment, text, what):
        return self.st.write(moment, text, what)

    def save_cmd(self, moment, cmd, what, label=None):
        """evidence.sh's ev_save: the command, then what it printed. Never an
        empty file, so 'printed nothing' reads differently from 'never ran'."""
        out = self.g.sh(f"{cmd}; true", label=label or cmd)
        self.st.write(moment, f"$ {cmd}\n" + (out if out.strip() else "(no output)\n"), what)
        return out

    def diff_kept(self, moment, a_name, a, b_name, b, what):
        """EV-DIFF of two texts already written to the story as a_name and
        b_name (Ctx.diff writes both sides itself)."""
        d = "".join(difflib.unified_diff(a.splitlines(True), b.splitlines(True), a_name, b_name))
        return self.st.write(moment, d or "(no difference)\n", what, ext="diff")

    def diff(self, moment, before, after, what):
        # Rule 1 (Requirements.md, evidence standard): before and after are
        # kept as files beside the diff, never the diff alone.
        b = self.st.write(f"{moment}-before", before, f"the 'before' side of {moment}")
        a = self.st.write(f"{moment}-after", after, f"the 'after' side of {moment}")
        d = "".join(difflib.unified_diff(before.splitlines(True), after.splitlines(True), b, a))
        return self.st.write(moment, d or "(no difference)\n", what, ext="diff")

    def pids(self, moment):
        """EV-PIDS: the processes that prove what did and did not restart."""
        out = self.g.ps()
        keep, table = [], {}
        for line in out.splitlines():
            f = line.split(None, 10)
            if len(f) < 10:
                continue
            pid, ppid, sid, user, comm = f[0], f[1], f[2], f[3], f[9]
            if comm in ("desktop-init", "xinit", "Xorg", "mwm", "xterm", "pipewire",
                        "pipewire-pulse", "wireplumber", "paplay") \
                    or user in ("desktop", "desktop-shell"):
                keep.append(line)
                table.setdefault(comm, []).append({"pid": int(pid), "ppid": int(ppid),
                                                   "sid": int(sid), "user": user,
                                                   "args": f[10] if len(f) > 10 else ""})
        self.st.write(moment, "PID PPID SID USER STARTED COMM ARGS\n" + "\n".join(keep) + "\n",
                      "pid, ppid, sid, user, start time and command of the desktop's processes")
        return table

    def session_pid(self, table, comm):
        procs = [p for p in table.get(comm, []) if p["user"] == "desktop"]
        return procs[0]["pid"] if len(procs) == 1 else None

    @contextlib.contextmanager
    def video(self, moment, what, fps=2.0):
        """EV-VIDEO: screendumps at fps for the duration of the block. QEMU
        writes each frame as a PPM, its raw pixels, and the frames become
        PNGs after the block: QEMU compresses a PNG screendump in its main
        loop, where its sound cards run, and an emulated HDA codec drops
        audio when that loop falls behind (qmp-tool.py's video says more)."""
        name = self.st.name(moment, "")
        frames = self.st.path(name)
        os.makedirs(frames, exist_ok=True)
        stop, index = threading.Event(), []

        def loop():
            i = 0
            while not stop.is_set():
                t0 = time.monotonic()
                i += 1
                ppm = os.path.abspath(os.path.join(frames, f"frame-{i:04d}.ppm"))
                try:
                    self.m.qmp.cmd("screendump", {"filename": ppm, "format": "ppm"}, log=False)
                except Exception as e:                         # noqa: BLE001
                    index.append(f"frame {i:04d} failed: {e}")
                    return
                index.append(f"frame-{i:04d}.png {stamp()} (QEMU wrote it in "
                             f"{1000 * (time.monotonic() - t0):.0f} ms)")
                stop.wait(max(0.0, 1.0 / fps - (time.monotonic() - t0)))

        t = threading.Thread(target=loop, daemon=True)
        self.run.log("video", f"start {name}")
        t.start()
        try:
            yield
        finally:
            time.sleep(0.6)
            stop.set()
            t.join(30)
            for f in sorted(os.listdir(frames)):
                if f.endswith(".ppm"):
                    ppm = os.path.join(frames, f)
                    subprocess.run(["convert", ppm, ppm[:-4] + ".png"], check=False, timeout=60)
                    os.unlink(ppm)
            self.run.log("video", f"stop {name} ({len(index)} frames)")
            with open(os.path.join(frames, "index.txt"), "w") as f:
                f.write("\n".join(index) + "\n")
            self.st.attach(name + "/", f"EV-VIDEO raw frames at {fps:g} fps; index.txt has each "
                           "frame's timestamp, to read against timeline.log, and how long QEMU took "
                           "to write it")
            gif = name + ".gif"
            pngs = sorted(p for p in os.listdir(frames) if p.endswith(".png"))
            if pngs:
                p = subprocess.run(["convert", "-delay", str(int(100 / fps)), "-loop", "0",
                                    *[os.path.join(frames, x) for x in pngs], "-resize", "50%",
                                    self.st.path(gif)], capture_output=True, timeout=300)
                if p.returncode == 0:
                    self.st.attach(gif, what)

    # -- doing: QEMU's tablet and keyboard only --
    def move(self, x, y, device=None):
        self.m.pointer(x, y, device=device)

    def glide(self, x0, y0, x1, y1, steps=10, dt=0.04, device=None):
        for i in range(1, steps + 1):
            self.m.pointer(round(x0 + (x1 - x0) * i / steps), round(y0 + (y1 - y0) * i / steps),
                           device=device)
            time.sleep(dt)

    def click(self, x, y, button="left", count=1, settle=0.5, device=None):
        self.move(x, y, device=device)
        time.sleep(0.15)
        for i in range(count):
            self.m.button(button, True, device=device)
            time.sleep(0.05)
            self.m.button(button, False, device=device)
            if i + 1 < count:
                time.sleep(0.07)
        time.sleep(settle)

    def drag(self, x0, y0, x1, y1, button="left", steps=16):
        self.move(x0, y0)
        time.sleep(0.2)
        self.m.button(button, True)
        time.sleep(0.3)
        self.glide(x0, y0, x1, y1, steps=steps, dt=0.08)
        time.sleep(0.3)
        self.m.button(button, False)
        time.sleep(0.8)

    def chord(self, *qcodes, settle=0.6, device=None):
        for q in qcodes:
            self.m.key(q, True, device=device)
            time.sleep(0.03)
        for q in reversed(qcodes):
            self.m.key(q, False, device=device)
            time.sleep(0.03)
        time.sleep(settle)

    def type(self, text, device=None):
        for ch in text:
            q, shift = KEYMAP[ch]
            if shift:
                self.chord("shift", q, settle=0.02, device=device)
            else:
                self.chord(q, settle=0.02, device=device)

    def type_line(self, text, settle=0.8, device=None):
        self.type(text, device=device)
        self.chord("ret", settle=settle, device=device)

    # -- finding room on the screen --
    def free_point(self, xs, room=(1, 1), margin=12):
        """A point on bare root - no mapped window under it - with `room`
        clear of the screen's edge to its right and below, for a menu."""
        rects = [t.rect() for t in xs.mapped_tops()
                 if not (t.w >= self.width and t.h >= self.height) and t.ax < self.width]
        for y in range(margin + 20, self.height - room[1] - margin, 16):
            for x in range(self.width - room[0] - margin, margin, -16):
                if not any(contains(r, x, y) for r in rects):
                    return (x, y)
        raise StoryFailed("there is no bare root window left on the screen to click on")

    def free_spot(self, xs, size, avoid=(), margin=16):
        """Top-left for a window of `size` that overlaps no mapped window and
        none of the rects in `avoid`."""
        rects = [t.rect() for t in xs.mapped_tops()
                 if not (t.w >= self.width and t.h >= self.height) and t.ax < self.width]
        rects += list(avoid)
        for y in range(margin, self.height - size[1] - margin, 16):
            for x in range(self.width - size[0] - margin, margin, -16):
                if not any(overlaps((x, y, size[0], size[1]), r) for r in rects):
                    return (x, y)
        raise StoryFailed(f"no room on the screen for a {size[0]}x{size[1]} window")

    # -- the operator's applications --
    def sink_argv(self, instance, geometry, word, sinkfile, xrm=None, title=None):
        argv = ["xterm", "-name", instance, "-geometry", geometry]
        # Without -T, xterm titles its window after the program -e runs ("sh").
        if title:
            argv += ["-T", title]
        if xrm:
            argv += ["-xrm", xrm]
        return argv + ["-e", "sh", "-c", SINK, word, sinkfile]

    def desk_sink(self, instance, geometry, word, xrm=None):
        """A sink xterm in the desktop container, as the session user."""
        self.g.desk(self.sink_argv(instance, geometry, word, f"/tmp/op-sink-{instance}", xrm),
                    detach=True)

    def client_sink(self, name, instance, geometry, word, xrm=None, devices=("display",), title=None):
        """A sink xterm in a client container of its own."""
        self.g.client_run(name, self.sink_argv(instance, geometry, word, f"/tmp/op-sink-{instance}", xrm,
                                               title), devices=devices)

    def desk_lines(self, path):
        return self.g.desk(["sh", "-c", f"cat {shlex.quote(path)} 2>/dev/null; true"],
                           user="root").splitlines()

    def client_lines(self, name, path):
        return self.g.client_exec(name, ["sh", "-c", f"cat {shlex.quote(path)} 2>/dev/null; true"],
                                  check=False).splitlines()

    def wait_client(self, instance, timeout=40):
        def look():
            xs = self.xstate(check=False)
            c = xs.client(instance)
            return (xs, c) if c and xs.mapped(xs.frame_of(c)) else None
        found = wait_until(look, timeout, 0.5)
        if not found:
            raise StoryFailed(f"the window '{instance}' never appeared on the screen")
        return found

    def wait_new_mapped(self, before, pred, timeout=6):
        def look():
            xs = self.xstate(check=False)
            new = [t for t in xs.new_mapped(before) if pred(t)]
            return (xs, new[0]) if new else None
        return wait_until(look, timeout, 0.3)

    def session_xterm(self, xs):
        """The xterm the session itself starts (xinitrc.desktop)."""
        found = [c for c in xs.clients("xterm") if xs.mapped(xs.frame_of(c))
                 or self.one(c.id).wm_state == "Iconic"]
        return found[0] if len(found) == 1 else None

    def wait_state(self, wid, state, timeout=6):
        return wait_until(lambda: (lambda i: i if i.wm_state == state else None)(self.one(wid)),
                          timeout, 0.3)

    def wait_gone(self, wid, timeout=10):
        return wait_until(lambda: self.one(wid).gone, timeout, 0.5)

    def new_xterm(self, before, timeout=20):
        """An xterm (WM_CLASS instance "xterm", as the menu starts them) that
        was not in `before` and is now on the screen."""
        old = {c.id for c in before.clients("xterm")}

        def look():
            xs = self.xstate(check=False)
            new = [c for c in xs.clients("xterm") if c.id not in old and xs.mapped(xs.frame_of(c))]
            return (xs, new[0]) if new else None
        return wait_until(look, timeout, 0.5)

    def pid_of(self, comm):
        """The session user's process named comm, quietly (for polling)."""
        out = self.g.sh(f"pgrep -u desktop -x {comm}; true", label=f"pgrep -u desktop -x {comm}").split()
        try:
            return int(out[0]) if len(out) == 1 else None
        except ValueError:
            return None

    def post_root_menu(self, xs):
        """Press button 1 on bare root and hold it: mwm posts the root menu
        with its corner at the pointer. Returns the press point and the menu,
        the button still down."""
        x, y = self.free_point(xs, room=(240, 260))
        self.move(x, y)
        time.sleep(0.2)
        self.m.button("left", True)
        found = self.wait_new_mapped(xs, lambda t: t.w > 60 and t.h > 100
                                     and abs(t.ax - x) <= 3 and abs(t.ay - y) <= 3)
        if not found:
            self.m.button("left", False)
            self.st.check(False, "a button press on bare root posts the root menu at the pointer",
                          f"pressed at ({x},{y}); no menu appeared there")
        return x, y, found[1]

    def root_menu(self, entry, moment):
        """Choose a root-menu entry the way the operator does: press a button
        on bare root, glide to the entry with it held, let go."""
        st = self.st
        xs = self.xstate()
        x, y, menu = self.post_root_menu(xs)
        img = self.shot(f"{moment}-menu", "the root menu posted at the pointer: the 'Desktop' "
                        "title and six entries, the dark menu colours")
        rows = img.text_rows(menu.rect())
        st.check(len(rows) == len(ROOT_MENU),
                 f"the root menu shows its title and six entries ({moment})",
                 f"{len(rows)} text rows in the {menu.w}x{menu.h} menu at +{menu.ax}+{menu.ay}")
        top, bottom = rows[ROOT_MENU.index(entry)]
        tx, ty = menu.ax + menu.w // 2, (top + bottom) // 2
        self.glide(x, y, tx, ty, steps=8, dt=0.05)
        time.sleep(0.3)
        self.shot(f"{moment}-armed", f"'{entry}' armed under the pointer, button still held")
        self.m.button("left", False)
        time.sleep(0.5)
        return xs, menu

    def confirm(self, before, moment):
        """Answer mwm's confirmation dialog with its OK button, if it posts
        one. Returns whether it did."""
        found = self.wait_new_mapped(
            before, lambda t: 80 < t.w < self.width and 60 < t.h < self.height
            and abs(t.ax + t.w // 2 - self.width // 2) < 40 and abs(t.ay + t.h // 2 - self.height // 2) < 40,
            timeout=4)
        if not found:
            self.st.record(f"{moment}: mwm posted no confirmation dialog")
            return False
        _, dlg = found
        img = self.shot(f"{moment}-dialog", "mwm's confirmation dialog; OK is the default button, "
                        "drawn inside a white focus ring")
        box = img.bbox(dlg.rect(), (255, 255, 255))
        self.st.check(box is not None and box[2] - box[0] > 15 and box[3] - box[1] > 10,
                      f"{moment}: the dialog's default button (OK) is drawn with its focus ring",
                      f"white pixels' bounding box {box}")
        self.st.record(f"{moment}: mwm asked to confirm in a {dlg.w}x{dlg.h} dialog")
        self.click((box[0] + box[2]) // 2, (box[1] + box[3]) // 2)
        return True

    # -- between stories --
    def recover(self):
        """Put the desktop back after a story, however it ended: no button
        held, no menu posted, no test window left."""
        for b in ("left", "middle", "right"):
            with contextlib.suppress(Exception):
                self.m.button(b, False)
        # Escape only while a menu is posted: the posted menu holds the
        # keyboard then. Sent to a terminal instead, Escape would leave bash's
        # readline waiting for the rest of a Meta sequence, and the first key
        # the next story types would be eaten by it.
        for _ in range(3):
            with contextlib.suppress(Exception):
                xs = self.xstate(check=False)
                if not any(xs.override.get(t.id) == "yes" and t.h > 60 and t.w < self.width
                           for t in xs.mapped_tops()):
                    break
                self.chord("esc", settle=0.4)
        with contextlib.suppress(Exception):
            self.g.stop_clients()
        with contextlib.suppress(Exception):
            self.g.desk(["pkill", "-u", "desktop", "-f", "xterm -name op"], check=False)
        with contextlib.suppress(Exception):
            wait_until(lambda: "mwm" in self.g.sh("pgrep -u desktop -x mwm >/dev/null && echo mwm; true",
                                                  label="is the session up?"), 60, 2)

    def diagnostics(self):
        st = self.st
        with contextlib.suppress(Exception):
            self.shot("failure", "the screen when the story failed")
        with contextlib.suppress(Exception):
            st.write("failure-tree", self.xstate(check=False).text, "the window tree when the story failed")
        with contextlib.suppress(Exception):
            st.write("failure-ps", self.g.ps(), "every process when the story failed")
        with contextlib.suppress(Exception):
            self.save_cmd("failure-desktop-log", "podman logs --tail 60 desktop 2>&1",
                          "the desktop container's log (EV-LOG-DESKTOP), last 60 lines",
                          label="podman logs desktop")


# US layout, which is what the session gets: nothing configures another.
KEYMAP = {**{c: (c, False) for c in "abcdefghijklmnopqrstuvwxyz0123456789"},
          **{c.upper(): (c, True) for c in "abcdefghijklmnopqrstuvwxyz"},
          " ": ("spc", False), "-": ("minus", False), "_": ("minus", True),
          "=": ("equal", False), "+": ("equal", True), ".": ("dot", False), ">": ("dot", True),
          ",": ("comma", False), "<": ("comma", True), "/": ("slash", False), "?": ("slash", True),
          ";": ("semicolon", False), ":": ("semicolon", True), "'": ("apostrophe", False),
          '"': ("apostrophe", True), "@": ("2", True), "#": ("3", True), "$": ("4", True),
          "%": ("5", True), "^": ("6", True), "&": ("7", True), "*": ("8", True),
          "(": ("9", True), ")": ("0", True), "|": ("backslash", True), "\\": ("backslash", False)}


# --- stories: the desktop as the operator finds it (F3.3, F3.5) --------------------

def s3_3_3(ctx, st):
    xs = ctx.xstate()
    ctx.save_state("tree", xs.text, "`xwininfo -root -tree` (EV-STATE): the session's xterm and "
                   "mwm's frame around it, nothing else mapped")
    img = ctx.shot("desktop", "the desktop before the operator touches it: the #101216 root, one "
                   "xterm at 100x30+60+60 in an mwm frame")
    xterms = [c for c in xs.clients("xterm") if xs.mapped(xs.frame_of(c))]
    st.check(len(xterms) == 1, "exactly one xterm is on the screen: the session's own",
             f"found {len(xterms)}")
    info = ctx.one(xterms[0].id)
    st.check(info.geometry == "100x30+60+60", "the session's xterm sits at 100x30+60+60",
             f"xwininfo -geometry {info.geometry}")
    st.check(xs.frame_of(xterms[0]).id != xterms[0].id, "mwm has framed it (it is not a top-level "
             "window of its own)")
    x, y = ctx.free_point(xs)
    rgb = img.px(x, y)
    st.check(rgb == ROOT_RGB, f"the bare root window at ({x},{y}) is #101216",
             f"sampled {rgb}, want {ROOT_RGB}")
    table = ctx.pids("pids")
    st.check(ctx.session_pid(table, "mwm"), "mwm runs, as the session user 'desktop'")


def s3_3_2(ctx, st):
    out = ctx.g.desk(["xset", "q"])
    st.write("xset-q", out, "`xset q` from the session (EV-STATE): 'timeout:  0' under Screen "
             "Saver, 'DPMS is Disabled'")
    st.check(re.search(r"timeout:\s+0\b", out), "the screen saver's timeout is 0: `xset s off` took effect")
    st.check("DPMS is Disabled" in out, "DPMS is disabled: `xset -dpms` took effect")
    st.record("the optional EV-SHOT after 11 idle minutes is not taken: it would add 11 minutes to "
              "every run for what `xset q` already shows")


def s3_5_2(ctx, st):
    out = ctx.g.xprobe("xprop -root RESOURCE_MANAGER 2>&1; true", label="observer: xprop -root RESOURCE_MANAGER")
    st.write("xprop-RESOURCE_MANAGER", out, "`xprop -root RESOURCE_MANAGER` (EV-STATE): "
             "'not found' - nothing loaded resources into the server, so Xt reads ~/.Xdefaults")
    st.check("not found" in out, "nothing set RESOURCE_MANAGER on the root window", out.strip())
    xs = ctx.xstate()
    term = ctx.session_xterm(xs)
    st.check(term is not None, "the session's xterm is on the screen to look at")
    info = ctx.one(term.id)
    img = ctx.shot("xterm", "the session's xterm: a dark terminal (#16191d), not a white one")
    # The bottom-right of the text area: empty, so it is background, and on
    # the side away from the scrollbar.
    x, y = info.ax + info.w - 8, info.ay + info.h - 8
    rgb = img.px(x, y)
    st.check(rgb == XTERM_BG, f"the xterm's background at ({x},{y}) is #16191d from ~/.Xdefaults",
             f"sampled {rgb}, want {XTERM_BG}")


def s3_5_3(ctx, st):
    xs = ctx.xstate()
    term = ctx.session_xterm(xs)
    st.check(term is not None, "the session's xterm is on the screen")
    fx, fy = ctx.free_spot(xs, (300, 200))
    ctx.client_sink("frames", "opframes", f"40x10+{fx}+{fy}", "frames")
    xs, cli = ctx.wait_client("opframes")
    for on, off, label, moment in ((term, cli, "session's xterm", "focus-session"),
                                   (cli, term, "client's xterm", "focus-client")):
        ctx.click(*xs.parts(on)["drag"])
        img = ctx.shot(moment, f"the {label} focused: its frame #41637f, the other frame #22262d")
        a, b = xs.parts(on)["swatch"], xs.parts(off)["swatch"]
        st.check(img.px(*a) == FOCUSED, f"with the {label} focused, its frame is #41637f",
                 f"sampled {img.px(*a)} at {a}")
        st.check(img.px(*b) == UNFOCUSED, "and the other frame is #22262d",
                 f"sampled {img.px(*b)} at {b}")
    xs = ctx.xstate()
    _, _, menu = ctx.post_root_menu(xs)
    try:
        img = ctx.shot("menu", "the root menu: #22262d behind light text")
        rows = img.text_rows(menu.rect())
        st.check(len(rows) >= 3, "the root menu's rows are legible", f"{len(rows)} rows")
        # Between two entries, mid-width: background, clear of text and bevel.
        sx, sy = menu.ax + menu.w // 2, (rows[1][1] + rows[2][0]) // 2
        st.check(img.px(sx, sy) == MENU_BG, f"the menu's background at ({sx},{sy}) is #22262d",
                 f"sampled {img.px(sx, sy)}")
    finally:
        ctx.m.button("left", False)
        time.sleep(0.3)
        ctx.chord("esc")
    st.check(wait_until(lambda: not ctx.xstate().mapped(menu), 4, 0.3), "Escape took the menu down")


# --- stories: client applications (F7.5) -------------------------------------------

def client_record(ctx, name, moment, what):
    """EV-PIDS for a podman client: its container's id, the host pid of its
    main process (the application), its restart count and its start time.
    Returns the values, the file's name and its text."""
    info = ctx.g.client_inspect(name)
    text = (f"$ podman inspect op-{name} --format "
            "'{{.Id}} {{.State.Pid}} {{.RestartCount}} {{.State.StartedAt}}'\n"
            f"id={info['id']}\npid={info['pid']}\nrestartCount={info['restarts']}\n"
            f"startedAt={info['started']}\n")
    return info, ctx.save_state(moment, text, what), text


def client_same(ctx, st, name, before, after):
    """The same container and application before and after: EV-DIFF of the
    two records, then the checks."""
    (b, b_name, b_text), (a, a_name, a_text) = before, after
    ctx.diff_kept("pids", b_name, b_text, a_name, a_text,
                  "EV-DIFF: the client container before and after (empty: the same container and "
                  "application, never restarted)")
    st.check(a["id"] == b["id"] and a["pid"] == b["pid"] and a["started"] == b["started"]
             and a["restarts"] == 0,
             "the same container and application throughout: id, the application's host pid and the "
             "start time unchanged, restartCount 0",
             f"pid {a['pid']}, started {a['started']}")
    st.check(ctx.g.pid_alive(a["pid"]), "and the application is still running", f"host pid {a['pid']}")
    ctx.save_cmd("client-log", f"podman logs op-{name} 2>&1",
                 "EV-LOG-CLIENT: the client container's own output (podman logs)",
                 label=f"podman logs op-{name}")


# podman exec sessions do not get CDI's env edits (Guest.xprobe), so the
# client's own screenshot takes DISPLAY and DESKTOP_TOOLS_BIN from the
# client's pid 1, where CDI put them.
CLIENT_SHOT = ("set -- $(tr '\\0' '\\n' < /proc/1/environ | grep -E '^(DISPLAY|DESKTOP_TOOLS_BIN)='); "
               "exec env \"$@\" sh -c 'exec \"$DESKTOP_TOOLS_BIN\"/screenshot --to-stdout'")


def client_shot(ctx, name, moment, what):
    """EV-SHOT-CLIENT: the display as the client captures it from inside its
    own container, with the toolkit's screenshot (the tools device)."""
    tmp = f"/tmp/op-client-shot-{name}.png"
    ctx.g.sh(shlex.join(["podman", "exec", f"op-{name}", "sh", "-c", CLIENT_SHOT]) + f" > {tmp}",
             label=f"client op-{name}: the toolkit's screenshot --to-stdout")
    data = ctx.g.fetch(tmp)
    if len(data) < 24 or data[:8] != b"\x89PNG\r\n\x1a\n":
        raise StoryFailed(f"the client's own screenshot is not a PNG ({len(data)} bytes)")
    n = ctx.st.name(moment, "png")
    with open(ctx.st.path(n), "wb") as f:
        f.write(data)
    ctx.st.attach(n, what)
    return struct.unpack(">II", data[16:24])


def client_typed(ctx, st, name, instance, text):
    """Whether the line typed reached the client's sink, read inside its own
    container; the sink file is kept (EV-STATE)."""
    got = wait_until(lambda: text in ctx.client_lines(name, f"/tmp/op-sink-{instance}"), 8, 0.5)
    ctx.save_cmd("sink", f"podman exec op-{name} cat /tmp/op-sink-{instance}",
                 "EV-STATE: the client-side sink file, read inside the client's own container: every "
                 "line typed into its window", label=f"the sink of op-{name}")
    return got


def s7_5_1(ctx, st):
    xs = ctx.xstate()
    term = ctx.session_xterm(xs)
    st.check(term is not None, "the session's xterm is on the screen, to hold the keyboard focus first")
    fx, fy = ctx.free_spot(xs, (300, 200))
    ctx.client_sink("s751", "s751app", f"40x10+{fx}+{fy}", "s751", devices=("display", "tools"),
                    title="s751app")
    st.record(f"the client: podman run --device desktop.local/display=all --device desktop.local/tools=all "
              f"{DESKTOP_IMAGE} xterm -name s751app -T s751app, a sink: every line typed into it is appended to "
              "/tmp/op-sink-s751app inside the client's own container. The tools device is there only "
              "for the client's own screenshot.")
    xs, cli = ctx.wait_client("s751app")
    ctx.save_state("tree", xs.text, "EV-STATE: xwininfo -root -tree from the observer (then each "
                   "top-level window's map state): the client's window s751app in it")
    info = ctx.one(cli.id)
    st.check(info.name == "s751app", "the client's window is on the desktop under the client's title",
             f"WM_NAME '{info.name}', {cli.w}x{cli.h}+{cli.ax}+{cli.ay}")
    before = client_record(ctx, "s751", "pids-before", "EV-PIDS: the client container before the click: "
                           "its id, the application's host pid, restart count and start time")
    # The focus starts elsewhere, so the keys can reach the client only if the
    # click on it moved the focus there.
    ctx.click(*xs.parts(term)["drag"])
    cx, cy = cli.ax + cli.w // 2, cli.ay + cli.h // 2
    ctx.click(cx, cy)
    st.record(f"the session's xterm was clicked first, then the client's window at its centre ({cx},{cy})")
    ctx.type_line("typedintoclient751")
    st.check(client_typed(ctx, st, "s751", "s751app", "typedintoclient751"),
             "the line typed after the click reached the client: its sink holds typedintoclient751")
    ctx.shot("typed", "EV-SHOT: the desktop with the client's window s751app: its word s751 on the first "
             "row, then the line typed into it, typedintoclient751")
    w, h = client_shot(ctx, "s751", "client-view", "EV-SHOT-CLIENT: the display as the client captures it "
                       "from inside its own container (the toolkit's screenshot): its window with the "
                       "typed line")
    st.check((w, h) == (ctx.width, ctx.height), "the client's own capture is of the whole screen", f"{w}x{h}")
    after = client_record(ctx, "s751", "pids-after", "EV-PIDS: the client container after the click and "
                          "the typing")
    client_same(ctx, st, "s751", before, after)


def s7_5_3(ctx, st):
    xs = ctx.xstate()
    term = ctx.session_xterm(xs)
    st.check(term is not None, "the session's xterm is on the screen, to hold the keyboard focus first")
    fx, fy = ctx.free_spot(xs, (300, 200))
    ctx.client_sink("s753", "s753app", f"40x10+{fx}+{fy}", "s753", devices=("display", "tools"))
    xs, cli = ctx.wait_client("s753app")
    ctx.save_state("tree", xs.text, "EV-STATE: the window tree: the client's window s753app inside the "
                   "frame mwm gave it")
    parts = xs.parts(cli)
    frame, title = parts["frame"], parts["title"]
    st.check(frame.id != cli.id and frame.w > cli.w and frame.h > cli.h and title.h > 0,
             "mwm framed the client's window: it sits in an mwm frame with a title bar",
             f"frame {frame.w}x{frame.h}+{frame.ax}+{frame.ay}, title bar {title.w}x{title.h}, "
             f"window {cli.w}x{cli.h}+{cli.ax}+{cli.ay}")
    before = client_record(ctx, "s753", "pids-before", "EV-PIDS: the client container before the click")
    ctx.click(*xs.parts(term)["drag"])
    a, t = parts["swatch"], xs.parts(term)["swatch"]
    img = ctx.shot("before-click", "EV-SHOT: the session's xterm holds the focus; the client's frame is "
                   "the inactive #22262d")
    st.check(img.px(*a) == UNFOCUSED, "before the click the client's frame is the inactive colour #22262d",
             f"sampled {img.px(*a)} at {a}")
    cx, cy = cli.ax + cli.w // 2, cli.ay + cli.h // 2
    ctx.click(cx, cy)
    img = ctx.shot("after-click", f"EV-SHOT: the client's window clicked at its centre ({cx},{cy}): its "
                   "frame the active #41637f, the session xterm's #22262d")
    st.check(img.px(*a) == FOCUSED, "the click on the client's window turned its frame the active colour "
             "#41637f", f"sampled {img.px(*a)} at {a}")
    st.check(img.px(*t) == UNFOCUSED, "and the session xterm's frame went to the inactive #22262d",
             f"sampled {img.px(*t)} at {t}")
    ctx.type_line("keystoclient753")
    st.check(client_typed(ctx, st, "s753", "s753app", "keystoclient753"),
             "the keys typed next went to the client: its sink holds keystoclient753")
    ctx.shot("typed", "EV-SHOT: the client's window with the line typed into it, keystoclient753")
    after = client_record(ctx, "s753", "pids-after", "EV-PIDS: the client container after the click and "
                          "the typing")
    client_same(ctx, st, "s753", before, after)


# --- stories: input hotplug, and a client application through it (F3.9, F3.11, F7.7) ---

USB_KBD = "QEMU QEMU USB Keyboard"
USB_TABLET = "QEMU QEMU USB Tablet"
USB_MOUSE = "QEMU QEMU USB Mouse"


def input_state(ctx):
    """F3.9's common set as one text: QEMU's USB devices, /dev/input on the
    VM host and in the desktop container, the kernel's input devices and
    xinput list."""
    g = ctx.g
    parts = [("info usb    # QEMU's monitor", ctx.m.hmp("info usb")),
             ("ls -l /dev/input    # on the VM host", g.sh("ls -l /dev/input 2>&1; true", label="ls -l /dev/input")),
             ("ls -l /dev/input    # in the desktop container",
              g.sh("podman exec desktop ls -l /dev/input 2>&1; true", label="ls -l /dev/input (container)")),
             ("cat /proc/bus/input/devices    # on the VM host",
              g.sh("cat /proc/bus/input/devices", label="cat /proc/bus/input/devices")),
             ("xinput list    # as the session user", g.desk(["xinput", "list"], check=False))]
    return "".join(f"$ {c}\n" + (o if o.strip() else "(no output)\n") + "\n" for c, o in parts)


def xi_slaves(ctx):
    """xinput's slave devices as (name, id), as the session user."""
    out = ctx.g.desk(["xinput", "list", "--short"], check=False)
    found = []
    for line in out.splitlines():
        mm = re.search(r"↳\s+(.+?)\s+id=(\d+)\s+\[slave", line)
        if mm:
            found.append((mm.group(1), int(mm.group(2))))
    return found


def xi_ids(ctx, name):
    return [i for n, i in xi_slaves(ctx) if n == name]


def guest_count(ctx, cmd, label, tries=3):
    """An integer the guest prints. A failed read is retried, then fails the
    story by name: it never stands in as a number, which could satisfy a
    check that a count dropped (Requirements.md S9.2.4)."""
    last = None
    for _ in range(tries):
        try:
            return int(ctx.g.sh(cmd, label=label).strip())
        except (RuntimeError, ValueError) as e:
            last = e
            time.sleep(0.5)
    raise RuntimeError(f"could not read {label} after {tries} tries: {last}")


def node_counts(ctx):
    """Event nodes on the VM host and in the desktop container."""
    return (guest_count(ctx, "ls /dev/input/event* | wc -l", "count /dev/input/event* (host)"),
            guest_count(ctx, "podman exec desktop sh -c 'ls /dev/input/event* | wc -l'",
                        "count /dev/input/event* (container)"))


def xi_test_start(ctx, xid, tag):
    """xinput test on one X device, into /tmp/op-xit-<tag>.txt in the desktop container."""
    ctx.g.desk(["sh", "-c", f"exec xinput test {int(xid)} > /tmp/op-xit-{tag}.txt 2>&1"], detach=True)
    time.sleep(1)


def xi_test_stop(ctx, xid, tag):
    ctx.g.desk(["pkill", "-f", f"^xinput test {int(xid)}$"], check=False)
    time.sleep(0.5)
    return ctx.g.desk(["cat", f"/tmp/op-xit-{tag}.txt"], check=False)


def xi_events(text):
    """Motion lines, button presses and releases of button 1, and key
    presses, in xinput test's output."""
    return (len(re.findall(r"^motion", text, re.M)), len(re.findall(r"^button press\s+1\b", text, re.M)),
            len(re.findall(r"^button release\s+1\b", text, re.M)), len(re.findall(r"^key press", text, re.M)))


def centre(win):
    return win.ax + win.w // 2, win.ay + win.h // 2


def wait_xi(ctx, name, want, timeout=20):
    """Until xinput lists `want` slave devices of that name."""
    return wait_until(lambda: len(xi_ids(ctx, name)) == want, timeout, 0.5)


def kbd_readd(ctx, bound):
    """The USB keyboard out and back: bound to the display (keys that name
    vga0 then come through it alone), or unbound, as QEMU boots it."""
    n = len(xi_ids(ctx, USB_KBD))
    ctx.m.device_del("kvmkbd")
    wait_until(lambda: len(xi_ids(ctx, USB_KBD)) < n, 20, 0.5)
    props = {"driver": "usb-kbd", "id": "kvmkbd", "bus": "xhci.0"}
    if bound:
        props["display"] = "vga0"
    ctx.m.device_add(**props)
    return wait_xi(ctx, USB_KBD, n)


def s3_9_11(ctx, st):
    m = ctx.m
    xs = ctx.xstate()
    term = ctx.session_xterm(xs)
    st.check(term is not None, "the session's xterm is on the screen, to hold the keyboard focus first")
    fx, fy = ctx.free_spot(xs, (300, 200))
    ctx.desk_sink("op3911", f"40x10+{fx}+{fy}", "s3911")
    xs, sink = ctx.wait_client("op3911")
    st.write("input-before", input_state(ctx), "F3.9's common set before the tablet is plugged: QEMU's info usb, "
             "/dev/input on the host and in the container, /proc/bus/input/devices, xinput list")
    try:
        # The tablet, bound to the display: pointer events that name vga0 go
        # to it alone, so its own X device is the one that must see them.
        m.device_add(driver="usb-tablet", id="optablet", bus="xhci.0", display="vga0")
        tid = wait_until(lambda: (xi_ids(ctx, USB_TABLET) or [None])[-1], 20, 0.5)
        st.check(tid, "Xorg lists the hot-added tablet (usb-tablet, bound to the display vga0)", f"X id {tid}")
        st.write("input-tablet", input_state(ctx), "F3.9's common set with the tablet plugged in")
        ctx.click(*xs.parts(term)["drag"])
        st.record("the session's xterm was clicked first, with the boot tablet: the keyboard focus is there")
        xi_test_start(ctx, tid, "tablet")
        sx, sy = centre(sink)
        with ctx.video("tablet", "EV-VIDEO: the pointer, driven through the hot-added tablet alone, crossing "
                       "the screen from its far corner to the sink xterm and clicking it: its frame turns the "
                       "focused colour"):
            ctx.move(ctx.width - 20, ctx.height - 20, device="vga0")
            time.sleep(0.3)
            ctx.glide(ctx.width - 20, ctx.height - 20, sx, sy, steps=24, dt=0.08, device="vga0")
            ctx.click(sx, sy, device="vga0")
            time.sleep(1)
        xit = xi_test_stop(ctx, tid, "tablet")
        st.write("xinput-test-tablet", xit or "(no output)\n",
                 f"EV-STATE: xinput test on the hot-added tablet's own X device (id {tid}) while the pointer "
                 "crossed the screen and clicked through it")
        motions, presses, releases, _ = xi_events(xit)
        st.check(motions >= 10 and presses >= 1 and releases >= 1,
                 "the hot-added tablet's own X device saw the motion and the click",
                 f"{motions} motion events, {presses} button-1 presses, {releases} releases")
        img = ctx.shot("clicked", "EV-SHOT: the sink xterm clicked through the hot-added tablet: its frame the "
                       "focused #41637f, the session xterm's #22262d")
        a, t = xs.parts(sink)["swatch"], xs.parts(term)["swatch"]
        st.check(img.px(*a) == FOCUSED and img.px(*t) == UNFOCUSED,
                 "the click through the hot-added tablet took the focus from the session's xterm to the sink",
                 f"sink frame {img.px(*a)}, session xterm frame {img.px(*t)}")
        ctx.type_line("tablet3911")
        got = wait_until(lambda: "tablet3911" in ctx.desk_lines("/tmp/op-sink-op3911"), 8, 0.5)
        ctx.save_cmd("sink", "podman exec desktop cat /tmp/op-sink-op3911",
                     "EV-STATE: the sink xterm's file: the line typed after the click", label="the sink")
        st.check(got, "the keys typed next landed in the sink xterm the tablet's click focused")

        # The mouse: no display property, so QEMU's current mouse (mouse_set)
        # is what receives relative motion and buttons that name no display.
        m.device_add(driver="usb-mouse", id="opmouse", bus="xhci.0")
        mid = wait_until(lambda: (xi_ids(ctx, USB_MOUSE) or [None])[-1], 20, 0.5)
        st.check(mid, "Xorg lists the hot-added mouse (usb-mouse)", f"X id {mid}")
        mice = m.qmp.cmd("query-mice")
        st.write("query-mice-before", json.dumps(mice, indent=1) + "\n",
                 "EV-QEMU: query-mice after the mouse was plugged: QEMU's mice, which one is current")
        usb = [mm for mm in mice if "HID Mouse" in mm.get("name", "")]
        st.check(usb, "QEMU lists the hot-added USB mouse among its mice", json.dumps(mice))
        m.hmp(f"mouse_set {usb[-1]['index']}")
        mice = m.qmp.cmd("query-mice")
        st.write("query-mice-after", json.dumps(mice, indent=1) + "\n",
                 f"EV-QEMU: query-mice after mouse_set {usb[-1]['index']}: the USB mouse current")
        st.check(any(mm["index"] == usb[-1]["index"] and mm.get("current") for mm in mice),
                 "mouse_set made the hot-added USB mouse QEMU's current mouse")
        # The relative motion starts in the middle of the session's xterm and
        # stays inside it, so the mouse's click lands there. In run
        # 37345104044 it went up and left from the sink onto bare root, where
        # a click makes mwm post its root menu, and that held the next
        # story's first click.
        ctx.move(*centre(term))
        time.sleep(0.3)
        xi_test_start(ctx, mid, "mouse")
        with ctx.video("mouse", "EV-VIDEO: the pointer moved by the hot-added USB mouse's relative motion "
                       "inside the session's xterm, then its click there"):
            for _ in range(12):
                m.rel(-5, 4)
                time.sleep(0.05)
            m.button("left", True)
            time.sleep(0.05)
            m.button("left", False)
            time.sleep(1)
        xit = xi_test_stop(ctx, mid, "mouse")
        st.write("xinput-test-mouse", xit or "(no output)\n",
                 f"EV-STATE: xinput test on the hot-added mouse's own X device (id {mid}) while QEMU's current "
                 "mouse moved and clicked")
        motions, presses, releases, _ = xi_events(xit)
        st.check(motions >= 5 and presses >= 1 and releases >= 1,
                 "the hot-added mouse's own X device saw the relative motion and the click",
                 f"{motions} motion events, {presses} button-1 presses, {releases} releases")
    finally:
        for dev in ("opmouse", "optablet"):
            with contextlib.suppress(Exception):
                m.device_del(dev)
        wait_xi(ctx, USB_MOUSE, 0, 10)
        wait_xi(ctx, USB_TABLET, 0, 10)


def s3_9_12(ctx, st):
    names0 = sorted(n for n, _ in xi_slaves(ctx))
    k0 = len(xi_ids(ctx, USB_KBD))
    h0, c0 = node_counts(ctx)
    xorg = ctx.pid_of("Xorg")
    st.check(k0 >= 1 and xorg, "the USB keyboard is plugged in and Xorg runs before the cycles",
             f"{k0} '{USB_KBD}' in xinput, Xorg pid {xorg}")
    st.write("input-baseline", input_state(ctx), "F3.9's common set before the first cycle (the baseline)")
    rows = ["cycle  state      host-event-nodes  container-event-nodes  xinput-usb-keyboards",
            f"0      baseline   {h0:<16}  {c0:<21}  {k0}"]
    away_ok = back_ok = True
    for i in range(1, 6):
        ctx.m.device_del("kvmkbd")
        away = wait_until(lambda: len(xi_ids(ctx, USB_KBD)) < k0 and node_counts(ctx)[0] < h0, 15, 0.5)
        h, c = node_counts(ctx)
        rows.append(f"{i}      removed    {h:<16}  {c:<21}  {len(xi_ids(ctx, USB_KBD))}")
        away_ok = away_ok and bool(away) and c < c0
        ctx.m.device_add(driver="usb-kbd", id="kvmkbd", bus="xhci.0")
        back = wait_until(lambda: len(xi_ids(ctx, USB_KBD)) == k0 and node_counts(ctx) == (h0, c0), 20, 0.5)
        h, c = node_counts(ctx)
        rows.append(f"{i}      re-added   {h:<16}  {c:<21}  {len(xi_ids(ctx, USB_KBD))}")
        back_ok = back_ok and bool(back)
    st.write("cycles", "\n".join(rows) + "\n", "EV-STATE: the counter table, one row per removal and per "
             "return: event nodes on the host and in the container, and the USB keyboards xinput lists")
    st.write("input-final", input_state(ctx), "F3.9's common set after the fifth cycle")
    names1 = sorted(n for n, _ in xi_slaves(ctx))
    ctx.diff("xinput-names", "\n".join(names0) + "\n", "\n".join(names1) + "\n",
             "EV-DIFF: the names of xinput's slave devices, baseline against after the fifth cycle (empty: no "
             "device left behind or missing; the ids are new, so the names are what is compared)")
    st.check(away_ok, "each of the five removals took the keyboard out of xinput and its nodes off the host "
             "and out of the container")
    st.check(back_ok, "each of the five returns brought the counts back to the baseline",
             f"baseline host {h0}, container {c0}, keyboards {k0}")
    st.check(names1 == names0, "after the fifth cycle xinput lists the same devices as before the first")
    st.check(ctx.pid_of("Xorg") == xorg, "Xorg kept its pid through the five cycles", f"pid {xorg}")
    xs = ctx.xstate()
    fx, fy = ctx.free_spot(xs, (300, 200))
    ctx.desk_sink("op3912", f"40x10+{fx}+{fy}", "s3912")
    xs, sink = ctx.wait_client("op3912")
    ctx.click(*centre(sink))
    ctx.type_line("aftercycles3912")
    got = wait_until(lambda: "aftercycles3912" in ctx.desk_lines("/tmp/op-sink-op3912"), 8, 0.5)
    ctx.save_cmd("sink", "podman exec desktop cat /tmp/op-sink-op3912",
                 "EV-STATE: a sink xterm's file after the cycles: the line typed into it", label="the sink")
    st.check(got, "the session still takes typed input after the five cycles")
    ctx.shot("after", "EV-SHOT: the sink xterm with the line typed after the five cycles")


def snd_counts(ctx):
    """Sound nodes on the host and in the container, and PipeWire's devices."""
    h = guest_count(ctx, "ls /dev/snd | wc -l", "count /dev/snd (host)")
    c = guest_count(ctx, "podman exec desktop sh -c 'ls /dev/snd | wc -l'", "count /dev/snd (container)")
    d = len(re.findall(r"^\s*id \d+, type PipeWire:Interface:Device", ctx.g.desk(["pw-cli", "ls", "Device"],
                                                                                  check=False), re.M))
    return h, c, d


def kvm_plug(ctx):
    """A KVM's devices on the USB bus: the keyboard (there from boot), a
    tablet bound to the display and a sound card. Returns the built-in
    sink's name, read before the card arrives."""
    builtin = node_name(ctx, "@DEFAULT_AUDIO_SINK@")
    ctx.m.device_add(driver="usb-tablet", id="kvmtab", bus="xhci.0", display="vga0")
    ctx.m.device_add(driver="usb-audio", id="kvmsnd", audiodev="snd0", bus="xhci.0")
    return builtin


def kvm_cycle(ctx, st, prefix="", on_away=None, on_back=None):
    """The switch: keyboard, tablet and sound card deleted back to back,
    then added back. on_away runs right after the deletions, on_back right
    after the additions (S3.11.2's video link). Writes the counter table;
    returns (away, back, base)."""
    m = ctx.m
    base = (*node_counts(ctx), *snd_counts(ctx), len(xi_ids(ctx, USB_KBD)), len(xi_ids(ctx, USB_TABLET)))
    m.device_del("kvmkbd")
    m.device_del("kvmtab")
    m.device_del("kvmsnd")
    if on_away:
        on_away()
    away = wait_until(lambda: not xi_ids(ctx, USB_KBD) and not xi_ids(ctx, USB_TABLET)
                      and snd_counts(ctx)[2] < base[4], 30, 0.5)
    away_c = (*node_counts(ctx), *snd_counts(ctx), len(xi_ids(ctx, USB_KBD)), len(xi_ids(ctx, USB_TABLET)))
    st.write(f"{prefix}away", input_state(ctx) + audio_devices(ctx),
             "the whole state with the three devices away: F3.9's and F4.7's common sets")
    m.device_add(driver="usb-kbd", id="kvmkbd", bus="xhci.0")
    m.device_add(driver="usb-tablet", id="kvmtab", bus="xhci.0", display="vga0")
    m.device_add(driver="usb-audio", id="kvmsnd", audiodev="snd0", bus="xhci.0")
    if on_back:
        on_back()
    back = wait_until(lambda: (*node_counts(ctx), *snd_counts(ctx), len(xi_ids(ctx, USB_KBD)),
                               len(xi_ids(ctx, USB_TABLET))) == base, 40, 1)
    back_c = (*node_counts(ctx), *snd_counts(ctx), len(xi_ids(ctx, USB_KBD)), len(xi_ids(ctx, USB_TABLET)))
    head = ("state   host-input  container-input  host-snd  container-snd  pw-devices  usb-keyboards  "
            "usb-tablets")
    rows = [head] + [f"{label:<7} " + "  ".join(f"{v:<{w}}" for v, w in zip(vals, (10, 15, 8, 13, 10, 13, 11)))
                     for label, vals in (("before", base), ("away", away_c), ("back", back_c))]
    st.write(f"{prefix}counts", "\n".join(rows) + "\n", "EV-STATE: the three counter tables in one: input "
             "nodes, sound nodes and PipeWire's devices, and the USB keyboard and tablet in xinput, before, "
             "away and back")
    return bool(away) and all(a < b for a, b in zip(away_c[:4], base[:4])), bool(back), base


def tone_to(ctx, st, moment, sink, wav_host, hz, what):
    """A one-shot client container plays a WAV to the named sink while the
    machine's output is captured; returns check-audio.py's verdict."""
    g, m = ctx.g, ctx.m
    ctr = f"op-{moment}"
    g.sh(f"podman rm -f {ctr} >/dev/null 2>&1; true")
    g.sh(shlex.join(["podman", "create", "--name", ctr, "--device=desktop.local/audio=all",
                     f"--env=PULSE_SINK={sink}", TESTCLIENT_IMAGE, "paplay", "/tmp/tone.wav"]))
    g.sh(shlex.join(["podman", "cp", wav_host, f"{ctr}:/tmp/tone.wav"]))
    wav_name = st.name(f"{moment}-{hz}hz", "wav")
    wav = os.path.abspath(st.path(wav_name))
    m.hmp(f"wavcapture {wav} snd0 44100 16 2")
    try:
        time.sleep(1)
        out = g.sh(shlex.join(["podman", "start", "-a", ctr]) + "; echo \"paplay exited $?\"", timeout=60,
                   check=False, label=f"client {ctr}: PULSE_SINK={sink} paplay")
        time.sleep(1)
    finally:
        m.hmp("stopcapture 0")
        g.sh(f"podman rm -f {ctr} >/dev/null 2>&1; true")
    st.write(f"{moment}-player", out, f"EV-LOG-CLIENT: the client's paplay, sent to {sink} by name: its exit status")
    st.attach(wav_name, what)
    rep, plot = st.name(f"{moment}-verdict", "txt"), st.name(f"{moment}-level", "png")
    rc = subprocess.run(["python3", "check-audio.py", "--report", st.path(rep), "--plot", st.path(plot),
                         wav, "1", "0.05", str(hz)], capture_output=True, timeout=120).returncode
    for n, w in ((rep, f"check-audio.py's verdict on {wav_name} (want {hz} Hz)"),
                 (plot, f"the level at {hz} Hz across {wav_name}, one bar per 0.1 s")):
        if os.path.exists(st.path(n)) and os.path.getsize(st.path(n)):
            st.attach(n, w)
    return rc == 0 and "paplay exited 0" in out


def s3_11_1(ctx, st):
    m = ctx.m
    try:
        builtin = kvm_plug(ctx)
        st.check(builtin, "the built-in card's sink is the default before the KVM's card arrives",
                 f"{builtin}")
        st.check(wait_xi(ctx, USB_TABLET, 1) and wait_until(lambda: snd_counts(ctx)[2] >= 2, 30, 1),
                 "the KVM's tablet and sound card are plugged in beside its keyboard")
        xorg, pw = ctx.pid_of("Xorg"), ctx.pid_of("pipewire")
        st.write("before", input_state(ctx) + audio_devices(ctx),
                 "the whole state before the switch: F3.9's and F4.7's common sets")
        pids = ctx.pids("pids-before")
        with ctx.video("kvm-cycle", "EV-VIDEO: the display while the keyboard, tablet and sound card leave "
                       "together and return together: nothing on it moves"):
            away, back, _ = kvm_cycle(ctx, st)
        st.check(away, "with the three deleted back to back, every count dropped: input and sound nodes on "
                 "the host and in the container, PipeWire's devices, xinput's keyboard and tablet")
        st.check(back, "with the three added back, every count returned to its value before")
        pids2 = ctx.pids("pids-after")
        st.check(ctx.session_pid(pids2, "Xorg") == ctx.session_pid(pids, "Xorg") == xorg
                 and ctx.session_pid(pids2, "pipewire") == pw,
                 "Xorg and PipeWire kept their pids through the switch", f"Xorg {xorg}, pipewire {pw}")
        # Afterwards the operator types, clicks and hears. The click goes
        # through the returned tablet (bound to the display), and the typing
        # through the returned keyboard, the newest one bound to no display.
        xs = ctx.xstate()
        fx, fy = ctx.free_spot(xs, (300, 200))
        ctx.desk_sink("op3111", f"40x10+{fx}+{fy}", "s3111")
        xs, sink = ctx.wait_client("op3111")
        tid = (xi_ids(ctx, USB_TABLET) or [None])[-1]
        st.check(tid, "xinput lists the returned tablet")
        xi_test_start(ctx, tid, "kvmtab")
        ctx.click(*centre(sink), device="vga0")
        xit = xi_test_stop(ctx, tid, "kvmtab")
        st.write("xinput-test-tablet", xit or "(no output)\n",
                 f"EV-STATE: xinput test on the returned tablet's own X device (id {tid}) while it clicked")
        st.check(xi_events(xit)[1] >= 1, "the returned tablet clicks: its own X device saw the button press")
        kid = (xi_ids(ctx, USB_KBD) or [None])[-1]
        st.check(kid, "xinput lists the returned keyboard")
        xi_test_start(ctx, kid, "kvmkbd")
        ctx.type_line("afterkvm3111")
        xit = xi_test_stop(ctx, kid, "kvmkbd")
        st.write("xinput-test-keyboard", xit or "(no output)\n",
                 f"EV-STATE: xinput test on the returned keyboard's own X device (id {kid}) while the line was typed")
        got = wait_until(lambda: "afterkvm3111" in ctx.desk_lines("/tmp/op-sink-op3111"), 8, 0.5)
        ctx.save_cmd("sink", "podman exec desktop cat /tmp/op-sink-op3111",
                     "EV-STATE: the sink xterm's file: the line typed after the switch", label="the sink")
        st.check(got and xi_events(xit)[3] >= 12, "the line typed after the switch came through the returned "
                 "keyboard and landed in the sink the returned tablet clicked",
                 f"{xi_events(xit)[3]} key presses on the keyboard's own device")
        ctx.shot("typed", "EV-SHOT: the sink xterm with the line typed after the switch")
        st.check(tone_to(ctx, st, "builtin-tone", builtin, "/tmp/op-tone-660-3s.wav", 660,
                         f"EV-AUDIO: the machine's output while a client played 660 Hz to the built-in sink by "
                         f"name ({builtin}), after the switch - listen for one beep"),
                 "after the switch a client's tone sent to the built-in sink by name is heard, and its paplay "
                 "exits 0 (WirePlumber makes the returning USB card the default, so an untargeted tone would "
                 "prove the USB card instead)")
    finally:
        for dev in ("kvmtab", "kvmsnd"):
            with contextlib.suppress(Exception):
                m.device_del(dev)
        wait_xi(ctx, USB_TABLET, 0, 10)


def s3_11_2(ctx, st):
    """S3.11.1 under a declared two-monitor layout, with Virtual-1 forced down
    while the KVM's devices are away and set back to detect as they return:
    the screen stays 2048x768 and no window moves at any step."""
    g, m = ctx.g, ctx.m
    conn = g.sh("ls -d /sys/class/drm/card*-Virtual-1 | head -n1", label="Virtual-1's sysfs connector").strip()

    def dims():
        return g.desk(["sh", "-c", "xdpyinfo | awk '/dimensions:/{print $2; exit}'"], check=False).strip()

    def v1():
        out = g.desk(["xrandr", "--query"], check=False)
        return next((x for x in out.splitlines() if x.startswith("Virtual-1 ")), "")

    def windows(xs):
        return sorted(l.strip() for l in xs.text.splitlines() if re.match(r'\s+0x[0-9a-f]+ "[^"]*": \("', l))

    def f310(moment, when):
        st.write(f"{moment}-f310",
                 g.sh("grep -H . /sys/class/drm/card*-*/status", check=False, label="sysfs status") + "\n"
                 + g.desk(["xrandr", "--query", "--verbose"], check=False),
                 f"F3.10's common set {when}: every connector's sysfs status, then xrandr --query --verbose")

    seen = {}
    found = dims()
    try:
        g.sh("repo/ci/vm/vm-guest.sh monitors-set two", timeout=240, label="declare two monitors, restart the desktop")
        ctx.measure_screen()
        st.check(dims() == "2048x768", "the declared layout is live: the screen is 2048x768", dims())
        builtin = kvm_plug(ctx)
        st.check(builtin, "the built-in card's sink is the default before the KVM's card arrives", f"{builtin}")
        st.check(wait_xi(ctx, USB_TABLET, 1) and wait_until(lambda: snd_counts(ctx)[2] >= 2, 30, 1),
                 "the KVM's tablet and sound card are plugged in beside its keyboard")
        xs0 = ctx.xstate()
        ctx.save_state("tree-before", xs0.text, "EV-STATE: the window tree before the switch")
        f310("before", "before the switch")
        w0 = windows(xs0)
        xorg, pw = ctx.pid_of("Xorg"), ctx.pid_of("pipewire")
        pids = ctx.pids("pids-before")

        def away():
            g.sh(f"echo off > {conn}/status", label="force Virtual-1 off with the devices")
            st.record(f"Virtual-1 forced off at {stamp()}, with the keyboard, tablet and sound card")

        def back():
            g.sh(f"echo detect > {conn}/status", label="Virtual-1 back to detect with the devices")
            st.record(f"Virtual-1 set back to detect at {stamp()}, as the devices returned")

        def away_state():
            g.desk(["xrandr", "--query"], check=False)           # a query makes X probe
            xs = ctx.xstate()
            seen["away"] = (dims(), v1(), windows(xs))
            ctx.save_state("tree-away", xs.text, "EV-STATE: the window tree with the devices away and Virtual-1 off")
            f310("away", "with the devices away and Virtual-1 forced off")

        def away_then_state():
            away()
            time.sleep(3)
            away_state()

        with ctx.video("kvm-cycle", "EV-VIDEO: the display while the keyboard, tablet and sound card leave "
                       "together with Virtual-1's link, and return together: nothing on it moves"):
            ok_away, ok_back, _ = kvm_cycle(ctx, st, on_away=away_then_state, on_back=back)
            wait_until(lambda: v1().startswith("Virtual-1 connected "), 15, 1)
        xs1 = ctx.xstate()
        ctx.save_state("tree-after", xs1.text, "EV-STATE: the window tree after the switch")
        f310("after", "after the switch")
        st.check(ok_away, "with the three deleted back to back, every count dropped")
        st.check(ok_back, "with the three added back, every count returned to its value before")
        d_away, v1_away, w_away = seen.get("away", ("", "", []))
        st.check(d_away == "2048x768" and v1_away.startswith("Virtual-1 disconnected ") and "1024x768+0+0" in v1_away,
                 "while away the screen stayed 2048x768 and Virtual-1 read disconnected, still at 1024x768+0+0",
                 f"{d_away}; {v1_away}")
        st.check(w_away == w0, "while away no window moved or resized", f"{len(w0)} windows")
        st.check(dims() == "2048x768" and v1().startswith("Virtual-1 connected ") and "1024x768+0+0" in v1(),
                 "after the return the screen is 2048x768 and Virtual-1 reads connected at 1024x768+0+0", v1())
        st.check(windows(xs1) == w0, "after the return no window moved or resized", f"{len(w0)} windows")
        pids2 = ctx.pids("pids-after")
        st.check(ctx.session_pid(pids2, "Xorg") == ctx.session_pid(pids, "Xorg") == xorg
                 and ctx.session_pid(pids2, "pipewire") == pw,
                 "Xorg and PipeWire kept their pids through the switch", f"Xorg {xorg}, pipewire {pw}")
        # Then the operator types, clicks and hears, as in S3.11.1, on
        # Virtual-1's half (QEMU's screendump shows head 0, Virtual-1).
        ctx.desk_sink("op3112", "40x10+300+300", "s3112")
        xs, sink = ctx.wait_client("op3112")
        tid = (xi_ids(ctx, USB_TABLET) or [None])[-1]
        xi_test_start(ctx, tid, "kvmtab")
        ctx.click(*centre(sink), device="vga0")
        xit = xi_test_stop(ctx, tid, "kvmtab")
        st.write("xinput-test-tablet", xit or "(no output)\n",
                 f"EV-STATE: xinput test on the returned tablet's own X device (id {tid}) while it clicked")
        st.check(xi_events(xit)[1] >= 1, "the returned tablet clicks: its own X device saw the button press")
        kid = (xi_ids(ctx, USB_KBD) or [None])[-1]
        xi_test_start(ctx, kid, "kvmkbd")
        ctx.type_line("afterkvm3112")
        xit = xi_test_stop(ctx, kid, "kvmkbd")
        st.write("xinput-test-keyboard", xit or "(no output)\n",
                 f"EV-STATE: xinput test on the returned keyboard's own X device (id {kid}) while the line was typed")
        got = wait_until(lambda: "afterkvm3112" in ctx.desk_lines("/tmp/op-sink-op3112"), 8, 0.5)
        ctx.save_cmd("sink", "podman exec desktop cat /tmp/op-sink-op3112",
                     "EV-STATE: the sink xterm's file: the line typed after the switch", label="the sink")
        st.check(got and xi_events(xit)[3] >= 12, "the line typed after the switch came through the returned "
                 "keyboard and landed in the sink the returned tablet clicked",
                 f"{xi_events(xit)[3]} key presses on the keyboard's own device")
        ctx.shot("typed", "EV-SHOT: head 0 (Virtual-1) with the sink xterm and the line typed after the switch")
        st.check(tone_to(ctx, st, "builtin-tone", builtin, "/tmp/op-tone-660-3s.wav", 660,
                         f"EV-AUDIO: the machine's output while a client played 660 Hz to the built-in sink by "
                         f"name ({builtin}), after the switch - listen for one beep"),
                 "after the switch a client's tone sent to the built-in sink by name is heard, and its paplay "
                 "exits 0")
    finally:
        for dev in ("kvmtab", "kvmsnd"):
            with contextlib.suppress(Exception):
                m.device_del(dev)
        wait_xi(ctx, USB_TABLET, 0, 10)
        with contextlib.suppress(Exception):
            g.sh(f"echo detect > {conn}/status", check=False, label="Virtual-1 back to detect")
        g.sh("repo/ci/vm/vm-guest.sh monitors-set shipped", timeout=240, check=False,
             label="the shipped monitors.conf back, restart the desktop")
        with contextlib.suppress(Exception):
            ctx.measure_screen()
    # The restore is checked, not assumed (Requirements.md S9.2.5).
    back = g.sh("cmp -s repo/deploy/host/etc/desktop-container/monitors.conf /etc/desktop-container/monitors.conf "
                "&& echo shipped || echo changed", check=False, label="monitors.conf against the shipped file").strip()
    same = bool(re.fullmatch(r"\d+x\d+", found)) and wait_until(lambda: dims() == found, 30, 1)
    st.check(back == "shipped" and same, f"restored: the shipped monitors.conf is back, and the screen is the "
             f"{found} the story found", f"{back}; the screen {dims()}")


def s7_7_1(ctx, st):
    xs = ctx.xstate()
    fx, fy = ctx.free_spot(xs, (300, 200))
    ctx.client_sink("s771", "op771", f"40x10+{fx}+{fy}", "s771")
    xs, cli = ctx.wait_client("op771")
    before = client_record(ctx, "s771", "client-before", "EV-PIDS: the client container before the keyboard "
                           "goes: id, the application's host pid, restart count, start time")
    pids = ctx.pids("pids-before")
    ctx.click(*centre(cli))
    ctx.type_line("beforekvm771")
    st.write("input-before", input_state(ctx), "F3.9's common set before the keyboard is removed")
    try:
        with ctx.video("keyboard-cycle", "EV-VIDEO: the display while the USB keyboard is removed and "
                       "re-added, the client's xterm focused throughout"):
            st.check(kbd_readd(ctx, bound=True), "the USB keyboard went and came back (bound to the display, so "
                     "keys sent to vga0 come through it alone)")
        st.write("input-after", input_state(ctx), "F3.9's common set with the keyboard back")
        kid = (xi_ids(ctx, USB_KBD) or [None])[-1]
        st.check(kid, "xinput lists the re-added keyboard")
        xi_test_start(ctx, kid, "s771")
        # No click: the focus the client had before the keyboard went.
        ctx.type_line("afterkvm771", device="vga0")
        xit = xi_test_stop(ctx, kid, "s771")
        st.write("xinput-test", xit or "(no output)\n", f"EV-STATE: xinput test on the re-added keyboard's own X "
                 f"device (id {kid}) while the line was typed")
        lines = wait_until(lambda: (lambda ls: ls if "afterkvm771" in ls else None)(
            ctx.client_lines("s771", "/tmp/op-sink-op771")), 8, 0.5)
        ctx.save_cmd("sink", "podman exec op-s771 cat /tmp/op-sink-op771",
                     "EV-STATE: the client-side sink file, inside the client's container: the line typed before "
                     "and the one typed through the re-added keyboard", label="the client's sink")
        st.check(lines and "beforekvm771" in lines, "the client's xterm took the line typed before the cycle")
        st.check(lines and xi_events(xit)[3] >= 11, "and, still focused, the line typed through the re-added "
                 "keyboard after it", f"{xi_events(xit)[3]} key presses on the keyboard's own device")
        ctx.shot("typed", "EV-SHOT: the client's xterm with both lines, the second typed through the re-added "
                 "keyboard")
        after = client_record(ctx, "s771", "client-after", "EV-PIDS: the client container after the cycle")
        pids2 = ctx.pids("pids-after")
        same_desktop(ctx, st, pids, pids2)
        client_same(ctx, st, "s771", before, after)
    finally:
        with contextlib.suppress(Exception):
            kbd_readd(ctx, bound=False)


def s7_7_2(ctx, st):
    m = ctx.m
    xs = ctx.xstate()
    term = ctx.session_xterm(xs)
    st.check(term is not None, "the session's xterm is on the screen, to hold the keyboard focus first")
    fx, fy = ctx.free_spot(xs, (300, 200))
    ctx.client_sink("s772", "op772", f"40x10+{fx}+{fy}", "s772")
    xs, cli = ctx.wait_client("op772")
    before = client_record(ctx, "s772", "client-before", "EV-PIDS: the client container before the tablet is "
                           "plugged")
    pids = ctx.pids("pids-before")
    ctx.click(*xs.parts(term)["drag"])
    st.write("input-before", input_state(ctx), "F3.9's common set before the tablet is plugged")
    try:
        with ctx.video("tablet", "EV-VIDEO: a tablet plugged in after the client started, then clicking the "
                       "client's window through it: its frame turns the focused colour"):
            m.device_add(driver="usb-tablet", id="op772tab", bus="xhci.0", display="vga0")
            tid = wait_until(lambda: (xi_ids(ctx, USB_TABLET) or [None])[-1], 20, 0.5)
            a = xs.parts(cli)["swatch"]
            # Run 37340174407 found the client's frame focused here although
            # the session's xterm had been clicked before the plug. Kept as
            # found, then the focus is put on the session's xterm again
            # through the boot pointer, so the click through the tablet has
            # something to move.
            img = ctx.shot("after-plug", "EV-SHOT: the screen just after the tablet was plugged in, before any "
                           "click: whichever frame is #41637f holds the focus")
            st.record(f"just after the tablet was plugged in the client's frame was {img.px(*a)} "
                      f"({'focused' if img.px(*a) == FOCUSED else 'not focused'})")
            ctx.click(*xs.parts(term)["drag"])
            img = ctx.shot("before-click", "EV-SHOT: the tablet plugged in, the session's xterm clicked through "
                           "the boot pointer: the client's frame #22262d")
            st.check(tid and img.px(*a) == UNFOCUSED, "with the tablet plugged in and the session's xterm "
                     "clicked, the client's frame is the inactive colour", f"X id {tid}, frame {img.px(*a)}")
            xi_test_start(ctx, tid, "s772")
            ctx.click(*centre(cli), device="vga0")
            xit = xi_test_stop(ctx, tid, "s772")
            img = ctx.shot("after-click", "EV-SHOT: the client's window clicked through the hot-added tablet: its "
                           "frame #41637f")
        st.write("input-after", input_state(ctx), "F3.9's common set with the tablet plugged in")
        st.write("xinput-test", xit or "(no output)\n", f"EV-STATE: xinput test on the hot-added tablet's own X "
                 f"device (id {tid}) while it clicked")
        st.check(xi_events(xit)[1] >= 1, "the click came through the hot-added tablet: its own X device saw the "
                 "button press")
        st.check(img.px(*a) == FOCUSED, "the click turned the client's frame the focused colour",
                 f"sampled {img.px(*a)} at {a}")
        ctx.type_line("clicked772")
        st.check(client_typed(ctx, st, "s772", "op772", "clicked772"), "the keys typed next landed in the "
                 "client's xterm")
        after = client_record(ctx, "s772", "client-after", "EV-PIDS: the client container after it was clicked")
        pids2 = ctx.pids("pids-after")
        same_desktop(ctx, st, pids, pids2)
        client_same(ctx, st, "s772", before, after)
    finally:
        with contextlib.suppress(Exception):
            m.device_del("op772tab")
        wait_xi(ctx, USB_TABLET, 0, 10)


def same_desktop(ctx, st, before, after):
    """Xorg, mwm and the three audio daemons kept their pids (F7.7's common set)."""
    names = ("Xorg", "mwm", "pipewire", "wireplumber", "pipewire-pulse")
    b = {n: ctx.session_pid(before, n) for n in names}
    a = {n: ctx.session_pid(after, n) for n in names}
    st.check(all(b[n] and b[n] == a[n] for n in names), "Xorg, mwm and the three audio daemons kept their pids",
             " ".join(f"{n}={b[n]}->{a[n]}" for n in names))


def s7_7_8(ctx, st):
    g, m = ctx.g, ctx.m
    try:
        kvm_plug(ctx)
        st.check(wait_xi(ctx, USB_TABLET, 1) and wait_until(lambda: snd_counts(ctx)[2] >= 2, 30, 1),
                 "the KVM's tablet and sound card are plugged in beside its keyboard")
        xs = ctx.xstate()
        fx, fy = ctx.free_spot(xs, (300, 200))
        ctx.client_sink("s778", "op778", f"40x10+{fx}+{fy}", "s778")
        xs, cli = ctx.wait_client("op778")
        g.client_run("s778p", ["paplay", "/tmp/tone.wav"], devices=("audio",), image=TESTCLIENT_IMAGE,
                     copy_in={"/tmp/tone.wav": "/tmp/op-tone-1100.wav"})
        st.check(wait_until(lambda: stream_sink(ctx), 20, 0.5), "the audio client's stream plays",
                 f"on {stream_sink(ctx)}")
        x_b = client_record(ctx, "s778", "xterm-before", "EV-PIDS: the xterm client before the switch")
        p_b = client_record(ctx, "s778p", "player-before", "EV-PIDS: the audio client before the switch")
        pids = ctx.pids("pids-before")
        ctx.click(*centre(cli))
        wav_name = st.name("through-kvm-1100hz", "wav")
        wav = os.path.abspath(st.path(wav_name))
        m.hmp(f"wavcapture {wav} snd0 44100 16 2")
        try:
            time.sleep(2)
            with ctx.video("kvm-cycle", "EV-VIDEO: the display while the KVM's keyboard, tablet and sound "
                           "card leave and return, the two clients running"):
                away, back, _ = kvm_cycle(ctx, st)
            time.sleep(3)
        finally:
            m.hmp("stopcapture 0")
        st.attach(wav_name, "EV-AUDIO: the machine's output while the audio client played its 1100 Hz tone "
                  "through the switch - listen for the tone before and after")
        st.check(away and back, "the keyboard, tablet and sound card left together and came back, every count "
                 "back to its value before")
        sink = stream_sink(ctx)
        ctx.save_cmd("streams-after", "podman exec -u desktop -e XDG_RUNTIME_DIR=/run/user/61000 desktop "
                     "pactl list sink-inputs", "EV-STATE: the streams after the switch: the client's paplay "
                     "still playing", label="pactl list sink-inputs")
        st.check(sink, "the audio client's stream is still playing after the switch", f"on {sink}")
        tail = [a for t, a in tone_levels(wav, 1100) if t >= max(0.0, (os.path.getsize(wav) - 44) / 176400 - 2.5)]
        lv = sorted(tail)[len(tail) // 2] if tail else 0.0
        st.write("tail-level", f"median 1100 Hz level over the capture's last 2.5 s: {lv:.4f} of full scale "
                 f"({20 * math.log10(max(lv, 1e-9)):.1f} dBFS)\n", "the tone's level at the end of the capture, "
                 "after the switch")
        st.check(lv >= 0.01, "and it is heard at the end of the capture, after the switch",
                 f"median level {lv:.4f} (-40 dBFS is 0.01)")
        kid = (xi_ids(ctx, USB_KBD) or [None])[-1]
        st.check(kid, "xinput lists the returned keyboard")
        xi_test_start(ctx, kid, "s778")
        ctx.type_line("afterkvm778", device=None)
        xit = xi_test_stop(ctx, kid, "s778")
        st.write("xinput-test", xit or "(no output)\n", f"EV-STATE: xinput test on the returned keyboard's own X "
                 f"device (id {kid}) while the line was typed")
        st.check(client_typed(ctx, st, "s778", "op778", "afterkvm778") and xi_events(xit)[3] >= 11,
                 "the xterm client took the line typed through the returned keyboard",
                 f"{xi_events(xit)[3]} key presses on the keyboard's own device")
        ctx.shot("typed", "EV-SHOT: the xterm client with the line typed after the switch")
        x_a = client_record(ctx, "s778", "xterm-after", "EV-PIDS: the xterm client after the switch")
        p_a = client_record(ctx, "s778p", "player-after", "EV-PIDS: the audio client after the switch")
        pids2 = ctx.pids("pids-after")
        st.check(ctx.session_pid(pids2, "Xorg") == ctx.session_pid(pids, "Xorg"), "Xorg kept its pid")
        client_same(ctx, st, "s778", x_b, x_a)
        client_same(ctx, st, "s778p", p_b, p_a)
    finally:
        with contextlib.suppress(Exception):
            g.client_stop("s778p")
        for dev in ("kvmtab", "kvmsnd"):
            with contextlib.suppress(Exception):
                m.device_del(dev)
        wait_xi(ctx, USB_TABLET, 0, 10)


# --- stories: E11 ----------------------------------------------------------------

def arrange(ctx, st, who, wid):
    """Move, resize, minimize, restore and maximize one window with the mouse,
    asserting each against xwininfo before and after."""
    tag = "desktop" if who.startswith("desktop") else "client"

    # Move: drag the title bar.
    xs = ctx.xstate()
    win = xs.by_id(wid)
    p = xs.parts(win)
    before = ctx.one(wid)
    frame = p["frame"]
    dx = 90 if frame.ax + frame.w + 90 < ctx.width - 8 else -90
    dy = 70 if frame.ay + frame.h + 70 < ctx.height - 8 else -70
    ctx.shot(f"{tag}-before-move", f"the {who} before its title bar is dragged by ({dx:+d},{dy:+d})")
    gx, gy = visible_point(ctx, xs, win, f"{who}'s title bar")
    with ctx.video(f"{tag}-move", f"the {who} following the title-bar drag (mwm draws an outline "
                   "while the button is held)"):
        ctx.drag(gx, gy, gx + dx, gy + dy)
    after = ctx.one(wid)
    ctx.shot(f"{tag}-after-move", f"the {who} moved by ({dx:+d},{dy:+d})")
    ctx.diff(f"{tag}-move", before.text, after.text, "xwininfo of the window: only the position lines change")
    moved = (after.ax - before.ax, after.ay - before.ay)
    st.check(abs(moved[0] - dx) <= 1 and abs(moved[1] - dy) <= 1,
             f"{who}: dragging the title bar moved the window with the pointer ({dx:+d},{dy:+d})",
             f"moved by {moved}")
    st.check((after.w, after.h) == (before.w, before.h), f"{who}: moving did not resize it")

    # Resize: drag the frame's bottom-right corner handle out by 10 columns
    # and 4 rows of xterm's character grid. mwm puts the frame's corner where
    # the pointer is rather than keeping where in the handle it was grabbed,
    # so the drag ends 10x4 cells (plus a pixel, so the snap to the grid
    # cannot round down) beyond the frame's outer corner, not beyond the
    # grab point.
    xs = ctx.xstate()
    p = xs.parts(xs.by_id(wid))
    frame = p["frame"]
    before = ctx.one(wid)
    inc = before.inc or (1, 1)
    cx, cy = p["corner"]
    ex = frame.ax + frame.w - 1 + 10 * inc[0] + 1
    ey = frame.ay + frame.h - 1 + 4 * inc[1] + 1
    st.check(ex < ctx.width - 4 and ey < ctx.height - 4, f"{who}: there is room on the screen to "
             "widen it by 10 columns and 4 rows", f"the corner would go to ({ex},{ey})")
    with ctx.video(f"{tag}-resize", f"the {who} following a drag of its bottom-right corner"):
        ctx.drag(cx, cy, ex, ey)
    after = ctx.one(wid)
    ctx.shot(f"{tag}-after-resize", f"the {who} resized by its corner")
    ctx.diff(f"{tag}-resize", before.text, after.text, "xwininfo: width, height and -geometry change, "
             "the top-left does not")
    got = (after.cells[0] - before.cells[0], after.cells[1] - before.cells[1]) \
        if before.cells and after.cells else None
    st.check(got == (10, 4), f"{who}: dragging the frame's corner resized it by 10 columns and 4 rows",
             f"-geometry {before.geometry} -> {after.geometry}")
    st.check((after.ax, after.ay) == (before.ax, before.ay),
             f"{who}: resizing by the bottom-right corner kept the top-left where it was")

    # Minimize with the frame's button, restore by double-clicking the icon.
    xs = ctx.xstate()
    p = xs.parts(xs.by_id(wid))
    before = ctx.one(wid)
    ctx.click(*p["min_btn"])
    iconic = ctx.wait_state(wid, "Iconic")
    st.check(iconic, f"{who}: the minimize button iconified it", f"WM_STATE {ctx.one(wid).wm_state}")
    ctx.diff(f"{tag}-minimize", before.text, iconic.text, "xwininfo/xprop: Map State and WM_STATE "
             "change, the geometry does not")
    icon = ctx.one(iconic.icon) if iconic.icon else None
    st.check(icon is not None and icon.map_state == "IsViewable", f"{who}: its icon is on the screen",
             f"icon window {iconic.icon}")
    st.check(iconic.map_state != "IsViewable", f"{who}: the window itself left the screen")
    ctx.shot(f"{tag}-minimized", f"the {who} gone from the screen, its icon at +{icon.ax}+{icon.ay}")
    ctx.click(icon.ax + icon.w // 2, icon.ay + icon.h // 2, count=2)
    normal = ctx.wait_state(wid, "Normal")
    st.check(normal, f"{who}: double-clicking the icon restored it")
    ctx.diff(f"{tag}-restore", before.text, normal.text, "xwininfo/xprop before the minimize and after "
             "the restore: no difference")
    st.check(normal.rect == before.rect, f"{who}: it came back where it was", f"{before.rect} -> {normal.rect}")
    ctx.shot(f"{tag}-restored", f"the {who} back at {before.geometry}")

    # Minimize again and restore through the icon's window menu.
    xs = ctx.xstate()
    p = xs.parts(xs.by_id(wid))
    ctx.click(*p["min_btn"])
    iconic = ctx.wait_state(wid, "Iconic")
    st.check(iconic, f"{who}: minimized a second time")
    icon = ctx.one(iconic.icon)
    before_menu = ctx.xstate()
    ctx.click(icon.ax + icon.w // 2, icon.ay + icon.h // 2)
    found = ctx.wait_new_mapped(before_menu, lambda t: t.h > 100)
    st.check(found, f"{who}: a click on the icon posts its window menu")
    _, menu = found
    img = ctx.shot(f"{tag}-icon-menu", "the icon's window menu; Restore is its first entry and is enabled")
    rows = img.text_rows(menu.rect())
    # Restore is the menu's first entry. If it were insensitive the first
    # light row would be Move, a full entry further down.
    st.check(rows and rows[0][0] - menu.ay < 18, f"{who}: the icon's window menu offers Restore",
             f"first enabled row at +{rows[0][0] - menu.ay if rows else '-'} in the menu")
    ctx.click(menu.ax + menu.w // 2, (rows[0][0] + rows[0][1]) // 2)
    normal = ctx.wait_state(wid, "Normal")
    st.check(normal, f"{who}: Restore in the icon's window menu restored it")
    ctx.diff(f"{tag}-menu-restore", before.text, normal.text, "xwininfo/xprop before the minimize and "
             "after Restore: no difference")
    st.check(normal.rect == before.rect, f"{who}: and it came back where it was",
             f"{before.rect} -> {normal.rect}")
    ctx.shot(f"{tag}-menu-restored", f"the {who} back at {before.geometry} after Restore in the icon's "
             "window menu; also how it is before the maximize")

    # Maximize, and the same button again to restore.
    xs = ctx.xstate()
    p = xs.parts(xs.by_id(wid))
    before = ctx.one(wid)
    ctx.click(*p["max_btn"])
    big = wait_until(lambda: (lambda i: i if i.w > before.w else None)(ctx.one(wid)), 6, 0.3)
    st.check(big, f"{who}: the maximize button enlarged it")
    ctx.diff(f"{tag}-maximize", before.text, big.text, "xwininfo: the window grows to the screen")
    xs = ctx.xstate()
    frame = xs.frame_of(xs.by_id(wid))
    ctx.shot(f"{tag}-maximized", f"the {who} maximized: frame {frame.w}x{frame.h}+{frame.ax}+{frame.ay}")
    on_screen = frame.ax >= 0 and frame.ay >= 0 and frame.ax + frame.w <= ctx.width \
        and frame.ay + frame.h <= ctx.height
    st.check(on_screen and frame.w >= 0.95 * ctx.width and frame.h >= 0.95 * ctx.height,
             f"{who}: maximized, its frame fills the screen",
             f"frame {frame.w}x{frame.h}+{frame.ax}+{frame.ay} on {ctx.width}x{ctx.height}")
    st.record(f"{who}: one output in this layout, so maximize can only fill the whole screen; it gave "
              f"a {frame.w}x{frame.h}+{frame.ax}+{frame.ay} frame on {ctx.width}x{ctx.height} "
              "(xterm's character grid keeps it a few pixels short)")
    p = xs.parts(xs.by_id(wid))
    ctx.click(*p["max_btn"])
    back = wait_until(lambda: (lambda i: i if i.rect == before.rect else None)(ctx.one(wid)), 6, 0.3)
    st.check(back, f"{who}: the maximize button, pressed again, put it back as it was",
             f"{before.rect} -> {ctx.one(wid).rect}")
    ctx.diff(f"{tag}-unmaximize", before.text, back.text, "xwininfo before the maximize and after the "
             "second press: no difference")
    ctx.shot(f"{tag}-unmaximized", f"the {who} back at {before.geometry}")


def visible_point(ctx, xs, win, part):
    """A point on win's title bar that no window stacked above it covers."""
    p = xs.parts(win)
    pos = xs.stack_pos(win)
    above = [t.rect() for t in xs.tops[:pos] if xs.mapped(t) and t.w < ctx.width]
    title = p["title"]
    y = title.ay + title.h // 2
    for x in range(title.ax + title.w - 3 * title.h, title.ax + 2 * title.h, -8):
        if not any(contains(r, x, y) for r in above):
            return (x, y)
    raise StoryFailed(f"no visible stretch of the {part} to click on")


def s11_1_2(ctx, st):
    xs = ctx.xstate()
    desk = ctx.session_xterm(xs)
    st.check(desk is not None, "the desktop's own xterm (the session's) is on the screen")
    dinfo = ctx.one(desk.id)
    st.check(dinfo.wm_state == "Normal", "the desktop's own xterm is a normal window to start with",
             f"WM_STATE {dinfo.wm_state}")
    dframe = xs.frame_of(desk)
    # The client's xterm opens over the desktop's, as two working windows do.
    cx, cy = dframe.ax + dframe.w // 2, dframe.ay + dframe.h // 2
    ctx.client_sink("mouse", "opmouse", f"60x16+{cx}+{cy}", "client")
    xs, cli = ctx.wait_client("opmouse")
    st.check(overlaps(xs.frame_of(desk).rect(), xs.frame_of(cli).rect()),
             "the client's window overlaps the desktop's")
    ctx.save_state("start-tree", xs.text, "the window tree at the start (EV-STATE)")
    ctx.shot("start", "the desktop's xterm and the client container's xterm, overlapping")
    pids_before = ctx.pids("pids-start")
    client_pid = ctx.g.client_inspect("mouse")["pid"]
    st.record(f"the client's xterm is host pid {client_pid} in container op-mouse; the desktop's is "
              f"pid {dinfo.pid}")

    # The same arrangements on both windows: the client's first, while it is
    # on top, then the desktop's - whose drags raise it over the client.
    arrange(ctx, st, "client container's xterm", cli.id)
    arrange(ctx, st, "desktop's xterm", desk.id)

    # Raise: button 1 on the client's frame, where it shows from under the
    # desktop's window, brings it back up.
    xs = ctx.xstate()
    st.check(xs.stack_pos(desk) < xs.stack_pos(cli), "the desktop's window is above the client's before the raise")
    st.check(overlaps(xs.frame_of(desk).rect(), xs.frame_of(cli).rect()),
             "the two windows still overlap, so the stacking shows")
    tree_before = xs.text
    ctx.shot("before-raise", "the desktop's window on top of the client's")
    ctx.click(*visible_point(ctx, xs, cli, "client xterm's title bar"))
    xs = ctx.xstate()
    ctx.diff("raise-tree", tree_before, xs.text, "the window tree: the client xterm's frame moves "
             "above the desktop's (top-level windows are listed top-most first)")
    ctx.shot("after-raise", "the client's window now on top")
    st.check(xs.stack_pos(cli) < xs.stack_pos(desk), "button 1 on the client xterm's frame raised it "
             "above the desktop's")

    # Close the client's window from its window menu: press button 3 on the
    # frame, which posts the menu (letting go there takes it down again), and
    # let go on Close, its last entry.
    keep = ctx.one(desk.id)
    bx, by = visible_point(ctx, xs, cli, "client xterm's title bar")
    ctx.move(bx, by)
    time.sleep(0.2)
    ctx.m.button("right", True)
    found = ctx.wait_new_mapped(xs, lambda t: t.h > 100)
    if not found:
        ctx.m.button("right", False)
    st.check(found, "button 3 on the client's frame posts its window menu")
    _, menu = found
    img = ctx.shot("window-menu", "the client window's menu, posted by button 3 on its frame; Close is "
                   "the last entry")
    rows = img.text_rows(menu.rect())
    if len(rows) < 2:
        ctx.m.button("right", False)
    st.check(len(rows) >= 2, "the window menu's entries are legible", f"{len(rows)} rows")
    ctx.glide(bx, by, menu.ax + menu.w // 2, (rows[-1][0] + rows[-1][1]) // 2, steps=8, dt=0.05)
    time.sleep(0.3)
    ctx.shot("window-menu-close", "Close armed under the pointer, button 3 still held")
    ctx.m.button("right", False)
    st.check(ctx.wait_gone(cli.id), "Close removed the client's window")
    st.check(wait_until(lambda: not ctx.g.pid_alive(client_pid), 10, 0.5),
             f"the client's xterm (pid {client_pid}) exited")
    st.check(wait_until(lambda: not ctx.g.client_exists("mouse"), 10, 0.5),
             "and its container went with it")
    after = ctx.one(desk.id)
    st.check(not after.gone and after.rect == keep.rect and after.wm_state == "Normal",
             "the desktop's xterm was untouched by the client's Close", f"{keep.rect} -> {after.rect}")
    pids_after = ctx.pids("pids-end")
    st.check(ctx.session_pid(pids_after, "Xorg") == ctx.session_pid(pids_before, "Xorg"),
             "the X server kept its pid throughout")
    st.check(ctx.g.pid_alive(dinfo.pid), f"the desktop's xterm (pid {dinfo.pid}) still runs")
    ctx.shot("end", "the desktop's xterm alone, where the drags left it")


def s11_1_3(ctx, st):
    xs = ctx.xstate()
    desk = ctx.session_xterm(xs)
    st.check(desk is not None, "the desktop's own xterm is on the screen")
    dinfo = ctx.one(desk.id)
    st.check(dinfo.wm_state == "Normal", "and it is a normal window", f"WM_STATE {dinfo.wm_state}")
    desk_pid = dinfo.pid
    fx, fy = ctx.free_spot(xs, (300, 200))
    ctx.client_sink("keys", "opkeys", f"40x10+{fx}+{fy}", "keys")
    xs, cli = ctx.wait_client("opkeys")
    pids_start = ctx.pids("pids-start")
    ctx.g.desk(["sh", "-c", ": > /tmp/op-kfocus"])

    # The last pointer event of the story: focus the desktop's xterm.
    ctx.click(*xs.parts(desk)["drag"])
    st.record("setup ended with a click on the desktop xterm's title bar; every input event after it "
              "in qemu.log is a key")

    def landed(tag):
        line = f"echo {tag} >>/tmp/op-kfocus"
        if tag in ctx.desk_lines("/tmp/op-kfocus"):
            return "desktop"
        if line in ctx.client_lines("keys", "/tmp/op-sink-opkeys"):
            return "client"
        return None

    n = [0]

    def probe():
        """Type a line; whichever window has the keyboard focus gets it."""
        n[0] += 1
        tag = f"kf{n[0]}"
        ctx.type_line(f"echo {tag} >>/tmp/op-kfocus")
        return wait_until(lambda: landed(tag), 6, 0.5)

    def colours(moment, focused):
        xs = ctx.xstate()
        img = ctx.shot(moment, f"the {focused} xterm focused: its frame #41637f, the other #22262d")
        on, off = (desk, cli) if focused == "desktop" else (cli, desk)
        a, b = img.px(*xs.parts(on)["swatch"]), img.px(*xs.parts(off)["swatch"])
        st.check(a == FOCUSED and b == UNFOCUSED, f"the frame colours show the {focused} xterm focused",
                 f"focused frame {a}, other {b}")

    st.check(probe() == "desktop", "typing lands in the desktop's xterm after the setup click")
    colours("focus-desktop", "desktop")
    ctx.chord("alt", "tab")
    st.check(probe() == "client", "Alt+Tab moved the keyboard focus to the client's xterm")
    colours("alt-tab", "client")
    ctx.chord("alt", "shift", "tab")
    st.check(probe() == "desktop", "Alt+Shift+Tab moved it back to the desktop's xterm")
    colours("alt-shift-tab", "desktop")

    for keys, label in ((("shift", "esc"), "Shift+Escape"), (("alt", "spc"), "Alt+Space")):
        before = ctx.xstate()
        ctx.chord(*keys)
        found = ctx.wait_new_mapped(before, lambda t: t.h > 100)
        st.check(found, f"{label} posts the focused window's menu")
        _, menu = found
        ctx.shot(label.lower().replace("+", "-"), f"the window menu {label} posted at the focused window")
        info = ctx.one(desk.id)
        st.check(abs(menu.ax - info.ax) <= 3 and abs(menu.ay - info.ay) <= 3,
                 f"the menu {label} posted belongs to the desktop's xterm (posted at its corner)",
                 f"menu at +{menu.ax}+{menu.ay}, window at +{info.ax}+{info.ay}")
        ctx.chord("esc")
        st.check(wait_until(lambda: not ctx.xstate().mapped(menu), 4, 0.3), f"Escape took {label}'s menu down")

    geometry = ctx.one(desk.id).rect
    ctx.chord("alt", "f9")
    iconic = ctx.wait_state(desk.id, "Iconic")
    st.check(iconic, "Alt+F9 minimized the focused window (the desktop's xterm)")
    ctx.shot("alt-f9", "the desktop's xterm iconified by Alt+F9")
    went = probe()
    st.record(f"after Alt+F9 the keyboard focus went to: {went or 'no window (the keys were lost)'}")
    # Alt+Tab cycles icons as well as windows. With one window and one icon
    # left, it reaches the icon in one press or two, depending on where Alt+F9
    # left the focus; the menu Shift+Escape posts says which it reached.
    icon = ctx.one(iconic.icon)
    menu, tabs = None, 0
    for tabs in (1, 2):
        ctx.chord("alt", "tab")
        before = ctx.xstate()
        ctx.chord("shift", "esc")
        found = ctx.wait_new_mapped(before, lambda t: t.h > 100)
        if found and abs(found[1].ax - icon.ax) <= 3 and abs(found[1].ay + found[1].h - icon.ay) <= 3:
            menu = found[1]
            break
        if found:
            ctx.chord("esc")
            wait_until(lambda: not ctx.xstate().mapped(found[1]), 4, 0.3)
    ctx.shot("icon-menu", "the iconified xterm's window menu, posted from the keyboard just above its icon")
    st.check(menu, "Alt+Tab reaches the iconified xterm's icon, and Shift+Escape posts the icon's "
             "window menu above it", f"icon at +{icon.ax}+{icon.ay}; {tabs} Alt+Tab press(es)")
    st.record(f"{tabs} Alt+Tab press(es) took the focus from where Alt+F9 left it to the icon")
    ctx.chord("r")
    normal = ctx.wait_state(desk.id, "Normal")
    st.check(normal, "the window menu's Restore (its mnemonic, R) restored the desktop's xterm")
    st.check(normal.rect == geometry, "it came back where it was", f"{geometry} -> {normal.rect}")
    ctx.shot("restored", "the desktop's xterm restored from the keyboard")

    where = probe()
    if where != "desktop":
        ctx.chord("alt", "tab")
        where = probe()
    st.check(where == "desktop", "the keyboard focus is on the desktop's xterm before Alt+F4")
    ctx.chord("alt", "f4")
    st.check(ctx.wait_gone(desk.id), "Alt+F4 closed the focused window (the desktop's xterm)")
    st.check(wait_until(lambda: not ctx.g.pid_alive(desk_pid), 10, 0.5),
             f"the desktop's xterm process (pid {desk_pid}) exited")
    ctx.shot("alt-f4", "the desktop's xterm closed by Alt+F4; the client's remains")
    # The session's own xterm is not restarted by anything: none takes its
    # place, and the session goes on without one (Xorg and mwm, checked at
    # the end against pids-start).
    time.sleep(5)
    st.check(not ctx.xstate().clients("xterm"), "no xterm took its place within 5 s of Alt+F4",
             f"xterm windows: {[w.id for w in ctx.xstate().clients('xterm')] or 'none'}")
    ctx.save_state("tree-after-alt-f4", ctx.xstate().text, "`xwininfo -root -tree` 5 s after Alt+F4 "
                   "(EV-STATE): the client's xterm, and no xterm of the session's")
    where = probe()
    st.record(f"after Alt+F4 the keyboard focus went to: {where or 'no window (the keys were lost)'}")
    if where != "client":
        ctx.chord("alt", "tab")
        where = probe()
    st.check(where == "client", "the keyboard alone moves the focus to the remaining window")
    ctx.save_state("sink-client", "\n".join(ctx.client_lines("keys", "/tmp/op-sink-opkeys")) + "\n",
                   "the client xterm's sink: the probe lines typed while it had the focus (EV-LOG-CLIENT)")
    ctx.save_state("sink-desktop", "\n".join(ctx.desk_lines("/tmp/op-kfocus")) + "\n",
                   "the tags the desktop xterm's shell wrote while it had the focus")
    pids_end = ctx.pids("pids-end")
    for comm in ("Xorg", "mwm"):
        was, now = ctx.session_pid(pids_start, comm), ctx.session_pid(pids_end, comm)
        st.check(was is not None and was == now, f"the session carried on: the same {comm} after Alt+F4",
                 f"{comm} pid {was} -> {now}")


def s11_2_1(ctx, st):
    # The story's pods A and B are client containers here: separate
    # containers holding only desktop.local/display, run by podman.
    st.record("pods A and B are two podman client containers (op-<name>), each holding only "
              "desktop.local/display; the desktop's xterm runs in the desktop container as the "
              "session user")
    rounds = (("PRIMARY", None), ("CLIPBOARD", "*selectToClipboard: true"))
    owners = {"desktop": "the desktop's", "pod A": "pod A's", "pod B": "pod B's"}
    for sel, xrm in rounds:
        s = sel[:4].lower()
        apps = {"desktop": f"op{s}desk", "pod A": f"op{s}a", "pod B": f"op{s}b"}
        words = {"desktop": f"desk{s}word", "pod A": f"apod{s}word", "pod B": f"bpod{s}word"}
        xs = ctx.xstate()
        spots = []
        for _ in apps:
            spots.append(ctx.free_spot(xs, (290, 100), avoid=[(x, y, 290, 100) for x, y in spots]))
        for (who, inst), (x, y) in zip(apps.items(), spots):
            if who == "desktop":
                ctx.desk_sink(inst, f"40x4+{x}+{y}", words[who], xrm)
            else:
                ctx.client_sink(inst, inst, f"40x4+{x}+{y}", words[who], xrm)
        wins = {who: ctx.wait_client(inst)[1].id for who, inst in apps.items()}
        ctx.pids(f"{s}-pids")
        ctx.shot(f"{s}-three", f"{sel}: three xterms - the desktop's and pods A's and B's - each "
                 "showing its own word")

        def lines(who):
            inst = apps[who]
            if who == "desktop":
                return ctx.desk_lines(f"/tmp/op-sink-{inst}")
            return ctx.client_lines(inst, f"/tmp/op-sink-{inst}")

        def word_point(who):
            info = ctx.one(wins[who])
            base, inc = info.base or (19, 4), info.inc or (6, 13)
            # Row 0 of the text area, mid-word. The text starts after the
            # scrollbar, which xterm counts in its base width.
            x = info.ax + base[0] - 2 + inc[0] * len(words[who]) // 2
            return x, info.ay + 2 + inc[1] // 2

        def paste_into(who):
            """Focus by the title bar, paste with the middle button, Enter."""
            xs = ctx.xstate()
            ctx.click(*xs.parts(wins[who])["drag"])
            info = ctx.one(wins[who])
            ctx.click(info.ax + info.w // 2, info.ay + info.h // 2, button="middle")
            ctx.chord("ret")

        pairs = [(src, dst) for src in apps for dst in apps if src != dst]
        for n, (src, dst) in enumerate(pairs, 1):
            tag = f"{src.replace(' ', '')}-to-{dst.replace(' ', '')}"
            decoy = f"decoy{s}{n}"
            ctx.click(*word_point(src), count=2)
            ctx.shot(f"{s}-{tag}-selected", f"{sel}: '{words[src]}' selected by a double-click "
                     f"in {owners[src]} xterm")
            # The control: overwrite the cut buffer xterm also writes, so a
            # word that arrives can only have come through the selection.
            ctx.g.xprobe(f"xprop -root -f CUT_BUFFER0 8s -set CUT_BUFFER0 {decoy}",
                         label=f"observer: CUT_BUFFER0 := {decoy} (control)")
            paste_into(dst)
            got = wait_until(lambda: words[src] in lines(dst), 5, 0.4)
            ctx.shot(f"{s}-{tag}-pasted", f"{sel}: '{words[src]}' pasted into {owners[dst]} xterm")
            st.check(got, f"{sel}: text selected in {owners[src]} xterm pastes into {owners[dst]}",
                     f"{owners[dst]} sink ends {lines(dst)[-1:]}, the cut buffer held '{decoy}'")

        for who in apps:
            ctx.save_state(f"{s}-sink-{who.replace(' ', '')}", "\n".join(lines(who)) + "\n",
                           f"{sel}: every line {owners[who]} xterm received (EV-LOG-CLIENT)")

        if sel == "CLIPBOARD":
            # Pod A's application goes away while it owns the selection.
            ctx.click(*word_point("pod A"), count=2)
            ctx.g.client_stop(apps["pod A"])
            st.check(ctx.wait_gone(wins["pod A"]), "pod A's xterm exited")
            cut = ctx.g.xprobe("xprop -root CUT_BUFFER0 2>&1; true", label="observer: xprop -root CUT_BUFFER0")
            before_n = len(lines("pod B"))
            paste_into("pod B")
            wait_until(lambda: len(lines("pod B")) > before_n, 5, 0.4)
            new = lines("pod B")[before_n:]
            ctx.shot("owner-gone-paste", "a paste into pod B after pod A's xterm, which owned the "
                     "selection, exited")
            st.record(f"with pod A's xterm gone, a paste into pod B gave {new!r}; the root's cut buffer "
                      f"held: {cut.strip()} (the session runs no clipboard manager)")
        for who, inst in apps.items():
            if who == "desktop":
                ctx.g.desk(["pkill", "-u", "desktop", "-f", f"xterm -name {inst}"], check=False)
            else:
                ctx.g.client_stop(inst)
        for wid in wins.values():
            ctx.wait_gone(wid)


def s11_1_1(ctx, st):
    # One entry after another, each leaving what the next one needs: the two
    # terminals the first two open are what Pack Icons iconifies, and Quit
    # session, which ends the X session, has to come last.
    # The VM's clock, both ways: podman logs takes RFC 3339, journalctl @epoch.
    state = {"since": ctx.g.sh("date -u +%Y-%m-%dT%H:%M:%SZ", label="date").strip(),
             "epoch": ctx.g.sh("date +%s", label="date +%s").strip()}
    table = ctx.pids("pids-start")
    state["xorg"] = ctx.session_pid(table, "Xorg")
    st.check(state["xorg"], "one X server runs for the session", f"Xorg pid {state['xorg']}")
    for step in (menu_new_terminal, menu_host_terminal, menu_refresh, menu_pack_icons,
                 menu_restart_mwm, menu_quit_session):
        step(ctx, st, state)


def xorg_kept(ctx, st, state, entry, before):
    """After a menu entry: the window tree's change (EV-DIFF), and the X
    server's pid, which only Quit session may change."""
    moment = entry.lower().replace(" ", "-")
    ctx.diff(f"{moment}-tree", before.text, ctx.xstate().text,
             f"`xwininfo -root -tree` before and after '{entry}'")
    now = ctx.session_pid(ctx.pids(f"pids-after-{moment}"), "Xorg")
    st.check(now == state["xorg"], f"the X server kept its pid through '{entry}'",
             f"{state['xorg']} -> {now}")


def menu_new_terminal(ctx, st, state):
    xs, _ = ctx.root_menu("New Terminal", "new-terminal")
    before = xs
    found = ctx.new_xterm(xs)
    st.check(found, "'New Terminal' opened an xterm")
    state["t1"] = found[1]
    ctx.shot("new-terminal", "the xterm 'New Terminal' opened")
    pid = ctx.one(found[1].id).pid
    st.check(pid and ctx.g.pid_alive(pid), "its xterm process runs", f"pid {pid}")
    state["t1_pid"] = pid
    xorg_kept(ctx, st, state, "New Terminal", before)


def menu_host_terminal(ctx, st, state):
    xs, _ = ctx.root_menu("Host Terminal", "host-terminal")
    before = xs
    found = ctx.new_xterm(xs)
    st.check(found, "'Host Terminal' opened an xterm")
    xs, t2 = found
    state["t2"] = t2
    st.record(f"the Host Terminal window is titled {ctx.one(t2.id).name!r} on first look; xterm "
              "starts it as 'host' and the host's shell prompt may retitle it")
    shell_up = wait_until(lambda: ctx.g.sh("pgrep -u desktop-shell -x bash >/dev/null && echo up; true",
                                           label="a desktop-shell bash on the host?").strip(), 20, 1)
    st.check(shell_up, "a shell runs on the host as desktop-shell, behind the Host Terminal window")
    ctx.g.sh("rm -f /tmp/op-host-whoami")
    ctx.click(*xs.parts(t2)["drag"])
    # tee, so the answer is on the screen for the shot as well as in a file
    # the harness can read.
    ctx.type_line("whoami | tee /tmp/op-host-whoami")
    who = wait_until(lambda: ctx.g.sh("cat /tmp/op-host-whoami 2>/dev/null; true",
                                      label="cat /tmp/op-host-whoami").strip(), 10, 0.5)
    ctx.shot("host-terminal", "the Host Terminal window: a desktop-shell prompt on the host, the "
             "whoami typed into it and its answer")
    st.check(who == "desktop-shell", "typing into Host Terminal runs commands on the host as desktop-shell",
             f"whoami wrote {who!r} on the host")
    journal = ctx.save_cmd("sshd-journal",
                           f"journalctl -u sshd --since @{state['epoch']} -o short-precise --no-pager "
                           "| grep 'Accepted publickey for desktop-shell'",
                           "EV-LOG-JOURNAL: sshd accepting the desktop-shell key for this login",
                           label="sshd's journal")
    st.check(journal.strip(), "sshd logged the publickey login behind the window")
    xorg_kept(ctx, st, state, "Host Terminal", before)


def menu_refresh(ctx, st, state):
    # Nothing moves and nothing restarts: Refresh only redraws.
    before = ctx.xstate()
    wids = [c.id for c in before.walk() if c.instance]
    info_before = ctx.info(*wids)
    pids_before = ctx.pids("pids-before-refresh")
    ctx.root_menu("Refresh", "refresh")
    time.sleep(1.5)
    after = ctx.xstate()
    info_after = ctx.info(*wids)
    ctx.diff("refresh-tree", before.text, after.text, "the window tree across Refresh: no difference")
    ctx.shot("refresh", "the desktop after Refresh: the same windows in the same places")
    st.check({t.id for t in after.mapped_tops()} == {t.id for t in before.mapped_tops()},
             "Refresh left the same windows on the screen")
    moved = [w for w in wids if info_before[w].rect != info_after[w].rect]
    st.check(not moved, "Refresh moved no window", f"moved: {moved}")
    pids_after = ctx.pids("pids-after-refresh")
    for comm in ("Xorg", "mwm"):
        st.check(ctx.session_pid(pids_after, comm) == ctx.session_pid(pids_before, comm),
                 f"Refresh restarted no {comm}")
    st.check(ctx.g.pid_alive(state["t1_pid"]), "the New Terminal xterm still runs after Refresh")


def menu_pack_icons(ctx, st, state):
    # Two windows iconified, their icons dragged apart, then packed.
    xs = ctx.xstate()
    before = xs
    terms = sorted((state["t1"], state["t2"]), key=xs.stack_pos)     # top-most first
    slots = {}
    for t in terms:
        xs = ctx.xstate()
        ctx.click(*xs.parts(xs.by_id(t.id))["min_btn"])
        iconic = ctx.wait_state(t.id, "Iconic")
        st.check(iconic, "a terminal minimized with its frame's button, for Pack Icons")
        slots[t.id] = iconic.icon
    placed = {tid: (ctx.one(icon).ax, ctx.one(icon).ay) for tid, icon in slots.items()}
    ctx.shot("icons-placed", f"the two icons where mwm placed them: {sorted(placed.values())}")
    for i, icon_id in enumerate(slots.values()):
        icon = ctx.one(icon_id)
        tx = int(ctx.width * (0.55 if i == 0 else 0.35))
        ty = int(ctx.height * (0.3 if i == 0 else 0.5))
        with ctx.video(f"icon-drag-{i + 1}", "an icon dragged away from mwm's icon row"):
            ctx.drag(icon.ax + icon.w // 2, icon.ay + icon.h // 2, tx, ty)
    scattered = {tid: (ctx.one(icon).ax, ctx.one(icon).ay) for tid, icon in slots.items()}
    ctx.shot("icons-scattered", "the two icons dragged apart, away from the icon row")
    st.check(all(scattered[t] != placed[t] for t in slots), "both icons were dragged off their places",
             f"placed {sorted(placed.values())}, now {sorted(scattered.values())}")
    ctx.root_menu("Pack Icons", "pack-icons")
    time.sleep(1.0)
    packed = {tid: (ctx.one(icon).ax, ctx.one(icon).ay) for tid, icon in slots.items()}
    ctx.shot("icons-packed", "the icons packed back into mwm's icon row")
    st.check(set(packed.values()) == set(placed.values()),
             "Pack Icons packed the icons back into the places mwm first gave them",
             f"placed {sorted(placed.values())}, packed {sorted(packed.values())}")
    xorg_kept(ctx, st, state, "Pack Icons", before)


def menu_restart_mwm(ctx, st, state):
    # The same X session, a new connection from mwm. f.restart re-executes mwm
    # in place, so its pid can stay the same; what cannot stay the same is its
    # connection to the server. (Frame window ids are no evidence either way:
    # the server hands the new connection the old one's id range, so the new
    # frames can reuse the old ids.)
    def mwm_sockets():
        return ctx.g.desk(["sh", "-c", 'for f in /proc/$(pgrep -u desktop -x mwm)/fd/*; do readlink "$f"; done '
                           '| grep socket: | sort'], check=False).split()

    table = ctx.pids("pids-before-restart")
    mwm_pid, socks = ctx.session_pid(table, "mwm"), mwm_sockets()
    before = ctx.xstate()
    clients = [c.id for c in before.walk() if c.instance == "xterm"]
    states = {w: ctx.one(w).wm_state for w in clients}
    with ctx.video("restart-mwm", "Restart mwm: the frames go and come back; the windows stay"):
        ctx.root_menu("Restart mwm", "restart-mwm")
        ctx.confirm(before, "restart-mwm")
        renewed = wait_until(lambda: (lambda s: s if s and s != socks else None)(mwm_sockets()), 20, 0.5)
        time.sleep(2)
    after = ctx.xstate(check=False)
    ctx.diff("restart-tree", before.text, after.text, "the window tree across Restart mwm: the same "
             "client windows, in frames mwm made again")
    table = ctx.pids("pids-after-restart")
    st.check(renewed, "Restart mwm replaced mwm's connection to the X server",
             f"mwm's sockets {socks} -> {mwm_sockets()}")
    st.record(f"mwm pid {mwm_pid} -> {ctx.session_pid(table, 'mwm')}")
    st.check(ctx.session_pid(table, "Xorg") == state["xorg"], "Restart mwm started no new X session")
    still = ctx.info(*clients)
    st.check(all(not still[w].gone and still[w].wm_state == states[w] for w in clients),
             "every window survived Restart mwm, in the state it was in",
             str({w: (states[w], still[w].wm_state) for w in clients}))
    ctx.shot("after-restart-mwm", "the desktop after Restart mwm: the same windows (here, two icons)")


def menu_quit_session(ctx, st, state):
    # The session ends and desktop-init starts a new one (S2.3.6).
    xorg = state["xorg"]
    before = ctx.xstate()

    def back():
        new_x, new_wm = ctx.pid_of("Xorg"), ctx.pid_of("mwm")
        if new_x and new_wm and new_x != xorg and ctx.session_xterm(ctx.xstate(check=False)):
            return (new_x, new_wm)
        return None

    with ctx.video("quit-session", "Quit session: the X session ends, and 3 s later a new one starts "
                   "with its xterm at 100x30+60+60"):
        ctx.root_menu("Quit session", "quit-session")
        ctx.confirm(before, "quit-session")
        came_back = wait_until(back, 60, 1)
        time.sleep(1)
    table = ctx.pids("pids-after-quit")
    st.check(came_back, "after Quit session a new X session came up, with a new X server and mwm",
             f"Xorg {xorg} -> {ctx.session_pid(table, 'Xorg')}")
    xs = ctx.xstate()
    ctx.diff("quit-session-tree", before.text, xs.text, "`xwininfo -root -tree` before Quit session and "
             "in the new session: every window new, the session's xterm back")
    img = ctx.shot("after-quit-session", "the desktop back after Quit session: the root colour and the "
                   "session's xterm")
    term = ctx.session_xterm(xs)
    st.check(term and ctx.one(term.id).geometry == "100x30+60+60",
             "the new session shows its xterm at 100x30+60+60")
    x, y = ctx.free_point(xs)
    st.check(img.px(x, y) == ROOT_RGB, "and the #101216 root", f"sampled {img.px(x, y)} at ({x},{y})")
    ctx.save_cmd("desktop-log", f"podman logs --since {state['since']} desktop 2>&1 | tail -80",
                 "the desktop's log for this story (EV-LOG-DESKTOP): the session's exit and restart",
                 label="podman logs desktop")
    # S2.3.5's other half: a clean end runs no postmortem. desktop-init calls
    # it only for a nonzero exit, and Quit session is the clean end.
    full = ctx.g.sh(f"podman logs --since {state['since']} desktop 2>&1; true")
    exits = re.findall(r"desktop-init: session exited \(rc=(\d+)\)", full)
    st.check(exits == ["0"] and "postmortem:" not in full,
             "Quit session is a clean end: desktop-init logs 'session exited (rc=0)' and no postmortem runs (S2.3.5)",
             f"session exits logged: {exits or 'none'}; postmortem lines: {full.count('postmortem:')}")


# --- S11.3.1: sound under the operator's control ---------------------------------

def tone_levels(path, freq, win=0.1):
    """(start seconds, amplitude as a fraction of full scale) per window, of
    the captured left channel at `freq`."""
    w = wave.open(path, "rb")
    rate, nch, n = w.getframerate(), w.getnchannels(), w.getnframes()
    raw = w.readframes(n)
    w.close()
    step = int(rate * win)
    coeff = 2.0 * math.cos(2.0 * math.pi * freq / rate)
    left = [int.from_bytes(raw[i:i + 2], "little", signed=True) for i in range(0, len(raw) - 1, 2 * nch)]
    out = []
    for start in range(0, len(left) - step + 1, step):
        s1 = s2 = 0.0
        for x in left[start:start + step]:
            s0 = x + coeff * s1 - s2
            s2, s1 = s1, s0
        mag = math.sqrt(max(0.0, s1 * s1 + s2 * s2 - coeff * s1 * s2))
        out.append((start / rate, 2.0 * mag / step / 32768.0))
    return out


def level_plot(levels, marks, path):
    """A picture of the 1100 Hz level over the capture, one bar per window
    (green), on a -60..0 dBFS scale, with a vertical line at each mark. The
    legend goes in the analysis file: this draws no text."""
    w, h = max(200, len(levels) * 2), 240
    img = bytearray(b"\x10\x12\x16" * w * h)

    def put(x, y, rgb):
        if 0 <= x < w and 0 <= y < h:
            img[(y * w + x) * 3:(y * w + x) * 3 + 3] = bytes(rgb)

    for i, (_, a) in enumerate(levels):
        db = 20 * math.log10(a) if a > 1e-6 else -120
        top = int((min(0, max(-60, db)) / -60) * (h - 1))
        for y in range(top, h):
            put(2 * i, y, (0x7F, 0xA8, 0x60))
            put(2 * i + 1, y, (0x7F, 0xA8, 0x60))
    palette = [(0xE0, 0x6C, 0x65), (0xE5, 0xB5, 0x67), (0x6B, 0xA3, 0xD8), (0xC0, 0x8F, 0xDB),
               (0x5F, 0xC9, 0xBF), (0xE6, 0xE9, 0xEE)]
    for k, (_, t) in enumerate(marks):
        x = int(t / 0.1) * 2
        for y in range(h):
            put(x, y, palette[k % len(palette)])
    for db in (-20, -40):
        y = int(db / -60 * (h - 1))
        for x in range(0, w, 4):
            put(x, y, (0x4A, 0x51, 0x5C))
    ppm = path + ".ppm"
    with open(ppm, "wb") as f:
        f.write(f"P6\n{w} {h}\n255\n".encode() + bytes(img))
    subprocess.run(["convert", ppm, path], check=True, timeout=60)
    os.unlink(ppm)
    return [(label, palette[k % len(palette)]) for k, (label, _) in enumerate(marks)]


def wp_sinks(status):
    """Sinks in `wpctl status`'s Audio section: id -> (name, volume, muted, default)."""
    sinks, section, in_audio = {}, None, False
    for line in status.splitlines():
        if line.startswith("Audio"):
            in_audio = True
            continue
        if in_audio and line and not line[0].isspace() and line[0] not in "├└│":
            break
        m = re.search(r"[├└]─ (.+?):\s*$", line)
        if m:
            section = m.group(1)
            continue
        if in_audio and section == "Sinks":
            m = re.search(r"(\*)?\s*(\d+)\.\s+(.*?)\s+\[vol:\s*([\d.]+)(\s+MUTED)?\]", line)
            if m:
                sinks[int(m.group(2))] = (m.group(3), float(m.group(4)), bool(m.group(5)), bool(m.group(1)))
    return sinks


def wpctl(ctx, *args):
    return ctx.g.desk(["wpctl", *args], check=False)


def node_name(ctx, ref):
    mm = re.search(r'node\.name = "([^"]+)"', wpctl(ctx, "inspect", str(ref)))
    return mm.group(1) if mm else None


def stream_sink(ctx):
    """The sink, by name, that the player's stream plays to, per pactl. By
    name because pactl's sink indexes are not the PipeWire ids wpctl shows."""
    sinks = {}
    for line in ctx.g.desk(["pactl", "list", "short", "sinks"], check=False).splitlines():
        f = line.split("\t")
        if len(f) > 1:
            sinks[f[0]] = f[1]
    for block in ctx.g.desk(["pactl", "list", "sink-inputs"], check=False).split("Sink Input #")[1:]:
        # application.name, not .process.binary: paplay is pacat by another
        # name, and reports the binary as pacat.
        if 'application.name = "paplay"' in block:
            mm = re.search(r"^\s*Sink: (\d+)", block, re.M)
            return sinks.get(mm.group(1)) if mm else None
    return None


def audio_devices(ctx):
    """F4.7's device state - what a sound-card hot-plug changes - as one text:
    /dev/snd on the host and in the container, PipeWire's devices, and
    pactl's sinks, sources and streams (S7.7.4)."""
    g = ctx.g
    parts = [("ls -l /dev/snd    # on the host", g.sh("ls -l /dev/snd 2>&1; true", label="ls -l /dev/snd (host)")),
             ("ls -l /dev/snd    # in the desktop container",
              g.sh("podman exec desktop ls -l /dev/snd 2>&1; true", label="ls -l /dev/snd (container)")),
             ("pw-cli ls Device", g.desk(["pw-cli", "ls", "Device"], check=False)),
             ("pactl list short sinks", g.desk(["pactl", "list", "short", "sinks"], check=False)),
             ("pactl list short sources", g.desk(["pactl", "list", "short", "sources"], check=False)),
             ("pactl list short sink-inputs", g.desk(["pactl", "list", "short", "sink-inputs"], check=False))]
    text = ""
    for cmd, out in parts:
        text += f"$ {cmd}\n" + (out if out.strip() else "(no output)\n") + "\n"
    return text


def audio_snapshot(ctx, moment, what):
    status = wpctl(ctx, "status")
    default = node_name(ctx, "@DEFAULT_AUDIO_SINK@")
    vol = wpctl(ctx, "get-volume", "@DEFAULT_AUDIO_SINK@").strip()
    ctx.st.write(moment, f"default sink: {default}\nwpctl get-volume @DEFAULT_AUDIO_SINK@: {vol}\n\n{status}",
                 what)
    return status, default, vol


def s11_3_1(ctx, st):
    # What has to be put back however the story ends: the hot-added card,
    # and the built-in output's volume as the story found it.
    held = {"card": None, "volume": None}
    try:
        sound_controls(ctx, st, held)
        sound_persistence(ctx, st)
    finally:
        with contextlib.suppress(Exception):
            ctx.g.client_stop("player")
        if held["card"] is not None:
            with contextlib.suppress(Exception):
                ctx.m.device_del("opsnd")
                wait_until(lambda: not any(node_name(ctx, i) == held["card"]
                                           for i in wp_sinks(wpctl(ctx, "status"))), 30, 1)
        with contextlib.suppress(Exception):
            if held["volume"]:
                wpctl(ctx, "set-volume", "@DEFAULT_AUDIO_SINK@", held["volume"])
            wpctl(ctx, "set-mute", "@DEFAULT_AUDIO_SINK@", "0")
            audio_snapshot(ctx, "end", "the audio state handed to the next phase: the built-in "
                           "output at the volume the story found it at")
    # The restore is checked, not assumed (Requirements.md S9.2.5).
    def restored():
        gone = held["card"] is None or not any(node_name(ctx, i) == held["card"]
                                               for i in wp_sinks(wpctl(ctx, "status")))
        vol = wpctl(ctx, "get-volume", "@DEFAULT_AUDIO_SINK@").strip()
        return gone and "MUTED" not in vol and (held["volume"] is None or vol == f"Volume: {held['volume']}"), gone, vol
    ok = wait_until(lambda: restored()[0], 10, 0.5)
    _, gone, vol = restored()
    st.check(ok, "restored: the hot-added card is gone, and the built-in output is back at the volume the story "
             "found it at, unmuted", f"card gone: {gone}; {vol}")


# Marks the analysis reads the capture against. The built-in output's own
# volume steps are recorded, not asserted: QEMU's emulated HDA output does not
# follow the volume it is set to (Requirements.md S11.3.1), so a level read
# there says more about the emulator than about the desktop. The emulated USB
# card does follow it, so the volume and mute assertions are made on it.
M_START = "capture starts"
M_B100 = "built-in output: set-volume 100%"
M_B50 = "built-in output: set-volume 50%"
M_PLUG = "USB sound card plugged in (QMP device_add)"
M_TO_BUILTIN = "set-default: the built-in output"
M_TO_USB = "set-default: the USB card"
M_U100 = "USB card: set-volume 100%"
M_U50 = "USB card: set-volume 50%"
M_MUTE = "USB card: set-mute 1"
M_UNMUTE = "USB card: set-mute 0"
M_END = "capture ends"


def sound_controls(ctx, st, held):
    """The operator's own controls, typed into a desktop terminal, with the
    machine's sound output captured throughout."""
    g, m = ctx.g, ctx.m
    marks = []
    t0 = [None]

    def mark(label):
        marks.append((label, time.monotonic() - t0[0]))
        ctx.run.log("mark", f"{label} at +{marks[-1][1]:.2f}s into the capture", echo=True)

    def command(text, label):
        # The mark goes at Enter, when the command takes effect.
        ctx.type(text)
        mark(label)
        ctx.chord("ret", settle=0.8)

    def volume_is(value):
        return wait_until(lambda: value in wpctl(ctx, "get-volume", "@DEFAULT_AUDIO_SINK@"), 6, 0.5)

    def after(slug, what):
        """The state each command left: `wpctl status` and the screen."""
        audio_snapshot(ctx, f"wpctl-status-{slug}", f"`wpctl status` after {what} (EV-STATE)")
        ctx.shot(f"after-{slug}", f"the operator's terminal after {what}: the command typed, the prompt back")

    devices = []

    def device_state(slug, what):
        """F4.7's set at one moment, diffed against the moment before (S7.7.4)."""
        text = audio_devices(ctx)
        name = st.write(f"devices-{slug}", text, f"/dev/snd (host and container), pw-cli ls Device and "
                        f"pactl's sinks, sources and sink-inputs {what} (EV-STATE)")
        if devices:
            prev_name, prev_text, prev_what = devices[-1]
            ctx.diff_kept(f"devices-{slug}", prev_name, prev_text, name, text,
                          f"EV-DIFF: from {prev_what} to {what}; the sink-inputs line shows which sink "
                          "the player's stream is on")
        devices.append((name, text, what))

    # EV-LOG-DESKTOP is bounded by this moment (podman logs --since).
    since = g.sh("date -u +%Y-%m-%dT%H:%M:%SZ", label="date").strip()

    # The application: a client container playing one long, continuous
    # 1100 Hz tone through nothing but desktop.local/audio.
    g.client_run("player", ["paplay", "/tmp/tone.wav"], devices=("audio",), image=TESTCLIENT_IMAGE,
                 copy_in={"/tmp/tone.wav": "/tmp/op-tone-1100.wav"})
    builtin = wait_until(lambda: stream_sink(ctx), 20, 0.5)
    st.check(builtin, "the client's player has a stream on the desktop's audio", f"on {builtin}")
    found_at = re.search(r"Volume: ([\d.]+)", wpctl(ctx, "get-volume", "@DEFAULT_AUDIO_SINK@"))
    held["volume"] = found_at.group(1) if found_at else None
    st.record(f"the built-in output's volume before the operator touched it: {held['volume']}")
    player = g.client_inspect("player")
    st.write("player-before", json.dumps(player, indent=1, sort_keys=True) + "\n",
             "EV-PIDS: the player container before the operator's commands: id, pid, start time, restarts")
    pids_before = ctx.pids("pids-start")
    pw_before = ctx.session_pid(pids_before, "pipewire")

    wav_name = st.name("audio-1100hz", "wav")
    wav = os.path.abspath(st.path(wav_name))
    m.hmp(f"wavcapture {wav} snd0 44100 16 2")
    t0[0] = time.monotonic()
    try:
        mark(M_START)
        time.sleep(2)

        # The operator's terminal, opened the operator's way.
        xs, _ = ctx.root_menu("New Terminal", "terminal")
        found = ctx.new_xterm(xs)
        st.check(found, "'New Terminal' opened the operator's terminal")
        ctx.click(*found[0].parts(found[1])["drag"])
        audio_snapshot(ctx, "wpctl-status-start", "`wpctl status` before the operator types anything (EV-STATE)")
        ctx.shot("terminal-open", "the operator's terminal, opened from the root menu, before any command")

        command("wpctl set-volume @DEFAULT_AUDIO_SINK@ 100%", M_B100)
        st.check(volume_is("1.00"), "typed into the terminal, wpctl set the built-in output to 100%")
        after("builtin-100", "set-volume 100% on the built-in output")
        time.sleep(2)
        command("wpctl set-volume @DEFAULT_AUDIO_SINK@ 50%", M_B50)
        st.check(volume_is("0.50"), "and then to 50%")
        after("builtin-50", "set-volume 50% on the built-in output")
        time.sleep(2)

        # A USB headset arrives, and the operator chooses where the sound goes.
        before = wp_sinks(wpctl(ctx, "status"))
        device_state("before-plug", "before the card is plugged")
        st.write("info-usb-before", m.hmp("info usb"), "QEMU's `info usb` before the card is plugged (EV-QEMU)")
        with ctx.video("plug", "the display while the USB card is plugged in (QMP device_add): nothing on "
                       "it changes, and nothing restarts"):
            m.device_add(driver="usb-audio", id="opsnd", audiodev="snd0", bus="xhci.0")
            held["card"] = ""
            mark(M_PLUG)
            new = wait_until(lambda: [i for i in wp_sinks(wpctl(ctx, "status")) if i not in before], 30, 1)
        st.check(new, "the hot-added card shows up as a new output in wpctl status")
        st.write("info-usb-after", m.hmp("info usb"), "QEMU's `info usb` with the card plugged (EV-QEMU)")
        usb_id = new[0]
        usb_name = node_name(ctx, usb_id)
        held["card"] = usb_name
        status, _, _ = audio_snapshot(ctx, "wpctl-status-plugged",
                                      f"`wpctl status` with the USB card plugged: its sink is id {usb_id}")
        time.sleep(1)
        on_plug = stream_sink(ctx)
        st.record(f"on plug-in, before the operator chose anything, the stream went to {on_plug} "
                  f"(WirePlumber {'moved it by itself' if on_plug == usb_name else 'left it where it was'})")
        device_state("plugged", "with the card plugged, before the operator chose an output")
        if on_plug == usb_name:
            # Already moved: choose the built-in output first, so that both
            # directions of the choice are seen.
            builtin_id = next(i for i in wp_sinks(status) if node_name(ctx, i) == builtin)
            command(f"wpctl set-default {builtin_id}", M_TO_BUILTIN)
            st.check(wait_until(lambda: stream_sink(ctx) == builtin, 8, 0.5),
                     "wpctl set-default moved the client's stream to the built-in output")
            after("default-builtin", "set-default to the built-in output")
            device_state("on-builtin", "after set-default to the built-in output")
            time.sleep(1)
        command(f"wpctl set-default {usb_id}", M_TO_USB)
        st.check(wait_until(lambda: stream_sink(ctx) == usb_name, 8, 0.5),
                 "wpctl set-default moved the client's stream to the USB card",
                 f"the stream is on {stream_sink(ctx)}, the card is {usb_name}")
        after("default-usb", "set-default to the USB card")
        device_state("on-usb", "after set-default to the USB card")
        time.sleep(1)

        # Volume and mute on the output the stream now plays from.
        command("wpctl set-volume @DEFAULT_AUDIO_SINK@ 100%", M_U100)
        st.check(volume_is("1.00"), "wpctl set the USB card to 100%")
        after("usb-100", "set-volume 100% on the USB card")
        time.sleep(2)
        command("wpctl set-volume @DEFAULT_AUDIO_SINK@ 50%", M_U50)
        st.check(volume_is("0.50"), "and then to 50%")
        after("usb-50", "set-volume 50% on the USB card")
        time.sleep(2)
        command("wpctl set-mute @DEFAULT_AUDIO_SINK@ 1", M_MUTE)
        st.check(volume_is("MUTED"), "wpctl set-mute 1 muted it")
        after("usb-muted", "set-mute 1 on the USB card")
        time.sleep(2)
        command("wpctl set-mute @DEFAULT_AUDIO_SINK@ 0", M_UNMUTE)
        st.check(wait_until(lambda: "MUTED" not in wpctl(ctx, "get-volume", "@DEFAULT_AUDIO_SINK@"), 6, 0.5),
                 "wpctl set-mute 0 unmuted it")
        after("usb-unmuted", "set-mute 0 on the USB card")
        time.sleep(2)
        mark(M_END)
    finally:
        m.hmp("stopcapture 0")
        wall = time.monotonic() - t0[0]
    st.attach(wav_name, "EV-AUDIO: the machine's output across the whole sequence - listen for the "
              "tone moving between the outputs, dropping at 50% on the USB card, and going silent "
              "while muted")
    ctx.shot("terminal", "the operator's terminal with every wpctl command typed into it")
    audio_snapshot(ctx, "wpctl-status-end", "`wpctl status` at the end of the sequence")

    player_after = g.client_inspect("player")
    st.write("player-after", json.dumps(player_after, indent=1, sort_keys=True) + "\n",
             "EV-PIDS: the player container after every command: the same id, pid, start time and restarts")
    pids_after = ctx.pids("pids-after-controls")
    st.check(player_after == player, "the player was not restarted: same container, pid, start time, "
             "no restarts", f"{player} -> {player_after}")
    st.check(ctx.session_pid(pids_after, "pipewire") == pw_before, "PipeWire was not restarted by any of it",
             f"pipewire pid {pw_before} -> {ctx.session_pid(pids_after, 'pipewire')}")
    analyse_capture(ctx, st, wav, marks, wall)
    ctx.save_cmd("desktop-log", f"podman logs --since {since} desktop 2>&1 | tail -100",
                 "EV-LOG-DESKTOP: the desktop's log from the story's start: nothing about the card's "
                 "arrival or the operator's commands restarted anything", label="podman logs desktop")


def analyse_capture(ctx, st, wav, marks, wall):
    """The level of the 1100 Hz tone in each 0.1 s of the capture, read
    against the moments the commands were entered.

    wavcapture records what the guest's sound devices play, and only while
    one of them is running: a stretch with no device running at all is
    missing from the file, not silent in it. So a gap in the sound shows up
    two ways - as quiet inside the capture, or as the capture being shorter
    than the wall-clock time it ran - and both are measured."""
    levels = tone_levels(wav, 1100)
    with wave.open(wav, "rb") as w:
        duration = w.getnframes() / w.getframerate()
    t = dict(marks)
    times = sorted(t.values())

    def level(start, end):
        vals = sorted(a for at, a in levels if start <= at < end)
        return vals[len(vals) // 2] if vals else 0.0

    def until_next(label):
        later = [x for x in times if x > t[label]]
        return later[0] if later else duration

    def settled(label):
        """The level once the command has taken effect, until the next one."""
        return level(t[label] + 1.0, until_next(label) - 0.3)

    def db(a, b):
        return 20 * math.log10(max(a, 1e-9) / max(b, 1e-9))

    b_start, b100, b50 = level(0.5, t[M_B100] - 0.3), settled(M_B100), settled(M_B50)
    u100, u50, muted, back = settled(M_U100), settled(M_U50), settled(M_MUTE), settled(M_UNMUTE)

    # Every change of output - the card's arrival and each set-default - must
    # leave no silence: nothing below a tenth of the quieter of the levels
    # either side of it.
    moves = []
    for label in (M_PLUG, M_TO_BUILTIN, M_TO_USB):
        if label not in t:
            continue
        at = t[label]
        before = level(at - 2.0, at - 0.3)
        after = level(at + 1.0, min(at + 3.0, until_next(label) - 0.3))
        floor = 0.1 * min(before, after)
        gap = run = 0.0
        for start, a in levels:
            if at - 0.5 <= start < min(at + 3.0, until_next(label)):
                run = run + 0.1 if a < floor else 0.0
                gap = max(gap, run)
        moves.append((label, before, after, gap))
    missing = wall - duration

    plot = st.name("level", "png")
    legend = level_plot(levels, marks, st.path(plot))
    checker = subprocess.run([sys.executable, os.path.join(os.path.dirname(os.path.abspath(__file__)),
                                                           "check-audio.py"), wav, "10", "0.02", "1100"],
                             capture_output=True, text=True)
    text = ["1100 Hz level, median once each command had taken effect (fraction of full scale):",
            f"  built-in output, as found        {b_start:.4f}",
            f"  built-in output at 100%          {b100:.4f}",
            f"  built-in output at 50%           {b50:.4f}  ({db(b50, b100):+.1f} dB; recorded only)",
            f"  USB card at 100%                 {u100:.4f}",
            f"  USB card at 50%                  {u50:.4f}  ({db(u50, u100):+.1f} dB; wpctl's cubic "
            "scale makes 50% -18.1 dB)",
            f"  USB card muted                   {muted:.4f}",
            f"  USB card unmuted                 {back:.4f}", "",
            "changes of output (level before -> after, longest stretch below a tenth of the quieter):"]
    text += [f"  {label}: {b:.4f} -> {a:.4f}, {g:.1f} s" for label, b, a, g in moves]
    text += ["", f"capture {duration:.2f} s against {wall:.2f} s of wall clock: {missing:.2f} s with no "
             "sound device running", "",
             "marks, in seconds into the capture, with their colour in the level plot:"]
    text += [f"  {at:7.2f}  #{r:02x}{g:02x}{b:02x}  {label}"
             for (label, at), (_, (r, g, b)) in zip(marks, legend)]
    text += ["", "check-audio.py (whole capture, loudest 0.75 s window):",
             (checker.stdout + checker.stderr).rstrip()]
    st.attach(plot, "the tone's level over the capture: one green bar per 0.1 s on a -60..0 dBFS scale "
              "(grey lines at -20 and -40), a coloured line at each mark (legend in the analysis file)")
    st.write("analysis", "\n".join(text) + "\n", "the analyser's reading of the capture, phase by phase")
    st.record(f"the built-in output (QEMU's emulated HDA) read {b_start:.4f} as found, {b100:.4f} at 100% "
              f"and {b50:.4f} at 50%: recorded, not asserted")
    st.check(checker.returncode == 0, "the capture carries the client's 1100 Hz tone")
    st.check(-20 <= db(u50, u100) <= -16, "set-volume 50% on the USB card lowered what the machine "
             "played by about 18 dB (wpctl's cubic scale: 0.5 cubed is -18.1 dB; held to -16..-20 dB)",
             f"{u100:.4f} -> {u50:.4f}, {db(u50, u100):+.1f} dB")
    st.check(muted < 0.1 * u50, "set-mute 1 silenced it", f"{u50:.4f} -> {muted:.4f}")
    st.check(back > 0.5 * u50, "set-mute 0 brought it back", f"{muted:.4f} -> {back:.4f}")
    for label, b, a, g in moves:
        st.check(g <= 0.5, f"{label}: the sound carried on, with no silence longer than 0.5 s",
                 f"{b:.4f} -> {a:.4f}, longest drop {g:.1f} s")
    st.check(missing <= 1.0, "no stretch with no sound device running at all longer than 1 s",
             f"the capture is {duration:.2f} s of {wall:.2f} s")


def sound_persistence(ctx, st):
    """What the operator's choices survive: recorded, not asserted (the
    container's home directory, where WirePlumber keeps them, is not meant
    to outlive the container)."""
    g = ctx.g
    ctx.save_cmd("player-log", "podman logs op-player 2>&1",
                 "the player's own output (EV-LOG-CLIENT): '(no output)' unless paplay complained",
                 label="podman logs op-player")
    g.client_stop("player")
    audio_snapshot(ctx, "persist-0-before", "volume, mute and default output as the operator left them")
    pw = ctx.pid_of("pipewire")
    g.desk(["pkill", "-u", "desktop", "-x", "pipewire"], check=False)
    st.check(wait_until(lambda: (lambda p: p if p and p != pw else None)(ctx.pid_of("pipewire")), 60, 2),
             "PipeWire came back after being killed")
    wait_until(lambda: wp_sinks(wpctl(ctx, "status")), 60, 2)
    _, d1, v1 = audio_snapshot(ctx, "persist-1-pipewire-restarted",
                               "the same, after PipeWire was killed and came back")
    st.record(f"after PipeWire restarted: default output {d1}, its volume '{v1}'")
    g.sh("systemctl restart desktop.service", timeout=300)
    up = wait_until(lambda: "ok" in g.sh("podman exec desktop test -f /run/desktop-init-ready "
                                         "&& pgrep -u desktop -x mwm >/dev/null && echo ok; true",
                                         label="is the desktop back?"), 180, 3)
    st.check(up, "the desktop came back after systemctl restart desktop.service")
    wait_until(lambda: wp_sinks(wpctl(ctx, "status")), 60, 2)
    _, d2, v2 = audio_snapshot(ctx, "persist-2-desktop-restarted",
                               "the same, after systemctl restart desktop.service (the container, and "
                               "its home directory, recreated)")
    st.record(f"after the desktop restarted: default output {d2}, its volume '{v2}'")


def window_text(ctx, wid, label):
    """The text an xterm shows: dragged over from its first row to its last,
    which xterm copies into CUT_BUFFER0 as well as PRIMARY, read back with
    the observer's xprop (S11.2.1 reads the same buffer)."""
    info = ctx.one(wid)
    base, inc = info.base or (19, 4), info.inc or (6, 13)
    ctx.drag(info.ax + base[0] - 1, info.ay + 2 + inc[1] // 2, info.ax + info.w - 3, info.ay + info.h - 3)
    out = ctx.g.xprobe("xprop -root CUT_BUFFER0 2>&1; true", label=label)
    m = re.search(r'= "(.*)"\s*$', out, re.S)
    return codecs.decode(m.group(1), "unicode_escape") if m else ""


def s5_7_8(ctx, st):
    """The Host Terminal entry's failure path, as the operator meets it (S5.7.8's
    T3 half, S3.6.4's failure path). The host's trust entry for desktop-shell
    is moved aside, so the key the container holds is refused: the wrapper
    keeps the window open with the reason, the enablement command, the common
    causes and "Press Enter to close", and Enter closes it."""
    ak = "/etc/ssh/authorized_keys.d/desktop-shell"
    aside = "/etc/ssh/authorized_keys.d/.ev-desktop-shell"
    ctx.save_cmd("sshd-auth", "sshd -T 2>/dev/null | grep -iE '^(passwordauthentication|kbdinteractiveauthentication|"
                 "pubkeyauthentication|authenticationmethods|authorizedkeysfile) '",
                 "EV-STATE: the host sshd's effective authentication settings (sshd -T)", label="sshd -T")
    epoch = ctx.g.sh("date +%s", label="the host's clock").strip()
    ctx.g.sh(f"mv {ak} {aside}", label="move the host's trust entry for desktop-shell aside")
    st.record(f"the host's trust entry {ak} moved aside: the key the container holds is refused")
    win = None
    try:
        xs, _ = ctx.root_menu("Host Terminal", "host-terminal-fails")
        found = ctx.new_xterm(xs)
        st.check(found, "'Host Terminal' opened an xterm")
        xs, t = found
        win = t.id
        text = wait_until(lambda: (lambda x: x if "Press Enter to close" in x else None)(
            window_text(ctx, win, "observer: the Host Terminal window's text, through CUT_BUFFER0")), 20, 1)
        text = text or window_text(ctx, win, "observer: the Host Terminal window's text, once more")
        ctx.shot("host-terminal-fails", "the Host Terminal window after ssh host was refused: the reason, the "
                 "enablement command, the common causes and 'Press Enter to close', the window still open")
        ctx.save_state("window-text", text + "\n", "EV-STATE: the Host Terminal window's text, selected and "
                       "read back through CUT_BUFFER0")
        st.check("host-terminal: ssh to the host failed (exit 255)." in text,
                 "the window says ssh to the host failed, with ssh's exit code (255)", text[-300:])
        st.check("systemctl start desktop-host-shell.service" in text,
                 "it gives the enablement command: systemctl start desktop-host-shell.service")
        st.check("Other common causes:" in text, "it lists the other common causes")
        st.check(text.rstrip().endswith("Press Enter to close."), "it ends 'Press Enter to close.', waiting")
        time.sleep(3)
        xs = ctx.xstate()
        st.check(xs.by_id(win) is not None and xs.mapped(xs.frame_of(xs.by_id(win))),
                 "the window is still open seconds after ssh failed")
        ctx.click(*xs.parts(xs.by_id(win))["drag"])
        ctx.chord("ret")
        st.check(ctx.wait_gone(win), "Enter closes it")
        win = None
        ctx.save_cmd("sshd-journal", f"journalctl -u sshd --since @{epoch} -o short-precise --no-pager | "
                     "grep -i desktop-shell || echo '(no line naming desktop-shell)'",
                     "EV-LOG-JOURNAL: sshd on the refused login", label="sshd's journal")
    finally:
        ctx.g.sh(f"mv {aside} {ak}", label="put the trust entry back")
        if win is not None:
            ctx.g.desk(["pkill", "-u", "desktop", "-f", "xterm -T host"], check=False)


STORIES = [
    ("S3.3.3", "Root window colour and initial xterm", s3_3_3),
    ("S3.3.2", "Screensaver and DPMS are off, so the screen never blanks", s3_3_2),
    ("S3.5.2", "~/.Xdefaults is honoured because nothing sets RESOURCE_MANAGER", s3_5_2),
    ("S3.5.3", "mwm frame and menu colours are applied", s3_5_3),
    ("S7.5.1", "A client application's window appears and is usable (podman)", s7_5_1),
    ("S7.5.3", "A client window gets decoration, focus and keyboard", s7_5_3),
    ("S3.9.11", "A hot-added pointer delivers motion and buttons", s3_9_11),
    ("S7.7.2", "A client window is clickable with a hot-added pointer", s7_7_2),
    ("S7.7.1", "A client window keeps receiving keystrokes across a keyboard remove/re-add", s7_7_1),
    ("S3.9.12", "Repeated input cycles leave no residue", s3_9_12),
    ("S3.11.1", "Keyboard, pointer and sound card leave and return together", s3_11_1),
    ("S7.7.8", "A client survives the KVM composite event", s7_7_8),
    ("S11.1.2", "Windows can be arranged with the mouse", s11_1_2),
    ("S11.1.3", "Windows can be managed from the keyboard alone", s11_1_3),
    ("S11.2.1", "Text moves between applications by selection and paste, across containers", s11_2_1),
    ("S11.1.1", "Every root-menu action does what its label says when chosen with the mouse", s11_1_1),
    ("S11.3.1", "The operator can set the volume, mute, and choose the output from the desktop", s11_3_1),
    ("S5.7.8", "The menu wrapper keeps its window open on failure", s5_7_8),
    # Last: it declares a two-monitor layout and restarts the desktop twice.
    ("S3.11.2", "Composite cycle with the video link down at the same time", s3_11_2),
]


def run_stories(ctx, only=None):
    results = []
    for sid, title, fn in STORIES:
        if only and sid not in only:
            continue
        st = Story(ctx.run, sid, title)
        ctx.run.story = ctx.st = st
        ctx.run.log("story", f"start: {title}", echo=True)
        error = trace = None
        try:
            fn(ctx, st)
        except StoryFailed as e:
            error, trace = str(e), traceback.format_exc()
        except Exception as e:                                  # noqa: BLE001
            error, trace = f"{type(e).__name__}: {e}", traceback.format_exc()
        if error:
            ctx.diagnostics()
        status = "FAIL" if error else "PASS"
        ctx.run.log("story", status + (f": {error}" if error else ""), echo=True)
        st.finish(error, trace)
        ctx.run.story = ctx.st = None
        results.append((sid, title, status, error))
        ctx.recover()
    return results


# --- the maintainer's journeys (E10): what the operator sees ------------------------
# ci/vm/maint-e2e.sh runs the maintainer's commands on the host (the guest
# writes those, each story's primary side) and calls this driver between
# them, one step per call (--maint STEP), for what only the screen can show:
# the menu entry a change is about, chosen the way the operator chooses it,
# and what it gives. A step writes the VM host's side of its story (the h-
# files and checks maint-e2e.sh's own screendumps use), appending across
# calls, and never settles the story's result: evlib reads the h-side checks
# with the guest's (read_result).

class HostStory(Story):
    """A maintainer story's h-side, as this driver writes it."""

    def __init__(self, run, sid, title):
        self.run = run
        self.sid = sid
        d = os.path.join(run.art, sid)
        os.makedirs(d, exist_ok=True)
        self._tl = open(os.path.join(d, "h-timeline.log"), "a", buffering=1)
        self._qemu = open(os.path.join(d, "h-qemu.log"), "a", buffering=1)
        run.story = self
        evlib.StoryWriter.__init__(self, run.art, sid, title, side="h-")

    def finish(self, error=None, trace=None, checked=False):
        # A failed check is in h-checks.tsv already; any other failure (a
        # guest command, a window that never came) goes there now.
        if error and not checked:
            evlib.StoryWriter.check(self, False, f"the operator's half stopped: {error}")
        if trace and not checked:
            self.write("trace", trace, "the traceback of the operator's half's failure")
        self._qemu.flush()
        if (os.path.getsize(self._p("h-qemu.log"))
                and "h-qemu.log" not in {n for _, n, _ in evlib.read_files(self.dir)}):
            self.attach("h-qemu.log", "EV-QEMU: every QMP command the operator's half sent: its "
                        "input events and screendumps")
        self.run.story = None
        self._tl.close()
        self._qemu.close()
        return "FAIL" if error else "PASS"


def story_title(sid):
    """The title Requirements.md gives the story, as maint-e2e.sh's mt_title reads it."""
    path = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "Requirements.md")
    m = re.search(r"^\*\*" + re.escape(sid) + r" (.*)\*\*$", open(path, encoding="utf-8").read(), re.M)
    return m.group(1) if m else sid


def maint_state(st):
    """What a step left for a later one of the same story (a dotfile: not evidence)."""
    try:
        with open(st.path(".h-maint.json")) as f:
            return json.load(f)
    except FileNotFoundError:
        return {}


def maint_save(st, state):
    with open(st.path(".h-maint.json"), "w") as f:
        json.dump(state, f, indent=1)


def screen_lines(text):
    return " / ".join(line.strip() for line in text.splitlines() if line.strip())


def host_terminal(ctx, st, moment):
    """'Host Terminal' from the root menu, and what it gives: ("prompt",
    whoami's answer, "") when a shell opens on the host, ("failed", "", the
    window's text) when the wrapper's failure text shows, (None, "", "") when
    neither comes within 30 s. The window is closed again the way it says:
    `exit` at a prompt, Enter on the failure text."""
    def shells():
        return set(ctx.g.sh("pgrep -u desktop-shell -x bash; true",
                            label="desktop-shell's shells on the host").split())
    old = shells()
    xs, _ = ctx.root_menu("Host Terminal", moment)
    found = ctx.new_xterm(xs)
    st.check(found, f"'Host Terminal' opened an xterm ({moment})")
    xs, t = found
    seen = {}

    def settled():
        if shells() - old:
            return "prompt"
        text = window_text(ctx, t.id, f"observer: the Host Terminal window's text ({moment})")
        if "Press Enter to close" in text:
            seen["text"] = text
            return "failed"
        return None
    what = wait_until(settled, 30, 1)
    who, text = "", seen.get("text", "")
    xs = ctx.xstate()
    if what == "prompt":
        ctx.g.sh("rm -f /tmp/op-host-whoami")
        ctx.click(*xs.parts(xs.by_id(t.id))["drag"])
        # tee: the answer on the screen for the shot, and in a file to read.
        ctx.type_line("whoami | tee /tmp/op-host-whoami")
        who = wait_until(lambda: ctx.g.sh("cat /tmp/op-host-whoami 2>/dev/null; true",
                                          label="cat /tmp/op-host-whoami").strip(), 10, 0.5) or ""
        ctx.shot(f"{moment}-host-terminal", f"the Host Terminal window ({moment}): a shell on the "
                 f"host, whoami typed into it and its answer, {who!r}")
        ctx.type_line("exit")
    elif what == "failed":
        ctx.shot(f"{moment}-host-terminal", f"the Host Terminal window ({moment}): the wrapper's "
                 "failure text, the window still open")
        ctx.save_state(f"{moment}-window-text", text + "\n", f"EV-STATE: the Host Terminal window's "
                       f"text ({moment}), selected and read back through CUT_BUFFER0")
        ctx.click(*xs.parts(xs.by_id(t.id))["drag"])
        ctx.chord("ret")
    else:
        ctx.shot(f"{moment}-host-terminal", f"the Host Terminal window ({moment}) 30 s on: neither "
                 "a shell on the host nor the failure text")
    if not ctx.wait_gone(t.id):
        ctx.g.desk(["pkill", "-u", "desktop", "-f", "xterm -T host"], check=False)
        ctx.wait_gone(t.id)
    return what, who, text


def m_hostterm_works(ctx, st, arg):
    """S10.3.5, before the switch: a host where Host Terminal works."""
    what, who, _ = host_terminal(ctx, st, "before-switch")
    st.check(what == "prompt" and who == "desktop-shell",
             "before the switch, 'Host Terminal' opens a shell on the host as desktop-shell",
             f"{what}: whoami {who!r}")


def m_hostterm_refused(ctx, st, arg):
    """S10.3.5, after the switch and the reboot: the entry fails, visibly."""
    what, who, text = host_terminal(ctx, st, "after-switch")
    if what == "failed":
        st.record("after the switch, the window reads: " + screen_lines(text))
    st.check(what == "failed", "after the switch and the reboot, 'Host Terminal' shows its failure "
             "text and stays open until Enter (S5.7.8)",
             {"prompt": f"it opened a shell on the host as {who!r}",
              None: "neither a shell nor the failure text within 30 s"}.get(what, ""))


def m_hostterm_screen(ctx, st, arg):
    """S10.3.6: the failure screen, read the way the operator reads it, and
    the command it gives, handed to the maintainer (--out)."""
    what, who, text = host_terminal(ctx, st, "first-click")
    st.check(what == "failed", "'Host Terminal' shows its failure screen",
             f"it opened a shell on the host as {who!r}" if what == "prompt" else "")
    st.record("the failure screen reads: " + screen_lines(text))
    m = re.search(r"enable it on the host:\s*\n\s*(\S.*?)(?:\s{2,}\(.*\))?\s*$", text, re.M)
    cmd = m.group(1).strip() if m else ""
    st.check(cmd, "the screen gives a command to run on the host", text[-300:])
    st.record(f"the command the screen gives the maintainer: {cmd}")
    if ctx.out:
        with open(ctx.out, "w") as f:
            f.write(cmd + "\n")


def m_hostterm_prompt(ctx, st, arg):
    """S10.3.6, once the maintainer ran that command: the next click."""
    what, who, text = host_terminal(ctx, st, "second-click")
    if what == "failed":
        st.record("the second click's window reads: " + screen_lines(text))
    ok = (what == "prompt" and who == "desktop-shell") or (
        what == "failed" and "restart desktop.service" in text)
    st.check(ok, "after the command the screen gave, the next 'Host Terminal' opens a shell on the "
             "host as desktop-shell, or its screen names what else is needed",
             {"prompt": f"a shell on the host, whoami {who!r}",
              "failed": "the failure screen again, naming nothing more",
              None: "neither a shell nor the failure text within 30 s"}[what])


def menu_look(ctx, st, moment):
    """The root menu, posted the way the operator posts it and measured on
    the screendump: its size, the width of the 'Refresh' entry's text, and
    its background (the commonest colour inside it). Unposted again with
    Escape, nothing chosen."""
    xs = ctx.xstate()
    _, _, menu = ctx.post_root_menu(xs)
    img = ctx.shot(f"{moment}-menu", f"the root menu posted at the pointer ({moment})")
    ctx.m.button("left", False)
    rows = img.text_rows(menu.rect())
    look = {"menu": [menu.w, menu.h], "rows": len(rows), "refresh": None}
    if len(rows) == len(ROOT_MENU):
        top, bottom = rows[ROOT_MENU.index("Refresh")]
        ink = [x for y in range(top, bottom + 1) for x in range(menu.ax + 3, menu.ax + menu.w - 3)
               if sum(img.px(x, y)) > 450]
        if ink:
            look["refresh"] = [min(ink), max(ink), max(ink) - min(ink) + 1]
    counts = {}
    for y in range(menu.ay, menu.ay + menu.h, 2):
        for x in range(menu.ax, menu.ax + menu.w, 2):
            p = img.px(x, y)
            counts[p] = counts.get(p, 0) + 1
    look["bg"] = list(max(counts, key=counts.get))
    for _ in range(3):
        xs = ctx.xstate(check=False)
        if not any(xs.override.get(t.id) == "yes" and t.h > 60 and t.w < ctx.width
                   for t in xs.mapped_tops()):
            break
        ctx.chord("esc", settle=0.4)
    return look


def m_menu_look(ctx, st, moment):
    """S10.3.7: the root menu at <moment>, against the one before the edits."""
    state = maint_state(st)
    look = menu_look(ctx, st, moment)
    state[moment] = look
    maint_save(st, state)
    ctx.save_state(f"{moment}-menu-measures", json.dumps(look, indent=1) + "\n",
                   f"EV-STATE: the root menu's measures on the screendump ({moment}): its size, its "
                   "text rows, the 'Refresh' entry's text extent (x0, x1, width) and its commonest "
                   "colour, the background")
    st.record(f"the root menu ({moment}): {look['menu'][0]}x{look['menu'][1]}, {look['rows']} text "
              f"rows, 'Refresh' text {look['refresh'] and look['refresh'][2]} px wide, background "
              f"{tuple(look['bg'])}")
    before = state.get("before")
    if moment == "after-mwmrc":
        st.check(before and before["refresh"] and look["refresh"]
                 and look["refresh"][2] > before["refresh"][2] + 40 and look["menu"][0] > before["menu"][0],
                 "the edited label is on the menu after Restart mwm: the 'Refresh' entry's text and "
                 "the menu itself are wider",
                 f"text {before and before['refresh']} -> {look['refresh']}, menu width "
                 f"{before and before['menu'][0]} -> {look['menu'][0]}")
    if moment == "after-restart-2":
        # The colour ~/.Xdefaults gives the menu now, the edit's.
        was = state.get("after-xdefaults", {}).get("bg")
        want = ctx.g.desk(["sh", "-c", "sed -n 's/^Mwm\\*menu\\*background: *#//p' /home/desktop/.Xdefaults"],
                          check=False).strip()
        rgb = tuple(int(want[i:i + 2], 16) for i in (0, 2, 4)) if re.fullmatch(r"[0-9a-fA-F]{6}", want) else None
        st.check(rgb is not None and tuple(look["bg"]) == rgb,
                 f"after Restart mwm the root menu draws the edited Mwm*menu*background #{want}: f.restart "
                 "read ~/.Xdefaults again, in the same X session",
                 f"background {tuple(was) if was else '?'} before Restart mwm, {tuple(look['bg'])} after; "
                 f"~/.Xdefaults gives #{want}")


def m_restart_mwm(ctx, st, arg):
    """S10.3.7: 'Restart mwm' from the root menu: a new connection from
    mwm (menu_restart_mwm says why that, not its pid, is the proof), the
    same X server."""
    def mwm_sockets():
        return ctx.g.desk(["sh", "-c", 'for f in /proc/$(pgrep -u desktop -x mwm)/fd/*; do readlink "$f"; done '
                           '| grep socket: | sort'], check=False).split()
    table = ctx.pids(f"pids-before-restart-mwm-{arg}")
    xorg, mwm, socks = ctx.session_pid(table, "Xorg"), ctx.session_pid(table, "mwm"), mwm_sockets()
    before = ctx.xstate()
    with ctx.video(f"restart-mwm-{arg}", "Restart mwm chosen from the root menu: the frames go and "
                   "come back; the windows stay"):
        ctx.root_menu("Restart mwm", f"restart-mwm-{arg}")
        ctx.confirm(before, f"restart-mwm-{arg}")
        renewed = wait_until(lambda: (lambda s: s if s and s != socks else None)(mwm_sockets()), 20, 0.5)
        time.sleep(2)
    table = ctx.pids(f"pids-after-restart-mwm-{arg}")
    st.check(renewed, "Restart mwm replaced mwm's connection to the X server",
             f"mwm's sockets {socks} -> {mwm_sockets()}")
    st.record(f"Restart mwm ({arg}): mwm pid {mwm} -> {ctx.session_pid(table, 'mwm')}, Xorg pid "
              f"{xorg} -> {ctx.session_pid(table, 'Xorg')}")
    st.check(xorg and ctx.session_pid(table, "Xorg") == xorg,
             "Restart mwm started no new X session: the Xorg pid is the same")
    ctx.shot(f"after-restart-mwm-{arg}", "the desktop after Restart mwm")


def m_new_xterm(ctx, st, want):
    """S10.3.7: 'New Terminal' after the ~/.Xdefaults edit, and the
    background it draws, sampled clear of its text (want: #rrggbb)."""
    xs, _ = ctx.root_menu("New Terminal", "new-terminal")
    found = ctx.new_xterm(xs)
    st.check(found, "'New Terminal' opened an xterm")
    xs, t = found
    time.sleep(1)
    info = ctx.one(t.id)
    img = ctx.shot("new-terminal", "the xterm 'New Terminal' opened after the ~/.Xdefaults edit; "
                   "its background is sampled at its bottom-right corner, clear of the text")
    x, y = info.ax + info.w - 8, info.ay + info.h - 8
    got = img.px(x, y)
    rgb = tuple(int(want[i:i + 2], 16) for i in (1, 3, 5))
    if info.pid:
        ctx.g.desk(["kill", str(info.pid)], check=False)
        ctx.wait_gone(t.id)
    st.check(got == rgb, f"the next xterm draws the edited background {want}",
             f"pixel ({x},{y}) is {got}, want {rgb}")


MAINT_STEPS = {
    "hostterm-works": ("S10.3.5", m_hostterm_works),
    "hostterm-refused": ("S10.3.5", m_hostterm_refused),
    "hostterm-screen": ("S10.3.6", m_hostterm_screen),
    "hostterm-prompt": ("S10.3.6", m_hostterm_prompt),
    "menu-look": ("S10.3.7", m_menu_look),
    "restart-mwm": ("S10.3.7", m_restart_mwm),
    "new-xterm": ("S10.3.7", m_new_xterm),
}


def run_maint(ctx, step, arg):
    sid, fn = MAINT_STEPS[step]
    st = HostStory(ctx.run, sid, story_title(sid))
    ctx.run.story = ctx.st = st
    ctx.run.log("story", f"the operator's half: {step} {arg}".rstrip(), echo=True)
    error = trace = None
    checked = False
    try:
        fn(ctx, st, arg)
    except StoryFailed as e:
        error, trace, checked = str(e), traceback.format_exc(), True
    except Exception as e:                                      # noqa: BLE001
        error, trace = f"{type(e).__name__}: {e}", traceback.format_exc()
    if error:
        ctx.diagnostics()
    ctx.run.log("story", "FAIL: " + error if error else "PASS", echo=True)
    st.finish(error, trace, checked)
    ctx.run.story = ctx.st = None
    ctx.recover()
    return 1 if error else 0


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--qmp", default="qmp.sock")
    ap.add_argument("--ssh-port", default="2222")
    ap.add_argument("--ssh-key", default="id_ed25519")
    ap.add_argument("--art", default="artifacts")
    ap.add_argument("--only", default="", help="comma-separated story ids")
    ap.add_argument("--maint", default="", choices=[""] + sorted(MAINT_STEPS),
                    help="one step of a maintainer journey's operator half (ci/vm/maint-e2e.sh)")
    ap.add_argument("--arg", default="", help="the --maint step's argument")
    ap.add_argument("--out", default="", help="a file the --maint step writes its answer to")
    args = ap.parse_args()
    run = Run(args.art)
    machine = Machine(run, args.qmp)
    ctx = Ctx(run, machine, Guest(run, args.ssh_port, args.ssh_key))
    ctx.out = args.out
    if args.maint:
        try:
            ctx.measure_screen()
            ctx.recover()
            return run_maint(ctx, args.maint, args.arg)
        finally:
            machine.close()
            with contextlib.suppress(Exception):
                ctx.g.close()
    try:
        ctx.measure_screen()
        ctx.recover()
        results = run_stories(ctx, [s for s in args.only.split(",") if s])
    finally:
        machine.close()
        with contextlib.suppress(Exception):
            ctx.g.close()
    summary = ["| Story | Title | Result |", "|---|---|---|"]
    summary += [f"| {sid} | {title} | {status}{': ' + err if err else ''} |" for sid, title, status, err in results]
    with open(os.path.join(args.art, "operator-summary.md"), "w") as f:
        f.write("\n".join(summary) + "\n")
    print("\n".join(summary))
    return 0 if all(r[2] == "PASS" for r in results) else 1


if __name__ == "__main__":
    sys.exit(main())
