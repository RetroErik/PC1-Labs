; ============================================================================
; CGAFLIP-DIAG4.ASM — Static E6 Test: Proving Column-Order Constraint Disappears
; ============================================================================
;
; WHAT THIS TESTS:
;   E6 and E7 are placed in COLUMN 1 (leftmost) — the beam-racing danger zone.
;   E6 is written with the SAME fixed value every scanline (static mid-gray).
;   E7 is fully dynamic (gradient), written LAST at ~cycle 119.
;
;   Direct A/B comparison with cgaflip-diag3:
;     diag3: E6 dynamic in col1 → ~100px stale artifact on even lines
;     diag4: E6 static  in col1 → no artifact (stale = new, identical)
;             E7 dynamic in col1 → no artifact either (see FINDING below)
;
; HARDWARE TEST RESULT (Olivetti Prodest PC1):
;   Column 1 (E6/E7): E6=static gray (even) — NO artifact. ✓
;                      E7=gradient (odd) — NO artifact either! ✓
;   Column 2 (E4/E5): Full gradient — clean. ✓
;   Column 3 (E2/E3): Full gradient — clean. ✓
;
; KEY FINDING:
;   E7 is dynamic in column 1 yet shows NO stale artifact despite finishing
;   at ~cycle 119 (beam arrives at col1 ~cycle 80). This is because E7 is an
;   "upcoming" entry: it's written during EVEN-line HBLANK but only DISPLAYED
;   on the next ODD line (palette 1). By the time the odd line starts drawing,
;   E7 was written a full scanline earlier — well before the beam arrives.
;
;   The column-order constraint ONLY applies to "current" entries (E2/E4/E6)
;   that are both written AND displayed on the same even scanline.
;   "Upcoming" entries (E3/E5/E7) are always safe regardless of column position.
;
; CHANGES FROM CGAFLIP9:
;   1. VRAM layout swapped: 0xFF in col1 (E6/E7), 0x55 in col3 (E2/E3)
;   2. build_outsb_buffer: E6 = fixed color, E7 = col1 gradient
;   3. E2/E3 get col3 gradient, E4/E5 get col2 gradient (unchanged)
;   4. Render loop identical — same OUTSB order E2→E3→E4→E5→E6→E7
;
; CONTROLS:
;   ESC   : Exit to DOS
;   SPACE : Cycle gradient mode (same as cgaflip9)
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

NUM_STEPS_34    equ 34         ; gradient steps for modes 0/1
NUM_STEPS_200   equ 200        ; gradient steps for mode 2 (all 512)
NUM_MODES       equ 4          ; number of gradient modes

; Fixed E6 color — mid-gray so the venetian-blind blending is visible
STATIC_E6_R     equ 3          ; R=3
STATIC_E6_GB    equ 0x33       ; G=3, B=3 → mid-gray RGB333

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

    ; Fill VRAM with 3-column pattern (same as cgaflip9)
    call fill_screen

    ; Default: Mode 0 (Sunset / Rainbow / Cubehelix)
    mov byte [current_mode], 0
    call set_mode_ptrs
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

    ; Cycle gradient mode: 0 -> 1 -> 2 -> 3 -> 0
    inc byte [current_mode]
    cmp byte [current_mode], NUM_MODES
    jb .mode_ok
    mov byte [current_mode], 0
.mode_ok:
    call set_mode_ptrs
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
; set_mode_ptrs — Configure gradient pointers and num_steps for current mode
; ============================================================================

set_mode_ptrs:
    cmp byte [current_mode], 1
    je .smp_mode1
    cmp byte [current_mode], 2
    je .smp_mode2
    cmp byte [current_mode], 3
    je .smp_mode3

    ; Mode 0: Sunset / Rainbow / Cubehelix (34 steps)
    mov word [col1_ptr], grad_sunset
    mov word [col2_ptr], grad_rainbow
    mov word [col3_ptr], grad_cubehelix
    mov word [num_steps], NUM_STEPS_34
    ret

.smp_mode1:
    ; Mode 1: Red / Green / Blue (34 steps)
    mov word [col1_ptr], grad_red
    mov word [col2_ptr], grad_green
    mov word [col3_ptr], grad_blue
    mov word [num_steps], NUM_STEPS_34
    ret

.smp_mode2:
    ; Mode 2: All 512 RGB333 colors (luminance sorted)
    mov word [col1_ptr], grad_512_col1
    mov word [col2_ptr], grad_512_col2
    mov word [col3_ptr], grad_512_col3
    mov word [num_steps], NUM_STEPS_200
    ret

.smp_mode3:
    ; Mode 3: Sunset / Rainbow / Cubehelix (200 steps)
    mov word [col1_ptr], grad200_sunset
    mov word [col2_ptr], grad200_rainbow
    mov word [col3_ptr], grad200_cubehelix
    mov word [num_steps], NUM_STEPS_200
    ret

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
; fill_screen — VRAM with 3-column pattern (E6/E7 in column 1)
; ============================================================================
; Both banks: 100 rows of [27x0xFF, 26x0xAA, 27x0x55]
;   pix3(0xFF) -> E6/E7    pix2(0xAA) -> E4/E5    pix1(0x55) -> E2/E3
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
    mov al, 0xFF            ; pixel 3 -> E6/E7 (column 1 — beam-race zone)
    mov cx, 27
    rep stosb
    mov al, 0xAA            ; pixel 2 -> E4/E5 (column 2)
    mov cx, 26
    rep stosb
    mov al, 0x55            ; pixel 1 -> E2/E3 (column 3)
    mov cx, 27
    rep stosb
    pop cx
    loop .row
    ret

; ============================================================================
; build_outsb_buffer — Precompute 100 x 12 byte OUTSB buffer (even lines only)
; ============================================================================
;
; DIFFERENCE FROM CGAFLIP9:
;   E6/E7 in column 1 (swapped VRAM). E6 is static, E7 is dynamic.
;   E2/E3 moved to column 3. E4/E5 stay in column 2.
;
; Buffer entry n (12 bytes):  [OUTSB writes in this order]
;   E2_R, E2_GB = col3[step_even]   (column 3 — safe, beam arrives ~cycle 320)
;   E3_R, E3_GB = col3[step_odd]    (column 3 — safe)
;   E4_R, E4_GB = col2[step_even]   (column 2 — safe, beam arrives ~cycle 200)
;   E5_R, E5_GB = col2[step_odd]    (column 2 — safe)
;   E6_R, E6_GB = STATIC (fixed!)   (column 1 — stale=new, no artifact)
;   E7_R, E7_GB = col1[step_odd]    (column 1 — dynamic, finishes ~cycle 119)
;
; ============================================================================

build_outsb_buffer:
    push bp
    cld
    mov di, outsb_buffer
    xor bp, bp              ; even line counter 0..99

.line_loop:
    ; --- step_even = (bp*2) * (num_steps-1) / 199 ---
    mov ax, bp
    shl ax, 1               ; ax = screen line = bp * 2
    mov cx, [num_steps]
    dec cx                  ; cx = num_steps - 1
    mul cx                  ; DX:AX = (bp*2) * (num_steps-1)
    mov cx, 199
    xor dx, dx
    div cx                  ; AX = step_even
    shl ax, 1               ; x 2 for byte offset
    mov [off_even], ax

    ; --- step_odd = (bp*2+1) * (num_steps-1) / 199 ---
    mov ax, bp
    shl ax, 1
    inc ax                  ; ax = bp*2 + 1
    cmp ax, SCREEN_HEIGHT
    jb .no_clamp
    mov ax, SCREEN_HEIGHT - 1
.no_clamp:
    mov cx, [num_steps]
    dec cx
    mul cx
    mov cx, 199
    xor dx, dx
    div cx
    shl ax, 1
    mov [off_odd], ax

    ; --- Write 12 bytes ---

    ; E2/E3 → Column 3 (rightmost — written first, safe)
    mov bx, [col3_ptr]
    mov si, [off_even]
    mov ax, [bx+si]         ; col3 @ step_even
    stosw                   ; E2: R, GB
    mov si, [off_odd]
    mov ax, [bx+si]         ; col3 @ step_odd
    stosw                   ; E3: R, GB

    ; E4/E5 → Column 2 (middle — safe)
    mov bx, [col2_ptr]
    mov si, [off_even]
    mov ax, [bx+si]
    stosw                   ; E4: R, GB
    mov si, [off_odd]
    mov ax, [bx+si]
    stosw                   ; E5: R, GB

    ; E6 → Column 1 (leftmost — STATIC, no beam-race artifact)
    mov al, STATIC_E6_R     ; Fixed color — always the same
    stosb                   ; E6: R
    mov al, STATIC_E6_GB
    stosb                   ; E6: GB
    ; E7 → Column 1 (leftmost — DYNAMIC, tests odd-line artifacts)
    mov bx, [col1_ptr]
    mov si, [off_odd]
    mov ax, [bx+si]         ; col1 @ step_odd
    stosw                   ; E7: R, GB

    inc bp
    cmp bp, NUM_EVEN_LINES  ; 100
    jb .line_loop

    pop bp
    ret

; ============================================================================
; render_frame — HSYNC-synced per-scanline palette streaming (identical to cgaflip9)
; ============================================================================

render_frame:
    cli
    cld
    mov si, outsb_buffer
    mov dx, PORT_DE             ; for OUTSB
    mov cx, SCREEN_HEIGHT       ; 200
    mov bl, PAL_EVEN            ; start with palette 0

    ; Pre-seed E2-E7 with first entry (still in VBLANK, timing free)
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
    outsb                       ; E6 R (static)
    outsb                       ; E6 GB (static)
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
    outsb                       ; E6 R   (static — same value) ~92
    outsb                       ; E6 GB  (no artifact!)        ~101
    outsb                       ; E7 R                         ~110
    outsb                       ; E7 GB                        ~119
    ; --- End critical ---
    ; E6 is static so stale=new → no visible glitch regardless of column

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

; --- All 512 RGB333 colors, sorted by luminance ---
%include "all512_tables.inc"

; --- 200-step gradients ---
%include "grad200_tables.inc"

; ============================================================================
; VARIABLES
; ============================================================================

current_mode:   db 0
num_steps:      dw NUM_STEPS_34

col1_ptr:       dw grad_sunset
col2_ptr:       dw grad_rainbow
col3_ptr:       dw grad_cubehelix

; Build temporaries
off_even:       dw 0
off_odd:        dw 0

; ============================================================================
; OUTSB BUFFER — 100 x 12 = 1200 bytes
; ============================================================================

outsb_buffer:
