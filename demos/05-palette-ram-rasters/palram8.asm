; ============================================================================
; PALRAM8.ASM - Palette RAM Raster Bars in CGA Mode 4 (320x200x4)
; Confirms V6355D palette RAM works in standard CGA mode
; Written for NASM - NEC V40 (80186 compatible) @ 8 MHz
; By Retro Erik - 2026 with help from GitHub Copilot
;
; Target: Olivetti PC1 with Yamaha V6355D video controller
; Video Mode: CGA Mode 4 (320x200, 4 colors) - STANDARD CGA MODE
;
; PURPOSE:
;   Demonstrates that V6355D palette RAM (0x3DD/0x3DE) works in standard
;   CGA mode 4, not just the hidden 160x200x16 mode.
;   Displays a 200-color animated warm gradient (same pattern as palram1).
;
; KEY FINDING (verified on real PC1 hardware, March 2026):
;   V6355D palette RAM is MODE-INDEPENDENT. The palette registers at
;   0x3DD/0x3DE respond identically regardless of which video mode the
;   chip is in. This means all palette RAM techniques (per-scanline
;   raster bars, RGB333 gradients, skip-if-same) work in CGA mode 4
;   (320x200) just as well as in the hidden 160x200x16 mode.
;
; BASED ON: palram1.asm (simplest palette RAM demo)
;
; CHANGES FROM PALRAM1:
;   - Video mode: int 0x10 AX=0x0004 (CGA mode 4) instead of out 0x3D8, 0x4A
;   - Video segment: 0xB800 (standard CGA) instead of 0xB000 (PC1 hidden)
;   - Mode restore: int 0x10 AX=0x0003 (same as palram1)
;   - Palette RAM writes: IDENTICAL to palram1
;
; OPTIMIZATIONS (from palram7/demo1b):
;   - Short port addresses: 0xDA/0xDD/0xDE instead of 0x3DA/0x3DD/0x3DE
;   - Immediate port I/O for status: in al, 0xDA (frees DX for OUTSB)
;   - OUTSB burst writes: 3-byte pal_cmd buffer streamed via OUTSB
;   - Skip-if-same: no port writes when color unchanged between scanlines
;   - Pre-load pal_cmd before HSYNC wait (setup in free time)
;   - Critical HBLANK path: ~60 clocks vs ~90+ unoptimized
;
; COMPATIBILITY:
;   On PC1 (V6355D): warm gradient bars (confirmed working)
;   On real CGA (MC6845): black screen (palette RAM ports don't exist)
;
; Controls:
;   SPACE - Toggle animation on/off
;   ESC   - Exit to DOS
; ============================================================================

[BITS 16]
[CPU 186]                       ; NEC V40 is 80186 compatible (enables OUTSB)
[ORG 0x100]

; ============================================================================
; Constants
; ============================================================================

; Short port aliases (saves ~4 cycles per OUT vs 0x3D* addresses)
PORT_STATUS     equ 0xDA        ; Status Register (short alias for 0x3DA)
                                ; Bit 0: HSYNC (1 = in horizontal retrace)
                                ; Bit 3: VBLANK (1 = in vertical retrace)
PORT_REG_ADDR   equ 0xDD        ; Palette register address (short alias for 0x3DD)
PORT_REG_DATA   equ 0xDE        ; Palette register data (short alias for 0x3DE)

; Video Memory
VIDEO_SEG       equ 0xB800      ; Standard CGA video RAM segment

; Screen parameters
SCREEN_HEIGHT   equ 200         ; Visible scanlines
GRADIENT_SIZE   equ 50          ; Pattern repeats every 50 scanlines (4 bars)

; Animation
ANIM_SPEED      equ 1           ; Color offset change per frame

; ============================================================================
; Main Program
; ============================================================================
main:
    ; Build the 200-entry RGB gradient table
    call build_gradient_table

    ; Set CGA mode 4 (320x200, 4 colors) via BIOS
    mov ax, 0x0004
    int 0x10

    ; Clear screen to color 0 (this is what palette RAM will recolor)
    call clear_screen

    ; Initialize animation offset
    mov word [color_offset], 0
    mov byte [anim_enabled], 1

.main_loop:
    ; Wait for VBLANK to start
    call wait_vblank

    ; Update animation offset during VBLANK (safe time)
    cmp byte [anim_enabled], 0
    je .skip_anim
    mov ax, [color_offset]
    add ax, ANIM_SPEED
    cmp ax, GRADIENT_SIZE
    jb .no_wrap
    xor ax, ax
.no_wrap:
    mov [color_offset], ax
.skip_anim:

    ; Render all 200 scanlines with palette changes
    call render_scanlines

    ; Check keyboard during VBLANK/border time
    call check_keyboard
    cmp al, 1               ; Exit flag?
    jne .main_loop

    ; Cleanup: Reset palette entry 0 to black
    mov al, 0x40
    out PORT_REG_ADDR, al
    xor al, al
    out PORT_REG_DATA, al   ; R = 0
    out PORT_REG_DATA, al   ; G|B = 0
    mov al, 0x80
    out PORT_REG_ADDR, al   ; Close palette write window

    ; Restore text mode and exit
    mov ax, 0x0003
    int 0x10
    mov ax, 0x4C00
    int 0x21

; ============================================================================
; build_gradient_table - Pre-compute gradient (same as palram1)
; ============================================================================
build_gradient_table:
    push cx
    push di
    push si

    mov di, gradient_table
    mov si, warm_gradient
    mov cx, GRADIENT_SIZE

.copy_loop:
    lodsb
    stosb
    lodsb
    stosb
    loop .copy_loop

    pop si
    pop di
    pop cx
    ret

; ============================================================================
; render_scanlines - Output palette changes for all 200 visible scanlines
;
; Optimized register plan (from palram7/demo1b):
;   DX = PORT_REG_ADDR (0xDD) permanently, used by OUTSB and close-write
;   SI = gradient_table pointer (swapped to pal_cmd only for OUTSB burst)
;   BH/BL = previously written R/GB bytes (skip write if unchanged)
;   CX = line counter
;   Status polling via immediate port: in al, PORT_STATUS (0xDA)
;
; Critical HBLANK path (write case): ~60 clocks
;   outsb(14) + inc dx(3) + outsb(14) + outsb(14) +
;   dec dx(3) + mov al,0x80(4) + out dx,al(8)
; Skip case: 0 port writes (no palette glitch possible)
; ============================================================================
render_scanlines:
    push ax
    push bx
    push cx
    push dx
    push si

    cli                     ; Disable interrupts for timing

    ; SI = starting position in gradient table (2 bytes per entry)
    mov ax, [color_offset]
    shl ax, 1               ; *2 for byte offset
    add ax, gradient_table
    mov si, ax

    mov cx, SCREEN_HEIGHT   ; 200 scanlines
    mov dx, PORT_REG_ADDR   ; DX stays 0xDD for OUTSB + close

    ; Init BH:BL to impossible value so first scanline always writes
    mov bx, 0xFFFF

.scanline_loop:
    ; --- Pre-fetch color during active display (timing uncritical) ---
    mov ah, [si]            ; AH = new R
    mov al, [si + 1]        ; AL = new G|B
    add si, 2

    ; --- Wrap SI at end of gradient table ---
    lea bp, [gradient_table + GRADIENT_SIZE * 2]
    cmp si, bp
    jb .no_table_wrap
    mov si, gradient_table
.no_table_wrap:

    ; --- Compare new (AH,AL) vs current (BH,BL) - skip if unchanged ---
    cmp ax, bx
    je .skip_write

    ; Color changed - update tracking and prepare OUTSB buffer
    mov bx, ax              ; BH:BL = new R:GB
    mov [pal_cmd + 1], bh   ; R byte
    mov [pal_cmd + 2], bl   ; G|B byte

    ; Park SI, load pal_cmd for OUTSB (before HSYNC wait - free time)
    mov [saved_si], si
    mov si, pal_cmd

    ; Wait for HSYNC to go LOW (visible line being drawn)
.wait_low:
    in al, PORT_STATUS      ; Immediate port I/O (0xDA), DX stays free
    test al, 0x01
    jnz .wait_low

    ; Wait for HSYNC to go HIGH (HBLANK begins - safe to write palette!)
.wait_high:
    in al, PORT_STATUS
    test al, 0x01
    jz .wait_high

    ; --- Critical HBLANK path: OUTSB burst (~60 clocks) ---
    outsb                   ; 14 - OUT 0xDD, 0x40 (open palette, entry 0)
    inc dx                  ; 3  - DX = 0xDE (PORT_REG_DATA)
    outsb                   ; 14 - OUT 0xDE, R byte
    outsb                   ; 14 - OUT 0xDE, G|B byte
    dec dx                  ; 3  - DX = 0xDD (PORT_REG_ADDR)
    mov al, 0x80            ; 4
    out dx, al              ; 8  - close palette write window

    ; Restore scanline pointer
    mov si, [saved_si]
    jmp .next_line

.skip_write:
    ; Same color as previous scanline - no port writes needed
.wait_low2:
    in al, PORT_STATUS
    test al, 0x01
    jnz .wait_low2
.wait_high2:
    in al, PORT_STATUS
    test al, 0x01
    jz .wait_high2

.next_line:
    loop .scanline_loop

    ; Reset palette entry 0 to black after visible area
    mov al, 0x40
    out dx, al              ; DX is still PORT_REG_ADDR
    xor al, al
    out PORT_REG_DATA, al
    out PORT_REG_DATA, al
    mov al, 0x80
    out dx, al              ; Close palette write window

    sti                     ; Re-enable interrupts

    pop si
    pop dx
    pop cx
    pop bx
    pop ax
    ret

; ============================================================================
; wait_vblank - Wait for vertical blanking interval
; ============================================================================
wait_vblank:
    push ax

    ; Wait for VBLANK to end (if we're in it)
.wait_end:
    in al, PORT_STATUS      ; Immediate port I/O (0xDA)
    test al, 0x08
    jnz .wait_end

    ; Wait for VBLANK to start
.wait_start:
    in al, PORT_STATUS
    test al, 0x08
    jz .wait_start

    pop ax
    ret

; ============================================================================
; check_keyboard - Check for keypresses
; Returns: AL = 1 if exit requested, 0 otherwise
; ============================================================================
check_keyboard:
    push bx

    xor al, al              ; Default: no exit

    mov ah, 0x01
    int 0x16
    jz .no_key

    mov ah, 0x00
    int 0x16

    cmp ah, 0x01            ; ESC
    jne .check_space
    mov al, 1
    jmp .done

.check_space:
    cmp ah, 0x39            ; Space bar
    jne .no_key
    xor byte [anim_enabled], 1

.no_key:
    xor al, al

.done:
    pop bx
    ret

; ============================================================================
; clear_screen - Fill CGA video memory with color 0
;
; CGA mode 4 memory layout:
;   0xB800:0000 - Even scanlines (0, 2, 4, ...)
;   0xB800:2000 - Odd scanlines (1, 3, 5, ...)
;   Total: 16384 bytes
; ============================================================================
clear_screen:
    push ax
    push cx
    push di
    push es

    mov ax, VIDEO_SEG
    mov es, ax
    xor di, di
    mov cx, 8192            ; 16384 / 2
    xor ax, ax              ; Color 0 in all pixels
    cld
    rep stosw

    pop es
    pop di
    pop cx
    pop ax
    ret

; ============================================================================
; Data Section
; ============================================================================

color_offset:   dw 0
anim_enabled:   db 1

; ============================================================================
; Warm gradient pattern - 50 entries (2 bytes each: Red, Green<<4|Blue)
; Same as palram1 - creates warm orange/red bars
; ============================================================================
warm_gradient:
    ; Lines 0-12: Black to Orange (fade in)
    db 0x00, 0x00           ; Black
    db 0x01, 0x00           ; Very dark red
    db 0x02, 0x00           ; Dark red
    db 0x03, 0x00           ; Red
    db 0x04, 0x10           ; Red-orange
    db 0x05, 0x20           ; Orange
    db 0x06, 0x30           ; Bright orange
    db 0x07, 0x40           ; Yellow-orange
    db 0x07, 0x50           ; Light yellow-orange
    db 0x07, 0x60           ; Yellow
    db 0x07, 0x70           ; Bright yellow
    db 0x07, 0x71           ; Yellow-white
    db 0x07, 0x72           ; Near white

    ; Lines 13-24: White to Orange (fade down)
    db 0x07, 0x72           ; Near white
    db 0x07, 0x71           ; Yellow-white
    db 0x07, 0x70           ; Bright yellow
    db 0x07, 0x60           ; Yellow
    db 0x07, 0x50           ; Light yellow-orange
    db 0x07, 0x40           ; Yellow-orange
    db 0x06, 0x30           ; Bright orange
    db 0x05, 0x20           ; Orange
    db 0x04, 0x10           ; Red-orange
    db 0x03, 0x00           ; Red
    db 0x02, 0x00           ; Dark red
    db 0x01, 0x00           ; Very dark red

    ; Lines 25-49: Black gap
    db 0x00, 0x00
    db 0x00, 0x00
    db 0x00, 0x00
    db 0x00, 0x00
    db 0x00, 0x00
    db 0x00, 0x00
    db 0x00, 0x00
    db 0x00, 0x00
    db 0x00, 0x00
    db 0x00, 0x00
    db 0x00, 0x00
    db 0x00, 0x00
    db 0x00, 0x00
    db 0x00, 0x00
    db 0x00, 0x00
    db 0x00, 0x00
    db 0x00, 0x00
    db 0x00, 0x00
    db 0x00, 0x00
    db 0x00, 0x00
    db 0x00, 0x00
    db 0x00, 0x00
    db 0x00, 0x00
    db 0x00, 0x00
    db 0x00, 0x00

; ============================================================================
; OUTSB command buffer: 3 bytes streamed to port 0xDD then 0xDE
; ============================================================================
pal_cmd:
    db 0x40                 ; Byte 0: palette entry 0 select (OUT 0xDD, 0x40)
    db 0x00                 ; Byte 1: R value (filled at runtime)
    db 0x00                 ; Byte 2: G|B value (filled at runtime)

saved_si: dw 0              ; Saved SI during OUTSB burst

; ============================================================================
; BSS Section
; ============================================================================
gradient_table: resb GRADIENT_SIZE * 2
