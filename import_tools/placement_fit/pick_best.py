#!/usr/bin/env python3
"""Combine phase 1 (biome score, from find_placement.lua's stderr-reported
candidates, re-read from /tmp/dest_eval_params.json for the coordinates)
and phase 2 (/tmp/dest_eval_result.json, the real land/water compatibility
check from zzz_dest_eval) into a single ranked report, and print the
recommended placement.

Primary sort key: above_sea_level_water_count (lower = better) -- this is
the proven, validated signature of the water-intrusion bug class (see
HANDOFF.md's round 25/25b/25c writeups: this is literally the metric that
found and explained Tactical Nuke's real bug, and sparse per-chunk-center
sampling was tried and rejected as too easy to miss a localized cluster).
Biome score is reported as context/tiebreaker, not the primary gate --
this fixes the root problem in the OLD pipeline (find_biome_placement.lua),
which only ever looked at biome and never checked real terrain at all.

This script only REPORTS -- it does not touch placement_registry.json or
museum_manifest.json. A human (the project owner) decides whether to
actually commit a candidate; that step is separate and explicit.

Run: python3 pick_best.py [base_display_name]
"""
import json
import sys

RESULT_PATH = "/tmp/dest_eval_result.json"


def main():
	base_name = sys.argv[1] if len(sys.argv) > 1 else "(unspecified base)"
	with open(RESULT_PATH) as f:
		results = json.load(f)

	if isinstance(results, dict) and "error" in results:
		print(f"phase 2 evaluation failed: {results['error']}")
		sys.exit(1)

	# sort by above_sea_level_water_count ascending (primary), biome score
	# descending as tiebreaker (parsed back out of the label)
	def biome_score(r):
		try:
			return float(r["label"].rsplit("_", 1)[-1])
		except (ValueError, IndexError):
			return 0.0

	ranked = sorted(results, key=lambda r: (r.get("above_sea_level_water_count", 1e18), -biome_score(r)))

	print(f"=== Placement candidates for {base_name}, ranked by real water-compatibility ===\n")
	print(f"{'rank':<5}{'anchor':<20}{'above-sea water':<18}{'biome score':<14}{'real-chunk match':<18}")
	for i, r in enumerate(ranked, 1):
		anchor = f"({r['anchor_x']}, {r['anchor_z']})"
		water = r.get("above_sea_level_water_count", "?")
		score = f"{biome_score(r):.3f}"
		match = f"{r.get('real_chunk_match_pct', 0):.1f}%"
		print(f"{i:<5}{anchor:<20}{water:<18}{score:<14}{match:<18}")

	best = ranked[0]
	print(f"\nRecommended: anchor ({best['anchor_x']}, {best['anchor_z']})")
	print(f"  above-sea-level water: {best['above_sea_level_water_count']} nodes "
		f"(rate {best['above_sea_level_water_rate']*100:.3f}% of footprint area)")
	print(f"  biome match score: {biome_score(best):.3f}")
	print(f"  real-chunk land/water match: {best.get('real_chunk_match_pct', 0):.1f}%")
	print("\nThis is a REPORT ONLY -- nothing has been written to "
		"placement_registry.json or museum_manifest.json. Placing this base "
		"here requires a separate, explicit step.")


if __name__ == "__main__":
	main()
