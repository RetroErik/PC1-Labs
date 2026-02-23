; ============================================================================
; CRTC_RESTARTS_TEST.ASM - Test Reenigne's CRTC Restarts on V6355D
; Olivetti Prodest PC1 - V6355D 160x200x16 Hidden Graphics Mode
; Written for NASM - NEC V40 @ 8 MHz (80186 instruction set)
; By RetroErik - 2026
;
; ============================================================================
; HARDWARE TEST RESULT (tested on real Olivetti Prodest PC1, 2026):
;
;   *** CRTC RESTARTS DO NOT WORK ON THE V6355D ***
;
;   R4 (Vertical Total) and R6 (Vertical Displayed) are DUMMY REGISTERS.
;   Writing any value to them has zero effect — the V6355D always generates
;   a full 200-line (100 character rows) frame regardless of R4/R6 content.
;
;   Test A: Set R4=0x01, R6=0x01. Display remained unchanged (full 200
;           lines). Blue border confirmed the code ran. R4 and R6 are
;           confirmed non-functional.
;
;   Test B: Full micro-frame restarts loop. Display remained at full 200
;           lines — no micro-frames were created because R4=0x01 was
;           ignored. The polling loops ran but the V6355D never generated
;           the expected micro-frame boundaries.
;
;   Test C: Restarts + scrolling. R12/R13 changes DID take effect (visible
;           tearing/shifting), proving that word writes via `out dx, ax`
;           work correctly on the V6355D. But still no micro-frames — R4
;           remained ignored. The tearing proves R12/R13 work while R4
;           does not.
;
;   Press R: No visible effect (expected — R4 was never actually modified
;           by the V6355D, so writing 0x7F back changes nothing).
;
;   CONCLUSION: Reenigne's CRTC Restarts technique requires a real MC6845
;   where R4 controls frame height. The V6355D hardcodes vertical timing
;   in silicon. R4, R5, R6, and R7 are all likely dummy registers — only
;   R12/R13 (Start Address) and R9 (Max Scanline) are confirmed working.
;
;   These findings are consistent with Section 17g of the V6355D Technical
;   Reference: interlacing and vertical timing are hardwired at the pin
;   level, not register-controlled.
;
;   R4/R6 join R8 (Interlace Mode), R16 (Interlace Offset), and the Skew
;   registers in the confirmed dummy register list.
; ============================================================================
;
; PURPOSE:
;   Test whether the V6355D supports mid-frame R4 (Vertical Total) changes.
;   This is required for Reenigne's "CRTC Restarts" technique which would
;   solve the 384-byte gap problem for hardware scrolling.
;
; TECHNIQUE (from Reenigne's 8088 MPH / restarts1.asm):
;   Instead of one 200-line CRTC frame, create 100 tiny 2-line "micro-frames"
;   by setting R4=0x01 mid-frame. Each micro-frame gets its own R12/R13 start
;   address. Since each micro-frame reads only 80 bytes per bank, the CRTC
;   NEVER reads through the 192-byte gap at offset 8000.
;
; THREE TESTS (press key to activate):
;
;   '1' = TEST A: Static R4 reduction
;         Sets R4 from normal to 0x01 (2 rows/frame)
;         EXPECTED: display shrinks to ~2-4 scanlines at top, rest is black
;         ACTUAL: Full 200-line display unchanged. R4 IS DUMMY.
;
;   '2' = TEST B: Full CRTC Restarts loop
;         Sets R4=0x01 during display, updates R12/R13 per micro-frame
;         EXPECTED: colored bands display correctly (same as normal)
;         ACTUAL: Full 200-line display unchanged. No micro-frames created.
;         Press ESC during test to exit back to normal mode
;
;   '3' = TEST C: Restarts + animated scroll
;         Same as Test B but scrolls the start addresses each frame
;         EXPECTED: smooth vertical scroll WITHOUT gap artifacts
;         ACTUAL: Tearing visible (R12/R13 works), but R4 still ignored.
;         Press ESC during test to exit back to normal mode
;
;   'R' = Reset to normal display mode
;   ESC = Exit to DOS
;
; BUILD:
;   nasm -f bin -o crtctest.com crtc_restarts_test.asm
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
BANK_SIZE       equ 8192            ; 8KB per interlaced bank
ODD_BANK_OFFSET equ 0x2000          ; Odd scanlines start here

; V6355D Ports
PORT_REG_ADDR   equ 0x3DD           ; V6355D register select
PORT_REG_DATA   equ 0x3DE           ; V6355D register data
PORT_MODE       equ 0x3D8           ; CGA Mode Control
PORT_COLOR      equ 0x3D9           ; CGA Color Select
PORT_STATUS     equ 0x3DA           ; Status (bit 0=HSync, bit 3=VBlank)
PORT_CRTC_ADDR  equ 0x3D4           ; CRTC index port
PORT_CRTC_DATA  equ 0x3D5           ; CRTC data port

; CRTC Registers
CRTC_R0_HTOTAL        equ 0        ; Horizontal Total
CRTC_R1_HDISP         equ 1        ; Horizontal Displayed
CRTC_R2_HSYNC_POS     equ 2        ; Horizontal Sync Position
CRTC_R3_SYNC_WIDTH    equ 3        ; Sync Widths
CRTC_R4_VTOTAL        equ 4        ; Vertical Total (THE KEY REGISTER)
CRTC_R5_VTOTAL_ADJ    equ 5        ; Vertical Total Adjust
CRTC_R6_VDISP         equ 6        ; Vertical Displayed
CRTC_R7_VSYNC_POS     equ 7        ; Vertical Sync Position
CRTC_R8_INTERLACE     equ 8        ; Interlace Mode (dummy on V6355D)
CRTC_R9_MAX_SCANLINE  equ 9        ; Max Scanline Address
CRTC_R12_START_HI     equ 12       ; Start Address High
CRTC_R13_START_LO     equ 13       ; Start Address Low

; Number of micro-frames needed for 200 scanlines
; With R4=0x01 (2 rows per frame), each micro-frame = 2 scanlines
NUM_MICRO_FRAMES      equ 100

; Keyboard scancodes (port 0x60)
KEY_ESC         equ 0x01
KEY_1           equ 0x02
KEY_2           equ 0x03
KEY_3           equ 0x04
KEY_R           equ 0x13

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
    call fill_color_bands

    ; Store initial CRTC R4 value for restore
    ; (Read R4 — select reg 4 via index port, read from data port)
    ; Note: MC6845 registers are typically write-only, but try anyway
    mov byte [normal_r4], 0x7F      ; Assume standard CGA value

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
    cmp ah, KEY_R
    je .reset_crtc
    jmp .menu_loop

; ---- TEST A: Static R4 reduction ----
; Sets R4 to 0x01 (2 rows per frame). If R4 works, display shows only
; ~2-4 scanlines. If R4 is ignored, full 200-line display remains.
; RESULT: R4 and R6 are DUMMY — full 200-line display unchanged.
.test_a:
    ; Flash border blue to confirm key detected
    mov dx, PORT_COLOR
    mov al, 0x01                    ; Blue border
    out dx, al
    
    ; Set R4 = 0x01 (Vertical Total = 2 rows)
    mov dx, PORT_CRTC_ADDR
    mov ax, 0x0104                  ; R4 = 0x01
    out dx, ax

    ; Set R6 = 0x01 (1 row displayed)
    mov ax, 0x0106                  ; R6 = 0x01
    out dx, ax

    ; Wait a moment for user to see the result
    ; Then return to menu (user presses R to reset)
    jmp .menu_loop

; ---- Reset CRTC to normal ----
.reset_crtc:
    ; Restore normal CRTC values
    mov dx, PORT_CRTC_ADDR

    ; R4 = 0x7F (128 rows — standard CGA vertical total)
    mov ax, 0x7F04
    out dx, ax

    ; R5 = 0x06 (vertical adjust)
    mov ax, 0x0605
    out dx, ax

    ; R6 = 0x64 (100 rows displayed — 200 visible scanlines)
    mov ax, 0x6406
    out dx, ax

    ; R7 = 0x70 (vertical sync position = 112)
    mov ax, 0x7007
    out dx, ax

    ; R9 = 0x01 (2 scanlines per character row)
    mov ax, 0x0109
    out dx, ax

    ; R12/R13 = 0x0000 (start address = 0)
    mov ax, 0x000C
    out dx, ax
    mov ax, 0x000D
    out dx, ax

    ; Reset border to black
    mov dx, PORT_COLOR
    xor al, al
    out dx, al

    jmp .menu_loop

; ---- TEST B: Full CRTC Restarts (static display) ----
.test_b:
    ; Flash border green to confirm
    mov dx, PORT_COLOR
    mov al, 0x02
    out dx, al

    call run_restarts_static
    jmp .menu_loop

; ---- TEST C: Restarts + scrolling ----
.test_c:
    ; Flash border red to confirm
    mov dx, PORT_COLOR
    mov al, 0x04
    out dx, al

    call run_restarts_scroll
    jmp .menu_loop

; ---- Exit to DOS ----
.exit_program:
    ; Reset CRTC
    mov dx, PORT_CRTC_ADDR
    mov ax, 0x000C
    out dx, ax
    mov ax, 0x000D
    out dx, ax

    ; Restore video mode
    mov ah, 0x00
    mov al, [saved_mode]
    int 0x10

    mov ax, 0x4C00
    int 0x21


; ============================================================================
; run_restarts_static - Full CRTC restarts loop (no scrolling)
;
; Reconstructs the 200-line display using 100 micro-frames of 2 scanlines
; each. If the display looks identical to normal mode, restarts work!
;
; Based on Reenigne's restarts1.asm from 8088 MPH.
;
; RESULT: FAILED — R4=0x01 is ignored by V6355D, no micro-frames created.
; Display remained at full 200 lines. The polling loops ran but the V6355D
; never generated the expected 2-scanline frame boundaries.
; ============================================================================

run_restarts_static:
    cli                             ; Critical — no interrupts in inner loop!

    ; Program CRTC for restarts mode
    mov dx, PORT_CRTC_ADDR

    ; R4 = 0x3E (initial overscan frame: 63 rows for vsync generation)
    mov ax, 0x3E04
    out dx, ax

    ; R5 = 0x00 (no vertical adjust)
    mov ax, 0x0005
    out dx, ax

    ; R6 = 0x01 (only 1 row displayed per micro-frame)
    mov ax, 0x0106
    out dx, ax

    ; R7 = 0x0D (vertical sync position for overscan frame)
    mov ax, 0x0D07
    out dx, ax

    ; R9 = 0x01 (2 scanlines per character row)
    ;   Scanline 0 → even bank (address as-is)
    ;   Scanline 1 → odd bank (address + 0x2000, via V6355D hardware)
    mov ax, 0x0109
    out dx, ax

    ; R12/R13 = 0x0000 (initial start address)
    mov ax, 0x000C
    out dx, ax
    mov ax, 0x000D
    out dx, ax

    ; Set initial scroll offset = 0 (display line pair 0)
    xor cx, cx                      ; CX = line counter (high byte = index)
    mov si, 0x0200                  ; SI = increment per micro-frame (2 lines)
    xor bp, bp                      ; BP = initial offset

    ; ---- Frame loop ----
.frame_loop:
    mov dx, PORT_STATUS

    ; Wait for vsync start
.wait_vsync:
    in al, dx
    test al, 8                      ; Bit 3 = VBlank
    jz .wait_vsync

    ; Wait for vsync end
.wait_vsync_end:
    in al, dx
    test al, 8
    jnz .wait_vsync_end

    ; Check keyboard (port 0x60) for ESC during overscan
    in al, 0x60
    cmp al, KEY_ESC
    je .restarts_exit

    ; === Begin active display ===

    ; First micro-frame: lines 0-1 are already displaying (from overscan
    ; frame R12/R13). During these 2 scanlines, change R4 to micro-frame
    ; mode and set next start address.

    ; Wait for display active (bit 0 = 0)
.wait_de1:
    in al, dx
    test al, 1
    jnz .wait_de1

    ; Change R4 to micro-frame mode
    mov dl, 0xD4                    ; DX = PORT_CRTC_ADDR (0x3D4)
    mov ax, 0x0104                  ; R4 = 0x01 (2 rows per micro-frame)
    out dx, ax

    ; Set start address for micro-frame 1 (lines 2-3)
    ;   Word address = 1 * 40 = 40 = 0x0028
    mov ax, 0x000C                  ; R12 = high byte = 0x00
    out dx, ax
    mov ax, 0x280D                  ; R13 = low byte = 0x28
    out dx, ax

    mov dl, 0xDA                    ; DX = PORT_STATUS
    ; Wait for display disable (bit 0 = 1)
.wait_dd1:
    in al, dx
    test al, 1
    jz .wait_dd1

    ; === Micro-frames 1..98: update R12/R13 for each line pair ===
    ; Each iteration: wait for display enable, wait for disable,
    ; wait for enable again, set next start address, wait for disable.
    ;
    ; For simplicity in this test, we use a loop with computed addresses
    ; rather than the unrolled %rep of restarts1.asm.

    mov cx, 1                       ; Current line pair index (0 already done)

.micro_frame_loop:
    ; Wait for display active (start of this micro-frame's first scanline)
    mov dl, 0xDA
.wait_de_a:
    in al, dx
    test al, 1
    jnz .wait_de_a

    ; Wait for display disable (end of first scanline)
.wait_dd_a:
    in al, dx
    test al, 1
    jz .wait_dd_a

    ; Wait for display active (second scanline)
.wait_de_b:
    in al, dx
    test al, 1
    jnz .wait_de_b

    ; Now set R12/R13 for the NEXT micro-frame
    ; Word address = (cx+1) * 40
    mov ax, cx
    inc ax                          ; Next pair index
    push cx
    mov cx, 40
    mul cx                          ; AX = word address for next pair
    pop cx
    mov bx, ax                     ; BX = word address

    mov dl, 0xD4                    ; PORT_CRTC_ADDR
    mov al, CRTC_R12_START_HI
    mov ah, bh                      ; High byte of word address
    out dx, ax
    mov al, CRTC_R13_START_LO
    mov ah, bl                      ; Low byte of word address
    out dx, ax

    mov dl, 0xDA                    ; PORT_STATUS
    ; Wait for display disable
.wait_dd_b:
    in al, dx
    test al, 1
    jz .wait_dd_b

    inc cx
    cmp cx, 99                      ; Last micro-frame = pair 99
    jb .micro_frame_loop

    ; === Last micro-frame (pair 99): restore R4 for overscan ===

    ; Wait for display active
.wait_de_last:
    in al, dx
    test al, 1
    jnz .wait_de_last

    mov dl, 0xD4
    ; Restore R4 for overscan frame (large vertical total for vsync)
    mov ax, 0x3E04                  ; R4 = 0x3E (63 rows)
    out dx, ax

    ; Set R12/R13 back to 0 for first pair of next frame
    mov ax, 0x000C                  ; R12 = 0x00
    out dx, ax
    mov ax, 0x000D                  ; R13 = 0x00
    out dx, ax

    mov dl, 0xDA
    ; Wait for display disable
.wait_dd_last:
    in al, dx
    test al, 1
    jz .wait_dd_last

    ; Wait for second scanline of last pair
.wait_de_last2:
    in al, dx
    test al, 1
    jnz .wait_de_last2
.wait_dd_last2:
    in al, dx
    test al, 1
    jz .wait_dd_last2

    jmp .frame_loop

.restarts_exit:
    sti                             ; Re-enable interrupts

    ; Acknowledge keyboard
    in al, 0x61
    mov ah, al
    or al, 0x80
    out 0x61, al
    mov al, ah
    out 0x61, al
    mov al, 0x20
    out 0x20, al

    ; Restore normal CRTC
    mov dx, PORT_CRTC_ADDR
    mov ax, 0x7F04                  ; R4 = 0x7F
    out dx, ax
    mov ax, 0x0605                  ; R5 = 0x06
    out dx, ax
    mov ax, 0x6406                  ; R6 = 0x64
    out dx, ax
    mov ax, 0x7007                  ; R7 = 0x70
    out dx, ax
    mov ax, 0x0109                  ; R9 = 0x01
    out dx, ax
    mov ax, 0x000C                  ; R12 = 0
    out dx, ax
    mov ax, 0x000D                  ; R13 = 0
    out dx, ax

    ret


; ============================================================================
; run_restarts_scroll - CRTC restarts with animated scrolling
;
; Same as run_restarts_static but shifts start addresses each frame
; to produce smooth vertical scrolling. If this works without gap
; artifacts, the 384-byte gap problem is SOLVED.
;
; RESULT: FAILED — R4 ignored (no micro-frames). R12/R13 word writes via
; `out dx, ax` DID take effect (visible tearing), proving the I/O mechanism
; works. The 384-byte gap problem remains unsolved.
; ============================================================================

run_restarts_scroll:
    cli

    ; Program CRTC for restarts mode (same as static test)
    mov dx, PORT_CRTC_ADDR
    mov ax, 0x3E04                  ; R4 = 0x3E
    out dx, ax
    mov ax, 0x0005                  ; R5 = 0
    out dx, ax
    mov ax, 0x0106                  ; R6 = 1
    out dx, ax
    mov ax, 0x0D07                  ; R7 = 0x0D
    out dx, ax
    mov ax, 0x0109                  ; R9 = 0x01
    out dx, ax
    mov ax, 0x000C
    out dx, ax
    mov ax, 0x000D
    out dx, ax

    ; Scroll offset: which line pair to start from
    mov word [scroll_pair], 0       ; Start at pair 0

    ; ---- Scrolling frame loop ----
.scroll_frame:
    mov dx, PORT_STATUS

.sw_vsync:
    in al, dx
    test al, 8
    jz .sw_vsync
.sw_vsync_end:
    in al, dx
    test al, 8
    jnz .sw_vsync_end

    ; Check ESC
    in al, 0x60
    cmp al, KEY_ESC
    je .scroll_exit

    ; Advance scroll offset (1 pair per frame = 2 scanlines per frame)
    mov bx, [scroll_pair]
    inc bx
    cmp bx, LINES_PER_BANK         ; Wrap at 100 pairs
    jb .scroll_no_wrap
    xor bx, bx
.scroll_no_wrap:
    mov [scroll_pair], bx

    ; Calculate start address for first pair of this frame
    ; pair_index = scroll_pair, wrapping at 100
    ; word_address = pair_index * 40

    ; First micro-frame uses the overscan frame's R12/R13 (already set)
    ; Wait for display active
.sw_de1:
    in al, dx
    test al, 1
    jnz .sw_de1

    ; Set R4 = micro-frame mode
    mov dl, 0xD4
    mov ax, 0x0104
    out dx, ax

    ; Compute and set start address for next micro-frame
    mov bx, [scroll_pair]
    inc bx
    cmp bx, LINES_PER_BANK
    jb .sw_p1_ok
    xor bx, bx
.sw_p1_ok:
    push bx
    mov ax, bx
    mov cx, 40
    mul cx                          ; AX = word address
    mov bx, ax
    mov al, CRTC_R12_START_HI
    mov ah, bh
    out dx, ax
    mov al, CRTC_R13_START_LO
    mov ah, bl
    out dx, ax
    pop bx

    mov dl, 0xDA
.sw_dd1:
    in al, dx
    test al, 1
    jz .sw_dd1

    ; Micro-frames 1..98
    mov cx, 1
.sw_mf_loop:
    mov dl, 0xDA
.sw_mf_de_a:
    in al, dx
    test al, 1
    jnz .sw_mf_de_a
.sw_mf_dd_a:
    in al, dx
    test al, 1
    jz .sw_mf_dd_a
.sw_mf_de_b:
    in al, dx
    test al, 1
    jnz .sw_mf_de_b

    ; Compute next pair index with wrap
    push cx
    mov ax, [scroll_pair]
    add ax, cx
    inc ax                          ; +1 for "next"
.sw_wrap_check:
    cmp ax, LINES_PER_BANK
    jb .sw_wrap_ok
    sub ax, LINES_PER_BANK
    jmp .sw_wrap_check
.sw_wrap_ok:
    push cx
    mov cx, 40
    mul cx                          ; AX = word address
    pop cx
    mov bx, ax

    mov dl, 0xD4
    mov al, CRTC_R12_START_HI
    mov ah, bh
    out dx, ax
    mov al, CRTC_R13_START_LO
    mov ah, bl
    out dx, ax

    pop cx

    mov dl, 0xDA
.sw_mf_dd_b:
    in al, dx
    test al, 1
    jz .sw_mf_dd_b

    inc cx
    cmp cx, 99
    jb .sw_mf_loop

    ; Last micro-frame: restore R4 for overscan
    mov dl, 0xDA
.sw_de_last:
    in al, dx
    test al, 1
    jnz .sw_de_last

    mov dl, 0xD4
    mov ax, 0x3E04                  ; R4 = 0x3E
    out dx, ax

    ; Set R12/R13 for first pair of next frame
    mov ax, [scroll_pair]
    push cx
    mov cx, 40
    mul cx
    pop cx
    mov bx, ax
    mov al, CRTC_R12_START_HI
    mov ah, bh
    out dx, ax
    mov al, CRTC_R13_START_LO
    mov ah, bl
    out dx, ax

    mov dl, 0xDA
.sw_dd_last:
    in al, dx
    test al, 1
    jz .sw_dd_last
.sw_de_last2:
    in al, dx
    test al, 1
    jnz .sw_de_last2
.sw_dd_last2:
    in al, dx
    test al, 1
    jz .sw_dd_last2

    jmp .scroll_frame

.scroll_exit:
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

    ; Restore normal CRTC
    mov dx, PORT_CRTC_ADDR
    mov ax, 0x7F04
    out dx, ax
    mov ax, 0x0605
    out dx, ax
    mov ax, 0x6406
    out dx, ax
    mov ax, 0x7007
    out dx, ax
    mov ax, 0x0109
    out dx, ax
    mov ax, 0x000C
    out dx, ax
    mov ax, 0x000D
    out dx, ax

    ret


; ============================================================================
; enable_hidden_mode - Activate PC1 160x200x16 hidden graphics mode
; ============================================================================

enable_hidden_mode:
    push ax
    push dx

    ; Register 0x65 = monitor control (200 lines, PAL, CRT)
    mov dx, PORT_REG_ADDR
    mov al, 0x65
    out dx, al
    jmp short $+2
    mov dx, PORT_REG_DATA
    mov al, 0x09                    ; PAL, 200 lines, CRT
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

    ; Open palette write (select entry 0)
    mov dx, PORT_REG_ADDR
    mov al, 0x40                    ; Entry 0 command
    out dx, al
    jmp short $+2

    ; Write 16 entries (R, GB pairs)
    ; Format: R[2:0] in bits 2:0, then G[2:0] in bits 5:3 + B[2:0] in bits 2:0
    mov dx, PORT_REG_DATA

    ; Entry 0: Black (0,0,0)
    mov al, 0x00
    out dx, al
    jmp short $+2
    mov al, 0x00
    out dx, al
    jmp short $+2

    ; Entry 1: Dark Blue (0,0,4)
    mov al, 0x00
    out dx, al
    jmp short $+2
    mov al, 0x04
    out dx, al
    jmp short $+2

    ; Entry 2: Dark Green (0,4,0)
    mov al, 0x00
    out dx, al
    jmp short $+2
    mov al, 0x20
    out dx, al
    jmp short $+2

    ; Entry 3: Dark Cyan (0,4,4)
    mov al, 0x00
    out dx, al
    jmp short $+2
    mov al, 0x24
    out dx, al
    jmp short $+2

    ; Entry 4: Dark Red (4,0,0)
    mov al, 0x04
    out dx, al
    jmp short $+2
    mov al, 0x00
    out dx, al
    jmp short $+2

    ; Entry 5: Dark Magenta (4,0,4)
    mov al, 0x04
    out dx, al
    jmp short $+2
    mov al, 0x04
    out dx, al
    jmp short $+2

    ; Entry 6: Brown/Dark Yellow (4,4,0)
    mov al, 0x04
    out dx, al
    jmp short $+2
    mov al, 0x20
    out dx, al
    jmp short $+2

    ; Entry 7: Light Gray (5,5,5)
    mov al, 0x05
    out dx, al
    jmp short $+2
    mov al, 0x2D
    out dx, al
    jmp short $+2

    ; Entry 8: Dark Gray (2,2,2)
    mov al, 0x02
    out dx, al
    jmp short $+2
    mov al, 0x12
    out dx, al
    jmp short $+2

    ; Entry 9: Bright Blue (0,0,7)
    mov al, 0x00
    out dx, al
    jmp short $+2
    mov al, 0x07
    out dx, al
    jmp short $+2

    ; Entry 10: Bright Green (0,7,0)
    mov al, 0x00
    out dx, al
    jmp short $+2
    mov al, 0x38
    out dx, al
    jmp short $+2

    ; Entry 11: Bright Cyan (0,7,7)
    mov al, 0x00
    out dx, al
    jmp short $+2
    mov al, 0x3F
    out dx, al
    jmp short $+2

    ; Entry 12: Bright Red (7,0,0)
    mov al, 0x07
    out dx, al
    jmp short $+2
    mov al, 0x00
    out dx, al
    jmp short $+2

    ; Entry 13: Bright Magenta (7,0,7)
    mov al, 0x07
    out dx, al
    jmp short $+2
    mov al, 0x07
    out dx, al
    jmp short $+2

    ; Entry 14: Bright Yellow (7,7,0)
    mov al, 0x07
    out dx, al
    jmp short $+2
    mov al, 0x38
    out dx, al
    jmp short $+2

    ; Entry 15: White (7,7,7)
    mov al, 0x07
    out dx, al
    jmp short $+2
    mov al, 0x3F
    out dx, al
    jmp short $+2

    ; Close palette write
    mov dx, PORT_REG_ADDR
    mov al, 0x80
    out dx, al

    pop dx
    pop cx
    pop ax
    ret


; ============================================================================
; fill_color_bands - Fill VRAM with horizontal color bands
;
; Each color band is 12-13 lines tall (200 lines / 16 colors ≈ 12.5)
; Band uses a single nibble value repeated across the line.
; Even lines in bank 0 (0x0000), odd lines in bank 1 (0x2000).
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

    ; Fill even bank (lines 0, 2, 4, ... 198)
    xor di, di                      ; Start at 0x0000
    mov cx, LINES_PER_BANK          ; 100 even lines

.fill_even:
    ; Calculate color for this line
    ; line_number = (LINES_PER_BANK - cx) * 2
    ; color_index = line_number / 13 (approximate: 200/16 ≈ 12.5)
    mov ax, LINES_PER_BANK
    sub ax, cx                      ; AX = even line index (0..99)
    shl ax, 1                       ; AX = display line (0,2,4..198)
    push cx
    mov bl, 13
    div bl                          ; AL = color index (0..15)
    and al, 0x0F
    mov ah, al
    shl ah, 4
    or al, ah                       ; AL = color_nibble | (color_nibble << 4)
    ; Fill one line (80 bytes)
    mov cx, BYTES_PER_LINE
    rep stosb
    pop cx
    loop .fill_even

    ; Fill odd bank (lines 1, 3, 5, ... 199)
    mov di, ODD_BANK_OFFSET         ; Start at 0x2000
    mov cx, LINES_PER_BANK          ; 100 odd lines

.fill_odd:
    mov ax, LINES_PER_BANK
    sub ax, cx
    shl ax, 1
    inc ax                          ; AX = display line (1,3,5..199)
    push cx
    mov bl, 13
    div bl
    and al, 0x0F
    mov ah, al
    shl ah, 4
    or al, ah
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
; Data
; ============================================================================

saved_mode      db 0                ; Original video mode
normal_r4       db 0x7F             ; Normal R4 value to restore
scroll_pair     dw 0                ; Current scroll offset (pair index)
