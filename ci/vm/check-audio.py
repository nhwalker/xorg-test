#!/usr/bin/env python3
"""Assert a QEMU wavcapture file contains real audio.

Usage: check-audio.py FILE MIN_SECONDS MIN_PEAK

Two distinct failure modes matter:
- wavcapture only writes frames while the guest's DAC stream is running,
  so a broken pipeline yields a header-only file (duration ~0);
- a running but muted/misrouted stream yields frames of silence (peak 0).

MIN_PEAK is a fraction of full scale (e.g. 0.05 = 5%). Stdlib only: the
CI runner has no audio tooling installed.
"""
import sys
import wave

def die(msg):
    print(f"check-audio: FAIL: {msg}", file=sys.stderr)
    sys.exit(1)

if len(sys.argv) != 4:
    die(f"usage: {sys.argv[0]} FILE MIN_SECONDS MIN_PEAK")

path, min_sec, min_peak = sys.argv[1], float(sys.argv[2]), float(sys.argv[3])

try:
    w = wave.open(path, "rb")
except FileNotFoundError:
    die(f"{path} does not exist - wavcapture never started?")
except wave.Error as e:
    die(f"{path} is not a valid WAV: {e}")

if w.getsampwidth() != 2:
    die(f"expected 16-bit samples, got {8 * w.getsampwidth()}-bit")

frames = w.getnframes()
rate = w.getframerate()
duration = frames / rate if rate else 0.0

raw = w.readframes(frames)
peak = 0
for i in range(0, len(raw) - 1, 2):
    s = int.from_bytes(raw[i:i + 2], "little", signed=True)
    if abs(s) > peak:
        peak = abs(s)
peak_frac = peak / 32768.0

print(f"check-audio: {path}: {duration:.2f}s @ {rate}Hz, "
      f"{w.getnchannels()}ch, peak={peak_frac:.3f} of full scale")

if duration < min_sec:
    die(f"only {duration:.2f}s captured (need >= {min_sec}s) - "
        "guest audio stream never ran for the capture window")
if peak_frac < min_peak:
    die(f"peak {peak_frac:.3f} below {min_peak} - stream ran but was silent "
        "(muted sink or misrouted client?)")

print("check-audio: PASS")
