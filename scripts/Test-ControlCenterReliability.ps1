[CmdletBinding()]
param([switch]$KeepFixture)

$ErrorActionPreference = 'Stop'
$SourceRoot = Split-Path $PSScriptRoot -Parent
. (Join-Path $SourceRoot 'tool\RustRPG-Common.ps1')
. (Join-Path $SourceRoot 'tool\RustRPG-Operations.ps1')
. (Join-Path $SourceRoot 'tool\RustRPG-Services.ps1')
$FixtureRoot = Join-Path ([IO.Path]::GetTempPath()) ('RustControlCenterReliability-' + [guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($FixtureRoot) | Out-Null
$Results = New-Object Collections.Generic.List[object]

function Add-TestResult([string]$Name,[bool]$Passed,[string]$Detail) {
    $Results.Add([pscustomobject]@{ Test=$Name; Passed=$Passed; Detail=$Detail })
    if (-not $Passed) { throw "$Name : $Detail" }
}

function Write-TestFile([string]$Relative,[string]$Content) {
    $Path = Join-Path $FixtureRoot $Relative
    [IO.Directory]::CreateDirectory((Split-Path $Path -Parent)) | Out-Null
    [IO.File]::WriteAllText($Path,$Content,[Text.UTF8Encoding]::new($true))
    return $Path
}

try {
    $Catalog = [ordered]@{
        version=1; selectedId='qa'; allowMultiInstance=$false; language='fr-FR'; uiMode='simple';
        instances=@([ordered]@{id='qa';displayName='QA isolé';identity='qa-world';enabled=$true;isPublic=$false;serverPort=39015;rconPort=39016;queryPort=39017;appPort=39018;level='Procedural Map';levelUrl='';seed=42;worldSize=1000;memoryEstimateGb=4})
    }
    $null = Write-TestFile 'instances.json' ($Catalog | ConvertTo-Json -Depth 8)
    $null = Write-TestFile 'config\server.cfg' 'server.hostname "QA"'
    $null = Write-TestFile 'config\users.cfg' ''
    $null = Write-TestFile '.rcon-password.txt' 'qa-secret-123456789'
    $null = Write-TestFile 'LANCER-CONTROL-CENTER.vbs' "CreateObject(`"WScript.Shell`").Run `"powershell.exe`", 0, False"
    $null = Write-TestFile 'server\server\qa-world\qa-world.sav' 'WORLD-V1'
    $null = Write-TestFile 'server\server\qa-world\player.blueprints.5.db' 'BLUEPRINTS-V1'
    $null = Write-TestFile 'server\server\qa-world\procedural.map' 'MAP-V1'
    $null = Write-TestFile 'server\server\qa-world\cfg\server.cfg' 'server.hostname "QA"'
    $null = Write-TestFile 'server\carbon\data\plugin.json' '{"score":12}'
    $null = Write-TestFile 'server\carbon\config.json' '{}'
    $LegacySchedule = [ordered]@{schemaVersion=1;updatedUtc='';schedules=@([ordered]@{id='legacy';name='Ancienne règle';identity='qa-world';action='Backup';recurrence='Daily';localTime='03:00';dayOfWeek='Monday';intervalHours=24;enabled=$false;stopAndRestart=$false;resetPluginData=$false;cleanGeneratedMaps=$true;nextRunUtc='';lastRunUtc='';lastStatus='Never';lastDetail='';lastOperationId='';createdUtc='';updatedUtc=''})}
    $null = Write-TestFile 'data\maintenance-schedules.json' ($LegacySchedule | ConvertTo-Json -Depth 8)
    $LegacyOperations = [ordered]@{schemaVersion=1;activeOperationId='';operations=@([ordered]@{id='legacy-op';type='Backup';title='Ancienne opération';serverId='qa-world';status='Succeeded';startedUtc='2026-01-01T00:00:00Z';completedUtc='2026-01-01T00:00:01Z';durationSeconds=1;processId=0})}
    $null = Write-TestFile 'data\operation-center.json' ($LegacyOperations | ConvertTo-Json -Depth 8)

    $ServerRoot = $FixtureRoot
    $Migration = Invoke-RustControlCenterMigrations -ServerRoot $FixtureRoot
    $MigratedCatalog = Get-RustInstanceCatalog -ServerRoot $FixtureRoot
    $MigratedSchedules = Get-Content -LiteralPath (Join-Path $FixtureRoot 'data\maintenance-schedules.json') -Raw | ConvertFrom-Json
    $MigratedOperations = Get-Content -LiteralPath (Join-Path $FixtureRoot 'data\operation-center.json') -Raw | ConvertFrom-Json
    $MigrationBackups = @(Get-ChildItem -LiteralPath (Join-Path $FixtureRoot 'data') -Filter '*.migration-*.bak').Count
    Add-TestResult 'Migrations v1 vers v3' ([int]$MigratedCatalog.version -eq 3 -and [string]$MigratedCatalog.instances[0].isolationMode -eq 'shared' -and [bool]$MigratedCatalog.instances[0].monitoringEnabled -and [int]$MigratedSchedules.schemaVersion -eq 2 -and [int]$MigratedSchedules.schedules[0].retentionCount -eq 10 -and [int]$MigratedOperations.schemaVersion -eq 2 -and [string]$MigratedOperations.operations[0].source -eq 'control-center' -and $Migration.CurrentSchema -eq 3 -and $MigrationBackups -eq 2 -and @(Get-ChildItem -LiteralPath $FixtureRoot -Filter 'instances.json.migration-*.bak').Count -eq 2) (($Migration.Changes) -join ', ')

    $FirewallFixture = (@(
        'Rule Name:                            rustdedicated.exe'
        '----------------------------------------------------------------------'
        'Enabled:                              Yes'
        'Direction:                            In'
        'Profiles:                             Public'
        'Protocol:                             UDP'
        'LocalPort:                            Any'
        'RemotePort:                           Any'
        'Program:                              C:\QA\RustDedicated.exe'
        'Action:                               Allow'
    ) -join "`r`n")
    $ProgramFirewallRules = @(Get-RustRpgFirewallAllowRulesFromText -Text $FirewallFixture -Protocol UDP -Port 39015 -ProgramPaths @('C:\QA\RustDedicated.exe') -AllowProgramWidePort)
    $WrongProgramFirewallRules = @(Get-RustRpgFirewallAllowRulesFromText -Text $FirewallFixture -Protocol UDP -Port 39015 -ProgramPaths @('C:\Other\RustDedicated.exe') -AllowProgramWidePort)
    Add-TestResult 'Pare-feu : autorisation Rust par programme' ($ProgramFirewallRules.Count -eq 1 -and $WrongProgramFirewallRules.Count -eq 0) 'La règle Windows standard couvrant RustDedicated.exe est reconnue sans accepter un autre chemin.'

    $SteamFixture = '{"response":{"success":true,"servers":[{"addr":"203.0.113.10:39017","appid":252490,"gameport":39015,"secure":true}]}}' | ConvertFrom-Json
    $SteamRecord = @(Find-RustRpgSteamServerRecord -Document $SteamFixture -PublicIp '203.0.113.10' -QueryPort 39017)
    $WrongSteamRecord = @(Find-RustRpgSteamServerRecord -Document $SteamFixture -PublicIp '203.0.113.10' -QueryPort 39018)
    Add-TestResult 'Visibilite Steam : réponse externe ciblée' ($SteamRecord.Count -eq 1 -and [int]$SteamRecord[0].gameport -eq 39015 -and $WrongSteamRecord.Count -eq 0) 'Seul un serveur Rust avec adresse et query port attendus est accepté.'

    $Isolation = Set-RustInstanceIsolation -ServerRoot $FixtureRoot -InstanceId 'qa' -Mode full
    $RuntimeExe = Write-TestFile 'data\instances\qa\runtime\RustDedicated.exe' 'QA-RUNTIME'
    $IsolationReady = Initialize-RustIsolatedRuntime -ServerRoot $FixtureRoot -InstanceId 'qa' -SkipSteamInstall
    Add-TestResult 'Isolation complète par instance' ([string]$IsolationReady.Mode -eq 'full' -and $IsolationReady.Ready -and $IsolationReady.RuntimeRoot -like '*data\instances\qa\runtime') ([string]$IsolationReady.RuntimeRoot)
    $null = Set-RustInstanceIsolation -ServerRoot $FixtureRoot -InstanceId 'qa' -Mode shared

    $SecondInstance = New-RustServerInstanceFromProfile -ServerRoot $FixtureRoot -DisplayName 'QA isolé 2' -Identity 'qa-2' -ServerPort 39115 -RconPort 39116 -QueryPort 39117 -AppPort 39118 -WorldSize 1000 -MemoryEstimateGb 4 -SelectAfterCreation $false
    $null = Set-RustMultiInstanceEnabled -ServerRoot $FixtureRoot -Enabled $true
    $null = Set-RustInstanceIsolation -ServerRoot $FixtureRoot -InstanceId 'qa' -Mode full
    $null = Set-RustInstanceIsolation -ServerRoot $FixtureRoot -InstanceId 'qa-2' -Mode full
    $null = Write-TestFile 'data\instances\qa-2\runtime\RustDedicated.exe' 'QA-RUNTIME-2'
    $MultiPlan = Get-RustMultiInstanceReadiness -ServerRoot $FixtureRoot -InstanceIds @('qa','qa-2')
    Add-TestResult 'Préparation multi-instance isolée' ($MultiPlan.Ready -and $MultiPlan.TargetCount -eq 2 -and $MultiPlan.EstimatedRamGb -eq 8) "$($MultiPlan.TargetCount) runtimes, $($MultiPlan.EstimatedRamGb) Go estimés, aucun blocage."
    $null = Set-RustInstanceIsolation -ServerRoot $FixtureRoot -InstanceId 'qa' -Mode shared
    $null = Remove-RustServerInstance -ServerRoot $FixtureRoot -Id 'qa-2'
    $null = Set-RustSelectedInstance -ServerRoot $FixtureRoot -Id 'qa'
    $null = Set-RustMultiInstanceEnabled -ServerRoot $FixtureRoot -Enabled $false

    $BackupPath = New-RustServerBackup -ServerRoot $FixtureRoot -Identity 'qa-world' -Kind 'qa-manual'
    $BackupCheck = Test-RustServerBackup -ServerRoot $FixtureRoot -BackupPath $BackupPath
    Add-TestResult 'Sauvegarde ZIP et manifeste SHA256' ($BackupCheck.Valid -and $BackupCheck.Integrity -eq 'VERIFIED' -and $BackupCheck.CheckedFiles -ge 4) $BackupCheck.Detail

    $CorruptPath = Join-Path (Split-Path $BackupPath -Parent) 'corrupted.zip'
    Copy-Item -LiteralPath $BackupPath -Destination $CorruptPath
    $Stream = [IO.File]::Open($CorruptPath,[IO.FileMode]::Open,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
    try { $Stream.Position = [math]::Max(0,$Stream.Length - 31); $Byte = $Stream.ReadByte(); $Stream.Position--; $Stream.WriteByte(($Byte -bxor 0xFF)) }
    finally { $Stream.Dispose() }
    $CorruptCheck = Test-RustServerBackup -ServerRoot $FixtureRoot -BackupPath $CorruptPath
    Add-TestResult 'Archive corrompue refusée' (-not $CorruptCheck.Valid) $CorruptCheck.Detail
    [IO.File]::Delete($CorruptPath)

    $null = Write-TestFile 'server\server\qa-world\qa-world.sav' 'WORLD-MODIFIED'
    $RestoredIdentity = Restore-RustServerBackup -ServerRoot $FixtureRoot -BackupPath $BackupPath
    $RestoredWorld = Get-Content -LiteralPath (Join-Path $FixtureRoot 'server\server\qa-world\qa-world.sav') -Raw
    Add-TestResult 'Restauration transactionnelle' ($RestoredIdentity -eq 'qa-world' -and $RestoredWorld -match 'WORLD-V1' -and @(Get-RustServerBackups -ServerRoot $FixtureRoot | Where-Object Type -eq 'pre-restore').Count -eq 1) 'Point de retour créé et monde restauré.'

    1..3 | ForEach-Object { $null = New-RustServerBackup -ServerRoot $FixtureRoot -Identity 'qa-world' -Kind 'scheduled' }
    $Removed = @(Remove-RustOldBackups -ServerRoot $FixtureRoot -Identity 'qa-world' -Keep 2 -Kinds @('scheduled'))
    $RemainingScheduled = @(Get-RustServerBackups -ServerRoot $FixtureRoot | Where-Object Type -eq 'scheduled').Count
    Add-TestResult 'Rotation des sauvegardes' ($Removed.Count -eq 1 -and $RemainingScheduled -eq 2) "$($Removed.Count) retirée(s), $RemainingScheduled conservée(s)."

    $BackupSchedule = Set-RustMaintenanceSchedule -ServerRoot $FixtureRoot -Name 'QA backup' -Identity 'qa-world' -Action Backup -Recurrence Interval -IntervalHours 24 -RetentionCount 2
    & (Join-Path $SourceRoot 'tool\RustRPG-MaintenanceWorker.ps1') -ServerRoot $FixtureRoot -ScheduleId ([string]$BackupSchedule.id) -Force | Out-Null
    $BackupScheduleResult = @((Get-RustMaintenanceScheduleStore -ServerRoot $FixtureRoot).schedules | Where-Object id -eq $BackupSchedule.id)[0]
    Add-TestResult 'Planificateur : sauvegarde réelle' ([string]$BackupScheduleResult.lastStatus -eq 'Succeeded') ([string]$BackupScheduleResult.lastDetail)

    $null = Write-TestFile 'server\server\qa-world\qa-world.sav' 'WORLD-BEFORE-MAP-WIPE'
    $null = Write-TestFile 'server\server\qa-world\procedural.map' 'MAP-BEFORE-WIPE'
    $MapSchedule = Set-RustMaintenanceSchedule -ServerRoot $FixtureRoot -Name 'QA map wipe' -Identity 'qa-world' -Action MapWipe -Recurrence Weekly -LocalTime '04:00' -DayOfWeek Thursday -RetentionCount 2 -CleanGeneratedMaps $true
    & (Join-Path $SourceRoot 'tool\RustRPG-MaintenanceWorker.ps1') -ServerRoot $FixtureRoot -ScheduleId ([string]$MapSchedule.id) -Force | Out-Null
    $MapScheduleResult = @((Get-RustMaintenanceScheduleStore -ServerRoot $FixtureRoot).schedules | Where-Object id -eq $MapSchedule.id)[0]
    $BlueprintStillThere = Test-Path -LiteralPath (Join-Path $FixtureRoot 'server\server\qa-world\player.blueprints.5.db')
    $MapGone = -not (Test-Path -LiteralPath (Join-Path $FixtureRoot 'server\server\qa-world\qa-world.sav'))
    Add-TestResult 'Planificateur : map wipe réel' ([string]$MapScheduleResult.lastStatus -eq 'Succeeded' -and $MapGone -and $BlueprintStillThere) ([string]$MapScheduleResult.lastDetail)

    $null = Write-TestFile 'server\server\qa-world\qa-world.sav' 'WORLD-BEFORE-FULL-WIPE'
    $FullSchedule = Set-RustMaintenanceSchedule -ServerRoot $FixtureRoot -Name 'QA full wipe' -Identity 'qa-world' -Action FullWipe -Recurrence Daily -LocalTime '05:00' -RetentionCount 2
    & (Join-Path $SourceRoot 'tool\RustRPG-MaintenanceWorker.ps1') -ServerRoot $FixtureRoot -ScheduleId ([string]$FullSchedule.id) -Force | Out-Null
    $FullScheduleResult = @((Get-RustMaintenanceScheduleStore -ServerRoot $FixtureRoot).schedules | Where-Object id -eq $FullSchedule.id)[0]
    $BlueprintGone = -not (Test-Path -LiteralPath (Join-Path $FixtureRoot 'server\server\qa-world\player.blueprints.5.db'))
    Add-TestResult 'Planificateur : full wipe réel' ([string]$FullScheduleResult.lastStatus -eq 'Succeeded' -and $BlueprintGone) ([string]$FullScheduleResult.lastDetail)

    $Diagnostics = @(Get-RustControlCenterDiagnostics -ServerRoot $FixtureRoot)
    $Categories = @($Diagnostics.Category | Sort-Object -Unique)
    $LauncherDiagnostic = @($Diagnostics | Where-Object Check -eq 'Lanceur silencieux' | Select-Object -First 1)
    $RepairCodes = @($Diagnostics.RepairCode | Where-Object { $_ } | Sort-Object -Unique)
    Add-TestResult 'Diagnostic global et réparations ciblées' ($Diagnostics.Count -ge 12 -and 'Sauvegardes' -in $Categories -and 'Sécurité' -in $Categories -and 'Automatisation' -in $Categories -and $LauncherDiagnostic[0].Status -eq 'OK' -and 'ServerUpdate' -in $RepairCodes -and 'GenerateRconSecret' -in $RepairCodes) "$($Diagnostics.Count) contrôles, $($RepairCodes.Count) actions guidées."

    $PreviousSecret = Get-Content -LiteralPath (Join-Path $FixtureRoot '.rcon-password.txt') -Raw
    $NewSecretResult = New-RustRconSecret -ServerRoot $FixtureRoot
    $NewSecret = (Get-Content -LiteralPath $NewSecretResult.Path -Raw).Trim()
    Add-TestResult 'Réparation ciblée du secret RCON' ($NewSecret.Length -ge 40 -and $NewSecret -ne $PreviousSecret.Trim() -and (Test-Path -LiteralPath $NewSecretResult.BackupPath)) "Secret aléatoire de $($NewSecret.Length) caractères, ancien fichier sauvegardé."

    $HostHealth = Get-RustHostHealthSnapshot -ServerRoot $FixtureRoot
    Add-TestResult 'Santé du PC et capacité multi-instance' (@($HostHealth.Rows).Count -ge 6 -and $HostHealth.TotalMemoryBytes -gt 0 -and $HostHealth.DiskFreeBytes -gt 0 -and $HostHealth.SafeAdditionalInstances -ge 0) "$(@($HostHealth.Rows).Count) contrôles, capacité supplémentaire estimée : $($HostHealth.SafeAdditionalInstances)."

    $MapSource = Write-TestFile 'qa-assets\QA Arena.map' 'RUSTEDIT-QA-MAP'
    $ImportedMap = Import-RustEditMap -ServerRoot $FixtureRoot -SourcePath $MapSource
    $DuplicateMap = Import-RustEditMap -ServerRoot $FixtureRoot -SourcePath $MapSource
    $AppliedMap = Set-RustInstanceImportedMap -ServerRoot $FixtureRoot -Identity 'qa-world' -MapId ([string]$ImportedMap.id)
    $MapStore = Get-RustMapLibrary -ServerRoot $FixtureRoot
    Add-TestResult 'Bibliothèque RustEdit vérifiée' (@($MapStore.maps).Count -eq 1 -and [string]$DuplicateMap.id -eq [string]$ImportedMap.id -and [string]$AppliedMap.LevelUrl -match '^file:///') "Carte importée une seule fois, SHA-256 $([string]$ImportedMap.sha256)."

    $OxideRuntime = Join-Path $FixtureRoot 'qa-oxide-runtime'
    [IO.Directory]::CreateDirectory((Join-Path $OxideRuntime 'oxide\plugins')) | Out-Null
    $CarbonContext = Get-RustRuntimeModContext -RuntimeRoot (Join-Path $FixtureRoot 'server')
    $OxideContext = Get-RustRuntimeModContext -RuntimeRoot $OxideRuntime
    Add-TestResult 'Détection Carbon et Oxide/uMod' ($CarbonContext.Framework -eq 'carbon' -and $CarbonContext.ConsolePrefix -eq 'c' -and $OxideContext.Framework -eq 'oxide' -and $OxideContext.ConsolePrefix -eq 'oxide') "Carbon et Oxide utilisent leurs dossiers et préfixes console dédiés."

    $Policy = Set-RustInstanceMonitorSettings -ServerRoot $FixtureRoot -InstanceId qa -Enabled $true -AutoRestart $true -MaxRestartsHour 2 -CooldownSeconds 30
    $Desired = Set-RustDesiredState -ServerRoot $FixtureRoot -InstanceId qa -State Running -Reason qa
    $Desired.changedUtc = [datetime]::UtcNow.AddMinutes(-5).ToString('o')
    $DesiredStore = Get-RustDesiredStateStore -ServerRoot $FixtureRoot
    $DesiredStore.instances[0].changedUtc = $Desired.changedUtc
    $null = Save-RustJsonAtomic -Path (Get-RustDesiredStatePath -ServerRoot $FixtureRoot) -Value $DesiredStore
    $WatchdogPlan = @(Invoke-RustWatchdogPass -ServerRoot $FixtureRoot -NoRestart)
    Add-TestResult 'Watchdog plafonné sans lancement réel' ($Policy.AutoRestart -and $WatchdogPlan.Count -eq 1 -and [string]$WatchdogPlan[0].type -eq 'RestartPlanned') ([string]$WatchdogPlan[0].detail)

    $RemoteConfig = Set-RustRemoteAccessConfig -ServerRoot $FixtureRoot -Enabled $true -BindAddress 127.0.0.1 -Port 39480
    $RemoteToken = New-RustRemoteAccessToken -ServerRoot $FixtureRoot
    $RemoteTokenRoundTrip = Get-RustRemoteAccessToken -ServerRoot $FixtureRoot
    Add-TestResult 'Accès distant chiffré et désactivable' ($RemoteConfig.enabled -and $RemoteToken.Length -ge 40 -and $RemoteTokenRoundTrip -eq $RemoteToken) "Jeton DPAPI $($RemoteToken.Length) caractères, port $($RemoteConfig.port)."

    $RemoteWorker = Join-Path $SourceRoot 'tool\RustRPG-RemoteDashboard.ps1'
    $RemoteStdOut = Join-Path $FixtureRoot 'logs\remote-qa.stdout.log'
    $RemoteStdErr = Join-Path $FixtureRoot 'logs\remote-qa.stderr.log'
    [IO.Directory]::CreateDirectory((Split-Path $RemoteStdOut -Parent)) | Out-Null
    $RemoteProcess = Start-Process -FilePath (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe') -ArgumentList @('-NoLogo','-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-File',('"'+$RemoteWorker+'"'),'-ServerRoot',('"'+$FixtureRoot+'"'),'-MaxRequests','3') -WorkingDirectory $SourceRoot -WindowStyle Hidden -PassThru -RedirectStandardOutput $RemoteStdOut -RedirectStandardError $RemoteStdErr
    try {
        $Health = $null
        for($Attempt=0;$Attempt-lt20-and-not$Health;$Attempt++) {
            try { $Health = Invoke-RestMethod -Uri 'http://127.0.0.1:39480/health' -TimeoutSec 2 }
            catch { Start-Sleep -Milliseconds 150 }
        }
        $UnauthorizedStatus = 0
        try { $null = Invoke-WebRequest -UseBasicParsing -Uri 'http://127.0.0.1:39480/api/status' -TimeoutSec 3 }
        catch { if($_.Exception.Response){$UnauthorizedStatus=[int]$_.Exception.Response.StatusCode} }
        $Authorized = Invoke-RestMethod -Uri 'http://127.0.0.1:39480/api/status' -Headers @{Authorization=('Bearer '+$RemoteToken)} -TimeoutSec 3
        $null = $RemoteProcess.WaitForExit(5000)
        Add-TestResult 'API distante locale authentifiée' ($Health.status -eq 'ok' -and $UnauthorizedStatus -eq 401 -and @($Authorized.instances).Count -eq 1 -and $RemoteProcess.HasExited) "Santé OK, refus anonyme HTTP $UnauthorizedStatus, statut authentifié reçu."
    }
    finally {
        if(-not$RemoteProcess.HasExited){$RemoteProcess.Kill();$null=$RemoteProcess.WaitForExit(3000)}
    }

    $CatalogDocument = [pscustomobject]@{schemaVersion=1;plugins=@([pscustomobject]@{id='base';name='Base';version='1.0.0';fileName='Base.cs';downloadUrl='https://example.invalid/Base.cs';dependencies=@()},[pscustomobject]@{id='addon';name='Addon';version='1.0.0';fileName='Addon.cs';downloadUrl='https://example.invalid/Addon.cs';dependencies=@('base')})}
    $null = Test-RustPluginCatalogDocument -Document $CatalogDocument
    $SourceStore = [pscustomobject]@{schemaVersion=1;sources=@([pscustomobject]@{id='qa-source';name='QA';url='https://example.invalid/catalog.json';enabled=$true;builtIn=$false;lastSyncUtc='';lastError=''})}
    $null = Save-RustPluginCatalogSources -ServerRoot $FixtureRoot -Store $SourceStore
    $CacheRoot = Get-RustPluginCatalogCacheRoot -ServerRoot $FixtureRoot
    $null = Write-TestFile 'data\plugin-catalog-cache\qa-source.json' ($CatalogDocument | ConvertTo-Json -Depth 8)
    $DependencyOrder = @(Resolve-RustCatalogPluginDependencies -ServerRoot $FixtureRoot -PluginId addon)
    Add-TestResult 'Catalogue et dépendances automatiques' ($DependencyOrder.Count -eq 2 -and $DependencyOrder[0].Id -eq 'base' -and $DependencyOrder[1].Id -eq 'addon') (@($DependencyOrder.Id) -join ' -> ')

    $SdkManifests = @(Get-RustPluginSdkManifests -ServerRoot $FixtureRoot)
    $SdkFiles = @($SdkManifests | ForEach-Object { [string]$_.plugin.fileBase } | Sort-Object -Unique)
    $SdkActions = @($SdkManifests | ForEach-Object { @($_.actions) }).Count
    $SdkSettings = @($SdkManifests | ForEach-Object { @($_.config.settings) }).Count
    Add-TestResult 'SDK universel : manifestes embarqués valides' ($SdkManifests.Count -eq 8 -and $SdkFiles.Count -eq 8 -and $SdkActions -ge 30 -and $SdkSettings -ge 20) "$($SdkManifests.Count) manifestes, $SdkSettings réglages, $SdkActions actions."

    $InvalidSdk = Get-Content -LiteralPath (Join-Path $SourceRoot 'tool\sdk\manifests\RustStats.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    $InvalidSdk.actions[0].command = 'quit;server.writecfg'
    $InvalidSdkRejected = $false
    try { $null = Test-RustPluginSdkManifest -Manifest $InvalidSdk }
    catch { $InvalidSdkRejected = $true }
    Add-TestResult 'SDK universel : commande dangereuse refusée' $InvalidSdkRejected 'Les retours ligne, séparateurs et commandes composites ne passent pas la validation.'

    $null = Write-TestFile 'server\carbon\configs\RustRates.json' '{"MultiplicateurGlobal":1,"AppliquerRecolte":true}'
    $SdkWrite = Set-RustPluginSdkConfiguration -ServerRoot $FixtureRoot -FileBase RustRates -Values ([ordered]@{global='2.5';gather=$false;stacks=$true})
    $SdkSaved = Get-Content -LiteralPath $SdkWrite.ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
    Add-TestResult 'SDK universel : réglages typés et sauvegarde' ([double]$SdkSaved.MultiplicateurGlobal -eq 2.5 -and -not [bool]$SdkSaved.AppliquerRecolte -and [bool]$SdkSaved.AppliquerPiles -and (Test-Path -LiteralPath $SdkWrite.BackupPath)) "$($SdkWrite.UpdatedCount) valeurs validées, copie de sécurité créée."

    $VerifiedCatalog = Get-Content -LiteralPath (Join-Path $SourceRoot 'tool\catalog\plugins.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    $PinnedFiles = foreach($Plugin in @($VerifiedCatalog.plugins)) {
        $BundledPath = Join-Path (Join-Path $SourceRoot 'tool') ([string]$Plugin.bundledPath)
        $DevelopmentPath = Join-Path $SourceRoot ('carbon\plugins\' + [string]$Plugin.fileName)
        $Path = if(Test-Path -LiteralPath $BundledPath -PathType Leaf){$BundledPath}else{$DevelopmentPath}
        $ManifestPath = Join-Path (Join-Path $SourceRoot 'tool') ([string]$Plugin.bundledManifestPath)
        [pscustomobject]@{ Id=[string]$Plugin.id; Exists=(Test-Path -LiteralPath $Path -PathType Leaf); Hash=$(if(Test-Path -LiteralPath $Path -PathType Leaf){(Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()}else{''}); Expected=([string]$Plugin.sha256).ToLowerInvariant(); ManifestExists=(Test-Path -LiteralPath $ManifestPath -PathType Leaf); ManifestHash=$(if(Test-Path -LiteralPath $ManifestPath -PathType Leaf){(Get-FileHash -LiteralPath $ManifestPath -Algorithm SHA256).Hash.ToLowerInvariant()}else{''}); ManifestExpected=([string]$Plugin.manifestSha256).ToLowerInvariant() }
    }
    $InvalidPins = @($PinnedFiles | Where-Object { -not $_.Exists -or $_.Hash -ne $_.Expected -or -not $_.ManifestExists -or $_.ManifestHash -ne $_.ManifestExpected })
    Add-TestResult 'Catalogue embarqué verrouillé par SHA256' (@($VerifiedCatalog.plugins).Count -eq 8 -and $InvalidPins.Count -eq 0) "$(@($VerifiedCatalog.plugins).Count) plugins et manifestes vérifiés, $($InvalidPins.Count) empreinte(s) invalide(s)."

    $BundledRoot = Join-Path $SourceRoot 'tool\catalog\bundled'
    if(Test-Path -LiteralPath $BundledRoot -PathType Container) {
        $InstalledCatalogPlugin = @(Install-RustCatalogPlugin -ServerRoot $FixtureRoot -InstanceId qa -PluginId rust-rates)
        $InstalledPluginPath = Join-Path $FixtureRoot 'server\carbon\plugins\RustRates.cs'
        $InstalledManifestPath = Join-Path $FixtureRoot 'server\carbon\plugin-manifests\RustRates.json'
        Add-TestResult 'Installation réelle depuis le catalogue embarqué' ($InstalledCatalogPlugin.Count -eq 1 -and (Test-Path -LiteralPath $InstalledPluginPath) -and (Test-Path -LiteralPath $InstalledManifestPath) -and (Get-FileHash -LiteralPath $InstalledPluginPath -Algorithm SHA256).Hash.ToLowerInvariant() -eq $InstalledCatalogPlugin[0].Sha256 -and (Get-FileHash -LiteralPath $InstalledManifestPath -Algorithm SHA256).Hash.ToLowerInvariant() -eq $InstalledCatalogPlugin[0].ManifestSha256) ([string]$InstalledPluginPath)
    }

    [pscustomobject]@{ Passed=$true; TestCount=$Results.Count; FixtureRoot=$FixtureRoot; Results=[object[]]$Results.ToArray() }
}
finally {
    if (-not $KeepFixture -and (Test-Path -LiteralPath $FixtureRoot -PathType Container)) {
        $ResolvedFixture = [IO.Path]::GetFullPath($FixtureRoot)
        $ResolvedTemp = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
        if (-not $ResolvedFixture.StartsWith($ResolvedTemp,[StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetFileName($ResolvedFixture) -notlike 'RustControlCenterReliability-*') { throw 'Nettoyage QA refusé : chemin inattendu.' }
        [IO.Directory]::Delete($ResolvedFixture,$true)
    }
}
