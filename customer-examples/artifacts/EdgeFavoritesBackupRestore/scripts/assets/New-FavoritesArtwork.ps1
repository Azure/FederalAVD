#requires -Version 5.1
<#
.SYNOPSIS
    Generates original favorites artwork locally; not run during installation.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing
$resources = [Collections.Generic.List[IDisposable]]::new()

function New-FavoritesArtBrush {
    param([string]$Color)
    $brush = [Drawing.SolidBrush]::new([Drawing.ColorTranslator]::FromHtml($Color))
    $resources.Add($brush)
    return $brush
}

function New-FavoritesArtPen {
    param([string]$Color, [single]$Width)
    $pen = [Drawing.Pen]::new([Drawing.ColorTranslator]::FromHtml($Color), $Width)
    $pen.StartCap = $pen.EndCap = [Drawing.Drawing2D.LineCap]::Round
    $pen.LineJoin = [Drawing.Drawing2D.LineJoin]::Round
    $resources.Add($pen)
    return $pen
}

function Draw-FavoritesSymbol {
    param([Drawing.Graphics]$Graphics, [string]$Role)
    $white = New-FavoritesArtBrush '#FFFFFF'
    $Graphics.FillRectangle((New-FavoritesArtBrush '#0757A8'), 45, 37, 160, 169)
    $Graphics.FillRectangle($white, 35, 27, 160, 169)
    $Graphics.FillRectangle((New-FavoritesArtBrush '#DFFAF3'), 35, 27, 160, 32)
    foreach ($x in @(49, 63, 77)) {
        $Graphics.FillEllipse((New-FavoritesArtBrush '#0ABDA6'), $x, 39, 6, 6)
    }
    $Graphics.FillRectangle((New-FavoritesArtBrush '#80E3D9'), 105, 39, 73, 6)
    $points = [Drawing.PointF[]]@(for ($i = 0; $i -lt 10; $i++) {
        $radius = if ($i % 2 -eq 0) { 43 } else { 20 }
        $angle = -[Math]::PI / 2 + $i * [Math]::PI / 5
        [Drawing.PointF]::new([single](108 + $radius * [Math]::Cos($angle)),
            [single](111 + $radius * [Math]::Sin($angle)))
    })
    $starGradient = [Drawing.Drawing2D.LinearGradientBrush]::new(
        [Drawing.Rectangle]::new(65, 68, 86, 86),
        [Drawing.ColorTranslator]::FromHtml('#26D88D'),
        [Drawing.ColorTranslator]::FromHtml('#0078D4'), [single]60)
    try { $Graphics.FillPolygon($starGradient, $points) }
    finally { $starGradient.Dispose() }
    $Graphics.DrawPolygon((New-FavoritesArtPen '#00AFC0' 2), $points)
    $Graphics.FillRectangle((New-FavoritesArtBrush '#ADE9E2'), 56, 166, 67, 5)
    $Graphics.FillRectangle((New-FavoritesArtBrush '#ADE9E2'), 56, 178, 49, 4)
    $Graphics.FillEllipse((New-FavoritesArtBrush '#064AB7'), 132, 132, 112, 112)
    $Graphics.DrawEllipse((New-FavoritesArtPen '#54EDBA' 3), 132, 132, 112, 112)
    $pen = New-FavoritesArtPen '#FFFFFF' 8
    if ($Role -eq 'Restore') {
        $Graphics.DrawArc($pen, 157, 157, 64, 64, 45, 270)
        $Graphics.FillPolygon((New-FavoritesArtBrush '#54EDBA'), [Drawing.PointF[]]@(
            [Drawing.PointF]::new(220, 157), [Drawing.PointF]::new(197, 161),
            [Drawing.PointF]::new(215, 181)))
    }
    else {
        $Graphics.DrawLine($pen, 188, 153, 188, 192)
        $Graphics.DrawLine($pen, 174, 179, 188, 193)
        $Graphics.DrawLine($pen, 202, 179, 188, 193)
        $tray = New-FavoritesArtPen '#54EDBA' 7
        $Graphics.DrawLines($tray, [Drawing.PointF[]]@(
            [Drawing.PointF]::new(157, 204), [Drawing.PointF]::new(157, 219),
            [Drawing.PointF]::new(219, 219), [Drawing.PointF]::new(219, 204)))
    }
}

function Draw-FavoritesWave {
    param([Drawing.Graphics]$Graphics)
    $state = $Graphics.Save()
    $clip = [Drawing.Drawing2D.GraphicsPath]::new()
    $wave = [Drawing.Drawing2D.GraphicsPath]::new()
    $curl = [Drawing.Drawing2D.GraphicsPath]::new()
    $gradient = [Drawing.Drawing2D.LinearGradientBrush]::new(
        [Drawing.Rectangle]::new(0, 0, 256, 256),
        [Drawing.ColorTranslator]::FromHtml('#31D67D'),
        [Drawing.ColorTranslator]::FromHtml('#00BCD9'), [single]35)
    try {
        $clip.AddEllipse(0, 0, 256, 256)
        $Graphics.SetClip($clip)
        $wave.AddBezier(0, 105, 22, -20, 193, -18, 256, 73)
        $wave.AddBezier(256, 73, 203, 30, 102, 46, 67, 118)
        $wave.AddBezier(67, 118, 45, 163, 25, 166, 0, 145)
        $wave.CloseFigure()
        $Graphics.FillPath($gradient, $wave)
        $curl.AddBezier(4, 166, 63, 246, 192, 262, 256, 175)
        $curl.AddBezier(256, 175, 232, 251, 90, 294, 4, 211)
        $curl.CloseFigure()
        $Graphics.FillPath((New-FavoritesArtBrush '#0754C9'), $curl)
    }
    finally {
        $Graphics.Restore($state)
        $clip.Dispose()
        $wave.Dispose()
        $curl.Dispose()
        $gradient.Dispose()
    }
}

function New-FavoritesArtBitmap {
    param([string]$Role, [int]$Size = 0)
    $width = if ($Size) { $Size } else { 1200 }
    $height = if ($Size) { $Size } else { 240 }
    $bitmap = [Drawing.Bitmap]::new($width, $height)
    $graphics = $null
    try {
        $graphics = [Drawing.Graphics]::FromImage($bitmap)
        $graphics.SmoothingMode = 'AntiAlias'
        $graphics.PixelOffsetMode = 'HighQuality'
        if ($Size) {
            $graphics.Clear([Drawing.Color]::Transparent)
            $gradient = [Drawing.Drawing2D.LinearGradientBrush]::new(
                [Drawing.Rectangle]::new(0, 0, $Size, $Size),
                [Drawing.ColorTranslator]::FromHtml('#079DD9'),
                [Drawing.ColorTranslator]::FromHtml('#0862D6'), [single]70)
            try { $graphics.FillEllipse($gradient, 0, 0, $Size, $Size) }
            finally { $gradient.Dispose() }
            $graphics.ScaleTransform([single]($Size / 256.0), [single]($Size / 256.0))
            Draw-FavoritesWave -Graphics $graphics
        }
        else {
            $gradient = [Drawing.Drawing2D.LinearGradientBrush]::new(
                [Drawing.Rectangle]::new(0, 0, $width, $height),
                [Drawing.ColorTranslator]::FromHtml('#063F9E'),
                [Drawing.ColorTranslator]::FromHtml('#009DAD'), [single]0)
            try { $graphics.FillRectangle($gradient, 0, 0, $width, $height) }
            finally { $gradient.Dispose() }
            $graphics.FillEllipse((New-FavoritesArtBrush '#00AAB8'), 690, -280, 590, 580)
            $graphics.FillEllipse((New-FavoritesArtBrush '#1BCFA1'), 1100, 95, 320, 320)
            $graphics.DrawEllipse((New-FavoritesArtPen '#65EFD1' 1.5), 815, -53, 355, 355)
            $graphics.TranslateTransform(875, 13)
            $graphics.ScaleTransform([single]0.86, [single]0.86)
            $graphics.FillEllipse((New-FavoritesArtBrush '#0789D1'), 0, 0, 256, 256)
            Draw-FavoritesWave -Graphics $graphics
        }
        Draw-FavoritesSymbol -Graphics $graphics -Role $Role
        return $bitmap
    }
    catch { $bitmap.Dispose(); throw }
    finally { if ($graphics) { $graphics.Dispose() } }
}

function Save-FavoritesArtIcon {
    param([string]$Role, [string]$Path)
    $sizes = @(16, 24, 32, 48, 64, 128, 256)
    $frames = [Collections.Generic.List[byte[]]]::new()
    foreach ($size in $sizes) {
        $bitmap = New-FavoritesArtBitmap -Role $Role -Size $size
        $stream = [IO.MemoryStream]::new()
        try {
            $bitmap.Save($stream, [Drawing.Imaging.ImageFormat]::Png)
            $frames.Add($stream.ToArray())
        }
        finally { $stream.Dispose(); $bitmap.Dispose() }
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
    }
    finally { $writer.Dispose() }
}

try {
    $banner = New-FavoritesArtBitmap -Role Restore
    try { $banner.Save((Join-Path $PSScriptRoot 'favorites-restore-banner.png'), [Drawing.Imaging.ImageFormat]::Png) }
    finally { $banner.Dispose() }
    foreach ($role in @('Backup', 'Restore')) {
        Save-FavoritesArtIcon -Role $role -Path (Join-Path $PSScriptRoot "favorites-$($role.ToLowerInvariant()).ico")
    }
}
finally { foreach ($resource in $resources) { $resource.Dispose() } }
Write-Output 'Generated original restore banner and seven-resolution backup/restore icons.'
