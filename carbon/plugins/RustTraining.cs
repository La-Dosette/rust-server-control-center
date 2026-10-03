using System;
using System.Collections.Generic;
using System.Globalization;
using System.Linq;
using Oxide.Core;
using Oxide.Game.Rust.Cui;
using UnityEngine;

namespace Oxide.Plugins
{
    [Info("RustTraining", "OpenAI", "2.0.0")]
    [Description("Entrainement : cibles mobiles pour travailler le tracking, arene temporaire et records personnels.")]
    public class RustTraining : RustPlugin
    {
        private const string ItemPrefix = "Entrainement - ";
        private const string TargetPrefab = "assets/prefabs/npc/scarecrow/scarecrow.prefab";
        private const string WallPrefab = "assets/prefabs/building/wall.external.high.stone/wall.external.high.stone.prefab";
        private const string ConcretePrefab = "assets/prefabs/deployable/barricades/barricade.concrete.prefab";
        private const string SandbagPrefab = "assets/prefabs/deployable/barricades/barricade.sandbags.prefab";
        private const string RugPrefab = "assets/prefabs/deployable/rug/rug.deployed.prefab";
        private const string HudPanel = "rusttraining.hud";

        // Tower Defense fait avancer ses ennemis a 0.15s, ce qui suffit pour des
        // zombies qui marchent. Pour du tracking c'est trop grossier : a 3.5 m/s
        // la cible saute de 52 cm et on travaille la prediction, pas le suivi.
        // A 20 Hz le pas retombe a 17 cm. training.validate mesure ce pas reel.
        private const float TargetTickSeconds = 0.05f;

        private const float ArenaRadius = 46f;
        private const int LaneCount = 4;
        private const float LaneWidth = 14f;
        private const float FiringLineZ = 2f;
        private const float RailZ = 26f;
        private const float RailHalfLength = 7f;
        private const float TargetHealth = 100000f;
        private const int TargetsPerLane = 3;
        private const float SparPitZ = -26f;
        private const float SparPitRadius = 11f;
        private const float SparHealthFloor = 5f;
        private const string SparWeapon = "machete";

        private readonly Dictionary<ulong, TrainingSession> _sessions = new Dictionary<ulong, TrainingSession>();
        private readonly Dictionary<BasePlayer, TargetState> _targets = new Dictionary<BasePlayer, TargetState>();
        private readonly List<BaseEntity> _arenaEntities = new List<BaseEntity>();
        private readonly bool[] _laneTaken = new bool[LaneCount];
        private readonly HashSet<ulong> _hudShown = new HashSet<ulong>();

        private StoredData _data;
        private Vector3 _arenaCenter;
        private bool _running;
        private int _sessionId;

        /// <summary>
        /// Etat par joueur. Les autres modes sont mono-instance avec un simple
        /// HashSet de participants ; ici quatre personnes peuvent travailler sur
        /// quatre series de cibles independantes, chacune dans son couloir.
        /// </summary>
        private class TrainingSession
        {
            public int Lane = -1;
            public string Zone = "aim";
            public int PointsSparring;
            public string Difficulte = "normal";
            public string Motif = "lateral";
            public string Arme = "sar";
            public int Duree = 60;
            public bool RunActive;
            public float RunEndsAt;
            public int Tirs;
            public int Touches;
            public int Headshots;
            public Vector3 Retour;
        }

        private class TargetState
        {
            public ulong Owner;
            public int Lane;
            public string Motif;
            public float Vitesse;
            public float Direction = 1f;
            public Vector3 RailA;
            public Vector3 RailB;
            public Vector3 Pivot;
            public float Phase;
            public float ProchainDemiTour;
            public float MaxStep;
            public float Parcouru;
            public Vector3 Depart;
        }

        private class StoredData
        {
            // Cles composites plates : la serialisation d'un dictionnaire imbrique
            // n'est pas testable hors ligne, autant ne pas prendre le risque.
            public Dictionary<string, int> MeilleursScores = new Dictionary<string, int>();
            public Dictionary<string, int> MeilleuresPrecisions = new Dictionary<string, int>();
            public Dictionary<ulong, string> Preferences = new Dictionary<ulong, string>();
            public Dictionary<ulong, string> Noms = new Dictionary<ulong, string>();
        }

        private static readonly string[] MotifIds = { "lateral", "zigzag", "cercle", "aleatoire" };
        private static readonly int[] DureeIds = { 30, 60, 120 };

        private static readonly Dictionary<string, float> DifficultySpeeds = new Dictionary<string, float>
        {
            ["facile"] = 2.0f,
            ["normal"] = 3.5f,
            ["difficile"] = 5.0f,
            ["extreme"] = 6.5f
        };

        // Seules des armes a projectile unique : un fusil a pompe envoie plusieurs
        // plombs par OnWeaponFired et rendrait la precision ininterpretable.
        // Uniquement des armes a projectile unique. Un fusil a pompe tire
        // plusieurs plombs par OnWeaponFired : la precision affichee n'aurait
        // plus aucun sens. C'est une contrainte de mesure, pas un oubli.
        private static readonly Dictionary<string, string> TrainingWeapons = new Dictionary<string, string>
        {
            ["sar"] = "rifle.semiauto",
            ["smg"] = "smg.thompson",
            ["mp5"] = "smg.mp5",
            ["custom"] = "smg.2",
            ["ak"] = "rifle.ak",
            ["lr300"] = "rifle.lr300",
            ["m39"] = "rifle.m39",
            ["sks"] = "rifle.sks",
            ["bolt"] = "rifle.bolt",
            ["l96"] = "rifle.l96",
            ["m249"] = "lmg.m249",
            ["hmlmg"] = "hmlmg",
            ["python"] = "pistol.python",
            ["revolver"] = "pistol.revolver",
            ["m92"] = "pistol.m92",
            ["p2"] = "pistol.semiauto",
            ["proto"] = "pistol.prototype17"
        };

        private static readonly Dictionary<string, string> TrainingAmmo = new Dictionary<string, string>
        {
            ["sar"] = "ammo.rifle",
            ["smg"] = "ammo.pistol",
            ["mp5"] = "ammo.pistol",
            ["custom"] = "ammo.pistol",
            ["ak"] = "ammo.rifle",
            ["lr300"] = "ammo.rifle",
            ["m39"] = "ammo.rifle",
            ["sks"] = "ammo.rifle",
            ["bolt"] = "ammo.rifle",
            ["l96"] = "ammo.rifle",
            ["m249"] = "ammo.rifle",
            ["hmlmg"] = "ammo.rifle",
            ["python"] = "ammo.pistol",
            ["revolver"] = "ammo.pistol",
            ["m92"] = "ammo.pistol",
            ["p2"] = "ammo.pistol",
            ["proto"] = "ammo.pistol"
        };

        // ----- Cycle de vie --------------------------------------------------

        private void Init()
        {
            LoadData();
        }

        private void OnServerSave()
        {
            SaveData();
        }

        private void LoadData()
        {
            try
            {
                _data = Interface.Oxide.DataFileSystem.ReadObject<StoredData>(Name);
            }
            catch
            {
                _data = null;
            }
            if (_data == null) _data = new StoredData();
            if (_data.MeilleursScores == null) _data.MeilleursScores = new Dictionary<string, int>();
            if (_data.MeilleuresPrecisions == null) _data.MeilleuresPrecisions = new Dictionary<string, int>();
            if (_data.Preferences == null) _data.Preferences = new Dictionary<ulong, string>();
            if (_data.Noms == null) _data.Noms = new Dictionary<ulong, string>();
        }

        private void SaveData()
        {
            Interface.Oxide.DataFileSystem.WriteObject(Name, _data);
        }

        private string RecordKey(ulong userId, TrainingSession session)
        {
            return $"{userId}:{session.Difficulte}:{session.Motif}:{session.Duree}";
        }

        private void LoadPreferences(ulong userId, TrainingSession session)
        {
            string raw;
            if (!_data.Preferences.TryGetValue(userId, out raw) || string.IsNullOrEmpty(raw)) return;
            string[] parts = raw.Split('|');
            if (parts.Length < 4) return;
            if (DifficultySpeeds.ContainsKey(parts[0])) session.Difficulte = parts[0];
            if (MotifIds.Contains(parts[1])) session.Motif = parts[1];
            if (TrainingWeapons.ContainsKey(parts[2])) session.Arme = parts[2];
            int duree;
            if (int.TryParse(parts[3], out duree) && DureeIds.Contains(duree)) session.Duree = duree;
        }

        private void SavePreferences(BasePlayer player, TrainingSession session)
        {
            _data.Preferences[player.userID] = $"{session.Difficulte}|{session.Motif}|{session.Arme}|{session.Duree}";
            _data.Noms[player.userID] = player.displayName;
            SaveData();
        }

        private void OnServerInitialized()
        {
            List<string> missing = new List<string>();
            foreach (KeyValuePair<string, string> weapon in TrainingWeapons)
            {
                if (ItemManager.FindItemDefinition(weapon.Value) == null) missing.Add(weapon.Value);
            }
            if (missing.Count > 0) PrintWarning("Armes d'entrainement introuvables : " + string.Join(", ", missing.ToArray()));

            ValidateKitShortnames();
            timer.Every(TargetTickSeconds, TickTargets);
            // Entretien du tireur : munitions, chargeur, usure et metabolisme.
            // Sans lui, "munitions illimitees" designait 128 cartouches.
            timer.Every(2f, TickSustain);
            Puts($"Entrainement pret : cibles mobiles, {LaneCount} couloirs, tick {TargetTickSeconds}s.");
        }

        private void Unload()
        {
            StopTraining(null, true);
            DestroyAllHuds();
            SaveData();
        }

        // ----- Hooks exposes aux autres plugins -------------------------------

        private object IsTrainingParticipant(BasePlayer player)
        {
            return player != null && _sessions.ContainsKey(player.userID);
        }

        /// <summary>
        /// Garde consommee par RustRPG.OnEntityDeath : sans elle, une cible tuee
        /// donnerait 55 XP et 35 pieces comme n'importe quel PNJ, ce qui ferait
        /// du stand de tir une ferme a experience.
        /// </summary>
        private object IsTrainingTarget(BasePlayer npc)
        {
            return npc != null && _targets.ContainsKey(npc);
        }

        /// <summary>
        /// Sortie de secours administrateur pour UN joueur. Un seul CallHook
        /// atteint tous les plugins : chacun ne libere que ses propres joueurs,
        /// sans jamais interrompre la partie des autres.
        /// </summary>
        private object ForceLeaveMode(BasePlayer player)
        {
            if (player == null || !_sessions.ContainsKey(player.userID)) return null;
            LeaveTraining(player, true);
            return true;
        }

        private object JoinTrainingFromLobby(BasePlayer player, string zone)
        {
            if (player == null) return false;
            JoinTraining(player, zone == "spar" ? "spar" : "aim");
            return true;
        }

        private object GetTrainingDashboardStatus()
        {
            CleanupTargets();
            int enCours = _sessions.Values.Count(session => session.RunActive);
            int sparring = _sessions.Values.Count(session => session.Zone == "spar");
            // "actif=True" est lu par RustGameHub.StatusIsRunning : c'est ce qui
            // alimente le drapeau running du dashboard et le garde-fou du Control Center.
            return $"actif={_running} joueurs={_sessions.Count} runs={enCours} sparring={sparring} cibles={_targets.Count} couloirs={_laneTaken.Count(taken => taken)}/{LaneCount} elementsArene={_arenaEntities.Count}";
        }

        // ----- Hooks Oxide -----------------------------------------------------

        private object OnEntityTakeDamage(BaseCombatEntity entity, HitInfo info)
        {
            if (!_running || entity == null || info == null) return null;

            BasePlayer victim = entity as BasePlayer;
            BasePlayer attacker = info.InitiatorPlayer;
            if (victim == null) return null;

            TargetState targetState;
            bool victimIsTarget = _targets.TryGetValue(victim, out targetState);
            bool attackerIsTarget = attacker != null && _targets.ContainsKey(attacker);
            bool victimTrains = _sessions.ContainsKey(victim.userID);
            bool attackerTrains = attacker != null && _sessions.ContainsKey(attacker.userID);

            // Une cible ne blesse jamais personne.
            if (attackerIsTarget)
            {
                info.damageTypes.ScaleAll(0f);
                return true;
            }

            if (victimIsTarget)
            {
                if (attackerTrains && targetState.Owner == attacker.userID) RegisterHit(attacker, info);
                // On laisse passer un millieme de degat plutot que zero : le client
                // garde ainsi son marqueur de touche et le sang, seul retour visuel
                // qui fasse d'un stand de tir un vrai stand de tir. Avec 100000 PV
                // la cible ne meurt jamais, donc aucune recompense n'est declenchee.
                info.damageTypes.ScaleAll(0.001f);
                return null;
            }

            // Duel de sparring : on plafonne les degats pour qu'aucun coup ne tue.
            if (attackerTrains && victimTrains)
            {
                TrainingSession attackerSession = _sessions[attacker.userID];
                TrainingSession victimSession = _sessions[victim.userID];
                if (attackerSession.Zone == "spar" && victimSession.Zone == "spar")
                {
                    if (info.damageTypes.Total() >= victim.health - SparHealthFloor)
                    {
                        info.damageTypes.ScaleAll(0f);
                        ScoreSparringHit(attacker, victim);
                        return true;
                    }
                    return null;
                }
            }

            // Un joueur en entrainement est isole du reste du monde, dans les deux sens.
            if (victimTrains || attackerTrains)
            {
                info.damageTypes.ScaleAll(0f);
                return true;
            }

            return null;
        }

        private void OnWeaponFired(BaseProjectile projectile, BasePlayer player, ItemModProjectile mod, ProtoBuf.ProjectileShoot projectiles)
        {
            if (projectile == null || player == null) return;
            TrainingSession session;
            if (!_sessions.TryGetValue(player.userID, out session)) return;
            if (!IsUsingTrainingWeapon(player)) return;

            if (session.RunActive) session.Tirs++;

            timer.Once(0.01f, () =>
            {
                if (projectile == null || projectile.IsDestroyed || projectile.primaryMagazine == null) return;
                projectile.primaryMagazine.contents = projectile.primaryMagazine.capacity;
                projectile.SendNetworkUpdateImmediate();
            });
        }

        private void OnPlayerDisconnected(BasePlayer player, string reason)
        {
            if (player == null || !_sessions.ContainsKey(player.userID)) return;
            // Les objets doivent partir avant que Rust ne sauvegarde l'inventaire,
            // sinon le joueur conserve son arme d'entrainement a la reconnexion.
            LeaveTraining(player, false);
        }

        private void RegisterHit(BasePlayer player, HitInfo info)
        {
            TrainingSession session;
            if (!_sessions.TryGetValue(player.userID, out session) || !session.RunActive) return;
            session.Touches++;
            if (info.isHeadshot) session.Headshots++;
        }

        // ----- Commandes joueur ------------------------------------------------

        [ChatCommand("entrainement")]
        private void CommandTraining(BasePlayer player, string command, string[] args)
        {
            string action = args != null && args.Length > 0 ? args[0].ToLowerInvariant() : "status";

            if (action == "viser" || action == "aim")
            {
                JoinTraining(player, "aim");
                return;
            }
            if (action == "melee" || action == "sparring" || action == "spar")
            {
                JoinTraining(player, "spar");
                return;
            }
            if (action == "quitter" || action == "leave")
            {
                if (!_sessions.ContainsKey(player.userID)) { SendReply(player, "Tu n'es pas a l'entrainement."); return; }
                LeaveTraining(player, true);
                return;
            }
            if (action == "start")
            {
                StartRun(player);
                return;
            }
            if (action == "stop")
            {
                StopRun(player, "Run interrompu.");
                return;
            }
            if (action == "difficulte" || action == "motif" || action == "arme" || action == "duree")
            {
                SetTrainingOption(player, action, args.Length > 1 ? args[1].ToLowerInvariant() : string.Empty);
                return;
            }

            ShowTrainingStatus(player);
        }

        [ChatCommand("train")]
        private void CommandTrainAlias(BasePlayer player, string command, string[] args)
        {
            CommandTraining(player, command, args);
        }

        [ChatCommand("aimtop")]
        private void CommandAimTop(BasePlayer player, string command, string[] args)
        {
            if (_data.MeilleursScores.Count == 0)
            {
                SendReply(player, "Aucun record enregistre pour l'instant. Tape /entrainement viser.");
                return;
            }

            SendReply(player, "<color=#ffd479>MEILLEURS SCORES ENTRAINEMENT</color>");
            int rank = 0;
            foreach (KeyValuePair<string, int> entry in _data.MeilleursScores.OrderByDescending(pair => pair.Value).Take(10))
            {
                rank++;
                string[] parts = entry.Key.Split(':');
                ulong userId;
                string who = "?";
                if (parts.Length > 0 && ulong.TryParse(parts[0], out userId))
                {
                    string stored;
                    who = _data.Noms.TryGetValue(userId, out stored) ? stored : parts[0];
                }
                string reglage = parts.Length >= 4 ? $"{parts[1]}/{parts[2]}/{parts[3]}s" : "?";
                SendReply(player, $"{rank}. {who} - <color=#9fd36f>{entry.Value}</color> pts ({reglage})");
            }
        }

        /// <summary>
        /// Applique un reglage et relance les cibles du couloir : changer de motif
        /// ou de difficulte sans respawn laisserait des cibles a l'ancien reglage.
        /// </summary>
        private bool SetTrainingOption(BasePlayer player, string option, string value)
        {
            TrainingSession session;
            if (!_sessions.TryGetValue(player.userID, out session))
            {
                SendReply(player, "Rejoins d'abord le stand avec /entrainement viser.");
                return false;
            }
            if (session.RunActive)
            {
                SendReply(player, "Termine ton run avant de changer de reglage.");
                return false;
            }

            bool changedTargets = false;
            if (option == "difficulte")
            {
                if (!DifficultySpeeds.ContainsKey(value))
                {
                    SendReply(player, "Difficultes : " + string.Join(", ", DifficultySpeeds.Keys.ToArray()) + ".");
                    return false;
                }
                session.Difficulte = value;
                changedTargets = true;
            }
            else if (option == "motif")
            {
                if (!MotifIds.Contains(value))
                {
                    SendReply(player, "Motifs : " + string.Join(", ", MotifIds) + ".");
                    return false;
                }
                session.Motif = value;
                changedTargets = true;
            }
            else if (option == "arme")
            {
                if (!TrainingWeapons.ContainsKey(value))
                {
                    SendReply(player, "Armes : " + string.Join(", ", TrainingWeapons.Keys.ToArray()) + ".");
                    return false;
                }
                session.Arme = value;
                GiveTrainingKit(player, session);
            }
            else if (option == "duree")
            {
                int duree;
                if (!int.TryParse(value, out duree) || !DureeIds.Contains(duree))
                {
                    SendReply(player, "Durees : " + string.Join(", ", DureeIds.Select(d => d.ToString()).ToArray()) + " secondes.");
                    return false;
                }
                session.Duree = duree;
            }
            else return false;

            if (changedTargets)
            {
                RemoveLaneTargets(player.userID);
                SpawnLaneTargets(player.userID, session);
            }
            SavePreferences(player, session);
            SendReply(player, $"Reglage applique : difficulte {session.Difficulte}, motif {session.Motif}, arme {session.Arme}, duree {session.Duree}s.");
            return true;
        }

        private object SetTrainingOptionFromMenu(BasePlayer player, string option, string value)
        {
            return SetTrainingOption(player, option, value);
        }

        private object GetTrainingPlayerStats(BasePlayer player)
        {
            if (player == null) return null;
            int best = 0;
            int bestAccuracy = 0;
            string prefix = player.userID + ":";
            foreach (KeyValuePair<string, int> entry in _data.MeilleursScores)
            {
                if (entry.Key.StartsWith(prefix, StringComparison.Ordinal) && entry.Value > best) best = entry.Value;
            }
            foreach (KeyValuePair<string, int> entry in _data.MeilleuresPrecisions)
            {
                if (entry.Key.StartsWith(prefix, StringComparison.Ordinal) && entry.Value > bestAccuracy) bestAccuracy = entry.Value;
            }
            return $"meilleur_score={best} meilleure_precision={bestAccuracy}";
        }

        private void ShowTrainingStatus(BasePlayer player)
        {
            TrainingSession session;
            if (_sessions.TryGetValue(player.userID, out session))
            {
                SendReply(player, $"<color=#9fd36f>ENTRAINEMENT</color> - couloir {session.Lane + 1}, difficulte {session.Difficulte}, motif {session.Motif}.");
                SendReply(player, session.RunActive
                    ? $"Run en cours : {session.Touches}/{session.Tirs} touches ({Accuracy(session)}%), {session.Headshots} headshot(s)."
                    : "Tape <color=#ffd479>/entrainement start</color> pour lancer un run chronometre.");
                SendReply(player, $"Reglages : arme {session.Arme}, duree {session.Duree}s. Change avec /entrainement difficulte|motif|arme|duree <valeur>.");
                SendReply(player, "<color=#ffd479>/entrainement quitter</color> pour sortir et retrouver ta position. /aimtop pour le classement.");
                return;
            }

            SendReply(player, "<color=#9fd36f>ENTRAINEMENT</color> - stand de tir avec cibles mobiles pour travailler le tracking.");
            SendReply(player, "Tape <color=#ffd479>/entrainement viser</color> pour rejoindre le stand.");
        }

        // ----- Commandes console -----------------------------------------------

        [ConsoleCommand("training")]
        private void ConsoleTraining(ConsoleSystem.Arg arg)
        {
            BasePlayer player = arg.Player();
            if (player == null) { arg.ReplyWith("Cette commande doit etre utilisee par un joueur."); return; }
            CommandTraining(player, "entrainement", ConsoleArgs(arg));
        }

        [ConsoleCommand("training.force")]
        private void ConsoleForceTraining(ConsoleSystem.Arg arg)
        {
            if (!IsAdminCaller(arg)) return;
            string[] args = ConsoleArgs(arg);
            string selector = args.Length > 0 ? args[0] : string.Empty;
            BasePlayer target = BasePlayer.activePlayerList.FirstOrDefault(candidate =>
                string.IsNullOrEmpty(selector) ||
                candidate.UserIDString == selector ||
                candidate.displayName.IndexOf(selector, StringComparison.OrdinalIgnoreCase) >= 0);
            if (target == null) { arg.ReplyWith("Joueur connecte introuvable."); return; }

            string zone = args.Length > 1 && args[1].ToLowerInvariant().StartsWith("mel") ? "spar" : "aim";
            JoinTraining(target, zone);
            arg.ReplyWith($"{target.displayName} est envoye a l'entrainement ({(zone == "spar" ? "sparring melee" : "stand de tir")}).");
        }

        [ConsoleCommand("training.stop")]
        private void ConsoleStopTraining(ConsoleSystem.Arg arg)
        {
            if (!IsAdminCaller(arg)) return;
            StopTraining("Entrainement arrete par un administrateur.", true);
            arg.ReplyWith("Entrainement arrete.");
        }

        [ConsoleCommand("training.debug")]
        private void ConsoleTrainingDebug(ConsoleSystem.Arg arg)
        {
            if (!IsAdminCaller(arg)) return;
            CleanupTargets();
            arg.ReplyWith($"{GetTrainingDashboardStatus()} centre={_arenaCenter} tick={TargetTickSeconds}s session={_sessionId}");
        }

        /// <summary>
        /// Autotest calque sur td.validate. Le chiffre qui compte est le pas
        /// maximum par tick : a 20 Hz et 3.5 m/s il doit valoir environ 0.18 m.
        /// S'il approche 0.5 m, le timer n'a pas tenu la cadence et le tracking
        /// sera sacade — c'est le signal pour descendre a 0.033s.
        /// </summary>
        [ConsoleCommand("training.validate")]
        private void ConsoleValidateTraining(ConsoleSystem.Arg arg)
        {
            if (!IsAdminCaller(arg)) return;
            if (_running) { arg.ReplyWith("Arrete l'entrainement avant l'autotest."); return; }

            _running = true;
            _sessionId++;
            int session = _sessionId;
            BuildArena();

            float speed = DifficultySpeeds["normal"];
            for (int index = 0; index < 3; index++)
            {
                SpawnTarget(0UL, 0, "lateral", speed);
            }

            timer.Once(3f, () =>
            {
                if (!_running || session != _sessionId) return;
                foreach (KeyValuePair<BasePlayer, TargetState> pair in _targets.ToArray())
                {
                    if (!IsValid(pair.Key)) continue;
                    TargetState state = pair.Value;
                    float net = HorizontalDistance(state.Depart, pair.Key.transform.position);
                    Puts($"Autotest cible {state.Motif} : {state.Parcouru:0.0}m parcourus ({net:0.0}m net), pas max {state.MaxStep:0.000}m, attendu ~{speed * TargetTickSeconds:0.000}m.");
                }
            });

            timer.Once(6f, () =>
            {
                if (_running && session == _sessionId) StopTraining(null, false);
            });

            arg.ReplyWith($"Autotest entrainement actif 6 secondes : arene={_arenaEntities.Count} elements, cibles={_targets.Count}, tick={TargetTickSeconds}s. Resultats en console.");
        }

        private bool IsAdminCaller(ConsoleSystem.Arg arg)
        {
            BasePlayer caller = arg.Player();
            if (caller != null && !caller.IsAdmin)
            {
                arg.ReplyWith("Commande reservee aux administrateurs.");
                return false;
            }
            return true;
        }

        private string[] ConsoleArgs(ConsoleSystem.Arg arg)
        {
            // arg.Args est un StringView[] sur cette version : conversion explicite.
            return arg.Args != null ? arg.Args.Select(value => value.ToString()).ToArray() : new string[0];
        }

        // ----- Entree et sortie -------------------------------------------------

        private void JoinTraining(BasePlayer player, string zone = "aim")
        {
            if (player == null) return;
            if (_sessions.ContainsKey(player.userID)) { SendReply(player, "Tu es deja a l'entrainement. Tape /entrainement quitter d'abord."); return; }

            string blocker = DescribeModeConflict(player);
            if (blocker != null) { SendReply(player, blocker); return; }

            bool sparring = zone == "spar";
            int lane = -1;
            if (!sparring)
            {
                lane = FirstFreeLane();
                if (lane < 0) { SendReply(player, $"Les {LaneCount} couloirs sont occupes. Essaie la fosse avec /entrainement melee."); return; }
            }

            if (!_running)
            {
                _running = true;
                _sessionId++;
                BuildArena();
                Puts($"Arene d'entrainement creee en {_arenaCenter} avec {_arenaEntities.Count} elements.");
            }

            TrainingSession session = new TrainingSession
            {
                Lane = lane,
                Zone = sparring ? "spar" : "aim",
                Retour = player.transform.position
            };
            LoadPreferences(player.userID, session);
            _sessions[player.userID] = session;

            player.InitializeHealth(100f, 100f);
            if (sparring)
            {
                int index = _sessions.Values.Count(other => other.Zone == "spar") - 1;
                player.Teleport(SparSpawn(Mathf.Max(0, index), 4));
                GiveSparringKit(player);
                SendReply(player, "<color=#9fd36f>FOSSE DE SPARRING</color> - arme blanche, sans classement.");
                SendReply(player, "Personne ne meurt : un coup fatal est annule et compte un point. <color=#ffd479>/entrainement quitter</color> pour sortir.");
            }
            else
            {
                _laneTaken[lane] = true;
                player.Teleport(FiringPosition(lane));
                GiveTrainingKit(player, session);
                SpawnLaneTargets(player.userID, session);
                SendReply(player, $"<color=#9fd36f>ENTRAINEMENT</color> - couloir {lane + 1}, cibles a 24m, motif {session.Motif}.");
                SendReply(player, "<color=#ffd479>/entrainement start</color> pour un run chronometre, <color=#ffd479>/entrainement quitter</color> pour sortir.");
            }
            DrawHud(player, session);
        }

        private void GiveSparringKit(BasePlayer player)
        {
            RemoveTrainingItems(player);
            GiveTrackedItem(player, SparWeapon, 1, "Machette de sparring");
        }

        /// <summary>
        /// Personne ne meurt en sparring : le coup fatal est annule, il compte un
        /// point et remet les deux combattants d'aplomb. Evite les cadavres au
        /// milieu d'une arene temporaire, donc la perte du materiel personnel.
        /// </summary>
        private void ScoreSparringHit(BasePlayer attacker, BasePlayer victim)
        {
            TrainingSession attackerSession;
            TrainingSession victimSession;
            if (!_sessions.TryGetValue(attacker.userID, out attackerSession)) return;
            if (!_sessions.TryGetValue(victim.userID, out victimSession)) return;

            attackerSession.PointsSparring++;
            victim.InitializeHealth(100f, 100f);
            attacker.InitializeHealth(100f, 100f);

            int index = 0;
            foreach (KeyValuePair<ulong, TrainingSession> pair in _sessions)
            {
                if (pair.Value.Zone != "spar") continue;
                BasePlayer fighter = FindActivePlayer(pair.Key);
                if (fighter != null && fighter.IsConnected) fighter.Teleport(SparSpawn(index, 4));
                index++;
            }

            SendReply(attacker, $"<color=#9fd36f>Point !</color> Total : {attackerSession.PointsSparring}.");
            SendReply(victim, $"<color=#e76a4c>Touche.</color> {attacker.displayName} mene avec {attackerSession.PointsSparring} point(s).");
        }

        private object IsTrainingFight(BasePlayer attacker, BasePlayer victim)
        {
            if (attacker == null || victim == null || attacker == victim) return false;
            TrainingSession attackerSession;
            TrainingSession victimSession;
            if (!_sessions.TryGetValue(attacker.userID, out attackerSession)) return false;
            if (!_sessions.TryGetValue(victim.userID, out victimSession)) return false;
            return attackerSession.Zone == "spar" && victimSession.Zone == "spar";
        }

        private void LeaveTraining(BasePlayer player, bool teleportBack)
        {
            if (player == null) return;
            TrainingSession session;
            if (!_sessions.TryGetValue(player.userID, out session)) return;

            _sessions.Remove(player.userID);
            if (session.Lane >= 0 && session.Lane < LaneCount) _laneTaken[session.Lane] = false;
            RemoveLaneTargets(player.userID);
            RemoveTrainingItems(player);
            DestroyHud(player);

            if (teleportBack && player.IsConnected && !player.IsDead() && session.Retour != Vector3.zero)
            {
                player.Teleport(session.Retour);
                SendReply(player, "Tu as quitte l'entrainement et retrouve ta position precedente.");
            }

            if (_sessions.Count == 0) StopTraining(null, false);
        }

        private void StopTraining(string message, bool returnPlayers)
        {
            if (!_running && _arenaEntities.Count == 0 && _targets.Count == 0) return;

            _running = false;
            _sessionId++;

            foreach (ulong userId in _sessions.Keys.ToArray())
            {
                BasePlayer player = FindActivePlayer(userId);
                TrainingSession session = _sessions[userId];
                _sessions.Remove(userId);
                if (player == null) continue;
                RemoveTrainingItems(player);
                DestroyHud(player);
                if (!string.IsNullOrEmpty(message)) SendReply(player, message);
                if (returnPlayers && player.IsConnected && !player.IsDead() && session.Retour != Vector3.zero) player.Teleport(session.Retour);
            }

            RemoveAllTargets();
            RemoveArena();
            for (int lane = 0; lane < LaneCount; lane++) _laneTaken[lane] = false;
        }

        private int FirstFreeLane()
        {
            for (int lane = 0; lane < LaneCount; lane++)
            {
                if (!_laneTaken[lane]) return lane;
            }
            return -1;
        }

        // ----- Runs chronometres -------------------------------------------------

        private void StartRun(BasePlayer player)
        {
            TrainingSession session;
            if (!_sessions.TryGetValue(player.userID, out session)) { SendReply(player, "Rejoins d'abord le stand avec /entrainement viser."); return; }
            if (session.RunActive) { SendReply(player, "Un run est deja en cours."); return; }

            session.RunActive = true;
            session.Tirs = 0;
            session.Touches = 0;
            session.Headshots = 0;
            session.RunEndsAt = UnityEngine.Time.realtimeSinceStartup + session.Duree;

            SendReply(player, $"<color=#e76a4c>GO !</color> {session.Duree} secondes. Touche un maximum de cibles.");
        }

        private void StopRun(BasePlayer player, string reason)
        {
            TrainingSession session;
            if (!_sessions.TryGetValue(player.userID, out session) || !session.RunActive) { SendReply(player, "Aucun run en cours."); return; }
            FinishRun(player, session, reason);
        }

        private void FinishRun(BasePlayer player, TrainingSession session, string reason)
        {
            session.RunActive = false;
            int score = session.Touches + session.Headshots * 2;
            int accuracy = Accuracy(session);
            float perMinute = session.Duree > 0 ? session.Touches * 60f / session.Duree : 0f;

            if (player == null || !player.IsConnected) return;

            if (!string.IsNullOrEmpty(reason)) SendReply(player, reason);
            SendReply(player, $"<color=#ffd479>RESULTAT</color> - score {score}, {session.Touches}/{session.Tirs} touches ({accuracy}%), {session.Headshots} headshot(s), {perMinute:0.0} touches/min.");

            // Les records sont conserves pour /aimtop et le menu, mais ne donnent
            // ni XP ni pieces : des cibles invulnerables tirees en boucle seraient
            // une ferme, et l'entrainement se suffit a lui-meme.
            string key = RecordKey(player.userID, session);
            int previous;
            bool hasPrevious = _data.MeilleursScores.TryGetValue(key, out previous);
            if (!hasPrevious || score > previous)
            {
                _data.MeilleursScores[key] = score;
                SendReply(player, hasPrevious
                    ? $"<color=#9fd36f>RECORD BATTU !</color> Ancien score : {previous}."
                    : "<color=#9fd36f>Premier record enregistre sur ce reglage.</color>");
            }

            int previousAccuracy;
            if (!_data.MeilleuresPrecisions.TryGetValue(key, out previousAccuracy) || accuracy > previousAccuracy)
            {
                _data.MeilleuresPrecisions[key] = accuracy;
            }

            _data.Noms[player.userID] = player.displayName;
            SaveData();
        }

        private int Accuracy(TrainingSession session)
        {
            return session.Tirs > 0 ? Mathf.RoundToInt(session.Touches * 100f / session.Tirs) : 0;
        }

        // ----- Cibles ------------------------------------------------------------

        private void SpawnLaneTargets(ulong owner, TrainingSession session)
        {
            float speed = DifficultySpeeds.ContainsKey(session.Difficulte) ? DifficultySpeeds[session.Difficulte] : DifficultySpeeds["normal"];
            for (int index = 0; index < TargetsPerLane; index++)
            {
                SpawnTarget(owner, session.Lane, session.Motif, speed);
            }
        }

        private bool SpawnTarget(ulong owner, int lane, string motif, float baseSpeed)
        {
            Vector3 railA = RailPoint(lane, -RailHalfLength);
            Vector3 railB = RailPoint(lane, RailHalfLength);
            Vector3 spawn = Vector3.Lerp(railA, railB, UnityEngine.Random.value);

            BaseEntity created = GameManager.server.CreateEntity(TargetPrefab, spawn, Quaternion.identity, true);
            BasePlayer target = created as BasePlayer;
            if (target == null)
            {
                if (created != null) created.Kill();
                PrintWarning("Impossible de creer une cible d'entrainement.");
                return false;
            }

            target.enableSaving = false;
            target.displayName = "CIBLE";
            target.Spawn();
            target.InitializeHealth(TargetHealth, TargetHealth);

            // Meme desactivation que Tower Defense : sans NavAgent l'IA ne peut plus
            // reprendre la main sur la position qu'on impose a chaque tick.
            NPCPlayer npc = target as NPCPlayer;
            if (npc != null && npc.NavAgent != null) npc.NavAgent.enabled = false;

            _targets[target] = new TargetState
            {
                Owner = owner,
                Lane = lane,
                Motif = motif,
                Vitesse = baseSpeed * UnityEngine.Random.Range(0.85f, 1.15f),
                Direction = UnityEngine.Random.value < 0.5f ? -1f : 1f,
                RailA = railA,
                RailB = railB,
                Pivot = Vector3.Lerp(railA, railB, 0.5f),
                // Dephasage initial : sans lui les cibles d'un meme couloir
                // orbitent ou zigzaguent a l'unisson, ce qui est plus facile.
                Phase = UnityEngine.Random.Range(0f, 6f),
                ProchainDemiTour = UnityEngine.Random.Range(0.35f, 1.2f),
                Depart = spawn
            };
            return true;
        }

        private void TickTargets()
        {
            if (!_running || _targets.Count == 0) return;
            CleanupTargets();

            foreach (KeyValuePair<BasePlayer, TargetState> pair in _targets.ToArray())
            {
                BasePlayer target = pair.Key;
                TargetState state = pair.Value;
                if (!IsValid(target)) continue;

                Vector3 current = target.transform.position;
                Vector3 next = ComputeNextPosition(current, state);
                next = Ground(next) + Vector3.up * 0.15f;

                Vector3 delta = next - current;
                float step = new Vector3(delta.x, 0f, delta.z).magnitude;
                if (step > state.MaxStep) state.MaxStep = step;
                state.Parcouru += step;

                target.transform.position = next;
                if (step > 0.0001f) target.transform.rotation = Quaternion.LookRotation(new Vector3(delta.x, 0f, delta.z).normalized);
                target.SendNetworkUpdateImmediate();
            }

            TickRuns();
        }

        private Vector3 ComputeNextPosition(Vector3 current, TargetState state)
        {
            state.Phase += TargetTickSeconds;

            if (state.Motif == "cercle")
            {
                // Orbite autour du centre du rail : la vitesse apparente vue du pas
                // de tir varie en continu, sans jamais de demi-tour sec.
                float angularSpeed = state.Vitesse / RailHalfLength;
                float angle = state.Phase * angularSpeed * state.Direction;
                Vector3 orbit = new Vector3(Mathf.Cos(angle), 0f, Mathf.Sin(angle)) * RailHalfLength;
                return state.Pivot + orbit;
            }

            Vector3 axis = state.RailB - state.RailA;
            axis.y = 0f;
            float length = axis.magnitude;
            if (length < 0.01f) return current;
            axis /= length;

            // Position le long du rail, recalculee depuis la projection courante
            // pour que la composante de profondeur du zigzag ne la fausse pas.
            float travelled = Vector3.Dot(current - state.RailA, axis);
            float nextTravelled = travelled + state.Direction * state.Vitesse * TargetTickSeconds;

            if (state.Motif == "aleatoire" && state.Phase >= state.ProchainDemiTour)
            {
                // Demi-tours imprevisibles : punit les flicks engages a l'avance.
                state.Direction = -state.Direction;
                state.ProchainDemiTour = state.Phase + UnityEngine.Random.Range(0.35f, 1.2f);
            }

            if (nextTravelled <= 0f)
            {
                nextTravelled = 0f;
                state.Direction = 1f;
            }
            else if (nextTravelled >= length)
            {
                nextTravelled = length;
                state.Direction = -1f;
            }

            Vector3 next = state.RailA + axis * nextTravelled;

            if (state.Motif == "zigzag")
            {
                // Va-et-vient lateral plus une avance/recul, pour que la vitesse
                // angulaire cesse d'etre constante.
                Vector3 depth = Vector3.Cross(Vector3.up, axis).normalized;
                next += depth * Mathf.Sin(state.Phase * 2.3f) * 4f;
            }

            return next;
        }

        private void TickRuns()
        {
            if (_sessions.Count == 0) return;
            float now = UnityEngine.Time.realtimeSinceStartup;

            foreach (ulong userId in _sessions.Keys.ToArray())
            {
                TrainingSession session;
                if (!_sessions.TryGetValue(userId, out session)) continue;
                BasePlayer player = FindActivePlayer(userId);
                if (player == null || !player.IsConnected) continue;

                if (session.RunActive && now >= session.RunEndsAt) FinishRun(player, session, "Temps ecoule.");
                DrawHud(player, session);
            }
        }

        private void RemoveLaneTargets(ulong owner)
        {
            foreach (KeyValuePair<BasePlayer, TargetState> pair in _targets.ToArray())
            {
                if (pair.Value.Owner != owner) continue;
                _targets.Remove(pair.Key);
                if (IsValid(pair.Key)) pair.Key.Kill();
            }
        }

        private void RemoveAllTargets()
        {
            foreach (BasePlayer target in _targets.Keys.ToArray())
            {
                if (IsValid(target)) target.Kill();
            }
            _targets.Clear();
        }

        private void CleanupTargets()
        {
            foreach (BasePlayer target in _targets.Keys.ToArray())
            {
                if (!IsValid(target)) _targets.Remove(target);
            }
        }

        // ----- Arene ---------------------------------------------------------------

        private void BuildArena()
        {
            RemoveArena();
            _arenaCenter = FindArenaCenter();

            const int walls = 44;
            for (int index = 0; index < walls; index++)
            {
                float angle = index * Mathf.PI * 2f / walls;
                Vector3 offset = new Vector3(Mathf.Cos(angle), 0f, Mathf.Sin(angle)) * ArenaRadius;
                SpawnArenaEntity(WallPrefab, Ground(_arenaCenter + offset), Quaternion.Euler(0f, -angle * Mathf.Rad2Deg, 0f));
            }

            for (int lane = 0; lane < LaneCount; lane++)
            {
                Vector3 firing = FiringPosition(lane);
                SpawnArenaEntity(RugPrefab, Ground(firing), Quaternion.identity);
                SpawnArenaEntity(ConcretePrefab, Ground(firing + new Vector3(-2.5f, 0f, 1.5f)), Quaternion.identity);
                SpawnArenaEntity(ConcretePrefab, Ground(firing + new Vector3(2.5f, 0f, 1.5f)), Quaternion.identity);
            }

            // Fosse de sparring au sud, a l'oppose des pas de tir.
            Vector3 pit = _arenaCenter + new Vector3(0f, 0f, SparPitZ);
            const int pitWalls = 12;
            for (int index = 0; index < pitWalls; index++)
            {
                float angle = index * Mathf.PI * 2f / pitWalls;
                Vector3 offset = new Vector3(Mathf.Cos(angle), 0f, Mathf.Sin(angle)) * SparPitRadius;
                SpawnArenaEntity(SandbagPrefab, Ground(pit + offset), Quaternion.Euler(0f, -angle * Mathf.Rad2Deg, 0f));
            }
            SpawnArenaEntity(RugPrefab, Ground(pit), Quaternion.identity);
        }

        private Vector3 SparSpawn(int index, int total)
        {
            int slots = Mathf.Max(2, total);
            float angle = index * Mathf.PI * 2f / slots;
            Vector3 offset = new Vector3(Mathf.Cos(angle), 0f, Mathf.Sin(angle)) * (SparPitRadius - 3f);
            Vector3 pit = _arenaCenter + new Vector3(0f, 0f, SparPitZ) + offset;
            return Ground(pit) + Vector3.up * 0.5f;
        }

        private Vector3 FindArenaCenter()
        {
            float halfSize = TerrainMeta.Size.x * 0.5f;
            float limit = Mathf.Max(120f, halfSize * 0.75f);

            for (int attempt = 0; attempt < 140; attempt++)
            {
                Vector3 candidate = new Vector3(
                    UnityEngine.Random.Range(-limit, limit),
                    0f,
                    UnityEngine.Random.Range(-limit, limit));
                if (IsArenaCandidate(candidate)) return Ground(candidate);
            }

            Vector3[] fallbacks = { Vector3.zero, new Vector3(0f, 0f, 350f), new Vector3(350f, 0f, 0f), new Vector3(0f, 0f, -350f), new Vector3(-350f, 0f, 0f) };
            foreach (Vector3 candidate in fallbacks.OrderBy(value => UnityEngine.Random.value))
            {
                if (IsArenaCandidate(candidate)) return Ground(candidate);
            }
            return Vector3.zero;
        }

        private bool IsArenaCandidate(Vector3 candidate)
        {
            float terrain = TerrainMeta.HeightMap.GetHeight(candidate);
            float water = TerrainMeta.WaterMap.GetHeight(candidate);
            // 3m au-dessus de la mer, et non -1 : WaterMap ne couvre que les lacs
            // et rivieres, jamais l'ocean, donc elle ne rattrapait pas un terrain
            // immerge. Le seuil de -1 acceptait explicitement du sol sous l'eau.
            if (terrain < 3f || terrain <= water + 2f) return false;
            if (!IsFlatEnough(candidate)) return false;

            if (TerrainMeta.Path != null && TerrainMeta.Path.Monuments != null)
            {
                foreach (MonumentInfo monument in TerrainMeta.Path.Monuments)
                {
                    if (monument == null) continue;
                    Vector3 delta = monument.transform.position - candidate;
                    delta.y = 0f;
                    if (delta.sqrMagnitude < 140f * 140f) return false;
                }
            }
            return true;
        }

        private bool IsFlatEnough(Vector3 candidate)
        {
            float min = float.MaxValue;
            float max = float.MinValue;
            Vector3[] offsets =
            {
                Vector3.zero,
                new Vector3(38f, 0f, 0f), new Vector3(-38f, 0f, 0f),
                new Vector3(0f, 0f, 38f), new Vector3(0f, 0f, -38f),
                new Vector3(27f, 0f, 27f), new Vector3(-27f, 0f, 27f),
                new Vector3(27f, 0f, -27f), new Vector3(-27f, 0f, -27f)
            };
            foreach (Vector3 offset in offsets)
            {
                Vector3 point = candidate + offset;
                float height = TerrainMeta.HeightMap.GetHeight(point);
                float water = TerrainMeta.WaterMap.GetHeight(point);
                if (height <= water + 1f) return false;
                if (height < min) min = height;
                if (height > max) max = height;
            }
            return max - min <= 5f;
        }

        private void SpawnArenaEntity(string prefab, Vector3 position, Quaternion rotation)
        {
            BaseEntity entity = GameManager.server.CreateEntity(prefab, position, rotation, true);
            if (entity == null) return;
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
        }

        private float LaneOffsetX(int lane)
        {
            return (lane - (LaneCount - 1) * 0.5f) * LaneWidth;
        }

        private Vector3 FiringPosition(int lane)
        {
            Vector3 position = _arenaCenter + new Vector3(LaneOffsetX(lane), 0f, FiringLineZ);
            return Ground(position) + Vector3.up * 0.5f;
        }

        private Vector3 RailPoint(int lane, float offsetX)
        {
            Vector3 position = _arenaCenter + new Vector3(LaneOffsetX(lane) + offsetX, 0f, RailZ);
            return Ground(position) + Vector3.up * 0.15f;
        }

        // ----- Kit --------------------------------------------------------------------

        /// <summary>
        /// Maintient le tireur en conditions de laboratoire : munitions et
        /// chargeur pleins, arme jamais usee, vie et besoins figes. Un serveur
        /// d'aim train ne doit jamais interrompre une serie pour de la faim,
        /// une arme cassee ou une reserve vide.
        /// </summary>
        /// <summary>
        /// Verifie au chargement que chaque raccourci d'arme et de munition
        /// existe vraiment. Une faute de frappe se voyait sinon seulement au
        /// moment ou un joueur demandait l'arme, en pleine session.
        /// </summary>
        private void ValidateKitShortnames()
        {
            List<string> manquants = new List<string>();

            foreach (var pair in TrainingWeapons)
            {
                if (ItemManager.FindItemDefinition(pair.Value) == null)
                    manquants.Add(pair.Key + " -> " + pair.Value);
            }
            foreach (var pair in TrainingAmmo)
            {
                if (ItemManager.FindItemDefinition(pair.Value) == null)
                    manquants.Add(pair.Key + " (munition) -> " + pair.Value);
            }

            if (manquants.Count > 0)
            {
                PrintWarning("Entrainement : " + manquants.Count + " raccourci(s) introuvable(s) : " + string.Join(", ", manquants.ToArray()));
            }
            else
            {
                Puts($"Entrainement : {TrainingWeapons.Count} armes verifiees, toutes disponibles.");
            }
        }

        private void TickSustain()
        {
            if (_sessions.Count == 0) return;

            foreach (BasePlayer player in BasePlayer.activePlayerList)
            {
                if (player == null || !player.IsConnected || player.IsDead()) continue;
                TrainingSession session;
                if (!_sessions.TryGetValue(player.userID, out session)) continue;
                if (player.inventory == null) continue;

                SustainAmmo(player, session);
                SustainWeapon(player);
                SustainBody(player);
            }
        }

        private void SustainAmmo(BasePlayer player, TrainingSession session)
        {
            string ammoShortname = TrainingAmmo.ContainsKey(session.Arme) ? TrainingAmmo[session.Arme] : TrainingAmmo["sar"];

            int held = 0;
            Item stack = null;
            foreach (Item item in AllTrainingItems(player))
            {
                if (item.info != null && item.info.shortname == ammoShortname)
                {
                    held += item.amount;
                    if (stack == null) stack = item;
                }
            }

            const int floor = 64;
            const int target = 256;
            if (held >= floor) return;

            if (stack != null)
            {
                stack.amount = target;
                stack.MarkDirty();
            }
            else
            {
                GiveTrackedItem(player, ammoShortname, target, "Munitions illimitees");
            }
        }

        private void SustainWeapon(BasePlayer player)
        {
            Item active = player.GetActiveItem();
            if (active == null || string.IsNullOrEmpty(active.name)) return;
            if (!active.name.StartsWith(ItemPrefix, StringComparison.Ordinal)) return;

            if (active.hasCondition && active.condition < active.maxCondition)
            {
                active.condition = active.maxCondition;
                active.MarkDirty();
            }
        }

        private void SustainBody(BasePlayer player)
        {
            float max = player.MaxHealth();
            if (player.health < max) player.health = max;

            PlayerMetabolism m = player.metabolism;
            if (m == null) return;
            if (m.calories != null) m.calories.value = m.calories.max;
            if (m.hydration != null) m.hydration.value = m.hydration.max;
            if (m.bleeding != null && m.bleeding.value > 0f) m.bleeding.value = 0f;
            if (m.radiation_poison != null) m.radiation_poison.value = 0f;
            if (m.radiation_level != null) m.radiation_level.value = 0f;
            m.SendChangesToClient();
        }

        private List<Item> AllTrainingItems(BasePlayer player)
        {
            List<Item> found = new List<Item>();
            if (player == null || player.inventory == null) return found;

            ItemContainer[] containers = { player.inventory.containerMain, player.inventory.containerBelt };
            foreach (ItemContainer container in containers)
            {
                if (container == null || container.itemList == null) continue;
                foreach (Item item in container.itemList)
                {
                    if (item == null || string.IsNullOrEmpty(item.name)) continue;
                    if (item.name.StartsWith(ItemPrefix, StringComparison.Ordinal)) found.Add(item);
                }
            }
            return found;
        }

        private void GiveTrainingKit(BasePlayer player, TrainingSession session)
        {
            RemoveTrainingItems(player);
            string weapon = TrainingWeapons.ContainsKey(session.Arme) ? TrainingWeapons[session.Arme] : TrainingWeapons["sar"];
            string ammo = TrainingAmmo.ContainsKey(session.Arme) ? TrainingAmmo[session.Arme] : TrainingAmmo["sar"];
            GiveTrackedItem(player, weapon, 1, "Arme d'entrainement");
            GiveTrackedItem(player, ammo, 256, "Munitions illimitees");
            timer.Once(0.15f, () => FillTrainingMagazine(player));
        }

        private bool GiveTrackedItem(BasePlayer player, string shortname, int amount, string label)
        {
            if (player == null || player.inventory == null) return false;
            Item item = ItemManager.CreateByName(shortname, amount);
            if (item == null)
            {
                PrintWarning($"Objet d'entrainement introuvable : {shortname}");
                return false;
            }
            item.name = ItemPrefix + label;
            if (item.hasCondition) item.condition = item.maxCondition;

            // player.GiveItem laisserait tomber l'objet au sol si l'inventaire est
            // plein, hors de portee du nettoyage par prefixe.
            if (!player.inventory.GiveItem(item))
            {
                item.Remove();
                SendReply(player, "<color=#e76a4c>Inventaire plein</color> : libere de la place pour recevoir ton arme.");
                return false;
            }
            return true;
        }

        private void FillTrainingMagazine(BasePlayer player)
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

        private bool IsUsingTrainingWeapon(BasePlayer player)
        {
            Item active = player != null ? player.GetActiveItem() : null;
            return active != null && !string.IsNullOrEmpty(active.name) && active.name.StartsWith(ItemPrefix, StringComparison.Ordinal);
        }

        private void RemoveTrainingItems(BasePlayer player)
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

        // ----- HUD ----------------------------------------------------------------------

        private void DrawHud(BasePlayer player, TrainingSession session)
        {
            if (player == null || !player.IsConnected) return;
            CuiHelper.DestroyUi(player, HudPanel);

            CuiElementContainer container = new CuiElementContainer();
            string panel = container.Add(new CuiPanel
            {
                Image = { Color = "0.05 0.04 0.03 0.82" },
                RectTransform = { AnchorMin = "0.795 0.70", AnchorMax = "0.995 0.955" },
                CursorEnabled = false
            }, "Hud", HudPanel);

            container.Add(new CuiLabel
            {
                Text = { Text = "ENTRAINEMENT - TRACKING", FontSize = 12, Align = TextAnchor.MiddleCenter, Color = "0.90 0.35 0.22 1" },
                RectTransform = { AnchorMin = "0 0.84", AnchorMax = "1 1" }
            }, panel);

            string headline = session.RunActive
                ? $"{Mathf.Max(0, Mathf.CeilToInt(session.RunEndsAt - UnityEngine.Time.realtimeSinceStartup))}s"
                : "PRET";
            container.Add(new CuiLabel
            {
                Text = { Text = headline, FontSize = 20, Align = TextAnchor.MiddleCenter, Color = "1 0.85 0.47 1" },
                RectTransform = { AnchorMin = "0 0.60", AnchorMax = "1 0.86" }
            }, panel);

            if (session.Zone == "spar")
            {
                AddHudLine(container, panel, 0.44f, 0.60f, $"Points : {session.PointsSparring}", "0.62 0.83 0.44 1");
                AddHudLine(container, panel, 0.30f, 0.44f, "Arme blanche", "0.85 0.82 0.76 1");
                AddHudLine(container, panel, 0.16f, 0.30f, "Sans classement", "0.85 0.82 0.76 1");
                AddHudLine(container, panel, 0.01f, 0.16f, "/entrainement quitter", "0.68 0.65 0.60 1");
            }
            else
            {
                AddHudLine(container, panel, 0.44f, 0.60f, $"Touches : {session.Touches}/{session.Tirs}", "0.85 0.82 0.76 1");
                AddHudLine(container, panel, 0.30f, 0.44f, $"Precision : {Accuracy(session)}%", "0.62 0.83 0.44 1");
                AddHudLine(container, panel, 0.16f, 0.30f, $"Headshots : {session.Headshots}", "0.85 0.82 0.76 1");
                AddHudLine(container, panel, 0.01f, 0.16f, session.RunActive ? $"Couloir {session.Lane + 1} - {session.Difficulte}" : "/entrainement start", "0.68 0.65 0.60 1");
            }

            CuiHelper.AddUi(player, container);
            _hudShown.Add(player.userID);
        }

        private void AddHudLine(CuiElementContainer container, string parent, float min, float max, string text, string color)
        {
            container.Add(new CuiLabel
            {
                Text = { Text = text, FontSize = 11, Align = TextAnchor.MiddleCenter, Color = color },
                RectTransform =
                {
                    AnchorMin = $"0 {min.ToString(CultureInfo.InvariantCulture)}",
                    AnchorMax = $"1 {max.ToString(CultureInfo.InvariantCulture)}"
                }
            }, parent);
        }

        private void DestroyHud(BasePlayer player)
        {
            if (player == null) return;
            _hudShown.Remove(player.userID);
            if (!player.IsConnected) return;
            CuiHelper.DestroyUi(player, HudPanel);
        }

        private void DestroyAllHuds()
        {
            foreach (ulong userId in _hudShown.ToArray())
            {
                BasePlayer player = FindActivePlayer(userId);
                if (player != null && player.IsConnected) CuiHelper.DestroyUi(player, HudPanel);
            }
            _hudShown.Clear();
        }

        // ----- Helpers ----------------------------------------------------------------------

        private string DescribeModeConflict(BasePlayer player)
        {
            string[] hooks = { "IsGunGameParticipant", "IsZombieParticipant", "IsDuelParticipant", "IsCompetitiveModeParticipant", "IsTowerDefenseParticipant", "IsBattlefieldParticipant" };
            foreach (string hook in hooks)
            {
                object result = Interface.CallHook(hook, player);
                if (result is bool && (bool)result) return "Quitte d'abord ton mode en cours avant de t'entrainer.";
            }
            return null;
        }

        private BasePlayer FindActivePlayer(ulong userId)
        {
            return BasePlayer.activePlayerList.FirstOrDefault(candidate => candidate != null && candidate.userID == userId);
        }

        private bool IsValid(BaseEntity entity)
        {
            return entity != null && !entity.IsDestroyed;
        }

        private Vector3 Ground(Vector3 position)
        {
            position.y = TerrainMeta.HeightMap.GetHeight(position);
            return position;
        }

        private float HorizontalDistance(Vector3 first, Vector3 second)
        {
            first.y = 0f;
            second.y = 0f;
            return Vector3.Distance(first, second);
        }
    }
}
