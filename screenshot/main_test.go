package main

import (
	"bytes"
	"errors"
	"image"
	"image/color"
	"image/png"
	"io"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// parse runs the flag layer the way run() does, so these tests exercise the
// real pflag configuration rather than a reconstruction of it.
func parse(t *testing.T, args ...string) (*options, error) {
	t.Helper()
	var o options
	fs := newFlagSet(&o)
	if err := fs.Parse(args); err != nil {
		return &o, usageErr{err}
	}
	if o.help {
		return &o, nil
	}
	return &o, o.validate(fs)
}

// TestShortHeightFlag pins the deliberate collision: -h is HEIGHT here, and
// help is --help only. Getting this backwards silently changes the published
// CLI, so it is asserted rather than left to pflag's defaults (pflag installs
// its own -h help shorthand unless something else claims 'h').
func TestShortHeightFlag(t *testing.T) {
	o, err := parse(t, "-h", "600", "out.png")
	if err != nil {
		t.Fatalf("-h 600: %v", err)
	}
	if o.height != 600 || !o.heightSet {
		t.Errorf("-h set height=%d (set=%v), want 600 (set=true)", o.height, o.heightSet)
	}
	if o.help {
		t.Error("-h was treated as --help")
	}
}

func TestHelpFlagIsNotAnError(t *testing.T) {
	o, err := parse(t, "--help")
	if err != nil {
		t.Fatalf("--help returned %v, want nil", err)
	}
	if !o.help {
		t.Error("--help did not set help")
	}
	// --help must not trip the "no output file" check.
	var out bytes.Buffer
	if err := run([]string{"--help"}, &out); err != nil {
		t.Fatalf("run --help: %v", err)
	}
	for _, want := range []string{"--to-stdout", "-h, --height", "-h is HEIGHT"} {
		if !strings.Contains(out.String(), want) {
			t.Errorf("help output is missing %q", want)
		}
	}
}

func TestDestinationArguments(t *testing.T) {
	tests := []struct {
		name    string
		args    []string
		wantErr bool
		file    string
	}{
		{name: "file", args: []string{"out.png"}, file: "out.png"},
		{name: "stdout", args: []string{"--to-stdout"}},
		{name: "neither", args: nil, wantErr: true},
		{name: "both", args: []string{"--to-stdout", "out.png"}, wantErr: true},
		{name: "two files", args: []string{"a.png", "b.png"}, wantErr: true},
		{name: "flags then file", args: []string{"-x", "5", "out.png"}, file: "out.png"},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			o, err := parse(t, tt.args...)
			if tt.wantErr {
				if err == nil {
					t.Fatal("expected an error")
				}
				assertUsageError(t, err)
				return
			}
			if err != nil {
				t.Fatalf("unexpected error: %v", err)
			}
			if o.file != tt.file {
				t.Errorf("file = %q, want %q", o.file, tt.file)
			}
		})
	}
}

func TestFlagValidation(t *testing.T) {
	for _, args := range [][]string{
		{"-x", "-1", "out.png"},
		{"-y", "-1", "out.png"},
		{"-w", "0", "out.png"},
		{"-h", "0", "out.png"},
		{"-w", "-5", "out.png"},
	} {
		t.Run(strings.Join(args, " "), func(t *testing.T) {
			_, err := parse(t, args...)
			if err == nil {
				t.Fatal("expected a usage error")
			}
			assertUsageError(t, err)
		})
	}
}

func TestRegionDefaultsAndBounds(t *testing.T) {
	const screenW, screenH = 1920, 1080
	tests := []struct {
		name    string
		args    []string
		want    image.Rectangle
		wantErr string
	}{
		{
			name: "no flags is the whole screen",
			args: []string{"out.png"},
			want: image.Rect(0, 0, screenW, screenH),
		},
		{
			name: "offset only extends to the screen edge",
			args: []string{"-x", "100", "-y", "50", "out.png"},
			want: image.Rect(100, 50, screenW, screenH),
		},
		{
			name: "explicit region",
			args: []string{"-x", "10", "-y", "20", "-w", "200", "-h", "100", "out.png"},
			want: image.Rect(10, 20, 210, 120),
		},
		{
			name: "width only keeps full height",
			args: []string{"-w", "640", "out.png"},
			want: image.Rect(0, 0, 640, screenH),
		},
		{
			name: "exactly the screen is allowed",
			args: []string{"-w", "1920", "-h", "1080", "out.png"},
			want: image.Rect(0, 0, screenW, screenH),
		},
		{
			name:    "too wide is refused, not clamped",
			args:    []string{"-w", "99999", "out.png"},
			wantErr: "1920x1080",
		},
		{
			name:    "region running off the right edge",
			args:    []string{"-x", "1900", "-w", "100", "out.png"},
			wantErr: "does not fit",
		},
		{
			name:    "region running off the bottom edge",
			args:    []string{"-y", "1000", "-h", "200", "out.png"},
			wantErr: "does not fit",
		},
		{
			name:    "offset past the screen leaves nothing",
			args:    []string{"-x", "1920", "out.png"},
			wantErr: "leaves nothing",
		},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			o, err := parse(t, tt.args...)
			if err != nil {
				t.Fatalf("parse: %v", err)
			}
			got, err := o.region(screenW, screenH)
			if tt.wantErr != "" {
				if err == nil {
					t.Fatalf("expected an error containing %q, got region %v", tt.wantErr, got)
				}
				assertUsageError(t, err)
				if !strings.Contains(err.Error(), tt.wantErr) {
					t.Errorf("error %q does not mention %q", err, tt.wantErr)
				}
				return
			}
			if err != nil {
				t.Fatalf("region: %v", err)
			}
			if got != tt.want {
				t.Errorf("region = %v, want %v", got, tt.want)
			}
		})
	}
}

// TestNoDisplayIsARuntimeError: an unset DISPLAY is the shape of "this
// container was not granted the display device", which is a runtime failure
// (exit 1), not the user mistyping a flag (exit 2).
func TestNoDisplayIsARuntimeError(t *testing.T) {
	t.Setenv("DISPLAY", "")
	err := run([]string{filepath.Join(t.TempDir(), "out.png")}, io.Discard)
	if err == nil {
		t.Fatal("expected an error with DISPLAY unset")
	}
	var ue usageErr
	if errors.As(err, &ue) {
		t.Errorf("unset DISPLAY reported as a usage error: %v", err)
	}
	if !strings.Contains(err.Error(), "desktop.local/display") {
		t.Errorf("error %q does not point at the CDI device that grants a display", err)
	}
}

func TestWritePNGToFile(t *testing.T) {
	path := filepath.Join(t.TempDir(), "out.png")
	if err := writePNG(testImage(), path, false, io.Discard); err != nil {
		t.Fatalf("writePNG: %v", err)
	}
	f, err := os.Open(path)
	if err != nil {
		t.Fatalf("open: %v", err)
	}
	defer f.Close()
	cfg, err := png.DecodeConfig(f)
	if err != nil {
		t.Fatalf("decoding written file: %v", err)
	}
	if cfg.Width != 4 || cfg.Height != 3 {
		t.Errorf("wrote a %dx%d PNG, want 4x3", cfg.Width, cfg.Height)
	}
}

func TestWritePNGToStdoutWritesNoFile(t *testing.T) {
	dir := t.TempDir()
	var out bytes.Buffer
	if err := writePNG(testImage(), filepath.Join(dir, "unused.png"), true, &out); err != nil {
		t.Fatalf("writePNG: %v", err)
	}
	if _, err := png.DecodeConfig(bytes.NewReader(out.Bytes())); err != nil {
		t.Fatalf("stdout is not a valid PNG: %v", err)
	}
	entries, err := os.ReadDir(dir)
	if err != nil {
		t.Fatal(err)
	}
	if len(entries) != 0 {
		t.Errorf("--to-stdout also wrote %d file(s) to disk", len(entries))
	}
}

// TestWritePNGLeavesNoTruncatedFile: encoding happens before the file is
// created, so a consumer polling for the path never sees a partial image.
func TestWritePNGFailureLeavesNoFile(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "nonexistent-subdir", "out.png")
	if err := writePNG(testImage(), path, false, io.Discard); err == nil {
		t.Fatal("expected a write error for an unwritable path")
	}
	if _, err := os.Stat(path); !os.IsNotExist(err) {
		t.Errorf("a file was left behind at %s", path)
	}
}

func testImage() *image.RGBA {
	img := image.NewRGBA(image.Rect(0, 0, 4, 3))
	for y := 0; y < 3; y++ {
		for x := 0; x < 4; x++ {
			img.Set(x, y, color.RGBA{R: uint8(x * 60), G: uint8(y * 80), B: 0x40, A: 0xff})
		}
	}
	return img
}

func assertUsageError(t *testing.T, err error) {
	t.Helper()
	var ue usageErr
	if !errors.As(err, &ue) {
		t.Errorf("error %q is not a usage error, so it would exit 1 instead of 2", err)
	}
}
