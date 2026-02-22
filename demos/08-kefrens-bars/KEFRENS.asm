; ============================================================================
; PC1-KEFRENS.asm - Kefrens Bars demo for Olivetti Prodest PC1
; Uses the hidden 160x200x16 graphics mode (Yamaha V6355D)
;
; Classic "Kefrens Bars" effect from the Amiga demo scene:
;   - Copper-colored gradient bars undulate across the screen
;   - Each frame draws ONE vertical column of bar pixels
;   - The column x-position follows a sine wave that varies per scanline,
;     creating the characteristic wavy bar shape
;   - Trails from previous frames remain on screen, building up the
;     swept-bar pattern over time
;
; Controls:
;   ESC - Exit to DOS
;
; Build:
;   nasm PC1-KEFRENS.asm -f bin -o PC1-KEFRENS.com
;
; Hardware required:
;   Olivetti Prodest PC1 (NEC V40, Yamaha V6355D)
;
; By Retro Erik - 2026
; ============================================================================

[BITS 16]
[ORG 0x100]

; ============================================================================
; Constants
; ============================================================================

; --- Video Memory ---
VIDEO_SEG       equ 0xB000      ; PC1 video RAM segment

; --- Yamaha V6355D I/O Ports ---
PORT_REG_ADDR   equ 0xDD        ; Register Bank Address Port
PORT_REG_DATA   equ 0xDE        ; Register Bank Data Port
PORT_MODE       equ 0xD8        ; Mode Control Register
PORT_COLOR      equ 0xD9        ; Color Select Register (border)
PORT_STATUS     equ 0x3DA       ; CGA Status Register (VSYNC/HSYNC)

; --- Screen Dimensions ---
SCREEN_WIDTH    equ 160         ; Horizontal resolution in pixels
SCREEN_HEIGHT   equ 200         ; Vertical resolution in pixels
BYTES_PER_ROW   equ 80          ; 160 pixels / 2 pixels per byte

; --- Bar Effect Parameters ---
BAR_PERIOD      equ 50          ; Scanlines per bar repetition (4 bars on screen)
BAR_HALF        equ 15          ; Gradient steps per bar half (colors 1-15)

; ============================================================================
; Entry Point
; ============================================================================
start:
    ; Enable hidden 160x200x16 graphics mode
    call    enable_gfx

    ; Set copper gradient palette
    call    set_palette

    ; Clear screen to black
    call    cls

    ; Initialize animation state
    xor     ax, ax
    mov     [phase], al
    mov     [bar_scroll], al
    mov     [frame_cnt], al

; ============================================================================
; Main Loop
; ============================================================================
main_loop:
    ; --- Wait for VBLANK (synchronize to frame) ---
    mov     dx, PORT_STATUS
.vb_end:
    in      al, dx
    test    al, 0x08            ; Test VSYNC bit (bit 3)
    jnz     .vb_end             ; Wait for VSYNC to end (active → inactive)
.vb_start:
    in      al, dx
    test    al, 0x08
    jz      .vb_start           ; Wait for VSYNC to start (inactive → active)

    ; --- Draw one column of Kefrens bars ---
    call    draw_column

    ; --- Animate sine wave ---
    inc     byte [phase]        ; Advance wave phase each frame

    ; --- Scroll bars vertically every 2 frames ---
    inc     byte [frame_cnt]
    cmp     byte [frame_cnt], 2
    jb      .no_scroll
    mov     byte [frame_cnt], 0
    inc     byte [bar_scroll]
    cmp     byte [bar_scroll], BAR_PERIOD
    jb      .no_scroll
    mov     byte [bar_scroll], 0
.no_scroll:

    ; --- Check ESC key (direct port read, no BIOS overhead) ---
    in      al, 0x60
    cmp     al, 1               ; ESC scancode
    je      .exit
    jmp     main_loop

.exit:
    ; Restore text mode
    mov     ax, 0x0003
    int     0x10

    ; Exit to DOS
    mov     ax, 0x4C00
    int     0x21

; ============================================================================
; draw_column - Draw one vertical column of Kefrens bar pixels
;
; For each scanline (y = 0..199):
;   1. Look up x position from sine table based on y and animation phase
;   2. Determine bar color from y position and vertical scroll offset
;   3. Plot the pixel at (x, y) with that color
;
; The sine wave varies per scanline, creating the wavy bar shape.
; Colors follow a repeating gradient pattern for the copper bar look.
; ============================================================================
draw_column:
    push    ax
    push    bx
    push    cx
    push    dx
    push    si
    push    di
    push    es
    push    bp

    mov     ax, VIDEO_SEG
    mov     es, ax

    xor     cx, cx              ; CX = y (scanline counter, 0-199)

.scanline:
    ; ----- Step 1: Get x position from sine table -----
    ; x = sine_table[(y * 2 + phase) & 0xFF]
    ; The y*2 factor creates ~1.5 full wave cycles across 200 scanlines
    mov     al, cl
    shl     al, 1               ; y * 2 (wraps at 256 = byte overflow)
    add     al, [phase]         ; + animation phase (also wraps)
    xor     ah, ah
    mov     si, ax
    mov     bl, [sine_table + si]   ; BL = x position (25-135)

    ; ----- Step 2: Calculate bar color -----
    ; bar_pos = (y + bar_scroll) mod BAR_PERIOD
    ; Color pattern per period:
    ;   bar_pos  0..14 → ascending gradient (color 1..15)
    ;   bar_pos 15..29 → descending gradient (color 15..1)
    ;   bar_pos 30..49 → black (color 0)
    mov     al, cl
    add     al, [bar_scroll]
    xor     ah, ah              ; AX = y + bar_scroll (0..248)

    ; Reduce AX mod BAR_PERIOD (max 5 subtractions for val ≤ 248)
.mod_loop:
    cmp     ax, BAR_PERIOD
    jb      .mod_done
    sub     ax, BAR_PERIOD
    jmp     .mod_loop
.mod_done:

    ; Determine color from bar_pos (AX)
    cmp     ax, BAR_HALF
    jae     .not_ascending

    ; Ascending half: color = bar_pos + 1 (values 1..15)
    inc     al
    jmp     .have_color

.not_ascending:
    cmp     ax, BAR_HALF * 2
    jae     .is_black

    ; Descending half: color = (BAR_HALF * 2) - bar_pos (values 15..1)
    neg     ax
    add     ax, BAR_HALF * 2
    jmp     .have_color

.is_black:
    xor     al, al              ; Color = 0 (black gap between bars)

.have_color:
    ; AL = color (0-15), BL = x (25-135), CX = y (0-199)
    mov     dl, al              ; DL = color (save for later)

    ; ----- Step 3: Calculate VRAM byte offset -----
    ; Memory layout: CGA-style interleaved
    ;   Even rows (y=0,2,4..): offset = (y/2) * 80
    ;   Odd rows  (y=1,3,5..): offset = 0x2000 + (y/2) * 80
    ;   Within row: byte = x / 2
    mov     ax, cx              ; AX = y
    shr     ax, 1               ; AX = y / 2
    mov     bp, BYTES_PER_ROW
    push    dx
    mul     bp                  ; AX = (y/2) * 80
    pop     dx
    mov     di, ax              ; DI = row base offset
    test    cl, 1               ; Odd row?
    jz      .even_row
    add     di, 0x2000          ; Odd rows start at bank 2
.even_row:
    mov     al, bl              ; AL = x
    xor     ah, ah
    shr     ax, 1               ; AX = x / 2
    add     di, ax              ; DI = final byte offset in VRAM

    ; ----- Step 4: Read-modify-write the target nibble -----
    ; High nibble = left pixel (even x), low nibble = right pixel (odd x)
    mov     al, [es:di]         ; Read current byte from VRAM
    test    bl, 1               ; Is x odd?
    jnz     .odd_pixel

    ; Even x → write to HIGH nibble (left pixel)
    and     al, 0x0F            ; Preserve low nibble (right pixel)
    mov     ah, dl              ; AH = color
    shl     ah, 4               ; Shift color into high nibble position
    or      al, ah
    jmp     .write_pixel

.odd_pixel:
    ; Odd x → write to LOW nibble (right pixel)
    and     al, 0xF0            ; Preserve high nibble (left pixel)
    or      al, dl              ; Place color in low nibble

.write_pixel:
    mov     [es:di], al         ; Write modified byte back to VRAM

    ; ----- Next scanline -----
    inc     cx
    cmp     cx, SCREEN_HEIGHT
    jb      .scanline

    pop     bp
    pop     es
    pop     di
    pop     si
    pop     dx
    pop     cx
    pop     bx
    pop     ax
    ret

; ============================================================================
; enable_gfx - Enable Olivetti PC1 hidden 160x200x16 graphics mode
;
; Sequence:
;   1. BIOS mode 4 → sets CRTC timing for 15.7kHz horizontal sync
;   2. Register 0x67 → 8-bit bus mode (MUST be 0 on PC1's 8-bit bus!)
;   3. Register 0x65 → 200 lines, PAL 50Hz
;   4. Port 0xD8 = 0x4A → unlock 16-color planar mode
;   5. Port 0xD9 = 0x00 → black border
; ============================================================================
enable_gfx:
    push    ax
    push    dx

    ; Set BIOS mode 4 (CGA 320x200) to configure CRTC timing
    mov     ax, 0x0004
    int     0x10

    ; Register 0x67: Configuration - 8-bit bus, CRT timing
    mov     al, 0x67
    out     PORT_REG_ADDR, al
    jmp     short $+2           ; I/O delay (~300ns for V6355D)
    mov     al, 0x18
    out     PORT_REG_DATA, al
    jmp     short $+2

    ; Register 0x65: Monitor - 200 lines, PAL 50Hz, color CRT
    mov     al, 0x65
    out     PORT_REG_ADDR, al
    jmp     short $+2
    mov     al, 0x09            ; 200 lines, PAL/50Hz
    out     PORT_REG_DATA, al
    jmp     short $+2

    ; Port 0xD8: Unlock 16-color mode (bit 6 = mode unlock)
    mov     al, 0x4A            ; Graphics on, video on, 16-color unlock
    out     PORT_MODE, al
    jmp     short $+2

    ; Port 0xD9: Black border
    xor     al, al
    out     PORT_COLOR, al

    pop     dx
    pop     ax
    ret

; ============================================================================
; set_palette - Write 16-color copper gradient palette to V6355D
;
; Palette format (per entry): 2 bytes
;   Byte 1: Red intensity (bits 0-2, values 0-7)
;   Byte 2: Green (bits 4-6) | Blue (bits 0-2)
;
; Writes all 16 entries (32 bytes) in one burst.
; ============================================================================
set_palette:
    push    ax
    push    cx
    push    si

    cli                         ; Disable interrupts during palette write

    ; Open palette write (start at entry 0)
    mov     al, 0x40
    out     PORT_REG_ADDR, al
    jmp     short $+2
    jmp     short $+2

    ; Stream 32 bytes of palette data
    mov     si, palette_data
    mov     cx, 32
.pal_loop:
    lodsb
    out     PORT_REG_DATA, al
    jmp     short $+2
    loop    .pal_loop

    ; Close palette write
    jmp     short $+2
    mov     al, 0x80
    out     PORT_REG_ADDR, al
    jmp     short $+2

    sti

    pop     si
    pop     cx
    pop     ax
    ret

; ============================================================================
; cls - Clear video RAM to black (all zeros)
; ============================================================================
cls:
    push    ax
    push    cx
    push    di
    push    es

    mov     ax, VIDEO_SEG
    mov     es, ax
    xor     di, di
    mov     cx, 8192            ; 16KB = 8192 words
    xor     ax, ax
    cld
    rep     stosw

    pop     es
    pop     di
    pop     cx
    pop     ax
    ret

; ============================================================================
; Data Section
; ============================================================================

; --- Animation state ---
phase       db 0                ; Sine wave phase (0-255, wraps)
bar_scroll  db 0                ; Vertical bar scroll offset (0 to BAR_PERIOD-1)
frame_cnt   db 0                ; Frame counter for scroll timing

; --- Copper Gradient Palette (16 entries x 2 bytes = 32 bytes) ---
; Smooth gradient from black through dark red, red, orange, gold, to bright yellow
; Creates the classic "copper bar" look from the Amiga demo scene
palette_data:
    ;       R     G<<4|B       Color description
    db      0,    0x00        ; Entry  0: Black (background/gap)
    db      1,    0x00        ; Entry  1: Very dark red
    db      2,    0x00        ; Entry  2: Dark red
    db      3,    0x00        ; Entry  3: Medium red
    db      4,    0x10        ; Entry  4: Red with hint of green
    db      5,    0x10        ; Entry  5: Bright red-orange
    db      5,    0x20        ; Entry  6: Orange
    db      6,    0x20        ; Entry  7: Bright orange
    db      6,    0x30        ; Entry  8: Amber
    db      7,    0x30        ; Entry  9: Bright amber
    db      7,    0x41        ; Entry 10: Gold
    db      7,    0x51        ; Entry 11: Bright gold
    db      7,    0x52        ; Entry 12: Yellow-gold
    db      7,    0x63        ; Entry 13: Yellow
    db      7,    0x74        ; Entry 14: Bright yellow
    db      7,    0x76        ; Entry 15: Near-white (bar peak)

; --- Sine Table (256 entries, one byte each) ---
; sine_table[i] = round(80 + 55 * sin(2π * i / 256))
; Center = 80 (middle of 160-pixel screen)
; Amplitude = 55 pixels → range 25 to 135
; Ensures bars stay within screen bounds with margin
sine_table:
    db 80, 81, 83, 84, 85, 87, 88, 89, 91, 92, 93, 95, 96, 97, 99, 100
    db 101, 102, 104, 105, 106, 107, 108, 109, 111, 112, 113, 114, 115, 116, 117, 118
    db 119, 120, 121, 122, 123, 123, 124, 125, 126, 126, 127, 128, 129, 129, 130, 130
    db 131, 131, 132, 132, 133, 133, 133, 134, 134, 134, 134, 135, 135, 135, 135, 135
    db 135, 135, 135, 135, 135, 135, 134, 134, 134, 134, 133, 133, 133, 132, 132, 131
    db 131, 130, 130, 129, 129, 128, 127, 126, 126, 125, 124, 123, 123, 122, 121, 120
    db 119, 118, 117, 116, 115, 114, 113, 112, 111, 109, 108, 107, 106, 105, 104, 102
    db 101, 100, 99, 97, 96, 95, 93, 92, 91, 89, 88, 87, 85, 84, 83, 81
    db 80, 79, 77, 76, 75, 73, 72, 71, 69, 68, 67, 65, 64, 63, 61, 60
    db 59, 58, 56, 55, 54, 53, 52, 51, 49, 48, 47, 46, 45, 44, 43, 42
    db 41, 40, 39, 38, 37, 37, 36, 35, 34, 34, 33, 32, 31, 31, 30, 30
    db 29, 29, 28, 28, 27, 27, 27, 26, 26, 26, 26, 25, 25, 25, 25, 25
    db 25, 25, 25, 25, 25, 25, 26, 26, 26, 26, 27, 27, 27, 28, 28, 29
    db 29, 30, 30, 31, 31, 32, 33, 34, 34, 35, 36, 37, 37, 38, 39, 40
    db 41, 42, 43, 44, 45, 46, 47, 48, 49, 51, 52, 53, 54, 55, 56, 58
    db 59, 60, 61, 63, 64, 65, 67, 68, 69, 71, 72, 73, 75, 76, 77, 79
