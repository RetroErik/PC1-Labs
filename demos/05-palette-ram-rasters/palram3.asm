; ============================================================================
; PALRAM3.ASM - Scanline Palette Demo (Advanced/Reference) During HSYNC
; ============================================================================
;
; EDUCATIONAL DEMONSTRATION: 200 Colors on Screen Simultaneously
;
; This program demonstrates a classic "demo scene" technique: changing the
; video palette during the horizontal blanking interval to display more
; colors than the hardware normally allows.
;
; Written for NASM assembler
; Target: Olivetti Prodest PC1 with Yamaha V6355D video controller
; CPU: NEC V40 (80186 compatible) @ 8 MHz
;
; By Retro Erik - 2026
;
; DISTINGUISHES THIS VERSION:
;   - Most comprehensive implementation
;   - 7 palette modes with advanced controls
;   - H/V SYNC toggle experimentation (press H/V)
;   - Detailed hardware documentation
;   - ~925 lines of code (reference implementation)
;
; ============================================================================
; HARDWARE BACKGROUND
; ============================================================================
;
; The Yamaha V6355D is an unusual CGA-compatible video controller that has
; a hidden 16-color mode at 160x200 resolution. Unlike standard CGA which
; has fixed palettes, this chip has programmable RGB palette entries.
;
; PALETTE FORMAT: RGB333 (3 bits per channel = 512 possible colors)
;   - First byte:  R (bits 2-0 = red intensity 0-7)
;   - Second byte: G<<4 | B (high nibble = green, low nibble = blue)
;
; The trick: CRT monitors draw the screen line-by-line, left to right.
; Between each line there's a brief "horizontal blanking" period when the
; electron beam returns to the left side. If we change the palette during
; this blanking period, each scanline can have a different color!
;
; ============================================================================
; THE TECHNIQUE
; ============================================================================
;
; Palette updates are synchronized to the HSYNC edge each scanline.
;
; 1. Fill entire screen with color index 0 (appears black initially)
; 2. Wait for VBLANK (start of frame) to synchronize
; 3. For each of the 200 scanlines:
;    a. Wait for HSYNC (horizontal blanking period)
;    b. Quickly write new RGB values to palette entry 0
;    c. The scanline draws with this new color
; 4. Result: 200 different colors on screen simultaneously!
;
; TIMING IS CRITICAL: We have only ~10 microseconds during HBLANK to write
; 3 bytes to the palette. On the 8 MHz V40, that's about 80 cycles.
; Our 3 OUT instructions take ~30 cycles - just enough time!
;
; NOTE: A full scanline is ~63.5 µs (~509 cycles), but only HBLANK (~80 cycles)
; is safe for palette writes. Writing during the visible portion causes tearing.
; For glitch-free results: max ~6-8 OUTs per scanline (during HBLANK only).
;
; ============================================================================
; CONTROLS
; ============================================================================
;
;   1-7  : Select palette mode
;          1 = Rainbow + Grayscale    5 = Fire gradient
;          2 = RGB Cube Snake         6 = Grayscale
;          3 = Warm Sunset            7 = Full Rainbow (default)
;          4 = Cool Ocean
;
;   H    : Toggle HSYNC waiting (see what happens without it!) - Default ON
;   V    : Toggle VSYNC waiting (see the scrolling effect!) - Default ON
;   ESC  : Exit to DOS
;
; ============================================================================

[BITS 16]
[ORG 0x100]

; ============================================================================
; HARDWARE PORT DEFINITIONS
; ============================================================================
; These I/O ports control the Yamaha V6355D video controller.
; They are similar to CGA ports but with extended palette features.

PORT_MODE       equ 0x3D8   ; Video mode register (write 0x4A for 160x200x16)
PORT_STATUS     equ 0x3DA   ; Status register (bit 0=HSYNC, bit 3=VSYNC)
PORT_PAL_ADDR   equ 0x3DD   ; Palette address register (0x40-0x4F for colors 0-15)
PORT_PAL_DATA   equ 0x3DE   ; Palette data register (write R, then G<<4|B)

; ============================================================================
; MEMORY AND SCREEN CONSTANTS
; ============================================================================

VIDEO_SEG       equ 0xB000  ; Video memory segment (not 0xB800 like standard CGA!)
SCREEN_HEIGHT   equ 200     ; Vertical resolution in pixels
NUM_PALETTES    equ 7       ; Number of available palette modes

; ============================================================================
; MAIN PROGRAM ENTRY POINT
; ============================================================================
main:
    ; -----------------------------------------------------------------------
    ; Initialize demo state
    ; -----------------------------------------------------------------------
    ; Set default palette to #7 (Full Rainbow) and enable both sync modes
    
    mov byte [current_palette], 6   ; Palette 7 (index 6) = Full Rainbow
    mov byte [hsync_enabled], 1     ; HSYNC waiting ON (stable display)
    mov byte [vsync_enabled], 1     ; VSYNC waiting ON (no tearing)
    call load_current_palette       ; Copy palette data to working buffer
    
    ; -----------------------------------------------------------------------
    ; Set up the video mode
    ; -----------------------------------------------------------------------
    ; Mode 0x4A is the "hidden" 160x200x16 mode with programmable palette.
    ; This mode is not documented in standard CGA specs!
    
    call enable_graphics_mode
    
    ; -----------------------------------------------------------------------
    ; Clear screen to color 0
    ; -----------------------------------------------------------------------
    ; We fill the entire screen with palette index 0. Since we'll be
    ; changing palette entry 0's RGB values per-scanline, each line
    ; will appear as a different color even though the video RAM
    ; contains the same value everywhere!
    
    call clear_screen
    
    ; -----------------------------------------------------------------------
    ; Main rendering loop
    ; -----------------------------------------------------------------------
    ; This loop runs once per frame (~60 Hz). Each iteration:
    ; 1. Waits for vertical blanking (if enabled)
    ; 2. Renders all 200 scanlines with palette changes
    ; 3. Checks for keyboard input
    
.main_loop:
    call wait_vblank            ; Synchronize to frame start
    call render_scanlines       ; The magic happens here!
    call check_keyboard         ; Handle user input
    
    cmp al, 0xFF                ; Exit flag set?
    jne .main_loop              ; No - continue looping
    
    ; -----------------------------------------------------------------------
    ; Clean up and exit to DOS
    ; -----------------------------------------------------------------------
    ; Reset palette entry 0 to black before exiting
    
    mov al, 0x40                ; Select palette entry 0
    out PORT_PAL_ADDR, al
    xor al, al                  ; R = 0
    out PORT_PAL_DATA, al
    out PORT_PAL_DATA, al       ; G<<4|B = 0 (black)
    
    mov ax, 0x0003              ; Set 80x25 text mode (standard BIOS call)
    int 0x10
    mov ax, 0x4C00              ; DOS exit with return code 0
    int 0x21

; ============================================================================
; check_keyboard - Handle keyboard input
; ============================================================================
; Checks if a key was pressed and handles:
;   - ESC: Returns 0xFF in AL to signal exit
;   - 1-7: Switches palette mode
;   - H: Toggles horizontal sync waiting
;   - V: Toggles vertical sync waiting
;
; Returns: AL = 0xFF if exit requested, else 0
; ============================================================================
check_keyboard:
    push bx
    
    ; -----------------------------------------------------------------------
    ; Check if a key is available (non-blocking)
    ; -----------------------------------------------------------------------
    ; BIOS INT 16h, AH=01h: Check keyboard buffer
    ; Returns: ZF=1 if no key, ZF=0 if key waiting
    
    mov ah, 0x01
    int 0x16
    jz .no_key                  ; No key pressed - return immediately
    
    ; -----------------------------------------------------------------------
    ; Read the key (removes it from buffer)
    ; -----------------------------------------------------------------------
    ; BIOS INT 16h, AH=00h: Read key
    ; Returns: AH = scan code, AL = ASCII character
    
    mov ah, 0x00
    int 0x16
    
    ; -----------------------------------------------------------------------
    ; Check for ESC key (scan code 0x01)
    ; -----------------------------------------------------------------------
    cmp ah, 0x01
    jne .not_esc
    mov al, 0xFF                ; Set exit flag
    jmp .done
    
.not_esc:
    ; -----------------------------------------------------------------------
    ; Check for H key - Toggle HSYNC waiting
    ; -----------------------------------------------------------------------
    ; When HSYNC is disabled, palette writes happen at random times
    ; during scanline drawing, causing a "torn" or wavy pattern.
    ; This demonstrates WHY synchronization is necessary!
    
    cmp al, 'h'
    je .toggle_hsync
    cmp al, 'H'
    jne .not_h
.toggle_hsync:
    xor byte [hsync_enabled], 1 ; Toggle: 0->1 or 1->0
    jmp .no_key
    
.not_h:
    ; -----------------------------------------------------------------------
    ; Check for V key - Toggle VSYNC waiting
    ; -----------------------------------------------------------------------
    ; When VSYNC is disabled, we don't wait for frame start before
    ; rendering. The colors will "scroll" up or down the screen
    ; because we're not synchronized to the display refresh.
    
    cmp al, 'v'
    je .toggle_vsync
    cmp al, 'V'
    jne .not_v
.toggle_vsync:
    xor byte [vsync_enabled], 1 ; Toggle: 0->1 or 1->0
    jmp .no_key
    
.not_v:
    ; -----------------------------------------------------------------------
    ; Check for palette selection keys (1-7)
    ; -----------------------------------------------------------------------
    cmp al, '1'
    jb .no_key                  ; Below '1' - ignore
    cmp al, '7'
    ja .no_key                  ; Above '7' - ignore
    
    ; Convert ASCII '1'-'7' to index 0-6
    sub al, '1'
    cmp al, [current_palette]
    je .no_key                  ; Same palette already selected
    
    ; Load the new palette
    mov [current_palette], al
    call load_current_palette
    
.no_key:
    xor al, al                  ; Return 0 (continue running)
    
.done:
    pop bx
    ret

; ============================================================================
; load_current_palette - Copy palette data to working buffer
; ============================================================================
; Copies 400 bytes (200 entries x 2 bytes each) from the selected
; palette's data table to the working color_table buffer.
;
; Using a working buffer allows fast indexed access during rendering,
; which is critical for meeting the tight HBLANK timing requirements.
; ============================================================================
load_current_palette:
    push ax
    push bx
    push cx
    push si
    push di
    
    ; Calculate pointer to selected palette data
    mov al, [current_palette]
    xor ah, ah
    shl ax, 1                   ; Multiply by 2 (word-sized pointers)
    mov bx, ax
    mov si, [palette_table + bx] ; SI = pointer to palette data
    
    ; Copy 400 bytes to working buffer
    mov di, color_table
    mov cx, 400
.copy:
    mov al, [si]
    mov [di], al
    inc si
    inc di
    loop .copy
    
    pop di
    pop si
    pop cx
    pop bx
    pop ax
    ret

; ============================================================================
; render_scanlines - The heart of the demo!
; ============================================================================
; This routine outputs different colors for each of the 200 scanlines.
; It must be precisely synchronized with the CRT beam to avoid visual
; artifacts.
;
; TIMING ANALYSIS (8 MHz V40):
;   - Horizontal line time: ~63.5 µs
;   - Horizontal blanking: ~10 µs (~80 CPU cycles)
;   - Our 3 OUTs: ~4 cycles each = ~12 cycles + setup ≈ 30 cycles
;   - Plenty of margin!
;
; PORT_STATUS bit 0: HSYNC (horizontal sync)
;   - 0 = Beam is drawing visible pixels
;   - 1 = Beam is in horizontal blanking (safe to change palette!)
; ============================================================================
render_scanlines:
    push ax
    push cx
    push dx
    push si
    
    ; -----------------------------------------------------------------------
    ; Disable interrupts during rendering
    ; -----------------------------------------------------------------------
    ; We can't afford to have timer interrupts or other IRQs disrupting
    ; our carefully timed palette writes! Even a few microseconds delay
    ; could cause visible glitches.
    
    cli                         ; Disable interrupts
    
    xor si, si                  ; SI = offset into color_table (starts at 0)
    mov cx, SCREEN_HEIGHT       ; CX = scanline counter (200 lines)
    mov dx, PORT_STATUS         ; DX = status port for fast IN instruction
    
    ; -----------------------------------------------------------------------
    ; Check if HSYNC waiting is enabled
    ; -----------------------------------------------------------------------
    cmp byte [hsync_enabled], 0
    je .no_hsync_loop           ; Skip sync waiting if disabled
    
    ; -----------------------------------------------------------------------
    ; HSYNC-synchronized rendering loop
    ; -----------------------------------------------------------------------
.scanline_loop:
    ; Wait for HSYNC to go LOW (beam is drawing visible area)
    ; We need to catch the transition to ensure we're at the right spot
.wait_low:
    in al, dx                   ; Read status register
    test al, 0x01               ; Test bit 0 (HSYNC)
    jnz .wait_low               ; Loop while HSYNC is high
    
    ; Wait for HSYNC to go HIGH (beam entering horizontal blanking)
    ; NOW is when we can safely write to the palette!
.wait_high:
    in al, dx                   ; Read status register
    test al, 0x01               ; Test bit 0 (HSYNC)
    jz .wait_high               ; Loop while HSYNC is low
    
    ; -----------------------------------------------------------------------
    ; CRITICAL SECTION: Write palette entry 0's new color
    ; -----------------------------------------------------------------------
    ; We're now in HBLANK - write the 3 bytes as fast as possible!
    ;
    ; Palette write sequence:
    ; 1. OUT to PORT_PAL_ADDR: Select palette entry (0x40 = entry 0)
    ; 2. OUT to PORT_PAL_DATA: Write R value (0-7)
    ; 3. OUT to PORT_PAL_DATA: Write G<<4 | B value
    
    mov al, 0x40                ; Select palette entry 0
    out PORT_PAL_ADDR, al
    mov al, [color_table + si]  ; Get R value for this scanline
    out PORT_PAL_DATA, al
    mov al, [color_table + si + 1] ; Get G<<4|B value
    out PORT_PAL_DATA, al
    
    add si, 2                   ; Advance to next color entry
    loop .scanline_loop         ; Decrement CX, loop if not zero
    jmp .done_render
    
    ; -----------------------------------------------------------------------
    ; Non-synchronized rendering loop (for educational demonstration)
    ; -----------------------------------------------------------------------
    ; When HSYNC waiting is disabled, we just blast out palette writes
    ; as fast as possible. This causes visible artifacts because we're
    ; changing colors while the beam is drawing visible pixels!
    
.no_hsync_loop:
.no_sync_scanline:
    mov al, 0x40
    out PORT_PAL_ADDR, al
    mov al, [color_table + si]
    out PORT_PAL_DATA, al
    mov al, [color_table + si + 1]
    out PORT_PAL_DATA, al
    
    add si, 2
    loop .no_sync_scanline
    
.done_render:
    ; -----------------------------------------------------------------------
    ; Reset palette entry 0 to first color for clean top of next frame
    ; -----------------------------------------------------------------------
    mov al, 0x40
    out PORT_PAL_ADDR, al
    xor al, al
    out PORT_PAL_DATA, al
    out PORT_PAL_DATA, al
    
    sti                         ; Re-enable interrupts
    
    pop si
    pop dx
    pop cx
    pop ax
    ret

; ============================================================================
; wait_vblank - Wait for vertical blanking period
; ============================================================================
; The CRT draws 200 visible lines, then has a "vertical blanking" period
; while the beam returns from bottom to top. We synchronize to this to
; ensure our rendering starts at the top of the screen.
;
; PORT_STATUS bit 3: VSYNC (vertical sync)
;   - 0 = Beam is drawing visible lines
;   - 1 = Beam is in vertical blanking
;
; We wait for VSYNC to end, then wait for it to start again.
; This ensures we catch the beginning of the blanking period.
; ============================================================================
wait_vblank:
    ; Check if VSYNC waiting is enabled
    cmp byte [vsync_enabled], 0
    je .skip_vblank             ; Skip if disabled
    
    push ax
    push dx
    mov dx, PORT_STATUS
    
    ; Wait for VSYNC to end (if we're currently in VBLANK)
.wait_end:
    in al, dx
    test al, 0x08               ; Test bit 3 (VSYNC)
    jnz .wait_end               ; Loop while in VBLANK
    
    ; Wait for VSYNC to start (beam finished drawing visible area)
.wait_start:
    in al, dx
    test al, 0x08               ; Test bit 3 (VSYNC)
    jz .wait_start              ; Loop while drawing
    
    pop dx
    pop ax
.skip_vblank:
    ret

; ============================================================================
; enable_graphics_mode - Activate the hidden 160x200x16 mode
; ============================================================================
; Mode 0x4A is an undocumented mode of the Yamaha V6355D that provides:
;   - 160x200 resolution
;   - 16 simultaneous colors from a 512-color palette
;   - Programmable RGB values for each palette entry
;
; This mode is NOT available on standard CGA adapters!
; ============================================================================
enable_graphics_mode:
    mov al, 0x4A                ; Hidden mode value
    out PORT_MODE, al           ; Write to mode register
    ret

; ============================================================================
; clear_screen - Fill video memory with zeros (color index 0)
; ============================================================================
; In 160x200x16 mode, each pixel is 4 bits. Two pixels per byte.
; Video memory is 16KB at segment 0xB000 (not 0xB800 like standard CGA).
;
; We fill everything with 0x00, so all pixels reference palette entry 0.
; Since we change entry 0's color per-scanline, different lines appear
; as different colors!
; ============================================================================
clear_screen:
    push ax
    push cx
    push di
    push es
    
    mov ax, VIDEO_SEG           ; Video memory segment
    mov es, ax
    xor di, di                  ; Start at offset 0
    mov cx, 8192                ; 16KB / 2 = 8192 words
    xor ax, ax                  ; Fill value = 0
    cld                         ; Direction = forward
    rep stosw                   ; Fill memory (fast block fill)
    
    pop es
    pop di
    pop cx
    pop ax
    ret

; ============================================================================
; DATA SECTION
; ============================================================================

; Current state variables
current_palette: db 6           ; Current palette (0-6), default = 7 (Full Rainbow)
hsync_enabled:   db 1           ; HSYNC waiting: 1=on, 0=off
vsync_enabled:   db 1           ; VSYNC waiting: 1=on, 0=off

; ============================================================================
; Palette pointer table
; ============================================================================
; Each entry points to a 400-byte palette data block (200 colors x 2 bytes)

palette_table:
    dw pal1_rainbow_gray        ; 1: Smooth rainbow + grayscale
    dw pal2_cube_snake          ; 2: RGB cube traversal (200 unique colors)
    dw pal3_sunset              ; 3: Warm sunset gradient
    dw pal4_ocean               ; 4: Cool ocean gradient
    dw pal5_fire                ; 5: Fire gradient
    dw pal6_grayscale           ; 6: Full grayscale
    dw pal7_fullrainbow         ; 7: Full rainbow (200 lines)

; ============================================================================
; PALETTE DATA
; ============================================================================
; Each palette is 200 entries, 2 bytes each:
;   Byte 0: R (red, 0-7)
;   Byte 1: G<<4 | B (green in high nibble, blue in low nibble)
;
; Example: Bright yellow = R=7, G=7, B=0 = bytes: 7, 0x70
; Example: Purple = R=4, G=0, B=7 = bytes: 4, 0x07
; Example: Gray = R=3, G=3, B=3 = bytes: 3, 0x33
; ============================================================================

; ============================================================================
; PALETTE 1: Smooth Rainbow + Grayscale (166 + 34 lines)
; ============================================================================
; This palette demonstrates a smooth HSV-style rainbow that cycles through
; all hues (Red→Yellow→Green→Cyan→Blue→Magenta→Red), followed by a
; grayscale ramp at the bottom. Shows both color and luminance capability.

pal1_rainbow_gray:
    ; RED to YELLOW (28 entries) - Red stays max, green ramps up
    db 7, 0x00, 7, 0x00, 7, 0x00, 7, 0x10
    db 7, 0x10, 7, 0x10, 7, 0x10, 7, 0x20
    db 7, 0x20, 7, 0x20, 7, 0x20, 7, 0x30
    db 7, 0x30, 7, 0x30, 7, 0x30, 7, 0x40
    db 7, 0x40, 7, 0x40, 7, 0x40, 7, 0x50
    db 7, 0x50, 7, 0x50, 7, 0x50, 7, 0x60
    db 7, 0x60, 7, 0x60, 7, 0x60, 7, 0x70
    ; YELLOW to GREEN (28 entries) - Green stays max, red ramps down
    db 7, 0x70, 7, 0x70, 7, 0x70, 6, 0x70
    db 6, 0x70, 6, 0x70, 6, 0x70, 5, 0x70
    db 5, 0x70, 5, 0x70, 5, 0x70, 4, 0x70
    db 4, 0x70, 4, 0x70, 4, 0x70, 3, 0x70
    db 3, 0x70, 3, 0x70, 3, 0x70, 2, 0x70
    db 2, 0x70, 2, 0x70, 2, 0x70, 1, 0x70
    db 1, 0x70, 1, 0x70, 1, 0x70, 0, 0x70
    ; GREEN to CYAN (28 entries) - Green stays max, blue ramps up
    db 0, 0x70, 0, 0x70, 0, 0x70, 0, 0x71
    db 0, 0x71, 0, 0x71, 0, 0x71, 0, 0x72
    db 0, 0x72, 0, 0x72, 0, 0x72, 0, 0x73
    db 0, 0x73, 0, 0x73, 0, 0x73, 0, 0x74
    db 0, 0x74, 0, 0x74, 0, 0x74, 0, 0x75
    db 0, 0x75, 0, 0x75, 0, 0x75, 0, 0x76
    db 0, 0x76, 0, 0x76, 0, 0x76, 0, 0x77
    ; CYAN to BLUE (28 entries) - Blue stays max, green ramps down
    db 0, 0x77, 0, 0x77, 0, 0x77, 0, 0x67
    db 0, 0x67, 0, 0x67, 0, 0x67, 0, 0x57
    db 0, 0x57, 0, 0x57, 0, 0x57, 0, 0x47
    db 0, 0x47, 0, 0x47, 0, 0x47, 0, 0x37
    db 0, 0x37, 0, 0x37, 0, 0x37, 0, 0x27
    db 0, 0x27, 0, 0x27, 0, 0x27, 0, 0x17
    db 0, 0x17, 0, 0x17, 0, 0x17, 0, 0x07
    ; BLUE to MAGENTA (28 entries) - Blue stays max, red ramps up
    db 0, 0x07, 0, 0x07, 0, 0x07, 1, 0x07
    db 1, 0x07, 1, 0x07, 1, 0x07, 2, 0x07
    db 2, 0x07, 2, 0x07, 2, 0x07, 3, 0x07
    db 3, 0x07, 3, 0x07, 3, 0x07, 4, 0x07
    db 4, 0x07, 4, 0x07, 4, 0x07, 5, 0x07
    db 5, 0x07, 5, 0x07, 5, 0x07, 6, 0x07
    db 6, 0x07, 6, 0x07, 6, 0x07, 7, 0x07
    ; MAGENTA to RED (26 entries) - Red stays max, blue ramps down
    db 7, 0x07, 7, 0x07, 7, 0x06, 7, 0x06
    db 7, 0x06, 7, 0x06, 7, 0x05, 7, 0x05
    db 7, 0x05, 7, 0x05, 7, 0x04, 7, 0x04
    db 7, 0x04, 7, 0x04, 7, 0x03, 7, 0x03
    db 7, 0x03, 7, 0x03, 7, 0x02, 7, 0x02
    db 7, 0x02, 7, 0x02, 7, 0x01, 7, 0x01
    db 7, 0x01, 7, 0x00
    ; GRAYSCALE (34 entries) - R=G=B for neutral gray
    db 0, 0x00, 0, 0x00, 1, 0x11, 1, 0x11
    db 1, 0x11, 2, 0x22, 2, 0x22, 2, 0x22
    db 2, 0x22, 3, 0x33, 3, 0x33, 3, 0x33
    db 3, 0x33, 3, 0x33, 4, 0x44, 4, 0x44
    db 4, 0x44, 4, 0x44, 4, 0x44, 5, 0x55
    db 5, 0x55, 5, 0x55, 5, 0x55, 5, 0x55
    db 6, 0x66, 6, 0x66, 6, 0x66, 6, 0x66
    db 6, 0x66, 7, 0x77, 7, 0x77, 7, 0x77
    db 7, 0x77, 7, 0x77

; ============================================================================
; PALETTE 2: RGB Cube Snake (200 unique colors from 512)
; ============================================================================
; This palette traverses the RGB333 color cube in a "snake" pattern,
; showing 200 unique colors out of the 512 possible. Notice how it
; zig-zags through the color space - each layer of blue contains a
; back-and-forth sweep through red and green.

pal2_cube_snake:
    ; Layer B=0: R varies, G varies (snake pattern)
    db 0,0x00, 1,0x00, 2,0x00, 3,0x00, 4,0x00, 5,0x00, 6,0x00, 7,0x00
    db 7,0x10, 6,0x10, 5,0x10, 4,0x10, 3,0x10, 2,0x10, 1,0x10, 0,0x10
    db 0,0x20, 1,0x20, 2,0x20, 3,0x20, 4,0x20, 5,0x20, 6,0x20, 7,0x20
    db 7,0x30, 6,0x30, 5,0x30, 4,0x30, 3,0x30, 2,0x30, 1,0x30, 0,0x30
    db 0,0x40, 1,0x40, 2,0x40, 3,0x40, 4,0x40, 5,0x40, 6,0x40, 7,0x40
    db 7,0x50, 6,0x50, 5,0x50, 4,0x50, 3,0x50, 2,0x50, 1,0x50, 0,0x50
    db 0,0x60, 1,0x60, 2,0x60, 3,0x60, 4,0x60, 5,0x60, 6,0x60, 7,0x60
    db 7,0x70, 6,0x70, 5,0x70, 4,0x70, 3,0x70, 2,0x70, 1,0x70, 0,0x70
    ; Layer B=1
    db 0,0x71, 1,0x71, 2,0x71, 3,0x71, 4,0x71, 5,0x71, 6,0x71, 7,0x71
    db 7,0x61, 6,0x61, 5,0x61, 4,0x61, 3,0x61, 2,0x61, 1,0x61, 0,0x61
    db 0,0x51, 1,0x51, 2,0x51, 3,0x51, 4,0x51, 5,0x51, 6,0x51, 7,0x51
    db 7,0x41, 6,0x41, 5,0x41, 4,0x41, 3,0x41, 2,0x41, 1,0x41, 0,0x41
    db 0,0x31, 1,0x31, 2,0x31, 3,0x31, 4,0x31, 5,0x31, 6,0x31, 7,0x31
    db 7,0x21, 6,0x21, 5,0x21, 4,0x21, 3,0x21, 2,0x21, 1,0x21, 0,0x21
    db 0,0x11, 1,0x11, 2,0x11, 3,0x11, 4,0x11, 5,0x11, 6,0x11, 7,0x11
    db 7,0x01, 6,0x01, 5,0x01, 4,0x01, 3,0x01, 2,0x01, 1,0x01, 0,0x01
    ; Layer B=2
    db 0,0x02, 1,0x02, 2,0x02, 3,0x02, 4,0x02, 5,0x02, 6,0x02, 7,0x02
    db 7,0x12, 6,0x12, 5,0x12, 4,0x12, 3,0x12, 2,0x12, 1,0x12, 0,0x12
    db 0,0x22, 1,0x22, 2,0x22, 3,0x22, 4,0x22, 5,0x22, 6,0x22, 7,0x22
    db 7,0x32, 6,0x32, 5,0x32, 4,0x32, 3,0x32, 2,0x32, 1,0x32, 0,0x32
    db 0,0x42, 1,0x42, 2,0x42, 3,0x42, 4,0x42, 5,0x42, 6,0x42, 7,0x42
    db 7,0x52, 6,0x52, 5,0x52, 4,0x52, 3,0x52, 2,0x52, 1,0x52, 0,0x52
    db 0,0x62, 1,0x62, 2,0x62, 3,0x62, 4,0x62, 5,0x62, 6,0x62, 7,0x62
    db 7,0x72, 6,0x72, 5,0x72, 4,0x72, 3,0x72, 2,0x72, 1,0x72, 0,0x72
    ; Remaining 8 colors to reach 200
    db 0,0x03, 1,0x03, 2,0x03, 3,0x03, 4,0x03, 5,0x03, 6,0x03, 7,0x03

; ============================================================================
; PALETTE 3: Warm Sunset (Reds, Oranges, Yellows, Purples)
; ============================================================================
; Simulates the colors of a sunset: dark at the horizon, warming through
; reds and oranges to bright yellow, then fading through purple to dark.

pal3_sunset:
    ; Black to dark red (20)
    db 0,0x00, 0,0x00, 0,0x00, 0,0x00, 0,0x00
    db 1,0x00, 1,0x00, 1,0x00, 1,0x00, 1,0x00
    db 2,0x00, 2,0x00, 2,0x00, 2,0x00, 2,0x00
    db 3,0x00, 3,0x00, 3,0x00, 3,0x00, 3,0x00
    ; Dark red to red (20)
    db 4,0x00, 4,0x00, 4,0x00, 4,0x00, 4,0x00
    db 5,0x00, 5,0x00, 5,0x00, 5,0x00, 5,0x00
    db 6,0x00, 6,0x00, 6,0x00, 6,0x00, 6,0x00
    db 7,0x00, 7,0x00, 7,0x00, 7,0x00, 7,0x00
    ; Red to orange (20)
    db 7,0x10, 7,0x10, 7,0x10, 7,0x10, 7,0x10
    db 7,0x20, 7,0x20, 7,0x20, 7,0x20, 7,0x20
    db 7,0x30, 7,0x30, 7,0x30, 7,0x30, 7,0x30
    db 7,0x40, 7,0x40, 7,0x40, 7,0x40, 7,0x40
    ; Orange to yellow (20)
    db 7,0x50, 7,0x50, 7,0x50, 7,0x50, 7,0x50
    db 7,0x60, 7,0x60, 7,0x60, 7,0x60, 7,0x60
    db 7,0x70, 7,0x70, 7,0x70, 7,0x70, 7,0x70
    db 7,0x70, 7,0x70, 7,0x70, 7,0x70, 7,0x70
    ; Yellow to white-ish (20)
    db 7,0x71, 7,0x71, 7,0x71, 7,0x71, 7,0x71
    db 7,0x72, 7,0x72, 7,0x72, 7,0x72, 7,0x72
    db 7,0x73, 7,0x73, 7,0x73, 7,0x73, 7,0x73
    db 7,0x74, 7,0x74, 7,0x74, 7,0x74, 7,0x74
    ; Fade to purple (20)
    db 7,0x64, 7,0x64, 7,0x64, 7,0x64, 7,0x64
    db 7,0x54, 7,0x54, 7,0x54, 7,0x54, 7,0x54
    db 7,0x44, 7,0x44, 7,0x44, 7,0x44, 7,0x44
    db 7,0x34, 7,0x34, 7,0x34, 7,0x34, 7,0x34
    ; Purple to magenta (20)
    db 7,0x24, 7,0x24, 7,0x24, 7,0x24, 7,0x24
    db 7,0x14, 7,0x14, 7,0x14, 7,0x14, 7,0x14
    db 7,0x05, 7,0x05, 7,0x05, 7,0x05, 7,0x05
    db 7,0x06, 7,0x06, 7,0x06, 7,0x06, 7,0x06
    ; Magenta to dark (20)
    db 6,0x05, 6,0x05, 6,0x05, 6,0x05, 6,0x05
    db 5,0x04, 5,0x04, 5,0x04, 5,0x04, 5,0x04
    db 4,0x03, 4,0x03, 4,0x03, 4,0x03, 4,0x03
    db 3,0x02, 3,0x02, 3,0x02, 3,0x02, 3,0x02
    ; Dark to black (20)
    db 2,0x01, 2,0x01, 2,0x01, 2,0x01, 2,0x01
    db 2,0x01, 2,0x01, 2,0x01, 2,0x01, 2,0x01
    db 1,0x00, 1,0x00, 1,0x00, 1,0x00, 1,0x00
    db 0,0x00, 0,0x00, 0,0x00, 0,0x00, 0,0x00
    ; Extra 20 to reach 200
    db 0,0x00, 0,0x00, 0,0x00, 0,0x00, 0,0x00
    db 1,0x01, 1,0x01, 1,0x01, 1,0x01, 1,0x01
    db 2,0x02, 2,0x02, 2,0x02, 2,0x02, 2,0x02
    db 3,0x03, 3,0x03, 3,0x03, 3,0x03, 3,0x03

; ============================================================================
; PALETTE 4: Cool Ocean (Blues, Cyans, Greens)
; ============================================================================
; Evokes underwater scenes with deep blues transitioning through cyan
; to green, like light filtering through ocean water.

pal4_ocean:
    ; Dark blue to blue (25)
    db 0,0x01, 0,0x01, 0,0x01, 0,0x01, 0,0x01
    db 0,0x02, 0,0x02, 0,0x02, 0,0x02, 0,0x02
    db 0,0x03, 0,0x03, 0,0x03, 0,0x03, 0,0x03
    db 0,0x04, 0,0x04, 0,0x04, 0,0x04, 0,0x04
    db 0,0x05, 0,0x05, 0,0x05, 0,0x05, 0,0x05
    ; Blue to bright blue (25)
    db 0,0x06, 0,0x06, 0,0x06, 0,0x06, 0,0x06
    db 0,0x07, 0,0x07, 0,0x07, 0,0x07, 0,0x07
    db 0,0x17, 0,0x17, 0,0x17, 0,0x17, 0,0x17
    db 0,0x27, 0,0x27, 0,0x27, 0,0x27, 0,0x27
    db 0,0x37, 0,0x37, 0,0x37, 0,0x37, 0,0x37
    ; Blue to cyan (25)
    db 0,0x47, 0,0x47, 0,0x47, 0,0x47, 0,0x47
    db 0,0x57, 0,0x57, 0,0x57, 0,0x57, 0,0x57
    db 0,0x67, 0,0x67, 0,0x67, 0,0x67, 0,0x67
    db 0,0x77, 0,0x77, 0,0x77, 0,0x77, 0,0x77
    db 0,0x76, 0,0x76, 0,0x76, 0,0x76, 0,0x76
    ; Cyan to green (25)
    db 0,0x75, 0,0x75, 0,0x75, 0,0x75, 0,0x75
    db 0,0x74, 0,0x74, 0,0x74, 0,0x74, 0,0x74
    db 0,0x73, 0,0x73, 0,0x73, 0,0x73, 0,0x73
    db 0,0x72, 0,0x72, 0,0x72, 0,0x72, 0,0x72
    db 0,0x71, 0,0x71, 0,0x71, 0,0x71, 0,0x71
    ; Green (25)
    db 0,0x70, 0,0x70, 0,0x70, 0,0x70, 0,0x70
    db 0,0x60, 0,0x60, 0,0x60, 0,0x60, 0,0x60
    db 0,0x50, 0,0x50, 0,0x50, 0,0x50, 0,0x50
    db 1,0x70, 1,0x70, 1,0x70, 1,0x70, 1,0x70
    db 1,0x60, 1,0x60, 1,0x60, 1,0x60, 1,0x60
    ; Green-cyan mix (25)
    db 0,0x66, 0,0x66, 0,0x66, 0,0x66, 0,0x66
    db 0,0x55, 0,0x55, 0,0x55, 0,0x55, 0,0x55
    db 0,0x44, 0,0x44, 0,0x44, 0,0x44, 0,0x44
    db 1,0x55, 1,0x55, 1,0x55, 1,0x55, 1,0x55
    db 1,0x66, 1,0x66, 1,0x66, 1,0x66, 1,0x66
    ; Back to dark blue (25)
    db 0,0x45, 0,0x45, 0,0x45, 0,0x45, 0,0x45
    db 0,0x34, 0,0x34, 0,0x34, 0,0x34, 0,0x34
    db 0,0x23, 0,0x23, 0,0x23, 0,0x23, 0,0x23
    db 0,0x12, 0,0x12, 0,0x12, 0,0x12, 0,0x12
    db 0,0x01, 0,0x01, 0,0x01, 0,0x01, 0,0x01
    ; Dark (25)
    db 0,0x00, 0,0x00, 0,0x00, 0,0x00, 0,0x00
    db 0,0x11, 0,0x11, 0,0x11, 0,0x11, 0,0x11
    db 0,0x22, 0,0x22, 0,0x22, 0,0x22, 0,0x22
    db 0,0x33, 0,0x33, 0,0x33, 0,0x33, 0,0x33
    db 0,0x44, 0,0x44, 0,0x44, 0,0x44, 0,0x44

; ============================================================================
; PALETTE 5: Fire (Black, Red, Orange, Yellow, White)
; ============================================================================
; Classic fire gradient: dark coals at bottom, rising through red
; flames, orange, bright yellow, to white-hot at the peak.
; Symmetric pattern creates a flame-like appearance.

pal5_fire:
    ; Black (20)
    db 0,0x00, 0,0x00, 0,0x00, 0,0x00, 0,0x00
    db 0,0x00, 0,0x00, 0,0x00, 0,0x00, 0,0x00
    db 0,0x00, 0,0x00, 0,0x00, 0,0x00, 0,0x00
    db 0,0x00, 0,0x00, 0,0x00, 0,0x00, 0,0x00
    ; Black to dark red (20)
    db 1,0x00, 1,0x00, 1,0x00, 1,0x00, 1,0x00
    db 2,0x00, 2,0x00, 2,0x00, 2,0x00, 2,0x00
    db 3,0x00, 3,0x00, 3,0x00, 3,0x00, 3,0x00
    db 4,0x00, 4,0x00, 4,0x00, 4,0x00, 4,0x00
    ; Dark red to red (20)
    db 5,0x00, 5,0x00, 5,0x00, 5,0x00, 5,0x00
    db 6,0x00, 6,0x00, 6,0x00, 6,0x00, 6,0x00
    db 7,0x00, 7,0x00, 7,0x00, 7,0x00, 7,0x00
    db 7,0x00, 7,0x00, 7,0x00, 7,0x00, 7,0x00
    ; Red to orange (20)
    db 7,0x10, 7,0x10, 7,0x10, 7,0x10, 7,0x10
    db 7,0x20, 7,0x20, 7,0x20, 7,0x20, 7,0x20
    db 7,0x30, 7,0x30, 7,0x30, 7,0x30, 7,0x30
    db 7,0x40, 7,0x40, 7,0x40, 7,0x40, 7,0x40
    ; Orange to yellow (20)
    db 7,0x50, 7,0x50, 7,0x50, 7,0x50, 7,0x50
    db 7,0x60, 7,0x60, 7,0x60, 7,0x60, 7,0x60
    db 7,0x70, 7,0x70, 7,0x70, 7,0x70, 7,0x70
    db 7,0x70, 7,0x70, 7,0x70, 7,0x70, 7,0x70
    ; Yellow to white (20)
    db 7,0x71, 7,0x71, 7,0x71, 7,0x71, 7,0x71
    db 7,0x72, 7,0x72, 7,0x72, 7,0x72, 7,0x72
    db 7,0x73, 7,0x73, 7,0x73, 7,0x73, 7,0x73
    db 7,0x74, 7,0x74, 7,0x74, 7,0x74, 7,0x74
    ; White (20)
    db 7,0x75, 7,0x75, 7,0x75, 7,0x75, 7,0x75
    db 7,0x76, 7,0x76, 7,0x76, 7,0x76, 7,0x76
    db 7,0x77, 7,0x77, 7,0x77, 7,0x77, 7,0x77
    db 7,0x77, 7,0x77, 7,0x77, 7,0x77, 7,0x77
    ; White to yellow (20)
    db 7,0x76, 7,0x76, 7,0x76, 7,0x76, 7,0x76
    db 7,0x75, 7,0x75, 7,0x75, 7,0x75, 7,0x75
    db 7,0x74, 7,0x74, 7,0x74, 7,0x74, 7,0x74
    db 7,0x73, 7,0x73, 7,0x73, 7,0x73, 7,0x73
    ; Yellow back to orange (20)
    db 7,0x72, 7,0x72, 7,0x72, 7,0x72, 7,0x72
    db 7,0x71, 7,0x71, 7,0x71, 7,0x71, 7,0x71
    db 7,0x70, 7,0x70, 7,0x70, 7,0x70, 7,0x70
    db 7,0x60, 7,0x60, 7,0x60, 7,0x60, 7,0x60
    ; Orange back to red (20)
    db 7,0x50, 7,0x50, 7,0x50, 7,0x50, 7,0x50
    db 7,0x40, 7,0x40, 7,0x40, 7,0x40, 7,0x40
    db 7,0x30, 7,0x30, 7,0x30, 7,0x30, 7,0x30
    db 7,0x20, 7,0x20, 7,0x20, 7,0x20, 7,0x20

; ============================================================================
; PALETTE 6: Full Grayscale (Black to White to Black)
; ============================================================================
; Demonstrates the luminance capability of the RGB333 palette.
; With R=G=B, we get 8 gray levels (0-7). This palette smoothly
; transitions from black to white and back to black.

pal6_grayscale:
    ; Black to white (100 lines)
    db 0,0x00, 0,0x00, 0,0x00, 0,0x00, 0,0x00, 0,0x00, 0,0x00
    db 1,0x11, 1,0x11, 1,0x11, 1,0x11, 1,0x11, 1,0x11, 1,0x11
    db 1,0x11, 1,0x11, 1,0x11, 1,0x11, 1,0x11, 1,0x11
    db 2,0x22, 2,0x22, 2,0x22, 2,0x22, 2,0x22, 2,0x22, 2,0x22
    db 2,0x22, 2,0x22, 2,0x22, 2,0x22, 2,0x22, 2,0x22
    db 3,0x33, 3,0x33, 3,0x33, 3,0x33, 3,0x33, 3,0x33, 3,0x33
    db 3,0x33, 3,0x33, 3,0x33, 3,0x33, 3,0x33, 3,0x33
    db 4,0x44, 4,0x44, 4,0x44, 4,0x44, 4,0x44, 4,0x44, 4,0x44
    db 4,0x44, 4,0x44, 4,0x44, 4,0x44, 4,0x44, 4,0x44
    db 5,0x55, 5,0x55, 5,0x55, 5,0x55, 5,0x55, 5,0x55, 5,0x55
    db 5,0x55, 5,0x55, 5,0x55, 5,0x55, 5,0x55, 5,0x55
    db 6,0x66, 6,0x66, 6,0x66, 6,0x66, 6,0x66, 6,0x66, 6,0x66
    db 6,0x66, 6,0x66, 6,0x66, 6,0x66, 6,0x66, 6,0x66
    db 7,0x77, 7,0x77, 7,0x77, 7,0x77, 7,0x77, 7,0x77, 7,0x77
    db 7,0x77, 7,0x77, 7,0x77, 7,0x77
    ; White to black (100 lines)
    db 7,0x77, 7,0x77, 7,0x77, 7,0x77, 7,0x77, 7,0x77, 7,0x77
    db 6,0x66, 6,0x66, 6,0x66, 6,0x66, 6,0x66, 6,0x66, 6,0x66
    db 6,0x66, 6,0x66, 6,0x66, 6,0x66, 6,0x66, 6,0x66
    db 5,0x55, 5,0x55, 5,0x55, 5,0x55, 5,0x55, 5,0x55, 5,0x55
    db 5,0x55, 5,0x55, 5,0x55, 5,0x55, 5,0x55, 5,0x55
    db 4,0x44, 4,0x44, 4,0x44, 4,0x44, 4,0x44, 4,0x44, 4,0x44
    db 4,0x44, 4,0x44, 4,0x44, 4,0x44, 4,0x44, 4,0x44
    db 3,0x33, 3,0x33, 3,0x33, 3,0x33, 3,0x33, 3,0x33, 3,0x33
    db 3,0x33, 3,0x33, 3,0x33, 3,0x33, 3,0x33, 3,0x33
    db 2,0x22, 2,0x22, 2,0x22, 2,0x22, 2,0x22, 2,0x22, 2,0x22
    db 2,0x22, 2,0x22, 2,0x22, 2,0x22, 2,0x22, 2,0x22
    db 1,0x11, 1,0x11, 1,0x11, 1,0x11, 1,0x11, 1,0x11, 1,0x11
    db 1,0x11, 1,0x11, 1,0x11, 1,0x11, 1,0x11, 1,0x11
    db 0,0x00, 0,0x00, 0,0x00, 0,0x00, 0,0x00, 0,0x00, 0,0x00
    db 0,0x00, 0,0x00, 0,0x00, 0,0x00

; ============================================================================
; PALETTE 7: Full Rainbow (200 lines, complete hue cycle)
; ============================================================================
; The "hero" palette - a full 200-line rainbow that cycles through
; the complete hue spectrum without any grayscale. This matches the
; classic color bar test pattern used in video calibration.
;
; HSV Hue Cycle (at maximum saturation and brightness):
;   Red (0°) → Yellow (60°) → Green (120°) → Cyan (180°) →
;   Blue (240°) → Magenta (300°) → Red (360°/0°)

pal7_fullrainbow:
    ; RED to YELLOW (33 lines) - R=7, G ramps 0->7, B=0
    db 7,0x00, 7,0x00, 7,0x00, 7,0x00, 7,0x10
    db 7,0x10, 7,0x10, 7,0x10, 7,0x20, 7,0x20
    db 7,0x20, 7,0x20, 7,0x30, 7,0x30, 7,0x30
    db 7,0x30, 7,0x40, 7,0x40, 7,0x40, 7,0x40
    db 7,0x50, 7,0x50, 7,0x50, 7,0x50, 7,0x60
    db 7,0x60, 7,0x60, 7,0x60, 7,0x70, 7,0x70
    db 7,0x70, 7,0x70, 7,0x70
    ; YELLOW to GREEN (33 lines) - R ramps 7->0, G=7, B=0
    db 7,0x70, 7,0x70, 7,0x70, 7,0x70, 6,0x70
    db 6,0x70, 6,0x70, 6,0x70, 5,0x70, 5,0x70
    db 5,0x70, 5,0x70, 4,0x70, 4,0x70, 4,0x70
    db 4,0x70, 3,0x70, 3,0x70, 3,0x70, 3,0x70
    db 2,0x70, 2,0x70, 2,0x70, 2,0x70, 1,0x70
    db 1,0x70, 1,0x70, 1,0x70, 0,0x70, 0,0x70
    db 0,0x70, 0,0x70, 0,0x70
    ; GREEN to CYAN (33 lines) - R=0, G=7, B ramps 0->7
    db 0,0x70, 0,0x70, 0,0x70, 0,0x70, 0,0x71
    db 0,0x71, 0,0x71, 0,0x71, 0,0x72, 0,0x72
    db 0,0x72, 0,0x72, 0,0x73, 0,0x73, 0,0x73
    db 0,0x73, 0,0x74, 0,0x74, 0,0x74, 0,0x74
    db 0,0x75, 0,0x75, 0,0x75, 0,0x75, 0,0x76
    db 0,0x76, 0,0x76, 0,0x76, 0,0x77, 0,0x77
    db 0,0x77, 0,0x77, 0,0x77
    ; CYAN to BLUE (33 lines) - R=0, G ramps 7->0, B=7
    db 0,0x77, 0,0x77, 0,0x77, 0,0x77, 0,0x67
    db 0,0x67, 0,0x67, 0,0x67, 0,0x57, 0,0x57
    db 0,0x57, 0,0x57, 0,0x47, 0,0x47, 0,0x47
    db 0,0x47, 0,0x37, 0,0x37, 0,0x37, 0,0x37
    db 0,0x27, 0,0x27, 0,0x27, 0,0x27, 0,0x17
    db 0,0x17, 0,0x17, 0,0x17, 0,0x07, 0,0x07
    db 0,0x07, 0,0x07, 0,0x07
    ; BLUE to MAGENTA (34 lines) - R ramps 0->7, G=0, B=7
    db 0,0x07, 0,0x07, 0,0x07, 0,0x07, 1,0x07
    db 1,0x07, 1,0x07, 1,0x07, 2,0x07, 2,0x07
    db 2,0x07, 2,0x07, 3,0x07, 3,0x07, 3,0x07
    db 3,0x07, 4,0x07, 4,0x07, 4,0x07, 4,0x07
    db 5,0x07, 5,0x07, 5,0x07, 5,0x07, 6,0x07
    db 6,0x07, 6,0x07, 6,0x07, 7,0x07, 7,0x07
    db 7,0x07, 7,0x07, 7,0x07, 7,0x07
    ; MAGENTA to RED (34 lines) - R=7, G=0, B ramps 7->0
    db 7,0x07, 7,0x07, 7,0x07, 7,0x07, 7,0x06
    db 7,0x06, 7,0x06, 7,0x06, 7,0x05, 7,0x05
    db 7,0x05, 7,0x05, 7,0x04, 7,0x04, 7,0x04
    db 7,0x04, 7,0x03, 7,0x03, 7,0x03, 7,0x03
    db 7,0x02, 7,0x02, 7,0x02, 7,0x02, 7,0x01
    db 7,0x01, 7,0x01, 7,0x01, 7,0x00, 7,0x00
    db 7,0x00, 7,0x00, 7,0x00, 7,0x00

; ============================================================================
; Working color table (copied from selected palette)
; ============================================================================
; This buffer holds the currently active palette data.
; Using a working buffer allows fast indexed access during the
; time-critical rendering loop.

color_table: times 400 db 0

; ============================================================================
; END OF PROGRAM
; ============================================================================
