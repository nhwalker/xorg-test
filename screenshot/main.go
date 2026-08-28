// Command screenshot saves the containerized desktop's display, or a region of
// it, as a PNG.
//
// It is deliberately self-contained: a static binary with no runtime
// dependencies, speaking the X11 wire protocol straight down the socket. That
// is what lets it be injected into an arbitrary client container - ubi9,
// alpine, distroless - none of which ship an X client stack.
//
// The command line, not the implementation, is the contract. When this desktop
// moves to Wayland there is no XGetImage equivalent a client can call, and the
// backend here becomes a custom compositor protocol; `screenshot out.png`
// keeps meaning what it means today. Only options BOTH backends can honour
// belong in these flags.
package main

import (
	"bytes"
	"errors"
	"fmt"
	"image"
	"image/png"
	"io"
	"os"

	"github.com/spf13/pflag"
)

// usageErr marks a problem with what the user asked for (exit 2) as opposed to
// a failure carrying it out (exit 1). Region errors are usage errors even
// though they are only detectable once the screen size is known.
type usageErr struct{ err error }

func (e usageErr) Error() string { return e.err.Error() }
func (e usageErr) Unwrap() error { return e.err }

func usagef(format string, a ...any) error { return usageErr{fmt.Errorf(format, a...)} }

type options struct {
	x, y      int
	width     int
	height    int
	widthSet  bool
	heightSet bool
	toStdout  bool
	help      bool
	list      bool
	file      string
}

func newFlagSet(o *options) *pflag.FlagSet {
	fs := pflag.NewFlagSet("screenshot", pflag.ContinueOnError)
	// Errors and usage are printed by main, once, in one format.
	fs.SetOutput(io.Discard)
	fs.IntVarP(&o.x, "x", "x", 0, "left edge of the region to capture")
	fs.IntVarP(&o.y, "y", "y", 0, "top edge of the region to capture")
	fs.IntVarP(&o.width, "width", "w", 0, "width of the region (default: to the right screen edge)")
	fs.IntVarP(&o.height, "height", "h", 0, "height of the region (default: to the bottom screen edge)")
	fs.BoolVar(&o.toStdout, "to-stdout", false, "write the PNG to stdout instead of to a file")
	fs.BoolVar(&o.list, "list-clients", false, "list connected X clients (resource-ID base and PID) instead of capturing")
	// No -h shorthand: -h is height. Defining both names here also stops
	// pflag installing its own -h/--help handling.
	fs.BoolVar(&o.help, "help", false, "show this help and exit")
	return fs
}

func writeUsage(w io.Writer) {
	var o options
	fmt.Fprint(w, `Usage:
  screenshot [flags] FILE.png     save the desktop (or a region of it) to FILE
  screenshot [flags] --to-stdout  write the PNG to stdout instead
  screenshot --list-clients       list connected X clients (one per line:
                                  client-base=0x... pid=N) and exit

Captures the X display named by $DISPLAY. With no region flags the whole
desktop is captured; -x/-y/-w/-h select a sub-region of it.

Flags:
`)
	fmt.Fprint(w, newFlagSet(&o).FlagUsages())
	fmt.Fprint(w, `
Note: -h is HEIGHT. Use --help for this message.

Exit status:
  0  success
  1  runtime failure (no display reachable, capture or write failed)
  2  usage error (bad flags, or a region that does not fit the screen)
`)
}

// validate checks everything that can be known without talking to X.
func (o *options) validate(fs *pflag.FlagSet) error {
	args := fs.Args()
	if o.list {
		// A listing takes no file and captures nothing; refuse the mix
		// rather than guess which of the two the caller wanted.
		if len(args) > 0 || o.toStdout || fs.Changed("x") || fs.Changed("y") ||
			fs.Changed("width") || fs.Changed("height") {
			return usagef("--list-clients takes no file argument and no capture flags")
		}
		return nil
	}
	switch {
	case o.toStdout && len(args) > 0:
		return usagef("--to-stdout takes no FILE argument (got %q)", args[0])
	case !o.toStdout && len(args) == 0:
		return usagef("no output file given: pass FILE.png, or --to-stdout")
	case len(args) > 1:
		return usagef("expected one output file, got %d: %v", len(args), args)
	}
	if !o.toStdout {
		o.file = args[0]
	}

	o.widthSet = fs.Changed("width")
	o.heightSet = fs.Changed("height")
	if o.x < 0 || o.y < 0 {
		return usagef("-x/-y must not be negative (got %d,%d)", o.x, o.y)
	}
	if o.widthSet && o.width <= 0 {
		return usagef("-w must be positive (got %d)", o.width)
	}
	if o.heightSet && o.height <= 0 {
		return usagef("-h must be positive (got %d)", o.height)
	}
	return nil
}

// region resolves the requested rectangle against the real screen size.
//
// Unset -w/-h extend to the screen edge, so `-x 100` means "everything right
// of x=100". Anything that does not fit is refused rather than clamped: a
// silently shrunk screenshot is the wrong size without looking wrong, which is
// exactly what breaks an automated image comparison.
func (o *options) region(screenW, screenH int) (image.Rectangle, error) {
	w, h := o.width, o.height
	if !o.widthSet {
		w = screenW - o.x
	}
	if !o.heightSet {
		h = screenH - o.y
	}
	if w <= 0 || h <= 0 {
		return image.Rectangle{}, usagef(
			"offset %d,%d leaves nothing to capture on a %dx%d screen", o.x, o.y, screenW, screenH)
	}
	if o.x+w > screenW || o.y+h > screenH {
		return image.Rectangle{}, usagef(
			"region %dx%d+%d+%d does not fit the %dx%d screen", w, h, o.x, o.y, screenW, screenH)
	}
	return image.Rect(o.x, o.y, o.x+w, o.y+h), nil
}

func writePNG(img image.Image, file string, toStdout bool, stdout io.Writer) error {
	if toStdout {
		if err := png.Encode(stdout, img); err != nil {
			return fmt.Errorf("writing PNG to stdout: %w", err)
		}
		return nil
	}
	// Encode fully before creating the file. An encode failure part-way
	// through would otherwise leave a truncated PNG at the path a consumer is
	// polling for, which reads as a successful capture of a corrupt screen.
	var buf bytes.Buffer
	if err := png.Encode(&buf, img); err != nil {
		return fmt.Errorf("encoding PNG: %w", err)
	}
	if err := os.WriteFile(file, buf.Bytes(), 0o644); err != nil {
		return fmt.Errorf("writing %s: %w", file, err)
	}
	return nil
}

func run(args []string, stdout io.Writer) error {
	var o options
	fs := newFlagSet(&o)
	if err := fs.Parse(args); err != nil {
		if errors.Is(err, pflag.ErrHelp) {
			writeUsage(stdout)
			return nil
		}
		return usageErr{err}
	}
	if o.help {
		writeUsage(stdout)
		return nil
	}
	if err := o.validate(fs); err != nil {
		return err
	}

	name := os.Getenv("DISPLAY")
	if name == "" {
		return errors.New("DISPLAY is not set: no X display to capture " +
			"(a client container is granted one by the desktop.local/display CDI device)")
	}
	d, err := connect(name)
	if err != nil {
		return err
	}
	defer d.close()

	if o.list {
		return listClients(d.conn, stdout)
	}

	r, err := o.region(d.width, d.height)
	if err != nil {
		return err
	}
	img, err := d.grab(r)
	if err != nil {
		return err
	}
	return writePNG(img, o.file, o.toStdout, stdout)
}

func main() {
	err := run(os.Args[1:], os.Stdout)
	if err == nil {
		return
	}
	fmt.Fprintf(os.Stderr, "screenshot: %v\n", err)
	var ue usageErr
	if errors.As(err, &ue) {
		fmt.Fprintln(os.Stderr)
		writeUsage(os.Stderr)
		os.Exit(2)
	}
	os.Exit(1)
}
