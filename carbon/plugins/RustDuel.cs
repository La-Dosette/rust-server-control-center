using System;
using System.Collections.Generic;
using System.Linq;
using Oxide.Core;
using UnityEngine;

namespace Oxide.Plugins
{
    [Info("RustDuel", "OpenAI", "2.2.2")]
    [Description("Duels avances 1v1 a 4v4 avec ELO, rangs, kits a distance et melee, six modeles d ar&#232;ne, spectateurs et tournoi 1v1.")]
    public class RustDuel : RustPlugin
    {
        private const string ItemPrefix = "Duel - ";
        private const string WallPrefab = "assets/prefabs/building/wall.external.high.stone/wall.external.high.stone.prefab";
        private const string ConcreteCoverPrefab = "assets/prefabs/deployable/barricades/barricade.concrete.prefab";
        private const string SandbagCoverPrefab = "assets/prefabs/deployable/barricades/barricade.sandbags.prefab";
        private const int RoundsToWin = 3;
        private const float RoundDuration = 240f;

        /// <summary>
        /// Source unique de verite des kits. La liste des identifiants etait
        /// auparavant recopiee a deux endroits : n'en modifier qu'un acceptait le
        /// kit a la selection puis le remplacait silencieusement par le SAR au
        /// tour suivant. Ajouter un kit ne demande plus qu'une ligne ici.
        /// </summary>
        private class DuelKit
        {
            public string Id;
            public string Nom;
            public string Arme;
            public string ArmeLabel;
            public string Munition;
            public int MunitionQuantite;
            public bool Melee;

            public DuelKit(string id, string nom, string arme, string armeLabel, string munition, int munitionQuantite, bool melee)
            {
                Id = id;
                Nom = nom;
                Arme = arme;
                ArmeLabel = armeLabel;
                Munition = munition;
                MunitionQuantite = munitionQuantite;
                Melee = melee;
            }
        }

        private static readonly DuelKit[] DuelKits =
        {
            new DuelKit("sar",      "semi-auto",         "rifle.semiauto", "Fusil semi-automatique", "ammo.rifle",   128, false),
            new DuelKit("smg",      "Thompson",          "smg.thompson",   "Thompson",               "ammo.pistol",  160, false),
            new DuelKit("bow",      "arc",               "bow.hunting",    "Arc de chasse",          "arrow.wooden",  64, false),
            new DuelKit("shotgun",  "pompe",             "shotgun.pump",   "Fusil a pompe",          "ammo.shotgun",  48, false),
            new DuelKit("couteau",  "couteau de combat", "knife.combat",   "Couteau de combat",      null,             0, true),
            new DuelKit("machette", "machette",          "machete",        "Machette",               null,             0, true),
            new DuelKit("epee",     "epee de fortune",   "salvaged.sword", "Epee de fortune",        null,             0, true),
            new DuelKit("lance",    "lance en pierre",   "spear.stone",    "Lance en pierre",        null,             0, true)
        };

        private readonly Dictionary<int, List<ulong>> _queues = new Dictionary<int, List<ulong>>();
        private readonly HashSet<ulong> _participants = new HashSet<ulong>();
        private readonly HashSet<ulong> _alive = new HashSet<ulong>();
        private readonly HashSet<ulong> _spectators = new HashSet<ulong>();
        private readonly Dictionary<ulong, int> _teams = new Dictionary<ulong, int>();
        private readonly Dictionary<ulong, Vector3> _returnPositions = new Dictionary<ulong, Vector3>();
        private readonly List<BaseEntity> _arenaEntities = new List<BaseEntity>();
        private readonly List<ulong> _tournamentQueue = new List<ulong>();
        private readonly List<ulong> _tournamentRound = new List<ulong>();
        private readonly List<ulong> _tournamentWinners = new List<ulong>();

        private StoredData _data;
        private Vector3 _arenaCenter;
        private string _currentArena = string.Empty;
        private bool _matchActive;
        private bool _roundActive;
        private bool _allowRoundRespawn;
        private int _teamSize;
        private int _scoreRed;
        private int _scoreBlue;
        private int _roundNumber;
        private int _sessionId;
        private int _tournamentPairIndex;
        private int _tournamentRoundNumber;
        private bool _tournamentActive;
        private bool _tournamentMatch;

        private class StoredData
        {
            public Dictionary<ulong, int> Victoires = new Dictionary<ulong, int>();
            public Dictionary<ulong, int> Defaites = new Dictionary<ulong, int>();
            public Dictionary<ulong, int> Cotes = new Dictionary<ulong, int>();
            public Dictionary<ulong, string> Kits = new Dictionary<ulong, string>();
            public Dictionary<ulong, int> Tournois = new Dictionary<ulong, int>();
            public Dictionary<ulong, string> Noms = new Dictionary<ulong, string>();
            // Modele d'arene souhaite. Vide ou "aleatoire" : tirage au sort.
            public string Arene = string.Empty;
        }

        private void Init()
        {
            for (int size = 1; size <= 4; size++) _queues[size] = new List<ulong>();
            LoadData();
        }

        private void OnServerInitialized()
        {
            // Un shortname disparu d'une mise a jour de Rust echouerait sinon en
            // silence au moment de donner le kit, en pleine manche.
            List<string> missing = new List<string>();
            foreach (DuelKit kit in DuelKits)
            {
                if (ItemManager.FindItemDefinition(kit.Arme) == null) missing.Add(kit.Arme);
                if (!string.IsNullOrEmpty(kit.Munition) && ItemManager.FindItemDefinition(kit.Munition) == null) missing.Add(kit.Munition);
            }
            if (missing.Count > 0) PrintWarning("Objets de kit introuvables dans cette version de Rust : " + string.Join(", ", missing.ToArray()));

            int melee = DuelKits.Count(kit => kit.Melee);
            Puts($"Duel avance pret : ELO, rangs, {DuelKits.Length} kits dont {melee} en melee, spectateurs et tournoi 1v1.");
        }

        private static DuelKit FindDuelKit(string id)
        {
            if (string.IsNullOrEmpty(id)) return null;
            return DuelKits.FirstOrDefault(kit => string.Equals(kit.Id, id, StringComparison.OrdinalIgnoreCase));
        }

        private string DuelKitHelp()
        {
            return "Kits : " + string.Join(", ", DuelKits.Select(kit => $"<color=#ffd479>{kit.Id}</color> ({kit.Nom})").ToArray()) + ".";
        }

        private void Unload()
        {
            _sessionId++;
            foreach (BasePlayer player in BasePlayer.activePlayerList.ToArray())
            {
                if (_participants.Contains(player.userID) || _spectators.Contains(player.userID)) ReturnPlayer(player);
                RemoveDuelItems(player);
            }
            RemoveArena();
            SaveData();
        }

        private void OnServerSave()
        {
            SaveData();
        }

        /// <summary>
        /// Source unique des gardes inter-modes. La meme chaine d'appels etait
        /// recopiee a trois endroits : en ajouter un cinquieme partout a la main
        /// est exactement la forme qui a produit le bug de la liste de kits.
        /// </summary>
        private string DescribeOtherMode(BasePlayer player)
        {
            if (IsOtherModeParticipant(player, "IsGunGameParticipant")) return "Quitte d'abord le Gun Game avec /gungame.";
            if (IsOtherModeParticipant(player, "IsZombieParticipant")) return "Quitte d'abord le mode Zombie avec /zombie.";
            if (IsOtherModeParticipant(player, "IsCompetitiveModeParticipant")) return "Quitte d'abord le mode competitif actuel avec /mode leave.";
            if (IsOtherModeParticipant(player, "IsTowerDefenseParticipant")) return "Quitte d'abord le Tower Defense avec /td.";
            if (IsOtherModeParticipant(player, "IsTrainingParticipant")) return "Quitte d'abord l'entrainement avec /entrainement quitter.";
            if (IsOtherModeParticipant(player, "IsBattlefieldParticipant")) return "Quitte d'abord Battlefield avec /bf.";
            return null;
        }

        private object ForceLeaveMode(BasePlayer player)
        {
            if (player == null) return null;
            bool involved = _participants.Contains(player.userID) || _spectators.Contains(player.userID) ||
                            QueueOf(player.userID) > 0 || _tournamentQueue.Contains(player.userID);
            if (!involved) return null;
            LeaveDuel(player);
            return true;
        }

        private object GetDuelPlayerStats(BasePlayer player)
        {
            if (player == null) return null;
            int rating = GetRating(player.userID);
            return $"elo={rating} rang={RankName(rating)} victoires={GetValue(_data.Victoires, player.userID)} defaites={GetValue(_data.Defaites, player.userID)} tournois={GetValue(_data.Tournois, player.userID)} kit={SelectedKit(player.userID)}";
        }

        private object SetDuelKitFromMenu(BasePlayer player, string kit)
        {
            if (player == null) return false;
            SelectKit(player, kit ?? string.Empty);
            return true;
        }

        private object GetDuelKitIds()
        {
            return string.Join(",", DuelKits.Select(kit => kit.Id).ToArray());
        }

        private object IsDuelParticipant(BasePlayer player)
        {
            return player != null && (_participants.Contains(player.userID) || _spectators.Contains(player.userID) || QueueOf(player.userID) > 0 || _tournamentQueue.Contains(player.userID));
        }

        private object JoinDuelQueueFromLobby(BasePlayer player, int size)
        {
            if (player == null) return false;
            JoinQueue(player, Mathf.Clamp(size, 1, 4));
            return true;
        }

        private object IsDuelFight(BasePlayer attacker, BasePlayer victim)
        {
            if (!_matchActive || !_roundActive || attacker == null || victim == null) return false;
            int attackerTeam;
            int victimTeam;
            return _teams.TryGetValue(attacker.userID, out attackerTeam) &&
                   _teams.TryGetValue(victim.userID, out victimTeam) &&
                   attackerTeam != victimTeam && _alive.Contains(attacker.userID) && _alive.Contains(victim.userID);
        }

        private object OnEntityTakeDamage(BaseCombatEntity entity, HitInfo info)
        {
            if (entity == null || info == null) return null;
            BasePlayer victim = entity as BasePlayer;
            BasePlayer attacker = info.InitiatorPlayer;
            if (victim == null || attacker == null) return null;

            bool victimInDuel = _participants.Contains(victim.userID);
            bool attackerInDuel = _participants.Contains(attacker.userID);
            bool victimSpectator = _spectators.Contains(victim.userID);
            bool attackerSpectator = _spectators.Contains(attacker.userID);
            if (!victimInDuel && !attackerInDuel && !victimSpectator && !attackerSpectator) return null;

            int attackerTeam;
            int victimTeam;
            bool opposingTeams = _roundActive && attackerInDuel && victimInDuel &&
                                  _alive.Contains(attacker.userID) && _alive.Contains(victim.userID) &&
                                  _teams.TryGetValue(attacker.userID, out attackerTeam) &&
                                  _teams.TryGetValue(victim.userID, out victimTeam) && attackerTeam != victimTeam;
            if (opposingTeams && IsUsingDuelWeapon(attacker)) return null;

            info.damageTypes.ScaleAll(0f);
            return true;
        }

        private void OnWeaponFired(BaseProjectile projectile, BasePlayer player, ItemModProjectile mod, ProtoBuf.ProjectileShoot projectiles)
        {
            if (projectile == null || player == null || !_participants.Contains(player.userID) || !_roundActive || !IsUsingDuelWeapon(player)) return;
            timer.Once(0.01f, () =>
            {
                if (projectile == null || projectile.IsDestroyed || projectile.primaryMagazine == null) return;
                projectile.primaryMagazine.contents = projectile.primaryMagazine.capacity;
                projectile.SendNetworkUpdateImmediate();
            });
        }

        private void OnEntityDeath(BaseCombatEntity entity, HitInfo info)
        {
            BasePlayer player = entity as BasePlayer;
            if (player == null || !_matchActive || !_roundActive || !_participants.Contains(player.userID)) return;
            _alive.Remove(player.userID);
            timer.Once(0.2f, EvaluateRound);
        }

        private object OnPlayerRespawn(BasePlayer player)
        {
            if (player != null && _matchActive && _roundActive && _participants.Contains(player.userID) &&
                !_alive.Contains(player.userID) && !_allowRoundRespawn)
            {
                SendReply(player, "Attends la prochaine manche pour reapparaitre dans le duel.");
                return true;
            }
            return null;
        }

        private void OnPlayerDisconnected(BasePlayer player, string reason)
        {
            if (player == null) return;
            RemoveFromQueues(player.userID);
            _tournamentQueue.Remove(player.userID);
            if (_spectators.Remove(player.userID))
            {
                _returnPositions.Remove(player.userID);
                return;
            }
            if (!_participants.Contains(player.userID)) return;
            int team;
            _teams.TryGetValue(player.userID, out team);
            FinishMatch(team == 1 ? 2 : 1, $"{player.displayName} s'est deconnecte : forfait.");
        }

        [ChatCommand("duel")]
        private void CommandDuel(BasePlayer player, string command, string[] args)
        {
            if (player == null) return;
            _data.Noms[player.userID] = player.displayName;
            if (args.Length == 0)
            {
                ShowDuelStatus(player);
                return;
            }

            string action = args[0].ToLowerInvariant();
            if (action == "leave" || action == "quitter" || action == "stop")
            {
                LeaveDuel(player);
                return;
            }
            if (action == "status" || action == "statut")
            {
                ShowDuelStatus(player);
                return;
            }
            if (action == "spectate" || action == "spectateur")
            {
                JoinSpectators(player);
                return;
            }
            if (action == "kit")
            {
                SelectKit(player, args.Length > 1 ? args[1] : string.Empty);
                return;
            }
            if (action == "arene" || action == "arena")
            {
                SelectArena(player, args.Length > 1 ? args[1] : string.Empty);
                return;
            }
            if (action == "rank" || action == "rang")
            {
                ShowRank(player);
                return;
            }

            int size = ParseTeamSize(action);
            if (size == 0)
            {
                SendReply(player, "Usage : <color=#ffd479>/duel 1v1|2v2|3v3|4v4</color>, /duel kit <nom>, /duel arene <nom>, /duel spectate, /duel rank, /duel leave");
                SendReply(player, DuelKitHelp());
                return;
            }
            JoinQueue(player, size);
        }

        [ConsoleCommand("duel")]
        private void ConsoleDuel(ConsoleSystem.Arg arg)
        {
            BasePlayer player = arg.Player();
            if (player == null)
            {
                arg.ReplyWith("Cette commande doit etre utilisee par un joueur.");
                return;
            }
            CommandDuel(player, "duel", ConsoleArgs(arg));
        }

        [ConsoleCommand("duel.stop")]
        private void ConsoleStop(ConsoleSystem.Arg arg)
        {
            BasePlayer caller = arg.Player();
            if (caller != null && !caller.IsAdmin)
            {
                arg.ReplyWith("Commande reservee aux administrateurs.");
                return;
            }
            if (_matchActive) FinishMatch(0, "Duel arrete par un administrateur.");
            else RemoveArena();
            arg.ReplyWith("Mode Duel arrete et arene retiree.");
        }

        [ConsoleCommand("duel.debug")]
        private void ConsoleDebug(ConsoleSystem.Arg arg)
        {
            BasePlayer caller = arg.Player();
            if (caller != null && !caller.IsAdmin)
            {
                arg.ReplyWith("Commande reservee aux administrateurs.");
                return;
            }
            string queues = string.Join(", ", _queues.OrderBy(pair => pair.Key).Select(pair => $"{pair.Key}v{pair.Key}={pair.Value.Count}").ToArray());
            arg.ReplyWith($"match={_matchActive} roundActive={_roundActive} size={_teamSize} score={_scoreRed}-{_scoreBlue} participants={_participants.Count} spectators={_spectators.Count} tournament={_tournamentActive} tournamentQueue={_tournamentQueue.Count} arenaEntities={_arenaEntities.Count} center={_arenaCenter} queues=[{queues}]");
        }

        private object GetDuelDashboardStatus()
        {
            string queues = string.Join(", ", _queues.OrderBy(pair => pair.Key).Select(pair => $"{pair.Key}v{pair.Key}={pair.Value.Count}").ToArray());
            return $"arene={(string.IsNullOrEmpty(_currentArena) ? "-" : _currentArena)} match={_matchActive} manche={_roundActive} format={_teamSize}v{_teamSize} score={_scoreRed}-{_scoreBlue} joueurs={_participants.Count} spectateurs={_spectators.Count} tournoi={_tournamentActive} fileTournoi={_tournamentQueue.Count} files=[{queues}]";
        }

        [ChatCommand("tournoi")]
        private void CommandTournament(BasePlayer player, string command, string[] args)
        {
            if (player == null) return;
            string action = args.Length > 0 ? args[0].ToLowerInvariant() : "join";
            if (action == "leave" || action == "quitter")
            {
                if (_tournamentQueue.Remove(player.userID)) SendReply(player, "Tu as quitte le tournoi 1v1.");
                else SendReply(player, "Tu n'es pas dans la file tournoi.");
                return;
            }
            if (action == "status" || action == "statut")
            {
                SendReply(player, $"Tournoi 1v1 : actif={_tournamentActive}, manche={_tournamentRoundNumber}, file={_tournamentQueue.Count}, encore en lice={_tournamentRound.Count}.");
                return;
            }
            JoinTournamentQueue(player);
        }

        [ChatCommand("dueltop")]
        private void CommandDuelTop(BasePlayer player, string command, string[] args)
        {
            List<KeyValuePair<ulong, int>> top = _data.Cotes.OrderByDescending(pair => pair.Value).ThenBy(pair => pair.Key).Take(10).ToList();
            if (top.Count == 0)
            {
                SendReply(player, "Le classement ELO est encore vide.");
                return;
            }
            SendReply(player, "<color=#ffd479>TOP 10 DUEL ELO</color>");
            for (int index = 0; index < top.Count; index++)
            {
                string name;
                if (!_data.Noms.TryGetValue(top[index].Key, out name)) name = top[index].Key.ToString();
                SendReply(player, $"{index + 1}. {name} - {RankName(top[index].Value)} {top[index].Value}");
            }
        }

        [ConsoleCommand("duel.tournament.start")]
        private void ConsoleTournamentStart(ConsoleSystem.Arg arg)
        {
            BasePlayer caller = arg.Player();
            if (caller != null && !caller.IsAdmin) { arg.ReplyWith("Commande reservee aux administrateurs."); return; }
            int requested = 0;
            if (arg.Args != null && arg.Args.Length > 0) int.TryParse(arg.Args[0].ToString(), out requested);
            StartTournament(requested, arg);
        }

        [ConsoleCommand("duel.tournament.stop")]
        private void ConsoleTournamentStop(ConsoleSystem.Arg arg)
        {
            BasePlayer caller = arg.Player();
            if (caller != null && !caller.IsAdmin) { arg.ReplyWith("Commande reservee aux administrateurs."); return; }
            _tournamentActive = false;
            _tournamentMatch = false;
            _tournamentRound.Clear();
            _tournamentWinners.Clear();
            _tournamentPairIndex = 0;
            if (_matchActive) FinishMatch(0, "Tournoi arrete par un administrateur.");
            arg.ReplyWith("Tournoi Duel arrete.");
        }

        private void ShowDuelStatus(BasePlayer player)
        {
            if (_spectators.Contains(player.userID))
            {
                SendReply(player, $"Tu observes le Duel {_teamSize}v{_teamSize}, score ROUGE {_scoreRed} / {_scoreBlue} BLEUE. /duel leave pour revenir.");
                return;
            }
            if (_participants.Contains(player.userID))
            {
                int team;
                _teams.TryGetValue(player.userID, out team);
                SendReply(player, $"Duel {_teamSize}v{_teamSize} - equipe {(team == 1 ? "ROUGE" : "BLEUE")} - score {_scoreRed}-{_scoreBlue}, manche {_roundNumber}.");
                SendReply(player, "Victoire en 3 manches. /duel leave abandonne la partie.");
                return;
            }

            int queuedSize = QueueOf(player.userID);
            if (queuedSize > 0)
            {
                SendReply(player, $"Tu attends un duel {queuedSize}v{queuedSize} : {_queues[queuedSize].Count}/{queuedSize * 2} joueur(s).");
                SendReply(player, "/duel leave pour quitter la file.");
                return;
            }
            int wins = GetValue(_data.Victoires, player.userID);
            int losses = GetValue(_data.Defaites, player.userID);
            int rating = GetRating(player.userID);
            SendReply(player, $"<color=#ffd479>DUEL BO5</color> - {RankName(rating)} {rating} ELO - {wins} victoire(s), {losses} defaite(s), {GetValue(_data.Tournois, player.userID)} tournoi(s).");
            SendReply(player, $"Kit actuel : {SelectedKit(player.userID).ToUpperInvariant()}. /duel spectate, /tournoi.");
            SendReply(player, DuelKitHelp());
            SendReply(player, "Tape /duel 1v1, /duel 2v2, /duel 3v3 ou /duel 4v4. La premiere equipe a 3 manches gagne.");
        }

        private void ShowRank(BasePlayer player)
        {
            int rating = GetRating(player.userID);
            SendReply(player, $"<color=#ffd479>{RankName(rating)}</color> - {rating} ELO | {GetValue(_data.Victoires, player.userID)} V / {GetValue(_data.Defaites, player.userID)} D | {GetValue(_data.Tournois, player.userID)} tournoi(s).");
        }

        private void SelectKit(BasePlayer player, string requested)
        {
            string kit = requested.ToLowerInvariant();
            if (FindDuelKit(kit) == null)
            {
                SendReply(player, DuelKitHelp());
                return;
            }
            _data.Kits[player.userID] = kit;
            SaveData();
            SendReply(player, $"Kit Duel selectionne : <color=#ffd479>{kit.ToUpperInvariant()}</color>. Il sera donne a la prochaine manche.");
        }

        private void JoinSpectators(BasePlayer player)
        {
            if (!_matchActive)
            {
                SendReply(player, "Aucun duel actif a observer.");
                return;
            }
            if (_participants.Contains(player.userID) || _spectators.Contains(player.userID))
            {
                SendReply(player, "Tu es deja dans le Duel.");
                return;
            }
            string blocker = DescribeOtherMode(player);
            if (blocker != null)
            {
                SendReply(player, blocker);
                return;
            }
            RemoveFromQueues(player.userID);
            _tournamentQueue.Remove(player.userID);
            _returnPositions[player.userID] = player.transform.position;
            _spectators.Add(player.userID);
            player.Teleport(GetSpectatorSpawn());
            SendReply(player, "Mode spectateur actif. Tu es protege et ne peux pas combattre. /duel leave pour revenir.");
        }

        private void JoinTournamentQueue(BasePlayer player)
        {
            if (_tournamentActive)
            {
                SendReply(player, "Le tournoi a deja commence. Utilise /duel spectate pour le regarder.");
                return;
            }
            if (_participants.Contains(player.userID) || _spectators.Contains(player.userID))
            {
                SendReply(player, "Quitte d'abord ton duel en cours.");
                return;
            }
            string tournamentBlocker = DescribeOtherMode(player);
            if (tournamentBlocker != null)
            {
                SendReply(player, tournamentBlocker);
                return;
            }
            RemoveFromQueues(player.userID);
            if (!_tournamentQueue.Contains(player.userID)) _tournamentQueue.Add(player.userID);
            foreach (ulong userId in _tournamentQueue.ToArray())
            {
                BasePlayer queued = FindActivePlayer(userId);
                if (queued != null) SendReply(queued, $"File tournoi 1v1 : {_tournamentQueue.Count} joueur(s). Le tournoi accepte 4, 8 ou 16 participants.");
            }
        }

        private void StartTournament(int requested, ConsoleSystem.Arg arg)
        {
            if (_matchActive || _tournamentActive)
            {
                arg.ReplyWith("Un Duel ou un tournoi est deja actif.");
                return;
            }
            _tournamentQueue.RemoveAll(userId => FindActivePlayer(userId) == null);
            int count = requested;
            if (count == 0) count = _tournamentQueue.Count >= 16 ? 16 : _tournamentQueue.Count >= 8 ? 8 : _tournamentQueue.Count >= 4 ? 4 : 0;
            if (!new[] { 4, 8, 16 }.Contains(count) || _tournamentQueue.Count < count)
            {
                arg.ReplyWith($"Il faut 4, 8 ou 16 joueurs. File actuelle : {_tournamentQueue.Count}.");
                return;
            }
            _tournamentActive = true;
            _tournamentMatch = false;
            _tournamentRoundNumber = 1;
            _tournamentPairIndex = 0;
            _tournamentRound.Clear();
            _tournamentWinners.Clear();
            _tournamentRound.AddRange(_tournamentQueue.Take(count).OrderBy(value => UnityEngine.Random.value));
            _tournamentQueue.RemoveRange(0, count);
            BroadcastGlobal($"<color=#ffd479>TOURNOI DUEL 1v1</color> - {count} joueurs, tableau a elimination directe. Premier match dans 5 secondes.");
            arg.ReplyWith($"Tournoi lance avec {count} joueurs.");
            timer.Once(5f, StartNextTournamentMatch);
        }

        private void StartNextTournamentMatch()
        {
            if (!_tournamentActive || _matchActive) return;
            if (_tournamentPairIndex >= _tournamentRound.Count)
            {
                if (_tournamentWinners.Count == 1)
                {
                    FinishTournament(_tournamentWinners[0]);
                    return;
                }
                _tournamentRound.Clear();
                _tournamentRound.AddRange(_tournamentWinners);
                _tournamentWinners.Clear();
                _tournamentPairIndex = 0;
                _tournamentRoundNumber++;
                BroadcastGlobal($"Tournoi Duel : debut du tour {_tournamentRoundNumber}, {_tournamentRound.Count} joueur(s) encore en lice.");
            }
            if (_tournamentPairIndex + 1 >= _tournamentRound.Count)
            {
                _tournamentActive = false;
                BroadcastGlobal("Tournoi annule : tableau incomplet.");
                return;
            }
            List<ulong> pair = new List<ulong> { _tournamentRound[_tournamentPairIndex], _tournamentRound[_tournamentPairIndex + 1] };
            _tournamentPairIndex += 2;
            if (pair.Any(userId => FindActivePlayer(userId) == null))
            {
                ulong connected = pair.FirstOrDefault(userId => FindActivePlayer(userId) != null);
                if (connected != 0) _tournamentWinners.Add(connected);
                timer.Once(1f, StartNextTournamentMatch);
                return;
            }
            _tournamentMatch = true;
            BroadcastGlobal($"Tournoi tour {_tournamentRoundNumber} : {FindActivePlayer(pair[0]).displayName} contre {FindActivePlayer(pair[1]).displayName}.");
            StartMatch(pair, 1);
        }

        private void FinishTournament(ulong championId)
        {
            BasePlayer champion = FindActivePlayer(championId);
            _data.Tournois[championId] = GetValue(_data.Tournois, championId) + 1;
            SaveData();
            if (champion != null)
            {
                Interface.CallHook("OnDuelTournamentWon", champion);
                BroadcastGlobal($"<color=#ffd479>{champion.displayName} remporte le tournoi Duel 1v1 !</color>");
            }
            _tournamentActive = false;
            _tournamentMatch = false;
            _tournamentRound.Clear();
            _tournamentWinners.Clear();
            _tournamentPairIndex = 0;
            timer.Once(1f, TryStartNextMatch);
        }

        private void JoinQueue(BasePlayer player, int size)
        {
            if (_participants.Contains(player.userID))
            {
                SendReply(player, "Tu participes deja a un duel.");
                return;
            }
            if (_spectators.Contains(player.userID))
            {
                SendReply(player, "Quitte d'abord les spectateurs avec /duel leave.");
                return;
            }
            string otherMode = DescribeOtherMode(player);
            if (otherMode != null)
            {
                SendReply(player, otherMode);
                return;
            }

            RemoveFromQueues(player.userID);
            _tournamentQueue.Remove(player.userID);
            _queues[size].Add(player.userID);
            BroadcastQueue(size, $"<color=#ffd479>{player.displayName}</color> rejoint la file {size}v{size} ({_queues[size].Count}/{size * 2}).");
            SendReply(player, $"File {size}v{size} rejointe. L'arene sera generee quand {size * 2} joueurs seront prets.");
            TryStartNextMatch();
        }

        private void LeaveDuel(BasePlayer player)
        {
            if (_spectators.Remove(player.userID))
            {
                ReturnPlayer(player);
                _returnPositions.Remove(player.userID);
                SendReply(player, "Tu as quitte les spectateurs.");
                return;
            }
            if (_tournamentQueue.Remove(player.userID))
            {
                SendReply(player, "Tu as quitte la file du tournoi 1v1.");
                return;
            }
            int queuedSize = QueueOf(player.userID);
            if (queuedSize > 0)
            {
                _queues[queuedSize].Remove(player.userID);
                SendReply(player, $"Tu as quitte la file {queuedSize}v{queuedSize}.");
                return;
            }
            if (_participants.Contains(player.userID))
            {
                int team;
                _teams.TryGetValue(player.userID, out team);
                FinishMatch(team == 1 ? 2 : 1, $"{player.displayName} abandonne : forfait.");
                return;
            }
            SendReply(player, "Tu n'es dans aucune file Duel.");
        }

        private void TryStartNextMatch()
        {
            if (_matchActive || _tournamentActive) return;
            foreach (int size in new[] { 1, 2, 3, 4 })
            {
                _queues[size].RemoveAll(userId => FindActivePlayer(userId) == null);
                int needed = size * 2;
                if (_queues[size].Count < needed) continue;
                List<ulong> selected = _queues[size].Take(needed).OrderBy(value => UnityEngine.Random.value).ToList();
                _queues[size].RemoveRange(0, needed);
                StartMatch(selected, size);
                return;
            }
        }

        private void StartMatch(List<ulong> selected, int size)
        {
            _matchActive = true;
            _roundActive = false;
            _teamSize = size;
            _scoreRed = 0;
            _scoreBlue = 0;
            _roundNumber = 0;
            _sessionId++;
            _participants.Clear();
            _teams.Clear();
            _alive.Clear();
            _returnPositions.Clear();

            for (int index = 0; index < selected.Count; index++)
            {
                BasePlayer player = FindActivePlayer(selected[index]);
                if (player == null) continue;
                _participants.Add(player.userID);
                _teams[player.userID] = index < size ? 1 : 2;
                _returnPositions[player.userID] = player.transform.position;
            }
            if (_participants.Count != size * 2)
            {
                FinishMatch(0, "Duel annule : un joueur n'est plus connecte.");
                return;
            }

            BuildArena();
            foreach (BasePlayer player in MatchPlayers())
            {
                int team = _teams[player.userID];
                SendReply(player, $"<color=#{(team == 1 ? "e9654b" : "6eb7ff")}>Equipe {(team == 1 ? "ROUGE" : "BLEUE")}</color> - Duel {_teamSize}v{_teamSize}, victoire en 3 manches.");
            }
            BroadcastMatch($"Arene Duel generee en {_arenaCenter}. Premiere manche dans 5 secondes.");
            int session = _sessionId;
            timer.Once(5f, () =>
            {
                if (_matchActive && session == _sessionId) StartRound();
            });
        }

        private void StartRound()
        {
            if (!_matchActive) return;
            foreach (ulong userId in _participants.ToArray())
            {
                if (FindActivePlayer(userId) == null)
                {
                    int missingTeam;
                    _teams.TryGetValue(userId, out missingTeam);
                    FinishMatch(missingTeam == 1 ? 2 : 1, "Un joueur manque : victoire par forfait.");
                    return;
                }
            }

            _roundNumber++;
            _roundActive = true;
            _alive.Clear();
            _allowRoundRespawn = true;
            foreach (BasePlayer player in MatchPlayers())
            {
                _alive.Add(player.userID);
                Vector3 spawn = GetTeamSpawn(_teams[player.userID], TeamIndex(player.userID));
                RemoveDuelItems(player);
                if (player.IsDead()) player.RespawnAt(spawn, Quaternion.identity);
                else player.Teleport(spawn);
                player.InitializeHealth(100f, 100f);
                BasePlayer captured = player;
                timer.Once(0.25f, () =>
                {
                    if (captured != null && captured.IsConnected && _participants.Contains(captured.userID)) GiveDuelKit(captured);
                });
            }
            _allowRoundRespawn = false;
            BroadcastMatch($"<color=#ffd479>Manche {_roundNumber}</color> - ROUGE {_scoreRed} / {_scoreBlue} BLEUE. Combat !");

            int session = _sessionId;
            int round = _roundNumber;
            timer.Once(RoundDuration, () =>
            {
                if (_matchActive && _roundActive && session == _sessionId && round == _roundNumber) ResolveRoundTimeout();
            });
        }

        private void EvaluateRound()
        {
            if (!_matchActive || !_roundActive) return;
            int redAlive = _alive.Count(userId => TeamOf(userId) == 1 && FindActivePlayer(userId) != null);
            int blueAlive = _alive.Count(userId => TeamOf(userId) == 2 && FindActivePlayer(userId) != null);
            if (redAlive == 0 && blueAlive == 0) EndRound(0, "Egalite : les deux equipes sont eliminees.");
            else if (redAlive == 0) EndRound(2, "Equipe BLEUE remporte la manche.");
            else if (blueAlive == 0) EndRound(1, "Equipe ROUGE remporte la manche.");
        }

        private void ResolveRoundTimeout()
        {
            int redAlive = _alive.Count(userId => TeamOf(userId) == 1 && FindActivePlayer(userId) != null);
            int blueAlive = _alive.Count(userId => TeamOf(userId) == 2 && FindActivePlayer(userId) != null);
            if (redAlive > blueAlive) EndRound(1, "Temps ecoule : ROUGE gagne au nombre de survivants.");
            else if (blueAlive > redAlive) EndRound(2, "Temps ecoule : BLEUE gagne au nombre de survivants.");
            else EndRound(0, "Temps ecoule : manche nulle.");
        }

        private void EndRound(int winner, string message)
        {
            if (!_matchActive || !_roundActive) return;
            _roundActive = false;
            if (winner == 1) _scoreRed++;
            if (winner == 2) _scoreBlue++;
            BroadcastMatch($"{message} Score : ROUGE {_scoreRed} / {_scoreBlue} BLEUE.");

            if (_scoreRed >= RoundsToWin || _scoreBlue >= RoundsToWin)
            {
                int matchWinner = _scoreRed > _scoreBlue ? 1 : 2;
                int session = _sessionId;
                timer.Once(4f, () =>
                {
                    if (_matchActive && session == _sessionId) FinishMatch(matchWinner, $"Equipe {(matchWinner == 1 ? "ROUGE" : "BLEUE")} remporte le duel {_scoreRed}-{_scoreBlue} !");
                });
                return;
            }

            int currentSession = _sessionId;
            timer.Once(5f, () =>
            {
                if (_matchActive && currentSession == _sessionId) StartRound();
            });
        }

        private void FinishMatch(int winner, string message)
        {
            if (!_matchActive)
            {
                RemoveArena();
                return;
            }

            _roundActive = false;
            _sessionId++;
            BroadcastMatch(message);
            List<ulong> participantIds = _participants.ToList();
            bool wasTournamentMatch = _tournamentActive && _tournamentMatch;
            ulong tournamentWinner = winner == 0 ? 0 : participantIds.FirstOrDefault(userId => TeamOf(userId) == winner);
            if (winner != 0) UpdateRatings(winner, participantIds);
            foreach (ulong userId in participantIds)
            {
                int team = TeamOf(userId);
                if (winner == team) _data.Victoires[userId] = GetValue(_data.Victoires, userId) + 1;
                else if (winner != 0) _data.Defaites[userId] = GetValue(_data.Defaites, userId) + 1;
            }
            foreach (BasePlayer player in MatchPlayers().ToArray())
            {
                int team = TeamOf(player.userID);
                if (winner == team)
                {
                    Interface.CallHook("OnDuelCompleted", player, _teamSize);
                    SendReply(player, "<color=#ffd479>Victoire Duel !</color> Recompense de progression ajoutee.");
                }
                RemoveDuelItems(player);
                ReturnPlayer(player);
            }
            foreach (ulong spectatorId in _spectators.ToArray())
            {
                BasePlayer spectator = FindActivePlayer(spectatorId);
                if (spectator != null) ReturnPlayer(spectator);
            }
            SaveData();
            _participants.Clear();
            _spectators.Clear();
            _teams.Clear();
            _alive.Clear();
            _returnPositions.Clear();
            _teamSize = 0;
            _scoreRed = 0;
            _scoreBlue = 0;
            _roundNumber = 0;
            _matchActive = false;
            _tournamentMatch = false;
            RemoveArena();
            if (wasTournamentMatch && tournamentWinner != 0 && _tournamentActive)
            {
                _tournamentWinners.Add(tournamentWinner);
                timer.Once(3f, StartNextTournamentMatch);
            }
            else timer.Once(1f, TryStartNextMatch);
        }

        /// <summary>
        /// Construit un modele pendant quelques secondes puis nettoie, pour le
        /// voir sans mobiliser deux joueurs. Refuse d'agir pendant un match :
        /// la construction ecraserait l'arene en cours.
        /// </summary>
        [ConsoleCommand("duel.arena.preview")]
        private void ConsoleDuelArenaPreview(ConsoleSystem.Arg arg)
        {
            BasePlayer caller = arg.Player();
            if (caller != null && !caller.IsAdmin) { arg.ReplyWith("Commande reservee aux administrateurs."); return; }
            if (_matchActive) { arg.ReplyWith("Un match est en cours : apercu refuse."); return; }
            if (_arenaEntities.Count > 0) { arg.ReplyWith("Une arene existe deja. Attends la fin du nettoyage."); return; }

            string[] args = arg.Args != null ? arg.Args.Select(value => value.ToString()).ToArray() : new string[0];
            string id = args.Length > 0 ? args[0].ToLowerInvariant() : "cercle";
            if (!IsKnownArena(id))
            {
                arg.ReplyWith("Modele inconnu. Disponibles : " + string.Join(", ", ArenaTemplates.Select(entry => entry[0]).ToArray()));
                return;
            }

            int duration = 20;
            if (args.Length > 1)
            {
                int parsed;
                if (int.TryParse(args[1], out parsed)) duration = Mathf.Clamp(parsed, 5, 120);
            }

            _arenaCenter = FindArenaCenter();
            _currentArena = id;
            BuildPerimeter(id);
            BuildInterior(id);
            int built = _arenaEntities.Count;

            // Jeton de session : si un vrai match demarre entre-temps, le timer
            // ne doit pas detruire son arene.
            int session = _sessionId;
            timer.Once(duration, () =>
            {
                if (_matchActive || session != _sessionId) return;
                RemoveArena();
                Puts($"Apercu d'arene {ArenaLabel(id)} nettoye.");
            });

            string position = $"{_arenaCenter.x:0} {_arenaCenter.y:0} {_arenaCenter.z:0}";
            arg.ReplyWith($"Apercu {ArenaLabel(id)} : {built} elements pendant {duration}s en {position}. Teleporte-toi avec : teleportpos {position}");
        }

        [ConsoleCommand("duel.arena")]
        private void ConsoleDuelArena(ConsoleSystem.Arg arg)
        {
            BasePlayer caller = arg.Player();
            if (caller != null && !caller.IsAdmin) { arg.ReplyWith("Commande reservee aux administrateurs."); return; }

            string[] args = arg.Args != null ? arg.Args.Select(value => value.ToString()).ToArray() : new string[0];
            if (args.Length == 0)
            {
                string current = string.IsNullOrEmpty(_data.Arene) ? "aleatoire" : _data.Arene;
                arg.ReplyWith($"Modele choisi : {current}. Modeles : aleatoire, " + string.Join(", ", ArenaTemplates.Select(entry => entry[0]).ToArray()));
                return;
            }

            string id = args[0].ToLowerInvariant();
            if (id == "aleatoire" || id == "random")
            {
                _data.Arene = string.Empty;
                SaveData();
                arg.ReplyWith("Modele d'arene : aleatoire.");
                return;
            }
            if (!IsKnownArena(id))
            {
                arg.ReplyWith("Modele inconnu. Disponibles : aleatoire, " + string.Join(", ", ArenaTemplates.Select(entry => entry[0]).ToArray()));
                return;
            }
            _data.Arene = id;
            SaveData();
            arg.ReplyWith($"Modele d'arene : {ArenaLabel(id)}." + (_matchActive ? " Applique au prochain match." : string.Empty));
        }

        /// <summary>
        /// Choix du modele d'arene. La preference est persistee et s'applique au
        /// prochain match : changer de modele en pleine manche reconstruirait
        /// l'arene sous les joueurs.
        /// </summary>
        private void SelectArena(BasePlayer player, string requested)
        {
            string id = (requested ?? string.Empty).ToLowerInvariant();

            if (string.IsNullOrEmpty(id))
            {
                SendReply(player, ArenaHelp());
                string current = string.IsNullOrEmpty(_data.Arene) ? "aleatoire" : _data.Arene;
                SendReply(player, $"Modele choisi : <color=#ffd479>{current}</color>." + (_matchActive ? $" Arene en cours : {ArenaLabel(_currentArena)}." : string.Empty));
                return;
            }

            if (id == "aleatoire" || id == "random")
            {
                _data.Arene = string.Empty;
                SaveData();
                SendReply(player, "Modele d'arene : <color=#ffd479>aleatoire</color>. Un modele different sera tire a chaque match.");
                return;
            }

            if (!IsKnownArena(id))
            {
                SendReply(player, ArenaHelp());
                return;
            }

            _data.Arene = id;
            SaveData();
            SendReply(player, $"Modele d'arene : <color=#ffd479>{ArenaLabel(id)}</color>." + (_matchActive ? " Il sera applique au prochain match." : string.Empty));
        }

        private string ArenaHelp()
        {
            return "Arenes : <color=#ffd479>aleatoire</color>, " + string.Join(", ", ArenaTemplates.Select(entry => $"<color=#ffd479>{entry[0]}</color> ({entry[2]})").ToArray());
        }

        // ----- Modeles d'arene ------------------------------------------------
        //
        // Les equipes apparaissent en x = -25 et x = +25 (GetTeamSpawn), et les
        // spectateurs en x = +46. Tout modele doit donc laisser ces couloirs
        // degages et rester contenu dans un rayon de 38m.

        private const float ArenaRadius = 38f;

        private static readonly string[][] ArenaTemplates =
        {
            new[] { "cercle",   "Cercle",    "Enceinte ronde, couvertures dispersees. Le classique." },
            new[] { "carre",    "Carre",     "Enceinte carree, couvertures en quinconce. Angles francs." },
            new[] { "colonnes", "Colonnes",  "Foret de colonnes : beaucoup de contournements." },
            new[] { "couloirs", "Couloirs",  "Longs murs paralleles, lignes de tir marquees." },
            new[] { "chicanes", "Chicanes",  "Murs en zigzag, progression a couvert." },
            new[] { "ouverte",  "Ouverte",   "Presque aucune couverture : duel a l'ancienne." }
        };

        private static bool IsKnownArena(string id)
        {
            return !string.IsNullOrEmpty(id) && ArenaTemplates.Any(entry => string.Equals(entry[0], id, StringComparison.OrdinalIgnoreCase));
        }

        private static string ArenaLabel(string id)
        {
            string[] entry = ArenaTemplates.FirstOrDefault(candidate => string.Equals(candidate[0], id, StringComparison.OrdinalIgnoreCase));
            return entry != null ? entry[1] : id;
        }

        private string ResolveArenaTemplate()
        {
            string preferred = _data != null ? _data.Arene : string.Empty;
            if (IsKnownArena(preferred)) return preferred.ToLowerInvariant();
            // "aleatoire", vide ou valeur inconnue : on tire au sort, ce qui evite
            // qu'une preference obsolete bloque la construction.
            return ArenaTemplates[UnityEngine.Random.Range(0, ArenaTemplates.Length)][0];
        }

        private void BuildArena()
        {
            RemoveArena();
            _arenaCenter = FindArenaCenter();
            _currentArena = ResolveArenaTemplate();

            BuildPerimeter(_currentArena);
            BuildInterior(_currentArena);

            Puts($"Arene Duel {_teamSize}v{_teamSize} modele {ArenaLabel(_currentArena)} construite en {_arenaCenter} avec {_arenaEntities.Count} elements.");
            BroadcastMatch($"Arene : <color=#ffd479>{ArenaLabel(_currentArena)}</color>.");
        }

        private void BuildPerimeter(string template)
        {
            if (template == "carre")
            {
                // Quatre cotes droits. Le pas de 6m correspond a la largeur d'un
                // mur externe, pour eviter les interstices franchissables.
                const float half = ArenaRadius;
                const float step = 6f;
                for (float offset = -half; offset <= half; offset += step)
                {
                    SpawnArenaEntity(WallPrefab, GroundPosition(_arenaCenter + new Vector3(offset, 0f, -half)), Quaternion.Euler(0f, 0f, 0f));
                    SpawnArenaEntity(WallPrefab, GroundPosition(_arenaCenter + new Vector3(offset, 0f, half)), Quaternion.Euler(0f, 180f, 0f));
                    SpawnArenaEntity(WallPrefab, GroundPosition(_arenaCenter + new Vector3(-half, 0f, offset)), Quaternion.Euler(0f, 90f, 0f));
                    SpawnArenaEntity(WallPrefab, GroundPosition(_arenaCenter + new Vector3(half, 0f, offset)), Quaternion.Euler(0f, 270f, 0f));
                }
                return;
            }

            const int wallCount = 44;
            for (int index = 0; index < wallCount; index++)
            {
                float angle = index * Mathf.PI * 2f / wallCount;
                Vector3 offset = new Vector3(Mathf.Cos(angle), 0f, Mathf.Sin(angle)) * ArenaRadius;
                SpawnArenaEntity(WallPrefab, GroundPosition(_arenaCenter + offset), Quaternion.Euler(0f, -angle * Mathf.Rad2Deg, 0f));
            }
        }

        private void BuildInterior(string template)
        {
            switch (template)
            {
                case "colonnes":
                    // Grille de colonnes, en sautant la bande centrale des spawns.
                    for (int x = -3; x <= 3; x++)
                    {
                        for (int z = -2; z <= 2; z++)
                        {
                            if (x == 0 && z == 0) continue;
                            Vector3 position = new Vector3(x * 8f, 0f, z * 9f);
                            if (Mathf.Abs(position.x) > 22f) continue;
                            SpawnArenaEntity(WallPrefab, GroundPosition(_arenaCenter + position), Quaternion.Euler(0f, (x + z) % 2 == 0 ? 0f : 90f, 0f));
                        }
                    }
                    break;

                case "couloirs":
                    for (int lane = -1; lane <= 1; lane++)
                    {
                        float z = lane * 12f;
                        for (float x = -18f; x <= 18f; x += 6f)
                        {
                            if (Mathf.Abs(x) < 4f) continue;
                            SpawnArenaEntity(WallPrefab, GroundPosition(_arenaCenter + new Vector3(x, 0f, z)), Quaternion.Euler(0f, 0f, 0f));
                        }
                    }
                    break;

                case "chicanes":
                    for (int index = 0; index < 6; index++)
                    {
                        float x = -20f + index * 8f;
                        float z = index % 2 == 0 ? -9f : 9f;
                        for (int piece = 0; piece < 3; piece++)
                        {
                            SpawnArenaEntity(WallPrefab, GroundPosition(_arenaCenter + new Vector3(x, 0f, z + piece * 6f)), Quaternion.Euler(0f, 90f, 0f));
                        }
                    }
                    break;

                case "ouverte":
                    foreach (Vector3 offset in new[] { new Vector3(-8f, 0f, 0f), new Vector3(8f, 0f, 0f), new Vector3(0f, 0f, -12f), new Vector3(0f, 0f, 12f) })
                    {
                        SpawnArenaEntity(SandbagCoverPrefab, GroundPosition(_arenaCenter + offset), Quaternion.Euler(0f, offset.x != 0f ? 0f : 90f, 0f));
                    }
                    break;

                case "carre":
                    for (int x = -2; x <= 2; x++)
                    {
                        for (int z = -1; z <= 1; z++)
                        {
                            if (x == 0 && z == 0) continue;
                            Vector3 position = new Vector3(x * 11f, 0f, z * 13f + (x % 2 == 0 ? 0f : 5f));
                            string prefab = (x + z) % 2 == 0 ? SandbagCoverPrefab : ConcreteCoverPrefab;
                            SpawnArenaEntity(prefab, GroundPosition(_arenaCenter + position), Quaternion.Euler(0f, (x + z) % 2 == 0 ? 0f : 90f, 0f));
                        }
                    }
                    break;

                default:
                    Vector3[] coverOffsets =
                    {
                        new Vector3(-14f,0f,-10f), new Vector3(-14f,0f,10f), new Vector3(14f,0f,-10f), new Vector3(14f,0f,10f),
                        new Vector3(-2f,0f,-17f), new Vector3(2f,0f,17f), new Vector3(-6f,0f,0f), new Vector3(6f,0f,0f),
                        new Vector3(-25f,0f,-16f), new Vector3(-25f,0f,16f), new Vector3(25f,0f,-16f), new Vector3(25f,0f,16f)
                    };
                    for (int index = 0; index < coverOffsets.Length; index++)
                    {
                        string prefab = index % 3 == 0 ? SandbagCoverPrefab : ConcreteCoverPrefab;
                        SpawnArenaEntity(prefab, GroundPosition(_arenaCenter + coverOffsets[index]), Quaternion.Euler(0f, index % 2 == 0 ? 0f : 90f, 0f));
                    }
                    break;
            }
        }

        private Vector3 FindArenaCenter()
        {
            float halfSize = TerrainMeta.Size.x * 0.5f;
            float limit = Mathf.Max(100f, halfSize * 0.75f);
            for (int attempt = 0; attempt < 140; attempt++)
            {
                Vector3 candidate = new Vector3(UnityEngine.Random.Range(-limit, limit), 0f, UnityEngine.Random.Range(-limit, limit));
                if (!IsArenaCandidate(candidate)) continue;
                candidate.y = TerrainMeta.HeightMap.GetHeight(candidate) + 0.1f;
                return candidate;
            }

            // Second passage sans la contrainte de planete : mesure faite sur six
            // constructions, la recherche stricte echouait deux fois sur six et
            // renvoyait tout le monde au centre de carte. Mieux vaut une arene
            // legerement vallonnee qu'une arene empilee sur la precedente.
            for (int attempt = 0; attempt < 140; attempt++)
            {
                Vector3 candidate = new Vector3(UnityEngine.Random.Range(-limit, limit), 0f, UnityEngine.Random.Range(-limit, limit));
                if (!IsArenaCandidate(candidate, false)) continue;
                candidate.y = TerrainMeta.HeightMap.GetHeight(candidate) + 0.1f;
                return candidate;
            }

            foreach (Vector3 fallback in new[] { Vector3.zero, new Vector3(300f,0f,0f), new Vector3(-300f,0f,0f), new Vector3(0f,0f,300f), new Vector3(0f,0f,-300f) }.OrderBy(value => UnityEngine.Random.value))
            {
                if (!IsArenaCandidate(fallback)) continue;
                Vector3 result = fallback;
                result.y = TerrainMeta.HeightMap.GetHeight(result) + 0.1f;
                return result;
            }
            Vector3 center = Vector3.zero;
            center.y = TerrainMeta.HeightMap.GetHeight(center) + 0.1f;
            return center;
        }

        private bool IsArenaCandidate(Vector3 candidate)
        {
            return IsArenaCandidate(candidate, true);
        }

        private bool IsArenaCandidate(Vector3 candidate, bool requireFlat)
        {
            float terrain = TerrainMeta.HeightMap.GetHeight(candidate);
            float water = TerrainMeta.WaterMap.GetHeight(candidate);
            // 3m au-dessus de la mer, et non -1 : WaterMap ne couvre que les lacs
            // et rivieres, jamais l'ocean, donc elle ne rattrapait pas un terrain
            // immerge. Le seuil de -1 acceptait explicitement du sol sous l'eau.
            // La planeite reste exigee au premier passage, relachee au second.
            if (terrain < 3f || terrain <= water + 2f) return false;
            if (requireFlat && !IsFlatEnough(candidate)) return false;
            if (TerrainMeta.Path != null && TerrainMeta.Path.Monuments != null)
            {
                foreach (MonumentInfo monument in TerrainMeta.Path.Monuments)
                {
                    if (monument == null) continue;
                    Vector3 delta = monument.transform.position - candidate;
                    delta.y = 0f;
                    if (delta.sqrMagnitude < 125f * 125f) return false;
                }
            }
            return true;
        }

        private bool IsFlatEnough(Vector3 position)
        {
            float min = float.MaxValue;
            float max = float.MinValue;
            foreach (Vector3 offset in new[]
            {
                Vector3.zero, new Vector3(34f,0f,0f), new Vector3(-34f,0f,0f), new Vector3(0f,0f,34f), new Vector3(0f,0f,-34f),
                new Vector3(24f,0f,24f), new Vector3(-24f,0f,24f), new Vector3(24f,0f,-24f), new Vector3(-24f,0f,-24f)
            })
            {
                float height = TerrainMeta.HeightMap.GetHeight(position + offset);
                min = Mathf.Min(min, height);
                max = Mathf.Max(max, height);
            }
            return max - min <= 4.5f;
        }

        private void SpawnArenaEntity(string prefab, Vector3 position, Quaternion rotation)
        {
            BaseEntity entity = GameManager.server.CreateEntity(prefab, position, rotation, true);
            if (entity == null)
            {
                PrintWarning($"Prefab Duel introuvable : {prefab}");
                return;
            }
            entity.enableSaving = false;
            entity.Spawn();
            _arenaEntities.Add(entity);
        }

        private void RemoveArena()
        {
            foreach (BaseEntity entity in _arenaEntities.ToArray())
            {
                if (entity != null && !entity.IsDestroyed) entity.Kill();
            }
            _arenaEntities.Clear();
            _arenaCenter = Vector3.zero;
        }

        private Vector3 GetTeamSpawn(int team, int index)
        {
            float x = team == 1 ? -25f : 25f;
            float z = (index - ((_teamSize - 1) * 0.5f)) * 6f;
            Vector3 result = GroundPosition(_arenaCenter + new Vector3(x, 0f, z));
            result.y += 1.2f;
            return result;
        }

        private Vector3 GetSpectatorSpawn()
        {
            Vector3 result = GroundPosition(_arenaCenter + new Vector3(46f, 0f, 0f));
            result.y += 1.2f;
            return result;
        }

        private Vector3 GroundPosition(Vector3 position)
        {
            position.y = TerrainMeta.HeightMap.GetHeight(position);
            return position;
        }

        private void GiveDuelKit(BasePlayer player)
        {
            if (player == null || !player.IsConnected) return;
            RemoveDuelItems(player);
            DuelKit kit = FindDuelKit(SelectedKit(player.userID)) ?? DuelKits[0];
            GiveNamedItem(player, kit.Arme, 1, kit.ArmeLabel);
            if (!string.IsNullOrEmpty(kit.Munition)) GiveNamedItem(player, kit.Munition, kit.MunitionQuantite, "Munitions illimitees");
            GiveNamedItem(player, "syringe.medical", 4, "Soins");
            // Sans arme a projectile, FillActiveMagazine ne trouve rien : inutile en melee.
            if (!kit.Melee) timer.Once(0.15f, () => FillActiveMagazine(player));
        }

        /// <summary>
        /// Les skins choisis avec MES SKINS (stockes par le Gun Game) valent dans
        /// tous les modes : un seul reglage pour toutes les armes du joueur.
        /// </summary>
        private void ApplySharedSkin(BasePlayer player, Item item, string shortname)
        {
            if (player == null || item == null) return;
            object skin = Interface.CallHook("GetPlayerWeaponSkin", player, shortname);
            if (!(skin is ulong) || (ulong)skin == 0UL) return;
            item.skin = (ulong)skin;
            BaseEntity held = item.GetHeldEntity();
            if (held != null)
            {
                held.skinID = (ulong)skin;
                held.SendNetworkUpdate();
            }
        }

        private void GiveNamedItem(BasePlayer player, string shortname, int amount, string label)
        {
            Item item = ItemManager.CreateByName(shortname, amount);
            if (item == null)
            {
                PrintWarning($"Objet Duel introuvable : {shortname}");
                return;
            }
            item.name = ItemPrefix + label;
            if (item.hasCondition) item.condition = item.maxCondition;
            ApplySharedSkin(player, item, shortname);
            // player.GiveItem laisse tomber l'objet au sol quand l'inventaire est
            // plein : il echappe alors au nettoyage par prefixe et pollue la carte.
            if (player.inventory == null || !player.inventory.GiveItem(item))
            {
                item.Remove();
                SendReply(player, "<color=#e76a4c>Inventaire plein</color> : libere de la place pour recevoir ton kit de duel.");
            }
        }

        private void FillActiveMagazine(BasePlayer player)
        {
            if (player == null) return;
            foreach (Item item in PlayerItems(player))
            {
                if (item == null || string.IsNullOrEmpty(item.name) || !item.name.StartsWith(ItemPrefix, StringComparison.Ordinal)) continue;
                BaseProjectile projectile = item.GetHeldEntity() as BaseProjectile;
                if (projectile == null || projectile.primaryMagazine == null) continue;
                projectile.primaryMagazine.contents = projectile.primaryMagazine.capacity;
                projectile.SendNetworkUpdateImmediate();
                item.MarkDirty();
            }
        }

        private bool IsUsingDuelWeapon(BasePlayer player)
        {
            Item active = player != null ? player.GetActiveItem() : null;
            return active != null && !string.IsNullOrEmpty(active.name) && active.name.StartsWith(ItemPrefix, StringComparison.Ordinal);
        }

        private void RemoveDuelItems(BasePlayer player)
        {
            foreach (Item item in PlayerItems(player).ToArray())
            {
                if (item != null && !string.IsNullOrEmpty(item.name) && item.name.StartsWith(ItemPrefix, StringComparison.Ordinal)) item.Remove();
            }
        }

        private IEnumerable<Item> PlayerItems(BasePlayer player)
        {
            if (player == null || player.inventory == null) return Enumerable.Empty<Item>();
            List<Item> items = new List<Item>();
            if (player.inventory.containerMain != null) items.AddRange(player.inventory.containerMain.itemList);
            if (player.inventory.containerBelt != null) items.AddRange(player.inventory.containerBelt.itemList);
            if (player.inventory.containerWear != null) items.AddRange(player.inventory.containerWear.itemList);
            return items;
        }

        private void ReturnPlayer(BasePlayer player)
        {
            if (player == null || !player.IsConnected) return;
            Vector3 position;
            if (!_returnPositions.TryGetValue(player.userID, out position)) return;
            if (player.IsDead())
            {
                _allowRoundRespawn = true;
                player.RespawnAt(position, Quaternion.identity);
                _allowRoundRespawn = false;
            }
            else player.Teleport(position);
        }

        private IEnumerable<BasePlayer> MatchPlayers()
        {
            return _participants.Select(FindActivePlayer).Where(player => player != null);
        }

        private BasePlayer FindActivePlayer(ulong userId)
        {
            return BasePlayer.activePlayerList.FirstOrDefault(player => player != null && player.userID == userId);
        }

        private int TeamIndex(ulong userId)
        {
            int team = TeamOf(userId);
            return _participants.Where(id => TeamOf(id) == team).OrderBy(id => id).ToList().IndexOf(userId);
        }

        private int TeamOf(ulong userId)
        {
            int team;
            return _teams.TryGetValue(userId, out team) ? team : 0;
        }

        private int ParseTeamSize(string value)
        {
            string normalized = value.Replace("vs", "v").Replace("x", "v");
            for (int size = 1; size <= 4; size++)
            {
                if (normalized == size.ToString() || normalized == $"{size}v{size}") return size;
            }
            return 0;
        }

        private int QueueOf(ulong userId)
        {
            foreach (KeyValuePair<int, List<ulong>> pair in _queues)
            {
                if (pair.Value.Contains(userId)) return pair.Key;
            }
            return 0;
        }

        private void RemoveFromQueues(ulong userId)
        {
            foreach (List<ulong> queue in _queues.Values) queue.Remove(userId);
        }

        private void BroadcastQueue(int size, string message)
        {
            foreach (ulong userId in _queues[size].ToArray())
            {
                BasePlayer player = FindActivePlayer(userId);
                if (player != null) SendReply(player, message);
            }
        }

        private void BroadcastMatch(string message)
        {
            foreach (BasePlayer player in MatchPlayers()) SendReply(player, message);
            foreach (ulong spectatorId in _spectators.ToArray())
            {
                BasePlayer spectator = FindActivePlayer(spectatorId);
                if (spectator != null) SendReply(spectator, "[SPECTATEUR] " + message);
            }
        }

        private void BroadcastGlobal(string message)
        {
            foreach (BasePlayer player in BasePlayer.activePlayerList)
            {
                if (player != null && player.IsConnected) SendReply(player, message);
            }
        }

        private bool IsOtherModeParticipant(BasePlayer player, string hookName)
        {
            object hook = Interface.CallHook(hookName, player);
            return hook is bool && (bool)hook;
        }

        private int GetValue(Dictionary<ulong, int> values, ulong userId)
        {
            int value;
            return values.TryGetValue(userId, out value) ? value : 0;
        }

        private int GetRating(ulong userId)
        {
            int rating;
            if (!_data.Cotes.TryGetValue(userId, out rating))
            {
                rating = 1000;
                _data.Cotes[userId] = rating;
            }
            return rating;
        }

        private string RankName(int rating)
        {
            if (rating < 800) return "FER";
            if (rating < 1000) return "BRONZE";
            if (rating < 1200) return "ARGENT";
            if (rating < 1400) return "OR";
            if (rating < 1600) return "PLATINE";
            if (rating < 1800) return "DIAMANT";
            return "ELITE";
        }

        private string SelectedKit(ulong userId)
        {
            string kit;
            if (!_data.Kits.TryGetValue(userId, out kit) || FindDuelKit(kit) == null) return "sar";
            return kit;
        }

        private void UpdateRatings(int winningTeam, List<ulong> participantIds)
        {
            List<ulong> red = participantIds.Where(userId => TeamOf(userId) == 1).ToList();
            List<ulong> blue = participantIds.Where(userId => TeamOf(userId) == 2).ToList();
            if (red.Count == 0 || blue.Count == 0) return;
            double redAverage = red.Average(userId => GetRating(userId));
            double blueAverage = blue.Average(userId => GetRating(userId));
            double redExpected = 1d / (1d + Math.Pow(10d, (blueAverage - redAverage) / 400d));
            double blueExpected = 1d - redExpected;
            int redDelta = (int)Math.Round(32d * ((winningTeam == 1 ? 1d : 0d) - redExpected));
            int blueDelta = (int)Math.Round(32d * ((winningTeam == 2 ? 1d : 0d) - blueExpected));
            foreach (ulong userId in red) ApplyRatingDelta(userId, redDelta);
            foreach (ulong userId in blue) ApplyRatingDelta(userId, blueDelta);
        }

        private void ApplyRatingDelta(ulong userId, int delta)
        {
            int next = Math.Max(100, GetRating(userId) + delta);
            _data.Cotes[userId] = next;
            BasePlayer player = FindActivePlayer(userId);
            if (player != null) SendReply(player, $"Classement : {(delta >= 0 ? "+" : string.Empty)}{delta} ELO -> <color=#ffd479>{RankName(next)} {next}</color>.");
        }

        private string[] ConsoleArgs(ConsoleSystem.Arg arg)
        {
            return arg.Args == null ? new string[0] : arg.Args.Select(value => value.ToString()).ToArray();
        }

        private void LoadData()
        {
            try { _data = Interface.Oxide.DataFileSystem.ReadObject<StoredData>(Name); }
            catch { _data = new StoredData(); }
            if (_data == null) _data = new StoredData();
            if (_data.Victoires == null) _data.Victoires = new Dictionary<ulong, int>();
            if (_data.Defaites == null) _data.Defaites = new Dictionary<ulong, int>();
            if (_data.Cotes == null) _data.Cotes = new Dictionary<ulong, int>();
            if (_data.Kits == null) _data.Kits = new Dictionary<ulong, string>();
            if (_data.Tournois == null) _data.Tournois = new Dictionary<ulong, int>();
            if (_data.Noms == null) _data.Noms = new Dictionary<ulong, string>();
        }

        private void SaveData()
        {
            Interface.Oxide.DataFileSystem.WriteObject(Name, _data);
        }
    }
}
