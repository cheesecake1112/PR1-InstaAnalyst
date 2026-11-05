$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing

$root = Split-Path -Parent $PSScriptRoot
$res = Join-Path $root 'android/app/src/main/res'
$brand = Join-Path $root 'assets/branding'
New-Item -ItemType Directory -Force -Path $brand | Out-Null

function New-RoundRectPath([float]$x, [float]$y, [float]$width, [float]$height, [float]$radius) {
    $path = [System.Drawing.Drawing2D.GraphicsPath]::new()
    $diameter = $radius * 2
    $path.AddArc($x, $y, $diameter, $diameter, 180, 90)
    $path.AddArc($x + $width - $diameter, $y, $diameter, $diameter, 270, 90)
    $path.AddArc($x + $width - $diameter, $y + $height - $diameter, $diameter, $diameter, 0, 90)
    $path.AddArc($x, $y + $height - $diameter, $diameter, $diameter, 90, 90)
    $path.CloseFigure()
    return $path
}

function Draw-Bust($graphics, [float]$x, [float]$y, [float]$width, [float]$height, $brush) {
    $path = [System.Drawing.Drawing2D.GraphicsPath]::new()
    $path.StartFigure()
    $path.AddLine($x, $y + $height, $x, $y + $height * 0.68)
    $path.AddBezier(
        [System.Drawing.PointF]::new($x, $y + $height * 0.68),
        [System.Drawing.PointF]::new($x, $y + $height * 0.18),
        [System.Drawing.PointF]::new($x + $width * 0.18, $y),
        [System.Drawing.PointF]::new($x + $width * 0.5, $y)
    )
    $path.AddBezier(
        [System.Drawing.PointF]::new($x + $width * 0.5, $y),
        [System.Drawing.PointF]::new($x + $width * 0.82, $y),
        [System.Drawing.PointF]::new($x + $width, $y + $height * 0.18),
        [System.Drawing.PointF]::new($x + $width, $y + $height * 0.68)
    )
    $path.AddLine($x + $width, $y + $height * 0.68, $x + $width, $y + $height)
    $path.CloseFigure()
    $graphics.FillPath($brush, $path)
    $path.Dispose()
}

function Draw-Mark($graphics) {
    $white = [System.Drawing.SolidBrush]::new([System.Drawing.Color]::FromArgb(255, 255, 255, 255))
    $softWhite = [System.Drawing.SolidBrush]::new([System.Drawing.Color]::FromArgb(205, 255, 255, 255))
    $mint = [System.Drawing.SolidBrush]::new([System.Drawing.Color]::FromArgb(255, 105, 235, 197))
    $deep = [System.Drawing.Pen]::new([System.Drawing.Color]::FromArgb(255, 73, 52, 201), 13)
    $deep.StartCap = [System.Drawing.Drawing2D.LineCap]::Round
    $deep.EndCap = [System.Drawing.Drawing2D.LineCap]::Round
    $deep.LineJoin = [System.Drawing.Drawing2D.LineJoin]::Round

    Draw-Bust $graphics 68 326 164 100 $softWhite
    Draw-Bust $graphics 280 326 164 100 $softWhite
    $graphics.FillEllipse($softWhite, 121, 236, 62, 62)
    $graphics.FillEllipse($softWhite, 329, 236, 62, 62)

    Draw-Bust $graphics 122 238 268 194 $white
    $graphics.FillEllipse($white, 208, 112, 96, 96)

    $graphics.FillEllipse($mint, 329, 329, 100, 100)
    $graphics.DrawLine($deep, 357, 378, 373, 394)
    $graphics.DrawLine($deep, 373, 394, 405, 359)

    $white.Dispose()
    $softWhite.Dispose()
    $mint.Dispose()
    $deep.Dispose()
}

function New-Foreground([int]$size, [string]$path) {
    $mark = [System.Drawing.Bitmap]::new(512, 512, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $g = [System.Drawing.Graphics]::FromImage($mark)
    $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $g.Clear([System.Drawing.Color]::Transparent)
    Draw-Mark $g
    $g.Dispose()

    $bitmap = [System.Drawing.Bitmap]::new($size, $size, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $g = [System.Drawing.Graphics]::FromImage($bitmap)
    $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::HighQuality
    $g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
    $g.Clear([System.Drawing.Color]::Transparent)
    $margin = [int][Math]::Round($size * 0.10)
    $g.DrawImage($mark, $margin, $margin, $size - 2 * $margin, $size - 2 * $margin)
    $bitmap.Save($path, [System.Drawing.Imaging.ImageFormat]::Png)
    $g.Dispose()
    $bitmap.Dispose()
    $mark.Dispose()
}

function New-LegacyIcon([int]$size, [string]$path) {
    $bitmap = [System.Drawing.Bitmap]::new($size, $size, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $g = [System.Drawing.Graphics]::FromImage($bitmap)
    $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::HighQuality
    $g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
    $g.Clear([System.Drawing.Color]::Transparent)
    $g.ScaleTransform($size / 512.0, $size / 512.0)

    $tile = New-RoundRectPath 0 0 512 512 116
    $background = [System.Drawing.Drawing2D.LinearGradientBrush]::new(
        [System.Drawing.Rectangle]::new(0, 0, 512, 512),
        [System.Drawing.Color]::FromArgb(255, 132, 99, 255),
        [System.Drawing.Color]::FromArgb(255, 67, 48, 187),
        48
    )
    $g.FillPath($background, $tile)
    Draw-Mark $g
    $bitmap.Save($path, [System.Drawing.Imaging.ImageFormat]::Png)

    $background.Dispose()
    $tile.Dispose()
    $g.Dispose()
    $bitmap.Dispose()
}

New-LegacyIcon 1024 (Join-Path $brand 'socialscope-icon.png')
$logoWidth = 860
$logoHeight = 300
$logo = [System.Drawing.Bitmap]::new($logoWidth, $logoHeight, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
$logoGraphics = [System.Drawing.Graphics]::FromImage($logo)
$logoGraphics.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::HighQuality
$logoGraphics.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
$logoGraphics.Clear([System.Drawing.Color]::Transparent)
$iconImage = [System.Drawing.Image]::FromFile((Join-Path $brand 'socialscope-icon.png'))
$logoGraphics.DrawImage($iconImage, 20, 20, 260, 260)
$wordFont = [System.Drawing.Font]::new('Segoe UI', 72, [System.Drawing.FontStyle]::Bold, [System.Drawing.GraphicsUnit]::Pixel)
$taglineFont = [System.Drawing.Font]::new('Segoe UI', 27, [System.Drawing.FontStyle]::Regular, [System.Drawing.GraphicsUnit]::Pixel)
$wordBrush = [System.Drawing.SolidBrush]::new([System.Drawing.Color]::FromArgb(255, 40, 37, 62))
$taglineBrush = [System.Drawing.SolidBrush]::new([System.Drawing.Color]::FromArgb(255, 105, 102, 124))
$logoGraphics.DrawString('SocialScope', $wordFont, $wordBrush, 315, 69)
$logoGraphics.DrawString('Your audience, clearly.', $taglineFont, $taglineBrush, 320, 168)
$logo.Save((Join-Path $brand 'socialscope-logo.png'), [System.Drawing.Imaging.ImageFormat]::Png)
$darkLogo = [System.Drawing.Bitmap]::new($logoWidth, $logoHeight, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
$darkGraphics = [System.Drawing.Graphics]::FromImage($darkLogo)
$darkGraphics.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::HighQuality
$darkGraphics.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
$darkGraphics.Clear([System.Drawing.Color]::Transparent)
$darkGraphics.DrawImage($iconImage, 20, 20, 260, 260)
$darkWordBrush = [System.Drawing.SolidBrush]::new([System.Drawing.Color]::FromArgb(255, 247, 246, 250))
$darkTaglineBrush = [System.Drawing.SolidBrush]::new([System.Drawing.Color]::FromArgb(255, 199, 195, 215))
$darkGraphics.DrawString('SocialScope', $wordFont, $darkWordBrush, 315, 69)
$darkGraphics.DrawString('Your audience, clearly.', $taglineFont, $darkTaglineBrush, 320, 168)
$darkLogo.Save((Join-Path $brand 'socialscope-logo-dark.png'), [System.Drawing.Imaging.ImageFormat]::Png)
$darkWordBrush.Dispose()
$darkTaglineBrush.Dispose()
$darkGraphics.Dispose()
$darkLogo.Dispose()
$wordBrush.Dispose()
$taglineBrush.Dispose()
$wordFont.Dispose()
$taglineFont.Dispose()
$iconImage.Dispose()
$logoGraphics.Dispose()
$logo.Dispose()

$densities = @{
    'mipmap-mdpi' = 48
    'mipmap-hdpi' = 72
    'mipmap-xhdpi' = 96
    'mipmap-xxhdpi' = 144
    'mipmap-xxxhdpi' = 192
}
foreach ($density in $densities.Keys) {
    $directory = Join-Path $res $density
    New-Item -ItemType Directory -Force -Path $directory | Out-Null
    New-LegacyIcon $densities[$density] (Join-Path $directory 'ic_launcher.png')
}

$drawable = Join-Path $res 'drawable'
$drawableNodpi = Join-Path $res 'drawable-nodpi'
$adaptive = Join-Path $res 'mipmap-anydpi-v26'
New-Item -ItemType Directory -Force -Path $drawable, $drawableNodpi, $adaptive | Out-Null
New-Foreground 432 (Join-Path $drawableNodpi 'ic_launcher_foreground.png')

@'
<shape xmlns:android="http://schemas.android.com/apk/res/android" android:shape="rectangle">
    <gradient android:type="linear" android:angle="135" android:startColor="#8463FF" android:endColor="#4330BB" />
</shape>
'@ | Set-Content -Encoding UTF8 (Join-Path $drawable 'ic_launcher_background.xml')

@'
<adaptive-icon xmlns:android="http://schemas.android.com/apk/res/android">
    <background android:drawable="@drawable/ic_launcher_background" />
    <foreground android:drawable="@drawable/ic_launcher_foreground" />
</adaptive-icon>
'@ | Set-Content -Encoding UTF8 (Join-Path $adaptive 'ic_launcher.xml')
