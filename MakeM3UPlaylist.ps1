param(
  [Parameter(Mandatory = $true)]
  [string] $FolderPath,

  [string] $PlaylistName = "playlist.m3u",

  [string] $Extension = ".mp3"
)

$resolvedFolder = (Resolve-Path -LiteralPath $FolderPath).Path
$playlistPath   = Join-Path $resolvedFolder $PlaylistName

if (-not $Extension.StartsWith(".")) { $Extension = "." + $Extension }

$files = Get-ChildItem -LiteralPath $resolvedFolder -File |
  Where-Object { $_.Extension -ieq $Extension } |
  Sort-Object Name

# Force the playlist to be created *in the same folder* (so filenames resolve)
$lines = New-Object System.Collections.Generic.List[string]
$lines.Add("#EXTM3U")

foreach ($f in $files) {
  $title = [IO.Path]::GetFileNameWithoutExtension($f.Name)
  $lines.Add("#EXTINF:-1,$title")
  $lines.Add($f.Name) # <-- filename only, including extension
}

# Write with CRLF, UTF-8 no BOM (broad compatibility)
$text = ($lines -join "`r`n") + "`r`n"
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
[IO.File]::WriteAllText($playlistPath, $text, $utf8NoBom)

Write-Host "Created: $playlistPath"
Write-Host "Tracks:  $($files.Count)"
Write-Host "NOTE: Open the .m3u from the SAME folder as the .flac files."


 .\Make-Playlist.ps1 -FolderPath "\\RootPath\Killer Instinct Gold (1996)" -PlaylistName "Killer Instinct Gold (1996).m3u"

