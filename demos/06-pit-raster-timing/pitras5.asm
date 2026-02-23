; ============================================================================
; PITRAS5.asm — HSYNC-Synced Cycle-Counted Split with Deferred Palette
; ============================================================================
;
; PURPOSE:
;   The most precise possible mid-scanline color split on the PC1.
;   Combines the BEST techniques from cgaflip9 and pitras3/4:
;     - HSYNC sync for scanline alignment (proven in cgaflip series)
;     - Cycle-counted delay for split position (no ISR overhead)
;     - Deferred palette open: write only DATA bytes mid-scanline
;       (avoids the 0xDD address write that disrupts V6355D output)
;     - Whole frame under CLI for deterministic timing
;
; KEY INSIGHT FROM CGAFLIP EXPERIMENTS:
;   Writing to port 0xDD (palette address / open / close) during the
;   visible area disrupts V6355D output (flickering). But writing DATA
;   to port 0xDE (palette data) to an ALREADY-OPEN palette session is
;   safe — the data goes into the palette RAM without disrupting video.
;
;   So: we OPEN the palette write session during HBLANK (safe), then
;   write the two DATA bytes mid-scanline via 0xDE only. This avoids
;   the 0xDD address write mid-scanline entirely.
;
; SPLIT APPROACH:
;   During HBLANK:
;     - Open palette at entry 0 (0x40 → 0xDD)     ← HBLANK, safe
;     - Write Color A: R_byte → 0xDE, GB_byte → 0xDE
;     - Close palette (0x80 → 0xDD)                ← still HBLANK
;   After entering visible area:
;     - Cycle-counted delay to reach target pixel
;     - Open palette at entry 0 (0x40 → 0xDD)     ← MAY cause tiny glitch
;     - Write Color B: R_byte → 0xDE, GB_byte → 0xDE
;     - Close palette (0x80 → 0xDD)
;   After scanline:
;     - Pad to fill exactly 509 cycles
;
; ALTERNATIVE (deferred-open variant, use mode D):
;   During HBLANK:
;     - Open palette at entry 0 (0x40 → 0xDD)
;     - Write Color A: R, GB   (entry 0 done, auto-increments to entry 1)
;     - Write dummy: R, GB     (entry 1 = unused padding)
;     - Write dummy: R, GB     (entry 2 padding... keeps session open)
;     (leave session OPEN — no close)
;
;   This doesn't work cleanly for re-targeting entry 0 because the V6355D
;   auto-increments. So we must re-open at 0x40 mid-scanline.
;
;   HOWEVER: We can minimize the mid-scanline 0xDD access to just ONE
;   byte (the OPEN command), immediately followed by 2 data bytes.
;   3 OUTs mid-scanline vs 5 OUTs. Less disruption window.
;
; CONTROLS:
;   Right/Left : Adjust split delay ±1
;   +/-        : Adjust split delay ±10
;   Up/Down    : Adjust pad ±1
;   M          : Cycle through test modes:
;                  A = Blue/Red (max contrast)
;                  B = Black/White
;                  C = Gradient (each scanline different)
;   ESC        : Exit
;
; Written for NASM assembler
; Target: Olivetti Prodest PC1 with Yamaha V6355D
; CPU: NEC V40 (80186 compatible) @ 8 MHz
;
; By Retro Erik - 2026
; ============================================================================

[BITS 16]
[ORG 0x100]

; --- Hardware Ports ---
PORT_MODE       equ 0xD8
PORT_STATUS     equ 0x3DA
PORT_PAL_ADDR   equ 0xDD        ; Palette address / open / close
PORT_PAL_DATA   equ 0xDE        ; Palette data (R, then G<<4|B)

; --- Constants ---
VIDEO_SEG       equ 0xB000
SCREEN_HEIGHT   equ 200

; ============================================================================
; MAIN PROGRAM
; ============================================================================
main:
    ; Turn off floppy motor
    mov dx, 0x3F2
    mov al, 0x0C
    out dx, al

    ; Set video mode
    mov ax, 0x0004
    int 0x10
    mov al, 0x4A
    out PORT_MODE, al

    ; Clear screen
    call clear_screen

    ; Initialize
    mov byte [split_delay], 30      ; starting delay
    mov byte [pad_nops], 100        ; pad to fill scanline
    mov byte [test_mode], 0         ; mode A = Blue/Red

    ; ===== MAIN LOOP =====
.main_loop:
    call render_frame
    call check_keyboard
    cmp al, 0xFF
    jne .main_loop

    ; === EXIT ===
    mov al, 0x40
    out PORT_PAL_ADDR, al
    xor al, al
    out PORT_PAL_DATA, al
    out PORT_PAL_DATA, al
    mov al, 0x80
    out PORT_PAL_ADDR, al

    mov ax, 0x0003
    int 0x10
    mov ax, 0x4C00
    int 0x21

; ============================================================================
; render_frame — HSYNC-relative cycle-counted mid-scanline split
; ============================================================================
;
; Per scanline (executed under CLI for entire frame):
;
;   [wait HSYNC HIGH]
;   [write Color A to entry 0 during HBLANK: open + 2 data + close]
;   [cycle-counted delay to target pixel]
;   [write Color B to entry 0: open + 2 data + close]
;   [pad NOPs to fill scanline]
;
; Approximate cycle budget:
;   HSYNC wait:     ~20 cycles (average polling loop)
;   Color A write:  open(11) + R(11) + GB(11) + close(11) = ~44 cycles
;   Delay loop:     ~14 × split_delay cycles
;   Color B write:  open(11) + R(11) + GB(11) + close(11) = ~44 cycles
;   Pad loop:       ~14 × pad_nops cycles
;   Loop overhead:  ~10 cycles
;   TOTAL:          ~118 + 14 × (split_delay + pad_nops)
;   Target 509:     14 × (split + pad) ≈ 391 → split + pad ≈ 28
;
; NOTE: The 0xDD open/close mid-scanline MAY cause a brief V6355D glitch.
; This experiment determines if that glitch is visible or acceptable.
; If not, the alternative is to never close (leave session open) and
; accept that entry 0 can only be re-written after wrapping through
; all 8 entries.
;
; ============================================================================
render_frame:
    push ax
    push bx
    push cx
    push dx
    push si
    push bp

    ; --- Wait for VBLANK ---
    mov dx, PORT_STATUS
.wvb_end:
    in al, dx
    test al, 0x08
    jnz .wvb_end
.wvb_start:
    in al, dx
    test al, 0x08
    jz .wvb_start

    cli                         ; === INTERRUPTS OFF ===

    ; Load parameters
    ; (V40 is 80186 — no movzx! Use xor+mov instead)
    xor bx, bx
    mov bl, [split_delay]
    mov bp, bx                      ; BP = split delay count
    xor bx, bx
    mov bl, [pad_nops]
    mov si, bx                      ; SI = pad count
    mov cx, SCREEN_HEIGHT
    mov dx, PORT_STATUS

    ; Pre-load color values based on mode
    ; BL = Color A (R byte)
    ; BH = Color A (GB byte)
    ; We'll use fixed Color B in registers too
    cmp byte [test_mode], 1
    je .mode_bw
    cmp byte [test_mode], 2
    je .mode_grad

    ; Mode A: Blue left, Red right
    mov byte [color_a_r], 0         ; Blue: R=0
    mov byte [color_a_gb], 0x07     ; Blue: G=0, B=7
    mov byte [color_b_r], 7         ; Red: R=7
    mov byte [color_b_gb], 0x00     ; Red: G=0, B=0
    jmp .start_render

.mode_bw:
    ; Mode B: Black left, White right
    mov byte [color_a_r], 0
    mov byte [color_a_gb], 0x00
    mov byte [color_b_r], 7
    mov byte [color_b_gb], 0x77
    jmp .start_render

.mode_grad:
    ; Mode C: Gradient — colors set per-scanline inside loop
    mov byte [color_a_r], 0
    mov byte [color_a_gb], 0x07
    mov byte [color_b_r], 7
    mov byte [color_b_gb], 0x00

.start_render:
    ; ===================================================================
    ; SCANLINE LOOP
    ; ===================================================================
.scanline_loop:
    ; ------------------------------------------------------------------
    ; STEP 1: Wait for HSYNC → HIGH (entering HBLANK)
    ; ------------------------------------------------------------------
.wait_low:
    in al, dx               ; ~8 cycles
    test al, 0x01            ; ~1 cycle
    jnz .wait_low            ; ~4 cycles if taken
.wait_high:
    in al, dx               ; ~8 cycles
    test al, 0x01            ; ~1 cycle
    jz .wait_high            ; ~4 cycles if taken

    ; ------------------------------------------------------------------
    ; STEP 2: Write Color A to entry 0 DURING HBLANK
    ; ------------------------------------------------------------------
    ; This is safe — HBLANK, no beam scanning
    mov al, 0x40             ; Open palette at entry 0
    out PORT_PAL_ADDR, al    ;                              ~11 cyc
    mov al, [color_a_r]      ; R byte                       ~3 cyc
    out PORT_PAL_DATA, al    ;                              ~11 cyc
    mov al, [color_a_gb]     ; GB byte                      ~3 cyc
    out PORT_PAL_DATA, al    ;                              ~11 cyc
    mov al, 0x80             ; Close palette
    out PORT_PAL_ADDR, al    ;                              ~11 cyc
                             ; SUBTOTAL: ~50 cycles (safe in HBLANK)

    ; ------------------------------------------------------------------
    ; STEP 3: Cycle-counted delay to target pixel
    ; ------------------------------------------------------------------
    ; Each iteration: 3 NOPs (9 cyc) + LOOP (5 cyc) = ~14 cycles
    push cx
    mov cx, bp               ; CX = split_delay
    jcxz .skip_delay
.delay_loop:
    nop
    nop
    nop
    loop .delay_loop
.skip_delay:
    pop cx

    ; ------------------------------------------------------------------
    ; STEP 4: Write Color B to entry 0 — MID-SCANLINE
    ; ------------------------------------------------------------------
    ; The 0xDD open/close writes happen in the visible area.
    ; This is the minimum possible: 5 OUTs.
    ; If this causes flicker, we need an alternative approach.
    mov al, 0x40             ; Open palette at entry 0
    out PORT_PAL_ADDR, al    ;                              ~11 cyc
    mov al, [color_b_r]      ; R byte                       ~3 cyc
    out PORT_PAL_DATA, al    ;                              ~11 cyc
    mov al, [color_b_gb]     ; GB byte                      ~3 cyc
    out PORT_PAL_DATA, al    ;                              ~11 cyc
    mov al, 0x80             ; Close palette
    out PORT_PAL_ADDR, al    ;                              ~11 cyc
                             ; SUBTOTAL: ~50 cycles

    ; ------------------------------------------------------------------
    ; STEP 5: Pad to fill scanline
    ; ------------------------------------------------------------------
    push cx
    mov cx, si
    jcxz .skip_pad
.pad_loop:
    nop
    nop
    nop
    loop .pad_loop
.skip_pad:
    pop cx

    ; ------------------------------------------------------------------
    ; STEP 6: Next scanline
    ; ------------------------------------------------------------------
    dec cx
    jnz .scanline_loop

    sti                     ; === INTERRUPTS BACK ON ===

    pop bp
    pop si
    pop dx
    pop cx
    pop bx
    pop ax
    ret

; ============================================================================
; check_keyboard
; ============================================================================
check_keyboard:
    push bx

    mov ah, 0x01
    int 0x16
    jz .no_key

    mov ah, 0x00
    int 0x16

    ; ESC
    cmp ah, 0x01
    jne .not_esc
    mov al, 0xFF
    jmp .done

.not_esc:
    ; Right arrow: delay +1
    cmp ah, 0x4D
    jne .not_right
    cmp byte [split_delay], 200
    jae .no_key
    inc byte [split_delay]
    jmp .no_key

.not_right:
    ; Left arrow: delay -1
    cmp ah, 0x4B
    jne .not_left
    cmp byte [split_delay], 0
    je .no_key
    dec byte [split_delay]
    jmp .no_key

.not_left:
    ; + : delay +10
    cmp al, '+'
    je .inc10
    cmp al, '='
    jne .not_plus
.inc10:
    cmp byte [split_delay], 190
    jae .no_key
    add byte [split_delay], 10
    jmp .no_key

.not_plus:
    ; - : delay -10
    cmp al, '-'
    jne .not_minus
    cmp byte [split_delay], 10
    jb .no_key
    sub byte [split_delay], 10
    jmp .no_key

.not_minus:
    ; Up arrow: pad +1
    cmp ah, 0x48
    jne .not_up
    cmp byte [pad_nops], 200
    jae .no_key
    inc byte [pad_nops]
    jmp .no_key

.not_up:
    ; Down arrow: pad -1
    cmp ah, 0x50
    jne .not_down
    cmp byte [pad_nops], 0
    je .no_key
    dec byte [pad_nops]
    jmp .no_key

.not_down:
    ; M : Cycle test mode
    cmp al, 'm'
    je .next_mode
    cmp al, 'M'
    jne .no_key
.next_mode:
    inc byte [test_mode]
    cmp byte [test_mode], 3
    jb .no_key
    mov byte [test_mode], 0
    jmp .no_key

.no_key:
    xor al, al
.done:
    pop bx
    ret

; ============================================================================
; clear_screen
; ============================================================================
clear_screen:
    push ax
    push cx
    push di
    push es
    mov ax, VIDEO_SEG
    mov es, ax
    xor di, di
    mov cx, 8192
    xor ax, ax
    cld
    rep stosw
    pop es
    pop di
    pop cx
    pop ax
    ret

; ============================================================================
; DATA
; ============================================================================
split_delay:    db 30
pad_nops:       db 100
test_mode:      db 0

color_a_r:      db 0            ; Color A = Blue
color_a_gb:     db 0x07
color_b_r:      db 7            ; Color B = Red
color_b_gb:     db 0x00
