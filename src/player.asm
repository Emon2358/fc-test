; ================================================
; NES Video Player for NesTiler
; Mapper: MMC3
; ================================================

.include "nes_header.inc"
.include "mmc3.inc"

; --- ZEROPAGE (高速アクセス用メモリ) ---
.segment "ZEROPAGE"
frame_idx:     .res 2  ; 現在のフレームインデックス (Word)
frame_delay:   .res 1  ; 60fps -> 15fps 調整用 (4フレームに1回更新)

; --- RAM ---
.segment "RAM"
dma_page:      .res 256 ; $0200-$02FF, ネームテーブルDMA転送用バッファ

; --- RODATA (各種データ) ---
.segment "RODATA"
AudioData:
    .incbin "build/sound.dmc"
AudioDataEnd:

; --- CODE (メインプログラム) ---
.segment "CODE"

; NesTilerが出力するデータ
; MMC3のバンクに配置される
.segment "VIDEO_CHR"
VideoChrData:
    .incbin "build/video_chr.bin"
VideoChrDataEnd:

.segment "VIDEO_MAP"
VideoMapData:
    .incbin "build/video_map.bin"
VideoMapDataEnd:

; ================================================
;  RESET - 起動時処理
; ================================================
.proc RESET
    sei          ; 割り込み禁止
    cld          ; デシマルモード解除
    ldx #$FF
    txs          ; スタックポインタ初期化

    jsr wait_vblank
    
    ; PPU/APUを無効化
    lda #0
    sta PPUCTRL
    sta PPUMASK
    sta $4015
    
    ; MMC3 初期化
    ; CHR A12 Invert ($0000-$0FFF と $1000-$1FFF を逆)
    lda #%10000000
    sta MMC3_CMD
    lda #0
    sta MMC3_DATA
    
    ; PRGバンク設定 (C000-DFFF を固定)
    lda #MMC3_CMD_PRG_ROM | %01000000
    sta MMC3_CMD
    lda #<VideoMapData ; C000にマップデータのバンクをセット
    sta MMC3_DATA      ; ※リンカ設定で要調整

    ; 1. APU (DPCM) の設定
    lda #$0F       ; IRQ無効, ループ無効, レート 15734Hz
    sta $4010
    lda #0         ; DPCM開始アドレス ($C000)
    sta $4012
    lda #((AudioDataEnd - AudioData) / 64) ; DPCMデータ長
    sta $4013

    ; 2. ビデオ再生の準備
    lda #0
    sta frame_idx
    sta frame_idx+1
    sta frame_delay

    ; 3. PPUをオン
    jsr wait_vblank
    lda #%10000000 ; NMI有効, スプライト8x8
    sta PPUCTRL
    lda #%00011110 ; BG/Sprite表示ON
    sta PPUMASK
    
    ; 4. DPCM再生開始
    lda #%00010000 ; DPCMチャンネルをON
    sta $4015

    ; 5. メインループ (NMIに全てを任せる)
MainLoop:
    jmp MainLoop

; --- VBlank待機サブルーチン ---
wait_vblank:
    bit PPUSTATUS
@wait:
    bit PPUSTATUS
    bpl @wait
    rts
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
    
    ; --- フレームレート調整 (15fps) ---
    lda frame_delay
    bne @skip_frame
    lda #3 ; 4フレーム待機 (0, 1, 2, 3)
    sta frame_delay
    
    ; --- フレームが最後までいったらループ ---
    lda frame_idx
    cmp #<FRAME_COUNT ; .D FRAME_COUNT=xx で渡される
    lda frame_idx+1
    sbc #>FRAME_COUNT
    bcc @frame_ok
    ; ループ
    lda #0
    sta frame_idx
    sta frame_idx+1
@frame_ok:

    ; =================================
    ; 1. CHRバンク (パターン) 切り替え
    ; =================================
    ; NesTilerは1フレームあたり4KB (4 * 1KBバンク) のCHRを使用
    ; frame_idx * 4 を計算
    lda frame_idx
    asl
    asl
    ; この値をMMC3のCHRバンク R2, R3, R4, R5 にセット
    
    ; R2 ($1000)
    sta MMC3_DATA
    lda #MMC3_CMD_CHR_2
    sta MMC3_CMD
    
    ; R3 ($1400)
    clc
    adc #1
    sta MMC3_DATA
    lda #MMC3_CMD_CHR_3
    sta MMC3_CMD

    ; R4 ($1800)
    clc
    adc #1
    sta MMC3_DATA
    lda #MMC3_CMD_CHR_4
    sta MMC3_CMD

    ; R5 ($1C00)
    clc
    adc #1
    sta MMC3_DATA
    lda #MMC3_CMD_CHR_5
    sta MMC3_CMD

    ; =================================
    ; 2. ネームテーブル (マップ) 転送
    ; =================================
    ; NesTilerは1フレームあたり 960バイト (32x30) のマップデータを出力
    ; 転送元アドレス = VideoMapData + (frame_idx * 960)
    ; 960 = $03C0
    
    ; (frame_idx * $03C0) の計算は重いので、
    ; DMAバッファ($0200)にデータをコピーする
    
    ; ... (アドレス計算とデータコピーロジック) ...
    ; ここでは簡略化のため、PRGバンクから$0200へのコピー処理を記述
    ; (実際にはもっと複雑なバンク切り替えとポインタ計算が必要)
    
    ; --- DMA転送 ---
    lda #0
    sta PPUADDR ; $2006
    sta PPUADDR ; アドレスを $0000 に
    
    ; $2000 (ネームテーブル0) に転送
    lda #$20
    sta PPUADDR
    lda #$00
    sta PPUADDR
    
    lda #>dma_page ; $02
    sta $4014      ; DMA転送開始 (バッファ $0200-$02FF)
    
    ; ... (960バイトは256バイトx4回弱の転送が必要) ...
    ; (NMI時間内に収めるため、実際には複数フレームに分割して転送する)

    ; --- フレームを進める ---
    inc frame_idx
    bne @nmi_exit
    inc frame_idx+1
    
    jmp @nmi_exit

@skip_frame:
    dec frame_delay ; 待機フレーム数を減らす

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
