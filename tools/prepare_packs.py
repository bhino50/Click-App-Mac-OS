"""
Prepare downloaded Mechvibes pack zips for bundling with Click.

Mechvibes packs ship as `.ogg` audio plus a `config.json` index. AVFoundation
on macOS does not read Ogg Vorbis natively, so we transcode each pack's audio
file to WAV using ffmpeg and rewrite the config to point at the new file. The
defines (start/duration sample slicing) stay unchanged because they're in
milliseconds, not byte offsets.

After running, packs are dropped into Resources/DefaultPacks/ as folders named
after their `name` field, suffixed with `.clickpack` so the loader picks them
up via the Mechvibes adapter.

Usage:

    python3 tools/prepare_packs.py
"""

from __future__ import annotations

import json
import os
import re
import shutil
import subprocess
import sys
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
DOWNLOADS = ROOT / "build" / "pack-downloads"
PACKS_OUT = ROOT / "Resources" / "DefaultPacks"
FFMPEG = "/opt/homebrew/bin/ffmpeg"

# Minimum reasonable size for a real pack's audio bundle.
MIN_ZIP_BYTES = 100_000


def sanitize(name: str) -> str:
    """Make a filesystem-friendly folder name from a pack display name."""
    safe = re.sub(r"[^A-Za-z0-9 _\-]", "", name).strip()
    return safe or "Pack"


def ogg_to_wav(ogg: Path, wav: Path) -> bool:
    if wav.exists():
        wav.unlink()
    res = subprocess.run(
        [FFMPEG, "-y", "-loglevel", "error", "-i", str(ogg), str(wav)],
        capture_output=True,
    )
    if res.returncode != 0:
        print(f"  ffmpeg failed: {res.stderr.decode(errors='replace').strip()}")
        return False
    return True


def prepare_zip(zip_path: Path) -> bool:
    if zip_path.stat().st_size < MIN_ZIP_BYTES:
        print(f"  {zip_path.name}: too small ({zip_path.stat().st_size} bytes), skipping")
        return False

    work = DOWNLOADS / f"_extract_{zip_path.stem}"
    if work.exists():
        shutil.rmtree(work)
    work.mkdir(parents=True)

    try:
        with zipfile.ZipFile(zip_path) as zf:
            zf.extractall(work)
    except zipfile.BadZipFile:
        print(f"  {zip_path.name}: corrupt zip, skipping")
        shutil.rmtree(work)
        return False

    # Locate config.json (may be at root or one level down)
    config_path = next(work.rglob("config.json"), None)
    if config_path is None:
        print(f"  {zip_path.name}: no config.json, skipping")
        shutil.rmtree(work)
        return False

    config = json.loads(config_path.read_text())
    pack_dir = config_path.parent
    display_name = config.get("name") or zip_path.stem

    # Single-file packs reference one audio file via "sound"; multi-file packs
    # list per-key files via "defines". OGG needs transcoding to WAV; existing
    # WAV files are kept as-is. A pack with neither is a packaging error.
    oggs = list(pack_dir.rglob("*.ogg"))
    existing_wavs = list(pack_dir.rglob("*.wav"))

    for ogg in oggs:
        wav = ogg.with_suffix(".wav")
        if ogg_to_wav(ogg, wav):
            ogg.unlink()

    if not oggs and not existing_wavs:
        print(f"  {display_name}: no usable audio files, skipping")
        shutil.rmtree(work)
        return False

    # Update config.json to point at .wav instead of .ogg
    if isinstance(config.get("sound"), str):
        config["sound"] = config["sound"].rsplit(".", 1)[0] + ".wav"

    defines = config.get("defines")
    if isinstance(defines, dict):
        rewritten = {}
        for k, v in defines.items():
            if isinstance(v, str):
                rewritten[k] = v.rsplit(".", 1)[0] + ".wav"
            else:
                rewritten[k] = v
        config["defines"] = rewritten

    config_path.write_text(json.dumps(config, indent=2))

    # Drop into the output dir
    out_name = sanitize(display_name) + ".clickpack"
    out_dir = PACKS_OUT / out_name
    if out_dir.exists():
        shutil.rmtree(out_dir)
    shutil.copytree(pack_dir, out_dir)
    shutil.rmtree(work)
    sizes = sum(p.stat().st_size for p in out_dir.rglob("*") if p.is_file())
    print(f"  installed: {out_name} ({sizes // 1024} KB)")
    return True


def main() -> int:
    if not Path(FFMPEG).exists():
        print(f"ffmpeg not found at {FFMPEG}")
        return 1

    PACKS_OUT.mkdir(parents=True, exist_ok=True)
    zips = sorted(DOWNLOADS.glob("*.zip"))
    if not zips:
        print(f"No zips found in {DOWNLOADS}")
        return 1

    print(f"Preparing {len(zips)} pack(s):")
    ok = 0
    for z in zips:
        print(f"- {z.name}")
        if prepare_zip(z):
            ok += 1

    print(f"Done. {ok}/{len(zips)} packs installed into {PACKS_OUT}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
