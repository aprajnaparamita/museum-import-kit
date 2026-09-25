#!/usr/bin/env python3
"""build_full_manifest.py -- wire the full 205-base museum manifest.

The kit manifest (manifest/museum_manifest.json) carries every base's
placement data (anchors, bboxes, chunk bounds, source paths) but leaves
`footprint_path` empty. This fills it from import_tools/placement_fit/
footprints/ by aggressive name normalization (the manifest names are
file-styled, the footprints punctuation-stripped), verifies the four
already-placed test bases keep their registry display names (so the
resumable batch SKIPS them), and writes the wired manifest.

Usage:
    build_full_manifest.py <out_manifest.json>
"""
import json
import os
import re
import sys
import glob

KIT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
MANIFEST_IN = os.path.join(KIT, "manifest", "museum_manifest.json")
FOOTPRINTS = os.path.join(KIT, "import_tools", "placement_fit", "footprints")

# display names already in the test world's registry, keyed by footprint
# file (the batch skips by display_name -- without these the four placed
# bases would be re-placed under their file-style names).
PLACED_NAMES = {
    "cutecurly_s_City": "cutecurly's City",
    "Tactical_Nuke_2023_09": "Tactical Nuke 2023-09",
    "Fort_Alcazar_2024_04_22_Th3_L1nk_download": "Fort Alcazar 2024-04-22 (Th3_L1nk download)",
    "Dark_Souls_Castle_2015_10_26": "Dark Souls Castle 2015-10-26",
}


def norm(s):
    return re.sub(r"[^a-z0-9]", "", s.lower())


def main():
    out_path = sys.argv[1]
    man = json.load(open(MANIFEST_IN))

    fps = {}
    for p in glob.glob(os.path.join(FOOTPRINTS, "*.json")):
        if p.endswith(".bak"):
            continue
        base = os.path.basename(p)[:-5]
        fps[norm(base)] = (base, p)

    missing = []
    for e in man:
        n = norm(e["display_name"])
        hit = fps.get(n)
        if not hit:
            # try without trailing timestamp ids etc.
            for k, v in fps.items():
                if k.startswith(n) or n.startswith(k):
                    hit = v
                    break
        if not hit:
            missing.append(e["display_name"])
            continue
        base, path = hit
        e["footprint_path"] = path
        # pretty warp/registry names: the manifest's display_name is the
        # footprint's file stem (underscores + a trailing epoch id);
        # humans warp by "Expedition Orion First Portal 2017-12", not
        # that. Known bases keep their established names.
        if base in PLACED_NAMES:
            e["display_name"] = PLACED_NAMES[base]
        else:
            pretty = re.sub(r"[_-]\d{9,}$", "", e["display_name"])
            pretty = pretty.replace("_", " ").strip()
            e["display_name"] = pretty

    if missing:
        print(f"ERROR: {len(missing)} entries have no footprint match:")
        for m in missing[:15]:
            print("  ", m)
        sys.exit(1)

    # Two beloved test bases (Tactical Nuke, Dark Souls Castle) are not
    # part of the museum's 205 packing at all -- append them from the
    # playtest manifest. Their test-strip anchors collide with museum
    # placements there, so translate them into clear space north of the
    # museum extent (the placement machinery is translation-safe: dest =
    # src - origin + anchor).
    pt_path = os.path.join(os.path.dirname(KIT), "museum-playtest", "museum_manifest.json")
    if os.path.exists(pt_path):
        have = {norm(e["display_name"]) for e in man}

        def b_of(e):
            b = e["dest_bbox"]
            return b["x_min"], b["z_min"], b["x_max"], b["z_max"]

        max_x = max(b_of(e)[2] for e in man)
        max_z = max(b_of(e)[3] for e in man)
        cur_x, cur_z = max_x + 1000, min(b_of(e)[1] for e in man)

        for e in json.load(open(pt_path)):
            if norm(e["display_name"]) in have:
                continue
            x1, z1, x2, z2 = b_of(e)
            dx = cur_x - x1
            dz = cur_z - z1
            e["dest_bbox"] = {"x_min": x1 + dx, "z_min": z1 + dz,
                              "x_max": x2 + dx, "z_max": z2 + dz}
            e["dest_anchor_x"] = int(e["dest_anchor_x"]) + dx
            e["dest_anchor_z"] = int(e["dest_anchor_z"]) + dz
            man.append(e)
            print(f"  appended extra base {e['display_name']!r} at "
                  f"anchor ({e['dest_anchor_x']},{e['dest_anchor_z']})")
            cur_z = e["dest_bbox"]["z_max"] + 500

        # overlap assertion over every pair (extras vs museum set)
        for i, a in enumerate(man):
            ax1, az1, ax2, az2 = b_of(a)
            for b in man[i + 1:]:
                # different dimensions are Y-disjoint by construction
                # (End bases live at y ~ -27000) -- X/Z overlap is fine
                if a.get("dimension_type") != b.get("dimension_type"):
                    continue
                bx1, bz1, bx2, bz2 = b_of(b)
                if ax1 <= bx2 and ax2 >= bx1 and az1 <= bz2 and az2 >= bz1:
                    print(f"ERROR: overlap {a['display_name']} / {b['display_name']}")
                    sys.exit(1)
        print("  overlap check: all placements disjoint")

    with open(out_path, "w") as f:
        json.dump(man, f, indent=1)
    renamed = [e["display_name"] for e in man if e["display_name"] in PLACED_NAMES.values()]
    print(f"wrote {len(man)} entries -> {out_path}")
    print(f"  already-placed kept under registry names: {sorted(renamed)}")
    dims = {}
    for e in man:
        dims[e["dimension_type"]] = dims.get(e["dimension_type"], 0) + 1
    print(f"  dimensions: {dims}")


if __name__ == "__main__":
    main()
