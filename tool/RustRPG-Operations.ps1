function Assert-RustIdentity {
    param([Parameter(Mandatory = $true)][string]$Identity)
    if ($Identity -notmatch '^[A-Za-z0-9_-]+$') {
        throw "Identite de serveur invalide."
    }
}

function Assert-RustServerStopped {
    param([string]$Identity = '')
    $Processes = @(Get-RustRpgServerProcesses -ServerRoot $ServerRoot)
    if (-not $Processes.Count) { return }
    if (-not $Identity -or @($Processes | Where-Object Identity -eq $Identity).Count) {
        throw "Arrete le serveur avant cette operation."
    }
}

function Write-Utf8File {
    param([string]$Path, [string]$Content)
    [IO.File]::WriteAllText($Path, $Content, [Text.UTF8Encoding]::new($true))
}

function Get-RustInstanceCatalogPath {
    param([Parameter(Mandatory = $true)][string]$ServerRoot)
    return Join-Path $ServerRoot 'instances.json'
}

function Get-RustInstanceCatalog {
    param([Parameter(Mandatory = $true)][string]$ServerRoot)
    $Path = Get-RustInstanceCatalogPath -ServerRoot $ServerRoot
    if (-not (Test-Path -LiteralPath $Path)) { throw 'Le catalogue instances.json est introuvable.' }
    try { $Catalog = Get-Content -LiteralPath $Path -Raw -Encoding utf8 | ConvertFrom-Json }
    catch { throw 'Le catalogue instances.json est invalide : ' + $_.Exception.Message }
    if (-not $Catalog.instances) { throw 'Le catalogue ne contient aucune instance.' }
    return $Catalog
}

function Assert-RustInstanceCatalog {
    param([Parameter(Mandatory = $true)]$Catalog)
    $Ids = @{}
    $Identities = @{}
    $Ports = @{}
    foreach ($Instance in @($Catalog.instances)) {
        $Id = [string]$Instance.id
        $Identity = [string]$Instance.identity
        if ($Id -notmatch '^[a-z0-9][a-z0-9-]{0,31}$') { throw "Identifiant d'instance invalide : $Id" }
        Assert-RustIdentity $Identity
        if ($Ids.ContainsKey($Id)) { throw "Identifiant d'instance duplique : $Id" }
        if ($Identities.ContainsKey($Identity.ToLowerInvariant())) { throw "Identite Rust dupliquee : $Identity" }
        $Ids[$Id] = $true
        $Identities[$Identity.ToLowerInvariant()] = $true
        foreach ($Field in @('serverPort','rconPort','queryPort','appPort')) {
            $Port = [int]$Instance.$Field
            if ($Port -lt 1025 -or $Port -gt 65535) { throw "Port invalide pour $($Instance.displayName) : $Port" }
            if ($Ports.ContainsKey($Port)) { throw "Le port $Port est utilise par plusieurs instances." }
            $Ports[$Port] = "$Id/$Field"
        }
        if ([int]$Instance.worldSize -lt 1000 -or [int]$Instance.worldSize -gt 6000) { throw "Taille de monde invalide pour $($Instance.displayName)." }
        if ([long]$Instance.seed -lt 0 -or [long]$Instance.seed -gt 2147483647) { throw "Seed invalide pour $($Instance.displayName)." }
        if ($Instance.PSObject.Properties.Name -contains 'isolationMode' -and [string]$Instance.isolationMode -notin @('shared','full')) { throw "Mode d'isolation invalide pour $($Instance.displayName)." }
    }
    if (-not $Ids.ContainsKey([string]$Catalog.selectedId)) { throw "L'instance selectionnee n'existe pas." }
}

function Save-RustInstanceCatalog {
    param(
        [Parameter(Mandatory = $true)][string]$ServerRoot,
        [Parameter(Mandatory = $true)]$Catalog,
        [switch]$NoBackup
    )
    Assert-RustInstanceCatalog $Catalog
    $Path = Get-RustInstanceCatalogPath -ServerRoot $ServerRoot
    if (-not $NoBackup -and (Test-Path -LiteralPath $Path)) {
        Copy-Item -LiteralPath $Path -Destination ($Path + '.bak-' + (Get-Date -Format 'yyyyMMdd-HHmmss')) -Force
    }
    Write-Utf8File -Path $Path -Content ($Catalog | ConvertTo-Json -Depth 12)
    return $Path
}

function Get-RustServerInstances {
    param([Parameter(Mandatory = $true)][string]$ServerRoot)
    return @((Get-RustInstanceCatalog -ServerRoot $ServerRoot).instances)
}

function Get-RustServerInstance {
    param(
        [Parameter(Mandatory = $true)][string]$ServerRoot,
        [string]$Id,
        [string]$Identity
    )
    $Catalog = Get-RustInstanceCatalog -ServerRoot $ServerRoot
    if ($Id) { return @($Catalog.instances | Where-Object id -eq $Id) | Select-Object -First 1 }
    if ($Identity) { return @($Catalog.instances | Where-Object identity -eq $Identity) | Select-Object -First 1 }
    return @($Catalog.instances | Where-Object id -eq ([string]$Catalog.selectedId)) | Select-Object -First 1
}

function Set-RustSelectedInstance {
    param([Parameter(Mandatory = $true)][string]$ServerRoot,[Parameter(Mandatory = $true)][string]$Id)
    $Catalog = Get-RustInstanceCatalog -ServerRoot $ServerRoot
    if (-not (@($Catalog.instances | Where-Object id -eq $Id).Count)) { throw "Instance '$Id' introuvable." }
    $Catalog.selectedId = $Id
    $null = Save-RustInstanceCatalog -ServerRoot $ServerRoot -Catalog $Catalog -NoBackup
    return Get-RustServerInstance -ServerRoot $ServerRoot -Id $Id
}

function Set-RustMultiInstanceEnabled {
    param([Parameter(Mandatory = $true)][string]$ServerRoot,[bool]$Enabled)
    $Catalog = Get-RustInstanceCatalog -ServerRoot $ServerRoot
    $Catalog.allowMultiInstance = $Enabled
    $null = Save-RustInstanceCatalog -ServerRoot $ServerRoot -Catalog $Catalog -NoBackup
}

function Set-RustControlCenterLanguage {
    param([Parameter(Mandatory = $true)][string]$ServerRoot,[ValidateSet('fr-FR','en-US')][string]$Language)
    $Catalog = Get-RustInstanceCatalog -ServerRoot $ServerRoot
    $Catalog.language = $Language
    $null = Save-RustInstanceCatalog -ServerRoot $ServerRoot -Catalog $Catalog -NoBackup
}

function Set-RustControlCenterUiMode {
    param([Parameter(Mandatory = $true)][string]$ServerRoot,[ValidateSet('simple','advanced')][string]$Mode)
    $Catalog = Get-RustInstanceCatalog -ServerRoot $ServerRoot
    if ($Catalog.PSObject.Properties.Name -contains 'uiMode') { $Catalog.uiMode = $Mode }
    else { $Catalog | Add-Member -NotePropertyName uiMode -NotePropertyValue $Mode }
    $null = Save-RustInstanceCatalog -ServerRoot $ServerRoot -Catalog $Catalog -NoBackup
}

function Initialize-RustInstanceStorage {
    param([Parameter(Mandatory = $true)][string]$ServerRoot,[Parameter(Mandatory = $true)]$Instance,[string]$CopyFromIdentity = '')
    Assert-RustIdentity ([string]$Instance.identity)
    $RuntimeRoot=if($Instance.PSObject.Properties.Name -contains 'isolationMode' -and [string]$Instance.isolationMode -eq 'full' -and (Get-Command Get-RustInstanceRuntimeRoot -ErrorAction SilentlyContinue)){Get-RustInstanceRuntimeRoot -ServerRoot $ServerRoot -Instance $Instance}else{Join-Path $ServerRoot 'server'}
    $Target = Join-Path $RuntimeRoot ('server\' + [string]$Instance.identity + '\cfg')
    New-Item -ItemType Directory -Force -Path $Target | Out-Null
    $Source = if ($CopyFromIdentity) { Join-Path (Get-RustIdentityStorageContext -ServerRoot $ServerRoot -Identity $CopyFromIdentity).IdentityPath 'cfg' } else { Join-Path $ServerRoot 'config' }
    foreach ($Name in @('server.cfg','users.cfg')) {
        $Destination = Join-Path $Target $Name
        $SourceFile = Join-Path $Source $Name
        if (-not (Test-Path -LiteralPath $Destination) -and (Test-Path -LiteralPath $SourceFile)) {
            Copy-Item -LiteralPath $SourceFile -Destination $Destination -Force
        }
    }
    return $Target
}

function New-RustServerInstance {
    param([Parameter(Mandatory = $true)][string]$ServerRoot,[string]$CopyFromId = '')
    $Catalog = Get-RustInstanceCatalog -ServerRoot $ServerRoot
    $Index = 1
    do {
        $Id = "server-$Index"
        $Identity = "rust-server-$Index"
        $BasePort = 28215 + (($Index - 1) * 100)
        $Index++
    } while (@($Catalog.instances | Where-Object { $_.id -eq $Id -or $_.identity -eq $Identity -or $_.serverPort -eq $BasePort }).Count)

    $Source = if ($CopyFromId) { @($Catalog.instances | Where-Object id -eq $CopyFromId) | Select-Object -First 1 } else { $null }
    if ($CopyFromId -and -not $Source) { throw "Instance source '$CopyFromId' introuvable." }
    $Instance = [pscustomobject][ordered]@{
        id               = $Id
        displayName      = if ($Source) { [string]$Source.displayName + ' - copie' } else { "Nouveau serveur $($Index - 1)" }
        identity         = $Identity
        enabled          = $true
        isPublic         = if ($Source) { [bool]$Source.isPublic } else { $false }
        serverPort       = $BasePort
        rconPort         = $BasePort + 1
        queryPort        = $BasePort + 2
        appPort          = $BasePort + 3
        level            = if ($Source) { [string]$Source.level } else { 'Procedural Map' }
        levelUrl         = if ($Source) { [string]$Source.levelUrl } else { '' }
        seed             = if ($Source) { [long]$Source.seed } else { [long](Get-Random -Minimum 0 -Maximum 2147483647) }
        worldSize        = if ($Source) { [int]$Source.worldSize } else { 2000 }
        memoryEstimateGb = if ($Source) { [int]$Source.memoryEstimateGb } else { 6 }
        isolationMode   = if ($Source -and $Source.PSObject.Properties.Name -contains 'isolationMode') { [string]$Source.isolationMode } else { 'shared' }
        runtimeRoot     = ''
        monitoringEnabled = $true
        autoRestart     = $false
        autoRestartMaxPerHour = 3
        autoRestartCooldownSeconds = 90
        remoteAllowed   = $true
    }
    $Catalog.instances = @($Catalog.instances) + @($Instance)
    $Catalog.selectedId = $Id
    $null = Save-RustInstanceCatalog -ServerRoot $ServerRoot -Catalog $Catalog
    $null = Initialize-RustInstanceStorage -ServerRoot $ServerRoot -Instance $Instance -CopyFromIdentity $(if($Source){[string]$Source.identity}else{''})
    return $Instance
}

function Get-RustAvailablePortSet {
    param(
        [Parameter(Mandatory = $true)][string]$ServerRoot,
        [int]$StartPort = 28115
    )
    $Catalog = Get-RustInstanceCatalog -ServerRoot $ServerRoot
    $Used = New-Object 'Collections.Generic.HashSet[int]'
    foreach ($Instance in @($Catalog.instances)) {
        foreach ($Field in @('serverPort','rconPort','queryPort','appPort')) { $null = $Used.Add([int]$Instance.$Field) }
    }
    try {
        foreach ($Endpoint in @(Get-NetTCPConnection -ErrorAction SilentlyContinue)) { $null = $Used.Add([int]$Endpoint.LocalPort) }
    }
    catch { }
    try {
        foreach ($Endpoint in @(Get-NetUDPEndpoint -ErrorAction SilentlyContinue)) { $null = $Used.Add([int]$Endpoint.LocalPort) }
    }
    catch { }

    $Candidate = [math]::Max(1025,$StartPort)
    while ($Candidate + 3 -le 65535) {
        $Ports = @($Candidate,($Candidate + 1),($Candidate + 2),($Candidate + 3))
        if (-not @($Ports | Where-Object { $Used.Contains([int]$_) }).Count) {
            return [pscustomobject]@{ ServerPort=$Ports[0]; RconPort=$Ports[1]; QueryPort=$Ports[2]; AppPort=$Ports[3] }
        }
        $Candidate += 100
    }
    throw 'Aucun bloc de quatre ports libres disponible.'
}

function Assert-RustNewInstancePorts {
    param(
        [Parameter(Mandatory = $true)][string]$ServerRoot,
        [Parameter(Mandatory = $true)][int[]]$Ports
    )
    if ($Ports.Count -ne 4 -or @($Ports | Select-Object -Unique).Count -ne 4) { throw 'Les quatre ports doivent être différents.' }
    foreach ($Port in $Ports) {
        if ($Port -lt 1025 -or $Port -gt 65535) { throw "Port invalide : $Port. Valeur attendue entre 1025 et 65535." }
    }
    $Catalog = Get-RustInstanceCatalog -ServerRoot $ServerRoot
    $CatalogPorts = @($Catalog.instances | ForEach-Object { [int]$_.serverPort; [int]$_.rconPort; [int]$_.queryPort; [int]$_.appPort })
    $Conflict = @($Ports | Where-Object { $CatalogPorts -contains [int]$_ }) | Select-Object -First 1
    if ($Conflict) { throw "Le port $Conflict est déjà utilisé par une autre instance du catalogue." }
    foreach ($Port in $Ports) {
        $Tcp = Get-NetTCPConnection -LocalPort $Port -ErrorAction SilentlyContinue | Select-Object -First 1
        $Udp = Get-NetUDPEndpoint -LocalPort $Port -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($Tcp -or $Udp) { throw "Le port $Port est déjà occupé sur ce PC." }
    }
}

function New-RustServerInstanceFromProfile {
    param(
        [Parameter(Mandatory = $true)][string]$ServerRoot,
        [Parameter(Mandatory = $true)][string]$DisplayName,
        [Parameter(Mandatory = $true)][string]$Identity,
        [bool]$Enabled = $true,
        [bool]$IsPublic = $false,
        [Parameter(Mandatory = $true)][int]$ServerPort,
        [Parameter(Mandatory = $true)][int]$RconPort,
        [Parameter(Mandatory = $true)][int]$QueryPort,
        [Parameter(Mandatory = $true)][int]$AppPort,
        [ValidateSet('Procedurale','Custom URL')][string]$MapType = 'Procedurale',
        [string]$LevelUrl = '',
        [long]$Seed = 0,
        [int]$WorldSize = 2000,
        [int]$MaxPlayers = 10,
        [int]$SaveInterval = 300,
        [int]$MemoryEstimateGb = 6,
        [bool]$Pve = $false,
        [bool]$Creative = $false,
        [bool]$SelectAfterCreation = $true
    )
    $DisplayName = $DisplayName.Trim()
    $Identity = $Identity.Trim().ToLowerInvariant()
    if (-not $DisplayName -or $DisplayName.Length -gt 80) { throw 'Le nom du serveur doit contenir entre 1 et 80 caractères.' }
    if ($Identity -notmatch '^[a-z0-9][a-z0-9-]{0,31}$') { throw 'Le dossier interne accepte uniquement les lettres minuscules, chiffres et tirets (32 caractères maximum).' }
    if ($Seed -lt 0 -or $Seed -gt 2147483647) { throw 'La seed doit être comprise entre 0 et 2147483647.' }
    if ($WorldSize -lt 1000 -or $WorldSize -gt 6000) { throw 'La taille de carte doit être comprise entre 1000 et 6000 mètres.' }
    if ($MaxPlayers -lt 1 -or $MaxPlayers -gt 500) { throw 'Le nombre de joueurs doit être compris entre 1 et 500.' }
    if ($SaveInterval -lt 30 -or $SaveInterval -gt 3600) { throw 'Intervalle de sauvegarde attendu entre 30 et 3600 secondes.' }
    if ($MemoryEstimateGb -lt 4 -or $MemoryEstimateGb -gt 32) { throw 'Estimation mémoire attendue entre 4 et 32 Go.' }
    if ($MapType -eq 'Custom URL') {
        if (-not $LevelUrl) { throw 'Indique une URL de carte custom.' }
        if ($IsPublic -and $LevelUrl -notmatch '^https?://') { throw 'Une carte custom publique exige une URL HTTP/HTTPS directe.' }
    }
    else { $LevelUrl = '' }

    $CatalogPath = Get-RustInstanceCatalogPath -ServerRoot $ServerRoot
    $OriginalCatalogText = Get-Content -LiteralPath $CatalogPath -Raw -Encoding UTF8
    $Catalog = $OriginalCatalogText | ConvertFrom-Json
    if (@($Catalog.instances | Where-Object { [string]$_.id -eq $Identity -or [string]$_.identity -eq $Identity }).Count) { throw "Le dossier interne '$Identity' existe déjà dans le catalogue." }
    $IdentityPath = Join-Path $ServerRoot ('server\server\' + $Identity)
    if (Test-Path -LiteralPath $IdentityPath) { throw "Le dossier '$IdentityPath' existe déjà. Choisis un autre dossier interne pour protéger les données présentes." }
    $Ports = @($ServerPort,$RconPort,$QueryPort,$AppPort)
    Assert-RustNewInstancePorts -ServerRoot $ServerRoot -Ports $Ports

    $Instance = [pscustomobject][ordered]@{
        id               = $Identity
        displayName      = $DisplayName
        identity         = $Identity
        enabled          = $Enabled
        isPublic         = $IsPublic
        serverPort       = $ServerPort
        rconPort         = $RconPort
        queryPort        = $QueryPort
        appPort          = $AppPort
        level            = 'Procedural Map'
        levelUrl         = $LevelUrl
        seed             = $Seed
        worldSize        = $WorldSize
        memoryEstimateGb = $MemoryEstimateGb
        isolationMode   = 'shared'
        runtimeRoot     = ''
        monitoringEnabled = $true
        autoRestart     = $false
        autoRestartMaxPerHour = 3
        autoRestartCooldownSeconds = 90
        remoteAllowed   = $true
    }
    $Catalog.instances = @($Catalog.instances) + @($Instance)
    if ($SelectAfterCreation) { $Catalog.selectedId = $Identity }

    $CatalogWritten = $false
    try {
        $null = Save-RustInstanceCatalog -ServerRoot $ServerRoot -Catalog $Catalog
        $CatalogWritten = $true
        $null = Initialize-RustInstanceStorage -ServerRoot $ServerRoot -Instance $Instance
        $ConfigValues = @{
            'server.hostname'      = $DisplayName
            'server.description'   = 'Serveur créé avec Rust Server Control Center'
            'server.maxplayers'    = $MaxPlayers
            'server.saveinterval'  = $SaveInterval
            'server.pve'           = $Pve.ToString().ToLowerInvariant()
            'server.radiation'     = 'true'
            'server.globalchat'    = 'true'
            'creative.allusers'    = $Creative.ToString().ToLowerInvariant()
        }
        $ConfigOrder = @('server.hostname','server.description','server.maxplayers','server.saveinterval','server.pve','server.radiation','server.globalchat','creative.allusers')
        $StringKeys = @('server.hostname','server.description')
        $Lines = foreach ($Key in $ConfigOrder) {
            $Value = [string]$ConfigValues[$Key]
            if ($StringKeys -contains $Key) { $Value = '"' + $Value.Replace('"',"'") + '"' }
            "$Key $Value"
        }
        $ConfigPath = Join-Path $IdentityPath 'cfg\server.cfg'
        Write-Utf8File -Path $ConfigPath -Content (($Lines -join [Environment]::NewLine) + [Environment]::NewLine)
        return $Instance
    }
    catch {
        if ($CatalogWritten) { Write-Utf8File -Path $CatalogPath -Content $OriginalCatalogText }
        if (Test-Path -LiteralPath $IdentityPath) {
            $SafeParent = [IO.Path]::GetFullPath((Join-Path $ServerRoot 'server\server')).TrimEnd([IO.Path]::DirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
            $ResolvedTarget = [IO.Path]::GetFullPath($IdentityPath)
            if ($ResolvedTarget.StartsWith($SafeParent,[StringComparison]::OrdinalIgnoreCase)) { Remove-Item -LiteralPath $ResolvedTarget -Recurse -Force }
        }
        throw
    }
}

function Remove-RustServerInstance {
    param([Parameter(Mandatory = $true)][string]$ServerRoot,[Parameter(Mandatory = $true)][string]$Id)
    $Catalog = Get-RustInstanceCatalog -ServerRoot $ServerRoot
    if (@($Catalog.instances).Count -le 1) { throw 'Il faut conserver au moins une instance.' }
    $Instance = @($Catalog.instances | Where-Object id -eq $Id) | Select-Object -First 1
    if (-not $Instance) { throw "Instance '$Id' introuvable." }
    $CommandPattern = '\+server\.identity\s+"?' + [regex]::Escape([string]$Instance.identity) + '(?:"|\s|$)'
    if (@(Get-CimInstance Win32_Process -Filter "Name = 'RustDedicated.exe'" -ErrorAction SilentlyContinue | Where-Object CommandLine -Match $CommandPattern).Count) {
        throw 'Arrete cette instance avant de la retirer.'
    }
    $Catalog.instances = @($Catalog.instances | Where-Object id -ne $Id)
    if ([string]$Catalog.selectedId -eq $Id) { $Catalog.selectedId = [string]$Catalog.instances[0].id }
    $null = Save-RustInstanceCatalog -ServerRoot $ServerRoot -Catalog $Catalog
    return [string]$Instance.identity
}

function Get-RustMapProfile {
    param(
        [Parameter(Mandatory = $true)][string]$ServerRoot,
        [Parameter(Mandatory = $true)][string]$Identity
    )
    $Settings = Get-RustServerInstance -ServerRoot $ServerRoot -Identity $Identity
    if (-not $Settings) { throw "Instance Rust '$Identity' introuvable." }
    $LevelUrl = [string]$Settings.levelUrl
    return [pscustomobject]@{
        Identity    = $Identity
        Id           = [string]$Settings.id
        DisplayName = [string]$Settings.displayName
        Type         = if ($LevelUrl) { 'Custom URL' } else { 'Procedurale' }
        Level        = [string]$Settings.level
        LevelUrl     = $LevelUrl
        Seed         = [int64]$Settings.seed
        WorldSize    = [int]$Settings.worldSize
    }
}

function Set-RustMapProfile {
    param(
        [Parameter(Mandatory = $true)][string]$ServerRoot,
        [Parameter(Mandatory = $true)][string]$Identity,
        [Parameter(Mandatory = $true)][ValidateSet('Procedurale','Custom URL')][string]$Type,
        [Parameter(Mandatory = $true)][long]$Seed,
        [Parameter(Mandatory = $true)][int]$WorldSize,
        [string]$LevelUrl = ''
    )

    Assert-RustServerStopped
    if ($Seed -lt 0 -or $Seed -gt 2147483647) { throw "La seed doit etre comprise entre 0 et 2147483647." }
    if ($WorldSize -lt 1000 -or $WorldSize -gt 6000) { throw "La taille doit etre comprise entre 1000 et 6000." }
    if ($Type -eq 'Custom URL') {
        if (-not $LevelUrl) { throw "Indique une URL de carte custom." }
        $TargetInstance = Get-RustServerInstance -ServerRoot $ServerRoot -Identity $Identity
        if (-not $TargetInstance) { throw "Instance Rust '$Identity' introuvable." }
        if ([bool]$TargetInstance.isPublic -and $LevelUrl -notmatch '^https?://') {
            throw "Le serveur amis exige une URL HTTP/HTTPS publique directe."
        }
    }
    else {
        $LevelUrl = ''
    }

    $Catalog = Get-RustInstanceCatalog -ServerRoot $ServerRoot
    $TargetInstance = @($Catalog.instances | Where-Object identity -eq $Identity) | Select-Object -First 1
    $TargetInstance.level = 'Procedural Map'
    $TargetInstance.levelUrl = $LevelUrl
    $TargetInstance.seed = $Seed
    $TargetInstance.worldSize = $WorldSize
    $null = Save-RustInstanceCatalog -ServerRoot $ServerRoot -Catalog $Catalog
    return Get-RustMapProfile -ServerRoot $ServerRoot -Identity $Identity
}

function Get-RustMapLibraryStorePath {
    param([Parameter(Mandatory = $true)][string]$ServerRoot)
    return Join-Path $ServerRoot 'data\maps\library.json'
}

function Get-RustMapLibrary {
    param([Parameter(Mandatory = $true)][string]$ServerRoot)
    $Path = Get-RustMapLibraryStorePath -ServerRoot $ServerRoot
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return [pscustomobject][ordered]@{schemaVersion=1;maps=@()} }
    try { $Store = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json }
    catch { throw 'La bibliothèque de cartes est invalide : ' + $_.Exception.Message }
    if ([int]$Store.schemaVersion -ne 1) { throw 'Version de bibliothèque de cartes non prise en charge.' }
    return $Store
}

function Save-RustMapLibrary {
    param([Parameter(Mandatory = $true)][string]$ServerRoot,[Parameter(Mandatory = $true)]$Store)
    $Path = Get-RustMapLibraryStorePath -ServerRoot $ServerRoot
    [IO.Directory]::CreateDirectory((Split-Path $Path -Parent)) | Out-Null
    $Temporary = $Path + '.tmp-' + [guid]::NewGuid().ToString('N')
    try {
        [IO.File]::WriteAllText($Temporary,($Store | ConvertTo-Json -Depth 8),[Text.UTF8Encoding]::new($false))
        Move-Item -LiteralPath $Temporary -Destination $Path -Force
    }
    finally { if (Test-Path -LiteralPath $Temporary -PathType Leaf) { Remove-Item -LiteralPath $Temporary -Force } }
    return $Path
}

function Import-RustEditMap {
    param([Parameter(Mandatory = $true)][string]$ServerRoot,[Parameter(Mandatory = $true)][string]$SourcePath)
    $Source = Get-Item -LiteralPath $SourcePath -ErrorAction Stop
    if ($Source.Extension.ToLowerInvariant() -ne '.map') { throw 'Choisis une carte RustEdit au format .map.' }
    if ([long]$Source.Length -le 0 -or [long]$Source.Length -gt 4GB) { throw 'La carte est vide ou dépasse la limite de sécurité de 4 Go.' }
    $Hash = (Get-FileHash -LiteralPath $Source.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
    $Store = Get-RustMapLibrary -ServerRoot $ServerRoot
    $Existing = @($Store.maps | Where-Object sha256 -eq $Hash) | Select-Object -First 1
    if ($Existing) { return $Existing }
    $LibraryRoot = Join-Path $ServerRoot 'data\maps\library'
    [IO.Directory]::CreateDirectory($LibraryRoot) | Out-Null
    $SafeBase = ([regex]::Replace($Source.BaseName,'[^A-Za-z0-9._-]','-')).Trim('-','.')
    if (-not $SafeBase) { $SafeBase = 'rustedit-map' }
    $TargetName = '{0}-{1}.map' -f $SafeBase,$Hash.Substring(0,8)
    $Target = Join-Path $LibraryRoot $TargetName
    Copy-Item -LiteralPath $Source.FullName -Destination $Target -Force
    if ((Get-FileHash -LiteralPath $Target -Algorithm SHA256).Hash.ToLowerInvariant() -ne $Hash) { throw 'La copie de la carte ne correspond pas au fichier source.' }
    $Entry = [pscustomobject][ordered]@{id=[guid]::NewGuid().ToString('N');name=$Source.Name;fileName=$TargetName;path=$Target;sizeBytes=[long]$Source.Length;sha256=$Hash;publicUrl='';importedUtc=[datetime]::UtcNow.ToString('o')}
    $Store.maps = @($Store.maps) + @($Entry)
    $null = Save-RustMapLibrary -ServerRoot $ServerRoot -Store $Store
    return $Entry
}

function Set-RustEditMapPublicUrl {
    param([Parameter(Mandatory = $true)][string]$ServerRoot,[Parameter(Mandatory = $true)][string]$MapId,[string]$PublicUrl='')
    $Store = Get-RustMapLibrary -ServerRoot $ServerRoot
    $Entry = @($Store.maps | Where-Object id -eq $MapId) | Select-Object -First 1
    if (-not $Entry) { throw 'Carte importée introuvable.' }
    if ($PublicUrl) {
        $Uri = $null
        if (-not [Uri]::TryCreate($PublicUrl,[UriKind]::Absolute,[ref]$Uri) -or $Uri.Scheme -notin @('http','https')) { throw 'Utilise une URL publique directe HTTP ou HTTPS.' }
    }
    $Entry.publicUrl = $PublicUrl.Trim()
    $null = Save-RustMapLibrary -ServerRoot $ServerRoot -Store $Store
    return $Entry
}

function Set-RustInstanceImportedMap {
    param([Parameter(Mandatory = $true)][string]$ServerRoot,[Parameter(Mandatory = $true)][string]$Identity,[Parameter(Mandatory = $true)][string]$MapId)
    $Store = Get-RustMapLibrary -ServerRoot $ServerRoot
    $Entry = @($Store.maps | Where-Object id -eq $MapId) | Select-Object -First 1
    if (-not $Entry -or -not (Test-Path -LiteralPath ([string]$Entry.path) -PathType Leaf)) { throw 'Le fichier de carte importé est introuvable.' }
    if ((Get-FileHash -LiteralPath ([string]$Entry.path) -Algorithm SHA256).Hash.ToLowerInvariant() -ne ([string]$Entry.sha256).ToLowerInvariant()) { throw 'La carte importée a été modifiée depuis son ajout.' }
    $Instance = Get-RustServerInstance -ServerRoot $ServerRoot -Identity $Identity
    if (-not $Instance) { throw 'Serveur cible introuvable.' }
    $LevelUrl = if ([bool]$Instance.isPublic) {
        if ([string]$Entry.publicUrl -notmatch '^https?://') { throw "Ce serveur est public : renseigne d’abord une URL directe accessible aux joueurs." }
        [string]$Entry.publicUrl
    } else { [Uri]::new([string]$Entry.path).AbsoluteUri }
    return Set-RustMapProfile -ServerRoot $ServerRoot -Identity $Identity -Type 'Custom URL' -Seed ([long]$Instance.seed) -WorldSize ([int]$Instance.worldSize) -LevelUrl $LevelUrl
}

function Get-RustDirectoryStatistics {
    param([Parameter(Mandatory = $true)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Container)) { return [pscustomobject]@{ FileCount=0; Bytes=0L } }
    $Files = @(Get-ChildItem -LiteralPath $Path -File -Recurse -Force -ErrorAction Stop)
    $Bytes = 0L
    foreach ($File in $Files) { $Bytes += [long]$File.Length }
    return [pscustomobject]@{ FileCount=$Files.Count; Bytes=$Bytes }
}

function Format-RustByteSize {
    param([long]$Bytes)
    if ($Bytes -ge 1TB) { return ('{0:N2} To' -f ($Bytes / 1TB)) }
    if ($Bytes -ge 1GB) { return ('{0:N2} Go' -f ($Bytes / 1GB)) }
    if ($Bytes -ge 1MB) { return ('{0:N1} Mo' -f ($Bytes / 1MB)) }
    if ($Bytes -ge 1KB) { return ('{0:N1} Ko' -f ($Bytes / 1KB)) }
    return "$Bytes o"
}

function Get-RustRuntimeModContext {
    param([Parameter(Mandatory = $true)][string]$RuntimeRoot)
    $CarbonRoot = Join-Path $RuntimeRoot 'carbon'
    $OxideRoot = Join-Path $RuntimeRoot 'oxide'
    $CarbonInstalled = (Test-Path -LiteralPath (Join-Path $CarbonRoot 'managed\Carbon.Common.dll') -PathType Leaf) -or (Test-Path -LiteralPath (Join-Path $CarbonRoot 'config.json') -PathType Leaf)
    $OxideInstalled = (Test-Path -LiteralPath (Join-Path $RuntimeRoot 'RustDedicated_Data\Managed\Oxide.Rust.dll') -PathType Leaf) -or (Test-Path -LiteralPath (Join-Path $OxideRoot 'plugins') -PathType Container)
    $Framework = if ($CarbonInstalled) { 'carbon' } elseif ($OxideInstalled) { 'oxide' } else { 'vanilla' }
    $PluginRoot = if ($Framework -eq 'oxide') { $OxideRoot } else { $CarbonRoot }
    return [pscustomobject]@{
        Framework=$Framework; Installed=($Framework -ne 'vanilla'); PluginRoot=$PluginRoot
        ConfigRoot=Join-Path $PluginRoot $(if($Framework -eq 'oxide'){'config'}else{'configs'})
        DataRoot=Join-Path $PluginRoot 'data'; LogsRoot=Join-Path $PluginRoot 'logs'
        ConsolePrefix=if($Framework -eq 'oxide'){'oxide'}else{'c'}
    }
}

function Get-RustIdentityStorageContext {
    param([Parameter(Mandatory = $true)][string]$ServerRoot,[Parameter(Mandatory = $true)][string]$Identity)
    $Instance=Get-RustServerInstance -ServerRoot $ServerRoot -Identity $Identity
    $RuntimeRoot=if($Instance -and (Get-Command Get-RustInstanceRuntimeRoot -ErrorAction SilentlyContinue)){Get-RustInstanceRuntimeRoot -ServerRoot $ServerRoot -Instance $Instance}else{Join-Path $ServerRoot 'server'}
    $Mod=Get-RustRuntimeModContext -RuntimeRoot $RuntimeRoot
    return [pscustomobject]@{Instance=$Instance;RuntimeRoot=$RuntimeRoot;IdentityRoot=Join-Path $RuntimeRoot 'server';IdentityPath=Join-Path $RuntimeRoot ('server\'+$Identity);Framework=$Mod.Framework;PluginRoot=$Mod.PluginRoot;CarbonRoot=$Mod.PluginRoot;ConfigRoot=$Mod.ConfigRoot;DataRoot=$Mod.DataRoot;LogsRoot=$Mod.LogsRoot;ConsolePrefix=$Mod.ConsolePrefix}
}

function Get-RustBackupPreflight {
    param(
        [Parameter(Mandatory = $true)][string]$ServerRoot,
        [Parameter(Mandatory = $true)][string]$Identity
    )
    Assert-RustIdentity $Identity
    $Context=Get-RustIdentityStorageContext -ServerRoot $ServerRoot -Identity $Identity
    $IdentityPath = $Context.IdentityPath
    if (-not (Test-Path -LiteralPath $IdentityPath -PathType Container)) { throw "Sauvegarde $Identity introuvable." }
    $SourceBytes = (Get-RustDirectoryStatistics -Path $IdentityPath).Bytes
    foreach ($Relative in @('data','configs','plugins','disabled-plugins')) {
        $Source = Join-Path $Context.CarbonRoot $Relative
        if (Test-Path -LiteralPath $Source -PathType Container) { $SourceBytes += (Get-RustDirectoryStatistics -Path $Source).Bytes }
    }
    $BackupRoot = Join-Path $ServerRoot 'backups\control-center'
    $RootPath = [IO.Path]::GetPathRoot([IO.Path]::GetFullPath($BackupRoot))
    $DriveInfo = [IO.DriveInfo]::new($RootPath)
    # La copie temporaire et l'archive coexistent pendant quelques secondes.
    # On garde en plus 512 Mo de marge pour le manifeste et les ecritures Rust.
    $RequiredBytes = [long][math]::Max(512MB,[math]::Ceiling($SourceBytes * 2.2))
    return [pscustomobject]@{
        Identity      = $Identity
        SourceBytes   = [long]$SourceBytes
        RequiredBytes = $RequiredBytes
        FreeBytes     = [long]$DriveInfo.AvailableFreeSpace
        EnoughSpace   = [long]$DriveInfo.AvailableFreeSpace -ge $RequiredBytes
        Drive         = $DriveInfo.Name
    }
}

function New-RustBackupManifest {
    param([Parameter(Mandatory = $true)][string]$BackupDirectory)
    $Root = [IO.Path]::GetFullPath($BackupDirectory)
    $Files = @(Get-ChildItem -LiteralPath $Root -File -Recurse -Force | Where-Object Name -ne 'manifest.json' | Sort-Object FullName)
    $Rows = foreach ($File in $Files) {
        $Relative = $File.FullName.Substring($Root.Length).TrimStart('\','/') -replace '\\','/'
        [ordered]@{ path=$Relative; length=[long]$File.Length; sha256=(Get-FileHash -LiteralPath $File.FullName -Algorithm SHA256).Hash.ToLowerInvariant() }
    }
    $Manifest = [ordered]@{
        schemaVersion = 1
        algorithm     = 'SHA256'
        createdUtc    = [datetime]::UtcNow.ToString('o')
        fileCount     = $Rows.Count
        files         = @($Rows)
    }
    Write-Utf8File -Path (Join-Path $Root 'manifest.json') -Content ($Manifest | ConvertTo-Json -Depth 8)
    return $Manifest
}

function Test-RustBackupDirectoryIntegrity {
    param([Parameter(Mandatory = $true)][string]$BackupDirectory)
    $Root = [IO.Path]::GetFullPath($BackupDirectory)
    $MetadataPath = Join-Path $Root 'metadata.json'
    $IdentityPath = Join-Path $Root 'identity'
    if (-not (Test-Path -LiteralPath $MetadataPath -PathType Leaf) -or -not (Test-Path -LiteralPath $IdentityPath -PathType Container)) {
        return [pscustomobject]@{ Valid=$false; Integrity='INVALID'; Detail='metadata.json ou dossier identity absent.'; CheckedFiles=0 }
    }
    $ManifestPath = Join-Path $Root 'manifest.json'
    if (-not (Test-Path -LiteralPath $ManifestPath -PathType Leaf)) {
        return [pscustomobject]@{ Valid=$true; Integrity='LEGACY'; Detail='Ancienne sauvegarde : structure valide, sans manifeste SHA256.'; CheckedFiles=0 }
    }
    try { $Manifest = Get-Content -LiteralPath $ManifestPath -Raw -Encoding UTF8 | ConvertFrom-Json }
    catch { return [pscustomobject]@{ Valid=$false; Integrity='INVALID'; Detail='Manifeste JSON illisible.'; CheckedFiles=0 } }
    $Checked = 0
    foreach ($Entry in @($Manifest.files)) {
        $Relative = ([string]$Entry.path) -replace '/','\'
        $Candidate = [IO.Path]::GetFullPath((Join-Path $Root $Relative))
        if (-not $Candidate.StartsWith($Root + [IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase)) {
            return [pscustomobject]@{ Valid=$false; Integrity='INVALID'; Detail="Chemin hors sauvegarde : $Relative"; CheckedFiles=$Checked }
        }
        if (-not (Test-Path -LiteralPath $Candidate -PathType Leaf)) { return [pscustomobject]@{ Valid=$false; Integrity='INVALID'; Detail="Fichier absent : $Relative"; CheckedFiles=$Checked } }
        $File = Get-Item -LiteralPath $Candidate
        if ([long]$File.Length -ne [long]$Entry.length) { return [pscustomobject]@{ Valid=$false; Integrity='INVALID'; Detail="Taille incorrecte : $Relative"; CheckedFiles=$Checked } }
        $Hash = (Get-FileHash -LiteralPath $Candidate -Algorithm SHA256).Hash
        if ($Hash -ne [string]$Entry.sha256) { return [pscustomobject]@{ Valid=$false; Integrity='INVALID'; Detail="Somme SHA256 incorrecte : $Relative"; CheckedFiles=$Checked } }
        $Checked++
    }
    return [pscustomobject]@{ Valid=$true; Integrity='VERIFIED'; Detail="$Checked fichier(s) verifies par SHA256."; CheckedFiles=$Checked }
}

function Get-RustBackupZipTextEntry {
    param([Parameter(Mandatory = $true)]$Archive,[Parameter(Mandatory = $true)][string]$Name)
    $Entry = $Archive.GetEntry($Name)
    if (-not $Entry) { return '' }
    $Stream = $Entry.Open()
    $Reader = New-Object IO.StreamReader($Stream,[Text.Encoding]::UTF8,$true)
    try { return $Reader.ReadToEnd() } finally { $Reader.Dispose(); $Stream.Dispose() }
}

function Test-RustBackupZipIntegrity {
    param([Parameter(Mandatory = $true)][string]$BackupPath)
    Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction SilentlyContinue
    try { $Archive = [IO.Compression.ZipFile]::OpenRead($BackupPath) }
    catch { return [pscustomobject]@{ Valid=$false; Integrity='INVALID'; Detail='Archive ZIP illisible : ' + $_.Exception.Message; CheckedFiles=0 } }
    try {
        $MetadataText = Get-RustBackupZipTextEntry -Archive $Archive -Name 'metadata.json'
        # ZipArchive conserve parfois les separateurs Windows (\) selon la
        # version de .NET utilisee par Windows PowerShell. Normaliser avant le
        # controle evite de rejeter une archive pourtant valide.
        $IdentityEntries = @($Archive.Entries | Where-Object {
            $NormalizedName = $_.FullName.Replace('\','/')
            $NormalizedName.StartsWith('identity/',[StringComparison]::OrdinalIgnoreCase) -and [bool]$_.Name
        })
        if (-not $MetadataText -or -not $IdentityEntries.Count) {
            return [pscustomobject]@{ Valid=$false; Integrity='INVALID'; Detail='metadata.json ou monde absent de l archive.'; CheckedFiles=0 }
        }
        $ManifestText = Get-RustBackupZipTextEntry -Archive $Archive -Name 'manifest.json'
        if (-not $ManifestText) { return [pscustomobject]@{ Valid=$true; Integrity='LEGACY'; Detail='Archive ancienne sans manifeste SHA256.'; CheckedFiles=0 } }
        try { $Manifest = $ManifestText | ConvertFrom-Json }
        catch { return [pscustomobject]@{ Valid=$false; Integrity='INVALID'; Detail='Manifeste ZIP illisible.'; CheckedFiles=0 } }
        $Entries = @{}
        foreach ($ZipEntry in $Archive.Entries) {
            $EntryName = $ZipEntry.FullName.Replace('\','/')
            if ($EntryName.StartsWith('/') -or $EntryName -match '(^|/)\.\.(/|$)' -or $EntryName -match '^[A-Za-z]:') {
                return [pscustomobject]@{ Valid=$false; Integrity='INVALID'; Detail="Chemin dangereux dans l archive : $EntryName"; CheckedFiles=0 }
            }
            $Entries[$EntryName] = $ZipEntry
        }
        $Checked = 0
        foreach ($Expected in @($Manifest.files)) {
            $Name = ([string]$Expected.path).Replace('\','/')
            if (-not $Entries.ContainsKey($Name)) { return [pscustomobject]@{ Valid=$false; Integrity='INVALID'; Detail="Fichier absent de l archive : $Name"; CheckedFiles=$Checked } }
            $ZipEntry = $Entries[$Name]
            if ([long]$ZipEntry.Length -ne [long]$Expected.length) { return [pscustomobject]@{ Valid=$false; Integrity='INVALID'; Detail="Taille incorrecte dans l archive : $Name"; CheckedFiles=$Checked } }
            $Stream = $ZipEntry.Open()
            $Sha = [Security.Cryptography.SHA256]::Create()
            try { $Hash = ([BitConverter]::ToString($Sha.ComputeHash($Stream))).Replace('-','').ToLowerInvariant() }
            finally { $Sha.Dispose(); $Stream.Dispose() }
            if ($Hash -ne ([string]$Expected.sha256).ToLowerInvariant()) { return [pscustomobject]@{ Valid=$false; Integrity='INVALID'; Detail="SHA256 incorrect dans l archive : $Name"; CheckedFiles=$Checked } }
            $Checked++
        }
        return [pscustomobject]@{ Valid=$true; Integrity='VERIFIED'; Detail="$Checked fichier(s) verifies dans l archive."; CheckedFiles=$Checked }
    }
    finally { $Archive.Dispose() }
}

function Test-RustServerBackup {
    param(
        [Parameter(Mandatory = $true)][string]$ServerRoot,
        [Parameter(Mandatory = $true)][string]$BackupPath
    )
    $BackupRoot = [IO.Path]::GetFullPath((Join-Path $ServerRoot 'backups\control-center'))
    $Resolved = [IO.Path]::GetFullPath($BackupPath)
    if (-not $Resolved.StartsWith($BackupRoot + [IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase)) {
        return [pscustomobject]@{ Valid=$false; Integrity='INVALID'; Detail='Sauvegarde hors du dossier autorise.'; CheckedFiles=0 }
    }
    if (Test-Path -LiteralPath $Resolved -PathType Container) { return Test-RustBackupDirectoryIntegrity -BackupDirectory $Resolved }
    if ((Test-Path -LiteralPath $Resolved -PathType Leaf) -and [IO.Path]::GetExtension($Resolved) -eq '.zip') { return Test-RustBackupZipIntegrity -BackupPath $Resolved }
    return [pscustomobject]@{ Valid=$false; Integrity='INVALID'; Detail='Sauvegarde introuvable ou format non pris en charge.'; CheckedFiles=0 }
}

function Get-RustBackupMetadata {
    param([Parameter(Mandatory = $true)][string]$BackupPath)
    if (Test-Path -LiteralPath $BackupPath -PathType Container) {
        $Path = Join-Path $BackupPath 'metadata.json'
        if (Test-Path -LiteralPath $Path) { try { return Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json } catch {} }
        return $null
    }
    if ([IO.Path]::GetExtension($BackupPath) -eq '.zip') {
        Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction SilentlyContinue
        try {
            $Archive = [IO.Compression.ZipFile]::OpenRead($BackupPath)
            try { $Text = Get-RustBackupZipTextEntry -Archive $Archive -Name 'metadata.json'; if ($Text) { return $Text | ConvertFrom-Json } }
            finally { $Archive.Dispose() }
        }
        catch {}
    }
    return $null
}

function New-RustServerBackup {
    param(
        [Parameter(Mandatory = $true)][string]$ServerRoot,
        [Parameter(Mandatory = $true)][string]$Identity,
        [string]$Kind = 'manual',
        # Reserve aux sauvegardes automatiques : l'appelant est alors tenu
        # d'avoir envoye 'server.save' et attendu l'ecriture. Le defaut reste
        # le refus, pour qu'une sauvegarde manuelle ne copie jamais un monde
        # en cours d'ecriture.
        [switch]$AllowRunning
    )

    Assert-RustIdentity $Identity
    if (-not $AllowRunning) { Assert-RustServerStopped }
    $Preflight = Get-RustBackupPreflight -ServerRoot $ServerRoot -Identity $Identity
    if (-not $Preflight.EnoughSpace) {
        throw ("Espace disque insuffisant : {0} libres, {1} requis pour une sauvegarde sure." -f (Format-RustByteSize $Preflight.FreeBytes),(Format-RustByteSize $Preflight.RequiredBytes))
    }
    $Context=Get-RustIdentityStorageContext -ServerRoot $ServerRoot -Identity $Identity
    $IdentityPath = $Context.IdentityPath

    $BackupRoot = Join-Path $ServerRoot 'backups\control-center'
    New-Item -ItemType Directory -Force -Path $BackupRoot | Out-Null
    $Stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $SafeKind = ($Kind -replace '[^A-Za-z0-9_-]','-').Trim('-')
    if (-not $SafeKind) { $SafeKind = 'manual' }
    $BaseName = "${Stamp}_${Identity}_${SafeKind}"
    $FinalPath = Join-Path $BackupRoot ($BaseName + '.zip')
    if (Test-Path -LiteralPath $FinalPath) { $FinalPath = Join-Path $BackupRoot ($BaseName + '-' + [guid]::NewGuid().ToString('N').Substring(0,6) + '.zip') }
    $StagingPath = Join-Path $BackupRoot ('.partial-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $StagingPath | Out-Null
    try {
        Copy-Item -LiteralPath $IdentityPath -Destination (Join-Path $StagingPath 'identity') -Recurse -Force
        foreach ($Relative in @('data','configs','plugins','disabled-plugins')) {
            $SourcePath = Join-Path $Context.CarbonRoot $Relative
            if (Test-Path -LiteralPath $SourcePath) {
                $Name = Split-Path $Relative -Leaf
                $ParentName = if ($Name -eq 'plugins') { 'carbon-plugins' } elseif ($Name -eq 'disabled-plugins') { 'carbon-disabled-plugins' } else { 'carbon-' + $Name }
                Copy-Item -LiteralPath $SourcePath -Destination (Join-Path $StagingPath $ParentName) -Recurse -Force
            }
        }
        $RootFiles = Join-Path $StagingPath 'root-config'
        New-Item -ItemType Directory -Path $RootFiles | Out-Null
        foreach ($Name in @('Settings.ps1','Settings-Online.ps1','config\server.cfg','config\users.cfg','instances.json')) {
            $SourcePath = Join-Path $ServerRoot $Name
            if (Test-Path -LiteralPath $SourcePath) { Copy-Item -LiteralPath $SourcePath -Destination (Join-Path $RootFiles (Split-Path $Name -Leaf)) -Force }
        }
        $Stats = Get-RustDirectoryStatistics -Path $StagingPath
        $Metadata = [ordered]@{
            SchemaVersion     = 2
            Identity          = $Identity
            Kind              = $SafeKind
            CreatedUtc        = [datetime]::UtcNow.ToString('o')
            Tool              = 'Rust Server Control Center v12.1.0'
            RuntimeMode       = if($Context.Instance -and $Context.Instance.PSObject.Properties.Name -contains 'isolationMode'){[string]$Context.Instance.isolationMode}else{'shared'}
            Format            = 'zip+sha256'
            SourceBytes       = [long]$Preflight.SourceBytes
            UncompressedBytes = [long]$Stats.Bytes
            DataFileCount     = [int]$Stats.FileCount
            VerifiedAtUtc     = [datetime]::UtcNow.ToString('o')
        } | ConvertTo-Json
        Write-Utf8File -Path (Join-Path $StagingPath 'metadata.json') -Content $Metadata
        $null = New-RustBackupManifest -BackupDirectory $StagingPath
        $StagingCheck = Test-RustBackupDirectoryIntegrity -BackupDirectory $StagingPath
        if (-not $StagingCheck.Valid) { throw 'Verification avant compression impossible : ' + $StagingCheck.Detail }
        Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction Stop
        [IO.Compression.ZipFile]::CreateFromDirectory($StagingPath,$FinalPath,[IO.Compression.CompressionLevel]::Optimal,$false)
        $ArchiveCheck = Test-RustBackupZipIntegrity -BackupPath $FinalPath
        if (-not $ArchiveCheck.Valid) { throw 'Archive creee mais invalide : ' + $ArchiveCheck.Detail }
        return $FinalPath
    }
    catch {
        if (Test-Path -LiteralPath $FinalPath) { [IO.File]::Delete($FinalPath) }
        throw
    }
    finally {
        if (Test-Path -LiteralPath $StagingPath) { [IO.Directory]::Delete($StagingPath,$true) }
    }
}

function Get-RustServerBackups {
    param([Parameter(Mandatory = $true)][string]$ServerRoot)
    $Root = Join-Path $ServerRoot 'backups\control-center'
    if (-not (Test-Path -LiteralPath $Root)) { return @() }
    $Items = @()
    $Items += @(Get-ChildItem -LiteralPath $Root -Directory | Where-Object Name -notlike '.partial-*')
    $Items += @(Get-ChildItem -LiteralPath $Root -File -Filter '*.zip')
    return @($Items | Sort-Object LastWriteTime -Descending | ForEach-Object {
        $Meta = Get-RustBackupMetadata -BackupPath $_.FullName
        $Identity = if($Meta){[string]$Meta.Identity}else{''}
        $Kind = if($Meta){[string]$Meta.Kind}else{''}
        $CreatedUtc = if($Meta -and $Meta.CreatedUtc){[string]$Meta.CreatedUtc}else{$_.LastWriteTimeUtc.ToString('o')}
        $Size = if($_.PSIsContainer){(Get-RustDirectoryStatistics -Path $_.FullName).Bytes}else{[long]$_.Length}
        $Integrity = if(-not $Meta){'INCONNUE'}elseif($Meta.PSObject.Properties.Name -contains 'VerifiedAtUtc' -and [string]$Meta.VerifiedAtUtc){'SHA256'}else{'LEGACY'}
        [pscustomobject]@{
            Name       = $_.Name
            Identity   = $Identity
            Type       = $Kind
            Date       = $_.LastWriteTime.ToString('dd/MM/yyyy HH:mm:ss')
            CreatedUtc = $CreatedUtc
            SizeBytes  = [long]$Size
            Size       = Format-RustByteSize $Size
            Integrity  = $Integrity
            Format     = if($_.PSIsContainer){'Dossier'}else{'ZIP'}
            Path       = $_.FullName
        }
    })
}

function Remove-RustOldBackups {
    param(
        [Parameter(Mandatory = $true)][string]$ServerRoot,
        [Parameter(Mandatory = $true)][string]$Identity,
        [ValidateRange(2,100)][int]$Keep = 10,
        [string[]]$Kinds = @('scheduled')
    )
    $Root = [IO.Path]::GetFullPath((Join-Path $ServerRoot 'backups\control-center'))
    $Candidates = @(Get-RustServerBackups -ServerRoot $ServerRoot | Where-Object { $_.Identity -eq $Identity -and ($Kinds.Count -eq 0 -or $_.Type -in $Kinds) } | Sort-Object CreatedUtc -Descending)
    $Removed = @()
    foreach ($Item in @($Candidates | Select-Object -Skip $Keep)) {
        $Resolved = [IO.Path]::GetFullPath([string]$Item.Path)
        if (-not $Resolved.StartsWith($Root + [IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase)) { throw 'Rotation refusee : cible hors dossier de sauvegardes.' }
        if (Test-Path -LiteralPath $Resolved -PathType Container) { [IO.Directory]::Delete($Resolved,$true) }
        elseif (Test-Path -LiteralPath $Resolved -PathType Leaf) { [IO.File]::Delete($Resolved) }
        $Removed += [string]$Item.Name
    }
    return @($Removed)
}

function Invoke-RustServerWipe {
    param(
        [Parameter(Mandatory = $true)][string]$ServerRoot,
        [Parameter(Mandatory = $true)][string]$Identity,
        [Parameter(Mandatory = $true)][ValidateSet('map','full')][string]$Type,
        [switch]$ResetPluginData,
        [switch]$CleanGeneratedMaps
    )

    Assert-RustIdentity $Identity
    Assert-RustServerStopped
    $Context=Get-RustIdentityStorageContext -ServerRoot $ServerRoot -Identity $Identity
    $IdentityPath = [IO.Path]::GetFullPath($Context.IdentityPath)
    $ServerIdentitiesRoot = [IO.Path]::GetFullPath($Context.IdentityRoot)
    if (-not $IdentityPath.StartsWith($ServerIdentitiesRoot + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Chemin de wipe invalide."
    }
    $BackupPath = New-RustServerBackup -ServerRoot $ServerRoot -Identity $Identity -Kind ("pre-wipe-" + $Type)
    $Targets = @(Get-ChildItem -LiteralPath $IdentityPath -File | Where-Object { $_.Name -match '\.sav($|\.)' })
    if ($Type -eq 'full') {
        $Targets += @(Get-ChildItem -LiteralPath $IdentityPath -File | Where-Object { $_.Name -like 'player.blueprints*' })
    }
    if ($CleanGeneratedMaps) {
        $Targets += @(Get-ChildItem -LiteralPath $IdentityPath -File | Where-Object { $_.Extension -eq '.map' -or $_.Name -like '*_occlusion_*.dat' })
    }
    $Targets = @($Targets | Sort-Object FullName -Unique)
    foreach ($Target in $Targets) {
        if ([IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($Target.FullName)) -ne $IdentityPath) {
            throw "Cible de wipe hors identite : $($Target.FullName)"
        }
        Remove-Item -LiteralPath $Target.FullName -Force
    }
    if ($ResetPluginData) {
        foreach ($Name in @('RustRPG.json','RustGunGame.json','RustDuel.json')) {
            $Path = Join-Path $Context.CarbonRoot ("data\" + $Name)
            if (Test-Path -LiteralPath $Path) { Remove-Item -LiteralPath $Path -Force }
        }
    }
    return [pscustomobject]@{ BackupPath = $BackupPath; DeletedFiles = $Targets.Count; Type = $Type }
}

function Restore-RustServerBackup {
    param(
        [Parameter(Mandatory = $true)][string]$ServerRoot,
        [Parameter(Mandatory = $true)][string]$BackupPath
    )

    Assert-RustServerStopped
    $BackupRoot = [IO.Path]::GetFullPath((Join-Path $ServerRoot 'backups\control-center'))
    $ResolvedBackup = [IO.Path]::GetFullPath($BackupPath)
    if (-not $ResolvedBackup.StartsWith($BackupRoot + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Sauvegarde hors du dossier autorise."
    }
    $Integrity = Test-RustServerBackup -ServerRoot $ServerRoot -BackupPath $ResolvedBackup
    if (-not $Integrity.Valid) { throw 'Restauration refusee : ' + $Integrity.Detail }

    $ExtractionPath = ''
    $EffectiveBackup = $ResolvedBackup
    try {
        if (Test-Path -LiteralPath $ResolvedBackup -PathType Leaf) {
            # L'archive a deja ete verifiee avant extraction. Le dossier
            # temporaire reste strictement sous backups\control-center.
            $ExtractionPath = Join-Path $BackupRoot ('.restore-' + [guid]::NewGuid().ToString('N'))
            [IO.Directory]::CreateDirectory($ExtractionPath) | Out-Null
            Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction Stop
            [IO.Compression.ZipFile]::ExtractToDirectory($ResolvedBackup,$ExtractionPath)
            $EffectiveBackup = $ExtractionPath
            $ExtractedCheck = Test-RustBackupDirectoryIntegrity -BackupDirectory $EffectiveBackup
            if (-not $ExtractedCheck.Valid) { throw 'Archive extraite mais invalide : ' + $ExtractedCheck.Detail }
        }

        $Meta = Get-RustBackupMetadata -BackupPath $EffectiveBackup
        if (-not $Meta) { throw 'metadata.json est absent ou illisible.' }
        $Identity = [string]$Meta.Identity
        Assert-RustIdentity $Identity
        $SourceIdentity = Join-Path $EffectiveBackup 'identity'
        if (-not (Test-Path -LiteralPath $SourceIdentity -PathType Container)) { throw "Cette sauvegarde ne contient pas d'identite Rust." }

        # Point de retour obligatoire, lui-meme compresse et verifie.
        $null = New-RustServerBackup -ServerRoot $ServerRoot -Identity $Identity -Kind 'pre-restore'
        $Context=Get-RustIdentityStorageContext -ServerRoot $ServerRoot -Identity $Identity
        $IdentityRoot = [IO.Path]::GetFullPath($Context.IdentityRoot)
        $TargetIdentity = [IO.Path]::GetFullPath((Join-Path $IdentityRoot $Identity))
        if (-not $TargetIdentity.StartsWith($IdentityRoot + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) { throw 'Destination invalide.' }

        # Preparation hors ligne puis permutation atomique de dossiers. Si le
        # renommage echoue, le monde courant reste en place.
        $NewIdentity = [IO.Path]::GetFullPath((Join-Path $IdentityRoot ($Identity + '.restore-' + [guid]::NewGuid().ToString('N'))))
        $OldIdentity = [IO.Path]::GetFullPath((Join-Path $IdentityRoot ($Identity + '.previous-' + [guid]::NewGuid().ToString('N'))))
        Copy-Item -LiteralPath $SourceIdentity -Destination $NewIdentity -Recurse -Force
        $SourceStats = Get-RustDirectoryStatistics -Path $SourceIdentity
        $NewStats = Get-RustDirectoryStatistics -Path $NewIdentity
        if ($SourceStats.FileCount -ne $NewStats.FileCount -or $SourceStats.Bytes -ne $NewStats.Bytes) {
            [IO.Directory]::Delete($NewIdentity,$true)
            throw 'La copie de restauration ne correspond pas a la sauvegarde.'
        }
        try {
            if (Test-Path -LiteralPath $TargetIdentity) { [IO.Directory]::Move($TargetIdentity,$OldIdentity) }
            [IO.Directory]::Move($NewIdentity,$TargetIdentity)
        }
        catch {
            if (Test-Path -LiteralPath $NewIdentity) { [IO.Directory]::Delete($NewIdentity,$true) }
            if (-not (Test-Path -LiteralPath $TargetIdentity) -and (Test-Path -LiteralPath $OldIdentity)) { [IO.Directory]::Move($OldIdentity,$TargetIdentity) }
            throw
        }
        if (Test-Path -LiteralPath $OldIdentity) { [IO.Directory]::Delete($OldIdentity,$true) }

        foreach ($Pair in @{
            'carbon-data'='data';
            'carbon-configs'='configs';
            'carbon-plugins'='plugins';
            'carbon-disabled-plugins'='disabled-plugins'
        }.GetEnumerator()) {
            $SourcePath = Join-Path $EffectiveBackup $Pair.Key
            $TargetPath = Join-Path $Context.CarbonRoot $Pair.Value
            if (Test-Path -LiteralPath $SourcePath -PathType Container) {
                [IO.Directory]::CreateDirectory($TargetPath) | Out-Null
                foreach ($Child in @(Get-ChildItem -LiteralPath $SourcePath -Force)) {
                    Copy-Item -LiteralPath $Child.FullName -Destination $TargetPath -Recurse -Force
                }
            }
        }
        return $Identity
    }
    finally {
        if ($ExtractionPath -and (Test-Path -LiteralPath $ExtractionPath)) { [IO.Directory]::Delete($ExtractionPath,$true) }
    }
}

function Get-RustPluginRuntimeContext {
    param([Parameter(Mandatory = $true)][string]$ServerRoot,[string]$InstanceId='')
    $Instance = if($InstanceId){Get-RustServerInstance -ServerRoot $ServerRoot -Id $InstanceId}else{Get-RustServerInstance -ServerRoot $ServerRoot}
    $RuntimeRoot = if($Instance -and (Get-Command Get-RustInstanceRuntimeRoot -ErrorAction SilentlyContinue)){Get-RustInstanceRuntimeRoot -ServerRoot $ServerRoot -Instance $Instance}else{Join-Path $ServerRoot 'server'}
    $Mod=Get-RustRuntimeModContext -RuntimeRoot $RuntimeRoot
    return [pscustomobject]@{Instance=$Instance;RuntimeRoot=$RuntimeRoot;Framework=$Mod.Framework;Installed=$Mod.Installed;PluginRoot=$Mod.PluginRoot;CarbonRoot=$Mod.PluginRoot;ConfigRoot=$Mod.ConfigRoot;DataRoot=$Mod.DataRoot;LogsRoot=$Mod.LogsRoot;ConsolePrefix=$Mod.ConsolePrefix}
}

function Get-RustPlugins {
    param([Parameter(Mandatory = $true)][string]$ServerRoot,[string]$InstanceId='')
    $EAcute = [char]0x00E9
    $ECirc = [char]0x00EA
    $Context = Get-RustPluginRuntimeContext -ServerRoot $ServerRoot -InstanceId $InstanceId
    $ActiveDir = Join-Path $Context.CarbonRoot 'plugins'
    $DisabledDir = Join-Path $Context.CarbonRoot 'disabled-plugins'

    # La lecture de l'etat ne doit jamais transformer une installation vanilla
    # en installation moddee. Les dossiers Carbon sont crees uniquement lors
    # d'une installation/importation explicite, jamais pendant un diagnostic.
    if (-not (Test-Path -LiteralPath $ActiveDir) -and -not (Test-Path -LiteralPath $DisabledDir)) {
        return @()
    }

    # L'etat d'un fichier et l'etat d'execution ne sont pas la meme chose.
    # Quand Rust tourne, on reconstruit le dernier etat connu depuis Carbon.Core.log.
    $ServerRunning = if($Context.Instance){@(Get-RustRpgServerProcesses -ServerRoot $ServerRoot | Where-Object Identity -eq ([string]$Context.Instance.identity)).Count -gt 0}else{(Get-RustRpgServerState -ServerRoot $ServerRoot).Running}
    $RuntimeStates = @{}
    if ($ServerRunning) {
        $RuntimeLogs = if ($Context.Framework -eq 'oxide') { @(Get-ChildItem -LiteralPath $Context.LogsRoot -Filter '*.txt' -File -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 3 -ExpandProperty FullName) } else { @(Join-Path $Context.LogsRoot 'Carbon.Core.log') }
        foreach ($RuntimeLog in $RuntimeLogs) {
            if (-not (Test-Path -LiteralPath $RuntimeLog)) { continue }
            foreach ($Line in Get-Content -LiteralPath $RuntimeLog -Tail 6000 -ErrorAction SilentlyContinue) {
                if ($Line -match "Loaded plugin ([^ ]+) v") {
                    $RuntimeStates[$Matches[1]] = ("Charg{0}" -f $EAcute)
                }
                elseif ($Line -match "Unloaded plugin ([^ ]+) v") {
                    $RuntimeStates[$Matches[1]] = ("D{0}charg{0}" -f $EAcute)
                }
                elseif ($Line -match "Failed compiling '([^']+)\.cs'") {
                    $RuntimeStates[$Matches[1]] = 'Erreur de compilation'
                }
            }
        }
    }

    $Items = @()
    foreach ($Entry in @(@{Path=$ActiveDir;State='Actif'},@{Path=$DisabledDir;State='Desactive'})) {
        foreach ($File in Get-ChildItem -LiteralPath $Entry.Path -Filter '*.cs' -File -ErrorAction SilentlyContinue) {
            $Header = Get-Content -LiteralPath $File.FullName -TotalCount 50 -ErrorAction SilentlyContinue | Out-String
            $Match = [regex]::Match($Header, '\[Info\(\s*"([^"]+)"\s*,\s*"([^"]+)"\s*,\s*"([^"]+)"')
            $PluginName = if ($Match.Success) { $Match.Groups[1].Value } else { $File.BaseName }
            $DisplayState = if ($Entry.State -eq 'Desactive') {
                ("D{0}sactiv{0}" -f $EAcute)
            }
            elseif (-not $ServerRunning) {
                ("Activ{0} - serveur arr{1}t{0}" -f $EAcute,$ECirc)
            }
            elseif ($RuntimeStates.ContainsKey($PluginName)) {
                [string]$RuntimeStates[$PluginName]
            }
            elseif ($RuntimeStates.ContainsKey($File.BaseName)) {
                [string]$RuntimeStates[$File.BaseName]
            }
            else {
                ("Activ{0} - {0}tat inconnu" -f $EAcute)
            }
            $FriendlyName = switch ($File.BaseName) {
                'RustRPG'          { 'Progression, quêtes & économie' }
                'RustGameHub'      { 'Lobby & modes de jeu' }
                'RustDuel'         { 'Duels & tournois' }
                'RustGunGame'      { 'Gun Game' }
                'RustTowerDefense' { 'Tower Defense' }
                'RustTraining'     { 'Entraînement' }
                'RustStats'        { 'Statistiques' }
                default            { $PluginName }
            }
            $Items += [pscustomobject]@{
                Nom        = $FriendlyName
                Version    = if ($Match.Success) { $Match.Groups[3].Value } else { '?' }
                Auteur     = if ($Match.Success) { $Match.Groups[2].Value } else { '?' }
                Etat       = $Entry.State
                EtatAffiche = $DisplayState
                FileBase   = $File.BaseName
                Path       = $File.FullName
                ConfigPath = Join-Path $Context.ConfigRoot ($File.BaseName + '.json')
            }
        }
    }
    return @($Items | Sort-Object Nom)
}

function Get-RustPluginCatalogDefinition {
    param([Parameter(Mandatory = $true)][string]$FileBase)
    switch ($FileBase) {
        'RustGameHub'      { return [pscustomobject]@{ CategoryId='mode'; CapabilityIds=@('competitive'); Detection='Registre Control Center' } }
        'RustDuel'         { return [pscustomobject]@{ CategoryId='mode'; CapabilityIds=@('duel'); Detection='Registre Control Center' } }
        'RustGunGame'      { return [pscustomobject]@{ CategoryId='mode'; CapabilityIds=@('gungame'); Detection='Registre Control Center' } }
        'RustRPG'          { return [pscustomobject]@{ CategoryId='mode'; CapabilityIds=@('progression'); Detection='Registre Control Center' } }
        'RustTowerDefense' { return [pscustomobject]@{ CategoryId='mode'; CapabilityIds=@('towerdefense'); Detection='Registre Control Center' } }
        'RustTraining'     { return [pscustomobject]@{ CategoryId='mode'; CapabilityIds=@('training'); Detection='Registre Control Center' } }
        'RustRates'        { return [pscustomobject]@{ CategoryId='gameplay'; CapabilityIds=@(); Detection='Registre Control Center' } }
        'RustStats'        { return [pscustomobject]@{ CategoryId='administration'; CapabilityIds=@(); Detection='Registre Control Center' } }
        default            { return $null }
    }
}

function Get-RustPluginCategoryLabel {
    param([string]$CategoryId)
    switch ($CategoryId) {
        'mode'           { return 'Mode de jeu' }
        'gameplay'       { return 'Gameplay' }
        'economy'        { return 'Économie' }
        'administration' { return 'Administration' }
        'utility'        { return 'Utilitaire' }
        default          { return 'Autre' }
    }
}

function Get-RustPluginCapabilityLabel {
    param([Parameter()][AllowEmptyCollection()][string[]]$CapabilityIds)
    $Labels = foreach ($Id in @($CapabilityIds)) {
        switch ($Id) {
            'competitive'  { 'Lobby, CTF, Domination, S&D, Extraction' }
            'duel'         { 'Duels, ELO et tournois' }
            'gungame'      { 'Gun Game' }
            'progression'  { 'RPG, quêtes et Zombies' }
            'towerdefense' { 'Tower Defense et Endless' }
            'training'     { 'Entraînement et sparring' }
        }
    }
    return @($Labels) -join ' • '
}

function Test-RustPluginSdkManifest {
    param([Parameter(Mandatory = $true)]$Manifest)
    if ([int]$Manifest.schemaVersion -ne 1) { throw 'Version de manifeste SDK non prise en charge.' }
    if ([string]$Manifest.id -notmatch '^[a-z0-9][a-z0-9_.-]{0,63}$') { throw 'Identifiant de manifeste SDK invalide.' }
    if (-not $Manifest.plugin -or [string]$Manifest.plugin.fileBase -notmatch '^[A-Za-z0-9_.-]{1,80}$') { throw 'plugin.fileBase est absent ou invalide.' }
    if ([string]::IsNullOrWhiteSpace([string]$Manifest.plugin.displayName)) { throw 'plugin.displayName est requis.' }
    if (-not $Manifest.config) { throw 'La section config est requise.' }
    $ConfigFile = [string]$Manifest.config.fileName
    if ($ConfigFile -and $ConfigFile -notmatch '^[A-Za-z0-9_.-]+\.json$') { throw 'config.fileName doit être un nom JSON simple.' }

    $SettingIds = @{}
    foreach ($Setting in @($Manifest.config.settings)) {
        $Id = [string]$Setting.id
        if ($Id -notmatch '^[a-z0-9][a-z0-9_.-]{0,63}$' -or $SettingIds.ContainsKey($Id)) { throw "Réglage SDK invalide ou dupliqué : $Id" }
        $SettingIds[$Id] = $true
        if ([string]$Setting.path -notmatch '^[A-Za-z0-9_-]+(?:\.[A-Za-z0-9_-]+)*$') { throw "Chemin de configuration refusé : $($Setting.path)" }
        if ([string]$Setting.type -notin @('boolean','integer','number','string','choice')) { throw "Type de réglage non pris en charge : $($Setting.type)" }
        if ([string]::IsNullOrWhiteSpace([string]$Setting.label)) { throw "Libellé absent pour le réglage $Id." }
        if ([string]$Setting.type -eq 'choice' -and @($Setting.options).Count -eq 0) { throw "Le réglage $Id doit proposer au moins une option." }
        if ($Setting.PSObject.Properties.Name -contains 'min' -and $Setting.PSObject.Properties.Name -contains 'max' -and [double]$Setting.min -gt [double]$Setting.max) { throw "Bornes inversées pour le réglage $Id." }
    }
    if (@($Manifest.config.settings).Count -gt 0 -and -not $ConfigFile) { throw 'Un manifeste avec des réglages doit déclarer config.fileName.' }

    $ActionIds = @{}
    foreach ($Action in @($Manifest.actions)) {
        $Id = [string]$Action.id
        if ($Id -notmatch '^[a-z0-9][a-z0-9_.-]{0,63}$' -or $ActionIds.ContainsKey($Id)) { throw "Action SDK invalide ou dupliquée : $Id" }
        $ActionIds[$Id] = $true
        if ([string]$Action.kind -ne 'rcon') { throw "Type d'action SDK non pris en charge : $($Action.kind)" }
        $Command = [string]$Action.command
        if ($Command.Length -gt 180 -or $Command -notmatch '^[A-Za-z0-9_.:-]+(?: [A-Za-z0-9_.:=/@,+-]+)*$') { throw "Commande RCON refusée pour l'action $Id." }
        if ([string]::IsNullOrWhiteSpace([string]$Action.label)) { throw "Libellé absent pour l'action $Id." }
    }
    return $true
}

function Get-RustPluginSdkManifests {
    param([Parameter(Mandatory = $true)][string]$ServerRoot,[string]$InstanceId='')
    $ByPlugin = [ordered]@{}
    $Sources = New-Object 'Collections.Generic.List[object]'
    $BuiltInRoot = Join-Path $PSScriptRoot 'sdk\manifests'
    if (Test-Path -LiteralPath $BuiltInRoot -PathType Container) { $Sources.Add([pscustomobject]@{ Root=$BuiltInRoot; Source='built-in' }) }
    $Context = Get-RustPluginRuntimeContext -ServerRoot $ServerRoot -InstanceId $InstanceId
    $LocalRoot = Join-Path $Context.CarbonRoot 'plugin-manifests'
    if (Test-Path -LiteralPath $LocalRoot -PathType Container) { $Sources.Add([pscustomobject]@{ Root=$LocalRoot; Source='instance' }) }
    foreach ($Source in $Sources) {
        foreach ($File in @(Get-ChildItem -LiteralPath $Source.Root -Filter '*.json' -File -ErrorAction SilentlyContinue | Sort-Object Name)) {
            try {
                $Manifest = Get-Content -LiteralPath $File.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
                $null = Test-RustPluginSdkManifest -Manifest $Manifest
                $Manifest | Add-Member -NotePropertyName ManifestPath -NotePropertyValue $File.FullName -Force
                $Manifest | Add-Member -NotePropertyName ManifestSource -NotePropertyValue ([string]$Source.Source) -Force
                $ByPlugin[[string]$Manifest.plugin.fileBase] = $Manifest
            }
            catch {
                # Un manifeste tiers invalide ne doit jamais empêcher la gestion
                # du serveur ou des autres plugins.
            }
        }
    }
    return @($ByPlugin.Values)
}

function Get-RustPluginSdkManifest {
    param([Parameter(Mandatory = $true)][string]$ServerRoot,[Parameter(Mandatory = $true)][string]$FileBase,[string]$InstanceId='')
    return @(Get-RustPluginSdkManifests -ServerRoot $ServerRoot -InstanceId $InstanceId | Where-Object { [string]$_.plugin.fileBase -eq $FileBase } | Select-Object -First 1)[0]
}

function Get-RustPluginSdkObjectValue {
    param($Root,[Parameter(Mandatory = $true)][string]$Path)
    $Current = $Root
    foreach ($Segment in @($Path -split '\.')) {
        if ($null -eq $Current) { return $null }
        $Property = $Current.PSObject.Properties[[string]$Segment]
        if (-not $Property) { return $null }
        $Current = $Property.Value
    }
    return $Current
}

function Set-RustPluginSdkObjectValue {
    param($Root,[Parameter(Mandatory = $true)][string]$Path,$Value)
    $Segments = @($Path -split '\.')
    $Current = $Root
    for ($Index = 0; $Index -lt $Segments.Count - 1; $Index++) {
        $Name = [string]$Segments[$Index]
        $Property = $Current.PSObject.Properties[$Name]
        if (-not $Property -or $null -eq $Property.Value -or $Property.Value -isnot [Management.Automation.PSCustomObject]) {
            $Child = [pscustomobject][ordered]@{}
            if ($Property) { $Property.Value = $Child } else { $Current | Add-Member -NotePropertyName $Name -NotePropertyValue $Child }
            $Current = $Child
        }
        else { $Current = $Property.Value }
    }
    $Last = [string]$Segments[-1]
    $LastProperty = $Current.PSObject.Properties[$Last]
    if ($LastProperty) { $LastProperty.Value = $Value } else { $Current | Add-Member -NotePropertyName $Last -NotePropertyValue $Value }
}

function ConvertTo-RustPluginSdkValue {
    param([Parameter(Mandatory = $true)]$Setting,$Value)
    $Id = [string]$Setting.id
    switch ([string]$Setting.type) {
        'boolean' {
            if ($Value -is [bool]) { $Converted = [bool]$Value }
            else {
                switch (([string]$Value).Trim().ToLowerInvariant()) {
                    { $_ -in @('true','1','oui','yes') } { $Converted = $true; break }
                    { $_ -in @('false','0','non','no') } { $Converted = $false; break }
                    default { throw "$Id : valeur booléenne invalide." }
                }
            }
        }
        'integer' {
            $Converted = [long]0
            if (-not [long]::TryParse(([string]$Value).Trim(),[Globalization.NumberStyles]::Integer,[Globalization.CultureInfo]::InvariantCulture,[ref]$Converted)) { throw "$Id : nombre entier invalide." }
        }
        'number' {
            $Converted = [double]0
            $Normalized = ([string]$Value).Trim().Replace(',','.')
            if (-not [double]::TryParse($Normalized,[Globalization.NumberStyles]::Float,[Globalization.CultureInfo]::InvariantCulture,[ref]$Converted)) { throw "$Id : nombre invalide." }
        }
        'choice' {
            $Converted = [string]$Value
            if (@($Setting.options | ForEach-Object { [string]$_ }) -notcontains $Converted) { throw "$Id : option inconnue." }
        }
        default {
            $Converted = [string]$Value
            if ($Converted.Length -gt 2048) { throw "$Id : texte trop long." }
        }
    }
    if ([string]$Setting.type -in @('integer','number')) {
        if ($Setting.PSObject.Properties.Name -contains 'min' -and [double]$Converted -lt [double]$Setting.min) { throw "$Id : minimum $($Setting.min)." }
        if ($Setting.PSObject.Properties.Name -contains 'max' -and [double]$Converted -gt [double]$Setting.max) { throw "$Id : maximum $($Setting.max)." }
    }
    return $Converted
}

function Get-RustPluginSdkConfigState {
    param([Parameter(Mandatory = $true)][string]$ServerRoot,[Parameter(Mandatory = $true)][string]$FileBase,[string]$InstanceId='')
    $Manifest = Get-RustPluginSdkManifest -ServerRoot $ServerRoot -FileBase $FileBase -InstanceId $InstanceId
    if (-not $Manifest) { return $null }
    $Context = Get-RustPluginRuntimeContext -ServerRoot $ServerRoot -InstanceId $InstanceId
    $ConfigPath = if ([string]$Manifest.config.fileName) { Join-Path $Context.ConfigRoot ([string]$Manifest.config.fileName) } else { '' }
    $Config = [pscustomobject][ordered]@{}
    if ($ConfigPath -and (Test-Path -LiteralPath $ConfigPath -PathType Leaf)) { $Config = Get-Content -LiteralPath $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json }
    $Settings = foreach ($Setting in @($Manifest.config.settings)) {
        $Value = Get-RustPluginSdkObjectValue -Root $Config -Path ([string]$Setting.path)
        $UsingDefault = $null -eq $Value
        if ($UsingDefault) { $Value = $Setting.default }
        [pscustomobject]@{ Definition=$Setting; Id=[string]$Setting.id; Path=[string]$Setting.path; Label=[string]$Setting.label; Type=[string]$Setting.type; Value=$Value; UsingDefault=[bool]$UsingDefault }
    }
    return [pscustomobject]@{ Manifest=$Manifest; ConfigPath=$ConfigPath; ConfigExists=[bool]($ConfigPath -and (Test-Path -LiteralPath $ConfigPath -PathType Leaf)); Config=$Config; Settings=@($Settings) }
}

function Set-RustPluginSdkConfiguration {
    param([Parameter(Mandatory = $true)][string]$ServerRoot,[Parameter(Mandatory = $true)][string]$FileBase,[Parameter(Mandatory = $true)][Collections.IDictionary]$Values,[string]$InstanceId='')
    $State = Get-RustPluginSdkConfigState -ServerRoot $ServerRoot -FileBase $FileBase -InstanceId $InstanceId
    if (-not $State -or -not [string]$State.ConfigPath) { throw 'Ce plugin ne déclare aucun réglage SDK.' }
    $Allowed = @{}
    foreach ($Setting in @($State.Manifest.config.settings)) { $Allowed[[string]$Setting.id] = $Setting }
    foreach ($Key in @($Values.Keys)) {
        if (-not $Allowed.ContainsKey([string]$Key)) { throw "Réglage SDK inconnu : $Key" }
        $Converted = ConvertTo-RustPluginSdkValue -Setting $Allowed[[string]$Key] -Value $Values[$Key]
        Set-RustPluginSdkObjectValue -Root $State.Config -Path ([string]$Allowed[[string]$Key].path) -Value $Converted
    }
    $BackupPath = ''
    if (Test-Path -LiteralPath $State.ConfigPath -PathType Leaf) {
        $Context = Get-RustPluginRuntimeContext -ServerRoot $ServerRoot -InstanceId $InstanceId
        $Identity = if ($Context.Instance) { [string]$Context.Instance.identity } else { 'default' }
        $BackupRoot = Join-Path $ServerRoot ('backups\plugin-config\' + $Identity)
        [IO.Directory]::CreateDirectory($BackupRoot) | Out-Null
        $BackupPath = Join-Path $BackupRoot ((Get-Date -Format 'yyyyMMdd-HHmmss-fff') + '-' + [IO.Path]::GetFileName($State.ConfigPath))
        Copy-Item -LiteralPath $State.ConfigPath -Destination $BackupPath -Force
    }
    $null = Save-RustJsonAtomic -Path $State.ConfigPath -Value $State.Config
    return [pscustomobject]@{ ConfigPath=$State.ConfigPath; BackupPath=$BackupPath; ReloadOnSave=[bool]$State.Manifest.config.reloadOnSave; UpdatedCount=[int]$Values.Count }
}

function Get-RustPluginCatalog {
    param([Parameter(Mandatory = $true)][string]$ServerRoot,[string]$InstanceId='')
    $Plugins = @(Get-RustPlugins -ServerRoot $ServerRoot -InstanceId $InstanceId)
    if (-not $Plugins.Count) { return @() }
    $DuplicateNames = @($Plugins | Group-Object FileBase | Where-Object Count -gt 1 | Select-Object -ExpandProperty Name)
    $SdkManifests = @(Get-RustPluginSdkManifests -ServerRoot $ServerRoot -InstanceId $InstanceId)

    $Catalog = foreach ($Plugin in $Plugins) {
        $Issues = New-Object 'Collections.Generic.List[string]'
        $Source = ''
        try { $Source = [IO.File]::ReadAllText([string]$Plugin.Path) }
        catch { $Issues.Add('Le code source ne peut pas être lu.') }

        $InfoMatch = [regex]::Match($Source,'\[Info\(\s*"([^"]+)"\s*,\s*"([^"]+)"\s*,\s*"([^"]+)"')
        $DescriptionMatch = [regex]::Match($Source,'\[Description\(\s*"((?:\\.|[^"])*)"\s*\)\]')
        $FrameworkMatch = [regex]::Match($Source,'class\s+[A-Za-z0-9_]+\s*:\s*(RustPlugin|CarbonPlugin|CovalencePlugin)')
        $PluginName = if ($InfoMatch.Success) { $InfoMatch.Groups[1].Value } else { [string]$Plugin.FileBase }
        $Author = if ($InfoMatch.Success) { $InfoMatch.Groups[2].Value } else { [string]$Plugin.Auteur }
        $Version = if ($InfoMatch.Success) { $InfoMatch.Groups[3].Value } else { [string]$Plugin.Version }
        $Description = if ($DescriptionMatch.Success) {
            [Net.WebUtility]::HtmlDecode($DescriptionMatch.Groups[1].Value.Replace('\"','"'))
        }
        else { '' }
        if (-not $InfoMatch.Success) { $Issues.Add('Métadonnées [Info] absentes ou illisibles.') }
        if (-not $Description) { $Issues.Add('Description du plugin absente.') }

        $Framework = if ($FrameworkMatch.Success) {
            switch ($FrameworkMatch.Groups[1].Value) {
                'CarbonPlugin'    { 'Carbon' }
                'CovalencePlugin' { 'Carbon / Oxide' }
                default           { 'Carbon / Oxide' }
            }
        }
        else {
            $Issues.Add('Type de plugin Carbon/Oxide non reconnu.')
            'Non reconnu'
        }

        $Commands = @([regex]::Matches($Source,'\[(?:ChatCommand|ConsoleCommand|Command)\(\s*"([^"]+)"') | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique)
        $Permissions = @([regex]::Matches($Source,'(?im)(?:permission|perm)[^=\r\n]{0,45}=\s*"([a-z0-9_.-]+)"') | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique)
        $Dependencies = @([regex]::Matches($Source,'(?m)\[PluginReference\][^\r\n]*(?:private|protected|public)?\s*(?:Plugin\s+)?([A-Za-z0-9_]+)\s*;') | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique)

        $SdkManifest = @($SdkManifests | Where-Object { [string]$_.plugin.fileBase -eq [string]$Plugin.FileBase } | Select-Object -First 1)[0]
        $Definition = Get-RustPluginCatalogDefinition -FileBase ([string]$Plugin.FileBase)
        $CapabilityIds = New-Object 'Collections.Generic.List[string]'
        if ($SdkManifest) {
            foreach ($CapabilityId in @($SdkManifest.plugin.capabilities)) { if (-not $CapabilityIds.Contains([string]$CapabilityId)) { $CapabilityIds.Add([string]$CapabilityId) } }
            $CategoryId = if ([string]$SdkManifest.plugin.category) { [string]$SdkManifest.plugin.category } elseif ($Definition) { [string]$Definition.CategoryId } else { 'other' }
            $Detection = 'Manifeste SDK v1'
        }
        elseif ($Definition) {
            foreach ($CapabilityId in @($Definition.CapabilityIds)) { if (-not $CapabilityIds.Contains([string]$CapabilityId)) { $CapabilityIds.Add([string]$CapabilityId) } }
            $CategoryId = [string]$Definition.CategoryId
            $Detection = [string]$Definition.Detection
        }
        else {
            $Haystack = (($Plugin.FileBase,$PluginName,$Description,($Commands -join ' ')) -join ' ').ToLowerInvariant()
            if ($Haystack -match 'gun\s*game|gungame|arms\s*race') { $CapabilityIds.Add('gungame') }
            if ($Haystack -match 'tower\s*defen[cs]e|towerdefen[cs]e') { $CapabilityIds.Add('towerdefense') }
            if ($Haystack -match '\bduel\b|\btournament\b|\btournoi\b') { $CapabilityIds.Add('duel') }
            if ($Haystack -match '\bzombie\b|\brpg\b|\bquest(?:s)?\b|\bqu[eê]te(?:s)?\b') { $CapabilityIds.Add('progression') }
            if ($Haystack -match 'aim\s*train|shooting\s*range|\btraining\b|\bsparring\b|\bentrainement\b|\bentraînement\b') { $CapabilityIds.Add('training') }
            if ($Haystack -match 'capture\s+the\s+flag|\bctf\b|\bdomination\b|search\s*(?:&|and)\s*destroy|\bextraction\b') { $CapabilityIds.Add('competitive') }
            if ($CapabilityIds.Count -gt 0) { $CategoryId = 'mode' }
            elseif ($Haystack -match '\bgather|\bharvest|\bcraft|\bstack|\brate(?:s)?\b|recolte|récolte|fabrication') { $CategoryId = 'gameplay' }
            elseif ($Haystack -match '\beconom|\bcurrency|\bshop|\breward|boutique|monnaie') { $CategoryId = 'economy' }
            elseif ($Haystack -match '\badmin|\bmoderation|\bban\b|\bkick\b|\bwhitelist\b|statistic|\bstats\b') { $CategoryId = 'administration' }
            elseif ($Haystack -match '\bbackup|\bwipe\b|\blog(?:ger)?\b|\bmetric|\bmonitor') { $CategoryId = 'utility' }
            else { $CategoryId = 'other' }
            $Detection = if ($CategoryId -eq 'other') { 'Métadonnées génériques' } else { 'Analyse automatique du code' }
        }

        if ($DuplicateNames -contains [string]$Plugin.FileBase) { $Issues.Add('Le même plugin existe dans les dossiers actif et désactivé.') }
        if ([string]$Plugin.EtatAffiche -eq 'Erreur de compilation') { $Issues.Add('Carbon signale une erreur de compilation.') }
        elseif ([string]$Plugin.EtatAffiche -like '*état inconnu*') { $Issues.Add("L'état d'exécution n'est pas confirmé par Carbon.") }

        $HealthId = if ([string]$Plugin.EtatAffiche -eq 'Erreur de compilation' -or $DuplicateNames -contains [string]$Plugin.FileBase) { 'error' } elseif ($Issues.Count -gt 0) { 'warning' } else { 'ok' }
        $HasConfig = Test-Path -LiteralPath ([string]$Plugin.ConfigPath) -PathType Leaf
        $FileInfo = Get-Item -LiteralPath ([string]$Plugin.Path) -ErrorAction SilentlyContinue
        $CapabilityArray = @($CapabilityIds | Sort-Object -Unique)
        $CapabilityLabel = Get-RustPluginCapabilityLabel -CapabilityIds $CapabilityArray
        $CategoryLabel = Get-RustPluginCategoryLabel -CategoryId $CategoryId
        $MetadataLine = "$($Plugin.FileBase).cs • v$Version • $Author"
        $TechnicalLine = "$Framework • $($Commands.Count) commande(s) • $($Permissions.Count) permission(s)"
        if ($HasConfig) { $TechnicalLine += ' • configuration détectée' }
        if ($SdkManifest) { $TechnicalLine += " • SDK v1 ($(@($SdkManifest.config.settings).Count) réglage(s), $(@($SdkManifest.actions).Count) action(s))" }

        [pscustomobject][ordered]@{
            Nom              = [string]$Plugin.Nom
            PluginName       = $PluginName
            Description      = $Description
            Version          = $Version
            Auteur           = $Author
            Etat             = [string]$Plugin.Etat
            EtatAffiche      = [string]$Plugin.EtatAffiche
            FileBase         = [string]$Plugin.FileBase
            FileName         = ([string]$Plugin.FileBase + '.cs')
            Path             = [string]$Plugin.Path
            ConfigPath       = [string]$Plugin.ConfigPath
            HasConfig        = [bool]$HasConfig
            HasSdk           = [bool]($null -ne $SdkManifest)
            SdkManifest      = $SdkManifest
            SdkVersion       = if ($SdkManifest) { [int]$SdkManifest.schemaVersion } else { 0 }
            SdkSettingsCount = if ($SdkManifest) { [int]@($SdkManifest.config.settings).Count } else { 0 }
            SdkActionCount   = if ($SdkManifest) { [int]@($SdkManifest.actions).Count } else { 0 }
            SdkLabel         = if ($SdkManifest) { 'SDK v1' } else { '—' }
            Framework        = $Framework
            CategoryId       = $CategoryId
            CategoryLabel    = $CategoryLabel
            CapabilityIds    = $CapabilityArray
            CapabilityLabel  = $CapabilityLabel
            IsMode           = [bool]($CapabilityArray.Count -gt 0)
            Detection        = $Detection
            Commands         = @($Commands)
            CommandCount     = [int]$Commands.Count
            CommandPreview   = (@($Commands | Select-Object -First 5) -join ', ')
            Permissions      = @($Permissions)
            PermissionCount  = [int]$Permissions.Count
            Dependencies     = @($Dependencies)
            DependencyCount  = [int]$Dependencies.Count
            HealthId         = $HealthId
            HealthLabel      = $(switch ($HealthId) { 'error' { 'ERREUR' } 'warning' { 'À VÉRIFIER' } default { 'SAIN' } })
            IssueText        = @($Issues) -join ' • '
            MetadataLine     = $MetadataLine
            TechnicalLine    = $TechnicalLine
            LastModified     = if ($FileInfo) { $FileInfo.LastWriteTime } else { [datetime]::MinValue }
            SizeKb           = if ($FileInfo) { [math]::Round($FileInfo.Length / 1KB,1) } else { 0 }
            SearchText       = (($Plugin.Nom,$PluginName,$Plugin.FileBase,$Description,$Author,$CategoryLabel,$CapabilityLabel,($Commands -join ' ')) -join ' ').ToLowerInvariant()
        }
    }
    return @($Catalog | Sort-Object CategoryLabel,Nom)
}

function Get-RustModEnvironment {
    param([Parameter(Mandatory = $true)][string]$ServerRoot,[string]$InstanceId='')
    $Context = Get-RustPluginRuntimeContext -ServerRoot $ServerRoot -InstanceId $InstanceId
    $VersionFile = if ($Context.Framework -eq 'carbon') { Join-Path $Context.PluginRoot 'managed\Carbon.Common.dll' } else { Join-Path $Context.RuntimeRoot 'RustDedicated_Data\Managed\Oxide.Rust.dll' }
    return [pscustomobject]@{
        Id        = [string]$Context.Framework
        Label     = ([string]$Context.Framework).ToUpperInvariant()
        Installed = [bool]$Context.Installed
        Version   = if (Test-Path -LiteralPath $VersionFile -PathType Leaf) { [string](Get-Item -LiteralPath $VersionFile).VersionInfo.FileVersion } else { '' }
    }
}

function Get-RustPluginCapabilityRegistry {
    # Registre volontairement petit et declaratif. Un plugin non repertorie
    # reste administrable dans Extensions, sans inventer une interface de mode.
    return @(
        [pscustomobject]@{ Id='competitive'; DisplayName='Modes compétitifs'; Plugin='RustGameHub'; ConfigName='RustGameHub.json'; Group='competitive' },
        [pscustomobject]@{ Id='duel'; DisplayName='Duels & tournois'; Plugin='RustDuel'; ConfigName='RustDuel.json'; Group='duel' },
        [pscustomobject]@{ Id='gungame'; DisplayName='Gun Game'; Plugin='RustGunGame'; ConfigName='RustGunGame.json'; Group='gungame' },
        [pscustomobject]@{ Id='progression'; DisplayName='Zombies & progression'; Plugin='RustRPG'; ConfigName='RustRPG.json'; Group='progression' },
        [pscustomobject]@{ Id='towerdefense'; DisplayName='Tower Defense'; Plugin='RustTowerDefense'; ConfigName='RustTowerDefense.json'; Group='towerdefense' },
        [pscustomobject]@{ Id='training'; DisplayName='Entraînement'; Plugin='RustTraining'; ConfigName='RustTraining.json'; Group='training' }
    )
}

function Get-RustPluginCapabilities {
    param(
        [Parameter(Mandatory = $true)][string]$ServerRoot,
        [Parameter()][AllowEmptyCollection()][object[]]$Plugins
    )
    if (-not $PSBoundParameters.ContainsKey('Plugins')) {
        $Plugins = @(Get-RustPluginCatalog -ServerRoot $ServerRoot)
    }
    $Result = foreach ($Definition in @(Get-RustPluginCapabilityRegistry)) {
        $Plugin = @($Plugins | Where-Object { [string]$_.FileBase -eq [string]$Definition.Plugin -and [string]$_.Etat -eq 'Actif' }) | Select-Object -First 1
        if (-not $Plugin) {
            $Plugin = @($Plugins | Where-Object { [string]$_.Etat -eq 'Actif' -and $_.PSObject.Properties.Name -contains 'CapabilityIds' -and @($_.CapabilityIds) -contains [string]$Definition.Id }) | Select-Object -First 1
        }
        if (-not $Plugin) {
            $Plugin = @($Plugins | Where-Object FileBase -eq $Definition.Plugin) | Select-Object -First 1
        }
        if (-not $Plugin) {
            $Plugin = @($Plugins | Where-Object { $_.PSObject.Properties.Name -contains 'CapabilityIds' -and @($_.CapabilityIds) -contains [string]$Definition.Id }) | Select-Object -First 1
        }
        if (-not $Plugin) { continue }
        [pscustomobject]@{
            Id           = [string]$Definition.Id
            DisplayName  = [string]$Definition.DisplayName
            Plugin       = [string]$Plugin.FileBase
            PluginFile   = ([string]$Plugin.FileBase + '.cs')
            ConfigName   = [string]$Definition.ConfigName
            ConfigPath   = [string]$Plugin.ConfigPath
            Group        = [string]$Definition.Group
            Enabled      = ([string]$Plugin.Etat -eq 'Actif')
            State        = [string]$Plugin.Etat
            RuntimeState = [string]$Plugin.EtatAffiche
            SourcePath   = [string]$Plugin.Path
            Detection    = if ($Plugin.PSObject.Properties.Name -contains 'Detection') { [string]$Plugin.Detection } else { 'Registre Control Center' }
        }
    }
    return @($Result)
}

function Set-RustPluginEnabled {
    param(
        [Parameter(Mandatory = $true)][string]$ServerRoot,
        [Parameter(Mandatory = $true)][string]$FileBase,
        [Parameter(Mandatory = $true)][bool]$Enabled,
        [string]$InstanceId=''
    )
    if ($FileBase -notmatch '^[A-Za-z0-9_.-]+$') { throw 'Nom de plugin invalide.' }
    $Context = Get-RustPluginRuntimeContext -ServerRoot $ServerRoot -InstanceId $InstanceId
    $Active = Join-Path $Context.CarbonRoot ("plugins\" + $FileBase + '.cs')
    $DisabledDir = Join-Path $Context.CarbonRoot 'disabled-plugins'
    $Disabled = Join-Path $DisabledDir ($FileBase + '.cs')
    New-Item -ItemType Directory -Force -Path $DisabledDir | Out-Null
    $Running = if($Context.Instance){@(Get-RustRpgServerProcesses -ServerRoot $ServerRoot|Where-Object Identity -eq ([string]$Context.Instance.identity)).Count-gt0}else{(Get-RustRpgServerState -ServerRoot $ServerRoot).Running}
    if ($Enabled) {
        if (-not (Test-Path -LiteralPath $Disabled)) { throw 'Plugin desactive introuvable.' }
        Move-Item -LiteralPath $Disabled -Destination $Active -Force
        if ($Running) { $null = Invoke-RustRpgRconCommand -ServerRoot $ServerRoot -Command ($Context.ConsolePrefix + ".load " + $FileBase) }
    }
    else {
        if (-not (Test-Path -LiteralPath $Active)) { throw 'Plugin actif introuvable.' }
        if ($Running) { $null = Invoke-RustRpgRconCommand -ServerRoot $ServerRoot -Command ($Context.ConsolePrefix + ".unload " + $FileBase) }
        Move-Item -LiteralPath $Active -Destination $Disabled -Force
    }
}

function Import-RustPlugin {
    param([string]$ServerRoot,[string]$SourcePath,[string]$InstanceId='')
    if ([IO.Path]::GetExtension($SourcePath) -ne '.cs') { throw 'Choisis un plugin Carbon/Oxide au format .cs.' }
    $Context = Get-RustPluginRuntimeContext -ServerRoot $ServerRoot -InstanceId $InstanceId
    $TargetDir = Join-Path $Context.CarbonRoot 'plugins'
    New-Item -ItemType Directory -Force -Path $TargetDir | Out-Null
    $Target = Join-Path $TargetDir (Split-Path $SourcePath -Leaf)
    if (Test-Path -LiteralPath $Target) {
        $BackupDir = Join-Path $ServerRoot ('backups\plugins\' + (Get-Date -Format 'yyyyMMdd-HHmmss'))
        New-Item -ItemType Directory -Force -Path $BackupDir | Out-Null
        Copy-Item -LiteralPath $Target -Destination $BackupDir -Force
    }
    Copy-Item -LiteralPath $SourcePath -Destination $Target -Force
    return $Target
}

function Archive-RustPlugin {
    param([string]$ServerRoot,[string]$FileBase,[string]$InstanceId='')
    if ($FileBase -notmatch '^[A-Za-z0-9_.-]+$') { throw 'Nom de plugin invalide.' }
    $Context = Get-RustPluginRuntimeContext -ServerRoot $ServerRoot -InstanceId $InstanceId
    $Plugin = Get-RustPlugins -ServerRoot $ServerRoot -InstanceId $InstanceId | Where-Object FileBase -eq $FileBase | Select-Object -First 1
    if (-not $Plugin) { throw 'Plugin introuvable.' }
    if ($Plugin.Etat -eq 'Actif' -and $(if($Context.Instance){@(Get-RustRpgServerProcesses -ServerRoot $ServerRoot|Where-Object Identity -eq ([string]$Context.Instance.identity)).Count-gt0}else{(Get-RustRpgServerState -ServerRoot $ServerRoot).Running})) {
        $null = Invoke-RustRpgRconCommand -ServerRoot $ServerRoot -Command ($Context.ConsolePrefix + ".unload " + $FileBase)
    }
    $ArchiveDir = Join-Path $ServerRoot ('backups\plugins\archive-' + (Get-Date -Format 'yyyyMMdd-HHmmss'))
    New-Item -ItemType Directory -Force -Path $ArchiveDir | Out-Null
    Move-Item -LiteralPath $Plugin.Path -Destination (Join-Path $ArchiveDir (Split-Path $Plugin.Path -Leaf))
    return $ArchiveDir
}

function Get-RustServerCfg {
    param([string]$ServerRoot,[string]$Identity = '')
    $Path = if ($Identity) { Join-Path (Get-RustIdentityStorageContext -ServerRoot $ServerRoot -Identity $Identity).IdentityPath 'cfg\server.cfg' } else { Join-Path $ServerRoot 'config\server.cfg' }
    if (-not (Test-Path -LiteralPath $Path)) { $Path = Join-Path $ServerRoot 'config\server.cfg' }
    $Values = @{}
    foreach ($Line in Get-Content -LiteralPath $Path) {
        if ($Line -match '^\s*([A-Za-z0-9_.]+)\s+(.+?)\s*$') {
            $Value = $Matches[2].Trim()
            if ($Value.StartsWith('"') -and $Value.EndsWith('"')) { $Value = $Value.Substring(1,$Value.Length-2) }
            $Values[$Matches[1]] = $Value
        }
    }
    return $Values
}

function Set-RustServerCfg {
    param([string]$ServerRoot,[hashtable]$Values,[string]$Identity = '')
    $Order = @('server.hostname','server.description','server.maxplayers','server.saveinterval','server.pve','server.radiation','server.globalchat','creative.allusers')
    $StringKeys = @('server.hostname','server.description')
    $Lines = foreach ($Key in $Order) {
        if ($Values.ContainsKey($Key)) {
            $Value = [string]$Values[$Key]
            if ($StringKeys -contains $Key) { $Value = '"' + $Value.Replace('"',"'") + '"' }
            "$Key $Value"
        }
    }
    $Content = ($Lines -join [Environment]::NewLine) + [Environment]::NewLine
    $Context=if($Identity){Get-RustIdentityStorageContext -ServerRoot $ServerRoot -Identity $Identity}else{$null}
    $ConfigPath = if ($Identity) { Join-Path $Context.IdentityPath 'cfg\server.cfg' } else { Join-Path $ServerRoot 'config\server.cfg' }
    $ConfigDirectory = Split-Path $ConfigPath -Parent
    if (-not (Test-Path -LiteralPath $ConfigDirectory)) { New-Item -ItemType Directory -Path $ConfigDirectory -Force | Out-Null }
    if (-not (Test-Path -LiteralPath $ConfigPath)) { Copy-Item -LiteralPath (Join-Path $ServerRoot 'config\server.cfg') -Destination $ConfigPath -Force }
    $BackupPath = $ConfigPath + '.bak-' + (Get-Date -Format 'yyyyMMdd-HHmmss')
    Copy-Item -LiteralPath $ConfigPath -Destination $BackupPath -Force
    Write-Utf8File -Path $ConfigPath -Content $Content
    $TargetInstance=if($Context){$Context.Instance}else{$null}
    $TargetRunning=if($TargetInstance){@(Get-RustRpgServerProcesses -ServerRoot $ServerRoot|Where-Object Identity -eq ([string]$TargetInstance.identity)).Count-gt0}else{(Get-RustRpgServerState -ServerRoot $ServerRoot).Running}
    if ($TargetRunning) {
        foreach ($Key in $Values.Keys) {
            $Value = [string]$Values[$Key]
            if ($StringKeys -contains $Key) { $Value = '"' + $Value.Replace('"',"'") + '"' }
            try { $null = Invoke-RustRpgRconCommand -ServerRoot $ServerRoot -RconPort $(if($TargetInstance){[int]$TargetInstance.rconPort}else{0}) -Command ("$Key $Value") } catch {}
        }
        $null = Invoke-RustRpgRconCommand -ServerRoot $ServerRoot -RconPort $(if($TargetInstance){[int]$TargetInstance.rconPort}else{0}) -Command 'server.writecfg'
    }
    return $BackupPath
}

function Get-CarbonAutoWipeConfig {
    param([string]$ServerRoot,[string]$Identity='')
    $Context=if($Identity){Get-RustIdentityStorageContext -ServerRoot $ServerRoot -Identity $Identity}else{Get-RustPluginRuntimeContext -ServerRoot $ServerRoot}
    $CarbonRoot=if($Context.PSObject.Properties.Name -contains 'CarbonRoot'){$Context.CarbonRoot}else{Join-Path $ServerRoot 'server\carbon'}
    $Path = Join-Path $CarbonRoot 'modules\AutoWipe\config.json'
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    return Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
}

function Set-CarbonAutoWipeConfig {
    param(
        [string]$ServerRoot,
        [bool]$Enabled,
        [string]$Cron,
        [ValidateSet('map','full')][string]$Type,
        [string]$Identity = 'serveur-amis'
    )
    Assert-RustServerStopped
    if ($Enabled -and (($Cron -split '\s+').Count -ne 5)) { throw 'Le planning Cron doit contenir 5 champs.' }
    $Profile = Get-RustMapProfile -ServerRoot $ServerRoot -Identity $Identity
    $Context=Get-RustIdentityStorageContext -ServerRoot $ServerRoot -Identity $Identity
    $Path = Join-Path $Context.CarbonRoot 'modules\AutoWipe\config.json'
    if (-not (Test-Path -LiteralPath $Path)) { throw "Le module Carbon AutoWipe n'est pas installé." }
    $Config = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
    $Config.Enabled = $Enabled
    $Config.Config.WipeChatCommand = 'nextwipe'
    if ($Enabled) {
        $Wipe = [ordered]@{
            WipeName = 'Wipe planifie par Rust Server Control Center'
            MapBrowserName = 'Rust Server'
            MapUrl = if ($Profile.Type -eq 'Custom URL') { $Profile.LevelUrl } else { '' }
            MapSize = $Profile.WorldSize
            ServerSeed = $Profile.Seed
            Cron = $Cron
            Temp = $false
            'Type (0=fullwipe 1=mapwipe)' = if ($Type -eq 'full') { 0 } else { 1 }
            Commands = @('server.save')
        }
        $Config.Config.AvailableWipes = @($Wipe)
    }
    else {
        $Config.Config.AvailableWipes = @()
    }
    Write-Utf8File -Path $Path -Content ($Config | ConvertTo-Json -Depth 12)
    return $Path
}

# ----- Acces amis, IP dynamique et DDNS --------------------------------------

function Get-RustNetworkAccessConfigPath {
    param([Parameter(Mandatory = $true)][string]$ServerRoot)
    return Join-Path $ServerRoot 'data\network-access.json'
}

function Get-RustNetworkAddressStatePath {
    param([Parameter(Mandatory = $true)][string]$ServerRoot)
    return Join-Path $ServerRoot 'data\network-address-state.json'
}

function Get-RustDdnsSecretPath {
    param([Parameter(Mandatory = $true)][string]$ServerRoot)
    return Join-Path $ServerRoot 'data\ddns-credential.bin'
}

function New-RustNetworkAccessConfig {
    return [pscustomobject][ordered]@{
        schemaVersion = 1
        updatedUtc = [datetime]::UtcNow.ToString('o')
        ddns = [pscustomobject][ordered]@{
            enabled = $false
            provider = 'Disabled'
            hostname = ''
            username = ''
            intervalMinutes = 10
            lastUpdateUtc = ''
            lastStatus = 'Never'
            lastDetail = ''
            lastAddress = ''
        }
        access = [pscustomobject][ordered]@{
            mode = 'Direct'
            tunnelHost = ''
            tunnelPort = 0
            tunnelProvider = 'Custom UDP / playit.gg'
        }
    }
}

function Get-RustNetworkAccessConfig {
    param([Parameter(Mandatory = $true)][string]$ServerRoot)
    $Defaults = New-RustNetworkAccessConfig
    $Path = Get-RustNetworkAccessConfigPath -ServerRoot $ServerRoot
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $Defaults }
    try { $Config = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json }
    catch { throw 'Configuration reseau avancee illisible : ' + $_.Exception.Message }
    if (-not ($Config.PSObject.Properties.Name -contains 'schemaVersion')) { $Config | Add-Member schemaVersion 1 }
    if (-not ($Config.PSObject.Properties.Name -contains 'updatedUtc')) { $Config | Add-Member updatedUtc '' }
    if (-not ($Config.PSObject.Properties.Name -contains 'ddns') -or -not $Config.ddns) { $Config | Add-Member ddns $Defaults.ddns -Force }
    if (-not ($Config.PSObject.Properties.Name -contains 'access') -or -not $Config.access) { $Config | Add-Member access $Defaults.access -Force }
    foreach ($Name in $Defaults.ddns.PSObject.Properties.Name) {
        if (-not ($Config.ddns.PSObject.Properties.Name -contains $Name)) { $Config.ddns | Add-Member -NotePropertyName $Name -NotePropertyValue $Defaults.ddns.$Name }
    }
    foreach ($Name in $Defaults.access.PSObject.Properties.Name) {
        if (-not ($Config.access.PSObject.Properties.Name -contains $Name)) { $Config.access | Add-Member -NotePropertyName $Name -NotePropertyValue $Defaults.access.$Name }
    }
    return $Config
}

function Save-RustNetworkAccessConfig {
    param([Parameter(Mandatory = $true)][string]$ServerRoot,[Parameter(Mandatory = $true)]$Config)
    $Config.updatedUtc = [datetime]::UtcNow.ToString('o')
    $null = Save-RustJsonAtomic -Path (Get-RustNetworkAccessConfigPath -ServerRoot $ServerRoot) -Value $Config
    return $Config
}

function Set-RustDdnsCredential {
    param([Parameter(Mandatory = $true)][string]$ServerRoot,[Parameter(Mandatory = $true)][string]$Secret)
    if ([string]::IsNullOrWhiteSpace($Secret)) { throw 'Le jeton ou mot de passe DDNS est vide.' }
    Add-Type -AssemblyName System.Security
    $Plain = [Text.Encoding]::UTF8.GetBytes($Secret.Trim())
    $Protected = [Security.Cryptography.ProtectedData]::Protect($Plain,$null,[Security.Cryptography.DataProtectionScope]::CurrentUser)
    $Path = Get-RustDdnsSecretPath -ServerRoot $ServerRoot
    [IO.Directory]::CreateDirectory((Split-Path $Path -Parent)) | Out-Null
    [IO.File]::WriteAllBytes($Path,$Protected)
    return $Path
}

function Get-RustDdnsCredential {
    param([Parameter(Mandatory = $true)][string]$ServerRoot)
    $Path = Get-RustDdnsSecretPath -ServerRoot $ServerRoot
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return '' }
    Add-Type -AssemblyName System.Security
    try {
        $Plain = [Security.Cryptography.ProtectedData]::Unprotect([IO.File]::ReadAllBytes($Path),$null,[Security.Cryptography.DataProtectionScope]::CurrentUser)
        return [Text.Encoding]::UTF8.GetString($Plain)
    }
    catch { return '' }
}

function Set-RustNetworkAccessConfig {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$ServerRoot,
        [bool]$DdnsEnabled,
        [ValidateSet('Disabled','DuckDNS','NoIP')][string]$DdnsProvider = 'Disabled',
        [string]$DdnsHostname = '',
        [string]$DdnsUsername = '',
        [ValidateRange(5,1440)][int]$DdnsIntervalMinutes = 10,
        [ValidateSet('Direct','Tailscale','CustomUdp')][string]$AccessMode = 'Direct',
        [string]$TunnelHost = '',
        [ValidateRange(0,65535)][int]$TunnelPort = 0,
        [string]$TunnelProvider = 'Custom UDP / playit.gg'
    )
    $DdnsHostname = $DdnsHostname.Trim().TrimEnd('.')
    $DdnsUsername = $DdnsUsername.Trim()
    $TunnelHost = $TunnelHost.Trim().TrimEnd('.')
    if ($DdnsEnabled) {
        if ($DdnsProvider -eq 'Disabled') { throw 'Choisis DuckDNS ou No-IP.' }
        if ($DdnsHostname -notmatch '^[A-Za-z0-9](?:[A-Za-z0-9.-]{0,251}[A-Za-z0-9])?$') { throw 'Nom DDNS invalide.' }
        if ($DdnsProvider -eq 'DuckDNS' -and $DdnsHostname -notmatch '\.duckdns\.org$') { $DdnsHostname += '.duckdns.org' }
        if ($DdnsProvider -eq 'NoIP' -and -not $DdnsUsername) { throw 'Le nom utilisateur de la cle DDNS No-IP est requis.' }
    }
    if ($AccessMode -eq 'CustomUdp') {
        if ($TunnelHost -notmatch '^[A-Za-z0-9](?:[A-Za-z0-9.-]{0,251}[A-Za-z0-9])?$') { throw 'Hote public du tunnel UDP invalide.' }
        if ($TunnelPort -lt 1025) { throw 'Port public du tunnel UDP invalide.' }
    }
    $Config = Get-RustNetworkAccessConfig -ServerRoot $ServerRoot
    $Config.ddns.enabled = $DdnsEnabled
    $Config.ddns.provider = $DdnsProvider
    $Config.ddns.hostname = $DdnsHostname
    $Config.ddns.username = $DdnsUsername
    $Config.ddns.intervalMinutes = $DdnsIntervalMinutes
    $Config.access.mode = $AccessMode
    $Config.access.tunnelHost = $TunnelHost
    $Config.access.tunnelPort = $TunnelPort
    $Config.access.tunnelProvider = $TunnelProvider
    return Save-RustNetworkAccessConfig -ServerRoot $ServerRoot -Config $Config
}

function Get-RustPublicIpAddress {
    [CmdletBinding()]
    param([ValidateRange(2,30)][int]$TimeoutSeconds = 8)
    Add-Type -AssemblyName System.Net.Http -ErrorAction SilentlyContinue
    $Client = New-Object Net.Http.HttpClient
    try {
        $Client.Timeout = [TimeSpan]::FromSeconds($TimeoutSeconds)
        $Address = ([string]$Client.GetStringAsync('https://api.ipify.org').GetAwaiter().GetResult()).Trim()
        $Parsed = $null
        if (-not [Net.IPAddress]::TryParse($Address,[ref]$Parsed)) { throw 'Adresse publique invalide recue.' }
        return $Address
    }
    finally { $Client.Dispose() }
}

function Update-RustNetworkAddressState {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$ServerRoot,[string]$PublicIp = '')
    $Path = Get-RustNetworkAddressStatePath -ServerRoot $ServerRoot
    $Previous = $null
    if (Test-Path -LiteralPath $Path -PathType Leaf) { try { $Previous = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json } catch {} }
    $IpConfig = @(Get-NetIPConfiguration -ErrorAction SilentlyContinue | Where-Object { $_.NetAdapter.Status -eq 'Up' -and $_.IPv4Address -and $_.IPv4DefaultGateway }) | Select-Object -First 1
    if (-not $IpConfig) { throw 'Aucune interface IPv4 active avec passerelle.' }
    $LanIp = [string]$IpConfig.IPv4Address.IPAddress
    $Adapter = Get-NetAdapter -InterfaceIndex $IpConfig.InterfaceIndex -ErrorAction SilentlyContinue
    $CimConfig = @(Get-CimInstance Win32_NetworkAdapterConfiguration -Filter 'IPEnabled=True' -ErrorAction SilentlyContinue | Where-Object { [int]$_.InterfaceIndex -eq [int]$IpConfig.InterfaceIndex }) | Select-Object -First 1
    $DhcpEnabled = if ($CimConfig) { [bool]$CimConfig.DHCPEnabled } else { $true }
    $LeaseObtained = if ($CimConfig -and $CimConfig.DHCPLeaseObtained) { ([datetime]$CimConfig.DHCPLeaseObtained).ToUniversalTime().ToString('o') } else { '' }
    if (-not $PublicIp) { try { $PublicIp = Get-RustPublicIpAddress } catch {} }
    $AdapterId = if ($Adapter) { [string]$Adapter.InterfaceGuid } else { [string]$IpConfig.InterfaceAlias }
    $LanChanged = [bool]($Previous -and [string]$Previous.adapterId -eq $AdapterId -and [string]$Previous.lastLanIp -and [string]$Previous.lastLanIp -ne $LanIp)
    $PublicChanged = [bool]($Previous -and [string]$Previous.lastPublicIp -and $PublicIp -and [string]$Previous.lastPublicIp -ne $PublicIp)
    $Observations = @()
    if ($Previous -and $Previous.PSObject.Properties.Name -contains 'observations') { $Observations = @($Previous.observations) }
    $Observation = [pscustomobject][ordered]@{ observedUtc=[datetime]::UtcNow.ToString('o');adapterId=$AdapterId;lanIp=$LanIp;leaseObtainedUtc=$LeaseObtained }
    $Observations = @($Observation) + @($Observations | Where-Object { -not ([string]$_.adapterId -eq $AdapterId -and [string]$_.lanIp -eq $LanIp -and [string]$_.leaseObtainedUtc -eq $LeaseObtained) } | Select-Object -First 19)
    $LeaseCount = @($Observations | Where-Object { [string]$_.adapterId -eq $AdapterId -and [string]$_.lanIp -eq $LanIp -and [string]$_.leaseObtainedUtc } | Select-Object -ExpandProperty leaseObtainedUtc -Unique).Count
    $ReservationStatus = if (-not $DhcpEnabled) { 'Static' } elseif ($LanChanged) { 'Changed' } elseif ($LeaseCount -ge 2) { 'ProbableReservation' } else { 'Unknown' }
    $State = [pscustomobject][ordered]@{
        schemaVersion = 1
        updatedUtc = [datetime]::UtcNow.ToString('o')
        adapterId = $AdapterId
        adapterName = [string]$IpConfig.InterfaceAlias
        macAddress = if ($Adapter) { [string]$Adapter.MacAddress } else { '' }
        gateway = [string]$IpConfig.IPv4DefaultGateway.NextHop
        dhcpEnabled = $DhcpEnabled
        leaseObtainedUtc = $LeaseObtained
        lastLanIp = $LanIp
        previousLanIp = if ($LanChanged) { [string]$Previous.lastLanIp } elseif ($Previous) { [string]$Previous.previousLanIp } else { '' }
        lanChanged = $LanChanged
        lastPublicIp = $PublicIp
        previousPublicIp = if ($PublicChanged) { [string]$Previous.lastPublicIp } elseif ($Previous) { [string]$Previous.previousPublicIp } else { '' }
        publicChanged = $PublicChanged
        reservationStatus = $ReservationStatus
        observations = $Observations
    }
    $null = Save-RustJsonAtomic -Path $Path -Value $State
    return $State
}

function Find-RustTailscaleExecutable {
    [CmdletBinding()]
    param()
    $Candidates = New-Object 'Collections.Generic.List[string]'
    $Command = Get-Command tailscale.exe -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($Command -and [string]$Command.Source) { $Candidates.Add([string]$Command.Source) }
    foreach ($Base in @([string]$env:ProgramFiles,[string]${env:ProgramFiles(x86)},[string]$env:LOCALAPPDATA)) {
        if ($Base) { $Candidates.Add((Join-Path $Base 'Tailscale\tailscale.exe')) }
    }
    return [string](@($Candidates | Where-Object { $_ -and (Test-Path -LiteralPath $_ -PathType Leaf) } | Select-Object -Unique) | Select-Object -First 1)
}

function ConvertFrom-RustTailscaleStatusJson {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Json,
        [string]$Executable = '',
        [string]$ServiceStatus = 'Unknown'
    )
    try { $Status = $Json | ConvertFrom-Json }
    catch { throw 'La réponse de Tailscale est illisible : ' + $_.Exception.Message }

    $Addresses = @()
    if ($Status.PSObject.Properties.Name -contains 'TailscaleIPs') { $Addresses += @($Status.TailscaleIPs) }
    if ($Status.Self -and $Status.Self.PSObject.Properties.Name -contains 'TailscaleIPs') { $Addresses += @($Status.Self.TailscaleIPs) }
    $Addresses = @($Addresses | ForEach-Object { [string]$_ } | Where-Object { $_ } | Select-Object -Unique)
    $Ipv4 = [string](@($Addresses | Where-Object { $_ -match '^\d{1,3}(?:\.\d{1,3}){3}$' }) | Select-Object -First 1)
    $Ipv6 = [string](@($Addresses | Where-Object { $_ -match ':' }) | Select-Object -First 1)

    $Peers = @()
    if ($Status.Peer) {
        if ($Status.Peer -is [Collections.IDictionary]) { $Peers = @($Status.Peer.Values) }
        else { $Peers = @($Status.Peer.PSObject.Properties | ForEach-Object { $_.Value }) }
    }
    $OnlinePeers = @($Peers | Where-Object { $_ -and $_.PSObject.Properties.Name -contains 'Online' -and [bool]$_.Online })
    $BackendState = if ($Status.PSObject.Properties.Name -contains 'BackendState') { [string]$Status.BackendState } else { '' }
    $DnsName = if ($Status.Self) { [string]$Status.Self.DNSName } else { '' }
    $HostName = if ($Status.Self) { [string]$Status.Self.HostName } else { '' }
    $TailnetName = if ($Status.CurrentTailnet) { [string]$Status.CurrentTailnet.Name } else { '' }
    $UserName = ''
    if ($Status.Self -and $Status.Self.PSObject.Properties.Name -contains 'UserID' -and $Status.User) {
        $UserId = [string]$Status.Self.UserID
        $UserProperty = @($Status.User.PSObject.Properties | Where-Object { [string]$_.Name -eq $UserId }) | Select-Object -First 1
        if ($UserProperty -and $UserProperty.Value) { $UserName = [string]$UserProperty.Value.LoginName }
    }
    $Running = [bool]($BackendState -eq 'Running' -and $Ipv4)
    return [pscustomobject][ordered]@{
        Installed       = [bool]$Executable
        Running         = $Running
        NeedsLogin      = [bool]($BackendState -in @('NeedsLogin','NoState'))
        Executable      = $Executable
        ServiceStatus   = $ServiceStatus
        BackendState    = $BackendState
        IPv4            = $Ipv4
        IPv6            = $Ipv6
        DnsName         = $DnsName.TrimEnd('.')
        HostName        = $HostName
        TailnetName     = $TailnetName
        UserName        = $UserName
        PeerCount       = [int]$Peers.Count
        OnlinePeerCount = [int]$OnlinePeers.Count
        Version         = if ($Status.PSObject.Properties.Name -contains 'Version') { [string]$Status.Version } else { '' }
        LastError       = ''
    }
}

function Get-RustTailscaleStatus {
    [CmdletBinding()]
    param()
    $Exe = Find-RustTailscaleExecutable
    $Service = Get-Service -Name Tailscale -ErrorAction SilentlyContinue
    $ServiceStatus = if ($Service) { [string]$Service.Status } else { 'NotInstalled' }
    if (-not $Exe) {
        return [pscustomobject][ordered]@{Installed=$false;Running=$false;NeedsLogin=$false;Executable='';ServiceStatus=$ServiceStatus;BackendState='NotInstalled';IPv4='';IPv6='';DnsName='';HostName='';TailnetName='';UserName='';PeerCount=0;OnlinePeerCount=0;Version='';LastError=''}
    }
    try {
        $Json = (& $Exe status --json 2>&1) -join "`n"
        if (-not $Json.Trim()) { throw "Tailscale n'a renvoye aucun etat." }
        return ConvertFrom-RustTailscaleStatusJson -Json $Json -Executable $Exe -ServiceStatus $ServiceStatus
    }
    catch {
        return [pscustomobject][ordered]@{Installed=$true;Running=$false;NeedsLogin=$true;Executable=$Exe;ServiceStatus=$ServiceStatus;BackendState='Unavailable';IPv4='';IPv6='';DnsName='';HostName='';TailnetName='';UserName='';PeerCount=0;OnlinePeerCount=0;Version='';LastError=$_.Exception.Message}
    }
}

function Install-RustTailscale {
    [CmdletBinding()]
    param()
    $Existing = Find-RustTailscaleExecutable
    if ($Existing) { return [pscustomobject]@{AlreadyInstalled=$true;InstallerPath='';Process=$null} }
    $DownloadRoot = Join-Path ([IO.Path]::GetTempPath()) 'RustServerControlCenter\downloads'
    [IO.Directory]::CreateDirectory($DownloadRoot) | Out-Null
    $InstallerPath = Join-Path $DownloadRoot 'tailscale-setup-latest.exe'
    Add-Type -AssemblyName System.Net.Http -ErrorAction SilentlyContinue
    $Client = New-Object Net.Http.HttpClient
    try {
        $Client.Timeout = [TimeSpan]::FromMinutes(3)
        $Bytes = $Client.GetByteArrayAsync('https://pkgs.tailscale.com/stable/tailscale-setup-latest.exe').GetAwaiter().GetResult()
        if (-not $Bytes -or $Bytes.Length -lt 1MB) { throw "Le programme d'installation telecharge parait incomplet." }
        [IO.File]::WriteAllBytes($InstallerPath,$Bytes)
    }
    finally { $Client.Dispose() }
    $Signature = Get-AuthenticodeSignature -FilePath $InstallerPath
    $Signer = if ($Signature.SignerCertificate) { [string]$Signature.SignerCertificate.Subject } else { '' }
    if ([string]$Signature.Status -ne 'Valid' -or $Signer -notmatch '(?i)Tailscale') {
        Remove-Item -LiteralPath $InstallerPath -Force -ErrorAction SilentlyContinue
        throw "Signature du programme Tailscale refusée ($($Signature.Status))."
    }
    $Process = Start-Process -FilePath $InstallerPath -Verb RunAs -PassThru
    return [pscustomobject]@{AlreadyInstalled=$false;InstallerPath=$InstallerPath;Process=$Process;Signer=$Signer}
}

function Start-RustTailscaleLogin {
    [CmdletBinding()]
    param()
    $Exe = Find-RustTailscaleExecutable
    if (-not $Exe) { throw "Tailscale n'est pas installe." }
    # La commande officielle ouvre le navigateur d'authentification. Aucun jeton
    # Tailscale n'est demande ni conserve par le Control Center.
    return Start-Process -FilePath $Exe -ArgumentList @('login') -WindowStyle Hidden -PassThru
}

function Start-RustTailscaleUp {
    [CmdletBinding()]
    param()
    $Exe = Find-RustTailscaleExecutable
    if (-not $Exe) { throw "Tailscale n'est pas installe." }
    return Start-Process -FilePath $Exe -ArgumentList @('up','--unattended') -WindowStyle Hidden -PassThru
}

function Get-RustPreferredFriendEndpoint {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$ServerRoot,[Parameter(Mandatory = $true)]$Instance,[string]$PublicIp = '')
    $Config = Get-RustNetworkAccessConfig -ServerRoot $ServerRoot
    $HostName = ''
    $Port = [int]$Instance.serverPort
    $Source = 'Direct'
    switch ([string]$Config.access.mode) {
        'Tailscale' {
            $Tail = Get-RustTailscaleStatus
            $HostName = if ([string]$Tail.DnsName) { ([string]$Tail.DnsName).TrimEnd('.') } else { [string]$Tail.IPv4 }
            $Source = 'Tailscale'
        }
        'CustomUdp' {
            $HostName = [string]$Config.access.tunnelHost
            if ([int]$Config.access.tunnelPort -gt 0) { $Port = [int]$Config.access.tunnelPort }
            $Source = [string]$Config.access.tunnelProvider
        }
        default {
            if ([bool]$Config.ddns.enabled -and [string]$Config.ddns.lastStatus -eq 'Success' -and [string]$Config.ddns.hostname) { $HostName = [string]$Config.ddns.hostname; $Source = [string]$Config.ddns.provider }
            elseif ($PublicIp) { $HostName = $PublicIp }
            else {
                $StatePath = Get-RustNetworkAddressStatePath -ServerRoot $ServerRoot
                if (Test-Path -LiteralPath $StatePath) { try { $HostName = [string](Get-Content $StatePath -Raw -Encoding UTF8 | ConvertFrom-Json).lastPublicIp } catch {} }
            }
        }
    }
    $Command = if ($HostName) { "client.connect ${HostName}:$Port" } else { "client.connect ADRESSE_IP:$Port" }
    return [pscustomobject]@{Mode=[string]$Config.access.mode;Source=$Source;Host=$HostName;Port=$Port;Command=$Command}
}

function Update-RustFriendConnectionDocument {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$ServerRoot,[Parameter(Mandatory = $true)]$Instance,[Parameter(Mandatory = $true)]$AddressState)
    $Endpoint = Get-RustPreferredFriendEndpoint -ServerRoot $ServerRoot -Instance $Instance -PublicIp ([string]$AddressState.lastPublicIp)
    $Lines = @(
        'RUST SERVER CONTROL CENTER - CONNEXION AMIS',
        '==============================================',
        '',
        'Commande a partager :',
        [string]$Endpoint.Command,
        '',
        ('Mode : ' + [string]$Endpoint.Source),
        ('IP locale actuelle : ' + [string]$AddressState.lastLanIp),
        ('IP publique actuelle : ' + [string]$AddressState.lastPublicIp),
        ('Port jeu local : UDP ' + [int]$Instance.serverPort),
        ('Port requetes local : UDP ' + [int]$Instance.queryPort),
        '',
        'Connexion depuis ce PC :',
        ('client.connect 127.0.0.1:' + [int]$Instance.serverPort),
        '',
        'Ne jamais ouvrir le port RCON TCP ' + [int]$Instance.rconPort + '.',
        'Tailscale exige que chaque ami installe le client et accepte le partage.',
        'Un tunnel UDP ajoute un relais et peut donc augmenter le ping.'
    )
    $Path = Join-Path $ServerRoot 'CONNEXION-AMIS.txt'
    Write-Utf8File -Path $Path -Content ($Lines -join [Environment]::NewLine)
    return [pscustomobject]@{Path=$Path;Endpoint=$Endpoint}
}

function Invoke-RustDdnsUpdate {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$ServerRoot,[string]$PublicIp = '')
    $Config = Get-RustNetworkAccessConfig -ServerRoot $ServerRoot
    if (-not [bool]$Config.ddns.enabled) { return [pscustomobject]@{Success=$false;Skipped=$true;Detail='DDNS desactive.';Address=''} }
    $Credential = Get-RustDdnsCredential -ServerRoot $ServerRoot
    if (-not $Credential) { throw 'Secret DDNS absent ou illisible pour ce compte Windows.' }
    if (-not $PublicIp) { $PublicIp = Get-RustPublicIpAddress }
    Add-Type -AssemblyName System.Net.Http -ErrorAction SilentlyContinue
    $Client = New-Object Net.Http.HttpClient
    try {
        $Client.Timeout = [TimeSpan]::FromSeconds(12)
        if ([string]$Config.ddns.provider -eq 'DuckDNS') {
            $Domain = ([string]$Config.ddns.hostname -replace '(?i)\.duckdns\.org$','')
            $Uri = 'https://www.duckdns.org/update?domains=' + [Uri]::EscapeDataString($Domain) + '&token=' + [Uri]::EscapeDataString($Credential) + '&ip=' + [Uri]::EscapeDataString($PublicIp) + '&verbose=true'
            $Response = [string]$Client.GetStringAsync($Uri).GetAwaiter().GetResult()
            $Success = $Response.Trim().StartsWith('OK',[StringComparison]::OrdinalIgnoreCase)
        }
        elseif ([string]$Config.ddns.provider -eq 'NoIP') {
            $Pair = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes(([string]$Config.ddns.username + ':' + $Credential)))
            $Client.DefaultRequestHeaders.Authorization = [Net.Http.Headers.AuthenticationHeaderValue]::new('Basic',$Pair)
            $Client.DefaultRequestHeaders.UserAgent.ParseAdd('RustServerControlCenter/12.0-Windows local-ddns-client')
            $Uri = 'https://dynupdate.no-ip.com/nic/update?hostname=' + [Uri]::EscapeDataString([string]$Config.ddns.hostname) + '&myip=' + [Uri]::EscapeDataString($PublicIp)
            $Response = [string]$Client.GetStringAsync($Uri).GetAwaiter().GetResult()
            $Success = $Response.Trim() -match '^(good|nochg)\b'
        }
        else { throw 'Fournisseur DDNS non pris en charge.' }
        if (-not $Success) { throw ('Le fournisseur DDNS a refuse la mise a jour : ' + $Response.Trim()) }
        $Config.ddns.lastUpdateUtc = [datetime]::UtcNow.ToString('o')
        $Config.ddns.lastStatus = 'Success'
        $Config.ddns.lastDetail = $Response.Trim()
        $Config.ddns.lastAddress = $PublicIp
        $null = Save-RustNetworkAccessConfig -ServerRoot $ServerRoot -Config $Config
        $State = Update-RustNetworkAddressState -ServerRoot $ServerRoot -PublicIp $PublicIp
        $Instance = @((Get-RustInstanceCatalog -ServerRoot $ServerRoot).instances | Where-Object isPublic) | Select-Object -First 1
        if ($Instance) { $null = Update-RustFriendConnectionDocument -ServerRoot $ServerRoot -Instance $Instance -AddressState $State }
        return [pscustomobject]@{Success=$true;Skipped=$false;Detail=$Response.Trim();Address=$PublicIp;Hostname=[string]$Config.ddns.hostname}
    }
    catch {
        $Config.ddns.lastUpdateUtc = [datetime]::UtcNow.ToString('o')
        $Config.ddns.lastStatus = 'Failed'
        $Config.ddns.lastDetail = $_.Exception.Message
        $null = Save-RustNetworkAccessConfig -ServerRoot $ServerRoot -Config $Config
        throw
    }
    finally { $Client.Dispose() }
}

# ----- Centre des operations -------------------------------------------------
# Etat volontairement stocke hors de l'interface : les taches et leur
# historique restent disponibles apres fermeture ou mise a jour du dashboard.

function Get-RustOperationStorePath {
    param([Parameter(Mandatory = $true)][string]$ServerRoot)
    return Join-Path $ServerRoot 'data\operation-center.json'
}

function New-RustOperationStore {
    return [pscustomobject]@{
        schemaVersion     = 1
        activeOperationId = ''
        operations        = @()
    }
}

function Get-RustOperationStore {
    param([Parameter(Mandatory = $true)][string]$ServerRoot)
    $Path = Get-RustOperationStorePath -ServerRoot $ServerRoot
    if (-not (Test-Path -LiteralPath $Path)) { return New-RustOperationStore }
    try { $Store = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json }
    catch { throw 'Historique des operations illisible : ' + $_.Exception.Message }
    if (-not ($Store.PSObject.Properties.Name -contains 'schemaVersion')) { $Store | Add-Member -NotePropertyName schemaVersion -NotePropertyValue 1 }
    if (-not ($Store.PSObject.Properties.Name -contains 'activeOperationId')) { $Store | Add-Member -NotePropertyName activeOperationId -NotePropertyValue '' }
    if (-not ($Store.PSObject.Properties.Name -contains 'operations')) { $Store | Add-Member -NotePropertyName operations -NotePropertyValue @() }
    $Store.operations = @($Store.operations)
    return $Store
}

function Save-RustOperationStore {
    param(
        [Parameter(Mandatory = $true)][string]$ServerRoot,
        [Parameter(Mandatory = $true)]$Store
    )
    $Path = Get-RustOperationStorePath -ServerRoot $ServerRoot
    $Directory = Split-Path $Path -Parent
    New-Item -ItemType Directory -Path $Directory -Force | Out-Null
    $Store.operations = @($Store.operations | Sort-Object startedUtc -Descending | Select-Object -First 150)
    $TemporaryPath = $Path + '.tmp'
    Write-Utf8File -Path $TemporaryPath -Content ($Store | ConvertTo-Json -Depth 20)
    try {
        if (Test-Path -LiteralPath $Path) { [IO.File]::Replace($TemporaryPath,$Path,$null) }
        else { [IO.File]::Move($TemporaryPath,$Path) }
    }
    catch {
        Move-Item -LiteralPath $TemporaryPath -Destination $Path -Force
    }
    return $Path
}

function Get-RustTrackedOperations {
    param([Parameter(Mandatory = $true)][string]$ServerRoot)
    return @((Get-RustOperationStore -ServerRoot $ServerRoot).operations | Sort-Object startedUtc -Descending)
}

function Get-RustActiveTrackedOperation {
    param([Parameter(Mandatory = $true)][string]$ServerRoot)
    $Store = Get-RustOperationStore -ServerRoot $ServerRoot
    $Active = @($Store.operations | Where-Object { [string]$_.id -eq [string]$Store.activeOperationId -and [string]$_.status -eq 'Running' }) | Select-Object -First 1
    if (-not $Active) { $Active = @($Store.operations | Where-Object status -eq 'Running' | Sort-Object startedUtc -Descending) | Select-Object -First 1 }
    return $Active
}

function New-RustTrackedOperation {
    param(
        [Parameter(Mandatory = $true)][string]$ServerRoot,
        [Parameter(Mandatory = $true)][string]$Type,
        [Parameter(Mandatory = $true)][string]$Title,
        [string]$ServerId = '',
        [string]$Stage = 'PREPARATION',
        [string]$Detail = '',
        [string]$RetryAction = '',
        [bool]$CanCancel = $false,
        [string]$LogPath = '',
        [string]$ErrorLogPath = '',
        [int]$ProcessId = 0,
        $Metadata = $null
    )
    $Store = Get-RustOperationStore -ServerRoot $ServerRoot
    $Now = (Get-Date).ToUniversalTime().ToString('o')
    $Operation = [pscustomobject]@{
        id                = [guid]::NewGuid().ToString('N')
        type              = $Type
        title             = $Title
        serverId          = $ServerId
        status            = 'Running'
        progress          = 1.0
        stage             = $Stage
        detail            = $Detail
        startedUtc        = $Now
        completedUtc      = ''
        durationSeconds   = 0
        logPath           = $LogPath
        errorLogPath      = $ErrorLogPath
        processId         = $ProcessId
        retryAction       = $RetryAction
        canCancel         = $CanCancel
        notificationShown = $false
        metadata          = $Metadata
    }
    $Store.operations = @($Operation) + @($Store.operations)
    $Store.activeOperationId = [string]$Operation.id
    $null = Save-RustOperationStore -ServerRoot $ServerRoot -Store $Store
    return $Operation
}

function Update-RustTrackedOperation {
    param(
        [Parameter(Mandatory = $true)][string]$ServerRoot,
        [Parameter(Mandatory = $true)][string]$Id,
        [Parameter(Mandatory = $true)][hashtable]$Changes
    )
    $Store = Get-RustOperationStore -ServerRoot $ServerRoot
    $Operation = @($Store.operations | Where-Object id -eq $Id) | Select-Object -First 1
    if (-not $Operation) { throw "Operation '$Id' introuvable." }
    foreach ($Name in $Changes.Keys) {
        if ($Operation.PSObject.Properties.Name -contains $Name) { $Operation.$Name = $Changes[$Name] }
        else { $Operation | Add-Member -NotePropertyName $Name -NotePropertyValue $Changes[$Name] }
    }
    if ([string]$Operation.status -eq 'Running') { $Store.activeOperationId = [string]$Operation.id }
    $null = Save-RustOperationStore -ServerRoot $ServerRoot -Store $Store
    return $Operation
}

function Complete-RustTrackedOperation {
    param(
        [Parameter(Mandatory = $true)][string]$ServerRoot,
        [Parameter(Mandatory = $true)][string]$Id,
        [Parameter(Mandatory = $true)][ValidateSet('Succeeded','Failed','Cancelled','Interrupted')][string]$Status,
        [string]$Stage = '',
        [string]$Detail = ''
    )
    $Store = Get-RustOperationStore -ServerRoot $ServerRoot
    $Operation = @($Store.operations | Where-Object id -eq $Id) | Select-Object -First 1
    if (-not $Operation) { throw "Operation '$Id' introuvable." }
    $Completed = (Get-Date).ToUniversalTime()
    try { $Started = [datetime]::Parse([string]$Operation.startedUtc).ToUniversalTime() }
    catch { $Started = $Completed }
    $Operation.status = $Status
    $Operation.completedUtc = $Completed.ToString('o')
    $Operation.durationSeconds = [math]::Max(0,[int]($Completed - $Started).TotalSeconds)
    $Operation.processId = 0
    $Operation.canCancel = $false
    if ($Stage) { $Operation.stage = $Stage }
    if ($Detail) { $Operation.detail = $Detail }
    if ($Status -eq 'Succeeded') { $Operation.progress = 100.0 }
    elseif ([double]$Operation.progress -ge 100) { $Operation.progress = 95.0 }
    if ([string]$Store.activeOperationId -eq $Id) {
        $Next = @($Store.operations | Where-Object { [string]$_.status -eq 'Running' -and [string]$_.id -ne $Id } | Sort-Object startedUtc -Descending) | Select-Object -First 1
        $Store.activeOperationId = if ($Next) { [string]$Next.id } else { '' }
    }
    $null = Save-RustOperationStore -ServerRoot $ServerRoot -Store $Store
    return $Operation
}

function Set-RustOperationNotificationShown {
    param([Parameter(Mandatory = $true)][string]$ServerRoot,[Parameter(Mandatory = $true)][string]$Id)
    return Update-RustTrackedOperation -ServerRoot $ServerRoot -Id $Id -Changes @{ notificationShown = $true }
}

# ----- Planification des wipes et sauvegardes -------------------------------
# Le moteur est independant de Carbon : une installation vanilla peut donc
# planifier des sauvegardes et des wipes. Les dates sont stockees en UTC, puis
# presentees dans le fuseau local de Windows par l'interface.

function Get-RustMaintenanceScheduleStorePath {
    param([Parameter(Mandatory = $true)][string]$ServerRoot)
    return Join-Path $ServerRoot 'data\maintenance-schedules.json'
}

function New-RustMaintenanceScheduleStore {
    return [pscustomobject]@{
        schemaVersion = 2
        updatedUtc    = (Get-Date).ToUniversalTime().ToString('o')
        schedules     = @()
    }
}

function Get-RustMaintenanceScheduleStore {
    param([Parameter(Mandatory = $true)][string]$ServerRoot)
    $Path = Get-RustMaintenanceScheduleStorePath -ServerRoot $ServerRoot
    if (-not (Test-Path -LiteralPath $Path)) { return New-RustMaintenanceScheduleStore }
    try { $Store = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json }
    catch { throw 'Planning de maintenance illisible : ' + $_.Exception.Message }
    if (-not ($Store.PSObject.Properties.Name -contains 'schemaVersion')) { $Store | Add-Member -NotePropertyName schemaVersion -NotePropertyValue 1 }
    if (-not ($Store.PSObject.Properties.Name -contains 'updatedUtc')) { $Store | Add-Member -NotePropertyName updatedUtc -NotePropertyValue '' }
    if (-not ($Store.PSObject.Properties.Name -contains 'schedules')) { $Store | Add-Member -NotePropertyName schedules -NotePropertyValue @() }
    $Store.schedules = @($Store.schedules)
    foreach ($Schedule in $Store.schedules) {
        if (-not ($Schedule.PSObject.Properties.Name -contains 'retentionCount')) { $Schedule | Add-Member -NotePropertyName retentionCount -NotePropertyValue 10 }
    }
    $Store.schemaVersion = 2
    return $Store
}

function Save-RustMaintenanceScheduleStore {
    param(
        [Parameter(Mandatory = $true)][string]$ServerRoot,
        [Parameter(Mandatory = $true)]$Store
    )
    $Path = Get-RustMaintenanceScheduleStorePath -ServerRoot $ServerRoot
    $Directory = Split-Path $Path -Parent
    New-Item -ItemType Directory -Path $Directory -Force | Out-Null
    $Store.updatedUtc = (Get-Date).ToUniversalTime().ToString('o')
    $Store.schedules = @($Store.schedules)
    $TemporaryPath = $Path + '.tmp'
    Write-Utf8File -Path $TemporaryPath -Content ($Store | ConvertTo-Json -Depth 20)
    try {
        if (Test-Path -LiteralPath $Path) { [IO.File]::Replace($TemporaryPath,$Path,$null) }
        else { [IO.File]::Move($TemporaryPath,$Path) }
    }
    catch { Move-Item -LiteralPath $TemporaryPath -Destination $Path -Force }
    return $Path
}

function Invoke-WithRustMaintenanceLock {
    param([Parameter(Mandatory = $true)][scriptblock]$ScriptBlock)
    $Created = $false
    $Mutex = [Threading.Mutex]::new($false,'Local\RustRPGMaintenanceScheduleStore',[ref]$Created)
    $Acquired = $false
    try {
        try { $Acquired = $Mutex.WaitOne([TimeSpan]::FromSeconds(15)) }
        catch [Threading.AbandonedMutexException] { $Acquired = $true }
        if (-not $Acquired) { throw 'Le planning est utilise par une autre operation. Reessaie dans quelques secondes.' }
        return & $ScriptBlock
    }
    finally {
        if ($Acquired) { try { $Mutex.ReleaseMutex() } catch {} }
        $Mutex.Dispose()
    }
}

function ConvertTo-RustMaintenanceUtc {
    param([Parameter(Mandatory = $true)][datetime]$Date)
    if ($Date.Kind -eq [DateTimeKind]::Utc) { return $Date }
    if ($Date.Kind -eq [DateTimeKind]::Unspecified) { return [TimeZoneInfo]::ConvertTimeToUtc($Date,[TimeZoneInfo]::Local) }
    return $Date.ToUniversalTime()
}

function Get-RustMaintenanceNextRunUtc {
    param(
        [Parameter(Mandatory = $true)][ValidateSet('Daily','Weekly','Interval')][string]$Recurrence,
        [string]$LocalTime = '04:00',
        [ValidateSet('Monday','Tuesday','Wednesday','Thursday','Friday','Saturday','Sunday')][string]$DayOfWeek = 'Thursday',
        [ValidateRange(1,720)][int]$IntervalHours = 24,
        [datetime]$FromUtc = ([datetime]::UtcNow)
    )
    $From = (ConvertTo-RustMaintenanceUtc $FromUtc).ToLocalTime()
    if ($Recurrence -eq 'Interval') { return (ConvertTo-RustMaintenanceUtc $From).AddHours($IntervalHours) }

    $ParsedTime = [datetime]::MinValue
    if (-not [datetime]::TryParseExact($LocalTime,'HH:mm',[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::None,[ref]$ParsedTime)) {
        throw "Heure invalide : utilise le format HH:mm, par exemple 04:00."
    }
    $Candidate = [datetime]::SpecifyKind($From.Date.AddHours($ParsedTime.Hour).AddMinutes($ParsedTime.Minute),[DateTimeKind]::Unspecified)
    if ($Recurrence -eq 'Daily') {
        if ($Candidate -le $From) { $Candidate = $Candidate.AddDays(1) }
    }
    else {
        $WantedDay = [DayOfWeek]::$DayOfWeek
        $Delta = (([int]$WantedDay - [int]$Candidate.DayOfWeek) + 7) % 7
        $Candidate = $Candidate.AddDays($Delta)
        if ($Candidate -le $From) { $Candidate = $Candidate.AddDays(7) }
    }
    return ConvertTo-RustMaintenanceUtc $Candidate
}

function Assert-RustMaintenanceScheduleValues {
    param(
        [Parameter(Mandatory = $true)][string]$ServerRoot,
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$Identity,
        [Parameter(Mandatory = $true)][ValidateSet('Backup','MapWipe','FullWipe')][string]$Action,
        [Parameter(Mandatory = $true)][ValidateSet('Daily','Weekly','Interval')][string]$Recurrence,
        [string]$LocalTime,
        [string]$DayOfWeek,
        [int]$IntervalHours
    )
    if ([string]::IsNullOrWhiteSpace($Name)) { throw 'Donne un nom a la regle.' }
    if ($Name.Trim().Length -gt 80) { throw 'Le nom de la regle est trop long (80 caracteres maximum).' }
    Assert-RustIdentity $Identity
    if (-not (Get-RustServerInstance -ServerRoot $ServerRoot -Identity $Identity)) { throw "Serveur '$Identity' introuvable." }
    if ($Recurrence -eq 'Interval' -and ($IntervalHours -lt 1 -or $IntervalHours -gt 720)) { throw "L'intervalle doit etre compris entre 1 et 720 heures." }
    if ($Recurrence -ne 'Interval') {
        $Parsed = [datetime]::MinValue
        if (-not [datetime]::TryParseExact($LocalTime,'HH:mm',[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::None,[ref]$Parsed)) { throw 'Heure invalide : utilise HH:mm.' }
    }
    if ($Recurrence -eq 'Weekly' -and $DayOfWeek -notin @('Monday','Tuesday','Wednesday','Thursday','Friday','Saturday','Sunday')) { throw 'Jour hebdomadaire invalide.' }
}

function Set-RustMaintenanceSchedule {
    param(
        [Parameter(Mandatory = $true)][string]$ServerRoot,
        [string]$Id = '',
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$Identity,
        [Parameter(Mandatory = $true)][ValidateSet('Backup','MapWipe','FullWipe')][string]$Action,
        [Parameter(Mandatory = $true)][ValidateSet('Daily','Weekly','Interval')][string]$Recurrence,
        [string]$LocalTime = '04:00',
        [ValidateSet('Monday','Tuesday','Wednesday','Thursday','Friday','Saturday','Sunday')][string]$DayOfWeek = 'Thursday',
        [ValidateRange(1,720)][int]$IntervalHours = 24,
        [ValidateRange(2,100)][int]$RetentionCount = 10,
        [bool]$Enabled = $true,
        [bool]$StopAndRestart = $false,
        [bool]$ResetPluginData = $false,
        [bool]$CleanGeneratedMaps = $true
    )
    Assert-RustMaintenanceScheduleValues -ServerRoot $ServerRoot -Name $Name -Identity $Identity -Action $Action -Recurrence $Recurrence -LocalTime $LocalTime -DayOfWeek $DayOfWeek -IntervalHours $IntervalHours
    return Invoke-WithRustMaintenanceLock {
        $Store = Get-RustMaintenanceScheduleStore -ServerRoot $ServerRoot
        $Existing = if ($Id) { @($Store.schedules | Where-Object id -eq $Id) | Select-Object -First 1 } else { $null }
        $Now = [datetime]::UtcNow
        $Next = Get-RustMaintenanceNextRunUtc -Recurrence $Recurrence -LocalTime $LocalTime -DayOfWeek $DayOfWeek -IntervalHours $IntervalHours -FromUtc $Now
        if ($Existing) {
            $Existing.name = $Name.Trim()
            $Existing.identity = $Identity
            $Existing.action = $Action
            $Existing.recurrence = $Recurrence
            $Existing.localTime = $LocalTime
            $Existing.dayOfWeek = $DayOfWeek
            $Existing.intervalHours = $IntervalHours
            $Existing.retentionCount = $RetentionCount
            $Existing.enabled = $Enabled
            $Existing.stopAndRestart = $StopAndRestart
            $Existing.resetPluginData = $ResetPluginData
            $Existing.cleanGeneratedMaps = $CleanGeneratedMaps
            $Existing.nextRunUtc = $Next.ToString('o')
            $Existing.updatedUtc = $Now.ToString('o')
            $Schedule = $Existing
        }
        else {
            $Schedule = [pscustomobject]@{
                id                 = [guid]::NewGuid().ToString('N')
                name               = $Name.Trim()
                identity           = $Identity
                action             = $Action
                recurrence         = $Recurrence
                localTime          = $LocalTime
                dayOfWeek          = $DayOfWeek
                intervalHours      = $IntervalHours
                retentionCount     = $RetentionCount
                enabled            = $Enabled
                stopAndRestart     = $StopAndRestart
                resetPluginData    = $ResetPluginData
                cleanGeneratedMaps = $CleanGeneratedMaps
                nextRunUtc         = $Next.ToString('o')
                lastRunUtc         = ''
                lastStatus         = 'Never'
                lastDetail         = ''
                lastOperationId    = ''
                createdUtc         = $Now.ToString('o')
                updatedUtc         = $Now.ToString('o')
            }
            $Store.schedules = @($Store.schedules) + @($Schedule)
        }
        $null = Save-RustMaintenanceScheduleStore -ServerRoot $ServerRoot -Store $Store
        return $Schedule
    }
}

function Remove-RustMaintenanceSchedule {
    param([Parameter(Mandatory = $true)][string]$ServerRoot,[Parameter(Mandatory = $true)][string]$Id)
    return Invoke-WithRustMaintenanceLock {
        $Store = Get-RustMaintenanceScheduleStore -ServerRoot $ServerRoot
        if (-not @($Store.schedules | Where-Object id -eq $Id).Count) { throw "Regle '$Id' introuvable." }
        $Store.schedules = @($Store.schedules | Where-Object id -ne $Id)
        $null = Save-RustMaintenanceScheduleStore -ServerRoot $ServerRoot -Store $Store
        return $true
    }
}

function Set-RustMaintenanceScheduleEnabled {
    param([Parameter(Mandatory = $true)][string]$ServerRoot,[Parameter(Mandatory = $true)][string]$Id,[bool]$Enabled)
    return Invoke-WithRustMaintenanceLock {
        $Store = Get-RustMaintenanceScheduleStore -ServerRoot $ServerRoot
        $Schedule = @($Store.schedules | Where-Object id -eq $Id) | Select-Object -First 1
        if (-not $Schedule) { throw "Regle '$Id' introuvable." }
        $Schedule.enabled = $Enabled
        $Schedule.updatedUtc = [datetime]::UtcNow.ToString('o')
        if ($Enabled) {
            $Schedule.nextRunUtc = (Get-RustMaintenanceNextRunUtc -Recurrence ([string]$Schedule.recurrence) -LocalTime ([string]$Schedule.localTime) -DayOfWeek ([string]$Schedule.dayOfWeek) -IntervalHours ([int]$Schedule.intervalHours)).ToString('o')
        }
        $null = Save-RustMaintenanceScheduleStore -ServerRoot $ServerRoot -Store $Store
        return $Schedule
    }
}

function Get-RustDueMaintenanceSchedules {
    param([Parameter(Mandatory = $true)][string]$ServerRoot,[datetime]$AtUtc = ([datetime]::UtcNow))
    $At = ConvertTo-RustMaintenanceUtc $AtUtc
    $Store = Get-RustMaintenanceScheduleStore -ServerRoot $ServerRoot
    return @($Store.schedules | Where-Object {
        if (-not [bool]$_.enabled -or [string]::IsNullOrWhiteSpace([string]$_.nextRunUtc)) { return $false }
        try { return ([datetime]::Parse([string]$_.nextRunUtc).ToUniversalTime() -le $At) } catch { return $false }
    } | Sort-Object nextRunUtc)
}

function Set-RustMaintenanceScheduleResult {
    param(
        [Parameter(Mandatory = $true)][string]$ServerRoot,
        [Parameter(Mandatory = $true)][string]$Id,
        [Parameter(Mandatory = $true)][ValidateSet('Succeeded','Deferred','Failed')][string]$Status,
        [string]$Detail = '',
        [string]$OperationId = '',
        [ValidateRange(1,1440)][int]$DeferMinutes = 15
    )
    return Invoke-WithRustMaintenanceLock {
        $Store = Get-RustMaintenanceScheduleStore -ServerRoot $ServerRoot
        $Schedule = @($Store.schedules | Where-Object id -eq $Id) | Select-Object -First 1
        if (-not $Schedule) { throw "Regle '$Id' introuvable." }
        $Now = [datetime]::UtcNow
        $Schedule.lastRunUtc = $Now.ToString('o')
        $Schedule.lastStatus = $Status
        $Schedule.lastDetail = $Detail
        $Schedule.lastOperationId = $OperationId
        $Schedule.updatedUtc = $Now.ToString('o')
        if ($Status -eq 'Deferred') { $Schedule.nextRunUtc = $Now.AddMinutes($DeferMinutes).ToString('o') }
        elseif ($Status -eq 'Failed') { $Schedule.enabled = $false }
        else {
            $Schedule.nextRunUtc = (Get-RustMaintenanceNextRunUtc -Recurrence ([string]$Schedule.recurrence) -LocalTime ([string]$Schedule.localTime) -DayOfWeek ([string]$Schedule.dayOfWeek) -IntervalHours ([int]$Schedule.intervalHours) -FromUtc $Now).ToString('o')
        }
        $null = Save-RustMaintenanceScheduleStore -ServerRoot $ServerRoot -Store $Store
        return $Schedule
    }
}

function Get-RustMaintenanceTaskName { return 'Rust Server Control Center - Maintenance' }

function Get-RustMaintenanceTaskStatus {
    param([Parameter(Mandatory = $true)][string]$ServerRoot)
    $TaskName = Get-RustMaintenanceTaskName
    try {
        $Task = Get-ScheduledTask -TaskName $TaskName -ErrorAction Stop
        $Info = Get-ScheduledTaskInfo -TaskName $TaskName -ErrorAction SilentlyContinue
        return [pscustomobject]@{ Installed=$true; State=[string]$Task.State; LastRunTime=if($Info){$Info.LastRunTime}else{$null}; NextRunTime=if($Info){$Info.NextRunTime}else{$null} }
    }
    catch { return [pscustomobject]@{ Installed=$false; State='NotInstalled'; LastRunTime=$null; NextRunTime=$null } }
}

function Register-RustMaintenanceTask {
    param([Parameter(Mandatory = $true)][string]$ServerRoot)
    $WorkerPath = Join-Path $ServerRoot 'tool\RustRPG-MaintenanceWorker.ps1'
    if (-not (Test-Path -LiteralPath $WorkerPath)) { throw 'Le moteur de maintenance est introuvable.' }
    $PowerShellExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $Arguments = '-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File "' + $WorkerPath + '" -ServerRoot "' + $ServerRoot + '"'
    $Action = New-ScheduledTaskAction -Execute $PowerShellExe -Argument $Arguments -WorkingDirectory $ServerRoot
    $Trigger = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(1) -RepetitionInterval ([TimeSpan]::FromMinutes(1)) -RepetitionDuration ([TimeSpan]::FromDays(3650))
    $UserId = [Security.Principal.WindowsIdentity]::GetCurrent().Name
    $Principal = New-ScheduledTaskPrincipal -UserId $UserId -LogonType Interactive -RunLevel Limited
    $Settings = New-ScheduledTaskSettingsSet -MultipleInstances IgnoreNew -StartWhenAvailable -ExecutionTimeLimit ([TimeSpan]::FromHours(6))
    Register-ScheduledTask -TaskName (Get-RustMaintenanceTaskName) -Action $Action -Trigger $Trigger -Principal $Principal -Settings $Settings -Description 'Execute les sauvegardes et wipes planifies par Rust Server Control Center.' -Force | Out-Null
    return Get-RustMaintenanceTaskStatus -ServerRoot $ServerRoot
}

function Unregister-RustMaintenanceTask {
    param([Parameter(Mandatory = $true)][string]$ServerRoot)
    if ((Get-RustMaintenanceTaskStatus -ServerRoot $ServerRoot).Installed) {
        Unregister-ScheduledTask -TaskName (Get-RustMaintenanceTaskName) -Confirm:$false
    }
    return Get-RustMaintenanceTaskStatus -ServerRoot $ServerRoot
}

# ----- Etat, migrations et diagnostic global -------------------------------

function Save-RustJsonAtomic {
    param([Parameter(Mandatory = $true)][string]$Path,[Parameter(Mandatory = $true)]$Value,[int]$Depth = 20)
    $Directory = Split-Path $Path -Parent
    if ($Directory) { [IO.Directory]::CreateDirectory($Directory) | Out-Null }
    $TemporaryPath = $Path + '.tmp-' + [guid]::NewGuid().ToString('N')
    Write-Utf8File -Path $TemporaryPath -Content ($Value | ConvertTo-Json -Depth $Depth)
    try {
        if (Test-Path -LiteralPath $Path) { [IO.File]::Replace($TemporaryPath,$Path,$null) }
        else { [IO.File]::Move($TemporaryPath,$Path) }
    }
    catch {
        if (Test-Path -LiteralPath $TemporaryPath) { Move-Item -LiteralPath $TemporaryPath -Destination $Path -Force }
        else { throw }
    }
    return $Path
}

function Get-RustControlCenterStatePath {
    param([Parameter(Mandatory = $true)][string]$ServerRoot)
    return Join-Path $ServerRoot 'data\control-center-state.json'
}

function Get-RustControlCenterState {
    param([Parameter(Mandatory = $true)][string]$ServerRoot)
    $Path = Get-RustControlCenterStatePath -ServerRoot $ServerRoot
    if (Test-Path -LiteralPath $Path) {
        try { $State = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json }
        catch { throw 'Etat du Control Center illisible : ' + $_.Exception.Message }
    }
    else {
        $AlreadyInstalled = Test-Path -LiteralPath (Join-Path $ServerRoot 'server\RustDedicated.exe') -PathType Leaf
        $State = [pscustomobject][ordered]@{
            schemaVersion       = 1
            onboardingCompleted = [bool]$AlreadyInstalled
            onboardingDismissed = $false
            lastDiagnosticUtc   = ''
            releaseRepository   = ''
            releaseChannel      = 'stable'
            preferredEnvironment = 'vanilla'
            automaticUpdateCheck = $true
            lastUpdateCheckUtc   = ''
            lastAvailableVersion = ''
        }
    }
    foreach ($Default in @{schemaVersion=1;onboardingCompleted=$false;onboardingDismissed=$false;lastDiagnosticUtc='';releaseRepository='';releaseChannel='stable';preferredEnvironment='vanilla';automaticUpdateCheck=$true;lastUpdateCheckUtc='';lastAvailableVersion=''}.GetEnumerator()) {
        if (-not ($State.PSObject.Properties.Name -contains $Default.Key)) { $State | Add-Member -NotePropertyName $Default.Key -NotePropertyValue $Default.Value }
    }
    return $State
}

function Save-RustControlCenterState {
    param([Parameter(Mandatory = $true)][string]$ServerRoot,[Parameter(Mandatory = $true)]$State)
    return Save-RustJsonAtomic -Path (Get-RustControlCenterStatePath -ServerRoot $ServerRoot) -Value $State
}

function Set-RustOnboardingState {
    param([Parameter(Mandatory = $true)][string]$ServerRoot,[bool]$Completed,[bool]$Dismissed)
    $State = Get-RustControlCenterState -ServerRoot $ServerRoot
    $State.onboardingCompleted = $Completed
    $State.onboardingDismissed = $Dismissed
    $null = Save-RustControlCenterState -ServerRoot $ServerRoot -State $State
    return $State
}

function Get-RustMigrationStatePath {
    param([Parameter(Mandatory = $true)][string]$ServerRoot)
    return Join-Path $ServerRoot 'data\migration-state.json'
}

function Get-RustMigrationStatus {
    param([Parameter(Mandatory = $true)][string]$ServerRoot)
    $Path = Get-RustMigrationStatePath -ServerRoot $ServerRoot
    if (-not (Test-Path -LiteralPath $Path)) { return [pscustomobject]@{ CurrentSchema=0; TargetSchema=3; Current=$false; LastRunUtc=''; History=@() } }
    try { $State = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json }
    catch { return [pscustomobject]@{ CurrentSchema=-1; TargetSchema=3; Current=$false; LastRunUtc=''; History=@(); Error=$_.Exception.Message } }
    return [pscustomobject]@{ CurrentSchema=[int]$State.currentSchema; TargetSchema=3; Current=([int]$State.currentSchema -ge 3); LastRunUtc=[string]$State.lastRunUtc; History=@($State.history) }
}

function Invoke-RustControlCenterMigrations {
    param([Parameter(Mandatory = $true)][string]$ServerRoot)
    $Changes = New-Object Collections.Generic.List[string]
    [IO.Directory]::CreateDirectory((Join-Path $ServerRoot 'data')) | Out-Null

    $CatalogPath = Get-RustInstanceCatalogPath -ServerRoot $ServerRoot
    $Catalog = Get-RustInstanceCatalog -ServerRoot $ServerRoot
    if (-not ($Catalog.PSObject.Properties.Name -contains 'version') -or [int]$Catalog.version -lt 2) {
        Copy-Item -LiteralPath $CatalogPath -Destination ($CatalogPath + '.migration-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.bak') -Force
        if ($Catalog.PSObject.Properties.Name -contains 'version') { $Catalog.version = 2 } else { $Catalog | Add-Member version 2 }
        if (-not ($Catalog.PSObject.Properties.Name -contains 'backupRetentionCount')) { $Catalog | Add-Member backupRetentionCount 10 }
        if (-not ($Catalog.PSObject.Properties.Name -contains 'releaseChannel')) { $Catalog | Add-Member releaseChannel 'stable' }
        $null = Save-RustInstanceCatalog -ServerRoot $ServerRoot -Catalog $Catalog -NoBackup
        $Changes.Add('instances.json : v1 vers v2')
    }
    if ([int]$Catalog.version -lt 3) {
        Copy-Item -LiteralPath $CatalogPath -Destination ($CatalogPath + '.migration-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '-v3.bak') -Force
        foreach ($Instance in @($Catalog.instances)) {
            foreach ($Default in @(
                @('isolationMode','shared'),@('runtimeRoot',''),@('monitoringEnabled',$true),@('autoRestart',$false),@('autoRestartMaxPerHour',3),@('autoRestartCooldownSeconds',90),@('remoteAllowed',$true)
            )) {
                if (-not ($Instance.PSObject.Properties.Name -contains $Default[0])) { $Instance | Add-Member -NotePropertyName $Default[0] -NotePropertyValue $Default[1] }
            }
        }
        $Catalog.version = 3
        $null = Save-RustInstanceCatalog -ServerRoot $ServerRoot -Catalog $Catalog -NoBackup
        $Changes.Add('instances.json : isolation et supervision v3')
    }

    $SchedulePath = Get-RustMaintenanceScheduleStorePath -ServerRoot $ServerRoot
    if (Test-Path -LiteralPath $SchedulePath) {
        $RawScheduleStore = Get-Content -LiteralPath $SchedulePath -Raw -Encoding UTF8 | ConvertFrom-Json
        $OriginalScheduleSchema = if ($RawScheduleStore.PSObject.Properties.Name -contains 'schemaVersion') { [int]$RawScheduleStore.schemaVersion } else { 1 }
        $ScheduleStore = Get-RustMaintenanceScheduleStore -ServerRoot $ServerRoot
        $NeedsScheduleSave = $OriginalScheduleSchema -lt 2
        foreach ($Schedule in @($ScheduleStore.schedules)) {
            if (-not ($Schedule.PSObject.Properties.Name -contains 'retentionCount')) { $Schedule | Add-Member retentionCount 10; $NeedsScheduleSave = $true }
        }
        if ($NeedsScheduleSave) {
            Copy-Item -LiteralPath $SchedulePath -Destination ($SchedulePath + '.migration-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.bak') -Force
            $ScheduleStore.schemaVersion = 2
            $null = Save-RustMaintenanceScheduleStore -ServerRoot $ServerRoot -Store $ScheduleStore
            $Changes.Add('planning : schema v2 et rotation')
        }
    }

    $OperationPath = Get-RustOperationStorePath -ServerRoot $ServerRoot
    if (Test-Path -LiteralPath $OperationPath) {
        $OperationStore = Get-RustOperationStore -ServerRoot $ServerRoot
        $NeedsOperationSave = [int]$OperationStore.schemaVersion -lt 2
        foreach ($Operation in @($OperationStore.operations)) {
            if (-not ($Operation.PSObject.Properties.Name -contains 'source')) { $Operation | Add-Member source 'control-center'; $NeedsOperationSave = $true }
        }
        if ($NeedsOperationSave) {
            Copy-Item -LiteralPath $OperationPath -Destination ($OperationPath + '.migration-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.bak') -Force
            $OperationStore.schemaVersion = 2
            $null = Save-RustOperationStore -ServerRoot $ServerRoot -Store $OperationStore
            $Changes.Add('historique des operations : schema v2')
        }
    }

    $State = Get-RustControlCenterState -ServerRoot $ServerRoot
    $null = Save-RustControlCenterState -ServerRoot $ServerRoot -State $State
    $MigrationPath = Get-RustMigrationStatePath -ServerRoot $ServerRoot
    $OldHistory = @()
    if (Test-Path -LiteralPath $MigrationPath) { try { $OldHistory = @((Get-Content -LiteralPath $MigrationPath -Raw -Encoding UTF8 | ConvertFrom-Json).history) } catch {} }
    $Now = [datetime]::UtcNow.ToString('o')
    $PreviousSchema = if($OldHistory.Count){[int]$OldHistory[0].toSchema}elseif($Changes.Count){1}else{3}
    $Entry = [pscustomobject]@{ runUtc=$Now; fromSchema=$PreviousSchema; toSchema=3; changes=[object[]]$Changes.ToArray() }
    $MigrationState = [pscustomobject][ordered]@{ schemaVersion=1; currentSchema=3; applicationVersion='12.1.0'; lastRunUtc=$Now; history=@($Entry) + @($OldHistory | Select-Object -First 49) }
    $null = Save-RustJsonAtomic -Path $MigrationPath -Value $MigrationState
    return [pscustomobject]@{ Changed=($Changes.Count -gt 0); Changes=[object[]]$Changes.ToArray(); CurrentSchema=3; StatePath=$MigrationPath }
}

function New-RustDiagnosticRow {
    param(
        [ValidateSet('OK','WARNING','ERROR','INFO')][string]$Status,
        [string]$Category,
        [string]$Check,
        [string]$Detail,
        [string]$Action='',
        [string]$RepairCode=''
    )
    return [pscustomobject]@{ Status=$Status; Category=$Category; Check=$Check; Detail=$Detail; Action=$Action; RepairCode=$RepairCode }
}

function Get-RustControlCenterDiagnostics {
    param([Parameter(Mandatory = $true)][string]$ServerRoot)
    $Rows = New-Object Collections.Generic.List[object]
    $Rows.Add((New-RustDiagnosticRow $(if([Environment]::Is64BitOperatingSystem){'OK'}else{'ERROR'}) 'Système' 'Windows 64 bits' ([Environment]::OSVersion.VersionString) 'Utiliser Windows 10/11 64 bits.'))
    $Rows.Add((New-RustDiagnosticRow $(if($PSVersionTable.PSVersion.Major -ge 5){'OK'}else{'ERROR'}) 'Système' 'PowerShell' ([string]$PSVersionTable.PSVersion) 'Installer PowerShell 5.1 ou supérieur.'))
    $RootExists = Test-Path -LiteralPath $ServerRoot -PathType Container
    $Rows.Add((New-RustDiagnosticRow $(if($RootExists){'OK'}else{'ERROR'}) 'Installation' 'Dossier du Control Center' $ServerRoot 'Réinstaller le Control Center.'))
    $DataPath = Join-Path $ServerRoot 'data'
    $Rows.Add((New-RustDiagnosticRow $(if((Test-Path -LiteralPath $DataPath -PathType Container)){'OK'}else{'WARNING'}) 'Installation' 'Données persistantes' $(if(Test-Path -LiteralPath $DataPath){'Dossier présent.'}else{'Dossier absent.'}) 'Lancer la réparation sûre.' 'SafeRepair'))

    $RustExe = Join-Path $ServerRoot 'server\RustDedicated.exe'
    if (Test-Path -LiteralPath $RustExe -PathType Leaf) {
        $Version = (Get-Item -LiteralPath $RustExe).VersionInfo.FileVersion
        $Rows.Add((New-RustDiagnosticRow 'OK' 'Serveur' 'Rust Dedicated' $(if($Version){"Version $Version"}else{'Exécutable installé.'})))
    }
    else { $Rows.Add((New-RustDiagnosticRow 'ERROR' 'Serveur' 'Rust Dedicated' 'Exécutable absent.' 'Installer ou mettre à jour le serveur.' 'ServerUpdate')) }
    $SteamCmd = Join-Path $ServerRoot 'steamcmd\steamcmd.exe'
    $Rows.Add((New-RustDiagnosticRow $(if(Test-Path -LiteralPath $SteamCmd){'OK'}else{'WARNING'}) 'Serveur' 'SteamCMD' $(if(Test-Path -LiteralPath $SteamCmd){'Installé.'}else{'Absent.'}) 'Utiliser Mettre à jour.' 'ServerUpdate'))

    try {
        $Catalog = Get-RustInstanceCatalog -ServerRoot $ServerRoot
        Assert-RustInstanceCatalog $Catalog
        $Rows.Add((New-RustDiagnosticRow 'OK' 'Configuration' 'Profils de serveur' ("{0} profil(s), ports et identités valides." -f @($Catalog.instances).Count)))
    }
    catch { $Rows.Add((New-RustDiagnosticRow 'ERROR' 'Configuration' 'Profils de serveur' $_.Exception.Message 'Restaurer le dernier instances.json.bak.')) }

    $SecretPath = Join-Path $ServerRoot '.rcon-password.txt'
    if (Test-Path -LiteralPath $SecretPath -PathType Leaf) {
        $SecretLength = ([IO.File]::ReadAllText($SecretPath)).Trim().Length
        $Rows.Add((New-RustDiagnosticRow $(if($SecretLength -ge 12){'OK'}else{'WARNING'}) 'Sécurité' 'Secret RCON' $(if($SecretLength -ge 12){'Présent et longueur correcte.'}else{'Présent mais trop court.'}) 'Utiliser au moins 12 caractères aléatoires.' 'GenerateRconSecret'))
    }
    else { $Rows.Add((New-RustDiagnosticRow 'ERROR' 'Sécurité' 'Secret RCON' 'Fichier secret absent.' 'Créer .rcon-password.txt localement.' 'GenerateRconSecret')) }

    try {
        $RootDrive = [IO.DriveInfo]::new([IO.Path]::GetPathRoot([IO.Path]::GetFullPath($ServerRoot)))
        $Free = [long]$RootDrive.AvailableFreeSpace
        $Rows.Add((New-RustDiagnosticRow $(if($Free -ge 15GB){'OK'}elseif($Free -ge 5GB){'WARNING'}else{'ERROR'}) 'Stockage' 'Espace disque' ((Format-RustByteSize $Free) + ' libres.') 'Libérer au moins 15 Go.'))
    }
    catch { $Rows.Add((New-RustDiagnosticRow 'WARNING' 'Stockage' 'Espace disque' $_.Exception.Message)) }

    $SelectedInstance=try{Get-RustServerInstance -ServerRoot $ServerRoot}catch{$null}
    $CarbonRoot=if($SelectedInstance -and (Get-Command Get-RustInstanceCarbonRoot -ErrorAction SilentlyContinue)){Get-RustInstanceCarbonRoot -ServerRoot $ServerRoot -Instance $SelectedInstance}else{Join-Path $ServerRoot 'server\carbon'}
    $Rows.Add((New-RustDiagnosticRow 'INFO' 'Extensions' 'Environnement' $(if(Test-Path -LiteralPath $CarbonRoot){'Carbon détecté sur le runtime sélectionné.'}else{'Vanilla : aucun Carbon détecté sur le runtime sélectionné.'})))
    if(Get-Command Get-RustInstanceIsolationStatus -ErrorAction SilentlyContinue){
        $IsolationRows=@(Get-RustServerInstances -ServerRoot $ServerRoot|ForEach-Object{Get-RustInstanceIsolationStatus -ServerRoot $ServerRoot -Instance $_})
        $Incomplete=@($IsolationRows|Where-Object{$_.Mode-eq'full' -and -not$_.Ready})
        $Rows.Add((New-RustDiagnosticRow $(if($Incomplete.Count){'WARNING'}else{'OK'}) 'Isolation' 'Runtimes par instance' ("{0} runtime(s) complet(s), {1} incomplet(s)." -f @($IsolationRows|Where-Object Mode -eq 'full').Count,$Incomplete.Count) 'Installer les runtimes isolés incomplets.' 'OpenIsolation'))
    }
    if(Get-Command Get-RustWatchdogTaskStatus -ErrorAction SilentlyContinue){$Watchdog=Get-RustWatchdogTaskStatus -ServerRoot $ServerRoot;$Rows.Add((New-RustDiagnosticRow $(if($Watchdog.Installed){'OK'}else{'INFO'}) 'Supervision' 'Watchdog' $(if($Watchdog.Installed){'Installé · '+$Watchdog.State}else{'Non activé.'}) 'Activation facultative dans Supervision.'))}
    if(Get-Command Get-RustRemoteAccessConfig -ErrorAction SilentlyContinue){$Remote=Get-RustRemoteAccessConfig -ServerRoot $ServerRoot;$RemoteTask=Get-RustRemoteTaskStatus -ServerRoot $ServerRoot;$Rows.Add((New-RustDiagnosticRow $(if([bool]$Remote.enabled-and-not$RemoteTask.Installed){'WARNING'}else{'OK'}) 'Sécurité' 'Accès distant' $(if([bool]$Remote.enabled){"Activé sur $($Remote.bindAddress):$($Remote.port), service installé : $($RemoteTask.Installed)."}else{'Désactivé par défaut.'}) 'Ne pas exposer directement sur Internet.' 'OpenRemote'))}
    try {
        $ScheduleStore = Get-RustMaintenanceScheduleStore -ServerRoot $ServerRoot
        $EnabledSchedules = @($ScheduleStore.schedules | Where-Object enabled).Count
        $Rows.Add((New-RustDiagnosticRow 'OK' 'Automatisation' 'Planning' ("{0} règle(s), {1} active(s)." -f @($ScheduleStore.schedules).Count,$EnabledSchedules)))
    }
    catch { $Rows.Add((New-RustDiagnosticRow 'ERROR' 'Automatisation' 'Planning' $_.Exception.Message 'Restaurer ou recréer le planning.')) }
    $Task = Get-RustMaintenanceTaskStatus -ServerRoot $ServerRoot
    $Rows.Add((New-RustDiagnosticRow $(if($Task.Installed){'OK'}else{'INFO'}) 'Automatisation' 'Service en arrière-plan' $(if($Task.Installed){"Installé · $($Task.State)"}else{"Non activé ; fonctionne seulement quand l'app est ouverte."}) 'Activation facultative dans Wipes.'))

    try {
        $OperationStore = Get-RustOperationStore -ServerRoot $ServerRoot
        $Orphans = @($OperationStore.operations | Where-Object { $_.status -eq 'Running' -and $_.processId -and -not (Get-Process -Id ([int]$_.processId) -ErrorAction SilentlyContinue) }).Count
        $Rows.Add((New-RustDiagnosticRow $(if($Orphans){'WARNING'}else{'OK'}) 'Historique' 'Opérations persistantes' ("{0} opération(s), {1} orpheline(s)." -f @($OperationStore.operations).Count,$Orphans) 'Ouvrir Opérations pour diagnostiquer.' 'OpenOperations'))
    }
    catch { $Rows.Add((New-RustDiagnosticRow 'ERROR' 'Historique' 'Opérations persistantes' $_.Exception.Message 'Lancer la réparation sûre.' 'SafeRepair')) }

    $Backups = @(Get-RustServerBackups -ServerRoot $ServerRoot)
    if ($Backups.Count) {
        $LatestCheck = Test-RustServerBackup -ServerRoot $ServerRoot -BackupPath ([string]$Backups[0].Path)
        $Rows.Add((New-RustDiagnosticRow $(if($LatestCheck.Valid){'OK'}else{'ERROR'}) 'Sauvegardes' 'Dernière sauvegarde' ("{0} · {1}" -f $Backups[0].Date,$LatestCheck.Detail) "Vérifier ou supprimer l'archive corrompue."))
    }
    else { $Rows.Add((New-RustDiagnosticRow 'WARNING' 'Sauvegardes' 'Dernière sauvegarde' 'Aucune sauvegarde Control Center.' 'Créer une première sauvegarde.' 'CreateBackup')) }

    $Migration = Get-RustMigrationStatus -ServerRoot $ServerRoot
    $Rows.Add((New-RustDiagnosticRow $(if($Migration.Current){'OK'}else{'WARNING'}) 'Installation' 'Schéma des données' ("Schéma {0} / {1}." -f $Migration.CurrentSchema,$Migration.TargetSchema) 'Lancer la réparation sûre.' 'SafeRepair'))
    $Launchers = @(
        (Join-Path $ServerRoot 'LANCER-CONTROL-CENTER.vbs'),
        (Join-Path $ServerRoot 'LANCER-RUST-RPG-APP.vbs')
    )
    $Launcher = @($Launchers | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } | Select-Object -First 1)
    $Rows.Add((New-RustDiagnosticRow $(if($Launcher.Count){'OK'}else{'WARNING'}) 'Installation' 'Lanceur silencieux' $(if($Launcher.Count){'Présent.'}else{'Absent.'}) 'Réinstaller le package standalone.' 'ReinstallPackage'))

    $ControlState = Get-RustControlCenterState -ServerRoot $ServerRoot
    $Repository = [string]$ControlState.releaseRepository
    $Rows.Add((New-RustDiagnosticRow $(if($Repository -match '^[^/\s]+/[^/\s]+$'){'OK'}else{'INFO'}) 'Mises à jour' 'Dépôt GitHub' $(if($Repository){$Repository}else{'Non configuré.'}) 'Configurer owner/repository avant publication.'))
    $ControlState.lastDiagnosticUtc = [datetime]::UtcNow.ToString('o')
    $null = Save-RustControlCenterState -ServerRoot $ServerRoot -State $ControlState
    return [object[]]$Rows.ToArray()
}

function Repair-RustControlCenterSafeIssues {
    param([Parameter(Mandatory = $true)][string]$ServerRoot)
    $Created = New-Object Collections.Generic.List[string]
    foreach ($Relative in @('data','logs','backups\control-center','config')) {
        $Path = Join-Path $ServerRoot $Relative
        if (-not (Test-Path -LiteralPath $Path -PathType Container)) { [IO.Directory]::CreateDirectory($Path) | Out-Null; $Created.Add($Relative) }
    }
    $Migration = Invoke-RustControlCenterMigrations -ServerRoot $ServerRoot
    foreach ($Instance in @(Get-RustServerInstances -ServerRoot $ServerRoot)) { $null = Initialize-RustInstanceStorage -ServerRoot $ServerRoot -Instance $Instance }
    return [pscustomobject]@{ Created=[object[]]$Created.ToArray(); MigrationChanges=@($Migration.Changes); Detail=("{0} dossier(s) créé(s), {1} migration(s)." -f $Created.Count,@($Migration.Changes).Count) }
}

function New-RustRconSecret {
    param([Parameter(Mandatory = $true)][string]$ServerRoot)
    if (@(Get-RustRpgServerProcesses -ServerRoot $ServerRoot).Count) {
        throw 'Arrête toutes les instances Rust avant de remplacer le secret RCON.'
    }
    $SecretPath = Join-Path $ServerRoot '.rcon-password.txt'
    $BackupPath = ''
    if (Test-Path -LiteralPath $SecretPath -PathType Leaf) {
        $BackupRoot = Join-Path $ServerRoot 'backups\security'
        [IO.Directory]::CreateDirectory($BackupRoot) | Out-Null
        $BackupPath = Join-Path $BackupRoot ('.rcon-password-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.txt.bak')
        Copy-Item -LiteralPath $SecretPath -Destination $BackupPath -Force
    }
    $Bytes = New-Object byte[] 32
    $Generator = [Security.Cryptography.RandomNumberGenerator]::Create()
    try { $Generator.GetBytes($Bytes) }
    finally { $Generator.Dispose() }
    $Secret = [Convert]::ToBase64String($Bytes).TrimEnd('=').Replace('+','-').Replace('/','_')
    Write-Utf8File -Path $SecretPath -Content $Secret
    return [pscustomobject]@{ Path=$SecretPath; BackupPath=$BackupPath; Length=$Secret.Length }
}

function Export-RustControlCenterDiagnostics {
    param([Parameter(Mandatory = $true)][string]$ServerRoot,[Parameter(Mandatory = $true)][string]$OutputPath)
    $Rows = @(Get-RustControlCenterDiagnostics -ServerRoot $ServerRoot)
    $Report = [pscustomobject][ordered]@{ generatedUtc=[datetime]::UtcNow.ToString('o'); applicationVersion='12.1.0'; serverRoot=$ServerRoot; checks=$Rows }
    if ([IO.Path]::GetExtension($OutputPath) -eq '.txt') {
        $Lines = @('RUST SERVER CONTROL CENTER - DIAGNOSTIC','Généré : ' + (Get-Date).ToString('yyyy-MM-dd HH:mm:ss'),'')
        $Lines += @($Rows | ForEach-Object { '[{0}] {1} / {2} - {3} {4}' -f $_.Status,$_.Category,$_.Check,$_.Detail,$_.Action })
        Write-Utf8File -Path $OutputPath -Content ($Lines -join [Environment]::NewLine)
    }
    else { Write-Utf8File -Path $OutputPath -Content ($Report | ConvertTo-Json -Depth 12) }
    return $OutputPath
}
