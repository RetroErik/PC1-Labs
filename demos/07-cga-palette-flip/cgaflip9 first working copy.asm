; ============================================================================
; CGAFLIP9.ASM — Per-Scanline Full-Palette Gradients via Passthrough Streaming
; ============================================================================
;
; TECHNIQUE: Per-scanline E2-E7 update via deferred open/close + passthrough
;
;   Uses cgaflip7's proven deferred open/close pattern, extended to write
;   all 6 palette entries (E2-E7) instead of just E2:
;
;   Even lines (13 OUTs, ~119 cycles):
;     Flip + OUTSB x12  (palette already opened by previous odd line)
;     Active entries (E2/E4/E6) = thisLine's colors (passthrough)
;     Inactive entries (E3/E5/E7) = nextLine's colors (prep for odd)
;
;   Odd lines (3 OUTs, ~37 cycles):
;     Flip + Close + Open  (reset write pointer to E2 for next even)
;
;   Pre-computed OUTSB buffer (100 x 12 = 1200 bytes, even lines only):
;     Each entry: E2_R, E2_GB, E3_R, E3_GB, E4_R, E4_GB,
;                 E5_R, E5_GB, E6_R, E6_GB, E7_R, E7_GB
;
;   Active entries receive the SAME value = "passthrough" (safe on V6355D,
;   proven by cgaflip-diag2). Inactive entries receive next line's colors.
;
;   No VRAM rotation needed — simple static 3-column pixel pattern.
;   Every line gets 3 unique gradient colors. 200 lines x 3 columns.
;
; SCREEN LAYOUT:
;   Col1 (108px, pix1=0x55): E2 on pal0, E3 on pal1
;   Col2 (104px, pix2=0xAA): E4 on pal0, E5 on pal1
;   Col3 (108px, pix3=0xFF): E6 on pal0, E7 on pal1
;
; CONTROLS:
;   ESC   : Exit to DOS
;   SPACE : Toggle gradient mode (Sunset/Rainbow/Cubehelix <-> Red/Green/Blue)
;
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
NUM_EVEN_LINES  equ 100

PAL_EVEN        equ 0x00       ; palette 0, bg/border = entry 0
PAL_ODD         equ 0x20       ; palette 1, bg/border = entry 0

OPEN_E2         equ 0x44       ; open palette write at entry 2 — VERIFIED
CLOSE_PAL       equ 0x80       ; close palette write

NUM_STEPS       equ 34         ; gradient steps per source table

; ============================================================================
; MAIN PROGRAM
; ============================================================================

main:
    ; Set CGA mode 4 (320x200x4)
    mov ax, 0x0004
    int 0x10

    ; Restore DS=ES=CS (INT 10h may trash ES on Olivetti BIOS)
    push cs
    pop ds
    push cs
    pop es

    ; Fill VRAM with 3-column pattern (no rotation)
    call fill_screen

    ; Default: Mode 0 (Sunset / Rainbow / Cubehelix)
    mov byte [current_mode], 0
    mov word [col1_ptr], grad_sunset
    mov word [col2_ptr], grad_rainbow
    mov word [col3_ptr], grad_cubehelix
    call build_outsb_buffer
    call wait_vblank
    call program_palette

; === Main loop ===
.main_loop:
    call wait_vblank
    call render_frame

    ; Check keyboard
    mov ah, 0x01
    int 0x16
    jz .main_loop

    mov ah, 0x00
    int 0x16

    cmp al, 0x1B            ; ESC
    je .exit
    cmp al, 0x20            ; Space
    jne .main_loop

    ; Toggle gradient mode
    xor byte [current_mode], 1
    cmp byte [current_mode], 0
    jne .set_mode1

    ; Mode 0: Sunset / Rainbow / Cubehelix
    mov word [col1_ptr], grad_sunset
    mov word [col2_ptr], grad_rainbow
    mov word [col3_ptr], grad_cubehelix
    jmp short .rebuild

.set_mode1:
    ; Mode 1: Red / Green / Blue
    mov word [col1_ptr], grad_red
    mov word [col2_ptr], grad_green
    mov word [col3_ptr], grad_blue

.rebuild:
    call build_outsb_buffer
    call wait_vblank
    call program_palette
    jmp .main_loop

.exit:
    mov ax, 3               ; text mode
    int 0x10
    mov ax, 0x4C00
    int 0x21

; ============================================================================
; wait_vblank — Wait for vertical blanking interval
; ============================================================================

wait_vblank:
.not_vb:
    in al, PORT_DA
    test al, 0x08
    jnz .not_vb
.in_vb:
    in al, PORT_DA
    test al, 0x08
    jz .in_vb
    ret

; ============================================================================
; program_palette — Set entries E2-E7 during VBLANK (proven pattern)
; ============================================================================
; Opens at 0x44 (entry 2), writes 12 bytes from outsb_buffer:
;   E2, E3, E4, E5, E6, E7
; Uses jmp $+2 as I/O delay (init path, not time-critical)
; Identical structure to cgaflip7's program_palette.
; ============================================================================

program_palette:
    cli

    mov bx, outsb_buffer

    mov al, OPEN_E2
    out PORT_DD, al
    jmp short $+2

    ; Write 6 entries x 2 bytes = 12 bytes with delays
    mov cx, 6
.write_entry:
    mov al, [bx]
    out PORT_DE, al
    jmp short $+2
    mov al, [bx+1]
    out PORT_DE, al
    jmp short $+2
    add bx, 2
    loop .write_entry

    mov al, CLOSE_PAL
    out PORT_DD, al

    sti
    ret

; ============================================================================
; fill_screen — VRAM with 3-column pattern (NO rotation)
; ============================================================================
; Both banks: 100 rows of [27x0x55, 26x0xAA, 27x0xFF]
;   pix1(0x55) -> E2/E3    pix2(0xAA) -> E4/E5    pix3(0xFF) -> E6/E7
; ============================================================================

fill_screen:
    push es
    mov ax, VIDEO_SEG
    mov es, ax
    cld

    ; Bank 0 (even screen rows)
    xor di, di
    mov cx, 100
    call .fill_bank

    ; Bank 1 (odd screen rows)
    mov di, 0x2000
    mov cx, 100
    call .fill_bank

    pop es
    ret

.fill_bank:
.row:
    push cx
    mov al, 0x55            ; pixel 1 -> E2/E3
    mov cx, 27
    rep stosb
    mov al, 0xAA            ; pixel 2 -> E4/E5
    mov cx, 26
    rep stosb
    mov al, 0xFF            ; pixel 3 -> E6/E7
    mov cx, 27
    rep stosb
    pop cx
    loop .row
    ret

; ============================================================================
; build_outsb_buffer — Precompute 100 x 12 byte OUTSB buffer (even lines only)
; ============================================================================
;
; For each even line pair (n = 0..99, screen lines 2n and 2n+1):
;   step_even = (2n) * 33 / 199       <- this even line's gradient step
;   step_odd  = (2n+1) * 33 / 199     <- next odd line's gradient step
;
; Buffer entry n (12 bytes):
;   E2_R, E2_GB = col1[step_even]   (active on pal0 = passthrough)
;   E3_R, E3_GB = col1[step_odd]    (inactive, prep for next odd line)
;   E4_R, E4_GB = col2[step_even]   (active = passthrough)
;   E5_R, E5_GB = col2[step_odd]    (inactive, prep)
;   E6_R, E6_GB = col3[step_even]   (active = passthrough)
;   E7_R, E7_GB = col3[step_odd]    (inactive, prep)
;
; ============================================================================

build_outsb_buffer:
    push bp
    cld
    mov di, outsb_buffer
    xor bp, bp              ; even line counter 0..99

.line_loop:
    ; --- step_even = (bp*2) * 33 / 199 ---
    mov ax, bp
    shl ax, 1               ; ax = screen line = bp * 2
    mov cx, NUM_STEPS - 1   ; 33
    mul cx                  ; DX:AX = (bp*2) * 33
    mov cx, 199
    xor dx, dx
    div cx                  ; AX = step_even
    shl ax, 1               ; x 2 for byte offset
    mov [off_even], ax

    ; --- step_odd = (bp*2+1) * 33 / 199 ---
    mov ax, bp
    shl ax, 1
    inc ax                  ; ax = bp*2 + 1
    cmp ax, SCREEN_HEIGHT
    jb .no_clamp
    mov ax, SCREEN_HEIGHT - 1
.no_clamp:
    mov cx, NUM_STEPS - 1
    mul cx
    mov cx, 199
    xor dx, dx
    div cx
    shl ax, 1
    mov [off_odd], ax

    ; --- Write 12 bytes: [E2even, E3odd, E4even, E5odd, E6even, E7odd] ---

    ; Column 1: E2 (even) + E3 (odd)
    mov bx, [col1_ptr]
    mov si, [off_even]
    mov ax, [bx+si]         ; col1 @ step_even
    stosw                   ; E2: R, GB
    mov si, [off_odd]
    mov ax, [bx+si]         ; col1 @ step_odd
    stosw                   ; E3: R, GB

    ; Column 2: E4 (even) + E5 (odd)
    mov bx, [col2_ptr]
    mov si, [off_even]
    mov ax, [bx+si]
    stosw                   ; E4: R, GB
    mov si, [off_odd]
    mov ax, [bx+si]
    stosw                   ; E5: R, GB

    ; Column 3: E6 (even) + E7 (odd)
    mov bx, [col3_ptr]
    mov si, [off_even]
    mov ax, [bx+si]
    stosw                   ; E6: R, GB
    mov si, [off_odd]
    mov ax, [bx+si]
    stosw                   ; E7: R, GB

    inc bp
    cmp bp, NUM_EVEN_LINES  ; 100
    jb .line_loop

    pop bp
    ret

; ============================================================================
; render_frame — HSYNC-synced per-scanline palette streaming
; ============================================================================
;
; Uses cgaflip7's proven deferred open/close pattern:
;
; Even lines (13 OUTs, ~119 cycles):
;   Flip + OUTSB x12  (palette already opened at E2 by previous odd line)
;   Active entries (E2/E4/E6) get same value = passthrough (proven safe)
;   Inactive entries (E3/E5/E7) get next line's colors
;   ~39 cycles spill into visible area — safe:
;     E2 done by cycle ~29 (HBLANK), E4 by ~65 (HBLANK), E6 by ~101 (visible)
;     All active entries written before beam reaches their column
;
; Odd lines (3 OUTs, ~37 cycles):
;   Flip + Close + Open at E2  (all in HBLANK, same as cgaflip7)
;
; Even/odd decision is made BEFORE HSYNC wait = branch-free critical path
;
; Pre-seed: writes line 0's E2-E7 during VBLANK
; Pre-open: palette write opened at E2 before loop for first even line
;
; Reads outsb_buffer: 100 entries x 12 bytes, consumed by OUTSB on even lines
; ============================================================================

render_frame:
    cli
    cld
    mov si, outsb_buffer
    mov dx, PORT_DE             ; for OUTSB
    mov cx, SCREEN_HEIGHT       ; 200
    mov bl, PAL_EVEN            ; start with palette 0

    ; Pre-seed E2-E7 with first entry (still in VBLANK, timing free)
    ; Prevents stale E2-E7 from last frame showing on first line
    mov al, OPEN_E2
    out PORT_DD, al
    jmp short $+2
    outsb                       ; E2 R
    outsb                       ; E2 GB
    outsb                       ; E3 R
    outsb                       ; E3 GB
    outsb                       ; E4 R
    outsb                       ; E4 GB
    outsb                       ; E5 R
    outsb                       ; E5 GB
    outsb                       ; E6 R
    outsb                       ; E6 GB
    outsb                       ; E7 R
    outsb                       ; E7 GB
    mov al, CLOSE_PAL
    out PORT_DD, al
    mov si, outsb_buffer        ; reset SI for render loop

    ; Pre-open palette at E2 for first even line
    mov al, OPEN_E2
    out PORT_DD, al

    ; ------------------------------------------------------------------
    ; HSYNC-synced render loop — 200 scanlines
    ; Even/odd branch chosen BEFORE HSYNC wait (zero-branch critical path)
    ; ------------------------------------------------------------------

.next_line:
    ; Decide even/odd BEFORE waiting (so critical path is branch-free)
    test cl, 1
    jnz .odd_line

    ; === EVEN LINE PATH: flip + E2-E7 update (13 OUTs) ===
.wait_low_e:
    in al, PORT_DA
    test al, 0x01
    jnz .wait_low_e
.wait_high_e:
    in al, PORT_DA
    test al, 0x01
    jz .wait_high_e

    ; --- Critical HBLANK: 13 OUTs, ~119 cycles ---
    ; (palette already opened at E2 by odd line or pre-open)
    mov al, bl
    out PORT_D9, al             ; flip palette                 ~11 cyc
    outsb                       ; E2 R  (DS:SI -> port DX)    ~20
    outsb                       ; E2 GB                        ~29
    outsb                       ; E3 R                         ~38
    outsb                       ; E3 GB                        ~47
    outsb                       ; E4 R                         ~56
    outsb                       ; E4 GB                        ~65
    outsb                       ; E5 R                         ~74
    outsb                       ; E5 GB  <- ~HBLANK boundary   ~83
    outsb                       ; E6 R                         ~92
    outsb                       ; E6 GB                        ~101
    outsb                       ; E7 R                         ~110
    outsb                       ; E7 GB                        ~119
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
    mov al, OPEN_E2
    out PORT_DD, al             ; open at E2 for next even line
    ; --- End critical ---

    xor bl, PAL_ODD
    loop .next_line
    jmp short .done_render

.done_render:
    mov al, PAL_EVEN
    out PORT_D9, al
    sti
    ret

; ============================================================================
; DATA — Gradient tables (34 steps x 2 bytes each)
; ============================================================================
; V6355D RGB333: byte 1 = R (0-7), byte 2 = (G << 4) | B
; ============================================================================

; --- Sunset: Purple -> Magenta -> Red -> Orange -> Yellow -> White ---
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

; --- Pure Red: Black -> Red -> White ---
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

; --- Pure Green: Black -> Green -> White ---
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

; --- Pure Blue: Black -> Blue -> White ---
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

col1_ptr:       dw grad_sunset
col2_ptr:       dw grad_rainbow
col3_ptr:       dw grad_cubehelix

; Build temporaries
off_even:       dw 0
off_odd:        dw 0

; ============================================================================
; OUTSB BUFFER — 100 x 12 = 1200 bytes (runtime, lives above loaded code)
; ============================================================================
; Format per entry: E2_R, E2_GB, E3_R, E3_GB, E4_R, E4_GB,
;                   E5_R, E5_GB, E6_R, E6_GB, E7_R, E7_GB
; ============================================================================

outsb_buffer:
