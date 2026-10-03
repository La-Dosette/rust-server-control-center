[CmdletBinding()]
param([string]$Root = '')

$ErrorActionPreference = 'Stop'
if(-not$Root){$Root=$PSScriptRoot}
$Root = [IO.Path]::GetFullPath($Root)
$TemplateRoot = Join-Path $Root 'standalone'
$CatalogPath = Join-Path $Root 'instances.json'
$ConfigRoot = Join-Path $Root 'config'

if (-not (Test-Path -LiteralPath $CatalogPath)) {
    $Template = Join-Path $TemplateRoot 'instances.template.json'
    if (-not (Test-Path -LiteralPath $Template)) { throw 'Le modele instances.template.json est introuvable.' }
    Copy-Item -LiteralPath $Template -Destination $CatalogPath
}

New-Item -ItemType Directory -Force -Path $ConfigRoot,(Join-Path $Root 'logs'),(Join-Path $Root 'backups\control-center') | Out-Null
foreach ($Name in @('server.cfg','users.cfg')) {
    $Target = Join-Path $ConfigRoot $Name
    $Template = Join-Path $TemplateRoot ('config\' + $Name)
    if (-not (Test-Path -LiteralPath $Target) -and (Test-Path -LiteralPath $Template)) {
        Copy-Item -LiteralPath $Template -Destination $Target
    }
}

$FriendFile = Join-Path $Root 'CONNEXION-AMIS.txt'
if (-not (Test-Path -LiteralPath $FriendFile)) {
    [IO.File]::WriteAllText($FriendFile,"client.connect VOTRE-IP-PUBLIQUE:28115`r`n",[Text.UTF8Encoding]::new($true))
}
