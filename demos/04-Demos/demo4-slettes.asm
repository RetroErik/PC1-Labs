; ============================================================================
; DEMO4.ASM - BMP Image with Animated Raster Bars from RAM Buffer
; Olivetti Prodest PC1 - V6355D 160x200x16 Hidden Graphics Mode
; Written for NASM - NEC V40 @ 8 MHz (8086 instruction set only)
; By RetroErik - 2026 with GitHub Copilot
;
; Description:
;   Loads and displays a 4-bit BMP image, then overlays two horizontal
;   raster bars that move independently using sine-wave motion.
;   The bars use reserved palette entries 14 and 15 which are updated
;   during VBlank for smooth, flicker-free color cycling.
;
; NEW RAM BUFFER DESIGN:
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
; RAM BUFFER LAYOUT (linear for simplicity):
;   - 16,000 bytes total (160×200×4-bit = 80 bytes × 200 rows)
;   - Row N at offset: N * 80
;
; RASTER BAR RESTORE TECHNIQUE:
;   Instead of backing up VRAM scanlines before drawing bars, we use the
;   RAM image buffer as the master copy. When restoring scanlines after
;   the bar passes, we copy from RAM→VRAM using REP MOVSB/MOVSW.
;   This avoids slow VRAM→RAM reads during the raster effect.
;
; COLOR CYCLING TECHNIQUE: (commented out)
;   The bars themselves are drawn as solid horizontal strips using fixed
;   palette indices (14 and 15). The pixels in VRAM never change color index -
;   they always contain 0xEE (palette 14) or 0xFF (palette 15).
;
;   The "color animation" happens by changing what color those palette indices
;   actually display. During VBlank, we write new RGB values to palette
;   registers 14 and 15 in the V6355D. This instantly changes the displayed
;   color of all pixels using those indices.
;
;   This is extremely efficient because:
;   - We only write 4 bytes to the palette per frame (2 colors × 2 bytes)
;   - No VRAM writes needed for color changes
;   - Smooth gradients with zero flicker (palette changes are atomic)
;
;   V6355D Palette Format (2 bytes per color):
;   - Byte 1: Red intensity (bits 0-2, values 0-7)
;   - Byte 2: Green (bits 4-6) | Blue (bits 0-2)
;   - Palette starts at register 0x40, so color N is at 0x40 + (N*2)
;
; VBlank Timing & Palette Safety:
;   - All palette updates occur during VBlank (bit 3 of PORT_STATUS)
;   - VBlank is ~1.4ms on PAL timing - enough time for palette writes
;   - Writing during VBlank avoids "snow" artifacts and color tearing
;   - Bar strip drawing also occurs during VBlank for clean animation
;
; Usage: DEMO3 filename.bmp
;        Press any key to exit
;
; Prerequisites:
;   Run PERITEL.COM first to set horizontal position correctly
;   BMP file must be 160x200 or 320x200, 4-bit (16 colors)
;   BMP must NOT use palette colors 14 and 15 (reserved for bars)
; ============================================================================

[BITS 16]
[CPU 8086]                      ; NEC V40 doesn't support all 80186 instructions
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
; Bars use palette indices 14 and 15 - these must be free in the BMP!
; Each bar is drawn as horizontal strips in VRAM, then the palette
; colors 14/15 are cycled during VBlank for smooth animation.
; ============================================================================

BAR_HEIGHT      equ 20           ; Height of each bar in scanlines
BAR1_PALETTE    equ 14          ; Palette index for bar 1
BAR2_PALETTE    equ 15          ; Palette index for bar 2

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
COLOR_SPEED     equ 6           ; Lower = faster color cycling (was 2, now slower)

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
    ; All bar updates happen during VBlank for flicker-free animation
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
    ; DISABLED: Color cycling commented out for testing
    ; call update_bar_palette
    
    ; --------------------------------------------------------------------
    ; STEP 3: Restore old bar positions (erase old strips)
    ; Must restore original BMP pixels before drawing new bars
    ; Copies from RAM image_buffer (master copy) to VRAM
    ; --------------------------------------------------------------------
    call restore_old_bars
    
    ; --------------------------------------------------------------------
    ; STEP 4: Calculate new bar Y positions using sine wave
    ; Updates bar1_y and bar2_y based on sine table lookup
    ; --------------------------------------------------------------------
    call update_bar_positions
    
    ; --------------------------------------------------------------------
    ; STEP 5: Draw new bar strips
    ; Draw bars using palette 14/15 (no backup needed - RAM buffer is master)
    ; --------------------------------------------------------------------
    call draw_bar_strips
    
    ; --------------------------------------------------------------------
    ; STEP 6: Check for keypress (exit on any key)
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
    
    ; Restore bars (remove them from display)
    call restore_old_bars
    
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
    ; Writing to PORT_PAL_ADDR sets which V6355D register we'll modify
    ; -----------------------------------------------------------------------
    mov al, 0x5C
    out PORT_PAL_ADDR, al
    jmp short $+2               ; I/O delay (required for V6355D timing)
    
    ; -----------------------------------------------------------------------
    ; STEP B: Write 2 bytes for color 14 (bar 1 - green gradient)
    ; Byte 1 = Red (bits 0-2), Byte 2 = Green (bits 4-6) | Blue (bits 0-2)
    ; After each write, register address auto-increments
    ; -----------------------------------------------------------------------
    mov si, green_gradient
    mov al, [si + bx]           ; Get Red byte from gradient table
    out PORT_PAL_DATA, al       ; Write to register 0x5C (color 14, red)
    jmp short $+2
    mov al, [si + bx + 1]       ; Get Green|Blue byte from gradient table  
    out PORT_PAL_DATA, al       ; Write to register 0x5D (color 14, green|blue)
    jmp short $+2               ; After this, register pointer is at 0x5E
    
    ; -----------------------------------------------------------------------
    ; STEP C: Write 2 bytes for color 15 (bar 2 - blue gradient)
    ; No need to set address - auto-increment already points to 0x5E
    ; -----------------------------------------------------------------------
    mov si, blue_gradient
    mov al, [si + bx]           ; Get Red byte from gradient table
    out PORT_PAL_DATA, al       ; Write to register 0x5E (color 15, red)
    jmp short $+2
    mov al, [si + bx + 1]       ; Get Green|Blue byte from gradient table
    out PORT_PAL_DATA, al       ; Write to register 0x5F (color 15, green|blue)
    jmp short $+2
    
    ; IMPORTANT: Disable palette write mode
    mov al, 0x80
    out PORT_PAL_ADDR, al
    
    sti                         ; Re-enable interrupts
    
    pop si
    pop dx
    pop bx
    pop ax
    ret

; ============================================================================
; update_bar_positions - Calculate new Y positions using sine wave
; Uses same calculation as rbars4.asm for consistent "dancing" motion
; ============================================================================
update_bar_positions:
    push ax
    push bx
    push si
    
    ; Update bar 1 sine index
    mov al, [bar1_sine_idx]
    add al, BAR1_SPEED
    mov [bar1_sine_idx], al         ; Wraps automatically (0-255)
    
    ; Calculate bar 1 Y position: center + sine[index] - amplitude
    ; (Same formula as rbars4.asm)
    xor ah, ah
    mov si, ax
    mov al, [sine_table + si]       ; Get sine value (0-100, centered at 50)
    add al, BAR1_CENTER
    sub al, SINE_AMPLITUDE          ; Adjust so sine oscillates around center
    
    ; Clamp to valid screen range (0 to SCREEN_HEIGHT - BAR_HEIGHT)
    ; Check for underflow (if result went negative, AL > 200)
    cmp al, SCREEN_HEIGHT
    jb .bar1_not_wrapped
    xor al, al                      ; Clamp to 0 if wrapped negative
    jmp .bar1_clamped
.bar1_not_wrapped:
    ; Check for overflow (bar would extend past bottom)
    mov bl, SCREEN_HEIGHT - BAR_HEIGHT
    cmp al, bl
    jbe .bar1_clamped
    mov al, bl                      ; Clamp to max
.bar1_clamped:
    mov [bar1_y], al
    
    ; Update bar 2 sine index
    mov al, [bar2_sine_idx]
    add al, BAR2_SPEED
    mov [bar2_sine_idx], al         ; Wraps automatically (0-255)
    
    ; Calculate bar 2 Y position: center + sine[index] - amplitude
    xor ah, ah
    mov si, ax
    mov al, [sine_table + si]       ; Get sine value
    add al, BAR2_CENTER
    sub al, SINE_AMPLITUDE          ; Adjust so sine oscillates around center
    
    ; Clamp to valid screen range
    cmp al, SCREEN_HEIGHT
    jb .bar2_not_wrapped
    xor al, al                      ; Clamp to 0 if wrapped negative
    jmp .bar2_clamped
.bar2_not_wrapped:
    mov bl, SCREEN_HEIGHT - BAR_HEIGHT
    cmp al, bl
    jbe .bar2_clamped
    mov al, bl                      ; Clamp to max
.bar2_clamped:
    mov [bar2_y], al
    
    pop si
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
; Input: AL = Y position (SI parameter is now ignored - we use RAM buffer)
; Clobbers: AX, BX, CX, DI, SI
;
; NEW: Reads from image_buffer (master copy) instead of VRAM backup.
;      This avoids VRAM→RAM reads which are slower than RAM→VRAM writes.
; ----------------------------------------------------------------------------
restore_strip:
    push ax
    push bx
    push cx
    push dx
    push bp
    push si
    
    mov bh, al                  ; BH = starting Y position (preserved across calls)
    mov bp, BAR_HEIGHT          ; BP = loop counter
    
.restore_row:
    ; Skip if Y >= 200 (off screen)
    cmp bh, SCREEN_HEIGHT
    jae .restore_done
    
    mov al, bh                  ; AL = current Y position
    
    ; Calculate VRAM offset for this row (CGA interlaced)
    call calc_vram_offset       ; Returns offset in DI, clobbers AX, DX
    
    ; Calculate RAM buffer offset for this row: Y * 80 (linear)
    mov al, bh                  ; AL = Y position
    xor ah, ah
    mov dx, BYTES_PER_LINE
    mul dx                      ; AX = Y * 80
    mov si, image_buffer
    add si, ax                  ; SI = image_buffer + (Y * 80)
    
    ; Copy 80 bytes from RAM buffer (DS:SI) to VRAM (ES:DI) using REP MOVSB
    mov cx, BYTES_PER_LINE
    cld
    rep movsb                   ; Fast block copy
    
    inc bh                      ; Next row
    dec bp                      ; Decrement loop counter
    jnz .restore_row
    
.restore_done:
    pop si
    pop bp
    pop dx
    pop cx
    pop bx
    pop ax
    ret

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
    
    ; Detect crossing: if bars swapped relative positions, toggle front bar
    ; This creates the 3D "dancing" effect from rbars4
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
    
    ; Draw bars based on front_bar state (not just Y position)
    cmp byte [front_bar], 0
    jnz .bar2_in_front
    
    ; Bar 1 in front: draw bar 2 first, then bar 1 on top
    mov al, [bar2_y]
    mov bl, BAR2_PALETTE
    call draw_strip
    
    mov al, [bar1_y]
    mov bl, BAR1_PALETTE
    call draw_strip
    jmp .done
    
.bar2_in_front:
    ; Bar 2 in front: draw bar 1 first, then bar 2 on top
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
; draw_strip - Draw a solid color strip (NO VRAM BACKUP needed)
; Input: AL = Y position, BL = palette index
; Uses ES = VIDEO_SEG (already set by caller)
;
; NEW: We no longer backup VRAM here. The RAM image_buffer serves as the
;      master copy, so restore_strip reads from there instead.
; ----------------------------------------------------------------------------
draw_strip:
    push ax
    push bx
    push cx
    push dx
    push di
    push bp
    
    mov bh, al                  ; BH = starting Y position
    
    ; Prepare the fill byte (two pixels of same palette index)
    mov al, bl
    mov cl, 4
    shl al, cl
    or al, bl                   ; AL = packed pixels (e.g., 0xEE for palette 14)
    mov bl, al                  ; BL = fill byte (preserved across calls)
    
    mov bp, BAR_HEIGHT          ; BP = loop counter
    
.process_row:
    ; Skip if Y >= 200 (off screen)
    cmp bh, SCREEN_HEIGHT
    jae .draw_done
    
    mov al, bh                  ; AL = current Y position
    
    ; Calculate VRAM offset for this row
    call calc_vram_offset       ; Returns offset in DI, clobbers AX, DX
    
    ; Fill 80 bytes in VRAM with bar color using REP STOSB
    mov cx, BYTES_PER_LINE
    mov al, bl                  ; Bar color (packed pixel byte)
    cld
    rep stosb                   ; Fast fill to ES:DI
    
    inc bh                      ; Next row
    dec bp                      ; Decrement loop counter
    jnz .process_row
    
.draw_done:
    pop bp
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
; set_bmp_palette - Set palette from BMP file, but preserve colors 14-15
; BMP palette: 64 bytes (16 colors × 4 bytes BGRA)
; 6355 palette: 32 bytes (16 colors × 2 bytes)
; ============================================================================
set_bmp_palette:
    push ax
    push bx
    push cx
    push dx
    push si
    
    cli
    
    ; Enable palette write at register 0x40
    mov al, 0x40
    out PORT_PAL_ADDR, al
    jmp short $+2
    
    ; Convert colors 0-13 from BMP format to 6355 format
    mov si, bmp_header + 54     ; Palette starts at offset 54
    mov cx, 14                  ; Only 14 colors (0-13)
    
.palette_loop:
    ; BMP stores as: Blue, Green, Red, Alpha
    lodsb                       ; Blue
    mov bl, al
    lodsb                       ; Green
    mov bh, al
    lodsb                       ; Red (need to convert 8-bit to 3-bit)
    
    ; NEC V40 compatible: shr al, 5 -> use CL for shift
    push cx                     ; Save loop counter (we need CL for shift)
    mov cl, 5
    shr al, cl                  ; Convert Red to 3-bit (0-7)
    pop cx                      ; Restore loop counter
    
    out PORT_PAL_DATA, al
    jmp short $+2
    
    ; Combine Green and Blue
    mov al, bh                  ; Green
    and al, 0xE0                ; Keep upper 3 bits
    
    push cx                     ; Save loop counter
    mov cl, 1
    shr al, cl                  ; Shift to bits 4-6
    pop cx                      ; Restore loop counter
    
    mov ah, al                  ; Save green component
    mov al, bl                  ; Blue
    
    push cx                     ; Save loop counter
    mov cl, 5
    shr al, cl                  ; Convert Blue to 3-bit
    pop cx                      ; Restore loop counter
    
    or al, ah                   ; Combine: Green (4-6) | Blue (0-2)
    out PORT_PAL_DATA, al
    jmp short $+2
    
    lodsb                       ; Skip alpha
    loop .palette_loop
    
    ; Skip BMP colors 14-15 (we don't read them)
    ; Instead, set our bar colors
    
    ; Color 14: Initial green color (will be animated)
    mov al, 0x00                ; No red
    out PORT_PAL_DATA, al
    jmp short $+2
    mov al, 0x70                ; Pure green
    out PORT_PAL_DATA, al
    jmp short $+2
    
    ; Color 15: Initial blue color (will be animated)
    mov al, 0x00                ; No red
    out PORT_PAL_DATA, al
    jmp short $+2
    mov al, 0x07                ; Pure blue
    out PORT_PAL_DATA, al
    jmp short $+2
    
    ; IMPORTANT: Disable palette write mode
    mov al, 0x80
    out PORT_PAL_ADDR, al
    
    sti
    
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
    
    cli
    
    mov al, 0x40            ; Enable palette write, start at color 0
    out PORT_PAL_ADDR, al
    jmp short $+2
    
    xor al, al              ; 0x00 = red byte (R=0)
    out PORT_PAL_DATA, al
    jmp short $+2
    
    xor al, al              ; 0x00 = green/blue byte (G=0, B=0)
    out PORT_PAL_DATA, al
    jmp short $+2
    
    mov al, 0x80            ; Disable palette write (IMPORTANT!)
    out PORT_PAL_ADDR, al
    
    sti
    
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
    out PORT_PAL_ADDR, al
    jmp short $+2
    
    mov si, cga_colors
    mov cx, 32
    
.pal_write_loop:
    lodsb
    out PORT_PAL_DATA, al
    jmp short $+2
    loop .pal_write_loop
    
    ; IMPORTANT: Disable palette write mode
    mov al, 0x80
    out PORT_PAL_ADDR, al
    
    sti
    
    pop si
    pop cx
    pop ax
    ret

; ============================================================================
; decode_bmp - Read BMP pixel data into RAM buffer (image_buffer)
;
; The BMP is decoded into a LINEAR RAM buffer, not directly to VRAM.
; This allows fast RAM→VRAM block copies and serves as the master copy
; for restoring scanlines after raster bar effects.
;
; RAM buffer layout: Row N at offset N * 80 (linear, 80 bytes per row)
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
    ; Calculate RAM buffer offset: current_row * 80 (linear layout)
    mov ax, [current_row]
    mov bx, BYTES_PER_LINE
    mul bx                      ; AX = row * 80
    mov di, image_buffer
    add di, ax                  ; DI = image_buffer + (row * 80)
    
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
    ; NEC V40 compatible: shr al, 4 -> use 4x shr al, 1
    shr al, 1
    shr al, 1
    shr al, 1
    shr al, 1                   ; P2 now in low nibble
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
; Handles CGA-style interlacing:
;   - Even rows (0,2,4...): VRAM offset = (row/2) * 80
;   - Odd rows (1,3,5...):  VRAM offset = 0x2000 + (row/2) * 80
;
; RAM buffer is linear: Row N at offset N * 80
; Uses REP MOVSW for maximum transfer speed (copies 2 bytes at a time)
; ============================================================================
copy_image_to_vram:
    push ax
    push bx
    push cx
    push dx
    push di
    push si
    push ds
    push es
    
    ; Set up segments: DS = code segment (RAM buffer), ES = VRAM
    mov ax, VIDEO_SEG
    mov es, ax
    
    ; Copy even rows (0, 2, 4, ... 198) to VRAM bank 0
    mov si, image_buffer        ; Start of RAM buffer
    xor di, di                  ; Start of VRAM bank 0
    mov dx, 100                 ; 100 even rows
    
.copy_even_rows:
    mov cx, 40                  ; 80 bytes / 2 = 40 words
    cld
    rep movsw                   ; Copy one row (80 bytes)
    add si, BYTES_PER_LINE      ; Skip odd row in RAM buffer
    dec dx
    jnz .copy_even_rows
    
    ; Copy odd rows (1, 3, 5, ... 199) to VRAM bank 1
    mov si, image_buffer + BYTES_PER_LINE  ; Row 1 in RAM buffer
    mov di, 0x2000              ; Start of VRAM bank 1 (odd rows)
    mov dx, 100                 ; 100 odd rows
    
.copy_odd_rows:
    mov cx, 40                  ; 80 bytes / 2 = 40 words
    cld
    rep movsw                   ; Copy one row (80 bytes)
    add si, BYTES_PER_LINE      ; Skip even row in RAM buffer
    dec dx
    jnz .copy_odd_rows
    
    pop es
    pop ds
    pop si
    pop di
    pop dx
    pop cx
    pop bx
    pop ax
    ret

; ============================================================================
; Data Section
; ============================================================================

msg_info    db 'DEMO3 v1.0 - BMP + Raster Bars Demo for Olivetti PC1', 0x0D, 0x0A
            db 'Displays BMP with animated raster bar overlay.', 0x0D, 0x0A
            db 0x0D, 0x0A
            db 'Usage: DEMO3 filename.bmp', 0x0D, 0x0A
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
front_bar       db 0            ; Which bar is in front (0=bar1, 1=bar2)
last_bar1_above db 1            ; Was bar1 above bar2 last frame? (for crossing detection)
temp_y          db 0            ; Temporary Y position for strip routines
temp_fill       db 0            ; Temporary fill byte for draw_strip

; ============================================================================
; Color gradient for bar 1 (green-yellow-cyan cycle)
;
; Format: 2 bytes per color entry
;   Byte 1: Red intensity (bits 0-2 = 0-7)
;   Byte 2: Green (bits 4-6) | Blue (bits 0-2)
;
; Cycles: Green -> Yellow -> White -> Cyan -> Green
; ============================================================================
green_gradient:
    db 0x00, 0x70               ; 0:  Pure bright green
    db 0x02, 0x70               ; 1:  Green + red = yellow-green
    db 0x05, 0x70               ; 2:  More yellow
    db 0x07, 0x70               ; 3:  Bright yellow
    db 0x07, 0x77               ; 4:  White (all colors max)
    db 0x05, 0x77               ; 5:  Light cyan-white
    db 0x02, 0x77               ; 6:  Cyan
    db 0x00, 0x77               ; 7:  Bright cyan
    db 0x00, 0x75               ; 8:  Cyan-green
    db 0x00, 0x73               ; 9:  More green
    db 0x00, 0x70               ; 10: Pure green
    db 0x00, 0x50               ; 11: Dark green
    db 0x00, 0x30               ; 12: Darker green
    db 0x00, 0x20               ; 13: Very dark
    db 0x00, 0x40               ; 14: Medium green
    db 0x00, 0x60               ; 15: Bright green

; ============================================================================
; Color gradient for bar 2 (blue-magenta-cyan cycle)
;
; Format: 2 bytes per color entry
;   Byte 1: Red intensity (bits 0-2 = 0-7)
;   Byte 2: Green (bits 4-6) | Blue (bits 0-2)
;
; Cycles: Blue -> Magenta -> Red -> Magenta -> Blue -> Cyan
; ============================================================================
blue_gradient:
    db 0x00, 0x07               ; 0:  Pure bright blue
    db 0x02, 0x07               ; 1:  Blue + red = purple
    db 0x05, 0x07               ; 2:  Magenta
    db 0x07, 0x05               ; 3:  Light magenta
    db 0x07, 0x02               ; 4:  Red-magenta
    db 0x07, 0x00               ; 5:  Bright red
    db 0x05, 0x02               ; 6:  Dark red-magenta
    db 0x03, 0x05               ; 7:  Purple
    db 0x00, 0x07               ; 8:  Back to blue
    db 0x00, 0x27               ; 9:  Blue + green = cyan-blue
    db 0x00, 0x57               ; 10: Cyan
    db 0x00, 0x77               ; 11: Bright cyan
    db 0x00, 0x55               ; 12: Medium cyan
    db 0x00, 0x35               ; 13: Dark cyan-blue
    db 0x00, 0x05               ; 14: Dark blue
    db 0x00, 0x03               ; 15: Very dark blue

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
; This is the master copy of the decoded BMP image in LINEAR format.
; Layout: Row N at offset N * 80 (80 bytes per row, 2 pixels per byte)
;
; Used for:
;   1. Fast RAM→VRAM copy using REP MOVSW during initial display
;   2. Restoring scanlines after raster bars pass (avoids VRAM reads)
;
; NOTE: VRAM uses CGA interlacing, but this buffer is linear for simplicity.
;       The copy_image_to_vram routine handles the layout conversion.
; ============================================================================
image_buffer:   times IMAGE_SIZE db 0

; ============================================================================
; End of Program
; ============================================================================
