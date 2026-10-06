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
      until SIGTERM or SIGINT, with DIR/index.txt naming each frame and its
      UTC time, to read against timeline.log. Give it a monitor socket of
      its own: QMP serves one client at a time, and a frame every half
      second would make every other command wait.

Through QMP rather than the HMP socket because replies come back as JSON
strings: no prompt, banner or terminal escapes to strip from evidence.
"""
import json
import os
import signal
import socket
import sys
import time


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
    with open(os.path.join(out_dir, "index.txt"), "a", buffering=1) as index:
        i = 0
        while not stop:
            t0 = time.monotonic()
            i += 1
            name = f"frame-{i:04d}.png"
            try:
                q.cmd("screendump", filename=os.path.abspath(os.path.join(out_dir, name)),
                      format="png")
                index.write(f"{name} {stamp()}\n")
            except SystemExit as e:
                index.write(f"{name} failed: {e}\n")
                return 1
            time.sleep(max(0.0, 1.0 / fps - (time.monotonic() - t0)))
    return 0


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
