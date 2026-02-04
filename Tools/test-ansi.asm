; ANSI Test - Display colored help screen
; Assemble: nasm -f bin test-ansi.asm -o test-ansi.com
; Run: test-ansi.com

CPU 186
ORG 100h

start:
    mov ah, 09h             ; DOS print string function
    mov dx, info_text       ; Pointer to $ terminated string
    int 21h
    
    ; Wait for key press
    mov ah, 00h
    int 16h
    
    ; Exit
    mov ax, 4C00h
    int 21h

info_text:
    db 1Bh, '[2J', 1Bh, '[H'        ; Clear screen and home cursor
    db 1Bh, '[1;36m'                ; Bright Cyan
    db 'BBalls4: Raster-Synchronized Sprite Multiplexing', 13, 10
    db 1Bh, '[1;33m'                ; Bright Yellow
    db '================================================', 13, 10
    db 1Bh, '[0m', 13, 10            ; Reset colors
    db 1Bh, '[1;32m'                ; Bright Green
    db 'Two bouncing balls from ONE 16x16 sprite!', 13, 10
    
    ; 16 horizontal color bars - 8 normal colors on top row, 8 bright colors on bottom row
    db 1Bh, '[4;52H'                ; Position first row (moved right by 2 chars)
    db 1Bh, '[40m   ', 1Bh, '[0m'  ; Black
    db 1Bh, '[44m   ', 1Bh, '[0m'  ; Blue
    db 1Bh, '[42m   ', 1Bh, '[0m'  ; Green
    db 1Bh, '[46m   ', 1Bh, '[0m'  ; Cyan
    db 1Bh, '[41m   ', 1Bh, '[0m'  ; Red
    db 1Bh, '[45m   ', 1Bh, '[0m'  ; Magenta
    db 1Bh, '[43m   ', 1Bh, '[0m'  ; Brown
    db 1Bh, '[47m   ', 1Bh, '[0m'  ; Light Gray
    db 1Bh, '[5;52H'                ; Position second row (moved right by 2 chars)
    db 1Bh, '[1;30m', 219,219,219, 1Bh, '[0m'  ; Dark Gray (bright black)
    db 1Bh, '[1;34m', 219,219,219, 1Bh, '[0m'  ; Light Blue (bright blue)
    db 1Bh, '[1;32m', 219,219,219, 1Bh, '[0m'  ; Light Green (bright green)
    db 1Bh, '[1;36m', 219,219,219, 1Bh, '[0m'  ; Light Cyan (bright cyan)
    db 1Bh, '[1;31m', 219,219,219, 1Bh, '[0m'  ; Light Red (bright red)
    db 1Bh, '[1;35m', 219,219,219, 1Bh, '[0m'  ; Light Magenta (bright magenta)
    db 1Bh, '[1;33m', 219,219,219, 1Bh, '[0m'  ; Yellow (bright brown)
    db 1Bh, '[1;37m', 219,219,219, 1Bh, '[0m'  ; White (bright light gray)
    
    db 1Bh, '[5;1H'                 ; Same line as bright color bars (row 5, column 1)
    db 1Bh, '[1;37m'                ; Bright White
    db 'Mid-frame repositioning chases the CRT beam', 13, 10
    db 1Bh, '[0m', 1Bh, '[37m'      ; Reset then Grey
    db 'down the screen for flicker-free animation.', 13, 10
    db 1Bh, '[0m', 13, 10            ; Reset
    db 1Bh, '[1;35m'                ; Bright Magenta
    db 'This is the BREAKTHROUGH version that proves', 13, 10
    db 1Bh, '[1;36m'                ; Bright Cyan
    db 'raster-sync multiplexing works on the PC1.', 13, 10
    db 1Bh, '[0m', 13, 10            ; Reset
    
    db 13, 10
    db 1Bh, '[1;33m'                ; Bright Yellow
    db 'Powered by ', 1Bh, '[1;36m', 'V6355D', 13, 10
    db 1Bh, '[0m'                   ; Reset
    db 'Created by ', 1Bh, '[1;35m', 'Retro ', 1Bh, '[1;36m', 'Erik', 1Bh, '[0m', ', 2026', 13, 10
    db 1Bh, '[1;33m', 'Press ESC to exit', 1Bh, '[0m', 13, 10, '$'
    db 1Bh, '[1;32m'                ; Bright Green
    db 'Two bouncing balls from ONE 16x16 sprite!', 13, 10
    db 1Bh, '[1;31m'                ; Bright Red
    db 'Mid-frame repositioning chases the CRT beam', 13, 10
    db 1Bh, '[1;34m'                ; Bright Blue
    db 'down the screen for flicker-free animation.', 13, 10
    db 1Bh, '[0m', 13, 10            ; Reset
    db 1Bh, '[1;35m'                ; Bright Magenta
    db 'This is the BREAKTHROUGH version that proves', 13, 10
    db 1Bh, '[1;36m'                ; Bright Cyan
    db 'raster-sync multiplexing works on the PC1.', 13, 10
    db 1Bh, '[0m', 13, 10            ; Reset
    db 1Bh, '[1;33m'                ; Bright Yellow
    db 'Powered by ', 1Bh, '[1;36m', 'V6355D', 13, 10
    db 1Bh, '[0m'                   ; Reset
    db 'Created by ', 1Bh, '[1;35m', 'Retro ', 1Bh, '[1;36m', 'Erik', 1Bh, '[0m', ', 2026', 13, 10
    db 1Bh, '[1;33m', 'Press ESC to exit', 1Bh, '[0m', 13, 10, '$'
