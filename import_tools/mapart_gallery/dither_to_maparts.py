#!/usr/bin/env python3
"""
dither_to_maparts.py -- drop images into mapart tiles using mapartcraft's palette.

Mapartcraft (https://github.com/rebane2001/mapartcraft) is a browser app
with no CLI -- this script ports the parts we actually need:

  - the palette (`src/components/mapart/json/coloursJSON.json`): one
    entry per *colour set* (block grouping that all map to the same map
    pixel colour), with `dark`/`normal`/`light`/`unobtainable` tones.
  - the default preset ("Everything" -- all 61 colour sets, one block
    each).
  - the standard map.dat staircasing-ON mode (three tones per colour).
  - Floyd-Steinberg error-diffusion dithering (the default in the JS
    worker; "FloydSteinberg" in `ditherMethods.json`).

Default I/O is wired for this project's curated workflow:
  - input  = ~/dev/museum-maparts/final  (the 20 owner-curated source JPEGs)
  - output = ~/dev/museum-maparts/output/final  (the library's scan dir)

So a bare `python3 dither_to_maparts.py` reads every JPEG in final/,
dithers it, and writes `<base_id>_<row>_<col>.png` tiles into output/final/
where `build_library_index.py` finds them automatically. Override with
--input/--output for anything else.

Output tiles are exactly 128x128 PNGs named `<base_id>_<row>_<col>.png`,
matching the existing convention.

Usage:
  # one image, drop into the default output dir with auto base_id
  python3 dither_to_maparts.py path/to/image.png

  # explicit base_id
  python3 dither_to_maparts.py image.png --id meme_42

  # batch every JPEG in the default curated source dir
  python3 dither_to_maparts.py --batch

  # batch a different directory
  python3 dither_to_maparts.py some/dir/ --batch --output other/place/

  # lock to exactly N tiles wide x M tiles tall (fits-contains the image)
  python3 dither_to_maparts.py photo.jpg --tiles 3x2 --fit cover

  # quilt/stitch -- large image already huge, just slice it without resizing
  python3 dither_to_maparts.py tiles/masterpiece.png --no-resize

  # use only the 'normal' tone (61-colour palette), no staircasing
  python3 dither_to_maparts.py photo.jpg --tones normal
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

# Mapartcraft lives at ~/dev/mapartcraft/ (this repo's sibling). Allow
# an explicit override via --colours for forks / local palette tweaks.
DEFAULT_MAPARTCRAFT_DIR = Path(os.path.expanduser("~/dev/mapartcraft"))
DEFAULT_COLOURS_JSON = DEFAULT_MAPARTCRAFT_DIR / "src" / "components" / "mapart" / "json" / "coloursJSON.json"

# This project's curated mapart source/output pair. Reads land directly
# in the library's scan dir so a successful run is picked up by the
# next build_library_index.py with zero plumbing.
DEFAULT_INPUT_DIR = Path(os.path.expanduser("~/dev/museum-maparts/final"))
DEFAULT_OUTPUT_DIR = Path(os.path.expanduser("~/dev/museum-maparts/output/final"))

# Default block selection = "Everything" preset (first entry in
# defaultPresets.json): all 61 colour sets, the default (index 0) block
# in each. Each colour set contributes its dark/normal/light tones (the
# "staircasing ON" mapdat mode), giving 183 palette colours.
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


def _load_palette(colours_path: Path = DEFAULT_COLOURS_JSON,
                  tone_keys: Iterable[str] = TONE_KEYS) -> np.ndarray:
    """Build the (N, 3) uint8 RGB palette from mapartcraft's coloursJSON.

    The colour set's `mapdatId` is *not* read here -- this palette is only
    used as nearest-neighbour targets for the ditherer, which doesn't care
    about which Minecraft block maps to which pixel: the consumer of these
    tiles (render_and_place.py / minetest's map item) handles the lookup.
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
    """Decide (cols, rows) of 128x128 tiles for an image."""
    if tiles:
        m = re.fullmatch(r"(\d+)\s*[xX]\s*(\d+)", tiles.strip())
        if not m:
            raise SystemExit(f"--tiles must look like '3x2', got {tiles!r}")
        return int(m.group(1)), int(m.group(2))
    src_w, src_h = image.size
    cols = max(1, (src_w + 127) // 128)
    rows = max(1, (src_h + 127) // 128)
    return cols, rows


def _floyd_steinberg(image: Image.Image, palette: np.ndarray) -> Image.Image:
    """Floyd-Steinberg error-diffusion dither onto `palette`."""
    arr = np.asarray(image.convert("RGB"), dtype=np.float64)
    h, w, _ = arr.shape

    for y in range(h):
        for x in range(w):
            old = arr[y, x]
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
    """Split the image into 128x128 chunks and write each as a PNG."""
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


def _iter_inputs(path: Path, batch: bool, is_default_dir: bool = False) -> List[Path]:
    """Resolve a positional argument into the list of image files to dither.

    With `is_default_dir=True` (set when the user passed no positional arg
    and we're using DEFAULT_INPUT_DIR), batch mode is implied and we just
    scan for any image extension. With an explicit path, batch must be
    requested via --batch.
    """
    if path.is_dir():
        if not batch and not is_default_dir:
            print(f"{path} is a directory; use --batch to process it as a folder of images", file=sys.stderr)
            sys.exit(2)
        return sorted(p for p in path.iterdir()
                      if p.suffix.lower() in {".png", ".jpg", ".jpeg", ".webp", ".bmp"})
    return [path]


def main(argv: List[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("image", nargs="?",
                    help="input image file, or a directory (with --batch). "
                         f"Default: every image under {DEFAULT_INPUT_DIR}/")
    ap.add_argument("--id", help="base_id for the output tiles (default: slug from filename)")
    ap.add_argument("--input", default=str(DEFAULT_INPUT_DIR),
                    help=f"default input directory when run as `dither_to_maparts.py --batch` "
                         f"(default: {DEFAULT_INPUT_DIR})")
    ap.add_argument("--output", default=str(DEFAULT_OUTPUT_DIR),
                    help=f"output directory for tiles (default: {DEFAULT_OUTPUT_DIR})")
    ap.add_argument("--tiles", help="force tile grid as CxR (e.g. 3x2); default: ceil(src/128)")
    ap.add_argument("--fit", choices=("cover", "contain"), default="contain",
                    help="resize strategy when fitting to the tile grid (default: contain)")
    ap.add_argument("--no-resize", action="store_true",
                    help="skip the resize step (use when the input is already 128-aligned)")
    ap.add_argument("--batch", action="store_true",
                    help="treat the input path as a directory of images "
                         "(implied when no positional arg is given)")
    ap.add_argument("--colours", default=str(DEFAULT_COLOURS_JSON),
                    help="path to mapartcraft coloursJSON.json (for a custom palette)")
    ap.add_argument("--tones", default=",".join(TONE_KEYS),
                    help=f"comma-separated tone keys from coloursJSON to include in the palette "
                         f"(default: {','.join(TONE_KEYS)})")
    args = ap.parse_args(argv)

    # Resolve input: positional arg wins, else default input dir in --batch mode.
    if args.image:
        src = Path(args.image).expanduser()
        if not src.exists():
            ap.error(f"input not found: {src}")
        is_default_dir = False
    else:
        src = Path(args.input).expanduser()
        if not src.exists():
            ap.error(f"default input dir not found: {src}\n"
                     f"pass an explicit image path, or create the curated source dir")
        is_default_dir = True
        args.batch = True  # implicit when no positional

    tone_keys = tuple(t.strip() for t in args.tones.split(",") if t.strip())
    palette = _load_palette(Path(args.colours), tone_keys)
    print(f"palette: {palette.shape[0]} colours from {args.colours} "
          f"(tones: {tone_keys})", file=sys.stderr)

    out_dir = Path(args.output).expanduser()
    inputs = _iter_inputs(src, args.batch, is_default_dir=is_default_dir)
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
                print(f"warning: --no-resize but {im.size} != {cols*128}x{rows*128}; "
                      f"resizing anyway", file=sys.stderr)
            print(f"{img_path.name} -> {base_id} ({cols}x{rows} maps = "
                  f"{cols*128}x{rows*128} px, fit={args.fit})", file=sys.stderr)
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
