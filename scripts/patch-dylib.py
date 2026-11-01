#!/usr/bin/env python3
"""Patches a tweak dylib's dependencies and rpaths for LiveContainer/sideloading.

1. Rewrites hardcoded CydiaSubstrate paths to @rpath/CydiaSubstrate.framework/CydiaSubstrate.
2. Removes all duplicate LC_RPATH load commands (preventing dyld4 duplicate LC_RPATH aborts).
3. Ensures essential rpaths (@loader_path, @loader_path/Frameworks, @executable_path/Frameworks)
   exist uniquely without duplicates.

Usage:
    python3 scripts/patch-dylib.py <path_to_dylib> [output_path]
"""
import struct
import sys
from pathlib import Path

MH_MAGIC_64 = 0xFEEDFACF
LC_SEGMENT_64 = 0x19
LC_LOAD_DYLIB = 0x0C
LC_LOAD_WEAK_DYLIB = 0x80000018
LC_REEXPORT_DYLIB = 0x8000001F
LC_RPATH = 0x8000001C

OLD_TARGETS = [
    b"/Library/Frameworks/CydiaSubstrate.framework/CydiaSubstrate",
    b"/usr/lib/libsubstrate.dylib",
]
NEW_TARGET = b"@rpath/CydiaSubstrate.framework/CydiaSubstrate"
DESIRED_RPATHS = [
    "@loader_path",
    "@loader_path/Frameworks",
    "@executable_path/Frameworks",
]


def make_rpath_cmd(path: str) -> bytes:
    b = path.encode("utf-8") + b"\0"
    cmdsize = 12 + len(b)
    if cmdsize % 8 != 0:
        cmdsize += 8 - (cmdsize % 8)
    pad = cmdsize - 12 - len(b)
    return struct.pack("<III", LC_RPATH, cmdsize, 12) + b + (b"\0" * pad)


def patch_dylib(input_path, output_path=None):
    p = Path(input_path)
    if not p.is_file():
        sys.exit(f"Error: {input_path} does not exist.")
    data = bytearray(p.read_bytes())
    if len(data) < 32:
        sys.exit(f"Error: {input_path} is too small to be a valid Mach-O binary.")

    magic = struct.unpack_from("<I", data, 0)[0]
    if magic != MH_MAGIC_64:
        sys.exit(f"Error: {input_path} is not an arm64 64-bit Mach-O binary (magic={hex(magic)}).")

    ncmds, sizeofcmds = struct.unpack_from("<II", data, 16)
    offset = 32
    seen_rpaths = set()
    rpaths_to_remove = []
    min_fileoff = len(data)
    substrate_patched = 0

    for _ in range(ncmds):
        if offset >= 32 + sizeofcmds:
            break
        cmd, cmdsize = struct.unpack_from("<II", data, offset)

        if cmd == LC_SEGMENT_64:
            fileoff = struct.unpack_from("<Q", data, offset + 40)[0]
            if 0 < fileoff < min_fileoff:
                min_fileoff = fileoff
            nsects = struct.unpack_from("<I", data, offset + 64)[0]
            sect_off = offset + 72
            for _ in range(nsects):
                s_offset = struct.unpack_from("<I", data, sect_off + 40)[0]
                if 0 < s_offset < min_fileoff:
                    min_fileoff = s_offset
                sect_off += 80

        elif cmd in (LC_LOAD_DYLIB, LC_LOAD_WEAK_DYLIB, LC_REEXPORT_DYLIB):
            name_offset = struct.unpack_from("<I", data, offset + 8)[0]
            str_start = offset + name_offset
            raw_str = bytes(data[str_start:offset + cmdsize]).split(b"\0")[0]
            for old in OLD_TARGETS:
                if raw_str == old:
                    assert len(NEW_TARGET) <= len(raw_str), "Replacement string exceeds original slot size"
                    replacement = NEW_TARGET + b"\0" * (len(raw_str) - len(NEW_TARGET))
                    data[str_start:str_start + len(raw_str)] = replacement
                    substrate_patched += 1
                    break

        elif cmd == LC_RPATH:
            path_offset = struct.unpack_from("<I", data, offset + 8)[0]
            rpath_str = bytes(data[offset + path_offset:offset + cmdsize]).split(b"\0")[0].decode("utf-8", errors="replace")
            if rpath_str in seen_rpaths:
                rpaths_to_remove.append((offset, cmdsize, rpath_str))
            else:
                seen_rpaths.add(rpath_str)

        offset += cmdsize

    # Remove duplicate LC_RPATHs from back to front
    for cmd_offset, cmdsize, rpath_str in reversed(rpaths_to_remove):
        print(f"Removing duplicate LC_RPATH: '{rpath_str}' at offset {cmd_offset} (size {cmdsize})")
        end_of_cmds = 32 + sizeofcmds
        tail = data[cmd_offset + cmdsize:end_of_cmds]
        data[cmd_offset:cmd_offset + len(tail)] = tail
        data[end_of_cmds - cmdsize:end_of_cmds] = b"\0" * cmdsize
        ncmds -= 1
        sizeofcmds -= cmdsize

    struct.pack_into("<II", data, 16, ncmds, sizeofcmds)

    # Ensure desired rpaths exist uniquely
    for path in DESIRED_RPATHS:
        if path not in seen_rpaths:
            cmd_bytes = make_rpath_cmd(path)
            cmdsize = len(cmd_bytes)
            if 32 + sizeofcmds + cmdsize <= min_fileoff:
                data[32 + sizeofcmds:32 + sizeofcmds + cmdsize] = cmd_bytes
                ncmds += 1
                sizeofcmds += cmdsize
                struct.pack_into("<II", data, 16, ncmds, sizeofcmds)
                seen_rpaths.add(path)
                print(f"Added missing LC_RPATH: '{path}' (size {cmdsize})")
            else:
                print(f"Warning: no header space to add LC_RPATH '{path}' (limit={min_fileoff})")

    out = output_path or input_path
    Path(out).write_bytes(data)
    print(f"==> Patched {out}: CydiaSubstrate={substrate_patched}, duplicates removed={len(rpaths_to_remove)}, final rpaths={sorted(seen_rpaths)}")


if __name__ == "__main__":
    if len(sys.argv) < 2:
        print("Usage: python3 scripts/patch-dylib.py <spotifyglass.dylib> [output.dylib]")
        sys.exit(1)
    inp = sys.argv[1]
    outp = sys.argv[2] if len(sys.argv) > 2 else inp
    patch_dylib(inp, outp)
