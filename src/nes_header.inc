.segment "HEADER"
.byte "NES", $1A
.byte 2           ; PRG-ROM (16KB * 2 = 32KB)
.byte 1           ; CHR-ROM (8KB * 1 = 8KB) (未使用)
.byte %00010001   ; Mapper 4 (MMC3) Lo, V-Mirror
.byte %01000000   ; Mapper 4 (MMC3) Hi
.byte 0,0,0,0,0,0,0,0
