[CmdletBinding()]
param([switch]$Elevated)

$ErrorActionPreference = 'Stop'
$Root = $PSScriptRoot
$CatalogPath = Join-Path $Root 'instances.json'
if (-not (Test-Path -LiteralPath $CatalogPath)) { throw 'instances.json est introuvable.' }
$Catalog = Get-Content -LiteralPath $CatalogPath -Raw -Encoding utf8 | ConvertFrom-Json
$Instance = @($Catalog.instances | Where-Object isPublic) | Select-Object -First 1
if (-not $Instance) { throw 'Aucune instance publique n''est configuree.' }

function Test-IsAdministrator {
    $Identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $Principal = New-Object Security.Principal.WindowsPrincipal($Identity)
    return $Principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

if (-not (Test-IsAdministrator)) {
    $PowerShellExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $Process = Start-Process -FilePath $PowerShellExe -Verb RunAs -Wait -PassThru -WindowStyle Hidden -ArgumentList @(
        '-NoLogo','-NoProfile','-ExecutionPolicy','Bypass','-File',('"' + $PSCommandPath + '"'),'-Elevated'
    )
    exit $Process.ExitCode
}

$ServerExe = Join-Path $Root 'server\RustDedicated.exe'
$Ports = @([int]$Instance.serverPort,[int]$Instance.queryPort)
$RuleName = 'Rust-Control-Center-' + [string]$Instance.id + '-UDP'
$Existing = Get-NetFirewallRule -Name $RuleName -ErrorAction SilentlyContinue
if ($Existing) { Remove-NetFirewallRule -Name $RuleName }
$Arguments = @{
    Name = $RuleName
    DisplayName = "Rust Server - $($Instance.displayName) - UDP"
    Direction = 'Inbound'
    Action = 'Allow'
    Enabled = 'True'
    Profile = 'Any'
    Protocol = 'UDP'
    LocalPort = ($Ports -join ',')
}
if (Test-Path -LiteralPath $ServerExe) { $Arguments.Program = $ServerExe }
New-NetFirewallRule @Arguments | Out-Null

$PublicIp = try { (Invoke-RestMethod -Uri 'https://api.ipify.org' -TimeoutSec 10).Trim() } catch { 'VOTRE-IP-PUBLIQUE' }
$Text = @"
Commande a donner aux amis :
client.connect ${PublicIp}:$($Instance.serverPort)

Ports UDP a rediriger dans le routeur : $($Ports -join ', ')
Port RCON a garder prive : $($Instance.rconPort)
"@
[IO.File]::WriteAllText((Join-Path $Root 'CONNEXION-AMIS.txt'),$Text,[Text.UTF8Encoding]::new($true))
Write-Output "Pare-feu configure. Consulte GUIDE-RESEAU-UNIVERSEL.html pour la redirection du routeur."
