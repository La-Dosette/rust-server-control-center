[CmdletBinding()]
param([Parameter(Mandatory = $true)][string]$ServerRoot)

$ErrorActionPreference = 'Stop'
$ServerRoot = [IO.Path]::GetFullPath($ServerRoot)
. (Join-Path $ServerRoot 'tool\RustRPG-Common.ps1')
. (Join-Path $ServerRoot 'tool\RustRPG-Operations.ps1')
. (Join-Path $ServerRoot 'tool\RustRPG-Services.ps1')

$ResultPath = Join-Path $ServerRoot 'data\ddns-last-run.json'
try {
    $Result = Invoke-RustDdnsUpdate -ServerRoot $ServerRoot
    $Document = [pscustomobject][ordered]@{generatedUtc=[datetime]::UtcNow.ToString('o');success=[bool]$Result.Success;detail=[string]$Result.Detail;address=[string]$Result.Address;hostname=[string]$Result.Hostname}
    $null = Save-RustJsonAtomic -Path $ResultPath -Value $Document
    $Document
}
catch {
    $Document = [pscustomobject][ordered]@{generatedUtc=[datetime]::UtcNow.ToString('o');success=$false;detail=$_.Exception.Message;address='';hostname=''}
    $null = Save-RustJsonAtomic -Path $ResultPath -Value $Document
    Write-Error $_.Exception.Message
    exit 1
}
