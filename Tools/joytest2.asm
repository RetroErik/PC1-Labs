;*****************************************************************************
;* JOYTEST2.COM - Enhanced joystick port scanner
;*
;* Reads ALL possible joystick-related hardware:
;*   - Port 0x3DA bits 0-4 (status register: HSync, MS1, MS0, VBlank, dot)
;*   - CRTC R16 via 0xD4/0xD5 (mouse X counter)
;*   - CRTC R17 via 0xD4/0xD5 (mouse Y counter)
;*
;* Press ESC to exit.
;* Compile: nasm -f bin -o joytest2.com joytest2.asm
;*****************************************************************************

CPU 186
ORG 100h

start:
        mov     ah, 9
        lea     dx, [header]
        int     21h

mainloop:
        ; Carriage return to overwrite line
        mov     ah, 2
        mov     dl, 0Dh
        int     21h

        ;--- Read port 0x3DA ---
        mov     dx, 3DAh
        in      al, dx
        mov     [val_3da], al

        ;--- Read CRTC R16 (mouse X counter) ---
        mov     al, 10h
        out     0D4h, al
        in      al, 0D5h
        mov     [val_r16], al

        ;--- Read CRTC R17 (mouse Y counter) ---
        mov     al, 11h
        out     0D4h, al
        in      al, 0D5h
        mov     [val_r17], al

        ;--- Display 0x3DA value ---
        mov     ah, 9
        lea     dx, [lbl_3da]
        int     21h
        mov     al, [val_3da]
        call    print_hex_byte

        ;--- Display individual bits of 0x3DA ---
        ; Bit 1 (MS1)
        mov     ah, 9
        lea     dx, [lbl_b1]
        int     21h
        mov     al, [val_3da]
        test    al, 02h
        call    print_bit

        ; Bit 2 (MS0)
        mov     ah, 9
        lea     dx, [lbl_b2]
        int     21h
        mov     al, [val_3da]
        test    al, 04h
        call    print_bit

        ; Bit 4 (dot)
        mov     ah, 9
        lea     dx, [lbl_b4]
        int     21h
        mov     al, [val_3da]
        test    al, 10h
        call    print_bit

        ;--- Display CRTC R16 (mouse X) ---
        mov     ah, 9
        lea     dx, [lbl_r16]
        int     21h
        mov     al, [val_r16]
        call    print_signed

        ;--- Display CRTC R17 (mouse Y) ---
        mov     ah, 9
        lea     dx, [lbl_r17]
        int     21h
        mov     al, [val_r17]
        call    print_signed

        ;--- Padding ---
        mov     ah, 9
        lea     dx, [spaces]
        int     21h

        ;--- Small delay ---
        mov     cx, 3
.delay: push    cx
        xor     cx, cx
.inner: loop    .inner
        pop     cx
        loop    .delay

        ;--- Check ESC ---
        mov     ah, 1
        int     16h
        jz      mainloop
        mov     ah, 0
        int     16h
        cmp     al, 27
        jne     mainloop

        mov     ah, 9
        lea     dx, [bye]
        int     21h
        mov     ax, 4C00h
        int     21h

;============================================================================
; print_bit - print 1 or 0 based on zero flag (test result)
; Call after TEST instruction: ZF set = bit is 0
;============================================================================
print_bit:
        jz      .zero
        mov     dl, '1'
        jmp     .out
.zero:  mov     dl, '0'
.out:   mov     ah, 2
        int     21h
        ret

;============================================================================
; print_signed - print AL as signed decimal (-128 to 127)
;============================================================================
print_signed:
        cbw                     ; sign extend AL to AX
        test    ax, ax
        jns     .positive
        push    ax
        mov     dl, '-'
        mov     ah, 2
        int     21h
        pop     ax
        neg     ax
        jmp     .print_num
.positive:
        push    ax
        mov     dl, '+'
        mov     ah, 2
        int     21h
        pop     ax
.print_num:
        ; AX = 0-128, print as decimal
        cmp     ax, 100
        jb      .tens
        push    ax
        mov     dl, '1'
        mov     ah, 2
        int     21h
        pop     ax
        sub     ax, 100
.tens:  xor     dx, dx
        mov     bl, 10
        div     bl              ; AL=tens, AH=ones
        push    ax
        add     al, '0'
        mov     dl, al
        mov     ah, 2
        int     21h
        pop     ax
        mov     al, ah
        add     al, '0'
        mov     dl, al
        mov     ah, 2
        int     21h
        ret

;============================================================================
; print_hex_byte - print AL as 2 hex digits
;============================================================================
print_hex_byte:
        push    ax
        shr     al, 4
        call    print_nibble
        pop     ax
        and     al, 0Fh
        call    print_nibble
        ret

print_nibble:
        cmp     al, 10
        jb      .digit
        add     al, 'A' - 10
        jmp     .print
.digit: add     al, '0'
.print: mov     dl, al
        mov     ah, 2
        int     21h
        ret

;============================================================================
; Data
;============================================================================
val_3da db 0
val_r16 db 0
val_r17 db 0

header  db 'JOYTEST2 - Enhanced joystick port scanner',0Dh,0Ah
        db 'Tests: 0x3DA bits, CRTC R16 (mouseX), R17 (mouseY)',0Dh,0Ah
        db 'Try: Up, Down, Left, Right, Fire - one at a time',0Dh,0Ah
        db 'Press ESC to exit',0Dh,0Ah,0Dh,0Ah,'$'
lbl_3da db '3DA=$'
lbl_b1  db ' B1=$'
lbl_b2  db ' B2=$'
lbl_b4  db ' B4=$'
lbl_r16 db ' R16=$'
lbl_r17 db ' R17=$'
spaces  db '     $'
bye     db 0Dh,0Ah,'Done.',0Dh,0Ah,'$'
