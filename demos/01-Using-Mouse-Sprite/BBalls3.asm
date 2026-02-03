; PC1 Sprite Cycling Demo - 3 Bouncing Balls (NOT TRUE MULTIPLEXING)
; For Olivetti PC1 with NEC V40 CPU
; Assemble with NASM: nasm -f bin BBalls3.asm -o BBalls3.com
; By Retro Erik - 2026 using VS Code with Co-Pilot
; Version 0.4 - Vsync-synchronized, one ball per frame cycling
;
; PURPOSE: Step 3 in the progression - adds vsync synchronization but
; fundamentally changes the approach. This is TIME-DIVISION, NOT multiplexing!
;
; KEY DIFFERENCE FROM BBalls1/2:
; - Adds vsync synchronization (waits for vertical retrace)
; - Eliminates crude delay loops
; - BUT: Only ONE ball visible per frame, cycles between them
;
; CRITICAL ISSUE - THIS IS NOT MULTIPLEXING:
; - True multiplexing = Multiple sprites visible in same frame
; - This = Time-division = Show ball 1, then ball 2, then ball 3
; - Results in FLICKER because each ball visible at only 50Hz/3 ≈ 16.7Hz
; - This is WORSE than BBalls1/2 for visual quality
; - This is a DEAD-END approach!
;
; WHY IT FAILS:
; - Each ball only refreshed once every 3 frames (too slow)
; - Visible flicker as observer's eyes can detect ~16.7Hz
; - Synchronization doesn't help if you're not actually multiplexing
;
; WHAT WORKS:
; - TRUE multiplexing = reposition sprite multiple times per frame
; - RASTER synchronization = wait for beam to pass position 1, then reposition to position 2
; - Both balls visible every frame = no flicker
;
; NOTE: Coordinate system details documented in BBall.asm
;
; NEXT STEPS (Learning Progression):
; - BBalls1.asm: 3 balls, mouse driver (crude multiplexing attempt)
; - BBalls2.asm: 3 balls, direct hardware (faster but still flickers)
; - BBalls3.asm: 3 balls cycling, vsync sync (time-division, NOT multiplexing) - YOU ARE HERE
; - BBalls4+: True raster-sync multiplexing (THIS is the solution!)

CPU 186

    ORG 100h

start:
    ; Initialize V6335D sprite hardware directly
    call enable_v6335d
    call load_sprite_shape
    call setup_sprite_attr
    call show_sprite

    ; Initialize ball 1 position and velocity
    ; Positions are in VIRTUAL coordinates (0-608 for X, 8-184 for Y)
    ; These get transformed to hardware coords in position_sprite
    mov word [ball1_x], 320     ; Center of screen (virtual X)
    mov word [ball1_y], 100     ; Center of screen (virtual Y)
    mov word [ball1_vx], 4      ; Pixels per frame, positive = right
    mov word [ball1_vy], 3      ; Pixels per frame, positive = down

    ; Initialize ball 2 position and velocity
    mov word [ball2_x], 450
    mov word [ball2_y], 140
    mov word [ball2_vx], -5
    mov word [ball2_vy], 4

    ; Initialize ball 3 position and velocity
    mov word [ball3_x], 200
    mov word [ball3_y], 60
    mov word [ball3_vx], 3
    mov word [ball3_vy], -2

    ; Initialize current ball counter for multiplexing
    mov byte [current_ball], 0

main_loop:
    ; Check for ESC key
    mov ah, 01h             ; Check if key available
    int 16h
    jnz check_key           ; Key pressed

continue_loop:
    ; Update all balls
    call update_ball1
    call update_ball2
    call update_ball3

    ; Wait for vertical retrace to start
    call wait_vsync
    
    ; Sprite multiplexing: one ball per vsync frame
    ; PAL = 50Hz, so each ball visible at 50Hz/3 = ~16.7Hz per ball
    mov al, [current_ball]
    cmp al, 0
    je .draw_ball1
    cmp al, 1
    je .draw_ball2
    jmp .draw_ball3

.draw_ball1:
    mov ax, [ball1_x]
    mov bx, [ball1_y]
    call position_sprite
    jmp .done_draw
    
.draw_ball2:
    mov ax, [ball2_x]
    mov bx, [ball2_y]
    call position_sprite
    jmp .done_draw
    
.draw_ball3:
    mov ax, [ball3_x]
    mov bx, [ball3_y]
    call position_sprite

.done_draw:
    ; Cycle to next ball (0->1->2->0)
    inc byte [current_ball]
    cmp byte [current_ball], 3
    jb .ball_ok
    mov byte [current_ball], 0
.ball_ok:

    ; No timer wait needed - vsync provides ~60Hz timing
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

; Short delay for sprite persistence
; Adjust CX value to tune flickering vs speed
; Higher value = longer delay = more solid balls but slower
short_delay:
    push cx
    mov cx, 4000h           ; Try 4000h for more solid appearance
.delay_loop:
    loop .delay_loop
    pop cx
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

    ; Check Y bounds (origin is top-left of 16x16 sprite)
    ; Hardware adds +8 offset, so top bound needs adjustment
    cmp ax, 8               ; Top edge (account for +8 offset)
    jle bounce1_y
    cmp ax, 184             ; Bottom edge (200 - 16)
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

    ; Check Y bounds
    cmp ax, 8
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

update_ball3:
    ; Update X position
    mov ax, [ball3_x]
    add ax, [ball3_vx]
    mov [ball3_x], ax

    ; Check X bounds
    cmp ax, 0
    jle bounce3_x
    cmp ax, 608
    jge bounce3_x
    jmp check3_y

bounce3_x:
    neg word [ball3_vx]
    mov ax, [ball3_x]
    add ax, [ball3_vx]
    add ax, [ball3_vx]
    mov [ball3_x], ax

check3_y:
    ; Update Y position
    mov ax, [ball3_y]
    add ax, [ball3_vy]
    mov [ball3_y], ax

    ; Check Y bounds
    cmp ax, 8
    jle bounce3_y
    cmp ax, 184
    jge bounce3_y
    jmp end_update3

bounce3_y:
    neg word [ball3_vy]
    mov ax, [ball3_y]
    add ax, [ball3_vy]
    add ax, [ball3_vy]
    mov [ball3_y], ax

end_update3:
    ret

; Data section
ball1_x     dw 100
ball1_y     dw 50
ball1_vx    dw 2
ball1_vy    dw 3

ball2_x     dw 400
ball2_y     dw 150
ball2_vx    dw -3
ball2_vy    dw -2

ball3_x     dw 320
ball3_y     dw 100
ball3_vx    dw 1
ball3_vy    dw 1

timer_target dw 0
current_ball db 0

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
