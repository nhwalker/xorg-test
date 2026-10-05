#!/usr/bin/env python3
"""Assert a QEMU wavcapture file contains real audio (optionally at a pitch).

Usage: check-audio.py FILE MIN_SECONDS MIN_PEAK [EXPECTED_HZ]

Failure modes this catches:
- wavcapture only writes frames while the guest DAC stream runs, so a broken
  pipeline yields a header-only file (duration ~0);
- a running but muted/misrouted stream yields frames of silence (peak ~0);
- with EXPECTED_HZ, audio that plays but is garbled or resampled to the wrong
  rate lands at the wrong dominant frequency and is rejected.

Frequency check: a Goertzel scan finds the loudest frequency in the capture
and requires it to be within TOL_HZ of EXPECTED_HZ. Stdlib only - the CI
runner has no audio tooling installed.

Evidence options (Requirements.md, EV-AUDIO), anywhere on the command line:
  --report FILE   also write every line printed here (the verdict) to FILE
  --plot FILE     draw the level at EXPECTED_HZ (or at the dominant
                  frequency) over the capture, one bar per 0.1 s on a
                  -60..0 dBFS scale, as a PNG (needs imagemagick's convert,
                  which the e2e runner has; the stand-in for a spectrogram
                  where no spectrogram tool is installed)

Continuity options, for a tone that must play through an event. The tone's
span runs from the first to the last 0.1 s window where EXPECTED_HZ is at or
above -40 dBFS:
  --max-gap SEC   no run of windows below -40 dBFS inside the span may last
                  longer than SEC
  --span LO HI    the span must last from LO to HI seconds. wavcapture writes
                  nothing while the guest's output is idle, so a stretch the
                  output missed is not silence in the file but time missing
                  from it: a tone of known length that comes out shorter lost
                  that time
  --mark SEC      draw a red line on the plot SEC seconds after the span
                  begins (an event, timed by the player's clock)
"""
import math
import os
import shutil
import subprocess
import sys
import wave

TOL_HZ = 25.0

# --report / --plot, then the positional arguments.
args, report_path, plot_path = [], None, None
max_gap = span = mark = None
argv = sys.argv[1:]
while argv:
    a = argv.pop(0)
    if a == "--report" and argv:
        report_path = argv.pop(0)
    elif a == "--plot" and argv:
        plot_path = argv.pop(0)
    elif a == "--max-gap" and argv:
        max_gap = float(argv.pop(0))
    elif a == "--span" and len(argv) >= 2:
        span = (float(argv.pop(0)), float(argv.pop(0)))
    elif a == "--mark" and argv:
        mark = float(argv.pop(0))
    else:
        args.append(a)
report = open(report_path, "w") if report_path else None


def say(line, err=False):
    print(line, file=sys.stderr if err else sys.stdout)
    if report:
        report.write(line + "\n")
        report.flush()


def die(msg):
    say(f"check-audio: FAIL: {msg}", err=True)
    sys.exit(1)

if len(args) not in (3, 4):
    die(f"usage: {sys.argv[0]} [--report FILE] [--plot FILE.png] FILE MIN_SECONDS MIN_PEAK [EXPECTED_HZ]")

path = args[0]
min_sec, min_peak = float(args[1]), float(args[2])
expected_hz = float(args[3]) if len(args) == 4 else None

try:
    w = wave.open(path, "rb")
except FileNotFoundError:
    die(f"{path} does not exist - wavcapture never started?")
except wave.Error as e:
    die(f"{path} is not a valid WAV: {e}")

if w.getsampwidth() != 2:
    die(f"expected 16-bit samples, got {8 * w.getsampwidth()}-bit")

nch = w.getnchannels()
rate = w.getframerate()
frames = w.getnframes()
duration = frames / rate if rate else 0.0
raw = w.readframes(frames)

# Left channel only (interleaved 16-bit LE), and the peak amplitude.
left = []
peak = 0
step = 2 * nch
for i in range(0, len(raw) - 1, 2):
    s = int.from_bytes(raw[i:i + 2], "little", signed=True)
    if abs(s) > peak:
        peak = abs(s)
    if (i % step) == 0:               # channel 0 sample
        left.append(s)
peak_frac = peak / 32768.0


def goertzel_mag(samples, freq, sr):
    coeff = 2.0 * math.cos(2.0 * math.pi * freq / sr)
    s1 = s2 = 0.0
    for x in samples:
        s0 = x + coeff * s1 - s2
        s2, s1 = s1, s0
    return math.sqrt(max(0.0, s1 * s1 + s2 * s2 - coeff * s1 * s2))


dominant = None
if expected_hz is not None and left:
    # Analyse the LOUDEST ~0.75s window, not the first one: pipewire starts
    # playing later than pulse, so a fixed leading window can land in the
    # silence before the tone and read the scan floor. Pick the window with
    # the most energy (a lone startup click can't outweigh a 1.5s tone).
    N = 32768
    if len(left) <= N:
        scan = left
    else:
        best_start, best_e = 0, -1.0
        for start in range(0, len(left) - N + 1, 4096):
            e = sum(s * s for s in left[start:start + N])
            if e > best_e:
                best_e, best_start = e, start
        scan = left[best_start:best_start + N]
    best_f, best_m = 0.0, -1.0
    f = 100.0
    while f <= 4000.0:
        m = goertzel_mag(scan, f, rate)
        if m > best_m:
            best_m, best_f = m, f
        f += 5.0
    dominant = best_f

info = (f"check-audio: {path}: {duration:.2f}s @ {rate}Hz, {nch}ch, "
        f"peak={peak_frac:.3f}")
if dominant is not None:
    info += f", dominant~{dominant:.0f}Hz (want {expected_hz:.0f}Hz)"
say(info)


def levels_at(samples, sr, freq):
    """The amplitude at `freq` in each 0.1 s window, as a fraction of full
    scale."""
    step = max(1, int(sr * 0.1))
    coeff = 2.0 * math.cos(2.0 * math.pi * freq / sr)
    levels = []
    for start in range(0, len(samples) - step + 1, step):
        s1 = s2 = 0.0
        for x in samples[start:start + step]:
            s0 = x + coeff * s1 - s2
            s2, s1 = s1, s0
        mag = math.sqrt(max(0.0, s1 * s1 + s2 * s2 - coeff * s1 * s2))
        levels.append(2.0 * mag / step / 32768.0)
    return levels


def level_plot(samples, sr, freq, out, mark_i=None):
    """One bar per 0.1 s: the amplitude at `freq` on a -60..0 dBFS scale,
    with dashed lines at -20 and -40 dB, and a red line before window
    `mark_i` if given. Draws no text; the report says what it shows."""
    levels = levels_at(samples, sr, freq)
    # Short captures (a 1.5 s beep) get wider bars, so the plot stays readable.
    bw = max(2, min(8, 400 // max(1, len(levels))))
    w, h = max(200, len(levels) * bw), 240
    img = bytearray(b"\x10\x12\x16" * w * h)
    for i, a in enumerate(levels):
        db = 20 * math.log10(a) if a > 1e-6 else -120
        top = int((min(0, max(-60, db)) / -60) * (h - 1))
        for y in range(top, h):
            for x in range(bw * i, bw * i + bw - 1):
                img[(y * w + x) * 3:(y * w + x) * 3 + 3] = b"\x7f\xa8\x60"
    for db in (-20, -40):
        y = int(db / -60 * (h - 1))
        for x in range(0, w, 4):
            img[(y * w + x) * 3:(y * w + x) * 3 + 3] = b"\x4a\x51\x5c"
    if mark_i is not None and 0 <= mark_i < len(levels):
        for y in range(h):
            for x in (bw * mark_i, bw * mark_i + 1):
                img[(y * w + x) * 3:(y * w + x) * 3 + 3] = b"\xe0\x40\x40"
    if not shutil.which("convert"):
        # No stray PPM left behind: an evidence directory indexes every file.
        say("check-audio: no plot: imagemagick's convert is not installed here")
        return
    ppm = out + ".ppm"
    with open(ppm, "wb") as f:
        f.write(f"P6\n{w} {h}\n255\n".encode() + bytes(img))
    try:
        subprocess.run(["convert", ppm, out], check=True, timeout=120)
    finally:
        os.unlink(ppm)
    say(f"check-audio: plot {out}: the level at {freq:.0f} Hz, one bar per 0.1 s "
        f"({len(levels)} bars), -60..0 dBFS, dashed lines at -20 and -40 dB"
        + (f", a red line at {mark_i * 0.1:.1f}s" if mark_i is not None and 0 <= mark_i < len(levels) else ""))


# The tone's span (--max-gap, --span, --mark): its windows at EXPECTED_HZ.
FLOOR = 10 ** (-40 / 20)
lv = loud = None
if expected_hz is not None and left and (max_gap is not None or span is not None or mark is not None):
    lv = levels_at(left, rate, expected_hz)
    loud = [i for i, a in enumerate(lv) if a >= FLOOR]
    if loud:
        say(f"check-audio: the tone spans {loud[0] * 0.1:.1f}..{(loud[-1] + 1) * 0.1:.1f}s "
            f"of the capture: {(loud[-1] + 1 - loud[0]) * 0.1:.1f}s")
mark_i = None
if mark is not None:
    if loud:
        mark_i = loud[0] + int(round(mark / 0.1))
        say(f"check-audio: the mark, {mark:.2f}s after the tone begins, falls at {mark_i * 0.1:.1f}s of the capture")
    else:
        say("check-audio: no mark: the tone never reaches -40 dBFS, so there is nothing to time it from")

if plot_path and left:
    level_plot(left, rate, dominant if expected_hz is None and dominant else (expected_hz or 1000.0), plot_path, mark_i)

if duration < min_sec:
    die(f"only {duration:.2f}s captured (need >= {min_sec}s) - "
        "guest audio stream never ran for the capture window")
if peak_frac < min_peak:
    die(f"peak {peak_frac:.3f} below {min_peak} - stream ran but was silent "
        "(muted sink or misrouted client?)")
if expected_hz is not None:
    if not left:
        die("no samples to analyze for frequency")
    if abs(dominant - expected_hz) > TOL_HZ:
        die(f"dominant frequency {dominant:.0f}Hz is not {expected_hz:.0f}Hz "
            f"(+/-{TOL_HZ:.0f}) - garbled or wrong sample rate?")

if (max_gap is not None or span is not None) and lv is None:
    die("--max-gap and --span need EXPECTED_HZ and samples")
if (max_gap is not None or span is not None) and not loud:
    die(f"the tone is never at -40 dBFS or above at {expected_hz:.0f}Hz")
if max_gap is not None:
    run = longest = 0
    at = None
    for i in range(loud[0], loud[-1] + 1):
        run = run + 1 if lv[i] < FLOOR else 0
        if run > longest:
            longest, at = run, (i - run + 1) * 0.1
    say(f"check-audio: the tone's longest stretch below -40 dBFS is {longest * 0.1:.1f}s"
        + (f" (from {at:.1f}s)" if longest else "") + f"; allowed {max_gap:.1f}s")
    if longest * 0.1 > max_gap + 1e-9:
        die(f"the tone goes quiet for {longest * 0.1:.1f}s from {at:.1f}s "
            f"(allowed {max_gap:.1f}s)")
if span is not None:
    got = (loud[-1] + 1 - loud[0]) * 0.1
    if not span[0] - 1e-9 <= got <= span[1] + 1e-9:
        die(f"the tone spans {got:.1f}s of the capture, not {span[0]:.1f}..{span[1]:.1f}s"
            + (" - time is missing from the capture" if got < span[0] else ""))
    say(f"check-audio: the tone's span, {got:.1f}s, is within {span[0]:.1f}..{span[1]:.1f}s")

say("check-audio: PASS")
