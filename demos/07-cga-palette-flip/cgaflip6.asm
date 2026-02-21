; ============================================================================
; CGAFLIP6.ASM - "Sunset Gradient" — Visual Palette Flip Showcase
; ============================================================================
;
; Part 5 of 8 — Row-dithered VRAM + flip = 7 perceived colors. No HBLANK streaming.
;   Next: cgaflip7 adds per-scanline E2 updates for 3 independent gradient columns.
;
; DEMONSTRATION: Shows why CGA palette flipping is exciting.
;
;   By alternating two palettes EVERY SCANLINE, the eye blends adjacent
;   colors together — perceiving MORE colors than either palette alone.
;   Combined with row-dithered VRAM (different pixel values in even/odd
;   banks), this demo produces a smooth 7-step sunset gradient from
;   just 4 CGA pixel values and 6 palette entries.
;
;   Standard CGA mode 4: 4 colors on screen
;   This demo:           7+ perceived colors, zero flicker
;
; TECHNIQUE:
;   - 1 OUT to port 0xD9 per HBLANK (alternating palette 0 / palette 1)
;   - NO palette RAM streaming during visible area (proven unstable)
;   - All 8 palette entries set once during VBLANK via 0xDD/0xDE
;   - VRAM uses row-dithering: bank 0 and bank 1 hold different pixel
;     values in transition zones, creating per-scanline color mixing
;
; Written for NASM assembler
; Target: Olivetti Prodest PC1 with Yamaha V6355D video controller
; CPU: NEC V40 (80186 compatible) @ 8 MHz
;
; By Retro Erik - 2026
;
; ============================================================================
; HOW IT WORKS — THE "VIRTUAL COLOR" TRICK
; ============================================================================
;
; CGA palette mapping with bg = entry 0:
;
;   Pixel  │ Even lines (pal 0) │ Odd lines (pal 1)
;   ───────┼────────────────────┼───────────────────
;     0    │ entry 0 (black)    │ entry 0 (black)
;     1    │ entry 2 (crimson)  │ entry 3 (amber)
;     2    │ entry 4 (purple)   │ entry 5 (lilac)
;     3    │ entry 6 (gold)     │ entry 7 (cream)
;
; When both banks have the SAME pixel value, the eye blends the two
; palette entries for that pixel (e.g. purple + lilac = vivid purple).
;
; When banks have DIFFERENT pixel values (dithered transition zones),
; the eye blends entries from DIFFERENT pixel mappings (e.g. purple
; from px 2 on even lines + cream from px 3 on odd lines = mauve).
;
; This creates "virtual colors" that don't exist in either palette!
;
; ============================================================================
; WHAT YOU SHOULD SEE — SUNSET GRADIENT (top to bottom)
; ============================================================================
;
;   Zone 1 (rows 0-33):    DEEP PURPLE SKY
;     Even lines: px 2, pal 0 → entry 4 (deep purple)
;     Odd lines:  px 2, pal 1 → entry 5 (lilac)
;     Perceived: vivid purple — the deep sky at dusk
;
;   Zone 2 (rows 34-67):   MAUVE TRANSITION
;     Even lines: px 2, pal 0 → entry 4 (deep purple)
;     Odd lines:  px 3, pal 1 → entry 7 (warm cream)
;     Perceived: dusty mauve — a color NEITHER palette can show alone!
;
;   Zone 3 (rows 68-99):   GOLDEN HORIZON
;     Even lines: px 3, pal 0 → entry 6 (golden yellow)
;     Odd lines:  px 3, pal 1 → entry 7 (warm cream)
;     Perceived: rich gold — the warm glow of the setting sun
;
;   Zone 4 (rows 100-133): BRIGHT ORANGE
;     Even lines: px 3, pal 0 → entry 6 (golden yellow)
;     Odd lines:  px 1, pal 1 → entry 3 (amber)
;     Perceived: vivid orange — another "impossible" virtual color!
;
;   Zone 5 (rows 134-167): SUNSET RED-ORANGE
;     Even lines: px 1, pal 0 → entry 2 (crimson)
;     Odd lines:  px 1, pal 1 → entry 3 (amber)
;     Perceived: warm red-orange — the lower sky ablaze
;
;   Zone 6 (rows 168-199): DARK BURGUNDY FADE
;     Even lines: px 1, pal 0 → entry 2 (crimson)
;     Odd lines:  px 0, pal 1 → entry 0 (black)
;     Perceived: dark burgundy — fading into night
;
; TOTAL: 6 distinct perceived colors + black = 7 visual tones
;         from a 4-color CGA mode. No flicker. No streaming.
;
; ============================================================================
; VRAM LAYOUT — ROW-DITHERING VIA CGA INTERLACING
; ============================================================================
;
; CGA interlaced memory makes row-dithering trivially easy:
;   Bank 0 (offset 0x0000) = even visual rows (0, 2, 4, ...)
;   Bank 1 (offset 0x2000) = odd visual rows  (1, 3, 5, ...)
;
; By filling each bank with DIFFERENT pixel values in transition zones,
; every adjacent scanline pair shows a different pixel value — creating
; per-scanline dithering with zero runtime cost.
;
; Bank 0 (even rows):          Bank 1 (odd rows):
;   Rows 0-33:  px 2 (0xAA)     Rows 0-16:  px 2 (0xAA)  ← same
;   (same as above)              Rows 17-49: px 3 (0xFF)  ← DIFFERENT!
;   Rows 34-66: px 3 (0xFF)     (same as above)
;   (same as above)              Rows 50-83: px 1 (0x55)  ← DIFFERENT!
;   Rows 67-99: px 1 (0x55)     (same as above)
;   (same as above)              Rows 84-99: px 0 (0x00)  ← DIFFERENT!
;
; The offset between banks creates the transition zones automatically.
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
WORDS_PER_ROW   equ 40

; Both palettes use entry 0 for bg/border = black (no border flicker!)
PAL_EVEN        equ 0x00       ; palette 0, bg/border = entry 0
PAL_ODD         equ 0x20       ; palette 1, bg/border = entry 0

; ============================================================================
; MAIN PROGRAM
; ============================================================================
main:
    mov byte [hsync_enabled], 1
    mov byte [vsync_enabled], 1

    mov ax, 0x0004              ; CGA 320x200x4 mode
    int 0x10

    call program_palette        ; Set sunset palette (during first VBLANK)
    call fill_screen_gradient   ; Fill VRAM with row-dithered gradient

.main_loop:
    call wait_vblank
    call render_frame           ; Palette flip every scanline
    call check_keyboard
    cmp al, 0xFF
    jne .main_loop

    ; Exit: restore text mode
    mov ax, 0x0003
    int 0x10
    mov ax, 0x4C00
    int 0x21

; ============================================================================
; program_palette — Write sunset palette entries 2-7
; ============================================================================
; Entries 0-1 are left at power-on defaults (black).
; Entry 0 = background/border (always black).
; Entry 1 = unused (no pixel value maps to it when bg = entry 0).
;
; We start the palette write at byte offset 4 (entry 2) using 0x44,
; then stream 12 bytes (entries 2-7, 2 bytes each) via REP OUTSB.
; ============================================================================
program_palette:
    cli
    mov al, 0x44                ; 0x40 | 0x04 = open write at entry 2
    out PORT_DD, al
    jmp short $+2               ; I/O delay

    mov si, palette_data
    mov dx, PORT_DE
    mov cx, 12                  ; 6 entries × 2 bytes
    cld
    rep outsb                   ; Stream all palette data

    mov al, 0x80                ; Close palette write
    out PORT_DD, al
    sti
    ret

; ============================================================================
; fill_screen_gradient — Row-dithered sunset gradient
; ============================================================================
; Bank 0 (even visual rows): 3 simple fills
;   Rows 0-33:  0xAA (px 2)  — 34 rows = 1360 words
;   Rows 34-66: 0xFF (px 3)  — 33 rows = 1320 words
;   Rows 67-99: 0x55 (px 1)  — 33 rows = 1320 words
;
; Bank 1 (odd visual rows): 4 fills with offset boundaries
;   Rows 0-16:  0xAA (px 2)  — 17 rows = 680 words
;   Rows 17-49: 0xFF (px 3)  — 33 rows = 1320 words
;   Rows 50-83: 0x55 (px 1)  — 34 rows = 1360 words
;   Rows 84-99: 0x00 (px 0)  — 16 rows = 640 words
;
; The offset between banks creates dithered transition zones.
; ============================================================================
fill_screen_gradient:
    push es
    mov ax, VIDEO_SEG
    mov es, ax
    cld

    ; ---- Bank 0 (even visual rows) ----
    xor di, di

    mov ax, 0xAAAA              ; Pixel value 2
    mov cx, 1360                ; 34 rows × 40 words
    rep stosw

    mov ax, 0xFFFF              ; Pixel value 3
    mov cx, 1320                ; 33 rows × 40 words
    rep stosw

    mov ax, 0x5555              ; Pixel value 1
    mov cx, 1320                ; 33 rows × 40 words
    rep stosw

    ; ---- Bank 1 (odd visual rows) ----
    mov di, 0x2000

    mov ax, 0xAAAA              ; Pixel value 2
    mov cx, 680                 ; 17 rows × 40 words
    rep stosw

    mov ax, 0xFFFF              ; Pixel value 3
    mov cx, 1320                ; 33 rows × 40 words
    rep stosw

    mov ax, 0x5555              ; Pixel value 1
    mov cx, 1360                ; 34 rows × 40 words
    rep stosw

    xor ax, ax                  ; Pixel value 0 (black)
    mov cx, 640                 ; 16 rows × 40 words
    rep stosw

    pop es
    ret

; ============================================================================
; render_frame — Per-scanline palette flip (the magic!)
; ============================================================================
; Each scanline gets a different palette: even lines = pal 0, odd = pal 1.
; The palette is written during HBLANK via a single OUT to port 0xD9.
; No palette RAM streaming — proven to cause blinking on V6355D.
;
; Combined with the row-dithered VRAM, this creates 6 distinct blended
; colors from a 4-color CGA mode. All perfectly stable, zero flicker.
; ============================================================================
render_frame:
    cli

    ; Set palette for row 0 (takes effect immediately)
    mov al, PAL_EVEN
    out PORT_D9, al

    ; Prepare alternation: first HBLANK write sets row 1 to PAL_ODD
    mov bl, PAL_ODD
    mov bh, PAL_EVEN

    cmp byte [hsync_enabled], 0
    je .no_hsync_loop

    ; ------------------------------------------------------------------
    ; HSYNC-synced loop — flip palette on every scanline
    ; ------------------------------------------------------------------
    mov cx, SCREEN_HEIGHT

.next_line:

    ; Wait for HSYNC: low → high transition
.wait_low:
    in al, PORT_DA
    test al, 0x01               ; Bit 0 = horizontal retrace
    jnz .wait_low
.wait_high:
    in al, PORT_DA
    test al, 0x01
    jz .wait_high

    ; Write palette for this scanline — 1 OUT, ~13 cycles
    mov al, bl
    out PORT_D9, al

    ; Swap palette for next line
    xchg bl, bh

    loop .next_line

    jmp short .done_render

    ; ------------------------------------------------------------------
    ; Non-synchronized loop (for testing — will look unstable)
    ; ------------------------------------------------------------------
.no_hsync_loop:
    mov cx, SCREEN_HEIGHT
.no_sync_line:
    mov al, bl
    out PORT_D9, al
    xchg bl, bh

    ; Small delay to approximate scanline timing
    push cx
    mov cx, 50
.delay:
    loop .delay
    pop cx

    loop .no_sync_line

.done_render:
    ; Reset to palette 0 for clean start next frame
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
    test al, 0x08               ; Bit 3 = vertical retrace
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
; SUNSET PALETTE — 6 entries (2 bytes each) for entries 2-7
; ============================================================================
;
; RGB333 encoding: byte 1 = R (bits 0-2), byte 2 = G<<4 | B (bits 4-6, 0-2)
;
; Palette 0 (even scanlines) uses entries 2, 4, 6:
;   Entry 2: Crimson        R=7 G=0 B=0  — deep red
;   Entry 4: Deep Purple    R=3 G=0 B=6  — indigo-violet
;   Entry 6: Golden Yellow  R=7 G=6 B=0  — bright warm gold
;
; Palette 1 (odd scanlines) uses entries 3, 5, 7:
;   Entry 3: Amber          R=7 G=4 B=0  — warm orange
;   Entry 5: Lilac          R=5 G=2 B=7  — soft blue-violet
;   Entry 7: Warm Cream     R=7 G=5 B=3  — soft peach
;
; PERCEIVED BLENDS (what the eye sees):
;   Zone 1: purple + lilac     = vivid purple sky
;   Zone 2: purple + cream     = dusty mauve (VIRTUAL COLOR!)
;   Zone 3: gold + cream       = warm rich gold
;   Zone 4: gold + amber       = bright orange (VIRTUAL COLOR!)
;   Zone 5: crimson + amber    = sunset red-orange
;   Zone 6: crimson + black    = dark burgundy fade
;
palette_data:
    db 0x07, 0x00               ; Entry 2: Crimson       R=7 G=0 B=0
    db 0x07, 0x40               ; Entry 3: Amber         R=7 G=4 B=0
    db 0x03, 0x06               ; Entry 4: Deep Purple   R=3 G=0 B=6
    db 0x05, 0x27               ; Entry 5: Lilac         R=5 G=2 B=7
    db 0x07, 0x60               ; Entry 6: Golden Yellow R=7 G=6 B=0
    db 0x07, 0x53               ; Entry 7: Warm Cream    R=7 G=5 B=3

; ============================================================================
; END OF PROGRAM
; ============================================================================
;
; SUMMARY:
;   This demo creates a smooth sunset gradient using 7 perceived colors
;   from CGA mode 4's nominal 4-color limit. The technique requires:
;     - 1 OUT instruction per HBLANK (trivially fast)
;     - Careful palette entry pairing for pleasing blended colors
;     - Row-dithered VRAM for transition zones (set once, zero runtime cost)
;
;   No palette RAM writes during the visible area. No flicker. No jitter.
;   Just a beautiful sunset that CGA was never supposed to display.
;
; ============================================================================
