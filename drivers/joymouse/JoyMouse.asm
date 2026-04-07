;*****************************************************************************
;*                .-= JOYMOUSE PC1 - Joystick to Mouse Driver =-.           *
;* INT 33h mouse emulation using Atari joystick on Olivetti Prodest PC1     *
;* Based on MOUSE-PC1 driver by Simone Riminucci (C) 2016                   *
;* Joystick adaptation by Retro Erik - 2026                                 *
;*                                                                          *
;* Connects an Atari-style digital joystick to the PC1 DE-9 mouse port      *
;* (with ENA pin 9 floating = joystick mode) and emulates INT 33h mouse     *
;* movements. Joystick directions move the cursor, fire = left button.      *
;*                                                                          *
;* Port 0x201 button bits (directly readable, active LOW):                  *
;*   Bit 4 = Button 1 (Fire / Left mouse button)                           *
;*   Bit 5 = Button 2 (2nd button / Right mouse button)                    *
;*                                                                          *
;* Joystick axes: After OUT to 0x201, digital switches discharge the RC     *
;* circuit near-instantly. We trigger, do a short delay, then read:         *
;*   Bit 0 = Axis 1 (Right: 0=pressed)                                     *
;*   Bit 1 = Axis 2 (Left:  0=pressed) -- actual mapping may vary          *
;*   Bit 2 = Axis 3 (Down:  0=pressed)                                     *
;*   Bit 3 = Axis 4 (Up:    0=pressed)                                     *
;*                                                                          *
;* NOTE: Axis-to-direction mapping may need adjustment on real hardware.    *
;*       Use /S parameter to swap X/Y axes if needed.                       *
;*                                                                          *
;* Compile with NASM: nasm -f bin -o joymouse.com JoyMouse.asm              *
;* Hardware cursor using YAMAHA V6355D sprite registers!                    *
;*****************************************************************************

CPU 186

BIOS_DATA_SEG   EQU 40h
driverversion   equ 303h

%include "../mouse/constant.inc"

;============================================================================
; NEC V40 specific opcodes (not recognized by NASM)
;============================================================================
%macro TEST1 2
        %ifn %2=CL
           %error "Only CL as second parameter"
        %endif
        db 0Fh
        %if %1=AL
          db 10h
          db 0C0h
        %elif %1=AX
          db 11h
          db 0C0h
        %else
          %error "Invalid Parameter"
        %endif
%endmacro

%macro SET1 2
        %ifn %2=CL
           %error "Only CL as second parameter"
        %endif
        db 0Fh
        %if %1=AL
          db 14h
          db 0C0h
        %elif %1=AH
          db 14h
          db 0C4h
        %elif %1=AX
          db 15h
          db 0C0h
        %else
          %error "Invalid Parameter"
        %endif
%endmacro

;============================================================================
; Program header
;============================================================================
        ORG     100h
        jmp     start

;============================================================================
; Resident data
;============================================================================
cmdlineflags    db 0

Old_INT08       dd 0
Old_INT09       dd 0
Old_INT09_MONK  dd 0
Already_in_user db 0
Cursor_Flag     db 0FFh
MIN_HRange      dw 0
MAX_HRange      dw 639
MIN_VRange      dw 0
MAX_VRange      dw 199
Hor_Ratio       dw 8
Vert_Ratio      dw 8
X_Mult_Ratio    dw 8
Y_Mult_Ratio    dw 8
CenterX         dw 15
CenterY         dw 15
H_Mickey_Count  dw 0
V_Mickey_Count  dw 0
Max_speed_D2    dw 2
Max_Speed_D     dw 35h
Button_Status   dw 0
LB_Count_press          dw 0
LB_PosX_last_press      dw 0
LB_PosY_last_press      dw 0
LB_Count_releases       dw 0
LB_PosX_last_release    dw 0
LB_PosY_last_release    dw 0
RB_Count_press          dw 0
RB_PosX_last_press      dw 0
RB_PosY_last_press      dw 0
RB_Count_releases       dw 0
RB_PosX_last_release    dw 0
RB_PosY_last_release    dw 0
shift_X_Pos             db 1
shift_ratioX            db 0
shift_ratioY            db 0
MouseX_Sum              dw 320
MouseY_Sum              dw 100
Cursor_attribute        db 0F0h
Last_mask               db 0
User_Event_Mask         db 0
Event_Handler_Addr      dd 63620000h
ORG_AX          dw 0
ORG_BX          dw 0
ORG_CX          dw 0
ORG_DX          dw 0
ORG_DI          dw 0
ORG_SI          dw 0
ORG_ES          dw 0

; Joystick-specific data
joy_speed       dw 3            ; pixels per tick (adjustable with /1 /2 /3)
joy_accel_count db 0            ; ticks joystick held in same direction
joy_accel_thresh db 8           ; ticks before acceleration kicks in
joy_last_dir    db 0            ; last direction bits for acceleration
joy_swapxy      db 0            ; nonzero = swap X/Y axes

;--- Cursor shape (arrow pointer) ---
screenmask      dw 0011111111111111b
                dw 0001111111111111b
                dw 0000111111111111b
                dw 0000011111111111b
                dw 0000001111111111b
                dw 0000000111111111b
                dw 0000000011111111b
                dw 0000000001111111b
                dw 0000000000111111b
                dw 0000000000011111b
                dw 0000000000001111b
                dw 0000000011111111b
                dw 0001000011111111b
                dw 0111100001111111b
                dw 1111100001111111b
                dw 1111110001111111b

cursormask      dw 0000000000000000b
                dw 0100000000000000b
                dw 0110000000000000b
                dw 0111000000000000b
                dw 0111100000000000b
                dw 0111110000000000b
                dw 0111111000000000b
                dw 0111111100000000b
                dw 0111111110000000b
                dw 0111111111000000b
                dw 0111111000000000b
                dw 0100011000000000b
                dw 0000011000000000b
                dw 0000001100000000b
                dw 0000001100000000b
                dw 0000000000000000b

;--- INT 33h function dispatch table ---
Int33_sub_index dw Fun_00       ; 00 - Reset/Query
                dw Fun_01       ; 01 - Show Pointer
                dw Fun_02       ; 02 - Hide Pointer
                dw Fun_03       ; 03 - Query Position & Buttons
                dw Fun_04       ; 04 - Move Pointer
                dw Fun_05       ; 05 - Query Button Press Count
                dw Fun_06       ; 06 - Query Button Release Count
                dw Fun_07       ; 07 - Set Horizontal Range
                dw Fun_08       ; 08 - Set Vertical Range
                dw Fun_09       ; 09 - Set Graphic Pointer Shape
                dw Fun_0A       ; 0A - Set Text Pointer / Cursor Attribute
                dw Fun_0B       ; 0B - Query Last Motion Distance
                dw Fun_0C       ; 0C - Set Event Handler
                dw no_fun       ; 0D - Enable Light Pen
                dw no_fun       ; 0E - Disable Light Pen
                dw Fun_0F       ; 0F - Set Pointer Speed
                dw no_fun       ; 10 - Set Exclusion Area
                dw Fun_11       ; 11 - Get Number of Buttons
                dw no_fun       ; 12
                dw Fun_13       ; 13 - Set Max Speed Doubling
                dw Fun_14       ; 14 - Exchange Event Handler

;============================================================================
; INT 08h handler - Timer tick (~18.2 Hz)
; Instead of reading V6355D CRTC mouse counters, we poll the joystick
;============================================================================
INT_08:
        pusha
        push    ds

        push    cs
        pop     ds
        mov     byte [Last_mask], 0
        call    read_joystick           ; <-- replaces read_M_delta_coord
        cmp     bl, 00h
        jz      .go3
        cmp     byte [Cursor_Flag], 0
        jnz     .go2
.update_cur:
        cli
        mov     dx, 3DDh
        mov     al, 60h+80h
        out     dx, al
        inc     dx
        mov     ax, [MouseX_Sum]
        shr     ax, 1
        add     ax, [CenterX]
        xchg    al, ah
        out     dx, al
        xchg    al, ah
        out     dx, al
        mov     ax, [MouseY_Sum]
        add     ax, [CenterY]
        xchg    al, ah
        out     dx, al
        xchg    al, ah
        out     dx, al
        sti
        cmp     bl, 0Fh
        jz      .return_to_fun04
.go2:   or      byte [Last_mask], 1

        push    es
        call    Call_User
        pop     es

.go3:   pop     ds
        popa
        jmp     far [cs:Old_INT08]

.return_to_fun04:
        pop     ds
        popa
        jmp     far [cs:Old_INT08]

;============================================================================
; read_joystick - Read Atari joystick from port 0x201
;
; Digital joystick: switches short RC to ground immediately.
; After triggering (OUT 0x201), we do a tiny delay, then IN.
; Pressed directions will have bits 0-3 = 0 (discharged instantly).
; Centered/released directions stay 1 (capacitor still charging).
;
; Bit 0 = Axis 1 channel (typically joystick X+, i.e. Right)
; Bit 1 = Axis 2 channel (typically joystick Y+, i.e. Down)
; Bit 2 = Axis 3 channel (typically joystick X-, i.e. Left) -- if 4-axis
; Bit 3 = Axis 4 channel (typically joystick Y-, i.e. Up)   -- if 4-axis
;
; For a 2-axis Atari stick on the standard PC game port:
;   Bit 0 = X axis (0 if pushed right, stays 1 briefly then 0 if centered,
;           but for digital: 0 = active switch, timing is near-instant)
;   Bit 1 = Y axis
;
; However on the PC1 with the DE-9 port in joystick mode, directions are 
; directly read as switch states. We read buttons (bits 4-5) directly.
;
; Output: BL = 0 if no movement, FFh if something changed
;============================================================================
read_joystick:
        mov     bl, 0                   ; BL = "was moved?" flag

        ;--- Read buttons first (active LOW, directly readable) ---
        mov     dx, 201h
        in      al, dx                  ; read port 201h
        mov     ah, al                  ; save full state in AH

        ;--- Extract button state: bit4=btn1(left), bit5=btn2(right) ---
        ;--- Convert to our format: bit0=left, bit1=right ---
        mov     cl, al
        not     cl                      ; invert: now 1=pressed
        shr     cl, 4                   ; shift bits 4,5 -> bits 0,1
        and     cl, 3                   ; mask to 2 buttons
        xor     ch, ch
        mov     [Button_Status], cx

        ;--- Trigger RC timing for axes ---
        out     dx, al                  ; any write triggers capacitor charge

        ;--- Short delay: digital switches discharge almost instantly ---
        ;--- but we need a few cycles for the port to settle ---
        in      al, dx                  ; waste a few cycles
        in      al, dx
        in      al, dx
        in      al, dx

        ;--- Now read axis state ---
        in      al, dx                  ; bits 0-3: 0 = switch closed (direction pressed)

        ;--- Check if we need to swap X/Y ---
        cmp     byte [joy_swapxy], 0
        jz      .no_swap
        ; Swap bits 0,1 with bits 2,3 by rotating
        mov     cl, al
        and     al, 0F0h               ; preserve upper bits
        mov     ch, cl
        and     ch, 03h                 ; original bits 0-1
        shl     ch, 2                   ; -> bits 2-3
        or      al, ch
        and     cl, 0Ch                 ; original bits 2-3 
        shr     cl, 2                   ; -> bits 0-1
        or      al, cl
.no_swap:
        not     al                      ; invert: now 1 = direction pressed
        and     al, 0Fh                 ; keep only direction bits

        ;--- Acceleration logic ---
        cmp     al, [joy_last_dir]
        je      .same_dir
        mov     [joy_last_dir], al
        mov     byte [joy_accel_count], 0
        jmp     .calc_speed
.same_dir:
        cmp     byte [joy_accel_count], 255
        je      .calc_speed
        inc     byte [joy_accel_count]

.calc_speed:
        ;--- Determine speed: base speed, doubled if holding long enough ---
        mov     si, [joy_speed]         ; base speed (1-5 pixels per tick)
        cmp     byte [joy_accel_count], 0
        jz      .no_accel_yet
        mov     cl, [joy_accel_count]
        cmp     cl, [joy_accel_thresh]
        jb      .no_accel_yet
        shl     si, 1                   ; double speed after threshold
        cmp     cl, 30                  ; even faster after ~1.6 seconds
        jb      .no_accel_yet
        shl     si, 1                   ; 4x speed
.no_accel_yet:

        ;--- Apply directions ---
        ; AL bit layout after inversion: bit0=Right, bit1=Down, bit2=Left, bit3=Up
        ; (This is the standard IBM game port axis mapping)
        ; NOTE: On actual PC1 hardware the mapping may be different.
        ;       The /S switch swaps axes if needed.

        test    al, al
        jz      .no_movement

        ;--- AL has direction bits: bit0=Right, bit1=Down, bit2=Left, bit3=Up ---
        mov     cl, al                  ; save direction bits in CL

        ;--- Horizontal: Right (bit 0) and Left (bit 2) ---
        mov     ax, 0                   ; delta X
        test    cl, 01h                 ; Right?
        jz      .no_right
        add     ax, si
.no_right:
        test    cl, 04h                 ; Left?
        jz      .no_left
        sub     ax, si
.no_left:
        or      ax, ax
        jz      .skip_x
        add     [H_Mickey_Count], ax
        add     ax, [MouseX_Sum]
        call    Verify_in_HRange
        mov     [MouseX_Sum], ax
        dec     bx                      ; BL = FFh = something moved
.skip_x:

        ;--- Vertical: Down (bit 1) and Up (bit 3) ---
        mov     ax, 0
        test    cl, 02h                 ; Down?
        jz      .no_down
        add     ax, si
.no_down:
        test    cl, 08h                 ; Up?
        jz      .no_up
        sub     ax, si
.no_up:
        or      ax, ax
        jz      .skip_y
        add     [V_Mickey_Count], ax
        add     ax, [MouseY_Sum]
        call    Verify_in_VRange
        mov     [MouseY_Sum], ax
        dec     bx
.skip_y:
        jmp     .check_buttons

.no_movement:
        mov     byte [joy_accel_count], 0
        mov     byte [joy_last_dir], 0

.check_buttons:
        ;--- Check if button state changed since last time ---
        ; Button changes are handled in a simplified way here:
        ; The full button press/release tracking is done by checking
        ; Button_Status which we set at the start of this routine.
        ; We just need to flag if the cursor should be updated.

.done:  ret

;============================================================================
; INT 09h handler - Keyboard (same as original mouse driver)
;============================================================================
INT_09bis:      push    ax
                call    Has_been_pressed_a_Mkey
                or      al, al
                jnz     INT_09.pressed
                pop     ax
                jmp     far [cs:Old_INT09_MONK]

INT_09:         push    ax
                call    Has_been_pressed_a_Mkey
                or      al, al
                jz      GoTo_OldInt
.pressed:       pusha
                push    es
                push    ds
                push    cs
                pop     ds
                mov     ah, [Button_Status]     ; use joystick button state
                test    al, 4
                jnz     short .loc_DE6
                test    al, 80h
                jnz     short .loc_DE0
                or      ah, 2
                jmp     short .loc_DF3
.loc_DE0:       and     ah, 1
                jmp     short .loc_DF3
.loc_DE6:       test    al, 80h
                jnz     short .loc_DF0
                or      ah, 1
                jmp     short .loc_DF3
.loc_DF0:       and     ah, 2
.loc_DF3:       and     ah, 3
                mov     [Button_Status], ah
                mov     al, ah
                mov     byte [Last_mask], 0
                call    Update_keyCount
                call    Call_User
                pop     ds
                pop     es
                popa
                pop     ax
                iret

GoTo_OldInt:    pop     ax
                jmp     far [cs:Old_INT09]

Has_been_pressed_a_Mkey:
                in      al, 64h
                and     al, 0D0h
                jz      short .loc_1C2C
                xor     ax, ax
                ret
.loc_1C2C:      in      al, 60h
                mov     ah, al
                cli
                mov     al, 61h
                out     20h, al
                sti
                mov     al, ah
no_fun:         ret

no_user_fun:    retf

;============================================================================
; Update button press/release counters
;============================================================================
Update_keyCount:
                mov     bx, [Button_Status]
                mov     byte [Button_Status], al
                xor     cx, cx
                xor     al, bl
                shr     al, 1
                rcr     ch, 1
                shr     ah, 1
                rcl     cl, 1
                shr     ch, cl
                mov     cl, 0
                shr     ah, 1
                cmc
                rcl     cl, 1
                shr     ch, cl
                shr     al, 1
                rcr     ch, 1
                xor     cl, 1
                shr     ch, cl
                shr     ch, 4
                mov     dh, ch
                mov     dl, ch
                shl     dl, 1
                mov     si, [MouseX_Sum]
                mov     di, [MouseY_Sum]
                xor     bx, bx
                mov     cl, 4
.next:          shr     dh, 1
                jc      .updatePR
.cont:          add     bx, LB_Count_releases-LB_Count_press
                loop    .next
                mov     byte [Last_mask], dl
                ret

.updatePR:      inc     word [LB_Count_press+bx]
                mov     word [LB_PosX_last_press+bx], si
                mov     word [LB_PosY_last_press+bx], di
                jmp     .cont

;============================================================================
; INT 33h entry point
;============================================================================
INT_33:
        sti
        call    Call_Subfun
        iret

;============================================================================
; INT 09 MONK (re-hook after someone steals INT 09)
;============================================================================
Install_INT09_MONK:
        cli
        mov     ax, 3509h
        int     21h
        mov     word [Old_INT09_MONK], bx
        mov     word [Old_INT09_MONK+2], es
        mov     dx, INT_09bis
        mov     ax, 2509h
        int     21h
        sti
        ret

Check_INT09_MONK:
        xor     ax, ax
        mov     es, ax
        mov     ax, cs
        cmp     word [ES:09h*4+2], ax
        je      .allok
        call    Install_INT09_MONK
.allok: ret

;============================================================================
; Reset pointer and variables
;============================================================================
Reset_pointer_and_var:
        xor     ax, ax
        mov     bx, 8
        mov     word [MouseX_Sum], 320
        mov     word [MouseY_Sum], 100
        mov     word [Hor_Ratio], bx
        mov     word [Vert_Ratio], bx
        mov     byte [Already_in_user], al
        mov     byte [User_Event_Mask], al
        mov     word [Event_Handler_Addr+2], cs
        mov     dx, no_user_fun
        mov     word [Event_Handler_Addr], dx
        mov     word [H_Mickey_Count], ax
        mov     word [V_Mickey_Count], ax
        mov     word [X_Mult_Ratio], bx
        mov     word [Y_Mult_Ratio], bx
        mov     byte [CenterX], 15
        mov     byte [CenterY], 15
        mov     byte [Max_speed_D2], 2
        mov     byte [Max_Speed_D], 35h
        mov     word [MIN_VRange], ax
        mov     word [MIN_HRange], ax
        mov     BYTE [shift_X_Pos], al
        ; Reset joystick state
        mov     byte [joy_accel_count], al
        mov     byte [joy_last_dir], al

        call    Check_INT09_MONK

        mov     ah, 0Fh
        int     10h
        mov     word [MAX_VRange], 199
        mov     word [MAX_HRange], 639
        cmp     al, 06h
        je      .cnt1
        mov     BYTE [shift_X_Pos], 1
.cnt1:  lea     si, [screenmask]
        call    Copy_cursor_shape
        call    TransMult
        ret

;============================================================================
; INT 33h Function 00 - Reset/Query Driver Presence
;============================================================================
Fun_00: mov     [Cursor_Flag], byte 0
        call    Fun_02
        call    Reset_pointer_and_var
        xor     ax, ax
        mov     byte [User_Event_Mask], al
        dec     ax                      ; AX = FFFFh = INSTALLED
        mov     [ORG_AX], ax
        mov     ax, 2                   ; 2 buttons
        mov     [ORG_BX], ax
        ret

;============================================================================
; Function 01 - Display Pointer
;============================================================================
Fun_01: cmp     byte [Cursor_Flag], 0
        jz      .end
        inc     byte [Cursor_Flag]
        jnz     .end
        mov     ah, byte [Cursor_attribute]
        mov     al, 68h+80h
        out     0DDh, AX
        jmp     adjust_cur
.end:   ret

;============================================================================
; Function 02 - Hide Pointer
;============================================================================
Fun_02: dec     byte [Cursor_Flag]
        mov     al, 68h+80h
        mov     ah, 0Fh                 ; cursor transparent
        out     0DDh, AX
        ret

;============================================================================
; Function 03 - Query Position & Buttons
;============================================================================
Fun_03: mov     ax, [Button_Status]
        mov     [ORG_BX], ax
        mov     ax, [MouseX_Sum]
        mov     [ORG_CX], ax
        mov     ax, [MouseY_Sum]
        mov     [ORG_DX], ax
        call    Check_INT09_MONK
        ret

;============================================================================
; Function 04 - Move Pointer
;============================================================================
Fun_04: mov     ax, dx
        call    Verify_in_VRange
        mov     bx, ax
        mov     ax, cx
        call    Verify_in_HRange
        mov     [MouseX_Sum], ax
        mov     [MouseY_Sum], bx
        cmp     byte [Cursor_Flag], 0
        jnz     endfun4
adjust_cur:
        mov     BL, 0Fh
        call    INT_08.update_cur
endfun4:
        ret

;============================================================================
; Function 05 - Query Button Pressed Count
;============================================================================
Fun_05: cmp     bx, 1
        ja      .end
        jb      .out
        mov     bx, RB_Count_press-LB_Count_press
.out:   xor     ax, ax
        xchg    ax, [LB_Count_press+BX]
        mov     [ORG_BX], ax
        mov     ax, [LB_PosX_last_press+BX]
        mov     [ORG_CX], ax
        mov     ax, [LB_PosY_last_press+BX]
        mov     [ORG_DX], ax
        mov     ax, [Button_Status]
        mov     [ORG_AX], ax
.end:   ret

;============================================================================
; Function 06 - Get Button Release Info
;============================================================================
Fun_06: cmp     bx, 1
        ja      Fun_05.end
        jb      .phase2
        mov     bx, RB_Count_press-LB_Count_press
.phase2:add     bx, LB_Count_releases-LB_Count_press
        jmp     Fun_05.out

;============================================================================
; Function 07 - Set Horizontal Range
;============================================================================
Fun_07: call    Invert
        cli
        mov     [MIN_HRange], cx
        mov     [MAX_HRange], dx
        mov     ax, [MouseX_Sum]
        call    Verify_in_HRange
        mov     [MouseX_Sum], ax
        jmp     adjust_cur

;============================================================================
; Function 08 - Set Vertical Range
;============================================================================
Fun_08: call    Invert
        cli
        mov     [MIN_VRange], cx
        mov     [MAX_VRange], dx
        mov     ax, [MouseY_Sum]
        call    Verify_in_VRange
        mov     [MouseY_Sum], ax
        jmp     adjust_cur

;============================================================================
; Function 09 - Set Graphic Pointer Shape
;============================================================================
Fun_09: cli
        neg     bx
        add     bx, 16
        mov     [CenterX], bx
        neg     cx
        add     cx, 16
        mov     [CenterY], cx
        push    ds
        mov     si, dx
        mov     ax, [ORG_ES]
        mov     ds, ax
        pop     es
        call    Copy_cursor_shape
        push    es
        pop     ds
        sti
        jmp     adjust_cur

;============================================================================
; Copy cursor shape (32 words) to V6355D sprite RAM
;============================================================================
Copy_cursor_shape:
        mov     dx, 0DDh
        xor     ax, ax
        out     dx, al
        inc     dx
        cld
        mov     cx, 20h
.copy_next:
        lodsw
        cmp     cx, 10h
        jbe     .ok
        not     ax
.ok:    xchg    ah, al
        out     dx, al
        xchg    ah, al
        out     dx, al
        loop    .copy_next
        ret

;============================================================================
; Function 0A - Set Cursor Attribute (PC1 specific)
;============================================================================
Fun_0A: cmp     bl, 0FFh
        jnz     .end
        mov     byte [Cursor_attribute], cl
        mov     al, 64h+80h
        out     0DDh, al
        xchg    al, dl
        or      al, 110b
        out     0DEh, al
        dec     byte [Cursor_Flag]
        jmp     Fun_01
.end:   ret

;============================================================================
; Function 0B - Query Last Motion Distance
;============================================================================
Fun_0B: cli
        xor     ax, ax
        xchg    ax, [H_Mickey_Count]
        mov     [ORG_CX], ax
        xor     ax, ax
        xchg    ax, [V_Mickey_Count]
        mov     [ORG_DX], ax
        ret

;============================================================================
; Function 0C - Set Event Handler
;============================================================================
Fun_0C: cli
        mov     word [Event_Handler_Addr], dx
        mov     dx, [ORG_ES]
        mov     word [Event_Handler_Addr+2], dx
        and     cl, 7Fh
        mov     byte [User_Event_Mask], cl
        sti
        ret

;============================================================================
; Function 0F - Set Pointer Speed
;============================================================================
Fun_0F: xchg    ax, cx
        cmp     ax, word 0000h
        je      .skipHor
        mov     [Hor_Ratio], ax
.skipHor:
        xchg    ax, dx
        cmp     ax, word 0000h
        je      .end
        mov     [Vert_Ratio], ax
        jmp     TransMult
.end:   ret

;============================================================================
; Function 11 - Get Driver Type  
;============================================================================
Fun_11: mov     ax, 33h                 ; Special PC1 driver
        mov     [ORG_AX], ax
        mov     al, 2
        mov     [ORG_BX], ax
        ret

;============================================================================
; Function 13 - Set Max Speed Doubling
;============================================================================
Fun_13: xchg    ax, dx
        mov     [Max_Speed_D], ax
        add     ax, 11h
        mov     bx, 23h
        xor     dx, dx
        div     bx
        mov     [Max_speed_D2], ax
        ret

;============================================================================
; Function 14 - Exchange Event Handler
;============================================================================
Fun_14: cli
        mov     ax, word [Event_Handler_Addr]
        mov     [ORG_DX], ax
        mov     word [Event_Handler_Addr], dx
        mov     dx, [ORG_ES]
        mov     ax, word [Event_Handler_Addr+2]
        mov     [ORG_ES], ax
        mov     word [Event_Handler_Addr+2], dx
        xor     ax, ax
        mov     al, byte [User_Event_Mask]
        mov     [ORG_CX], ax
        and     cl, 7Fh
        mov     byte [User_Event_Mask], cl
        sti
        ret

;============================================================================
; Transform ratio to shift count
;============================================================================
TransMult:
        mov     al, byte [shift_X_Pos]
        mov     byte [shift_ratioX], al
        mov     ax, [X_Mult_Ratio]
        xor     dx, dx
        div     word [Hor_Ratio]
.redo1: shr     AX, 1
        cmp     ax, 0
        je      .ok1
        inc     byte [shift_ratioX]
        jmp     .redo1
.ok1:   mov     byte [shift_ratioY], 0
        mov     ax, [Y_Mult_Ratio]
        xor     dx, dx
        div     word [Vert_Ratio]
.redo2: shr     AX, 1
        cmp     ax, 0
        je      .ok2
        inc     byte [shift_ratioY]
        jmp     .redo2
.ok2:   ret

;============================================================================
; Function 1A - Set Mouse Sensitivity
;============================================================================
Fun_1A: shr     bx, 2
        mov     [X_Mult_Ratio], bx
        shr     cx, 2
        mov     [Y_Mult_Ratio], cx
        call    TransMult
        jmp     Fun_13

;============================================================================
; Function 1B - Query Mouse Sensitivity
;============================================================================
Fun_1B: mov     ax, [X_Mult_Ratio]
        shl     ax, 2
        mov     [ORG_BX], ax
        mov     ax, [Y_Mult_Ratio]
        shl     ax, 2
        mov     [ORG_CX], ax
        mov     ax, [Max_Speed_D]
        mov     [ORG_DX], ax
        ret

Fun_23: mov     word [ORG_BX], 08h
        ret

Fun_24: mov     word [ORG_BX], driverversion
        mov     word [ORG_CX], 0309h
        ret

;============================================================================
; INT 33h subfunction dispatcher
;============================================================================
Call_Subfun:
        push    bp
        push    ds
        push    cs
        pop     ds
        mov     [ORG_AX], ax
        mov     [ORG_BX], bx
        mov     [ORG_CX], cx
        mov     [ORG_DX], dx
        mov     [ORG_DI], di
        mov     [ORG_SI], si
        mov     [ORG_ES], es
        push    ds
        pop     es
        cmp     ax, 14h
        ja      short OtherFuns
        push    si
        mov     si, ax
        shl     si, 1
        mov     ax, [Int33_sub_index+si]
        pop     si
call_it:
        call    ax
        jmp     short loc_6F5

Fun_4D: mov     word [ORG_DI], Copyright1983
        mov     [ORG_ES], cs
        ret

Fun_6D: jnz     short loc_6F5
        mov     [ORG_DI], word magicnumber
        mov     [ORG_ES], cs
        ret

execute_other:
        shl     bx, 1
        call    [CS:other_address+bX]
        jmp     short loc_6F5

OtherFuns:
        mov     bx, 4
.more:  cmp     al, [other_num+bx]
        jz      execute_other
        dec     bx
        jnz     .more

loc_6F5:
        mov     ax, [ORG_ES]
        mov     es, ax
        mov     si, [ORG_SI]
        mov     di, [ORG_DI]
        mov     dx, [ORG_DX]
        mov     cx, [ORG_CX]
        mov     bx, [ORG_BX]
        mov     ax, [ORG_AX]
        pop     ds
        pop     bp
        ret

other_address:  dw Fun_1A, Fun_1B, Fun_23, Fun_24, Fun_4D, Fun_6D
other_num       db 1Ah, 1Bh, 23h, 24h, 4Dh, 6Dh

;============================================================================
; Call user event handler
;============================================================================
Call_User:
        cmp     byte [Already_in_user], 0FFh
        jz      .endend
        mov     byte [Already_in_user], 0FFh
        xor     ax, ax
        mov     al, byte [Last_mask]
        and     al, byte [User_Event_Mask]
        mov     bp, Event_Handler_Addr
        jz      .no_sub
        call    CALL_FUN_AT_BP
.no_sub:
        mov     byte [Already_in_user], 0
.endend:ret

CALL_FUN_AT_BP:
        mov     bx, [Button_Status]
        mov     cx, [MouseX_Sum]
        mov     dx, [MouseY_Sum]
        mov     si, word [H_Mickey_Count]
        mov     di, word [V_Mickey_Count]
        sti
        call    far [cs:bp]
        PUSH    CS
        POP     DS
        ret

;============================================================================
; Utility routines
;============================================================================
Invert: cmp     cx, dx
        jl      short .ret
        xchg    cx, dx
.ret:   ret

Verify_in_VRange:
        mov     dx, [CS:MIN_VRange]
        cmp     ax, dx
        jl      short .set
        mov     dx, [CS:MAX_VRange]
        cmp     ax, dx
        jle     short .skip
.set:   mov     ax, dx
.skip:  ret

Verify_in_HRange:
        mov     dx, [CS:MIN_HRange]
        cmp     ax, dx
        jl      short .set
        mov     dx, [CS:MAX_HRange]
        cmp     ax, dx
        jle     short .skip
.set:   mov     ax, dx
.skip:  ret

;============================================================================
; Constants
;============================================================================
Copyright1983 db 'Copyright 1983 Microsoft ***'
magicnumber db 55h, 64h

; ========================== END OF RESIDENT PART =========================
notresident:

db '*** This is a PC1 joystick-mouse driver, but some software expect the upper string!'
welcome DB  'JOYMOUSE-PC1 v1.0 - Joystick to Mouse Driver',0Dh,0Ah
        DB  'Based on MOUSE-PC1 by Simone Riminucci (C) 2016',0Dh,0Ah
        DB  'Joystick adaptation by Retro Erik - 2026',0Dh,0Ah,'$'
already DB  'A mouse driver is already installed',0Dh,0Ah,'$'
ForceIn db  'F: Installing over existing driver',0Dh,0Ah,'$'
notPC1  db  'This driver works only on OLIVETTI PRODEST PC1.',0Dh,0Ah,'$'
joyinfo DB  'Joystick mode: directions=cursor, fire=left button',0Dh,0Ah,'$'
speedmsg DB 'Speed: $'
EGAVGA  DB  'EGA/VGA Patch installed',0Dh,0Ah,'$'

helpmsg db  0Ah,0Dh,"JOYMOUSE - Atari joystick to INT 33h mouse emulation",0Ah,0Dh
        db  0Ah,0Dh
        db  "Parameters:",0Ah,0Dh
        db  "  /I - Do not check if on Olivetti Prodest PC1",0Ah,0Dh
        db  "  /M - Show cursor immediately",0Ah,0Dh
        db  "  /F - Force installation over existing driver",0Ah,0Dh
        db  "  /E - Force EGA/VGA Patch",0Ah,0Dh
        db  "  /S - Swap X/Y joystick axes",0Ah,0Dh
        db  "  /1 - Slow cursor speed",0Ah,0Dh
        db  "  /2 - Medium cursor speed (default)",0Ah,0Dh
        db  "  /3 - Fast cursor speed",0Ah,0Dh
        db  "$"

Equipment_Addr  dw 0A1h

;============================================================================
; Startup code (not resident)
;============================================================================
start:
        push    cs
        pop     ds
        lea     dx, [welcome]
        mov     ah, 9
        int     21h

        call    process_cmdline

        test    byte [cmdlineflags], help
        jnz     display_help

        test    byte [cmdlineflags], nocheck
        jnz     .skipcheck

        call    check_for_PC1
        or      ax, ax
        jz      .not_PC1

.skipcheck:
        mov     AX, 0000h
        int     33h
        cmp     AX, 0FFFFh
        jne     .cont0
        test    byte [cmdlineflags], forceinst
        jz      .terminate
        lea     dx, [ForceIn]
        mov     ah, 9
        int     21h

.cont0:
        cli
        call    Install_INT08
        call    Install_INT09
        call    Install_INT33
        call    reset_V6355D
        call    Reset_pointer_and_var

        ; Print joystick info
        lea     dx, [joyinfo]
        mov     ah, 9
        int     21h

        ; Print speed setting
        lea     dx, [speedmsg]
        mov     ah, 9
        int     21h
        mov     ax, [joy_speed]
        add     al, '0'
        mov     dl, al
        mov     ah, 2
        int     21h
        mov     dl, 0Dh
        int     21h
        mov     dl, 0Ah
        int     21h

        test    byte [cmdlineflags], showcurs
        jz      .skipshow
        call    Fun_01
.skipshow:
        STI

        ; Free environment, go TSR
        mov     ah, 51h
        int     21h
        mov     es, bx
        mov     es, [es:2Ch]
        mov     ah, 49h
        int     21h

        mov     dx, notresident
        mov     cl, 4
        shr     dx, cl
        inc     dx
        MOV     AX, 3100h
        INT     21h

.terminate:
        lea     dx, [already]
        mov     ah, 9
        int     21h
.error:
        MOV     AX, 4C01h
        INT     21h

.not_PC1:
        lea     dx, [notPC1]
        mov     ah, 9
        int     21h
        jmp     .error

;============================================================================
; V6355D reset (sprite engine init)
;============================================================================
reset_V6355D:
        cli
        push    ds
        mov     bx, [Equipment_Addr]
        mov     ax, BIOS_DATA_SEG
        mov     ds, ax
        mov     al, [bx]
        pop     ds
        test    byte [cmdlineflags], forceEGA
        jnz     .force
        test    al, 1
        jz      .cont
.force: and     al, 0FEh
        or      byte [cmdlineflags], forceEGA
        out     68h, al
        in      al, 0D1h
        cmp     al, 0FFh
        jnz     .wmsg
        test    byte [cmdlineflags], nocheck
        jz      start.not_PC1
.wmsg:  lea     dx, [EGAVGA]
        mov     ah, 9
        int     21h
.cont:  mov     dx, 3DDh
        mov     al, 64h+80h
        out     dx, al
        inc     dx
        mov     al, 6h
        out     dx, al
        sti
        ret

;============================================================================
; PC1 detection
;============================================================================
check_for_PC1:
PC1_Equipment_Addr      EQU 89h
PC1HD_Equipment_Addr    EQU 0A1h
        push    bx
        push    ds
        mov     ax, 0F000h
        mov     ds, ax
        mov     bx, 0FFFDh
        mov     ax, [bx]
        pop     ds
        mov     bl, PC1HD_Equipment_Addr
        cmp     ax, 0FE44h
        jz      short .pc1dd
        cmp     ax, 0FE49h
        jz      short .found
        cmp     ax, 0FE4Ah
        jnz     short .notfound
.pc1dd: mov     bl, PC1_Equipment_Addr
.found: mov     ax, 0FFh
        jmp     short .done
.notfound:
        mov     ax, 0
.done:  mov     [Equipment_Addr], bl
        pop     bx
        ret

;============================================================================
; Command line processing
;============================================================================
help            EQU     BIT0
nocheck         EQU     BIT1
showcurs        EQU     BIT2
forceinst       EQU     BIT3
forceEGA        EQU     BIT4
swapxy_flag     EQU     BIT5

process_cmdline:
        push    ds
        push    bx
        push    si
        mov     ah, 51h
        int     21h
        mov     ds, bx
        mov     cx, bx
        mov     si, 80h
        mov     bh, 0
        mov     bl, byte [si]
        add     si, bx
        inc     si
        mov     byte [si], NULL
        mov     si, 81h

.cmdlineloop:
        mov     ds, cx
        lodsb
        push    cs
        pop     ds
        cmp     al, " "
        jz      .cmdlineloop
        cmp     al, NULL
        jz      .exitpc
        cmp     al, "-"
        jz      .checkflags
        cmp     al, "/"
        jz      .checkflags
        or      byte [cmdlineflags], help
        jmp     .cmdlineloop

.exitpc:
        pop     si
        pop     bx
        pop     ds
        ret

.checkflags:
        mov     ds, cx
        lodsb
        push    cs
        pop     ds
        cmp     al, " "
        jz      .cmdlineloop
        cmp     al, NULL
        jz      .exitpc
        cmp     al, "-"
        jz      .checkflags
        cmp     al, "/"
        jz      .checkflags
        call    ucase

        cmp     al, "?"
        jz      .sethelp
        cmp     al, "H"
        jz      .sethelp
        cmp     al, "I"
        jz      .setnocheck
        cmp     al, "M"
        jz      .setshowcurs
        cmp     al, "F"
        jz      .setforceinst
        cmp     al, "E"
        jz      .setforceEGA
        cmp     al, "S"
        jz      .setswapxy
        cmp     al, "1"
        jz      .setspeed1
        cmp     al, "2"
        jz      .setspeed2
        cmp     al, "3"
        jz      .setspeed3
        jmp     .cmdlineloop

.sethelp:
        or      byte [cmdlineflags], help
        jmp     .checkflags
.setnocheck:
        or      byte [cmdlineflags], nocheck
        jmp     .checkflags
.setshowcurs:
        or      byte [cmdlineflags], showcurs
        jmp     .checkflags
.setforceinst:
        or      byte [cmdlineflags], forceinst
        jmp     .checkflags
.setforceEGA:
        or      byte [cmdlineflags], forceEGA
        jmp     .checkflags
.setswapxy:
        mov     byte [joy_swapxy], 1
        jmp     .checkflags
.setspeed1:
        mov     word [joy_speed], 2
        jmp     .checkflags
.setspeed2:
        mov     word [joy_speed], 3
        jmp     .checkflags
.setspeed3:
        mov     word [joy_speed], 5
        jmp     .checkflags

ucase:
        pushf
        cmp     al, "a"
        jb      .noupper
        cmp     al, "z"
        ja      .noupper
        and     al, 5fh
.noupper:
        popf
        ret

;============================================================================
; Interrupt installation routines
;============================================================================
Install_INT08:
        cli
        mov     ax, 3508h
        int     21h
        mov     word [Old_INT08], bx
        mov     word [Old_INT08+2], es
        mov     dx, INT_08
        mov     ax, 2508h
        int     21h
        sti
        ret

Install_INT09:
        cli
        mov     ax, 3509h
        int     21h
        mov     word [Old_INT09], bx
        mov     word [Old_INT09+2], es
        mov     dx, INT_09
        mov     ax, 2509h
        int     21h
        sti
        ret

Install_INT33:
        cli
        lea     dx, [INT_33]
        mov     al, 33h
        mov     ah, 25h
        int     21h
        ret

;============================================================================
; Help display
;============================================================================
display_help:
        mov     ah, 9
        lea     dx, [helpmsg]
        int     21h
        mov     ax, 4c02h
        int     21h

END:
