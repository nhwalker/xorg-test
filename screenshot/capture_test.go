package main

import (
	"encoding/binary"
	"image"
	"io"
	"net"
	"testing"

	"github.com/jezek/xgb"
	"github.com/jezek/xgb/xproto"
)

// The tests below drive the real client code - the same connect/grab/decode
// path main() uses - against a fake X server over a socket pair. That covers
// the handshake, the GetImage round trip and the whole decode including
// scanline padding, with no X server anywhere, so it runs in the same CI job
// as `go vet`. It follows the fake-kubelet pattern in
// cdi-device-plugin/main_test.go.

const (
	testRootWindow = 0x2a0
	testVisualID   = 0x21
	testScreenW    = 1280
	testScreenH    = 800
)

// fakeServerConfig is the shape of the server the fake presents.
type fakeServerConfig struct {
	bitsPerPixel byte
	scanlinePad  byte
	depth        byte
	byteOrder    byte // xproto.ImageOrderLSBFirst or MSBFirst
	redMask      uint32
	greenMask    uint32
	blueMask     uint32
	// image is what GetImage answers with; nil means "generate a gradient".
	image []byte
}

// truecolor24 is the format an ordinary Xorg screen presents: depth 24 packed
// into 32 bits per pixel, little-endian, BGRX in memory.
func truecolor24() fakeServerConfig {
	return fakeServerConfig{
		bitsPerPixel: 32,
		scanlinePad:  32,
		depth:        24,
		byteOrder:    xproto.ImageOrderLSBFirst,
		redMask:      0xff0000,
		greenMask:    0x00ff00,
		blueMask:     0x0000ff,
	}
}

func (cfg fakeServerConfig) setupInfo() xproto.SetupInfo {
	visual := xproto.VisualInfo{
		VisualId:        testVisualID,
		Class:           xproto.VisualClassTrueColor,
		BitsPerRgbValue: 8,
		ColormapEntries: 256,
		RedMask:         cfg.redMask,
		GreenMask:       cfg.greenMask,
		BlueMask:        cfg.blueMask,
	}
	screen := xproto.ScreenInfo{
		Root:               testRootWindow,
		WidthInPixels:      testScreenW,
		HeightInPixels:     testScreenH,
		RootVisual:         testVisualID,
		RootDepth:          cfg.depth,
		AllowedDepthsLen:   1,
		CurrentInputMasks:  0,
		WidthInMillimeters: 300,
		AllowedDepths: []xproto.DepthInfo{{
			Depth:      cfg.depth,
			VisualsLen: 1,
			Visuals:    []xproto.VisualInfo{visual},
		}},
	}
	return xproto.SetupInfo{
		Status:                   1,
		ProtocolMajorVersion:     11,
		ProtocolMinorVersion:     0,
		ReleaseNumber:            12101013,
		ResourceIdBase:           0x400000,
		ResourceIdMask:           0x1fffff,
		VendorLen:                uint16(len("fake")),
		Vendor:                   "fake",
		MaximumRequestLength:     65535,
		RootsLen:                 1,
		PixmapFormatsLen:         1,
		ImageByteOrder:           cfg.byteOrder,
		BitmapFormatScanlineUnit: 32,
		BitmapFormatScanlinePad:  cfg.scanlinePad,
		MinKeycode:               8,
		MaxKeycode:               255,
		PixmapFormats: []xproto.Format{{
			Depth:        cfg.depth,
			BitsPerPixel: cfg.bitsPerPixel,
			ScanlinePad:  cfg.scanlinePad,
		}},
		Roots: []xproto.ScreenInfo{screen},
	}
}

// serve runs the fake server on conn until the client disconnects, reporting
// the GetImage requests it saw on reqs.
//
// It never touches *testing.T: the connection outlives the test body (the
// client is closed from t.Cleanup), so an assertion from in here would fire
// after the test completed and panic the run instead of failing it. Every
// failure path just drops the connection, which the client reports.
func (cfg fakeServerConfig) serve(conn net.Conn, reqs chan<- getImageRequest) {
	defer conn.Close()
	defer close(reqs)

	// --- connection setup ------------------------------------------------
	// The client's setup request: 12 fixed bytes, then padded auth name and
	// data whose lengths the header carries.
	head := make([]byte, 12)
	if _, err := io.ReadFull(conn, head); err != nil {
		return
	}
	nameLen := int(binary.LittleEndian.Uint16(head[6:]))
	dataLen := int(binary.LittleEndian.Uint16(head[8:]))
	if pad := xgb.Pad(nameLen) + xgb.Pad(dataLen); pad > 0 {
		if _, err := io.ReadFull(conn, make([]byte, pad)); err != nil {
			return
		}
	}

	info := cfg.setupInfo()
	reply := info.Bytes()
	// Length counts the 4-byte units following the 8-byte header. SetupInfo
	// does not fill it in, and xgb uses it to size its read.
	binary.LittleEndian.PutUint16(reply[6:], uint16((len(reply)-8)/4))
	if _, err := conn.Write(reply); err != nil {
		return
	}

	// --- request loop ----------------------------------------------------
	seq := uint16(0)
	for {
		hdr := make([]byte, 4)
		if _, err := io.ReadFull(conn, hdr); err != nil {
			return // client closed; normal end of test
		}
		seq++
		body := make([]byte, int(binary.LittleEndian.Uint16(hdr[2:]))*4-4)
		if _, err := io.ReadFull(conn, body); err != nil {
			return
		}

		switch hdr[0] {
		case opGetInputFocus:
			// xgb's Close() sends one of these as a no-op and BLOCKS on its
			// reply, so a fake that only answers GetImage deadlocks on
			// teardown. The contents do not matter; the reply must exist.
			if _, err := conn.Write(emptyReply(seq)); err != nil {
				return
			}
		case opGetImage:
			req := getImageRequest{
				x:      int(int16(binary.LittleEndian.Uint16(body[4:]))),
				y:      int(int16(binary.LittleEndian.Uint16(body[6:]))),
				width:  int(binary.LittleEndian.Uint16(body[8:])),
				height: int(binary.LittleEndian.Uint16(body[10:])),
			}
			reqs <- req

			data := cfg.image
			if data == nil {
				data = cfg.gradient(req.width, req.height)
			}
			if err := writeGetImageReply(conn, seq, cfg.depth, testVisualID, data); err != nil {
				return
			}
		default:
			return // unexpected request: drop the connection, client will say so
		}
	}
}

const (
	opGetInputFocus = 43
	opGetImage      = 73
)

type getImageRequest struct{ x, y, width, height int }

// emptyReply is the minimal 32-byte X reply, enough for GetInputFocus.
func emptyReply(seq uint16) []byte {
	buf := make([]byte, 32)
	buf[0] = 1 // reply
	binary.LittleEndian.PutUint16(buf[2:], seq)
	return buf
}

func writeGetImageReply(w io.Writer, seq uint16, depth byte, visual uint32, data []byte) error {
	// Replies are padded to a 4-byte boundary; Length counts those units.
	padded := data
	if r := len(data) % 4; r != 0 {
		padded = append(append([]byte{}, data...), make([]byte, 4-r)...)
	}
	buf := make([]byte, 32+len(padded))
	buf[0] = 1 // reply
	buf[1] = depth
	binary.LittleEndian.PutUint16(buf[2:], seq)
	binary.LittleEndian.PutUint32(buf[4:], uint32(len(padded)/4))
	binary.LittleEndian.PutUint32(buf[8:], visual)
	copy(buf[32:], padded)
	_, err := w.Write(buf)
	return err
}

// strideFor is the fake server's OWN scanline-stride arithmetic, deliberately
// written out separately from pixelLayout.stride. Sharing that helper would
// make the fake agree with whatever the production code believes, and a wrong
// stride would lay out and read back identically - the padding tests would
// pass against a decoder that ignores padding entirely.
func strideFor(width int, bitsPerPixel, scanlinePad byte) int {
	rowBits := width * int(bitsPerPixel)
	pad := int(scanlinePad)
	if rem := rowBits % pad; rem != 0 {
		rowBits += pad - rem
	}
	return rowBits / 8
}

// gradient builds a ZPixmap whose pixel at (col,row) encodes its own
// coordinates, so a decode error anywhere shows up as a specific wrong pixel
// rather than a uniform smear.
func (cfg fakeServerConfig) gradient(width, height int) []byte {
	stride := strideFor(width, cfg.bitsPerPixel, cfg.scanlinePad)
	bpp := int(cfg.bitsPerPixel) / 8
	out := make([]byte, stride*height)
	// Fill the padding with a value that is not a plausible pixel, so a
	// decoder that ignores stride produces visibly wrong output.
	for i := range out {
		out[i] = 0xa5
	}
	for row := 0; row < height; row++ {
		for col := 0; col < width; col++ {
			r, g, b := uint32(col%256), uint32(row%256), uint32((col+row)%256)
			p := r<<16 | g<<8 | b
			off := row*stride + col*bpp
			for i := 0; i < bpp; i++ {
				if cfg.byteOrder == xproto.ImageOrderLSBFirst {
					out[off+i] = byte(p >> (8 * i))
				} else {
					out[off+i] = byte(p >> (8 * (bpp - 1 - i)))
				}
			}
		}
	}
	return out
}

// startFake wires a socket pair, runs the fake server on one end and returns a
// display connected to the other.
func startFake(t *testing.T, cfg fakeServerConfig) (*display, <-chan getImageRequest) {
	t.Helper()
	client, server := net.Pipe()
	reqs := make(chan getImageRequest, 4)
	go cfg.serve(server, reqs)

	d, err := connectNet(client)
	if err != nil {
		t.Fatalf("connectNet: %v", err)
	}
	t.Cleanup(d.close)
	return d, reqs
}

func TestConnectReadsScreenGeometry(t *testing.T) {
	d, _ := startFake(t, truecolor24())
	if d.width != testScreenW || d.height != testScreenH {
		t.Errorf("screen is %dx%d, want %dx%d", d.width, d.height, testScreenW, testScreenH)
	}
	if d.root != testRootWindow {
		t.Errorf("root window %#x, want %#x", d.root, testRootWindow)
	}
}

func TestGrabFullScreen(t *testing.T) {
	d, reqs := startFake(t, truecolor24())
	img, err := d.grab(image.Rect(0, 0, testScreenW, testScreenH))
	if err != nil {
		t.Fatalf("grab: %v", err)
	}
	req := <-reqs
	if req.x != 0 || req.y != 0 || req.width != testScreenW || req.height != testScreenH {
		t.Errorf("server saw GetImage %dx%d+%d+%d, want %dx%d+0+0",
			req.width, req.height, req.x, req.y, testScreenW, testScreenH)
	}
	if got := img.Bounds().Dx(); got != testScreenW {
		t.Errorf("image width %d, want %d", got, testScreenW)
	}
	assertGradient(t, img)
}

// TestGrabRegionAsksTheServerForOnlyTheRegion is the point of doing regions in
// the protocol rather than cropping afterwards: the server is asked for the
// sub-rectangle, so only those pixels cross the socket.
func TestGrabRegionAsksTheServerForOnlyTheRegion(t *testing.T) {
	d, reqs := startFake(t, truecolor24())
	img, err := d.grab(image.Rect(10, 20, 210, 120))
	if err != nil {
		t.Fatalf("grab: %v", err)
	}
	req := <-reqs
	want := getImageRequest{x: 10, y: 20, width: 200, height: 100}
	if req != want {
		t.Errorf("server saw GetImage %+v, want %+v", req, want)
	}
	if img.Bounds().Dx() != 200 || img.Bounds().Dy() != 100 {
		t.Errorf("image is %v, want 200x100", img.Bounds().Size())
	}
	assertGradient(t, img)
}

// TestGrabRegionWithScanlinePadding is the regression guard for the stride
// bug: at 24 bits per pixel with 32-bit scanline padding, a 199-pixel-wide row
// occupies 597 bytes of pixels inside a 600-byte row. A decoder that assumes
// width*bytesPerPixel shears the image progressively down the rows - and full
// screen widths, being conveniently aligned, never reveal it.
func TestGrabRegionWithScanlinePadding(t *testing.T) {
	cfg := truecolor24()
	cfg.bitsPerPixel = 24
	cfg.scanlinePad = 32
	d, _ := startFake(t, cfg)

	img, err := d.grab(image.Rect(0, 0, 199, 40))
	if err != nil {
		t.Fatalf("grab: %v", err)
	}
	assertGradient(t, img)
}

func TestGrabMSBFirstServer(t *testing.T) {
	cfg := truecolor24()
	cfg.byteOrder = xproto.ImageOrderMSBFirst
	d, _ := startFake(t, cfg)

	img, err := d.grab(image.Rect(0, 0, 64, 8))
	if err != nil {
		t.Fatalf("grab: %v", err)
	}
	assertGradient(t, img)
}

// TestGrabRejectsShortReply covers a truncated GetImage answer: the decoder
// must say so rather than index past the end of the buffer.
func TestGrabRejectsShortReply(t *testing.T) {
	cfg := truecolor24()
	cfg.image = make([]byte, 16) // far less than the requested region needs
	d, _ := startFake(t, cfg)

	if _, err := d.grab(image.Rect(0, 0, 100, 100)); err == nil {
		t.Fatal("grab accepted a truncated GetImage reply")
	}
}

// assertGradient checks the decoded image against the pattern the fake server
// generated, which encodes each pixel's own coordinates.
func assertGradient(t *testing.T, img *image.RGBA) {
	t.Helper()
	b := img.Bounds()
	for row := 0; row < b.Dy(); row++ {
		for col := 0; col < b.Dx(); col++ {
			c := img.RGBAAt(col, row)
			wantR, wantG, wantB := uint8(col%256), uint8(row%256), uint8((col+row)%256)
			if c.R != wantR || c.G != wantG || c.B != wantB || c.A != 0xff {
				t.Fatalf("pixel (%d,%d) = %v, want (%d,%d,%d,255)",
					col, row, c, wantR, wantG, wantB)
			}
		}
	}
}
