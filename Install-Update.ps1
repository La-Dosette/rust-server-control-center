[CmdletBinding()]
param(
    [switch]$InstallCarbon,
    [switch]$InstallOxide,
    [switch]$InstallBundledPlugins
)

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"
$Utf8ConsoleEncoding = New-Object Text.UTF8Encoding($false)
[Console]::OutputEncoding = $Utf8ConsoleEncoding
$OutputEncoding = $Utf8ConsoleEncoding

$Root = $PSScriptRoot
$SteamCmdDir = Join-Path $Root "steamcmd"
$SteamCmdExe = Join-Path $SteamCmdDir "steamcmd.exe"
$ServerDir = Join-Path $Root "server"
$SteamCmdZip = Join-Path $env:TEMP "rust-rpg-steamcmd.zip"
$CarbonZip = Join-Path $env:TEMP "rust-rpg-carbon.zip"
$OxideZip = Join-Path $env:TEMP "rust-rpg-oxide.zip"
$CarbonWasInstalled = Test-Path -LiteralPath (Join-Path $ServerDir "carbon\managed\Carbon.Common.dll")
$OxideWasInstalled = (Test-Path -LiteralPath (Join-Path $ServerDir "oxide\plugins") -PathType Container) -or (Test-Path -LiteralPath (Join-Path $ServerDir "RustDedicated_Data\Managed\Oxide.Rust.dll") -PathType Leaf)
if ($InstallCarbon -and $InstallOxide) { throw "Choisis Carbon ou Oxide, pas les deux." }
if ($InstallCarbon -and $OxideWasInstalled) { throw "Oxide est déjà installé. Une migration automatique vers Carbon pourrait casser les plugins : utilise un runtime séparé." }
if ($InstallOxide -and $CarbonWasInstalled) { throw "Carbon est déjà installé. Une migration automatique vers Oxide pourrait casser les plugins : utilise un runtime séparé." }
$ShouldInstallCarbon = $InstallCarbon -or ($InstallBundledPlugins -and -not $OxideWasInstalled) -or $CarbonWasInstalled
$ShouldInstallOxide = $InstallOxide -or $OxideWasInstalled

function Write-ControlCenterProgress([int]$Percent,[string]$Stage,[string]$Detail) {
    # Ligne volontairement simple a parser par le Control Center. Elle reste
    # aussi lisible lorsqu'Install-Update.ps1 est lance manuellement.
    Write-Output ("RCC_PROGRESS|{0}|{1}|{2}" -f $Percent,$Stage,$Detail)
}

if (Get-Process RustDedicated -ErrorAction SilentlyContinue | Where-Object { $_.Path -like "$Root*" }) {
    throw "Arrete d'abord toutes les instances Rust depuis le Control Center."
}

Write-Host "=== Rust Server - installation / mise a jour ===" -ForegroundColor Cyan
Write-ControlCenterProgress 2 'PREPARATION' 'Préparation des dossiers et vérification de SteamCMD.'
New-Item -ItemType Directory -Force -Path $SteamCmdDir, $ServerDir | Out-Null

if (-not (Test-Path -LiteralPath $SteamCmdExe)) {
    Write-ControlCenterProgress 8 'STEAMCMD' 'Téléchargement des outils Valve.'
    Write-Host "Telechargement de SteamCMD depuis Valve..."
    Invoke-WebRequest -Uri "https://steamcdn-a.akamaihd.net/client/installer/steamcmd.zip" -OutFile $SteamCmdZip -UseBasicParsing
    Expand-Archive -LiteralPath $SteamCmdZip -DestinationPath $SteamCmdDir -Force
    Remove-Item -LiteralPath $SteamCmdZip -Force
}

$SteamArgs = @(
    "+force_install_dir", $ServerDir,
    "+login", "anonymous",
    "+app_update", "258550", "validate",
    "+quit"
)

Write-ControlCenterProgress 18 'RUST DEDICATED' 'SteamCMD vérifie et télécharge les fichiers du serveur.'
Write-Host "Installation/mise a jour de Rust Dedicated Server..."
& $SteamCmdExe @SteamArgs
$SteamExitCode = $LASTEXITCODE
if ($SteamExitCode -eq 7) {
    & $SteamCmdExe @SteamArgs
    $SteamExitCode = $LASTEXITCODE
}
if ($SteamExitCode -ne 0) {
    throw "SteamCMD a termine avec le code $SteamExitCode."
}
Write-ControlCenterProgress 86 'RUST DEDICATED' 'Les fichiers du serveur Rust sont à jour.'

if ($ShouldInstallCarbon) {
    Write-ControlCenterProgress 90 'CARBON' 'Téléchargement de la dernière version de Carbon.'
    Write-Host "Telechargement de Carbon Production..."
    $Release = Invoke-RestMethod -Uri "https://api.github.com/repos/CarbonCommunity/Carbon/releases/latest" -Headers @{ "User-Agent" = "Rust-Server-Control-Center" }
    $Asset = $Release.assets | Where-Object { $_.name -eq "Carbon.Windows.Release.zip" } | Select-Object -First 1
    if (-not $Asset) {
        throw "Archive Carbon.Windows.Release.zip introuvable dans la derniere version."
    }
    Invoke-WebRequest -Uri $Asset.browser_download_url -OutFile $CarbonZip -UseBasicParsing
    Expand-Archive -LiteralPath $CarbonZip -DestinationPath $ServerDir -Force
    Remove-Item -LiteralPath $CarbonZip -Force
    Write-ControlCenterProgress 97 'CARBON' 'Carbon est installé et prêt à être chargé.'
} elseif ($ShouldInstallOxide) {
    Write-ControlCenterProgress 90 'OXIDE' "Téléchargement de la dernière version stable d’Oxide/uMod."
    Write-Host "Telechargement de la version Windows d'Oxide/uMod..."
    Invoke-WebRequest -Uri "https://umod.org/games/rust/download" -Headers @{ "User-Agent" = "Rust-Server-Control-Center" } -OutFile $OxideZip -UseBasicParsing
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $Archive = [IO.Compression.ZipFile]::OpenRead($OxideZip)
    try {
        $ExpandedBytes = 0L
        foreach ($Entry in $Archive.Entries) {
            $EntryPath = ([string]$Entry.FullName).Replace('/','\')
            if ([IO.Path]::IsPathRooted($EntryPath) -or $EntryPath -match '(^|\\)\.\.(\\|$)') { throw "Archive Oxide refusée : chemin dangereux." }
            $ExpandedBytes += [long]$Entry.Length
            if ($ExpandedBytes -gt 1GB) { throw "Archive Oxide refusée : contenu décompressé anormalement volumineux." }
        }
        if (-not @($Archive.Entries | Where-Object { ([string]$_.FullName) -match '(^|/)RustDedicated_Data/' }).Count) {
            throw "Archive Oxide invalide : RustDedicated_Data est absent."
        }
    }
    finally { $Archive.Dispose() }
    Expand-Archive -LiteralPath $OxideZip -DestinationPath $ServerDir -Force
    Remove-Item -LiteralPath $OxideZip -Force
    Write-ControlCenterProgress 97 'OXIDE' 'Oxide/uMod est installé et prêt à être chargé.'
} else {
    Write-ControlCenterProgress 94 'ENVIRONNEMENT VANILLA' "Vérification de l'installation sans mod loader."
    Write-Host "Environnement vanilla conserve : Carbon n'est pas installe." -ForegroundColor DarkGray
}

if ($InstallBundledPlugins) {
    $PluginSourceDir = Join-Path $Root "carbon\plugins"
    $PluginTargetDir = if ($ShouldInstallOxide) { Join-Path $ServerDir "oxide\plugins" } else { Join-Path $ServerDir "carbon\plugins" }
    New-Item -ItemType Directory -Force -Path $PluginTargetDir | Out-Null
    Copy-Item -Path (Join-Path $PluginSourceDir "*.cs") -Destination $PluginTargetDir -Force
}

if (-not (Test-Path -LiteralPath (Join-Path $ServerDir "RustDedicated.exe"))) {
    throw "RustDedicated.exe est introuvable apres l'installation."
}

$EnvironmentLabel = if ($ShouldInstallCarbon) { "Rust Dedicated et Carbon sont a jour." } elseif ($ShouldInstallOxide) { "Rust Dedicated et Oxide/uMod sont a jour." } else { "Rust Dedicated vanilla est a jour." }
Write-ControlCenterProgress 100 'TERMINE' $EnvironmentLabel
Write-Host $EnvironmentLabel -ForegroundColor Green
