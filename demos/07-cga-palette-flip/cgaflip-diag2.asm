; ============================================================================
; CGAFLIP-DIAG2.ASM — Active-Entry Passthrough Test During Visible Area
; ============================================================================
;
; Diagnostic tool — proved active-entry passthrough (write same value) is safe.
;   This finding enabled cgaflip9's full E2-E7 streaming without VRAM rotation.
;
; PURPOSE: Can we stream through ACTIVE palette entries (writing the
; same value = passthrough) during the visible area to update INACTIVE
; entries beyond them?
;
; BACKGROUND:
;   cgaflip-diag proved: writing to INACTIVE entries during visible area
;   does NOT disrupt active entries. But the V6355D requires sequential
;   streaming — to reach E5/E7, we must stream through E2/E4/E6 first.
;   On even lines (pal 0), E2/E4/E6 are actively displayed.
;
;   This test writes the SAME VALUE to active entries (passthrough) while
;   changing inactive entries to new colors. If the V6355D's DAC glitches
;   during the latch, we'll see pixel artifacts on even lines.
;
; SCREEN: 3 columns (pixel 1 / pixel 2 / pixel 3)
;   Even lines (pal 0): Col1=E2(Red) Col2=E4(Green) Col3=E6(Blue)
;   Odd lines  (pal 1): Col1=E3(DkR) Col2=E5(DkGrn) Col3=E7(DkBlu)
;
; SPACE toggles test ON/OFF:
;
;   OFF (reference):
;     No visible-area writes. Clean interlaced display:
;     Even = Red / Green / Blue
;     Odd  = Dark Red / Dark Green / Dark Blue
;
;   ON (passthrough test):
;     During even VISIBLE AREA (after delay past HBLANK):
;     Stream E2-E7: E2=Red(same!) E3=Yellow(new!) E4=Green(same!)
;                   E5=Cyan(new!) E6=Blue(same!) E7=White(new!)
;     Expected if passthrough is SAFE:
;       Even = Red / Green / Blue (unchanged — passthrough worked!)
;       Odd  = Yellow / Cyan / White (inactive entries updated!)
;     If passthrough FAILS:
;       Even lines show glitching/wrong colors during write
;
; WHAT SUCCESS MEANS:
;   If this test passes, cgaflip9 can update ALL 3 columns on EVERY
;   scanline via visible-area writes. HBLANK is just 1 OUT (flip).
;   Result: 200 unique scanlines × 3 columns = 600 color instances,
;   limited only by the RGB333 palette's 512 possible colors.
;
; ESC: Exit to DOS
;
; Target: Olivetti Prodest PC1 with Yamaha V6355D
; CPU: NEC V40 (80186 compatible) @ 8 MHz
; ============================================================================

[BITS 16]
[ORG 0x100]

PORT_D9     equ 0xD9
PORT_DA     equ 0xDA
PORT_DD     equ 0xDD
PORT_DE     equ 0xDE

PAL_EVEN    equ 0x00
PAL_ODD     equ 0x20
OPEN_E2     equ 0x44
CLOSE_PAL   equ 0x80

; === Active entry values (even/pal0 — these are displayed) ===
; Must match exactly for passthrough to be "same value"
E2_R        equ 7           ; Red: R7
E2_GB       equ 0x00        ;      G0,B0
E4_R        equ 0           ; Green: R0
E4_GB       equ 0x70        ;        G7,B0
E6_R        equ 0           ; Blue: R0
E6_GB       equ 0x07        ;       G0,B7

; === New inactive values (odd/pal1 — written during even visible) ===
E3_NEW_R    equ 7           ; Yellow: R7
E3_NEW_GB   equ 0x70        ;         G7,B0
E5_NEW_R    equ 0           ; Cyan: R0
E5_NEW_GB   equ 0x77        ;       G7,B7
E7_NEW_R    equ 7           ; White: R7
E7_NEW_GB   equ 0x77        ;        G7,B7

; === Original inactive values (for reference mode) ===
E3_ORIG_R   equ 3           ; Dark Red: R3
E3_ORIG_GB  equ 0x00        ;           G0,B0
E5_ORIG_R   equ 0           ; Dark Green: R0
E5_ORIG_GB  equ 0x30        ;             G3,B0
E7_ORIG_R   equ 0           ; Dark Blue: R0
E7_ORIG_GB  equ 0x03        ;            G0,B3

; ============================================================================
; MAIN
; ============================================================================

main:
    mov ax, 4
    int 0x10

    ; Fill screen: 3 columns, no rotation
    push es
    mov ax, 0xB800
    mov es, ax
    cld

    ; Bank 0 (even rows)
    xor di, di
    mov cx, 100
    call fill_bank

    ; Bank 1 (odd rows)
    mov di, 0x2000
    mov cx, 100
    call fill_bank
    pop es

    ; Set initial palette
    call init_palette

    mov byte [test_on], 0

; === Main loop ===
.main_loop:
    ; Wait VBLANK
.wait_not_vb:
    in al, PORT_DA
    test al, 0x08
    jnz .wait_not_vb
.wait_vb:
    in al, PORT_DA
    test al, 0x08
    jz .wait_vb

    call render_frame

    ; Check keyboard
    mov ah, 0x01
    int 0x16
    jz .main_loop

    mov ah, 0x00
    int 0x16

    cmp al, 0x1B            ; ESC
    je .exit
    cmp al, 0x20            ; Space
    jne .main_loop

    ; Toggle test mode
    xor byte [test_on], 1

    ; When turning OFF, restore original palette during VBLANK
    cmp byte [test_on], 0
    jne .main_loop

    ; Wait for VBLANK to restore cleanly
.wait_not_vb2:
    in al, PORT_DA
    test al, 0x08
    jnz .wait_not_vb2
.wait_vb2:
    in al, PORT_DA
    test al, 0x08
    jz .wait_vb2

    call init_palette
    jmp .main_loop

.exit:
    mov ax, 3
    int 0x10
    mov ax, 0x4C00
    int 0x21

; ============================================================================
; fill_bank — Fill CGA bank with 3-column pattern
; ============================================================================
; Col1(pix1)=27 bytes, Col2(pix2)=26 bytes, Col3(pix3)=27 bytes
; ============================================================================

fill_bank:
.row:
    push cx
    mov al, 0x55            ; pixel 1 → E2/E3
    mov cx, 27
    rep stosb
    mov al, 0xAA            ; pixel 2 → E4/E5
    mov cx, 26
    rep stosb
    mov al, 0xFF            ; pixel 3 → E6/E7
    mov cx, 27
    rep stosb
    pop cx
    loop .row
    ret

; ============================================================================
; init_palette — Set E2-E7 with reference colors
; ============================================================================

init_palette:
    mov al, OPEN_E2
    out PORT_DD, al
    jmp short $+2

    mov al, E2_R                ; E2: Red
    out PORT_DE, al
    jmp short $+2
    mov al, E2_GB
    out PORT_DE, al
    jmp short $+2

    mov al, E3_ORIG_R           ; E3: Dark Red
    out PORT_DE, al
    jmp short $+2
    mov al, E3_ORIG_GB
    out PORT_DE, al
    jmp short $+2

    mov al, E4_R                ; E4: Green
    out PORT_DE, al
    jmp short $+2
    mov al, E4_GB
    out PORT_DE, al
    jmp short $+2

    mov al, E5_ORIG_R           ; E5: Dark Green
    out PORT_DE, al
    jmp short $+2
    mov al, E5_ORIG_GB
    out PORT_DE, al
    jmp short $+2

    mov al, E6_R                ; E6: Blue
    out PORT_DE, al
    jmp short $+2
    mov al, E6_GB
    out PORT_DE, al
    jmp short $+2

    mov al, E7_ORIG_R           ; E7: Dark Blue
    out PORT_DE, al
    jmp short $+2
    mov al, E7_ORIG_GB
    out PORT_DE, al
    jmp short $+2

    mov al, CLOSE_PAL
    out PORT_DD, al
    ret

; ============================================================================
; render_frame — Per-scanline flip + visible-area passthrough test
; ============================================================================
; Even lines: flip to pal 0, then (if test ON) write E2-E7 during
;             visible area with active entries = same value.
; Odd lines:  flip to pal 1 only.
;
; A delay loop after the flip ensures writes happen DURING visible
; area, not in leftover HBLANK time. This guarantees we're writing
; to actively-displayed entries, making the test conclusive.
; ============================================================================

render_frame:
    cli
    mov cx, 200
    mov bl, PAL_EVEN

.next_line:
    test cl, 1
    jnz .odd_path

    ; === EVEN LINE ===
.wait_lo_e:
    in al, PORT_DA
    test al, 0x01
    jnz .wait_lo_e
.wait_hi_e:
    in al, PORT_DA
    test al, 0x01
    jz .wait_hi_e

    ; HBLANK: flip to pal 0
    mov al, bl
    out PORT_D9, al

    ; Test enabled?
    cmp byte [test_on], 0
    je .even_done

    ; --- Delay to push writes into VISIBLE AREA ---
    ; ~80 cycles from HBLANK start (we're ~15 cycles in after flip+branch)
    ; Need ~65 more cycles to exit HBLANK
    ; 10 iterations × ~7 cycles = ~70 cycles delay
    push cx
    mov cx, 10
.vis_delay:
    loop .vis_delay
    pop cx

    ; === VISIBLE AREA: Stream E2-E7 ===
    ; Active entries (E2/E4/E6) get SAME value = passthrough
    ; Inactive entries (E3/E5/E7) get NEW colors

    mov al, OPEN_E2
    out PORT_DD, al

    ; E2: Red PASSTHROUGH (R7,G0,B0) — ACTIVE, same value!
    mov al, E2_R
    out PORT_DE, al
    mov al, E2_GB
    out PORT_DE, al

    ; E3: Yellow NEW (R7,G7,B0) — INACTIVE, safe to change!
    mov al, E3_NEW_R
    out PORT_DE, al
    mov al, E3_NEW_GB
    out PORT_DE, al

    ; E4: Green PASSTHROUGH (R0,G7,B0) — ACTIVE, same value!
    mov al, E4_R
    out PORT_DE, al
    mov al, E4_GB
    out PORT_DE, al

    ; E5: Cyan NEW (R0,G7,B7) — INACTIVE, safe to change!
    mov al, E5_NEW_R
    out PORT_DE, al
    mov al, E5_NEW_GB
    out PORT_DE, al

    ; E6: Blue PASSTHROUGH (R0,G0,B7) — ACTIVE, same value!
    mov al, E6_R
    out PORT_DE, al
    mov al, E6_GB
    out PORT_DE, al

    ; E7: White NEW (R7,G7,B7) — INACTIVE, safe to change!
    mov al, E7_NEW_R
    out PORT_DE, al
    mov al, E7_NEW_GB
    out PORT_DE, al

    mov al, CLOSE_PAL
    out PORT_DD, al

.even_done:
    xor bl, PAL_ODD
    loop .next_line
    jmp short .done

    ; === ODD LINE ===
.odd_path:
.wait_lo_o:
    in al, PORT_DA
    test al, 0x01
    jnz .wait_lo_o
.wait_hi_o:
    in al, PORT_DA
    test al, 0x01
    jz .wait_hi_o

    ; HBLANK: flip to pal 1 only
    mov al, bl
    out PORT_D9, al

    xor bl, PAL_ODD
    loop .next_line

.done:
    mov al, PAL_EVEN
    out PORT_D9, al
    sti
    ret

; ============================================================================
; DATA
; ============================================================================

test_on:    db 0
