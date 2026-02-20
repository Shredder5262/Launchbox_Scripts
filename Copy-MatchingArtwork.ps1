<#
Copy-MatchingArtwork.ps1

Description
-----------
Reads an XML file and extracts all values named "Gamefilename" (case-insensitive), whether they appear
as elements or attributes. Each value is normalized to a base name (e.g., "romname.zip" -> "romname"),
then the script searches a source artwork directory for a matching ZIP (by ZIP base name) and copies
any matches into a destination artwork directory.

Typical use case
----------------
You have a list of games (via an XML) and want to collect/copy only the matching MAME artwork ZIPs
from a larger artwork library into a smaller folder for another frontend/emulator setup.

Notes
-----
- Matching is done by ZIP base name (filename without extension).
- If multiple ZIPs with the same base name exist, the first one found is used.
- Use -WhatIf to preview copy operations without writing files.

Inputs
------
-XmlPath: Path to the XML file containing Gamefilename values.

Outputs
-------
Copies matching *.zip files from SourceArtworkRoot to DestArtworkDir.

#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$XmlPath,

    [Parameter()]
    [string]$SourceArtworkRoot = 'D:\Path\To\Source\Artwork',

    [Parameter()]
    [string]$DestArtworkDir = 'D:\Path\To\Destination\Artwork',

    [switch]$RecurseSource = $true,

    [switch]$WhatIf
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-GameFilenamesFromXml {
    param([string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        throw "XML file not found: $Path"
    }

    [xml]$doc = Get-Content -LiteralPath $Path

    # Try to find any element/attribute named Gamefilename (case-insensitive)
    $nodes = $doc.SelectNodes("//*[translate(local-name(), 'ABCDEFGHIJKLMNOPQRSTUVWXYZ', 'abcdefghijklmnopqrstuvwxyz')='gamefilename']")

    $values = New-Object System.Collections.Generic.List[string]

    foreach ($n in $nodes) {
        # element text
        if ($n.'#text' -and $n.'#text'.Trim().Length -gt 0) {
            $values.Add($n.'#text'.Trim())
            continue
        }

        # attribute value (if node is an attribute-like result)
        if ($n.Value -and $n.Value.Trim().Length -gt 0) {
            $values.Add($n.Value.Trim())
            continue
        }
    }

    # Fallback: sometimes it's an attribute on a <game ... Gamefilename="...">
    if ($values.Count -eq 0) {
        $attrNodes = $doc.SelectNodes("//*[@*[translate(local-name(), 'ABCDEFGHIJKLMNOPQRSTUVWXYZ', 'abcdefghijklmnopqrstuvwxyz')='gamefilename']]")
        foreach ($an in $attrNodes) {
            foreach ($a in $an.Attributes) {
                if ($a.Name -match '^(?i)gamefilename$') {
                    $values.Add($a.Value.Trim())
                }
            }
        }
    }

    return $values | Where-Object { $_ -and $_.Trim().Length -gt 0 } | Select-Object -Unique
}

function Normalize-BaseName {
    param([string]$Gamefilename)

    $name = $Gamefilename.Trim()

    # If it contains a path, keep only the leaf
    $leaf = [System.IO.Path]::GetFileName($name)

    # Remove .zip (case-insensitive) if present
    if ($leaf -match '(?i)\.zip$') {
        return [System.IO.Path]::GetFileNameWithoutExtension($leaf)
    }

    # If it has another extension, drop it; otherwise keep as-is
    $ext = [System.IO.Path]::GetExtension($leaf)
    if ($ext) {
        return [System.IO.Path]::GetFileNameWithoutExtension($leaf)
    }

    return $leaf
}

# Ensure destination exists
if (-not (Test-Path -LiteralPath $DestArtworkDir)) {
    New-Item -ItemType Directory -Path $DestArtworkDir | Out-Null
}

Write-Host "Loading Gamefilename entries from: $XmlPath"
$gameFiles = Get-GameFilenamesFromXml -Path $XmlPath
if (-not $gameFiles -or $gameFiles.Count -eq 0) {
    throw "No Gamefilename entries were found in the XML. Verify the XML structure and the element/attribute name."
}

Write-Host "Found $($gameFiles.Count) unique Gamefilename entries."

# Build an index of all zip files under the source (fast lookup by base name)
Write-Host "Indexing source artwork zips in: $SourceArtworkRoot"
$gciParams = @{
    LiteralPath = $SourceArtworkRoot
    File        = $true
    Filter      = '*.zip'
}
if ($RecurseSource) { $gciParams.Recurse = $true }

$zipIndex = @{}
Get-ChildItem @gciParams | ForEach-Object {
    $base = $_.BaseName
    # If duplicates exist, keep the first; you can change this behavior if you want.
    if (-not $zipIndex.ContainsKey($base)) {
        $zipIndex[$base] = $_.FullName
    }
}

Write-Host "Indexed $($zipIndex.Count) zip(s). Starting copy..."

$copied = 0
$missing = 0

foreach ($gf in $gameFiles) {
    $baseName = Normalize-BaseName -Gamefilename $gf

    if ($zipIndex.ContainsKey($baseName)) {
        $src = $zipIndex[$baseName]
        $dst = Join-Path $DestArtworkDir ([System.IO.Path]::GetFileName($src))

        if ($WhatIf) {
            Write-Host "[WHATIF] Copy `"$src`" -> `"$dst`""
        } else {
            Copy-Item -LiteralPath $src -Destination $dst -Force
        }

        $copied++
    } else {
        Write-Warning "No matching zip found for Gamefilename '$gf' (normalized: '$baseName')"
        $missing++
    }
}

Write-Host "Done. Copied: $copied  Missing: $missing"

# Example usage (generic paths):
# .\Copy-MatchingArtwork.ps1 `
#   -XmlPath "C:\Path\To\Games.xml" `
#   -SourceArtworkRoot "D:\Path\To\Source\Artwork" `
#   -DestArtworkDir "D:\Path\To\Destination\Artwork" `
#   -RecurseSource `
#   -WhatIf
