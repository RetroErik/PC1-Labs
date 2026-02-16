; ============================================================================
; DEMO5A.ASM - Scrolling BMP Image Demo
; Olivetti Prodest PC1 - V6355D 160x200x16 Hidden Graphics Mode
; Written for NASM - NEC V40 @ 8 MHz (80186 instruction set)
; By RetroErik - 2026 with GitHub Copilot
;
; Description:
;   Loads a 4-bit BMP image and scrolls/pans it around the screen using
;   sine-wave motion to create a smooth Lissajous pattern effect.
;
; ============================================================================
; OPTIMIZATION TECHNIQUES USED
; ============================================================================
;
; 1. INTERLACED RAM BUFFER (major speedup)
;    - RAM buffer layout mirrors VRAM's CGA interlacing
;    - Even rows at bytes 0-7999, odd rows at bytes 8000-15999
;    - Allows bulk bank-to-bank copies instead of row-by-row
;
; 2. 2-PIXEL Y MOVEMENT STEPS
;    - Y scroll always moves in 2-pixel increments
;    - Preserves bank alignment (even row stays even, odd stays odd)
;    - Enables fast block copies without per-row bank calculations
;
; 3. 80186 INSTRUCTIONS (CPU 186 directive)
;    - PUSHA/POPA for fast register save/restore
;    - Immediate operand shifts (shr al, 4 instead of loop)
;    - These are native on the NEC V40 processor
;
; 4. REP MOVSW FOR BLOCK TRANSFERS
;    - Uses 16-bit word moves instead of byte moves where possible
;    - Minimizes loop overhead for large transfers
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
; VBlank Timing
; ============================================================================
;
;   - All VRAM updates occur during VBlank (bit 3 of PORT_STATUS)
;   - VBlank is ~1.4ms on PAL timing
;   - Image copy extends past VBlank (some tearing visible)
;   - Future optimization: delta updates or hardware scroll
;
; Usage: DEMO5A filename.bmp
;        Press any key to exit
;
; See also:
;   demo5b - Same scroller with LINEAR RAM buffer (simpler but slower)
;   demo5c - Same scroller with INTERLACED RAM buffer (this approach)
;   The two variants allow comparing RAM layout strategies.
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

; BMP File Header offsets
BMP_SIGNATURE   equ 0           ; 'BM' signature (2 bytes)
BMP_DATA_OFFSET equ 10          ; Offset to pixel data (dword)
BMP_WIDTH       equ 18          ; Image width (dword)
BMP_HEIGHT      equ 22          ; Image height (dword)
BMP_BPP         equ 28          ; Bits per pixel (word)
BMP_COMPRESSION equ 30          ; Compression (dword, 0=none)

; ============================================================================
; IMAGE SCROLL CONFIGURATION
; ============================================================================
; The image scrolls/pans around the screen using sine wave motion.
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
    
    ; Copy entire image from RAM buffer to VRAM
    call copy_image_to_vram
    
    ; Initialize image scroll state
    mov byte [image_sine_x], IMAGE_X_PHASE
    mov byte [image_sine_y], IMAGE_Y_PHASE
    mov word [image_x], 0
    mov word [image_y], 0
    
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
    ; STEP 1: Wait for VBlank start
    ; VBlank is the safe window for VRAM updates (~1.4ms on PAL)
    ; Bit 3 of PORT_STATUS = 1 during vertical blanking
    ; --------------------------------------------------------------------
    call wait_vblank
    
    ; --------------------------------------------------------------------
    ; STEP 2: Update image position using sine wave
    ; Calculates new X,Y position for the scrolling image
    ; Uses Lissajous pattern (different X/Y speeds + phase offset)
    ; --------------------------------------------------------------------
    call update_image_position
    
    ; --------------------------------------------------------------------
    ; STEP 3: Copy image to VRAM at new position
    ; Copies the entire 16KB image from interlaced RAM buffer to VRAM.
    ; Uses bank-aligned block copies for speed.
    ; Note: This extends past VBlank, causing some visible tearing.
    ; --------------------------------------------------------------------
    call copy_image_at_position
    
    ; --------------------------------------------------------------------
    ; STEP 4: Check for keypress (exit on any key)
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
; copy_image_at_position - Copy image from RAM to VRAM at offset position
;
; OPTIMIZATION: Uses interlaced RAM buffer with 2-pixel Y steps.
; Since Y is always even, source bank alignment matches destination.
; This allows processing even/odd banks separately with simpler math.
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
    pusha                       ; 80186 PUSHA - save all registers
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
    
    xor di, di                  ; DI = VRAM even bank start
    xor dx, dx                  ; DX = current screen row (even: 0,2,4...)
    
.even_loop:
    ; Calculate source row index in even bank
    mov ax, dx                  ; AX = screen row (0,2,4...)
    shr ax, 1                   ; AX = screen row / 2 (0,1,2...)
    sub ax, bp                  ; AX = source row index in even bank
    
    ; Check bounds (0-99 valid for 100 even rows)
    cmp ax, 0
    jl .even_black
    cmp ax, 100
    jge .even_black
    
    ; Valid row - calculate source offset
    push dx
    mov dx, BYTES_PER_LINE
    imul dx                     ; AX = row_index * 80
    mov si, image_buffer
    add si, ax                  ; SI = source in even bank
    pop dx
    
    ; Copy with X offset applied
    mov ax, [temp_x_bytes]
    call copy_row_with_offset
    jmp .even_next
    
.even_black:
    ; Fill row with black (out of bounds)
    push di
    mov cx, BYTES_PER_LINE / 2
    xor ax, ax
    cld
    rep stosw
    pop di
    add di, BYTES_PER_LINE
    
.even_next:
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
    cmp ax, 100
    jge .odd_black
    
    ; Valid row - calculate source offset (odd bank starts at 8000)
    push dx
    mov dx, BYTES_PER_LINE
    imul dx                     ; AX = row_index * 80
    mov si, image_buffer + 8000 ; Odd bank base
    add si, ax                  ; SI = source in odd bank
    pop dx
    
    ; Copy with X offset applied
    mov ax, [temp_x_bytes]
    call copy_row_with_offset
    jmp .odd_next
    
.odd_black:
    ; Fill row with black (out of bounds)
    push di
    mov cx, BYTES_PER_LINE / 2
    xor ax, ax
    cld
    rep stosw
    pop di
    add di, BYTES_PER_LINE
    
.odd_next:
    add dx, 2                   ; Next odd screen row
    cmp dx, 200
    jb .odd_loop
    
    pop es
    popa                        ; 80186 POPA - restore all registers
    ret

; Temporary storage for X offset in bytes
temp_x_bytes: dw 0

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
; copy_image_to_vram - Copy entire RAM buffer to VRAM using REP MOVSW
;
; OPTIMIZATION: RAM buffer is interlaced to match VRAM layout.
; This allows two large block copies instead of 200 row copies!
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

msg_info    db 'DEMO5A - Scrolling BMP Image for Olivetti PC1', 0x0D, 0x0A
            db 'Scrolls BMP image with smooth sine-wave motion.', 0x0D, 0x0A
            db 0x0D, 0x0A
            db 'Usage: DEMO5A filename.bmp', 0x0D, 0x0A
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
