; ----------------------------------------------------------------------------
;
; U64 BBC BASIC -- cartridge bank 0: boot and MOS core
;
; Included by cart.s (assembled with -d:CART_EF=1 or -d:CART_TMB=1).
;
; Bank 0 is mapped at $8000-$BFFF during cold start and during every MOS
; call (through the trampoline in resident.s). BBC BASIC 3.10 is copied
; from bank 1 to the RAM underneath at cold start and runs from there with
; the cartridge switched off: the Ultimate 64 runs cartridge ROM fetches at
; 1 MHz but RAM at turbo speed. The KERNAL stays in place (screen editor,
; keyboard scan, IEC).
;
; Conventions used in the routine headers below:
;   Summary  what the routine is for
;   Function how it does it, where that is not obvious
;   Input    registers and memory it reads
;   Output   registers and memory it sets; "preserved" lists what is kept
;   Uses     zero page and MOS RAM it changes besides its outputs
;
; Interrupt safety: routines in this file run in the foreground only. They
; use the MOS zero page ($52-$5F). The IRQ, NMI and BRK handlers
; (resident.s) never touch it; state shared with them (TIME, keyboard
; buffer, ESCFLG) is read or changed with interrupts disabled where a
; partial update could be seen.
;
; ----------------------------------------------------------------------------

; ----------------------------------------------------------------------------
; CBM80 cartridge header: the KERNAL reset routine finds it and jumps to
; the cold start vector. The warm start vector (used by the KERNAL's NMI
; handler) is never taken, because the MOS installs its own NMI handler.

    dta a(cold), a(cold)
    dta $C3, $C2, $CD, $38, $30

; ----------------------------------------------------------------------------
; cold
;   Summary: cold start: initialise the machine and the MOS, enter BASIC.
;   Function: the KERNAL's own reset sequence (I/O, RAM test, vectors,
;            screen), then the MOS: resident code, state, BASIC's RAM copy,
;            turbo, vectors, keyboard, video, banner.
;   Input:   entered from the KERNAL reset with bank 0 mapped.
;   Output:  does not return.

cold:
    sei
    ldx #$FF
    txs
    cld
    stx $D016
    jsr K_IOINIT
    jsr K_RAMTAS
    jsr K_RESTOR
    jsr K_CINT
    sei
    lda #CART_MODE16
    sta CART_CTRL
    jsr resident_init
    lda #0                      ; sound engine, SID image (the interrupt
    farcall snd_setup, BANK_SND ; calls it: before anything may let one in)
    jsr core_init
    jsr engine_init
    jsr state_init
    jsr copy_basic
    jsr turbo_init              ; after state_init, which clears turbo_state
    jsr vectors_init
    jsr keyboard_init
    jsr video_init
    jsr workspace_init
    cli
    farcall fs_init, BANK_FS    ; find the Ultimate (up to 0.5 s)
    farcall sid_auto, BANK_FS   ; fewer than 8 SIDs: the 8SID layout
    farcall net.uc_check, BANK_NET ; the Ultimate's settings (ultctl.s)
    jsr font_to_reu             ; fonts for MODE changes and bitmap text
    farcall fo_mkascii, BANK_FS ; (the ASCII-order one, font.s)
    jsr key_init                ; no *KEY texts
    lda #0                      ; Upic full: auto-show on, nothing drawn
    sta UP_DIRTY
    sta FONT46                  ; (the REU font: the normal glyphs)
    sta DF_EXEC                 ; no *EXEC, no *SPOOL (WRCHV is set anew)
    sta DF_SPCH
    lda reu_banks               ; GXR sprites: none (with an REU)
    ora reu_banks+1
    beq cold_nogxr
    farcall gxr.gxr_cold, BANK_RD
    farcall spr.sp_cold, BANK_RD ; (no SpritePad colours)
cold_nogxr:
    farcall font_keepdef, BANK_FS ; and the start-up font for *FONT DEFAULT
    farcall snd_instinit, BANK_SND ; default instruments to the REU
    farcall rd_boot, BANK_RD    ; the REU RAM disk
    farcall net.net_init, BANK_NET ; no JSON reply kept
    jsr ul_detect               ; Upic Lite possible?
    farcall aud.aud_init, BANK_AUD ; Ultimate Audio found? (sample.s)
    farcall rnd_seed, BANK_GFX   ; RND: another sequence every start
    jsr banner
    jmp enter_lang

; ----------------------------------------------------------------------------
; turbo_init
;   Summary: run at the maximum speed of the device.
;   Function: on the Ultimate 64 / C64 Ultimate speed index 15 is always
;            the hardware maximum (48 or 64 MHz), so no probe is needed to
;            select it. $D031 reads $FF without turbo registers (Ultimate
;            II+, stock C64, VICE): stock speed. In the firmware's "Turbo
;            Enable Bit" mode $D031 reads $00 and $D030 bit 0 switches turbo
;            on at the speed set in the menu.
;            Register semantics: ultimate-uci-oscar64 TURBOCONTROL_MANUAL.md.
;   Input:   none.
;   Output:  turbo_state = 0 none, 1 enable bit, 2 U64 registers at max.
;   Uses:    A, X.

turbo_init:
    ldx #0
    lda U64_TURBO
    cmp #$FF
    beq turbo_set
    lda U64_TURBOEN
    cmp #$FF
    bne turbo_enbit
    lda #TURBO_MAX
    sta U64_TURBO
    ldx #2
    bne turbo_set
turbo_enbit:
    ora #1
    sta U64_TURBOEN
    ldx #1
turbo_set:
    stx turbo_state
    rts

; ----------------------------------------------------------------------------
; resident_init
;   Summary: copy the resident MOS (1K) from this bank to $C400-$C7FF.
;   Input:   none.
;   Output:  RAM $C400-$C7FF.
;   Uses:    A, X, Y, mosPTR, mosPTR2.

resident_init:
    lda #<res_load
    sta mosPTR
    lda #>res_load
    sta mosPTR+1
    lda #<RESIDENT
    sta mosPTR2
    lda #>RESIDENT
    sta mosPTR2+1
    ldx #4                      ; 4 pages
    ldy #0
resi_loop:
    lda (mosPTR),y
    sta (mosPTR2),y
    iny
    bne resi_loop
    inc mosPTR+1
    inc mosPTR2+1
    dex
    bne resi_loop
    rts

; ----------------------------------------------------------------------------
; core_init
;   Summary: copy the VDU core (2K) from this bank to CORE ($C800-$CFFF).
;   Function: the VDU driver runs from RAM at turbo speed; in cartridge
;            ROM it ran at 1 MHz (100 us per VDU byte).
;   Input:   none.  Output: core in RAM.  Uses: A, X, Y, mosPTR, mosPTR2.

core_init:
    lda #<core_load
    sta mosPTR
    lda #>core_load
    sta mosPTR+1
    lda #<CORE
    sta mosPTR2
    lda #>CORE
    sta mosPTR2+1
    ldx #8                      ; 8 pages
    ldy #0
coi_loop:
    lda (mosPTR),y
    sta (mosPTR2),y
    iny
    bne coi_loop
    inc mosPTR+1
    inc mosPTR2+1
    dex
    bne coi_loop
    rts

; ----------------------------------------------------------------------------
; ul_detect
;   Summary: Upic Lite needs 64 MHz and the Ultimate's palette commands:
;            sets ul_ok (core) if both are there.
;   Function: the speed probe (Christian Gleissner's raster-timed loop, as
;            uii_turbo_probe_max in ultimate-uci-oscar64) runs from RAM
;            (errbuf), since this bank runs at 1 MHz: 64,764 cycles take
;            fewer than 19 raster lines at 64 MHz, fewer than 26 at 48.
;            Measured until two results in a row agree (at most 50):
;            right after the cartridge starts the Ultimate may not run
;            at full speed yet (measured: 92 lines). The palette commands
;            must be there (pal_boot reads the current palette).
;   Uses:    A, X, Y, errbuf, mosTMP+2/+3.
ul_detect:
    lda #0
    sta ul_ok
    sta pal_ok
    farcall pal_boot, BANK_FS   ; palette commands (firmware 3.15a+)?
    bcs uld_nopal
    inc pal_ok
uld_nopal:
    lda turbo_state
    cmp #2
    bne uld_done
    ldx #probe_end-probe_load-1
uld_copy:
    lda probe_load,x
    sta errbuf,x
    dex
    bpl uld_copy
    lda #50                     ; up to 50 tries: right after the start
    sta mosTMP+2                ; the Ultimate may not run at full speed
    lda #$FF                    ; yet; two equal classes in a row decide
    sta mosTMP+3                ; (as uii_turbo_probe_max)
uld_probe:
    jsr errbuf
    ldx #2                      ; class: 2 = 64 MHz, 1 = 48 MHz, 0 = ?
    cmp #19
    bcc uld_class
    dex
    cmp #26
    bcc uld_class
    dex
uld_class:
    txa
    beq uld_again
    cmp mosTMP+3
    beq uld_decided
uld_again:
    stx mosTMP+3
    dec mosTMP+2
    bne uld_probe
    rts
uld_decided:
    sta cpu_class               ; (Upic full picks its renderer by it)
    cmp #2
    bne uld_done
    lda pal_ok
    sta ul_ok
uld_done:
    rts

; The probe, assembled for errbuf: A = raster lines for 64,764 cycles.
; Every loop-back is an absolute jmp (3 cycles), no I/O in the loop.
probe_load:
    org errbuf, probe_load
    php
    sei
prb_f1:
    lda $D011                   ; bottom of the frame...
    bpl prb_f1
prb_f2:
    lda $D011                   ; ...then the wrap to line 0
    bmi prb_f2
    lda #$20
prb_w:
    cmp $D012
    bne prb_w
    ldy #36                     ; 36 x 1799 cycles
prb_o:
    ldx #0
prb_i:
    dex
    beq prb_id
    jmp prb_i
prb_id:
    dey
    beq prb_od
    jmp prb_o
prb_od:
    lda $D012
    sec
    sbc #$20
    plp
    rts
probe_len = * - errbuf
    org probe_load + probe_len
probe_end:

; ----------------------------------------------------------------------------
; engine_init
;   Summary: copy the drawing engine (4K) from this bank to ENGINE
;            ($D000-$DFFF, the RAM under I/O), and point the RAM NMI/IRQ
;            vectors at $FFFA (used while the ROMs are out) at an RTI.
;   Function: with $01 = $33 the cartridge stays visible and the character
;            ROM replaces I/O at $D000: reads there see the ROM, writes
;            reach the RAM underneath. Interrupts are off meanwhile.
;   Input:   none.  Output: engine in RAM.  Uses: A, X, Y, mosPTR, mosPTR2.

engine_init:
    lda #<engine_load
    sta mosPTR
    lda #>engine_load
    sta mosPTR+1
    lda #<ENGINE
    sta mosPTR2
    lda #>ENGINE
    sta mosPTR2+1
    sei
    lda #$33
    sta $01
    ldx #16                     ; 16 pages
    ldy #0
eni_loop:
    lda (mosPTR),y
    sta (mosPTR2),y
    iny
    bne eni_loop
    inc mosPTR+1
    inc mosPTR2+1
    dex
    bne eni_loop
    lda #CPU_ROMS
    sta $01
    cli
    lda #0                      ; the VIC-II engine is in
    sta eng_kind
    lda #<nmi_rti               ; RAM vectors for ROM-less moments
    sta $FFFA
    sta $FFFE
    lda #>nmi_rti
    sta $FFFB
    sta $FFFF
    rts

; ----------------------------------------------------------------------------
; state_init
;   Summary: reset the MOS RAM variables.
;   Function: clears everything from tramp_tgt to ramvars_end (the keyboard
;            tables before it are filled by keyboard_init).
;   Input:   none.
;   Output:  curbank = bank 0, ESCFLG = 0, TIME = 0, cursor enabled,
;            empty VDU queue.
;   Uses:    A, X.

state_init:
    lda #BANK_MOS
    sta curbank
    ldx #ramvars_end-tramp_tgt-1
    lda #0
st_clear:
    sta tramp_tgt,x
    dex
    bpl st_clear
    sta ESCFLG
    lda #2
    sta timefrac
    lda #1
    sta curson
    rts

; ----------------------------------------------------------------------------
; vectors_init
;   Summary: set the BBC RAM vectors at $0200 and the KERNAL vectors.
;   Input:   none.
;   Output:  USERV..FSCV = defaults below; $0314 IRQ, $0316 BRK, $0318 NMI
;            and $028F keyboard decode point into the resident MOS.
;   Uses:    A, X.

vectors_init:
    ldx #NVECTORS*2-1
vec_loop:
    lda vector_defaults,x
    sta USERV,x
    dex
    bpl vec_loop
    lda #<irq_main
    sta CINV
    lda #>irq_main
    sta CINV+1
    lda #<irq_brk
    sta CBINV
    lda #>irq_brk
    sta CBINV+1
    lda #<irq_nmi
    sta NMINV
    lda #>irq_nmi
    sta NMINV+1
    lda #<irq_keylog
    sta KEYLOG
    lda #>irq_keylog
    sta KEYLOG+1
    rts

vector_defaults:
    dta a(enter_lang)           ; USERV
    dta a(enter_lang)           ; BRKV (until the language sets it)
    dta a(K_IRQ_EXIT)           ; IRQ1V (unused)
    dta a(K_IRQ_EXIT)           ; IRQ2V (unused)
    dta a(v_cli)                ; CLIV
    dta a(v_byte)               ; BYTEV
    dta a(v_word)               ; WORDV
    dta a(mos_wrch)             ; WRCHV: the VDU core runs from RAM
    dta a(v_rdch)               ; RDCHV
    dta a(v_file)               ; FILEV
    dta a(v_args)               ; ARGSV
    dta a(v_bget)               ; BGETV
    dta a(v_bput)               ; BPUTV
    dta a(v_gbpb)               ; GBPBV
    dta a(v_find)               ; FINDV
    dta a(enter_lang)           ; FSCV (unused)

; ----------------------------------------------------------------------------
; keyboard_init
;   Summary: BBC-style CAPS LOCK: unshifted letters type capitals.
;   Function: copies the KERNAL's unshifted and shifted decode tables
;            (65 bytes each) to RAM and swaps the letter entries
;            (PETSCII $41-$5A unshifted, $C1-$DA shifted). irq_keylog uses
;            the copies. Shift+C= no longer switches the character set.
;   Input:   none.
;   Output:  kt_unshift, kt_shift; MODE = $80.
;   Uses:    A, X, Y.

keyboard_init:
    ldx #64
kb_copy:
    lda $EB81,x
    sta kt_unshift,x
    lda $EBC2,x
    sta kt_shift,x
    dex
    bpl kb_copy
    ldx #64
kb_swap:
    lda kt_unshift,x
    cmp #$41
    bcc kb_next
    cmp #$5B
    bcs kb_next
    ldy kt_shift,x
    sta kt_shift,x
    tya
    sta kt_unshift,x
kb_next:
    dex
    bpl kb_swap
    lda #$80
    sta MODE
    rts

; ----------------------------------------------------------------------------
; video_init
;   Summary: set up the text screen: VIC bank 3, screen at $C000, font at
;            $F000 (RAM under the KERNAL: the VIC reads RAM there, and
;            writes always reach it), white on black like a BBC Micro.
;   Function: copies the C64 lower/upper case set (character ROM $D800,
;            2K) to FONT, then patches in the eight ASCII glyphs the C64
;            lacks (table 'glyphs', generated by tools/gentables.py), each
;            also inverted for its reverse-video twin at code + 128.
;   Input:   none.
;   Output:  font, VIC registers, HIBASE, colours; screen cleared.
;   Uses:    A, X, Y, mosPTR, mosPTR2, mosTMP. Interrupts are off while
;            the character ROM is mapped in (I/O is out then).

video_init:
    jsr font_init
    jmp vid_regs

; font_init
;   Summary: the text font at FONT: the C64 lower/upper case set from the
;            character ROM plus the eight ASCII glyphs it lacks.
;   Function: also used by the core (font_restore) after a bitmap mode
;            when there is no REU copy of the font.
;   Uses:    A, X, Y, mosPTR, mosPTR2, mosTMP.
font_init:
    sei
    lda #$33                    ; character ROM in, I/O out
    sta $01
    lda #<$D800
    sta mosPTR
    lda #>$D800
    sta mosPTR+1
    lda #<FONT
    sta mosPTR2
    lda #>FONT
    sta mosPTR2+1
    ldx #8                      ; 8 pages = 2K
    ldy #0
vid_font:
    lda (mosPTR),y
    sta (mosPTR2),y
    iny
    bne vid_font
    inc mosPTR+1
    inc mosPTR2+1
    dex
    bne vid_font
    lda #CPU_ROMS
    sta $01
    cli

    ldx #0                      ; patch the ASCII glyphs
vid_glyph:
    lda glyphs,x
    cmp #$FF
    beq vid_glyphs_done
    sta mosTMP                  ; screen code (< 128) -> FONT + code * 8
    lda #0
    sta mosTMP+1
    asl mosTMP
    rol mosTMP+1
    asl mosTMP
    rol mosTMP+1
    asl mosTMP
    rol mosTMP+1
    lda mosTMP
    sta mosPTR
    lda mosTMP+1
    clc
    adc #>FONT
    sta mosPTR+1
    lda mosTMP+1                ; reverse copy at code + 128
    adc #>[FONT+$400]
    sta mosPTR2+1
    lda mosTMP
    sta mosPTR2
    inx
    ldy #0
vid_gbyte:
    lda glyphs,x
    sta (mosPTR),y
    eor #$FF
    sta (mosPTR2),y
    inx
    iny
    cpy #8
    bne vid_gbyte
    beq vid_glyph
vid_glyphs_done:
    rts

vid_regs:
    lda $DD02                   ; VIC bank 3 ($C000-$FFFF)
    ora #$03
    sta $DD02
    lda $DD00
    and #$FC
    sta $DD00
    lda #$0C                    ; screen $C000, characters $F000
    sta $D018
    lda #>SCREEN
    sta HIBASE
    lda #0
    sta $D020
    sta $D021
    lda #1
    sta COLOR
    sta ttfg                     ; (the colour COLOUR 128 goes back to)
    lda #$93
    jmp putpet

; ----------------------------------------------------------------------------
; workspace_init
;   Summary: clear BASIC's workspace &0400-&07FF.
;   Function: it held the KERNAL's start-up screen (spaces), which BASIC
;            would show as resident integers of &20202020.
;   Input:   none.  Output: &0400-&07FF = 0.  Uses: A, X.

workspace_init:
    lda #0
    tax
wsi_loop:
    sta $0400,x
    sta $0500,x
    sta $0600,x
    sta $0700,x
    inx
    bne wsi_loop
    rts

; ----------------------------------------------------------------------------
; banner
;   Summary: print the start-up banner and the CPU speed in use.
;   Input:   turbo_state.
;   Output:  text on screen.
;   Uses:    A, X, Y, mosPTR.

banner:
    ldx #0
ban_loop:
    lda banner_text,x
    beq ban_speed
    jsr OSASCI
    inx
    bne ban_loop
ban_speed:
    lda turbo_state
    asl
    tax
    lda speed_texts,x
    sta mosPTR
    lda speed_texts+1,x
    sta mosPTR+1
    ldy #0
ban_sloop:
    lda (mosPTR),y
    beq ban_done
    jsr OSASCI
    iny
    bne ban_sloop
ban_done:
    rts

banner_text:
    dta 'U64 BBC BASIC 1.0.0', 13, 13, 'BASIC 3.10 (C)1983 Acorn', 13, 0

speed_texts:
    dta a(speed_none), a(speed_enbit), a(speed_max)
speed_none:
    dta 'CPU 1 MHz', 13, 13, 0
speed_enbit:
    dta 'CPU turbo (firmware speed)', 13, 13, 0
speed_max:
    dta 'CPU turbo (maximum)', 13, 13, 0

; ----------------------------------------------------------------------------
; dbg_filter (called from the VDU core through the trampoline)
;   Summary: remote debugger hook: recognise BASIC's TRACE output.
;   Function: with TRACE ON, BASIC prints "[n] " through OSWRCH before
;            each line it runs. In debug mode (MB_DEBUG bit 0) these bytes
;            are swallowed; at the "]" the line number goes to MB_LINENO
;            and dbg_line may pause. A "[" not followed by digits and "]"
;            is printed after all (dbg_flush).
;   Input:   A = byte (also in wr_a).
;   Output:  C = 1 if the byte was consumed.
;   Uses:    A, X, Y, dbg_*, mosNUM.
dbg_filter:
    ldx dbg_state
    bne df_in
    cmp #'['
    bne df_space
    lda #1
    sta dbg_state
    lda #0
    sta dbg_len
    sta dbg_num
    sta dbg_num+1
    sta dbg_skipsp
    sec
    rts
df_space:
    ldx dbg_skipsp              ; the space BASIC prints after "]"
    beq df_pass
    ldx #0
    stx dbg_skipsp
    cmp #' '
    bne df_pass
    sec
    rts
df_pass:
    clc
    rts
df_in:
    cmp #']'
    beq df_close
    cmp #'0'
    bcc df_abort
    cmp #'9'+1
    bcs df_abort
    ldx dbg_len
    cpx #5
    bcs df_abort
    inc dbg_len
    and #$0F                    ; dbg_num = dbg_num * 10 + digit
    pha
    lda dbg_num
    asl
    sta mosNUM
    lda dbg_num+1
    rol
    sta mosNUM+1                ; *2
    asl dbg_num
    rol dbg_num+1
    asl dbg_num
    rol dbg_num+1
    asl dbg_num
    rol dbg_num+1               ; *8
    lda dbg_num
    clc
    adc mosNUM
    sta dbg_num
    lda dbg_num+1
    adc mosNUM+1
    sta dbg_num+1               ; *10
    pla
    clc
    adc dbg_num
    sta dbg_num
    bcc df_digit
    inc dbg_num+1
df_digit:
    sec
    rts
df_close:
    lda dbg_len
    beq df_abort
    lda #0
    sta dbg_state
    lda #1
    sta dbg_skipsp
    jsr dbg_line
    sec
    rts
df_abort:
    jsr dbg_flush
    clc                         ; this byte is printed normally
    rts

; dbg_flush
;   Summary: print a "[" (and digits) that turned out not to be a trace.
;   Function: through wr_raw, not OSWRCH: this runs inside mos_wrch,
;            whose saved registers a nested OSWRCH would overwrite.
;   Uses:    A, X, Y, mosTMP.
dbg_flush:
    lda #0
    sta dbg_state
    lda #'['
    jsr wr_raw
    lda dbg_len
    beq dfl_done
    lda dbg_num                 ; at most 5 digits: print the number
    sta mosTMP
    lda dbg_num+1
    sta mosTMP+1
    jsr print_u16
dfl_done:
    rts

; print_u16
;   Summary: print mosTMP/mosTMP+1 in decimal, no leading zeros
;            (through wr_raw, for dbg_flush).
;   Uses:    A, X, Y, mosTMP, mosNUM.
print_u16:
    ldy #0                      ; 1 once a digit is printed
    ldx #8                      ; powers table index (10000 .. 1)
pu_digit:
    lda #'0'
    sta mosNUM
pu_sub:
    lda mosTMP
    sec
    sbc pu_pow,x
    pha
    lda mosTMP+1
    sbc pu_pow+1,x
    bcc pu_done
    sta mosTMP+1
    pla
    sta mosTMP
    inc mosNUM
    bne pu_sub
pu_done:
    pla
    lda mosNUM
    cmp #'0'
    bne pu_print
    cpy #0
    bne pu_print
    cpx #0                      ; always print the last digit
    bne pu_next
pu_print:
    jsr wr_raw
    ldy #1
pu_next:
    dex
    dex
    bpl pu_digit
    rts
pu_pow:
    dta a(1), a(10), a(100), a(1000), a(10000)

; dbg_line
;   Summary: a traced line is about to run: report it, maybe pause.
;   Function: MB_LINENO = line. Pauses when stepping (MB_DEBUG bit 1) or
;            at a breakpoint (MB_BREAK). Paused: MB_STATUS = 3, then waits
;            for a REQ_DEBUG request: 1 continue, 2 step (pause at the
;            next line), 3 stop (ESCAPE). RUN/STOP also ends the pause.
;            Interrupts keep running; the host reads memory meanwhile.
;   Input:   dbg_num.  Output: MB_LINENO, MB_DEBUG, MB_STATUS.
;   Uses:    A, X.
dbg_line:
    lda dbg_num
    sta MB_LINENO
    lda dbg_num+1
    sta MB_LINENO+1
    lda MB_DEBUG
    and #2
    bne dl_pause
    ldx #14
dl_break:
    lda MB_BREAK,x
    ora MB_BREAK+1,x
    beq dl_bnext
    lda MB_BREAK,x
    cmp dbg_num
    bne dl_bnext
    lda MB_BREAK+1,x
    cmp dbg_num+1
    beq dl_pause
dl_bnext:
    dex
    dex
    bpl dl_break
    rts
dl_pause:
    lda #3
    sta MB_STATUS
dl_wait:
    bit ESCFLG
    bmi dl_resume
    lda MB_HSEQ
    cmp MB_CSEQ
    beq dl_wait
    lda MB_REQ
    cmp #REQ_DEBUG
    bne dl_wait                 ; other requests wait for the prompt
    lda MB_LINE
    cmp #3
    bne dl_cont
    lda #$80                    ; stop: ESCAPE
    sta ESCFLG
    bne dl_ack
dl_cont:
    lda MB_DEBUG                ; 1 continue, 2 step
    and #$FD
    ldx MB_LINE
    cpx #2
    bne dl_setflags
    ora #2
dl_setflags:
    sta MB_DEBUG
dl_ack:
    lda #2
    sta MB_STATUS
    lda MB_HSEQ
    sta MB_CSEQ
    rts
dl_resume:
    lda #2
    sta MB_STATUS
    rts

; ----------------------------------------------------------------------------
; waitkey
;   Summary: wait for a key, with the blinking cursor if it is enabled.
;   Input:   curson.
;   Output:  A = PETSCII code of the key, or A = 0 if ESCAPE came first.
;   Uses:    A, X, Y; BLNSW and the KERNAL cursor state.

waitkey:
    lda curson                  ; the KERNAL's cursor: text screen only (in
    beq wk_loop                 ; the graphics modes $C000 is the colour
    lda vtype                   ; matrix, or Upic full's console, whose
    bne wk_loop                 ; cursor is the engine's)
    lda #0
    sta BLNSW
wk_loop:
    bit ESCFLG
    bmi wk_esc
    jsr key_avail               ; (typed, or a *KEY text going on)
    beq wk_loop
    jsr wk_hide
    jmp key_get
wk_esc:
    jsr wk_hide
    lda #0
    rts

; wk_hide
;   Summary: stop the cursor blinking and restore the character under it
;            (as the KERNAL does in its own input loop, $E5CD).
;   Input:   none.  Output: cursor hidden.  Uses: A, X, Y.
wk_hide:
    sei
    lda #1
    sta BLNSW
    lda BLNON
    beq wk_hidden
    lda GDBLN
    ldx GDCOL
    ldy #0
    sty BLNON
    jsr K_SETCURSOR
wk_hidden:
    cli
    rts

; ----------------------------------------------------------------------------
; mos_rdch (OSRDCH)
;   Summary: read one key.
;   Input:   none.
;   Output:  A = ASCII code, C = 0; or A = 27, C = 1 if ESCAPE is pending.
;            X, Y preserved. Keys without an ASCII meaning are skipped.
;            In *PETSCII mode (pet_on) A is the key's PETSCII code.
;   Uses:    rd_x, rd_y.

mos_rdch:
    stx rd_x
    sty rd_y
    lda #1                      ; GET: Upic full shows its picture first
    farcall upic.up_auto, BANK_UP ; (if it changed; upic.s)
rd_loop:
    bit ESCFLG
    bmi rd_esc
    jsr waitkey
    tax
    lda pet_on                  ; *PETSCII: GET gives the PETSCII code
    beq rd_asc
    txa
    clc
    bcc rd_ret
rd_asc:
    lda pet2asc,x
    beq rd_loop
    clc
    bcc rd_ret
rd_esc:
    lda #27
    sec
rd_ret:
    ldx rd_x
    ldy rd_y
    rts

; ----------------------------------------------------------------------------
; mos_byte (OSBYTE)
;   Summary: OSBYTE calls (*FX). Unknown calls return unchanged.
;   Function: looks A up in byte_codes and jumps to the matching handler
;            with the caller's X and Y restored.
;   Input:   A = call number, X and Y = parameters.
;   Output:  X and Y = results (call dependent); A preserved.
;   Uses:    by_a, by_x, by_y; handlers as noted.
;
;   Implemented: &00 OS version, &0F/&15 flush keyboard, &7C clear escape,
;   &7D set escape, &7E acknowledge escape, &80 ADVAL (0), &81 INKEY,
;   &82 high address, &83 OSHWM (PAGE), &84/&85 HIMEM, &86 POS/VPOS,
;   &87 character at cursor, &DA VDU queue, &E5 escape key on/off,
;   &CA keyboard status (CAPS LOCK), &04, &0B, &0C, &13, &A3, &C8, &DC
;   (bank 7, acorn.s),
;   &7F EOF# (filing system, bank 2), &72 shadow for the next MODE, &75
;   VDU status (bit 4: shadow mode).

mos_byte:
    sta by_a
    stx by_x
    sty by_y
    cmp #0
    bne by_look
    jmp by_osver
by_look:
    ldy #0
by_find:
    lda byte_codes,y
    beq by_unknown
    cmp by_a
    beq by_found
    iny
    bne by_find
by_unknown:
    ldx by_x
    ldy by_y
    lda by_a
    rts
by_found:
    tya
    asl
    tay
    lda byte_handlers+1,y
    pha
    lda byte_handlers,y
    pha
    ldx by_x
    ldy by_y
    rts

byte_codes:
    dta $0F, $15, $7C, $7D, $7E, $80, $81, $82, $83, $84, $85, $86
    dta $87, $DA, $E5, $7F, $72, $75, $CA, $65
    dta $04, $0B, $0C, $13, $A3, $C8, $DC, 0
byte_handlers:
    dta a(by_flush-1)
    dta a(by_flush-1)
    dta a(by_clresc-1)
    dta a(by_setesc-1)
    dta a(by_ackesc-1)
    dta a(by_adval-1)
    dta a(by_inkey-1)
    dta a(by_high-1)
    dta a(by_oshwm-1)
    dta a(by_himem-1)
    dta a(by_himem85-1)
    dta a(by_pos-1)
    dta a(by_char-1)
    dta a(by_vduq-1)
    dta a(by_escdis-1)
    dta a(by_eof-1)
    dta a(by_shadow-1)
    dta a(by_vdustat-1)
    dta a(by_kbdstat-1)
    dta a(by_http-1)
    dta a(by_acorn-1), a(by_acorn-1), a(by_acorn-1), a(by_acorn-1)
    dta a(by_acorn-1), a(by_acorn-1), a(by_acorn-1)

by_ret:
    lda by_a
    rts

by_osver:
    ldx #28                     ; Return %xx0x1xxx, 28=Commodore
    bne by_ret
by_flush:                       ; &0F, &15: empty the keyboard buffer
    lda #0                      ; (and stop a *KEY text)
    sta NDX
    sta kx_n
    beq by_ret
by_clresc:                      ; &7C: clear ESCAPE
    lda #0
    sta ESCFLG
    beq by_ret
by_setesc:                      ; &7D: set ESCAPE
    lda #$80
    sta ESCFLG
    bne by_ret
by_ackesc:                      ; &7E: X = $FF if ESCAPE was pending
    ldx #0
    bit ESCFLG
    bpl by_ret
    lda #0
    sta ESCFLG
    sta NDX                     ; drop the RUN/STOP code and type-ahead
    sta kx_n                    ; (and a *KEY text, as the BBC)
    jsr bae_exec                ; and an *EXEC file is closed
    ldx #$FF
    bne by_ret
by_adval:                       ; &80: X = &E4-&FB: sound queues of
    ldy #0                      ; voices 23-0 (free bytes, sndcmd.s);
    cpx #5                      ; &CC-&E3: the song's notes of voices
    bcc bad_ac                  ; 23-0; 0-4 and &FF (keys waiting): the
    cpx #$FF                    ; control ports (acorn.s); others 0
    bne bad_snd
bad_ac:
    jmp bad_acorn
bad_snd:
    cpx #$CC
    bcc bad_zero
    cpx #$FC
    bcs bad_zero
    farcall snd_adval, BANK_SND
    ldy #0
    jmp by_ret
bad_zero:
    ldx #0
    jmp by_ret
by_high:                        ; &82: no second processor
    ldx #$FF
    ldy #$FF
    bne by_ret
by_oshwm:                       ; &83: PAGE = &1D00 (&0800-&1CFF: MOSBUF,
    ldx #0                      ; the sound engine); &0900 under *SOUND NONE
    ldy #>OSHWM
    lda snd_on
    bne by_ret
    ldy #>OSHWM_NONE
    bne by_ret
by_himem:                       ; &84: HIMEM of the current mode (below
    ldx #0                      ; the graphics fast path and the sprite
    ldy fp_page                 ; multiplexer when they are there)
    bne bh84_rts
    ldy spr_page
    bne bh84_rts
    ldy vmode_himem
bh84_rts:
    jmp by_ret
by_himem85:                     ; &85: HIMEM for mode X (BASIC's MODE)
    farcall bk_himem, BANK_GFX
    lda spr_on                  ; *SPRITE ON: 5 pages lower in the VIC-II
    beq bh85_fp                 ; modes (HIMEM &8000 or &7C00; not Upic
    cpy #$7C                    ; Lite's, not Upic full's: no sprites)
    bcc bh85_fp
    txa
    and #$7F
    cmp #110
    bcs bh85_fp
    tya
    sec
    sbc #5
    tay
bh85_fp:                        ; graphics modes: 3 pages lower for the
    txa                         ; * graphics fast path (fastpath.s): MODE
    and #$7F                    ; 0-5, 103, 104, 110, 111 (as mode_tab;
    cmp #8                      ; other numbers as n AND 7, as MODE does)
    bcc bf_low
    cmp #100
    beq bh85_rts
    cmp #103
    beq bf_gfx
    cmp #104
    beq bf_gfx
    cmp #110
    beq bf_gfx
    cmp #111
    beq bf_gfx
    and #7
bf_low:
    cmp #6
    bcs bh85_rts
bf_gfx:
    tya
    sec
    sbc #3                      ; (fastpath.s FP_PAGES)
    tay
bh85_rts:
    ldx #0
    jmp by_ret
by_shadow:                      ; &72 (Master): X = 0 shadow, 1 normal
    lda shadow                  ; for the next MODE; X = the old setting
    eor #1                      ; (others: read only)
    pha
    cpx #2
    bcs bsh_read
    txa
    eor #1
    sta shadow
bsh_read:
    pla
    tax
    jmp by_ret
by_vdustat:                     ; &75: X = VDU status (bit 4: shadow)
    lda mode_shadow
    asl
    asl
    asl
    asl
    tax
    jmp by_ret
by_pos:                         ; &86: X = POS, Y = VPOS
    lda vtype
    beq bp_text
    lda tcx                     ; bitmap modes: inside the text window
    sec
    sbc twl
    tax
    lda tcy
    sec
    sbc twt
    tay
    jmp by_ret
bp_text:
    sec
    jsr K_PLOT                  ; X = row, Y = column
    stx mosTMP
    tya
    tax
    ldy mosTMP
    jmp by_ret
by_char:                        ; &87: X = character at cursor, Y = mode
    lda vtype
    beq bc_text
    cmp #2
    beq bc_ttx
    lda eng_kind                ; Upic full: its console is the text
    cmp #3                      ; screen
    beq bc_up
    ldx tcx                     ; bitmap modes: read from the pixels
    ldy tcy                     ; (gxblock.s, as the BBC: the glyphs
    farcall gxb.gxb_chr, BANK_RD ; compared)
    tax
    ldy vmode
    jmp by_ret
bc_ttx:                         ; MODE 7: the code in the screen memory
    lda #<TTXBUF                ; at the cursor: &7C00 + y * 40 + x
    ldx #>TTXBUF
    jsr bc_cell
    tax
    ldy #7
    jmp by_ret
bc_up:                          ; Upic full: its console at SCREEN, by
    lda #<SCREEN                ; the engine's text cursor
    ldx #>SCREEN
    jsr bc_cell
    and #$7F
    tax
    lda scr2asc,x
    tax
    ldy vmode
    jmp by_ret
; bc_cell: A = the byte at A/X (low/high) + tcy * 40 + tcx
bc_cell:
    sta mosTMP
    stx mosTMP+1
    ldx tcy
    beq bcc_x
bcc_row:
    lda mosTMP
    clc
    adc #40
    sta mosTMP
    bcc bcc_n
    inc mosTMP+1
bcc_n:
    dex
    bne bcc_row
bcc_x:
    ldy tcx
    lda (mosTMP),y
    rts
bc_text:
    ldy $D3                     ; KERNAL cursor column on the line
    lda ($D1),y
    and #$7F
    tax
    lda scr2asc,x
    tax
    ldy vmode
    jmp by_ret
by_vduq:                        ; &DA: new = (old AND Y) EOR X, old in X
    lda vduq
    sta mosTMP
    tya
    and vduq
    stx mosTMP+1
    eor mosTMP+1
    sta vduq
    ldx mosTMP
    jmp by_ret
by_eof:                         ; &7F: EOF#, X = channel -> X = $FF at end
    farcall fs_eof, BANK_FS
    jmp by_ret
; by_kbdstat (OSBYTE &CA)
;   Summary: the keyboard status byte, as the BBC's: new = (old AND Y)
;            EOR X, the old one returned in X.
;   Function: bit 4 = 0 CAPS LOCK on (caps_ofs 0; Shift+C= switches it),
;            bit 5 = 1 SHIFT LOCK off (there is none), bit 3 SHIFT and
;            bit 6 CTRL held (read only); setting bit 4 switches CAPS LOCK.
;   Input:   X, Y.  Output: X = the old status.  Uses: A, mosTMP.
by_http:                        ; &65: X/Y = the last HTTP status code
    farcall net.http_code, BANK_NET ; (nethttp.s; 0: none)
    jmp by_ret
by_kbdstat:
    lda caps_ofs                ; 8 (off) -> bit 4
    asl
    ora #$20
    sta mosTMP
    lda SHFLAG
    and #1                      ; SHIFT -> bit 3
    asl
    asl
    asl
    ora mosTMP
    sta mosTMP
    lda SHFLAG
    and #4                      ; CTRL -> bit 6
    asl
    asl
    asl
    asl
    ora mosTMP
    sta mosTMP                  ; old
    tya
    and mosTMP
    stx mosTMP+1
    eor mosTMP+1
    and #$10                    ; new CAPS LOCK
    lsr
    sta caps_ofs
    ldx mosTMP
    jmp by_ret
by_escdis:                      ; &E5: X <> 0 disables the ESCAPE key
    lda escdis                  ; (escdis bit 0; bit 1 is *FX 200's)
    and #1
    pha
    lda escdis
    and #2
    cpx #0
    beq bed_set
    ora #1
bed_set:
    sta escdis
    pla
    tax
    jmp by_ret
by_acorn:                       ; &04, &0B, &0C, &13, &A3, &C8, &DC: bank 7
    farcall acorn.ac_byte, BANK_TOOLS
    jmp by_ret
bae_exec:                       ; (by_ackesc) the *EXEC file closed
    ldy DF_EXEC
    beq bae_rts
    lda #0
    sta DF_EXEC
    jsr OSFIND
bae_rts:
    ldy by_y
    rts
bad_acorn:                      ; ADVAL 0-4, -1: bank 7
    farcall acorn.ac_adval, BANK_TOOLS
    jmp by_ret

; by_inkey (OSBYTE &81)
;   Summary: INKEY: wait up to a time for a key, or scan a key.
;   Input:   X + 256*Y = time in centiseconds (Y < $80); Y = $FF: key scan.
;   Output:  Y = 0, X = ASCII key, C = 0; or C = 1 with Y = $1B (ESCAPE)
;            or Y = $FF (time-out). Key scans: X = Y = &FF held, 0 not
;            (acorn.s); X = 0: X = &FF, Y = 0 (BBC B, OS 1.2).
;   Uses:    mosNUM, mosTMP, inkey_t0. TIME is read with interrupts off.

by_inkey:
    cpy #$FF
    bne ink_wait
    farcall acorn.ac_scan, BANK_TOOLS ; INKEY(-n), INKEY(-256)
    jmp by_ret
ink_wait:
    stx mosNUM
    sty mosNUM+1
    sei
    lda mostime
    sta inkey_t0
    lda mostime+1
    sta inkey_t0+1
    cli
    lda #2                      ; a long INKEY: Upic full shows its picture
    farcall upic.up_auto, BANK_UP ; (TIME goes on meanwhile)
ink_loop:
    bit ESCFLG
    bmi ink_esc
    jsr key_avail
    beq ink_time
    jsr key_get
    tax
    lda pet_on                  ; *PETSCII: the PETSCII code
    bne ink_pet
    lda pet2asc,x
    beq ink_loop
    tax
ink_pet:
    ldy #0
    clc
    jmp by_ret
ink_time:                       ; elapsed = TIME - start (16 bits)
    sei
    lda mostime
    sec
    sbc inkey_t0
    sta mosTMP
    lda mostime+1
    sbc inkey_t0+1
    cli
    cmp mosNUM+1
    bcc ink_loop
    bne ink_out
    lda mosTMP
    cmp mosNUM
    bcc ink_loop
ink_out:
    ldy #$FF
    sec
    jmp by_ret
ink_esc:
    ldy #$1B
    sec
    jmp by_ret

; ----------------------------------------------------------------------------
; mos_word (OSWORD)
;   Summary: OSWORD calls 0 (read line), 1 (read TIME), 2 (write TIME),
;            7 (SOUND), 8 (ENVELOPE), 9 (read a pixel), 10 (read a
;            character definition), 14 (read the clock, bank 2), &42
;            (REU data transfer, as the Master's sideways RAM). Other calls
;            return without action.
;   Input:   A = call number, X/Y = address of the parameter block.
;   Output:  per call.
;   Uses:    mosPTR = parameter block.

mos_word:
    stx mosPTR
    sty mosPTR+1
    cmp #0
    bne mw_not0
    jmp word0
mw_not0:
    cmp #1
    bne mw_not1
    jmp word1
mw_not1:
    cmp #2
    bne mw_not2
    jmp word2
mw_not2:
    cmp #7
    bne mw_not7
    farcall snd_word7, BANK_SND  ; SOUND (sndcmd.s)
    rts
mw_not7:
    cmp #8
    bne mw_not8
    farcall snd_word8, BANK_SND  ; ENVELOPE
    rts
mw_not8:
    cmp #9
    bne mw_not9
    jmp word9
mw_not9:
    cmp #10
    bne mw_not10
    jmp word10
mw_not10:
    cmp #$42
    bne mw_not42
    farcall sr_word, BANK_FS    ; REU data transfer (srcmd.s)
    rts
mw_not42:
    cmp #$70
    bne mw_not70
    farcall net.json_word, BANK_NET ; a JSON value (netcmd.s)
    rts
mw_not70:
    cmp #$71
    bne mw_not71
    farcall spr.spr_word, BANK_RD ; sprites (sprite.s)
    rts
mw_not71:
    cmp #14
    bne mw_not14
    farcall clock_word, BANK_FS ; OSWORD 14: read the clock
mw_not14:
    rts

; word0 (OSWORD 0)
;   Summary: read a line with the KERNAL screen editor.
;   Function: KERNAL CHRIN returns the edited logical line one character
;            at a time; each is converted to ASCII and stored if it is in
;            the accepted range and the buffer has room. RUN/STOP ends the
;            line (irq_main types RETURN) and sets ESCAPE. The newline is
;            echoed, as the BBC MOS does.
;   Input:   block: +0/+1 buffer, +2 maximum length, +3/+4 lowest and
;            highest accepted character.
;   Output:  buffer filled, CR terminated (at most 'maximum length'
;            characters plus the CR, so the buffer needs max+1 bytes, as
;            on the BBC); Y = length without the CR; C = 1 on ESCAPE.
;   Uses:    mosPTR2, mosCNT, mosMAX, mosMIN, mosHIGH, inlinein.
;   Limits:  the KERNAL editor's logical line is 80 columns including the
;            prompt; a line filling all 80 wraps onto an empty row.

word0:
    ldy #0
    lda (mosPTR),y
    sta mosPTR2
    iny
    lda (mosPTR),y
    sta mosPTR2+1
    iny
    lda (mosPTR),y
    sta mosMAX
    iny
    lda (mosPTR),y
    sta mosMIN
    iny
    lda (mosPTR),y
    sta mosHIGH
    lda #0
    sta mosCNT
    lda #1
    sta inlinein
    sta MB_STATUS               ; remote: at the prompt
    lda mosPTR2+1
    sta MB_PROMPT               ; remote: prompt (&07) or INPUT (&06)
    cmp #>$0700                 ; the prompt: Upic full shows a changed
    bne w0_noshow               ; picture (a program ended, upic.s)
    lda #0
    farcall upic.up_auto, BANK_UP
w0_noshow:
    jsr w0_waitkey              ; a key, or a remote request handled
    bcc w0_key
    jmp w0_end                  ; remote line is in the buffer
w0_key:
    lda EDMODE                  ; *EDIT BBC (0): the MOS line editor
    bne w0_c64
    jmp le_line
w0_c64:
    lda vtype                   ; *EDIT C64: the KERNAL's screen editor
    beq w0_loop
    jmp w0_bitmap
w0_loop:
    jsr K_CHRIN
    cmp #13
    beq w0_end
    tax
    lda pet2asc,x
    beq w0_loop
    cmp mosMIN
    bcc w0_loop
    cmp mosHIGH
    beq w0_store
    bcs w0_loop
w0_store:
    ldy mosCNT
    cpy mosMAX                  ; full: drop further characters
    bcs w0_loop
    sta (mosPTR2),y
    inc mosCNT
    bne w0_loop
w0_end:
    ldy mosCNT
    lda #13
    sta (mosPTR2),y
    lda #0
    sta inlinein
    lda #2
    sta MB_STATUS               ; remote: running the line
    lda #$0D                    ; echo the newline, as the BBC MOS does
    jsr putpet
    lda MB_CAPTURE              ; and a newline for the host's capture
    beq w0_nocap
    lda #13
    jsr wr_tee
w0_nocap:
    lda ESCFLG
    asl                         ; C = ESCAPE pending
    ldy mosCNT
    rts

; w0_bitmap
;   Summary: OSWORD 0 in bitmap modes: the BBC way, without a screen
;            editor. Characters are stored and echoed, DELETE removes the
;            last one, RETURN ends the line, ESCAPE leaves with C = 1. The
;            cursor (an inverted line) shows while waiting for a key.
;   Input:   as word0, a key waiting.  Output: as word0.
;   Uses:    A, X, Y, mosCNT.
w0_bitmap:
    jsr w0b_cursor
w0b_wait:
    bit ESCFLG
    bmi w0b_esc
    jsr key_avail
    beq w0b_wait
    jsr w0b_cursor              ; hide while the key acts
    jsr key_get
    cmp #13
    beq w0b_end
    cmp #$14                    ; DELETE
    bne w0b_char
    lda mosCNT
    beq w0b_next
    dec mosCNT
    lda #127
    jsr OSWRCH
    jmp w0b_next
w0b_char:
    tax
    lda pet2asc,x
    beq w0b_next
    cmp mosMIN
    bcc w0b_next
    cmp mosHIGH
    beq w0b_store
    bcs w0b_next
w0b_store:
    ldy mosCNT
    cpy mosMAX
    bcs w0b_next
    sta (mosPTR2),y
    inc mosCNT
    jsr OSWRCH
w0b_next:
    jsr w0b_cursor
    jmp w0b_wait
w0b_esc:
    jsr w0b_cursor
w0b_end:
    jmp w0_end

w0b_cursor:
    ldx #GX_CURSOR
    jmp gx_call

; w0_waitkey
;   Summary: wait at the prompt for a key or a remote request.
;   Function: shows the cursor and polls the keyboard buffer and the
;            remote mailbox (docs/REMOTE_DEV.md). A key (or the RETURN
;            that RUN/STOP types) returns C = 0: the screen editor reads
;            the line (with *EDIT BBC also CTRL with a cursor key, the
;            copy cursor). A remote request is handled and acknowledged:
;            REQ_LINE and REQ_PROGRAM put a line in the buffer and return
;            C = 1; REQ_CAPTURE switches output capture and keeps waiting.
;   Input:   mosPTR2/mosMAX/mosMIN/mosHIGH (the OSWORD 0 block).
;   Output:  C = 1: mosCNT characters in the buffer, echoed on screen.
;   Uses:    A, X, Y, mosCNT.
w0_waitkey:
    lda #0                      ; the graphics modes: the engine's cursor,
    sta ed_blk                  ; blinking as in the line editor (from 8
    lda JIFFY                   ; jiffies on; egk_blink, lineed.s)
    clc
    adc #8
    sta ed_bt
    lda #$FF
    sta ed_bph
    lda curson                  ; the text screen: the KERNAL's
    beq wk0_poll
    lda vtype
    bne wk0_poll
    lda #0
    sta BLNSW
wk0_poll:
    jsr egk_blink
    jsr key_avail
    bne wk0_key
    lda EDMODE                  ; the line editor: CTRL+cursor keys (the
    bne wk0_nocopy              ; copy cursor) start a line too, though
    lda SHFLAG                  ; they put nothing in the keyboard buffer
    and #4                      ; (lineed.s, ed_poll)
    beq wk0_nocopy
    lda SFDX
    cmp #2
    beq wk0_key
    cmp #7
    beq wk0_key
wk0_nocopy:
    lda MB_HSEQ
    cmp MB_CSEQ
    beq wk0_poll
    jsr egk_hide                ; (either cursor)
    lda MB_REQ
    cmp #REQ_LINE
    beq wk0_line
    cmp #REQ_PROGRAM
    beq wk0_prog
    cmp #REQ_CAPTURE
    bne wk0_ack                 ; unknown request: acknowledge, ignore
    lda MB_LINE
    cmp MB_CAPTURE
    beq wk0_ack                 ; no change: keep what is in the ring
    sta MB_CAPTURE
    lda #0                      ; switched: start with an empty ring
    sta MB_RINGW
    sta MB_RINGR
wk0_ack:
    lda MB_HSEQ
    sta MB_CSEQ
    jmp w0_waitkey
wk0_key:
    jsr egk_hide
    clc
    rts

; REQ_PROGRAM: the host has written a program to PAGE. Type LOAD (or
; CHAIN) "$REMOTE": BASIC's own LOAD then checks it, sets TOP and clears
; the variables; fs_file answers for $REMOTE without reading a file.
wk0_prog:
    lda #1
    sta MB_PROG
    ldx #0
    lda MB_LINE                 ; 0: LOAD, 1: CHAIN
    beq wk0_pcopy
    ldx #wk0_chain-wk0_load
wk0_pcopy:
    ldy #0
wk0_pchar:
    lda wk0_load,x
    beq wk0_done
    jsr wk0_put
    inx
    bne wk0_pchar

wk0_line:                       ; REQ_LINE: the line in MB_LINE
    ldx #0
wk0_lchar:
    cpx MB_LINELEN
    bcs wk0_done
    cpx #MB_LINEMAX
    bcs wk0_done
    lda MB_LINE,x
    jsr wk0_put
    inx
    bne wk0_lchar
wk0_done:
    lda #2                      ; running, before the host sees the ack
    sta MB_STATUS
    lda MB_HSEQ
    sta MB_CSEQ
    sec
    rts

; wk0_put: store A in the line buffer if it is in range and fits (as the
; screen editor path does), and echo it.
wk0_put:
    cmp mosMIN
    bcc wkp_skip
    cmp mosHIGH
    beq wkp_ok
    bcs wkp_skip
wkp_ok:
    ldy mosCNT
    cpy mosMAX
    bcs wkp_skip
    sta (mosPTR2),y
    inc mosCNT
    cmp #127                    ; echo straight to the screen: not through
    bcs wkp_skip                ; OSWRCH, so the host's output capture
    stx mosTMP+1                ; holds only what BASIC prints
    tax
    lda asc2pet,x
    beq wkp_noecho
    jsr putpet
wkp_noecho:
    ldx mosTMP+1
wkp_skip:
    rts

wk0_load:
    dta 'LOAD "$REMOTE"', 0
wk0_chain:
    dta 'CHAIN "$REMOTE"', 0

; word9 (OSWORD 9)
;   Summary: read a pixel (BASIC's POINT): logical colour, or 255 off the
;            graphics window and in text modes.
;   Input:   block +0/+1 x, +2/+3 y (OS units).  Output: block +4.
;   Uses:    A, X, Y, pk_x, pk_y, gx_res.
word9:
    lda #$FF
    sta gx_res
    lda vtype
    cmp #1                      ; bitmap modes only (not teletext: the
    bne w9_done                 ; teletext engine has no POINT)
    ldy #3
w9_copy:
    lda (mosPTR),y
    sta pk_x,y                  ; pk_x, pk_y are adjacent
    dey
    bpl w9_copy
    ldx #GX_POINT
    jsr gx_call
w9_done:
    lda gx_res
    ldy #4
    sta (mosPTR),y
    rts

; word10 (OSWORD 10)
;   Summary: read a character definition, as on the BBC.
;   Function: the glyph the graphics modes use (REU font) with an REU;
;            without one, codes 0-127 from the text font on the text
;            screen (user-defined characters included), else from the
;            character ROM.
;   Input:   block +0 = character.  Output: block +1..+8 = rows, top first.
;   Uses:    A, X, Y, glyph.
word10:
    ldy #0
    lda (mosPTR),y
    ldx reu_banks
    bne w10_get
    ldx reu_banks+1
    bne w10_get
    ldx vtype
    bne w10_get
    cmp #$80
    bcs w10_get
    jsr glyph_font
    jmp w10_copy
w10_get:
    jsr glyph_get
w10_copy:
    ldy #8
w10_loop:
    lda glyph-1,y
    sta (mosPTR),y
    dey
    bne w10_loop
    rts

; word1 (OSWORD 1)
;   Summary: read TIME, 5 bytes, centiseconds.
;   Input:   block = 5-byte buffer.  Output: buffer.
;   Uses:    A, Y. Interrupts off while copying (irq_main updates TIME).
word1:
    sei
    ldy #4
w1_loop:
    lda mostime,y
    sta (mosPTR),y
    dey
    bpl w1_loop
    cli
    rts

; word2 (OSWORD 2)
;   Summary: set TIME from 5 bytes.
;   Input:   block = 5 bytes.  Output: mostime.
;   Uses:    A, Y. Interrupts off while copying.
word2:
    sei
    ldy #4
w2_loop:
    lda (mosPTR),y
    sta mostime,y
    dey
    bpl w2_loop
    cli
    rts

; ----------------------------------------------------------------------------
; mos_cli (OSCLI)
;   Summary: run a * command.
;   Function: skips leading spaces and '*', looks the command word up in
;            cmd_table (case-insensitive; a '.' abbreviates, e.g. *H.;
;            only the group of its first letter is searched, cmd_index),
;            and calls its handler in its bank through the trampoline,
;            with Y at the first character after the word. "*." is *CAT.
;            Unknown commands raise error 254 "Bad command".
;   Input:   X/Y = address of the CR-terminated command line.
;   Output:  per command.
;   Uses:    mosPTR = command line, mosTMP (word start, handler address).
;            Scanning stops at Y = 255 at the latest.

mos_cli:
    stx mosPTR
    sty mosPTR+1
    ldy #0
cli_skip:
    lda (mosPTR),y
    cmp #' '
    beq cli_next
    cmp #'*'
    bne cli_start
cli_next:
    iny
    bne cli_skip
cli_start:
    cmp #13
    bne cli_dot
    rts
cli_dot:
    cmp #'.'                    ; "*." is *CAT, as on the BBC
    bne cli_match
    iny
    ldx #<cmd_cat
    lda #>cmd_cat
    stx tramp_tgt
    sta tramp_tgt+1
    lda #BANK_FS
    sta tramp_bank
    jmp tramp
cli_match:
    sty mosTMP                  ; start of the command word
    jsr toupper                 ; (mosPTR2): its letter's group (cmd_index;
    sec                         ; the table is over 256 bytes, so no X
    sbc #'A'                    ; index)
    cmp #26
    bcc cli_letter
    jmp cli_bad
cli_letter:
    asl
    tax
    lda cmd_index,x
    sta mosPTR2
    lda cmd_index+1,x
    sta mosPTR2+1
cli_try:
    ldy #0
    lda (mosPTR2),y
    beq cli_bad
    lda mosTMP                  ; mosTMP+1: position in the line
    sta mosTMP+1
    ldx #0                      ; X: position in the name
cli_cmp:
    txa
    tay
    lda (mosPTR2),y
    beq cli_endname
    sta mosTMP+2
    ldy mosTMP+1
    lda (mosPTR),y
    cmp #'.'
    beq cli_abbrev
    jsr toupper
    cmp mosTMP+2
    bne cli_skipname
    inx
    inc mosTMP+1
    bne cli_cmp
cli_endname:
    ldy mosTMP+1                ; the word must end here
    lda (mosPTR),y
    jsr toupper
    cmp #'A'
    bcc cli_found
    cmp #'Z'+1
    bcc cli_skipname
    bcs cli_found
cli_abbrev:
    inc mosTMP+1
cli_toend:
    txa
    tay
cli_toend_y:
    lda (mosPTR2),y
    beq cli_foundy
    iny
    bne cli_toend_y
cli_skipname:
    txa
    tay
cli_skip_y:
    lda (mosPTR2),y
    beq cli_nextcmd
    iny
    bne cli_skip_y
cli_nextcmd:
    tya                         ; next entry: after the 0 and 3 bytes
    sec
    adc #3
    clc
    adc mosPTR2
    sta mosPTR2
    bcc cli_try
    inc mosPTR2+1
    bne cli_try
cli_found:
    txa
    tay
cli_foundy:
    iny                         ; handler address and bank
    lda (mosPTR2),y
    sta tramp_tgt
    iny
    lda (mosPTR2),y
    sta tramp_tgt+1
    iny
    lda (mosPTR2),y
    sta tramp_bank
    ldy mosTMP+1                ; Y = first character after the word
    jmp tramp
cli_bad:
    brk
    dta 254, 'Bad command', 0
cli_badnum:
    brk
    dta 252, 'Bad number', 0

; Command table: upper-case name, 0, handler address, handler bank, in
; groups by first letter (cmd_index), each group ending with 0
; (scanning every entry would take up to 25 ms at 1 MHz for a command
; near the end). Abbreviations match the first entry
; of their letter's group in this order. genhelp.py checks the grouping.
cmd_table:
ct_A:
    dta 'ADVAL', 0, a(acorn.cmd_adval), BANK_TOOLS
    dta 'ACCESS', 0, a(cmd_access), BANK_FS
    dta 'ASCII', 0, a(pet.cmd_ascii), BANK_SND
    dta 0
ct_B:
    dta 'BUILD', 0, a(dfs.cmd_build), BANK_TOOLS
    dta 'BROWSE', 0, a(brw.cmd_browse), BANK_NET
    dta 0
ct_C:
    dta 'CAT', 0, a(cmd_cat), BANK_FS
    dta 'CD', 0, a(cmd_dir), BANK_FS
    dta 'COPY', 0, a(cmd_copy), BANK_FS
    dta 'CP', 0, a(cmd_cp), BANK_FS
    dta 'CDIR', 0, a(cmd_mkdir), BANK_FS
    dta 'CIRCLE', 0, a(bvc.cmd_circle), BANK_UP
    dta 'COLOUR', 0, a(bvc.cmd_colour), BANK_UP
    dta 'CRUNCH', 0, a(tk.cmd_crunch), BANK_TOOLS
    dta 'CONFIG', 0, a(net.cmd_config), BANK_NET
    dta 0
ct_D:
    dta 'DIR', 0, a(cmd_dir), BANK_FS
    dta 'DELETE', 0, a(cmd_delete), BANK_FS
    dta 'DRIVE', 0, a(cmd_drive), BANK_FS
    dta 'DUMP', 0, a(dfs.cmd_dump), BANK_TOOLS
    dta 0
ct_E:
    dta 'EDIT', 0, a(cmd_edit), BANK_MOS
    dta 'ELLIPSE', 0, a(bvc.cmd_ellipse), BANK_UP
    dta 'EXEC', 0, a(dfs.cmd_exec), BANK_TOOLS
    dta 0
ct_F:
    dta 'FONT', 0, a(cmd_font), BANK_FS
    dta 'FX', 0, a(cmd_fx), BANK_MOS
    dta 'FIND', 0, a(tk.cmd_find), BANK_TOOLS
    dta 'FLOOD', 0, a(gxr.cmd_accept), BANK_RD
    dta 0
ct_G:
    dta 'GCOL', 0, a(bvc.cmd_gcol), BANK_UP
    dta 'GXR', 0, a(gxr.cmd_accept), BANK_RD
    dta 0
ct_H:
    dta 'HELP', 0, a(cmd_help), BANK_MOS
    dta 0
ct_I:
    dta 'INSTRUMENT', 0, a(cmd_instrument), BANK_SND
    dta 'INFO', 0, a(dfs.cmd_info), BANK_TOOLS
    dta 0
ct_J:
    dta 'JSON', 0, a(net.cmd_json), BANK_NET
    dta 0
ct_K:
    dta 'KEY', 0, a(cmd_key), BANK_MOS
    dta 0
ct_L:
    dta 'LOAD', 0, a(cmd_load), BANK_FS
    dta 'LIST', 0, a(cmd_list), BANK_FS
    dta 'LINE', 0, a(bvc.cmd_line), BANK_UP
    dta 0
ct_M:
    dta 'MKDIR', 0, a(cmd_mkdir), BANK_FS
    dta 'MOUNT', 0, a(cmd_mount), BANK_FS
    dta 'MEMORY', 0, a(cmd_memory), BANK_FS
    dta 'MAP', 0, a(cmap.cmd_map), BANK_UP
    dta 'MENU', 0, a(net.cmd_menu), BANK_NET
    dta 'MODPLAY', 0, a(aud.cmd_modplay), BANK_AUD
    dta 'MODSTOP', 0, a(aud.cmd_modstop), BANK_AUD
    dta 0
ct_N:
    dta 'NET', 0, a(net.cmd_net), BANK_NET
    dta 'NOFLOOD', 0, a(gxr.cmd_accept), BANK_RD
    dta 'NOGXR', 0, a(gxr.cmd_accept), BANK_RD
    dta 0
ct_O:
    dta 'OFF', 0, a(bvc.cmd_off), BANK_UP
    dta 'ON', 0, a(bvc.cmd_on), BANK_UP
    dta 0
ct_P:
    dta 'PALETTE', 0, a(cmd_palette), BANK_FS
    dta 'PARTITION', 0, a(cmd_partition), BANK_FS
    dta 'PARTITIONS', 0, a(cmd_partitions), BANK_FS
    dta 'PWD', 0, a(cmd_pwd), BANK_FS
    dta 'POINT', 0, a(bvc.cmd_point), BANK_UP
    dta 'PACK', 0, a(tk.cmd_pack), BANK_TOOLS
    dta 'PETSCII', 0, a(pet.cmd_petscii), BANK_SND
    dta 0
ct_Q:
    dta 0
ct_R:
    dta 'RENAME', 0, a(cmd_rename), BANK_FS
    dta 'RECTANGLE', 0, a(bvc.cmd_rectangle), BANK_UP
    dta 'RUN', 0, a(dfs.cmd_run), BANK_TOOLS
    dta 'REPLACE', 0, a(tk.cmd_replace), BANK_TOOLS
    dta 'REBOOT', 0, a(net.cmd_reboot), BANK_NET
    dta 'REU', 0, a(cmd_reu), BANK_SND
    dta 'REULOAD', 0, a(cmd_reuload), BANK_SND
    dta 'REUSAVE', 0, a(cmd_reusave), BANK_SND
    dta 'RANDOMIZE', 0, a(cmd_randomize), BANK_GFX
    dta 'RANDOMISE', 0, a(cmd_randomize), BANK_GFX
    dta 0
ct_S:
    dta 'SAVE', 0, a(cmd_save), BANK_FS
    dta 'SETTIME', 0, a(cmd_settime), BANK_FS
    dta 'SHADOW', 0, a(cmd_shadow), BANK_MOS
    dta 'SNAPSHOT', 0, a(snap.cmd_snapshot), BANK_RD
    dta 'SPRITE', 0, a(spr.cmd_sprite), BANK_RD
    dta 'SCHOOSE', 0, a(gxr.cmd_schoose), BANK_RD
    dta 'SDELETE', 0, a(gxr.cmd_sdelete), BANK_RD
    dta 'SEDIT', 0, a(sed.cmd_sedit), BANK_TOOLS
    dta 'SGET', 0, a(gxr.cmd_sget), BANK_RD
    dta 'SLOAD', 0, a(gxr.cmd_sload), BANK_RD
    dta 'SMASK', 0, a(gxr.cmd_smask), BANK_RD
    dta 'SMERGE', 0, a(gxr.cmd_smerge), BANK_RD
    dta 'SNEW', 0, a(gxr.cmd_snew), BANK_RD
    dta 'SRENUMBER', 0, a(gxr.cmd_srenumber), BANK_RD
    dta 'SSAVE', 0, a(gxr.cmd_ssave), BANK_RD
    dta 'SSPACE', 0, a(gxr.cmd_sspace), BANK_RD
    dta 'SPOOL', 0, a(dfs.cmd_spool), BANK_TOOLS
    dta 'SEARCH', 0, a(tk.cmd_search), BANK_TOOLS
    dta 'SPEECH', 0, a(spch.cmd_speech), BANK_SND
    dta 'SAY', 0, a(spch.cmd_say), BANK_SND
    dta 'SPEAK', 0, a(spch.cmd_speak), BANK_SND
    dta 'SONG', 0, a(cmd_song), BANK_SND
    dta 'SOUND', 0, a(cmd_sound), BANK_SND
    dta 'SRREAD', 0, a(cmd_srread), BANK_FS
    dta 'SRWRITE', 0, a(cmd_srwrite), BANK_FS
    dta 'SID', 0, a(cmd_sid), BANK_FS
    dta 'STATUS', 0, a(cmd_status), BANK_FS
    dta 'SWAP', 0, a(cmd_swap), BANK_FS
    dta 'SYS', 0, a(cmd_status), BANK_FS
    dta 'SEQ', 0, a(pet.cmd_seq), BANK_SND
    dta 'SAVEMEM', 0, a(net.cmd_savemem), BANK_NET
    dta 'SETUP', 0, a(net.cmd_setup), BANK_NET
    dta 'SAMPLE', 0, a(aud.cmd_sample), BANK_AUD
    dta 0
ct_T:
    dta 'TABLE', 0, a(mt5.cmd_tab5), BANK_RD
    dta 'TIME', 0, a(cmd_time), BANK_FS
    dta 'TURBO', 0, a(cmd_turbo), BANK_MOS
    dta 'TYPE', 0, a(cmd_type), BANK_FS
    dta 0
ct_U:
    dta 'UPIC', 0, a(upic.cmd_upic), BANK_UP
    dta 'UNMOUNT', 0, a(cmd_unmount), BANK_FS
    dta 'UVER', 0, a(cmd_uver), BANK_FS
    dta 0
ct_V:
    dta 'VARLIST', 0, a(tk.cmd_varlist), BANK_TOOLS
    dta 0
ct_W:
    dta 0
ct_X:
    dta 'XREF', 0, a(tk.cmd_xref), BANK_TOOLS
    dta 0
ct_Y:
    dta 0
ct_Z:
    dta 0

; cmd_index: the start of each letter's group in cmd_table, A-Z
cmd_index:
    dta a(ct_A), a(ct_B), a(ct_C), a(ct_D), a(ct_E), a(ct_F)
    dta a(ct_G), a(ct_H), a(ct_I), a(ct_J), a(ct_K), a(ct_L)
    dta a(ct_M), a(ct_N), a(ct_O), a(ct_P), a(ct_Q), a(ct_R)
    dta a(ct_S), a(ct_T), a(ct_U), a(ct_V), a(ct_W), a(ct_X)
    dta a(ct_Y), a(ct_Z)

; toupper
;   Summary: ASCII a-z to A-Z.
;   Input:   A.  Output: A (other characters unchanged).  Uses: flags.
toupper:
    cmp #'a'
    bcc tu_done
    cmp #'z'+1
    bcs tu_done
    and #$DF
tu_done:
    rts

; cmd_shadow
;   Summary: *SHADOW [n] (BBC Master): n = 0 or none: the next MODE is a
;            shadow mode (the VIC-II version, HIMEM &8000); n = 1: normal
;            (Upic Lite where possible). As OSBYTE &72.
;   Input:   mosPTR/Y.  Uses: A, X, Y, mosNUM.
cmd_shadow:
    jsr cli_byte
    bcc csh_n
    lda #0
csh_n:
    cmp #2
    bcc csh_set
    jmp cli_badnum
csh_set:
    eor #1
    sta shadow
    rts

; cmd_fx
;   Summary: *FX a[,x[,y]]: call OSBYTE a with X = x, Y = y (default 0).
;   Input:   mosPTR/Y = rest of the command line.
;   Output:  per OSBYTE call. Values above 255 raise "Bad number".
;   Uses:    mosARGS, mosNUM.
cmd_fx:
    jsr cli_byte
    bcc fx_first
    jmp cli_bad
fx_first:
    sta mosARGS
    lda #0
    sta mosARGS+1
    sta mosARGS+2
    jsr cli_byte
    bcs fx_call
    sta mosARGS+1
    jsr cli_byte
    bcs fx_call
    sta mosARGS+2
fx_call:
    lda mosARGS
    ldx mosARGS+1
    ldy mosARGS+2
    jmp OSBYTE

; cli_byte
;   Summary: parse a number of at most 255.
;   Input:   mosPTR/Y.
;   Output:  C = 0, A = value, Y after it; C = 1 if there is no number.
;            Raises "Bad number" if it is above 255.
;   Uses:    mosNUM, X.
cli_byte:
    jsr cli_number
    bcs cb_none
    lda mosNUM+1
    beq cb_ok
    jmp cli_badnum
cb_ok:
    lda mosNUM
    clc
cb_none:
    rts

; cli_number
;   Summary: parse a decimal or &hex number.
;   Function: skips spaces and commas first. Digits beyond 16 bits wrap
;            (callers check the range they need).
;   Input:   mosPTR/Y.
;   Output:  C = 0, mosNUM = value, Y after the number; C = 1 if none.
;   Uses:    A, X, mosNUM.
cli_number:
    lda (mosPTR),y
    cmp #' '
    beq cn_skip
    cmp #','
    bne cn_start
cn_skip:
    iny
    bne cli_number
cn_start:
    lda #0
    sta mosNUM
    sta mosNUM+1
    lda (mosPTR),y
    cmp #'&'
    beq cn_hex
    jsr cn_isdigit
    bcs cn_none
cn_dec:
    lda (mosPTR),y
    jsr cn_isdigit
    bcs cn_done
    pha                         ; mosNUM = mosNUM * 10 + digit
    lda mosNUM
    ldx mosNUM+1
    asl mosNUM
    rol mosNUM+1
    asl mosNUM
    rol mosNUM+1
    clc
    adc mosNUM
    sta mosNUM
    txa
    adc mosNUM+1
    sta mosNUM+1
    asl mosNUM
    rol mosNUM+1
    pla
    clc
    adc mosNUM
    sta mosNUM
    bcc cn_decnext
    inc mosNUM+1
cn_decnext:
    iny
    bne cn_dec
cn_hex:
    iny
    lda (mosPTR),y
    jsr cn_ishex
    bcs cn_none
cn_hexloop:
    lda (mosPTR),y
    jsr cn_ishex
    bcs cn_done
    ldx #4
cn_shift:
    asl mosNUM
    rol mosNUM+1
    dex
    bne cn_shift
    ora mosNUM
    sta mosNUM
    iny
    bne cn_hexloop
cn_done:
    clc
    rts
cn_none:
    sec
    rts

; cn_isdigit
;   Summary: test for a decimal digit.
;   Input:   A = character.
;   Output:  C = 0 and A = 0-9 for '0'-'9'; otherwise C = 1, A unchanged.
cn_isdigit:
    cmp #'0'
    bcc cn_no
    cmp #'9'+1
    bcs cn_no
    and #$0F
    clc
    rts
cn_no:
    sec
    rts

; cn_ishex
;   Summary: test for a hexadecimal digit (either case).
;   Input:   A = character.
;   Output:  C = 0 and A = 0-15; otherwise C = 1.
cn_ishex:
    jsr cn_isdigit
    bcc cn_yes
    jsr toupper
    cmp #'A'
    bcc cn_no
    cmp #'F'+1
    bcs cn_no
    sbc #'A'-11                 ; C=0 here: A - ('A' - 10)
cn_yes:
    clc
    rts

; cmd_turbo
;   Summary: *TURBO [MAX|OFF|<0-15>]: show or set the CPU speed.
;   Function: without argument prints the current speed index; MAX = 15
;            (the device's maximum), OFF = 0 (1 MHz), a number sets that
;            U64 speed index. Badlines stay suppressed at turbo speeds.
;            Needs the U64 turbo registers; raises "No turbo" otherwise.
;   Input:   mosPTR/Y.  Output: text or new speed.  Uses: A, X, Y, mosNUM.
cmd_turbo:
    lda turbo_state
    cmp #2
    beq ct_ok
    brk
    dta 199, 'No turbo registers (Turbo Control setting)', 0
ct_ok:
    jsr cli_skipsp
    cmp #13
    bne ct_arg
    lda U64_TURBO               ; show
    and #$0F
    sta mosNUM
    ldx #0
ct_show:
    lda ct_text,x
    beq ct_num
    jsr OSASCI
    inx
    bne ct_show
ct_num:
    lda mosNUM
    jsr print_dec
    jmp OSNEWL
ct_arg:
    jsr toupper
    cmp #'M'
    beq ct_max
    cmp #'O'
    beq ct_off
    jsr cli_byte
    bcs ct_syntax
    cmp #16
    bcs ct_badnum
    bcc ct_set
ct_max:
    lda #15
    bne ct_set
ct_off:
    lda #0
ct_set:
    ora #$80                    ; no badline stalls
    sta U64_TURBO
    rts
ct_badnum:
    jmp cli_badnum
ct_syntax:
    jmp cli_bad
ct_text:
    dta 'Turbo speed index ', 0

; cli_skipsp
;   Summary: skip spaces in the command line.
;   Input:   mosPTR/Y.  Output: A = next character, Y at it.
cli_skipsp:
    lda (mosPTR),y
    cmp #' '
    bne csp_done
    iny
    bne cli_skipsp
csp_done:
    rts

; print_dec
;   Summary: print A (0-255) in decimal without leading zeros.
;   Input:   A.  Output: text.  Uses: A, X, mosTMP.
print_dec:
    ldx #0                      ; X = 1 once a digit has been printed
    stx mosTMP+1
    ldx #100
    jsr pd_digit
    ldx #10
    jsr pd_digit
    ora #'0'
    jmp OSWRCH
pd_digit:
    stx mosTMP
    ldx #'0'-1
pd_sub:
    inx
    sec
    sbc mosTMP
    bcs pd_sub
    adc mosTMP
    cpx #'0'
    bne pd_print
    ldy mosTMP+1
    beq pd_skip
pd_print:
    pha
    txa
    jsr OSWRCH
    pla
    ldy #1
    sty mosTMP+1
pd_skip:
    rts

; ----------------------------------------------------------------------------
; cmd_help
;   Summary: *HELP [subject]: show a help text from the help banks.
;   Function: copies the subject (upper case, at most 31 characters) to
;            errbuf+1 (free unless an error is being raised); no subject
;            means HELP. Looks for an exact name in the help index (bank
;            BANK_HELP, built by tools/genhelp.py) and shows its text;
;            otherwise lists the names that start with the subject.
;   Input:   mosPTR/Y = command line after HELP.
;   Output:  text.
;   Uses:    A, X, Y, mosPTR, mosNUM, mosARGS, mosCNT, errbuf.

HELP_INDEX  = $8006             ; first index record
HELP_MAXARG = 31

cmd_help:
    jsr cli_skipsp
    ldx #0
hl_copy:
    lda (mosPTR),y
    cmp #13
    beq hl_copied
    cmp #' '
    beq hl_copied
    jsr toupper
    sta errbuf+1,x
    inx
    iny
    cpx #HELP_MAXARG
    bcc hl_copy
hl_copied:
    lda #0
    sta errbuf+1,x
    cpx #0
    bne hl_check
    ldx #4                      ; no subject: HELP
hl_def:
    lda hl_default,x
    sta errbuf+1,x
    dex
    bpl hl_def
hl_check:
    lda #<$8000                 ; help banks present?
    sta mosPTR
    lda #>$8000
    sta mosPTR+1
    ldy #3
hl_magic:
    ldx #BANK_HELP
    jsr bank_peek
    cmp hl_magictext,y
    bne hl_nohelp
    dey
    bpl hl_magic
    jsr hl_find                 ; exact match?
    bcs hl_prefix
    jmp hl_show
hl_prefix:
    jmp hl_list
hl_nohelp:
    brk
    dta 254, 'No help in this cartridge', 0

hl_default:
    dta 'HELP', 0
hl_magictext:
    dta 'UHLP'

; hl_start
;   Summary: point mosPTR at the first index record, mosNUM = count.
hl_start:
    lda #<$8004
    sta mosPTR
    lda #>$8004
    sta mosPTR+1
    ldx #BANK_HELP
    ldy #0
    jsr bank_peek
    sta mosNUM
    iny
    jsr bank_peek
    sta mosNUM+1
    lda #<HELP_INDEX
    sta mosPTR
    lda #>HELP_INDEX
    sta mosPTR+1
    rts

; hl_next
;   Summary: step mosPTR past the current index record, count down.
;   Output:  Z = 1 when no records are left.  Uses: A, X, Y.
hl_next:
    ldx #BANK_HELP
    ldy #0
hn_name:
    jsr bank_peek
    beq hn_end
    iny
    bne hn_name
hn_end:
    tya                         ; skip name, 0, bank, address
    clc
    adc #4
    adc mosPTR
    sta mosPTR
    bcc hn_count
    inc mosPTR+1
hn_count:
    lda mosNUM
    bne hn_dec
    dec mosNUM+1
hn_dec:
    dec mosNUM
    lda mosNUM
    ora mosNUM+1
    rts

; hl_find
;   Summary: find the subject (errbuf+1) in the index.
;   Output:  C = 0: mosPTR at the record, Y at its name's 0 terminator;
;            C = 1: not found.
;   Uses:    A, X, Y, mosNUM.
hl_find:
    jsr hl_start
hf_record:
    lda mosNUM
    ora mosNUM+1
    beq hf_none
    ldx #BANK_HELP
    ldy #0
hf_cmp:
    jsr bank_peek
    cmp errbuf+1,y
    bne hf_skip
    cmp #0
    beq hf_found
    iny
    bne hf_cmp
hf_skip:
    jsr hl_next
    jmp hf_record
hf_found:
    clc
    rts
hf_none:
    sec
    rts

; hl_show
;   Summary: show the text of the index record at mosPTR (Y at the name's
;            terminator), 22 lines per page.
;   Function: lines are shown as they are; a line starting with byte 1
;            is a paragraph (genhelp.py), word-wrapped to the text width
;            less one (39 on the 40-column screen, 79 in 80 columns, the
;            text window's in the bitmap modes). SPACE
;            (any key) shows the next page; ESCAPE stops and is
;            acknowledged. Text bytes are read through bank_peek.
;   Uses:    A, X, Y, mosPTR, mosARGS (bank, line count, width), mosCNT
;            (column), mosTMP (word length, index).
hl_show:
    ldx #BANK_HELP
    iny
    jsr bank_peek
    sta mosARGS                 ; bank of the text
    iny
    jsr bank_peek
    pha
    iny
    jsr bank_peek
    sta mosPTR+1
    pla
    sta mosPTR
    lda #0
    sta mosARGS+1               ; lines on this page
    lda #39                     ; characters a line: the width less one
    ldx vtype
    beq hs_w
    lda twr
    sec
    sbc twl
hs_w:
    sta mosARGS+2
    jsr OSNEWL
hs_loop:
    bit ESCFLG
    bmi hs_stop
    jsr hs_byte
    beq hs_done
    cmp #1
    beq hs_para
    jsr hs_adv
    cmp #13
    beq hs_line
    jsr OSWRCH
    jmp hs_loop
hs_line:
    jsr hs_nl
    bcc hs_loop
hs_stop:
    lda #$7E                    ; acknowledge ESCAPE
    jsr OSBYTE
    jsr OSNEWL
hs_done:
    rts

; a paragraph: word by word, a new line when the next word would not fit
hs_para:
    jsr hs_adv                  ; (the marker)
    lda #0
    sta mosCNT                  ; column
hp_word:
    bit ESCFLG
    bmi hs_stop
    ldy #0                      ; the word's length: up to a space, CR, 0
    ldx mosARGS
hp_len:
    jsr bank_peek
    cmp #' '+1
    bcc hp_got
    iny
    bne hp_len
hp_got:
    sty mosTMP
    lda mosCNT                  ; the line's first word: no space
    beq hp_put
    sec                         ; column + 1 + length fits?
    adc mosTMP
    bcs hp_nl
    cmp mosARGS+2
    beq hp_sp
    bcs hp_nl
hp_sp:
    lda #' '
    jsr OSWRCH
    inc mosCNT
    jmp hp_put
hp_nl:
    jsr hs_nl
    bcs hs_stop
    lda #0
    sta mosCNT
hp_put:
    ldy #0                      ; the word
hp_ch:
    cpy mosTMP
    beq hp_end
    sty mosTMP+1
    ldx mosARGS
    jsr bank_peek
    jsr OSWRCH
    ldy mosTMP+1
    iny
    bne hp_ch
hp_end:
    lda mosTMP                  ; past it; the column on
    clc
    adc mosCNT
    sta mosCNT
    lda mosTMP
    clc
    adc mosPTR
    sta mosPTR
    bcc hp_sep
    inc mosPTR+1
hp_sep:
    jsr hs_byte                 ; a space: the next word; CR: the end
    beq hs_done
    jsr hs_adv
    cmp #' '
    beq hp_word
    jsr hs_nl
    bcs hs_stop
    jmp hs_loop

; hs_byte: A = the text byte at mosPTR (Z = 1: the end)
hs_byte:
    ldx mosARGS
    ldy #0
    jmp bank_peek

; hs_adv: mosPTR on by one (A kept)
hs_adv:
    inc mosPTR
    bne hsa_rts
    inc mosPTR+1
hsa_rts:
    rts

; hs_nl: a new line; after 22 lines wait for a key ("more").
; C = 1 when ESCAPE was pressed.  Uses: A, X.
hs_nl:
    jsr OSNEWL
    inc mosARGS+1
    lda mosARGS+1
    cmp #22
    bcc hsn_ok
    ldx #0                      ; page full: wait
hs_prompt:
    lda hs_more,x
    beq hs_wait
    jsr OSWRCH
    inx
    bne hs_prompt
hs_wait:
    jsr OSRDCH
    bcs hsn_rts
    lda #13                     ; wipe the prompt line
    jsr OSWRCH
    ldx #38
hs_wipe:
    lda #' '
    jsr OSWRCH
    dex
    bpl hs_wipe
    lda #13
    jsr OSWRCH
    lda #0
    sta mosARGS+1
hsn_ok:
    clc
hsn_rts:
    rts

hs_more:
    dta '-- SPACE: more, ESCAPE: stop --', 0

; hl_list
;   Summary: list the index names that start with the subject, in
;            columns of 13; "No help on ..." if there are none.
;   Uses:    A, X, Y, mosPTR, mosNUM, mosCNT (column), mosARGS (found).
hl_list:
    jsr hl_start
    lda #0
    sta mosCNT
    sta mosARGS
hli_record:
    lda mosNUM
    ora mosNUM+1
    beq hli_end
    ldx #BANK_HELP
    ldy #0
hli_cmp:
    lda errbuf+1,y              ; end of the subject: prefix matches
    beq hli_match
    jsr bank_peek
    cmp errbuf+1,y
    bne hli_next
    iny
    bne hli_cmp
hli_match:
    inc mosARGS
    ldy #0
hli_print:
    jsr bank_peek
    beq hli_pad
    jsr OSWRCH
    iny
    bne hli_print
hli_pad:
    lda mosCNT                  ; three columns of 13
    cmp #26
    bcs hli_nl
    clc
    adc #13
    sta mosCNT
hli_sp:
    cpy #13
    bcs hli_next
    lda #' '
    jsr OSWRCH
    iny
    bne hli_sp
hli_nl:
    jsr OSNEWL
    lda #0
    sta mosCNT
hli_next:
    jsr hl_next
    jmp hli_record
hli_end:
    lda mosCNT
    beq hli_nonl
    jsr OSNEWL
hli_nonl:
    lda mosARGS
    bne hli_done
    ldx #0
hli_none:
    lda hl_nonetext,x
    beq hli_subj
    jsr OSWRCH
    inx
    bne hli_none
hli_subj:
    ldx #0
hli_subjloop:
    lda errbuf+1,x
    beq hli_tail
    jsr OSWRCH
    inx
    bne hli_subjloop
hli_tail:
    jsr OSNEWL
hli_done:
    rts

hl_nonetext:
    dta 'No help on ', 0

; ----------------------------------------------------------------------------
; The line editor (OSWORD 0, *EDIT BBC)

    icl 'lineed.s'

; ----------------------------------------------------------------------------
; Function keys (*KEY)

    icl 'keys.s'

; ----------------------------------------------------------------------------
; Character tables (generated by tools/gentables.py)

    icl 'tables.s'

; ----------------------------------------------------------------------------
; Resident MOS: assembled for $C400, stored here, copied at cold start

res_load:
    org RESIDENT, res_load
    icl 'resident.s'
    org res_load + $400

; ----------------------------------------------------------------------------
; VDU core: assembled for $C800, stored here, copied at cold start

core_load:
    org CORE, core_load
    icl 'core.s'
    org core_load + $800

; ----------------------------------------------------------------------------
; Drawing engine: assembled for $D000, stored here, copied at cold start

engine_load:
    org ENGINE, engine_load
    icl 'gfx_vic.s'
    org engine_load + $1000

mos_end:
    .if mos_end > $BF00
    .error "MOS bank 0 overflows into the EasyFlash boot area"
    .endif

; ----------------------------------------------------------------------------
; ef_reset
;   Summary: EasyFlash power-on: get from Ultimax mode to a normal start.
;   Function: the cartridge starts in Ultimax mode with bank 0's ROMH at
;            $E000-$FFFF and no KERNAL. Copy a stub to RAM at $0100
;            (visible in Ultimax mode), switch to 16K mode there and run
;            the KERNAL reset, which finds the CBM80 header at $8004.
;            This code runs at $FFxx in Ultimax mode: addresses are +$4000.
;            Never used by the TwoMegabyter, which starts in 16K mode.
;   Input:   CPU reset.  Output: does not return.

    :[$BF00-*] dta $FF

ef_reset:
    sei
    ldx #$FF
    txs
    cld
    ldx #ef_stub_end-ef_stub-1
ef_copy:
    lda ef_stub+$4000,x
    sta $0100,x
    dex
    bpl ef_copy
    jmp $0100

ef_stub:
    lda #$87                    ; 16K mode, LED on
    sta CART_CTRL
    jmp ($FFFC)                 ; KERNAL reset vector
ef_stub_end:

ef_nmi:
    rti

    :[$BFFA-*] dta $FF
    dta a(ef_nmi+$4000), a(ef_reset+$4000), a(ef_nmi+$4000)
