; ============================================================================
; REG65_TEST.ASM - V6355D Register 0x65 Mid-Frame Test
; Olivetti Prodest PC1 - V6355D 160x200x16 Hidden Graphics Mode
; Written for NASM - NEC V40 @ 8 MHz (80186 instruction set)
; By RetroErik - 2026
;
; PURPOSE:
;   Test whether V6355D Register 0x65 (Monitor Control) can be changed
;   mid-frame. Bits 0-1 control vertical line count:
;     00 = 192 lines
;     01 = 200 lines (default)
;     10 = 204 lines
;     11 = unknown / reserved
;
;   Mid-frame changes DO take effect. This register can be used for
;   raster-style vertical splitting or line-count tricks.
;
; HARDWARE TEST RESULTS (February 23, 2026 — Olivetti Prodest PC1):
; -----------------------------------------------------------------
;   TEST A: PASS — All 4 modes cycle correctly (192/200/204/reserved).
;           Display visibly grows/shrinks. Border colors confirm mode.
;   TEST B: PASS — Bottom lines cut off (light blue border). Mid-frame
;           200→192 switch removes the bottom 8 lines.
;   TEST C: PASS — Extra lines appear at bottom (orange border). Mid-frame
;           200→204 switch extends the display by 4 lines.
;   TEST D: PASS — Bottom lines alternate each frame (red/purple border).
;           Per-frame toggle between 192 and 204 produces visible flicker.
;
;   PALETTE CORRUPTION: Writing 0x65 to port 0x3DD corrupts palette because
;   bit 6 of 0x65 overlaps the palette command range (0x40-0x4F). Fixed by:
;   (1) closing palette session (write 0x80 to 0x3DD) after register write,
;   (2) restoring palette programmatically after runtime register writes.
;
;   CONCLUSION: Register 0x65 responds to both static and mid-frame changes,
;   but controls only vertical line count — NOT CRTC addressing. It cannot
;   solve the 384-byte gap problem for hardware scrolling. In 192-line mode,
;   the gap increases from 192 to 512 bytes (6 smooth scroll steps vs 2 at
;   200 lines), but the fundamental CRTC wrap at 8192 remains.
;   All hardware avenues for the gap are now exhausted.
; -----------------------------------------------------------------
;
; FOUR TESTS (press key to activate):
;
;   '1' = TEST A: Static line count changes
;         Cycles through 192/200/204/reserved modes.
;         Press 1 repeatedly to cycle: 200 → 192 → 204 → ?? → 200 ...
;         Border color indicates current setting.
;         RESULT: All modes work. Display height visibly changes.
;
;   '2' = TEST B: Mid-frame split — top=200 lines, bottom=192 lines
;         During vsync, sets 200-line mode. At approximately scanline 100,
;         switches to 192-line mode.
;         RESULT: Bottom portion cut short. Mid-frame change takes effect.
;         Press ESC during test to return to menu.
;
;   '3' = TEST C: Mid-frame split — top=200 lines, bottom=204 lines
;         Same as Test B but switches to 204-line mode at scanline 100.
;         RESULT: Extra lines appear at bottom. Mid-frame extension works.
;         Press ESC during test to return to menu.
;
;   '4' = TEST D: Per-frame toggle — alternates 192/204 each frame
;         Rapidly alternates between 192 and 204 lines every frame.
;         RESULT: Bottom lines toggle on/off each frame (visible flicker).
;         Press ESC during test to return to menu.
;
;   'R' = Reset register 0x65 to default (200 lines, PAL, CRT)
;   ESC = Exit to DOS
;
; BUILD:
;   nasm -f bin -o reg65tst.com reg65_test.asm
;
; ============================================================================

[BITS 16]
[CPU 186]
[ORG 0x100]

; ============================================================================
; Constants
; ============================================================================

VIDEO_SEG       equ 0xB000          ; V6355D VRAM segment
BYTES_PER_LINE  equ 80              ; 160 pixels / 2 pixels per byte
LINES_PER_BANK  equ 100             ; 200 visible lines / 2 banks
ODD_BANK_OFFSET equ 0x2000          ; Odd scanlines start here

; V6355D Ports
; Note: 0xDD/0xDE and 0x3DD/0x3DE are aliases on PC1 hardware
PORT_REG_ADDR   equ 0x3DD           ; V6355D Register Bank Address Port
PORT_REG_DATA   equ 0x3DE           ; V6355D Register Bank Data Port
PORT_MODE       equ 0x3D8           ; CGA Mode Control
PORT_COLOR      equ 0x3D9           ; CGA Color Select
PORT_STATUS     equ 0x3DA           ; Status (bit 0=HSync, bit 3=VBlank)
PORT_CRTC_ADDR  equ 0x3D4           ; CRTC index port
PORT_CRTC_DATA  equ 0x3D5           ; CRTC data port
;
; PALETTE CORRUPTION WARNING:
;   Port 0x3DD is shared between register select and palette commands.
;   Writing 0x65 to 0x3DD may be interpreted as a palette command (bit 6 set),
;   corrupting DAC state. colorbar.asm and PC1-BMP.asm avoid this because they
;   write register 0x65 BEFORE palette setup (palette overwrites any damage).
;   For runtime register writes (after palette is set), we must:
;     1. Write register normally via 0x3DD/0x3DE
;     2. Close any palette session: write 0x80 to 0x3DD
;     3. Restore the palette

; Register 0x65 bit fields
; Bits 0-1: Vertical line count
;   00 = 192 lines (96 character rows)
;   01 = 200 lines (100 character rows) — default
;   10 = 204 lines (102 character rows)
;   11 = unknown / reserved
; Bit 2: Horizontal width (0=320/640)
; Bit 3: PAL/50Hz (1=PAL, 0=NTSC)
; Bit 4: CGA color mode (0=color)
; Bit 5: Display type (0=CRT, 1=LCD)
; Bit 6: RAM type (0=Dynamic)
; Bit 7: Light pen (0=no)

REG65_DEFAULT   equ 0x09            ; PAL, 200 lines, CRT = 0000_1001
REG65_192       equ 0x08            ; PAL, 192 lines, CRT = 0000_1000
REG65_200       equ 0x09            ; PAL, 200 lines, CRT = 0000_1001
REG65_204       equ 0x0A            ; PAL, 204 lines, CRT = 0000_1010
REG65_RESERVED  equ 0x0B            ; PAL, ???, CRT       = 0000_1011

; Keyboard scancodes (port 0x60)
KEY_ESC         equ 0x01
KEY_1           equ 0x02
KEY_2           equ 0x03
KEY_3           equ 0x04
KEY_4           equ 0x05
KEY_R           equ 0x13

; Border colors for feedback
BORDER_BLACK    equ 0x00
BORDER_BLUE     equ 0x01            ; 192 lines
BORDER_GREEN    equ 0x02            ; 200 lines (default)
BORDER_RED      equ 0x04            ; 204 lines
BORDER_MAGENTA  equ 0x05            ; reserved (11)
BORDER_CYAN     equ 0x03            ; Test B active
BORDER_YELLOW   equ 0x06            ; Test C active
BORDER_WHITE    equ 0x07            ; Test D active

; Approximate PIT-ticks-per-scanline timing for polling
; CGA scanline = ~76 PIT ticks. We need to count ~100 scanlines (50 char rows)
; to find the midpoint. We'll use HSYNC edge counting.
MIDPOINT_LINE   equ 100             ; Scanline at which to switch reg 0x65


; ============================================================================
; Main Entry Point
; ============================================================================

main:
    ; Save current video mode
    mov ah, 0x0F
    int 0x10
    mov [saved_mode], al

    ; Set CGA mode 4 first (initializes CRTC timing)
    mov ax, 0x0004
    int 0x10

    ; Switch to hidden 160x200x16 mode
    call enable_hidden_mode

    ; Set up a visible 16-color palette
    call set_test_palette

    ; Fill VRAM with recognizable colored horizontal bands
    ; Plus marker lines at key positions (192, 200, 204)
    call fill_color_bands

    ; Initialize line count mode
    mov byte [current_mode], 1      ; Start at 200 lines (bits = 01)

    ; ---- Main menu loop ----
.menu_loop:
    ; Wait for keypress (BIOS — interrupts enabled)
    mov ah, 0x00
    int 0x16                        ; AL = ASCII, AH = scancode

    cmp ah, KEY_ESC
    je .exit_program
    cmp ah, KEY_1
    je .test_a
    cmp ah, KEY_2
    je .test_b
    cmp ah, KEY_3
    je .test_c
    cmp ah, KEY_4
    je .test_d
    cmp ah, KEY_R
    je .reset_reg65
    jmp .menu_loop

; ---- TEST A: Static line count cycle ----
; Cycles through 192 → 200 → 204 → reserved → 192 ...
.test_a:
    ; Advance to next mode
    mov al, [current_mode]
    inc al
    and al, 0x03                    ; Wrap 0-3
    mov [current_mode], al

    ; Write register 0x65 with new vertical line count
    call write_reg65_from_mode

    ; Restore palette (writing 0x65 to 0x3DD corrupts palette state)
    call set_test_palette

    ; Set border color to indicate mode
    call set_border_for_mode

    jmp .menu_loop

; ---- Reset register 0x65 to default ----
.reset_reg65:
    mov byte [current_mode], 1      ; 200 lines
    call write_reg65_from_mode

    ; Restore palette (register write corrupts palette)
    call set_test_palette

    ; Black border
    mov dx, PORT_COLOR
    xor al, al
    out dx, al

    jmp .menu_loop

; ---- TEST B: Mid-frame split 200→192 ----
.test_b:
    ; Cyan border to indicate Test B
    mov dx, PORT_COLOR
    mov al, BORDER_CYAN
    out dx, al

    call run_midframe_split_192
    call set_test_palette            ; Restore palette (safety)
    jmp .menu_loop

; ---- TEST C: Mid-frame split 200→204 ----
.test_c:
    ; Yellow border to indicate Test C
    mov dx, PORT_COLOR
    mov al, BORDER_YELLOW
    out dx, al

    call run_midframe_split_204
    call set_test_palette            ; Restore palette (safety)
    jmp .menu_loop

; ---- TEST D: Per-frame 192/204 toggle ----
.test_d:
    ; White border to indicate Test D
    mov dx, PORT_COLOR
    mov al, BORDER_WHITE
    out dx, al

    call run_frame_toggle
    call set_test_palette            ; Restore palette (safety)
    jmp .menu_loop

; ---- Exit to DOS ----
.exit_program:
    ; Reset register 0x65 to default
    mov dx, PORT_REG_ADDR
    mov al, 0x65
    out dx, al
    jmp short $+2
    mov dx, PORT_REG_DATA
    mov al, REG65_DEFAULT
    out dx, al
    jmp short $+2
    ; Close palette session
    mov dx, PORT_REG_ADDR
    mov al, 0x80
    out dx, al

    ; Restore video mode
    mov ah, 0x00
    mov al, [saved_mode]
    int 0x10

    mov ax, 0x4C00
    int 0x21


; ============================================================================
; write_reg65_from_mode - Write register 0x65 based on current_mode (0-3)
;
; current_mode 0 = 192 lines (bits 0-1 = 00)
; current_mode 1 = 200 lines (bits 0-1 = 01)
; current_mode 2 = 204 lines (bits 0-1 = 10)
; current_mode 3 = reserved  (bits 0-1 = 11)
; ============================================================================

write_reg65_from_mode:
    push ax
    push bx
    push dx

    ; Look up reg65 value from table
    mov bl, [current_mode]
    xor bh, bh
    mov al, [reg65_table + bx]

    ; Write register 0x65 via 0x3DD/0x3DE (same as colorbar.asm / PC1-BMP.asm)
    mov dx, PORT_REG_ADDR
    push ax
    mov al, 0x65
    out dx, al
    jmp short $+2
    pop ax
    mov dx, PORT_REG_DATA
    out dx, al
    jmp short $+2

    ; Close any palette session that 0x65 may have opened
    mov dx, PORT_REG_ADDR
    mov al, 0x80
    out dx, al

    pop dx
    pop bx
    pop ax
    ret


; ============================================================================
; set_border_for_mode - Set border color based on current_mode
; ============================================================================

set_border_for_mode:
    push ax
    push bx
    push dx

    mov bl, [current_mode]
    xor bh, bh
    mov al, [border_table + bx]

    mov dx, PORT_COLOR
    out dx, al

    pop dx
    pop bx
    pop ax
    ret


; ============================================================================
; write_reg65 - Write a value to register 0x65
; Input: AL = value to write
; ============================================================================

write_reg65:
    push ax
    push dx

    ; Write register 0x65 via 0x3DD/0x3DE (proven method from colorbar.asm)
    mov ah, al                      ; Save value
    mov dx, PORT_REG_ADDR
    mov al, 0x65
    out dx, al
    jmp short $+2
    mov dx, PORT_REG_DATA
    mov al, ah
    out dx, al
    jmp short $+2

    ; Close any palette session that 0x65 may have opened on 0x3DD
    mov dx, PORT_REG_ADDR
    mov al, 0x80
    out dx, al

    pop dx
    pop ax
    ret


; ============================================================================
; run_midframe_split_192 - Mid-frame split: 200 lines → 192 lines
;
; Each frame:
;   1. During vsync: set reg 0x65 to 200-line mode
;   2. Wait until approximately scanline 100 (midpoint)
;   3. Switch reg 0x65 to 192-line mode
;
; If the V6355D responds to mid-frame 0x65 changes, the bottom half
; of the display should be cut short (192-line boundary reached sooner).
;
; Uses HSYNC edge counting for scanline timing (same technique as
; the raster bar demos in 03-port-color-rasters).
; ============================================================================

run_midframe_split_192:
    cli                             ; Disable interrupts for tight timing

.split192_frame:
    mov dx, PORT_STATUS

    ; Wait for vsync start (bit 3 high)
.s192_wait_vsync:
    in al, dx
    test al, 8
    jz .s192_wait_vsync

    ; Check ESC during vsync
    in al, 0x60
    cmp al, KEY_ESC
    je .split192_exit

    ; Set 200-line mode at top of frame
    mov al, REG65_200
    call write_reg65

    ; Wait for vsync end (bit 3 low)
    mov dx, PORT_STATUS
.s192_wait_vsync_end:
    in al, dx
    test al, 8
    jnz .s192_wait_vsync_end

    ; Count HSYNC edges to reach the midpoint
    ; HSYNC = STATUS bit 0. We detect 0→1 transitions.
    ; We need to count approximately MIDPOINT_LINE scanlines.
    mov cx, MIDPOINT_LINE

.s192_count_lines:
    ; Wait for bit 0 = 0 (display active)
.s192_wait_de:
    in al, dx
    test al, 1
    jnz .s192_wait_de

    ; Wait for bit 0 = 1 (retrace/blanking)
.s192_wait_dd:
    in al, dx
    test al, 1
    jz .s192_wait_dd

    dec cx
    jnz .s192_count_lines

    ; === MIDPOINT REACHED ===
    ; Switch to 192-line mode
    mov al, REG65_192
    call write_reg65

    ; Let the rest of the frame display with 192-line setting
    jmp .split192_frame

.split192_exit:
    sti

    ; Acknowledge keyboard
    in al, 0x61
    mov ah, al
    or al, 0x80
    out 0x61, al
    mov al, ah
    out 0x61, al
    mov al, 0x20
    out 0x20, al

    ; Restore 200-line default
    mov al, REG65_DEFAULT
    call write_reg65

    ret


; ============================================================================
; run_midframe_split_204 - Mid-frame split: 200 lines → 204 lines
;
; Same as above but switches to 204-line mode at the midpoint.
; If it works, the display might extend 4 extra lines at the bottom.
; ============================================================================

run_midframe_split_204:
    cli

.split204_frame:
    mov dx, PORT_STATUS

    ; Wait for vsync start
.s204_wait_vsync:
    in al, dx
    test al, 8
    jz .s204_wait_vsync

    ; Check ESC
    in al, 0x60
    cmp al, KEY_ESC
    je .split204_exit

    ; Set 200-line mode at top of frame
    mov al, REG65_200
    call write_reg65

    ; Wait for vsync end
    mov dx, PORT_STATUS
.s204_wait_vsync_end:
    in al, dx
    test al, 8
    jnz .s204_wait_vsync_end

    ; Count to midpoint
    mov cx, MIDPOINT_LINE

.s204_count_lines:
.s204_wait_de:
    in al, dx
    test al, 1
    jnz .s204_wait_de
.s204_wait_dd:
    in al, dx
    test al, 1
    jz .s204_wait_dd
    dec cx
    jnz .s204_count_lines

    ; === MIDPOINT REACHED ===
    ; Switch to 204-line mode
    mov al, REG65_204
    call write_reg65

    jmp .split204_frame

.split204_exit:
    sti

    ; Acknowledge keyboard
    in al, 0x61
    mov ah, al
    or al, 0x80
    out 0x61, al
    mov al, ah
    out 0x61, al
    mov al, 0x20
    out 0x20, al

    ; Restore default
    mov al, REG65_DEFAULT
    call write_reg65

    ret


; ============================================================================
; run_frame_toggle - Alternate 192/204 lines each frame
;
; If register 0x65 is latched at frame boundaries (vsync), this will
; produce visible flickering between 192 and 204 line modes.
; If it's latched at some other time, we'll see whatever the V6355D does.
; ============================================================================

run_frame_toggle:
    cli
    xor si, si                      ; SI = frame counter (even=192, odd=204)

.toggle_frame:
    mov dx, PORT_STATUS

    ; Wait for vsync start
.t_wait_vsync:
    in al, dx
    test al, 8
    jz .t_wait_vsync

    ; Check ESC
    in al, 0x60
    cmp al, KEY_ESC
    je .toggle_exit

    ; Set line mode based on frame parity
    test si, 1
    jnz .t_set_204

    ; Even frame: 192 lines
    mov al, REG65_192
    call write_reg65

    ; Also flash border to show which mode
    mov dx, PORT_COLOR
    mov al, BORDER_BLUE             ; Blue = 192
    out dx, al
    jmp short .t_wait_end

.t_set_204:
    ; Odd frame: 204 lines
    mov al, REG65_204
    call write_reg65

    mov dx, PORT_COLOR
    mov al, BORDER_RED              ; Red = 204
    out dx, al

.t_wait_end:
    inc si

    ; Wait for vsync end
    mov dx, PORT_STATUS
.t_wait_vsync_end:
    in al, dx
    test al, 8
    jnz .t_wait_vsync_end

    jmp .toggle_frame

.toggle_exit:
    sti

    ; Acknowledge keyboard
    in al, 0x61
    mov ah, al
    or al, 0x80
    out 0x61, al
    mov al, ah
    out 0x61, al
    mov al, 0x20
    out 0x20, al

    ; Restore default
    mov al, REG65_DEFAULT
    call write_reg65

    ; Reset border
    mov dx, PORT_COLOR
    xor al, al
    out dx, al

    ret


; ============================================================================
; enable_hidden_mode - Activate PC1 160x200x16 hidden graphics mode
; ============================================================================

enable_hidden_mode:
    push ax
    push dx

    ; Register 0x65 = monitor control (200 lines, PAL, CRT)
    ; Same method as colorbar.asm and PC1-BMP.asm
    mov dx, PORT_REG_ADDR
    mov al, 0x65
    out dx, al
    jmp short $+2
    mov dx, PORT_REG_DATA
    mov al, REG65_DEFAULT           ; PAL, 200 lines, CRT
    out dx, al
    jmp short $+2

    ; Mode register: graphics on, video enable, unlock
    mov dx, PORT_MODE
    mov al, 0x4A                    ; bit 1=GRPH, bit 3=VIDEO, bit 6=UNLOCK
    out dx, al
    jmp short $+2

    ; Black border
    mov dx, PORT_COLOR
    xor al, al
    out dx, al

    pop dx
    pop ax
    ret


; ============================================================================
; set_test_palette - 16 distinct colors for band visibility
; ============================================================================

set_test_palette:
    push ax
    push cx
    push dx
    push si

    ; Open palette write (select entry 0)
    mov dx, PORT_REG_ADDR
    mov al, 0x40                    ; Entry 0 command
    out dx, al
    jmp short $+2

    ; Write 16 entries from table (R byte, then GB byte each)
    mov dx, PORT_REG_DATA
    mov si, palette_data
    mov cx, 32                      ; 16 entries × 2 bytes each

.pal_loop:
    lodsb
    out dx, al
    jmp short $+2
    dec cx
    jnz .pal_loop

    ; Close palette write
    mov dx, PORT_REG_ADDR
    mov al, 0x80
    out dx, al

    pop si
    pop dx
    pop cx
    pop ax
    ret


; ============================================================================
; fill_color_bands - Fill VRAM with horizontal color bands + marker lines
;
; 16 color bands across 200 lines. Additionally, lines 191-192 are drawn
; in bright white and lines 199-200 in bright red, lines 203-204 in
; bright cyan — these serve as visual markers for the 192/200/204 line
; boundaries. If the display extends or shrinks, these markers will
; appear or disappear.
; ============================================================================

fill_color_bands:
    push ax
    push bx
    push cx
    push dx
    push di
    push es

    mov ax, VIDEO_SEG
    mov es, ax

    ; --- Fill 102 even lines (lines 0, 2, 4, ... 202) and 102 odd lines ---
    ; We fill slightly more than 100 per bank to have content at 204-line area
    ; Even bank: offsets 0x0000..0x1FFF (up to 102 lines = 8160 bytes)
    ; Some of this will be in the "gap" area (offsets 8000-8191) but that's OK
    ; since we want to see what the V6355D displays for 204-line mode.

    ; Fill even bank (lines 0, 2, 4, ... 202)
    xor di, di                      ; Start at 0x0000
    mov cx, 102                     ; 102 even lines (for 204-line mode)

.fill_even:
    mov ax, 102
    sub ax, cx                      ; AX = even line index (0..101)
    shl ax, 1                       ; AX = display line (0,2,4..202)
    push cx
    call get_line_color
    ; AL = fill byte (nibble | nibble<<4)
    mov cx, BYTES_PER_LINE
    rep stosb
    pop cx
    loop .fill_even

    ; Fill odd bank (lines 1, 3, 5, ... 203)
    mov di, ODD_BANK_OFFSET         ; Start at 0x2000
    mov cx, 102                     ; 102 odd lines

.fill_odd:
    mov ax, 102
    sub ax, cx
    shl ax, 1
    inc ax                          ; AX = display line (1,3,5..203)
    push cx
    call get_line_color
    mov cx, BYTES_PER_LINE
    rep stosb
    pop cx
    loop .fill_odd

    pop es
    pop di
    pop dx
    pop cx
    pop bx
    pop ax
    ret


; ============================================================================
; get_line_color - Return fill byte for a given display line
;
; Input:  AX = display line number (0-203)
; Output: AL = fill byte (nibble | nibble<<4)
;
; Lines 190-191: bright white (color 15) — marks 192-line boundary
; Lines 198-199: bright red (color 12) — marks 200-line boundary
; Lines 202-203: bright cyan (color 11) — marks 204-line boundary
; Other lines: color band pattern (line / 13 = color index 0-15)
; ============================================================================

get_line_color:
    ; Check for marker lines
    cmp ax, 190
    je .marker_192
    cmp ax, 191
    je .marker_192
    cmp ax, 198
    je .marker_200
    cmp ax, 199
    je .marker_200
    cmp ax, 202
    je .marker_204
    cmp ax, 203
    je .marker_204

    ; Normal color band: color_index = line / 13
    push cx
    mov bl, 13
    div bl                          ; AL = line / 13
    pop cx
    and al, 0x0F
    mov ah, al
    shl ah, 4
    or al, ah
    ret

.marker_192:
    mov al, 0xFF                    ; Color 15 (white) both nibbles
    ret

.marker_200:
    mov al, 0xCC                    ; Color 12 (bright red) both nibbles
    ret

.marker_204:
    mov al, 0xBB                    ; Color 11 (bright cyan) both nibbles
    ret


; ============================================================================
; Data
; ============================================================================

saved_mode      db 0                ; Original video mode
current_mode    db 1                ; Current line count mode (0-3)

; Register 0x65 values indexed by mode (0=192, 1=200, 2=204, 3=reserved)
reg65_table:
    db REG65_192, REG65_200, REG65_204, REG65_RESERVED

; Border colors indexed by mode
border_table:
    db BORDER_BLUE, BORDER_GREEN, BORDER_RED, BORDER_MAGENTA

; Palette data: 16 entries, each 2 bytes (R, GB)
palette_data:
    ; Entry 0: Black (0,0,0)
    db 0x00, 0x00
    ; Entry 1: Dark Blue (0,0,4)
    db 0x00, 0x04
    ; Entry 2: Dark Green (0,4,0)
    db 0x00, 0x20
    ; Entry 3: Dark Cyan (0,4,4)
    db 0x00, 0x24
    ; Entry 4: Dark Red (4,0,0)
    db 0x04, 0x00
    ; Entry 5: Dark Magenta (4,0,4)
    db 0x04, 0x04
    ; Entry 6: Brown/Dark Yellow (4,4,0)
    db 0x04, 0x20
    ; Entry 7: Light Gray (5,5,5)
    db 0x05, 0x2D
    ; Entry 8: Dark Gray (2,2,2)
    db 0x02, 0x12
    ; Entry 9: Bright Blue (0,0,7)
    db 0x00, 0x07
    ; Entry 10: Bright Green (0,7,0)
    db 0x00, 0x38
    ; Entry 11: Bright Cyan (0,7,7)
    db 0x00, 0x3F
    ; Entry 12: Bright Red (7,0,0)
    db 0x07, 0x00
    ; Entry 13: Bright Magenta (7,0,7)
    db 0x07, 0x07
    ; Entry 14: Bright Yellow (7,7,0)
    db 0x07, 0x38
    ; Entry 15: White (7,7,7)
    db 0x07, 0x3F
