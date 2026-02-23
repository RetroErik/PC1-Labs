; ============================================================================
; PYRAMID.asm - Flat-Shaded Rotating Pyramid
; Olivetti Prodest PC1 - Yamaha V6355D - NEC V40 @ 8 MHz
;
; 3D flat-shaded pyramid rotating in real-time on the PC1's hidden
; 160x200x16 graphics mode. Uses the V6355D's 512-color palette
; to display 4 distinctly colored faces with backface culling and
; painter's algorithm for correct visibility.
;
; Features:
;   - 5-vertex pyramid with 4 triangular faces
;   - Y-axis rotation + fixed X-axis tilt (3/4 view)
;   - Backface culling via 2D cross product
;   - Painter's algorithm (back-to-front face sorting)
;   - Fast scanline triangle fill for 4bpp packed pixel mode
;   - 8.8 fixed-point math using NEC V40 IMUL/IDIV
;   - 256-entry sine/cosine lookup table
;   - VBlank synchronization
;
; Controls: ESC - Exit to DOS
;
; Build: nasm PYRAMID.asm -f bin -o PYRAMID.com
;
; By Retro Erik - 2026
; ============================================================================

[BITS 16]
[ORG 0x100]
[CPU 186]

; ============================================================================
; Constants
; ============================================================================

VIDEO_SEG       equ 0xB000      ; Hidden mode VRAM segment
PORT_REG_ADDR   equ 0x3DD       ; V6355D register address port
PORT_REG_DATA   equ 0x3DE       ; V6355D register data port
PORT_MODE       equ 0x3D8       ; Mode control register
PORT_COLOR      equ 0x3D9       ; Border color register
PORT_STATUS     equ 0x3DA       ; Status register (bit 3 = VBlank)

SCREEN_W        equ 160         ; Screen width in pixels
SCREEN_H        equ 200         ; Screen height in pixels
BYTES_PER_ROW   equ 80          ; Bytes per scanline (160 / 2)
CENTER_X        equ 80          ; Screen center X
CENTER_Y        equ 100         ; Screen center Y

NUM_VERTICES    equ 5           ; Pyramid: 1 apex + 4 base
NUM_FACES       equ 4           ; 4 triangular side faces
FACE_STRIDE     equ 4           ; Bytes per face entry (3 indices + 1 color)

FOCAL_LEN       equ 256         ; Perspective focal length
Z_OFFSET        equ 300         ; Z depth offset (keeps everything in front)

ANGLE_X_TILT    equ 22          ; Fixed X tilt (~31 degrees for 3/4 view)
ANGLE_Y_SPEED   equ 2           ; Y rotation speed (per frame)

; ============================================================================
; Entry Point
; ============================================================================
start:
    ; --- Set BIOS mode 4 for proper CRTC timing ---
    mov     ax, 0x0004
    int     0x10

    ; Restore segment registers after BIOS call
    push    cs
    pop     ds
    push    cs
    pop     es
    cld

    ; --- Configure V6355D chip ---
    mov     dx, PORT_REG_ADDR
    mov     al, 0x67            ; Register 0x67: bus/timing config
    out     dx, al
    jmp     short $+2
    mov     dx, PORT_REG_DATA
    mov     al, 0x18            ; 8-bit bus, CRT timing
    out     dx, al
    jmp     short $+2

    mov     dx, PORT_REG_ADDR
    mov     al, 0x65            ; Register 0x65: monitor config
    out     dx, al
    jmp     short $+2
    mov     dx, PORT_REG_DATA
    mov     al, 0x09            ; 200 lines, PAL/50Hz
    out     dx, al
    jmp     short $+2

    ; --- Unlock hidden 16-color mode ---
    mov     dx, PORT_MODE
    mov     al, 0x4A            ; Bit 6 = mode unlock
    out     dx, al
    jmp     short $+2

    ; --- Set palette ---
    call    set_palette

    ; --- Set border to black ---
    mov     dx, PORT_COLOR
    xor     al, al
    out     dx, al

    ; --- Clear VRAM ---
    call    clear_screen

    ; --- Initialize angle ---
    mov     word [angle_y], 0

; ============================================================================
; Main Loop
; ============================================================================
main_loop:
    ; --- 1. Transform vertices (CPU-only, no VRAM access) ---
    call    transform_vertices

    ; --- 2. Process faces: backface cull + depth sort (CPU-only) ---
    call    process_faces

    ; --- 3. Wait for VBlank (so clear+draw starts hidden) ---
    mov     dx, PORT_STATUS
.vb_end:
    in      al, dx
    test    al, 0x08
    jnz     .vb_end             ; Wait for VBlank to end
.vb_start:
    in      al, dx
    test    al, 0x08
    jz      .vb_start           ; Wait for VBlank to start

    ; --- 4. Clear screen (starts during VBlank) ---
    call    clear_screen

    ; --- 5. Draw visible faces (painter's algorithm: back to front) ---
    call    draw_faces

    ; --- 6. Advance rotation ---
    add     word [angle_y], ANGLE_Y_SPEED
    and     word [angle_y], 0xFF    ; Keep in 0-255 range

    ; --- 7. Check ESC key ---
    in      al, 0x60
    cmp     al, 1
    je      .exit

    jmp     main_loop

.exit:
    ; Restore text mode and exit
    mov     ax, 0x0003
    int     0x10
    mov     ax, 0x4C00
    int     0x21

; ============================================================================
; set_palette - Load 16-color palette into V6355D
; ============================================================================
set_palette:
    cli
    mov     dx, PORT_REG_ADDR
    mov     al, 0x40            ; Open palette at entry 0
    out     dx, al
    jmp     short $+2
    jmp     short $+2

    mov     dx, PORT_REG_DATA
    mov     si, palette_data
    mov     cx, 32              ; 16 colors x 2 bytes
.pal_loop:
    lodsb
    out     dx, al
    jmp     short $+2
    loop    .pal_loop

    mov     dx, PORT_REG_ADDR
    mov     al, 0x80            ; Close palette write
    out     dx, al
    sti
    ret

; ============================================================================
; clear_screen - VRAM clear in scanline order (both banks interleaved)
;
; Clears rows in display order (0, 1, 2, 3...) so that both CGA banks
; progress top-to-bottom together, matching the CRT beam direction.
; This prevents the stripe artifact caused by clearing one full bank
; before the other (which leaves odd rows showing the previous frame
; while even rows are already black as the beam scans over them).
; ============================================================================
clear_screen:
    push    es
    push    si
    mov     ax, VIDEO_SEG
    mov     es, ax
    mov     si, yTable          ; Row offset lookup table
    xor     ax, ax              ; Clear value = 0
    mov     dx, SCREEN_H        ; 200 rows
.clear_row:
    mov     di, [si]            ; DI = VRAM offset for this row
    mov     cx, 40              ; 40 words = 80 bytes = 1 row
    rep     stosw
    add     si, 2               ; Next yTable entry
    dec     dx
    jnz     .clear_row
    pop     si
    pop     es
    ret

; ============================================================================
; transform_vertices - Rotate all vertices and project to 2D
;
; Rotation order: Y-axis (turntable) then X-axis (tilt)
;
; Y rotation:  rx = x*cos(a) - z*sin(a)
;              rz = x*sin(a) + z*cos(a)
;              ry = y
;
; X tilt:      ry2 = ry*cos(b) - rz*sin(b)
;              rz2 = ry*sin(b) + rz*cos(b)
;              rx2 = rx
;
; Projection:  sx = CENTER_X + rx2 * FOCAL / (rz2 + Z_OFFSET)
;              sy = CENTER_Y + ry2 * FOCAL / (rz2 + Z_OFFSET)
; ============================================================================
transform_vertices:
    pusha

    ; Look up sin/cos for Y rotation angle
    mov     bx, [angle_y]
    shl     bx, 1               ; Word index
    mov     ax, [sin_table + bx]
    mov     [sin_y], ax
    mov     bx, [angle_y]
    add     bx, 64              ; cos = sin(angle + 64)
    and     bx, 0xFF
    shl     bx, 1
    mov     ax, [sin_table + bx]
    mov     [cos_y], ax

    ; Look up sin/cos for fixed X tilt
    mov     bx, ANGLE_X_TILT
    shl     bx, 1
    mov     ax, [sin_table + bx]
    mov     [sin_x], ax
    mov     bx, ANGLE_X_TILT + 64
    and     bx, 0xFF
    shl     bx, 1
    mov     ax, [sin_table + bx]
    mov     [cos_x], ax

    ; Process each vertex
    mov     si, vertices        ; Source: 3D vertices
    mov     di, proj_x          ; Dest: projected screen coords
    mov     cx, NUM_VERTICES

.vert_loop:
    push    cx

    ; Load vertex (x, y, z) - signed 16-bit integers
    mov     ax, [si]            ; x
    mov     [v_x], ax
    mov     ax, [si+2]          ; y
    mov     [v_y], ax
    mov     ax, [si+4]          ; z
    mov     [v_z], ax

    ; --- Y-axis rotation ---
    ; rx = x*cos_y - z*sin_y  (result >> 8 for 8.8 fixed point)
    mov     ax, [v_x]
    imul    word [cos_y]        ; DX:AX = x * cos_y
    mov     al, ah
    mov     ah, dl              ; AX = (x * cos_y) >> 8
    mov     bp, ax              ; BP = x*cos_y >> 8

    mov     ax, [v_z]
    imul    word [sin_y]        ; DX:AX = z * sin_y
    mov     al, ah
    mov     ah, dl              ; AX = (z * sin_y) >> 8
    sub     bp, ax              ; BP = rx = x*cos - z*sin
    mov     [rot_x], bp

    ; rz = x*sin_y + z*cos_y
    mov     ax, [v_x]
    imul    word [sin_y]
    mov     al, ah
    mov     ah, dl
    mov     bp, ax              ; BP = x*sin >> 8

    mov     ax, [v_z]
    imul    word [cos_y]
    mov     al, ah
    mov     ah, dl
    add     bp, ax              ; BP = rz = x*sin + z*cos
    mov     [rot_z], bp

    mov     ax, [v_y]
    mov     [rot_y], ax         ; ry = y (unchanged by Y rotation)

    ; --- X-axis tilt ---
    ; ry2 = ry*cos_x - rz*sin_x
    mov     ax, [rot_y]
    imul    word [cos_x]
    mov     al, ah
    mov     ah, dl
    mov     bp, ax              ; BP = ry*cos_x >> 8

    mov     ax, [rot_z]
    imul    word [sin_x]
    mov     al, ah
    mov     ah, dl
    sub     bp, ax              ; BP = ry2
    mov     [rot_y2], bp

    ; rz2 = ry*sin_x + rz*cos_x
    mov     ax, [rot_y]
    imul    word [sin_x]
    mov     al, ah
    mov     ah, dl
    mov     bp, ax

    mov     ax, [rot_z]
    imul    word [cos_x]
    mov     al, ah
    mov     ah, dl
    add     bp, ax              ; BP = rz2
    mov     [rot_z2], bp

    ; rx2 = rot_x (unchanged by X tilt)
    mov     ax, [rot_x]
    mov     [rot_x2], ax

    ; --- Perspective projection ---
    ; Denominator: rz2 + Z_OFFSET (must be > 0)
    mov     cx, [rot_z2]
    add     cx, Z_OFFSET        ; CX = z + depth

    ; Safety: clamp minimum denominator to 50
    cmp     cx, 50
    jge     .denom_ok
    mov     cx, 50
.denom_ok:

    ; screen_x = CENTER_X + rot_x2 * FOCAL / (rz2 + Z_OFFSET)
    mov     ax, [rot_x2]
    imul    word [focal]        ; DX:AX = rot_x2 * FOCAL
    idiv    cx                  ; AX = rot_x2 * FOCAL / denom
    add     ax, CENTER_X
    mov     [di], ax            ; Store projected X

    ; screen_y = CENTER_Y + rot_y2 * FOCAL / (rz2 + Z_OFFSET)
    mov     ax, [rot_y2]
    imul    word [focal]
    idiv    cx
    add     ax, CENTER_Y
    mov     [di+2], ax          ; Store projected Y

    add     si, 6               ; Next source vertex (3 words)
    add     di, 4               ; Next dest (2 words: sx, sy)

    pop     cx
    dec     cx
    jnz     .vert_loop

    ; Note: transformed Z values are computed separately by compute_vertex_z
    ; (called from process_faces) for depth sorting.

    popa
    ret

; ============================================================================
; process_faces - Backface cull and depth-sort visible faces
;
; For each face:
;   1. Compute 2D cross product for backface test
;   2. If front-facing, add to visible list with average Z
;   3. Sort visible list by Z (furthest first = painter's algorithm)
; ============================================================================
process_faces:
    pusha

    ; We need the transformed Z for each vertex for depth sorting.
    ; Re-transform just to get Z values (fast, only 5 vertices)
    call    compute_vertex_z

    mov     si, faces           ; Face definitions
    mov     di, visible_faces   ; Output: sorted visible face list
    xor     cx, cx              ; CX = count of visible faces
    mov     byte [num_visible], 0

.face_loop:
    cmp     cx, NUM_FACES
    jge     .faces_done

    ; Get vertex indices for this face
    push    cx
    mov     bx, cx
    shl     bx, 2               ; BX = face_index * 4 (FACE_STRIDE)
    xor     ah, ah

    ; Load vertex index 0
    mov     al, [faces + bx]
    shl     ax, 2               ; AX = vertex_index * 4 (word pairs in proj arrays)
    mov     bp, ax
    mov     ax, [proj_x + bp]   ; AX = sx0
    mov     [sx0], ax
    mov     ax, [proj_x + bp + 2] ; AX = sy0
    mov     [sy0], ax

    ; Load vertex index 1
    xor     ah, ah
    mov     al, [faces + bx + 1]
    shl     ax, 2
    mov     bp, ax
    mov     ax, [proj_x + bp]
    mov     [sx1], ax
    mov     ax, [proj_x + bp + 2]
    mov     [sy1], ax

    ; Load vertex index 2
    xor     ah, ah
    mov     al, [faces + bx + 2]
    shl     ax, 2
    mov     bp, ax
    mov     ax, [proj_x + bp]
    mov     [sx2], ax
    mov     ax, [proj_x + bp + 2]
    mov     [sy2], ax

    ; --- Backface culling: 2D cross product ---
    ; cross = (sx1-sx0)*(sy2-sy0) - (sy1-sy0)*(sx2-sx0)
    ; If cross < 0 → front-facing (draw)  [for our CCW winding + Y-down screen]
    mov     ax, [sx1]
    sub     ax, [sx0]           ; AX = dx1 = sx1-sx0
    mov     dx, [sy2]
    sub     dx, [sy0]           ; DX = dy2 = sy2-sy0
    imul    dx                  ; DX:AX = dx1 * dy2
    mov     [temp32], ax
    mov     [temp32+2], dx      ; Save first term

    mov     ax, [sy1]
    sub     ax, [sy0]           ; AX = dy1 = sy1-sy0
    mov     dx, [sx2]
    sub     dx, [sx0]           ; DX = dx2 = sx2-sx0
    imul    dx                  ; DX:AX = dy1 * dx2

    ; cross = first_term - second_term
    ; Check sign: if first_term < second_term → cross < 0 → visible
    sub     ax, [temp32]
    sbb     dx, [temp32+2]
    ; Now DX:AX = -(cross)... wait, let me redo this
    ; temp32 = dx1*dy2
    ; DX:AX = dy1*dx2
    ; cross = dx1*dy2 - dy1*dx2 = temp32 - DX:AX
    ; So we want: temp32 - (DX:AX)
    mov     cx, ax              ; Save DX:AX
    mov     ax, [temp32]
    sub     ax, cx
    mov     cx, dx
    mov     dx, [temp32+2]
    sbb     dx, cx
    ; Now DX:AX = cross product
    ; If DX < 0 (cross < 0) → face is front-facing → draw
    test    dx, dx
    jns     .cull_face          ; DX >= 0 → back-facing, skip

    ; Edge case: if DX == 0, check AX
    ; (already handled: jns catches DX=0 with SF=0)
    ; Actually if DX=0 and AX is negative (bit 15 set), cross could still be <0
    ; but as 32-bit: DX=0 means cross >= 0. So jns is correct.

    ; --- Face is visible: add to visible list ---
    pop     cx                  ; Restore face counter
    push    cx

    ; Store: face_index, average_z, color
    mov     bp, cx              ; BP = face_index
    shl     bp, 2               ; BP = face_index * 4

    ; Compute average Z of this face's vertices
    xor     ah, ah
    mov     al, [faces + bp]    ; Vertex 0 index
    shl     ax, 1
    mov     bx, ax
    mov     ax, [trans_z + bx]  ; Z of vertex 0

    push    ax
    xor     ah, ah
    mov     al, [faces + bp + 1] ; Vertex 1 index
    shl     ax, 1
    mov     bx, ax
    mov     ax, [trans_z + bx]

    pop     dx
    add     dx, ax              ; DX = Z0 + Z1

    xor     ah, ah
    mov     al, [faces + bp + 2] ; Vertex 2 index
    shl     ax, 1
    mov     bx, ax
    mov     ax, [trans_z + bx]
    add     dx, ax              ; DX = Z0 + Z1 + Z2
    ; Average = sum/3, but for sorting we can use the sum directly

    ; Get face color
    mov     al, [faces + bp + 3]

    ; Store in visible_faces list
    mov     bx, [num_visible]
    xor     bh, bh
    shl     bx, 2               ; Each visible entry = 4 bytes (face_idx, color, avg_z_word)
    mov     ah, cl              ; Face index
    mov     [visible_faces + bx], ah     ; face_index
    mov     [visible_faces + bx + 1], al ; color
    mov     [visible_faces + bx + 2], dx ; average Z (sum, for sorting)

    inc     byte [num_visible]
    jmp     .next_face

.cull_face:

.next_face:
    pop     cx
    inc     cx
    jmp     .face_loop

.faces_done:
    ; --- Sort visible faces by Z (bubble sort, max 4 faces) ---
    ; Sort descending by average Z (furthest first = painter's)
    call    sort_visible

    popa
    ret

; ============================================================================
; compute_vertex_z - Re-compute transformed Z for all vertices
; (Stores in trans_z array for depth sorting)
; ============================================================================
compute_vertex_z:
    pusha

    mov     si, vertices
    mov     di, trans_z
    mov     cx, NUM_VERTICES

.vz_loop:
    push    cx

    ; Y rotation: rz = x*sin_y + z*cos_y
    mov     ax, [si]            ; x
    imul    word [sin_y]
    mov     al, ah
    mov     ah, dl
    mov     bp, ax              ; BP = x*sin_y >> 8

    mov     ax, [si+4]          ; z
    imul    word [cos_y]
    mov     al, ah
    mov     ah, dl
    add     bp, ax              ; BP = rz

    ; X tilt: rz2 = ry*sin_x + rz*cos_x
    mov     ax, [si+2]          ; y (= ry before X tilt)
    imul    word [sin_x]
    mov     al, ah
    mov     ah, dl
    mov     cx, ax              ; CX = ry*sin_x >> 8

    mov     ax, bp              ; rz
    imul    word [cos_x]
    mov     al, ah
    mov     ah, dl
    add     ax, cx              ; AX = rz2

    mov     [di], ax            ; Store transformed Z
    add     si, 6
    add     di, 2

    pop     cx
    dec     cx
    jnz     .vz_loop

    popa
    ret

; ============================================================================
; sort_visible - Bubble sort visible faces by avg Z (descending)
; ============================================================================
sort_visible:
    mov     cl, [num_visible]
    cmp     cl, 2
    jb      .sort_done          ; 0 or 1 face: nothing to sort

    ; Simple bubble sort (max 4 faces = max 3 passes)
    mov     ch, 3               ; Max passes
.pass:
    xor     si, si              ; SI = byte index into visible_faces
    xor     dl, dl              ; Swapped flag
    mov     cl, [num_visible]
    dec     cl                  ; Comparisons per pass = n-1
.compare:
    ; Compare avg_z (word at offset +2) — sort descending (furthest first)
    mov     ax, [visible_faces + si + 2]
    cmp     ax, [visible_faces + si + 6]
    jge     .no_swap

    ; Swap 4-byte entries at [si] and [si+4]
    mov     ax, [visible_faces + si]
    mov     bx, [visible_faces + si + 4]
    mov     [visible_faces + si], bx
    mov     [visible_faces + si + 4], ax

    mov     ax, [visible_faces + si + 2]
    mov     bx, [visible_faces + si + 6]
    mov     [visible_faces + si + 2], bx
    mov     [visible_faces + si + 6], ax

    mov     dl, 1               ; Set swapped flag

.no_swap:
    add     si, 4
    dec     cl
    jnz     .compare

    test    dl, dl
    jz      .sort_done          ; No swaps this pass: already sorted
    dec     ch
    jnz     .pass

.sort_done:
    ret

; ============================================================================
; draw_faces - Draw all visible faces (painter's order)
; ============================================================================
draw_faces:
    pusha
    push    es

    mov     ax, VIDEO_SEG
    mov     es, ax

    mov     cl, [num_visible]
    xor     ch, ch
    test    cx, cx
    jz      .draw_done

    xor     si, si              ; SI = index into visible_faces

.draw_face_loop:
    push    cx

    ; Get face data from visible list
    mov     al, [visible_faces + si]     ; Face index
    xor     ah, ah
    mov     cl, [visible_faces + si + 1] ; Color
    mov     [fill_color], cl

    ; Look up face definition to get vertex indices
    shl     ax, 2               ; AX = face_index * FACE_STRIDE
    mov     bx, ax

    ; Get projected screen coords for the 3 vertices
    xor     ah, ah
    mov     al, [faces + bx]    ; Vertex 0
    shl     ax, 2
    mov     bp, ax
    mov     ax, [proj_x + bp]
    mov     [tri_x0], ax
    mov     ax, [proj_x + bp + 2]
    mov     [tri_y0], ax

    xor     ah, ah
    mov     al, [faces + bx + 1] ; Vertex 1
    shl     ax, 2
    mov     bp, ax
    mov     ax, [proj_x + bp]
    mov     [tri_x1], ax
    mov     ax, [proj_x + bp + 2]
    mov     [tri_y1], ax

    xor     ah, ah
    mov     al, [faces + bx + 2] ; Vertex 2
    shl     ax, 2
    mov     bp, ax
    mov     ax, [proj_x + bp]
    mov     [tri_x2], ax
    mov     ax, [proj_x + bp + 2]
    mov     [tri_y2], ax

    ; Fill the triangle
    call    fill_triangle

    add     si, 4               ; Next visible face entry
    pop     cx
    dec     cx
    jnz     .draw_face_loop

.draw_done:
    pop     es
    popa
    ret

; ============================================================================
; fill_triangle - Scanline fill a triangle
;
; Input (via memory variables):
;   tri_x0, tri_y0, tri_x1, tri_y1, tri_x2, tri_y2 (screen coords, signed)
;   fill_color (0-15)
;
; Algorithm:
;   1. Sort vertices by Y (top to bottom)
;   2. Compute edge slopes in 8.8 fixed-point
;   3. Fill top half (V0 to V1) and bottom half (V1 to V2)
; ============================================================================
fill_triangle:
    pusha

    ; --- Sort vertices by Y: y0 <= y1 <= y2 ---
    ; Compare y0 and y1
    mov     ax, [tri_y0]
    cmp     ax, [tri_y1]
    jle     .sort1_ok
    ; Swap V0 and V1
    xchg    ax, [tri_y1]
    mov     [tri_y0], ax
    mov     ax, [tri_x0]
    xchg    ax, [tri_x1]
    mov     [tri_x0], ax
.sort1_ok:
    ; Compare y1 and y2
    mov     ax, [tri_y1]
    cmp     ax, [tri_y2]
    jle     .sort2_ok
    xchg    ax, [tri_y2]
    mov     [tri_y1], ax
    mov     ax, [tri_x1]
    xchg    ax, [tri_x2]
    mov     [tri_x1], ax
.sort2_ok:
    ; Compare y0 and y1 again (after possible swap)
    mov     ax, [tri_y0]
    cmp     ax, [tri_y1]
    jle     .sort3_ok
    xchg    ax, [tri_y1]
    mov     [tri_y0], ax
    mov     ax, [tri_x0]
    xchg    ax, [tri_x1]
    mov     [tri_x0], ax
.sort3_ok:

    ; Now: tri_y0 <= tri_y1 <= tri_y2

    ; --- Clip: skip if entirely off screen ---
    mov     ax, [tri_y2]
    cmp     ax, 0
    jl      .tri_done           ; Entirely above screen
    mov     ax, [tri_y0]
    cmp     ax, SCREEN_H
    jge     .tri_done           ; Entirely below screen

    ; --- Compute slopes ---
    ; dAC = (x2-x0) * 256 / (y2-y0)  [long edge, always V0→V2]
    mov     ax, [tri_x2]
    sub     ax, [tri_x0]
    mov     bx, [tri_y2]
    sub     bx, [tri_y0]
    call    calc_slope
    mov     [slope_long], ax     ; dAC (long edge slope)

    ; dAB = (x1-x0) * 256 / (y1-y0)  [top short edge, V0→V1]
    mov     ax, [tri_x1]
    sub     ax, [tri_x0]
    mov     bx, [tri_y1]
    sub     bx, [tri_y0]
    call    calc_slope
    mov     [slope_top], ax      ; dAB

    ; dBC = (x2-x1) * 256 / (y2-y1)  [bottom short edge, V1→V2]
    mov     ax, [tri_x2]
    sub     ax, [tri_x1]
    mov     bx, [tri_y2]
    sub     bx, [tri_y1]
    call    calc_slope
    mov     [slope_bot], ax      ; dBC

    ; --- Determine which side the long edge is on ---
    ; Compare slopes: if slope_long > slope_top, long edge is on the right
    mov     ax, [slope_long]
    cmp     ax, [slope_top]
    jg      .long_on_right

    ; Long edge on left: xL tracks long edge, xR tracks short edges
    ; Top half: V0 to V1
    mov     ax, [tri_x0]
    shl     ax, 8               ; 8.8 fixed point
    mov     [edge_xL], ax       ; Left edge starts at x0
    mov     [edge_xR], ax       ; Right edge starts at x0

    mov     ax, [tri_y0]
    mov     [cur_y], ax

    ; Fill top half
    mov     cx, [tri_y1]
    sub     cx, [tri_y0]
    jle     .top_done_left
.top_loop_left:
    call    draw_scanline_LR
    mov     ax, [slope_long]
    add     [edge_xL], ax
    mov     ax, [slope_top]
    add     [edge_xR], ax
    inc     word [cur_y]
    dec     cx
    jnz     .top_loop_left
.top_done_left:

    ; Bottom half: V1 to V2 (right edge restarts at x1)
    mov     ax, [tri_x1]
    shl     ax, 8
    mov     [edge_xR], ax

    mov     cx, [tri_y2]
    sub     cx, [tri_y1]
    jle     .tri_done
.bot_loop_left:
    call    draw_scanline_LR
    mov     ax, [slope_long]
    add     [edge_xL], ax
    mov     ax, [slope_bot]
    add     [edge_xR], ax
    inc     word [cur_y]
    dec     cx
    jnz     .bot_loop_left
    jmp     .tri_done

.long_on_right:
    ; Long edge on right: xL tracks short edges, xR tracks long edge
    mov     ax, [tri_x0]
    shl     ax, 8
    mov     [edge_xL], ax
    mov     [edge_xR], ax

    mov     ax, [tri_y0]
    mov     [cur_y], ax

    ; Fill top half
    mov     cx, [tri_y1]
    sub     cx, [tri_y0]
    jle     .top_done_right
.top_loop_right:
    call    draw_scanline_LR
    mov     ax, [slope_top]
    add     [edge_xL], ax
    mov     ax, [slope_long]
    add     [edge_xR], ax
    inc     word [cur_y]
    dec     cx
    jnz     .top_loop_right
.top_done_right:

    ; Bottom half: left edge restarts at x1
    mov     ax, [tri_x1]
    shl     ax, 8
    mov     [edge_xL], ax

    mov     cx, [tri_y2]
    sub     cx, [tri_y1]
    jle     .tri_done
.bot_loop_right:
    call    draw_scanline_LR
    mov     ax, [slope_bot]
    add     [edge_xL], ax
    mov     ax, [slope_long]
    add     [edge_xR], ax
    inc     word [cur_y]
    dec     cx
    jnz     .bot_loop_right

.tri_done:
    popa
    ret

; ============================================================================
; calc_slope - Compute 8.8 fixed-point slope (overflow-safe)
;
; Input:  AX = delta_x (numerator), BX = delta_y (denominator)
; Output: AX = (delta_x * 256) / delta_y (8.8 fixed-point, clamped)
; Trashes: BX, CX, DX
;
; Uses unsigned MUL/DIV with manual sign tracking to avoid IDIV overflow
; that occurs when delta_y is small relative to delta_x (nearly-horizontal
; edges), which would otherwise cause INT 0 (divide fault) on the V40.
; ============================================================================
calc_slope:
    test    bx, bx
    jnz     .cs_nonzero
    xor     ax, ax
    ret
.cs_nonzero:
    ; Work with absolute values, track result sign separately
    mov     cx, bx              ; CX = delta_y
    xor     bx, bx              ; BX = sign toggle (0=positive, 1=negative)

    test    ax, ax
    jns     .cs_ax_pos
    neg     ax
    inc     bx                  ; Toggle sign
.cs_ax_pos:
    test    cx, cx
    jns     .cs_cx_pos
    neg     cx
    inc     bx                  ; Toggle sign
.cs_cx_pos:
    ; AX = |delta_x|, CX = |delta_y|, BX = sign (odd = negative result)
    push    bx                  ; Save sign flag

    ; Compute |delta_x| * 256 (unsigned)
    mov     bx, 256
    mul     bx                  ; DX:AX = |delta_x| * 256 (unsigned)

    ; Check for unsigned DIV overflow: DX must be < CX
    ; (if DX >= CX, quotient won't fit in 16 bits)
    cmp     dx, cx
    jb      .cs_div_ok

    ; Overflow: clamp to +/-32000
    pop     bx
    mov     ax, 32000
    test    bx, 1
    jz      .cs_ret
    neg     ax
.cs_ret:
    ret

.cs_div_ok:
    div     cx                  ; AX = |delta_x| * 256 / |delta_y| (unsigned)
    pop     bx                  ; Restore sign flag
    test    bx, 1
    jz      .cs_pos
    neg     ax                  ; Apply negative sign
.cs_pos:
    ret

; ============================================================================
; draw_scanline_LR - Draw one horizontal span of the triangle
;
; Uses edge_xL, edge_xR (8.8 fixed-point), cur_y, fill_color
; ES must be VIDEO_SEG
; ============================================================================
draw_scanline_LR:
    push    ax
    push    bx
    push    cx
    push    dx
    push    si
    push    di

    ; Get Y and check bounds
    mov     ax, [cur_y]
    cmp     ax, 0
    jl      .sl_done
    cmp     ax, SCREEN_H
    jge     .sl_done

    ; Convert 8.8 fixed-point X to integer
    mov     si, [edge_xL]
    sar     si, 8               ; SI = left X (integer, signed)
    mov     di, [edge_xR]
    sar     di, 8               ; DI = right X (integer, signed)

    ; Ensure left <= right
    cmp     si, di
    jle     .x_ordered
    xchg    si, di
.x_ordered:

    ; Clip X to screen bounds
    cmp     di, 0
    jl      .sl_done            ; Entirely off left
    cmp     si, SCREEN_W - 1
    jg      .sl_done            ; Entirely off right
    cmp     si, 0
    jge     .xl_ok
    xor     si, si
.xl_ok:
    cmp     di, SCREEN_W - 1
    jle     .xr_ok
    mov     di, SCREEN_W - 1
.xr_ok:

    ; SI = clipped left X, DI = clipped right X (both 0-159)
    ; Look up VRAM row offset
    mov     bx, [cur_y]
    shl     bx, 1
    mov     bx, [yTable + bx]   ; BX = VRAM row offset

    ; Call horizontal line fill
    ; Need: SI=x_left, DI=x_right, BX=row_offset, fill_color
    call    hline_4bpp

.sl_done:
    pop     di
    pop     si
    pop     dx
    pop     cx
    pop     bx
    pop     ax
    ret

; ============================================================================
; hline_4bpp - Fast horizontal line fill for 160x200x16 mode
;
; Input:
;   SI = left X (0-159, clipped, inclusive)
;   DI = right X (0-159, clipped, inclusive, >= left X)
;   BX = VRAM row offset (from yTable)
;   [fill_color] = color (0-15)
;   ES = VIDEO_SEG (B000h)
;
; Each byte in VRAM holds 2 pixels:
;   High nibble = left/even pixel, Low nibble = right/odd pixel
; ============================================================================
hline_4bpp:
    push    ax
    push    cx
    push    dx
    push    di
    push    si

    ; Prepare fill byte: color in both nibbles
    mov     al, [fill_color]
    mov     ah, al
    shl     ah, 4
    or      ah, al              ; AH = fill byte (e.g., 0x22 for color 2)
    mov     [hl_fill], ah

    ; Calculate byte offsets within the row
    mov     ax, si
    shr     ax, 1               ; AX = left byte offset
    mov     cx, di
    shr     cx, 1               ; CX = right byte offset

    ; Set DI to point to left byte in VRAM
    mov     dx, di              ; Save right X in DX
    mov     di, bx              ; DI = row offset
    add     di, ax              ; DI = VRAM address of left byte

    ; Same byte case?
    cmp     ax, cx
    jne     .hl_multi

    ; --- Single byte ---
    mov     al, [es:di]
    test    si, 1
    jnz     .hl_s_lodd
    ; Left is even
    test    dx, 1
    jnz     .hl_s_both          ; Even..Odd = full byte
    ; Even..Even = high nibble only
    and     al, 0x0F
    mov     ah, [hl_fill]
    and     ah, 0xF0
    or      al, ah
    mov     [es:di], al
    jmp     .hl_done
.hl_s_both:
    mov     al, [hl_fill]
    mov     [es:di], al
    jmp     .hl_done
.hl_s_lodd:
    ; Left is odd (same byte, right must also be odd)
    and     al, 0xF0
    mov     ah, [hl_fill]
    and     ah, 0x0F
    or      al, ah
    mov     [es:di], al
    jmp     .hl_done

.hl_multi:
    ; --- Multiple bytes ---
    push    cx                  ; Save right byte offset

    ; Handle left partial byte
    test    si, 1
    jz      .hl_left_full
    ; Left pixel is odd: write low nibble of first byte
    mov     al, [es:di]
    and     al, 0xF0
    mov     ah, [hl_fill]
    and     ah, 0x0F
    or      al, ah
    mov     [es:di], al
    inc     di                  ; Move past partial byte
    inc     ax                  ; AX = first full byte offset (not used further)
.hl_left_full:

    pop     cx                  ; CX = right byte offset
    push    cx                  ; Re-save for right edge handling

    ; Handle right partial byte
    test    dx, 1               ; DX = right X
    jnz     .hl_right_full
    ; Right pixel is even: only high nibble of last byte
    ; We'll handle this after filling the middle
    dec     cx                  ; Last full byte = right_byte - 1
.hl_right_full:

    ; Fill middle bytes with REP STOSB
    ; CX = last full byte, AX was left byte offset (but DI already points past partial)
    ; Number of bytes = last_full_byte_VRAM_addr - DI + 1
    ; last_full_byte_VRAM = BX (row offset) + CX
    mov     ax, bx              ; AX = row offset
    add     ax, cx              ; AX = VRAM addr of last full byte
    sub     ax, di              ; AX = bytes remaining (last - current)
    inc     ax                  ; AX = count of full bytes to fill
    jle     .hl_skip_middle     ; No middle bytes

    mov     cx, ax
    mov     al, [hl_fill]
    rep     stosb               ; Fill middle bytes! DI advances.

.hl_skip_middle:
    pop     cx                  ; CX = right byte offset (original)

    ; Handle right partial byte (if right X is even)
    test    dx, 1
    jnz     .hl_done            ; Right X is odd: already filled by middle
    ; Right X is even: write high nibble only
    ; DI should now point to the right edge byte
    mov     al, [es:di]
    and     al, 0x0F
    mov     ah, [hl_fill]
    and     ah, 0xF0
    or      al, ah
    mov     [es:di], al

.hl_done:
    pop     si
    pop     di
    pop     dx
    pop     cx
    pop     ax
    ret

; ============================================================================
; DATA SECTION
; ============================================================================

; --- Perspective constant ---
focal   dw  FOCAL_LEN

; --- Pyramid Vertices (5 vertices, X/Y/Z signed 16-bit) ---
; Coordinate system: X=right, Y=down, Z=into screen
vertices:
    dw    0, -70,   0          ; V0: Apex (top center)
    dw  -50,  50, -50          ; V1: Base front-left
    dw   50,  50, -50          ; V2: Base front-right
    dw   50,  50,  50          ; V3: Base back-right
    dw  -50,  50,  50          ; V4: Base back-left

; --- Face Definitions (4 triangular faces) ---
; Each: vertex_index_0, vertex_index_1, vertex_index_2, color
; Winding: CCW from outside (3D, Y-up convention)
; Backface test: cross < 0 in screen space = front-facing
faces:
    db  0, 1, 2,  2            ; Front face  - bright red
    db  0, 2, 3,  4            ; Right face  - bright green
    db  0, 3, 4,  6            ; Back face   - bright blue
    db  0, 4, 1,  8            ; Left face   - bright cyan

; --- Palette (16 colors x 2 bytes = 32 bytes) ---
; Format: [-----RRR] [0GGG0BBB]
; Colors chosen for vivid face shading
palette_data:
    db 0, 0x00                 ;  0: Black (background)
    db 1, 0x00                 ;  1: Very dark red
    db 7, 0x10                 ;  2: Bright red (front face)
    db 5, 0x00                 ;  3: Medium red
    db 1, 0x61                 ;  4: Bright green (right face)
    db 0, 0x40                 ;  5: Medium green
    db 1, 0x17                 ;  6: Bright blue (back face)
    db 0, 0x03                 ;  7: Medium blue
    db 0, 0x77                 ;  8: Bright cyan (left face)
    db 0, 0x44                 ;  9: Medium cyan
    db 7, 0x70                 ; 10: Yellow
    db 7, 0x40                 ; 11: Orange
    db 5, 0x55                 ; 12: Light gray
    db 3, 0x33                 ; 13: Dark gray
    db 7, 0x77                 ; 14: White
    db 4, 0x22                 ; 15: Muted purple

; --- Sine Table (256 entries, signed 16-bit, 8.8 fixed-point) ---
; sin_table[i] = round(256 * sin(2*pi*i/256))
; Range: -256 to +256 (0xFF00 to 0x0100)
; Cosine: sin_table[(i + 64) & 0xFF]
sin_table:
    dw 0, 6, 13, 19, 25, 31, 38, 44
    dw 50, 56, 62, 68, 74, 80, 86, 92
    dw 98, 104, 109, 115, 121, 126, 132, 137
    dw 142, 147, 152, 157, 162, 167, 172, 177
    dw 181, 185, 190, 194, 198, 202, 206, 209
    dw 213, 216, 220, 223, 226, 229, 231, 234
    dw 237, 239, 241, 243, 245, 247, 248, 250
    dw 251, 252, 253, 254, 255, 255, 256, 256
    dw 256, 256, 256, 255, 255, 254, 253, 252
    dw 251, 250, 248, 247, 245, 243, 241, 239
    dw 237, 234, 231, 229, 226, 223, 220, 216
    dw 213, 209, 206, 202, 198, 194, 190, 185
    dw 181, 177, 172, 167, 162, 157, 152, 147
    dw 142, 137, 132, 126, 121, 115, 109, 104
    dw 98, 92, 86, 80, 74, 68, 62, 56
    dw 50, 44, 38, 31, 25, 19, 13, 6
    dw 0, -6, -13, -19, -25, -31, -38, -44
    dw -50, -56, -62, -68, -74, -80, -86, -92
    dw -98, -104, -109, -115, -121, -126, -132, -137
    dw -142, -147, -152, -157, -162, -167, -172, -177
    dw -181, -185, -190, -194, -198, -202, -206, -209
    dw -213, -216, -220, -223, -226, -229, -231, -234
    dw -237, -239, -241, -243, -245, -247, -248, -250
    dw -251, -252, -253, -254, -255, -255, -256, -256
    dw -256, -256, -256, -255, -255, -254, -253, -252
    dw -251, -250, -248, -247, -245, -243, -241, -239
    dw -237, -234, -231, -229, -226, -223, -220, -216
    dw -213, -209, -206, -202, -198, -194, -190, -185
    dw -181, -177, -172, -167, -162, -157, -152, -147
    dw -142, -137, -132, -126, -121, -115, -109, -104
    dw -98, -92, -86, -80, -74, -68, -62, -56
    dw -50, -44, -38, -31, -25, -19, -13, -6

; --- Y-offset Table (200 entries, VRAM row offsets) ---
; CGA interlaced: even rows at base+0, odd rows at base+0x2000
; Each row = 80 bytes
yTable:
    dw 0, 8192, 80, 8272, 160, 8352, 240, 8432
    dw 320, 8512, 400, 8592, 480, 8672, 560, 8752
    dw 640, 8832, 720, 8912, 800, 8992, 880, 9072
    dw 960, 9152, 1040, 9232, 1120, 9312, 1200, 9392
    dw 1280, 9472, 1360, 9552, 1440, 9632, 1520, 9712
    dw 1600, 9792, 1680, 9872, 1760, 9952, 1840, 10032
    dw 1920, 10112, 2000, 10192, 2080, 10272, 2160, 10352
    dw 2240, 10432, 2320, 10512, 2400, 10592, 2480, 10672
    dw 2560, 10752, 2640, 10832, 2720, 10912, 2800, 10992
    dw 2880, 11072, 2960, 11152, 3040, 11232, 3120, 11312
    dw 3200, 11392, 3280, 11472, 3360, 11552, 3440, 11632
    dw 3520, 11712, 3600, 11792, 3680, 11872, 3760, 11952
    dw 3840, 12032, 3920, 12112, 4000, 12192, 4080, 12272
    dw 4160, 12352, 4240, 12432, 4320, 12512, 4400, 12592
    dw 4480, 12672, 4560, 12752, 4640, 12832, 4720, 12912
    dw 4800, 12992, 4880, 13072, 4960, 13152, 5040, 13232
    dw 5120, 13312, 5200, 13392, 5280, 13472, 5360, 13552
    dw 5440, 13632, 5520, 13712, 5600, 13792, 5680, 13872
    dw 5760, 13952, 5840, 14032, 5920, 14112, 6000, 14192
    dw 6080, 14272, 6160, 14352, 6240, 14432, 6320, 14512
    dw 6400, 14592, 6480, 14672, 6560, 14752, 6640, 14832
    dw 6720, 14912, 6800, 14992, 6880, 15072, 6960, 15152
    dw 7040, 15232, 7120, 15312, 7200, 15392, 7280, 15472
    dw 7360, 15552, 7440, 15632, 7520, 15712, 7600, 15792
    dw 7680, 15872, 7760, 15952, 7840, 16032, 7920, 16112

; ============================================================================
; BSS / VARIABLES (uninitialized at runtime)
; ============================================================================

; Rotation state
angle_y         dw 0            ; Current Y rotation angle (0-255)

; Trig cache for current frame
sin_y           dw 0
cos_y           dw 0
sin_x           dw 0
cos_x           dw 0

; Temporary vertex workspace
v_x             dw 0
v_y             dw 0
v_z             dw 0
rot_x           dw 0
rot_y           dw 0
rot_z           dw 0
rot_x2          dw 0
rot_y2          dw 0
rot_z2          dw 0

; Projected screen coordinates (5 vertices x 2 words: sx, sy)
proj_x:
    times NUM_VERTICES * 2 dw 0  ; Interleaved: sx0, sy0, sx1, sy1, ...

; Transformed Z values (for depth sorting)
trans_z:
    times NUM_VERTICES dw 0

; Face processing temporaries
sx0             dw 0
sy0             dw 0
sx1             dw 0
sy1             dw 0
sx2             dw 0
sy2             dw 0
temp32          dd 0            ; 32-bit temporary for cross product

; Visible face list (max NUM_FACES entries, 4 bytes each)
; Format: [face_index, color, avg_z (word)]
num_visible     db 0
visible_faces:
    times NUM_FACES * 4 db 0

; Triangle filler workspace
tri_x0          dw 0
tri_y0          dw 0
tri_x1          dw 0
tri_y1          dw 0
tri_x2          dw 0
tri_y2          dw 0
fill_color      db 0

slope_long      dw 0            ; Long edge slope (8.8 fixed-point)
slope_top       dw 0            ; Top short edge slope
slope_bot       dw 0            ; Bottom short edge slope
edge_xL         dw 0            ; Left edge X (8.8 fixed-point)
edge_xR         dw 0            ; Right edge X (8.8 fixed-point)
cur_y           dw 0            ; Current scanline Y

; Horizontal line workspace
hl_fill         db 0            ; Fill byte (color | color<<4)
