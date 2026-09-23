# General N x M jigsaw solver for a real captured-map grid whose tile-to-
# position assignment is unknown (position and content can't be assumed
# to correlate with the maps' numeric creation-order ids at all -- see
# solve_column_order.py's header for why: a 2b2t builder's real vanilla
# map_id is assigned by CREATION time, physical placement in frames is a
# separate, unrelated decision the builder made by eye).
#
# Unlike solve_column_order.py (which assumes each column's internal row
# order is already correct and only the left-right column order is
# wrong), this solves the FULL grid assignment: which tile id goes in
# which (row, col) slot, brute force over all N! permutations, scored by
# total border-pixel mismatch summed across every internal edge (both
# horizontal neighbor-pairs and vertical neighbor-pairs). Tractable for
# grids up to ~9-10 tiles (9! = 362,880, scored via cheap precomputed
# pairwise edge-diff table lookups -- ~1s).
#
# Usage: solve_grid_jigsaw({tile_id: path, ...}, rows, cols)
# Returns (best_grid, best_score, identity_score) where best_grid is a
# dict {(row, col): tile_id}.
import sys, itertools, math
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
        return [data[y * w:(y + 1) * w] for y in range(h)]


def _right_left_diff(rows_a, rows_b, border_px=4):
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


def _bottom_top_diff(rows_a, rows_b, border_px=4):
    # bottom edge of A (last rows) vs top edge of B (first rows)
    total, n = 0, 0
    h = len(rows_a)
    for i in range(border_px):
        row_a = rows_a[h - border_px + i]
        row_b = rows_b[i]
        for ax, bx in zip(row_a, row_b):
            total += sum(abs(ax[k] - bx[k]) for k in range(3))
            n += 1
    return total / n if n else 0.0


def solve_grid_jigsaw(tile_paths, rows, cols, verbose=True):
    ids = sorted(tile_paths.keys())
    n = len(ids)
    assert n == rows * cols, f"{n} tiles but {rows}x{cols} = {rows*cols} slots"

    pixels = {tid: _load_rgb(path) for tid, path in tile_paths.items()}

    # pairwise directional diffs for every ordered pair
    right_of, below_of = {}, {}
    for a in ids:
        for b in ids:
            if a != b:
                right_of[(a, b)] = _right_left_diff(pixels[a], pixels[b])
                below_of[(a, b)] = _bottom_top_diff(pixels[a], pixels[b])

    def score_grid(grid):
        # grid: dict (row, col) -> id
        total = 0.0
        for r in range(rows):
            for c in range(cols):
                if c + 1 < cols:
                    total += right_of[(grid[(r, c)], grid[(r, c + 1)])]
                if r + 1 < rows:
                    total += below_of[(grid[(r, c)], grid[(r + 1, c)])]
        return total

    slots = [(r, c) for r in range(rows) for c in range(cols)]
    best_grid, best_score = None, None
    total_perms = math.factorial(n)
    for perm in itertools.permutations(ids):
        grid = dict(zip(slots, perm))
        s = score_grid(grid)
        if best_score is None or s < best_score:
            best_score, best_grid = s, grid

    identity_grid = {(r, c): ids[r * cols + c] for r in range(rows) for c in range(cols)}
    identity_score = score_grid(identity_grid)

    if verbose:
        print(f"tried {n}! = {total_perms} permutations")
        print(f"best score: {best_score:.1f}")
        print(f"row-major (numeric id order) score: {identity_score:.1f}")
        for r in range(rows):
            print(' '.join(str(best_grid[(r, c)]) for c in range(cols)))

    return best_grid, best_score, identity_score


def verify_and_solve_physical(tile_paths, id_at_pos, verbose=True):
    """Real-content verification for a cluster of real captured maps at
    known physical (x, z) positions, BEFORE trusting any numeric-id-order
    assumption about their correct arrangement (round 25 found that
    assumption flatly wrong for a real 3x3 gallery -- creation-order id
    and physical placement are unrelated, ordinary Minecraft behavior,
    not a pipeline bug -- see this file's and auto_gallery_fill.py's
    module docstrings).

    id_at_pos: {(x, z): tile_id} -- the CURRENT physical arrangement.
    tile_paths: {tile_id: path} for every id in id_at_pos.

    Tries both axis orientations (x-adjacency scored as horizontal
    neighbors / z-adjacency as vertical, and the transpose), since which
    real-world axis maps to "left-right" in the rendered image is not
    knowable in advance. Returns the orientation whose BEST achievable
    score is lower (the one real content actually supports), along with
    that orientation's score for the CURRENT arrangement and for the
    best-found arrangement (mapped back to physical (x, z) positions) --
    so the caller can compare current-vs-best and only touch anything if
    the current arrangement is actually, verifiably wrong.
    """
    xs = sorted(set(x for x, z in id_at_pos))
    zs = sorted(set(z for x, z in id_at_pos))
    rows, cols = len(xs), len(zs)
    ids = sorted(tile_paths.keys())
    assert len(ids) == rows * cols == len(id_at_pos)

    pixels = {tid: _load_rgb(path) for tid, path in tile_paths.items()}
    right_of, below_of = {}, {}
    for a in ids:
        for b in ids:
            if a != b:
                right_of[(a, b)] = _right_left_diff(pixels[a], pixels[b])
                below_of[(a, b)] = _bottom_top_diff(pixels[a], pixels[b])

    def score_grid(grid, rows, cols):
        total = 0.0
        for r in range(rows):
            for c in range(cols):
                if c + 1 < cols:
                    total += right_of[(grid[(r, c)], grid[(r, c + 1)])]
                if r + 1 < rows:
                    total += below_of[(grid[(r, c)], grid[(r + 1, c)])]
        return total

    slots = [(r, c) for r in range(rows) for c in range(cols)]
    best_grid_abs, best_score = None, None
    for perm in itertools.permutations(ids):
        grid = dict(zip(slots, perm))
        s = score_grid(grid, rows, cols)
        if best_score is None or s < best_score:
            best_score, best_grid_abs = s, grid

    results = []
    for orientation, row_key, col_key, r_n, c_n in (
            ('x_row', xs, zs, rows, cols), ('z_row', zs, xs, cols, rows)):
        row_of = {v: i for i, v in enumerate(row_key)}
        col_of = {v: i for i, v in enumerate(col_key)}
        if orientation == 'x_row':
            current_grid = {(row_of[x], col_of[z]): tid for (x, z), tid in id_at_pos.items()}
        else:
            current_grid = {(row_of[z], col_of[x]): tid for (x, z), tid in id_at_pos.items()}
        current_score = score_grid(current_grid, r_n, c_n)
        # best_grid_abs was solved on a rows x cols abstract grid; only
        # valid for the orientation matching those dimensions
        if r_n == rows and c_n == cols:
            best_for_orientation = best_grid_abs
            best_for_orientation_score = best_score
        else:
            best_for_orientation, best_for_orientation_score = None, None
        results.append((orientation, current_score, best_for_orientation_score, row_key, col_key))

    # pick the orientation whose CURRENT arrangement scores lower --
    # best_score ties between orientations for a square grid (the
    # abstract solve doesn't know about real x/z at all), so it can't
    # discriminate; current_score is what actually reveals which real
    # axis correctly plays "row" vs "col" against real pixel content.
    valid = [r for r in results if r[2] is not None]
    orientation, current_score, best_score_o, row_key, col_key = min(valid, key=lambda r: r[1])

    row_of = {v: i for i, v in enumerate(row_key)}
    col_of = {v: i for i, v in enumerate(col_key)}
    best_target_by_pos = {}
    for (r, c), tid in best_grid_abs.items():
        if orientation == 'x_row':
            x, z = row_key[r], col_key[c]
        else:
            z, x = row_key[r], col_key[c]
        best_target_by_pos[(x, z)] = tid

    if verbose:
        print(f"orientation={orientation} current_score={current_score:.1f} best_score={best_score_o:.1f}")

    return {
        'orientation': orientation,
        'current_score': current_score,
        'best_score': best_score_o,
        'best_target_by_pos': best_target_by_pos,  # {(x, z): tile_id}
    }


if __name__ == '__main__':
    import json
    cfg_path = sys.argv[1] if len(sys.argv) > 1 else '/tmp/grid_jigsaw_input.json'
    cfg = json.load(open(cfg_path))
    tile_paths = {int(k): v for k, v in cfg['tile_paths'].items()}
    grid, score, identity_score = solve_grid_jigsaw(tile_paths, cfg['rows'], cfg['cols'])
    out = {'grid': {f"{r},{c}": tid for (r, c), tid in grid.items()},
           'score': score, 'identity_score': identity_score}
    json.dump(out, open('/tmp/grid_jigsaw_result.json', 'w'), indent=1)
    print('wrote /tmp/grid_jigsaw_result.json')
