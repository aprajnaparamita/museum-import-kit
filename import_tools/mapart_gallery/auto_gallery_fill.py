#!/usr/bin/env python3
# Round 29: automatic gallery-fill orchestrator. Ties together the
# previously-manual pipeline (survey -> cluster -> match -> render ->
# place, from round 20/21) into one command that runs as a normal part
# of a full rebuild, instead of a one-shot live edit against the
# deployed world only (round 20's approach -- confirmed this round to
# silently vanish on every subsequent full wipe-and-rebuild, since
# nothing ever reapplied it. That's the actual reason the owner found
# Tactical Nuke's gallery empty again this round).
#
# Also handles the OTHER confirmed-still-broken class of bug: a
# ceiling/floor-mounted (param2 0/1) cluster of REAL captured maps whose
# ids are a contiguous sequential run (e.g. "..._0".."..._8") gets
# scrambled by the import pipeline's own frame-to-id association logic
# (root cause not tracked down -- see HANDOFF.md round 20/29) --
# generalizes round 20's hand-written Fort Alcazar fix (hardcoded old
# coordinates, silently went stale once the base moved) into something
# that re-derives the fix from CURRENT frame positions every run.
#
# Wall-mounted (param2 2-5) REAL captured-map clusters are NOT
# auto-corrected here: round 20's fix for Tactical Nuke's one such wall
# was re-verified this round via real edge-coherence scoring (decode all
# tiles, brute-force every column/row permutation + transpose, compare
# total boundary pixel error) and found to ALREADY be coherent in a
# fresh import (score 289 for the current arrangement vs 412+ for the
# next-best of 71 other candidates -- a clear, unambiguous minimum) --
# applying the old fix now would have INTRODUCED a scramble, not fixed
# one. Whatever originally caused that bug either doesn't reproduce
# deterministically or was fixed as a side effect of an unrelated code
# change; not chased further since there's currently no reproducing
# case to fix. If a future base's wall-mounted real-map cluster reports
# looking scrambled, use scripts/check_wall_coherence.py (new this
# round) to verify with real pixel data before touching anything --
# never assume/guess an ordering fix the way round 20 originally had to.
#
# Usage:
#   python3 auto_gallery_fill.py --world /path/to/world --bases "Base A" "Base B" ...
#   python3 auto_gallery_fill.py --world /path/to/world --all
#
# Requires: the target world's worldmods/ to already have spawnimport's
# real content placed (this fills EMPTY frames and fixes scrambled REAL
# ceiling/floor grids -- it does not create or move real captured
# content). The target world must not have a client connected to it.

import argparse, json, os, re, subprocess, sys, time, random
from collections import defaultdict

HERE = os.path.dirname(os.path.abspath(__file__))
LUANTI_BIN = os.path.expanduser(os.environ.get("GALLERY_LUANTI_BIN", "~/dev/luanti/bin/luanti"))
LUANTI_CONF = os.path.expanduser(os.environ.get("GALLERY_LUANTI_CONF", "~/dev/museum-testrig/conf/tactical.conf"))
REGISTRY_PATH = os.path.join(HERE, "used_pieces_registry.json")
SCRATCH = "/tmp/auto_gallery_fill"
os.makedirs(SCRATCH, exist_ok=True)

sys.path.insert(0, HERE)
import cluster_frames
import build_library_index
from tga_write import save_tga
from PIL import Image

FACING = {2: ('z', True), 3: ('z', False), 4: ('x', False), 5: ('x', True)}
SOURCE_PRIORITY = {'final': 0, 'wiki': 1, 'mapartindex': 1}
SOURCE_WEIGHTS = {'final': 4, 'wiki': 1, 'mapartindex': 1}
# All three art pools feed the gallery again (owner 2026-09-26: "only
# things from final/, none of the art from the other sources") -- final/
# (the curated 20 artworks) stays the preferred pool via these weights;
# wiki/ and mapartindex/ fill the rest. SOURCE_WEIGHTS feeds
# pick_piece's weighted random, SOURCE_PRIORITY the placement plan's
# tiering.


def log(msg):
    print(f"[auto_gallery_fill] {msg}", flush=True)


# Per-run engine timeout (2026-09-27: the survey pass outgrew the old
# 600s default as the worlds got heavier -- it was still actively
# scanning when cut off, not hung). Override with GALLERY_RUN_TIMEOUT.
def run_luanti(world, logfile, timeout=None):
    if timeout is None:
        timeout = int(os.environ.get("GALLERY_RUN_TIMEOUT", "1800"))
    logpath = os.path.join(SCRATCH, logfile)
    if os.path.exists(logpath):
        os.remove(logpath)
    proc = subprocess.Popen(
        [LUANTI_BIN, "--server", "--config", LUANTI_CONF, "--world", world,
         "--gameid", "mineclonia", "--logfile", logpath],
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    start = time.time()
    while proc.poll() is None:
        if time.time() - start > timeout:
            proc.kill()
            raise RuntimeError(f"luanti run timed out after {timeout}s ({logfile})")
        time.sleep(1)
    if os.path.exists(logpath):
        with open(logpath, errors="replace") as f:
            text = f.read()
        if "ServerError" in text or "fatal error" in text:
            raise RuntimeError(f"luanti run failed, see {logpath}")
    return logpath


def install_worldmod(world, name, lua_src, extra_files=None):
    modpath = os.path.join(world, "worldmods", name)
    if os.path.exists(modpath):
        subprocess.run(["rm", "-rf", modpath], check=True)
    os.makedirs(modpath)
    with open(os.path.join(modpath, "init.lua"), "w") as f:
        f.write(lua_src)
    for fname, content in (extra_files or {}).items():
        with open(os.path.join(modpath, fname), "w") as f:
            f.write(content)
    subprocess.run(["luajit", "-e",
                     f"local f,err=loadfile('{os.path.join(modpath, 'init.lua')}'); "
                     f"if not f then error(err) end"], check=True)
    return modpath


def remove_worldmod(world, name):
    modpath = os.path.join(world, "worldmods", name)
    if os.path.exists(modpath):
        subprocess.run(["rm", "-rf", modpath], check=True)


# ---------------------------------------------------------------------
# Phase 1: survey (one combined worldmod for all requested bases)
# ---------------------------------------------------------------------

SURVEY_LUA = r"""
local bases = %s
local out = io.open("%s", "w")
local function process(i)
    if i > #bases then
        out:close()
        core.after(1, function() core.request_shutdown("survey done", false, 0) end)
        return
    end
    local b = bases[i]
    core.emerge_area({x=b.x_min,y=b.y_min,z=b.z_min}, {x=b.x_max,y=b.y_max,z=b.z_max}, function(_,_,calls_remaining)
        if calls_remaining > 0 then return end
        core.after(2, function()
            local xspan = b.x_max - b.x_min + 1
            local zspan = b.z_max - b.z_min + 1
            local y_tile = math.max(1, math.floor(140000000 / math.max(1, xspan * zspan)))
            local positions = {}
            local y = b.y_min
            while y <= b.y_max do
                local y1 = math.min(b.y_max, y + y_tile - 1)
                local found = core.find_nodes_in_area(
                    {x=b.x_min,y=y,z=b.z_min}, {x=b.x_max,y=y1,z=b.z_max},
                    {"group:itemframe"}, false) or {}
                for _, p in ipairs(found) do positions[#positions+1] = p end
                y = y1 + 1
            end
            out:write(string.format("### %%s %%d\n", b.name, #positions))
            for _, p in ipairs(positions) do
                local node = core.get_node(p)
                local inv = core.get_meta(p):get_inventory()
                local stack = inv:get_stack("main", 1)
                local has_item = not stack:is_empty()
                local item = has_item and stack:get_name() or ""
                local mid = has_item and stack:get_meta():get_string("mcl_maps:id") or ""
                out:write(string.format("(%%d,%%d,%%d) param2=%%d has_item=%%s item=%%s mcl_maps_id=%%s node=%%s\n",
                    p.x, p.y, p.z, node.param2, tostring(has_item), item, mid, node.name))
            end
            process(i + 1)
        end)
    end)
end
core.register_on_mods_loaded(function()
    core.after(1, function() process(1) end)
end)
"""


def do_survey(world, bases):
    bases_lua = "{" + ",".join(
        f'{{name="{b["name"]}",x_min={b["bbox"]["x_min"]},x_max={b["bbox"]["x_max"]},'
        f'y_min={b["bbox"].get("y_min",-192)},y_max={b["bbox"].get("y_max",255)},'
        f'z_min={b["bbox"]["z_min"]},z_max={b["bbox"]["z_max"]}}}'
        for b in bases) + "}"
    out_path = os.path.join(SCRATCH, "survey.txt")
    lua_src = SURVEY_LUA % (bases_lua, out_path)
    install_worldmod(world, "zzz_auto_survey", lua_src)
    log(f"running survey pass for {len(bases)} base(s)...")
    run_luanti(world, "survey.log")
    remove_worldmod(world, "zzz_auto_survey")
    with open(out_path) as f:
        text = f.read()
    per_base = {}
    cur = None
    for line in text.splitlines():
        m = re.match(r"### (.+) (\d+)$", line)
        if m:
            cur = m.group(1)
            per_base[cur] = []
            continue
        m = re.match(r"\((-?\d+),(-?\d+),(-?\d+)\) param2=(\d+) has_item=(\w+) item=(\S*) mcl_maps_id=(\S*) node=(\S+)", line)
        if m and cur:
            x, y, z, p2, has, item, mid, node = m.groups()
            per_base[cur].append({
                'x': int(x), 'y': int(y), 'z': int(z), 'p2': int(p2),
                'has_item': has == 'true', 'item': item, 'mcl_maps_id': mid, 'node': node,
            })
    return per_base


# ---------------------------------------------------------------------
# Phase 2: cluster + match empties (variety-aware) + detect real
# ceiling/floor scrambles
# ---------------------------------------------------------------------

def load_registry():
    if os.path.exists(REGISTRY_PATH):
        with open(REGISTRY_PATH) as f:
            return json.load(f)
    return {}


def save_registry(reg):
    with open(REGISTRY_PATH, "w") as f:
        json.dump(reg, f, indent=1, sort_keys=True)


def build_library():
    log("building mapart library index (museum-maparts/output/*)...")
    lib = build_library_index.build_index()
    # build_index() keeps tiles keyed by (row,col) tuples (its own
    # in-memory convention); the rest of this file (and the original
    # build_placement_plan.py it's adapted from) uses "row_col" string
    # keys throughout, matching what that script's __main__ block wrote
    # to /tmp/mapart_library.json. Normalize here once instead of
    # scattering tuple-vs-string handling everywhere downstream.
    for p in lib:
        p['tiles'] = {f"{r}_{c}": path for (r, c), path in p['tiles'].items()}
    log(f"library: {len(lib)} usable pieces")
    return lib


def match_empties(clusters, library, registry, rng):
    by_size = defaultdict(list)
    for p in library:
        by_size[(p['rows'], p['cols'])].append(p)
    # Sort each size pool: best coherence first (round 21), shuffled for
    # run-to-run variety. Source weighting happens at pick time below.
    for lst in by_size.values():
        rng.shuffle(lst)
        lst.sort(key=lambda p: p.get('coherence_score', 0.0))

    used_base_ids = set(registry.get("used_base_ids", []))

    def pick_piece(rows, cols):
        for key, rotate in (((rows, cols), False), ((cols, rows), True)):
            pool = by_size.get(key, [])
            unused = [p for p in pool if p['base_id'] not in used_base_ids]
            if not unused:
                continue
            # Weighted random: final/ has higher odds (SOURCE_WEIGHTS).
            weights = [SOURCE_WEIGHTS.get(p['source'], 1) for p in unused]
            total = sum(weights)
            r = rng.random() * total
            acc = 0.0
            for p, w in zip(unused, weights):
                acc += w
                if r < acc:
                    used_base_ids.add(p['base_id'])
                    return p, rotate
            # numeric fallback (shouldn't be reached)
            p = unused[-1]
            used_base_ids.add(p['base_id'])
            return p, rotate
        # Do NOT reuse a piece that was already placed (owner report: the
        # same mapart was appearing many times in one gallery). If no
        # unused piece of this size exists, leave the frames empty rather
        # than duplicating.
        return None, False

    def cluster_dims(c):
        along_axis, left_is_larger = FACING[c['p2']]
        along_span = c['x_span'] if along_axis == 'x' else c['z_span']
        return c['y_span'], along_span, along_axis, left_is_larger

    placements = []
    unfilled = []
    for c in clusters:
        empties = [m for m in c['members'] if not m['has_item']]
        if not empties:
            continue
        if c['p2'] not in FACING:
            continue  # ceiling/floor handled separately
        rows, cols, along_axis, left_is_larger = cluster_dims(c)
        treat_as_grid = (len(empties) == c['n_frames'])

        if not treat_as_grid:
            for m in empties:
                piece, rotate = pick_piece(1, 1)
                if not piece:
                    unfilled.append(m); continue
                placements.append({
                    **{k: m[k] for k in ('x', 'y', 'z', 'p2')},
                    'tile_path': piece['tiles']['1_1'], 'rotate': rotate,
                    'art_id': f"{piece['source']}_{piece['base_id']}",
                    'source': piece['source'], 'display_name': piece['display_name'],
                })
            continue

        piece, rotate = pick_piece(rows, cols)
        if not piece:
            unfilled.extend(empties)
            continue

        along_vals = sorted(set(m[along_axis] for m in c['members']))
        if left_is_larger:
            along_vals = list(reversed(along_vals))
        col_of_along = {v: i + 1 for i, v in enumerate(along_vals)}
        y_vals = sorted(set(m['y'] for m in c['members']), reverse=True)
        row_of_y = {v: i + 1 for i, v in enumerate(y_vals)}

        for m in empties:
            col = col_of_along[m[along_axis]]
            row = row_of_y[m['y']]
            if rotate:
                src_row, src_col = (cols + 1 - col), row
            else:
                src_row, src_col = row, col
            tile_key = f"{src_row}_{src_col}"
            if tile_key not in piece['tiles']:
                unfilled.append(m); continue
            placements.append({
                **{k: m[k] for k in ('x', 'y', 'z', 'p2')},
                'tile_path': piece['tiles'][tile_key], 'rotate': rotate,
                'art_id': f"{piece['source']}_{piece['base_id']}",
                'source': piece['source'], 'display_name': piece['display_name'],
            })

    registry['used_base_ids'] = sorted(used_base_ids)
    return placements, unfilled


VERIFIED_CLUSTERS_PATH = os.path.join(HERE, "verified_real_map_clusters.json")


def load_verified_clusters():
    """Hand-verified frame-to-map-id mappings for real map clusters where
    NEITHER numeric-id-order NOR pixel-content edge-matching can be
    trusted (round 30: proved via direct source WDL entity NBT decode
    that the raw capture itself has real maps mirrored on one axis
    relative to the true built arrangement -- e.g. Fort Alcazar's 3x3
    ceiling grid and cutecurly's City's 5x5 wall both showed the exact
    same "outer positions swapped along one axis, center fixed" pattern,
    most likely a World Downloader client-side reconstruction artifact,
    not a bug in this project's own coordinate math -- every position
    transform in this file (blocks/signs/frames/mobs) uses the identical
    anchor+(source-origin) formula, independently re-derived and
    confirmed to match, ruling out an entity-specific transform bug
    here). These mappings were solved by the owner in-game via trial and
    error and captured directly from the corrected live world -- treat
    as ground truth, never overwrite with a computed guess."""
    if not os.path.exists(VERIFIED_CLUSTERS_PATH):
        return []
    with open(VERIFIED_CLUSTERS_PATH) as f:
        return json.load(f).get("clusters", [])


def detect_ceiling_scrambles(world, frames):
    """Ceiling/floor (p2 0/1) clusters of REAL (non-gallery, non-empty)
    maps whose ids are a contiguous integer run.

    Round 30 found TWO independent, compounding problems with the old
    approach here:
    1. A naive "row-major by numeric id" heuristic was flatly wrong
       (round 25 already proved this via pixel-content brute force for
       Fort Alcazar specifically) -- yet it kept firing and re-scrambling
       a freshly, correctly-placed grid on every rebuild.
    2. The replacement content-based verifier (solve_grid_jigsaw.
       verify_and_solve_physical) is ALSO not trustworthy for real
       (non-pixel-art) map content: it declared Fort Alcazar's raw
       capture "already optimal" when a direct visual render (composing
       the 9 tiles into one image) showed an obvious incoherent
       patchwork -- border-color averaging is too weak a signal for
       photographic terrain content, unlike the clean geometric pixel
       art it works for elsewhere in this file.

    So: this function no longer guesses AT ALL. It only ever applies a
    mapping found in verified_real_map_clusters.json (owner-verified,
    in-game ground truth) -- and for any contiguous-id ceiling/floor
    cluster NOT in that file, it just logs a warning that the cluster
    needs manual verification and leaves it completely untouched,
    matching the same caution already applied to wall-mounted real map
    clusters elsewhere in this file."""
    verified = load_verified_clusters()
    verified_by_prefix = {c['id_prefix']: c for c in verified}
    real = [f for f in frames if f['p2'] in (0, 1) and f['has_item']
            and f['mcl_maps_id'] and not f['mcl_maps_id'].startswith('gallery_')]
    if not real:
        return []
    # group into rectangular grids by strict rook-adjacency, same rule as cluster_frames
    idx_set = set(range(len(real)))
    visited = set()
    groups = []
    for i in range(len(real)):
        if i in visited:
            continue
        comp = []
        dq = [i]
        visited.add(i)
        while dq:
            cur = dq.pop()
            comp.append(cur)
            cf = real[cur]
            for j in idx_set:
                if j in visited:
                    continue
                jf = real[j]
                total = abs(cf['x'] - jf['x']) + abs(cf['y'] - jf['y']) + abs(cf['z'] - jf['z'])
                if total == 1:
                    visited.add(j)
                    dq.append(j)
        groups.append([real[k] for k in comp])

    fixes = []
    for g in groups:
        if len(g) < 4:
            continue  # not worth reordering a pair/singleton
        ids = []
        for m in g:
            mm = re.search(r'_(\d+)$', m['mcl_maps_id'])
            if not mm:
                ids = None
                break
            ids.append(int(mm.group(1)))
        if ids is None:
            continue
        if sorted(ids) != list(range(min(ids), min(ids) + len(ids))):
            continue  # not a contiguous sequential run -- don't guess
        xs = sorted(set(m['x'] for m in g))
        zs = sorted(set(m['z'] for m in g))
        if len(xs) * len(zs) != len(g):
            continue  # not a clean rectangle
        if len(xs) * len(zs) > 9:
            log(f"ceiling cluster at {g[0]['mcl_maps_id']} is {len(xs)}x{len(zs)} "
                f"-- too large for a brute-force jigsaw verify, skipping")
            continue

        id_prefix = re.sub(r'_\d+$', '', g[0]['mcl_maps_id'])
        cur_ids = {(m['x'], m['y'], m['z']): int(re.search(r'_(\d+)$', m['mcl_maps_id']).group(1)) for m in g}

        verified = verified_by_prefix.get(id_prefix)
        if not verified:
            log(f"ceiling cluster {id_prefix}: {len(g)} real map(s), contiguous ids "
                f"{min(ids)}-{max(ids)} -- NOT in verified_real_map_clusters.json, "
                f"no automatic reordering attempted (needs owner in-game verification; "
                f"see HANDOFF.md round 30 for why numeric-order and pixel-edge-matching "
                f"heuristics are both untrustworthy here) -- leaving as-is")
            continue

        target = {(p['x'], p['y'], p['z']): p['id'] for p in verified['positions']}
        if set(target.keys()) != set(cur_ids.keys()):
            log(f"ceiling cluster {id_prefix}: verified_real_map_clusters.json entry's "
                f"positions don't match this cluster's current positions -- base may have "
                f"moved since verification; NOT applying stale override, leaving as-is")
            continue

        if cur_ids == target:
            log(f"ceiling cluster {id_prefix}: already matches verified mapping -- no change needed")
            continue

        log(f"ceiling cluster {id_prefix}: reasserting owner-verified mapping "
            f"(current arrangement had drifted from it)")
        fixes.append({'id_prefix': id_prefix, 'positions': [
            {'x': x, 'y': y, 'z': z, 'target_id': tid}
            for (x, y, z), tid in target.items()]})
    return fixes


def apply_verified_wall_clusters(frames):
    """Reasserts verified_real_map_clusters.json mappings for WALL-mounted
    (p2 2-5) real map clusters on every rebuild -- detect_ceiling_scrambles
    only ever looks at ceiling/floor (p2 0/1) clusters, so without this,
    a verified wall-mounted fix (e.g. cutecurly's City's 5x5 gallery, both
    faces) would silently vanish on the next full wipe-and-rebuild, the
    exact class of problem round 29 already hit once for gallery-fill
    itself. Unlike detect_ceiling_scrambles, this never tries to detect
    OR guess a fix for an unverified cluster -- it only ever reasserts an
    exact, already-verified mapping, matched by id_prefix and its full
    position set (skipped if the base's frames have moved since
    verification, never applied stale)."""
    verified = load_verified_clusters()
    by_pos = {}
    for f in frames:
        if f['p2'] not in (0, 1) and f['has_item'] and f['mcl_maps_id'] \
                and not f['mcl_maps_id'].startswith('gallery_'):
            mm = re.search(r'^(.*)_(\d+)$', f['mcl_maps_id'])
            if mm:
                by_pos[(f['x'], f['y'], f['z'])] = (mm.group(1), int(mm.group(2)))

    fixes = []
    for cluster in verified:
        id_prefix = cluster['id_prefix']
        target = {(p['x'], p['y'], p['z']): p['id'] for p in cluster['positions']}
        present = {pos: by_pos[pos] for pos in target if pos in by_pos}
        if len(present) != len(target):
            continue  # not this cluster (or wrong orientation) -- skip silently
        if any(prefix != id_prefix for prefix, _ in present.values()):
            continue  # positions occupied by a different cluster's ids -- skip
        cur_ids = {pos: num for pos, (_, num) in present.items()}
        if cur_ids == target:
            continue
        log(f"wall cluster {id_prefix}: reasserting owner-verified mapping "
            f"(current arrangement had drifted from it)")
        fixes.append({'id_prefix': id_prefix, 'positions': [
            {'x': x, 'y': y, 'z': z, 'target_id': tid}
            for (x, y, z), tid in target.items()]})
    return fixes


# ---------------------------------------------------------------------
# Phase 3: render textures into the target world's mcl_maps/
# ---------------------------------------------------------------------

def sanitize(s):
    return re.sub(r'[^A-Za-z0-9]+', '_', s).strip('_')


def render(world, placements):
    tex_dir = os.path.join(world, "mcl_maps")
    os.makedirs(tex_dir, exist_ok=True)
    frame_manifest = []
    seen = set()
    n_written = 0
    for p in placements:
        art_tag = sanitize(p['art_id'])
        # derive row/col from tile_path filename for a stable id
        m = re.search(r'_(\d+)_(\d+)\.png$', p['tile_path'])
        row, col = (m.group(1), m.group(2)) if m else ("1", "1")
        mid = f"gallery_{art_tag}_{row}_{col}"
        if mid not in seen:
            seen.add(mid)
            im = Image.open(p['tile_path']).convert('RGB')
            if p['rotate']:
                im = im.rotate(-90, expand=True)
            assert im.size == (128, 128), (p['tile_path'], im.size)
            w, h = im.size
            data = list(im.getdata())
            pixels_top_down = [data[y * w:(y + 1) * w] for y in range(h)]
            out_path = os.path.join(tex_dir, f"mcl_maps_map_texture_{mid}.tga")
            save_tga(out_path, pixels_top_down)
            n_written += 1
        frame_manifest.append({
            'x': p['x'], 'y': p['y'], 'z': p['z'], 'p2': p['p2'],
            'id': mid, 'display_name': p['display_name'], 'source': p['source'],
        })
    log(f"rendered {n_written} textures, {len(frame_manifest)} frame placements")
    return frame_manifest


# ---------------------------------------------------------------------
# Phase 4: place (one combined worldmod: fill manifest + apply ceiling
# reorders for all bases)
# ---------------------------------------------------------------------

PLACE_LUA = r"""
local modpath = core.get_modpath(core.get_current_modname())
local out = io.open("%s", "w")
local function w(...) out:write(string.format(...) .. "\n") end
local bboxes = %s

local function emerge_all(i, done_cb)
    if i > #bboxes then done_cb(); return end
    local b = bboxes[i]
    core.emerge_area({x=b.x_min,y=b.y_min,z=b.z_min}, {x=b.x_max,y=b.y_max,z=b.z_max}, function(_,_,calls_remaining)
        if calls_remaining > 0 then return end
        emerge_all(i + 1, done_cb)
    end)
end

core.register_on_mods_loaded(function()
 core.after(1, function()
  emerge_all(1, function()
    core.after(2, function()
        local ok, err = pcall(function()
            local f = assert(io.open(modpath .. "/frame_manifest.json", "r"))
            local manifest = core.parse_json(f:read("*a"))
            f:close()
            local n_placed, n_skip_notframe, n_skip_notempty = 0, 0, 0
            for _, entry in ipairs(manifest) do
                local pos = {x=entry.x, y=entry.y, z=entry.z}
                local node = core.get_node(pos)
                if node.name ~= "mcl_itemframes:frame" and node.name ~= "mcl_itemframes:glow_frame" then
                    n_skip_notframe = n_skip_notframe + 1
                else
                    local meta = core.get_meta(pos)
                    local inv = meta:get_inventory()
                    local cur = inv:get_stack("main", 1)
                    if not cur:is_empty() then
                        n_skip_notempty = n_skip_notempty + 1
                    else
                        local stack = ItemStack("mcl_maps:filled_map")
                        local smeta = stack:get_meta()
                        smeta:set_string("mcl_maps:id", entry.id)
                        smeta:set_string("mcl_maps:minp", core.pos_to_string({x=entry.x-64, y=0, z=entry.z-64}))
                        smeta:set_string("mcl_maps:maxp", core.pos_to_string({x=entry.x+63, y=255, z=entry.z+63}))
                        smeta:set_int("date", os.time())
                        if entry.display_name and entry.display_name ~= "" then
                            smeta:set_string("name", entry.display_name)
                        end
                        if tt and tt.reload_itemstack_description then
                            tt.reload_itemstack_description(stack)
                        end
                        inv:set_stack("main", 1, stack)
                        n_placed = n_placed + 1
                    end
                end
            end
            w("gallery fill: placed=%%d skip_notframe=%%d skip_notempty=%%d", n_placed, n_skip_notframe, n_skip_notempty)

            local f2 = assert(io.open(modpath .. "/ceiling_fixes.json", "r"))
            local fixes = core.parse_json(f2:read("*a"))
            f2:close()
            local n_reordered = 0
            for _, fix in ipairs(fixes) do
                -- read all current stacks first (avoid overwriting before reading)
                local current = {}
                for _, p in ipairs(fix.positions) do
                    local pos = {x=p.x, y=p.y, z=p.z}
                    local inv = core.get_meta(pos):get_inventory()
                    current[#current+1] = {pos=pos, stack=inv:get_stack("main", 1), target_id=p.target_id}
                end
                -- build id -> stack map from current contents
                local by_id = {}
                for _, c in ipairs(current) do
                    local mid = c.stack:get_meta():get_string("mcl_maps:id")
                    by_id[mid] = c.stack
                end
                for _, c in ipairs(current) do
                    local target_id_str = fix.id_prefix .. "_" .. tostring(c.target_id)
                    local src_stack = by_id[target_id_str]
                    if src_stack then
                        core.get_meta(c.pos):get_inventory():set_stack("main", 1, src_stack)
                        n_reordered = n_reordered + 1
                    end
                end
            end
            w("ceiling reorder: %%d frame(s) rewritten across %%d cluster(s)", n_reordered, #fixes)
        end)
        if not ok then w("ERROR: %%s", tostring(err)) end
        out:close()
        core.after(1, function() core.request_shutdown("place done", false, 0) end)
    end)
  end)
 end)
end)
"""


def do_place(world, frame_manifest, ceiling_fixes, bases):
    if not frame_manifest and not ceiling_fixes:
        log("nothing to place, skipping placement pass")
        return
    bboxes_lua = "{" + ",".join(
        f'{{x_min={b["bbox"]["x_min"]},x_max={b["bbox"]["x_max"]},'
        f'y_min={b["bbox"].get("y_min",-192)},y_max={b["bbox"].get("y_max",255)},'
        f'z_min={b["bbox"]["z_min"]},z_max={b["bbox"]["z_max"]}}}'
        for b in bases) + "}"

    result_path = os.path.join(SCRATCH, "place_result.txt")
    lua_src = PLACE_LUA % (result_path, bboxes_lua)
    install_worldmod(world, "zzz_auto_place", lua_src, extra_files={
        "frame_manifest.json": json.dumps(frame_manifest),
        "ceiling_fixes.json": json.dumps(ceiling_fixes),
    })
    log("running placement pass...")
    run_luanti(world, "place.log")
    remove_worldmod(world, "zzz_auto_place")
    with open(result_path) as f:
        for line in f:
            log(line.rstrip())


# ---------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--world", required=True)
    ap.add_argument("--manifest", default=os.path.join(HERE, "..", "..", "..", "museum-playtest", "museum_manifest.json"))
    ap.add_argument("--bases", nargs="*", help="base display_name(s); default: all in manifest")
    ap.add_argument("--seed", type=int, default=20260919)
    args = ap.parse_args()

    manifest_path = os.path.abspath(args.manifest)
    with open(manifest_path) as f:
        entries = json.load(f)
    if args.bases:
        entries = [e for e in entries if e['display_name'] in args.bases]
    bases = [{'name': e['display_name'], 'bbox': e['dest_bbox']} for e in entries]
    log(f"target world: {args.world}")
    log(f"bases: {[b['name'] for b in bases]}")

    survey = do_survey(args.world, bases)

    registry = load_registry()
    library = build_library()
    rng = random.Random(args.seed)

    all_placements = []
    all_ceiling_fixes = []
    for b in bases:
        frames = survey.get(b['name'], [])
        log(f"{b['name']}: {len(frames)} item frame(s) surveyed")
        clusters = cluster_frames.cluster(frames)
        placements, unfilled = match_empties(clusters, library, registry, rng)
        log(f"{b['name']}: {len(placements)} gallery placements, {len(unfilled)} unfilled")
        all_placements.extend(placements)

        fixes = detect_ceiling_scrambles(args.world, frames)
        if fixes:
            log(f"{b['name']}: {len(fixes)} ceiling/floor cluster(s) need real-map reordering")
        all_ceiling_fixes.extend(fixes)

        wall_fixes = apply_verified_wall_clusters(frames)
        if wall_fixes:
            log(f"{b['name']}: {len(wall_fixes)} verified wall cluster(s) need reasserting")
        all_ceiling_fixes.extend(wall_fixes)

    save_registry(registry)
    log(f"registry now has {len(registry.get('used_base_ids', []))} used piece(s)")

    frame_manifest = render(args.world, all_placements)
    do_place(args.world, frame_manifest, all_ceiling_fixes, bases)
    log("done")


if __name__ == '__main__':
    main()
