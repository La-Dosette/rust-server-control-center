using System;
using System.Collections.Generic;
using System.Linq;
using Oxide.Core;
using Oxide.Game.Rust.Cui;
using UnityEngine;
using UnityEngine.AI;

namespace Oxide.Plugins
{
    [Info("RustRPG", "OpenAI", "4.1.0")]
    [Description("Progression PvE avec quetes, competences, economie et mode Zombie avance.")]
    public class RustRPG : RustPlugin
    {
        private const string AdminPermission = "rustrpg.admin";
        private const string ZombiePrefab = "assets/prefabs/npc/scarecrow/scarecrow.prefab";
        private const string ScientistPrefab = "assets/rust.ai/agents/npcplayer/humannpc/scientist/scientistnpc_full_any.prefab";
        private const string BossPrefab = "assets/rust.ai/agents/npcplayer/humannpc/scientist/scientistnpc_heavy.prefab";
        private const string ZombieItemPrefix = "Zombie Mode - ";
        private const string ZombieBuildPrefix = "Zombie Build - ";
        private const string ZombieHudPanel = "rustrpg.zombie.hud";

        private PluginConfig _config;
        private StoredData _storedData;
        private readonly HashSet<BasePlayer> _zombies = new HashSet<BasePlayer>();
        private readonly HashSet<BasePlayer> _scientists = new HashSet<BasePlayer>();
        private readonly HashSet<BasePlayer> _bosses = new HashSet<BasePlayer>();
        private readonly HashSet<ulong> _zombieModePlayers = new HashSet<ulong>();
        private readonly HashSet<BasePlayer> _waveEnemies = new HashSet<BasePlayer>();
        private readonly HashSet<BasePlayer> _waveBosses = new HashSet<BasePlayer>();
        private readonly Dictionary<BasePlayer, float> _waveDamageMultipliers = new Dictionary<BasePlayer, float>();
        private readonly Dictionary<ulong, Vector3> _zombieReturnPositions = new Dictionary<ulong, Vector3>();
        private readonly Dictionary<ulong, int> _zombieCredits = new Dictionary<ulong, int>();
        private readonly List<BaseEntity> _zombieDefenses = new List<BaseEntity>();
        private readonly HashSet<ulong> _zombieDowned = new HashSet<ulong>();
        private readonly Dictionary<ulong, float> _zombieDownedUntil = new Dictionary<ulong, float>();
        private readonly HashSet<ulong> _zombieHudShown = new HashSet<ulong>();
        private readonly HashSet<ulong> _zombiePendingReturns = new HashSet<ulong>();
        private Vector3 _zombieArenaCenter;
        private int _zombieWave;
        private int _zombieSessionId;
        private bool _zombieModeRunning;
        private bool _zombieWaveActive;
        private bool _zombieBuildPhase;
        private bool _zombieEndless;
        private float _zombieNextWaveAt;

        private class PluginConfig
        {
            public bool BloquerDegatsEntreJoueurs = true;
            public int ZombiesSimultanes = 6;
            public int ScientifiquesSimultanes = 3;
            public int BossSimultanes = 1;
            public float IntervalleApparitionSecondes = 90f;
            public float DistanceMinimale = 45f;
            public float DistanceMaximale = 85f;
            public int ZombieVaguesMaximum = 10;
            public int ZombiesBaseParVague = 4;
            public int ZombiesSupplementairesParVague = 2;
            public int ZombiesSupplementairesParJoueur = 2;
            public float PauseEntreVaguesSecondes = 25f;
            public float RayonApparitionZombie = 42f;
            public int CreditsZombie = 15;
            public int CreditsBoss = 150;
            public float RayonConstructionZombie = 38f;
            public int ZombieBudgetBase = 6;
            public int ZombieBudgetParVague = 4;
            public int ZombieBudgetParJoueur = 3;
            public int ZombiePlafondEnnemis = 34;
            public bool ZombieAfficherHud = true;
            public float ZombieSecondesAterre = 35f;
            public float ZombieVieApresReanimation = 45f;
            public float ZombieDegatsSubisAterre = 0.15f;
            public int ZombieEndlessBossTousLes = 5;
            public int ZombieEndlessPalierRecompense = 10;
            public float ZombieEndlessPauseMinimum = 14f;
            public int RecompenseEndlessPalierExperience = 400;
            public int RecompenseEndlessPalierPieces = 800;
            public int RecompenseZombieExperience = 30;
            public int RecompenseZombiePieces = 25;
            public int RecompenseBossExperience = 300;
            public int RecompenseBossPieces = 450;
            public int RecompenseVaguePieces = 75;
            public int RecompenseVictoireZombiePieces = 1500;
            public int RecompenseVictoireZombieExperience = 750;
            public int RecompenseDuelExperienceBase = 350;
            public int RecompenseDuelExperienceParTaille = 100;
            public int RecompenseDuelPiecesBase = 700;
            public int RecompenseDuelPiecesParTaille = 200;
            public int RecompenseTournoiExperience = 1500;
            public int RecompenseTournoiPieces = 3000;
            public int RecompenseModeExperience = 600;
            public int RecompenseModePieces = 1200;
            public int ObjectifQueteQuotidienne = 10;
            public int RecompenseQuetePieces = 300;
            public int RecompenseQueteExperience = 150;
            public Dictionary<string, ShopEntry> Boutique = new Dictionary<string, ShopEntry>
            {
                ["bois"] = new ShopEntry("Bois x1000", "wood", 1000, 50),
                ["pierre"] = new ShopEntry("Pierre x1000", "stones", 1000, 60),
                ["metal"] = new ShopEntry("Fragments de metal x500", "metal.fragments", 500, 100),
                ["soins"] = new ShopEntry("Seringues x3", "syringe.medical", 3, 100),
                ["munitions"] = new ShopEntry("Munitions 5.56 x64", "ammo.rifle", 64, 120),
                ["ak"] = new ShopEntry("Fusil AK", "rifle.ak", 1, 800)
            };
        }

        private class ShopEntry
        {
            public string Nom;
            public string Shortname;
            public int Quantite;
            public int Prix;

            public ShopEntry() { }

            public ShopEntry(string nom, string shortname, int quantite, int prix)
            {
                Nom = nom;
                Shortname = shortname;
                Quantite = quantite;
                Prix = prix;
            }
        }

        private class PlayerProgress
        {
            public int Niveau = 1;
            public int Experience;
            public int Pieces = 250;
            public int PointsCompetence;
            public int Vitalite;
            public int Puissance;
            public int Recolte;
            public string DateQuete = string.Empty;
            public int ProgressionQuete;
            public bool QueteReclamee;
            public int MeilleureVagueZombie;
            public int VictoiresZombie;
            public int MeilleureVagueZombieInfini;
            public int ReanimationsZombie;
        }

        /// <summary>
        /// Un type d'ennemi et son cout dans le budget de vague. Les vagues sont
        /// composees en depensant un budget croissant plutot qu'en attribuant les
        /// roles par index (i % 5), ce qui rendait la composition rigide et
        /// interdisait d'ajouter un type sans decaler tous les autres.
        /// </summary>
        private class ZombieArchetype
        {
            public string Nom;
            public string Prefab;
            public int Cout;
            public int VagueMinimum;
            public float Vie;
            public float Vitesse;
            public float Degats;
            public bool Boss;

            public ZombieArchetype(string nom, string prefab, int cout, int vagueMinimum, float vie, float vitesse, float degats, bool boss = false)
            {
                Nom = nom;
                Prefab = prefab;
                Cout = cout;
                VagueMinimum = vagueMinimum;
                Vie = vie;
                Vitesse = vitesse;
                Degats = degats;
                Boss = boss;
            }
        }

        private static readonly ZombieArchetype[] ZombieArchetypes =
        {
            new ZombieArchetype("Marcheur",  ZombiePrefab, 1,  1, 1.00f, 1.00f, 1.00f),
            new ZombieArchetype("COUREUR",   ZombiePrefab, 2,  2, 0.72f, 1.32f, 0.85f),
            new ZombieArchetype("BRUTE",     ZombiePrefab, 4,  4, 2.30f, 0.80f, 1.55f),
            new ZombieArchetype("TOXIQUE",   ZombiePrefab, 3,  6, 1.15f, 1.05f, 1.80f),
            new ZombieArchetype("BLINDE",    ZombiePrefab, 5,  8, 3.40f, 0.72f, 1.40f),
            new ZombieArchetype("HURLEUR",   ZombiePrefab, 4, 11, 1.00f, 1.45f, 1.10f),
            new ZombieArchetype("REVENANT",  ZombiePrefab, 7, 15, 4.20f, 0.95f, 1.75f)
        };

        private class StoredData
        {
            public Dictionary<ulong, PlayerProgress> Joueurs = new Dictionary<ulong, PlayerProgress>();
        }

        protected override void LoadDefaultConfig()
        {
            _config = new PluginConfig();
            SaveConfig();
        }

        protected override void LoadConfig()
        {
            base.LoadConfig();
            try
            {
                _config = Config.ReadObject<PluginConfig>();
                if (_config == null)
                {
                    throw new Exception("Configuration vide");
                }
            }
            catch
            {
                PrintWarning("Configuration invalide, creation des valeurs par defaut.");
                LoadDefaultConfig();
            }
            SaveConfig();
        }

        protected override void SaveConfig()
        {
            Config.WriteObject(_config, true);
        }

        private void Init()
        {
            permission.RegisterPermission(AdminPermission, this);
            LoadData();
        }

        private void OnServerInitialized()
        {
            foreach (BasePlayer player in BasePlayer.activePlayerList)
            {
                EnsurePlayer(player.userID);
            }

            timer.Every(Mathf.Max(30f, _config.IntervalleApparitionSecondes), MaintainPopulation);
            timer.Once(10f, MaintainPopulation);
            timer.Every(1f, ZombieTick);
            Puts("Module de progression initialise : PvE, quetes, economie et mode Zombie actifs.");
        }

        private void Unload()
        {
            StopZombieMode(null, true);
            // StopZombieMode sort tot si le mode ne tournait pas : on garantit ici
            // qu'aucun panneau CUI ne survit au dechargement du plugin.
            DestroyAllZombieHuds();
            SaveData();
            RemoveSpawnedNpcs();
        }

        private void OnServerSave()
        {
            SaveData();
        }

        private void OnPlayerConnected(BasePlayer player)
        {
            EnsurePlayer(player.userID);

            // Un joueur deconnecte en pleine partie a ete sorti du mode et
            // depouille de son kit ; il lui reste a etre ramene ou il jouait.
            if (player != null && _zombiePendingReturns.Remove(player.userID))
            {
                Vector3 returnPosition;
                if (_zombieReturnPositions.TryGetValue(player.userID, out returnPosition))
                {
                    _zombieReturnPositions.Remove(player.userID);
                    timer.Once(6f, () =>
                    {
                        if (player == null || !player.IsConnected || player.IsDead()) return;
                        player.Teleport(returnPosition);
                        SendReply(player, "Tu as ete ramene a ta position d'avant le mode Zombie.");
                    });
                }
            }

            timer.Once(5f, () =>
            {
                if (player != null && player.IsConnected)
                {
                    SendReply(player, "<color=#d6a84b>Progression</color> — Tape <color=#ffd479>/progression</color> pour voir les commandes.");
                }
            });
        }

        private void OnPlayerRespawned(BasePlayer player)
        {
            if (player == null || _zombieModePlayers.Contains(player.userID)) return;

            Vector3 returnPosition;
            if (_zombieReturnPositions.TryGetValue(player.userID, out returnPosition))
            {
                _zombieReturnPositions.Remove(player.userID);
                timer.Once(0.2f, () =>
                {
                    if (player != null && player.IsConnected) player.Teleport(returnPosition);
                });
            }
        }

        private void OnPlayerDisconnected(BasePlayer player, string reason)
        {
            if (player == null) return;
            bool wasParticipant = _zombieModePlayers.Remove(player.userID);
            if (!wasParticipant)
            {
                _zombieReturnPositions.Remove(player.userID);
                return;
            }

            // Le kit doit partir maintenant : Rust sauvegarde l'inventaire a la
            // deconnexion, et sans ce nettoyage le joueur conservait armes et
            // munitions du mode a sa reconnexion.
            RemoveZombieKit(player);
            RemoveZombieBuildItems(player);
            DestroyZombieHud(player);
            _zombieCredits.Remove(player.userID);
            _zombieDowned.Remove(player.userID);
            _zombieDownedUntil.Remove(player.userID);

            // La position de retour survit a la deconnexion : elle sera appliquee
            // au retour du joueur plutot que jetee.
            if (_zombieReturnPositions.ContainsKey(player.userID)) _zombiePendingReturns.Add(player.userID);

            BroadcastZombie($"<color=#e76a4c>{player.displayName}</color> s'est deconnecte. {_zombieModePlayers.Count} survivant(s).");
            if (_zombieModePlayers.Count == 0)
            {
                StopZombieMode("Mode Zombie termine : tous les joueurs sont partis.", false);
            }
        }

        private object OnEntityTakeDamage(BaseCombatEntity entity, HitInfo info)
        {
            if (entity == null || info == null)
            {
                return null;
            }

            BasePlayer attacker = info.InitiatorPlayer;
            BasePlayer victim = entity as BasePlayer;

            object gunGameHook = Interface.CallHook("IsGunGameFight", attacker, victim);
            bool gunGameFight = gunGameHook is bool && (bool)gunGameHook;
            object duelHook = Interface.CallHook("IsDuelFight", attacker, victim);
            bool duelFight = duelHook is bool && (bool)duelHook;
            object competitiveHook = Interface.CallHook("IsCompetitiveModeFight", attacker, victim);
            bool competitiveFight = competitiveHook is bool && (bool)competitiveHook;
            object trainingHook = Interface.CallHook("IsTrainingFight", attacker, victim);
            bool trainingFight = trainingHook is bool && (bool)trainingHook;
            // Sans ce hook, RustRPG reactive annulerait tous les combats de Battlefield.
            object battlefieldHook = Interface.CallHook("IsBattlefieldFight", attacker, victim);
            trainingFight = trainingFight || (battlefieldHook is bool && (bool)battlefieldHook);

            bool victimWaveEnemy = victim != null && _waveEnemies.Contains(victim);
            bool attackerWaveEnemy = attacker != null && _waveEnemies.Contains(attacker);
            bool victimZombiePlayer = IsHumanPlayer(victim) && _zombieModePlayers.Contains(victim.userID);
            bool attackerZombiePlayer = IsHumanPlayer(attacker) && _zombieModePlayers.Contains(attacker.userID);

            if ((victimWaveEnemy && !attackerZombiePlayer) ||
                (attackerZombiePlayer && victim != null && !victimWaveEnemy) ||
                (victimZombiePlayer && attacker != null && !attackerWaveEnemy))
            {
                info.damageTypes.ScaleAll(0f);
                return true;
            }

            if (_config.BloquerDegatsEntreJoueurs && !gunGameFight && !duelFight && !competitiveFight && !trainingFight && IsHumanPlayer(attacker) && IsHumanPlayer(victim) && attacker != victim)
            {
                info.damageTypes.ScaleAll(0f);
                return true;
            }

            if (attackerWaveEnemy)
            {
                float multiplier;
                if (_waveDamageMultipliers.TryGetValue(attacker, out multiplier)) info.damageTypes.ScaleAll(multiplier);
            }

            if (!duelFight && !competitiveFight && IsHumanPlayer(victim))
            {
                PlayerProgress progress = EnsurePlayer(victim.userID);
                float reduction = Mathf.Clamp(progress.Vitalite * 0.05f, 0f, 0.25f);
                info.damageTypes.ScaleAll(1f - reduction);
            }

            if (IsHumanPlayer(attacker) && victim != null && victim.IsNpc)
            {
                PlayerProgress progress = EnsurePlayer(attacker.userID);
                float bonus = 1f + Mathf.Clamp(progress.Puissance * 0.05f, 0f, 0.25f);
                info.damageTypes.ScaleAll(bonus);
            }

            if (victimZombiePlayer)
            {
                // Un joueur a terre serait acheve en une seconde par la vague :
                // on laisse passer juste assez de degats pour que la situation
                // reste tendue sans rendre la reanimation impossible.
                if (_zombieDowned.Contains(victim.userID))
                {
                    info.damageTypes.ScaleAll(Mathf.Clamp01(_config.ZombieDegatsSubisAterre));
                    return null;
                }

                // Dernier maillon : le coup qui tuerait met a terre au lieu de
                // tuer. Ce test doit rester apres tous les ajustements de degats
                // ci-dessus, sinon on compare a une valeur qui n'est pas la finale.
                if (_config.ZombieSecondesAterre > 0f && info.damageTypes.Total() >= victim.health)
                {
                    info.damageTypes.ScaleAll(0f);
                    DownZombiePlayer(victim, info);
                    return true;
                }
            }

            return null;
        }

        private void OnDispenserGather(ResourceDispenser dispenser, BaseEntity entity, Item item)
        {
            BasePlayer player = entity as BasePlayer;
            if (!IsHumanPlayer(player) || item == null)
            {
                return;
            }

            PlayerProgress progress = EnsurePlayer(player.userID);
            float multiplier = 1f + progress.Recolte * 0.15f;
            item.amount = Mathf.Max(1, Mathf.RoundToInt(item.amount * multiplier));
        }

        private void OnEntityBuilt(Planner planner, GameObject gameObject)
        {
            BasePlayer player = planner != null ? planner.GetOwnerPlayer() : null;
            BaseEntity entity = gameObject != null ? gameObject.ToBaseEntity() : null;
            TrackZombieDefense(player, entity);
        }

        private void OnItemDeployed(Deployer deployer, BaseEntity entity)
        {
            BasePlayer player = deployer != null ? deployer.GetOwnerPlayer() : null;
            TrackZombieDefense(player, entity);
        }

        private void TrackZombieDefense(BasePlayer player, BaseEntity entity)
        {
            if (player == null || entity == null || !_zombieModePlayers.Contains(player.userID)) return;
            Vector3 delta = entity.transform.position - _zombieArenaCenter;
            delta.y = 0f;
            float radius = _config.RayonConstructionZombie;
            if (!_zombieBuildPhase || delta.sqrMagnitude > radius * radius)
            {
                SendReply(player, _zombieBuildPhase ? $"Construis a moins de {radius:0}m du centre de la zone Zombie." : "Construction autorisee uniquement entre les vagues.");
                timer.Once(0.05f, () => { if (entity != null && !entity.IsDestroyed) entity.Kill(); });
                return;
            }
            entity.enableSaving = false;
            if (!_zombieDefenses.Contains(entity)) _zombieDefenses.Add(entity);
        }

        private void OnEntityDeath(BaseCombatEntity entity, HitInfo info)
        {
            BasePlayer deadPlayer = entity as BasePlayer;
            if (IsHumanPlayer(deadPlayer) && _zombieModePlayers.Contains(deadPlayer.userID))
            {
                EliminateZombiePlayer(deadPlayer);
                return;
            }

            BasePlayer npc = deadPlayer;
            if (npc == null || !npc.IsNpc) return;

            bool isWaveBoss = _waveBosses.Remove(npc);
            bool isWaveEnemy = _waveEnemies.Remove(npc);
            _waveDamageMultipliers.Remove(npc);
            BasePlayer killer = info != null ? info.InitiatorPlayer : null;

            if (isWaveEnemy)
            {
                if (IsHumanPlayer(killer) && _zombieModePlayers.Contains(killer.userID))
                {
                    Award(killer, isWaveBoss ? _config.RecompenseBossExperience : _config.RecompenseZombieExperience, isWaveBoss ? _config.RecompenseBossPieces : _config.RecompenseZombiePieces, isWaveBoss ? "Boss de vague" : "Zombie de vague");
                    _zombieCredits[killer.userID] = ZombieCredits(killer.userID) + (isWaveBoss ? _config.CreditsBoss : _config.CreditsZombie);
                    SendReply(killer, $"Credits Zombie : <color=#9fd36f>{ZombieCredits(killer.userID)}</color>.");
                    AdvanceQuest(killer);
                }
                timer.Once(0.25f, CheckZombieWaveCleared);
                return;
            }

            object gunGameBotHook = Interface.CallHook("IsGunGameBot", npc);
            if (gunGameBotHook is bool && (bool)gunGameBotHook)
            {
                return;
            }
            object towerDefenseEnemyHook = Interface.CallHook("IsTowerDefenseEnemy", npc);
            if (towerDefenseEnemyHook is bool && (bool)towerDefenseEnemyHook) return;
            // Une cible d'entrainement ne doit jamais rapporter d'XP : elle est
            // invulnerable par conception, mais si un jour elle mourait par un
            // chemin imprevu, le stand de tir deviendrait une ferme a experience.
            object trainingTargetHook = Interface.CallHook("IsTrainingTarget", npc);
            if (trainingTargetHook is bool && (bool)trainingTargetHook) return;

            bool isBoss = _bosses.Remove(npc);
            bool isZombie = _zombies.Remove(npc);
            bool isScientist = _scientists.Remove(npc);

            if (!IsHumanPlayer(killer))
            {
                return;
            }

            int xp = isBoss ? 500 : isZombie ? 35 : 55;
            int coins = isBoss ? 750 : isZombie ? 20 : 35;
            string enemyName = isBoss ? "Boss" : isZombie ? "Zombie" : isScientist ? "Scientifique" : "PNJ";
            Award(killer, xp, coins, enemyName);
            AdvanceQuest(killer);
        }

        [ChatCommand("rpg")]
        private void CommandRpg(BasePlayer player, string command, string[] args)
        {
            SendReply(player, "<color=#d6a84b>Progression</color> - /stats, /quest, /claim, /skills, /skill, /balance, /shop, /buy, /lobby");
            SendReply(player, "Modes : /gungame, /zombie, /zombie endless, /td, /duel, /ctf, /dom, /snd et /extract. Tape /modes pour l'etat des parties.");
        }

        [ChatCommand("progression")]
        private void CommandProgression(BasePlayer player, string command, string[] args)
        {
            CommandRpg(player, command, args);
        }

        private object GetRpgPlayerStats(BasePlayer player)
        {
            if (player == null) return null;
            PlayerProgress progress = EnsurePlayer(player.userID);
            return $"niveau={progress.Niveau} experience={progress.Experience}/{XpForNextLevel(progress.Niveau)} pieces={progress.Pieces} points={progress.PointsCompetence} vague_zombie={progress.MeilleureVagueZombie} zombie_infini={progress.MeilleureVagueZombieInfini} victoires_zombie={progress.VictoiresZombie} reanimations={progress.ReanimationsZombie}";
        }

        private object ForceLeaveMode(BasePlayer player)
        {
            if (player == null || !_zombieModePlayers.Contains(player.userID)) return null;
            LeaveZombieMode(player, true);
            return true;
        }

        private object IsZombieParticipant(BasePlayer player)
        {
            return player != null && _zombieModePlayers.Contains(player.userID);
        }

        private object JoinZombieModeFromLobby(BasePlayer player)
        {
            if (player == null) return false;
            if (!_zombieModePlayers.Contains(player.userID)) JoinZombieMode(player);
            return true;
        }

        [ChatCommand("zombie")]
        private void CommandZombie(BasePlayer player, string command, string[] args)
        {
            if (_zombieModePlayers.Contains(player.userID))
            {
                LeaveZombieMode(player, true);
                return;
            }

            if (IsInGunGame(player))
            {
                SendReply(player, "Quitte d'abord le Gun Game avec /gungame.");
                return;
            }

            if (IsInDuel(player))
            {
                SendReply(player, "Quitte d'abord le mode Duel avec /duel leave.");
                return;
            }

            if (IsInCompetitiveMode(player))
            {
                SendReply(player, "Quitte d'abord le mode competitif avec /mode leave.");
                return;
            }

            bool endless = args != null && args.Length > 0 &&
                           (args[0].Equals("endless", StringComparison.OrdinalIgnoreCase) ||
                            args[0].Equals("infini", StringComparison.OrdinalIgnoreCase));

            // Le choix infini n'appartient qu'au fondateur de la session : un
            // joueur qui rejoint une partie en cours en herite.
            if (endless && _zombieModeRunning && !_zombieEndless)
            {
                SendReply(player, "Une survie classique est deja en cours : tu la rejoins.");
                endless = false;
            }

            JoinZombieMode(player, endless);
        }

        [ConsoleCommand("zombie")]
        private void ConsoleZombie(ConsoleSystem.Arg arg)
        {
            BasePlayer player = arg.Player();
            if (player == null)
            {
                arg.ReplyWith("Cette commande doit etre utilisee par un joueur.");
                return;
            }
            // arg.Args est un StringView[] et non un string[] : la conversion est
            // explicite, comme ailleurs dans le plugin.
            string[] args = arg.Args != null
                ? arg.Args.Select(value => value.ToString()).ToArray()
                : new string[0];
            CommandZombie(player, "zombie", args);
        }

        [ConsoleCommand("zombie.endless")]
        private void ConsoleEndlessZombie(ConsoleSystem.Arg arg)
        {
            BasePlayer caller = arg.Player();
            if (caller != null && !caller.IsAdmin)
            {
                arg.ReplyWith("Commande reservee aux administrateurs.");
                return;
            }
            if (_zombieModeRunning)
            {
                arg.ReplyWith("Une partie Zombie est deja en cours. Utilise zombie.stop d'abord.");
                return;
            }

            BasePlayer target = ResolveZombieTarget(arg);
            if (target == null)
            {
                arg.ReplyWith("Joueur connecte introuvable.");
                return;
            }
            string blocker = DescribeModeConflict(target);
            if (blocker != null)
            {
                arg.ReplyWith(blocker);
                return;
            }

            JoinZombieMode(target, true);
            arg.ReplyWith($"{target.displayName} lance le mode Zombie INFINI.");
        }

        private BasePlayer ResolveZombieTarget(ConsoleSystem.Arg arg)
        {
            string selector = arg.Args != null && arg.Args.Length > 0 ? arg.Args[0].ToString() : string.Empty;
            return BasePlayer.activePlayerList.FirstOrDefault(player =>
                string.IsNullOrEmpty(selector) ||
                player.UserIDString == selector ||
                player.displayName.IndexOf(selector, StringComparison.OrdinalIgnoreCase) >= 0);
        }

        private string DescribeModeConflict(BasePlayer target)
        {
            if (IsInGunGame(target)) return "Le joueur doit d'abord quitter le Gun Game.";
            if (IsInDuel(target)) return "Le joueur doit d'abord quitter le mode Duel.";
            if (IsInCompetitiveMode(target)) return "Le joueur doit d'abord quitter le mode competitif.";
            return null;
        }

        [ConsoleCommand("zombie.force")]
        private void ConsoleForceZombie(ConsoleSystem.Arg arg)
        {
            BasePlayer caller = arg.Player();
            if (caller != null && !caller.IsAdmin)
            {
                arg.ReplyWith("Commande reservee aux administrateurs.");
                return;
            }

            BasePlayer target = ResolveZombieTarget(arg);
            if (target == null)
            {
                arg.ReplyWith("Joueur connecte introuvable.");
                return;
            }
            string blocker = DescribeModeConflict(target);
            if (blocker != null)
            {
                arg.ReplyWith(blocker);
                return;
            }

            if (!_zombieModePlayers.Contains(target.userID)) JoinZombieMode(target);
            arg.ReplyWith($"{target.displayName} participe au mode Zombie.");
        }

        [ConsoleCommand("zombie.stop")]
        private void ConsoleStopZombie(ConsoleSystem.Arg arg)
        {
            BasePlayer caller = arg.Player();
            if (caller != null && !caller.IsAdmin)
            {
                arg.ReplyWith("Commande reservee aux administrateurs.");
                return;
            }
            StopZombieMode("Mode Zombie arrete par un administrateur.", true);
            arg.ReplyWith("Mode Zombie arrete.");
        }

        [ConsoleCommand("zombie.debug")]
        private void ConsoleZombieDebug(ConsoleSystem.Arg arg)
        {
            BasePlayer caller = arg.Player();
            if (caller != null && !caller.IsAdmin)
            {
                arg.ReplyWith("Commande reservee aux administrateurs.");
                return;
            }
            CleanupWaveSets();
            arg.ReplyWith($"running={_zombieModeRunning} endless={_zombieEndless} wave={_zombieWave}/{_config.ZombieVaguesMaximum} active={_zombieWaveActive} build={_zombieBuildPhase} players={_zombieModePlayers.Count} downed={_zombieDowned.Count} enemies={_waveEnemies.Count} bosses={_waveBosses.Count} defenses={_zombieDefenses.Count} huds={_zombieHudShown.Count} center={_zombieArenaCenter} arena_score={(_zombieModeRunning ? ScoreZombieArena(_zombieArenaCenter).ToString("0.0") : "n/a")}");
        }

        [ChatCommand("zstatus")]
        private void CommandZombieStatus(BasePlayer player, string command, string[] args)
        {
            PlayerProgress progress = EnsurePlayer(player.userID);
            if (!_zombieModeRunning)
            {
                SendReply(player, $"Mode Zombie inactif - meilleure vague {progress.MeilleureVagueZombie}, record infini {progress.MeilleureVagueZombieInfini}, {progress.VictoiresZombie} victoire(s), {progress.ReanimationsZombie} reanimation(s).");
                SendReply(player, "Tape <color=#ffd479>/zombie</color> pour la survie en 10 vagues ou <color=#ffd479>/zombie endless</color> pour le mode infini.");
                return;
            }

            CleanupWaveSets();
            string waves = _zombieEndless ? $"{_zombieWave}/INFINI" : $"{_zombieWave}/{_config.ZombieVaguesMaximum}";
            string downed = _zombieDowned.Count > 0 ? $", {_zombieDowned.Count} a terre" : string.Empty;
            SendReply(player, $"Mode Zombie - vague {waves}, {_waveEnemies.Count} ennemi(s), {_zombieModePlayers.Count} survivant(s){downed}, {ZombieCredits(player.userID)} credits. Phase : {ZombiePhaseLabel()}.");
        }

        [ChatCommand("zshop")]
        private void CommandZombieShop(BasePlayer player, string command, string[] args)
        {
            if (!_zombieModePlayers.Contains(player.userID)) { SendReply(player, "Rejoins le mode avec /zombie."); return; }
            SendReply(player, $"<color=#9fd36f>BOUTIQUE ZOMBIE</color> - {ZombieCredits(player.userID)} credits");
            SendReply(player, "/zbuy ammo (40) | meds (60) | wood (80) | stone (100) | barricade (120) | trap (250)");
            SendReply(player, "Les defenses et ressources de construction sont utilisables pendant l'intermission.");
        }

        [ChatCommand("zbuy")]
        private void CommandZombieBuy(BasePlayer player, string command, string[] args)
        {
            if (!_zombieModePlayers.Contains(player.userID)) { SendReply(player, "Rejoins le mode avec /zombie."); return; }
            if (args.Length == 0) { CommandZombieShop(player, "zshop", new string[0]); return; }
            string offer = args[0].ToLowerInvariant();
            int price;
            string shortname;
            int amount;
            string label;
            bool buildItem = false;
            if (offer == "ammo") { price = 40; shortname = "ammo.pistol"; amount = 128; label = "Munitions boutique"; }
            else if (offer == "meds") { price = 60; shortname = "syringe.medical"; amount = 3; label = "Soins boutique"; }
            else if (offer == "wood") { price = 80; shortname = "wood"; amount = 3000; label = "Bois construction"; buildItem = true; }
            else if (offer == "stone") { price = 100; shortname = "stones"; amount = 2500; label = "Pierre construction"; buildItem = true; }
            else if (offer == "barricade") { price = 120; shortname = "barricade.wood"; amount = 2; label = "Barricades"; buildItem = true; }
            else if (offer == "trap") { price = 250; shortname = "guntrap"; amount = 1; label = "Piege a fusil"; buildItem = true; }
            else { CommandZombieShop(player, "zshop", new string[0]); return; }
            if (ZombieCredits(player.userID) < price) { SendReply(player, "Pas assez de credits Zombie."); return; }

            // Les credits ne sont debites qu'une fois l'objet reellement remis :
            // inventaire plein ou objet inconnu ne doivent rien couter.
            if (!GiveTrackedItem(player, shortname, amount, buildItem ? ZombieBuildPrefix : ZombieItemPrefix, label))
            {
                SendReply(player, "Achat annule, aucun credit debite.");
                return;
            }
            _zombieCredits[player.userID] = ZombieCredits(player.userID) - price;
            SendReply(player, $"Achat : {label}. Reste {ZombieCredits(player.userID)} credits.");
        }

        [ConsoleCommand("rpg.rewards")]
        private void ConsoleRewards(ConsoleSystem.Arg arg)
        {
            BasePlayer caller = arg.Player();
            if (caller != null && !caller.IsAdmin) { arg.ReplyWith("Commande reservee aux administrateurs."); return; }
            arg.ReplyWith(GetRewardDashboardStatus().ToString());
        }

        private object GetRewardDashboardStatus()
        {
            return $"duel_xp_base={_config.RecompenseDuelExperienceBase} duel_coins_base={_config.RecompenseDuelPiecesBase} tournament_xp={_config.RecompenseTournoiExperience} tournament_coins={_config.RecompenseTournoiPieces} zombie_kill_xp={_config.RecompenseZombieExperience} zombie_kill_coins={_config.RecompenseZombiePieces} wave_coins={_config.RecompenseVaguePieces} zombie_victory_xp={_config.RecompenseVictoireZombieExperience} zombie_victory_coins={_config.RecompenseVictoireZombiePieces} mode_xp={_config.RecompenseModeExperience} mode_coins={_config.RecompenseModePieces}";
        }

        private object GetZombieDashboardStatus()
        {
            CleanupWaveSets();
            string waves = _zombieEndless ? $"{_zombieWave}/INFINI" : $"{_zombieWave}/{_config.ZombieVaguesMaximum}";
            return $"actif={_zombieModeRunning} infini={_zombieEndless} vague={waves} combat={_zombieWaveActive} construction={_zombieBuildPhase} joueurs={_zombieModePlayers.Count} aterre={_zombieDowned.Count} ennemis={_waveEnemies.Count} boss={_waveBosses.Count} defenses={_zombieDefenses.Count}";
        }

        [ConsoleCommand("rpg.rewards.apply")]
        private void ConsoleApplyRewards(ConsoleSystem.Arg arg)
        {
            BasePlayer caller = arg.Player();
            if (caller != null && !caller.IsAdmin) { arg.ReplyWith("Commande reservee aux administrateurs."); return; }
            if (arg.Args == null || arg.Args.Length != 11) { arg.ReplyWith("Usage: rpg.rewards.apply duelXP duelPieces tournoiXP tournoiPieces zombieXP zombiePieces vaguePieces victoireZombieXP victoireZombiePieces modeXP modePieces"); return; }
            int[] values = new int[11];
            for (int index = 0; index < values.Length; index++)
            {
                if (!int.TryParse(arg.Args[index].ToString(), out values[index]) || values[index] < 0 || values[index] > 100000)
                {
                    arg.ReplyWith($"Valeur {index + 1} invalide : nombre attendu entre 0 et 100000.");
                    return;
                }
            }
            _config.RecompenseDuelExperienceBase = values[0];
            _config.RecompenseDuelPiecesBase = values[1];
            _config.RecompenseTournoiExperience = values[2];
            _config.RecompenseTournoiPieces = values[3];
            _config.RecompenseZombieExperience = values[4];
            _config.RecompenseZombiePieces = values[5];
            _config.RecompenseVaguePieces = values[6];
            _config.RecompenseVictoireZombieExperience = values[7];
            _config.RecompenseVictoireZombiePieces = values[8];
            _config.RecompenseModeExperience = values[9];
            _config.RecompenseModePieces = values[10];
            SaveConfig();
            arg.ReplyWith("Recompenses appliquees. " + GetRewardDashboardStatus());
        }

        [ConsoleCommand("rpg.rewards.set")]
        private void ConsoleSetReward(ConsoleSystem.Arg arg)
        {
            BasePlayer caller = arg.Player();
            if (caller != null && !caller.IsAdmin) { arg.ReplyWith("Commande reservee aux administrateurs."); return; }
            if (arg.Args == null || arg.Args.Length < 2) { arg.ReplyWith("Usage: rpg.rewards.set cle valeur"); return; }
            int value;
            if (!int.TryParse(arg.Args[1].ToString(), out value) || value < 0 || value > 100000) { arg.ReplyWith("Valeur attendue entre 0 et 100000."); return; }
            string key = arg.Args[0].ToString().ToLowerInvariant();
            if (key == "duel_xp_base") _config.RecompenseDuelExperienceBase = value;
            else if (key == "duel_coins_base") _config.RecompenseDuelPiecesBase = value;
            else if (key == "tournament_xp") _config.RecompenseTournoiExperience = value;
            else if (key == "tournament_coins") _config.RecompenseTournoiPieces = value;
            else if (key == "zombie_kill_xp") _config.RecompenseZombieExperience = value;
            else if (key == "zombie_kill_coins") _config.RecompenseZombiePieces = value;
            else if (key == "wave_coins") _config.RecompenseVaguePieces = value;
            else if (key == "zombie_victory_xp") _config.RecompenseVictoireZombieExperience = value;
            else if (key == "zombie_victory_coins") _config.RecompenseVictoireZombiePieces = value;
            else if (key == "mode_xp") _config.RecompenseModeExperience = value;
            else if (key == "mode_coins") _config.RecompenseModePieces = value;
            else { arg.ReplyWith("Cle inconnue."); return; }
            SaveConfig();
            arg.ReplyWith($"{key}={value} enregistre.");
        }

        private void JoinZombieMode(BasePlayer player, bool endless = false)
        {
            bool newSession = !_zombieModeRunning;
            if (newSession)
            {
                _zombieModeRunning = true;
                _zombieWaveActive = false;
                _zombieBuildPhase = false;
                _zombieEndless = endless;
                _zombieWave = 0;
                _zombieSessionId++;
                _zombieArenaCenter = FindZombieArenaCenter(player);
                Puts($"Mode Zombie {(endless ? "INFINI" : "classique")} cree en {_zombieArenaCenter}.");
            }

            _zombieReturnPositions[player.userID] = player.transform.position;
            _zombiePendingReturns.Remove(player.userID);
            _zombieModePlayers.Add(player.userID);
            if (!_zombieCredits.ContainsKey(player.userID)) _zombieCredits[player.userID] = 100;
            player.Teleport(GetZombiePlayerSpawn());
            GiveZombieKit(player);
            BroadcastZombie($"<color=#9fd36f>{player.displayName}</color> rejoint la survie Zombie.");
            SendReply(player, "<color=#9fd36f>Mode Zombie actif !</color> Gagne des credits, utilise /zshop entre les vagues et construis des defenses.");
            SendReply(player, "Si tu tombes, tu passes <color=#e76a4c>a terre</color> : un allie peut te relever avant la fin du compte a rebours.");
            DrawZombieHud(player);

            if (newSession)
            {
                BroadcastZombie(_zombieEndless
                    ? "<color=#ffd479>MODE INFINI</color> - premiere vague dans 5 secondes."
                    : "Premiere vague dans 5 secondes.");
                ScheduleNextZombieWave(5f);
            }
        }

        private void LeaveZombieMode(BasePlayer player, bool notify)
        {
            if (player == null || !_zombieModePlayers.Remove(player.userID)) return;

            RemoveZombieKit(player);
            RemoveZombieBuildItems(player);
            DestroyZombieHud(player);
            _zombieCredits.Remove(player.userID);
            if (_zombieDowned.Remove(player.userID))
            {
                _zombieDownedUntil.Remove(player.userID);
                try { player.StopWounded(); } catch { }
                player.Heal(50f);
            }
            Vector3 returnPosition;
            if (!player.IsDead() && _zombieReturnPositions.TryGetValue(player.userID, out returnPosition))
            {
                player.Teleport(returnPosition);
                _zombieReturnPositions.Remove(player.userID);
            }
            if (notify) SendReply(player, "Tu as quitte le mode Zombie et retrouve ta position precedente.");

            if (_zombieModePlayers.Count == 0)
            {
                StopZombieMode("Mode Zombie termine : plus aucun survivant.", false);
            }
        }

        private void EliminateZombiePlayer(BasePlayer player)
        {
            if (player == null || !_zombieModePlayers.Remove(player.userID)) return;
            RemoveZombieKit(player);
            RemoveZombieBuildItems(player);
            DestroyZombieHud(player);
            _zombieCredits.Remove(player.userID);
            _zombieDowned.Remove(player.userID);
            _zombieDownedUntil.Remove(player.userID);
            SendReply(player, "Tu as ete elimine du mode Zombie. Tu retourneras a ta position au respawn.");
            BroadcastZombie($"<color=#e76a4c>{player.displayName}</color> a ete elimine. {_zombieModePlayers.Count} survivant(s).");
            if (_zombieModePlayers.Count == 0)
            {
                StopZombieMode("Defaite : tous les survivants ont ete elimines.", false);
            }
        }

        private void StartNextZombieWave()
        {
            if (!_zombieModeRunning || _zombieModePlayers.Count == 0 || _zombieWaveActive) return;

            _zombieBuildPhase = false;
            foreach (ulong userId in _zombieModePlayers.ToArray())
            {
                BasePlayer builder = FindActivePlayer(userId);
                if (builder != null) RemoveZombieBuildItems(builder);
            }
            _zombieWave++;
            _zombieWaveActive = true;
            bool bossWave = IsZombieBossWave(_zombieWave);
            int spawned = 0;
            int cap = Mathf.Max(6, _config.ZombiePlafondEnnemis);
            float baseHealth = 100f + (_zombieWave - 1) * 26f;

            if (bossWave)
            {
                string bossName = ZombieBossName(_zombieWave);
                int bossCount = _zombieEndless
                    ? 1 + _zombieWave / 20
                    : (_zombieWave >= _config.ZombieVaguesMaximum ? 2 : 1);
                for (int bossIndex = 0; bossIndex < bossCount; bossIndex++)
                {
                    if (SpawnWaveEnemy(BossPrefab, bossName, 700f + _zombieWave * 150f, true, 0.82f, 1.7f + _zombieWave * 0.08f)) spawned++;
                }
            }

            // Le reste de la vague est compose en depensant un budget : chaque
            // type coute des points et n'est debloque qu'a partir d'une vague
            // donnee, ce qui fait evoluer la composition et pas seulement le nombre.
            int budget = _config.ZombieBudgetBase +
                         (_zombieWave - 1) * _config.ZombieBudgetParVague +
                         _zombieModePlayers.Count * _config.ZombieBudgetParJoueur;

            List<ZombieArchetype> pool = ZombieArchetypes
                .Where(archetype => !archetype.Boss && archetype.VagueMinimum <= _zombieWave)
                .ToList();

            while (budget > 0 && spawned < cap && pool.Count > 0)
            {
                List<ZombieArchetype> affordable = pool.Where(archetype => archetype.Cout <= budget).ToList();
                if (affordable.Count == 0) break;

                ZombieArchetype choice = affordable[UnityEngine.Random.Range(0, affordable.Count)];
                string name = choice.Cout == 1 ? $"Zombie - Vague {_zombieWave}" : choice.Nom;
                if (!SpawnWaveEnemy(ZombiePrefab, name, baseHealth * choice.Vie, false, choice.Vitesse, choice.Degats))
                {
                    // Plus aucune position d'apparition exploitable : inutile d'insister.
                    break;
                }
                spawned++;
                budget -= choice.Cout;
            }

            foreach (ulong userId in _zombieModePlayers.ToArray())
            {
                PlayerProgress progress = EnsurePlayer(userId);
                if (_zombieEndless) progress.MeilleureVagueZombieInfini = Math.Max(progress.MeilleureVagueZombieInfini, _zombieWave);
                else progress.MeilleureVagueZombie = Math.Max(progress.MeilleureVagueZombie, _zombieWave);
            }
            SaveData();

            if (spawned == 0)
            {
                StopZombieMode("Mode Zombie arrete : aucune position NavMesh valide pour les ennemis.", true);
                return;
            }

            Puts($"Vague Zombie {_zombieWave} lancee en {_zombieArenaCenter} : {spawned} ennemi(s), boss={bossWave}, infini={_zombieEndless}.");
            string waveLabel = _zombieEndless ? $"VAGUE {_zombieWave}" : $"VAGUE {_zombieWave}/{_config.ZombieVaguesMaximum}";
            BroadcastZombie($"<color=#e76a4c>{waveLabel}</color> - {spawned} ennemi(s){(bossWave ? " avec un BOSS" : string.Empty)} !");
        }

        private bool IsZombieBossWave(int wave)
        {
            if (_zombieEndless)
            {
                int period = Mathf.Max(2, _config.ZombieEndlessBossTousLes);
                return wave % period == 0;
            }
            return wave == 3 || wave == 5 || wave == 8 || wave >= _config.ZombieVaguesMaximum;
        }

        private string ZombieBossName(int wave)
        {
            if (!_zombieEndless)
            {
                if (wave == 3) return "LE BOUCHER";
                if (wave == 5) return "ABOMINATION";
                if (wave == 8) return "JUGGERNAUT";
                return "ALPHA MUTANT";
            }
            string[] names = { "LE BOUCHER", "ABOMINATION", "JUGGERNAUT", "ALPHA MUTANT", "SEIGNEUR DE LA HORDE" };
            return names[Mathf.Min(names.Length - 1, wave / Mathf.Max(2, _config.ZombieEndlessBossTousLes) - 1)];
        }

        private bool SpawnWaveEnemy(string prefab, string name, float health, bool boss, float speedMultiplier, float damageMultiplier)
        {
            Vector3 spawnPosition;
            if (!FindZombieEnemySpawn(out spawnPosition)) return false;

            BaseEntity entity = GameManager.server.CreateEntity(prefab, spawnPosition, Quaternion.identity, true);
            BasePlayer npc = entity as BasePlayer;
            if (npc == null)
            {
                if (entity != null) entity.Kill();
                return false;
            }

            npc.enableSaving = false;
            npc.displayName = name;
            npc.Spawn();
            npc.InitializeHealth(health, health);
            if (!PlaceNpcOnNavMesh(npc, spawnPosition))
            {
                npc.Kill();
                return false;
            }
            NPCPlayer ai = npc as NPCPlayer;
            if (ai != null && ai.NavAgent != null) ai.NavAgent.speed = Mathf.Max(1f, ai.NavAgent.speed * speedMultiplier);
            _waveEnemies.Add(npc);
            if (boss) _waveBosses.Add(npc);
            _waveDamageMultipliers[npc] = Mathf.Max(0.1f, damageMultiplier);
            return true;
        }

        private void CheckZombieWaveCleared()
        {
            if (!_zombieModeRunning || !_zombieWaveActive) return;
            CleanupWaveSets();
            if (_waveEnemies.Count > 0) return;

            _zombieWaveActive = false;
            Puts($"Vague Zombie {_zombieWave} terminee.");
            foreach (ulong userId in _zombieModePlayers.ToArray())
            {
                BasePlayer player = FindActivePlayer(userId);
                if (player != null && player.IsConnected)
                {
                    Award(player, 35 + _zombieWave * 10, _config.RecompenseVaguePieces + _zombieWave * 15, $"Vague {_zombieWave} terminee");
                }
            }

            if (!_zombieEndless && _zombieWave >= _config.ZombieVaguesMaximum)
            {
                foreach (ulong userId in _zombieModePlayers.ToArray())
                {
                    BasePlayer player = FindActivePlayer(userId);
                    if (player == null || !player.IsConnected) continue;
                    EnsurePlayer(userId).VictoiresZombie++;
                    Award(player, _config.RecompenseVictoireZombieExperience, _config.RecompenseVictoireZombiePieces, "Victoire Zombie");
                }
                SaveData();
                BroadcastZombie($"<color=#ffd479>VICTOIRE !</color> Les {_config.ZombieVaguesMaximum} vagues Zombie sont terminees.");
                int completedSession = _zombieSessionId;
                timer.Once(5f, () =>
                {
                    if (_zombieModeRunning && completedSession == _zombieSessionId) StopZombieMode("Survie Zombie terminee.", true);
                });
                return;
            }

            // En infini, un palier franchi vaut une recompense RPG et un record.
            int milestone = Mathf.Max(1, _config.ZombieEndlessPalierRecompense);
            if (_zombieEndless && _zombieWave % milestone == 0)
            {
                foreach (ulong userId in _zombieModePlayers.ToArray())
                {
                    BasePlayer player = FindActivePlayer(userId);
                    if (player == null || !player.IsConnected) continue;
                    Award(player, _config.RecompenseEndlessPalierExperience, _config.RecompenseEndlessPalierPieces, $"Palier infini {_zombieWave}");
                }
                SaveData();
                BroadcastZombie($"<color=#ffd479>PALIER {_zombieWave}</color> franchi ! Recompense distribuee.");
            }

            BeginZombieIntermission();
            ScheduleNextZombieWave(ZombieIntermissionDelay());
        }

        /// <summary>
        /// Duree de l'intermission. En infini elle se resserre a chaque vague
        /// jusqu'a un plancher : c'est la pression du temps, plus que le nombre
        /// d'ennemis, qui finit par mettre l'equipe en difficulte.
        /// </summary>
        private float ZombieIntermissionDelay()
        {
            if (!_zombieEndless) return _config.PauseEntreVaguesSecondes;
            float reduced = _config.PauseEntreVaguesSecondes - (_zombieWave - 1) * 0.6f;
            return Mathf.Max(_config.ZombieEndlessPauseMinimum, reduced);
        }

        private void BeginZombieIntermission()
        {
            _zombieBuildPhase = true;
            float delay = ZombieIntermissionDelay();
            float radius = _config.RayonConstructionZombie;
            foreach (ulong userId in _zombieModePlayers.ToArray())
            {
                BasePlayer player = FindActivePlayer(userId);
                if (player == null || !player.IsConnected) continue;
                GiveZombieBuildItem(player, "building.planner", 1, "Plan de construction");
                GiveZombieBuildItem(player, "hammer", 1, "Marteau");
                SendReply(player, $"<color=#9fd36f>INTERMISSION {delay:0}s</color> - construis dans un rayon de {radius:0}m et utilise /zshop. Credits : {ZombieCredits(userId)}.");
            }
            BroadcastZombie($"Prochaine vague dans {delay:0} secondes. Phase construction active.");
        }

        private void ScheduleNextZombieWave(float delay)
        {
            float wait = Mathf.Max(1f, delay);
            // Sert au compte a rebours affiche par le HUD.
            _zombieNextWaveAt = UnityEngine.Time.realtimeSinceStartup + wait;
            int scheduledSession = _zombieSessionId;
            timer.Once(wait, () =>
            {
                if (_zombieModeRunning && scheduledSession == _zombieSessionId) StartNextZombieWave();
            });
        }

        private void StopZombieMode(string message, bool returnPlayers)
        {
            if (!_zombieModeRunning && _waveEnemies.Count == 0) return;

            if (!string.IsNullOrEmpty(message)) BroadcastZombie(message);
            _zombieModeRunning = false;
            _zombieWaveActive = false;
            _zombieBuildPhase = false;
            _zombieEndless = false;
            _zombieNextWaveAt = 0f;
            _zombieSessionId++;
            DestroyAllZombieHuds();

            // Les joueurs a terre doivent etre remis debout avant d'etre rendus
            // au monde normal, sinon ils y restent bloques en rampant.
            foreach (ulong downedId in _zombieDowned.ToArray())
            {
                BasePlayer downedPlayer = FindActivePlayer(downedId);
                if (downedPlayer == null) continue;
                try { downedPlayer.StopWounded(); } catch { }
                downedPlayer.Heal(50f);
            }
            _zombieDowned.Clear();
            _zombieDownedUntil.Clear();

            foreach (BasePlayer enemy in _waveEnemies.ToArray())
            {
                _waveEnemies.Remove(enemy);
                _waveBosses.Remove(enemy);
                if (enemy != null && !enemy.IsDestroyed) enemy.Kill();
            }
            _waveEnemies.Clear();
            _waveBosses.Clear();
            _waveDamageMultipliers.Clear();

            foreach (BaseEntity defense in _zombieDefenses.ToArray())
            {
                if (defense != null && !defense.IsDestroyed) defense.Kill();
            }
            _zombieDefenses.Clear();

            foreach (ulong userId in _zombieModePlayers.ToArray())
            {
                BasePlayer player = FindActivePlayer(userId);
                if (player == null) continue;
                RemoveZombieKit(player);
                RemoveZombieBuildItems(player);
                Vector3 returnPosition;
                if (returnPlayers && !player.IsDead() && _zombieReturnPositions.TryGetValue(userId, out returnPosition))
                {
                    player.Teleport(returnPosition);
                    _zombieReturnPositions.Remove(userId);
                }
            }
            _zombieModePlayers.Clear();
            _zombieCredits.Clear();
            _zombieWave = 0;
        }

        private void BroadcastZombie(string message)
        {
            foreach (BasePlayer player in BasePlayer.activePlayerList)
            {
                if (_zombieModePlayers.Contains(player.userID)) SendReply(player, message);
            }
        }

        private BasePlayer FindActivePlayer(ulong userId)
        {
            return BasePlayer.activePlayerList.FirstOrDefault(candidate => candidate != null && candidate.userID == userId);
        }

        // ----- HUD et battement du mode -------------------------------------

        /// <summary>
        /// Un seul battement permanent pilote le HUD et les comptes a rebours.
        /// Il est cree une fois au demarrage plutot qu'a chaque partie : garder
        /// une reference de timer obligerait a nommer un type dont la resolution
        /// differe entre Oxide et Carbon, pour economiser un test par seconde.
        /// </summary>
        private void ZombieTick()
        {
            if (!_zombieModeRunning) return;

            ExpireDownedPlayers();
            if (!_zombieModeRunning) return;

            foreach (ulong userId in _zombieModePlayers.ToArray())
            {
                BasePlayer player = FindActivePlayer(userId);
                if (player == null || !player.IsConnected) continue;
                DrawZombieHud(player);
            }
        }

        private string ZombiePhaseLabel()
        {
            if (_zombieBuildPhase) return "CONSTRUCTION";
            return _zombieWaveActive ? "COMBAT" : "PREPARATION";
        }

        private void DrawZombieHud(BasePlayer player)
        {
            if (!_config.ZombieAfficherHud || player == null || !player.IsConnected) return;

            CleanupWaveSets();
            CuiHelper.DestroyUi(player, ZombieHudPanel);

            CuiElementContainer container = new CuiElementContainer();
            string panel = container.Add(new CuiPanel
            {
                Image = { Color = "0.05 0.04 0.03 0.82" },
                RectTransform = { AnchorMin = "0.795 0.70", AnchorMax = "0.995 0.955" },
                CursorEnabled = false
            }, "Hud", ZombieHudPanel);

            string title = _zombieEndless ? "SURVIE ZOMBIE - INFINI" : "SURVIE ZOMBIE";
            container.Add(new CuiLabel
            {
                Text = { Text = title, FontSize = 13, Align = TextAnchor.MiddleCenter, Color = "0.90 0.35 0.22 1" },
                RectTransform = { AnchorMin = "0 0.84", AnchorMax = "1 1" }
            }, panel);

            string wave = _zombieEndless
                ? $"VAGUE {_zombieWave}"
                : $"VAGUE {_zombieWave}/{_config.ZombieVaguesMaximum}";
            container.Add(new CuiLabel
            {
                Text = { Text = wave, FontSize = 20, Align = TextAnchor.MiddleCenter, Color = "1 0.85 0.47 1" },
                RectTransform = { AnchorMin = "0 0.60", AnchorMax = "1 0.86" }
            }, panel);

            int downed = _zombieDowned.Count;
            string survivors = downed > 0
                ? $"Survivants : {_zombieModePlayers.Count - downed}/{_zombieModePlayers.Count}  ({downed} a terre)"
                : $"Survivants : {_zombieModePlayers.Count}";

            AddZombieHudLine(container, panel, 0.44f, 0.60f, $"Ennemis restants : {_waveEnemies.Count}", "0.85 0.82 0.76 1");
            AddZombieHudLine(container, panel, 0.30f, 0.44f, survivors, downed > 0 ? "0.91 0.42 0.30 1" : "0.85 0.82 0.76 1");
            AddZombieHudLine(container, panel, 0.16f, 0.30f, $"Credits : {ZombieCredits(player.userID)}", "0.62 0.83 0.44 1");

            string phase = ZombiePhaseLabel();
            if (!_zombieWaveActive && _zombieNextWaveAt > UnityEngine.Time.realtimeSinceStartup)
            {
                int remaining = Mathf.CeilToInt(_zombieNextWaveAt - UnityEngine.Time.realtimeSinceStartup);
                phase += $" - vague suivante dans {remaining}s";
            }
            if (_zombieDowned.Contains(player.userID))
            {
                float until;
                if (_zombieDownedUntil.TryGetValue(player.userID, out until))
                {
                    int left = Mathf.Max(0, Mathf.CeilToInt(until - UnityEngine.Time.realtimeSinceStartup));
                    phase = $"A TERRE - {left}s avant elimination";
                }
            }
            AddZombieHudLine(container, panel, 0.01f, 0.16f, phase, "0.68 0.65 0.60 1");

            CuiHelper.AddUi(player, container);
            _zombieHudShown.Add(player.userID);
        }

        private void AddZombieHudLine(CuiElementContainer container, string parent, float min, float max, string text, string color)
        {
            container.Add(new CuiLabel
            {
                Text = { Text = text, FontSize = 11, Align = TextAnchor.MiddleCenter, Color = color },
                RectTransform = { AnchorMin = $"0 {min.ToString(System.Globalization.CultureInfo.InvariantCulture)}", AnchorMax = $"1 {max.ToString(System.Globalization.CultureInfo.InvariantCulture)}" }
            }, parent);
        }

        private void DestroyZombieHud(BasePlayer player)
        {
            if (player == null) return;
            _zombieHudShown.Remove(player.userID);
            if (!player.IsConnected) return;
            CuiHelper.DestroyUi(player, ZombieHudPanel);
        }

        private void DestroyAllZombieHuds()
        {
            // On parcourt _zombieHudShown et pas seulement les participants :
            // un joueur elimine garde sinon son panneau a l'ecran.
            foreach (ulong userId in _zombieHudShown.ToArray())
            {
                BasePlayer player = FindActivePlayer(userId);
                if (player != null && player.IsConnected) CuiHelper.DestroyUi(player, ZombieHudPanel);
            }
            _zombieHudShown.Clear();
        }

        // ----- A terre et reanimation ---------------------------------------

        /// <summary>
        /// Met un joueur a terre au lieu de l'eliminer. On s'appuie sur l'etat
        /// blesse natif de Rust : le joueur rampe, et un allie peut le relever
        /// avec la mecanique de secours du jeu, qui declenche OnPlayerRevive.
        /// </summary>
        private void DownZombiePlayer(BasePlayer player, HitInfo info)
        {
            if (player == null || !_zombieModePlayers.Contains(player.userID)) return;
            if (!_zombieDowned.Add(player.userID)) return;

            _zombieDownedUntil[player.userID] = UnityEngine.Time.realtimeSinceStartup + _config.ZombieSecondesAterre;

            try
            {
                player.health = 4f;
                player.BecomeWounded(info);
            }
            catch
            {
                // Si l'etat blesse natif n'est pas disponible, on garde au moins
                // le joueur en vie et le compte a rebours logiciel.
                player.health = 4f;
            }

            BroadcastZombie($"<color=#e76a4c>{player.displayName} est a terre !</color> Approchez et maintenez la touche d'utilisation pour le relever ({_config.ZombieSecondesAterre:0}s).");
            SendReply(player, "Tu es <color=#e76a4c>a terre</color>. Un allie peut te relever avant la fin du compte a rebours.");

            CheckZombieTeamWipe();
        }

        private void ReviveZombiePlayer(BasePlayer player, BasePlayer reviver)
        {
            if (player == null || !_zombieDowned.Remove(player.userID)) return;
            _zombieDownedUntil.Remove(player.userID);

            try { player.StopWounded(); } catch { }
            player.Heal(Mathf.Max(10f, _config.ZombieVieApresReanimation));

            if (reviver != null && _zombieModePlayers.Contains(reviver.userID))
            {
                PlayerProgress progress = EnsurePlayer(reviver.userID);
                progress.ReanimationsZombie++;
                Award(reviver, 50, 100, "Reanimation");
                BroadcastZombie($"<color=#9fd36f>{reviver.displayName}</color> a releve <color=#9fd36f>{player.displayName}</color> !");
            }
            else
            {
                BroadcastZombie($"<color=#9fd36f>{player.displayName}</color> s'est remis sur pied.");
            }
        }

        private void ExpireDownedPlayers()
        {
            if (_zombieDowned.Count == 0) return;
            float now = UnityEngine.Time.realtimeSinceStartup;

            foreach (ulong userId in _zombieDowned.ToArray())
            {
                float until;
                if (!_zombieDownedUntil.TryGetValue(userId, out until)) { until = now; }
                if (now < until) continue;

                BasePlayer player = FindActivePlayer(userId);
                _zombieDowned.Remove(userId);
                _zombieDownedUntil.Remove(userId);
                if (player == null)
                {
                    _zombieModePlayers.Remove(userId);
                    continue;
                }
                BroadcastZombie($"<color=#e76a4c>{player.displayName}</color> n'a pas ete releve a temps.");
                EliminateZombiePlayer(player);
            }
        }

        /// <summary>
        /// Defaite quand plus personne n'est debout : sans ce test, une equipe
        /// entierement a terre attendait la fin de chaque compte a rebours.
        /// </summary>
        private void CheckZombieTeamWipe()
        {
            if (!_zombieModeRunning || _zombieModePlayers.Count == 0) return;
            if (_zombieDowned.Count < _zombieModePlayers.Count) return;
            StopZombieMode("Defaite : toute l'equipe est a terre.", true);
        }

        private object OnPlayerRevive(BasePlayer reviver, BasePlayer player)
        {
            if (player != null && _zombieDowned.Contains(player.userID)) ReviveZombiePlayer(player, reviver);
            return null;
        }

        private void OnPlayerRecovered(BasePlayer player)
        {
            if (player != null && _zombieDowned.Contains(player.userID)) ReviveZombiePlayer(player, null);
        }

        /// <summary>
        /// Choisit un centre d'arene jouable. L'ancienne version retenait la
        /// premiere position navigable hors eau et hors monument, sans jamais
        /// verifier que le terrain etait praticable : l'arene tombait en pleine
        /// pente, dans une foret dense ou sur la base d'un joueur. On note
        /// desormais plusieurs candidats et on garde le meilleur.
        /// </summary>
        private Vector3 FindZombieArenaCenter(BasePlayer player)
        {
            Vector3 origin = player.transform.position;
            Vector3 best = Vector3.zero;
            float bestScore = float.MinValue;

            // Priorite au voisinage du joueur : une arene proche evite un long trajet.
            for (int attempt = 0; attempt < 45; attempt++)
            {
                Vector2 direction = UnityEngine.Random.insideUnitCircle.normalized;
                float distance = UnityEngine.Random.Range(70f, 180f);
                Vector3 candidate = origin + new Vector3(direction.x, 0f, direction.y) * distance;
                Vector3 navigable;
                if (!TryGetSafeZombiePosition(candidate, 25f, out navigable)) continue;

                float score = ScoreZombieArena(navigable);
                if (score <= float.MinValue) continue;
                if (score > bestScore)
                {
                    bestScore = score;
                    best = navigable;
                    // Terrain plat, degage et bien couvert par le NavMesh : inutile de chercher plus loin.
                    if (score >= 90f) return best;
                }
            }
            if (bestScore >= 55f) return best;

            // Elargissement a la carte entiere quand le voisinage ne donne rien de bon.
            float halfSize = TerrainMeta.Size.x * 0.5f;
            float limit = Mathf.Max(120f, halfSize * 0.7f);
            for (int attempt = 0; attempt < 120; attempt++)
            {
                Vector3 candidate = new Vector3(
                    UnityEngine.Random.Range(-limit, limit),
                    0f,
                    UnityEngine.Random.Range(-limit, limit));
                Vector3 navigable;
                if (!TryGetSafeZombiePosition(candidate, 25f, out navigable)) continue;

                float score = ScoreZombieArena(navigable);
                if (score <= float.MinValue) continue;
                if (score > bestScore)
                {
                    bestScore = score;
                    best = navigable;
                    if (score >= 90f) return best;
                }
            }
            if (bestScore > float.MinValue) return best;

            // Plus aucun candidat note : on retombe sur l'ancien comportement
            // permissif plutot que de refuser de lancer le mode.
            Vector3[] fallbacks =
            {
                Vector3.zero, new Vector3(0f, 0f, 350f), new Vector3(350f, 0f, 0f),
                new Vector3(0f, 0f, -350f), new Vector3(-350f, 0f, 0f)
            };
            foreach (Vector3 candidate in fallbacks.OrderBy(value => UnityEngine.Random.value))
            {
                Vector3 navigable;
                if (TryGetSafeZombiePosition(candidate, 30f, out navigable)) return navigable;
            }

            Vector3 fallback;
            return TryGetNavigablePosition(origin, 30f, out fallback) ? fallback : Vector3.zero;
        }

        /// <summary>
        /// Note une arene candidate de 0 a 100, ou float.MinValue si elle est
        /// disqualifiee. Les criteres eliminatoires sont ceux qui rendent une
        /// partie injouable : relief, eau dans l'enceinte, base de joueur, et
        /// surtout couverture NavMesh insuffisante sur l'anneau d'apparition,
        /// qui se traduisait par un "aucune position valide" en pleine partie.
        /// </summary>
        private float ScoreZombieArena(Vector3 center)
        {
            float buildRadius = Mathf.Max(20f, _config.RayonConstructionZombie);

            // 1. Relief : on echantillonne trois anneaux et on mesure l'amplitude.
            float minHeight = float.MaxValue;
            float maxHeight = float.MinValue;
            for (int ring = 1; ring <= 3; ring++)
            {
                float radius = buildRadius * ring / 3f;
                for (int step = 0; step < 8; step++)
                {
                    float angle = step * Mathf.PI * 2f / 8f;
                    Vector3 point = center + new Vector3(Mathf.Cos(angle), 0f, Mathf.Sin(angle)) * radius;
                    float height = TerrainMeta.HeightMap.GetHeight(point);
                    float water = TerrainMeta.WaterMap.GetHeight(point);
                    if (height <= water + 1f) return float.MinValue;
                    if (height < minHeight) minHeight = height;
                    if (height > maxHeight) maxHeight = height;
                }
            }
            float relief = maxHeight - minHeight;
            if (relief > 16f) return float.MinValue;

            // 2. Couverture NavMesh de l'anneau d'apparition des ennemis.
            int navigable = 0;
            const int NavSamples = 12;
            for (int step = 0; step < NavSamples; step++)
            {
                float angle = step * Mathf.PI * 2f / NavSamples;
                Vector3 point = center + new Vector3(Mathf.Cos(angle), 0f, Mathf.Sin(angle)) * _config.RayonApparitionZombie;
                point.y = TerrainMeta.HeightMap.GetHeight(point) + 1f;
                Vector3 resolved;
                if (TryGetNavigablePosition(point, 12f, out resolved)) navigable++;
            }
            if (navigable < 7) return float.MinValue;

            // 3. Bases de joueurs : on ne pose jamais une arene sur une construction.
            if (HasPlayerBuildingNearby(center, buildRadius + 25f)) return float.MinValue;

            // 4. Encombrement au sol (rochers, arbres, epaves) au centre de l'arene.
            int obstacles = CountArenaObstacles(center, buildRadius * 0.6f);

            float reliefScore = Mathf.Clamp01(1f - relief / 16f) * 45f;
            float navScore = (float)navigable / NavSamples * 40f;
            float clearScore = Mathf.Clamp01(1f - obstacles / 25f) * 15f;
            return reliefScore + navScore + clearScore;
        }

        private bool HasPlayerBuildingNearby(Vector3 center, float radius)
        {
            try
            {
                List<BuildingBlock> blocks = new List<BuildingBlock>();
                Vis.Entities(center, radius, blocks);
                foreach (BuildingBlock block in blocks)
                {
                    if (block != null && !block.IsDestroyed) return true;
                }
            }
            catch
            {
                // Une variation d'API ne doit pas empecher de lancer une partie.
                return false;
            }
            return false;
        }

        private int CountArenaObstacles(Vector3 center, float radius)
        {
            try
            {
                Collider[] hits = Physics.OverlapSphere(center + Vector3.up, radius, LayerMask.GetMask("World", "Construction", "Tree"));
                return hits != null ? hits.Length : 0;
            }
            catch
            {
                return 0;
            }
        }

        private bool TryGetSafeZombiePosition(Vector3 candidate, float navRange, out Vector3 result)
        {
            float terrain = TerrainMeta.HeightMap.GetHeight(candidate);
            float water = TerrainMeta.WaterMap.GetHeight(candidate);
            // 3m au-dessus de la mer, et non -1 : WaterMap ne couvre que les lacs
            // et rivieres, jamais l'ocean, donc elle ne rattrapait pas un terrain
            // immerge. Le seuil de -1 acceptait explicitement du sol sous l'eau.
            if (terrain < 3f || terrain <= water + 2f || IsNearMonument(candidate, 120f))
            {
                result = Vector3.zero;
                return false;
            }
            candidate.y = terrain + 1f;
            return TryGetNavigablePosition(candidate, navRange, out result);
        }

        private bool IsNearMonument(Vector3 position, float distance)
        {
            if (TerrainMeta.Path == null || TerrainMeta.Path.Monuments == null) return false;
            float distanceSquared = distance * distance;
            foreach (MonumentInfo monument in TerrainMeta.Path.Monuments)
            {
                if (monument == null) continue;
                Vector3 delta = monument.transform.position - position;
                delta.y = 0f;
                if (delta.sqrMagnitude < distanceSquared) return true;
            }
            return false;
        }

        private Vector3 GetZombiePlayerSpawn()
        {
            for (int attempt = 0; attempt < 12; attempt++)
            {
                Vector2 offset = UnityEngine.Random.insideUnitCircle * 8f;
                Vector3 candidate = _zombieArenaCenter + new Vector3(offset.x, 0f, offset.y);
                Vector3 navigable;
                if (TryGetNavigablePosition(candidate, 10f, out navigable))
                {
                    navigable.y += 0.5f;
                    return navigable;
                }
            }
            return _zombieArenaCenter + Vector3.up;
        }

        private bool FindZombieEnemySpawn(out Vector3 result)
        {
            for (int attempt = 0; attempt < 24; attempt++)
            {
                Vector2 direction = UnityEngine.Random.insideUnitCircle.normalized;
                float radius = UnityEngine.Random.Range(Mathf.Max(22f, _config.RayonApparitionZombie - 10f), _config.RayonApparitionZombie + 12f);
                Vector3 candidate = _zombieArenaCenter + new Vector3(direction.x, 0f, direction.y) * radius;
                float terrain = TerrainMeta.HeightMap.GetHeight(candidate);
                float water = TerrainMeta.WaterMap.GetHeight(candidate);
                if (terrain < 1f || terrain <= water + 1f) continue;
                candidate.y = terrain + 1f;
                if (TryGetNavigablePosition(candidate, 18f, out result)) return true;
            }
            result = Vector3.zero;
            return false;
        }

        private bool TryGetNavigablePosition(Vector3 candidate, float range, out Vector3 result)
        {
            NavMeshHit hit;
            if (NavMesh.SamplePosition(candidate, out hit, range, NavMesh.AllAreas))
            {
                result = hit.position;
                float water = TerrainMeta.WaterMap.GetHeight(result);
                if (result.y < 1f || result.y <= water + 0.5f)
                {
                    result = Vector3.zero;
                    return false;
                }
                return true;
            }
            result = Vector3.zero;
            return false;
        }

        private bool PlaceNpcOnNavMesh(BasePlayer npc, Vector3 position)
        {
            NPCPlayer ai = npc as NPCPlayer;
            if (ai == null || ai.NavAgent == null) return false;
            if (ai.NavAgent.isOnNavMesh) return true;
            NavMeshHit agentHit;
            return ai.NavAgent.SamplePosition(position, out agentHit, 40f, false) && ai.NavAgent.Warp(agentHit.position);
        }

        private void GiveZombieKit(BasePlayer player)
        {
            RemoveZombieKit(player);
            GiveZombieItem(player, "smg.thompson", 1, "Thompson de survie");
            GiveZombieItem(player, "ammo.pistol", 192, "Munitions");
            GiveZombieItem(player, "syringe.medical", 4, "Soins");
            player.Heal(100f);
        }

        /// <summary>
        /// Donne un objet marque du prefixe du mode. player.GiveItem laisse tomber
        /// l'objet au sol quand l'inventaire est plein : il sort alors du suivi par
        /// prefixe et n'est plus jamais nettoye. On passe donc par
        /// inventory.GiveItem, qui echoue proprement, et on detruit l'objet refuse.
        /// </summary>
        private bool GiveTrackedItem(BasePlayer player, string shortname, int amount, string prefix, string name)
        {
            if (player == null || player.inventory == null) return false;
            Item item = ItemManager.CreateByName(shortname, amount);
            if (item == null) return false;
            item.name = prefix + name;
            if (item.hasCondition) item.condition = item.maxCondition;

            if (!player.inventory.GiveItem(item))
            {
                item.Remove();
                SendReply(player, "<color=#e76a4c>Inventaire plein</color> : libere de la place, l'objet n'a pas ete donne.");
                return false;
            }
            return true;
        }

        private void GiveZombieItem(BasePlayer player, string shortname, int amount, string name)
        {
            if (!GiveTrackedItem(player, shortname, amount, ZombieItemPrefix, name)) return;

            if (shortname == "smg.thompson")
            {
                Item item = FindZombieItem(player, ZombieItemPrefix + name);
                BaseProjectile projectile = item != null ? item.GetHeldEntity() as BaseProjectile : null;
                ItemDefinition ammo = ItemManager.FindItemDefinition("ammo.pistol");
                if (projectile != null && projectile.primaryMagazine != null)
                {
                    if (ammo != null) projectile.primaryMagazine.ammoType = ammo;
                    projectile.primaryMagazine.contents = projectile.primaryMagazine.capacity;
                    projectile.SendNetworkUpdateImmediate();
                }
            }
        }

        private Item FindZombieItem(BasePlayer player, string exactName)
        {
            foreach (Item item in EnumerateInventory(player))
            {
                if (item != null && string.Equals(item.name, exactName, StringComparison.Ordinal)) return item;
            }
            return null;
        }

        private void GiveZombieBuildItem(BasePlayer player, string shortname, int amount, string name)
        {
            GiveTrackedItem(player, shortname, amount, ZombieBuildPrefix, name);
        }

        private int ZombieCredits(ulong userId)
        {
            int credits;
            return _zombieCredits.TryGetValue(userId, out credits) ? credits : 0;
        }

        private List<Item> EnumerateInventory(BasePlayer player)
        {
            List<Item> items = new List<Item>();
            if (player == null || player.inventory == null) return items;
            if (player.inventory.containerMain != null) items.AddRange(player.inventory.containerMain.itemList);
            if (player.inventory.containerBelt != null) items.AddRange(player.inventory.containerBelt.itemList);
            if (player.inventory.containerWear != null) items.AddRange(player.inventory.containerWear.itemList);
            return items;
        }

        private void RemoveItemsWithPrefix(BasePlayer player, string prefix)
        {
            foreach (Item item in EnumerateInventory(player))
            {
                if (item != null && !string.IsNullOrEmpty(item.name) && item.name.StartsWith(prefix, StringComparison.Ordinal)) item.Remove();
            }
        }

        private void RemoveZombieKit(BasePlayer player)
        {
            RemoveItemsWithPrefix(player, ZombieItemPrefix);
        }

        private void RemoveZombieBuildItems(BasePlayer player)
        {
            RemoveItemsWithPrefix(player, ZombieBuildPrefix);
        }

        private void CleanupWaveSets()
        {
            _waveEnemies.RemoveWhere(enemy => enemy == null || enemy.IsDestroyed);
            _waveBosses.RemoveWhere(enemy => enemy == null || enemy.IsDestroyed);
            foreach (BasePlayer enemy in _waveDamageMultipliers.Keys.Where(enemy => enemy == null || enemy.IsDestroyed).ToArray()) _waveDamageMultipliers.Remove(enemy);
        }

        [ChatCommand("stats")]
        private void CommandStats(BasePlayer player, string command, string[] args)
        {
            PlayerProgress progress = EnsurePlayer(player.userID);
            SendReply(player, $"<color=#ffd479>Niveau {progress.Niveau}</color> — XP {progress.Experience}/{XpForNextLevel(progress.Niveau)} — {progress.Pieces} pieces — {progress.PointsCompetence} point(s) de competence");
        }

        [ChatCommand("balance")]
        private void CommandBalance(BasePlayer player, string command, string[] args)
        {
            SendReply(player, $"Solde : <color=#ffd479>{EnsurePlayer(player.userID).Pieces} pieces</color>");
        }

        [ChatCommand("quest")]
        private void CommandQuest(BasePlayer player, string command, string[] args)
        {
            PlayerProgress progress = EnsurePlayer(player.userID);
            ResetQuestIfNeeded(progress);
            string state = progress.QueteReclamee ? "terminee et reclamee" : $"{progress.ProgressionQuete}/{_config.ObjectifQueteQuotidienne} ennemis";
            SendReply(player, $"Quete du jour : eliminer {_config.ObjectifQueteQuotidienne} ennemis — {state}. Recompense : {_config.RecompenseQuetePieces} pieces et {_config.RecompenseQueteExperience} XP.");
        }

        [ChatCommand("claim")]
        private void CommandClaim(BasePlayer player, string command, string[] args)
        {
            PlayerProgress progress = EnsurePlayer(player.userID);
            ResetQuestIfNeeded(progress);
            if (progress.QueteReclamee)
            {
                SendReply(player, "Tu as deja reclame la quete du jour.");
                return;
            }
            if (progress.ProgressionQuete < _config.ObjectifQueteQuotidienne)
            {
                SendReply(player, $"Quete incomplete : {progress.ProgressionQuete}/{_config.ObjectifQueteQuotidienne}.");
                return;
            }

            progress.QueteReclamee = true;
            Award(player, _config.RecompenseQueteExperience, _config.RecompenseQuetePieces, "Quete quotidienne");
            SaveData();
        }

        [ChatCommand("skills")]
        private void CommandSkills(BasePlayer player, string command, string[] args)
        {
            PlayerProgress progress = EnsurePlayer(player.userID);
            SendReply(player, $"Competences — vitalite {progress.Vitalite}/5, puissance {progress.Puissance}/5, recolte {progress.Recolte}/5. Points disponibles : {progress.PointsCompetence}.");
            SendReply(player, "Utilise /skill vitalite, /skill puissance ou /skill recolte.");
        }

        [ChatCommand("skill")]
        private void CommandSkill(BasePlayer player, string command, string[] args)
        {
            if (args.Length == 0)
            {
                CommandSkills(player, command, args);
                return;
            }

            PlayerProgress progress = EnsurePlayer(player.userID);
            if (progress.PointsCompetence <= 0)
            {
                SendReply(player, "Tu n'as pas de point de competence disponible.");
                return;
            }

            string skill = args[0].ToLowerInvariant();
            int current;
            if (skill == "vitalite") current = progress.Vitalite;
            else if (skill == "puissance") current = progress.Puissance;
            else if (skill == "recolte") current = progress.Recolte;
            else
            {
                SendReply(player, "Competence inconnue : vitalite, puissance ou recolte.");
                return;
            }

            if (current >= 5)
            {
                SendReply(player, "Cette competence est deja au niveau maximum.");
                return;
            }

            if (skill == "vitalite") progress.Vitalite++;
            else if (skill == "puissance") progress.Puissance++;
            else progress.Recolte++;
            progress.PointsCompetence--;
            SaveData();
            SendReply(player, $"Competence <color=#ffd479>{skill}</color> amelioree.");
        }

        [ChatCommand("shop")]
        private void CommandShop(BasePlayer player, string command, string[] args)
        {
            SendReply(player, "<color=#d6a84b>Boutique de progression</color> — utilise /buy nom [quantite]");
            foreach (KeyValuePair<string, ShopEntry> entry in _config.Boutique)
            {
                SendReply(player, $"{entry.Key} : {entry.Value.Nom} — {entry.Value.Prix} pieces");
            }
        }

        [ChatCommand("buy")]
        private void CommandBuy(BasePlayer player, string command, string[] args)
        {
            if (args.Length == 0)
            {
                CommandShop(player, command, args);
                return;
            }

            ShopEntry offer;
            string key = args[0].ToLowerInvariant();
            if (!_config.Boutique.TryGetValue(key, out offer))
            {
                SendReply(player, "Objet inconnu. Tape /shop.");
                return;
            }

            int count = 1;
            if (args.Length > 1)
            {
                int parsed;
                if (int.TryParse(args[1], out parsed)) count = Mathf.Clamp(parsed, 1, 20);
            }

            PlayerProgress progress = EnsurePlayer(player.userID);
            int totalPrice = offer.Prix * count;
            if (progress.Pieces < totalPrice)
            {
                SendReply(player, $"Il te faut {totalPrice} pieces. Solde : {progress.Pieces}.");
                return;
            }

            Item item = ItemManager.CreateByName(offer.Shortname, offer.Quantite * count);
            if (item == null)
            {
                SendReply(player, "Impossible de creer cet objet. Previens un administrateur.");
                return;
            }

            progress.Pieces -= totalPrice;
            player.GiveItem(item);
            SaveData();
            SendReply(player, $"Achat : {offer.Nom} x{count}. Nouveau solde : {progress.Pieces} pieces.");
        }

        [ChatCommand("rpgspawn")]
        private void CommandSpawn(BasePlayer player, string command, string[] args)
        {
            if (!player.IsAdmin && !permission.UserHasPermission(player.UserIDString, AdminPermission))
            {
                SendReply(player, "Commande reservee aux administrateurs.");
                return;
            }
            if (args.Length == 0)
            {
                SendReply(player, "Utilise /rpgspawn zombie|scientifique|boss [nombre].");
                return;
            }

            int count = 1;
            if (args.Length > 1)
            {
                int parsed;
                if (int.TryParse(args[1], out parsed)) count = Mathf.Clamp(parsed, 1, 20);
            }

            string type = args[0].ToLowerInvariant();
            for (int i = 0; i < count; i++)
            {
                if (type == "zombie") SpawnNpcNear(player, ZombiePrefab, "Zombie", 180f, _zombies);
                else if (type == "scientifique" || type == "npc") SpawnNpcNear(player, ScientistPrefab, "Scientifique", 250f, _scientists);
                else if (type == "boss") SpawnNpcNear(player, BossPrefab, "Commandant irradie", 2500f, _bosses);
                else
                {
                    SendReply(player, "Type inconnu : zombie, scientifique ou boss.");
                    return;
                }
            }
            SendReply(player, $"Apparition de {count} {type}(s).");
        }

        private void MaintainPopulation()
        {
            CleanupNpcSet(_zombies);
            CleanupNpcSet(_scientists);
            CleanupNpcSet(_bosses);

            List<BasePlayer> rpgPlayers = BasePlayer.activePlayerList
                .Where(player => player != null && player.IsConnected && !IsInGunGame(player) && !IsInDuel(player) && !IsInCompetitiveMode(player) && !_zombieModePlayers.Contains(player.userID))
                .ToList();

            if (rpgPlayers.Count == 0)
            {
                return;
            }

            BasePlayer player = rpgPlayers[UnityEngine.Random.Range(0, rpgPlayers.Count)];
            if (_zombies.Count < _config.ZombiesSimultanes)
                SpawnNpcNear(player, ZombiePrefab, "Zombie", 180f, _zombies);
            if (_scientists.Count < _config.ScientifiquesSimultanes)
                SpawnNpcNear(player, ScientistPrefab, "Scientifique", 250f, _scientists);
            if (_bosses.Count < _config.BossSimultanes)
                SpawnNpcNear(player, BossPrefab, "Commandant irradie", 2500f, _bosses);
        }

        private void SpawnNpcNear(BasePlayer player, string prefab, string name, float health, HashSet<BasePlayer> bucket)
        {
            if (player == null || !player.IsConnected || IsInGunGame(player) || IsInDuel(player) || IsInCompetitiveMode(player))
            {
                return;
            }

            Vector3 position = Vector3.zero;
            bool positionFound = false;
            for (int attempt = 0; attempt < 16; attempt++)
            {
                Vector2 circle = UnityEngine.Random.insideUnitCircle.normalized;
                float distance = UnityEngine.Random.Range(_config.DistanceMinimale, _config.DistanceMaximale);
                Vector3 candidate = player.transform.position + new Vector3(circle.x, 0f, circle.y) * distance;
                float terrain = TerrainMeta.HeightMap.GetHeight(candidate);
                float water = TerrainMeta.WaterMap.GetHeight(candidate);
                if (terrain < 1f || terrain <= water + 1f) continue;
                candidate.y = terrain + 1f;
                if (TryGetNavigablePosition(candidate, 18f, out position))
                {
                    positionFound = true;
                    break;
                }
            }
            if (!positionFound)
            {
                PrintWarning($"Aucun point NavMesh valide trouve pres de {player.displayName} pour {name}.");
                return;
            }

            BaseEntity entity = GameManager.server.CreateEntity(prefab, position, Quaternion.identity, true);
            BasePlayer npc = entity as BasePlayer;
            if (npc == null)
            {
                if (entity != null) entity.Kill();
                PrintWarning($"Impossible de creer le PNJ depuis {prefab}");
                return;
            }

            npc.enableSaving = false;
            npc.displayName = name;
            npc.Spawn();
            npc.InitializeHealth(health, health);
            if (!PlaceNpcOnNavMesh(npc, position))
            {
                npc.Kill();
                PrintWarning($"Le PNJ {name} ne peut pas utiliser le NavMesh a cet endroit.");
                return;
            }
            bucket.Add(npc);
        }

        private bool IsInGunGame(BasePlayer player)
        {
            object hook = Interface.CallHook("IsGunGameParticipant", player);
            return hook is bool && (bool)hook;
        }

        private bool IsInDuel(BasePlayer player)
        {
            object hook = Interface.CallHook("IsDuelParticipant", player);
            return hook is bool && (bool)hook;
        }

        private bool IsInCompetitiveMode(BasePlayer player)
        {
            object hook = Interface.CallHook("IsCompetitiveModeParticipant", player);
            if (hook is bool && (bool)hook) return true;
            object towerDefenseHook = Interface.CallHook("IsTowerDefenseParticipant", player);
            if (towerDefenseHook is bool && (bool)towerDefenseHook) return true;
            object trainingHook = Interface.CallHook("IsTrainingParticipant", player);
            if (trainingHook is bool && (bool)trainingHook) return true;
            object battlefieldHook = Interface.CallHook("IsBattlefieldParticipant", player);
            return battlefieldHook is bool && (bool)battlefieldHook;
        }

        private void OnTowerDefenseCompleted(BasePlayer player, int wave, int coreHealth)
        {
            if (!IsHumanPlayer(player)) return;
            int healthBonus = Mathf.Max(0, coreHealth / 10);
            Award(player, 1200 + healthBonus, 2500 + healthBonus * 2, $"Victoire Tower Defense vague {wave}");
        }

        private void OnTowerDefenseEndlessMilestone(BasePlayer player, int wave, int coreHealth)
        {
            if (!IsHumanPlayer(player)) return;
            int milestone = Mathf.Max(1, wave / 10);
            Award(player, 400 + milestone * 250, 800 + milestone * 500, $"Palier Tower Defense Endless vague {wave}");
        }

        private void Award(BasePlayer player, int xp, int coins, string source)
        {
            PlayerProgress progress = EnsurePlayer(player.userID);
            progress.Experience += xp;
            progress.Pieces += coins;
            int levelsGained = 0;

            while (progress.Experience >= XpForNextLevel(progress.Niveau))
            {
                progress.Experience -= XpForNextLevel(progress.Niveau);
                progress.Niveau++;
                progress.PointsCompetence++;
                levelsGained++;
            }

            SendReply(player, $"{source} : <color=#8fd694>+{xp} XP</color>, <color=#ffd479>+{coins} pieces</color>.");
            if (levelsGained > 0)
            {
                SendReply(player, $"<color=#ffd479>Niveau {progress.Niveau} atteint !</color> Tu gagnes {levelsGained} point(s) de competence.");
            }
            SaveData();
        }

        private void AdvanceQuest(BasePlayer player)
        {
            PlayerProgress progress = EnsurePlayer(player.userID);
            ResetQuestIfNeeded(progress);
            if (progress.QueteReclamee || progress.ProgressionQuete >= _config.ObjectifQueteQuotidienne)
            {
                return;
            }

            progress.ProgressionQuete++;
            if (progress.ProgressionQuete >= _config.ObjectifQueteQuotidienne)
            {
                SendReply(player, "<color=#ffd479>Quete quotidienne terminee !</color> Tape /claim pour recevoir la recompense.");
            }
        }

        private void OnGunGameCompleted(BasePlayer player)
        {
            if (!IsHumanPlayer(player))
            {
                return;
            }

            Award(player, 750, 1500, "Victoire Gun Game");
        }

        private void OnDuelCompleted(BasePlayer player, int teamSize)
        {
            if (!IsHumanPlayer(player)) return;
            int size = Mathf.Clamp(teamSize, 1, 4);
            Award(player, _config.RecompenseDuelExperienceBase + size * _config.RecompenseDuelExperienceParTaille, _config.RecompenseDuelPiecesBase + size * _config.RecompenseDuelPiecesParTaille, $"Victoire Duel {size}v{size}");
        }

        private void OnDuelTournamentWon(BasePlayer player)
        {
            if (!IsHumanPlayer(player)) return;
            Award(player, _config.RecompenseTournoiExperience, _config.RecompenseTournoiPieces, "Champion du tournoi Duel");
        }

        private void OnCompetitiveModeCompleted(BasePlayer player, string mode)
        {
            if (!IsHumanPlayer(player)) return;
            string label = string.IsNullOrEmpty(mode) ? "Mode competitif" : mode.ToUpperInvariant();
            Award(player, _config.RecompenseModeExperience, _config.RecompenseModePieces, $"Victoire {label}");
        }

        private PlayerProgress EnsurePlayer(ulong userId)
        {
            PlayerProgress progress;
            if (!_storedData.Joueurs.TryGetValue(userId, out progress))
            {
                progress = new PlayerProgress();
                _storedData.Joueurs[userId] = progress;
            }
            ResetQuestIfNeeded(progress);
            return progress;
        }

        private void ResetQuestIfNeeded(PlayerProgress progress)
        {
            string today = DateTime.UtcNow.ToString("yyyy-MM-dd");
            if (progress.DateQuete == today)
            {
                return;
            }
            progress.DateQuete = today;
            progress.ProgressionQuete = 0;
            progress.QueteReclamee = false;
        }

        private int XpForNextLevel(int level)
        {
            return 100 + (level - 1) * 75;
        }

        private bool IsHumanPlayer(BasePlayer player)
        {
            return player != null && !player.IsNpc && player.userID.IsSteamId();
        }

        private void CleanupNpcSet(HashSet<BasePlayer> set)
        {
            set.RemoveWhere(npc => npc == null || npc.IsDestroyed);
        }

        private void RemoveSpawnedNpcs()
        {
            foreach (BasePlayer npc in _zombies.Concat(_scientists).Concat(_bosses).ToArray())
            {
                if (npc != null && !npc.IsDestroyed)
                {
                    npc.Kill();
                }
            }
            _zombies.Clear();
            _scientists.Clear();
            _bosses.Clear();
        }

        private void LoadData()
        {
            try
            {
                _storedData = Interface.Oxide.DataFileSystem.ReadObject<StoredData>(Name);
            }
            catch
            {
                _storedData = new StoredData();
            }
            if (_storedData == null || _storedData.Joueurs == null)
            {
                _storedData = new StoredData();
            }
        }

        private void SaveData()
        {
            Interface.Oxide.DataFileSystem.WriteObject(Name, _storedData);
        }
    }
}
