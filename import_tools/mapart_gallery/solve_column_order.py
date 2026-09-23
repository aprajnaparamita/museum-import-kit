# General solver for the "columns are internally correct but the
# left-to-right ORDER is wrong" bug found repeatedly this session in
# real captured-map galleries (Tactical Nuke's 3x3 wall, Fort Alcazar's
# ceiling grid, cutecurly's City's 5-column piece -- three independent
# owner reports, all describing the exact same pattern: "the vertical
# strips/columns are correct but the order is wrong").
#
# Root cause is NOT an import-pipeline bug -- traced directly this round
# (mods/spawnimport/init.lua's place_one_chunk): each real item frame's
# position and its held item's map_id come from the SAME decoded NBT
# entity, so position-to-content association can't scramble in transit.
# The real explanation: the original 2b2t builder created these maps in
# one order (their real vanilla map_id, assigned by CREATION time) but
# physically placed them in frames in a DIFFERENT spatial order, which
# is completely normal Minecraft behavior -- nothing to "fix" in the
# pipeline, just something that has to be solved per-wall from the real
# pixel content, same as a jigsaw puzzle.
#
# Usage: solve_column_order(tile_paths_by_col, rows) where
# tile_paths_by_col is {current_col_index: [row1_path, row2_path, ...]}
# (current, KNOWN-wrong physical order) -- returns the correct left-to-
# right ordering of those same column indices, found by brute-force over
# all N! permutations (tractable for the N<=6 seen so far) scored by
# total border-pixel mismatch between every adjacent pair's touching
# edge, summed across all rows in that column.
import sys, itertools
sys.path.insert(0, __file__.rsplit('/', 1)[0])
from tga_read import read_tga_a1r5g5b5_rle

def _load_rgb(path):
	if path.endswith('.tga'):
		w, h, rows = read_tga_a1r5g5b5_rle(path)
		return rows
	else:
		from PIL import Image
		im = Image.open(path).convert('RGB')
		w, h = im.size
		data = list(im.getdata())
		return [data[y*w:(y+1)*w] for y in range(h)]

def _edge_diff(rows_a, rows_b, border_px=4):
	# right edge of A vs left edge of B, averaged over all rows
	total, n = 0, 0
	for row_a, row_b in zip(rows_a, rows_b):
		w = len(row_a)
		for i in range(border_px):
			ax = row_a[w - border_px + i]
			bx = row_b[i]
			total += sum(abs(ax[k] - bx[k]) for k in range(3))
			n += 1
	return total / n if n else 0.0

def solve_column_order(tile_paths_by_col, rows, verbose=True):
	col_indices = sorted(tile_paths_by_col.keys())
	n = len(col_indices)
	# concatenate each column's rows vertically into one tall image (list of rows)
	col_pixels = {}
	for c in col_indices:
		paths = tile_paths_by_col[c]
		assert len(paths) == rows, f"column {c} has {len(paths)} tiles, expected {rows}"
		combined = []
		for p in paths:
			combined.extend(_load_rgb(p))
		col_pixels[c] = combined

	# pairwise right(i)->left(j) edge diff for every ordered pair
	diff = {}
	for i in col_indices:
		for j in col_indices:
			if i != j:
				diff[(i, j)] = _edge_diff(col_pixels[i], col_pixels[j])

	best_order, best_score = None, None
	for perm in itertools.permutations(col_indices):
		score = sum(diff[(perm[k], perm[k+1])] for k in range(n - 1))
		if best_score is None or score < best_score:
			best_score, best_order = score, perm

	if verbose:
		print(f"tried {n}! = {__import__('math').factorial(n)} permutations")
		print(f"best order: {best_order}  total edge-mismatch score: {best_score:.2f}")
		# also print the CURRENT (identity) order's score for comparison
		identity = tuple(col_indices)
		identity_score = sum(diff[(identity[k], identity[k+1])] for k in range(n - 1))
		print(f"current physical order {identity}: score {identity_score:.2f}")
	return best_order, best_score

if __name__ == '__main__':
	import json
	cfg_path = sys.argv[1] if len(sys.argv) > 1 else '/tmp/column_order_input.json'
	cfg = json.load(open(cfg_path))
	order, score = solve_column_order(cfg['tile_paths_by_col'], cfg['rows'])
	json.dump({'order': list(order), 'score': score}, open('/tmp/column_order_result.json', 'w'))
	print('wrote /tmp/column_order_result.json')
