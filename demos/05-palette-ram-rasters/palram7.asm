; ============================================================================
; PALRAM7.ASM - BMP Image with Palette RAM Raster Bar Overlay
; Loads a BMP image, then displays dancing palette RAM raster bars on top
; Written for NASM - NEC V40 (80186 compatible) @ 8 MHz
; By Retro Erik - 2026 with help from GitHub Copilot
;
; Target: Olivetti PC1 with Yamaha V6355D video controller
; Video Mode: CGA 160x200x16 (Hidden mode)
;
; Technique:
;   Phase 1: Load BMP image (screen blanked during load)
;   Phase 2: Display raster bars on top via Palette RAM per scanline
;   - Two bars with sine-wave wobble motion
;   - Bars swap depth order when crossing for 3D "dancing" illusion
;   - Unlike PORT_COLOR bars (demo1), palette RAM bars change what
;     color 0 actually looks like, so the bars "shine through" all
;     background (color 0) pixels in the image
;
; ============================================================================
; PALETTE RAM vs PORT_COLOR RASTER BARS
; ============================================================================
;
; demo1.asm uses PORT_COLOR (0xD9) to set the overscan/border color per
; scanline. PORT_COLOR only affects the border area and becomes unreliable
; during active display with non-zero pixels. The raster bars only really
; show on the border and on fully blank scanlines.
;
; This demo uses Palette RAM (0xDD/0xDE) to redefine palette entry 0's
; actual RGB values per scanline. This means:
;   - Any pixel using color 0 will show the raster bar color
;   - All other colors (1-15) remain unchanged from the BMP palette
;   - The bars "shine through" wherever the image has background (color 0)
;   - RGB333 format gives 512 possible colors (vs 16 palette indices)
;
; The trade-off: 4 OUTs per scanline (open + R + G|B + close) instead of 1,
; but still fits comfortably within the ~80-cycle HBLANK window.
;
; ============================================================================
; TIMING ANALYSIS
; ============================================================================
;
; Per-scanline palette write sequence during HBLANK (OUTSB burst):
;   outsb            ; 14 cycles -  OUT 0xDD, 0x40 (open palette, entry 0)
;   inc dx           ; 3 cycles  -  DX = 0xDE (PORT_REG_DATA)
;   outsb            ; 14 cycles -  OUT 0xDE, R byte
;   outsb            ; 14 cycles -  OUT 0xDE, G|B byte
;   dec dx           ; 3 cycles  -  DX = 0xDD (PORT_REG_ADDR)
;   mov al, 0x80     ; 4 cycles  -  Prepare close command
;   out dx, al       ; 8 cycles  -  Close IMMEDIATELY (palram6 finding)
;                   -----------
;   Total:           ~60 cycles  (comfortably within ~80 cycle HBLANK)
;
; CRITICAL: Close palette mode (0x80) IMMEDIATELY after last data byte!
; Delays before close cause palette "bleed" to adjacent entries (palram6).
;
; ============================================================================
;
; Usage: PALRAM7 image.bmp
;        Any key - Exit to DOS
;
; Prerequisites:
;   Run PERITEL.COM first to set horizontal position correctly
; ============================================================================

[BITS 16]
[CPU 186]                       ; NEC V40 is 80186 compatible (enables OUTSB)
[ORG 0x100]

; ============================================================================
; Constants - Hardware definitions
; ============================================================================
VIDEO_SEG       equ 0xB000      ; PC1 video RAM segment

; Yamaha V6355D I/O Ports (aliased from 0x3Dx to 0xDx on PC1)
PORT_REG_ADDR   equ 0xDD        ; Register address port (palette open/close)
PORT_REG_DATA   equ 0xDE        ; Register data port (palette R, G|B values)
PORT_MODE       equ 0xD8        ; Mode control register
PORT_COLOR      equ 0xD9        ; Color select (border/overscan color)
PORT_STATUS     equ 0xDA        ; Status (bit 0=hsync, bit 3=vblank)

; BMP File Header offsets
BMP_SIGNATURE   equ 0           ; 'BM' signature (2 bytes)
BMP_DATA_OFFSET equ 10          ; Offset to pixel data (dword)
BMP_WIDTH       equ 18          ; Image width (dword)
BMP_HEIGHT      equ 22          ; Image height (dword)
BMP_BPP         equ 28          ; Bits per pixel (word)
BMP_COMPRESSION equ 30          ; Compression (dword, 0=none)

; Screen parameters
SCREEN_WIDTH    equ 160
SCREEN_HEIGHT   equ 200
SCREEN_SIZE     equ 16384       ; Full video RAM (16KB)

; ============================================================================
; RASTER BAR CONFIGURATION - Adjust these values to customize appearance
; ============================================================================

LINES_PER_COLOR equ 2           ; Scanlines per gradient color (1=thin, 3=thick)
BAR_HEIGHT      equ 14 * LINES_PER_COLOR  ; Total bar height (7 colors × 2 directions)

; Per-bar speed (higher = faster wobble)
BAR1_SPEED      equ 2           ; Bar 1 sine index increment per frame
BAR2_SPEED      equ 3           ; Bar 2 sine index increment per frame

; Per-bar center position (Y coordinate on screen)
BAR1_CENTER     equ 100         ; Bar 1 oscillates around this Y position
BAR2_CENTER     equ 100         ; Bar 2 oscillates around this Y position (same = crossing!)

; Per-bar starting phase (0-255, controls where in sine wave each bar starts)
BAR1_PHASE      equ 0           ; Bar 1 starts at sine position 0
BAR2_PHASE      equ 85          ; Bar 2 starts 1/3 cycle offset (120 degrees)

; Shared amplitude (affects wobble range for both bars)
SINE_AMPLITUDE  equ 50          ; Maximum distance from center

; ============================================================================
; Main Program Entry Point
; ============================================================================
main:
    ; Parse command line for filename
    mov si, 0x81            ; Command line starts at PSP:0081

.skip_spaces:
    lodsb
    cmp al, ' '
    je .skip_spaces
    cmp al, 0x0D            ; End of command line?
    je .show_usage

    ; Check for /? or /h
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

.find_end:
    lodsb
    cmp al, ' '
    je .found_end
    cmp al, 0x0D
    jne .find_end

.found_end:
    dec si
    mov byte [si], 0        ; Null-terminate filename
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
    mov ax, 0x3D00          ; DOS Open File (read-only)
    int 0x21
    jc .file_error
    mov [file_handle], ax

    ; Read BMP header + palette (118 bytes)
    mov bx, ax
    mov dx, bmp_header
    mov cx, 118
    mov ah, 0x3F            ; DOS Read File
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

    ; Seek to pixel data
    mov bx, [file_handle]
    mov dx, [bmp_header + BMP_DATA_OFFSET]
    mov cx, [bmp_header + BMP_DATA_OFFSET + 2]
    mov ax, 0x4200
    int 0x21
    jc .file_error

    ; ========================================================================
    ; PHASE 1: Load and display BMP image
    ; ========================================================================

    ; Enable graphics mode with video blanked during loading
    call enable_graphics_mode
    mov al, 0x42            ; Graphics mode, video OFF
    out PORT_MODE, al

    ; Clear screen
    call clear_screen

    ; Save BMP's original color 0 for non-bar scanlines
    call save_color0

    ; Set palette from BMP
    call set_bmp_palette

    ; Display BMP image
    call decode_bmp

    ; Close file
    mov bx, [file_handle]
    mov ah, 0x3E
    int 0x21

    ; Reset border to black
    xor al, al
    out PORT_COLOR, al

    ; Enable video - image appears!
    mov al, 0x4A            ; Graphics mode, video ON
    out PORT_MODE, al

    ; Initialize bar sine indices with starting phases
    mov byte [bar1_sine_idx], BAR1_PHASE
    mov byte [bar2_sine_idx], BAR2_PHASE

    ; ========================================================================
    ; PHASE 2: Palette RAM raster bar animation loop
    ; ========================================================================
.main_loop:
    ; Update bar 1 sine index and calculate Y position
    add byte [bar1_sine_idx], BAR1_SPEED
    mov al, [bar1_sine_idx]
    xor ah, ah
    mov si, ax
    mov al, [sine_table + si]       ; Get sine value (0-100)
    add al, BAR1_CENTER
    sub al, SINE_AMPLITUDE
    mov [bar1_y], al

    ; Update bar 2 sine index and calculate Y position
    add byte [bar2_sine_idx], BAR2_SPEED
    mov al, [bar2_sine_idx]
    xor ah, ah
    mov si, ax
    mov al, [sine_table + si]
    add al, BAR2_CENTER
    sub al, SINE_AMPLITUDE
    mov [bar2_y], al

    ; Detect crossing for 3D effect
    mov al, [bar1_y]
    cmp al, [bar2_y]
    jae .bar1_in_front
    mov byte [front_bar], 0         ; Cyan in front
    jmp .build_table
.bar1_in_front:
    mov byte [front_bar], 1         ; Red in front

.build_table:
    ; Build scanline table BEFORE waiting - we have time during display
    call build_scanline_table

    ; Now wait for vblank to end (display starts) and immediately render
    call wait_vblank
    call render_raster_bars

    ; Check for keypress
    mov ah, 0x01
    int 0x16
    jz .main_loop

    ; Exit - consume key
    mov ah, 0x00
    int 0x16

    ; Restore CGA palette for clean text mode transition
    call set_cga_palette

    ; Restore text mode
    mov ax, 0x0003
    int 0x10

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
; build_scanline_table - Pre-compute palette RGB pairs for all 200 scanlines
; Each entry is 2 bytes: R, G|B (V6355D palette format)
; Non-bar scanlines get the BMP's original color 0 value
; ============================================================================
build_scanline_table:
    push ax
    push bx
    push cx
    push di

    ; Fill table with BMP's original color 0 (no bar = show image normally)
    mov di, scanline_colors
    mov al, [orig_color0_r]
    mov ah, [orig_color0_gb]
    mov cx, SCREEN_HEIGHT
.clear_loop:
    mov [di], ax            ; Write R at [di], G|B at [di+1] (little-endian)
    add di, 2
    loop .clear_loop

    ; Check which bar should be in front (drawn last = on top)
    cmp byte [front_bar], 0
    jnz .red_in_front

    ; Cyan in front: draw red first, then cyan on top
    call draw_red_bar
    call draw_cyan_bar
    jmp .done_drawing

.red_in_front:
    call draw_cyan_bar
    call draw_red_bar

.done_drawing:
    pop di
    pop cx
    pop bx
    pop ax
    ret

; ----------------------------------------------------------------------------
; draw_red_bar - Draw bar 1 (red gradient) into scanline table
; RGB333 gradient: R=1→7→1, G=0, B=0
; ----------------------------------------------------------------------------
draw_red_bar:
    push ax
    push bx
    push cx
    push si

    mov al, [bar1_y]
    xor ah, ah
    mov bx, ax
    shl bx, 1              ; BX = Y × 2 (2 bytes per entry)
    mov si, red_gradient
    mov cx, BAR_HEIGHT

.draw_loop:
    cmp bx, SCREEN_HEIGHT * 2
    jb .in_range
    sub bx, SCREEN_HEIGHT * 2
.in_range:
    mov ax, [si]            ; Load R and G|B as word
    mov [scanline_colors + bx], ax
    add bx, 2
    add si, 2
    loop .draw_loop

    pop si
    pop cx
    pop bx
    pop ax
    ret

; ----------------------------------------------------------------------------
; draw_cyan_bar - Draw bar 2 (cyan gradient) into scanline table
; RGB333 gradient: R=0, G=1→7→1, B=1→7→1
; ----------------------------------------------------------------------------
draw_cyan_bar:
    push ax
    push bx
    push cx
    push si

    mov al, [bar2_y]
    xor ah, ah
    mov bx, ax
    shl bx, 1              ; BX = Y × 2 (2 bytes per entry)
    mov si, cyan_gradient
    mov cx, BAR_HEIGHT

.draw_loop:
    cmp bx, SCREEN_HEIGHT * 2
    jb .in_range
    sub bx, SCREEN_HEIGHT * 2
.in_range:
    mov ax, [si]            ; Load R and G|B as word
    mov [scanline_colors + bx], ax
    add bx, 2
    add si, 2
    loop .draw_loop

    pop si
    pop cx
    pop bx
    pop ax
    ret

; ============================================================================
; render_raster_bars - Per-scanline palette RAM changes via OUTSB
;
; Optimized register plan:
;   DX = PORT_REG_ADDR (0xDD) permanently, used by OUTSB and close-write
;   SI = scanline_colors pointer (swapped to pal_cmd only for OUTSB burst)
;   BH/BL = previously written R/GB bytes (skip write if unchanged)
;   CX = line counter
;   Status polling via immediate port: in al, PORT_STATUS (0xDA)
;
; Critical hblank path (write case): ~60 clocks
;   outsb(14) + inc dx(3) + outsb(14) + outsb(14) +
;   dec dx(3) + mov al,0x80(4) + out dx,al(8)
; Skip case: 0 port writes (no palette glitch possible)
; ============================================================================
render_raster_bars:
    push ax
    push bx
    push cx
    push dx
    push si

    cli                     ; Disable interrupts for timing-critical code

    mov si, scanline_colors
    mov cx, SCREEN_HEIGHT
    mov dx, PORT_REG_ADDR   ; DX stays 0xDD for OUTSB + close

    ; Init BH:BL to impossible value so first scanline always writes
    mov bx, 0xFFFF

.scanline_loop:
    ; Pre-fetch color for this scanline (during active display - uncritical)
    mov ah, [si]            ; AH = new R
    mov al, [si + 1]        ; AL = new G|B
    add si, 2

    ; Compare new (AH,AL) vs current (BH,BL) - skip if unchanged
    cmp ax, bx
    je .skip_write

    ; Color changed - update tracking and prepare OUTSB buffer
    mov bx, ax              ; BH:BL = new R:GB
    mov [pal_cmd + 1], bh   ; R byte
    mov [pal_cmd + 2], bl   ; G|B byte

    ; Park SI, load pal_cmd for OUTSB (before HSYNC wait - free time)
    mov [saved_si], si
    mov si, pal_cmd

    ; Wait for HSYNC to go LOW (visible line being drawn)
.wait_low:
    in al, PORT_STATUS
    test al, 0x01
    jnz .wait_low

    ; Wait for HSYNC to go HIGH (HBLANK begins - safe to write palette!)
.wait_high:
    in al, PORT_STATUS
    test al, 0x01
    jz .wait_high

    ; --- Critical HBLANK path: OUTSB burst (~60 clocks) ---
    outsb                   ; 14 - OUT 0xDD, 0x40 (open palette, entry 0)
    inc dx                  ; 3  - DX = 0xDE (PORT_REG_DATA)
    outsb                   ; 14 - OUT 0xDE, R byte
    outsb                   ; 14 - OUT 0xDE, G|B byte
    dec dx                  ; 3  - DX = 0xDD (PORT_REG_ADDR)
    mov al, 0x80            ; 4
    out dx, al              ; 8  - close palette write window

    ; Restore scanline pointer
    mov si, [saved_si]
    jmp .next_line

.skip_write:
    ; Same color as previous scanline - no port writes needed
.wait_low2:
    in al, PORT_STATUS
    test al, 0x01
    jnz .wait_low2
.wait_high2:
    in al, PORT_STATUS
    test al, 0x01
    jz .wait_high2

.next_line:
    dec cx
    jnz .scanline_loop

    ; Restore palette entry 0 to original BMP color for clean top-of-frame
    mov al, 0x40
    out dx, al              ; DX is still PORT_REG_ADDR
    mov al, [orig_color0_r]
    out PORT_REG_DATA, al
    mov al, [orig_color0_gb]
    out PORT_REG_DATA, al
    mov al, 0x80
    out dx, al

    sti                     ; Re-enable interrupts

    pop si
    pop dx
    pop cx
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

    ; Wait for VBLANK to end (if currently in VBLANK)
.wait_end:
    in al, dx
    test al, 0x08
    jnz .wait_end

    ; Wait for VBLANK to start
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

    ; BIOS Mode 4: CGA 320x200 graphics, sets CRTC for 15.7kHz sync timing
    mov ax, 0x0004
    int 0x10

    ; Set monitor control register 0x65 (200 lines, PAL, color)
    mov al, 0x65
    out PORT_REG_ADDR, al
    jmp short $+2
    mov al, 0x09
    out PORT_REG_DATA, al
    jmp short $+2
    jmp short $+2

    ; Unlock 16-color mode
    mov al, 0x4A
    out PORT_MODE, al
    jmp short $+2
    jmp short $+2

    ; Set border color = black
    xor al, al
    out PORT_COLOR, al
    jmp short $+2
    jmp short $+2

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
; save_color0 - Save the BMP's original color 0 in V6355D RGB333 format
; Used to restore color 0 on scanlines where no raster bar is visible
; ============================================================================
save_color0:
    push ax
    push bx

    ; BMP palette is BGRA at bmp_header + 54
    ; Entry 0: Blue=[+0], Green=[+1], Red=[+2], Alpha=[+3]

    mov al, [bmp_header + 54 + 0]  ; Blue (8-bit)
    mov bl, al
    mov al, [bmp_header + 54 + 1]  ; Green (8-bit)
    mov bh, al
    mov al, [bmp_header + 54 + 2]  ; Red (8-bit)

    ; Convert Red: 8-bit → 3-bit (shift right 5)
    shr al, 5
    mov [orig_color0_r], al

    ; Convert Green: keep top 3 bits, shift to bits 4-6
    mov al, bh
    and al, 0xE0
    shr al, 1               ; Green now in bits 4-6
    mov ah, al

    ; Convert Blue: 8-bit → 3-bit (shift right 5)
    mov al, bl
    shr al, 5
    or al, ah               ; Combine: G (bits 4-6) | B (bits 0-2)
    mov [orig_color0_gb], al

    pop bx
    pop ax
    ret

; ============================================================================
; set_bmp_palette - Set palette from BMP file
; Converts BMP's BGRA format to V6355D's RGB333 format
; ============================================================================
set_bmp_palette:
    push ax
    push bx
    push cx
    push dx
    push si

    cli

    mov al, 0x40
    out PORT_REG_ADDR, al
    jmp short $+2

    mov si, bmp_header + 54
    mov cx, 16

.palette_loop:
    lodsb                   ; Blue
    mov bl, al

    lodsb                   ; Green
    mov bh, al

    lodsb                   ; Red
    shr al, 5               ; 8-bit → 3-bit
    out PORT_REG_DATA, al
    jmp short $+2

    mov al, bh              ; Green
    and al, 0xE0
    shr al, 1
    mov ah, al

    mov al, bl              ; Blue
    shr al, 5               ; 8-bit → 3-bit
    or al, ah
    out PORT_REG_DATA, al
    jmp short $+2

    lodsb                   ; Skip alpha

    loop .palette_loop

    mov al, 0x80
    out PORT_REG_ADDR, al

    sti

    pop si
    pop dx
    pop cx
    pop bx
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
    out PORT_REG_ADDR, al
    jmp short $+2

    mov si, cga_colors
    mov cx, 32

.pal_write_loop:
    lodsb
    out PORT_REG_DATA, al
    jmp short $+2
    loop .pal_write_loop

    mov al, 0x80
    out PORT_REG_ADDR, al

    sti

    pop si
    pop cx
    pop ax
    ret

; ============================================================================
; decode_bmp - Decode and display BMP image data
; BMP format: 4-bit pixels, 2 pixels per byte (packed nibbles)
; BMP stores bottom-up (last row first), so we reverse it
; CGA memory: even rows at 0x0000, odd rows at 0x2000
; ============================================================================
decode_bmp:
    push ax
    push bx
    push cx
    push dx
    push di
    push si
    push es

    ; Set ES to video memory
    mov ax, VIDEO_SEG
    mov es, ax

    ; Get image dimensions
    mov ax, [bmp_header + BMP_WIDTH]
    mov [image_width], ax

    ; Check if we need downscaling
    cmp ax, 160
    jbe .width_ok
    mov byte [downsample_flag], 1
    jmp .width_done
.width_ok:
    mov byte [downsample_flag], 0
.width_done:

    mov ax, [bmp_header + BMP_HEIGHT]
    cmp ax, 200
    jbe .height_ok
    mov ax, 200
.height_ok:
    mov [image_height], ax

    ; Calculate bytes per row (4-bit: width/2, padded to 4 bytes)
    mov ax, [image_width]
    inc ax
    shr ax, 1               ; bytes = (width + 1) / 2
    add ax, 3               ; Round up to 4-byte boundary
    and ax, 0xFFFC
    cmp ax, 164
    jbe .bpr_ok
    mov ax, 164
.bpr_ok:
    mov [bytes_per_row], ax

    ; Start from bottom row (BMP is bottom-up)
    mov ax, [image_height]
    dec ax
    mov [current_row], ax

.row_loop:
    ; Calculate video memory offset for this row
    ; Even rows: offset = (row/2) * 80
    ; Odd rows:  offset = 0x2000 + (row/2) * 80
    mov ax, [current_row]
    push ax                 ; Save for odd/even test
    shr ax, 1               ; AX = row / 2
    mov bx, 80
    mul bx                  ; AX = (row/2) * 80
    mov di, ax              ; DI = base offset

    pop ax                  ; Restore row number
    test al, 1              ; Check if odd row
    jz .is_even_row
    add di, 0x2000          ; Add 8KB offset for odd rows
.is_even_row:

    ; Read one row from file
    mov bx, [file_handle]
    mov dx, row_buffer
    mov cx, [bytes_per_row]
    mov ah, 0x3F
    int 0x21
    jc .decode_done
    or ax, ax
    jz .decode_done

    ; C64-style border color cycling during load
    mov al, [border_ctr]
    out PORT_COLOR, al
    inc byte [border_ctr]
    and byte [border_ctr], 0x0F

    ; Check if we need to downsample
    cmp byte [downsample_flag], 0
    je .no_downsample

    ; Downsample 320 -> 160: take every other pixel
    mov si, row_buffer
    mov cx, 80

.downsample_loop:
    lodsb                   ; AL = [pixel0][pixel1]
    push ax
    and al, 0xF0            ; Keep pixel0 in high nibble
    mov ah, al
    lodsb                   ; AL = [pixel2][pixel3]
    shr al, 4               ; High nibble → low nibble
    or al, ah               ; AL = [pixel0][pixel2]
    mov [es:di], al
    inc di
    pop ax
    loop .downsample_loop
    jmp .row_done

.no_downsample:
    ; Direct copy (160 pixel width)
    mov si, row_buffer
    mov cx, 80

.copy_loop:
    lodsb
    stosb
    loop .copy_loop

.row_done:
    mov ax, [current_row]
    or ax, ax
    jz .decode_done
    dec ax
    mov [current_row], ax
    jmp .row_loop

.decode_done:
    pop es
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

msg_info    db 'PALRAM7 - BMP with Palette RAM Raster Bars for Olivetti PC1', 0x0D, 0x0A
            db 'Uses palette RAM instead of PORT_COLOR for RGB333 raster bars', 0x0D, 0x0A
            db 'Bars appear wherever the image has background (color 0) pixels', 0x0D, 0x0A
            db 'Usage: PALRAM7 image.bmp', 0x0D, 0x0A
            db 'Press any key to exit.', 0x0D, 0x0A, '$'
msg_file_err db 'Error: Cannot open file', 0x0D, 0x0A, '$'
msg_not_bmp db 'Error: Not a valid BMP file', 0x0D, 0x0A, '$'
msg_format  db 'Error: BMP must be 4-bit uncompressed', 0x0D, 0x0A, '$'

filename_ptr    dw 0
file_handle     dw 0
image_width     dw 0
image_height    dw 0
bytes_per_row   dw 0
current_row     dw 0
downsample_flag db 0
border_ctr      db 0            ; Border color cycling counter for loading effect

; Saved BMP color 0 in V6355D RGB333 format
orig_color0_r   db 0            ; Red component (bits 0-2)
orig_color0_gb  db 0            ; Green (bits 4-6) | Blue (bits 0-2)

; Raster bar state
bar1_y:         db 0
bar2_y:         db 0
bar1_sine_idx:  db BAR1_PHASE
bar2_sine_idx:  db BAR2_PHASE
front_bar:      db 0

; OUTSB command buffer: [0x40, R, G|B] - pre-built before each HSYNC
pal_cmd         db 0x40, 0, 0
saved_si        dw 0

; ============================================================================
; RGB333 Gradient Tables - 2 bytes per entry (R, G|B)
; ============================================================================

; Red gradient: R=1→7→1, G=0, B=0 (warm raster bar)
; BAR_HEIGHT entries × 2 bytes = 56 bytes
red_gradient:
%assign i 1
%rep 7
    times LINES_PER_COLOR db i, 0x00
%assign i i+1
%endrep
%assign i 7
%rep 7
    times LINES_PER_COLOR db i, 0x00
%assign i i-1
%endrep

; Cyan gradient: R=0, G=1→7→1, B=1→7→1 (cool raster bar)
; BAR_HEIGHT entries × 2 bytes = 56 bytes
cyan_gradient:
%assign i 1
%rep 7
    times LINES_PER_COLOR db 0x00, (i << 4) | i
%assign i i+1
%endrep
%assign i 7
%rep 7
    times LINES_PER_COLOR db 0x00, (i << 4) | i
%assign i i-1
%endrep

; Pre-computed scanline RGB pairs (200 entries × 2 bytes = 400 bytes)
; Each entry: R byte, G|B byte for palette entry 0 on that scanline
scanline_colors: times SCREEN_HEIGHT * 2 db 0

; Sine table (256 entries, values 0-100, centered at 50)
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

; Standard CGA palette for exit
cga_colors:
    db 0x00, 0x00    ; 0:  Black
    db 0x00, 0x05    ; 1:  Blue
    db 0x00, 0x50    ; 2:  Green
    db 0x00, 0x55    ; 3:  Cyan
    db 0x05, 0x00    ; 4:  Red
    db 0x05, 0x05    ; 5:  Magenta
    db 0x05, 0x20    ; 6:  Brown
    db 0x05, 0x55    ; 7:  Light Gray
    db 0x02, 0x22    ; 8:  Dark Gray
    db 0x02, 0x27    ; 9:  Light Blue
    db 0x02, 0x72    ; 10: Light Green
    db 0x02, 0x77    ; 11: Light Cyan
    db 0x07, 0x22    ; 12: Light Red
    db 0x07, 0x27    ; 13: Light Magenta
    db 0x07, 0x70    ; 14: Yellow
    db 0x07, 0x77    ; 15: White

; BMP header buffer and row buffer
bmp_header:     times 128 db 0
row_buffer:     times 164 db 0

; ============================================================================
; End of Program
; ============================================================================
