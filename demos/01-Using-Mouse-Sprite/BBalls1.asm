; PC1 Sprite Multiplexing Demo - 3 Bouncing Balls (CRUDE MULTIPLEXING ATTEMPT)
; For Olivetti PC1 with NEC V40 CPU
; Assemble with NASM: nasm -f bin BBalls.asm -o BBalls.com
; By Retro Erik - 2026 using VS Code with Co-Pilot
;
; PURPOSE: Demonstrates a NAIVE multiplexing approach to display 3 balls
; using a single hardware sprite. This is an EXPERIMENTAL/LEARNING version.
;
; FEATURES:
; - 3 independently bouncing balls
; - Rapid repositioning to simulate multiple sprites (crude multiplexing)
; - Uses INT 33h mouse driver (requires mouse driver installed)
;
; LIMITATIONS & ISSUES:
; - Uses rapid repositioning with delays (NOT raster-synchronized)
; - Will exhibit flicker due to unsynced sprite redraws
; - Code is POORLY STRUCTURED: uses 3 identical update_ball routines
;   (update_ball1, update_ball2, update_ball3) instead of generic loop
; - Significant code duplication (data and logic repeated 3 times)
; - Waits for BIOS timer tick (~18Hz) - slow and imprecise timing
;
; PROPER MULTIPLEXING (raster-synchronized, flicker-free) requires:
; - Direct hardware access (no mouse driver)
; - Synchronization with raster beam position
; - Careful timing to reposition sprite between balls
; - See BBalls4+ for correct implementation
;
; NEXT STEPS (Learning Progression):
; - BBalls1.asm: 3 balls, mouse driver (crude multiplexing attempt) - YOU ARE HERE
; - BBalls2.asm: 3 balls, direct hardware (faster but still flickers)
; - BBalls3.asm: 3 balls cycling, vsync sync (time-division, NOT multiplexing)
; - BBalls4+: True raster-sync multiplexing (THIS is the solution!)


CPU 186

    ORG 100h

start:
    ; Initialize mouse driver
    xor ax, ax
    int 33h
    cmp ax, 0FFFFh          ; Check if mouse driver present
    jne no_mouse

    ; Set circular sprite shape
    mov ax, 09h             ; Function 09h: Set graphic pointer shape
    mov bx, 8               ; Horizontal hot spot (center)
    mov cx, 8               ; Vertical hot spot (center)
    push cs
    pop es
    mov dx, sprite_mask
    int 33h

    ; Show cursor/sprite
    mov ax, 01h
    int 33h

    ; Initialize ball 1 position and velocity
    mov word [ball1_x], 100
    mov word [ball1_y], 50
    mov word [ball1_vx], 2
    mov word [ball1_vy], 3

    ; Initialize ball 2 position and velocity
    mov word [ball2_x], 400
    mov word [ball2_y], 150
    mov word [ball2_vx], -3
    mov word [ball2_vy], -2

    ; Initialize ball 3 position and velocity
    mov word [ball3_x], 320
    mov word [ball3_y], 100
    mov word [ball3_vx], 1
    mov word [ball3_vy], 1

main_loop:
    ; Check for ESC key
    mov ah, 01h             ; Check if key available
    int 16h
    jnz check_key           ; Key pressed

continue_loop:
    ; Update ball 1
    call update_ball1
    
    ; Update ball 2
    call update_ball2
    
    ; Update ball 3
    call update_ball3

    ; Sprite multiplexing: draw all 3 balls by repositioning
    
    ; Draw ball 1
    mov ax, 04h
    mov cx, [ball1_x]
    mov dx, [ball1_y]
    int 33h
    
    ; Small delay for persistence
    mov cx, 3FFFh
    call delay_short
    
    ; Draw ball 2
    mov ax, 04h
    mov cx, [ball2_x]
    mov dx, [ball2_y]
    int 33h
    
    ; Small delay
    mov cx, 3FFFh
    call delay_short
    
    ; Draw ball 3
    mov ax, 04h
    mov cx, [ball3_x]
    mov dx, [ball3_y]
    int 33h
    
    ; Small delay
    mov cx, 3FFFh
    call delay_short

    ; Wait for next BIOS timer tick (~55ms, ~18Hz)
    mov ah, 00h
    int 1Ah
    mov [timer_target], dx
    inc word [timer_target]

wait_tick:
    mov ah, 00h
    int 1Ah
    cmp dx, [timer_target]
    jne wait_tick

    jmp main_loop

check_key:
    mov ah, 00h
    int 16h
    cmp ah, 01h             ; ESC scan code
    je exit_program
    jmp continue_loop

no_mouse:
    mov dx, no_mouse_msg
    mov ah, 09h
    int 21h
    jmp exit_program

exit_program:
    ; Hide cursor before exit
    mov ax, 02h
    int 33h

    ; Exit to DOS
    mov ax, 4C00h
    int 21h

; ===== Ball Update Routines =====

update_ball1:
    ; Update X
    mov ax, [ball1_x]
    add ax, [ball1_vx]
    mov [ball1_x], ax
    
    ; Check X bounds
    cmp ax, 8
    jle bounce1_x
    cmp ax, 631
    jge bounce1_x
    jmp check1_y
    
bounce1_x:
    mov ax, [ball1_vx]
    neg ax
    mov [ball1_vx], ax
    mov ax, [ball1_x]
    add ax, [ball1_vx]
    add ax, [ball1_vx]
    mov [ball1_x], ax
    
check1_y:
    mov ax, [ball1_y]
    add ax, [ball1_vy]
    mov [ball1_y], ax
    
    cmp ax, 8
    jle bounce1_y
    cmp ax, 191
    jge bounce1_y
    jmp end_update1
    
bounce1_y:
    mov ax, [ball1_vy]
    neg ax
    mov [ball1_vy], ax
    mov ax, [ball1_y]
    add ax, [ball1_vy]
    add ax, [ball1_vy]
    mov [ball1_y], ax
    
end_update1:
    ret

update_ball2:
    ; Update X
    mov ax, [ball2_x]
    add ax, [ball2_vx]
    mov [ball2_x], ax
    
    ; Check X bounds
    cmp ax, 8
    jle bounce2_x
    cmp ax, 631
    jge bounce2_x
    jmp check2_y
    
bounce2_x:
    mov ax, [ball2_vx]
    neg ax
    mov [ball2_vx], ax
    mov ax, [ball2_x]
    add ax, [ball2_vx]
    add ax, [ball2_vx]
    mov [ball2_x], ax
    
check2_y:
    mov ax, [ball2_y]
    add ax, [ball2_vy]
    mov [ball2_y], ax
    
    cmp ax, 8
    jle bounce2_y
    cmp ax, 191
    jge bounce2_y
    jmp end_update2
    mov ax, [ball2_vy]
    neg ax
    mov [ball2_vy], ax
bounce2_y:
    neg word [ball2_vy]
    mov ax, [ball2_y]
    add ax, [ball2_vy]
    add ax, [ball2_vy]
    mov [ball2_y], ax
    
end_update2:
    ret

update_ball3:
    ; Update X
    mov ax, [ball3_x]
    add ax, [ball3_vx]
    mov [ball3_x], ax
    
    ; Check X bounds
    cmp ax, 8
    jle bounce3_x
    cmp ax, 631
    jge bounce3_x
    jmp check3_y
    mov ax, [ball3_vx]
    neg ax
    mov [ball3_vx], ax
bounce3_x:
    neg word [ball3_vx]
    mov ax, [ball3_x]
    add ax, [ball3_vx]
    add ax, [ball3_vx]
    mov [ball3_x], ax
    
check3_y:
    mov ax, [ball3_y]
    add ax, [ball3_vy]
    mov [ball3_y], ax
    
    cmp ax, 8
    jle bounce3_y
    cmp ax, 191
    mov ax, [ball3_vy]
    neg ax
    mov [ball3_vy], ax
    jmp end_update3
    
bounce3_y:
    neg word [ball3_vy]
    mov ax, [ball3_y]
    add ax, [ball3_vy]
    add ax, [ball3_vy]
    mov [ball3_y], ax
    
end_update3:
    ret

; Simple spin delay (CX iterations)
delay_short:
delay_loop:
    loop delay_loop
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

no_mouse_msg db 'Mouse driver not found!', 0Dh, 0Ah, '$'

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
