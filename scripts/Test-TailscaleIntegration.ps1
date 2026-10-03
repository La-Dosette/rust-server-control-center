[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$SourceRoot = Split-Path $PSScriptRoot -Parent
. (Join-Path $SourceRoot 'tool\RustRPG-Operations.ps1')

function Assert-TailscaleTest([bool]$Condition,[string]$Message) {
    if (-not $Condition) { throw "Test Tailscale échoué : $Message" }
}

$ConnectedJson = @'
{
  "Version": "1.90.1",
  "BackendState": "Running",
  "TailscaleIPs": ["100.75.10.20", "fd7a:115c:a1e0::1"],
  "Self": {
    "HostName": "rust-host",
    "DNSName": "rust-host.example.ts.net.",
    "UserID": 123,
    "Online": true,
    "TailscaleIPs": ["100.75.10.20", "fd7a:115c:a1e0::1"]
  },
  "CurrentTailnet": { "Name": "example.ts.net" },
  "User": { "123": { "LoginName": "host@example.test" } },
  "Peer": {
    "peer-a": { "HostName": "friend-online", "Online": true },
    "peer-b": { "HostName": "friend-offline", "Online": false }
  }
}
'@

$Connected = ConvertFrom-RustTailscaleStatusJson -Json $ConnectedJson -Executable 'C:\Program Files\Tailscale\tailscale.exe' -ServiceStatus Running
Assert-TailscaleTest $Connected.Installed 'le client doit être marqué installé'
Assert-TailscaleTest $Connected.Running 'BackendState Running et une IPv4 doivent produire Running'
Assert-TailscaleTest ($Connected.IPv4 -eq '100.75.10.20') 'IPv4 incorrecte'
Assert-TailscaleTest ($Connected.DnsName -eq 'rust-host.example.ts.net') 'le point final MagicDNS doit être retiré'
Assert-TailscaleTest ($Connected.PeerCount -eq 2) 'nombre total de pairs incorrect'
Assert-TailscaleTest ($Connected.OnlinePeerCount -eq 1) 'nombre de pairs en ligne incorrect'
Assert-TailscaleTest ($Connected.UserName -eq 'host@example.test') 'identité du compte incorrecte'

$NeedsLogin = ConvertFrom-RustTailscaleStatusJson -Json '{"BackendState":"NeedsLogin","TailscaleIPs":[],"Peer":{}}' -Executable 'tailscale.exe' -ServiceStatus Running
Assert-TailscaleTest $NeedsLogin.NeedsLogin 'NeedsLogin doit être détecté'
Assert-TailscaleTest (-not $NeedsLogin.Running) 'un client sans adresse ne doit pas être prêt'

$InvalidRejected = $false
try { $null = ConvertFrom-RustTailscaleStatusJson -Json '{invalid' -Executable 'tailscale.exe' }
catch { $InvalidRejected = $true }
Assert-TailscaleTest $InvalidRejected 'un JSON invalide doit être refusé'

Write-Output 'Tailscale integration OK: connected, login-required and invalid-response cases passed.'
