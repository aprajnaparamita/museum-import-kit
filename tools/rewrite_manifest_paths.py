#!/usr/bin/env python3
"""Repoint museum_manifest.json at wherever the WDL repo lives on this machine.

The manifest stores absolute source paths (source_region_dir /
source_base_folder) from the machine that generated it. Everything else in
it -- packing coordinates, chunk bounds, Y offsets -- is machine
independent, so only the path prefix needs changing.

    ./rewrite_manifest_paths.py museum_manifest.json \
        /Users/dara/dev/2b2tmuseum-WDL /root/2b2tmuseum-WDL
"""
import json, sys, os

src_json, old_prefix, new_prefix = sys.argv[1], sys.argv[2], sys.argv[3]
data = json.load(open(src_json))
changed = missing = 0
for e in data:
    for key in ("source_region_dir", "source_base_folder"):
        v = e.get(key)
        if v and v.startswith(old_prefix):
            e[key] = new_prefix + v[len(old_prefix):]
            changed += 1
    d = e.get("source_region_dir")
    if d and not os.path.isdir(d):
        missing += 1
        if missing <= 5:
            print("  MISSING:", d)
json.dump(data, open(src_json, "w"), indent=1)
print(f"rewrote {changed} paths across {len(data)} entries")
print(f"{missing} entries point at directories that do not exist"
      if missing else "all source directories exist")
