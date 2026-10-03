[CmdletBinding()]
param(
    [string]$Version = '12.1.0',
    [string]$PortableZip = '',
    [string]$OutputPath = '',
    [switch]$InstallerMode
)

$ErrorActionPreference = 'Stop'
$SourceRoot = [IO.Path]::GetFullPath($PSScriptRoot)
if (-not $PortableZip) { $PortableZip = Join-Path $SourceRoot ("dist\RustServerControlCenter-Portable-v$Version.zip") }
if (-not $OutputPath) { $OutputPath = Join-Path $SourceRoot ("dist\RustServerControlCenter-v$Version.exe") }
$PortableZip = [IO.Path]::GetFullPath($PortableZip)
$OutputPath = [IO.Path]::GetFullPath($OutputPath)
$TemplatePath = Join-Path $SourceRoot 'launcher\RustServerControlCenter.SingleExe.cs'
$IconPath = Join-Path $SourceRoot 'tool\RustServerControlCenter-v4.ico'
$Compiler = 'C:\Windows\Microsoft.NET\Framework64\v4.0.30319\csc.exe'
if (-not (Test-Path -LiteralPath $Compiler)) { $Compiler = 'C:\Windows\Microsoft.NET\Framework\v4.0.30319\csc.exe' }

foreach ($Required in @($PortableZip,$TemplatePath,$IconPath,$Compiler)) {
    if (-not (Test-Path -LiteralPath $Required -PathType Leaf)) { throw "Fichier requis absent : $Required" }
}
if ([IO.Path]::GetExtension($OutputPath) -ne '.exe') { throw 'La sortie doit utiliser l extension .exe.' }
if (Test-Path -LiteralPath $OutputPath) { throw "La sortie existe deja : $OutputPath" }

$CoreVersion = ($Version -split '[-+]')[0]
$VersionParts = @($CoreVersion -split '\.')
$InvalidVersionParts = @($VersionParts | Where-Object { $_ -notmatch '^\d+$' })
if ($VersionParts.Count -lt 3 -or $InvalidVersionParts.Count -gt 0) { throw 'Version invalide. Exemple : 12.0.0 ou 12.1.0-beta.1' }
$AssemblyVersionParts = @(($VersionParts + @('0','0','0','0')) | Select-Object -First 4)
$AssemblyVersion = $AssemblyVersionParts -join '.'
$ZipHash = (Get-FileHash -LiteralPath $PortableZip -Algorithm SHA256).Hash.ToLowerInvariant()
$Template = [IO.File]::ReadAllText($TemplatePath,[Text.Encoding]::UTF8)
$Source = $Template.Replace('__PRODUCT_VERSION__',$Version).Replace('__ASSEMBLY_VERSION__',$AssemblyVersion).Replace('__ZIP_SHA256__',$ZipHash).Replace('__INSTALLER_MODE__',$(if($InstallerMode){'true'}else{'false'}))
if ($Source -match '__[A-Z0-9_]+__') { throw 'Un jeton du lanceur C# n a pas ete remplace.' }

$TempRoot = Join-Path ([IO.Path]::GetTempPath()) ('RustSingleExeBuild-' + [guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($TempRoot) | Out-Null
try {
    $GeneratedSource = Join-Path $TempRoot 'RustServerControlCenter.Generated.cs'
    [IO.File]::WriteAllText($GeneratedSource,$Source,[Text.UTF8Encoding]::new($false))
    [IO.Directory]::CreateDirectory((Split-Path $OutputPath -Parent)) | Out-Null
    $CompilerArguments = @(
        '/nologo','/target:winexe','/optimize+','/platform:anycpu',
        ('/out:' + $OutputPath),
        ('/win32icon:' + $IconPath),
        ('/resource:' + $PortableZip + ',RustServerControlCenter.Portable.zip'),
        '/reference:System.dll','/reference:System.Core.dll','/reference:System.Windows.Forms.dll',
        '/reference:System.IO.Compression.dll','/reference:System.IO.Compression.FileSystem.dll',
        $GeneratedSource
    )
    $CompilerOutput = & $Compiler @CompilerArguments 2>&1
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $OutputPath -PathType Leaf)) {
        throw "Compilation du lanceur impossible.`n$($CompilerOutput -join [Environment]::NewLine)"
    }
}
finally {
    if (Test-Path -LiteralPath $TempRoot) {
        $ResolvedTemp = [IO.Path]::GetFullPath($TempRoot)
        $ExpectedTemp = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
        if ($ResolvedTemp.StartsWith($ExpectedTemp,[StringComparison]::OrdinalIgnoreCase) -and [IO.Path]::GetFileName($ResolvedTemp) -like 'RustSingleExeBuild-*') {
            [IO.Directory]::Delete($ResolvedTemp,$true)
        }
    }
}

$ExeHash = (Get-FileHash -LiteralPath $OutputPath -Algorithm SHA256).Hash.ToLowerInvariant()
$ChecksumPath = $OutputPath + '.sha256'
[IO.File]::WriteAllText($ChecksumPath,("$ExeHash  $([IO.Path]::GetFileName($OutputPath))" + [Environment]::NewLine),[Text.UTF8Encoding]::new($false))
$File = Get-Item -LiteralPath $OutputPath
[pscustomobject]@{
    OutputPath   = $OutputPath
    ChecksumPath = $ChecksumPath
    Version      = $Version
    Length       = [long]$File.Length
    Sha256       = $ExeHash
    ZipSha256    = $ZipHash
}
