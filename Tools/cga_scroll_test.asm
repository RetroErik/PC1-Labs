; ============================================================================
; CGA_SCROLL_TEST.ASM - CGA Hardware Scroll R12/R13 Verification
; Olivetti Prodest PC1 - V6355D 160x200x16 Hidden Graphics Mode
; Written for NASM - NEC V40 @ 8 MHz (80186 instruction set)
; By RetroErik - 2026
;
; Purpose:
;   Test if CGA CRTC R12/R13 (Start Address registers) control scrolling.
;   The V6355D datasheet mentions "6845 restricted mode for IBM-PC compatibility"
;   so hardware scrolling MIGHT be available via standard CGA CRTC ports.
;   Uses border color as diagnostic feedback for I/O operations.
;
; Controls:
;   , (comma)   = Scroll up (decrease start address)
;   . (period)  = Scroll down (increase start address)
;   R           = Reset start address to 0
;   ESC or Q    = Exit program
;
; Diagnostics (border color feedback):
;   Red border  = Comma key detected
;   Green border = Period key detected
;   Blue border = R key detected
;   White flash = CRTC register write attempt
;   Black       = Normal
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
PORT_MODE       equ 0x3D8          ; Mode control register
PORT_CRTC_ADDR  equ 0x3D4          ; CRTC Address port (select register)
PORT_CRTC_DATA  equ 0x3D5          ; CRTC Data port (read/write register)
PORT_STATUS     equ 0x3DA          ; Status register (bit 3=VBlank)

; CRTC Register definitions
CRTC_START_ADDR_HIGH equ 12        ; R12 = Start Address High byte
CRTC_START_ADDR_LOW  equ 13        ; R13 = Start Address Low byte

; ============================================================================
; Main Program Entry Point
; ============================================================================

main:
    ; Enable graphics mode (0x4A = graphics on, bit 6 unlock)
    mov al, 0x4A
    out PORT_MODE, al
    jmp short $+2
    
    ; Set up a simple 4-color palette
    call set_palette
    
    ; Fill screen with horizontal color bands
    call fill_color_bands
    
    ; Initialize start address to 0
    mov word [crtc_start_addr], 0
    
.scroll_loop:
    ; Check for keypress (non-blocking)
    mov ah, 0x01
    int 0x16
    jz .scroll_loop                 ; No key pressed, continue
    
    ; Get the keypress
    mov ah, 0x00
    int 0x16                        ; AL = key code
    
    ; Parse key command (using simple ASCII keys instead of scan codes)
    cmp al, ','                     ; Comma = scroll up
    je .scroll_up
    cmp al, '<'                     ; Shift+Comma also accepted
    je .scroll_up
    cmp al, '.'                     ; Period = scroll down
    je .scroll_down
    cmp al, '>'                     ; Shift+Period also accepted
    je .scroll_down
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
    
.scroll_up:
    ; Decrease start address (scroll up = show earlier lines)
    mov ax, [crtc_start_addr]
    cmp ax, 0
    je .scroll_loop                 ; Already at 0
    sub ax, BYTES_PER_LINE          ; Go up one line (80 bytes)
    mov [crtc_start_addr], ax
    jmp .apply_crtc_scroll
    
.scroll_down:
    ; Increase start address (scroll down = show later lines)
    ; Allow scrolling through entire VRAM (16KB = 16384 bytes)
    mov ax, [crtc_start_addr]
    add ax, BYTES_PER_LINE          ; Go down one line (80 bytes)
    
    ; Max scroll: Allow wrapping at VRAM boundary
    ; If reached end, wrap back to start for smooth circular buffer
    cmp ax, VRAM_SIZE
    jl .down_ok
    xor ax, ax                      ; Wrap to beginning
.down_ok:
    mov [crtc_start_addr], ax
    jmp .apply_crtc_scroll
    
.scroll_reset:
    mov word [crtc_start_addr], 0
    
.apply_crtc_scroll:
    ; Write R12/R13 with new start address
    ; R12 = high byte, R13 = low byte
    ; This uses standard CGA CRTC addressing
    
    ; Get start address
    mov ax, [crtc_start_addr]
    
    ; Calculate byte offset to word offset for CRTC
    ; CRTC uses word addressing (each word = 2 bytes = 4 pixels in 4bpp)
    shr ax, 1                       ; Divide by 2 to get word offset
    
    ; Extract high and low bytes
    mov bh, ah                      ; BH = high byte
    mov bl, al                      ; BL = low byte
    
    ; Write R12 (Start Address High)
    mov al, CRTC_START_ADDR_HIGH
    out PORT_CRTC_ADDR, al
    jmp short $+2                   ; I/O delay
    
    mov al, bh
    out PORT_CRTC_DATA, al
    jmp short $+2                   ; I/O delay
    
    ; Write R13 (Start Address Low)
    mov al, CRTC_START_ADDR_LOW
    out PORT_CRTC_ADDR, al
    jmp short $+2                   ; I/O delay
    
    mov al, bl
    out PORT_CRTC_DATA, al
    jmp short $+2                   ; I/O delay
    
    jmp .scroll_loop
    
.exit_program:
    ; Reset R12/R13 to default (0,0)
    mov al, CRTC_START_ADDR_HIGH
    out PORT_CRTC_ADDR, al
    jmp short $+2
    
    xor al, al
    out PORT_CRTC_DATA, al
    jmp short $+2
    
    mov al, CRTC_START_ADDR_LOW
    out PORT_CRTC_ADDR, al
    jmp short $+2
    
    xor al, al
    out PORT_CRTC_DATA, al
    jmp short $+2
    
    ; Disable graphics mode
    mov al, 0x28
    out PORT_MODE, al
    jmp short $+2
    
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
    out 0x3DD, al
    jmp short $+2
    
    ; Write 10 bytes (first 5 colors × 2 bytes each)
    mov dx, 0x3DE
    
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
    out 0x3DD, al
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

crtc_start_addr: dw 0               ; Current CRTC start address (word offset)

; ============================================================================
; End of Program
; ============================================================================
