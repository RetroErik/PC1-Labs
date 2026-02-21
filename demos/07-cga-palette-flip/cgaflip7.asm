; ============================================================================
; CGAFLIP7.ASM — Three-Column Independent Gradients via E2 VRAM Rotation
; ============================================================================
;
; Part 6 of 8 — Three independent gradient columns via VRAM rotation + deferred open/close.
;   Next: cgaflip8 adds E3 for dual-entry gradient (smoother blending).
;
; TECHNIQUE: Per-scanline E2 update + CGA palette flip + VRAM rotation
;
;   Only palette entry 2 is updated per scanline. Deferred open/close:
;   the write session is opened on odd lines and consumed by OUTSB on
;   even lines (flip + OUTSB×2 = 3 OUTs, ~29 cycles in ~80-cycle HBLANK).
;
;   The VRAM pixel pattern rotates every 2 rows so that a different
;   column has pixel value 1 (which maps to E2) on each even line:
;
;     Row 0 (even): Col1=pix1(E2) Col2=pix2(E4) Col3=pix3(E6)
;     Row 1 (odd):  Col1=pix1(E3) Col2=pix2(E5) Col3=pix3(E7)
;     Row 2 (even): Col1=pix3(E6) Col2=pix2(E4) Col3=pix1(E2)  ← col3
;     Row 3 (odd):  Col1=pix3(E7) Col2=pix2(E5) Col3=pix1(E3)
;     Row 4 (even): Col1=pix2(E4) Col2=pix1(E2) Col3=pix3(E6)  ← col2
;     Row 5 (odd):  Col1=pix2(E5) Col2=pix1(E3) Col3=pix3(E7)
;
;   E2 is loaded with a DIFFERENT gradient per column:
;     Lines 0,6,12,...: E2 = Column 1 gradient (Sunset / Red)
;     Lines 2,8,14,...: E2 = Column 3 gradient (Cubehelix / Blue)
;     Lines 4,10,16,...: E2 = Column 2 gradient (Rainbow / Green)
;
;   Result: 3 independent color gradients, ~33 steps each, all from
;   a 4-color CGA mode. Zero flicker. Zero palette streaming artifacts.
;
; UNIQUE COLORS ON SCREEN (from a 4-color CGA mode!):
;
;   Mode 0 (Sunset/Rainbow/Cubehelix):
;     Black preset: 80 unique colors   (E0 bg + 79 E2 gradient values)
;     Auto preset:  85 unique colors   (+ 5 static E3-E7 tones)
;
;   Mode 1 (Pure Red/Green/Blue):
;     Black preset: 53 unique colors
;     Auto preset:  58 unique colors
;
; PALETTE MAP (CGA mode 4, bg = entry 0):
;
;     Pixel  │  Palette 0 (even)  │  Palette 1 (odd)
;     ───────┼────────────────────┼───────────────────
;       0    │  E0 (background)   │  E0 (background)
;       1    │  E2 (gradient!)    │  E3 (static)
;       2    │  E4 (static)       │  E5 (static)
;       3    │  E6 (static)       │  E7 (static)
;
; CONTROLS:
;
;   ESC   : Exit to DOS
;   SPACE : Cycle static preset (Black → Dark → Gray → Auto → ...)
;   ENTER : Toggle RGB mode (Pure Red / Green / Blue columns)
;   H     : Toggle HSYNC sync
;   V     : Toggle VSYNC sync
;
; Written for NASM assembler
; Target: Olivetti Prodest PC1 with Yamaha V6355D
; CPU: NEC V40 (80186 compatible) @ 8 MHz
;
; By Retro Erik - 2026
;
; ============================================================================

[BITS 16]
[ORG 0x100]

; ============================================================================
; Port Definitions
; ============================================================================

PORT_D9         equ 0xD9        ; CGA Color Select Register
PORT_DA         equ 0xDA        ; CGA Status Register
PORT_DD         equ 0xDD        ; V6355D Palette Address Register
PORT_DE         equ 0xDE        ; V6355D Palette Data Register

; ============================================================================
; Constants
; ============================================================================

VIDEO_SEG       equ 0xB800
SCREEN_HEIGHT   equ 200
BYTES_PER_ROW   equ 80

PAL_EVEN        equ 0x00       ; palette 0, bg/border = entry 0
PAL_ODD         equ 0x20       ; palette 1, bg/border = entry 0

OPEN_ENTRY2     equ 0x44       ; open palette write at entry 2 — VERIFIED
CLOSE_PAL       equ 0x80       ; close palette write

NUM_STEPS       equ 34         ; gradient steps per column
NUM_GRAD_ENTRIES equ 100       ; 200 lines / 2 (even lines only)
NUM_PRESETS     equ 4          ; static presets per mode

; ============================================================================
; MAIN PROGRAM
; ============================================================================

main:
    ; Initialize state
    mov byte [current_mode], 0
    mov byte [static_sub], 0
    mov byte [hsync_enabled], 1
    mov byte [vsync_enabled], 1

    ; Set CGA mode 4 (320×200×4)
    mov ax, 0x0004
    int 0x10

    ; Setup default mode (Sunset / Rainbow / Cubehelix, black static)
    call set_mode0_ptrs
    call set_static_ptr
    call fill_screen
    call build_gradient_buffer
    call wait_vblank
    call program_palette

.main_loop:
    call wait_vblank
    call render_frame
    call check_keyboard

    cmp al, 0xFF            ; ESC → exit
    je .exit
    cmp al, 1               ; Space → cycle static
    je .handle_space
    cmp al, 2               ; Enter → toggle mode
    je .handle_enter
    jmp .main_loop

; --- Space: cycle static preset ---
.handle_space:
    inc byte [static_sub]
    cmp byte [static_sub], NUM_PRESETS
    jb .space_apply
    mov byte [static_sub], 0
.space_apply:
    call set_static_ptr
    call wait_vblank
    call program_palette
    jmp .main_loop

; --- Enter: toggle gradient mode ---
.handle_enter:
    xor byte [current_mode], 1
    cmp byte [current_mode], 0
    je .enter_mode0
    ; Switched to mode 1 (RGB)
    call set_mode1_ptrs
    mov byte [static_sub], 0     ; force black static
    jmp short .enter_apply
.enter_mode0:
    call set_mode0_ptrs
.enter_apply:
    call set_static_ptr
    call build_gradient_buffer
    call wait_vblank
    call program_palette
    jmp .main_loop

; --- Exit ---
.exit:
    mov ax, 0x0003
    int 0x10
    mov ax, 0x4C00
    int 0x21

; ============================================================================
; set_mode0_ptrs / set_mode1_ptrs — Set gradient table pointers
; ============================================================================

set_mode0_ptrs:
    mov word [col1_ptr], grad_sunset
    mov word [col2_ptr], grad_rainbow
    mov word [col3_ptr], grad_cubehelix
    ret

set_mode1_ptrs:
    mov word [col1_ptr], grad_red
    mov word [col2_ptr], grad_green
    mov word [col3_ptr], grad_blue
    ret

; ============================================================================
; set_static_ptr — Look up static preset from mode + submode
; ============================================================================

set_static_ptr:
    mov al, [static_sub]
    xor ah, ah
    shl ax, 1                   ; word offset
    mov bx, ax
    cmp byte [current_mode], 0
    jne .m1_table
    add bx, m0_presets
    jmp short .load_ptr
.m1_table:
    add bx, m1_presets
.load_ptr:
    mov bx, [bx]               ; dereference pointer table
    mov [static_ptr], bx
    ret

; ============================================================================
; build_gradient_buffer — Precompute 100 entries × 2 bytes (even lines only)
; ============================================================================
; Entry N maps to:
;   column = [col1, col3, col2][N % 3]
;   step   = N / 3
;
; Mapping:  N%3=0 → col1 (sunset/red)    = even lines 0,6,12,...
;           N%3=1 → col3 (cubehelix/blue) = even lines 2,8,14,...
;           N%3=2 → col2 (rainbow/green)  = even lines 4,10,16,...
;
; Each entry: [R_byte, GB_byte] for E2 update via OUTSB
; ============================================================================

build_gradient_buffer:
    cld
    mov di, gradient_buffer
    xor cx, cx                  ; entry counter 0..99

.entry_loop:
    mov ax, cx
    mov bl, 3
    div bl                      ; AL = step (0-33), AH = col_idx (0/1/2)

    ; Save column index
    mov dl, ah

    ; Clamp step to max
    cmp al, NUM_STEPS - 1
    jbe .step_ok
    mov al, NUM_STEPS - 1
.step_ok:
    xor ah, ah
    shl ax, 1                  ; AX = step × 2 (byte offset into table)
    mov bx, ax

    ; Pick gradient table: 0→col1, 1→col3, 2→col2
    cmp dl, 0
    je .use_col1
    cmp dl, 1
    je .use_col3
    ; dl == 2: col2
    add bx, [col2_ptr]
    jmp short .copy_entry
.use_col1:
    add bx, [col1_ptr]
    jmp short .copy_entry
.use_col3:
    add bx, [col3_ptr]

.copy_entry:
    mov ax, [bx]               ; AL = R, AH = GB
    stosw                       ; write to buffer, DI += 2

    inc cx
    cmp cx, NUM_GRAD_ENTRIES
    jb .entry_loop
    ret

; ============================================================================
; program_palette — Set entries E2-E7 during VBLANK
; ============================================================================
; Opens at 0x44 (entry 2), writes 12 bytes:
;   E2 = first gradient color for col1
;   E3-E7 = static preset values
; Uses jmp $+2 as I/O delay (init path, not time-critical)
; ============================================================================

program_palette:
    cli

    ; E2: initial value = first gradient step for col1
    mov bx, [col1_ptr]

    mov al, OPEN_ENTRY2
    out PORT_DD, al
    jmp short $+2

    mov al, [bx]                ; E2 R
    out PORT_DE, al
    jmp short $+2
    mov al, [bx+1]              ; E2 GB
    out PORT_DE, al
    jmp short $+2

    ; E3-E7: from static preset (5 entries × 2 bytes = 10 bytes)
    mov bx, [static_ptr]
    mov cx, 5
.write_static:
    mov al, [bx]
    out PORT_DE, al
    jmp short $+2
    mov al, [bx+1]
    out PORT_DE, al
    jmp short $+2
    add bx, 2
    loop .write_static

    mov al, CLOSE_PAL
    out PORT_DD, al

    sti
    ret

; ============================================================================
; fill_screen — VRAM with 3-column rotating pixel pattern
; ============================================================================
; 6-line cycle using 3 patterns (repeats every 3 VRAM rows per bank):
;   A: col1=pix1(0x55), col2=pix2(0xAA), col3=pix3(0xFF)
;   B: col1=pix3(0xFF), col2=pix2(0xAA), col3=pix1(0x55)
;   C: col1=pix2(0xAA), col2=pix1(0x55), col3=pix3(0xFF)
;
; Column widths: 108 + 104 + 108 = 320 pixels (27+26+27 = 80 bytes)
; ============================================================================

fill_screen:
    push es
    mov ax, VIDEO_SEG
    mov es, ax
    cld

    ; Bank 0 (even screen rows: 0, 2, 4, ...)
    xor di, di
    mov cx, 100
    xor bl, bl                  ; pattern index (0=A, 1=B, 2=C)
    call .fill_bank

    ; Bank 1 (odd screen rows: 1, 3, 5, ...)
    mov di, 0x2000
    mov cx, 100
    xor bl, bl
    call .fill_bank

    pop es
    ret

.fill_bank:
.fill_row:
    push cx
    push bx

    ; Column 1: 27 bytes
    xor bh, bh
    mov al, [pattern_c1 + bx]
    mov cx, 27
    rep stosb

    ; Column 2: 26 bytes
    mov al, [pattern_c2 + bx]
    mov cx, 26
    rep stosb

    ; Column 3: 27 bytes
    mov al, [pattern_c3 + bx]
    mov cx, 27
    rep stosb

    pop bx
    pop cx

    ; Advance pattern: 0→1→2→0
    inc bl
    cmp bl, 3
    jb .no_wrap
    xor bl, bl
.no_wrap:
    loop .fill_row
    ret

; ============================================================================
; render_frame — Per-scanline palette flip + E2 gradient (even lines only)
; ============================================================================
; Deferred open/close: palette write session opened on odd HBLANK,
; consumed by OUTSB on even HBLANK. Reduces even critical path to 29 cycles.
;
; Even lines (3 OUTs, ~29 cycles — comfortable in ~80-cycle HBLANK):
;   OUT PORT_D9  ← flip palette
;   OUTSB PORT_DE ← E2 R value  (write pointer already at E2)
;   OUTSB PORT_DE ← E2 GB value
;
; Odd lines (3 OUTs, ~37 cycles):
;   OUT PORT_D9  ← flip palette
;   OUT PORT_DD  ← 0x80 (close previous write session)
;   OUT PORT_DD  ← 0x44 (open at E2 for next even line)
;
; Even/odd decision is made BEFORE waiting for HSYNC, so the critical
; HBLANK path has zero branching — straight from HSYNC detect to OUTs.
;
; Pre-open: palette write opened at E2 before loop for first even line.
;
; Reads gradient_buffer: 100 entries × 2 bytes, consumed by OUTSB on even lines
; ============================================================================

render_frame:
    cli
    cld
    mov si, gradient_buffer
    mov dx, PORT_DE             ; for OUTSB
    mov cx, SCREEN_HEIGHT       ; 200
    mov bl, PAL_EVEN            ; start with palette 0

    cmp byte [hsync_enabled], 0
    je .no_hsync_loop

    ; Pre-seed E2 with first gradient color (still in VBLANK, timing free)
    ; Prevents stale E2 from last frame showing on first line
    mov al, OPEN_ENTRY2
    out PORT_DD, al
    outsb                       ; E2 R from gradient_buffer[0]
    outsb                       ; E2 GB
    mov al, CLOSE_PAL
    out PORT_DD, al
    mov si, gradient_buffer     ; reset SI for render loop

    ; Pre-open palette at E2 for first even line
    mov al, OPEN_ENTRY2
    out PORT_DD, al

    ; ------------------------------------------------------------------
    ; HSYNC-synced render loop — 200 scanlines
    ; Even/odd branch chosen BEFORE HSYNC wait (zero-branch critical path)
    ; ------------------------------------------------------------------

.next_line:
    ; Decide even/odd BEFORE waiting (so critical path is branch-free)
    test cl, 1
    jnz .odd_line

    ; === EVEN LINE PATH: flip + E2 update (3 OUTs) ===
.wait_low_e:
    in al, PORT_DA
    test al, 0x01
    jnz .wait_low_e
.wait_high_e:
    in al, PORT_DA
    test al, 0x01
    jz .wait_high_e

    ; --- Critical HBLANK: 3 OUTs, ~29 cycles ---
    ; (palette already opened at E2 by odd line or pre-open)
    mov al, bl
    out PORT_D9, al             ; flip palette
    outsb                       ; E2 R  (DS:SI → port DX)
    outsb                       ; E2 GB
    ; --- End critical ---

    xor bl, PAL_ODD             ; toggle for next line
    loop .next_line
    jmp short .done_render

    ; === ODD LINE PATH: flip + close + open (3 OUTs) ===
.odd_line:
.wait_low_o:
    in al, PORT_DA
    test al, 0x01
    jnz .wait_low_o
.wait_high_o:
    in al, PORT_DA
    test al, 0x01
    jz .wait_high_o

    ; --- Critical HBLANK: 3 OUTs, ~37 cycles ---
    mov al, bl
    out PORT_D9, al             ; flip palette
    mov al, CLOSE_PAL
    out PORT_DD, al             ; close previous write session
    mov al, OPEN_ENTRY2
    out PORT_DD, al             ; open at E2 for next even line
    ; --- End critical ---

    xor bl, PAL_ODD
    loop .next_line
    jmp short .done_render

    ; ------------------------------------------------------------------
    ; Non-synced render (debug mode)
    ; ------------------------------------------------------------------

.no_hsync_loop:
    mov cx, SCREEN_HEIGHT

.no_sync_line:
    mov al, bl
    out PORT_D9, al
    xor bl, PAL_ODD

    test cl, 1
    jnz .no_sync_skip

    mov al, OPEN_ENTRY2
    out PORT_DD, al
    outsb
    outsb
    mov al, CLOSE_PAL
    out PORT_DD, al

.no_sync_skip:
    push cx
    mov cx, 30
.delay:
    loop .delay
    pop cx

    loop .no_sync_line

.done_render:
    ; Close any pending palette write session
    mov al, CLOSE_PAL
    out PORT_DD, al
    ; Reset to palette 0 for clean state
    mov al, PAL_EVEN
    out PORT_D9, al

    sti
    ret

; ============================================================================
; wait_vblank — Wait for vertical retrace
; ============================================================================

wait_vblank:
    cmp byte [vsync_enabled], 0
    je .done
.wait_not_vsync:
    in al, PORT_DA
    test al, 0x08
    jnz .wait_not_vsync
.wait_vsync:
    in al, PORT_DA
    test al, 0x08
    jz .wait_vsync
.done:
    ret

; ============================================================================
; check_keyboard — Non-blocking key check
; ============================================================================
; Returns: AL = 0xFF (ESC), 1 (Space), 2 (Enter), 0 (none/other)
; ============================================================================

check_keyboard:
    mov ah, 0x01
    int 0x16
    jz .no_key

    mov ah, 0x00
    int 0x16                    ; AL = ASCII, AH = scan code

    cmp al, 0x1B               ; ESC
    je .key_esc
    cmp al, 0x20               ; Space
    je .key_space
    cmp al, 0x0D               ; Enter
    je .key_enter
    or al, 0x20                ; to lowercase
    cmp al, 'h'
    je .key_h
    cmp al, 'v'
    je .key_v
    xor al, al                 ; unknown key
    ret

.key_esc:
    mov al, 0xFF
    ret
.key_space:
    mov al, 1
    ret
.key_enter:
    mov al, 2
    ret
.key_h:
    xor byte [hsync_enabled], 1
    xor al, al
    ret
.key_v:
    xor byte [vsync_enabled], 1
    xor al, al
    ret
.no_key:
    xor al, al
    ret

; ============================================================================
; DATA — Pattern lookup (for fill_screen VRAM rotation)
; ============================================================================
; Indexed by pattern 0(A), 1(B), 2(C)
;   A: col1=pix1, col2=pix2, col3=pix3  (E2 goes to col1)
;   B: col1=pix3, col2=pix2, col3=pix1  (E2 goes to col3)
;   C: col1=pix2, col2=pix1, col3=pix3  (E2 goes to col2)

pattern_c1: db 0x55, 0xFF, 0xAA
pattern_c2: db 0xAA, 0xAA, 0x55
pattern_c3: db 0xFF, 0x55, 0xFF

; ============================================================================
; DATA — Static preset pointer tables
; ============================================================================

; Mode 0 presets (Sunset/Rainbow/Cubehelix)
m0_presets:
    dw preset_black
    dw preset_dark
    dw preset_gray
    dw m0_auto

; Mode 1 presets (Red/Green/Blue)
m1_presets:
    dw preset_black
    dw preset_dark
    dw preset_gray
    dw m1_auto

; ============================================================================
; DATA — Static preset values (E3, E4, E5, E6, E7 — 5 entries × 2 bytes)
; ============================================================================
; Each column's "background" appearance:
;   E3 = pix1 on odd lines (shared by all 3 columns in turn)
;   E4 = pix2 on even pal 0 lines (col2 dominant: 4/6 lines)
;   E5 = pix2 on odd pal 1 lines  (col2 dominant: 4/6 lines)
;   E6 = pix3 on even pal 0 lines (col3 dominant: 4/6 lines)
;   E7 = pix3 on odd pal 1 lines  (col3 dominant: 4/6 lines)
; ============================================================================

preset_black:
    db 0, 0x00     ; E3
    db 0, 0x00     ; E4
    db 0, 0x00     ; E5
    db 0, 0x00     ; E6
    db 0, 0x00     ; E7

preset_dark:
    db 2, 0x10     ; E3: R2,G1,B0 dark brown
    db 1, 0x12     ; E4: R1,G1,B2 dark blue-gray
    db 1, 0x01     ; E5: R1,G0,B1 dark purple
    db 2, 0x02     ; E6: R2,G0,B2 dark magenta
    db 1, 0x11     ; E7: R1,G1,B1 dark gray

preset_gray:
    db 2, 0x22     ; E3: R2,G2,B2
    db 3, 0x33     ; E4: R3,G3,B3
    db 2, 0x22     ; E5: R2,G2,B2
    db 4, 0x44     ; E6: R4,G4,B4
    db 3, 0x33     ; E7: R3,G3,B3

m0_auto:
    db 2, 0x11     ; E3: warm dark (all cols odd-line companion)
    db 0, 0x33     ; E4: dark teal (col2 even — rainbow midpoint)
    db 0, 0x22     ; E5: darker teal (col2 odd)
    db 1, 0x02     ; E6: dark purple (col3 even — cubehelix mid)
    db 1, 0x01     ; E7: darker purple (col3 odd)

m1_auto:
    db 1, 0x11     ; E3: dark gray (neutral)
    db 0, 0x20     ; E4: dark green (col2=green midpoint)
    db 0, 0x10     ; E5: darker green
    db 0, 0x03     ; E6: dark blue (col3=blue midpoint)
    db 0, 0x02     ; E7: darker blue

; ============================================================================
; DATA — Gradient tables (34 steps × 2 bytes each = 68 bytes)
; ============================================================================
; V6355D RGB333: byte 1 = R (0-7), byte 2 = (G << 4) | B
; ============================================================================

; --- Sunset: Purple → Magenta → Red → Orange → Yellow → White ---
grad_sunset:
    db 1, 0x03     ; Step  0: R1,G0,B3 dark purple
    db 2, 0x04     ; Step  1: R2,G0,B4
    db 2, 0x05     ; Step  2: R2,G0,B5
    db 3, 0x06     ; Step  3: R3,G0,B6
    db 3, 0x07     ; Step  4: R3,G0,B7 purple
    db 4, 0x07     ; Step  5: R4,G0,B7
    db 4, 0x06     ; Step  6: R4,G0,B6
    db 5, 0x06     ; Step  7: R5,G0,B6
    db 5, 0x05     ; Step  8: R5,G0,B5 magenta
    db 6, 0x05     ; Step  9: R6,G0,B5
    db 6, 0x04     ; Step 10: R6,G0,B4
    db 7, 0x04     ; Step 11: R7,G0,B4
    db 7, 0x03     ; Step 12: R7,G0,B3 red-magenta
    db 7, 0x02     ; Step 13: R7,G0,B2
    db 7, 0x01     ; Step 14: R7,G0,B1
    db 7, 0x00     ; Step 15: R7,G0,B0 bright red
    db 7, 0x00     ; Step 16: R7,G0,B0
    db 7, 0x10     ; Step 17: R7,G1,B0
    db 7, 0x10     ; Step 18: R7,G1,B0
    db 7, 0x20     ; Step 19: R7,G2,B0 orange
    db 7, 0x20     ; Step 20: R7,G2,B0
    db 7, 0x30     ; Step 21: R7,G3,B0
    db 7, 0x30     ; Step 22: R7,G3,B0
    db 7, 0x40     ; Step 23: R7,G4,B0 golden
    db 7, 0x40     ; Step 24: R7,G4,B0
    db 7, 0x50     ; Step 25: R7,G5,B0
    db 7, 0x50     ; Step 26: R7,G5,B0
    db 7, 0x60     ; Step 27: R7,G6,B0 yellow
    db 7, 0x60     ; Step 28: R7,G6,B0
    db 7, 0x70     ; Step 29: R7,G7,B0 bright yellow
    db 7, 0x70     ; Step 30: R7,G7,B0
    db 7, 0x71     ; Step 31: R7,G7,B1
    db 7, 0x72     ; Step 32: R7,G7,B2
    db 7, 0x73     ; Step 33: R7,G7,B3 warm white

; --- Rainbow: full hue rotation ---
grad_rainbow:
    db 7, 0x00     ; Step  0: Red
    db 7, 0x10     ; Step  1
    db 7, 0x20     ; Step  2: Orange
    db 7, 0x30     ; Step  3
    db 7, 0x40     ; Step  4
    db 7, 0x50     ; Step  5
    db 7, 0x70     ; Step  6: Yellow
    db 6, 0x70     ; Step  7
    db 5, 0x70     ; Step  8
    db 4, 0x70     ; Step  9
    db 3, 0x70     ; Step 10: Green
    db 2, 0x70     ; Step 11
    db 0, 0x70     ; Step 12: Pure green
    db 0, 0x71     ; Step 13
    db 0, 0x72     ; Step 14: Teal
    db 0, 0x73     ; Step 15
    db 0, 0x75     ; Step 16
    db 0, 0x77     ; Step 17: Cyan
    db 0, 0x67     ; Step 18
    db 0, 0x57     ; Step 19
    db 0, 0x47     ; Step 20
    db 0, 0x37     ; Step 21: Blue
    db 0, 0x27     ; Step 22
    db 0, 0x17     ; Step 23
    db 0, 0x07     ; Step 24: Pure blue
    db 1, 0x07     ; Step 25
    db 2, 0x07     ; Step 26: Indigo
    db 3, 0x07     ; Step 27
    db 4, 0x07     ; Step 28: Purple
    db 5, 0x07     ; Step 29
    db 5, 0x06     ; Step 30
    db 6, 0x05     ; Step 31
    db 7, 0x04     ; Step 32
    db 7, 0x02     ; Step 33: back toward red

; --- Cubehelix: monotonic luminance spiral ---
grad_cubehelix:
    db 0, 0x00     ; Step  0: Black
    db 0, 0x01     ; Step  1
    db 0, 0x02     ; Step  2: Dark blue
    db 0, 0x13     ; Step  3
    db 0, 0x24     ; Step  4
    db 0, 0x35     ; Step  5: Teal
    db 1, 0x45     ; Step  6
    db 1, 0x55     ; Step  7: Green
    db 2, 0x64     ; Step  8
    db 3, 0x63     ; Step  9: Olive
    db 4, 0x52     ; Step 10
    db 5, 0x41     ; Step 11
    db 5, 0x30     ; Step 12: Orange
    db 6, 0x20     ; Step 13
    db 6, 0x10     ; Step 14
    db 6, 0x01     ; Step 15: Red
    db 6, 0x02     ; Step 16
    db 5, 0x03     ; Step 17: Purple
    db 5, 0x04     ; Step 18
    db 4, 0x15     ; Step 19
    db 3, 0x26     ; Step 20
    db 3, 0x37     ; Step 21: Blue
    db 3, 0x57     ; Step 22
    db 4, 0x67     ; Step 23
    db 5, 0x76     ; Step 24: Light teal
    db 5, 0x75     ; Step 25
    db 6, 0x74     ; Step 26
    db 6, 0x63     ; Step 27
    db 7, 0x53     ; Step 28: Peach
    db 7, 0x43     ; Step 29
    db 7, 0x34     ; Step 30: Pink
    db 7, 0x45     ; Step 31
    db 7, 0x66     ; Step 32: Lavender
    db 7, 0x77     ; Step 33: White

; --- Pure Red: Black → Red → White ---
grad_red:
    db 0, 0x00     ; Step  0
    db 1, 0x00     ; Step  1
    db 1, 0x00     ; Step  2
    db 2, 0x00     ; Step  3
    db 2, 0x00     ; Step  4
    db 3, 0x00     ; Step  5
    db 3, 0x00     ; Step  6
    db 4, 0x00     ; Step  7
    db 4, 0x00     ; Step  8
    db 5, 0x00     ; Step  9
    db 5, 0x00     ; Step 10
    db 6, 0x00     ; Step 11
    db 6, 0x00     ; Step 12
    db 7, 0x00     ; Step 13: Bright red
    db 7, 0x00     ; Step 14
    db 7, 0x10     ; Step 15
    db 7, 0x10     ; Step 16
    db 7, 0x20     ; Step 17
    db 7, 0x20     ; Step 18
    db 7, 0x30     ; Step 19
    db 7, 0x30     ; Step 20
    db 7, 0x40     ; Step 21
    db 7, 0x40     ; Step 22
    db 7, 0x50     ; Step 23
    db 7, 0x50     ; Step 24
    db 7, 0x51     ; Step 25
    db 7, 0x62     ; Step 26
    db 7, 0x62     ; Step 27
    db 7, 0x63     ; Step 28
    db 7, 0x63     ; Step 29
    db 7, 0x74     ; Step 30
    db 7, 0x75     ; Step 31
    db 7, 0x76     ; Step 32
    db 7, 0x77     ; Step 33: White

; --- Pure Green: Black → Green → White ---
grad_green:
    db 0, 0x00     ; Step  0
    db 0, 0x10     ; Step  1
    db 0, 0x10     ; Step  2
    db 0, 0x20     ; Step  3
    db 0, 0x20     ; Step  4
    db 0, 0x30     ; Step  5
    db 0, 0x30     ; Step  6
    db 0, 0x40     ; Step  7
    db 0, 0x40     ; Step  8
    db 0, 0x50     ; Step  9
    db 0, 0x50     ; Step 10
    db 0, 0x60     ; Step 11
    db 0, 0x60     ; Step 12
    db 0, 0x70     ; Step 13: Bright green
    db 0, 0x70     ; Step 14
    db 1, 0x70     ; Step 15
    db 1, 0x70     ; Step 16
    db 2, 0x70     ; Step 17
    db 2, 0x70     ; Step 18
    db 3, 0x70     ; Step 19
    db 3, 0x70     ; Step 20
    db 4, 0x70     ; Step 21
    db 4, 0x70     ; Step 22
    db 5, 0x70     ; Step 23
    db 5, 0x71     ; Step 24
    db 5, 0x71     ; Step 25
    db 6, 0x72     ; Step 26
    db 6, 0x72     ; Step 27
    db 6, 0x73     ; Step 28
    db 6, 0x73     ; Step 29
    db 7, 0x74     ; Step 30
    db 7, 0x75     ; Step 31
    db 7, 0x76     ; Step 32
    db 7, 0x77     ; Step 33: White

; --- Pure Blue: Black → Blue → White ---
grad_blue:
    db 0, 0x00     ; Step  0
    db 0, 0x01     ; Step  1
    db 0, 0x01     ; Step  2
    db 0, 0x02     ; Step  3
    db 0, 0x02     ; Step  4
    db 0, 0x03     ; Step  5
    db 0, 0x03     ; Step  6
    db 0, 0x04     ; Step  7
    db 0, 0x04     ; Step  8
    db 0, 0x05     ; Step  9
    db 0, 0x05     ; Step 10
    db 0, 0x06     ; Step 11
    db 0, 0x06     ; Step 12
    db 0, 0x07     ; Step 13: Bright blue
    db 0, 0x07     ; Step 14
    db 0, 0x17     ; Step 15
    db 0, 0x17     ; Step 16
    db 0, 0x27     ; Step 17
    db 0, 0x27     ; Step 18
    db 0, 0x37     ; Step 19
    db 0, 0x37     ; Step 20
    db 0, 0x47     ; Step 21
    db 0, 0x47     ; Step 22
    db 0, 0x57     ; Step 23
    db 1, 0x57     ; Step 24
    db 1, 0x57     ; Step 25
    db 2, 0x67     ; Step 26
    db 2, 0x67     ; Step 27
    db 3, 0x67     ; Step 28
    db 3, 0x67     ; Step 29
    db 4, 0x77     ; Step 30
    db 5, 0x77     ; Step 31
    db 6, 0x77     ; Step 32
    db 7, 0x77     ; Step 33: White

; ============================================================================
; VARIABLES
; ============================================================================

current_mode:   db 0            ; 0 = Sunset/Rainbow/Cubehelix, 1 = RGB
static_sub:     db 0            ; 0=black, 1=dark, 2=gray, 3=auto
hsync_enabled:  db 1
vsync_enabled:  db 1

col1_ptr:       dw grad_sunset
col2_ptr:       dw grad_rainbow
col3_ptr:       dw grad_cubehelix
static_ptr:     dw preset_black

; ============================================================================
; GRADIENT BUFFER — Precomputed at runtime by build_gradient_buffer
; ============================================================================
; 100 entries × 2 bytes = 200 bytes (uninitialized, lives above loaded code)
; Format per entry: [R_byte, GB_byte] for OUTSB streaming to PORT_DE
; ============================================================================
gradient_buffer:
