[CmdletBinding()]
param(
    [string]$Version = '12.1.0',
    [string]$OutputRoot = ''
)

$ErrorActionPreference = 'Stop'
$SourceRoot = [IO.Path]::GetFullPath($PSScriptRoot)
if(-not$OutputRoot){$OutputRoot=Join-Path $SourceRoot 'dist'}
$OutputRoot = [IO.Path]::GetFullPath($OutputRoot)
$PackageName = "RustServerControlCenter-Portable-v$Version"
$PackageRoot = Join-Path $OutputRoot $PackageName
$ZipPath = Join-Path $OutputRoot ($PackageName + '.zip')
$ChecksumPath = $ZipPath + '.sha256'

if (Test-Path -LiteralPath $PackageRoot) { throw "Le dossier existe déjà : $PackageRoot" }
if (Test-Path -LiteralPath $ZipPath) { throw "L'archive existe déjà : $ZipPath" }
if (Test-Path -LiteralPath $ChecksumPath) { throw "La somme existe déjà : $ChecksumPath" }
[IO.Directory]::CreateDirectory($PackageRoot) | Out-Null

function Copy-ReleaseFile([string]$SourceRelative,[string]$TargetRelative = '') {
    if (-not $TargetRelative) { $TargetRelative = $SourceRelative }
    $Source = [IO.Path]::GetFullPath((Join-Path $SourceRoot $SourceRelative))
    $Target = [IO.Path]::GetFullPath((Join-Path $PackageRoot $TargetRelative))
    if (-not $Source.StartsWith($SourceRoot + [IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase)) { throw "Source hors dépôt : $SourceRelative" }
    if (-not $Target.StartsWith($PackageRoot + [IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase)) { throw "Cible hors paquet : $TargetRelative" }
    if (-not (Test-Path -LiteralPath $Source -PathType Leaf)) { throw "Fichier requis absent : $SourceRelative" }
    [IO.Directory]::CreateDirectory((Split-Path $Target -Parent)) | Out-Null
    Copy-Item -LiteralPath $Source -Destination $Target -Force
}

# Liste blanche stricte : aucun dossier utilisateur, monde, log, secret ou
# binaire serveur ne peut entrer dans le paquet par accident.
$DirectFiles = @(
    'Build-Standalone.ps1','Build-SingleExe.ps1','Build-WindowsInstaller.ps1','Initialize-Standalone.ps1','Install-Update.ps1','Start-Instance.ps1','launcher\RustServerControlCenter.SingleExe.cs',
    'Install-ControlCenter.ps1','Uninstall-ControlCenter.ps1','Update-ControlCenter.ps1',
    'GUIDE-RESEAU-UNIVERSEL.html','PLUGIN-SDK.md','LICENSE','docs\USER-GUIDE.fr.md','docs\USER-GUIDE.en.md','docs\PUBLISHING.fr.md','docs\PUBLISHING.en.md','docs\SIGNING.md','docs\images\friend-test.png','docs\images\network-access.png',
    'tool\RustRPG-Common.ps1','tool\RustRPG-Operations.ps1','tool\RustRPG-Services.ps1','tool\RustRPG-MaintenanceWorker.ps1','tool\RustRPG-Watchdog.ps1','tool\RustRPG-RemoteDashboard.ps1','tool\RustRPG-IsolationWorker.ps1','tool\RustRPG-PluginWorker.ps1','tool\RustRPG-FriendTestWorker.ps1','tool\RustRPG-DdnsWorker.ps1',
    'tool\RustRPG-Manager.ps1','tool\RustRPG-Manager.xaml','tool\RustServerControlCenter-Logo-v4.png',
    'tool\RustServerControlCenter-v4.ico','tool\locales\fr-FR.json','tool\locales\en-US.json','tool\locales\ui-en-US.json','tool\catalog\plugins.json','tool\catalog\catalog.schema.json','tool\sdk\plugin-manifest.schema.json',
    'scripts\Test-Release.ps1','scripts\Test-ControlCenterReliability.ps1','scripts\Test-FirstRunExperience.ps1','scripts\Test-TailscaleIntegration.ps1','scripts\Sign-Release.ps1','scripts\Sign-Executable.ps1','.github\workflows\validate-portable.yml','.github\workflows\release.yml',
    'standalone\instances.template.json','standalone\config\server.cfg','standalone\config\users.cfg'
)
foreach ($Name in $DirectFiles) { Copy-ReleaseFile $Name }

$Mappings = @(
    @('standalone\instances.template.json','instances.json'),
    @('standalone\config\server.cfg','config\server.cfg'),
    @('standalone\config\users.cfg','config\users.cfg'),
    @('standalone\LANCER-CONTROL-CENTER.vbs','LANCER-CONTROL-CENTER.vbs'),
    @('standalone\README-PORTABLE.md','README.md'),
    @('standalone\portable.gitignore','.gitignore'),
    @('standalone\INSTRUCTIONS-LANCEMENT.txt','INSTRUCTIONS-LANCEMENT.txt'),
    @('standalone\Configure-OnlineAccess.ps1','Configure-OnlineAccess.ps1'),
    @('standalone\OUVRIR-GUIDE-RESEAU.bat','OUVRIR-REGLAGE-LIVEBOX.bat'),
    @('carbon\plugins\RustRates.cs','tool\catalog\bundled\RustRates.cs'),
    @('carbon\plugins\RustGameHub.cs','tool\catalog\bundled\RustGameHub.cs'),
    @('carbon\plugins\RustGunGame.cs','tool\catalog\bundled\RustGunGame.cs'),
    @('carbon\plugins\RustDuel.cs','tool\catalog\bundled\RustDuel.cs'),
    @('carbon\plugins\RustRPG.cs','tool\catalog\bundled\RustRPG.cs'),
    @('carbon\plugins\RustTowerDefense.cs','tool\catalog\bundled\RustTowerDefense.cs'),
    @('carbon\plugins\RustTraining.cs','tool\catalog\bundled\RustTraining.cs'),
    @('carbon\plugins\RustStats.cs','tool\catalog\bundled\RustStats.cs'),
    @('tool\sdk\manifests\RustRates.json','tool\sdk\manifests\RustRates.json'),
    @('tool\sdk\manifests\RustGameHub.json','tool\sdk\manifests\RustGameHub.json'),
    @('tool\sdk\manifests\RustGunGame.json','tool\sdk\manifests\RustGunGame.json'),
    @('tool\sdk\manifests\RustDuel.json','tool\sdk\manifests\RustDuel.json'),
    @('tool\sdk\manifests\RustRPG.json','tool\sdk\manifests\RustRPG.json'),
    @('tool\sdk\manifests\RustTowerDefense.json','tool\sdk\manifests\RustTowerDefense.json'),
    @('tool\sdk\manifests\RustTraining.json','tool\sdk\manifests\RustTraining.json'),
    @('tool\sdk\manifests\RustStats.json','tool\sdk\manifests\RustStats.json')
)
foreach ($Map in $Mappings) { Copy-ReleaseFile $Map[0] $Map[1] }
[IO.File]::WriteAllText((Join-Path $PackageRoot 'VERSION'),$Version + [Environment]::NewLine,[Text.UTF8Encoding]::new($false))

$ManifestRows = foreach ($File in @(Get-ChildItem -LiteralPath $PackageRoot -File -Recurse -Force | Sort-Object FullName)) {
    $Relative = $File.FullName.Substring($PackageRoot.Length).TrimStart('\','/').Replace('\','/')
    [ordered]@{ path=$Relative; length=[long]$File.Length; sha256=(Get-FileHash -LiteralPath $File.FullName -Algorithm SHA256).Hash.ToLowerInvariant() }
}
$Manifest = [ordered]@{
    schemaVersion = 1
    product       = 'Rust Server Control Center'
    version       = $Version
    generatedUtc  = [datetime]::UtcNow.ToString('o')
    fileCount     = @($ManifestRows).Count
    files         = @($ManifestRows)
}
[IO.File]::WriteAllText((Join-Path $PackageRoot 'release-manifest.json'),($Manifest | ConvertTo-Json -Depth 8),[Text.UTF8Encoding]::new($false))

Add-Type -AssemblyName System.IO.Compression.FileSystem
[IO.Compression.ZipFile]::CreateFromDirectory($PackageRoot,$ZipPath,[IO.Compression.CompressionLevel]::Optimal,$false)
$ZipHash = (Get-FileHash -LiteralPath $ZipPath -Algorithm SHA256).Hash.ToLowerInvariant()
[IO.File]::WriteAllText($ChecksumPath,("$ZipHash  $([IO.Path]::GetFileName($ZipPath))" + [Environment]::NewLine),[Text.UTF8Encoding]::new($false))
[pscustomobject]@{ PackageRoot=$PackageRoot; ZipPath=$ZipPath; ChecksumPath=$ChecksumPath; Sha256=$ZipHash; Version=$Version; FileCount=@($ManifestRows).Count }
