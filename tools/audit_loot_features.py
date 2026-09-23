#!/usr/bin/env python3
"""
audit_loot_features.py -- one-shot audit of the 2b2tmuseum-WDL corpus.

Counts things in the world captures that the current importer silently
drops, so we know whether the work to support them is worth doing before
the vast.ai re-import runs:

  * item frames & glow item frames (block_entities, post-1.14)
  * item frames & glow item frames (entities, 1.13 and earlier)
  * paintings (entities) and which motive
  * named anything (CustomName set on an entity)
  * tamed mobs (OwnerUUID set -- wolves, cats, parrots, horses, ...)
  * 'owned' projectiles (Owner set with no UUID -- fireworks, arrows,
    tridents; tracked separately so they don't masquerade as pets)
  * the items held inside item frames -- tells us whether the frames are
    just decorative random-coloured blocks (=low-value) or part of a
    deliberate map-art install (=high-value, must get exact).

Walks <wdl-root>/WDL/<year>/<base>/{region,entities}/r.<x>.<z>.mca files.
Pure stdlib so this runs anywhere (laptop, vast.ai instance, rescue
world). One-pass: reads region location tables, only inflates present
chunks, only descends into the chunk's block_entities/entities lists and
skips the massive sections[] array entirely.

Usage:
  audit_loot_features.py <wdl-root> [--json PATH] [--limit N] [--quiet]

Output:
  stdout: one line per base + a corpus-totals summary block.
  --json:  full per-base + corpus detail as JSON.
"""

import argparse
import json
import struct
import sys
import zlib
from collections import Counter
from pathlib import Path

# ---------------------------------------------------------------------------
# Streaming NBT reader
# ---------------------------------------------------------------------------
#
# Bedrock/Edition-independent NBT (works for any modern Minecraft chunk).
# The reader only materializes values we explicitly request; for the chunk
# itself we walk the root compound and skip every field except block_entities
# and entities (and, inside those entries, we skip sub-fields we don't care
# about). That's what keeps the audit fast on a 13 GB corpus.
#
# A note on licensing: this format is documented at
# https://wiki.vg/NBT and isn't anyone's copyright. The reader is the
# minimum subset that the audit needs (compound / list / primitive types 1-12,
# Long Array type 12), written from scratch for this tool.

TAG_End = 0
TAG_Byte = 1
TAG_Short = 2
TAG_Int = 3
TAG_Long = 4
TAG_Float = 5
TAG_Double = 6
TAG_Byte_Array = 7
TAG_String = 8
TAG_List = 9
TAG_Compound = 10
TAG_Int_Array = 11
TAG_Long_Array = 12


class NBTReader:
    """Streaming reader over an in-memory NBT byte buffer."""

    __slots__ = ("buf", "pos", "len")

    def __init__(self, buf, pos=0):
        self.buf = buf
        self.pos = pos
        self.len = len(buf)

    def _need(self, n):
        if self.pos + n > self.len:
            raise ValueError(f"NBT read past end at {self.pos}+{n} (len {self.len})")

    def read_byte(self):
        self._need(1)
        b = self.buf[self.pos]
        self.pos += 1
        return b

    def read_short(self):
        self._need(2)
        v = (self.buf[self.pos] << 8) | self.buf[self.pos + 1]
        self.pos += 2
        if v >= 0x8000:
            v -= 0x10000
        return v

    def read_ushort(self):
        self._need(2)
        v = (self.buf[self.pos] << 8) | self.buf[self.pos + 1]
        self.pos += 2
        return v

    def read_int(self):
        self._need(4)
        v = int.from_bytes(self.buf[self.pos : self.pos + 4], "big", signed=True)
        self.pos += 4
        return v

    def read_long(self):
        self._need(8)
        v = int.from_bytes(self.buf[self.pos : self.pos + 8], "big", signed=True)
        self.pos += 8
        return v

    def read_string(self):
        n = self.read_ushort()
        self._need(n)
        s = self.buf[self.pos : self.pos + n].decode("utf-8", errors="replace")
        self.pos += n
        return s

    def skip_value(self, type_id):
        """Advance pos past whatever value of the given type follows."""
        if type_id == TAG_End:
            return  # zero bytes
        if type_id == TAG_Byte:
            self._need(1)
            self.pos += 1
        elif type_id == TAG_Short:
            self._need(2)
            self.pos += 2
        elif type_id == TAG_Int:
            self._need(4)
            self.pos += 4
        elif type_id == TAG_Long:
            self._need(8)
            self.pos += 8
        elif type_id == TAG_Float:
            self._need(4)
            self.pos += 4
        elif type_id == TAG_Double:
            self._need(8)
            self.pos += 8
        elif type_id == TAG_Byte_Array:
            n = self.read_int()
            self._need(n)
            self.pos += n
        elif type_id == TAG_String:
            n = self.read_ushort()
            self._need(n)
            self.pos += n
        elif type_id == TAG_List:
            elem_type = self.read_byte()
            count = self.read_int()
            for _ in range(count):
                self.skip_value(elem_type)
        elif type_id == TAG_Compound:
            while True:
                t = self.read_byte()
                if t == TAG_End:
                    return
                # each tag: type byte, then name (short + bytes), then value
                self.read_string()  # name
                self.skip_value(t)
        elif type_id == TAG_Int_Array:
            n = self.read_int()
            self.pos += n * 4
        elif type_id == TAG_Long_Array:
            n = self.read_int()
            self.pos += n * 8
        else:
            raise ValueError(f"unknown NBT tag type {type_id} at pos {self.pos}")

    def read_value(self, type_id):
        """Materialize the next value of the given type (full parse)."""
        if type_id == TAG_End:
            return None
        if type_id == TAG_Byte:
            return self.read_byte()
        if type_id == TAG_Short:
            return self.read_short()
        if type_id == TAG_Int:
            return self.read_int()
        if type_id == TAG_Long:
            return self.read_long()
        if type_id == TAG_Float:
            self.pos += 4
            return None
        if type_id == TAG_Double:
            self.pos += 8
            return None
        if type_id == TAG_Byte_Array:
            n = self.read_int()
            self.pos += n
            return None
        if type_id == TAG_String:
            return self.read_string()
        if type_id == TAG_List:
            elem_type = self.read_byte()
            count = self.read_int()
            return [self.read_value(elem_type) for _ in range(count)]
        if type_id == TAG_Compound:
            return self.read_compound()
        if type_id == TAG_Int_Array:
            n = self.read_int()
            self.pos += n * 4
            return None
        if type_id == TAG_Long_Array:
            n = self.read_int()
            self.pos += n * 8
            return None
        raise ValueError(f"unknown NBT tag type {type_id} at pos {self.pos}")

    def read_compound(self):
        out = {}
        while True:
            t = self.read_byte()
            if t == TAG_End:
                return out
            name = self.read_string()
            # Peek at the value only if we have a future caller that wants
            # compound-shaped fields; for the audit, we read top-level
            # fields selectively.
            out[name] = self.read_value(t)
        # Unreachable

    # Helpful: read a top-level compound, but as the named field appearing
    # anywhere we encounter it (compounds are unordered for our purposes:
    # we walk the root once and pick out what we want by name).
    def read_root_compound_selective(self, wanted_names, want_lists_of_dicts):
        """
        Read a top-level compound (the chunk root). For each tag:
          - if name is in wanted_names, read it fully (used for Lists of
            Compounds we want to count).
          - otherwise skip its value.
        Returns {name: parsed_value} for the wanted fields.
        """
        out = {}
        while True:
            t = self.read_byte()
            if t == TAG_End:
                return out
            name = self.read_string()
            if name in wanted_names:
                v = self.read_value(t)
                if v is not None:
                    out[name] = v
            else:
                self.skip_value(t)


# ---------------------------------------------------------------------------
# Region file walker
# ---------------------------------------------------------------------------
#
# Minecraft Anvil .mca format:
#   - first 4 KiB: location table, 4 bytes per (32*32=1024) chunk slot
#       byte[0..2] = sector offset (big-endian, relative to file start)
#       byte[3]    = sector count
#   - next 4 KiB: timestamp table (unused for the audit)
#   - sector index 1024 onward: chunk payload
#       first 4 bytes = length (big-endian)
#       byte 5         = compression type (1 gzip, 2 zlib, 3 uncompressed)
#       bytes 6..      = compressed chunk NBT


def region_coords_from_filename(path):
    """Parse r.<rx>.<rz>.mca into (region_x, region_z)."""
    name = path.stem  # e.g. "r.269.3581"
    parts = name.split(".")
    if len(parts) != 3 or parts[0] != "r":
        return None
    try:
        return int(parts[1]), int(parts[2])
    except ValueError:
        return None


def iter_chunks(path):
    """Yield (chunk_x_world, chunk_z_world, inflated_nbt_buf) for each present slot.

    Chunks with empty slots, corrupt length, or unknown compression are
    silently skipped -- this is an audit, not an importer. Opens the
    region file once (not once per chunk) so the on-disk cache keeps
    the second-Nth present slot reads fast.
    """
    rxz = region_coords_from_filename(path)
    if rxz is None:
        return
    rx, rz = rxz

    with open(path, "rb") as f:
        header = f.read(8192)
    if len(header) < 8192:
        return
    slots = []
    for i in range(1024):
        off24 = (header[i * 4] << 16) | (header[i * 4 + 1] << 8) | header[i * 4 + 2]
        sec_count = header[i * 4 + 3]
        if off24 == 0 and sec_count == 0:
            continue
        slots.append((off24, i))
    if not slots:
        return
    with open(path, "rb") as f:
        for off24, i in slots:
            off = off24 * 4096
            f.seek(off)
            length_bytes = f.read(4)
            if len(length_bytes) < 4:
                continue
            length = int.from_bytes(length_bytes, "big")
            if length == 0 or length > 16 * 1024 * 1024:
                continue
            payload = f.read(length)
            if len(payload) < length:
                continue
            if not payload:
                continue
            compression = payload[0]
            compressed = payload[1:]
            try:
                if compression == 2:  # zlib (all modern)
                    inflated = zlib.decompress(compressed)
                elif compression == 1:  # gzip (rare, old)
                    import gzip
                    inflated = gzip.decompress(compressed)
                elif compression == 3:  # uncompressed (very rare)
                    inflated = compressed
                else:
                    continue
            except (zlib.error, OSError):
                continue
            cx_world = rx * 32 + (i & 31)
            cz_world = rz * 32 + (i >> 5)
            yield cx_world, cz_world, inflated


# ---------------------------------------------------------------------------
# Audit logic
# ---------------------------------------------------------------------------
#
# Two chunk formats appear in the corpus:
#   * vanilla pre-1.13: top-level root compound has child "Level" whose
#     children "TileEntities" and "Entities" are the relevant lists.
#   * everything from 1.13 onward (vanilla and WDL-capture):
#       -- vanilla wraps the chunk fields inside a child named "level";
#       -- but the WDL saves chunks with the same fields at the top of
#          the root compound (no "level" wrapper). The list names
#          themselves are the same: block_entities and entities.
# The simplest robust thing is to walk the root compound once, picking
# up whatever list named block_entities / TileEntities / entities /
# Entities appears at *any* depth-zero level. None of the inner lists
# inside sections[] / block_ticks / fluid_ticks share those names, so
# there's no risk of misclassification.
#
# For block entities: we care about the value of "id" (string) on each
# entry and, for item frames, the "Item" compound's "id" field.
# For entities: same -- "id" string and, if "CustomName" / "Owner" /
# "OwnerUUID" are set, those count as named/owned.

INTERESTING_FRAME_IDS = {"minecraft:item_frame", "minecraft:glow_item_frame"}

BLOCK_ENTITY_LIST_NAMES = {"block_entities", "TileEntities"}
ENTITY_LIST_NAMES = {"entities", "Entities"}


def _compound_id(d):
    """Pull the 'id' string from a NBT compound (read as dict)."""
    v = d.get("id")
    if isinstance(v, str):
        return v
    return None


def _count_frame_item(d, out):
    item = d.get("Item")
    if isinstance(item, dict):
        iid = _compound_id(item)
        if iid:
            out["frame_items"][iid] += 1


def _scan_block_entity_list(lst, out):
    if not isinstance(lst, list):
        return
    for d in lst:
        if not isinstance(d, dict):
            continue
        bid = _compound_id(d)
        if bid == "minecraft:item_frame":
            out["frames"] += 1
            _count_frame_item(d, out)
        elif bid == "minecraft:glow_item_frame":
            out["glow_frames"] += 1
            _count_frame_item(d, out)


def _scan_entity_list(lst, out):
    if not isinstance(lst, list):
        return
    for d in lst:
        if not isinstance(d, dict):
            continue
        eid = _compound_id(d)
        if eid == "minecraft:item_frame":
            out["frames"] += 1
            _count_frame_item(d, out)
        elif eid == "minecraft:glow_item_frame":
            out["glow_frames"] += 1
            _count_frame_item(d, out)
        elif eid == "minecraft:painting":
            out["paintings"] += 1
            motive = d.get("Motive") or d.get("variant")
            if isinstance(motive, str) and motive:
                out["painting_motives"][motive] += 1
        if "CustomName" in d:
            out["named"] += 1
            out["named_entity_ids"][eid or "?"] += 1
        # OwnerUUID is the unambiguous tamed-mob marker (wolves, cats,
        # parrots, horses, donkeys, mules, llamas, foxes, axolotls, bees
        # in hives, ...). Many projectiles (firework_rocket, arrow,
        # trident) set a string Owner field but lack UUID -- track them
        # separately as "projectiles" so they don't masquerade as pets
        # in the headline "owned" number.
        if "OwnerUUID" in d:
            out["tamed"] += 1
            out["tamed_entity_ids"][eid or "?"] += 1
        elif "Owner" in d:
            out["owned_by_string"] += 1
            out["owned_by_string_ids"][eid or "?"] += 1


def audit_chunk(inflated):
    """Process one chunk's raw NBT bytes.

    Returns a dict of counters/lists for this chunk's contributions to
    the base totals. We skip the sections[] array entirely (it's the
    giant palette-encoded block-state payload); we only descend into
    the four list-of-interest names wherever they appear at the root
    level of the chunk.
    """
    out = {
        "frames": 0,
        "glow_frames": 0,
        "named": 0,
        "tamed": 0,  # entities with OwnerUUID -- the unambiguous pet marker
        "owned_by_string": 0,  # entities with Owner but no UUID -- usually projectiles
        "paintings": 0,
        "frame_items": Counter(),
        "painting_motives": Counter(),
        "named_entity_ids": Counter(),
        "tamed_entity_ids": Counter(),
        "owned_by_string_ids": Counter(),
    }
    r = NBTReader(inflated)
    try:
        root_type = r.read_byte()
    except ValueError:
        return out
    if root_type != TAG_Compound:
        return out
    try:
        r.read_string()  # root tag name (empty for file-root chunks)
    except ValueError:
        return out

    while True:
        try:
            t = r.read_byte()
        except ValueError:
            return out
        if t == TAG_End:
            return out
        try:
            name = r.read_string()
        except ValueError:
            return out
        if name in BLOCK_ENTITY_LIST_NAMES:
            v = r.read_value(t)
            _scan_block_entity_list(v, out)
        elif name in ENTITY_LIST_NAMES:
            v = r.read_value(t)
            _scan_entity_list(v, out)
        else:
            # sections[], block_ticks[], fluid_ticks[], Heightmaps, etc.
            r.skip_value(t)


def audit_base(base_dir):
    """Walk a single base directory, tallying its region + entities files."""
    out = {
        "name": base_dir.name,
        "year": base_dir.parent.name,
        "chunks_visited": 0,
        "frames": 0,
        "glow_frames": 0,
        "paintings": 0,
        "named": 0,
        "tamed": 0,
        "owned_by_string": 0,
        "frame_items": Counter(),
        "painting_motives": Counter(),
        "named_entity_ids": Counter(),
        "tamed_entity_ids": Counter(),
        "owned_by_string_ids": Counter(),
    }
    for sub in ("region", "entities"):
        region_dir = base_dir / sub
        if not region_dir.is_dir():
            continue
        for mca in sorted(region_dir.glob("r.*.*.mca")):
            for _cx, _cz, inflated in iter_chunks(mca):
                out["chunks_visited"] += 1
                per_chunk = audit_chunk(inflated)
                out["frames"] += per_chunk["frames"]
                out["glow_frames"] += per_chunk["glow_frames"]
                out["paintings"] += per_chunk["paintings"]
                out["named"] += per_chunk["named"]
                out["tamed"] += per_chunk["tamed"]
                out["owned_by_string"] += per_chunk["owned_by_string"]
                out["frame_items"] += per_chunk["frame_items"]
                out["painting_motives"] += per_chunk["painting_motives"]
                out["named_entity_ids"] += per_chunk["named_entity_ids"]
                out["tamed_entity_ids"] += per_chunk["tamed_entity_ids"]
                out["owned_by_string_ids"] += per_chunk["owned_by_string_ids"]
    return out


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("wdl_root", type=Path, help="path to the 2b2tmuseum-WDL checkout")
    parser.add_argument("--json", type=Path, help="write full per-base detail to this JSON file")
    parser.add_argument("--limit", type=int, help="process only the first N bases (for smoke-testing)")
    parser.add_argument("--quiet", action="store_true", help="suppress per-base progress lines")
    args = parser.parse_args(argv)

    if not args.wdl_root.is_dir():
        print(f"error: {args.wdl_root} is not a directory", file=sys.stderr)
        return 2

    # WDL/<year>/<base>/... -- we want the <base> directories.
    bases = sorted(
        base
        for year_dir in (args.wdl_root / "WDL").iterdir()
        if year_dir.is_dir()
        for base in year_dir.iterdir()
        if base.is_dir()
    )
    if args.limit:
        bases = bases[: args.limit]

    if not args.quiet:
        print(f"scanning {len(bases)} base directories under {args.wdl_root}/WDL/", file=sys.stderr)

    all_results = []
    for i, base_dir in enumerate(bases):
        result = audit_base(base_dir)
        all_results.append(result)
        if not args.quiet and (
            result["frames"]
            or result["paintings"]
            or result["named"]
            or result["tamed"]
        ):
            extras = []
            if result["named"]:
                extras.append(f"named={result['named']}")
            if result["tamed"]:
                extras.append(f"tamed={result['tamed']}")
            print(
                f"  [{i + 1:3}/{len(bases)}] {result['year']}/{result['name']}: "
                f"chunks={result['chunks_visited']} "
                f"frames={result['frames']}+{result['glow_frames']}g "
                f"paintings={result['paintings']} "
                + " ".join(extras),
                file=sys.stderr,
            )

    # ----- corpus summary line on stdout (the killer yes/no answer) -----
    total_frames = sum(r["frames"] for r in all_results)
    total_glow = sum(r["glow_frames"] for r in all_results)
    total_paint = sum(r["paintings"] for r in all_results)
    total_named = sum(r["named"] for r in all_results)
    total_tamed = sum(r["tamed"] for r in all_results)
    total_by_string = sum(r["owned_by_string"] for r in all_results)
    bases_with_frames = sum(1 for r in all_results if r["frames"] or r["glow_frames"])
    bases_with_paint = sum(1 for r in all_results if r["paintings"])
    bases_with_named = sum(1 for r in all_results if r["named"])
    bases_with_tamed = sum(1 for r in all_results if r["tamed"])

    print(f"\n===== corpus total over {len(all_results)} bases =====")
    print(f"item frames:        {total_frames:>10}  ({bases_with_frames} bases)")
    print(f"glow item frames:   {total_glow:>10}  (subset of above; double-glow frames are uncommon)")
    print(f"paintings:          {total_paint:>10}  ({bases_with_paint} bases)")
    print(f"named (CustomName): {total_named:>10}  ({bases_with_named} bases)")
    print(f"tamed (OwnerUUID):  {total_tamed:>10}  ({bases_with_tamed} bases)")
    print(f"proj.-Owner tagged: {total_by_string:>10}  (fireworks, arrows, tridents -- not pets)")

    # Top 10 frame items -- if these are richly-coloured blocks (concrete,
    # wool, terracotta, glazed terracotta) in non-trivial counts, we very
    # likely have map art to preserve. If they're swords, fireworks, maps,
    # banners, etc., it's decoration.
    all_frame_items = Counter()
    for r in all_results:
        all_frame_items += r["frame_items"]
    if all_frame_items:
        print("\ntop item IDs held inside item frames:")
        for iid, count in all_frame_items.most_common(15):
            print(f"  {count:>10}  {iid}")
    all_motives = Counter()
    for r in all_results:
        all_motives += r["painting_motives"]
    if all_motives:
        print("\npainting motives seen:")
        for motive, count in all_motives.most_common(20):
            print(f"  {count:>5}  {motive}")
    all_named_ids = Counter()
    for r in all_results:
        all_named_ids += r["named_entity_ids"]
    if all_named_ids:
        print("\nnamed-entity counts by id (CustomName):")
        for eid, count in all_named_ids.most_common(15):
            print(f"  {count:>6}  {eid}")
    all_tamed_ids = Counter()
    for r in all_results:
        all_tamed_ids += r["tamed_entity_ids"]
    if all_tamed_ids:
        print("\ntamed-mob counts by id (OwnerUUID):")
        for eid, count in all_tamed_ids.most_common(15):
            print(f"  {count:>6}  {eid}")
    all_string_ids = Counter()
    for r in all_results:
        all_string_ids += r["owned_by_string_ids"]
    if all_string_ids:
        print("\nnon-UUID 'Owner'-tagged entity counts (mostly projectiles):")
        for eid, count in all_string_ids.most_common(10):
            print(f"  {count:>7}  {eid}")

    if args.json:
        # Counter isn't JSON-serializable; convert.
        def _coerce(r):
            return {
                "name": r["name"],
                "year": r["year"],
                "chunks_visited": r["chunks_visited"],
                "frames": r["frames"],
                "glow_frames": r["glow_frames"],
                "paintings": r["paintings"],
                "named": r["named"],
                "tamed": r["tamed"],
                "owned_by_string": r["owned_by_string"],
                "frame_items": dict(r["frame_items"]),
                "painting_motives": dict(r["painting_motives"]),
                "named_entity_ids": dict(r["named_entity_ids"]),
                "tamed_entity_ids": dict(r["tamed_entity_ids"]),
                "owned_by_string_ids": dict(r["owned_by_string_ids"]),
            }
        payload = {
            "wdl_root": str(args.wdl_root),
            "bases_scanned": len(all_results),
            "totals": {
                "frames": total_frames,
                "glow_frames": total_glow,
                "paintings": total_paint,
                "named": total_named,
                "tamed": total_tamed,
                "owned_by_string": total_by_string,
                "bases_with_frames": bases_with_frames,
                "bases_with_paint": bases_with_paint,
                "bases_with_named": bases_with_named,
                "bases_with_tamed": bases_with_tamed,
                "frame_items": dict(all_frame_items),
                "painting_motives": dict(all_motives),
                "named_entity_ids": dict(all_named_ids),
                "tamed_entity_ids": dict(all_tamed_ids),
                "owned_by_string_ids": dict(all_string_ids),
            },
            "bases": [_coerce(r) for r in all_results],
        }
        args.json.write_text(json.dumps(payload, indent=2, sort_keys=True))
        if not args.quiet:
            print(f"\nfull per-base JSON written to {args.json}", file=sys.stderr)

    # Return success unless the answer is "completely empty" -- we just exit 0
    # either way, the caller looks at the numbers.
    return 0


if __name__ == "__main__":
    sys.exit(main())
