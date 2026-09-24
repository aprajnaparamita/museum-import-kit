#!/usr/bin/env python3
"""
dither_to_maparts.py -- drop images into mapart tiles using mapartcraft's palette.

Mapartcraft (https://github.com/rebane2001/mapartcraft) is a browser app --
it has no CLI and no Python pipeline, so this script ports the parts we
actually need:

  - the palette (`src/components/mapart/json/coloursJSON.json`): one entry
    per *colour set* (block grouping that all map to the same map pixel
    colour), with `dark`/`normal`/`light`/`unobtainable` tones.
  - the default preset ("Everything" -- all 61 colour sets, one block each).
  - the standard map.dat staircasing-ON mode (the three tones per colour).
  - Floyd-Steinberg error-diffusion dithering (the default in the JS
    worker; "FloydSteinberg" in `ditherMethods.json`).

Output tiles are exactly 128x128 PNGs named `<base_id>_<row>_<col>.png`,
matching the existing `~/dev/museum-maparts/output/{final,mapartindex,wiki}/`
naming convention so the gallery-fill pipeline (`build_library_index.py` +
`render_and_place.py`) picks them up unchanged after this script is also
added as a scanned source.

Usage:
  # one image, drop into ./dithered/ with auto base_id from filename
  python3 dither_to_maparts.py path/to/image.png

  # explicit base_id + a different output directory
  python3 dither_to_maparts.py image.png --id meme_42 --out other_dir

  # batch every image in a directory, one base_id per image
  python3 dither_to_maparts.py ~/dev/museum-maparts/images/ --batch

  # lock to exactly N tiles wide x M tiles tall (fits-contains the image)
  python3 dither_to_maparts.py photo.jpg --tiles 3x2 --fit cover

  # quilt/stitch -- large image already huge, just slice it without resizing
  python3 dither_to_maparts.py tiles/masterpiece.png --no-resize
"""

import argparse
import json
import os
import re
import sys
from pathlib import Path
from typing import Iterable, List, Tuple

import numpy as np
from PIL import Image

# -- constants tied to mapartcraft's data files -------------------------

MAPARTCRAFT_DIR = Path(__file__).resolve().parent.parent.parent.parent / "mapartcraft"
COLOURS_JSON = MAPARTCRAFT_DIR / "src" / "components" / "mapart" / "json" / "coloursJSON.json"
DEFAULT_OUTPUT_DIR = Path(__file__).resolve().parent / "dithered"

# Default block selection = "Everything" preset (first entry in
# defaultPresets.json): all 61 colour sets, the default (index 0) block
# in each. Each colour set contributes its dark/normal/light tones (the
# "staircasing ON" mapdat mode), giving 183 palette colours -- the same
# colour budget as a "3x3 staircased" mapart on rebane2001.com.
TONE_KEYS = ("dark", "normal", "light")

# Floyd-Steinberg kernel from mapartcraft's ditherMethods.json (the
# [0][*]/[1][*]/[2][*] 3x5 sparse layout it walks column-by-column).
# Only the non-zero entries matter; pairs are (dy, dx, weight).
FS_KERNEL = (
    (0, 1, 7.0),
    (1, -1, 3.0),
    (1, 0, 5.0),
    (1, 1, 1.0),
)
FS_DIVISOR = 16.0


def _slugify(name: str) -> str:
    """Make a filesystem-/pipeline-friendly id from a filename or arbitrary string."""
    base = os.path.splitext(os.path.basename(name))[0]
    slug = re.sub(r"[^A-Za-z0-9]+", "_", base).strip("_")
    return slug or "art"


def _load_palette(colours_path: Path = COLOURS_JSON,
                  tone_keys: Iterable[str] = TONE_KEYS) -> np.ndarray:
    """Build the (N, 3) uint8 RGB palette from mapartcraft's coloursJSON.

    The colour set's `mapdatId` is *not* read here -- this palette is only
    used as nearest-neighbour targets for the ditherer, which doesn't care
    about which Minecraft block maps to which pixel: the *consumer* of
    these tiles (render_and_place.py / minetest's map item) will look up
    the actual block on its own.
    """
    with open(colours_path) as f:
        data = json.load(f)
    swatches = []
    for colour_set_id in sorted(data.keys(), key=int):
        tones = data[colour_set_id]["tonesRGB"]
        for tone in tone_keys:
            if tone in tones:
                swatches.append(tones[tone])
    arr = np.array(swatches, dtype=np.float64)
    if arr.size == 0:
        raise RuntimeError(f"no palette swatches found in {colours_path}")
    return arr


def _resize_for_tiles(image: Image.Image, cols: int, rows: int,
                      fit: str) -> Image.Image:
    """Resize + pad to (cols*128 x rows*128) so tiles are exact multiples of 128.

    fit="cover"   -- center-crop the image to fill, may crop edges
    fit="contain" -- letterbox to fit, preserves full image (default)
    """
    target_w = cols * 128
    target_h = rows * 128
    src_w, src_h = image.size
    if src_w == target_w and src_h == target_h:
        return image

    if fit == "cover":
        scale = max(target_w / src_w, target_h / src_h)
        crop_w = int(round(target_w / scale))
        crop_h = int(round(target_h / scale))
        left = (src_w - crop_w) // 2
        top = (src_h - crop_h) // 2
        image = image.crop((left, top, left + crop_w, top + crop_h))
        return image.resize((target_w, target_h), Image.LANCZOS)

    # contain: scale so both fit, paste centred on a neutral canvas
    scale = min(target_w / src_w, target_h / src_h)
    new_w = max(1, int(round(src_w * scale)))
    new_h = max(1, int(round(src_h * scale)))
    resized = image.resize((new_w, new_h), Image.LANCZOS)
    canvas = Image.new("RGB", (target_w, target_h), (127, 178, 56))  # grass normal
    paste_x = (target_w - new_w) // 2
    paste_y = (target_h - new_h) // 2
    canvas.paste(resized, (paste_x, paste_y))
    return canvas


def _choose_tile_grid(image: Image.Image, tiles: str | None) -> Tuple[int, int]:
    """Decide (cols, rows) of 128x128 tiles for an image.

    If --tiles is given, parse as "CxR" (e.g. "3x2"); else round UP to
    one 128-tile, but never enlarge beyond what would 4x the source area
    (we just one-tile small images for "dithered" single-map artworks).
    """
    if tiles:
        m = re.fullmatch(r"(\d+)\s*[xX]\s*(\d+)", tiles.strip())
        if not m:
            raise SystemExit(f"--tiles must look like '3x2', got {tiles!r}")
        return int(m.group(1)), int(m.group(2))
    src_w, src_h = image.size
    cols = max(1, (src_w + 127) // 128)
    rows = max(1, (src_h + 127) // 128)
    # cap at first 128x128 for tiny images so we don't generate 100
    # grass-coloured tiles of a 200x200 source by default
    if cols * rows > 12 and (src_w <= 128 or src_h <= 128):
        return 1, 1
    return cols, rows


def _floyd_steinberg(image: Image.Image, palette: np.ndarray) -> Image.Image:
    """Floyd-Steinberg error-diffusion dither onto `palette`.

    Faithful port of the JS worker's FloydSteinberg branch: scan-line
    order (top-down, left-right), distribute the per-pixel quantisation
    error using the standard 7/16, 3/16, 5/16, 1/16 kernel. Uses float
    arithmetic with clipping at the end (matches the JS worker's
    canvasImageData mutation, which clamps to [0,255] on read back into
    ImageData).
    """
    arr = np.asarray(image.convert("RGB"), dtype=np.float64)
    h, w, _ = arr.shape

    for y in range(h):
        for x in range(w):
            old = arr[y, x]
            # nearest palette colour (squared Euclidean in RGB, same as
            # optionValue_betterColour=false in the JS worker)
            dists = np.einsum("ij,ij->i", palette - old, palette - old)
            idx = int(np.argmin(dists))
            new = palette[idx]
            arr[y, x] = new
            err = old - new
            if err.sum() == 0:
                continue
            for dy, dx, weight in FS_KERNEL:
                ny, nx = y + dy, x + dx
                if 0 <= ny < h and 0 <= nx < w:
                    arr[ny, nx] += err * (weight / FS_DIVISOR)

    arr = np.clip(arr, 0, 255).astype(np.uint8)
    return Image.fromarray(arr, mode="RGB")


def _emit_tiles(image: Image.Image, base_id: str, out_dir: Path,
                existing_ids: set[str] | None = None) -> List[Path]:
    """Split the image into 128x128 chunks and write each as a PNG.

    Existing ids are file stems in the output dir minus the "_R_C" suffix
    (e.g. "meme_42") -- if a base_id collides we append "_2", "_3", ... so
    a re-run doesn't blow away the previous result.
    """
    cols = image.size[0] // 128
    rows = image.size[1] // 128
    if image.size[0] % 128 != 0 or image.size[1] % 128 != 0 or rows == 0 or cols == 0:
        raise ValueError(
            f"image must be a positive multiple of 128 in each dim, got {image.size}"
        )

    out_dir.mkdir(parents=True, exist_ok=True)
    bid = base_id
    if existing_ids is not None and bid in existing_ids:
        i = 2
        while f"{bid}_{i}" in existing_ids:
            i += 1
        bid = f"{base_id}_{i}"

    written = []
    for r in range(rows):
        for c in range(cols):
            tile = image.crop((c * 128, r * 128, (c + 1) * 128, (r + 1) * 128))
            tile_path = out_dir / f"{bid}_{r + 1}_{c + 1}.png"
            tile.save(tile_path, "PNG")
            written.append(tile_path)
    return written


def _existing_base_ids(out_dir: Path) -> set[str]:
    """Return the set of base_ids already present in out_dir.

    A base_id is the prefix before the last two underscores + digits, e.g.
    "meme_42_3_2.png" -> base_id "meme_42_3". This is more permissive than
    a single-image splitter (which only checks before the first "_R_C")
    so re-running on a different split-up image doesn't accidentally
    collide.
    """
    pat = re.compile(r"^(.*)_(\d+)_(\d+)\.png$")
    seen = set()
    if not out_dir.is_dir():
        return seen
    for p in out_dir.iterdir():
        m = pat.match(p.name)
        if m:
            seen.add(m.group(1))
    return seen


def _iter_inputs(path: Path, batch: bool) -> List[Path]:
    """Resolve a positional argument into the list of image files to dither."""
    if path.is_dir():
        if not batch:
            print(f"{path} is a directory; use --batch to process it as a folder of images", file=sys.stderr)
            sys.exit(2)
        return sorted(p for p in path.iterdir() if p.suffix.lower() in {".png", ".jpg", ".jpeg", ".webp", ".bmp"})
    return [path]


def main(argv: List[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("image", help="input image file, or a directory (with --batch)")
    ap.add_argument("--id", help="base_id for the output tiles (default: slug from filename)")
    ap.add_argument("--out", default=str(DEFAULT_OUTPUT_DIR),
                    help=f"output directory for tiles (default: {DEFAULT_OUTPUT_DIR})")
    ap.add_argument("--tiles", help="force tile grid as CxR (e.g. 3x2); default: ceil(src/128)")
    ap.add_argument("--fit", choices=("cover", "contain"), default="contain",
                    help="resize strategy when fitting to the tile grid (default: contain)")
    ap.add_argument("--no-resize", action="store_true",
                    help="skip the resize step (use when the input is already 128-aligned; honoured by --tiles)")
    ap.add_argument("--batch", action="store_true", help="treat the input path as a directory of images")
    ap.add_argument("--colours", default=str(COLOURS_JSON),
                    help="path to mapartcraft coloursJSON.json (for a custom palette)")
    ap.add_argument("--tones", default=",".join(TONE_KEYS),
                    help=f"comma-separated tone keys from coloursJSON to include in the palette (default: {','.join(TONE_KEYS)})")
    args = ap.parse_args(argv)

    src = Path(args.image).expanduser()
    if not src.exists():
        ap.error(f"input not found: {src}")

    tone_keys = tuple(t.strip() for t in args.tones.split(",") if t.strip())
    palette = _load_palette(Path(args.colours), tone_keys)
    print(f"palette: {palette.shape[0]} colours from {args.colours} (tones: {tone_keys})", file=sys.stderr)

    out_dir = Path(args.out).expanduser()
    inputs = _iter_inputs(src, args.batch)
    if not inputs:
        ap.error("no images found to process")

    total = 0
    for img_path in inputs:
        existing_ids = _existing_base_ids(out_dir)
        base_id = args.id or _slugify(img_path.name)
        if args.id is None and base_id in existing_ids:
            i = 2
            while f"{base_id}_{i}" in existing_ids:
                i += 1
            base_id = f"{base_id}_{i}"

        with Image.open(img_path) as im:
            cols, rows = _choose_tile_grid(im, args.tiles)
            if args.no_resize and (im.size[0] != cols * 128 or im.size[1] != rows * 128):
                print(f"warning: --no-resize but {im.size} != {cols*128}x{rows*128}; resizing anyway", file=sys.stderr)
            print(f"{img_path.name} -> {base_id} ({cols}x{rows} maps = {cols*128}x{rows*128} px, fit={args.fit})", file=sys.stderr)
            if args.no_resize:
                prepared = im.convert("RGB")
            else:
                prepared = _resize_for_tiles(im.convert("RGB"), cols, rows, args.fit)
            dithered = _floyd_steinberg(prepared, palette)
            written = _emit_tiles(dithered, base_id, out_dir)
            for p in written:
                print(f"  wrote {p}", file=sys.stderr)
            total += len(written)
    print(f"done: {total} tile(s) written to {out_dir}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
