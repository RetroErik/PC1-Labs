; HPOS.ASM - Horizontal Position Tester for Olivetti PC1
; Press LEFT/RIGHT arrows to adjust, Q or ESC to quit
; Shows current register 0x67 value on screen
;
; Assemble: nasm -f bin hpos.asm -o hpos.com
;
; ============================================================================
; FINDINGS: V6355D Register 0x67 (Configuration Mode Register)
; ============================================================================
;
; From documentation:
;   Bits 0-4: Horizontal display position adjustment (-7 to +8 dots) in CRT mode
;   Bits 5-7: Should be 0 (LCD control, page mode, 16-bit bus - not used on PC1)
;
; PERITEL.COM sets: 0x18 (decimal 24) - maximum right shift
; CRT.COM sets:     (does not touch 0x67, only changes 0x65 for 50Hz/60Hz)
;
; Experimental results on Olivetti PC1:
;   - Value 24 = maximum RIGHT shift (PERITEL's choice, optimal)
;   - Values 25+ = screen moves LEFT (wraps around?)
;   - Values 23- = screen moves LEFT off-screen
;   - Range is very limited: 24 is the sweet spot
;
; Conclusion:
;   Register 0x67 = 0x18 (24) is already the maximum rightward position.
;   If the screen still appears shifted left, the cause is NOT register 0x67.
;   Something else (mode change, other registers, timing) must be responsible.
;
; ============================================================================
; HOW TO PRESERVE PERITEL SETTINGS WHEN INITIALIZING GRAPHICS MODE
; ============================================================================
;
; Problem: BIOS INT 10h function 00h (set video mode) resets V6355D registers,
;          overwriting PERITEL's horizontal position setting.
;
; Solution: Do NOT call BIOS to set video mode. Instead:
;
;   1. Run PERITEL.COM first (sets horizontal position to maximum right)
;
;   2. In your program, enable 160x200x16 graphics mode by writing DIRECTLY
;      to the CGA mode register at port 0x3D8:
;
;        mov al, 0x4A      ; Bit 6=1 (160x200 mode), Bit 3=1 (enable), Bit 1=1 (graphics)
;        mov dx, 0x3D8
;        out dx, al
;
;   3. Do NOT write to register 0x67 - leave PERITEL's value intact
;
;   4. On exit, only reset the mode register if needed:
;
;        mov al, 0x28      ; Text mode, video enabled
;        out 0x3D8, al
;
;      Do NOT write to register 0x67 on exit either.
;
; This approach preserves the horizontal position set by PERITEL.COM.
;
; Note: The raster bar effect works by changing the border color (port 0x3D9)
;       per-scanline. This only affects the left and right borders - the text
;       or graphics content in the middle of the screen is unaffected.
;
; ============================================================================

org 0x100

section .text

start:
    ; Initialize with PERITEL value
    mov byte [current_pos], 0x18
    
    ; Set initial position
    call set_hpos
    call show_value

main_loop:
    ; Wait for keypress
    mov ah, 0x00
    int 0x16            ; BIOS keyboard read
    
    ; Check for ESC (AL=0x1B or scan code 0x01)
    cmp al, 0x1B
    je exit
    cmp ah, 0x01        ; ESC scan code
    je exit
    
    ; Check for Q/q to quit
    cmp al, 'q'
    je exit
    cmp al, 'Q'
    je exit
    
    ; Check for arrow keys (extended keys have al=0, ah=scancode)
    cmp al, 0
    jne main_loop       ; Not extended key, ignore
    
    ; Check scancode in AH
    cmp ah, 0x4B        ; Left arrow
    je go_left
    cmp ah, 0x4D        ; Right arrow
    je go_right
    jmp main_loop

go_left:
    cmp byte [current_pos], 0
    je main_loop        ; Already at minimum
    dec byte [current_pos]
    call set_hpos
    call show_value
    jmp main_loop

go_right:
    cmp byte [current_pos], 0x1F  ; Max 31 (5 bits)
    je main_loop        ; Already at maximum
    inc byte [current_pos]
    call set_hpos
    call show_value
    jmp main_loop

exit:
    ; Exit to DOS
    mov ax, 0x4C00
    int 0x21

; Set horizontal position register 0x67
set_hpos:
    mov al, 0x67
    out 0xDD, al
    mov al, [current_pos]
    out 0xDE, al
    ret

; Show current value on screen at top-left
show_value:
    push ax
    push bx
    push cx
    push dx
    
    ; Position cursor at 0,0
    mov ah, 0x02
    mov bh, 0
    mov dx, 0x0000
    int 0x10
    
    ; Print "Reg 0x67 = 0x"
    mov ah, 0x09
    mov dx, msg_prefix
    int 0x21
    
    ; Print hex value
    mov al, [current_pos]
    call print_hex_byte
    
    ; Print " (dec "
    mov ah, 0x09
    mov dx, msg_dec
    int 0x21
    
    ; Print decimal value
    mov al, [current_pos]
    call print_decimal
    
    ; Print ")"
    mov ah, 0x02
    mov dl, ')'
    int 0x21
    
    ; Print position interpretation
    mov ah, 0x09
    mov dx, msg_dots
    int 0x21
    
    ; Calculate dots offset: value - 16 (if 16 is center)
    mov al, [current_pos]
    sub al, 16
    js .negative
    
    ; Positive or zero
    mov ah, 0x02
    mov dl, '+'
    int 0x21
    call print_decimal_signed
    jmp .done
    
.negative:
    ; Negative - AL already has negative value
    neg al
    push ax
    mov ah, 0x02
    mov dl, '-'
    int 0x21
    pop ax
    call print_decimal_signed
    
.done:
    ; Print " dots)  "
    mov ah, 0x09
    mov dx, msg_end
    int 0x21
    
    pop dx
    pop cx
    pop bx
    pop ax
    ret

; Print AL as 2-digit hex
print_hex_byte:
    push ax
    push cx
    
    mov cl, al          ; Save original
    
    ; High nibble
    shr al, 4
    call print_hex_digit
    
    ; Low nibble
    mov al, cl
    and al, 0x0F
    call print_hex_digit
    
    pop cx
    pop ax
    ret

print_hex_digit:
    cmp al, 10
    jb .digit
    add al, 'A' - 10
    jmp .print
.digit:
    add al, '0'
.print:
    mov ah, 0x02
    mov dl, al
    int 0x21
    ret

; Print AL as decimal (0-255)
print_decimal:
    push ax
    push bx
    push cx
    push dx
    
    xor ah, ah
    mov bl, 100
    div bl              ; AL = hundreds, AH = remainder
    
    cmp al, 0
    je .skip_hundreds
    add al, '0'
    mov dl, al
    mov ah, 0x02
    int 0x21
    mov byte [printed], 1
    jmp .do_tens
    
.skip_hundreds:
    mov byte [printed], 0
    
.do_tens:
    push ax
    mov al, ah          ; Get remainder
    xor ah, ah
    mov bl, 10
    div bl              ; AL = tens, AH = ones
    
    cmp byte [printed], 0
    jne .print_tens
    cmp al, 0
    je .skip_tens
    
.print_tens:
    add al, '0'
    mov dl, al
    push ax
    mov ah, 0x02
    int 0x21
    pop ax
    
.skip_tens:
    ; Always print ones
    mov al, ah          ; ones digit
    add al, '0'
    mov dl, al
    mov ah, 0x02
    int 0x21
    
    pop ax
    pop dx
    pop cx
    pop bx
    pop ax
    ret

; Print AL as signed decimal (for small values)
print_decimal_signed:
    push ax
    push dx
    
    cmp al, 10
    jb .ones
    
    ; Two digits
    push ax
    mov dl, '1'
    mov ah, 0x02
    int 0x21
    pop ax
    sub al, 10
    
.ones:
    add al, '0'
    mov dl, al
    mov ah, 0x02
    int 0x21
    
    pop dx
    pop ax
    ret

section .data
    current_pos: db 0x18
    printed:     db 0
    
    msg_prefix:  db 'Reg 0x67 = 0x$'
    msg_dec:     db ' (dec $'
    msg_dots:    db ' = $'
    msg_end:     db ' dots)    $'
