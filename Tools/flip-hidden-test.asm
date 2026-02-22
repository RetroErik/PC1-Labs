; ============================================================================
; FLIP-HIDDEN-TEST.ASM - Test port 0xD9 bit 5 in hidden 160x200x16 mode
; Written for NASM - NEC V40 (80186 compatible)
; By Retro Erik - 2026
;
; Purpose: Determine if port 0xD9 bit 5 (CGA palette flip) has any
;          visible effect in the hidden 160x200x16 graphics mode.
;
; Test setup:
;   - Enters hidden 160x200x16 mode
;   - Sets entries 0-7 to distinct warm colors (reds/yellows)
;   - Sets entries 8-15 to distinct cool colors (blues/greens)
;   - Fills screen with a test pattern using all 16 pixel values
;   - Press SPACE to toggle port 0xD9 bit 5
;   - Press ESC to exit
;
; CONFIRMED RESULT (February 22, 2026 — tested on real PC1 hardware):
;   Outcome A: Port 0xD9 bit 5 is IGNORED in hidden 160x200x16 mode.
;   Toggling bit 5 produced no visible change to the 16 color bars.
;   Only the intentional white border flash (confirming keypress) was
;   observed. The CGA palette select MUX has no effect when the pixel
;   path is 4 bits wide — all 16 palette entries are always active.
;
; Implication:
;   There is no hardware double-buffering mechanism for per-scanline
;   palette changes in hidden mode. The "Simone flip" technique from
;   CGA mode 4 (PC1-BMP2) cannot be adapted. Per-scanline palette
;   updates in hidden mode must write directly to live/visible entries
;   during HBLANK (~76 cycles available, enough for 2 entries).
; ============================================================================

[BITS 16]
[ORG 0x100]

; ============================================================================
; Constants
; ============================================================================
VIDEO_SEG       equ 0xB000      ; PC1 video RAM segment
PORT_REG_ADDR   equ 0xDD        ; 6355 Register Bank Address Port
PORT_REG_DATA   equ 0xDE        ; 6355 Register Bank Data Port
PORT_MODE       equ 0xD8        ; CGA Mode Control Port
PORT_COLOR      equ 0xD9        ; CGA Color Select Port

; ============================================================================
; Main Entry Point
; ============================================================================
main:
    ; Print instructions
    mov dx, msg_info
    mov ah, 0x09
    int 0x21

    ; Wait for any key to start
    xor ah, ah
    int 0x16

    ; Enable hidden 160x200x16 mode
    call enable_graphics_mode

    ; Set test palette
    call set_test_palette

    ; Fill screen with test pattern
    call fill_test_pattern

    ; Enable video
    mov al, 0x4A            ; Graphics mode, video ON
    out PORT_MODE, al

    ; Print on-screen hint via border flash
    ; (can't print text in graphics mode)

    ; Main loop - toggle on SPACE, exit on ESC
.main_loop:
    xor ah, ah
    int 0x16                ; Wait for keypress

    cmp al, 0x1B            ; ESC?
    je .exit

    cmp al, ' '             ; SPACE?
    jne .main_loop

    ; Toggle bit 5 of port 0xD9
    xor byte [flip_state], 0x20
    mov al, [flip_state]
    out PORT_COLOR, al

    ; Also flash border briefly to confirm keypress registered
    mov al, 0x0F            ; White border flash
    out PORT_COLOR, al

    ; Small delay for flash visibility
    mov cx, 0x8000
.flash_delay:
    loop .flash_delay

    ; Restore border to current flip state
    mov al, [flip_state]
    out PORT_COLOR, al

    jmp .main_loop

.exit:
    ; Reset palette to CGA defaults
    call set_cga_palette

    ; Disable graphics mode
    call disable_graphics_mode

    ; Restore text mode
    mov ax, 0x0003
    int 0x10

    ; Print result prompt
    mov dx, msg_done
    mov ah, 0x09
    int 0x21

    ; Exit to DOS
    mov ax, 0x4C00
    int 0x21

; ============================================================================
; enable_graphics_mode - Olivetti PC1 hidden 160x200x16 mode
; ============================================================================
enable_graphics_mode:
    push ax

    ; Set monitor control register 0x65
    mov al, 0x65
    out PORT_REG_ADDR, al
    jmp short $+2
    mov al, 0x09            ; 200 lines, PAL, color
    out PORT_REG_DATA, al
    jmp short $+2

    ; Unlock 16-color mode + video OFF (blank during setup)
    mov al, 0x42            ; Graphics mode, video OFF
    out PORT_MODE, al
    jmp short $+2

    ; Border = black
    xor al, al
    out PORT_COLOR, al
    jmp short $+2

    pop ax
    ret

; ============================================================================
; disable_graphics_mode - Reset V6355 for text mode
; ============================================================================
disable_graphics_mode:
    push ax

    mov al, 0x65
    out PORT_REG_ADDR, al
    jmp short $+2
    mov al, 0x09
    out PORT_REG_DATA, al
    jmp short $+2

    mov al, 0x28
    out PORT_MODE, al
    jmp short $+2

    pop ax
    ret

; ============================================================================
; set_test_palette - Warm colors in 0-7, cool colors in 8-15
; Designed so any palette shift/swap is immediately obvious.
;
; 6355 palette format (2 bytes per entry):
;   Byte 1: Red   (bits 0-2, values 0-7)
;   Byte 2: Green (bits 4-6) | Blue (bits 0-2)
; ============================================================================
set_test_palette:
    push ax
    push cx
    push si

    cli

    ; Open palette at entry 0
    mov al, 0x40
    out PORT_REG_ADDR, al
    jmp short $+2

    ; Write 16 entries (32 bytes)
    mov si, test_palette
    mov cx, 32
.pal_loop:
    lodsb
    out PORT_REG_DATA, al
    jmp short $+2
    loop .pal_loop

    ; Close palette
    mov al, 0x80
    out PORT_REG_ADDR, al

    sti

    pop si
    pop cx
    pop ax
    ret

; ============================================================================
; fill_test_pattern - 16 vertical color bars (each 10 pixels wide = 160 total)
; Each bar uses pixel value 0-15 so all palette entries are visible.
; In 160x200x16 mode: 4bpp, 2 pixels per byte, 80 bytes per row.
; CGA-style interleaving: even rows at offset 0, odd rows at +0x2000.
; ============================================================================
fill_test_pattern:
    push ax
    push bx
    push cx
    push dx
    push di
    push es

    mov ax, VIDEO_SEG
    mov es, ax

    ; First clear all video memory
    xor di, di
    mov cx, 8192            ; 16KB = 8192 words
    xor ax, ax
    cld
    rep stosw

    ; Now fill with 16 vertical bars
    ; Each bar is 10 pixels wide = 5 bytes (since 2 pixels/byte)
    ; Bar N uses pixel value N for both nibbles: byte = (N << 4) | N
    ;
    ; Row layout (80 bytes):
    ;   Bytes 0-4:   bar 0  (pixel value 0x00)
    ;   Bytes 5-9:   bar 1  (pixel value 0x11)
    ;   Bytes 10-14: bar 2  (pixel value 0x22)
    ;   ...
    ;   Bytes 75-79: bar 15 (pixel value 0xFF)

    xor dx, dx              ; DX = current row (0-199)

.row_loop:
    ; Calculate video offset for this row
    mov ax, dx
    push dx
    shr ax, 1               ; AX = row / 2
    mov bx, 80
    push dx
    mul bx                  ; AX = (row/2) * 80
    pop dx
    mov di, ax

    pop dx                  ; Restore row number
    test dl, 1              ; Odd row?
    jz .even_row
    add di, 0x2000          ; Odd rows offset
.even_row:

    ; Fill this row with 16 bars
    xor bx, bx              ; BX = bar index (0-15)

.bar_loop:
    ; Create byte: (bar_index << 4) | bar_index
    mov al, bl
    shl al, 4
    or al, bl               ; AL = 0x00, 0x11, 0x22, ... 0xFF

    ; Write 5 bytes for this bar (10 pixels)
    mov cx, 5
.pixel_loop:
    mov [es:di], al
    inc di
    loop .pixel_loop

    inc bx
    cmp bx, 16
    jb .bar_loop

    ; Next row
    inc dx
    cmp dx, 200
    jb .row_loop

    pop es
    pop di
    pop dx
    pop cx
    pop bx
    pop ax
    ret

; ============================================================================
; set_cga_palette - Restore standard CGA text palette
; ============================================================================
set_cga_palette:
    push ax
    push cx
    push si

    cli

    mov al, 0x40
    out PORT_REG_ADDR, al
    jmp short $+2

    mov si, cga_colors
    mov cx, 32
.pal_loop:
    lodsb
    out PORT_REG_DATA, al
    jmp short $+2
    loop .pal_loop

    mov al, 0x80
    out PORT_REG_ADDR, al

    sti

    pop si
    pop cx
    pop ax
    ret

; ============================================================================
; Data
; ============================================================================

msg_info    db 'FLIP-HIDDEN-TEST - Port 0xD9 bit 5 test in hidden 16-color mode', 0x0D, 0x0A
            db 0x0D, 0x0A
            db 'This tests whether the CGA palette flip (port 0xD9 bit 5)', 0x0D, 0x0A
            db 'has any effect in the hidden 160x200x16 graphics mode.', 0x0D, 0x0A
            db 0x0D, 0x0A
            db 'You will see 16 vertical color bars.', 0x0D, 0x0A
            db 'Bars 0-7 are warm (reds/oranges/yellows).', 0x0D, 0x0A
            db 'Bars 8-15 are cool (cyans/blues/greens).', 0x0D, 0x0A
            db 0x0D, 0x0A
            db 'Controls:', 0x0D, 0x0A
            db '  SPACE = Toggle port 0xD9 bit 5 (white flash confirms)', 0x0D, 0x0A
            db '  ESC   = Exit', 0x0D, 0x0A
            db 0x0D, 0x0A
            db 'Watch for ANY change when pressing SPACE!', 0x0D, 0x0A
            db 'Press any key to start...', 0x0D, 0x0A, '$'

msg_done    db 0x0D, 0x0A
            db 'Test complete. What did you observe?', 0x0D, 0x0A
            db '  A) No change at all  (bit 5 ignored in hidden mode)', 0x0D, 0x0A
            db '  B) Colors shifted    (bit 5 offsets palette addressing)', 0x0D, 0x0A
            db '  C) Something else    (please describe!)', 0x0D, 0x0A, '$'

flip_state  db 0x00

; ============================================================================
; Test palette: 16 entries, designed for maximum visual contrast
; Entries 0-7:  Warm spectrum (black, dark red, red, orange, yellow, ...)
; Entries 8-15: Cool spectrum (dark blue, blue, cyan, green, ...)
;
; Format: Red (3-bit), Green|Blue packed byte
; ============================================================================
test_palette:
    ; Entry 0:  BLACK        R=0 G=0 B=0
    db 0x00, 0x00
    ; Entry 1:  DARK RED     R=3 G=0 B=0
    db 0x03, 0x00
    ; Entry 2:  RED          R=7 G=0 B=0
    db 0x07, 0x00
    ; Entry 3:  ORANGE       R=7 G=3 B=0  (G=3 → bits 4-6 = 0x30)
    db 0x07, 0x30
    ; Entry 4:  YELLOW       R=7 G=7 B=0  (G=7 → bits 4-6 = 0x70)
    db 0x07, 0x70
    ; Entry 5:  LIGHT YELLOW R=7 G=7 B=3
    db 0x07, 0x73
    ; Entry 6:  PINK         R=7 G=2 B=5
    db 0x07, 0x25
    ; Entry 7:  MAGENTA      R=5 G=0 B=7
    db 0x05, 0x07

    ; Entry 8:  DARK BLUE    R=0 G=0 B=3
    db 0x00, 0x03
    ; Entry 9:  BLUE         R=0 G=0 B=7
    db 0x00, 0x07
    ; Entry 10: DARK CYAN    R=0 G=3 B=5
    db 0x00, 0x35
    ; Entry 11: CYAN         R=0 G=7 B=7
    db 0x00, 0x77
    ; Entry 12: DARK GREEN   R=0 G=3 B=0
    db 0x00, 0x30
    ; Entry 13: GREEN        R=0 G=7 B=0
    db 0x00, 0x70
    ; Entry 14: LIGHT GREEN  R=3 G=7 B=3
    db 0x03, 0x73
    ; Entry 15: WHITE        R=7 G=7 B=7
    db 0x07, 0x77

; ============================================================================
; Standard CGA text mode palette (for restore on exit)
; ============================================================================
cga_colors:
    db 0x00, 0x00    ; 0:  Black
    db 0x00, 0x05    ; 1:  Blue
    db 0x00, 0x50    ; 2:  Green
    db 0x00, 0x55    ; 3:  Cyan
    db 0x05, 0x00    ; 4:  Red
    db 0x05, 0x05    ; 5:  Magenta
    db 0x05, 0x20    ; 6:  Brown
    db 0x05, 0x55    ; 7:  Light Gray
    db 0x02, 0x22    ; 8:  Dark Gray
    db 0x02, 0x27    ; 9:  Light Blue
    db 0x02, 0x72    ; 10: Light Green
    db 0x02, 0x77    ; 11: Light Cyan
    db 0x07, 0x22    ; 12: Light Red
    db 0x07, 0x27    ; 13: Light Magenta
    db 0x07, 0x70    ; 14: Yellow
    db 0x07, 0x77    ; 15: White
