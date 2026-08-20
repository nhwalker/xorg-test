// Command testpattern paints a known, deliberately asymmetric pattern over the
// whole display and holds it there, so the e2e can assert what `screenshot`
// captured against pixels whose colour and position are known exactly.
//
// This is a CI FIXTURE, not a product binary. It exists because the e2e's
// original checks - image size plus a "not blank" test - are invariant under
// every interesting way a capture can be wrong: a vertically flipped,
// horizontally mirrored, 180-degree rotated, channel-swapped or offset image
// has exactly the same dimensions and the same grayscale standard deviation as
// a correct one. The pattern below is asymmetric in both axes and uses a
// different colour in each corner, so any of those defects moves a known
// colour to a coordinate the test can name.
//
// # Why an override-redirect window rather than the root
//
// Two reasons, both learned the hard way:
//
//   - mwm reparents and decorates managed windows, so a normal window's
//     contents are NOT at the geometry you asked for - exact-coordinate
//     assertions against one are fragile.
//   - by the time the screenshot phase runs, earlier phases have left xterms
//     on the display, and anything painted on the ROOT window would be partly
//     covered by them.
//
// An override-redirect window is ignored by the window manager, sits at exactly
// the requested coordinates, and covers everything below it.
//
// The pattern is painted into a Pixmap that becomes the window's background
// pixmap, so the X server repaints it on expose with no involvement from this
// process. That is why this program only has to stay alive, not run an event
// loop - but stay alive it must: X frees a client's windows and pixmaps when it
// disconnects, and the pattern would vanish with them.
package main

import (
	"flag"
	"fmt"
	"io"
	"log"
	"math/bits"
	"os"
	"time"

	"github.com/jezek/xgb"
	"github.com/jezek/xgb/xproto"
)

func init() {
	// Same reason as the screenshot binary: xgb announces its no-authority
	// fallback on stderr every run, and there is no Xauthority in a client
	// container because the session runs `xhost +local:`.
	xgb.Logger = log.New(io.Discard, "", 0)
}

// The pattern's geometry. ci/vm/vm-e2e.sh asserts against these same numbers -
// keep the two in sync; they are repeated there rather than passed across so
// the assertions state their expectations literally.
const (
	blockSize = 64  // corner block edge
	fiducialX = 300 // 1px vertical line, for shear/offset detection
	fiducialY = 200 // 1px horizontal line
	oddX      = 37  // a block at deliberately un-round coordinates, so an
	oddY      = 91  // alignment assumption shows up as a wrong pixel
	oddW      = 13
	oddH      = 7
)

// The pattern's colours, as 24-bit RGB. The background has three DIFFERENT
// channel values on purpose: a red/blue swap turns 0x204060 into 0x604020, so
// even a flat area of the image reveals a channel-order bug.
const (
	colBackground = 0x204060
	colTopLeft    = 0xff0000
	colTopRight   = 0x00ff00
	colBottomLeft = 0x0000ff
	colBottomRght = 0xffffff
	colFiducialV  = 0xffff00
	colFiducialH  = 0xff00ff
	colOdd        = 0x00ffff
)

// rgbToPixel converts a 24-bit RGB colour to the server's pixel value for a
// visual, using the visual's own channel masks.
//
// This deliberately does NOT share code with the decoder in the screenshot
// binary. If both used one helper, a wrong reading of the visual masks would
// paint and read back consistently and every colour assertion would pass
// against a broken decoder. Two independent implementations of the same
// convention is the point - the same reason the fake X server in
// capture_test.go computes its own scanline stride.
func rgbToPixel(rgb uint32, red, green, blue uint32) (uint32, error) {
	var out uint32
	for _, ch := range []struct {
		mask  uint32
		value uint32
	}{
		{red, rgb >> 16 & 0xff},
		{green, rgb >> 8 & 0xff},
		{blue, rgb & 0xff},
	} {
		if ch.mask == 0 {
			return 0, fmt.Errorf("visual has an empty colour mask")
		}
		shift := uint(bits.TrailingZeros32(ch.mask))
		max := uint32(1)<<bits.OnesCount32(ch.mask) - 1
		out |= (ch.value * max / 255) << shift
	}
	return out, nil
}

func main() {
	hold := flag.Duration("hold", 5*time.Minute, "how long to keep the pattern on screen")
	flag.Parse()

	if err := run(*hold); err != nil {
		fmt.Fprintf(os.Stderr, "testpattern: %v\n", err)
		os.Exit(1)
	}
}

func run(hold time.Duration) error {
	c, err := xgb.NewConn()
	if err != nil {
		return fmt.Errorf("connecting to display: %w", err)
	}
	defer c.Close()

	setup := xproto.Setup(c)
	screen := setup.DefaultScreen(c)
	width, height := int(screen.WidthInPixels), int(screen.HeightInPixels)

	// The corner blocks must not overlap and the fiducials must fall clear of
	// them, or the assertions would be checking coincidences.
	if width < 2*blockSize+fiducialX+2 || height < 2*blockSize+fiducialY+2 {
		return fmt.Errorf("display %dx%d is too small for this pattern", width, height)
	}

	visual := findVisual(screen, screen.RootVisual)
	if visual == nil {
		return fmt.Errorf("no description for root visual %#x", screen.RootVisual)
	}

	pixmap, err := xproto.NewPixmapId(c)
	if err != nil {
		return err
	}
	if err := xproto.CreatePixmapChecked(c, screen.RootDepth, pixmap,
		xproto.Drawable(screen.Root), uint16(width), uint16(height)).Check(); err != nil {
		return fmt.Errorf("creating the pattern pixmap: %w", err)
	}

	gc, err := xproto.NewGcontextId(c)
	if err != nil {
		return err
	}
	if err := xproto.CreateGCChecked(c, gc, xproto.Drawable(pixmap), 0, nil).Check(); err != nil {
		return fmt.Errorf("creating a graphics context: %w", err)
	}

	fill := func(rgb uint32, rects ...xproto.Rectangle) error {
		pixel, err := rgbToPixel(rgb, visual.RedMask, visual.GreenMask, visual.BlueMask)
		if err != nil {
			return err
		}
		if err := xproto.ChangeGCChecked(c, gc, xproto.GcForeground,
			[]uint32{pixel}).Check(); err != nil {
			return err
		}
		return xproto.PolyFillRectangleChecked(c, xproto.Drawable(pixmap), gc, rects).Check()
	}

	w16, h16 := uint16(width), uint16(height)
	far := int16(width - blockSize)
	low := int16(height - blockSize)

	// Order matters where shapes overlap: the fiducials are drawn after the
	// background and before nothing else that crosses them, and the horizontal
	// fiducial wins at the single pixel where the two lines meet. The tests
	// never assert that intersection.
	steps := []struct {
		rgb   uint32
		rects []xproto.Rectangle
	}{
		{colBackground, []xproto.Rectangle{{X: 0, Y: 0, Width: w16, Height: h16}}},
		{colTopLeft, []xproto.Rectangle{{X: 0, Y: 0, Width: blockSize, Height: blockSize}}},
		{colTopRight, []xproto.Rectangle{{X: far, Y: 0, Width: blockSize, Height: blockSize}}},
		{colBottomLeft, []xproto.Rectangle{{X: 0, Y: low, Width: blockSize, Height: blockSize}}},
		{colBottomRght, []xproto.Rectangle{{X: far, Y: low, Width: blockSize, Height: blockSize}}},
		{colOdd, []xproto.Rectangle{{X: oddX, Y: oddY, Width: oddW, Height: oddH}}},
		{colFiducialV, []xproto.Rectangle{{X: fiducialX, Y: 0, Width: 1, Height: h16}}},
		{colFiducialH, []xproto.Rectangle{{X: 0, Y: fiducialY, Width: w16, Height: 1}}},
	}
	for _, s := range steps {
		if err := fill(s.rgb, s.rects...); err != nil {
			return fmt.Errorf("painting the pattern: %w", err)
		}
	}

	win, err := xproto.NewWindowId(c)
	if err != nil {
		return err
	}
	// Value list order must follow the mask's bit order: BackPixmap (1) then
	// OverrideRedirect (512).
	if err := xproto.CreateWindowChecked(c, screen.RootDepth, win, screen.Root,
		0, 0, w16, h16, 0, xproto.WindowClassInputOutput, screen.RootVisual,
		xproto.CwBackPixmap|xproto.CwOverrideRedirect,
		[]uint32{uint32(pixmap), 1}).Check(); err != nil {
		return fmt.Errorf("creating the pattern window: %w", err)
	}
	if err := xproto.MapWindowChecked(c, win).Check(); err != nil {
		return fmt.Errorf("mapping the pattern window: %w", err)
	}
	if err := xproto.ConfigureWindowChecked(c, win, xproto.ConfigWindowStackMode,
		[]uint32{xproto.StackModeAbove}).Check(); err != nil {
		return fmt.Errorf("raising the pattern window: %w", err)
	}

	// A round trip after mapping: when this returns the server has processed
	// everything above, so a caller that waits for this line has a guarantee
	// the pattern is on screen rather than a guess dressed up as a sleep.
	if _, err := xproto.GetInputFocus(c).Reply(); err != nil {
		return fmt.Errorf("synchronising with the server: %w", err)
	}

	fmt.Printf("testpattern: %dx%d painted and held for %s\n", width, height, hold)
	os.Stdout.Sync()
	time.Sleep(hold)
	return nil
}

func findVisual(screen *xproto.ScreenInfo, id xproto.Visualid) *xproto.VisualInfo {
	for _, depth := range screen.AllowedDepths {
		for i := range depth.Visuals {
			if depth.Visuals[i].VisualId == id {
				return &depth.Visuals[i]
			}
		}
	}
	return nil
}
