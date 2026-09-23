# Clusters a raw item-frame survey (position/param2/fill-state dump, one
# line per frame: "(x,y,z) param2=N has_item=true/false item=<name>") into
# rectangular same-facing groups.
#
# Round 21 fix (owner live report, screenshots): the original round-20
# version used Chebyshev distance <=2 for clustering, meant to tolerate a
# couple blocks of alcove/recess stepping in the SUPPORTING wall -- but
# this also merged frames that have a real, visible GAP between them (no
# alcove, just architecturally spaced-apart single frames) into one
# "cluster," and then placed FRAGMENTS of one bigger artwork across them.
# The owner's own words: "these map arts... are separated across and
# really should be filled with individual 1x1 map art... it's better to
# have individual 1x1 map arts" when there's a real gap. Fixed: strict
# grid adjacency only (a frame connects to another iff they differ by
# exactly 1 in ONE of the two in-wall axes and 0 in the other -- a plain
# rook move, no diagonals, no gaps) -- true contiguous tile grids still
# cluster correctly (every real multi-tile wall found this session has
# 0-gap adjacency along at least one axis), while anything with a visible
# gap now correctly falls out into its own 1x1 slot.
import re, json, sys
from collections import defaultdict, deque

FACING = {
	2: ('z', True),   # dir=+x, along=z, LEFT=+z(larger z)
	3: ('z', False),  # dir=-x, along=z, LEFT=-z(smaller z)
	4: ('x', False),  # dir=+z, along=x, LEFT=-x(smaller x)
	5: ('x', True),   # dir=-z, along=x, LEFT=+x(larger x)
}

def parse_survey(path):
	frames = []
	with open(path) as f:
		for line in f:
			m = re.match(r'\((-?\d+),(-?\d+),(-?\d+)\) param2=(\d+) has_item=(\w+) item=(\S+)', line)
			if m:
				x, y, z, p2, has, item = m.groups()
				frames.append({'x': int(x), 'y': int(y), 'z': int(z), 'p2': int(p2),
					'has_item': has == 'true', 'item': item})
	return frames

def cluster(frames):
	by_p2 = defaultdict(list)
	for i, f in enumerate(frames):
		by_p2[f['p2']].append(i)

	all_clusters = []
	for p2, idxs in by_p2.items():
		along_axis, _ = FACING.get(p2, (None, None))
		if along_axis is None:
			# floor/ceiling-mounted (p2 0/1) -- no along-axis convention
			# established (see HANDOFF.md round 20's Fort Alcazar ceiling-
			# grid writeup); cluster each as its own singleton so nothing
			# gets silently grouped under an unverified axis guess.
			for i in idxs:
				all_clusters.append(_singleton(frames, i))
			continue

		# Real 3D strict-adjacency BFS, keyed on the frame's own index (not
		# a derived (along,y) tuple) -- round 21 bug found and fixed: an
		# (along,y) dict key silently DROPPED frames whenever two distinct
		# frames shared that key (e.g. a one-block-recessed alcove wall,
		# common in this room's real architecture, differs only in the
		# FIXED coordinate, which a 2-axis key ignores entirely) --
		# confirmed by a frame-count mismatch (313 surveyed vs 144 summed
		# across clusters) before this fix. "Connected" now means true
		# voxel adjacency: exactly one of dx/dy/dz is 1 and the other two
		# are 0, checked directly on x/y/z, so nothing can collide away.
		idx_set = set(idxs)
		visited = set()
		for i in idxs:
			if i in visited:
				continue
			comp = []
			dq = deque([i])
			visited.add(i)
			while dq:
				cur = dq.popleft()
				comp.append(cur)
				cf = frames[cur]
				for j in idx_set:
					if j in visited:
						continue
					jf = frames[j]
					dx = abs(cf['x'] - jf['x'])
					dy = abs(cf['y'] - jf['y'])
					dz = abs(cf['z'] - jf['z'])
					total = dx + dy + dz
					if total == 1:  # exactly one axis differs by 1
						visited.add(j)
						dq.append(j)
			members = [frames[k] for k in comp]
			xs = sorted(set(m['x'] for m in members))
			ys = sorted(set(m['y'] for m in members))
			zs = sorted(set(m['z'] for m in members))
			all_clusters.append({
				'p2': p2, 'n_frames': len(members),
				'x_min': min(xs), 'x_max': max(xs), 'x_span': len(xs),
				'y_min': min(ys), 'y_max': max(ys), 'y_span': len(ys),
				'z_min': min(zs), 'z_max': max(zs), 'z_span': len(zs),
				'n_empty': sum(1 for m in members if not m['has_item']),
				'n_filled': sum(1 for m in members if m['has_item']),
				'members': members,
			})

	total_check = sum(c['n_frames'] for c in all_clusters)
	assert total_check == len(frames), (
		f"clustering lost/duplicated frames: {total_check} clustered vs {len(frames)} surveyed")
	return all_clusters

def _singleton(frames, i):
	f = frames[i]
	return {
		'p2': f['p2'], 'n_frames': 1,
		'x_min': f['x'], 'x_max': f['x'], 'x_span': 1,
		'y_min': f['y'], 'y_max': f['y'], 'y_span': 1,
		'z_min': f['z'], 'z_max': f['z'], 'z_span': 1,
		'n_empty': 0 if f['has_item'] else 1,
		'n_filled': 1 if f['has_item'] else 0,
		'members': [f],
	}

if __name__ == '__main__':
	survey_path = sys.argv[1] if len(sys.argv) > 1 else '/tmp/gallery_survey.txt'
	out_path = sys.argv[2] if len(sys.argv) > 2 else '/tmp/gallery_clusters.json'
	frames = parse_survey(survey_path)
	clusters = cluster(frames)
	clusters.sort(key=lambda c: -c['n_frames'])
	print(f"total frames: {len(frames)}", file=sys.stderr)
	print(f"total clusters: {len(clusters)}", file=sys.stderr)
	for c in clusters:
		print(f"  p2={c['p2']} x[{c['x_min']}..{c['x_max']}]({c['x_span']}) "
			f"y[{c['y_min']}..{c['y_max']}]({c['y_span']}) "
			f"z[{c['z_min']}..{c['z_max']}]({c['z_span']}) "
			f"n={c['n_frames']} empty={c['n_empty']} filled={c['n_filled']}", file=sys.stderr)
	json.dump(clusters, open(out_path, 'w'), indent=1)
	print(f"wrote {out_path}", file=sys.stderr)
