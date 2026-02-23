; ============================================================================
; PITRAS4.asm — Cycle-Counted Mid-Scanline Color Split (No ISR)
; ============================================================================
;
; PURPOSE:
;   Achieve pixel-precise mid-scanline color changes by eliminating ALL
;   sources of timing non-determinism:
;     1. No PIT interrupts (ISR push/pop/iret adds ~40-cycle jitter)
;     2. No HSYNC polling loops (variable iteration count = jitter)
;     3. Cycle-counted delay to target exact pixel positions
;
; TECHNIQUE (inspired by 8088 MPH / reenigne's Kefrens bars):
;   - CLI to disable all interrupts
;   - Wait for VBLANK to sync with top of frame
;   - Execute a tight cycle-counted loop: each iteration = exactly 1 scanline
;   - The palette write happens at a deterministic cycle offset within
;     each scanline, targeting a specific pixel column
;
; V6355D TIMING (Olivetti PC1):
;   - Pixel clock:      14.31818 MHz / 2 = 7.15909 MHz
;   - CPU clock:        8 MHz (NEC V40)
;   - Pixels/scanline:  912 total (including blanking)
;   - Visible pixels:   320 (in CGA mode 4 / hidden mode)
;   - CPU cycles/scanline: ~509 (63.5 µs × 8 MHz)
;   - CPU cycles/pixel: ~0.56 (i.e. 1 pixel ≈ 1.8 CPU cycles)
;   - HBLANK:           ~80 CPU cycles (~10 µs)
;   - Active display:   ~320-424 CPU cycles
;
; PIXEL TARGETING:
;   To hit pixel N within the visible area:
;     delay_cycles = N × 1.8   (from start of active display)
;   For pixel 100: delay ≈ 180 CPU cycles after active display begins
;   For pixel 160: delay ≈ 288 CPU cycles (screen center)
;
;   But we measure from HSYNC edge (start of HBLANK), so:
;     total_delay = HBLANK_cycles + pixel_delay
;     pixel 100: ~80 + 180 = ~260 cycles after HSYNC
;     pixel 160: ~80 + 288 = ~368 cycles after HSYNC
;
; JITTER ANALYSIS:
;   On standard IBM PC, DRAM refresh (PIT CH1) steals 4 bus cycles every
;   72 cycles → ~6% timing uncertainty. Reenigne solved this by reprogramming
;   PIT CH1 to 76 ticks (4 refreshes per scanline at fixed positions).
;
;   On the Olivetti PC1 (NEC V40):
;     - DRAM refresh is internal to V40 — NOT via PIT CH1 → can't reprogram
;     - V6355D steals bus cycles for VRAM fetch → unpredictable
;     - V40's internal DRAM refresh timing is unknown
;   Both are sources of jitter we cannot fully eliminate.
;
;   This experiment measures the MINIMUM achievable jitter with the
;   cycle-counted approach vs the PIT ISR approach (pitras3).
;
; THE SCANLINE LOOP:
;   Each iteration must take EXACTLY 509 CPU cycles (1 scanline).
;   We split each iteration into:
;     [HSYNC wait] + [palette write #1] + [delay] + [palette write #2] + [pad]
;   Where [delay] positions the split point and [pad] fills remaining time.
;
; CONTROLS:
;   Right/Left  : Adjust delay by 1 NOP (fine — moves split point)
;   +/-         : Adjust delay by 10 NOPs (coarse)
;   Up/Down     : Adjust pad NOPs by 1 (tune total scanline time)
;   ESC         : Exit
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
PORT_PAL_ADDR   equ 0xDD
PORT_PAL_DATA   equ 0xDE

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
    mov ax, 0x0004          ; CGA 320x200x4
    int 0x10
    mov al, 0x4A            ; Hidden 160x200x16
    out PORT_MODE, al

    ; Clear screen (all pixels = palette entry 0)
    call clear_screen

    ; Initialize defaults
    mov byte [split_delay], 40      ; ~40 NOPs ≈ pixel 72
    mov byte [pad_nops], 108        ; Pad to fill scanline

    ; =========  M A I N   L O O P  =========
.main_loop:
    call render_frame
    call check_keyboard
    cmp al, 0xFF
    jne .main_loop

    ; === EXIT ===
    ; Reset palette entry 0 to black
    mov al, 0x40
    out PORT_PAL_ADDR, al
    xor al, al
    out PORT_PAL_DATA, al
    out PORT_PAL_DATA, al

    mov ax, 0x0003
    int 0x10
    mov ax, 0x4C00
    int 0x21

; ============================================================================
; render_frame — Cycle-counted scanline loop (no ISR, no polling jitter)
; ============================================================================
;
; Strategy:
;   1. Wait for VBLANK (sync to top of frame)
;   2. CLI
;   3. For each of 200 scanlines:
;      a. Wait for HSYNC HIGH (start of HBLANK)
;         — This is the ONE polling loop. But its jitter only affects
;           where on the scanline we START; the split point within
;           the scanline is determined by cycle counting from there.
;      b. Write BLUE to palette entry 0 (3 OUTs, ~33 cycles)
;      c. Execute [split_delay] NOPs (~3 cycles each on V40)
;      d. Write RED to palette entry 0 (3 OUTs, ~33 cycles)
;      e. Execute [pad_nops] NOPs to fill rest of scanline
;   4. STI
;
; The key insight: HSYNC polling jitter affects ALL scanlines equally
; (systematic, not random), so the split point within each scanline
; is stable even if the absolute horizontal position drifts slightly.
; The V6355D bus contention is the remaining source of random jitter.
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
.wait_vblank_end:
    in al, dx
    test al, 0x08
    jnz .wait_vblank_end
.wait_vblank_start:
    in al, dx
    test al, 0x08
    jz .wait_vblank_start

    cli                         ; *** INTERRUPTS OFF FOR ENTIRE FRAME ***

    ; Load parameters into registers for speed
    ; (V40 is 80186 — no movzx! Use xor+mov instead)
    xor bx, bx
    mov bl, [split_delay]
    mov bp, bx                      ; BP = split delay count
    xor bx, bx
    mov bl, [pad_nops]
    mov si, bx                      ; SI = pad count
    mov cx, SCREEN_HEIGHT           ; CX = scanline counter (200)
    mov dx, PORT_STATUS             ; DX = status port for HSYNC check

    ; ===================================================================
    ; SCANLINE LOOP — 200 iterations
    ; ===================================================================
.scanline_loop:
    ; ------------------------------------------------------------------
    ; STEP 1: Wait for HSYNC HIGH (entering HBLANK)
    ; ------------------------------------------------------------------
    ; This is our sync point. The polling introduces ~4-8 cycle jitter
    ; (1 iteration of the poll loop), but this jitter is CONSTANT for
    ; the split point because both color writes happen at fixed cycle
    ; offsets from this moment.
    ; ------------------------------------------------------------------
.wait_hsync_low:
    in al, dx               ; 8 cycles (in from port)
    test al, 0x01            ; 1 cycle
    jnz .wait_hsync_low      ; 1/4 cycles (taken/not)
.wait_hsync_high:
    in al, dx               ; 8 cycles
    test al, 0x01            ; 1 cycle
    jz .wait_hsync_high      ; 1/4 cycles

    ; ------------------------------------------------------------------
    ; STEP 2: Write COLOR 1 (BLUE) to palette entry 0
    ; ------------------------------------------------------------------
    ; 3 OUTs: address + R byte + GB byte
    ; V40 I/O cycle: ~11 cycles per OUT (short-form port)
    ; Total: ~33 cycles
    ; ------------------------------------------------------------------
    mov al, 0x40            ; Palette entry 0 address
    out PORT_PAL_ADDR, al   ; Set palette address          ~11 cyc
    xor al, al              ; R = 0                        ~1 cyc
    out PORT_PAL_DATA, al   ; Write R                      ~11 cyc
    mov al, 0x07            ; G=0, B=7 (blue)              ~1 cyc
    out PORT_PAL_DATA, al   ; Write GB                     ~11 cyc
                            ; SUBTOTAL: ~35 cycles
    ; ------------------------------------------------------------------
    ; STEP 3: DELAY — position the color split
    ; ------------------------------------------------------------------
    ; Each NOP on V40 ≈ 3 cycles (1 byte fetch + execute)
    ; split_delay NOPs = split_delay × 3 cycles
    ;
    ; We use a register LOOP instead of unrolled NOPs so the delay is
    ; adjustable at runtime. LOOP cost: 5 cycles/iteration on V40,
    ; plus the NOP (3 cycles) = 8 cycles per iteration.
    ;
    ; For pixel 100: need ~180 cycles delay → ~23 iterations
    ; For pixel 160: need ~288 cycles delay → ~36 iterations
    ; ------------------------------------------------------------------
    push cx                 ; Save scanline counter         ~3 cyc
    mov cx, bp              ; CX = split delay              ~2 cyc
    jcxz .skip_delay        ;                               ~4 cyc
.delay_loop:
    nop                     ; 3+ cycles
    nop                     ; 3+ cycles (add more NOPs for
    nop                     ; 3+ cycles  coarser but stabler steps)
    loop .delay_loop        ; 5 cycles (taken)
.skip_delay:
    pop cx                  ; Restore scanline counter      ~3 cyc

    ; ------------------------------------------------------------------
    ; STEP 4: Write COLOR 2 (RED) to palette entry 0
    ; ------------------------------------------------------------------
    mov al, 0x40            ; Palette entry 0 address
    out PORT_PAL_ADDR, al   ;                              ~11 cyc
    mov al, 7               ; R = 7                        ~1 cyc
    out PORT_PAL_DATA, al   ;                              ~11 cyc
    xor al, al              ; G=0, B=0 (red)              ~1 cyc
    out PORT_PAL_DATA, al   ;                              ~11 cyc
                            ; SUBTOTAL: ~35 cycles

    ; ------------------------------------------------------------------
    ; STEP 5: PAD — fill remaining scanline time
    ; ------------------------------------------------------------------
    ; We need the total loop iteration to be close to 509 cycles.
    ; Used cycles so far per iteration (approximate):
    ;   HSYNC poll:    ~20 cycles (avg)
    ;   Color 1 write: ~35 cycles
    ;   Delay loop:    ~(14 × split_delay) cycles
    ;   Color 2 write: ~35 cycles
    ;   Pad + loop:    ~(14 × pad_nops) cycles
    ;   Loop overhead: ~10 cycles
    ;   TOTAL:         ~100 + 14×(split_delay + pad_nops)
    ;   To reach 509:  14 × (split+pad) ≈ 409
    ;                  split+pad ≈ 29
    ;
    ; (These are rough — tune on real hardware with Up/Down keys)
    ; ------------------------------------------------------------------
    push cx
    mov cx, si              ; CX = pad count
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

    sti                     ; *** INTERRUPTS BACK ON ***

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
    ; P : print current values (visual debugging)
    cmp al, 'p'
    je .print_vals
    cmp al, 'P'
    jne .no_key
.print_vals:
    ; We skip printing for now (too complex for .COM)
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
; wait_vblank (standalone — used only before render_frame)
; ============================================================================
wait_vblank:
    push ax
    push dx
    mov dx, PORT_STATUS
.wait_end:
    in al, dx
    test al, 0x08
    jnz .wait_end
.wait_start:
    in al, dx
    test al, 0x08
    jz .wait_start
    pop dx
    pop ax
    ret

; ============================================================================
; DATA
; ============================================================================
split_delay:    db 40           ; NOP loop iterations before 2nd color write
pad_nops:       db 108          ; NOP loop iterations to fill scanline
