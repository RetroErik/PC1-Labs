; ============================================================================
; DEMO8C.ASM - Circular Buffer Scroller with Register 0x65 (192 lines)
; Olivetti Prodest PC1 - V6355D 160x192x16 Hidden Graphics Mode
; Written for NASM - NEC V40 @ 8 MHz (80186 instruction set)
; By RetroErik - 2026
;
; ============================================================================
; TRUE CIRCULAR BUFFER — ZERO RELOADS, ZERO STUTTERING
; ============================================================================
;
; demo8b had THREE bugs causing stuttering:
;   1. CRTC R6 is a dummy register on V6355D (write does nothing)
;   2. New row was written at wrong VRAM offset (before display start)
;   3. Periodic 15KB reload every 3-6 scrolls caused visible multi-frame stutter
;
; FIX: The CRTC MA counter wraps within each 8K bank naturally (standard CGA
; hardware behavior). This means we can use a TRUE circular buffer — the CRTC
; reads seamlessly across the 8192-byte boundary. No reloads ever needed!
;
; Register 0x65 = 0x08 gives genuine 192-line mode (7680 bytes/bank used,
; 512 bytes gap). Every scroll writes exactly 160 bytes. On the rare case
; (~1 in 102 scrolls) where a row straddles the 8K boundary, we split the
; copy into two parts. Total cost: always 160 bytes. Always smooth.
;
; ============================================================================
; CIRCULAR BUFFER TECHNIQUE
; ============================================================================
;
; Treat VRAM as a circular (ring) buffer. Instead of copying all visible rows,
; only copy the NEW rows that scroll into view, then use R12/R13 to shift
; where the CRTC starts reading.
;
; How it works (scrolling DOWN by 2 rows):
;   1. Row 0-1 scrolls off top of screen (no longer visible)
;   2. Row 190-191 scrolls into view at bottom
;   3. Overwrite VRAM where rows 0-1 were stored with new rows
;   4. Set R12/R13 to start display at row 2's position
;   5. CRTC wraps around at 8KB boundary, making it seamless
;
; Memory comparison:
;   Demo7b: 15,360 bytes per scroll step (full viewport copy for 192 rows)
;   Demo8c: 160 bytes per scroll step (just 2 new rows) — EVERY scroll!
;   Speedup: ~96x faster than demo7b, consistent, no reloads
;
; VRAM layout (interlaced, 192-row display):
;   Even bank (0x0000-0x1FFF): rows 0,2,4,...190 = 96 rows × 80 = 7680 bytes
;   Odd bank  (0x2000-0x3FFF): rows 1,3,5,...191 = 96 rows × 80 = 7680 bytes
;   Gap: 512 bytes per bank (never displayed, used as write-ahead area)
;
; TRUE CIRCULAR BUFFER:
;   CRTC MA counter wraps at 8K bank boundary (standard 6845/CGA behavior).
;   crtc_start_addr advances by 80 each scroll, wrapping with & 0x1FFF.
;   New row is written at (crtc_start + 7680) & 0x1FFF — always in the gap.
;   If the 80-byte write crosses 8192, it's split into two copies.
;   No reloads, no stuttering, no limit on consecutive scrolls.
;
; ============================================================================
; CONTROLS
; ============================================================================
;   UP/DOWN arrows or <,> = Manual scroll (2 rows per step)
;   SPACE = Toggle auto-scroll (bounces up and down)
;   V = Toggle VSync wait
;   R = Reset to initial view (scroll position 0)
;   ESC/Q = Exit
;
; ============================================================================
; CHANGES FROM DEMO8B
; ============================================================================
;   - Register 0x65 = 0x08 for genuine 192-line mode (replaces broken R6)
;   - TRUE circular buffer: CRTC MA wraps at 8K, zero reloads needed
;   - Write destination: (crtc_start + BANK_USED) & 0x1FFF with split copy
;   - Removed reload_viewport entirely — no more 15KB stutter
;   - Word-wide CRTC writes (out dx, ax) for atomic R12/R13 updates
;   - Palette session close (0x80 → 0x3DD) after register 0x65 write
;   - Removed broken CRTC R6 write
;
; ============================================================================

[BITS 16]
[CPU 186]
[ORG 0x100]

; ============================================================================
; Constants
; ============================================================================

VIDEO_SEG       equ 0xB000
BYTES_PER_LINE  equ 80
BANK_SIZE       equ 8192        ; 8KB per bank (hardware size)
DISPLAY_ROWS    equ 192         ; 192 visible rows (register 0x65 = 0x08)
ROWS_PER_BANK   equ 96          ; 96 rows × 80 = 7680 bytes per bank
BANK_USED       equ 7680        ; 96 rows × 80 bytes (display area)
BANK_MASK       equ 0x1FFF      ; 8191 — for wrapping within 8K bank
VRAM_SIZE       equ 15360       ; 192 rows × 80 bytes
MAX_IMAGE_HEIGHT equ 800        ; Maximum height: 800×80 = 64000 bytes
STACK_RESERVE   equ 64          ; Paragraphs reserved for stack (1KB)
SCROLL_STEP     equ 2           ; Must be 2 to keep bank alignment
FRAME_DELAY     equ 1           ; VSync waits between frames

; V6355D I/O Ports
PORT_REG_ADDR   equ 0x3DD
PORT_REG_DATA   equ 0x3DE
PORT_MODE       equ 0x3D8
PORT_COLOR      equ 0x3D9
PORT_STATUS     equ 0x3DA
PORT_CRTC_ADDR  equ 0x3D4
PORT_CRTC_DATA  equ 0x3D5

; CRTC registers
CRTC_START_HIGH equ 12          ; Start Address High (R12)
CRTC_START_LOW  equ 13          ; Start Address Low (R13)

; Register 0x65 values
REG65_192       equ 0x08        ; PAL, 192 lines, CRT (bits 0-1 = 00)
REG65_200       equ 0x09        ; PAL, 200 lines, CRT (bits 0-1 = 01, default)

; BMP file header offsets
BMP_SIGNATURE   equ 0
BMP_DATA_OFFSET equ 10
BMP_WIDTH       equ 18
BMP_HEIGHT      equ 22
BMP_BPP         equ 28
BMP_COMPRESSION equ 30

; ============================================================================
; Main
; ============================================================================

main:
    call shrink_memory_block
    
    ; Parse command line
    mov si, 0x81
.skip_spaces:
    lodsb
    cmp al, ' '
    je .skip_spaces
    cmp al, 0x0D
    je .show_usage
    dec si
    mov [filename_ptr], si
    
.find_end:
    lodsb
    cmp al, ' '
    je .terminate
    cmp al, 0x0D
    je .terminate
    jmp .find_end
.terminate:
    mov byte [si-1], 0
    jmp .open_file

.show_usage:
    mov dx, msg_usage
    mov ah, 0x09
    int 0x21
    mov ax, 0x4C00
    int 0x21

.open_file:
    mov dx, [filename_ptr]
    mov ax, 0x3D00
    int 0x21
    jc .file_error
    mov [file_handle], ax
    
    mov bx, ax
    mov dx, bmp_header
    mov cx, 118
    mov ah, 0x3F
    int 0x21
    jc .file_error
    
    cmp word [bmp_header + BMP_SIGNATURE], 0x4D42
    jne .not_bmp
    cmp word [bmp_header + BMP_BPP], 4
    jne .wrong_format
    cmp word [bmp_header + BMP_COMPRESSION], 0
    jne .wrong_format
    
    mov ax, [bmp_header + BMP_WIDTH]
    mov [image_width], ax
    cmp ax, 160
    je .width_ok
    cmp ax, 320
    jne .wrong_size
    mov byte [downsample_flag], 1
.width_ok:
    
    mov ax, [bmp_header + BMP_HEIGHT]
    cmp ax, DISPLAY_ROWS        ; Minimum 192 rows
    jb .wrong_size
    cmp ax, MAX_IMAGE_HEIGHT
    ja .wrong_size
    mov [image_height], ax
    
    ; Seek to pixel data
    mov bx, [file_handle]
    mov dx, [bmp_header + BMP_DATA_OFFSET]
    mov cx, [bmp_header + BMP_DATA_OFFSET + 2]
    mov ax, 0x4200
    int 0x21
    
    ; Decode BMP to RAM buffer (interlaced format)
    call decode_bmp
    
    mov bx, [file_handle]
    mov ah, 0x3E
    int 0x21
    
    call enable_graphics_mode
    call set_bmp_palette
    
    ; Calculate max scroll row (image_height - DISPLAY_ROWS)
    mov ax, [image_height]
    sub ax, DISPLAY_ROWS        ; 192 rows displayed
    jns .has_scroll_range
    xor ax, ax
.has_scroll_range:
    mov [max_scroll_row], ax
    
    ; Initialize circular buffer state
    call reset_scroll
    
    ; Enable video
    mov dx, PORT_MODE
    mov al, 0x4A
    out dx, al
    
    ; ========================================================================
    ; Main loop
    ; ========================================================================
.main_loop:
    cmp byte [auto_scroll], 0
    jne .do_auto_scroll
    
    mov ah, 0x01
    int 0x16
    jz .main_loop
    jmp .handle_key

.do_auto_scroll:
    mov ah, 0x01
    int 0x16
    jz .auto_step
    
.handle_key:
    xor ah, ah
    int 0x16
    
    cmp al, 0x1B
    je .exit
    cmp al, 'q'
    je .exit
    cmp al, 'Q'
    je .exit
    
    cmp al, ' '
    je .toggle_auto
    
    cmp al, 'V'
    je .toggle_vsync
    cmp al, 'v'
    je .toggle_vsync
    
    cmp al, 'R'
    je .do_reset
    cmp al, 'r'
    je .do_reset
    
    cmp ah, 0x48            ; Up arrow
    je .scroll_up
    cmp al, ','
    je .scroll_up
    cmp al, '<'
    je .scroll_up
    
    cmp ah, 0x50            ; Down arrow
    je .scroll_down
    cmp al, '.'
    je .scroll_down
    cmp al, '>'
    je .scroll_down
    
    jmp .main_loop

.toggle_auto:
    xor byte [auto_scroll], 1
    jmp .main_loop

.toggle_vsync:
    xor byte [vsync_enabled], 1
    jmp .main_loop

.do_reset:
    call reset_scroll
    jmp .main_loop

.auto_step:
    cmp byte [vsync_enabled], 0
    je .skip_vsync
    mov cx, FRAME_DELAY
.delay_loop:
    call wait_vsync
    loop .delay_loop
.skip_vsync:
    
    mov ax, [scroll_row]
    cmp byte [scroll_dir], 0
    jne .auto_up
    
    ; Moving down
    add ax, SCROLL_STEP
    cmp ax, [max_scroll_row]
    jbe .auto_do_scroll_down
    mov ax, [max_scroll_row]
    mov byte [scroll_dir], 1
    jmp .main_loop
    
.auto_do_scroll_down:
    call scroll_down_circular
    jmp .main_loop
    
.auto_up:
    sub ax, SCROLL_STEP
    jns .auto_do_scroll_up
    xor ax, ax
    mov byte [scroll_dir], 0
    jmp .main_loop
    
.auto_do_scroll_up:
    call scroll_up_circular
    jmp .main_loop

.scroll_up:
    mov byte [auto_scroll], 0
    mov ax, [scroll_row]
    cmp ax, 0
    je .main_loop           ; Already at top
    call scroll_up_circular
    jmp .main_loop

.scroll_down:
    mov byte [auto_scroll], 0
    mov ax, [scroll_row]
    cmp ax, [max_scroll_row]
    jae .main_loop          ; Already at bottom
    call scroll_down_circular
    jmp .main_loop

.exit:
    mov ax, [image_buffer_seg]
    or ax, ax
    jz .no_free
    mov es, ax
    mov ah, 0x49
    int 0x21
.no_free:
    
    ; Reset CRTC start address to 0
    xor ax, ax
    call set_crtc_start_address
    
    ; Restore register 0x65 to default 200-line mode
    mov dx, PORT_REG_ADDR
    mov al, 0x65
    out dx, al
    mov dx, PORT_REG_DATA
    mov al, REG65_200           ; 0x09 = PAL, 200 lines, CRT
    out dx, al
    ; Close palette session to prevent DAC corruption
    mov dx, PORT_REG_ADDR
    mov al, 0x80
    out dx, al
    
    call set_cga_palette
    
    mov dx, PORT_MODE
    mov al, 0x28
    out dx, al
    mov ax, 0x0003
    int 0x10
    mov ax, 0x4C00
    int 0x21

.file_error:
    mov dx, msg_file_err
    jmp .error_exit
.not_bmp:
    mov dx, msg_not_bmp
    jmp .error_exit
.wrong_format:
    mov dx, msg_format
    jmp .error_exit
.wrong_size:
    mov dx, msg_size
.error_exit:
    mov ah, 0x09
    int 0x21
    mov ax, 0x4C01
    int 0x21

; ============================================================================
; reset_scroll - Reset to initial state, copy first 192 rows to VRAM
; Clears VRAM to black first, then fills from offset 0. crtc_start = 0.
; ============================================================================
reset_scroll:
    pusha
    push ds
    push es
    
    ; Reset scroll position
    mov word [scroll_row], 0
    mov word [crtc_start_addr], 0
    
    mov ax, VIDEO_SEG
    mov es, ax
    
    ; Clear entire even bank to black (including gap area)
    xor ax, ax
    xor di, di
    mov cx, BANK_SIZE / 2       ; 4096 words = 8192 bytes
    cld
    rep stosw
    
    ; Clear entire odd bank to black
    mov di, 0x2000
    mov cx, BANK_SIZE / 2
    rep stosw
    
    ; Now copy image data
    mov ax, [image_buffer_seg]
    mov ds, ax
    
    ; Copy even rows (0,2,4...190) to VRAM bank 0 at offset 0
    xor si, si                  ; Start of RAM buffer
    xor di, di                  ; VRAM offset 0
    mov cx, BANK_USED / 2       ; 96 rows × 80 bytes / 2 = 3840 words
    rep movsw
    
    ; Copy odd rows (1,3,5...191) to VRAM bank 1 at offset 0x2000
    mov si, [cs:odd_bank_offset]
    mov di, 0x2000
    mov cx, BANK_USED / 2       ; 3840 words
    rep movsw
    
    ; Set CRTC start address to 0
    xor ax, ax
    call set_crtc_start_address
    
    pop es
    pop ds
    popa
    ret

; ============================================================================
; copy_row_wrapped - Copy 80 bytes from DS:SI to ES:bank with 8K wrapping
;
; Input:  DS:SI = source data (80 bytes)
;         DI = bank-relative destination offset (0..8191), may wrap past 8K
;         BP = bank base (0x0000 for even, 0x2000 for odd)
; Output: SI advanced by 80
; Destroys: AX, CX, DI
; ============================================================================
copy_row_wrapped:
    mov ax, di
    add ax, BYTES_PER_LINE      ; dest + 80
    cmp ax, BANK_SIZE           ; Does write cross the 8K boundary?
    jbe .no_wrap
    
    ; === SPLIT COPY: row straddles the 8K bank boundary ===
    ; First part: from dest to end of bank
    mov cx, BANK_SIZE
    sub cx, di                  ; CX = bytes to end of bank (always even)
    push cx                     ; save first part size
    shr cx, 1                   ; convert to words
    add di, bp                  ; absolute VRAM address = bank_base + offset
    rep movsw
    
    ; Second part: from start of bank for remaining bytes
    pop cx                      ; first part byte count
    neg cx
    add cx, BYTES_PER_LINE      ; CX = 80 - first_part = remaining bytes
    shr cx, 1                   ; words
    mov di, bp                  ; dest = bank start (0x0000 or 0x2000)
    rep movsw
    ret
    
.no_wrap:
    ; Normal case: entire row fits without wrapping
    add di, bp                  ; absolute VRAM address
    mov cx, BYTES_PER_LINE / 2  ; 40 words
    rep movsw
    ret

; ============================================================================
; scroll_down_circular - Scroll down by 2 rows using true circular buffer
;
; Every scroll: write 2 new rows (160 bytes) + update R12/R13. No reloads!
; New bottom row is written at (crtc_start + BANK_USED) & BANK_MASK.
; crtc_start advances by 80 and wraps with & BANK_MASK.
; CRTC hardware wraps MA counter within each 8K bank naturally.
; ============================================================================
scroll_down_circular:
    pusha
    push ds
    push es
    
    ; Update scroll position
    add word [scroll_row], SCROLL_STEP
    
    ; The new rows to display are at (scroll_row + DISPLAY_ROWS - 2)
    ; These scroll into view at the bottom of the viewport
    mov ax, [scroll_row]
    add ax, DISPLAY_ROWS - 2    ; 190 for 192-row display
    mov [temp_row], ax
    
    ; Calculate source offset in RAM for new even row: (row/2) * 80
    mov ax, [temp_row]
    shr ax, 1
    mov bx, BYTES_PER_LINE
    mul bx
    mov [temp_src_even], ax
    
    ; Calculate source for odd row
    mov ax, [temp_row]
    inc ax
    shr ax, 1
    mov bx, BYTES_PER_LINE
    mul bx
    add ax, [odd_bank_offset]
    mov [temp_src_odd], ax
    
    ; Calculate write destination: (crtc_start + BANK_USED) & BANK_MASK
    ; This is the slot right after the last visible row (in the gap area).
    ; After advancing crtc_start by 80, this becomes the new last visible row.
    mov ax, [crtc_start_addr]
    add ax, BANK_USED
    and ax, BANK_MASK           ; Wrap within 8K bank
    mov [temp_dest], ax
    
    ; Calculate new CRTC start: (crtc_start + 80) & BANK_MASK
    mov ax, [crtc_start_addr]
    add ax, BYTES_PER_LINE
    and ax, BANK_MASK
    mov [temp_new_crtc], ax
    
    ; === WAIT FOR VSYNC - do all writes during vertical blank ===
    mov dx, PORT_STATUS
.wait_not_vsync_down:
    in al, dx
    test al, 8
    jnz .wait_not_vsync_down
.wait_vsync_down:
    in al, dx
    test al, 8
    jz .wait_vsync_down
    
    ; === NOW IN VBLANK - do everything quickly ===
    mov ax, [image_buffer_seg]
    mov ds, ax
    mov ax, VIDEO_SEG
    mov es, ax
    cld
    
    ; Copy new even row to even bank (bank base = 0x0000)
    mov si, [cs:temp_src_even]
    mov di, [cs:temp_dest]
    xor bp, bp                  ; BP = 0x0000 (even bank base)
    call copy_row_wrapped
    
    ; Copy new odd row to odd bank (bank base = 0x2000)
    mov si, [cs:temp_src_odd]
    mov di, [cs:temp_dest]      ; Same bank-relative offset
    mov bp, 0x2000              ; BP = 0x2000 (odd bank base)
    call copy_row_wrapped
    
    ; Update CRTC start address (still in vblank)
    mov ax, [cs:temp_new_crtc]
    mov [cs:crtc_start_addr], ax
    
    ; Convert byte offset to word offset for CRTC
    shr ax, 1
    mov bx, ax
    
    ; Word-wide CRTC write: R12 (start address high)
    mov ah, bh
    mov al, CRTC_START_HIGH
    mov dx, PORT_CRTC_ADDR
    out dx, ax
    
    ; Word-wide CRTC write: R13 (start address low)
    mov ah, bl
    mov al, CRTC_START_LOW
    out dx, ax

.scroll_done:
    pop es
    pop ds
    popa
    ret

; ============================================================================
; scroll_up_circular - Scroll up by 2 rows using true circular buffer
;
; New top row is written at (crtc_start - 80) & BANK_MASK.
; crtc_start retreats by 80 and wraps with & BANK_MASK.
; ============================================================================
scroll_up_circular:
    pusha
    push ds
    push es
    
    ; Update scroll position
    sub word [scroll_row], SCROLL_STEP
    
    ; The new rows to display are at scroll_row and scroll_row+1
    ; These scroll into view at the top of the viewport
    mov ax, [scroll_row]
    mov [temp_row], ax
    
    ; Calculate source offset in RAM for new even row
    mov ax, [temp_row]
    shr ax, 1
    mov bx, BYTES_PER_LINE
    mul bx
    mov [temp_src_even], ax
    
    ; Calculate source for odd row
    mov ax, [temp_row]
    inc ax
    shr ax, 1
    mov bx, BYTES_PER_LINE
    mul bx
    add ax, [odd_bank_offset]
    mov [temp_src_odd], ax
    
    ; Calculate new CRTC start and write destination:
    ; (crtc_start - 80) & BANK_MASK — new top row goes at new crtc position
    mov ax, [crtc_start_addr]
    sub ax, BYTES_PER_LINE
    and ax, BANK_MASK           ; Wrap within 8K bank (handles underflow)
    mov [temp_new_crtc], ax
    mov [temp_dest], ax         ; Write destination = new crtc start
    
    ; === WAIT FOR VSYNC - do all writes during vertical blank ===
    mov dx, PORT_STATUS
.wait_not_vsync_up:
    in al, dx
    test al, 8
    jnz .wait_not_vsync_up
.wait_vsync_up:
    in al, dx
    test al, 8
    jz .wait_vsync_up
    
    ; === NOW IN VBLANK - do everything quickly ===
    mov ax, [image_buffer_seg]
    mov ds, ax
    mov ax, VIDEO_SEG
    mov es, ax
    cld
    
    ; Copy new even row to even bank
    mov si, [cs:temp_src_even]
    mov di, [cs:temp_dest]
    xor bp, bp                  ; BP = 0x0000 (even bank base)
    call copy_row_wrapped
    
    ; Copy new odd row to odd bank
    mov si, [cs:temp_src_odd]
    mov di, [cs:temp_dest]
    mov bp, 0x2000              ; BP = 0x2000 (odd bank base)
    call copy_row_wrapped
    
    ; Update CRTC start address (still in vblank)
    mov ax, [cs:temp_new_crtc]
    mov [cs:crtc_start_addr], ax
    
    ; Convert byte offset to word offset for CRTC
    shr ax, 1
    mov bx, ax
    
    ; Word-wide CRTC write: R12 (start address high)
    mov ah, bh
    mov al, CRTC_START_HIGH
    mov dx, PORT_CRTC_ADDR
    out dx, ax
    
    ; Word-wide CRTC write: R13 (start address low)
    mov ah, bl
    mov al, CRTC_START_LOW
    out dx, ax

.scroll_up_done:
    pop es
    pop ds
    popa
    ret

; ============================================================================
; set_crtc_start_address - Set R12/R13 from byte offset in AX
; Uses word-wide out dx,ax for atomic register updates
; Waits for vertical retrace to prevent flicker
; ============================================================================
set_crtc_start_address:
    push ax
    push bx
    push dx
    
    ; Convert byte offset to word offset (CRTC counts words, not bytes)
    shr ax, 1
    mov bx, ax                 ; BH = high byte, BL = low byte
    
    ; Wait for vertical retrace before updating CRTC
    ; This prevents flicker by ensuring we update during blanking
    mov dx, PORT_STATUS
.wait_not_vsync:
    in al, dx
    test al, 8              ; Bit 3 = vertical retrace
    jnz .wait_not_vsync     ; Wait until NOT in retrace
.wait_vsync:
    in al, dx
    test al, 8
    jz .wait_vsync          ; Wait until IN retrace
    
    ; Now in vertical blank - atomic CRTC update via word-wide writes
    ; Write R12 (high byte of start address)
    mov ah, bh                 ; AH = R12 data
    mov al, CRTC_START_HIGH    ; AL = register index 12
    mov dx, PORT_CRTC_ADDR
    out dx, ax                 ; Writes index to 0x3D4, data to 0x3D5
    
    ; Write R13 (low byte of start address)
    mov ah, bl                 ; AH = R13 data
    mov al, CRTC_START_LOW     ; AL = register index 13
    out dx, ax                 ; Writes index to 0x3D4, data to 0x3D5
    
    pop dx
    pop bx
    pop ax
    ret

; ============================================================================
; wait_vsync
; ============================================================================
wait_vsync:
    push ax
    push dx
    mov dx, PORT_STATUS
.wait_end:
    in al, dx
    test al, 8
    jnz .wait_end
.wait_start:
    in al, dx
    test al, 8
    jz .wait_start
    pop dx
    pop ax
    ret

; ============================================================================
; enable_graphics_mode - Set up 160×192×16 mode using register 0x65
;
; Uses register 0x65 = 0x08 for genuine 192-line mode.
; R6 (Vertical Displayed) is NOT written — it's a dummy on the V6355D.
; Register 0x65 must be written BEFORE palette setup.
; ============================================================================
enable_graphics_mode:
    push ax
    push dx
    
    ; Register 0x65 = 0x08: PAL, 192 lines, CRT
    ; Bits 0-1 = 00 → 192 lines (96 character rows per bank)
    ; Bit 3 = 1 → PAL/50Hz
    ; This genuinely reduces the display to 192 lines, giving 512 bytes headroom
    mov dx, PORT_REG_ADDR
    mov al, 0x65
    out dx, al
    jmp short $+2
    mov dx, PORT_REG_DATA
    mov al, REG65_192           ; 0x08 = 192 lines
    out dx, al
    jmp short $+2
    
    ; Close palette session to prevent DAC corruption
    ; (register write via 0x3DD may leave address pointer in palette range)
    mov dx, PORT_REG_ADDR
    mov al, 0x80
    out dx, al
    jmp short $+2
    
    ; Mode register
    mov dx, PORT_MODE
    mov al, 0x4A
    out dx, al
    jmp short $+2
    
    ; Border = black
    mov dx, PORT_COLOR
    xor al, al
    out dx, al
    
    pop dx
    pop ax
    ret

; ============================================================================
; shrink_memory_block
; ============================================================================
shrink_memory_block:
    push ax
    push bx
    push es
    
    mov ax, cs
    mov es, ax
    mov bx, end_program + 0x100
    add bx, 15
    shr bx, 4
    add bx, STACK_RESERVE
    
    mov ah, 0x4A
    int 0x21
    
    pop es
    pop bx
    pop ax
    ret

; ============================================================================
; decode_bmp - Allocate RAM and read BMP to interlaced buffer
; ============================================================================
decode_bmp:
    pusha
    push es
    
    mov ax, [image_width]
    inc ax
    shr ax, 1
    add ax, 3
    and ax, 0xFFFC
    mov [bytes_per_row], ax
    
    mov ax, [image_height]
    shr ax, 1
    mov bx, BYTES_PER_LINE
    mul bx
    mov [odd_bank_offset], ax
    
    mov ax, [image_height]
    mov bx, BYTES_PER_LINE
    mul bx
    mov [image_size_bytes], ax
    
    mov bx, ax
    add bx, 15
    shr bx, 4
    mov ah, 0x48
    int 0x21
    jc .alloc_error
    mov [image_buffer_seg], ax
    
    mov ax, [image_height]
    dec ax
    mov [current_row], ax
    
.row_loop:
    mov ax, [current_row]
    mov bx, ax
    shr ax, 1
    mov dx, BYTES_PER_LINE
    mul dx
    mov di, ax
    test bx, 1
    jz .even_row
    add di, [odd_bank_offset]
.even_row:
    
    mov bx, [file_handle]
    mov dx, row_buffer
    mov cx, [bytes_per_row]
    mov ah, 0x3F
    int 0x21
    jc .decode_done
    or ax, ax
    jz .decode_done
    
    mov es, [image_buffer_seg]
    
    cmp byte [downsample_flag], 0
    je .no_downsample
    
    mov si, row_buffer
    mov cx, 80
.ds_loop:
    lodsb
    and al, 0xF0
    mov ah, al
    lodsb
    shr al, 4
    or al, ah
    stosb
    loop .ds_loop
    jmp .row_done
    
.no_downsample:
    mov si, row_buffer
    mov cx, 80
    rep movsb
    
.row_done:
    dec word [current_row]
    cmp word [current_row], 0xFFFF
    jne .row_loop
    
.decode_done:
    pop es
    popa
    ret

.alloc_error:
    mov dx, msg_mem_err
    mov ah, 0x09
    int 0x21
    mov ax, 0x4C01
    int 0x21

; ============================================================================
; set_bmp_palette
; ============================================================================
set_bmp_palette:
    pusha
    cli
    
    mov dx, PORT_REG_ADDR
    mov al, 0x40
    out dx, al
    jmp short $+2
    
    mov si, bmp_header + 54
    mov cx, 16
    mov dx, PORT_REG_DATA
    
.pal_loop:
    lodsb
    mov bl, al
    lodsb
    mov bh, al
    lodsb
    shr al, 5
    out dx, al
    jmp short $+2
    
    mov al, bh
    and al, 0xE0
    shr al, 1
    mov ah, al
    mov al, bl
    shr al, 5
    or al, ah
    out dx, al
    jmp short $+2
    
    lodsb
    loop .pal_loop
    
    mov dx, PORT_REG_ADDR
    mov al, 0x80
    out dx, al
    
    sti
    popa
    ret

; ============================================================================
; set_cga_palette
; ============================================================================
set_cga_palette:
    pusha
    cli
    
    mov dx, PORT_REG_ADDR
    mov al, 0x40
    out dx, al
    jmp short $+2
    
    mov si, cga_colors
    mov cx, 32
    mov dx, PORT_REG_DATA
    
.cga_loop:
    lodsb
    out dx, al
    jmp short $+2
    loop .cga_loop
    
    mov dx, PORT_REG_ADDR
    mov al, 0x80
    out dx, al
    
    sti
    popa
    ret

; ============================================================================
; Data
; ============================================================================

msg_usage       db 'DEMO8C - 192-Line Circular Buffer Scroller (reg 0x65 fix)', 13, 10
                db 'Usage: DEMO8C filename.bmp', 13, 10
                db 'BMP must be 160 wide, 192-800 tall, 4-bit', 13, 10
                db 'UP/DOWN = scroll, SPACE = auto, V = VSync, R = Reset', 13, 10
                db 'True circular buffer: 160 bytes/scroll, zero reloads!', 13, 10
                db 'ESC to exit', 13, 10, '$'

msg_file_err    db 'Error: Cannot open file', 13, 10, '$'
msg_not_bmp     db 'Error: Not a valid BMP file', 13, 10, '$'
msg_format      db 'Error: Must be 4-bit uncompressed BMP', 13, 10, '$'
msg_size        db 'Error: Must be 160 wide, 192-800 tall', 13, 10, '$'
msg_mem_err     db 'Error: Cannot allocate memory', 13, 10, '$'

cga_colors:
    db 0x00, 0x00
    db 0x00, 0x05
    db 0x00, 0x50
    db 0x00, 0x55
    db 0x05, 0x00
    db 0x05, 0x05
    db 0x05, 0x20
    db 0x05, 0x55
    db 0x02, 0x22
    db 0x02, 0x27
    db 0x02, 0x72
    db 0x02, 0x77
    db 0x07, 0x22
    db 0x07, 0x27
    db 0x07, 0x70
    db 0x07, 0x77

filename_ptr    dw 0
file_handle     dw 0
image_width     dw 0
image_height    dw 0
bytes_per_row   dw 0
current_row     dw 0
downsample_flag db 0

; Scrolling state
scroll_row      dw 0            ; Current top row in image (0 to max_scroll_row)
max_scroll_row  dw 0            ; Maximum scroll position
image_buffer_seg dw 0           ; Allocated buffer segment
odd_bank_offset dw 0            ; Offset to odd rows in buffer
image_size_bytes dw 0

; Circular buffer state
crtc_start_addr dw 0            ; Current CRTC start address (byte offset in VRAM)

; Temporary variables for scroll routines
temp_row        dw 0            ; Current image row being processed
temp_src_even   dw 0            ; Source offset for even row (in RAM)
temp_src_odd    dw 0            ; Source offset for odd row (in RAM)
temp_new_crtc   dw 0            ; Pre-calculated new CRTC value
temp_dest       dw 0            ; Write destination (bank-relative, wrapped)

; Auto-scroll state
auto_scroll     db 0
scroll_dir      db 0
vsync_enabled   db 1

bmp_header      times 128 db 0
row_buffer      times 164 db 0

end_program:
