.include "nes_header.inc"
.include "mmc3.inc"

; ================================================
; APU (サウンド) レジスタ定義
; ================================================
APU_PULSE1_CTRL = $4000
APU_PULSE1_SWEEP = $4001
APU_PULSE1_LO = $4002
APU_PULSE1_HI = $4003

APU_PULSE2_CTRL = $4004
APU_PULSE2_SWEEP = $4005
APU_PULSE2_LO = $4006
APU_PULSE2_HI = $4007

APU_TRI_CTRL = $4008
APU_TRI_LO = $400A
APU_TRI_HI = $400B

APU_NOISE_CTRL = $400C
APU_NOISE_LO = $400E
APU_NOISE_HI = $400F

APU_SND_CTRL = $4015
; ================================================

.segment "ZEROPAGE"
music_ptr:     .res 2  ; 音楽データへのポインタ
wait_timer:    .res 1  ; NMI待機用タイマー

.segment "RODATA"
MusicData:
    .incbin "build/music_data.bin"
MusicDataEnd:

.segment "CODE"

.proc RESET
    sei          ; 割り込み禁止
    cld
    ldx #$FF
    txs          ; スタックポインタ初期化

    lda #%10000000 ; NMI有効
    sta $2000      ; PPUCTRL
    
    ; APU (サウンド) 初期化
    lda #0
    sta APU_SND_CTRL ; 全チャンネルを無効化
    
    ; パルス波1 (Duty 50%, 音量 10)
    lda #%01101010 
    sta APU_PULSE1_CTRL
    ; パルス波2 (Duty 50%, 音量 10)
    lda #%01101010
    sta APU_PULSE2_CTRL
    ; 三角波 (音量ON)
    lda #%10000000
    sta APU_TRI_CTRL
    ; ノイズ (音量 10)
    lda #%00101010
    sta APU_NOISE_CTRL
    
    ; 音楽データポインタとタイマーを初期化
    lda #<MusicData
    sta music_ptr
    lda #>MusicData
    sta music_ptr+1
    lda #0
    sta wait_timer
    
    ; APUチャンネルを有効化 (DPCM以外)
    lda #%00001111
    sta APU_SND_CTRL
    
    cli          ; 割り込み許可 (NMI開始)
    
MainLoop:
    jmp MainLoop

.endproc

; ================================================
;  NMI - 毎フレーム (60Hz) 実行
; ================================================
.proc NMI
    pha
    
    lda wait_timer
    beq @process_music
    dec wait_timer
    jmp @nmi_exit
    
@process_music:
    ldy #0
    lda (music_ptr), y
    
    bmi @cmd_wait      ; $80-$FF (CMD_WAIT)
    
    and #%01000000
    bne @cmd_note_off  ; $40-$7F (CMD_NOTE_OFF)
    
; $00-$3F (CMD_NOTE_ON)
@cmd_note_on:
    lda (music_ptr), y
    and #%00000011 ; チャンネル番号 (0, 1, 2, 3)
    tay ; Y = チャンネル番号
    
    ; データポインタをインクリメント (データ部へ)
    inc music_ptr
    bne @ptr_ok1
    inc music_ptr+1
@ptr_ok1:
    
    ; Y (チャンネル番号) でジャンプ
    cpy #0
    beq @note_on_pulse1
    cpy #1
    beq @note_on_pulse2
    cpy #2
    beq @note_on_triangle
    
@note_on_noise:
    ; [Period] (1バイト)
    ldy #0
    lda (music_ptr), y ; Period
    sta APU_NOISE_LO   ; ノイズ周期
    lda #%00101010     ; 音量リセット (エンベロープ再開)
    sta APU_NOISE_CTRL
    lda #%10000000     ; 長さカウンタON
    sta APU_NOISE_HI
    jmp @cmd_done

@note_on_triangle:
    ; [Lo, Hi] (2バイト)
    ldy #0
    lda (music_ptr), y ; Lo byte
    sta APU_TRI_LO
    iny
    lda (music_ptr), y ; Hi byte
    sta APU_TRI_HI
    inc music_ptr ; ポインタを1バイト余分に進める
    jmp @cmd_done

@note_on_pulse1:
    ; [Lo, Hi] (2バイト)
    ldy #0
    lda (music_ptr), y ; Lo byte
    sta APU_PULSE1_LO
    iny
    lda (music_ptr), y ; Hi byte
    sta APU_PULSE1_HI
    lda #%10000000     ; 長さカウンタON
    sta APU_PULSE1_HI, x ; (Hiに上書き)
    inc music_ptr
    jmp @cmd_done
    
@note_on_pulse2:
    ; [Lo, Hi] (2バイト)
    ldy #0
    lda (music_ptr), y ; Lo byte
    sta APU_PULSE2_LO
    iny
    lda (music_ptr), y ; Hi byte
    sta APU_PULSE2_HI
    lda #%10000000     ; 長さカウンタON
    sta APU_PULSE2_HI, x
    inc music_ptr
    jmp @cmd_done

@cmd_note_off:
    lda (music_ptr), y
    and #%00000011
    
    cmp #0
    beq @note_off_pulse1
    cmp #1
    beq @note_off_pulse2
    cmp #2
    beq @note_off_triangle
    
@note_off_noise:
    lda #0
    sta APU_NOISE_CTRL ; 音量 0
    jmp @cmd_done

@note_off_triangle:
    lda #0
    sta APU_TRI_CTRL ; Linear counter 0
    jmp @cmd_done

@note_off_pulse1:
    lda #%01100000 ; 音量 0
    sta APU_PULSE1_CTRL
    jmp @cmd_done
    
@note_off_pulse2:
    lda #%01100000 ; 音量 0
    sta APU_PULSE2_CTRL
    jmp @cmd_done

@cmd_wait:
    lda (music_ptr), y
    and #%01111111
    sta wait_timer
    
@cmd_done:
    inc music_ptr
    bne @nmi_exit
    inc music_ptr+1
    
@nmi_exit:
    pla
    rti
.endproc

; --- ベクタテーブル ---
.segment "VECTORS"
.addr NMI, RESET, 0
