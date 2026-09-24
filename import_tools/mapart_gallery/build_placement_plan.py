import json, random, sys
from collections import defaultdict

clusters = json.load(open('/tmp/gallery_clusters.json'))
library = json.load(open('/tmp/mapart_library.json'))

FACING = {
    2: ('z', True),
    3: ('z', False),
    4: ('x', False),
    5: ('x', True),
}
SOURCE_PRIORITY = {'final': 0, 'mapartindex': 1, 'wiki': 2, 'dithered': 3}  # dithered = lowest priority -- owner-curated corpus always wins when sized correctly

by_size = defaultdict(list)
for p in library:
    by_size[(p['rows'], p['cols'])].append(p)

# Round 21 (owner live report, image #94 -- a still-wrong column order
# after round 20's fix, on a piece that turned out not to be the real
# captured-map wall already fixed and verified that round): some library
# pieces' own tile files can be mislabeled at the source (see
# build_library_index.py's coherence_score -- computed once per piece
# there, from comparing declared-adjacent tiles' touching borders).
# Reseeded (was 20260919) so a fresh run doesn't reproduce the exact same
# picks the owner already flagged as bad; within each source-priority
# tier, pieces are now shuffled THEN stable-sorted by coherence_score
# ascending (best-seam-continuity first) -- multi-tile pieces with a
# likely-scrambled source ordering sort toward the back of their tier
# and only get used once better-scoring same-size/same-tier options run
# out, instead of being picked with equal odds to everything else.
rng = random.Random(20260919 + 21)
for lst in by_size.values():
    tiers = defaultdict(list)
    for p in lst:
        tiers[SOURCE_PRIORITY[p['source']]].append(p)
    for t in tiers.values():
        rng.shuffle(t)
        t.sort(key=lambda p: p.get('coherence_score', 0.0))
    lst[:] = [p for t in sorted(tiers) for p in tiers[t]]

used_base_ids = set()

def pick_piece(rows, cols):
    for key, rotate in ((( rows, cols), False), ((cols, rows), True)):
        pool = by_size.get(key, [])
        # prefer an unused piece; fall back to reuse if the pool is exhausted
        for p in pool:
            if p['base_id'] not in used_base_ids:
                used_base_ids.add(p['base_id'])
                return p, rotate
        if pool:
            return pool[0], rotate
    return None, False

def cluster_dims(c):
    along_axis, left_is_larger = FACING[c['p2']]
    along_span = c['x_span'] if along_axis == 'x' else c['z_span']
    rows = c['y_span']
    cols = along_span
    return rows, cols, along_axis, left_is_larger

placements = []  # list of {x,y,z,p2, tile_path, rotate, art_id, source, display_name}
unfilled = []

for c in clusters:
    empties = [m for m in c['members'] if not m['has_item']]
    if not empties:
        continue
    rows, cols, along_axis, left_is_larger = cluster_dims(c)
    # sanity: if this cluster mixes filled+empty in a way that doesn't
    # match its full grid (partial fill), treat remaining empties as
    # independent 1x1 slots rather than guessing how they relate to the
    # existing filled ones.
    treat_as_grid = (len(empties) == c['n_frames'])

    if not treat_as_grid:
        for m in empties:
            piece, rotate = pick_piece(1, 1)
            if not piece:
                unfilled.append(m); continue
            placements.append({
                **{k: m[k] for k in ('x','y','z','p2')},
                'tile_path': piece['tiles']['1_1'], 'rotate': rotate,
                'art_id': f"{piece['source']}_{piece['base_id']}",
                'source': piece['source'], 'display_name': piece['display_name'],
                'row': 1, 'col': 1,
            })
        continue

    piece, rotate = pick_piece(rows, cols)
    if not piece:
        unfilled.extend(empties)
        continue

    # sort along-axis coordinate values ascending; map to column index
    # 1..cols using this cluster's LEFT/RIGHT convention (col 1 = left,
    # matching the library's own _row_col naming where col increases
    # left-to-right in the source image).
    along_key = along_axis
    along_vals = sorted(set(m[along_key] for m in c['members']))
    if left_is_larger:
        along_vals = list(reversed(along_vals))  # now index0 = leftmost (largest)
    col_of_along = {v: i + 1 for i, v in enumerate(along_vals)}

    y_vals = sorted(set(m['y'] for m in c['members']), reverse=True)  # index0 = top (largest y)
    row_of_y = {v: i + 1 for i, v in enumerate(y_vals)}

    piece_rows, piece_cols = (piece['cols'], piece['rows']) if rotate else (piece['rows'], piece['cols'])
    for m in empties:
        col = col_of_along[m[along_key]]
        row = row_of_y[m['y']]
        if rotate:
            # library piece is (piece.rows=cols x piece.cols=rows) relative
            # to this cluster's (rows x cols) -- a 90deg-CW rotation from
            # piece-space into cluster-space maps piece tile (r,c) to
            # cluster position (dest_row=c, dest_col=piece.rows+1-r).
            # Inverting: given a cluster (row,col), the piece tile is
            # (piece_row = cols+1-col, piece_col = row).
            src_row, src_col = (cols + 1 - col), row
        else:
            src_row, src_col = row, col
        tile_key = f"{src_row}_{src_col}"
        if tile_key not in piece['tiles']:
            unfilled.append(m); continue
        placements.append({
            **{k: m[k] for k in ('x','y','z','p2')},
            'tile_path': piece['tiles'][tile_key], 'rotate': rotate,
            'art_id': f"{piece['source']}_{piece['base_id']}",
            'source': piece['source'], 'display_name': piece['display_name'],
            'row': row, 'col': col,
        })

print(f"total placements: {len(placements)}")
print(f"unfilled frames: {len(unfilled)}")
by_src = defaultdict(int)
for p in placements:
    by_src[p['source']] += 1
print("by source:", dict(by_src))
n_pieces = len(set(p['art_id'] for p in placements))
print(f"distinct artworks used: {n_pieces}")

json.dump(placements, open('/tmp/gallery_placements.json', 'w'), indent=1)
json.dump(unfilled, open('/tmp/gallery_unfilled.json', 'w'), indent=1)
print("wrote /tmp/gallery_placements.json and /tmp/gallery_unfilled.json")
