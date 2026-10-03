[CmdletBinding()]
param([Parameter(Mandatory = $true)][string]$PackageRoot)

$ErrorActionPreference = 'Stop'
$PackageRoot = [IO.Path]::GetFullPath($PackageRoot)
if (-not (Test-Path -LiteralPath $PackageRoot -PathType Container)) { throw "Paquet introuvable : $PackageRoot" }

function Get-ReleaseFileSha256 {
    param([Parameter(Mandatory = $true)][string]$Path)
    $Stream = [IO.File]::OpenRead($Path)
    try {
        $Sha = [Security.Cryptography.SHA256]::Create()
        try { return (($Sha.ComputeHash($Stream) | ForEach-Object { $_.ToString('x2') }) -join '') }
        finally { $Sha.Dispose() }
    }
    finally { $Stream.Dispose() }
}

$Required = @(
    'README.md','PLUGIN-SDK.md','LICENSE','VERSION','.gitignore','release-manifest.json','LANCER-CONTROL-CENTER.vbs',
    'Build-Standalone.ps1','Build-SingleExe.ps1','Build-WindowsInstaller.ps1','Initialize-Standalone.ps1','Install-Update.ps1','Start-Instance.ps1','launcher\RustServerControlCenter.SingleExe.cs',
    'Install-ControlCenter.ps1','Uninstall-ControlCenter.ps1','Update-ControlCenter.ps1','instances.json',
    'tool\RustRPG-Common.ps1','tool\RustRPG-Manager.ps1','tool\RustRPG-Manager.xaml',
    'tool\RustRPG-Operations.ps1','tool\RustRPG-Services.ps1','tool\RustRPG-MaintenanceWorker.ps1',
    'tool\RustRPG-Watchdog.ps1','tool\RustRPG-RemoteDashboard.ps1','tool\RustRPG-IsolationWorker.ps1','tool\RustRPG-PluginWorker.ps1','tool\RustRPG-FriendTestWorker.ps1','tool\RustRPG-DdnsWorker.ps1',
    'tool\RustServerControlCenter-v4.ico','tool\RustServerControlCenter-Logo-v4.png',
    'tool\locales\fr-FR.json','tool\locales\en-US.json','tool\locales\ui-en-US.json',
    'tool\catalog\plugins.json','tool\catalog\catalog.schema.json','tool\sdk\plugin-manifest.schema.json',
    'tool\sdk\manifests\RustRates.json','tool\sdk\manifests\RustGameHub.json','tool\sdk\manifests\RustGunGame.json','tool\sdk\manifests\RustDuel.json',
    'tool\sdk\manifests\RustRPG.json','tool\sdk\manifests\RustTowerDefense.json','tool\sdk\manifests\RustTraining.json','tool\sdk\manifests\RustStats.json',
    'scripts\Test-Release.ps1','scripts\Test-ControlCenterReliability.ps1','scripts\Test-FirstRunExperience.ps1','scripts\Test-TailscaleIntegration.ps1','scripts\Sign-Executable.ps1','.github\workflows\validate-portable.yml','.github\workflows\release.yml',
    'docs\USER-GUIDE.fr.md','docs\USER-GUIDE.en.md','docs\PUBLISHING.fr.md','docs\PUBLISHING.en.md','docs\SIGNING.md','docs\images\friend-test.png','docs\images\network-access.png'
)
foreach ($Name in $Required) {
    if (-not (Test-Path -LiteralPath (Join-Path $PackageRoot $Name) -PathType Leaf)) { throw "Fichier de publication absent : $Name" }
}

$ForbiddenDirectoryNames = @('server','steamcmd','logs','backups','data','maps','carbon')
$ForbiddenDirectories = @(Get-ChildItem -LiteralPath $PackageRoot -Directory -Recurse -Force | Where-Object { $_.Name.ToLowerInvariant() -in $ForbiddenDirectoryNames })
if ($ForbiddenDirectories.Count) { throw 'Dossier de données interdit : ' + (($ForbiddenDirectories.FullName) -join ', ') }
$ForbiddenExtensions = @('.exe','.dll','.map','.sav','.db','.db-shm','.db-wal','.log','.dmp')
$ForbiddenBinary = @(Get-ChildItem -LiteralPath $PackageRoot -File -Recurse -Force | Where-Object Extension -in $ForbiddenExtensions)
if ($ForbiddenBinary.Count) { throw 'Binaire ou donnée serveur interdite : ' + (($ForbiddenBinary.Name | Sort-Object -Unique) -join ', ') }
foreach ($SecretName in @('.rcon-password.txt','CONNEXION-AMIS.txt')) {
    if (Test-Path -LiteralPath (Join-Path $PackageRoot $SecretName)) { throw "Donnée locale incluse par erreur : $SecretName" }
}

$TextFiles = @(Get-ChildItem -LiteralPath $PackageRoot -File -Recurse -Force | Where-Object Extension -in '.ps1','.psm1','.json','.cfg','.txt','.md','.vbs','.bat','.html','.yml','.yaml','.gitignore')
$ForbiddenPatterns = @(
    'C:\\Users\\','C:/Users/','92\.162\.','ownerid\s+7656','7656\d{13}',
    'client\.connect\s+(?!127\.0\.0\.1|203\.0\.113\.10|localhost|VOTRE-IP|YOUR-IP)[0-9]{1,3}(?:\.[0-9]{1,3}){3}'
)
foreach ($File in $TextFiles) {
    if ($File.Name -eq 'Test-Release.ps1' -and (Split-Path $File.DirectoryName -Leaf) -eq 'scripts') { continue }
    $Text = Get-Content -LiteralPath $File.FullName -Raw -ErrorAction SilentlyContinue
    foreach ($Pattern in $ForbiddenPatterns) {
        if ($Text -match $Pattern) { throw "Donnée privée potentielle dans $($File.FullName) (motif $Pattern)." }
    }
}

$ManifestPath = Join-Path $PackageRoot 'release-manifest.json'
try { $Manifest = Get-Content -LiteralPath $ManifestPath -Raw -Encoding UTF8 | ConvertFrom-Json }
catch { throw 'release-manifest.json invalide : ' + $_.Exception.Message }
if ([int]$Manifest.schemaVersion -ne 1 -or -not [string]$Manifest.version) { throw 'Manifeste de release incomplet.' }
$ExpectedPaths = New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
foreach ($Entry in @($Manifest.files)) {
    $RelativeSlash = ([string]$Entry.path).Replace('\','/')
    if ($RelativeSlash.StartsWith('/') -or $RelativeSlash -match '(^|/)\.\.(/|$)' -or -not $ExpectedPaths.Add($RelativeSlash)) { throw "Chemin de manifeste invalide ou dupliqué : $RelativeSlash" }
    $Path = [IO.Path]::GetFullPath((Join-Path $PackageRoot $RelativeSlash.Replace('/','\')))
    if (-not $Path.StartsWith($PackageRoot + [IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase)) { throw "Chemin hors paquet : $RelativeSlash" }
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "Fichier du manifeste absent : $RelativeSlash" }
    $File = Get-Item -LiteralPath $Path
    if ([long]$File.Length -ne [long]$Entry.length) { throw "Taille différente du manifeste : $RelativeSlash" }
    $Hash = Get-ReleaseFileSha256 -Path $Path
    if ($Hash -ne ([string]$Entry.sha256).ToLowerInvariant()) { throw "SHA256 différent du manifeste : $RelativeSlash" }
}
$ActualFiles = @(Get-ChildItem -LiteralPath $PackageRoot -File -Recurse -Force | Where-Object Name -ne 'release-manifest.json')
foreach ($File in $ActualFiles) {
    $Relative = $File.FullName.Substring($PackageRoot.Length).TrimStart('\','/').Replace('\','/')
    if (-not $ExpectedPaths.Contains($Relative)) { throw "Fichier inattendu hors manifeste : $Relative" }
}
if ($ActualFiles.Count -ne [int]$Manifest.fileCount) { throw 'Le nombre de fichiers ne correspond pas au manifeste.' }
if ((Get-Content -LiteralPath (Join-Path $PackageRoot 'VERSION') -Raw).Trim() -ne [string]$Manifest.version) { throw 'VERSION ne correspond pas au manifeste.' }

foreach ($File in @(Get-ChildItem -LiteralPath $PackageRoot -Filter '*.ps1' -File -Recurse -Force)) {
    $Tokens = $null
    $Errors = $null
    [Management.Automation.Language.Parser]::ParseFile($File.FullName,[ref]$Tokens,[ref]$Errors) | Out-Null
    if ($Errors.Count) { throw ("PowerShell invalide : {0} - {1}" -f $File.FullName,$Errors[0].Message) }
}
[xml]$null = Get-Content -LiteralPath (Join-Path $PackageRoot 'tool\RustRPG-Manager.xaml') -Raw -Encoding UTF8
foreach ($LocaleName in @('fr-FR','en-US')) { $null = Get-Content -LiteralPath (Join-Path $PackageRoot "tool\locales\$LocaleName.json") -Raw -Encoding UTF8 | ConvertFrom-Json }
$null = Get-Content -LiteralPath (Join-Path $PackageRoot 'tool\locales\ui-en-US.json') -Raw -Encoding UTF8 | ConvertFrom-Json
$PluginCatalog = Get-Content -LiteralPath (Join-Path $PackageRoot 'tool\catalog\plugins.json') -Raw -Encoding UTF8 | ConvertFrom-Json
$PluginSchema = Get-Content -LiteralPath (Join-Path $PackageRoot 'tool\catalog\catalog.schema.json') -Raw -Encoding UTF8 | ConvertFrom-Json
if(-not($PluginCatalog.PSObject.Properties.Name -contains 'plugins') -or -not[bool]$PluginSchema.'$schema'){throw 'Catalogue de plugins ou schéma JSON invalide.'}
$SdkSchema = Get-Content -LiteralPath (Join-Path $PackageRoot 'tool\sdk\plugin-manifest.schema.json') -Raw -Encoding UTF8 | ConvertFrom-Json
if(-not[bool]$SdkSchema.'$schema'){throw 'Schéma du SDK de plugins invalide.'}
foreach($Plugin in @($PluginCatalog.plugins)){
    if(-not[string]$Plugin.bundledManifestPath -or [string]$Plugin.manifestSha256-notmatch'^[A-Fa-f0-9]{64}$'){throw "Manifeste SDK absent du catalogue pour $($Plugin.id)."}
    $SdkPath=[IO.Path]::GetFullPath((Join-Path (Join-Path $PackageRoot 'tool') ([string]$Plugin.bundledManifestPath)))
    $SdkRoot=[IO.Path]::GetFullPath((Join-Path $PackageRoot 'tool\sdk\manifests')).TrimEnd('\')+'\'
    if(-not$SdkPath.StartsWith($SdkRoot,[StringComparison]::OrdinalIgnoreCase)-or-not(Test-Path -LiteralPath $SdkPath -PathType Leaf)){throw "Chemin SDK invalide pour $($Plugin.id)."}
    $SdkManifest=Get-Content -LiteralPath $SdkPath -Raw -Encoding UTF8|ConvertFrom-Json
    if([int]$SdkManifest.schemaVersion-ne1-or[string]$SdkManifest.plugin.fileBase-ne[IO.Path]::GetFileNameWithoutExtension([string]$Plugin.fileName)){throw "Manifeste SDK incompatible pour $($Plugin.id)."}
    if((Get-ReleaseFileSha256 -Path $SdkPath)-ne([string]$Plugin.manifestSha256).ToLowerInvariant()){throw "Empreinte SDK invalide pour $($Plugin.id)."}
}
$Catalog = Get-Content -LiteralPath (Join-Path $PackageRoot 'instances.json') -Raw -Encoding UTF8 | ConvertFrom-Json
if ([int]$Catalog.version -lt 2) { throw 'Le paquet utilise un ancien schéma instances.json.' }
if ([string]$Catalog.uiMode -ne 'simple') { throw 'Le paquet portable ne démarre pas en Mode simple.' }
if ([int]$Catalog.backupRetentionCount -lt 2) { throw 'La rotation de sauvegardes par défaut est invalide.' }
$ReleaseWorkflow = Get-Content -LiteralPath (Join-Path $PackageRoot '.github\workflows\release.yml') -Raw
if ($ReleaseWorkflow -notmatch 'contents:\s*write' -or $ReleaseWorkflow -notmatch 'gh release') { throw 'Le workflow de publication GitHub est incomplet.' }

Write-Output ("Release OK : {0} · {1} fichiers vérifiés par SHA256 · aucune donnée privée détectée." -f $PackageRoot,$ActualFiles.Count)
