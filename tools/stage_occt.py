#!/usr/bin/env python3
"""Copy the Open CASCADE runtime libraries the extension needs into godot/bin/ and list them in
godot/bin/fpcad.gdextension so Godot exports them with the game.

    python3 tools/stage_occt.py --occt <occt install prefix> --platform linux|windows|android

Open CASCADE stays a set of shared libraries beside the extension, which keeps the app within
the LGPL (users can swap in a rebuilt Open CASCADE).
"""

import argparse
import glob
import os
import re
import shutil
import sys

# The toolkits the extension loads, directly or through other toolkits (Open CASCADE 8.0).
TOOLKITS = [
    "TKernel", "TKMath", "TKG2d", "TKG3d", "TKGeomBase", "TKBRep", "TKGeomAlgo", "TKTopAlgo",
    "TKPrim", "TKBO", "TKBool", "TKFillet", "TKMesh", "TKShHealing", "TKHLR", "TKXSBase", "TKDE",
    "TKDESTEP", "TKDEIGES", "TKDESTL", "TKLCAF", "TKCAF", "TKCDF", "TKXCAF", "TKService", "TKV3d",
    "TKVCAF",
]

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
BIN = os.path.join(ROOT, "godot", "bin")
MANIFEST = os.path.join(BIN, "fpcad.gdextension")


def find(prefix: str, platform: str, tk: str) -> list:
    """Returns the files for one toolkit: the real library and, on Linux, its soname link."""
    if platform == "windows":
        hits = glob.glob(os.path.join(prefix, "**", tk + ".dll"), recursive=True)
        return hits[:1]
    hits = sorted(glob.glob(os.path.join(prefix, "**", "lib" + tk + ".so*"), recursive=True))
    if platform == "android":
        plain = [h for h in hits if h.endswith(".so")]
        return plain[:1]
    # Linux: the extension asks for libTKx.so.8.0, which points at libTKx.so.8.0.N.
    return [h for h in hits if re.search(r"\.so\.\d+\.\d+$", h)][:1]


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--occt", required=True, help="Open CASCADE install prefix")
    ap.add_argument("--platform", required=True, choices=["linux", "windows", "android"])
    ap.add_argument("--arch", default=None, help="x86_64 or arm64 (default depends on platform)")
    ap.add_argument("--extra", action="append", default=[],
                    help="another runtime library to stage, e.g. the NDK's libc++_shared.so")
    args = ap.parse_args()
    arch = args.arch or ("arm64" if args.platform == "android" else "x86_64")
    # Same folder as the extension: Linux finds them through $ORIGIN, Windows through the
    # extension DLL's own directory, and Android packs every .so into the APK's lib folder.
    dest = BIN

    staged = []
    missing = []
    for tk in TOOLKITS:
        files = find(args.occt, args.platform, tk)
        if not files:
            missing.append(tk)
            continue
        for f in files:
            out = os.path.join(dest, os.path.basename(f))
            shutil.copy2(os.path.realpath(f), out)
            staged.append(out)
    for f in args.extra:
        out = os.path.join(dest, os.path.basename(f))
        shutil.copy2(os.path.realpath(f), out)
        staged.append(out)
    if missing:
        print("missing toolkits: " + ", ".join(missing), file=sys.stderr)
        return 1

    # Rewrite this platform's line in [dependencies], keeping the others.
    with open(MANIFEST, encoding="utf-8") as fh:
        text = fh.read()
    head, _, deps = text.partition("[dependencies]")
    key = f"{args.platform}.{arch}"
    lines = [l for l in deps.splitlines() if l.strip() and not l.startswith(key + " ")]
    entries = ", ".join(
        f'"res://bin/{os.path.basename(p)}": ""' for p in sorted(staged))
    lines.append(f"{key} = {{ {entries} }}")
    with open(MANIFEST, "w", encoding="utf-8") as fh:
        fh.write(head + "[dependencies]\n\n" + "\n".join(lines) + "\n")
    print(f"staged {len(staged)} libraries into {os.path.relpath(dest, ROOT)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
