; ============================================================================
; RBARS3.ASM - Color Cycling Raster Bar Demo for Olivetti Prodest PC1
; Horizontal scrolling raster bars with C64-style smooth color cycling
; Written for NASM - NEC V40 (80186 compatible) @ 8 MHz
; By Retro Erik - 2026 with help from GitHub Copilot
;
; Target: Olivetti PC1 with Yamaha V6355D video controller
; Video Mode: CGA 160x200x16 (Hidden mode)
;
; Technique:
;   - Changes PORT_COLOR per scanline during hsync
;   - Uses static precomputed pattern table (no per-frame calculation)
;   - Scroll offset advances each frame for smooth animation
;   - C64-style gradient cycling: rotates palette entries during vblank for liquid effect
;
; Controls:
;   Any key - Exit to DOS
;
; Prerequisites:
;   Run PERITEL.COM first to set horizontal position correctly
; ============================================================================

[BITS 16]
[ORG 0x100]

; ============================================================================
; Constants - EDIT THESE TO CUSTOMIZE THE DEMO
; ============================================================================

VIDEO_SEG       equ 0xB000      ; PC1 video RAM segment

; Yamaha V6355D I/O Ports
PORT_REG_ADDR   equ 0x3DD       ; Register address port
PORT_REG_DATA   equ 0x3DE       ; Register data port
PORT_MODE       equ 0x3D8       ; Mode control register
PORT_COLOR      equ 0x3D9       ; Color select (border/overscan color)
PORT_STATUS     equ 0x3DA       ; Status (bit 0=hsync, bit 3=vblank)

; Screen parameters
SCREEN_HEIGHT   equ 200         ; Visible scanlines
SCREEN_SIZE     equ 16384       ; Full video RAM (16KB)

; ============================================================================
; VBLANK WINDOW - Safe time for palette updates
; ============================================================================
;
; What is VBlank?
;   VBlank (vertical blanking) is the time between the last visible scanline
;   and when the electron beam returns to the top of the screen. During this
;   interval, no pixels are being drawn to the display.
;
; Why update palette during VBlank?
;   - The DAC (Digital-to-Analog Converter) is idle
;   - No VRAM fetches happening
;   - Palette register writes won't interfere with active display
;   - Changes are stable and glitch-free
;
; PC1 VBlank timing:
;   - Display: 200 visible scanlines (0-199)
;   - VBlank: Remaining scanlines until frame repeats (~56 scanlines)
;   - Total frame: ~256 scanlines
;   - Frame rate: ~50Hz (PAL CRT display)
;
; Detected via PORT_STATUS bit 3:
;   - bit 3 = 1: In VBlank (safe for palette updates)
;   - bit 3 = 0: Active display (avoid palette changes)
;
; ============================================================================
; RASTER BAR CONFIGURATION - Adjust these values to customize appearance
; ============================================================================

LINES_PER_COLOR   equ 2         ; Scanlines per gradient color (1=thin, 3=thick)
BLACK_SPACING     equ 18        ; Black lines between bars (more = more spacing)
BAR_SPEED         equ 1         ; Scroll speed per frame (1=smooth, 2+=faster)
COLOR_CYCLE_DELAY equ 8         ; Frames between palette rotations (higher=slower)

; Calculated constants (don't edit these)
GRADIENT_LINES  equ (7 * LINES_PER_COLOR)           ; Lines for one gradient (7 colors)
BAR_LINES       equ (GRADIENT_LINES * 2)            ; Full bar (up + down gradient)
BAR_SPACING     equ (BAR_LINES + BLACK_SPACING * 2) ; Total pattern cycle

; ============================================================================
; Main Program
; ============================================================================
main:
    call enable_graphics_mode
    call set_palette
    call clear_screen
    
    mov byte [bar_y_pos], 0
    mov byte [frame_counter], 0

.main_loop:
    call wait_vblank
    
    ; Update scroll position
    mov al, [bar_y_pos]
    add al, BAR_SPEED
    cmp al, BAR_SPACING
    jb .no_wrap
    xor al, al
.no_wrap:
    mov [bar_y_pos], al
    
    ; Color cycling - rotate palette every N frames
    mov al, [frame_counter]
    inc al
    cmp al, COLOR_CYCLE_DELAY
    jb .no_cycle
    xor al, al
    call rotate_palette         ; Rotate during vblank
.no_cycle:
    mov [frame_counter], al
    
    call render_raster_bars
    
    ; Check for keypress
    mov ah, 0x01
    int 0x16
    jz .main_loop
    
    ; Exit
    mov ah, 0x00
    int 0x16                    ; Consume key
    
    call restore_palette        ; Restore original palette before exit
    
    mov ax, 0x0003              ; Restore text mode
    int 0x10
    mov ax, 0x4C00
    int 0x21

; ============================================================================
; render_raster_bars - Per-scanline color changes via PORT_COLOR
; Outputs one color per scanline from the pattern table
; Timing-critical: runs with interrupts disabled
; ============================================================================
render_raster_bars:
    push ax
    push bx
    push dx
    push si
    
    cli
    
    ; SI = starting offset into pattern
    mov al, [bar_y_pos]
    xor ah, ah
    mov si, ax
    
    xor bx, bx                  ; BX = scanline counter
    mov dx, PORT_STATUS
    
.scanline_loop:
    ; Wait for hsync low
.wait_low:
    in al, dx
    test al, 0x01
    jnz .wait_low
    
    ; Wait for hsync high
.wait_high:
    in al, dx
    test al, 0x01
    jz .wait_high
    
    ; Output color from pattern table
    mov al, [static_pattern + si]
    out PORT_COLOR, al
    
    ; Advance pattern index with wrap
    inc si
    cmp si, BAR_SPACING
    jb .no_wrap
    xor si, si
.no_wrap:
    
    inc bx
    cmp bx, SCREEN_HEIGHT
    jb .scanline_loop
    
    ; Reset to black after frame
    xor al, al
    out PORT_COLOR, al
    
    sti
    
    pop si
    pop dx
    pop bx
    pop ax
    ret

; ============================================================================
; wait_vblank - Wait for vertical blanking interval
; ============================================================================
wait_vblank:
    push ax
    push dx
    
    mov dx, PORT_STATUS
    
.wait_end:
    in al, dx
    test al, 0x08
    jnz .wait_end
    
.wait_start:
    in al, dx
    test al, 0x08
    jz .wait_start
    
    pop dx
    pop ax
    ret

; ============================================================================
; enable_graphics_mode - Enable 160x200x16 hidden mode
; ============================================================================
enable_graphics_mode:
    push ax
    push dx
    
    mov dx, PORT_MODE
    mov al, 0x4A
    out dx, al
    
    pop dx
    pop ax
    ret

; ============================================================================
; clear_screen - Fill video RAM with color 0
; ============================================================================
clear_screen:
    push ax
    push cx
    push di
    push es
    
    mov ax, VIDEO_SEG
    mov es, ax
    xor di, di
    mov cx, SCREEN_SIZE / 2
    xor ax, ax
    cld
    rep stosw
    
    pop es
    pop di
    pop cx
    pop ax
    ret

; ============================================================================
; set_palette - Load warm gradient palette into V6355D
; ============================================================================
set_palette:
    push ax
    push cx
    push dx
    push si
    
    cli
    
    mov dx, PORT_REG_ADDR
    mov al, 0x40
    out dx, al
    
    mov dx, PORT_REG_DATA
    mov si, palette_data
    mov cx, 32                  ; 16 colors * 2 bytes
    
.pal_loop:
    lodsb
    out dx, al
    loop .pal_loop
    
    sti
    
    pop si
    pop dx
    pop cx
    pop ax
    ret

; ============================================================================
; restore_palette - Restore default CGA palette for text mode
; ============================================================================
restore_palette:
    push ax
    push cx
    push dx
    push si
    
    cli
    
    mov dx, PORT_REG_ADDR
    mov al, 0x40
    out dx, al
    
    mov dx, PORT_REG_DATA
    mov si, default_palette
    mov cx, 32                  ; 16 colors * 2 bytes
    
.pal_loop:
    lodsb
    out dx, al
    loop .pal_loop
    
    sti
    
    pop si
    pop dx
    pop cx
    pop ax
    ret

; ============================================================================
; rotate_palette - Rotate gradient colors 1-7 for liquid effect
; Called during vblank - timing not critical
; Rotates the working palette entries, then reloads to V6355D
; ============================================================================
rotate_palette:
    push ax
    push bx
    push cx
    push dx
    push si
    
    ; Save color 1 (will become color 7)
    mov ax, [palette_data + 2]      ; Color 1: bytes 2-3
    mov [temp_color], ax
    
    ; Shift colors 2-7 down to 1-6
    mov si, palette_data + 4        ; Start at color 2
    mov cx, 6                       ; Move 6 colors (2-7 -> 1-6)
.shift_loop:
    mov ax, [si]                    ; Get color N
    mov [si - 2], ax                ; Put at N-1
    add si, 2
    loop .shift_loop
    
    ; Put saved color 1 into position 7
    mov ax, [temp_color]
    mov [palette_data + 14], ax     ; Color 7: bytes 14-15
    
    ; Reload palette to V6355D
    cli
    
    mov dx, PORT_REG_ADDR
    mov al, 0x40
    out dx, al
    
    mov dx, PORT_REG_DATA
    mov si, palette_data
    mov cx, 32
    
.reload_loop:
    lodsb
    out dx, al
    loop .reload_loop
    
    sti
    
    pop si
    pop dx
    pop cx
    pop bx
    pop ax
    ret

; ============================================================================
; Data Section
; ============================================================================

bar_y_pos:      db 0            ; Current scroll position
frame_counter:  db 0            ; Frame counter for color cycle delay
temp_color:     dw 0            ; Temp storage for palette rotation

; Static pattern table - auto-generated from configuration constants
; Each entry = one scanline color (0=black, 1-7=gradient colors)
static_pattern:
    ; Gradient bright to dark (colors 1-7)
%assign i 1
%rep 7
    times LINES_PER_COLOR db i
%assign i i+1
%endrep
    ; Black spacing after first gradient
    times BLACK_SPACING db 0
    ; Gradient dark to bright (colors 7-1)
%assign i 7
%rep 7
    times LINES_PER_COLOR db i
%assign i i-1
%endrep
    ; Black spacing after second gradient
    times BLACK_SPACING db 0

; Warm gradient palette (16 colors, 2 bytes each: Red, Green<<4|Blue)
; Colors 1-7 are rotated for the liquid cycling effect
palette_data:
    db 0x00, 0x00               ;  0: Black (background)
    db 0x07, 0x77               ;  1: White (brightest)
    db 0x07, 0x72               ;  2: Light yellow
    db 0x07, 0x62               ;  3: Yellow
    db 0x06, 0x42               ;  4: Orange
    db 0x05, 0x31               ;  5: Dark orange
    db 0x04, 0x20               ;  6: Red-orange
    db 0x03, 0x10               ;  7: Dark red (darkest)
    times 16 db 0x00            ;  8-15: Reserved

; Default CGA-style palette for restoring on exit
default_palette:
    db 0x00, 0x00               ;  0: Black
    db 0x00, 0x07               ;  1: Blue
    db 0x00, 0x70               ;  2: Green
    db 0x00, 0x77               ;  3: Cyan
    db 0x07, 0x00               ;  4: Red
    db 0x07, 0x07               ;  5: Magenta
    db 0x07, 0x40               ;  6: Brown
    db 0x07, 0x77               ;  7: Light gray
    db 0x03, 0x33               ;  8: Dark gray
    db 0x03, 0x3F               ;  9: Light blue
    db 0x03, 0xF3               ; 10: Light green
    db 0x03, 0xFF               ; 11: Light cyan
    db 0x0F, 0x33               ; 12: Light red
    db 0x0F, 0x3F               ; 13: Light magenta
    db 0x0F, 0xF3               ; 14: Yellow
    db 0x0F, 0xFF               ; 15: White

; ============================================================================
; End of Program
; ============================================================================
