import sys
import mido
import math
from collections import defaultdict

# MIDIノート番号をNES APUの周波数レジスタ値に変換するテーブル (NTSC)
NOTE_TO_NES_PERIOD = [
    0x7FF, 0x78D, 0x721, 0x6B9, 0x656, 0x5F8, 0x5A0, 0x54C, 0x4FB, 0x4AF, 0x467, 0x422, # 0-11
    0x3E1, 0x3A3, 0x368, 0x330, 0x2FA, 0x2C8, 0x29A, 0x26E, 0x245, 0x21E, 0x1F9, 0x1D6, # 12-23
    0x1B5, 0x195, 0x177, 0x15B, 0x140, 0x127, 0x110, 0x0FA, 0x0E6, 0x0D3, 0x0C2, 0x0B2, # 24-35
    0x0A3, 0x095, 0x088, 0x07C, 0x071, 0x066, 0x05C, 0x053, 0x04B, 0x043, 0x03C, 0x035, # 36-47
    0x030, 0x02A, 0x025, 0x021, 0x01D, 0x01A, 0x017, 0x014, 0x011, 0x00F, 0x00C, 0x00A, # 48-59 (C4=48)
    0x008, 0x006, 0x004, 0x002, 0x001, 0x000, 0x000, 0x000, 0x000, 0x000, 0x000, 0x000, # 60+ (範囲外)
]
TRIANGLE_NOTE_OFFSET = 12 # 三角波は1オクターブ低く鳴るため

# ノイズチャンネル用のピッチ (MIDIノート番号 -> ノイズ周期 $400E の値)
DRUM_TO_NOISE_PERIOD = {
    35: 0x01, # Acoustic Bass Drum
    36: 0x01, # Bass Drum 1
    38: 0x04, # Acoustic Snare
    40: 0x04, # Electric Snare
    42: 0x08, # Closed Hi Hat
    44: 0x08, # Pedal Hi Hat
    46: 0x08, # Open Hi Hat
    49: 0x0C, # Crash Cymbal 1
    51: 0x0A, # Ride Cymbal 1
    57: 0x0C, # Crash Cymbal 2
}
DEFAULT_NOISE_PERIOD = 0x06 # デフォルト (Tambourineなど)

# NESチャンネル (0=Pulse1, 1=Pulse2, 2=Triangle, 3=Noise)
NES_CH_PULSE1 = 0
NES_CH_PULSE2 = 1
NES_CH_TRIANGLE = 2
NES_CH_NOISE = 3

# 出力データ形式
CMD_WAIT = 0x80      # 0x80 | (wait_ticks) -> 1～127 ticks 待機
CMD_NOTE_OFF = 0x40  # 0x40 | (channel) -> チャンネルの音を止める
CMD_NOTE_ON = 0x00   # 0x00 | (channel) -> [次のバイト: Lo, Hi] (Pulse/Tri)
                     # 0x00 | 3 (Noise) -> [次のバイト: Period] (Noise)

def convert_midi(midi_path, out_path):
    mid = mido.MidiFile(midi_path)
    
    ticks_per_beat = mid.ticks_per_beat if mid.ticks_per_beat > 0 else 480
    # 120BPM (500000 usec/beat) を仮定
    tempo = 500000
    ticks_to_nes_frames_ratio = (ticks_per_beat * (60.0 / 1000000.0)) / (tempo / 1000000.0)
    
    music_data = bytearray()
    
    # --- トラックの自動選定 ---
    track_note_counts = defaultdict(int)
    drum_track_indices = []
    melodic_track_indices = []
    
    # 1. 全トラックをスキャン
    for i, track in enumerate(mid.tracks):
        is_drum_track = False
        for msg in track:
            if msg.type == 'program_change' and msg.channel == 9:
                is_drum_track = True
            elif msg.type == 'note_on' and msg.channel == 9:
                 is_drum_track = True

        if is_drum_track:
            drum_track_indices.append(i)
        elif i > 0: # トラック0はテンポ情報として除外
            melodic_track_indices.append(i)
            for msg in track:
                if msg.type == 'note_on' and msg.velocity > 0:
                    track_note_counts[i] += 1
                    
    # 2. メロディ/ベースをノート数でソートし、上位3トラックを選定
    sorted_melodic_tracks = sorted(track_note_counts.items(), key=lambda item: item[1], reverse=True)
    
    track_map = {}
    if len(drum_track_indices) > 0:
        track_map[drum_track_indices[0]] = NES_CH_NOISE # 最初のドラムトラックをノイズに
        print(f"Assigning Track {drum_track_indices[0]} (Drum) to NES Noise (ch3)")
        
    if len(sorted_melodic_tracks) > 0:
        track_map[sorted_melodic_tracks[0][0]] = NES_CH_PULSE1
        print(f"Assigning Track {sorted_melodic_tracks[0][0]} (Notes: {sorted_melodic_tracks[0][1]}) to NES Pulse 1 (ch0)")
    if len(sorted_melodic_tracks) > 1:
        track_map[sorted_melodic_tracks[1][0]] = NES_CH_PULSE2
        print(f"Assigning Track {sorted_melodic_tracks[1][0]} (Notes: {sorted_melodic_tracks[1][1]}) to NES Pulse 2 (ch1)")
    if len(sorted_melodic_tracks) > 2:
        track_map[sorted_melodic_tracks[2][0]] = NES_CH_TRIANGLE
        print(f"Assigning Track {sorted_melodic_tracks[2][0]} (Notes: {sorted_melodic_tracks[2][1]}) to NES Triangle (ch2)")
        
    # --- MIDIイベントのマージと変換 ---
    merged_events = []
    for i, track in enumerate(mid.tracks):
        if i not in track_map:
            continue
            
        nes_channel = track_map[i]
        current_time_ticks = 0
        for msg in track:
            current_time_ticks += msg.time
            if msg.type == 'note_on' or msg.type == 'note_off':
                merged_events.append((current_time_ticks, msg, nes_channel))
            elif msg.type == 'set_tempo':
                # (簡易テンポ計算)
                tempo = msg.tempo
                ticks_to_nes_frames_ratio = (ticks_per_beat * (60.0 / 1000000.0)) / (tempo / 1000000.0)
                
    merged_events.sort(key=lambda x: x[0])

    # イベントをNESデータに変換
    last_nes_time = 0
    for (time_ticks, msg, nes_channel) in merged_events:
        
        nes_time = int(time_ticks / ticks_to_nes_frames_ratio)
        wait_time = nes_time - last_nes_time
        
        while wait_time > 0:
            wait_chunk = min(wait_time, 127)
            music_data.append(CMD_WAIT | wait_chunk)
            wait_time -= wait_chunk
            
        if msg.type == 'note_on' and msg.velocity > 0:
            note = msg.note
            if nes_channel == NES_CH_NOISE:
                period = DRUM_TO_NOISE_PERIOD.get(note, DEFAULT_NOISE_PERIOD)
                music_data.append(CMD_NOTE_ON | nes_channel)
                music_data.append(period) # [Period]
            
            elif nes_channel == NES_CH_TRIANGLE:
                note += TRIANGLE_NOTE_OFFSET
                if note < len(NOTE_TO_NES_PERIOD):
                    period = NOTE_TO_NES_PERIOD[note]
                    period_hi = (period >> 8) & 0x07
                    period_lo = period & 0xFF
                    music_data.append(CMD_NOTE_ON | nes_channel)
                    music_data.append(period_lo) # [Lo, Hi]
                    music_data.append(period_hi)
                    
            else: # Pulse 1 or 2
                if note < len(NOTE_TO_NES_PERIOD):
                    period = NOTE_TO_NES_PERIOD[note]
                    period_hi = (period >> 8) & 0x07
                    period_lo = period & 0xFF
                    music_data.append(CMD_NOTE_ON | nes_channel)
                    music_data.append(period_lo) # [Lo, Hi]
                    music_data.append(period_hi)
                    
        else: # note_off または velocity 0
            music_data.append(CMD_NOTE_OFF | nes_channel)
            
        last_nes_time = nes_time
        
    music_data.append(CMD_WAIT | 127)

    with open(out_path, 'wb') as f:
        f.write(music_data)
    print(f"Wrote {len(music_data)} bytes of music data to {out_path}")

if __name__ == "__main__":
    if len(sys.argv) != 3:
        print("Usage: python midi_converter.py <input.mid> <output.bin>")
        sys.exit(1)
    convert_midi(sys.argv[1], sys.argv[2])
