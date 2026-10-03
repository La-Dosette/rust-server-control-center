[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$ServerRoot,
    [Parameter(Mandatory = $true)][string]$InstanceId,
    [Parameter(Mandatory = $true)][string]$PluginId,
    [Parameter(Mandatory = $true)][string]$OperationId
)
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'RustRPG-Common.ps1')
. (Join-Path $PSScriptRoot 'RustRPG-Operations.ps1')
. (Join-Path $PSScriptRoot 'RustRPG-Services.ps1')
try{
    $null=Update-RustTrackedOperation -ServerRoot $ServerRoot -Id $OperationId -Changes @{progress=10.0;stage='DÉPENDANCES';detail='Résolution de la chaîne de dépendances.'}
    $null=Update-RustTrackedOperation -ServerRoot $ServerRoot -Id $OperationId -Changes @{progress=35.0;stage='TÉLÉCHARGEMENT';detail='Téléchargement HTTPS et vérification du code source.'}
    $Installed=@(Install-RustCatalogPlugin -ServerRoot $ServerRoot -InstanceId $InstanceId -PluginId $PluginId)
    $null=Complete-RustTrackedOperation -ServerRoot $ServerRoot -Id $OperationId -Status Succeeded -Stage 'TERMINÉ' -Detail (("{0} plugin(s) installé(s) : " -f $Installed.Count)+(@($Installed.Plugin)-join', '))
}
catch{
    $null=Complete-RustTrackedOperation -ServerRoot $ServerRoot -Id $OperationId -Status Failed -Stage 'ÉCHEC' -Detail $_.Exception.Message
    throw
}
