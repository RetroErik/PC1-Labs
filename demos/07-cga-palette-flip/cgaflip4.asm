; ============================================================================
; CGAFLIP4.ASM - CGA Palette Flip + Visible-Area Palette Reprogramming
; ============================================================================
;
; EXPERIMENT: Reprogram ALL palette entries during the visible scanline
; area, not during HBLANK. Tests whether writing to ACTIVE entries while
; the beam is drawing causes glitches on the V6355D.
;
; Key insight from Simone: While palette 0 is being drawn (even line),
; entries {1, 3, 5, 7} are NOT being read by the video hardware.
; We can safely reprogram them during the visible area (~424 cycles),
; then flip to palette 1 at the next HBLANK (1 fast OUT). Vice versa
; on odd lines.
;
; THIS FILE ALSO writes the ACTIVE entries (the experiment part).
; If active-entry writes cause glitches, we'll need a version that
; only writes inactive entries.
;
; Written for NASM assembler
; Target: Olivetti Prodest PC1 with Yamaha V6355D video controller
; CPU: NEC V40 (80186 compatible) @ 8 MHz
;
; By Retro Erik - 2026
;
; ============================================================================
; LESSONS APPLIED FROM CGAFLIP3
; ============================================================================
;
; 1. 0xD9 bits 3-0 control BOTH pixel-value-0 AND border (same bits).
;    Both PAL_EVEN and PAL_ODD must use entry 0 as bg/border = black.
;    PAL_EVEN = 0x00, PAL_ODD = 0x20 (NOT 0x21!).
;
; 2. Entry 1 is unused (no pixel value maps to it when bg=entry 0).
;    We stream zeros through it to reach entry 2.
;
; 3. V6355D palette writes stream sequentially from entry 0.
;    To write entry N, must write all entries 0 through N-1 first.
;
; ============================================================================
; THE TECHNIQUE
; ============================================================================
;
; DURING HBLANK (~80 cycles):
;   - 1 OUT to 0xD9: flip palette (0x00 or 0x20)
;
; DURING VISIBLE AREA (~424 cycles):
;   - Open palette (0x40 to 0xDD)
;   - Stream-write all 8 entries (16 × LODSB+OUT to 0xDE)
;   - Close palette (0x80 to 0xDD)
;
;   Cost: 1 (flip) + 2 (open/close) + 16 (LODSB+OUT) = 19 instructions
;   Timing: ~160 cycles (well within 424 visible-area budget)
;
; WHAT COULD GO WRONG:
;   - Writing ACTIVE entries during visible area might cause brief
;     color glitches (V6355D palette pipeline).
;   - If so: only inactive entries should change per line.
;
; ============================================================================
; CGA PALETTE MAPPING (with bg = entry 0)
; ============================================================================
;
;   Pixel  │ Even (pal 0)  │ Odd (pal 1)
;   ───────┼───────────────┼──────────────
;     0    │ entry 0 (bg)  │ entry 0 (bg)    ← both black (border too)
;     1    │ entry 2       │ entry 3
;     2    │ entry 4       │ entry 5
;     3    │ entry 6       │ entry 7
;          │ (entry 1 unused — streamed through)
;
; ============================================================================
; WHAT YOU SHOULD SEE (if it works!)
; ============================================================================
;
; 4 vertical bands. Band 0 = solid black. Bands 1-3 each show a
; smooth rainbow gradient flowing down the screen, with each band
; at a different phase offset (different part of the spectrum).
;
; EVERY scanline should show gradient colors (not just every other).
; If active-entry writes cause glitches, you'll see horizontal
; noise/flicker — that tells us we need to write only inactive entries.
;
; ============================================================================
; CONTROLS
; ============================================================================
;
;   ESC : Exit to DOS
;   H   : Toggle HSYNC sync
;   V   : Toggle VSYNC sync
;
; ============================================================================

[BITS 16]
[ORG 0x100]

; ============================================================================
; Port Definitions — short aliases
; ============================================================================

PORT_D9         equ 0xD9
PORT_DA         equ 0xDA
PORT_DD         equ 0xDD
PORT_DE         equ 0xDE

; ============================================================================
; Constants
; ============================================================================

VIDEO_SEG       equ 0xB800
SCREEN_HEIGHT   equ 200
BYTES_PER_ROW   equ 80

; Both palettes use entry 0 for bg/border = black (no border flicker!)
PAL_EVEN        equ 0x00   ; palette 0, bg/border = entry 0
PAL_ODD         equ 0x20   ; palette 1, bg/border = entry 0

; ============================================================================
; MAIN PROGRAM
; ============================================================================
main:
    mov byte [hsync_enabled], 1
    mov byte [vsync_enabled], 1

    mov ax, 0x0004          ; CGA 320x200x4 mode
    int 0x10

    call program_palette    ; Set initial palette
    call fill_screen_bands  ; 4 vertical bands (pixel values 0-3)

.main_loop:
    call wait_vblank
    call render_frame
    call check_keyboard
    cmp al, 0xFF
    jne .main_loop

    ; Exit: restore text mode
    mov ax, 0x0003
    int 0x10
    mov ax, 0x4C00
    int 0x21

; ============================================================================
; program_palette - Write initial 8 entries
; ============================================================================
program_palette:
    cli
    mov al, 0x40
    out PORT_DD, al
    jmp short $+2

    mov si, palette_init
    mov cx, 16
.pal_loop:
    lodsb
    out PORT_DE, al
    jmp short $+2
    loop .pal_loop

    mov al, 0x80
    out PORT_DD, al
    sti
    ret

; ============================================================================
; fill_screen_bands - 4 vertical bands (pixel values 0, 1, 2, 3)
; ============================================================================
fill_screen_bands:
    push es
    mov ax, VIDEO_SEG
    mov es, ax
    xor bx, bx

.fill_bank:
    mov cx, 100
    xor di, di
    add di, bx

.fill_row:
    push cx
    push di

    mov cx, 10
    xor ax, ax
    cld
    rep stosw               ; Band 0: pixel value 0

    mov cx, 10
    mov ax, 0x5555
    rep stosw               ; Band 1: pixel value 1

    mov cx, 10
    mov ax, 0xAAAA
    rep stosw               ; Band 2: pixel value 2

    mov cx, 10
    mov ax, 0xFFFF
    rep stosw               ; Band 3: pixel value 3

    pop di
    add di, BYTES_PER_ROW
    pop cx
    loop .fill_row

    cmp bx, 0x2000
    jae .fill_done
    mov bx, 0x2000
    jmp .fill_bank

.fill_done:
    pop es
    ret

; ============================================================================
; render_frame - Palette flip + full visible-area palette stream
; ============================================================================
; Per scanline:
;   HBLANK:  1 OUT (palette flip via 0xD9)
;   VISIBLE: 19 instructions (open + 16 LODSB/OUT + close)
;
; All 8 entries streamed from gradient_data table (16 bytes/line).
; Entries 0,1 = always black. Entries 2-7 = rainbow gradient.
; ============================================================================
render_frame:
    cli

    mov si, gradient_data
    mov cx, SCREEN_HEIGHT
    mov bl, PAL_EVEN
    mov bh, PAL_ODD

    cmp byte [hsync_enabled], 0
    je .no_hsync_loop

    ; ------------------------------------------------------------------
    ; HSYNC-synced loop
    ; ------------------------------------------------------------------
.scanline:
.wait_low:
    in al, PORT_DA
    test al, 0x01
    jnz .wait_low

.wait_high:
    in al, PORT_DA
    test al, 0x01
    jz .wait_high

    ; === HBLANK: just flip palette (1 OUT) ===
    mov al, bl
    out PORT_D9, al

    ; === VISIBLE AREA: stream all 8 entries (16 bytes) ===
    mov al, 0x40
    out PORT_DD, al         ; Open palette at entry 0

    ; Entries 0-7: all from gradient_data table
    lodsb
    out PORT_DE, al         ; Entry 0 R
    lodsb
    out PORT_DE, al         ; Entry 0 G|B
    lodsb
    out PORT_DE, al         ; Entry 1 R
    lodsb
    out PORT_DE, al         ; Entry 1 G|B
    lodsb
    out PORT_DE, al         ; Entry 2 R
    lodsb
    out PORT_DE, al         ; Entry 2 G|B
    lodsb
    out PORT_DE, al         ; Entry 3 R
    lodsb
    out PORT_DE, al         ; Entry 3 G|B
    lodsb
    out PORT_DE, al         ; Entry 4 R
    lodsb
    out PORT_DE, al         ; Entry 4 G|B
    lodsb
    out PORT_DE, al         ; Entry 5 R
    lodsb
    out PORT_DE, al         ; Entry 5 G|B
    lodsb
    out PORT_DE, al         ; Entry 6 R
    lodsb
    out PORT_DE, al         ; Entry 6 G|B
    lodsb
    out PORT_DE, al         ; Entry 7 R
    lodsb
    out PORT_DE, al         ; Entry 7 G|B

    mov al, 0x80
    out PORT_DD, al         ; Close palette

    ; Swap for next line
    xchg bl, bh

    loop .scanline
    jmp .done_render

    ; ------------------------------------------------------------------
    ; Non-synchronized loop (for testing)
    ; ------------------------------------------------------------------
.no_hsync_loop:
.no_sync_line:
    mov al, bl
    out PORT_D9, al

    mov al, 0x40
    out PORT_DD, al
    %rep 16
    lodsb
    out PORT_DE, al
    %endrep
    mov al, 0x80
    out PORT_DD, al

    xchg bl, bh
    loop .no_sync_line

.done_render:
    ; Reset to palette 0, clean palette
    mov al, PAL_EVEN
    out PORT_D9, al

    sti
    ret

; ============================================================================
; wait_vblank
; ============================================================================
wait_vblank:
    cmp byte [vsync_enabled], 0
    je .skip
.wait_end:
    in al, PORT_DA
    test al, 0x08
    jnz .wait_end
.wait_start:
    in al, PORT_DA
    test al, 0x08
    jz .wait_start
.skip:
    ret

; ============================================================================
; check_keyboard
; ============================================================================
check_keyboard:
    mov ah, 0x01
    int 0x16
    jz .no_key
    mov ah, 0x00
    int 0x16
    cmp ah, 0x01
    jne .not_esc
    mov al, 0xFF
    ret
.not_esc:
    cmp al, 'h'
    je .toggle_h
    cmp al, 'H'
    jne .not_h
.toggle_h:
    xor byte [hsync_enabled], 1
    jmp .no_key
.not_h:
    cmp al, 'v'
    je .toggle_v
    cmp al, 'V'
    jne .no_key
.toggle_v:
    xor byte [vsync_enabled], 1
.no_key:
    xor al, al
    ret

; ============================================================================
; DATA
; ============================================================================

hsync_enabled:  db 1
vsync_enabled:  db 1

; ============================================================================
; Initial palette
; ============================================================================
palette_init:
    db 0x00, 0x00           ; 0: Black (bg/border)
    db 0x00, 0x00           ; 1: Black (unused)
    db 0x07, 0x00           ; 2: Red   (pal 0, px 1)
    db 0x07, 0x00           ; 3: Red   (pal 1, px 1)
    db 0x00, 0x70           ; 4: Green (pal 0, px 2)
    db 0x00, 0x70           ; 5: Green (pal 1, px 2)
    db 0x07, 0x70           ; 6: Yellow (pal 0, px 3)
    db 0x07, 0x70           ; 7: Yellow (pal 1, px 3)

; ============================================================================
; Gradient data — 200 lines × 16 bytes per line = 3200 bytes
; ============================================================================
; Each line: all 8 palette entries (2 bytes each = 16 bytes).
;
; Layout per line:
;   [0] entry 0 R, [1] entry 0 G|B  — always 0,0 (black bg/border)
;   [2] entry 1 R, [3] entry 1 G|B  — always 0,0 (unused)
;   [4] entry 2 R, [5] entry 2 G|B  — band 1 even (gradient)
;   [6] entry 3 R, [7] entry 3 G|B  — band 1 odd  (gradient +1)
;   [8] entry 4 R, [9] entry 4 G|B  — band 2 even (gradient +67)
;   [10] entry 5 R,[11] entry 5 G|B — band 2 odd  (gradient +68)
;   [12] entry 6 R,[13] entry 6 G|B — band 3 even (gradient +133)
;   [14] entry 7 R,[15] entry 7 G|B — band 3 odd  (gradient +134)
;
; Rainbow: 150-step cycle (R→Y→G→C→B→M→R), repeating.
; Phase offsets per band give each band a different part of the spectrum.
; Even/odd entries offset by 1 step for smooth per-line flow.

; --- Rainbow color macro: step 0-149, repeating ---
%macro RAINBOW_COLOR 1
    %assign %%step (%1 %% 150)
    %if %%step < 25
        ; Red → Yellow: R=7, G: 0→7
        %assign %%g ((%%step * 7 + 12) / 24)
        db 7, (%%g << 4)
    %elif %%step < 50
        ; Yellow → Green: R: 7→0, G=7
        %assign %%r (7 - ((%%step - 25) * 7 + 12) / 24)
        db %%r, 0x70
    %elif %%step < 75
        ; Green → Cyan: G=7, B: 0→7
        %assign %%b ((%%step - 50) * 7 + 12) / 24
        db 0, (0x70 | %%b)
    %elif %%step < 100
        ; Cyan → Blue: G: 7→0, B=7
        %assign %%g (7 - ((%%step - 75) * 7 + 12) / 24)
        db 0, ((%%g << 4) | 7)
    %elif %%step < 125
        ; Blue → Magenta: R: 0→7, B=7
        %assign %%r ((%%step - 100) * 7 + 12) / 24
        db %%r, 0x07
    %elif %%step < 150
        ; Magenta → Red: B: 7→0, R=7
        %assign %%b (7 - ((%%step - 125) * 7 + 12) / 24)
        db 7, %%b
    %endif
%endmacro

gradient_data:
%assign i 0
%rep 200
    db 0, 0                         ; Entry 0: black (bg/border)
    db 0, 0                         ; Entry 1: black (unused)
    RAINBOW_COLOR i                 ; Entry 2: band 1 even
    RAINBOW_COLOR (i + 1)           ; Entry 3: band 1 odd (+1 for smooth flow)
    RAINBOW_COLOR (i + 67)          ; Entry 4: band 2 even
    RAINBOW_COLOR (i + 68)          ; Entry 5: band 2 odd
    RAINBOW_COLOR (i + 133)         ; Entry 6: band 3 even
    RAINBOW_COLOR (i + 134)         ; Entry 7: band 3 odd
    %assign i (i + 1)
%endrep

; ============================================================================
; END OF PROGRAM
; ============================================================================
