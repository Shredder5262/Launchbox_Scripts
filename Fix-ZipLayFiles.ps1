<#
Fix-ZipLayDefaultName.ps1

Description
-----------
Scans one folder (optionally recursively) for .zip files and enforces a consistent MAME artwork layout
convention: every *.lay file inside each ZIP should be named "default.lay".

For each ZIP:
1) Extracts the ZIP into a temporary working folder.
2) Finds all *.lay files under the extracted contents.
3) Renames any *.lay that is not already named "default.lay" to "default.lay" within its existing
   subfolder (the internal directory structure is preserved).
4) If renaming would collide (e.g., two layout files in the same directory), a unique name is used
   (e.g., default_1.lay, default_2.lay, ...).
5) Re-compresses the extracted content into a new ZIP and replaces the original ZIP.
6) Optionally writes a .bak copy of the original ZIP before replacement.

Notes
-----
- Use -WhatIf (common PowerShell parameter) to preview rename/replace operations.
- Use -Backup to create "<zip>.bak" before overwriting the original zip.

#>

[CmdletBinding(SupportsShouldProcess = $true)]
param(
  [Parameter(Mandatory = $true)]
  [string]$Folder,

  [switch]$Recurse,

  # Create a .bak copy of the original zip before replacing it
  [switch]$Backup
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Get-UniquePath {
  param(
    [Parameter(Mandatory=$true)][string]$Path
  )
  if (-not (Test-Path -LiteralPath $Path)) { return $Path }

  $dir  = Split-Path -Parent $Path
  $base = [System.IO.Path]::GetFileNameWithoutExtension($Path)
  $ext  = [System.IO.Path]::GetExtension($Path)

  $i = 1
  while ($true) {
    $candidate = Join-Path $dir ("{0}_{1}{2}" -f $base, $i, $ext)
    if (-not (Test-Path -LiteralPath $candidate)) { return $candidate }
    $i++
  }
}

# Ensure Zip APIs are available
Add-Type -AssemblyName System.IO.Compression.FileSystem | Out-Null

$zipFiles = Get-ChildItem -LiteralPath $Folder -Filter "*.zip" -File -Recurse:$Recurse

if (-not $zipFiles) {
  Write-Host "No .zip files found in: $Folder"
  return
}

foreach ($zip in $zipFiles) {
  $tempRoot   = Join-Path ([System.IO.Path]::GetTempPath()) ("ZipLayFix_" + [guid]::NewGuid().ToString("N"))
  $extractDir = Join-Path $tempRoot "extract"
  $newZipPath = Join-Path $tempRoot ($zip.BaseName + ".zip")

  try {
    New-Item -ItemType Directory -Path $extractDir -Force | Out-Null

    # Extract
    [System.IO.Compression.ZipFile]::ExtractToDirectory($zip.FullName, $extractDir)

    # Find .lay files
    $layFiles = Get-ChildItem -LiteralPath $extractDir -Recurse -File -Filter "*.lay"

    if (-not $layFiles) {
      Write-Verbose "No .lay files in $($zip.Name); skipping."
      continue
    }

    $changed = $false

    foreach ($f in $layFiles) {
      if ($f.Name -ieq "default.lay") {
        continue
      }

      # Rename within its current directory
      $target = Join-Path $f.DirectoryName "default.lay"
      if (Test-Path -LiteralPath $target) {
        # Collision: choose unique variant default_1.lay etc.
        $target = Get-UniquePath -Path $target
      }

      if ($PSCmdlet.ShouldProcess("$($zip.Name)", "Rename $($f.FullName) -> $target")) {
        Rename-Item -LiteralPath $f.FullName -NewName ([System.IO.Path]::GetFileName($target)) -Force
        $changed = $true
      }
    }

    if (-not $changed) {
      Write-Verbose "All .lay files already default.lay in $($zip.Name); no changes."
      continue
    }

    # Re-compress extracted folder into a new zip
    if (Test-Path -LiteralPath $newZipPath) { Remove-Item -LiteralPath $newZipPath -Force }
    [System.IO.Compression.ZipFile]::CreateFromDirectory(
      $extractDir,
      $newZipPath,
      [System.IO.Compression.CompressionLevel]::Optimal,
      $false
    )

    # Replace original zip (optionally backup)
    if ($PSCmdlet.ShouldProcess("$($zip.FullName)", "Replace zip with updated contents")) {
      if ($Backup) {
        $bak = $zip.FullName + ".bak"
        Copy-Item -LiteralPath $zip.FullName -Destination $bak -Force
      }
      Move-Item -LiteralPath $newZipPath -Destination $zip.FullName -Force
      Write-Host "Updated: $($zip.FullName)"
    }
  }
  catch {
    Write-Warning "Failed processing '$($zip.Name)': $($_.Exception.Message)"
  }
  finally {
    if (Test-Path -LiteralPath $tempRoot) {
      Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
  }
}

Write-Host "Done."

# -------------------------
# Example usage (generic)
# -------------------------
# Preview changes:
# .\Fix-ZipLayDefaultName.ps1 -Folder "D:\Path\To\Zips" -Recurse -WhatIf
#
# Apply changes and keep backups:
# .\Fix-ZipLayDefaultName.ps1 -Folder "D:\Path\To\Zips" -Recurse -Backup
