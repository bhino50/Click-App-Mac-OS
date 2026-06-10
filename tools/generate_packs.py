"""
Generate bundled `.clickpack` sound packs using modal synthesis.

Procedural clicks usually sound digital because they're built from broadband
noise. Real mechanical-keyboard sounds are dominated by a small number of
damped resonant modes — the housing, the keycap, and the spring — each ringing
at a specific frequency with its own decay time. Sum a handful of those modes,
weight them, and you get something that reads to the ear as a switch impact
instead of static.

Two profiles ship:

  - Light: low-energy linear-feeling switch. Soft bottom-out, gentle keycap
           overtones, no metallic ping. Designed for long, comfortable typing.
  - Mech:  tactile/clicky switch. Stronger bottom-out, brighter keycap modes,
           a brief filtered transient at the start to mimic a leaf snap.

Each profile produces 4 random default variants per pack so per-keystroke
variation prevents the typing rhythm from feeling robotic.

Run from the project root:

    python3 tools/generate_packs.py
"""

from __future__ import annotations

import json
import math
import random
import struct
import wave
from pathlib import Path

SAMPLE_RATE = 44_100
ROOT = Path(__file__).resolve().parent.parent
PACKS_DIR = ROOT / "Resources" / "DefaultPacks"


# ----- WAV I/O -----------------------------------------------------------

def write_wav(path: Path, samples: list[float]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    clipped = [max(-1.0, min(1.0, s)) for s in samples]
    pcm = b"".join(struct.pack("<h", int(s * 30_000)) for s in clipped)
    with wave.open(str(path), "wb") as f:
        f.setnchannels(1)
        f.setsampwidth(2)
        f.setframerate(SAMPLE_RATE)
        f.writeframes(pcm)


# ----- Primitives --------------------------------------------------------

def sine(length: int, freq: float, phase: float = 0.0) -> list[float]:
    return [math.sin(2 * math.pi * freq * i / SAMPLE_RATE + phase) for i in range(length)]


def damped_mode(length: int, freq: float, tau_ms: float, phase: float = 0.0) -> list[float]:
    """One damped sinusoid — the building block of modal synthesis. `tau_ms`
    is the exponential decay time-constant; the mode is ~37% of its peak
    amplitude after one tau."""
    tau_samples = max(1.0, tau_ms / 1000.0 * SAMPLE_RATE)
    out = [0.0] * length
    for i in range(length):
        env = math.exp(-i / tau_samples)
        out[i] = env * math.sin(2 * math.pi * freq * i / SAMPLE_RATE + phase)
    return out


def noise(length: int, seed: int) -> list[float]:
    rng = random.Random(seed)
    return [rng.uniform(-1.0, 1.0) for _ in range(length)]


def lowpass(samples: list[float], cutoff_hz: float, poles: int = 2) -> list[float]:
    """Cascaded one-pole low-pass for a steeper, smoother rolloff."""
    out = list(samples)
    alpha = 1.0 / (1.0 + SAMPLE_RATE / (2.0 * math.pi * cutoff_hz))
    for _ in range(poles):
        prev = 0.0
        for i in range(len(out)):
            prev = prev + alpha * (out[i] - prev)
            out[i] = prev
    return out


def highpass(samples: list[float], cutoff_hz: float) -> list[float]:
    lp = lowpass(samples, cutoff_hz, poles=1)
    return [s - l for s, l in zip(samples, lp)]


def mix(*tracks: list[float]) -> list[float]:
    length = max(len(t) for t in tracks)
    out = [0.0] * length
    for track in tracks:
        for i, s in enumerate(track):
            out[i] += s
    return out


def hann_fade(samples: list[float], fade_ms: float = 1.5) -> list[float]:
    fade = max(2, int(fade_ms / 1000.0 * SAMPLE_RATE))
    n = len(samples)
    out = list(samples)
    fade = min(fade, n // 2)
    for i in range(fade):
        w = 0.5 * (1.0 - math.cos(math.pi * i / fade))
        out[i] *= w
        out[n - 1 - i] *= w
    return out


def normalize(samples: list[float], peak: float = 0.85) -> list[float]:
    peak_now = max((abs(s) for s in samples), default=1.0)
    if peak_now < 1e-9:
        return samples
    return [s * (peak / peak_now) for s in samples]


# ----- Profiles ----------------------------------------------------------
#
# A "mode" is (frequency Hz, gain, decay-tau ms).
#
# These frequencies are chosen to fall roughly where measurements of real
# Cherry-MX switches sit: a dominant bottom-out near 150-220Hz, secondary
# housing modes in the 400-900Hz range, and a couple of keycap overtones
# scattered up through 2-3 kHz. The decay constants taper off so higher
# frequencies die out faster, which is what makes acoustic objects sound
# acoustic.

LIGHT_MODES = [
    (170,  1.00, 36),   # bottom-out fundamental
    (320,  0.55, 24),   # housing second mode
    (660,  0.32, 16),
    (1120, 0.20, 10),
    (1860, 0.10, 7),
]

MECH_MODES = [
    (195,  1.00, 30),   # tighter, brighter bottom-out
    (390,  0.60, 22),
    (820,  0.42, 14),
    (1620, 0.30, 9),
    (2540, 0.18, 6),
    (3680, 0.08, 4),    # subtle metallic glint, well below piercing
]


def jitter_modes(modes, seed: int, freq_pct: float = 0.04, gain_pct: float = 0.10):
    """Slightly randomize mode frequencies and gains per-variant so successive
    keystrokes don't sound mechanically identical."""
    rng = random.Random(seed)
    out = []
    for f, g, t in modes:
        f_j = f * (1.0 + rng.uniform(-freq_pct, freq_pct))
        g_j = g * (1.0 + rng.uniform(-gain_pct, gain_pct))
        out.append((f_j, g_j, t))
    return out


def modal_click(modes, transient_db: float, length_ms: int, seed: int, lowpass_hz: float) -> list[float]:
    length = int(length_ms / 1000.0 * SAMPLE_RATE)
    components: list[list[float]] = []

    # Each mode is a damped sinusoid with random phase so variants aren't
    # phase-coherent.
    rng = random.Random(seed ^ 0xBEEF)
    for freq, gain, tau in jitter_modes(modes, seed):
        phase = rng.uniform(0.0, 2 * math.pi)
        components.append([s * gain for s in damped_mode(length, freq, tau, phase)])

    # Brief filtered noise transient for the initial impact attack. Without
    # this the first few milliseconds sound too "pure" — too synth, not enough
    # impact.
    transient_len = int(0.004 * SAMPLE_RATE)
    transient_env_tau = 0.7  # ms — very fast decay
    transient_samples = noise(transient_len, seed)
    transient_samples = highpass(transient_samples, 500.0)
    transient_samples = lowpass(transient_samples, lowpass_hz, poles=2)
    transient_gain = 10 ** (transient_db / 20.0)
    tau_s = max(1.0, transient_env_tau / 1000.0 * SAMPLE_RATE)
    transient_out = [
        transient_samples[i] * math.exp(-i / tau_s) * transient_gain
        for i in range(transient_len)
    ] + [0.0] * (length - transient_len)

    mixed = mix(*components, transient_out)
    # Final low-pass to take any remaining harshness off the top end.
    mixed = lowpass(mixed, lowpass_hz, poles=2)
    mixed = hann_fade(mixed, fade_ms=1.5)
    return mixed


def synth_light_click(seed: int) -> list[float]:
    out = modal_click(LIGHT_MODES, transient_db=-12.0, length_ms=85, seed=seed, lowpass_hz=3_200)
    return normalize(out, peak=0.55)


def synth_mech_click(seed: int) -> list[float]:
    out = modal_click(MECH_MODES, transient_db=-6.0, length_ms=110, seed=seed, lowpass_hz=4_200)
    return normalize(out, peak=0.72)


# ----- Pack construction ------------------------------------------------

KEY_SPACE = 49
KEY_ENTER = 36
KEY_BACKSPACE = 51
KEY_TAB = 48


def build_pack(name: str, author: str, synth, root: Path) -> None:
    folder = root / f"{name}.clickpack"
    if folder.exists():
        for child in sorted(folder.rglob("*"), reverse=True):
            if child.is_file():
                child.unlink()
            elif child.is_dir():
                child.rmdir()
    folder.mkdir(parents=True, exist_ok=True)
    audio = folder / "audio"
    audio.mkdir(exist_ok=True)

    # 5 default variants — more variety = less robotic typing rhythm.
    default_paths = []
    for i in range(5):
        path = audio / f"default-{i + 1}.wav"
        write_wav(path, synth(seed=hash((name, "default", i)) & 0xFFFF))
        default_paths.append(f"audio/{path.name}")

    space_paths = []
    for i in range(3):
        path = audio / f"space-{i + 1}.wav"
        write_wav(path, synth(seed=hash((name, "space", i)) & 0xFFFF))
        space_paths.append(f"audio/{path.name}")

    enter_path = audio / "enter.wav"
    write_wav(enter_path, synth(seed=hash((name, "enter")) & 0xFFFF))

    backspace_path = audio / "backspace.wav"
    write_wav(backspace_path, synth(seed=hash((name, "back")) & 0xFFFF))

    tab_path = audio / "tab.wav"
    write_wav(tab_path, synth(seed=hash((name, "tab")) & 0xFFFF))

    common_key_codes = [
        0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20,
        21, 22, 23, 24, 25, 26, 27, 28, 29, 30, 31, 32, 33, 34, 35, 37, 38, 39,
        40, 41, 42, 43, 44, 45, 46, 47, 50,
    ]
    key_map = {str(k): default_paths for k in common_key_codes}
    key_map[str(KEY_SPACE)] = space_paths
    key_map[str(KEY_ENTER)] = [f"audio/{enter_path.name}"]
    key_map[str(KEY_BACKSPACE)] = [f"audio/{backspace_path.name}"]
    key_map[str(KEY_TAB)] = [f"audio/{tab_path.name}"]

    manifest = {
        "name": name,
        "author": author,
        "version": "1.1.0",
        "defaultSound": default_paths[0],
        "keyMap": key_map,
    }
    (folder / "manifest.json").write_text(json.dumps(manifest, indent=2))
    print(f"  wrote {folder.name}: {len(list(audio.iterdir()))} samples, {len(key_map)} keys mapped")


def main() -> None:
    PACKS_DIR.mkdir(parents=True, exist_ok=True)
    print(f"Generating packs into {PACKS_DIR}")
    build_pack("Click Light", "Click", synth_light_click, PACKS_DIR)
    build_pack("Click Mech",  "Click", synth_mech_click,  PACKS_DIR)
    print("Done.")


if __name__ == "__main__":
    main()
