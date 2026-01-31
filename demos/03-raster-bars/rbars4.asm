; ============================================================================
; RBARS4.ASM - Two-Bar Vertical Movement Demo for Olivetti Prodest PC1
; Two independently moving raster bars with red and green gradients
; Written for NASM - NEC V40 (80186 compatible) @ 8 MHz
; By Retro Erik - 2026 with help from GitHub Copilot
;
; Target: Olivetti PC1 with Yamaha V6355D video controller
; Video Mode: CGA 160x200x16 (Hidden mode)
;
; Technique:
;   - Changes PORT_COLOR per scanline during hsync
;   - Two bars with independent vertical positions
;   - Bar 1: Red gradient (palette colors 1-7)
;   - Bar 2: Green gradient (palette colors 8-14)
;   - Bars slide up/down with different speeds
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
; Constants - Hardware definitions
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
; RASTER BAR CONFIGURATION - Adjust these values to customize appearance
; ============================================================================

LINES_PER_COLOR equ 2           ; Scanlines per gradient color (1=thin, 3=thick)
BAR_HEIGHT      equ 14 * LINES_PER_COLOR  ; Total bar height (7 colors * 2 directions)

BAR1_SPEED      equ 2           ; Bar 1 vertical speed (pixels per frame)
BAR2_SPEED      equ 3           ; Bar 2 vertical speed (pixels per frame)

BAR1_START      equ 20          ; Bar 1 starting Y position
BAR2_START      equ 120         ; Bar 2 starting Y position

; ============================================================================
; Main Program
; ============================================================================
main:
    call enable_graphics_mode
    call set_palette
    call clear_screen
    
    ; Initialize bar positions
    mov byte [bar1_y], BAR1_START
    mov byte [bar2_y], BAR2_START

.main_loop:
    call wait_vblank
    
    ; Update bar 1 position (moving down)
    mov al, [bar1_y]
    add al, BAR1_SPEED
    cmp al, SCREEN_HEIGHT
    jb .bar1_ok
    xor al, al                  ; Wrap to top
.bar1_ok:
    mov [bar1_y], al
    
    ; Update bar 2 position (moving down, different speed)
    mov al, [bar2_y]
    add al, BAR2_SPEED
    cmp al, SCREEN_HEIGHT
    jb .bar2_ok
    xor al, al                  ; Wrap to top
.bar2_ok:
    mov [bar2_y], al
    
    ; Build the scanline color table for this frame
    call build_scanline_table
    
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
; build_scanline_table - Pre-compute colors for all 200 scanlines
; Creates the color for each scanline based on bar positions
; Called during vblank - timing not critical
; ============================================================================
build_scanline_table:
    push ax
    push bx
    push cx
    push dx
    push si
    push di
    
    ; Clear table to black
    mov di, scanline_colors
    mov cx, SCREEN_HEIGHT
    xor al, al
    rep stosb
    
    ; Draw bar 1 (red gradient, palette 1-7)
    mov al, [bar1_y]
    xor ah, ah
    mov di, ax                  ; DI = bar 1 Y position
    mov si, red_gradient
    mov cx, BAR_HEIGHT
    
.draw_bar1:
    cmp di, SCREEN_HEIGHT
    jb .bar1_in_range
    sub di, SCREEN_HEIGHT       ; Wrap around
.bar1_in_range:
    mov al, [si]
    mov [scanline_colors + di], al
    inc di
    inc si
    loop .draw_bar1
    
    ; Draw bar 2 (green gradient, palette 8-14)
    mov al, [bar2_y]
    xor ah, ah
    mov di, ax                  ; DI = bar 2 Y position
    mov si, green_gradient
    mov cx, BAR_HEIGHT
    
.draw_bar2:
    cmp di, SCREEN_HEIGHT
    jb .bar2_in_range
    sub di, SCREEN_HEIGHT       ; Wrap around
.bar2_in_range:
    mov al, [si]
    mov [scanline_colors + di], al
    inc di
    inc si
    loop .draw_bar2
    
    pop di
    pop si
    pop dx
    pop cx
    pop bx
    pop ax
    ret

; ============================================================================
; render_raster_bars - Per-scanline color changes via PORT_COLOR
; Outputs one color per scanline from the pre-computed table
; Timing-critical: runs with interrupts disabled
; ============================================================================
render_raster_bars:
    push ax
    push bx
    push dx
    push si
    
    cli
    
    mov si, scanline_colors     ; SI = pointer to color table
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
    
    ; Output color from pre-computed table
    mov al, [si]
    out PORT_COLOR, al
    
    inc si
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
; set_palette - Load red/green gradient palettes into V6355D
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
; Data Section
; ============================================================================

bar1_y:         db 0            ; Bar 1 vertical position (0-199)
bar2_y:         db 0            ; Bar 2 vertical position (0-199)

; Pre-computed scanline colors (built each frame during vblank)
scanline_colors: times SCREEN_HEIGHT db 0

; Red gradient pattern (palette indices 1-7, then 7-1)
; Auto-generated based on LINES_PER_COLOR
red_gradient:
%assign i 1
%rep 7
    times LINES_PER_COLOR db i
%assign i i+1
%endrep
%assign i 7
%rep 7
    times LINES_PER_COLOR db i
%assign i i-1
%endrep

; Green gradient pattern (palette indices 8-14, then 14-8)
; Auto-generated based on LINES_PER_COLOR
green_gradient:
%assign i 8
%rep 7
    times LINES_PER_COLOR db i
%assign i i+1
%endrep
%assign i 14
%rep 7
    times LINES_PER_COLOR db i
%assign i i-1
%endrep

; Palette with red gradient (1-7) and green gradient (8-14)
; Format: 2 bytes per color (Red, Green<<4|Blue)
palette_data:
    db 0x00, 0x00               ;  0: Black (background)
    ; Red gradient (colors 1-7)
    db 0x0F, 0x77               ;  1: Light pink (brightest red)
    db 0x0F, 0x55               ;  2: Pink
    db 0x0F, 0x33               ;  3: Light red
    db 0x0D, 0x22               ;  4: Red
    db 0x0A, 0x11               ;  5: Dark red
    db 0x07, 0x00               ;  6: Darker red
    db 0x04, 0x00               ;  7: Darkest red
    ; Green gradient (colors 8-14)
    db 0x07, 0xF7               ;  8: Light green-white (brightest)
    db 0x05, 0xF5               ;  9: Light green
    db 0x03, 0xD3               ; 10: Green
    db 0x02, 0xA2               ; 11: Medium green
    db 0x01, 0x71               ; 12: Dark green
    db 0x00, 0x50               ; 13: Darker green
    db 0x00, 0x30               ; 14: Darkest green
    db 0x00, 0x00               ; 15: Black (unused)

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
