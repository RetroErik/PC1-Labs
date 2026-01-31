; PC1 Sprite Multiplexing Demo - 2 Bouncing Balls with Random Rainbow Colors
; For Olivetti PC1 with NEC V40 CPU and V6355D video controller
; Assemble with NASM: nasm -f bin BBalls5.asm -o BBalls5.com
; By Retro Erik - 2026 using VS Code with Co-Pilot
; Version 0.6 - Raster-sync with rainbow colors, solid/XOR modes
;
; FEATURES:
; ---------
; - Uses the V6355D hardware mouse cursor sprite as a game sprite
; - True raster-synchronized multiplexing: 2 balls from 1 sprite!
; - Random rainbow color on every bounce (never repeats)
; - Top ball: solid mode, Bottom ball: XOR transparent mode
; - Mode/color changes mid-frame via registers 64h and 68h
;
; HOW RASTER-SYNC MULTIPLEXING WORKS:
; -----------------------------------
; The CRT beam draws the screen top-to-bottom, line by line.
; We "chase" the beam by repositioning the single hardware sprite
; after the beam has already drawn the first ball's position.
;
; Algorithm:
;   1. Wait for vsync (beam returns to top of screen)
;   2. Set Ball 1 color and position sprite (solid mode)
;   3. Wait until beam passes that ball (Y + 16)
;   4. Set Ball 2 color and reposition sprite (XOR transparent mode)
;   5. Result: Both balls visible in ONE frame = no flicker!
;
; VERTICAL ZONES (screen split in half):
;   Ball 1: Y =   8 -  84  (top half, sprite bottom at 100)
;   Ball 2: Y = 100 - 184  (bottom half)
;
; Sprite origin is TOP-LEFT corner (16x16 sprite)

CPU 186

    ORG 100h

start:
    ; Print info text on screen
    call print_info
    
    ; Initialize V6335D sprite hardware directly
    call enable_v6335d
    call load_sprite_shape
    call setup_sprite_attr
    call show_sprite

    ; Initialize ball 1 position and velocity
    ; Positions are in VIRTUAL coordinates
    mov word [ball1_x], 320     ; Center of screen (virtual X)
    mov word [ball1_y], 46      ; Zone 1: top half (8-84)
    mov word [ball1_vx], 2      ; Pixels per frame
    mov word [ball1_vy], 1

    ; Initialize ball 2 position and velocity
    mov word [ball2_x], 450
    mov word [ball2_y], 142     ; Zone 2: bottom half (100-184)
    mov word [ball2_vx], -2
    mov word [ball2_vy], 2

main_loop:
    ; Check for ESC key
    mov ah, 01h             ; Check if key available
    int 16h
    jnz check_key           ; Key pressed

continue_loop:
    ; Update both balls
    call update_ball1
    call update_ball2

    ; Wait for vertical retrace (beam returns to top of screen)
    call wait_vsync
    
    ; ========= TRUE RASTER-SYNC MULTIPLEXING =========
    ; Beam is at TOP of screen after vsync
    
    ; --- Ball 1: Draw immediately (top half) - SOLID ---
    mov al, 06h                 ; AND + XOR mode (solid)
    call set_sprite_mode
    mov al, [color_idx1]        ; Get current color directly
    call set_sprite_color
    mov ax, [ball1_x]
    mov bx, [ball1_y]
    call position_sprite
    
    ; Wait for beam to pass ball 1 (need to reach scanline 100)
    ; Ball 1 max Y = 84, sprite bottom = 100
    ; IMPORTANT: Don't wait too long or beam passes ball 2!
    mov cx, 0800h           ; Reduced delay - try to catch ball 2
.wait_for_bottom:
    nop
    nop
    nop
    nop
    loop .wait_for_bottom
    
    ; --- Ball 2: Beam has passed top half, now draw bottom - TRANSPARENT XOR ---
    mov al, 04h                 ; XOR only mode (transparent)
    call set_sprite_mode
    mov al, [color_idx2]        ; Get current color directly
    call set_sprite_color
    mov ax, [ball2_x]
    mov bx, [ball2_y]
    call position_sprite
    
    ; Colors change on bounce (see update routines)

    jmp main_loop

check_key:
    mov ah, 00h
    int 16h
    cmp ah, 01h             ; ESC scan code
    je exit_program
    jmp continue_loop

exit_program:
    ; Hide sprite before exit
    mov dx, 3DDh
    mov al, 60h             ; Disable sprite (remove enable bit)
    out dx, al

    ; Exit to DOS
    mov ax, 4C00h
    int 21h

; ===== Hardware Sprite Routines =====

; Enable V6335D chip - read from BIOS data and write to port 68h
enable_v6335d:
    push ds
    mov ax, 40h             ; BIOS data segment
    mov ds, ax
    mov bx, 89h             ; Equipment address for PC1
    mov al, [bx]
    pop ds
    and al, 0FEh            ; Clear bit 0
    out 68h, al             ; Enable V6335D and mouse counter
    ret

; Load sprite shape to V6335D sprite memory
; NOTE: First 16 words (screen mask) must be inverted!
load_sprite_shape:
    mov dx, 0DDh
    xor al, al              ; Select sprite memory at index 0
    out dx, al
    inc dx                  ; DX = 0DEh (data port)
    
    mov si, sprite_mask
    mov cx, 32              ; 32 words total (16 screen mask + 16 cursor mask)
    cld
.load_loop:
    lodsw                   ; Load word from sprite_mask
    cmp cx, 10h             ; First 16 words (cx > 16)?
    jbe .no_invert
    not ax                  ; Invert screen mask words
.no_invert:
    xchg al, ah             ; Swap bytes for V6335D
    out dx, al
    xchg al, ah
    out dx, al
    loop .load_loop
    ret

; Setup sprite color/masking attribute register
setup_sprite_attr:
    mov dx, 3DDh            ; Use port 3DDh for register 64h
    mov al, 64h+80h         ; Register 64h with enable bit
    out dx, al
    inc dx
    mov al, 06h             ; Value: mask/and/xor enabled
    out dx, al
    ret

; Set sprite rendering mode via register 64h
; AL = mode (04h = XOR only/transparent, 06h = AND+XOR/solid)
set_sprite_mode:
    push ax
    mov ah, al              ; Save mode in AH
    mov dx, 3DDh
    mov al, 64h+80h         ; Register 64h with enable bit
    out dx, al
    inc dx
    mov al, ah              ; Restore mode
    out dx, al
    pop ax
    ret

; Show sprite on screen - write to register 68h!
show_sprite:
    ; Enable sprite visibility via register 68h
    mov al, 68h+80h         ; Register 68h
    mov ah, 0F0h            ; Cursor attribute: F0 = white/black opaque
    out 0DDh, ax            ; Write AL to 0DDh, AH to 0DEh
    
    ; Position sprite at center
    mov dx, 3DDh
    mov al, 60h+80h         ; Register 60h with enable bit
    out dx, al
    inc dx                  ; DX = 3DEh
    
    ; Initialize position to center (320, 100)
    mov ax, 320
    xchg al, ah
    out dx, al
    xchg al, ah
    out dx, al
    
    mov ax, 100
    xchg al, ah
    out dx, al
    xchg al, ah
    out dx, al
    ret

; Position sprite at AX=X, BX=Y
; Converts from virtual coordinates (0-639, 0-199) to hardware coordinates
; Hardware X = (X / 2) + 15   (CenterX offset)
; Hardware Y = Y + 8          (CenterY offset, approximate)
position_sprite:
    push dx
    
    ; Convert X: divide by 2, add offset
    shr ax, 1               ; X / 2
    add ax, 15              ; Add CenterX offset
    
    ; Convert Y: add offset
    add bx, 8               ; Add CenterY offset
    
    ; Write to register 60h
    mov dx, 3DDh
    push ax
    mov al, 60h+80h         ; Sprite position register
    out dx, al
    pop ax
    inc dx                  ; DX = 3DEh
    
    ; Write X coordinate (word, big-endian)
    xchg al, ah
    out dx, al
    xchg al, ah
    out dx, al
    
    ; Write Y coordinate (word, big-endian)
    mov ax, bx
    xchg al, ah
    out dx, al
    xchg al, ah
    out dx, al
    
    pop dx
    ret

; Set sprite color via register 68h
; AL = color byte (high nibble = foreground, low nibble = background)
set_sprite_color:
    push ax
    mov ah, al              ; Save color in AH
    mov al, 68h+80h         ; Register 68h with enable bit
    out 0DDh, ax            ; Write register select + color
    pop ax
    ret

; Wait for vertical sync (retrace)
; Uses CGA status port 3DAh, bit 3 = vertical retrace
wait_vsync:
    push ax
    push dx
    mov dx, 3DAh            ; CGA status port
    
    ; First wait for retrace to end (if already in retrace)
.wait_no_vsync:
    in al, dx
    test al, 08h            ; Bit 3 = vertical retrace
    jnz .wait_no_vsync
    
    ; Now wait for retrace to start
.wait_vsync_start:
    in al, dx
    test al, 08h
    jz .wait_vsync_start
    
    pop dx
    pop ax
    ret

; ===== Ball Update Routines =====

update_ball1:
    ; Update X position
    mov ax, [ball1_x]
    add ax, [ball1_vx]
    mov [ball1_x], ax

    ; Check X bounds (origin is top-left of 16x16 sprite)
    ; Hardware does X/2, so right bound needs adjustment
    cmp ax, 0               ; Left edge
    jle bounce1_x
    cmp ax, 592             ; Right edge (sprite stays fully visible)
    jge bounce1_x
    jmp check1_y

bounce1_x:
    neg word [ball1_vx]     ; Reverse X velocity
    mov ax, [ball1_x]
    add ax, [ball1_vx]      ; Apply reversed velocity
    add ax, [ball1_vx]      ; Move away from edge
    mov [ball1_x], ax
    call advance_color1     ; Change color on bounce

check1_y:
    ; Update Y position
    mov ax, [ball1_y]
    add ax, [ball1_vy]
    mov [ball1_y], ax

    ; Check Y bounds - ZONE 1: Top half (8 to 84)
    cmp ax, 8
    jle bounce1_y
    cmp ax, 84
    jge bounce1_y
    jmp end_update1

bounce1_y:
    neg word [ball1_vy]     ; Reverse Y velocity
    mov ax, [ball1_y]
    add ax, [ball1_vy]      ; Apply reversed velocity
    add ax, [ball1_vy]      ; Move away from edge
    mov [ball1_y], ax
    call advance_color1     ; Change color on bounce

end_update1:
    ret

update_ball2:
    ; Update X position
    mov ax, [ball2_x]
    add ax, [ball2_vx]
    mov [ball2_x], ax

    ; Check X bounds
    cmp ax, 0
    jle bounce2_x
    cmp ax, 592
    jge bounce2_x
    jmp check2_y

bounce2_x:
    neg word [ball2_vx]
    mov ax, [ball2_x]
    add ax, [ball2_vx]
    add ax, [ball2_vx]
    mov [ball2_x], ax
    call advance_color2     ; Change color on bounce

check2_y:
    ; Update Y position
    mov ax, [ball2_y]
    add ax, [ball2_vy]
    mov [ball2_y], ax

    ; Check Y bounds - ZONE 2: Bottom half (100 to 184)
    cmp ax, 100
    jle bounce2_y
    cmp ax, 184
    jge bounce2_y
    jmp end_update2

bounce2_y:
    neg word [ball2_vy]
    mov ax, [ball2_y]
    add ax, [ball2_vy]
    add ax, [ball2_vy]
    mov [ball2_y], ax
    call advance_color2     ; Change color on bounce

end_update2:
    ret

; Print info text to screen
print_info:
    mov ah, 09h             ; DOS print string function
    mov dx, info_text       ; Pointer to $ terminated string
    int 21h
    ret

; Advance ball 1 color (called on bounce) - random rainbow, never same color
advance_color1:
    mov ah, [color_idx1]    ; Save current color
.retry1:
    call get_random_rainbow
    cmp al, ah              ; Same as current?
    je .retry1              ; Try again
    mov [color_idx1], al
    ret

; Advance ball 2 color (called on bounce) - random rainbow, never same color
advance_color2:
    mov ah, [color_idx2]    ; Save current color
.retry2:
    call get_random_rainbow
    cmp al, ah              ; Same as current?
    je .retry2              ; Try again
    mov [color_idx2], al
    ret

; Get a random rainbow color (returns color byte in AL)
; Note: Preserves AH for caller's use
get_random_rainbow:
    push bx
    ; Read timer for pseudo-random value
    in al, 40h              ; Read PIT counter (changes rapidly)
    and al, 07h             ; Mask to 0-7 (8 rainbow colors)
    xor bh, bh              ; Clear high byte
    mov bl, al              ; BX = 0-7 (proper zero extension)
    mov al, [rainbow_colors + bx]
    pop bx
    ret

; ===== Data Section =====

ball1_x     dw 0
ball1_y     dw 0
ball1_vx    dw 0
ball1_vy    dw 0

ball2_x     dw 0
ball2_y     dw 0
ball2_vx    dw 0
ball2_vy    dw 0

; Current colors for each ball (byte value, not index)
color_idx1  db 0B0h         ; Start with Light Cyan
color_idx2  db 0C0h         ; Start with Light Red

; Rainbow colors table - 8 bright, clear colors
; Format: high nibble = foreground color, low nibble = 0
rainbow_colors:
    db 0C0h     ; Light Red (12)
    db 0E0h     ; Yellow (14)
    db 0A0h     ; Light Green (10)
    db 0B0h     ; Light Cyan (11)
    db 090h     ; Light Blue (9)
    db 0D0h     ; Light Magenta (13)
    db 040h     ; Red (4)
    db 020h     ; Green (2)
RAINBOW_LEN equ 8

; Text strings ($ terminated for DOS)
info_text:
    db 'V6355D Raster-Sync Sprite Multiplexing Demo', 13, 10
    db '--------------------------------------------', 13, 10
    db 'Using the hardware mouse cursor sprite!', 13, 10
    db 'Two balls from ONE 16x16 sprite.', 13, 10
    db 13, 10
    db 'Top ball: Solid    Bottom ball: XOR transparent', 13, 10
    db 'Random rainbow colors on bounce!', 13, 10
    db 13, 10
    db 'Created by Retro Erik, 2026', 13, 10
    db 'Press ESC to exit', 13, 10, '$'

; 16x16 circular sprite mask
; First 16 words: Screen mask (AND mask - 0=transparent)
; Second 16 words: Cursor mask (XOR mask - 1=draw)

sprite_mask:
    ; Screen mask (inverted circle - 0 where sprite is)
    dw 1111111111111111b    ; Row 0
    dw 1111111001111111b    ; Row 1
    dw 1111110000011111b    ; Row 2
    dw 1111100000001111b    ; Row 3
    dw 1111000000000111b    ; Row 4
    dw 1110000000000011b    ; Row 5
    dw 1110000000000011b    ; Row 6
    dw 1100000000000001b    ; Row 7
    dw 1100000000000001b    ; Row 8
    dw 1110000000000011b    ; Row 9
    dw 1110000000000011b    ; Row 10
    dw 1111000000000111b    ; Row 11
    dw 1111100000001111b    ; Row 12
    dw 1111110000011111b    ; Row 13
    dw 1111111001111111b    ; Row 14
    dw 1111111111111111b    ; Row 15

    ; Cursor mask (solid circle - 1 where sprite draws)
    dw 0000000000000000b    ; Row 0
    dw 0000000110000000b    ; Row 1
    dw 0000001111100000b    ; Row 2
    dw 0000011111110000b    ; Row 3
    dw 0000111111111000b    ; Row 4
    dw 0001111111111100b    ; Row 5
    dw 0001111111111100b    ; Row 6
    dw 0011111111111110b    ; Row 7
    dw 0011111111111110b    ; Row 8
    dw 0001111111111100b    ; Row 9
    dw 0001111111111100b    ; Row 10
    dw 0000111111111000b    ; Row 11
    dw 0000011111110000b    ; Row 12
    dw 0000001111100000b    ; Row 13
    dw 0000000110000000b    ; Row 14
    dw 0000000000000000b    ; Row 15
