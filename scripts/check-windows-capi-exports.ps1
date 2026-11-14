<#
.SYNOPSIS
Checks that every public C ABI entry point is exported by the Windows Core DLL.
#>
[CmdletBinding()]
param(
    [string]$CoreDir = $(if ($env:BUBILATOR88_CORE_DIR) { $env:BUBILATOR88_CORE_DIR }
                        else { Join-Path $PSScriptRoot '..\..\Bubilator88Core' }),
    [string]$DllPath
)

$ErrorActionPreference = 'Stop'
$CoreDir = (Resolve-Path -LiteralPath $CoreDir).Path
if (-not $DllPath) { $DllPath = Join-Path $CoreDir '.build\debug\Bubilator88C.dll' }
$DllPath = (Resolve-Path -LiteralPath $DllPath).Path
$toolBin = Split-Path (Get-Command swift -ErrorAction Stop).Source
$exportLines = & (Join-Path $toolBin 'llvm-objdump.exe') -p $DllPath
if ($LASTEXITCODE -ne 0) { throw "Cannot inspect the DLL export table: $DllPath" }
$exportText = $exportLines -join "`n"
$sourceText = (Get-ChildItem -LiteralPath (Join-Path $CoreDir 'Sources\CApi') -Filter '*.swift' |
    Get-Content -Raw) -join "`n"
$declarations = [regex]::Matches($sourceText, '@_cdecl\("(b88_[^"]+)"\)')
$nonPublic = [regex]::Matches($sourceText, '@_cdecl\("(b88_[^"]+)"\)\s*(?!public\b)func')
if ($nonPublic.Count -gt 0) { throw "Non-public C entry points: $($nonPublic.Value -join ', ')" }

function Assert-Exported([string[]]$Names) {
    $missing = @($Names | Where-Object { $exportText -notmatch "\b$([regex]::Escape($_))\b" })
    if ($missing.Count -gt 0) { throw "Missing C exports: $($missing -join ', ')" }
}

Assert-Exported @($declarations | ForEach-Object { $_.Groups[1].Value })
$previous = & git -C $CoreDir grep '@_cdecl' HEAD -- Sources/CApi
if ($LASTEXITCODE -ne 0) { throw 'Cannot read the Core HEAD entry points.' }
$previousNames = [regex]::Matches(($previous -join "`n"), '@_cdecl\("(b88_[^"]+)"\)') |
    ForEach-Object { $_.Groups[1].Value }
Assert-Exported @($previousNames)
Write-Output "Verified $($declarations.Count) public C exports; all existing HEAD exports retained."
