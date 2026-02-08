; ============================================================================
; RBARS1b.ASM - Raster Bar Demo v1b: Modulo Banding (Full-Width)
; Thick scrolling color bands using division-based color calculation
; Written for NASM - NEC V40 (80186 compatible) @ 8 MHz
; By Retro Erik - 2026
;
; Target: Olivetti PC1 with Yamaha V6355D video controller
; Video Mode: CGA 160x200x16 (Hidden mode)
;
; TECHNIQUE:
;   - Per-scanline color changes via PORT_COLOR register
;   - Modulo banding: color = (scanline + offset) / 12 AND 0x0F
;   - Creates thick 12-scanline bands that scroll smoothly
;   - Uses edge detection for clean top/bottom borders
;
; WHY FULL-WIDTH WORKS:
;   This demo doesn't write 0x80 to port 0x3DD, so the default full-width
;   PORT_COLOR mode is preserved. See rbars1.asm for the full discovery.
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
VIDEO_SEG       equ 0xB000      ; PC1 video RAM segment (not B800!)

; --- Yamaha V6355D I/O Ports ---
; Base address is 0x3D0 on PC1, but 0xD0-0xDF also works as alias
PORT_REG_ADDR   equ 0x3DD       ; Register Bank Address Port (select register)
PORT_REG_DATA   equ 0x3DE       ; Register Bank Data Port (read/write)
PORT_MODE       equ 0x3D8       ; Mode Control Register
PORT_COLOR      equ 0x3D9       ; Color Select Register (border color, bits 0-3)
PORT_STATUS     equ 0x3DA       ; Status Register (read-only)
                                ; Bit 0: Display enable (1 = retrace/blanking)
                                ; Bit 3: Vertical retrace (1 = in VBLANK)

; --- Screen Dimensions (160x200x16 hidden mode) ---
SCREEN_HEIGHT   equ 200         ; Vertical resolution in pixels/scanlines
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
    
    ; Clear screen to black
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
    mov ax, 0003h      ; BIOS video: set mode 03h (80x25 text)
    int 10h

    mov ax, 0x4C00
    int 0x21

; ============================================================================
; render_raster_bars - Render raster bars on left/right borders
;
; Animated version: Bars scroll down the screen smoothly
; Uses bar_y_pos as offset to create scrolling effect
; ============================================================================
render_raster_bars:
    push ax
    push bx
    push cx
    push dx
    
    cli                     ; Disable interrupts for stable timing
    
    xor bx, bx              ; BX = scanline counter (0-199)
    mov dx, PORT_STATUS
    
.scanline_loop:
    ; Step 1: Wait for display period (bit 0 = 0)
.wait_display:
    in al, dx
    test al, 0x01
    jnz .wait_display
    
    ; Step 2: Wait for retrace to start (bit 0 = 1)
.wait_retrace:
    in al, dx
    test al, 0x01
    jz .wait_retrace
    
    ; Step 3: Calculate color with scroll offset
    ; color = ((scanline + bar_y_pos) / 12) AND 15
    ; This creates 12-scanline bands that scroll down
    mov ax, bx              ; AX = current scanline
    add al, [bar_y_pos]     ; Add scroll offset
    adc ah, 0               ; Handle overflow
    mov cl, 12              ; Thinner bands = more bars visible
    div cl                  ; AL = (scanline + offset) / 12
    and al, 0x0F            ; Keep in range 0-15
    
    ; Step 4: Output color
    mov dx, PORT_COLOR
    out dx, al
    mov dx, PORT_STATUS     ; Restore DX for next iteration
    
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
; enable_graphics_mode - Enable Olivetti PC1 hidden 160x200x16 mode
;
; Configures the Yamaha V6355D for the hidden graphics mode:
;   - Sets port 0x3D8 to 0x4A to enable 16-color mode
;
; NOTE: Registers 0x65 and 0x67 are NOT strictly required for graphics mode.
; The minimal requirement is just: out 0x3D8, 0x4A
; These extra registers are removed from version 1c onwards.
; ============================================================================
enable_graphics_mode:
    push ax
    push dx
    
    ; NOTE: We skip BIOS and all V6355D register writes to preserve
    ; PERITEL.COM's settings! User can PERITEL.COM first to adjust horizontal position.
    ; 
    ; IMPORTANT: Do NOT touch registers via 0x3DD/0x3DE at all!
    ; Any write to port 0x3DD might reset things.
    
    ; Port 0x3D8: Mode Control Register
    ; 0x4A = Enable 16-color mode (bit 6=1), graphics mode (bit 1=1),
    ;        video enable (bit 3=1)
    mov al, 0x4A
    out PORT_MODE, al
    jmp short $+2
    
    ; Set border to black initially
    xor al, al
    out PORT_COLOR, al
    
    pop dx
    pop ax
    ret

; ============================================================================
; disable_graphics_mode - Return to text mode
; ============================================================================
disable_graphics_mode:
    push ax
    push dx
    
    ; Reset mode control to text mode (just reverse of 0x4A)
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
    
    ; Disable palette write mode
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
