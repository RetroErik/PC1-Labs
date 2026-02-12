; ============================================================================
; PITRAS1.asm - PIT Interrupt Raster Timing (Method 3)
; ============================================================================
;
; EDUCATIONAL DEMONSTRATION: PIT-Timed Scanline Updates
;
; This method replaces HSYNC polling with PIT-driven IRQ0 timing. Instead of
; busy-waiting on the status port, we schedule a timer interrupt for each
; scanline and perform the color update inside the ISR. This reduces jitter
; and frees CPU time between scanlines.
;
; TECHNIQUE (inspired by 8088MPH / Area5150):
;   1. Save the original IRQ0 vector and PIT settings
;   2. Wait for VBLANK to synchronize with frame start
;   3. Reprogram PIT Channel 0 to fire every ~76 ticks (~63.5µs = 1 scanline)
;   4. Our custom ISR fires once per scanline and updates palette entry 0
;   5. After 200 scanlines, we stop and wait for next frame
;   6. On exit, restore original PIT and IRQ0 vector
;
; Written for NASM assembler
; Target: Olivetti Prodest PC1 / M24 with Yamaha V6355D video controller
; CPU: NEC V40 (80186 compatible) @ 8 MHz
;
; By Retro Erik - 2026

; ** The plan is to test 4 methods. We have tested method 1 and 2
;   1. PORT_COLOR (0x3D9): 1 OUT per scanline, 16 palette indices (fast, limited).
;   2. Palette RAM (0x3DD/0x3DE): 3 OUTs per scanline, RGB333 (512 colors).
; **  3. PIT interrupt raster (8088MPH/Area5150): timer IRQs schedule mid-scanline updates.
;   4. CGA palette flip (0x3D8): toggle between the two CGA palettes mid-scanline.
;
; ============================================================================
; PIT TIMING THEORY
; ============================================================================
;
; The Intel 8253/8254 PIT (Programmable Interval Timer) has 3 channels:
;   - Channel 0: System timer (connected to IRQ0 via 8259 PIC)
;   - Channel 1: DRAM refresh (not used here)
;   - Channel 2: PC speaker
;
; PIT Clock Frequency: 1.193182 MHz (derived from 14.31818 MHz / 12)
; PIT Tick Duration: 1 / 1,193,182 = ~0.838 microseconds
;
; CGA Horizontal Timing:
;   - Horizontal frequency: 15.7 kHz (derived from 14.31818 MHz / 912)
;   - Scanline duration: ~63.5 microseconds
;   - PIT ticks per scanline: 63.5 / 0.838 ≈ 76 ticks
;
; By programming PIT Channel 0 with count=76, we get an IRQ0 every scanline!
;
; CAUTION: The PIT count must be tuned for exact hardware. Values 75-77 may
; work better depending on PIT/CRT clock drift. Adjust PIT_SCANLINE_COUNT.
;
; ============================================================================
; CONTROLS
; ============================================================================
;
;   +/-  : Adjust PIT count (fine-tune scanline timing)
;   P    : Toggle PIT mode vs HSYNC polling mode
;   V    : Toggle VSYNC waiting
;   ESC  : Exit to DOS
;
; ============================================================================

[BITS 16]
[ORG 0x100]

; ============================================================================
; HARDWARE PORT DEFINITIONS
; ============================================================================

; --- Yamaha V6355D Video Controller ---
; Note: 0xDx and 0x3Dx are aliases on PC1 - using short form for byte-immediate OUT
PORT_MODE       equ 0xD8    ; Video mode register (write 0x4A for 160x200x16)
PORT_STATUS     equ 0x3DA   ; Status register (bit 0=HSYNC, bit 3=VSYNC)
PORT_PAL_ADDR   equ 0xDD    ; Palette address register (0x40 = entry 0)
PORT_PAL_DATA   equ 0xDE    ; Palette data register (R, then G<<4|B)

; --- Intel 8253/8254 PIT (Programmable Interval Timer) ---
PIT_CH0_DATA    equ 0x40    ; Channel 0 data port (IRQ0 timer)
PIT_CH2_DATA    equ 0x42    ; Channel 2 data port (PC speaker)
PIT_COMMAND     equ 0x43    ; PIT command/mode register

; --- Intel 8259 PIC (Programmable Interrupt Controller) ---
PIC_CMD         equ 0x20    ; PIC command port (EOI goes here)
PIC_DATA        equ 0x21    ; PIC data port (interrupt mask)

; ============================================================================
; TIMING CONSTANTS
; ============================================================================

; PIT count for one scanline (~63.5µs)
; Formula: 1,193,182 Hz / 15,700 Hz ≈ 76
; Adjust this value if raster bars drift up or down
PIT_SCANLINE_COUNT  equ 76

; ============================================================================
; MEMORY AND SCREEN CONSTANTS
; ============================================================================

VIDEO_SEG       equ 0xB000  ; Video memory segment
SCREEN_HEIGHT   equ 200     ; Vertical resolution in pixels

; ============================================================================
; MAIN PROGRAM ENTRY POINT
; ============================================================================
main:
    ; -----------------------------------------------------------------------
    ; Save DS for ISR access
    ; -----------------------------------------------------------------------
    mov ax, cs
    mov [cs:isr_data_seg], ax   ; ISR needs to know our data segment
    
    ; -----------------------------------------------------------------------
    ; Initialize demo state
    ; -----------------------------------------------------------------------
    call load_current_palette   ; Copy rainbow palette to working buffer
    mov word [pit_count], PIT_SCANLINE_COUNT
    mov byte [pit_mode], 1      ; Start in PIT mode
    mov byte [vsync_enabled], 1 ; VSYNC waiting ON
    
    ; -----------------------------------------------------------------------
    ; Save original IRQ0 vector (INT 08h)
    ; -----------------------------------------------------------------------
    xor ax, ax
    mov es, ax                  ; ES = 0 (IVT segment)
    mov ax, [es:0x08*4]         ; Offset of INT 08h
    mov [old_irq0_off], ax
    mov ax, [es:0x08*4+2]       ; Segment of INT 08h
    mov [old_irq0_seg], ax
    
    ; -----------------------------------------------------------------------
    ; Set up the video mode
    ; -----------------------------------------------------------------------
    mov ax, 0x0004              ; BIOS mode 4 (CGA 320x200)
    int 0x10                    ; Sets up CRTC timing
    
    mov al, 0x4A                ; Hidden 160x200x16 mode
    out PORT_MODE, al
    
    ; -----------------------------------------------------------------------
    ; Clear screen to color 0
    ; -----------------------------------------------------------------------
    call clear_screen
    
    ; -----------------------------------------------------------------------
    ; Main rendering loop
    ; -----------------------------------------------------------------------
.main_loop:
    call wait_vblank            ; Synchronize to frame start
    
    ; Check which mode we're in
    cmp byte [pit_mode], 0
    je .polling_mode
    
    ; PIT-timed rendering mode
    call render_pit_frame
    jmp .check_input
    
.polling_mode:
    ; HSYNC polling mode (fallback, for comparison)
    call render_polling_frame
    
.check_input:
    call check_keyboard
    cmp al, 0xFF
    jne .main_loop
    
    ; -----------------------------------------------------------------------
    ; Clean up and exit to DOS
    ; -----------------------------------------------------------------------
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
; check_keyboard - Handle keyboard input
; ============================================================================
; Returns: AL = 0xFF if exit requested, else 0
; ============================================================================
check_keyboard:
    push bx
    
    mov ah, 0x01
    int 0x16
    jz .no_key
    
    mov ah, 0x00
    int 0x16
    
    ; ESC - Exit
    cmp ah, 0x01
    jne .not_esc
    mov al, 0xFF
    jmp .done
    
.not_esc:
    ; P - Toggle PIT/Polling mode
    cmp al, 'p'
    je .toggle_pit
    cmp al, 'P'
    jne .not_p
.toggle_pit:
    xor byte [pit_mode], 1
    jmp .no_key
    
.not_p:
    ; V - Toggle VSYNC
    cmp al, 'v'
    je .toggle_vsync
    cmp al, 'V'
    jne .not_v
.toggle_vsync:
    xor byte [vsync_enabled], 1
    jmp .no_key
    
.not_v:
    ; + - Increase PIT count (slower = bars drift down)
    cmp al, '+'
    je .inc_pit
    cmp al, '='
    jne .not_plus
.inc_pit:
    inc word [pit_count]
    jmp .no_key
    
.not_plus:
    ; - - Decrease PIT count (faster = bars drift up)
    cmp al, '-'
    jne .no_key
    cmp word [pit_count], 50
    jbe .no_key               ; Prevent underflow below 50
    dec word [pit_count]
    
.no_key:
    xor al, al
    
.done:
    pop bx
    ret

; ============================================================================
; load_current_palette - Copy palette data to working buffer
; ============================================================================
load_current_palette:
    push ax
    push cx
    push si
    push di
    
    mov si, pal_fullrainbow
    mov di, color_table
    mov cx, 400
.copy:
    mov al, [si]
    mov [di], al
    inc si
    inc di
    loop .copy
    
    pop di
    pop si
    pop cx
    pop ax
    ret

; ============================================================================
; render_pit_frame - Render one frame using PIT interrupts
; ============================================================================
; This is the core PIT-timed rendering routine:
;   1. Reset scanline counter
;   2. Install our custom IRQ0 handler
;   3. Program PIT for scanline timing
;   4. Wait for 200 scanlines to complete
;   5. Restore original PIT and IRQ0
; ============================================================================
render_pit_frame:
    push ax
    push bx
    push cx
    push dx
    push es
    
    cli                         ; Disable interrupts during setup
    
    ; -----------------------------------------------------------------------
    ; Reset scanline counter and color pointer
    ; -----------------------------------------------------------------------
    mov word [scanline_count], 0
    mov word [color_offset], 0
    mov byte [frame_done], 0
    
    ; -----------------------------------------------------------------------
    ; Install our custom IRQ0 handler
    ; -----------------------------------------------------------------------
    xor ax, ax
    mov es, ax                  ; ES = 0 (IVT segment)
    mov word [es:0x08*4], irq0_handler      ; Set offset
    mov word [es:0x08*4+2], cs              ; Set segment
    
    ; -----------------------------------------------------------------------
    ; Program PIT Channel 0 for scanline timing
    ; -----------------------------------------------------------------------
    ; Command byte: 00 11 010 0 = 0x34
    ;   Bits 7-6: 00 = Select channel 0
    ;   Bits 5-4: 11 = Access mode: low byte then high byte
    ;   Bits 3-1: 010 = Mode 2 (rate generator)
    ;   Bit 0:    0 = Binary counting
    
    mov al, 0x34                ; Channel 0, lobyte/hibyte, mode 2, binary
    out PIT_COMMAND, al
    jmp short $+2               ; I/O delay
    
    mov ax, [pit_count]         ; Get current PIT count value
    out PIT_CH0_DATA, al        ; Low byte
    jmp short $+2
    mov al, ah
    out PIT_CH0_DATA, al        ; High byte
    
    ; -----------------------------------------------------------------------
    ; Enable interrupts and wait for frame to complete
    ; -----------------------------------------------------------------------
    sti
    
.wait_frame:
    cmp byte [frame_done], 0
    je .wait_frame              ; Spin until ISR sets frame_done
    
    cli                         ; Disable interrupts for cleanup
    
    ; -----------------------------------------------------------------------
    ; Restore original PIT settings (mode 3, count 65536)
    ; -----------------------------------------------------------------------
    mov al, 0x36                ; Channel 0, lobyte/hibyte, mode 3, binary
    out PIT_COMMAND, al
    jmp short $+2
    xor al, al                  ; Low byte (0 = 65536)
    out PIT_CH0_DATA, al
    jmp short $+2
    out PIT_CH0_DATA, al        ; High byte
    
    ; -----------------------------------------------------------------------
    ; Restore original IRQ0 handler
    ; -----------------------------------------------------------------------
    xor ax, ax
    mov es, ax
    mov ax, [old_irq0_off]
    mov [es:0x08*4], ax
    mov ax, [old_irq0_seg]
    mov [es:0x08*4+2], ax
    
    sti
    
    pop es
    pop dx
    pop cx
    pop bx
    pop ax
    ret

; ============================================================================
; irq0_handler - Custom IRQ0 Interrupt Service Routine
; ============================================================================
; This ISR fires once per scanline (~63.5µs intervals).
; It must be FAST - we only have about 80 cycles during HBLANK!
;
; What it does:
;   1. Save registers
;   2. Write new color to palette entry 0
;   3. Increment scanline counter
;   4. If 200 scanlines done, set frame_done flag
;   5. Send EOI to PIC
;   6. Restore registers and IRET
; ============================================================================
irq0_handler:
    push ax
    push bx
    push ds
    
    ; -----------------------------------------------------------------------
    ; Set up DS to access our data
    ; -----------------------------------------------------------------------
    mov ax, [cs:isr_data_seg]
    mov ds, ax
    
    ; -----------------------------------------------------------------------
    ; Check if we've done all scanlines
    ; -----------------------------------------------------------------------
    mov bx, [scanline_count]
    cmp bx, SCREEN_HEIGHT
    jae .done_frame
    
    ; -----------------------------------------------------------------------
    ; Write palette entry 0 with new color
    ; -----------------------------------------------------------------------
    mov al, 0x40                ; Select palette entry 0
    out PORT_PAL_ADDR, al
    
    mov bx, [color_offset]      ; BX = offset into color_table
    mov al, [color_table + bx]  ; Get R value
    out PORT_PAL_DATA, al
    mov al, [color_table + bx + 1] ; Get G<<4|B value
    out PORT_PAL_DATA, al
    
    ; -----------------------------------------------------------------------
    ; Advance to next scanline
    ; -----------------------------------------------------------------------
    add word [color_offset], 2
    inc word [scanline_count]
    jmp .send_eoi
    
.done_frame:
    mov byte [frame_done], 1    ; Signal main loop that frame is complete
    
.send_eoi:
    ; -----------------------------------------------------------------------
    ; Send End-Of-Interrupt to PIC
    ; -----------------------------------------------------------------------
    mov al, 0x20                ; EOI command
    out PIC_CMD, al
    
    pop ds
    pop bx
    pop ax
    iret

; ============================================================================
; render_polling_frame - Render using HSYNC polling (for comparison)
; ============================================================================
render_polling_frame:
    push ax
    push cx
    push dx
    push si
    
    cli
    
    xor si, si                  ; SI = offset into color_table
    mov cx, SCREEN_HEIGHT       ; CX = scanline counter
    mov dx, PORT_STATUS
    
.scanline_loop:
    ; Wait for HSYNC to go LOW
.wait_low:
    in al, dx
    test al, 0x01
    jnz .wait_low
    
    ; Wait for HSYNC to go HIGH (HBLANK begins)
.wait_high:
    in al, dx
    test al, 0x01
    jz .wait_high
    
    ; Write palette entry 0
    mov al, 0x40
    out PORT_PAL_ADDR, al
    mov al, [color_table + si]
    out PORT_PAL_DATA, al
    mov al, [color_table + si + 1]
    out PORT_PAL_DATA, al
    
    add si, 2
    loop .scanline_loop
    
    sti
    
    pop si
    pop dx
    pop cx
    pop ax
    ret

; ============================================================================
; wait_vblank - Wait for vertical blanking period
; ============================================================================
; The CRT draws 200 visible lines, then has a "vertical blanking" period
; while the beam returns from bottom to top. We synchronize to this to
; ensure our rendering starts at the top of the screen.
;
; PORT_STATUS bit 3: VSYNC (vertical sync)
;   - 0 = Beam is drawing visible lines
;   - 1 = Beam is in vertical blanking
;
; We wait for VSYNC to end, then wait for it to start again.
; This ensures we catch the beginning of the blanking period.
; ============================================================================
wait_vblank:
    ; Check if VSYNC waiting is enabled
    cmp byte [vsync_enabled], 0
    je .skip_vblank             ; Skip if disabled
    
    push ax
    push dx
    mov dx, PORT_STATUS
    
    ; Wait for VSYNC to end (if we're currently in VBLANK)
.wait_end:
    in al, dx
    test al, 0x08               ; Test bit 3 (VSYNC)
    jnz .wait_end               ; Loop while in VBLANK
    
    ; Wait for VSYNC to start (beam finished drawing visible area)
.wait_start:
    in al, dx
    test al, 0x08               ; Test bit 3 (VSYNC)
    jz .wait_start              ; Loop while drawing
    
    pop dx
    pop ax
.skip_vblank:
    ret

; ============================================================================
; clear_screen - Fill video memory with zeros (color index 0)
; ============================================================================
clear_screen:
    push ax
    push cx
    push di
    push es
    
    mov ax, VIDEO_SEG           ; Video memory segment
    mov es, ax
    xor di, di                  ; Start at offset 0
    mov cx, 8192                ; 16KB / 2 = 8192 words
    xor ax, ax                  ; Fill value = 0
    cld                         ; Direction = forward
    rep stosw                   ; Fill memory (fast block fill)
    
    pop es
    pop di
    pop cx
    pop ax
    ret

; ============================================================================
; DATA SECTION
; ============================================================================

; --- ISR Communication Variables ---
; These must be accessible from the ISR via CS-relative addressing
isr_data_seg:   dw 0            ; Data segment for ISR to use
scanline_count: dw 0            ; Current scanline being rendered
color_offset:   dw 0            ; Offset into color_table
frame_done:     db 0            ; Flag: 1 when 200 scanlines complete

; --- Original IRQ0 Vector ---
old_irq0_off:   dw 0            ; Original INT 08h offset
old_irq0_seg:   dw 0            ; Original INT 08h segment

; --- Configuration ---
pit_count:      dw PIT_SCANLINE_COUNT   ; Current PIT count (adjustable)
pit_mode:       db 1            ; 1 = PIT mode, 0 = polling mode
vsync_enabled:  db 1            ; 1 = wait for VSYNC

; ============================================================================
; PALETTE DATA - Full Rainbow (200 scanlines)
; ============================================================================
; Format: R (bits 0-2), G<<4|B (bits 4-6 | 0-2)
; Full spectrum: Red → Yellow → Green → Cyan → Blue → Magenta → Red

pal_fullrainbow:
    ; RED to YELLOW (33)
    db 7,0x00, 7,0x00, 7,0x00, 7,0x00, 7,0x10, 7,0x10, 7,0x10, 7,0x10
    db 7,0x20, 7,0x20, 7,0x20, 7,0x20, 7,0x30, 7,0x30, 7,0x30, 7,0x30
    db 7,0x40, 7,0x40, 7,0x40, 7,0x40, 7,0x50, 7,0x50, 7,0x50, 7,0x50
    db 7,0x60, 7,0x60, 7,0x60, 7,0x60, 7,0x70, 7,0x70, 7,0x70, 7,0x70
    db 7,0x70
    ; YELLOW to GREEN (33)
    db 7,0x70, 7,0x70, 7,0x70, 7,0x70, 6,0x70, 6,0x70, 6,0x70, 6,0x70
    db 5,0x70, 5,0x70, 5,0x70, 5,0x70, 4,0x70, 4,0x70, 4,0x70, 4,0x70
    db 3,0x70, 3,0x70, 3,0x70, 3,0x70, 2,0x70, 2,0x70, 2,0x70, 2,0x70
    db 1,0x70, 1,0x70, 1,0x70, 1,0x70, 0,0x70, 0,0x70, 0,0x70, 0,0x70
    db 0,0x70
    ; GREEN to CYAN (33)
    db 0,0x70, 0,0x70, 0,0x70, 0,0x70, 0,0x71, 0,0x71, 0,0x71, 0,0x71
    db 0,0x72, 0,0x72, 0,0x72, 0,0x72, 0,0x73, 0,0x73, 0,0x73, 0,0x73
    db 0,0x74, 0,0x74, 0,0x74, 0,0x74, 0,0x75, 0,0x75, 0,0x75, 0,0x75
    db 0,0x76, 0,0x76, 0,0x76, 0,0x76, 0,0x77, 0,0x77, 0,0x77, 0,0x77
    db 0,0x77
    ; CYAN to BLUE (33)
    db 0,0x77, 0,0x77, 0,0x77, 0,0x77, 0,0x67, 0,0x67, 0,0x67, 0,0x67
    db 0,0x57, 0,0x57, 0,0x57, 0,0x57, 0,0x47, 0,0x47, 0,0x47, 0,0x47
    db 0,0x37, 0,0x37, 0,0x37, 0,0x37, 0,0x27, 0,0x27, 0,0x27, 0,0x27
    db 0,0x17, 0,0x17, 0,0x17, 0,0x17, 0,0x07, 0,0x07, 0,0x07, 0,0x07
    db 0,0x07
    ; BLUE to MAGENTA (34)
    db 0,0x07, 0,0x07, 0,0x07, 0,0x07, 1,0x07, 1,0x07, 1,0x07, 1,0x07
    db 2,0x07, 2,0x07, 2,0x07, 2,0x07, 3,0x07, 3,0x07, 3,0x07, 3,0x07
    db 4,0x07, 4,0x07, 4,0x07, 4,0x07, 5,0x07, 5,0x07, 5,0x07, 5,0x07
    db 6,0x07, 6,0x07, 6,0x07, 6,0x07, 7,0x07, 7,0x07, 7,0x07, 7,0x07
    db 7,0x07, 7,0x07
    ; MAGENTA to RED (34)
    db 7,0x07, 7,0x07, 7,0x07, 7,0x07, 7,0x06, 7,0x06, 7,0x06, 7,0x06
    db 7,0x05, 7,0x05, 7,0x05, 7,0x05, 7,0x04, 7,0x04, 7,0x04, 7,0x04
    db 7,0x03, 7,0x03, 7,0x03, 7,0x03, 7,0x02, 7,0x02, 7,0x02, 7,0x02
    db 7,0x01, 7,0x01, 7,0x01, 7,0x01, 7,0x00, 7,0x00, 7,0x00, 7,0x00
    db 7,0x00, 7,0x00

; ============================================================================
; Working color table (copied from selected palette)
; ============================================================================
; This buffer holds the currently active palette data.
; Using a working buffer allows fast indexed access during the
; time-critical rendering loop.

color_table: times 400 db 0

; ============================================================================
; END OF PROGRAM
; ============================================================================
