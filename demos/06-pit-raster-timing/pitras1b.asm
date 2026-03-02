; ============================================================================
; PITRAS1B.asm - Phase-Locked PIT Raster (Zero-Drift)
; ============================================================================
;
; IMPROVED VERSION of pitras1a.asm using the clock discovery findings:
;
; KEY INSIGHT (confirmed by Simon, V6355D designer):
;   On the 1987 PC1, the CPU clock comes from the V6355D's DCK output.
;   CPU, PIT, and pixel clock all derive from the SAME 14.31818 MHz crystal.
;   This means PIT and scanlines are PHASE-LOCKED — zero drift, ever.
;
; WHAT PITRAS1A DID WRONG:
;   1. Reinstalled PIT + ISR every frame (re-sync jitter each time)
;   2. Loaded DS segment inside the ISR (wasted ~12 cycles)
;   3. Used memory variables for scanline count (slow)
;   4. No HBLANK edge sync before starting PIT
;   5. Assumed "8 MHz" CPU (actually 7.159 MHz = 14.318/2)
;
; WHAT PITRAS1B DOES DIFFERENTLY:
;   1. ONE-TIME setup: sync PIT to HBLANK edge, install ISR, done
;   2. PIT runs forever at 76 ticks/scanline — never reprogrammed
;   3. ISR uses CS-relative data only (no DS reload needed)
;   4. Scanline counter in ISR wraps at 314 (full PAL frame)
;   5. Main loop uses HLT — CPU sleeps between interrupts
;   6. Phase-locked = zero drift = butter-smooth raster bars
;
; HARDWARE TEST RESULTS (confirmed on real Olivetti Prodest PC1):
;   - Rainbow bars are 99%+ stable — near-zero horizontal jitter
;   - PIT count 76 confirmed EXACT (75 drifts one way, 77 the other)
;   - Frame total = 314 lines confirmed (313 caused upward scroll)
;   - Remaining ~1% edge flicker = V40 interrupt latency variance
;     (CPU can't break mid-instruction: 1-cycle NOP vs 20-cycle MUL)
;   - HLT sleep vs busy-wait (S key): busy-wait noticeably worse —
;     confirms jitter source is variable instruction length at IRQ entry
;   - Phase-lock theory: PROVEN
;
; CONTROLS:
;   ESC    : Exit to DOS
;   , / .  : Fine-tune PIT count (should not be needed if 76 is exact)
;   S      : Toggle between HLT sleep and busy-wait (jitter comparison)
;
; Written for NASM assembler
; Target: Olivetti Prodest PC1 with Yamaha V6355D video controller
; CPU: NEC V40 @ 7.159 MHz (14.31818 / 2)
;
; By Retro Erik - 2026
;
; ============================================================================
; PHASE-LOCKED CLOCK TREE (confirmed)
; ============================================================================
;
;   14.31818 MHz Crystal
;       |
;       +-- V6355D master clock
;       |     +-- / 2 = 7.159 MHz pixel clock (320-wide modes)
;       |     +-- DCK output -> CPU clock divider
;       |
;       +-- / 2 = 7.159 MHz CPU clock (Turbo mode)
;       +-- / 12 = 1.193182 MHz PIT clock
;
;   PIT ticks per scanline = 14.31818 MHz / 912 master clocks
;                           / (14.31818 MHz / 12)
;                         = 912 / 12 = 76.0 EXACTLY
;
;   This is not an approximation. It is mathematically exact.
;   76 PIT ticks = 1 scanline, with zero accumulated error.
;
; ============================================================================
; PAL FRAME STRUCTURE
; ============================================================================
;
;   Lines 0-199:   Visible (active display)
;   Lines 200-313: Vertical blanking (114 lines)
;   Total:         314 lines per frame (50 Hz PAL)
;
;   ISR fires on every line. During VBLANK (lines 200-313), it just
;   increments the counter and returns — very fast, frees CPU.
;
; ============================================================================
; BUILD
; ============================================================================
;
;   nasm -f bin -o pitras1b.com pitras1b.asm
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
    mov word [cs:pit_count], PIT_SCANLINE_COUNT
    mov byte [cs:sleep_mode], 1 ; Start with HLT mode
    mov byte [cs:exit_flag], 0

    ; ------------------------------------------------------------------
    ; CRITICAL: One-time PIT sync to HBLANK edge
    ; ------------------------------------------------------------------
    ; This is the single synchronization point. After this, the PIT
    ; and scanlines stay phase-locked forever (same crystal).
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

    ; Now at top of VBLANK. Wait for the first HBLANK edge.
    ; This aligns our PIT to the exact start of a scanline.

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

    ; Program PIT Channel 0: Mode 2 (rate generator), count = 76
    mov al, 0x34                ; CH0, lo/hi, Mode 2, binary
    out PIT_COMMAND, al
    mov al, PIT_SCANLINE_COUNT  ; Low byte = 76
    out PIT_CH0_DATA, al
    mov al, 0                   ; High byte = 0
    out PIT_CH0_DATA, al

    ; PIT is now running. First IRQ0 will fire in ~76 ticks.
    ; From here on, ISR fires once per scanline, phase-locked.
    ; We set scanline to a VBLANK line since we synced during VBLANK.
    mov word [cs:scanline], VISIBLE_LINES

    sti                         ; Let IRQ0 fire!

    ; ------------------------------------------------------------------
    ; Main loop — CPU is FREE
    ; ------------------------------------------------------------------
    ; The ISR handles all palette updates. Main loop just handles
    ; keyboard input and sleeps.
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
; Called from main loop when user adjusts PIT count with , / .
; Writing a new count to Mode 2 takes effect on the next reload,
; so the phase relationship is maintained (no re-sync needed).
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
; irq0_handler - Scanline ISR (fires every 76 PIT ticks)
; ============================================================================
;
; DESIGN GOALS:
;   - Minimum cycle count (every cycle = 1 pixel of jitter)
;   - CS-relative data only (no DS reload)
;   - Fast path for VBLANK lines (just increment + EOI)
;   - Palette write only during visible lines
;
; CYCLE BUDGET (approximate, V40):
;   Interrupt entry (push flags+CS+IP):  ~12 cycles
;   push ax, bx:                         ~4 cycles
;   Scanline check + visible path:       ~20 cycles
;   Palette write (3 OUTs):              ~30 cycles
;   Counter update + wrap:               ~10 cycles
;   EOI + pop + IRET:                    ~20 cycles
;   TOTAL:                               ~96 cycles
;
;   With 136 HBLANK cycles available, we have ~40 cycles margin.
;   The palette write may extend slightly into visible area, but
;   since we're writing entry 0 (background), this is usually OK.
;
; ============================================================================
irq0_handler:
    push ax
    push bx

    ; ------------------------------------------------------------------
    ; Get current scanline
    ; ------------------------------------------------------------------
    mov bx, [cs:scanline]

    ; ------------------------------------------------------------------
    ; Are we in the visible area? (lines 0-199)
    ; ------------------------------------------------------------------
    cmp bx, VISIBLE_LINES
    jae .isr_vblank

    ; ------------------------------------------------------------------
    ; VISIBLE LINE: Write palette entry 0 with this line's color
    ; ------------------------------------------------------------------
    ; Color table: 2 bytes per line (R, G<<4|B), at CS:color_table
    ; BX = scanline number (0-199), index = BX * 2

    shl bx, 1                   ; BX = scanline * 2
    mov al, 0x40                ; Select palette entry 0
    out PORT_PAL_ADDR, al
    mov al, [cs:color_table + bx]       ; R byte
    out PORT_PAL_DATA, al
    mov al, [cs:color_table + bx + 1]   ; G<<4|B byte
    out PORT_PAL_DATA, al

.isr_advance:
    ; ------------------------------------------------------------------
    ; Advance scanline counter (wrap at TOTAL_SCANLINES)
    ; ------------------------------------------------------------------
    inc word [cs:scanline]
    cmp word [cs:scanline], TOTAL_SCANLINES
    jb .isr_eoi
    mov word [cs:scanline], 0   ; Wrap to line 0

.isr_eoi:
    ; ------------------------------------------------------------------
    ; Send EOI to PIC
    ; ------------------------------------------------------------------
    mov al, 0x20
    out PIC_CMD, al

    pop bx
    pop ax
    iret

.isr_vblank:
    ; ------------------------------------------------------------------
    ; VBLANK LINE: Skip palette write, just advance counter
    ; ------------------------------------------------------------------
    jmp .isr_advance

; ============================================================================
; DATA (CS-relative — accessible from ISR without DS reload)
; ============================================================================

; --- ISR State ---
scanline:       dw 0                    ; Current scanline (0-313)
pit_count:      dw PIT_SCANLINE_COUNT   ; Current PIT count
sleep_mode:     db 1                    ; 1=HLT, 0=busy-wait
exit_flag:      db 0                    ; 1=exit requested

; --- Saved IRQ0 vector ---
old_irq0_off:   dw 0
old_irq0_seg:   dw 0

; ============================================================================
; PALETTE DATA - Full Rainbow (200 scanlines)
; ============================================================================
; Format: R (bits 0-2), G<<4|B (bits 4-6 | 0-2)
; Full spectrum: Red -> Yellow -> Green -> Cyan -> Blue -> Magenta -> Red
;
; Identical to pitras1.asm palette data for direct comparison.

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
