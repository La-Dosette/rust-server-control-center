[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$ServerRoot,
    [Parameter(Mandatory = $true)][string]$InstanceId,
    [Parameter(Mandatory = $true)][string]$OperationId,
    [ValidateRange(30,900)][int]$StartupTimeoutSeconds = 180,
    [ValidateRange(30,1800)][int]$WaitForFriendSeconds = 300
)

$ErrorActionPreference = 'Stop'
$ServerRoot = [IO.Path]::GetFullPath($ServerRoot)
. (Join-Path $ServerRoot 'tool\RustRPG-Common.ps1')
. (Join-Path $ServerRoot 'tool\RustRPG-Operations.ps1')
. (Join-Path $ServerRoot 'tool\RustRPG-Services.ps1')

$Operation = @(Get-RustTrackedOperations -ServerRoot $ServerRoot | Where-Object id -eq $OperationId) | Select-Object -First 1
if (-not $Operation) { throw "Operation '$OperationId' introuvable." }
$Instance = @((Get-RustInstanceCatalog -ServerRoot $ServerRoot).instances | Where-Object id -eq $InstanceId) | Select-Object -First 1
if (-not $Instance) { throw "Instance '$InstanceId' introuvable." }
if (-not [bool]$Instance.isPublic) { throw 'Le test ami exige une instance marquee publique.' }

$LogPath = [string]$Operation.logPath
if (-not $LogPath) { $LogPath = Join-Path $ServerRoot ('logs\friend-test-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.txt') }
$ReportPath = if ($Operation.metadata -and $Operation.metadata.PSObject.Properties.Name -contains 'reportPath') { [string]$Operation.metadata.reportPath } else { [IO.Path]::ChangeExtension($LogPath,'.json') }
$CancelPath = Join-Path $ServerRoot ("data\friend-test-cancel-$OperationId.request")
[IO.Directory]::CreateDirectory((Split-Path $LogPath -Parent)) | Out-Null
[IO.Directory]::CreateDirectory((Split-Path $ReportPath -Parent)) | Out-Null

$Checks = New-Object Collections.Generic.List[object]
$StartedUtc = [datetime]::UtcNow
$Report = [pscustomobject][ordered]@{
    schemaVersion = 1
    operationId = $OperationId
    generatedUtc = $StartedUtc.ToString('o')
    completedUtc = ''
    result = 'Running'
    server = [pscustomobject][ordered]@{id=[string]$Instance.id;name=[string]$Instance.displayName;identity=[string]$Instance.identity;gamePort=[int]$Instance.serverPort;queryPort=[int]$Instance.queryPort;rconPort=[int]$Instance.rconPort}
    serverStartedByTest = $false
    accessMode = ''
    connectionCommand = ''
    publicIp = ''
    lanIp = ''
    friendDetected = $false
    friend = $null
    checks = $Checks
}

function Write-FriendTestLog([string]$Text) {
    $Line = ('[{0}] {1}' -f (Get-Date -Format 'HH:mm:ss'),$Text)
    Add-Content -LiteralPath $LogPath -Value $Line -Encoding UTF8
    Write-Output $Line
}

function Save-FriendTestReport {
    $Report.checks = [object[]]$Checks.ToArray()
    $null = Save-RustJsonAtomic -Path $ReportPath -Value $Report
}

function Add-FriendCheck([string]$Name,[string]$Status,[string]$Detail,[string]$Action = '') {
    $Checks.Add([pscustomobject][ordered]@{name=$Name;status=$Status;detail=$Detail;action=$Action;utc=[datetime]::UtcNow.ToString('o')})
    Write-FriendTestLog ("$Status - $Name - $Detail")
    Save-FriendTestReport
}

function Set-FriendTestProgress([double]$Progress,[string]$Stage,[string]$Detail) {
    $null = Update-RustTrackedOperation -ServerRoot $ServerRoot -Id $OperationId -Changes @{progress=$Progress;stage=$Stage;detail=$Detail}
    Write-FriendTestLog ("$Stage - $Detail")
}

function Assert-FriendTestNotCancelled {
    if (Test-Path -LiteralPath $CancelPath -PathType Leaf) { throw [OperationCanceledException]::new('Test ami annule par utilisateur.') }
}

function Get-TestPlayers {
    try {
        $Raw = [string](Invoke-RustRpgRconCommand -ServerRoot $ServerRoot -RconPort ([int]$Instance.rconPort) -Command 'playerlist' -TimeoutMs 7000)
        if (-not $Raw) { return @() }
        return @($Raw | ConvertFrom-Json)
    }
    catch { return @() }
}

function Complete-FriendTest([ValidateSet('Succeeded','Failed','Cancelled')][string]$Status,[string]$Stage,[string]$Detail,[string]$Result) {
    $Report.completedUtc = [datetime]::UtcNow.ToString('o')
    $Report.result = $Result
    Save-FriendTestReport
    $SummaryLines = @(
        'RUST SERVER CONTROL CENTER - RAPPORT TEST AMI',
        '================================================',
        ('Resultat : ' + $Result),
        ('Serveur : ' + [string]$Instance.displayName),
        ('Commande : ' + [string]$Report.connectionCommand),
        ('Mode acces : ' + [string]$Report.accessMode),
        ('Ami detecte : ' + [string]$Report.friendDetected),
        ('Rapport JSON : ' + $ReportPath),
        '',
        'CONTROLES'
    )
    foreach ($Check in $Checks) { $SummaryLines += ('- [{0}] {1} : {2}{3}' -f $Check.status,$Check.name,$Check.detail,$(if($Check.action){' | '+$Check.action}else{''})) }
    Write-Utf8File -Path $LogPath -Content ($SummaryLines -join [Environment]::NewLine)
    $null = Complete-RustTrackedOperation -ServerRoot $ServerRoot -Id $OperationId -Status $Status -Stage $Stage -Detail $Detail
}

try {
    if (Test-Path -LiteralPath $CancelPath) { Remove-Item -LiteralPath $CancelPath -Force }
    Set-FriendTestProgress 3 'PREPARATION' 'Verification du profil public et de la configuration locale.'
    $ServerExe = Join-Path $ServerRoot 'server\RustDedicated.exe'
    if (-not (Test-Path -LiteralPath $ServerExe -PathType Leaf)) { throw "Rust Dedicated n'est pas installe. Utilise Mettre a jour avant le test ami." }

    Assert-FriendTestNotCancelled
    Set-FriendTestProgress 10 'ADRESSES' 'Detection des adresses locale et publique.'
    $AddressState = Update-RustNetworkAddressState -ServerRoot $ServerRoot
    $Report.publicIp = [string]$AddressState.lastPublicIp
    $Report.lanIp = [string]$AddressState.lastLanIp
    $ReservationDetail = switch ([string]$AddressState.reservationStatus) {
        'Static' { 'Adresse IPv4 statique configuree dans Windows.' }
        'ProbableReservation' { 'Meme adresse observee sur plusieurs baux DHCP : reservation probable.' }
        'Changed' { "Adresse locale modifiee : $($AddressState.previousLanIp) vers $($AddressState.lastLanIp)." }
        default { 'DHCP actif : la reservation dans le routeur ne peut pas encore etre confirmee.' }
    }
    Add-FriendCheck 'Adresse locale et reservation DHCP' $(if([bool]$AddressState.lanChanged){'WARNING'}else{'OK'}) $ReservationDetail $(if([bool]$AddressState.lanChanged){'Corrige les redirections NAT vers la nouvelle IP.'}else{''})
    if ([bool]$AddressState.publicChanged) { Add-FriendCheck 'Adresse publique' 'WARNING' "IP publique modifiee : $($AddressState.previousPublicIp) vers $($AddressState.lastPublicIp)." 'La commande amis et le DDNS vont etre actualises.' }
    else { Add-FriendCheck 'Adresse publique' 'OK' ([string]$AddressState.lastPublicIp) }

    $AccessConfig = Get-RustNetworkAccessConfig -ServerRoot $ServerRoot
    if ([bool]$AccessConfig.ddns.enabled) {
        Assert-FriendTestNotCancelled
        Set-FriendTestProgress 17 'DDNS' ("Mise a jour " + [string]$AccessConfig.ddns.provider + '.')
        try {
            $Ddns = Invoke-RustDdnsUpdate -ServerRoot $ServerRoot -PublicIp ([string]$AddressState.lastPublicIp)
            Add-FriendCheck 'DNS dynamique' 'OK' ("$($Ddns.Hostname) pointe vers $($Ddns.Address).")
        }
        catch { Add-FriendCheck 'DNS dynamique' 'ERROR' $_.Exception.Message 'Verifie le nom, la cle DDNS et la connexion Internet.'; throw }
    }

    $Document = Update-RustFriendConnectionDocument -ServerRoot $ServerRoot -Instance $Instance -AddressState $AddressState
    $Endpoint = $Document.Endpoint
    $Report.accessMode = [string]$Endpoint.Source
    $Report.connectionCommand = [string]$Endpoint.Command
    Add-FriendCheck 'Commande a partager' $(if([string]$Endpoint.Host){'OK'}else{'ERROR'}) ([string]$Endpoint.Command) 'Copie uniquement cette commande a ton ami.'
    if (-not [string]$Endpoint.Host) { throw 'Aucune adresse partageable pour le mode selectionne.' }

    Assert-FriendTestNotCancelled
    $Running = @(Get-RustRpgServerProcesses -ServerRoot $ServerRoot | Where-Object Identity -eq ([string]$Instance.identity)) | Select-Object -First 1
    if (-not $Running) {
        Set-FriendTestProgress 24 'DEMARRAGE' ("Demarrage silencieux de " + [string]$Instance.displayName + '.')
        $PowerShellExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
        $StartLog = [IO.Path]::ChangeExtension($LogPath,'.server.log')
        $StartError = [IO.Path]::ChangeExtension($LogPath,'.server-error.log')
        $Arguments = @('-NoLogo','-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-WindowStyle','Hidden','-File',('"'+(Join-Path $ServerRoot 'Start-Instance.ps1')+'"'),'-InstanceId',[string]$Instance.id)
        $Launcher = Start-Process -FilePath $PowerShellExe -ArgumentList $Arguments -WorkingDirectory $ServerRoot -WindowStyle Hidden -RedirectStandardOutput $StartLog -RedirectStandardError $StartError -PassThru
        $Report.serverStartedByTest = $true
    }
    else { Add-FriendCheck 'Demarrage du serveur' 'OK' "Serveur deja actif (PID $($Running.ProcessId))." }

    $StartupDeadline = (Get-Date).AddSeconds($StartupTimeoutSeconds)
    do {
        Assert-FriendTestNotCancelled
        $Running = @(Get-RustRpgServerProcesses -ServerRoot $ServerRoot | Where-Object Identity -eq ([string]$Instance.identity)) | Select-Object -First 1
        $GameListener = @(Get-NetUDPEndpoint -LocalPort ([int]$Instance.serverPort) -ErrorAction SilentlyContinue)
        $QueryListener = @(Get-NetUDPEndpoint -LocalPort ([int]$Instance.queryPort) -ErrorAction SilentlyContinue)
        if ($Running -and $GameListener.Count -and $QueryListener.Count) { break }
        $Elapsed = $StartupTimeoutSeconds - [math]::Max(0,[int]($StartupDeadline - (Get-Date)).TotalSeconds)
        $Progress = 24 + [math]::Min(30,[math]::Round(30 * $Elapsed / $StartupTimeoutSeconds))
        $null = Update-RustTrackedOperation -ServerRoot $ServerRoot -Id $OperationId -Changes @{progress=$Progress;stage='DEMARRAGE';detail="Rust charge la carte et les plugins... $Elapsed s"}
        Start-Sleep -Seconds 2
    } while ((Get-Date) -lt $StartupDeadline)
    if (-not $Running) { throw 'RustDedicated s est arrete pendant le demarrage. Consulte le journal serveur associe.' }
    if (-not $GameListener.Count -or -not $QueryListener.Count) { throw "Le serveur tourne mais les ports UDP $($Instance.serverPort)/$($Instance.queryPort) n'ecoutent pas apres $StartupTimeoutSeconds secondes." }
    Add-FriendCheck 'Demarrage du serveur' 'OK' "PID $($Running.ProcessId), ports UDP $($Instance.serverPort) et $($Instance.queryPort) en ecoute."

    Assert-FriendTestNotCancelled
    Set-FriendTestProgress 58 'PARE-FEU' 'Verification des autorisations Windows.'
    $Diagnostics = @(Get-RustRpgNetworkDiagnostics -ServerRoot $ServerRoot -FriendCommand ([string]$Endpoint.Command))
    $GameFirewall = @($Diagnostics | Where-Object Test -eq "Pare-feu UDP $($Instance.serverPort)") | Select-Object -First 1
    $QueryFirewall = @($Diagnostics | Where-Object Test -eq "Pare-feu UDP $($Instance.queryPort)") | Select-Object -First 1
    Add-FriendCheck 'Pare-feu port jeu' $(if($GameFirewall.Statut-eq'OK'){'OK'}else{'ERROR'}) ([string]$GameFirewall.Detail) ([string]$GameFirewall.Action)
    Add-FriendCheck 'Pare-feu port query' $(if($QueryFirewall.Statut-eq'OK'){'OK'}else{'WARNING'}) ([string]$QueryFirewall.Detail) ([string]$QueryFirewall.Action)
    if (-not $GameFirewall -or [string]$GameFirewall.Statut -ne 'OK') { throw "Le pare-feu Windows ne confirme pas le port jeu UDP $($Instance.serverPort)." }

    Assert-FriendTestNotCancelled
    $AccessMode = [string]$AccessConfig.access.mode
    if ($AccessMode -eq 'Direct') {
        Set-FriendTestProgress 68 'STEAM EXTERNE' 'Verification depuis l annuaire public Steam.'
        $Steam = $null
        for ($Attempt=1;$Attempt -le 3;$Attempt++) {
            Assert-FriendTestNotCancelled
            $Steam = Get-RustRpgSteamExternalVisibility -PublicIp ([string]$AddressState.lastPublicIp) -QueryPort ([int]$Instance.queryPort) -GamePort ([int]$Instance.serverPort)
            if ([string]$Steam.Statut -eq 'OK') { break }
            if ($Attempt -lt 3) { $null = Update-RustTrackedOperation -ServerRoot $ServerRoot -Id $OperationId -Changes @{progress=(68+$Attempt*3);stage='STEAM EXTERNE';detail="Serveur pas encore publie, nouvelle tentative $($Attempt+1)/3..."};Start-Sleep -Seconds 15 }
        }
        Add-FriendCheck 'Visibilite Steam externe' ([string]$Steam.Statut) ([string]$Steam.Detail) ([string]$Steam.Action)
        if ([string]$Steam.Statut -eq 'ERREUR') { throw 'Steam ne voit pas encore le serveur depuis Internet. Verifie NAT/CGNAT puis relance le test.' }
    }
    elseif ($AccessMode -eq 'Tailscale') {
        Set-FriendTestProgress 70 'TAILSCALE' 'Verification du reseau prive Tailscale.'
        $Tail = Get-RustTailscaleStatus
        if (-not $Tail.Installed -or -not $Tail.Running) { Add-FriendCheck 'Tailscale' 'ERROR' 'Tailscale absent ou deconnecte.' 'Installe Tailscale sur les deux PC et partage cette machine.';throw 'Le profil Tailscale n est pas pret.' }
        Add-FriendCheck 'Tailscale' 'OK' ("Adresse privee : " + [string]$Tail.IPv4) 'Chaque ami doit installer Tailscale et accepter le partage de cette machine.'
    }
    else {
        Set-FriendTestProgress 70 'TUNNEL UDP' 'Verification de la commande publique du tunnel.'
        Add-FriendCheck 'Tunnel UDP' 'WARNING' ("Relais configure : $($Endpoint.Host):$($Endpoint.Port).") "Le tunnel doit relayer UDP vers 127.0.0.1:$($Instance.serverPort); un second tunnel query est recommande."
    }

    Assert-FriendTestNotCancelled
    Set-FriendTestProgress 80 'ATTENTE DE L AMI' ("Serveur pret. Partage : " + [string]$Endpoint.Command)
    $InitialPlayers = @(Get-TestPlayers)
    $InitialIds = @($InitialPlayers | ForEach-Object { [string]$_.SteamID })
    $Friend = $InitialPlayers | Select-Object -First 1
    $WaitStarted = Get-Date
    while (-not $Friend -and ((Get-Date) - $WaitStarted).TotalSeconds -lt $WaitForFriendSeconds) {
        Assert-FriendTestNotCancelled
        Start-Sleep -Seconds 3
        $Players = @(Get-TestPlayers)
        $Friend = @($Players | Where-Object { [string]$_.SteamID -notin $InitialIds }) | Select-Object -First 1
        if (-not $Friend -and $InitialPlayers.Count -gt 0) { $Friend = $InitialPlayers | Select-Object -First 1 }
        $Elapsed = [int]((Get-Date) - $WaitStarted).TotalSeconds
        $Progress = 80 + [math]::Min(18,[math]::Round(18 * $Elapsed / $WaitForFriendSeconds))
        $null = Update-RustTrackedOperation -ServerRoot $ServerRoot -Id $OperationId -Changes @{progress=$Progress;stage='ATTENTE DE L AMI';detail="Commande prete : $($Endpoint.Command) - attente $Elapsed/$WaitForFriendSeconds s"}
    }
    if ($Friend) {
        $Report.friendDetected = $true
        $Report.friend = [pscustomobject][ordered]@{displayName=[string]$Friend.DisplayName;steamId=[string]$Friend.SteamID;ping=if($Friend.PSObject.Properties.Name-contains'Ping'){[int]$Friend.Ping}else{0};address=if($Friend.PSObject.Properties.Name-contains'Address'){[string]$Friend.Address}else{''}}
        Add-FriendCheck 'Connexion joueur' 'OK' ("Joueur detecte : " + [string]$Friend.DisplayName + '.')
        Complete-FriendTest -Status Succeeded -Stage 'AMI CONNECTE' -Detail ("Connexion confirmee : " + [string]$Friend.DisplayName + '.') -Result 'FriendConnected'
    }
    else {
        Add-FriendCheck 'Connexion joueur' 'WARNING' "Aucun nouvel ami detecte pendant $WaitForFriendSeconds secondes." 'Le serveur reste lance et la commande peut encore etre utilisee.'
        Complete-FriendTest -Status Succeeded -Stage 'PRET A PARTAGER' -Detail ("Reseau pret. Aucun ami detecte dans le delai. Commande : " + [string]$Endpoint.Command) -Result 'ReadyNoFriend'
    }
}
catch [OperationCanceledException] {
    Add-FriendCheck 'Annulation' 'WARNING' $_.Exception.Message 'Le serveur deja demarre reste dans son etat actuel.'
    Complete-FriendTest -Status Cancelled -Stage 'ANNULE' -Detail 'Test ami annule. Le serveur reste disponible.' -Result 'Cancelled'
}
catch {
    $Message = $_.Exception.Message
    Add-FriendCheck 'Echec final' 'ERROR' $Message 'Ouvre le rapport et le diagnostic reseau pour corriger le blocage.'
    Complete-FriendTest -Status Failed -Stage 'ECHEC' -Detail $Message -Result 'Failed'
    Write-Error $Message
    exit 1
}
finally {
    if (Test-Path -LiteralPath $CancelPath -PathType Leaf) { Remove-Item -LiteralPath $CancelPath -Force -ErrorAction SilentlyContinue }
}
