[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$ServerRoot,
    [Parameter(Mandatory = $true)][string]$InstanceId,
    [Parameter(Mandatory = $true)][string]$OperationId,
    [switch]$IncludeCarbon
)
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'RustRPG-Common.ps1')
. (Join-Path $PSScriptRoot 'RustRPG-Operations.ps1')
. (Join-Path $PSScriptRoot 'RustRPG-Services.ps1')
try{
    $null=Update-RustTrackedOperation -ServerRoot $ServerRoot -Id $OperationId -Changes @{progress=8.0;stage='PRÉPARATION';detail='Vérification du stockage et de SteamCMD.'}
    $null=Update-RustTrackedOperation -ServerRoot $ServerRoot -Id $OperationId -Changes @{progress=20.0;stage='INSTALLATION RUST';detail='SteamCMD télécharge et vérifie un runtime indépendant. Cette étape peut prendre plusieurs minutes.'}
    $Status=Initialize-RustIsolatedRuntime -ServerRoot $ServerRoot -InstanceId $InstanceId -IncludeCarbon:$IncludeCarbon
    $null=Update-RustTrackedOperation -ServerRoot $ServerRoot -Id $OperationId -Changes @{progress=92.0;stage='VÉRIFICATION';detail="Contrôle de l’exécutable et des dossiers de configuration."}
    $null=Complete-RustTrackedOperation -ServerRoot $ServerRoot -Id $OperationId -Status Succeeded -Stage 'TERMINÉ' -Detail ("Runtime isolé prêt : "+$Status.RuntimeRoot)
}
catch{
    $null=Complete-RustTrackedOperation -ServerRoot $ServerRoot -Id $OperationId -Status Failed -Stage 'ÉCHEC' -Detail $_.Exception.Message
    throw
}
