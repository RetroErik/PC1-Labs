; ============================================================================
; KEFRENS4.asm - Kefrens Bars with 3-wave morphing
; Minimum delta from proven working KEFRENS.asm (v1)
;
; ONLY changes from v1:
;   - draw_column x calc: 3 summed sine waves instead of 1
;   - main_loop: animate 3 phases instead of 1
;   - Data: 2 extra phase bytes
;   - Everything else is BYTE-FOR-BYTE identical to v1
;
; Build: nasm KEFRENS4.asm -f bin -o KEFRENS4.com
; ============================================================================

[BITS 16]
[ORG 0x100]

; ============================================================================
; Constants (IDENTICAL to v1)
; ============================================================================
VIDEO_SEG       equ 0xB000
PORT_REG_ADDR   equ 0xDD
PORT_REG_DATA   equ 0xDE
PORT_MODE       equ 0xD8
PORT_COLOR      equ 0xD9
PORT_STATUS     equ 0x3DA
SCREEN_WIDTH    equ 160
SCREEN_HEIGHT   equ 200
BYTES_PER_ROW   equ 80
BAR_PERIOD      equ 50
BAR_HALF        equ 15

; ============================================================================
; Entry Point (IDENTICAL to v1)
; ============================================================================
start:
    call    enable_gfx
    call    set_palette
    call    cls

    xor     ax, ax
    mov     [phase], al
    mov     [phase2], al        ; NEW
    mov     [phase3], al        ; NEW
    mov     [bar_scroll], al
    mov     [frame_cnt], al

; ============================================================================
; Main Loop
; ============================================================================
main_loop:
    ; --- Wait for VBLANK (IDENTICAL to v1) ---
    mov     dx, PORT_STATUS
.vb_end:
    in      al, dx
    test    al, 0x08
    jnz     .vb_end
.vb_start:
    in      al, dx
    test    al, 0x08
    jz      .vb_start

    ; --- Draw kefrens column ---
    call    draw_column

    ; --- Animate (v1 + 2 extra phases) ---
    inc     byte [phase]

    ; NEW: advance phase2 by 2 per frame
    mov     al, [phase2]
    add     al, 2
    mov     [phase2], al

    ; NEW: advance phase3 by 3 per frame
    mov     al, [phase3]
    add     al, 3
    mov     [phase3], al

    ; --- Scroll bars (IDENTICAL to v1) ---
    inc     byte [frame_cnt]
    cmp     byte [frame_cnt], 2
    jb      .no_scroll
    mov     byte [frame_cnt], 0
    inc     byte [bar_scroll]
    cmp     byte [bar_scroll], BAR_PERIOD
    jb      .no_scroll
    mov     byte [bar_scroll], 0
.no_scroll:

    ; --- Check ESC (IDENTICAL to v1) ---
    in      al, 0x60
    cmp     al, 1
    je      .exit
    jmp     main_loop

.exit:
    mov     ax, 0x0003
    int     0x10
    mov     ax, 0x4C00
    int     0x21

; ============================================================================
; draw_column - CHANGED: 3-wave x position, everything else identical to v1
;
; Uses v1's sine table (range 25-135) with scaling:
;   x = sine[idx1]/2 + sine[idx2]/4 + sine[idx3]/4
;   Range: 12+6+6=24 to 67+33+33=133 (safe within 0-159)
;
; Register allocation: SAME as v1 (BL=x, DL=color, SI=index, etc.)
; ============================================================================
draw_column:
    push    ax
    push    bx
    push    cx
    push    dx
    push    si
    push    di
    push    es
    push    bp

    mov     ax, VIDEO_SEG
    mov     es, ax

    xor     cx, cx              ; CX = y (0-199)

.scanline:
    ; ===== NEW: 3-wave x position (replaces v1's single-wave calc) =====

    ; Wave 1 (dominant): sine_table[(y*2 + phase) & 0xFF] / 2
    mov     al, cl
    shl     al, 1               ; y*2
    add     al, [phase]
    xor     ah, ah
    mov     si, ax
    mov     al, [sine_table + si]
    shr     al, 1               ; /2 → 12-67
    mov     bl, al              ; BL = wave1

    ; Wave 2 (medium): sine_table[(y*5 + phase2) & 0xFF] / 4
    ; y*5 = y + y*4
    mov     al, cl              ; y
    shl     al, 1               ; y*2
    shl     al, 1               ; y*4
    add     al, cl              ; y*5 (byte wraps, fine for sine index)
    add     al, [phase2]
    xor     ah, ah
    mov     si, ax
    mov     al, [sine_table + si]
    shr     al, 1
    shr     al, 1               ; /4 → 6-33
    add     bl, al              ; BL += wave2

    ; Wave 3 (fine): sine_table[(y*13 + phase3) & 0xFF] / 4
    ; y*13 = y + y*4 + y*8
    mov     al, cl              ; y
    shl     al, 1               ; y*2
    shl     al, 1               ; y*4
    mov     ah, al              ; AH = y*4
    shl     al, 1               ; y*8
    add     al, ah              ; y*12
    add     al, cl              ; y*13 (byte wraps, fine for sine index)
    add     al, [phase3]
    xor     ah, ah
    mov     si, ax
    mov     al, [sine_table + si]
    shr     al, 1
    shr     al, 1               ; /4 → 6-33
    add     bl, al              ; BL = total x (24-133)

    ; ===== END OF NEW CODE. Below is IDENTICAL to v1. =====

    ; ----- Bar color (IDENTICAL to v1) -----
    mov     al, cl
    add     al, [bar_scroll]
    xor     ah, ah

.mod_loop:
    cmp     ax, BAR_PERIOD
    jb      .mod_done
    sub     ax, BAR_PERIOD
    jmp     .mod_loop
.mod_done:

    cmp     ax, BAR_HALF
    jae     .not_ascending
    inc     al
    jmp     .have_color

.not_ascending:
    cmp     ax, BAR_HALF * 2
    jae     .is_black
    neg     ax
    add     ax, BAR_HALF * 2
    jmp     .have_color

.is_black:
    xor     al, al

.have_color:
    mov     dl, al              ; DL = color

    ; ----- VRAM offset (IDENTICAL to v1) -----
    mov     ax, cx
    shr     ax, 1
    mov     bp, BYTES_PER_ROW
    push    dx
    mul     bp
    pop     dx
    mov     di, ax
    test    cl, 1
    jz      .even_row
    add     di, 0x2000
.even_row:
    mov     al, bl
    xor     ah, ah
    shr     ax, 1
    add     di, ax

    ; ----- Read-modify-write nibble (IDENTICAL to v1) -----
    mov     al, [es:di]
    test    bl, 1
    jnz     .odd_pixel

    and     al, 0x0F
    mov     ah, dl
    shl     ah, 4
    or      al, ah
    jmp     .write_pixel

.odd_pixel:
    and     al, 0xF0
    or      al, dl

.write_pixel:
    mov     [es:di], al

    inc     cx
    cmp     cx, SCREEN_HEIGHT
    jb      .scanline

    pop     bp
    pop     es
    pop     di
    pop     si
    pop     dx
    pop     cx
    pop     bx
    pop     ax
    ret

; ============================================================================
; enable_gfx (IDENTICAL to v1)
; ============================================================================
enable_gfx:
    push    ax
    push    dx

    mov     ax, 0x0004
    int     0x10

    mov     al, 0x67
    out     PORT_REG_ADDR, al
    jmp     short $+2
    mov     al, 0x18
    out     PORT_REG_DATA, al
    jmp     short $+2

    mov     al, 0x65
    out     PORT_REG_ADDR, al
    jmp     short $+2
    mov     al, 0x09
    out     PORT_REG_DATA, al
    jmp     short $+2

    mov     al, 0x4A
    out     PORT_MODE, al
    jmp     short $+2

    xor     al, al
    out     PORT_COLOR, al

    pop     dx
    pop     ax
    ret

; ============================================================================
; set_palette (IDENTICAL to v1)
; ============================================================================
set_palette:
    push    ax
    push    cx
    push    si

    cli

    mov     al, 0x40
    out     PORT_REG_ADDR, al
    jmp     short $+2
    jmp     short $+2

    mov     si, palette_data
    mov     cx, 32
.pal_loop:
    lodsb
    out     PORT_REG_DATA, al
    jmp     short $+2
    loop    .pal_loop

    jmp     short $+2
    mov     al, 0x80
    out     PORT_REG_ADDR, al
    jmp     short $+2

    sti

    pop     si
    pop     cx
    pop     ax
    ret

; ============================================================================
; cls (IDENTICAL to v1)
; ============================================================================
cls:
    push    ax
    push    cx
    push    di
    push    es

    mov     ax, VIDEO_SEG
    mov     es, ax
    xor     di, di
    mov     cx, 8192
    xor     ax, ax
    cld
    rep     stosw

    pop     es
    pop     di
    pop     cx
    pop     ax
    ret

; ============================================================================
; Data (v1 + 2 extra phase bytes)
; ============================================================================
phase       db 0
phase2      db 0                ; NEW
phase3      db 0                ; NEW
bar_scroll  db 0
frame_cnt   db 0

; Palette (IDENTICAL to v1)
palette_data:
    db      0,    0x00
    db      1,    0x00
    db      2,    0x00
    db      3,    0x00
    db      4,    0x10
    db      5,    0x10
    db      5,    0x20
    db      6,    0x20
    db      6,    0x30
    db      7,    0x30
    db      7,    0x41
    db      7,    0x51
    db      7,    0x52
    db      7,    0x63
    db      7,    0x74
    db      7,    0x76

; Sine table (IDENTICAL to v1)
sine_table:
    db 80, 81, 83, 84, 85, 87, 88, 89, 91, 92, 93, 95, 96, 97, 99, 100
    db 101, 102, 104, 105, 106, 107, 108, 109, 111, 112, 113, 114, 115, 116, 117, 118
    db 119, 120, 121, 122, 123, 123, 124, 125, 126, 126, 127, 128, 129, 129, 130, 130
    db 131, 131, 132, 132, 133, 133, 133, 134, 134, 134, 134, 135, 135, 135, 135, 135
    db 135, 135, 135, 135, 135, 135, 134, 134, 134, 134, 133, 133, 133, 132, 132, 131
    db 131, 130, 130, 129, 129, 128, 127, 126, 126, 125, 124, 123, 123, 122, 121, 120
    db 119, 118, 117, 116, 115, 114, 113, 112, 111, 109, 108, 107, 106, 105, 104, 102
    db 101, 100, 99, 97, 96, 95, 93, 92, 91, 89, 88, 87, 85, 84, 83, 81
    db 80, 79, 77, 76, 75, 73, 72, 71, 69, 68, 67, 65, 64, 63, 61, 60
    db 59, 58, 56, 55, 54, 53, 52, 51, 49, 48, 47, 46, 45, 44, 43, 42
    db 41, 40, 39, 38, 37, 37, 36, 35, 34, 34, 33, 32, 31, 31, 30, 30
    db 29, 29, 28, 28, 27, 27, 27, 26, 26, 26, 26, 25, 25, 25, 25, 25
    db 25, 25, 25, 25, 25, 25, 26, 26, 26, 26, 27, 27, 27, 28, 28, 29
    db 29, 30, 30, 31, 31, 32, 33, 34, 34, 35, 36, 37, 37, 38, 39, 40
    db 41, 42, 43, 44, 45, 46, 47, 48, 49, 51, 52, 53, 54, 55, 56, 58
    db 59, 60, 61, 63, 64, 65, 67, 68, 69, 71, 72, 73, 75, 76, 77, 79
