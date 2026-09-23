#!/usr/bin/env python3
"""Batch-run source_footprint.lua across every overworld base in the
master manifest (manifest/museum_manifest.json, 205 entries, 203
overworld + 2 End). Round 27 large-scale fitting-pipeline prep, per
owner request: "run processing on all these bases for the initial
stages to check fit in the seed."

Writes one footprint JSON per base to footprints/<sanitized_name>.json,
skips a base if its footprint file already exists (resumable across
interruptions), and writes a summary log so a partial run can be picked
back up without redoing already-finished bases.
"""
import json
import os
import re
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
MANIFEST_PATH = "/Volumes/Dara/dev/museum-import-kit/manifest/museum_manifest.json"
FOOTPRINTS_DIR = os.path.join(HERE, "footprints")
LOG_PATH = os.path.join(HERE, "batch_footprint_log.jsonl")
PER_BASE_TIMEOUT = 600  # seconds; some bases may have many region files


def sanitize(name):
    return re.sub(r"[^A-Za-z0-9]+", "_", name).strip("_")


def main():
    manifest = json.load(open(MANIFEST_PATH))
    overworld = [e for e in manifest if e.get("dimension_type") == "overworld"]
    print(f"{len(overworld)} overworld bases to process", file=sys.stderr)

    os.makedirs(FOOTPRINTS_DIR, exist_ok=True)
    log_f = open(LOG_PATH, "a")

    for i, entry in enumerate(overworld):
        name = entry["display_name"]
        safe = sanitize(name)
        out_path = os.path.join(FOOTPRINTS_DIR, f"{safe}.json")
        if os.path.exists(out_path):
            print(f"[{i+1}/{len(overworld)}] SKIP (already done): {name}", file=sys.stderr)
            continue

        region_dir = entry["source_region_dir"]
        if not os.path.isdir(region_dir):
            print(f"[{i+1}/{len(overworld)}] MISSING region dir, skipping: {name} -> {region_dir}", file=sys.stderr)
            log_f.write(json.dumps({"name": name, "status": "missing_region_dir", "region_dir": region_dir}) + "\n")
            log_f.flush()
            continue

        print(f"[{i+1}/{len(overworld)}] extracting: {name}", file=sys.stderr)
        t0 = time.time()
        try:
            result = subprocess.run(
                ["luajit", "source_footprint.lua", region_dir, out_path],
                cwd=HERE, capture_output=True, text=True, timeout=PER_BASE_TIMEOUT,
            )
            elapsed = time.time() - t0
            ok = result.returncode == 0 and os.path.exists(out_path)
            status = "ok" if ok else "error"
            print(f"    {status} in {elapsed:.1f}s: {result.stderr.strip().splitlines()[-1] if result.stderr.strip() else ''}", file=sys.stderr)
            log_f.write(json.dumps({
                "name": name, "status": status, "elapsed_s": round(elapsed, 1),
                "stderr_tail": result.stderr[-2000:], "returncode": result.returncode,
            }) + "\n")
            log_f.flush()
        except subprocess.TimeoutExpired:
            elapsed = time.time() - t0
            print(f"    TIMEOUT after {elapsed:.1f}s", file=sys.stderr)
            log_f.write(json.dumps({"name": name, "status": "timeout", "elapsed_s": round(elapsed, 1)}) + "\n")
            log_f.flush()
        except Exception as e:
            print(f"    EXCEPTION: {e}", file=sys.stderr)
            log_f.write(json.dumps({"name": name, "status": "exception", "error": str(e)}) + "\n")
            log_f.flush()

    log_f.close()
    print("batch footprint extraction complete", file=sys.stderr)


if __name__ == "__main__":
    main()
