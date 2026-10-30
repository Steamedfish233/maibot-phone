# Generates MaiBot launcher/notification icon assets from the official OneKey mascot artwork.
# Source: branding/sprout-source.png (1024x1024 ARGB).
#   - the artwork already contains a cream rounded tile on a transparent margin
#   - tile bbox   : x=46..984, y=36..992   -> legacy / round launcher icons, header brand mark
#   - mascot bbox : x=104..968, y=141..973 -> adaptive-icon foreground (tile stripped)
Add-Type -AssemblyName System.Drawing

$ErrorActionPreference = 'Stop'

$root    = Split-Path -Parent $PSScriptRoot
$srcPath = Join-Path $root 'branding\sprout-source.png'
$res     = Join-Path $root 'app\src\main\res'

if (-not (Test-Path $srcPath)) { throw "brand source not found: $srcPath" }

$tileRect   = New-Object System.Drawing.Rectangle 46, 36, 938, 956
$mascotRect = New-Object System.Drawing.Rectangle 104, 141, 865, 833

$tileColor = [System.Drawing.ColorTranslator]::FromHtml('#FDF8EA')
$src = [System.Drawing.Bitmap]::FromFile($srcPath)

function New-RoundedPath {
    param([int]$w, [int]$h, [double]$radius)
    $p = New-Object System.Drawing.Drawing2D.GraphicsPath
    $d = [double]($radius * 2)
    $p.AddArc(0, 0, $d, $d, 180, 90)
    $p.AddArc($w - $d, 0, $d, $d, 270, 90)
    $p.AddArc($w - $d, $h - $d, $d, $d, 0, 90)
    $p.AddArc(0, $h - $d, $d, $d, 90, 90)
    $p.CloseFigure()
    return $p
}

function New-Graphics {
    param([System.Drawing.Bitmap]$bmp)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode      = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $g.InterpolationMode  = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
    $g.PixelOffsetMode    = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
    $g.CompositingQuality = [System.Drawing.Drawing2D.CompositingQuality]::HighQuality
    return $g
}

# Legacy launcher icon: cream rounded tile with the mascot artwork on it.
function New-TileIcon {
    param([int]$size)
    $bmp = New-Object System.Drawing.Bitmap $size, $size
    $g = New-Graphics $bmp
    $g.Clear([System.Drawing.Color]::Transparent)
    $path  = New-RoundedPath $size $size ($size * 0.22)
    $brush = New-Object System.Drawing.SolidBrush $tileColor
    $g.FillPath($brush, $path)
    $dst = New-Object System.Drawing.Rectangle 0, 0, $size, $size
    $g.DrawImage($src, $dst, $tileRect, [System.Drawing.GraphicsUnit]::Pixel)
    $g.Dispose(); $brush.Dispose(); $path.Dispose()
    return $bmp
}

# Round launcher icon: same artwork, circular mask.
function New-RoundIcon {
    param([int]$size)
    $bmp = New-Object System.Drawing.Bitmap $size, $size
    $g = New-Graphics $bmp
    $g.Clear([System.Drawing.Color]::Transparent)
    $clip = New-Object System.Drawing.Drawing2D.GraphicsPath
    $clip.AddEllipse(0, 0, $size, $size)
    $g.SetClip($clip)
    $brush = New-Object System.Drawing.SolidBrush $tileColor
    $g.FillRectangle($brush, 0, 0, $size, $size)
    $dst = New-Object System.Drawing.Rectangle 0, 0, $size, $size
    $g.DrawImage($src, $dst, $tileRect, [System.Drawing.GraphicsUnit]::Pixel)
    $g.Dispose(); $brush.Dispose(); $clip.Dispose()
    return $bmp
}

# Adaptive foreground: transparent canvas, mascot only, inside the safe zone.
function New-Foreground {
    param([int]$size)
    $bmp = New-Object System.Drawing.Bitmap $size, $size
    $g = New-Graphics $bmp
    $g.Clear([System.Drawing.Color]::Transparent)
    $m = [int]($size * 0.55)
    $dst = New-Object System.Drawing.Rectangle ([int](($size - $m) / 2)), ([int](($size - $m) / 2)), $m, $m
    $g.DrawImage($src, $dst, $mascotRect, [System.Drawing.GraphicsUnit]::Pixel)
    $g.Dispose()
    return $bmp
}

$densities = [ordered]@{
    'mdpi'    = 48
    'hdpi'    = 72
    'xhdpi'   = 96
    'xxhdpi'  = 144
    'xxxhdpi' = 192
}

foreach ($d in $densities.Keys) {
    $dir = Join-Path $res "mipmap-$d"
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    $s = $densities[$d]

    $tile = New-TileIcon $s
    $tile.Save((Join-Path $dir 'ic_launcher.png'), [System.Drawing.Imaging.ImageFormat]::Png)
    $tile.Dispose()

    $round = New-RoundIcon $s
    $round.Save((Join-Path $dir 'ic_launcher_round.png'), [System.Drawing.Imaging.ImageFormat]::Png)
    $round.Dispose()

    # Adaptive foreground uses the 108dp canvas.
    $fgSize = [int][math]::Round($s * 108 / 48)
    $fg = New-Foreground $fgSize
    $fg.Save((Join-Path $dir 'ic_launcher_foreground.png'), [System.Drawing.Imaging.ImageFormat]::Png)
    $fg.Dispose()

    Write-Output "mipmap-$d : ic_launcher ${s}px, round ${s}px, foreground ${fgSize}px"
}

# Header brand mark for the in-app title row.
$brandDir = Join-Path $res 'drawable-nodpi'
New-Item -ItemType Directory -Force -Path $brandDir | Out-Null
$brand = New-TileIcon 192
$brand.Save((Join-Path $brandDir 'ic_brand.png'), [System.Drawing.Imaging.ImageFormat]::Png)
$brand.Dispose()
Write-Output 'drawable-nodpi : ic_brand.png 192px'

$src.Dispose()
Write-Output 'icons generated.'
