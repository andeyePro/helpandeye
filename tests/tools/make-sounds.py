"""Makes the caller's sounds, so they are the project's own and can be remade or changed.
Run from the repository root:  python3 tests/tools/make-sounds.py"""
import math, struct, wave

RATE = 22050

def write(path, samples):
    with wave.open(path, "wb") as w:
        w.setnchannels(1); w.setsampwidth(2); w.setframerate(RATE)
        w.writeframes(b"".join(struct.pack("<h", int(max(-1, min(1, s)) * 32767)) for s in samples))

def buzz(freq, seconds):
    """A game-show wrong-answer buzz: two slightly apart square waves, cut off cleanly."""
    n = int(RATE * seconds)
    out = []
    for i in range(n):
        t = i / RATE
        edge = min(1, i / (RATE * 0.01), (n - i) / (RATE * 0.02))
        sq = sum(1 if math.sin(2 * math.pi * f * t) > 0 else -1 for f in (freq, freq * 1.01)) / 2
        out.append(0.35 * edge * sq)
    return out

def eeh_ooh(high, low):
    """A soft two-note "eeh-ooh", high then low: sine tones that swell in and fade out."""
    out = []
    for freq, seconds in ((high, 0.32), (low, 0.5)):
        n = int(RATE * seconds)
        for i in range(n):
            t = i / RATE
            env = min(1, i / (RATE * 0.04)) * min(1, (n - i) / (RATE * 0.12))
            out.append(0.3 * env * (math.sin(2 * math.pi * freq * t) + 0.2 * math.sin(4 * math.pi * freq * t)))
        out += [0.0] * int(RATE * 0.04)
    return out

def chime(freqs, step, seconds):
    """Soft bell notes, each starting a step after the last and fading away."""
    n = int(RATE * seconds)
    out = [0.0] * n
    for k, f in enumerate(freqs):
        start = int(RATE * step * k)
        for i in range(start, n):
            t = (i - start) / RATE
            env = min(1, t / 0.005) * math.exp(-t * 4)
            out[i] += 0.25 * env * (math.sin(2 * math.pi * f * t) + 0.3 * math.sin(4 * math.pi * f * t))
    return out

silence = [0.0] * int(RATE * 0.08)
write("app/helpandeye/Sounds/eeh-ooh.wav", eeh_ooh(659.25, 493.88))
write("app/helpandeye/Sounds/buzzer.wav", buzz(185, 0.35) + silence + buzz(139, 0.6))
write("app/helpandeye/Sounds/seen.wav", chime([523.25, 659.25, 783.99, 1046.5], 0.14, 1.4))
