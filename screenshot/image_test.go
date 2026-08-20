package main

import (
	"strings"
	"testing"
)

func TestNewChannel(t *testing.T) {
	tests := []struct {
		name      string
		mask      uint32
		wantShift uint
		wantMax   uint32
		wantErr   string
	}{
		{name: "8-bit red", mask: 0xff0000, wantShift: 16, wantMax: 255},
		{name: "8-bit green", mask: 0x00ff00, wantShift: 8, wantMax: 255},
		{name: "8-bit blue", mask: 0x0000ff, wantShift: 0, wantMax: 255},
		{name: "10-bit red (depth 30)", mask: 0x3ff00000, wantShift: 20, wantMax: 1023},
		{name: "5-bit red (RGB565)", mask: 0xf800, wantShift: 11, wantMax: 31},
		{name: "6-bit green (RGB565)", mask: 0x07e0, wantShift: 5, wantMax: 63},
		{name: "empty", mask: 0, wantErr: "indexed colour"},
		{name: "non-contiguous", mask: 0xf0f0, wantErr: "not contiguous"},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			c, err := newChannel(tt.mask)
			if tt.wantErr != "" {
				if err == nil {
					t.Fatalf("expected an error for mask %#x", tt.mask)
				}
				if !strings.Contains(err.Error(), tt.wantErr) {
					t.Errorf("error %q does not mention %q", err, tt.wantErr)
				}
				return
			}
			if err != nil {
				t.Fatalf("unexpected error: %v", err)
			}
			if c.shift != tt.wantShift || c.max != tt.wantMax {
				t.Errorf("got shift=%d max=%d, want shift=%d max=%d",
					c.shift, c.max, tt.wantShift, tt.wantMax)
			}
		})
	}
}

// TestChannelValue8Scaling covers the two directions the same expression has
// to handle: narrowing deep colour down to 8 bits, and widening 5/6-bit
// components up to the full range so white stays white.
func TestChannelValue8Scaling(t *testing.T) {
	tests := []struct {
		name  string
		mask  uint32
		pixel uint32
		want  uint8
	}{
		{name: "8-bit passthrough", mask: 0x0000ff, pixel: 0x7f, want: 0x7f},
		{name: "8-bit full", mask: 0x0000ff, pixel: 0xff, want: 0xff},
		{name: "10-bit full stays full", mask: 0x3ff, pixel: 1023, want: 255},
		{name: "10-bit zero stays zero", mask: 0x3ff, pixel: 0, want: 0},
		{name: "10-bit midpoint narrows", mask: 0x3ff, pixel: 512, want: 127},
		{name: "5-bit full widens to white", mask: 0x1f, pixel: 31, want: 255},
		{name: "5-bit half", mask: 0x1f, pixel: 16, want: 131},
		{name: "shifted 10-bit red", mask: 0x3ff00000, pixel: 0x3ff00000, want: 255},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			c, err := newChannel(tt.mask)
			if err != nil {
				t.Fatal(err)
			}
			if got := c.value8(tt.pixel); got != tt.want {
				t.Errorf("value8(%#x) = %d, want %d", tt.pixel, got, tt.want)
			}
		})
	}
}

func TestStride(t *testing.T) {
	tests := []struct {
		name         string
		width        int
		bitsPerPixel byte
		scanlinePad  byte
		want         int
	}{
		{name: "32bpp needs no padding", width: 100, bitsPerPixel: 32, scanlinePad: 32, want: 400},
		{name: "odd width at 32bpp", width: 199, bitsPerPixel: 32, scanlinePad: 32, want: 796},
		// 199*24 = 4776 bits of pixels; padded up to 4800 = 600 bytes, so the
		// row carries 3 bytes the naive 199*3=597 calculation walks over.
		{name: "24bpp rounds up to the pad", width: 199, bitsPerPixel: 24, scanlinePad: 32, want: 600},
		{name: "24bpp already aligned", width: 200, bitsPerPixel: 24, scanlinePad: 32, want: 600},
		{name: "16bpp odd width", width: 101, bitsPerPixel: 16, scanlinePad: 32, want: 204},
		{name: "8bpp pads to 4 bytes", width: 5, bitsPerPixel: 8, scanlinePad: 32, want: 8},
		{name: "8-bit pad does not round", width: 5, bitsPerPixel: 8, scanlinePad: 8, want: 5},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			l := pixelLayout{bitsPerPixel: tt.bitsPerPixel, scanlinePad: tt.scanlinePad}
			if got := l.stride(tt.width); got != tt.want {
				t.Errorf("stride(%d) = %d, want %d", tt.width, got, tt.want)
			}
		})
	}
}

func TestReadPixel(t *testing.T) {
	b := []byte{0x11, 0x22, 0x33, 0x44}
	tests := []struct {
		name     string
		n        int
		lsbFirst bool
		want     uint32
	}{
		{name: "4 bytes LSB first", n: 4, lsbFirst: true, want: 0x44332211},
		{name: "4 bytes MSB first", n: 4, lsbFirst: false, want: 0x11223344},
		{name: "3 bytes LSB first", n: 3, lsbFirst: true, want: 0x332211},
		{name: "3 bytes MSB first", n: 3, lsbFirst: false, want: 0x112233},
		{name: "2 bytes LSB first", n: 2, lsbFirst: true, want: 0x2211},
		{name: "1 byte", n: 1, lsbFirst: true, want: 0x11},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			if got := readPixel(b, tt.n, tt.lsbFirst); got != tt.want {
				t.Errorf("readPixel = %#x, want %#x", got, tt.want)
			}
		})
	}
}

// TestDecodeDepth30 is the case a hardcoded 8-bits-per-component decoder gets
// silently wrong rather than failing: NVIDIA can drive a depth-30 screen, and
// its 10-bit components must scale down instead of being read as bytes.
func TestDecodeDepth30(t *testing.T) {
	l := pixelLayout{bitsPerPixel: 32, scanlinePad: 32, lsbFirst: true}
	var err error
	if l.red, err = newChannel(0x3ff00000); err != nil {
		t.Fatal(err)
	}
	if l.green, err = newChannel(0x000ffc00); err != nil {
		t.Fatal(err)
	}
	if l.blue, err = newChannel(0x000003ff); err != nil {
		t.Fatal(err)
	}

	// One pixel: full red, zero green, half blue.
	pixel := uint32(1023)<<20 | uint32(0)<<10 | uint32(512)
	data := []byte{byte(pixel), byte(pixel >> 8), byte(pixel >> 16), byte(pixel >> 24)}

	img, err := decodeZPixmap(data, 1, 1, l)
	if err != nil {
		t.Fatalf("decode: %v", err)
	}
	got := img.RGBAAt(0, 0)
	if got.R != 255 || got.G != 0 || got.B != 127 || got.A != 255 {
		t.Errorf("depth-30 pixel decoded as %v, want (255,0,127,255)", got)
	}
}

func TestDecodeRejectsBadInput(t *testing.T) {
	ok := pixelLayout{bitsPerPixel: 32, scanlinePad: 32}
	ok.red, _ = newChannel(0xff0000)
	ok.green, _ = newChannel(0x00ff00)
	ok.blue, _ = newChannel(0x0000ff)

	tests := []struct {
		name    string
		data    []byte
		w, h    int
		layout  pixelLayout
		wantErr string
	}{
		{name: "zero width", data: make([]byte, 16), w: 0, h: 1, layout: ok, wantErr: "0x1"},
		{name: "short buffer", data: make([]byte, 4), w: 10, h: 10, layout: ok, wantErr: "need"},
		{
			name: "bits per pixel not a byte multiple", data: make([]byte, 64), w: 2, h: 2,
			layout:  pixelLayout{bitsPerPixel: 4, scanlinePad: 32},
			wantErr: "bits-per-pixel",
		},
		{
			name: "zero scanline pad", data: make([]byte, 64), w: 2, h: 2,
			layout:  pixelLayout{bitsPerPixel: 32, scanlinePad: 0},
			wantErr: "scanline pad",
		},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			_, err := decodeZPixmap(tt.data, tt.w, tt.h, tt.layout)
			if err == nil {
				t.Fatal("expected an error")
			}
			if !strings.Contains(err.Error(), tt.wantErr) {
				t.Errorf("error %q does not mention %q", err, tt.wantErr)
			}
		})
	}
}
