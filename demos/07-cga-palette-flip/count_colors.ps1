# Count unique colors for cgaflip7/8
# Each color = R*256 + GB (unique integer key)

# Gradient tables as flat arrays: R0, GB0, R1, GB1, ...
$sunset = 1,0x03, 2,0x04, 2,0x05, 3,0x06, 3,0x07, 4,0x07, 4,0x06, 5,0x06, 5,0x05, 6,0x05, 6,0x04, 7,0x04, 7,0x03, 7,0x02, 7,0x01, 7,0x00, 7,0x00, 7,0x10, 7,0x10, 7,0x20, 7,0x20, 7,0x30, 7,0x30, 7,0x40, 7,0x40, 7,0x50, 7,0x50, 7,0x60, 7,0x60, 7,0x70, 7,0x70, 7,0x71, 7,0x72, 7,0x73
$rainbow = 7,0x00, 7,0x10, 7,0x20, 7,0x30, 7,0x40, 7,0x50, 7,0x70, 6,0x70, 5,0x70, 4,0x70, 3,0x70, 2,0x70, 0,0x70, 0,0x71, 0,0x72, 0,0x73, 0,0x75, 0,0x77, 0,0x67, 0,0x57, 0,0x47, 0,0x37, 0,0x27, 0,0x17, 0,0x07, 1,0x07, 2,0x07, 3,0x07, 4,0x07, 5,0x07, 5,0x06, 6,0x05, 7,0x04, 7,0x02
$cubehelix = 0,0x00, 0,0x01, 0,0x02, 0,0x13, 0,0x24, 0,0x35, 1,0x45, 1,0x55, 2,0x64, 3,0x63, 4,0x52, 5,0x41, 5,0x30, 6,0x20, 6,0x10, 6,0x01, 6,0x02, 5,0x03, 5,0x04, 4,0x15, 3,0x26, 3,0x37, 3,0x57, 4,0x67, 5,0x76, 5,0x75, 6,0x74, 6,0x63, 7,0x53, 7,0x43, 7,0x34, 7,0x45, 7,0x66, 7,0x77
$tred = 0,0x00, 1,0x00, 1,0x00, 2,0x00, 2,0x00, 3,0x00, 3,0x00, 4,0x00, 4,0x00, 5,0x00, 5,0x00, 6,0x00, 6,0x00, 7,0x00, 7,0x00, 7,0x10, 7,0x10, 7,0x20, 7,0x20, 7,0x30, 7,0x30, 7,0x40, 7,0x40, 7,0x50, 7,0x50, 7,0x51, 7,0x62, 7,0x62, 7,0x63, 7,0x63, 7,0x74, 7,0x75, 7,0x76, 7,0x77
$tgreen = 0,0x00, 0,0x10, 0,0x10, 0,0x20, 0,0x20, 0,0x30, 0,0x30, 0,0x40, 0,0x40, 0,0x50, 0,0x50, 0,0x60, 0,0x60, 0,0x70, 0,0x70, 1,0x70, 1,0x70, 2,0x70, 2,0x70, 3,0x70, 3,0x70, 4,0x70, 4,0x70, 5,0x70, 5,0x71, 5,0x71, 6,0x72, 6,0x72, 6,0x73, 6,0x73, 7,0x74, 7,0x75, 7,0x76, 7,0x77
$tblue = 0,0x00, 0,0x01, 0,0x01, 0,0x02, 0,0x02, 0,0x03, 0,0x03, 0,0x04, 0,0x04, 0,0x05, 0,0x05, 0,0x06, 0,0x06, 0,0x07, 0,0x07, 0,0x17, 0,0x17, 0,0x27, 0,0x27, 0,0x37, 0,0x37, 0,0x47, 0,0x47, 0,0x57, 1,0x57, 1,0x57, 2,0x67, 2,0x67, 3,0x67, 3,0x67, 4,0x77, 5,0x77, 6,0x77, 7,0x77

function Get-Step([int[]]$table, [int]$step) {
    $i = [Math]::Min($step, 33) * 2
    return @($table[$i], $table[$i+1])
}

function Build-Buffer([int[]]$col1, [int[]]$col2, [int[]]$col3) {
    # N%3: 0->col1, 1->col3, 2->col2
    $tables = @($col1, $col3, $col2)
    $e2set = [System.Collections.Generic.HashSet[int]]::new()
    $e3set = [System.Collections.Generic.HashSet[int]]::new()
    for ($n = 0; $n -lt 100; $n++) {
        $step = [Math]::Floor($n / 3)
        $cidx = $n % 3
        $c = Get-Step $tables[$cidx] $step
        [int]$r = $c[0]; [int]$gb = $c[1]
        [void]$e2set.Add($r * 256 + $gb)
        # Darken
        [int]$dr = [Math]::Max(0, $r - 1)
        [int]$g = [Math]::Floor($gb / 16)
        [int]$b = $gb % 16
        [int]$dg = [Math]::Max(0, $g - 1)
        [int]$db = [Math]::Max(0, $b - 1)
        [int]$dgb = $dg * 16 + $db
        [void]$e3set.Add($dr * 256 + $dgb)
    }
    return @{ e2 = $e2set; e3 = $e3set }
}

$m0 = Build-Buffer $sunset $rainbow $cubehelix
$m1 = Build-Buffer $tred $tgreen $tblue

# Presets as color keys
$auto0 = @(2*256+0x11, 0*256+0x33, 0*256+0x22, 1*256+0x02, 1*256+0x01)
$auto1 = @(1*256+0x11, 0*256+0x20, 0*256+0x10, 0*256+0x03, 0*256+0x02)
$bg = 0

function Count-Unique([System.Collections.Generic.HashSet[int]]$e2, [System.Collections.Generic.HashSet[int]]$e3, [int[]]$static, [bool]$includeE3) {
    $all = [System.Collections.Generic.HashSet[int]]::new($e2)
    if ($includeE3) { $all.UnionWith($e3) }
    [void]$all.Add($bg)
    if ($static) { foreach ($s in $static) { [void]$all.Add($s) } }
    return $all.Count
}

Write-Host "=== CGAFLIP7 (E2 only) ==="
Write-Host "Mode 0 black: $(Count-Unique $m0.e2 $m0.e3 @() $false) unique colors"
Write-Host "Mode 0 auto:  $(Count-Unique $m0.e2 $m0.e3 $auto0 $false) unique colors"
Write-Host "Mode 1 black: $(Count-Unique $m1.e2 $m1.e3 @() $false) unique colors"
Write-Host "Mode 1 auto:  $(Count-Unique $m1.e2 $m1.e3 $auto1 $false) unique colors"
Write-Host ""
Write-Host "=== CGAFLIP8 (E2 + E3) ==="
Write-Host "Mode 0 black: $(Count-Unique $m0.e2 $m0.e3 @() $true) unique colors"
Write-Host "Mode 0 auto:  $(Count-Unique $m0.e2 $m0.e3 $auto0 $true) unique colors"
Write-Host "Mode 1 black: $(Count-Unique $m1.e2 $m1.e3 @() $true) unique colors"
Write-Host "Mode 1 auto:  $(Count-Unique $m1.e2 $m1.e3 $auto1 $true) unique colors"
Write-Host ""
Write-Host "E2 unique m0: $($m0.e2.Count)  E3 unique m0: $($m0.e3.Count)"
Write-Host "E2 unique m1: $($m1.e2.Count)  E3 unique m1: $($m1.e3.Count)"
