; ============================================================================
; PALRAM9C.ASM - BMP Image + Animated Raster Bars (Hybrid Write Method)
;               Optimized OUTSB×4 (E0+E1) + REP OUTSB×12 (E2-E7) per scanline
; ============================================================================
;
; CONFIRMED WORKING on real PC1 hardware (March 2026).
; Based on palram9b, with an optimized hybrid write method:
; OUTSB×4 for E0+E1 (fast first-byte latency, no REP startup delay)
; followed by REP OUTSB×12 for E2-E7 (compact code, inactive bank).
; Every scanline writes ALL entries — E0 through E7 — in a single
; palette write session opened at 0x40. This allows raster bars and
; image content to coexist on the same scanlines.
;
; TECHNIQUE ORIGIN: PC1-BMP v6.0 "E0 Reprogramming" proved that a single
; 0x40-opened write session can stream 16 bytes (E0-E7) per scanline.
; E0 completes within HBLANK (~55 cycles). E1 is unused in CGA mode 4.
; E2-E7 spill into the visible area but target the inactive palette set
; (flip-first technique), so no artifacts appear.
;
; The BMP image is displayed in CGA mode 4 (320x200x4) using the
; flip-first palette technique from pc1-bmp4: per-scanline palette flip
; via port 0xD9 gives 3 independent colors per scanline by alternating
; between two palette selects (entries {0,2,4,6} and {0,3,5,7}).
;
; On top of this, two animated raster bars (red + cyan) from palram7b
; bounce via sine wave and redefine entry 0 (background/border) per
; scanline. The bars appear in the BLACK/background areas of the image,
; creating a colorful light-beam effect through the dark regions while
; preserving the actual image content. Because there is no zone split,
; bars can sweep across the image area itself.
;
; ============================================================================
; UNIFIED RENDER — No Zone Split
; ============================================================================
;
; All 200 visible scanlines are treated identically. Each scanline:
;   1. Waits for HBLANK
;   2. Flips palette select (PAL_ODD ↔ PAL_EVEN)
;   3. Opens palette at E0 (0x40)
;   4. Hybrid stream: OUTSB×4 (E0+E1), then REP OUTSB×12 (E2-E7)
;   5. Closes palette (0x80)
;
; The 16-byte palette_stream is pre-built:
;   - Bytes  0-1:  E0 (background) — updated every frame from bar data
;   - Bytes  2-3:  E1 (unused, always zero)
;   - Bytes  4-15: E2-E7 (flip-first interleaved image colors, static)
;
; Per-frame update: update_stream_e0 copies the 2-byte bar color for
; each scanline into the E0 slot of each 16-byte record. Only 400
; bytes of scattered writes per frame (200 lines × 2 bytes).
;
; ============================================================================
; HBLANK TIMING — Combined E0+E2-E7 Fit
; ============================================================================
;
; After HBLANK detected:
;   Flip palette       ~12 cycles   (running: 12)
;   xchg bl,bh         ~3 cycles    (running: 15)
;   Open 0x40          ~12 cycles   (running: 27)
;   PUSH CX            ~4 cycles    (running: 31)
;   MOV CX,16          ~4 cycles    (running: 35)
;   OUTSB×4 + REP×12   ~224 cycles  (running: 259) ← E0-E7 all 16 bytes
;     E0 completes     at ~63 cycles from HBLANK    ← within HBLANK
;     E1 completes     at ~91 cycles                ← borderline (unused)
;     E2-E7            remainder                    ← targets inactive set
;   POP CX             ~4 cycles    (running: 263)
;   Close 0x80         ~12 cycles   (running: 275)
;
; E0 completes at ~55 cycles, within the ~72-80 cycle HBLANK window.
; E1 is not displayed in CGA mode 4, so spill is harmless.
; E2-E7 write to the inactive palette (flip-first), no artifacts.
;
; ============================================================================
; WHAT WORKS / EXPECTED ARTIFACTS (verified on real PC1, March 2026)
; ============================================================================
;
;   ✅ CGA palette flip is 100% stable — no flicker, no shimmer
;   ✅ Raster bars display across entire screen, overlapping with image
;   ✅ Bars show through wherever pixel value 0 (background) appears
;   ✅ Image displays correctly with 3 colors per scanline via flip-first
;   ⚠️ Tiny left-edge artifact on the first few pixels of raster bar lines
;     caused by E0 write completing at the edge of HBLANK window (~55 of
;     ~72-80 available cycles). This is inherent to E0 streaming and cannot
;     be eliminated (4 OUT instructions are the minimum for E0 open/write).
;   ⚠️ Colored border on bar lines (E0 affects border area too — CGA rule)
;
; ============================================================================
; SKIP-IF-SAME — Why It's Not Used Here
; ============================================================================
;
;   Several skip optimizations were tested on real hardware and all caused
;   severe full-screen blinking:
;
;   1. Same-parity (N vs N-2): skip both flip and write if data matches
;   2. Frame-to-frame: compare with previous frame's stream for same line
;   3. All-zeros detection: skip lines where all 16 stream bytes are zero
;   4. Skip write only (still flip): hardware shows stale palette data
;   5. Open at 0x44 (skip E0-E1): tested, blinked — mixing 0x40/0x44
;      per-scanline is unreliable (PC1-BMP4 uses 0x44 consistently, works)
;   6. Split session (0x40 for E0 + close + 0x44 for E2-E7): blinked —
;      two open/close cycles per scanline is unreliable with flip-first
;
;   Root cause: the HSYNC polling loop expects CONSTANT time per iteration.
;   The write path takes ~200+ cycles (flip + open + 16 OUTSB + close).
;   The skip path takes ~20 cycles. When a skip finishes early, the next
;   poll catches the wrong HBLANK edge — either re-triggering on the same
;   scanline or drifting to a different one. This timing jitter accumulates
;   across scanlines, causing visible blinking at zone transitions.
;
;   The only fixes would be padding the skip path to match write timing
;   (defeats the purpose) or using a hardware timer interrupt instead of
;   polling (major architectural change). Neither is worthwhile here.
;
;   Conclusion: with polling-based HSYNC, every scanline must execute the
;   same write path for stable display. The hybrid approach writes all 200
;   lines every frame.
;
; ============================================================================
; THREE WRITE METHODS TESTED (all using single 0x40 session per scanline)
; ============================================================================
;
;   Method          | E0 Latency   | Artifacts           | Code Size
;   ----------------+--------------+---------------------+----------
;   16× unrolled OUT | Fastest      | Best (not 100%)     | Largest
;   Hybrid OUTSB    | Fast         | Best (not 100%)     | Medium
;   REP OUTSB       | Slowest      | Left-side bar glitch| Smallest
;
;   E0 first-byte latency determines artifact severity. REP's ~17-cycle
;   startup delay pushes E0 past the safe HBLANK window on some scanlines.
;   The hybrid (OUTSB×4 for E0+E1, REP OUTSB×12 for E2-E7) matches
;   unrolled OUT performance at smaller code size.
;
; ============================================================================
; TECHNIQUES USED
; ============================================================================
;
;   From pc1-bmp4: flip-first palette, 3 colors/line, OUTSB streaming,
;     two-pass BMP analysis, stability reordering, DX=0xDE permanently
;   From palram7b: sine-wave bounce, dual bars (red + cyan)
;   From PC1-BMP v6.0: combined E0+E2-E7 in single 0x40 write session
;   New: unified render loop (no zones), per-frame E0 slot update
;
; Controls:
;   SPACE : Toggle raster bar animation on/off
;   S     : Toggle vblank sync on/off
;   ESC   : Exit to DOS
;
; Written for NASM assembler
; Target: Olivetti Prodest PC1 with Yamaha V6355D video controller
; CPU: NEC V40 (80186 compatible) @ 8 MHz
;
; By Retro Erik - 2026 with help from GitHub Copilot
;
; ============================================================================
; BUILD
; ============================================================================
;
;   nasm -f bin -o palram9b.com palram9b.asm
;
; ============================================================================
; USAGE
; ============================================================================
;
;   palram9b filename.bmp
;
; ============================================================================

[BITS 16]
[CPU 186]
[ORG 0x100]

; ============================================================================
; Constants
; ============================================================================

VIDEO_SEG       equ 0xB800      ; CGA video RAM segment

; V6355D I/O Ports (short aliases for speed-critical code)
PORT_MODE       equ 0xD8        ; CGA Mode Control
PORT_COLOR      equ 0xD9        ; CGA Color Select / Palette Select
PORT_STATUS     equ 0xDA        ; CGA Status Register
PORT_REG_ADDR   equ 0xDD        ; V6355D Register Bank Address
PORT_REG_DATA   equ 0xDE        ; V6355D Register Bank Data

; BMP file header offsets
BMP_SIGNATURE   equ 0           ; 'BM' (2 bytes)
BMP_DATA_OFFSET equ 10          ; Offset to pixel data (dword)
BMP_WIDTH       equ 18          ; Image width (dword)
BMP_HEIGHT      equ 22          ; Image height (dword)
BMP_BPP         equ 28          ; Bits per pixel (word)
BMP_COMPRESSION equ 30          ; Compression (dword)
BMP_PALETTE_OFF equ 54          ; BMP palette starts here

; Screen constants
SCREEN_HEIGHT   equ 200
CGA_ROW_BYTES   equ 80          ; 320 pixels / 4 pixels per byte
BMP_ROW_4BPP    equ 160         ; 320 pixels at 4bpp (2 pixels/byte)
BMP_ROW_8BPP    equ 320         ; 320 pixels at 8bpp (1 pixel/byte)

; CGA mode 4 control values (port 0xD8)
CGA_MODE4_OFF   equ 0x02        ; 320x200 graphics, video OFF
CGA_MODE4_ON    equ 0x0A        ; 320x200 graphics, video ON

; Palette select values (port 0xD9)
PAL_EVEN        equ 0x00        ; Palette 0: entries {0,2,4,6}
PAL_ODD         equ 0x20        ; Palette 1: entries {0,3,5,7}

; ============================================================================
; Raster Bar Configuration
; ============================================================================

LINES_PER_COLOR equ 1           ; Scanlines per gradient color
BAR_HEIGHT      equ 14 * LINES_PER_COLOR  ; Total bar height (14 lines)

; Per-bar speed (higher = faster wobble)
BAR1_SPEED      equ 4
BAR2_SPEED      equ 3

; Per-bar starting phase (0-255)
BAR1_PHASE      equ 0
BAR2_PHASE      equ 85          ; 1/3 cycle offset (120 degrees)

; ============================================================================
; Main Program Entry Point
; ============================================================================
main:
    cld
    push ds
    pop es                      ; ES = DS for .COM

    ; --- Parse command line ---
    mov si, 0x81

.skip_spaces:
    lodsb
    cmp al, ' '
    je .skip_spaces
    cmp al, 0x0D
    je .show_usage

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
    mov byte [si], 0            ; Null-terminate filename

    ; --- Open BMP file ---
    mov dx, [filename_ptr]
    mov ax, 0x3D00              ; DOS Open File (read-only)
    int 0x21
    jc .file_error
    mov [file_handle], ax

    ; --- Read header + palette (up to 1078 bytes) ---
    mov bx, ax
    mov dx, bmp_header
    mov cx, 1078
    mov ah, 0x3F
    int 0x21
    jc .file_error
    cmp ax, 54
    jb .file_error

    ; --- Validate BMP ---
    cmp word [bmp_header + BMP_SIGNATURE], 0x4D42
    jne .not_bmp

    ; --- Detect BPP ---
    mov ax, [bmp_header + BMP_BPP]
    cmp ax, 4
    je .bpp_4
    cmp ax, 8
    je .bpp_8
    jmp .wrong_format

.bpp_4:
    mov byte [bmp_bpp], 4
    mov word [num_colors], 16
    mov word [bmp_row_bytes], BMP_ROW_4BPP
    jmp .bpp_done

.bpp_8:
    mov byte [bmp_bpp], 8
    mov word [num_colors], 256
    mov word [bmp_row_bytes], BMP_ROW_8BPP

.bpp_done:
    cmp word [bmp_header + BMP_COMPRESSION], 0
    jne .wrong_format
    cmp word [bmp_header + BMP_COMPRESSION + 2], 0
    jne .wrong_format

    cmp word [bmp_header + BMP_WIDTH], 320
    jne .wrong_size
    cmp word [bmp_header + BMP_HEIGHT], 200
    jne .wrong_size

    ; --- Convert BMP palette ---
    call convert_bmp_palette

    ; --- Auto-detect background (darkest entry) ---
    call find_bg_index

    ; --- Show splash ---
    mov ax, 0x0003
    int 0x10
    mov dx, msg_splash
    mov ah, 0x09
    int 0x21

    ; --- Seek to pixel data for Pass 1 ---
    mov bx, [file_handle]
    mov dx, [bmp_header + BMP_DATA_OFFSET]
    mov cx, [bmp_header + BMP_DATA_OFFSET + 2]
    mov ax, 0x4200
    int 0x21
    jc .file_error

    ; --- PASS 1: Analyze image (top 3 colors per scanline) ---
    call analyze_image

    ; --- Reorder by stability ---
    call reorder_by_stability

    ; --- Build per-scanline palette stream (E0-E7, 16 bytes/line) ---
    call build_palette_stream

    ; --- Seek back to pixel data for Pass 2 ---
    mov bx, [file_handle]
    mov dx, [bmp_header + BMP_DATA_OFFSET]
    mov cx, [bmp_header + BMP_DATA_OFFSET + 2]
    mov ax, 0x4200
    int 0x21

    ; --- PASS 2: Remap pixels to RAM buffer (splash stays visible) ---
    call render_to_buffer

    ; --- Close file ---
    mov bx, [file_handle]
    mov ah, 0x3E
    int 0x21

    ; --- Set CGA mode 4 + blank video ---
    mov ax, 0x0004
    int 0x10
    cld
    mov al, CGA_MODE4_OFF
    out PORT_MODE, al

    ; --- Copy buffer to VRAM (fast REP MOVSW, ~8ms) ---
    push ds
    pop es                      ; Restore ES = DS after INT 10h
    call copy_buffer_to_vram

    ; --- Program initial palette ---
    call program_initial_palette

    ; --- Initialize raster bar state ---
    mov byte [bar1_sine_idx], BAR1_PHASE
    mov byte [bar2_sine_idx], BAR2_PHASE
    mov byte [bars_enabled], 1

    ; --- Enable video ---
    mov al, PAL_EVEN
    out PORT_COLOR, al
    mov al, CGA_MODE4_ON
    out PORT_MODE, al

    ; ========================================================================
    ; Display loop: animate raster bars + render frame
    ; ========================================================================
.display_loop:
    ; --- Update raster bar positions ---
    cmp byte [bars_enabled], 0
    je .skip_bar_update

    ; Update bar 1 (full-screen bounce, top-biased)
    add byte [bar1_sine_idx], BAR1_SPEED
    mov al, [bar1_sine_idx]
    xor ah, ah
    mov si, ax
    mov al, [sine_table + si]  ; Range: 3-97
    mov [bar1_y], al

    ; Update bar 2 (full-screen bounce, bottom-biased)
    add byte [bar2_sine_idx], BAR2_SPEED
    mov al, [bar2_sine_idx]
    xor ah, ah
    mov si, ax
    mov al, [sine_table + si]  ; Range: 3-97
    add al, 90                 ; Range: 93-187
    mov [bar2_y], al

    call build_scanline_table
    jmp .do_render

.skip_bar_update:
    ; Bars disabled — fill scanline_colors with black
    call clear_scanline_table

.do_render:
    call update_stream_e0       ; Copy bar colors into palette stream E0 slots
    cmp byte [sync_enabled], 0
    je .no_sync
    call wait_vblank
.no_sync:
    call render_frame

    ; --- Check keyboard ---
    call check_keyboard
    cmp al, 0xFF
    je .exit_program
    cmp al, 0x20                ; SPACE = toggle bars
    jne .not_space
    xor byte [bars_enabled], 1
    jmp .display_loop
.not_space:
    cmp al, 's'                 ; S = toggle sync
    je .toggle_sync
    cmp al, 'S'
    jne .display_loop
.toggle_sync:
    xor byte [sync_enabled], 1
    jmp .display_loop

.exit_program:
    call set_cga_palette
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
    jmp .print_exit

.show_usage:
    mov dx, msg_info
    mov ah, 0x09
    int 0x21
    mov ax, 0x4C00
    int 0x21

.print_exit:
    mov ah, 0x09
    int 0x21
    mov ax, 0x4C01
    int 0x21

; ============================================================================
; convert_bmp_palette - BMP BGRA → RGB888 + V6355D format
; ============================================================================
convert_bmp_palette:
    push ax
    push bx
    push cx
    push si
    push di

    mov si, bmp_header + BMP_PALETTE_OFF
    xor di, di
    mov cx, [num_colors]

.cvt_loop:
    lodsb                       ; Blue
    mov [pal_b + di], al
    lodsb                       ; Green
    mov [pal_g + di], al
    lodsb                       ; Red
    mov [pal_r + di], al

    ; V6355D 2-byte entry
    mov bx, di
    shl bx, 1

    mov al, [pal_r + di]
    shr al, 5
    mov [v6355_pal + bx], al

    mov al, [pal_g + di]
    and al, 0xE0
    shr al, 1
    mov ah, al
    mov al, [pal_b + di]
    shr al, 5
    or al, ah
    mov [v6355_pal + bx + 1], al

    lodsb                       ; Skip alpha

    inc di
    loop .cvt_loop

    pop di
    pop si
    pop cx
    pop bx
    pop ax
    ret

; ============================================================================
; find_bg_index - Auto-detect darkest palette entry as background
; ============================================================================
find_bg_index:
    push ax
    push bx
    push cx
    push dx
    push si

    xor ax, ax
    mov dx, 0xFFFF
    xor bx, bx
    mov cx, [num_colors]

.fbg_loop:
    xor si, si
    push ax
    xor ah, ah
    mov al, [pal_r + bx]
    add si, ax
    mov al, [pal_g + bx]
    add si, ax
    mov al, [pal_b + bx]
    add si, ax
    pop ax

    cmp si, dx
    jae .fbg_not_darker
    mov dx, si
    mov ax, bx

.fbg_not_darker:
    inc bx
    loop .fbg_loop

    mov [bg_index], al

    xor bh, bh
    mov bl, al
    mov byte [pal_r + bx], 0
    mov byte [pal_g + bx], 0
    mov byte [pal_b + bx], 0
    shl bx, 1
    mov word [v6355_pal + bx], 0

    pop si
    pop dx
    pop cx
    pop bx
    pop ax
    ret

; ============================================================================
; analyze_image - Pass 1: Read all BMP rows, find top 3 colors per scanline
; ============================================================================
analyze_image:
    push ax
    push bx
    push cx
    push dx
    push si
    push di

    mov word [current_row], 199

.analyze_loop:
    call read_bmp_row
    jc .analyze_done
    cmp ax, [bmp_row_bytes]
    jb .analyze_done

    call analyze_scanline

    mov ax, [current_row]
    or ax, ax
    jz .analyze_done
    dec word [current_row]
    jmp .analyze_loop

.analyze_done:
    pop di
    pop si
    pop dx
    pop cx
    pop bx
    pop ax
    ret

; ============================================================================
; analyze_scanline - Count colors, find top 3 for this scanline
; ============================================================================
analyze_scanline:
    push ax
    push bx
    push cx
    push dx
    push si
    push di

    ; Clear color counts (256 words)
    push es
    push ds
    pop es
    mov di, color_count
    mov cx, 256
    xor ax, ax
    rep stosw
    pop es

    ; Count pixel colors
    mov si, row_buffer
    cmp byte [bmp_bpp], 8
    je .count_8bpp

    ; 4bpp: 2 pixels per byte
    mov cx, BMP_ROW_4BPP
    xor bh, bh

.count_loop_4:
    lodsb
    mov ah, al

    shr al, 4
    mov bl, al
    add bx, bx
    inc word [color_count + bx]
    shr bx, 1

    mov al, ah
    and al, 0x0F
    mov bl, al
    add bx, bx
    inc word [color_count + bx]
    shr bx, 1

    loop .count_loop_4
    jmp .count_done

.count_8bpp:
    mov cx, BMP_ROW_8BPP
    xor bh, bh

.count_loop_8:
    lodsb
    mov bl, al
    add bx, bx
    inc word [color_count + bx]
    shr bx, 1

    loop .count_loop_8

.count_done:
    ; Exclude background
    xor bx, bx
    mov bl, [bg_index]
    shl bx, 1
    mov word [color_count + bx], 0

    ; Find top 3
    call find_max_color
    mov [top3_temp], al
    xor bx, bx
    mov bl, al
    shl bx, 1
    mov word [color_count + bx], 0

    call find_max_color
    mov [top3_temp + 1], al
    xor bx, bx
    mov bl, al
    shl bx, 1
    mov word [color_count + bx], 0

    call find_max_color
    mov [top3_temp + 2], al

    ; Store top3 for this scanline
    mov bx, [current_row]
    mov ax, bx
    shl ax, 1
    add bx, ax                  ; BX = row * 3

    mov al, [top3_temp]
    mov [scanline_top3 + bx], al
    mov al, [top3_temp + 1]
    mov [scanline_top3 + bx + 1], al
    mov al, [top3_temp + 2]
    mov [scanline_top3 + bx + 2], al

    pop di
    pop si
    pop dx
    pop cx
    pop bx
    pop ax
    ret

; ============================================================================
; find_max_color - Find palette index with highest pixel count
; ============================================================================
find_max_color:
    push bx
    push cx
    push dx

    xor ax, ax
    mov al, [bg_index]
    xor dx, dx
    xor bx, bx
    mov cx, [num_colors]

.fmc_loop:
    cmp [color_count + bx], dx
    jbe .fmc_not_better
    mov dx, [color_count + bx]
    mov ax, bx
    shr ax, 1

.fmc_not_better:
    add bx, 2
    dec cx
    jnz .fmc_loop

    pop dx
    pop cx
    pop bx
    ret

; ============================================================================
; reorder_by_stability - Most stable colors → highest palette entries
; ============================================================================
reorder_by_stability:
    push ax
    push bx
    push cx
    push dx
    push si
    push di

    ; Clear line presence count
    push es
    push ds
    pop es
    mov di, color_line_count
    mov cx, 256
    xor ax, ax
    rep stosw
    pop es

    ; Count lines where each color appears
    mov si, scanline_top3
    mov cx, 200
.rbs_count:
    lodsb
    cmp al, [bg_index]
    je .rbs_skip1
    xor bx, bx
    mov bl, al
    shl bx, 1
    inc word [color_line_count + bx]
.rbs_skip1:
    lodsb
    cmp al, [bg_index]
    je .rbs_skip2
    xor bx, bx
    mov bl, al
    shl bx, 1
    inc word [color_line_count + bx]
.rbs_skip2:
    lodsb
    cmp al, [bg_index]
    je .rbs_skip3
    xor bx, bx
    mov bl, al
    shl bx, 1
    inc word [color_line_count + bx]
.rbs_skip3:
    loop .rbs_count

    ; Find most common → global_c (entries 6/7)
    xor ax, ax
    mov al, [bg_index]
    xor dx, dx
    xor bx, bx
    mov cx, [num_colors]
.rbs_find1:
    cmp [color_line_count + bx], dx
    jbe .rbs_f1_skip
    mov dx, [color_line_count + bx]
    mov ax, bx
    shr ax, 1
.rbs_f1_skip:
    add bx, 2
    loop .rbs_find1

    mov [global_c], al

    cmp al, [bg_index]
    je .rbs_no_reorder
    xor bx, bx
    mov bl, al
    shl bx, 1
    mov word [color_line_count + bx], 0

    ; Find 2nd most common → global_b (entries 4/5)
    xor ax, ax
    mov al, [bg_index]
    xor dx, dx
    xor bx, bx
    mov cx, [num_colors]
.rbs_find2:
    cmp [color_line_count + bx], dx
    jbe .rbs_f2_skip
    mov dx, [color_line_count + bx]
    mov ax, bx
    shr ax, 1
.rbs_f2_skip:
    add bx, 2
    loop .rbs_find2

    mov [global_b], al

    ; Reorder each line's top3
    mov si, scanline_top3
    mov cx, 200
.rbs_reorder:
    mov al, [si]
    mov ah, [si + 1]
    mov dl, [si + 2]

    mov dh, [global_c]
    cmp dl, dh
    je .rbs_check_b
    cmp al, dh
    je .rbs_c_in_0
    cmp ah, dh
    je .rbs_c_in_1
    jmp .rbs_check_b

.rbs_c_in_0:
    xchg al, dl
    jmp .rbs_check_b

.rbs_c_in_1:
    xchg ah, dl

.rbs_check_b:
    mov dh, [global_b]
    cmp dh, [bg_index]
    je .rbs_store
    cmp ah, dh
    je .rbs_store
    cmp al, dh
    jne .rbs_store
    xchg al, ah

.rbs_store:
    mov [si], al
    mov [si + 1], ah
    mov [si + 2], dl

    add si, 3
    loop .rbs_reorder

.rbs_no_reorder:
    pop di
    pop si
    pop dx
    pop cx
    pop bx
    pop ax
    ret

; ============================================================================
; build_palette_stream - Unified V6355D data (E0-E7, 16 bytes/line)
; ============================================================================
;
; Builds 16-byte records for all 200 scanlines:
;   Bytes  0-1:  E0 = black placeholder (updated per-frame by update_stream_e0)
;   Bytes  2-3:  E1 = zeros (unused entry in CGA mode 4)
;   Bytes  4-15: E2-E7 = flip-first interleaved image colors (static)
;
; E2-E7 interleaving (Simone-calibrated flip-first):
;
;   Even line N (just flipped to pal 1 — entries 3,5,7 now active):
;     E2 = line N+2 color A  (inactive, pre-load for next even line)
;     E3 = line N+1 color A  (active, same-value passthrough)
;     E4 = line N+2 color B  (inactive, pre-load)
;     E5 = line N+1 color B  (active, passthrough)
;     E6 = line N+2 color C  (inactive, pre-load)
;     E7 = line N+1 color C  (active, passthrough)
;
;   Odd line N (just flipped to pal 0 — entries 2,4,6 now active):
;     E2 = line N+1 color A  (active, same-value passthrough)
;     E3 = line N+2 color A  (inactive, pre-load for next odd line)
;     E4 = line N+1 color B  (active, passthrough)
;     E5 = line N+2 color B  (inactive, pre-load)
;     E6 = line N+1 color C  (active, passthrough)
;     E7 = line N+2 color C  (inactive, pre-load)
;
; Total: 200 lines × 16 bytes = 3200 bytes.
; ============================================================================
build_palette_stream:
    push ax
    push bx
    push cx
    push dx
    push si
    push di

    xor cx, cx
    mov di, palette_stream

.bps_loop:
    ; E0: black placeholder (updated per-frame by update_stream_e0)
    mov word [di], 0

    ; E1: unused entry (always zero)
    mov word [di + 2], 0

    ; Far line (N+2): inactive pre-load target
    mov bx, cx
    add bx, 2
    cmp bx, 200
    jb .bps_far_ok
    sub bx, 200
.bps_far_ok:
    mov ax, bx
    shl ax, 1
    add bx, ax

    mov al, [scanline_top3 + bx]
    mov [bps_cur_a], al
    mov al, [scanline_top3 + bx + 1]
    mov [bps_cur_b], al
    mov al, [scanline_top3 + bx + 2]
    mov [bps_cur_c], al

    ; Near line (N+1): same-value passthrough
    mov bx, cx
    inc bx
    cmp bx, 200
    jb .bps_near_ok
    sub bx, 200
.bps_near_ok:
    mov ax, bx
    shl ax, 1
    add bx, ax

    mov al, [scanline_top3 + bx]
    mov [bps_nxt_a], al
    mov al, [scanline_top3 + bx + 1]
    mov [bps_nxt_b], al
    mov al, [scanline_top3 + bx + 2]
    mov [bps_nxt_c], al

    test cl, 1
    jnz .bps_odd

    ; EVEN line: pal 1 active (E3,E5,E7 active)
    ; E2=far A, E3=near A, E4=far B, E5=near B, E6=far C, E7=near C
    xor bx, bx
    mov bl, [bps_cur_a]
    shl bx, 1
    mov ax, [v6355_pal + bx]
    mov [di + 4], ax

    xor bx, bx
    mov bl, [bps_nxt_a]
    shl bx, 1
    mov ax, [v6355_pal + bx]
    mov [di + 6], ax

    xor bx, bx
    mov bl, [bps_cur_b]
    shl bx, 1
    mov ax, [v6355_pal + bx]
    mov [di + 8], ax

    xor bx, bx
    mov bl, [bps_nxt_b]
    shl bx, 1
    mov ax, [v6355_pal + bx]
    mov [di + 10], ax

    xor bx, bx
    mov bl, [bps_cur_c]
    shl bx, 1
    mov ax, [v6355_pal + bx]
    mov [di + 12], ax

    xor bx, bx
    mov bl, [bps_nxt_c]
    shl bx, 1
    mov ax, [v6355_pal + bx]
    mov [di + 14], ax

    jmp .bps_next

.bps_odd:
    ; ODD line: pal 0 active (E2,E4,E6 active)
    ; E2=near A, E3=far A, E4=near B, E5=far B, E6=near C, E7=far C
    xor bx, bx
    mov bl, [bps_nxt_a]
    shl bx, 1
    mov ax, [v6355_pal + bx]
    mov [di + 4], ax

    xor bx, bx
    mov bl, [bps_cur_a]
    shl bx, 1
    mov ax, [v6355_pal + bx]
    mov [di + 6], ax

    xor bx, bx
    mov bl, [bps_nxt_b]
    shl bx, 1
    mov ax, [v6355_pal + bx]
    mov [di + 8], ax

    xor bx, bx
    mov bl, [bps_cur_b]
    shl bx, 1
    mov ax, [v6355_pal + bx]
    mov [di + 10], ax

    xor bx, bx
    mov bl, [bps_nxt_c]
    shl bx, 1
    mov ax, [v6355_pal + bx]
    mov [di + 12], ax

    xor bx, bx
    mov bl, [bps_cur_c]
    shl bx, 1
    mov ax, [v6355_pal + bx]
    mov [di + 14], ax

.bps_next:
    add di, 16                  ; 16 bytes per line
    inc cx
    cmp cx, 200
    jb .bps_loop

    pop di
    pop si
    pop dx
    pop cx
    pop bx
    pop ax
    ret

; ============================================================================
; render_to_buffer - Pass 2: Read BMP, remap pixels, write to RAM buffer
; ============================================================================
render_to_buffer:
    push ax
    push bx
    push cx
    push dx
    push si
    push di

    mov word [current_row], 199

.rv_loop:
    call read_bmp_row
    jc .rv_done
    cmp ax, [bmp_row_bytes]
    jb .rv_done

    call build_remap_table

    ; CGA interlaced offset into RAM buffer
    mov ax, [current_row]
    push ax
    shr ax, 1
    mov bx, CGA_ROW_BYTES
    mul bx
    mov di, ax
    pop ax
    test al, 1
    jz .rv_even
    add di, 0x2000
.rv_even:
    add di, vram_buffer         ; DI = offset within DS

    mov si, row_buffer
    mov bx, remap_table
    mov cx, CGA_ROW_BYTES

    cmp byte [bmp_bpp], 8
    je .rv_convert_8

    ; 4bpp conversion
.rv_convert_4:
    xor dh, dh

    lodsb
    mov dl, al
    shr al, 4
    xlat
    or dh, al
    shl dh, 2

    mov al, dl
    and al, 0x0F
    xlat
    or dh, al
    shl dh, 2

    lodsb
    mov dl, al
    shr al, 4
    xlat
    or dh, al
    shl dh, 2

    mov al, dl
    and al, 0x0F
    xlat
    or dh, al

    mov al, dh
    mov [di], al
    inc di
    loop .rv_convert_4
    jmp .rv_convert_done

    ; 8bpp conversion
.rv_convert_8:
    xor dh, dh

    lodsb
    xlat
    or dh, al
    shl dh, 2

    lodsb
    xlat
    or dh, al
    shl dh, 2

    lodsb
    xlat
    or dh, al
    shl dh, 2

    lodsb
    xlat
    or dh, al

    mov al, dh
    mov [di], al
    inc di
    loop .rv_convert_8

.rv_convert_done:
    mov ax, [current_row]
    or ax, ax
    jz .rv_done
    dec word [current_row]
    jmp .rv_loop

.rv_done:
    pop di
    pop si
    pop dx
    pop cx
    pop bx
    pop ax
    ret

; ============================================================================
; copy_buffer_to_vram - Fast REP MOVSW from vram_buffer to CGA VRAM
; ============================================================================
copy_buffer_to_vram:
    push ax
    push cx
    push si
    push di
    push es

    mov ax, VIDEO_SEG
    mov es, ax
    mov si, vram_buffer
    xor di, di
    mov cx, 8192                ; 16384 bytes / 2 = 8192 words
    cld
    rep movsw

    pop es
    pop di
    pop si
    pop cx
    pop ax
    ret

; ============================================================================
; build_remap_table - BMP index → CGA value (0-3)
; ============================================================================
build_remap_table:
    push ax
    push bx
    push cx
    push dx
    push si

    mov bx, [current_row]
    mov ax, bx
    shl ax, 1
    add bx, ax

    mov al, [scanline_top3 + bx]
    mov [top3_temp], al
    mov al, [scanline_top3 + bx + 1]
    mov [top3_temp + 1], al
    mov al, [scanline_top3 + bx + 2]
    mov [top3_temp + 2], al

    xor cx, cx

.brt_loop:
    cmp cl, [bg_index]
    je .brt_black

    cmp cl, [top3_temp]
    je .brt_1
    cmp cl, [top3_temp + 1]
    je .brt_2
    cmp cl, [top3_temp + 2]
    je .brt_3

    call find_nearest
    jmp .brt_store

.brt_black:
    xor al, al
    jmp .brt_store
.brt_1:
    mov al, 1
    jmp .brt_store
.brt_2:
    mov al, 2
    jmp .brt_store
.brt_3:
    mov al, 3

.brt_store:
    mov bx, cx
    mov [remap_table + bx], al
    inc cx
    cmp cx, [num_colors]
    jb .brt_loop

    pop si
    pop dx
    pop cx
    pop bx
    pop ax
    ret

; ============================================================================
; find_nearest - Map BMP index to nearest CGA value by RGB distance
; ============================================================================
find_nearest:
    push bx
    push cx
    push dx
    push si

    xor bh, bh
    mov bl, cl

    ; Distance to black
    xor dx, dx
    mov al, [pal_r + bx]
    xor ah, ah
    add dx, ax
    mov al, [pal_g + bx]
    add dx, ax
    mov al, [pal_b + bx]
    add dx, ax
    mov [nn_best_dist], dx
    mov byte [nn_best_cga], 0

    ; Distance to Color A
    mov al, [top3_temp]
    cmp al, [bg_index]
    je .fn_done
    xor ah, ah
    mov si, ax
    call compute_dist_bx_si
    cmp dx, [nn_best_dist]
    jae .fn_try_2
    mov [nn_best_dist], dx
    mov byte [nn_best_cga], 1

.fn_try_2:
    mov al, [top3_temp + 1]
    cmp al, [bg_index]
    je .fn_done
    xor ah, ah
    mov si, ax
    call compute_dist_bx_si
    cmp dx, [nn_best_dist]
    jae .fn_try_3
    mov [nn_best_dist], dx
    mov byte [nn_best_cga], 2

.fn_try_3:
    mov al, [top3_temp + 2]
    cmp al, [bg_index]
    je .fn_done
    xor ah, ah
    mov si, ax
    call compute_dist_bx_si
    cmp dx, [nn_best_dist]
    jae .fn_done
    mov byte [nn_best_cga], 3

.fn_done:
    mov al, [nn_best_cga]

    pop si
    pop dx
    pop cx
    pop bx
    ret

; ============================================================================
; compute_dist_bx_si - RGB888 Manhattan distance
; ============================================================================
compute_dist_bx_si:
    xor dx, dx

    mov al, [pal_r + bx]
    sub al, [pal_r + si]
    jnc .cd_r_pos
    neg al
.cd_r_pos:
    xor ah, ah
    add dx, ax

    mov al, [pal_g + bx]
    sub al, [pal_g + si]
    jnc .cd_g_pos
    neg al
.cd_g_pos:
    xor ah, ah
    add dx, ax

    mov al, [pal_b + bx]
    sub al, [pal_b + si]
    jnc .cd_b_pos
    neg al
.cd_b_pos:
    xor ah, ah
    add dx, ax
    ret

; ============================================================================
; read_bmp_row - Read one row of BMP pixel data into row_buffer
; ============================================================================
read_bmp_row:
    push bx
    push cx
    push dx
    push es

    mov bx, [file_handle]
    mov dx, row_buffer
    mov cx, [bmp_row_bytes]
    mov ah, 0x3F
    int 0x21

    pop es
    pop dx
    pop cx
    pop bx
    ret

; ============================================================================
; program_initial_palette - Set V6355D entries 0-7 for first frame
; ============================================================================
program_initial_palette:
    push ax
    push bx
    push cx
    push si

    cli

    mov al, 0x40
    out PORT_REG_ADDR, al
    jmp short $+2

    ; Entries 0-1: black
    xor al, al
    out PORT_REG_DATA, al
    jmp short $+2
    out PORT_REG_DATA, al
    jmp short $+2
    out PORT_REG_DATA, al
    jmp short $+2
    out PORT_REG_DATA, al
    jmp short $+2

    ; Entry 2 = line 0, Color A
    xor bx, bx
    mov bl, [scanline_top3]
    shl bx, 1
    mov al, [v6355_pal + bx]
    out PORT_REG_DATA, al
    jmp short $+2
    mov al, [v6355_pal + bx + 1]
    out PORT_REG_DATA, al
    jmp short $+2

    ; Entry 3 = line 1, Color A
    xor bx, bx
    mov bl, [scanline_top3 + 3]
    shl bx, 1
    mov al, [v6355_pal + bx]
    out PORT_REG_DATA, al
    jmp short $+2
    mov al, [v6355_pal + bx + 1]
    out PORT_REG_DATA, al
    jmp short $+2

    ; Entry 4 = line 0, Color B
    xor bx, bx
    mov bl, [scanline_top3 + 1]
    shl bx, 1
    mov al, [v6355_pal + bx]
    out PORT_REG_DATA, al
    jmp short $+2
    mov al, [v6355_pal + bx + 1]
    out PORT_REG_DATA, al
    jmp short $+2

    ; Entry 5 = line 1, Color B
    xor bx, bx
    mov bl, [scanline_top3 + 4]
    shl bx, 1
    mov al, [v6355_pal + bx]
    out PORT_REG_DATA, al
    jmp short $+2
    mov al, [v6355_pal + bx + 1]
    out PORT_REG_DATA, al
    jmp short $+2

    ; Entry 6 = line 0, Color C
    xor bx, bx
    mov bl, [scanline_top3 + 2]
    shl bx, 1
    mov al, [v6355_pal + bx]
    out PORT_REG_DATA, al
    jmp short $+2
    mov al, [v6355_pal + bx + 1]
    out PORT_REG_DATA, al
    jmp short $+2

    ; Entry 7 = line 1, Color C
    xor bx, bx
    mov bl, [scanline_top3 + 5]
    shl bx, 1
    mov al, [v6355_pal + bx]
    out PORT_REG_DATA, al
    jmp short $+2
    mov al, [v6355_pal + bx + 1]
    out PORT_REG_DATA, al
    jmp short $+2

    mov al, 0x80
    out PORT_REG_ADDR, al

    sti

    pop si
    pop cx
    pop bx
    pop ax
    ret

; ============================================================================
; build_scanline_table - Pre-compute raster bar RGB pairs for 200 scanlines
; ============================================================================
build_scanline_table:
    push ax
    push bx
    push cx
    push di

    ; Fill with black
    mov di, scanline_colors
    xor ax, ax
    mov cx, SCREEN_HEIGHT
    rep stosw

    ; Draw both bars (may overlap — cyan drawn second overwrites)
    call draw_red_bar
    call draw_cyan_bar

    pop di
    pop cx
    pop bx
    pop ax
    ret

; ============================================================================
; clear_scanline_table - Fill scanline_colors with black (bars disabled)
; ============================================================================
clear_scanline_table:
    push ax
    push cx
    push di

    mov di, scanline_colors
    xor ax, ax
    mov cx, SCREEN_HEIGHT
    rep stosw

    pop di
    pop cx
    pop ax
    ret

; ----------------------------------------------------------------------------
; draw_red_bar - Red gradient into scanline table
; ----------------------------------------------------------------------------
draw_red_bar:
    push ax
    push bx
    push cx
    push si

    mov al, [bar1_y]
    xor ah, ah
    mov bx, ax
    shl bx, 1
    mov si, red_gradient
    mov cx, BAR_HEIGHT

.draw_loop:
    cmp bx, SCREEN_HEIGHT * 2
    jae .skip_line              ; Off-screen: clip (don't wrap)
    mov ax, [si]
    mov [scanline_colors + bx], ax
.skip_line:
    add bx, 2
    add si, 2
    loop .draw_loop

    pop si
    pop cx
    pop bx
    pop ax
    ret

; ----------------------------------------------------------------------------
; draw_cyan_bar - Cyan gradient into scanline table
; ----------------------------------------------------------------------------
draw_cyan_bar:
    push ax
    push bx
    push cx
    push si

    mov al, [bar2_y]
    xor ah, ah
    mov bx, ax
    shl bx, 1
    mov si, cyan_gradient
    mov cx, BAR_HEIGHT

.draw_loop:
    cmp bx, SCREEN_HEIGHT * 2
    jae .skip_line              ; Off-screen: clip (don't wrap)
    mov ax, [si]
    mov [scanline_colors + bx], ax
.skip_line:
    add bx, 2
    add si, 2
    loop .draw_loop

    pop si
    pop cx
    pop bx
    pop ax
    ret

; ============================================================================
; update_stream_e0 - Copy bar colors into palette stream E0 slots
; ============================================================================
;
; Called once per frame, after build_scanline_table. Copies the 2-byte
; bar color (R, G|B) from scanline_colors[N] into palette_stream[N*16]
; for all 200 scanlines. Only 400 bytes of scattered writes per frame.
;
; When bars are disabled, scanline_colors is all black (from
; clear_scanline_table), so E0 slots get black — image displays normally.
; ============================================================================
update_stream_e0:
    push ax
    push cx
    push si
    push di

    mov si, scanline_colors
    mov di, palette_stream
    mov cx, SCREEN_HEIGHT

.use_loop:
    lodsw                       ; AX = R, GB from scanline_colors
    mov [di], ax                ; Store at E0 slot (offset 0-1 of 16-byte record)
    add di, 16                  ; Next 16-byte record
    loop .use_loop

    pop di
    pop si
    pop cx
    pop ax
    ret

; ============================================================================
; render_frame — Unified per-scanline palette programming (E0-E7)
; ============================================================================
;
; Called once per frame, immediately after wait_vblank returns (line 0).
; Programs the V6355D palette for all 200 visible scanlines.
;
; Hybrid write path (proven working):
;   - OUTSB×4 for E0+E1 (E0 is time-critical, goes out immediately after open)
;   - REP OUTSB×12 for E2-E7 (inactive bank, no timing constraint)
; All 16 bytes written in one session (open 0x40 → 16 bytes → close 0x80).
;
; NOTE: Skip optimizations (same-parity, frame-to-frame, all-zeros) were all
; tested and caused severe blinking. The write/skip paths take different
; amounts of time, causing HSYNC polling desynchronization. The polling loop
; expects consistent per-scanline timing — variable timing causes drift.
;
; Register plan:
;   DX = PORT_REG_DATA (0xDE) — permanent, used by OUTSB
;   SI = palette_stream pointer — advances 16 bytes per line
;   CX = scanline counter (counts down from 200)
;   BL/BH = PAL_ODD/PAL_EVEN (alternating flip)
; ============================================================================
render_frame:
    cli
    cld

    mov si, palette_stream
    mov cx, SCREEN_HEIGHT
    mov dx, PORT_REG_DATA       ; DX = 0xDE permanently
    mov bl, PAL_ODD
    mov bh, PAL_EVEN

.rf_scanline:
.rf_wait_low:
    in al, PORT_STATUS
    test al, 0x01
    jnz .rf_wait_low
.rf_wait_high:
    in al, PORT_STATUS
    test al, 0x01
    jz .rf_wait_high

    ; FLIP FIRST — nanosecond-critical
    mov al, bl
    out PORT_COLOR, al
    xchg bl, bh

    ; Open at E0, hybrid stream (single session)
    mov al, 0x40
    out PORT_REG_ADDR, al

    outsb                       ; E0 R   — time-critical
    outsb                       ; E0 G|B — time-critical
    outsb                       ; E1 R   (dummy)
    outsb                       ; E1 G|B (dummy)

    push cx
    mov cx, 12                  ; E2-E7 = 12 bytes
    rep outsb
    pop cx

    mov al, 0x80
    out PORT_REG_ADDR, al       ; Close

    loop .rf_scanline

    ; ------------------------------------------------------------------
    ; End of frame: reset entry 0 to black, restore palette 0
    ; ------------------------------------------------------------------
    mov al, 0x40
    out PORT_REG_ADDR, al       ; Open at E0
    xor al, al
    out dx, al                  ; E0 R = 0
    out dx, al                  ; E0 G|B = 0
    mov al, 0x80
    out PORT_REG_ADDR, al       ; Close

    mov al, PAL_EVEN
    out PORT_COLOR, al

    sti
    ret


; ============================================================================
; wait_vblank — Synchronize to the start of the visible frame
; ============================================================================
;
; Called between frames. Waits for VBLANK to end so render_frame begins
; at exactly line 0.
;
;   1. Wait for VBLANK START (bit 3 = 1) — confirms we're in blanking
;   2. Wait for VBLANK END (bit 3 = 0) — returns at first visible scanline
;
; PORT_STATUS (0xDA) bit 3: 1 = vertical blanking, 0 = visible area
; ============================================================================
wait_vblank:
    ; Wait for vblank to start
.wv_wait_start:
    in al, PORT_STATUS
    test al, 0x08
    jnz .wv_in_vblank
    jmp .wv_wait_start

.wv_in_vblank:
    ; Wait for vblank to end (visible area about to begin)
.wv_wait_end:
    in al, PORT_STATUS
    test al, 0x08
    jnz .wv_wait_end
    ret

; ============================================================================
; check_keyboard - Returns AL: 0xFF=ESC, 0x20=SPACE, 's'/'S'=sync, 0=no key
; ============================================================================
check_keyboard:
    mov ah, 0x01
    int 0x16
    jz .ck_no_key

    mov ah, 0x00
    int 0x16

    cmp ah, 0x01                ; ESC
    je .ck_esc
    cmp al, 0x20                ; SPACE
    je .ck_done
    cmp al, 's'
    je .ck_done
    cmp al, 'S'
    je .ck_done

.ck_no_key:
    xor al, al
    ret

.ck_esc:
    mov al, 0xFF
    ret

.ck_done:
    ret

; ============================================================================
; set_cga_palette - Restore default CGA text mode palette
; ============================================================================
set_cga_palette:
    push ax
    push cx
    push si

    cli

    mov al, 0x40
    out PORT_REG_ADDR, al
    jmp short $+2

    mov si, cga_colors
    mov cx, 32

.scp_loop:
    lodsb
    out PORT_REG_DATA, al
    jmp short $+2
    loop .scp_loop

    mov al, 0x80
    out PORT_REG_ADDR, al

    sti

    pop si
    pop cx
    pop ax
    ret

; ============================================================================
; DATA - Messages
; ============================================================================

msg_info    db 'PALRAM9B - BMP Image + Full-Screen Raster Bars', 0x0D, 0x0A
            db 0x0D, 0x0A
            db 'Displays 320x200 BMP with flip-first palette', 0x0D, 0x0A
            db '(3 colors/line) + animated raster bars on', 0x0D, 0x0A
            db 'the background. Unified E0+E2-E7 streaming.', 0x0D, 0x0A
            db 0x0D, 0x0A
            db 'Usage: PALRAM9B filename.bmp', 0x0D, 0x0A
            db '  SPACE = toggle raster bars', 0x0D, 0x0A
            db '  S     = toggle vblank sync', 0x0D, 0x0A
            db '  ESC   = exit to DOS', 0x0D, 0x0A
            db 0x0D, 0x0A
            db 'By Retro Erik - 2026', 0x0D, 0x0A, '$'

msg_splash   db 0x1B, '[2J', 0x1B, '[H'
             db 0x0D, 0x0A
             db 0x0D, 0x0A
             db 0x0D, 0x0A
             db 0x0D, 0x0A
             db 0x0D, 0x0A
             db 0x0D, 0x0A
             db 0x0D, 0x0A
             db 0x0D, 0x0A
             db '                   '
             db 0x1B, '[1;36m'
             db 'Olivetti Prodest PC1 - BMP + Raster Bars'
             db 0x1B, '[0m', 0x0D, 0x0A
             db '                   '
             db 0x1B, '[1;33m'
             db 'Unified E0+E2-E7 Full-Screen Raster Bars'
             db 0x1B, '[0m', 0x0D, 0x0A
             db 0x0D, 0x0A
             db '                                '
             db 0x1B, '[1;35m'
             db 'Retro Erik'
             db 0x1B, '[0m'
             db ' 2026', 0x0D, 0x0A
             db 0x0D, 0x0A
             db '                                '
             db 0x1B, '[1;33m'
             db 'Loading Image...'
             db 0x1B, '[0m', '$'

msg_file_err db 'Error: Cannot open file', 0x0D, 0x0A, '$'
msg_not_bmp  db 'Error: Not a valid BMP file', 0x0D, 0x0A, '$'
msg_format   db 'Error: BMP must be 4-bit or 8-bit uncompressed', 0x0D, 0x0A, '$'
msg_size     db 'Error: BMP must be 320x200', 0x0D, 0x0A, '$'

; ============================================================================
; DATA - Standard CGA palette for exit
; ============================================================================

cga_colors:
    db 0x00, 0x00               ; 0:  Black
    db 0x00, 0x05               ; 1:  Blue
    db 0x00, 0x50               ; 2:  Green
    db 0x00, 0x55               ; 3:  Cyan
    db 0x05, 0x00               ; 4:  Red
    db 0x05, 0x05               ; 5:  Magenta
    db 0x05, 0x20               ; 6:  Brown
    db 0x05, 0x55               ; 7:  Light Gray
    db 0x02, 0x22               ; 8:  Dark Gray
    db 0x02, 0x27               ; 9:  Light Blue
    db 0x02, 0x72               ; 10: Light Green
    db 0x02, 0x77               ; 11: Light Cyan
    db 0x07, 0x22               ; 12: Light Red
    db 0x07, 0x27               ; 13: Light Magenta
    db 0x07, 0x70               ; 14: Yellow
    db 0x07, 0x77               ; 15: White

; ============================================================================
; DATA - Raster bar gradients (from palram7b)
; ============================================================================

; Red gradient: R=1→7→1, G=0, B=0
red_gradient:
%assign i 1
%rep 7
    times LINES_PER_COLOR db i, 0x00
%assign i i+1
%endrep
%assign i 7
%rep 7
    times LINES_PER_COLOR db i, 0x00
%assign i i-1
%endrep

; Cyan gradient: R=0, G=1→7→1, B=1→7→1
cyan_gradient:
%assign i 1
%rep 7
    times LINES_PER_COLOR db 0x00, (i << 4) | i
%assign i i+1
%endrep
%assign i 7
%rep 7
    times LINES_PER_COLOR db 0x00, (i << 4) | i
%assign i i-1
%endrep

; Sine table (256 entries, values 3-97)
sine_table:
    db 50, 51, 52, 53, 55, 56, 57, 58, 59, 61, 62, 63, 64, 65, 66, 68
    db 69, 70, 71, 72, 73, 74, 75, 76, 77, 78, 79, 80, 81, 82, 83, 84
    db 84, 85, 86, 87, 87, 88, 89, 89, 90, 90, 91, 91, 92, 92, 93, 93
    db 94, 94, 94, 95, 95, 95, 96, 96, 96, 96, 97, 97, 97, 97, 97, 97
    db 97, 97, 97, 97, 97, 97, 97, 97, 96, 96, 96, 96, 95, 95, 95, 94
    db 94, 94, 93, 93, 92, 92, 91, 91, 90, 90, 89, 89, 88, 87, 87, 86
    db 85, 84, 84, 83, 82, 81, 80, 79, 78, 77, 76, 75, 74, 73, 72, 71
    db 70, 69, 68, 66, 65, 64, 63, 62, 61, 59, 58, 57, 56, 55, 53, 52
    db 50, 49, 48, 47, 45, 44, 43, 42, 41, 39, 38, 37, 36, 35, 34, 32
    db 31, 30, 29, 28, 27, 26, 25, 24, 23, 22, 21, 20, 19, 18, 17, 16
    db 16, 15, 14, 13, 13, 12, 11, 11, 10, 10,  9,  9,  8,  8,  7,  7
    db  6,  6,  6,  5,  5,  5,  4,  4,  4,  4,  3,  3,  3,  3,  3,  3
    db  3,  3,  3,  3,  3,  3,  3,  3,  4,  4,  4,  4,  5,  5,  5,  6
    db  6,  6,  7,  7,  8,  8,  9,  9, 10, 10, 11, 11, 12, 13, 13, 14
    db 15, 16, 16, 17, 18, 19, 20, 21, 22, 23, 24, 25, 26, 27, 28, 29
    db 30, 31, 32, 34, 35, 36, 37, 38, 39, 41, 42, 43, 44, 45, 47, 48

; ============================================================================
; DATA - Variables
; ============================================================================

filename_ptr:   dw 0
file_handle:    dw 0
current_row:    dw 0

; BMP format
bmp_bpp:        db 0
num_colors:     dw 0
bmp_row_bytes:  dw 0

; Background detection
bg_index:       db 0

; Raster bar state
bar1_y:         db 0
bar2_y:         db 0
bar1_sine_idx:  db BAR1_PHASE
bar2_sine_idx:  db BAR2_PHASE
bars_enabled:   db 1
sync_enabled:   db 1

; BMP palette RGB888 (for distance calc)
pal_r:          times 256 db 0
pal_g:          times 256 db 0
pal_b:          times 256 db 0

; V6355D format palette (up to 256 × 2 bytes)
v6355_pal:      times 512 db 0

; Per-scanline analysis
top3_temp:      times 3 db 0
nn_best_dist:   dw 0
nn_best_cga:    db 0

; Palette stream build temps
bps_cur_a:      db 0
bps_cur_b:      db 0
bps_cur_c:      db 0
bps_nxt_a:      db 0
bps_nxt_b:      db 0
bps_nxt_c:      db 0

; Color frequency workspace (256 words)
color_count:    times 512 db 0

; Per-scanline top 3 color indices (200 × 3 = 600 bytes)
scanline_top3:  times 600 db 0

; Pixel remap table (256 bytes)
remap_table:    times 256 db 0

; Color stability analysis
color_line_count: times 512 db 0
global_c:       db 0
global_b:       db 0

; Raster bar per-scanline RGB pairs (200 × 2 = 400 bytes)
scanline_colors: times SCREEN_HEIGHT * 2 db 0

; Unified palette stream (200 × 16 = 3200 bytes): E0+E1+E2-E7 per line
palette_stream: times 3200 db 0

; File I/O buffers
bmp_header:     times 1088 db 0
row_buffer:     times 324 db 0

; Off-screen VRAM buffer (CGA interlaced layout, 16384 bytes)
vram_buffer:    times 16384 db 0

; ============================================================================
; END OF PROGRAM
; ============================================================================
