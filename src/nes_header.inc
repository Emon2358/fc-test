.segment "HEADER"
.byte "NES", $1A
.byte 32          ; PRG-ROM (16KB * 32 = 512KB) ※動画サイズに応じて要調整
.byte 32          ; CHR-ROM (8KB * 32 = 256KB) ※動画サイズに応じて要調整
.byte %00010000   ; Mapper 4 (MMC3) Lo, V-Mirror
.byte %01000000   ; Mapper 4 (MMC3) Hi
.byte 0,0,0,0,0,0,0,0
