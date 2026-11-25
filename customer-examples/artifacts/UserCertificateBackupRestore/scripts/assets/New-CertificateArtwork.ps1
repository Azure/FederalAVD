#Requires -Version 5.1
[CmdletBinding()]
param()
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing
. (Join-Path (Split-Path $PSScriptRoot -Parent) 'Set-FileZone.ps1')
$outputs = @('certificate-banner.png', 'certificate-backup-banner.png', 'certificate-restore.ico', 'certificate-backup.ico')
$before = @(Get-ChildItem -LiteralPath $PSScriptRoot -Force -File | Select-Object FullName, Length, LastWriteTimeUtc)
$minimumZones = @{}
foreach ($name in $outputs) {
    $path = Join-Path $PSScriptRoot $name
    $minimumZones[$path] = if ([IO.File]::Exists($path) -and (Read-ZoneId $path) -eq 4) { 4 } else { 3 }
}
$resources = [Collections.Generic.List[IDisposable]]::new()
function New-ArtBrush([string]$Color) {
    $brush = [Drawing.SolidBrush]::new([Drawing.ColorTranslator]::FromHtml($Color))
    $resources.Add($brush)
    return $brush
}
function New-ArtPen([string]$Color, [single]$Width) {
    $pen = [Drawing.Pen]::new([Drawing.ColorTranslator]::FromHtml($Color), $Width)
    $pen.StartCap = $pen.EndCap = [Drawing.Drawing2D.LineCap]::Round
    $pen.LineJoin = [Drawing.Drawing2D.LineJoin]::Round
    $resources.Add($pen)
    return $pen
}
function Draw-Background([Drawing.Graphics]$Graphics, [int]$Width, [int]$Height) {
    $gradient = [Drawing.Drawing2D.LinearGradientBrush]::new(
        [Drawing.Rectangle]::new(0, 0, $Width, $Height),
        [Drawing.ColorTranslator]::FromHtml('#003B71'),
        [Drawing.ColorTranslator]::FromHtml('#0078D4'), [single]0)
    try { $Graphics.FillRectangle($gradient, 0, 0, $Width, $Height) }
    finally { $gradient.Dispose() }
}
function Draw-CertificateSymbol([Drawing.Graphics]$Graphics, [string]$Role) {
    $paper = New-ArtBrush '#FFFFFF'
    $blue = New-ArtBrush '#0078D4'
    $pale = New-ArtBrush '#B7E4FF'
    $Graphics.FillRectangle((New-ArtBrush '#034A84'), 54, 39, 128, 166)
    $Graphics.FillRectangle($paper, 46, 31, 128, 166)
    $Graphics.FillRectangle((New-ArtBrush '#E8F5FF'), 46, 31, 128, 32)
    $Graphics.FillRectangle($blue, 61, 45, 72, 6)
    $Graphics.FillRectangle($pale, 64, 81, 88, 7)
    $Graphics.FillRectangle($pale, 64, 101, 66, 6)
    $Graphics.FillRectangle($pale, 64, 119, 78, 6)
    $Graphics.FillPolygon($blue, [Drawing.PointF[]]@(
        [Drawing.PointF]::new(74, 159), [Drawing.PointF]::new(71, 184),
        [Drawing.PointF]::new(84, 176), [Drawing.PointF]::new(97, 184),
        [Drawing.PointF]::new(94, 159)))
    $Graphics.FillEllipse($blue, 68, 141, 32, 32)
    $Graphics.DrawEllipse((New-ArtPen '#B7E4FF' 2), 74, 147, 20, 20)
    $Graphics.FillEllipse((New-ArtBrush '#003B71'), 128, 128, 116, 116)
    $Graphics.DrawEllipse((New-ArtPen '#7AC9FF' 2), 128, 128, 116, 116)
    $whitePen = New-ArtPen '#FFFFFF' 8
    if ($Role -eq 'Restore') {
        # Open shackle and return arrow distinguish unlock/restore from backup.
        $Graphics.DrawArc($whitePen, 158, 145, 48, 48, 180, 205)
        $Graphics.DrawLine($whitePen, 158, 169, 158, 187)
        $Graphics.FillRectangle($paper, 148, 186, 72, 42)
        $Graphics.FillEllipse((New-ArtBrush '#003B71'), 179, 198, 10, 10)
        $Graphics.DrawLine((New-ArtPen '#003B71' 4), 184, 206, 184, 216)
        $arrow = New-ArtPen '#B7E4FF' 7
        $Graphics.DrawArc($arrow, 8, 75, 66, 103, 105, 200)
        $Graphics.FillPolygon($pale, [Drawing.PointF[]]@(
            [Drawing.PointF]::new(69, 84), [Drawing.PointF]::new(48, 88), [Drawing.PointF]::new(61, 106)))
    } else {
        $Graphics.FillRectangle($paper, 148, 188, 74, 40)
        $Graphics.FillRectangle($paper, 142, 183, 86, 11)
        $Graphics.FillRectangle((New-ArtBrush '#0078D4'), 173, 205, 24, 5)
        $Graphics.DrawLine($whitePen, 185, 145, 185, 174)
        $Graphics.DrawLine($whitePen, 170, 163, 185, 178)
        $Graphics.DrawLine($whitePen, 200, 163, 185, 178)
    }
}
function New-ArtBitmap([string]$Role, [int]$Size = 0) {
    $width = if ($Size) { $Size } else { 1200 }
    $height = if ($Size) { $Size } elseif ($Role -eq 'Backup') { 210 } else { 280 }
    $bitmap = [Drawing.Bitmap]::new($width, $height)
    $graphics = $null
    try {
        $graphics = [Drawing.Graphics]::FromImage($bitmap)
        $graphics.SmoothingMode = [Drawing.Drawing2D.SmoothingMode]::AntiAlias
        $graphics.PixelOffsetMode = [Drawing.Drawing2D.PixelOffsetMode]::HighQuality
        if ($Size) {
            $graphics.Clear([Drawing.Color]::Transparent)
            $graphics.FillEllipse((New-ArtBrush '#0078D4'), 0, 0, $Size, $Size)
            $graphics.ScaleTransform([single]($Size / 256.0), [single]($Size / 256.0))
        } else {
            Draw-Background $graphics $width $height
            $graphics.FillEllipse((New-ArtBrush '#086CB8'), 660, -300, 660, 620)
            $graphics.FillEllipse((New-ArtBrush '#1689DB'), 1060, 60, 400, 400)
            $graphics.DrawEllipse((New-ArtPen '#4BA6E8' 1.5), 795, -36, 360, 360)
            $graphics.TranslateTransform(830, 13)
            if ($Role -eq 'Backup') { $graphics.ScaleTransform([single]0.74, [single]0.74) }
        }
        Draw-CertificateSymbol $graphics $Role
        return $bitmap
    } catch { $bitmap.Dispose(); throw }
    finally { if ($null -ne $graphics) { $graphics.Dispose() } }
}
function Save-ArtIcon([string]$Role, [string]$Path) {
    $sizes = @(16, 24, 32, 48, 64, 128, 256)
    $frames = [Collections.Generic.List[byte[]]]::new()
    foreach ($size in $sizes) {
        $bitmap = New-ArtBitmap $Role $size
        $stream = [IO.MemoryStream]::new()
        try {
            $bitmap.Save($stream, [Drawing.Imaging.ImageFormat]::Png)
            $frames.Add($stream.ToArray())
        } finally { $stream.Dispose(); $bitmap.Dispose() }
    }
    $writer = [IO.BinaryWriter]::new([IO.File]::Open($Path, [IO.FileMode]::Create))
    try {
        $writer.Write([uint16]0)
        $writer.Write([uint16]1)
        $writer.Write([uint16]$sizes.Count)
        $offset = [uint32](6 + 16 * $sizes.Count)
        for ($i = 0; $i -lt $sizes.Count; $i++) {
            $dimension = if ($sizes[$i] -eq 256) { [byte]0 } else { [byte]$sizes[$i] }
            $writer.Write($dimension)
            $writer.Write($dimension)
            $writer.Write([byte]0)
            $writer.Write([byte]0)
            $writer.Write([uint16]1)
            $writer.Write([uint16]32)
            $writer.Write([uint32]$frames[$i].Length)
            $writer.Write($offset)
            $offset += [uint32]$frames[$i].Length
        }
        foreach ($frame in $frames) { $writer.Write($frame) }
    } finally { $writer.Dispose() }
}
try {
    foreach ($role in @('Restore', 'Backup')) {
        $bannerName = if ($role -eq 'Restore') { 'certificate-banner.png' } else { 'certificate-backup-banner.png' }
        $bitmap = New-ArtBitmap $role
        try { $bitmap.Save((Join-Path $PSScriptRoot $bannerName), [Drawing.Imaging.ImageFormat]::Png) }
        finally { $bitmap.Dispose() }
        Save-ArtIcon $role (Join-Path $PSScriptRoot ("certificate-$($role.ToLowerInvariant()).ico"))
    }
} finally {
    foreach ($resource in $resources) { $resource.Dispose() }
    foreach ($file in Get-ChildItem -LiteralPath $PSScriptRoot -Force -File) {
        $old = $before | Where-Object FullName -EQ $file.FullName | Select-Object -First 1
        if ($file.FullName -in $minimumZones.Keys) { Set-FileZone $file.FullName $minimumZones[$file.FullName] }
        elseif (-not $old -or $old.Length -ne $file.Length -or $old.LastWriteTimeUtc -ne $file.LastWriteTimeUtc) { Set-FileZone $file.FullName }
    }
}
Write-Host 'Generated restore/unlock and backup banners plus seven-resolution shortcut icons.'
