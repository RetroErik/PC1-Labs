; ============================================================================
; TEST_R12R13.ASM - R12/R13 Hardware Scroll Test (diagnostic tool)
; Olivetti Prodest PC1 - V6355D 160x200x16 Hidden Graphics Mode
; Written for NASM - NEC V40 @ 8 MHz (80186 instruction set)
; By RetroErik - 2026
;
; Description:
;   Loads a 320×200 BMP directly to VRAM and tests R12/R13 hardware
;   scrolling. No RAM buffer — eliminates memory issues for debugging.
;   Border color changes at each stage for diagnostic feedback.
;   Originally demo7_simple.asm, moved to Tools as a standalone test.
;
; Usage: TEST_R12R13 filename.bmp
;        Comma/Period = scroll, ESC = exit
; ============================================================================

[BITS 16]
[CPU 186]
[ORG 0x100]

; ============================================================================
; Constants
; ============================================================================

VIDEO_SEG       equ 0xB000
BYTES_PER_LINE  equ 80
SCREEN_HEIGHT   equ 200

; Ports
PORT_REG_ADDR   equ 0x3DD
PORT_REG_DATA   equ 0x3DE
PORT_MODE       equ 0x3D8
PORT_COLOR      equ 0x3D9
PORT_CRTC_ADDR  equ 0x3D4
PORT_CRTC_DATA  equ 0x3D5
PORT_STATUS     equ 0x3DA

; CRTC Registers
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
    ; === DIAGNOSTIC: Set border RED at start ===
    mov dx, PORT_COLOR
    mov al, 4               ; Red
    out dx, al

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
    je .found_end
    cmp al, 0x0D
    jne .find_end
.found_end:
    dec si
    mov byte [si], 0
    jmp .open_file

.show_usage:
    mov dx, msg_usage
    mov ah, 0x09
    int 0x21
    mov ax, 0x4C00
    int 0x21

.open_file:
    ; === DIAGNOSTIC: Set border GREEN = file opening ===
    mov dx, PORT_COLOR
    mov al, 2
    out dx, al

    mov dx, [filename_ptr]
    mov ax, 0x3D00
    int 0x21
    jc .file_error
    mov [file_handle], ax

    ; Read BMP header
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

    ; Check width
    mov ax, [bmp_header + BMP_WIDTH]
    cmp ax, 320
    je .width_320
    cmp ax, 160
    je .width_160
    jmp .wrong_size

.width_320:
    mov byte [downsample_flag], 1
    jmp .check_height
.width_160:
    mov byte [downsample_flag], 0

.check_height:
    mov ax, [bmp_header + BMP_HEIGHT]
    cmp ax, 200
    jne .wrong_size

    ; Seek to pixel data
    mov bx, [file_handle]
    mov dx, [bmp_header + BMP_DATA_OFFSET]
    mov cx, [bmp_header + BMP_DATA_OFFSET + 2]
    mov ax, 0x4200
    int 0x21

    ; === DIAGNOSTIC: Set border CYAN = enabling graphics ===
    mov dx, PORT_COLOR
    mov al, 3
    out dx, al

    ; Enable graphics mode
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

    ; Set palette from BMP
    call set_bmp_palette

    ; === DIAGNOSTIC: Set border MAGENTA = loading image ===
    mov dx, PORT_COLOR
    mov al, 5
    out dx, al

    ; Load BMP directly to VRAM (like PC1-BMP does)
    call decode_bmp_to_vram

    ; Close file
    mov bx, [file_handle]
    mov ah, 0x3E
    int 0x21

    ; === DIAGNOSTIC: Set border BLACK = ready ===
    mov dx, PORT_COLOR
    xor al, al
    out dx, al

    ; Initialize scroll offset
    mov word [scroll_offset], 0

    ; Main loop - scroll with comma/period
.main_loop:
    mov ah, 0x01
    int 0x16
    jz .main_loop

    xor ah, ah
    int 0x16

    cmp al, 0x1B            ; ESC
    je .exit
    cmp al, 'q'
    je .exit
    cmp al, 'Q'
    je .exit

    cmp al, ','
    je .scroll_up
    cmp al, '<'
    je .scroll_up
    cmp al, '.'
    je .scroll_down
    cmp al, '>'
    je .scroll_down
    jmp .main_loop

.scroll_up:
    mov ax, [scroll_offset]
    sub ax, BYTES_PER_LINE  ; Scroll up one row
    jns .update_scroll
    xor ax, ax              ; Clamp to 0
    jmp .update_scroll

.scroll_down:
    mov ax, [scroll_offset]
    add ax, BYTES_PER_LINE  ; Scroll down one row
    cmp ax, 8000            ; Max offset (100 rows * 80 bytes, half VRAM)
    jbe .update_scroll
    mov ax, 8000

.update_scroll:
    mov [scroll_offset], ax
    call set_crtc_start_address
    jmp .main_loop

.exit:
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

    ; Write R12
    mov dx, PORT_CRTC_ADDR
    mov al, CRTC_START_HIGH
    out dx, al
    jmp short $+2
    mov dx, PORT_CRTC_DATA
    mov al, bh
    out dx, al
    jmp short $+2

    ; Write R13
    mov dx, PORT_CRTC_ADDR
    mov al, CRTC_START_LOW
    out dx, al
    jmp short $+2
    mov dx, PORT_CRTC_DATA
    mov al, bl
    out dx, al
    jmp short $+2

    pop dx
    pop bx
    pop ax
    ret

; ============================================================================
; set_bmp_palette - Set palette from BMP header
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
; decode_bmp_to_vram - Load BMP directly to video memory
; (Same approach as working PC1-BMP.asm)
; ============================================================================
decode_bmp_to_vram:
    pusha

    mov ax, VIDEO_SEG
    mov es, ax

    ; Calculate bytes per row in file
    mov ax, [bmp_header + BMP_WIDTH]
    inc ax
    shr ax, 1
    add ax, 3
    and ax, 0xFFFC
    mov [bmp_row_bytes], ax

    ; BMP is bottom-up, start at last row (199)
    mov word [current_y], 199

.row_loop:
    ; Read one row from file
    mov bx, [file_handle]
    mov dx, line_buffer
    mov cx, [bmp_row_bytes]
    mov ah, 0x3F
    int 0x21

    ; Calculate VRAM offset for this row
    mov ax, [current_y]
    mov bx, ax
    shr bx, 1               ; BX = row / 2
    mov cx, BYTES_PER_LINE
    push ax
    mov ax, bx
    mul cx                  ; AX = (row/2) * 80
    mov di, ax
    pop ax
    test al, 1              ; Odd row?
    jz .even_row
    add di, 0x2000          ; Odd rows at bank 2
.even_row:

    ; Copy/downsample row to VRAM
    mov si, line_buffer
    cmp byte [downsample_flag], 0
    je .copy_direct

    ; Downsample 320->160
    mov cx, 80
.downsample:
    lodsb                   ; [P1 P0]
    mov ah, al
    and ah, 0xF0            ; Keep P0
    lodsb                   ; [P3 P2]
    and al, 0xF0
    shr al, 4
    or al, ah               ; [P0 P2]
    stosb
    loop .downsample
    jmp .next_row

.copy_direct:
    mov cx, 80
    rep movsb

.next_row:
    dec word [current_y]
    cmp word [current_y], 0
    jge .row_loop

    popa
    ret

; ============================================================================
; Data
; ============================================================================

msg_usage       db 'DEMO7_SIMPLE - Hardware Scroll Test', 13, 10
                db 'Usage: DEMO7_SIMPLE filename.bmp (320x200 or 160x200)', 13, 10
                db 'Comma/Period = scroll, ESC = exit', 13, 10, '$'

msg_file_err    db 'Error: Cannot open file', 13, 10, '$'
msg_not_bmp     db 'Error: Not a valid BMP file', 13, 10, '$'
msg_format      db 'Error: Must be 4-bit BMP', 13, 10, '$'
msg_size        db 'Error: Must be 320x200 or 160x200', 13, 10, '$'

filename_ptr    dw 0
file_handle     dw 0
downsample_flag db 0
bmp_row_bytes   dw 0
current_y       dw 0
scroll_offset   dw 0

bmp_header      times 118 db 0
line_buffer     times 164 db 0
