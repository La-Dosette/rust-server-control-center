$script:RustRpgStateCache = $null

function Get-RustRpgServerProcesses {
    [CmdletBinding()]
    param([string]$ServerRoot = (Split-Path $PSScriptRoot -Parent))

    $Catalog = $null
    $CatalogPath = Join-Path $ServerRoot 'instances.json'
    if (Test-Path -LiteralPath $CatalogPath) {
        try { $Catalog = Get-Content -LiteralPath $CatalogPath -Raw -Encoding utf8 | ConvertFrom-Json } catch { }
    }
    $Processes = @(Get-CimInstance Win32_Process -Filter "Name = 'RustDedicated.exe'" -ErrorAction SilentlyContinue)
    $Rows = foreach ($Process in $Processes) {
        $CommandLine = [string]$Process.CommandLine
        $Identity = ''
        $ServerPort = 0
        $RconPort = 0
        if ($CommandLine -match '\+server\.identity\s+"?([^"\s]+)') { $Identity = $Matches[1] }
        if ($CommandLine -match '\+server\.port\s+"?(\d+)') { $ServerPort = [int]$Matches[1] }
        if ($CommandLine -match '\+rcon\.port\s+"?(\d+)') { $RconPort = [int]$Matches[1] }
        $Instance = if ($Catalog) { @($Catalog.instances | Where-Object identity -eq $Identity) | Select-Object -First 1 } else { $null }
        [pscustomobject]@{
            ProcessId   = [int]$Process.ProcessId
            Identity    = $Identity
            InstanceId  = if ($Instance) { [string]$Instance.id } else { '' }
            DisplayName = if ($Instance) { [string]$Instance.displayName } elseif($Identity) { $Identity } else { 'Serveur Rust' }
            IsPublic    = if ($Instance) { [bool]$Instance.isPublic } else { $false }
            ServerPort  = if ($ServerPort) { $ServerPort } elseif($Instance) { [int]$Instance.serverPort } else { 28115 }
            RconPort    = if ($RconPort) { $RconPort } elseif($Instance) { [int]$Instance.rconPort } else { 28116 }
            MemoryMb    = [math]::Round([double]$Process.WorkingSetSize / 1MB)
            CommandLine = $CommandLine
        }
    }
    return @($Rows)
}

function Get-RustRpgServerState {
    [CmdletBinding()]
    param([switch]$Force,[string]$ServerRoot = (Split-Path $PSScriptRoot -Parent))

    $Processes = @(Get-RustRpgServerProcesses -ServerRoot $ServerRoot)
    if (-not $Processes.Count) {
        return [pscustomobject]@{
            Running=$false; Mode='stopped'; Label='ARRETE'; Detail='Aucun serveur Rust en cours';
            ProcessId=$null; InstanceId=''; Identity=''; ServerPort=0; RconPort=0; Count=0; Processes=@()
        }
    }

    $SelectedId = ''
    $CatalogPath = Join-Path $ServerRoot 'instances.json'
    if (Test-Path -LiteralPath $CatalogPath) {
        try { $SelectedId = [string](Get-Content -LiteralPath $CatalogPath -Raw -Encoding utf8 | ConvertFrom-Json).selectedId } catch { }
    }
    $Primary = @($Processes | Where-Object InstanceId -eq $SelectedId) | Select-Object -First 1
    if (-not $Primary) { $Primary = $Processes | Select-Object -First 1 }
    $Mode = if ($Primary.IsPublic) { 'online' } else { 'local' }
    $Label = if ($Processes.Count -gt 1) { "$($Processes.Count) SERVEURS" } else { ([string]$Primary.DisplayName).ToUpperInvariant() }
    $Detail = if ($Processes.Count -gt 1) { "$($Processes.Count) instances actives - cible : $($Primary.DisplayName)" } else { "$($Primary.DisplayName) actif sur UDP $($Primary.ServerPort)" }
    return [pscustomobject]@{
        Running=$true; Mode=$Mode; Label=$Label; Detail=$Detail; ProcessId=$Primary.ProcessId;
        InstanceId=$Primary.InstanceId; Identity=$Primary.Identity; ServerPort=$Primary.ServerPort;
        RconPort=$Primary.RconPort; Count=$Processes.Count; Processes=$Processes
    }
}

function Get-RustControlCenterRconPort {
    param([Parameter(Mandatory = $true)][string]$ServerRoot)
    $CatalogPath = Join-Path $ServerRoot 'instances.json'
    if (Test-Path -LiteralPath $CatalogPath) {
        try {
            $Catalog = Get-Content -LiteralPath $CatalogPath -Raw -Encoding utf8 | ConvertFrom-Json
            $Selected = @($Catalog.instances | Where-Object id -eq ([string]$Catalog.selectedId)) | Select-Object -First 1
            if ($Selected) { return [int]$Selected.rconPort }
        } catch { }
    }
    $State = Get-RustRpgServerState -ServerRoot $ServerRoot
    if ($State.Running -and [int]$State.RconPort -gt 0) { return [int]$State.RconPort }
    return 28116
}

function Invoke-RustRpgRconCommandOnce {
    <#
        Envoie une commande RCON et retourne la reponse correspondante.

        Le serveur Rust pousse ses evenements console sur la meme WebSocket que
        les reponses aux commandes. Ces evenements portent un Identifier different
        de celui de la requete (generalement 0 ou -1). On boucle donc jusqu'a
        recevoir le message qui porte notre Identifier, en ignorant le reste :
        sans ce filtre on affiche un log a la place de la reponse.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$ServerRoot,

        [Parameter(Mandatory = $true)]
        [string]$Command,

        [switch]$NoResponse,

        [int]$RconPort = 0,

        [int]$TimeoutMs = 5000
    )

    $PasswordFile = Join-Path $ServerRoot ".rcon-password.txt"
    if (-not (Test-Path -LiteralPath $PasswordFile)) {
        throw "Le mot de passe RCON local est introuvable."
    }

    $Password = (Get-Content -LiteralPath $PasswordFile -Raw).Trim()
    if ($RconPort -le 0) { $RconPort = Get-RustControlCenterRconPort -ServerRoot $ServerRoot }
    $Uri = [Uri]("ws://127.0.0.1:$RconPort/" + [Uri]::EscapeDataString($Password))
    $Identifier = [int](Get-Random -Minimum 1000 -Maximum 999999)
    $Client = New-Object System.Net.WebSockets.ClientWebSocket
    $Deadline = (Get-Date).AddMilliseconds($TimeoutMs)

    # Chaque attente est bornee par le temps restant, jamais par le timeout
    # complet : connexion et envoi le consommaient chacun en entier, si bien
    # qu'une commande demandee a 10s pouvait durer plus de 20s. Sur une commande
    # inconnue - un plugin desactive, par exemple - ces depassements cumules
    # figeaient l'interface.
    function Get-RemainingMs { return [int][Math]::Max(1, ($Deadline - (Get-Date)).TotalMilliseconds) }

    # Task.Wait() ne se contente pas de renvoyer $false en cas d'echec : il leve
    # une AggregateException. Sans ce garde-fou, l'interface affichait seulement
    # "Exception lors de l'appel de Wait" et masquait la vraie panne reseau.
    function Wait-RustRpgTask {
        param(
            [Parameter(Mandatory = $true)][Threading.Tasks.Task]$Task,
            [Parameter(Mandatory = $true)][int]$WaitMs,
            [Parameter(Mandatory = $true)][string]$TimeoutMessage
        )

        try { $Completed = $Task.Wait($WaitMs) }
        catch {
            if ($Task.Exception) { throw $Task.Exception.GetBaseException() }
            throw
        }
        if (-not $Completed) { throw $TimeoutMessage }
    }

    try {
        $ConnectTask = $Client.ConnectAsync($Uri, [Threading.CancellationToken]::None)
        Wait-RustRpgTask -Task $ConnectTask -WaitMs (Get-RemainingMs) -TimeoutMessage "Le serveur RCON ne repond pas. Le serveur est peut-etre encore en demarrage."

        $Packet = @{
            Identifier = $Identifier
            Message    = $Command
            Name       = "Rust Server Control Center"
        } | ConvertTo-Json -Compress
        $Bytes = [Text.Encoding]::UTF8.GetBytes($Packet)
        $Segment = [ArraySegment[byte]]::new($Bytes)
        $SendTask = $Client.SendAsync(
            $Segment,
            [Net.WebSockets.WebSocketMessageType]::Text,
            $true,
            [Threading.CancellationToken]::None
        )
        Wait-RustRpgTask -Task $SendTask -WaitMs (Get-RemainingMs) -TimeoutMessage "La commande RCON n'a pas pu etre envoyee."
        if ($NoResponse) { return $true }

        $Buffer = New-Object byte[] 65536
        $Closed = $false
        $ReceivedAnything = $false

        while ((Get-Date) -lt $Deadline) {
            # Assemble un message complet, potentiellement fragmente sur plusieurs frames.
            $Builder = New-Object Text.StringBuilder
            do {
                $Remaining = Get-RemainingMs
                $ReceiveSegment = [ArraySegment[byte]]::new($Buffer)
                $ReceiveTask = $Client.ReceiveAsync($ReceiveSegment, [Threading.CancellationToken]::None)
                Wait-RustRpgTask -Task $ReceiveTask -WaitMs $Remaining -TimeoutMessage "Le serveur RCON n'a pas renvoye de reponse pour '$Command'."
                $Result = $ReceiveTask.Result
                if ($Result.MessageType -eq [Net.WebSockets.WebSocketMessageType]::Close) {
                    $Closed = $true
                    break
                }
                $ReceivedAnything = $true
                $null = $Builder.Append([Text.Encoding]::UTF8.GetString($Buffer, 0, $Result.Count))
            } while (-not $Result.EndOfMessage)

            if ($Closed) {
                if (-not $ReceivedAnything) {
                    throw "Le serveur RCON a ferme la connexion. Verifie le mot de passe dans .rcon-password.txt."
                }
                break
            }

            $RawResponse = $Builder.ToString()
            if (-not $RawResponse) { continue }

            $Response = $null
            try { $Response = $RawResponse | ConvertFrom-Json } catch { }

            if ($null -eq $Response) {
                # Charge utile non JSON : on ne peut pas l'attribuer, on la rend telle quelle.
                return $RawResponse
            }
            if ([int]$Response.Identifier -eq $Identifier) {
                return [string]$Response.Message
            }
            # Evenement console asynchrone : on l'ignore et on continue d'attendre.
        }

        throw "Aucune reponse RCON correspondante pour '$Command' (delai depasse)."
    }
    finally {
        try {
            if ($Client.State -eq [Net.WebSockets.WebSocketState]::Open) {
                $null = $Client.CloseAsync(
                    [Net.WebSockets.WebSocketCloseStatus]::NormalClosure,
                    "fin",
                    [Threading.CancellationToken]::None
                ).Wait(1000)
            }
        }
        catch { }
        $Client.Dispose()
    }
}

function Invoke-RustRpgRconCommand {
    <#
        Couche publique avec une relance courte. Rust peut fermer une WebSocket
        juste apres une commande precedente ; une seconde tentative evite que
        cette fermeture transitoire remonte comme une panne dans l'interface.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$ServerRoot,
        [Parameter(Mandatory = $true)][string]$Command,
        [switch]$NoResponse,
        [int]$RconPort = 0,
        [int]$TimeoutMs = 5000
    )

    for ($Attempt = 1; $Attempt -le 2; $Attempt++) {
        try {
            return Invoke-RustRpgRconCommandOnce -ServerRoot $ServerRoot -Command $Command -NoResponse:$NoResponse -RconPort $RconPort -TimeoutMs $TimeoutMs
        }
        catch {
            if ($Attempt -ge 2) { throw }
            Start-Sleep -Milliseconds 350
        }
    }
}

function Send-RustRpgRconCommand {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$ServerRoot,

        [Parameter(Mandatory = $true)]
        [string]$Command,

        [int]$RconPort = 0
    )

    return [bool](Invoke-RustRpgRconCommand -ServerRoot $ServerRoot -Command $Command -NoResponse -RconPort $RconPort)
}

function Get-RustRpgPlayers {
    <#
        Joueurs connectes. On passe par "playerlist", qui renvoie du JSON, plutot
        que par le tableau texte de "status" : le format de status varie entre
        versions de Rust et se parse mal des qu'un pseudo contient un espace.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$ServerRoot,
        [int]$RconPort = 0,
        [ValidateRange(500,60000)][int]$TimeoutMs = 8000
    )

    $Raw = [string](Invoke-RustRpgRconCommand -ServerRoot $ServerRoot -Command 'playerlist' -RconPort $RconPort -TimeoutMs $TimeoutMs)
    if ([string]::IsNullOrWhiteSpace($Raw)) { return @() }

    try { $Parsed = $Raw | ConvertFrom-Json } catch { return @() }
    if (-not $Parsed) { return @() }

    return @($Parsed | ForEach-Object {
        $Seconds = 0
        if ($_.PSObject.Properties.Name -contains 'ConnectedSeconds') { $Seconds = [int]$_.ConnectedSeconds }
        [pscustomobject]@{
            Nom       = [string]$_.DisplayName
            SteamID   = [string]$_.SteamID
            Ping      = [int]$_.Ping
            Connecte  = Format-RustRpgDuration $Seconds
            Sante     = if ($_.PSObject.Properties.Name -contains 'Health') { [int]$_.Health } else { 0 }
            Adresse   = [string]$_.Address
            Secondes  = $Seconds
        }
    })
}

function Format-RustRpgDuration {
    param([int]$Seconds)
    if ($Seconds -le 0) { return '0s' }
    $Span = [TimeSpan]::FromSeconds($Seconds)
    if ($Span.TotalHours -ge 1) { return ('{0}h {1:00}min' -f [int]$Span.TotalHours, $Span.Minutes) }
    if ($Span.TotalMinutes -ge 1) { return ('{0}min {1:00}s' -f [int]$Span.TotalMinutes, $Span.Seconds) }
    return ('{0}s' -f $Span.Seconds)
}

function Get-RustRpgServerInfo {
    <#
        Etat detaille du serveur. "serverinfo" repond en JSON : joueurs, uptime,
        images par seconde, memoire, nombre d'entites. C'est la source du tableau
        de bord, bien plus riche que le simple "processus en cours".
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$ServerRoot,
        [int]$RconPort = 0,
        [ValidateRange(500,60000)][int]$TimeoutMs = 8000
    )

    $Raw = [string](Invoke-RustRpgRconCommand -ServerRoot $ServerRoot -Command 'serverinfo' -RconPort $RconPort -TimeoutMs $TimeoutMs)
    if ([string]::IsNullOrWhiteSpace($Raw)) { return $null }
    try { return $Raw | ConvertFrom-Json } catch { return $null }
}

function Get-RustRpgBans {
    <#
        Liste des bannis. "banlist" repond en texte libre ; on en extrait ce qu'on
        peut sans jamais lever, une liste vide etant un resultat legitime.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$ServerRoot)

    $Raw = [string](Invoke-RustRpgRconCommand -ServerRoot $ServerRoot -Command 'banlist' -TimeoutMs 8000)
    if ([string]::IsNullOrWhiteSpace($Raw)) { return @() }

    $Bans = @()
    foreach ($Line in ($Raw -split "`r?`n")) {
        if ([string]::IsNullOrWhiteSpace($Line)) { continue }
        $Match = [regex]::Match($Line, '(\d{17})\s*[-:"]*\s*(.*)$')
        if (-not $Match.Success) { continue }
        $Rest = $Match.Groups[2].Value.Trim(' ', '"', '-')
        $Bans += [pscustomobject]@{
            SteamID = $Match.Groups[1].Value
            Detail  = if ($Rest) { $Rest } else { 'sans motif' }
        }
    }
    return @($Bans)
}

function Invoke-RustRpgModeration {
    <#
        Expulsion ou bannissement. Le motif est nettoye des guillemets, qui
        casseraient la commande RCON en coupant l'argument en deux.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$ServerRoot,
        [Parameter(Mandatory = $true)][ValidateSet('kick','ban','unban')][string]$Action,
        [Parameter(Mandatory = $true)][string]$SteamId,
        [string]$Reason = ''
    )

    $Clean = ($Reason -replace '"', "'").Trim()
    if (-not $Clean) { $Clean = 'Aucun motif precise' }

    $Command = switch ($Action) {
        'kick'  { "kick $SteamId ""$Clean""" }
        'ban'   { "ban $SteamId ""$Clean""" }
        'unban' { "unban $SteamId" }
    }
    return [string](Invoke-RustRpgRconCommand -ServerRoot $ServerRoot -Command $Command -TimeoutMs 10000)
}

function Write-RustRpgModerationLog {
    <#
        Journal des sanctions, cote outil. Une sanction prise en jeu via F1
        n'y figure pas : seules celles passees par le Control Center sont tracees.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$ServerRoot,
        [Parameter(Mandatory = $true)][string]$Action,
        [Parameter(Mandatory = $true)][string]$SteamId,
        [string]$PlayerName = '',
        [string]$Reason = '',
        [string]$Result = ''
    )

    $Directory = Join-Path $ServerRoot 'logs'
    if (-not (Test-Path -LiteralPath $Directory)) { New-Item -ItemType Directory -Path $Directory -Force | Out-Null }
    $Path = Join-Path $Directory 'moderation.json'

    $Entries = @()
    if (Test-Path -LiteralPath $Path) {
        try { $Entries = @(Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json) } catch { $Entries = @() }
    }

    $Entries += [pscustomobject]@{
        Date    = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
        Action  = $Action
        Joueur  = $PlayerName
        SteamID = $SteamId
        Motif   = $Reason
        Retour  = $Result
        Auteur  = $env:USERNAME
    }

    # On borne le journal pour qu'il ne grossisse pas indefiniment.
    if ($Entries.Count -gt 500) { $Entries = $Entries[-500..-1] }
    $Entries | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $Path -Encoding UTF8
    return $Path
}

function Get-RustRpgModerationLog {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$ServerRoot)

    $Path = Join-Path $ServerRoot 'logs\moderation.json'
    if (-not (Test-Path -LiteralPath $Path)) { return @() }
    try { $Entries = @(Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json) } catch { return @() }
    return @($Entries | Sort-Object Date -Descending)
}

function Get-RustRpgDataFile {
    <#
        Lit un fichier de donnees de plugin. Ces fichiers contiennent deja tous
        les classements et records : on les lit sur disque plutot que par RCON,
        ce qui marche meme serveur arrete.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$ServerRoot,
        [Parameter(Mandatory = $true)][string]$PluginName
    )

    $DataRoot = Join-Path $ServerRoot 'server\carbon\data'
    if (Get-Command Get-RustPluginRuntimeContext -ErrorAction SilentlyContinue) {
        try { $DataRoot = (Get-RustPluginRuntimeContext -ServerRoot $ServerRoot).DataRoot } catch { }
    }
    $Path = Join-Path $DataRoot "$PluginName.json"
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    try { return Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json } catch { return $null }
}

function Get-RustRpgLeaderboards {
    <#
        Agrege les classements de tous les plugins en une seule liste plate,
        triee par valeur decroissante. Un plugin absent est simplement ignore.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$ServerRoot)

    $Rows = @()
    $Names = @{}

    $Duel = Get-RustRpgDataFile -ServerRoot $ServerRoot -PluginName 'RustDuel'
    if ($Duel) {
        if ($Duel.Noms) { foreach ($p in $Duel.Noms.PSObject.Properties) { $Names[$p.Name] = $p.Value } }
        if ($Duel.Cotes) {
            foreach ($p in $Duel.Cotes.PSObject.Properties) {
                $Rows += [pscustomobject]@{ Classement='Duel ELO'; Joueur=$(if($Names[$p.Name]){$Names[$p.Name]}else{$p.Name}); Valeur=[int]$p.Value; SteamID=$p.Name }
            }
        }
    }

    $Td = Get-RustRpgDataFile -ServerRoot $ServerRoot -PluginName 'RustTowerDefense'
    if ($Td) {
        if ($Td.Noms) { foreach ($p in $Td.Noms.PSObject.Properties) { $Names[$p.Name] = $p.Value } }
        if ($Td.MeilleuresVaguesEndless) {
            foreach ($p in $Td.MeilleuresVaguesEndless.PSObject.Properties) {
                $Rows += [pscustomobject]@{ Classement='TD Endless'; Joueur=$(if($Names[$p.Name]){$Names[$p.Name]}else{$p.Name}); Valeur=[int]$p.Value; SteamID=$p.Name }
            }
        }
    }

    $Gg = Get-RustRpgDataFile -ServerRoot $ServerRoot -PluginName 'RustGunGame'
    if ($Gg -and $Gg.Victoires) {
        foreach ($p in $Gg.Victoires.PSObject.Properties) {
            $Rows += [pscustomobject]@{ Classement='Gun Game'; Joueur=$(if($Names[$p.Name]){$Names[$p.Name]}else{$p.Name}); Valeur=[int]$p.Value; SteamID=$p.Name }
        }
    }

    $Training = Get-RustRpgDataFile -ServerRoot $ServerRoot -PluginName 'RustTraining'
    if ($Training) {
        if ($Training.Noms) { foreach ($p in $Training.Noms.PSObject.Properties) { $Names[$p.Name] = $p.Value } }
        if ($Training.MeilleursScores) {
            # Cles composites "steamid:difficulte:motif:duree" : on ne garde que le meilleur par joueur.
            $Best = @{}
            foreach ($p in $Training.MeilleursScores.PSObject.Properties) {
                $Id = ($p.Name -split ':')[0]
                if (-not $Best.ContainsKey($Id) -or [int]$p.Value -gt $Best[$Id]) { $Best[$Id] = [int]$p.Value }
            }
            foreach ($Id in $Best.Keys) {
                $Rows += [pscustomobject]@{ Classement='Entrainement'; Joueur=$(if($Names[$Id]){$Names[$Id]}else{$Id}); Valeur=$Best[$Id]; SteamID=$Id }
            }
        }
    }

    $Rpg = Get-RustRpgDataFile -ServerRoot $ServerRoot -PluginName 'RustRPG'
    if ($Rpg -and $Rpg.Joueurs) {
        foreach ($p in $Rpg.Joueurs.PSObject.Properties) {
            $Progress = $p.Value
            $Rows += [pscustomobject]@{ Classement='Niveau progression'; Joueur=$(if($Names[$p.Name]){$Names[$p.Name]}else{$p.Name}); Valeur=[int]$Progress.Niveau; SteamID=$p.Name }
            if ($Progress.MeilleureVagueZombie -gt 0) {
                $Rows += [pscustomobject]@{ Classement='Zombie (vague)'; Joueur=$(if($Names[$p.Name]){$Names[$p.Name]}else{$p.Name}); Valeur=[int]$Progress.MeilleureVagueZombie; SteamID=$p.Name }
            }
        }
    }

    return @($Rows | Sort-Object Classement, @{Expression='Valeur';Descending=$true})
}

function Get-RustRpgStats {
    <#
        Statistiques collectees par le plugin RustStats. Le RCON est prefere
        lorsque le serveur tourne, puis le fichier RustStats.json prend le
        relais. La page reste donc utile serveur arrete ou pendant un demarrage.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$ServerRoot)

    if ((Get-RustRpgServerState).Running) {
        try {
            $Raw = [string](Invoke-RustRpgRconCommand -ServerRoot $ServerRoot -Command 'stats.dump json' -TimeoutMs 10000)
            if ($Raw.TrimStart().StartsWith('{')) {
                $Live = $Raw | ConvertFrom-Json
                $Live | Add-Member -NotePropertyName source -NotePropertyValue 'RCON' -Force
                return $Live
            }
        }
        catch { }
    }

    $Stored = Get-RustRpgDataFile -ServerRoot $ServerRoot -PluginName 'RustStats'
    if (-not $Stored) { return $null }

    $ModeNames = [ordered]@{
        zombie       = 'Zombie'
        duel         = 'Duel'
        gungame      = 'Gun Game'
        towerdefense = 'Tower Defense'
        training     = 'Entrainement'
    }

    $Modes = @(
        foreach ($Entry in $ModeNames.GetEnumerator()) {
            $Stats = $null
            if ($Stored.Modes) { $Stats = $Stored.Modes.([string]$Entry.Key) }
            $Parties = if ($Stats) { [int]$Stats.Parties } else { 0 }
            $Total = if ($Stats) { [int]$Stats.SecondesTotal } else { 0 }
            [pscustomobject]@{
                cle           = [string]$Entry.Key
                nom           = [string]$Entry.Value
                parties       = $Parties
                secondesTotal = $Total
                dureeMoyenne  = if ($Parties -gt 0) { [int]($Total / $Parties) } else { 0 }
                plusLongue    = if ($Stats) { [int]$Stats.PlusLonguePartie } else { 0 }
                derniere      = if ($Stats) { [string]$Stats.DernierePartie } else { '' }
            }
        }
    )

    $Players = @()
    if ($Stored.Joueurs) {
        $Players = @(
            foreach ($Entry in $Stored.Joueurs.PSObject.Properties) {
                $Record = $Entry.Value
                [pscustomobject]@{
                    steamId    = [string]$Entry.Name
                    nom        = [string]$Record.Nom
                    sessions   = [int]$Record.Sessions
                    secondesJeu = [int]$Record.SecondesJeu
                    premiere   = [string]$Record.PremiereConnexion
                    derniere   = [string]$Record.DerniereConnexion
                    notes      = [string]$Record.Notes
                    victoires  = $Record.Victoires
                }
            }
        )
    }

    return [pscustomobject]@{
        depuis  = [string]$Stored.CollecteDepuis
        source  = 'disque'
        modes   = $Modes
        joueurs = $Players
    }
}

function Get-RustRpgActivity {
    <#
        Photographie de ce qui se passe reellement sur le serveur : joueurs
        connectes et modes en cours. Sert de garde-fou avant toute action qui
        peut interrompre une partie (reload, stop de mode, wipe, arret).

        Ne leve jamais : en cas d'echec RCON on renvoie Known = $false, ce qui
        doit etre traite comme "on ne sait pas" et donc comme un risque.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$ServerRoot
    )

    $Result = [pscustomobject]@{
        Known       = $false
        PlayerCount = 0
        Players     = @()
        ActiveModes = @()
        Error       = ''
    }

    if (-not (Get-RustRpgServerState).Running) {
        $Result.Known = $true
        return $Result
    }

    try {
        $Players = @(Get-RustRpgPlayers -ServerRoot $ServerRoot)
        $Result.PlayerCount = $Players.Count
        $Result.Players = @($Players | ForEach-Object { $_.Nom })
        $Result.Known = $true
    }
    catch {
        $Result.Error = $_.Exception.Message
        return $Result
    }

    try {
        $Modes = [string](Invoke-RustRpgRconCommand -ServerRoot $ServerRoot -Command 'dashboard.modes' -TimeoutMs 10000)
        $Result.ActiveModes = @(Get-RustRpgActiveModeNames -DashboardText $Modes)
    }
    catch {
        $Result.Error = $_.Exception.Message
        $Result.Known = $false
    }

    return $Result
}

function Get-RustRpgActiveModeNames {
    <#
        Extrait la liste des modes en cours depuis la sortie de dashboard.modes.
        Accepte la sortie JSON et retombe sur le format texte historique.
    #>
    [CmdletBinding()]
    param([string]$DashboardText)

    $Active = @()
    if (-not $DashboardText) { return $Active }

    $Trimmed = $DashboardText.Trim()
    if ($Trimmed.StartsWith('{')) {
        try {
            $Json = $Trimmed | ConvertFrom-Json
            foreach ($Mode in $Json.modes) {
                if ($Mode.running) { $Active += [string]$Mode.name }
            }
            return $Active
        }
        catch { }
    }

    foreach ($Line in ($DashboardText -split "`r?`n")) {
        if ($Line -match '(?i)\bactif\s*=\s*(true|vrai)\b') {
            $Label = ($Line -split '\s*[:\-]\s*')[0].Trim()
            if ($Label) { $Active += $Label }
        }
    }
    return $Active
}

function Get-RustRpgFirewallAllowRulesFromText {
    <#
        Analyse une photographie `netsh advfirewall` sans modifier le pare-feu.
        Une autorisation peut viser directement un port ou le binaire
        RustDedicated.exe sur tous ses ports. Le second cas est celui créé par
        la boite de dialogue standard du pare-feu Windows.
    #>
    [CmdletBinding()]
    param(
        [string]$Text,
        [Parameter(Mandatory = $true)][ValidateSet('TCP','UDP')][string]$Protocol,
        [Parameter(Mandatory = $true)][ValidateRange(1,65535)][int]$Port,
        [string[]]$ProgramPaths = @(),
        [switch]$AllowProgramWidePort
    )

    $Found = @()
    if (-not $Text) { return $Found }
    $NormalizedPrograms = @($ProgramPaths | Where-Object { $_ } | ForEach-Object {
        try { [IO.Path]::GetFullPath([Environment]::ExpandEnvironmentVariables([string]$_)).TrimEnd('\').ToLowerInvariant() }
        catch { ([string]$_).Trim().Trim('"').TrimEnd('\').ToLowerInvariant() }
    } | Sort-Object -Unique)
    $Pattern = '(?ms)^\s*(?:Nom de la r.gle|Rule Name)\s*:\s*(?<name>[^\r\n]+)\r?\n-+\r?\n(?<body>.*?)(?=^\s*(?:Nom de la r.gle|Rule Name)\s*:|\z)'
    foreach ($RuleMatch in [regex]::Matches($Text,$Pattern)) {
        $Body = $RuleMatch.Groups['body'].Value
        $Enabled = $Body -match '(?im)^\s*(?:Activ.|Enabled)\s*:\s*(?:Oui|Yes|True)\s*$'
        $Allowed = $Body -match '(?im)^\s*Action\s*:\s*(?:Autoriser|Allow)\s*$'
        $ProtocolMatch = $Body -match ('(?im)^\s*(?:Protocole|Protocol)\s*:\s*' + [regex]::Escape($Protocol) + '\s*$')
        if (-not ($Enabled -and $Allowed -and $ProtocolMatch)) { continue }

        $ExplicitPort = $Body -match ('(?im)^\s*(?:LocalPort|Port local)\s*:\s*[^\r\n]*\b' + $Port + '\b')
        $ProgramWidePort = $false
        if ($AllowProgramWidePort -and $NormalizedPrograms.Count -gt 0 -and $Body -match '(?im)^\s*(?:LocalPort|Port local)\s*:\s*(?:Tout|Any|\*)\s*$') {
            $ProgramMatch = [regex]::Match($Body,'(?im)^\s*(?:Program|Programme)\s*:\s*(?<program>[^\r\n]+)\s*$')
            if ($ProgramMatch.Success) {
                $RuleProgram = $ProgramMatch.Groups['program'].Value.Trim().Trim('"')
                try { $RuleProgram = [IO.Path]::GetFullPath([Environment]::ExpandEnvironmentVariables($RuleProgram)).TrimEnd('\').ToLowerInvariant() }
                catch { $RuleProgram = $RuleProgram.TrimEnd('\').ToLowerInvariant() }
                $ProgramWidePort = $RuleProgram -in $NormalizedPrograms
            }
        }
        if ($ExplicitPort -or $ProgramWidePort) {
            $Suffix = if ($ProgramWidePort -and -not $ExplicitPort) { ' (autorisation du programme)' } else { '' }
            $Found += $RuleMatch.Groups['name'].Value.Trim() + $Suffix
        }
    }
    return @($Found | Sort-Object -Unique)
}

function Find-RustRpgSteamServerRecord {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Document,
        [Parameter(Mandatory = $true)][string]$PublicIp,
        [Parameter(Mandatory = $true)][ValidateRange(1,65535)][int]$QueryPort
    )
    $ExpectedAddress = "${PublicIp}:$QueryPort"
    return @($Document.response.servers | Where-Object {
        [string]$_.addr -eq $ExpectedAddress -and [int]$_.appid -eq 252490
    } | Select-Object -First 1)
}

function Get-RustRpgSteamExternalVisibility {
    <#
        Interroge l'API publique officielle de Steam depuis HTTPS. Steam renvoie
        ici la vue de son annuaire, ce qui evite de conclure depuis le meme Wi-Fi
        et de dependre du NAT loopback de la box.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$PublicIp,
        [Parameter(Mandatory = $true)][ValidateRange(1,65535)][int]$QueryPort,
        [Parameter(Mandatory = $true)][ValidateRange(1,65535)][int]$GamePort,
        [ValidateRange(2,30)][int]$TimeoutSeconds = 8
    )

    try {
        Add-Type -AssemblyName System.Net.Http -ErrorAction SilentlyContinue
        $Client = New-Object Net.Http.HttpClient
        try {
            $Client.Timeout = [TimeSpan]::FromSeconds($TimeoutSeconds)
            $Address = [Uri]::EscapeDataString("${PublicIp}:$QueryPort")
            $Uri = "https://api.steampowered.com/ISteamApps/GetServersAtAddress/v1/?addr=$Address&format=json"
            $Json = [string]$Client.GetStringAsync($Uri).GetAwaiter().GetResult()
        }
        finally { $Client.Dispose() }
        $Document = $Json | ConvertFrom-Json
        if (-not [bool]$Document.response.success) {
            return [pscustomobject]@{ Statut='ATTENTION'; Detail='Steam a refuse le controle externe.'; Action='Reessaie dans quelques instants.'; Address="${PublicIp}:$QueryPort" }
        }
        $Record = @(Find-RustRpgSteamServerRecord -Document $Document -PublicIp $PublicIp -QueryPort $QueryPort) | Select-Object -First 1
        if ($Record) {
            $PublishedGamePort = if ([int]$Record.gameport -gt 0) { [int]$Record.gameport } else { $GamePort }
            return [pscustomobject]@{
                Statut = 'OK'
                Detail = "Steam voit le serveur sur ${PublicIp}:$QueryPort et annonce le port jeu $PublishedGamePort."
                Action = "Un ami peut tester : client.connect ${PublicIp}:$PublishedGamePort"
                Address = "${PublicIp}:$PublishedGamePort"
            }
        }
        return [pscustomobject]@{
            Statut = 'ERREUR'
            Detail = "Steam ne voit aucun serveur Rust sur ${PublicIp}:$QueryPort."
            Action = "Attends deux minutes apres le demarrage, puis verifie la redirection UDP $QueryPort et UDP $GamePort vers ce PC."
            Address = "${PublicIp}:$QueryPort"
        }
    }
    catch {
        return [pscustomobject]@{ Statut='ATTENTION'; Detail=('Controle Steam indisponible : ' + $_.Exception.Message); Action='La panne du service externe ne prouve pas que le port est ferme. Reessaie plus tard.'; Address="${PublicIp}:$QueryPort" }
    }
}

function Get-RustRpgNetworkDiagnostics {
    <#
        Diagnostic reseau sans modification du systeme. Les tests d'ecoute et
        de pare-feu sont certains depuis ce PC. La joignabilite NAT/CGNAT reste
        volontairement marquee "A VERIFIER" car elle exige un client externe.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$ServerRoot,
        [string]$FriendCommand = ''
    )

    $Results = New-Object System.Collections.Generic.List[object]
    function Add-NetworkResult([string]$Statut,[string]$Test,[string]$Detail,[string]$Action = '') {
        $Results.Add([pscustomobject]@{
            Statut = $Statut
            Test   = $Test
            Detail = $Detail
            Action = $Action
        })
    }

    $GamePort = 28115
    $RconPort = 28116
    $QueryPort = 28117
    $BindIp = '0.0.0.0'
    $RconIp = '127.0.0.1'
    $CatalogPath = Join-Path $ServerRoot 'instances.json'
    $SettingsPath = Join-Path $ServerRoot 'Settings-Online.ps1'
    $Target = $null
    if (Test-Path -LiteralPath $CatalogPath) {
        try {
            $Catalog = Get-Content -LiteralPath $CatalogPath -Raw -Encoding utf8 | ConvertFrom-Json
            $Target = @($Catalog.instances | Where-Object isPublic) | Select-Object -First 1
            if (-not $Target) { $Target = @($Catalog.instances | Where-Object id -eq ([string]$Catalog.selectedId)) | Select-Object -First 1 }
            if ($Target) {
                $GamePort = [int]$Target.serverPort
                $RconPort = [int]$Target.rconPort
                $QueryPort = [int]$Target.queryPort
            }
        } catch { }
    }
    elseif (Test-Path -LiteralPath $SettingsPath) {
        $SettingsText = Get-Content -LiteralPath $SettingsPath -Raw
        foreach ($Setting in @(
            @{ Name='ServerPort'; Ref=[ref]$GamePort; Numeric=$true },
            @{ Name='RconPort'; Ref=[ref]$RconPort; Numeric=$true },
            @{ Name='QueryPort'; Ref=[ref]$QueryPort; Numeric=$true }
        )) {
            $Match = [regex]::Match($SettingsText, ('(?m)^\s*' + $Setting.Name + '\s*=\s*(\d+)'))
            if ($Match.Success) { $Setting.Ref.Value = [int]$Match.Groups[1].Value }
        }
        $Match = [regex]::Match($SettingsText, '(?m)^\s*BindIp\s*=\s*["'']([^"'']+)["'']')
        if ($Match.Success) { $BindIp = $Match.Groups[1].Value }
        $Match = [regex]::Match($SettingsText, '(?m)^\s*RconIp\s*=\s*["'']([^"'']+)["'']')
        if ($Match.Success) { $RconIp = $Match.Groups[1].Value }
    }

    $State = Get-RustRpgServerState -Force -ServerRoot $ServerRoot
    if ($State.Running) {
        Add-NetworkResult 'OK' 'Processus Rust' ("PID {0} - profil {1}" -f $State.ProcessId,$State.Mode) 'Aucune action.'
    }
    else {
        Add-NetworkResult 'INFO' 'Processus Rust' 'Serveur actuellement arrete.' 'Lance le profil local ou amis pour tester les ports en ecoute.'
    }

    $LanIp = ''
    $Gateway = ''
    $InterfaceAlias = ''
    $Dhcp = ''
    try {
        $Configurations = @(Get-NetIPConfiguration -ErrorAction Stop | Where-Object {
            $_.NetAdapter.Status -eq 'Up' -and $_.IPv4Address -and $_.IPv4DefaultGateway
        })
        $Configuration = $Configurations | Select-Object -First 1
        if (-not $Configuration) {
            $Configuration = @(Get-NetIPConfiguration -ErrorAction Stop | Where-Object { $_.IPv4Address }) | Select-Object -First 1
        }
        if ($Configuration) {
            $LanIp = [string]$Configuration.IPv4Address.IPAddress
            $Gateway = [string]$Configuration.IPv4DefaultGateway.NextHop
            $InterfaceAlias = [string]$Configuration.InterfaceAlias
            try {
                $IpInterface = Get-NetIPInterface -InterfaceIndex $Configuration.InterfaceIndex -AddressFamily IPv4 -ErrorAction Stop
                $Dhcp = [string]$IpInterface.Dhcp
            }
            catch { }
        }
    }
    catch { }

    if ($LanIp) {
        Add-NetworkResult 'OK' 'Adresse LAN' ("{0} via {1} - passerelle {2}" -f $LanIp,$InterfaceAlias,$Gateway) 'Utilise cette IP comme destination des redirections Livebox.'
    }
    else {
        Add-NetworkResult 'ERREUR' 'Adresse LAN' 'Aucune interface IPv4 utilisable avec passerelle detectee.' 'Verifie la connexion Ethernet/Wi-Fi et la configuration IPv4.'
    }
    if ($Dhcp -eq 'Enabled') {
        Add-NetworkResult 'ATTENTION' 'Stabilite IP locale' 'DHCP actif : adresse LAN susceptible de changer apres un redemarrage.' 'Cree une reservation DHCP dans la Livebox pour ce PC.'
    }
    elseif ($LanIp) {
        Add-NetworkResult 'OK' 'Stabilite IP locale' 'DHCP desactive ou adresse configuree de facon stable.' 'Conserve cette adresse pour les redirections NAT.'
    }

    $PublicIp = ''
    try {
        Add-Type -AssemblyName System.Net.Http -ErrorAction SilentlyContinue
        $Client = New-Object Net.Http.HttpClient
        try {
            $Client.Timeout = [TimeSpan]::FromSeconds(6)
            $PublicIp = ([string]$Client.GetStringAsync('https://api.ipify.org').GetAwaiter().GetResult()).Trim()
        }
        finally { $Client.Dispose() }
        if ($PublicIp -notmatch '^\d{1,3}(\.\d{1,3}){3}$') { $PublicIp = '' }
    }
    catch { }
    if ($PublicIp) {
        Add-NetworkResult 'OK' 'Adresse publique' $PublicIp 'Donne cette adresse aux amis avec le port du jeu.'
    }
    else {
        Add-NetworkResult 'ATTENTION' 'Adresse publique' 'Impossible de recuperer automatiquement adresse IP publique.' 'Reessaie ou controle adresse WAN dans la Livebox.'
    }

    if (-not $FriendCommand) {
        $AddressPath = Join-Path $ServerRoot 'CONNEXION-AMIS.txt'
        if (Test-Path -LiteralPath $AddressPath) {
            $Match = [regex]::Match((Get-Content -LiteralPath $AddressPath -Raw), 'client\.connect\s+([^\s]+)')
            if ($Match.Success) { $FriendCommand = 'client.connect ' + $Match.Groups[1].Value }
        }
    }
    $ExpectedFriendCommand = if ($PublicIp) { "client.connect ${PublicIp}:$GamePort" } else { '' }
    if ($FriendCommand -and $ExpectedFriendCommand -and $FriendCommand.Trim() -eq $ExpectedFriendCommand) {
        Add-NetworkResult 'OK' 'Adresse amis' $FriendCommand 'Commande a coller dans la console F1 de Rust.'
    }
    elseif ($ExpectedFriendCommand) {
        Add-NetworkResult 'ATTENTION' 'Adresse amis' $(if ($FriendCommand) { $FriendCommand } else { 'Commande absente' }) ("Actualise la commande vers : {0}" -f $ExpectedFriendCommand)
    }
    elseif ($FriendCommand) {
        Add-NetworkResult 'INFO' 'Adresse amis' $FriendCommand 'Adresse publique non comparee.'
    }

    $GameEndpoints = @()
    $QueryEndpoints = @()
    try { $GameEndpoints = @(Get-NetUDPEndpoint -LocalPort $GamePort -ErrorAction Stop) } catch { }
    try { $QueryEndpoints = @(Get-NetUDPEndpoint -LocalPort $QueryPort -ErrorAction Stop) } catch { }
    if ($State.Running) {
        if ($GameEndpoints.Count -gt 0) {
            Add-NetworkResult 'OK' "Port jeu UDP $GamePort" (($GameEndpoints | ForEach-Object LocalAddress | Sort-Object -Unique) -join ', ') 'Le serveur ecoute localement.'
        }
        else {
            Add-NetworkResult 'ERREUR' "Port jeu UDP $GamePort" 'Aucune ecoute UDP detectee.' 'Attends la fin du demarrage puis relance le diagnostic.'
        }
        if ($QueryEndpoints.Count -gt 0) {
            Add-NetworkResult 'OK' "Port requetes UDP $QueryPort" (($QueryEndpoints | ForEach-Object LocalAddress | Sort-Object -Unique) -join ', ') 'Ouvre aussi ce port si tu veux faciliter la liste publique du serveur.'
        }
        else {
            Add-NetworkResult 'ATTENTION' "Port requetes UDP $QueryPort" 'Aucune ecoute UDP detectee.' 'Verifie server.queryport et le demarrage complet.'
        }
    }
    else {
        Add-NetworkResult 'INFO' "Ports Rust UDP $GamePort / $QueryPort" 'Serveur arrete : aucune ecoute attendue.' 'Lance le serveur puis relance le diagnostic.'
    }

    if (-not $State.Running) {
        Add-NetworkResult 'INFO' 'Visibilite Steam externe' 'Test ignore : le serveur est arrete.' 'Lance le serveur amis puis relance le diagnostic.'
    }
    elseif (-not $PublicIp) {
        Add-NetworkResult 'ATTENTION' 'Visibilite Steam externe' 'Test impossible sans adresse publique.' 'Retablis la connexion Internet puis relance le diagnostic.'
    }
    elseif ($QueryEndpoints.Count -eq 0) {
        Add-NetworkResult 'ATTENTION' 'Visibilite Steam externe' "Le port de requetes UDP $QueryPort n'ecoute pas encore." 'Attends la fin du demarrage puis relance le diagnostic.'
    }
    else {
        $SteamVisibility = Get-RustRpgSteamExternalVisibility -PublicIp $PublicIp -QueryPort $QueryPort -GamePort $GamePort
        Add-NetworkResult ([string]$SteamVisibility.Statut) 'Visibilite Steam externe' ([string]$SteamVisibility.Detail) ([string]$SteamVisibility.Action)
    }

    $RconEndpoints = @()
    try { $RconEndpoints = @(Get-NetTCPConnection -State Listen -LocalPort $RconPort -ErrorAction Stop) } catch { }
    $UnsafeRconListener = @($RconEndpoints | Where-Object { $_.LocalAddress -notin @('127.0.0.1','::1') })
    if ($RconIp -notin @('127.0.0.1','localhost','::1')) {
        Add-NetworkResult 'ERREUR' "RCON TCP $RconPort" ("Configuration exposee sur {0}" -f $RconIp) 'Remets RconIp sur 127.0.0.1 et ne redirige jamais ce port.'
    }
    elseif ($UnsafeRconListener.Count -gt 0) {
        Add-NetworkResult 'ERREUR' "RCON TCP $RconPort" ("Ecoute non privee : {0}" -f (($UnsafeRconListener | ForEach-Object LocalAddress) -join ', ')) 'Arrete le serveur et corrige rcon.ip vers 127.0.0.1.'
    }
    elseif ($State.Running -and $RconEndpoints.Count -gt 0) {
        Add-NetworkResult 'OK' "RCON TCP $RconPort" 'Ecoute limitee a la boucle locale.' 'Ne cree aucune redirection ni regle entrante pour RCON.'
    }
    elseif (-not $State.Running) {
        Add-NetworkResult 'OK' "RCON TCP $RconPort" 'Serveur arrete et configuration privee sur 127.0.0.1.' 'Conserve ce port ferme depuis Internet.'
    }
    else {
        Add-NetworkResult 'ATTENTION' "RCON TCP $RconPort" 'Le serveur tourne mais RCON ne repond pas encore.' 'Attends le demarrage complet puis relance le diagnostic.'
    }

    if ($State.Running -and $RconEndpoints.Count -gt 0 -and $UnsafeRconListener.Count -eq 0) {
        try {
            $RconResponse = [string](Invoke-RustRpgRconCommand -ServerRoot $ServerRoot -Command 'serverinfo' -TimeoutMs 7000)
            if ($RconResponse) { Add-NetworkResult 'OK' 'Dialogue RCON local' 'Authentification et commande serverinfo reussies.' 'Le dashboard peut piloter le serveur.' }
            else { Add-NetworkResult 'ATTENTION' 'Dialogue RCON local' 'Connexion reussie mais reponse vide.' 'Reessaie apres la fin du demarrage.' }
        }
        catch { Add-NetworkResult 'ERREUR' 'Dialogue RCON local' $_.Exception.Message 'Verifie le demarrage et le mot de passe RCON local.' }
    }

    # Get-NetFirewallPortFilter sur chaque regle prend plusieurs dizaines de
    # secondes. netsh fournit la meme photographie en une seule lecture et ne
    # demande pas d'elevation pour l'affichage.
    $InboundFirewallText = ''
    try { $InboundFirewallText = (& netsh advfirewall firewall show rule name=all dir=in verbose 2>$null) -join "`n" } catch { }
    $RustProgramPaths = @(Join-Path $ServerRoot 'server\RustDedicated.exe')
    if ($Target -and [string]$Target.runtimeRoot) {
        $RuntimeRoot = [Environment]::ExpandEnvironmentVariables([string]$Target.runtimeRoot)
        if (-not [IO.Path]::IsPathRooted($RuntimeRoot)) { $RuntimeRoot = Join-Path $ServerRoot $RuntimeRoot }
        $RustProgramPaths += Join-Path $RuntimeRoot 'RustDedicated.exe'
    }

    $GameRules = @(Get-RustRpgFirewallAllowRulesFromText -Text $InboundFirewallText -Protocol UDP -Port $GamePort -ProgramPaths $RustProgramPaths -AllowProgramWidePort)
    if ($GameRules.Count -gt 0) {
        Add-NetworkResult 'OK' "Pare-feu UDP $GamePort" ($GameRules -join ', ') 'Regle entrante active pour le port du jeu.'
    }
    else {
        Add-NetworkResult 'ERREUR' "Pare-feu UDP $GamePort" 'Aucune regle entrante active detectee.' 'Ouvre le port depuis le lanceur administrateur ou le pare-feu Windows.'
    }
    $QueryRules = @(Get-RustRpgFirewallAllowRulesFromText -Text $InboundFirewallText -Protocol UDP -Port $QueryPort -ProgramPaths $RustProgramPaths -AllowProgramWidePort)
    if ($QueryRules.Count -gt 0) {
        Add-NetworkResult 'OK' "Pare-feu UDP $QueryPort" ($QueryRules -join ', ') 'Le port de requetes est autorise.'
    }
    else {
        Add-NetworkResult 'ATTENTION' "Pare-feu UDP $QueryPort" 'Aucune regle entrante active detectee.' 'Optionnel pour client.connect, recommande pour la liste/query du serveur.'
    }
    $RconRules = @(Get-RustRpgFirewallAllowRulesFromText -Text $InboundFirewallText -Protocol TCP -Port $RconPort)
    if ($RconRules.Count -eq 0) {
        Add-NetworkResult 'OK' "Pare-feu RCON TCP $RconPort" 'Aucune regle entrante active : RCON reste prive.' 'Ne jamais ouvrir ce port sur la Livebox.'
    }
    else {
        Add-NetworkResult 'ERREUR' "Pare-feu RCON TCP $RconPort" ($RconRules -join ', ') 'Desactive ou supprime ces regles entrantes pour proteger administration.'
    }

    Add-NetworkResult 'INFO' 'Profil reseau' ("Jeu {0}:{1}/UDP - query {2}/UDP - RCON {3}:{4}/TCP" -f $BindIp,$GamePort,$QueryPort,$RconIp,$RconPort) 'Profil attendu : jeu public, RCON local uniquement.'
    if ($LanIp) {
        Add-NetworkResult 'A VERIFIER' 'Livebox / NAT' ("Rediriger UDP {0} vers {1}:{0}; UDP {2} est recommande pour les requetes." -f $GamePort,$LanIp,$QueryPort) 'Teste ensuite depuis un autre reseau. Le test depuis le meme Wi-Fi peut echouer par absence de NAT loopback.'
    }
    else {
        Add-NetworkResult 'A VERIFIER' 'Livebox / NAT' 'Destination LAN inconnue.' 'Retablis une adresse IPv4 locale valide avant de continuer.'
    }
    Add-NetworkResult 'A VERIFIER' 'CGNAT / double NAT' 'Impossible a confirmer uniquement depuis Windows.' 'Compare IP WAN de la Livebox et IP publique. Si elles different, contacte operateur ou corrige le double NAT.'

    return $Results.ToArray()
}
