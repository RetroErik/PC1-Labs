; ============================================================================
; RBARS4.ASM - Raster Bar Demo v4: Independent Multi-Bar Motion
; Two independently moving raster bars with sine-wave wobble motion
; Written for NASM - NEC V40 (80186 compatible) @ 8 MHz
; By Retro Erik - 2026
;
; Target: Olivetti PC1 with Yamaha V6355D video controller
; Video Mode: CGA 160x200x16 (Hidden mode)
;
; ============================================================================
; WHY THIS DEMO SHOWS FULL-WIDTH BARS - Critical Discovery
; ============================================================================
;
; ** MAJOR DISCOVERY **
; Full-width PORT_COLOR is the DEFAULT state after boot!
; Writing 0x80 to PORT_REG_ADDR LOCKS it to border-only mode.
; Writing 0x40 to PORT_REG_ADDR UNLOCKS full-width mode again.
;
; This demo works full-width because:
;   1. set_palette writes 0x40 to port 0xDD to start palette write
;   2. We do NOT write 0x80 at the end (which would lock it!)
;
; The old code wrote 0x80 after palette setup thinking it was "closing"
; palette write mode. But 0x80 actually locks PORT_COLOR to border-only!
;
; HSYNC TIMING (edge detection vs simple wait):
;   - Edge detection (wait 0→1): Full width + CLEAN top/bottom borders
;   - Simple wait (bit=1 only):  Full width + COLORS in all 4 borders
;
; This demo uses edge detection for clean borders.
;
; ============================================================================
;
; TECHNIQUE:
;   - Per-scanline color changes via PORT_COLOR register
;   - Two bars with independent vertical positions and sine-wave motion
;   - Bar 1: Red gradient; Bar 2: Green gradient
;   - Bars swap depth order when crossing for 3D "dancing" illusion
;   - Sine-wave math creates classic C64 "wobble" effect
;
; LEARNING FOCUS:
;   Advanced effects: independent motion, sine-wave math, depth ordering
;
; Prerequisites:
;   Run PERITEL.COM first to set horizontal position correctly
;
; Controls:
;   Any key - Exit to DOS
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
;
; Per-bar controls (change without modifying code):
;   BAR1_SPEED, BAR2_SPEED   - Individual wobble speeds
;   BAR1_CENTER, BAR2_CENTER - Individual vertical center positions
;
; Shared controls (affect both bars equally):
;   LINES_PER_COLOR          - Bar thickness (1=thin, 3=thick)
;   SINE_AMPLITUDE           - Wobble distance from center
;
; To add more bars: duplicate gradient table, add palette colors, 
; add new speed/center constants, and add draw_barN section in build_scanline_table
; ============================================================================

LINES_PER_COLOR equ 2           ; Scanlines per gradient color (1=thin, 3=thick)
BAR_HEIGHT      equ 14 * LINES_PER_COLOR  ; Total bar height (7 colors * 2 directions)

; Per-bar speed (higher = faster wobble)
BAR1_SPEED      equ 2           ; Bar 1 sine index increment per frame
BAR2_SPEED      equ 3           ; Bar 2 sine index increment per frame

; Per-bar center position (Y coordinate on screen)
; Set both to same center to make them dance over/under each other!
BAR1_CENTER     equ 100         ; Bar 1 oscillates around this Y position
BAR2_CENTER     equ 100         ; Bar 2 oscillates around this Y position (same = crossing!)

; Per-bar starting phase (0-255, controls where in sine wave each bar starts)
; Different phases + different speeds = bars weaving around each other
BAR1_PHASE      equ 0           ; Bar 1 starts at sine position 0
BAR2_PHASE      equ 85          ; Bar 2 starts 1/3 cycle offset (120 degrees)

; Shared amplitude (affects wobble range for both bars)
SINE_AMPLITUDE  equ 50          ; Maximum distance from center (bigger = more dramatic)

; ============================================================================
; Main Program
; ============================================================================
main:
    call enable_graphics_mode
    call set_palette
    call clear_screen
    
    ; Initialize sine wave indices with configurable starting phases
    mov byte [bar1_sine_idx], BAR1_PHASE
    mov byte [bar2_sine_idx], BAR2_PHASE

.main_loop:
    call wait_vblank
    
    ; Update bar 1 sine index
    mov al, [bar1_sine_idx]
    add al, BAR1_SPEED
    mov [bar1_sine_idx], al         ; Wraps automatically (0-255)
    
    ; Calculate bar 1 Y position: center + sine[index]
    xor ah, ah
    mov si, ax
    mov al, [sine_table + si]       ; Get sine value (0-100, centered at 50)
    add al, BAR1_CENTER
    sub al, SINE_AMPLITUDE          ; Adjust so sine oscillates around center
    mov [bar1_y], al
    
    ; Update bar 2 sine index
    mov al, [bar2_sine_idx]
    add al, BAR2_SPEED
    mov [bar2_sine_idx], al         ; Wraps automatically (0-255)
    
    ; Calculate bar 2 Y position: center + sine[index]
    xor ah, ah
    mov si, ax
    mov al, [sine_table + si]       ; Get sine value
    add al, BAR2_CENTER
    sub al, SINE_AMPLITUDE          ; Adjust so sine oscillates around center
    mov [bar2_y], al
    
    ; Detect crossing: if bars swapped relative positions, toggle front bar
    ; This creates the 3D "dancing" effect
    mov al, [bar1_y]
    mov bl, [bar2_y]
    cmp al, bl                      ; Compare current positions
    mov al, [last_bar1_above]       ; Get last frame's state
    jae .bar1_above_now
    ; Bar 1 is below bar 2 now
    test al, al                     ; Was bar1 above last frame?
    jz .no_crossing                 ; No, still below - no crossing
    xor byte [front_bar], 1         ; Yes! They crossed - toggle front bar
    mov byte [last_bar1_above], 0   ; Update state
    jmp .no_crossing
.bar1_above_now:
    ; Bar 1 is above bar 2 now
    test al, al                     ; Was bar1 above last frame?
    jnz .no_crossing                ; Yes, still above - no crossing
    xor byte [front_bar], 1         ; No! They crossed - toggle front bar
    mov byte [last_bar1_above], 1   ; Update state
.no_crossing:
    
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
; Draws the "back" bar first, then "front" bar on top (determined by front_bar)
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
    
    ; Check which bar should be in front
    cmp byte [front_bar], 0
    jnz .red_in_front
    
    ; Green in front: draw red first, then green on top
    call draw_red_bar
    call draw_green_bar
    jmp .done_drawing
    
.red_in_front:
    ; Red in front: draw green first, then red on top
    call draw_green_bar
    call draw_red_bar
    
.done_drawing:
    pop di
    pop si
    pop dx
    pop cx
    pop bx
    pop ax
    ret

; ----------------------------------------------------------------------------
; draw_red_bar - Draw bar 1 (red gradient, palette 1-7)
; ----------------------------------------------------------------------------
draw_red_bar:
    mov al, [bar1_y]
    xor ah, ah
    mov di, ax                  ; DI = bar 1 Y position
    mov si, red_gradient
    mov cx, BAR_HEIGHT
    
.draw_loop:
    cmp di, SCREEN_HEIGHT
    jb .in_range
    sub di, SCREEN_HEIGHT       ; Wrap around
.in_range:
    mov al, [si]
    mov [scanline_colors + di], al
    inc di
    inc si
    loop .draw_loop
    ret

; ----------------------------------------------------------------------------
; draw_green_bar - Draw bar 2 (green gradient, palette 8-14)
; ----------------------------------------------------------------------------
draw_green_bar:
    mov al, [bar2_y]
    xor ah, ah
    mov di, ax                  ; DI = bar 2 Y position
    mov si, green_gradient
    mov cx, BAR_HEIGHT
    
.draw_loop:
    cmp di, SCREEN_HEIGHT
    jb .in_range
    sub di, SCREEN_HEIGHT       ; Wrap around
.in_range:
    mov al, [si]
    mov [scanline_colors + di], al
    inc di
    inc si
    loop .draw_loop
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

bar1_y:         db 0            ; Bar 1 current vertical position (0-199)
bar2_y:         db 0            ; Bar 2 current vertical position (0-199)
bar1_sine_idx:  db 0            ; Bar 1 sine table index (0-255)
bar2_sine_idx:  db 0            ; Bar 2 sine table index (0-255)
front_bar:      db 0            ; Which bar is in front (0=green, 1=red)
last_bar1_above: db 1           ; Was bar1 above bar2 last frame? (for crossing detection)

; Pre-computed scanline colors (built each frame during vblank)
scanline_colors: times SCREEN_HEIGHT db 0

; Sine table (256 entries, values 0-100 representing sine wave)
; Center value is 50, oscillates between 0 and 100
; This creates smooth wobble motion for SINE_AMPLITUDE of 50
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
