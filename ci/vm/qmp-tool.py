#!/usr/bin/env python3
"""QEMU's view for the evidence (EV-QEMU, EV-VIDEO), over QMP.

  qmp-tool.py hmp SOCKET COMMAND
      Run one human-monitor command (`info usb`, `device_add ...`) through
      QMP's human-monitor-command and print its reply as QEMU wrote it: an
      empty reply is how device_add and device_del say yes. Exits 1 when
      QEMU's reply says the command failed ("Error: ..."), or QMP does.

  qmp-tool.py shot SOCKET FILE [DEVICE HEAD]
      One PNG screendump (EV-SHOT); with DEVICE and HEAD, of that head of
      that display device (`vga0 1` is the virtio-vga's second output).

  qmp-tool.py video SOCKET DIR [FPS]
      Screendump the display into DIR/frame-NNNN.png at FPS (default 2)
      until SIGTERM or SIGINT, with DIR/index.txt naming each frame, its
      UTC time (to read against timeline.log) and how long QEMU took to
      write it. Give it a monitor socket of its own: QMP serves one client
      at a time, and a frame every half second would make every other
      command wait.

      QEMU writes each frame as a PPM, its raw pixels, and the frames become
      PNGs once the recording stops. Before they do, DIR/changes.txt gets
      the share of each frame's rows that differ from the frame before it
      (ci/evlib.py's frame_changes), for the event frames (S9.3.5). QEMU compresses a PNG screendump in its
      main loop, the loop its emulated sound card and audio backend run in,
      and the sound card drops 8 KiB of audio (46 ms) when that loop falls
      behind: in run 37338352192 a PNG frame every half second cost S7.6.3's
      tone 18 such drops, each at a frame, while S4.5.1's tone, with no
      video, had none.

Through QMP rather than the HMP socket because replies come back as JSON
strings: no prompt, banner or terminal escapes to strip from evidence.
"""
import json
import os
import signal
import socket
import subprocess
import sys
import time

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
import evlib  # noqa: E402  (ci/evlib.py: each frame's change, for the event frames)


def stamp():
    t = time.time()
    return time.strftime("%Y-%m-%dT%H:%M:%S", time.gmtime(t)) + f".{int(t * 1000) % 1000:03d}Z"


class Qmp:
    def __init__(self, path):
        self.s = socket.socket(socket.AF_UNIX)
        self.s.connect(path)
        self.f = self.s.makefile("rw")
        self.f.readline()                      # the greeting
        self.cmd("qmp_capabilities")

    def raw(self, msg):
        self.f.write(json.dumps(msg) + "\n")
        self.f.flush()
        while True:                            # skip async events
            line = self.f.readline()
            if not line:
                raise SystemExit("qmp: connection closed")
            reply = json.loads(line)
            if "error" in reply or "return" in reply:
                return reply

    def cmd(self, name, **args):
        msg = {"execute": name}
        if args:
            msg["arguments"] = args
        reply = self.raw(msg)
        if "error" in reply:
            raise SystemExit(f"qmp error: {reply['error']}")
        return reply["return"]


def hmp(sock, command):
    out = Qmp(sock).cmd("human-monitor-command", **{"command-line": command})
    sys.stdout.write(out)
    # HMP reports a failed command in its text, not as a QMP error.
    return 1 if out.lstrip().startswith("Error") else 0


def shot(sock, filename, device=None, head=None):
    args = {"filename": os.path.abspath(filename), "format": "png"}
    if device:
        args["device"] = device
        args["head"] = int(head or 0)
    Qmp(sock).cmd("screendump", **args)
    return 0


def video(sock, out_dir, fps):
    os.makedirs(out_dir, exist_ok=True)
    q = Qmp(sock)
    stop = []
    signal.signal(signal.SIGTERM, lambda *_: stop.append(1))
    signal.signal(signal.SIGINT, lambda *_: stop.append(1))
    rc = 0
    with open(os.path.join(out_dir, "index.txt"), "a", buffering=1) as index:
        i = 0
        while not stop:
            t0 = time.monotonic()
            i += 1
            name = f"frame-{i:04d}"
            try:
                q.cmd("screendump", filename=os.path.abspath(os.path.join(out_dir, name + ".ppm")),
                      format="ppm")
                index.write(f"{name}.png {stamp()} (QEMU wrote it in {1000 * (time.monotonic() - t0):.0f} ms)\n")
            except SystemExit as e:
                index.write(f"{name}.png failed: {e}\n")
                rc = 1
                break
            time.sleep(max(0.0, 1.0 / fps - (time.monotonic() - t0)))
    # Each frame's change from the one before, from the raw pixels; then the
    # PNGs, now that QEMU is no longer waiting on them.
    ppms = sorted(os.path.join(out_dir, f) for f in os.listdir(out_dir) if f.endswith(".ppm"))
    evlib.write_changes(out_dir, ppms)
    for ppm in ppms:
        subprocess.run(["convert", ppm, ppm[:-4] + ".png"], check=False, timeout=60)
        os.unlink(ppm)
    return rc


def main():
    if len(sys.argv) >= 4 and sys.argv[1] == "hmp":
        return hmp(sys.argv[2], sys.argv[3])
    if len(sys.argv) >= 4 and sys.argv[1] == "shot":
        return shot(sys.argv[2], sys.argv[3], *sys.argv[4:6])
    if len(sys.argv) >= 4 and sys.argv[1] == "video":
        return video(sys.argv[2], sys.argv[3], float(sys.argv[4]) if len(sys.argv) > 4 else 2.0)
    sys.exit(__doc__)


if __name__ == "__main__":
    sys.exit(main())
