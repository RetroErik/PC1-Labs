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
;   - Screen shake (earthquake/explosion effect)
;   - Horizontal wave (wobbly effect)
;   - Slide-in transition (image slides from left)
;   - Bounce (horizontal bounce animation)
;   - Marquee (ping-pong scroll)
;
; CRTC Start Address Notes:
;   R12 = Start Address High byte (bits 15-8 of VRAM offset)
;   R13 = Start Address Low byte (bits 7-0 of VRAM offset)
;   Standard start = 0x0000 (top of VRAM)
;   Row offset = 80 bytes (160 pixels / 2 pixels per byte)
;   LIMITATION: 384-byte gap at 0x1F40 causes artifacts beyond ~5 row offset
;
; Controls:
;   S     - Toggle screen shake on/off
;   H     - Toggle horizontal wave on/off
;   T     - Trigger slide-in transition
;   B     - Bounce effect
;   M     - Marquee (ping-pong scroll)
;   1-9   - Shake intensity levels
;   V     - Toggle VSync on/off
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
    ; Wait for VBlank (if enabled)
    cmp byte [vsync_enabled], 0
    je .skip_vsync
    call wait_vblank
.skip_vsync:
    
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
    ; Handle horizontal wave if active
    cmp byte [hwave_active], 0
    je .check_split
    call do_horizontal_wave
    
.check_split:
    ; Handle slide-in if active
    cmp byte [split_active], 0
    je .check_bounce
    call do_split_screen
    
.check_bounce:
    ; Handle bounce if active
    cmp byte [bounce_active], 0
    je .check_marquee
    call do_bounce
    
.check_marquee:
    ; Handle marquee if active
    cmp byte [marquee_active], 0
    je .check_keys
    call do_marquee
    
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
    
    ; Check for 'V' or 'v' - toggle vsync
    cmp al, 'V'
    je .toggle_vsync
    cmp al, 'v'
    je .toggle_vsync
    
    ; Check for 'H' or 'h' - toggle horizontal wave
    cmp al, 'H'
    je .toggle_hwave
    cmp al, 'h'
    je .toggle_hwave
    
    ; Check for 'T' or 't' - trigger slide-in
    cmp al, 'T'
    je .toggle_split
    cmp al, 't'
    je .toggle_split
    
    ; Check for 'B' or 'b' - trigger bounce
    cmp al, 'B'
    je .toggle_bounce
    cmp al, 'b'
    je .toggle_bounce
    
    ; Check for 'M' or 'm' - marquee
    cmp al, 'M'
    je .toggle_marquee
    cmp al, 'm'
    je .toggle_marquee
    
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
    
.toggle_vsync:
    xor byte [vsync_enabled], 1
    jmp .main_loop
    
.toggle_hwave:
    xor byte [hwave_active], 1
    cmp byte [hwave_active], 0
    jne .main_loop
    mov byte [need_reset], 1
    jmp .main_loop
    
.toggle_split:
    xor byte [split_active], 1
    cmp byte [split_active], 0
    jne .main_loop
    mov byte [need_reset], 1
    jmp .main_loop
    
.toggle_bounce:
    mov byte [bounce_active], 1
    mov byte [bounce_frame], 0    ; Reset animation
    jmp .main_loop
    
.toggle_marquee:
    xor byte [marquee_active], 1
    cmp byte [marquee_active], 0
    jne .main_loop
    mov byte [need_reset], 1
    jmp .main_loop
    
.do_reset:
    mov byte [shake_active], 0
    mov byte [hwave_active], 0
    mov byte [split_active], 0
    mov byte [bounce_active], 0
    mov byte [marquee_active], 0
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
; do_screen_shake - Apply oscillating screen shake offset
; Creates an earthquake/explosion visual effect
; Alternates between positive offsets each frame for visible shake
; ----------------------------------------------------------------------------
do_screen_shake:
    push ax
    push bx
    
    ; Simple frame-based oscillation: toggle between two offsets
    ; This guarantees visible movement every frame
    xor byte [shake_toggle], 1
    
    ; Get intensity (1-9) and convert to row offset
    mov al, [shake_intensity]
    xor ah, ah
    
    ; If toggle is 0, use positive offset; if 1, use 0
    cmp byte [shake_toggle], 0
    je .use_offset
    xor ax, ax              ; Offset = 0 on alternate frames
    jmp .apply
    
.use_offset:
    ; Multiply intensity by 80 to get byte offset (1-9 rows)
    mov bx, BYTES_PER_ROW
    mul bx                  ; AX = intensity * 80
    
.apply:
    ; Set the CRTC start address
    call set_crtc_start
    
    pop bx
    pop ax
    ret

shake_toggle: db 0

; ----------------------------------------------------------------------------
; do_horizontal_wave - Horizontal wobble effect (SMOOTH version)
; Uses dedicated 64-entry wave table for smooth, slower motion
; Range: 0-8 bytes = 0-16 pixels horizontal shift
; ----------------------------------------------------------------------------
do_horizontal_wave:
    push ax
    push si
    
    ; Increment wave index (wraps at 64)
    inc byte [hwave_index]
    mov al, [hwave_index]
    and al, 0x3F            ; Keep in 0-63 range
    mov [hwave_index], al
    
    ; Look up smooth wave value (0-8, 1-byte steps guaranteed)
    xor ah, ah
    mov si, ax
    mov al, [hwave_table + si]
    
    ; AX = byte offset directly (0-8 bytes = 0-16 pixels)
    xor ah, ah
    call set_crtc_start
    
    pop si
    pop ax
    ret

hwave_index: db 0

; Smooth horizontal wave table (64 entries)
; Triangle wave: 0→8→0 with smooth wrap-around
; Each value appears 3-4 times for slower motion
hwave_table:
    db 0, 0, 0, 0, 1, 1, 1, 1     ; 0-7:   0→1
    db 2, 2, 2, 2, 3, 3, 3, 3     ; 8-15:  2→3
    db 4, 4, 4, 4, 5, 5, 5, 5     ; 16-23: 4→5
    db 6, 6, 6, 6, 7, 7, 8, 8     ; 24-31: 6→7→8
    db 8, 8, 7, 7, 6, 6, 6, 6     ; 32-39: 8→7→6
    db 5, 5, 5, 5, 4, 4, 4, 4     ; 40-47: 5→4
    db 3, 3, 3, 3, 2, 2, 2, 2     ; 48-55: 3→2
    db 1, 1, 1, 1, 0, 0, 0, 0     ; 56-63: 1→0 (wraps smoothly)

; ----------------------------------------------------------------------------
; do_bounce - Bouncing ball physics effect
; Image "drops" and bounces with decreasing height
; Uses a pre-calculated bounce table for smooth motion
; ----------------------------------------------------------------------------
do_bounce:
    push ax
    push si
    
    ; Get current frame in bounce animation
    mov al, [bounce_frame]
    xor ah, ah
    mov si, ax
    
    ; Look up position from bounce table
    mov al, [bounce_table + si]
    
    ; Check for end of animation (255 = done)
    cmp al, 255
    jne .not_done
    
    ; Animation complete
    mov byte [bounce_active], 0
    mov byte [bounce_frame], 0
    mov byte [need_reset], 1
    xor ax, ax
    jmp .apply_bounce
    
.not_done:
    ; Advance to next frame
    inc byte [bounce_frame]
    xor ah, ah
    
.apply_bounce:
    ; Set CRTC start address
    call set_crtc_start
    
    pop si
    pop ax
    ret

; Bounce animation table - simulates drop and 3 bounces
; Values are byte offsets (0-40), 255 = end
; Each value repeated 3x for slower, smoother animation
bounce_table:
    ; Drop (accelerating): 0 to 40
    db 0, 0, 0, 1, 1, 1, 2, 2, 2, 4, 4, 4
    db 6, 6, 6, 9, 9, 9, 12, 12, 12, 16, 16, 16
    db 20, 20, 20, 25, 25, 25, 30, 30, 30, 36, 36, 36
    db 40, 40, 40
    ; Bounce 1 up: 40 to 20
    db 36, 36, 36, 32, 32, 32, 28, 28, 28
    db 25, 25, 25, 22, 22, 22, 20, 20, 20
    ; Bounce 1 down: 20 to 40
    db 22, 22, 22, 25, 25, 25, 28, 28, 28
    db 32, 32, 32, 36, 36, 36, 40, 40, 40
    ; Bounce 2 up: 40 to 30
    db 37, 37, 37, 34, 34, 34, 32, 32, 32, 30, 30, 30
    ; Bounce 2 down: 30 to 40
    db 32, 32, 32, 34, 34, 34, 37, 37, 37, 40, 40, 40
    ; Bounce 3 up: 40 to 36
    db 38, 38, 38, 36, 36, 36
    ; Bounce 3 down: 36 to 40
    db 38, 38, 38, 40, 40, 40
    ; Settle
    db 40, 40, 40, 40, 40, 40, 40, 40, 40
    ; Return to center (slower)
    db 35, 35, 35, 30, 30, 30, 25, 25, 25
    db 20, 20, 20, 15, 15, 15, 10, 10, 10
    db 5, 5, 5, 0, 0, 0
    ; End marker
    db 255

bounce_frame: db 0

; Legacy variables (kept for compatibility)
bounce_pos: db 0
bounce_vel: db 0

; ----------------------------------------------------------------------------
; do_marquee - Continuous scroll left and right
; Ping-pong scroll effect, avoids wrap-around glitches from CGA interleaving
; Scrolls 0 to 40 bytes (80 pixels) and back
; ----------------------------------------------------------------------------
do_marquee:
    push ax
    
    ; Check direction and update position
    cmp byte [marquee_dir], 0
    jne .go_right
    
    ; Going left (increasing offset)
    inc byte [marquee_pos]
    cmp byte [marquee_pos], 40
    jb .apply_marquee
    mov byte [marquee_dir], 1   ; Reverse direction
    jmp .apply_marquee
    
.go_right:
    ; Going right (decreasing offset)
    dec byte [marquee_pos]
    cmp byte [marquee_pos], 0
    ja .apply_marquee
    mov byte [marquee_dir], 0   ; Reverse direction
    
.apply_marquee:
    mov al, [marquee_pos]
    xor ah, ah
    call set_crtc_start
    
    pop ax
    ret

marquee_pos: db 0
marquee_dir: db 0               ; 0 = left, 1 = right

; ----------------------------------------------------------------------------
; do_split_screen - Slide-in effect
; Smoothly slides image from left (offset 40) back to center (offset 0)
; Press T to trigger slide animation
; ----------------------------------------------------------------------------
do_split_screen:
    push ax
    
    ; If slide not running, start it
    cmp byte [slide_pos], 0
    jne .continue_slide
    mov byte [slide_pos], 40    ; Start at 40 bytes (80 pixels) left
    
.continue_slide:
    ; Set current slide position
    mov al, [slide_pos]
    xor ah, ah
    call set_crtc_start
    
    ; Decrement position (slide back to center)
    dec byte [slide_pos]
    
    ; If reached 0, disable effect
    cmp byte [slide_pos], 0
    jne .done
    mov byte [split_active], 0
    mov byte [need_reset], 1
    
.done:
    pop ax
    ret

slide_pos: db 0
split_toggle: db 0
; Sine table (256 entries, 0-100 range, centered at 50)
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
            db '  S     - Screen shake (earthquake)', 0x0D, 0x0A
            db '  H     - Horizontal wave (wobbly)', 0x0D, 0x0A
            db '  T     - Slide-in transition', 0x0D, 0x0A
            db '  B     - Bounce effect', 0x0D, 0x0A
            db '  M     - Marquee (ping-pong scroll)', 0x0D, 0x0A
            db '  1-9   - Shake intensity', 0x0D, 0x0A
            db '  V     - Toggle VSync', 0x0D, 0x0A
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
hwave_active    db 0            ; 1 = horizontal wave active
split_active    db 0            ; 1 = slide-in transition active
bounce_active   db 0            ; 1 = bounce effect active
marquee_active  db 0            ; 1 = marquee scroll active
vsync_enabled   db 1            ; 1 = vsync on (default), 0 = free running

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
