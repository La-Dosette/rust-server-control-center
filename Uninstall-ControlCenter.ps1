[CmdletBinding()]
param(
    [string]$InstallRoot = '',
    [switch]$PurgeUserData,
    [string]$ConfirmPurge = ''
)

$ErrorActionPreference = 'Stop'
if(-not$InstallRoot){$InstallRoot=$PSScriptRoot}
$InstallRoot = [IO.Path]::GetFullPath($InstallRoot)
if ([IO.Path]::GetPathRoot($InstallRoot) -eq $InstallRoot) { throw "Désinstallation refusée à la racine d'un disque." }
if ($PurgeUserData -and ($ConfirmPurge -ne 'DELETE' -or [IO.Path]::GetFileName($InstallRoot) -notmatch '^RustServerControlCenter')) {
    throw "La suppression des données exige -ConfirmPurge DELETE et un dossier nommé RustServerControlCenter*."
}

$DesktopShortcut = Join-Path ([Environment]::GetFolderPath('Desktop')) 'Rust Server Control Center.lnk'
$StartMenuRoot = Join-Path ([Environment]::GetFolderPath('Programs')) 'Rust Server Control Center'
if (Test-Path -LiteralPath $DesktopShortcut -PathType Leaf) { [IO.File]::Delete($DesktopShortcut) }
if (Test-Path -LiteralPath $StartMenuRoot -PathType Container) { [IO.Directory]::Delete($StartMenuRoot,$true) }
$UninstallKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\RustServerControlCenter'
if (Test-Path -LiteralPath $UninstallKey) { Remove-Item -LiteralPath $UninstallKey -Recurse -Force }

if ($PurgeUserData) {
    # Le script est déjà chargé en mémoire ; Windows autorise sa suppression.
    [IO.Directory]::Delete($InstallRoot,$true)
    [pscustomobject]@{ Uninstalled=$true; DataPreserved=$false; InstallRoot=$InstallRoot }
    exit 0
}

$ManifestPath = Join-Path $InstallRoot 'release-manifest.json'
if (-not (Test-Path -LiteralPath $ManifestPath)) { throw 'release-manifest.json absent : désinstallation automatique prudente impossible.' }
$Manifest = Get-Content -LiteralPath $ManifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
$PreservedPrefixes = @('instances.json','config/','data/','server/','steamcmd/','logs/','backups/','maps/','.rcon-password.txt','CONNEXION-AMIS.txt')
foreach ($Entry in @($Manifest.files)) {
    $RelativeSlash = ([string]$Entry.path).Replace('\','/')
    if (@($PreservedPrefixes | Where-Object { $RelativeSlash -eq $_ -or ($_.EndsWith('/') -and $RelativeSlash.StartsWith($_,[StringComparison]::OrdinalIgnoreCase)) }).Count) { continue }
    $Target = [IO.Path]::GetFullPath((Join-Path $InstallRoot $RelativeSlash.Replace('/','\')))
    if (-not $Target.StartsWith($InstallRoot + [IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase)) { throw "Cible invalide : $RelativeSlash" }
    if (Test-Path -LiteralPath $Target -PathType Leaf) { [IO.File]::Delete($Target) }
}
if (Test-Path -LiteralPath $ManifestPath -PathType Leaf) { [IO.File]::Delete($ManifestPath) }
foreach ($RelativeDirectory in @('.github','scripts','standalone','tool')) {
    $Directory = Join-Path $InstallRoot $RelativeDirectory
    if ((Test-Path -LiteralPath $Directory -PathType Container) -and -not @(Get-ChildItem -LiteralPath $Directory -Force).Count) { [IO.Directory]::Delete($Directory,$false) }
}
[pscustomobject]@{ Uninstalled=$true; DataPreserved=$true; InstallRoot=$InstallRoot; Message='Les mondes, profils, secrets, logs et sauvegardes sont restés sur le disque.' }
