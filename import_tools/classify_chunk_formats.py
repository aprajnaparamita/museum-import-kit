"""Classify every manifest source capture as legacy (pre-1.18 numeric
Blocks) or modern (block_states), by peeking at one chunk. Used to scope
the legacy.lua table audit to the captures that actually exercise it.
"""
import json
import struct
import sys
import zlib

sys.path.insert(0, "/Volumes/Dara/dev/luanti/spawnmasons/import_tools")
import nbt

MANIFEST = "/Volumes/Dara/dev/museum-import-kit/manifest/museum_manifest_full.json"


def peek(region_dir):
    import os
    for name in sorted(os.listdir(region_dir)):
        if not name.endswith(".mca"):
            continue
        path = os.path.join(region_dir, name)
        with open(path, "rb") as f:
            data = f.read()
        if len(data) < 4096:
            continue
        for i in range(1024):
            off = struct.unpack(">I", b"\x00" + data[i * 3:i * 3 + 3])[0]
            if off == 0 or off * 4096 + 5 > len(data):
                continue
            start = off * 4096
            length = struct.unpack(">I", data[start:start + 4])[0]
            comp = data[start + 4]
            payload = data[start + 5:start + 4 + length]
            try:
                raw = zlib.decompress(payload) if comp == 2 else payload
                chunk = nbt.parse_buffer(raw)
            except Exception:
                continue
            if "Level" in chunk:
                dv = chunk.get("DataVersion", "?")
                return "legacy(DV %s)" % dv
            secs = chunk.get("sections") or chunk.get("Sections") or []
            for s in secs:
                if "block_states" in s:
                    return "modern(DV %s)" % chunk.get("DataVersion", "?")
                if "Blocks" in s:
                    return "legacy(DV %s)" % chunk.get("DataVersion", "?")
            return "unknown(DV %s)" % chunk.get("DataVersion", "?")
    return "empty"


def main():
    bases = json.load(open(MANIFEST))
    if isinstance(bases, dict):
        bases = bases.get("bases") or bases.get("entries")
    from collections import Counter
    counts = Counter()
    legacy = []
    for b in bases:
        rd = b["source_region_dir"]
        fmt = peek(rd)
        counts[fmt.split("(")[0]] += 1
        if fmt.startswith("legacy"):
            legacy.append((b["display_name"], b["dimension_type"], fmt, rd))
            print("LEGACY\t%s\t%s\t%s\t%s" % (b["display_name"], b["dimension_type"], fmt, rd))
        sys.stderr.write(".") ; sys.stderr.flush()
    sys.stderr.write("\n")
    print(counts, file=sys.stderr)
    with open("/tmp/legacy_captures.tsv", "w") as f:
        for row in legacy:
            f.write("\t".join(row) + "\n")
    print("wrote /tmp/legacy_captures.tsv (%d legacy captures)" % len(legacy))


if __name__ == "__main__":
    main()
