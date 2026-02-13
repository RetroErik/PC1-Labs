; ============================================================================
; PITRAS2.asm - Multiple Palette Entries Per Scanline
; ============================================================================
;
; EDUCATIONAL DEMONSTRATION: How Many Palette Entries Can We Update Per Scanline?
;
; Building on pitras1.asm's success, this demo tests writing MULTIPLE palette
; entries during each scanline. The goal is to determine the practical limit
; for the V6355D - can we update 2, 4, 8, or even all 16 entries per line?
;
; TIMING BUDGET:
;   - HBLANK duration: ~10-12 µs (estimated)
;   - Each palette write: 3 OUTs = ~24-36 cycles = ~3-4.5 µs
;   - Theoretical max during HBLANK: 2-3 entries
;   - But with PIT timing, we can also write during active display
;     (may cause visual artifacts depending on timing)
;
; TEST APPROACH:
;   We'll write N palette entries per scanline, starting with 2 and allowing
;   the user to increase/decrease with keyboard. Visual artifacts will reveal
;   when we're exceeding safe limits.
;
; Written for NASM assembler
; Target: Olivetti Prodest PC1 with Yamaha V6355D
; CPU: NEC V40 @ 8 MHz
;
; By Retro Erik - 2026

; ============================================================================
; CONTROLS
; ============================================================================
;
;   SPACE: Continue after initial bar display
;   1-8  : Set number of palette entries per scanline (1-8)
;   , / . : Fine-tune PIT count
;   P    : Toggle PIT mode vs polling mode
;   V    : Toggle VSYNC waiting
;   ESC  : Exit to DOS
;
; ============================================================================

[BITS 16]
[ORG 0x100]

; ============================================================================
; HARDWARE PORT DEFINITIONS
; ============================================================================

PORT_MODE       equ 0xD8    ; Video mode (0x4A = 160x200x16)
PORT_STATUS     equ 0x3DA   ; Status register
PORT_PAL_ADDR   equ 0xDD    ; Palette address (short form)
PORT_PAL_DATA   equ 0xDE    ; Palette data (short form)

PIT_CH0_DATA    equ 0x40
PIT_COMMAND     equ 0x43
PIC_CMD         equ 0x20

; ============================================================================
; CONSTANTS
; ============================================================================

VIDEO_SEG           equ 0xB000  ; PC1 hidden mode video segment (not 0xB800!)
SCREEN_HEIGHT       equ 200
PIT_SCANLINE_COUNT  equ 76
MAX_ENTRIES         equ 8       ; Maximum entries to write per scanline

; ============================================================================
; MAIN PROGRAM
; ============================================================================
main:
    mov ax, cs
    mov [cs:isr_data_seg], ax
    
    ; Initialize state
    mov word [pit_count], PIT_SCANLINE_COUNT
    mov byte [pit_mode], 1
    mov byte [vsync_enabled], 1
    mov byte [entries_per_line], 4  ; Start with 4 entries per scanline
    
    ; Generate gradient palette data
    call generate_gradient_palette
    
    ; Save original IRQ0 vector
    xor ax, ax
    mov es, ax
    mov ax, [es:0x08*4]
    mov [old_irq0_off], ax
    mov ax, [es:0x08*4+2]
    mov [old_irq0_seg], ax
    
    ; Set up video mode
    mov ax, 0x0004
    int 0x10

    mov al, 0x4A
    out PORT_MODE, al
    jmp short $+2           ; I/O delay
    jmp short $+2
    
    ; Set border color to black
    xor al, al
    out 0xD9, al            ; PORT_COLOR
    jmp short $+2
    jmp short $+2
    
    ; Initialize palette with base colors
    call set_initial_palette
    
    ; Fill screen with pattern showing all 16 colors
    call fill_color_pattern
    
    ; Wait for SPACE to continue (verify bars look correct)
    call wait_for_space
    
    ; Main loop
.main_loop:
    call wait_vblank
    
    cmp byte [pit_mode], 0
    je .polling_mode
    
    call render_pit_frame
    jmp .check_input
    
.polling_mode:
    call render_polling_frame
    
.check_input:
    call check_keyboard
    cmp al, 0xFF
    jne .main_loop
    
    ; Clean up - restore default palette
    call restore_default_palette
    
    mov ax, 0x0003
    int 0x10
    mov ax, 0x4C00
    int 0x21

; ============================================================================
; generate_gradient_palette - Create gradient data for all entries
; ============================================================================
; We create a table where each scanline has different colors for entries 0-15.
; Format: For each scanline, 16 entries × 2 bytes (R, G<<4|B) = 32 bytes/line
; Total: 200 lines × 32 bytes = 6400 bytes (too big!)
;
; Instead, we'll use a simpler approach:
; - Base colors for entries 0-15 (static)
; - Per-scanline modifier (add to base colors to create gradient)
; ============================================================================
generate_gradient_palette:
    push ax
    push bx
    push cx
    push di
    
    ; Generate base colors for 16 entries (static part)
    ; Entry 0 = Red, 1 = Orange, 2 = Yellow, ... (rainbow spread)
    mov di, base_colors
    
    ; Entry 0: Pure Red
    mov byte [di], 7        ; R = 7
    mov byte [di+1], 0x00   ; G=0, B=0
    add di, 2
    
    ; Entry 1: Orange-Red
    mov byte [di], 7
    mov byte [di+1], 0x20
    add di, 2
    
    ; Entry 2: Orange
    mov byte [di], 7
    mov byte [di+1], 0x40
    add di, 2
    
    ; Entry 3: Yellow-Orange
    mov byte [di], 7
    mov byte [di+1], 0x60
    add di, 2
    
    ; Entry 4: Yellow
    mov byte [di], 7
    mov byte [di+1], 0x70
    add di, 2
    
    ; Entry 5: Yellow-Green
    mov byte [di], 5
    mov byte [di+1], 0x70
    add di, 2
    
    ; Entry 6: Green
    mov byte [di], 0
    mov byte [di+1], 0x70
    add di, 2
    
    ; Entry 7: Green-Cyan
    mov byte [di], 0
    mov byte [di+1], 0x73
    add di, 2
    
    ; Entry 8: Cyan
    mov byte [di], 0
    mov byte [di+1], 0x77
    add di, 2
    
    ; Entry 9: Cyan-Blue
    mov byte [di], 0
    mov byte [di+1], 0x47
    add di, 2
    
    ; Entry 10: Blue
    mov byte [di], 0
    mov byte [di+1], 0x07
    add di, 2
    
    ; Entry 11: Blue-Purple
    mov byte [di], 3
    mov byte [di+1], 0x07
    add di, 2
    
    ; Entry 12: Purple
    mov byte [di], 5
    mov byte [di+1], 0x05
    add di, 2
    
    ; Entry 13: Magenta
    mov byte [di], 7
    mov byte [di+1], 0x07
    add di, 2
    
    ; Entry 14: Pink
    mov byte [di], 7
    mov byte [di+1], 0x04
    add di, 2
    
    ; Entry 15: White
    mov byte [di], 7
    mov byte [di+1], 0x77
    
    ; Generate scanline modifiers (controls how colors shift per line)
    ; Simple: each scanline adds an offset that cycles through colors
    mov di, scanline_mod
    mov cx, 200
    xor al, al
.gen_mod:
    mov [di], al
    inc di
    add al, 1           ; Increment modifier each line (wraps at 256)
    loop .gen_mod
    
    pop di
    pop cx
    pop bx
    pop ax
    ret

; ============================================================================
; set_initial_palette - Write base_colors to hardware palette
; ============================================================================
; This initializes the 16 palette entries before we start the raster effect.
; Format: Write 0x40 to 0xDD, then 32 bytes to 0xDE, then 0x80 to 0xDD
; ============================================================================
set_initial_palette:
    push ax
    push cx
    push si
    
    cli                         ; Disable interrupts during palette write
    
    ; Enable palette write mode
    mov al, 0x40
    out PORT_PAL_ADDR, al
    jmp short $+2               ; I/O delay
    jmp short $+2
    
    ; Write 32 bytes of palette data
    mov si, base_colors
    mov cx, 32
.pal_loop:
    lodsb
    out PORT_PAL_DATA, al
    jmp short $+2               ; I/O delay
    loop .pal_loop
    
    ; Disable palette write mode
    jmp short $+2
    mov al, 0x80
    out PORT_PAL_ADDR, al
    jmp short $+2
    
    sti
    
    pop si
    pop cx
    pop ax
    ret

; ============================================================================
; fill_color_pattern - Fill screen with vertical stripes of all 16 colors
; ============================================================================
; Copied from working colorbars.asm
; Hidden mode (0x4A) uses INTERLEAVED memory at 0xB000:
;   - Even scanlines (0,2,4...): offset 0x0000 + (line/2)*80
;   - Odd scanlines (1,3,5...):  offset 0x2000 + (line/2)*80
; ============================================================================
fill_color_pattern:
    push ax
    push bx
    push cx
    push dx
    push si
    push di
    push es
    
    ; First clear the screen
    call clear_screen
    
    mov ax, VIDEO_SEG
    mov es, ax
    
    ; Draw all 200 rows
    xor si, si              ; SI = row counter (0-199)
    
.row_loop:
    ; Calculate base offset for this row
    ; Even rows: offset = (row/2) * 80
    ; Odd rows:  offset = 0x2000 + (row/2) * 80
    mov ax, si
    shr ax, 1               ; AX = row / 2
    mov bx, 80
    mul bx                  ; AX = (row/2) * 80
    mov di, ax
    test si, 1              ; Check if odd row
    jz .even_row
    add di, 0x2000          ; Odd rows start at 0x2000
.even_row:
    
    ; For each row, write bytes for the bar area
    ; 16 bars × 10 pixels = 160 pixels = 80 bytes
    xor bx, bx              ; BX = pixel position (0-159)
    
.pixel_loop:
    ; Calculate which color this pixel belongs to
    ; pixel / 10 = color index (0-15)
    mov ax, bx
    mov cl, 10              ; bar_width = 10
    xor ch, ch
    div cl                  ; AL = pixel / bar_width = color index (0-15)
    mov dl, al              ; DL = left pixel color
    
    ; Get right pixel color (pixel + 1)
    mov ax, bx
    inc ax
    div cl                  ; AL = (pixel+1) / bar_width
    
    ; DL = left color, AL = right color
    ; Combine: byte = (left << 4) | right
    shl dl, 4
    or dl, al
    
    ; Write byte to video memory
    mov [es:di], dl
    inc di
    
    ; Advance by 2 pixels
    add bx, 2
    cmp bx, 160
    jb .pixel_loop
    
    ; Next row
    inc si
    cmp si, 200
    jb .row_loop
    
    pop es
    pop di
    pop si
    pop dx
    pop cx
    pop bx
    pop ax
    ret

; ============================================================================
; clear_screen - Clear video memory to black (color 0)
; ============================================================================
clear_screen:
    push ax
    push cx
    push di
    push es
    
    mov ax, VIDEO_SEG
    mov es, ax
    xor di, di
    mov cx, 8192            ; 16KB = 8192 words
    xor ax, ax              ; Fill with 0x0000
    cld
    rep stosw
    
    pop es
    pop di
    pop cx
    pop ax
    ret

; ============================================================================
; render_pit_frame - Render using PIT interrupts (multi-entry version)
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
    
    ; Install custom IRQ0 handler
    xor ax, ax
    mov es, ax
    mov word [es:0x08*4], irq0_handler
    mov word [es:0x08*4+2], cs
    
    ; Program PIT for scanline timing
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
    
    ; Restore original PIT
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
; irq0_handler - Multi-entry palette update ISR
; ============================================================================
; This ISR writes multiple palette entries per scanline.
; The number of entries is controlled by [entries_per_line].
;
; For each entry, we need:
;   - Set palette address: 1 OUT
;   - Write R: 1 OUT
;   - Write G<<4|B: 1 OUT
; Total: 3 OUTs per entry
;
; With 8 entries: 24 OUTs per scanline
; ============================================================================
irq0_handler:
    push ax
    push bx
    push cx
    push si
    push ds
    
    mov ax, [cs:isr_data_seg]
    mov ds, ax
    
    ; Check if frame is complete
    mov bx, [scanline_count]
    cmp bx, SCREEN_HEIGHT
    jae .done_frame
    
    ; Get scanline modifier
    mov si, bx                  ; SI = scanline number
    mov al, [scanline_mod + si] ; AL = modifier for this line
    mov [current_mod], al       ; Save for use in write loop
    
    ; Write N palette entries
    mov cl, [entries_per_line]
    xor ch, ch                  ; CX = number of entries to write
    xor bx, bx                  ; BX = entry index (0-15)
    
.write_loop:
    ; Calculate palette address: 0x40 + entry number
    mov al, 0x40
    add al, bl
    out PORT_PAL_ADDR, al
    
    ; Get base color for this entry
    mov si, bx
    shl si, 1                   ; SI = entry * 2 (2 bytes per entry)
    
    ; Apply scanline modifier to R component
    mov al, [base_colors + si]  ; Get R
    add al, [current_mod]       ; Add modifier
    and al, 0x07                ; Mask to 3 bits
    out PORT_PAL_DATA, al
    
    ; Apply modifier to G|B
    mov al, [base_colors + si + 1]  ; Get G<<4|B
    ; Modify G (bits 4-6) and B (bits 0-2) by modifier
    mov ah, al
    and ah, 0x70                ; Isolate G
    shr ah, 4                   ; G in bits 0-2
    add ah, [current_mod]
    and ah, 0x07                ; Mask G to 3 bits
    shl ah, 4                   ; Back to bits 4-6
    
    and al, 0x07                ; Isolate B
    add al, [current_mod]
    and al, 0x07                ; Mask B to 3 bits
    or al, ah                   ; Combine G|B
    out PORT_PAL_DATA, al
    
    inc bx
    loop .write_loop
    
    inc word [scanline_count]
    jmp .send_eoi
    
.done_frame:
    mov byte [frame_done], 1
    
.send_eoi:
    mov al, 0x20
    out PIC_CMD, al
    
    pop ds
    pop si
    pop cx
    pop bx
    pop ax
    iret

; ============================================================================
; render_polling_frame - Polling mode for comparison
; ============================================================================
render_polling_frame:
    push ax
    push bx
    push cx
    push dx
    push si
    
    cli
    
    xor si, si                  ; Scanline counter
    mov dx, PORT_STATUS
    
.scanline_loop:
    cmp si, SCREEN_HEIGHT
    jae .done
    
    ; Wait for HSYNC LOW
.wait_low:
    in al, dx
    test al, 0x01
    jnz .wait_low
    
    ; Wait for HSYNC HIGH
.wait_high:
    in al, dx
    test al, 0x01
    jz .wait_high
    
    ; Write entries (same logic as ISR but in polling context)
    push dx
    
    mov al, [scanline_mod + si]
    mov [current_mod], al
    
    mov cl, [entries_per_line]
    xor ch, ch
    xor bx, bx
    
.poll_write_loop:
    mov al, 0x40
    add al, bl
    out PORT_PAL_ADDR, al
    
    push si
    mov si, bx
    shl si, 1
    
    mov al, [base_colors + si]
    add al, [current_mod]
    and al, 0x07
    out PORT_PAL_DATA, al
    
    mov al, [base_colors + si + 1]
    mov ah, al
    and ah, 0x70
    shr ah, 4
    add ah, [current_mod]
    and ah, 0x07
    shl ah, 4
    and al, 0x07
    add al, [current_mod]
    and al, 0x07
    or al, ah
    out PORT_PAL_DATA, al
    
    pop si
    inc bx
    loop .poll_write_loop
    
    pop dx
    inc si
    jmp .scanline_loop
    
.done:
    sti
    
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
    
    ; ESC - Exit
    cmp ah, 0x01
    jne .not_esc
    mov al, 0xFF
    jmp .done
    
.not_esc:
    ; 1-8 - Set number of entries per scanline
    cmp al, '1'
    jb .not_number
    cmp al, '8'
    ja .not_number
    sub al, '0'
    mov [entries_per_line], al
    jmp .no_key
    
.not_number:
    ; P - Toggle mode
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
    ; . - Increase PIT count
    cmp al, '.'
    jne .not_period
    inc word [pit_count]
    jmp .no_key
    
.not_period:
    ; , - Decrease PIT count
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
; wait_for_space - Wait for SPACE key to continue
; ============================================================================
wait_for_space:
    push ax
.wait_loop:
    mov ah, 0x00
    int 0x16                ; Wait for keypress
    cmp al, ' '             ; Space?
    jne .wait_loop          ; No, keep waiting
    pop ax
    ret

; ============================================================================
; wait_vblank
; ============================================================================
wait_vblank:
    cmp byte [vsync_enabled], 0
    je .skip
    
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
.skip:
    ret

; ============================================================================
; restore_default_palette - Reset palette to standard colors
; ============================================================================
restore_default_palette:
    push ax
    push cx
    
    ; Restore entries 0-15 to reasonable defaults
    mov cx, 16
    xor ah, ah          ; Entry counter
.restore_loop:
    mov al, 0x40
    add al, ah
    out PORT_PAL_ADDR, al
    
    mov al, ah          ; Simple: entry N = gray level N
    and al, 0x07
    out PORT_PAL_DATA, al
    mov al, ah
    shl al, 4
    or al, ah
    and al, 0x77
    out PORT_PAL_DATA, al
    
    inc ah
    loop .restore_loop
    
    pop cx
    pop ax
    ret

; ============================================================================
; DATA SECTION
; ============================================================================

isr_data_seg:       dw 0
scanline_count:     dw 0
frame_done:         db 0
current_mod:        db 0

old_irq0_off:       dw 0
old_irq0_seg:       dw 0

pit_count:          dw PIT_SCANLINE_COUNT
pit_mode:           db 1
vsync_enabled:      db 1
entries_per_line:   db 4        ; Number of palette entries per scanline (1-8)

; Base colors for 16 palette entries (2 bytes each = 32 bytes)
base_colors:        times 32 db 0

; Scanline modifier table (1 byte per scanline = 200 bytes)
scanline_mod:       times 200 db 0

; ============================================================================
; END OF PROGRAM
; ============================================================================
