package main

import (
	"fmt"
	"image"
	"io"
	"log"
	"net"

	"github.com/jezek/xgb"
	"github.com/jezek/xgb/xproto"
)

func init() {
	// xgb announces its no-authority fallback on stderr ("Could not get
	// authority info", "Trying connection without authority info...") every
	// time it cannot read an Xauthority file. Inside a client container that
	// is every single run: the desktop.local/display CDI device injects
	// DISPLAY and the socket, never a cookie, because the session runs
	// `xhost +local:` (image/session/xinitrc.desktop) and host-based access
	// control needs no cookie. The fallback is the intended path here, so the
	// warning is pure noise on every invocation - and noise on stderr is what
	// callers scraping this tool would have to filter.
	//
	// If `xhost +local:` is ever tightened, this is the code that has to grow
	// MIT-MAGIC-COOKIE-1 support (and the display CDI device has to start
	// injecting an XAUTHORITY file); until then there is nothing to report.
	xgb.Logger = log.New(io.Discard, "", 0)
}

// display is a live connection to an X server plus the geometry and pixel
// format facts read out of its setup reply.
type display struct {
	conn   *xgb.Conn
	setup  *xproto.SetupInfo
	screen *xproto.ScreenInfo
	root   xproto.Window
	width  int
	height int
}

// connect dials the X server named by a DISPLAY-style string.
//
// xgb dials the FILESYSTEM socket /tmp/.X11-unix/X<n> (conn.go), which is the
// only thing that can work here: the abstract-namespace socket Xorg also
// listens on is scoped to a network namespace, and a client container does not
// share the desktop's. The display CDI device bind-mounts the directory for
// exactly this reason.
func connect(name string) (*display, error) {
	c, err := xgb.NewConnDisplay(name)
	if err != nil {
		return nil, fmt.Errorf("connecting to display %s: %w", name, err)
	}
	return newDisplay(c)
}

// connectNet is connect over a caller-supplied transport, which is what lets
// the tests drive the real client code against a fake server.
func connectNet(nc net.Conn) (*display, error) {
	c, err := xgb.NewConnNet(nc)
	if err != nil {
		return nil, fmt.Errorf("connecting to display: %w", err)
	}
	return newDisplay(c)
}

func newDisplay(c *xgb.Conn) (*display, error) {
	setup := xproto.Setup(c)
	if setup == nil || len(setup.Roots) == 0 {
		c.Close()
		return nil, fmt.Errorf("server returned no screens")
	}
	screen := setup.DefaultScreen(c)
	return &display{
		conn:   c,
		setup:  setup,
		screen: screen,
		root:   screen.Root,
		width:  int(screen.WidthInPixels),
		height: int(screen.HeightInPixels),
	}, nil
}

func (d *display) close() { d.conn.Close() }

// grab captures a rectangle of the root window.
//
// The region is a GetImage argument, not a crop of a full-screen grab: asking
// for less moves less. A small region is a few hundred KB where the whole
// screen is tens of MB at 4K, and the PNG encode shrinks with it.
//
// The caller must have validated the rectangle against the screen bounds
// first: GetImage answers an out-of-bounds request with a BadMatch protocol
// error, which says nothing useful about what went wrong.
func (d *display) grab(r image.Rectangle) (*image.RGBA, error) {
	reply, err := xproto.GetImage(d.conn, xproto.ImageFormatZPixmap,
		xproto.Drawable(d.root),
		int16(r.Min.X), int16(r.Min.Y), uint16(r.Dx()), uint16(r.Dy()),
		0xffffffff).Reply()
	if err != nil {
		return nil, fmt.Errorf("capturing %dx%d+%d+%d: %w", r.Dx(), r.Dy(), r.Min.X, r.Min.Y, err)
	}
	layout, err := d.layoutFor(reply.Depth, reply.Visual)
	if err != nil {
		return nil, err
	}
	return decodeZPixmap(reply.Data, r.Dx(), r.Dy(), layout)
}

// layoutFor derives the pixel layout for a captured image from the server's
// declared formats and the visual the reply names.
func (d *display) layoutFor(depth byte, visual xproto.Visualid) (pixelLayout, error) {
	var format *xproto.Format
	for i := range d.setup.PixmapFormats {
		if d.setup.PixmapFormats[i].Depth == depth {
			format = &d.setup.PixmapFormats[i]
			break
		}
	}
	if format == nil {
		return pixelLayout{}, fmt.Errorf("server declares no pixmap format for depth %d", depth)
	}

	// A window reply names its own visual; fall back to the screen's root
	// visual if the server left it unset.
	if visual == 0 {
		visual = d.screen.RootVisual
	}
	info := d.findVisual(visual)
	if info == nil {
		return pixelLayout{}, fmt.Errorf("server described no visual %#x", visual)
	}
	if info.Class != xproto.VisualClassTrueColor && info.Class != xproto.VisualClassDirectColor {
		return pixelLayout{}, fmt.Errorf(
			"visual %#x is class %d, not TrueColor/DirectColor (indexed colour is unsupported)",
			visual, info.Class)
	}

	l := pixelLayout{
		bitsPerPixel: format.BitsPerPixel,
		scanlinePad:  format.ScanlinePad,
		lsbFirst:     d.setup.ImageByteOrder == xproto.ImageOrderLSBFirst,
	}
	var err error
	if l.red, err = newChannel(info.RedMask); err != nil {
		return pixelLayout{}, fmt.Errorf("red mask: %w", err)
	}
	if l.green, err = newChannel(info.GreenMask); err != nil {
		return pixelLayout{}, fmt.Errorf("green mask: %w", err)
	}
	if l.blue, err = newChannel(info.BlueMask); err != nil {
		return pixelLayout{}, fmt.Errorf("blue mask: %w", err)
	}
	return l, nil
}

func (d *display) findVisual(id xproto.Visualid) *xproto.VisualInfo {
	for _, depth := range d.screen.AllowedDepths {
		for i := range depth.Visuals {
			if depth.Visuals[i].VisualId == id {
				return &depth.Visuals[i]
			}
		}
	}
	return nil
}
