; ============================================================================
; RBARS1a.ASM - Raster Bar Demo v1a: Distance-Based Gradient
; Single animated raster bar with smooth color gradient
; Written for NASM - NEC V40 (80186 compatible) @ 8 MHz
; By Retro Erik - 2026
;
; Target: Olivetti PC1 with Yamaha V6355D video controller
; Video Mode: CGA 160x200x16 (Hidden mode)
;
; TECHNIQUE:
;   - Per-scanline color changes via PORT_COLOR register
;   - Distance-based gradient: bright center fading to dark edges
;   - Self-contained: calls enable_graphics_mode and set_c64_palette
;   - Single bar animates down the screen
;
; ============================================================================
; CRITICAL DISCOVERY - 0x80 Locks, 0x40 Unlocks Full-Width PORT_COLOR
; ============================================================================
;
; ** MAJOR DISCOVERY **
; Full-width PORT_COLOR is the DEFAULT state after boot!
; Writing 0x80 to PORT_REG_ADDR LOCKS it to border-only mode.
; Writing 0x40 to PORT_REG_ADDR UNLOCKS full-width mode again.
;
; The problem was: set_c64_palette wrote 0x80 at the end, thinking it was
; "closing" palette write mode. But 0x80 actually locks PORT_COLOR to border!
;
; Solution: Don't write 0x80 after palette setup, or write 0x40 to unlock.
;
; HSYNC Timing affects BORDER behavior (the E key toggle):
;   - Edge detection (0→1): Full width + CLEAN top/bottom borders (black)  
;   - Simple wait (bit=1):  Full width + COLORS in all 4 borders
;
; Press U to toggle between 0x40 (unlock) and 0x80 (lock) to see the difference!
; Press E to toggle between edge detection and simple wait.
;
; NOTE: U only works in graphics mode (0x4A). In text mode (Space toggles),
; PORT_COLOR is ignored entirely - the V6355D renders text characters instead.
; When you press Space to return to graphics, set_c64_palette writes 0x40,
; so full-width mode is automatically restored.
;
; LEARNING FOCUS:
;   Foundation: per-scanline color output, gradient calculation, smooth animation
;
; Controls:
;   U     - Toggle 0x40 unlock (full width vs border only)
;   E     - Toggle HSYNC edge detection (border behavior)
;   P     - Pause/unpause animation
;   V     - Toggle VBLANK sync on/off
;   Space - Toggle graphics mode on/off
;   ESC   - Exit to DOS
; ============================================================================

[BITS 16]
[ORG 0x100]

; ============================================================================
; Constants
; ============================================================================

; --- Video Memory ---
VIDEO_SEG       equ 0xB000      ; PC1 video RAM segment (not B800!)

; --- Yamaha V6355D I/O Ports ---
PORT_REG_ADDR   equ 0x3DD       ; Register Bank Address Port (select register)
PORT_REG_DATA   equ 0x3DE       ; Register Bank Data Port (read/write)
PORT_MODE       equ 0x3D8       ; Mode Control Register
PORT_COLOR      equ 0x3D9       ; Color Select Register
PORT_STATUS     equ 0x3DA       ; Status Register (bit 0=HSYNC, bit 3=VBLANK)
                                ; Bit 0: Display enable (1 = retrace/blanking)
                                ; Bit 3: Vertical retrace (1 = in VBLANK)

; --- Screen Dimensions (160x200x16 hidden mode) ---
SCREEN_HEIGHT   equ 200         ; Vertical resolution in pixels/scanlines
RENDER_LINES    equ 216         ; Total lines to render (includes borders)
BYTES_PER_ROW   equ 80          ; 160 pixels / 2 pixels per byte

; --- Raster Bar Parameters ---
; A raster bar is a band of colored scanlines that creates a gradient effect
BAR_HEIGHT      equ 16          ; Height of the raster bar in scanlines
BAR_SPEED       equ 1           ; Movement speed (scanlines per frame)

; --- C64-inspired Color Palette (mapped to V6355D RGB values) ---
; The V6355D uses 3 bits per color channel (RGB 3-3-3, 512 colors)
; Format: Byte 1 = Red (bits 0-2), Byte 2 = Green (bits 4-6) | Blue (bits 0-2)
;
; We define 16 colors inspired by the C64 palette:
;  0: Black       4: Purple      8: Orange     12: Medium Gray
;  1: White       5: Green       9: Brown      13: Light Green
;  2: Red         6: Blue       10: Light Red  14: Light Blue
;  3: Cyan        7: Yellow     11: Dark Gray  15: Light Gray
; ============================================================================

; ============================================================================
; Main Program Entry Point
; ============================================================================
main:
    ; Save original video mode
    mov ah, 0x0F
    int 0x10
    mov [orig_video_mode], al
    
    ; Enable the hidden 160x200x16 graphics mode
    call enable_graphics_mode
    
    ; Set up C64-inspired palette
    call set_c64_palette
    
    ; Clear screen to black
    call clear_screen
    
    ; Initialize state
    mov byte [bar_y_pos], 0         ; Start at top
    mov byte [vsync_enabled], 1     ; VBLANK sync on by default
    mov byte [graphics_enabled], 1  ; Graphics mode on by default
    
; ============================================================================
; Main Loop - Runs until keypress
; ============================================================================
.main_loop:
    ; -----------------------------------------------------------------
    ; Step 1: Wait for Vertical Retrace (VBLANK) - if enabled
    ; This ensures we start drawing at the top of the frame
    ; -----------------------------------------------------------------
    cmp byte [vsync_enabled], 0
    je .skip_vblank
    call wait_vblank
.skip_vblank:
    
    ; -----------------------------------------------------------------
    ; Step 2: Update raster bar position (animation)
    ; Move the bar down by BAR_SPEED scanlines each frame
    ; Bar moves through full range 0 to RENDER_LINES-1
    ; Skip if paused
    ; -----------------------------------------------------------------
    cmp byte [paused], 1
    je .skip_update
    
    mov al, [bar_y_pos]
    add al, BAR_SPEED
    cmp al, RENDER_LINES
    jb .no_wrap
    xor al, al              ; Wrap to top
.no_wrap:
    mov [bar_y_pos], al
.skip_update:
    
    ; -----------------------------------------------------------------
    ; Step 3: Render the raster bars for this frame
    ; Loop through all visible scanlines and set colors
    ; -----------------------------------------------------------------
    call render_raster_bars
    
    ; -----------------------------------------------------------------
    ; Step 4: Check for keypress
    ; -----------------------------------------------------------------
    mov ah, 0x01            ; Check keyboard buffer (non-blocking)
    int 0x16
    jz .main_loop           ; No key pressed, continue
    
    ; Key was pressed - get it
    mov ah, 0x00
    int 0x16                ; Consume key
    
    ; Check which key
    cmp al, 27              ; ESC key?
    je .exit
    
    cmp al, 'v'             ; V key (lowercase)?
    je .toggle_vsync
    cmp al, 'V'             ; V key (uppercase)?
    je .toggle_vsync
    
    cmp al, ' '             ; Space key?
    je .toggle_graphics
    
    cmp al, 'p'             ; P key (lowercase)?
    je .toggle_pause
    cmp al, 'P'             ; P key (uppercase)?
    je .toggle_pause
    
    cmp al, 'e'             ; E key (lowercase)?
    je .toggle_edge
    cmp al, 'E'             ; E key (uppercase)?
    je .toggle_edge
    
    cmp al, 'u'             ; U key (lowercase)?
    je .toggle_unlock
    cmp al, 'U'             ; U key (uppercase)?
    je .toggle_unlock
    
    jmp .main_loop          ; Unknown key, continue

.toggle_unlock:
    xor byte [unlock_mode], 1
    ; Apply or remove the unlock immediately
    cmp byte [unlock_mode], 0
    je .lock_mode
    ; Enable unlock: write 0x40 to PORT_REG_ADDR (full width)
    mov al, 0x40
    out PORT_REG_ADDR, al
    jmp .main_loop
.lock_mode:
    ; Lock mode: write 0x80 to PORT_REG_ADDR (border only)
    mov al, 0x80
    out PORT_REG_ADDR, al
    jmp .main_loop

.toggle_edge:
    xor byte [edge_detect], 1
    jmp .main_loop

.toggle_pause:
    xor byte [paused], 1    ; Toggle 0<->1
    jmp .main_loop
    
.toggle_vsync:
    xor byte [vsync_enabled], 1    ; Toggle 0<->1
    jmp .main_loop
    
.toggle_graphics:
    xor byte [graphics_enabled], 1  ; Toggle 0<->1
    cmp byte [graphics_enabled], 0
    je .disable_gfx
    call enable_graphics_mode       ; Turn on
    call set_c64_palette
    jmp .main_loop
.disable_gfx:
    call disable_graphics_mode      ; Turn off
    jmp .main_loop
    
; ============================================================================
; Exit - Restore text mode and return to DOS
; ============================================================================
.exit:
    ; Disable hidden graphics mode
    call disable_graphics_mode
    
    ; Restore original video mode
    mov ah, 0x00
    mov al, [orig_video_mode]
    int 0x10
    
    ; Clear screen
    mov ah, 0x06
    mov al, 0
    mov bh, 0x07            ; Light gray on black
    xor cx, cx
    mov dx, 0x184F
    int 0x10
    
    ; Exit to DOS
    mov ax, 0x4C00
    int 0x21

; ============================================================================
; render_raster_bars - Render all raster bars for the current frame
;
; This is the heart of the raster bar effect. For each visible scanline:
;   1. Wait for horizontal retrace (start of scanline)
;   2. Calculate the color for this scanline
;   3. Write the color to the border/background register
;
; The V6355D's status port (0x3DA) provides timing information:
;   Bit 0 = 1: Horizontal or vertical retrace active
;   Bit 3 = 1: Vertical retrace active
;
; Since we're running on a PAL system (50 Hz, 200 visible lines),
; timing is more relaxed than on an IBM 5150. Simple busy-wait loops
; are sufficient for this proof-of-concept.
;
; STRUCTURE FOR MULTIPLE BARS:
; To add more bars, simply extend the color calculation logic in
; get_bar_color to check multiple Y positions and blend/overlay colors.
; ============================================================================
render_raster_bars:
    push ax
    push bx
    push cx
    push dx
    
    cli                     ; Disable interrupts during render
    
    xor bx, bx              ; BX = color counter (0-15)
    mov cx, SCREEN_HEIGHT   ; CX = line counter (200 lines)
    
    ; Check mode ONCE before loop
    cmp byte [edge_detect], 0
    je .simple_loop
    
    ; =========================================
    ; EDGE DETECTION LOOP (full width raster)
    ; =========================================
.edge_next_line:
    mov dx, PORT_STATUS
    ; Wait for bit 0 = 0
.edge_wait_low:
    in al, dx
    test al, 0x01
    jnz .edge_wait_low
    ; Wait for bit 0 = 1
.edge_wait_high:
    in al, dx
    test al, 0x01
    jz .edge_wait_high
    
    ; Output color immediately
    mov al, bl
    out PORT_COLOR, al
    
    ; Next color
    inc bl
    and bl, 0x0F
    
    ; Count lines
    dec cx
    jnz .edge_next_line
    jmp .done
    
    ; =========================================
    ; SIMPLE WAIT LOOP (border only raster)
    ; =========================================
.simple_loop:
.simple_next_line:
    mov dx, PORT_STATUS
    ; Wait for bit 0 = 1 only
.simple_wait_hsync:
    in al, dx
    test al, 0x01
    jz .simple_wait_hsync
    
    ; Output color
    mov al, bl
    out PORT_COLOR, al
    
    ; Next color
    inc bl
    and bl, 0x0F
    
    ; Count lines
    dec cx
    jnz .simple_next_line
    
.done:
    ; Reset to black
    xor al, al
    out PORT_COLOR, al
    
    sti                     ; Re-enable interrupts
    
    pop dx
    pop cx
    pop bx
    pop ax
    ret

; ============================================================================
; get_bar_color - Calculate the color for a given scanline
;
; Input:  AX = current scanline (0-199)
; Output: AL = color index (0-15)
;
; This function determines what color a scanline should be based on:
;   - The bar's current Y position (bar_y_pos)
;   - The bar's height (BAR_HEIGHT)
;   - A gradient within the bar (smooth color transition)
;
; EXTENDING FOR MULTIPLE BARS:
; To add more bars, check distance from multiple Y positions and
; combine/overlay the results. Each bar could have its own:
;   - Y position
;   - Color palette (warm, cool, rainbow, etc.)
;   - Height and gradient style
; ============================================================================
get_bar_color:
    ; Input: AX = scanline (0-199)
    ; Output: AL = color (0-15)
    ;
    ; No wrap-around - bar disappears at edges to avoid border flicker
    push bx
    
    mov bl, [bar_y_pos]     ; BL = bar position
    
    ; Calculate distance: |scanline - bar_y|
    sub al, bl              ; AL = scanline - bar_y
    jns .pos1
    neg al
.pos1:
    ; AL = |distance|
    
    ; If distance > BAR_HEIGHT/2, return black
    cmp al, BAR_HEIGHT/2
    ja .black
    
    ; Color = 15 - distance (gradient)
    mov bl, al
    mov al, 15
    sub al, bl
    jmp .done
    
.black:
    xor al, al
    
.done:
    pop bx
    ret

; ============================================================================
; wait_vblank - Wait for vertical blanking interval
;
; Waits for the start of the vertical retrace period.
; This ensures we begin rendering at the top of the frame.
;
; Method:
;   1. Wait for any current VBLANK to end (bit 3 goes low)
;   2. Wait for new VBLANK to start (bit 3 goes high)
; ============================================================================
wait_vblank:
    push ax
    push dx
    
    mov dx, PORT_STATUS
    
    ; First, wait for current VBLANK to end (if we're in one)
.wait_end:
    in al, dx
    test al, 0x08           ; Check bit 3 (vertical retrace)
    jnz .wait_end           ; Still in VBLANK, keep waiting
    
    ; Now wait for new VBLANK to start
.wait_start:
    in al, dx
    test al, 0x08           ; Check bit 3
    jz .wait_start          ; Not in VBLANK yet, keep waiting
    
    pop dx
    pop ax
    ret

; ============================================================================
; enable_graphics_mode - Enable Olivetti PC1 hidden 160x200x16 mode
;
; Configures the Yamaha V6355D for the hidden graphics mode:
;   - Uses BIOS to set CGA 320x200 mode (for CRTC timing)
;   - Configures register 0x67 for 8-bit bus mode
;   - Configures register 0x65 for 200 lines, PAL timing
;   - Sets port 0x3D8 to 0x4A to enable 16-color mode
;
; NOTE: Registers 0x65 and 0x67 are NOT strictly required for graphics mode.
; The minimal requirement is just: out 0x3D8, 0x4A
; These extra registers are removed from version 1c onwards.
; ============================================================================
enable_graphics_mode:
    push ax
    push dx
    
    ; Port 0x3D8: Mode Control Register
    ; 0x4A = Enable 16-color mode (bit 6=1), graphics mode (bit 1=1),
    ;        video enable (bit 3=1)
    mov al, 0x4A
    out PORT_MODE, al
    jmp short $+2
    
    ; Set border to black initially
    mov dx, PORT_COLOR
    xor al, al
    out dx, al
    
    pop dx
    pop ax
    ret

; ============================================================================
; disable_graphics_mode - Return to text mode
; ============================================================================
disable_graphics_mode:
    push ax
    push dx
    
    ; Reset mode control to text mode
    mov al, 0x28
    out PORT_MODE, al
    jmp short $+2
    
    pop dx
    pop ax
    ret

; ============================================================================
; clear_screen - Fill video memory with black (color 0)
; ============================================================================
clear_screen:
    push ax
    push cx
    push di
    push es
    
    mov ax, VIDEO_SEG
    mov es, ax
    xor di, di
    mov cx, 8192            ; 16KB = 8192 words
    xor ax, ax              ; Black = 0x0000
    cld
    rep stosw
    
    pop es
    pop di
    pop cx
    pop ax
    ret

; ============================================================================
; set_c64_palette - Load a C64-inspired color palette into the V6355D
;
; The V6355D has 16 palette registers, each holding an RGB value.
; Format: 2 bytes per color
;   Byte 1: Red intensity (bits 0-2, values 0-7)
;   Byte 2: Green (bits 4-6) | Blue (bits 0-2)
;
; This palette is inspired by the C64 but mapped to the V6355D's
; 3-bit-per-channel RGB format.
; ============================================================================
set_c64_palette:
    push ax
    push cx
    push si
    
    cli                     ; Disable interrupts during palette write
    
    ; Enable palette write mode (write 0x40 to register address port)
    mov al, 0x40
    out PORT_REG_ADDR, al
    jmp short $+2
    jmp short $+2
    
    ; Write 32 bytes of palette data (16 colors × 2 bytes)
    mov si, c64_palette
    mov cx, 32
    
.pal_loop:
    lodsb
    out PORT_REG_DATA, al
    jmp short $+2
    loop .pal_loop
    
    ; NOTE: We do NOT write 0x80 here!
    ; Writing 0x80 to PORT_REG_ADDR disables full-width PORT_COLOR mode.
    ; Leaving it in "palette write mode" (0x40) enables full-width raster bars.
    
    sti                     ; Re-enable interrupts
    
    pop si
    pop cx
    pop ax
    ret

; ============================================================================
; Data Section
; ============================================================================

; Original video mode (saved at startup)
orig_video_mode: db 0

; Raster bar state
bar_y_pos:        db 0          ; Current Y position of bar center (0-199)
vsync_enabled:    db 1          ; 1 = wait for VBLANK, 0 = free-running
graphics_enabled: db 1          ; 1 = graphics mode, 0 = text mode
paused:           db 0          ; 1 = animation paused, 0 = running
edge_detect:      db 1          ; 1 = edge detection (clean borders), 0 = simple (all borders)
unlock_mode:      db 0          ; 1 = 0x40 unlock (full width), 0 = border only

; ============================================================================
; C64-Inspired Color Palette
; Approximating the iconic C64 colors using V6355D's RGB 3-3-3 format
; Format: Red (byte 1), Green<<4 | Blue (byte 2)
;
; The C64 palette is distinctive for its earthy browns, muted purples,
; and that iconic light blue. We map these as closely as possible.
; ============================================================================
c64_palette:
    ; Index 0-7: Dark/muted colors
    db 0x00, 0x00           ;  0: Black         (R=0, G=0, B=0)
    db 0x07, 0x77           ;  1: White         (R=7, G=7, B=7)
    db 0x05, 0x11           ;  2: Red           (R=5, G=1, B=1)
    db 0x02, 0x66           ;  3: Cyan          (R=2, G=6, B=6)
    db 0x05, 0x25           ;  4: Purple        (R=5, G=2, B=5)
    db 0x02, 0x51           ;  5: Green         (R=2, G=5, B=1)
    db 0x01, 0x14           ;  6: Blue          (R=1, G=1, B=4)
    db 0x06, 0x62           ;  7: Yellow        (R=6, G=6, B=2)
    
    ; Index 8-15: Bright/light colors
    db 0x05, 0x32           ;  8: Orange        (R=5, G=3, B=2)
    db 0x03, 0x20           ;  9: Brown         (R=3, G=2, B=0)
    db 0x06, 0x33           ; 10: Light Red     (R=6, G=3, B=3)
    db 0x02, 0x22           ; 11: Dark Gray     (R=2, G=2, B=2)
    db 0x04, 0x44           ; 12: Medium Gray   (R=4, G=4, B=4)
    db 0x04, 0x73           ; 13: Light Green   (R=4, G=7, B=3)
    db 0x03, 0x36           ; 14: Light Blue    (R=3, G=3, B=6)
    db 0x06, 0x66           ; 15: Light Gray    (R=6, G=6, B=6)

; ============================================================================
; End of Program
; ============================================================================
