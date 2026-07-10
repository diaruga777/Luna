#!/usr/bin/env python3
"""Synthesizes the two audio-playback chime assets from scratch (stdlib only —
math/wave/struct, no numpy) and converts them to .caf via afconvert (macOS-only).

Generates, into LunaLibraries/Sources/LunaAudioPlayback/Resources/:
  - ChimeTransition.caf  ~0.8s, two soft ascending notes (segment -> segment,
    e.g. before an autoplay "Now Reading" announcement).
  - ChimeFinal.caf       ~1.5s, three notes resolving down to the tonic — an
    audibly "done" sound for the end of the autoplay queue.

Both are warm (sine fundamental + a quiet second harmonic) and quiet (peak
around -12 dBFS), gentle attack/release so they don't feel like alerts.

Re-run after editing any parameters below; the .caf outputs are checked in.
"""

import math
import os
import struct
import subprocess
import sys
import wave

SAMPLE_RATE = 44100
PEAK_DBFS = -12.0
PEAK_AMPLITUDE = 32767 * (10 ** (PEAK_DBFS / 20.0))  # int16 full-scale headroom

RESOURCES_DIR = os.path.join(
    os.path.dirname(os.path.abspath(__file__)),
    "..", "LunaLibraries", "Sources", "LunaAudioPlayback", "Resources",
)


def envelope(t, duration, attack, release):
    """0..1 gain: linear attack, sustain, linear release."""
    if t < attack:
        return t / attack
    if t > duration - release:
        return max(0.0, (duration - t) / release)
    return 1.0


def note_samples(freq, duration, attack=0.03, release=0.12, harmonic_mix=0.18):
    """One note's samples in [-1, 1]: sine fundamental + a quiet, warm 2nd
    harmonic, with a gentle attack/release envelope."""
    n = int(SAMPLE_RATE * duration)
    out = []
    for i in range(n):
        t = i / SAMPLE_RATE
        g = envelope(t, duration, attack, release)
        fundamental = math.sin(2 * math.pi * freq * t)
        second_harmonic = math.sin(2 * math.pi * freq * 2 * t)
        sample = (fundamental * (1.0 - harmonic_mix) + second_harmonic * harmonic_mix) * g
        out.append(sample)
    return out


def sequence(notes):
    """Concatenates note sample lists with a short equal-power crossfade
    between adjacent notes so the sequence feels legato, not clicky."""
    crossfade = int(SAMPLE_RATE * 0.05)
    result = list(notes[0])
    for next_notes in notes[1:]:
        overlap = min(crossfade, len(result), len(next_notes))
        for i in range(overlap):
            fade_out = 1.0 - (i / overlap)
            fade_in = i / overlap
            idx = len(result) - overlap + i
            result[idx] = result[idx] * fade_out + next_notes[i] * fade_in
        result.extend(next_notes[overlap:])
    return result


def normalize_and_write_wav(path, samples):
    peak = max(1e-9, max(abs(s) for s in samples))
    scale = PEAK_AMPLITUDE / peak
    frames = bytearray()
    for s in samples:
        value = int(max(-32768, min(32767, round(s * scale))))
        frames += struct.pack("<h", value)
    with wave.open(path, "wb") as wav_file:
        wav_file.setnchannels(1)
        wav_file.setsampwidth(2)
        wav_file.setframerate(SAMPLE_RATE)
        wav_file.writeframes(bytes(frames))


def convert_to_caf(wav_path, caf_path):
    subprocess.run(
        ["afconvert", "-f", "caff", "-d", "LEI16@44100", wav_path, caf_path],
        check=True,
    )
    os.remove(wav_path)


def make_chime_transition():
    """Two ascending notes, ~0.8s total: soft "moving on" cue between segments."""
    notes = [
        note_samples(523.25, 0.42, attack=0.04, release=0.16),  # C5
        note_samples(659.25, 0.42, attack=0.03, release=0.22),  # E5
    ]
    return sequence(notes)


def make_chime_final():
    """Three notes resolving downward to the tonic, ~1.5s: audibly "done"."""
    notes = [
        note_samples(783.99, 0.5, attack=0.03, release=0.18),  # G5
        note_samples(659.25, 0.5, attack=0.03, release=0.2),   # E5
        note_samples(523.25, 0.65, attack=0.03, release=0.45), # C5 (tonic, longer tail)
    ]
    return sequence(notes)


def main():
    if sys.platform != "darwin":
        print("make_tones.py requires afconvert (macOS-only).", file=sys.stderr)
        sys.exit(1)

    os.makedirs(RESOURCES_DIR, exist_ok=True)

    jobs = [
        ("ChimeTransition", make_chime_transition),
        ("ChimeFinal", make_chime_final),
    ]
    for name, builder in jobs:
        samples = builder()
        wav_path = os.path.join(RESOURCES_DIR, f"{name}.wav")
        caf_path = os.path.join(RESOURCES_DIR, f"{name}.caf")
        normalize_and_write_wav(wav_path, samples)
        convert_to_caf(wav_path, caf_path)
        duration = len(samples) / SAMPLE_RATE
        print(f"Wrote {caf_path} ({duration:.2f}s)")


if __name__ == "__main__":
    main()
