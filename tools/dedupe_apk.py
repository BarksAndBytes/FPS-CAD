#!/usr/bin/env python3
"""Rewrite an APK so every entry name appears once, keeping the last copy.

Godot's Android template already contains lib/arm64-v8a/libc++_shared.so, and the export adds the
extension's copy (built with a newer NDK) beside it. apksigner refuses duplicate names, so keep the
later, newer copy, which older code built against libc++ can also use.

    python3 tools/dedupe_apk.py in.apk out.apk
"""
import sys
import zipfile

src, dst = sys.argv[1], sys.argv[2]
with zipfile.ZipFile(src) as zin:
    infos = zin.infolist()
    last = {i.filename: n for n, i in enumerate(infos)}
    dropped = [i.filename for n, i in enumerate(infos) if last[i.filename] != n]
    with zipfile.ZipFile(dst, "w") as zout:
        for n, info in enumerate(infos):
            if last[info.filename] == n:
                zout.writestr(info, zin.read(info), compress_type=info.compress_type)
for name in dropped:
    print(f"dropped duplicate {name}")
