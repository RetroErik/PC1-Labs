; ============================================================================
; CGAFLIP7-STREAMING.ASM - Three-Column Gradient via Per-Scanline Palette Update
; ============================================================================
;
; Intermediate experiment — 9 OUTs per HBLANK (pre-deferred approach).
;   Superseded by cgaflip7.asm which uses deferred open/close (3 OUTs).
;
; DEMONSTRATION: Per-scanline palette entry 2 gradient on column 1,
;   combined with CGA palette flipping. Columns 2-3 show static
;   alternating colors from the palette flip (entries 4-7 set at init).
;
; TECHNIQUE:
;   9 OUTs per HBLANK (~72 cycles, fits in ~80 cycle HBLANK):
;     1. OUT 0xD9 — palette flip (alternating 0x00 / 0x20)
;     2. OUT 0xDD — open palette write at entry 0 (0x40)
;     3. OUT 0xDE — entry 0 R = 0 (keep black)
;     4. OUT 0xDE — entry 0 GB = 0 (keep black)
;     5. OUT 0xDE — entry 1 R = 0 (unused, stream through)
;     6. OUT 0xDE — entry 1 GB = 0 (unused, stream through)
;     7. OUT 0xDE — entry 2 R (gradient color)
;     8. OUT 0xDE — entry 2 GB (gradient color)
;     9. OUT 0xDD — close palette write (0x80)
;
;   Per-scanline update (every line, cycling through 200 gradient steps):
;     Even lines: pal 0 → update entry 2 (column 1 gradient)
;     Odd lines:  pal 1 → entry 3 visible (static from init)
;
;   Entry 2 gets a new RGB333 color every scanline (200 steps per frame).
;   On even lines, entry 2 is visible in column 1. On odd lines, entry 3
;   (set once during init) is visible instead. The eye blends even/odd
;   into smooth intermediate colors.
;
; SAFE APPROACH: Uses only 0x40 (open at entry 0) — VERIFIED on PC1.
;   Streams zeros through entries 0-1 to reach entry 2, then writes the
;   gradient color. This is the cgaflip3 proven approach (9 OUTs per HBLANK).
;   Only column 1 has a gradient; columns 2-3 show static alternating colors
;   from the palette flip. Open-at-offset (0x46, 0x48 etc.) was tested and
;   caused a black screen — the V6355D does not support arbitrary offsets.
;
; Written for NASM assembler
; Target: Olivetti Prodest PC1 with Yamaha V6355D video controller
; CPU: NEC V40 (80186 compatible) @ 8 MHz
;
; By Retro Erik - 2026
;
; ============================================================================
; CGA PALETTE MAPPING (with bg = entry 0)
; ============================================================================
;
;   Pixel  │ Even (pal 0)  │ Odd (pal 1)
;   ───────┼───────────────┼──────────────
;     0    │ entry 0 (bg)  │ entry 0 (bg)    ← both black, border too
;     1    │ entry 2       │ entry 3          ← Column 1 (left)
;     2    │ entry 4       │ entry 5          ← Column 2 (middle)
;     3    │ entry 6       │ entry 7          ← Column 3 (right)
;          │ (entry 1 unused)
;
; ============================================================================
; WHAT YOU SHOULD SEE
; ============================================================================
;
; Three vertical columns filling the screen:
;
;   Column 1 (left):   Full rainbow gradient (entry 2 updated per scanline)
;                      Red → Yellow → Green → Cyan → Blue → Purple
;   Column 2 (middle): Static alternating colors (entries 4/5 from init)
;   Column 3 (right):  Static alternating colors (entries 6/7 from init)
;
; Column 1 has visible scanline interlacing (even lines = gradient color,
; odd lines = entry 3 static color from init). The eye blends them.
;
; NOTE: This is a DIAGNOSTIC VERSION. The original cgaflip7 attempted to
; update entries 3-7 using open-at-offset (0x46-0x4E) but those commands
; caused a black screen on real PC1 hardware. This version proves the
; render loop works using only verified palette commands (0x40).
;
; ============================================================================
; CONTROLS
; ============================================================================
;
;   ESC : Exit to DOS
;   H   : Toggle HSYNC sync (default: ON)
;   V   : Toggle VSYNC sync (default: ON)
;
; ============================================================================

[BITS 16]
[ORG 0x100]

; ============================================================================
; Port Definitions — short aliases (saves ~4 cycles per OUT on V40)
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

; Both palettes use entry 0 for bg/border = black (no border flicker!)
PAL_EVEN        equ 0x00       ; palette 0, bg/border = entry 0
PAL_ODD         equ 0x20       ; palette 1, bg/border = entry 0

; V6355D palette commands:
OPEN_ENTRY0     equ 0x40       ; open palette write at entry 0 — VERIFIED
OPEN_ENTRY2     equ 0x44       ; open palette write at entry 2 — VERIFIED
CLOSE_PAL       equ 0x80       ; close palette write

; ============================================================================
; MAIN PROGRAM
; ============================================================================
main:
    mov byte [hsync_enabled], 1
    mov byte [vsync_enabled], 1

    mov ax, 0x0004              ; CGA 320x200x4 mode
    int 0x10

    call build_gradient_buffer  ; Precompute interleaved gradient data
    call wait_vblank
    call program_palette        ; Set initial palette entries 2-7
    call fill_screen_columns    ; Fill VRAM with 3 columns

.main_loop:
    call wait_vblank
    call render_frame           ; Per-scanline palette flip + gradient
    call check_keyboard
    cmp al, 0xFF
    jne .main_loop

    ; Exit: restore text mode
    mov ax, 0x0003
    int 0x10
    mov ax, 0x4C00
    int 0x21

; ============================================================================
; build_gradient_buffer — Precompute 200 entries of per-scanline palette data
; ============================================================================
; Builds a flat buffer of 200 entries, each 3 bytes: [palette_val, R, GB]
;
; Every scanline updates entry 2 via streaming (open at 0, write 0,1,2).
; The gradient cycles through grad_col1 (34 steps), stretched to fill 200
; scanlines: index = scanline × 34 / 200 (~6 scanlines per gradient step).
; Even lines use PAL_EVEN, odd lines use PAL_ODD.
;
; Buffer: 200 entries × 3 bytes = 600 bytes
; ============================================================================
build_gradient_buffer:
    mov di, gradient_buffer
    xor cx, cx              ; scanline counter (0 to 199)

.line_loop:
    ; Palette value: alternate even/odd
    test cl, 1
    jnz .odd_line
    mov byte [di], PAL_EVEN
    jmp short .set_color
.odd_line:
    mov byte [di], PAL_ODD

.set_color:
    ; Gradient index: scanline × 34 / 200
    ; This stretches 34 gradient steps evenly across 200 scanlines
    mov ax, cx
    mov bl, 34
    mul bl                  ; AX = scanline × 34   (max 199×34 = 6766)
    mov bl, 200
    div bl                  ; AL = AX / 200        (0-33)
    xor ah, ah
    mov bx, ax
    shl bx, 1              ; bx = index × 2 (byte offset into source table)
    mov al, [grad_col1 + bx]
    mov [di+1], al          ; R
    mov al, [grad_col1 + bx + 1]
    mov [di+2], al          ; G|B

    add di, 3
    inc cx
    cmp cx, SCREEN_HEIGHT
    jb .line_loop
    ret

; ============================================================================
; darken_r — Reduce R channel by 1 (min 0)
; ============================================================================
; Input/Output: AL = R value (0-7)
darken_r:
    sub al, 1
    jnc .ok
    xor al, al
.ok:
    ret

; ============================================================================
; darken_gb — Reduce G and B channels by 1 each (min 0)
; ============================================================================
; Input/Output: AL = (G << 4) | B
darken_gb:
    mov ah, al
    and ah, 0x70            ; isolate G (bits 6-4)
    and al, 0x07            ; isolate B (bits 2-0)
    sub ah, 0x10            ; G - 1 (in nibble position)
    jnc .g_ok
    xor ah, ah
.g_ok:
    sub al, 1               ; B - 1
    jnc .b_ok
    xor al, al
.b_ok:
    or al, ah               ; recombine
    ret

; ============================================================================
; program_palette — Set initial entries 2-7 from gradient step 0
; ============================================================================
; Opens at entry 2 (0x44) and streams all 6 entries (12 bytes).
; Entries 0-1 stay at power-on defaults (both black).
; Called during VBLANK — no timing constraints.
; ============================================================================
program_palette:
    cli
    mov al, OPEN_ENTRY2     ; open at entry 2 (byte offset 4)
    out PORT_DD, al
    jmp short $+2

    ; Entry 2: col 1 even, step 0
    mov bx, grad_col1
    call write_entry_pair   ; writes entries 2 (even) and 3 (odd/darkened)

    ; Entry 4: col 2 even, step 0
    mov bx, grad_col2
    call write_entry_pair   ; writes entries 4 (even) and 5 (odd/darkened)

    ; Entry 6: col 3 even, step 0
    mov bx, grad_col3
    call write_entry_pair   ; writes entries 6 (even) and 7 (odd/darkened)

    mov al, CLOSE_PAL
    out PORT_DD, al
    sti
    ret

; ============================================================================
; write_entry_pair — Write even + odd (darkened) entry pair during init
; ============================================================================
; Input: BX = pointer to gradient source (2 bytes: R, GB)
; Writes 4 bytes to port 0xDE: even_R, even_GB, odd_R, odd_GB
; ============================================================================
write_entry_pair:
    ; Even entry (full brightness)
    mov al, [bx]
    out PORT_DE, al
    jmp short $+2
    mov al, [bx+1]
    out PORT_DE, al
    jmp short $+2
    ; Odd entry (darkened by 1 per channel)
    mov al, [bx]
    call darken_r
    out PORT_DE, al
    jmp short $+2
    mov al, [bx+1]
    call darken_gb
    out PORT_DE, al
    jmp short $+2
    ret

; ============================================================================
; fill_screen_columns — Fill VRAM with 3 vertical columns
; ============================================================================
; Column 1 (pixel value 1 = 0x55): 108 pixels = 27 bytes
; Column 2 (pixel value 2 = 0xAA): 104 pixels = 26 bytes
; Column 3 (pixel value 3 = 0xFF): 108 pixels = 27 bytes
; Total: 27 + 26 + 27 = 80 bytes per row ✓
; ============================================================================
fill_screen_columns:
    push es
    mov ax, VIDEO_SEG
    mov es, ax
    xor bx, bx             ; bank offset (0 then 0x2000)

.fill_bank:
    xor di, di
    add di, bx
    mov cx, 100             ; 100 rows per CGA bank

.fill_row:
    push cx
    push di

    ; Column 1: pixel value 1 (0x55 = 01 01 01 01)
    mov al, 0x55
    mov cx, 27
    cld
    rep stosb

    ; Column 2: pixel value 2 (0xAA = 10 10 10 10)
    mov al, 0xAA
    mov cx, 26
    rep stosb

    ; Column 3: pixel value 3 (0xFF = 11 11 11 11)
    mov al, 0xFF
    mov cx, 27
    rep stosb

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
; render_frame — Per-scanline palette flip + entry 2 gradient
; ============================================================================
; Uses the cgaflip3 proven approach: open at entry 0 (0x40), stream
; zeros through entries 0-1, write entry 2 gradient color, close.
;
; 9 OUTs per HBLANK (~72 cycles, fits in ~80 cycle HBLANK on V40):
;   OUT 0xD9  → palette flip
;   OUT 0xDD  → 0x40 (open at entry 0)
;   OUT 0xDE  → 0 (entry 0 R — keep black)
;   OUT 0xDE  → 0 (entry 0 GB — keep black)
;   OUT 0xDE  → 0 (entry 1 R — unused, stream through)
;   OUT 0xDE  → 0 (entry 1 GB — unused, stream through)
;   OUT 0xDE  → R (entry 2 gradient color)
;   OUT 0xDE  → GB (entry 2 gradient color)
;   OUT 0xDD  → 0x80 (close)
;
; Reads gradient_buffer: 200 entries × 3 bytes [palette_val, R, GB]
; ============================================================================
render_frame:
    cli
    cld
    mov si, gradient_buffer

    cmp byte [hsync_enabled], 0
    je .no_hsync_loop

    ; ------------------------------------------------------------------
    ; HSYNC-synced loop — 200 scanlines
    ; ------------------------------------------------------------------
    mov cx, SCREEN_HEIGHT

.next_line:
    ; Wait for HSYNC: low → high transition
.wait_low:
    in al, PORT_DA
    test al, 0x01
    jnz .wait_low
.wait_high:
    in al, PORT_DA
    test al, 0x01
    jz .wait_high

    ; === Critical HBLANK section — 9 OUTs ===

    lodsb                       ; AL = palette_val (0x00 or 0x20)
    out PORT_D9, al             ; flip palette

    mov al, OPEN_ENTRY0
    out PORT_DD, al             ; open write at entry 0

    xor al, al
    out PORT_DE, al             ; entry 0 R = 0 (black)
    out PORT_DE, al             ; entry 0 GB = 0 (black)
    out PORT_DE, al             ; entry 1 R = 0 (unused)
    out PORT_DE, al             ; entry 1 GB = 0 (unused)

    lodsb                       ; AL = entry 2 R value
    out PORT_DE, al             ; entry 2 R
    lodsb                       ; AL = entry 2 GB value
    out PORT_DE, al             ; entry 2 GB

    mov al, CLOSE_PAL
    out PORT_DD, al             ; close palette write

    ; === End critical section ===

    loop .next_line
    jmp short .done_render

    ; ------------------------------------------------------------------
    ; Non-synchronized loop (for testing without HSYNC)
    ; ------------------------------------------------------------------
.no_hsync_loop:
    mov cx, SCREEN_HEIGHT

.no_sync_line:
    lodsb
    out PORT_D9, al
    mov al, OPEN_ENTRY0
    out PORT_DD, al
    xor al, al
    out PORT_DE, al
    out PORT_DE, al
    out PORT_DE, al
    out PORT_DE, al
    lodsb
    out PORT_DE, al
    lodsb
    out PORT_DE, al
    mov al, CLOSE_PAL
    out PORT_DD, al

    push cx
    mov cx, 30
.delay:
    loop .delay
    pop cx

    loop .no_sync_line

.done_render:
    ; Reset to palette 0 for clean state
    mov al, PAL_EVEN
    out PORT_D9, al

    sti
    ret

; ============================================================================
; wait_vblank — Wait for vertical blanking interval
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
; check_keyboard — Handle input (ESC, H, V)
; ============================================================================
check_keyboard:
    mov ah, 0x01
    int 0x16
    jz .no_key
    mov ah, 0x00
    int 0x16

    cmp ah, 0x01                ; ESC
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
; GRADIENT SOURCE TABLES — 34 entries × 2 bytes each (R, G<<4|B)
; ============================================================================
;
; These define the EVEN line colors for each column. The build routine
; creates darkened ODD variants automatically (each channel -1, min 0).
;
; V6355D RGB333: byte1 = R (0-7), byte2 = (G << 4) | B
;
; ============================================================================

; Column 1: Full rainbow hue rotation
; Red → Orange → Yellow → Green → Cyan → Blue → Purple → Magenta
grad_col1:
    db 0x07, 0x00       ; Step  0: R=7 G=0 B=0  Red
    db 0x07, 0x10       ; Step  1: R=7 G=1 B=0
    db 0x07, 0x20       ; Step  2: R=7 G=2 B=0  Orange
    db 0x07, 0x30       ; Step  3: R=7 G=3 B=0
    db 0x07, 0x40       ; Step  4: R=7 G=4 B=0  Orange-Yellow
    db 0x07, 0x50       ; Step  5: R=7 G=5 B=0
    db 0x07, 0x70       ; Step  6: R=7 G=7 B=0  Yellow
    db 0x06, 0x70       ; Step  7: R=6 G=7 B=0
    db 0x05, 0x70       ; Step  8: R=5 G=7 B=0  Yellow-Green
    db 0x04, 0x70       ; Step  9: R=4 G=7 B=0
    db 0x03, 0x70       ; Step 10: R=3 G=7 B=0  Green
    db 0x02, 0x70       ; Step 11: R=2 G=7 B=0
    db 0x00, 0x70       ; Step 12: R=0 G=7 B=0  Pure Green
    db 0x00, 0x71       ; Step 13: R=0 G=7 B=1
    db 0x00, 0x72       ; Step 14: R=0 G=7 B=2  Teal
    db 0x00, 0x73       ; Step 15: R=0 G=7 B=3
    db 0x00, 0x75       ; Step 16: R=0 G=7 B=5  Blue-Teal
    db 0x00, 0x77       ; Step 17: R=0 G=7 B=7  Cyan
    db 0x00, 0x67       ; Step 18: R=0 G=6 B=7
    db 0x00, 0x57       ; Step 19: R=0 G=5 B=7  Blue-Cyan
    db 0x00, 0x47       ; Step 20: R=0 G=4 B=7
    db 0x00, 0x37       ; Step 21: R=0 G=3 B=7  Blue
    db 0x00, 0x27       ; Step 22: R=0 G=2 B=7
    db 0x00, 0x17       ; Step 23: R=0 G=1 B=7  Deep Blue
    db 0x00, 0x07       ; Step 24: R=0 G=0 B=7  Pure Blue
    db 0x01, 0x07       ; Step 25: R=1 G=0 B=7
    db 0x02, 0x07       ; Step 26: R=2 G=0 B=7  Indigo
    db 0x03, 0x07       ; Step 27: R=3 G=0 B=7
    db 0x04, 0x07       ; Step 28: R=4 G=0 B=7  Purple
    db 0x05, 0x07       ; Step 29: R=5 G=0 B=7
    db 0x05, 0x06       ; Step 30: R=5 G=0 B=6  Purple-Magenta
    db 0x06, 0x05       ; Step 31: R=6 G=0 B=5
    db 0x07, 0x04       ; Step 32: R=7 G=0 B=4  Red-Magenta
    db 0x07, 0x02       ; Step 33: R=7 G=0 B=2  Back toward Red

; Column 2: Blue spectrum — Dark Blue → Blue → Cyan → White
grad_col2:
    db 0x00, 0x02       ; Step  0: R=0 G=0 B=2  Very Dark Blue
    db 0x00, 0x03       ; Step  1: R=0 G=0 B=3
    db 0x00, 0x04       ; Step  2: R=0 G=0 B=4  Navy
    db 0x00, 0x05       ; Step  3: R=0 G=0 B=5
    db 0x00, 0x06       ; Step  4: R=0 G=0 B=6  Medium Blue
    db 0x00, 0x07       ; Step  5: R=0 G=0 B=7  Bright Blue
    db 0x00, 0x17       ; Step  6: R=0 G=1 B=7
    db 0x00, 0x27       ; Step  7: R=0 G=2 B=7  Blue
    db 0x00, 0x37       ; Step  8: R=0 G=3 B=7
    db 0x00, 0x47       ; Step  9: R=0 G=4 B=7  Teal Blue
    db 0x00, 0x57       ; Step 10: R=0 G=5 B=7
    db 0x00, 0x67       ; Step 11: R=0 G=6 B=7  Light Cyan
    db 0x00, 0x77       ; Step 12: R=0 G=7 B=7  Cyan
    db 0x01, 0x77       ; Step 13: R=1 G=7 B=7
    db 0x02, 0x77       ; Step 14: R=2 G=7 B=7  Pale Cyan
    db 0x03, 0x77       ; Step 15: R=3 G=7 B=7
    db 0x04, 0x77       ; Step 16: R=4 G=7 B=7  Pale Blue
    db 0x05, 0x77       ; Step 17: R=5 G=7 B=7
    db 0x06, 0x77       ; Step 18: R=6 G=7 B=7  Near White
    db 0x07, 0x77       ; Step 19: R=7 G=7 B=7  White
    db 0x07, 0x76       ; Step 20: R=7 G=7 B=6
    db 0x07, 0x66       ; Step 21: R=7 G=6 B=6  Warm White
    db 0x07, 0x65       ; Step 22: R=7 G=6 B=5
    db 0x07, 0x54       ; Step 23: R=7 G=5 B=4  Peach
    db 0x07, 0x53       ; Step 24: R=7 G=5 B=3
    db 0x07, 0x42       ; Step 25: R=7 G=4 B=2  Warm Orange
    db 0x07, 0x31       ; Step 26: R=7 G=3 B=1
    db 0x07, 0x30       ; Step 27: R=7 G=3 B=0  Orange
    db 0x06, 0x20       ; Step 28: R=6 G=2 B=0
    db 0x05, 0x20       ; Step 29: R=5 G=2 B=0  Brown
    db 0x05, 0x10       ; Step 30: R=5 G=1 B=0
    db 0x04, 0x10       ; Step 31: R=4 G=1 B=0  Dark Brown
    db 0x03, 0x10       ; Step 32: R=3 G=1 B=0
    db 0x02, 0x00       ; Step 33: R=2 G=0 B=0  Very Dark

; Column 3: Purple/Magenta fade — Magenta → Red → Brown → Black
grad_col3:
    db 0x07, 0x07       ; Step  0: R=7 G=0 B=7  Bright Magenta
    db 0x07, 0x06       ; Step  1: R=7 G=0 B=6
    db 0x07, 0x16       ; Step  2: R=7 G=1 B=6  Pink
    db 0x07, 0x15       ; Step  3: R=7 G=1 B=5
    db 0x07, 0x25       ; Step  4: R=7 G=2 B=5
    db 0x07, 0x24       ; Step  5: R=7 G=2 B=4  Soft Pink
    db 0x07, 0x23       ; Step  6: R=7 G=2 B=3
    db 0x07, 0x12       ; Step  7: R=7 G=1 B=2
    db 0x07, 0x11       ; Step  8: R=7 G=1 B=1  Rose
    db 0x07, 0x00       ; Step  9: R=7 G=0 B=0  Red
    db 0x07, 0x10       ; Step 10: R=7 G=1 B=0
    db 0x06, 0x20       ; Step 11: R=6 G=2 B=0  Dark Orange
    db 0x06, 0x10       ; Step 12: R=6 G=1 B=0
    db 0x05, 0x20       ; Step 13: R=5 G=2 B=0  Brown
    db 0x05, 0x10       ; Step 14: R=5 G=1 B=0
    db 0x04, 0x20       ; Step 15: R=4 G=2 B=0
    db 0x04, 0x10       ; Step 16: R=4 G=1 B=0  Dark Brown
    db 0x03, 0x10       ; Step 17: R=3 G=1 B=0
    db 0x03, 0x10       ; Step 18: R=3 G=1 B=0
    db 0x03, 0x00       ; Step 19: R=3 G=0 B=0  Very Dark Red
    db 0x02, 0x10       ; Step 20: R=2 G=1 B=0
    db 0x02, 0x00       ; Step 21: R=2 G=0 B=0
    db 0x02, 0x00       ; Step 22: R=2 G=0 B=0
    db 0x01, 0x00       ; Step 23: R=1 G=0 B=0  Near Black
    db 0x01, 0x00       ; Step 24: R=1 G=0 B=0
    db 0x01, 0x00       ; Step 25: R=1 G=0 B=0
    db 0x01, 0x00       ; Step 26: R=1 G=0 B=0
    db 0x00, 0x00       ; Step 27: R=0 G=0 B=0  Black
    db 0x00, 0x00       ; Step 28
    db 0x00, 0x00       ; Step 29
    db 0x00, 0x00       ; Step 30
    db 0x00, 0x00       ; Step 31
    db 0x00, 0x00       ; Step 32
    db 0x00, 0x00       ; Step 33

; ============================================================================
; GRADIENT BUFFER — Precomputed at runtime by build_gradient_buffer
; ============================================================================
; 200 entries × 3 bytes = 600 bytes
; Lives in uninitialized memory above the loaded code.
; Format per entry: [palette_val, R_val, GB_val]
; ============================================================================
gradient_buffer:
