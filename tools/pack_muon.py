#!/usr/bin/env python3
"""Pack a Muon (WGSL) folder into a .hshader with forward-slash entry names.

    python pack_muon.py muon-0.4.0 muon-0.4.0.hshader
"""
from __future__ import annotations

import sys
import zipfile
from pathlib import Path


def main() -> int:
    if len(sys.argv) != 3:
        print(__doc__)
        return 2
    src = Path(sys.argv[1])
    out = Path(sys.argv[2])
    if not (src / "horizon-shaders.toml").is_file():
        raise SystemExit(f"{src} has no horizon-shaders.toml")
    with zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED) as z:
        for f in sorted(src.rglob("*")):
            if f.is_file():
                z.write(f, f.relative_to(src).as_posix())
    print(f"wrote {out} ({out.stat().st_size} bytes)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
