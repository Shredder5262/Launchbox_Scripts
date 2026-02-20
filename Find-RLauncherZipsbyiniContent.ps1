<#
Find-RLauncherZipsByIniContent.ps1

Description
-----------
Scans all .zip files in a folder and detects "RLauncher-style" packs by inspecting the contents of any
embedded .ini files. A zip is considered a match if at least one .ini file contains bezel coordinate
keys commonly used by RLauncher (e.g., "Bezel Screen Top Left X Coordinate = ...").

If matches are found, the script can:
- Print matching ZIP filenames to the console (default behavior)
- Optionally write a list of matching ZIP full paths to a text file (-OutputList)
- Optionally move matching ZIP files to another folder (-MoveTo)

How detection works
-------------------
1) Enumerate *.zip files in the provided -ZipFolder.
2) For each zip, open it read-only and iterate entries.
3) For any entry ending in .ini, read it as text (StreamReader with BOM detection).
4) If the text matches any of the configured regex patterns, mark the zip as a match.

Notes
-----
- This script reads inside ZIPs; it does not extract them to disk.
- Use -OutputList to record results; use -MoveTo to quarantine/organize matched zips.
- If a ZIP is corrupt/unreadable, the script warns and continues.

#>

param(
  [Parameter(Mandatory=$true)]
  [string]$ZipFolder,

  [string]$OutputList,
  [string]$MoveTo
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

Add-Type -AssemblyName System.IO.Compression.FileSystem | Out-Null

# Regex patterns that indicate an INI looks like it contains RLauncher bezel coordinate settings.
$RLauncherPatterns = @(
  'Bezel\s+Screen\s+Top\s+Left\s+X\s+Coordinate\s*=',
  'Bezel\s+Screen\s+Top\s+Left\s+Y\s+Coordinate\s*=',
  'Bezel\s+Screen\s+Bottom\s+Right\s+X\s+Coordinate\s*=',
  'Bezel\s+Screen\s+Bottom\s+Right\s+Y\s+Coordinate\s*='
)

function Test-IniLooksLikeRLauncher {
  param([string]$IniText)

  foreach ($pat in $RLauncherPatterns) {
    if ($IniText -match $pat) { return $true }
  }
  return $false
}

function Zip-ContainsRLauncherIni {
  param([string]$ZipPath)

  $zip = [System.IO.Compression.ZipFile]::OpenRead($ZipPath)
  try {
    foreach ($e in $zip.Entries) {
      if ($e.FullName -match '\.ini$') {
        $stream = $null
        $reader = $null
        try {
          $stream = $e.Open()
          # Let StreamReader detect BOM/encoding when possible; ASCII keys still match either way.
          $reader = New-Object System.IO.StreamReader($stream, [System.Text.Encoding]::UTF8, $true)
          $text = $reader.ReadToEnd()

          if (Test-IniLooksLikeRLauncher -IniText $text) {
            return $true
          }
        }
        finally {
          if ($reader -ne $null) { $reader.Dispose() }
          if ($stream -ne $null) { $stream.Dispose() }
        }
      }
    }
    return $false
  }
  finally {
    $zip.Dispose()
  }
}

# ---- Main ----
$zips = @(Get-ChildItem -LiteralPath $ZipFolder -File -Filter *.zip)
if ($zips.Count -eq 0) {
  Write-Host "No .zip files found in: $ZipFolder"
  exit 0
}

$rlauncherZips = @()

foreach ($z in $zips) {
  try {
    if (Zip-ContainsRLauncherIni -ZipPath $z.FullName) {
      $rlauncherZips += $z
    }
  }
  catch {
    Write-Warning "Could not scan zip: $($z.Name) - $($_.Exception.Message)"
  }
}

if ($rlauncherZips.Count -eq 0) {
  Write-Host "No RLauncher-style zips detected (by INI content)."
} else {
  Write-Host "RLauncher-style zips detected: $($rlauncherZips.Count)"
  $rlauncherZips | ForEach-Object { Write-Host $_.Name }

  if ($OutputList) {
    $rlauncherZips.FullName | Out-File -FilePath $OutputList -Encoding UTF8
    Write-Host "Saved list to: $OutputList"
  }

  if ($MoveTo) {
    if (-not (Test-Path -LiteralPath $MoveTo)) {
      New-Item -ItemType Directory -Path $MoveTo | Out-Null
    }
    foreach ($f in $rlauncherZips) {
      $dest = Join-Path $MoveTo $f.Name
      Move-Item -LiteralPath $f.FullName -Destination $dest -Force
    }
    Write-Host "Moved detected zips to: $MoveTo"
  }
}

# -------------------------
# Example usage (generic)
# -------------------------

# Just detect + print:
# .\Find-RLauncherZipsByIniContent.ps1 -ZipFolder "D:\Path\To\Zips"

# Detect + save list:
# .\Find-RLauncherZipsByIniContent.ps1 -ZipFolder "D:\Path\To\Zips" -OutputList "D:\Path\To\output\rlauncher_zips.txt"

# Detect + move them out of the folder:
# .\Find-RLauncherZipsByIniContent.ps1 -ZipFolder "D:\Path\To\Zips" -MoveTo "D:\Path\To\Zips\RLauncherOnly"
