# Packs this folder's lua/, scripts/ and ui/ into multibeam.zip (forward-slash entry names, as BeamNG
# requires) and copies it into the game's mods folder.
#
# BeamNG keeps the zip mounted while it runs. Replacing it underneath a running game breaks the mod for the rest
# of that session (its files stop being found), so the copy is skipped while the game is open.
Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem

$root = $PSScriptRoot
$out  = Join-Path $root 'multibeam.zip'
$mods = Join-Path $env:LOCALAPPDATA 'BeamNG\BeamNG.drive\current\mods'

if (Test-Path $out) { Remove-Item $out -Force }
$zip = [System.IO.Compression.ZipFile]::Open($out, 'Create')
try {
    foreach ($dir in 'lua', 'scripts', 'ui') {
        Get-ChildItem (Join-Path $root $dir) -Recurse -File | ForEach-Object {
            $rel = $_.FullName.Substring($root.Length + 1).Replace('\', '/')
            [void][System.IO.Compression.ZipFileExtensions]::CreateEntryFromFile($zip, $_.FullName, $rel, 'Optimal')
        }
    }
} finally { $zip.Dispose() }
Write-Host "Built $out" -ForegroundColor Green

if (Get-Process -Name 'BeamNG.drive*' -ErrorAction SilentlyContinue) {
    Write-Host ''
    Write-Host 'BeamNG.drive is running, so the mod was NOT copied into the game.' -ForegroundColor Yellow
    Write-Host 'Close the game, then run this again to install it.' -ForegroundColor Yellow
    exit 2
}

if (-not (Test-Path $mods)) {
    Write-Host "Could not find the BeamNG mods folder: $mods" -ForegroundColor Red
    Write-Host "Copy multibeam.zip into your BeamNG mods folder by hand."
    exit 1
}
Copy-Item $out $mods -Force
Write-Host "Installed to $mods" -ForegroundColor Green
Write-Host "Start BeamNG.drive to use the new version." -ForegroundColor Yellow
