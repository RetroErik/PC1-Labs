; ============================================================================
; PALRAM5.ASM - Multiple Color Changes PER Scanline Test
; ============================================================================
;
; EXPERIMENT: How many times can we change palette entry 0 during a single
; scanline, creating horizontal color bands within each line?
;
; This test writes palette entry 0 multiple times during the visible
; scanline period to create horizontal stripes of color across the screen.
;
; Written for NASM assembler
; Target: Olivetti Prodest PC1 / M24 with Yamaha V6355D video controller
; CPU: NEC V40 (80186 compatible) @ 8 MHz
;
; By Retro Erik - 2026
;
; ============================================================================
; THE EXPERIMENT
; ============================================================================
;
; Instead of one color per scanline, we attempt MULTIPLE palette writes
; during each scanline's full duration (including visible period):
;
; 1. Wait for HSYNC HIGH (entering horizontal blanking)
; 2. Do ALL setup (prepare registers, counters) DURING HBLANK
; 3. Wait for HSYNC LOW (visible scanline begins at pixel 0)
; 4. Write palette entry 0 with color 1
; 5. Minimal delay (just 3 NOPs to space writes)
; 6. Write palette entry 0 with color 2
; 7. ... repeat N times
;
; EXPECTED RESULT: Horizontal color bands across each scanline
; The number of distinct vertical stripes tells us how many writes we can fit!
;
; TIMING BUDGET:
; - Full scanline: ~63.5 μs (HBLANK ~10μs + visible ~53μs)
; - Each palette write: ~20-25 cycles (~2.5-3 μs)
; - Theoretical max: 15-20 writes per scanline
;
; FINDINGS FROM TESTING:
; - Vertical stripe alignment is perfect (setup before HSYNC LOW works!)
; - ~4-8 pixel jitter in horizontal position is NORMAL with polling
;   (caused by variable latency in detecting HSYNC transitions)
; - Excessive delays cause scanlines to be skipped (200→68 lines visible)
; - Timer interrupts (Kefrens technique) would eliminate jitter but
;   V6355D has no documented per-scanline interrupt capability
; - Polling HSYNC is the practical approach for this hardware
;
; ALTERNATIVE TECHNIQUE (not used here):
; Demos like 8088mph, Area 5150, and Kefrens bars use the PIT (Programmable
; Interval Timer, 8253 chip) to generate IRQ0 interrupts at precise scanline
; frequency. Example: writePIT16 0, 2, 76*262 sets timer to ~59.923Hz with
; 262 scanlines = perfectly timed per-scanline interrupts with ZERO jitter.
; This requires:
;   - Programming timer 0 (port 0x40-0x43) to match video timing
;   - ISR (Interrupt Service Routine) on IRQ0 that writes palette
;   - CRT timing sync (works on CGA, may not work identically on V6355D)
; The PIT method is superior (no jitter) but requires careful timer calibration
; and assumes the video controller's timing matches the PIT frequency.
;
; ============================================================================
; CONTROLS
; ============================================================================
;   ESC : Exit to DOS
;   H   : Toggle HSYNC wait (compare synchronized vs unsynchronized)
;   V   : Toggle VSYNC wait (see color scrolling effect)
;   .   : Increase writes per scanline
;   ,   : Decrease writes per scanline
;
; ============================================================================

    org 0x100                   ; COM file starts at offset 0x100

; ============================================================================
; CONSTANTS
; ============================================================================
VIDEO_SEG       equ 0xB000      ; Video memory segment
SCREEN_HEIGHT   equ 200         ; 200 scanlines
SCREEN_WIDTH    equ 160         ; 160 pixels wide
BYTES_PER_LINE  equ SCREEN_WIDTH / 2  ; 2 pixels per byte

PORT_MODE       equ 0xD8        ; Video mode register
PORT_STATUS     equ 0xDA        ; Status register (bit 0 = HSYNC, bit 3 = VBLANK)
PORT_PAL_ADDR   equ 0xDD        ; Palette address register
PORT_PAL_DATA   equ 0xDE        ; Palette data register

MAX_WRITES      equ 20          ; Maximum writes per scanline to test
DEFAULT_WRITES  equ 8           ; Start with 8 writes per scanline

; ============================================================================
; DATA SECTION
; ============================================================================
section .data

hsync_enabled:  db 1            ; 1 = wait for HSYNC, 0 = blast writes
vsync_enabled:  db 1            ; 1 = wait for VSYNC before each frame
writes_per_line: db DEFAULT_WRITES  ; Number of palette writes per scanline

; Test colors: cycling through bright colors
test_colors:
    ; Format: [R value] [G<<4 | B value]
    db 7, 0x00      ; Red
    db 7, 0x70      ; Yellow
    db 0, 0x70      ; Green
    db 0, 0x77      ; Cyan
    db 0, 0x07      ; Blue
    db 7, 0x07      ; Magenta
    db 7, 0x30      ; Orange
    db 3, 0x77      ; Light cyan
    db 7, 0x44      ; Purple
    db 5, 0x50      ; Yellow-green
    db 7, 0x77      ; White
    db 4, 0x00      ; Dark red
    db 0, 0x40      ; Dark green
    db 0, 0x04      ; Dark blue
    db 3, 0x33      ; Gray
    db 7, 0x33      ; Pink
    db 5, 0x20      ; Brown
    db 2, 0x55      ; Teal
    db 6, 0x10      ; Olive
    db 1, 0x66      ; Slate blue

; ============================================================================
; CODE SECTION
; ============================================================================
section .text

main:
    ; -----------------------------------------------------------------------
    ; Initialize program state
    ; -----------------------------------------------------------------------
    mov byte [hsync_enabled], 1
    mov byte [vsync_enabled], 1
    mov byte [writes_per_line], DEFAULT_WRITES
    
    call enable_graphics_mode
    call clear_screen
    
    ; -----------------------------------------------------------------------
    ; Main loop
    ; -----------------------------------------------------------------------
.main_loop:
    ; Check if VSYNC waiting is enabled
    cmp byte [vsync_enabled], 0
    je .skip_vsync
    call wait_vblank
    
.skip_vsync:
    call render_scanlines
    
    call check_keyboard
    cmp al, 0xFF                ; Check for exit flag
    jne .main_loop
    
    ; -----------------------------------------------------------------------
    ; Exit to DOS
    ; -----------------------------------------------------------------------
    mov ax, 0x0003              ; Text mode 80x25
    int 0x10
    mov ax, 0x4C00              ; DOS exit with return code 0
    int 0x21

; ============================================================================
; check_keyboard - Handle keyboard input
; ============================================================================
check_keyboard:
    push bx
    
    mov ah, 0x01
    int 0x16
    jz .no_key
    
    mov ah, 0x00
    int 0x16
    
    ; Check for ESC key
    cmp ah, 0x01
    jne .not_esc
    mov al, 0xFF
    jmp .done
    
.not_esc:
    ; Check for H key - Toggle HSYNC
    cmp al, 'h'
    je .toggle_hsync
    cmp al, 'H'
    jne .not_h
.toggle_hsync:
    xor byte [hsync_enabled], 1
    jmp .no_key
    
.not_h:
    ; Check for V key - Toggle VSYNC
    cmp al, 'v'
    je .toggle_vsync
    cmp al, 'V'
    jne .not_v
.toggle_vsync:
    xor byte [vsync_enabled], 1
    jmp .no_key
    
.not_v:
    ; Check for . key - Increase writes per line
    cmp al, '.'
    jne .not_period
    mov al, [writes_per_line]
    cmp al, MAX_WRITES
    jae .no_key
    inc byte [writes_per_line]
    jmp .no_key
    
.not_period:
    ; Check for , key - Decrease writes per line
    cmp al, ','
    jne .no_key
    mov al, [writes_per_line]
    cmp al, 1
    jbe .no_key
    dec byte [writes_per_line]
    
.no_key:
    xor al, al
    
.done:
    pop bx
    ret

; ============================================================================
; render_scanlines - Render with multiple color changes per scanline
; ============================================================================
render_scanlines:
    push ax
    push bx
    push cx
    push dx
    push si
    
    cli                         ; Disable interrupts
    
    mov cx, SCREEN_HEIGHT       ; CX = scanline counter (200 lines)
    mov dx, PORT_STATUS         ; DX = status port
    
    ; Check if HSYNC waiting is enabled
    cmp byte [hsync_enabled], 0
    je .no_hsync_loop
    
    ; -----------------------------------------------------------------------
    ; HSYNC-synchronized rendering loop
    ; -----------------------------------------------------------------------
.scanline_loop:
    ; Wait for HSYNC to go LOW
.wait_low:
    in al, dx
    test al, 0x01
    jnz .wait_low
    
    ; Wait for HSYNC to go HIGH (entering HBLANK)
.wait_high:
    in al, dx
    test al, 0x01
    jz .wait_high
    
    ; -----------------------------------------------------------------------
    ; CRITICAL: Do ALL setup BEFORE waiting for visible scanline
    ; This ensures first palette write happens immediately at pixel 0,
    ; minimizing horizontal position jitter.
    ;
    ; NOTE: Even with this optimization, polling introduces 4-8 pixel
    ; jitter due to variable HSYNC detection latency. This is normal
    ; and unavoidable without hardware interrupts (not available on V6355D).
    ; -----------------------------------------------------------------------
    push cx                     ; Save scanline counter
    xor si, si                  ; SI = color index (starts at 0)
    mov cl, [writes_per_line]   ; CL = number of writes to do
    xor ch, ch                  ; CX = writes counter
    
    ; Wait for HSYNC to go LOW (visible scanline begins at pixel 0!)
    ; NOW we're ready - first write happens immediately!
.wait_visible:
    in al, dx
    test al, 0x01
    jnz .wait_visible
    
.write_loop:
    ; Calculate color index (wrap around if needed)
    mov bx, si
    and bx, 0x0F                ; Wrap to 0-15 (we have 20 colors but mod 16 for safety)
    shl bx, 1                   ; BX = color_index * 2 (2 bytes per color)
    
    ; Write palette entry 0 with color from table
    mov al, 0x40                ; Select palette entry 0
    out PORT_PAL_ADDR, al
    mov al, [test_colors + bx]  ; Get R value
    out PORT_PAL_DATA, al
    mov al, [test_colors + bx + 1] ; Get G<<4|B value
    out PORT_PAL_DATA, al
    
    ; Minimal delay - just 3 NOPs to space writes slightly
    ; WARNING: Large delays (like 10-cycle loops) cause scanline skipping!
    ; With 8 writes + 10-cycle delays, processing takes ~71μs > 63.5μs/line
    ; Result: Only ~68 of 200 scanlines get processed (200/3 ≈ 67)
    ; Keep delays minimal to process all 200 scanlines per frame!
    nop
    nop
    nop
    
    inc si                      ; Next color
    loop .write_loop            ; Decrement CX, loop if not zero
    
    pop cx                      ; Restore scanline counter
    loop .scanline_loop         ; Next scanline
    jmp .done_render
    
    ; -----------------------------------------------------------------------
    ; Non-synchronized rendering loop
    ; -----------------------------------------------------------------------
.no_hsync_loop:
    push cx                     ; Save scanline counter
    
    xor si, si
    mov cl, [writes_per_line]
    xor ch, ch
    
.no_sync_write:
    mov bx, si
    and bx, 0x0F
    shl bx, 1
    
    mov al, 0x40
    out PORT_PAL_ADDR, al
    mov al, [test_colors + bx]
    out PORT_PAL_DATA, al
    mov al, [test_colors + bx + 1]
    out PORT_PAL_DATA, al
    
    ; Minimal delay for non-sync mode
    nop
    nop
    nop
    
    inc si
    loop .no_sync_write
    
    pop cx
    loop .no_hsync_loop
    
.done_render:
    sti                         ; Re-enable interrupts
    
    pop si
    pop dx
    pop cx
    pop bx
    pop ax
    ret

; ============================================================================
; wait_vblank - Wait for vertical blanking period
; ============================================================================
wait_vblank:
    push ax
    push dx
    
    mov dx, PORT_STATUS
    
.wait_vblank_end:
    in al, dx
    test al, 0x08               ; Test VBLANK bit (bit 3)
    jnz .wait_vblank_end        ; Loop while in VBLANK
    
.wait_vblank_start:
    in al, dx
    test al, 0x08
    jz .wait_vblank_start       ; Loop until VBLANK starts
    
    pop dx
    pop ax
    ret

; ============================================================================
; enable_graphics_mode - Switch to 160x200x16 graphics mode
; ============================================================================
enable_graphics_mode:
    push ax
    
    mov ax, 0x004A              ; Mode 0x4A: 160x200x16 (hidden mode)
    int 0x10
    
    pop ax
    ret

; ============================================================================
; clear_screen - Fill video memory with zeros (color index 0)
; ============================================================================
clear_screen:
    push ax
    push cx
    push di
    push es
    
    mov ax, VIDEO_SEG
    mov es, ax
    xor di, di                  ; Start at offset 0
    xor ax, ax                  ; Fill with 0
    mov cx, 16000               ; 160x200 / 2 = 16000 bytes
    rep stosb                   ; Fill memory
    
    pop es
    pop di
    pop cx
    pop ax
    ret
