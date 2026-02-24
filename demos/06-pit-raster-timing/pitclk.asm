; ============================================================================
; PITCLK.asm — CPU Frequency Measurement Tool (v4)
; ============================================================================
;
; PURPOSE:
;   Determine if the PC1's CPU clock is derived from the V6355D master clock
;   (14.31818 MHz crystal) via the DCK pin, or from a separate oscillator.
;
; CONFIRMED RESULTS (tested on real Olivetti Prodest PC1, Feb 2026):
;
;   *** CPU clock = V6355D DCK output, NOT an independent oscillator ***
;
;   Normal mode: DCK / 3 = 4.773 MHz  (measured: 905 PIT ticks / 100 iter)
;   Turbo mode:  DCK / 2 = 7.159 MHz  (measured: 513 PIT ticks / 100 iter)
;   CheckIt benchmark also confirmed: "V20, 7.03 MHz" (within margin)
;
;   The "8 MHz" marketing claim is rounded up from 7.159 MHz.
;
;   KEY IMPLICATION: In Turbo mode, CPU clock = pixel clock (7.159 MHz).
;     - 1 CPU cycle = exactly 1 pixel (320-wide modes)
;     - 456 CPU cycles per scanline (exact integer)
;     - Pixel-perfect beam racing IS possible with cycle counting
;
;   BONUS FINDING: No V6355D bus contention on system RAM.
;     VBLANK and active display gave identical loop timings (100%).
;     V6355D bus stealing only affects VRAM (B000h), not system RAM.
;     NOP delay loops are fully deterministic regardless of beam position.
;
;   Frame timing: 50 Hz PAL, 312-313 scanlines/frame, 76 PIT ticks/scanline.
;
;   See PC1-CLOCK-DISCOVERY.md for full analysis and clock tree diagram.
;
; DISPLAY:
;   ANSI colored output, fits on one 80x25 screen.
;   Colors: Cyan=headers, Yellow=labels, White=measurements,
;           Green=derived values, Magenta=best match, Grey=reference.
;
; VERSION HISTORY:
;   v1-v3 — Measurement iterations (see PC1-CLOCK-DISCOVERY.md)
;   v4 — Compact ANSI color display, fits on one screen (25 lines)
;
; CONTROLS:
;   Press any key to exit.
;
; Written for NASM assembler
; Target: Olivetti Prodest PC1 with Yamaha V6355D
; CPU: NEC V40 (80186 compatible)
;
; By Retro Erik - 2026
; ============================================================================

[BITS 16]
[ORG 0x100]

; --- Hardware Ports ---
PORT_STATUS     equ 0x3DA
PIT_CH0_DATA    equ 0x40
PIT_CMD         equ 0x43

CAL_ITERS       equ 100

; --- ANSI shortcuts ---
ESC             equ 1Bh

; ============================================================================
; MAIN — Run all 5 measurements, then display results
; ============================================================================
main:
    ; CGA graphics mode (for HSYNC/VBLANK status bits)
    mov ax, 0x0004
    int 0x10

    ; ================================================================
    ; TEST 1: Frame period (VBLANK to VBLANK)
    ; ================================================================
    call pit_ch0_freerun
    call wait_vblank_edge
    cli
    call latch_pit_ch0
    mov [pit_start], ax
    sti
    call wait_vblank_edge
    cli
    call latch_pit_ch0
    mov [pit_end], ax
    sti
    mov ax, [pit_start]
    sub ax, [pit_end]
    mov [result_frame], ax

    ; ================================================================
    ; TEST 2: PIT ticks per 100 scanlines
    ; ================================================================
    call pit_ch0_freerun
    call wait_vblank_edge
    call wait_hsync_edge
    cli
    call latch_pit_ch0
    mov [pit_start], ax
    mov cx, 100
.hsync_loop:
    call wait_hsync_edge
    dec cx
    jnz .hsync_loop
    call latch_pit_ch0
    mov [pit_end], ax
    sti
    mov ax, [pit_start]
    sub ax, [pit_end]
    mov [result_100scan], ax

    ; ================================================================
    ; TEST 3: VBLANK duration
    ; ================================================================
    call pit_ch0_freerun
    call wait_vblank_edge
    cli
    call latch_pit_ch0
    mov [pit_start], ax
    mov dx, PORT_STATUS
.vb_end:
    in al, dx
    test al, 0x08
    jnz .vb_end
    call latch_pit_ch0
    mov [pit_end], ax
    sti
    mov ax, [pit_start]
    sub ax, [pit_end]
    mov [result_vblank], ax

    ; ================================================================
    ; TEST 4: Calibrated loop during VBLANK (no bus contention)
    ; ================================================================
    call pit_ch0_freerun
    call wait_vblank_edge
    cli
    call latch_pit_ch0
    mov [pit_start], ax
    mov cx, CAL_ITERS
.cal_vblank:
    nop
    nop
    dec cx
    jnz .cal_vblank
    call latch_pit_ch0
    mov [pit_end], ax
    sti
    mov ax, [pit_start]
    sub ax, [pit_end]
    mov [result_cal_vb], ax

    ; ================================================================
    ; TEST 5: Same loop during active display (bus contention test)
    ; ================================================================
    call pit_ch0_freerun
    call wait_vblank_edge
    mov dx, PORT_STATUS
.wait_active:
    in al, dx
    test al, 0x08
    jnz .wait_active
    cli
    call latch_pit_ch0
    mov [pit_start], ax
    mov cx, CAL_ITERS
.cal_active:
    nop
    nop
    dec cx
    jnz .cal_active
    call latch_pit_ch0
    mov [pit_end], ax
    sti
    mov ax, [pit_start]
    sub ax, [pit_end]
    mov [result_cal_act], ax

    ; ================================================================
    ; Pre-compute derived values
    ; ================================================================

    ; Scanlines per frame = frame_ticks * 100 / result_100scan
    mov ax, [result_frame]
    mov bx, 100
    mul bx
    mov bx, [result_100scan]
    or bx, bx
    jz .no_spf
    div bx
.no_spf:
    mov [result_spf], ax

    ; VBLANK in scanlines = vblank_ticks * 100 / result_100scan
    mov ax, [result_vblank]
    mov bx, 100
    mul bx
    mov bx, [result_100scan]
    or bx, bx
    jz .no_vbl
    div bx
.no_vbl:
    mov [result_vb_lines], ax

    ; Bus contention % = (cal_act * 100) / cal_vb
    mov ax, [result_cal_act]
    mov bx, 100
    mul bx
    mov bx, [result_cal_vb]
    or bx, bx
    jz .no_bus
    div bx
.no_bus:
    mov [result_bus_pct], ax

    ; Avg ticks/scanline integer = result_100scan / 100
    mov ax, [result_100scan]
    xor dx, dx
    mov bx, 100
    div bx
    mov [result_tps_int], ax
    ; Fractional part
    mov ax, dx
    mov bx, 100
    mul bx
    mov bx, 100
    div bx
    mov [result_tps_frac], ax

    ; Cycles/scanline if DCK/2: ticks_per_scan * 6
    mov ax, [result_100scan]
    xor dx, dx
    mov bx, 100
    div bx
    mov bx, 6
    mul bx
    mov [result_cps_d2], ax

    ; Cycles/scanline if DCK/3: ticks_per_scan * 4
    mov ax, [result_100scan]
    xor dx, dx
    mov bx, 100
    div bx
    mov bx, 4
    mul bx
    mov [result_cps_d3], ax

    ; ================================================================
    ; Restore PIT Ch0 to BIOS default
    ; ================================================================
    mov al, 00110110b
    out PIT_CMD, al
    xor al, al
    out PIT_CH0_DATA, al
    out PIT_CH0_DATA, al

    ; ================================================================
    ; DISPLAY RESULTS — ANSI colored, compact 25-line layout
    ; ================================================================
    mov ax, 0x0003          ; Text mode 80x25
    int 0x10

    ; === Row 1: Title ===
    mov ah, 09h
    mov dx, s_title
    int 21h

    ; === Row 2: Separator ===
    mov ah, 09h
    mov dx, s_sep1
    int 21h

    ; === Row 3: Credits ===
    mov ah, 09h
    mov dx, s_credits
    int 21h

    ; === Row 4: blank ===
    mov ah, 09h
    mov dx, s_nl
    int 21h

    ; === Row 5: Section header — Timing ===
    mov ah, 09h
    mov dx, s_sec_timing
    int 21h

    ; === Row 6: Frame period ===
    mov ah, 09h
    mov dx, s_lbl_frame
    int 21h
    mov ax, [result_frame]
    call print_dec
    ; PAL or NTSC?
    mov ax, [result_frame]
    cmp ax, 21000
    jb .is_ntsc
    mov dx, s_sfx_pal
    jmp .fr_done
.is_ntsc:
    mov dx, s_sfx_ntsc
.fr_done:
    mov ah, 09h
    int 21h

    ; === Row 7: Scanlines/frame ===
    mov ah, 09h
    mov dx, s_lbl_spf
    int 21h
    mov ax, [result_spf]
    call print_dec
    mov ah, 09h
    mov dx, s_nl
    int 21h

    ; === Row 8: Ticks/scanline ===
    mov ah, 09h
    mov dx, s_lbl_tps
    int 21h
    mov ax, [result_tps_int]
    call print_dec
    mov al, '.'
    call put_char
    mov ax, [result_tps_frac]
    cmp ax, 10
    jae .f1ok
    mov al, '0'
    call put_char
.f1ok:
    call print_dec
    mov ah, 09h
    mov dx, s_nl
    int 21h

    ; === Row 9: VBLANK duration ===
    mov ah, 09h
    mov dx, s_lbl_vblank
    int 21h
    mov ax, [result_vblank]
    call print_dec
    mov ah, 09h
    mov dx, s_sfx_vbtk
    int 21h
    mov ax, [result_vb_lines]
    call print_dec
    mov ah, 09h
    mov dx, s_sfx_vbln
    int 21h

    ; === Row 10: blank ===
    mov ah, 09h
    mov dx, s_nl
    int 21h

    ; === Row 11: Section header — Bus Test ===
    mov ah, 09h
    mov dx, s_sec_bus
    int 21h

    ; === Row 12: VBLANK loop ===
    mov ah, 09h
    mov dx, s_lbl_calvb
    int 21h
    mov ax, [result_cal_vb]
    call print_dec
    mov ah, 09h
    mov dx, s_sfx_ticks
    int 21h

    ; === Row 13: Display loop ===
    mov ah, 09h
    mov dx, s_lbl_calact
    int 21h
    mov ax, [result_cal_act]
    call print_dec
    mov ah, 09h
    mov dx, s_sfx_ticks
    int 21h

    ; === Row 14: Bus contention ===
    mov ah, 09h
    mov dx, s_lbl_bus
    int 21h
    mov ax, [result_bus_pct]
    call print_dec
    mov ah, 09h
    mov dx, s_sfx_bus
    int 21h

    ; === Row 15: blank ===
    mov ah, 09h
    mov dx, s_nl
    int 21h

    ; === Row 16: Section header — Result ===
    mov ah, 09h
    mov dx, s_sec_result
    int 21h

    ; === Row 17: Best match ===
    mov ah, 09h
    mov dx, s_lbl_match
    int 21h
    ; Determine best match
    mov ax, [result_cal_vb]
    cmp ax, 607
    jae .m477
    cmp ax, 461
    jae .m716
    mov dx, s_r8mhz
    jmp .mdone
.m716:
    mov dx, s_r716
    jmp .mdone
.m477:
    mov dx, s_r477
.mdone:
    mov ah, 09h
    int 21h

    ; === Row 18: Cycles/scanline ===
    mov ah, 09h
    mov dx, s_lbl_cps
    int 21h
    mov ax, [result_cps_d2]
    call print_dec
    mov ah, 09h
    mov dx, s_sfx_d2
    int 21h
    mov ax, [result_cps_d3]
    call print_dec
    mov ah, 09h
    mov dx, s_sfx_d3
    int 21h

    ; === Row 19: blank ===
    mov ah, 09h
    mov dx, s_nl
    int 21h

    ; === Row 20: Section header — Reference ===
    mov ah, 09h
    mov dx, s_sec_ref
    int 21h

    ; === Row 21: Expected PIT values ===
    mov ah, 09h
    mov dx, s_ref_pit
    int 21h

    ; === Row 22: CPU/PIT ratios ===
    mov ah, 09h
    mov dx, s_ref_ratio
    int 21h

    ; === Row 23: Tip ===
    mov ah, 09h
    mov dx, s_tip
    int 21h

    ; === Row 24: blank ===
    mov ah, 09h
    mov dx, s_nl
    int 21h

    ; === Row 25: Press any key ===
    mov ah, 09h
    mov dx, s_press
    int 21h

    ; Wait for keypress, exit
    mov ah, 0x00
    int 0x16
    ; Reset colors before exit
    mov ah, 09h
    mov dx, s_reset
    int 21h
    mov ax, 0x4C00
    int 0x21

; ============================================================================
; SUBROUTINES
; ============================================================================
pit_ch0_freerun:
    mov al, 00110100b       ; Ch0, mode 2, lo/hi
    out PIT_CMD, al
    xor al, al
    out PIT_CH0_DATA, al
    out PIT_CH0_DATA, al
    push cx
    mov cx, 200
.s: nop
    loop .s
    pop cx
    ret

latch_pit_ch0:
    push dx
    mov al, 00000000b       ; Latch Ch0
    out PIT_CMD, al
    in al, PIT_CH0_DATA
    mov dl, al
    in al, PIT_CH0_DATA
    mov ah, al
    mov al, dl
    pop dx
    ret

wait_vblank_edge:
    push ax
    push dx
    mov dx, PORT_STATUS
.e: in al, dx
    test al, 0x08
    jnz .e
.s: in al, dx
    test al, 0x08
    jz .s
    pop dx
    pop ax
    ret

wait_hsync_edge:
    push ax
    push dx
    mov dx, PORT_STATUS
.l: in al, dx
    test al, 0x01
    jnz .l
.h: in al, dx
    test al, 0x01
    jz .h
    pop dx
    pop ax
    ret

; Print AX as unsigned decimal via DOS (preserves all regs)
print_dec:
    push ax
    push bx
    push cx
    push dx
    xor cx, cx
    mov bx, 10
.dv:xor dx, dx
    div bx
    push dx
    inc cx
    or ax, ax
    jnz .dv
.pr:pop ax
    add al, '0'
    call put_char
    loop .pr
    pop dx
    pop cx
    pop bx
    pop ax
    ret

; Print single char in AL via DOS
put_char:
    push ax
    push dx
    mov dl, al
    mov ah, 02h
    int 21h
    pop dx
    pop ax
    ret

; ============================================================================
; DATA — measurement results
; ============================================================================
pit_start:       dw 0
pit_end:         dw 0
result_frame:    dw 0
result_100scan:  dw 0
result_vblank:   dw 0
result_cal_vb:   dw 0
result_cal_act:  dw 0
result_spf:      dw 0
result_vb_lines: dw 0
result_bus_pct:  dw 0
result_tps_int:  dw 0
result_tps_frac: dw 0
result_cps_d2:   dw 0
result_cps_d3:   dw 0

; ============================================================================
; DISPLAY STRINGS — ANSI escape sequences
; ============================================================================
; Color key:
;   Bright Cyan  (1;36m)  = title, section separators
;   Bright Yellow(1;33m)  = labels
;   Bright White (1;37m)  = raw measured values
;   Bright Green (1;32m)  = derived/calculated values
;   Bright Magenta(1;35m) = best match highlight
;   Grey         (0;37m)  = reference data, dim info
;   Reset        (0m)

; Row 1: Title
s_title:
    db ESC, '[2J'                           ; Clear screen
    db ESC, '[H'                            ; Home cursor
    db ESC, '[1;36m'                        ; Bright Cyan
    db ' PITCLK v4: CPU Clock Measurement', 13, 10, '$'

; Row 2: Separator
s_sep1:
    db ESC, '[1;33m'                        ; Yellow
    db ' ', 205,205,205,205,205,205,205,205,205,205,205,205,205,205,205
    db     205,205,205,205,205,205,205,205,205,205,205,205,205,205,205
    db     205,205,205,205,205,205,205,205,205,205,205,205,205,205,205
    db     205,205,205,205,205,205,205,205,205,205,205
    db 13, 10, '$'

; Row 3: Credits
s_credits:
    db ESC, '[0;37m'                        ; Grey
    db ' Created by '
    db ESC, '[1;35m', 'Retro '              ; Magenta
    db ESC, '[1;36m', 'Erik'                ; Cyan
    db ESC, '[0;37m', ', 2026'              ; Grey
    db ' ', 196, ' Olivetti PC1 / V6355D / NEC V40'
    db 13, 10, '$'

; Row 5: Section — Timing
s_sec_timing:
    db ESC, '[1;36m'                        ; Bright Cyan
    db ' ', 196,196,196, ' Timing '
    db 196,196,196,196,196,196,196,196,196,196,196,196,196,196,196
    db 196,196,196,196,196,196,196,196,196,196,196,196,196,196,196
    db 196,196,196,196,196,196,196,196,196,196,196,196,196,196,196
    db 196,196,196
    db 13, 10, '$'

; Row 6: Frame period (label)
s_lbl_frame:
    db ESC, '[1;33m'                        ; Yellow
    db '  Frame period:       '
    db ESC, '[1;37m', '$'                   ; White for value

; Row 6 suffix: PAL or NTSC
s_sfx_pal:
    db ESC, '[0;37m'
    db ' ticks '
    db ESC, '[1;33m'
    db '(50 Hz PAL)', 13, 10, '$'
s_sfx_ntsc:
    db ESC, '[0;37m'
    db ' ticks '
    db ESC, '[1;33m'
    db '(60 Hz NTSC)', 13, 10, '$'

; Row 7: Scanlines/frame
s_lbl_spf:
    db ESC, '[1;33m'
    db '  Scanlines/frame:    '
    db ESC, '[1;32m', '$'                   ; Green for derived

; Row 8: Ticks/scanline
s_lbl_tps:
    db ESC, '[1;33m'
    db '  Ticks/scanline:     '
    db ESC, '[1;37m', '$'                   ; White

; Row 9: VBLANK
s_lbl_vblank:
    db ESC, '[1;33m'
    db '  VBLANK duration:    '
    db ESC, '[1;37m', '$'                   ; White

s_sfx_vbtk:
    db ESC, '[0;37m', ' ticks '
    db ESC, '[1;32m', '('
    db '$'

s_sfx_vbln:
    db ESC, '[1;32m', ' lines'
    db ESC, '[1;32m', ')'
    db 13, 10, '$'

; Row 11: Section — Bus Test
s_sec_bus:
    db ESC, '[1;36m'
    db ' ', 196,196,196, ' Bus Test (100-iter NOP loop) '
    db 196,196,196,196,196,196,196,196,196,196,196,196,196,196,196
    db 196,196,196,196,196,196,196,196,196
    db 13, 10, '$'

; Row 12: VBLANK loop
s_lbl_calvb:
    db ESC, '[1;33m'
    db '  VBLANK loop:        '
    db ESC, '[1;37m', '$'

; Row 13: Display loop
s_lbl_calact:
    db ESC, '[1;33m'
    db '  Display loop:       '
    db ESC, '[1;37m', '$'

; Row 14: Bus contention
s_lbl_bus:
    db ESC, '[1;33m'
    db '  Bus contention:     '
    db ESC, '[1;37m', '$'

s_sfx_ticks:
    db ESC, '[0;37m', ' ticks', 13, 10, '$'

s_sfx_bus:
    db ESC, '[0;37m', '%'
    db ESC, '[0;37m', '  (100% = no V6355D bus stealing)'
    db 13, 10, '$'

; Row 16: Section — Result
s_sec_result:
    db ESC, '[1;36m'
    db ' ', 196,196,196, ' Result '
    db 196,196,196,196,196,196,196,196,196,196,196,196,196,196,196
    db 196,196,196,196,196,196,196,196,196,196,196,196,196,196,196
    db 196,196,196,196,196,196,196,196,196,196,196,196,196,196,196
    db 196,196,196
    db 13, 10, '$'

; Row 17: Best match
s_lbl_match:
    db ESC, '[1;33m'
    db '  Best match:         '
    db ESC, '[1;35m', '$'                   ; Magenta for result

s_r716:
    db '~7.16 MHz = DCK/2 = PIXEL CLOCK!'
    db 13, 10, '$'
s_r477:
    db '~4.77 MHz = DCK/3 (normal mode)'
    db 13, 10, '$'
s_r8mhz:
    db '~8 MHz (separate oscillator)'
    db 13, 10, '$'

; Row 18: Cycles/scanline
s_lbl_cps:
    db ESC, '[1;33m'
    db '  Cycles/scanline:    '
    db ESC, '[1;32m', '$'                   ; Green

s_sfx_d2:
    db ESC, '[0;37m', ' (DCK/2)    '
    db ESC, '[1;32m', '$'

s_sfx_d3:
    db ESC, '[0;37m', ' (DCK/3)'
    db 13, 10, '$'

; Row 20: Section — Reference
s_sec_ref:
    db ESC, '[1;36m'
    db ' ', 196,196,196, ' Reference '
    db 196,196,196,196,196,196,196,196,196,196,196,196,196,196,196
    db 196,196,196,196,196,196,196,196,196,196,196,196,196,196,196
    db 196,196,196,196,196,196,196,196,196,196,196,196,196
    db 13, 10, '$'

; Row 21: Expected PIT values
s_ref_pit:
    db ESC, '[0;37m'
    db '  Expected PIT: '
    db ESC, '[1;37m', '~725'
    db ESC, '[0;37m', ' (4.77 DCK/3)  '
    db ESC, '[1;37m', '~489'
    db ESC, '[0;37m', ' (7.16 DCK/2)  '
    db ESC, '[1;37m', '~432'
    db ESC, '[0;37m', ' (8 MHz)'
    db 13, 10, '$'

; Row 22: CPU/PIT ratios
s_ref_ratio:
    db ESC, '[0;37m'
    db '  CPU/PIT ratio: '
    db ESC, '[1;37m', '4.0'
    db ESC, '[0;37m', ' (DCK/3)   '
    db ESC, '[1;37m', '6.0'
    db ESC, '[0;37m', ' (DCK/2)   '
    db ESC, '[1;37m', '6.7'
    db ESC, '[0;37m', ' (8 MHz)'
    db 13, 10, '$'

; Row 23: Tip
s_tip:
    db ESC, '[1;33m', '  TIP: '
    db ESC, '[0;37m'
    db 'Run in BOTH Turbo and Normal. If ratio ~1.5x '
    db 196, ' same crystal!'
    db 13, 10, '$'

; Row 25: Press any key
s_press:
    db ESC, '[1;33m'
    db ' Press any key to exit...'
    db ESC, '[0m', '$'

; Utility strings
s_nl:       db 13, 10, '$'
s_reset:    db ESC, '[0m', '$'
