import json, re, sys, os
sys.path.insert(0, os.path.dirname(__file__) + '/tga_check')
from tga_write import save_tga
from PIL import Image

DEPLOY = "/Users/dara/Library/Application Support/minetest/worlds/2b2t Museum TEST"
TEX_DIR = os.path.join(DEPLOY, "mcl_maps")
os.makedirs(TEX_DIR, exist_ok=True)

placements = json.load(open('/tmp/gallery_placements.json'))

def sanitize(s):
    return re.sub(r'[^A-Za-z0-9]+', '_', s).strip('_')

frame_manifest = []
n_written = 0
seen_ids = set()

for p in placements:
    art_tag = sanitize(p['art_id'])
    mid = f"gallery_{art_tag}_{p['row']}_{p['col']}"
    if mid not in seen_ids:
        seen_ids.add(mid)
        im = Image.open(p['tile_path']).convert('RGB')
        if p['rotate']:
            im = im.rotate(-90, expand=True)  # 90 deg clockwise
        assert im.size == (128, 128), (p['tile_path'], im.size)
        w, h = im.size
        data = list(im.getdata())
        pixels_top_down = [data[y*w:(y+1)*w] for y in range(h)]
        out_path = os.path.join(TEX_DIR, f"mcl_maps_map_texture_{mid}.tga")
        save_tga(out_path, pixels_top_down)
        n_written += 1

    frame_manifest.append({
        'x': p['x'], 'y': p['y'], 'z': p['z'], 'p2': p['p2'],
        'id': mid, 'display_name': p['display_name'], 'source': p['source'],
    })

print(f"textures written: {n_written}")
print(f"frame manifest entries: {len(frame_manifest)}")
json.dump(frame_manifest, open('/tmp/gallery_frame_manifest.json', 'w'), indent=1)
print("wrote /tmp/gallery_frame_manifest.json")
