; ============================================================================
; PALRAM4.ASM - Scanline Palette Demo - During HSYNC - Clean for use with further experimentation
; ============================================================================
;
; EDUCATIONAL DEMONSTRATION: 200 Colors on Screen Simultaneously
;
; This program demonstrates a classic "demo scene" technique: changing the
; video palette during the horizontal blanking interval to display more
; colors than the hardware normally allows.
;
; Written for NASM assembler
; Target: Olivetti Prodest PC1 / M24 with Yamaha V6355D video controller
; CPU: NEC V40 (80186 compatible) @ 8 MHz
;
; By Retro Erik - 2026

; ** The plan is to test 4 method. We have tested method 1 and 2 
;   1. PORT_COLOR (0xD9 or 0x3D9): 1 OUT per scanline, 16 palette indices (fast, limited). Tested in 03-raster-bars
; **  2. Palette RAM (0xDD/0xDE or 0x3DD/0x3DE): 3 OUTs per scanline, RGB333 (512 colors). - Tested in 05-scanline-palette
;   3. PIT interrupt raster (8088MPH/Area5150): timer IRQs schedule mid-scanline updates.
;   4. CGA palette flip (0x3D8): toggle between the two CGA palettes mid-scanline.
;
; DISTINGUISHES THIS VERSION:
;   - H/V SYNC toggle experimentation (press H/V)
;   - Detailed hardware documentation
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
NUM_PALETTES    equ 1       ; Number of available palette modes

; ============================================================================
; MAIN PROGRAM ENTRY POINT
; ============================================================================
main:
    ; -----------------------------------------------------------------------
    ; Initialize demo state
    ; -----------------------------------------------------------------------
    ; Set default palette to #7 (Full Rainbow) and enable both sync modes
    
    mov byte [current_palette], 0   ; Palette 1 (index 0) = Full Rainbow
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
    dw pal7_fullrainbow         ; 7: Full rainbow (200 lines)

; ============================================================================
; PALETTE DATA
; ============================================================================

; ============================================================================
; PALETTE 7: Full Rainbow (200 lines, complete hue cycle)
; ============================================================================
; ============================================================================
; Full spectrum rainbow: Red → Yellow → Green → Cyan → Blue → Magenta → Red

pal7_fullrainbow:
    ; RED to YELLOW (33)
    db 7,0x00, 7,0x00, 7,0x00, 7,0x00, 7,0x10, 7,0x10, 7,0x10, 7,0x10
    db 7,0x20, 7,0x20, 7,0x20, 7,0x20, 7,0x30, 7,0x30, 7,0x30, 7,0x30
    db 7,0x40, 7,0x40, 7,0x40, 7,0x40, 7,0x50, 7,0x50, 7,0x50, 7,0x50
    db 7,0x60, 7,0x60, 7,0x60, 7,0x60, 7,0x70, 7,0x70, 7,0x70, 7,0x70
    db 7,0x70
    ; YELLOW to GREEN (33)
    db 7,0x70, 7,0x70, 7,0x70, 7,0x70, 6,0x70, 6,0x70, 6,0x70, 6,0x70
    db 5,0x70, 5,0x70, 5,0x70, 5,0x70, 4,0x70, 4,0x70, 4,0x70, 4,0x70
    db 3,0x70, 3,0x70, 3,0x70, 3,0x70, 2,0x70, 2,0x70, 2,0x70, 2,0x70
    db 1,0x70, 1,0x70, 1,0x70, 1,0x70, 0,0x70, 0,0x70, 0,0x70, 0,0x70
    db 0,0x70
    ; GREEN to CYAN (33)
    db 0,0x70, 0,0x70, 0,0x70, 0,0x70, 0,0x71, 0,0x71, 0,0x71, 0,0x71
    db 0,0x72, 0,0x72, 0,0x72, 0,0x72, 0,0x73, 0,0x73, 0,0x73, 0,0x73
    db 0,0x74, 0,0x74, 0,0x74, 0,0x74, 0,0x75, 0,0x75, 0,0x75, 0,0x75
    db 0,0x76, 0,0x76, 0,0x76, 0,0x76, 0,0x77, 0,0x77, 0,0x77, 0,0x77
    db 0,0x77
    ; CYAN to BLUE (33)
    db 0,0x77, 0,0x77, 0,0x77, 0,0x77, 0,0x67, 0,0x67, 0,0x67, 0,0x67
    db 0,0x57, 0,0x57, 0,0x57, 0,0x57, 0,0x47, 0,0x47, 0,0x47, 0,0x47
    db 0,0x37, 0,0x37, 0,0x37, 0,0x37, 0,0x27, 0,0x27, 0,0x27, 0,0x27
    db 0,0x17, 0,0x17, 0,0x17, 0,0x17, 0,0x07, 0,0x07, 0,0x07, 0,0x07
    db 0,0x07
    ; BLUE to MAGENTA (34)
    db 0,0x07, 0,0x07, 0,0x07, 0,0x07, 1,0x07, 1,0x07, 1,0x07, 1,0x07
    db 2,0x07, 2,0x07, 2,0x07, 2,0x07, 3,0x07, 3,0x07, 3,0x07, 3,0x07
    db 4,0x07, 4,0x07, 4,0x07, 4,0x07, 5,0x07, 5,0x07, 5,0x07, 5,0x07
    db 6,0x07, 6,0x07, 6,0x07, 6,0x07, 7,0x07, 7,0x07, 7,0x07, 7,0x07
    db 7,0x07, 7,0x07
    ; MAGENTA to RED (34)
    db 7,0x07, 7,0x07, 7,0x07, 7,0x07, 7,0x06, 7,0x06, 7,0x06, 7,0x06
    db 7,0x05, 7,0x05, 7,0x05, 7,0x05, 7,0x04, 7,0x04, 7,0x04, 7,0x04
    db 7,0x03, 7,0x03, 7,0x03, 7,0x03, 7,0x02, 7,0x02, 7,0x02, 7,0x02
    db 7,0x01, 7,0x01, 7,0x01, 7,0x01, 7,0x00, 7,0x00, 7,0x00, 7,0x00
    db 7,0x00, 7,0x00

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
