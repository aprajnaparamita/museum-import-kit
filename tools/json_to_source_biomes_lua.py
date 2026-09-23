#!/usr/bin/env python3
"""One-off: convert /tmp/source_biomes.json (from import_tools/biome_survey.py)
into tools/source_biomes.lua, the data file find_biome_placement.lua reads."""
import json

with open("/tmp/source_biomes.json") as f:
    data = json.load(f)

lines = ["return {"]
for name, v in data.items():
    lines.append(f"  [{json.dumps(name)}] = {{")
    lines.append(f"    width = {v['width']}, height = {v['height']},")
    lines.append("    counts = {")
    for biome, count in v["counts"].items():
        lines.append(f"      [{json.dumps(biome)}] = {count},")
    lines.append("    },")
    lines.append("  },")
lines.append("}")

with open("/Volumes/Dara/dev/museum-import-kit/tools/source_biomes.lua", "w") as f:
    f.write("\n".join(lines) + "\n")
print("wrote tools/source_biomes.lua")
