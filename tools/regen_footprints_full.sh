#!/bin/bash
# Regenerate every footprint for manifest/museum_manifest_full.json on this
# machine, into import_tools/placement_fit/footprints/. Resumable: entries
# whose footprint already exists and is non-empty are skipped.
#
# Footprints are .gitignored and regenerable (they are NOT in the kit repo).
# spawnimport silently skips a base's merge when its footprint is missing,
# so every manifest entry needs a real footprint before the import starts.
#
# Usage:
#   WDL=/srv/museum/2b2tmuseum-WDL ./tools/regen_footprints_full.sh
set -u
KIT="$(cd "$(dirname "$0")/.." && pwd)"
MANIFEST="${MANIFEST:-$KIT/manifest/museum_manifest_full.json}"
WDL="${WDL:-/srv/museum/2b2tmuseum-WDL}"
OLD_WDL="${OLD_WDL:-/Users/dara/dev/2b2tmuseum-WDL}"
FP_DIR="$KIT/import_tools/placement_fit/footprints"
LOG="${LOG:-/tmp/footprint_regen.log}"

mkdir -p "$FP_DIR"

python3 - "$MANIFEST" "$WDL" "$OLD_WDL" "$FP_DIR" > /tmp/footprint_regen_jobs.txt <<'PY'
import json, sys, os
man = json.load(open(sys.argv[1]))
wdl, old_wdl, fpdir = sys.argv[2], sys.argv[3], sys.argv[4]
for e in man:
    fp = e.get('footprint_path')
    if not fp:
        continue
    name = os.path.basename(fp)
    out = os.path.join(fpdir, name)
    if os.path.exists(out) and os.path.getsize(out) > 2:
        continue
    region = e.get('source_region_dir', '').replace(old_wdl, wdl)
    if not region or not os.path.isdir(region):
        flag = '__MISSING_DIR__'
    elif e.get('dimension_type') == 'nether':
        flag = 'nether'
    else:
        flag = ''
    print(region + '\t' + out + '\t' + flag)
PY

cd "$KIT/import_tools/placement_fit" || exit 1
total=$(awk -F'\t' '$3 != "__MISSING_DIR__"' /tmp/footprint_regen_jobs.txt | wc -l)
missing=$(awk -F'\t' '$3 == "__MISSING_DIR__"' /tmp/footprint_regen_jobs.txt | wc -l)
echo "jobs: $total, missing source dirs: $missing" | tee "$LOG"
i=0
while IFS=$'\t' read -r region out flag; do
    if [ "$flag" = "__MISSING_DIR__" ]; then
        echo "SKIP (missing source dir): $out" | tee -a "$LOG"
        continue
    fi
    i=$((i+1))
    echo "[$i/$total] $(basename "$out")  ($(date '+%H:%M:%S'))" | tee -a "$LOG"
    if [ "$flag" = "nether" ]; then
        luajit source_footprint.lua "$region" "$out" nether >> "$LOG" 2>&1 \
            || echo "FAILED: $(basename "$out")" | tee -a "$LOG"
    else
        luajit source_footprint.lua "$region" "$out" >> "$LOG" 2>&1 \
            || echo "FAILED: $(basename "$out")" | tee -a "$LOG"
    fi
done < /tmp/footprint_regen_jobs.txt
echo "ALL FOOTPRINTS DONE ($total jobs) at $(date '+%H:%M:%S')" | tee -a "$LOG"
