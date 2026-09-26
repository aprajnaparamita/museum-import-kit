#!/bin/bash
# regen_footprints.sh -- regenerate old-format footprints with the current
# source_footprint.lua. 201 of 207 corpus footprints were built by an
# older tool that recorded ONE height per 16x16 chunk (no cols/solid_cols/
# terrain_cols); the merge's seam pins and height targets then work from
# chunk-quantized levels -- the owner's "square edges", "pyramid",
# "lines of sand/gravel" (2026-09-25). The current tool records the
# per-column solid floor, which is what seam matching needs.
set -u
KIT=/Volumes/Dara/dev/museum-import-kit
FP="$KIT/import_tools/placement_fit/footprints"
MANIFEST=/Users/dara/dev/museum-fullimport_manifest.json
OUT=/tmp/footprint_regen.log
: > "$OUT"

python3 - "$MANIFEST" "$FP" > /tmp/footprint_regen_jobs.txt <<'EOF'
import json, sys, os
man = json.load(open(sys.argv[1]))
fpdir = sys.argv[2]
for e in man:
    path = e.get('footprint_path')
    if not path:
        continue
    try:
        d = json.load(open(path))
        if all(c.get('terrain_cols') for c in d['chunks']):
            continue  # already full format
    except Exception:
        pass
    print(e['source_region_dir'] + '\t' + path)
EOF

echo "jobs: $(wc -l < /tmp/footprint_regen_jobs.txt)" >> "$OUT"
cd "$KIT/import_tools/placement_fit"
while IFS=$'\t' read -r region path; do
    echo "=== $(basename "$path")" >> "$OUT"
    luajit source_footprint.lua "$region" "$path" >> "$OUT" 2>&1
done < /tmp/footprint_regen_jobs.txt
echo "ALL FOOTPRINTS DONE" >> "$OUT"
