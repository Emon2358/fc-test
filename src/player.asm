.include "nes_header.inc"
.include "mmc3.inc"

; ================================================
; [修正] 不足していたPPUレジスタの定義を追加
; ================================================
PPUCTRL   = $2000
PPUMASK   = $2001
PPUSTATUS = $2002
PPUADDR   = $2006
PPUDATA   = $2007
; ================================================

.segment "ZEROPAGE"
frame_idx:     .res 2
frame_delay:   .res 1
map_data_ptr:  .res 2
diff_len:      .res 2
diff_ptr:      .res 2

.segment "RODATA"
AudioData:
    .incbin "build/sound.dmc"
AudioDataEnd:

.segment "CODE"

; Pythonスクリプトが出力するデータ
.segment "VIDEO_CHR"
VideoChrData:
    .incbin "build/video_chr.bin"
VideoChrDataEnd:

.segment "VIDEO_MAP"
VideoMapData:
    .incbin "build/video_map.bin"
VideoMapDataEnd:

.proc RESET
    sei
    cld
    ldx #$FF
    txs
    
    jsr wait_vblank
    lda #0
    sta PPUCTRL ; $2000
    sta PPUMASK ; $2001
    sta $4015
    
    ; MMC3 PRGバンク設定
    lda #MMC3_CMD_PRG_ROM
    sta MMC3_CMD
    lda #<VideoMapData ; $8000 にマップデータのバンクをセット
    sta MMC3_DATA
    
    lda #MMC3_CMD_PRG_ROM | %01000000
    sta MMC3_CMD
    lda #<AudioData ; $A000 にオーディオデータのバンクをセット
    sta MMC3_DATA

    ; APU (DPCM) 設定
    lda #$0F       ; IRQ無効, ループ無効, レート 15734Hz
    sta $4010
    lda #%10000000 ; DPCM開始アドレス ($A000)
    sta $4012
    lda #((AudioDataEnd - AudioData) / 64)
    sta $4013

    ; ビデオ再生準備
    lda #0
    sta frame_idx
    sta frame_idx+1
    sta frame_delay
    lda #<VideoMapData
    sta map_data_ptr
    lda #>VideoMapData
    sta map_data_ptr+1

    ; PPUオン
    jsr wait_vblank
    lda #%10000000 ; NMI有効
    sta PPUCTRL ; $2000
    lda #%00011110 ; BG/Sprite表示ON
    sta PPUMASK ; $2001
    
    ; DPCM再生開始
    lda #%00010000
    sta $4015

MainLoop:
    jmp MainLoop

wait_vblank:
    bit PPUSTATUS ; $2002
@wait:
    bit PPUSTATUS ; $2002
    bpl @wait
    rts
.endproc

.proc NMI
    pha
    txa
    pha
    tya
    pha
    
    ; 15fps (4フレームに1回更新)
    lda frame_delay
    bne @skip_frame
    lda #3
    sta frame_delay

    ; フレームが最後までいったらループ
    lda frame_idx
    cmp #<FRAME_COUNT
    lda frame_idx+1
    sbc #>FRAME_COUNT
    bcc @frame_ok
    ; ループ
    lda #0
    sta frame_idx
    sta frame_idx+1
    lda #<VideoMapData
    sta map_data_ptr
    lda #>VideoMapData
    sta map_data_ptr+1
@frame_ok:

    ; 1. CHRバンク切り替え (Pythonスクリプトの実装に合わせて)
    ; (注: Pythonスクリプトは現在 1bpp のみ出力するため、
    ;  CHRバンク切り替えは未実装でも動作します)

    ; 2. 差分マップデータ転送
    ; [データ長Lo, データ長Hi] を読み込む
    ldy #0
    lda (map_data_ptr), y
    sta diff_len
    iny
    lda (map_data_ptr), y
    sta diff_len+1
    
    ; データポインタを進める
    clc
    lda map_data_ptr
    adc #2
    sta map_data_ptr
    bcc @no_carry
    inc map_data_ptr+1
@no_carry:
    ; 差分データ本体のアドレスをセット
    lda map_data_ptr
    sta diff_ptr
    lda map_data_ptr+1
    sta diff_ptr+1

    ; VRAMにデータを転送
    ldy #0
@diff_loop:
    ; 残りデータ長をチェック
    lda diff_len
    ora diff_len+1
    beq @diff_done ; データ長が0なら終了

    ; [アドレスH, アドレスL, タイルID] を読み込む
    ; アドレスH
    lda (diff_ptr), y
    sta PPUADDR ; $2006
    iny
    ; アドレスL (ネームテーブル $2000 を足す)
    lda (diff_ptr), y
    clc
    adc #$20 ; $20xx
    sta PPUADDR ; $2006
    iny
    ; タイルID
    lda (diff_ptr), y
    sta PPUDATA ; $2007
    iny
    
    ; データ長カウンタを3減らす
    lda diff_len
    sec
    sbc #3
    sta diff_len
    lda diff_len+1
    sbc #0
    sta diff_len+1
    
    jmp @diff_loop
    
@diff_done:
    ; map_data_ptr を次のフレームへ進める (diff_ptr - map_data_ptr)
    lda diff_ptr
    clc
    adc diff_len ; (diff_lenは今 0 または負なので)
    sta map_data_ptr
    lda diff_ptr+1
    adc diff_len+1
    sta map_data_ptr+1

    ; フレームインデックスを進める
    inc frame_idx
    bne @nmi_exit
    inc frame_idx+1
    
    jmp @nmi_exit

@skip_frame:
    dec frame_delay

@nmi_exit:
    pla
    tay
    pla
    tax
    pla
    rti
.endproc

; --- ベクタテーブル ---
.segment "VECTORS"
.addr NMI, RESET, 0
