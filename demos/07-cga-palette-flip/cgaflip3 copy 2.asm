; ============================================================================
; CGAFLIP3.ASM - CGA Palette Flip + Per-Scanline Entry 2 Rainbow Gradient
; ============================================================================
;
; DEMONSTRATION: Combines TWO techniques in 320x200x4 CGA mode:
;
;   1. PALETTE FLIP via port 0xD9 — alternates CGA palette 0/1 per scanline
;      (foreground colors change between even/odd lines)
;
;   2. PALETTE RAM REPROGRAMMING via 0xDD/0xDE — changes entry 2's RGB333
;      color every scanline during HBLANK (rainbow gradient in band 1)
;
; Both happen in a single HBLANK (~80 cycles): 9 OUTs total.
;
; Written for NASM assembler
; Target: Olivetti Prodest PC1 with Yamaha V6355D video controller
; CPU: NEC V40 (80186 compatible) @ 8 MHz
;
; By Retro Erik - 2026
;
; ============================================================================
; WHAT YOU SHOULD SEE
; ============================================================================
;
; 4 vertical bands, left to right:
;
;   BAND 0 (pixel value 0 = background/border):
;     ALL lines → entry 0 = Black (selected by 0xD9 bits 3-0 = 0)
;     Border also uses entry 0 → solid black border!
;
;   BAND 1 (pixel value 1):
;     Even lines → entry 2 = RAINBOW GRADIENT (changes per line!)
;     Odd  lines → entry 3 = Deep Blue
;     → Alternating gradient/blue horizontal stripes
;
;   BAND 2 (pixel value 2):
;     Even lines → entry 4 = Bright Green
;     Odd  lines → entry 5 = Orange
;     → Alternating green/orange horizontal stripes
;
;   BAND 3 (pixel value 3):
;     Even lines → entry 6 = Yellow
;     Odd  lines → entry 7 = White
;     → Alternating yellow/white horizontal stripes
;
; BORDER: Solid black on all lines.
;   On CGA, 0xD9 bits 3-0 select the entry for BOTH pixel-value-0
;   AND the border. They cannot differ. Both palettes use entry 0
;   (black) so border is always black.
;
; ============================================================================
; THE TECHNIQUE (per scanline, during HBLANK)
; ============================================================================
;
;   OUT 0xD9  → palette flip (bit 5) + bg/border index (bits 3-0 = 0)
;   OUT 0xDD  → 0x40 (open palette write at entry 0)
;   OUT 0xDE  → entry 0 R = 0 (black, keep stable)
;   OUT 0xDE  → entry 0 G|B = 0 (black)
;   OUT 0xDE  → entry 1 R = 0 (unused entry, stream-through)
;   OUT 0xDE  → entry 1 G|B = 0 (unused entry, stream-through)
;   OUT 0xDE  → entry 2 R from gradient table
;   OUT 0xDE  → entry 2 G|B from gradient table
;   OUT 0xDD  → 0x80 (close palette write)
;
;   Total: 9 OUT instructions — tight but should fit on V40 @ 8 MHz
;
; ============================================================================
; 0xD9 COLOR SELECT REGISTER
; ============================================================================
;
;   Bit 5:   Palette select (0 = palette 0, 1 = palette 1)
;   Bit 4:   Intensity (0 = normal)
;   Bits 3-0: Background/border color index
;
;   Even lines: 0x00 → palette 0, bg/border = entry 0 (black)
;   Odd  lines: 0x20 → palette 1, bg/border = entry 0 (black)
;
;   Pixel  │ Even (pal 0)  │ Odd (pal 1)
;   ───────┼───────────────┼──────────────
;     0    │ entry 0 (bg)  │ entry 0 (bg)    ← both black
;     1    │ entry 2 ★     │ entry 3
;     2    │ entry 4       │ entry 5
;     3    │ entry 6       │ entry 7
;                ★ = gradient (reprogrammed per scanline)
;
; ============================================================================
; LESSONS LEARNED (verified on real PC1 hardware, February 2026)
; ============================================================================
;
; 1. PORT 0xD9 BIT 5 controls palette select on V6355D (VERIFIED WORKING).
;    Port 0xD8 bit 5 does NOT — despite what some docs claim (section 14).
;
; 2. PIXEL VALUE 0 AND BORDER share the same source: 0xD9 bits 3-0.
;    These 4 bits select which V6355D palette entry is used for BOTH:
;      - All pixels with framebuffer value 0 (the "background color")
;      - The overscan border area
;    This is a hardwired CGA rule, not a PC1 quirk. It applies equally
;    to IBM CGA, Tandy, PCjr, and the V6355D.
;
; 3. YOU CANNOT independently set "color 0" for palette A vs palette B.
;    0xD9 bits 3-0 apply to BOTH palette 0 and palette 1. If you change
;    them per scanline (e.g. 0x00 on even, 0x21 on odd), the border
;    flickers between those two entries — there's no way to avoid it.
;
; 4. PALETTE RAM ENTRIES and 0xD9 are SEPARATE hardware paths:
;    - Palette RAM entries (0xDD/0xDE) define the RGB333 colors
;    - 0xD9 bits 3-0 select WHICH entry pixel-value-0/border uses
;    - 0xD9 bit 5 selects WHICH palette set (0 or 1) for pixel values 1-3
;
; 5. V6355D palette writes STREAM SEQUENTIALLY from entry 0.
;    Command 0x40 always opens at entry 0. To change entry N, you must
;    write 2×N dummy bytes for entries 0 through N-1 first.
;    No random-access to individual entries.
;
; 6. CLEAN BORDER requires: both PAL_EVEN and PAL_ODD point to the
;    same entry (here entry 0 = black). The gradient goes on entry 2
;    (pixel value 1, palette 0) which has no effect on the border.
;
; 7. TIMING: 9 OUTs per HBLANK is tight but works on V40 @ 8 MHz.
;    The ~80 cycle HBLANK budget allows roughly 10 short-form OUTs.
;    Using short port aliases (0xD9 not 0x3D9) saves ~4 cycles each.
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
; Port Definitions — short aliases (saves ~4 cycles/OUT on V40)
; ============================================================================

PORT_D9         equ 0xD9    ; Color Select Register
PORT_DA         equ 0xDA    ; Status Register (bit 0=HSYNC, bit 3=VSYNC)
PORT_DD         equ 0xDD    ; V6355D Palette/Register Address
PORT_DE         equ 0xDE    ; V6355D Palette/Register Data

; ============================================================================
; Video Constants
; ============================================================================

VIDEO_SEG       equ 0xB800
SCREEN_HEIGHT   equ 200
BYTES_PER_ROW   equ 80

; ============================================================================
; 0xD9 flip values — both use entry 0 for bg/border (black)
; ============================================================================

PAL_EVEN        equ 0x00   ; palette 0, bg/border = entry 0 (black)
PAL_ODD         equ 0x20   ; palette 1, bg/border = entry 0 (black)

; ============================================================================
; MAIN PROGRAM
; ============================================================================
main:
    mov byte [hsync_enabled], 1
    mov byte [vsync_enabled], 1

    ; Set CGA 320x200x4 mode
    mov ax, 0x0004
    int 0x10

    ; Program V6355D palette entries 0-7
    call program_palette

    ; Fill screen with 4 vertical bands (pixel values 0-3)
    call fill_screen_bands

.main_loop:
    call wait_vblank
    call render_frame
    call check_keyboard
    cmp al, 0xFF
    jne .main_loop

    ; ------------------------------------------------------------------
    ; Exit: reset palette entry 0 to black, restore text mode
    ; ------------------------------------------------------------------
    mov al, 0x40
    out PORT_DD, al
    xor al, al
    out PORT_DE, al
    out PORT_DE, al
    mov al, 0x80
    out PORT_DD, al

    mov ax, 0x0003
    int 0x10
    mov ax, 0x4C00
    int 0x21

; ============================================================================
; program_palette - Write 8 RGB333 entries to V6355D palette RAM
; ============================================================================
program_palette:
    cli

    mov al, 0x40
    out PORT_DD, al
    jmp short $+2

    mov si, palette_data
    mov cx, 16              ; 8 entries × 2 bytes (entries 0-7)
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
; fill_screen_bands - Draw 4 vertical bands using pixel values 0-3
; ============================================================================
fill_screen_bands:
    push es
    mov ax, VIDEO_SEG
    mov es, ax
    xor bx, bx             ; Bank base

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
; render_frame - Per-scanline palette flip + entry 2 gradient
; ============================================================================
; Each HBLANK does 9 OUTs:
;   1. OUT 0xD9  = palette flip + bg/border = entry 0
;   2. OUT 0xDD  = 0x40 (open palette write at entry 0)
;   3. OUT 0xDE  = entry 0 R = 0 (black)
;   4. OUT 0xDE  = entry 0 G|B = 0 (black)
;   5. OUT 0xDE  = entry 1 R = 0 (unused, stream-through)
;   6. OUT 0xDE  = entry 1 G|B = 0 (unused, stream-through)
;   7. OUT 0xDE  = entry 2 R (from gradient table)
;   8. OUT 0xDE  = entry 2 G|B (from gradient table)
;   9. OUT 0xDD  = 0x80 (close palette write)
; ============================================================================
render_frame:
    cli

    mov si, gradient_data
    mov cx, SCREEN_HEIGHT
    mov bl, PAL_EVEN        ; First line = even (0x00)
    mov bh, PAL_ODD         ; Next line = odd (0x21)

    cmp byte [hsync_enabled], 0
    je .no_hsync_loop

    ; ------------------------------------------------------------------
    ; HSYNC-synchronized loop
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

    ; --- HBLANK: 9 OUTs (tight on V40 @ 8MHz) ---
    mov al, bl
    out PORT_D9, al         ; 1. Palette flip + bg/border=0

    mov al, 0x40
    out PORT_DD, al         ; 2. Open palette at entry 0

    xor al, al
    out PORT_DE, al         ; 3. Entry 0 R = 0 (black)
    out PORT_DE, al         ; 4. Entry 0 G|B = 0 (black)
    out PORT_DE, al         ; 5. Entry 1 R = 0 (unused)
    out PORT_DE, al         ; 6. Entry 1 G|B = 0 (unused)

    lodsb
    out PORT_DE, al         ; 7. Entry 2 R (gradient)

    lodsb
    out PORT_DE, al         ; 8. Entry 2 G|B (gradient)

    mov al, 0x80
    out PORT_DD, al         ; 9. Close palette

    ; Swap even/odd for next line
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
    xor al, al
    out PORT_DE, al
    out PORT_DE, al
    out PORT_DE, al
    out PORT_DE, al
    lodsb
    out PORT_DE, al
    lodsb
    out PORT_DE, al
    mov al, 0x80
    out PORT_DD, al
    xchg bl, bh
    loop .no_sync_line

.done_render:
    ; Reset: palette 0, bg=0, entries 0-2 = black/original
    mov al, PAL_EVEN
    out PORT_D9, al
    mov al, 0x40
    out PORT_DD, al
    xor al, al
    out PORT_DE, al         ; entry 0 R
    out PORT_DE, al         ; entry 0 GB
    out PORT_DE, al         ; entry 1 R
    out PORT_DE, al         ; entry 1 GB
    ; Restore entry 2 to initial red
    mov al, 0x07
    out PORT_DE, al         ; entry 2 R=7
    xor al, al
    out PORT_DE, al         ; entry 2 GB=0
    mov al, 0x80
    out PORT_DD, al

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
; V6355D Palette — 8 entries (RGB333)
; ============================================================================
;
; Entry │ Role              │ Color         │  R   G   B
; ──────┼───────────────────┼───────────────┼───────────
;   0   │ bg/border (both)  │ Black         │  0   0   0
;   1   │ (unused)          │ Black         │  0   0   0
;   2   │ px1 even (pal 0)  │ Red (init)    │  7   0   0  ★ gradient
;   3   │ px1 odd  (pal 1)  │ Deep Blue     │  0   0   7
;   4   │ px2 even (pal 0)  │ Bright Green  │  0   7   0
;   5   │ px2 odd  (pal 1)  │ Orange        │  7   4   0
;   6   │ px3 even (pal 0)  │ Bright Yellow │  7   7   0
;   7   │ px3 odd  (pal 1)  │ Bright White  │  7   7   7

palette_data:
    db 0x00, 0x00           ; 0: Black       (bg/border, both palettes)
    db 0x00, 0x00           ; 1: Black       (unused — streamed through)
    db 0x07, 0x00           ; 2: Red init    (overwritten by gradient)
    db 0x00, 0x07           ; 3: Deep Blue   (R=0, G=0, B=7)
    db 0x00, 0x70           ; 4: Green       (R=0, G=7, B=0)
    db 0x07, 0x40           ; 5: Orange      (R=7, G=4, B=0)
    db 0x07, 0x70           ; 6: Yellow      (R=7, G=7, B=0)
    db 0x07, 0x77           ; 7: White       (R=7, G=7, B=7)

; ============================================================================
; Gradient data — 200 entries × 2 bytes = 400 bytes
; ============================================================================
; Full spectrum rainbow: R → Y → G → C → B → M → R
; Entry 2 is reprogrammed to these values per scanline during HBLANK.
; Even lines display entry 2 (pixel value 1, palette 0).
; Odd lines display entry 3 (deep blue, palette 1) — not the gradient.
; Gradient visible on 100 even lines; blue on 100 odd lines.

gradient_data:
    ; RED to YELLOW (33 lines: R=7, G increases 0→7)
    db 7,0x00, 7,0x00, 7,0x00, 7,0x00, 7,0x10, 7,0x10, 7,0x10, 7,0x10
    db 7,0x20, 7,0x20, 7,0x20, 7,0x20, 7,0x30, 7,0x30, 7,0x30, 7,0x30
    db 7,0x40, 7,0x40, 7,0x40, 7,0x40, 7,0x50, 7,0x50, 7,0x50, 7,0x50
    db 7,0x60, 7,0x60, 7,0x60, 7,0x60, 7,0x70, 7,0x70, 7,0x70, 7,0x70
    db 7,0x70

    ; YELLOW to GREEN (33 lines: R decreases 7→0, G=7)
    db 7,0x70, 7,0x70, 7,0x70, 7,0x70, 6,0x70, 6,0x70, 6,0x70, 6,0x70
    db 5,0x70, 5,0x70, 5,0x70, 5,0x70, 4,0x70, 4,0x70, 4,0x70, 4,0x70
    db 3,0x70, 3,0x70, 3,0x70, 3,0x70, 2,0x70, 2,0x70, 2,0x70, 2,0x70
    db 1,0x70, 1,0x70, 1,0x70, 1,0x70, 0,0x70, 0,0x70, 0,0x70, 0,0x70
    db 0,0x70

    ; GREEN to CYAN (33 lines: G=7, B increases 0→7)
    db 0,0x70, 0,0x70, 0,0x70, 0,0x70, 0,0x71, 0,0x71, 0,0x71, 0,0x71
    db 0,0x72, 0,0x72, 0,0x72, 0,0x72, 0,0x73, 0,0x73, 0,0x73, 0,0x73
    db 0,0x74, 0,0x74, 0,0x74, 0,0x74, 0,0x75, 0,0x75, 0,0x75, 0,0x75
    db 0,0x76, 0,0x76, 0,0x76, 0,0x76, 0,0x77, 0,0x77, 0,0x77, 0,0x77
    db 0,0x77

    ; CYAN to BLUE (33 lines: G decreases 7→0, B=7)
    db 0,0x77, 0,0x77, 0,0x77, 0,0x77, 0,0x67, 0,0x67, 0,0x67, 0,0x67
    db 0,0x57, 0,0x57, 0,0x57, 0,0x57, 0,0x47, 0,0x47, 0,0x47, 0,0x47
    db 0,0x37, 0,0x37, 0,0x37, 0,0x37, 0,0x27, 0,0x27, 0,0x27, 0,0x27
    db 0,0x17, 0,0x17, 0,0x17, 0,0x17, 0,0x07, 0,0x07, 0,0x07, 0,0x07
    db 0,0x07

    ; BLUE to MAGENTA (34 lines: R increases 0→7, B=7)
    db 0,0x07, 0,0x07, 0,0x07, 0,0x07, 1,0x07, 1,0x07, 1,0x07, 1,0x07
    db 2,0x07, 2,0x07, 2,0x07, 2,0x07, 3,0x07, 3,0x07, 3,0x07, 3,0x07
    db 4,0x07, 4,0x07, 4,0x07, 4,0x07, 5,0x07, 5,0x07, 5,0x07, 5,0x07
    db 6,0x07, 6,0x07, 6,0x07, 6,0x07, 7,0x07, 7,0x07, 7,0x07, 7,0x07
    db 7,0x07, 7,0x07

    ; MAGENTA to RED (34 lines: B decreases 7→0, R=7)
    db 7,0x07, 7,0x07, 7,0x07, 7,0x07, 7,0x06, 7,0x06, 7,0x06, 7,0x06
    db 7,0x05, 7,0x05, 7,0x05, 7,0x05, 7,0x04, 7,0x04, 7,0x04, 7,0x04
    db 7,0x03, 7,0x03, 7,0x03, 7,0x03, 7,0x02, 7,0x02, 7,0x02, 7,0x02
    db 7,0x01, 7,0x01, 7,0x01, 7,0x01, 7,0x00, 7,0x00, 7,0x00, 7,0x00
    db 7,0x00, 7,0x00

; ============================================================================
; END OF PROGRAM
; ============================================================================
