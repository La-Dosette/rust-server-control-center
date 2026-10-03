# Services v10 : isolation des runtimes, supervision, catalogue de plugins,
# acces distant et sante du PC. Ce fichier ne demarre aucun service au chargement.

function Get-RustInstanceDataRoot {
    param([Parameter(Mandatory = $true)][string]$ServerRoot,[Parameter(Mandatory = $true)][string]$InstanceId)
    if ($InstanceId -notmatch '^[a-z0-9][a-z0-9-]{0,31}$') { throw "Identifiant d'instance invalide." }
    return Join-Path $ServerRoot ('data\instances\' + $InstanceId)
}

function Get-RustInstanceRuntimeRoot {
    param([Parameter(Mandatory = $true)][string]$ServerRoot,[Parameter(Mandatory = $true)]$Instance)
    $Mode = if ($Instance.PSObject.Properties.Name -contains 'isolationMode') { [string]$Instance.isolationMode } else { 'shared' }
    if ($Mode -ne 'full') { return Join-Path $ServerRoot 'server' }
    $Expected = Join-Path (Get-RustInstanceDataRoot -ServerRoot $ServerRoot -InstanceId ([string]$Instance.id)) 'runtime'
    $ExpectedFull = [IO.Path]::GetFullPath($Expected)
    if ($Instance.PSObject.Properties.Name -contains 'runtimeRoot' -and [string]$Instance.runtimeRoot) {
        $Configured = [IO.Path]::GetFullPath([string]$Instance.runtimeRoot)
        $SafeParent = [IO.Path]::GetFullPath((Join-Path $ServerRoot 'data\instances')).TrimEnd('\') + '\'
        if (-not $Configured.StartsWith($SafeParent,[StringComparison]::OrdinalIgnoreCase)) {
            throw "Le runtime isole doit rester dans data\instances pour proteger les autres dossiers."
        }
        return $Configured
    }
    return $ExpectedFull
}

function Get-RustInstanceCarbonRoot {
    param([Parameter(Mandatory = $true)][string]$ServerRoot,[Parameter(Mandatory = $true)]$Instance)
    return Join-Path (Get-RustInstanceRuntimeRoot -ServerRoot $ServerRoot -Instance $Instance) 'carbon'
}

function Get-RustInstanceIsolationStatus {
    param([Parameter(Mandatory = $true)][string]$ServerRoot,[Parameter(Mandatory = $true)]$Instance)
    $Mode = if ($Instance.PSObject.Properties.Name -contains 'isolationMode') { [string]$Instance.isolationMode } else { 'shared' }
    $Runtime = Get-RustInstanceRuntimeRoot -ServerRoot $ServerRoot -Instance $Instance
    $Exe = Join-Path $Runtime 'RustDedicated.exe'
    $Carbon = Test-Path -LiteralPath (Join-Path $Runtime 'carbon') -PathType Container
    return [pscustomobject]@{
        Mode        = $Mode
        Label       = if ($Mode -eq 'full') { 'RUNTIME ISOLE' } else { 'RUNTIME PARTAGE' }
        RuntimeRoot = $Runtime
        Ready       = if ($Mode -eq 'full') { Test-Path -LiteralPath $Exe -PathType Leaf } else { $true }
        Carbon      = [bool]$Carbon
        DiskGb      = if (Test-Path -LiteralPath $Runtime) { [math]::Round(((Get-ChildItem -LiteralPath $Runtime -File -Recurse -ErrorAction SilentlyContinue | Measure-Object Length -Sum).Sum / 1GB),2) } else { 0 }
    }
}

function Set-RustInstanceIsolation {
    param(
        [Parameter(Mandatory = $true)][string]$ServerRoot,
        [Parameter(Mandatory = $true)][string]$InstanceId,
        [Parameter(Mandatory = $true)][ValidateSet('shared','full')][string]$Mode
    )
    $Catalog = Get-RustInstanceCatalog -ServerRoot $ServerRoot
    $Instance = @($Catalog.instances | Where-Object id -eq $InstanceId) | Select-Object -First 1
    if (-not $Instance) { throw "Instance '$InstanceId' introuvable." }
    if (@(Get-RustRpgServerProcesses -ServerRoot $ServerRoot | Where-Object Identity -eq ([string]$Instance.identity)).Count) {
        throw "Arrete cette instance avant de modifier son isolation."
    }
    if ($Instance.PSObject.Properties.Name -contains 'isolationMode') { $Instance.isolationMode = $Mode }
    else { $Instance | Add-Member isolationMode $Mode }
    $RuntimeRoot = if ($Mode -eq 'full') { Join-Path (Get-RustInstanceDataRoot -ServerRoot $ServerRoot -InstanceId $InstanceId) 'runtime' } else { '' }
    if ($Instance.PSObject.Properties.Name -contains 'runtimeRoot') { $Instance.runtimeRoot = $RuntimeRoot }
    else { $Instance | Add-Member runtimeRoot $RuntimeRoot }
    if ($Mode -eq 'full') { [IO.Directory]::CreateDirectory((Split-Path $RuntimeRoot -Parent)) | Out-Null }
    $null = Save-RustInstanceCatalog -ServerRoot $ServerRoot -Catalog $Catalog
    return Get-RustInstanceIsolationStatus -ServerRoot $ServerRoot -Instance $Instance
}

function Copy-RustCarbonToIsolatedRuntime {
    param([Parameter(Mandatory = $true)][string]$ServerRoot,[Parameter(Mandatory = $true)][string]$RuntimeRoot)
    $SourceRuntime = Join-Path $ServerRoot 'server'
    $SourceCarbon = Join-Path $SourceRuntime 'carbon'
    if (-not (Test-Path -LiteralPath $SourceCarbon -PathType Container)) { return [pscustomobject]@{Copied=$false;Detail='Installation source vanilla.'} }
    if (-not (Test-Path -LiteralPath (Join-Path $RuntimeRoot 'RustDedicated.exe') -PathType Leaf)) { throw 'Installe Rust dans le runtime isole avant Carbon.' }
    [IO.Directory]::CreateDirectory((Join-Path $RuntimeRoot 'carbon')) | Out-Null
    Copy-Item -LiteralPath $SourceCarbon -Destination $RuntimeRoot -Recurse -Force
    foreach ($Name in @('Carbon.targets','doorstop_config.ini','winhttp.dll')) {
        $Source = Join-Path $SourceRuntime $Name
        if (Test-Path -LiteralPath $Source -PathType Leaf) { Copy-Item -LiteralPath $Source -Destination (Join-Path $RuntimeRoot $Name) -Force }
    }
    return [pscustomobject]@{Copied=$true;Detail='Carbon copie dans le runtime isole.'}
}

function Initialize-RustIsolatedRuntime {
    param(
        [Parameter(Mandatory = $true)][string]$ServerRoot,
        [Parameter(Mandatory = $true)][string]$InstanceId,
        [switch]$IncludeCarbon,
        [switch]$SkipSteamInstall
    )
    $Instance = Get-RustServerInstance -ServerRoot $ServerRoot -Id $InstanceId
    if (-not $Instance) { throw "Instance '$InstanceId' introuvable." }
    if ([string]$Instance.isolationMode -ne 'full') { throw "Active d'abord l'isolation complete pour cette instance." }
    $Runtime = Get-RustInstanceRuntimeRoot -ServerRoot $ServerRoot -Instance $Instance
    $SafeParent = [IO.Path]::GetFullPath((Join-Path $ServerRoot 'data\instances')).TrimEnd('\') + '\'
    if (-not ([IO.Path]::GetFullPath($Runtime)).StartsWith($SafeParent,[StringComparison]::OrdinalIgnoreCase)) { throw 'Chemin de runtime refuse.' }
    [IO.Directory]::CreateDirectory($Runtime) | Out-Null
    if (-not $SkipSteamInstall) {
        $SteamCmd = Join-Path $ServerRoot 'steamcmd\steamcmd.exe'
        if (-not (Test-Path -LiteralPath $SteamCmd -PathType Leaf)) { throw "SteamCMD est absent. Lance d'abord la mise a jour du serveur principal." }
        $Drive = [IO.DriveInfo]::new([IO.Path]::GetPathRoot($Runtime))
        if ($Drive.AvailableFreeSpace -lt 20GB) { throw 'Au moins 20 Go libres sont requis pour un runtime Rust isole.' }
        $LogDir = Join-Path $ServerRoot 'logs\isolation'
        [IO.Directory]::CreateDirectory($LogDir) | Out-Null
        $Log = Join-Path $LogDir ("install-$InstanceId-" + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.log')
        $ErrorLog = $Log + '.err'
        $Arguments = @('+force_install_dir',('"' + $Runtime + '"'),'+login','anonymous','+app_update','258550','validate','+quit')
        $Process = Start-Process -FilePath $SteamCmd -ArgumentList $Arguments -WorkingDirectory (Split-Path $SteamCmd -Parent) -WindowStyle Hidden -RedirectStandardOutput $Log -RedirectStandardError $ErrorLog -Wait -PassThru
        if ($Process.ExitCode -ne 0 -or -not (Test-Path -LiteralPath (Join-Path $Runtime 'RustDedicated.exe') -PathType Leaf)) {
            throw "L'installation du runtime isole a echoue (code $($Process.ExitCode)). Consulte $Log"
        }
    }
    if ($IncludeCarbon) { $null = Copy-RustCarbonToIsolatedRuntime -ServerRoot $ServerRoot -RuntimeRoot $Runtime }
    $TargetCfg = Join-Path $Runtime ('server\' + [string]$Instance.identity + '\cfg')
    [IO.Directory]::CreateDirectory($TargetCfg) | Out-Null
    $SharedCfg = Join-Path $ServerRoot ('server\server\' + [string]$Instance.identity + '\cfg')
    foreach ($Name in @('server.cfg','users.cfg')) {
        $Source = Join-Path $SharedCfg $Name
        if (-not (Test-Path -LiteralPath $Source)) { $Source = Join-Path $ServerRoot ('config\' + $Name) }
        if (Test-Path -LiteralPath $Source) { Copy-Item -LiteralPath $Source -Destination (Join-Path $TargetCfg $Name) -Force }
    }
    return Get-RustInstanceIsolationStatus -ServerRoot $ServerRoot -Instance $Instance
}

# ----- Supervision ---------------------------------------------------------

function ConvertTo-RustUtcDate {
    param($Value)
    if($Value-is[datetime]){return ([datetime]$Value).ToUniversalTime()}
    $Parsed=[datetime]::MinValue
    if([datetime]::TryParse([string]$Value,[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::RoundtripKind,[ref]$Parsed)){return $Parsed.ToUniversalTime()}
    if([datetime]::TryParse([string]$Value,[ref]$Parsed)){return $Parsed.ToUniversalTime()}
    return [datetime]::MinValue
}

function Get-RustDesiredStatePath { param([string]$ServerRoot) return Join-Path $ServerRoot 'data\desired-state.json' }

function Get-RustDesiredStateStore {
    param([Parameter(Mandatory = $true)][string]$ServerRoot)
    $Path = Get-RustDesiredStatePath -ServerRoot $ServerRoot
    if (Test-Path -LiteralPath $Path) {
        try { $Store = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json } catch { $Store = $null }
    }
    if (-not $Store) { $Store = [pscustomobject][ordered]@{schemaVersion=1;updatedUtc='';instances=@()} }
    if (-not ($Store.PSObject.Properties.Name -contains 'instances')) { $Store | Add-Member instances @() }
    return $Store
}

function Set-RustDesiredState {
    param([Parameter(Mandatory = $true)][string]$ServerRoot,[Parameter(Mandatory = $true)][string]$InstanceId,[ValidateSet('Running','Stopped')][string]$State,[string]$Reason='user')
    $Store = Get-RustDesiredStateStore -ServerRoot $ServerRoot
    $Entry = @($Store.instances | Where-Object id -eq $InstanceId) | Select-Object -First 1
    $Now = [datetime]::UtcNow.ToString('o')
    if (-not $Entry) {
        $Entry = [pscustomobject][ordered]@{id=$InstanceId;state=$State;reason=$Reason;changedUtc=$Now;lastStartAttemptUtc='';restartHistory=@()}
        $Store.instances = @($Store.instances) + @($Entry)
    }
    else { $Entry.state=$State; $Entry.reason=$Reason; $Entry.changedUtc=$Now }
    if ($State -eq 'Running') { $Entry.lastStartAttemptUtc=$Now }
    $Store.updatedUtc=$Now
    $null = Save-RustJsonAtomic -Path (Get-RustDesiredStatePath -ServerRoot $ServerRoot) -Value $Store
    return $Entry
}

function Get-RustInstanceMonitorSettings {
    param([Parameter(Mandatory = $true)]$Instance)
    return [pscustomobject]@{
        Enabled         = if ($Instance.PSObject.Properties.Name -contains 'monitoringEnabled') { [bool]$Instance.monitoringEnabled } else { $true }
        AutoRestart     = if ($Instance.PSObject.Properties.Name -contains 'autoRestart') { [bool]$Instance.autoRestart } else { $false }
        MaxRestartsHour = if ($Instance.PSObject.Properties.Name -contains 'autoRestartMaxPerHour') { [int]$Instance.autoRestartMaxPerHour } else { 3 }
        CooldownSeconds = if ($Instance.PSObject.Properties.Name -contains 'autoRestartCooldownSeconds') { [int]$Instance.autoRestartCooldownSeconds } else { 90 }
    }
}

function Set-RustInstanceMonitorSettings {
    param([Parameter(Mandatory = $true)][string]$ServerRoot,[Parameter(Mandatory = $true)][string]$InstanceId,[bool]$Enabled,[bool]$AutoRestart,[ValidateRange(1,10)][int]$MaxRestartsHour=3,[ValidateRange(30,1800)][int]$CooldownSeconds=90)
    $Catalog = Get-RustInstanceCatalog -ServerRoot $ServerRoot
    $Instance = @($Catalog.instances | Where-Object id -eq $InstanceId) | Select-Object -First 1
    if (-not $Instance) { throw "Instance '$InstanceId' introuvable." }
    foreach ($Pair in @(
        @('monitoringEnabled',$Enabled),@('autoRestart',$AutoRestart),@('autoRestartMaxPerHour',$MaxRestartsHour),@('autoRestartCooldownSeconds',$CooldownSeconds)
    )) {
        if ($Instance.PSObject.Properties.Name -contains $Pair[0]) { $Instance.($Pair[0])=$Pair[1] }
        else { $Instance | Add-Member -NotePropertyName $Pair[0] -NotePropertyValue $Pair[1] }
    }
    $null = Save-RustInstanceCatalog -ServerRoot $ServerRoot -Catalog $Catalog
    return Get-RustInstanceMonitorSettings -Instance $Instance
}

function Get-RustCrashEventPath { param([string]$ServerRoot) return Join-Path $ServerRoot 'data\crash-events.json' }

function Add-RustCrashEvent {
    param([Parameter(Mandatory = $true)][string]$ServerRoot,[string]$InstanceId,[ValidateSet('Crash','Restart','RestartBlocked','StartFailure','Info')][string]$Type,[string]$Detail)
    $Path = Get-RustCrashEventPath -ServerRoot $ServerRoot
    $Store = $null
    if (Test-Path -LiteralPath $Path) { try { $Store = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json } catch {} }
    if (-not $Store) { $Store = [pscustomobject][ordered]@{schemaVersion=1;events=@()} }
    $Event = [pscustomobject][ordered]@{id=[guid]::NewGuid().ToString('N');instanceId=$InstanceId;type=$Type;utc=[datetime]::UtcNow.ToString('o');detail=$Detail}
    $Store.events = @($Event) + @($Store.events | Select-Object -First 499)
    $null = Save-RustJsonAtomic -Path $Path -Value $Store
    return $Event
}

function Get-RustCrashEvents {
    param([Parameter(Mandatory = $true)][string]$ServerRoot,[string]$InstanceId='')
    $Path = Get-RustCrashEventPath -ServerRoot $ServerRoot
    if (-not (Test-Path -LiteralPath $Path)) { return @() }
    try { $Events = @((Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json).events) } catch { return @() }
    if ($InstanceId) { return @($Events | Where-Object instanceId -eq $InstanceId) }
    return $Events
}

function Get-RustLastFailureDetail {
    param([string]$ServerRoot,[string]$InstanceId)
    $Patterns = @('launcher-' + $InstanceId + '-error.log','rust-' + $InstanceId + '-*.log')
    foreach ($Pattern in $Patterns) {
        $File = Get-ChildItem -LiteralPath (Join-Path $ServerRoot 'logs') -Filter $Pattern -File -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1
        if (-not $File) { continue }
        $Lines = @(Get-Content -LiteralPath $File.FullName -Tail 80 -ErrorAction SilentlyContinue | Where-Object { $_ -match '(?i)error|exception|failed|fatal|port|memory|crash' })
        if ($Lines.Count) { return [string]$Lines[-1] }
    }
    return 'Aucune erreur recente detectee dans les journaux.'
}

function Get-RustInstanceTelemetry {
    param([Parameter(Mandatory = $true)][string]$ServerRoot,[Parameter(Mandatory = $true)]$Instance,[switch]$IncludeRcon)
    $ProcessRow = @(Get-RustRpgServerProcesses -ServerRoot $ServerRoot | Where-Object Identity -eq ([string]$Instance.identity)) | Select-Object -First 1
    $CpuSeconds = 0; $MemoryMb = 0; $PrivateMb = 0; $UptimeSeconds = 0; $Players = 0; $Fps = 0; $RconMs = -1; $Rcon = 'ARRETE'
    if ($ProcessRow) {
        $Process = Get-Process -Id ([int]$ProcessRow.ProcessId) -ErrorAction SilentlyContinue
        if ($Process) {
            $CpuSeconds=[math]::Round([double]$Process.TotalProcessorTime.TotalSeconds,2)
            $MemoryMb=[math]::Round([double]$Process.WorkingSet64/1MB)
            $PrivateMb=[math]::Round([double]$Process.PrivateMemorySize64/1MB)
            try { $UptimeSeconds=[int]((Get-Date)-$Process.StartTime).TotalSeconds } catch {}
        }
        $Rcon='NON TESTE'
        if ($IncludeRcon) {
            $Watch=[Diagnostics.Stopwatch]::StartNew()
            try {
                $Info=Get-RustRpgServerInfo -ServerRoot $ServerRoot -RconPort ([int]$Instance.rconPort)
                $Watch.Stop(); $RconMs=[int]$Watch.ElapsedMilliseconds; $Rcon='OK'
                if ($Info) {
                    foreach ($Name in @('Players','players')) { if ($Info.PSObject.Properties.Name -contains $Name) { $Players=[int]$Info.$Name; break } }
                    foreach ($Name in @('Framerate','FPS','fps')) { if ($Info.PSObject.Properties.Name -contains $Name) { $Fps=[math]::Round([double]$Info.$Name,1); break } }
                }
            }
            catch { $Watch.Stop(); $Rcon='ERREUR'; $RconMs=[int]$Watch.ElapsedMilliseconds }
        }
    }
    $Isolation=Get-RustInstanceIsolationStatus -ServerRoot $ServerRoot -Instance $Instance
    return [pscustomobject][ordered]@{
        InstanceId=[string]$Instance.id;DisplayName=[string]$Instance.displayName;Identity=[string]$Instance.identity;Running=[bool]($null-ne $ProcessRow);ProcessId=if($ProcessRow){[int]$ProcessRow.ProcessId}else{0};
        CpuSeconds=$CpuSeconds;MemoryMb=$MemoryMb;PrivateMb=$PrivateMb;UptimeSeconds=$UptimeSeconds;Players=$Players;Fps=$Fps;Rcon=$Rcon;RconMs=$RconMs;Isolation=$Isolation.Label;RuntimeReady=$Isolation.Ready;LastFailure=Get-RustLastFailureDetail -ServerRoot $ServerRoot -InstanceId ([string]$Instance.id)
    }
}

function Save-RustTelemetrySnapshot {
    param([Parameter(Mandatory = $true)][string]$ServerRoot,[Parameter(Mandatory = $true)][object[]]$Samples)
    $Path=Join-Path $ServerRoot 'data\telemetry-history.json'; $Store=$null
    if(Test-Path -LiteralPath $Path){try{$Store=Get-Content -LiteralPath $Path -Raw -Encoding UTF8|ConvertFrom-Json}catch{}}
    if(-not $Store){$Store=[pscustomobject][ordered]@{schemaVersion=1;samples=@()}}
    $Now=[datetime]::UtcNow.ToString('o')
    $Rows=@($Samples|ForEach-Object{[pscustomobject]@{utc=$Now;instanceId=$_.InstanceId;running=$_.Running;cpuPercent=if($_.PSObject.Properties.Name -contains 'CpuPercent'){$_.CpuPercent}else{0};memoryMb=$_.MemoryMb;players=$_.Players;fps=$_.Fps;rconMs=$_.RconMs}})
    $Store.samples=@($Rows)+@($Store.samples|Select-Object -First 1439)
    $null=Save-RustJsonAtomic -Path $Path -Value $Store
}

function Get-RustStartReadinessDiagnostics {
    param([Parameter(Mandatory = $true)][string]$ServerRoot,[Parameter(Mandatory = $true)][string]$InstanceId)
    $Instance=Get-RustServerInstance -ServerRoot $ServerRoot -Id $InstanceId
    if(-not $Instance){throw "Instance '$InstanceId' introuvable."}
    $Rows=New-Object Collections.Generic.List[object]
    $Isolation=Get-RustInstanceIsolationStatus -ServerRoot $ServerRoot -Instance $Instance
    $Exe=Join-Path $Isolation.RuntimeRoot 'RustDedicated.exe'
    $Rows.Add([pscustomobject]@{Status=if(Test-Path -LiteralPath $Exe){'OK'}else{'ERROR'};Check='Rust Dedicated';Detail=if(Test-Path -LiteralPath $Exe){$Exe}else{'Executable absent du runtime.'};Action=if($Isolation.Mode-eq'full'){'Installer le runtime isole.'}else{'Mettre a jour le serveur.'}})
    $Processes=@(Get-RustRpgServerProcesses -ServerRoot $ServerRoot)
    $Duplicate=@($Processes|Where-Object Identity -eq ([string]$Instance.identity))
    $Rows.Add([pscustomobject]@{Status=if($Duplicate.Count){'WARNING'}else{'OK'};Check='Processus';Detail=if($Duplicate.Count){"Instance deja active (PID $($Duplicate[0].ProcessId))."}else{'Aucun doublon.'};Action='Arreter le doublon avant de relancer.'})
    $InstanceRunning=$Duplicate.Count-gt0
    foreach($Pair in @(@('Jeu UDP',[int]$Instance.serverPort,'UDP'),@('RCON TCP',[int]$Instance.rconPort,'TCP'),@('Query UDP',[int]$Instance.queryPort,'UDP'),@('Rust+ TCP',[int]$Instance.appPort,'TCP'))){
        $Used=if($Pair[2]-eq'TCP'){Get-NetTCPConnection -LocalPort $Pair[1] -State Listen -ErrorAction SilentlyContinue|Select-Object -First 1}else{Get-NetUDPEndpoint -LocalPort $Pair[1] -ErrorAction SilentlyContinue|Select-Object -First 1}
        $Rows.Add([pscustomobject]@{Status=if($Used-and-not$InstanceRunning){'ERROR'}else{'OK'};Check=$Pair[0];Detail=if($Used-and$InstanceRunning){"Port $($Pair[1]) utilise par cette instance active."}elseif($Used){"Port $($Pair[1]) deja utilise."}else{"Port $($Pair[1]) libre."};Action='Choisir un autre port ou arreter le processus concurrent.'})
    }
    $Os=Get-CimInstance Win32_OperatingSystem -ErrorAction SilentlyContinue
    $FreeRam=if($Os){[math]::Round([double]$Os.FreePhysicalMemory/1MB,1)}else{0}
    $Need=[double]$Instance.memoryEstimateGb+2
    $Rows.Add([pscustomobject]@{Status=if($FreeRam-ge$Need){'OK'}elseif($FreeRam-ge[double]$Instance.memoryEstimateGb){'WARNING'}else{'ERROR'};Check='Memoire';Detail="$FreeRam Go libres, $Need Go recommandes avec marge.";Action='Fermer des applications ou demarrer moins d instances.'})
    $Secret=Join-Path $ServerRoot '.rcon-password.txt'
    $Rows.Add([pscustomobject]@{Status=if(Test-Path -LiteralPath $Secret){'OK'}else{'WARNING'};Check='Secret RCON';Detail=if(Test-Path -LiteralPath $Secret){'Present.'}else{'Il sera genere au premier lancement.'};Action='Ne jamais publier ce fichier.'})
    $Rows.Add([pscustomobject]@{Status=if($Isolation.Mode-eq'full' -and -not $Isolation.Ready){'ERROR'}else{'OK'};Check='Isolation';Detail="$($Isolation.Label) - $($Isolation.RuntimeRoot)";Action='Utiliser un runtime complet pour plusieurs serveurs Carbon.'})
    return [object[]]$Rows.ToArray()
}

function Get-RustMultiInstanceReadiness {
    param([Parameter(Mandatory = $true)][string]$ServerRoot,[string[]]$InstanceIds)
    $Rows = New-Object Collections.Generic.List[object]
    $Catalog = Get-RustInstanceCatalog -ServerRoot $ServerRoot
    try {
        Assert-RustInstanceCatalog $Catalog
        $Rows.Add([pscustomobject]@{ Status='OK'; Check='Catalogue'; Detail='Ports, identités et identifiants uniques.'; Action='' })
    }
    catch {
        $Rows.Add([pscustomobject]@{ Status='ERROR'; Check='Catalogue'; Detail=$_.Exception.Message; Action='Corriger les profils avant de continuer.' })
    }
    $Targets = if($InstanceIds.Count){@($Catalog.instances|Where-Object{[string]$_.id-in$InstanceIds})}else{@($Catalog.instances|Where-Object enabled)}
    if($Targets.Count-lt2){$Rows.Add([pscustomobject]@{Status='INFO';Check='Instances ciblées';Detail="$($Targets.Count) instance ciblée.";Action='Deux instances sont nécessaires pour un test multi-instance.'})}
    elseif(-not[bool]$Catalog.allowMultiInstance){$Rows.Add([pscustomobject]@{Status='ERROR';Check='Autorisation';Detail="Le mode multi-instance n'est pas accepté.";Action='Active explicitement le mode expérimental dans Mes serveurs.'})}
    else{$Rows.Add([pscustomobject]@{Status='OK';Check='Autorisation';Detail="$($Targets.Count) instances ciblées et mode expérimental accepté.";Action=''})}

    $SharedCarbon = New-Object Collections.Generic.List[string]
    $EstimatedRam = 0.0
    foreach($Instance in $Targets){
        $Isolation=Get-RustInstanceIsolationStatus -ServerRoot $ServerRoot -Instance $Instance
        $Estimate=if($Instance.PSObject.Properties.Name -contains 'memoryEstimateGb') {[double]$Instance.memoryEstimateGb}else{6}
        $EstimatedRam += $Estimate
        if($Isolation.Mode-eq'full' -and-not$Isolation.Ready){$Rows.Add([pscustomobject]@{Status='ERROR';Check=[string]$Instance.displayName;Detail='Runtime isolé incomplet.';Action='Installer le runtime isolé avant le lancement groupé.'})}
        else{$Rows.Add([pscustomobject]@{Status='OK';Check=[string]$Instance.displayName;Detail=("{0} · {1} Go estimés." -f $Isolation.Label,$Estimate);Action=''})}
        if($Isolation.Mode-ne'full' -and (Test-Path -LiteralPath (Join-Path $Isolation.RuntimeRoot 'carbon') -PathType Container)){$SharedCarbon.Add([string]$Instance.displayName)}
    }
    if($Targets.Count-gt1-and$SharedCarbon.Count){$Rows.Add([pscustomobject]@{Status='ERROR';Check='Carbon partagé';Detail=(($SharedCarbon.ToArray())-join', ');Action='Chaque serveur Carbon simultané doit utiliser un runtime complet isolé.'})}
    else{$Rows.Add([pscustomobject]@{Status='OK';Check='Isolation Carbon';Detail='Aucun runtime Carbon partagé dans ce lancement groupé.';Action=''})}

    $Health=Get-RustHostHealthSnapshot -ServerRoot $ServerRoot
    $FreeRamGb=[math]::Round([double]$Health.FreeMemoryBytes/1GB,1)
    $Rows.Add([pscustomobject]@{Status=$(if($FreeRamGb-ge($EstimatedRam+2)){'OK'}elseif($FreeRamGb-ge$EstimatedRam){'WARNING'}else{'ERROR'});Check='Mémoire globale';Detail=("{0} Go libres · {1} Go estimés + 2 Go de marge." -f $FreeRamGb,[math]::Round($EstimatedRam,1));Action="Réduire le nombre d'instances ou leur taille de carte si nécessaire."})
    $Blocking=@($Rows|Where-Object Status -eq 'ERROR')
    return [pscustomobject]@{Ready=($Blocking.Count-eq0);TargetCount=$Targets.Count;EstimatedRamGb=[math]::Round($EstimatedRam,1);Rows=[object[]]$Rows.ToArray();Blocking=[object[]]$Blocking}
}

function Invoke-RustWatchdogPass {
    param([Parameter(Mandatory = $true)][string]$ServerRoot,[switch]$NoRestart)
    $Catalog=Get-RustInstanceCatalog -ServerRoot $ServerRoot; $Desired=Get-RustDesiredStateStore -ServerRoot $ServerRoot; $Processes=@(Get-RustRpgServerProcesses -ServerRoot $ServerRoot); $Results=New-Object Collections.Generic.List[object]
    foreach($Instance in @($Catalog.instances)){
        $Settings=Get-RustInstanceMonitorSettings -Instance $Instance
        if(-not $Settings.Enabled){continue}
        $Want=@($Desired.instances|Where-Object id -eq ([string]$Instance.id)|Select-Object -First 1)
        $Running=@($Processes|Where-Object Identity -eq ([string]$Instance.identity)).Count-gt 0
        if($Running -or -not $Want -or [string]$Want.state-ne'Running'){continue}
        $Changed=ConvertTo-RustUtcDate $Want.changedUtc;if($Changed-eq[datetime]::MinValue){$Changed=[datetime]::UtcNow}
        if(([datetime]::UtcNow-$Changed).TotalSeconds-lt $Settings.CooldownSeconds){continue}
        $Recent=@(Get-RustCrashEvents -ServerRoot $ServerRoot -InstanceId ([string]$Instance.id)|Where-Object{[string]$_.type-eq'Restart' -and ([datetime]::UtcNow-(ConvertTo-RustUtcDate $_.utc)).TotalHours-lt 1})
        if(-not $Settings.AutoRestart){$Results.Add((Add-RustCrashEvent -ServerRoot $ServerRoot -InstanceId ([string]$Instance.id) -Type Crash -Detail (Get-RustLastFailureDetail -ServerRoot $ServerRoot -InstanceId ([string]$Instance.id))));continue}
        if($Recent.Count-ge $Settings.MaxRestartsHour){$Results.Add((Add-RustCrashEvent -ServerRoot $ServerRoot -InstanceId ([string]$Instance.id) -Type RestartBlocked -Detail "Limite de $($Settings.MaxRestartsHour) redemarrages par heure atteinte."));continue}
        if($NoRestart){$Results.Add([pscustomobject]@{instanceId=[string]$Instance.id;type='RestartPlanned';detail='Test sans lancement.'});continue}
        $Launcher=Join-Path $ServerRoot 'Start-Instance.ps1'; $PsExe=Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'; $ErrorLog=Join-Path $ServerRoot ('logs\watchdog-'+[string]$Instance.id+'.err.log')
        $P=Start-Process -FilePath $PsExe -ArgumentList @('-NoLogo','-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-WindowStyle','Hidden','-File',('"'+$Launcher+'"'),'-InstanceId',([string]$Instance.id),'-WatchdogRestart') -WorkingDirectory $ServerRoot -WindowStyle Hidden -RedirectStandardError $ErrorLog -PassThru
        $Results.Add((Add-RustCrashEvent -ServerRoot $ServerRoot -InstanceId ([string]$Instance.id) -Type Restart -Detail "Relance automatique demandee, PID lanceur $($P.Id)."))
        $null=Set-RustDesiredState -ServerRoot $ServerRoot -InstanceId ([string]$Instance.id) -State Running -Reason watchdog
    }
    return [object[]]$Results.ToArray()
}

function Get-RustWatchdogTaskName { return 'Rust Server Control Center - Watchdog' }
function Get-RustWatchdogTaskStatus {
    param([string]$ServerRoot)
    try{$Task=Get-ScheduledTask -TaskName (Get-RustWatchdogTaskName) -ErrorAction Stop;return [pscustomobject]@{Installed=$true;State=[string]$Task.State}}catch{return [pscustomobject]@{Installed=$false;State='NotInstalled'}}
}
function Register-RustWatchdogTask {
    param([Parameter(Mandatory = $true)][string]$ServerRoot)
    $Worker=Join-Path $ServerRoot 'tool\RustRPG-Watchdog.ps1';if(-not(Test-Path -LiteralPath $Worker)){throw 'Moteur de supervision introuvable.'}
    $PsExe=Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe';$Args='-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File "'+$Worker+'" -ServerRoot "'+$ServerRoot+'"'
    $Action=New-ScheduledTaskAction -Execute $PsExe -Argument $Args -WorkingDirectory $ServerRoot;$Trigger=New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(1) -RepetitionInterval ([TimeSpan]::FromMinutes(1)) -RepetitionDuration ([TimeSpan]::FromDays(3650));$User=[Security.Principal.WindowsIdentity]::GetCurrent().Name;$Principal=New-ScheduledTaskPrincipal -UserId $User -LogonType Interactive -RunLevel Limited;$Settings=New-ScheduledTaskSettingsSet -MultipleInstances IgnoreNew -StartWhenAvailable -ExecutionTimeLimit ([TimeSpan]::FromMinutes(5))
    Register-ScheduledTask -TaskName (Get-RustWatchdogTaskName) -Action $Action -Trigger $Trigger -Principal $Principal -Settings $Settings -Description 'Surveille les instances Rust et applique la politique de relance controlee.' -Force|Out-Null
    return Get-RustWatchdogTaskStatus -ServerRoot $ServerRoot
}
function Unregister-RustWatchdogTask { param([string]$ServerRoot) if((Get-RustWatchdogTaskStatus -ServerRoot $ServerRoot).Installed){Unregister-ScheduledTask -TaskName (Get-RustWatchdogTaskName) -Confirm:$false};return Get-RustWatchdogTaskStatus -ServerRoot $ServerRoot }

# ----- Catalogue de plugins ------------------------------------------------

function Get-RustPluginCatalogSourcesPath { param([string]$ServerRoot) return Join-Path $ServerRoot 'data\plugin-catalog-sources.json' }
function Get-RustPluginCatalogCacheRoot { param([string]$ServerRoot) return Join-Path $ServerRoot 'data\plugin-catalog-cache' }

function Get-RustPluginCatalogSources {
    param([Parameter(Mandatory = $true)][string]$ServerRoot)
    $Path=Get-RustPluginCatalogSourcesPath -ServerRoot $ServerRoot
    if(Test-Path -LiteralPath $Path){try{$Store=Get-Content -LiteralPath $Path -Raw -Encoding UTF8|ConvertFrom-Json}catch{$Store=$null}}
    if(-not $Store){$Store=[pscustomobject][ordered]@{schemaVersion=1;sources=@([pscustomobject]@{id='bundled';name='Catalogue verifie du Control Center';url='';enabled=$true;builtIn=$true;lastSyncUtc='';lastError=''})}}
    return $Store
}

function Save-RustPluginCatalogSources { param([string]$ServerRoot,$Store) return Save-RustJsonAtomic -Path (Get-RustPluginCatalogSourcesPath -ServerRoot $ServerRoot) -Value $Store }

function Add-RustPluginCatalogSource {
    param([string]$ServerRoot,[string]$Name,[string]$Url)
    $Parsed=$null;if(-not[Uri]::TryCreate($Url,[UriKind]::Absolute,[ref]$Parsed)-or$Parsed.Scheme-ne'https'){throw 'Le catalogue doit utiliser une URL HTTPS.'}
    $Store=Get-RustPluginCatalogSources -ServerRoot $ServerRoot;if(@($Store.sources|Where-Object url -eq $Url).Count){throw 'Cette source existe deja.'}
    $Source=[pscustomobject][ordered]@{id=[guid]::NewGuid().ToString('N');name=$Name.Trim();url=$Url;enabled=$true;builtIn=$false;lastSyncUtc='';lastError=''};$Store.sources=@($Store.sources)+@($Source);$null=Save-RustPluginCatalogSources -ServerRoot $ServerRoot -Store $Store;return $Source
}

function Test-RustPluginCatalogDocument {
    param([Parameter(Mandatory = $true)]$Document)
    if(-not($Document.PSObject.Properties.Name -contains 'plugins')){throw 'Le document ne contient pas de tableau plugins.'}
    $Ids=@{};foreach($Plugin in @($Document.plugins)){
        if([string]$Plugin.id-notmatch'^[a-z0-9][a-z0-9_.-]{0,63}$'){throw "Identifiant de plugin invalide : $($Plugin.id)"}
        if($Ids.ContainsKey([string]$Plugin.id)){throw "Plugin duplique : $($Plugin.id)"};$Ids[[string]$Plugin.id]=$true
        if([string]$Plugin.fileName-notmatch'^[A-Za-z0-9_.-]+\.cs$'){throw "Nom de fichier refuse pour $($Plugin.id)."}
        if([string]$Plugin.downloadUrl -and [string]$Plugin.downloadUrl-notmatch'^https://'){throw "URL non HTTPS pour $($Plugin.id)."}
        if([string]$Plugin.manifestUrl -and [string]$Plugin.manifestUrl-notmatch'^https://'){throw "URL de manifeste non HTTPS pour $($Plugin.id)."}
        if([string]$Plugin.manifestSha256 -and [string]$Plugin.manifestSha256-notmatch'^[A-Fa-f0-9]{64}$'){throw "Empreinte du manifeste invalide pour $($Plugin.id)."}
        if([string]$Plugin.bundledManifestPath -and [string]$Plugin.bundledManifestPath-notmatch'^[A-Za-z0-9_./\\-]+\.json$'){throw "Chemin de manifeste embarqué refusé pour $($Plugin.id)."}
    };return $true
}

function Sync-RustPluginCatalogSources {
    param([Parameter(Mandatory = $true)][string]$ServerRoot)
    $Store=Get-RustPluginCatalogSources -ServerRoot $ServerRoot;$CacheRoot=Get-RustPluginCatalogCacheRoot -ServerRoot $ServerRoot;[IO.Directory]::CreateDirectory($CacheRoot)|Out-Null
    foreach($Source in @($Store.sources|Where-Object enabled)){
        if([bool]$Source.builtIn){$Source.lastSyncUtc=[datetime]::UtcNow.ToString('o');$Source.lastError='';continue}
        try{
            $Client=New-Object Net.Http.HttpClient;$Client.Timeout=[TimeSpan]::FromSeconds(20)
            try{$Json=$Client.GetStringAsync([string]$Source.url).GetAwaiter().GetResult()}finally{$Client.Dispose()}
            if($Json.Length-gt 2MB){throw 'Catalogue trop volumineux.'};$Doc=$Json|ConvertFrom-Json;$null=Test-RustPluginCatalogDocument -Document $Doc
            $Cache=Join-Path $CacheRoot ([string]$Source.id+'.json');[IO.File]::WriteAllText($Cache,$Json,[Text.UTF8Encoding]::new($true));$Source.lastSyncUtc=[datetime]::UtcNow.ToString('o');$Source.lastError=''
        }catch{$Source.lastError=$_.Exception.Message}
    };$null=Save-RustPluginCatalogSources -ServerRoot $ServerRoot -Store $Store;return $Store
}

function Get-RustAvailablePluginCatalog {
    param([Parameter(Mandatory = $true)][string]$ServerRoot)
    $Documents=New-Object Collections.Generic.List[object];$Bundled=Join-Path $PSScriptRoot 'catalog\plugins.json'
    if(Test-Path -LiteralPath $Bundled){try{$Doc=Get-Content -LiteralPath $Bundled -Raw -Encoding UTF8|ConvertFrom-Json;$null=Test-RustPluginCatalogDocument $Doc;$Documents.Add([pscustomobject]@{sourceId='bundled';sourceName='Control Center';document=$Doc})}catch{}}
    $Sources=Get-RustPluginCatalogSources -ServerRoot $ServerRoot;$CacheRoot=Get-RustPluginCatalogCacheRoot -ServerRoot $ServerRoot
    foreach($Source in @($Sources.sources|Where-Object{-not[bool]$_.builtIn-and[bool]$_.enabled})){$Path=Join-Path $CacheRoot ([string]$Source.id+'.json');if(Test-Path -LiteralPath $Path){try{$Doc=Get-Content -LiteralPath $Path -Raw -Encoding UTF8|ConvertFrom-Json;$null=Test-RustPluginCatalogDocument $Doc;$Documents.Add([pscustomobject]@{sourceId=[string]$Source.id;sourceName=[string]$Source.name;document=$Doc})}catch{}}}
    $Items=foreach($Entry in $Documents){foreach($P in @($Entry.document.plugins)){[pscustomobject][ordered]@{Id=[string]$P.id;Name=[string]$P.name;Description=[string]$P.description;Version=[string]$P.version;Author=[string]$P.author;Category=[string]$P.category;Framework=if($P.framework){[string]$P.framework}else{'Carbon'};FileName=[string]$P.fileName;DownloadUrl=[string]$P.downloadUrl;Sha256=[string]$P.sha256;Dependencies=@($P.dependencies);Homepage=[string]$P.homepage;SourceId=$Entry.sourceId;SourceName=$Entry.sourceName;BundledPath=if($P.bundledPath){[string]$P.bundledPath}else{''};ManifestUrl=if($P.manifestUrl){[string]$P.manifestUrl}else{''};ManifestSha256=if($P.manifestSha256){[string]$P.manifestSha256}else{''};BundledManifestPath=if($P.bundledManifestPath){[string]$P.bundledManifestPath}else{''}}}}
    $Seen=@{};return @($Items|Where-Object{if($Seen.ContainsKey($_.Id)){$false}else{$Seen[$_.Id]=$true;$true}}|Sort-Object Category,Name)
}

function Get-RustInstalledPluginRegistryPath { param([string]$ServerRoot) return Join-Path $ServerRoot 'data\installed-plugins.json' }
function Get-RustInstalledPluginRegistry {
    param([string]$ServerRoot);$Path=Get-RustInstalledPluginRegistryPath $ServerRoot
    if(Test-Path -LiteralPath $Path){try{return Get-Content -LiteralPath $Path -Raw -Encoding UTF8|ConvertFrom-Json}catch{}}
    return [pscustomobject][ordered]@{schemaVersion=1;plugins=@()}
}

function Test-RustCatalogPluginCompatibility {
    param([string]$ServerRoot,[string]$InstanceId,$Plugin)
    $Instance=Get-RustServerInstance -ServerRoot $ServerRoot -Id $InstanceId;if(-not$Instance){throw 'Instance introuvable.'};$Runtime=Get-RustInstanceRuntimeRoot -ServerRoot $ServerRoot -Instance $Instance;$Mod=Get-RustRuntimeModContext -RuntimeRoot $Runtime
    $Missing=New-Object Collections.Generic.List[string];$Installed=Get-RustInstalledPluginRegistry -ServerRoot $ServerRoot
    foreach($Dependency in @($Plugin.Dependencies)){if(-not@($Installed.plugins|Where-Object{[string]$_.instanceId-eq$InstanceId-and[string]$_.pluginId-eq[string]$Dependency}).Count){$Missing.Add([string]$Dependency)}}
    $Compatible=($Plugin.Framework-eq'Any' -or $Mod.Installed) -and $Missing.Count-eq 0
    return [pscustomobject]@{Compatible=$Compatible;Carbon=[bool]$Mod.Installed;Framework=$Mod.Framework;MissingDependencies=@($Missing);Detail=if(-not$Mod.Installed-and$Plugin.Framework-ne'Any'){'Aucun framework Carbon/Oxide sur le runtime cible.'}elseif($Missing.Count){'Dependances manquantes : '+($Missing-join', ')}else{"Compatible avec $($Mod.Framework)."}}
}

function Resolve-RustCatalogPluginDependencies {
    param([string]$ServerRoot,[string]$PluginId)
    $Catalog=@(Get-RustAvailablePluginCatalog -ServerRoot $ServerRoot);$Order=New-Object Collections.Generic.List[object];$Visiting=@{};$Done=@{}
    function Visit([string]$Id){if($Done.ContainsKey($Id)){return};if($Visiting.ContainsKey($Id)){throw "Cycle de dependances detecte autour de '$Id'."};$Item=@($Catalog|Where-Object Id -eq $Id)|Select-Object -First 1;if(-not$Item){throw "Dependance '$Id' absente du catalogue."};$Visiting[$Id]=$true;foreach($D in @($Item.Dependencies)){Visit ([string]$D)};$Visiting.Remove($Id);$Done[$Id]=$true;$Order.Add($Item)}
    Visit $PluginId;return [object[]]$Order.ToArray()
}

function Install-RustCatalogPlugin {
    param([Parameter(Mandatory = $true)][string]$ServerRoot,[Parameter(Mandatory = $true)][string]$InstanceId,[Parameter(Mandatory = $true)][string]$PluginId)
    $Instance=Get-RustServerInstance -ServerRoot $ServerRoot -Id $InstanceId;if(-not$Instance){throw 'Instance introuvable.'};$Runtime=Get-RustInstanceRuntimeRoot -ServerRoot $ServerRoot -Instance $Instance;$Mod=Get-RustRuntimeModContext -RuntimeRoot $Runtime
    if(-not$Mod.Installed){throw 'Installe Carbon ou Oxide dans le runtime cible avant un plugin.'}
    $Installed=New-Object Collections.Generic.List[object]
    foreach($Plugin in @(Resolve-RustCatalogPluginDependencies -ServerRoot $ServerRoot -PluginId $PluginId)){
        $Temp=Join-Path ([IO.Path]::GetTempPath()) ('rust-plugin-'+[guid]::NewGuid().ToString('N')+'.cs')
        $ManifestTemp=Join-Path ([IO.Path]::GetTempPath()) ('rust-plugin-manifest-'+[guid]::NewGuid().ToString('N')+'.json')
        try{
            if([string]$Plugin.BundledPath){$Source=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot ([string]$Plugin.BundledPath)));$Allowed=[IO.Path]::GetFullPath($PSScriptRoot).TrimEnd('\')+'\';if(-not$Source.StartsWith($Allowed,[StringComparison]::OrdinalIgnoreCase)){throw 'Source embarquee hors du dossier outil.'};Copy-Item -LiteralPath $Source -Destination $Temp -Force}
            else{$Uri=$null;if(-not[Uri]::TryCreate([string]$Plugin.DownloadUrl,[UriKind]::Absolute,[ref]$Uri)-or$Uri.Scheme-ne'https'){throw 'URL HTTPS requise.'};$Client=New-Object Net.Http.HttpClient;$Client.Timeout=[TimeSpan]::FromSeconds(30);try{$Bytes=$Client.GetByteArrayAsync($Uri).GetAwaiter().GetResult()}finally{$Client.Dispose()};if($Bytes.Length-gt 4MB){throw 'Plugin trop volumineux.'};[IO.File]::WriteAllBytes($Temp,$Bytes)}
            $Text=[IO.File]::ReadAllText($Temp);if($Text-notmatch'(?s)class\s+[A-Za-z0-9_]+\s*:\s*(?:RustPlugin|CarbonPlugin|CovalencePlugin)'){throw "Le fichier $($Plugin.FileName) ne ressemble pas a un plugin Carbon/Oxide."}
            $Hash=(Get-FileHash -LiteralPath $Temp -Algorithm SHA256).Hash.ToLowerInvariant();if([string]$Plugin.Sha256-and$Hash-ne([string]$Plugin.Sha256).ToLowerInvariant()){throw "Empreinte SHA256 invalide pour $($Plugin.Name)."}
            $Manifest=$null;$ManifestHash='';$ManifestTarget=''
            if([string]$Plugin.BundledManifestPath -or [string]$Plugin.ManifestUrl){
                if([string]$Plugin.BundledManifestPath){$ManifestSource=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot ([string]$Plugin.BundledManifestPath)));$Allowed=[IO.Path]::GetFullPath($PSScriptRoot).TrimEnd('\')+'\';if(-not$ManifestSource.StartsWith($Allowed,[StringComparison]::OrdinalIgnoreCase)){throw 'Manifeste embarqué hors du dossier outil.'};Copy-Item -LiteralPath $ManifestSource -Destination $ManifestTemp -Force}
                else{$ManifestUri=$null;if(-not[Uri]::TryCreate([string]$Plugin.ManifestUrl,[UriKind]::Absolute,[ref]$ManifestUri)-or$ManifestUri.Scheme-ne'https'){throw 'URL HTTPS requise pour le manifeste.'};$ManifestClient=New-Object Net.Http.HttpClient;$ManifestClient.Timeout=[TimeSpan]::FromSeconds(20);try{$ManifestBytes=$ManifestClient.GetByteArrayAsync($ManifestUri).GetAwaiter().GetResult()}finally{$ManifestClient.Dispose()};if($ManifestBytes.Length-gt 512KB){throw 'Manifeste trop volumineux.'};[IO.File]::WriteAllBytes($ManifestTemp,$ManifestBytes)}
                $ManifestHash=(Get-FileHash -LiteralPath $ManifestTemp -Algorithm SHA256).Hash.ToLowerInvariant();if([string]$Plugin.ManifestSha256-and$ManifestHash-ne([string]$Plugin.ManifestSha256).ToLowerInvariant()){throw "Empreinte du manifeste invalide pour $($Plugin.Name)."}
                $Manifest=Get-Content -LiteralPath $ManifestTemp -Raw -Encoding UTF8|ConvertFrom-Json;$null=Test-RustPluginSdkManifest -Manifest $Manifest
                $ExpectedFileBase=[IO.Path]::GetFileNameWithoutExtension([string]$Plugin.FileName);if([string]$Manifest.plugin.fileBase-ne$ExpectedFileBase){throw "Le manifeste SDK cible $($Manifest.plugin.fileBase) au lieu de $ExpectedFileBase."}
            }
            $TargetDir=Join-Path $Mod.PluginRoot 'plugins';[IO.Directory]::CreateDirectory($TargetDir)|Out-Null;$Target=Join-Path $TargetDir ([string]$Plugin.FileName)
            if(Test-Path -LiteralPath $Target){$Backup=Join-Path $ServerRoot ('backups\plugins\'+(Get-Date -Format 'yyyyMMdd-HHmmss')+'-'+$InstanceId);[IO.Directory]::CreateDirectory($Backup)|Out-Null;Copy-Item -LiteralPath $Target -Destination $Backup -Force}
            Copy-Item -LiteralPath $Temp -Destination $Target -Force
            if($Manifest){$ManifestDir=Join-Path $Mod.PluginRoot 'plugin-manifests';[IO.Directory]::CreateDirectory($ManifestDir)|Out-Null;$ManifestTarget=Join-Path $ManifestDir ([string]$Manifest.plugin.fileBase+'.json');Copy-Item -LiteralPath $ManifestTemp -Destination $ManifestTarget -Force}
            $Registry=Get-RustInstalledPluginRegistry -ServerRoot $ServerRoot;$Registry.plugins=@($Registry.plugins|Where-Object{-not([string]$_.instanceId-eq$InstanceId-and[string]$_.pluginId-eq[string]$Plugin.Id)})+@([pscustomobject]@{instanceId=$InstanceId;pluginId=[string]$Plugin.Id;version=[string]$Plugin.Version;fileName=[string]$Plugin.FileName;sha256=$Hash;manifestFileName=$(if($Manifest){[string]$Manifest.plugin.fileBase+'.json'}else{''});manifestSha256=$ManifestHash;sourceId=[string]$Plugin.SourceId;installedUtc=[datetime]::UtcNow.ToString('o')});$null=Save-RustJsonAtomic -Path (Get-RustInstalledPluginRegistryPath $ServerRoot) -Value $Registry
            $Installed.Add([pscustomobject]@{Plugin=$Plugin.Name;Version=$Plugin.Version;Path=$Target;Sha256=$Hash;ManifestPath=$ManifestTarget;ManifestSha256=$ManifestHash})
        }finally{if(Test-Path -LiteralPath $Temp){Remove-Item -LiteralPath $Temp -Force};if(Test-Path -LiteralPath $ManifestTemp){Remove-Item -LiteralPath $ManifestTemp -Force}}
    };return [object[]]$Installed.ToArray()
}

function Remove-RustCatalogPlugin {
    param([string]$ServerRoot,[string]$InstanceId,[string]$PluginId)
    $Registry=Get-RustInstalledPluginRegistry -ServerRoot $ServerRoot;$Entry=@($Registry.plugins|Where-Object{[string]$_.instanceId-eq$InstanceId-and[string]$_.pluginId-eq$PluginId})|Select-Object -First 1;if(-not$Entry){throw 'Plugin catalogue non installe sur cette instance.'};$Instance=Get-RustServerInstance -ServerRoot $ServerRoot -Id $InstanceId;$Runtime=Get-RustInstanceRuntimeRoot -ServerRoot $ServerRoot -Instance $Instance;$Mod=Get-RustRuntimeModContext -RuntimeRoot $Runtime;$Path=Join-Path $Mod.PluginRoot ('plugins\'+[string]$Entry.fileName)
    $Archive=Join-Path $ServerRoot ('backups\plugins\archive-'+(Get-Date -Format 'yyyyMMdd-HHmmss')+'-'+$InstanceId);$Archived=$false
    if(Test-Path -LiteralPath $Path){[IO.Directory]::CreateDirectory($Archive)|Out-Null;Move-Item -LiteralPath $Path -Destination $Archive -Force;$Archived=$true}
    $ManifestName=if($Entry.PSObject.Properties.Name-contains'manifestFileName' -and [string]$Entry.manifestFileName){[string]$Entry.manifestFileName}else{[IO.Path]::GetFileNameWithoutExtension([string]$Entry.fileName)+'.json'};$ManifestPath=Join-Path $Mod.PluginRoot ('plugin-manifests\'+$ManifestName)
    if(Test-Path -LiteralPath $ManifestPath){if(-not$Archived){[IO.Directory]::CreateDirectory($Archive)|Out-Null};Move-Item -LiteralPath $ManifestPath -Destination $Archive -Force}
    $Registry.plugins=@($Registry.plugins|Where-Object{-not([string]$_.instanceId-eq$InstanceId-and[string]$_.pluginId-eq$PluginId)});$null=Save-RustJsonAtomic -Path (Get-RustInstalledPluginRegistryPath $ServerRoot) -Value $Registry;return $true
}

# ----- Acces distant -------------------------------------------------------

function Get-RustRemoteConfigPath { param([string]$ServerRoot) return Join-Path $ServerRoot 'data\remote-access.json' }
function Get-RustRemoteTokenPath { param([string]$ServerRoot) return Join-Path $ServerRoot 'data\remote-token.bin' }

function Get-RustRemoteAccessConfig {
    param([Parameter(Mandatory = $true)][string]$ServerRoot);$Path=Get-RustRemoteConfigPath $ServerRoot
    if(Test-Path -LiteralPath $Path){try{$Config=Get-Content -LiteralPath $Path -Raw -Encoding UTF8|ConvertFrom-Json}catch{$Config=$null}}
    if(-not$Config){$Config=[pscustomobject][ordered]@{schemaVersion=1;enabled=$false;bindAddress='127.0.0.1';port=28480;sessionMinutes=60;allowRcon=$false;updatedUtc=''}}
    return $Config
}

function Set-RustRemoteAccessConfig {
    param([string]$ServerRoot,[bool]$Enabled,[ValidateSet('127.0.0.1','0.0.0.0')][string]$BindAddress='127.0.0.1',[ValidateRange(1025,65535)][int]$Port=28480,[bool]$AllowRcon=$false)
    $Catalog=Get-RustInstanceCatalog -ServerRoot $ServerRoot;foreach($I in @($Catalog.instances)){foreach($P in @('serverPort','rconPort','queryPort','appPort')){if([int]$I.$P-eq$Port){throw "Le port $Port est deja reserve par $($I.displayName)."}}}
    $Config=[pscustomobject][ordered]@{schemaVersion=1;enabled=$Enabled;bindAddress=$BindAddress;port=$Port;sessionMinutes=60;allowRcon=$AllowRcon;updatedUtc=[datetime]::UtcNow.ToString('o')};$null=Save-RustJsonAtomic -Path (Get-RustRemoteConfigPath $ServerRoot) -Value $Config;return $Config
}

function New-RustRemoteAccessToken {
    param([Parameter(Mandatory = $true)][string]$ServerRoot)
    Add-Type -AssemblyName System.Security
    $Bytes=New-Object byte[] 32;[Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($Bytes);$Token=[Convert]::ToBase64String($Bytes).TrimEnd('=').Replace('+','-').Replace('/','_');$Plain=[Text.Encoding]::UTF8.GetBytes($Token);$Protected=[Security.Cryptography.ProtectedData]::Protect($Plain,$null,[Security.Cryptography.DataProtectionScope]::CurrentUser);[IO.Directory]::CreateDirectory((Join-Path $ServerRoot 'data'))|Out-Null;[IO.File]::WriteAllBytes((Get-RustRemoteTokenPath $ServerRoot),$Protected);return $Token
}

function Get-RustRemoteAccessToken {
    param([Parameter(Mandatory = $true)][string]$ServerRoot)
    Add-Type -AssemblyName System.Security;$Path=Get-RustRemoteTokenPath $ServerRoot;if(-not(Test-Path -LiteralPath $Path)){return ''};try{$Plain=[Security.Cryptography.ProtectedData]::Unprotect([IO.File]::ReadAllBytes($Path),$null,[Security.Cryptography.DataProtectionScope]::CurrentUser);return [Text.Encoding]::UTF8.GetString($Plain)}catch{return ''}
}

function Get-RustRemoteTaskName { return 'Rust Server Control Center - Remote Dashboard' }
function Get-RustRemoteTaskStatus { param([string]$ServerRoot) try{$Task=Get-ScheduledTask -TaskName (Get-RustRemoteTaskName) -ErrorAction Stop;return [pscustomobject]@{Installed=$true;State=[string]$Task.State}}catch{return [pscustomobject]@{Installed=$false;State='NotInstalled'}} }
function Register-RustRemoteTask {
    param([Parameter(Mandatory = $true)][string]$ServerRoot)
    $Config=Get-RustRemoteAccessConfig -ServerRoot $ServerRoot;if(-not[bool]$Config.enabled){throw "Active d'abord l'acces distant."};if(-not(Get-RustRemoteAccessToken -ServerRoot $ServerRoot)){throw "Genere d'abord un jeton d'acces."};$Worker=Join-Path $ServerRoot 'tool\RustRPG-RemoteDashboard.ps1';if(-not(Test-Path -LiteralPath $Worker)){throw 'Serveur web local introuvable.'}
    $PsExe=Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe';$Args='-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File "'+$Worker+'" -ServerRoot "'+$ServerRoot+'"';$Action=New-ScheduledTaskAction -Execute $PsExe -Argument $Args -WorkingDirectory $ServerRoot;$Trigger=New-ScheduledTaskTrigger -AtLogOn -User ([Security.Principal.WindowsIdentity]::GetCurrent().Name);$Principal=New-ScheduledTaskPrincipal -UserId ([Security.Principal.WindowsIdentity]::GetCurrent().Name) -LogonType Interactive -RunLevel Limited;$Settings=New-ScheduledTaskSettingsSet -MultipleInstances IgnoreNew -StartWhenAvailable
    Register-ScheduledTask -TaskName (Get-RustRemoteTaskName) -Action $Action -Trigger $Trigger -Principal $Principal -Settings $Settings -Description 'Tableau de bord web local du Rust Server Control Center.' -Force|Out-Null;Start-ScheduledTask -TaskName (Get-RustRemoteTaskName);return Get-RustRemoteTaskStatus -ServerRoot $ServerRoot
}
function Unregister-RustRemoteTask { param([string]$ServerRoot) if((Get-RustRemoteTaskStatus -ServerRoot $ServerRoot).Installed){Stop-ScheduledTask -TaskName (Get-RustRemoteTaskName) -ErrorAction SilentlyContinue;Unregister-ScheduledTask -TaskName (Get-RustRemoteTaskName) -Confirm:$false};return Get-RustRemoteTaskStatus -ServerRoot $ServerRoot }

function Get-RustRemoteAdvertisedUrls {
    param([Parameter(Mandatory = $true)][string]$ServerRoot)
    $Config = Get-RustRemoteAccessConfig -ServerRoot $ServerRoot
    $Rows = New-Object Collections.Generic.List[object]
    $Rows.Add([pscustomobject]@{ Kind='LOCAL'; Adapter='Boucle locale'; Address='127.0.0.1'; Url=("http://127.0.0.1:{0}/" -f [int]$Config.port); Reachable=$true })
    if ([string]$Config.bindAddress -ne '0.0.0.0') { return [object[]]$Rows.ToArray() }
    $VpnPattern = '(?i)tailscale|wireguard|zerotier|hamachi|radmin\s*vpn|openvpn|mullvad|proton\s*vpn'
    try {
        foreach ($Adapter in @(Get-NetAdapter -ErrorAction Stop | Where-Object Status -eq 'Up')) {
            foreach ($Address in @(Get-NetIPAddress -InterfaceIndex $Adapter.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue | Where-Object { $_.IPAddress -notmatch '^(127\.|169\.254\.)' } | ForEach-Object IPAddress)) {
                $IsVpn = ([string]$Adapter.Name -match $VpnPattern -or [string]$Adapter.InterfaceDescription -match $VpnPattern)
                $Rows.Add([pscustomobject]@{ Kind=$(if($IsVpn){'VPN'}else{'LAN'}); Adapter=[string]$Adapter.Name; Address=[string]$Address; Url=("http://{0}:{1}/" -f $Address,[int]$Config.port); Reachable=$true })
            }
        }
    }
    catch { }
    return [object[]]$Rows.ToArray()
}

# ----- Sante du PC --------------------------------------------------------

function Get-RustHostHealthSnapshot {
    param([Parameter(Mandatory = $true)][string]$ServerRoot)

    $Rows = New-Object Collections.Generic.List[object]
    $Adapters = New-Object Collections.Generic.List[object]
    $CpuPercent = 0
    $TotalMemory = 0L
    $FreeMemory = 0L
    $DiskTotal = 0L
    $DiskFree = 0L

    try {
        $CpuSamples = @(Get-CimInstance Win32_Processor -ErrorAction Stop)
        if ($CpuSamples.Count) {
            $CpuPercent = [int][math]::Round((($CpuSamples | Measure-Object LoadPercentage -Average).Average),0)
        }
        $CpuStatus = if ($CpuPercent -lt 75) { 'OK' } elseif ($CpuPercent -lt 90) { 'WARNING' } else { 'ERROR' }
        $Rows.Add([pscustomobject]@{ Status=$CpuStatus; Check='Charge processeur'; Detail="$CpuPercent % sur $([Environment]::ProcessorCount) processeurs logiques."; Action=$(if($CpuStatus -eq 'OK'){'Marge disponible.'}else{'Ferme les applications lourdes avant de démarrer plusieurs serveurs.'}); RepairCode='OpenTaskManager' })
    }
    catch {
        $Rows.Add([pscustomobject]@{ Status='WARNING'; Check='Charge processeur'; Detail=$_.Exception.Message; Action='Ouvrir le Gestionnaire des tâches.'; RepairCode='OpenTaskManager' })
    }

    try {
        $OperatingSystem = Get-CimInstance Win32_OperatingSystem -ErrorAction Stop
        $TotalMemory = [long]$OperatingSystem.TotalVisibleMemorySize * 1KB
        $FreeMemory = [long]$OperatingSystem.FreePhysicalMemory * 1KB
        $MemoryStatus = if ($FreeMemory -ge 10GB) { 'OK' } elseif ($FreeMemory -ge 6GB) { 'WARNING' } else { 'ERROR' }
        $Rows.Add([pscustomobject]@{ Status=$MemoryStatus; Check='Mémoire disponible'; Detail=((Format-RustByteSize $FreeMemory) + ' libres sur ' + (Format-RustByteSize $TotalMemory) + '.'); Action=$(if($MemoryStatus -eq 'OK'){'Capacité suffisante pour une instance standard.'}else{"Ferme des applications ou démarre moins d'instances."}); RepairCode='OpenTaskManager' })
    }
    catch {
        $Rows.Add([pscustomobject]@{ Status='WARNING'; Check='Mémoire disponible'; Detail=$_.Exception.Message; Action='Ouvrir le Gestionnaire des tâches.'; RepairCode='OpenTaskManager' })
    }

    try {
        $Drive = [IO.DriveInfo]::new([IO.Path]::GetPathRoot([IO.Path]::GetFullPath($ServerRoot)))
        $DiskTotal = [long]$Drive.TotalSize
        $DiskFree = [long]$Drive.AvailableFreeSpace
        $DiskStatus = if ($DiskFree -ge 40GB) { 'OK' } elseif ($DiskFree -ge 20GB) { 'WARNING' } else { 'ERROR' }
        $Rows.Add([pscustomobject]@{ Status=$DiskStatus; Check='Stockage disponible'; Detail=((Format-RustByteSize $DiskFree) + ' libres sur ' + (Format-RustByteSize $DiskTotal) + '.'); Action=$(if($DiskStatus -eq 'OK'){'Marge correcte pour les mises à jour et sauvegardes.'}else{'Libère au moins 20 Go avant un runtime isolé.'}); RepairCode='OpenStorageSettings' })
    }
    catch {
        $Rows.Add([pscustomobject]@{ Status='WARNING'; Check='Stockage disponible'; Detail=$_.Exception.Message; Action='Vérifier le stockage Windows.'; RepairCode='OpenStorageSettings' })
    }

    $RustProcesses = @(Get-Process -Name RustDedicated -ErrorAction SilentlyContinue)
    $RustMemory = [long](($RustProcesses | Measure-Object WorkingSet64 -Sum).Sum)
    $Rows.Add([pscustomobject]@{ Status='INFO'; Check='Processus Rust'; Detail=("{0} processus · {1} utilisés." -f $RustProcesses.Count,(Format-RustByteSize $RustMemory)); Action='Chaque serveur actif consomme du CPU, de la RAM et des accès disque.'; RepairCode='OpenSupervision' })

    $Instances = @()
    try {
        $Catalog = Get-RustInstanceCatalog -ServerRoot $ServerRoot
        Assert-RustInstanceCatalog $Catalog
        $Instances = @($Catalog.instances)
        $Rows.Add([pscustomobject]@{ Status='OK'; Check='Ports des instances'; Detail=("{0} profil(s), aucun doublon de port ou d’identité." -f $Instances.Count); Action='Les blocs de ports peuvent fonctionner simultanément.'; RepairCode='OpenInstances' })
    }
    catch {
        $Rows.Add([pscustomobject]@{ Status='ERROR'; Check='Ports des instances'; Detail=$_.Exception.Message; Action='Corriger les profils avant le multi-instance.'; RepairCode='OpenInstances' })
    }

    try {
        $Profiles = @(Get-NetFirewallProfile -ErrorAction Stop)
        $EnabledProfiles = @($Profiles | Where-Object Enabled)
        $Rows.Add([pscustomobject]@{ Status=$(if($EnabledProfiles.Count){'OK'}else{'ERROR'}); Check='Pare-feu Windows'; Detail=$(if($EnabledProfiles.Count){(($EnabledProfiles | ForEach-Object Name) -join ', ') + ' actif(s).'}else{'Tous les profils sont désactivés.'}); Action="Conserve le pare-feu actif et n'ouvre que les ports Rust nécessaires."; RepairCode='OpenFirewall' })
    }
    catch {
        $Rows.Add([pscustomobject]@{ Status='WARNING'; Check='Pare-feu Windows'; Detail=$_.Exception.Message; Action='Ouvrir les paramètres du pare-feu.'; RepairCode='OpenFirewall' })
    }

    $VpnPattern = '(?i)tailscale|wireguard|zerotier|hamachi|radmin\s*vpn|openvpn|mullvad|proton\s*vpn'
    try {
        foreach ($Adapter in @(Get-NetAdapter -ErrorAction Stop | Where-Object Status -eq 'Up')) {
            $Addresses = @(Get-NetIPAddress -InterfaceIndex $Adapter.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue | Where-Object { $_.IPAddress -notmatch '^169\.254\.' } | ForEach-Object IPAddress)
            if (-not $Addresses.Count) { continue }
            $IsVpn = ([string]$Adapter.Name -match $VpnPattern -or [string]$Adapter.InterfaceDescription -match $VpnPattern)
            $Profile = @(Get-NetConnectionProfile -InterfaceIndex $Adapter.ifIndex -ErrorAction SilentlyContinue | Select-Object -First 1)
            $Adapters.Add([pscustomobject]@{
                Adapter = [string]$Adapter.Name
                Type = if ($IsVpn) { 'VPN' } else { [string]$Adapter.MediaType }
                Address = $Addresses -join ', '
                Profile = if ($Profile.Count) { [string]$Profile[0].NetworkCategory } else { '—' }
                Vpn = if ($IsVpn) { 'OUI' } else { 'NON' }
            })
        }
        $VpnAdapters = @($Adapters | Where-Object Vpn -eq 'OUI')
        $Rows.Add([pscustomobject]@{ Status=$(if($VpnAdapters.Count){'OK'}else{'INFO'}); Check='Accès VPN'; Detail=$(if($VpnAdapters.Count){("{0} adaptateur(s) VPN détecté(s)." -f $VpnAdapters.Count)}else{'Aucun adaptateur VPN détecté.'}); Action=$(if($VpnAdapters.Count){'Le tableau de bord distant peut rester privé sur ce VPN.'}else{'Facultatif : installe un VPN maillé avant un accès distant hors du domicile.'}); RepairCode='OpenRemote' })
    }
    catch {
        $Rows.Add([pscustomobject]@{ Status='WARNING'; Check='Cartes réseau'; Detail=$_.Exception.Message; Action='Ouvrir les paramètres réseau Windows.'; RepairCode='OpenNetworkSettings' })
    }

    $DefaultEstimate = 6
    $ConfiguredEstimates = @($Instances | ForEach-Object { if ($_.PSObject.Properties.Name -contains 'memoryEstimateGb' -and [double]$_.memoryEstimateGb -gt 0) { [double]$_.memoryEstimateGb } else { 6 } })
    if ($ConfiguredEstimates.Count) { $DefaultEstimate = [math]::Max(2,[double](($ConfiguredEstimates | Measure-Object -Average).Average)) }
    $RamCapacity = if ($FreeMemory -gt 2GB) { [int][math]::Floor((($FreeMemory - 2GB) / 1GB) / $DefaultEstimate) } else { 0 }
    $DiskCapacity = if ($DiskFree -gt 15GB) { [int][math]::Floor((($DiskFree - 15GB) / 1GB) / 20) } else { 0 }
    $SafeAdditional = [math]::Max(0,[math]::Min($RamCapacity,$DiskCapacity))
    $CapacityDetail = "Avec une marge de 2 Go de RAM et 15 Go de disque, ce PC peut démarrer environ $SafeAdditional instance(s) supplémentaire(s) estimée(s) à $([math]::Round($DefaultEstimate,1)) Go. Un runtime complet isolé demande environ 20 Go de disque. Ce calcul reste une estimation : la taille de carte, Carbon et les plugins peuvent augmenter la consommation."

    return [pscustomobject]@{
        GeneratedUtc = [datetime]::UtcNow.ToString('o')
        CpuPercent = $CpuPercent
        TotalMemoryBytes = $TotalMemory
        FreeMemoryBytes = $FreeMemory
        DiskTotalBytes = $DiskTotal
        DiskFreeBytes = $DiskFree
        RustProcessCount = $RustProcesses.Count
        RustMemoryBytes = $RustMemory
        ConfiguredInstances = $Instances.Count
        SafeAdditionalInstances = $SafeAdditional
        CapacityDetail = $CapacityDetail
        Rows = [object[]]$Rows.ToArray()
        Adapters = [object[]]$Adapters.ToArray()
    }
}
