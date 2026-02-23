; ============================================================================
; DEMO9B.ASM - Vertical R12/R13 Effects Demo for Olivetti Prodest PC1
; Written for NASM - NEC V40 (80186 compatible) @ 8 MHz
; By Retro Erik - 2026 with help from GitHub Copilot
;
; Target: Olivetti PC1 with Yamaha V6355D video controller
; Video Mode: CGA 160x192x16 (Hidden mode, 192 lines via register 0x65)
;
; ============================================================================
; FIXES FROM DEMO9.ASM
; ============================================================================
;
; demo9.asm had THREE bugs causing visual glitches:
;
;   1. CRTC WORD ADDRESSING: The MC6845-compatible CRTC counts in words (2
;      bytes), not bytes. demo9 wrote raw byte offsets to R12/R13, causing
;      all effects to operate at 2x the intended displacement. Fixed by
;      adding SHR AX,1 before CRTC register writes (confirmed by demo8c).
;
;   2. NON-ROW-ALIGNED OFFSETS: Using start_addr values that aren't multiples
;      of 80 (one row) creates a mid-scanline seam where the right portion
;      of each line displays data from 2 scanlines higher. This is inherent
;      to CGA interleaved addressing — the CRTC reads linearly and crosses
;      row boundaries mid-scanline. Fixed by converting all effects to use
;      row-aligned offsets (multiples of 80) for clean vertical movement.
;
;   3. GAP ARTIFACTS: CGA interlaced memory has a 192-byte gap per bank at
;      200 lines (0x1F40-0x1FFF, 0x3F40-0x3FFF). Any non-zero start_addr
;      pushes the last scanlines into this gap, showing black/garbage.
;      Fixed by using register 0x65 for 192-line mode (512-byte gap) and
;      gap-patching (copying top-of-image data into gaps for circular wrap).
;
; ============================================================================
; TALL IMAGE SUPPORT
; ============================================================================
;
; Supports images from 1 to 800 rows tall:
;   - The .COM shrinks its PSP memory block and allocates a separate buffer
;   - Full image decoded to allocated RAM buffer (interlaced format)
;   - Current 192-row viewport copied from RAM buffer to VRAM
;   - UP/DOWN arrows and PgUp/PgDn navigate through tall images
;   - Effects operate on the current viewport in VRAM
;   - Viewport changes stop effects and do a full VRAM refresh
;
; ============================================================================
; TECHNIQUE
; ============================================================================
;
; All effects use VERTICAL movement with row-aligned CRTC offsets:
;   - start_addr always a multiple of 80 (one character row = 2 scanlines)
;   - No mid-scanline seams, no horizontal displacement
;   - 192-line mode gives 512 bytes (6 rows) of gap headroom
;   - Gap-patched so the image wraps cleanly at the bottom
;
; Register 0x65 = 0x08: PAL, 192 lines, CRT
;   - 96 rows per bank x 80 bytes = 7680 bytes displayed
;   - Gap per bank: 8192 - 7680 = 512 bytes (6.4 rows of headroom)
;   - Maximum safe start_addr: 480 bytes (6 rows, 12 pixels)
;
; Controls:
;   S       - Toggle screen shake (vertical jitter)
;   H       - Toggle vertical wave (gentle bob up/down)
;   T       - Trigger drop-in (image drops into place from above)
;   B       - Bounce effect (image bounces vertically)
;   M       - Vertical scroll (ping-pong up/down)
;   1-6     - Shake intensity levels (capped at 6 for gap safety)
;   UP/DOWN - Navigate tall images (2 rows per step)
;   PgUp/Dn - Navigate tall images (96 rows per step)
;   Home    - Jump to top of image
;   End     - Jump to bottom of image
;   V       - Toggle VSync on/off
;   R       - Reset effects to normal view
;   ESC     - Exit to DOS
;
; Usage: DEMO9B image.bmp
;
; Prerequisites:
;   Run PERITEL.COM first to set horizontal position correctly
; ============================================================================

[BITS 16]
[CPU 186]
[ORG 0x100]

; ============================================================================
; Constants - Hardware definitions
; ============================================================================
VIDEO_SEG       equ 0xB000      ; PC1 video RAM segment

; Yamaha V6355D I/O Ports
PORT_CRTC_ADDR  equ 0x3D4       ; CRTC register index (R0-R17)
PORT_CRTC_DATA  equ 0x3D5       ; CRTC register data
PORT_V6355_ADDR equ 0x3DD       ; V6355D extended register / palette address
PORT_V6355_DATA equ 0x3DE       ; V6355D extended register / palette data
PORT_MODE       equ 0x3D8       ; Mode control register
PORT_COLOR      equ 0x3D9       ; Color select (border/overscan color)
PORT_STATUS     equ 0x3DA       ; Status (bit 0=hsync, bit 3=vblank)

; CRTC Register numbers
CRTC_START_HI   equ 12          ; R12: Start Address High
CRTC_START_LO   equ 13          ; R13: Start Address Low

; Register 0x65 values
REG65_192       equ 0x08        ; PAL, 192 lines, CRT (bits 0-1 = 00)
REG65_200       equ 0x09        ; PAL, 200 lines, CRT (bits 0-1 = 01, default)

; BMP File Header offsets
BMP_SIGNATURE   equ 0
BMP_DATA_OFFSET equ 10
BMP_WIDTH       equ 18
BMP_HEIGHT      equ 22
BMP_BPP         equ 28
BMP_COMPRESSION equ 30

; Screen parameters
SCREEN_WIDTH    equ 160
DISPLAY_ROWS    equ 192         ; 192 lines (register 0x65 = 0x08)
ROWS_PER_BANK   equ 96          ; 96 rows per bank in 192-line mode
BYTES_PER_ROW   equ 80          ; 160 pixels * 4 bits / 8 = 80 bytes
SCREEN_SIZE     equ 16384       ; Full video RAM (16KB)
BANK_SIZE       equ 8192        ; 8KB per bank
BANK_USED       equ 7680        ; 96 rows x 80 bytes (display area at 192 lines)
GAP_SIZE        equ 512         ; BANK_SIZE - BANK_USED = headroom per bank

; Image limits
MAX_IMAGE_HEIGHT equ 800        ; Maximum image height in rows
STACK_RESERVE   equ 64          ; Paragraphs reserved for stack (1024 bytes)

; Navigation steps
VIEW_STEP_SMALL equ 2           ; UP/DOWN: 2 rows (1 character row, 4 pixels)
VIEW_STEP_LARGE equ 96          ; PgUp/PgDn: 96 rows (half screen)

; ============================================================================
; Shake Configuration
; ============================================================================
SHAKE_MAX       equ 6           ; Maximum shake intensity (rows), capped for gap

; ============================================================================
; Main Program Entry Point
; ============================================================================
main:
    ; Shrink memory block to free conventional RAM for image buffer
    call shrink_memory_block

    ; Parse command line for filename
    mov si, 0x81

.skip_spaces:
    lodsb
    cmp al, ' '
    je .skip_spaces
    cmp al, 0x0D
    je .show_usage

    ; Check for /? or /h
    cmp al, '/'
    jne .not_help
    lodsb
    cmp al, '?'
    je .show_usage
    cmp al, 'h'
    je .show_usage
    cmp al, 'H'
    je .show_usage
    dec si
    dec si
    jmp .save_filename

.not_help:
    dec si

.save_filename:
    mov [filename_ptr], si

.find_end:
    lodsb
    cmp al, ' '
    je .found_end
    cmp al, 0x0D
    jne .find_end

.found_end:
    dec si
    mov byte [si], 0
    jmp .open_file

.show_usage:
    mov dx, msg_info
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

    ; Read BMP header + palette (54 byte header + 64 byte palette = 118)
    mov bx, ax
    mov dx, bmp_header
    mov cx, 118
    mov ah, 0x3F
    int 0x21
    jc .file_error
    cmp ax, 118
    jb .file_error

    ; Verify BMP signature
    cmp word [bmp_header + BMP_SIGNATURE], 0x4D42
    jne .not_bmp

    ; Check bits per pixel
    cmp word [bmp_header + BMP_BPP], 4
    jne .wrong_format

    ; Check compression
    cmp word [bmp_header + BMP_COMPRESSION], 0
    jne .wrong_format

    ; Validate image width (must be 160 or 320)
    mov ax, [bmp_header + BMP_WIDTH]
    mov [image_width], ax
    cmp ax, 160
    je .width_ok
    cmp ax, 320
    jne .wrong_size
    mov byte [downsample_flag], 1
.width_ok:

    ; Validate image height (1 to MAX_IMAGE_HEIGHT)
    mov ax, [bmp_header + BMP_HEIGHT]
    or ax, ax
    jz .wrong_size
    cmp ax, MAX_IMAGE_HEIGHT
    ja .wrong_size
    mov [image_height], ax

    ; Seek to pixel data
    mov bx, [file_handle]
    mov dx, [bmp_header + BMP_DATA_OFFSET]
    mov cx, [bmp_header + BMP_DATA_OFFSET + 2]
    mov ax, 0x4200
    int 0x21
    jc .file_error

    ; Decode BMP to allocated RAM buffer (interlaced format)
    call decode_bmp_to_ram

    ; Close file
    mov bx, [file_handle]
    mov ah, 0x3E
    int 0x21

    ; Calculate maximum view row (how far we can scroll)
    mov ax, [image_height]
    sub ax, DISPLAY_ROWS
    jns .has_scroll_range
    xor ax, ax                  ; Image shorter than 192: no scrolling
.has_scroll_range:
    and ax, 0xFFFE              ; Ensure even (interlaced alignment)
    mov [max_view_row], ax

    ; Enable graphics mode with 192 lines (must be before palette!)
    call enable_graphics_mode

    ; Wait for VBlank
    call wait_vblank

    ; Set palette from BMP
    call set_bmp_palette

    ; Force palette 0 to black
    call force_black_palette0

    ; Clear screen
    call clear_screen

    ; Load initial viewport (top of image) from RAM to VRAM
    call load_viewport

    ; Patch gap areas for circular wrapping
    call gap_patch

    ; Enable video
    mov dx, PORT_MODE
    mov al, 0x4A
    out dx, al

    ; ========================================================================
    ; PHASE 2: R12/R13 Effects Loop
    ; ========================================================================
.main_loop:
    ; Wait for VBlank (if enabled)
    cmp byte [vsync_enabled], 0
    je .skip_vsync
    call wait_vblank
.skip_vsync:

    ; Handle screen shake if enabled
    cmp byte [shake_active], 0
    je .no_shake
    call do_screen_shake
    jmp .check_wave

.no_shake:
    ; If shake just disabled, reset to normal
    cmp byte [need_reset], 1
    jne .check_wave
    call reset_crtc_start
    mov byte [need_reset], 0

.check_wave:
    ; Handle vertical wave if active
    cmp byte [vwave_active], 0
    je .check_drop
    call do_vertical_wave

.check_drop:
    ; Handle drop-in if active
    cmp byte [drop_active], 0
    je .check_bounce
    call do_drop_in

.check_bounce:
    ; Handle bounce if active
    cmp byte [bounce_active], 0
    je .check_marquee
    call do_bounce

.check_marquee:
    ; Handle vertical scroll if active
    cmp byte [marquee_active], 0
    je .check_keys
    call do_marquee

.check_keys:
    ; Check for keypress
    mov ah, 0x01
    int 0x16
    jz .main_loop

    ; Get key
    mov ah, 0x00
    int 0x16

    ; Check for ESC
    cmp al, 27
    je .exit_program

    ; Check for 'S' or 's' - toggle shake
    cmp al, 'S'
    je .toggle_shake
    cmp al, 's'
    je .toggle_shake

    ; Check for 'V' or 'v' - toggle vsync
    cmp al, 'V'
    je .toggle_vsync
    cmp al, 'v'
    je .toggle_vsync

    ; Check for 'H' or 'h' - toggle vertical wave
    cmp al, 'H'
    je .toggle_vwave
    cmp al, 'h'
    je .toggle_vwave

    ; Check for 'T' or 't' - trigger drop-in
    cmp al, 'T'
    je .toggle_drop
    cmp al, 't'
    je .toggle_drop

    ; Check for 'B' or 'b' - trigger bounce
    cmp al, 'B'
    je .toggle_bounce
    cmp al, 'b'
    je .toggle_bounce

    ; Check for 'M' or 'm' - marquee
    cmp al, 'M'
    je .toggle_marquee
    cmp al, 'm'
    je .toggle_marquee

    ; Check for 'R' or 'r' - reset
    cmp al, 'R'
    je .do_reset
    cmp al, 'r'
    je .do_reset

    ; Check for '1'-'6' - shake intensity (capped at 6)
    cmp al, '1'
    jb .check_extended_keys
    cmp al, '6'
    ja .check_extended_keys

    ; Set shake intensity (1-6)
    sub al, '0'
    mov [shake_intensity], al
    jmp .main_loop

.check_extended_keys:
    ; Extended keys have AL=0, scan code in AH
    cmp ah, 0x48                ; Up arrow
    je .view_up
    cmp ah, 0x50                ; Down arrow
    je .view_down
    cmp ah, 0x49                ; Page Up
    je .view_pgup
    cmp ah, 0x51                ; Page Down
    je .view_pgdn
    cmp ah, 0x47                ; Home
    je .view_home
    cmp ah, 0x4F                ; End
    je .view_end
    jmp .main_loop

.toggle_shake:
    xor byte [shake_active], 1
    cmp byte [shake_active], 0
    jne .main_loop
    mov byte [need_reset], 1    ; Flag to reset when shake stops
    jmp .main_loop

.toggle_vsync:
    xor byte [vsync_enabled], 1
    jmp .main_loop

.toggle_vwave:
    xor byte [vwave_active], 1
    cmp byte [vwave_active], 0
    jne .main_loop
    mov byte [need_reset], 1
    jmp .main_loop

.toggle_drop:
    xor byte [drop_active], 1
    cmp byte [drop_active], 0
    jne .main_loop
    mov byte [need_reset], 1
    jmp .main_loop

.toggle_bounce:
    mov byte [bounce_active], 1
    mov byte [bounce_frame], 0    ; Reset animation
    jmp .main_loop

.toggle_marquee:
    xor byte [marquee_active], 1
    cmp byte [marquee_active], 0
    jne .main_loop
    mov byte [need_reset], 1
    jmp .main_loop

.do_reset:
    call stop_all_effects
    jmp .main_loop

; --- View navigation (tall image scrolling) ---
.view_up:
    mov ax, [view_row]
    or ax, ax
    jz .main_loop               ; Already at top
    sub ax, VIEW_STEP_SMALL
    jns .view_set
    xor ax, ax                  ; Clamp to 0
    jmp .view_set

.view_down:
    mov ax, [view_row]
    add ax, VIEW_STEP_SMALL
    jmp .view_clamp

.view_pgup:
    mov ax, [view_row]
    or ax, ax
    jz .main_loop               ; Already at top
    sub ax, VIEW_STEP_LARGE
    jns .view_set
    xor ax, ax
    jmp .view_set

.view_pgdn:
    mov ax, [view_row]
    add ax, VIEW_STEP_LARGE
    jmp .view_clamp

.view_home:
    xor ax, ax
    jmp .view_set

.view_end:
    mov ax, [max_view_row]
    jmp .view_set

.view_clamp:
    cmp ax, [max_view_row]
    jbe .view_set
    mov ax, [max_view_row]

.view_set:
    and ax, 0xFFFE              ; Ensure even row (interlaced alignment)
    cmp ax, [view_row]
    je .main_loop               ; No change — skip expensive refresh
    mov [view_row], ax

    ; Stop effects, refresh VRAM with new viewport
    call stop_all_effects
    call load_viewport
    call gap_patch
    jmp .main_loop

; --- Exit ---
.exit_program:
    ; Reset CRTC start address
    call reset_crtc_start

    ; Free image buffer
    mov ax, [image_buffer_seg]
    or ax, ax
    jz .no_free
    mov es, ax
    mov ah, 0x49                ; DOS: Free memory block
    int 0x21
.no_free:

    ; Restore register 0x65 to default 200-line mode
    mov dx, PORT_V6355_ADDR
    mov al, 0x65
    out dx, al
    mov dx, PORT_V6355_DATA
    mov al, REG65_200           ; 0x09 = PAL, 200 lines, CRT
    out dx, al
    ; Close palette session to prevent DAC corruption
    mov dx, PORT_V6355_ADDR
    mov al, 0x80
    out dx, al

    ; Restore CGA palette
    call set_cga_palette

    ; Restore text mode
    mov ax, 0x0003
    int 0x10

    mov ax, 0x4C00
    int 0x21

; --- Error handlers ---
.file_error:
    mov dx, msg_file_err
    jmp .print_exit

.not_bmp:
    mov dx, msg_not_bmp
    jmp .print_exit

.wrong_format:
    mov dx, msg_format
    jmp .print_exit

.wrong_size:
    mov dx, msg_size

.print_exit:
    mov ah, 0x09
    int 0x21
    mov ax, 0x4C01
    int 0x21

; ============================================================================
; stop_all_effects - Disable all effects and reset CRTC to 0
; ============================================================================
stop_all_effects:
    call reset_crtc_start
    mov byte [shake_active], 0
    mov byte [vwave_active], 0
    mov byte [drop_active], 0
    mov byte [bounce_active], 0
    mov byte [marquee_active], 0
    mov byte [need_reset], 0
    ret

; ============================================================================
; shrink_memory_block - Shrink PSP memory block to free RAM for allocation
;
; COM files initially own all memory. We must release unneeded memory so
; DOS INT 21h/48h can allocate a buffer for the full image.
; ============================================================================
shrink_memory_block:
    pusha
    push es

    mov ax, cs
    mov es, ax

    ; Calculate paragraphs needed: program size + stack reserve
    mov bx, end_program         ; End of program data (offset from ORG)
    add bx, 0x100               ; Add PSP size
    add bx, 15                  ; Round up to next paragraph
    shr bx, 4
    add bx, STACK_RESERVE       ; Reserve stack space

    mov ah, 0x4A                ; DOS: Resize memory block
    int 0x21

    pop es
    popa
    ret

; ============================================================================
; R12/R13 EFFECT ROUTINES
; ============================================================================

; ----------------------------------------------------------------------------
; set_crtc_start - Set CRTC start address (R12/R13)
; Input: AX = start address (BYTE offset in VRAM, must be even)
; The CRTC counts in words (2 bytes), so we divide by 2.
; Uses word-wide OUT for atomic index+data writes.
; Must be called during VBlank to avoid tearing!
; ----------------------------------------------------------------------------
set_crtc_start:
    push ax
    push bx
    push dx

    ; Convert byte offset to CRTC word offset
    shr ax, 1
    mov bx, ax                 ; BH = high byte, BL = low byte

    ; Word-wide CRTC write: R12 = start address high
    mov dx, PORT_CRTC_ADDR
    mov al, CRTC_START_HI       ; AL = register index 12
    mov ah, bh                  ; AH = data (high byte of word offset)
    out dx, ax

    ; Word-wide CRTC write: R13 = start address low
    mov al, CRTC_START_LO       ; AL = register index 13
    mov ah, bl                  ; AH = data (low byte of word offset)
    out dx, ax

    pop dx
    pop bx
    pop ax
    ret

; ----------------------------------------------------------------------------
; reset_crtc_start - Reset CRTC start address to 0
; ----------------------------------------------------------------------------
reset_crtc_start:
    push ax
    xor ax, ax
    call set_crtc_start
    pop ax
    ret

; ----------------------------------------------------------------------------
; do_screen_shake - Vertical screen shake effect
; Alternates between start_addr = intensity*80 and start_addr = 0
; All offsets are row-aligned (multiples of 80) — no seam artifacts
; Range: 1-6 rows = 2-12 pixels of vertical jitter
; ----------------------------------------------------------------------------
do_screen_shake:
    push ax
    push bx

    ; Toggle between offset and 0 each frame
    xor byte [shake_toggle], 1

    ; If toggle is 1, use 0 (rest position)
    cmp byte [shake_toggle], 0
    jne .shake_zero

    ; Get intensity (1-6) and multiply by 80 for byte offset
    mov al, [shake_intensity]
    xor ah, ah
    mov bx, BYTES_PER_ROW
    mul bx                      ; AX = intensity * 80 (row-aligned)
    jmp .shake_apply

.shake_zero:
    xor ax, ax                  ; Offset = 0 on alternate frames

.shake_apply:
    call set_crtc_start

    pop bx
    pop ax
    ret

shake_toggle: db 0

; ----------------------------------------------------------------------------
; do_vertical_wave - Vertical bob effect (SMOOTH version)
; Gentle up/down oscillation using a 64-entry wave table
; Table contains row counts (0-4), multiplied by 80 for byte offset
; Range: 0-4 rows = 0-8 pixels of vertical movement
; At 50Hz PAL: full cycle = 64 frames = 1.28 seconds
; ----------------------------------------------------------------------------
do_vertical_wave:
    push ax
    push bx
    push si

    ; Increment wave index (wraps at 64)
    inc byte [vwave_index]
    mov al, [vwave_index]
    and al, 0x3F                ; Keep in 0-63 range
    mov [vwave_index], al

    ; Look up row count from wave table
    xor ah, ah
    mov si, ax
    mov al, [vwave_table + si]  ; AL = row count (0-4)

    ; Multiply by 80 for byte offset
    xor ah, ah
    mov bl, BYTES_PER_ROW
    mul bl                      ; AX = rows * 80

    call set_crtc_start

    pop si
    pop bx
    pop ax
    ret

vwave_index: db 0

; Vertical wave table (64 entries, values = row count 0-4)
; Smooth triangle wave: 0->4->0, each position held 8 frames
vwave_table:
    db 0, 0, 0, 0, 0, 0, 0, 0  ; 0-7:   rest at 0
    db 1, 1, 1, 1, 1, 1, 1, 1  ; 8-15:  row 1 (2 pixels up)
    db 2, 2, 2, 2, 2, 2, 2, 2  ; 16-23: row 2 (4 pixels up)
    db 3, 3, 3, 3, 3, 3, 3, 3  ; 24-31: row 3 (6 pixels up)
    db 4, 4, 4, 4, 4, 4, 4, 4  ; 32-39: row 4 (8 pixels up, peak)
    db 3, 3, 3, 3, 3, 3, 3, 3  ; 40-47: row 3
    db 2, 2, 2, 2, 2, 2, 2, 2  ; 48-55: row 2
    db 1, 1, 1, 1, 1, 1, 1, 1  ; 56-63: row 1 (wraps to 0 smoothly)

; ----------------------------------------------------------------------------
; do_drop_in - Vertical drop-in transition
; Image starts shifted up (6 rows) and drops back to rest position (0)
; Each step = 1 row = 2 pixels, with a delay for smoother animation
; Looks like: image sliding down into place from above
; ----------------------------------------------------------------------------
do_drop_in:
    push ax
    push bx

    ; Initialize if not started
    cmp byte [drop_pos], 0
    jne .drop_continue
    mov byte [drop_pos], 6      ; Start 6 rows up (12 pixels)

.drop_continue:
    ; Set current position: drop_pos * 80
    mov al, [drop_pos]
    xor ah, ah
    mov bl, BYTES_PER_ROW
    mul bl                      ; AX = rows * 80
    call set_crtc_start

    ; Slow down: advance every other frame
    xor byte [drop_delay], 1
    cmp byte [drop_delay], 0
    jne .drop_done

    ; Decrement position (drop toward rest)
    dec byte [drop_pos]
    cmp byte [drop_pos], 0
    jne .drop_done

    ; Animation complete
    mov byte [drop_active], 0
    mov byte [need_reset], 1

.drop_done:
    pop bx
    pop ax
    ret

drop_pos:   db 0
drop_delay: db 0

; ----------------------------------------------------------------------------
; do_bounce - Vertical bounce physics effect
; Image gets bumped upward and bounces back to rest position
; Uses pre-calculated table of row counts (0-5), multiplied by 80
; Looks like: image kicked up, falls back, bounces with damping
; ----------------------------------------------------------------------------
do_bounce:
    push ax
    push bx
    push si

    ; Get current frame in bounce animation
    mov al, [bounce_frame]
    xor ah, ah
    mov si, ax

    ; Look up row count from bounce table
    mov al, [bounce_table + si]

    ; Check for end of animation (255 = done)
    cmp al, 255
    jne .bounce_not_done

    ; Animation complete
    mov byte [bounce_active], 0
    mov byte [bounce_frame], 0
    mov byte [need_reset], 1
    xor ax, ax
    jmp .bounce_apply

.bounce_not_done:
    ; Advance to next frame
    inc byte [bounce_frame]

    ; Multiply row count by 80 for byte offset
    xor ah, ah
    mov bl, BYTES_PER_ROW
    mul bl                      ; AX = rows * 80

.bounce_apply:
    call set_crtc_start

    pop si
    pop bx
    pop ax
    ret

; Bounce animation table - values are ROW COUNTS (0-5), 255 = end
; Image rises from rest (0) to peak (5), bounces back with damping
; Each value repeated 2x for smoother animation at 50Hz
bounce_table:
    ; Rise (impact pushes up): 0->5 (accelerating)
    db 0, 0, 0, 1, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 5
    ; Fall back to rest: 5->0 (decelerating)
    db 5, 5, 4, 4, 3, 3, 2, 2, 1, 1, 0, 0, 0
    ; Bounce 2: 0->3->0
    db 0, 1, 1, 2, 2, 3, 3, 2, 2, 1, 1, 0, 0
    ; Bounce 3: 0->1->0
    db 0, 1, 1, 1, 0, 0
    ; Settle at rest
    db 0, 0, 0, 0
    ; End marker
    db 255

bounce_frame: db 0

; ----------------------------------------------------------------------------
; do_marquee - Vertical ping-pong scroll
; Scrolls image up and down continuously between 0 and 5 rows
; Range: 0-5 rows = 0-10 pixels of vertical movement
; Looks like: image gently scrolling up and back down
; ----------------------------------------------------------------------------
do_marquee:
    push ax
    push bx

    ; Check direction and update position
    cmp byte [marquee_dir], 0
    jne .marquee_down

    ; Going up (increasing offset — image shifts up)
    inc byte [marquee_pos]
    cmp byte [marquee_pos], 5
    jbe .marquee_apply
    mov byte [marquee_pos], 5
    mov byte [marquee_dir], 1   ; Reverse direction
    jmp .marquee_apply

.marquee_down:
    ; Going down (decreasing offset — image shifts back)
    dec byte [marquee_pos]
    cmp byte [marquee_pos], 0
    jne .marquee_apply
    mov byte [marquee_dir], 0   ; Reverse direction

.marquee_apply:
    mov al, [marquee_pos]
    xor ah, ah
    mov bl, BYTES_PER_ROW
    mul bl                      ; AX = rows * 80
    call set_crtc_start

    pop bx
    pop ax
    ret

marquee_pos: db 0
marquee_dir: db 0               ; 0 = up (increasing), 1 = down (decreasing)

; ============================================================================
; Video Utility Routines
; ============================================================================

; ----------------------------------------------------------------------------
; wait_vblank - Wait for vertical blanking interval
; ----------------------------------------------------------------------------
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

; ----------------------------------------------------------------------------
; enable_graphics_mode - Enable 160x192x16 hidden mode
; Sets register 0x65 for 192-line mode BEFORE palette initialization.
; This gives 512 bytes of gap headroom per bank for R12/R13 effects.
; ----------------------------------------------------------------------------
enable_graphics_mode:
    push ax
    push dx

    ; Register 0x65 = 0x08: PAL, 192 lines, CRT
    ; Bits 0-1 = 00 -> 192 lines (96 character rows per bank)
    ; Bit 3 = 1 -> PAL/50Hz
    ; Must be written BEFORE palette setup (0x65 overlaps palette range)
    mov dx, PORT_V6355_ADDR
    mov al, 0x65
    out dx, al
    jmp short $+2
    mov dx, PORT_V6355_DATA
    mov al, REG65_192           ; 0x08 = 192 lines
    out dx, al
    jmp short $+2

    ; Close palette session to prevent DAC corruption
    ; (register address 0x65 has bit 6 set, overlapping palette command range)
    mov dx, PORT_V6355_ADDR
    mov al, 0x80
    out dx, al
    jmp short $+2

    ; Mode register: enable 160x192 hidden graphics mode
    mov dx, PORT_MODE
    mov al, 0x4A
    out dx, al

    pop dx
    pop ax
    ret

; ----------------------------------------------------------------------------
; clear_screen - Fill video RAM with color 0
; ----------------------------------------------------------------------------
clear_screen:
    pusha
    push es

    mov ax, VIDEO_SEG
    mov es, ax
    xor di, di
    mov cx, SCREEN_SIZE / 2
    xor ax, ax
    cld
    rep stosw

    pop es
    popa
    ret

; ----------------------------------------------------------------------------
; load_viewport - Copy 192 rows from RAM buffer to VRAM at current view_row
;
; RAM buffer layout (interlaced):
;   Even rows (0,2,4,...) stored at offset 0, each 80 bytes sequentially
;   Odd rows (1,3,5,...) stored at odd_bank_offset, each 80 bytes
;
; VRAM layout:
;   Even bank: 0x0000-0x1DFF (96 rows x 80 = 7680 bytes)
;   Odd bank:  0x2000-0x3DFF (96 rows x 80 = 7680 bytes)
;
; If image is shorter than 192 rows, remaining VRAM rows stay black.
; view_row must be even for correct interlaced alignment.
; ----------------------------------------------------------------------------
load_viewport:
    pusha
    push ds
    push es

    ; How many rows can we display from view_row?
    mov ax, [image_height]
    sub ax, [view_row]          ; Rows remaining from view_row to end
    cmp ax, DISPLAY_ROWS
    jbe .vp_rows_ok
    mov ax, DISPLAY_ROWS        ; Cap at 192
.vp_rows_ok:
    or ax, ax
    jz .vp_done                 ; Nothing to display
    mov [vp_display_rows], ax

    ; Even row count = (display_rows + 1) / 2
    mov bx, ax
    inc ax
    shr ax, 1
    mov [vp_even_count], ax

    ; Odd row count = display_rows / 2
    shr bx, 1
    mov [vp_odd_count], bx

    ; Source offset for even rows: (view_row / 2) * 80
    mov ax, [view_row]
    shr ax, 1
    mov bx, BYTES_PER_ROW
    mul bx                      ; AX = (view_row/2) * 80
    mov [vp_even_src], ax

    ; Source offset for odd rows: odd_bank_offset + (view_row / 2) * 80
    add ax, [odd_bank_offset]
    mov [vp_odd_src], ax

    ; Clear VRAM first (handles images shorter than 192 rows)
    mov ax, VIDEO_SEG
    mov es, ax
    xor di, di
    mov cx, BANK_SIZE / 2
    xor ax, ax
    cld
    rep stosw                   ; Clear even bank
    mov di, BANK_SIZE
    mov cx, BANK_SIZE / 2
    rep stosw                   ; Clear odd bank

    ; Set DS = image buffer segment for movsw source
    mov ax, [cs:image_buffer_seg]
    mov ds, ax

    ; Copy even rows: RAM buffer -> VRAM 0x0000
    mov si, [cs:vp_even_src]
    xor di, di                  ; VRAM even bank start
    mov cx, [cs:vp_even_count]
    or cx, cx
    jz .vp_copy_odd
    mov bx, BYTES_PER_ROW / 2   ; 40 words per row
.vp_even_loop:
    push cx
    mov cx, bx
    rep movsw
    pop cx
    loop .vp_even_loop

.vp_copy_odd:
    ; Copy odd rows: RAM buffer -> VRAM 0x2000
    mov si, [cs:vp_odd_src]
    mov di, BANK_SIZE           ; VRAM odd bank start (0x2000)
    mov cx, [cs:vp_odd_count]
    or cx, cx
    jz .vp_done
.vp_odd_loop:
    push cx
    mov cx, bx
    rep movsw
    pop cx
    loop .vp_odd_loop

.vp_done:
    pop es
    pop ds
    popa
    ret

; Viewport temporaries
vp_display_rows: dw 0
vp_even_src:     dw 0
vp_odd_src:      dw 0
vp_even_count:   dw 0
vp_odd_count:    dw 0

; ----------------------------------------------------------------------------
; gap_patch - Fill gap areas with top-of-VRAM data for circular wrapping
;
; Copies the first 512 bytes of each bank into its gap area at the end.
; This makes the display wrap cleanly when start_addr is non-zero:
; instead of showing black/garbage at the bottom, it shows the top
; rows of the image (a circular wrap effect, imperceptible during animation).
;
; Even bank: copy 0x0000-0x01FF -> 0x1E00-0x1FFF (512 bytes)
; Odd bank:  copy 0x2000-0x21FF -> 0x3E00-0x3FFF (512 bytes)
; ----------------------------------------------------------------------------
gap_patch:
    pusha
    push ds
    push es

    mov ax, VIDEO_SEG
    mov ds, ax
    mov es, ax
    cld

    ; Patch even bank gap
    xor si, si                  ; Source: 0x0000 (top of even bank)
    mov di, BANK_USED           ; Dest: 0x1E00 (gap start, 7680)
    mov cx, GAP_SIZE / 2        ; 256 words = 512 bytes
    rep movsw

    ; Patch odd bank gap
    mov si, BANK_SIZE           ; Source: 0x2000 (top of odd bank)
    mov di, BANK_SIZE + BANK_USED ; Dest: 0x3E00 (odd gap start)
    mov cx, GAP_SIZE / 2        ; 256 words = 512 bytes
    rep movsw

    pop es
    pop ds
    popa
    ret

; ============================================================================
; Palette Routines
; ============================================================================

; ----------------------------------------------------------------------------
; set_bmp_palette - Set palette from BMP file
; Uses 16-bit port addresses via DX for V6355D palette registers
; ----------------------------------------------------------------------------
set_bmp_palette:
    pusha

    cli

    mov dx, PORT_V6355_ADDR
    mov al, 0x40
    out dx, al
    jmp short $+2

    mov si, bmp_header + 54
    mov cx, 16

.palette_loop:
    lodsb                       ; Blue
    mov bl, al

    lodsb                       ; Green
    mov bh, al

    lodsb                       ; Red
    shr al, 5                   ; Top 3 bits -> bits 0-2 (186 imm shift)
    mov dx, PORT_V6355_DATA
    out dx, al
    jmp short $+2

    mov al, bh                  ; Green
    and al, 0xE0
    shr al, 1                   ; Green top 3 bits -> bits 4-6
    mov ah, al

    mov al, bl                  ; Blue
    shr al, 5                   ; Blue top 3 bits -> bits 0-2
    or al, ah                   ; Combine green | blue
    mov dx, PORT_V6355_DATA
    out dx, al
    jmp short $+2

    lodsb                       ; Skip alpha/reserved byte

    loop .palette_loop

    mov dx, PORT_V6355_ADDR
    mov al, 0x80
    out dx, al

    sti

    popa
    ret

; ----------------------------------------------------------------------------
; force_black_palette0 - Force palette entry 0 to black
; ----------------------------------------------------------------------------
force_black_palette0:
    push ax
    push dx

    cli

    mov dx, PORT_V6355_ADDR
    mov al, 0x40
    out dx, al
    jmp short $+2

    mov dx, PORT_V6355_DATA
    xor al, al
    out dx, al
    jmp short $+2

    xor al, al
    out dx, al
    jmp short $+2

    mov dx, PORT_V6355_ADDR
    mov al, 0x80
    out dx, al

    sti

    pop dx
    pop ax
    ret

; ----------------------------------------------------------------------------
; set_cga_palette - Restore standard CGA palette
; ----------------------------------------------------------------------------
set_cga_palette:
    pusha

    cli

    mov dx, PORT_V6355_ADDR
    mov al, 0x40
    out dx, al
    jmp short $+2

    mov si, cga_colors
    mov cx, 32
    mov dx, PORT_V6355_DATA

.pal_write_loop:
    lodsb
    out dx, al
    jmp short $+2
    loop .pal_write_loop

    mov dx, PORT_V6355_ADDR
    mov al, 0x80
    out dx, al

    sti

    popa
    ret

; ============================================================================
; BMP Decoding to RAM Buffer
; ============================================================================

; ----------------------------------------------------------------------------
; decode_bmp_to_ram - Allocate RAM and decode BMP to interlaced buffer
;
; Allocates a memory block via DOS and decodes the BMP file (bottom-up)
; into interlaced format matching CGA bank structure:
;
;   Even rows (0,2,4,...) packed at offset 0, each 80 bytes
;   Odd rows (1,3,5,...) packed at odd_bank_offset, each 80 bytes
;
; Total allocation: image_height * 80 bytes (max 64000 for 800 rows)
; ----------------------------------------------------------------------------
decode_bmp_to_ram:
    pusha
    push es

    ; Calculate BMP bytes per row (padded to 4-byte boundary)
    mov ax, [image_width]
    inc ax
    shr ax, 1                   ; Pixels -> bytes (4bpp)
    add ax, 3
    and ax, 0xFFFC              ; Round up to 4-byte boundary
    cmp ax, 164
    jbe .bpr_ok
    mov ax, 164                 ; Cap row read size
.bpr_ok:
    mov [bytes_per_bmp_row], ax

    ; Calculate odd bank offset: (image_height / 2) * 80
    ; Even rows: stored at offset 0 through odd_bank_offset - 1
    ; Odd rows:  stored at odd_bank_offset through end
    mov ax, [image_height]
    inc ax
    shr ax, 1                   ; ceil(image_height / 2)
    mov bx, BYTES_PER_ROW
    mul bx                      ; AX = ceil(height/2) * 80
    mov [odd_bank_offset], ax

    ; Total buffer size: image_height * 80
    mov ax, [image_height]
    mov bx, BYTES_PER_ROW
    mul bx                      ; DX:AX (max 800*80 = 64000, fits in AX)
    mov [image_size_bytes], ax

    ; Allocate memory: convert bytes to paragraphs
    mov bx, ax
    add bx, 15
    shr bx, 4                   ; Paragraphs needed
    mov ah, 0x48                ; DOS: Allocate memory
    int 0x21
    jc .alloc_error
    mov [image_buffer_seg], ax

    ; Zero the buffer (ensures clean partial-image display)
    mov es, ax
    xor di, di
    mov cx, [image_size_bytes]
    shr cx, 1
    xor ax, ax
    cld
    rep stosw

    ; Decode BMP rows bottom-up into interlaced RAM buffer
    mov ax, [image_height]
    dec ax
    mov [current_row], ax

.row_loop:
    ; Read one BMP row from file
    mov bx, [file_handle]
    mov dx, row_buffer
    mov cx, [bytes_per_bmp_row]
    mov ah, 0x3F
    int 0x21
    jc .decode_done
    or ax, ax
    jz .decode_done

    ; Border color cycling during load (visual feedback)
    mov al, [border_ctr]
    out PORT_COLOR, al
    inc byte [border_ctr]
    and byte [border_ctr], 0x0F

    ; Calculate destination in RAM buffer
    mov ax, [current_row]
    mov bx, ax
    shr ax, 1                   ; Even row index = row / 2
    mov dx, BYTES_PER_ROW
    mul dx                      ; AX = (row/2) * 80
    mov di, ax
    test bx, 1                  ; Is original row odd?
    jz .is_even_row
    add di, [odd_bank_offset]   ; Odd rows go to second half of buffer
.is_even_row:

    ; Set ES = image buffer segment
    mov es, [image_buffer_seg]

    cmp byte [downsample_flag], 0
    je .no_downsample

    ; Downsample 320 -> 160: take high nibble of each pair
    mov si, row_buffer
    mov cx, 80
.downsample_loop:
    lodsb
    and al, 0xF0                ; Keep high nibble (left pixel)
    mov ah, al
    lodsb
    shr al, 4                   ; Move high nibble to low (right pixel)
    or al, ah                   ; Combine into one byte
    stosb
    loop .downsample_loop
    jmp .row_done

.no_downsample:
    mov si, row_buffer
    mov cx, 80
    rep movsb

.row_done:
    dec word [current_row]
    cmp word [current_row], 0xFFFF  ; Wrapped past 0?
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
; Data Section
; ============================================================================

msg_info    db 'DEMO9B - Vertical R12/R13 Effects Demo (192-line mode)', 0x0D, 0x0A
            db 'Usage: DEMO9B image.bmp', 0x0D, 0x0A
            db 0x0D, 0x0A
            db 'Supports 160 or 320 wide, 1-800 rows tall, 4-bit BMP.', 0x0D, 0x0A
            db 'All effects use row-aligned vertical movement (no seam).', 0x0D, 0x0A
            db '192-line mode + gap patching eliminates black lines.', 0x0D, 0x0A
            db 0x0D, 0x0A
            db 'Controls:', 0x0D, 0x0A
            db '  S       - Screen shake (vertical jitter)', 0x0D, 0x0A
            db '  H       - Vertical wave (gentle bob)', 0x0D, 0x0A
            db '  T       - Drop-in transition', 0x0D, 0x0A
            db '  B       - Bounce effect', 0x0D, 0x0A
            db '  M       - Vertical scroll (ping-pong)', 0x0D, 0x0A
            db '  1-6     - Shake intensity', 0x0D, 0x0A
            db '  UP/DOWN - Navigate tall images', 0x0D, 0x0A
            db '  PgUp/Dn - Navigate (half-screen steps)', 0x0D, 0x0A
            db '  Home/End- Jump to top/bottom', 0x0D, 0x0A
            db '  V       - Toggle VSync', 0x0D, 0x0A
            db '  R       - Reset effects', 0x0D, 0x0A
            db '  ESC     - Exit to DOS', 0x0D, 0x0A, '$'

msg_file_err db 'Error: Cannot open file', 0x0D, 0x0A, '$'
msg_not_bmp  db 'Error: Not a valid BMP file', 0x0D, 0x0A, '$'
msg_format   db 'Error: BMP must be 4-bit uncompressed', 0x0D, 0x0A, '$'
msg_size     db 'Error: Must be 160 or 320 wide, 1-800 tall', 0x0D, 0x0A, '$'
msg_mem_err  db 'Error: Cannot allocate memory for image', 0x0D, 0x0A, '$'

; File handling
filename_ptr     dw 0
file_handle      dw 0
image_width      dw 0
image_height     dw 0
bytes_per_bmp_row dw 0
current_row      dw 0
downsample_flag  db 0
border_ctr       db 0

; Image buffer
image_buffer_seg dw 0           ; Segment of allocated RAM buffer
odd_bank_offset  dw 0           ; Offset to odd rows in buffer
image_size_bytes dw 0           ; Total buffer size in bytes

; View state (for tall image navigation)
view_row        dw 0            ; Current top row displayed (always even)
max_view_row    dw 0            ; Maximum view_row value

; Effect state variables
shake_active    db 0            ; 1 = shake enabled
shake_intensity db 3            ; Shake intensity (1-6 rows)
need_reset      db 0            ; Flag to reset CRTC after effect stops
vwave_active    db 0            ; 1 = vertical wave active
drop_active     db 0            ; 1 = drop-in transition active
bounce_active   db 0            ; 1 = bounce effect active
marquee_active  db 0            ; 1 = vertical scroll active
vsync_enabled   db 1            ; 1 = vsync on (default), 0 = free running

; Standard CGA palette
cga_colors:
    db 0x00, 0x00    ; 0:  Black
    db 0x00, 0x05    ; 1:  Blue
    db 0x00, 0x50    ; 2:  Green
    db 0x00, 0x55    ; 3:  Cyan
    db 0x05, 0x00    ; 4:  Red
    db 0x05, 0x05    ; 5:  Magenta
    db 0x05, 0x20    ; 6:  Brown
    db 0x05, 0x55    ; 7:  Light Gray
    db 0x02, 0x22    ; 8:  Dark Gray
    db 0x02, 0x27    ; 9:  Light Blue
    db 0x02, 0x72    ; 10: Light Green
    db 0x02, 0x77    ; 11: Light Cyan
    db 0x07, 0x22    ; 12: Light Red
    db 0x07, 0x27    ; 13: Light Magenta
    db 0x07, 0x70    ; 14: Yellow
    db 0x07, 0x77    ; 15: White

; Buffers
bmp_header:     times 128 db 0
row_buffer:     times 164 db 0

end_program:

; ============================================================================
; End of Program
; ============================================================================
