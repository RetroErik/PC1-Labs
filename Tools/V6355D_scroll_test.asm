; ============================================================================
; SCROLL_TEST.ASM - Hardware Scroll Register 0x64 Verification
; Olivetti Prodest PC1 - V6355D 160x200x16 Hidden Graphics Mode
; Written for NASM - NEC V40 @ 8 MHz (80186 instruction set)
; By RetroErik - 2026
;
; TEST RESULTS (February 2, 2026):
; ================================
; Register 0x64 (Bits 3-5) "Vertical Adjustment" - TESTED IN GRAPHICS MODE
;
; Finding: Register 0x64 DOES control vertical scrolling!
;   - Limited range: ±8 lines (3 bits = 2^3 = 8 values: 0-7)
;   - Write operations do NOT crash (register is valid)
;   - Screen visibly shifts by 0-7 rows based on bits 3-5 value
;   - Matches Z-180 manual: "Vertical adjustment (rows to shift screen up)"
;   - Side effect: Colors may shift during register writes
;
; Conclusion: V6355D Register 0x64 works for vertical scrolling
;   - Useful for small adjustments (monitor calibration, micro-scrolling)
;   - Limited to 8-row range (not practical for full-screen scrolling)
;   - For smooth full-screen pan: Use CGA CRTC R12/R13 (cga_scroll_test.asm)
;
; RECOMMENDATION: 
;   - Small adjustments (±4 lines): Use Register 0x64 (simpler)
;   - Full-screen tall image scrolling: Use CGA CRTC R12/R13 (unlimited range)
;
; Note: Only tested in graphics mode (0x4A). Text mode behavior unknown.
;
; ============================================================================

[BITS 16]
[CPU 186]
[ORG 0x100]

; ============================================================================
; Constants
; ============================================================================

VIDEO_SEG       equ 0xB000
BYTES_PER_LINE  equ 80
SCREEN_HEIGHT   equ 200
VRAM_SIZE       equ 16384          ; Full VRAM size (16KB)

; Port definitions
PORT_MODE       equ 0x3D8       ; Mode control register
PORT_REG_ADDR   equ 0x3DD       ; Register bank address
PORT_REG_DATA   equ 0x3DE       ; Register bank data
PORT_STATUS     equ 0x3DA       ; Status register (bit 3=VBlank)

; ============================================================================
; Main Program Entry Point
; ============================================================================

main:
    ; Enable graphics mode (0x4A = graphics on, bit 6 unlock)
    mov al, 0x4A
    out PORT_MODE, al
    
    ; Set up a simple 4-color palette
    call set_palette
    
    ; Fill screen with horizontal color bands
    call fill_color_bands
    
    ; Display text instructions in text mode area (if visible)
    ; Most of screen is now graphics, but we can still communicate
    
.scroll_loop:
    ; Check for keypress (non-blocking)
    mov ah, 0x01
    int 0x16
    jz .scroll_loop                 ; No key pressed, continue
    
    ; Get the keypress
    mov ah, 0x00
    int 0x16                        ; AL = key code
    
    ; Parse key command
    cmp al, ','                     ; Comma = scroll up
    je .try_scroll_up
    cmp al, '<'                     ; Shift+Comma also accepted
    je .try_scroll_up
    cmp al, '.'                     ; Period = scroll down
    je .try_scroll_down
    cmp al, '>'                     ; Shift+Period also accepted
    je .try_scroll_down
    cmp al, 'r'
    je .scroll_reset
    cmp al, 'R'
    je .scroll_reset
    cmp al, 0x1B                    ; ESC
    je .exit_program
    cmp al, 'q'
    je .exit_program
    cmp al, 'Q'
    je .exit_program
    
    ; Unknown key, loop
    jmp .scroll_loop
    
.try_scroll_up:
    mov ax, [scroll_offset]
    cmp ax, 0
    je .scroll_loop                 ; Already at min
    dec ax
    mov [scroll_offset], ax
    jmp .attempt_register_write
    
.try_scroll_down:
    mov ax, [scroll_offset]
    add ax, 1
    cmp ax, 7                       ; Max 7 for 3-bit value
    jge .scroll_loop                ; Already at max
    mov [scroll_offset], ax
    jmp .attempt_register_write
    
.scroll_reset:
    mov byte [scroll_offset], 0
    jmp .attempt_register_write
    
.attempt_register_write:
    ; This is where Register 0x64 write will be attempted
    ; If program crashes here, Register 0x64 is NOT supported
    
    ; Select Register 0x64
    mov al, 0x64
    out PORT_REG_ADDR, al
    jmp short $+2                   ; I/O delay required
    
    ; Create value with scroll bits set
    mov al, [scroll_offset]
    shl al, 3                       ; Shift value to bits 3-5
    and al, 0x38                    ; Mask to ensure only bits 3-5 used
    
    ; Write to Register 0x64 (THIS LIKELY CRASHES IF NOT SUPPORTED)
    out PORT_REG_DATA, al
    jmp short $+2                   ; I/O delay
    
    ; If we reach here, write succeeded!
    jmp .scroll_loop
    
.exit_program:
    ; Reset Register 0x64 to default
    mov al, 0x64
    out PORT_REG_ADDR, al
    jmp short $+2
    
    xor al, al                      ; Write 0 (no scroll adjustment)
    out PORT_REG_DATA, al
    jmp short $+2
    
    ; Disable graphics mode
    mov al, 0x28
    out PORT_MODE, al
    
    ; Return to text mode
    mov ax, 0x0003
    int 0x10
    
    ; Exit to DOS
    mov ax, 0x4C00
    int 0x21

; ============================================================================
; set_palette - Initialize 4-color palette for testing
; Colors: 0=Black, 1=White, 2=Red, 3=Green, 4=Blue
; ============================================================================

set_palette:
    push ax
    push cx
    push si
    push dx
    
    cli
    
    ; Enable palette write at register 0x40 (start at color 0)
    mov al, 0x40
    out PORT_REG_ADDR, al
    jmp short $+2
    
    ; Write 10 bytes (first 5 colors × 2 bytes each)
    mov dx, PORT_REG_DATA
    
    ; Color 0: Black (R=0, G=0, B=0)
    mov al, 0x00
    out dx, al
    jmp short $+2
    mov al, 0x00
    out dx, al
    jmp short $+2
    
    ; Color 1: White (R=7, G=7, B=7) - for test band 1
    mov al, 0x07
    out dx, al
    jmp short $+2
    mov al, 0x77
    out dx, al
    jmp short $+2
    
    ; Color 2: Red (R=7, G=0, B=0) - for test band 2
    mov al, 0x07
    out dx, al
    jmp short $+2
    mov al, 0x00
    out dx, al
    jmp short $+2
    
    ; Color 3: Green (R=0, G=7, B=0) - for test band 3
    mov al, 0x00
    out dx, al
    jmp short $+2
    mov al, 0x70
    out dx, al
    jmp short $+2
    
    ; Color 4: Blue (R=0, G=0, B=7) - for test band 4
    mov al, 0x00
    out dx, al
    jmp short $+2
    mov al, 0x07
    out dx, al
    jmp short $+2
    
    ; Disable palette write mode
    mov al, 0x80
    out PORT_REG_ADDR, al
    jmp short $+2
    
    sti
    
    pop dx
    pop si
    pop cx
    pop ax
    ret

; ============================================================================
; fill_color_bands - Fill entire VRAM (16384 bytes) with color bands
;
; Band layout (40 rows each = 200 rows + 384 bytes padding):
;   Rows 0-39:    Color 1 (White)
;   Rows 40-79:   Color 2 (Red)
;   Rows 80-119:  Color 3 (Green)
;   Rows 120-159: Color 4 (Blue)
;   Rows 160-199: Color 1 (White)
;   Bytes 16000-16383: Padding with white (384 bytes)
; ============================================================================

fill_color_bands:
    pusha
    push es
    
    mov ax, VIDEO_SEG
    mov es, ax
    
    ; Fill entire VRAM (16384 bytes / 2 = 8192 words) with white first
    xor di, di
    mov cx, VRAM_SIZE / 2           ; 8192 words
    mov ax, 0x1111                  ; White in both pixels
    cld
    rep stosw
    
    ; Now fill color bands (overwrite the white where bands should be)
    ; Band 0 (0-39): White (keep as is)
    
    ; Band 1 (40-79): Red (0x22)
    mov di, 40 * BYTES_PER_LINE
    mov cx, 40 * BYTES_PER_LINE / 2
    mov ax, 0x2222
    rep stosw
    
    ; Band 2 (80-119): Green (0x33)
    mov di, 80 * BYTES_PER_LINE
    mov cx, 40 * BYTES_PER_LINE / 2
    mov ax, 0x3333
    rep stosw
    
    ; Band 3 (120-159): Blue (0x44)
    mov di, 120 * BYTES_PER_LINE
    mov cx, 40 * BYTES_PER_LINE / 2
    mov ax, 0x4444
    rep stosw
    
    ; Band 4 (160-199): White (keep as is)
    
    pop es
    popa
    ret

; ============================================================================
; Data Section
; ============================================================================

scroll_offset: db 0                     ; Current scroll offset (0-7)

; ============================================================================
; End of Program
; ============================================================================
