# JOYMOUSE-PC1

INT 33h mouse driver for the **Olivetti Prodest PC1** using an Atari-style joystick connected to the DE-9 mouse port.

Based on MOUSE-PC1 by Simone Riminucci (C) 2016.  
Joystick adaptation by Retro Erik — 2026.

## How it works

The PC1 translates joystick directions and the fire button into keyboard scan codes via the 8042 keyboard controller:

| Joystick | Scan code | Mouse action |
|----------|-----------|--------------|
| Up       | 48h (↑)   | Cursor up    |
| Down     | 50h (↓)   | Cursor down  |
| Left     | 4Bh (←)   | Cursor left  |
| Right    | 4Dh (→)   | Cursor right |
| Fire     | 39h (Space) | Left click |

The driver intercepts these scan codes in INT 09h and converts them into INT 33h mouse events. Cursor movement is rendered using the V6355D hardware sprite.

### Scroll Lock toggle

Since the joystick shares scan codes with the arrow keys and Space, a **Scroll Lock** toggle controls when interception is active:

- **Scroll Lock ON** — Joystick mode: arrow keys and Space are captured for mouse control
- **Scroll Lock OFF** — Normal mode: all keys pass through to DOS

Press Scroll Lock before launching a game, and again to return to normal keyboard operation.

## Usage

```
JOYMOUSE [/M] [/1|/2|/3] [/I] [/F] [/E]
```

| Parameter | Description |
|-----------|-------------|
| `/M`      | Show cursor immediately after loading |
| `/1`      | Slow cursor speed |
| `/2`      | Medium cursor speed (default) |
| `/3`      | Fast cursor speed |
| `/I`      | Skip PC1 hardware detection check |
| `/F`      | Force install over an existing mouse driver |
| `/E`      | Force EGA/VGA patch |
| `/?`      | Display help |

## Building

Requires [NASM](https://www.nasm.us/):

```
nasm -f bin -o joymouse.com JoyMouse.asm
```

## Hardware background

The PC1's DE-9 mouse port is designed for a quadrature mouse. When no mouse is detected (ENA pin floating), the PC1 treats the port as a joystick using standard Atari pinout. The 8042 keyboard controller generates arrow key and Space scan codes for the five joystick inputs.

Only joystick Up and Down are wired to the V6355D switch pins (readable on port 0x3DA bits 1–2). Left, Right, and Fire connect to quadrature encoder pins which don't produce usable signals from a digital joystick's on/off switches. Therefore all five inputs are read via scan code interception.

## Tested with

- Norton SI (text mode)
- Leisure Suit Larry 2 (Sierra SCI0, with PC1 SCI0 driver)

## Files

| File | Description |
|------|-------------|
| `JoyMouse.asm` | Driver source code |
| `joymouse.com` | Compiled driver |
| `JOY.EXE` | Official Olivetti joystick remapping utility - translated to english |
