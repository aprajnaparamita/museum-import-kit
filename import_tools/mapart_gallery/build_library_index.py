import json, re, os
from collections import defaultdict
from PIL import Image, ImageChops, ImageStat

OUTPUT_DIR = os.path.expanduser('~/dev/museum-maparts/output')
TILE_RE = re.compile(r'^(.*)_(\d+)_(\d+)\.png$')

# Round 21 fix (owner live report, image showing two "rocket" tiles that
# "look almost identical" placed side by side): some library "pieces"
# with a multi-tile <base_id>_<row>_<col>.png naming turn out to be
# ANIMATED mapart exported frame-by-frame (each "tile" is a near-full
# copy of the same image, one animation frame later) rather than real
# spatial tiles of one bigger picture -- the row/col naming convention
# can't tell the two apart, only the actual pixel content can. Detected
# here by checking every pair of grid-ADJACENT tiles (the only pairs
# that would ever be visually neighboring if placed) for near-identical
# content; flagged pieces are excluded from the usable library entirely
# rather than guessed at.
def _mean_abs_diff(path_a, path_b):
	a = Image.open(path_a).convert('RGB')
	b = Image.open(path_b).convert('RGB')
	if a.size != b.size:
		return 255.0  # different sizes can't be a duplicate-frame issue
	diff = ImageChops.difference(a, b)
	return ImageStat.Stat(diff).mean[0]  # 0..255, 0 = pixel-identical

ANIMATED_DUPLICATE_THRESHOLD = 8.0  # empirically: real distinct tiles of
# a real image differ by dozens+ on this scale; true animation-frame
# duplicates (same base image, maybe a small moving detail) score very
# low -- picked conservatively low to avoid false-rejecting legitimately
# similar-toned real tiles (e.g. two adjacent sky tiles).

def has_animated_duplicate_tiles(tiles, rows, cols):
	for r in range(1, rows + 1):
		for c in range(1, cols + 1):
			if (r, c) not in tiles:
				continue
			for nr, nc in ((r, c + 1), (r + 1, c)):
				if (nr, nc) in tiles:
					d = _mean_abs_diff(tiles[(r, c)], tiles[(nr, nc)])
					if d < ANIMATED_DUPLICATE_THRESHOLD:
						return True
	return False

# Round 21 (owner live report, image #94: "this map art is still not
# fixed as the column on the right should be the one on the far left"):
# some library pieces' own <row>_<col> tile files may simply be mislabeled
# at the source (wrong order baked into the filenames themselves, not a
# bug in this project's placement code) -- the same class of problem as
# the real captured-map column swap found and fixed this session, just
# in externally-sourced data this project doesn't control. A general,
# content-based signal: for every DECLARED-adjacent tile pair, compare
# the touching border strips (last/first few pixel columns or rows) --
# real continuous artwork has closely-matching borders at a true seam;
# a scrambled/mislabeled ordering does not. Lower score = more coherent.
# This is a soft ranking signal (real art can legitimately have a sharp
# edge at a seam, e.g. a hard silhouette), not a hard reject -- used by
# build_placement_plan.py to prefer better-scoring candidates within a
# same-source/size pool, not to exclude anything outright.
_BORDER_PX = 4

def _edge_strip(im, side):
	w, h = im.size
	if side == 'right':
		return im.crop((w - _BORDER_PX, 0, w, h))
	if side == 'left':
		return im.crop((0, 0, _BORDER_PX, h))
	if side == 'bottom':
		return im.crop((0, h - _BORDER_PX, w, h))
	if side == 'top':
		return im.crop((0, 0, w, _BORDER_PX))

def coherence_score(tiles, rows, cols):
	diffs = []
	cache = {}
	def load(rc):
		if rc not in cache:
			cache[rc] = Image.open(tiles[rc]).convert('RGB')
		return cache[rc]
	for r in range(1, rows + 1):
		for c in range(1, cols + 1):
			if (r, c) not in tiles:
				continue
			im = load((r, c))
			if (r, c + 1) in tiles:
				a = _edge_strip(im, 'right')
				b = _edge_strip(load((r, c + 1)), 'left')
				diffs.append(ImageStat.Stat(ImageChops.difference(a, b)).mean[0])
			if (r + 1, c) in tiles:
				a = _edge_strip(im, 'bottom')
				b = _edge_strip(load((r + 1, c)), 'top')
				diffs.append(ImageStat.Stat(ImageChops.difference(a, b)).mean[0])
	return sum(diffs) / len(diffs) if diffs else 0.0

def scan_dir(source):
    d = os.path.join(OUTPUT_DIR, source)
    pieces = defaultdict(dict)  # base_id -> {(row,col): filename}
    for fn in os.listdir(d):
        if not fn.endswith('.png'):
            continue
        m = TILE_RE.match(fn)
        if not m:
            continue
        base_id, row, col = m.group(1), int(m.group(2)), int(m.group(3))
        pieces[base_id][(row, col)] = fn
    return pieces

def load_final_manifest():
    path = os.path.join(OUTPUT_DIR, 'final', '..', '_manifest.json')
    path = os.path.join(OUTPUT_DIR, '_manifest.json')
    with open(path) as f:
        m = json.load(f)
    by_base = {}
    for entry in m['results']:
        if entry['source'] != 'final':
            continue
        by_base[entry['base_name']] = entry
    return by_base

def build_index(check_animated=True):
    library = []  # list of {source, base_id, rows, cols, display_name, tiles: {(row,col): abspath}}
    final_manifest = load_final_manifest()
    n_rejected_animated = 0

    for source in ('final', 'mapartindex', 'wiki'):
        pieces = scan_dir(source)
        for base_id, tiles in pieces.items():
            rows = max(rc[0] for rc in tiles)
            cols = max(rc[1] for rc in tiles)
            expected = rows * cols
            if len(tiles) != expected:
                # incomplete grid (missing tiles) -- skip, can't use safely
                continue
            display_name = None
            if source == 'final' and base_id in final_manifest:
                display_name = final_manifest[base_id].get('display_name')
                msize = final_manifest[base_id].get('size')  # [cols, rows]
                if msize and (msize[1], msize[0]) != (rows, cols):
                    # trust filename-derived grid over manifest size if they
                    # disagree -- filenames are the ground truth for what
                    # tiles actually exist on disk.
                    pass
            abs_tiles = {rc: os.path.join(OUTPUT_DIR, source, fn) for rc, fn in tiles.items()}
            if check_animated and rows * cols > 1 and has_animated_duplicate_tiles(abs_tiles, rows, cols):
                n_rejected_animated += 1
                continue
            score = coherence_score(abs_tiles, rows, cols) if rows * cols > 1 else 0.0
            library.append({
                'source': source,
                'base_id': base_id,
                'rows': rows,
                'cols': cols,
                'display_name': display_name or base_id,
                'tiles': abs_tiles,
                'coherence_score': score,
            })
    if check_animated:
        print(f"rejected as animated-frame-duplicates: {n_rejected_animated}", flush=True)
    return library

if __name__ == '__main__':
    lib = build_index()
    print(f"total usable pieces: {len(lib)}")
    by_source = defaultdict(int)
    by_size = defaultdict(int)
    for p in lib:
        by_source[p['source']] += 1
        by_size[(p['rows'], p['cols'])] += 1
    print("by source:", dict(by_source))
    print(f"distinct sizes: {len(by_size)}")
    # dump a lightweight index (no full tile paths, just counts) for inspection
    out = []
    for p in lib:
        out.append({'source': p['source'], 'base_id': p['base_id'], 'rows': p['rows'],
                     'cols': p['cols'], 'display_name': p['display_name'],
                     'coherence_score': p['coherence_score'],
                     'tiles': {f"{r}_{c}": path for (r,c), path in p['tiles'].items()}})
    json.dump(out, open('/tmp/mapart_library.json', 'w'))
    print("wrote /tmp/mapart_library.json")
