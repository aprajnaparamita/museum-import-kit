#!/usr/bin/env python3
"""Build manifest/museum_manifest_sample20.json: a 20-base diagnostic set
(owner 2026-09-28: "a diverse selection of 20 bases ... an even spread
between the dimensions to diagnose issues more effectively").

The corpus has only five non-overworld captures, so the set is all five
plus 15 overworld bases spread across years (2011-2025), sizes and water
share:
  * nether: Hausemaster (full), Taylobase 4 (micro entry);
  * End: Endhaven, Space Valkyria III and Krobar's Interdimensional Bridge,
    each trimmed to its densest 2x2 region window (largest region files)
    under ~/dev/museum-microtest-src/<name>_trim2x2/, like the micro set's
    Endhaven fixture.
Overworld and Hausemaster entries are copied from the full manifest, so
their placements are already disjoint. End placements get one gateway slot
each via build_full_manifest.assign_end_gateway_slots.

Usage: python3 tools/build_sample_manifest.py
"""
import json
import os
import sys

KIT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(KIT, "tools"))
from build_full_manifest import assign_end_gateway_slots  # noqa: E402

FULL = os.path.join(KIT, "manifest", "museum_manifest_full.json")
MICRO = os.path.join(KIT, "manifest", "museum_manifest_micro.json")
OUT = os.path.join(KIT, "manifest", "museum_manifest_sample20.json")
FP = os.path.join(KIT, "import_tools", "placement_fit", "footprints")
FIXTURES = "/Users/dara/dev/museum-microtest-src"
END_DY = -27073

OVERWORLD = [
    "Ponponheads first base 2011-08-09",
    "Ravenholm 2018",
    "upside down pyramid 2013-01-25",
    "Argonath Fortress 2017-11-16",
    "Hopes Retreat 2013-11-21",
    "Tactical Nuke 2023-09",
    "DayTown 2017-10-22",
    "Arnthor base 2018-01-21",
    "IronWeasel's underwater base 2016-08-12",
    "The Fort 2018-01-29",
    "Gomorrah 2017-03",
    "Mesa Mountain HQ 2020-11-22",
    "The Citadel Aug 1st 2024-Mewlificent",
    "Fort Alcazar 2024-04-22 (Th3_L1nk download)",
    "cutecurly's City",
]


def trimmed_end(name, fixture, rx, rz, anchor_x, anchor_z, footprint):
    """An End entry for a 2x2-region fixture whose low corner is region
    (rx, rz): 64x64 chunks, placed with its low corner at the anchor."""
    cx0, cz0 = rx * 32, rz * 32
    return {
        "display_name": name,
        "source_region_dir": os.path.join(FIXTURES, fixture, "region"),
        "source_base_folder": os.path.join(FIXTURES, fixture),
        "dimension_type": "end",
        "origin_x": cx0 * 16,
        "origin_z": cz0 * 16,
        "dest_anchor_x": anchor_x,
        "dest_anchor_z": anchor_z,
        "dest_y_offset": END_DY,
        "chunk_bounds": {"x_min": cx0, "x_max": cx0 + 63, "z_min": cz0, "z_max": cz0 + 63},
        "dest_bbox": {"x_min": anchor_x, "x_max": anchor_x + 1023,
                      "z_min": anchor_z, "z_max": anchor_z + 1023},
        "sampled_block_count": 0,
        "footprint_path": os.path.join(FP, footprint),
    }


def main():
    full = {e["display_name"]: e for e in json.load(open(FULL))}
    micro = {e["display_name"]: e for e in json.load(open(MICRO))}
    man = []
    missing = [n for n in OVERWORLD if n not in full]
    if missing:
        sys.exit(f"not in the full manifest: {missing}")
    man += [full[n] for n in OVERWORLD]
    man.append(full["Hausemaster Base 2012 (Nether)"])
    man.append(micro["Taylobase 4 (Nether)"])
    man.append(micro["Endhaven 2024-11-24 (est. 2022-03-13) (End trim2x2)"])
    # low corners chosen so each trim sits in its own gateway direction
    # (Endhaven ~50 deg, Valkyria ~0 deg, Krobar ~180 deg)
    man.append(trimmed_end("Space Valkyria III (End trim2x2)", "valkyria_trim2x2", 133, -218,
                           4096, -512, "Space_Valkyria_III_End_trim2x2.json"))
    man.append(trimmed_end("Krobar's Interdimensional Bridge (End trim2x2)", "krobar_trim2x2", -357, -663,
                           -5120, -512, "Krobar_s_Interdimensional_Bridge_End_trim2x2.json"))

    for e in man:
        for key in ("source_region_dir", "footprint_path"):
            if not os.path.exists(e[key]):
                sys.exit(f"{e['display_name']}: {key} missing: {e[key]}")
    # same-dimension placements must not overlap
    for i, a in enumerate(man):
        for b in man[i + 1:]:
            if a["dimension_type"] != b["dimension_type"]:
                continue
            ab, bb = a["dest_bbox"], b["dest_bbox"]
            if (ab["x_min"] <= bb["x_max"] and ab["x_max"] >= bb["x_min"]
                    and ab["z_min"] <= bb["z_max"] and ab["z_max"] >= bb["z_min"]):
                sys.exit(f"overlap: {a['display_name']} / {b['display_name']}")
    assign_end_gateway_slots(man)

    with open(OUT, "w") as f:
        json.dump(man, f, indent=1)
    dims = {}
    for e in man:
        dims[e["dimension_type"]] = dims.get(e["dimension_type"], 0) + 1
    print(f"wrote {len(man)} bases -> {OUT}: {dims}")


if __name__ == "__main__":
    main()
