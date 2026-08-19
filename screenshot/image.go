package main

import (
	"fmt"
	"image"
	"math/bits"
)

// channel describes one colour component's position inside a raw pixel, as
// declared by the X visual's red/green/blue masks. Deriving it from the mask
// rather than assuming 8 bits per component is what lets a depth-30 (10 bits
// per component) screen decode correctly instead of producing garbage; NVIDIA
// can and does run those.
type channel struct {
	shift uint
	max   uint32
}

func newChannel(mask uint32) (channel, error) {
	if mask == 0 {
		return channel{}, fmt.Errorf("visual has an empty colour mask (indexed colour is unsupported)")
	}
	shift := bits.TrailingZeros32(mask)
	width := bits.OnesCount32(mask)
	if mask != ((1<<width)-1)<<shift {
		return channel{}, fmt.Errorf("visual colour mask %#x is not contiguous", mask)
	}
	return channel{shift: uint(shift), max: 1<<width - 1}, nil
}

// value8 scales the component to the 0-255 range image/png wants. The same
// expression both widens (5-bit 565 colour) and narrows (10-bit deep colour),
// so there is no per-depth special case to get wrong.
func (c channel) value8(pixel uint32) uint8 {
	return uint8((pixel >> c.shift & c.max) * 255 / c.max)
}

// pixelLayout is everything needed to interpret a ZPixmap byte stream: how
// wide a pixel is, how rows are padded, which end of a pixel comes first, and
// where the colour components sit. Every field comes from the server's own
// setup reply - none of it is assumed.
type pixelLayout struct {
	bitsPerPixel uint8
	scanlinePad  uint8
	lsbFirst     bool
	red          channel
	green        channel
	blue         channel
}

// stride is the distance between the starts of two rows. X pads every scanline
// out to a multiple of scanlinePad BITS, so this is not width*bytesPerPixel.
// Full-screen captures hide the difference because screen widths are
// conveniently aligned; an arbitrary -w region is where an assumed stride
// starts shearing the image.
func (l pixelLayout) stride(width int) int {
	pad := int(l.scanlinePad)
	rowBits := width * int(l.bitsPerPixel)
	return ((rowBits + pad - 1) / pad) * pad / 8
}

// readPixel assembles one pixel from its bytes in the server's byte order.
func readPixel(b []byte, bytesPerPixel int, lsbFirst bool) uint32 {
	var v uint32
	if lsbFirst {
		for i := bytesPerPixel - 1; i >= 0; i-- {
			v = v<<8 | uint32(b[i])
		}
		return v
	}
	for i := 0; i < bytesPerPixel; i++ {
		v = v<<8 | uint32(b[i])
	}
	return v
}

// decodeZPixmap converts a GetImage ZPixmap reply into an RGBA image.
func decodeZPixmap(data []byte, width, height int, l pixelLayout) (*image.RGBA, error) {
	if width <= 0 || height <= 0 {
		return nil, fmt.Errorf("cannot decode a %dx%d image", width, height)
	}
	if l.bitsPerPixel%8 != 0 || l.bitsPerPixel == 0 || l.bitsPerPixel > 32 {
		return nil, fmt.Errorf("unsupported bits-per-pixel %d (need a multiple of 8, at most 32)", l.bitsPerPixel)
	}
	if l.scanlinePad == 0 || l.scanlinePad%8 != 0 {
		return nil, fmt.Errorf("unsupported scanline pad %d bits", l.scanlinePad)
	}

	bytesPerPixel := int(l.bitsPerPixel) / 8
	stride := l.stride(width)
	// The final row need not carry its trailing pad, so require only what is
	// actually read rather than stride*height.
	need := stride*(height-1) + width*bytesPerPixel
	if len(data) < need {
		return nil, fmt.Errorf("GetImage returned %d bytes, need %d for %dx%d at %d bpp",
			len(data), need, width, height, l.bitsPerPixel)
	}

	img := image.NewRGBA(image.Rect(0, 0, width, height))
	for row := 0; row < height; row++ {
		src := data[row*stride:]
		dst := img.Pix[row*img.Stride:]
		for col := 0; col < width; col++ {
			p := readPixel(src[col*bytesPerPixel:], bytesPerPixel, l.lsbFirst)
			dst[col*4+0] = l.red.value8(p)
			dst[col*4+1] = l.green.value8(p)
			dst[col*4+2] = l.blue.value8(p)
			dst[col*4+3] = 0xff
		}
	}
	return img, nil
}
