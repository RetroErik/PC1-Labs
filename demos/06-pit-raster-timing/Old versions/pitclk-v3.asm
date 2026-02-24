; ============================================================================
; PITCLK.asm — CPU Frequency Measurement Tool (v3)
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
; METHOD:
;   Uses PIT channel 0 as reference clock (1,193,182 Hz = 14.31818 / 12).
;   Runs a calibrated NOP+NOP+DEC+JNZ loop (100 iterations) and measures
;   PIT tick delta. The CPU/PIT ratio reveals the DCK divider:
;     Ratio 4.0 → DCK/3 = 4.77 MHz (Normal)
;     Ratio 6.0 → DCK/2 = 7.16 MHz (Turbo)
;     Ratio 6.7 → 8.0 MHz (independent — ruled out)
;
;   Test 4 runs during VBLANK (no bus contention).
;   Test 5 runs during active display (measures bus contention impact).
;
; VERSION HISTORY:
;   v1 — Ran calibration during active display → V6355D bus stealing
;        inflated results (41,492 PIT ticks for 10K iters — ~3× too high)
;   v2 — Moved to VBLANK but used 1000 iterations (4.1 ms) which
;        overflowed VBLANK duration (1.0 ms) → both tests identical
;   v3 — Reduced to 100 iterations (~0.4 ms), fits within VBLANK.
;        Confirmed: DCK/2 in Turbo, DCK/3 in Normal. No bus contention.
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
PORT_MODE       equ 0xD8
PIT_CH0_DATA    equ 0x40
PIT_CMD         equ 0x43

CAL_ITERS       equ 100         ; Loop iterations (fits in VBLANK)

; ============================================================================
; MAIN
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
    ; Wait for VBLANK to end
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
    ; TEST 4: Calibrated loop during VBLANK (KEY TEST — no bus contention)
    ; ================================================================
    ; Loop: NOP(1B) + NOP(1B) + DEC CX(1B) + JNZ(2B) = 5 bytes/iter
    ; At 7.16 MHz with 8-bit bus: ~29 CPU cycles/iter
    ; 100 iters ≈ 2900 cycles ≈ 483 PIT ticks (fits in VBLANK)
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
    ; Wait for VBLANK to END → entering active display
    mov dx, PORT_STATUS
.wait_active:
    in al, dx
    test al, 0x08
    jnz .wait_active
    ; Now in active display — V6355D is fetching VRAM
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
    ; Restore PIT Ch0 to BIOS default
    ; ================================================================
    mov al, 00110110b
    out PIT_CMD, al
    xor al, al
    out PIT_CH0_DATA, al
    out PIT_CH0_DATA, al

    ; ================================================================
    ; DISPLAY RESULTS
    ; ================================================================
    mov ax, 0x0003
    int 0x10

    ; --- Header ---
    mov si, msg_header
    call print_string

    ; --- Frame period ---
    mov si, msg_t1
    call print_string
    mov ax, [result_frame]
    call print_decimal
    mov ax, [result_frame]
    cmp ax, 21000
    jb .hz60
    mov si, msg_pal
    jmp .hz_done
.hz60:
    mov si, msg_ntsc
.hz_done:
    call print_string

    ; --- 100 scanlines ---
    mov si, msg_t2
    call print_string
    mov ax, [result_100scan]
    call print_decimal
    mov si, msg_nl
    call print_string

    ; --- Avg ticks/scanline ---
    mov si, msg_t2avg
    call print_string
    mov ax, [result_100scan]
    xor dx, dx
    mov bx, 100
    div bx
    call print_decimal
    mov si, msg_dot
    call print_string
    mov ax, dx
    mov bx, 100
    mul bx
    mov bx, 100
    div bx
    cmp ax, 10
    jae .f1ok
    push ax
    mov al, '0'
    call print_char
    pop ax
.f1ok:
    call print_decimal
    mov si, msg_nl
    call print_string

    ; --- VBLANK duration ---
    mov si, msg_t3
    call print_string
    mov ax, [result_vblank]
    call print_decimal
    mov si, msg_ticks
    call print_string
    ; Convert to scanlines: vblank_ticks / (100scan_ticks / 100)
    mov si, msg_t3b
    call print_string
    mov ax, [result_vblank]
    mov bx, 100
    mul bx                      ; DX:AX = vblank × 100
    mov bx, [result_100scan]
    or bx, bx
    jz .skip_vblines
    div bx                      ; AX = VBLANK in scanlines
    call print_decimal
    mov si, msg_lines
    call print_string
    jmp .done_vblines
.skip_vblines:
    mov si, msg_err
    call print_string
.done_vblines:

    ; --- KEY TEST ---
    mov si, msg_sep
    call print_string

    mov si, msg_t4
    call print_string
    mov ax, [result_cal_vb]
    call print_decimal
    mov si, msg_ticks
    call print_string

    mov si, msg_t5
    call print_string
    mov ax, [result_cal_act]
    call print_decimal
    mov si, msg_ticks
    call print_string

    ; Bus contention %
    mov si, msg_bus
    call print_string
    mov ax, [result_cal_act]
    mov bx, 100
    mul bx
    mov bx, [result_cal_vb]
    or bx, bx
    jz .skip_bus
    div bx
    call print_decimal
    mov si, msg_pct
    call print_string
    jmp .done_bus
.skip_bus:
    mov si, msg_err
    call print_string
.done_bus:

    ; --- Interpretation ---
    mov si, msg_interp
    call print_string

    ; Show scanlines per frame
    mov si, msg_spf
    call print_string
    mov ax, [result_frame]
    mov bx, 10
    mul bx                      ; DX:AX = frame_ticks × 10
    mov bx, [result_100scan]
    or bx, bx
    jz .skip_spf
    push ax
    push dx
    ; (frame × 10) / (100scan) × (100/10) = frame × 1000 / 100scan
    ; Actually: (frame / (100scan/100)) = (frame × 100) / 100scan
    pop dx
    pop ax
    ; Let me redo: scanlines/frame = frame_ticks / ticks_per_scanline
    ;            = frame × 100 / result_100scan
    mov ax, [result_frame]
    mov bx, 100
    mul bx                      ; DX:AX = frame × 100
    mov bx, [result_100scan]
    div bx                      ; AX = scanlines per frame
    call print_decimal
    mov si, msg_nl
    call print_string
    jmp .done_spf
.skip_spf:
    mov si, msg_err
    call print_string
.done_spf:

    ; Expected values table
    mov si, msg_expected
    call print_string

    ; Best match logic using VBLANK calibration
    ; v2 showed: 4894 PIT for 1000 iters. Per iter = 4.894.
    ; At 7.16 MHz: 4.894 × 6 = 29.4 cycles/iter (correct for 8-bit bus V40)
    ; For 100 iters at same per-iter cost: expect ~489 PIT ticks
    ;
    ; Match ranges (PIT ticks for 100 iters):
    ;   4.77 MHz: ~725 (high)
    ;   7.16 MHz: ~489 (middle)
    ;   8.00 MHz: ~432 (low)
    ;   Midpoints: (725+489)/2=607, (489+432)/2=461

    mov si, msg_match
    call print_string
    mov ax, [result_cal_vb]
    cmp ax, 607
    jae .m477
    cmp ax, 461
    jae .m716
    mov si, msg_r8mhz
    call print_string
    jmp .done_match
.m716:
    mov si, msg_r716
    call print_string
    jmp .done_match
.m477:
    mov si, msg_r477
    call print_string
.done_match:

    ; Estimated cycles/scanline (for info)
    ; cyc/scan = (cal_per_iter_cycles × ticks_per_scanline) / cal_per_iter_PIT
    ; Where cal_per_iter is from VBLANK test.
    ; We don't know cal_per_iter_cycles exactly, but we can show the
    ; two possible values:
    mov si, msg_cps_hdr
    call print_string

    ; If DCK/2 (ratio 6.0): cyc/scan = (ticks/scan) × 6
    mov si, msg_cps2
    call print_string
    mov ax, [result_100scan]
    xor dx, dx
    mov bx, 100
    div bx                      ; AX = ticks/scanline
    mov bx, 6
    mul bx                      ; AX = cycles/scanline at DCK/2
    call print_decimal
    mov si, msg_nl
    call print_string

    ; If DCK/3 (ratio 4.0): cyc/scan = (ticks/scan) × 4
    mov si, msg_cps3
    call print_string
    mov ax, [result_100scan]
    xor dx, dx
    mov bx, 100
    div bx
    mov bx, 4
    mul bx
    call print_decimal
    mov si, msg_nl
    call print_string

    ; Hint
    mov si, msg_hint
    call print_string

    ; Done
    mov si, msg_press
    call print_string
    mov ah, 0x00
    int 0x16
    mov ax, 0x4C00
    int 0x21

; ============================================================================
; SUBROUTINES
; ============================================================================
pit_ch0_freerun:
    mov al, 00110100b
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
    mov al, 00000000b
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

print_string:
    push ax
    push si
.lp:lodsb
    or al, al
    jz .dn
    call print_char
    jmp .lp
.dn:pop si
    pop ax
    ret

print_char:
    push ax
    push bx
    mov ah, 0x0E
    mov bx, 0x0007
    int 0x10
    pop bx
    pop ax
    ret

print_decimal:
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
    call print_char
    loop .pr
    pop dx
    pop cx
    pop bx
    pop ax
    ret

; ============================================================================
; DATA
; ============================================================================
pit_start:      dw 0
pit_end:        dw 0
result_frame:   dw 0
result_100scan: dw 0
result_vblank:  dw 0
result_cal_vb:  dw 0
result_cal_act: dw 0

; ============================================================================
; STRINGS
; ============================================================================
msg_header: db '=== PITCLK v3: CPU Clock Measurement ===', 13, 10
            db 'Olivetti PC1 / V6355D / NEC V40', 13, 10, 13, 10, 0

msg_t1:     db 'Frame period:      ', 0
msg_pal:    db ' ticks (50 Hz PAL)', 13, 10, 0
msg_ntsc:   db ' ticks (60 Hz NTSC)', 13, 10, 0

msg_t2:     db '100 scanlines:     ', 0
msg_t2avg:  db 'Avg ticks/scan:    ', 0

msg_t3:     db 'VBLANK duration:   ', 0
msg_t3b:    db 'VBLANK scanlines:  ', 0
msg_lines:  db ' lines', 13, 10, 0

msg_sep:    db 13, 10, '--- KEY TEST (100-iter loop, VBLANK) ---', 13, 10, 0
msg_t4:     db 'During VBLANK:     ', 0
msg_t5:     db 'During display:    ', 0
msg_bus:    db 'Bus contention:    ', 0
msg_pct:    db '%', 13, 10, 0
msg_err:    db 'ERR', 13, 10, 0

msg_interp: db 13, 10, '--- INTERPRETATION ---', 13, 10, 0
msg_spf:    db 'Scanlines/frame:   ', 0

msg_expected: db 13, 10, 'Expected VBLANK PIT for 100 iters:', 13, 10
              db '  4.77 MHz (DCK/3): ~725 ticks', 13, 10
              db '  7.16 MHz (DCK/2): ~489 ticks', 13, 10
              db '  8.00 MHz (indep): ~432 ticks', 13, 10, 13, 10, 0

msg_match:  db 'Best match: ', 0
msg_r8mhz:  db '~8 MHz (separate oscillator)', 13, 10, 0
msg_r716:   db '~7.16 MHz = DCK/2 = PIXEL CLOCK', 13, 10, 0
msg_r477:   db '~4.77 MHz = DCK/3 (normal mode)', 13, 10, 0

msg_cps_hdr: db 13, 10, 'CPU cycles per scanline:', 13, 10, 0
msg_cps2:   db '  If DCK/2 (7.16 MHz): ', 0
msg_cps3:   db '  If DCK/3 (4.77 MHz): ', 0
msg_cps_ref: db 0

msg_hint:   db 13, 10, 'TIP: Run in BOTH Turbo and Normal mode.', 13, 10
            db 'If Normal/Turbo PIT ratio = 1.50,', 13, 10
            db 'both clocks derive from same crystal.', 13, 10, 0

msg_ticks:  db ' ticks', 13, 10, 0
msg_dot:    db '.', 0
msg_nl:     db 13, 10, 0
msg_press:  db 13, 10, 'Press any key to exit...', 0
