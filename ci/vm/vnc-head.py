#!/usr/bin/env python3
"""Plug a monitor into a virtio-gpu head, or take it away, the way a display
frontend does (S3.10.7).

  vnc-head.py SOCKET WIDTH HEIGHT

SOCKET is QEMU's VNC server bound to the head (`-vnc unix:SOCKET,display=vga0,
head=1`). The client asks for WIDTHxHEIGHT with RFB's SetDesktopSize, and
QEMU hands the size to the display device as the head's UI info, as it does
when a window showing that head is resized. virtio-gpu then enables the head
with an EDID of that size, or disables it for 0x0, and tells the guest with
a display event: the guest's driver reads every head's EDID and geometry
again and reports a hotplug. Under `-display none` nothing else can enable a
second head (HotpluggingTestHelp.md, 4.3.1).

Prints the server's version, desktop name and size, the request, and QEMU's
answer (the ExtendedDesktopSize status). Exits 1 unless QEMU says it
forwarded the request to the device (status 4).
"""
import socket
import struct
import sys

ENC_RAW, ENC_EXTENDED_DESKTOP_SIZE = 0, -308
STATUS = {0: "no error", 1: "prohibited", 2: "out of resources", 3: "invalid screen layout",
          4: "request forwarded"}


def recv_exact(s, n):
    buf = b""
    while len(buf) < n:
        chunk = s.recv(n - len(buf))
        if not chunk:
            raise RuntimeError(f"the VNC server closed the connection ({len(buf)} of {n} bytes read)")
        buf += chunk
    return buf


def handshake(s):
    """RFB 3.8 with no authentication, a shared ClientInit; returns the
    server's version, desktop size and name."""
    version = recv_exact(s, 12).decode(errors="replace").strip()
    s.sendall(b"RFB 003.008\n")
    count = recv_exact(s, 1)[0]
    if count == 0:
        n = struct.unpack(">I", recv_exact(s, 4))[0]
        raise RuntimeError("the server refused the connection: " + recv_exact(s, n).decode(errors="replace"))
    types = recv_exact(s, count)
    if 1 not in types:
        raise RuntimeError(f"the server offers no unauthenticated access (security types {list(types)})")
    s.sendall(b"\x01")
    result = struct.unpack(">I", recv_exact(s, 4))[0]
    if result != 0:
        raise RuntimeError(f"the security handshake failed (result {result})")
    s.sendall(b"\x01")
    width, height = struct.unpack(">HH", recv_exact(s, 4))
    recv_exact(s, 16)                                   # the pixel format
    n = struct.unpack(">I", recv_exact(s, 4))[0]
    return version, width, height, recv_exact(s, n).decode(errors="replace")


def resize_answer(s):
    """Read server messages until the ExtendedDesktopSize rectangle that
    answers the request; returns (reason, status, width, height)."""
    while True:
        kind = recv_exact(s, 1)[0]
        if kind == 2:                                   # Bell
            continue
        if kind == 3:                                   # ServerCutText
            recv_exact(s, 3)
            recv_exact(s, struct.unpack(">I", recv_exact(s, 4))[0])
            continue
        if kind != 0:
            raise RuntimeError(f"unexpected server message type {kind}")
        _, rects = struct.unpack(">BH", recv_exact(s, 3))
        for _ in range(rects):
            x, y, w, h, enc = struct.unpack(">HHHHi", recv_exact(s, 12))
            if enc == ENC_EXTENDED_DESKTOP_SIZE:
                screens = recv_exact(s, 4)[0]
                recv_exact(s, 16 * screens)
                if x == 1:                              # reason 1: this client's request
                    return x, y, w, h
            elif enc == ENC_RAW:
                recv_exact(s, w * h * 4)
            else:
                raise RuntimeError(f"unexpected rectangle encoding {enc}")


def main():
    if len(sys.argv) != 4:
        print(__doc__.strip(), file=sys.stderr)
        return 2
    path, width, height = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
    s = socket.socket(socket.AF_UNIX)
    s.settimeout(10)
    s.connect(path)
    version, w0, h0, name = handshake(s)
    print(f"server: {version}, desktop '{name}', {w0}x{h0}")
    encs = (ENC_RAW, ENC_EXTENDED_DESKTOP_SIZE)
    s.sendall(struct.pack(">BxH", 2, len(encs)) + b"".join(struct.pack(">i", e) for e in encs))
    # SetDesktopSize: one screen, id 0, at 0,0 covering the whole size.
    s.sendall(struct.pack(">BxHHBx", 251, width, height, 1) + struct.pack(">IHHHHI", 0, 0, 0, width, height, 0))
    print(f"sent: SetDesktopSize {width}x{height}")
    _, status, w1, h1 = resize_answer(s)
    print(f"answer: status {status} ({STATUS.get(status, 'unknown')}), {w1}x{h1}")
    s.close()
    return 0 if status == 4 else 1


if __name__ == "__main__":
    sys.exit(main())
