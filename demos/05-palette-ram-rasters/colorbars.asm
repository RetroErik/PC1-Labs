; ============================================================================
; colorbars.ASM (v 1.0) - Hidden graphics mode demo for Olivetti Prodest PC1
; Hidden 160x200x16 Graphics Mode - 16 Color Bars Only
; Written for NASM - NEC V40 (80186 compatible)
; By Retro Erik - 2026 using VS Code with Co-Pilot
;
; Press any key to exit
; ============================================================================

[BITS 16]
[ORG 0x100]

; ============================================================================
; Constants
; ============================================================================

; --- Video Memory ---
VIDEO_SEG       equ 0xB000      ; PC1 video RAM segment (not B800 like standard CGA!)

; --- Yamaha V6355D I/O Ports ---
PORT_REG_ADDR   equ 0xDD        ; Register Bank Address Port (select register 0x00-0x7F)
PORT_REG_DATA   equ 0xDE        ; Register Bank Data Port (read/write selected register)
PORT_MODE       equ 0xD8        ; Mode Control Register (CGA compatible + extensions)
PORT_COLOR      equ 0xD9        ; Color Select Register (border color, palette index 0-15)

; ============================================================================
; Main Program Entry Point
; ============================================================================
main:
    ; Save original video mode
    mov ah, 0x0F
    int 0x10                    ; Get current video mode
    mov [orig_video_mode], al   ; Save mode in AL
    
    ; Save original text attribute (read from screen position 0,0)
    mov ah, 0x08
    mov bh, 0                   ; Page 0
    int 0x10                    ; Get char+attr at cursor
    mov [orig_text_attr], ah    ; Save attribute in AH
    
    ; Enable the hidden 160x200x16 graphics mode
    call enable_graphics_mode
    
    ; Draw 16 color bars with CGA palette
    call set_cga_palette
    call set_palette
    call clear_screen
    call draw_color_bars
    
    ; Wait for any key
    call wait_key
    
    ; Reset palette to CGA defaults before exiting
    call set_cga_palette
    call set_palette
    
    ; Disable graphics mode (return to text mode)
    call disable_graphics_mode
    
    ; Restore original video mode
    mov ah, 0x00
    mov al, [orig_video_mode]
    int 0x10
    
    ; Clear screen with original text attribute
    mov ah, 0x06                ; Scroll up function
    mov al, 0                   ; Clear entire window
    mov bh, [orig_text_attr]    ; Use original attribute
    xor cx, cx                  ; Upper left (0,0)
    mov dx, 0x184F              ; Lower right (24,79)
    int 0x10
    
    ; Set cursor to top-left
    mov ah, 0x02
    xor bh, bh                  ; Page 0
    xor dx, dx                  ; Row 0, Col 0
    int 0x10
    
    ; Exit to DOS
    mov ax, 0x4C00
    int 0x21

; ============================================================================
; enable_graphics_mode - Olivetti Prodest PC1 hidden 160x200x16 graphics mode
; Configures Yamaha V6355D for hidden 160x200x16 graphics mode:
; - Enables 16-color mode (planar logic, custom palette)
; - Sets border color to black
; ---------------------------------------------------------------------------
enable_graphics_mode:
    push ax
    push dx
    
    ; BIOS Mode 4: CGA 320x200 graphics, sets CRTC for 15.7kHz sync
    mov ax, 0x0004
    int 0x10
    
    ; --- UNLOCK 16-COLOR MODE (Port 0xD8, value 0x4A) ---
    ; This is the CGA Mode Control Register, but the PC1's Yamaha V6355D 
    ; repurposes several bits for extended functionality.
    ;
    ; Standard CGA bits (IBM PC/XT compatible):
    ; Bit 0: [0] Text mode column width (0 = 40×25, 1 = 80×25)
    ; Bit 1: [1] Graphics mode enable (0 = text, 1 = graphics)
    ; Bit 2: [0] Video signal type (0 = color burst, 1 = mono)
    ; Bit 3: [1] Video enable (0 = blank, 1 = display)
    ; Bit 4: [0] High-res graphics (0 = 320x200, 1 = 640x200)
    ;
    ; Extended PC1/Yamaha V6355D bits:
    ; Bit 5: [0] Blink/Background (text mode only)
    ; Bit 6: [1] MODE UNLOCK (Yamaha extension)
    ;         1 = Enable 16-color planar logic (160x200)
    ;         0 = Standard 4-color CGA mode
    ; Bit 7: [0] STANDBY MODE (V6355D Datasheet)
    ;         0 = Normal operation
    ;         1 = Power save mode (display blank)
    ;
    ; Value 0x4A = 01001010b
    ;   Bit 6 = 1 (MODE UNLOCK: enable 16-color planar)
    ;   Bit 3 = 1 (Video enable)
    ;   Bit 1 = 1 (Graphics mode)
    ;   All other bits = 0
    mov al, 0x4A
    out PORT_MODE, al
    jmp short $+2
    jmp short $+2
    
    ; Port 0xD9: 0x00 = black border
    xor al, al
    out PORT_COLOR, al
    jmp short $+2
    jmp short $+2
    
    pop dx
    pop ax
    ret

; ============================================================================
; disable_graphics_mode - Disable the hidden graphics mode
; ============================================================================
disable_graphics_mode:
    push ax
    push dx
    
    ; --- RESET 16-COLOR MODE (Port 0xD8, value 0x28) ---
    ; Reset mode control port to standard CGA mode
    ; 0x28 = text mode (bit 5=1 blink, bit 3=1 video on)
    mov al, 0x28
    out PORT_MODE, al
    jmp short $+2
    
    pop dx
    pop ax
    ret

; ============================================================================
; clear_screen - Clear video memory to black (color 0)
; ============================================================================
clear_screen:
    push ax
    push cx
    push di
    push es
    
    mov ax, VIDEO_SEG
    mov es, ax
    xor di, di
    mov cx, 8192            ; 16KB = 8192 words (0x4000 bytes)
    xor ax, ax              ; Fill with 0x0000
    cld
    rep stosw
    
    pop es
    pop di
    pop cx
    pop ax
    ret

; ============================================================================
; set_palette - Write the 16-color palette to the 6355 chip
;   MOV AL, 0x40 / OUT 0xDD, AL   ; Enable palette write
;   Loop with OUT to port 0xDE    ; Output 32 bytes with I/O delays
;   MOV AL, 0x80 / OUT 0xDD, AL   ; Disable palette write
;
; Palette format: 32 bytes (16 colors × 2 bytes each)
;   Byte 1: Red intensity (bits 0-2, values 0-7)
;   Byte 2: Green (bits 4-6) + Blue (bits 0-2)
; ============================================================================
set_palette:
    push ax
    push cx
    push si
    
    cli                     ; Disable interrupts during palette write
    
    ; Enable palette write mode (write 0x40 to port 0xDD)
    mov al, 0x40
    out PORT_REG_ADDR, al
    jmp short $+2           ; I/O delay
    jmp short $+2
    
    ; Write 32 bytes of palette data with I/O delays (PC1 hardware needs this!)
    mov si, palette
    mov cx, 32              ; 16 colors × 2 bytes
    
.pal_write_loop:
    lodsb                   ; Load byte from DS:SI into AL, inc SI
    out PORT_REG_DATA, al   ; Write to port 0xDE
    jmp short $+2           ; I/O delay
    loop .pal_write_loop
    
    ; Disable palette write mode (write 0x80 to port 0xDD)
    jmp short $+2           ; Extra delay before mode change
    mov al, 0x80
    out PORT_REG_ADDR, al
    jmp short $+2           ; I/O delay
    
    sti                     ; Re-enable interrupts
    
    pop si
    pop cx
    pop ax
    ret

; ============================================================================
; draw_color_bars - Draw 16 vertical color bars on screen
; Uses [bar_width] to set pixel width of each bar (1-10 pixels)
; Always draws exactly 16 bars, starting from left edge
; Color 0 = black (matches border)
; Remaining pixels after 16 bars stay black
; ============================================================================
draw_color_bars:
    push ax
    push bx
    push cx
    push dx
    push di
    push si
    push es
    
    ; First clear the screen (fills with black/color 0)
    call clear_screen
    
    mov ax, VIDEO_SEG
    mov es, ax
    
    ; Calculate total width of all 16 bars
    mov al, [bar_width]
    xor ah, ah
    shl ax, 4               ; AX = bar_width * 16 = total pixels for all bars
    cmp ax, 160
    jbe .width_ok
    mov ax, 160             ; Cap at screen width
.width_ok:
    mov [bars_total_width], ax
    
    ; Draw all 200 rows using fast byte writes
    xor si, si              ; SI = row counter (0-199)
    
.row_loop:
    ; Calculate base offset for this row
    ; Even rows: offset = (row/2) * 80
    ; Odd rows:  offset = 0x2000 + (row/2) * 80
    mov ax, si
    shr ax, 1               ; AX = row / 2
    mov bx, 80
    mul bx                  ; AX = (row/2) * 80
    mov di, ax
    test si, 1              ; Check if odd row
    jz .even_row
    add di, 0x2000          ; Odd rows start at 0x2000
.even_row:
    
    ; For each row, write bytes for the bar area only
    xor bx, bx              ; BX = pixel position (0-159)
    
.pixel_loop:
    ; Check if we're past all 16 bars
    cmp bx, [bars_total_width]
    jae .row_done           ; Past bar area, rest stays black
    
    ; Calculate which color this pixel belongs to
    mov ax, bx
    mov cl, [bar_width]
    xor ch, ch
    div cl                  ; AL = pixel / bar_width = color index (0-15)
    mov dl, al              ; DL = left pixel color
    
    ; Get right pixel color (pixel + 1)
    mov ax, bx
    inc ax
    cmp ax, [bars_total_width]
    jae .right_black        ; Right pixel is past bar area
    div cl                  ; AL = (pixel+1) / bar_width
    jmp .combine
    
.right_black:
    xor al, al              ; Right pixel is black (color 0)
    
.combine:
    ; DL = left color, AL = right color
    ; Combine: byte = (left << 4) | right
    shl dl, 4
    or dl, al
    
    ; Write byte to video memory
    mov [es:di], dl
    inc di
    
    ; Advance by 2 pixels
    add bx, 2
    cmp bx, 160
    jb .pixel_loop
    
.row_done:
    ; Next row
    inc si
    cmp si, 200
    jb .row_loop
    
    pop es
    pop si
    pop di
    pop dx
    pop cx
    pop bx
    pop ax
    ret

bars_total_width: dw 160    ; Total width of all 16 bars in pixels

; ============================================================================
; set_cga_palette - Set palette to standard CGA text mode colors
; Copies the 16 CGA colors to the palette buffer
; ============================================================================
set_cga_palette:
    push cx
    push si
    push di
    
    mov si, cga_colors
    mov di, palette
    mov cx, 32              ; 16 colors × 2 bytes
    cld
    rep movsb
    
    pop di
    pop si
    pop cx
    ret

; ============================================================================
; Standard CGA text mode palette (16 colors)
; Format: Byte 1 = Red (bits 0-2), Byte 2 = Green (bits 4-6) | Blue (bits 0-2)
; ============================================================================
cga_colors:
    db 0x00, 0x00    ; 0:  Black
    db 0x00, 0x05    ; 1:  Blue
    db 0x00, 0x50    ; 2:  Green
    db 0x00, 0x55    ; 3:  Cyan
    db 0x05, 0x00    ; 4:  Red
    db 0x05, 0x05    ; 5:  Magenta
    db 0x05, 0x20    ; 6:  Brown (dark yellow-orange)
    db 0x05, 0x55    ; 7:  Light Gray
    db 0x02, 0x22    ; 8:  Dark Gray
    db 0x02, 0x27    ; 9:  Light Blue
    db 0x02, 0x72    ; 10: Light Green
    db 0x02, 0x77    ; 11: Light Cyan
    db 0x07, 0x22    ; 12: Light Red
    db 0x07, 0x27    ; 13: Light Magenta
    db 0x07, 0x70    ; 14: Yellow
    db 0x07, 0x77    ; 15: White

; ============================================================================
; wait_key - Wait for a key press
; Output: AL = ASCII code of key pressed
; ============================================================================
wait_key:
    mov ah, 0x00
    int 0x16                    ; BIOS keyboard read
    ret

; ============================================================================
; Data Section
; ============================================================================

bar_width:      db 10           ; Bar width in pixels (1-10)
orig_video_mode: db 0           ; Original video mode before program start
orig_text_attr: db 0x07         ; Original text attribute (default: light gray on black)

; Palette buffer - 32 bytes (16 colors × 2 bytes each)
palette:
    times 32 db 0

; ============================================================================
; End of program
; ============================================================================