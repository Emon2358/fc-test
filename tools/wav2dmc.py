import sys
import numpy as np
from scipy.io import wavfile

# NES DPCMのデルタ変調をシミュレートするクラス
class DmcEncoder:
    def __init__(self):
        self.level = 64  # 初期レベル (0-127)
        self.shift = 0
        self.bits = 0

    def encode_sample(self, sample):
        # ----------------------------------------------------
        # [修正]
        # sample (numpy.int16) を先に int() でPythonの int に変換し、
        # OverflowError を防ぎます。
        target_level = (int(sample) + 32768) >> 9
        # ----------------------------------------------------
        
        bit_data = 0
        
        if target_level > self.level and self.level < 126:
            self.level += 2
            bit_data = 1
        elif target_level < self.level and self.level > 1:
            self.level -= 2
            bit_data = 0
        
        self.bits = (self.bits >> 1) | (bit_data << 7)
        self.shift += 1
        
        if self.shift == 8:
            byte_out = self.bits
            self.shift = 0
            self.bits = 0
            return byte_out
        return None

def main(wav_path, dmc_path):
    try:
        sample_rate, data = wavfile.read(wav_path)
    except Exception as e:
        print(f"Error reading WAV file: {e}")
        print("Ensure WAV is 16-bit PCM mono.")
        sys.exit(1)

    # ステレオならモノラルに
    if data.ndim > 1:
        data = data.mean(axis=1)
        
    encoder = DmcEncoder()
    dmc_bytes = bytearray()

    print(f"Read {len(data)} samples from WAV.")

    for sample in data:
        dmc_byte = encoder.encode_sample(sample)
        if dmc_byte is not None:
            dmc_bytes.append(dmc_byte)
            
    # パディング
    while len(dmc_bytes) % 16 != 0:
        dmc_bytes.append(0x55) # 一般的なパディング

    with open(dmc_path, 'wb') as f:
        f.write(dmc_bytes)
        
    print(f"Wrote {len(dmc_bytes)} bytes to {dmc_path}.")

if __name__ == "__main__":
    if len(sys.argv) != 3:
        print("Usage: python wav2dmc.py <input.wav> <output.dmc>")
        sys.exit(1)
    main(sys.argv[1], sys.argv[2])
