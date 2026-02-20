<#
Rename-BezelLayerPngsInMameZips.ps1

Description
-----------
Scans MAME-style artwork ZIPs and renames only the PNG files that represent "bezel-layer" images, then
updates any *.lay (layout) files so their <image file="..."> and <image alphafile="..."> references
continue to point to the correct renamed assets.

Bezel-layer detection (two-stage)
---------------------------------
A) Preferred (explicit): If a <view> contains bezel-like tags (<bezel>, <overlay>, <backdrop>, <marquee>),
   the script treats the referenced elements as bezel layers.
B) Fallback (heuristic): If no bezel-like tags exist anywhere, the script treats the largest-area element
   instances in each view as bezel layers (by bounds area), selecting any whose area >= (maxArea * LargestAreaFactor).

What it changes
---------------
- Only PNG files referenced by the detected bezel-layer element definitions are renamed.
- The script updates the corresponding XML attributes in the *.lay files to match the new filenames.
- ZIPs are processed by extraction to a temp folder, modification, then re-compression to replace the original ZIP.
- Optional -Backup creates a "<zip>.bak" copy before replacement.
- Use -WhatIf (common PowerShell parameter) to preview all changes without writing.

Notes
-----
- Layout XML formatting may change slightly when saved; MAME accepts standard XML layout files.
- This script intentionally does NOT rename non-PNG assets (JPG/SVG/etc).

#>

[CmdletBinding(SupportsShouldProcess = $true)]
param(
  [Parameter(Mandatory = $true)]
  [string]$Folder,

  [switch]$Recurse,

  [switch]$Backup,

  # For fallback heuristic: include any element whose area >= MaxArea * ThisFactor
  [ValidateRange(0.1, 1.0)]
  [double]$LargestAreaFactor = 0.85
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
Add-Type -AssemblyName System.IO.Compression.FileSystem | Out-Null

function Get-UniquePath {
  param([Parameter(Mandatory=$true)][string]$Path)
  if (-not (Test-Path -LiteralPath $Path)) { return $Path }
  $dir  = Split-Path -Parent $Path
  $base = [IO.Path]::GetFileNameWithoutExtension($Path)
  $ext  = [IO.Path]::GetExtension($Path)
  $i = 1
  while ($true) {
    $cand = Join-Path $dir ("{0}_{1}{2}" -f $base,$i,$ext)
    if (-not (Test-Path -LiteralPath $cand)) { return $cand }
    $i++
  }
}

function Sanitize-Token {
  param([string]$s)
  if ([string]::IsNullOrWhiteSpace($s)) { return "x" }
  # Keep letters, numbers, underscore, dash; normalize everything else to underscore
  return ($s -replace '[^a-zA-Z0-9_\-]+','_').Trim('_')
}

function Get-BoundsArea {
  param($boundsNode)

  if (-not $boundsNode) { return 1.0 }

  # bounds are typically attributes: <bounds x="..." y="..." width="..." height="..."/>
  # or: <bounds left="..." top="..." right="..." bottom="..."/>
  $get = {
    param($n, $name)
    $a = $n.Attributes[$name]
    if ($a) { return [double]$a.Value }
    return $null
  }

  $w = & $get $boundsNode "width"
  $h = & $get $boundsNode "height"

  if ($w -ne $null -and $h -ne $null) {
    return ([math]::Abs($w) * [math]::Abs($h))
  }

  $left   = & $get $boundsNode "left"
  $top    = & $get $boundsNode "top"
  $right  = & $get $boundsNode "right"
  $bottom = & $get $boundsNode "bottom"

  if ($left -ne $null -and $top -ne $null -and $right -ne $null -and $bottom -ne $null) {
    $w2 = [math]::Abs($right - $left)
    $h2 = [math]::Abs($bottom - $top)
    return ($w2 * $h2)
  }

  return 1.0
}

function Get-BezelRefsFromLay {
  param(
    [Parameter(Mandatory=$true)][xml]$Xml
  )

  $results = @() # objects { RefName, Role, Area }
  $specialTags = @("bezel","overlay","backdrop","marquee")

  $views = @($Xml.SelectNodes("//mamelayout/view"))
  foreach ($v in $views) {

    # 1) Preferred: explicit bezel-like tags
    foreach ($tag in $specialTags) {
      $nodes = @($v.SelectNodes("./*[local-name()='$tag']"))
      foreach ($n in $nodes) {
        $ref = $null
        if ($n.Attributes["element"]) { $ref = $n.Attributes["element"].Value }
        elseif ($n.Attributes["ref"]) { $ref = $n.Attributes["ref"].Value }

        if ($ref) {
          $results += [pscustomobject]@{ RefName=$ref; Role=$tag; Area=0.0 }
        }
      }
    }

    # 2) Fallback: largest bounds among <element ref="..."><bounds .../></element>
    $areas = @()
    $elementInst = @($v.SelectNodes("./*[local-name()='element' and @ref]"))
    foreach ($e in $elementInst) {
      $ref = $e.Attributes["ref"].Value
      $b = $e.SelectSingleNode("./*[local-name()='bounds']")
      $area = Get-BoundsArea $b
      $areas += [pscustomobject]@{ RefName = $ref; Role = "largest"; Area = $area }
    }

    if ($areas.Count -gt 0) {
      $max = ($areas | Measure-Object -Property Area -Maximum).Maximum
      $pick = $areas | Where-Object { $_.Area -ge ($max * $LargestAreaFactor) }
      $results += $pick
    }
  }

  # If we found any special-tag roles at all, prefer only those
  $hasSpecial = $results | Where-Object { $_.Role -in $specialTags } | Select-Object -First 1
  if ($hasSpecial) {
    return @($results | Where-Object { $_.Role -in $specialTags } | Sort-Object RefName, Role -Unique)
  }

  # Deduplicate by RefName+Role
  $dedup = @{}
  foreach ($r in $results) {
    $key = "$($r.RefName)|$($r.Role)"
    $dedup[$key] = $r
  }

  return @($dedup.Values | Sort-Object RefName, Role -Unique)
}

function Find-ElementDefinition {
  param(
    [Parameter(Mandatory=$true)][xml]$Xml,
    [Parameter(Mandatory=$true)][string]$Name
  )
  # element definitions live under mamelayout as <element name="...">
  $nodes = $Xml.SelectNodes("//mamelayout/element[@name='$Name']")
  if ($nodes -and $nodes.Count -gt 0) { return $nodes }
  return @()
}

function Get-ImageAttributeNodes {
  param(
    [Parameter(Mandatory=$true)]$ElementNode
  )
  # Return tuples: (node, attrName) for file + alphafile
  $out = @()
  $imgs = $ElementNode.SelectNodes(".//image")
  foreach ($img in $imgs) {
    if ($img.Attributes["file"])      { $out += [pscustomobject]@{ Node=$img; Attr="file" } }
    if ($img.Attributes["alphafile"]) { $out += [pscustomobject]@{ Node=$img; Attr="alphafile" } }
  }
  return $out
}

function Get-NewBezelFileName {
  param(
    [Parameter(Mandatory=$true)][string]$ZipBase,
    [Parameter(Mandatory=$true)][string]$Role,
    [Parameter(Mandatory=$true)][string]$RefName,
    [Parameter(Mandatory=$true)][string]$OldLeaf
  )

  $roleTok = Sanitize-Token $Role
  $refTok  = Sanitize-Token $RefName

  # Output format:
  #   <romname>__<role>__<element>.png
  return ("{0}__{1}__{2}.png" -f $ZipBase.ToLowerInvariant(), $roleTok.ToLowerInvariant(), $refTok.ToLowerInvariant())
}

$zipFiles = Get-ChildItem -LiteralPath $Folder -Filter "*.zip" -File -Recurse:$Recurse

foreach ($zip in $zipFiles) {
  $tempRoot   = Join-Path ([IO.Path]::GetTempPath()) ("ZipBezelRename_" + [guid]::NewGuid().ToString("N"))
  $extractDir = Join-Path $tempRoot "extract"
  $newZipPath = Join-Path $tempRoot $zip.Name

  try {
    New-Item -ItemType Directory -Path $extractDir -Force | Out-Null
    [IO.Compression.ZipFile]::ExtractToDirectory($zip.FullName, $extractDir)

    $layFiles = Get-ChildItem -LiteralPath $extractDir -Recurse -File -Filter "*.lay"
    if (-not $layFiles) { continue }

    $zipBase = $zip.BaseName
    $anyChange = $false

    foreach ($lay in $layFiles) {
      # Load XML
      $raw = Get-Content -LiteralPath $lay.FullName -Raw
      [xml]$xml = $raw

      $bezelRefs = Get-BezelRefsFromLay -Xml $xml
      if (-not $bezelRefs -or $bezelRefs.Count -eq 0) { continue }

      # Build rename operations for only bezel-layer images
      $ops = @() # { OldFull, NewFull, NewRel, Node, Attr, RefName, Role }

      foreach ($br in $bezelRefs) {
        $defs = Find-ElementDefinition -Xml $xml -Name $br.RefName
        foreach ($def in $defs) {
          $imgAttrs = Get-ImageAttributeNodes -ElementNode $def
          foreach ($ia in $imgAttrs) {
            $oldRel = [string]$ia.Node.Attributes[$ia.Attr].Value
            if ([string]::IsNullOrWhiteSpace($oldRel)) { continue }

            # Only rename PNGs (leave JPG/SVG/etc alone)
            if (-not ($oldRel -match '\.png$')) { continue }

            $oldRelNorm = $oldRel -replace '/', '\'
            $baseDir = Split-Path -Parent $lay.FullName
            $oldFull = Join-Path $baseDir $oldRelNorm

            if (-not (Test-Path -LiteralPath $oldFull)) {
              # Sometimes paths are relative to ZIP root; try from extract root
              $alt = Join-Path $extractDir $oldRelNorm
              if (Test-Path -LiteralPath $alt) { $oldFull = $alt } else { continue }
            }

            $oldLeaf = [IO.Path]::GetFileName($oldRelNorm)
            $newLeaf = Get-NewBezelFileName -ZipBase $zipBase -Role $br.Role -RefName $br.RefName -OldLeaf $oldLeaf

            if ($oldLeaf -ieq $newLeaf) { continue }

            $oldDir = Split-Path -Parent $oldFull
            $newFull = Join-Path $oldDir $newLeaf
            if (Test-Path -LiteralPath $newFull) { $newFull = Get-UniquePath -Path $newFull }

            # Preserve relative folder portion from the XML value
            $relDir = Split-Path -Parent $oldRelNorm
            $newRel = if ($relDir) { (Join-Path $relDir ([IO.Path]::GetFileName($newFull))) } else { ([IO.Path]::GetFileName($newFull)) }

            # Preserve slash style from original attribute
            if ($oldRel -like "*/*") { $newRel = ($newRel -replace '\\','/') }

            $ops += [pscustomobject]@{
              OldFull = $oldFull
              NewFull = $newFull
              NewRel  = $newRel
              Node    = $ia.Node
              Attr    = $ia.Attr
              RefName = $br.RefName
              Role    = $br.Role
            }
          }
        }
      }

      if (-not $ops) { continue }

      # Apply XML updates first
      foreach ($op in $ops) {
        if ($PSCmdlet.ShouldProcess($zip.Name, "Update $($lay.Name): $($op.Attr) -> $($op.NewRel)")) {
          $op.Node.Attributes[$op.Attr].Value = $op.NewRel
          $anyChange = $true
        }
      }

      # Rename files (unique by OldFull)
      foreach ($op in ($ops | Sort-Object -Property OldFull -Unique)) {
        if ($PSCmdlet.ShouldProcess($zip.Name, "Rename bezel PNG: $([IO.Path]::GetFileName($op.OldFull)) -> $([IO.Path]::GetFileName($op.NewFull))")) {
          Rename-Item -LiteralPath $op.OldFull -NewName ([IO.Path]::GetFileName($op.NewFull)) -Force
          $anyChange = $true
        }
      }

      # Save updated XML back to .lay
      if ($anyChange -and $PSCmdlet.ShouldProcess($zip.Name, "Write updated lay: $($lay.FullName)")) {
        $xml.Save($lay.FullName)
      }
    }

    if (-not $anyChange) { continue }

    # Repack and replace zip
    if (Test-Path -LiteralPath $newZipPath) { Remove-Item -LiteralPath $newZipPath -Force }
    [IO.Compression.ZipFile]::CreateFromDirectory($extractDir, $newZipPath, [IO.Compression.CompressionLevel]::Optimal, $false)

    if ($PSCmdlet.ShouldProcess($zip.FullName, "Replace ZIP with updated contents")) {
      if ($Backup) { Copy-Item -LiteralPath $zip.FullName -Destination ($zip.FullName + ".bak") -Force }
      Move-Item -LiteralPath $newZipPath -Destination $zip.FullName -Force
      Write-Host "Updated: $($zip.FullName)"
    }
  }
  catch {
    Write-Warning "Failed '$($zip.Name)': $($_.Exception.Message)"
  }
  finally {
    if (Test-Path -LiteralPath $tempRoot) {
      Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
  }
}

# -------------------------
# Example usage (generic)
# -------------------------
# Preview changes:
# .\Rename-BezelLayerPngsInMameZips.ps1 -Folder "D:\Path\To\Zips" -Recurse -WhatIf
#
# Apply changes and keep backups:
# .\Rename-BezelLayerPngsInMameZips.ps1 -Folder "D:\Path\To\Zips" -Recurse -Backup
