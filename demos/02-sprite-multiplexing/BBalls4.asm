; PC1 Sprite Multiplexing Demo - 2 Bouncing Balls
; For Olivetti PC1 with NEC V40 CPU
; Assemble with NASM: nasm -f bin BBalls4.asm -o BBalls4.com
; By Retro Erik - 2026 using VS Code with Co-Pilot
;
; HOW RASTER-SYNC MULTIPLEXING WORKS:
; -----------------------------------
; The CRT beam draws the screen top-to-bottom, line by line.
; We "chase" the beam by repositioning the single hardware sprite
; after the beam has already drawn the first ball's position.
;
; Algorithm:
;   1. Wait for vsync (beam returns to top of screen)
;   2. Position sprite at top ball
;   3. Wait until beam passes that ball (Y + 16)
;   4. Reposition sprite to bottom ball
;   5. Result: Both balls visible in ONE frame = no flicker!
;
; PROGRESSION IN THIS SERIES:
; ---------------------------
; BBalls4 (this file): Basic raster-synchronized multiplexing - 2 balls, white
;   - THE BREAKTHROUGH: Shows raster-sync actually works (no flicker!)
;   - Simplest working version - understand this first
;   - No colors, no animation - pure technique focus
; BBalls5: + Rainbow colors + mode switching (solid vs XOR transparent)
; BBalls6: + Animated sprite shapes (8-frame spinning line)
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
    mov word [ball1_vx], 4      ; Pixels per frame
    mov word [ball1_vy], 2

    ; Initialize ball 2 position and velocity
    mov word [ball2_x], 450
    mov word [ball2_y], 142     ; Zone 2: bottom half (100-184)
    mov word [ball2_vx], -5
    mov word [ball2_vy], 3

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
    
    ; --- Ball 1: Draw immediately (top half) ---
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
    
    ; --- Ball 2: Beam has passed top half, now draw bottom ---
    mov ax, [ball2_x]
    mov bx, [ball2_y]
    call position_sprite
    
    ; Ball 2 stays visible until next vsync

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
    cmp ax, 608             ; Right edge (adjusted for X/2 transform)
    jge bounce1_x
    jmp check1_y

bounce1_x:
    neg word [ball1_vx]     ; Reverse X velocity
    mov ax, [ball1_x]
    add ax, [ball1_vx]      ; Apply reversed velocity
    add ax, [ball1_vx]      ; Move away from edge
    mov [ball1_x], ax

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
    cmp ax, 608
    jge bounce2_x
    jmp check2_y

bounce2_x:
    neg word [ball2_vx]
    mov ax, [ball2_x]
    add ax, [ball2_vx]
    add ax, [ball2_vx]
    mov [ball2_x], ax

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

end_update2:
    ret

; Print info text to screen
print_info:
    mov ah, 09h             ; DOS print string function
    mov dx, info_text       ; Pointer to $ terminated string
    int 21h
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

; Text strings ($ terminated for DOS)
info_text:
    db 1Bh, '[2J', 1Bh, '[H'        ; Clear screen and home cursor
    db 1Bh, '[1;36m'                ; Bright Cyan
    db 'BBalls4: Raster-Synchronized Sprite Multiplexing', 13, 10
    db 1Bh, '[1;33m'                ; Bright Yellow
    db '================================================', 13, 10
    db 1Bh, '[0m', 13, 10            ; Reset colors
    db 1Bh, '[1;32m'                ; Bright Green
    db 'Two bouncing balls from ONE 16x16 sprite!', 13, 10
    
    ; 16 horizontal color bars - 8 normal colors on top row, 8 bright colors on bottom row
    db 1Bh, '[4;52H'                ; Position first row (moved right by 2 chars)
    db 1Bh, '[40m   ', 1Bh, '[0m'  ; Black
    db 1Bh, '[44m   ', 1Bh, '[0m'  ; Blue
    db 1Bh, '[42m   ', 1Bh, '[0m'  ; Green
    db 1Bh, '[46m   ', 1Bh, '[0m'  ; Cyan
    db 1Bh, '[41m   ', 1Bh, '[0m'  ; Red
    db 1Bh, '[45m   ', 1Bh, '[0m'  ; Magenta
    db 1Bh, '[43m   ', 1Bh, '[0m'  ; Brown
    db 1Bh, '[47m   ', 1Bh, '[0m'  ; Light Gray
    db 1Bh, '[5;52H'                ; Position second row (moved right by 2 chars)
    db 1Bh, '[1;30m', 219,219,219, 1Bh, '[0m'  ; Dark Gray (bright black)
    db 1Bh, '[1;34m', 219,219,219, 1Bh, '[0m'  ; Light Blue (bright blue)
    db 1Bh, '[1;32m', 219,219,219, 1Bh, '[0m'  ; Light Green (bright green)
    db 1Bh, '[1;36m', 219,219,219, 1Bh, '[0m'  ; Light Cyan (bright cyan)
    db 1Bh, '[1;31m', 219,219,219, 1Bh, '[0m'  ; Light Red (bright red)
    db 1Bh, '[1;35m', 219,219,219, 1Bh, '[0m'  ; Light Magenta (bright magenta)
    db 1Bh, '[1;33m', 219,219,219, 1Bh, '[0m'  ; Yellow (bright brown)
    db 1Bh, '[1;37m', 219,219,219, 1Bh, '[0m'  ; White (bright light gray)
    
    db 1Bh, '[5;1H'                 ; Same line as bright color bars (row 5, column 1)
    db 1Bh, '[1;37m'                ; Bright White
    db 'Mid-frame repositioning chases the CRT beam', 13, 10
    db 1Bh, '[0m', 1Bh, '[37m'      ; Reset then Grey
    db 'down the screen for flicker-free animation.', 13, 10
    db 1Bh, '[0m', 13, 10            ; Reset
    db 1Bh, '[1;35m'                ; Bright Magenta
    db 'This is the BREAKTHROUGH version that proves', 13, 10
    db 1Bh, '[1;36m'                ; Bright Cyan
    db 'raster-sync multiplexing works on the PC1.', 13, 10
    db 1Bh, '[0m', 13, 10            ; Reset
    db 1Bh, '[1;33m'                ; Bright Yellow
    db 'Powered by ', 1Bh, '[1;36m', 'V6355D', 13, 10
    db 1Bh, '[0m'                   ; Reset
    db 'Created by ', 1Bh, '[1;35m', 'Retro ', 1Bh, '[1;36m', 'Erik', 1Bh, '[0m', ', 2026', 13, 10
    db 1Bh, '[1;33m', 'Press ESC to exit', 1Bh, '[0m', 13, 10, '$'

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
