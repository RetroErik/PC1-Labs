; ============================================================================
; RBARSRAM.ASM - Raster Bars via Palette RAM Manipulation
; Alternative technique: change what color 0 LOOKS like per scanline
; Written for NASM - NEC V40 (80186 compatible) @ 8 MHz
; By Retro Erik - 2026
;
; Target: Olivetti PC1 with Yamaha V6355D video controller
; Video Mode: CGA 160x200x16 (Hidden mode)
;
; ============================================================================
; TECHNIQUE: Palette RAM Manipulation (not PORT_COLOR!)
; ============================================================================
;
; Instead of using PORT_COLOR (port 0xD9), this demo changes palette entry 0's
; RGB values per scanline. Since the screen is filled with color index 0,
; changing what color 0 looks like changes the entire scanline's color.
;
; Palette write sequence (per scanline):
;   1. Write 0x40 to port 0xDD (select palette entry 0, write mode)
;   2. Write Red byte to port 0xDE (bits 0-2 = intensity 0-7)
;   3. Write Green|Blue byte to port 0xDE (bits 4-6 = G, bits 0-2 = B)
;
; This is 3 OUT instructions per scanline (slower than PORT_COLOR's 1 OUT).
;
; ============================================================================
; COMPARISON: Palette RAM vs PORT_COLOR
; ============================================================================
;
; Palette RAM (this demo) - SLOWER but 512 colors:
;   - 3 OUT instructions per scanline (select + red + green|blue)
;   - Direct RGB control: 8 levels each for R, G, B = 512 colors total!
;   - NOT limited to 16-color palette - you set the actual RGB values
;   - Can create smooth color gradients impossible with PORT_COLOR
;   - Affects all pixels using that palette index (sprites, graphics, etc)
;
; PORT_COLOR (other rbars demos) - FASTER but only 16 colors:
;   - 1 OUT instruction per scanline
;   - Limited to 16 palette entries - just picks WHICH color, not RGB
;   - Only affects overscan/background color, not drawn graphics
;   - Simpler to use, less tearing risk
;
; Use PORT_COLOR for simple 16-color raster effects.
; Use Palette RAM for true RGB gradients or affecting drawn graphics.
;
; ============================================================================
; BORDER FLICKER NOTE
; ============================================================================
;
; Palette 0 changes affect both active area AND borders. This can cause 
; visible flickering in borders. Use edge detection for cleaner results.
;
; Controls:
;   H   - Toggle HSYNC wait on/off
;   ESC - Exit to DOS
; ============================================================================

[BITS 16]
[ORG 0x100]

; ============================================================================
; Constants
; ============================================================================

; --- Yamaha V6355D I/O Ports ---
PORT_MODE       equ 0xD8        ; Mode Control Register
PORT_STATUS     equ 0xDA        ; Status Register (bit 0=HSYNC, bit 3=VBLANK)
PORT_STATUS     equ 0xDA        ; Status Register (read-only)
                                ; Bit 0: HSYNC (1 = in horizontal retrace)
                                ; Bit 3: VBLANK (1 = in vertical retrace)
PORT_PAL_ADDR   equ 0xDD        ; Palette register address
PORT_PAL_DATA   equ 0xDE        ; Palette register data

; --- Video Memory ---
VIDEO_SEG       equ 0xB000      ; PC1 video RAM segment

; ============================================================================
; Main Program
; ============================================================================
main:
    ; Enable 160x200x16 hidden graphics mode
    call enable_graphics_mode
    
    ; Set palette entry 15 to near-black (R=1, G=0, B=0)
    ; This will be used for borders during VBLANK
    mov al, 0x4F            ; Palette entry 15, write mode
    out PORT_PAL_ADDR, al
    mov al, 1               ; R = 1 (very dark red)
    out PORT_PAL_DATA, al
    xor al, al              ; G|B = 0
    out PORT_PAL_DATA, al
    
    ; Clear screen to color 0 (this is what we'll be changing)
    call clear_screen
    
    ; Run the raster loop
    call raster_loop
    
    ; Reset palette entry 0 to black before exiting
    mov al, 0x40
    out PORT_PAL_ADDR, al
    xor al, al
    out PORT_PAL_DATA, al   ; R = 0
    out PORT_PAL_DATA, al   ; G|B = 0
    
    ; Restore text mode and exit
    mov ax, 0x0003
    int 0x10
    int 0x20

; ============================================================================
; raster_loop - Per-scanline palette manipulation
; ============================================================================
raster_loop:
    xor bx, bx              ; BL = color intensity (0-7)
    
.next_line:
    ; --- Wait for HSYNC ---
    cmp byte [hsync_enabled], 0
    je .skip_hsync
    
    mov dx, PORT_STATUS
.wait_low:
    in al, dx
    test al, 0x01
    jnz .wait_low
.wait_high:
    in al, dx
    test al, 0x01
    jz .wait_high
    
.skip_hsync:
    ; --- Set palette entry 0 to current color ---
    mov al, 0x40
    out PORT_PAL_ADDR, al
    mov al, bl              ; Red intensity (0-7)
    out PORT_PAL_DATA, al
    xor al, al              ; G=0, B=0
    out PORT_PAL_DATA, al
    
    ; --- Next color ---
    inc bl
    and bl, 0x07            ; Wrap 0-7
    
    ; --- Check keyboard ---
    in al, 0x60
    cmp al, 0x01            ; ESC?
    je .exit
    cmp al, 0x23            ; H key?
    jne .next_line
    
    xor byte [hsync_enabled], 1
.wait_release:
    in al, 0x60
    cmp al, 0x23
    je .wait_release
    jmp .next_line
    
.exit:
    ret

; ============================================================================
; enable_graphics_mode - Enable 160x200x16 hidden mode
; ============================================================================
enable_graphics_mode:
    mov al, 0x4A
    out PORT_MODE, al
    ret

; ============================================================================
; clear_screen - Fill video memory with color 0
; ============================================================================
clear_screen:
    push es
    mov ax, VIDEO_SEG
    mov es, ax
    xor di, di
    mov cx, 8192
    xor ax, ax
    cld
    rep stosw
    pop es
    ret

; ============================================================================
; Data
; ============================================================================
hsync_enabled: db 1         ; 1 = wait for HSYNC, 0 = free-running
