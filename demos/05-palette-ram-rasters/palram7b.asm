; ============================================================================
; PALRAM7B.ASM - Dancing Palette RAM Raster Bars in CGA Mode 4 (320x200x4)
; Two animated sine-wave raster bars with 3D depth-swap effect
; Written for NASM - NEC V40 (80186 compatible) @ 8 MHz
; By Retro Erik - 2026 with help from GitHub Copilot
;
; Target: Olivetti PC1 with Yamaha V6355D video controller
; Video Mode: CGA Mode 4 (320x200, 4 colors) - STANDARD CGA MODE
;
; PURPOSE:
;   Dancing palette RAM raster bars on a black background in standard
;   CGA mode 4. Uses the same raster bar engine as palram7 but without
;   BMP loading — a standalone demo of the technique.
;
;   V6355D palette RAM is confirmed mode-independent (palram8 finding,
;   March 2026), so all palette RAM techniques work identically in
;   CGA mode 4 (320x200) as in the hidden 160x200x16 mode.
;
; BASED ON: palram7.asm (BMP + palette RAM raster bars)
;
; CHANGES FROM PALRAM7:
;   - Video mode: CGA mode 4 (320x200x4) via int 0x10
;   - Video segment: 0xB800 (standard CGA) instead of 0xB000
;   - No BMP loading, no file I/O, no command line parsing
;   - Screen filled with color 0 (background = raster bar canvas)
;   - Background color is black (R=0, G|B=0) instead of BMP color 0
;   - All raster bar logic, OUTSB, skip-if-same identical to palram7
;
; TECHNIQUE:
;   - Two sine-wave bouncing raster bars (red + cyan)
;   - Bars swap depth order when crossing (3D illusion)
;   - Per-scanline palette RAM writes redefine color 0's RGB value
;   - OUTSB burst writes for minimal HBLANK jitter (~60 cycles)
;   - Skip-if-same: only writes when color changes between scanlines
;
; OPTIMIZATIONS (from palram7/demo1b):
;   - Short port addresses: 0xDA/0xDD/0xDE (saves ~4 cycles per OUT)
;   - Immediate port I/O for status: in al, 0xDA (frees DX for OUTSB)
;   - OUTSB burst writes: 3-byte pal_cmd buffer streamed via OUTSB
;   - Skip-if-same: no port writes when color unchanged between scanlines
;   - Pre-load pal_cmd before HSYNC wait (setup during free time)
;   - Critical HBLANK path: ~60 clocks total
;
; Controls:
;   Any key - Exit to DOS
; ============================================================================

[BITS 16]
[CPU 186]                       ; NEC V40 is 80186 compatible (enables OUTSB)
[ORG 0x100]

; ============================================================================
; Constants
; ============================================================================

; Video Memory
VIDEO_SEG       equ 0xB800      ; Standard CGA video RAM segment

; Yamaha V6355D I/O Ports (short aliases)
PORT_REG_ADDR   equ 0xDD        ; Palette register address (open/close)
PORT_REG_DATA   equ 0xDE        ; Palette register data (R, G|B values)
PORT_STATUS     equ 0xDA        ; Status (bit 0=hsync, bit 3=vblank)

; Screen parameters
SCREEN_HEIGHT   equ 200

; ============================================================================
; RASTER BAR CONFIGURATION
; ============================================================================

LINES_PER_COLOR equ 2           ; Scanlines per gradient color (1=thin, 3=thick)
BAR_HEIGHT      equ 14 * LINES_PER_COLOR  ; Total bar height (7 colors x 2 directions)

; Per-bar speed (higher = faster wobble)
BAR1_SPEED      equ 2
BAR2_SPEED      equ 3

; Per-bar center position
BAR1_CENTER     equ 100
BAR2_CENTER     equ 100

; Per-bar starting phase (0-255)
BAR1_PHASE      equ 0
BAR2_PHASE      equ 85          ; 1/3 cycle offset (120 degrees)

; Shared amplitude
SINE_AMPLITUDE  equ 50

; ============================================================================
; Main Program Entry Point
; ============================================================================
main:
    ; Set CGA mode 4 (320x200, 4 colors) via BIOS
    mov ax, 0x0004
    int 0x10

    ; Clear screen to color 0 (raster bars will redefine this color)
    call clear_screen

    ; Initialize bar sine indices with starting phases
    mov byte [bar1_sine_idx], BAR1_PHASE
    mov byte [bar2_sine_idx], BAR2_PHASE

    ; ========================================================================
    ; Raster bar animation loop
    ; ========================================================================
.main_loop:
    ; Update bar 1 sine index and calculate Y position
    add byte [bar1_sine_idx], BAR1_SPEED
    mov al, [bar1_sine_idx]
    xor ah, ah
    mov si, ax
    mov al, [sine_table + si]
    add al, BAR1_CENTER
    sub al, SINE_AMPLITUDE
    mov [bar1_y], al

    ; Update bar 2 sine index and calculate Y position
    add byte [bar2_sine_idx], BAR2_SPEED
    mov al, [bar2_sine_idx]
    xor ah, ah
    mov si, ax
    mov al, [sine_table + si]
    add al, BAR2_CENTER
    sub al, SINE_AMPLITUDE
    mov [bar2_y], al

    ; Detect crossing for 3D effect
    mov al, [bar1_y]
    cmp al, [bar2_y]
    jae .bar1_in_front
    mov byte [front_bar], 0         ; Cyan in front
    jmp .build_table
.bar1_in_front:
    mov byte [front_bar], 1         ; Red in front

.build_table:
    ; Build scanline table BEFORE waiting - we have time during display
    call build_scanline_table

    ; Wait for vblank to end (display starts) and immediately render
    call wait_vblank
    call render_raster_bars

    ; Check for keypress
    mov ah, 0x01
    int 0x16
    jz .main_loop

    ; Exit - consume key
    mov ah, 0x00
    int 0x16

    ; Restore CGA palette for clean text mode transition
    call set_cga_palette

    ; Restore text mode
    mov ax, 0x0003
    int 0x10

    mov ax, 0x4C00
    int 0x21

; ============================================================================
; build_scanline_table - Pre-compute palette RGB pairs for all 200 scanlines
; Each entry is 2 bytes: R, G|B (V6355D palette format)
; Non-bar scanlines get black (R=0, G|B=0)
; ============================================================================
build_scanline_table:
    push ax
    push bx
    push cx
    push di

    ; Fill table with black (no bar = black background)
    mov di, scanline_colors
    xor ax, ax              ; R=0, G|B=0 (black)
    mov cx, SCREEN_HEIGHT
.clear_loop:
    mov [di], ax
    add di, 2
    loop .clear_loop

    ; Check which bar should be in front (drawn last = on top)
    cmp byte [front_bar], 0
    jnz .red_in_front

    ; Cyan in front: draw red first, then cyan on top
    call draw_red_bar
    call draw_cyan_bar
    jmp .done_drawing

.red_in_front:
    call draw_cyan_bar
    call draw_red_bar

.done_drawing:
    pop di
    pop cx
    pop bx
    pop ax
    ret

; ----------------------------------------------------------------------------
; draw_red_bar - Draw bar 1 (red gradient) into scanline table
; ----------------------------------------------------------------------------
draw_red_bar:
    push ax
    push bx
    push cx
    push si

    mov al, [bar1_y]
    xor ah, ah
    mov bx, ax
    shl bx, 1              ; BX = Y x 2 (2 bytes per entry)
    mov si, red_gradient
    mov cx, BAR_HEIGHT

.draw_loop:
    cmp bx, SCREEN_HEIGHT * 2
    jb .in_range
    sub bx, SCREEN_HEIGHT * 2
.in_range:
    mov ax, [si]
    mov [scanline_colors + bx], ax
    add bx, 2
    add si, 2
    loop .draw_loop

    pop si
    pop cx
    pop bx
    pop ax
    ret

; ----------------------------------------------------------------------------
; draw_cyan_bar - Draw bar 2 (cyan gradient) into scanline table
; ----------------------------------------------------------------------------
draw_cyan_bar:
    push ax
    push bx
    push cx
    push si

    mov al, [bar2_y]
    xor ah, ah
    mov bx, ax
    shl bx, 1
    mov si, cyan_gradient
    mov cx, BAR_HEIGHT

.draw_loop:
    cmp bx, SCREEN_HEIGHT * 2
    jb .in_range
    sub bx, SCREEN_HEIGHT * 2
.in_range:
    mov ax, [si]
    mov [scanline_colors + bx], ax
    add bx, 2
    add si, 2
    loop .draw_loop

    pop si
    pop cx
    pop bx
    pop ax
    ret

; ============================================================================
; render_raster_bars - Per-scanline palette RAM changes via OUTSB
;
; Optimized register plan:
;   DX = PORT_REG_ADDR (0xDD) permanently, used by OUTSB and close-write
;   SI = scanline_colors pointer (swapped to pal_cmd only for OUTSB burst)
;   BH/BL = previously written R/GB bytes (skip write if unchanged)
;   CX = line counter
;   Status polling via immediate port: in al, PORT_STATUS (0xDA)
;
; Critical hblank path (write case): ~60 clocks
;   outsb(14) + inc dx(3) + outsb(14) + outsb(14) +
;   dec dx(3) + mov al,0x80(4) + out dx,al(8)
; Skip case: 0 port writes
; ============================================================================
render_raster_bars:
    push ax
    push bx
    push cx
    push dx
    push si

    cli

    mov si, scanline_colors
    mov cx, SCREEN_HEIGHT
    mov dx, PORT_REG_ADDR   ; DX stays 0xDD for OUTSB + close

    ; Init BH:BL to impossible value so first scanline always writes
    mov bx, 0xFFFF

.scanline_loop:
    ; Pre-fetch color for this scanline (during active display - uncritical)
    mov ah, [si]            ; AH = new R
    mov al, [si + 1]        ; AL = new G|B
    add si, 2

    ; Compare new (AH,AL) vs current (BH,BL) - skip if unchanged
    cmp ax, bx
    je .skip_write

    ; Color changed - update tracking and prepare OUTSB buffer
    mov bx, ax
    mov [pal_cmd + 1], bh   ; R byte
    mov [pal_cmd + 2], bl   ; G|B byte

    ; Park SI, load pal_cmd for OUTSB (before HSYNC wait - free time)
    mov [saved_si], si
    mov si, pal_cmd

    ; Wait for HSYNC to go LOW (visible line being drawn)
.wait_low:
    in al, PORT_STATUS
    test al, 0x01
    jnz .wait_low

    ; Wait for HSYNC to go HIGH (HBLANK begins)
.wait_high:
    in al, PORT_STATUS
    test al, 0x01
    jz .wait_high

    ; --- Critical HBLANK path: OUTSB burst (~60 clocks) ---
    outsb                   ; 14 - OUT 0xDD, 0x40 (open palette, entry 0)
    inc dx                  ; 3  - DX = 0xDE (PORT_REG_DATA)
    outsb                   ; 14 - OUT 0xDE, R byte
    outsb                   ; 14 - OUT 0xDE, G|B byte
    dec dx                  ; 3  - DX = 0xDD (PORT_REG_ADDR)
    mov al, 0x80            ; 4
    out dx, al              ; 8  - close palette write window

    ; Restore scanline pointer
    mov si, [saved_si]
    jmp .next_line

.skip_write:
    ; Same color - just wait for scanline to pass
.wait_low2:
    in al, PORT_STATUS
    test al, 0x01
    jnz .wait_low2
.wait_high2:
    in al, PORT_STATUS
    test al, 0x01
    jz .wait_high2

.next_line:
    dec cx
    jnz .scanline_loop

    ; Reset palette entry 0 to black for clean top-of-frame
    mov al, 0x40
    out dx, al
    xor al, al
    out PORT_REG_DATA, al
    out PORT_REG_DATA, al
    mov al, 0x80
    out dx, al

    sti

    pop si
    pop dx
    pop cx
    pop bx
    pop ax
    ret

; ============================================================================
; wait_vblank - Wait for vertical blanking interval
; ============================================================================
wait_vblank:
    push ax

.wait_end:
    in al, PORT_STATUS
    test al, 0x08
    jnz .wait_end

.wait_start:
    in al, PORT_STATUS
    test al, 0x08
    jz .wait_start

    pop ax
    ret

; ============================================================================
; clear_screen - Fill CGA video memory with color 0
; ============================================================================
clear_screen:
    push ax
    push cx
    push di
    push es

    mov ax, VIDEO_SEG
    mov es, ax
    xor di, di
    mov cx, 8192            ; 16384 / 2
    xor ax, ax
    cld
    rep stosw

    pop es
    pop di
    pop cx
    pop ax
    ret

; ============================================================================
; set_cga_palette - Reset palette to standard CGA text mode colors
; ============================================================================
set_cga_palette:
    push ax
    push cx
    push si

    cli

    mov al, 0x40
    out PORT_REG_ADDR, al
    jmp short $+2

    mov si, cga_colors
    mov cx, 32

.pal_write_loop:
    lodsb
    out PORT_REG_DATA, al
    jmp short $+2
    loop .pal_write_loop

    mov al, 0x80
    out PORT_REG_ADDR, al

    sti

    pop si
    pop cx
    pop ax
    ret

; ============================================================================
; Data Section
; ============================================================================

; Raster bar state
bar1_y:         db 0
bar2_y:         db 0
bar1_sine_idx:  db BAR1_PHASE
bar2_sine_idx:  db BAR2_PHASE
front_bar:      db 0

; OUTSB command buffer: [0x40, R, G|B]
pal_cmd         db 0x40, 0, 0
saved_si        dw 0

; ============================================================================
; RGB333 Gradient Tables - 2 bytes per entry (R, G|B)
; ============================================================================

; Red gradient: R=1->7->1, G=0, B=0
red_gradient:
%assign i 1
%rep 7
    times LINES_PER_COLOR db i, 0x00
%assign i i+1
%endrep
%assign i 7
%rep 7
    times LINES_PER_COLOR db i, 0x00
%assign i i-1
%endrep

; Cyan gradient: R=0, G=1->7->1, B=1->7->1
cyan_gradient:
%assign i 1
%rep 7
    times LINES_PER_COLOR db 0x00, (i << 4) | i
%assign i i+1
%endrep
%assign i 7
%rep 7
    times LINES_PER_COLOR db 0x00, (i << 4) | i
%assign i i-1
%endrep

; Pre-computed scanline RGB pairs (200 entries x 2 bytes = 400 bytes)
scanline_colors: times SCREEN_HEIGHT * 2 db 0

; Sine table (256 entries, values 0-100)
sine_table:
    db 50, 51, 52, 53, 55, 56, 57, 58, 59, 61, 62, 63, 64, 65, 66, 68
    db 69, 70, 71, 72, 73, 74, 75, 76, 77, 78, 79, 80, 81, 82, 83, 84
    db 84, 85, 86, 87, 87, 88, 89, 89, 90, 90, 91, 91, 92, 92, 93, 93
    db 94, 94, 94, 95, 95, 95, 96, 96, 96, 96, 97, 97, 97, 97, 97, 97
    db 97, 97, 97, 97, 97, 97, 97, 97, 96, 96, 96, 96, 95, 95, 95, 94
    db 94, 94, 93, 93, 92, 92, 91, 91, 90, 90, 89, 89, 88, 87, 87, 86
    db 85, 84, 84, 83, 82, 81, 80, 79, 78, 77, 76, 75, 74, 73, 72, 71
    db 70, 69, 68, 66, 65, 64, 63, 62, 61, 59, 58, 57, 56, 55, 53, 52
    db 50, 49, 48, 47, 45, 44, 43, 42, 41, 39, 38, 37, 36, 35, 34, 32
    db 31, 30, 29, 28, 27, 26, 25, 24, 23, 22, 21, 20, 19, 18, 17, 16
    db 16, 15, 14, 13, 13, 12, 11, 11, 10, 10,  9,  9,  8,  8,  7,  7
    db  6,  6,  6,  5,  5,  5,  4,  4,  4,  4,  3,  3,  3,  3,  3,  3
    db  3,  3,  3,  3,  3,  3,  3,  3,  4,  4,  4,  4,  5,  5,  5,  6
    db  6,  6,  7,  7,  8,  8,  9,  9, 10, 10, 11, 11, 12, 13, 13, 14
    db 15, 16, 16, 17, 18, 19, 20, 21, 22, 23, 24, 25, 26, 27, 28, 29
    db 30, 31, 32, 34, 35, 36, 37, 38, 39, 41, 42, 43, 44, 45, 47, 48

; Standard CGA palette for exit
cga_colors:
    db 0x00, 0x00    ; 0:  Black
    db 0x00, 0x05    ; 1:  Blue
    db 0x00, 0x50    ; 2:  Green
    db 0x00, 0x55    ; 3:  Cyan
    db 0x05, 0x00    ; 4:  Red
    db 0x05, 0x05    ; 5:  Magenta
    db 0x05, 0x20    ; 6:  Brown
    db 0x05, 0x55    ; 7:  Light Gray
    db 0x02, 0x22    ; 8:  Dark Gray
    db 0x02, 0x27    ; 9:  Light Blue
    db 0x02, 0x72    ; 10: Light Green
    db 0x02, 0x77    ; 11: Light Cyan
    db 0x07, 0x22    ; 12: Light Red
    db 0x07, 0x27    ; 13: Light Magenta
    db 0x07, 0x70    ; 14: Yellow
    db 0x07, 0x77    ; 15: White

; ============================================================================
; End of Program
; ============================================================================
