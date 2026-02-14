; ============================================================================
; CGAFLIP5.ASM - CGA Palette Flip — Split-Screen Proof-of-Concept
; ============================================================================
;
; CONFIRMED RESULT (February 2026, real PC1 hardware):
;
;   Per-scanline palette FLIP via port 0xD9 is PERFECTLY STABLE.
;   6 freely programmable colors + black, zero flicker.
;
;   Palette STREAMING (open 0x40 / write via 0xDE / close 0x80)
;   during the visible area ALWAYS causes visible blinking — even
;   when targeting only INACTIVE entries with unchanged values.
;   The V6355D palette write protocol itself disrupts video output.
;
; HISTORY:
;   This file began as an attempt to fix cgaflip4's flickering by
;   writing only inactive entries (Simone's insight). Multiple
;   variants were tested:
;     - Full 8-entry streaming with active entries changing → flicker
;     - Inactive-entry-only streaming (swapped data layout) → flicker
;     - 2x slowed gradient (same values on adjacent lines) → flicker
;     - Flip-only, NO streaming → PERFECTLY STABLE
;
;   Conclusion: the PALETTE WRITE PROTOCOL itself (open/stream/close)
;   disrupts V6355D output. It is NOT about which entries you write
;   or what values you write — any palette register access during the
;   visible area causes blinking.
;
;   The current code demonstrates the stable flip-only approach with
;   a split-screen test: top half = palette 0, bottom half = palette 1.
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
; THE TECHNIQUE (current version: flip-only, no streaming)
; ============================================================================
;
; DURING HBLANK (~80 cycles):
;   - 1 OUT to 0xD9: set palette (0x00 or 0x20)
;
; NO VISIBLE-AREA PALETTE WRITES.
;   All palette entries are set once during program_palette (VBLANK).
;   The render loop only flips the palette select register.
;
; CURRENT MODE: Split-screen test
;   Top 100 lines: PAL_EVEN (0x00) → entries {0, 2, 4, 6}
;   Bottom 100 lines: PAL_ODD (0x20) → entries {0, 3, 5, 7}
;   This proves the palette select register works per-scanline.
;
; RESULT: 6 colors + black, perfectly stable, zero flicker.
;
; WHAT FAILED (visible-area palette streaming):
;   Opening the palette write protocol (0x40 → 0xDD) and streaming
;   data (LODSB+OUT to 0xDE) during the visible area causes visible
;   blinking — even when writing only inactive entries with their
;   current unchanged values. The V6355D's palette read pipeline is
;   disrupted by the write protocol regardless of data content.
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
; WHAT YOU SHOULD SEE
; ============================================================================
;
; 4 vertical bands across the screen (pixel values 0-3).
; Band 0 = black (background). Bands 1-3 show colors.
;
; TOP HALF (lines 0-99): palette 0 → Red, Green, Blue
; BOTTOM HALF (lines 100-199): palette 1 → Yellow, Cyan, Magenta
;
; All colors perfectly stable — no flickering or blinking.
; This proves per-scanline palette select via 0xD9 is rock solid.
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
; render_frame - Palette flip only (split-screen test)
; ============================================================================
; Top 100 lines: PAL_EVEN (0x00) → entries {0, 2, 4, 6}
; Bottom 100 lines: PAL_ODD (0x20) → entries {0, 3, 5, 7}
;
; NO palette streaming during visible area (proven to cause blinking).
; All palette entries set once in program_palette.
; ============================================================================
render_frame:
    cli

    mov cx, SCREEN_HEIGHT
    mov bl, PAL_EVEN
    mov bh, PAL_ODD

    cmp byte [hsync_enabled], 0
    je .no_hsync_loop

    ; ------------------------------------------------------------------
    ; HSYNC-synced loop — SPLIT-SCREEN TEST
    ; ------------------------------------------------------------------
    ; Top 100 lines: PAL_EVEN (0x00) → E2=Red, E4=Green, E6=Blue
    ; Bottom 100 lines: PAL_ODD (0x20) → E3=Yellow, E5=Cyan, E7=Magenta
    ; If you see different colors top vs bottom, the flip IS working.
    ; ------------------------------------------------------------------

    ; --- Top half: 100 lines with PAL_EVEN ---
    mov cx, 100
.top_half:
.wait_low_t:
    in al, PORT_DA
    test al, 0x01
    jnz .wait_low_t
.wait_high_t:
    in al, PORT_DA
    test al, 0x01
    jz .wait_high_t

    mov al, PAL_EVEN
    out PORT_D9, al
    loop .top_half

    ; --- Bottom half: 100 lines with PAL_ODD ---
    mov cx, 100
.bottom_half:
.wait_low_b:
    in al, PORT_DA
    test al, 0x01
    jnz .wait_low_b
.wait_high_b:
    in al, PORT_DA
    test al, 0x01
    jz .wait_high_b

    mov al, PAL_ODD
    out PORT_D9, al
    loop .bottom_half

    jmp .done_render

    ; ------------------------------------------------------------------
    ; Non-synchronized loop (for testing)
    ; ------------------------------------------------------------------
.no_hsync_loop:
.no_sync_line:
    mov al, bl
    out PORT_D9, al

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
; Initial palette — set once during VBLANK via program_palette
; ============================================================================
; 6 distinct visible colors + black to prove palette flip works.
;
;   Top half (pal 0):  Band 1=Red, Band 2=Green, Band 3=Blue
;   Bottom half (pal 1): Band 1=Yellow, Band 2=Cyan, Band 3=Magenta
;
; CONFIRMED: Split-screen shows all 6 colors, perfectly stable.
palette_init:
    db 0x00, 0x00           ; 0: Black (bg/border)
    db 0x00, 0x00           ; 1: Black (unused)
    db 0x07, 0x00           ; 2: Red       (pal 0, px 1) - top half
    db 0x07, 0x70           ; 3: Yellow    (pal 1, px 1) - bottom half
    db 0x00, 0x70           ; 4: Green     (pal 0, px 2) - top half
    db 0x00, 0x77           ; 5: Cyan      (pal 1, px 2) - bottom half
    db 0x00, 0x07           ; 6: Blue      (pal 0, px 3) - top half
    db 0x07, 0x07           ; 7: Magenta   (pal 1, px 3) - bottom half

; ============================================================================
; END OF PROGRAM
; ============================================================================
;
; NOTE: The RAINBOW_COLOR macro and gradient_data table that were in
; earlier versions of this file have been removed. They supported
; per-scanline palette streaming during the visible area, which was
; proven to cause blinking on V6355D hardware regardless of whether
; active or inactive entries were targeted. The palette write protocol
; (open 0x40 / stream via 0xDE / close 0x80) itself disrupts video
; output.
;
; For per-scanline color changes, the only stable approach on V6355D
; is writing 1 entry during HBLANK (see cgaflip3.asm). Full palette
; changes must be done during VBLANK only.
; ============================================================================
