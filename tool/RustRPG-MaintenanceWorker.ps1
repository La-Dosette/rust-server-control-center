[CmdletBinding()]
param(
    [string]$ServerRoot = '',
    [string]$ScheduleId = '',
    [switch]$Force,
    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'
if(-not$ServerRoot){$ServerRoot=Split-Path $PSScriptRoot -Parent}
. (Join-Path $PSScriptRoot 'RustRPG-Common.ps1')
. (Join-Path $PSScriptRoot 'RustRPG-Operations.ps1')

$WorkerMutex = [Threading.Mutex]::new($false,'Local\RustRPGMaintenanceWorker')
$WorkerAcquired = $false
try {
    try { $WorkerAcquired = $WorkerMutex.WaitOne(0) }
    catch [Threading.AbandonedMutexException] { $WorkerAcquired = $true }
    if (-not $WorkerAcquired) { exit 0 }

    $LogDirectory = Join-Path $ServerRoot 'logs'
    New-Item -ItemType Directory -Path $LogDirectory -Force | Out-Null
    $LogPath = Join-Path $LogDirectory ('maintenance-' + (Get-Date -Format 'yyyy-MM-dd') + '.log')

    function Write-MaintenanceLog([string]$Message) {
        $Line = ('[{0}] {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'),$Message)
        Add-Content -LiteralPath $LogPath -Value $Line -Encoding UTF8
        Write-Output $Line
    }

    function Get-MaintenanceTargetProcess([string]$Identity) {
        return @(Get-RustRpgServerProcesses -ServerRoot $ServerRoot | Where-Object Identity -eq $Identity) | Select-Object -First 1
    }

    function Get-MaintenancePlayerCheck([int]$RconPort) {
        try {
            $Raw = [string](Invoke-RustRpgRconCommand -ServerRoot $ServerRoot -RconPort $RconPort -Command 'playerlist' -TimeoutMs 8000)
            if ([string]::IsNullOrWhiteSpace($Raw)) { return [pscustomobject]@{ Success=$true; Count=0 } }
            $Players = @($Raw | ConvertFrom-Json)
            return [pscustomobject]@{ Success=$true; Count=$Players.Count }
        }
        catch { return [pscustomobject]@{ Success=$false; Count=-1; Error=$_.Exception.Message } }
    }

    function Wait-MaintenanceTargetStopped([string]$Identity,[int]$TimeoutSeconds = 90) {
        $Deadline = (Get-Date).AddSeconds($TimeoutSeconds)
        while ((Get-Date) -lt $Deadline) {
            if (-not (Get-MaintenanceTargetProcess $Identity)) { return $true }
            Start-Sleep -Seconds 2
        }
        return $false
    }

    function Start-MaintenanceInstance([string]$InstanceId) {
        $PowerShellExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
        $LauncherPath = Join-Path $ServerRoot 'Start-Instance.ps1'
        $Arguments = @('-NoLogo','-NoProfile','-ExecutionPolicy','Bypass','-File',('"' + $LauncherPath + '"'),'-InstanceId',$InstanceId)
        Start-Process -FilePath $PowerShellExe -ArgumentList $Arguments -WorkingDirectory $ServerRoot -WindowStyle Hidden | Out-Null
    }

    $Store = Get-RustMaintenanceScheduleStore -ServerRoot $ServerRoot
    if ($ScheduleId) {
        $Schedules = @($Store.schedules | Where-Object id -eq $ScheduleId)
        if (-not $Schedules.Count) { throw "Regle '$ScheduleId' introuvable." }
        if (-not $Force) {
            $Schedules = @($Schedules | Where-Object {
                [bool]$_.enabled -and [datetime]::Parse([string]$_.nextRunUtc).ToUniversalTime() -le [datetime]::UtcNow
            })
        }
    }
    else { $Schedules = @(Get-RustDueMaintenanceSchedules -ServerRoot $ServerRoot) }

    foreach ($Schedule in $Schedules) {
        $Identity = [string]$Schedule.identity
        $ActionName = [string]$Schedule.action
        $Instance = Get-RustServerInstance -ServerRoot $ServerRoot -Identity $Identity
        if (-not $Instance) {
            $null = Set-RustMaintenanceScheduleResult -ServerRoot $ServerRoot -Id ([string]$Schedule.id) -Status Failed -Detail "Serveur '$Identity' introuvable. Regle desactivee."
            continue
        }

        $AllProcesses = @(Get-RustRpgServerProcesses -ServerRoot $ServerRoot)
        $TargetProcess = @($AllProcesses | Where-Object Identity -eq $Identity) | Select-Object -First 1
        $IsWipe = $ActionName -in @('MapWipe','FullWipe')
        $ShouldRestart = $false

        if ($IsWipe -and $AllProcesses.Count) {
            if ($AllProcesses.Count -gt 1 -or -not $TargetProcess) {
                $Detail = 'Wipe reporte de 15 minutes : une autre instance Rust est active.'
                Write-MaintenanceLog $Detail
                if (-not $DryRun) { $null = Set-RustMaintenanceScheduleResult -ServerRoot $ServerRoot -Id ([string]$Schedule.id) -Status Deferred -Detail $Detail }
                continue
            }
            if (-not [bool]$Schedule.stopAndRestart) {
                $Detail = 'Wipe reporte de 15 minutes : le serveur est actif et l arret automatique est desactive.'
                Write-MaintenanceLog $Detail
                if (-not $DryRun) { $null = Set-RustMaintenanceScheduleResult -ServerRoot $ServerRoot -Id ([string]$Schedule.id) -Status Deferred -Detail $Detail }
                continue
            }
            $PlayerCheck = Get-MaintenancePlayerCheck -RconPort ([int]$TargetProcess.RconPort)
            if (-not $PlayerCheck.Success) {
                $Detail = 'Wipe reporte de 15 minutes : impossible de verifier les joueurs par RCON.'
                Write-MaintenanceLog $Detail
                if (-not $DryRun) { $null = Set-RustMaintenanceScheduleResult -ServerRoot $ServerRoot -Id ([string]$Schedule.id) -Status Deferred -Detail $Detail }
                continue
            }
            if ($PlayerCheck.Count -gt 0) {
                $Detail = "Wipe reporte de 15 minutes : $($PlayerCheck.Count) joueur(s) encore connecte(s)."
                Write-MaintenanceLog $Detail
                if (-not $DryRun) { $null = Set-RustMaintenanceScheduleResult -ServerRoot $ServerRoot -Id ([string]$Schedule.id) -Status Deferred -Detail $Detail }
                continue
            }
        }

        if ($DryRun) {
            Write-MaintenanceLog ("DRY-RUN : {0} pour {1}." -f $ActionName,$Identity)
            continue
        }

        $Title = switch ($ActionName) {
            'Backup'   { "Sauvegarde planifiee de $Identity" }
            'FullWipe' { "Full wipe planifie de $Identity" }
            default    { "Wipe carte planifie de $Identity" }
        }
        $Operation = New-RustTrackedOperation -ServerRoot $ServerRoot -Type $(if($ActionName -eq 'Backup'){'Backup'}else{'Wipe'}) -Title $Title -ServerId $Identity -Stage 'PLANIFICATION' -Detail ("Regle : " + [string]$Schedule.name) -LogPath $LogPath -ProcessId $PID -Metadata ([pscustomobject]@{ scheduleId=[string]$Schedule.id; scheduled=$true })
        try {
            if ($ActionName -eq 'Backup') {
                if ($TargetProcess) {
                    $null = Update-RustTrackedOperation -ServerRoot $ServerRoot -Id ([string]$Operation.id) -Changes @{ progress=20.0; stage='SAUVEGARDE DU MONDE'; detail='Commande server.save envoyee avant la copie.' }
                    $null = Invoke-RustRpgRconCommand -ServerRoot $ServerRoot -RconPort ([int]$TargetProcess.RconPort) -Command 'server.save' -TimeoutMs 12000
                    Start-Sleep -Seconds 4
                }
                $null = Update-RustTrackedOperation -ServerRoot $ServerRoot -Id ([string]$Operation.id) -Changes @{ progress=48.0; stage='COPIE DES DONNEES'; detail='Copie du monde, des configurations et des donnees de plugins.' }
                $BackupPath = New-RustServerBackup -ServerRoot $ServerRoot -Identity $Identity -Kind 'scheduled' -AllowRunning:($AllProcesses.Count -gt 0)
                $Detail = "Sauvegarde planifiee terminee : $BackupPath"
                $RotationKinds = @('scheduled')
            }
            else {
                if ($TargetProcess) {
                    $null = Update-RustTrackedOperation -ServerRoot $ServerRoot -Id ([string]$Operation.id) -Changes @{ progress=14.0; stage='ARRET SECURISE'; detail='Sauvegarde Rust puis arret du serveur vide.' }
                    $null = Invoke-RustRpgRconCommand -ServerRoot $ServerRoot -RconPort ([int]$TargetProcess.RconPort) -Command 'server.save' -TimeoutMs 12000
                    Start-Sleep -Seconds 3
                    $null = Send-RustRpgRconCommand -ServerRoot $ServerRoot -RconPort ([int]$TargetProcess.RconPort) -Command 'quit'
                    if (-not (Wait-MaintenanceTargetStopped -Identity $Identity)) { throw "Le serveur ne s'est pas arrete dans le delai de securite." }
                    $ShouldRestart = $true
                }
                $null = Update-RustTrackedOperation -ServerRoot $ServerRoot -Id ([string]$Operation.id) -Changes @{ progress=42.0; stage='SAUVEGARDE & WIPE'; detail='Une sauvegarde complete est creee avant toute suppression.' }
                $WipeType = if ($ActionName -eq 'FullWipe') { 'full' } else { 'map' }
                $Result = Invoke-RustServerWipe -ServerRoot $ServerRoot -Identity $Identity -Type $WipeType -ResetPluginData:([bool]$Schedule.resetPluginData) -CleanGeneratedMaps:([bool]$Schedule.cleanGeneratedMaps)
                if ($ShouldRestart) {
                    $null = Update-RustTrackedOperation -ServerRoot $ServerRoot -Id ([string]$Operation.id) -Changes @{ progress=88.0; stage='REDEMARRAGE'; detail='Le serveur redemarre silencieusement sur le nouveau monde.' }
                    Start-MaintenanceInstance -InstanceId ([string]$Instance.id)
                    $ShouldRestart = $false
                }
                $Detail = "Wipe termine : $($Result.DeletedFiles) fichier(s) retire(s), sauvegarde $($Result.BackupPath)."
                $RotationKinds = @('pre-wipe-' + $WipeType)
            }
            $RetentionCount = if ($Schedule.PSObject.Properties.Name -contains 'retentionCount') { [int]$Schedule.retentionCount } else { 10 }
            $RemovedBackups = @(Remove-RustOldBackups -ServerRoot $ServerRoot -Identity $Identity -Keep $RetentionCount -Kinds $RotationKinds)
            if ($RemovedBackups.Count) { $Detail += " Rotation : $($RemovedBackups.Count) ancienne(s) sauvegarde(s) retiree(s)." }
            Write-MaintenanceLog $Detail
            $null = Complete-RustTrackedOperation -ServerRoot $ServerRoot -Id ([string]$Operation.id) -Status Succeeded -Stage 'TERMINE' -Detail $Detail
            $null = Set-RustMaintenanceScheduleResult -ServerRoot $ServerRoot -Id ([string]$Schedule.id) -Status Succeeded -Detail $Detail -OperationId ([string]$Operation.id)
        }
        catch {
            $ErrorDetail = $_.Exception.Message
            Write-MaintenanceLog ("ECHEC {0} : {1}" -f [string]$Schedule.name,$ErrorDetail)
            try { $null = Complete-RustTrackedOperation -ServerRoot $ServerRoot -Id ([string]$Operation.id) -Status Failed -Stage 'ECHEC' -Detail $ErrorDetail } catch {}
            try { $null = Set-RustMaintenanceScheduleResult -ServerRoot $ServerRoot -Id ([string]$Schedule.id) -Status Failed -Detail ($ErrorDetail + ' Regle desactivee par securite.') -OperationId ([string]$Operation.id) } catch {}
            if ($ShouldRestart) {
                try { Start-MaintenanceInstance -InstanceId ([string]$Instance.id) } catch { Write-MaintenanceLog ('Redemarrage de secours impossible : ' + $_.Exception.Message) }
            }
        }
    }
}
finally {
    if ($WorkerAcquired) { try { $WorkerMutex.ReleaseMutex() } catch {} }
    $WorkerMutex.Dispose()
}
