# Python port of tga_encoder.lua's exact A1R5G5B5 + RLE ("compression =
# RLE") output path -- the same one mcl_maps.create_map() and this
# project's own render_map_art() both use. Ported directly from
# /Volumes/Dara/dev/mineclonia/mods/CORE/tga_encoder/init.lua's
# encode_header/encode_image_spec/encode_data_R8G8B8_as_A1R5G5B5_rle/
# encode_footer -- not reimplemented from a generic TGA spec, to avoid
# introducing any new format mismatch. Validated by round-tripping
# through tga_read.py (this project's independent reader, itself already
# validated by decoding real game-written files into a visually-correct
# image) before being trusted for real use -- see the __main__ self-test.
#
# pixels: list of 128 rows, each a list of 128 (r,g,b) tuples, row[0] =
# TOP of the displayed image (normal top-down image convention) --
# reversed internally to TGA's bottom-up write order, mirroring
# mapdata.lua's own `pixels[128 - z]` convention exactly.

def _scale_8_to_5(v):
    return int((v * 31 / 255) + 0.5)

def _colorword(r, g, b):
    return 32768 + (_scale_8_to_5(r) * 1024) + (_scale_8_to_5(g) * 32) + (_scale_8_to_5(b) * 1)

def encode_tga_a1r5g5b5_rle(pixels_top_down):
    height = len(pixels_top_down)
    width = len(pixels_top_down[0])
    # bottom-up write order (row 0 written first = bottom of image)
    rows_bottom_up = list(reversed(pixels_top_down))

    header = bytearray()
    header += bytes([0])       # image id length
    header += bytes([0])       # colormap type
    header += bytes([10])      # image type: RLE true-color
    header += bytes([0, 0])    # colormap: first entry index
    header += bytes([0, 0])    # colormap: number of entries
    header += bytes([0])       # colormap: bits per pixel
    header += bytes([0, 0])    # x-origin
    header += bytes([0, 0])    # y-origin
    header += bytes([width % 256, width // 256])
    header += bytes([height % 256, height // 256])
    header += bytes([16])      # pixel depth (A1R5G5B5)
    header += bytes([0])       # image descriptor (origin bottom-left)

    # RLE encode, row-major within the bottom-up row order, exactly
    # matching encode_data_R8G8B8_as_A1R5G5B5_rle's flat iteration over
    # `for _, row in ipairs(self.pixels) do for _, pixel in ipairs(row)`.
    flat = [px for row in rows_bottom_up for px in row]
    packets = bytearray()
    i = 0
    n = len(flat)
    while i < n:
        r, g, b = flat[i]
        run = 1
        while i + run < n and run < 128 and flat[i + run] == (r, g, b):
            run += 1
        cw = _colorword(r, g, b)
        lo, hi = cw & 0xFF, (cw >> 8) & 0xFF
        if run > 1:
            packets += bytes([128 + run - 1, lo, hi])
            i += run
        else:
            # raw packet: gather consecutive non-repeating pixels (run==1 each)
            raw = [(r, g, b)]
            j = i + 1
            while j < n and len(raw) < 128:
                pr, pg, pb = flat[j]
                # peek ahead: stop raw-run if the NEXT pixel starts a repeat run
                if j + 1 < n and flat[j] == flat[j + 1]:
                    break
                raw.append((pr, pg, pb))
                j += 1
            packets += bytes([len(raw) - 1])
            for (pr, pg, pb) in raw:
                cw2 = _colorword(pr, pg, pb)
                packets += bytes([cw2 & 0xFF, (cw2 >> 8) & 0xFF])
            i = j

    footer = bytearray()
    footer += bytes([0, 0, 0, 0])   # extension area offset
    footer += bytes([0, 0, 0, 0])   # developer area offset
    footer += b"TRUEVISION-XFILE"
    footer += b"."
    footer += bytes([0])

    return bytes(header) + bytes(packets) + bytes(footer)

def save_tga(path, pixels_top_down):
    data = encode_tga_a1r5g5b5_rle(pixels_top_down)
    with open(path, 'wb') as f:
        f.write(data)

if __name__ == '__main__':
    import random, sys
    sys.path.insert(0, '.')
    from tga_read import read_tga_a1r5g5b5_rle

    random.seed(42)
    # test 1: random noise (exercises raw packets)
    # test 2: solid blocks (exercises RLE packets)
    # test 3: real decoded tile re-encoded (round trip against real data)
    tests_ok = True

    noise = [[(random.randint(0,255), random.randint(0,255), random.randint(0,255))
              for _ in range(128)] for _ in range(128)]
    save_tga('/tmp/_selftest_noise.tga', noise)
    w, h, rows = read_tga_a1r5g5b5_rle('/tmp/_selftest_noise.tga')
    # A1R5G5B5 is lossy (5-bit channels) -- compare against the SAME
    # quantization the encoder itself applied, not the raw input.
    def requant(px):
        r,g,b = px
        return (round(_scale_8_to_5(r)*255/31), round(_scale_8_to_5(g)*255/31), round(_scale_8_to_5(b)*255/31))
    expect = [[requant(px) for px in row] for row in noise]
    if rows != expect:
        print("NOISE TEST FAILED"); tests_ok = False
    else:
        print("noise round-trip OK")

    blocks = [[(255,0,0) if x < 64 else (0,255,0) for x in range(128)] for y in range(128)]
    save_tga('/tmp/_selftest_blocks.tga', blocks)
    w, h, rows = read_tga_a1r5g5b5_rle('/tmp/_selftest_blocks.tga')
    expect = [[requant(px) for px in row] for row in blocks]
    if rows != expect:
        print("BLOCKS TEST FAILED"); tests_ok = False
    else:
        print("blocks round-trip OK")

    # test 3: re-encode a REAL already-decoded game tile and diff against original bytes
    orig_path = '/Users/dara/Library/Application Support/minetest/worlds/2b2t Museum TEST/mcl_maps/mcl_maps_map_texture_imported_Tactical_Nuke_2023_09_390.tga'
    w, h, rows = read_tga_a1r5g5b5_rle(orig_path)
    save_tga('/tmp/_selftest_real390.tga', rows)
    w2, h2, rows2 = read_tga_a1r5g5b5_rle('/tmp/_selftest_real390.tga')
    if rows2 != rows:
        print("REAL-TILE ROUND TRIP FAILED"); tests_ok = False
    else:
        print("real-tile round-trip OK (pixel-identical after re-encode)")

    print("ALL OK" if tests_ok else "FAILURES PRESENT")
