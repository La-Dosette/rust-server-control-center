[CmdletBinding()]
param(
    [string]$InstallRoot = (Join-Path $env:LOCALAPPDATA 'RustServerControlCenter'),
    [switch]$NoShortcuts,
    [switch]$NoLaunch
)

$ErrorActionPreference = 'Stop'
Import-Module Microsoft.PowerShell.Utility -Global -ErrorAction Stop
$PackageRoot = [IO.Path]::GetFullPath($PSScriptRoot)
$InstallRoot = [IO.Path]::GetFullPath($InstallRoot)
if ($InstallRoot -eq $PackageRoot) { throw 'Le dossier cible doit être différent du paquet extrait.' }
if ([IO.Path]::GetPathRoot($InstallRoot) -eq $InstallRoot) { throw "Installation refusée à la racine d'un disque." }

$ManifestPath = Join-Path $PackageRoot 'release-manifest.json'
$ReleaseTest = Join-Path $PackageRoot 'scripts\Test-Release.ps1'
if (-not (Test-Path -LiteralPath $ManifestPath) -or -not (Test-Path -LiteralPath $ReleaseTest)) { throw 'Paquet incomplet : manifeste ou test de sécurité absent.' }
. $ReleaseTest -PackageRoot $PackageRoot | Out-Null
$Manifest = Get-Content -LiteralPath $ManifestPath -Raw -Encoding UTF8 | ConvertFrom-Json

[IO.Directory]::CreateDirectory($InstallRoot) | Out-Null
$PreserveIfPresent = @('instances.json','config/server.cfg','config/users.cfg')
foreach ($Entry in @($Manifest.files)) {
    $Relative = ([string]$Entry.path).Replace('/','\')
    $Source = [IO.Path]::GetFullPath((Join-Path $PackageRoot $Relative))
    $Target = [IO.Path]::GetFullPath((Join-Path $InstallRoot $Relative))
    if (-not $Source.StartsWith($PackageRoot + [IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase)) { throw "Chemin source invalide : $Relative" }
    if (-not $Target.StartsWith($InstallRoot + [IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase)) { throw "Chemin cible invalide : $Relative" }
    if ($PreserveIfPresent -contains $Relative.Replace('\','/') -and (Test-Path -LiteralPath $Target)) { continue }
    [IO.Directory]::CreateDirectory((Split-Path $Target -Parent)) | Out-Null
    Copy-Item -LiteralPath $Source -Destination $Target -Force
}
Copy-Item -LiteralPath $ManifestPath -Destination (Join-Path $InstallRoot 'release-manifest.json') -Force

& (Join-Path $InstallRoot 'Initialize-Standalone.ps1') -Root $InstallRoot

if (-not $NoShortcuts) {
    $Shell = New-Object -ComObject WScript.Shell
    $Launcher = Join-Path $InstallRoot 'LANCER-CONTROL-CENTER.vbs'
    $DesktopPath = [Environment]::GetFolderPath('Desktop')
    $StartMenuPath = Join-Path ([Environment]::GetFolderPath('Programs')) 'Rust Server Control Center'
    [IO.Directory]::CreateDirectory($StartMenuPath) | Out-Null
    foreach ($ShortcutPath in @((Join-Path $DesktopPath 'Rust Server Control Center.lnk'),(Join-Path $StartMenuPath 'Rust Server Control Center.lnk'))) {
        $Shortcut = $Shell.CreateShortcut($ShortcutPath)
        $Shortcut.TargetPath = Join-Path $env:SystemRoot 'System32\wscript.exe'
        $Shortcut.Arguments = '"' + $Launcher + '"'
        $Shortcut.WorkingDirectory = $InstallRoot
        $Icon = Join-Path $InstallRoot 'tool\RustServerControlCenter-v4.ico'
        if (Test-Path -LiteralPath $Icon) { $Shortcut.IconLocation = $Icon + ',0' }
        $Shortcut.Description = 'Rust Server Control Center'
        $Shortcut.Save()
    }
    $UninstallKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\RustServerControlCenter'
    New-Item -Path $UninstallKey -Force | Out-Null
    $PowerShellExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $UninstallScript = Join-Path $InstallRoot 'Uninstall-ControlCenter.ps1'
    $UninstallCommand = '"' + $PowerShellExe + '" -NoLogo -NoProfile -ExecutionPolicy Bypass -File "' + $UninstallScript + '" -InstallRoot "' + $InstallRoot + '"'
    New-ItemProperty -Path $UninstallKey -Name DisplayName -Value 'Rust Server Control Center' -PropertyType String -Force | Out-Null
    New-ItemProperty -Path $UninstallKey -Name DisplayVersion -Value ([string]$Manifest.version) -PropertyType String -Force | Out-Null
    New-ItemProperty -Path $UninstallKey -Name Publisher -Value 'Rust Server Control Center community project' -PropertyType String -Force | Out-Null
    New-ItemProperty -Path $UninstallKey -Name InstallLocation -Value $InstallRoot -PropertyType String -Force | Out-Null
    New-ItemProperty -Path $UninstallKey -Name DisplayIcon -Value (Join-Path $InstallRoot 'tool\RustServerControlCenter-v4.ico') -PropertyType String -Force | Out-Null
    New-ItemProperty -Path $UninstallKey -Name UninstallString -Value $UninstallCommand -PropertyType String -Force | Out-Null
    New-ItemProperty -Path $UninstallKey -Name NoModify -Value 1 -PropertyType DWord -Force | Out-Null
    New-ItemProperty -Path $UninstallKey -Name NoRepair -Value 1 -PropertyType DWord -Force | Out-Null
}

if (-not $NoLaunch) { Start-Process -FilePath (Join-Path $env:SystemRoot 'System32\wscript.exe') -ArgumentList ('"' + (Join-Path $InstallRoot 'LANCER-CONTROL-CENTER.vbs') + '"') -WorkingDirectory $InstallRoot -WindowStyle Hidden }
[pscustomobject]@{ Installed=$true; InstallRoot=$InstallRoot; Version=[string]$Manifest.version; Shortcuts=(-not $NoShortcuts) }
