; ================================================
; NES Video Player for pinobatch
; Mapper: MMC3
; ================================================

.include "nes_header.inc"
.include "mmc3.inc"

; --- ZEROPAGE (高速アクセス用メモリ) ---
.segment "ZEROPAGE"
frame_ptr:     .res 2  ; 現在のフレームデータへのポインタ
frame_delay:   .res 1  ; フレームレート調整用
ppu_addr_lo:   .res 1  ; PPU転送先アドレス
ppu_addr_hi:   .res 1

; --- RAM ---
.segment "RAM"
dma_buffer:    .res 256 ; OAM DMA / VRAM DMA兼用バッファ

; --- RODATA (DPCMデータ) ---
.segment "RODATA"
AudioData:
    .incbin "build/sound.dmc"
AudioDataEnd:

; --- CODE (メインプログラム) ---
.segment "CODE"
.proc RESET
    ; 1. CPUとPPUの初期化
    sei          ; 割り込み禁止
    cld          ; デシマルモード解除
    ldx #$FF
    txs          ; スタックポインタ初期化
    
    jsr wait_vblank ; 最初のVBlankを待つ
    
    ; PPUをオフ
    lda #0
    sta PPUCTRL
    sta PPUMASK

    ; MMC3 初期化
    ; (PRGバンクとCHRバンクの設定)
    ; ... (ここでは簡略化) ...
    
    ; 2. APU (DPCM) の設定
    ; DPCMデータを $C000-$FFFF にマッピング
    lda #MMC3_CMD_PRG_ROM
    sta MMC3_CMD
    lda #8  ; $C000-$DFFF にバンク8をセット (データがあるバンクを指定)
    sta MMC3_DATA
    
    lda #$0F       ; IRQ無効, ループ無効, レート 15734Hz
    sta $4010
    lda #0         ; DPCM開始アドレス ($C000 -> $C000 + 0 * 64)
    sta $4012
    lda #((AudioDataEnd - AudioData) / 64) ; DPCMデータ長 (64バイト単位)
    sta $4013

    ; 3. ビデオ再生の準備
    lda #<video_frames ; `video_data.s` で定義されるラベル
    sta frame_ptr
    lda #>video_frames
    sta frame_ptr+1
    lda #0
    sta frame_delay

    ; 4. PPUをオン
    jsr wait_vblank
    lda #%10000000 ; NMI有効
    sta PPUCTRL
    lda #%00011110 ; BG/Sprite表示ON
    sta PPUMASK
    
    ; 5. DPCM再生開始
    lda #%00010000 ; DPCMチャンネルをON
    sta $4015

    ; 6. メインループ (フレームレート調整のみ)
MainLoop:
    lda frame_delay
    beq @skip_wait
    dec frame_delay
@skip_wait:
    jmp MainLoop

.endproc

; ================================================
;  NMI - 垂直ブランク割り込み (毎フレーム実行)
; ================================================
.proc NMI
    pha ; レジスタ退避
    txa
    pha
    tya
    pha
    
    ; --- フレームレート調整 ---
    lda frame_delay
    bne @skip_decode ; 0でなければまだ待つ
    
    lda #2 ; (例: 15fpsなら 60/15 = 4フレーム待つ。 30fpsなら 2)
    sta frame_delay

    ; --- pinobatch 差分データデコード ---
    ; pinobatch (vram-dma) 形式のデコード
    ; 形式: [PPUアドレスH, PPUアドレスL, データ長, ...データ...]
    
    ldy #0
    lda (frame_ptr), y
    cmp #$FF           ; 終端マーカーか？
    beq @video_end

    sta ppu_addr_hi    ; PPUアドレスH
    iny
    lda (frame_ptr), y
    sta ppu_addr_lo    ; PPUアドレスL
    iny
    lda (frame_ptr), y ; データ長
    tax                ; Xにデータ長を保存
    
    ; ポインタをデータ本体へ
    iny
    
    ; DMAバッファ ($0200) にデータをコピー
    ldy #0
@copy_loop:
    cpx #0
    beq @copy_done
    lda (frame_ptr), y
    sta dma_buffer, y
    iny
    dex
    jmp @copy_loop

@copy_done:
    ; Xに元のデータ長が残っている
    
    ; PPUアドレスをセット
    lda ppu_addr_hi
    sta PPUADDR
    lda ppu_addr_lo
    sta PPUADDR
    
    ; DMA転送開始
    lda #<dma_buffer
    sta $4014 ; OAMDMAレジスタだが、裏技的にVRAMにも転送できる (要タイミング調整)
              ; ※注: 安全なのは $2007 への手動書き込み
    
    ; フレームポインタを進める
    ; (省略...)
    
    jmp @nmi_exit

@video_end:
    ; 動画終了 -> ループ
    lda #<video_frames
    sta frame_ptr
    lda #>video_frames
    sta frame_ptr+1

@skip_decode:
    ; (処理なし)

@nmi_exit:
    pla ; レジスタ復帰
    tay
    pla
    tax
    pla
    rti
.endproc

; --- ベクタテーブル ---
.segment "VECTORS"
.addr NMI, RESET, 0

; --- CHRデータ (pinobatchが生成) ---
.segment "CHR"
.incbin "build/video_chr.bin"
