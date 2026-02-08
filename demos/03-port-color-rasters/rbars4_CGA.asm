; ============================================================================
; RBARS4_CGA.ASM - Raster Bar Demo: Standard CGA Mode
; Raster bars in standard CGA 320x200x2 mode
; Written for NASM - NEC V40 (80186 compatible) @ 8 MHz
; By Retro Erik - 2026
;
; Target: Standard CGA-compatible systems
; Video Mode: CGA 320x200x2 (Standard mode 0x04)
;
; TECHNIQUE:
;   - Per-scanline color via PORT_COLOR (CGA Color Select Register)
;   - Modulo spacing creates multiple evenly-spaced bars
;   - Distance-based gradient: bright center, dark edges
;   - Standard CGA technique - works on any CGA-compatible system
;
; DISCOVERY: PORT_COLOR changes work in standard CGA modes, not just
; on the PC1's hidden mode. This proves the technique is universally
; applicable to all CGA hardware.
;
; Controls:
;   Any key - Exit to DOS
; ============================================================================

[BITS 16]
[ORG 0x100]

; ============================================================================
; Constants
; ============================================================================

; --- Video Memory ---
VIDEO_SEG       equ 0xB800      ; Standard CGA video RAM segment

; --- CGA I/O Ports (Standard) ---
PORT_MODE       equ 0x3D8       ; CGA Mode Control Register
PORT_COLOR      equ 0x3D9       ; CGA Color Select Register (border & background)
PORT_STATUS     equ 0x3DA       ; CGA Status Register (read-only)
                                ; Bit 0: HSYNC (1 = horizontal blanking)
                                ; Bit 3: VSYNC (1 = vertical blanking)

; --- Screen Dimensions (CGA 320x200 mode) ---
SCREEN_HEIGHT   equ 200         ; Vertical resolution in pixels/scanlines
BYTES_PER_ROW   equ 80          ; 320 pixels / 8 pixels per byte = 40 bytes/row × 2 banks

; --- Raster Bar Parameters ---
; A raster bar is a band of colored scanlines with a gradient effect
; Bright center fading to dark edges - creates a "glowing bar" look
BAR_HEIGHT      equ 24          ; Total height of one bar in scanlines
BAR_SPACING     equ 64          ; Distance between bar centers (power of 2 for speed!)
BAR_MASK        equ 63          ; BAR_SPACING - 1 for fast modulo
BAR_SPEED       equ 1           ; Movement speed (scanlines per frame)
NUM_BARS        equ 3           ; Number of bars on screen (200/64)

; --- CGA Color Indices ---
; Standard CGA uses color indices 0-15 for PORT_COLOR register.
; In mode 0x04 (320x200), only 2 colors are displayed in video memory,
; but PORT_COLOR can be changed per-scanline to display different colors.
;
; Standard CGA color indices:
;  0: Black       4: Red         8: Dark Gray   12: Light Red
;  1: Blue        5: Magenta     9: Light Blue  13: Light Magenta
;  2: Green       6: Brown      10: Light Green 14: Yellow
;  3: Cyan        7: White      11: Light Cyan  15: Bright White
; ============================================================================

; ============================================================================
; Main Program Entry Point
; ============================================================================
main:
    ; Switch to graphics mode (required for full-width rasters)
    call enable_graphics_mode
    
    ; Clear screen to black (video RAM has garbage)
    call clear_screen
    
    ; Initialize raster bar position
    mov byte [bar_y_pos], 0
    mov byte [bar_frame], 0
    
; ============================================================================
; Main Loop - Runs until keypress
; ============================================================================
.main_loop:
    ; -----------------------------------------------------------------
    ; Step 1: Wait for Vertical Retrace (VBLANK)
    ; This ensures we start drawing at the top of the frame
    ; -----------------------------------------------------------------
    call wait_vblank
    
    ; -----------------------------------------------------------------
    ; Step 2: Update raster bar position (animation)
    ; Move the bar down by BAR_SPEED scanlines each frame
    ; -----------------------------------------------------------------
    mov al, [bar_y_pos]
    add al, BAR_SPEED
    cmp al, SCREEN_HEIGHT
    jb .no_wrap
    xor al, al              ; Wrap to top of screen
.no_wrap:
    mov [bar_y_pos], al
    
    ; Increment frame counter (used for color cycling)
    inc byte [bar_frame]
    
    ; -----------------------------------------------------------------
    ; Step 3: Render the raster bars for this frame
    ; Loop through all visible scanlines and set colors
    ; -----------------------------------------------------------------
    call render_raster_bars
    
    ; -----------------------------------------------------------------
    ; Step 4: Check for keypress to exit
    ; -----------------------------------------------------------------
    mov ah, 0x01            ; Check keyboard buffer (non-blocking)
    int 0x16
    jz .main_loop           ; No key pressed, continue
    
    ; Key was pressed - consume it and exit
    mov ah, 0x00
    int 0x16
    
; ============================================================================
; Exit - Return to DOS (don't reset video - preserve PERITEL settings)
; ============================================================================
.exit:
    ; Just exit to DOS - COMMAND.COM will restore the screen
   
    mov ax, 0003h      ; BIOS video: set mode 03h (80x25 text)
    int 10h
   
    mov ax, 0x4C00     ; DOS: terminate, return code 0
    int 0x21

; ============================================================================
; render_raster_bars - Render smooth gradient raster bars
;
; Creates "real" raster bars with:
;   - Bright center (white/color 15)
;   - Smooth gradient fading to dark edges
;   - Multiple bars scrolling down the screen
;
; KNOWN ISSUE - TEARING:
;   There is visible tearing because we calculate the color AFTER detecting
;   the HSYNC edge. The gradient calculation takes ~15 instructions, which
;   delays the color output into the visible portion of the scanline.
;
;   To fix: Pre-compute all 200 colors into a table during VBLANK, then
;   the scanline loop becomes just: wait → lodsb → out (3 operations).
;   See rbars2.asm for an example of this pre-computed approach.
; ============================================================================
render_raster_bars:
    push ax
    push bx
    push cx
    push dx
    
    cli                     ; Disable interrupts for stable timing
    
    xor bx, bx              ; BX = scanline counter (0-199)
    mov cl, [bar_y_pos]     ; CL = scroll offset (keep in register)
    mov dx, PORT_STATUS
    
.scanline_loop:
    ; Wait for HSYNC 0→1 edge (clean timing, no tearing)
    ; Step 1: Wait for bit 0 = 0 (in display period)
.wait_low:
    in al, dx
    test al, 0x01
    jnz .wait_low
    
    ; Step 2: Wait for bit 0 = 1 (HSYNC started)
.wait_high:
    in al, dx
    test al, 0x01
    jz .wait_high
    
    ; Step 3: Calculate color using fast gradient
    ; position = (scanline + offset) AND BAR_MASK  (0 to 31)
    mov ax, bx
    add al, cl              ; Add scroll offset
    and al, BAR_MASK        ; Fast modulo! (0-31)
    
    ; Calculate distance from bar center (center is at BAR_SPACING/2 = 32)
    ; distance = |position - 32|
    sub al, BAR_SPACING/2   ; AL = position - 32 (signed: -32 to +31)
    jns .positive
    neg al                  ; AL = |distance| (0 to 32)
.positive:
    
    ; Create gradient: if distance < BAR_HEIGHT/2 (12), we're inside bar
    cmp al, BAR_HEIGHT/2
    jae .outside_bar
    
    ; Inside bar - gradient from center (15) to edge (3)
    ; color = 15 - distance (original formula)
    mov ah, 15
    sub ah, al              ; color = 15 - distance
    mov al, ah
    jmp .output_color
    
.outside_bar:
    xor al, al              ; Black outside bar
    
.output_color:
    mov dx, PORT_COLOR
    out dx, al
    mov dx, PORT_STATUS
    
    ; Next scanline
    inc bx
    cmp bx, SCREEN_HEIGHT
    jb .scanline_loop
    
    ; Reset border to black
    xor al, al
    mov dx, PORT_COLOR
    out dx, al
    
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
    push bx
    push cx
    
    ; Calculate distance from bar center
    mov bl, [bar_y_pos]     ; BL = bar Y position (center)
    xor bh, bh
    
    ; Calculate signed distance: scanline - bar_center
    mov cx, ax              ; CX = scanline
    sub cx, bx              ; CX = scanline - bar_y
    
    ; Handle wrap-around (bar can cross screen edge)
    cmp cx, SCREEN_HEIGHT/2
    jl .no_wrap_high
    sub cx, SCREEN_HEIGHT   ; Adjust for wrap
.no_wrap_high:
    cmp cx, word -(SCREEN_HEIGHT/2)
    jge .no_wrap_low
    add cx, SCREEN_HEIGHT   ; Adjust for wrap
.no_wrap_low:
    
    ; Get absolute distance
    mov ax, cx
    test ax, ax
    jns .positive
    neg ax                  ; AX = |distance|
.positive:
    
    ; Check if within bar height
    cmp ax, BAR_HEIGHT/2
    ja .outside_bar
    
    ; -----------------------------------------------------------------
    ; Inside the bar - create a color gradient
    ; Distance 0 (center) = brightest color (white, index 15)
    ; Distance BAR_HEIGHT/2 (edge) = darker color
    ; We use a simple linear gradient through the color palette
    ; -----------------------------------------------------------------
    
    ; Map distance (0 to BAR_HEIGHT/2) to color (15 down to 8)
    ; Formula: color = 15 - (distance * 8 / (BAR_HEIGHT/2))
    ; Simplified for BAR_HEIGHT=16: color = 15 - distance
    mov bx, ax              ; BX = distance (0-7)
    mov al, 15
    sub al, bl              ; AL = 15 - distance = color (15 down to 8)
    
    ; Optional: Add color cycling based on frame counter
    ; This makes the bar shimmer/animate
    mov bl, [bar_frame]
    shr bl, 2               ; Slow down the cycling (divide by 4)
    and bl, 0x07            ; Keep in range 0-7
    add al, bl
    and al, 0x0F            ; Wrap to 0-15
    
    jmp .done
    
.outside_bar:
    ; Outside the bar - return black (color 0)
    xor al, al
    
.done:
    pop cx
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
; enable_graphics_mode - Enable CGA Mode 0x04 (320x200 graphics)
;
; Uses BIOS INT 0x10 to properly initialize the video mode.
; ============================================================================
enable_graphics_mode:
    push ax
    
    ; Use BIOS to set CGA mode 0x04 properly
    mov ax, 0x0004          ; BIOS mode 4 (320x200 graphics)
    int 0x10                ; Set video mode
    
    pop ax
    ret

; ============================================================================
; disable_graphics_mode - Return to text mode
; (Not used - we use INT 0x10 in exit routine instead)
; ============================================================================
disable_graphics_mode:
    push ax
    
    ; Use BIOS to return to text mode
    mov ax, 0x0003          ; BIOS mode 3 (80x25 text)
    int 0x10
    
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
; set_c64_palette - NOT USED IN STANDARD CGA VERSION
;
; This function is left in for reference but not called in standard CGA mode.
; Standard CGA uses fixed colors defined by the hardware.
; On systems with programmable palettes (like PC1), this could be used
; to customize the RGB values of CGA color indices.
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
    
    ; WARNING: Writing 0x80 here locks PORT_COLOR to border-only!
    ; Comment out for full-width bars, or write 0x40 again after.
    mov al, 0x80
    out PORT_REG_ADDR, al
    jmp short $+2
    
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
bar_y_pos:      db 0            ; Current Y position of bar center (0-199)
bar_frame:      db 0            ; Frame counter for color cycling

; ============================================================================
; C64-Inspired Color Palette Data (NOT USED IN STANDARD CGA)
; Left for reference - this would be used on systems with programmable
; RGB palettes to customize CGA colors. Standard CGA hardware has
; fixed RGB values for each color index.
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
