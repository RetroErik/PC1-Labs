; ============================================================================
; TIMING.ASM - Timing measurement for Olivetti PC1 V6355D
; Measures scanline timing and vblank duration
; Written for NASM - NEC V40 @ 8 MHz
; By Retro Erik - 2026 using VS Code with Co-Pilot
;
; MEASURED VALUES (Olivetti PC1):
;   - Loop iterations per scanline: 2 (very brief hsync pulse)
;   - Loop iterations during vblank: 133
;   - Scanlines per frame: 4096 (timeout - hsync counting unreliable)
;   - Est. CPU cycles per scanline: 22 (hsync pulse only)
;
; PAL 50Hz Expected Values (for reference):
;   - 64 µs per scanline (~512 CPU cycles @ 8MHz)
;   - ~312 total scanlines per frame
;   - ~112 vblank lines (~7.2 ms vblank)
;   - ~40-50 loop iterations per scanline
;   - ~4000-5000 iterations during vblank
;
; NOTES:
;   - The hsync pulse (bit 0 = 1) is very brief (~2 iterations)
;   - Vblank (bit 3) is reliable for frame sync
;   - Raster bars need to detect hsync edge, not poll for duration
; ============================================================================

[BITS 16]
[ORG 0x100]

; --- Yamaha V6355D I/O Ports ---
PORT_MODE       equ 0x3D8
PORT_COLOR      equ 0x3D9
PORT_STATUS     equ 0x3DA       ; bit 0 = hsync, bit 3 = vsync

main:
    ; === Run all tests in graphics mode ===
    mov dx, PORT_MODE
    mov al, 0x4A
    out dx, al
    
    ; Test 1: Scanline timing
    call measure_scanline
    mov [scanline_count], ax
    
    ; Test 2: Vblank timing
    call measure_vblank
    mov [vblank_count], ax
    
    ; Test 3: Scanlines per frame
    call count_scanlines
    mov [total_scanlines], ax
    
    ; Now return to text mode ONCE and display all results
    mov ax, 0x0003
    int 0x10
    
    ; Display all results
    mov si, msg_scanline
    call print_string
    mov ax, [scanline_count]
    call print_number
    call print_newline
    
    mov si, msg_vblank
    call print_string
    mov ax, [vblank_count]
    call print_number
    call print_newline
    
    mov si, msg_lines
    call print_string
    mov ax, [total_scanlines]
    call print_number
    call print_newline
    
    ; Calculate estimated cycles per scanline
    mov si, msg_est_cycles
    call print_string
    mov ax, [scanline_count]
    mov bx, 11                  ; ~11 cycles per loop
    mul bx
    call print_number
    call print_newline
    
    ; Wait for key
    mov si, msg_done
    call print_string
    mov ah, 0
    int 0x16
    
    mov ax, 0x4C00
    int 0x21

; ============================================================================
; measure_scanline - Count loop iterations during one scanline
; Returns: AX = iteration count
; Uses timeout to prevent hanging
; ============================================================================
measure_scanline:
    push bx
    push dx
    cli
    
    mov dx, PORT_STATUS
    xor ax, ax
    
    ; Wait for bit 0 = 0 (with timeout)
    mov bx, 0xFFFF
.wait_low:
    in al, dx
    test al, 0x01
    jz .got_low
    dec bx
    jnz .wait_low
    mov ax, 0                   ; Timeout - return 0
    jmp .done
    
.got_low:
    ; Wait for bit 0 = 1 (hsync start, with timeout)
    mov bx, 0xFFFF
.wait_high:
    in al, dx
    test al, 0x01
    jnz .got_high
    dec bx
    jnz .wait_high
    mov ax, 0
    jmp .done
    
.got_high:
    ; Now count until bit 0 goes low then high again
    xor cx, cx
    mov bx, 0xFFFF
    
.count_loop:
    in al, dx
    inc cx
    test al, 0x01
    jz .found_transition
    dec bx
    jnz .count_loop
    mov ax, cx                  ; Timeout - return count so far
    jmp .done
    
.found_transition:
    mov ax, cx
    
.done:
    sti
    pop dx
    pop bx
    ret

; ============================================================================
; measure_vblank - Count loop iterations during vblank
; Returns: AX = iteration count (with timeout protection)
; ============================================================================
measure_vblank:
    push bx
    push dx
    cli
    
    mov dx, PORT_STATUS
    
    ; Wait for NOT in vblank (with timeout)
    mov bx, 0xFFFF
.wait_not_vblank:
    in al, dx
    test al, 0x08
    jz .not_in_vblank
    dec bx
    jnz .wait_not_vblank
    xor ax, ax
    jmp .done
    
.not_in_vblank:
    ; Wait for vblank start (with timeout)
    mov bx, 0xFFFF
.wait_vblank_start:
    in al, dx
    test al, 0x08
    jnz .in_vblank
    dec bx
    jnz .wait_vblank_start
    xor ax, ax
    jmp .done
    
.in_vblank:
    ; Count during vblank (with timeout)
    xor cx, cx
    mov bx, 0xFFFF
    
.count_vblank:
    in al, dx
    test al, 0x08
    jz .vblank_done
    inc cx
    dec bx
    jnz .count_vblank
    
.vblank_done:
    mov ax, cx
    
.done:
    sti
    pop dx
    pop bx
    ret

; ============================================================================
; count_scanlines - Count total scanlines per frame
; Returns: AX = scanline count (with timeout protection)
; ============================================================================
count_scanlines:
    push bx
    push dx
    cli
    
    mov dx, PORT_STATUS
    xor cx, cx
    
    ; Wait for vblank to start (with timeout)
    mov bx, 0xFFFF
.wait_vblank:
    in al, dx
    test al, 0x08
    jnz .in_vblank
    dec bx
    jnz .wait_vblank
    xor ax, ax
    jmp .done
    
.in_vblank:
    ; Wait for vblank to end (with timeout)
    mov bx, 0xFFFF
.wait_frame:
    in al, dx
    test al, 0x08
    jz .frame_start
    dec bx
    jnz .wait_frame
    xor ax, ax
    jmp .done
    
.frame_start:
    ; Count scanlines until next vblank (with timeout)
    xor cx, cx
    mov bx, 0x1000              ; Limit to ~4000 lines max
    
.count_loop:
    ; Wait for hsync (with inner timeout)
    push bx
    mov bx, 0xFFF
.wait_hsync:
    in al, dx
    test al, 0x01
    jnz .got_hsync
    dec bx
    jnz .wait_hsync
    pop bx
    jmp .count_done             ; Inner timeout = done
    
.got_hsync:
    pop bx
    inc cx
    
    ; Check if in vblank
    test al, 0x08
    jnz .count_done
    
    ; Wait for NOT hsync (with inner timeout)
    push bx
    mov bx, 0xFFF
.wait_not_hsync:
    in al, dx
    test al, 0x01
    jz .not_hsync
    dec bx
    jnz .wait_not_hsync
    pop bx
    jmp .count_done
    
.not_hsync:
    pop bx
    dec bx
    jnz .count_loop
    
.count_done:
    mov ax, cx
    
.done:
    sti
    pop dx
    pop bx
    ret

; ============================================================================
; print_string - Print null-terminated string using DOS
; SI = string pointer
; ============================================================================
print_string:
    push ax
    push dx
.loop:
    lodsb
    or al, al
    jz .done
    mov dl, al
    mov ah, 0x02                ; DOS: Print character
    int 0x21
    jmp .loop
.done:
    pop dx
    pop ax
    ret

; ============================================================================
; print_number - Print 16-bit number in decimal using DOS
; AX = number
; ============================================================================
print_number:
    push ax
    push bx
    push cx
    push dx
    
    ; Handle zero specially
    or ax, ax
    jnz .not_zero
    mov dl, '0'
    mov ah, 0x02
    int 0x21
    jmp .print_done
    
.not_zero:
    mov bx, 10
    xor cx, cx
    
.divide:
    xor dx, dx
    div bx
    add dl, '0'                 ; Convert to ASCII
    push dx
    inc cx
    or ax, ax
    jnz .divide
    
.print:
    pop dx
    mov ah, 0x02                ; DOS: Print character
    int 0x21
    loop .print
    
.print_done:
    pop dx
    pop cx
    pop bx
    pop ax
    ret

; ============================================================================
; print_newline - Output CR+LF
; ============================================================================
print_newline:
    push ax
    push bx
    push dx
    
    ; Use DOS INT 21h for reliable newline
    mov ah, 0x02                ; DOS: Print character
    mov dl, 13                  ; CR
    int 0x21
    mov dl, 10                  ; LF
    int 0x21
    
    pop dx
    pop bx
    pop ax
    ret

; ============================================================================
; Data
; ============================================================================
scanline_count:  dw 0
vblank_count:    dw 0
total_scanlines: dw 0

msg_scanline:    db 'Loop iterations per scanline: ', 0
msg_vblank:      db 'Loop iterations during vblank: ', 0
msg_lines:       db 'Scanlines per frame: ', 0
msg_est_cycles:  db 'Est. CPU cycles per scanline: ', 0
msg_testing:     db 'Testing: ', 0
msg_done:        db 'Press any key to exit...', 0
