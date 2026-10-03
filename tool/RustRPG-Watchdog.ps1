[CmdletBinding()]
param([Parameter(Mandatory = $true)][string]$ServerRoot)
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'RustRPG-Common.ps1')
. (Join-Path $PSScriptRoot 'RustRPG-Operations.ps1')
. (Join-Path $PSScriptRoot 'RustRPG-Services.ps1')
[IO.Directory]::CreateDirectory((Join-Path $ServerRoot 'logs'))|Out-Null
$Log=Join-Path $ServerRoot 'logs\watchdog.log'
try{
    $Events=@(Invoke-RustWatchdogPass -ServerRoot $ServerRoot)
    if($Events.Count){Add-Content -LiteralPath $Log -Encoding UTF8 -Value ((Get-Date -Format 'yyyy-MM-dd HH:mm:ss')+' - '+(($Events|ForEach-Object{$_.type+': '+$_.detail})-join' | '))}
}
catch{Add-Content -LiteralPath $Log -Encoding UTF8 -Value ((Get-Date -Format 'yyyy-MM-dd HH:mm:ss')+' - ERREUR - '+$_.Exception.Message);throw}
