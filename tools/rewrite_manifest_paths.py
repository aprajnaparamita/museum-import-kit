#!/usr/bin/env python3
"""Repoint museum_manifest.json at wherever the WDL repo and the kit live.

The manifest stores absolute source paths (source_region_dir /
source_base_folder) from the machine that generated it, plus footprint_path
pointing at the generating machine's kit checkout. Everything else in it --
packing coordinates, chunk bounds, Y offsets -- is machine independent, so
only the path prefixes need changing.

    ./rewrite_manifest_paths.py museum_manifest.json \
        /Users/dara/dev/2b2tmuseum-WDL /srv/museum/2b2tmuseum-WDL \
        /Volumes/Dara/dev/museum-import-kit /srv/museum/museum-import-kit

The footprint args are optional (a caller that only wants WDL paths can
omit them); footprint_path is then left untouched.
"""
import json, sys, os

src_json = sys.argv[1]
wdl_old, wdl_new = sys.argv[2], sys.argv[3]
fp_old = sys.argv[4] if len(sys.argv) > 4 else None
fp_new = sys.argv[5] if len(sys.argv) > 5 else None

data = json.load(open(src_json))
changed = missing_src = missing_fp = 0
for e in data:
    for key in ("source_region_dir", "source_base_folder"):
        v = e.get(key)
        if v and v.startswith(wdl_old):
            e[key] = wdl_new + v[len(wdl_old):]
            changed += 1
    if fp_old and fp_new:
        v = e.get("footprint_path")
        if v and v.startswith(fp_old):
            e["footprint_path"] = fp_new + v[len(fp_old):]
            changed += 1
    d = e.get("source_region_dir")
    if d and not os.path.isdir(d):
        missing_src += 1
        if missing_src <= 5:
            print("  MISSING source_region_dir:", d)
    f = e.get("footprint_path")
    if f and not os.path.isfile(f):
        missing_fp += 1
        if missing_fp <= 5:
            print("  MISSING footprint_path:", f)

json.dump(data, open(src_json, "w"), indent=1)
print(f"rewrote {changed} paths across {len(data)} entries")
print(f"{missing_src} source_region_dir(s) do not exist"
      if missing_src else "all source_region_dir entries exist")
print(f"{missing_fp} footprint_path(s) do not exist"
      if missing_fp else "all footprint_path entries exist")
