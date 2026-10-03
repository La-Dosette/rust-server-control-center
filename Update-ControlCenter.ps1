[CmdletBinding()]
param(
    [string]$ServerRoot = '',
    [string]$Repository = '',
    [string]$Channel = '',
    [string]$PackageRoot = '',
    [switch]$CheckOnly,
    [string]$ResultPath = '',
    [switch]$ListBackups,
    [string]$RestoreBackup = '',
    [switch]$Relaunch
)

$ErrorActionPreference = 'Stop'
if(-not$ServerRoot){$ServerRoot=$PSScriptRoot}
$ServerRoot = [IO.Path]::GetFullPath($ServerRoot)
if ([IO.Path]::GetPathRoot($ServerRoot) -eq $ServerRoot) { throw "Mise à jour refusée à la racine d'un disque." }
$CurrentVersion = if (Test-Path -LiteralPath (Join-Path $ServerRoot 'VERSION')) { (Get-Content -LiteralPath (Join-Path $ServerRoot 'VERSION') -Raw).Trim() } else { 'development' }
$TemporaryRoot = ''

function Compare-ControlCenterVersion([string]$Left,[string]$Right) {
    if ($Left -eq 'development') { return -1 }
    $Pattern = '^v?(?<core>\d+\.\d+\.\d+(?:\.\d+)?)(?:-(?<pre>[0-9A-Za-z.-]+))?(?:\+[0-9A-Za-z.-]+)?$'
    if ($Left -notmatch $Pattern) { return -1 };$LeftCore=[version]$Matches.core;$LeftPre=[string]$Matches.pre
    if ($Right -notmatch $Pattern) { return 1 };$RightCore=[version]$Matches.core;$RightPre=[string]$Matches.pre
    $CoreResult=$LeftCore.CompareTo($RightCore);if($CoreResult-ne 0){return $CoreResult}
    if (-not $LeftPre -and $RightPre) { return 1 };if ($LeftPre -and -not $RightPre) { return -1 };if (-not $LeftPre) { return 0 }
    return [string]::Compare($LeftPre,$RightPre,[StringComparison]::OrdinalIgnoreCase)
}

function Write-UpdateResult($Value) {
    if ($ResultPath) {
        $FullResultPath = [IO.Path]::GetFullPath($ResultPath)
        [IO.Directory]::CreateDirectory((Split-Path $FullResultPath -Parent)) | Out-Null
        [IO.File]::WriteAllText($FullResultPath,($Value | ConvertTo-Json -Depth 10),[Text.UTF8Encoding]::new($false))
    }
    return $Value
}

function Get-UpdateBackupRows {
    $Root = Join-Path $ServerRoot 'backups\control-center-updates'
    if (-not (Test-Path -LiteralPath $Root -PathType Container)) { return @() }
    return @(Get-ChildItem -LiteralPath $Root -Directory | Sort-Object Name -Descending | ForEach-Object {
        $ManifestPath = Join-Path $_.FullName 'backup-manifest.json'
        if (-not (Test-Path -LiteralPath $ManifestPath -PathType Leaf)) { return }
        try {
            $Backup = Get-Content -LiteralPath $ManifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
            [pscustomobject]@{Path=$_.FullName;CreatedUtc=[string]$Backup.createdUtc;PreviousVersion=[string]$Backup.previousVersion;TargetVersion=[string]$Backup.targetVersion;FileCount=@($Backup.files).Count}
        } catch { }
    })
}

if ($ListBackups) {
    $BackupRows = @(Get-UpdateBackupRows)
    return Write-UpdateResult $BackupRows
}

if ($RestoreBackup) {
    if (Get-Process RustDedicated -ErrorAction SilentlyContinue | Where-Object { $_.Path -like "$ServerRoot*" }) { throw 'Arrête Rust avant de restaurer une version du Control Center.' }
    $BackupBase = [IO.Path]::GetFullPath((Join-Path $ServerRoot 'backups\control-center-updates')).TrimEnd('\') + '\'
    $BackupRoot = [IO.Path]::GetFullPath($RestoreBackup)
    if (-not $BackupRoot.StartsWith($BackupBase,[StringComparison]::OrdinalIgnoreCase)) { throw 'Sauvegarde de mise à jour hors du dossier autorisé.' }
    $BackupManifestPath = Join-Path $BackupRoot 'backup-manifest.json'
    if (-not (Test-Path -LiteralPath $BackupManifestPath -PathType Leaf)) { throw 'Manifeste de restauration introuvable.' }
    $BackupManifest = Get-Content -LiteralPath $BackupManifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
    foreach ($Entry in @($BackupManifest.files)) {
        $Relative = ([string]$Entry.path).Replace('/','\')
        if ($Relative -match '(^|\\)\.\.(\\|$)' -or [IO.Path]::IsPathRooted($Relative)) { throw 'Chemin de restauration invalide.' }
        $Target = [IO.Path]::GetFullPath((Join-Path $ServerRoot $Relative))
        if (-not $Target.StartsWith($ServerRoot + [IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase)) { throw 'Cible de restauration hors installation.' }
        if ([bool]$Entry.hadOriginal) {
            $Source = [IO.Path]::GetFullPath((Join-Path $BackupRoot $Relative))
            if (-not $Source.StartsWith($BackupRoot + [IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase) -or -not (Test-Path -LiteralPath $Source -PathType Leaf)) { throw "Fichier de restauration absent : $Relative" }
            if ($Entry.PSObject.Properties.Name -contains 'length' -and [long]$Entry.length -ne [long](Get-Item -LiteralPath $Source).Length) { throw "Taille de sauvegarde invalide : $Relative" }
            if ($Entry.PSObject.Properties.Name -contains 'sha256' -and [string]$Entry.sha256 -and (Get-FileHash -LiteralPath $Source -Algorithm SHA256).Hash.ToLowerInvariant() -ne ([string]$Entry.sha256).ToLowerInvariant()) { throw "Empreinte de sauvegarde invalide : $Relative" }
            [IO.Directory]::CreateDirectory((Split-Path $Target -Parent)) | Out-Null
            Copy-Item -LiteralPath $Source -Destination $Target -Force
        } elseif (Test-Path -LiteralPath $Target -PathType Leaf) {
            Remove-Item -LiteralPath $Target -Force
        }
    }
    $Result = [pscustomobject]@{Restored=$true;Version=[string]$BackupManifest.previousVersion;BackupRoot=$BackupRoot}
    if ($Relaunch) { Start-Process -FilePath (Join-Path $env:SystemRoot 'System32\wscript.exe') -ArgumentList ('"' + (Join-Path $ServerRoot 'LANCER-CONTROL-CENTER.vbs') + '"') -WorkingDirectory $ServerRoot -WindowStyle Hidden }
    return Write-UpdateResult $Result
}

try {
    if (-not $PackageRoot) {
        $StatePath = Join-Path $ServerRoot 'data\control-center-state.json';$SavedState=$null
        if (Test-Path -LiteralPath $StatePath) { try { $SavedState=Get-Content -LiteralPath $StatePath -Raw -Encoding UTF8 | ConvertFrom-Json } catch {} }
        if (-not $Repository -and $SavedState) { $Repository = [string]$SavedState.releaseRepository }
        if (-not $Channel -and $SavedState -and $SavedState.PSObject.Properties.Name -contains 'releaseChannel') { $Channel=[string]$SavedState.releaseChannel }
        if (-not $Channel) { $Channel='stable' }
        if ($Channel -notin @('stable','beta')) { throw "Canal de mise à jour invalide : $Channel" }
        if ($Repository -notmatch '^[^/\s]+/[^/\s]+$') { throw 'Configure le dépôt GitHub sous la forme owner/repository ou utilise -Repository.' }
        $Headers = @{ 'User-Agent'='RustServerControlCenter'; 'Accept'='application/vnd.github+json'; 'X-GitHub-Api-Version'='2026-03-10' }
        if ($Channel -eq 'beta') {
            $Releases=@(Invoke-RestMethod -Uri ("https://api.github.com/repos/$Repository/releases?per_page=20") -Headers $Headers)
            $Release=$Releases | Where-Object { -not [bool]$_.draft } | Select-Object -First 1
            if (-not $Release) { throw 'Aucune release stable ou bêta publiée.' }
        } else { $Release = Invoke-RestMethod -Uri ("https://api.github.com/repos/$Repository/releases/latest") -Headers $Headers }
        $ZipAsset = @($Release.assets | Where-Object name -like 'RustServerControlCenter-Portable-v*.zip' | Sort-Object name -Descending) | Select-Object -First 1
        if (-not $ZipAsset) { throw "La dernière release ne contient pas l'archive portable attendue." }
        $ChecksumAsset = @($Release.assets | Where-Object name -eq ($ZipAsset.name + '.sha256')) | Select-Object -First 1
        if (-not $ChecksumAsset) { throw 'La release ne contient pas la somme SHA256 attendue.' }
        if ($CheckOnly) { $Latest=([string]$Release.tag_name).TrimStart('v');return Write-UpdateResult ([pscustomobject]@{ CurrentVersion=$CurrentVersion; LatestVersion=$Latest; UpdateAvailable=((Compare-ControlCenterVersion $Latest $CurrentVersion)-gt 0); Repository=$Repository;Channel=$Channel;Prerelease=[bool]$Release.prerelease }) }
        $TemporaryRoot = Join-Path ([IO.Path]::GetTempPath()) ('RustControlCenterUpdate-' + [guid]::NewGuid().ToString('N'))
        [IO.Directory]::CreateDirectory($TemporaryRoot) | Out-Null
        $ZipPath = Join-Path $TemporaryRoot $ZipAsset.name
        $ChecksumPath = $ZipPath + '.sha256'
        Invoke-WebRequest -Uri $ZipAsset.browser_download_url -Headers $Headers -OutFile $ZipPath
        Invoke-WebRequest -Uri $ChecksumAsset.browser_download_url -Headers $Headers -OutFile $ChecksumPath
        $Expected = ((Get-Content -LiteralPath $ChecksumPath -Raw).Trim() -split '\s+')[0].ToLowerInvariant()
        $Actual = (Get-FileHash -LiteralPath $ZipPath -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($Expected -ne $Actual) { throw 'Somme SHA256 invalide : le paquet téléchargé est refusé.' }
        $ExtractRoot = Join-Path $TemporaryRoot 'package'
        Expand-Archive -LiteralPath $ZipPath -DestinationPath $ExtractRoot
        $PackageRoot = @((Get-ChildItem -LiteralPath $ExtractRoot -Directory) + @((Get-Item -LiteralPath $ExtractRoot))) | Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName 'release-manifest.json') } | Select-Object -First 1 -ExpandProperty FullName
        if (-not $PackageRoot) { throw 'Racine du paquet introuvable après extraction.' }
    }

    $PackageRoot = [IO.Path]::GetFullPath($PackageRoot)
    $ManifestPath = Join-Path $PackageRoot 'release-manifest.json'
    $ReleaseTest = Join-Path $PackageRoot 'scripts\Test-Release.ps1'
    if (-not (Test-Path -LiteralPath $ManifestPath) -or -not (Test-Path -LiteralPath $ReleaseTest)) { throw 'Paquet de mise à jour incomplet.' }
    & $ReleaseTest -PackageRoot $PackageRoot | Out-Null
    $Manifest = Get-Content -LiteralPath $ManifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($CheckOnly) { return Write-UpdateResult ([pscustomobject]@{ CurrentVersion=$CurrentVersion; LatestVersion=[string]$Manifest.version; UpdateAvailable=((Compare-ControlCenterVersion ([string]$Manifest.version) $CurrentVersion)-gt 0); PackageRoot=$PackageRoot;Channel=$(if($Channel){$Channel}else{'local'}) }) }

    $SignatureStatus = 'Unsigned'
    if ($Manifest.PSObject.Properties.Name -contains 'signing' -and [string]$Manifest.signing.thumbprint) {
        foreach ($ScriptEntry in @($Manifest.files | Where-Object { [IO.Path]::GetExtension([string]$_.path) -in @('.ps1','.psm1','.psd1') })) {
            $ScriptPath = Join-Path $PackageRoot ([string]$ScriptEntry.path).Replace('/','\')
            $Signature = Get-AuthenticodeSignature -LiteralPath $ScriptPath
            if ([string]$Signature.Status -ne 'Valid' -or [string]$Signature.SignerCertificate.Thumbprint -ne [string]$Manifest.signing.thumbprint) { throw "Signature Authenticode invalide : $($ScriptEntry.path)" }
        }
        $SignatureStatus = 'Valid'
    }

    $BackupRoot = Join-Path $ServerRoot ('backups\control-center-updates\' + (Get-Date -Format 'yyyyMMdd-HHmmss'))
    [IO.Directory]::CreateDirectory($BackupRoot) | Out-Null
    $Preserved = @('instances.json','config/server.cfg','config/users.cfg')
    $BackupEntries = New-Object Collections.Generic.List[object]
    foreach ($Entry in @($Manifest.files)) {
        $RelativeSlash = ([string]$Entry.path).Replace('\','/')
        if ($Preserved -contains $RelativeSlash) { continue }
        $Source = [IO.Path]::GetFullPath((Join-Path $PackageRoot $RelativeSlash.Replace('/','\')))
        $Target = [IO.Path]::GetFullPath((Join-Path $ServerRoot $RelativeSlash.Replace('/','\')))
        if (-not $Source.StartsWith($PackageRoot + [IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase)) { throw "Source invalide : $RelativeSlash" }
        if (-not $Target.StartsWith($ServerRoot + [IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase)) { throw "Cible invalide : $RelativeSlash" }
        $HadOriginal = Test-Path -LiteralPath $Target -PathType Leaf
        if ($HadOriginal) {
            $BackupTarget = Join-Path $BackupRoot $RelativeSlash.Replace('/','\')
            [IO.Directory]::CreateDirectory((Split-Path $BackupTarget -Parent)) | Out-Null
            Copy-Item -LiteralPath $Target -Destination $BackupTarget -Force
        }
        $BackupEntries.Add([pscustomobject]@{path=$RelativeSlash;hadOriginal=[bool]$HadOriginal;length=$(if($HadOriginal){[long](Get-Item -LiteralPath $BackupTarget).Length}else{0L});sha256=$(if($HadOriginal){(Get-FileHash -LiteralPath $BackupTarget -Algorithm SHA256).Hash.ToLowerInvariant()}else{''})})
    }
    $CurrentManifestPath = Join-Path $ServerRoot 'release-manifest.json'
    $HadCurrentManifest = Test-Path -LiteralPath $CurrentManifestPath -PathType Leaf
    $BackupManifestCopy = Join-Path $BackupRoot 'release-manifest.json'
    if ($HadCurrentManifest) { Copy-Item -LiteralPath $CurrentManifestPath -Destination $BackupManifestCopy -Force }
    $BackupEntries.Add([pscustomobject]@{path='release-manifest.json';hadOriginal=[bool]$HadCurrentManifest;length=$(if($HadCurrentManifest){[long](Get-Item -LiteralPath $BackupManifestCopy).Length}else{0L});sha256=$(if($HadCurrentManifest){(Get-FileHash -LiteralPath $BackupManifestCopy -Algorithm SHA256).Hash.ToLowerInvariant()}else{''})})
    $BackupManifest = [pscustomobject][ordered]@{schemaVersion=1;createdUtc=[datetime]::UtcNow.ToString('o');previousVersion=$CurrentVersion;targetVersion=[string]$Manifest.version;signatureStatus=$SignatureStatus;files=[object[]]$BackupEntries.ToArray()}
    [IO.File]::WriteAllText((Join-Path $BackupRoot 'backup-manifest.json'),($BackupManifest | ConvertTo-Json -Depth 8),[Text.UTF8Encoding]::new($false))

    foreach ($Entry in @($Manifest.files)) {
        $RelativeSlash = ([string]$Entry.path).Replace('\','/')
        if ($Preserved -contains $RelativeSlash) { continue }
        $Source = [IO.Path]::GetFullPath((Join-Path $PackageRoot $RelativeSlash.Replace('/','\')))
        $Target = [IO.Path]::GetFullPath((Join-Path $ServerRoot $RelativeSlash.Replace('/','\')))
        [IO.Directory]::CreateDirectory((Split-Path $Target -Parent)) | Out-Null
        Copy-Item -LiteralPath $Source -Destination $Target -Force
    }
    Copy-Item -LiteralPath $ManifestPath -Destination (Join-Path $ServerRoot 'release-manifest.json') -Force
    if ($Relaunch) { Start-Process -FilePath (Join-Path $env:SystemRoot 'System32\wscript.exe') -ArgumentList ('"' + (Join-Path $ServerRoot 'LANCER-CONTROL-CENTER.vbs') + '"') -WorkingDirectory $ServerRoot -WindowStyle Hidden }
    Write-UpdateResult ([pscustomobject]@{ Updated=$true; PreviousVersion=$CurrentVersion; Version=[string]$Manifest.version; BackupRoot=$BackupRoot; SignatureStatus=$SignatureStatus })
}
finally {
    if ($TemporaryRoot -and (Test-Path -LiteralPath $TemporaryRoot -PathType Container)) { [IO.Directory]::Delete($TemporaryRoot,$true) }
}
