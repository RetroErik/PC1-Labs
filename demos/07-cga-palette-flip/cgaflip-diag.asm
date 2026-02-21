; ============================================================================
; CGAFLIP-DIAG.ASM — Diagnostic: Can we write INACTIVE entries during visible?
; ============================================================================
;
; Diagnostic tool — proved inactive-entry writes during visible area are safe.
;   This finding enabled cgaflip8 (E3 during HBLANK) and cgaflip9 (E2-E7 passthrough).
;
; TEST HYPOTHESIS:
;   Writing to inactive palette entries during the visible area does NOT
;   cause visual artifacts on the V6355D, because the DAC is only reading
;   the active palette's entries.
;
; SETUP:
;   - CGA mode 4 (320×200×4)
;   - Screen filled with pixel value 1 (shows E2 or E3 depending on pal)
;   - E2 = bright RED (R7,G0,B0)
;   - E3 = bright BLUE (R0,G0,B7)
;   - Palette flips every scanline (even=pal0, odd=pal1)
;
; TEST:
;   On ODD lines (pal 1 active → E3=blue displayed, E2 is INACTIVE):
;     After HBLANK flip, wait ~50 cycles into visible area, then:
;     Open 0x44, write GREEN to E2, close 0x80
;
;   On EVEN lines (pal 0 active → E2 displayed):
;     At HBLANK: flip only. E2 should show GREEN (written previous line).
;     During visible: write RED back to E2 for the next even line to show.
;     (Actually, we alternate: odd writes GREEN, even just flips.)
;
; EXPECTED RESULTS:
;
;   SUCCESS (inactive writes are safe):
;     Even lines: E2 = GREEN (stable, no glitches)
;     Odd lines:  E3 = BLUE (stable, no glitches)
;     Screen = alternating GREEN/BLUE horizontal stripes
;
;   FAILURE (protocol disrupts DAC regardless):
;     Odd lines show visual noise/flicker on the BLUE stripes
;     (because open/stream/close disrupts DAC even for inactive entries)
;
; CONTROLS:
;   ESC    : Exit
;   SPACE  : Toggle test ON/OFF (compare with/without visible-area writes)
;   1      : Write during visible area (default test)
;   2      : Write GREEN at HBLANK instead (control: proves green works)
;   3      : Write RED to E2 always (control: proves setup works)
;
; Written for NASM assembler
; Target: Olivetti Prodest PC1 with Yamaha V6355D
; CPU: NEC V40 @ 8 MHz
;
; By Retro Erik - 2026
;
; ============================================================================

[BITS 16]
[ORG 0x100]

PORT_D9     equ 0xD9
PORT_DA     equ 0xDA
PORT_DD     equ 0xDD
PORT_DE     equ 0xDE

VIDEO_SEG   equ 0xB800
OPEN_E2     equ 0x44
CLOSE_PAL   equ 0x80
PAL_EVEN    equ 0x00
PAL_ODD     equ 0x20
SCREEN_H    equ 200

; ============================================================================
; MAIN
; ============================================================================

main:
    mov byte [test_mode], 1     ; 1=visible-area, 2=hblank, 3=red-only
    mov byte [test_on], 1

    ; Set mode 4
    mov ax, 0x0004
    int 0x10

    ; Fill screen with pixel value 1 (0x55)
    mov ax, VIDEO_SEG
    mov es, ax
    xor di, di
    mov cx, 8192                ; 16KB / 2
    mov ax, 0x5555
    rep stosw

    ; Program initial palette: E2=RED, E3=BLUE
    call wait_vblank
    call program_initial

.main_loop:
    call wait_vblank
    call render_frame
    call check_keys

    cmp al, 0xFF
    jne .main_loop

    ; Exit
    mov ax, 0x0003
    int 0x10
    mov ax, 0x4C00
    int 0x21

; ============================================================================
; program_initial — Set E2=RED, E3=BLUE during VBLANK
; ============================================================================

program_initial:
    cli
    mov al, OPEN_E2
    out PORT_DD, al
    jmp short $+2

    ; E2: RED = R7, G0|B0
    mov al, 7
    out PORT_DE, al
    jmp short $+2
    mov al, 0x00
    out PORT_DE, al
    jmp short $+2

    ; E3: BLUE = R0, G0|B7
    mov al, 0
    out PORT_DE, al
    jmp short $+2
    mov al, 0x07
    out PORT_DE, al
    jmp short $+2

    mov al, CLOSE_PAL
    out PORT_DD, al
    sti
    ret

; ============================================================================
; write_e2_green — Open 0x44, write GREEN (R0,G7,B0) to E2, close
; ============================================================================

write_e2_green:
    mov al, OPEN_E2
    out PORT_DD, al
    mov al, 0                   ; R = 0
    out PORT_DE, al
    mov al, 0x70                ; G=7, B=0
    out PORT_DE, al
    mov al, CLOSE_PAL
    out PORT_DD, al
    ret

; ============================================================================
; write_e2_red — Open 0x44, write RED (R7,G0,B0) to E2, close
; ============================================================================

write_e2_red:
    mov al, OPEN_E2
    out PORT_DD, al
    mov al, 7                   ; R = 7
    out PORT_DE, al
    mov al, 0x00                ; G=0, B=0
    out PORT_DE, al
    mov al, CLOSE_PAL
    out PORT_DD, al
    ret

; ============================================================================
; render_frame — 200 scanlines with per-line palette flip + test writes
; ============================================================================

render_frame:
    cli
    mov cx, SCREEN_H
    mov bl, PAL_EVEN

.next_line:
    ; Wait for HSYNC: low → high
.wait_low:
    in al, PORT_DA
    test al, 0x01
    jnz .wait_low
.wait_high:
    in al, PORT_DA
    test al, 0x01
    jz .wait_high

    ; === HBLANK: flip palette ===
    mov al, bl
    out PORT_D9, al
    ; Toggle for next line
    xor bl, PAL_ODD

    ; Is test enabled?
    cmp byte [test_on], 0
    je .skip_all

    ; Branch by test mode
    cmp byte [test_mode], 3
    je .mode3
    cmp byte [test_mode], 2
    je .mode2

    ; --- Mode 1: Write GREEN to E2 during VISIBLE AREA of ODD lines ---
    ; Odd line = we just flipped to PAL_ODD (bl is now PAL_EVEN after xor)
    ; Check: did we just output PAL_ODD? bl after xor = PAL_EVEN means yes.
    cmp bl, PAL_EVEN
    jne .skip_all               ; even line, skip

    ; We're now in the visible area of an odd line (pal 1 active).
    ; E2 is INACTIVE. Let's write to it.
    ; Add some delay to ensure we're well past HBLANK into visible area.
    push cx
    mov cx, 10
.vis_delay:
    loop .vis_delay
    pop cx

    ; Write GREEN to E2 during visible area
    call write_e2_green
    jmp short .skip_all

    ; --- Mode 2: Write GREEN to E2 at HBLANK (control test) ---
.mode2:
    ; Only on odd lines
    cmp bl, PAL_EVEN
    jne .skip_all
    ; We're still in HBLANK (just did the flip). Write immediately.
    call write_e2_green
    jmp short .skip_all

    ; --- Mode 3: Write RED to E2 at HBLANK always (baseline) ---
.mode3:
    cmp bl, PAL_EVEN
    jne .skip_all
    call write_e2_red

.skip_all:
    loop .next_line

    ; Reset palette
    mov al, PAL_EVEN
    out PORT_D9, al
    sti
    ret

; ============================================================================
; wait_vblank
; ============================================================================

wait_vblank:
.wait_not:
    in al, PORT_DA
    test al, 0x08
    jnz .wait_not
.wait_yes:
    in al, PORT_DA
    test al, 0x08
    jz .wait_yes
    ret

; ============================================================================
; check_keys — Returns AL: 0xFF=ESC, 0=none
; ============================================================================

check_keys:
    mov ah, 0x01
    int 0x16
    jz .no_key

    mov ah, 0x00
    int 0x16

    cmp al, 0x1B               ; ESC
    je .esc
    cmp al, 0x20               ; SPACE
    je .space
    cmp al, '1'
    je .key1
    cmp al, '2'
    je .key2
    cmp al, '3'
    je .key3
    xor al, al
    ret

.esc:
    mov al, 0xFF
    ret
.space:
    xor byte [test_on], 1
    ; When turning test off, restore E2=RED
    cmp byte [test_on], 0
    jne .space_done
    call wait_vblank
    call program_initial
.space_done:
    xor al, al
    ret
.key1:
    mov byte [test_mode], 1
    xor al, al
    ret
.key2:
    mov byte [test_mode], 2
    xor al, al
    ret
.key3:
    mov byte [test_mode], 3
    call wait_vblank
    call program_initial
    xor al, al
    ret
.no_key:
    xor al, al
    ret

; ============================================================================
; DATA
; ============================================================================

test_mode:  db 1                ; 1=visible-area, 2=hblank-green, 3=red-only
test_on:    db 1                ; 0=off, 1=on
