; ============================================================================
; RBARS2.ASM - Full-Screen Raster Bar Demo for Olivetti Prodest PC1
; Horizontal scrolling raster bars using per-scanline color changes
; Written for NASM - NEC V40 (80186 compatible) @ 8 MHz
; By Retro Erik - 2026 with help from GitHub Copilot
;
; Target: Olivetti PC1 with Yamaha V6355D video controller
; Video Mode: CGA 160x200x16 (Hidden mode)
;
; Technique:
;   - Changes PORT_COLOR per scanline during hsync
;   - Uses static precomputed pattern table (no per-frame calculation)
;   - Scroll offset advances each frame for smooth animation
;
; Controls:
;   Any key - Exit to DOS
;
; Prerequisites:
;   Run PERITEL.COM first to set horizontal position correctly
; ============================================================================

[BITS 16]
[ORG 0x100]

; ============================================================================
; Constants
; ============================================================================

VIDEO_SEG       equ 0xB000      ; PC1 video RAM segment

; Yamaha V6355D I/O Ports
PORT_REG_ADDR   equ 0x3DD       ; Register address port
PORT_REG_DATA   equ 0x3DE       ; Register data port
PORT_MODE       equ 0x3D8       ; Mode control register
PORT_COLOR      equ 0x3D9       ; Color select (border/overscan color)
PORT_STATUS     equ 0x3DA       ; Status (bit 0=hsync, bit 3=vblank)

; Screen parameters
SCREEN_HEIGHT   equ 200         ; Visible scanlines
SCREEN_SIZE     equ 16384       ; Full video RAM (16KB)

; Raster bar parameters
BAR_SPACING     equ 48          ; Pattern cycle length (scanlines)
BAR_SPEED       equ 1           ; Scroll speed per frame

; ============================================================================
; Main Program
; ============================================================================
main:
    call enable_graphics_mode
    call set_palette
    call clear_screen
    
    mov byte [bar_y_pos], 0

.main_loop:
    call wait_vblank
    
    ; Update scroll position
    mov al, [bar_y_pos]
    add al, BAR_SPEED
    cmp al, BAR_SPACING
    jb .no_wrap
    xor al, al
.no_wrap:
    mov [bar_y_pos], al
    
    call render_raster_bars
    
    ; Check for keypress
    mov ah, 0x01
    int 0x16
    jz .main_loop
    
    ; Exit
    mov ah, 0x00
    int 0x16                    ; Consume key
    
    mov ax, 0x0003              ; Restore text mode
    int 0x10
    mov ax, 0x4C00
    int 0x21

; ============================================================================
; render_raster_bars - Per-scanline color changes via PORT_COLOR
; Uses static pattern table indexed by scroll position
; ============================================================================
render_raster_bars:
    push ax
    push bx
    push dx
    push si
    
    cli
    
    ; SI = starting offset into pattern
    mov al, [bar_y_pos]
    xor ah, ah
    mov si, ax
    
    xor bx, bx                  ; BX = scanline counter
    mov dx, PORT_STATUS
    
.scanline_loop:
    ; Wait for hsync low
.wait_low:
    in al, dx
    test al, 0x01
    jnz .wait_low
    
    ; Wait for hsync high
.wait_high:
    in al, dx
    test al, 0x01
    jz .wait_high
    
    ; Output color from pattern table
    mov al, [static_pattern + si]
    out PORT_COLOR, al
    
    ; Advance pattern index with wrap
    inc si
    cmp si, BAR_SPACING
    jb .no_wrap
    xor si, si
.no_wrap:
    
    inc bx
    cmp bx, SCREEN_HEIGHT
    jb .scanline_loop
    
    ; Reset to black after frame
    xor al, al
    out PORT_COLOR, al
    
    sti
    
    pop si
    pop dx
    pop bx
    pop ax
    ret

; ============================================================================
; wait_vblank - Wait for vertical blanking interval
; ============================================================================
wait_vblank:
    push ax
    push dx
    
    mov dx, PORT_STATUS
    
.wait_end:
    in al, dx
    test al, 0x08
    jnz .wait_end
    
.wait_start:
    in al, dx
    test al, 0x08
    jz .wait_start
    
    pop dx
    pop ax
    ret

; ============================================================================
; enable_graphics_mode - Enable 160x200x16 hidden mode
; ============================================================================
enable_graphics_mode:
    push ax
    push dx
    
    mov dx, PORT_MODE
    mov al, 0x4A
    out dx, al
    
    pop dx
    pop ax
    ret

; ============================================================================
; clear_screen - Fill video RAM with color 0
; ============================================================================
clear_screen:
    push ax
    push cx
    push di
    push es
    
    mov ax, VIDEO_SEG
    mov es, ax
    xor di, di
    mov cx, SCREEN_SIZE / 2
    xor ax, ax
    cld
    rep stosw
    
    pop es
    pop di
    pop cx
    pop ax
    ret

; ============================================================================
; set_palette - Load warm gradient palette into V6355D
; ============================================================================
set_palette:
    push ax
    push cx
    push dx
    push si
    
    cli
    
    mov dx, PORT_REG_ADDR
    mov al, 0x40
    out dx, al
    
    mov dx, PORT_REG_DATA
    mov si, palette_data
    mov cx, 32                  ; 16 colors * 2 bytes
    
.pal_loop:
    lodsb
    out dx, al
    loop .pal_loop
    
    sti
    
    pop si
    pop dx
    pop cx
    pop ax
    ret

; ============================================================================
; Data Section
; ============================================================================

bar_y_pos:  db 0                ; Current scroll position

; Static pattern table - one complete bar cycle (48 entries)
; Colors 1-7 form the gradient, 0 is black background
static_pattern:
    db 1, 1, 1, 2, 2, 2, 3, 3, 3, 4, 4, 4    ; Bright to mid
    db 5, 5, 5, 6, 6, 6, 7, 7, 7, 0, 0, 0    ; Mid to black
    db 0, 0, 0, 7, 7, 7, 6, 6, 6, 5, 5, 5    ; Black to mid
    db 4, 4, 4, 3, 3, 3, 2, 2, 2, 1, 1, 1    ; Mid to bright

; Warm gradient palette (16 colors, 2 bytes each: Red, Green<<4|Blue)
palette_data:
    db 0x00, 0x00               ;  0: Black (background)
    db 0x07, 0x77               ;  1: White (brightest)
    db 0x07, 0x72               ;  2: Light yellow
    db 0x07, 0x62               ;  3: Yellow
    db 0x06, 0x42               ;  4: Orange
    db 0x05, 0x31               ;  5: Dark orange
    db 0x04, 0x20               ;  6: Red-orange
    db 0x03, 0x10               ;  7: Dark red (darkest)
    db 0x00, 0x00               ;  8: (unused)
    db 0x00, 0x00               ;  9: (unused)
    db 0x00, 0x00               ; 10: (unused)
    db 0x00, 0x00               ; 11: (unused)
    db 0x00, 0x00               ; 12: (unused)
    db 0x00, 0x00               ; 13: (unused)
    db 0x00, 0x00               ; 14: (unused)
    db 0x00, 0x00               ; 15: (unused)

; ============================================================================
; End of Program
; ============================================================================
