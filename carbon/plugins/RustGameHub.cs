using System;
using System.Collections.Generic;
using System.Globalization;
using System.Linq;
using System.Text;
using System.Text.RegularExpressions;
using Oxide.Core;
using Oxide.Core.Plugins;
using Oxide.Game.Rust.Cui;
using UnityEngine;

namespace Oxide.Plugins
{
    [Info("RustGameHub", "OpenAI", "2.3.0")]
    [Description("Lobby central protege avec huit portails et modes CTF, Domination, Search & Destroy et Extraction.")]
    public class RustGameHub : RustPlugin
    {
        private const string ModeItemPrefix = "Mode Competitif - ";
        private const string WallPrefab = "assets/prefabs/building/wall.external.high.stone/wall.external.high.stone.prefab";
        private const string ConcretePrefab = "assets/prefabs/deployable/barricades/barricade.concrete.prefab";
        private const string SandbagPrefab = "assets/prefabs/deployable/barricades/barricade.sandbags.prefab";
        private const string RugPrefab = "assets/prefabs/deployable/rug/rug.deployed.prefab";
        private const string SignPrefab = "assets/prefabs/deployable/signs/sign.post.single.prefab";
        private const string GuidePrefab = "assets/prefabs/npc/bandit/shopkeepers/bandit_conversationalist.prefab";

        private readonly Dictionary<string, List<ulong>> _queues = new Dictionary<string, List<ulong>>();
        private readonly HashSet<ulong> _participants = new HashSet<ulong>();
        private readonly HashSet<ulong> _alive = new HashSet<ulong>();
        private readonly Dictionary<ulong, int> _teams = new Dictionary<ulong, int>();
        private readonly Dictionary<ulong, Vector3> _returnPositions = new Dictionary<ulong, Vector3>();
        private readonly HashSet<ulong> _lobbyPlayers = new HashSet<ulong>();
        private readonly Dictionary<ulong, Vector3> _lobbyReturnPositions = new Dictionary<ulong, Vector3>();
        private readonly Dictionary<ulong, float> _portalCooldowns = new Dictionary<ulong, float>();
        private readonly List<BaseEntity> _arenaEntities = new List<BaseEntity>();
        private readonly List<BaseEntity> _lobbyEntities = new List<BaseEntity>();
        private readonly HashSet<BasePlayer> _lobbyGuides = new HashSet<BasePlayer>();
        private readonly Dictionary<ulong, int> _flagCarriers = new Dictionary<ulong, int>();
        private readonly Dictionary<ulong, int> _extractionLoot = new Dictionary<ulong, int>();

        private readonly string[] _modeOrder = { "ctf", "domination", "snd", "extraction" };
        private readonly bool[] _extractionAvailable = new bool[6];
        private List<PortalDefinition> _portals;
        private readonly HashSet<ulong> _menuOpen = new HashSet<ulong>();
        private readonly Dictionary<ulong, string> _menuPage = new Dictionary<ulong, string>();
        private readonly Dictionary<ulong, float> _menuOpenedAt = new Dictionary<ulong, float>();
        private Vector3 _lobbyCenter;
        private Vector3 _arenaCenter;
        private string _activeMode = string.Empty;
        private string _scheduledMode = string.Empty;
        private bool _matchActive;
        private bool _roundActive;
        private bool _redFlagAvailable;
        private bool _blueFlagAvailable;
        private bool _bombPlanted;
        private float _bombPlantedAt;
        private int _scoreRed;
        private int _scoreBlue;
        private int _sndRound;
        private int _sessionId;

        private class PortalDefinition
        {
            public string Key;
            public string Label;
            public Vector3 Offset;

            public PortalDefinition(string key, string label, Vector3 offset)
            {
                Key = key;
                Label = label;
                Offset = offset;
            }
        }

        private void Init()
        {
            foreach (string mode in _modeOrder) _queues[mode] = new List<ulong>();
        }

        private void OnServerInitialized()
        {
            timer.Every(1f, Tick);
            timer.Once(5f, BuildLobby);
            // Rechargement a chaud : les joueurs deja en ligne n'ont pas de
            // bouton tant qu'on ne le repose pas.
            foreach (BasePlayer online in BasePlayer.activePlayerList)
            {
                ShowInventoryButton(online);
            }
            Puts("Game Hub pret : lobby, CTF, Domination, Search & Destroy et Extraction.");
        }

        private void Unload()
        {
            _sessionId++;
            if (_dayLocked) ConsoleSystem.Run(ConsoleSystem.Option.Server.Quiet(), "env.progresstime", true);
            CloseAllMenus();
            foreach (BasePlayer online in BasePlayer.activePlayerList.ToArray())
            {
                CuiHelper.DestroyUi(online, InventoryButtonPanel);
            }
            foreach (BasePlayer player in BasePlayer.activePlayerList.ToArray())
            {
                RemoveModeItems(player);
                if (_participants.Contains(player.userID)) ReturnParticipant(player);
                if (_lobbyPlayers.Contains(player.userID)) ReturnLobbyPlayer(player);
            }
            RemoveArena();
            RemoveLobby();
        }

        private object ForceLeaveMode(BasePlayer player)
        {
            if (player == null) return null;
            bool inMode = _participants.Contains(player.userID) || _queues.Values.Any(queue => queue.Contains(player.userID));
            bool inLobby = _lobbyPlayers.Contains(player.userID);
            if (!inMode && !inLobby) return null;
            CloseMenu(player);
            if (IsMiniGameServer())
            {
                // Le lobby est le point de depart : on n'en sort pas. Un joueur
                // en partie ou en file la quitte et le lobby le recupere.
                if (!inMode) return null;
                LeaveMode(player);
                return true;
            }
            if (inLobby) LeaveLobby(player, true);
            else LeaveMode(player);
            return true;
        }

        /// <summary>
        /// Libere UN joueur de tout mode ou il serait coince. Un seul CallHook
        /// atteint les six plugins ; chacun ignore les joueurs qui ne sont pas
        /// chez lui, donc la partie des autres n'est jamais interrompue.
        /// </summary>
        [ConsoleCommand("admin.free")]
        private void ConsoleAdminFree(ConsoleSystem.Arg arg)
        {
            BasePlayer caller = arg.Player();
            if (caller != null && !caller.IsAdmin) { arg.ReplyWith("Commande reservee aux administrateurs."); return; }

            string[] args = MenuArgs(arg);
            if (args.Length == 0) { arg.ReplyWith("Usage : admin.free <steamid ou nom>"); return; }

            string selector = args[0];
            BasePlayer target = BasePlayer.activePlayerList.FirstOrDefault(player =>
                player.UserIDString == selector ||
                player.displayName.IndexOf(selector, StringComparison.OrdinalIgnoreCase) >= 0);
            if (target == null) { arg.ReplyWith("Joueur connecte introuvable."); return; }

            Interface.CallHook("ForceLeaveMode", target);
            arg.ReplyWith($"{target.displayName} a ete sorti de tout mode en cours.");
        }

        [ConsoleCommand("admin.heal")]
        private void ConsoleAdminHeal(ConsoleSystem.Arg arg)
        {
            BasePlayer caller = arg.Player();
            if (caller != null && !caller.IsAdmin) { arg.ReplyWith("Commande reservee aux administrateurs."); return; }

            string[] args = MenuArgs(arg);
            if (args.Length == 0) { arg.ReplyWith("Usage : admin.heal <steamid ou nom>"); return; }

            BasePlayer target = FindConnectedPlayer(args[0]);
            if (target == null) { arg.ReplyWith("Joueur connecte introuvable."); return; }

            target.Heal(1000f);
            if (target.metabolism != null)
            {
                target.metabolism.bleeding.value = 0f;
                target.metabolism.poison.value = 0f;
                target.metabolism.radiation_level.value = 0f;
                target.metabolism.SendChangesToClient();
            }
            target.SendNetworkUpdateImmediate();
            target.ChatMessage("<color=#72D79B>[ADMIN]</color> Tu as ete soigne.");
            arg.ReplyWith($"{target.displayName} a ete soigne.");
        }

        [ConsoleCommand("admin.message")]
        private void ConsoleAdminMessage(ConsoleSystem.Arg arg)
        {
            BasePlayer caller = arg.Player();
            if (caller != null && !caller.IsAdmin) { arg.ReplyWith("Commande reservee aux administrateurs."); return; }

            string[] args = MenuArgs(arg);
            if (args.Length < 2) { arg.ReplyWith("Usage : admin.message <steamid ou nom> <message>"); return; }

            BasePlayer target = FindConnectedPlayer(args[0]);
            if (target == null) { arg.ReplyWith("Joueur connecte introuvable."); return; }

            string message = string.Join(" ", args.Skip(1).ToArray()).Trim();
            if (message.Length > 300) message = message.Substring(0, 300);
            if (string.IsNullOrEmpty(message)) { arg.ReplyWith("Le message est vide."); return; }

            target.ChatMessage($"<color=#E75B3B>[MESSAGE ADMIN]</color> {message}");
            arg.ReplyWith($"Message prive envoye a {target.displayName}.");
        }

        private BasePlayer FindConnectedPlayer(string selector)
        {
            if (string.IsNullOrWhiteSpace(selector)) return null;
            return BasePlayer.activePlayerList.FirstOrDefault(player =>
                player.UserIDString == selector ||
                player.displayName.IndexOf(selector, StringComparison.OrdinalIgnoreCase) >= 0);
        }

        private object IsCompetitiveModeParticipant(BasePlayer player)
        {
            return player != null && (_participants.Contains(player.userID) || _queues.Values.Any(queue => queue.Contains(player.userID)));
        }

        private object IsCompetitiveModeFight(BasePlayer attacker, BasePlayer victim)
        {
            if (!_matchActive || !_roundActive || attacker == null || victim == null) return false;
            if (!_alive.Contains(attacker.userID) || !_alive.Contains(victim.userID)) return false;
            if (!_participants.Contains(attacker.userID) || !_participants.Contains(victim.userID)) return false;
            return _activeMode == "extraction" || TeamOf(attacker.userID) != TeamOf(victim.userID);
        }

        private object OnEntityTakeDamage(BaseCombatEntity entity, HitInfo info)
        {
            if (entity == null || info == null) return null;
            // Structure du lobby : ni degats ni usure (la deterioration passe
            // aussi par ce hook).
            if (_lobbyProtected.Contains(entity))
            {
                info.damageTypes.ScaleAll(0f);
                return true;
            }
            BasePlayer victim = entity as BasePlayer;
            BasePlayer attacker = info.InitiatorPlayer;
            // Protection par position, pas par appartenance a une liste : un
            // joueur qui vient de partir en duel ne doit pas rester invincible
            // une seconde de trop, et personne ne se bat au lobby.
            if (victim != null && (_lobbyGuides.Contains(victim) || (IsInLobbyZone(victim.transform.position) && !_participants.Contains(victim.userID))))
            {
                info.damageTypes.ScaleAll(0f);
                return true;
            }
            if (attacker != null && IsInLobbyZone(attacker.transform.position) && !_participants.Contains(attacker.userID))
            {
                info.damageTypes.ScaleAll(0f);
                return true;
            }
            if (victim == null || attacker == null) return null;
            bool victimInMode = _participants.Contains(victim.userID);
            bool attackerInMode = _participants.Contains(attacker.userID);
            if (!victimInMode && !attackerInMode) return null;
            bool allowed = _roundActive && victimInMode && attackerInMode && _alive.Contains(victim.userID) && _alive.Contains(attacker.userID) &&
                           (_activeMode == "extraction" || TeamOf(victim.userID) != TeamOf(attacker.userID));
            if (allowed) return null;
            info.damageTypes.ScaleAll(0f);
            return true;
        }

        private void OnWeaponFired(BaseProjectile projectile, BasePlayer player, ItemModProjectile mod, ProtoBuf.ProjectileShoot projectiles)
        {
            if (projectile == null || player == null || !_participants.Contains(player.userID) || !_roundActive || !IsUsingModeWeapon(player)) return;
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
            if (player == null || !_matchActive || !_participants.Contains(player.userID)) return;
            _alive.Remove(player.userID);
            int carriedFlag;
            if (_flagCarriers.TryGetValue(player.userID, out carriedFlag))
            {
                if (carriedFlag == 1) _redFlagAvailable = true; else _blueFlagAvailable = true;
                _flagCarriers.Remove(player.userID);
                BroadcastMode($"{player.displayName} perd le drapeau : il retourne a sa base.");
            }
            if (_activeMode == "extraction")
            {
                _extractionLoot[player.userID] = 0;
                for (int index = 0; index < _extractionAvailable.Length; index++) _extractionAvailable[index] = true;
            }
            if (_activeMode == "snd")
            {
                timer.Once(0.2f, EvaluateSndRound);
                return;
            }
            int session = _sessionId;
            timer.Once(4f, () =>
            {
                if (_matchActive && session == _sessionId && _participants.Contains(player.userID)) RespawnParticipant(player);
            });
        }

        private void OnPlayerRespawned(BasePlayer player)
        {
            // Un panneau survivant a une mort laisserait le joueur curseur libere
            // et incapable de bouger a la reapparition.
            CloseMenu(player);
            ShowInventoryButton(player);
            if (player != null && IsMiniGameServer() && !_lobbyExempt.Contains(player.userID) && !IsPlayingSomewhere(player))
            {
                // Les modes gerent la reapparition de leurs joueurs ; les autres
                // reviennent au lobby, pas sur une plage.
                timer.Once(0.3f, () =>
                {
                    if (player != null && player.IsConnected && !IsPlayingSomewhere(player) && !_lobbyExempt.Contains(player.userID)) SendToLobby(player);
                });
            }
            if (player == null || !_participants.Contains(player.userID)) return;
            timer.Once(0.2f, () =>
            {
                if (player == null || !player.IsConnected || !_participants.Contains(player.userID)) return;
                if (_activeMode == "snd" && !_alive.Contains(player.userID))
                {
                    player.Teleport(GetSpectatorPoint());
                    RemoveModeItems(player);
                    return;
                }
                _alive.Add(player.userID);
                player.Teleport(GetModeSpawn(player.userID));
                GiveModeKit(player);
            });
        }

        private void OnPlayerDisconnected(BasePlayer player, string reason)
        {
            if (player == null) return;
            CloseMenu(player);
            CuiHelper.DestroyUi(player, InventoryButtonPanel);
            _lobbyExempt.Remove(player.userID);
            _lobbyEditors.Remove(player.userID);
            RemoveFromAllQueues(player.userID);
            _lobbyPlayers.Remove(player.userID);
            _lobbyReturnPositions.Remove(player.userID);
            // Sans cette ligne le dictionnaire gardait une entree par joueur, a vie.
            _portalCooldowns.Remove(player.userID);
            if (!_participants.Remove(player.userID)) return;
            _alive.Remove(player.userID);
            _returnPositions.Remove(player.userID);
            _teams.Remove(player.userID);
            if (_participants.Count == 0) FinishMode(0, null, "Mode termine : tous les joueurs sont partis.");
            else if (_activeMode != "extraction" && !_teams.Values.Contains(1)) FinishMode(2, null, "Equipe BLEUE gagne par forfait.");
            else if (_activeMode != "extraction" && !_teams.Values.Contains(2)) FinishMode(1, null, "Equipe ROUGE gagne par forfait.");
        }

        [ChatCommand("lobby")]
        private void CommandLobby(BasePlayer player, string command, string[] args)
        {
            string action = args.Length > 0 ? args[0].ToLowerInvariant() : string.Empty;
            if (player != null && player.IsAdmin && HandleLobbyAdmin(player, action, args)) return;
            if (IsMiniGameServer())
            {
                if (action == "leave" || action == "quitter")
                {
                    // Sur un serveur mini-jeux on ne quitte pas le lobby, sauf un
                    // admin qui doit pouvoir circuler et construire librement.
                    if (!player.IsAdmin) { SendReply(player, "Serveur mini-jeux : choisis un mode avec un portail ou le menu de ton inventaire."); return; }
                    _lobbyExempt.Add(player.userID);
                    _lobbyPlayers.Remove(player.userID);
                    SendReply(player, "Mode admin : tu n'es plus ramene au lobby. Tape /lobby pour y revenir.");
                    return;
                }
                _lobbyExempt.Remove(player.userID);
                if (IsPlayingSomewhere(player)) { SendReply(player, "Quitte d'abord ton mode de jeu actuel."); return; }
                SendToLobby(player);
                SendReply(player, "<color=#ffd479>LOBBY</color> - marche sur un portail ou ouvre le menu depuis ton inventaire.");
                return;
            }
            if (action == "leave" || action == "quitter")
            {
                LeaveLobby(player, true);
                return;
            }
            if (_lobbyPlayers.Contains(player.userID))
            {
                SendReply(player, "Tu es dans le lobby. Approche un portail ou tape /lobby leave.");
                return;
            }
            if (IsInAnyGame(player))
            {
                SendReply(player, "Quitte d'abord ton mode de jeu actuel.");
                return;
            }
            if (_lobbyEntities.Count == 0) BuildLobby();
            _lobbyReturnPositions[player.userID] = player.transform.position;
            _lobbyPlayers.Add(player.userID);
            player.Teleport(NextLobbySpawn());
            SendReply(player, "<color=#ffd479>LOBBY CENTRAL</color> - zone protegee. Les portails autour de toi lancent Duel, Zombie, Gun Game, CTF, Domination, S&D et Extraction.");
        }

        [ConsoleCommand("lobby.rebuild")]
        private void ConsoleLobbyRebuild(ConsoleSystem.Arg arg)
        {
            BasePlayer caller = arg.Player();
            if (caller != null && !caller.IsAdmin) { arg.ReplyWith("Commande reservee aux administrateurs."); return; }
            BuildLobby();
            foreach (ulong userId in _lobbyPlayers.ToArray())
            {
                BasePlayer player = FindPlayer(userId);
                if (player != null) player.Teleport(NextLobbySpawn());
            }
            arg.ReplyWith($"Lobby reconstruit en {_lobbyCenter} avec {_lobbyEntities.Count} elements et {_lobbyGuides.Count} guide(s).");
        }

        [ChatCommand("ctf")]
        private void CommandCtf(BasePlayer player, string command, string[] args) { ToggleModeQueue(player, "ctf"); }

        [ChatCommand("domination")]
        private void CommandDomination(BasePlayer player, string command, string[] args) { ToggleModeQueue(player, "domination"); }

        [ChatCommand("dom")]
        private void CommandDom(BasePlayer player, string command, string[] args) { ToggleModeQueue(player, "domination"); }

        [ChatCommand("snd")]
        private void CommandSnd(BasePlayer player, string command, string[] args) { ToggleModeQueue(player, "snd"); }

        [ChatCommand("extraction")]
        private void CommandExtraction(BasePlayer player, string command, string[] args) { ToggleModeQueue(player, "extraction"); }

        [ChatCommand("extract")]
        private void CommandExtract(BasePlayer player, string command, string[] args) { ToggleModeQueue(player, "extraction"); }

        [ChatCommand("modes")]
        private void CommandModes(BasePlayer player, string command, string[] args)
        {
            SendReply(player, "<color=#ffd479>MODES COMPETITIFS</color> - /ctf, /dom, /snd, /extract, /mode status, /mode leave, /plant et /defuse.");
            SendReply(player, $"Actif : {(string.IsNullOrEmpty(_activeMode) ? "aucun" : ModeLabel(_activeMode))}. Files : CTF {_queues["ctf"].Count}, DOM {_queues["domination"].Count}, S&D {_queues["snd"].Count}, Extraction {_queues["extraction"].Count}.");
        }

        [ChatCommand("mode")]
        private void CommandMode(BasePlayer player, string command, string[] args)
        {
            string action = args.Length > 0 ? args[0].ToLowerInvariant() : "status";
            if (action == "leave" || action == "quitter") LeaveMode(player);
            else CommandModes(player, "modes", new string[0]);
        }

        [ChatCommand("plant")]
        private void CommandPlant(BasePlayer player, string command, string[] args)
        {
            if (!_matchActive || _activeMode != "snd" || !_roundActive || !_alive.Contains(player.userID) || TeamOf(player.userID) != 1)
            {
                SendReply(player, "Tu dois etre attaquant vivant dans une manche S&D.");
                return;
            }
            if (_bombPlanted) { SendReply(player, "La charge est deja posee."); return; }
            if (HorizontalDistance(player.transform.position, GetSndTarget()) > 7f) { SendReply(player, "Approche-toi du site central pour poser la charge."); return; }
            _bombPlanted = true;
            _bombPlantedAt = Time.realtimeSinceStartup;
            BroadcastMode($"<color=#e76a4c>{player.displayName} a pose la charge !</color> Explosion dans 45 secondes.");
        }

        [ChatCommand("defuse")]
        private void CommandDefuse(BasePlayer player, string command, string[] args)
        {
            if (!_matchActive || _activeMode != "snd" || !_roundActive || !_alive.Contains(player.userID) || TeamOf(player.userID) != 2 || !_bombPlanted)
            {
                SendReply(player, "Aucune charge a desamorcer pour ton equipe.");
                return;
            }
            if (HorizontalDistance(player.transform.position, GetSndTarget()) > 7f) { SendReply(player, "Approche-toi de la charge."); return; }
            _bombPlanted = false;
            EndSndRound(2, $"{player.displayName} desamorce la charge.");
        }

        [ConsoleCommand("event.stop")]
        private void ConsoleEventStop(ConsoleSystem.Arg arg)
        {
            BasePlayer caller = arg.Player();
            if (caller != null && !caller.IsAdmin) { arg.ReplyWith("Commande reservee aux administrateurs."); return; }
            if (_matchActive) FinishMode(0, null, "Evenement arrete par un administrateur.");
            arg.ReplyWith("Evenement competitif arrete.");
        }

        [ConsoleCommand("event.start")]
        private void ConsoleEventStart(ConsoleSystem.Arg arg)
        {
            BasePlayer caller = arg.Player();
            if (caller != null && !caller.IsAdmin) { arg.ReplyWith("Commande reservee aux administrateurs."); return; }
            if (arg.Args == null || arg.Args.Length == 0) { arg.ReplyWith("Usage: event.start ctf|domination|snd|extraction"); return; }
            string mode = NormalizeMode(arg.Args[0].ToString());
            if (!_queues.ContainsKey(mode)) { arg.ReplyWith("Mode inconnu."); return; }
            if (_matchActive) { arg.ReplyWith($"Une partie {_activeMode} est deja active."); return; }
            _queues[mode].RemoveAll(userId => FindPlayer(userId) == null);
            int minimum = MinimumPlayers(mode);
            if (_queues[mode].Count < minimum) { arg.ReplyWith($"Impossible : {minimum} joueur(s) minimum dans la file {ModeLabel(mode)}. Actuel : {_queues[mode].Count}."); return; }
            StartMode(mode, true);
            arg.ReplyWith($"{ModeLabel(mode)} demarre avec {_participants.Count} joueur(s).");
        }

        [ConsoleCommand("event.debug")]
        private void ConsoleEventDebug(ConsoleSystem.Arg arg)
        {
            BasePlayer caller = arg.Player();
            if (caller != null && !caller.IsAdmin) { arg.ReplyWith("Commande reservee aux administrateurs."); return; }
            string queues = string.Join(", ", _modeOrder.Select(mode => $"{mode}={_queues[mode].Count}").ToArray());
            arg.ReplyWith($"active={_matchActive} mode={_activeMode} roundActive={_roundActive} players={_participants.Count} alive={_alive.Count} score={_scoreRed}-{_scoreBlue} lobbyPlayers={_lobbyPlayers.Count} lobbyEntities={_lobbyEntities.Count} arenaEntities={_arenaEntities.Count} queues=[{queues}]");
        }

        [ConsoleCommand("dashboard.modes")]
        private void ConsoleDashboardModes(ConsoleSystem.Arg arg)
        {
            BasePlayer caller = arg.Player();
            if (caller != null && !caller.IsAdmin) { arg.ReplyWith("Commande reservee aux administrateurs."); return; }
            string players = BasePlayer.activePlayerList.Count == 0
                ? "aucun joueur connecte"
                : string.Join(", ", BasePlayer.activePlayerList.Select(player => $"{player.displayName} ({player.UserIDString})").ToArray());
            string queues = string.Join(", ", _modeOrder.Select(mode => $"{ModeLabel(mode)}={_queues[mode].Count}").ToArray());
            object duel = Interface.CallHook("GetDuelDashboardStatus");
            object zombie = Interface.CallHook("GetZombieDashboardStatus");
            object gunGame = Interface.CallHook("GetGunGameDashboardStatus");
            object towerDefense = Interface.CallHook("GetTowerDefenseDashboardStatus");
            object training = Interface.CallHook("GetTrainingDashboardStatus");
            object rewards = Interface.CallHook("GetRewardDashboardStatus");
            string lobby = $"lobby={_lobbyPlayers.Count} elements={_lobbyEntities.Count} actif={_matchActive} mode={_activeMode} manche={_roundActive} score={_scoreRed}-{_scoreBlue} joueurs={_participants.Count} vivants={_alive.Count} files=[{queues}]";

            // "dashboard.modes json" sert les outils, la sortie texte reste la vue
            // console. Les deux passent par le meme appel de hooks : une seule
            // requete RCON suffit toujours a photographier le serveur.
            bool asJson = arg.Args != null && arg.Args.Length > 0 &&
                          arg.Args[0].ToString().Equals("json", StringComparison.OrdinalIgnoreCase);
            if (asJson)
            {
                arg.ReplyWith(BuildDashboardJson(lobby, duel, zombie, gunGame, towerDefense, training, rewards));
                return;
            }

            arg.ReplyWith(
                $"[JOUEURS]\n{players}\n\n" +
                $"[LOBBY + EVENEMENT]\n{lobby}\n\n" +
                $"[DUEL]\n{duel ?? "indisponible"}\n\n" +
                $"[ZOMBIE]\n{zombie ?? "indisponible"}\n\n" +
                $"[GUN GAME]\n{gunGame ?? "indisponible"}\n\n" +
                $"[TOWER DEFENSE]\n{towerDefense ?? "indisponible"}\n\n" +
                $"[ENTRAINEMENT]\n{training ?? "indisponible"}\n\n" +
                $"[RECOMPENSES]\n{rewards ?? "indisponible"}");
        }

        private string BuildDashboardJson(string lobby, object duel, object zombie, object gunGame, object towerDefense, object training, object rewards)
        {
            StringBuilder json = new StringBuilder();
            json.Append("{\"players\":[");
            bool firstPlayer = true;
            foreach (BasePlayer player in BasePlayer.activePlayerList)
            {
                if (!firstPlayer) json.Append(',');
                firstPlayer = false;
                json.Append("{\"name\":\"").Append(JsonEscape(player.displayName))
                    .Append("\",\"steamId\":\"").Append(JsonEscape(player.UserIDString)).Append("\"}");
            }

            json.Append("],\"modes\":[");
            bool firstMode = true;
            AppendMode(json, ref firstMode, "Lobby & evenement", lobby);
            AppendMode(json, ref firstMode, "Duel", duel);
            AppendMode(json, ref firstMode, "Zombie", zombie);
            AppendMode(json, ref firstMode, "Gun Game", gunGame);
            AppendMode(json, ref firstMode, "Tower Defense", towerDefense);
            AppendMode(json, ref firstMode, "Entrainement", training);

            json.Append("],\"rewards\":{");
            bool firstReward = true;
            foreach (Match match in Regex.Matches(rewards == null ? string.Empty : rewards.ToString(), @"(\w+)=(-?\d+)"))
            {
                if (!firstReward) json.Append(',');
                firstReward = false;
                json.Append('"').Append(JsonEscape(match.Groups[1].Value)).Append("\":").Append(match.Groups[2].Value);
            }
            json.Append("}}");
            return json.ToString();
        }

        private void AppendMode(StringBuilder json, ref bool first, string name, object status)
        {
            if (!first) json.Append(',');
            first = false;
            string text = status == null ? string.Empty : status.ToString();
            json.Append("{\"name\":\"").Append(JsonEscape(name))
                .Append("\",\"available\":").Append(status == null ? "false" : "true")
                .Append(",\"running\":").Append(StatusIsRunning(text) ? "true" : "false")
                .Append(",\"status\":\"").Append(JsonEscape(text)).Append("\"}");
        }

        /// <summary>
        /// Chaque plugin nomme differemment son drapeau d'activite. On les couvre
        /// tous plutot que d'imposer un renommage qui casserait les sorties texte
        /// deja utilisees ailleurs.
        /// </summary>
        private bool StatusIsRunning(string status)
        {
            if (string.IsNullOrEmpty(status)) return false;
            return Regex.IsMatch(status, @"\b(actif|active|match|arene)=True\b", RegexOptions.IgnoreCase);
        }

        private string JsonEscape(string value)
        {
            if (string.IsNullOrEmpty(value)) return string.Empty;
            StringBuilder escaped = new StringBuilder(value.Length + 8);
            foreach (char character in value)
            {
                switch (character)
                {
                    case '"': escaped.Append("\\\""); break;
                    case '\\': escaped.Append("\\\\"); break;
                    case '\n': escaped.Append("\\n"); break;
                    case '\r': escaped.Append("\\r"); break;
                    case '\t': escaped.Append("\\t"); break;
                    default:
                        if (character < ' ') escaped.Append("\\u").Append(((int)character).ToString("x4"));
                        else escaped.Append(character);
                        break;
                }
            }
            return escaped.ToString();
        }

        private void ToggleModeQueue(BasePlayer player, string mode)
        {
            if (_participants.Contains(player.userID)) { SendReply(player, "Tu participes deja a un mode. /mode leave pour quitter."); return; }
            if (_queues[mode].Contains(player.userID))
            {
                _queues[mode].Remove(player.userID);
                SendReply(player, $"File {ModeLabel(mode)} quittee.");
                return;
            }
            if (IsOtherGameParticipant(player)) { SendReply(player, "Quitte d'abord Gun Game, Zombie ou Duel."); return; }
            RemoveFromAllQueues(player.userID);
            if (_lobbyPlayers.Contains(player.userID)) LeaveLobby(player, true);
            _queues[mode].Add(player.userID);
            BroadcastQueue(mode, $"{player.displayName} rejoint {ModeLabel(mode)} ({_queues[mode].Count}/{MinimumPlayers(mode)} minimum).");
            TryScheduleMode(mode);
        }

        private void TryScheduleMode(string preferred)
        {
            if (_matchActive || !string.IsNullOrEmpty(_scheduledMode)) return;
            string mode = _queues[preferred].Count >= MinimumPlayers(preferred) ? preferred : _modeOrder.FirstOrDefault(candidate => _queues[candidate].Count >= MinimumPlayers(candidate));
            if (string.IsNullOrEmpty(mode)) return;
            _scheduledMode = mode;
            BroadcastQueue(mode, $"{ModeLabel(mode)} demarre dans 5 secondes. Jusqu'a 8 joueurs peuvent rejoindre.");
            timer.Once(5f, () =>
            {
                string scheduled = _scheduledMode;
                _scheduledMode = string.Empty;
                if (!_matchActive && !string.IsNullOrEmpty(scheduled)) StartMode(scheduled, false);
            });
        }

        private void StartMode(string mode, bool forced)
        {
            if (_matchActive) return;
            _queues[mode].RemoveAll(userId => FindPlayer(userId) == null);
            int minimum = MinimumPlayers(mode);
            if (_queues[mode].Count < minimum)
            {
                if (forced) BroadcastGlobal($"Impossible de lancer {ModeLabel(mode)} : {minimum} joueur(s) minimum dans la file.");
                return;
            }
            List<ulong> selected = _queues[mode].Take(8).OrderBy(value => UnityEngine.Random.value).ToList();
            foreach (ulong selectedUserId in selected) _queues[mode].Remove(selectedUserId);
            _activeMode = mode;
            _matchActive = true;
            _roundActive = mode != "snd";
            _sessionId++;
            _scoreRed = 0;
            _scoreBlue = 0;
            _sndRound = 0;
            _bombPlanted = false;
            _participants.Clear();
            _alive.Clear();
            _teams.Clear();
            _returnPositions.Clear();
            _flagCarriers.Clear();
            _extractionLoot.Clear();
            _redFlagAvailable = true;
            _blueFlagAvailable = true;
            for (int index = 0; index < _extractionAvailable.Length; index++) _extractionAvailable[index] = true;
            for (int selectedIndex = 0; selectedIndex < selected.Count; selectedIndex++)
            {
                ulong userId = selected[selectedIndex];
                BasePlayer player = FindPlayer(userId);
                if (player == null) continue;
                _participants.Add(userId);
                _alive.Add(userId);
                _teams[userId] = mode == "extraction" ? selectedIndex + 1 : selectedIndex % 2 + 1;
                _returnPositions[userId] = player.transform.position;
                _extractionLoot[userId] = 0;
            }
            BuildArena();
            if (mode == "snd")
            {
                BroadcastMode("Search & Destroy : premiere manche dans 5 secondes. Attaquants ROUGE, defenseurs BLEUS.");
                int session = _sessionId;
                timer.Once(5f, () => { if (_matchActive && session == _sessionId) StartSndRound(); });
            }
            else
            {
                foreach (BasePlayer player in ModePlayers()) PreparePlayer(player);
                BroadcastMode(ModeStartInstructions(mode));
            }
            int activeSession = _sessionId;
            timer.Once(900f, () => { if (_matchActive && activeSession == _sessionId) FinishTimedMode(); });
        }

        private void StartSndRound()
        {
            if (!_matchActive || _activeMode != "snd") return;
            _sndRound++;
            _roundActive = true;
            _bombPlanted = false;
            _alive.Clear();
            foreach (BasePlayer player in ModePlayers())
            {
                _alive.Add(player.userID);
                PreparePlayer(player);
            }
            BroadcastMode($"S&D manche {_sndRound} - score ROUGE {_scoreRed} / {_scoreBlue} BLEUE. ROUGE : /plant au centre. BLEUE : /defuse.");
            int session = _sessionId;
            int round = _sndRound;
            timer.Once(120f, () => { if (_matchActive && _roundActive && session == _sessionId && round == _sndRound) EndSndRound(2, "Temps ecoule : defense reussie."); });
        }

        private void EvaluateSndRound()
        {
            if (!_matchActive || !_roundActive || _activeMode != "snd") return;
            int redAlive = _alive.Count(userId => TeamOf(userId) == 1 && FindPlayer(userId) != null);
            int blueAlive = _alive.Count(userId => TeamOf(userId) == 2 && FindPlayer(userId) != null);
            if (blueAlive == 0) EndSndRound(1, "Defenseurs elimines.");
            else if (redAlive == 0 && !_bombPlanted) EndSndRound(2, "Attaquants elimines avant la pose.");
        }

        private void EndSndRound(int winner, string message)
        {
            if (!_matchActive || !_roundActive || _activeMode != "snd") return;
            _roundActive = false;
            _bombPlanted = false;
            if (winner == 1) _scoreRed++; else _scoreBlue++;
            BroadcastMode($"{message} Score S&D : ROUGE {_scoreRed} / {_scoreBlue} BLEUE.");
            if (_scoreRed >= 3 || _scoreBlue >= 3)
            {
                FinishMode(_scoreRed > _scoreBlue ? 1 : 2, null, "Match Search & Destroy termine.");
                return;
            }
            int session = _sessionId;
            timer.Once(6f, () => { if (_matchActive && session == _sessionId) StartSndRound(); });
        }

        private void Tick()
        {
            TickSkyLobby();
            TickLobbyPortals();
            TickMenus();
            if (!_matchActive || !_roundActive) return;
            if (_activeMode == "ctf") TickCtf();
            else if (_activeMode == "domination") TickDomination();
            else if (_activeMode == "snd" && _bombPlanted && Time.realtimeSinceStartup - _bombPlantedAt >= 45f) EndSndRound(1, "La charge explose.");
            else if (_activeMode == "extraction") TickExtraction();
        }

        private void TickCtf()
        {
            foreach (BasePlayer player in ModePlayers())
            {
                if (!_alive.Contains(player.userID)) continue;
                int team = TeamOf(player.userID);
                if (!_flagCarriers.ContainsKey(player.userID))
                {
                    if (team == 1 && _blueFlagAvailable && HorizontalDistance(player.transform.position, GetTeamBase(2)) <= 4f)
                    {
                        _blueFlagAvailable = false;
                        _flagCarriers[player.userID] = 2;
                        BroadcastMode($"{player.displayName} prend le drapeau BLEU !");
                    }
                    else if (team == 2 && _redFlagAvailable && HorizontalDistance(player.transform.position, GetTeamBase(1)) <= 4f)
                    {
                        _redFlagAvailable = false;
                        _flagCarriers[player.userID] = 1;
                        BroadcastMode($"{player.displayName} prend le drapeau ROUGE !");
                    }
                }
                int carried;
                if (_flagCarriers.TryGetValue(player.userID, out carried) && HorizontalDistance(player.transform.position, GetTeamBase(team)) <= 4f && (team == 1 ? _redFlagAvailable : _blueFlagAvailable))
                {
                    _flagCarriers.Remove(player.userID);
                    if (carried == 1) _redFlagAvailable = true; else _blueFlagAvailable = true;
                    if (team == 1) _scoreRed++; else _scoreBlue++;
                    BroadcastMode($"<color=#ffd479>{player.displayName} capture un drapeau !</color> Score ROUGE {_scoreRed} / {_scoreBlue} BLEUE.");
                    if (_scoreRed >= 3 || _scoreBlue >= 3) FinishMode(_scoreRed > _scoreBlue ? 1 : 2, null, "Capture du drapeau terminee.");
                }
            }
        }

        private void TickDomination()
        {
            int red = 0;
            int blue = 0;
            foreach (BasePlayer player in ModePlayers())
            {
                if (!_alive.Contains(player.userID) || HorizontalDistance(player.transform.position, _arenaCenter) > 9f) continue;
                if (TeamOf(player.userID) == 1) red++; else blue++;
            }
            if (red > 0 && blue == 0) _scoreRed += Math.Min(3, red);
            if (blue > 0 && red == 0) _scoreBlue += Math.Min(3, blue);
            if (_scoreRed >= 100 || _scoreBlue >= 100) FinishMode(_scoreRed > _scoreBlue ? 1 : 2, null, $"Domination terminee : {_scoreRed}-{_scoreBlue}.");
        }

        private void TickExtraction()
        {
            foreach (BasePlayer player in ModePlayers())
            {
                if (!_alive.Contains(player.userID)) continue;
                for (int index = 0; index < _extractionAvailable.Length; index++)
                {
                    if (!_extractionAvailable[index] || HorizontalDistance(player.transform.position, GetExtractionPoint(index)) > 3.5f) continue;
                    _extractionAvailable[index] = false;
                    _extractionLoot[player.userID] = _extractionLoot[player.userID] + 1;
                    SendReply(player, $"Butin recupere : {_extractionLoot[player.userID]}/3. Reviens au centre pour extraire.");
                }
                if (_extractionLoot[player.userID] >= 3 && HorizontalDistance(player.transform.position, _arenaCenter) <= 5f)
                {
                    FinishMode(0, player, $"{player.displayName} reussit l'extraction avec son butin !");
                    return;
                }
            }
        }

        private void FinishTimedMode()
        {
            if (_activeMode == "extraction")
            {
                BasePlayer best = ModePlayers().OrderByDescending(player => _extractionLoot.ContainsKey(player.userID) ? _extractionLoot[player.userID] : 0).FirstOrDefault();
                FinishMode(0, best, "Temps ecoule : meilleur butin extrait.");
            }
            else FinishMode(_scoreRed == _scoreBlue ? 0 : _scoreRed > _scoreBlue ? 1 : 2, null, "Temps limite atteint.");
        }

        private void FinishMode(int winningTeam, BasePlayer winnerFfa, string message)
        {
            if (!_matchActive) return;
            _roundActive = false;
            _sessionId++;
            BroadcastMode(message);
            foreach (BasePlayer player in ModePlayers().ToArray())
            {
                bool winner = winnerFfa != null ? player == winnerFfa : winningTeam != 0 && TeamOf(player.userID) == winningTeam;
                if (winner)
                {
                    Interface.CallHook("OnCompetitiveModeCompleted", player, _activeMode);
                    SendReply(player, "<color=#ffd479>Victoire !</color> Recompense de progression ajoutee.");
                }
                RemoveModeItems(player);
                ReturnParticipant(player);
            }
            _participants.Clear();
            _alive.Clear();
            _teams.Clear();
            _returnPositions.Clear();
            _flagCarriers.Clear();
            _extractionLoot.Clear();
            _scoreRed = 0;
            _scoreBlue = 0;
            _sndRound = 0;
            _bombPlanted = false;
            _matchActive = false;
            _activeMode = string.Empty;
            RemoveArena();
            timer.Once(2f, TryStartAnyQueuedMode);
        }

        private void LeaveMode(BasePlayer player)
        {
            bool removedQueue = RemoveFromAllQueues(player.userID);
            if (removedQueue) { SendReply(player, "Tu as quitte la file competitive."); return; }
            if (!_participants.Contains(player.userID)) { SendReply(player, "Tu ne participes a aucun mode competitif."); return; }
            int leavingTeam = TeamOf(player.userID);
            _participants.Remove(player.userID);
            _alive.Remove(player.userID);
            RemoveModeItems(player);
            ReturnParticipant(player);
            _returnPositions.Remove(player.userID);
            _teams.Remove(player.userID);
            if (_participants.Count == 0) FinishMode(0, null, "Mode termine : tous les joueurs sont partis.");
            else if (_activeMode != "extraction" && !_teams.Values.Contains(leavingTeam)) FinishMode(leavingTeam == 1 ? 2 : 1, null, "Victoire par forfait.");
        }

        private void PreparePlayer(BasePlayer player)
        {
            if (player == null || !player.IsConnected) return;
            Vector3 spawn = GetModeSpawn(player.userID);
            if (player.IsDead()) player.RespawnAt(spawn, Quaternion.identity); else player.Teleport(spawn);
            player.InitializeHealth(100f, 100f);
            BasePlayer captured = player;
            timer.Once(0.25f, () => { if (captured != null && captured.IsConnected && _participants.Contains(captured.userID)) GiveModeKit(captured); });
        }

        private void RespawnParticipant(BasePlayer player)
        {
            if (player == null || !player.IsConnected || !_participants.Contains(player.userID)) return;
            if (player.IsDead()) player.RespawnAt(GetModeSpawn(player.userID), Quaternion.identity);
        }

        private void GiveModeKit(BasePlayer player)
        {
            RemoveModeItems(player);
            GiveModeItem(player, "rifle.semiauto", 1, "Fusil semi-automatique");
            GiveModeItem(player, "ammo.rifle", 160, "Munitions illimitees");
            GiveModeItem(player, "syringe.medical", 3, "Soins");
            timer.Once(0.15f, () => FillModeMagazine(player));
        }

        private void GiveModeItem(BasePlayer player, string shortname, int amount, string label)
        {
            Item item = ItemManager.CreateByName(shortname, amount);
            if (item == null) return;
            item.name = ModeItemPrefix + label;
            if (item.hasCondition) item.condition = item.maxCondition;
            ApplySharedSkin(player, item, shortname);
            player.GiveItem(item);
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


        private void FillModeMagazine(BasePlayer player)
        {
            if (player == null) return;
            foreach (Item item in PlayerItems(player))
            {
                if (item == null || string.IsNullOrEmpty(item.name) || !item.name.StartsWith(ModeItemPrefix, StringComparison.Ordinal)) continue;
                BaseProjectile projectile = item.GetHeldEntity() as BaseProjectile;
                if (projectile == null || projectile.primaryMagazine == null) continue;
                projectile.primaryMagazine.contents = projectile.primaryMagazine.capacity;
                projectile.SendNetworkUpdateImmediate();
                item.MarkDirty();
            }
        }

        private bool IsUsingModeWeapon(BasePlayer player)
        {
            Item item = player != null ? player.GetActiveItem() : null;
            return item != null && !string.IsNullOrEmpty(item.name) && item.name.StartsWith(ModeItemPrefix, StringComparison.Ordinal);
        }

        private void RemoveModeItems(BasePlayer player)
        {
            foreach (Item item in PlayerItems(player).ToArray())
            {
                if (item != null && !string.IsNullOrEmpty(item.name) && item.name.StartsWith(ModeItemPrefix, StringComparison.Ordinal)) item.Remove();
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

        // ----- Lobby du ciel ------------------------------------------------------
        //
        // Le lobby est construit a partir d'un plan (data/RustGameHub_Lobby.json) :
        // une grille de caracteres, une case = une fondation de 3 m.
        //   .  vide          #  sol          S  sol + point d'apparition
        //   1 a 9  sol + portail, relie a un mode dans la liste "Portails"
        // L'editeur du Control Center ecrit ce meme format : ce qui y est dessine
        // se construit ici sans toucher au code.

        private const string LayoutFile = "RustGameHub_Lobby";
        private const string FoundationPrefab = "assets/prefabs/building core/foundation/foundation.prefab";
        private const string LowWallPrefab = "assets/prefabs/building core/wall.low/wall.low.prefab";
        private const float CellSize = 3f;
        private const int MaxGridSize = 40;

        private class LobbyLayout
        {
            public string Nom = "Lobby du ciel";
            public bool MiniJeux = true;
            public float Altitude = 300f;
            public string Grade = "metal";
            public bool GardeCorps = true;
            public bool JourPermanent = true;
            public List<string> Grille = new List<string>();
            public List<LobbyPortal> Portails = new List<LobbyPortal>();
            // Lobby construit en jeu : si Objets n'est pas vide, il remplace la grille.
            public List<LobbyObject> Objets = new List<LobbyObject>();
            public List<LobbyPoint> Apparitions = new List<LobbyPoint>();
            public List<LobbyFreePortal> PortailsLibres = new List<LobbyFreePortal>();
        }

        private class LobbyPortal
        {
            public int Emplacement;
            public string Mode = "";
            public string Nom = "";
        }

        private LobbyLayout _layout;
        private readonly HashSet<BaseEntity> _lobbyProtected = new HashSet<BaseEntity>();
        private readonly HashSet<ulong> _lobbyExempt = new HashSet<ulong>();
        private readonly List<Vector3> _lobbySpawns = new List<Vector3>();
        private readonly Dictionary<string, Vector3> _portalPositions = new Dictionary<string, Vector3>();
        private float _lobbyFloorY;
        private float _lobbyRadius = 20f;
        private int _nextLobbySpawn;
        private bool _dayLocked;
        private Timer _lobbyRebuildTimer;

        private LobbyLayout DefaultLayout()
        {
            LobbyLayout layout = new LobbyLayout();
            layout.Grille = new List<string>
            {
                "....#####....",
                "...###9###...",
                "..##1###2##..",
                ".###########.",
                "##8#######3##",
                "#############",
                "######S######",
                "#############",
                "##7#######4##",
                ".###########.",
                "..##6###5##..",
                "...#######...",
                "....#####...."
            };
            string[][] slots =
            {
                new[] { "1", "duel", "DUEL" },
                new[] { "2", "gungame", "GUN GAME" },
                new[] { "3", "ctf", "CTF" },
                new[] { "4", "domination", "DOMINATION" },
                new[] { "5", "snd", "SEARCH & DESTROY" },
                new[] { "6", "extraction", "EXTRACTION" },
                new[] { "7", "zombie", "ZOMBIE" },
                new[] { "8", "towerdefense", "TOWER DEFENSE" },
                new[] { "9", "training", "ENTRAINEMENT" }
            };
            foreach (string[] slot in slots)
            {
                layout.Portails.Add(new LobbyPortal { Emplacement = int.Parse(slot[0]), Mode = slot[1], Nom = slot[2] });
            }
            return layout;
        }

        private void LoadLayout()
        {
            LobbyLayout loaded = null;
            bool exists = Interface.Oxide.DataFileSystem.ExistsDatafile(LayoutFile);
            try
            {
                if (exists) loaded = Interface.Oxide.DataFileSystem.ReadObject<LobbyLayout>(LayoutFile);
            }
            catch (Exception exception)
            {
                PrintWarning("Plan du lobby illisible, plan par defaut utilise : " + exception.Message);
            }

            bool noGrid = loaded == null || loaded.Grille == null || loaded.Grille.Count == 0;
            bool noObjects = loaded == null || loaded.Objets == null || loaded.Objets.Count == 0;
            if (noGrid && noObjects)
            {
                loaded = DefaultLayout();
                // On n'ecrit le plan par defaut que s'il n'existe aucun fichier :
                // un plan mal forme reste sur le disque pour etre corrige, au lieu
                // d'etre ecrase par le defaut.
                if (!exists) Interface.Oxide.DataFileSystem.WriteObject(LayoutFile, loaded);
            }
            if (loaded.Grille == null) loaded.Grille = new List<string>();
            if (loaded.Portails == null) loaded.Portails = new List<LobbyPortal>();
            if (loaded.Objets == null) loaded.Objets = new List<LobbyObject>();
            if (loaded.Apparitions == null) loaded.Apparitions = new List<LobbyPoint>();
            if (loaded.PortailsLibres == null) loaded.PortailsLibres = new List<LobbyFreePortal>();
            _layout = loaded;
        }

        private BuildingGrade.Enum ParseGrade(string value)
        {
            switch ((value ?? "").ToLowerInvariant())
            {
                case "paille": case "twig": case "twigs": return BuildingGrade.Enum.Twigs;
                case "bois": case "wood": return BuildingGrade.Enum.Wood;
                case "pierre": case "stone": return BuildingGrade.Enum.Stone;
                case "blinde": case "hq": case "toptier": return BuildingGrade.Enum.TopTier;
                default: return BuildingGrade.Enum.Metal;
            }
        }

        private static bool IsFloorCell(char cell)
        {
            return cell == '#' || cell == 'S' || (cell >= '1' && cell <= '9');
        }

        private static bool IsFloorAt(List<string> grid, int row, int col)
        {
            return row >= 0 && row < grid.Count && col >= 0 && col < grid[row].Length && IsFloorCell(grid[row][col]);
        }

        private Vector3 CellPosition(int row, int col, int rows, int cols)
        {
            // Ligne 0 au nord (+z) : la grille se lit comme une carte.
            return _lobbyCenter + new Vector3((col - (cols - 1) * 0.5f) * CellSize, 0f, ((rows - 1) * 0.5f - row) * CellSize);
        }

        private bool IsModeAvailable(string key)
        {
            switch (key)
            {
                case "duel": return plugins.Find("RustDuel") != null;
                case "gungame": return plugins.Find("RustGunGame") != null;
                case "zombie": return plugins.Find("RustRPG") != null;
                case "towerdefense": return plugins.Find("RustTowerDefense") != null;
                case "training": return plugins.Find("RustTraining") != null;
                case "battlefield": return plugins.Find("RustBattlefield") != null;
                default: return true; // modes internes au hub
            }
        }

        private void BuildLobby()
        {
            RemoveLobby();
            LoadLayout();
            if (HasLobbyObjects())
            {
                BuildLobbyFromObjects();
                return;
            }

            List<string> grid = _layout.Grille
                .Take(MaxGridSize)
                .Select(row => row == null ? "" : (row.Length > MaxGridSize ? row.Substring(0, MaxGridSize) : row))
                .ToList();
            int rows = grid.Count;
            int cols = rows == 0 ? 0 : grid.Max(row => row.Length);
            if (rows == 0 || cols == 0)
            {
                PrintWarning("Plan du lobby vide : rien a construire.");
                return;
            }

            // Toujours au-dessus du relief : une altitude trop basse traverserait
            // une colline au centre de la carte.
            float ground = TerrainMeta.HeightMap.GetHeight(Vector3.zero);
            float altitude = Mathf.Max(_layout.Altitude, ground + 60f);
            _lobbyCenter = new Vector3(0f, altitude, 0f);
            _lobbyRadius = 0.5f * Mathf.Sqrt(rows * rows + cols * cols) * CellSize;
            _lobbyFloorY = altitude;

            BuildingGrade.Enum grade = ParseGrade(_layout.Grade);
            bool floorMeasured = false;
            Dictionary<int, Vector3> slotPositions = new Dictionary<int, Vector3>();

            for (int row = 0; row < rows; row++)
            {
                for (int col = 0; col < grid[row].Length; col++)
                {
                    char cell = grid[row][col];
                    if (!IsFloorCell(cell)) continue;
                    Vector3 position = CellPosition(row, col, rows, cols);
                    BuildingBlock block = SpawnBlock(FoundationPrefab, position, Quaternion.identity, grade);
                    if (block != null && !floorMeasured)
                    {
                        // La hauteur de marche se mesure sur un vrai bloc : on ne
                        // suppose pas ou se trouve le pivot d'une fondation.
                        floorMeasured = true;
                        try { _lobbyFloorY = block.WorldSpaceBounds().ToBounds().max.y; } catch { }
                    }
                    if (cell == 'S') _lobbySpawns.Add(position);
                    else if (cell >= '1' && cell <= '9') slotPositions[cell - '0'] = position;
                }
            }

            if (_layout.GardeCorps)
            {
                Vector3[] directions = { Vector3.forward, Vector3.back, Vector3.right, Vector3.left };
                int[] rowStep = { -1, 1, 0, 0 };
                int[] colStep = { 0, 0, 1, -1 };
                for (int row = 0; row < rows; row++)
                {
                    for (int col = 0; col < grid[row].Length; col++)
                    {
                        if (!IsFloorCell(grid[row][col])) continue;
                        for (int side = 0; side < 4; side++)
                        {
                            if (IsFloorAt(grid, row + rowStep[side], col + colStep[side])) continue;
                            Vector3 edge = CellPosition(row, col, rows, cols) + directions[side] * (CellSize * 0.5f);
                            // Le prefab de mur s'etend sur son axe Z local : on
                            // aligne Z sur le bord, pas sur sa normale. Mesure faite :
                            // avec LookRotation(normale), le mur sortait a 90 degres.
                            SpawnBlock(LowWallPrefab, edge, Quaternion.LookRotation(Vector3.Cross(Vector3.up, directions[side])), grade);
                        }
                    }
                }
            }

            Dictionary<string, string> labels = new Dictionary<string, string>();
            foreach (PortalDefinition definition in Portals()) labels[definition.Key] = definition.Label;

            foreach (LobbyPortal portal in _layout.Portails)
            {
                Vector3 position;
                if (portal == null || !slotPositions.TryGetValue(portal.Emplacement, out position)) continue;
                string key = (portal.Mode ?? "").ToLowerInvariant();
                if (!labels.ContainsKey(key))
                {
                    PrintWarning("Plan du lobby : mode inconnu \"" + portal.Mode + "\" sur l'emplacement " + portal.Emplacement + ".");
                    continue;
                }
                Vector3 floor = new Vector3(position.x, _lobbyFloorY, position.z);
                string label = string.IsNullOrEmpty(portal.Nom) ? labels[key] : portal.Nom;
                // Memorise meme pour un mode coupe : une sauvegarde en jeu ne doit
                // pas perdre son portail.
                _allPortalPoints[key] = floor;
                _allPortalNames[key] = label;
                // Pas de portail mort : un mode dont le plugin est absent n'en a pas.
                if (!IsModeAvailable(key)) continue;
                SpawnPortal(key, label, floor);
            }

            if (_lobbySpawns.Count == 0) _lobbySpawns.Add(_lobbyCenter);
            _lobbyBottomY = _lobbyFloorY - 6f;
            _lobbyTopY = _lobbyFloorY + 25f;
            ApplyDayLock();
            Puts($"Lobby \"{_layout.Nom}\" construit a {altitude:F0} m : {_lobbyEntities.Count} elements, {_portalPositions.Count} portail(s), sol a {_lobbyFloorY:F2}.");
        }

        private BuildingBlock SpawnBlock(string prefab, Vector3 position, Quaternion rotation, BuildingGrade.Enum grade)
        {
            BaseEntity entity = GameManager.server.CreateEntity(prefab, position, rotation, true);
            BuildingBlock block = entity as BuildingBlock;
            if (block == null)
            {
                if (entity != null) entity.Kill();
                return null;
            }
            block.enableSaving = false;
            // Sans "grounded", la stabilite fait s'effondrer un bloc sans appui :
            // une plateforme a 300 m tomberait en morceaux a l'apparition.
            block.grounded = true;
            // Avant Spawn(), la definition du bloc n'est pas encore chargee :
            // SetGrade levait une NullReferenceException. On la fournit nous-memes.
            block.blockDefinition = PrefabAttribute.server.Find<Construction>(block.prefabID);
            block.SetGrade(grade);
            block.Spawn();
            block.SetHealthToMax();
            block.SendNetworkUpdate();
            _lobbyEntities.Add(block);
            _lobbyProtected.Add(block);
            return block;
        }

        private BaseEntity SpawnProtected(string prefab, Vector3 position, Quaternion rotation)
        {
            BaseEntity entity = GameManager.server.CreateEntity(prefab, position, rotation, true);
            if (entity == null) return null;
            entity.enableSaving = false;
            entity.Spawn();
            _lobbyEntities.Add(entity);
            _lobbyProtected.Add(entity);
            return entity;
        }

        private void SpawnSkyGuide(string label, Vector3 position, Quaternion rotation)
        {
            BaseEntity entity = GameManager.server.CreateEntity(GuidePrefab, position, rotation, true);
            BasePlayer guide = entity as BasePlayer;
            if (guide == null) { if (entity != null) entity.Kill(); return; }
            guide.enableSaving = false;
            guide.displayName = "PORTAIL " + label;
            guide.Spawn();
            guide.InitializeHealth(500f, 500f);
            _lobbyGuides.Add(guide);
        }

        private void ApplyDayLock()
        {
            if (_layout == null) return;
            if (_layout.JourPermanent)
            {
                // Une plateforme dans le ciel est illisible de nuit : les serveurs
                // mini-jeux figent l'heure en plein jour.
                ConsoleSystem.Run(ConsoleSystem.Option.Server.Quiet(), "env.time", 12f);
                ConsoleSystem.Run(ConsoleSystem.Option.Server.Quiet(), "env.progresstime", false);
                _dayLocked = true;
            }
            else if (_dayLocked)
            {
                ConsoleSystem.Run(ConsoleSystem.Option.Server.Quiet(), "env.progresstime", true);
                _dayLocked = false;
            }
        }

        private bool IsInLobbyZone(Vector3 position)
        {
            if (_lobbyEntities.Count == 0) return false;
            return position.y > _lobbyBottomY && position.y < _lobbyTopY &&
                   HorizontalDistance(position, _lobbyCenter) <= _lobbyRadius + 4f;
        }

        private bool IsUnderLobby(Vector3 position)
        {
            return _lobbyEntities.Count > 0 && position.y < _lobbyBottomY - 14f &&
                   HorizontalDistance(position, _lobbyCenter) <= _lobbyRadius + 30f;
        }

        private bool IsMiniGameServer()
        {
            return _layout != null && _layout.MiniJeux;
        }

        private bool IsPlayingSomewhere(BasePlayer player)
        {
            // En partie, hors files d'attente : un joueur en file attend au lobby.
            return player != null && (IsOtherGameParticipant(player) || _participants.Contains(player.userID));
        }

        private Vector3 NextLobbySpawn()
        {
            Vector3 point = _lobbySpawns.Count == 0 ? _lobbyCenter : _lobbySpawns[_nextLobbySpawn++ % _lobbySpawns.Count];
            // Petite dispersion : plusieurs joueurs au meme point s'empileraient.
            return new Vector3(point.x + UnityEngine.Random.Range(-1f, 1f), point.y + 0.3f, point.z + UnityEngine.Random.Range(-1f, 1f));
        }

        private void SendToLobby(BasePlayer player)
        {
            if (player == null || !player.IsConnected || player.IsDead()) return;
            if (_lobbyEntities.Count == 0) BuildLobby();
            if (_lobbyEntities.Count == 0) return;
            player.EnsureDismounted();
            _lobbyPlayers.Add(player.userID);
            // Delai de grace : on n'arrive jamais pile sur un portail actif.
            _portalCooldowns[player.userID] = Time.realtimeSinceStartup + 3f;
            player.Teleport(NextLobbySpawn());
        }

        private void TickSkyLobby()
        {
            if (_layout == null || _lobbyEntities.Count == 0) return;
            foreach (BasePlayer player in BasePlayer.activePlayerList.ToArray())
            {
                if (player == null || !player.IsConnected || player.IsDead() || player.IsSleeping()) continue;
                Vector3 position = player.transform.position;
                if (_lobbyExempt.Contains(player.userID))
                {
                    // Un editeur garde le filet de chute ; un admin sorti du lobby, non.
                    if (_lobbyEditors.Contains(player.userID) && IsUnderLobby(position)) player.Teleport(NextLobbySpawn());
                    continue;
                }
                bool playing = IsPlayingSomewhere(player);

                // Filet sous la plateforme : une chute ramene au spawn, sans degat.
                if (!playing && IsUnderLobby(position) && (IsMiniGameServer() || _lobbyPlayers.Contains(player.userID)))
                {
                    player.Teleport(NextLobbySpawn());
                    continue;
                }
                if (!IsMiniGameServer()) continue;

                bool inZone = IsInLobbyZone(position);
                if (inZone && !playing) _lobbyPlayers.Add(player.userID);
                else _lobbyPlayers.Remove(player.userID);

                // Serveur mini-jeux : quiconque n'est ni en partie ni au lobby y
                // retourne. Couvre connexion, fin de mode, sortie de zone.
                if (!inZone && !playing && !IsInAnyGame(player)) SendToLobby(player);
            }
        }

        private void TickLobbyPortals()
        {
            if (_lobbyPlayers.Count == 0 || _portalPositions.Count == 0) return;
            foreach (ulong userId in _lobbyPlayers.ToArray())
            {
                BasePlayer player = FindPlayer(userId);
                if (player == null) { _lobbyPlayers.Remove(userId); continue; }
                float readyAt;
                if (_portalCooldowns.TryGetValue(userId, out readyAt) && Time.realtimeSinceStartup < readyAt) continue;
                Vector3 position = player.transform.position;
                foreach (KeyValuePair<string, Vector3> portal in _portalPositions)
                {
                    if (HorizontalDistance(position, portal.Value) > 1.6f) continue;
                    if (Mathf.Abs(position.y - portal.Value.y) > 3f) continue;
                    _portalCooldowns[userId] = Time.realtimeSinceStartup + 5f;
                    ActivatePortal(player, portal.Key);
                    break;
                }
            }
        }

        private void ScheduleLobbyRebuild(Plugin plugin)
        {
            if (plugin == null || _lobbyEntities.Count == 0) return;
            string name = plugin.Name;
            if (name != "RustDuel" && name != "RustGunGame" && name != "RustRPG" && name != "RustTowerDefense" && name != "RustTraining" && name != "RustBattlefield") return;
            // Un mode active ou coupe : ses portails apparaissent ou disparaissent.
            if (_lobbyRebuildTimer != null) _lobbyRebuildTimer.Destroy();
            _lobbyRebuildTimer = timer.Once(3f, RebuildLobbyAndRecall);
        }

        private void OnPluginLoaded(Plugin plugin) { ScheduleLobbyRebuild(plugin); }
        private void OnPluginUnloaded(Plugin plugin) { ScheduleLobbyRebuild(plugin); }

        private void RebuildLobbyAndRecall()
        {
            BuildLobby();
            // La reconstruction retire les blocs sous les pieds : on repose les
            // joueurs presents avant qu'ils ne tombent.
            foreach (ulong userId in _lobbyPlayers.ToArray())
            {
                BasePlayer player = FindPlayer(userId);
                if (player != null && player.IsConnected && !player.IsDead()) player.Teleport(NextLobbySpawn());
            }
        }

        private object CanBuild(Planner planner, Construction prefab, Construction.Target target)
        {
            BasePlayer player = planner != null ? planner.GetOwnerPlayer() : null;
            if (player == null || _lobbyExempt.Contains(player.userID)) return null;
            Vector3 position = target.entity != null ? target.entity.transform.position : target.position;
            if (!IsInLobbyZone(position) && !IsInLobbyZone(player.transform.position)) return null;
            SendReply(player, "Construction interdite dans le lobby.");
            return false;
        }

        private object OnStructureUpgrade(BaseCombatEntity entity, BasePlayer player, BuildingGrade.Enum grade)
        {
            return entity != null && _lobbyProtected.Contains(entity) && !IsLobbyEditor(player) ? (object)false : null;
        }

        private object OnStructureDemolish(BaseCombatEntity entity, BasePlayer player, bool immediate)
        {
            return entity != null && _lobbyProtected.Contains(entity) && !IsLobbyEditor(player) ? (object)false : null;
        }

        private object OnStructureRotate(BaseCombatEntity entity, BasePlayer player)
        {
            return entity != null && _lobbyProtected.Contains(entity) && !IsLobbyEditor(player) ? (object)false : null;
        }

        private object CanPickupEntity(BasePlayer player, BaseEntity entity)
        {
            return entity != null && _lobbyProtected.Contains(entity) && !IsLobbyEditor(player) ? (object)false : null;
        }

        // ----- Lobby construit en jeu (3D) -----------------------------------------
        //
        // L'editeur 3D, c'est Rust : un admin en /lobby edit construit librement
        // et gratuitement autour du lobby, puis /lobby save enregistre chaque
        // objet (prefab, position et rotation relatives au centre, materiau,
        // skin). Tant que "Objets" n'est pas vide, le lobby est reconstruit a
        // partir de cette liste plutot que de la grille.

        private class LobbyObject
        {
            public string Prefab = "";
            public float X;
            public float Y;
            public float Z;
            public float RX;
            public float RY;
            public float RZ;
            public int Grade = -1;
            public ulong Skin;
        }

        private class LobbyPoint
        {
            public float X;
            public float Y;
            public float Z;
        }

        private class LobbyFreePortal
        {
            public string Mode = "";
            public string Nom = "";
            public float X;
            public float Y;
            public float Z;
        }

        private const string LayoutBackupFile = "RustGameHub_Lobby_precedent";
        private const int MaxLobbyObjects = 3000;
        private readonly HashSet<ulong> _lobbyEditors = new HashSet<ulong>();
        private readonly HashSet<BaseEntity> _portalDecor = new HashSet<BaseEntity>();
        private readonly Dictionary<string, Vector3> _allPortalPoints = new Dictionary<string, Vector3>();
        private readonly Dictionary<string, string> _allPortalNames = new Dictionary<string, string>();
        private readonly List<Vector3> _editSpawns = new List<Vector3>();
        private bool _editSpawnsTouched;
        private readonly Dictionary<string, Vector3> _editPortalPoints = new Dictionary<string, Vector3>();
        private readonly Dictionary<string, string> _editPortalNames = new Dictionary<string, string>();
        private readonly HashSet<string> _editPortalRemoved = new HashSet<string>();
        private float _lobbyBottomY;
        private float _lobbyTopY;

        private bool HasLobbyObjects()
        {
            return _layout != null && _layout.Objets != null && _layout.Objets.Count > 0;
        }

        private void SpawnPortal(string key, string label, Vector3 floor)
        {
            _portalPositions[key] = floor;
            BaseEntity rug = SpawnProtected(RugPrefab, floor, Quaternion.identity);
            // Le tapis est regenere depuis le portail : il ne doit pas etre
            // enregistre comme objet, sinon il serait double a chaque sauvegarde.
            if (rug != null) _portalDecor.Add(rug);
            Vector3 outward = new Vector3(floor.x - _lobbyCenter.x, 0f, floor.z - _lobbyCenter.z);
            outward = outward.sqrMagnitude > 0.01f ? outward.normalized : Vector3.forward;
            SpawnSkyGuide(label, floor + outward * 1.1f, Quaternion.LookRotation(-outward));
        }

        private void BuildLobbyFromObjects()
        {
            float ground = TerrainMeta.HeightMap.GetHeight(Vector3.zero);
            float altitude = Mathf.Max(_layout.Altitude, ground + 60f);
            _lobbyCenter = new Vector3(0f, altitude, 0f);
            _lobbyFloorY = altitude;
            float radius = 10f;
            float minY = 0f;
            float maxY = 0f;
            int missing = 0;
            List<string> missingNames = new List<string>();

            // Les blocs de construction d'abord : certains objets (tapis, meubles)
            // se detruisent s'ils n'ont rien sous eux au moment ou ils apparaissent.
            List<LobbyObject> ordered = _layout.Objets
                .Where(item => item != null && !string.IsNullOrEmpty(item.Prefab))
                .OrderBy(item => item.Grade >= 0 ? 0 : 1)
                .Take(MaxLobbyObjects)
                .ToList();
            foreach (LobbyObject item in ordered)
            {
                Vector3 position = _lobbyCenter + new Vector3(item.X, item.Y, item.Z);
                BaseEntity entity = GameManager.server.CreateEntity(item.Prefab, position, Quaternion.Euler(item.RX, item.RY, item.RZ), true);
                if (entity == null)
                {
                    missing++;
                    if (missingNames.Count < 8 && !missingNames.Contains(item.Prefab)) missingNames.Add(item.Prefab);
                    continue;
                }
                entity.enableSaving = false;
                entity.skinID = item.Skin;
                BuildingBlock block = entity as BuildingBlock;
                if (block != null)
                {
                    block.grounded = true;
                    block.blockDefinition = PrefabAttribute.server.Find<Construction>(block.prefabID);
                    if (item.Grade >= 0) block.SetGrade((BuildingGrade.Enum)item.Grade);
                }
                entity.Spawn();
                if (block != null)
                {
                    block.SetHealthToMax();
                    block.SendNetworkUpdate();
                }
                _lobbyEntities.Add(entity);
                _lobbyProtected.Add(entity);
                radius = Mathf.Max(radius, new Vector2(item.X, item.Z).magnitude + 2f);
                minY = Mathf.Min(minY, item.Y);
                maxY = Mathf.Max(maxY, item.Y);
            }
            _lobbyRadius = radius;
            _lobbyBottomY = altitude + minY - 6f;
            _lobbyTopY = altitude + Mathf.Max(25f, maxY + 10f);

            if (_layout.Apparitions != null)
            {
                foreach (LobbyPoint point in _layout.Apparitions)
                {
                    if (point != null) _lobbySpawns.Add(_lobbyCenter + new Vector3(point.X, point.Y, point.Z));
                }
            }
            if (_lobbySpawns.Count == 0) _lobbySpawns.Add(_lobbyCenter);

            Dictionary<string, string> labels = new Dictionary<string, string>();
            foreach (PortalDefinition definition in Portals()) labels[definition.Key] = definition.Label;
            if (_layout.PortailsLibres != null)
            {
                foreach (LobbyFreePortal portal in _layout.PortailsLibres)
                {
                    if (portal == null) continue;
                    string key = (portal.Mode ?? "").ToLowerInvariant();
                    if (!labels.ContainsKey(key)) continue;
                    Vector3 floor = _lobbyCenter + new Vector3(portal.X, portal.Y, portal.Z);
                    string label = string.IsNullOrEmpty(portal.Nom) ? labels[key] : portal.Nom;
                    _allPortalPoints[key] = floor;
                    _allPortalNames[key] = label;
                    if (!IsModeAvailable(key)) continue;
                    SpawnPortal(key, label, floor);
                }
            }

            ApplyDayLock();
            // Les chemins fautifs sont nommes : un objet absent de cette version
            // du jeu se corrige dans le plan au lieu d'etre cherche a l'aveugle.
            string note = missing > 0 ? ", " + missing + " objet(s) introuvable(s) dans cette version du jeu : " + string.Join(" | ", missingNames.ToArray()) : "";
            Puts($"Lobby \"{_layout.Nom}\" construit a {altitude:F0} m (construit en jeu) : {_lobbyEntities.Count} elements, {_portalPositions.Count} portail(s){note}.");
        }

        private float EditRadius()
        {
            return Mathf.Max(_lobbyRadius + 40f, 60f);
        }

        private bool IsInEditArea(Vector3 position)
        {
            if (_lobbyEntities.Count == 0) return false;
            return HorizontalDistance(position, _lobbyCenter) <= EditRadius() &&
                   position.y > _lobbyBottomY - 30f && position.y < _lobbyTopY + 60f;
        }

        private bool IsLobbyEditor(BasePlayer player)
        {
            return player != null && _lobbyEditors.Contains(player.userID);
        }

        private bool IsEditingHere(BasePlayer player)
        {
            return IsLobbyEditor(player) && IsInEditArea(player.transform.position);
        }

        // Construction gratuite, mais seulement pour un editeur et seulement
        // autour du lobby : ailleurs, les regles normales du jeu s'appliquent.
        private object CanAffordToPlace(BasePlayer player, Planner planner, Construction construction)
        {
            return IsEditingHere(player) ? (object)true : null;
        }

        private object OnPayForPlacement(BasePlayer player, Planner planner, Construction construction)
        {
            return IsEditingHere(player) ? (object)false : null;
        }

        private object CanAffordUpgrade(BasePlayer player, BuildingBlock block, BuildingGrade.Enum grade)
        {
            return IsEditingHere(player) ? (object)true : null;
        }

        private object OnPayForUpgrade(BasePlayer player, BuildingBlock block, ConstructionGrade gradeTarget)
        {
            return IsEditingHere(player) ? (object)false : null;
        }

        private bool IsSavableLobbyEntity(BaseEntity entity)
        {
            if (entity is BasePlayer) return false;           // joueurs et guides de portail
            if (entity is BaseCorpse) return false;
            if (entity is DroppedItem || entity is DroppedItemContainer) return false;
            if (entity is BaseNpc) return false;
            if (_portalDecor.Contains(entity)) return false;  // regenere depuis le portail
            // Les enfants (serrures, prises, accessoires) suivent leur parent :
            // les enregistrer a part les ferait apparaitre deux fois.
            if (entity.GetParentEntity() != null) return false;
            return !string.IsNullOrEmpty(entity.PrefabName);
        }

        private static float Round3(float value)
        {
            return Mathf.Round(value * 1000f) / 1000f;
        }

        private string SaveLobbyFromWorld()
        {
            if (_layout == null) LoadLayout();
            if (_lobbyEntities.Count == 0) return "Aucun lobby construit : rien a sauvegarder.";

            List<BaseEntity> found = new List<BaseEntity>();
            foreach (BaseNetworkable networkable in BaseNetworkable.serverEntities.ToList())
            {
                BaseEntity entity = networkable as BaseEntity;
                if (entity == null || entity.IsDestroyed || !IsSavableLobbyEntity(entity)) continue;
                if (!IsInEditArea(entity.transform.position)) continue;
                found.Add(entity);
            }
            if (found.Count == 0) return "Aucun objet trouve autour du lobby : sauvegarde annulee.";
            if (found.Count > MaxLobbyObjects) return $"{found.Count} objets : au-dela de {MaxLobbyObjects}, sauvegarde refusee pour proteger le serveur.";

            // Copie de securite avant toute ecriture : /lobby restore y revient.
            Interface.Oxide.DataFileSystem.WriteObject(LayoutBackupFile, _layout);

            List<LobbyObject> objects = new List<LobbyObject>();
            foreach (BaseEntity entity in found)
            {
                Vector3 offset = entity.transform.position - _lobbyCenter;
                Vector3 euler = entity.transform.rotation.eulerAngles;
                BuildingBlock block = entity as BuildingBlock;
                objects.Add(new LobbyObject
                {
                    Prefab = entity.PrefabName,
                    X = Round3(offset.x), Y = Round3(offset.y), Z = Round3(offset.z),
                    RX = Round3(euler.x), RY = Round3(euler.y), RZ = Round3(euler.z),
                    Grade = block != null ? (int)block.grade : -1,
                    Skin = entity.skinID
                });
            }

            List<LobbyPoint> spawns = new List<LobbyPoint>();
            List<Vector3> spawnSource = _editSpawnsTouched && _editSpawns.Count > 0 ? _editSpawns : _lobbySpawns;
            foreach (Vector3 point in spawnSource)
            {
                Vector3 offset = point - _lobbyCenter;
                spawns.Add(new LobbyPoint { X = Round3(offset.x), Y = Round3(offset.y), Z = Round3(offset.z) });
            }

            // Tous les portails connus, y compris ceux d'un mode coupe en ce
            // moment : sauvegarder pendant que Zombie est desactive ne doit pas
            // effacer son portail pour toujours.
            Dictionary<string, Vector3> points = new Dictionary<string, Vector3>(_allPortalPoints);
            Dictionary<string, string> names = new Dictionary<string, string>(_allPortalNames);
            foreach (KeyValuePair<string, Vector3> pair in _editPortalPoints) points[pair.Key] = pair.Value;
            foreach (KeyValuePair<string, string> pair in _editPortalNames) names[pair.Key] = pair.Value;
            foreach (string key in _editPortalRemoved) { points.Remove(key); names.Remove(key); }
            List<LobbyFreePortal> portals = new List<LobbyFreePortal>();
            foreach (KeyValuePair<string, Vector3> pair in points)
            {
                Vector3 offset = pair.Value - _lobbyCenter;
                string name;
                portals.Add(new LobbyFreePortal
                {
                    Mode = pair.Key,
                    Nom = names.TryGetValue(pair.Key, out name) ? name : "",
                    X = Round3(offset.x), Y = Round3(offset.y), Z = Round3(offset.z)
                });
            }

            _layout.Objets = objects;
            _layout.Apparitions = spawns;
            _layout.PortailsLibres = portals;
            Interface.Oxide.DataFileSystem.WriteObject(LayoutFile, _layout);

            // Les objets poses a la main deviennent des objets du lobby : on retire
            // les originaux avant de reconstruire, sinon tout serait en double.
            foreach (BaseEntity entity in found)
            {
                if (entity != null && !entity.IsDestroyed) entity.Kill();
            }
            _editSpawns.Clear();
            _editSpawnsTouched = false;
            _editPortalPoints.Clear();
            _editPortalNames.Clear();
            _editPortalRemoved.Clear();
            RebuildLobbyAndRecall();
            return $"Lobby sauvegarde : {objects.Count} objets, {spawns.Count} apparition(s), {portals.Count} portail(s). Version precedente : /lobby restore.";
        }

        private string RestorePreviousLobby()
        {
            if (!Interface.Oxide.DataFileSystem.ExistsDatafile(LayoutBackupFile)) return "Aucune version precedente a restaurer.";
            LobbyLayout previous = Interface.Oxide.DataFileSystem.ReadObject<LobbyLayout>(LayoutBackupFile);
            bool emptyGrid = previous == null || previous.Grille == null || previous.Grille.Count == 0;
            bool emptyObjects = previous == null || previous.Objets == null || previous.Objets.Count == 0;
            if (emptyGrid && emptyObjects) return "Version precedente illisible : rien n'a ete change.";
            // Echange des deux versions : un second /lobby restore annule le premier.
            LobbyLayout current = _layout;
            Interface.Oxide.DataFileSystem.WriteObject(LayoutFile, previous);
            if (current != null) Interface.Oxide.DataFileSystem.WriteObject(LayoutBackupFile, current);
            RebuildLobbyAndRecall();
            return "Version precedente du lobby restauree. Refais /lobby restore pour annuler.";
        }

        private string ReturnToGridLobby()
        {
            if (_layout == null) LoadLayout();
            if (!HasLobbyObjects()) return "Le lobby utilise deja le plan en grille.";
            Interface.Oxide.DataFileSystem.WriteObject(LayoutBackupFile, _layout);
            _layout.Objets = new List<LobbyObject>();
            _layout.Apparitions = new List<LobbyPoint>();
            _layout.PortailsLibres = new List<LobbyFreePortal>();
            Interface.Oxide.DataFileSystem.WriteObject(LayoutFile, _layout);
            RebuildLobbyAndRecall();
            return "Retour au plan en grille. La construction en jeu est gardee : /lobby restore pour la retrouver.";
        }

        private bool HandleLobbyAdmin(BasePlayer player, string action, string[] args)
        {
            switch (action)
            {
                case "edit": case "edition": ToggleLobbyEdit(player); return true;
                case "save": case "sauver": SendReply(player, SaveLobbyFromWorld()); return true;
                case "remove": case "suppr": RemoveLookedAtObject(player); return true;
                case "spawn": case "apparition": EditLobbySpawn(player, args); return true;
                case "portal": case "portail": EditLobbyPortal(player, args); return true;
                case "restore": case "restaurer": SendReply(player, RestorePreviousLobby()); return true;
                case "grid": case "grille": SendReply(player, ReturnToGridLobby()); return true;
                case "help": case "aide": ShowLobbyEditHelp(player); return true;
                default: return false;
            }
        }

        private void ToggleLobbyEdit(BasePlayer player)
        {
            if (_lobbyEditors.Remove(player.userID))
            {
                _lobbyExempt.Remove(player.userID);
                SendReply(player, "Mode edition termine. Ce que tu as construit n'est garde qu'apres <color=#ffd479>/lobby save</color>.");
                return;
            }
            if (_lobbyEntities.Count == 0) BuildLobby();
            _lobbyEditors.Add(player.userID);
            // Exempte : pas de rappel automatique pendant qu'on construit.
            _lobbyExempt.Add(player.userID);
            _lobbyPlayers.Remove(player.userID);
            GiveEditTool(player, "building.planner");
            GiveEditTool(player, "hammer");
            ShowLobbyEditHelp(player);
        }

        private void GiveEditTool(BasePlayer player, string shortname)
        {
            ItemDefinition definition = ItemManager.FindItemDefinition(shortname);
            if (definition == null || player.inventory == null) return;
            if (player.inventory.GetAmount(definition.itemid) > 0) return;
            Item item = ItemManager.Create(definition, 1);
            if (item != null && !player.inventory.GiveItem(item)) item.Remove();
        }

        private void ShowLobbyEditHelp(BasePlayer player)
        {
            SendReply(player, "<color=#ffd479>EDITION DU LOBBY</color> - construction et amelioration gratuites autour du lobby. Rien n'est garde avant /lobby save.");
            SendReply(player, "/lobby save : enregistre tout ce qui est construit autour du lobby");
            SendReply(player, "/lobby remove : supprime l'objet que tu regardes");
            SendReply(player, "/lobby spawn : point d'apparition a tes pieds (/lobby spawn clear pour repartir de zero)");
            SendReply(player, "/lobby portal <mode> [nom] : portail a tes pieds (/lobby portal remove <mode>)");
            SendReply(player, "Modes : " + string.Join(", ", Portals().Select(portal => portal.Key).ToArray()));
            SendReply(player, "/lobby restore : version precedente   /lobby grid : retour au plan en grille   /lobby edit : quitter l'edition");
        }

        private void EditLobbySpawn(BasePlayer player, string[] args)
        {
            string sub = args.Length > 1 ? args[1].ToLowerInvariant() : "";
            if (sub == "clear" || sub == "effacer")
            {
                _editSpawns.Clear();
                _editSpawnsTouched = true;
                SendReply(player, "Points d'apparition effaces. Ajoute-en avec /lobby spawn avant /lobby save, sinon les anciens sont gardes.");
                return;
            }
            _editSpawns.Add(player.transform.position);
            _editSpawnsTouched = true;
            SendReply(player, $"Point d'apparition {_editSpawns.Count} pose. Il compte a la prochaine /lobby save.");
        }

        private void EditLobbyPortal(BasePlayer player, string[] args)
        {
            if (args.Length < 2)
            {
                SendReply(player, "Usage : /lobby portal <mode> [nom]  ou  /lobby portal remove <mode>");
                return;
            }
            bool remove = args[1].ToLowerInvariant() == "remove" || args[1].ToLowerInvariant() == "retirer";
            string key = (remove ? (args.Length > 2 ? args[2] : "") : args[1]).ToLowerInvariant();
            Dictionary<string, string> catalog = new Dictionary<string, string>();
            foreach (PortalDefinition definition in Portals()) catalog[definition.Key] = definition.Label;
            if (!catalog.ContainsKey(key))
            {
                SendReply(player, "Mode inconnu. Modes : " + string.Join(", ", catalog.Keys.ToArray()));
                return;
            }
            if (remove)
            {
                _editPortalRemoved.Add(key);
                _editPortalPoints.Remove(key);
                _editPortalNames.Remove(key);
                SendReply(player, $"Portail {catalog[key]} retire a la prochaine /lobby save.");
                return;
            }
            string name = args.Length > 2 ? string.Join(" ", args.Skip(2).ToArray()).ToUpperInvariant() : catalog[key];
            _editPortalRemoved.Remove(key);
            _editPortalPoints[key] = player.transform.position;
            _editPortalNames[key] = name;
            SendReply(player, $"Portail {name} place a tes pieds. Il apparaitra apres /lobby save.");
        }

        private void RemoveLookedAtObject(BasePlayer player)
        {
            RaycastHit hit;
            int mask = LayerMask.GetMask("Construction", "Deployed", "Default");
            if (!Physics.Raycast(player.eyes.HeadRay(), out hit, 12f, mask))
            {
                SendReply(player, "Aucun objet vise a moins de 12 m.");
                return;
            }
            BaseEntity entity = hit.GetEntity();
            if (entity == null || entity is BasePlayer || !IsInEditArea(entity.transform.position))
            {
                SendReply(player, "Rien a supprimer ici : vise un objet du lobby.");
                return;
            }
            string name = entity.ShortPrefabName;
            _lobbyEntities.Remove(entity);
            _lobbyProtected.Remove(entity);
            _portalDecor.Remove(entity);
            entity.Kill();
            SendReply(player, $"{name} supprime. Pense a /lobby save.");
        }

        [ConsoleCommand("lobby.save")]
        private void ConsoleLobbySave(ConsoleSystem.Arg arg)
        {
            BasePlayer caller = arg.Player();
            if (caller != null && !caller.IsAdmin) { arg.ReplyWith("Commande reservee aux administrateurs."); return; }
            arg.ReplyWith(SaveLobbyFromWorld());
        }

        [ConsoleCommand("lobby.restore")]
        private void ConsoleLobbyRestore(ConsoleSystem.Arg arg)
        {
            BasePlayer caller = arg.Player();
            if (caller != null && !caller.IsAdmin) { arg.ReplyWith("Commande reservee aux administrateurs."); return; }
            arg.ReplyWith(RestorePreviousLobby());
        }

        [ConsoleCommand("lobby.grid")]
        private void ConsoleLobbyGrid(ConsoleSystem.Arg arg)
        {
            BasePlayer caller = arg.Player();
            if (caller != null && !caller.IsAdmin) { arg.ReplyWith("Commande reservee aux administrateurs."); return; }
            arg.ReplyWith(ReturnToGridLobby());
        }

        [ConsoleCommand("lobby.debug")]
        private void ConsoleLobbyDebug(ConsoleSystem.Arg arg)
        {
            BasePlayer caller = arg.Player();
            if (caller != null && !caller.IsAdmin) { arg.ReplyWith("Commande reservee aux administrateurs."); return; }
            int alive = _lobbyEntities.Count(entity => entity != null && !entity.IsDestroyed);
            int blocks = _lobbyProtected.Count(entity => entity is BuildingBlock && !entity.IsDestroyed);
            string wall = "";
            BuildingBlock lowWall = _lobbyProtected.OfType<BuildingBlock>().FirstOrDefault(block => block != null && !block.IsDestroyed && block.ShortPrefabName.Contains("wall"));
            if (lowWall != null)
            {
                Bounds bounds = lowWall.WorldSpaceBounds().ToBounds();
                wall = $" mur[pos={lowWall.transform.position} rot={lowWall.transform.eulerAngles.y:F0} ext={bounds.extents}]";
            }
            string name = _layout != null ? _layout.Nom : "?";
            string kind = HasLobbyObjects() ? "3d:" + _layout.Objets.Count : "grille";
            arg.ReplyWith($"plan=\"{name}\" type={kind} editeurs={_lobbyEditors.Count} zone=[{_lobbyBottomY:F0};{_lobbyTopY:F0}] minijeux={IsMiniGameServer()} centre={_lobbyCenter} sol={_lobbyFloorY:F2} rayon={_lobbyRadius:F1} " +
                          $"entites={alive}/{_lobbyEntities.Count} blocs={blocks} guides={_lobbyGuides.Count} spawns={_lobbySpawns.Count} " +
                          $"portails=[{string.Join(",", _portalPositions.Keys.ToArray())}] joueurs={_lobbyPlayers.Count} exemptes={_lobbyExempt.Count}{wall}");
        }

        private void ActivatePortal(BasePlayer player, string key)
        {
            if (IsMiniGameServer())
            {
                // Le mode memorise la position de depart comme point de retour.
                // Recentre d'abord : sinon on reviendrait sur le portail en fin
                // de partie et on le redeclencherait aussitot.
                player.Teleport(NextLobbySpawn());
                LeaveLobby(player, false);
            }
            else LeaveLobby(player, true);
            if (key == "duel") Interface.CallHook("JoinDuelQueueFromLobby", player, 1);
            else if (key == "zombie") Interface.CallHook("JoinZombieModeFromLobby", player);
            else if (key == "gungame") Interface.CallHook("JoinGunGameFromLobby", player);
            else if (key == "towerdefense") Interface.CallHook("JoinTowerDefenseFromLobby", player);
            else if (key == "training") Interface.CallHook("JoinTrainingFromLobby", player, "aim");
            else if (key == "battlefield") Interface.CallHook("JoinBattlefieldFromLobby", player);
            else ToggleModeQueue(player, key);
        }

        /// <summary>
        /// Les decalages etaient ecrits a la main, ce qui rendait l'ajout d'un
        /// neuvieme portail collisionnel avec les diagonales. L'anneau est
        /// desormais calcule et la liste mise en cache : TickLobbyPortals
        /// reconstruisait sinon la liste et ses objets a chaque joueur, chaque seconde.
        /// </summary>
        private List<PortalDefinition> Portals()
        {
            if (_portals != null) return _portals;

            string[][] definitions =
            {
                new[] { "duel", "DUEL" },
                new[] { "zombie", "ZOMBIE" },
                new[] { "gungame", "GUN GAME" },
                new[] { "towerdefense", "TOWER DEFENSE" },
                new[] { "training", "ENTRAINEMENT" },
                new[] { "ctf", "CTF" },
                new[] { "domination", "DOMINATION" },
                new[] { "snd", "SEARCH & DESTROY" },
                new[] { "extraction", "EXTRACTION" },
                new[] { "battlefield", "BATTLEFIELD" }
            };

            const float portalRadius = 20f;
            _portals = new List<PortalDefinition>();
            for (int index = 0; index < definitions.Length; index++)
            {
                float angle = index * Mathf.PI * 2f / definitions.Length;
                Vector3 offset = new Vector3(Mathf.Cos(angle), 0f, Mathf.Sin(angle)) * portalRadius;
                _portals.Add(new PortalDefinition(definitions[index][0], definitions[index][1], offset));
            }
            return _portals;
        }

        private void LeaveLobby(BasePlayer player, bool returnPlayer)
        {
            CloseMenu(player);
            if (player == null || !_lobbyPlayers.Remove(player.userID)) return;
            if (returnPlayer) ReturnLobbyPlayer(player);
            _lobbyReturnPositions.Remove(player.userID);
        }

        private void ReturnLobbyPlayer(BasePlayer player)
        {
            Vector3 position;
            if (player != null && player.IsConnected && _lobbyReturnPositions.TryGetValue(player.userID, out position)) player.Teleport(position);
        }

        private void BuildArena()
        {
            RemoveArena();
            _arenaCenter = FindSafeCenter(40f, true);
            const int walls = 44;
            const float radius = 40f;
            for (int index = 0; index < walls; index++)
            {
                float angle = index * Mathf.PI * 2f / walls;
                Vector3 offset = new Vector3(Mathf.Cos(angle), 0f, Mathf.Sin(angle)) * radius;
                SpawnTracked(WallPrefab, Ground(_arenaCenter + offset), Quaternion.Euler(0f, -angle * Mathf.Rad2Deg, 0f), _arenaEntities);
            }
            for (int index = 0; index < 14; index++)
            {
                float angle = index * Mathf.PI * 2f / 14f;
                float distance = index % 2 == 0 ? 14f : 25f;
                string prefab = index % 3 == 0 ? SandbagPrefab : ConcretePrefab;
                SpawnTracked(prefab, Ground(_arenaCenter + new Vector3(Mathf.Cos(angle), 0f, Mathf.Sin(angle)) * distance), Quaternion.Euler(0f, -angle * Mathf.Rad2Deg, 0f), _arenaEntities);
            }
        }

        private Vector3 FindSafeCenter(float radius, bool avoidLobby)
        {
            float halfSize = TerrainMeta.Size.x * 0.5f;
            float limit = Mathf.Max(120f, halfSize * 0.72f);
            for (int attempt = 0; attempt < 160; attempt++)
            {
                Vector3 candidate = new Vector3(UnityEngine.Random.Range(-limit, limit), 0f, UnityEngine.Random.Range(-limit, limit));
                if (IsSafeCenter(candidate, radius, avoidLobby)) { candidate.y = TerrainMeta.HeightMap.GetHeight(candidate) + 0.1f; return candidate; }
            }
            Vector3 fallback = avoidLobby ? new Vector3(300f, 0f, 300f) : Vector3.zero;
            fallback.y = TerrainMeta.HeightMap.GetHeight(fallback) + 0.1f;
            return fallback;
        }

        private bool IsSafeCenter(Vector3 candidate, float radius, bool avoidLobby)
        {
            float terrain = TerrainMeta.HeightMap.GetHeight(candidate);
            float water = TerrainMeta.WaterMap.GetHeight(candidate);
            // 3m au-dessus de la mer, et non -1 : WaterMap ne couvre que les lacs
            // et rivieres, jamais l'ocean, donc elle ne rattrapait pas un terrain
            // immerge. Le seuil de -1 acceptait explicitement du sol sous l'eau.
            if (terrain < 3f || terrain <= water + 2f) return false;
            float min = float.MaxValue;
            float max = float.MinValue;
            foreach (Vector3 offset in new[] { Vector3.zero, Vector3.right * radius, Vector3.left * radius, Vector3.forward * radius, Vector3.back * radius })
            {
                float height = TerrainMeta.HeightMap.GetHeight(candidate + offset);
                min = Mathf.Min(min, height);
                max = Mathf.Max(max, height);
            }
            if (max - min > 5f) return false;
            if (avoidLobby && _lobbyEntities.Count > 0 && HorizontalDistance(candidate, _lobbyCenter) < 160f) return false;
            if (TerrainMeta.Path != null && TerrainMeta.Path.Monuments != null)
            {
                foreach (MonumentInfo monument in TerrainMeta.Path.Monuments)
                {
                    if (monument != null && HorizontalDistance(monument.transform.position, candidate) < 130f) return false;
                }
            }
            return true;
        }

        private void SpawnTracked(string prefab, Vector3 position, Quaternion rotation, List<BaseEntity> bucket)
        {
            BaseEntity entity = GameManager.server.CreateEntity(prefab, position, rotation, true);
            if (entity == null) return;
            entity.enableSaving = false;
            entity.Spawn();
            bucket.Add(entity);
        }

        private void RemoveArena()
        {
            foreach (BaseEntity entity in _arenaEntities.ToArray()) if (entity != null && !entity.IsDestroyed) entity.Kill();
            _arenaEntities.Clear();
            _arenaCenter = Vector3.zero;
        }

        private void RemoveLobby()
        {
            foreach (BaseEntity entity in _lobbyEntities.ToArray()) if (entity != null && !entity.IsDestroyed) entity.Kill();
            foreach (BasePlayer guide in _lobbyGuides.ToArray()) if (guide != null && !guide.IsDestroyed) guide.Kill();
            _lobbyEntities.Clear();
            _lobbyGuides.Clear();
            _lobbyProtected.Clear();
            _lobbySpawns.Clear();
            _portalPositions.Clear();
            _portalDecor.Clear();
            _allPortalPoints.Clear();
            _allPortalNames.Clear();
        }

        private Vector3 GetModeSpawn(ulong userId)
        {
            if (_activeMode == "extraction")
            {
                int index = _participants.OrderBy(id => id).ToList().IndexOf(userId);
                float angle = index * Mathf.PI * 2f / Math.Max(1, _participants.Count);
                return Ground(_arenaCenter + new Vector3(Mathf.Cos(angle), 0f, Mathf.Sin(angle)) * 27f) + Vector3.up * 1.2f;
            }
            int team = TeamOf(userId);
            List<ulong> teamPlayers = _participants.Where(id => TeamOf(id) == team).OrderBy(id => id).ToList();
            int teamIndex = teamPlayers.IndexOf(userId);
            float x = team == 1 ? -28f : 28f;
            float z = (teamIndex - (teamPlayers.Count - 1) * 0.5f) * 6f;
            return Ground(_arenaCenter + new Vector3(x, 0f, z)) + Vector3.up * 1.2f;
        }

        private Vector3 GetTeamBase(int team) { return Ground(_arenaCenter + new Vector3(team == 1 ? -29f : 29f, 0f, 0f)) + Vector3.up; }
        private Vector3 GetSndTarget() { return Ground(_arenaCenter) + Vector3.up; }
        private Vector3 GetSpectatorPoint() { return Ground(_arenaCenter + new Vector3(45f, 0f, 0f)) + Vector3.up; }
        private Vector3 GetExtractionPoint(int index)
        {
            float angle = index * Mathf.PI * 2f / _extractionAvailable.Length;
            return Ground(_arenaCenter + new Vector3(Mathf.Cos(angle), 0f, Mathf.Sin(angle)) * 18f) + Vector3.up;
        }

        private Vector3 Ground(Vector3 position) { position.y = TerrainMeta.HeightMap.GetHeight(position); return position; }
        private float HorizontalDistance(Vector3 first, Vector3 second) { first.y = 0f; second.y = 0f; return Vector3.Distance(first, second); }
        private int TeamOf(ulong userId) { int team; return _teams.TryGetValue(userId, out team) ? team : 0; }
        private BasePlayer FindPlayer(ulong userId) { return BasePlayer.activePlayerList.FirstOrDefault(player => player != null && player.userID == userId); }
        private IEnumerable<BasePlayer> ModePlayers() { return _participants.Select(FindPlayer).Where(player => player != null); }

        private bool RemoveFromAllQueues(ulong userId)
        {
            bool removed = false;
            foreach (List<ulong> queue in _queues.Values) removed |= queue.Remove(userId);
            return removed;
        }

        private void TryStartAnyQueuedMode()
        {
            string next = _modeOrder.FirstOrDefault(mode => _queues[mode].Count >= MinimumPlayers(mode));
            if (!string.IsNullOrEmpty(next)) TryScheduleMode(next);
        }

        private int MinimumPlayers(string mode) { return mode == "extraction" ? 1 : 2; }
        private string NormalizeMode(string value)
        {
            string mode = value.ToLowerInvariant();
            if (mode == "dom") return "domination";
            if (mode == "extract") return "extraction";
            return mode;
        }

        private string ModeLabel(string mode)
        {
            if (mode == "ctf") return "CAPTURE DU DRAPEAU";
            if (mode == "domination") return "DOMINATION";
            if (mode == "snd") return "SEARCH & DESTROY";
            if (mode == "extraction") return "EXTRACTION";
            return mode.ToUpperInvariant();
        }

        private string ModeStartInstructions(string mode)
        {
            if (mode == "ctf") return "CTF : vole le drapeau adverse et rapporte-le a ta base. Premier a 3 captures.";
            if (mode == "domination") return "DOMINATION : controle la zone centrale. Premiere equipe a 100 points.";
            return "EXTRACTION : collecte 3 caches autour de l'arene puis reviens au centre vivant.";
        }

        private void BroadcastQueue(string mode, string message)
        {
            foreach (ulong userId in _queues[mode].ToArray()) { BasePlayer player = FindPlayer(userId); if (player != null) SendReply(player, message); }
        }

        private void BroadcastMode(string message)
        {
            foreach (BasePlayer player in ModePlayers()) SendReply(player, message);
        }

        private void BroadcastGlobal(string message)
        {
            foreach (BasePlayer player in BasePlayer.activePlayerList) if (player != null && player.IsConnected) SendReply(player, message);
        }

        // ----- Menu a l'ecran ---------------------------------------------------

        private const string MenuPanel = "rustgamehub.menu";
        private const string InventoryButtonPanel = "rustgamehub.invbutton";
        private const string MenuBackdrop = "rustgamehub.menu.backdrop";
        private const float MenuTimeoutSeconds = 120f;

        /// <summary>
        /// Pose le bouton d'acces au menu. Il est parente a "Hud.Menu" : ce
        /// conteneur n'est rendu par le client que lorsque l'inventaire est
        /// ouvert. Le bouton est donc invisible en jeu et apparait tout seul
        /// avec l'inventaire, sans aucun hook d'ouverture -- il n'en existe pas
        /// pour son propre inventaire.
        /// </summary>
        private void ShowInventoryButton(BasePlayer player)
        {
            if (player == null || !player.IsConnected) return;

            // Toujours detruire avant : sans cela chaque reapparition empile
            // un bouton de plus sur le precedent.
            CuiHelper.DestroyUi(player, InventoryButtonPanel);

            CuiElementContainer container = new CuiElementContainer();
            // Un panneau transparent porte les deux boutons : une seule
            // destruction suffit a tout retirer.
            // CursorEnabled reste absent : l'inventaire fournit deja le curseur.
            container.Add(new CuiPanel
            {
                Image = { Color = "0 0 0 0" },
                RectTransform = { AnchorMin = Anchor(0.015f, 0.815f), AnchorMax = Anchor(0.155f, 0.935f) }
            }, "Hud.Menu", InventoryButtonPanel);
            container.Add(new CuiButton
            {
                Button = { Command = "hub.menu", Color = "0.83 0.29 0.18 0.95" },
                Text = { Text = "MENU DES MODES", FontSize = 12, Align = TextAnchor.MiddleCenter, Color = "1 0.97 0.93 1" },
                RectTransform = { AnchorMin = "0 0.54", AnchorMax = "1 1" }
            }, InventoryButtonPanel);
            if (plugins.Find("RustGunGame") != null)
            {
                container.Add(new CuiButton
                {
                    Button = { Command = "hub.menu.skins", Color = "0.22 0.20 0.17 0.95" },
                    Text = { Text = "MES SKINS", FontSize = 12, Align = TextAnchor.MiddleCenter, Color = "1 0.85 0.47 1" },
                    RectTransform = { AnchorMin = "0 0", AnchorMax = "1 0.46" }
                }, InventoryButtonPanel);
            }

            CuiHelper.AddUi(player, container);
        }

        private void OnPlayerConnected(BasePlayer player)
        {
            if (player == null) return;
            // Legere temporisation : la pose echoue si le client n'a pas fini
            // de charger son interface.
            timer.Once(4f, () => ShowInventoryButton(player));
        }

        private void OnPlayerSleepEnded(BasePlayer player)
        {
            ShowInventoryButton(player);
            if (player == null || !IsMiniGameServer() || _lobbyExempt.Contains(player.userID)) return;
            if (IsPlayingSomewhere(player) || IsInLobbyZone(player.transform.position)) return;
            SendToLobby(player);
        }

        [ChatCommand("menu")]
        private void CommandMenu(BasePlayer player, string command, string[] args)
        {
            OpenMenu(player, "modes");
        }

        [ConsoleCommand("hub.menu")]
        private void ConsoleMenu(ConsoleSystem.Arg arg)
        {
            BasePlayer player = arg.Player();
            if (player == null) return;
            OpenMenu(player, "modes");
        }

        [ConsoleCommand("hub.menu.page")]
        private void ConsoleMenuPage(ConsoleSystem.Arg arg)
        {
            BasePlayer player = arg.Player();
            if (player == null) return;
            string[] args = MenuArgs(arg);
            OpenMenu(player, args.Length > 0 ? args[0] : "modes");
        }

        /// <summary>
        /// Sortie du mode en cours depuis le menu. On passe par le hook
        /// ForceLeaveMode, implemente par les six extensions de jeu : c'est le
        /// point de sortie unique, celui qui rend l'inventaire et remet le
        /// joueur ou il etait. Ne jamais arreter le mode pour tout le monde.
        /// </summary>
        [ConsoleCommand("hub.menu.leave")]
        private void ConsoleMenuLeave(ConsoleSystem.Arg arg)
        {
            BasePlayer player = arg.Player();
            if (player == null) return;

            bool engaged = IsInAnyGame(player) || (!IsMiniGameServer() && _lobbyPlayers.Contains(player.userID));
            if (!engaged)
            {
                SendReply(player, "Tu n'es engage dans aucun mode.");
                return;
            }

            Interface.CallHook("ForceLeaveMode", player);

            SendReply(player, "<color=#ffd479>Mode quitte.</color>");
            // Le menu se redessine : le bouton QUITTER disparait, et les
            // statuts des modes refletent la sortie.
            if (_menuOpen.Contains(player.userID))
            {
                string page;
                DrawMenu(player, _menuPage.TryGetValue(player.userID, out page) ? page : "modes");
            }
        }

        /// <summary>
        /// Ouvre le selecteur de skins du Gun Game. Le menu des modes est ferme
        /// d'abord : les deux panneaux vivent dans l'inventaire et se
        /// superposeraient.
        /// </summary>
        [ConsoleCommand("hub.menu.skins")]
        private void ConsoleMenuSkins(ConsoleSystem.Arg arg)
        {
            BasePlayer player = arg.Player();
            if (player == null) return;
            CloseMenu(player);
            if (plugins.Find("RustGunGame") == null)
            {
                SendReply(player, "Le selecteur de skins demande l'extension Gun Game.");
                return;
            }
            player.SendConsoleCommand("gg.skin.open");
        }

        [ConsoleCommand("hub.menu.close")]
        private void ConsoleMenuClose(ConsoleSystem.Arg arg)
        {
            BasePlayer player = arg.Player();
            if (player == null) return;
            CloseMenu(player);
            SendReply(player, "Menu ferme.");
        }

        [ConsoleCommand("hub.menu.join")]
        private void ConsoleMenuJoin(ConsoleSystem.Arg arg)
        {
            BasePlayer player = arg.Player();
            if (player == null) return;
            string[] args = MenuArgs(arg);
            if (args.Length == 0) return;

            // Le menu doit disparaitre avant le mode : sinon le joueur arrive en
            // partie avec le curseur libere et ne peut ni bouger ni tirer.
            CloseMenu(player);
            ActivatePortal(player, args[0]);
        }

        [ConsoleCommand("hub.menu.tp")]
        private void ConsoleMenuTeleport(ConsoleSystem.Arg arg)
        {
            BasePlayer player = arg.Player();
            if (player == null) return;
            string[] args = MenuArgs(arg);
            if (args.Length == 0) return;
            CloseMenu(player);

            if (args[0] == "lobby")
            {
                CommandLobby(player, "lobby", new string[0]);
                return;
            }
            if (args[0] == "retour")
            {
                if (_lobbyPlayers.Contains(player.userID)) LeaveLobby(player, true);
                else SendReply(player, "Aucune position sauvegardee : tu n'es pas passe par le lobby.");
                return;
            }
            if (args[0] == "training")
            {
                Interface.CallHook("JoinTrainingFromLobby", player, "aim");
                return;
            }
            if (args[0] == "sparring")
            {
                Interface.CallHook("JoinTrainingFromLobby", player, "spar");
            }
        }

        [ConsoleCommand("hub.menu.option")]
        private void ConsoleMenuOption(ConsoleSystem.Arg arg)
        {
            BasePlayer player = arg.Player();
            if (player == null) return;
            string[] args = MenuArgs(arg);
            if (args.Length < 3) return;

            if (args[0] == "duel") Interface.CallHook("SetDuelKitFromMenu", player, args[2]);
            else if (args[0] == "training") Interface.CallHook("SetTrainingOptionFromMenu", player, args[1], args[2]);
            OpenMenu(player, "options");
        }

        private string[] MenuArgs(ConsoleSystem.Arg arg)
        {
            return arg.Args != null ? arg.Args.Select(value => value.ToString()).ToArray() : new string[0];
        }

        private void OpenMenu(BasePlayer player, string page)
        {
            if (player == null || !player.IsConnected) return;

            // Le verrou "pas de menu en partie" protegeait du curseur libere.
            // Depuis que le menu vit dans Hud.Menu, ce risque n'existe plus, et
            // le lever est necessaire : c'est en partie qu'on veut le bouton
            // QUITTER LE MODE.

            bool firstOpen = _menuOpen.Add(player.userID);
            _menuPage[player.userID] = page;
            _menuOpenedAt[player.userID] = Time.realtimeSinceStartup;
            DrawMenu(player, page);

            if (firstOpen)
            {
                SendReply(player, "Menu ouvert dans l'inventaire. Ferme l'inventaire pour le masquer.");
            }
        }

        private void CloseMenu(BasePlayer player)
        {
            if (player == null) return;
            _menuOpen.Remove(player.userID);
            _menuPage.Remove(player.userID);
            _menuOpenedAt.Remove(player.userID);
            if (!player.IsConnected) return;
            CuiHelper.DestroyUi(player, MenuPanel);
            CuiHelper.DestroyUi(player, MenuBackdrop);
        }

        private void CloseAllMenus()
        {
            // On itere la liste des menus ouverts et pas les joueurs du lobby :
            // un joueur parti ailleurs garderait sinon son panneau a l'ecran.
            foreach (ulong userId in _menuOpen.ToArray())
            {
                BasePlayer player = BasePlayer.activePlayerList.FirstOrDefault(candidate => candidate != null && candidate.userID == userId);
                if (player != null && player.IsConnected)
                {
                    CuiHelper.DestroyUi(player, MenuPanel);
                    CuiHelper.DestroyUi(player, MenuBackdrop);
                }
            }
            _menuOpen.Clear();
            _menuPage.Clear();
            _menuOpenedAt.Clear();
        }

        private void TickMenus()
        {
            if (_menuOpen.Count == 0) return;
            float now = Time.realtimeSinceStartup;
            foreach (ulong userId in _menuOpen.ToArray())
            {
                float openedAt;
                if (!_menuOpenedAt.TryGetValue(userId, out openedAt)) { openedAt = now; }
                if (now - openedAt < MenuTimeoutSeconds) continue;

                BasePlayer player = BasePlayer.activePlayerList.FirstOrDefault(candidate => candidate != null && candidate.userID == userId);
                CloseMenu(player);
                if (player != null && player.IsConnected) SendReply(player, "Menu ferme automatiquement apres 2 minutes.");
            }
        }

        private void DrawMenu(BasePlayer player, string page)
        {
            CuiHelper.DestroyUi(player, MenuPanel);
            CuiHelper.DestroyUi(player, MenuBackdrop);

            CuiElementContainer container = new CuiElementContainer();
            // Parent "Hud.Menu" et non "Overlay" : ce conteneur n'est rendu
            // que lorsque l'inventaire est ouvert. Consequence majeure, le
            // menu ne peut plus verrouiller le curseur d'un joueur -- c'est
            // l'inventaire qui le fournit, et le fermer rend la main.
            container.Add(new CuiPanel
            {
                Image = { Color = "0 0 0 0.75" },
                RectTransform = { AnchorMin = "0 0", AnchorMax = "1 1" }
            }, "Hud.Menu", MenuBackdrop);

            string panel = container.Add(new CuiPanel
            {
                Image = { Color = "0.09 0.08 0.07 0.98" },
                RectTransform = { AnchorMin = "0.14 0.12", AnchorMax = "0.86 0.90" }
                // Pas de CursorEnabled : l'activer entrerait en conflit avec
                // celui de l'inventaire.
            }, "Hud.Menu", MenuPanel);

            container.Add(new CuiPanel
            {
                Image = { Color = "0.83 0.29 0.18 1" },
                RectTransform = { AnchorMin = "0 0.93", AnchorMax = "1 1" }
            }, panel);

            container.Add(new CuiLabel
            {
                Text = { Text = "  RUST GAME MODES - MENU", FontSize = 18, Align = TextAnchor.MiddleLeft, Color = "1 0.97 0.93 1" },
                RectTransform = { AnchorMin = "0.01 0.93", AnchorMax = "0.5 1" }
            }, panel);

            AddMenuButton(container, panel, 0.90f, 0.985f, 0.935f, 0.995f, "FERMER", "hub.menu.close", "0.62 0.18 0.15 1");
            if (plugins.Find("RustGunGame") != null)
            {
                AddMenuButton(container, panel, 0.55f, 0.67f, 0.935f, 0.995f, "MES SKINS", "hub.menu.skins", "0.22 0.20 0.17 1");
            }

            // N'apparait que si le joueur est reellement engage quelque part :
            // un bouton de sortie toujours visible inviterait au clic inutile.
            if (IsInAnyGame(player) || (!IsMiniGameServer() && _lobbyPlayers.Contains(player.userID)))
            {
                AddMenuButton(container, panel, 0.68f, 0.885f, 0.935f, 0.995f, "QUITTER LE MODE", "hub.menu.leave", "0.83 0.45 0.18 1");
            }

            string[][] tabs =
            {
                new[] { "modes", "MODES" },
                new[] { "tp", "TELEPORTS" },
                new[] { "stats", "STATS" },
                new[] { "options", "OPTIONS" }
            };
            for (int index = 0; index < tabs.Length; index++)
            {
                float min = 0.01f + index * 0.16f;
                bool active = tabs[index][0] == page;
                AddMenuButton(container, panel, min, min + 0.15f, 0.855f, 0.915f, tabs[index][1],
                    "hub.menu.page " + tabs[index][0], active ? "0.83 0.29 0.18 1" : "0.22 0.20 0.17 1");
            }

            if (page == "tp") DrawTeleportPage(container, panel, player);
            else if (page == "stats") DrawStatsPage(container, panel, player);
            else if (page == "options") DrawOptionsPage(container, panel, player);
            else DrawModesPage(container, panel);

            CuiHelper.AddUi(player, container);
        }

        private void DrawModesPage(CuiElementContainer container, string panel)
        {
            Dictionary<string, string> statuses = CollectModeStatuses();
            string[][] modes =
            {
                new[] { "duel", "DUEL", "Duel" },
                new[] { "zombie", "ZOMBIE", "Zombie" },
                new[] { "gungame", "GUN GAME", "Gun Game" },
                new[] { "battlefield", "BATTLEFIELD CONQUETE", "Battlefield" },
                new[] { "towerdefense", "TOWER DEFENSE", "Tower Defense" },
                new[] { "training", "ENTRAINEMENT", "Entrainement" },
                new[] { "ctf", "CAPTURE DU DRAPEAU", "" },
                new[] { "domination", "DOMINATION", "" },
                new[] { "snd", "SEARCH & DESTROY", "" },
                new[] { "extraction", "EXTRACTION", "" }
            };

            for (int index = 0; index < modes.Length; index++)
            {
                // Espacement proportionnel : un mode de plus ne doit pas faire
                // deborder la liste du panneau.
                float step = 0.79f / modes.Length;
                float top = 0.80f - index * step;
                float bottom = top - step * 0.85f;

                string status = "inactif";
                string color = "0.62 0.60 0.56 1";
                if (!string.IsNullOrEmpty(modes[index][2]) && statuses.ContainsKey(modes[index][2]))
                {
                    string raw = statuses[modes[index][2]];
                    if (StatusIsRunning(raw)) { status = "PARTIE EN COURS"; color = "0.62 0.83 0.44 1"; }
                    string players = ExtractField(raw, "joueurs");
                    if (!string.IsNullOrEmpty(players) && players != "0") status += $" - {players} joueur(s)";
                }
                else
                {
                    int queued = _queues.ContainsKey(modes[index][0]) ? _queues[modes[index][0]].Count : 0;
                    if (_matchActive && _activeMode == modes[index][0]) { status = "PARTIE EN COURS"; color = "0.62 0.83 0.44 1"; }
                    else if (queued > 0) { status = $"{queued} en file"; color = "1 0.85 0.47 1"; }
                }

                container.Add(new CuiLabel
                {
                    Text = { Text = modes[index][1], FontSize = 14, Align = TextAnchor.MiddleLeft, Color = "0.93 0.89 0.83 1" },
                    RectTransform = { AnchorMin = Anchor(0.03f, bottom), AnchorMax = Anchor(0.45f, top) }
                }, panel);

                container.Add(new CuiLabel
                {
                    Text = { Text = status, FontSize = 12, Align = TextAnchor.MiddleLeft, Color = color },
                    RectTransform = { AnchorMin = Anchor(0.45f, bottom), AnchorMax = Anchor(0.80f, top) }
                }, panel);

                AddMenuButton(container, panel, 0.82f, 0.97f, bottom, top, "REJOINDRE", "hub.menu.join " + modes[index][0], "0.83 0.29 0.18 1");
            }
        }

        private void DrawTeleportPage(CuiElementContainer container, string panel, BasePlayer player)
        {
            string[][] destinations =
            {
                new[] { "lobby", "LOBBY CENTRAL", "Le hub avec les portails vers tous les modes." },
                new[] { "retour", "MA POSITION", "Retour la ou tu etais avant d'entrer au lobby." },
                new[] { "training", "STAND DE TIR", "Cibles mobiles pour travailler le tracking." },
                new[] { "sparring", "FOSSE DE SPARRING", "Combat a l'arme blanche, sans classement." }
            };

            for (int index = 0; index < destinations.Length; index++)
            {
                float top = 0.78f - index * 0.15f;
                float bottom = top - 0.12f;

                container.Add(new CuiLabel
                {
                    Text = { Text = destinations[index][1], FontSize = 15, Align = TextAnchor.LowerLeft, Color = "0.93 0.89 0.83 1" },
                    RectTransform = { AnchorMin = Anchor(0.03f, bottom + 0.06f), AnchorMax = Anchor(0.80f, top) }
                }, panel);

                container.Add(new CuiLabel
                {
                    Text = { Text = destinations[index][2], FontSize = 11, Align = TextAnchor.UpperLeft, Color = "0.62 0.60 0.56 1" },
                    RectTransform = { AnchorMin = Anchor(0.03f, bottom), AnchorMax = Anchor(0.80f, bottom + 0.06f) }
                }, panel);

                AddMenuButton(container, panel, 0.82f, 0.97f, bottom + 0.02f, top - 0.02f, "ALLER", "hub.menu.tp " + destinations[index][0], "0.78 0.51 0.20 1");
            }
        }

        private void DrawStatsPage(CuiElementContainer container, string panel, BasePlayer player)
        {
            string[][] sources =
            {
                new[] { "GetRpgPlayerStats", "PROGRESSION" },
                new[] { "GetDuelPlayerStats", "DUEL" },
                new[] { "GetGunGamePlayerStats", "GUN GAME" },
                new[] { "GetTowerDefensePlayerStats", "TOWER DEFENSE" },
                new[] { "GetTrainingPlayerStats", "ENTRAINEMENT" }
            };

            float cursor = 0.80f;
            foreach (string[] source in sources)
            {
                object raw = Interface.CallHook(source[0], player);
                container.Add(new CuiLabel
                {
                    Text = { Text = source[1], FontSize = 13, Align = TextAnchor.MiddleLeft, Color = "0.83 0.29 0.18 1" },
                    RectTransform = { AnchorMin = Anchor(0.03f, cursor - 0.045f), AnchorMax = Anchor(0.97f, cursor) }
                }, panel);
                cursor -= 0.05f;

                string text = raw == null ? "indisponible" : FormatStatLine(raw.ToString());
                container.Add(new CuiLabel
                {
                    Text = { Text = text, FontSize = 11, Align = TextAnchor.UpperLeft, Color = "0.85 0.82 0.76 1" },
                    RectTransform = { AnchorMin = Anchor(0.05f, cursor - 0.09f), AnchorMax = Anchor(0.97f, cursor) }
                }, panel);
                cursor -= 0.105f;
            }
        }

        private string FormatStatLine(string raw)
        {
            List<string> parts = new List<string>();
            foreach (Match match in Regex.Matches(raw, @"(\w+)=(\S+)"))
            {
                parts.Add(match.Groups[1].Value.Replace('_', ' ') + " : " + match.Groups[2].Value);
            }
            return parts.Count == 0 ? raw : string.Join("     ", parts.ToArray());
        }

        private void DrawOptionsPage(CuiElementContainer container, string panel, BasePlayer player)
        {
            object kitIds = Interface.CallHook("GetDuelKitIds");
            string[] kits = kitIds == null ? new string[0] : kitIds.ToString().Split(',');

            container.Add(new CuiLabel
            {
                Text = { Text = "KIT DE DUEL", FontSize = 13, Align = TextAnchor.MiddleLeft, Color = "0.83 0.29 0.18 1" },
                RectTransform = { AnchorMin = Anchor(0.03f, 0.76f), AnchorMax = Anchor(0.97f, 0.81f) }
            }, panel);

            for (int index = 0; index < kits.Length; index++)
            {
                float min = 0.03f + index % 4 * 0.24f;
                float top = 0.73f - index / 4 * 0.07f;
                AddMenuButton(container, panel, min, min + 0.22f, top - 0.055f, top, kits[index].ToUpperInvariant(),
                    "hub.menu.option duel kit " + kits[index], "0.22 0.20 0.17 1");
            }

            string[][] groups =
            {
                new[] { "difficulte", "DIFFICULTE ENTRAINEMENT", "facile,normal,difficile,extreme" },
                new[] { "motif", "MOTIF DES CIBLES", "lateral,zigzag,cercle,aleatoire" },
                new[] { "arme", "ARME D'ENTRAINEMENT", "sar,smg,ak,lr300" },
                new[] { "duree", "DUREE DU RUN", "30,60,120" }
            };

            float cursor = 0.55f;
            foreach (string[] group in groups)
            {
                container.Add(new CuiLabel
                {
                    Text = { Text = group[1], FontSize = 13, Align = TextAnchor.MiddleLeft, Color = "0.83 0.29 0.18 1" },
                    RectTransform = { AnchorMin = Anchor(0.03f, cursor), AnchorMax = Anchor(0.97f, cursor + 0.05f) }
                }, panel);

                string[] values = group[2].Split(',');
                for (int index = 0; index < values.Length; index++)
                {
                    float min = 0.03f + index * 0.24f;
                    AddMenuButton(container, panel, min, min + 0.22f, cursor - 0.06f, cursor - 0.005f, values[index].ToUpperInvariant(),
                        $"hub.menu.option training {group[0]} {values[index]}", "0.22 0.20 0.17 1");
                }
                cursor -= 0.125f;
            }
        }

        private void AddMenuButton(CuiElementContainer container, string parent, float minX, float maxX, float minY, float maxY, string label, string command, string color)
        {
            container.Add(new CuiButton
            {
                Button = { Command = command, Color = color },
                Text = { Text = label, FontSize = 11, Align = TextAnchor.MiddleCenter, Color = "1 0.97 0.93 1" },
                RectTransform = { AnchorMin = Anchor(minX, minY), AnchorMax = Anchor(maxX, maxY) }
            }, parent);
        }

        /// <summary>
        /// Les ancres CUI sont des chaines : une locale francaise ecrirait "0,44"
        /// et casserait silencieusement toute la mise en page.
        /// </summary>
        private string Anchor(float x, float y)
        {
            return x.ToString(CultureInfo.InvariantCulture) + " " + y.ToString(CultureInfo.InvariantCulture);
        }

        /// <summary>
        /// Les statuts viennent des memes hooks que dashboard.modes, appeles dans
        /// le meme processus : le menu ne coute aucune requete RCON.
        /// </summary>
        private Dictionary<string, string> CollectModeStatuses()
        {
            Dictionary<string, string> statuses = new Dictionary<string, string>();
            string[][] sources =
            {
                new[] { "GetDuelDashboardStatus", "Duel" },
                new[] { "GetZombieDashboardStatus", "Zombie" },
                new[] { "GetGunGameDashboardStatus", "Gun Game" },
                new[] { "GetTowerDefenseDashboardStatus", "Tower Defense" },
                new[] { "GetTrainingDashboardStatus", "Entrainement" },
                new[] { "GetBattlefieldDashboardStatus", "Battlefield" }
            };
            foreach (string[] source in sources)
            {
                object raw = Interface.CallHook(source[0]);
                if (raw != null) statuses[source[1]] = raw.ToString();
            }
            return statuses;
        }

        private string ExtractField(string status, string key)
        {
            if (string.IsNullOrEmpty(status)) return string.Empty;
            Match match = Regex.Match(status, Regex.Escape(key) + @"=(\S+)");
            return match.Success ? match.Groups[1].Value : string.Empty;
        }

        private bool IsOtherGameParticipant(BasePlayer player)
        {
            foreach (string hookName in new[] { "IsGunGameParticipant", "IsZombieParticipant", "IsDuelParticipant", "IsTowerDefenseParticipant", "IsTrainingParticipant", "IsBattlefieldParticipant" })
            {
                object hook = Interface.CallHook(hookName, player);
                if (hook is bool && (bool)hook) return true;
            }
            return false;
        }

        private bool IsInAnyGame(BasePlayer player)
        {
            return IsOtherGameParticipant(player) || _participants.Contains(player.userID) || _queues.Values.Any(queue => queue.Contains(player.userID));
        }

        private void ReturnParticipant(BasePlayer player)
        {
            if (player == null || !player.IsConnected) return;
            Vector3 position;
            if (!_returnPositions.TryGetValue(player.userID, out position)) return;
            if (player.IsDead()) player.RespawnAt(position, Quaternion.identity); else player.Teleport(position);
        }
    }
}
