# screenshot

A self-contained binary that saves the desktop's display — or a region of it —
as a PNG.

```sh
screenshot out.png                            # the whole desktop
screenshot -x 10 -y 20 -w 200 -h 100 out.png  # a sub-region
screenshot --to-stdout > out.png              # PNG on stdout
```

It speaks the X11 wire protocol straight down the socket named by `$DISPLAY`.
There is no `libX11`, no `xwd`, no ImageMagick and no libc: a static
`CGO_ENABLED=0` binary that runs unchanged in ubi9, alpine or distroless, none
of which ship an X client stack. That is the whole point — it is meant to be
injected into arbitrary client containers.

## How it reaches a client

It ships **inside the desktop image**. At startup the desktop publishes it to
`/var/lib/desktop-container/bin` on the host (`image/tools/publish-tools.sh`,
run by `desktop-tools-publish.service`), and the `desktop.local/tools` CDI
device mounts that directory read-only into clients as
`/opt/desktop-tools/bin`, injecting `DESKTOP_TOOLS_BIN` to point at it:

```sh
podman run --rm --device desktop.local/display=all --device desktop.local/tools=all \
    <image> sh -c '"$DESKTOP_TOOLS_BIN"/screenshot /tmp/out.png'
```

Living in the desktop image is the point: the binary's version becomes an
attribute of the desktop, so the display server and the tool that talks to it
update together and cannot disagree about the protocol. That is what makes the
Wayland move a single-artifact change.

Three details of the delivery are load-bearing:

- **Published by rename, never `cp`.** Writing over a binary a client is
  currently executing fails `ETXTBSY`; rename swaps in a new inode and leaves
  the old one alive for anything still running it.
- **`0755`, not `1777`** like the exported socket dirs next to it. That
  directory holds executables mounted into every client, so anything able to
  write it would control code running in all of them.
- **The device is advertised only once the directory is populated**, so a node
  where the desktop never started fails at scheduling rather than handing a
  client an empty toolkit. See `deploy/host/usr/local/libexec/desktop-tools-cdi`.

Holding `desktop.local/tools` grants no capability by itself — the binary is
inert without the X socket, which comes from `desktop.local/display`.

**SELinux:** executing a file from the injected directory is a harder case
than opening a socket, and it used to be the gap here — every client path in
CI was exempt. It is covered now. The deploy tree labels this directory
`container_file_t` (`desktop-selinux.service`), and the VM e2e runs enforcing
end to end: a *confined* client pod executes the binary from the injected
mount, and the **host** executes the same published binary as an ordinary
unconfined process. Both are asserted, so a labeling regression fails CI
rather than a deployment.

## Why a binary, and not just documentation

X11 lets any client on the display read the framebuffer, so a client container
holding `desktop.local/display` could screenshot for itself. **Wayland will
not.** There is no `XGetImage` equivalent a client can call; capture has to go
through the compositor.

So the command line, not the implementation, is the contract. When this desktop
moves to Wayland the backend here becomes a custom compositor protocol and
`screenshot out.png` keeps meaning what it means today — client images do not
change, and in the broker-style designs they do not even need re-pulling.

That constrains what may go in these flags: **only options both backends can
honour.** Region capture qualifies (X11 takes it as a `GetImage` argument;
`wlr-screencopy`-style protocols have a region variant). Window-by-title does
not — it needs `QueryTree` plus `_NET_WM_NAME` walking on X11 and something
entirely different on Wayland, and the moment a flag can only be honoured by
one backend the abstraction starts leaking.

## Flags

| flag | meaning | default |
|---|---|---|
| `-x, --x` | left edge of the region | 0 |
| `-y, --y` | top edge of the region | 0 |
| `-w, --width` | width of the region | to the right screen edge |
| `-h, --height` | height of the region | to the bottom screen edge |
| `--to-stdout` | write the PNG to stdout instead of a file | off |
| `--help` | usage | — |

> **`-h` is HEIGHT, not help.** The geometry set `-x -y -w -h` is the same one
> `maim` uses, and it wins the letter; help is `--help` only. A bare
> `screenshot -h` therefore reports a missing argument for `--height` and
> prints the usage block, which carries a note saying so.

**Exit status:** `0` success · `1` runtime failure (no display reachable,
capture or write failed) · `2` usage error, including a region that does not
fit the screen.

A region that runs off the screen is **refused, not clamped**, and the error
names the real screen size. A silently shrunk screenshot is the wrong size
without looking wrong, which is exactly what breaks an automated image
comparison.

## Authentication

The session runs `xhost +local:` (`image/session/xinitrc.desktop`), so
host-based access control admits any local connection and no cookie is needed
— which is just as well, since `desktop.local/display` injects `DISPLAY` and
the socket directory but no `XAUTHORITY` file.

This binary is therefore one of the things that would have to change before
`xhost +local:` could be tightened: it would need `MIT-MAGIC-COOKIE-1` support,
and the display CDI device would need to start injecting a cookie. See the note
in `capture.go`.

## Implementation notes

Three details are load-bearing and easy to get wrong:

- **The filesystem socket, never the abstract one.** Xorg listens on both
  `/tmp/.X11-unix/X0` and abstract `@/tmp/.X11-unix/X0`. Abstract sockets are
  scoped to a network namespace and a client container does not share the
  desktop's, so only the filesystem path can work — which is why the CDI device
  bind-mounts that directory. `jezek/xgb` dials it correctly.
- **Scanline stride comes from the server's `PixmapFormats`,** not from
  `width × bytesPerPixel`. X pads every row out to a multiple of
  `scanline-pad` *bits*. Full-screen captures hide the difference because
  screen widths are conveniently aligned; an arbitrary `-w` region is where an
  assumed stride starts shearing the image.
- **Colour components come from the visual's masks,** not from an assumption of
  8 bits each. NVIDIA can drive a depth-30 screen, whose 10-bit components a
  hardcoded decoder reads as garbage rather than failing.

Regions are a `GetImage` argument, not a crop of a full grab: a 400×300 region
moves a few hundred KB where the whole screen is tens of MB at 4K, and the PNG
encode shrinks with it.

## Building

Two stages, matching `cdi-device-plugin`: a base image that fetches the module
cache (the only step needing network) and an application layer that compiles
fully offline.

```sh
podman build -t localhost/screenshot-base:latest -f Containerfile.screenshot.base .
podman build --network=none -t localhost/screenshot:latest -f Containerfile.screenshot .
```

The resulting `scratch` image exists to *carry* the binary, not to run it —
nothing about this tool is containerized in production. The desktop image
stages the binary out of it (a named `tools` build stage), so this image must
be built **before** `Containerfile`; the CI workflows order
them that way.

## Testing

`go test ./screenshot/...` drives the real client code against a **fake X
server** over a socket pair: canned setup reply, canned `GetImage` reply, real
handshake and decode. It covers the wire format, including scanline padding and
both byte orders, with no X server anywhere, so it runs in the same CI job as
`go vet`. (The fake computes its own stride deliberately — sharing the
production helper would let a wrong stride lay out and read back identically.)

Reality is covered in the VM e2e (`ci/vm/vm-guest.sh verify-screenshot`), where
the binary captures a real Xorg on a real KMS display from inside a client pod
that has no X client stack of its own. The pod does not bake the binary in — it
arrives by the real delivery path, so the phase also proves the desktop
published it, the `.path` unit advertised it, and CDI injected it read-only.

That phase checks the **pixels**, not just that a PNG appeared. Image size and a
"not blank" test are invariant under every interesting way a capture can be
wrong — flipped, mirrored, rotated, red/blue swapped or shifted images all have
the same dimensions and the same grayscale standard deviation as a correct one.
So `screenshot/testpattern` paints a known, deliberately asymmetric pattern
(a different colour in each corner, a background whose three channels differ,
1px fiducial lines, a block at un-round coordinates) into an override-redirect
window covering the display, and `ci/vm/vm-e2e.sh` asserts:

1. **Colour at coordinate** — each corner, either side of a block edge, and the
   vertical fiducial on both the first and last row (a wrong scanline stride
   drifts it down the image rather than failing outright).
2. **Region origin** — each region capture must be byte-identical to the same
   rectangle cropped out of the full capture. This pins the origin without any
   pattern at all: under a position-dependent transform, cropping the
   transformed full image does not equal the transform of the server-side
   sub-rectangle.
3. **Orientation against an independent capture** — QEMU's own screendump of
   the same display, scored by margin against its flipped, mirrored and rotated
   variants, so the upright match has to win by a wide margin. QEMU composites
   the pointer cursor and `GetImage` does not, which is why this is a margin
   test and not an equality one.

Each of those assertions was verified to *fail* against a deliberately mutated
capture; a check that cannot fail is not a check.

## Not implemented

Cursor capture, per-output/RandR selection, window-by-title, interactive region
selection, and `--clamp`. Interactive selection in particular belongs in a
separate tool: drawing a selection overlay needs a surface and a pointer grab,
which would pull input privileges into a binary whose appeal is that it needs
none. `-h`/`--height`'s geometry syntax pairs naturally with a coordinate
producer like `slurp`.
