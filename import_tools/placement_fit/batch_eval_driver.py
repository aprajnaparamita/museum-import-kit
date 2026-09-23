#!/usr/bin/env python3
"""Driver for the round-27 large-scale fit-check pass: evaluates every
overworld base's CURRENTLY-ASSIGNED position (from the master manifest)
against a dedicated scratch world (~/dev/museum-fitting-world, on
/Volumes/Dara -- never the production world) using
batch_eval_worldmod's sampled above-sea-level-water metric.

Resumable: skips any base already present in
/tmp/batch_eval_results.jsonl. Processes bases in batches (one headless
launch per batch) so a crash only loses the in-progress batch, not the
whole run.
"""
import json
import os
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
MANIFEST_PATH = "/Volumes/Dara/dev/museum-import-kit/manifest/museum_manifest.json"
FOOTPRINTS_DIR = os.path.join(HERE, "footprints")
RESULTS_PATH = "/tmp/batch_eval_results.jsonl"
PARAMS_PATH = "/tmp/batch_eval_params.json"
PROGRESS_PATH = "/tmp/batch_eval_progress.txt"
WORLD_DIR = os.path.expanduser("~/dev/museum-fitting-world")
CONFIG_PATH = os.path.expanduser("~/dev/museum-testrig/conf/playtest.conf")
LUANTI_BIN = os.path.expanduser("~/dev/museum-testrig/bin/luanti")
DEPLOY_WORLDMODS_TARGET = os.path.join(WORLD_DIR, "worldmods", "zzz_batch_eval")
BATCH_SIZE = 15
PER_BATCH_TIMEOUT = 7200  # 2 hour ceiling per batch; ~150-200s/base observed in testing


def sanitize(name):
    import re
    return re.sub(r"[^A-Za-z0-9]+", "_", name).strip("_")


def already_done():
    done = set()
    if os.path.exists(RESULTS_PATH):
        for line in open(RESULTS_PATH):
            line = line.strip()
            if not line:
                continue
            try:
                d = json.loads(line)
                done.add(d["name"])
            except Exception:
                pass
    return done


def main():
    manifest = json.load(open(MANIFEST_PATH))
    overworld = [e for e in manifest if e.get("dimension_type") == "overworld"]
    done = already_done()
    print(f"{len(overworld)} total overworld bases, {len(done)} already evaluated", file=sys.stderr)

    pending = []
    for e in overworld:
        name = e["display_name"]
        if name in done:
            continue
        fp_path = os.path.join(FOOTPRINTS_DIR, f"{sanitize(name)}.json")
        if not os.path.exists(fp_path):
            print(f"SKIP (no footprint): {name}", file=sys.stderr)
            continue
        bb = e["dest_bbox"]
        pending.append({
            "name": name,
            "footprint_path": fp_path,
            "dest_anchor_x": e["dest_anchor_x"],
            "dest_anchor_z": e["dest_anchor_z"],
            "origin_x": e["origin_x"],
            "origin_z": e["origin_z"],
            "dest_y_offset": e["dest_y_offset"],
            "bbox_width": bb["x_max"] - bb["x_min"],
            "bbox_height": bb["z_max"] - bb["z_min"],
        })

    print(f"{len(pending)} bases pending evaluation", file=sys.stderr)

    os.makedirs(os.path.dirname(DEPLOY_WORLDMODS_TARGET), exist_ok=True)

    batch_num = 0
    while pending:
        batch = pending[:BATCH_SIZE]
        pending = pending[BATCH_SIZE:]
        batch_num += 1
        print(f"=== batch {batch_num}: {len(batch)} bases ===", file=sys.stderr)
        for b in batch:
            print(f"  - {b['name']}", file=sys.stderr)

        json.dump({"bases": batch}, open(PARAMS_PATH, "w"))

        # (re)install the worldmod fresh each batch
        subprocess.run(["rm", "-rf", DEPLOY_WORLDMODS_TARGET])
        subprocess.run(["cp", "-R", os.path.join(HERE, "batch_eval_worldmod"), DEPLOY_WORLDMODS_TARGET])

        # Wipe generated terrain between batches (NOT map_meta.txt, which
        # holds the pinned seed -- see this project's whole session of
        # hard-won lessons about that). Each base occupies a unique,
        # non-overlapping bbox, so there's zero reuse value in keeping
        # old bases' generated terrain around, and letting map.sqlite
        # grow unbounded across 200+ bases caused real, measurable I/O
        # slowdown (observed: ~15 bases/hour early on, dropped to ~4/hour
        # once the db passed ~3GB).
        for fname in ("map.sqlite", "mod_storage.sqlite"):
            fpath = os.path.join(WORLD_DIR, fname)
            if os.path.exists(fpath):
                os.remove(fpath)

        logfile = f"/tmp/batch_eval_r{batch_num}.log"
        t0 = time.time()
        try:
            subprocess.run(
                [LUANTI_BIN, "--server", "--config", CONFIG_PATH, "--world", WORLD_DIR,
                 "--gameid", "mineclonia", "--logfile", logfile],
                timeout=PER_BATCH_TIMEOUT, capture_output=True, text=True,
            )
        except subprocess.TimeoutExpired:
            print(f"  batch {batch_num} TIMED OUT after {PER_BATCH_TIMEOUT}s -- killing and moving on", file=sys.stderr)
            subprocess.run(["pkill", "-f", f"world {WORLD_DIR}"])
            time.sleep(3)
        elapsed = time.time() - t0
        print(f"  batch {batch_num} took {elapsed:.0f}s", file=sys.stderr)

        subprocess.run(["rm", "-rf", DEPLOY_WORLDMODS_TARGET])

    print("all pending bases processed", file=sys.stderr)


if __name__ == "__main__":
    main()
