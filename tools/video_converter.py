import sys
import glob
from PIL import Image
import numpy as np

# NES NTSCパレット（代表16色 × 4段階）
NES_PALETTE_RGB = [
    (84, 84, 84), (0, 30, 116), (8, 16, 144), (48, 0, 136),
    (68, 0, 100), (92, 0, 48), (84, 4, 0), (60, 24, 0),
    (32, 42, 0), (8, 58, 0), (0, 64, 0), (0, 60, 0),
    (0, 50, 60), (0, 0, 0), (0, 0, 0), (0, 0, 0),
    (152, 150, 152), (8, 76, 196), (48, 50, 236), (92, 30, 228),
    (136, 20, 176), (160, 20, 100), (152, 34, 32), (120, 60, 0),
    (84, 90, 0), (40, 114, 0), (8, 124, 0), (0, 118, 40),
    (0, 102, 120), (0, 0, 0), (0, 0, 0), (0, 0, 0),
    (236, 238, 236), (76, 154, 236), (120, 124, 236), (176, 98, 236),
    (228, 84, 236), (236, 88, 180), (236, 106, 100), (212, 136, 32),
    (160, 170, 0), (116, 196, 0), (76, 208, 32), (56, 204, 108),
    (56, 180, 204), (60, 60, 60), (0, 0, 0), (0, 0, 0),
    (236, 238, 236), (168, 204, 236), (188, 188, 236), (212, 178, 236),
    (236, 174, 236), (236, 174, 212), (236, 180, 176), (228, 196, 144),
    (204, 210, 120), (180, 222, 120), (168, 226, 144), (152, 226, 180),
    (160, 214, 228), (160, 162, 160), (0, 0, 0), (0, 0, 0)
]

# PILパレット作成
PALETTE_IMG_DATA = []
for r, g, b in NES_PALETTE_RGB:
    PALETTE_IMG_DATA.extend((r, g, b))
PALETTE_IMG_DATA.extend((0, 0, 0) * (256 - len(NES_PALETTE_RGB)))
PALETTE_IMG = Image.new("P", (1, 1))
PALETTE_IMG.putpalette(PALETTE_IMG_DATA)

MAX_CHR_SIZE = 0x20000  # 128KB上限

def convert_image_to_nes_tiles(img_path):
    img = Image.open(img_path).convert("RGB")
    img = img.quantize(palette=PALETTE_IMG, dither=Image.Dither.FLOYDSTEINBERG)
    
    width, height = img.size
    pixels = np.array(img)
    
    tiles = []
    tile_map = []
    tile_dict = {}

    for ty in range(0, height // 8):
        for tx in range(0, width // 8):
            tile_data = pixels[ty*8:(ty+1)*8, tx*8:(tx+1)*8]
            tile_key = tile_data.tobytes()

            if tile_key not in tile_dict:
                tile_dict[tile_key] = len(tiles)
                tiles.append(tile_data)
            
            tile_map.append(tile_dict[tile_key])
            
    return tiles, tile_map, tile_dict

def tile_to_2bpp(tile):
    """8x8(0〜3値) → NES 2bpp(16byte)変換"""
    out = bytearray()
    for y in range(8):
        plane0 = 0
        plane1 = 0
        for x in range(8):
            pixel = tile[y][x] & 0x03
            plane0 |= ((pixel >> 0) & 1) << (7 - x)
            plane1 |= ((pixel >> 1) & 1) << (7 - x)
        out.append(plane0)
        out.append(plane1)
    return bytes(out)

def main(frames_dir, chr_out_path, map_out_path):
    frame_files = sorted(glob.glob(f"{frames_dir}/*.png"))
    global_tiles = []
    global_tile_dict = {}
    frame_maps = []
    
    print(f"Processing {len(frame_files)} frames...")

    for f in frame_files:
        tiles, tile_map, tile_dict = convert_image_to_nes_tiles(f)
        frame_maps.append(tile_map)
        for tile_key, _ in tile_dict.items():
            if tile_key not in global_tile_dict:
                global_tile_dict[tile_key] = len(global_tiles)
                global_tiles.append(np.frombuffer(tile_key, dtype=np.uint8).reshape(8, 8))

    print(f"Found {len(global_tiles)} unique tiles.")

    # CHR出力
    total_bytes = 0
    with open(chr_out_path, 'wb') as f_chr:
        for tile_data in global_tiles:
            chr_bytes = tile_to_2bpp(tile_data)
            if total_bytes + len(chr_bytes) > MAX_CHR_SIZE:
                print(f"⚠️ CHR data reached 128KB limit. Stopping at {len(global_tiles)} tiles.")
                break
            f_chr.write(chr_bytes)
            total_bytes += len(chr_bytes)
    print(f"Wrote CHR data ({total_bytes} bytes) to {chr_out_path}")

    # MAP出力
    last_map = None
    with open(map_out_path, 'wb') as f_map:
        for i, current_map in enumerate(frame_maps):
            diff_data = bytearray()
            if i == 0:
                for addr, tile_id in enumerate(current_map):
                    diff_data.extend([(addr >> 8) & 0xFF, addr & 0xFF, tile_id & 0xFF])
            else:
                for addr, tile_id in enumerate(current_map):
                    if tile_id != last_map[addr]:
                        diff_data.extend([(addr >> 8) & 0xFF, addr & 0xFF, tile_id & 0xFF])
            last_map = current_map
            f_map.write(len(diff_data).to_bytes(2, 'little'))
            f_map.write(diff_data)
    print(f"Wrote MAP data to {map_out_path}")

if __name__ == "__main__":
    if len(sys.argv) != 4:
        print("Usage: python video_converter.py <frames_dir> <output.chr> <output.map>")
        sys.exit(1)
    main(sys.argv[1], sys.argv[2], sys.argv[3])
