; ============================================================================
; KEFRENS2.asm - Kefrens Bars v2 with raster background
; Olivetti Prodest PC1 - Yamaha V6355D - NEC V40 @ 8 MHz
;
; Inspired by the Kefrens bars effect from the 8088mph demo.
;
; Two combined effects:
;
;   1. KEFRENS BARS (VRAM pixels, colors 1-15):
;      Classic "draw one column per frame" technique with trail persistence.
;      Uses 3 summed sine waves of different periods per scanline to create
;      the organic, morphing bar shape seen in 8088mph. Each wave has its
;      own speed, creating constantly shifting, living bar movement.
;
;   2. RASTER BACKGROUND (PORT_COLOR, palette index 0):
;      Per-scanline color changes via PORT_COLOR register (port 0xD9).
;      After unlocking with 0x40 to 0xDD, PORT_COLOR changes what
;      palette entry 0 looks like for the entire scanline width.
;      Since the Kefrens bars use colors 1-15, and the empty background
;      is color 0, the raster stripes show through ONLY where there are
;      no bar pixels — creating the dancing raster background.
;
;      Uses zero CPU for VRAM writes — just 1 OUT per scanline.
;      The raster bars move via sine wave, independent of the kefrens bars.
;
; Controls:
;   ESC - Exit to DOS
;
; Build:
;   nasm KEFRENS2.asm -f bin -o KEFRENS2.com
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

; --- Bar Gradient Parameters ---
BAR_PERIOD      equ 40          ; Scanlines per bar repetition
BAR_HALF        equ 12          ; Gradient steps per bar half (colors 1-12)

; --- Raster Bar Parameters ---
RASTER_HEIGHT   equ 16          ; Scanlines per raster bar (gradient up + down)
NUM_RASTER_BARS equ 3           ; Number of background raster bars

; --- Sine Wave Periods (different periods = morphing shape) ---
; These create the 8088mph-style organic motion.
; Wave 1: broad, slow sweep (primary shape)
; Wave 2: medium detail, faster (adds undulation)
; Wave 3: fine detail, fastest (adds "shimmer")
WAVE1_Y_STEP    equ 3           ; Sine steps per scanline for wave 1 (broad)
WAVE2_Y_STEP    equ 7           ; Sine steps per scanline for wave 2 (medium)
WAVE3_Y_STEP    equ 13          ; Sine steps per scanline for wave 3 (fine)
WAVE1_SPEED     equ 1           ; Phase advance per frame for wave 1
WAVE2_SPEED     equ 2           ; Phase advance per frame for wave 2
WAVE3_SPEED     equ 3           ; Phase advance per frame for wave 3

; ============================================================================
; Entry Point
; ============================================================================
start:
    cld                         ; Clear direction flag for rep string ops
    call    enable_gfx
    push    cs
    pop     es                  ; Restore ES = CS (INT 10h may change ES!)
    call    set_palette
    call    cls

    ; Initialize animation state
    xor     ax, ax
    mov     [wave1_phase], al
    mov     [wave2_phase], al
    mov     [wave3_phase], al
    mov     [bar_scroll], al
    mov     [raster_phase], al

; ============================================================================
; Main Loop
;
; Frame timing:
;   1. Build raster table (not timing critical, can run anytime)
;   2. Wait for VBLANK start
;   3. Draw kefrens column + animate (fits within VBLANK: ~26K / ~57K cycles)
;   4. Wait for VBLANK to END (beam at scanline 0)
;   5. Render rasters HSYNC-synced from scanline 0 (200 scanlines)
;   6. Loop
; ============================================================================
main_loop:
    ; --- Build raster table (not timing critical) ---
    call    build_raster_table

    ; --- Wait for VBLANK start ---
    mov     dx, PORT_STATUS
.vb_end:
    in      al, dx
    test    al, 0x08
    jnz     .vb_end
.vb_start:
    in      al, dx
    test    al, 0x08
    jz      .vb_start

    ; --- During VBLANK: draw kefrens column ---
    call    draw_column

    ; --- Animate wave phases (still in VBLANK) ---
    mov     al, [wave1_phase]
    add     al, WAVE1_SPEED
    mov     [wave1_phase], al

    mov     al, [wave2_phase]
    add     al, WAVE2_SPEED
    mov     [wave2_phase], al

    mov     al, [wave3_phase]
    add     al, WAVE3_SPEED
    mov     [wave3_phase], al

    ; --- Scroll bar colors vertically ---
    inc     byte [bar_scroll]
    cmp     byte [bar_scroll], BAR_PERIOD
    jb      .no_wrap
    mov     byte [bar_scroll], 0
.no_wrap:

    ; --- Advance raster bar position ---
    add     byte [raster_phase], 2

    ; --- Check ESC (before rendering, so exit is responsive) ---
    in      al, 0x60
    cmp     al, 1
    je      .exit

    ; --- Wait for VBLANK to END (beam now at scanline 0) ---
    mov     dx, PORT_STATUS
.vb_active:
    in      al, dx
    test    al, 0x08
    jnz     .vb_active          ; Wait while VBLANK is still active

    ; --- Render raster bars from scanline 0 (timing critical) ---
    call    render_rasters

    jmp     main_loop

.exit:
    mov     ax, 0x0003
    int     0x10
    mov     ax, 0x4C00
    int     0x21

; ============================================================================
; draw_column - Draw one column of kefrens bar pixels using 3 summed sine waves
;
; For each scanline y (0-199):
;   x = sine[y*WAVE1_STEP + wave1_phase] / 2
;     + sine[y*WAVE2_STEP + wave2_phase] / 4
;     + sine[y*WAVE3_STEP + wave3_phase] / 4
;
; Wave 1 provides the broad sweep (half amplitude),
; Wave 2 adds medium undulation (quarter amplitude),
; Wave 3 adds fine shimmer (quarter amplitude).
; The three waves have different y-step rates, so the bar shape morphs
; continuously as their phases advance at different speeds.
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

    xor     cx, cx              ; CX = y (0-199)

.scanline:
    ; ----- Calculate x from 3 summed sine waves -----

    ; Wave 1: broad sweep — sine[(y * WAVE1_STEP + phase1) & 0xFF]
    mov     al, cl
    mov     bl, WAVE1_Y_STEP
    mul     bl                  ; AX = y * WAVE1_STEP (may exceed 255, that's OK)
    add     al, [wave1_phase]
    xor     ah, ah
    mov     si, ax
    and     si, 0xFF
    mov     al, [sine_table + si]   ; 0-128 range
    shr     al, 1                   ; /2 → 0-64 (dominant wave)
    mov     bl, al                  ; BL = wave1 contribution

    ; Wave 2: medium detail — sine[(y * WAVE2_STEP + phase2) & 0xFF]
    mov     al, cl
    push    bx
    mov     bl, WAVE2_Y_STEP
    mul     bl
    pop     bx
    add     al, [wave2_phase]
    xor     ah, ah
    mov     si, ax
    and     si, 0xFF
    mov     al, [sine_table + si]
    shr     al, 2                   ; /4 → 0-32 (secondary wave)
    add     bl, al                  ; BL += wave2

    ; Wave 3: fine shimmer — sine[(y * WAVE3_STEP + phase3) & 0xFF]
    mov     al, cl
    push    bx
    mov     bl, WAVE3_Y_STEP
    mul     bl
    pop     bx
    add     al, [wave3_phase]
    xor     ah, ah
    mov     si, ax
    and     si, 0xFF
    mov     al, [sine_table + si]
    shr     al, 2                   ; /4 → 0-32 (tertiary wave)
    add     bl, al                  ; BL = total x offset (0-128)

    ; Center on screen: add margin so bar stays in bounds
    ; Max x = 128 (64+32+32), plus 16 margin → range 16-144 (within 0-159)
    add     bl, 16

    ; Clamp to screen width (safety)
    cmp     bl, SCREEN_WIDTH
    jb      .x_ok
    mov     bl, SCREEN_WIDTH - 1
.x_ok:

    ; ----- Calculate bar color -----
    mov     al, cl
    add     al, [bar_scroll]
    xor     ah, ah

.mod_loop:
    cmp     ax, BAR_PERIOD
    jb      .mod_done
    sub     ax, BAR_PERIOD
    jmp     .mod_loop
.mod_done:

    cmp     ax, BAR_HALF
    jae     .not_ascending
    inc     al                  ; Colors 1..12
    jmp     .have_color
.not_ascending:
    cmp     ax, BAR_HALF * 2
    jae     .is_black
    neg     ax
    add     ax, BAR_HALF * 2    ; Colors 12..1
    jmp     .have_color
.is_black:
    xor     al, al              ; Color 0 (background - will show raster!)
.have_color:
    mov     dl, al              ; DL = color

    ; ----- Calculate VRAM offset -----
    mov     ax, cx              ; AX = y
    shr     ax, 1               ; AX = y / 2
    mov     bp, BYTES_PER_ROW
    push    dx
    mul     bp                  ; AX = (y/2) * 80
    pop     dx
    mov     di, ax
    test    cl, 1
    jz      .even_row
    add     di, 0x2000
.even_row:
    mov     al, bl              ; AL = x
    xor     ah, ah
    shr     ax, 1               ; AX = x / 2
    add     di, ax

    ; ----- Read-modify-write nibble -----
    mov     al, [es:di]
    test    bl, 1
    jnz     .odd_pixel

    ; Even x → high nibble
    and     al, 0x0F
    mov     ah, dl
    shl     ah, 4
    or      al, ah
    jmp     .write_pixel

.odd_pixel:
    ; Odd x → low nibble
    and     al, 0xF0
    or      al, dl

.write_pixel:
    mov     [es:di], al

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
; build_raster_table - Pre-compute PORT_COLOR values for 200 scanlines
;
; Creates dancing raster bars in the background using palette indices 0-15.
; These are output per-scanline via PORT_COLOR, which affects palette entry 0.
; Wherever VRAM = color 0 (background), the raster color shows through.
; Wherever VRAM = colors 1-15 (kefrens pixels), those colors override.
; ============================================================================
build_raster_table:
    push    ax
    push    bx
    push    cx
    push    si
    push    di
    push    es

    ; ES must equal DS for rep stosb (ES:DI target)
    push    ds
    pop     es

    ; Clear table to 0 (black background where no raster bar)
    mov     di, raster_colors
    mov     cx, SCREEN_HEIGHT
    xor     al, al
    cld
    rep     stosb

    ; Draw 3 raster bars at positions determined by sine wave
    mov     cl, NUM_RASTER_BARS
    mov     al, [raster_phase]
    mov     bl, al              ; BL = base phase

.bar_loop:
    ; Get Y position for this bar from sine table
    xor     bh, bh
    mov     al, [raster_sine + bx]  ; Y center position (0-199)
    xor     ah, ah
    mov     si, ax              ; SI = Y center

    ; Draw gradient: ascending 1..8, descending 8..1
    ; Total height = 16 scanlines
    push    cx
    push    bx

    ; Ascending half (bottom edge → center)
    mov     cx, RASTER_HEIGHT / 2
    mov     di, si
    sub     di, RASTER_HEIGHT / 2   ; start at top of bar
    mov     bx, 1               ; starting color

.raster_up:
    ; Bounds check
    cmp     di, 0
    jl      .skip_up
    cmp     di, SCREEN_HEIGHT
    jge     .skip_up
    ; Only write if current slot is empty (don't overwrite other bars)
    cmp     byte [raster_colors + di], 0
    jne     .skip_up
    mov     [raster_colors + di], bl
.skip_up:
    inc     di
    inc     bx
    loop    .raster_up

    ; Descending half (center → bottom edge)
    mov     cx, RASTER_HEIGHT / 2
    mov     bx, RASTER_HEIGHT / 2  ; peak color

.raster_down:
    cmp     di, 0
    jl      .skip_down
    cmp     di, SCREEN_HEIGHT
    jge     .skip_down
    cmp     byte [raster_colors + di], 0
    jne     .skip_down
    mov     [raster_colors + di], bl
.skip_down:
    inc     di
    dec     bx
    loop    .raster_down

    pop     bx
    pop     cx

    ; Next bar: offset phase by 85 (~120 degrees) for even spacing
    add     bl, 85
    dec     cl
    jnz     .bar_loop

    pop     es
    pop     di
    pop     si
    pop     cx
    pop     bx
    pop     ax
    ret

; ============================================================================
; render_rasters - Output PORT_COLOR per scanline (timing critical)
;
; This runs with interrupts disabled, synchronized to HSYNC.
; Only 1 OUT per scanline — very lightweight.
; ============================================================================
render_rasters:
    push    ax
    push    bx
    push    dx
    push    si

    ; Caller has already waited for VBLANK to end — beam is at scanline 0
    cli

    mov     si, raster_colors
    xor     bx, bx
    mov     dx, PORT_STATUS

.scanline_loop:
    ; Wait for HSYNC edge (low → high) for clean timing
.wait_low:
    in      al, dx
    test    al, 0x01
    jnz     .wait_low
.wait_high:
    in      al, dx
    test    al, 0x01
    jz      .wait_high

    ; Output color for this scanline
    mov     al, [si + bx]
    out     PORT_COLOR, al

    inc     bx
    cmp     bx, SCREEN_HEIGHT
    jb      .scanline_loop

    ; Reset to black after last scanline
    xor     al, al
    out     PORT_COLOR, al

    sti

    pop     si
    pop     dx
    pop     bx
    pop     ax
    ret

; ============================================================================
; enable_gfx - Enable Olivetti PC1 hidden 160x200x16 graphics mode
; ============================================================================
enable_gfx:
    push    ax
    push    dx

    mov     ax, 0x0004
    int     0x10

    ; Register 0x67: 8-bit bus, CRT timing
    mov     al, 0x67
    out     PORT_REG_ADDR, al
    jmp     short $+2
    mov     al, 0x18
    out     PORT_REG_DATA, al
    jmp     short $+2

    ; Register 0x65: 200 lines, PAL 50Hz
    mov     al, 0x65
    out     PORT_REG_ADDR, al
    jmp     short $+2
    mov     al, 0x09
    out     PORT_REG_DATA, al
    jmp     short $+2

    ; Unlock 16-color mode
    mov     al, 0x4A
    out     PORT_MODE, al
    jmp     short $+2

    ; Black border
    xor     al, al
    out     PORT_COLOR, al

    pop     dx
    pop     ax
    ret

; ============================================================================
; set_palette - Write copper + raster palette
;
; Palette layout:
;   Entry 0: Dynamically changed per-scanline by PORT_COLOR (raster bars)
;   Entries 1-12: Copper gradient for kefrens bars (dark red → bright yellow)
;   Entries 13-15: Raster bar colors (blue, cyan, white)
;
; PORT_COLOR writes an INDEX (0-15) which selects which palette entry's RGB
; values are shown for all color-0 pixels on that scanline.
; So the raster bar gradient uses entries 1-8 from the palette too.
;
; IMPORTANT: We do NOT write 0x80 to close palette write!
; Leaving it "unlocked" (0x40 mode) enables full-width PORT_COLOR.
; ============================================================================
set_palette:
    push    ax
    push    cx
    push    si

    cli

    ; Open palette write (entry 0, auto-increment) — AND enable full-width mode
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

    ; NOTE: intentionally NOT writing 0x80 — keeps PORT_COLOR full-width!

    sti

    pop     si
    pop     cx
    pop     ax
    ret

; ============================================================================
; cls - Clear video RAM to black
; ============================================================================
cls:
    push    ax
    push    cx
    push    di
    push    es

    mov     ax, VIDEO_SEG
    mov     es, ax
    xor     di, di
    mov     cx, 8192
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
wave1_phase     db 0            ; Phase for sine wave 1 (broad sweep)
wave2_phase     db 0            ; Phase for sine wave 2 (medium undulation)
wave3_phase     db 0            ; Phase for sine wave 3 (fine shimmer)
bar_scroll      db 0            ; Vertical bar color scroll
raster_phase    db 0            ; Raster bar vertical position phase

; --- Pre-computed raster color table (1 byte per scanline) ---
raster_colors:  times SCREEN_HEIGHT db 0

; --- Copper Gradient Palette (16 entries x 2 bytes = 32 bytes) ---
; Entry 0 is dynamically overridden by PORT_COLOR per scanline,
; but its palette RGB is still used as the "default" background.
;
; Entries 1-12: Copper bar gradient (kefrens pixels)
; Entries 13-15: Bright accent colors (reachable by raster bars if needed)
;
; Format: Byte 1 = Red (0-7), Byte 2 = Green<<4 | Blue (each 0-7)
palette_data:
    ;       R     G<<4|B       Description
    db      0,    0x00        ; Entry  0: Black (background / raster base)
    db      1,    0x00        ; Entry  1: Very dark red
    db      2,    0x00        ; Entry  2: Dark red
    db      3,    0x01        ; Entry  3: Medium red
    db      4,    0x10        ; Entry  4: Red-orange
    db      5,    0x10        ; Entry  5: Bright red-orange
    db      5,    0x20        ; Entry  6: Orange
    db      6,    0x30        ; Entry  7: Bright amber
    db      7,    0x40        ; Entry  8: Gold (raster bar peak)
    db      7,    0x51        ; Entry  9: Bright gold
    db      7,    0x62        ; Entry 10: Yellow
    db      7,    0x73        ; Entry 11: Bright yellow
    db      7,    0x76        ; Entry 12: Near-white (kefrens peak)
    db      0,    0x02        ; Entry 13: Dark blue (raster)
    db      0,    0x04        ; Entry 14: Medium blue (raster)
    db      0,    0x07        ; Entry 15: Bright blue (raster)

; --- Kefrens Wave Sine Table (256 entries, values 0-128) ---
; sine_table[i] = round(64 + 64 * sin(2π * i / 256))
; Range 0-128, centered at 64. The draw_column routine scales each wave:
;   Wave 1: /2 → 0-64 pixels (dominant shape)
;   Wave 2: /4 → 0-32 pixels (medium detail)
;   Wave 3: /4 → 0-32 pixels (fine shimmer)
; Total max: 64+32+32 = 128 pixels + 16 margin = 144 (within 160-wide screen)
sine_table:
    db 64, 66, 67, 69, 70, 72, 73, 75, 76, 78, 79, 81, 82, 84, 85, 87
    db 88, 89, 91, 92, 93, 95, 96, 97, 98, 100, 101, 102, 103, 104, 105, 106
    db 107, 108, 109, 110, 111, 112, 113, 113, 114, 115, 115, 116, 116, 117, 117, 118
    db 118, 118, 119, 119, 119, 120, 120, 120, 120, 120, 120, 120, 120, 120, 120, 120
    db 120, 120, 120, 120, 120, 120, 120, 120, 120, 120, 119, 119, 119, 118, 118, 118
    db 117, 117, 116, 116, 115, 115, 114, 113, 113, 112, 111, 110, 109, 108, 107, 106
    db 105, 104, 103, 102, 101, 100, 98, 97, 96, 95, 93, 92, 91, 89, 88, 87
    db 85, 84, 82, 81, 79, 78, 76, 75, 73, 72, 70, 69, 67, 66, 64, 63
    db 61, 60, 58, 57, 55, 54, 52, 51, 49, 48, 46, 45, 43, 42, 40, 39
    db 38, 36, 35, 34, 32, 31, 30, 29, 27, 26, 25, 24, 23, 22, 21, 20
    db 19, 18, 17, 16, 15, 14, 13, 13, 12, 11, 11, 10, 10, 9, 9, 8
    db 8, 8, 7, 7, 7, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6
    db 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 7, 7, 7, 8, 8, 8
    db 9, 9, 10, 10, 11, 11, 12, 13, 13, 14, 15, 16, 17, 18, 19, 20
    db 21, 22, 23, 24, 25, 26, 27, 29, 30, 31, 32, 34, 35, 36, 38, 39
    db 40, 42, 43, 45, 46, 48, 49, 51, 52, 54, 55, 57, 58, 60, 61, 63

; --- Raster Bar Position Sine Table (256 entries, values 10-189) ---
; Positions the raster bars vertically on screen with some margin
; raster_sine[i] = round(100 + 89 * sin(2π * i / 256))
raster_sine:
    db 100, 102, 104, 106, 108, 110, 113, 115, 117, 119, 121, 123, 125, 127, 129, 131
    db 133, 135, 137, 139, 140, 142, 144, 146, 147, 149, 150, 152, 153, 155, 156, 157
    db 159, 160, 161, 162, 163, 164, 165, 166, 167, 168, 168, 169, 170, 170, 171, 171
    db 171, 172, 172, 172, 172, 172, 172, 172, 172, 172, 172, 172, 171, 171, 171, 170
    db 170, 169, 168, 168, 167, 166, 165, 164, 163, 162, 161, 160, 159, 157, 156, 155
    db 153, 152, 150, 149, 147, 146, 144, 142, 140, 139, 137, 135, 133, 131, 129, 127
    db 125, 123, 121, 119, 117, 115, 113, 110, 108, 106, 104, 102, 100, 98, 96, 94
    db 92, 90, 87, 85, 83, 81, 79, 77, 75, 73, 71, 69, 67, 65, 63, 61
    db 60, 58, 56, 54, 53, 51, 50, 48, 47, 45, 44, 43, 41, 40, 39, 38
    db 37, 36, 35, 34, 33, 32, 32, 31, 30, 30, 29, 29, 29, 28, 28, 28
    db 28, 28, 28, 28, 28, 28, 28, 28, 29, 29, 29, 30, 30, 31, 32, 32
    db 33, 34, 35, 36, 37, 38, 39, 40, 41, 43, 44, 45, 47, 48, 50, 51
    db 53, 54, 56, 58, 60, 61, 63, 65, 67, 69, 71, 73, 75, 77, 79, 81
    db 83, 85, 87, 90, 92, 94, 96, 98, 100, 102, 104, 106, 108, 110, 113, 115
    db 117, 119, 121, 123, 125, 127, 129, 131, 133, 135, 137, 139, 140, 142, 144, 146
    db 147, 149, 150, 152, 153, 155, 156, 157, 159, 160, 161, 162, 163, 164, 165, 166
