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
; CORE CONCEPT:
; Instead of using PORT_COLOR (port 0xD9), this demo changes palette entry
; RGB values per scanline. The entire screen is filled with a single color
; INDEX (in this case, 0). By changing what that index LOOKS like via palette
; RAM, the entire scanline changes color in real-time.
;
; PALETTE WRITE SEQUENCE (per scanline):
;   1. Write 0x40 to port 0xDD (select palette entry 0, write mode)
;   2. Write Red byte to port 0xDE (bits 0-2 = intensity 0-7)
;   3. Write Green|Blue byte to port 0xDE (bits 4-6 = G, bits 0-2 = B)
;
; = 3 OUT instructions per scanline (compare to PORT_COLOR's 1 OUT)
;
; WHY THIS IS POWERFUL:
;
; 1. DIRECT RGB CONTROL (NOT palette-limited):
;    - 8 levels each for Red, Green, Blue = 8×8×8 = 512 total colors
;    - You set the actual RGB values, not picking from a 16-color palette
;    - Create smooth color gradients impossible with PORT_COLOR's 16 colors
;
; 2. AFFECTS DRAWN GRAPHICS (not just background):
;    - If you draw sprites/text using color 0, they change color too!
;    - PORT_COLOR only changes background/overscan, not drawn content
;    - This opens up incredible visual effects with existing graphics
;
; 3. ANY PALETTE ENTRY (not just color 0):
;    - Can modify entries 0x40-0x4F (palette colors 0-15) independently
;    - Scanline 1: Change entry 5 (0x45) → all color-5 pixels change
;    - Scanline 2: Change entry 12 (0x4C) → all color-12 pixels change
;    - This means different parts of your screen can change colors separately!
;
; 4. MULTIPLE ENTRIES PER SCANLINE:
;    - Have 3 OUTs per palette entry, so changing 3 entries = 9 OUTs
;    - At 8MHz, ~509 cycles per scanline, 9 OUTs take ~90 cycles
;    - Leaves plenty of time for complex effects
;    - Example: Draw text in color 1, sprites in colors 2-7, background 0
;              Then per scanline, cycle ALL three independently!
;
; 5. AMIGA-LIKE PALETTE TRICKS (similar to Copper/HAM concept):
;    - Amiga HAM: Per-pixel spatial modification (4096 colors but artifacts)
;    - This technique: Per-scanline temporal modification (512 colors, clean)
;    - Both are clever palette hacks to break color limits
;    - Both sacrifice something (HAM artifacts vs palette RAM timing)
;    - Both enable effects impossible with static palettes
;
; COMPARISON TO PORT_COLOR:
;    Palette RAM: 512 colors, affects all graphics, slower (3 OUTs)
;    PORT_COLOR:  16 colors, affects only background, faster (1 OUT)
;
; THIS DEMO:
; This simple example fills the screen with color 0 and cycles through all
; 512 colors by incrementing R, G, B channels per scanline. Over 200 visible
; scanlines, you'll see a smooth gradient using 200 different RGB colors
; drawn from the full 512-color palette. This demonstrates the core technique,
; but the real power is using different palette entries for different graphics!
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
; raster_loop - Per-scanline palette manipulation through all 512 colors
; ============================================================================
raster_loop:
    xor bx, bx              ; BL = red (0-7), BH = green (0-7)
    xor cx, cx              ; CL = blue (0-7)
    
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
    ; --- Set palette entry 0 to current RGB color ---
    mov al, 0x40
    out PORT_PAL_ADDR, al
    mov al, bl              ; Red intensity (0-7)
    out PORT_PAL_DATA, al
    mov al, bh              ; Green (bits 4-6)
    shl al, 4
    or al, cl               ; Blue (bits 0-2)
    out PORT_PAL_DATA, al
    
    ; --- Advance through all 512 colors ---
    ; Increment blue first, then green, then red (LSB to MSB)
    inc cl
    cmp cl, 8
    jne .skip_blue_wrap
    xor cl, cl              ; Blue wraps to 0
    inc bh                  ; Increment green
    cmp bh, 8
    jne .skip_blue_wrap
    xor bh, bh             ; Green wraps to 0
    inc bl                  ; Increment red
    and bl, 0x07            ; Red wraps at 8
.skip_blue_wrap:
    
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
