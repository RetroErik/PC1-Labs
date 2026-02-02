; ============================================================================
; DEMO7.ASM - R12/R13 Hardware Scroll Test (160×512 support) - not with auto scrolling
; Olivetti Prodest PC1 - V6355D 160x200x16 Hidden Graphics Mode
; Written for NASM - NEC V40 @ 8 MHz (80186 instruction set)
; By RetroErik - 2026
;
; Description:
;   Loads a 160×200-800 BMP, stores in allocated RAM (up to 64KB),
;   copies 200-row viewport to VRAM, scrolls using keyboard.
;   Press UP/DOWN arrows or <,> to scroll manually.
;   Press SPACE to start/stop smooth auto-scrolling.
;   ESC/Q to exit.
;
; This proves that V6355D's "6845 restricted mode" supports hardware
; scrolling via standard CGA CRTC Start Address registers.
;
; MEMORY LAYOUT:
;   - Shrink COM program to free DOS memory
;   - Allocate up to 64KB for 160×800 interlaced buffer
;   - Copy 200-row viewport to VRAM for display
; ============================================================================

[BITS 16]
[CPU 186]
[ORG 0x100]

; ============================================================================
; Constants
; ============================================================================

VIDEO_SEG       equ 0xB000
BYTES_PER_LINE  equ 80
VRAM_SIZE       equ 16384       ; 16KB VRAM
MAX_IMAGE_HEIGHT equ 800        ; Maximum supported height (800×80=64000 bytes)
STACK_RESERVE   equ 64          ; Paragraphs reserved for stack (1KB)
SCROLL_SPEED    equ 2           ; Rows per frame for auto-scroll
FRAME_DELAY     equ 2           ; Delay loops between frames

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
    ; Shrink memory block to free up space for 40KB buffer
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
    
    mov ax, [bmp_header + BMP_HEIGHT]
    cmp ax, 200
    jb .wrong_size              ; Too short
    cmp ax, MAX_IMAGE_HEIGHT
    ja .wrong_size              ; Too tall
    mov [image_height], ax
    
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
    
    ; Calculate max scroll row (image_height - 200)
    mov ax, [image_height]
    sub ax, 200
    jns .has_scroll_range
    xor ax, ax
.has_scroll_range:
    mov [max_scroll_row], ax
    
    ; Reset scroll position
    mov word [scroll_row], 0
    
    ; Copy initial viewport to VRAM
    call copy_viewport_to_vram
    
    ; Enable video
    mov dx, PORT_MODE
    mov al, 0x4A
    out dx, al
    
    ; ========================================================================
    ; Main loop - keyboard scroll test with auto-scroll support
    ; ========================================================================
.main_loop:
    ; Check if auto-scrolling is active
    cmp byte [auto_scroll], 0
    jne .do_auto_scroll
    
    ; Manual mode: wait for keypress
    mov ah, 0x01
    int 0x16
    jz .main_loop
    jmp .handle_key

.do_auto_scroll:
    ; Auto-scroll mode: check for key but don't wait
    mov ah, 0x01
    int 0x16
    jz .auto_step
    
.handle_key:
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
    
    ; Check for space (toggle auto-scroll)
    cmp al, ' '
    je .toggle_auto
    
    ; Check for scroll keys (manual)
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

.auto_step:
    ; Frame delay for smooth animation
    mov cx, FRAME_DELAY
.delay_loop:
    call wait_vsync
    loop .delay_loop
    
    ; Move in current direction
    mov ax, [scroll_row]
    cmp byte [scroll_dir], 0
    jne .auto_up
    
    ; Moving down
    add ax, SCROLL_SPEED
    cmp ax, [max_scroll_row]
    jbe .auto_update
    mov ax, [max_scroll_row]
    mov byte [scroll_dir], 1    ; Reverse to up
    jmp .auto_update
    
.auto_up:
    ; Moving up
    sub ax, SCROLL_SPEED
    jns .auto_update
    xor ax, ax
    mov byte [scroll_dir], 0    ; Reverse to down
    
.auto_update:
    mov [scroll_row], ax
    call copy_viewport_to_vram
    jmp .main_loop

.scroll_up:
    mov byte [auto_scroll], 0   ; Stop auto-scroll on manual input
    mov ax, [scroll_row]
    sub ax, 2               ; Move up 2 rows (keep bank alignment)
    jns .update_scroll
    xor ax, ax              ; Clamp at 0
    jmp .update_scroll

.scroll_down:
    mov byte [auto_scroll], 0   ; Stop auto-scroll on manual input
    mov ax, [scroll_row]
    add ax, 2               ; Move down 2 rows (keep bank alignment)
    cmp ax, [max_scroll_row]
    jbe .update_scroll
    mov ax, [max_scroll_row]

.update_scroll:
    mov [scroll_row], ax
    call copy_viewport_to_vram
    jmp .main_loop

.exit:
    ; Free allocated memory
    mov ax, [image_buffer_seg]
    or ax, ax
    jz .no_free
    mov es, ax
    mov ah, 0x49            ; DOS Free Memory
    int 0x21
.no_free:
    
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
; wait_vsync - Wait for vertical retrace (smooth animation)
; ============================================================================
wait_vsync:
    push ax
    push dx
    
    mov dx, PORT_STATUS
    
    ; Wait for end of current retrace (if in retrace)
.wait_end:
    in al, dx
    test al, 8
    jnz .wait_end
    
    ; Wait for start of new retrace
.wait_start:
    in al, dx
    test al, 8
    jz .wait_start
    
    pop dx
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
; shrink_memory_block - Release unused memory for DOS allocation
; ============================================================================
shrink_memory_block:
    push ax
    push bx
    push es
    
    mov ax, cs
    mov es, ax
    
    ; Calculate paragraphs needed: (end_program + PSP + stack) / 16
    mov bx, end_program + 0x100
    add bx, 15
    shr bx, 4
    add bx, STACK_RESERVE
    
    mov ah, 0x4A                ; DOS Resize Memory Block
    int 0x21
    
    pop es
    pop bx
    pop ax
    ret

; ============================================================================
; decode_bmp - Allocate RAM and read BMP to interlaced buffer
;
; For images > 200 rows, we need DOS-allocated memory.
; Layout: interlaced like VRAM (even rows at 0, odd rows at half-size offset)
; ============================================================================
decode_bmp:
    pusha
    push es
    
    ; Calculate bytes per row in BMP file
    mov ax, [image_width]
    inc ax
    shr ax, 1
    add ax, 3
    and ax, 0xFFFC
    mov [bytes_per_row], ax
    
    ; Calculate buffer size and odd bank offset
    ; Even rows: 0 to (height/2) * 80
    ; Odd rows: (height/2) * 80 to height * 80
    mov ax, [image_height]
    shr ax, 1                   ; height / 2
    mov bx, BYTES_PER_LINE
    mul bx                      ; AX = (height/2) * 80 = odd bank offset
    mov [odd_bank_offset], ax
    
    ; Total size = height * 80
    mov ax, [image_height]
    mov bx, BYTES_PER_LINE
    mul bx
    mov [image_size_bytes], ax
    
    ; Allocate memory (convert bytes to paragraphs)
    mov bx, ax
    add bx, 15
    shr bx, 4
    mov ah, 0x48                ; DOS Allocate Memory
    int 0x21
    jc .alloc_error
    mov [image_buffer_seg], ax
    
    ; Start from last row (BMP is bottom-up)
    mov ax, [image_height]
    dec ax
    mov [current_row], ax
    
.row_loop:
    ; Calculate destination offset in interlaced format
    ; Even rows: (row/2) * 80
    ; Odd rows: odd_bank_offset + (row/2) * 80
    mov ax, [current_row]
    mov bx, ax                  ; Save row number
    shr ax, 1                   ; row / 2
    mov dx, BYTES_PER_LINE
    mul dx                      ; AX = (row/2) * 80
    mov di, ax
    test bx, 1                  ; Is row odd?
    jz .even_row
    add di, [odd_bank_offset]
.even_row:
    
    ; Read row from file to row_buffer
    mov bx, [file_handle]
    mov dx, row_buffer
    mov cx, [bytes_per_row]
    mov ah, 0x3F
    int 0x21
    jc .decode_done
    or ax, ax
    jz .decode_done
    
    ; Set ES to allocated buffer segment
    mov es, [image_buffer_seg]
    
    ; Copy or downsample to allocated buffer (ES:DI)
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
; copy_viewport_to_vram - Copy 200-row viewport from RAM buffer to VRAM
;
; Input: [scroll_row] = starting row in image (0 to height-200)
; Copies rows [scroll_row .. scroll_row+199] to VRAM
; ============================================================================
copy_viewport_to_vram:
    pusha
    push ds
    push es
    
    ; Clear full VRAM first
    mov ax, VIDEO_SEG
    mov es, ax
    xor di, di
    xor ax, ax
    mov cx, 8192
    rep stosw
    
    ; Calculate source offset for even rows
    ; scroll_row/2 * 80 = starting offset in even bank
    mov ax, [scroll_row]
    shr ax, 1
    mov bx, BYTES_PER_LINE
    mul bx
    mov si, ax                  ; SI = offset in even bank
    
    ; Set DS to allocated buffer
    mov ax, [image_buffer_seg]
    mov ds, ax
    
    ; Copy 100 even rows (rows 0,2,4...198 of viewport)
    xor di, di                  ; VRAM even bank at 0x0000
    mov cx, 4000                ; 100 rows × 80 bytes / 2
    cld
    rep movsw
    
    ; Calculate source offset for odd rows
    ; odd_bank_offset + scroll_row/2 * 80
    mov ax, [cs:scroll_row]
    shr ax, 1
    mov bx, BYTES_PER_LINE
    mul bx
    add ax, [cs:odd_bank_offset]
    mov si, ax
    
    ; Copy 100 odd rows
    mov di, 0x2000              ; VRAM odd bank at 0x2000
    mov cx, 4000
    rep movsw
    
    pop es
    pop ds
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

msg_usage       db 'DEMO7 - Tall Image Auto-Scroll Demo', 13, 10
                db 'Usage: DEMO7 filename.bmp', 13, 10
                db 'BMP must be 160 wide, 200-800 tall, 4-bit', 13, 10
                db 'UP/DOWN = manual scroll, SPACE = auto-scroll', 13, 10
                db 'ESC to exit', 13, 10, '$'

msg_file_err    db 'Error: Cannot open file', 13, 10, '$'
msg_not_bmp     db 'Error: Not a valid BMP file', 13, 10, '$'
msg_format      db 'Error: Must be 4-bit uncompressed BMP', 13, 10, '$'
msg_size        db 'Error: Must be 160 wide, 200-800 tall', 13, 10, '$'
msg_mem_err     db 'Error: Cannot allocate memory', 13, 10, '$'

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
image_height    dw 0
bytes_per_row   dw 0
current_row     dw 0
downsample_flag db 0

; Tall image scrolling variables
scroll_row      dw 0            ; Current top row of viewport (0 to max_scroll_row)
max_scroll_row  dw 0            ; Maximum scroll row (image_height - 200)
image_buffer_seg dw 0           ; Segment of allocated image buffer
odd_bank_offset dw 0            ; Offset to odd bank in buffer
image_size_bytes dw 0           ; Total image bytes (for freeing)

; Auto-scroll state
auto_scroll     db 0            ; 0 = manual, 1 = auto-scrolling
scroll_dir      db 0            ; 0 = down, 1 = up

bmp_header      times 128 db 0
row_buffer      times 164 db 0   ; Max 320 pixels / 2 = 160 bytes + padding

; Note: image_buffer is dynamically allocated via DOS

; Mark end of program for memory shrinking calculation
end_program:

