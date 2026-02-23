; ============================================================================
; KEFRENS3B.asm - Diagnostic: 3-wave morphing kefrens, NO RASTERS
; If this works: the raster code is the crash cause
; If this crashes: the 3-wave code is the crash cause
;
; Build: nasm KEFRENS3B.asm -f bin -o KEFRENS3B.com
; ============================================================================

[BITS 16]
[ORG 0x100]

VIDEO_SEG       equ 0xB000
PORT_REG_ADDR   equ 0xDD
PORT_REG_DATA   equ 0xDE
PORT_MODE       equ 0xD8
PORT_COLOR      equ 0xD9
PORT_STATUS     equ 0x3DA

SCREEN_HEIGHT   equ 200
BYTES_PER_ROW   equ 80
BAR_PERIOD      equ 40
BAR_HALF        equ 12

WAVE1_STEP      equ 3
WAVE2_STEP      equ 7
WAVE3_STEP      equ 13
WAVE1_SPEED     equ 1
WAVE2_SPEED     equ 2
WAVE3_SPEED     equ 3

; ============================================================================
start:
    ; --- Identical init to working KEFRENS v1 ---
    mov     ax, 0x0004
    int     0x10

    push    cs
    pop     ds
    push    cs
    pop     es
    cld

    ; V6355D registers
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

    ; --- Set palette (identical to working v1 pattern) ---
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

    ; Close palette with 0x80 (same as working v1)
    jmp     short $+2
    mov     al, 0x80
    out     PORT_REG_ADDR, al
    jmp     short $+2
    sti

    ; --- Clear VRAM ---
    mov     ax, VIDEO_SEG
    mov     es, ax
    xor     di, di
    xor     ax, ax
    mov     cx, 8192
    cld
    rep     stosw

    push    cs
    pop     es

    ; Init animation
    xor     ax, ax
    mov     [wave1_phase], al
    mov     [wave2_phase], al
    mov     [wave3_phase], al
    mov     [bar_scroll], al

; ============================================================================
; Main Loop - Just morphing kefrens, no rasters
; ============================================================================
main_loop:
    ; Wait for VBLANK
    mov     dx, PORT_STATUS
.vb_end:
    in      al, dx
    test    al, 0x08
    jnz     .vb_end
.vb_start:
    in      al, dx
    test    al, 0x08
    jz      .vb_start

    ; Draw one kefrens column
    call    draw_column

    ; Animate
    mov     al, [wave1_phase]
    add     al, WAVE1_SPEED
    mov     [wave1_phase], al

    mov     al, [wave2_phase]
    add     al, WAVE2_SPEED
    mov     [wave2_phase], al

    mov     al, [wave3_phase]
    add     al, WAVE3_SPEED
    mov     [wave3_phase], al

    inc     byte [bar_scroll]
    cmp     byte [bar_scroll], BAR_PERIOD
    jb      .no_wrap
    mov     byte [bar_scroll], 0
.no_wrap:

    ; Check ESC
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
; draw_column - 3 summed sine waves, same logic as KEFRENS3
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

    ; Init accumulators
    mov     al, [wave1_phase]
    mov     [w1_acc], al
    mov     al, [wave2_phase]
    mov     [w2_acc], al
    mov     al, [wave3_phase]
    mov     [w3_acc], al

    xor     cx, cx

.scanline:
    ; --- Sum 3 sine waves ---
    xor     bh, bh
    mov     bl, [w1_acc]
    mov     al, [sine_table + bx]
    shr     al, 1               ; /2
    mov     dl, al

    mov     bl, [w2_acc]
    mov     al, [sine_table + bx]
    shr     al, 1
    shr     al, 1               ; /4
    add     dl, al

    mov     bl, [w3_acc]
    mov     al, [sine_table + bx]
    shr     al, 1
    shr     al, 1               ; /4
    add     dl, al

    add     dl, 20              ; Center on screen

    ; Advance accumulators
    add     byte [w1_acc], WAVE1_STEP
    add     byte [w2_acc], WAVE2_STEP
    add     byte [w3_acc], WAVE3_STEP

    ; --- Bar color (identical to working v1 pattern) ---
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
    jae     .not_asc
    inc     al
    jmp     .got_color
.not_asc:
    cmp     ax, BAR_HALF * 2
    jae     .is_gap
    neg     ax
    add     ax, BAR_HALF * 2
    jmp     .got_color
.is_gap:
    xor     al, al
.got_color:
    mov     dh, al              ; DH = color, DL = x

    ; --- VRAM offset (identical to working v1) ---
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
    mov     al, dl
    xor     ah, ah
    shr     ax, 1
    add     di, ax

    ; --- Read-modify-write nibble ---
    mov     al, [es:di]
    test    dl, 1
    jnz     .odd_px

    and     al, 0x0F
    mov     ah, dh
    shl     ah, 4
    or      al, ah
    jmp     short .write_px

.odd_px:
    and     al, 0xF0
    or      al, dh

.write_px:
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
; Data
; ============================================================================
wave1_phase     db 0
wave2_phase     db 0
wave3_phase     db 0
bar_scroll      db 0
w1_acc          db 0
w2_acc          db 0
w3_acc          db 0

; Copper Gradient Palette (same as working v1)
palette_data:
    db 0, 0x00      ;  0: Black
    db 1, 0x00      ;  1: Very dark red
    db 2, 0x00      ;  2: Dark red
    db 3, 0x00      ;  3: Medium red
    db 4, 0x10      ;  4: Red with green hint
    db 5, 0x10      ;  5: Bright red-orange
    db 5, 0x20      ;  6: Orange
    db 6, 0x20      ;  7: Bright orange
    db 6, 0x30      ;  8: Amber
    db 7, 0x30      ;  9: Bright amber
    db 7, 0x41      ; 10: Gold
    db 7, 0x51      ; 11: Bright gold
    db 7, 0x52      ; 12: Yellow-gold
    db 7, 0x63      ; 13: Yellow
    db 7, 0x74      ; 14: Bright yellow
    db 7, 0x76      ; 15: Near-white

; Sine Table (256 entries, values 0-120)
sine_table:
    db 60, 61, 63, 64, 66, 67, 69, 70, 72, 73, 75, 76, 77, 79, 80, 81
    db 83, 84, 85, 86, 88, 89, 90, 91, 92, 93, 94, 95, 96, 97, 98, 99
    db 100, 100, 101, 102, 103, 103, 104, 104, 105, 105, 106, 106, 107, 107, 107, 108
    db 108, 108, 109, 109, 109, 109, 109, 110, 110, 110, 110, 110, 110, 110, 110, 110
    db 110, 110, 110, 110, 110, 110, 110, 110, 110, 109, 109, 109, 109, 109, 108, 108
    db 108, 107, 107, 107, 106, 106, 105, 105, 104, 104, 103, 103, 102, 101, 100, 100
    db 99, 98, 97, 96, 95, 94, 93, 92, 91, 90, 89, 88, 86, 85, 84, 83
    db 81, 80, 79, 77, 76, 75, 73, 72, 70, 69, 67, 66, 64, 63, 61, 60
    db 60, 59, 57, 56, 54, 53, 51, 50, 48, 47, 45, 44, 43, 41, 40, 39
    db 37, 36, 35, 34, 32, 31, 30, 29, 28, 27, 26, 25, 24, 23, 22, 21
    db 20, 20, 19, 18, 17, 17, 16, 16, 15, 15, 14, 14, 13, 13, 13, 12
    db 12, 12, 11, 11, 11, 11, 11, 10, 10, 10, 10, 10, 10, 10, 10, 10
    db 10, 10, 10, 10, 10, 10, 10, 10, 10, 11, 11, 11, 11, 11, 12, 12
    db 12, 13, 13, 13, 14, 14, 15, 15, 16, 16, 17, 17, 18, 19, 20, 20
    db 21, 22, 23, 24, 25, 26, 27, 28, 29, 30, 31, 32, 34, 35, 36, 37
    db 39, 40, 41, 43, 44, 45, 47, 48, 50, 51, 53, 54, 56, 57, 59, 60
