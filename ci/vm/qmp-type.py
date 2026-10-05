#!/usr/bin/env python3
"""Drive real HID input into the guest over QMP (input-send-event).

Usage: qmp-type.py SOCKET WIDTHxHEIGHT PX_X PX_Y TEXT

Positions the absolute pointer at pixel (PX_X, PX_Y) on a WIDTHxHEIGHT
screen, left-clicks (to focus the window under mwm's click-to-focus),
then types TEXT followed by Return. Every event is a real virtio HID
event, so this exercises the whole path: QEMU device -> evdev -> Xorg ->
focused client. TEXT must be lowercase letters/digits (they double as
QEMU qcodes).

Absolute axis values are 0..0x7fff mapped across the screen, so pixel
coords convert as px / dimension * 0x7fff.

With QMP_TRANSCRIPT=<file> in the environment, every QMP command sent is
appended to that file with a UTC timestamp (EV-QEMU).

With QMP_KEY_DEVICE=<display id> (and QMP_KEY_HEAD, default 0), every key
event names that display: QEMU then gives it to the keyboard bound to the
display's console (a usb-kbd added with display=<id>), not to the newest
unbound one. The pointer events name no display.
"""
import json
import os
import socket
import sys
import time

sock_path, res, px_x, px_y, text = sys.argv[1:6]
width, height = (int(v) for v in res.lower().split("x"))
px_x, px_y = int(px_x), int(px_y)
ABS_MAX = 0x7FFF
transcript = None


def main():
    # EV-QEMU: with QMP_TRANSCRIPT set, every command sent is appended there,
    # timestamped, so the evidence shows the keys came from QEMU's devices.
    path = os.environ.get("QMP_TRANSCRIPT")
    global transcript
    transcript = open(path, "a", buffering=1) if path else None
    s = socket.socket(socket.AF_UNIX)
    s.connect(sock_path)
    f = s.makefile("rw")

    def cmd(obj):
        if transcript:
            transcript.write(time.strftime("%Y-%m-%dT%H:%M:%S", time.gmtime())
                             + f".{int(time.time() * 1000) % 1000:03d}Z " + json.dumps(obj) + "\n")
        f.write(json.dumps(obj) + "\n")
        f.flush()
        while True:  # skip async events, wait for the reply
            line = f.readline()
            if not line:
                raise SystemExit("qmp: connection closed")
            msg = json.loads(line)
            if "error" in msg:
                raise SystemExit("qmp error: %s" % msg["error"])
            if "return" in msg:
                return msg

    def send(*events):
        cmd({"execute": "input-send-event", "arguments": {"events": list(events)}})

    key_device = os.environ.get("QMP_KEY_DEVICE")

    def send_key(*events):
        args = {"events": list(events)}
        if key_device:
            args["device"] = key_device
            args["head"] = int(os.environ.get("QMP_KEY_HEAD", "0"))
        cmd({"execute": "input-send-event", "arguments": args})

    def abs_event(axis, px, dim):
        return {"type": "abs", "data": {"axis": axis,
                "value": int(px / dim * ABS_MAX)}}

    def btn(down):
        return {"type": "btn", "data": {"button": "left", "down": down}}

    def key(qcode, down):
        return {"type": "key", "data": {
            "key": {"type": "qcode", "data": qcode}, "down": down}}

    f.readline()                       # QMP greeting
    cmd({"execute": "qmp_capabilities"})

    send(abs_event("x", px_x, width), abs_event("y", px_y, height))
    time.sleep(0.3)
    send(btn(True))
    send(btn(False))
    time.sleep(0.4)                    # let mwm settle focus
    for ch in text:
        send_key(key(ch, True))
        send_key(key(ch, False))
        time.sleep(0.05)
    send_key(key("ret", True))
    send_key(key("ret", False))


if __name__ == "__main__":
    main()
