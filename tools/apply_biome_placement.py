#!/usr/bin/env python3
"""Apply find_biome_placement.lua's results to museum_manifest.json.

Reads /tmp/biome_placement_results.json (converted from the Lua script's
own /tmp/biome_placement_results.lua output -- see this repo's tools/
find_biome_placement.lua) and updates dest_anchor_x/dest_anchor_z (and the
derived dest_bbox) for each matching base in both the master manifest and
museum-playtest's copy, leaving everything else (dest_y_offset, origin_x/
z, chunk_bounds) untouched -- those aren't affected by WHERE on the biome
map a base lands, only by its own real capture geometry.
"""
import json
import sys

RESULTS_PATH = "/tmp/biome_placement_results.json"
# 2026-09-19: deliberately museum-playtest ONLY. The kit's own
# manifest/museum_manifest.json is a SEPARATE, much larger-scale layout
# (203 overworld entries) for the eventual full museum-world-rescue
# project -- this search only avoids overlap among the bases actually
# passed to it (the museum-playtest 3), so applying its results to the
# master manifest can silently create overlaps with OTHER real bases'
# already-planned positions there. A first run of this script did exactly
# that (Fort Alcazar/cutecurly's City got overwritten with playtest-scale
# coordinates) and had to be manually reverted from the old-bbox values
# this script itself printed before overwriting -- don't repeat it.
MANIFEST_PATHS = [
	"/Users/dara/dev/museum-playtest/museum_manifest.json",
]


def main():
	with open(RESULTS_PATH) as f:
		results = json.load(f)

	for manifest_path in MANIFEST_PATHS:
		try:
			with open(manifest_path) as f:
				manifest = json.load(f)
		except FileNotFoundError:
			print(f"skip (not found): {manifest_path}")
			continue

		updated = 0
		for entry in manifest:
			name = entry.get("display_name")
			if name not in results:
				continue
			r = results[name]
			old_bbox = dict(entry["dest_bbox"])
			width = old_bbox["x_max"] - old_bbox["x_min"]
			height = old_bbox["z_max"] - old_bbox["z_min"]
			entry["dest_anchor_x"] = r["anchor_x"]
			entry["dest_anchor_z"] = r["anchor_z"]
			entry["dest_bbox"] = {
				"x_min": r["anchor_x"],
				"x_max": r["anchor_x"] + width,
				"z_min": r["anchor_z"],
				"z_max": r["anchor_z"] + height,
			}
			print(f"{manifest_path}: {name}")
			print(f"  old bbox: {old_bbox}")
			print(f"  new bbox: {entry['dest_bbox']}  (biome match score {r['score']:.3f})")
			updated += 1

		with open(manifest_path, "w") as f:
			json.dump(manifest, f, indent=1)
		print(f"{manifest_path}: updated {updated} entries\n")


if __name__ == "__main__":
	main()
