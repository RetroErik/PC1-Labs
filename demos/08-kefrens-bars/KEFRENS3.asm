; ============================================================================
; KEFRENS3.asm - Kefrens Bars v3 with raster background
; Olivetti Prodest PC1 - Yamaha V6355D - NEC V40 @ 8 MHz
;
; Two combined effects:
;   1. Kefrens bars with 3 summed sine waves (8088mph-style morphing shape)
;   2. Dancing raster bar background via PORT_COLOR
;
; PORT_COLOR shows through wherever VRAM is color 0 (background).
; Kefrens bar pixels (colors 1-15) are unaffected by PORT_COLOR.
;
; Controls: ESC - Exit to DOS
;
; Build: nasm KEFRENS3.asm -f bin -o KEFRENS3.com
;
; By Retro Erik - 2026
; ============================================================================

[BITS 16]
[ORG 0x100]

; ============================================================================
; Constants
; ============================================================================

VIDEO_SEG       equ 0xB000
PORT_REG_ADDR   equ 0xDD        ; V6355D Register Address Port
PORT_REG_DATA   equ 0xDE        ; V6355D Register Data Port
PORT_MODE       equ 0xD8        ; Mode Control Register
PORT_COLOR      equ 0xD9        ; Color Select Register
PORT_STATUS     equ 0x3DA       ; CGA Status Register (VSYNC/HSYNC)

SCREEN_WIDTH    equ 160
SCREEN_HEIGHT   equ 200
BYTES_PER_ROW   equ 80

BAR_PERIOD      equ 40          ; Scanlines per bar cycle
BAR_HALF        equ 12          ; Gradient steps per bar half (colors 1-12)

RASTER_SIZE     equ 16          ; Scanlines per raster bar
NUM_RASTERS     equ 3

; Sine wave steps per scanline (different periods = morphing)
WAVE1_STEP      equ 3
WAVE2_STEP      equ 7
WAVE3_STEP      equ 13

; Phase advance per frame (different speeds = living motion)
WAVE1_SPEED     equ 1
WAVE2_SPEED     equ 2
WAVE3_SPEED     equ 3

; ============================================================================
; Entry Point
; ============================================================================
start:
    ; --- Set up graphics mode ---
    mov     ax, 0x0004          ; BIOS mode 4: sets CRTC timing
    int     0x10

    ; After INT 10h, restore segment registers
    push    cs
    pop     ds
    push    cs
    pop     es
    cld                         ; Ensure forward direction for string ops

    ; V6355D configuration
    mov     dx, PORT_REG_ADDR
    mov     al, 0x67            ; Register 0x67: bus config
    out     dx, al
    jmp     short $+2
    mov     dx, PORT_REG_DATA
    mov     al, 0x18            ; 8-bit bus, CRT timing
    out     dx, al
    jmp     short $+2

    mov     dx, PORT_REG_ADDR
    mov     al, 0x65            ; Register 0x65: monitor config
    out     dx, al
    jmp     short $+2
    mov     dx, PORT_REG_DATA
    mov     al, 0x09            ; 200 lines, PAL/50Hz
    out     dx, al
    jmp     short $+2

    mov     dx, PORT_MODE
    mov     al, 0x4A            ; Unlock 16-color mode
    out     dx, al
    jmp     short $+2

    ; --- Set palette ---
    cli
    mov     dx, PORT_REG_ADDR
    mov     al, 0x40            ; Open palette write at entry 0
    out     dx, al
    jmp     short $+2
    jmp     short $+2

    mov     dx, PORT_REG_DATA
    mov     si, palette_data
    mov     cx, 32              ; 16 entries x 2 bytes
.pal_loop:
    lodsb
    out     dx, al
    jmp     short $+2
    loop    .pal_loop

    ; DO NOT close with 0x80 — keeps PORT_COLOR full-width!
    sti

    ; --- Clear VRAM ---
    mov     ax, VIDEO_SEG
    mov     es, ax
    xor     di, di
    xor     ax, ax
    mov     cx, 8192
    rep     stosw

    ; Restore ES = CS
    push    cs
    pop     es

    ; --- Set border to black ---
    mov     dx, PORT_COLOR
    xor     al, al
    out     dx, al

    ; --- Initialize animation state ---
    xor     ax, ax
    mov     [wave1_phase], al
    mov     [wave2_phase], al
    mov     [wave3_phase], al
    mov     [bar_scroll], al
    mov     [raster_phase], al

; ============================================================================
; Main Loop
; ============================================================================
main_loop:
    ; --- 1. Build raster color table (not timing critical) ---
    call    build_raster_table

    ; --- 2. Wait for VBLANK start ---
    mov     dx, PORT_STATUS
.vb_end:
    in      al, dx
    test    al, 0x08
    jnz     .vb_end
.vb_start:
    in      al, dx
    test    al, 0x08
    jz      .vb_start

    ; --- 3. Draw kefrens column (during VBLANK, ~3ms) ---
    call    draw_column

    ; --- 4. Animate phases ---
    mov     al, [wave1_phase]
    add     al, WAVE1_SPEED
    mov     [wave1_phase], al

    mov     al, [wave2_phase]
    add     al, WAVE2_SPEED
    mov     [wave2_phase], al

    mov     al, [wave3_phase]
    add     al, WAVE3_SPEED
    mov     [wave3_phase], al

    inc     byte [bar_scroll]
    cmp     byte [bar_scroll], BAR_PERIOD
    jb      .no_bar_wrap
    mov     byte [bar_scroll], 0
.no_bar_wrap:

    add     byte [raster_phase], 2

    ; --- 5. Check ESC ---
    in      al, 0x60
    cmp     al, 1
    je      .exit

    ; --- 6. Wait for VBLANK to END (beam at scanline 0) ---
    mov     dx, PORT_STATUS
.vb_wait_end:
    in      al, dx
    test    al, 0x08
    jnz     .vb_wait_end

    ; --- 7. Render rasters synced to HSYNC from scanline 0 ---
    call    render_rasters

    jmp     main_loop

.exit:
    mov     ax, 0x0003
    int     0x10
    mov     ax, 0x4C00
    int     0x21

; ============================================================================
; draw_column - Draw one column of kefrens bar pixels
;
; Uses 3 summed sine waves with running accumulators (no MUL needed).
; Wave 1 (broad sweep):  amplitude/2 → dominant shape
; Wave 2 (medium detail): amplitude/4 → adds undulation
; Wave 3 (fine shimmer):  amplitude/4 → adds complexity
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

    ; Initialize running sine accumulators from current phases
    mov     al, [wave1_phase]
    mov     [w1_acc], al
    mov     al, [wave2_phase]
    mov     [w2_acc], al
    mov     al, [wave3_phase]
    mov     [w3_acc], al

    xor     cx, cx              ; CX = y (0-199)

.scanline:
    ; ----- Sum 3 sine waves to get x position -----

    ; Wave 1 (broad) → /2
    xor     bh, bh
    mov     bl, [w1_acc]
    mov     al, [sine_table + bx]
    shr     al, 1               ; /2 → 0-60
    mov     dl, al              ; DL = wave1 contribution

    ; Wave 2 (medium) → /4
    mov     bl, [w2_acc]
    mov     al, [sine_table + bx]
    shr     al, 1
    shr     al, 1               ; /4 → 0-30
    add     dl, al              ; DL += wave2

    ; Wave 3 (fine) → /4
    mov     bl, [w3_acc]
    mov     al, [sine_table + bx]
    shr     al, 1
    shr     al, 1               ; /4 → 0-30
    add     dl, al              ; DL = total x (0-120)

    ; Center on screen with margin
    add     dl, 20              ; x range: 20-140 (within 0-159)

    ; ----- Advance accumulators for next scanline -----
    add     byte [w1_acc], WAVE1_STEP
    add     byte [w2_acc], WAVE2_STEP
    add     byte [w3_acc], WAVE3_STEP

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

    ; Color from gradient position
    cmp     ax, BAR_HALF
    jae     .not_asc
    inc     al                  ; Ascending: colors 1..12
    jmp     .got_color
.not_asc:
    cmp     ax, BAR_HALF * 2
    jae     .is_gap
    neg     ax
    add     ax, BAR_HALF * 2    ; Descending: colors 12..1
    jmp     .got_color
.is_gap:
    xor     al, al              ; Gap: color 0 (shows raster background)
.got_color:
    mov     dh, al              ; DH = color, DL = x

    ; ----- Calculate VRAM offset -----
    mov     ax, cx              ; AX = y
    shr     ax, 1               ; AX = y / 2
    mov     bp, BYTES_PER_ROW
    push    dx                  ; Save DH=color, DL=x
    mul     bp                  ; AX = (y/2) * 80, DX trashed
    pop     dx                  ; Restore DH=color, DL=x
    mov     di, ax              ; DI = row offset
    test    cl, 1
    jz      .even_row
    add     di, 0x2000          ; Odd rows in bank 2
.even_row:
    mov     al, dl              ; AL = x
    xor     ah, ah
    shr     ax, 1               ; byte = x / 2
    add     di, ax              ; DI = VRAM byte offset

    ; ----- Read-modify-write the target nibble -----
    mov     al, [es:di]
    test    dl, 1               ; Odd x?
    jnz     .odd_px

    ; Even x → high nibble
    and     al, 0x0F
    mov     ah, dh
    shl     ah, 4
    or      al, ah
    jmp     short .write_px

.odd_px:
    ; Odd x → low nibble
    and     al, 0xF0
    or      al, dh

.write_px:
    mov     [es:di], al

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
; Simple loop-based approach (no REP STOSB, no signed comparisons).
; Draws 3 raster bars using a small gradient lookup table.
; ============================================================================
build_raster_table:
    push    ax
    push    bx
    push    cx
    push    di
    push    si

    ; Clear table to 0 using simple loop
    mov     di, raster_colors
    mov     cx, SCREEN_HEIGHT
.clear:
    mov     byte [di], 0
    inc     di
    loop    .clear

    ; Draw 3 raster bars
    mov     ch, NUM_RASTERS     ; Outer counter in CH
    mov     cl, [raster_phase]  ; CL = phase for first bar

.rbar_loop:
    ; Look up Y position from sine table
    xor     bh, bh
    mov     bl, cl              ; BL = phase index (0-255)
    mov     al, [raster_pos_table + bx]  ; AL = Y center (10-190)
    xor     ah, ah
    mov     si, ax              ; SI = Y center

    ; Draw bar: 16 pixels centered at SI
    push    cx                  ; Save CH=bar count, CL=phase
    mov     cx, RASTER_SIZE     ; CX = 16
    mov     di, si
    sub     di, RASTER_SIZE / 2 ; DI = Y start (center - 8)
    xor     bx, bx              ; BX = index into gradient

.rbar_pixel:
    ; Unsigned bounds check: if DI >= 200, skip (catches negative wrap too)
    cmp     di, SCREEN_HEIGHT
    jae     .rbar_skip

    ; Only write if slot is empty
    cmp     byte [raster_colors + di], 0
    jne     .rbar_skip

    mov     al, [rbar_gradient + bx]
    mov     [raster_colors + di], al

.rbar_skip:
    inc     di
    inc     bx
    loop    .rbar_pixel

    pop     cx                  ; Restore CH=bar count, CL=phase
    add     cl, 85              ; Next bar: phase + 85 (~120 degrees)
    dec     ch
    jnz     .rbar_loop

    pop     si
    pop     di
    pop     cx
    pop     bx
    pop     ax
    ret

; ============================================================================
; render_rasters - Output PORT_COLOR per scanline
;
; Matches the working pattern from rbars7.asm exactly.
; Uses DX-based OUT to PORT_COLOR (16-bit port address via DX).
; ============================================================================
render_rasters:
    push    ax
    push    bx
    push    cx
    push    dx
    push    si

    cli

    mov     si, raster_colors
    xor     bx, bx
    mov     cx, SCREEN_HEIGHT

.scanline_loop:
    ; Wait for HSYNC low then high (edge detection)
    mov     dx, PORT_STATUS
.wait_low:
    in      al, dx
    test    al, 0x01
    jnz     .wait_low
.wait_high:
    in      al, dx
    test    al, 0x01
    jz      .wait_high

    ; Output color via DX (matching rbars7 pattern)
    mov     dx, PORT_COLOR
    mov     al, [si + bx]
    out     dx, al

    inc     bx
    dec     cx
    jnz     .scanline_loop

    ; Reset border to black
    xor     al, al
    out     dx, al

    sti

    pop     si
    pop     dx
    pop     cx
    pop     bx
    pop     ax
    ret

; ============================================================================
; Data Section
; ============================================================================

; --- Animation state ---
wave1_phase     db 0
wave2_phase     db 0
wave3_phase     db 0
bar_scroll      db 0
raster_phase    db 0

; --- Running sine accumulators (used within draw_column) ---
w1_acc          db 0
w2_acc          db 0
w3_acc          db 0

; --- Raster bar gradient (16 entries: up 1-8, down 8-1) ---
rbar_gradient:
    db 1, 2, 3, 4, 5, 6, 7, 8, 8, 7, 6, 5, 4, 3, 2, 1

; --- Pre-computed raster colors (1 byte per scanline) ---
raster_colors:  times SCREEN_HEIGHT db 0

; --- Copper Gradient Palette (16 entries x 2 bytes = 32 bytes) ---
;   Entry 0: Black (overridden by PORT_COLOR per scanline)
;   Entries 1-12: Copper bar gradient (kefrens pixels)
;   Entries 13-15: Extra (unused in kefrens, available for raster)
palette_data:
    db 0, 0x00                  ;  0: Black
    db 1, 0x00                  ;  1: Very dark red
    db 2, 0x00                  ;  2: Dark red
    db 3, 0x01                  ;  3: Medium red
    db 4, 0x10                  ;  4: Red-orange
    db 5, 0x10                  ;  5: Bright red-orange
    db 5, 0x20                  ;  6: Orange
    db 6, 0x30                  ;  7: Bright amber
    db 7, 0x40                  ;  8: Gold
    db 7, 0x51                  ;  9: Bright gold
    db 7, 0x62                  ; 10: Yellow
    db 7, 0x73                  ; 11: Bright yellow
    db 7, 0x76                  ; 12: Near-white (peak)
    db 0, 0x02                  ; 13: Dark blue
    db 0, 0x04                  ; 14: Medium blue
    db 0, 0x07                  ; 15: Bright blue

; --- Kefrens Sine Table (256 entries, values 0-120) ---
; sine[i] = round(60 + 60 * sin(2pi * i / 256))
; Range 0-120. draw_column scales:
;   Wave 1: /2 → 0-60   (dominant)
;   Wave 2: /4 → 0-30   (medium)
;   Wave 3: /4 → 0-30   (fine)
; Total max: 60+30+30 = 120, plus 20 margin = 140 (safe within 160)
sine_table:
    db 60, 61, 63, 64, 66, 67, 69, 70, 72, 73, 75, 76, 77, 79, 80, 81
    db 83, 84, 85, 86, 88, 89, 90, 91, 92, 93, 94, 95, 96, 97, 98, 99
    db 100, 100, 101, 102, 103, 103, 104, 104, 105, 105, 106, 106, 107, 107, 107, 108
    db 108, 108, 109, 109, 109, 109, 109, 110, 110, 110, 110, 110, 110, 110, 110, 110
    db 110, 110, 110, 110, 110, 110, 110, 110, 110, 109, 109, 109, 109, 109, 108, 108
    db 108, 107, 107, 107, 106, 106, 105, 105, 104, 104, 103, 103, 102, 101, 100, 100
    db 99, 98, 97, 96, 95, 94, 93, 92, 91, 90, 89, 88, 86, 85, 84, 83
    db 81, 80, 79, 77, 76, 75, 73, 72, 70, 69, 67, 66, 64, 63, 61, 60
    db 60, 59, 57, 56, 54, 53, 51, 50, 48, 47, 45, 44, 43, 41, 40, 39
    db 37, 36, 35, 34, 32, 31, 30, 29, 28, 27, 26, 25, 24, 23, 22, 21
    db 20, 20, 19, 18, 17, 17, 16, 16, 15, 15, 14, 14, 13, 13, 13, 12
    db 12, 12, 11, 11, 11, 11, 11, 10, 10, 10, 10, 10, 10, 10, 10, 10
    db 10, 10, 10, 10, 10, 10, 10, 10, 10, 11, 11, 11, 11, 11, 12, 12
    db 12, 13, 13, 13, 14, 14, 15, 15, 16, 16, 17, 17, 18, 19, 20, 20
    db 21, 22, 23, 24, 25, 26, 27, 28, 29, 30, 31, 32, 34, 35, 36, 37
    db 39, 40, 41, 43, 44, 45, 47, 48, 50, 51, 53, 54, 56, 57, 59, 60

; --- Raster Bar Position Table (256 entries, values 16-184) ---
; Vertical position for raster bars. Sine wave centered at 100.
; raster_pos[i] = round(100 + 84 * sin(2pi * i / 256))
raster_pos_table:
    db 100, 102, 104, 106, 108, 110, 112, 114, 116, 118, 120, 122, 124, 126, 128, 130
    db 131, 133, 135, 137, 138, 140, 141, 143, 144, 146, 147, 148, 150, 151, 152, 153
    db 154, 155, 156, 157, 158, 158, 159, 160, 160, 161, 161, 162, 162, 162, 163, 163
    db 163, 163, 163, 163, 163, 163, 163, 163, 163, 163, 162, 162, 162, 161, 161, 160
    db 160, 159, 158, 158, 157, 156, 155, 154, 153, 152, 151, 150, 148, 147, 146, 144
    db 143, 141, 140, 138, 137, 135, 133, 131, 130, 128, 126, 124, 122, 120, 118, 116
    db 114, 112, 110, 108, 106, 104, 102, 100, 98, 96, 94, 92, 90, 88, 86, 84
    db 82, 80, 78, 76, 74, 72, 70, 69, 67, 65, 63, 62, 60, 59, 57, 56
    db 54, 53, 52, 50, 49, 48, 47, 46, 45, 44, 43, 42, 42, 41, 40, 40
    db 39, 39, 38, 38, 38, 37, 37, 37, 37, 37, 37, 37, 37, 37, 37, 37
    db 38, 38, 38, 39, 39, 40, 40, 41, 42, 42, 43, 44, 45, 46, 47, 48
    db 49, 50, 52, 53, 54, 56, 57, 59, 60, 62, 63, 65, 67, 69, 70, 72
    db 74, 76, 78, 80, 82, 84, 86, 88, 90, 92, 94, 96, 98, 100, 102, 104
    db 106, 108, 110, 112, 114, 116, 118, 120, 122, 124, 126, 128, 130, 131, 133, 135
    db 137, 138, 140, 141, 143, 144, 146, 147, 148, 150, 151, 152, 153, 154, 155, 156
    db 157, 158, 158, 159, 160, 160, 161, 161, 162, 162, 162, 163, 163, 163, 163, 163
