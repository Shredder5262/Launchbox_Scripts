<#
Merge-MameArtworkPacks.ps1

Description
-----------
Merges multiple "pack ZIPs" (each containing many per-ROM artwork ZIPs) into a single per-ROM output ZIP:

  <OutDir>\<rom>.zip

Each output ZIP combines artwork content from each pack while keeping pack files separated in subfolders
inside the ROM zip (e.g., WS/, ALT/, PACK3/). The script also merges and rewrites layout files so that
<image file="..."> references point to the correct subfolder paths, and it prefixes element/view names
to avoid naming collisions across packs.

Key behaviors
-------------
- Keeps original artwork filenames (no hash renaming).
- Copies each pack's content into a labeled subfolder inside the ROM output zip:
    OUT\<rom>.zip
      WS/...
      ALT/...
      PACK3/...
- Rewrites default.lay references to include the pack subfolder (e.g., "bezel.png" -> "WS/bezel.png").
- Prefixes element names and view names per pack to avoid collisions.
- Optional cross-pack content deduplication using a hash (default: SHA1) so identical files are stored once.
- Writes one merged "default.lay" at the root of each ROM output zip.

Notes
-----
- This script is designed for Windows PowerShell / PowerShell 7+ on Windows.
- For large collections, start with MaxRoms set to a small number for testing.

Example test command (generic)
------------------------------
# mame <romname> -artpath "D:\Path\To\_MAME_ART_OUT" -verbose -log

#>

[CmdletBinding()]
param()

# =========================
# CONFIG (edit these only)
# =========================
$Config = @{
  # Base folder used for your working set (not required by logic, but helpful as an anchor)
  RootPath = "D:\Path\To\ArtworkProject"

  # Pack ZIPs: each is a "container zip" holding many per-ROM artwork zips
  PackZips = @(
    "D:\Path\To\Packs\artwork_pack1.zip",
    "D:\Path\To\Packs\artwork_pack2.zip",
    "D:\Path\To\Packs\artwork_pack3.zip"
  )

  # Labels become the folder names inside output zips (must align 1:1 with PackZips)
  PackLabels = @("PACK1","PACK2","PACK3")

  # Output per-ROM zips will be written here
  OutDir  = "D:\Path\To\Output\_MAME_ART_OUT"

  # Temp workspace used while processing
  TempDir = "D:\Path\To\Temp\_MAME_ART_TMP"

  # Performance/safety
  MaxRoms          = 10        # 0 = all, or set to a small number for testing
  OverwriteOutput  = $true     # overwrite OUT\<rom>.zip if it exists
  DeleteTempPerRom = $true     # delete temp folder for each ROM after processing

  # Layout handling
  LayoutFileName = "default.lay"

  # Dedupe
  EnableContentDedupe = $true  # dedupe identical files across packs
  DedupeHash          = "SHA1" # SHA1 is fast and typically sufficient (or use SHA256)

  # Logging
  LogPath    = "D:\Path\To\Logs\merge_log.txt"
  ErrorsPath = "D:\Path\To\Logs\merge_errors.txt"
}
# =========================
# END CONFIG
# =========================

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

Add-Type -AssemblyName System.IO.Compression.FileSystem | Out-Null

function Get-LayoutAssetRefs {
  param([System.Xml.XmlDocument]$Doc)

  $refs = New-Object System.Collections.Generic.HashSet[string]([StringComparer]::OrdinalIgnoreCase)
  $assetExtPattern = '\.(png|jpg|jpeg|gif|bmp|webp|svg|wav|mp3|ogg|flac|ttf|otf)$'

  foreach ($n in $Doc.SelectNodes("//*")) {
    if ($n.Attributes) {
      foreach ($a in @($n.Attributes)) {
        $v = ($a.Value -as [string])
        if ([string]::IsNullOrWhiteSpace($v)) { continue }
        $t = $v.Trim().Replace("\","/")
        if ($t -match $assetExtPattern) { [void]$refs.Add($t) }
      }
    }

    if (-not $n.HasChildNodes -and $n.InnerText) {
      $t = $n.InnerText.Trim().Replace("\","/")
      if ($t -match $assetExtPattern) { [void]$refs.Add($t) }
    }
  }

  return $refs
}

function Zip-HasEntry {
  param([System.IO.Compression.ZipArchive]$Zip, [string]$VirtualPath)

  $p = $VirtualPath.Replace("\","/").TrimStart("./")
  return [bool]($Zip.GetEntry($p))
}

function Find-EntryByLeaf {
  param([System.IO.Compression.ZipArchive]$Zip, [string]$Leaf)

  $leaf = $Leaf.Replace("\","/") | Split-Path -Leaf
  if ([string]::IsNullOrWhiteSpace($leaf)) { return $null }

  foreach ($e in $Zip.Entries) {
    if ($e.FullName.EndsWith("/")) { continue }
    if ((Split-Path ($e.FullName.Replace("/","\")) -Leaf) -ieq $leaf) {
      return $e.FullName
    }
  }
  return $null
}

function Log([string]$msg) {
  $line = "[{0}] {1}" -f (Get-Date), $msg
  Add-Content -LiteralPath $Config.LogPath -Value $line
  Write-Host $line
}
function LogWarn([string]$msg) {
  $line = "WARNING: {0}" -f $msg
  Add-Content -LiteralPath $Config.LogPath -Value ("[{0}] {1}" -f (Get-Date), $line)
  Write-Warning $line
}
function LogErr([string]$msg) {
  $line = "[{0}] ERROR: {1}" -f (Get-Date), $msg
  Add-Content -LiteralPath $Config.ErrorsPath -Value $line
  Write-Host $line
}

function Ensure-Dir([string]$p) {
  if (-not (Test-Path -LiteralPath $p)) {
    New-Item -ItemType Directory -Path $p | Out-Null
  }
}

function Open-ZipRead([string]$zipPath) {
  return [System.IO.Compression.ZipFile]::OpenRead($zipPath)
}

function Open-ZipCreate([string]$zipPath) {
  return [System.IO.Compression.ZipFile]::Open($zipPath, [System.IO.Compression.ZipArchiveMode]::Update)
}

function Read-ZipEntryText {
  param([Parameter(Mandatory)][System.IO.Compression.ZipArchiveEntry]$Entry)

  $sr = $null
  $s = $Entry.Open()
  try {
    $sr = New-Object System.IO.StreamReader($s, [Text.Encoding]::UTF8, $true)
    return $sr.ReadToEnd()
  }
  finally {
    if ($sr) { $sr.Dispose() }
    $s.Dispose()
  }
}

function Load-XmlSafe([string]$text) {
  if ([string]::IsNullOrWhiteSpace($text)) { return $null }

  # Trim UTF-8 BOM if present
  if ($text.Length -gt 0 -and [int]$text[0] -eq 0xFEFF) { $text = $text.Substring(1) }

  $doc = New-Object System.Xml.XmlDocument
  $doc.PreserveWhitespace = $true
  $doc.XmlResolver = $null
  try { $doc.LoadXml($text); return $doc } catch { return $null }
}

function Compute-HashFromEntry {
  param(
    [Parameter(Mandatory)][System.IO.Compression.ZipArchiveEntry]$Entry,
    [ValidateSet("SHA1","SHA256")][string]$Algo = "SHA1"
  )

  $hasher = $null
  $s = $Entry.Open()
  try {
    $hasher = if ($Algo -eq "SHA256") { [System.Security.Cryptography.SHA256]::Create() } else { [System.Security.Cryptography.SHA1]::Create() }
    $bytes = $hasher.ComputeHash($s)
    return ([BitConverter]::ToString($bytes) -replace "-","").ToLowerInvariant()
  }
  finally {
    if ($hasher) { $hasher.Dispose() }
    $s.Dispose()
  }
}

function Copy-ZipEntryToZip {
  param(
    [Parameter(Mandatory)][System.IO.Compression.ZipArchiveEntry]$Entry,
    [Parameter(Mandatory)][System.IO.Compression.ZipArchive]$OutZip,
    [Parameter(Mandatory)][string]$OutName
  )

  if ([string]::IsNullOrWhiteSpace($OutName)) { throw "OutName empty for entry '$($Entry.FullName)'" }

  $outEntry = $OutZip.CreateEntry($OutName, [System.IO.Compression.CompressionLevel]::Optimal)
  $inStream = $Entry.Open()
  $outStream = $outEntry.Open()
  try { $inStream.CopyTo($outStream) }
  finally {
    $outStream.Dispose()
    $inStream.Dispose()
  }
}

function Normalize-VirtualPath([string]$p) {
  if ([string]::IsNullOrWhiteSpace($p)) { return $null }
  $x = $p.Trim().Replace("\","/")
  $x = $x.TrimStart("./")
  return $x
}

function Rewrite-LayoutFileRefs {
  param(
    [Parameter(Mandatory)][System.Xml.XmlDocument]$LayoutDoc,
    [Parameter(Mandatory)][hashtable]$FileMap,       # keys: various source refs, value: virtual path in output zip
    [Parameter(Mandatory)][string]$ElementPrefix,
    [Parameter(Mandatory)][string]$ViewPrefix
  )

  # Prefix element names
  $elemRename = @{}
  foreach ($el in $LayoutDoc.SelectNodes("//element[@name]")) {
    $old = $el.GetAttribute("name")
    if ([string]::IsNullOrWhiteSpace($old)) { continue }
    $new = $ElementPrefix + $old
    $el.SetAttribute("name", $new)
    $elemRename[$old] = $new
  }

  # Prefix view names
  foreach ($v in $LayoutDoc.SelectNodes("//view[@name]")) {
    $n = $v.GetAttribute("name")
    if ([string]::IsNullOrWhiteSpace($n)) { continue }
    $v.SetAttribute("name", ($ViewPrefix + $n))
  }

  # Rewrite attributes:
  # - element="foo" (deprecated marquee/bezel/cpanel) and ref="foo" for <element ref=...>
  foreach ($node in $LayoutDoc.SelectNodes("//*[@element]")) {
    $val = $node.GetAttribute("element").Trim()
    if ($elemRename.ContainsKey($val)) { $node.SetAttribute("element", $elemRename[$val]) }
  }
  foreach ($node in $LayoutDoc.SelectNodes("//*[@ref]")) {
    $val = $node.GetAttribute("ref").Trim()
    if ($elemRename.ContainsKey($val)) { $node.SetAttribute("ref", $elemRename[$val]) }
  }

  # Rewrite file references in <image file="..."> and anything else that points to an asset.
  $assetExtPattern = '\.(png|jpg|jpeg|gif|bmp|webp|svg|wav|mp3|ogg|flac|ttf|otf)$'

  foreach ($n in $LayoutDoc.SelectNodes("//*")) {
    if (-not $n.Attributes) { continue }
    foreach ($a in @($n.Attributes)) {
      $raw = $a.Value
      if ([string]::IsNullOrWhiteSpace($raw)) { continue }

      $v = $raw.Trim()
      if ($v -notmatch $assetExtPattern) { continue }

      # Try several normalizations to match map keys
      $candidates = New-Object System.Collections.Generic.List[string]
      $candidates.Add($v)
      $candidates.Add((Normalize-VirtualPath $v))
      $leaf = Split-Path -Path ($v.Replace("/","\")) -Leaf
      if ($leaf) {
        $candidates.Add($leaf)
        $candidates.Add("./$leaf")
        $candidates.Add(".\$leaf")
      }

      foreach ($k in $candidates) {
        if ([string]::IsNullOrWhiteSpace($k)) { continue }
        if ($FileMap.ContainsKey($k)) {
          $a.Value = $FileMap[$k]
          break
        }
      }
    }
  }

  return $LayoutDoc
}

function New-BaseLayoutDoc {
  $doc = New-Object System.Xml.XmlDocument
  $doc.PreserveWhitespace = $true
  $root = $doc.CreateElement("mamelayout")
  $ver = $doc.CreateAttribute("version")
  $ver.Value = "2"
  $root.Attributes.Append($ver) | Out-Null
  $doc.AppendChild($root) | Out-Null
  return $doc
}

# ---------- Setup ----------
Ensure-Dir (Split-Path -Parent $Config.LogPath)
Ensure-Dir (Split-Path -Parent $Config.ErrorsPath)
Add-Content -LiteralPath $Config.LogPath -Value ("`n===== RUN {0} =====" -f (Get-Date))
Ensure-Dir $Config.OutDir
Ensure-Dir $Config.TempDir

if ($Config.PackZips.Count -ne $Config.PackLabels.Count) {
  throw "PackZips count must match PackLabels count."
}
foreach ($p in $Config.PackZips) {
  if (-not (Test-Path -LiteralPath $p)) { throw "Pack zip not found: $p" }
}

# ---------- Index packs: rom -> list of (packIndex, nestedEntry) ----------
Log "Indexing packs..."
$romMap = @{}  # rom -> list of @{ PackIndex=int; EntryName=string }

for ($i=0; $i -lt $Config.PackZips.Count; $i++) {
  $packZipPath = $Config.PackZips[$i]
  $label = $Config.PackLabels[$i]
  Log "Indexing pack: $packZipPath (Label=$label)"

  $za = Open-ZipRead $packZipPath
  try {
    foreach ($e in $za.Entries) {
      if (-not $e) { continue }
      if ($e.FullName.EndsWith("/")) { continue }
      if ([IO.Path]::GetExtension($e.Name) -ne ".zip") { continue }

      $rom = [IO.Path]::GetFileNameWithoutExtension($e.Name)
      if ([string]::IsNullOrWhiteSpace($rom)) { continue }

      if (-not $romMap.ContainsKey($rom)) { $romMap[$rom] = New-Object System.Collections.Generic.List[object] }
      $romMap[$rom].Add([pscustomobject]@{ PackIndex=$i; EntryName=$e.FullName }) | Out-Null
    }
  }
  finally { $za.Dispose() }
}

$allRoms = $romMap.Keys | Sort-Object
Log ("Found {0} unique rom zips across packs." -f $allRoms.Count)

# Global hash->canonical virtual path (for dedupe across packs)
$globalHashToPath = @{}

# ---------- Process ROMs ----------
$processed = 0
foreach ($rom in $allRoms) {
  $processed++
  if ($Config.MaxRoms -gt 0 -and $processed -gt $Config.MaxRoms) { break }

  $outZipPath = Join-Path $Config.OutDir ($rom + ".zip")
  if ((Test-Path -LiteralPath $outZipPath) -and (-not $Config.OverwriteOutput)) {
    Log ("[{0}/{1}] Skipping (exists): {2}" -f $processed, $allRoms.Count, $rom)
    continue
  }

  Log ("[{0}/{1}] ROM: {2}" -f $processed, $allRoms.Count, $rom)

  # ROM temp
  $romTmp = Join-Path $Config.TempDir $rom
  if (Test-Path -LiteralPath $romTmp) { Remove-Item $romTmp -Recurse -Force -ErrorAction SilentlyContinue }
  Ensure-Dir $romTmp
  $nestedDir = Join-Path $romTmp "_nested"
  Ensure-Dir $nestedDir

  # Create output zip fresh
  if (Test-Path -LiteralPath $outZipPath) { Remove-Item $outZipPath -Force -ErrorAction SilentlyContinue }
  $outZip = Open-ZipCreate $outZipPath

  # We'll merge layouts into one doc
  $merged = New-BaseLayoutDoc
  $mergedRoot = $merged.DocumentElement

  # View dedupe signature
  $viewSig = @{}

  try {
    # Per-ROM file map for rewriting refs:
    # key: original ref variants (filename, ./filename, fullpath-ish) -> value: canonical virtual path in output zip
    $fileMap = @{}

    # Each pack that has this ROM:
    foreach ($item in $romMap[$rom]) {
      $pi = [int]$item.PackIndex
      $packZipPath = $Config.PackZips[$pi]
      $label = $Config.PackLabels[$pi]

      # Extract nested rom zip to disk
      $nestedPath = Join-Path $nestedDir ("{0}__{1}.zip" -f $label, $rom)

      $zaPack = Open-ZipRead $packZipPath
      try {
        $entry = $zaPack.GetEntry($item.EntryName)
        if (-not $entry) { LogWarn "[$rom][$label] missing entry '$($item.EntryName)'"; continue }

        $fs = [IO.File]::Open($nestedPath, [IO.FileMode]::Create, [IO.FileAccess]::Write)
        $s = $entry.Open()
        try { $s.CopyTo($fs) } finally { $fs.Dispose(); $s.Dispose() }
      }
      finally { $zaPack.Dispose() }

      Log ("  Scanning nested: {0}" -f $nestedPath)

      # Open nested zip and copy entries into output zip under label/
      $zaNested = Open-ZipRead $nestedPath
      try {
        # Load layout if present
        $layEntry = $zaNested.GetEntry($Config.LayoutFileName)
        $layDoc = $null
        if ($layEntry) {
          $layText = Read-ZipEntryText $layEntry
          $layDoc = Load-XmlSafe $layText
          if (-not $layDoc) {
            LogWarn "[$rom][$label] layout parse failed; will still copy assets, but views from this pack won't be merged."
            Add-Content -LiteralPath $Config.ErrorsPath -Value ("[{0}] [{1}][{2}] layout parse failed in {3}" -f (Get-Date), $rom, $label, $nestedPath)
          }
        }

        # Copy files (except default.lay) to OUT zip under label/
        foreach ($e in $zaNested.Entries) {
          if (-not $e) { continue }
          if ($e.FullName.EndsWith("/")) { continue }

          $name = $e.FullName
          if ([string]::IsNullOrWhiteSpace($name)) { continue }
          if ($name -eq $Config.LayoutFileName) { continue } # we rewrite merged layout

          $virt = Normalize-VirtualPath $name
          if ([string]::IsNullOrWhiteSpace($virt)) { continue }

          $destVirt = "{0}/{1}" -f $label, $virt

          # build map keys (how layouts might reference it)
          $leaf = Split-Path -Path ($virt.Replace("/","\")) -Leaf
          if ($leaf) {
            $fileMap[$leaf]     = $destVirt
            $fileMap["./$leaf"] = $destVirt
            $fileMap[".\$leaf"] = $destVirt
          }
          $fileMap[$virt]     = $destVirt
          $fileMap["./$virt"] = $destVirt

          # Optional cross-pack dedupe
          if ($Config.EnableContentDedupe) {
            $h = Compute-HashFromEntry -Entry $e -Algo $Config.DedupeHash
            if ($globalHashToPath.ContainsKey($h)) {
              $canonical = $globalHashToPath[$h]
              # Point all keys at canonical path
              if ($leaf) {
                $fileMap[$leaf]     = $canonical
                $fileMap["./$leaf"] = $canonical
                $fileMap[".\$leaf"] = $canonical
              }
              $fileMap[$virt]     = $canonical
              $fileMap["./$virt"] = $canonical
              continue
            } else {
              $globalHashToPath[$h] = $destVirt
            }
          }

          # Write into OUT zip
          Copy-ZipEntryToZip -Entry $e -OutZip $outZip -OutName $destVirt
        }

        # Merge layout views/elements if we parsed it
        if ($layDoc -and $layDoc.DocumentElement) {
          $prefElem = "{0}__" -f $label
          $prefView = "{0} - " -f $label

          $layDoc = Rewrite-LayoutFileRefs -LayoutDoc $layDoc -FileMap $fileMap -ElementPrefix $prefElem -ViewPrefix $prefView

          # Import all <element> and <view> nodes into merged doc
          foreach ($n in $layDoc.SelectNodes("/mamelayout/element")) {
            $import = $merged.ImportNode($n, $true)
            $mergedRoot.AppendChild($import) | Out-Null
          }
          foreach ($v in $layDoc.SelectNodes("/mamelayout/view")) {
            # view dedupe by normalized outerxml
            $sig = ($v.OuterXml -replace "\s+"," ").Trim()
            if ($viewSig.ContainsKey($sig)) { continue }
            $viewSig[$sig] = $true

            $import = $merged.ImportNode($v, $true)
            $mergedRoot.AppendChild($import) | Out-Null
          }
        }
      }
      finally { $zaNested.Dispose() }
    }

    # Write merged default.lay into OUT zip root
    $xmlText = $merged.OuterXml
    $layOutEntry = $outZip.CreateEntry($Config.LayoutFileName, [System.IO.Compression.CompressionLevel]::Optimal)
    $sw = $null
    $st = $layOutEntry.Open()
    try {
      $sw = New-Object System.IO.StreamWriter($st, [Text.Encoding]::UTF8)
      $sw.Write($xmlText)
    }
    finally {
      if ($sw) { $sw.Dispose() }
      $st.Dispose()
    }

    # --- Verify merged layout references exist ---
    try {
      $mergedDoc = Load-XmlSafe $xmlText
      if ($mergedDoc) {
        $refs = Get-LayoutAssetRefs -Doc $mergedDoc
        $missingRefs = New-Object System.Collections.Generic.List[string]

        foreach ($r in $refs) {
          if (-not (Zip-HasEntry -Zip $outZip -VirtualPath $r)) {
            $missingRefs.Add($r) | Out-Null
          }
        }

        if ($missingRefs.Count -gt 0) {
          LogWarn ("[$rom] Missing {0} referenced asset(s) in merged zip. Attempting leaf-match repairs..." -f $missingRefs.Count)

          foreach ($mr in $missingRefs) {
            $leaf = Split-Path ($mr.Replace("/","\")) -Leaf
            $found = Find-EntryByLeaf -Zip $outZip -Leaf $leaf
            if ($found) {
              $fileMap[$leaf] = $found.Replace("\","/")
            } else {
              Add-Content -LiteralPath $Config.ErrorsPath -Value ("[{0}] ROM={1} MISSING_REF={2}" -f (Get-Date), $rom, $mr)
            }
          }
        }
      }
    }
    catch {
      LogWarn "[$rom] Verification step failed: $($_.Exception.Message)"
    }

    Log ("  Wrote output: {0}" -f $outZipPath)
  }
  catch {
    LogErr ("ROM={0} ERROR={1}`n{2}" -f $rom, $_.Exception.Message, $_.ScriptStackTrace)
  }
  finally {
    $outZip.Dispose()
    if ($Config.DeleteTempPerRom -and (Test-Path -LiteralPath $romTmp)) {
      Remove-Item $romTmp -Recurse -Force -ErrorAction SilentlyContinue
    }
  }
}

Log "DONE."
Log ("Output folder: {0}" -f $Config.OutDir)
