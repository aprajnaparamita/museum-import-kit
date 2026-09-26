"""Audit the pre-1.18 (legacy numeric id) block table in lua_import/legacy.lua
against real capture data.

Background (2026-09-26): a mislabelled id in legacy.lua (153 hopper vs
153 nether_quartz_ore) made ~16k quartz-ore blocks import as hoppers. This
tool provides the evidence to audit the WHOLE table:

  1. (id, meta) histogram over every legacy chunk in the given region dirs
  2. id -> set of TileEntity `id` names seen at blocks of that id
     (TileEntities carry real modern names -- the strongest anchor for
     what a numeric id actually is, e.g. a "minecraft:hopper" TE proves
     which block id hoppers are)
  3. per-id meta value histogram (ores/stones never carry facing metas;
     directional blocks do)

Usage:
  python3 legacy_id_audit.py <region_dir> [<region_dir> ...] [--top N]

Reads capture data read-only; writes nothing.
"""

import argparse
import collections
import gzip
import os
import struct
import sys
import zlib

sys.path.insert(0, "/Volumes/Dara/dev/luanti/spawnmasons/import_tools")
import nbt  # noqa: E402


def iter_region_chunks(region_dir):
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
            if off == 0:
                continue
            start = off * 4096
            if start + 5 > len(data):
                continue
            length = struct.unpack(">I", data[start:start + 4])[0]
            comp = data[start + 4]
            payload = data[start + 5:start + 4 + length]
            try:
                if comp == 2:
                    raw = zlib.decompress(payload)
                elif comp == 1:
                    raw = gzip.decompress(payload)
                else:
                    continue
                yield nbt.parse_buffer(raw)
            except Exception as e:  # corrupt chunk: report and move on
                print("  ! %s chunk %d: %s" % (name, i, e), file=sys.stderr)


def scan(region_dirs):
    id_meta = collections.Counter()          # (id, meta) -> count
    id_counts = collections.Counter()        # id -> count
    id_metas = collections.defaultdict(collections.Counter)  # id -> meta -> count
    id_tes = collections.defaultdict(collections.Counter)    # id -> TE name -> count
    id_sample_pos = {}                       # id -> one (x,y,z) sample
    for region_dir in region_dirs:
        print("scanning %s" % region_dir, file=sys.stderr)
        for chunk in iter_region_chunks(region_dir):
            level = chunk["Level"] if "Level" in chunk else chunk
            tes = {}
            for te in level.get("TileEntities", []):
                tes[(int(te["x"]), int(te["y"]), int(te["z"]))] = str(te.get("id", "?"))
            for sec in level.get("Sections", []):
                blocks = sec.get("Blocks")
                if blocks is None:
                    continue
                data = sec.get("Data", b"")
                sy = int(sec["Y"]) * 16
                base_x = int(level["xPos"]) * 16
                base_z = int(level["zPos"]) * 16
                for i, b in enumerate(blocks):
                    bid = b if isinstance(b, int) else b[0]
                    if bid < 0:
                        bid += 256
                    if bid == 0:
                        continue
                    meta = 0
                    if i // 2 < len(data):
                        meta = (data[i // 2] >> ((i % 2) * 4)) & 0xF
                    id_counts[bid] += 1
                    id_meta[(bid, meta)] += 1
                    id_metas[bid][meta] += 1
                    if bid not in id_sample_pos:
                        y = sy + (i // 256)
                        id_sample_pos[bid] = (base_x + (i % 16), y, base_z + ((i // 16) % 16))
                    te = tes.get((base_x + (i % 16), sy + (i // 256), base_z + ((i // 16) % 16)))
                    if te:
                        id_tes[bid][te] += 1
    return id_counts, id_metas, id_tes, id_sample_pos


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("region_dirs", nargs="+")
    ap.add_argument("--top", type=int, default=0, help="only show ids with >= N blocks")
    args = ap.parse_args()

    id_counts, id_metas, id_tes, id_sample_pos = scan(args.region_dirs)
    id_meta = {(bid, meta): c for bid, mc in id_metas.items() for meta, c in mc.items()}

    print("\n=== id -> count | metas (count) | TileEntity names | sample pos ===")
    for bid in sorted(id_counts):
        if args.top and id_counts[bid] < args.top:
            continue
        metas = " ".join("%d(%d)" % (m, c) for m, c in sorted(id_metas[bid].items()))
        tes = ", ".join("%s x%d" % (n, c) for n, c in id_tes[bid].most_common())
        pos = id_sample_pos[bid]
        print("%4d %10d | %-48s | %-28s | %s" % (bid, id_counts[bid], metas, tes or "-", pos))

    print("\n=== (id, meta) pairs sorted by count ===")
    pairs = sorted(id_meta.items(), key=lambda kv: -kv[1])
    for (bid, meta), c in pairs:
        print("id %4d meta %2d : %d" % (bid, meta, c))


if __name__ == "__main__":
    main()
