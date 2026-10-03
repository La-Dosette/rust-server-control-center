[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidatePattern('^[a-z0-9][a-z0-9-]{0,31}$')]
    [string]$InstanceId,
    [switch]$WatchdogRestart
)

$ErrorActionPreference = 'Stop'
$Root = $PSScriptRoot
. (Join-Path $Root 'tool\RustRPG-Common.ps1')
. (Join-Path $Root 'tool\RustRPG-Operations.ps1')
. (Join-Path $Root 'tool\RustRPG-Services.ps1')
$CatalogPath = Join-Path $Root 'instances.json'
$LogsDir = Join-Path $Root 'logs'
$RconPasswordFile = Join-Path $Root '.rcon-password.txt'

if (-not (Test-Path -LiteralPath $CatalogPath)) { throw 'Le catalogue instances.json est introuvable.' }

$Catalog = Get-Content -LiteralPath $CatalogPath -Raw -Encoding utf8 | ConvertFrom-Json
$Instance = @($Catalog.instances | Where-Object id -eq $InstanceId) | Select-Object -First 1
if (-not $Instance) { throw "Instance '$InstanceId' introuvable." }
if ([string]$Instance.identity -notmatch '^[A-Za-z0-9_-]+$') { throw 'Identité Rust invalide.' }
$ServerDir = Get-RustInstanceRuntimeRoot -ServerRoot $Root -Instance $Instance
$ServerExe = Join-Path $ServerDir 'RustDedicated.exe'
if (-not (Test-Path -LiteralPath $ServerExe)) {
    if ([string]$Instance.isolationMode -eq 'full') { throw "Le runtime isolé n'est pas installé pour '$($Instance.displayName)'." }
    throw "Rust Dedicated n'est pas installé. Lance d'abord la mise à jour."
}

$Running = @(Get-CimInstance Win32_Process -Filter "Name = 'RustDedicated.exe'" -ErrorAction SilentlyContinue)
foreach ($Process in $Running) {
    $CommandLine = [string]$Process.CommandLine
    if ($CommandLine -match ('\+server\.identity\s+"?' + [regex]::Escape([string]$Instance.identity) + '(?:"|\s|$)')) {
        throw "Cette instance est déjà active (PID $($Process.ProcessId))."
    }
}

$Ports = @([int]$Instance.serverPort,[int]$Instance.rconPort,[int]$Instance.queryPort,[int]$Instance.appPort)
if (@($Ports | Select-Object -Unique).Count -ne 4) { throw 'Les quatre ports de cette instance doivent être différents.' }
foreach ($Port in $Ports) {
    if ($Port -lt 1025 -or $Port -gt 65535) { throw "Port invalide : $Port." }
    $Listener = Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue | Select-Object -First 1
    $UdpEndpoint = Get-NetUDPEndpoint -LocalPort $Port -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($Listener -or $UdpEndpoint) { throw "Le port $Port est déjà utilisé." }
}

$CfgDir = Join-Path $ServerDir ("server\" + [string]$Instance.identity + '\cfg')
New-Item -ItemType Directory -Force -Path $CfgDir,$LogsDir | Out-Null
foreach ($ConfigName in @('server.cfg','users.cfg')) {
    $Target = Join-Path $CfgDir $ConfigName
    $Template = Join-Path $Root ("config\" + $ConfigName)
    if (-not (Test-Path -LiteralPath $Target) -and (Test-Path -LiteralPath $Template)) {
        Copy-Item -LiteralPath $Template -Destination $Target -Force
    }
}

if (-not (Test-Path -LiteralPath $RconPasswordFile)) {
    $Bytes = New-Object byte[] 32
    [Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($Bytes)
    $Password = [Convert]::ToBase64String($Bytes).TrimEnd('=').Replace('+','A').Replace('/','B')
    [IO.File]::WriteAllText($RconPasswordFile,$Password,[Text.Encoding]::ASCII)
}
$RconPassword = (Get-Content -LiteralPath $RconPasswordFile -Raw).Trim()
$SafeLogId = ([string]$Instance.id -replace '[^a-z0-9-]','-')
$LogFile = Join-Path $LogsDir ("rust-$SafeLogId-" + (Get-Date -Format 'yyyy-MM-dd_HH-mm-ss') + '.log')

$ServerArgs = @(
    '-batchmode','-nographics',
    '+server.ip','0.0.0.0',
    '+server.port',[int]$Instance.serverPort,
    '+server.queryport',[int]$Instance.queryPort,
    '+server.level',[string]$Instance.level,
    '+server.identity',[string]$Instance.identity,
    '+rcon.ip','127.0.0.1',
    '+rcon.port',[int]$Instance.rconPort,
    '+rcon.password',$RconPassword,
    '+rcon.web',1,
    '+app.port',[int]$Instance.appPort,
    '-logfile',$LogFile
)
if ([string]$Instance.levelUrl) {
    $ServerArgs += @('+server.levelurl',[string]$Instance.levelUrl)
}
else {
    $ServerArgs += @('+server.seed',[long]$Instance.seed,'+server.worldsize',[int]$Instance.worldSize)
}

Push-Location $ServerDir
try {
    $null = Set-RustDesiredState -ServerRoot $Root -InstanceId $InstanceId -State Running -Reason $(if($WatchdogRestart){'watchdog'}else{'launcher'})
    & $ServerExe @ServerArgs
    $ExitCode = $LASTEXITCODE
}
finally { Pop-Location }
if ($ExitCode -notin @(0,-1)) {
    $null = Add-RustCrashEvent -ServerRoot $Root -InstanceId $InstanceId -Type StartFailure -Detail "RustDedicated s'est arrêté avec le code $ExitCode. Consulte $LogFile"
    throw "RustDedicated s'est arrêté avec le code $ExitCode. Consulte $LogFile"
}
