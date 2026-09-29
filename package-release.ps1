# Builds the release assets in dist/:
#   MTTireFix_P.pak    the tire pak (copied from -Pak)
#   WheelDebugger.zip  the UE4SS Lua mod (extract into ue4ss/Mods/)
# Usage: .\package-release.ps1 -Pak build\MTTireFix_P.pak
param(
    [Parameter(Mandatory)] [string] $Pak
)
$ErrorActionPreference = 'Stop'
Set-Location $PSScriptRoot

$dist = Join-Path $PSScriptRoot 'dist'
if (Test-Path $dist) { Remove-Item $dist -Recurse -Force }
New-Item -ItemType Directory $dist | Out-Null

Copy-Item $Pak (Join-Path $dist 'MTTireFix_P.pak')

$stage = Join-Path $dist 'stage'
New-Item -ItemType Directory (Join-Path $stage 'WheelDebugger\Scripts') -Force | Out-Null
Copy-Item 'WheelDebugger\Scripts\*.lua' (Join-Path $stage 'WheelDebugger\Scripts')
Compress-Archive -Path (Join-Path $stage 'WheelDebugger') -DestinationPath (Join-Path $dist 'WheelDebugger.zip')
Remove-Item $stage -Recurse -Force

Get-ChildItem $dist | ForEach-Object {
    '{0,-20} {1,8} bytes  SHA-256 {2}' -f $_.Name, $_.Length, (Get-FileHash $_.FullName -Algorithm SHA256).Hash
}
