<#
Convert a folder of artwork ZIPs into MAME-compatible artwork ZIPs.

Input:  Folder containing many .zip files (each game pack)
Output: Folder where converted .zip files are written (same filenames)

Actions per zip:
- Extract to temp
- Remove *.ini
- Flatten *.png to root (avoid nested folders)
- Create root default.lay (mamelayout version="2", non-deprecated)
- Create overlay-style views for PNGs with transparent cutout (alpha==0)
- If none have cutout, create a fallback view that just draws the image full-screen and centers the game screen.

Requirements:
- Windows PowerShell 5.1+ (or PowerShell 7+ on Windows)
- Uses System.Drawing for PNG alpha scan
#>

param(
  [Parameter(Mandatory=$true)]
  [string]$InputZipFolder,

  [Parameter(Mandatory=$true)]
  [string]$OutputZipFolder,

  [int]$TargetWidth  = 1920,
  [int]$TargetHeight = 1080,

  [switch]$Overwrite
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

Add-Type -AssemblyName System.IO.Compression.FileSystem | Out-Null
Add-Type -AssemblyName System.Drawing | Out-Null

function New-TempDir {
  $p = Join-Path $env:TEMP ("mame_art_" + [guid]::NewGuid().ToString("N"))
  New-Item -ItemType Directory -Path $p | Out-Null
  return $p
}

function Safe-XmlId([string]$s) {
  $id = ($s -replace '[^a-zA-Z0-9_]+','_').Trim('_')
  if ([string]::IsNullOrWhiteSpace($id)) { return "art" }
  return $id
}

function Get-TransparentBBox {
  <#
    Returns @{L;T;R;B;W;H} for pixels with alpha==0 (fully transparent).
    Returns $null if no alpha channel or no transparent pixels.
  #>
  param([string]$PngPath)

  $img = [System.Drawing.Image]::FromFile($PngPath)
  try {
    $bmp = New-Object System.Drawing.Bitmap $img
    try {
      $w = $bmp.Width
      $h = $bmp.Height

      $pf = $bmp.PixelFormat.ToString()
      if ($pf -notmatch 'Argb|PArgb') { return $null }

      $minX = [int]::MaxValue
      $minY = [int]::MaxValue
      $maxX = -1
      $maxY = -1

      for ($y=0; $y -lt $h; $y++) {
        for ($x=0; $x -lt $w; $x++) {
          $c = $bmp.GetPixel($x,$y)
          if ($c.A -eq 0) {
            if ($x -lt $minX) { $minX = $x }
            if ($y -lt $minY) { $minY = $y }
            if ($x -gt $maxX) { $maxX = $x }
            if ($y -gt $maxY) { $maxY = $y }
          }
        }
      }

      if ($maxX -lt 0 -or $maxY -lt 0) { return $null }

      return @{
        L = $minX
        T = $minY
        R = ($maxX + 1)  # exclusive
        B = ($maxY + 1)  # exclusive
        W = $w
        H = $h
      }
    }
    finally { $bmp.Dispose() }
  }
  finally { $img.Dispose() }
}

function Flatten-PngsToRoot {
  param([string]$Dir)

  $root = $Dir
  $pngs = @(Get-ChildItem -LiteralPath $Dir -Recurse -File -Filter *.png)
  $used = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)

  $out = @()

  foreach ($p in $pngs) {
    $name = $p.Name
    $dest = Join-Path $root $name

    if ((Test-Path -LiteralPath $dest) -or $used.Contains($name)) {
      $stem = [System.IO.Path]::GetFileNameWithoutExtension($name)
      $ext  = [System.IO.Path]::GetExtension($name)
      $i = 1
      while ($true) {
        $new = "{0}_{1}{2}" -f $stem, $i, $ext
        $dest = Join-Path $root $new
        if (-not (Test-Path -LiteralPath $dest) -and -not $used.Contains($new)) {
          $name = $new
          break
        }
        $i++
      }
    }

    $used.Add($name) | Out-Null

    if ($p.FullName -ne $dest) {
      Copy-Item -LiteralPath $p.FullName -Destination $dest -Force
    }
    $out += (Get-Item -LiteralPath $dest)
  }

  # Remove subfolders after flattening
  @(Get-ChildItem -LiteralPath $Dir -Directory) | ForEach-Object {
    Remove-Item -LiteralPath $_.FullName -Recurse -Force
  }

  return $out
}

function Write-DefaultLay {
  param(
    [string]$OutPath,
    [array]$Views,
    [int]$TW,
    [int]$TH
  )

  $lines = New-Object System.Collections.Generic.List[string]
  $lines.Add('<?xml version="1.0"?>')
  $lines.Add('<mamelayout version="2">')

  foreach ($v in $Views) {
    $lines.Add(("  <element name=""{0}"">" -f $v.ElementId))
    $lines.Add(("    <image file=""{0}""/>" -f $v.FileName))
    $lines.Add('  </element>')
  }

  foreach ($v in $Views) {
    $lines.Add(("  <view name=""{0}"">" -f $v.ViewName))
    $lines.Add(("    <element ref=""{0}"">" -f $v.ElementId))
    $lines.Add(("      <bounds x=""0"" y=""0"" width=""{0}"" height=""{1}""/>" -f $TW, $TH))
    $lines.Add('    </element>')

    $lines.Add('    <screen index="0">')
    $lines.Add(("      <bounds x=""{0}"" y=""{1}"" width=""{2}"" height=""{3}""/>" -f $v.ScreenX, $v.ScreenY, $v.ScreenW, $v.ScreenH))
    $lines.Add('    </screen>')
    $lines.Add('  </view>')
  }

  $lines.Add('</mamelayout>')

  [System.IO.File]::WriteAllLines($OutPath, $lines, [System.Text.Encoding]::UTF8)
}

# --- Main -------------------------------------------------------------

$inDir  = (Resolve-Path -LiteralPath $InputZipFolder).Path
if (-not (Test-Path -LiteralPath $OutputZipFolder)) {
  New-Item -ItemType Directory -Path $OutputZipFolder | Out-Null
}
$outDir = (Resolve-Path -LiteralPath $OutputZipFolder).Path

$zips = @(Get-ChildItem -LiteralPath $inDir -File -Filter *.zip)
if ($zips.Count -eq 0) {
  throw "No .zip files found in: $inDir"
}

$report = @()
Write-Host "Found $($zips.Count) zip(s) in $inDir"

foreach ($zip in $zips) {
  $outZip = Join-Path $outDir $zip.Name
  if ((Test-Path -LiteralPath $outZip) -and -not $Overwrite) {
    Write-Host "Skipping (exists): $($zip.Name)"
    continue
  }

  $tempRoot = New-TempDir
  try {
    # Extract zip
    [System.IO.Compression.ZipFile]::ExtractToDirectory($zip.FullName, $tempRoot)

    # Remove INI
    @(Get-ChildItem -LiteralPath $tempRoot -Recurse -File -Filter *.ini) |
      ForEach-Object { Remove-Item -LiteralPath $_.FullName -Force -ErrorAction SilentlyContinue }

    # Flatten PNGs to root
    $flatPngs = @(Flatten-PngsToRoot -Dir $tempRoot)

    # Build views
    $views = @()

    foreach ($png in $flatPngs) {
      $bbox = Get-TransparentBBox -PngPath $png.FullName
      if (-not $bbox) { continue }

      $sx = $TargetWidth  / [double]$bbox.W
      $sy = $TargetHeight / [double]$bbox.H

      $x = [int][Math]::Round($bbox.L * $sx)
      $y = [int][Math]::Round($bbox.T * $sy)
      $w = [int][Math]::Round(($bbox.R - $bbox.L) * $sx)
      $h = [int][Math]::Round(($bbox.B - $bbox.T) * $sy)

      # Clamp
      $x = [Math]::Max(0, [Math]::Min($TargetWidth - 1, $x))
      $y = [Math]::Max(0, [Math]::Min($TargetHeight - 1, $y))
      $w = [Math]::Max(1, [Math]::Min($TargetWidth - $x, $w))
      $h = [Math]::Max(1, [Math]::Min($TargetHeight - $y, $h))

      $views += [pscustomobject]@{
        ViewName  = "Overlay - $($png.BaseName)"
        ElementId = Safe-XmlId("el_$($png.BaseName)")
        FileName  = $png.Name
        ScreenX   = $x
        ScreenY   = $y
        ScreenW   = $w
        ScreenH   = $h
      }
    }

    # Fallback if no cutouts found
    if ($views.Count -eq 0 -and $flatPngs.Count -gt 0) {
      $p0 = $flatPngs[0]

      # Center a 4:3-ish screen region as a reasonable default
      $screenW = [int]([Math]::Round($TargetHeight * (4.0/3.0)))
      $screenH = $TargetHeight
      if ($screenW -gt $TargetWidth) { $screenW = $TargetWidth; $screenH = $TargetHeight }
      $screenX = [int](($TargetWidth - $screenW) / 2)
      $screenY = 0

      $views = @([pscustomobject]@{
        ViewName  = "Overlay - Fallback"
        ElementId = Safe-XmlId("el_fallback")
        FileName  = $p0.Name
        ScreenX   = $screenX
        ScreenY   = $screenY
        ScreenW   = $screenW
        ScreenH   = $screenH
      })
    }

    # Write default.lay at root
    $layPath = Join-Path $tempRoot "default.lay"
    Write-DefaultLay -OutPath $layPath -Views $views -TW $TargetWidth -TH $TargetHeight

    # Rezip
    if (Test-Path -LiteralPath $outZip) { Remove-Item -LiteralPath $outZip -Force }
    [System.IO.Compression.ZipFile]::CreateFromDirectory(
      $tempRoot,
      $outZip,
      [System.IO.Compression.CompressionLevel]::Optimal,
      $false
    )

    $report += [pscustomobject]@{
      Zip       = $zip.Name
      Views     = $views.Count
      Pngs      = $flatPngs.Count
      OutputZip = $outZip
    }

    Write-Host ("Converted: {0} (views={1}, pngs={2})" -f $zip.Name, $views.Count, $flatPngs.Count)
  }
  finally {
    Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
  }
}

$reportCsv = Join-Path $outDir "conversion_report.csv"
$report | Sort-Object Zip | Export-Csv -NoTypeInformation -Encoding UTF8 -Path $reportCsv

Write-Host ""
Write-Host "DONE. Converted zips in: $outDir"
Write-Host "Report: $reportCsv"

# Example usage (generic paths):
# .\Convert-MameArtworkZipsFromFolder.ps1 `
#   -InputZipFolder  "C:\Path\To\Input\Zips" `
#   -OutputZipFolder "C:\Path\To\Output\Zips" `
#   -Overwrite
