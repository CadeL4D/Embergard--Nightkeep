#!/usr/bin/env python3
"""Verify that an exported pack contains the files the game reads at RUNTIME.

Why this exists
---------------
The smoke test runs from source, where every file is on disk, so it structurally cannot catch a
file that the *exporter* drops. One did: `content/locale/embergard.csv.import` had
`importer="csv_translation"`, which makes Godot treat the CSV as the source of an imported resource
and ship only the generated `.translation`. The Locale autoload reads the CSV itself, so on device it
found nothing, registered zero translations, and every label and button in the game rendered as its
own key — `UI_NEW_WORLD`, `RESOURCE_WOOD`, all of it. In the editor it was invisible.

Anything the game opens with FileAccess rather than load() has this exposure. Check the pack, not the
project.

Usage
-----
    godot --headless --path . --export-pack "iOS" build/verify/test.pck
    python tools/verify_export.py build/verify/test.pck

Exits non-zero on failure, so it can gate a release.
"""
from __future__ import annotations

import csv
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent

# Files read via FileAccess at runtime, so they must be present VERBATIM rather than as an
# imported artefact. Add to this list whenever the game learns to read another raw file.
REQUIRED_PATHS = [
    "res://content/locale/embergard.csv",
]

# Directories whose .tres content must all be present, since the catalogs scan them at runtime.
REQUIRED_CONTENT_DIRS = [
    "content/jobs", "content/buildings", "content/powers",
    "content/monsters", "content/difficulties", "content/tomes", "content/blight",
]


def main(argv: list[str]) -> int:
    if len(argv) != 2:
        print(__doc__)
        return 2
    pack = pathlib.Path(argv[1])
    if not pack.is_file():
        print(f"FAIL  no pack at {pack}")
        return 1

    data = pack.read_bytes()
    print(f"pack: {pack}  ({len(data):,} bytes)\n")
    failures = 0

    # --- raw files the game opens itself -------------------------------------------------
    for path in REQUIRED_PATHS:
        present = path.encode("utf-8") in data
        print(f"  {'ok  ' if present else 'FAIL'}  {path}")
        failures += not present

    # --- and their CONTENT, not just their path in the index -----------------------------
    # A path can appear in the index while the payload is an imported stub, so the strings the
    # player actually reads are checked directly.
    locale = ROOT / "content/locale/embergard.csv"
    if locale.is_file():
        rows = [r for r in csv.reader(locale.read_text(encoding="utf-8").splitlines())
                if len(r) > 1 and r[0] and not r[0].startswith("#")]
        found = sum(1 for r in rows if r[1] and r[1].encode("utf-8") in data)
        ratio = found / max(len(rows), 1)
        ok = ratio > 0.95
        print(f"  {'ok  ' if ok else 'FAIL'}  {found}/{len(rows)} translated values stored verbatim")
        failures += not ok

    # --- content catalogs ----------------------------------------------------------------
    print()
    paths = {m.group(0).decode("utf-8", "replace")
             for m in re.finditer(rb"res://[\x20-\x7e]{3,120}", data)}
    for rel in REQUIRED_CONTENT_DIRS:
        src = ROOT / rel
        if not src.is_dir():
            continue
        want = {f"res://{rel}/{f.name}" for f in src.glob("*.tres")}
        # Exported resources may be listed with a .remap suffix.
        have = {p for p in want if p in paths or f"{p}.remap" in paths}
        ok = len(have) == len(want)
        print(f"  {'ok  ' if ok else 'FAIL'}  {rel}: {len(have)}/{len(want)} defs")
        if not ok:
            for missing in sorted(want - have):
                print(f"          missing {missing}")
        failures += not ok

    print()
    if failures:
        print(f"{failures} problem(s) — this build would misbehave on device")
        return 1
    print("pack contains everything the game reads at runtime")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
