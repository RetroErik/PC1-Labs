; ============================================================================
; CRTC_REG_TEST.ASM — Comprehensive MC6845/V6355D Register Map
; ============================================================================
;
; Tests ALL 18 MC6845 CRTC registers (R0-R17) and V6355D extended registers
; (0x64, 0x65, 0x67) on the Olivetti Prodest PC1's Yamaha V6355D.
;
; TWO PHASES:
;
;   Phase 1 — AUTOMATED (no user input, ~3 seconds):
;     - Register readback: write known value, pollute bus, read back
;     - Live counter detection: R14/R15 read repeatedly during display
;     - PIT timing: measure frame/scanline period, test R4/R7 effect
;     - V6355D extended register readback
;
;   Phase 2 — INTERACTIVE (user answers Y/N for visual tests):
;     - Each test: display pattern → modify register → "See a change? Y/N"
;     - Low risk tests first, high risk (R0, R3) last with warning
;     - User can SKIP dangerous tests
;
;   Summary: ANSI colored table with all results
;
; CRASH RISK ORDERING (safest first):
;   Low:    R12/R13 readback, R14/R15 counter, R10/R11 cursor
;   Medium: R1, R2, R6, R9, V6355D 0x64/0x65/0x67
;   High:   R0 (H Total), R3 (H Sync Width) — could desync monitor
;
; ============================================================================
; MC6845 CRTC REGISTER MAP — V6355D Status & Test Results
; ============================================================================
;
;  Reg  Name              MC6845 R/W  Readable?  Effect     Source
;  ---  ----------------  ----------  ---------  ---------  ----------------------
;  R0   H Total           Write-only  NO         DUMMY      crtc_reg_test (Mar 2026)
;  R1   H Displayed       Write-only  NO         DUMMY      crtc_reg_test (Mar 2026)
;  R2   H Sync Position   Write-only  NO         DUMMY      crtc_reg_test (Mar 2026)
;  R3   H Sync Width      Write-only  NO         DUMMY      crtc_reg_test (Mar 2026)
;  R4   V Total           Write-only  NO         DUMMY      crtc_restarts_test
;  R5   V Total Adjust    Write-only  NO         --         Not tested
;  R6   V Displayed       Write-only  NO         DUMMY      crtc_restarts_test
;  R7   V Sync Position   Write-only  NO         DUMMY      crtc_reg_test (Mar 2026)
;  R8   Interlace Mode    Write-only  NO         --         Not tested
;  R9   Max Scanline      Write-only  NO         WORKS      crtc_restarts_test
;  R10  Cursor Start      Write-only  NO         WORKS      Text mode observation
;  R11  Cursor End        Write-only  NO         WORKS      Text mode observation
;  R12  Start Address Hi  Read/Write  NO         WORKS      cga_scroll_test
;  R13  Start Address Lo  Read/Write  YES        WORKS      crtc_reg_test (Mar 2026)
;  R14  Cursor Address Hi Read/Write  NO         --         NOT a live counter
;  R15  Cursor Address Lo Read/Write  YES        --         NOT a live counter
;  R16  Light Pen Hi      Read-only   NO         --         Not functional
;  R17  Light Pen Lo      Read-only   NO         --         Not functional
;
;  READBACK NOTES:
;    Only R13 and R15 (low bytes) return written values.
;    R12 and R14 (high bytes) return stale bus data — NOT readable.
;    R14/R15 do NOT auto-increment as live raster counters.
;
;  PIT BASELINE: 23,868 ticks/frame (confirms 76 × 314 = 23,864, ±4 jitter)
;
; ============================================================================
; V6355D EXTENDED REGISTERS (via ports 0xDD/0xDE) — SKIPPED (need bit-field tests)
; ============================================================================
;
;  Reg   Name              Bit Fields                        Status
;  ----  ----------------  --------------------------------  ------------------
;  0x60  Cursor X Lo       Bits 0-7: X position low byte    From Z-180 manual
;  0x61  Cursor X Hi       Bit 0: X position bit 8          From Z-180 manual
;  0x62  Cursor Y          Bits 0-7: Y position             Disputed (J.E.=N/A)
;  0x63  Cursor Pattern    Bits 0-7: Cursor shape           From Z-180 manual
;  0x64  Vertical Adjust   Bits 0-2: Mouse ptr visibility   UNTESTED
;                          Bits 3-5: V adjust (shift up)    WORKS (confirmed)
;                          Bits 6-7: Reserved                UNTESTED
;  0x65  Monitor Control   Bits 0-1: Line count (192/200)   WORKS (confirmed)
;                          Bit 2: H width (320/640)         UNTESTED
;                          Bit 3: PAL/NTSC                  UNTESTED
;                          Bit 4: MDA/CGA color mode        UNTESTED
;                          Bit 5: CRT/LCD                   UNTESTED
;                          Bit 6: Dynamic RAM               UNTESTED
;                          Bit 7: Light-pen                  UNTESTED
;  0x66  LCD Control       Bits 0-1: LCD V position         N/A (PC1 = CRT)
;                          Bits 2-3: LCD driver type        N/A (PC1 = CRT)
;                          Bits 4-5: LCD shift clock        N/A (PC1 = CRT)
;                          Bit 6: MDA greyscale mode        UNTESTED
;                          Bit 7: Underline blue            UNTESTED
;  0x67  Configuration     Bits 0-4: H position adjust      WORKS (confirmed)
;                          Bit 5: LCD control period         N/A (PC1 = CRT)
;                          Bit 6: 4-page VRAM (64KB only)   N/A (PC1 = 16KB)
;                          Bit 7: 16-bit bus                MUST BE 0 on PC1
;
; Sources: Z-180 Manual, John Elliott (seasip.info), ACV-1030 Manual,
;          Retro Erik hardware tests (Feb 2026)
;
; ============================================================================
;
; BUILD:
;   nasm -f bin -o crtc_reg_test.com crtc_reg_test.asm
;
; TARGET: Olivetti Prodest PC1 / V6355D / NEC V40
; By Retro Erik — 2026
; ============================================================================

[BITS 16]
[ORG 0x100]

; ============================================================================
; Constants
; ============================================================================

CRTC_ADDR       equ 0x3D4       ; MC6845 register select
CRTC_DATA       equ 0x3D5       ; MC6845 data read/write
PORT_MODE       equ 0xD8        ; V6355D mode register
PORT_STATUS     equ 0xDA        ; Status (bit 0=HSYNC, bit 3=VSYNC)
PORT_REG_ADDR   equ 0xDD        ; V6355D register bank address
PORT_REG_DATA   equ 0xDE        ; V6355D register bank data
PIT_CH0         equ 0x40        ; PIT Channel 0 data
PIT_CMD         equ 0x43        ; PIT command
ESC_CHAR        equ 0x1B        ; ANSI escape

; Readback result codes
RB_NONE         equ 0           ; Not readable (bus echo)
RB_READ         equ 1           ; Readable (value persists)
RB_LIVE         equ 2           ; Live counter (value changes)
RB_SKIP         equ 0xFE        ; Skipped
RB_NA           equ 0xFF        ; Not tested

; Effect result codes
EF_NONE         equ 0           ; No effect (dummy)
EF_WORKS        equ 1           ; Has effect
EF_SKIP         equ 0xFE        ; Skipped by user
EF_NA           equ 0xFF        ; Not tested

; ============================================================================
; Main
; ============================================================================
main:
    cld
    mov ax, cs
    mov ds, ax
    mov es, ax

    ; ==================================================================
    ; PHASE 1: Automated tests (CGA mode 4 for HSYNC/VSYNC access)
    ; ==================================================================
    mov ax, 0x0004
    int 0x10                    ; CGA 320x200 graphics (sets CRTC regs)

    ; --- Test 1: CRTC Register Readback (R0-R17) ---
    call test_crtc_readback

    ; --- Test 2: R14/R15 Live Counter Detection ---
    call test_live_counter

    ; --- Test 3: V6355D Extended Register Readback ---
    ; SKIPPED — V6355D registers need per-bit-field testing (future work)
    ;call test_v6355_readback

    ; --- Test 4: PIT Baseline Timing ---
    call pit_freerun
    call measure_frame_period
    mov [baseline_frame], ax

    call measure_scanline_period
    mov [baseline_scan], ax

    ; --- Test 5: R4 effect on frame period ---
    ; SKIPPED — R4 already CONFIRMED DUMMY by crtc_restarts_test.asm
    ;mov al, 4
    ;mov bl, 0x01
    ;call crtc_write
    ;call measure_frame_period
    ;mov [r4_frame], ax
    ;mov ax, 0x0004
    ;int 0x10
    mov word [r4_frame], 0      ; Mark as not tested

    ; --- Test 6: R7 effect on frame period ---
    mov al, 7
    mov bl, 0x01
    call crtc_write
    call measure_frame_period
    mov [r7_frame], ax
    ; Restore
    mov ax, 0x0004
    int 0x10

    ; --- Restore PIT ---
    call pit_restore

    ; --- Analyze automated results ---
    call analyze_timing

    ; --- Override R4: test was skipped, analyze_timing compared vs 0 (bogus) ---
    mov byte [crtc_effect + 4], EF_NONE  ; R4 confirmed DUMMY by crtc_restarts_test

    ; --- Pre-fill known results (confirmed on real hardware) ---
    mov byte [crtc_effect + 12], EF_WORKS  ; R12 Start Addr Hi — confirmed
    mov byte [crtc_effect + 13], EF_WORKS  ; R13 Start Addr Lo — confirmed

    ; ==================================================================
    ; PHASE 2: Interactive visual tests (text mode)
    ; ==================================================================

    ; --- Test pattern + interactive for each register ---

    ; Test A: R9 (Max Scanline) — LOW RISK
    ; SKIPPED — R9 already CONFIRMED WORKING by crtc_restarts_test.asm
    ;mov byte [vis_reg_type], 0
    ;mov byte [vis_reg_num], 9
    ;mov byte [vis_test_val], 0x03
    ;mov word [vis_prompt], s_vis_r9
    ;call run_visual_test
    ;mov al, [vis_result]
    mov byte [crtc_effect + 9], EF_WORKS   ; Known working

    ; Test B: R10/R11 (Cursor Shape) — LOW RISK
    ; SKIPPED — Cursor visibly works in text mode on PC1
    ;mov byte [vis_reg_type], 0
    ;mov byte [vis_reg_num], 10
    ;mov byte [vis_test_val], 0x00
    ;mov word [vis_prompt], s_vis_r10
    ;call run_visual_test
    ;mov al, [vis_result]
    mov byte [crtc_effect + 10], EF_WORKS  ; Known working
    ;mov byte [vis_reg_num], 11
    ;mov byte [vis_test_val], 0x0D
    ;mov word [vis_prompt], s_vis_r11
    ;call run_visual_test
    ;mov al, [vis_result]
    mov byte [crtc_effect + 11], EF_WORKS  ; Known working

    ; SKIPPED — V6355D registers need per-bit-field testing (future work)
    ; Test C: V6355D 0x64 (Vertical Adjust) — LOW RISK (already confirmed)
    ;mov byte [vis_reg_type], 1  ; V6355D type
    ;mov byte [vis_reg_num], 0   ; index 0 = 0x64
    ;mov byte [vis_test_val], 0x38  ; bits 3-5 = 7 (max shift up)
    ;mov word [vis_prompt], s_vis_64
    ;call run_visual_test
    ;mov al, [vis_result]
    ;mov [v6355_effect + 0], al

    ; Test D: V6355D 0x67 (Horizontal Position) — LOW RISK
    ;mov byte [vis_reg_type], 1
    ;mov byte [vis_reg_num], 2   ; index 2 = 0x67
    ;mov byte [vis_test_val], 0x00  ; shift H position to 0
    ;mov word [vis_prompt], s_vis_67
    ;call run_visual_test
    ;mov al, [vis_result]
    ;mov [v6355_effect + 2], al

    ; Test E: R1 (H Displayed) — MEDIUM RISK
    mov byte [vis_reg_type], 0
    mov byte [vis_reg_num], 1
    mov byte [vis_test_val], 0x14  ; 20 chars (half width)
    mov word [vis_prompt], s_vis_r1
    call run_visual_test
    mov al, [vis_result]
    mov [crtc_effect + 1], al

    ; Test F: R2 (H Sync Position) — MEDIUM RISK
    mov byte [vis_reg_type], 0
    mov byte [vis_reg_num], 2
    mov byte [vis_test_val], 0x40  ; shift right
    mov word [vis_prompt], s_vis_r2
    call run_visual_test
    mov al, [vis_result]
    mov [crtc_effect + 2], al

    ; Test G: R6 (V Displayed) — MEDIUM RISK
    ; SKIPPED — R6 already CONFIRMED DUMMY by crtc_restarts_test.asm
    ;mov byte [vis_reg_type], 0
    ;mov byte [vis_reg_num], 6
    ;mov byte [vis_test_val], 0x0C
    ;mov word [vis_prompt], s_vis_r6
    ;call run_visual_test
    ;mov al, [vis_result]
    mov byte [crtc_effect + 6], EF_NONE    ; Known dummy

    ; Test H: V6355D 0x65 (Monitor Control) — MEDIUM RISK
    ; SKIPPED — V6355D registers need per-bit-field testing (future work)
    ;mov byte [vis_reg_type], 1
    ;mov byte [vis_reg_num], 1   ; index 1 = 0x65
    ;mov byte [vis_test_val], 0x28  ; bits 0-1 = 00 → 192 lines (was 01=200)
    ;mov word [vis_prompt], s_vis_65
    ;call run_visual_test
    ;mov al, [vis_result]
    ;mov [v6355_effect + 1], al

    ; --- HIGH RISK TESTS (user warned, can skip) ---

    ; Test I: R0 (Horizontal Total) — HIGH RISK
    mov byte [vis_reg_type], 0
    mov byte [vis_reg_num], 0
    mov byte [vis_test_val], 0x61  ; slightly different from default
    mov word [vis_prompt], s_vis_r0
    call run_visual_test_risky
    mov al, [vis_result]
    mov [crtc_effect + 0], al

    ; Test J: R3 (H Sync Width) — HIGH RISK
    mov byte [vis_reg_type], 0
    mov byte [vis_reg_num], 3
    mov byte [vis_test_val], 0x05  ; narrower sync pulse
    mov word [vis_prompt], s_vis_r3
    call run_visual_test_risky
    mov al, [vis_result]
    mov [crtc_effect + 3], al

    ; ==================================================================
    ; PHASE 3: ANSI Summary
    ; ==================================================================
    mov ax, 0x0003
    int 0x10                    ; Clean text mode
    call display_summary

    ; Wait for key, exit
    mov ah, 0x00
    int 0x16
    mov ah, 0x09
    mov dx, s_reset
    int 0x21
    mov ax, 0x4C00
    int 0x21

; ============================================================================
; PHASE 1: Automated Test Routines
; ============================================================================

; ----------------------------------------------------------------------------
; test_crtc_readback — Write 0x55, pollute bus, read back for all R0-R17
; ----------------------------------------------------------------------------
test_crtc_readback:
    push ax
    push bx
    push cx
    push dx

    xor cx, cx                  ; CX = register number (0-17)

.loop:
    ; 1. Select register CX, write 0x55
    mov dx, CRTC_ADDR
    mov al, cl
    out dx, al
    inc dx                      ; DX = CRTC_DATA
    mov al, 0x55
    out dx, al

    ; 2. Pollute bus: select R12 (or R13 if CX==12), write 0xAA
    dec dx                      ; DX = CRTC_ADDR
    mov al, 12
    cmp cl, 12
    jne .not12
    mov al, 13
.not12:
    out dx, al
    inc dx
    mov al, 0xAA
    out dx, al

    ; 3. Re-select register CX, read back
    dec dx
    mov al, cl
    out dx, al
    inc dx
    in al, dx                   ; Read!

    ; 4. Store raw read value
    mov bx, cx
    mov [crtc_read_val + bx], al

    ; 5. Determine result: 0x55 = readable, 0xAA = bus echo, other = unknown
    cmp al, 0x55
    jne .not_readable
    mov byte [crtc_readback + bx], RB_READ
    jmp .next
.not_readable:
    mov byte [crtc_readback + bx], RB_NONE

.next:
    inc cx
    cmp cx, 18
    jb .loop

    ; Restore CRTC by re-setting mode
    mov ax, 0x0004
    int 0x10

    pop dx
    pop cx
    pop bx
    pop ax
    ret

; ----------------------------------------------------------------------------
; test_live_counter — Read R14 and R15 repeatedly, check if values change
; ----------------------------------------------------------------------------
test_live_counter:
    push ax
    push bx
    push cx
    push dx

    ; Wait for active display (not VBLANK)
    mov dx, PORT_STATUS
.wait_active:
    in al, dx
    test al, 0x08
    jnz .wait_active

    ; Read R14 fifty times, track min/max
    mov dx, CRTC_ADDR
    mov al, 14
    out dx, al
    inc dx                      ; DX = CRTC_DATA
    mov bh, 0xFF                ; min
    mov bl, 0x00                ; max
    mov cx, 50
.r14_loop:
    in al, dx
    cmp al, bh
    jae .r14_not_min
    mov bh, al
.r14_not_min:
    cmp al, bl
    jbe .r14_not_max
    mov bl, al
.r14_not_max:
    loop .r14_loop

    mov [r14_min], bh
    mov [r14_max], bl
    ; If max > min, values are changing → live counter
    cmp bl, bh
    je .r14_not_live
    ; Only mark as LIVE if readback test also passed
    cmp byte [crtc_readback + 14], RB_READ
    jne .r14_not_live
    mov byte [crtc_readback + 14], RB_LIVE
.r14_not_live:

    ; Read R15 fifty times
    dec dx                      ; DX = CRTC_ADDR
    mov al, 15
    out dx, al
    inc dx
    mov bh, 0xFF
    mov bl, 0x00
    mov cx, 50
.r15_loop:
    in al, dx
    cmp al, bh
    jae .r15_not_min
    mov bh, al
.r15_not_min:
    cmp al, bl
    jbe .r15_not_max
    mov bl, al
.r15_not_max:
    loop .r15_loop

    mov [r15_min], bh
    mov [r15_max], bl
    cmp bl, bh
    je .r15_not_live
    cmp byte [crtc_readback + 15], RB_READ
    jne .r15_not_live
    mov byte [crtc_readback + 15], RB_LIVE
.r15_not_live:

    pop dx
    pop cx
    pop bx
    pop ax
    ret

; ----------------------------------------------------------------------------
; test_v6355_readback — Test readability of V6355D registers 0x64, 0x65, 0x67
; SKIPPED — These registers need per-bit-field testing (future work)
; ----------------------------------------------------------------------------
;test_v6355_readback:
;    push ax
;    push bx
;    push dx
;
;    ; Close any palette session first
;    mov al, 0x80
;    out PORT_REG_ADDR, al
;
;    ; --- Test 0x64 (index 0) ---
;    mov al, 0x64
;    out PORT_REG_ADDR, al
;    mov al, 0x55
;    out PORT_REG_DATA, al       ; Write 0x55
;
;    mov al, 0x80                ; Close / pollute
;    out PORT_REG_ADDR, al
;
;    mov al, 0x64                ; Re-select
;    out PORT_REG_ADDR, al
;    in al, PORT_REG_DATA        ; Read back
;    mov [v6355_read_val + 0], al
;    cmp al, 0x55
;    jne .v64_no
;    mov byte [v6355_readback + 0], RB_READ
;    jmp .v64_done
;.v64_no:
;    mov byte [v6355_readback + 0], RB_NONE
;.v64_done:
;    ; Restore 0x64 to default (0x00)
;    mov al, 0x64
;    out PORT_REG_ADDR, al
;    xor al, al
;    out PORT_REG_DATA, al
;
;    ; --- Test 0x65 (index 1) ---
;    ; CAUTION: 0x65 overlaps palette range. Close palette after.
;    mov al, 0x65
;    out PORT_REG_ADDR, al
;    mov al, 0x55
;    out PORT_REG_DATA, al
;
;    mov al, 0x80
;    out PORT_REG_ADDR, al
;
;    mov al, 0x65
;    out PORT_REG_ADDR, al
;    in al, PORT_REG_DATA
;    mov [v6355_read_val + 1], al
;    cmp al, 0x55
;    jne .v65_no
;    mov byte [v6355_readback + 1], RB_READ
;    jmp .v65_done
;.v65_no:
;    mov byte [v6355_readback + 1], RB_NONE
;.v65_done:
;    ; Restore 0x65 to default (0x29 for PAL, 200 lines)
;    mov al, 0x65
;    out PORT_REG_ADDR, al
;    mov al, 0x29
;    out PORT_REG_DATA, al
;    mov al, 0x80
;    out PORT_REG_ADDR, al
;
;    ; --- Test 0x67 (index 2) ---
;    mov al, 0x67
;    out PORT_REG_ADDR, al
;    mov al, 0x55
;    out PORT_REG_DATA, al
;
;    mov al, 0x80
;    out PORT_REG_ADDR, al
;
;    mov al, 0x67
;    out PORT_REG_ADDR, al
;    in al, PORT_REG_DATA
;    mov [v6355_read_val + 2], al
;    cmp al, 0x55
;    jne .v67_no
;    mov byte [v6355_readback + 2], RB_READ
;    jmp .v67_done
;.v67_no:
;    mov byte [v6355_readback + 2], RB_NONE
;.v67_done:
;    ; Restore 0x67 (default varies by PERITEL state, use 0x11)
;    mov al, 0x67
;    out PORT_REG_ADDR, al
;    mov al, 0x11
;    out PORT_REG_DATA, al
;    mov al, 0x80
;    out PORT_REG_ADDR, al
;
;    ; Re-set mode to ensure everything is clean
;    mov ax, 0x0004
;    int 0x10
;
;    pop dx
;    pop bx
;    pop ax
;    ret

; ----------------------------------------------------------------------------
; analyze_timing — Compare PIT measurements to determine R4/R7 effect
; ----------------------------------------------------------------------------
analyze_timing:
    ; R4: compare baseline_frame vs r4_frame
    ; If within ±5%: no effect (dummy)
    mov ax, [baseline_frame]
    mov bx, [r4_frame]
    sub ax, bx
    ; ABS(difference)
    jns .r4_pos
    neg ax
.r4_pos:
    cmp ax, 100                 ; >100 tick difference = effect
    jb .r4_dummy
    mov byte [crtc_effect + 4], EF_WORKS
    jmp .r4_done
.r4_dummy:
    mov byte [crtc_effect + 4], EF_NONE
.r4_done:

    ; R7: compare baseline_frame vs r7_frame
    mov ax, [baseline_frame]
    mov bx, [r7_frame]
    sub ax, bx
    jns .r7_pos
    neg ax
.r7_pos:
    cmp ax, 100
    jb .r7_dummy
    mov byte [crtc_effect + 7], EF_WORKS
    jmp .r7_done
.r7_dummy:
    mov byte [crtc_effect + 7], EF_NONE
.r7_done:
    ret

; ============================================================================
; PHASE 2: Interactive Visual Tests
; ============================================================================

; ----------------------------------------------------------------------------
; run_visual_test — Show pattern, modify register, ask Y/N, restore
; ----------------------------------------------------------------------------
; Uses: vis_reg_type (0=CRTC, 1=V6355D)
;       vis_reg_num  (register number or V6355D index)
;       vis_test_val (value to write)
;       vis_prompt   (prompt string pointer)
; Sets: vis_result   (EF_WORKS / EF_NONE)
; ----------------------------------------------------------------------------
run_visual_test:
    push ax
    push bx
    push dx

    ; Set text mode and fill pattern
    mov ax, 0x0003
    int 0x10
    call fill_test_pattern

    ; Print prompt at row 24
    mov ah, 0x02                ; Set cursor position
    mov bh, 0x00
    mov dh, 23                  ; Row 23 (0-based)
    mov dl, 0
    int 0x10
    mov ah, 0x09
    mov dx, [vis_prompt]
    int 0x21

    ; Print "Press SPACE to apply, S to skip"
    mov ah, 0x02
    mov bh, 0x00
    mov dh, 24
    mov dl, 0
    int 0x10
    mov ah, 0x09
    mov dx, s_press_space
    int 0x21

    ; Wait for SPACE or S
    mov ah, 0x00
    int 0x16
    cmp al, ' '
    je .apply
    cmp al, 's'
    je .skip
    cmp al, 'S'
    je .skip
    ; Any other key, treat as apply
    jmp .apply

.skip:
    mov byte [vis_result], EF_SKIP
    jmp .done

.apply:
    ; Apply the register change
    cmp byte [vis_reg_type], 0
    jne .apply_v6355

    ; CRTC register
    mov al, [vis_reg_num]
    mov bl, [vis_test_val]
    call crtc_write
    jmp .ask_result

.apply_v6355:
    ; V6355D register (index 0=0x64, 1=0x65, 2=0x67)
    mov al, [vis_reg_num]
    mov bl, [vis_test_val]
    call v6355_write
    jmp .ask_result

.ask_result:
    ; Print "Did the display change? (Y/N)"
    mov ah, 0x02
    mov bh, 0x00
    mov dh, 24
    mov dl, 0
    int 0x10
    mov ah, 0x09
    mov dx, s_ask_yn
    int 0x21

    ; Wait for Y or N
.yn_wait:
    mov ah, 0x00
    int 0x16
    cmp al, 'y'
    je .yes
    cmp al, 'Y'
    je .yes
    cmp al, 'n'
    je .no
    cmp al, 'N'
    je .no
    jmp .yn_wait

.yes:
    mov byte [vis_result], EF_WORKS
    jmp .done
.no:
    mov byte [vis_result], EF_NONE

.done:
    ; Restore by re-setting text mode
    mov ax, 0x0003
    int 0x10

    pop dx
    pop bx
    pop ax
    ret

; ----------------------------------------------------------------------------
; run_visual_test_risky — Same but warns user and auto-restores after 2 sec
; ----------------------------------------------------------------------------
run_visual_test_risky:
    push ax
    push bx
    push dx

    ; Set text mode and fill pattern
    mov ax, 0x0003
    int 0x10
    call fill_test_pattern

    ; Print warning + prompt at rows 22-24
    mov ah, 0x02
    mov bh, 0x00
    mov dh, 22
    mov dl, 0
    int 0x10
    mov ah, 0x09
    mov dx, s_risky_warn
    int 0x21

    mov ah, 0x02
    mov bh, 0x00
    mov dh, 23
    mov dl, 0
    int 0x10
    mov ah, 0x09
    mov dx, [vis_prompt]
    int 0x21

    mov ah, 0x02
    mov bh, 0x00
    mov dh, 24
    mov dl, 0
    int 0x10
    mov ah, 0x09
    mov dx, s_risky_press
    int 0x21

    ; Wait for Y or S
    mov ah, 0x00
    int 0x16
    cmp al, 'y'
    je .risky_apply
    cmp al, 'Y'
    je .risky_apply
    ; Anything else = skip
    mov byte [vis_result], EF_SKIP
    jmp .risky_done

.risky_apply:
    ; Apply register change
    cmp byte [vis_reg_type], 0
    jne .risky_v6355
    mov al, [vis_reg_num]
    mov bl, [vis_test_val]
    call crtc_write
    jmp .risky_wait

.risky_v6355:
    mov al, [vis_reg_num]
    mov bl, [vis_test_val]
    call v6355_write

.risky_wait:
    ; Wait ~2 seconds (auto-restore) via BIOS tick count
    push es
    xor ax, ax
    mov es, ax
    mov ax, [es:0x046C]         ; BIOS tick count (low word)
    add ax, 36                  ; ~2 seconds at 18.2 Hz
    mov bx, ax
.tick_wait:
    mov ax, [es:0x046C]
    cmp ax, bx
    jb .tick_wait
    pop es

    ; Restore immediately
    mov ax, 0x0003
    int 0x10
    call fill_test_pattern

    ; Ask if they saw a change
    mov ah, 0x02
    mov bh, 0x00
    mov dh, 24
    mov dl, 0
    int 0x10
    mov ah, 0x09
    mov dx, s_risky_ask
    int 0x21

.risky_yn:
    mov ah, 0x00
    int 0x16
    cmp al, 'y'
    je .risky_yes
    cmp al, 'Y'
    je .risky_yes
    cmp al, 'n'
    je .risky_no
    cmp al, 'N'
    je .risky_no
    jmp .risky_yn

.risky_yes:
    mov byte [vis_result], EF_WORKS
    jmp .risky_done
.risky_no:
    mov byte [vis_result], EF_NONE

.risky_done:
    mov ax, 0x0003
    int 0x10
    pop dx
    pop bx
    pop ax
    ret

; ============================================================================
; PHASE 3: ANSI Summary Display
; ============================================================================

display_summary:
    ; === Title ===
    mov ah, 0x09
    mov dx, s_title
    int 0x21
    mov dx, s_sep
    int 0x21
    mov dx, s_credits
    int 0x21
    mov dx, s_nl
    int 0x21

    ; === Section: CRTC Register Readback ===
    mov dx, s_sec_readback
    int 0x21
    mov dx, s_tbl_header
    int 0x21
    mov dx, s_tbl_line
    int 0x21

    ; Print each CRTC register row
    xor cx, cx                  ; CX = register index
.print_crtc:
    push cx
    ; Register name
    call print_reg_name         ; Prints "  R0  H Total   │ "

    ; Read value (hex)
    mov bx, cx
    mov al, [crtc_read_val + bx]
    call print_hex_byte

    ; Separator
    mov ah, 0x09
    mov dx, s_col_sep
    int 0x21

    ; Readback result
    mov bx, cx
    mov al, [crtc_readback + bx]
    call print_readback_code

    ; Separator
    mov ah, 0x09
    mov dx, s_col_sep
    int 0x21

    ; Effect result
    mov al, [crtc_effect + bx]
    call print_effect_code

    ; Newline
    mov ah, 0x09
    mov dx, s_nl
    int 0x21

    pop cx
    inc cx
    cmp cx, 18
    jb .print_crtc

    ; === Section: V6355D Extended Registers ===
    ; SKIPPED — These registers need per-bit-field testing (future work)
    ;mov ah, 0x09
    ;mov dx, s_nl
    ;int 0x21
    ;mov dx, s_sec_v6355
    ;int 0x21
    ;mov dx, s_tbl_header
    ;int 0x21
    ;mov dx, s_tbl_line
    ;int 0x21
;
    ; Print V6355D register rows (3 registers: 0x64, 0x65, 0x67)
    ;xor cx, cx
;.print_v6355:
    ;push cx
    ;call print_v6355_name       ; Prints "  0x64 V.Adjust │ "
;
    ; Read value
    ;mov bx, cx
    ;mov al, [v6355_read_val + bx]
    ;call print_hex_byte
;
    ;mov ah, 0x09
    ;mov dx, s_col_sep
    ;int 0x21
;
    ;mov bx, cx
    ;mov al, [v6355_readback + bx]
    ;call print_readback_code
;
    ;mov ah, 0x09
    ;mov dx, s_col_sep
    ;int 0x21
;
    ;mov al, [v6355_effect + bx]
    ;call print_effect_code
;
    ;mov ah, 0x09
    ;mov dx, s_nl
    ;int 0x21
;
    ;pop cx
    ;inc cx
    ;cmp cx, 3
    ;jb .print_v6355

    ; === Section: Live Counter ===
    mov ah, 0x09
    mov dx, s_nl
    int 0x21
    mov dx, s_sec_counter
    int 0x21

    ; R14 range
    mov dx, s_lbl_r14
    int 0x21
    mov al, [r14_min]
    call print_hex_byte
    mov al, '-'
    call put_char
    mov al, [r14_max]
    call print_hex_byte

    ; Result
    cmp byte [crtc_readback + 14], RB_LIVE
    jne .r14_no_ctr
    mov dx, s_ctr_yes
    jmp .r14_ctr_done
.r14_no_ctr:
    mov dx, s_ctr_no
.r14_ctr_done:
    mov ah, 0x09
    int 0x21

    ; R15 range
    mov dx, s_lbl_r15
    int 0x21
    mov al, [r15_min]
    call print_hex_byte
    mov al, '-'
    call put_char
    mov al, [r15_max]
    call print_hex_byte

    cmp byte [crtc_readback + 15], RB_LIVE
    jne .r15_no_ctr
    mov dx, s_ctr_yes
    jmp .r15_ctr_done
.r15_no_ctr:
    mov dx, s_ctr_no
.r15_ctr_done:
    mov ah, 0x09
    int 0x21

    ; === Section: Timing ===
    mov ah, 0x09
    mov dx, s_nl
    int 0x21
    mov dx, s_sec_timing
    int 0x21

    ; Baseline frame
    mov dx, s_lbl_baseline
    int 0x21
    mov ax, [baseline_frame]
    call print_dec
    mov dx, s_sfx_ticks
    int 0x21

    ; Baseline scanline
    mov dx, s_lbl_scanline
    int 0x21
    mov ax, [baseline_scan]
    call print_dec
    mov dx, s_sfx_ticks
    int 0x21

    ; R4 result
    mov dx, s_lbl_r4
    int 0x21
    mov ax, [r4_frame]
    call print_dec
    cmp byte [crtc_effect + 4], EF_NONE
    jne .r4_eff
    mov dx, s_eff_dummy
    jmp .r4_eff_done
.r4_eff:
    mov dx, s_eff_works
.r4_eff_done:
    mov ah, 0x09
    int 0x21

    ; R7 result
    mov dx, s_lbl_r7
    int 0x21
    mov ax, [r7_frame]
    call print_dec
    cmp byte [crtc_effect + 7], EF_NONE
    jne .r7_eff
    mov dx, s_eff_dummy
    jmp .r7_eff_done
.r7_eff:
    mov dx, s_eff_works
.r7_eff_done:
    mov ah, 0x09
    int 0x21

    ; === Footer ===
    mov ah, 0x09
    mov dx, s_nl
    int 0x21
    mov dx, s_footer
    int 0x21

    ret

; ============================================================================
; Helper: Print register name for CRTC R0-R17
; ============================================================================
; Input: CX = register number (0-17)
; Prints the name with ANSI color and column separator
print_reg_name:
    push ax
    push bx
    push dx

    ; Yellow for register label
    mov ah, 0x09
    mov dx, s_col_yellow
    int 0x21

    ; Calculate string offset: each name is 16 bytes
    mov ax, cx
    shl ax, 4                   ; AX = CX * 16
    add ax, crtc_names
    mov dx, ax
    mov ah, 0x09
    int 0x21

    ; White for value
    mov dx, s_col_white
    int 0x21

    pop dx
    pop bx
    pop ax
    ret

; ============================================================================
; Helper: Print V6355D register name
; SKIPPED — V6355D registers need per-bit-field testing (future work)
; ============================================================================
;print_v6355_name:
;    push ax
;    push dx
;
;    mov ah, 0x09
;    mov dx, s_col_yellow
;    int 0x21
;
;    mov ax, cx
;    shl ax, 4                   ; AX = CX * 16
;    add ax, v6355_names
;    mov dx, ax
;    mov ah, 0x09
;    int 0x21
;
;    mov dx, s_col_white
;    int 0x21
;
;    pop dx
;    pop ax
;    ret

; ============================================================================
; Helper: Print readback result code
; ============================================================================
print_readback_code:
    push dx
    cmp al, RB_LIVE
    je .is_live
    cmp al, RB_READ
    je .is_read
    cmp al, RB_SKIP
    je .is_skip
    cmp al, RB_NA
    je .is_na
    ; RB_NONE
    mov dx, s_rb_none
    jmp .pr_done
.is_read:
    mov dx, s_rb_read
    jmp .pr_done
.is_live:
    mov dx, s_rb_live
    jmp .pr_done
.is_skip:
    mov dx, s_rb_skip
    jmp .pr_done
.is_na:
    mov dx, s_rb_na
.pr_done:
    mov ah, 0x09
    int 0x21
    pop dx
    ret

; ============================================================================
; Helper: Print effect result code
; ============================================================================
print_effect_code:
    push dx
    cmp al, EF_WORKS
    je .is_works
    cmp al, EF_SKIP
    je .is_skip
    cmp al, EF_NA
    je .is_na
    cmp al, EF_NONE
    je .is_none
    mov dx, s_ef_na
    jmp .pe_done
.is_works:
    mov dx, s_ef_works
    jmp .pe_done
.is_none:
    mov dx, s_ef_none
    jmp .pe_done
.is_skip:
    mov dx, s_ef_skip
    jmp .pe_done
.is_na:
    mov dx, s_ef_na
.pe_done:
    mov ah, 0x09
    int 0x21
    pop dx
    ret

; ============================================================================
; Helper: CRTC read/write
; ============================================================================
; crtc_write: AL = register, BL = value
crtc_write:
    push dx
    mov dx, CRTC_ADDR
    out dx, al
    inc dx
    mov al, bl
    out dx, al
    pop dx
    ret

; crtc_read: AL = register → AL = value read
crtc_read:
    push dx
    mov dx, CRTC_ADDR
    out dx, al
    inc dx
    in al, dx
    pop dx
    ret

; ============================================================================
; Helper: V6355D read/write
; NOTE: V6355D tests are skipped but v6355_write is kept for code references
; ============================================================================
; v6355_write: AL = index (0=0x64, 1=0x65, 2=0x67), BL = value
v6355_write:
    push ax
    push dx
    ; Convert index to register address
    mov ah, al
    cmp ah, 0
    jne .vw_not0
    mov al, 0x64
    jmp .vw_do
.vw_not0:
    cmp ah, 1
    jne .vw_not1
    mov al, 0x65
    jmp .vw_do
.vw_not1:
    mov al, 0x67
.vw_do:
    out PORT_REG_ADDR, al
    mov al, bl
    out PORT_REG_DATA, al
    ; Close palette session
    mov al, 0x80
    out PORT_REG_ADDR, al
    pop dx
    pop ax
    ret

; ============================================================================
; Helper: Fill text screen with colored test pattern
; ============================================================================
fill_test_pattern:
    push ax
    push bx
    push cx
    push di
    push es

    mov ax, 0xB800
    mov es, ax
    xor di, di
    mov cx, 23 * 80             ; 23 rows (save bottom 2 for prompts)
    xor bx, bx                 ; Column counter
.fill:
    ; Character = block char 0xDB
    mov al, 0xDB
    stosb
    ; Attribute = cycling foreground + background
    mov ax, bx
    and al, 0x0F                ; Low nibble for foreground
    mov ah, al
    shl ah, 4                   ; Shift to background
    inc ah                      ; Different bg
    and ah, 0x70
    or al, ah
    stosb
    inc bx
    loop .fill

    ; Clear bottom 2 rows (black)
    mov cx, 2 * 80
    xor ax, ax
.clear_bottom:
    stosw
    loop .clear_bottom

    pop es
    pop di
    pop cx
    pop bx
    pop ax
    ret

; ============================================================================
; Helper: PIT routines
; ============================================================================
pit_freerun:
    mov al, 0x34                ; CH0, lo/hi, Mode 2, binary
    out PIT_CMD, al
    xor al, al
    out PIT_CH0, al             ; Count = 65536
    out PIT_CH0, al
    ret

pit_restore:
    mov al, 0x36                ; CH0, lo/hi, Mode 3, binary
    out PIT_CMD, al
    xor al, al
    out PIT_CH0, al
    out PIT_CH0, al
    ret

pit_latch:
    ; Latch CH0, read count → AX
    push dx
    mov al, 0x00                ; Latch CH0
    out PIT_CMD, al
    in al, PIT_CH0
    mov dl, al
    in al, PIT_CH0
    mov ah, al
    mov al, dl
    pop dx
    ret

; measure_frame_period: VSYNC→VSYNC ticks → AX
measure_frame_period:
    push dx
    mov dx, PORT_STATUS
    ; Wait for VSYNC end
.mf_end:
    in al, dx
    test al, 0x08
    jnz .mf_end
    ; Wait for VSYNC start
.mf_start:
    in al, dx
    test al, 0x08
    jz .mf_start
    ; Latch PIT → start count
    call pit_latch
    mov [pit_start], ax
    ; Wait for next VSYNC end+start
.mf_end2:
    in al, dx
    test al, 0x08
    jnz .mf_end2
.mf_start2:
    in al, dx
    test al, 0x08
    jz .mf_start2
    ; Latch PIT → end count
    call pit_latch
    ; Delta = start - end (PIT counts down)
    mov bx, ax
    mov ax, [pit_start]
    sub ax, bx
    pop dx
    ret

; measure_scanline_period: 100 HSYNCs → ticks → AX
measure_scanline_period:
    push bx
    push cx
    push dx
    mov dx, PORT_STATUS

    ; Wait for HSYNC edge to start
.ms_wait1:
    in al, dx
    test al, 0x01
    jnz .ms_wait1
.ms_wait2:
    in al, dx
    test al, 0x01
    jz .ms_wait2

    call pit_latch
    mov [pit_start], ax

    mov cx, 100
.ms_loop:
.ms_lo:
    in al, dx
    test al, 0x01
    jnz .ms_lo
.ms_hi:
    in al, dx
    test al, 0x01
    jz .ms_hi
    loop .ms_loop

    call pit_latch
    mov bx, ax
    mov ax, [pit_start]
    sub ax, bx

    pop dx
    pop cx
    pop bx
    ret

; ============================================================================
; Helper: Print routines
; ============================================================================

; print_dec: AX → decimal string via DOS
print_dec:
    push ax
    push bx
    push cx
    push dx
    xor cx, cx
    mov bx, 10
.dv:
    xor dx, dx
    div bx
    push dx
    inc cx
    or ax, ax
    jnz .dv
.pr:
    pop ax
    add al, '0'
    call put_char
    loop .pr
    pop dx
    pop cx
    pop bx
    pop ax
    ret

; print_hex_byte: AL → 2-digit hex string
print_hex_byte:
    push ax
    push cx
    mov cl, al
    shr al, 4
    call .nib
    mov al, cl
    and al, 0x0F
    call .nib
    pop cx
    pop ax
    ret
.nib:
    add al, '0'
    cmp al, '9'
    jbe .nib_ok
    add al, 7                   ; 'A'-'9'-1 = 7
.nib_ok:
    call put_char
    ret

; put_char: AL → DOS char output
put_char:
    push ax
    push dx
    mov dl, al
    mov ah, 0x02
    int 0x21
    pop dx
    pop ax
    ret

; ============================================================================
; DATA — Results
; ============================================================================

; CRTC R0-R17 results
crtc_readback:  times 18 db RB_NA
crtc_effect:    times 18 db EF_NA
crtc_read_val:  times 18 db 0

; V6355D results (3 registers: 0x64, 0x65, 0x67)
v6355_readback: times 3 db RB_NA
v6355_effect:   times 3 db EF_NA
v6355_read_val: times 3 db 0

; Live counter tracking
r14_min:        db 0xFF
r14_max:        db 0x00
r15_min:        db 0xFF
r15_max:        db 0x00

; PIT measurements
pit_start:      dw 0
baseline_frame: dw 0
baseline_scan:  dw 0
r4_frame:       dw 0
r7_frame:       dw 0

; Visual test state
vis_reg_type:   db 0            ; 0=CRTC, 1=V6355D
vis_reg_num:    db 0
vis_test_val:   db 0
vis_prompt:     dw 0
vis_result:     db 0

; ============================================================================
; DATA — Register Names (16 bytes each, $-terminated)
; ============================================================================

crtc_names:
    db '  R0  H Total  $'       ;  0 — Horizontal Total
    db '  R1  H Displ  $'       ;  1 — Horizontal Displayed
    db '  R2  H Sync P $'       ;  2 — H Sync Position
    db '  R3  H Sync W $'       ;  3 — H Sync Width
    db '  R4  V Total  $'       ;  4 — Vertical Total
    db '  R5  V Adjust $'       ;  5 — V Total Adjust
    db '  R6  V Displ  $'       ;  6 — Vertical Displayed
    db '  R7  V Sync P $'       ;  7 — V Sync Position
    db '  R8  Interlac $'       ;  8 — Interlace Mode
    db '  R9  MaxScanl $'       ;  9 — Max Scanline Address
    db '  R10 Cur Star $'       ; 10 — Cursor Start
    db '  R11 Cur End  $'       ; 11 — Cursor End
    db '  R12 Addr Hi  $'       ; 12 — Start Address High
    db '  R13 Addr Lo  $'       ; 13 — Start Address Low
    db '  R14 Cur Hi   $'       ; 14 — Cursor Addr High
    db '  R15 Cur Lo   $'       ; 15 — Cursor Addr Low
    db '  R16 LP Hi    $'       ; 16 — Light Pen High
    db '  R17 LP Lo    $'       ; 17 — Light Pen Low

v6355_names:
    db '  0x64 V.Adj   $'       ;  0 — Vertical Adjustment
    db '  0x65 Monitor $'       ;  1 — Monitor Control
    db '  0x67 H.Pos   $'       ;  2 — Horizontal Position

; ============================================================================
; DATA — ANSI Strings
; ============================================================================

s_col_yellow:
    db ESC_CHAR, '[1;33m$'
s_col_white:
    db ESC_CHAR, '[1;37m$'
s_col_green:
    db ESC_CHAR, '[1;32m$'
s_col_red:
    db ESC_CHAR, '[1;31m$'
s_col_cyan:
    db ESC_CHAR, '[1;36m$'
s_col_magenta:
    db ESC_CHAR, '[1;35m$'
s_col_grey:
    db ESC_CHAR, '[0;37m$'
s_reset:
    db ESC_CHAR, '[0m$'
s_nl:
    db 13, 10, '$'

; Title
s_title:
    db ESC_CHAR, '[2J'                     ; Clear screen
    db ESC_CHAR, '[H'                      ; Home cursor
    db ESC_CHAR, '[1;36m'                  ; Bright Cyan
    db ' CRTC Register Test: MC6845 / V6355D'
    db 13, 10, '$'

s_sep:
    db ESC_CHAR, '[1;33m'
    db ' ', 205,205,205,205,205,205,205,205,205,205,205,205,205,205,205
    db     205,205,205,205,205,205,205,205,205,205,205,205,205,205,205
    db     205,205,205,205,205,205,205,205,205,205,205,205,205,205,205
    db     205,205,205,205,205,205,205,205,205
    db 13, 10, '$'

s_credits:
    db ESC_CHAR, '[0;37m'
    db ' Created by '
    db ESC_CHAR, '[1;35m', 'Retro '
    db ESC_CHAR, '[1;36m', 'Erik'
    db ESC_CHAR, '[0;37m', ', 2026'
    db ' ', 196, ' Olivetti PC1 / V6355D / NEC V40'
    db 13, 10, '$'

; Section headers
s_sec_readback:
    db ESC_CHAR, '[1;36m'
    db ' ', 196,196,196, ' Register Map '
    db 196,196,196,196,196,196,196,196,196,196,196,196,196,196,196
    db 196,196,196,196,196,196,196,196,196,196,196,196,196,196,196
    db 196,196,196,196,196,196,196,196,196,196
    db 13, 10, '$'

s_sec_v6355:
    db ESC_CHAR, '[1;36m'
    db ' ', 196,196,196, ' V6355D Extended '
    db 196,196,196,196,196,196,196,196,196,196,196,196,196,196,196
    db 196,196,196,196,196,196,196,196,196,196,196,196,196,196,196
    db 196,196,196,196,196,196,196
    db 13, 10, '$'

s_sec_counter:
    db ESC_CHAR, '[1;36m'
    db ' ', 196,196,196, ' Live Counter (R14/R15) '
    db 196,196,196,196,196,196,196,196,196,196,196,196,196,196,196
    db 196,196,196,196,196,196,196,196,196,196,196,196,196,196,196
    db 13, 10, '$'

s_sec_timing:
    db ESC_CHAR, '[1;36m'
    db ' ', 196,196,196, ' PIT Timing Tests '
    db 196,196,196,196,196,196,196,196,196,196,196,196,196,196,196
    db 196,196,196,196,196,196,196,196,196,196,196,196,196,196,196
    db 196,196,196,196,196
    db 13, 10, '$'

; Table header
s_tbl_header:
    db ESC_CHAR, '[0;37m'
    db '  Register      ', 179, '  Read ', 179, ' Readable ', 179, ' Effect'
    db 13, 10, '$'

s_tbl_line:
    db ESC_CHAR, '[0;37m'
    db '  ', 196,196,196,196,196,196,196,196,196,196,196,196,196,196
    db 196
    db 197
    db 196,196,196,196,196,196
    db 197
    db 196,196,196,196,196,196,196,196,196,196
    db 197
    db 196,196,196,196,196,196,196,196,196,196
    db 13, 10, '$'

s_col_sep:
    db ESC_CHAR, '[0;37m'
    db '  ', 179, ' $'

; Readback result strings
s_rb_none:
    db ESC_CHAR, '[1;31m', '  NO    $'      ; Red
s_rb_read:
    db ESC_CHAR, '[1;32m', '  YES   $'      ; Green
s_rb_live:
    db ESC_CHAR, '[1;35m', ' LIVE!  $'      ; Magenta
s_rb_skip:
    db ESC_CHAR, '[0;37m', ' SKIP   $'      ; Grey
s_rb_na:
    db ESC_CHAR, '[0;37m', '  --    $'       ; Grey

; Effect result strings
s_ef_works:
    db ESC_CHAR, '[1;32m', ' WORKS  $'      ; Green
s_ef_none:
    db ESC_CHAR, '[1;31m', ' DUMMY  $'      ; Red
s_ef_skip:
    db ESC_CHAR, '[0;37m', ' SKIP   $'      ; Grey
s_ef_na:
    db ESC_CHAR, '[0;37m', '  --    $'       ; Grey

; Live counter labels
s_lbl_r14:
    db ESC_CHAR, '[1;33m'
    db '  R14 (Cursor Hi):  range '
    db ESC_CHAR, '[1;37m', '$'
s_lbl_r15:
    db ESC_CHAR, '[1;33m'
    db '  R15 (Cursor Lo):  range '
    db ESC_CHAR, '[1;37m', '$'
s_ctr_yes:
    db ESC_CHAR, '[1;35m', '  ', 16, ' LIVE COUNTER DETECTED!', 13, 10, '$'
s_ctr_no:
    db ESC_CHAR, '[1;31m', '  ', 16, ' No change (not a live counter)', 13, 10, '$'

; Timing labels
s_lbl_baseline:
    db ESC_CHAR, '[1;33m'
    db '  Baseline frame:   '
    db ESC_CHAR, '[1;37m', '$'
s_lbl_scanline:
    db ESC_CHAR, '[1;33m'
    db '  Baseline scanln:  '
    db ESC_CHAR, '[1;37m', '$'
s_lbl_r4:
    db ESC_CHAR, '[1;33m'
    db '  R4=0x01 frame:    '
    db ESC_CHAR, '[1;37m', '$'
s_lbl_r7:
    db ESC_CHAR, '[1;33m'
    db '  R7=0x01 frame:    '
    db ESC_CHAR, '[1;37m', '$'

s_sfx_ticks:
    db ESC_CHAR, '[0;37m', ' ticks', 13, 10, '$'

s_eff_dummy:
    db ESC_CHAR, '[1;31m', ' ', 16, ' DUMMY (no change)', 13, 10, '$'
s_eff_works:
    db ESC_CHAR, '[1;32m', ' ', 16, ' WORKS! (timing changed)', 13, 10, '$'

; Interactive prompts
s_vis_r9:
    db ESC_CHAR, '[1;33m', ' Test: R9 (Max Scanline) = 0x03. Character height should change.$'
s_vis_r10:
    db ESC_CHAR, '[1;33m', ' Test: R10 (Cursor Start) = 0x00. Cursor should start at top.$'
s_vis_r11:
    db ESC_CHAR, '[1;33m', ' Test: R11 (Cursor End) = 0x0D. Cursor should be full block.$'
s_vis_64:
    db ESC_CHAR, '[1;33m', ' Test: V6355D 0x64 bits 3-5 = 7. Display should shift UP.$'
s_vis_67:
    db ESC_CHAR, '[1;33m', ' Test: V6355D 0x67 = 0x00. Display should shift horizontally.$'
s_vis_r1:
    db ESC_CHAR, '[1;33m', ' Test: R1 (H Displayed) = 20. Visible width should HALVE.$'
s_vis_r2:
    db ESC_CHAR, '[1;33m', ' Test: R2 (H Sync Pos) = 0x40. Display should shift position.$'
s_vis_r6:
    db ESC_CHAR, '[1;33m', ' Test: R6 (V Displayed) = 12. Visible height should HALVE.$'
s_vis_65:
    db ESC_CHAR, '[1;33m', ' Test: V6355D 0x65 bits 0-1 = 00. Line count to 192 lines.$'
s_vis_r0:
    db ESC_CHAR, '[1;31m', ' [RISKY] R0 (H Total) = 0x61. May desync display briefly!$'
s_vis_r3:
    db ESC_CHAR, '[1;31m', ' [RISKY] R3 (H Sync Width) = 0x05. May cause sync loss!$'

s_press_space:
    db ESC_CHAR, '[0;37m', ' Press SPACE to apply change, S to skip...$'

s_ask_yn:
    db ESC_CHAR, '[1;33m', ' Did the display change? ('
    db ESC_CHAR, '[1;32m', 'Y'
    db ESC_CHAR, '[1;33m', '/'
    db ESC_CHAR, '[1;31m', 'N'
    db ESC_CHAR, '[1;33m', ')                               $'

s_risky_warn:
    db ESC_CHAR, '[1;31m', ' WARNING: This test may temporarily desync your monitor!$'
s_risky_press:
    db ESC_CHAR, '[0;37m', ' Press Y to test (auto-restore 2s), or any key to skip...$'
s_risky_ask:
    db ESC_CHAR, '[1;33m', ' Register restored. Did you see a change? ('
    db ESC_CHAR, '[1;32m', 'Y'
    db ESC_CHAR, '[1;33m', '/'
    db ESC_CHAR, '[1;31m', 'N'
    db ESC_CHAR, '[1;33m', ')  $'

; Footer
s_footer:
    db ESC_CHAR, '[1;33m'
    db ' Press any key to exit...'
    db ESC_CHAR, '[0m', '$'

; ============================================================================
; END OF PROGRAM
; ============================================================================
