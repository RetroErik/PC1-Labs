; ============================================================================
; DEMO5.ASM - Scrolling BMP Image with Animated Raster Bars
; Olivetti Prodest PC1 - V6355D 160x200x16 Hidden Graphics Mode
; Written for NASM - NEC V40 @ 8 MHz (80186 instruction set)
; By RetroErik - 2026 with GitHub Copilot
;
; Description:
;   Loads a 4-bit BMP image and scrolls/pans it around the screen using
;   sine-wave motion, while two horizontal raster bars move independently.
;   The bars use reserved palette entries 14 and 15 which are updated
;   during VBlank for smooth, flicker-free color cycling.
;
; ============================================================================
; RAM BUFFER DESIGN
; ============================================================================
;
;   The BMP is first decoded entirely into a 16KB RAM buffer (image_buffer),
;   then copied to VRAM using fast REP MOVSW block transfers.
;   The RAM buffer serves as the "master copy" of the background image.
;
; How it works:
;   1. Load BMP image into RAM buffer (not directly to VRAM)
;   2. Copy entire image from RAM to VRAM using REP MOVSW
;   3. Draw bar "strips" into VRAM using palette indices 14 and 15
;   4. Each frame during VBlank:
;      a. Update palette entries 14/15 with new gradient colors
;      b. Erase old bar strips (restore from RAM buffer, not VRAM backup)
;      c. Calculate new bar positions using sine tables
;      d. Draw new bar strips at updated Y positions
;   5. Bars appear to float over the static BMP image
;
; VRAM LAYOUT (CGA-style interlacing):
;   - Segment 0xB000, 16KB total
;   - Even rows (0, 2, 4...): offset = (row/2) * 80
;   - Odd rows (1, 3, 5...):  offset = 0x2000 + (row/2) * 80
;   - Each bank is 8KB (100 rows × 80 bytes)
;
; RAM BUFFER LAYOUT (interlaced to match VRAM for fast block copies):
;   - 16,000 bytes total (160×200×4-bit = 80 bytes × 200 rows)
;   - Even rows (0,2,4...198): bytes 0-7999 (100 rows × 80 bytes)
;   - Odd rows (1,3,5...199): bytes 8000-15999 (100 rows × 80 bytes)
;   - Y scroll always moves in 2-pixel steps to preserve bank alignment
;
; RASTER BAR RESTORE TECHNIQUE:
;   Instead of backing up VRAM scanlines before drawing bars, we use the
;   RAM image buffer as the master copy. When restoring scanlines after
;   the bar passes, we copy from RAM→VRAM using REP MOVSB/MOVSW.
;   This avoids slow VRAM→RAM reads during the raster effect.
;
; ============================================================================
; HOW THE RASTER BARS WORK (Current Implementation)
; ============================================================================
;
; PALETTE-CYCLING SOLID BARS:
;   The bars are drawn as solid horizontal strips using fixed palette indices
;   (14 and 15). The VRAM pixels never change index value during animation -
;   they always contain 0xEE (palette 14) or 0xFF (palette 15).
;
;   The "color animation" happens by changing what RGB color those palette
;   indices actually display. During VBlank, we write new RGB values to
;   palette registers 14 and 15 in the V6355D. This instantly changes the
;   displayed color of all pixels using those indices.
;
;   This is extremely efficient because:
;   - We only write 4 bytes to the palette per frame (2 colors × 2 bytes)
;   - No VRAM writes needed for color changes
;   - Smooth gradients with zero flicker (palette changes are atomic)
;
;   V6355D Color System:
;   - 512 possible colors (3 bits R, 3 bits G, 3 bits B = 8×8×8)
;   - 16 on-screen palette entries, each can be ANY of the 512 colors
;   - Format: 2 bytes per color:
;       Byte 1: Red intensity (bits 0-2, values 0-7)
;       Byte 2: Green (bits 4-6) | Blue (bits 0-2)
;   - Palette starts at register 0x40, so color N is at 0x40 + (N*2)
;
;   The 16-entry gradient tables (green_gradient, blue_gradient) define
;   the color wave animation. Each frame advances through the table,
;   creating a smooth "breathing" or "pulsing" color effect.
;
; ============================================================================
; ALTERNATIVE TECHNIQUE #1: Multi-Color Gradient Bars (Palette Trade-off)
; ============================================================================
;
; Instead of 1 solid color per bar, use 3-4 palette entries per bar to
; draw actual gradient bands (dark edges → bright center → dark edges):
;
;   Palette allocation example:
;   - Colors 0-9:   BMP image (10 colors)
;   - Colors 10-12: Bar 1 gradient (dark red, red, bright red)
;   - Colors 13-15: Bar 2 gradient (dark cyan, cyan, bright cyan)
;
;   Each bar is drawn with multiple horizontal bands:
;   - Scanlines 0-3:   palette 10 (dark)
;   - Scanlines 4-7:   palette 11 (medium)  
;   - Scanlines 8-11:  palette 12 (bright) ← center
;   - Scanlines 12-15: palette 11 (medium)
;   - Scanlines 16-19: palette 10 (dark)
;
;   PROS:
;   - True C64-style gradient appearance
;   - Still benefits from palette cycling (all gradient colors shift together)
;
;   CONS:
;   - Fewer colors available for the BMP image (10 instead of 14)
;   - More complex draw_strip code (must track multiple palette indices)
;   - Images with >10 colors will look degraded
;
; ============================================================================
; ALTERNATIVE TECHNIQUE #2: HSync Palette Switching (Copper-bar Style)
; ============================================================================
;
; Use only 1 palette entry per bar, but change its color MID-FRAME at
; specific scanlines during active display:
;
;   During frame drawing:
;   - Wait for scanline 50 → set palette 14 = dark green
;   - Wait for scanline 53 → set palette 14 = medium green
;   - Wait for scanline 56 → set palette 14 = bright green (center)
;   - Wait for scanline 59 → set palette 14 = medium green
;   - Wait for scanline 62 → set palette 14 = dark green
;
;   The result: a single palette entry appears as multiple colors within
;   the same frame! This is how the Amiga "copper" created rainbow bars.
;
;   PROS:
;   - Uses only 1 palette entry per bar (14 image colors preserved!)
;   - Theoretically unlimited gradient steps
;   - True demoscene technique
;
;   CONS:
;   - Requires cycle-exact timing synchronized with the raster beam
;   - Must reprogram palette during HBlank (~10-15 microseconds window)
;   - V6355D I/O is slow; may not complete within HBlank
;   - CPU must poll PORT_STATUS for HSync timing (wastes cycles)
;   - Very difficult to stabilize - prone to visual "wobble" or jitter
;   - The PC1's 8MHz NEC V40 may not be fast enough for stable results
;
;   On the Amiga, dedicated hardware (Copper coprocessor) handled this.
;   The PC1 has no such hardware, making this technique challenging.
;
; ============================================================================
; VBlank Timing & Palette Safety
; ============================================================================
;
;   - All palette updates occur during VBlank (bit 3 of PORT_STATUS)
;   - VBlank is ~1.4ms on PAL timing - enough time for palette writes
;   - Writing during VBlank avoids "snow" artifacts and color tearing
;   - Bar strip drawing also occurs during VBlank for clean animation
;
; Usage: DEMO4 filename.bmp
;        Press any key to exit
;
; Prerequisites:
;   Run PERITEL.COM first to set horizontal position correctly
;   BMP file must be 160x200 or 320x200, 4-bit (16 colors)
;   BMP must NOT use palette colors 14 and 15 (reserved for bars)
; ============================================================================

[BITS 16]
[CPU 186]                       ; NEC V40 supports 80186 instructions
[ORG 0x100]

; ============================================================================
; Constants - Hardware definitions
; ============================================================================

VIDEO_SEG       equ 0xB000      ; PC1 video RAM segment

; Yamaha V6355D I/O Ports
; Palette ports (8-bit addresses, can use immediate OUT)
PORT_PAL_ADDR   equ 0xDD        ; Palette register address
PORT_PAL_DATA   equ 0xDE        ; Palette register data

; Full CGA addresses (16-bit, require DX register)
PORT_REG_ADDR   equ 0x3DD       ; Register address port
PORT_REG_DATA   equ 0x3DE       ; Register data port
PORT_MODE       equ 0x3D8       ; Mode control register
PORT_COLOR      equ 0x3D9       ; Color select (border/overscan color)
PORT_STATUS     equ 0x3DA       ; Status (bit 0=hsync, bit 3=vblank)

; Screen parameters
SCREEN_WIDTH    equ 160
SCREEN_HEIGHT   equ 200
SCREEN_SIZE     equ 16384       ; Full video RAM (16KB)
IMAGE_SIZE      equ 16000       ; RAM buffer size (80 bytes × 200 rows)
BYTES_PER_LINE  equ 80          ; 160 pixels / 2 pixels per byte

; BMP File Header offsets
BMP_SIGNATURE   equ 0           ; 'BM' signature (2 bytes)
BMP_DATA_OFFSET equ 10          ; Offset to pixel data (dword)
BMP_WIDTH       equ 18          ; Image width (dword)
BMP_HEIGHT      equ 22          ; Image height (dword)
BMP_BPP         equ 28          ; Bits per pixel (word)
BMP_COMPRESSION equ 30          ; Compression (dword, 0=none)

; ============================================================================
; RASTER BAR CONFIGURATION
; ============================================================================
; Animated solid bars using palette indices 14 and 15
; The bars appear as solid colors that "pulse" by cycling palette entries
; Palette 0-13 is used by the BMP image, only 14-15 are reserved for bars
; ============================================================================

BAR_HEIGHT      equ 12          ; Height of each bar in scanlines

; Palette index for each bar (these entries cycle through colors)
BAR1_PALETTE    equ 14          ; Bar 1 uses palette index 14 (green cycle)
BAR2_PALETTE    equ 15          ; Bar 2 uses palette index 15 (blue cycle)

; Per-bar speed (higher = faster wobble)
BAR1_SPEED      equ 2           ; Bar 1 sine index increment per frame
BAR2_SPEED      equ 3           ; Bar 2 sine index increment per frame

; Per-bar center position (Y coordinate on screen)
BAR1_CENTER     equ 100         ; Bar 1 oscillates around this Y position
BAR2_CENTER     equ 100         ; Bar 2 oscillates around this Y position

; Per-bar starting phase (0-255, controls where in sine wave each bar starts)
BAR1_PHASE      equ 0           ; Bar 1 starts at sine position 0
BAR2_PHASE      equ 85          ; Bar 2 starts 1/3 cycle offset (120 degrees)

; Shared amplitude (affects wobble range for both bars)
SINE_AMPLITUDE  equ 50          ; Maximum distance from center

; Color cycling speed (frames per color step)
COLOR_SPEED     equ 12          ; Higher = slower color cycling (smoother wave)

; ============================================================================
; IMAGE SCROLL CONFIGURATION
; ============================================================================
; The image scrolls/pans around the screen using sine wave motion.
; Since we copy the entire image each frame, we can position it anywhere.
; Border areas (where image doesn't cover) are filled with black (color 0).
; ============================================================================

; Image movement amplitude (pixels from center)
IMAGE_X_AMPLITUDE equ 40        ; Horizontal wobble range (±40 pixels = 80 total)
IMAGE_Y_AMPLITUDE equ 30        ; Vertical wobble range (±30 pixels = 60 total)

; Image movement speed (higher = faster)
IMAGE_X_SPEED   equ 1           ; X sine index increment per frame
IMAGE_Y_SPEED   equ 2           ; Y sine index increment per frame (different for Lissajous)

; Starting phase offset (creates interesting motion patterns)
IMAGE_X_PHASE   equ 0           ; X starts at sine position 0
IMAGE_Y_PHASE   equ 64          ; Y starts 90 degrees offset (Lissajous figure)

; ============================================================================
; Main Program Entry Point
; ============================================================================
main:
    ; Parse command line for filename
    mov si, 0x81                ; Command line starts at PSP:0081
    
    ; Skip leading spaces
.skip_spaces:
    lodsb
    cmp al, ' '
    je .skip_spaces
    cmp al, 0x0D                ; End of command line?
    je .show_usage
    
    ; Check for help flags
    cmp al, '/'
    jne .not_help
    lodsb
    cmp al, '?'
    je .show_usage
    cmp al, 'h'
    je .show_usage
    cmp al, 'H'
    je .show_usage
    dec si
    dec si
    jmp .save_filename
    
.not_help:
    dec si
    
.save_filename:
    mov [filename_ptr], si
    
    ; Find end of filename (space or CR)
.find_end:
    lodsb
    cmp al, ' '
    je .found_end
    cmp al, 0x0D
    jne .find_end
    
.found_end:
    dec si
    mov byte [si], 0            ; Null-terminate filename
    jmp .open_file

.show_usage:
    mov dx, msg_info
    mov ah, 0x09
    int 0x21
    mov ax, 0x4C00
    int 0x21

.open_file:
    ; Open the BMP file
    mov dx, [filename_ptr]
    mov ax, 0x3D00              ; DOS Open File (read-only)
    int 0x21
    jc .file_error
    mov [file_handle], ax
    
    ; Read BMP header + palette (118 bytes)
    mov bx, ax
    mov dx, bmp_header
    mov cx, 118
    mov ah, 0x3F
    int 0x21
    jc .file_error
    cmp ax, 118
    jb .file_error
    
    ; Verify BMP signature ('BM')
    cmp word [bmp_header + BMP_SIGNATURE], 0x4D42
    jne .not_bmp
    
    ; Check bits per pixel (should be 4)
    cmp word [bmp_header + BMP_BPP], 4
    jne .wrong_format
    
    ; Check compression (should be 0 = uncompressed)
    cmp word [bmp_header + BMP_COMPRESSION], 0
    jne .wrong_format
    cmp word [bmp_header + BMP_COMPRESSION + 2], 0
    jne .wrong_format
    
    ; Seek to pixel data
    mov bx, [file_handle]
    mov dx, [bmp_header + BMP_DATA_OFFSET]
    mov cx, [bmp_header + BMP_DATA_OFFSET + 2]
    mov ax, 0x4200
    int 0x21
    jc .file_error
    
    ; Display loading message centered in text mode
    ; Clear screen first using BIOS
    mov ax, 0x0003              ; Set 80x25 text mode (clears screen)
    int 0x10
    
    ; Position cursor to center of screen (row 12, column 22)
    mov ah, 0x02                ; Set cursor position
    mov bh, 0                   ; Page 0
    mov dh, 12                  ; Row 12 (middle of 25 rows)
    mov dl, 22                  ; Column 22 (center for ~36 char message)
    int 0x10
    
    ; Print the loading message
    mov dx, msg_loading
    mov ah, 0x09
    int 0x21
    
    ; Decode BMP into RAM buffer while still in text mode
    ; (loading message stays visible during file read)
    call decode_bmp
    
    ; Close file (done reading)
    mov bx, [file_handle]
    mov ah, 0x3E
    int 0x21
    
    ; NOW switch to graphics mode after loading is complete
    call enable_graphics_mode
    
    ; Blank video output during VRAM setup (prevents flicker)
    mov dx, PORT_MODE
    mov al, 0x42                ; Graphics mode, video OFF
    out dx, al
    
    ; Clear screen
    call clear_screen
    
    ; Set palette from BMP (but preserve our bar colors 14, 15)
    call set_bmp_palette
    
    ; Force palette 0 to true black (some BMPs have off-black)
    call force_black_palette0
    
    ; Copy entire image from RAM buffer to VRAM using fast block transfer
    call copy_image_to_vram
    
.file_closed:
    ; Initialize bar animation state
    mov byte [bar1_sine_idx], BAR1_PHASE
    mov byte [bar2_sine_idx], BAR2_PHASE
    mov byte [bar1_y], 0
    mov byte [bar2_y], 0
    mov byte [bar1_old_y], 0xFF     ; Invalid Y = no restore needed first frame
    mov byte [bar2_old_y], 0xFF
    mov byte [color_cycle_idx], 0
    mov byte [color_frame_ctr], 0
    
    ; Initialize image scroll state
    mov byte [image_sine_x], IMAGE_X_PHASE
    mov byte [image_sine_y], IMAGE_Y_PHASE
    mov word [image_x], 0
    mov word [image_y], 0
    
    ; Reset border to black (16-bit port, needs DX)
    mov dx, PORT_COLOR
    xor al, al
    out dx, al
    
    ; Enable video output (16-bit port, needs DX)
    mov dx, PORT_MODE
    mov al, 0x4A
    out dx, al
    
    ; ========================================================================
    ; MAIN ANIMATION LOOP
    ; All updates happen during VBlank for flicker-free animation
    ; ========================================================================
.main_loop:
    ; --------------------------------------------------------------------
    ; STEP 1: Wait for VBlank start
    ; VBlank is the safe window for all VRAM and palette updates
    ; Bit 3 of PORT_STATUS = 1 during vertical blanking
    ; --------------------------------------------------------------------
    call wait_vblank
    
    ; --------------------------------------------------------------------
    ; STEP 2: Update palette entries 14 and 15 (during VBlank)
    ; This is the key to smooth color cycling without flicker.
    ; We change what colors 14/15 display, not the pixels themselves.
    ; Safe because VBlank = no scanlines being drawn = no tearing
    ; --------------------------------------------------------------------
    call update_bar_palette
    
    ; --------------------------------------------------------------------
    ; STEP 3: Update image position using sine wave
    ; Calculates new X,Y position for the scrolling image
    ; --------------------------------------------------------------------
    call update_image_position
    
    ; --------------------------------------------------------------------
    ; STEP 4: Copy image to VRAM at new position
    ; This is the "brute force" approach - copy entire image each frame.
    ; Fast REP MOVSW is used, but may extend past VBlank (some tearing).
    ; --------------------------------------------------------------------
    call copy_image_at_position
    
    ; --------------------------------------------------------------------
    ; STEP 5: Calculate new bar Y positions using sine wave
    ; Updates bar1_y and bar2_y based on sine table lookup
    ; --------------------------------------------------------------------
    call update_bar_positions
    
    ; --------------------------------------------------------------------
    ; STEP 6: Draw new bar strips (on top of scrolled image)
    ; Draw bars using palette 14/15
    ; Note: No restore needed - image copy already refreshed background
    ; --------------------------------------------------------------------
    call draw_bar_strips_no_restore
    
    ; --------------------------------------------------------------------
    ; STEP 7: Check for keypress (exit on any key)
    ; --------------------------------------------------------------------
    mov ah, 0x01
    int 0x16
    jz .main_loop
    
    ; Consume the keypress
    mov ah, 0x00
    int 0x16
    
    ; ========================================================================
    ; EXIT: Cleanup and return to DOS
    ; ========================================================================
    
    ; Wait for VBlank before palette reset
    call wait_vblank
    
    ; Restore default CGA palette
    call set_cga_palette
    
    ; Disable graphics mode
    call disable_graphics_mode
    
    ; Restore text mode
    mov ax, 0x0003
    int 0x10
    
    ; Exit to DOS
    mov ax, 0x4C00
    int 0x21

.file_error:
    mov dx, msg_file_err
    jmp .print_exit

.not_bmp:
    mov dx, msg_not_bmp
    jmp .print_exit

.wrong_format:
    mov dx, msg_format

.print_exit:
    mov ah, 0x09
    int 0x21
    mov ax, 0x4C01
    int 0x21

; ============================================================================
; wait_vblank - Wait for vertical blanking interval start
; 
; VBlank Timing Notes:
;   - PAL: ~1.4ms VBlank period (enough for palette + VRAM updates)
;   - Bit 3 of PORT_STATUS = 1 during VBlank
;   - We first wait for VBlank to end (if currently in VBlank)
;   - Then wait for VBlank to start (fresh VBlank period)
;   - This ensures maximum time for our updates
; ============================================================================
wait_vblank:
    push ax
    push dx
    
    mov dx, PORT_STATUS         ; Use DX for port > 255
    
    ; Wait for VBlank to end (if we're in it)
.wait_end:
    in al, dx
    test al, 0x08               ; Bit 3 = VBlank
    jnz .wait_end
    
    ; Wait for VBlank to start (fresh VBlank)
.wait_start:
    in al, dx
    test al, 0x08
    jz .wait_start
    
    pop dx
    pop ax
    ret

; ============================================================================
; update_bar_palette - Cycle colors for palette entries 14 and 15
;
; This is where the "magic" happens - we change what colors the bars display
; by reprogramming the V6355D palette registers, not by changing VRAM pixels.
;
; V6355D PALETTE REGISTER ACCESS:
;   1. Write starting register address to PORT_REG_ADDR (0xDD)
;      - Palette starts at register 0x40
;      - Color 14 is at register 0x40 + (14*2) = 0x5C
;   2. Write color data bytes to PORT_REG_DATA (0xDE)
;      - Register auto-increments after each write
;      - So after writing to 0x5C/0x5D, next write goes to 0x5E (color 15)
;
; WHY VBLANK IS CRITICAL:
;   - V6355D reads palette during active display to generate pixel colors
;   - Writing palette mid-frame causes "tearing" - top/bottom show different colors
;   - VBlank = ~1.4ms window when no scanlines are being drawn
;   - All 4 bytes can be written safely in <100 microseconds
;
; COLOR CYCLING ANIMATION:
;   - Bar 1 (palette 14): cycles through green_gradient (green cycle)
;   - Bar 2 (palette 15): cycles through blue_gradient (blue cycle)
;   - color_cycle_idx advances every COLOR_SPEED frames
;   - Gradient tables have 16 entries, creating smooth looping animation
; ============================================================================
update_bar_palette:
    push ax
    push bx
    push dx
    push si
    
    ; Update color cycle counter (controls animation speed)
    inc byte [color_frame_ctr]
    cmp byte [color_frame_ctr], COLOR_SPEED
    jb .no_color_update
    mov byte [color_frame_ctr], 0
    
    ; Advance color cycle index
    inc byte [color_cycle_idx]
    
.no_color_update:
    ; Get current color cycle position
    mov al, [color_cycle_idx]
    and al, 0x0F                ; 16 color steps (0-15)
    xor ah, ah
    mov bx, ax
    
    ; Calculate table offset (2 bytes per color)
    shl bx, 1
    
    cli                         ; Disable interrupts during palette update
    
    ; -----------------------------------------------------------------------
    ; STEP A: Select palette register 14 (address = 0x40 + 14*2 = 0x5C)
    ; Writing to PORT_REG_ADDR sets which V6355D register we'll modify
    ; Must use DX for 16-bit port addresses (> 255)
    ; -----------------------------------------------------------------------
    mov dx, PORT_REG_ADDR
    mov al, 0x5C
    out dx, al
    jmp short $+2               ; I/O delay (required for V6355D timing)
    
    ; -----------------------------------------------------------------------
    ; STEP B: Write 2 bytes for color 14 (bar 1 - green gradient)
    ; Byte 1 = Red (bits 0-2), Byte 2 = Green (bits 4-6) | Blue (bits 0-2)
    ; After each write, register address auto-increments
    ; -----------------------------------------------------------------------
    mov dx, PORT_REG_DATA
    mov si, green_gradient
    mov al, [si + bx]           ; Get Red byte from gradient table
    out dx, al                  ; Write to register 0x5C (color 14, red)
    jmp short $+2
    mov al, [si + bx + 1]       ; Get Green|Blue byte from gradient table  
    out dx, al                  ; Write to register 0x5D (color 14, green|blue)
    jmp short $+2               ; After this, register pointer is at 0x5E
    
    ; -----------------------------------------------------------------------
    ; STEP C: Write 2 bytes for color 15 (bar 2 - blue gradient)
    ; No need to set address - auto-increment already points to 0x5E
    ; -----------------------------------------------------------------------
    mov si, blue_gradient
    mov al, [si + bx]           ; Get Red byte from gradient table
    out dx, al                  ; Write to register 0x5E (color 15, red)
    jmp short $+2
    mov al, [si + bx + 1]       ; Get Green|Blue byte from gradient table
    out dx, al                  ; Write to register 0x5F (color 15, green|blue)
    jmp short $+2
    
    ; IMPORTANT: Disable palette write mode
    mov dx, PORT_REG_ADDR
    mov al, 0x80
    out dx, al
    
    sti                         ; Re-enable interrupts
    
    pop si
    pop dx
    pop bx
    pop ax
    ret

; ============================================================================
; update_bar_positions - Calculate new Y positions using sine wave
; ============================================================================
update_bar_positions:
    push ax
    push si
    
    ; NOTE: We do NOT save old_y here anymore!
    ; old_y is saved at the END of draw_bar_strips, after we know where we drew.
    
    ; Update bar 1 sine index
    mov al, [bar1_sine_idx]
    add al, BAR1_SPEED
    mov [bar1_sine_idx], al
    
    ; Calculate bar 1 Y position: center + (sine - 50)
    xor ah, ah
    mov si, ax
    mov al, [sine_table + si]   ; Get sine value (0-100, centered at 50)
    add al, BAR1_CENTER
    sub al, SINE_AMPLITUDE      ; Adjust so sine oscillates around center
    
    ; Clamp to valid screen range
    cmp al, SCREEN_HEIGHT - BAR_HEIGHT
    jb .bar1_ok
    mov al, SCREEN_HEIGHT - BAR_HEIGHT - 1
.bar1_ok:
    mov [bar1_y], al
    
    ; Update bar 2 sine index
    mov al, [bar2_sine_idx]
    add al, BAR2_SPEED
    mov [bar2_sine_idx], al
    
    ; Calculate bar 2 Y position
    xor ah, ah
    mov si, ax
    mov al, [sine_table + si]
    add al, BAR2_CENTER
    sub al, SINE_AMPLITUDE
    
    ; Clamp to valid screen range
    cmp al, SCREEN_HEIGHT - BAR_HEIGHT
    jb .bar2_ok
    mov al, SCREEN_HEIGHT - BAR_HEIGHT - 1
.bar2_ok:
    mov [bar2_y], al
    
    pop si
    pop ax
    ret

; ============================================================================
; update_image_position - Calculate new X,Y position using sine waves
;
; Uses two separate sine indices (X and Y) with different speeds to create
; a Lissajous-like motion pattern. The image oscillates around the center
; of the screen.
;
; Output: Updates image_x and image_y (signed words)
; ============================================================================
update_image_position:
    push ax
    push bx
    push si
    
    ; Update X sine index
    mov al, [image_sine_x]
    add al, IMAGE_X_SPEED
    mov [image_sine_x], al
    
    ; Calculate X position: (sine - 50) * amplitude / 50
    ; Simplified: sine value 0-100, we want -amplitude to +amplitude
    xor ah, ah
    mov si, ax
    mov al, [sine_table + si]   ; Get sine value (0-100, centered at 50)
    sub al, 50                  ; Now -50 to +50
    cbw                         ; Sign extend AL to AX
    
    ; Multiply by amplitude and divide by 50 to scale
    ; For simplicity, just use direct scaling: AX * AMPLITUDE / 50
    mov bx, IMAGE_X_AMPLITUDE
    imul bx                     ; DX:AX = AX * amplitude
    mov bx, 50
    idiv bx                     ; AX = result / 50
    mov [image_x], ax
    
    ; Update Y sine index
    mov al, [image_sine_y]
    add al, IMAGE_Y_SPEED
    mov [image_sine_y], al
    
    ; Calculate Y position
    xor ah, ah
    mov si, ax
    mov al, [sine_table + si]
    sub al, 50
    cbw
    
    mov bx, IMAGE_Y_AMPLITUDE
    imul bx
    mov bx, 50
    idiv bx
    and ax, 0xFFFE              ; Force Y to be even (2-pixel steps)
    mov [image_y], ax
    
    pop si
    pop bx
    pop ax
    ret

; ============================================================================
; copy_image_at_position - Copy image from RAM to VRAM at offset position
;
; OPTIMIZED: Uses interlaced RAM buffer with 2-pixel Y steps.
; Since Y is always even, source bank alignment matches destination.
; This allows large block copies instead of 200 row-by-row copies.
;
; RAM layout: Even rows at 0-7999, Odd rows at 8000-15999
; VRAM layout: Even rows at 0x0000, Odd rows at 0x2000
;
; With Y offset always even:
;   - Screen even row N needs image even row (N - Y_offset)
;   - Screen odd row N needs image odd row (N - Y_offset)
;   - Bank alignment is always preserved!
; ============================================================================
copy_image_at_position:
    pusha                       ; 80186 PUSHA
    push es
    
    mov ax, VIDEO_SEG
    mov es, ax
    
    ; Get image position
    mov ax, [image_x]           ; AX = X offset (signed, in pixels)
    sar ax, 1                   ; Convert to bytes (2 pixels per byte)
    mov [temp_x_bytes], ax      ; Save X offset in bytes
    
    mov bp, [image_y]           ; BP = Y offset (always even, in scanlines)
    sar bp, 1                   ; BP = Y offset in row-pairs (for bank offset)
    
    ; ===== COPY EVEN BANK (screen rows 0,2,4...198 to VRAM 0x0000) =====
    ; Source: image_buffer + (Y_offset/2) * 80
    ; If Y_offset is negative, we need to fill black at top
    
    xor di, di                  ; DI = VRAM even bank start
    mov bx, bp                  ; BX = row offset in bank (can be negative)
    xor dx, dx                  ; DX = current screen row (even: 0,2,4...)
    
.even_loop:
    ; Calculate source row index in even bank
    mov ax, dx                  ; AX = screen row (0,2,4...)
    shr ax, 1                   ; AX = screen row / 2 (0,1,2...)
    sub ax, bp                  ; AX = source row index in even bank
    
    ; Check bounds
    cmp ax, 0
    jl .even_black
    cmp ax, 100                 ; 100 even rows total
    jge .even_black
    
    ; Valid row - calculate source offset
    push dx
    mov dx, BYTES_PER_LINE
    imul dx                     ; AX = row_index * 80
    mov si, image_buffer
    add si, ax                  ; SI = source in even bank
    pop dx
    
    ; Copy with X offset
    mov ax, [temp_x_bytes]
    call copy_row_with_offset
    jmp .even_next
    
.even_black:
    ; Fill row with black
    push di
    mov cx, BYTES_PER_LINE / 2
    xor ax, ax
    cld
    rep stosw
    pop di
    add di, BYTES_PER_LINE
    jmp .even_next2
    
.even_next:
    ; DI already advanced by copy_row_with_offset
.even_next2:
    add dx, 2                   ; Next even screen row
    cmp dx, 200
    jb .even_loop
    
    ; ===== COPY ODD BANK (screen rows 1,3,5...199 to VRAM 0x2000) =====
    
    mov di, 0x2000              ; DI = VRAM odd bank start
    mov dx, 1                   ; DX = current screen row (odd: 1,3,5...)
    
.odd_loop:
    ; Calculate source row index in odd bank
    mov ax, dx                  ; AX = screen row (1,3,5...)
    shr ax, 1                   ; AX = screen row / 2 (0,1,2...)
    sub ax, bp                  ; AX = source row index in odd bank
    
    ; Check bounds
    cmp ax, 0
    jl .odd_black
    cmp ax, 100                 ; 100 odd rows total
    jge .odd_black
    
    ; Valid row - calculate source offset (odd bank starts at 8000)
    push dx
    mov dx, BYTES_PER_LINE
    imul dx                     ; AX = row_index * 80
    mov si, image_buffer + 8000 ; Odd bank base
    add si, ax                  ; SI = source in odd bank
    pop dx
    
    ; Copy with X offset
    mov ax, [temp_x_bytes]
    call copy_row_with_offset
    jmp .odd_next
    
.odd_black:
    ; Fill row with black
    push di
    mov cx, BYTES_PER_LINE / 2
    xor ax, ax
    cld
    rep stosw
    pop di
    add di, BYTES_PER_LINE
    jmp .odd_next2
    
.odd_next:
    ; DI already advanced by copy_row_with_offset
.odd_next2:
    add dx, 2                   ; Next odd screen row
    cmp dx, 200
    jb .odd_loop
    
    pop es
    popa                        ; 80186 POPA
    ret

; Temporary storage for X offset in bytes
temp_x_bytes: dw 0

; ----------------------------------------------------------------------------
; copy_row_with_offset - Copy one row from RAM to VRAM with X offset
; Input: SI = source row in RAM buffer (start of row)
;        DI = destination in VRAM (start of row)
;        AX = X offset in bytes (signed)
;        ES = VIDEO_SEG
; Clobbers: AX, CX, SI, DI
; ----------------------------------------------------------------------------
copy_row_with_offset:
    push bx
    push dx
    
    ; Handle three cases:
    ; 1. offset = 0: simple copy
    ; 2. offset > 0: image shifts right, left edge has black
    ; 3. offset < 0: image shifts left, right edge has black
    
    or ax, ax
    jz .simple_copy
    jg .shift_right
    
    ; --- Shift left (offset < 0) ---
    neg ax                      ; AX = positive offset
    mov bx, ax                  ; BX = bytes to skip from source
    
    ; Check if entire row is off-screen
    cmp bx, BYTES_PER_LINE
    jge .all_black
    
    ; Adjust source pointer (skip left portion)
    add si, bx
    
    ; Calculate bytes to copy
    mov cx, BYTES_PER_LINE
    sub cx, bx                  ; CX = visible bytes from image
    
    ; Copy visible portion
    cld
    rep movsb
    
    ; Fill right edge with black
    mov cx, bx                  ; CX = black bytes on right
    xor al, al
    rep stosb
    jmp .done
    
.shift_right:
    ; --- Shift right (offset > 0) ---
    mov bx, ax                  ; BX = black bytes on left
    
    ; Check if entire row is off-screen
    cmp bx, BYTES_PER_LINE
    jge .all_black
    
    ; Fill left edge with black
    mov cx, bx
    xor al, al
    cld
    rep stosb
    
    ; Calculate bytes to copy
    mov cx, BYTES_PER_LINE
    sub cx, bx                  ; CX = visible bytes from image
    
    ; Copy visible portion
    rep movsb
    jmp .done
    
.simple_copy:
    ; No offset - fast copy entire row
    mov cx, BYTES_PER_LINE / 2  ; 40 words
    cld
    rep movsw
    jmp .done
    
.all_black:
    ; Entire row is black
    mov cx, BYTES_PER_LINE / 2
    xor ax, ax
    cld
    rep stosw
    
.done:
    pop dx
    pop bx
    ret

; ============================================================================
; draw_bar_strips_no_restore - Draw bar strips without restore step
;
; Since we copy the entire image each frame, we don't need to restore
; the old bar positions - the image copy already refreshed the background.
; ============================================================================
draw_bar_strips_no_restore:
    push ax
    push bx
    push cx
    push dx
    push di
    push si
    push es
    
    mov ax, VIDEO_SEG
    mov es, ax
    
    ; Determine which bar is in front (lower Y = higher on screen = behind)
    mov al, [bar1_y]
    cmp al, [bar2_y]
    jbe .bar1_behind
    
    ; Bar 2 is behind (draw first, bar 1 on top)
    mov al, [bar2_y]
    mov bl, BAR2_PALETTE        ; Palette 15 (blue cycle)
    call draw_strip
    
    mov al, [bar1_y]
    mov bl, BAR1_PALETTE        ; Palette 14 (green cycle)
    call draw_strip
    jmp .done
    
.bar1_behind:
    ; Bar 1 is behind (draw first, bar 2 on top)
    mov al, [bar1_y]
    mov bl, BAR1_PALETTE
    call draw_strip
    
    mov al, [bar2_y]
    mov bl, BAR2_PALETTE
    call draw_strip
    
.done:
    pop es
    pop si
    pop di
    pop dx
    pop cx
    pop bx
    pop ax
    ret

; ============================================================================
; restore_old_bars - Restore original BMP pixels at old bar positions
; IMPORTANT: Must restore in REVERSE order of drawing to handle overlaps!
; If bar1 was behind (drawn first), we must restore bar2 first, then bar1.
;
; NEW: restore_strip reads from image_buffer, no backup buffers needed.
; ============================================================================
restore_old_bars:
    push ax
    push bx
    push cx
    push dx
    push di
    push si
    push es
    
    mov ax, VIDEO_SEG
    mov es, ax
    
    ; Check if this is first frame (no restore needed)
    cmp byte [bar1_old_y], 0xFF
    je .skip_restore
    
    ; Determine restore order based on OLD positions (reverse of draw order)
    ; If bar1 was behind (lower Y), we drew bar1 first, so restore bar2 first
    mov al, [bar1_old_y]
    cmp al, [bar2_old_y]
    jbe .bar1_was_behind
    
    ; Bar2 was behind → restore bar1 first, then bar2
    mov al, [bar1_old_y]
    call restore_strip
    
    mov al, [bar2_old_y]
    call restore_strip
    jmp .skip_restore
    
.bar1_was_behind:
    ; Bar1 was behind → restore bar2 first, then bar1
    mov al, [bar2_old_y]
    call restore_strip
    
    mov al, [bar1_old_y]
    call restore_strip
    
.skip_restore:
    pop es
    pop si
    pop di
    pop dx
    pop cx
    pop bx
    pop ax
    ret

; ----------------------------------------------------------------------------
; restore_strip - Restore a horizontal strip from RAM image buffer
; Input: AL = Y position (screen Y to restore)
; Clobbers: AX, BX, CX, DI, SI
;
; UPDATED: Now applies current image_x/image_y scroll offset!
; Reads from INTERLACED image_buffer at the correct scrolled position.
; Even rows at 0-7999, Odd rows at 8000-15999.
; ----------------------------------------------------------------------------
restore_strip:
    push dx
    push bp
    
    mov bl, al                  ; BL = starting screen Y position
    mov cl, BAR_HEIGHT
    xor ch, ch
    
    ; Pre-calculate X offset in bytes (same as copy_image_at_position)
    mov ax, [image_x]           ; AX = X offset in pixels (signed)
    sar ax, 1                   ; AX = X offset in bytes (2 pixels per byte)
    mov [restore_x_bytes], ax   ; Store for use in loop
    
.restore_row:
    push cx
    push bx
    
    mov al, bl                  ; AL = current screen Y
    
    ; Calculate VRAM offset for this screen row (CGA interlaced)
    call calc_vram_offset       ; Returns offset in DI
    
    ; Calculate source row in image: screen_Y - image_y = source_row
    xor ah, ah
    mov al, bl                  ; AL = screen Y
    mov bp, ax                  ; BP = screen Y (save for odd test)
    sub ax, [image_y]           ; AX = source row in image (signed)
    
    ; Check if source row is in bounds (0-199)
    cmp ax, 0
    jl .restore_black
    cmp ax, 200
    jge .restore_black
    
    ; Calculate RAM buffer offset for source row (INTERLACED layout)
    ; Even rows: (src_row/2) * 80
    ; Odd rows: 8000 + (src_row/2) * 80
    mov dx, ax                  ; DX = source row
    shr ax, 1                   ; AX = source_row / 2
    push dx
    mov dx, BYTES_PER_LINE
    mul dx                      ; AX = (source_row/2) * 80
    pop dx
    mov si, image_buffer
    test dl, 1                  ; Is source row odd?
    jz .restore_even
    add si, 8000                ; Odd rows at offset 8000
.restore_even:
    add si, ax                  ; SI = base + (source_row/2) * 80
    
    ; Copy row with X offset applied (like copy_row_with_offset)
    mov ax, [restore_x_bytes]
    call copy_row_with_offset
    jmp .restore_next
    
.restore_black:
    ; Source row is out of bounds - fill with black
    push di
    mov cx, BYTES_PER_LINE / 2
    xor ax, ax
    cld
    rep stosw
    pop di
    add di, BYTES_PER_LINE      ; Not used, but keep consistent
    
.restore_next:
    pop bx
    inc bl                      ; Next screen row
    pop cx
    loop .restore_row
    
    pop bp
    pop dx
    ret

; Temporary storage for restore_strip X offset
restore_x_bytes: dw 0

; ============================================================================
; draw_bar_strips - Draw bar strips (no VRAM backup needed - uses RAM buffer)
;
; NEW: No longer backs up VRAM pixels. restore_strip reads from image_buffer.
; ============================================================================
draw_bar_strips:
    push ax
    push bx
    push cx
    push dx
    push di
    push si
    push es
    
    mov ax, VIDEO_SEG
    mov es, ax
    
    ; Determine which bar is in front (lower Y = higher on screen = behind)
    mov al, [bar1_y]
    cmp al, [bar2_y]
    jbe .bar1_behind
    
    ; Bar 2 is behind (draw first, bar 1 on top)
    mov al, [bar2_y]
    mov bl, BAR2_PALETTE        ; Palette 15 (blue cycle)
    call draw_strip
    
    mov al, [bar1_y]
    mov bl, BAR1_PALETTE        ; Palette 14 (green cycle)
    call draw_strip
    jmp .done
    
.bar1_behind:
    ; Bar 1 is behind (draw first, bar 2 on top)
    mov al, [bar1_y]
    mov bl, BAR1_PALETTE
    call draw_strip
    
    mov al, [bar2_y]
    mov bl, BAR2_PALETTE
    call draw_strip
    
.done:
    ; Save the Y positions we just drew at for next frame's restore
    mov al, [bar1_y]
    mov [bar1_old_y], al
    mov al, [bar2_y]
    mov [bar2_old_y], al
    
    pop es
    pop si
    pop di
    pop dx
    pop cx
    pop bx
    pop ax
    ret

; ----------------------------------------------------------------------------
; draw_strip - Draw a solid color raster bar
; Input: AL = Y position, BL = palette index (14 or 15)
; Uses ES = VIDEO_SEG (already set by caller)
;
; Draws BAR_HEIGHT scanlines of solid color using the palette index in BL.
; The actual color displayed is set by update_bar_palette, which cycles
; the palette entries 14/15 to create the "pulsing" animation effect.
; ----------------------------------------------------------------------------
draw_strip:
    push ax
    push bx
    push cx
    push dx
    push di
    push si
    push bp
    
    mov bh, al                  ; BH = current Y position
    
    ; Create fill byte (two pixels of same palette index)
    ; BL = palette index (14 or 15)
    mov al, bl                  ; AL = palette index
    shl al, 4                   ; AL = palette << 4 (high nibble) - 80186 immediate shift
    or al, bl                   ; AL = palette | (palette << 4)
    mov [fill_byte], al         ; Save fill byte in memory (DL gets clobbered)
    
    mov bp, BAR_HEIGHT          ; BP = rows to draw
    
.draw_loop:
    cmp bh, SCREEN_HEIGHT       ; Bounds check
    jae .draw_done
    
    ; Calculate VRAM offset for this row
    mov al, bh                  ; Y position
    call calc_vram_offset       ; DI = VRAM offset (clobbers AX, DX)
    
    ; Fill the scanline with the palette color
    mov al, [fill_byte]         ; AL = fill byte from memory
    mov cx, BYTES_PER_LINE
    cld
    rep stosb
    
    inc bh                      ; Next scanline
    dec bp
    jnz .draw_loop
    
.draw_done:
    pop bp
    pop si
    pop di
    pop dx
    pop cx
    pop bx
    pop ax
    ret

; ----------------------------------------------------------------------------
; calc_vram_offset - Calculate VRAM offset for a given Y coordinate
; Input: AL = Y coordinate (0-199)
; Output: DI = VRAM offset
; Clobbers: AX, DX
;
; CGA-style interlacing:
;   Even rows: offset = (row/2) * 80
;   Odd rows:  offset = 0x2000 + (row/2) * 80
; ----------------------------------------------------------------------------
calc_vram_offset:
    push bx
    
    mov bl, al                  ; Save row number
    shr al, 1                   ; AL = row / 2
    xor ah, ah
    mov dx, 80
    mul dx                      ; AX = (row/2) * 80
    mov di, ax
    
    test bl, 1                  ; Check if odd row
    jz .even_row
    add di, 0x2000              ; Add 8KB offset for odd rows
.even_row:
    
    pop bx
    ret

; ============================================================================
; enable_graphics_mode - Enable 160x200x16 hidden mode (simplified like rbars4)
; ============================================================================
enable_graphics_mode:
    push ax
    push dx
    
    ; Just set mode register like rbars4 does
    mov dx, PORT_MODE
    mov al, 0x4A
    out dx, al
    
    pop dx
    pop ax
    ret

; ============================================================================
; disable_graphics_mode - Reset to text mode
; ============================================================================
disable_graphics_mode:
    push ax
    push dx
    
    ; Set mode register back to text
    mov dx, PORT_MODE
    mov al, 0x28
    out dx, al
    
    pop dx
    pop ax
    ret

; ============================================================================
; clear_screen - Fill video memory with black
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
; set_bmp_palette - Set palette from BMP file, reserve colors 8-15 for bars
; BMP palette: 64 bytes (16 colors × 4 bytes BGRA)
; 6355 palette: 32 bytes (16 colors × 2 bytes)
; Only loads BMP colors 0-7, then sets up bar gradient colors 8-15
; ============================================================================
set_bmp_palette:
    push ax
    push bx
    push cx
    push dx
    push si
    push bp
    
    cli
    
    ; Enable palette write at register 0x40
    mov dx, PORT_REG_ADDR
    mov al, 0x40
    out dx, al
    jmp short $+2
    
    ; Convert colors 0-13 from BMP format to 6355 format
    ; Palette 14-15 are reserved for bar animation (set below)
    mov si, bmp_header + 54     ; Palette starts at offset 54
    mov bp, 14                  ; BP = color counter (0-13 from BMP)
    
.palette_loop:
    ; BMP stores as: Blue, Green, Red, Alpha
    lodsb                       ; Blue
    mov bl, al
    lodsb                       ; Green
    mov bh, al
    lodsb                       ; Red (need to convert 8-bit to 3-bit)
    shr al, 5                   ; Convert Red to 3-bit (0-7) - 80186 immediate shift
    
    mov dx, PORT_REG_DATA
    out dx, al
    jmp short $+2
    
    ; Combine Green and Blue
    mov al, bh                  ; Green
    and al, 0xE0                ; Keep upper 3 bits
    shr al, 1                   ; Shift to bits 4-6 - 80186 immediate shift
    mov ah, al                  ; Save green component
    mov al, bl                  ; Blue
    shr al, 5                   ; Convert Blue to 3-bit - 80186 immediate shift
    or al, ah                   ; Combine: Green (4-6) | Blue (0-2)
    out dx, al
    jmp short $+2
    
    lodsb                       ; Skip alpha
    dec bp
    jnz .palette_loop
    
    ; Set initial bar colors (palette 14-15)
    ; These will be animated by update_bar_palette
    ; Palette 14 (bar 1): Start with bright green
    mov al, 0x00                ; Red = 0
    out dx, al
    jmp short $+2
    mov al, 0x70                ; Green = 7, Blue = 0
    out dx, al
    jmp short $+2
    
    ; Palette 15 (bar 2): Start with bright blue  
    mov al, 0x00                ; Red = 0
    out dx, al
    jmp short $+2
    mov al, 0x07                ; Green = 0, Blue = 7
    out dx, al
    jmp short $+2
    
    ; IMPORTANT: Disable palette write mode
    mov dx, PORT_REG_ADDR
    mov al, 0x80
    out dx, al
    
    sti
    
    pop bp
    pop si
    pop dx
    pop cx
    pop bx
    pop ax
    ret

; ============================================================================
; force_black_palette0 - Force palette entry 0 to exact black (0x00, 0x00)
; Some BMP files may have slightly off "black" values; this ensures true black
; ============================================================================
force_black_palette0:
    push ax
    push dx
    
    cli
    
    mov dx, PORT_REG_ADDR
    mov al, 0x40            ; Enable palette write, start at color 0
    out dx, al
    jmp short $+2
    
    mov dx, PORT_REG_DATA
    xor al, al              ; 0x00 = red byte (R=0)
    out dx, al
    jmp short $+2
    
    xor al, al              ; 0x00 = green/blue byte (G=0, B=0)
    out dx, al
    jmp short $+2
    
    mov dx, PORT_REG_ADDR
    mov al, 0x80            ; Disable palette write (IMPORTANT!)
    out dx, al
    
    sti
    
    pop dx
    pop ax
    ret

; ============================================================================
; set_cga_palette - Reset palette to standard CGA text mode colors
; ============================================================================
set_cga_palette:
    push ax
    push cx
    push dx
    push si
    
    cli
    
    mov dx, PORT_REG_ADDR
    mov al, 0x40
    out dx, al
    jmp short $+2
    
    mov dx, PORT_REG_DATA
    mov si, cga_colors
    mov cx, 32
    
.pal_write_loop:
    lodsb
    out dx, al
    jmp short $+2
    loop .pal_write_loop
    
    ; IMPORTANT: Disable palette write mode
    mov dx, PORT_REG_ADDR
    mov al, 0x80
    out dx, al
    
    sti
    
    pop si
    pop dx
    pop cx
    pop ax
    ret

; ============================================================================
; decode_bmp - Read BMP pixel data into RAM buffer (image_buffer)
;
; The BMP is decoded into an INTERLACED RAM buffer matching VRAM layout.
; This allows fast block copies for scrolling.
;
; RAM buffer layout (interlaced):
;   - Even rows (0,2,4...198) at bytes 0-7999
;   - Odd rows (1,3,5...199) at bytes 8000-15999
;
; If BMP is 320×200, it is downsampled to 160×200 (drop every 2nd pixel)
; ============================================================================
decode_bmp:
    push ax
    push bx
    push cx
    push dx
    push di
    push si
    push es
    
    ; ES:DI will point to RAM buffer (in DS segment for .COM file)
    push ds
    pop es
    
    ; Get image dimensions
    mov ax, [bmp_header + 18]
    mov [image_width], ax
    
    ; Check if downscaling needed
    cmp ax, 160
    jbe .width_ok
    mov byte [downsample_flag], 1
    jmp .width_done
.width_ok:
    mov byte [downsample_flag], 0
.width_done:
    
    ; Get height
    mov ax, [bmp_header + 22]
    cmp ax, 200
    jbe .height_ok
    mov ax, 200
.height_ok:
    mov [image_height], ax
    
    ; Calculate bytes per row in BMP file (4-byte aligned)
    mov ax, [image_width]
    inc ax
    shr ax, 1
    add ax, 3
    and ax, 0xFFFC
    mov [bytes_per_row], ax
    
    ; Start from last row (BMP is bottom-up)
    mov ax, [image_height]
    dec ax
    mov [current_row], ax
    
.row_loop:
    ; Calculate RAM buffer offset (INTERLACED layout)
    ; Even rows: (row/2) * 80
    ; Odd rows: 8000 + (row/2) * 80
    mov ax, [current_row]
    mov bx, ax                  ; Save row number
    shr ax, 1                   ; AX = row / 2
    mov dx, BYTES_PER_LINE
    mul dx                      ; AX = (row/2) * 80
    mov di, image_buffer
    test bx, 1                  ; Is row odd?
    jz .even_row_decode
    add di, 8000                ; Odd rows start at offset 8000
.even_row_decode:
    add di, ax                  ; DI = base + (row/2) * 80
    
    ; Read scanline from file
    mov bx, [file_handle]
    mov dx, row_buffer
    mov cx, [bytes_per_row]
    mov ah, 0x3F
    int 0x21
    jc .decode_done
    or ax, ax
    jz .decode_done
    
    ; Copy or downsample to RAM buffer
    cmp byte [downsample_flag], 0
    je .no_downsample
    
    ; Downsample 320 -> 160 (drop every second pixel)
    mov si, row_buffer
    mov cx, BYTES_PER_LINE
.downsample_loop:
    lodsb                       ; Get byte with 2 pixels (P0, P1)
    and al, 0xF0                ; Keep P0 in high nibble
    mov ah, al
    lodsb                       ; Get next byte (P2, P3)
    shr al, 4                   ; P2 now in low nibble - 80186 immediate shift
    or al, ah                   ; AL = P0:P2 (dropped P1, P3)
    stosb                       ; Store to RAM buffer (ES:DI)
    
    ; C64-style: change border every 8 bytes
    push ax
    mov ax, cx
    and ax, 0x07
    jnz .no_border_ds
    mov al, [border_ctr]
    mov dx, PORT_COLOR
    out dx, al
    inc byte [border_ctr]
    and byte [border_ctr], 0x0F
.no_border_ds:
    pop ax
    
    loop .downsample_loop
    jmp .row_done
    
.no_downsample:
    ; Copy 80 bytes to RAM buffer with C64-style border cycling
    mov si, row_buffer
    mov cx, BYTES_PER_LINE
.copy_loop:
    lodsb
    stosb
    
    ; C64-style: change border every 8 bytes
    push ax
    mov ax, cx
    and ax, 0x07
    jnz .no_border_copy
    mov al, [border_ctr]
    mov dx, PORT_COLOR
    out dx, al
    inc byte [border_ctr]
    and byte [border_ctr], 0x0F
.no_border_copy:
    pop ax
    
    loop .copy_loop
    
.row_done:
    mov ax, [current_row]
    or ax, ax
    jz .decode_done
    dec ax
    mov [current_row], ax
    jmp .row_loop
    
.decode_done:
    ; Reset border to black (16-bit port, needs DX)
    mov dx, PORT_COLOR
    xor al, al
    out dx, al
    
    pop es
    pop si
    pop di
    pop dx
    pop cx
    pop bx
    pop ax
    ret

; ============================================================================
; copy_image_to_vram - Copy entire RAM buffer to VRAM using REP MOVSW
;
; OPTIMIZED: RAM buffer is now interlaced to match VRAM layout.
; This allows two large block copies instead of 200 row copies!
;
; RAM layout: Even rows at 0-7999, Odd rows at 8000-15999
; VRAM layout: Even rows at 0x0000-0x1F3F, Odd rows at 0x2000-0x3F3F
; ============================================================================
copy_image_to_vram:
    pusha                       ; 80186 PUSHA
    push es
    
    ; Set up segments: DS = code segment (RAM buffer), ES = VRAM
    mov ax, VIDEO_SEG
    mov es, ax
    
    ; Copy entire even bank in ONE operation (8000 bytes = 4000 words)
    mov si, image_buffer        ; Even rows in RAM (0-7999)
    xor di, di                  ; Even rows in VRAM (0x0000)
    mov cx, 4000                ; 8000 bytes / 2 = 4000 words
    cld
    rep movsw                   ; Single fast block copy!
    
    ; Copy entire odd bank in ONE operation (8000 bytes = 4000 words)
    mov si, image_buffer + 8000 ; Odd rows in RAM (8000-15999)
    mov di, 0x2000              ; Odd rows in VRAM (0x2000)
    mov cx, 4000                ; 8000 bytes / 2 = 4000 words
    rep movsw                   ; Single fast block copy!
    
    pop es
    popa                        ; 80186 POPA
    ret

; ============================================================================
; Data Section
; ============================================================================

msg_info    db 'DEMO5 v1.0 - Scrolling BMP + Raster Bars for Olivetti PC1', 0x0D, 0x0A
            db 'Scrolls BMP image with sine-wave motion and raster bars.', 0x0D, 0x0A
            db 0x0D, 0x0A
            db 'Usage: DEMO5 filename.bmp', 0x0D, 0x0A
            db '       BMP must NOT use palette colors 14-15', 0x0D, 0x0A
            db 0x0D, 0x0A
            db 'Press any key to exit.', 0x0D, 0x0A
            db 'By RetroErik - 2026', 0x0D, 0x0A, '$'

msg_file_err db 'Error: Cannot open file', 0x0D, 0x0A, '$'
msg_not_bmp  db 'Error: Not a valid BMP file', 0x0D, 0x0A, '$'
msg_format   db 'Error: BMP must be 4-bit uncompressed', 0x0D, 0x0A, '$'
msg_loading  db 'Loading demo, please wait...', '$'

; File handling
filename_ptr    dw 0
file_handle     dw 0
image_width     dw 0
image_height    dw 0
bytes_per_row   dw 0
current_row     dw 0
downsample_flag db 0
border_ctr      db 0

; Bar animation state
bar1_y          db 0            ; Bar 1 current Y position
bar2_y          db 0            ; Bar 2 current Y position
bar1_old_y      db 0            ; Bar 1 previous Y position
bar2_old_y      db 0            ; Bar 2 previous Y position
bar1_sine_idx   db 0            ; Bar 1 sine table index
bar2_sine_idx   db 0            ; Bar 2 sine table index
color_cycle_idx db 0            ; Current color in gradient
color_frame_ctr db 0            ; Frame counter for color speed
front_bar       db 0            ; Which bar is in front (for dancing effect)
last_bar1_above db 1            ; Was bar1 above bar2 last frame?
fill_byte       db 0            ; Temp storage for bar fill byte

; Image scroll animation state
image_x         dw 0            ; Current image X position (signed, can be negative)
image_y         dw 0            ; Current image Y position (signed, can be negative)
image_sine_x    db 0            ; X sine table index
image_sine_y    db 0            ; Y sine table index

; ============================================================================
; Color Gradients for Palette Cycling Animation
; 
; These tables define the color cycling animation for palette entries 14 and 15.
; Each entry is 2 bytes: Red (bits 0-2), Green<<4|Blue (bits 0-2)
; The tables have 16 entries for smooth looping animation.
;
; update_bar_palette cycles through these tables each frame, giving the
; solid-color bars a "breathing" or "pulsing" appearance.
; ============================================================================

; Green gradient for Bar 1 (palette 14) - smooth cyan/green wave
; Smoothly transitions: dark -> medium -> bright -> medium -> dark
; Using cyan-green hues (G=0-7, B=0-5) for a cohesive wave
green_gradient:
    db 0x00, 0x10               ; 0:  Very dark green
    db 0x00, 0x20               ; 1:  Dark green
    db 0x00, 0x31               ; 2:  Dark green + hint blue
    db 0x00, 0x42               ; 3:  Medium green-cyan
    db 0x00, 0x53               ; 4:  Medium-bright cyan
    db 0x00, 0x64               ; 5:  Bright cyan
    db 0x00, 0x75               ; 6:  Very bright cyan
    db 0x00, 0x76               ; 7:  Peak brightness cyan
    db 0x00, 0x75               ; 8:  Very bright cyan (descending)
    db 0x00, 0x64               ; 9:  Bright cyan
    db 0x00, 0x53               ; 10: Medium-bright cyan
    db 0x00, 0x42               ; 11: Medium green-cyan
    db 0x00, 0x31               ; 12: Dark green + hint blue
    db 0x00, 0x20               ; 13: Dark green
    db 0x00, 0x10               ; 14: Very dark green
    db 0x00, 0x20               ; 15: Dark green (smooth loop)

; Blue gradient for Bar 2 (palette 15) - smooth magenta/purple wave
; Smoothly transitions: dark -> medium -> bright -> medium -> dark
; Using magenta-blue hues (R=0-7, B=3-7) for a cohesive wave
blue_gradient:
    db 0x01, 0x02               ; 0:  Very dark purple
    db 0x02, 0x03               ; 1:  Dark purple
    db 0x03, 0x04               ; 2:  Dark magenta
    db 0x04, 0x05               ; 3:  Medium magenta
    db 0x05, 0x06               ; 4:  Medium-bright magenta
    db 0x06, 0x07               ; 5:  Bright magenta
    db 0x07, 0x07               ; 6:  Very bright magenta
    db 0x07, 0x17               ; 7:  Peak brightness (magenta + green tint)
    db 0x07, 0x07               ; 8:  Very bright magenta (descending)
    db 0x06, 0x07               ; 9:  Bright magenta
    db 0x05, 0x06               ; 10: Medium-bright magenta
    db 0x04, 0x05               ; 11: Medium magenta
    db 0x03, 0x04               ; 12: Dark magenta
    db 0x02, 0x03               ; 13: Dark purple
    db 0x01, 0x02               ; 14: Very dark purple
    db 0x02, 0x03               ; 15: Dark purple (smooth loop)

; ============================================================================
; Standard CGA palette for restoring on exit
; ============================================================================
cga_colors:
    db 0x00, 0x00               ; 0:  Black
    db 0x00, 0x05               ; 1:  Blue
    db 0x00, 0x50               ; 2:  Green
    db 0x00, 0x55               ; 3:  Cyan
    db 0x05, 0x00               ; 4:  Red
    db 0x05, 0x05               ; 5:  Magenta
    db 0x05, 0x20               ; 6:  Brown
    db 0x05, 0x55               ; 7:  Light Gray
    db 0x02, 0x22               ; 8:  Dark Gray
    db 0x02, 0x27               ; 9:  Light Blue
    db 0x02, 0x72               ; 10: Light Green
    db 0x02, 0x77               ; 11: Light Cyan
    db 0x07, 0x22               ; 12: Light Red
    db 0x07, 0x27               ; 13: Light Magenta
    db 0x07, 0x70               ; 14: Yellow
    db 0x07, 0x77               ; 15: White

; ============================================================================
; Sine table (256 entries, values 0-100 representing sine wave)
; Center value is 50, oscillates between 0 and 100
; Used for smooth wobble motion
; ============================================================================
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

; ============================================================================
; Buffers (must be at end of file)
; ============================================================================

; BMP file header buffer
bmp_header:     times 128 db 0

; Row buffer for file reading
row_buffer:     times 164 db 0

; ============================================================================
; RAM Image Buffer (16,000 bytes = 160×200×4-bit)
;
; This is the master copy of the decoded BMP image in INTERLACED format.
; Layout matches VRAM for fast block copies:
;   - Bytes 0-7999: Even rows (0,2,4...198) - 100 rows × 80 bytes
;   - Bytes 8000-15999: Odd rows (1,3,5...199) - 100 rows × 80 bytes
;
; Used for:
;   1. Fast RAM→VRAM copy using REP MOVSW (just 2 block copies!)
;   2. Restoring scanlines after raster bars pass (avoids VRAM reads)
;
; With Y scroll always in 2-pixel steps, bank alignment is preserved,
; allowing massive speedup compared to row-by-row copying.
; ============================================================================
image_buffer:   times IMAGE_SIZE db 0

; ============================================================================
; End of Program
; ============================================================================
