# PowerShell script to create test BMP files for V6355 raster bar testing

$width = 160
$height = 200
$bpp = 4  # bits per pixel

# Calculate sizes
$bytesPerRow = 80  # 160 pixels * 4 bits / 8 = 80 bytes
$rowPadding = 0    # 80 is already multiple of 4
$paddedRowSize = $bytesPerRow + $rowPadding

# Palette (BGRA format, 16 colors)
$palette = @(
    0,0,0,0,         # 0: Black (transparent)
    255,0,0,0,       # 1: Blue
    0,255,0,0,       # 2: Green
    255,255,0,0,     # 3: Cyan
    0,0,255,0,       # 4: Red
    255,0,255,0,     # 5: Magenta
    0,128,255,0,     # 6: Brown
    192,192,192,0,   # 7: Light gray
    128,128,128,0,   # 8: Dark gray
    255,128,128,0,   # 9: Light blue
    128,255,128,0,   # 10: Light green
    255,255,128,0,   # 11: Light cyan
    128,128,255,0,   # 12: Light red
    255,128,255,0,   # 13: Light magenta
    128,255,255,0,   # 14: Yellow
    255,255,255,0    # 15: White
)

$pixelDataOffset = 14 + 40 + 64  # BMP header + info header + palette
$fileSize = $pixelDataOffset + ($paddedRowSize * $height)

function Create-BandsBMP {
    param([string]$filename, [int]$bandHeight = 10)
    
    $bytes = New-Object System.Collections.ArrayList
    
    # BMP Header (14 bytes)
    $bytes.AddRange([byte[]](0x42, 0x4D))  # 'BM'
    $bytes.AddRange([BitConverter]::GetBytes([uint32]$fileSize))
    $bytes.AddRange([byte[]](0,0,0,0))  # Reserved
    $bytes.AddRange([BitConverter]::GetBytes([uint32]$pixelDataOffset))
    
    # Info Header (40 bytes)
    $bytes.AddRange([BitConverter]::GetBytes([uint32]40))
    $bytes.AddRange([BitConverter]::GetBytes([int32]$width))
    $bytes.AddRange([BitConverter]::GetBytes([int32]$height))
    $bytes.AddRange([BitConverter]::GetBytes([uint16]1))   # planes
    $bytes.AddRange([BitConverter]::GetBytes([uint16]$bpp))
    $bytes.AddRange([BitConverter]::GetBytes([uint32]0))   # compression
    $bytes.AddRange([BitConverter]::GetBytes([uint32]0))   # image size
    $bytes.AddRange([BitConverter]::GetBytes([int32]0))    # X ppm
    $bytes.AddRange([BitConverter]::GetBytes([int32]0))    # Y ppm
    $bytes.AddRange([BitConverter]::GetBytes([uint32]16))  # colors used
    $bytes.AddRange([BitConverter]::GetBytes([uint32]16))  # important
    
    # Palette
    $bytes.AddRange([byte[]]$palette)
    
    # Pixel data (bottom-up)
    for ($y = 0; $y -lt $height; $y++) {
        $bandNum = [Math]::Floor($y / $bandHeight)
        $isBlackBand = ($bandNum % 2) -eq 0
        
        for ($x = 0; $x -lt $width; $x += 2) {
            if ($isBlackBand) {
                $bytes.Add([byte]0x00) | Out-Null
            } else {
                $color = (([Math]::Floor($x / 4) % 7) + 1)
                $bytes.Add([byte](($color -shl 4) -bor $color)) | Out-Null
            }
        }
    }
    
    [System.IO.File]::WriteAllBytes($filename, [byte[]]$bytes.ToArray())
    Write-Host "Created $filename (horizontal bands test)"
}

function Create-VStripeBMP {
    param([string]$filename)
    
    $bytes = New-Object System.Collections.ArrayList
    
    # BMP Header
    $bytes.AddRange([byte[]](0x42, 0x4D))
    $bytes.AddRange([BitConverter]::GetBytes([uint32]$fileSize))
    $bytes.AddRange([byte[]](0,0,0,0))
    $bytes.AddRange([BitConverter]::GetBytes([uint32]$pixelDataOffset))
    
    # Info Header
    $bytes.AddRange([BitConverter]::GetBytes([uint32]40))
    $bytes.AddRange([BitConverter]::GetBytes([int32]$width))
    $bytes.AddRange([BitConverter]::GetBytes([int32]$height))
    $bytes.AddRange([BitConverter]::GetBytes([uint16]1))
    $bytes.AddRange([BitConverter]::GetBytes([uint16]$bpp))
    $bytes.AddRange([BitConverter]::GetBytes([uint32]0))
    $bytes.AddRange([BitConverter]::GetBytes([uint32]0))
    $bytes.AddRange([BitConverter]::GetBytes([int32]0))
    $bytes.AddRange([BitConverter]::GetBytes([int32]0))
    $bytes.AddRange([BitConverter]::GetBytes([uint32]16))
    $bytes.AddRange([BitConverter]::GetBytes([uint32]16))
    
    # Palette
    $bytes.AddRange([byte[]]$palette)
    
    # Pixel data - left half black, right half colored
    for ($y = 0; $y -lt $height; $y++) {
        for ($x = 0; $x -lt $width; $x += 2) {
            if ($x -lt 80) {
                # Left half: color 0
                $bytes.Add([byte]0x00) | Out-Null
            } else {
                # Right half: colored
                $color = (([Math]::Floor($y / 10) % 7) + 1)
                $bytes.Add([byte](($color -shl 4) -bor $color)) | Out-Null
            }
        }
    }
    
    [System.IO.File]::WriteAllBytes($filename, [byte[]]$bytes.ToArray())
    Write-Host "Created $filename (vertical stripe test)"
}

# Create test images
Create-BandsBMP "test_bands.bmp" 10
Create-VStripeBMP "test_vstripe.bmp"

Write-Host ""
Write-Host "Test images created!"
Write-Host "- test_bands.bmp: Horizontal bands (alternating black/colored)"
Write-Host "- test_vstripe.bmp: Vertical split (left=black, right=colored)"
Write-Host ""
Write-Host "Test theory:"
Write-Host "  If bars show through black bands only -> per-scanline detection"
Write-Host "  If bars show through left half -> per-pixel transparency"
Write-Host "  If bars only in border -> blocked by any non-zero pixel"
