; Bouncing Ball Demo using PC1 Hardware Sprite
; For Olivetti PC1 with NEC V40 CPU
; Assemble with NASM: nasm -f bin BB.asm -o BB.com
; Created by RetroErik - 2026

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

    ; Initialize position and velocity
    mov word [pos_x], 320   ; Center X
    mov word [pos_y], 100   ; Center Y
    mov word [vel_x], 3     ; X velocity
    mov word [vel_y], 2     ; Y velocity

main_loop:
    ; Check for ESC key
    mov ah, 01h             ; Check if key available
    int 16h
    jnz check_key           ; Key pressed

continue_loop:
    ; Update X position
    mov ax, [pos_x]
    add ax, [vel_x]
    mov [pos_x], ax

    ; Check X bounds
    cmp ax, 8               ; Left edge (sprite half-width)
    jle bounce_x
    cmp ax, 631             ; Right edge (639 - 8)
    jge bounce_x
    jmp check_y

bounce_x:
    neg word [vel_x]        ; Reverse X velocity
    mov ax, [pos_x]
    add ax, [vel_x]         ; Apply reversed velocity
    add ax, [vel_x]         ; Move away from edge
    mov [pos_x], ax

check_y:
    ; Update Y position
    mov ax, [pos_y]
    add ax, [vel_y]
    mov [pos_y], ax

    ; Check Y bounds
    cmp ax, 8               ; Top edge
    jle bounce_y
    cmp ax, 191             ; Bottom edge (199 - 8)
    jge bounce_y
    jmp update_sprite

bounce_y:
    neg word [vel_y]        ; Reverse Y velocity
    mov ax, [pos_y]
    add ax, [vel_y]         ; Apply reversed velocity
    add ax, [vel_y]         ; Move away from edge
    mov [pos_y], ax

update_sprite:
    ; Move sprite to new position
    mov ax, 04h             ; Function 04h: Move pointer
    mov cx, [pos_x]
    mov dx, [pos_y]
    int 33h

    ; Wait for next BIOS timer tick (~55ms, ~18Hz)
    mov ah, 00h             ; Get current timer tick count
    int 1Ah                 ; Returns tick count in CX:DX
    mov [timer_target], dx  ; Save current low word
    inc word [timer_target] ; Target = current + 1 tick

wait_tick:
    mov ah, 00h
    int 1Ah
    cmp dx, [timer_target]  ; Has tick count reached target?
    jne wait_tick           ; No, keep waiting

    jmp main_loop

check_key:
    mov ah, 00h             ; Read key
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

; Data section
pos_x        dw 320
pos_y        dw 100
vel_x        dw 3
vel_y        dw 2
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
