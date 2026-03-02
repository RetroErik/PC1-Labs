; ============================================================================
; PITRAS1D.asm - Half-Scanline PIT Mid-Scanline Color Split
; ============================================================================
;
; STATUS: ❌ CRASHES ON REAL HARDWARE
;
;   Multiple approaches attempted — all crash or produce heavy jitter.
;   The half-scanline PIT (count=38) fires 31,400 IRQs/sec which may
;   overwhelm the V40 or interact badly with V6355D bus timing.
;
;   Mid-scanline color changes remain an unsolved problem on the PC1.
;   See pitras3.asm for a simpler version that works (with jitter).
;
; APPROACHES TRIED (all failed or unacceptably jittery):
;   v1: pitras1c + 20 NOPs + blue write (active display sync) — jittery
;   v2: HBLANK sync + NOPs + blue — same diagonal jitter
;   v3: HBLANK sync + PORT_STATUS poll between writes — BLINKING
;       KEY FINDING: reading 0xDA between palette writes glitches V6355D
;   v4: HBLANK sync + 40 NOPs (no poll) — same jitter
;   v5: PORT_STATUS poll before writes + 20 NOPs + blue — closer but jittery
;   v6: Half-scanline PIT (count=38), phase-toggle ISR — CRASH
;
; GOAL: Two colors per scanline using half-scanline PIT interrupts.
;
; APPROACH:
;   PIT count = 38 (half of 76). Two interrupts fire per scanline,
;   each independently anchored to the 14.31818 MHz crystal:
;
;     Phase 0: fires at HBLANK start → write rainbow color (invisible)
;     Phase 1: fires 228 CPU cycles later → write blue (mid-scanline)
;
;   Both color changes have only ISR-entry jitter (~±10 pixels),
;   same as pitras1b. No NOP chains, no port polling between writes.
;
; BASED ON PC1-CLOCK-DISCOVERY.md FINDINGS:
;   - 1 CPU cycle = 1 pixel (7.159 MHz, Turbo mode)
;   - 456 cycles/scanline = 320 active + 136 blank
;   - 38 PIT ticks × 6 cycles/tick = 228 cycles between phases
;   - Phase 1 split point: 228 - 136 = pixel 92 (~29% from left)
;   - NOP = 3 cycles = 3 pixels (deterministic, no bus contention)
;   - No V6355D bus contention on system RAM execution
;
; EVOLUTION:
;   pitras1b: proven working — 1 color/scanline during HBLANK
;   pitras1c: proved V6355D accepts palette writes during active display
;   pitras1d: two colors/scanline via half-scanline PIT (this file)
;
; CONTROLS:
;   ESC    : Exit to DOS
;   , / .  : Fine-tune PIT count (should not be needed)
;   S      : Toggle between HLT sleep and busy-wait
;
; Written for NASM assembler
; Target: Olivetti Prodest PC1 with Yamaha V6355D video controller
; CPU: NEC V40 @ 7.159 MHz (14.31818 / 2)
;
; By Retro Erik - 2026
;
; ============================================================================
; BUILD
; ============================================================================
;
;   nasm -f bin -o pitras1d.com pitras1d.asm
;
; ============================================================================

[BITS 16]
[ORG 0x100]

; ============================================================================
; HARDWARE PORT DEFINITIONS
; ============================================================================

; --- Yamaha V6355D Video Controller ---
PORT_MODE       equ 0xD8        ; Video mode register
PORT_STATUS     equ 0xDA        ; Status register (bit 0=HSYNC, bit 3=VSYNC)
PORT_PAL_ADDR   equ 0xDD        ; Palette address register
PORT_PAL_DATA   equ 0xDE        ; Palette data register

; --- Intel 8253 PIT ---
PIT_CH0_DATA    equ 0x40        ; Channel 0 data port
PIT_COMMAND     equ 0x43        ; PIT command register

; --- Intel 8259 PIC ---
PIC_CMD         equ 0x20        ; PIC command port (EOI)

; ============================================================================
; TIMING CONSTANTS
; ============================================================================

PIT_SCANLINE_COUNT  equ 76      ; EXACT: 912 master clocks / 12 = 76
PIT_HALF_SCANLINE   equ 38      ; Half-scanline: 76/2 = 38 (exact)
TOTAL_SCANLINES     equ 314     ; PAL frame: 200 visible + 114 blank
VISIBLE_LINES       equ 200     ; Active display area

; ============================================================================
; SCREEN CONSTANTS
; ============================================================================

VIDEO_SEG       equ 0xB000      ; Video memory segment (V6355D)

; ============================================================================
; MAIN PROGRAM ENTRY POINT
; ============================================================================
main:
    ; ------------------------------------------------------------------
    ; Save original IRQ0 vector (INT 08h)
    ; ------------------------------------------------------------------
    xor ax, ax
    mov es, ax
    mov ax, [es:0x08*4]
    mov [cs:old_irq0_off], ax
    mov ax, [es:0x08*4+2]
    mov [cs:old_irq0_seg], ax

    ; ------------------------------------------------------------------
    ; Set up video mode: 160x200x16 (hidden mode)
    ; ------------------------------------------------------------------
    mov ax, 0x0004              ; BIOS mode 4 (CGA 320x200)
    int 0x10

    mov al, 0x4A                ; Hidden 160x200x16 mode
    out PORT_MODE, al

    ; ------------------------------------------------------------------
    ; Clear screen to color 0
    ; ------------------------------------------------------------------
    mov ax, VIDEO_SEG
    mov es, ax
    xor di, di
    mov cx, 8192
    xor ax, ax
    cld
    rep stosw

    ; ------------------------------------------------------------------
    ; Initialize ISR state (CS-relative, no DS needed)
    ; ------------------------------------------------------------------
    mov word [cs:scanline], 0
    mov word [cs:pit_count], PIT_HALF_SCANLINE
    mov byte [cs:phase], 1      ; Start at 1: first XOR→0 = phase 0 (HBLANK)
    mov byte [cs:sleep_mode], 1 ; Start with HLT mode
    mov byte [cs:exit_flag], 0

    ; ------------------------------------------------------------------
    ; CRITICAL: One-time PIT sync to HBLANK edge
    ; ------------------------------------------------------------------
    ; Sync PIT to RISING edge of HBLANK (same as pitras1b).
    ; PIT count = 38 (half-scanline). Two crystal-anchored interrupts
    ; per scanline: phase 0 at HBLANK, phase 1 at mid-scanline.
    ; ------------------------------------------------------------------

    cli                         ; No interrupts during sync

    ; Wait for VSYNC to start (ensures we're at frame boundary)
.wait_vsync_end:
    in al, PORT_STATUS
    test al, 0x08
    jnz .wait_vsync_end         ; Wait while in VBLANK

.wait_vsync_start:
    in al, PORT_STATUS
    test al, 0x08
    jz .wait_vsync_start        ; Wait for VBLANK to begin

    ; Now at top of VBLANK. Wait for HBLANK edge (same as pitras1b).

.wait_hblank_low:
    in al, PORT_STATUS
    test al, 0x01
    jnz .wait_hblank_low        ; Wait until NOT in HBLANK

.wait_hblank_high:
    in al, PORT_STATUS
    test al, 0x01
    jz .wait_hblank_high        ; Wait for HBLANK edge (rising)

    ; === HBLANK edge detected — start PIT NOW ===

    ; Install ISR first (before PIT fires!)
    xor ax, ax
    mov es, ax
    mov word [es:0x08*4], irq0_handler
    mov word [es:0x08*4+2], cs

    ; Program PIT Channel 0: Mode 2 (rate generator), count = 38
    ; Half-scanline: fires TWICE per scanline (phase 0 + phase 1)
    ; Phase 0 at HBLANK start → first color write
    ; Phase 1 at mid-scanline → second color write (blue)
    mov al, 0x34                ; CH0, lo/hi, Mode 2, binary
    out PIT_COMMAND, al
    mov al, PIT_HALF_SCANLINE   ; Low byte = 38
    out PIT_CH0_DATA, al
    mov al, 0                   ; High byte = 0
    out PIT_CH0_DATA, al

    ; PIT is now running. First IRQ0 fires in ~38 ticks.
    ; Two fires per scanline, phase-locked to crystal.
    ; We set scanline to a VBLANK line since we synced during VBLANK.
    mov word [cs:scanline], VISIBLE_LINES

    sti                         ; Let IRQ0 fire!

    ; ------------------------------------------------------------------
    ; Main loop — IDENTICAL to pitras1b
    ; ------------------------------------------------------------------

.main_loop:
    ; Check exit flag (set by keyboard handler)
    cmp byte [cs:exit_flag], 0
    jne .exit

    ; Sleep mode: HLT vs busy-wait
    cmp byte [cs:sleep_mode], 0
    je .busy_wait

    hlt                         ; Sleep until next IRQ0
    jmp .check_keys

.busy_wait:
    nop                         ; Busy-wait (for jitter comparison)
    nop

.check_keys:
    ; Non-blocking keyboard check
    mov ah, 0x01
    int 0x16
    jz .main_loop               ; No key waiting

    ; Read the key
    mov ah, 0x00
    int 0x16

    ; ESC - Exit
    cmp ah, 0x01
    jne .not_esc
    mov byte [cs:exit_flag], 1
    jmp .main_loop

.not_esc:
    ; S - Toggle sleep mode (HLT vs busy-wait)
    cmp al, 's'
    je .toggle_sleep
    cmp al, 'S'
    jne .not_s
.toggle_sleep:
    xor byte [cs:sleep_mode], 1
    jmp .main_loop

.not_s:
    ; . - Increase PIT count
    cmp al, '.'
    jne .not_period
    inc word [cs:pit_count]
    call reprogram_pit
    jmp .main_loop

.not_period:
    ; , - Decrease PIT count
    cmp al, ','
    jne .main_loop
    cmp word [cs:pit_count], 50
    jbe .main_loop
    dec word [cs:pit_count]
    call reprogram_pit
    jmp .main_loop

    ; ------------------------------------------------------------------
    ; Exit: restore PIT and IRQ0, return to DOS
    ; ------------------------------------------------------------------
.exit:
    cli

    ; Restore PIT to default (Mode 3, count 0 = 65536)
    mov al, 0x36                ; CH0, lo/hi, Mode 3, binary
    out PIT_COMMAND, al
    xor al, al
    out PIT_CH0_DATA, al        ; Low byte = 0
    out PIT_CH0_DATA, al        ; High byte = 0

    ; Restore original IRQ0 vector
    xor ax, ax
    mov es, ax
    mov ax, [cs:old_irq0_off]
    mov [es:0x08*4], ax
    mov ax, [cs:old_irq0_seg]
    mov [es:0x08*4+2], ax

    ; Reset palette entry 0 to black
    mov al, 0x40
    out PORT_PAL_ADDR, al
    xor al, al
    out PORT_PAL_DATA, al
    out PORT_PAL_DATA, al

    sti

    ; Restore text mode
    mov ax, 0x0003
    int 0x10

    ; Exit to DOS
    mov ax, 0x4C00
    int 0x21

; ============================================================================
; reprogram_pit - Update PIT count without losing sync
; ============================================================================
reprogram_pit:
    push ax
    cli
    mov al, 0x34                ; CH0, lo/hi, Mode 2, binary
    out PIT_COMMAND, al
    mov ax, [cs:pit_count]
    out PIT_CH0_DATA, al        ; Low byte
    mov al, ah
    out PIT_CH0_DATA, al        ; High byte
    sti
    pop ax
    ret

; ============================================================================
; irq0_handler - Half-Scanline ISR (fires every 38 PIT ticks)
; ============================================================================
;
; PIT fires TWICE per scanline (count=38, half of 76).
; Phase 0: fires at HBLANK start → write rainbow color (invisible change)
; Phase 1: fires 228 CPU cycles later → write blue (mid-scanline split)
;
; Both phases are independently anchored to the crystal.
; Scanline counter advances ONLY in phase 1 (once per full scanline).
;
; ============================================================================
irq0_handler:
    push ax
    push bx

    ; ------------------------------------------------------------------
    ; Toggle phase: 0 → 1, 1 → 0
    ; Phase starts at 1, so first XOR → 0 = phase 0 (HBLANK rainbow)
    ; ------------------------------------------------------------------
    xor byte [cs:phase], 1
    jnz .phase1                 ; If now 1 → mid-scanline write

    ; ==================================================================
    ; PHASE 0: HBLANK — write first color (rainbow from table)
    ; ==================================================================
    mov bx, [cs:scanline]
    cmp bx, VISIBLE_LINES
    jae .isr_eoi                ; VBLANK: skip, don't advance

    shl bx, 1                   ; BX = scanline * 2
    mov al, 0x40                ; Select palette entry 0
    out PORT_PAL_ADDR, al
    mov al, [cs:color_table + bx]       ; R byte
    out PORT_PAL_DATA, al
    mov al, [cs:color_table + bx + 1]   ; G<<4|B byte
    out PORT_PAL_DATA, al
    jmp .isr_eoi                ; Don't advance scanline yet

    ; ==================================================================
    ; PHASE 1: MID-SCANLINE — write second color (blue)
    ; ==================================================================
.phase1:
    mov bx, [cs:scanline]
    cmp bx, VISIBLE_LINES
    jae .phase1_advance         ; VBLANK: skip palette, just advance

    ; Visible line: write blue at mid-scanline
    mov al, 0x40                ; Select palette entry 0
    out PORT_PAL_ADDR, al
    xor al, al                  ; R = 0
    out PORT_PAL_DATA, al
    mov al, 0x07                ; G=0, B=7
    out PORT_PAL_DATA, al

.phase1_advance:
    ; Advance scanline (ONLY here — once per full scanline)
    inc word [cs:scanline]
    cmp word [cs:scanline], TOTAL_SCANLINES
    jb .isr_eoi
    mov word [cs:scanline], 0

.isr_eoi:
    mov al, 0x20
    out PIC_CMD, al

    pop bx
    pop ax
    iret

; ============================================================================
; DATA (CS-relative — accessible from ISR without DS reload)
; ============================================================================

; --- ISR State ---
scanline:       dw 0                    ; Current scanline (0-313)
pit_count:      dw PIT_HALF_SCANLINE    ; Current PIT count (38 = half scanline)
phase:          db 1                    ; Starts at 1; first XOR→0 = HBLANK phase
sleep_mode:     db 1                    ; 1=HLT, 0=busy-wait
exit_flag:      db 0                    ; 1=exit requested

; --- Saved IRQ0 vector ---
old_irq0_off:   dw 0
old_irq0_seg:   dw 0

; ============================================================================
; PALETTE DATA - Full Rainbow (200 scanlines)
; ============================================================================
; Identical to pitras1b — same color_table for direct comparison.
; Format: R (bits 0-2), G<<4|B (bits 4-6 | 0-2)

color_table:
    ; RED to YELLOW (33 lines)
    db 7,0x00, 7,0x00, 7,0x00, 7,0x00, 7,0x10, 7,0x10, 7,0x10, 7,0x10
    db 7,0x20, 7,0x20, 7,0x20, 7,0x20, 7,0x30, 7,0x30, 7,0x30, 7,0x30
    db 7,0x40, 7,0x40, 7,0x40, 7,0x40, 7,0x50, 7,0x50, 7,0x50, 7,0x50
    db 7,0x60, 7,0x60, 7,0x60, 7,0x60, 7,0x70, 7,0x70, 7,0x70, 7,0x70
    db 7,0x70
    ; YELLOW to GREEN (33 lines)
    db 7,0x70, 7,0x70, 7,0x70, 7,0x70, 6,0x70, 6,0x70, 6,0x70, 6,0x70
    db 5,0x70, 5,0x70, 5,0x70, 5,0x70, 4,0x70, 4,0x70, 4,0x70, 4,0x70
    db 3,0x70, 3,0x70, 3,0x70, 3,0x70, 2,0x70, 2,0x70, 2,0x70, 2,0x70
    db 1,0x70, 1,0x70, 1,0x70, 1,0x70, 0,0x70, 0,0x70, 0,0x70, 0,0x70
    db 0,0x70
    ; GREEN to CYAN (33 lines)
    db 0,0x70, 0,0x70, 0,0x70, 0,0x70, 0,0x71, 0,0x71, 0,0x71, 0,0x71
    db 0,0x72, 0,0x72, 0,0x72, 0,0x72, 0,0x73, 0,0x73, 0,0x73, 0,0x73
    db 0,0x74, 0,0x74, 0,0x74, 0,0x74, 0,0x75, 0,0x75, 0,0x75, 0,0x75
    db 0,0x76, 0,0x76, 0,0x76, 0,0x76, 0,0x77, 0,0x77, 0,0x77, 0,0x77
    db 0,0x77
    ; CYAN to BLUE (33 lines)
    db 0,0x77, 0,0x77, 0,0x77, 0,0x77, 0,0x67, 0,0x67, 0,0x67, 0,0x67
    db 0,0x57, 0,0x57, 0,0x57, 0,0x57, 0,0x47, 0,0x47, 0,0x47, 0,0x47
    db 0,0x37, 0,0x37, 0,0x37, 0,0x37, 0,0x27, 0,0x27, 0,0x27, 0,0x27
    db 0,0x17, 0,0x17, 0,0x17, 0,0x17, 0,0x07, 0,0x07, 0,0x07, 0,0x07
    db 0,0x07
    ; BLUE to MAGENTA (34 lines)
    db 0,0x07, 0,0x07, 0,0x07, 0,0x07, 1,0x07, 1,0x07, 1,0x07, 1,0x07
    db 2,0x07, 2,0x07, 2,0x07, 2,0x07, 3,0x07, 3,0x07, 3,0x07, 3,0x07
    db 4,0x07, 4,0x07, 4,0x07, 4,0x07, 5,0x07, 5,0x07, 5,0x07, 5,0x07
    db 6,0x07, 6,0x07, 6,0x07, 6,0x07, 7,0x07, 7,0x07, 7,0x07, 7,0x07
    db 7,0x07, 7,0x07
    ; MAGENTA to RED (34 lines)
    db 7,0x07, 7,0x07, 7,0x07, 7,0x07, 7,0x06, 7,0x06, 7,0x06, 7,0x06
    db 7,0x05, 7,0x05, 7,0x05, 7,0x05, 7,0x04, 7,0x04, 7,0x04, 7,0x04
    db 7,0x03, 7,0x03, 7,0x03, 7,0x03, 7,0x02, 7,0x02, 7,0x02, 7,0x02
    db 7,0x01, 7,0x01, 7,0x01, 7,0x01, 7,0x00, 7,0x00, 7,0x00, 7,0x00
    db 7,0x00, 7,0x00

; ============================================================================
; END OF PROGRAM
; ============================================================================
