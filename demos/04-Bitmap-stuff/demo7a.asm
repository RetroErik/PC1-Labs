; ============================================================================
; DEMO7A.ASM - R12/R13 Hardware Scroll Test (Working 160×200 version) - First working version
; Olivetti Prodest PC1 - V6355D 160x200x16 Hidden Graphics Mode
; Written for NASM - NEC V40 @ 8 MHz (80186 instruction set)
; By RetroErik - 2026
;
; Description:
;   Loads a 160×200 or 320×200 BMP, displays it, and tests hardware
;   scrolling using CGA CRTC registers R12/R13 (Start Address).
;   Press UP/DOWN arrows or <,> to scroll. ESC/Q to exit.
;
; This proves that V6355D's "6845 restricted mode" supports hardware
; scrolling via standard CGA CRTC Start Address registers.
; ============================================================================

[BITS 16]
[CPU 186]
[ORG 0x100]

; ============================================================================
; Constants
; ============================================================================

VIDEO_SEG       equ 0xB000
BYTES_PER_LINE  equ 80
IMAGE_SIZE      equ 16000       ; 160×200×4bpp = 16000 bytes
VRAM_SIZE       equ 16384       ; Full VRAM is 16KB

; Ports
PORT_REG_ADDR   equ 0x3DD
PORT_REG_DATA   equ 0x3DE
PORT_MODE       equ 0x3D8
PORT_COLOR      equ 0x3D9
PORT_STATUS     equ 0x3DA
PORT_CRTC_ADDR  equ 0x3D4
PORT_CRTC_DATA  equ 0x3D5

; CRTC registers
CRTC_START_HIGH equ 12
CRTC_START_LOW  equ 13

; BMP offsets
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
    
    ; Find end of filename, null-terminate
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
    ; Open BMP file
    mov dx, [filename_ptr]
    mov ax, 0x3D00
    int 0x21
    jc .file_error
    mov [file_handle], ax
    
    ; Read header
    mov bx, ax
    mov dx, bmp_header
    mov cx, 118
    mov ah, 0x3F
    int 0x21
    jc .file_error
    
    ; Verify BMP
    cmp word [bmp_header + BMP_SIGNATURE], 0x4D42
    jne .not_bmp
    cmp word [bmp_header + BMP_BPP], 4
    jne .wrong_format
    cmp word [bmp_header + BMP_COMPRESSION], 0
    jne .wrong_format
    
    ; Get dimensions
    mov ax, [bmp_header + BMP_WIDTH]
    mov [image_width], ax
    cmp ax, 160
    je .width_ok
    cmp ax, 320
    jne .wrong_size
    mov byte [downsample_flag], 1
.width_ok:
    
    cmp word [bmp_header + BMP_HEIGHT], 200
    jne .wrong_size
    
    ; Seek to pixel data
    mov bx, [file_handle]
    mov dx, [bmp_header + BMP_DATA_OFFSET]
    mov cx, [bmp_header + BMP_DATA_OFFSET + 2]
    mov ax, 0x4200
    int 0x21
    
    ; Decode BMP to RAM buffer
    call decode_bmp
    
    ; Close file
    mov bx, [file_handle]
    mov ah, 0x3E
    int 0x21
    
    ; Enable graphics mode
    call enable_graphics_mode
    
    ; Set palette
    call set_bmp_palette
    
    ; Copy image to VRAM
    call copy_image_to_vram
    
    ; Enable video
    mov dx, PORT_MODE
    mov al, 0x4A
    out dx, al
    
    ; Reset scroll
    mov word [scroll_offset], 0
    
    ; ========================================================================
    ; Main loop - keyboard scroll test
    ; ========================================================================
.main_loop:
    ; Wait for keypress
    mov ah, 0x01
    int 0x16
    jz .main_loop
    
    ; Get key
    xor ah, ah
    int 0x16
    
    ; Check for exit
    cmp al, 0x1B            ; ESC
    je .exit
    cmp al, 'q'
    je .exit
    cmp al, 'Q'
    je .exit
    
    ; Check for scroll keys
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

.scroll_up:
    mov ax, [scroll_offset]
    sub ax, BYTES_PER_LINE
    jns .update_scroll
    xor ax, ax
    jmp .update_scroll

.scroll_down:
    mov ax, [scroll_offset]
    add ax, BYTES_PER_LINE
    cmp ax, 8000             ; Max scroll = 100 lines worth
    jbe .update_scroll
    mov ax, 800

.update_scroll:
    mov [scroll_offset], ax
    call set_crtc_start_address
    jmp .main_loop

.exit:
    ; Restore CGA palette
    call set_cga_palette
    
    ; Restore text mode
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
; set_crtc_start_address - Set R12/R13 from byte offset in AX
; ============================================================================
set_crtc_start_address:
    push ax
    push bx
    push dx
    
    ; Convert byte offset to word offset
    shr ax, 1
    mov bh, ah              ; High byte
    mov bl, al              ; Low byte
    
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
; enable_graphics_mode - PC1 hidden 160×200×16 mode
; ============================================================================
enable_graphics_mode:
    push ax
    push dx
    
    ; Register 0x65 = monitor control
    mov dx, PORT_REG_ADDR
    mov al, 0x65
    out dx, al
    jmp short $+2
    mov dx, PORT_REG_DATA
    mov al, 0x09
    out dx, al
    jmp short $+2
    
    ; Mode register
    mov dx, PORT_MODE
    mov al, 0x4A
    out dx, al
    jmp short $+2
    
    ; Border = black
    mov dx, PORT_COLOR
    xor al, al
    out dx, al
    
    pop dx
    pop ax
    ret

; ============================================================================
; decode_bmp - Read BMP pixel data to interlaced RAM buffer
; ============================================================================
decode_bmp:
    pusha
    
    ; Calculate bytes per row in BMP file
    mov ax, [image_width]
    inc ax
    shr ax, 1
    add ax, 3
    and ax, 0xFFFC
    mov [bytes_per_row], ax
    
    ; Start from last row (BMP is bottom-up)
    mov word [current_row], 199
    
.row_loop:
    ; Calculate destination offset in interlaced format
    mov ax, [current_row]
    mov bx, ax
    shr ax, 1
    mov dx, BYTES_PER_LINE
    mul dx
    mov di, ax
    test bx, 1
    jz .even_row
    add di, 8192            ; Odd rows at offset 8192
.even_row:
    
    ; Read row from file
    mov bx, [file_handle]
    mov dx, row_buffer
    mov cx, [bytes_per_row]
    mov ah, 0x3F
    int 0x21
    jc .decode_done
    or ax, ax
    jz .decode_done
    
    ; Copy/downsample to buffer
    cmp byte [downsample_flag], 0
    je .no_downsample
    
    ; Downsample 320→160
    mov si, row_buffer
    mov cx, 80
.ds_loop:
    lodsb
    and al, 0xF0
    mov ah, al
    lodsb
    shr al, 4
    or al, ah
    mov [image_buffer + di], al
    inc di
    loop .ds_loop
    jmp .row_done
    
.no_downsample:
    mov si, row_buffer
    mov cx, 80
.copy_loop:
    lodsb
    mov [image_buffer + di], al
    inc di
    loop .copy_loop
    
.row_done:
    dec word [current_row]
    cmp word [current_row], 0xFFFF
    jne .row_loop
    
.decode_done:
    popa
    ret

; ============================================================================
; copy_image_to_vram - Copy interlaced buffer to VRAM
; ============================================================================
copy_image_to_vram:
    pusha
    push es
    
    ; Clear full VRAM first (fixes 384-byte garbage at end)
    mov ax, VIDEO_SEG
    mov es, ax
    xor di, di
    xor ax, ax
    mov cx, 8192            ; 16KB / 2
    rep stosw
    
    ; Copy even rows (first 8000 bytes to VRAM 0x0000)
    mov si, image_buffer
    xor di, di
    mov cx, 4000
    rep movsw
    
    ; Copy odd rows (next 8000 bytes to VRAM 0x2000)
    mov si, image_buffer + 8192
    mov di, 0x2000
    mov cx, 4000
    rep movsw
    
    pop es
    popa
    ret

; ============================================================================
; set_bmp_palette - Load palette from BMP header
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
    lodsb                   ; Blue
    mov bl, al
    lodsb                   ; Green
    mov bh, al
    lodsb                   ; Red
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
    
    lodsb                   ; Skip alpha
    loop .pal_loop
    
    mov dx, PORT_REG_ADDR
    mov al, 0x80
    out dx, al
    
    sti
    popa
    ret

; ============================================================================
; set_cga_palette - Restore standard CGA text mode colors
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

msg_usage       db 'DEMO7A - R12/R13 Hardware Scroll Test', 13, 10
                db 'Usage: DEMO7A filename.bmp', 13, 10
                db 'BMP must be 160x200 or 320x200, 4-bit', 13, 10
                db 'UP/DOWN or <,> to scroll, ESC to exit', 13, 10, '$'

msg_file_err    db 'Error: Cannot open file', 13, 10, '$'
msg_not_bmp     db 'Error: Not a valid BMP file', 13, 10, '$'
msg_format      db 'Error: Must be 4-bit uncompressed BMP', 13, 10, '$'
msg_size        db 'Error: Must be 160x200 or 320x200', 13, 10, '$'

; Standard CGA palette (16 colors × 2 bytes)
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

filename_ptr    dw 0
file_handle     dw 0
image_width     dw 0
bytes_per_row   dw 0
current_row     dw 0
downsample_flag db 0
scroll_offset   dw 0

bmp_header      times 128 db 0
row_buffer      times 164 db 0
image_buffer    times IMAGE_SIZE db 0
