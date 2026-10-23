; ----------------------------------------------------------------------------
;
; U64 BBC BASIC -- Acorn compatibility: keys, analogue channels, *FX
;
; Bank 9 (.local acorn). INKEY(-n) scans one key of the C64 keyboard by
; the BBC's internal key number, INKEY(-256) gives &FF (BBC B, OS 1.2);
; ADVAL(0-4) reads the joysticks, paddles or a 1351 mouse in the control
; ports (*ADVAL picks which), ADVAL(-1) the keys waiting; the OSBYTEs
; *FX 4, 11, 12, 19, 163, 200 and 220. Design:
; docs/DESIGN_ACORN.md.
;
; ----------------------------------------------------------------------------

    .local acorn
    icl 'bankhelp.s'

; State in the KERNAL's RS-232 variables ($0293-$029E: the KERNAL uses
; them only while device 2 is open, which the MOS never does; RAMTAS
; clears them at the cold start, so 0 is every default)
ac_ports    = $0293             ; port modes: bits 0-1 port 1, 2-3 port 2
                                ; (0 joystick, 1 paddles, 2 mouse)
ac_fx4      = $0294             ; *FX 4 (cursor keys), kept
ac_fx200    = $0295             ; *FX 200
ac_fx220    = $0296             ; *FX 220: the escape character EOR 27
ac_mpot     = $0297             ; 4: mouse: the last POT x, y (port 1, 2)
ac_mpos     = $029B             ; 4: mouse: position x, y 0-255 (port 1, 2)
    .if ac_mpos+4 > $029F
    .error "Acorn state overflows the RS-232 variables"
    .endif

AC_T        = MOSBUF+$00        ; scratch (4)
AC_D        = MOSBUF+$04        ; the mouse's movement
POTX        = $D419
POTY        = $D41A
RPTFLG      = $028A             ; KERNAL: key repeat ($80 all, $40 none)
NDXC        = $C6               ; KERNAL: keys in the keyboard buffer

; ----------------------------------------------------------------------------
; ac_scan
;   Summary: INKEY(-n): OSBYTE &81 with Y = &FF. X = 0 (INKEY(-256)):
;            the machine, &FF = BBC B with OS 1.2 (Y = 0). Else X = the
;            internal key number EOR &FF: is that key held?
;   Function: the BBC key -> its C64 key (ac_keytab: matrix column and
;            row, and whether Shift must be held or not: the C64's
;            cursor and function keys share a key between two codes);
;            the matrix read with interrupts off (the KERNAL scans it in
;            its interrupt). SHIFT is either Shift key.
;   Input:   X.  Output: X = Y = &FF held, X = Y = 0 not.
;   Uses:    A, X, Y, AC_T.
ac_scan:
    cpx #0
    bne asc_key
    ldx #$C0                    ; INKEY(-256): &Cx=Commodore, &C0=Commodore 64
    ldy #0
    rts
asc_key:
    txa
    eor #$FF
    cmp #AC_NKEYS
    bcs asc_no
    tax
    lda ac_keytab,x
    cmp #$FF
    beq asc_no
    sta AC_T+2
    stx AC_T+3
    and #$3F
    jsr ac_key
    bcs asc_held
    lda AC_T+3                  ; SHIFT: the right Shift key too
    bne asc_no
    lda #$34
    jsr ac_key
    bcc asc_no
asc_held:
    lda AC_T+2                  ; Shift needed (bit 6) or not (bit 7)?
    and #$C0
    beq asc_yes
    jsr ac_shift
    lda AC_T+2
    bmi asc_noshift
    bcc asc_no
    bcs asc_yes
asc_noshift:
    bcs asc_no
asc_yes:
    ldx #$FF
    ldy #$FF
    rts
asc_no:
    ldx #0
    ldy #0
    rts

; ac_shift: C = 1 if a Shift key is held
ac_shift:
    lda #$0F
    jsr ac_key
    bcs ash_rts
    lda #$34
    jmp ac_key
ash_rts:
    rts

; ac_key: C = 1 if the key at matrix position A (column * 8 + row) is
; held. Uses: A, X, Y, AC_T, AC_T+1.
ac_key:
    tay
    and #7
    tax
    lda ac_bits,x
    sta AC_T                    ; the row's bit
    tya
    lsr
    lsr
    lsr
    tax
    lda ac_bits,x
    eor #$FF                    ; the column driven low
    php
    sei
    ldx $DC00
    stx AC_T+1
    sta $DC00
    lda $DC01
    lda $DC01                   ; (settled)
    ldx AC_T+1
    stx $DC00
    plp
    and AC_T
    bne ak_up
    sec
    rts
ak_up:
    clc
    rts
ac_bits:
    dta 1, 2, 4, 8, 16, 32, 64, 128

; The BBC's internal key numbers (INKEY(-n): n - 1) -> C64 matrix
; position column * 8 + row; + $40: with Shift, + $80: without Shift
; (cursor and function keys); $FF: no such key on the C64. f1-f8 are
; F1-F7 and Shift with them (as *KEY), COPY is F1, ESCAPE RUN/STOP,
; _ left-arrow, \ the pound key, ^ up-arrow; f0, f9, TAB, CAPS LOCK,
; SHIFT LOCK, [ and ] have no key.
N_          = $FF
ac_keytab:
    dta $0F, $3A, N_, N_, N_, N_, N_, N_          ; 0 SHIFT, CTRL, links
    dta N_, N_, N_, N_, N_, N_, N_, N_            ; 8
    dta $3E, $08, $0B, $10, $45, $1B, $83, $2B    ; 16 Q 3 4 5 f4 8 f7 -
    dta $36, $42, N_, N_, N_, N_, N_, N_          ; 24 ^ left
    dta N_, $09, $0E, $16, $18, $21, $20, $23     ; 32 f0 W E T 7 I 9 0
    dta $39, $87, N_, N_, N_, N_, N_, N_          ; 40 _ down
    dta $38, $3B, $12, $11, $13, $1E, $26, $29    ; 48 1 2 D R 6 U O P
    dta N_, $47, N_, N_, N_, N_, N_, N_           ; 56 [ up
    dta N_, $0A, $17, $15, $19, $22, $25, $2E     ; 64 CAPS A X F Y J K @
    dta $2D, $01, N_, N_, N_, N_, N_, N_          ; 72 : RETURN
    dta N_, $0D, $14, $1A, $1D, $27, $2A, $32     ; 80 SLOCK S C G H N L ;
    dta N_, $00, N_, N_, N_, N_, N_, N_           ; 88 ] DELETE
    dta N_, $0C, $3C, $1F, $1C, $24, $2F, $2C     ; 96 TAB Z SPC V B M , .
    dta $37, $84, N_, N_, N_, N_, N_, N_          ; 104 / COPY
    dta $3F, $84, $44, $85, $86, $46, $43, N_     ; 112 ESC f1 f2 f3 f5 f6 f8 f9
    dta $30, $82                                  ; 120 \ right
AC_NKEYS    = * - ac_keytab

; ----------------------------------------------------------------------------
; ac_adval
;   Summary: ADVAL (OSBYTE &80): X = 1-4 the analogue channels (BBC
;            joystick 1 = control port 2: channels 1 x, 2 y; joystick 2 =
;            port 1: 3 x, 4 y), 0..&FFF0, high = left / up; X = 0: the
;            fire buttons (bit 0 joystick 1, bit 1 joystick 2), Y = 4
;            (the last channel converted); X = &FF: keys waiting.
;   Function: each port as *ADVAL set it: a joystick (&FFF0, &8000 or 0),
;            paddles (the SID's POT lines: 255 - value, high byte) or a
;            1351 mouse (its position, moved by the POT lines' change).
;   Input:   X.  Output: X (low), Y (high).  Uses: A, X, Y, AC_T.
ac_adval:
    cpx #$FF
    bne aad_n
    ldx NDXC                    ; ADVAL(-1): keys in the buffer
    ldy #0
    rts
aad_n:
    cpx #0
    bne aad_ch
    lda #2                      ; ADVAL(0): fire buttons, port 2 (BBC
    jsr ac_fire                 ; joystick 1) in bit 0, port 1 in bit 1
    lda #0
    rol
    sta AC_T+3
    lda #1
    jsr ac_fire
    lda #0
    rol
    asl
    ora AC_T+3
    tax
    ldy #4
    rts
aad_ch:
    cpx #5
    bcc aad_ok
    ldx #0
    ldy #0
    rts
aad_ok:
    stx AC_T+3                  ; the channel
    lda #2                      ; 1, 2: port 2; 3, 4: port 1
    cpx #3
    bcc aad_port
    lda #1
aad_port:
    sta AC_T+2                  ; the port
    jsr ac_mode                 ; its mode
    cmp #1
    beq aad_paddle
    cmp #2
    beq aad_mouse
    lda AC_T+2                  ; joystick
    jsr ac_lines
    pha
    lda AC_T+3                  ; odd channel: x (left 4, right 8 -> 1, 2)
    lsr
    pla
    bcc aad_jy
    lsr
    lsr
aad_jy:
    lsr                         ; C = up / left
    bcs aad_max
    lsr                         ; C = down / right
    bcs aad_min
    ldx #0
    ldy #$80
    rts
aad_max:
    ldx #$F0
    ldy #$FF
    rts
aad_min:
    ldx #0
    ldy #0
    rts
aad_paddle:
    lda AC_T+2
    jsr ac_pots                 ; X = POT x, Y = POT y
    lda AC_T+3
    lsr
    bcs aad_px
    tya
    jmp aad_pv
aad_px:
    txa
aad_pv:
    eor #$FF                    ; 255 - value
    jmp aad_val
aad_mouse:
    lda AC_T+2
    jsr ac_mouse                ; the position moved
    ldx AC_T+2                  ; port 1: ac_mpos 0, 1; port 2: 2, 3
    dex
    txa
    asl
    tax
    lda AC_T+3
    lsr
    bcs aad_mx
    lda ac_mpos+1,x             ; y: high = up
    jmp aad_val
aad_mx:
    lda ac_mpos,x               ; x: high = left
    eor #$FF
aad_val:
    tay                         ; Y = high, X = high AND &F0 (12 bits)
    and #$F0
    tax
    rts

; ac_mode: A = port 1 or 2 -> A = its mode (0-2)
ac_mode:
    cmp #2
    lda ac_ports
    bcc amo_1
    lsr
    lsr
amo_1:
    and #3
    rts

; ac_fire: C = 1 if port A's fire is pressed (paddles: either paddle's
; button, the left / right lines)
ac_fire:
    pha
    jsr ac_lines
    sta AC_T
    pla
    jsr ac_mode
    cmp #1
    beq afi_pad
    lda AC_T
    and #$10
    cmp #$10
    rts
afi_pad:
    lda AC_T
    and #$0C
    cmp #1                      ; (C = 1 if not 0)
    rts

; ac_lines: A = port 1 or 2 -> A = its lines, 1 = active: bit 0 up,
; 1 down, 2 left, 3 right, 4 fire. Uses: A, X.
ac_lines:
    php
    sei
    ldx $DC00
    cmp #1
    bne ali_2
    lda #$FF                    ; port 1: on the keyboard rows, no column
    sta $DC00                   ; driven
    lda $DC01
    jmp ali_got
ali_2:
    lda #$FF
    sta $DC00
    lda $DC00
ali_got:
    stx $DC00
    plp
    eor #$FF
    and #$1F
    rts

; ac_pots: A = port 1 or 2 -> X = POT x, Y = POT y of that port. The
; port is chosen with CIA 1's PA6/PA7 (port 1: PA6 high); the SID needs
; 512 cycles at 1 MHz to sample: nine raster lines are waited, with
; interrupts off (the KERNAL's scan would change PA6/PA7).
ac_pots:
    ldx #$7F                    ; port 1: PA7 low, PA6 high
    cmp #1
    beq apo_sel
    ldx #$BF                    ; port 2: PA6 low, PA7 high
apo_sel:
    php
    sei
    lda $DC00
    pha
    stx $DC00
    ldx #9
apo_line:
    lda $D012
apo_same:
    cmp $D012
    beq apo_same
    dex
    bne apo_line
    ldx POTX
    ldy POTY
    pla
    sta $DC00
    plp
    rts

; ac_mouse: A = port 1 or 2: the 1351's movement since the last read
; (its POT lines count the position modulo 64, in bits 1-6) added to
; ac_mpos, kept within 0-255. Read often enough: more than 31 counts
; between two reads come out the wrong way.
ac_mouse:
    pha
    jsr ac_pots
    stx AC_T                    ; POT x, y
    sty AC_T+1
    pla
    sec
    sbc #1
    asl
    tax                         ; 0 or 2
    lda AC_T
    jsr amo_delta
    jsr amo_add
    inx
    lda AC_T+1
    jsr amo_delta
    jmp amo_add
; amo_delta: A = POT value, X = slot: A = the signed movement (counts),
; the value kept
amo_delta:
    and #$7E
    pha
    sec
    sbc ac_mpot,x
    and #$7F
    cmp #$40
    bcc amd_pos
    ora #$80                    ; -64..-1 (7 bits sign-extended)
amd_pos:
    cmp #$80                    ; / 2, the sign kept
    ror
    sta AC_D
    pla
    sta ac_mpot,x
    lda AC_D
    rts
; amo_add: ac_mpos,x + A (signed), kept within 0-255
amo_add:
    cmp #0
    bmi ama_neg
    clc
    adc ac_mpos,x
    bcc ama_set
    lda #255
    bne ama_set
ama_neg:
    clc
    adc ac_mpos,x
    bcs ama_set
    lda #0
ama_set:
    sta ac_mpos,x
    rts

; ----------------------------------------------------------------------------
; cmd_adval
;   Summary: *ADVAL [JOY|PADDLE|MOUSE [port]]: what ADVAL reads from a
;            control port (no port: JOY both, PADDLE and MOUSE port 1);
;            alone it lists both ports.
;   Function: the mode into ac_ports; a mouse starts in the middle, its
;            POT lines read once (no jump at the first ADVAL).
;   Input:   mosPTR/Y.  Output: ac_ports.  Uses: A, X, Y, mosNUM, AC_T.
cmd_adval:
    jsr s6_skipsp
    cmp #13
    bne cad_set
    jmp cad_list
cad_set:
    ldx #2
cad_word:
    stx AC_T+3
    lda cad_words_lo,x
    pha
    lda cad_words_hi,x
    tax
    pla
    jsr s6_word
    bcs cad_found
    ldx AC_T+3
    dex
    bpl cad_word
    jmp s6_syntax
cad_found:
    jsr s6_num                  ; the port (none: the default)
    bcc cad_port
    jsr s6_end
    lda AC_T+3
    bne cad_def1
    lda #0                      ; JOY: both ports
    sta ac_ports
    rts
cad_def1:
    lda #1                      ; PADDLE, MOUSE: port 1
    bne cad_one
cad_port:
    jsr s6_end
    lda mosNUM+1
    bne cad_bad
    lda mosNUM
    cmp #1
    beq cad_one
    cmp #2
    beq cad_one
cad_bad:
    brk
    dta 252, 'Bad port', 0
cad_one:
    sta AC_T+2                  ; the port
    cmp #1
    bne cad_p2
    lda ac_ports
    and #$0C
    ora AC_T+3
    jmp cad_store
cad_p2:
    lda AC_T+3
    asl
    asl
    sta AC_T
    lda ac_ports
    and #$03
    ora AC_T
cad_store:
    sta ac_ports
    lda AC_T+3
    cmp #2
    bne cad_rts
    lda AC_T+2                  ; a mouse: in the middle, POT lines read
    jsr ac_pots
    stx AC_T
    sty AC_T+1
    lda AC_T+2
    sec
    sbc #1
    asl
    tax
    lda AC_T
    and #$7E
    sta ac_mpot,x
    lda AC_T+1
    and #$7E
    sta ac_mpot+1,x
    lda #128
    sta ac_mpos,x
    sta ac_mpos+1,x
cad_rts:
    rts
cad_list:
    lda #1
    jsr cad_line
    lda #2
cad_line:
    pha
    jsr s6_text
    dta 'Port ', 0
    pla
    pha
    ora #'0'
    jsr OSWRCH
    jsr s6_text
    dta ': ', 0
    pla
    jsr ac_mode
    tax
    lda cad_words_lo,x
    sta mosPTR2
    lda cad_words_hi,x
    sta mosPTR2+1
    ldy #0
cadl_c:
    lda (mosPTR2),y
    beq cadl_e
    jsr OSWRCH
    iny
    bne cadl_c
cadl_e:
    jmp OSNEWL
cad_words_lo:
    dta <cad_joy, <cad_pad, <cad_mou
cad_words_hi:
    dta >cad_joy, >cad_pad, >cad_mou
cad_joy     dta 'JOY', 0
cad_pad     dta 'PADDLE', 0
cad_mou     dta 'MOUSE', 0

; ----------------------------------------------------------------------------
; ac_byte
;   Summary: OSBYTEs from the BBC this MOS adds: &04 cursor keys (kept;
;            GET and INKEY always give 136-139), &0B / &0C keyboard
;            repeat (the KERNAL's: X = 0 off for &0B; &0C 0 its default;
;            other values: every key repeats, at the KERNAL's speed),
;            &13 wait for the frame's end, &A3 (GXR's 242: accepted),
;            &C8 bit 0: ESCAPE off, &DC the escape character.
;   Input:   by_a, X, Y.  Output: X = the old value (where there is one).
;   Uses:    A, X, Y.
ac_byte:
    lda by_a
    cmp #$04
    bne ab_n4
    lda ac_fx4
    stx ac_fx4
    tax
    rts
ab_n4:
    cmp #$0B
    bne ab_n11
    lda #$40                    ; 0: no repeat
    cpx #0
    beq ab_rpt
    lda #$80
ab_rpt:
    sta RPTFLG
    ldx #0
    rts
ab_n11:
    cmp #$0C
    bne ab_n12
    lda #0                      ; 0: the default (cursor keys, space,
    cpx #0                      ; DEL repeat)
    beq ab_rpt
    lda #$80
    bne ab_rpt
ab_n12:
    cmp #$13
    bne ab_n19
    php                         ; *FX 19: to the bottom border (raster
    cli                         ; line 256 on)
ab_vs1:
    bit $D011                   ; out of the border first
    bmi ab_vs1
ab_vs2:
    bit $D011
    bpl ab_vs2
    plp
    rts
ab_n19:
    cmp #$C8
    bne ab_n200
    lda ac_fx200
    pha
    stx ac_fx200
    lda escdis                  ; bit 1 of escdis: ESCAPE off by *FX 200
    and #$FD
    sta escdis
    txa
    and #1
    asl
    ora escdis
    sta escdis
    pla
    tax
    rts
ab_n200:
    cmp #$DC
    bne ab_rts
    lda ac_fx220                ; (stored EOR 27: 0 is the default 27)
    eor #27
    pha
    txa
    eor #27
    sta ac_fx220
    pla
    tax
ab_rts:
    rts                         ; (&A3: nothing)

    .endl
