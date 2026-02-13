; ============================================================================
; CGAFLIP2.ASM - CGA Palette Flip Demo (Static 8-Color)
; ============================================================================
;
; DEMONSTRATION: Per-scanline CGA palette switching in 320x200x4 mode
; using the Yamaha V6355D programmable RGB333 palette.
;
; Written for NASM assembler
; Target: Olivetti Prodest PC1 / M24 with Yamaha V6355D video controller
; CPU: NEC V40 (80186 compatible) @ 8 MHz
;
; By Retro Erik - 2026
;
; ============================================================================
; THE TECHNIQUE
; ============================================================================
;
; In standard CGA 320x200x4 mode, each pixel is 2 bits → 4 colors.
; The CGA has two foreground palettes. On the V6355D, palette select
; is controlled by port 0xD8 (Mode Control Register) bit 5:
;
;   Palette 0 (bit 5=0): pixel values map to V6355D entries {bg, 2, 4, 6}
;   Palette 1 (bit 5=1): pixel values map to V6355D entries {bg, 3, 5, 7}
;
; The background index (pixel value 0) is set by port 0xD9 bits 3-0.
;
; By alternating the palette EVERY SCANLINE during HSYNC with 2 OUTs:
;   OUT 0xD8 → palette select (bit 5 toggles palette 0 vs 1)
;   OUT 0xD9 → background index (0 on even lines, 1 on odd lines)
;
; This displays 8 distinct RGB333 colors — 4 per line, alternating:
;
;   Even lines: palette 0, bg=index 0 → entries {0, 2, 4, 6}
;   Odd  lines: palette 1, bg=index 1 → entries {1, 3, 5, 7}
;
; Since V6355D palette entries 0-7 are all programmable to any RGB333
; value, this gives 8 arbitrary colors from the 512-color space.
;
; Timing: 2 OUTs = ~16 cycles. HBLANK is ~80 cycles. Plenty of margin.
;
; ============================================================================
; PORT LAYOUT FOR PALETTE FLIP
; ============================================================================
;
; Port 0xD8 (Mode Control Register):
;   Bit 5: Palette select (0 = palette 0, 1 = palette 1)
;   Other bits: mode config (kept constant: 0x0A = 320x200 graphics on)
;
;   Even lines: 0x0A = mode4 + palette 0
;   Odd  lines: 0x2A = mode4 + palette 1  (bit 5 set)
;
; Port 0xD9 (Color Select Register):
;   Bits 3-0: Background color index
;
;   Even lines: 0x00 = bg = entry 0
;   Odd  lines: 0x01 = bg = entry 1
;
;   CGA pixel value → V6355D palette entry mapping:
;
;     Pixel Value │ Even (palette 0) │ Odd (palette 1)
;     ───────────┼──────────────────┼─────────────────
;         0      │  entry 0 (bg=0)  │  entry 1 (bg=1)
;         1      │  entry 2         │  entry 3
;         2      │  entry 4         │  entry 5
;         3      │  entry 6         │  entry 7
;
; ============================================================================
; CONTROLS
; ============================================================================
;
;   ESC  : Exit to DOS
;   H    : Toggle HSYNC sync (shows what happens without timing)
;   V    : Toggle VSYNC sync (shows scrolling/tearing)
;
; ============================================================================

[BITS 16]
[ORG 0x100]

; ============================================================================
; Port Definitions — short aliases for speed on PC1
; ============================================================================
; On the PC1, ports 0x3Dx are mirrored at 0xDx.
; Short form (immediate OUT/IN) saves ~4 cycles vs DX-indirect form.
; See V6355D-Technical-Reference Section 3a.

PORT_D8         equ 0xD8    ; Mode Control Register
PORT_D9         equ 0xD9    ; Color Select Register (palette, intensity, bg)
PORT_DA         equ 0xDA    ; Status Register (bit 0=HSYNC, bit 3=VSYNC)
PORT_DD         equ 0xDD    ; V6355D Palette/Register Address
PORT_DE         equ 0xDE    ; V6355D Palette/Register Data

; ============================================================================
; Video Constants
; ============================================================================

VIDEO_SEG       equ 0xB800  ; Standard CGA video memory segment
SCREEN_HEIGHT   equ 200     ; Vertical resolution in pixels
BYTES_PER_ROW   equ 80      ; 320 pixels / 4 pixels per byte
BAND_WIDTH      equ 20      ; Each of 4 bands = 80 pixels = 20 bytes

; ============================================================================
; Palette flip values
; ============================================================================
; Port 0xD8: mode control with palette select in bit 5
;   Mode 4 base = 0x0A (graphics=1, video_enable=1)
;   Palette 0 = 0x0A (bit 5 clear)
;   Palette 1 = 0x2A (bit 5 set)
;
; Port 0xD9: background color index in bits 3-0
;   Even lines bg = 0 (entry 0)
;   Odd  lines bg = 1 (entry 1)

FLIP_D8_PAL0    equ 0x0A   ; Mode 4 + palette 0 (bit 5 = 0)
FLIP_D8_PAL1    equ 0x2A   ; Mode 4 + palette 1 (bit 5 = 1)
FLIP_D9_EVEN    equ 0x00   ; Background = entry 0
FLIP_D9_ODD     equ 0x01   ; Background = entry 1

; ============================================================================
; MAIN PROGRAM
; ============================================================================
main:
    ; ------------------------------------------------------------------
    ; Initialize state
    ; ------------------------------------------------------------------
    mov byte [hsync_enabled], 1
    mov byte [vsync_enabled], 1

    ; ------------------------------------------------------------------
    ; Set CGA 320x200x4 mode via BIOS
    ; ------------------------------------------------------------------
    mov ax, 0x0004          ; BIOS mode 4: 320x200 4-color CGA
    int 0x10

    ; ------------------------------------------------------------------
    ; Program V6355D palette entries 0-7 with custom RGB333 colors
    ; ------------------------------------------------------------------
    call program_palette

    ; ------------------------------------------------------------------
    ; Fill VRAM with 4 vertical bands (pixel values 0, 1, 2, 3)
    ; ------------------------------------------------------------------
    call fill_screen_bands

    ; ------------------------------------------------------------------
    ; Main loop: flip palettes per scanline each frame
    ; ------------------------------------------------------------------
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

    mov ax, 0x0003          ; BIOS mode 3: 80x25 text
    int 0x10
    mov ax, 0x4C00          ; DOS exit
    int 0x21

; ============================================================================
; program_palette - Write 8 RGB333 entries to V6355D palette RAM
; ============================================================================
; Programs entries 0-7 using ports 0xDD/0xDE.
; Palette write sequence: 0x40 → data stream → 0x80.
; I/O delays (jmp short $+2) required between writes per V6355D spec.
; ============================================================================
program_palette:
    cli

    mov al, 0x40            ; Start palette write at entry 0
    out PORT_DD, al
    jmp short $+2           ; I/O delay (V6355D needs ~300ns between accesses)

    ; Write 16 bytes (8 entries × 2 bytes: R then G<<4|B)
    mov si, palette_data
    mov cx, 16
.pal_loop:
    lodsb
    out PORT_DE, al
    jmp short $+2           ; I/O delay between writes
    loop .pal_loop

    mov al, 0x80            ; End palette write mode
    out PORT_DD, al

    sti
    ret

; ============================================================================
; fill_screen_bands - Draw 4 vertical bands using pixel values 0-3
; ============================================================================
; In CGA 320x200x4 mode, each pixel is 2 bits packed 4 per byte:
;   bits 7-6 = leftmost pixel, bits 1-0 = rightmost pixel
;
; Band layout (320 pixels = 80 bytes per row):
;   Bytes  0-19: pixel value 0 = 0x00  (00 00 00 00)
;   Bytes 20-39: pixel value 1 = 0x55  (01 01 01 01)
;   Bytes 40-59: pixel value 2 = 0xAA  (10 10 10 10)
;   Bytes 60-79: pixel value 3 = 0xFF  (11 11 11 11)
;
; CGA interlaced VRAM: even rows at 0x0000, odd rows at 0x2000.
; ============================================================================
fill_screen_bands:
    push es
    mov ax, VIDEO_SEG
    mov es, ax

    ; Fill both CGA banks
    xor bx, bx             ; BX = bank base (0x0000 or 0x2000)

.fill_bank:
    mov cx, 100             ; 100 rows per bank
    xor di, di
    add di, bx              ; Start at bank base

.fill_row:
    push cx
    push di

    ; Band 0: 20 bytes of 0x00 (pixel value 0)
    mov cx, 10
    xor ax, ax
    cld
    rep stosw

    ; Band 1: 20 bytes of 0x55 (pixel value 1)
    mov cx, 10
    mov ax, 0x5555
    rep stosw

    ; Band 2: 20 bytes of 0xAA (pixel value 2)
    mov cx, 10
    mov ax, 0xAAAA
    rep stosw

    ; Band 3: 20 bytes of 0xFF (pixel value 3)
    mov cx, 10
    mov ax, 0xFFFF
    rep stosw

    pop di
    add di, BYTES_PER_ROW
    pop cx
    loop .fill_row

    ; Switch to odd bank if not done yet
    cmp bx, 0x2000
    jae .fill_done
    mov bx, 0x2000
    jmp .fill_bank

.fill_done:
    pop es
    ret

; ============================================================================
; render_frame - Per-scanline palette flip (the core technique)
; ============================================================================
; For each of the 200 visible scanlines:
;   1. Wait for HSYNC edge (HBLANK start)
;   2. OUT 0xD8: set palette 0 or 1 via bit 5 of Mode Control Register
;   3. OUT 0xD9: set background color index (0 or 1)
;   4. Alternate even/odd values each line
;
; Timing: 2 OUTs = ~16 cycles in ~80 cycle HBLANK. Plenty of margin.
;
; Register usage during loop:
;   BL = current line's 0xD8 value (palette select)
;   BH = current line's 0xD9 value (background index)
;   DL = next line's 0xD8 value
;   DH = next line's 0xD9 value
;   CX = scanline counter
; ============================================================================
render_frame:
    cli                     ; No interrupts during palette writes

    mov cx, SCREEN_HEIGHT   ; 200 scanlines

    ; Even line values in BX, odd line values in DX
    mov bl, FLIP_D8_PAL0    ; BL = 0x0A (palette 0)
    mov bh, FLIP_D9_EVEN    ; BH = 0x00 (bg = entry 0)
    mov dl, FLIP_D8_PAL1    ; DL = 0x2A (palette 1)
    mov dh, FLIP_D9_ODD     ; DH = 0x01 (bg = entry 1)

    ; Check if HSYNC sync is enabled
    cmp byte [hsync_enabled], 0
    je .no_hsync_loop

    ; ------------------------------------------------------------------
    ; HSYNC-synchronized loop (stable display)
    ; ------------------------------------------------------------------
.scanline:
    ; Wait for HSYNC LOW (beam is drawing visible pixels)
.wait_low:
    in al, PORT_DA
    test al, 0x01
    jnz .wait_low

    ; Wait for HSYNC HIGH (beam entering HBLANK — safe to write!)
.wait_high:
    in al, PORT_DA
    test al, 0x01
    jz .wait_high

    ; --- CRITICAL: 2 fast OUTs during HBLANK ---
    mov al, bl              ; Palette select value
    out PORT_D8, al         ; Port 0xD8: set palette 0 or 1
    mov al, bh              ; Background index
    out PORT_D9, al         ; Port 0xD9: set bg color

    ; Swap even/odd values for next line
    xchg bx, dx             ; BX ↔ DX (swaps both pairs at once)

    loop .scanline
    jmp .done

    ; ------------------------------------------------------------------
    ; Non-synchronized loop (educational: shows tearing without sync)
    ; ------------------------------------------------------------------
.no_hsync_loop:
.no_sync_line:
    mov al, bl
    out PORT_D8, al
    mov al, bh
    out PORT_D9, al
    xchg bx, dx
    loop .no_sync_line

.done:
    ; Reset to palette 0, bg=0 for clean frame start
    mov al, FLIP_D8_PAL0
    out PORT_D8, al
    xor al, al
    out PORT_D9, al

    sti
    ret

; ============================================================================
; wait_vblank - Wait for vertical blanking period
; ============================================================================
; Waits for VSYNC end → VSYNC start (catches the frame boundary).
; After return: we are at the beginning of VBLANK.
; The render loop's wait_low will then block until VBLANK ends and
; the first visible scanline begins.
; ============================================================================
wait_vblank:
    cmp byte [vsync_enabled], 0
    je .skip

    ; Wait for VSYNC to end (exit any current VBLANK)
.wait_end:
    in al, PORT_DA
    test al, 0x08
    jnz .wait_end

    ; Wait for VSYNC to start (visible area has finished)
.wait_start:
    in al, PORT_DA
    test al, 0x08
    jz .wait_start

.skip:
    ret

; ============================================================================
; check_keyboard - Handle user input
; ============================================================================
; Returns: AL = 0xFF if ESC pressed (exit), else 0
; ============================================================================
check_keyboard:
    mov ah, 0x01
    int 0x16
    jz .no_key

    ; Read the key
    mov ah, 0x00
    int 0x16

    ; ESC?
    cmp ah, 0x01
    jne .not_esc
    mov al, 0xFF
    ret

.not_esc:
    ; H - toggle HSYNC
    cmp al, 'h'
    je .toggle_h
    cmp al, 'H'
    jne .not_h
.toggle_h:
    xor byte [hsync_enabled], 1
    jmp .no_key

.not_h:
    ; V - toggle VSYNC
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
; DATA SECTION
; ============================================================================

; State variables
hsync_enabled:  db 1            ; 1 = sync to HSYNC (stable), 0 = free-run
vsync_enabled:  db 1            ; 1 = sync to VSYNC (no tear), 0 = free-run

; ============================================================================
; V6355D Palette Data — 8 entries, RGB333 format
; ============================================================================
; Format per entry: byte1 = R (bits 2-0, 0-7), byte2 = G<<4 | B (0x00-0x77)
;
; Entry │ Role                  │ Color       │ R  G  B
; ──────┼───────────────────────┼─────────────┼────────
;   0   │ bg on even lines      │ Black       │ 0  0  0
;   1   │ bg on odd lines       │ Dark Blue   │ 0  0  5
;   2   │ pixel 1, even lines   │ Red         │ 7  0  0
;   3   │ pixel 1, odd lines    │ Cyan        │ 0  7  7
;   4   │ pixel 2, even lines   │ Green       │ 0  7  0
;   5   │ pixel 2, odd lines    │ Magenta     │ 7  0  7
;   6   │ pixel 3, even lines   │ Yellow      │ 7  7  0
;   7   │ pixel 3, odd lines    │ White       │ 7  7  7

palette_data:
    db 0x00, 0x00           ; 0: Black       (R=0, G=0, B=0)
    db 0x00, 0x05           ; 1: Dark Blue   (R=0, G=0, B=5)
    db 0x07, 0x00           ; 2: Red         (R=7, G=0, B=0)
    db 0x00, 0x77           ; 3: Cyan        (R=0, G=7, B=7)
    db 0x00, 0x70           ; 4: Green       (R=0, G=7, B=0)
    db 0x07, 0x07           ; 5: Magenta     (R=7, G=0, B=7)
    db 0x07, 0x70           ; 6: Yellow      (R=7, G=7, B=0)
    db 0x07, 0x77           ; 7: White       (R=7, G=7, B=7)

; ============================================================================
; END OF PROGRAM
; ============================================================================
