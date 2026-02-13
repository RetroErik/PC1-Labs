; ============================================================================
; PITRAS3.asm - PIT-Driven Mid-Scanline Color Split (Proof of Concept)
; ============================================================================
;
; PURPOSE:
;   Prove that PIT interrupts can produce TWO different colors on a single
;   scanline by changing palette entry 0 mid-scanline.
;
; HOW IT WORKS:
;   PIT channel 0 fires IRQ0 once per scanline (~76 ticks). The ISR:
;     1. Writes BLUE (R=0,G=0,B=7) to palette entry 0
;     2. Executes a variable NOP+LOOP delay  (burns CPU cycles)
;     3. Writes RED  (R=7,G=0,B=0) to palette entry 0
;   Because the CRT beam is mid-scanline during step 2, the left portion
;   of the line renders blue and the right portion renders red.
;
; RESULTS:
;   SUCCESS - Two colors are clearly visible on the same scanlines.
;   The blue/red split point moves when the NOP delay is adjusted.
;   However, the split boundary jitters by ~4-8 pixels per frame due to
;   bus contention with the Yamaha V6355D video controller.
;
; LIMITATIONS:
;   - No hardware HSYNC reference available on the V6355D, so the ISR
;     fires at an approximate scanline boundary (PIT-derived).
;   - The V6355D steals bus cycles unpredictably to fetch VRAM, causing
;     the NOP delay to vary by a few cycles per scanline = jitter.
;   - The 8088MPH DRAM refresh trick (PIT CH1 18->19) does NOT apply:
;     the NEC V40 has integrated refresh logic, not PIT-driven.
;   - Pixel-stable mid-scanline splits would require reverse-engineering
;     the V6355D's bus access pattern or finding an undocumented sync
;     register.
;
; CONTROLS:
;   Right/Left : Adjust NOP delay by 1 (fine - moves split point)
;   +/-        : Adjust NOP delay by 10 (coarse)
;   .          : Increase PIT count (tune scanline interval)
;   ,          : Decrease PIT count
;   ESC        : Exit
;
; BASED ON: pitras1.asm (proven working PIT interrupt structure)
; SEE ALSO: pitras1 (1 color/scanline), pitras2 (multi-entry/scanline)
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
PIT_CH0_DATA    equ 0x40
PIT_COMMAND     equ 0x43
PIC_CMD         equ 0x20

; --- Constants ---
VIDEO_SEG       equ 0xB000
SCREEN_HEIGHT   equ 200
PIT_SCANLINE_COUNT equ 76

; ============================================================================
; MAIN - Copied from working pitras1.asm structure
; ============================================================================
main:
    mov ax, cs
    mov [cs:isr_data_seg], ax

    mov word [pit_count], PIT_SCANLINE_COUNT
    mov byte [nop_delay], 20

    ; Save original IRQ0 vector
    xor ax, ax
    mov es, ax
    mov ax, [es:0x08*4]
    mov [old_irq0_off], ax
    mov ax, [es:0x08*4+2]
    mov [old_irq0_seg], ax

    ; Turn off floppy motor (stops floppy light staying on)
    mov dx, 0x3F2
    mov al, 0x0C               ; motor off, controller+DMA enabled
    out dx, al

    ; Set video mode
    mov ax, 0x0004
    int 0x10
    mov al, 0x4A
    out PORT_MODE, al

    ; Clear screen (all pixels = palette entry 0)
    call clear_screen

    ; ---- Main loop ----
.main_loop:
    call wait_vblank
    call render_pit_frame

    call check_keyboard
    cmp al, 0xFF
    jne .main_loop

    ; Exit
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
; render_pit_frame - Identical structure to pitras1
; ============================================================================
render_pit_frame:
    push ax
    push bx
    push cx
    push dx
    push es

    cli

    mov word [scanline_count], 0
    mov byte [frame_done], 0

    ; Install ISR
    xor ax, ax
    mov es, ax
    mov word [es:0x08*4], irq0_handler
    mov word [es:0x08*4+2], cs

    ; Program PIT: channel 0, lobyte/hibyte, mode 2, binary
    mov al, 0x34
    out PIT_COMMAND, al
    jmp short $+2
    mov ax, [pit_count]
    out PIT_CH0_DATA, al
    jmp short $+2
    mov al, ah
    out PIT_CH0_DATA, al

    sti

.wait_frame:
    cmp byte [frame_done], 0
    je .wait_frame

    cli

    ; Restore PIT channel 0
    mov al, 0x36
    out PIT_COMMAND, al
    jmp short $+2
    xor al, al
    out PIT_CH0_DATA, al
    jmp short $+2
    out PIT_CH0_DATA, al

    ; Restore original IRQ0
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
; irq0_handler - Write BLUE, delay, write RED
; ============================================================================
; Same register save/restore pattern as pitras1's working ISR.
; Only difference: two palette writes with a delay between them.
; ============================================================================
irq0_handler:
    push ax
    push bx
    push cx
    push ds

    mov ax, [cs:isr_data_seg]
    mov ds, ax

    mov bx, [scanline_count]
    cmp bx, SCREEN_HEIGHT
    jae .done_frame

    ; ---- Write BLUE to palette entry 0 ----
    mov al, 0x40
    out PORT_PAL_ADDR, al
    xor al, al                 ; R = 0
    out PORT_PAL_DATA, al
    mov al, 0x07               ; G=0, B=7
    out PORT_PAL_DATA, al

    ; ---- Variable delay: CL loop iterations ----
    ; Each iteration ≈ 8 cycles on V40 (nop=3 + loop=5)
    ; Range 0-60 covers 0-480 cycles (most of a scanline)
    mov cl, [nop_delay]
    xor ch, ch
    jcxz .no_delay
.delay_loop:
    nop
    loop .delay_loop
.no_delay:

    ; ---- Write RED to palette entry 0 ----
    mov al, 0x40
    out PORT_PAL_ADDR, al
    mov al, 7                  ; R = 7
    out PORT_PAL_DATA, al
    xor al, al                 ; G=0, B=0
    out PORT_PAL_DATA, al

    inc word [scanline_count]
    jmp .send_eoi

.done_frame:
    mov byte [frame_done], 1

.send_eoi:
    mov al, 0x20
    out PIC_CMD, al

    pop ds
    pop cx
    pop bx
    pop ax
    iret

; ============================================================================
; wait_vblank - Same as pitras1
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
; clear_screen - Same as pitras1
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
    cmp byte [nop_delay], 80
    jae .no_key
    inc byte [nop_delay]
    jmp .no_key

.not_right:
    ; Left arrow: delay -1
    cmp ah, 0x4B
    jne .not_left
    cmp byte [nop_delay], 0
    je .no_key
    dec byte [nop_delay]
    jmp .no_key

.not_left:
    ; + : delay +10
    cmp al, '+'
    je .inc10
    cmp al, '='
    jne .not_plus
.inc10:
    cmp byte [nop_delay], 70
    jae .no_key
    add byte [nop_delay], 10
    jmp .no_key

.not_plus:
    ; - : delay -10
    cmp al, '-'
    jne .not_minus
    cmp byte [nop_delay], 10
    jb .no_key
    sub byte [nop_delay], 10
    jmp .no_key

.not_minus:
    ; . = increase PIT
    cmp al, '.'
    jne .not_period
    inc word [pit_count]
    jmp .no_key

.not_period:
    ; , = decrease PIT
    cmp al, ','
    jne .no_key
    cmp word [pit_count], 50
    jbe .no_key
    dec word [pit_count]

.no_key:
    xor al, al
.done:
    pop bx
    ret

; ============================================================================
; DATA
; ============================================================================
isr_data_seg:       dw 0
scanline_count:     dw 0
frame_done:         db 0
nop_delay:          db 20
pit_count:          dw PIT_SCANLINE_COUNT
old_irq0_off:       dw 0
old_irq0_seg:       dw 0
