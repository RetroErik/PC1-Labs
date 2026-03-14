; ============================================================================
; PALRAM9.ASM - BMP Image + Animated Raster Bars (Flip-First + Entry 0)
;              E0 written every scanline — no skip-if-same optimization
; ============================================================================
;
; Combines pc1-bmp4's flip-first 3-color-per-scanline BMP display with
; palram7b's dancing sine-wave raster bars on the background (entry 0).
; Unlike palram7b, E0 must be written on every scanline in the bar zones
; (not just lines where the color changes) to avoid timing-drift blinking
; at zone transitions. See "THE BIG DISCOVERY" section below.
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
; preserving the actual image content.
;
; ============================================================================
; SCREEN LAYOUT — 3-Zone Symmetric Split
; ============================================================================
;
; The 200 visible scanlines are divided into three zones:
;
;   Zone 1 — RASTER BARS (lines 0-39, top 40 lines)
;     Only palette entry 0 (E0) is written. No palette flip.
;     Bar 1 (red gradient) bounces within this zone via sine wave.
;
;   Zone 2 — IMAGE (lines 40-159, middle 120 lines)
;     Palette entries E2-E7 are written using flip-first technique.
;     The BMP image is displayed with 3 unique colors per scanline.
;     No E0 writes — entry 0 stays black (reset at end of frame).
;
;   Zone 3 — RASTER BARS (lines 160-199, bottom 40 lines)
;     Same as Zone 1. Bar 2 (cyan gradient) bounces here.
;
; Each zone writes ONLY E0 or ONLY E2-E7, never both on the same
; scanline. This separation is the key to avoiding flicker:
;   - E0 writes (2 bytes) MUST complete within HBLANK (~72-80 cycles)
;   - E2-E7 writes (12 bytes) safely spill past HBLANK because
;     flip-first targets the inactive palette set
;   - Mixing both on one scanline would overflow the HBLANK window
;
; ============================================================================
; HBLANK BEHAVIOR — What Happens During Horizontal Blanking
; ============================================================================
;
; The CRT beam sweeps left-to-right drawing pixels, then briefly returns
; (horizontal blanking / HBLANK). During HBLANK we can safely change
; palette entries without visible artifacts.
;
; HBLANK detection: poll PORT_STATUS (0xDA) bit 0:
;   - Wait for bit 0 = 0 (visible area / HSYNC low)
;   - Wait for bit 0 = 1 (HBLANK started / HSYNC high)
;   - Immediately write palette data
;
; BAR ZONES (Zones 1 & 3) — E0 write during HBLANK:
;   Before the wait loop, color values are pre-fetched:
;     AH = R byte (loaded from scanline_colors table)
;     [bar_gb] = G|B byte (saved to fixed memory address)
;   After HBLANK detected:
;     out 0xDD, 0x40     ; Open palette at entry 0
;     out 0xDE, AH        ; Write R (from register — instant)
;     out 0xDE, [bar_gb]  ; Write G|B (from pre-fetched memory)
;     out 0xDD, 0x80      ; Close palette
;   Total: ~55 cycles — fits within ~72-80 cycle HBLANK window.
;   Pre-fetching R into AH before the wait loop avoids indexed
;   memory reads during the critical HBLANK window.
;
; IMAGE ZONE (Zone 2) — Flip-first E2-E7 write:
;   After HBLANK detected:
;     out 0xD9, PAL_ODD/PAL_EVEN  ; FLIP palette select FIRST
;     out 0xDD, 0x44               ; Open at entry 2
;     REP OUTSB (12 bytes)         ; Stream E2-E7 data
;     out 0xDD, 0x80               ; Close palette
;   The flip happens within HBLANK. The 12-byte REP OUTSB (~168 cycles)
;   spills into the visible area BUT writes to the INACTIVE palette set
;   (the one not currently being displayed), so no artifacts appear.
;
; ============================================================================
; VBLANK BEHAVIOR — What Happens During Vertical Blanking
; ============================================================================
;
; After line 199, the CRT enters vertical blanking (VBLANK). During this
; time no pixels are drawn. The main loop uses this time to:
;
;   1. Update raster bar positions (sine wave advancement)
;   2. Build the scanline_colors table (pre-compute 200 × 2 byte pairs)
;   3. Wait for VBLANK to END (visible area about to start)
;
; wait_vblank ensures render_frame begins at exactly line 0:
;   - First waits for VBLANK to START (bit 3 = 1) — ensures we're
;     actually in the blanking period
;   - Then waits for VBLANK to END (bit 3 = 0) — returns at the
;     first visible scanline
;
; This ordering is critical. The old approach (wait for end, then start)
; would skip an entire frame of 200 visible lines with no palette
; programming, causing 30 Hz blinking.
;
; End-of-frame cleanup (done at the end of render_frame, after line 199):
;   - Reset E0 to black (0,0) so the image zone background is black
;   - Restore PAL_EVEN as the active palette select
;
; ============================================================================
; WHAT WORKS
; ============================================================================
;
;   - Raster bars display with smooth animation, no shimmer or blinking,
;     but with a tiny artifact on the first few pixels of each bar
;     scanline (see NOTE below)
;   - Pre-fetching R into AH and G|B into [bar_gb] before the HBLANK
;     wait loop eliminates the full-width shimmer that occurred when
;     memory reads happened during the critical HBLANK window
;   - Image displays correctly with 3 colors per scanline via flip-first
;   - Image area is flicker-free — no blinking or artifacts
;   - Bars animate smoothly with sine-wave bounce
;   - Toggle bars on/off with SPACE key
;   - BMP loading with two-pass analysis, nearest-neighbor color mapping
;
;   NOTE: There is a tiny visual imperfection — the first few pixels on
;   the left edge of each raster bar scanline may show a brief color
;   glitch. This is caused by the E0 palette write completing at the
;   very edge of the HBLANK window (~55 cycles of port I/O out of
;   ~72-80 available). The close instruction (0x80 to 0xDD) finishes
;   just as the beam enters the visible area, causing a few pixels to
;   catch the transition. This is an inherent trade-off of writing E0
;   on every scanline and cannot be eliminated without fewer OUT
;   instructions (the V6355D requires all 4) or a wider HBLANK window
;   (fixed by hardware).
;
; ============================================================================
; THE BIG DISCOVERY — E0 Must Be Written On Every Scanline
; ============================================================================
;
;   In palram7b (raster bars without a BMP image), performance was
;   optimized with a "skip-if-same" approach: E0 was only written on
;   scanlines where the bar color actually changed. Since a bar only
;   occupies ~14-28 of the 200 lines, the vast majority of scanlines
;   were skipped, meaning the HBLANK write path ran on very few lines.
;   This worked perfectly in palram7b's single-zone design.
;
;   In palram9, the same skip-if-same approach caused severe blinking.
;   The problem is timing drift at zone transitions: the "write" path
;   and the "skip" path have different execution times. When the code
;   transitions from Zone 1 (bars) to Zone 2 (image), the variable
;   timing from write-vs-skip decisions creates a different offset into
;   the scanline each frame. This frame-to-frame jitter at the zone
;   boundary causes visible blinking.
;
;   The solution — and palram9's defining constraint — is to write E0
;   on EVERY scanline in the bar zones, even when the color hasn't
;   changed. This makes every scanline take the same code path with
;   identical timing, eliminating the jitter at zone transitions.
;
;   The trade-off: writing E0 on every line means 4 OUT instructions
;   (~55 cycles) execute during every HBLANK in the bar zones. Since
;   HBLANK is only ~72-80 cycles, the write barely fits, and the last
;   few cycles spill past the start of the visible area — causing the
;   tiny left-edge artifact described above. This is the price of
;   flicker-free multi-zone raster bars on the V6355D.
;
; ============================================================================
; WHAT WAS TRIED AND DIDN'T WORK (development history)
; ============================================================================
;
;   These approaches were tested during development and caused problems:
;
;   - Skip-if-same optimization (only writing E0 on scanlines where the
;     color changes) caused blinking in palram9's multi-zone layout.
;     See "THE BIG DISCOVERY" above for full explanation.
;
;   - OUTSB burst technique (palram7b's DX=0xDD approach) for bar zones
;     caused blinking — possibly because switching DX between 0xDD
;     (bar zones) and 0xDE (image zone) disrupts V6355D state.
;
;   - Using BP or BX registers for pre-fetch instead of AH + [bar_gb]
;     also caused blinking in the bar zones.
;
;   - Partial E0 writes — writing only the R byte (for the red bar) or
;     only the G|B byte (for the cyan bar) and closing the palette
;     session. The V6355D requires both bytes to be written for each
;     palette entry. Writing only one byte and closing with 0x80 causes
;     the entry to vanish entirely (the bar disappears). This is a
;     hard requirement: open (0x40), write R, write G|B, close (0x80)
;     — all four OUTs are mandatory.
;
;   - Replacing memory reads with immediate zeros (e.g., XOR AL,AL
;     instead of MOV AL,[bar_gb] for the unused color channel) was
;     tested to try to reduce the left-edge artifact. The code worked
;     correctly, but the cycle savings (~4 cycles per scanline) were
;     too small to visibly reduce the artifact. The bottleneck is the
;     4 OUT instructions themselves, not the data loads between them.
;
;   KEY FIX: Pre-fetching the bar color bytes (R into AH, G|B into
;   [bar_gb]) BEFORE the HBLANK wait loop — so the critical burst uses
;   a register copy + 1 fixed-address memory read instead of 2 indexed
;   reads off DI — fixed the blinking. The exact mechanism is unknown:
;   the V6355D tech ref says system RAM has no bus contention, so the
;   cycle savings from register vs indexed addressing shouldn't matter,
;   yet empirically this change is what made palram9 flicker-free.
;
; ============================================================================
; TECHNIQUES USED
; ============================================================================
;
;   From pc1-bmp4: flip-first palette, 3 colors/line, REP OUTSB streaming,
;     two-pass BMP analysis, stability reordering, DX=0xDE permanently
;   From palram7b: sine-wave bounce, dual bars (red + cyan)
;   Combined: 3-zone render — bars frame the image symmetrically
;   New: register pre-fetch (AH + [bar_gb]) to avoid memory reads in HBLANK
;
; Controls:
;   SPACE : Toggle raster bar animation on/off
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
;   nasm -f bin -o palram9.com palram9.asm
;
; ============================================================================
; USAGE
; ============================================================================
;
;   palram9 filename.bmp
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
; Raster Bar Configuration (from palram7b)
; ============================================================================

LINES_PER_COLOR equ 1           ; Scanlines per gradient color
BAR_HEIGHT      equ 14 * LINES_PER_COLOR  ; Total bar height (14 lines)

; Per-bar speed (higher = faster wobble)
BAR1_SPEED      equ 4
BAR2_SPEED      equ 3

; Per-bar starting phase (0-255)
BAR1_PHASE      equ 0
BAR2_PHASE      equ 85          ; 1/3 cycle offset (120 degrees)

; Screen zone boundaries (Option B: symmetric split)
IMAGE_TOP       equ 40          ; First image scanline
IMAGE_BOTTOM    equ 160         ; First bottom-bar scanline
BAR_TOP_LINES   equ 40          ; Lines in top bar zone
IMAGE_LINES     equ 120         ; Lines in image zone (IMAGE_BOTTOM - IMAGE_TOP)
BAR_BOT_LINES   equ 40          ; Lines in bottom bar zone

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

    ; --- Build per-scanline palette stream (E2-E7, 12 bytes/line) ---
    call build_palette_stream

    ; --- Set CGA mode 4 ---
    mov ax, 0x0004
    int 0x10
    cld

    ; --- Blank video during VRAM write ---
    mov al, CGA_MODE4_OFF
    out PORT_MODE, al

    ; --- Seek back to pixel data for Pass 2 ---
    mov bx, [file_handle]
    mov dx, [bmp_header + BMP_DATA_OFFSET]
    mov cx, [bmp_header + BMP_DATA_OFFSET + 2]
    mov ax, 0x4200
    int 0x21

    ; --- PASS 2: Remap pixels and write to CGA VRAM ---
    call render_to_vram

    ; --- Close file ---
    mov bx, [file_handle]
    mov ah, 0x3E
    int 0x21

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

    ; Update bar 1 (top zone: lines 0-39)
    add byte [bar1_sine_idx], BAR1_SPEED
    mov al, [bar1_sine_idx]
    xor ah, ah
    mov si, ax
    mov al, [sine_table + si]
    shr al, 2                   ; 0-97 → 0-24 (fits in 40-line zone)
    mov [bar1_y], al

    ; Update bar 2 (bottom zone: lines 160-199)
    add byte [bar2_sine_idx], BAR2_SPEED
    mov al, [bar2_sine_idx]
    xor ah, ah
    mov si, ax
    mov al, [sine_table + si]
    shr al, 2                   ; 0-97 → 0-24
    add al, IMAGE_BOTTOM        ; 160 + 0-24 = 160-184
    mov [bar2_y], al

    call build_scanline_table
    jmp .do_render

.skip_bar_update:
    ; Bars disabled — fill scanline_colors with black
    call clear_scanline_table

.do_render:
    call wait_vblank
    call render_frame

    ; --- Check keyboard ---
    call check_keyboard
    cmp al, 0xFF
    je .exit_program
    cmp al, 0x20                ; SPACE = toggle bars
    jne .display_loop
    xor byte [bars_enabled], 1
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
; build_palette_stream - Flip-first interleaved V6355D data (E2-E7)
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
    mov [di], ax

    xor bx, bx
    mov bl, [bps_nxt_a]
    shl bx, 1
    mov ax, [v6355_pal + bx]
    mov [di + 2], ax

    xor bx, bx
    mov bl, [bps_cur_b]
    shl bx, 1
    mov ax, [v6355_pal + bx]
    mov [di + 4], ax

    xor bx, bx
    mov bl, [bps_nxt_b]
    shl bx, 1
    mov ax, [v6355_pal + bx]
    mov [di + 6], ax

    xor bx, bx
    mov bl, [bps_cur_c]
    shl bx, 1
    mov ax, [v6355_pal + bx]
    mov [di + 8], ax

    xor bx, bx
    mov bl, [bps_nxt_c]
    shl bx, 1
    mov ax, [v6355_pal + bx]
    mov [di + 10], ax

    jmp .bps_next

.bps_odd:
    ; ODD line: pal 0 active (E2,E4,E6 active)
    ; E2=near A, E3=far A, E4=near B, E5=far B, E6=near C, E7=far C
    xor bx, bx
    mov bl, [bps_nxt_a]
    shl bx, 1
    mov ax, [v6355_pal + bx]
    mov [di], ax

    xor bx, bx
    mov bl, [bps_cur_a]
    shl bx, 1
    mov ax, [v6355_pal + bx]
    mov [di + 2], ax

    xor bx, bx
    mov bl, [bps_nxt_b]
    shl bx, 1
    mov ax, [v6355_pal + bx]
    mov [di + 4], ax

    xor bx, bx
    mov bl, [bps_cur_b]
    shl bx, 1
    mov ax, [v6355_pal + bx]
    mov [di + 6], ax

    xor bx, bx
    mov bl, [bps_nxt_c]
    shl bx, 1
    mov ax, [v6355_pal + bx]
    mov [di + 8], ax

    xor bx, bx
    mov bl, [bps_cur_c]
    shl bx, 1
    mov ax, [v6355_pal + bx]
    mov [di + 10], ax

.bps_next:
    add di, 12
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
; render_to_vram - Pass 2: Read BMP, remap pixels, write to CGA VRAM
; ============================================================================
render_to_vram:
    push ax
    push bx
    push cx
    push dx
    push si
    push di
    push es

    mov ax, VIDEO_SEG
    mov es, ax

    mov word [current_row], 199

.rv_loop:
    call read_bmp_row
    jc .rv_done
    cmp ax, [bmp_row_bytes]
    jb .rv_done

    call build_remap_table

    ; CGA VRAM offset (interlaced layout)
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
    stosb
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
    stosb
    loop .rv_convert_8

.rv_convert_done:
    mov ax, [current_row]
    or ax, ax
    jz .rv_done
    dec word [current_row]
    jmp .rv_loop

.rv_done:
    pop es
    pop di
    pop si
    pop dx
    pop cx
    pop bx
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

    ; Draw both bars (separate zones, no overlap possible)
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
; ============================================================================
; render_frame — Per-scanline palette programming across 3 zones
; ============================================================================
;
; Called once per frame, immediately after wait_vblank returns (line 0).
; Programs the V6355D palette for all 200 visible scanlines:
;
; ZONE 1 — Top raster bars (lines 0 to 39):
;   Writes entry 0 (E0) only. Two bytes: R and G|B.
;   Color is pre-fetched into AH (R) and [bar_gb] (G|B) BEFORE the
;   HBLANK wait loop, so the critical burst uses a register read (AH)
;   and a single fixed-address memory read ([bar_gb]) — no indexed
;   memory access during the tight HBLANK window.
;   No palette flip occurs. E0 is shared by both palette selects.
;
; ZONE 2 — Image (lines 40 to 159):
;   Writes entries E2-E7 using flip-first technique. 12 bytes per line.
;   First flips the palette select (PAL_ODD ↔ PAL_EVEN), then streams
;   E2-E7 via REP OUTSB. The flip targets HBLANK; the 12-byte stream
;   spills into visible area but writes to the inactive palette set.
;   DI advances past the unused scanline_colors slot for each line.
;
; ZONE 3 — Bottom raster bars (lines 160 to 199):
;   Identical technique to Zone 1. Bar 2 (cyan) bounces here.
;
; End of frame:
;   Reset E0 to black and restore PAL_EVEN. This ensures the image
;   zone (which doesn't write E0) has a black background, and the
;   palette select starts clean for the next frame.
;
; Register plan:
;   DX = PORT_REG_DATA (0xDE) — permanent across all zones
;   SI = palette_stream pointer (image zone, advanced by REP OUTSB)
;   DI = scanline_colors pointer (all zones, advanced 2 bytes/line)
;   CX = scanline counter (counts down from 200)
;   BL/BH = PAL_ODD/PAL_EVEN (image zone flip-first only)
;   AH = pre-fetched R byte (bar zones, survives wait loop)
; ============================================================================
render_frame:
    cli
    cld

    mov si, palette_stream + IMAGE_TOP * 12
    mov di, scanline_colors
    mov cx, SCREEN_HEIGHT
    mov dx, PORT_REG_DATA       ; DX = 0xDE permanently
    mov bl, PAL_ODD
    mov bh, PAL_EVEN

    ; ==================================================================
    ; ZONE 1: Top raster bars (lines 0 to IMAGE_TOP-1)
    ; Pre-fetch into registers, then write from registers during HBLANK.
    ; ==================================================================
.rf_bar_top:
    ; Pre-fetch color into registers (during visible area — free time)
    mov ah, [di]                ; AH = R (survives wait loop)
    mov al, [di + 1]
    mov [bar_gb], al            ; Save G|B in memory (before wait)
    add di, 2

    ; Wait for HBLANK
.rf_bt_wait_low:
    in al, PORT_STATUS
    test al, 0x01
    jnz .rf_bt_wait_low
.rf_bt_wait_high:
    in al, PORT_STATUS
    test al, 0x01
    jz .rf_bt_wait_high

    ; --- Critical HBLANK: pre-fetched burst, 1 memory read ---
    mov al, 0x40
    out PORT_REG_ADDR, al       ; open E0
    mov al, ah                  ; R from AH (preserved)
    out dx, al                  ; R → 0xDE
    mov al, [bar_gb]            ; G|B from saved byte
    out dx, al                  ; G|B → 0xDE
    mov al, 0x80
    out PORT_REG_ADDR, al       ; close

    dec cx
    cmp cx, SCREEN_HEIGHT - IMAGE_TOP
    ja .rf_bar_top

    ; ==================================================================
    ; ZONE 2: Image (lines IMAGE_TOP to IMAGE_BOTTOM-1)
    ; DX already 0xDE. SI already loaded.
    ; ==================================================================
.rf_image:
.rf_img_wait_low:
    in al, PORT_STATUS
    test al, 0x01
    jnz .rf_img_wait_low
.rf_img_wait_high:
    in al, PORT_STATUS
    test al, 0x01
    jz .rf_img_wait_high

    ; FLIP FIRST
    mov al, bl
    out PORT_COLOR, al
    xchg bl, bh

    ; Write E2-E7 (12 bytes, unrolled — avoids push/pop cx overhead)
    mov al, 0x44
    out PORT_REG_ADDR, al       ; Open at entry 2

    outsb                       ; E2 R
    outsb                       ; E2 G|B
    outsb                       ; E3 R
    outsb                       ; E3 G|B
    outsb                       ; E4 R
    outsb                       ; E4 G|B
    outsb                       ; E5 R
    outsb                       ; E5 G|B
    outsb                       ; E6 R
    outsb                       ; E6 G|B
    outsb                       ; E7 R
    outsb                       ; E7 G|B

    mov al, 0x80
    out PORT_REG_ADDR, al       ; Close

    add di, 2                   ; Advance DI past unused bar data
    dec cx
    cmp cx, SCREEN_HEIGHT - IMAGE_BOTTOM
    ja .rf_image

    ; ==================================================================
    ; ZONE 3: Bottom raster bars (lines IMAGE_BOTTOM to 199)
    ; ==================================================================
.rf_bar_bot:
    mov ah, [di]
    mov al, [di + 1]
    mov [bar_gb], al
    add di, 2

.rf_bb_wait_low:
    in al, PORT_STATUS
    test al, 0x01
    jnz .rf_bb_wait_low
.rf_bb_wait_high:
    in al, PORT_STATUS
    test al, 0x01
    jz .rf_bb_wait_high

    mov al, 0x40
    out PORT_REG_ADDR, al       ; open E0
    mov al, ah
    out dx, al                  ; R
    mov al, [bar_gb]
    out dx, al                  ; G|B
    mov al, 0x80
    out PORT_REG_ADDR, al       ; close

    loop .rf_bar_bot

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
; Called between frames, after the between-frame work (update bar
; positions, build scanline table) is complete.
;
; The render loop must start at exactly line 0. This function ensures
; that by waiting for VBLANK to end:
;
;   1. Wait for VBLANK START (bit 3 = 1) — confirms we're in the
;      blanking period, not still in the visible area
;   2. Wait for VBLANK END (bit 3 = 0) — returns at the first
;      visible scanline, so render_frame begins at line 0
;
; This ordering is critical. An earlier implementation waited for
; VBLANK end first, then start — this caused the code to skip an
; entire frame (200 visible lines with no palette programming),
; resulting in 30 Hz blinking.
;
; PORT_STATUS (0xDA) bit 3: 1 = in vertical blanking, 0 = visible area
;
; ============================================================================
wait_vblank:
    ; If we're already past vblank, wait for it to start first
.wv_wait_start:
    in al, PORT_STATUS
    test al, 0x08
    jnz .wv_in_vblank
    jmp .wv_wait_start

.wv_in_vblank:
    ; Now wait for vblank to END (visible area about to begin)
.wv_wait_end:
    in al, PORT_STATUS
    test al, 0x08
    jnz .wv_wait_end
    ret

; ============================================================================
; check_keyboard - Returns AL: 0xFF=ESC, 0x20=SPACE, 0=no key
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
    je .ck_space

.ck_no_key:
    xor al, al
    ret

.ck_esc:
    mov al, 0xFF
    ret

.ck_space:
    mov al, 0x20
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

msg_info    db 'PALRAM9 - BMP Image + Animated Raster Bars', 0x0D, 0x0A
            db 0x0D, 0x0A
            db 'Displays 320x200 BMP with flip-first palette', 0x0D, 0x0A
            db '(3 colors/line) + animated raster bars on', 0x0D, 0x0A
            db 'the background. V6355D 512-color space.', 0x0D, 0x0A
            db 0x0D, 0x0A
            db 'Usage: PALRAM9 filename.bmp', 0x0D, 0x0A
            db '  SPACE = toggle raster bars', 0x0D, 0x0A
            db '  ESC   = exit to DOS', 0x0D, 0x0A
            db 0x0D, 0x0A
            db 'By RetroErik - 2026', 0x0D, 0x0A, '$'

msg_splash   db 0x1B, '[2J', 0x1B, '[H'
             db 0x0D, 0x0A
             db 0x0D, 0x0A
             db 0x0D, 0x0A
             db 0x0D, 0x0A
             db 0x0D, 0x0A
             db 0x0D, 0x0A
             db 0x0D, 0x0A
             db 0x0D, 0x0A
             db '                 '
             db 0x1B, '[1;36m'
             db 'Olivetti Prodest PC1 - BMP + Raster Bars'
             db 0x1B, '[0m', 0x0D, 0x0A
             db '                 '
             db 0x1B, '[1;33m'
             db 'Flip-First Image + Dancing Palette Bars'
             db 0x1B, '[0m', 0x0D, 0x0A
             db 0x0D, 0x0A
             db '                              '
             db 0x1B, '[1;35m'
             db 'RetroErik'
             db 0x1B, '[0m'
             db ' 2026', 0x0D, 0x0A
             db 0x0D, 0x0A
             db '                            '
             db 0x1B, '[1;33m'
             db 'Loading Image...'
             db 0x1B, '[0m', 0x0D, 0x0A, '$'

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

; Sine table (256 entries, values 0-100)
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

; Unused — leftover from OUTSB bar burst experiment (didn't work)
pal_cmd:        db 0x40, 0, 0

; Unused — leftover from earlier render loop variant
saved_img_si:   dw 0

; Pre-fetched G|B byte for bar zone register burst
bar_gb:         db 0

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

; Image palette stream (200 × 12 = 2400 bytes): E2-E7 per line
palette_stream: times 2400 db 0

; File I/O buffers
bmp_header:     times 1088 db 0
row_buffer:     times 324 db 0

; ============================================================================
; END OF PROGRAM
; ============================================================================
