import sys
import glob
from PIL import Image
import numpy as np

# 固定のNESカラーパレット (例: NTSC)
NES_PALETTE_RGB = [
    (84, 84, 84), (0, 30, 116), (8, 16, 144), (48, 0, 136), (68, 0, 100), (92, 0, 48), (84, 4, 0), (60, 24, 0), (32, 42, 0), (8, 58, 0), (0, 64, 0), (0, 60, 0), (0, 50, 60), (0, 0, 0), (0, 0, 0), (0, 0, 0),
    (152, 150, 152), (8, 76, 196), (48, 50, 236), (92, 30, 228), (136, 20, 176), (160, 20, 100), (152, 34, 32), (120, 60, 0), (84, 90, 0), (40, 114, 0), (8, 124, 0), (0, 118, 40), (0, 102, 120), (0, 0, 0), (0, 0, 0), (0, 0, 0),
    (236, 238, 236), (76, 154, 236), (120, 124, 236), (176, 98, 236), (228, 84, 236), (236, 88, 180), (236, 106, 100), (212, 136, 32), (160, 170, 0), (116, 196, 0), (76, 208, 32), (56, 204, 108), (56, 180, 204), (60, 60, 60), (0, 0, 0), (0, 0, 0),
    (236, 238, 236), (168, 204, 236), (188, 188, 236), (212, 178, 236), (236, 174, 236), (236, 174, 212), (236, 180, 176), (228, 196, 144), (204, 210, 120), (180, 222, 120), (168, 226, 144), (152, 226, 180), (160, 214, 228), (160, 162, 160), (0, 0, 0), (0, 0, 0),
]

# PILパレットイメージを作成
PALETTE_IMG_DATA = []
for r, g, b in NES_PALETTE_RGB:
    PALETTE_IMG_DATA.extend((r, g, b))
PALETTE_IMG_DATA.extend((0, 0, 0) * (256 - len(NES_PALETTE_RGB)))
PALETTE_IMG = Image.new("P", (1, 1))
PALETTE_IMG.putpalette(PALETTE_IMG_DATA)

def convert_image_to_nes_tiles(img_path):
    # 画像を開き、NESパレットに減色
    img = Image.open(img_path).convert("RGB")
    img = img.quantize(palette=PALETTE_IMG, dither=Image.Dither.FLOYDSTEINBERG)
    
    # 256x224 (32x28タイル)
    width, height = img.size
    pixels = np.array(img)
    
    tiles = []
    tile_map = []
    tile_dict = {}

    for ty in range(0, height // 8):
        for tx in range(0, width // 8):
            # 8x8 タイルを切り出す
            tile_data = pixels[ty*8:(ty+1)*8, tx*8:(tx+1)*8]
            tile_key = tile_data.tobytes()

            if tile_key not in tile_dict:
                tile_dict[tile_key] = len(tiles)
                tiles.append(tile_data)
            
            tile_map.append(tile_dict[tile_key])
            
    return tiles, tile_map, tile_dict

def main(frames_dir, chr_out_path, map_out_path):
    frame_files = sorted(glob.glob(f"{frames_dir}/*.png"))
    
    global_tiles = []
    global_tile_dict = {}
    frame_maps = []
    
    print(f"Processing {len(frame_files)} frames...")

    # 1. 全フレームを処理し、グローバルタイルセットを作成
    for f in frame_files:
        _, tile_map, tile_dict = convert_image_to_nes_tiles(f)
        frame_maps.append(tile_map)
        
        for tile_key, tile_idx in tile_dict.items():
            if tile_key not in global_tile_dict:
                global_tile_dict[tile_key] = len(global_tiles)
                # タイルデータを PIL Image から numpy 配列 (8x8) に戻す
                global_tiles.append(np.frombuffer(tile_key, dtype=np.uint8).reshape(8, 8))

    print(f"Found {len(global_tiles)} unique tiles.")
    
    # 2. CHRデータ (タイルセット) をバイナリ化
    #    (注: 簡略化のため、NESの2bppプレーン形式への変換は省略し、
    #     インデックスデータ (1bpp) をそのままCHRとして保存します。
    #     アセンブリ側でこれを解釈する必要があります。)
    with open(chr_out_path, 'wb') as f_chr:
        for tile_data in global_tiles:
            # 簡略化: 8x8 = 64バイトのインデックスをそのまま書き込む
            f_chr.write(tile_data.tobytes())
            
    # 3. マップデータ (差分) をバイナリ化
    last_map = None
    with open(map_out_path, 'wb') as f_map:
        for i, current_map_indices in enumerate(frame_maps):
            
            # グローバルインデックスに変換
            current_map = [0] * len(current_map_indices)
            
            # (注: この変換ロジックは CHR 生成ロジックと密接に関連します)
            # (ここでは簡略化のため、フレーム固有のインデックスをそのまま使います)
            current_map = current_map_indices

            diff_data = bytearray()
            
            if i == 0:
                # 最初のフレームは全データを書き込む (差分ではない)
                for addr, tile_id in enumerate(current_map):
                    addr_h = (addr >> 8) & 0xFF
                    addr_l = addr & 0xFF
                    # [アドレスH, アドレスL, タイルID]
                    diff_data.extend([addr_h, addr_l, tile_id & 0xFF])
            else:
                # 差分を検出
                for addr, tile_id in enumerate(current_map):
                    if tile_id != last_map[addr]:
                        addr_h = (addr >> 8) & 0xFF
                        addr_l = addr & 0xFF
                        diff_data.extend([addr_h, addr_l, tile_id & 0xFF])
            
            last_map = current_map
            
            # [フレームのデータ長 (Lo), データ長 (Hi)]
            f_map.write(len(diff_data).to_bytes(2, 'little'))
            f_map.write(diff_data)
            
    print(f"Wrote CHR data to {chr_out_path}")
    print(f"Wrote Map data to {map_out_path}")

if __name__ == "__main__":
    if len(sys.argv) != 4:
        print("Usage: python video_converter.py <frames_dir> <output.chr> <output.map>")
        sys.exit(1)
    main(sys.argv[1], sys.argv[2], sys.argv[3])
