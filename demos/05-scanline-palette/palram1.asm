; ============================================================================
; PALRAM1.ASM - Scanline Palette Demo (Basic) During HSYNC
; Static 200-color RGB gradient with optional animation
; Written for NASM - NEC V40 (80186 compatible) @ 8 MHz
; By Retro Erik - 2026
;
; Target: Olivetti PC1 with Yamaha V6355D video controller
; Video Mode: CGA 160x200x16 (Hidden mode)
;
; DISTINGUISHES THIS VERSION:
;   - Simplest implementation: single gradient pattern
;   - Clean, minimal code for educational clarity
;   - Animation toggle only (SPACE bar)
;   - ~417 lines of code
;
; ============================================================================
; TECHNIQUE: Palette RAM Manipulation
; ============================================================================
;
; All palette updates are synchronized to the HSYNC edge per scanline.
;
; Instead of PORT_COLOR (0xD9) which selects from 16 palette indices,
; this demo modifies the RGB values of palette entry 0 per-scanline.
; The screen is filled with color index 0, so changing its RGB values
; changes what that entire scanline looks like.
;
; PALETTE WRITE SEQUENCE (3 OUTs per scanline, timed to HSYNC edge):
;   1. OUT 0xDD, 0x40   ; Select palette entry 0
;   2. OUT 0xDE, R      ; Red intensity (bits 0-2, values 0-7)
;   3. OUT 0xDE, G|B    ; Green (bits 4-6) | Blue (bits 0-2)
;
; ADVANTAGES OVER PORT_COLOR:
;   - 512 RGB colors (8×8×8) vs 16 palette indices
;   - Affects all graphics using that palette entry, not just background
;   - Can modify any of 16 palette entries independently (0x40-0x4F)
;
; TIMING:
;   ~509 cycles per scanline @ 8MHz
;   3 OUTs (1 entry) = ~30 cycles (proven stable)
;   9 OUTs (3 entries) = ~90 cycles (tight but workable)
;   48 OUTs (all 16) = too slow, causes artifacts
;
; THIS IMPLEMENTATION:
;   - Pre-computes 200 RGB values (one per scanline) at startup
;   - Per-frame: reads from table, outputs to palette RAM
;   - Optional animation: rotates color offset during VBLANK
;   - Stable, predictable pattern for testing and debugging
;
; Controls:
;   SPACE - Toggle animation on/off
;   ESC   - Exit to DOS
; ============================================================================

[BITS 16]
[ORG 0x100]

; ============================================================================
; Constants
; ============================================================================

; Yamaha V6355D I/O Ports
PORT_MODE       equ 0xD8        ; Mode Control Register
PORT_STATUS     equ 0xDA        ; Status Register
                                ; Bit 0: HSYNC (1 = in horizontal retrace)
                                ; Bit 3: VBLANK (1 = in vertical retrace)
PORT_PAL_ADDR   equ 0xDD        ; Palette register address
PORT_PAL_DATA   equ 0xDE        ; Palette register data

; Video Memory
VIDEO_SEG       equ 0xB000      ; PC1 video RAM segment

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
    
    ; Enable 160x200x16 hidden graphics mode
    call enable_graphics_mode
    
    ; Clear screen to color 0 (this is what we'll be changing)
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
    out PORT_PAL_ADDR, al
    xor al, al
    out PORT_PAL_DATA, al   ; R = 0
    out PORT_PAL_DATA, al   ; G|B = 0
    
    ; Restore text mode and exit
    mov ax, 0x0003
    int 0x10
    mov ax, 0x4C00
    int 0x21

; ============================================================================
; build_gradient_table - Pre-compute 200 RGB values (one per scanline)
;
; Creates a repeating warm gradient pattern:
;   Lines 0-24:   Black → Dark Red → Orange (fade in)
;   Lines 25-49:  Orange → Yellow → White (brighten)
;   Lines 50-74:  White → Yellow → Orange (dim)
;   Lines 75-99:  Orange → Dark Red → Black (fade out)
;   Lines 100-199: Repeat pattern
;
; Each entry is 2 bytes: [Red, Green<<4 | Blue]
; ============================================================================
build_gradient_table:
    push ax
    push bx
    push cx
    push di
    push si
    
    mov di, gradient_table
    mov si, warm_gradient
    mov cx, GRADIENT_SIZE
    
.copy_loop:
    ; Copy Red byte
    lodsb
    stosb
    ; Copy Green|Blue byte  
    lodsb
    stosb
    loop .copy_loop
    
    pop si
    pop di
    pop cx
    pop bx
    pop ax
    ret

; ============================================================================
; render_scanlines - Output palette changes for all 200 visible scanlines
;
; For each scanline:
;   1. Wait for HSYNC low -> high edge
;   2. Write palette entry 0 with color from gradient table
;
; Uses [color_offset] to create animation effect
; ============================================================================
render_scanlines:
    push ax
    push bx
    push cx
    push dx
    push si
    
    cli                     ; Disable interrupts for timing
    
    ; SI = starting offset into gradient table (2 bytes per entry)
    mov ax, [color_offset]
    shl ax, 1               ; *2 for byte offset
    mov si, ax
    
    mov cx, SCREEN_HEIGHT   ; 200 scanlines
    mov dx, PORT_STATUS
    
.scanline_loop:
    ; --- Wait for HSYNC low then high (edge detection) ---
.wait_low:
    in al, dx
    test al, 0x01
    jnz .wait_low
    
.wait_high:
    in al, dx
    test al, 0x01
    jz .wait_high
    
    ; --- Output palette entry 0 with current color ---
    ; Critical timing: 1 entry = 3 OUTs, aligned to HSYNC edge
    mov al, 0x40            ; Select palette entry 0
    out PORT_PAL_ADDR, al
    
    mov al, [gradient_table + si]       ; Red
    out PORT_PAL_DATA, al
    
    mov al, [gradient_table + si + 1]   ; Green|Blue
    out PORT_PAL_DATA, al
    
    ; --- Advance to next color in table (wrap at pattern size) ---
    add si, 2
    cmp si, GRADIENT_SIZE * 2
    jb .no_table_wrap
    xor si, si
.no_table_wrap:
    
    loop .scanline_loop
    
    ; Reset palette entry 0 to black after visible area
    ; This prevents border flicker
    mov al, 0x40
    out PORT_PAL_ADDR, al
    xor al, al
    out PORT_PAL_DATA, al
    out PORT_PAL_DATA, al
    
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
    push dx
    
    mov dx, PORT_STATUS
    
    ; Wait for VBLANK to end (if we're in it)
.wait_end:
    in al, dx
    test al, 0x08
    jnz .wait_end
    
    ; Wait for VBLANK to start
.wait_start:
    in al, dx
    test al, 0x08
    jz .wait_start
    
    pop dx
    pop ax
    ret

; ============================================================================
; check_keyboard - Check for keypresses
; Returns: AL = 1 if exit requested, 0 otherwise
; ============================================================================
check_keyboard:
    push bx
    
    xor al, al              ; Default: no exit
    
    ; Check if key available
    mov ah, 0x01
    int 0x16
    jz .no_key
    
    ; Read the key
    mov ah, 0x00
    int 0x16
    
    ; Check for ESC
    cmp ah, 0x01
    jne .check_space
    mov al, 1               ; Exit flag
    jmp .done
    
.check_space:
    cmp ah, 0x39            ; Space bar scancode
    jne .no_key
    xor byte [anim_enabled], 1  ; Toggle animation
    
.no_key:
    xor al, al
    
.done:
    pop bx
    ret

; ============================================================================
; enable_graphics_mode - Enable 160x200x16 hidden mode
; ============================================================================
enable_graphics_mode:
    push ax
    push dx
    
    ; Set graphics mode
    mov al, 0x4A
    out PORT_MODE, al
    
    pop dx
    pop ax
    ret

; ============================================================================
; clear_screen - Fill video memory with color 0
; ============================================================================
clear_screen:
    push ax
    push cx
    push di
    push es
    
    mov ax, VIDEO_SEG
    mov es, ax
    xor di, di
    mov cx, 8192            ; 16KB / 2
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

color_offset:   dw 0        ; Current animation offset (0-GRADIENT_SIZE-1)
anim_enabled:   db 1        ; 1 = animate, 0 = static

; ============================================================================
; Warm gradient pattern - 50 entries (2 bytes each: Red, Green<<4|Blue)
; Creates smooth orange/red bars that fade in and out
; Pattern: Black → Dark Red → Orange → Yellow → White → Yellow → Orange → Dark Red → Black
; ============================================================================
warm_gradient:
    ; Lines 0-12: Black to Orange (fade in) - 13 entries
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
    
    ; Lines 13-24: White to Orange (fade down) - 12 entries
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
    
    ; Lines 25-37: Black gap - 13 entries
    db 0x00, 0x00           ; Black
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
    
    ; Lines 38-49: Black gap continued - 12 entries
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
; BSS Section - Gradient table working copy
; ============================================================================
gradient_table: resb GRADIENT_SIZE * 2

; ============================================================================
; End of Program
; ============================================================================
