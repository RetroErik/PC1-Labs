; ============================================================================
; DEMO9.ASM - R12/R13 Effects Demo for Olivetti Prodest PC1
; Explores CRTC Start Address register effects on V6355D
; Written for NASM - NEC V40 (80186 compatible) @ 8 MHz
; By Retro Erik - 2026 with help from GitHub Copilot
;
; Target: Olivetti PC1 with Yamaha V6355D video controller
; Video Mode: CGA 160x200x16 (Hidden mode)
;
; Technique:
;   Uses CRTC registers R12 (Start Address High) and R13 (Start Address Low)
;   to manipulate which part of VRAM is displayed, enabling:
;   - Screen shake (explosion effect)
;   - Vertical wipe transitions
;   - Split screen (status bar) - if HBlank timing works
;
; CRTC Start Address Notes:
;   R12 = Start Address High byte (bits 15-8 of VRAM offset)
;   R13 = Start Address Low byte (bits 7-0 of VRAM offset)
;   Standard start = 0x0000 (top of VRAM)
;   Row offset = 80 bytes (160 pixels / 2 pixels per byte)
;   NOTE: CGA interleaving may affect this! Need to test.
;
; Controls:
;   S     - Toggle screen shake on/off
;   W     - Trigger vertical wipe transition
;   1-9   - Shake intensity levels
;   R     - Reset to normal view
;   ESC   - Exit to DOS
;
; Usage: DEMO9 image.bmp
;
; Prerequisites:
;   Run PERITEL.COM first to set horizontal position correctly
; ============================================================================

[BITS 16]
[CPU 8086]
[ORG 0x100]

; ============================================================================
; Constants - Hardware definitions
; ============================================================================
VIDEO_SEG       equ 0xB000      ; PC1 video RAM segment

; Yamaha V6355D I/O Ports
PORT_REG_ADDR   equ 0x3D4       ; CRTC register address (standard CGA port)
PORT_REG_DATA   equ 0x3D5       ; CRTC register data (standard CGA port)
PORT_MODE       equ 0x3D8       ; Mode control register
PORT_COLOR      equ 0x3D9       ; Color select (border/overscan color)
PORT_STATUS     equ 0x3DA       ; Status (bit 0=hsync, bit 3=vblank)

; Alternate port addresses for palette
PORT_PAL_ADDR   equ 0xDD        ; Palette register address (8-bit alias)
PORT_PAL_DATA   equ 0xDE        ; Palette register data (8-bit alias)

; CRTC Register numbers
CRTC_START_HI   equ 12          ; R12: Start Address High
CRTC_START_LO   equ 13          ; R13: Start Address Low

; BMP File Header offsets
BMP_SIGNATURE   equ 0
BMP_DATA_OFFSET equ 10
BMP_WIDTH       equ 18
BMP_HEIGHT      equ 22
BMP_BPP         equ 28
BMP_COMPRESSION equ 30

; Screen parameters
SCREEN_WIDTH    equ 160
SCREEN_HEIGHT   equ 200
BYTES_PER_ROW   equ 80          ; 160 pixels * 4 bits / 8 = 80 bytes
SCREEN_SIZE     equ 16384       ; Full video RAM (16KB)

; ============================================================================
; Shake Configuration
; ============================================================================
SHAKE_MAX       equ 10          ; Maximum shake intensity (rows)

; ============================================================================
; Main Program Entry Point
; ============================================================================
main:
    ; Parse command line for filename
    mov si, 0x81
    
.skip_spaces:
    lodsb
    cmp al, ' '
    je .skip_spaces
    cmp al, 0x0D
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
    mov byte [si], 0
    jmp .open_file

.show_usage:
    mov dx, msg_info
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
    
    ; Read BMP header + palette
    mov bx, ax
    mov dx, bmp_header
    mov cx, 118
    mov ah, 0x3F
    int 0x21
    jc .file_error
    cmp ax, 118
    jb .file_error
    
    ; Verify BMP signature
    cmp word [bmp_header + BMP_SIGNATURE], 0x4D42
    jne .not_bmp
    
    ; Check bits per pixel
    cmp word [bmp_header + BMP_BPP], 4
    jne .wrong_format
    
    ; Check compression
    cmp word [bmp_header + BMP_COMPRESSION], 0
    jne .wrong_format
    
    ; Seek to pixel data
    mov bx, [file_handle]
    mov dx, [bmp_header + BMP_DATA_OFFSET]
    mov cx, [bmp_header + BMP_DATA_OFFSET + 2]
    mov ax, 0x4200
    int 0x21
    jc .file_error
    
    ; Enable graphics mode (blanked)
    call enable_graphics_mode
    
    ; Wait for VBlank
    call wait_vblank
    
    ; Set palette from BMP
    call set_bmp_palette
    
    ; Force palette 0 to black
    call force_black_palette0
    
    ; Clear screen
    call clear_screen
    
    ; Display BMP image
    call decode_bmp
    
    ; Close file
    mov bx, [file_handle]
    mov ah, 0x3E
    int 0x21
    
    ; Enable video
    mov dx, PORT_MODE
    mov al, 0x4A
    out dx, al
    
    ; ========================================================================
    ; PHASE 2: R12/R13 Effects Loop
    ; ========================================================================
.main_loop:
    ; Wait for VBlank (all CRTC changes should happen during VBlank)
    call wait_vblank
    
    ; Handle screen shake if enabled
    cmp byte [shake_active], 0
    je .no_shake
    call do_screen_shake
    jmp .check_wipe
    
.no_shake:
    ; If shake just disabled, reset to normal
    cmp byte [need_reset], 1
    jne .check_wipe
    call reset_crtc_start
    mov byte [need_reset], 0
    
.check_wipe:
    ; Handle vertical wipe if in progress
    cmp byte [wipe_active], 0
    je .check_keys
    call do_vertical_wipe
    
.check_keys:
    ; Check for keypress
    mov ah, 0x01
    int 0x16
    jz .main_loop
    
    ; Get key
    mov ah, 0x00
    int 0x16
    
    ; Check for ESC
    cmp al, 27
    je .exit_program
    
    ; Check for 'S' or 's' - toggle shake
    cmp al, 'S'
    je .toggle_shake
    cmp al, 's'
    je .toggle_shake
    
    ; Check for 'W' or 'w' - start wipe
    cmp al, 'W'
    je .start_wipe
    cmp al, 'w'
    je .start_wipe
    
    ; Check for 'R' or 'r' - reset
    cmp al, 'R'
    je .do_reset
    cmp al, 'r'
    je .do_reset
    
    ; Check for '1'-'9' - shake intensity
    cmp al, '1'
    jb .main_loop
    cmp al, '9'
    ja .main_loop
    
    ; Set shake intensity (1-9)
    sub al, '0'
    mov [shake_intensity], al
    jmp .main_loop
    
.toggle_shake:
    xor byte [shake_active], 1
    cmp byte [shake_active], 0
    jne .main_loop
    mov byte [need_reset], 1    ; Flag to reset when shake stops
    jmp .main_loop
    
.start_wipe:
    mov byte [wipe_active], 1
    mov word [wipe_offset], 0
    jmp .main_loop
    
.do_reset:
    mov byte [shake_active], 0
    mov byte [wipe_active], 0
    call reset_crtc_start
    jmp .main_loop
    
.exit_program:
    ; Reset CRTC start address
    call reset_crtc_start
    
    ; Restore CGA palette
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
; R12/R13 EFFECT ROUTINES
; ============================================================================

; ----------------------------------------------------------------------------
; set_crtc_start - Set CRTC start address (R12/R13)
; Input: AX = start address (byte offset in VRAM)
; Must be called during VBlank to avoid tearing!
; ----------------------------------------------------------------------------
set_crtc_start:
    push ax
    push dx
    
    ; Save low byte
    mov [temp_lo], al
    
    ; Set R12 (high byte)
    mov dx, PORT_REG_ADDR
    mov al, CRTC_START_HI
    out dx, al
    
    mov dx, PORT_REG_DATA
    mov al, ah              ; High byte of start address
    out dx, al
    
    ; Set R13 (low byte)
    mov dx, PORT_REG_ADDR
    mov al, CRTC_START_LO
    out dx, al
    
    mov dx, PORT_REG_DATA
    mov al, [temp_lo]       ; Low byte of start address
    out dx, al
    
    pop dx
    pop ax
    ret

temp_lo: db 0

; ----------------------------------------------------------------------------
; reset_crtc_start - Reset CRTC start address to 0
; ----------------------------------------------------------------------------
reset_crtc_start:
    push ax
    xor ax, ax
    call set_crtc_start
    pop ax
    ret

; ----------------------------------------------------------------------------
; do_screen_shake - Apply random screen shake offset
; Creates an earthquake/explosion visual effect
; Uses lookup table to avoid division issues with certain intensity values
; ----------------------------------------------------------------------------
do_screen_shake:
    push ax
    push bx
    push cx
    
    ; Get pseudo-random value using simple LFSR
    mov ax, [random_seed]
    mov bx, ax
    shl ax, 1
    shl ax, 1
    shl ax, 1
    xor ax, bx
    shl ax, 1
    xor ax, bx
    mov [random_seed], ax
    
    ; Use intensity as a mask: AND with (2^n - 1) based on intensity
    ; This avoids division which was causing issues with certain values
    mov bl, [shake_intensity]
    xor bh, bh
    mov si, bx
    mov bl, [intensity_mask + si]   ; Get mask for this intensity
    and al, bl                      ; AL = 0 to mask value
    
    ; Convert to row offset (multiply by 80 bytes per row)
    xor ah, ah
    mov bx, BYTES_PER_ROW
    mul bx                  ; AX = row offset in bytes
    
    ; Clamp to safe range (stay within first bank, avoid 384-byte gap)
    ; Max safe offset = ~1600 bytes = 20 rows
    cmp ax, 1600
    jbe .in_range
    mov ax, 1600
.in_range:
    
    ; Set the CRTC start address
    call set_crtc_start
    
    pop cx
    pop bx
    pop ax
    ret

; ----------------------------------------------------------------------------
; do_vertical_wipe - Gradually scroll down to reveal "new" screen
; Simulates a curtain-opening or scene transition
; ----------------------------------------------------------------------------
do_vertical_wipe:
    push ax
    push bx
    
    ; Increment wipe offset
    mov ax, [wipe_offset]
    add ax, BYTES_PER_ROW   ; Move down one row per frame
    
    ; Check if wipe is complete
    ; Due to 384-byte gap, we can only safely scroll ~20 rows (1600 bytes)
    ; This creates a partial wipe effect but avoids garbage
    cmp ax, 20 * BYTES_PER_ROW
    jb .wipe_continue
    
    ; Wipe complete - reset
    xor ax, ax
    mov byte [wipe_active], 0
    
.wipe_continue:
    mov [wipe_offset], ax
    call set_crtc_start
    
    pop bx
    pop ax
    ret

; ============================================================================
; Video Utility Routines
; ============================================================================

; ----------------------------------------------------------------------------
; wait_vblank - Wait for vertical blanking interval
; ----------------------------------------------------------------------------
wait_vblank:
    push ax
    push dx
    
    mov dx, PORT_STATUS
    
.wait_end:
    in al, dx
    test al, 0x08
    jnz .wait_end
    
.wait_start:
    in al, dx
    test al, 0x08
    jz .wait_start
    
    pop dx
    pop ax
    ret

; ----------------------------------------------------------------------------
; enable_graphics_mode - Enable 160x200x16 hidden mode
; ----------------------------------------------------------------------------
enable_graphics_mode:
    push ax
    push dx
    
    mov dx, PORT_MODE
    mov al, 0x4A
    out dx, al
    
    pop dx
    pop ax
    ret

; ----------------------------------------------------------------------------
; clear_screen - Fill video RAM with color 0
; ----------------------------------------------------------------------------
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
; Palette Routines
; ============================================================================

; ----------------------------------------------------------------------------
; set_bmp_palette - Set palette from BMP file
; ----------------------------------------------------------------------------
set_bmp_palette:
    push ax
    push bx
    push cx
    push dx
    push si
    
    cli
    
    mov al, 0x40
    out PORT_PAL_ADDR, al
    jmp short $+2
    
    mov si, bmp_header + 54
    mov cx, 16
    
.palette_loop:
    lodsb                   ; Blue
    mov bl, al
    
    lodsb                   ; Green
    mov bh, al
    
    lodsb                   ; Red
    push cx
    mov cl, 5
    shr al, cl
    pop cx
    out PORT_PAL_DATA, al
    jmp short $+2
    
    mov al, bh              ; Green
    and al, 0xE0
    push cx
    mov cl, 1
    shr al, cl
    pop cx
    mov ah, al
    
    mov al, bl              ; Blue
    push cx
    mov cl, 5
    shr al, cl
    pop cx
    or al, ah
    out PORT_PAL_DATA, al
    jmp short $+2
    
    lodsb                   ; Skip alpha
    
    loop .palette_loop
    
    mov al, 0x80
    out PORT_PAL_ADDR, al
    
    sti
    
    pop si
    pop dx
    pop cx
    pop bx
    pop ax
    ret

; ----------------------------------------------------------------------------
; force_black_palette0 - Force palette entry 0 to black
; ----------------------------------------------------------------------------
force_black_palette0:
    push ax
    
    cli
    
    mov al, 0x40
    out PORT_PAL_ADDR, al
    jmp short $+2
    
    xor al, al
    out PORT_PAL_DATA, al
    jmp short $+2
    
    xor al, al
    out PORT_PAL_DATA, al
    jmp short $+2
    
    mov al, 0x80
    out PORT_PAL_ADDR, al
    
    sti
    
    pop ax
    ret

; ----------------------------------------------------------------------------
; set_cga_palette - Restore standard CGA palette
; ----------------------------------------------------------------------------
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
    
    mov al, 0x80
    out PORT_PAL_ADDR, al
    
    sti
    
    pop si
    pop cx
    pop ax
    ret

; ============================================================================
; BMP Decoding
; ============================================================================

decode_bmp:
    push ax
    push bx
    push cx
    push dx
    push di
    push si
    push es
    
    mov ax, VIDEO_SEG
    mov es, ax
    
    mov ax, [bmp_header + BMP_WIDTH]
    mov [image_width], ax
    
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
    
    mov ax, [image_width]
    inc ax
    shr ax, 1
    add ax, 3
    and ax, 0xFFFC
    cmp ax, 164
    jbe .bpr_ok
    mov ax, 164
.bpr_ok:
    mov [bytes_per_row], ax
    
    mov ax, [image_height]
    dec ax
    mov [current_row], ax
    
.row_loop:
    mov ax, [current_row]
    push ax
    shr ax, 1
    mov bx, 80
    mul bx
    mov di, ax
    
    pop ax
    test al, 1
    jz .is_even_row
    add di, 0x2000
.is_even_row:
    
    mov bx, [file_handle]
    mov dx, row_buffer
    mov cx, [bytes_per_row]
    mov ah, 0x3F
    int 0x21
    jc .decode_done
    or ax, ax
    jz .decode_done
    
    ; Border color cycling during load
    mov al, [border_ctr]
    out PORT_COLOR, al
    inc byte [border_ctr]
    and byte [border_ctr], 0x0F
    
    cmp byte [downsample_flag], 0
    je .no_downsample
    
    ; Downsample 320 -> 160
    mov si, row_buffer
    mov cx, 80
    
.downsample_loop:
    lodsb
    push ax
    and al, 0xF0
    mov ah, al
    lodsb
    shr al, 1
    shr al, 1
    shr al, 1
    shr al, 1
    or al, ah
    mov [es:di], al
    inc di
    pop ax
    loop .downsample_loop
    jmp .row_done
    
.no_downsample:
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

msg_info    db 'DEMO9 - R12/R13 Effects Demo for Olivetti Prodest PC1', 0x0D, 0x0A
            db 'Usage: DEMO9 image.bmp', 0x0D, 0x0A
            db 0x0D, 0x0A
            db 'Controls:', 0x0D, 0x0A
            db '  S     - Toggle screen shake', 0x0D, 0x0A
            db '  W     - Vertical wipe transition', 0x0D, 0x0A
            db '  1-9   - Shake intensity', 0x0D, 0x0A
            db '  R     - Reset to normal', 0x0D, 0x0A
            db '  ESC   - Exit to DOS', 0x0D, 0x0A, '$'

msg_file_err db 'Error: Cannot open file', 0x0D, 0x0A, '$'
msg_not_bmp  db 'Error: Not a valid BMP file', 0x0D, 0x0A, '$'
msg_format   db 'Error: BMP must be 4-bit uncompressed', 0x0D, 0x0A, '$'

; File handling
filename_ptr    dw 0
file_handle     dw 0
image_width     dw 0
image_height    dw 0
bytes_per_row   dw 0
current_row     dw 0
downsample_flag db 0
border_ctr      db 0

; Effect state variables
shake_active    db 0            ; 1 = shake enabled
shake_intensity db 3            ; Shake intensity (1-9 rows)
need_reset      db 0            ; Flag to reset CRTC after shake stops
wipe_active     db 0            ; 1 = wipe in progress
wipe_offset     dw 0            ; Current wipe offset

; Random number generator seed
random_seed     dw 0x1234       ; Initial seed

; Intensity mask table - maps intensity 1-9 to bit masks
; Using masks avoids division which caused issues with certain values
; Mask values give range 0..N rows of shake
intensity_mask:
    db 0        ; 0: unused
    db 0x01     ; 1: 0-1 rows
    db 0x01     ; 2: 0-1 rows
    db 0x03     ; 3: 0-3 rows
    db 0x03     ; 4: 0-3 rows
    db 0x07     ; 5: 0-7 rows
    db 0x07     ; 6: 0-7 rows
    db 0x0F     ; 7: 0-15 rows
    db 0x0F     ; 8: 0-15 rows
    db 0x1F     ; 9: 0-31 rows (but clamped to 20 for safety)

; Standard CGA palette
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

; Buffers
bmp_header:     times 128 db 0
row_buffer:     times 164 db 0

; ============================================================================
; End of Program
; ============================================================================
