; ============================================================================
; DEMO8B.ASM - Circular Buffer Scroller with Reduced Display (196 rows)
; Olivetti Prodest PC1 - V6355D 160x200x16 Hidden Graphics Mode
; Written for NASM - NEC V40 @ 8 MHz (80186 instruction set)
; By RetroErik - 2026
;
; STATUS: SUPERSEDED by demo8c.asm (true circular buffer, zero reloads)
;
; This version has THREE bugs that cause stuttering:
;   1. CRTC R6 is a dummy register on V6355D — writing R6=98 does nothing
;   2. scroll_down wrote new rows at wrong VRAM offset (before display start)
;   3. Periodic 15KB reload_viewport every 3-6 scrolls causes multi-frame stutter
;
; demo8c fixes all three: register 0x65 = 0x08 for genuine 192-line mode,
; correct write destination with 8K-boundary split copy, and zero reloads.
;
; ============================================================================
; CIRCULAR BUFFER TECHNIQUE - 100x FASTER THAN DEMO7!
; ============================================================================
;
; Demo7 copies 16KB every scroll step. This demo only copies 160 bytes!
;
; The trick: Treat VRAM as a circular (ring) buffer. Instead of copying
; all 200 visible rows, only copy the NEW rows that scroll into view,
; then use R12/R13 to shift where the CRTC starts reading.
;
; How it works (scrolling DOWN by 2 rows):
;   1. Row 0-1 scrolls off top of screen (no longer visible)
;   2. Row 200-201 scrolls into view at bottom
;   3. Overwrite VRAM where rows 0-1 were stored with rows 196-197
;   4. Set R12/R13 to start display at row 2's position
;   5. CRTC wraps around at 8KB boundary, making it seamless
;
; Memory comparison:
;   Demo7b: 15,680 bytes per scroll step (full viewport copy)
;   Demo8b: 160 bytes per scroll step (just 2 new rows) - 80% of scrolls
;   Speedup: ~20x faster on average!
;
; VRAM layout (interlaced, 196-row display):
;   Even bank (0x0000-0x1FFF): rows 0,2,4,...194 = 98 rows × 80 = 7840 bytes
;   Odd bank  (0x2000-0x3FFF): rows 1,3,5,...195 = 98 rows × 80 = 7840 bytes
;   HEADROOM: 8192 - 7840 = 352 bytes (4.4 rows) available for circular buffer
;
; THE 192-BYTE GAP PROBLEM (solved by using 196 rows):
;   With 200 rows, each bank uses 8000 bytes, leaving only 192 bytes gap.
;   Any R12/R13 offset would read into the gap almost immediately.
;   By using 196 rows (98 per bank = 7840 bytes), we have 352 bytes of
;   headroom - enough for 4 fast scrolls before needing a reload.
;
; THE FIX - REDUCED DISPLAY + PERIODIC RELOAD:
;   Display 196 rows instead of 200 (4 rows less, barely noticeable).
;   This gives us 352 bytes (4 rows) of circular buffer headroom.
;   Every 4 scrolls, do a full viewport reload to reset crtc_start_addr.
;   
;   Result: 4 fast scrolls (160 bytes each) + 1 slow reload (15680 bytes)
;   Average: ~3,200 bytes/scroll instead of 15,680 = ~5x faster than demo7b
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
; LIMITATIONS
; ============================================================================
;   - Scroll step MUST be 2 rows (to keep even/odd alignment)
;   - Cannot scroll by 1 row (would desync the banks)
;   - Cannot smoothly scroll backwards after forward (must reset or track)
;   - Current implementation: simple bidirectional scrolling
;   - Still stutters on hardware (see demo8c for fix)
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
DISPLAY_ROWS    equ 196         ; 196 visible rows (98 per bank)
ROWS_PER_BANK   equ 98          ; 98 rows × 80 = 7840 bytes per bank
BANK_USED       equ 7840        ; 98 rows × 80 bytes (display area)
BANK_HEADROOM   equ 352         ; 8192 - 7840 = 352 bytes (4.4 rows)
GAP_BOUNDARY    equ 320         ; Max crtc_start_addr before reload (4 rows × 80)
VRAM_SIZE       equ 15680       ; 196 rows × 80 bytes
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
    cmp ax, DISPLAY_ROWS        ; Minimum 196 rows
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
    sub ax, DISPLAY_ROWS        ; 196 rows displayed
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
; reset_scroll - Reset to initial state, copy first 196 rows to VRAM
; Clears VRAM to black first to prevent garbage in unused area
; Starts at middle position (160) for equal up/down headroom
; ============================================================================
reset_scroll:
    pusha
    push ds
    push es
    
    ; Reset scroll position
    mov word [scroll_row], 0
    mov word [crtc_start_addr], 160 ; Middle position for equal headroom
    
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
    
    ; Copy even rows (0,2,4...194) to VRAM bank 0 at offset 160
    xor si, si                  ; Start of RAM buffer
    mov di, 160                 ; Start at middle position
    mov cx, BANK_USED / 2       ; 98 rows × 80 bytes / 2 = 3920 words
    rep movsw
    
    ; Copy odd rows (1,3,5...195) to VRAM bank 1 at offset 0x2000 + 160
    mov si, [cs:odd_bank_offset]
    mov di, 0x2000 + 160
    mov cx, BANK_USED / 2       ; 3920 words
    rep movsw
    
    ; Set CRTC start address to middle
    mov ax, 160
    call set_crtc_start_address
    
    pop es
    pop ds
    popa
    ret

; ============================================================================
; reload_viewport - Full viewport copy from current scroll_row
; Called when we hit the gap boundary to reset the circular buffer
; Resets crtc_start_addr to middle (160) for equal up/down headroom
; ============================================================================
reload_viewport:
    ; Reset crtc_start_addr to middle position for equal headroom
    mov word [crtc_start_addr], 160
    
    ; Calculate source offset for current scroll_row
    ; Even bank: (scroll_row / 2) * 80
    mov ax, [scroll_row]
    shr ax, 1
    mov bx, BYTES_PER_LINE
    mul bx
    mov [cs:temp_src_even], ax      ; Save source offset for even rows
    
    mov ax, VIDEO_SEG
    mov es, ax
    mov ax, [image_buffer_seg]
    mov ds, ax
    
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
    
    ; Copy 98 even rows to VRAM bank 0 at offset 160 (row slot 2)
    mov si, [cs:temp_src_even]
    mov di, 160                 ; Start at offset 160 (middle position)
    mov cx, BANK_USED / 2       ; 3920 words
    rep movsw
    
    ; Calculate source offset for odd rows
    mov ax, [cs:scroll_row]
    shr ax, 1
    mov bx, BYTES_PER_LINE
    mul bx
    add ax, [cs:odd_bank_offset]
    mov si, ax
    
    ; Copy 98 odd rows to VRAM bank 1 at offset 0x2000 + 160
    mov di, 0x2000 + 160
    mov cx, BANK_USED / 2       ; 3920 words
    rep movsw
    
    ; Set CRTC start address to middle position
    mov ax, 160
    call set_crtc_start_address
    ret

; ============================================================================
; scroll_down_circular - Scroll down by 2 rows using circular buffer
;
; STRATEGY: Use fast 2-row copy + R12/R13 shift for most scrolls.
; When crtc_start_addr would exceed GAP_BOUNDARY (320 bytes = 4 rows),
; do a full viewport reload and reset to middle (160).
; ============================================================================
scroll_down_circular:
    pusha
    push ds
    push es
    
    ; Check if we're about to hit the gap
    ; GAP_BOUNDARY = 320 (4 rows × 80), after which display reads from gap
    mov ax, [crtc_start_addr]
    add ax, BYTES_PER_LINE      ; What it would be after this scroll
    cmp ax, GAP_BOUNDARY        ; 320 bytes (max safe)
    jbe .fast_scroll
    
    ; === FULL VIEWPORT RELOAD ===
    add word [scroll_row], SCROLL_STEP
    call reload_viewport
    jmp .scroll_done
    
.fast_scroll:
    ; Normal fast path: copy just 2 new rows
    add word [scroll_row], SCROLL_STEP
    
    ; The new rows to display are at (scroll_row + DISPLAY_ROWS - 2)
    ; These scroll into view at the bottom of the viewport
    mov ax, [scroll_row]
    add ax, DISPLAY_ROWS - 2    ; 194 for 196-row display
    mov [temp_row], ax
    
    ; Calculate source offset in RAM for new even row: (row/2) * 80
    mov ax, [temp_row]
    shr ax, 1
    mov bx, BYTES_PER_LINE
    mul bx
    mov [temp_src_even], ax
    
    ; Calculate source for odd row and save it
    mov ax, [temp_row]
    inc ax
    shr ax, 1
    mov bx, BYTES_PER_LINE
    mul bx
    add ax, [odd_bank_offset]
    mov [temp_src_odd], ax
    
    ; Pre-calculate new CRTC value
    mov ax, [crtc_start_addr]
    add ax, BYTES_PER_LINE
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
    ; Set up segments
    mov ax, [image_buffer_seg]
    mov ds, ax
    mov ax, VIDEO_SEG
    mov es, ax
    
    ; Destination in VRAM: current crtc_start (old row 0)
    mov di, [cs:crtc_start_addr]
    
    ; Copy 1 even row (80 bytes)
    mov si, [cs:temp_src_even]
    mov cx, 40
    cld
    rep movsw
    
    ; Destination for odd row: same offset but in odd bank
    mov di, [cs:crtc_start_addr]
    add di, 0x2000
    
    ; Copy 1 odd row (80 bytes)
    mov si, [cs:temp_src_odd]
    mov cx, 40
    rep movsw
    
    ; Update CRTC start address immediately (still in vblank)
    mov ax, [cs:temp_new_crtc]
    mov [cs:crtc_start_addr], ax
    
    ; Convert to word offset and write to CRTC
    shr ax, 1
    mov bx, ax
    mov dx, PORT_CRTC_ADDR
    mov al, CRTC_START_HIGH
    out dx, al
    mov dx, PORT_CRTC_DATA
    mov al, bh
    out dx, al
    mov dx, PORT_CRTC_ADDR
    mov al, CRTC_START_LOW
    out dx, al
    mov dx, PORT_CRTC_DATA
    mov al, bl
    out dx, al

.scroll_done:
    pop es
    pop ds
    popa
    ret

; ============================================================================
; scroll_up_circular - Scroll up by 2 rows using circular buffer
;
; When crtc_start_addr would go below 0,
; do a full viewport reload to avoid wrapping issues.
; ============================================================================
scroll_up_circular:
    pusha
    push ds
    push es
    
    ; Check if we're about to go below 0
    mov ax, [crtc_start_addr]
    cmp ax, BYTES_PER_LINE      ; Need at least 80 to subtract
    jae .fast_scroll_up
    
    ; === FULL VIEWPORT RELOAD ===
    sub word [scroll_row], SCROLL_STEP
    call reload_viewport
    jmp .scroll_up_done
    
.fast_scroll_up:
    ; Normal fast path
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
    
    ; Calculate source for odd row and save it
    mov ax, [temp_row]
    inc ax
    shr ax, 1
    mov bx, BYTES_PER_LINE
    mul bx
    add ax, [odd_bank_offset]
    mov [temp_src_odd], ax
    
    ; Pre-calculate new CRTC value and destination
    mov ax, [crtc_start_addr]
    sub ax, BYTES_PER_LINE
    mov [temp_new_crtc], ax
    
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
    ; Set up segments
    mov ax, [image_buffer_seg]
    mov ds, ax
    mov ax, VIDEO_SEG
    mov es, ax
    
    ; Destination: new start position (crtc - 80)
    mov di, [cs:temp_new_crtc]
    
    ; Copy 1 even row
    mov si, [cs:temp_src_even]
    mov cx, 40
    cld
    rep movsw
    
    ; Destination: new start position in odd bank
    mov di, [cs:temp_new_crtc]
    add di, 0x2000
    
    ; Copy 1 odd row
    mov si, [cs:temp_src_odd]
    mov cx, 40
    rep movsw
    
    ; Update CRTC start address immediately (still in vblank)
    mov ax, [cs:temp_new_crtc]
    mov [cs:crtc_start_addr], ax
    
    ; Convert to word offset and write to CRTC
    shr ax, 1
    mov bx, ax
    mov dx, PORT_CRTC_ADDR
    mov al, CRTC_START_HIGH
    out dx, al
    mov dx, PORT_CRTC_DATA
    mov al, bh
    out dx, al
    mov dx, PORT_CRTC_ADDR
    mov al, CRTC_START_LOW
    out dx, al
    mov dx, PORT_CRTC_DATA
    mov al, bl
    out dx, al

.scroll_up_done:
    pop es
    pop ds
    popa
    ret

; ============================================================================
; set_crtc_start_address - Set R12/R13 from byte offset in AX
; Waits for vertical retrace to prevent flicker
; ============================================================================
set_crtc_start_address:
    push ax
    push bx
    push dx
    
    ; Convert byte offset to word offset (CRTC counts words, not bytes)
    shr ax, 1
    mov bh, ah
    mov bl, al
    
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
    
    ; Now in vertical blank - update CRTC quickly
    ; Write R12 (high byte)
    mov dx, PORT_CRTC_ADDR
    mov al, CRTC_START_HIGH
    out dx, al
    mov dx, PORT_CRTC_DATA
    mov al, bh
    out dx, al
    
    ; Write R13 (low byte)
    mov dx, PORT_CRTC_ADDR
    mov al, CRTC_START_LOW
    out dx, al
    mov dx, PORT_CRTC_DATA
    mov al, bl
    out dx, al
    
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
; enable_graphics_mode - Set up 160×196×16 mode (reduced from 200 for headroom)
; ============================================================================
enable_graphics_mode:
    push ax
    push dx
    
    ; Register 0x65 = monitor control
    mov dx, PORT_REG_ADDR
    mov al, 0x65
    out dx, al
    jmp short $+2
    mov dx, PORT_REG_DATA
    mov al, 0x09
    out dx, al
    jmp short $+2
    
    ; Mode register
    mov dx, PORT_MODE
    mov al, 0x4A
    out dx, al
    jmp short $+2
    
    ; Set CRTC R6 (Vertical Displayed) to 98 rows per field
    ; This gives us 196 visible rows instead of 200
    mov dx, PORT_CRTC_ADDR
    mov al, 6               ; R6 = Vertical Displayed
    out dx, al
    jmp short $+2
    mov dx, PORT_CRTC_DATA
    mov al, ROWS_PER_BANK   ; 98 rows
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

msg_usage       db 'DEMO8B - 196-Row Circular Buffer Scroller (~5x faster)', 13, 10
                db 'Usage: DEMO8B filename.bmp', 13, 10
                db 'BMP must be 160 wide, 196-800 tall, 4-bit', 13, 10
                db 'UP/DOWN = scroll, SPACE = auto, V = VSync, R = Reset', 13, 10
                db 'Uses R12/R13 + partial updates (160 bytes vs 15KB)', 13, 10
                db 'ESC to exit', 13, 10, '$'

msg_file_err    db 'Error: Cannot open file', 13, 10, '$'
msg_not_bmp     db 'Error: Not a valid BMP file', 13, 10, '$'
msg_format      db 'Error: Must be 4-bit uncompressed BMP', 13, 10, '$'
msg_size        db 'Error: Must be 160 wide, 196-800 tall', 13, 10, '$'
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

; Auto-scroll state
auto_scroll     db 0
scroll_dir      db 0
vsync_enabled   db 1

bmp_header      times 128 db 0
row_buffer      times 164 db 0

end_program:
