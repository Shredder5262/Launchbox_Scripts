<#
Copy-AAE-Artwork.ps1

Description
-----------
Parses a platform/library XML (such as a frontend or launcher database export) and identifies entries
whose publisher/manufacturer matches a configurable regular expression. For each matching entry, the
script extracts the ROM base name from a configured path field (default: ApplicationPath), then copies
matching artwork archives (e.g., ROMNAME.zip and optionally ROMNAME.7z) from a source artwork folder
to a destination folder.

What it does
------------
1) Loads an XML file.
2) Finds nodes that contain a configured path field (element or attribute), such as "ApplicationPath".
3) Locates a nearby publisher/manufacturer value (element or attribute), searching the node and its
   closest ancestor that contains any of the configured publisher keys.
4) Filters entries where the publisher/manufacturer matches a regex.
5) Extracts ROM base names (filename without extension) from the path field.
6) Copies matching archive(s) from SourceDir -> DestDir (ZIP by default, optionally 7z).

Notes
-----
- Works whether fields are stored as elements or attributes.
- Matching is done by filename base name (ROMNAME), not by CRC or internal zip contents.
- Uses ShouldProcess, so you can run with -WhatIf (PowerShell common parameter) to preview copies.
- If SkipIfExists is enabled, existing files in the destination are not overwritten.

#>

[CmdletBinding(SupportsShouldProcess = $true)]
param()

# =========================
# CONFIG (edit these only)
# =========================
$Config = @{
    # Path to the XML containing entries with a ROM/application path + publisher/manufacturer metadata
    XmlPath  = "D:\Path\To\Platform.xml"

    # Source artwork folder containing ROMNAME.zip (and optionally ROMNAME.7z)
    SourceDir = "D:\Path\To\Source\Artwork"

    # Destination folder where matched archives will be copied
    DestDir   = "D:\Path\To\Destination\Artwork"

    # Behavior flags
    SkipIfExists = $false
    AlsoCopy7z   = $false

    # Field name holding the ROM/application path to derive base names from
    PathKey = "ApplicationPath"

    # Publisher keys to try (some XMLs use Manufacturer)
    PublisherKeys = @("Publisher", "publisher", "Manufacturer", "manufacturer")

    # Regex used to match publishers/manufacturers (examples: '(?i)\batari\b', '(?i)\bsega\b')
    PublisherMatchRegex = '(?i)\bAtari Games\b'

    # If true, prints diagnostic info when no matches are found
    PrintDiagnostics = $true
}
# =========================
# END CONFIG
# =========================

function Get-RomBaseNameFromValue {
    param([string]$Value)
    if ([string]::IsNullOrWhiteSpace($Value)) { return $null }

    $v = $Value.Trim()
    $leaf = Split-Path -Path $v -Leaf                 # handles if XML stores a full path
    $base = [System.IO.Path]::GetFileNameWithoutExtension($leaf)

    if ([string]::IsNullOrWhiteSpace($base)) { return $null }
    return $base
}

function Get-NodeFieldValue {
    param(
        [System.Xml.XmlNode]$Node,
        [string]$FieldName
    )
    if (-not $Node -or [string]::IsNullOrWhiteSpace($FieldName)) { return $null }

    # Child element
    $child = $Node.SelectSingleNode("./$FieldName")
    if ($child -and -not [string]::IsNullOrWhiteSpace($child.InnerText)) {
        return $child.InnerText.Trim()
    }

    # Attribute
    $attr = $Node.Attributes[$FieldName]
    if ($attr -and -not [string]::IsNullOrWhiteSpace($attr.Value)) {
        return $attr.Value.Trim()
    }

    return $null
}

function Get-ClosestAnyFieldValue {
    param(
        [System.Xml.XmlNode]$Node,
        [string[]]$Keys
    )
    if (-not $Node -or -not $Keys -or $Keys.Count -eq 0) { return $null }

    # Try on this node first
    foreach ($k in $Keys) {
        $v = Get-NodeFieldValue -Node $Node -FieldName $k
        if ($v) { return $v }
    }

    # Find nearest ancestor that has any key as element or attribute
    $parts = @()
    foreach ($k in $Keys) {
        $parts += "$k"
        $parts += "@$k"
    }
    $predicate = ($parts -join " or ")
    $xpath = "ancestor-or-self::*[$predicate][1]"
    $container = $Node.SelectSingleNode($xpath)

    if ($container) {
        foreach ($k in $Keys) {
            $v = Get-NodeFieldValue -Node $container -FieldName $k
            if ($v) { return $v }
        }
    }

    return $null
}

function Get-NodesWithKey {
    param([xml]$Xml, [string]$KeyName)

    $lower = $KeyName.ToLowerInvariant()
    # Find nodes that have KeyName as element or attribute (also lower-case variant)
    return $Xml.SelectNodes("//*[${KeyName} or @${KeyName} or ${lower} or @${lower}]")
}

# --- Validate paths ---
if (-not (Test-Path -LiteralPath $Config.XmlPath))   { throw "XML file not found: $($Config.XmlPath)" }
if (-not (Test-Path -LiteralPath $Config.SourceDir)) { throw "Source directory not found: $($Config.SourceDir)" }
if (-not (Test-Path -LiteralPath $Config.DestDir))   { New-Item -ItemType Directory -Path $Config.DestDir | Out-Null }

# --- Load XML ---
[xml]$xml = Get-Content -LiteralPath $Config.XmlPath -Raw

# --- Find candidate nodes (have ApplicationPath) ---
$nodes = Get-NodesWithKey -Xml $xml -KeyName $Config.PathKey
if (-not $nodes -or $nodes.Count -eq 0) {
    Write-Warning "No '$($Config.PathKey)' entries found in XML."
    return
}

# --- Filter nodes by Publisher regex + build ROM list ---
$romBases = New-Object System.Collections.Generic.List[string]
$pubSeen  = New-Object System.Collections.Generic.List[string]

foreach ($n in $nodes) {
    # read ApplicationPath (try exact key then lowercase key)
    $pathVal = Get-NodeFieldValue -Node $n -FieldName $Config.PathKey
    if (-not $pathVal) {
        $pathVal = Get-NodeFieldValue -Node $n -FieldName $Config.PathKey.ToLowerInvariant()
    }
    if (-not $pathVal) { continue }

    $publisher = Get-ClosestAnyFieldValue -Node $n -Keys $Config.PublisherKeys
    if ($publisher) { $pubSeen.Add($publisher) }

    if ($publisher -and ($publisher -match $Config.PublisherMatchRegex)) {
        $base = Get-RomBaseNameFromValue $pathVal
        if ($base) { $romBases.Add($base) }
    }
}

$romBases = $romBases | Sort-Object -Unique

if (-not $romBases -or $romBases.Count -eq 0) {
    Write-Warning "No ROMs found where Publisher matches regex: $($Config.PublisherMatchRegex)"

    if ($Config.PrintDiagnostics) {
        $distinct = $pubSeen | Where-Object { $_ } | Sort-Object -Unique
        if ($distinct.Count -eq 0) {
            Write-Warning "Diagnostic: No Publisher/Manufacturer values were found near '$($Config.PathKey)' nodes."
            Write-Warning "If this XML is a playlist/export without publisher metadata, you may need a different key or data source."
        } else {
            Write-Host "Diagnostic: Publisher/Manufacturer values found (distinct, first 50):"
            $distinct | Select-Object -First 50 | ForEach-Object { "  - $_" }
            if ($distinct.Count -gt 50) { Write-Host "  ... ($($distinct.Count) total distinct strings)" }
        }
    }

    return
}

Write-Host "Found $($romBases.Count) ROM base name(s) where Publisher matches: $($Config.PublisherMatchRegex)"

# --- Copy matching archives ---
$extensions = @(".zip")
if ($Config.AlsoCopy7z) { $extensions += ".7z" }

$copied  = 0
$skipped = 0
$missing = 0

foreach ($rom in $romBases) {
    foreach ($ext in $extensions) {
        $src  = Join-Path $Config.SourceDir ($rom + $ext)
        $dest = Join-Path $Config.DestDir   ($rom + $ext)

        if (Test-Path -LiteralPath $src) {
            if ($Config.SkipIfExists -and (Test-Path -LiteralPath $dest)) {
                $skipped++
                continue
            }

            if ($PSCmdlet.ShouldProcess($src, "Copy to $dest")) {
                Copy-Item -LiteralPath $src -Destination $dest -Force
            }
            $copied++
        } else {
            if ($ext -eq ".zip") { $missing++ }
        }
    }
}

Write-Host "Done."
Write-Host "  Copied : $copied"
Write-Host "  Skipped: $skipped"
Write-Host "  Missing: $missing (no matching .zip in SourceDir)"
