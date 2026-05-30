# Render all Natively .mmd diagrams to SVG (Windows / PowerShell).
# Uses mermaid-cli via npx (no global install needed; downloads on first run).
# Usage:  pwsh docs/diagrams/render.ps1            # -> SVG
#         pwsh docs/diagrams/render.ps1 -Format png -Theme dark
param(
    [string]$Format = "svg",
    [string]$Theme  = "default"
)
$ErrorActionPreference = "Stop"
$dir = $PSScriptRoot
$out = Join-Path $dir "rendered"
New-Item -ItemType Directory -Force -Path $out | Out-Null

Get-ChildItem -Path $dir -Filter *.mmd | ForEach-Object {
    $in  = $_.FullName
    $name = [System.IO.Path]::GetFileNameWithoutExtension($_.Name)
    $dest = Join-Path $out "$name.$Format"
    Write-Host "Rendering $($_.Name) -> rendered/$name.$Format"
    npx --yes @mermaid-js/mermaid-cli -i $in -o $dest -t $Theme -b transparent
}
Write-Host "Done. Output in $out"
