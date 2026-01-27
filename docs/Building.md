# Building PC1 Sprite Demo

Instructions for assembling the demos and driver on Windows, macOS, and Linux.

## Requirements

- **NASM** (Netwide Assembler) 2.14 or later
- **DOS or emulator** (PCem, 86Box, DOSBOX) to run the compiled COM files
- **Optional**: Text editor with assembly syntax highlighting (VS Code, Sublime Text, etc.)

## Installation

### Windows

1. Download NASM from https://www.nasm.us/
2. Extract to a folder (e.g., `C:\nasm`)
3. Add to PATH:
   - Right-click "This PC" → Properties → Advanced system settings
   - Environment Variables → Edit PATH
   - Add `C:\nasm` (or your NASM folder)
4. Verify: Open PowerShell and run `nasm -version`

### macOS

```bash
brew install nasm
nasm -version
```

### Linux (Ubuntu/Debian)

```bash
sudo apt-get install nasm
nasm -version
```

## Building

### Mouse Driver

```bash
cd drivers/mouse
nasm -f bin -o mouse.com Mouse.asm
```

**Output:** `mouse.com` (executable)

### Bouncing Ball Demo

```bash
cd demos/01-bouncing-ball
nasm -f bin -o BB.com BB.asm
```

**Output:** `BB.com` (executable)

### Troubleshooting

**Error: `constant.inc: No such file or directory`**
- Make sure `constant.inc` is in the same directory as `Mouse.asm`
- Or use absolute path: `nasm -f bin -o mouse.com -i /path/to/inc/ Mouse.asm`

**Error: `invalid operand size for instruction`**
- Check CPU directive: Should be `CPU 186` for NEC V40 compatibility
- Some 186-specific instructions (like `PUSH imm`) may fail on older NASM versions

**Error: `jmp far` or similar invalid syntax**
- Use `jmp far [cs:label]` or `retf` syntax
- NASM syntax differs from MASM/TASM

## Running on Real Hardware

### Olivetti PC1

1. Copy `mouse.com` and `BB.com` to a DOS floppy or hard disk
2. Boot to DOS
3. Load driver: `mouse.com /I /M`
4. Run demo: `BB.com`
5. Press ESC to exit

### Emulation

#### DOSBox

1. Create `dosbox.conf`:
```ini
[cpu]
core=normal
cputype=auto
cycles=fixed 5000

[mixer]
rate=44100

[dos]
xms=true
```

2. Copy your COM files to a folder
3. Run DOSBox and mount that folder:
```bash
mount c: /path/to/folder
c:
mouse.com /I /M
BB.com
```

#### PCem / 86Box

1. Configure virtual machine:
   - CPU: NEC V40
   - RAM: 512 KB
   - Video: Olivetti PC1 or compatible
   - BIOS: PC1 BIOS
2. Create DOS boot disk
3. Copy COM files to virtual drive
4. Boot and run as above

## Building for Different Targets

### Customize CPU Target

Edit the `CPU` directive in the source:

```asm
CPU 186     ; NEC V40 (186-compatible)
CPU 8086    ; Standard 8086 (no 186 instructions)
CPU 286     ; 286 and up
```

The current demos require **186** (for instructions like `PUSH imm`, `IMUL reg,imm`).

### Output Formats

Current setup uses `-f bin` (raw binary) → `ORG 100h` → COM file.

To create SYS driver instead:

```bash
nasm -f bin -o mouse.sys Mouse.asm
```

(Would need to adjust ORG and entry point logic)

## Development Workflow

### 1. Edit

Edit `.asm` files in your text editor.

### 2. Assemble

```bash
nasm -f bin -o output.com input.asm
```

### 3. Test on Emulator

```bash
dosbox -conf dosbox.conf
# Inside DOSBox:
output.com
```

### 4. Debug

Use NASM listing output to map addresses:

```bash
nasm -f bin -o output.com input.asm -l output.lst
```

The `.lst` file shows bytecode and addresses for each instruction.

## Optimization Tips

**Code size:**
- Use short jumps when possible (`jz short label`)
- Reuse registers to avoid temporary variables
- Use `xchg` instead of `mov` pair (same size, avoids register blocking)

**Timing:**
- Avoid repeated `OUT` instructions (use register pre-loads)
- Cache frequently-read BIOS data in registers
- Minimize INT calls in tight loops

## Helpful Resources

- [NASM Manual](https://www.nasm.us/doc/)
- [x86-64 Assembly Guide](https://cs.brown.edu/courses/cs033/docs/guides/x86.html) (applicable to 8086/186)
- [DOS/BIOS Interrupt Reference](http://www.ctyme.com/intr/cat-all.htm)
- Simone Riminucci's source code comments

## Next Steps

- Modify sprites and masks in the source
- Extend physics (gravity, acceleration)
- Add new demos using the same framework
- Push to GitHub for collaboration
