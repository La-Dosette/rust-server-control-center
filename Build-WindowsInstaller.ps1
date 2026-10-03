[CmdletBinding()]
param(
    [string]$Version = '12.1.0',
    [string]$PortableZip = '',
    [string]$OutputPath = ''
)

$ErrorActionPreference = 'Stop'
$SourceRoot = [IO.Path]::GetFullPath($PSScriptRoot)
if (-not $PortableZip) { $PortableZip = Join-Path $SourceRoot ("dist\RustServerControlCenter-Portable-v$Version.zip") }
if (-not $OutputPath) { $OutputPath = Join-Path $SourceRoot ("dist\RustServerControlCenter-Setup-v$Version.exe") }

$Result = & (Join-Path $SourceRoot 'Build-SingleExe.ps1') -Version $Version -PortableZip $PortableZip -OutputPath $OutputPath -InstallerMode
if (-not $Result -or -not (Test-Path -LiteralPath $OutputPath -PathType Leaf)) { throw "La création de l’installateur Windows a échoué." }
$Result
