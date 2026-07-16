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
"""
import math
import sys
import wave

TOL_HZ = 25.0

def die(msg):
    print(f"check-audio: FAIL: {msg}", file=sys.stderr)
    sys.exit(1)

if len(sys.argv) not in (4, 5):
    die(f"usage: {sys.argv[0]} FILE MIN_SECONDS MIN_PEAK [EXPECTED_HZ]")

path = sys.argv[1]
min_sec, min_peak = float(sys.argv[2]), float(sys.argv[3])
expected_hz = float(sys.argv[4]) if len(sys.argv) == 5 else None

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
print(info)

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

print("check-audio: PASS")
