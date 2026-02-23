; ============================================================================
; DEMO8A.ASM - Circular Buffer Fast Scroller (Experimental - Has 384-Gap Bug)
; Olivetti Prodest PC1 - V6355D 160x200x16 Hidden Graphics Mode
; Written for NASM - NEC V40 @ 8 MHz (80186 instruction set)
; By RetroErik - 2026
;
; ============================================================================
; CIRCULAR BUFFER TECHNIQUE - CONCEPT DEMONSTRATION
; ============================================================================
;
; This demo attempts to implement circular buffer scrolling for speed.
; Demo7 copies 16KB every scroll step. This demo only copies 160 bytes!
;
; The trick: Treat VRAM as a circular (ring) buffer. Instead of copying
; all 200 visible rows, only copy the NEW rows that scroll into view,
; then use R12/R13 to shift where the CRTC starts reading.
;
; How it works (scrolling DOWN by 2 rows):
;   1. Row 0-1 scrolls off top of screen (no longer visible)
;   2. Row 200-201 scrolls into view at bottom
;   3. Overwrite VRAM where rows 0-1 were stored with rows 200-201
;   4. Set R12/R13 to start display at row 2's position
;   5. CRTC wraps around at bank boundary, making it seamless
;
; Memory comparison:
;   Demo7: 16,384 bytes per scroll step (full viewport copy)
;   Demo8a: 160 bytes per scroll step (just 2 new rows)
;   Potential speedup: ~100x faster!
;
; ============================================================================
; KNOWN BUG: THE 384-BYTE GAP PROBLEM
; ============================================================================
;
; This demo has a fundamental flaw due to CGA/V6355D interlaced memory layout:
;
;   VRAM Bank Layout:
;   Even bank (0x0000-0x1FFF): 8192 bytes total, but only 8000 used (100×80)
;   Odd bank  (0x2000-0x3FFF): 8192 bytes total, but only 8000 used (100×80)
;
;   The Gap:
;   - Each bank has 8192 - 8000 = 192 bytes of unused "gap" at the end
;   - Total gap = 192 × 2 banks = 384 bytes
;   - These 192 bytes per bank (offsets 0x1F40-0x1FFF and 0x3F40-0x3FFF)
;     contain garbage/uninitialized data
;
;   The Problem:
;   - This code wraps crtc_start_addr at 8000 bytes (logical display area)
;   - But the V6355D hardware wraps at 8192 bytes (physical bank size)
;   - When crtc_start_addr > 0, the CRTC reads into the gap area
;   - Result: Garbage pixels appear at the bottom of the screen
;
;   Example (crtc_start_addr = 80, one row scrolled):
;   - Display reads rows at offsets: 80, 160, 240, ... 7920, 8000 (gap!), ...
;   - Offset 8000-8079 is in the gap, not valid image data
;   - Those 80 bytes display as garbage (last row on screen)
;
; This demo is kept as a reference for the circular buffer concept.
; See demo8b.asm for 196-row workaround, demo8c.asm for the final fix.
;
; STATUS: SUPERSEDED by demo8c.asm which uses register 0x65 (192-line mode)
; to create a 512-byte gap — enough for true circular buffer with zero reloads.
;
; ============================================================================
; CONTROLS
; ============================================================================
;   UP/DOWN arrows or <,> = Manual scroll (2 rows per step)
;   SPACE = Toggle auto-scroll (bounces up and down)
;   V = Toggle VSync wait
;   R = Reset to initial view (scroll position 0)
;   ESC/Q = Exit
;
; ============================================================================
; LIMITATIONS
; ============================================================================
;   - Scroll step MUST be 2 rows (to keep even/odd bank alignment)
;   - Cannot scroll by 1 row (would desync the interlaced banks)
;   - 384-byte gap bug causes garbage when crtc_start_addr > 0
;
; ============================================================================

[BITS 16]
[CPU 186]
[ORG 0x100]

; ============================================================================
; Constants
; ============================================================================

VIDEO_SEG       equ 0xB000
BYTES_PER_LINE  equ 80
BANK_SIZE       equ 8192        ; 8KB per bank (100 rows)
VRAM_SIZE       equ 16384       ; 16KB total VRAM
MAX_IMAGE_HEIGHT equ 800        ; Maximum height: 800×80 = 64000 bytes
STACK_RESERVE   equ 64          ; Paragraphs reserved for stack (1KB)
SCROLL_STEP     equ 2           ; Must be 2 to keep bank alignment
FRAME_DELAY     equ 1           ; VSync waits between frames

; V6355D I/O Ports
PORT_REG_ADDR   equ 0x3DD
PORT_REG_DATA   equ 0x3DE
PORT_MODE       equ 0x3D8
PORT_COLOR      equ 0x3D9
PORT_STATUS     equ 0x3DA
PORT_CRTC_ADDR  equ 0x3D4
PORT_CRTC_DATA  equ 0x3D5

; CRTC registers
CRTC_START_HIGH equ 12          ; Start Address High (R12)
CRTC_START_LOW  equ 13          ; Start Address Low (R13)

; BMP file header offsets
BMP_SIGNATURE   equ 0
BMP_DATA_OFFSET equ 10
BMP_WIDTH       equ 18
BMP_HEIGHT      equ 22
BMP_BPP         equ 28
BMP_COMPRESSION equ 30

; ============================================================================
; Main
; ============================================================================

main:
    call shrink_memory_block
    
    ; Parse command line
    mov si, 0x81
.skip_spaces:
    lodsb
    cmp al, ' '
    je .skip_spaces
    cmp al, 0x0D
    je .show_usage
    dec si
    mov [filename_ptr], si
    
.find_end:
    lodsb
    cmp al, ' '
    je .terminate
    cmp al, 0x0D
    je .terminate
    jmp .find_end
.terminate:
    mov byte [si-1], 0
    jmp .open_file

.show_usage:
    mov dx, msg_usage
    mov ah, 0x09
    int 0x21
    mov ax, 0x4C00
    int 0x21

.open_file:
    mov dx, [filename_ptr]
    mov ax, 0x3D00
    int 0x21
    jc .file_error
    mov [file_handle], ax
    
    mov bx, ax
    mov dx, bmp_header
    mov cx, 118
    mov ah, 0x3F
    int 0x21
    jc .file_error
    
    cmp word [bmp_header + BMP_SIGNATURE], 0x4D42
    jne .not_bmp
    cmp word [bmp_header + BMP_BPP], 4
    jne .wrong_format
    cmp word [bmp_header + BMP_COMPRESSION], 0
    jne .wrong_format
    
    mov ax, [bmp_header + BMP_WIDTH]
    mov [image_width], ax
    cmp ax, 160
    je .width_ok
    cmp ax, 320
    jne .wrong_size
    mov byte [downsample_flag], 1
.width_ok:
    
    mov ax, [bmp_header + BMP_HEIGHT]
    cmp ax, 200
    jb .wrong_size
    cmp ax, MAX_IMAGE_HEIGHT
    ja .wrong_size
    mov [image_height], ax
    
    ; Seek to pixel data
    mov bx, [file_handle]
    mov dx, [bmp_header + BMP_DATA_OFFSET]
    mov cx, [bmp_header + BMP_DATA_OFFSET + 2]
    mov ax, 0x4200
    int 0x21
    
    ; Decode BMP to RAM buffer (interlaced format)
    call decode_bmp
    
    mov bx, [file_handle]
    mov ah, 0x3E
    int 0x21
    
    call enable_graphics_mode
    call set_bmp_palette
    
    ; Calculate max scroll row (image_height - 200)
    mov ax, [image_height]
    sub ax, 200
    jns .has_scroll_range
    xor ax, ax
.has_scroll_range:
    mov [max_scroll_row], ax
    
    ; Initialize circular buffer state
    call reset_scroll
    
    ; Enable video
    mov dx, PORT_MODE
    mov al, 0x4A
    out dx, al
    
    ; ========================================================================
    ; Main loop
    ; ========================================================================
.main_loop:
    cmp byte [auto_scroll], 0
    jne .do_auto_scroll
    
    mov ah, 0x01
    int 0x16
    jz .main_loop
    jmp .handle_key

.do_auto_scroll:
    mov ah, 0x01
    int 0x16
    jz .auto_step
    
.handle_key:
    xor ah, ah
    int 0x16
    
    cmp al, 0x1B
    je .exit
    cmp al, 'q'
    je .exit
    cmp al, 'Q'
    je .exit
    
    cmp al, ' '
    je .toggle_auto
    
    cmp al, 'V'
    je .toggle_vsync
    cmp al, 'v'
    je .toggle_vsync
    
    cmp al, 'R'
    je .do_reset
    cmp al, 'r'
    je .do_reset
    
    cmp ah, 0x48            ; Up arrow
    je .scroll_up
    cmp al, ','
    je .scroll_up
    cmp al, '<'
    je .scroll_up
    
    cmp ah, 0x50            ; Down arrow
    je .scroll_down
    cmp al, '.'
    je .scroll_down
    cmp al, '>'
    je .scroll_down
    
    jmp .main_loop

.toggle_auto:
    xor byte [auto_scroll], 1
    jmp .main_loop

.toggle_vsync:
    xor byte [vsync_enabled], 1
    jmp .main_loop

.do_reset:
    call reset_scroll
    jmp .main_loop

.auto_step:
    cmp byte [vsync_enabled], 0
    je .skip_vsync
    mov cx, FRAME_DELAY
.delay_loop:
    call wait_vsync
    loop .delay_loop
.skip_vsync:
    
    mov ax, [scroll_row]
    cmp byte [scroll_dir], 0
    jne .auto_up
    
    ; Moving down
    add ax, SCROLL_STEP
    cmp ax, [max_scroll_row]
    jbe .auto_do_scroll_down
    mov ax, [max_scroll_row]
    mov byte [scroll_dir], 1
    jmp .main_loop
    
.auto_do_scroll_down:
    call scroll_down_circular
    jmp .main_loop
    
.auto_up:
    sub ax, SCROLL_STEP
    jns .auto_do_scroll_up
    xor ax, ax
    mov byte [scroll_dir], 0
    jmp .main_loop
    
.auto_do_scroll_up:
    call scroll_up_circular
    jmp .main_loop

.scroll_up:
    mov byte [auto_scroll], 0
    mov ax, [scroll_row]
    cmp ax, 0
    je .main_loop           ; Already at top
    call scroll_up_circular
    jmp .main_loop

.scroll_down:
    mov byte [auto_scroll], 0
    mov ax, [scroll_row]
    cmp ax, [max_scroll_row]
    jae .main_loop          ; Already at bottom
    call scroll_down_circular
    jmp .main_loop

.exit:
    mov ax, [image_buffer_seg]
    or ax, ax
    jz .no_free
    mov es, ax
    mov ah, 0x49
    int 0x21
.no_free:
    
    ; Reset CRTC start address to 0
    xor ax, ax
    call set_crtc_start_address
    
    call set_cga_palette
    
    mov dx, PORT_MODE
    mov al, 0x28
    out dx, al
    mov ax, 0x0003
    int 0x10
    mov ax, 0x4C00
    int 0x21

.file_error:
    mov dx, msg_file_err
    jmp .error_exit
.not_bmp:
    mov dx, msg_not_bmp
    jmp .error_exit
.wrong_format:
    mov dx, msg_format
    jmp .error_exit
.wrong_size:
    mov dx, msg_size
.error_exit:
    mov ah, 0x09
    int 0x21
    mov ax, 0x4C01
    int 0x21

; ============================================================================
; reset_scroll - Reset to initial state, copy first 200 rows to VRAM
; ============================================================================
reset_scroll:
    pusha
    push ds
    push es
    
    ; Reset scroll position
    mov word [scroll_row], 0
    mov word [vram_write_row], 0    ; Next row to overwrite in VRAM
    mov word [crtc_start_addr], 0   ; Display starts at offset 0
    
    ; Copy initial 200 rows from RAM buffer to VRAM (full copy, just once)
    mov ax, VIDEO_SEG
    mov es, ax
    mov ax, [image_buffer_seg]
    mov ds, ax
    
    ; Copy even rows (0,2,4...198) to VRAM bank 0
    xor si, si                  ; Start of RAM buffer
    xor di, di                  ; VRAM even bank
    mov cx, 4000                ; 100 rows × 80 bytes / 2
    cld
    rep movsw
    
    ; Copy odd rows (1,3,5...199) to VRAM bank 1
    mov si, [cs:odd_bank_offset]
    mov di, 0x2000              ; VRAM odd bank
    mov cx, 4000
    rep movsw
    
    ; Reset CRTC start address
    xor ax, ax
    call set_crtc_start_address
    
    pop es
    pop ds
    popa
    ret

; ============================================================================
; scroll_down_circular - Scroll down by 2 rows using circular buffer
;
; Algorithm:
;   1. Increment scroll_row by 2 (new logical position in image)
;   2. Copy 2 new rows from RAM to VRAM slot being vacated at top
;   3. Increment CRTC start address by 80 bytes (shifts display down)
;   4. Wrap vram_write_row at 200, crtc_start_addr at 8000
;
; BUG: This wraps at 8000 bytes, but hardware wraps at 8192.
;      After ANY scroll, crtc_start_addr > 0 causes display to read
;      into the 192-byte gap at offsets 8000-8191, showing garbage.
; ============================================================================
scroll_down_circular:
    pusha
    push ds
    push es
    
    ; Update scroll position in image
    add word [scroll_row], SCROLL_STEP
    
    ; The new rows to display are at (scroll_row + 198) and (scroll_row + 199)
    ; These are the bottom 2 rows of the new viewport
    mov ax, [scroll_row]
    add ax, 198                 ; New even row (row 198 of viewport = scroll_row+198 in image)
    mov [temp_row], ax
    
    ; Calculate source offset in RAM for new even row
    ; Even row: (row/2) * 80
    mov ax, [temp_row]
    shr ax, 1
    mov bx, BYTES_PER_LINE
    mul bx
    mov si, ax                  ; SI = offset in RAM even bank
    
    ; Calculate destination in VRAM (circular wrap)
    ; vram_write_row tells us which VRAM row slot to overwrite
    mov ax, [vram_write_row]
    shr ax, 1                   ; Row slot / 2 (for even bank)
    mov bx, BYTES_PER_LINE
    mul bx
    mov di, ax                  ; DI = VRAM even bank offset
    
    ; Set up segments
    mov ax, [image_buffer_seg]
    mov ds, ax
    mov ax, VIDEO_SEG
    mov es, ax
    
    ; Copy 1 even row (80 bytes)
    mov cx, 40
    cld
    rep movsw
    
    ; Now copy the new odd row
    mov ax, [cs:temp_row]
    inc ax                      ; Odd row = even row + 1
    shr ax, 1
    mov bx, BYTES_PER_LINE
    mul bx
    add ax, [cs:odd_bank_offset]
    mov si, ax                  ; SI = offset in RAM odd bank
    
    ; VRAM odd bank destination
    mov ax, [cs:vram_write_row]
    shr ax, 1
    mov bx, BYTES_PER_LINE
    mul bx
    add ax, 0x2000              ; Odd bank offset
    mov di, ax
    
    ; Copy 1 odd row (80 bytes)
    mov cx, 40
    rep movsw
    
    ; Update VRAM write position (circular wrap at 200)
    mov ax, [cs:vram_write_row]
    add ax, SCROLL_STEP
    cmp ax, 200
    jb .no_wrap_write
    sub ax, 200                 ; Wrap around
.no_wrap_write:
    mov [cs:vram_write_row], ax
    
    ; Update CRTC start address
    ; Move start forward by 2 rows (160 bytes = 80 per row × 2 rows)
    ; But we need byte offset for R12/R13
    mov ax, [cs:crtc_start_addr]
    add ax, BYTES_PER_LINE      ; Add 80 bytes (1 row in each bank = 2 visual rows)
    
    ; Wrap at 8000 bytes (100 rows in even bank)
    cmp ax, 8000
    jb .no_wrap_crtc
    sub ax, 8000                ; Wrap around
.no_wrap_crtc:
    mov [cs:crtc_start_addr], ax
    call set_crtc_start_address
    
    pop es
    pop ds
    popa
    ret

; ============================================================================
; scroll_up_circular - Scroll up by 2 rows using circular buffer
;
; Algorithm (reverse of scroll_down):
;   1. Decrement vram_write_row by 2 (prepare slot for new top row)
;   2. Decrement scroll_row by 2 (new logical position in image)
;   3. Copy 2 new rows from RAM to the new VRAM slot
;   4. Decrement CRTC start address by 80 bytes (shifts display up)
;   5. Wrap vram_write_row at 200, crtc_start_addr at 8000
;
; BUG: Same 384-gap bug as scroll_down_circular. Any non-zero
;      crtc_start_addr causes garbage pixels from the gap area.
; ============================================================================
scroll_up_circular:
    pusha
    push ds
    push es
    
    ; Update scroll position
    sub word [scroll_row], SCROLL_STEP
    
    ; Update VRAM write position backward (need to write BEFORE current start)
    mov ax, [vram_write_row]
    sub ax, SCROLL_STEP
    jns .no_wrap_write_up
    add ax, 200                 ; Wrap around backward
.no_wrap_write_up:
    mov [vram_write_row], ax
    
    ; The new rows to display are at scroll_row and scroll_row+1
    ; These are the top 2 rows of the new viewport
    mov ax, [scroll_row]
    mov [temp_row], ax
    
    ; Calculate source offset in RAM for new even row
    mov ax, [temp_row]
    shr ax, 1
    mov bx, BYTES_PER_LINE
    mul bx
    mov si, ax
    
    ; Calculate destination in VRAM
    mov ax, [vram_write_row]
    shr ax, 1
    mov bx, BYTES_PER_LINE
    mul bx
    mov di, ax
    
    ; Set up segments
    mov ax, [image_buffer_seg]
    mov ds, ax
    mov ax, VIDEO_SEG
    mov es, ax
    
    ; Copy 1 even row
    mov cx, 40
    cld
    rep movsw
    
    ; Copy new odd row
    mov ax, [cs:temp_row]
    inc ax
    shr ax, 1
    mov bx, BYTES_PER_LINE
    mul bx
    add ax, [cs:odd_bank_offset]
    mov si, ax
    
    mov ax, [cs:vram_write_row]
    shr ax, 1
    mov bx, BYTES_PER_LINE
    mul bx
    add ax, 0x2000
    mov di, ax
    
    mov cx, 40
    rep movsw
    
    ; Update CRTC start address backward
    mov ax, [cs:crtc_start_addr]
    sub ax, BYTES_PER_LINE
    jns .no_wrap_crtc_up
    add ax, 8000                ; Wrap around
.no_wrap_crtc_up:
    mov [cs:crtc_start_addr], ax
    call set_crtc_start_address
    
    pop es
    pop ds
    popa
    ret

; ============================================================================
; set_crtc_start_address - Set R12/R13 from byte offset in AX
; ============================================================================
set_crtc_start_address:
    push ax
    push bx
    push dx
    
    ; Convert byte offset to word offset (CRTC counts words, not bytes)
    shr ax, 1
    mov bh, ah
    mov bl, al
    
    ; Write R12 (high byte)
    mov dx, PORT_CRTC_ADDR
    mov al, CRTC_START_HIGH
    out dx, al
    jmp short $+2
    mov dx, PORT_CRTC_DATA
    mov al, bh
    out dx, al
    jmp short $+2
    
    ; Write R13 (low byte)
    mov dx, PORT_CRTC_ADDR
    mov al, CRTC_START_LOW
    out dx, al
    jmp short $+2
    mov dx, PORT_CRTC_DATA
    mov al, bl
    out dx, al
    
    pop dx
    pop bx
    pop ax
    ret

; ============================================================================
; wait_vsync
; ============================================================================
wait_vsync:
    push ax
    push dx
    mov dx, PORT_STATUS
.wait_end:
    in al, dx
    test al, 8
    jnz .wait_end
.wait_start:
    in al, dx
    test al, 8
    jz .wait_start
    pop dx
    pop ax
    ret

; ============================================================================
; enable_graphics_mode
; ============================================================================
enable_graphics_mode:
    push ax
    push dx
    
    mov dx, PORT_REG_ADDR
    mov al, 0x65
    out dx, al
    jmp short $+2
    mov dx, PORT_REG_DATA
    mov al, 0x09
    out dx, al
    jmp short $+2
    
    mov dx, PORT_MODE
    mov al, 0x4A
    out dx, al
    jmp short $+2
    
    mov dx, PORT_COLOR
    xor al, al
    out dx, al
    
    pop dx
    pop ax
    ret

; ============================================================================
; shrink_memory_block
; ============================================================================
shrink_memory_block:
    push ax
    push bx
    push es
    
    mov ax, cs
    mov es, ax
    mov bx, end_program + 0x100
    add bx, 15
    shr bx, 4
    add bx, STACK_RESERVE
    
    mov ah, 0x4A
    int 0x21
    
    pop es
    pop bx
    pop ax
    ret

; ============================================================================
; decode_bmp - Allocate RAM and read BMP to interlaced buffer
; ============================================================================
decode_bmp:
    pusha
    push es
    
    mov ax, [image_width]
    inc ax
    shr ax, 1
    add ax, 3
    and ax, 0xFFFC
    mov [bytes_per_row], ax
    
    mov ax, [image_height]
    shr ax, 1
    mov bx, BYTES_PER_LINE
    mul bx
    mov [odd_bank_offset], ax
    
    mov ax, [image_height]
    mov bx, BYTES_PER_LINE
    mul bx
    mov [image_size_bytes], ax
    
    mov bx, ax
    add bx, 15
    shr bx, 4
    mov ah, 0x48
    int 0x21
    jc .alloc_error
    mov [image_buffer_seg], ax
    
    mov ax, [image_height]
    dec ax
    mov [current_row], ax
    
.row_loop:
    mov ax, [current_row]
    mov bx, ax
    shr ax, 1
    mov dx, BYTES_PER_LINE
    mul dx
    mov di, ax
    test bx, 1
    jz .even_row
    add di, [odd_bank_offset]
.even_row:
    
    mov bx, [file_handle]
    mov dx, row_buffer
    mov cx, [bytes_per_row]
    mov ah, 0x3F
    int 0x21
    jc .decode_done
    or ax, ax
    jz .decode_done
    
    mov es, [image_buffer_seg]
    
    cmp byte [downsample_flag], 0
    je .no_downsample
    
    mov si, row_buffer
    mov cx, 80
.ds_loop:
    lodsb
    and al, 0xF0
    mov ah, al
    lodsb
    shr al, 4
    or al, ah
    stosb
    loop .ds_loop
    jmp .row_done
    
.no_downsample:
    mov si, row_buffer
    mov cx, 80
    rep movsb
    
.row_done:
    dec word [current_row]
    cmp word [current_row], 0xFFFF
    jne .row_loop
    
.decode_done:
    pop es
    popa
    ret

.alloc_error:
    mov dx, msg_mem_err
    mov ah, 0x09
    int 0x21
    mov ax, 0x4C01
    int 0x21

; ============================================================================
; set_bmp_palette
; ============================================================================
set_bmp_palette:
    pusha
    cli
    
    mov dx, PORT_REG_ADDR
    mov al, 0x40
    out dx, al
    jmp short $+2
    
    mov si, bmp_header + 54
    mov cx, 16
    mov dx, PORT_REG_DATA
    
.pal_loop:
    lodsb
    mov bl, al
    lodsb
    mov bh, al
    lodsb
    shr al, 5
    out dx, al
    jmp short $+2
    
    mov al, bh
    and al, 0xE0
    shr al, 1
    mov ah, al
    mov al, bl
    shr al, 5
    or al, ah
    out dx, al
    jmp short $+2
    
    lodsb
    loop .pal_loop
    
    mov dx, PORT_REG_ADDR
    mov al, 0x80
    out dx, al
    
    sti
    popa
    ret

; ============================================================================
; set_cga_palette
; ============================================================================
set_cga_palette:
    pusha
    cli
    
    mov dx, PORT_REG_ADDR
    mov al, 0x40
    out dx, al
    jmp short $+2
    
    mov si, cga_colors
    mov cx, 32
    mov dx, PORT_REG_DATA
    
.cga_loop:
    lodsb
    out dx, al
    jmp short $+2
    loop .cga_loop
    
    mov dx, PORT_REG_ADDR
    mov al, 0x80
    out dx, al
    
    sti
    popa
    ret

; ============================================================================
; Data
; ============================================================================

msg_usage       db 'DEMO8 - Circular Buffer Fast Scroller (100x faster!)', 13, 10
                db 'Usage: DEMO8 filename.bmp', 13, 10
                db 'BMP must be 160 wide, 200-800 tall, 4-bit', 13, 10
                db 'UP/DOWN = scroll, SPACE = auto, V = VSync, R = Reset', 13, 10
                db 'Only copies 160 bytes/frame instead of 16KB!', 13, 10
                db 'ESC to exit', 13, 10, '$'

msg_file_err    db 'Error: Cannot open file', 13, 10, '$'
msg_not_bmp     db 'Error: Not a valid BMP file', 13, 10, '$'
msg_format      db 'Error: Must be 4-bit uncompressed BMP', 13, 10, '$'
msg_size        db 'Error: Must be 160 wide, 200-800 tall', 13, 10, '$'
msg_mem_err     db 'Error: Cannot allocate memory', 13, 10, '$'

cga_colors:
    db 0x00, 0x00
    db 0x00, 0x05
    db 0x00, 0x50
    db 0x00, 0x55
    db 0x05, 0x00
    db 0x05, 0x05
    db 0x05, 0x20
    db 0x05, 0x55
    db 0x02, 0x22
    db 0x02, 0x27
    db 0x02, 0x72
    db 0x02, 0x77
    db 0x07, 0x22
    db 0x07, 0x27
    db 0x07, 0x70
    db 0x07, 0x77

filename_ptr    dw 0
file_handle     dw 0
image_width     dw 0
image_height    dw 0
bytes_per_row   dw 0
current_row     dw 0
downsample_flag db 0

; Scrolling state
scroll_row      dw 0            ; Current top row in image (0 to max_scroll_row)
max_scroll_row  dw 0            ; Maximum scroll position
image_buffer_seg dw 0           ; Allocated buffer segment
odd_bank_offset dw 0            ; Offset to odd rows in buffer
image_size_bytes dw 0

; Circular buffer state
vram_write_row  dw 0            ; Next VRAM row slot to overwrite (0-199)
crtc_start_addr dw 0            ; Current CRTC start address (byte offset)

; Temporary variables
temp_row        dw 0

; Auto-scroll state
auto_scroll     db 0
scroll_dir      db 0
vsync_enabled   db 1

bmp_header      times 128 db 0
row_buffer      times 164 db 0

end_program:
