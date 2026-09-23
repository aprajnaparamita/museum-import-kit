# Minimal reader for the exact TGA subset tga_encoder.lua writes:
# image_type=10 (RLE true-color), pixel_depth=16 (A1R5G5B5), no colormap,
# image descriptor byte 0 (origin bottom-left, i.e. first pixel in the
# data stream is the BOTTOM-LEFT pixel of the displayed image, matching
# mapdata.lua's own documented convention). Written to independently
# verify real pixel content since Pillow's TGA plugin errors on this RLE
# variant.
def read_tga_a1r5g5b5_rle(path):
    with open(path, 'rb') as f:
        data = f.read()
    id_len = data[0]
    colormap_type = data[1]
    image_type = data[2]
    assert colormap_type == 0, colormap_type
    assert image_type == 10, image_type
    width = data[12] | (data[13] << 8)
    height = data[14] | (data[15] << 8)
    pixel_depth = data[16]
    assert pixel_depth == 16, pixel_depth
    descriptor = data[17]
    off = 18 + id_len

    pixels_flat = []
    n_pixels = width * height
    while len(pixels_flat) < n_pixels:
        header = data[off]; off += 1
        count = (header & 0x7F) + 1
        is_rle = bool(header & 0x80)
        if is_rle:
            b0, b1 = data[off], data[off+1]
            off += 2
            colorword = b0 | (b1 << 8)
            r5 = (colorword >> 10) & 0x1F
            g5 = (colorword >> 5) & 0x1F
            b5 = colorword & 0x1F
            r = round(r5 * 255 / 31)
            g = round(g5 * 255 / 31)
            b = round(b5 * 255 / 31)
            for _ in range(count):
                pixels_flat.append((r, g, b))
        else:
            for _ in range(count):
                b0, b1 = data[off], data[off+1]
                off += 2
                colorword = b0 | (b1 << 8)
                r5 = (colorword >> 10) & 0x1F
                g5 = (colorword >> 5) & 0x1F
                b5 = colorword & 0x1F
                r = round(r5 * 255 / 31)
                g = round(g5 * 255 / 31)
                b = round(b5 * 255 / 31)
                pixels_flat.append((r, g, b))

    # pixels_flat[0] = bottom-left pixel (row 0 of stream = bottom row of
    # the image). Build rows top-to-bottom (normal image-array convention,
    # row 0 = top) for display/analysis convenience.
    rows_bottom_up = [pixels_flat[y*width:(y+1)*width] for y in range(height)]
    rows_top_down = list(reversed(rows_bottom_up))
    return width, height, rows_top_down

if __name__ == '__main__':
    import sys
    w, h, rows = read_tga_a1r5g5b5_rle(sys.argv[1])
    print(w, h, len(rows))
