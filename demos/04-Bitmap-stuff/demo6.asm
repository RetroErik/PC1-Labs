; ============================================================================
; DEMO6.ASM - Partial Image Panning with C64-Style Wobble Effect
; Olivetti Prodest PC1 - V6355D 160x200x16 Hidden Graphics Mode
; Written for NASM - NEC V40 @ 8 MHz (80186 instruction set)
; By RetroErik - 2026 with GitHub Copilot
;
; Description:
;   Loads a 4-bit BMP image and pans a configurable section (default 50 rows)
;   around the screen using sine-wave motion for classic C64 "wobble" effect.
;   Demonstrates fast partial-screen updates with minimal flicker.
;   FPS counter shows actual performance (updates once per second).
;
; ============================================================================
; OPTIMIZATION TECHNIQUES USED
; ============================================================================
;
; 1. DELTA CLEARING (major flicker reduction!)
;    - Instead of clear-all then draw-all (causes visible flash)
;    - Only clear exposed rows that won't be overwritten by new position
;    - Moving down? Clear only top exposed rows
;    - Moving up? Clear only bottom exposed rows
;    - Result: No visible "gap" between clear and draw!
;
; 2. INTERLACED RAM BUFFER (major speedup)
;    - RAM buffer layout mirrors VRAM's CGA interlacing
;    - Even rows at bytes 0-7999, odd rows at bytes 8000-15999
;    - Allows bulk bank-to-bank copies instead of row-by-row
;
; 3. 2-PIXEL Y MOVEMENT STEPS
;    - Y scroll always moves in 2-pixel increments
;    - Preserves bank alignment (even row stays even, odd stays odd)
;    - Enables fast block copies without per-row bank calculations
;
; 4. 80186 INSTRUCTIONS (CPU 186 directive)
;    - PUSHA/POPA for fast register save/restore
;    - Immediate operand shifts (shr al, 4 instead of loop)
;    - These are native on the NEC V40 processor
;
; 5. REP MOVSW / REP STOSW FOR BLOCK TRANSFERS
;    - Uses 16-bit word moves for both copy and clear operations
;    - Minimizes loop overhead for large transfers
;
; 6. PARTIAL SCREEN UPDATES (speed test)
;    - Only updates PARTIAL_HEIGHT rows per frame (configurable)
;    - 50 rows = 50 FPS with VSync, 72 FPS free-running (44% headroom)
;    - 74 rows = max for stable 50 FPS (edge of timing budget)
;    - 100 rows = 25 FPS with VSync (half rate, still smooth)
;
; ============================================================================
; VRAM LAYOUT (CGA-style interlacing)
; ============================================================================
;
;   - Segment 0xB000, 16KB total
;   - Even rows (0, 2, 4...): offset = (row/2) * 80
;   - Odd rows (1, 3, 5...):  offset = 0x2000 + (row/2) * 80
;   - Each bank is 8KB (100 rows × 80 bytes)
;
; ============================================================================
; RAM BUFFER LAYOUT (interlaced to match VRAM)
; ============================================================================
;
;   - 16,000 bytes total (160×200×4-bit = 80 bytes × 200 rows)
;   - Even rows (0,2,4...198): bytes 0-7999 (100 rows × 80 bytes)
;   - Odd rows (1,3,5...199): bytes 8000-15999 (100 rows × 80 bytes)
;   - Y scroll always moves in 2-pixel steps to preserve bank alignment
;
; ============================================================================
; C64-STYLE WOBBLE MOTION
; ============================================================================
;
;   - Uses sine wave tables for smooth oscillation
;   - X and Y have independent speeds and phase offsets
;   - Creates Lissajous-like patterns when combined
;   - Configurable amplitude and speed for different effects
;
; Usage: DEMO6 filename.bmp
;        Press V to toggle VSync (for benchmarking)
;        Press any other key to exit
;
; Prerequisites:
;   Run PERITEL.COM first to set horizontal position correctly
;   BMP file must be 160x200 or 320x200, 4-bit (16 colors)
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

; Partial update parameters - Height of image section to move
; Change these values to test different section sizes
PARTIAL_HEIGHT  equ 50          ; Rows to update (74 = max for 50 FPS)
PARTIAL_EVEN    equ 25          ; Must be PARTIAL_HEIGHT / 2
PARTIAL_ODD     equ 25          ; Must be PARTIAL_HEIGHT / 2
MAX_Y_POSITION  equ (200 - PARTIAL_HEIGHT)  ; Maximum Y before clipping

; BMP File Header offsets
BMP_SIGNATURE   equ 0           ; 'BM' signature (2 bytes)
BMP_DATA_OFFSET equ 10          ; Offset to pixel data (dword)
BMP_WIDTH       equ 18          ; Image width (dword)
BMP_HEIGHT      equ 22          ; Image height (dword)
BMP_BPP         equ 28          ; Bits per pixel (word)
BMP_COMPRESSION equ 30          ; Compression (dword, 0=none)

; ============================================================================
; C64-STYLE WOBBLE CONFIGURATION
; ============================================================================
; The 50-row image section bounces around the screen using sine wave motion.
; X and Y have independent speeds/phases for Lissajous-like patterns.
; Adjust these values to change the wobble character!
; ============================================================================

; Image movement amplitude (pixels from center)
IMAGE_X_AMPLITUDE equ 40        ; Horizontal wobble range (±40 pixels = 80 total)
IMAGE_Y_AMPLITUDE equ (MAX_Y_POSITION / 2)  ; Vertical range - auto-calculated!

; Image movement speed (higher = faster) - C64 "wobble" style!
IMAGE_X_SPEED   equ 3           ; X sine index increment per frame
IMAGE_Y_SPEED   equ 4           ; Y sine index increment per frame (different = Lissajous)

; Starting phase offset (creates interesting motion patterns)
IMAGE_X_PHASE   equ 0           ; X starts at sine position 0
IMAGE_Y_PHASE   equ 85          ; Y starts 120 degrees offset (more dramatic Lissajous)

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
    call decode_bmp
    
    ; Close file (done reading)
    mov bx, [file_handle]
    mov ah, 0x3E
    int 0x21
    
    ; Switch to graphics mode after loading is complete
    call enable_graphics_mode
    
    ; Blank video output during VRAM setup (prevents flicker)
    mov dx, PORT_MODE
    mov al, 0x42                ; Graphics mode, video OFF
    out dx, al
    
    ; Clear screen
    call clear_screen
    
    ; Set palette from BMP
    call set_bmp_palette
    
    ; Force palette 0 to true black (some BMPs have off-black)
    call force_black_palette0
    
    ; Find the brightest color in the palette for FPS counter text
    call find_brightest_color
    
    ; UNUSED: draw_demo6_text draws "0,1,2,3,4,5,6,7,8,9" test string
    ; call draw_demo6_text
    
    ; UNUSED: copy_image_to_vram copies full 200-row image at once
    ; call copy_image_to_vram
    
    ; Initialize image scroll state
    mov byte [image_sine_x], IMAGE_X_PHASE
    mov byte [image_sine_y], IMAGE_Y_PHASE
    mov word [image_x], 0
    mov word [image_y], 0
    
    ; Initialize previous Y position to center (where first frame will draw)
    mov word [prev_y_start], 75
    mov word [dest_y_start], 75
    
    ; Reset border to black
    mov dx, PORT_COLOR
    xor al, al
    out dx, al
    
    ; Enable video output
    mov dx, PORT_MODE
    mov al, 0x4A
    out dx, al
    
    ; ========================================================================
    ; MAIN ANIMATION LOOP
    ; ========================================================================
.main_loop:
    ; --------------------------------------------------------------------
    ; STEP 1: Wait for VBlank (if enabled)
    ; Press 'V' to toggle VBlank sync on/off for benchmarking
    ; --------------------------------------------------------------------
    cmp byte [vsync_enabled], 0
    je .skip_vblank
    call wait_vblank
.skip_vblank:
    
    ; --------------------------------------------------------------------
    ; STEP 2: Update image position using sine wave
    ; Calculates new X,Y position for the scrolling image
    ; Uses Lissajous pattern (different X/Y speeds + phase offset)
    ; Creates classic C64 "wobble" effect!
    ; --------------------------------------------------------------------
    call update_image_position
    
    ; --------------------------------------------------------------------
    ; STEP 3: Delta clear - only clear exposed rows (reduces flicker!)
    ; Instead of clearing all 50 rows, only clear rows that won't be
    ; overwritten by the new image position.
    ; --------------------------------------------------------------------
    call delta_clear_and_draw
    
    ; --------------------------------------------------------------------
    ; STEP 4: Save current position for next frame
    ; --------------------------------------------------------------------
    mov ax, [dest_y_start]
    mov [prev_y_start], ax
    
    ; --------------------------------------------------------------------
    ; STEP 5: FPS counter using BIOS timer (18.2 Hz tick at 0040:006C)
    ; Counts frames, updates display every ~1 second (18 ticks)
    ; --------------------------------------------------------------------
    inc word [frame_count]
    
    ; Read BIOS timer tick count
    push es
    mov ax, 0x0040
    mov es, ax
    mov ax, [es:0x006C]         ; Low word of BIOS tick counter
    pop es
    
    ; Check if 18 ticks (~1 second) have passed
    sub ax, [last_tick]
    cmp ax, 18                  ; 18.2 ticks per second
    jb .skip_fps_update
    
    ; 1 second passed - update FPS display
    mov ax, [frame_count]
    mov [fps_display], ax
    mov word [frame_count], 0
    
    ; Save current tick as new reference
    push es
    mov ax, 0x0040
    mov es, ax
    mov ax, [es:0x006C]
    pop es
    mov [last_tick], ax
    
    call draw_fps               ; Draw FPS (only once per second)
    
.skip_fps_update:
    
    ; --------------------------------------------------------------------
    ; STEP 6: Check for keypress
    ; V = toggle VBlank sync, any other key = exit
    ; --------------------------------------------------------------------
    mov ah, 0x01
    int 0x16
    jz .main_loop
    
    ; Get the keypress
    mov ah, 0x00
    int 0x16
    
    ; Check for 'V' or 'v' to toggle VBlank
    cmp al, 'V'
    je .toggle_vsync
    cmp al, 'v'
    je .toggle_vsync
    jmp .exit_loop              ; Any other key exits
    
.toggle_vsync:
    xor byte [vsync_enabled], 1 ; Toggle 0<->1
    jmp .main_loop
    
.exit_loop:
    
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
;   - PAL: ~1.4ms VBlank period
;   - Bit 3 of PORT_STATUS = 1 during VBlank
;   - We first wait for VBlank to end (if currently in VBlank)
;   - Then wait for VBlank to start (fresh VBlank period)
;   - This ensures maximum time for our updates
; ============================================================================
wait_vblank:
    push ax
    push dx
    
    mov dx, PORT_STATUS
    
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
; update_image_position - Calculate new X,Y position using sine waves
;
; Uses two separate sine indices (X and Y) with different speeds to create
; a Lissajous-like motion pattern. The image oscillates around the center
; of the screen.
;
; OPTIMIZATION: Y position is forced to even values (2-pixel steps).
; This preserves bank alignment for fast interlaced copying.
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
    ; Sine value 0-100, we want -amplitude to +amplitude
    xor ah, ah
    mov si, ax
    mov al, [sine_table + si]   ; Get sine value (0-100, centered at 50)
    sub al, 50                  ; Now -50 to +50
    cbw                         ; Sign extend AL to AX
    
    ; Scale: AX * AMPLITUDE / 50
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
    and ax, 0xFFFE              ; Force Y to be even (2-pixel steps for bank alignment)
    mov [image_y], ax
    
    pop si
    pop bx
    pop ax
    ret

; ============================================================================
; copy_image_at_position - Copy partial image from RAM to VRAM at position
;
; SPEED TEST VERSION: Only copies 50 rows (1/4 of image) but positions them
; anywhere on screen based on image_x and image_y offsets.
;
; The 50-row section is drawn at screen position (image_x, dest_y) where
; dest_y is calculated to center the partial image based on image_y offset.
;
; RAM layout: Even rows at 0-7999, Odd rows at 8000-15999
; VRAM layout: Even rows at 0x0000, Odd rows at 0x2000
; ============================================================================

; ============================================================================
; delta_clear_and_draw - Optimized routine that minimizes flicker
;
; OPTIMIZATION: Instead of clear-all then draw-all (causes flicker), we:
;   1. Calculate the delta between old and new Y positions
;   2. Clear only the exposed rows (rows that won't be overwritten)
;   3. Draw the image at new position
;   4. Use block transfers with minimal loop overhead
;
; This eliminates the visible "gap" between clear and draw!
; ============================================================================
delta_clear_and_draw:
    pusha
    push es
    
    mov ax, VIDEO_SEG
    mov es, ax
    
    ; Get image X position for drawing
    mov ax, [image_x]
    sar ax, 1                   ; Convert pixels to bytes
    mov [temp_x_bytes], ax
    
    ; Calculate new Y position (same as before)
    mov ax, [image_y]
    add ax, (MAX_Y_POSITION / 2) ; Center position
    cmp ax, 0
    jge .not_neg
    xor ax, ax
.not_neg:
    cmp ax, MAX_Y_POSITION
    jle .not_too_high
    mov ax, MAX_Y_POSITION
.not_too_high:
    and ax, 0xFFFE              ; Force even for bank alignment
    mov [dest_y_start], ax
    
    ; Compare old and new positions
    mov bx, [prev_y_start]      ; BX = old Y
    mov cx, [dest_y_start]      ; CX = new Y
    
    cmp bx, cx
    je .same_position           ; No Y movement - just redraw for X changes
    jg .moving_up               ; Old > New means moving up
    
    ; --- MOVING DOWN: clear top rows, draw at new position ---
.moving_down:
    ; Clear rows from old_y to new_y (the exposed top rows)
    mov ax, bx                  ; AX = old_y (start of clear)
    mov dx, cx
    sub dx, bx                  ; DX = number of rows to clear (new - old)
    cmp dx, PARTIAL_HEIGHT
    jbe .clear_top_rows
    mov dx, PARTIAL_HEIGHT      ; Cap at 50 rows max
.clear_top_rows:
    call clear_rows_fast        ; Clear AX to AX+DX rows
    jmp .draw_image
    
.moving_up:
    ; --- MOVING UP: clear bottom rows, draw at new position ---
    ; Clear rows from (new_y + 50) to (old_y + 50) (the exposed bottom rows)
    mov ax, cx
    add ax, PARTIAL_HEIGHT      ; AX = new_y + 50 (start of clear)
    mov dx, bx
    sub dx, cx                  ; DX = number of rows to clear (old - new)
    cmp dx, PARTIAL_HEIGHT
    jbe .clear_bottom_rows
    mov dx, PARTIAL_HEIGHT      ; Cap at 50 rows max
.clear_bottom_rows:
    ; Clamp to screen bounds
    cmp ax, 200
    jb .do_clear_bottom
    jmp .draw_image             ; Already past screen edge
.do_clear_bottom:
    push ax
    add ax, dx
    cmp ax, 200
    jbe .bottom_ok
    mov dx, 200
    pop ax
    sub dx, ax                  ; Adjust count to not go past screen
    jmp .clear_bottom_exec
.bottom_ok:
    pop ax
.clear_bottom_exec:
    call clear_rows_fast
    jmp .draw_image
    
.same_position:
    ; No Y change - still need to draw for X offset changes
    
.draw_image:
    ; ===== OPTIMIZED DRAW: Use block copy with minimal overhead =====
    
    ; --- EVEN BANK ---
    mov ax, [dest_y_start]
    shr ax, 1                   ; row index in even bank
    mov bx, BYTES_PER_LINE
    mul bx
    mov di, ax                  ; DI = VRAM even bank start
    
    mov si, image_buffer        ; SI = RAM even bank start
    mov cx, PARTIAL_EVEN        ; 25 rows
    
.draw_even:
    push cx
    push di
    push si
    
    mov ax, [temp_x_bytes]
    call copy_row_with_offset_fast
    
    pop si
    add si, BYTES_PER_LINE      ; Next source row
    pop di
    add di, BYTES_PER_LINE      ; Next dest row
    pop cx
    loop .draw_even
    
    ; --- ODD BANK ---
    mov ax, [dest_y_start]
    inc ax
    shr ax, 1                   ; row index in odd bank
    mov bx, BYTES_PER_LINE
    mul bx
    add ax, 0x2000
    mov di, ax                  ; DI = VRAM odd bank start
    
    mov si, image_buffer + 8000 ; SI = RAM odd bank start
    mov cx, PARTIAL_ODD         ; 25 rows
    
.draw_odd:
    push cx
    push di
    push si
    
    mov ax, [temp_x_bytes]
    call copy_row_with_offset_fast
    
    pop si
    add si, BYTES_PER_LINE
    pop di
    add di, BYTES_PER_LINE
    pop cx
    loop .draw_odd
    
    pop es
    popa
    ret

; ============================================================================
; clear_rows_fast - Clear DX rows starting at row AX (optimized)
; Input: AX = starting row (0-199), DX = number of rows to clear
;        ES = VIDEO_SEG
; Uses REP STOSW for maximum speed
; ============================================================================
clear_rows_fast:
    push ax
    push bx
    push cx
    push dx
    push di
    
    or dx, dx
    jz .clear_done              ; Nothing to clear
    
    mov bx, dx                  ; BX = row count
    mov cx, ax                  ; CX = start row
    
.clear_row_loop:
    ; Calculate VRAM offset for this row
    mov ax, cx
    test ax, 1                  ; Odd or even row?
    jnz .clear_odd_row
    
    ; Even row: offset = (row/2) * 80
    shr ax, 1
    push cx
    mov cx, BYTES_PER_LINE
    mul cx
    pop cx
    mov di, ax
    jmp .do_clear
    
.clear_odd_row:
    ; Odd row: offset = 0x2000 + (row/2) * 80
    shr ax, 1
    push cx
    mov cx, BYTES_PER_LINE
    mul cx
    pop cx
    add ax, 0x2000
    mov di, ax
    
.do_clear:
    push cx
    mov cx, BYTES_PER_LINE / 2  ; 40 words
    xor ax, ax
    cld
    rep stosw
    pop cx
    
    inc cx                      ; Next row
    dec bx
    jnz .clear_row_loop
    
.clear_done:
    pop di
    pop dx
    pop cx
    pop bx
    pop ax
    ret

; ============================================================================
; copy_row_with_offset_fast - Optimized single row copy
; Input: SI = source, DI = dest, AX = X offset in bytes
;        ES = VIDEO_SEG
; Preserves: SI, DI (caller handles advancement)
; ============================================================================
copy_row_with_offset_fast:
    push bx
    push cx
    push si
    push di
    
    or ax, ax
    jz .fast_copy
    jg .fast_right
    
    ; Shift left
    neg ax
    cmp ax, BYTES_PER_LINE
    jge .fast_black
    
    mov bx, ax
    add si, bx                  ; Skip source bytes
    mov cx, BYTES_PER_LINE
    sub cx, bx
    cld
    rep movsb                   ; Copy visible portion
    mov cx, bx
    xor al, al
    rep stosb                   ; Fill right with black
    jmp .fast_done
    
.fast_right:
    cmp ax, BYTES_PER_LINE
    jge .fast_black
    
    mov bx, ax
    mov cx, bx
    xor al, al
    cld
    rep stosb                   ; Fill left with black
    mov cx, BYTES_PER_LINE
    sub cx, bx
    rep movsb                   ; Copy visible portion
    jmp .fast_done
    
.fast_copy:
    ; No offset - use word moves for speed
    mov cx, BYTES_PER_LINE / 2
    cld
    rep movsw
    jmp .fast_done
    
.fast_black:
    ; Entire row black
    mov cx, BYTES_PER_LINE / 2
    xor ax, ax
    cld
    rep stosw
    
.fast_done:
    pop di
    pop si
    pop cx
    pop bx
    ret

dest_y_start: dw 0              ; Destination Y position on screen
prev_y_start: dw 0              ; Previous Y position (for clearing)
temp_x_bytes: dw 0              ; X offset in bytes

; ============================================================================
; OLD ROUTINES - kept for reference but no longer used
; ============================================================================

; ----------------------------------------------------------------------------
; copy_row_with_offset - Copy one row from RAM to VRAM with X offset
; Input: SI = source row in RAM buffer (start of row)
;        DI = destination in VRAM (start of row)
;        AX = X offset in bytes (signed)
;        ES = VIDEO_SEG
; Output: DI advanced by BYTES_PER_LINE
; Clobbers: AX, CX, SI
;
; Handles three cases:
;   1. offset = 0: simple fast copy (REP MOVSW)
;   2. offset > 0: image shifts right, left edge filled with black
;   3. offset < 0: image shifts left, right edge filled with black
; ----------------------------------------------------------------------------
copy_row_with_offset:
    push bx
    push dx
    
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
    ; No offset - fast copy entire row using 16-bit moves
    mov cx, BYTES_PER_LINE / 2  ; 40 words
    cld
    rep movsw
    jmp .done
    
.all_black:
    ; Entire row is black (completely off-screen)
    mov cx, BYTES_PER_LINE / 2
    xor ax, ax
    cld
    rep stosw
    
.done:
    pop dx
    pop bx
    ret

; ============================================================================
; enable_graphics_mode - Enable 160x200x16 hidden graphics mode
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
; disable_graphics_mode - Reset to text mode
; ============================================================================
disable_graphics_mode:
    push ax
    push dx
    
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
; set_bmp_palette - Set all 16 palette entries from BMP file
; BMP palette: 64 bytes (16 colors × 4 bytes BGRA)
; V6355D palette: 32 bytes (16 colors × 2 bytes)
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
    
    ; Convert all 16 colors from BMP format to V6355D format
    mov si, bmp_header + 54     ; Palette starts at offset 54
    mov bp, 16                  ; BP = color counter (all 16 colors)
    
.palette_loop:
    ; BMP stores as: Blue, Green, Red, Alpha
    lodsb                       ; Blue
    mov bl, al
    lodsb                       ; Green
    mov bh, al
    lodsb                       ; Red (convert 8-bit to 3-bit)
    shr al, 5                   ; 80186 immediate shift
    
    mov dx, PORT_REG_DATA
    out dx, al                  ; Write Red byte
    jmp short $+2
    
    ; Combine Green and Blue
    mov al, bh                  ; Green
    and al, 0xE0                ; Keep upper 3 bits
    shr al, 1                   ; Shift to bits 4-6 (80186 immediate shift)
    mov ah, al                  ; Save green component
    mov al, bl                  ; Blue
    shr al, 5                   ; Convert to 3-bit (80186 immediate shift)
    or al, ah                   ; Combine: Green (4-6) | Blue (0-2)
    out dx, al                  ; Write Green|Blue byte
    jmp short $+2
    
    lodsb                       ; Skip alpha
    dec bp
    jnz .palette_loop
    
    ; Disable palette write mode
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
    mov al, 0x40                ; Enable palette write, start at color 0
    out dx, al
    jmp short $+2
    
    mov dx, PORT_REG_DATA
    xor al, al                  ; 0x00 = red byte (R=0)
    out dx, al
    jmp short $+2
    
    xor al, al                  ; 0x00 = green/blue byte (G=0, B=0)
    out dx, al
    jmp short $+2
    
    mov dx, PORT_REG_ADDR
    mov al, 0x80                ; Disable palette write
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
; This allows fast block copies during scrolling.
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
    shr al, 4                   ; P2 now in low nibble (80186 immediate shift)
    or al, ah                   ; AL = P0:P2 (dropped P1, P3)
    stosb                       ; Store to RAM buffer (ES:DI)
    
    ; C64-style: change border every 8 bytes (loading effect)
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
    
    ; C64-style: change border every 8 bytes (loading effect)
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
    ; Reset border to black
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
; UNUSED: copy_image_to_vram - Copy entire RAM buffer to VRAM
;
; Copies all 200 rows at once. Not used in this demo because
; delta_clear_and_draw only copies PARTIAL_HEIGHT rows per frame.
; Kept for reference - useful for static image display.
;
; RAM layout: Even rows at 0-7999, Odd rows at 8000-15999
; VRAM layout: Even rows at 0x0000-0x1F3F, Odd rows at 0x2000-0x3F3F
; ============================================================================
copy_image_to_vram:
    pusha                       ; 80186 PUSHA
    push es
    
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

msg_info    db 'DEMO6 v1.1 - C64-Style Wobble Demo for Olivetti PC1', 0x0D, 0x0A
            db 'Pans 50-row image section with sine-wave motion.', 0x0D, 0x0A
            db 'Uses delta-clearing for flicker-free animation.', 0x0D, 0x0A
            db 0x0D, 0x0A
            db 'Usage: DEMO6 filename.bmp', 0x0D, 0x0A
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

; Image scroll animation state
image_x         dw 0            ; Current image X position (signed)
image_y         dw 0            ; Current image Y position (signed, always even)
image_sine_x    db 0            ; X sine table index
image_sine_y    db 0            ; Y sine table index
vsync_enabled   db 1            ; 1 = VBlank sync ON, 0 = free-running (press V to toggle)

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
; EMBEDDED 8x8 FONT - Digits 0-9 and comma (no scaling, native 8x8)
; ============================================================================

; Font bitmaps - 8 bytes per character (8x8 pixels)
font_0:
    db 0x3C  ; ..####..
    db 0x66  ; .##..##.
    db 0x6E  ; .##.###.
    db 0x76  ; .###.##.
    db 0x66  ; .##..##.
    db 0x66  ; .##..##.
    db 0x3C  ; ..####..
    db 0x00  ; ........

font_1:
    db 0x18  ; ...##...
    db 0x38  ; ..###...
    db 0x18  ; ...##...
    db 0x18  ; ...##...
    db 0x18  ; ...##...
    db 0x18  ; ...##...
    db 0x7E  ; .######.
    db 0x00  ; ........

font_2:
    db 0x3C  ; ..####..
    db 0x66  ; .##..##.
    db 0x06  ; .....##.
    db 0x0C  ; ....##..
    db 0x18  ; ...##...
    db 0x30  ; ..##....
    db 0x7E  ; .######.
    db 0x00  ; ........

font_3:
    db 0x3C  ; ..####..
    db 0x66  ; .##..##.
    db 0x06  ; .....##.
    db 0x1C  ; ...###..
    db 0x06  ; .....##.
    db 0x66  ; .##..##.
    db 0x3C  ; ..####..
    db 0x00  ; ........

font_4:
    db 0x0C  ; ....##..
    db 0x1C  ; ...###..
    db 0x3C  ; ..####..
    db 0x6C  ; .##.##..
    db 0x7E  ; .######.
    db 0x0C  ; ....##..
    db 0x0C  ; ....##..
    db 0x00  ; ........

font_5:
    db 0x7E  ; .######.
    db 0x60  ; .##.....
    db 0x7C  ; .#####..
    db 0x06  ; .....##.
    db 0x06  ; .....##.
    db 0x66  ; .##..##.
    db 0x3C  ; ..####..
    db 0x00  ; ........

font_6:
    db 0x1C  ; ...###..
    db 0x30  ; ..##....
    db 0x60  ; .##.....
    db 0x7C  ; .#####..
    db 0x66  ; .##..##.
    db 0x66  ; .##..##.
    db 0x3C  ; ..####..
    db 0x00  ; ........

font_7:
    db 0x7E  ; .######.
    db 0x06  ; .....##.
    db 0x0C  ; ....##..
    db 0x18  ; ...##...
    db 0x18  ; ...##...
    db 0x18  ; ...##...
    db 0x18  ; ...##...
    db 0x00  ; ........

font_8:
    db 0x3C  ; ..####..
    db 0x66  ; .##..##.
    db 0x66  ; .##..##.
    db 0x3C  ; ..####..
    db 0x66  ; .##..##.
    db 0x66  ; .##..##.
    db 0x3C  ; ..####..
    db 0x00  ; ........

font_9:
    db 0x3C  ; ..####..
    db 0x66  ; .##..##.
    db 0x66  ; .##..##.
    db 0x3E  ; ..#####.
    db 0x06  ; .....##.
    db 0x0C  ; ....##..
    db 0x38  ; ..###...
    db 0x00  ; ........

font_comma:
    db 0x00  ; ........
    db 0x00  ; ........
    db 0x00  ; ........
    db 0x00  ; ........
    db 0x00  ; ........
    db 0x18  ; ...##...
    db 0x18  ; ...##...
    db 0x30  ; ..##....

; UNUSED: Table for draw_demo6_text (draws "0,1,2,3,4,5,6,7,8,9" string)
char_table:
    dw font_0
    dw font_comma
    dw font_1
    dw font_comma
    dw font_2
    dw font_comma
    dw font_3
    dw font_comma
    dw font_4
    dw font_comma
    dw font_5
    dw font_comma
    dw font_6
    dw font_comma
    dw font_7
    dw font_comma
    dw font_8
    dw font_comma
    dw font_9
char_count_total equ 19

; ============================================================================
; find_brightest_color - Scan BMP palette to find the lightest color
; The BMP palette is at bmp_header+54, format: B,G,R,A for each of 16 colors
; Stores the color index (0-15) in text_color variable
; ============================================================================
find_brightest_color:
    pusha
    
    mov si, bmp_header + 54     ; Palette starts at offset 54
    xor bx, bx                  ; BX = current color index
    xor dx, dx                  ; DX = best brightness found so far
    mov byte [text_color], 1    ; Default to color 1 (avoid 0 which is black)
    
.check_loop:
    ; Skip color 0 (that's our background black)
    or bx, bx
    jz .next_color
    
    ; Calculate brightness = R + G + B
    xor ax, ax
    mov al, [si]                ; Blue
    mov cx, ax
    mov al, [si+1]              ; Green
    add cx, ax
    mov al, [si+2]              ; Red
    add cx, ax                  ; CX = total brightness
    
    ; Is this brighter than what we've found?
    cmp cx, dx
    jbe .next_color
    
    ; Yes! Save this as the brightest
    mov dx, cx
    mov [text_color], bl        ; Store color index
    
.next_color:
    add si, 4                   ; Next palette entry (4 bytes: BGRA)
    inc bx
    cmp bx, 16
    jb .check_loop
    
    ; Build the text byte pattern (both nibbles = same color)
    ; For example, if brightest is color 7, pattern = 0x77
    mov al, [text_color]
    mov ah, al
    shl ah, 4                   ; High nibble
    or al, ah                   ; AL = 0xCC where C is color
    mov [text_byte], al
    
    popa
    ret

text_color: db 15               ; Brightest color index (default 15)
text_byte:  db 0xFF             ; Byte pattern for two pixels of text color

; ============================================================================
; UNUSED: draw_demo6_text - Draw "0,1,2,3,4,5,6,7,8,9" test string
; Position: X=2, Y=190 (bottom left)
; Uses brightest color found in palette
; Kept for reference - could be repurposed for other text display
; ============================================================================
draw_demo6_text:
    pusha
    push es
    
    ; ES = video segment for VRAM writes
    mov ax, VIDEO_SEG
    mov es, ax
    
    ; Initialize text position and character counter
    mov word [text_x], 1        ; Start X (byte offset = 2 pixels from left edge)
    mov byte [char_count], char_count_total
    mov bx, char_table          ; BX points to font address table
    
.char_loop:
    ; Get font address from table
    mov si, [bx]                ; SI = font data address
    add bx, 2                   ; Advance table pointer
    mov [table_ptr], bx         ; Save table position
    
    ; Draw 8 font rows
    mov word [cur_y], 190       ; Starting Y row (190 + 8 = 198, leaves 2 row margin)
    mov byte [row_count], 8     ; 8 rows per character
    
.row_loop:
    ; Read font byte
    lodsb                       ; AL = 8-bit pattern for this row
    mov [font_byte], al
    mov [font_ptr_save], si     ; Save font position
    
    ; Calculate VRAM offset for current scanline
    mov ax, [cur_y]             ; AX = Y coordinate
    test ax, 1
    jnz .odd_row
    
    ; Even row: offset = (row/2) * 80 + x
    shr ax, 1
    mov cx, BYTES_PER_LINE
    mul cx
    add ax, [text_x]
    mov di, ax
    jmp .render_row
    
.odd_row:
    ; Odd row: offset = 0x2000 + (row/2) * 80 + x
    shr ax, 1
    mov cx, BYTES_PER_LINE
    mul cx
    add ax, 0x2000
    add ax, [text_x]
    mov di, ax
    
.render_row:
    ; Convert 8-bit bitmask to 8 pixels (4 bytes output)
    mov al, [font_byte]
    mov cl, [text_color]        ; CL = color for lit pixels
    
    ; Byte 0: bits 7,6 -> pixels 0,1
    xor ah, ah
    test al, 0x80
    jz .p0_done
    mov ah, cl
    shl ah, 4
.p0_done:
    test al, 0x40
    jz .p1_done
    or ah, cl
.p1_done:
    mov [es:di], ah
    
    ; Byte 1: bits 5,4 -> pixels 2,3
    xor ah, ah
    test al, 0x20
    jz .p2_done
    mov ah, cl
    shl ah, 4
.p2_done:
    test al, 0x10
    jz .p3_done
    or ah, cl
.p3_done:
    mov [es:di+1], ah
    
    ; Byte 2: bits 3,2 -> pixels 4,5
    xor ah, ah
    test al, 0x08
    jz .p4_done
    mov ah, cl
    shl ah, 4
.p4_done:
    test al, 0x04
    jz .p5_done
    or ah, cl
.p5_done:
    mov [es:di+2], ah
    
    ; Byte 3: bits 1,0 -> pixels 6,7
    xor ah, ah
    test al, 0x02
    jz .p6_done
    mov ah, cl
    shl ah, 4
.p6_done:
    test al, 0x01
    jz .p7_done
    or ah, cl
.p7_done:
    mov [es:di+3], ah
    
    ; Move to next Y row
    inc word [cur_y]
    
    ; Restore font pointer and continue to next font row
    mov si, [font_ptr_save]
    dec byte [row_count]
    jnz .row_loop
    
    ; Move to next character (8 pixels = 4 bytes)
    add word [text_x], 4        ; 4 bytes for char (no gap - comma provides spacing)
    
    mov bx, [table_ptr]         ; Restore table pointer
    dec byte [char_count]
    jnz .char_loop
    
    pop es
    popa
    ret

; Variables for text drawing
text_x:         dw 0            ; Current X position (byte offset)
char_count:     db 0            ; Characters remaining
table_ptr:      dw 0            ; Position in font table
row_count:      db 0            ; Font rows remaining (8)
font_byte:      db 0            ; Current font bitmask byte
font_ptr_save:  dw 0            ; Saved font pointer
cur_y:          dw 0            ; Current Y coordinate

; FPS counter variables
frame_count:    dw 0            ; Frames counted this second
last_tick:      dw 0            ; BIOS tick at start of current second
fps_display:    dw 0            ; Last FPS value to display

; ============================================================================
; draw_fps - Draw FPS counter in bottom-left corner
; Displays 2 digits (00-99) using fps_display value
; Position: X=1 (left side), Y=190 (bottom)
; ============================================================================
draw_fps:
    pusha
    push es
    
    mov ax, VIDEO_SEG
    mov es, ax
    
    ; Convert fps_display to 2 digits
    mov ax, [fps_display]
    cmp ax, 99                  ; Cap at 99
    jbe .cap_ok
    mov ax, 99
.cap_ok:
    
    ; Divide by 10 to get tens digit
    xor dx, dx
    mov bx, 10
    div bx                      ; AX = tens, DX = ones
    mov [fps_tens], al
    mov [fps_ones], dl
    
    ; Draw tens digit at X=1 (byte offset), Y=190
    mov word [text_x], 1
    mov word [cur_y], 190
    
    ; Get font address for tens digit
    xor bx, bx
    mov bl, [fps_tens]
    shl bx, 1                   ; BX = digit * 2 (word offset)
    add bx, fps_font_table
    mov si, [bx]                ; SI = font data
    
    call draw_single_char
    
    ; Draw ones digit at X=5, Y=190
    mov word [text_x], 5
    mov word [cur_y], 190
    
    xor bx, bx
    mov bl, [fps_ones]
    shl bx, 1
    add bx, fps_font_table
    mov si, [bx]
    
    call draw_single_char
    
    pop es
    popa
    ret

fps_tens: db 0
fps_ones: db 0

; Font lookup table for digits 0-9 (reuses existing font data)
fps_font_table:
    dw font_0
    dw font_1
    dw font_2
    dw font_3
    dw font_4
    dw font_5
    dw font_6
    dw font_7
    dw font_8
    dw font_9

; ============================================================================
; draw_single_char - Draw one 8x8 character at text_x, cur_y
; Input: SI = pointer to font data (8 bytes)
; Uses: text_x, cur_y, text_color
; ============================================================================
draw_single_char:
    push ax
    push bx
    push cx
    push dx
    push di
    
    mov byte [row_count], 8
    
.row_loop:
    lodsb                       ; AL = font byte
    mov [font_byte], al
    mov [font_ptr_save], si
    
    ; Calculate VRAM offset
    mov ax, [cur_y]
    test ax, 1
    jnz .odd_row
    
    shr ax, 1
    mov cx, BYTES_PER_LINE
    mul cx
    add ax, [text_x]
    mov di, ax
    jmp .render
    
.odd_row:
    shr ax, 1
    mov cx, BYTES_PER_LINE
    mul cx
    add ax, 0x2000
    add ax, [text_x]
    mov di, ax
    
.render:
    mov al, [font_byte]
    mov cl, [text_color]
    
    ; Byte 0: bits 7,6
    xor ah, ah
    test al, 0x80
    jz .r0
    mov ah, cl
    shl ah, 4
.r0:
    test al, 0x40
    jz .r1
    or ah, cl
.r1:
    mov [es:di], ah
    
    ; Byte 1: bits 5,4
    xor ah, ah
    test al, 0x20
    jz .r2
    mov ah, cl
    shl ah, 4
.r2:
    test al, 0x10
    jz .r3
    or ah, cl
.r3:
    mov [es:di+1], ah
    
    ; Byte 2: bits 3,2
    xor ah, ah
    test al, 0x08
    jz .r4
    mov ah, cl
    shl ah, 4
.r4:
    test al, 0x04
    jz .r5
    or ah, cl
.r5:
    mov [es:di+2], ah
    
    ; Byte 3: bits 1,0
    xor ah, ah
    test al, 0x02
    jz .r6
    mov ah, cl
    shl ah, 4
.r6:
    test al, 0x01
    jz .r7
    or ah, cl
.r7:
    mov [es:di+3], ah
    
    inc word [cur_y]
    mov si, [font_ptr_save]
    dec byte [row_count]
    jnz .row_loop
    
    pop di
    pop dx
    pop cx
    pop bx
    pop ax
    ret

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
; Master copy of the decoded BMP image in INTERLACED format.
; Layout matches VRAM for fast block copies:
;   - Bytes 0-7999: Even rows (0,2,4...198) - 100 rows × 80 bytes
;   - Bytes 8000-15999: Odd rows (1,3,5...199) - 100 rows × 80 bytes
;
; With Y scroll always in 2-pixel steps, bank alignment is preserved,
; allowing significant speedup compared to row-by-row copying.
; ============================================================================
image_buffer:   times IMAGE_SIZE db 0

; ============================================================================
; End of Program
; ============================================================================
