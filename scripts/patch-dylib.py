#!/usr/bin/env python3
"""Patches a tweak dylib's CydiaSubstrate dependency path for LiveContainer/sideloading.

Usage:
    python scripts/patch-dylib.py <path_to_dylib> [output_path]
"""
import struct
import sys
from pathlib import Path

LC_LOAD_DYLIB = 0xC
LC_LOAD_WEAK_DYLIB = 0x80000018
LC_REEXPORT_DYLIB = 0x8000001F

OLD_TARGETS = [
    b"/Library/Frameworks/CydiaSubstrate.framework/CydiaSubstrate",
    b"/usr/lib/libsubstrate.dylib",
]
NEW_TARGET = b"@rpath/CydiaSubstrate.framework/CydiaSubstrate"


def patch_dylib(input_path, output_path=None):
    data = bytearray(Path(input_path).read_bytes())
    if len(data) < 32:
        sys.exit(f"Error: {input_path} is too small to be a valid Mach-O binary.")

    magic = struct.unpack_from("<I", data, 0)[0]
    if magic != 0xFEEDFACF:
        sys.exit(f"Error: {input_path} is not an arm64 64-bit Mach-O binary (magic={hex(magic)}).")

    ncmds, sizeofcmds = struct.unpack_from("<II", data, 16)
    off = 32
    patched = 0

    for _ in range(ncmds):
        if off >= len(data):
            break
        cmd, cmdsize = struct.unpack_from("<II", data, off)
        if cmd in (LC_LOAD_DYLIB, LC_LOAD_WEAK_DYLIB, LC_REEXPORT_DYLIB):
            name_offset = struct.unpack_from("<I", data, off + 8)[0]
            str_start = off + name_offset
            raw_str = bytes(data[str_start:off + cmdsize]).split(b"\0")[0]
            for old in OLD_TARGETS:
                if raw_str == old:
                    print(f"Found match: {raw_str.decode()} -> {NEW_TARGET.decode()}")
                    # New target is 46 bytes, old target is 58 bytes (fits inside the cmdsize slot)
                    assert len(NEW_TARGET) <= len(raw_str), "Replacement string exceeds original slot size"
                    replacement = NEW_TARGET + b"\0" * (len(raw_str) - len(NEW_TARGET))
                    data[str_start:str_start + len(raw_str)] = replacement
                    patched += 1
                    break
        off += cmdsize

    out = output_path or input_path
    Path(out).write_bytes(data)
    if patched:
        print(f"Successfully patched {patched} load command(s) in {out}!")
    else:
        print(f"No CydiaSubstrate hardcoded path found in {input_path} (already patched or not present).")


if __name__ == "__main__":
    if len(sys.argv) < 2:
        print("Usage: python scripts/patch-dylib.py <spotifyglass.dylib> [output.dylib]")
        sys.exit(1)
    inp = sys.argv[1]
    outp = sys.argv[2] if len(sys.argv) > 2 else inp
    patch_dylib(inp, outp)
