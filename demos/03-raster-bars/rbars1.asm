; ============================================================================
; RBARS0.ASM - Raster Basics: Per-Scanline Border Color Cycling
; Minimal demo showing how raster effects work on the BORDER area
; Written for NASM - NEC V40 (80186 compatible) @ 8 MHz
; By Retro Erik - 2026
;
; Target: Olivetti PC1 with Yamaha V6355D video controller
; Video Mode: CGA 160x200x16 (Hidden mode)
;
; ============================================================================
; WHAT WE ARE TESTING:
; ============================================================================
;
; PORT_COLOR (0xD9):
;   - Sets the BORDER color only (not the active 160x200 screen area)
;   - Takes a value 0-15, selecting one of the 16 palette entries
;   - Each palette entry can be any color from the 512-color RGB palette
;   - So we have 16 colors to choose from per frame (set via palette RAM)
;
; HSYNC (bit 0 of PORT_STATUS):
;   - Tells us when the CRT beam starts a new scanline
;   - By waiting for HSYNC before changing color, we get one color per line
;   - Without HSYNC sync: colors change too fast, screen looks grey/mixed
;   - With HSYNC sync: clean horizontal stripes in the border
;
; VBLANK (bit 3 of PORT_STATUS):
;   - Tells us when vertical blanking begins (end of visible frame)
;   - Useful for knowing when we've passed line 199
;   - More on this in rbars1.asm
;
; ============================================================================
; WHAT WE LEARNED:
; ============================================================================
;
; ** MAJOR DISCOVERY **
; PORT_COLOR affects the ENTIRE scanline, but ONLY if you first "unlock" it
; by writing 0x40 to port 0xDD (PORT_REG_ADDR).
;
; Without the 0x40 unlock: PORT_COLOR only affects the BORDER/OVERSCAN area!
; With the 0x40 unlock: PORT_COLOR affects the full scanline width!
;
; The 0x40 value means "palette index 0, write mode" - even without writing
; any palette data, this single OUT instruction enables full-width PORT_COLOR.
;
; HSYNC Timing (edge detection vs simple wait):
;   - Edge detection (0→1): Full width + CLEAN top/bottom borders (black)
;   - Simple wait (bit=1):  Full width + COLORS in all 4 borders
;
; THIS DEMO: Shows border-only effect because it lacks the 0x40 unlock.
; See rbars4.asm for a working full-width example with the unlock.
;
; Controls:
;   H   - Toggle HSYNC wait on/off (see the difference!)
;   ESC - Exit to DOS
; ============================================================================

[BITS 16]
[ORG 0x100]

; ============================================================================
; Constants
; ============================================================================

; --- Yamaha V6355D I/O Ports ---
PORT_MODE       equ 0xD8        ; Mode Control Register
PORT_COLOR      equ 0xD9        ; Color Select Register (border/background)
PORT_STATUS     equ 0xDA        ; Status Register (read-only)
                                ; Bit 0: HSYNC (1 = in horizontal retrace)
                                ; Bit 3: VBLANK (1 = in vertical retrace)

; --- Video Memory ---
VIDEO_SEG       equ 0xB000      ; PC1 video RAM segment

; ============================================================================
; Main Program
; ============================================================================
main:
    ; Enable 160x200x16 hidden graphics mode
    call enable_graphics_mode
    
    ; Clear screen so we only see the color effect
    call clear_screen
    
    ; Run the raster loop
    call raster_loop
    
    ; Restore text mode and exit
    mov ax, 0x0003
    int 0x10
    int 0x20

; ============================================================================
; raster_loop - The core raster effect
;
; This is the heart of raster effects:
;   1. Wait for HSYNC (start of new scanline)
;   2. Change the color
;   3. Repeat forever (until ESC)
;
; Each scanline gets a different color because we're synchronized
; with the CRT beam's horizontal position.
; ============================================================================
raster_loop:
    xor bx, bx              ; BX = color counter (0-15, wraps)
    
.next_line:
    ; --- Wait for HSYNC (if enabled) ---
    cmp byte [hsync_enabled], 0
    je .skip_hsync
    
    mov dx, PORT_STATUS
    
    ; First wait for bit 0 = 0 (not in HSYNC)
.wait_low:
    in al, dx
    test al, 0x01
    jnz .wait_low           ; Still high, keep waiting
    
    ; Now wait for bit 0 = 1 (HSYNC starts)
.wait_high:
    in al, dx
    test al, 0x01
    jz .wait_high           ; Still low, keep waiting
    
.skip_hsync:
    ; --- Output color for this scanline ---
    mov dx, PORT_COLOR
    mov al, bl
    out dx, al
    
    ; --- Next color (cycle 0-15) ---
    inc bl
    and bl, 0x0F
    
    ; --- Check keyboard ---
    in al, 0x60             ; Read keyboard scancode
    cmp al, 0x01            ; ESC?
    je .exit
    cmp al, 0x23            ; H key scancode
    jne .next_line
    
    ; Toggle HSYNC and wait for key release
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
;
; The Yamaha V6355D has a hidden 16-color graphics mode.
; Writing 0x4A to port 0xD8 enables it.
; ============================================================================
enable_graphics_mode:
    mov al, 0x4A
    out PORT_MODE, al
    ret

; ============================================================================
; clear_screen - Fill video memory with color 0 (shows background color)
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
hsync_enabled: db 0         ; 0 = free-running, 1 = wait for HSYNC
