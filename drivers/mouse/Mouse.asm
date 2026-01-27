;*****************************************************************************
;*	   		  .-= MOUSE PC1 Project =-.			     *
;* Int33h mouse hook for PC1 - NECV40 0.97 by Simone Riminucci (C) 2016	     *
;* Started: 29.11.2016							     *
;* Last updated 21.02.2017						     *
;* Tested on: OLIVETTI PRODEST PC1 (NEC V40 XT, 512/640kB)		     *
;* Translated to English and modified by Retro Erik - 2026		     *
;*	     								     *
;* MODIFIED VERSION: Hardware mouse detection skipped to allow loading	     *
;* the driver without a physical mouse connected. Original mouse hardware   *
;* detection code (set_mouse_keyb) is preserved and commented out.	     *
;*	     								     *
;* Only 1904 byte Resident!						     *
;* Compile with NASM (186 code)						     *
;* Hardware Mouse pointer using YAMAHA V6335D special registers !	     *
;*****************************************************************************

CPU 186 			;code compatability

;%define DEBUG
;%define CALL_OLD_INT33
BIOS_DATA_SEG	EQU 40h
driverversion	equ 303h	;imitated Microsoft driver version

%include "constant.inc"    ; Stuff that never changes.

%macro TEST1 2	;test 1 bit (n. CL). ZF is set if bit is zero.
		; out CY=0 V=0, ZF as needed
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

%macro SET1 2	;set 1 bit (n. CL). if ZF is set the bit go to zero.
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

;************** Program header ***************************************************

	ORG	100h		;use if compiling .COM file
	jmp	start

cmdlineflags	db 0

KeyStatus       db 0
Old_INT08       dd 0                    	;old INT
Old_INT09       dd 0  				;old INT

%ifdef CALL_OLD_INT33
Old_INT33       dd 0  				;old INT
%endif

Old_INT09_MONK	dd 0                    	;old INT
Already_in_user	db 0
Cursor_Flag	db 0FFh
MIN_HRange	dw 0
MAX_HRange	dw 639
MIN_VRange	dw 0
MAX_VRange	dw 199
Hor_Ratio	dw 8
Vert_Ratio	dw 8
X_Mult_Ratio    dw 8
Y_Mult_Ratio    dw 8 
CenterX		dw 15
CenterY		dw 15
H_Mickey_Count	dw 0
V_Mickey_Count	dw 0
Max_speed_D2    dw 2
Max_Speed_D     dw 35h
Button_Status		dw 0
LB_Count_press		dw 0
LB_PosX_last_press 	dw 0
LB_PosY_last_press 	dw 0
LB_Count_releases 	dw 0
LB_PosX_last_release 	dw 0
LB_PosY_last_release 	dw 0
RB_Count_press		dw 0
RB_PosX_last_press 	dw 0
RB_PosY_last_press 	dw 0
RB_Count_releases 	dw 0
RB_PosX_last_release 	dw 0
RB_PosY_last_release 	dw 0
shift_X_Pos		db 1
shift_ratioX		db 0
shift_ratioY		db 0
MouseX_Sum		dw 160
MouseY_Sum		dw 100
Cursor_attribute	db 0F0h
Last_mask		db 0	
User_Event_Mask		db 0	; Changed: Cursor pos,left press, left rel, right press, right rel
Event_Handler_Addr 	dd 63620000h
ORG_AX		dw 0
ORG_BX		dw 0
ORG_CX		dw 0
ORG_DX		dw 0
ORG_DI		dw 0
ORG_SI		dw 0
ORG_ES		dw 0

screenmask	dw 0011111111111111b	; 0
		dw 0001111111111111b	; 2
		dw 0000111111111111b	; 4
		dw 0000011111111111b	; 6
		dw 0000001111111111b	; 8
		dw 0000000111111111b	; 10
		dw 0000000011111111b	; 12
		dw 0000000001111111b	; 14
		dw 0000000000111111b	; 16
		dw 0000000000011111b	; 18
		dw 0000000000001111b	; 20
		dw 0000000011111111b	; 22
		dw 0001000011111111b	; 24
		dw 0111100001111111b	; 26
		dw 1111100001111111b	; 28
		dw 1111110001111111b	; 30	

cursormask	dw 0000000000000000b	; 0
		dw 0100000000000000b	; 2
		dw 0110000000000000b	; 4
		dw 0111000000000000b	; 6
		dw 0111100000000000b	; 8
		dw 0111110000000000b	; 10
		dw 0111111000000000b	; 12
		dw 0111111100000000b	; 14
		dw 0111111110000000b	; 16
		dw 0111111111000000b	; 18
		dw 0111111000000000b	; 20
		dw 0100011000000000b	; 22
		dw 0000011000000000b	; 24
		dw 0000001100000000b	; 26
		dw 0000001100000000b	; 28
		dw 0000000000000000b	; 30

Int33_sub_index	dw Fun_00	; Reset/Query driver Presence
		dw Fun_01	; Display Pointer
		dw Fun_02	; Hide Pointer
		dw Fun_03	; Query	Position & Buttons
		dw Fun_04	; Move Pointer
		dw Fun_05	; Query	Button Pressed count
					; BX = 0  left button
					;      1  right	button
					;
					;
					;	  on return:
					;	  BX = count of	button presses (0-32767), set to zero after call
					;	  CX = horizontal position at last press
					;	  DX = vertical	position at last press
					;	  AX = status:
					;		  |F-8|7|6|5|4|3|2|1|0|	 Button	Status
					;		    |  | | | | | | | `---- left	button (1 = pressed)
					;		    |  | | | | | | `----- right	button (1 = pressed)
					;		    `------------------- unused
		dw Fun_06	; Get Mouse Button Release Information
					;
					; BL=Button
					;
					; on return:
					;	  BX = count of	button releases	(0-32767), set to zero after call
					;	  CX = horizontal position at last release
					;	  DX = vertical	position at last release
					;	  AX = status
		dw Fun_07	; Set Horizontal range
					; CX = minimum H pos
					; DX = maximum H pos
		dw Fun_08	; Set Vertical range
					; CX = minimum V pos
					; DX = maximum V pos
		dw Fun_09	; Set graphic pointer shape
					; BX = horizontal hot spot (-16	to 16)
					; CX = vertical	hot spot (-16 to 16)
					; ES:DX	= pointer to screen and	cursor masks (16 byte bitmap)
		dw Fun_0A	; Set text pointer mask
		dw Fun_0B	; Query	last motion distance
		dw Fun_0C	; Set Event Handler
		dw no_fun	; Enable Light Pen Emulation
		dw no_fun	; Disable Light	Pen Emulation
		dw Fun_0F	; Set Pointer Speed
					; CX= Horizontal Ratio
					; DX= Vertical Ratio
		dw no_fun	; Set Exclusion	Area
		dw Fun_11	; GET NUMBER OF BUTTONS (special PC1 MOUSE procedure)
		dw no_fun
		dw Fun_13	; Set max for Speed Doubling
		dw Fun_14	; Exchange Event Handler

INT_08:
	pusha
	push	ds
	
	push 	cs		;variable segment!
	pop	ds
	mov     byte [Last_mask], 0
	call	read_M_delta_coord
	cmp	bl, 00h			; Value	00h or FFh = WAS MOVED!
	jz	go3
	cmp	byte [Cursor_Flag], 0	; default -1 (FF) not visible
					; visible=0
	jnz	go2
update_cur:
	cli
	mov	dx, 3DDh
	mov	al, 60h+80h		;sistemiamo solo lo sprite per ora...
	out	dx, al
	inc	dx
	mov     ax, [MouseX_Sum]
	shr	ax, 1
	add	ax, [CenterX]
	xchg	al, ah
	out	dx,al
	xchg	al, ah
	out	dx,al
	mov     ax, [MouseY_Sum]
	add	ax, [CenterY]
	xchg	al, ah
	out	dx,al
	xchg	al, ah
	out	dx,al
	sti
	cmp	bl, 0Fh			;me lo posso permettere perchè ho eliminato MOV mem,imm e CMP mem,imm -> CMP reg,imm
	jz	return_to_fun04		;adjust_cursor was on-going
go2:	or      byte [Last_mask], 1	; signal cursor movement to mask

	push    es
	call    Call_User	; there is X or Y movement!
	pop     es


go3:	pop	ds
	popa

	jmp	far [cs:Old_INT08]

%macro CHECK_THRES 0	;test for AX < [Max_speed_D2] in valore assoluto SENZA jump! (prima ce ne erano 2!!!)
		; AX shifted if |AX| > [Max_speed_D2] - CX Corrupted - speed optimized
	push	AX
	mov	CX, AX
	SHR	CX, 0Fh
	xor	AX, CX
	sub	AX, CX
	cmp	ax, [Max_speed_D2]	;carry set if Below [Max_speed_D2]
	cmc				;set if Higher of [Max_speed_D2]
	xor	cl, cl
	rcl	cl, 1		;cl=1 if carry set, 0 otherwise
	pop	ax		;tiriamo fuori il valore originale
	shl	ax, cl
%endmacro

read_M_delta_coord:		; (BL) lo uso come "was moved!"
	mov	BL, 0		; was moved = no
	mov	al, 10h		; load CTRC register
	out	0D4h,al
	in 	al, 0D5h
	cmp	al, 0
	je	rm2		; non è cambiata la "X"
	cbw                     ; Converts byte in AL to word Value in AX by extending sign of AL throughout register AH.
	neg 	ax		; negative! la X è sepre negativa, non so perchè
	dec	BX
	add     [H_Mickey_Count], ax		;here the mickey are NOT doubled!
	CHECK_THRES
	mov	CL, byte [shift_ratioX]		;shifting is better than IMUL/IDIV 50+34=84 Clock!!! 
	shl	ax, cl
	add     ax, [MouseX_Sum]
	call	Verify_in_HRange
	mov     [MouseX_Sum], ax
 rm2:	mov	al, 11h		; load CTRC register
	out	0D4h,al
	in 	al, 0D5h
	cbw
	cmp	ax, 0
	je	rm4
	dec	BX		; was moved = sì più corto ancora: 1 solo byte
	CHECK_THRES
 rm3:	add     [V_Mickey_Count], ax		;here the mickey are NOT shifted
	mov	CL, byte [shift_ratioY]		;shifting is better than IMUL/IDIV 50+34=84 Clock!!! 
	shl	ax, cl
	add     ax, [MouseY_Sum]
	call	Verify_in_VRange
	mov     [MouseY_Sum], ax
return_to_fun04: 	;sì è pulcioso, si risparmia un'altro byte se è meno lontano di 127 byte!
rm4:	ret

; NOTA: non uso pushf/popf perchè sono già salvate da INT09 procedure

INT_09bis:	push	ax		
		call	Has_been_pressed_a_Mkey
		or	al, al
		jnz	pressed
		pop	ax
		jmp	far [cs:Old_INT09_MONK]

INT_09:		push	ax
		call	Has_been_pressed_a_Mkey
		or	al, al
		jz	GoTo_OldInt
pressed:	pusha
		push	es
		push	ds
		push	cs	;RIGHT SEGMENT FOR DATA
		pop	ds
		;mov	bx, cs
		;mov	ds, bx
		;mov	es, bx
		mov	ah, [KeyStatus]
		test	al, 4
		jnz	short loc_DE6
		test	al, 80h
		jnz	short loc_DE0
		or	ah, 2
		jmp	short loc_DF3

loc_DE0:				
		and	ah, 1
		jmp	short loc_DF3

loc_DE6:	test	al, 80h
		jnz	short loc_DF0
		or	ah, 1
		jmp	short loc_DF3

loc_DF0:	and	ah, 2

loc_DF3:	and	ah, 3
		mov	[KeyStatus], ah
		mov	al, ah
		mov	byte [Last_mask], 0
		call    Update_keyCount
		call	Call_User
		pop	ds
		pop	es
		popa
		pop	ax	;pre-interrupt AX preserved!
		iret
; ÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄ

GoTo_OldInt:	pop	ax
		jmp	far [cs:Old_INT09]

; ÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛ S U B	R O U T	I N E ÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛ

;corrupt only AX!
Has_been_pressed_a_Mkey:
		in	al, 64h		; AT Keyboard controller 8042.
		and	al, 0D0h
		jz	short loc_1C2C
		xor	ax, ax
		ret

loc_1C2C:	in	al, 60h		; AT Keyboard controller 8042.
		mov	ah, al
		cli
		mov	al, 61h		; Ok, key processed!
		out	20h, al		; Interrupt controller,	8259A.
		sti
		mov	al, ah
no_fun:		ret

no_user_fun:	
		retf

; ÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛ S U B	R O U T	I N E ÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛ

Update_keyCount:		;AL= xxxxxLxR

		mov	bx, [Button_Status]
		mov	byte [Button_Status],	al

		xor	cx, cx	;azzeriamo  CH  CL - CH tiene i bit RRLL, CL il numero di shift da fare
		xor	al, bl
		shr	al, 1	;tasto SX: Carry =1 se cambiato =0 se non cambiato rispetto al vecchio status
		rcr	ch, 1	;inseriamo questo valore nel byte, al primo posto (+ significativo)
		shr	ah, 1	; Carry =1 se Pressed =0 se released
		rcl	cl, 1	; Qui CL diventa 1 se il tasto è pressed!
		shr	ch, cl	; Se pressed è il quarto bit da mettere a 1, quindi lo spingo ancora avanti tipo "01000000"
				; finito con il tasto sinistro = CH="LL000000"
		mov	cl, 0
		shr	ah, 1	; Carry =1 se Pressed =0 se released
		cmc		; Toggles (inverts) the Carry Flag
		rcl	cl, 1	; Qui CL diventa 1 se il tasto è released!
		shr	ch, cl	; aggiungiamo uno zero se è released -> "0LL0000", altrimenti invariato

		shr	al, 1	; tasto DX: Carry =1 se cambiato =0 se non cambiato rispetto al vecchio status
		rcr	ch, 1	; lo aggiungiamo al solito a sx: adesso abbiamo: "RLL00000" o "RRLL0000"
		xor	cl, 1	; Inverto CL: se era 0 diventa 1 e viceversa
		shr	ch, cl	; quindi aggiungiamo uno zero se è pressed -> "0RLL0000", altrimenti invariato

		shr	ch, 4   ;adesso abbiamo in CH i 4 bit 0000RRLL
		mov	dh, ch
		mov	dl, ch
		shl	dl, 1	;DL è pronto per andare in [last_mask] '000RRLL0'

		mov	si, [MouseX_Sum]
		mov	di, [MouseY_Sum]
		
		xor	bx, bx
		mov	cl, 4	;4 passaggi LB_Press, LB_Release, RB_Press, RB_Release
.next		shr	dh, 1
		jc	.updatePR
.cont		add	bx, LB_Count_releases-LB_Count_press
		loop	.next

		mov	byte [Last_mask], dl
		ret

.updatePR	inc	word [LB_Count_press+bx]
		mov	word [LB_PosX_last_press+bx], si
		mov	word [LB_PosY_last_press+bx], di
		jmp 	.cont

; ÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄ

INT_33:
%ifdef CALL_OLD_INT33
	or      ah, ah
	jnz     call_old33_if_exist
%endif
	sti        
	call    Call_Subfun
end_int33:	
	iret

call_old33_if_exist:
%ifdef CALL_OLD_INT33
	cmp     word [cs:Old_INT33+2], 0
	jz      end_int33
	jmp     far [cs:Old_INT33]
%endif

; ÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄ

Install_INT09_MONK:
	cli
	mov     ax, 3509h
	int     21h             ; DOS - 2+ - GET INTERRUPT VECTOR
				; AL = interrupt number
				; Return: ES:BX = value of interrupt vector
	mov     word [Old_INT09_MONK], bx
	mov     word [Old_INT09_MONK+2], es
	mov     dx, INT_09bis ; Int 09 (BIS) Entry Point
	mov     ax, 2509h
	int     21h             ; DOS - SET INTERRUPT VECTOR
				; AL = interrupt number
				; DS:DX = new vector to be used for specified interrupt
	sti
	ret

; ÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄ

;check for INT_09 hook!
Check_INT09_MONK:
		xor	ax, ax
		mov	es, ax
		mov	ax, cs
		cmp     word [ES:09h*4+2], ax	;check for int09 data segment
		je	allok
		;SEMPLIFICO: se non è nel segmento la cambio altrimenti lascio stare!
		;mov     ax, 3509h
		;int     21h             ; DOS - 2+ - GET INTERRUPT VECTOR
		;			; AL = interrupt number
		;			; Return: ES:BX = value of interrupt vector
		;mov	ax, cs
		;mov	cx, es
		;cmp     ax, cx		
		;jne	install_newint	;qualcuno (monkey?) ha cambiato l'int 09
		;mov	cx, INT_09
		;cmp     cx, bx
		;je	allok
		;mov	cx, INT_09bis
		;cmp     cx, bx
		;je	allok
install_newint:	call	Install_INT09_MONK
		
allok:		ret

; ÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛ S U B	R O U T	I N E ÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛ

Reset_pointer_and_var:
		xor	ax, ax				;mov mem, ax è più veloce e occupa meno di mov mem,0
		mov	bx, 8				;per i valori da 8
		mov     word [MouseX_Sum], 320
		mov     word [MouseY_Sum], 100
		mov     word [Hor_Ratio], bx
		mov     word [Vert_Ratio], bx
		mov     byte [Already_in_user], al
		mov	byte [User_Event_Mask], al
		mov	word [Event_Handler_Addr+2], cs
		mov	dx, no_user_fun
		mov	word [Event_Handler_Addr], dx
		mov     word [H_Mickey_Count], ax ; horizontal mickey count (-32768 to 32767)
		mov     word [V_Mickey_Count], ax
		mov     word [X_Mult_Ratio], bx
		mov     word [Y_Mult_Ratio], bx
		mov     byte [CenterX], 15
		mov     byte [CenterY], 15
		mov     byte [Max_speed_D2], 2
		mov     byte [Max_Speed_D], 35h

		mov     word [MIN_VRange], ax
		mov     word [MIN_HRange], ax
		mov	BYTE [shift_X_Pos], al

		;check for INT_09 hook!
		call	Check_INT09_MONK
		
		mov     ah, 0Fh
		int     10h             ; - VIDEO - GET CURRENT VIDEO MODE
					; Return: AH = number of columns on screen
					; AL = current video mode
					; BH = current active display page
		mov     word [MAX_VRange], 199
		mov     word [MAX_HRange], 639
		cmp	al, 06h
		je	cnt1
		mov	BYTE [shift_X_Pos], 1

cnt1:		lea     si, [screenmask]
		call 	Copy_cursor_shape	; Copy cursor addressed by DS:SI 
		call	TransMult
		ret

; ÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛ S U B	R O U T	I N E ÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛ

; Reset/Query driver Presence

Fun_00:		mov	[Cursor_Flag], byte 0
		call	Fun_02
		call	Reset_pointer_and_var
		xor	ax,ax
		mov	byte [User_Event_Mask], al ; Changed: Cursor pos,left press, left rel,	right press, right rel
		dec	ax		;mov	ax, 0FFFFh	;INSTALLED
		mov	[ORG_AX], ax
		mov	ax, 2		;0FFFFh	;2 Buttons	
		mov	[ORG_BX], ax
		ret

; ÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛ S U B	R O U T	I N E ÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛ

; Display Pointer

Fun_01		cmp	byte [Cursor_Flag], 0	; default -1 (FF) not visible
						; visible=0
		jz	end_fun_01		; già visibile
		inc	byte [Cursor_Flag]
		jnz	end_fun_01

		mov	ah, byte [Cursor_attribute]	
		mov 	al, 68h+80h
		out	0DDh,AX		;DD->AL DE->AH
		jmp 	adjust_cur		

end_fun_01:	ret


; ÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛ S U B	R O U T	I N E ÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛ

; Hide Pointer

Fun_02		dec	byte [Cursor_Flag]
		;cmp	byte [Cursor_Flag], 0FFh	; default -1 (FF) not visible
							; visible=0
		;jnz	end_fun_02			; always HIDE!

		mov 	al, 68h+80h
		mov	ah, 0Fh		;cursor transparent
		out	0DDh,AX		;DD->AL DE->AH

end_fun_02:	ret


; ÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛ S U B	R O U T	I N E ÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛ

; Query	Position & Buttons

Fun_03:		;pushf			; out:
					; CX = Horizontal (X) position
					; DX = Vertical	(Y) position
					; BX = Button Status (bit 0-1=L-R)
		mov	ax, [Button_Status]
		mov	[ORG_BX], ax
		mov	ax, [MouseX_Sum]
		mov	[ORG_CX], ax
		mov	ax, [MouseY_Sum]
		mov	[ORG_DX], ax
		;popf
		;check for INT_09 hook!
		call	Check_INT09_MONK
		ret


; ÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛ S U B	R O U T	I N E ÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛ

; Move Pointer

Fun_04:		mov	ax, dx
		call	Verify_in_VRange ; Verify if pointer in	Vertical Range
					; if not then move
		mov	bx, ax
		mov	ax, cx
		call	Verify_in_HRange ; Verify if pointer in	Horizontal Range
					 ; if not then move
		mov	[MouseX_Sum],	ax
		mov	[MouseY_Sum],	bx

		cmp	byte [Cursor_Flag], 0	; default -1 (FF) not visible
						; visible=0
		jnz	endfun4
		
adjust_cur	mov	BL, 0Fh			;usede to call/ret on update_cursor ^^
		call 	update_cur
			
endfun4:
		ret

; ÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛ S U B	R O U T	I N E ÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛ

; Query	Button Pressed count
; BX = 0  left button
;      1  right	button
;
;
;	  on return:
;	  BX = count of	button presses (0-32767), set to zero after call
;	  CX = horizontal position at last press
;	  DX = vertical	position at last press
;	  AX = status:
;		  |F-8|7|6|5|4|3|2|1|0|	 Button	Status
;		    |  | | | | | | | `---- left	button (1 = pressed)
;		    |  | | | | | | `----- right	button (1 = pressed)
;		    `------------------- unused

Fun_05:		cmp	bx, 1
		ja	Fun05_end
		jb	Fun_05Out
		mov	bx, RB_Count_press-LB_Count_press	;0=SX o delta=DX
Fun_05Out:	xor	ax, ax
		xchg	ax, [LB_Count_press+BX]		;così azzero anche COUNT con un'unica istruzione, veloce!
		mov	[ORG_BX],	ax
		mov	ax, [LB_PosX_last_press+BX]
		mov	[ORG_CX],	ax
		mov	ax, [LB_PosY_last_press+BX]
		mov	[ORG_DX],	ax
		mov	ax, [Button_Status]
		mov	[ORG_AX],	ax
Fun05_end:	ret


; Get Mouse Button Release Information
;
; BL=Button
;
; on return:
;	  BX = count of	button releases	(0-32767), set to zero after call
;	  CX = horizontal position at last release
;	  DX = vertical	position at last release
;	  AX = status

Fun_06:
		cmp	bx, 1
		ja	Fun05_end
		jb	.phase2		;se bx=0 don't add L/R offset
		mov	bx, RB_Count_press-LB_Count_press
.phase2		add	bx, LB_Count_releases-LB_Count_press
		jmp	Fun_05Out


; ÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛ S U B	R O U T	I N E ÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛ

; Set Horizontal range
; CX = minimum H pos
; DX = maximum H pos

Fun_07:		call	Invert		; Invert CX/DX if necessary (DX<CX)
		;pushf
		cli
		mov	[MIN_HRange], cx
		mov	[MAX_HRange], dx
		mov	ax, [MouseX_Sum]
		call	Verify_in_HRange ; Verify if pointer in	Horizontal Range
					 ; if not then move
		mov	[MouseX_Sum],	ax
		;popf
		jmp	adjust_cur


; ÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛ S U B	R O U T	I N E ÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛ

; Set Vertical range
; CX = minimum V pos
; DX = maximum V pos

Fun_08		call	Invert		; Invert CX/DX if necessary (DX<CX)
		;pushf
		cli
		mov	[MIN_VRange], cx
		mov	[MAX_VRange], dx
		mov	ax, [MouseY_Sum]
		call	Verify_in_VRange ; Verify if pointer in	Vertical Range
					; if not then move
		mov	[MouseY_Sum],	ax
		;popf
		jmp	adjust_cur

; ÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛ S U B	R O U T	I N E ÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛ

; Set graphic pointer shape
; BX = horizontal hot spot (-16	to 16)
; CX = vertical	hot spot (-16 to 16)
; ES:DX	= pointer to screen and	cursor masks (16 byte bitmap)

Fun_09:		cli
		neg	bx
		add	bx, 16
		mov	[CenterX], bx
		neg	cx
		add	cx, 16
		mov	[CenterY], cx
		push	ds
		mov	si, dx
		mov	ax, [ORG_ES]
		mov	ds, ax
		pop	es
		call	Copy_cursor_shape
		push	es
		pop	ds
		sti
		jmp	adjust_cur		;è cambiato il centro!
		;ret


; ÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛ S U B	R O U T	I N E ÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛ

; Copy cursor addressed by DS:SI 

Copy_cursor_shape:		
	mov	dx, 0DDh		;sistemiamo lo sprite...
	xor	ax, ax
	out	dx, al
	inc	dx
	cld

	mov     cx, 20h		;32 valori word (64 byte)
.copy_next:
	lodsw                   ; Load Cursor value
	cmp	cx, 10h		; if first 32 byte
	jbe	.ok		; also slow down a little the procedure: too fast in a "0-wait-state" PC1!
	not	ax		; invert it -> also is some byte less (8 byte!)
.ok:	xchg	ah,al
	out 	dx, al
	xchg	ah,al
	out 	dx, al
	loop    .copy_next       ; Load Values

	ret

; ¦¦¦¦¦¦¦¦¦¦¦¦¦¦¦ S U B R O U T I N E ¦¦¦¦¦¦¦¦¦¦¦¦¦¦¦¦¦¦¦¦¦¦¦¦¦¦¦¦¦¦¦¦¦¦¦¦¦¦¦

; Normally Set text pointer mask
; but in this special driver set the graphics cursor color attribute
; BX = FF , then CX = AND/XOR attribute. F0 = white/black not trasparent.
; DX = 1 -> blink

Fun_0A:		cmp     bl, 0FFh 
		jnz     endfun
		mov 	byte [Cursor_attribute], cl
		mov	al, 64h+80h		;register 64h
		out	0DDh, al
		xchg	al, dl
		or	al, 110b	;set mask/and/xor = ON
		out	0DEh, al
		dec	byte [Cursor_Flag]
		jmp 	Fun_01
;endfun0A:	ret

; ÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛ S U B	R O U T	I N E ÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛ

; Query	last motion distance

Fun_0B:		;pushf
		cli
		xor	ax, ax			;così azzeriamo in un passaggio solo!
		xchg	ax, [H_Mickey_Count] ; horizontal	mickey count (-32768 to	32767)
		mov	[ORG_CX],	ax
		xor	ax, ax
		xchg	ax, [V_Mickey_Count] ; vertical mickey count (-32768 to 32767)
		mov	[ORG_DX],	ax
		;popf
endfun:		ret

; ÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛ S U B	R O U T	I N E ÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛ

; Set Event Handler

Fun_0C:		;pushf
		cli
		mov	word [Event_Handler_Addr], dx
		mov	dx, [ORG_ES]
		mov	word [Event_Handler_Addr+2], dx
		and	cl, 7Fh		; exclude high bit (7)
		mov	byte [User_Event_Mask], cl ; Changed: Cursor pos,left press, left rel,	right press, right rel
		;popf
		sti
		ret

;Fun_0D:		ret
;Fun_0E:		ret
 
; ¦¦¦¦¦¦¦¦¦¦¦¦¦¦¦ S U B R O U T I N E ¦¦¦¦¦¦¦¦¦¦¦¦¦¦¦¦¦¦¦¦¦¦¦¦¦¦¦¦¦¦¦¦¦¦¦¦¦¦¦

; Set Pointer Speed
; CX= Horizontal Ratio
; DX= Vertical Ratio

Fun_0F: 	;cmp	cx,0
		;je	EndFun10	;una divisione per /0 avrebbe esiti funesti!
		;cmp	dx,0
		;je	EndFun10
		;mov     [Hor_Ratio], cx
		;mov     [Vert_Ratio], dx

		xchg	ax, cx		;se porto tutto su AX risparmio 1 byte ogni operazione!
		cmp	ax, word 0000h
		je	.skipHor	;una divisione per /0 avrebbe esiti funesti!
		mov     [Hor_Ratio], ax
.skipHor	xchg	ax, dx
		cmp	ax, word 0000h		;una divisione per /0 avrebbe esiti funesti!
		je	EndFun		;pulcioso, ma risparmio 1 byte
		mov     [Vert_Ratio], ax
		jmp	TransMult	

;Fun_10:		ret

; ¦¦¦¦¦¦¦¦¦¦¦¦¦¦¦ S U B R O U T I N E ¦¦¦¦¦¦¦¦¦¦¦¦¦¦¦¦¦¦¦¦¦¦¦¦¦¦¦¦¦¦¦¦¦¦¦¦¦¦¦

; Get driver type
; return_ AX= 33h
Fun_11:		mov	ax, 33h		;Special PC1 mouse driver
		mov	[ORG_AX], ax
		mov	al, 2
		mov	[ORG_BX], ax	;number of buttons
EndFun:		ret

;Fun_12:		ret

; ¦¦¦¦¦¦¦¦¦¦¦¦¦¦¦ S U B R O U T I N E ¦¦¦¦¦¦¦¦¦¦¦¦¦¦¦¦¦¦¦¦¦¦¦¦¦¦¦¦¦¦¦¦¦¦¦¦¦¦¦

; Set max for Speed Doubling

Fun_13:		xchg    ax, dx
		mov     [Max_Speed_D], ax
		add     ax, 11h
		mov     bx, 23h
		xor     dx, dx
		div     bx
		mov     [Max_speed_D2], ax
		ret


; ÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛ S U B	R O U T	I N E ÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛ

; Exchange Event Handler

Fun_14:		;pushf
		cli
		mov	ax, word [Event_Handler_Addr]
		mov	[ORG_DX],	ax
		mov	word [Event_Handler_Addr], dx
		mov	dx, [ORG_ES]
		mov	ax, word [Event_Handler_Addr+2]
		mov	[ORG_ES],	ax
		mov	word [Event_Handler_Addr+2], dx
		xor	ax, ax
		mov	al, byte [User_Event_Mask] ; Changed: Cursor pos,left press, left rel,	right press, right rel
		mov	[ORG_CX],	ax
		and	cl, 7Fh
		mov	byte [User_Event_Mask], cl ; Changed: Cursor pos,left press, left rel,	right press, right rel
		sti
		;popf
EndFun14:	ret

;Fun_15:		ret
;Fun_16:		ret
;Fun_17:		ret
;Fun_18:		ret
;Fun_19:		ret

 ; ¦¦¦¦¦¦¦¦¦¦¦¦¦¦¦ S U B R O U T I N E ¦¦¦¦¦¦¦¦¦¦¦¦¦¦¦¦¦¦¦¦¦¦¦¦¦¦¦¦¦¦¦¦¦¦¦¦¦¦¦

; Transform multiplier in SHIFT-LEFT
; me ne sbatto dei risultati che hanno un rapporto Mult/Ratio < 1 anche perchè il mouse è già lento così di suo
; [shift_X_Pos] già considerato!

TransMult:	mov 	al, byte [shift_X_Pos]		;parto da questo valore
		mov	byte [shift_ratioX], al
		mov     ax, [X_Mult_Ratio]
		xor	dx, dx
		div	word [Hor_Ratio]
.redo1:		shr	AX, 1
		cmp	ax, 0
		je	.ok1
		inc	byte [shift_ratioX]
		jmp	.redo1
		
.ok1:		mov	byte [shift_ratioY], 0
		mov     ax, [Y_Mult_Ratio]
		xor	dx, dx
		div	word [Vert_Ratio]
.redo2:		shr	AX, 1
		cmp	ax, 0
		je	EndFun14	;.ok2 - pulcioso ma risparmio!
		inc	byte [shift_ratioY]
		jmp	.redo2
;.ok2:		ret

 ; ¦¦¦¦¦¦¦¦¦¦¦¦¦¦¦ S U B R O U T I N E ¦¦¦¦¦¦¦¦¦¦¦¦¦¦¦¦¦¦¦¦¦¦¦¦¦¦¦¦¦¦¦¦¦¦¦¦¦¦¦

; Set mouse sensivity
;         BX = horizontal coordinates per pixel
;         CX = vertical coordinates per pixel
;         DX = double speed threshold

Fun_1A:		shr	bx, 2
		mov     [X_Mult_Ratio], bx
		shr	cx, 2
		mov     [Y_Mult_Ratio], cx
		call	TransMult
		jmp     Fun_13          ; Set max for Speed Doubling

; ¦¦¦¦¦¦¦¦¦¦¦¦¦¦¦ S U B R O U T I N E ¦¦¦¦¦¦¦¦¦¦¦¦¦¦¦¦¦¦¦¦¦¦¦¦¦¦¦¦¦¦¦¦¦¦¦¦¦¦¦

;adjust_mult:	mov     bl, 0Ah
;		div     bl
;		xor     ah, ah
;		cmp     al, 0Ah
;		jbe     short loc_B9B
;		mov     al, 0Ah
;loc_B9B:	mov     bx, moltiplic
;		;add     bx, ax
;		;mov     al, [bx]	;qui uso XLAT = mov al, [BX+AL]
;		XLAT
;		ret
; ---------------------------------------------------------------------------
;moltiplic       db 1, 2, 3, 4, 6, 8, 0Ah, 0Eh, 12h, 16h, 1Eh


; ¦¦¦¦¦¦¦¦¦¦¦¦¦¦¦ S U B R O U T I N E ¦¦¦¦¦¦¦¦¦¦¦¦¦¦¦¦¦¦¦¦¦¦¦¦¦¦¦¦¦¦¦¦¦¦¦¦¦¦¦

; Query Mouse Sensivity

Fun_1B:		;mov     ax, [Hor_CoordXPixel]
		mov     ax, [X_Mult_Ratio]
		shl	ax, 2
		mov     [ORG_BX], ax
		;mov     ax, [Ver_CoordXPixel]
		mov     ax, [Y_Mult_Ratio]
		shl	ax, 2
		mov     [ORG_CX], ax
		mov     ax, [Max_Speed_D]
		mov     [ORG_DX], ax
		ret

;Fun_1C:		ret

;Fun_1D:	mov     [CRT_page_num], bx
;		ret

;Fun_1E:	mov     ax, [CRT_page_num]
;             	mov    [ORG_BX], ax
;		ret

;Fun_1F:		ret
;Fun_20:		ret
;Fun_21:		ret
;Fun_22:		ret

; LANGUAGE = ITA!!! :)
Fun_23:		mov     word [ORG_BX], 08h
		ret

; 24 - Get software version, mouse type and IRQ
; Out:	[AX] = 24h/FFFFh	(installed/error)
;	[BX]			(version)
;	[CL]			(IRQ #/0=PS/2)
;	[CH] = 1=bus/2=serial/3=InPort/4=PS2/5=HP (mouse type)
; Use:	driverversion
Fun_24:		mov     word [ORG_BX], driverversion
		mov	word [ORG_CX], 0309h	;inport, IRQ=09
		ret

; ÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛ S U B	R O U T	I N E ÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛ

; Call INT 33 subfunction in AX

Call_Subfun:	push	bp
		push	ds
		push	cs	;right segment!
		pop	ds
		mov	[ORG_AX], ax
		mov	[ORG_BX], bx
		mov	[ORG_CX], cx
		mov	[ORG_DX], dx
		mov	[ORG_DI], di
		mov	[ORG_SI], si
		mov	[ORG_ES], es
		push	ds
		pop	es
		cmp	ax, 14h
		ja	short OtherFuns	; other functions!
		push	si
		mov	si, ax
		shl	si, 1
		mov	ax, [Int33_sub_index+si]
		pop	si
call_it:	call	ax
		jmp	short loc_6F5

; ÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄ
; 2A - Get cursor hot spot
; Out:	[AX]			(cursor visibility counter)
;	[BX]			(hot spot X)
;	[CX]			(hot spot Y)
;	[DX] = 1=bus/2=serial/3=InPort/4=PS2/5=HP (mouse type)	
;		cmp	al, 2Ah
;		jnz	short Fun_4D
;		mov	ax, [Cursor_Flag]
;		mov	[ORG_AX], AX
;		mov	ax, 16
;		sub	ax, [CenterX]
;		mov	[ORG_BX], AX
;		mov	ax, 16
;		sub	ax, [CenterY]
;		mov	[ORG_CX], AX
;		mov	word [ORG_DX], 3	;inport mouse
;		jmp	short loc_6F5

Fun_4D:		; Pointer to Microsoft Label!
		mov	word [ORG_DI], Copyright1983
		mov	[ORG_ES], cs
		ret

Fun_6D:		jnz	short loc_6F5
		mov	[ORG_DI], word magicnumber ;word 204h
		mov	[ORG_ES], cs
		ret

execute:	shl	bx,1
		call	[CS:other_address+bX]
		jmp	short loc_6F5	

OtherFuns:	mov	bx, 4
more:		cmp 	al, [other_num+bx]
		jz	execute
		dec	bx
		jnz	more

loc_6F5:
		mov	ax, [ORG_ES]
		mov	es, ax
		mov	si, [ORG_SI]
		mov	di, [ORG_DI]
		mov	dx, [ORG_DX]
		mov	cx, [ORG_CX]
		mov	bx, [ORG_BX]
		mov	ax, [ORG_AX]
		pop	ds
		pop	bp
		ret

other_address: 	dw Fun_1A, Fun_1B, Fun_23, Fun_24, Fun_4D, Fun_6D
other_num	db 1Ah, 1Bh, 23h, 24h, 4Dh, 6Dh

; ÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛ S U B	R O U T	I N E ÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛ


Call_User:
		cmp	byte [Already_in_user], 0FFh
		jz	endend
		mov	byte [Already_in_user], 0FFh
		xor	ax,ax
		mov	al, byte [Last_mask]
		and	al, byte [User_Event_Mask] ; Changed: Cursor pos,left press, left rel,	right press, right rel
		mov	bp, Event_Handler_Addr ;	   Custom Event Handler
		jz	no_sub
		call	CALL_FUN_AT_BP	; call function	(save all registers)
					; @ BasePointer
no_sub:		mov	byte [Already_in_user], 0

endend:		ret

; ÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛ S U B	R O U T	I N E ÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛ

; call function	(save all registers)
; @ BasePointer

CALL_FUN_AT_BP:	
		mov	bx, [Button_Status]
		mov	cx, [MouseX_Sum]
		mov	dx, [MouseY_Sum]
		mov	si, word [H_Mickey_Count] ; horizontal	mickey count (-32768 to	32767)
		mov	di, word [V_Mickey_Count] ; vertical mickey count (-32768 to 32767)
		;pushf
		sti
		call	far [cs:bp]
		;popf
		PUSH	CS		;return to my DS segment
		POP	DS
		ret


 ; ¦¦¦¦¦¦¦¦¦¦¦¦¦¦¦ S U B R O U T I N E ¦¦¦¦¦¦¦¦¦¦¦¦¦¦¦¦¦¦¦¦¦¦¦¦¦¦¦¦¦¦¦¦¦¦¦¦¦¦¦

 ; Invert CX/DX if necessary (DX<CX)

Invert:		cmp     cx, dx
		jl      short locret_D05
		xchg    cx, dx
locret_D05: 	ret


; ÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛ S U B	R O U T	I N E ÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛ

;Input:     AX=Vertical Pos
; Verify if pointer in Vertical	Range
; if not then move
; Corrupt AX, DX

Verify_in_VRange:
		;push	dx
                mov     dx, [CS:MIN_VRange]
		cmp	ax, dx
		jl	short .set
                mov     dx, [CS:MAX_VRange]
		cmp	ax, dx
		jle	short .skip

.set:
		mov	ax, dx

.skip:		;pop	dx
		ret

; ÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛ S U B	R O U T	I N E ÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛÛ

;Input:     AX=Horizontal Pos
; Verify if pointer in Horizontal Range
; if not then move
; Corrupt AX, DX

Verify_in_HRange:
		;push	dx
                mov     dx, [CS:MIN_HRange]
		cmp	ax, dx
		jl	short set2
                mov     dx, [CS:MAX_HRange]
		cmp	ax, dx
		jle	short skip3

set2:
		mov	ax, dx

skip3:		;pop 	dx
		ret

;************** Constants / Costanti ****************************************
Copyright1983 db 'Copyright 1983 Microsoft ***'
magicnumber db 55h, 64h
; ========================== END OF RESIDENT PART =========================

notresident:
db '*** This is a PC1 mouse driver by Riminucci Simone (c) 2016, but some software expect here the upper string!'
welcome DB  'MOUSE-PC1 Driver ver. 0.97 - Simone Riminucci (C) 2016',0Dh,0Ah,'$'
already	DB	'A driver is already installed',0Dh,0Ah,'$'
EGAVGA	DB	'EGA/VGA Patch installed (advanced functions disabled)',0Dh,0Ah,'$'
ForceIn db 	'F: The driver will be installed over the existing one',0Dh,0Ah,'$'
SiamoSpiacenti  db 'It was not possible to install the mouse driver',0Dh,0Ah
        db 'This mouse driver works only on OLIVETTI PRODEST PC1. ',0Ah, 0Dh,'$'
aSpiacentiIlMou db 'Warning: the mouse is NOT connected.',0Ah,0Dh,'$'

helpmsg	db	0Ah,0Dh,"Parameters:",0Ah,0Dh
    db	0Ah,0Dh
    db	"/I - Do not check if on Olivetti Prodest PC1",0Ah,0Dh
    db	"/M - Show cursor immediately in DOS",0Ah,0Dh
    db	"/F - Force installation even over existing driver",0Ah,0Dh
    db	"/E - Force installation of EGA/VGA Patch",0Ah,0Dh
    db	"$"

Equipment_Addr 	dw 0A1h

start:
	push	cs
	pop	ds
	lea     dx, [welcome] ; "Benvenuti"...
	mov     ah, 9
	int     21h             ; DOS - PRINT STRING	

	call    process_cmdline         ; grab switches, etc

	test	byte [cmdlineflags], help
	jnz	display_help

	test	byte [cmdlineflags], nocheck
	jnz	skipcheck

	call	check_for_PC1
	or      ax, ax
	jz      not_PC1

skipcheck:	
	mov 	AX,0000h	;intallation check if already installed
	int	33h
	cmp	AX,0FFFFh
%ifndef DEBUG
	jne	cont0
	test	byte [cmdlineflags], forceinst
	jz	terminate
	lea     dx, [ForceIn] ; ">Forced!"...
	mov     ah, 9
	int     21h             ; DOS - PRINT STRING
%endif

cont0:	
	cli
	; SKIPPED FOR TESTING (no hardware mouse connected)
	; call    set_mouse_keyb			; Set keyboard chip 8042
						; to respond to mouse click -> scancode
						; Left Button   77h
						; Middle Button 78h
						; Right Button  79h
	mov al, 01h                         ; Force success (bypassing hardware check)
	or      al, al
%ifndef DEBUG
	jz      short print_mouse_non_connesso
%endif
	call    Install_INT08
	call    Install_INT09
	call    Install_INT33
	
	call	reset_V6355D
        call    Reset_pointer_and_var
	
	test	byte [cmdlineflags], showcurs
	jz	skipshow
        call    Fun_01

skipshow:
        STI

terminate_but_stay_resident:

cont3:		
	mov     ah, 51h         ;Get application's PSP address
        int     21h		;we get it in bx
	mov     es, bx
	mov     es, [es:2Ch]    ;Get address of environment block.
	mov     ah, 49h         ;DOS deallocate block call.
	int     21h		;get rid of PSP!

	mov	dx, notresident		; only resident part will be saved

	mov	cl, 4
	shr	dx, cl			; paragraph to keep
	inc	dx			; 1 paragraph more... safer for roundings

	MOV	AX, 3100h	;
	INT 	21h		;stay resident and exit

terminate:
	lea     dx, [already] ; "Già installato!"...
	mov     ah, 9
	int     21h             ; DOS - PRINT STRING
error:
	MOV 	AX, 4C01h	;AH 4C = Exit to DOS, ERRORLEVEL AL 01
	INT	21h

print_mouse_non_connesso:
	lea     dx, [aSpiacentiIlMou] ; "Non connesso!"...
	mov     ah, 9
	int     21h             ; DOS - PRINT STRING
	MOV 	AX, 4C02h	;AH 4C = Exit to DOS, ERRORLEVEL AL 02
	INT	21h

reset_V6355D:
	cli
	;mov 	dx, 3DDh
	;mov 	al, 65h+80h
	;out	dx, al
	;inc	dx
	;mov	al, 89h		;mouse enable
	;out	dx, al
	push	ds
	mov     bx, [Equipment_Addr]                               
	mov     ax, BIOS_DATA_SEG
	mov     ds, ax
	mov     al, [bx]
	pop	ds
	test	byte [cmdlineflags], forceEGA
	jnz	.force
	test	al, 1
	jz	.cont
.force	and     al, 0FEh        ; azzera l'ultimo bit
	;;;;mov     [bx], al	; lo riscrivo indietro in modo che non venga più cambiato!?!?
	or      byte [cmdlineflags], forceEGA  ; mi segno che era quello!
	out     68h, al         ; così "accende" lo schermo V6355D e il counter del mouse
	in	al, 0D1h
	cmp	al, 0FFh	; questo controllo è utile solo per computer non-pc1
	jnz	.wmsg
	test	byte [cmdlineflags], nocheck
	jz	not_PC1
.wmsg	lea     dx, [EGAVGA] ; "EGA/VGA Patch installed"...
	mov     ah, 9
	int     21h             ; DOS - PRINT STRING	

.cont	mov 	dx, 3DDh
	mov 	al, 64h+80h
	out	dx, al
	inc	dx
	mov	al, 6h		;mouse AND & XOR enable
	out	dx, al
	sti
        ret

check_for_PC1:

PC1_Equipment_Addr 	EQU 89h
PC1HD_Equipment_Addr 	EQU 0A1h

	push    bx
	push    ds
	mov     ax, 0F000h
	mov     ds, ax
	mov     bx, 0FFFDh      ; penultimi due byte del BIOS
	mov     ax, [bx]
	pop	ds
	mov	bl, PC1HD_Equipment_Addr
	cmp     ax, 0FE44h      ; PC1 - Floppy
	jz      short pc1dd
	cmp     ax, 0FE49h      ; PC1 - Unknown
	jz      short loc_2B1C
	cmp     ax, 0FE4Ah      ; PC1 - HD
	jnz     short loc_2B22

pc1dd:	mov	bl, PC1_Equipment_Addr

loc_2B1C:                               
	mov     ax, 0FFh
	jmp     short loc_2B25

loc_2B22:                               
	mov     ax, 0

loc_2B25:                                                          
	mov	[Equipment_Addr],bl   
	pop     bx
	ret

not_PC1:
	lea     dx, [SiamoSpiacenti] ; "Siamo spiacenti di non poter installare"...
	mov     ah, 9
	int     21h             ; DOS - PRINT STRING
				; DS:DX -> string terminated by "$"
	jmp	error

Value_for_8042  db 12h, 77h, 78h, 79h, 1	;valori dei tre tasti del mouse: 77h 78h 79h

set_mouse_keyb:
	cli
	mov     al, 12h
	push    ax
	mov     dx, 64h
wait_8042:
	in      al, dx          ; AT Keyboard controller 8042.
	and     al, 2
	jnz     short wait_8042
	pop     ax
	out     dx, al          ; AT Keyboard controller 8042.
wait_8042f:
	in      al, 64h         ; AT Keyboard controller 8042.
	and     al, 1
	jz      short wait_8042f
	in      al, 60h         ; AT Keyboard controller 8042.
	and     al, 1
	jnz     short skip
	push    si
	lea     si, [Value_for_8042]
	mov     cx, 5
	cld
load_next:
	lodsb                   ; Load Value: 12h 77h 78h 79h 01
	push    ax
	mov     dx, 64h
wait_8042g:
	in      al, dx          ; AT Keyboard controller 8042.
	and     al, 2
	jnz     short wait_8042g
	pop     ax
	mov     dx, 60h
	out     dx, al          ; AT Keyboard controller 8042.
	loop    load_next       ; Load Value: 12h 77h 78h 79h 01
	mov     ax, 0FFh
	pop     si
	sti
	ret
skip:	xor	ax, ax
	sti
	ret

;===========================================================================
;Procedure: ucase
;Purpose:   Converts character in AL to uppercase.
;           
;Input:     AL=character
;           
;Output:    AL=uppercase character (if a-z)
;           All other registers preserved.  (flags too)
;
;Processing: test valid range (a-z), set to upper, exit
;---------------------------------------------------------------------------
ucase:
	pushf
	cmp al,"a"                  ;if  it's not a-z, skipit
	jb noupper
	cmp al,"z"
	ja noupper
	and al,5fh                  ;strip off a few bits to make it upper
noupper:        
	popf
	ret

;##################### start cmd line interpret ####################

; command line flags
help		EQU	BIT0		; help requested
nocheck		EQU	BIT1		; don't check for PC1
showcurs	EQU	BIT2		; show cursor at loading
forceinst	EQU	BIT3		; forced install over an existing driver
forceEGA	EQU	BIT4		; force EGA/VGA book
debug		EQU	BIT5		; debug bit
koverride	EQU	BIT5		; debug bit
writeprotect	EQU	BIT6		; write protected bit
noint10		EQU	BIT7		; light INT10 hook (composit)


process_cmdline:

        push    ds
        push    bx
        push    si

        mov     ah, 51h
        int     21h
        mov     ds, bx
	mov 	cx, bx

        mov     si, 80h
	mov 	bh, 0
	mov	bl, byte [si]
        add     si, bx
        inc     si

        mov     byte [si], NULL             ;zero terminate

        mov     si, 81h

cmdlineloop:
	mov	ds,cx
        lodsb			;Transfers string element addressed by DS:SI to the accumulator
	push	cs
	pop	ds
        cmp     al, " "                 ; found a space?
        jz      cmdlineloop
        cmp     al, NULL                ; found end of line?
        jz      exitpc
        cmp     al, "-"                 ; found a flag?
        jz      checkflags
        cmp     al, "/"                 ; found a flag?
        jz      checkflags

        ; unknow skip but show help
	or      byte [cmdlineflags], help
	jmp 	cmdlineloop
exitpc: pop     si
        pop     bx
        pop     ds
        
        ret

checkflags:
	mov	ds,cx
        lodsb			;Transfers string element addressed by DS:SI to the accumulator
	push	cs
	pop	ds
        cmp     al, " "                 ; false flag
        jz      cmdlineloop
        cmp     al, NULL                ; found end of line?
        jz      exitpc
        cmp     al, "-"                 ; found a double flag?
        jz      checkflags
        cmp     al, "/"                 ; found a double flag?
        jz      checkflags

        ; must be a flag

	call	ucase

	cmp	al, "?"
	jz	sethelp

	cmp	al, "H"
	jz	sethelp

	cmp	al, "I"
	jz	setignorenotPC1

	cmp	al, "M"
	jz	setshowcursor

	cmp	al, "F"
	jz	setforceinst

	cmp	al, "E"
	jz	setforceEGA

	jmp     cmdlineloop             ; nothing we care about, continue
                                        ; could jump to help msg
sethelp:
        or      byte [cmdlineflags], help
        jmp     checkflags              ; allows flags to be stacked

setignorenotPC1:
        or      byte [cmdlineflags], nocheck
        jmp     checkflags              ; allows flags to be stacked

setshowcursor:
        or      byte [cmdlineflags], showcurs
        jmp     checkflags              ; allows flags to be stacked

setforceinst:
        or      byte [cmdlineflags], forceinst
        jmp     checkflags              ; allows flags to be stacked

setforceEGA:
        or      byte [cmdlineflags], forceEGA
        jmp     checkflags              ; allows flags to be stacked

;##################### end cmd line interpret ####################


Install_INT08:
	cli
	mov     ax, 3508h
	int     21h             ; DOS - 2+ - GET INTERRUPT VECTOR
				; AL = interrupt number
				; Return: ES:BX = value of interrupt vector
	mov     word [Old_INT08], bx
	mov     word [Old_INT08+2], es
	mov     dx, INT_08 ; Int 08 Entry Point
	mov     ax, 2508h
	int     21h             ; DOS - SET INTERRUPT VECTOR
				; AL = interrupt number
				; DS:DX = new vector to be used for specified interrupt
	sti
	ret


Install_INT09:
	cli
	mov     ax, 3509h
	int     21h             ; DOS - 2+ - GET INTERRUPT VECTOR
				; AL = interrupt number
				; Return: ES:BX = value of interrupt vector
	mov     word [Old_INT09], bx
	mov     word [Old_INT09+2], es
	mov     dx, INT_09 ; Int 09 Entry Point
	mov     ax, 2509h
	int     21h             ; DOS - SET INTERRUPT VECTOR
				; AL = interrupt number
				; DS:DX = new vector to be used for specified interrupt
	sti
	ret

Install_INT33:
	cli
%ifdef CALL_OLD_INT33
	push    ds
	xor     ax, ax
	mov     ds, ax
	mov     si, 0CCh
	mov     bx, [si]
	mov     cx, [si+2]
	pop     ds
	mov     [Old_INT33], bx
	mov     [Old_INT33+2], cx
%endif
	lea     dx, [INT_33]      ; Int33 Entry Point
	mov     al, 33h
	mov     ah, 25h		; DOS - SET INTERRUPT VECTOR
	int     21h             ; AL = interrupt number
	ret			; DS:DX = new vector to be used for specified interrupt


display_help:

	mov	ah, 9
	lea	dx, [helpmsg]			; display help message
	int	21h
	
exit	mov	ax, 4c02h			; end
	int	21h

END: