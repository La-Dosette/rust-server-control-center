[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$PackageRoot,
    [string]$OutputRoot = '',
    [ValidateSet('vanilla','carbon','oxide')][string]$Environment = 'vanilla',
    [switch]$InstallRust,
    [switch]$LaunchRust,
    [switch]$KeepFixture
)

$ErrorActionPreference = 'Stop'
$PackageRoot = [IO.Path]::GetFullPath($PackageRoot)
if (-not (Test-Path -LiteralPath $PackageRoot -PathType Container)) { throw "Paquet portable introuvable : $PackageRoot" }
if ($LaunchRust -and -not $InstallRust) { throw '-LaunchRust exige également -InstallRust.' }

$ExplicitOutput = [bool]$OutputRoot
if (-not $OutputRoot) { $OutputRoot = Join-Path ([IO.Path]::GetTempPath()) ('RustControlCenterFirstRun-' + [guid]::NewGuid().ToString('N')) }
$OutputRoot = [IO.Path]::GetFullPath($OutputRoot)
if (Test-Path -LiteralPath $OutputRoot) { throw "Le dossier de sortie existe déjà : $OutputRoot" }
[IO.Directory]::CreateDirectory($OutputRoot) | Out-Null
$InstallRoot = Join-Path $OutputRoot 'install'
$ArtifactRoot = Join-Path $OutputRoot 'artifacts'
[IO.Directory]::CreateDirectory($ArtifactRoot) | Out-Null
$Results = New-Object Collections.Generic.List[object]
$RustLauncherProcess = $null

function Add-FirstRunResult([string]$Stage,[bool]$Passed,[string]$Detail) {
    $Results.Add([pscustomobject]@{Stage=$Stage;Passed=$Passed;Detail=$Detail})
    if (-not $Passed) { throw "$Stage : $Detail" }
}

try {
    $ForbiddenRuntime = @('server','steamcmd','carbon','oxide') | Where-Object { Test-Path -LiteralPath (Join-Path $PackageRoot $_) }
    Add-FirstRunResult 'Paquet sans serveur préinstallé' ($ForbiddenRuntime.Count -eq 0) $(if($ForbiddenRuntime.Count){'Dossiers interdits : '+($ForbiddenRuntime -join ', ')}else{'Aucun binaire Rust, SteamCMD, Carbon ou Oxide dans le paquet.'})

    & (Join-Path $PackageRoot 'Install-ControlCenter.ps1') -InstallRoot $InstallRoot -NoShortcuts -NoLaunch | Out-Null
    $Version = (Get-Content -LiteralPath (Join-Path $InstallRoot 'VERSION') -Raw).Trim()
    $CleanInstall = -not (Test-Path -LiteralPath (Join-Path $InstallRoot 'server\RustDedicated.exe')) -and -not (Test-Path -LiteralPath (Join-Path $InstallRoot 'steamcmd\steamcmd.exe'))
    Add-FirstRunResult 'Installation Windows isolée' $CleanInstall "Control Center $Version installé sans raccourci, lancement ni serveur existant."

    . (Join-Path $InstallRoot 'tool\RustRPG-Common.ps1')
    . (Join-Path $InstallRoot 'tool\RustRPG-Operations.ps1')
    . (Join-Path $InstallRoot 'tool\RustRPG-Services.ps1')
    $ServerRoot = $InstallRoot
    $Migration = Invoke-RustControlCenterMigrations -ServerRoot $InstallRoot
    $Health = Get-RustHostHealthSnapshot -ServerRoot $InstallRoot
    Add-FirstRunResult 'Détection du matériel' ($Health.TotalMemoryBytes -gt 0 -and $Health.DiskFreeBytes -gt 0 -and @($Health.Rows).Count -ge 6) "$(@($Health.Rows).Count) contrôles · RAM et stockage détectés · capacité estimée $($Health.SafeAdditionalInstances)."

    $ModEnvironment = Get-RustModEnvironment -ServerRoot $InstallRoot
    Add-FirstRunResult 'Environnement initial Vanilla' ([string]$ModEnvironment.Id -eq 'vanilla' -and -not [bool]$ModEnvironment.Installed) 'Aucun framework de plugins créé par le diagnostic.'

    $InitialDiagnostics = @(Get-RustControlCenterDiagnostics -ServerRoot $InstallRoot)
    $BlockingRows = @($InitialDiagnostics | Where-Object Status -eq 'ERROR')
    $UnclearRows = @($BlockingRows | Where-Object { -not [string]$_.Detail -or -not [string]$_.Action -or -not [string]$_.RepairCode })
    $RustDiagnostic = @($BlockingRows | Where-Object Check -eq 'Rust Dedicated' | Select-Object -First 1)
    Add-FirstRunResult 'Erreurs compréhensibles et réparables' ($BlockingRows.Count -ge 1 -and $UnclearRows.Count -eq 0 -and $RustDiagnostic.Count -eq 1 -and [string]$RustDiagnostic[0].RepairCode -eq 'ServerUpdate') "$($BlockingRows.Count) blocage(s), chacun avec détail, action et code de réparation."

    $Repair = Repair-RustControlCenterSafeIssues -ServerRoot $InstallRoot
    $Secret = New-RustRconSecret -ServerRoot $InstallRoot
    $RepairReady = (Test-Path -LiteralPath (Join-Path $InstallRoot 'data') -PathType Container) -and (Test-Path -LiteralPath $Secret.Path -PathType Leaf) -and $Secret.Length -ge 40
    Add-FirstRunResult 'Réparation sûre' $RepairReady "$($Repair.Detail) Secret RCON local de $($Secret.Length) caractères créé."

    $FirstServer = New-RustServerInstanceFromProfile -ServerRoot $InstallRoot -DisplayName 'Premier serveur QA' -Identity 'qa-first' -ServerPort 39015 -RconPort 39016 -QueryPort 39017 -AppPort 39018 -WorldSize 1000 -MemoryEstimateGb 4 -MaxPlayers 10 -SaveInterval 300 -SelectAfterCreation $true
    $FirstConfig = Join-Path $InstallRoot 'server\server\qa-first\cfg\server.cfg'
    $ConnectionCommand = "client.connect 127.0.0.1:$($FirstServer.serverPort)"
    Add-FirstRunResult 'Création guidée du premier serveur' ((Test-Path -LiteralPath $FirstConfig -PathType Leaf) -and [string]$FirstServer.identity -eq 'qa-first') "Profil, quatre ports et configuration créés sans démarrer Rust."
    Add-FirstRunResult 'Adresse de première connexion' ($ConnectionCommand -eq 'client.connect 127.0.0.1:39015') $ConnectionCommand

    $CollisionRejected = $false
    $CollisionMessage = ''
    try { Assert-RustNewInstancePorts -ServerRoot $InstallRoot -Ports @(39015,39016,39017,39018) }
    catch { $CollisionRejected=$true;$CollisionMessage=$_.Exception.Message }
    Add-FirstRunResult 'Erreur de ports explicite' ($CollisionRejected -and $CollisionMessage -match 'déjà utilisé') $CollisionMessage

    if ($InstallRust) {
        $InstallArguments = @{}
        if ($Environment -eq 'carbon') { $InstallArguments.InstallCarbon = $true }
        elseif ($Environment -eq 'oxide') { $InstallArguments.InstallOxide = $true }
        & (Join-Path $InstallRoot 'Install-Update.ps1') @InstallArguments
        $RustExe = Join-Path $InstallRoot 'server\RustDedicated.exe'
        $InstalledEnvironment = Get-RustModEnvironment -ServerRoot $InstallRoot
        Add-FirstRunResult 'Installation réelle de Rust Dedicated' ((Test-Path -LiteralPath $RustExe -PathType Leaf) -and [string]$InstalledEnvironment.Id -eq $Environment) "Rust Dedicated et $Environment installés depuis leurs sources distantes."

        if ($LaunchRust) {
            $PowerShellExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
            $OutLog = Join-Path $ArtifactRoot 'first-server.stdout.log'
            $ErrorLog = Join-Path $ArtifactRoot 'first-server.stderr.log'
            $RustLauncherProcess = Start-Process -FilePath $PowerShellExe -ArgumentList @('-NoLogo','-NoProfile','-ExecutionPolicy','Bypass','-File',('"'+(Join-Path $InstallRoot 'Start-Instance.ps1')+'"'),'-InstanceId','qa-first') -WorkingDirectory $InstallRoot -WindowStyle Hidden -PassThru -RedirectStandardOutput $OutLog -RedirectStandardError $ErrorLog
            $Ready = $false
            $Deadline = [datetime]::UtcNow.AddMinutes(10)
            while ([datetime]::UtcNow -lt $Deadline -and -not $Ready) {
                $Ready = [bool](Get-NetUDPEndpoint -LocalPort 39015 -ErrorAction SilentlyContinue | Select-Object -First 1)
                if (-not $Ready) { Start-Sleep -Seconds 2 }
            }
            Add-FirstRunResult 'Premier démarrage réel' $Ready "Le serveur écoute sur UDP 39015 ; commande prête : $ConnectionCommand"
        }
    }
    else {
        Add-FirstRunResult 'Téléchargement lourd' $true 'Ignoré dans le test rapide. Utilise -InstallRust, puis éventuellement -LaunchRust, sur un runner dédié.'
    }

    $OnboardingCapture = Join-Path $ArtifactRoot 'first-run-onboarding.png'
    $ConnectionCapture = Join-Path $ArtifactRoot 'first-run-connection.png'
    $InteractionPath = Join-Path $ArtifactRoot 'first-run-interaction.json'
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -Sta -File (Join-Path $InstallRoot 'tool\RustRPG-Manager.ps1') -CapturePath $OnboardingCapture -CaptureTab 18 -CaptureUiMode advanced -V12InteractionQaPath $InteractionPath -ExitAfterCapture
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $OnboardingCapture -PathType Leaf)) { throw "La capture de l’assistant de première installation a échoué." }
    $Interaction = Get-Content -LiteralPath $InteractionPath -Raw -Encoding UTF8 | ConvertFrom-Json
    Add-FirstRunResult 'Bouton de réparation guidée' ([bool]$Interaction.onboarding.repairVisible -and [string]$Interaction.onboarding.repairCode -eq 'ServerUpdate') "Le blocage Rust Dedicated expose directement l’action de réparation ServerUpdate."
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -Sta -File (Join-Path $InstallRoot 'tool\RustRPG-Manager.ps1') -CapturePath $ConnectionCapture -CaptureTab 15 -CaptureWizardStep 6 -CaptureWizardServerName ([string]$FirstServer.displayName) -CaptureWizardServerPort ([int]$FirstServer.serverPort) -CaptureUiMode advanced -ExitAfterCapture
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $ConnectionCapture -PathType Leaf)) { throw "La capture de l’adresse de première connexion a échoué." }
    Add-FirstRunResult 'Interface de première installation' $true 'Assistant et écran de connexion rendus sans erreur WPF.'

    $Report = [pscustomobject][ordered]@{
        schemaVersion=1;generatedUtc=[datetime]::UtcNow.ToString('o');passed=$true;version=$Version
        packageRoot=$PackageRoot;installRoot=$InstallRoot;environment=$Environment;installRust=[bool]$InstallRust;launchRust=[bool]$LaunchRust
        connectionCommand=$ConnectionCommand;artifacts=[pscustomobject]@{onboarding=$OnboardingCapture;connection=$ConnectionCapture;interaction=$InteractionPath}
        results=[object[]]$Results.ToArray()
    }
    $ReportPath = Join-Path $ArtifactRoot 'first-run-report.json'
    [IO.File]::WriteAllText($ReportPath,($Report | ConvertTo-Json -Depth 10),[Text.UTF8Encoding]::new($false))
    [pscustomobject]@{Passed=$true;TestCount=$Results.Count;ReportPath=$ReportPath;OutputRoot=$OutputRoot;ConnectionCommand=$ConnectionCommand;FullRustTest=[bool]$InstallRust}
}
finally {
    if ($RustLauncherProcess -and -not $RustLauncherProcess.HasExited) {
        $MatchingRust = @(Get-CimInstance Win32_Process -Filter "Name = 'RustDedicated.exe'" -ErrorAction SilentlyContinue | Where-Object { [string]$_.ExecutablePath -like "$InstallRoot*" -and [string]$_.CommandLine -match '\+server\.identity\s+"?qa-first' })
        foreach ($Process in $MatchingRust) { Stop-Process -Id ([int]$Process.ProcessId) -Force -ErrorAction SilentlyContinue }
        if (-not $RustLauncherProcess.HasExited) { Stop-Process -Id $RustLauncherProcess.Id -Force -ErrorAction SilentlyContinue }
    }
    if (-not $KeepFixture -and -not $ExplicitOutput -and (Test-Path -LiteralPath $OutputRoot -PathType Container)) {
        $ResolvedTemp = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
        if (-not $OutputRoot.StartsWith($ResolvedTemp,[StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetFileName($OutputRoot) -notlike 'RustControlCenterFirstRun-*') { throw 'Nettoyage du test refusé : dossier inattendu.' }
        [IO.Directory]::Delete($OutputRoot,$true)
    }
}
