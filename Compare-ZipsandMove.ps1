# Compare-ZipsAndMove.ps1
# Moves .zip files present in Dir2 but missing in Dir1 into Dir3
# Case-insensitive + name normalization + robust .Count handling

param(
  [Parameter(Mandatory=$true)]
  [string]$Dir1,

  [Parameter(Mandatory=$true)]
  [string]$Dir2,

  [Parameter(Mandatory=$true)]
  [string]$Dir3,

  [switch]$WhatIf
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# Ensure destination exists
if (-not (Test-Path -LiteralPath $Dir3)) {
  New-Item -ItemType Directory -Path $Dir3 | Out-Null
}

function Normalize-Name([string]$name) {
  # Normalize for comparisons: trim + collapse whitespace
  $n = $name.Trim()
  $n = [regex]::Replace($n, '\s+', ' ')
  return $n
}

function Get-ZipNameSet([string]$Path) {
  # Returns a HashSet of normalized zip base names (case-insensitive)
  $set = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)

  @(Get-ChildItem -LiteralPath $Path -File -Filter *.zip) | ForEach-Object {
    [void]$set.Add( (Normalize-Name $_.BaseName) )
  }

  return $set
}

$dir1Names = Get-ZipNameSet -Path $Dir1

# Find zips in Dir2 that are missing from Dir1
$missing = @(
  Get-ChildItem -LiteralPath $Dir2 -File -Filter *.zip | Where-Object {
    -not $dir1Names.Contains( (Normalize-Name $_.BaseName) )
  }
)

if ($missing.Count -eq 0) {
  Write-Host "No missing zips found. Nothing to move."
  exit 0
}

Write-Host ("Found {0} zip(s) in Dir2 that are missing from Dir1." -f $missing.Count)

foreach ($f in $missing) {
  $dest = Join-Path -Path $Dir3 -ChildPath $f.Name

  # Avoid overwriting: if exists, add a timestamp suffix
  if (Test-Path -LiteralPath $dest) {
    $stamp = Get-Date -Format "yyyyMMdd_HHmmss"
    $dest = Join-Path -Path $Dir3 -ChildPath ("{0}_{1}{2}" -f $f.BaseName, $stamp, $f.Extension)
  }

  if ($WhatIf) {
    Write-Host "[WhatIf] Would move: $($f.FullName) -> $dest"
  } else {
    Move-Item -LiteralPath $f.FullName -Destination $dest
    Write-Host "Moved: $($f.Name) -> $dest"
  }
}

# Dry run (recommended first):
# .\Compare-ZipsAndMove.ps1 -Dir1 "\\Dir1\artwork\Mame" -Dir2 "\\Dir2\Rlauncherbezels" -Dir3 "\\Dir3\Unique mame" -WhatIf

# Actually move files:
# .\Compare-ZipsAndMove.ps1 -Dir1 "\\Dir1\artwork\Mame" -Dir2 "\\Dir2\Rlauncherbezels" -Dir3 "\\Dir3\Unique mame"
