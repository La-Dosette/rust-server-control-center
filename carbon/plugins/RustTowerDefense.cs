using System;
using System.Collections.Generic;
using System.Linq;
using Oxide.Core;
using Rust;
using UnityEngine;

namespace Oxide.Plugins
{
    [Info("RustTowerDefense", "OpenAI", "1.1.0")]
    [Description("Tower Defense cooperatif normal ou endless avec routes fixes sans NavMesh, construction, tours, vagues et boss.")]
    public class RustTowerDefense : RustPlugin
    {
        private const string ItemPrefix = "Tower Defense - ";
        private const string EnemyPrefab = "assets/prefabs/npc/scarecrow/scarecrow.prefab";
        private const string BossPrefab = "assets/rust.ai/agents/npcplayer/humannpc/scientist/scientistnpc_heavy.prefab";
        private const string WallPrefab = "assets/prefabs/building/wall.external.high.stone/wall.external.high.stone.prefab";
        private const string ConcretePrefab = "assets/prefabs/deployable/barricades/barricade.concrete.prefab";
        private const string RugPrefab = "assets/prefabs/deployable/rug/rug.deployed.prefab";
        private const string CorePrefab = "assets/prefabs/deployable/vendingmachine/vendingmachine.deployed.prefab";
        private const string MachineTowerPrefab = "assets/prefabs/npc/autoturret/autoturret_deployed.prefab";
        private const string SniperTowerPrefab = "assets/prefabs/deployable/single shot trap/guntrap.deployed.prefab";
        private const string SlowTowerPrefab = "assets/prefabs/deployable/search light/searchlight.deployed.prefab";

        private const int MaximumWaves = 10;
        private const int MaximumCoreHealth = 3000;
        private const float EnemyTickSeconds = 0.15f;
        // Le niveau de la mer est a 0 dans Rust : 3m de marge garantissent une
        // plage seche, y compris a maree de vagues.
        private const float MinimumGroundHeight = 3f;

        private readonly HashSet<ulong> _participants = new HashSet<ulong>();
        private readonly HashSet<ulong> _alive = new HashSet<ulong>();
        private readonly HashSet<ulong> _readyPlayers = new HashSet<ulong>();
        private readonly Dictionary<ulong, Vector3> _returnPositions = new Dictionary<ulong, Vector3>();
        private readonly Dictionary<ulong, int> _credits = new Dictionary<ulong, int>();
        private readonly Dictionary<BasePlayer, EnemyState> _enemies = new Dictionary<BasePlayer, EnemyState>();
        private readonly List<BaseEntity> _defenses = new List<BaseEntity>();
        private readonly List<TowerState> _towers = new List<TowerState>();
        private readonly List<BaseEntity> _arenaEntities = new List<BaseEntity>();
        private readonly List<Vector3[]> _lanes = new List<Vector3[]>();

        private Vector3 _arenaCenter;
        private BaseEntity _coreEntity;
        private bool _running;
        private bool _waveActive;
        private bool _buildPhase;
        private bool _stopping;
        private int _wave;
        private int _spawnRemaining;
        private int _coreHealth;
        private int _sessionId;
        private float _buildEndsAt;
        private bool _endless;
        private StoredData _data;

        private class StoredData
        {
            public Dictionary<ulong, int> MeilleuresVaguesEndless = new Dictionary<ulong, int>();
            public Dictionary<ulong, string> Noms = new Dictionary<ulong, string>();
        }

        private class EnemyState
        {
            public int Lane;
            public int Waypoint = 1;
            public float Speed;
            public float CoreDamage;
            public int Credits;
            public float NextAttackAt;
            public float SlowedUntil;
            public ulong LastTowerOwner;
            public bool Boss;
        }

        private class TowerState
        {
            public BaseEntity Entity;
            public string Type;
            public ulong Owner;
            public int Level = 1;
            public float Damage;
            public float Range;
            public float Interval;
            public float NextShotAt;
        }

        private void Init()
        {
            try { _data = Interface.Oxide.DataFileSystem.ReadObject<StoredData>(Name) ?? new StoredData(); }
            catch { _data = new StoredData(); }
        }

        private void OnServerInitialized()
        {
            timer.Every(EnemyTickSeconds, TickEnemies);
            timer.Every(0.2f, TickTowers);
            Puts("Tower Defense pret : construction, routes fixes, tours, vagues et boss.");
        }

        private void Unload()
        {
            StopMode("", true);
            SaveData();
        }

        private object ForceLeaveMode(BasePlayer player)
        {
            if (player == null || !_participants.Contains(player.userID)) return null;
            LeaveMode(player, true);
            return true;
        }

        private object GetTowerDefensePlayerStats(BasePlayer player)
        {
            if (player == null) return null;
            int best;
            if (!_data.MeilleuresVaguesEndless.TryGetValue(player.userID, out best)) best = 0;
            return $"record_endless={best}";
        }

        private object IsTowerDefenseParticipant(BasePlayer player)
        {
            return player != null && _participants.Contains(player.userID);
        }

        private object IsTowerDefenseEnemy(BasePlayer player)
        {
            return player != null && _enemies.ContainsKey(player);
        }

        private object JoinTowerDefenseFromLobby(BasePlayer player)
        {
            if (player == null) return false;
            if (!_participants.Contains(player.userID)) JoinMode(player, false);
            return _participants.Contains(player.userID);
        }

        private object GetTowerDefenseDashboardStatus()
        {
            CleanupEntities();
            int seconds = _buildPhase ? Mathf.Max(0, Mathf.CeilToInt(_buildEndsAt - Time.realtimeSinceStartup)) : 0;
            return $"actif={_running} mode={(_endless ? "ENDLESS" : "10-VAGUES")} vague={WaveDisplay()} combat={_waveActive} construction={_buildPhase} tempsConstruction={seconds}s joueurs={_participants.Count} vivants={_alive.Count} ennemis={_enemies.Count}+{_spawnRemaining} defenses={_defenses.Count} tours={_towers.Count} coeur={_coreHealth}/{MaximumCoreHealth} recordEndless={BestEndlessWave()}";
        }

        [ChatCommand("td")]
        private void CommandTowerDefense(BasePlayer player, string command, string[] args)
        {
            if (player == null) return;
            string action = args.Length > 0 ? args[0].ToLowerInvariant() : string.Empty;
            if (_participants.Contains(player.userID))
            {
                if (action == "status") { SendStatus(player); return; }
                if (action == "endless" || action == "normal") { SendReply(player, $"La partie actuelle est en mode {(_endless ? "ENDLESS" : "10 VAGUES")}. Quitte avec /td avant d'en creer une autre."); return; }
                LeaveMode(player, true);
                return;
            }
            JoinMode(player, action == "endless" || action == "infini");
        }

        [ChatCommand("tdtop")]
        private void CommandTop(BasePlayer player, string command, string[] args)
        {
            List<KeyValuePair<ulong, int>> top = _data.MeilleuresVaguesEndless.OrderByDescending(pair => pair.Value).ThenBy(pair => pair.Key).Take(10).ToList();
            if (top.Count == 0) { SendReply(player, "Aucun record Tower Defense Endless pour le moment."); return; }
            SendReply(player, "<color=#ffd479>TOP TOWER DEFENSE ENDLESS</color>");
            for (int index = 0; index < top.Count; index++)
            {
                string name;
                if (!_data.Noms.TryGetValue(top[index].Key, out name)) name = top[index].Key.ToString();
                SendReply(player, $"{index + 1}. {name} - vague {top[index].Value}");
            }
        }

        [ChatCommand("tdstatus")]
        private void CommandStatus(BasePlayer player, string command, string[] args)
        {
            SendStatus(player);
        }

        [ChatCommand("tdshop")]
        private void CommandShop(BasePlayer player, string command, string[] args)
        {
            if (!IsParticipant(player)) { SendReply(player, "Rejoins d'abord le Tower Defense avec /td."); return; }
            int credits = Credits(player.userID);
            SendReply(player, $"<color=#e65a38>BOUTIQUE TD</color> - Credits : <color=#9fd36f>{credits}</color>{(_buildPhase ? " - phase de CONSTRUCTION" : " - phase de COMBAT")}");

            SendReply(player, $"<color=#ffd479>TOURS</color> (construction uniquement, visees a 4m devant toi) : {ShopLine(credits, "mitrailleuse", 200)}, {ShopLine(credits, "sniper", 350)}, {ShopLine(credits, "slow", 250)}, {ShopLine(credits, "tesla", 400)}, {ShopLine(credits, "mortier", 500)}");
            SendReply(player, $"<color=#ffd479>DEFENSES</color> (construction) : {ShopLine(credits, "barricade", 80)}, {ShopLine(credits, "herses", 120)}, {ShopLine(credits, "ressources", 100)}, {ShopLine(credits, "mur", 150)}");
            SendReply(player, $"<color=#ffd479>SOUTIEN</color> (a tout moment) : {ShopLine(credits, "soins", 60)}, {ShopLine(credits, "munitions", 70)}, {ShopLine(credits, "armure", 180)}, {ShopLine(credits, "repair", 250)}");
            SendReply(player, "/tdupgrade pres d'une tour : niveau suivant pour 150 x niveau. /tdready pour lancer la vague plus tot.");
        }

        /// <summary>
        /// Grise ce que le joueur ne peut pas s'offrir : la boutique disait
        /// seulement les prix, sans jamais indiquer ce qui etait a portee.
        /// </summary>
        private string ShopLine(int credits, string offer, int price)
        {
            return credits >= price
                ? $"<color=#9fd36f>{offer}</color> ({price})"
                : $"<color=#7a736a>{offer} ({price})</color>";
        }

        [ChatCommand("tdbuy")]
        private void CommandBuy(BasePlayer player, string command, string[] args)
        {
            if (!IsParticipant(player)) { SendReply(player, "Rejoins d'abord le Tower Defense avec /td."); return; }
            if (args.Length == 0) { CommandShop(player, "tdshop", new string[0]); return; }
            string offer = args[0].ToLowerInvariant();

            // Le soutien reste accessible pendant la vague : se retrouver a court
            // de soins ou de munitions en plein combat, sans aucun recours malgre
            // des credits en poche, etait la principale frustration du mode.
            if (offer == "soins" || offer == "heal")
            {
                if (!SpendCredits(player, 60)) return;
                GiveNamedItem(player, "syringe.medical", 4, "Seringues");
                SendReply(player, "4 seringues ajoutees.");
                return;
            }
            if (offer == "munitions" || offer == "ammo")
            {
                if (!SpendCredits(player, 70)) return;
                GiveNamedItem(player, "ammo.rifle", 128, "Munitions");
                SendReply(player, "128 munitions ajoutees.");
                return;
            }
            if (offer == "armure" || offer == "armor")
            {
                if (!SpendCredits(player, 180)) return;
                GiveNamedItem(player, "metal.facemask", 1, "Casque en metal");
                GiveNamedItem(player, "metal.plate.torso", 1, "Plastron en metal");
                SendReply(player, "Armure lourde ajoutee.");
                return;
            }
            if (offer == "repair" || offer == "reparer")
            {
                if (_coreHealth >= MaximumCoreHealth) { SendReply(player, "Le coeur est deja au maximum."); return; }
                if (!SpendCredits(player, 250)) return;
                int restoredCore = Mathf.Min(500, MaximumCoreHealth - _coreHealth);
                _coreHealth += restoredCore;
                Broadcast($"{player.displayName} repare le coeur de {restoredCore} PV : {_coreHealth}/{MaximumCoreHealth}.");
                return;
            }

            // Tout ce qui se pose au sol reste reserve a la construction.
            if (!_buildPhase)
            {
                SendReply(player, "<color=#e76a4c>Phase de combat</color> : tours et defenses seulement pendant la construction.");
                SendReply(player, "Disponible maintenant : soins (60), munitions (70), armure (180), repair (250).");
                return;
            }

            if (offer == "mitrailleuse" || offer == "turret") { BuyTower(player, "mitrailleuse", 200, MachineTowerPrefab, 34f, 25f, 0.45f); return; }
            if (offer == "sniper") { BuyTower(player, "sniper", 350, SniperTowerPrefab, 125f, 43f, 1.75f); return; }
            if (offer == "slow" || offer == "ralentissement") { BuyTower(player, "slow", 250, SlowTowerPrefab, 9f, 19f, 0.7f); return; }
            if (offer == "tesla") { BuyTower(player, "tesla", 400, SlowTowerPrefab, 62f, 21f, 0.9f); return; }
            if (offer == "mortier") { BuyTower(player, "mortier", 500, SniperTowerPrefab, 190f, 55f, 2.6f); return; }
            if (offer == "barricade")
            {
                if (!SpendCredits(player, 80)) return;
                GiveNamedItem(player, "barricade.wood", 3, "Barricades de defense");
                SendReply(player, "3 barricades ajoutees. Place-les avant la prochaine vague.");
                return;
            }
            if (offer == "herses" || offer == "spikes")
            {
                if (!SpendCredits(player, 120)) return;
                GiveNamedItem(player, "spikes.floor", 4, "Herses");
                SendReply(player, "4 herses ajoutees : elles blessent les ennemis qui les traversent.");
                return;
            }
            if (offer == "mur" || offer == "wall")
            {
                if (!SpendCredits(player, 150)) return;
                GiveNamedItem(player, "barricade.concrete", 3, "Murs de beton");
                SendReply(player, "3 murs de beton ajoutes : bien plus resistants que le bois.");
                return;
            }
            if (offer == "ressources" || offer == "resources")
            {
                if (!SpendCredits(player, 100)) return;
                GiveNamedItem(player, "wood", 5000, "Bois de construction");
                GiveNamedItem(player, "stones", 5000, "Pierre de construction");
                SendReply(player, "Pack de construction ajoute.");
                return;
            }
            SendReply(player, $"<color=#e76a4c>Offre inconnue :</color> {offer}");
            CommandShop(player, "tdshop", new string[0]);
        }

        [ChatCommand("tdupgrade")]
        private void CommandUpgrade(BasePlayer player, string command, string[] args)
        {
            if (!IsParticipant(player) || !_buildPhase) { SendReply(player, "Ameliore les tours pendant la construction."); return; }
            TowerState tower = _towers.Where(candidate => IsValid(candidate.Entity) && HorizontalDistance(candidate.Entity.transform.position, player.transform.position) <= 5f)
                .OrderBy(candidate => HorizontalDistance(candidate.Entity.transform.position, player.transform.position)).FirstOrDefault();
            if (tower == null) { SendReply(player, "Approche-toi a moins de 5m d'une tour."); return; }
            if (tower.Level >= 4) { SendReply(player, "Cette tour est deja niveau maximum."); return; }
            int price = tower.Level * 150;
            if (!SpendCredits(player, price)) return;
            tower.Level++;
            tower.Damage *= 1.35f;
            tower.Range += 2f;
            tower.Interval = Mathf.Max(0.2f, tower.Interval * 0.9f);
            BaseCombatEntity combat = tower.Entity as BaseCombatEntity;
            if (combat != null)
            {
                float newMaximum = combat.MaxHealth() + 250f;
                combat.InitializeHealth(newMaximum, newMaximum);
                combat.SendNetworkUpdateImmediate();
            }
            SendReply(player, $"Tour {tower.Type} amelioree au niveau {tower.Level}. Degats : {tower.Damage:0}.");
        }

        [ChatCommand("tdready")]
        private void CommandReady(BasePlayer player, string command, string[] args)
        {
            if (!IsParticipant(player) || !_buildPhase) { SendReply(player, "Aucune phase de construction active."); return; }
            _readyPlayers.Add(player.userID);
            Broadcast($"{player.displayName} est pret ({_readyPlayers.Count}/{_participants.Count}).");
            if (_participants.Count > 0 && _participants.All(userId => _readyPlayers.Contains(userId)))
            {
                int session = ++_sessionId;
                timer.Once(0.5f, () => { if (_running && _buildPhase && session == _sessionId) BeginWave(); });
            }
        }

        [ConsoleCommand("td.force")]
        private void ConsoleForce(ConsoleSystem.Arg arg)
        {
            BasePlayer caller = arg.Player();
            if (caller != null && !caller.IsAdmin) { arg.ReplyWith("Commande reservee aux administrateurs."); return; }
            string selector = arg.Args != null && arg.Args.Length > 0 ? arg.Args[0].ToString() : string.Empty;
            BasePlayer target = BasePlayer.activePlayerList.FirstOrDefault(player => string.IsNullOrEmpty(selector) || player.UserIDString == selector || player.displayName.IndexOf(selector, StringComparison.OrdinalIgnoreCase) >= 0);
            if (target == null) { arg.ReplyWith("Joueur connecte introuvable."); return; }
            if (!_participants.Contains(target.userID)) JoinMode(target, false);
            arg.ReplyWith(_participants.Contains(target.userID) ? $"{target.displayName} rejoint le Tower Defense." : "Le joueur est deja dans un autre mode.");
        }

        [ConsoleCommand("td.endless")]
        private void ConsoleEndless(ConsoleSystem.Arg arg)
        {
            BasePlayer caller = arg.Player();
            if (caller != null && !caller.IsAdmin) { arg.ReplyWith("Commande reservee aux administrateurs."); return; }
            string selector = arg.Args != null && arg.Args.Length > 0 ? arg.Args[0].ToString() : string.Empty;
            BasePlayer target = BasePlayer.activePlayerList.FirstOrDefault(player => string.IsNullOrEmpty(selector) || player.UserIDString == selector || player.displayName.IndexOf(selector, StringComparison.OrdinalIgnoreCase) >= 0);
            if (target == null) { arg.ReplyWith("Joueur connecte introuvable."); return; }
            if (!_participants.Contains(target.userID)) JoinMode(target, true);
            arg.ReplyWith(_participants.Contains(target.userID) && _endless ? $"{target.displayName} rejoint le Tower Defense Endless." : "Impossible de lancer Endless : un autre mode est actif.");
        }

        [ConsoleCommand("td.stop")]
        private void ConsoleStop(ConsoleSystem.Arg arg)
        {
            BasePlayer caller = arg.Player();
            if (caller != null && !caller.IsAdmin) { arg.ReplyWith("Commande reservee aux administrateurs."); return; }
            StopMode("Tower Defense arrete par un administrateur.", true);
            arg.ReplyWith("Tower Defense arrete et arene retiree.");
        }

        [ConsoleCommand("td.wave")]
        private void ConsoleWave(ConsoleSystem.Arg arg)
        {
            BasePlayer caller = arg.Player();
            if (caller != null && !caller.IsAdmin) { arg.ReplyWith("Commande reservee aux administrateurs."); return; }
            if (!_running || !_buildPhase) { arg.ReplyWith("Aucune construction Tower Defense active."); return; }
            _sessionId++;
            BeginWave();
            arg.ReplyWith("Vague lancee immediatement.");
        }

        [ConsoleCommand("td.debug")]
        private void ConsoleDebug(ConsoleSystem.Arg arg)
        {
            BasePlayer caller = arg.Player();
            if (caller != null && !caller.IsAdmin) { arg.ReplyWith("Commande reservee aux administrateurs."); return; }
            arg.ReplyWith(GetTowerDefenseDashboardStatus().ToString() + $" centre={_arenaCenter} elementsArene={_arenaEntities.Count}");
        }

        [ConsoleCommand("td.validate")]
        private void ConsoleValidate(ConsoleSystem.Arg arg)
        {
            BasePlayer caller = arg.Player();
            if (caller != null && !caller.IsAdmin) { arg.ReplyWith("Commande reservee aux administrateurs."); return; }
            if (_running) { arg.ReplyWith("Arrete la partie Tower Defense avant l'autotest."); return; }
            bool validateEndless = arg.Args != null && arg.Args.Length > 0 && arg.Args[0].ToString().Equals("endless", StringComparison.OrdinalIgnoreCase);
            _running = true;
            _waveActive = true;
            _buildPhase = false;
            _endless = validateEndless;
            _wave = validateEndless ? 25 : 1;
            _coreHealth = MaximumCoreHealth;
            _sessionId++;
            BuildArena();
            int createdTowers = 0;
            if (CreateValidationTower("mitrailleuse", MachineTowerPrefab, new Vector3(0f, 0f, -18f), 34f, 25f, 0.45f)) createdTowers++;
            if (CreateValidationTower("sniper", SniperTowerPrefab, new Vector3(5f, 0f, 18f), 125f, 43f, 1.75f)) createdTowers++;
            if (CreateValidationTower("slow", SlowTowerPrefab, new Vector3(14f, 0f, 0f), 9f, 19f, 0.7f)) createdTowers++;
            SpawnEnemy(validateEndless);
            BasePlayer validationEnemy = _enemies.Keys.FirstOrDefault();
            Vector3 validationStart = validationEnemy != null ? validationEnemy.transform.position : Vector3.zero;
            timer.Once(3f, () =>
            {
                if (IsValid(validationEnemy)) Puts($"Autotest mouvement sans NavMesh : {HorizontalDistance(validationStart, validationEnemy.transform.position):0.0}m en 3s.");
            });
            arg.ReplyWith($"Autotest TD {(_endless ? "ENDLESS" : "NORMAL")} actif 6 secondes : vague={WaveDisplay()}, arene={_arenaEntities.Count}, tours={createdTowers}/3, ennemis={_enemies.Count}.");
            int session = _sessionId;
            timer.Once(6f, () => { if (_running && session == _sessionId) StopMode("", false); });
        }

        private bool CreateValidationTower(string type, string prefab, Vector3 offset, float damage, float range, float interval)
        {
            BaseEntity entity = GameManager.server.CreateEntity(prefab, Ground(_arenaCenter + offset) + Vector3.up * 0.1f, Quaternion.identity, true);
            if (entity == null) return false;
            entity.enableSaving = false;
            entity.Spawn();
            _defenses.Add(entity);
            _towers.Add(new TowerState { Entity = entity, Type = type, Damage = damage, Range = range, Interval = interval });
            return true;
        }

        private void JoinMode(BasePlayer player, bool endless)
        {
            if (player == null || !player.IsConnected) return;
            if (IsInOtherMode(player)) { SendReply(player, "Quitte d'abord ton autre mode de jeu."); return; }
            if (_running && !_buildPhase) { SendReply(player, "Une vague est en cours. Attends la prochaine construction pour rejoindre."); return; }

            bool newSession = !_running;
            if (newSession)
            {
                _running = true;
                _waveActive = false;
                _buildPhase = false;
                _wave = 0;
                _coreHealth = MaximumCoreHealth;
                _endless = endless;
                _sessionId++;
                BuildArena();
            }

            _participants.Add(player.userID);
            _alive.Add(player.userID);
            _returnPositions[player.userID] = player.transform.position;
            if (!_credits.ContainsKey(player.userID)) _credits[player.userID] = 300;
            _data.Noms[player.userID] = player.displayName;
            SaveData();
            TeleportParticipant(player);
            GiveCombatKit(player);
            SendReply(player, $"<color=#e65a38>TOWER DEFENSE {(_endless ? "ENDLESS" : "10 VAGUES")}</color> - protege le coeur {(_endless ? "le plus longtemps possible" : "pendant 10 vagues")}.");
            SendReply(player, "Construis murs et barricades avec le plan. /tdshop pour les tours, /tdready quand tu es pret, /td pour quitter.");
            if (newSession) StartBuildPhase(60f, "Construction initiale");
            else GiveBuildSupplies(player);
        }

        private void LeaveMode(BasePlayer player, bool returnPlayer)
        {
            if (player == null || !_participants.Remove(player.userID)) return;
            _alive.Remove(player.userID);
            _readyPlayers.Remove(player.userID);
            RemoveModeItems(player);
            if (returnPlayer) ReturnPlayer(player);
            _returnPositions.Remove(player.userID);
            _credits.Remove(player.userID);
            SendReply(player, "Tu as quitte le Tower Defense.");
            if (_participants.Count == 0) StopMode("Tower Defense termine : aucun defenseur.", false);
            else if (_alive.Count == 0 && _waveActive) StopMode("Defaite : tous les defenseurs sont tombes.", true);
        }

        private void StartBuildPhase(float duration, string label)
        {
            if (!_running) return;
            _waveActive = false;
            _buildPhase = true;
            _spawnRemaining = 0;
            _readyPlayers.Clear();
            _buildEndsAt = Time.realtimeSinceStartup + duration;
            int session = ++_sessionId;
            foreach (ulong userId in _participants.ToArray())
            {
                BasePlayer player = FindPlayer(userId);
                if (player == null) continue;
                if (player.IsDead()) player.RespawnAt(GetPlayerSpawn(userId), Quaternion.identity); else player.Teleport(GetPlayerSpawn(userId));
                _alive.Add(userId);
                GiveCombatKit(player);
                GiveBuildSupplies(player);
                SendReply(player, $"<color=#9fd36f>{label.ToUpperInvariant()}</color> - {duration:0}s. Credits : {Credits(userId)}. /tdshop et /tdready.");
            }
            timer.Once(duration, () => { if (_running && _buildPhase && session == _sessionId) BeginWave(); });
        }

        private void BeginWave()
        {
            if (!_running || !_buildPhase) return;
            _sessionId++;
            _buildPhase = false;
            _waveActive = true;
            _readyPlayers.Clear();
            _wave++;
            int scaledWave = Mathf.Min(_wave, 30);
            _spawnRemaining = Mathf.Min(72, 5 + scaledWave * 2 + _participants.Count * 2 + Mathf.Max(0, (_wave - 30) / 5));
            Broadcast($"<color=#e65a38>VAGUE {WaveDisplay()}</color> - {_spawnRemaining} ennemis approchent par deux voies fixes !");
            ScheduleSpawn(_sessionId);
        }

        private void ScheduleSpawn(int session)
        {
            if (!_running || !_waveActive || session != _sessionId) return;
            if (_spawnRemaining <= 0) { CheckWaveCleared(); return; }
            SpawnEnemy(_spawnRemaining == 1 && _wave % 5 == 0);
            _spawnRemaining--;
            float delay = Mathf.Max(0.45f, 1.15f - _wave * 0.055f);
            timer.Once(delay, () => ScheduleSpawn(session));
        }

        private void SpawnEnemy(bool boss)
        {
            int laneIndex = UnityEngine.Random.Range(0, _lanes.Count);
            Vector3 spawn = _lanes[laneIndex][0] + Vector3.up * 0.15f;
            BaseEntity created = GameManager.server.CreateEntity(boss ? BossPrefab : EnemyPrefab, spawn, Quaternion.identity, true);
            BasePlayer enemy = created as BasePlayer;
            if (enemy == null) { if (created != null) created.Kill(); return; }
            enemy.enableSaving = false;
            enemy.displayName = boss ? (_wave == 10 ? "COLOSSE DU NEANT" : "DEMOLISSEUR") : EnemyNameForWave();
            enemy.Spawn();
            float difficulty = 1f + Mathf.Min(60, Mathf.Max(0, _wave - 1)) * 0.16f + Mathf.Max(0, _wave - 60) * 0.05f;
            float health = boss ? (2200f + _participants.Count * 500f) * difficulty : (115f + _participants.Count * 28f) * difficulty;
            enemy.InitializeHealth(health, health);
            NPCPlayer npc = enemy as NPCPlayer;
            if (npc != null && npc.NavAgent != null) npc.NavAgent.enabled = false;
            _enemies[enemy] = new EnemyState
            {
                Lane = laneIndex,
                Speed = boss ? 1.15f : EnemySpeedForWave(),
                CoreDamage = boss ? Mathf.Min(1200f, 500f + _wave * 20f) : 80f + Mathf.Min(_wave, 50) * 12f + Mathf.Max(0, _wave - 50) * 3f,
                Credits = boss ? 250 + _wave * 15 : 18 + _wave * 3,
                Boss = boss
            };
        }

        private void TickEnemies()
        {
            if (!_running || !_waveActive || _enemies.Count == 0) return;
            CleanupEntities();
            foreach (KeyValuePair<BasePlayer, EnemyState> pair in _enemies.ToArray())
            {
                BasePlayer enemy = pair.Key;
                EnemyState state = pair.Value;
                if (!IsValid(enemy) || enemy.IsDead()) continue;

                BaseCombatEntity obstacle = ClosestDefense(enemy.transform.position, 2.7f);
                if (obstacle != null)
                {
                    AttackTarget(enemy, state, obstacle, state.Boss ? 110f : 24f + _wave * 4f);
                    continue;
                }
                BasePlayer defender = ClosestDefender(enemy.transform.position, 2.4f);
                if (defender != null)
                {
                    AttackTarget(enemy, state, defender, state.Boss ? 48f : 10f + _wave * 1.8f);
                    continue;
                }

                Vector3[] lane = _lanes[state.Lane];
                if (state.Waypoint >= lane.Length) { HitCore(enemy, state); continue; }
                Vector3 target = lane[state.Waypoint];
                Vector3 direction = target - enemy.transform.position;
                direction.y = 0f;
                if (direction.magnitude <= 1.1f)
                {
                    state.Waypoint++;
                    if (state.Waypoint >= lane.Length) HitCore(enemy, state);
                    continue;
                }
                float speed = state.Speed * (Time.realtimeSinceStartup < state.SlowedUntil ? 0.45f : 1f);
                Vector3 next = enemy.transform.position + direction.normalized * speed * EnemyTickSeconds;
                next = Ground(next) + Vector3.up * 0.15f;
                enemy.transform.position = next;
                enemy.transform.rotation = Quaternion.LookRotation(direction.normalized);
                enemy.SendNetworkUpdateImmediate();
            }
        }

        private void AttackTarget(BasePlayer enemy, EnemyState state, BaseCombatEntity target, float damage)
        {
            if (Time.realtimeSinceStartup < state.NextAttackAt || target == null || target.IsDestroyed) return;
            state.NextAttackAt = Time.realtimeSinceStartup + (state.Boss ? 0.75f : 1f);
            target.Hurt(damage, DamageType.Blunt, enemy, true);
        }

        private void TickTowers()
        {
            if (!_running || !_waveActive || _towers.Count == 0 || _enemies.Count == 0) return;
            foreach (TowerState tower in _towers.ToArray())
            {
                if (!IsValid(tower.Entity)) { _towers.Remove(tower); continue; }
                if (Time.realtimeSinceStartup < tower.NextShotAt) continue;
                BasePlayer target = _enemies.Keys.Where(enemy => IsValid(enemy) && !enemy.IsDead() && HorizontalDistance(enemy.transform.position, tower.Entity.transform.position) <= tower.Range)
                    .OrderBy(enemy => HorizontalDistance(enemy.transform.position, tower.Entity.transform.position)).FirstOrDefault();
                if (target == null) continue;
                tower.NextShotAt = Time.realtimeSinceStartup + tower.Interval;
                EnemyState enemyState;
                if (!_enemies.TryGetValue(target, out enemyState)) continue;
                enemyState.LastTowerOwner = tower.Owner;
                if (tower.Type == "slow") enemyState.SlowedUntil = Time.realtimeSinceStartup + 2.2f;
                target.Hurt(tower.Damage, DamageType.Bullet, tower.Entity, false);
                Vector3 direction = target.transform.position - tower.Entity.transform.position;
                direction.y = 0f;
                if (direction.sqrMagnitude > 0.1f)
                {
                    tower.Entity.transform.rotation = Quaternion.LookRotation(direction.normalized);
                    tower.Entity.SendNetworkUpdateImmediate();
                }
            }
        }

        private void HitCore(BasePlayer enemy, EnemyState state)
        {
            if (!_enemies.Remove(enemy)) return;
            _coreHealth = Mathf.Max(0, _coreHealth - Mathf.RoundToInt(state.CoreDamage));
            if (IsValid(enemy)) enemy.Kill();
            Broadcast($"Le coeur subit {state.CoreDamage:0} degats : <color=#e65a38>{_coreHealth}/{MaximumCoreHealth}</color>.");
            if (_coreHealth <= 0) { StopMode("DEFAITE : le coeur a ete detruit.", true); return; }
            CheckWaveCleared();
        }

        private void CheckWaveCleared()
        {
            if (!_running || !_waveActive || _spawnRemaining > 0) return;
            CleanupEntities();
            if (_enemies.Count > 0) return;
            _waveActive = false;
            foreach (ulong userId in _participants.ToArray())
            {
                _credits[userId] = Credits(userId) + 120 + _wave * 30;
                BasePlayer player = FindPlayer(userId);
                if (player != null) SendReply(player, $"Vague {_wave} terminee. Bonus : {120 + _wave * 30} credits.");
            }
            if (_endless)
            {
                UpdateEndlessRecords();
                if (_wave % 10 == 0)
                {
                    foreach (BasePlayer player in Participants()) Interface.CallHook("OnTowerDefenseEndlessMilestone", player, _wave, _coreHealth);
                    Broadcast($"<color=#ffd479>PALIER ENDLESS : VAGUE {_wave}</color> - record sauvegarde et recompense de progression ajoutee.");
                }
                float endlessBuildTime = Mathf.Max(18f, 35f - Mathf.Floor(_wave / 5f) * 2f);
                StartBuildPhase(endlessBuildTime, $"Intermission Endless apres la vague {_wave}");
                return;
            }
            if (_wave >= MaximumWaves)
            {
                foreach (BasePlayer player in Participants()) Interface.CallHook("OnTowerDefenseCompleted", player, _wave, _coreHealth);
                Broadcast("<color=#ffd479>VICTOIRE TOWER DEFENSE !</color> Les dix vagues sont repoussees.");
                int session = _sessionId;
                timer.Once(6f, () => { if (_running && session == _sessionId) StopMode("Tower Defense termine.", true); });
                return;
            }
            StartBuildPhase(35f, $"Intermission apres la vague {_wave}");
        }

        private void OnEntityBuilt(Planner planner, GameObject gameObject)
        {
            BasePlayer player = planner != null ? planner.GetOwnerPlayer() : null;
            BaseEntity entity = gameObject != null ? gameObject.ToBaseEntity() : null;
            TrackBuiltDefense(player, entity);
        }

        private void OnItemDeployed(Deployer deployer, BaseEntity entity)
        {
            BasePlayer player = deployer != null ? deployer.GetOwnerPlayer() : null;
            TrackBuiltDefense(player, entity);
        }

        private void TrackBuiltDefense(BasePlayer player, BaseEntity entity)
        {
            if (!IsParticipant(player) || entity == null) return;
            if (!_buildPhase || HorizontalDistance(entity.transform.position, _arenaCenter) > 68f || HorizontalDistance(entity.transform.position, CorePosition()) < 5f)
            {
                SendReply(player, _buildPhase ? "Construis dans l'arene et laisse 5m libres autour du coeur." : "Construction autorisee uniquement entre les vagues.");
                timer.Once(0.05f, () => { if (IsValid(entity)) entity.Kill(); });
                return;
            }
            entity.enableSaving = false;
            entity.OwnerID = player.userID;
            if (!_defenses.Contains(entity)) _defenses.Add(entity);
        }

        private object OnEntityTakeDamage(BaseCombatEntity entity, HitInfo info)
        {
            if (!_running || entity == null || info == null) return null;
            BasePlayer victimPlayer = entity as BasePlayer;
            BasePlayer attackerPlayer = info.InitiatorPlayer;
            BaseEntity attackerEntity = info.Initiator as BaseEntity;
            bool victimEnemy = victimPlayer != null && _enemies.ContainsKey(victimPlayer);
            bool attackerEnemy = attackerPlayer != null && _enemies.ContainsKey(attackerPlayer);
            bool victimParticipant = victimPlayer != null && _participants.Contains(victimPlayer.userID);
            bool attackerParticipant = attackerPlayer != null && _participants.Contains(attackerPlayer.userID);
            bool victimDefense = _defenses.Contains(entity);
            bool attackerTower = _towers.Any(tower => tower.Entity == attackerEntity);

            if (entity == _coreEntity)
            {
                info.damageTypes.ScaleAll(0f);
                return true;
            }
            if (victimEnemy)
            {
                if (attackerParticipant || attackerTower) return null;
                info.damageTypes.ScaleAll(0f);
                return true;
            }
            if (victimParticipant)
            {
                if (attackerEnemy) return null;
                info.damageTypes.ScaleAll(0f);
                return true;
            }
            if (victimDefense)
            {
                if (attackerEnemy) return null;
                info.damageTypes.ScaleAll(0f);
                return true;
            }
            if (attackerEnemy || attackerParticipant || attackerTower)
            {
                info.damageTypes.ScaleAll(0f);
                return true;
            }
            return null;
        }

        private void OnEntityDeath(BaseCombatEntity entity, HitInfo info)
        {
            if (entity == null) return;
            BasePlayer deadPlayer = entity as BasePlayer;
            EnemyState enemyState;
            if (deadPlayer != null && _enemies.TryGetValue(deadPlayer, out enemyState))
            {
                _enemies.Remove(deadPlayer);
                BasePlayer killer = info != null ? info.InitiatorPlayer : null;
                ulong rewarded = killer != null && _participants.Contains(killer.userID) ? killer.userID : enemyState.LastTowerOwner;
                if (rewarded != 0 && _participants.Contains(rewarded))
                {
                    _credits[rewarded] = Credits(rewarded) + enemyState.Credits;
                    BasePlayer owner = FindPlayer(rewarded);
                    if (owner != null && enemyState.Boss) SendReply(owner, $"Boss elimine : +{enemyState.Credits} credits.");
                }
                CheckWaveCleared();
                return;
            }
            if (deadPlayer != null && _participants.Contains(deadPlayer.userID))
            {
                _alive.Remove(deadPlayer.userID);
                Broadcast($"{deadPlayer.displayName} est tombe. Retour a la prochaine construction.");
                if (_waveActive && _alive.Count == 0)
                {
                    int session = _sessionId;
                    timer.Once(2f, () => { if (_running && _waveActive && _alive.Count == 0 && session == _sessionId) StopMode("DEFAITE : tous les defenseurs sont tombes.", true); });
                }
                return;
            }
            BaseEntity baseEntity = entity as BaseEntity;
            if (baseEntity != null && _defenses.Remove(baseEntity)) _towers.RemoveAll(tower => tower.Entity == baseEntity);
        }

        private void OnPlayerRespawned(BasePlayer player)
        {
            if (!IsParticipant(player)) return;
            timer.Once(0.2f, () =>
            {
                if (!IsParticipant(player) || !player.IsConnected) return;
                if (_buildPhase)
                {
                    _alive.Add(player.userID);
                    TeleportParticipant(player);
                    GiveCombatKit(player);
                    GiveBuildSupplies(player);
                }
                else
                {
                    player.Teleport(Ground(_arenaCenter + new Vector3(48f, 0f, 30f)) + Vector3.up * 1.2f);
                    RemoveModeItems(player);
                    SendReply(player, "Tu observes jusqu'a la prochaine phase de construction.");
                }
            });
        }

        private void OnPlayerDisconnected(BasePlayer player, string reason)
        {
            if (player == null || !_participants.Remove(player.userID)) return;
            _alive.Remove(player.userID);
            _readyPlayers.Remove(player.userID);
            _returnPositions.Remove(player.userID);
            _credits.Remove(player.userID);
            if (_participants.Count == 0) StopMode("Tower Defense termine : tous les joueurs sont partis.", false);
            else if (_waveActive && _alive.Count == 0) StopMode("DEFAITE : tous les defenseurs sont partis.", true);
        }

        private void OnWeaponFired(BaseProjectile projectile, BasePlayer player, ItemModProjectile mod, ProtoBuf.ProjectileShoot projectiles)
        {
            if (projectile == null || !IsParticipant(player)) return;
            timer.Once(0.01f, () =>
            {
                if (projectile == null || projectile.IsDestroyed || projectile.primaryMagazine == null) return;
                projectile.primaryMagazine.contents = projectile.primaryMagazine.capacity;
                projectile.SendNetworkUpdateImmediate();
            });
        }

        private void BuyTower(BasePlayer player, string type, int price, string prefab, float damage, float range, float interval)
        {
            if (Credits(player.userID) < price)
            {
                SendReply(player, $"<color=#e76a4c>Credits insuffisants</color> : {type} coute {price}, tu as {Credits(player.userID)}.");
                return;
            }

            // La tour se pose 4.5m devant le joueur : c'est la source d'echec la
            // plus frequente, l'ancien message ne disait ni pourquoi ni ou aller.
            Vector3 position = Ground(player.transform.position + player.eyes.BodyForward() * 4.5f) + Vector3.up * 0.1f;
            float toCenter = HorizontalDistance(position, _arenaCenter);
            float toCore = HorizontalDistance(position, CorePosition());
            if (toCenter > 65f)
            {
                SendReply(player, $"<color=#e76a4c>Trop loin du centre</color> ({toCenter:0}m, maximum 65m). Rapproche-toi du coeur et reessaie.");
                return;
            }
            if (toCore < 5f)
            {
                SendReply(player, $"<color=#e76a4c>Trop pres du coeur</color> ({toCore:0}m, minimum 5m). Recule de quelques pas.");
                return;
            }
            BaseEntity entity = GameManager.server.CreateEntity(prefab, position, Quaternion.LookRotation(player.eyes.BodyForward()), true);
            if (entity == null) { SendReply(player, "Cette tour est indisponible dans cette version de Rust."); return; }
            entity.enableSaving = false;
            entity.OwnerID = player.userID;
            entity.Spawn();
            BaseCombatEntity combat = entity as BaseCombatEntity;
            if (combat != null) combat.InitializeHealth(700f, 700f);
            _credits[player.userID] = Credits(player.userID) - price;
            _defenses.Add(entity);
            _towers.Add(new TowerState { Entity = entity, Type = type, Owner = player.userID, Damage = damage, Range = range, Interval = interval });
            SendReply(player, $"Tour {type} construite pour {price} credits. Solde : {Credits(player.userID)}.");
        }

        private bool SpendCredits(BasePlayer player, int amount)
        {
            int balance = Credits(player.userID);
            if (balance < amount) { SendReply(player, $"Il faut {amount} credits. Solde : {balance}."); return false; }
            _credits[player.userID] = balance - amount;
            return true;
        }

        private void GiveCombatKit(BasePlayer player)
        {
            RemoveModeItems(player);
            Item weapon = GiveNamedItem(player, "rifle.semiauto", 1, "Fusil de defense");
            if (weapon != null && weapon.hasCondition) weapon.condition = weapon.maxCondition;
            GiveNamedItem(player, "ammo.rifle", 256, "Munitions illimitees");
            GiveNamedItem(player, "syringe.medical", 5, "Soins");
        }

        private void GiveBuildSupplies(BasePlayer player)
        {
            RemoveBuildItems(player);
            GiveNamedItem(player, "building.planner", 1, "Plan de construction");
            GiveNamedItem(player, "hammer", 1, "Marteau de defense");
            GiveNamedItem(player, "wood", 8000, "Bois de construction");
            GiveNamedItem(player, "stones", 8000, "Pierre de construction");
            GiveNamedItem(player, "barricade.wood", 4, "Barricades de defense");
        }

        private Item GiveNamedItem(BasePlayer player, string shortname, int amount, string label)
        {
            Item item = ItemManager.CreateByName(shortname, amount);
            if (item == null) return null;
            item.name = ItemPrefix + label;
            player.GiveItem(item);
            return item;
        }

        private void RemoveBuildItems(BasePlayer player)
        {
            foreach (Item item in PlayerItems(player).ToArray())
            {
                if (item == null || string.IsNullOrEmpty(item.name) || !item.name.StartsWith(ItemPrefix, StringComparison.Ordinal)) continue;
                string name = item.name.Substring(ItemPrefix.Length);
                if (name.Contains("construction") || name.Contains("Plan") || name.Contains("Marteau") || name.Contains("Barricades")) item.Remove();
            }
        }

        private void RemoveModeItems(BasePlayer player)
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

        private void BuildArena()
        {
            RemoveArena();
            // 78m et non 72 : les murs sont a 73m, il faut valider au-dela de ce
            // qui est reellement bati pour ne pas coller l'enceinte a une berge.
            _arenaCenter = FindSafeCenter(78f);
            BuildLanes();
            const int wallCount = 54;
            const float radius = 73f;
            for (int index = 0; index < wallCount; index++)
            {
                float angle = index * Mathf.PI * 2f / wallCount;
                Vector3 offset = new Vector3(Mathf.Cos(angle), 0f, Mathf.Sin(angle)) * radius;
                SpawnTracked(WallPrefab, Ground(_arenaCenter + offset), Quaternion.Euler(0f, -angle * Mathf.Rad2Deg, 0f));
            }
            foreach (Vector3[] lane in _lanes)
            {
                for (int waypoint = 0; waypoint < lane.Length - 1; waypoint++)
                {
                    Vector3 start = lane[waypoint];
                    Vector3 end = lane[waypoint + 1];
                    float distance = HorizontalDistance(start, end);
                    int markers = Mathf.Max(1, Mathf.FloorToInt(distance / 7f));
                    for (int marker = 0; marker <= markers; marker++)
                    {
                        Vector3 point = Vector3.Lerp(start, end, marker / (float)markers);
                        SpawnTracked(RugPrefab, Ground(point), Quaternion.LookRotation((end - start).normalized));
                    }
                }
            }
            Vector3 core = CorePosition();
            for (int index = 0; index < 8; index++)
            {
                float angle = index * Mathf.PI * 2f / 8f;
                Vector3 offset = new Vector3(Mathf.Cos(angle), 0f, Mathf.Sin(angle)) * 4.2f;
                SpawnTracked(ConcretePrefab, Ground(core + offset), Quaternion.Euler(0f, -angle * Mathf.Rad2Deg, 0f));
            }
            _coreEntity = SpawnTracked(CorePrefab, Ground(core) + Vector3.up * 0.1f, Quaternion.Euler(0f, 90f, 0f));
            // La marge terrain-eau est la seule mesure qui prouve que l'arene est
            // au sec : une altitude proche de zero est normale sur une carte plate.
            float lowestGround = float.MaxValue;
            float worstLakeMargin = float.MaxValue;
            foreach (Vector3 point in ArenaSamplePoints(_arenaCenter, 78f))
            {
                float terrain = TerrainMeta.HeightMap.GetHeight(point);
                if (terrain < lowestGround) lowestGround = terrain;
                float margin = terrain - TerrainMeta.WaterMap.GetHeight(point);
                if (margin < worstLakeMargin) worstLakeMargin = margin;
            }
            Puts($"Arene Tower Defense generee en {_arenaCenter} avec {_lanes.Count} voies fixes et {_arenaEntities.Count} elements. Point le plus bas : {lowestGround:0.0}m au-dessus de la mer, marge lac/riviere : {worstLakeMargin:0.0}m.");
        }

        private void BuildLanes()
        {
            _lanes.Clear();
            Vector3[][] offsets =
            {
                new[] { new Vector3(-62f,0f,-22f), new Vector3(-42f,0f,-22f), new Vector3(-29f,0f,-8f), new Vector3(-8f,0f,-8f), new Vector3(8f,0f,10f), new Vector3(27f,0f,10f), new Vector3(46f,0f,0f) },
                new[] { new Vector3(-62f,0f,22f), new Vector3(-42f,0f,22f), new Vector3(-29f,0f,8f), new Vector3(-8f,0f,8f), new Vector3(8f,0f,-10f), new Vector3(27f,0f,-10f), new Vector3(46f,0f,0f) }
            };
            foreach (Vector3[] laneOffsets in offsets) _lanes.Add(laneOffsets.Select(offset => Ground(_arenaCenter + offset)).ToArray());
        }

        private BaseEntity SpawnTracked(string prefab, Vector3 position, Quaternion rotation)
        {
            BaseEntity entity = GameManager.server.CreateEntity(prefab, position, rotation, true);
            if (entity == null) return null;
            entity.enableSaving = false;
            entity.Spawn();
            _arenaEntities.Add(entity);
            return entity;
        }

        private void StopMode(string message, bool returnPlayers)
        {
            if (_stopping || (!_running && _arenaEntities.Count == 0 && _enemies.Count == 0)) return;
            _stopping = true;
            if (!string.IsNullOrEmpty(message)) Broadcast(message);
            _running = false;
            _waveActive = false;
            _buildPhase = false;
            _sessionId++;
            UpdateEndlessRecords();
            foreach (BasePlayer enemy in _enemies.Keys.ToArray()) if (IsValid(enemy)) enemy.Kill();
            _enemies.Clear();
            foreach (BaseEntity defense in _defenses.ToArray()) if (IsValid(defense)) defense.Kill();
            _defenses.Clear();
            _towers.Clear();
            foreach (ulong userId in _participants.ToArray())
            {
                BasePlayer player = FindPlayer(userId);
                if (player == null) continue;
                RemoveModeItems(player);
                if (returnPlayers) ReturnPlayer(player);
            }
            _participants.Clear();
            _alive.Clear();
            _readyPlayers.Clear();
            _returnPositions.Clear();
            _credits.Clear();
            _wave = 0;
            _spawnRemaining = 0;
            _coreHealth = 0;
            _endless = false;
            RemoveArena();
            _stopping = false;
        }

        private void RemoveArena()
        {
            foreach (BaseEntity entity in _arenaEntities.ToArray()) if (IsValid(entity)) entity.Kill();
            _arenaEntities.Clear();
            _lanes.Clear();
            _coreEntity = null;
            _arenaCenter = Vector3.zero;
        }

        private void CleanupEntities()
        {
            bool removedEnemy = false;
            foreach (BasePlayer enemy in _enemies.Keys.Where(enemy => !IsValid(enemy) || enemy.IsDead()).ToArray()) removedEnemy |= _enemies.Remove(enemy);
            _defenses.RemoveAll(entity => !IsValid(entity));
            _towers.RemoveAll(tower => !IsValid(tower.Entity));
            if (removedEnemy && _running && _waveActive && _spawnRemaining == 0) timer.Once(0.1f, CheckWaveCleared);
        }

        private BaseCombatEntity ClosestDefense(Vector3 position, float range)
        {
            return _defenses.Where(IsValid).OfType<BaseCombatEntity>()
                .Where(defense => HorizontalDistance(defense.transform.position, position) <= range)
                .OrderBy(defense => HorizontalDistance(defense.transform.position, position)).FirstOrDefault();
        }

        private BasePlayer ClosestDefender(Vector3 position, float range)
        {
            return Participants().Where(player => _alive.Contains(player.userID) && !player.IsDead() && HorizontalDistance(player.transform.position, position) <= range)
                .OrderBy(player => HorizontalDistance(player.transform.position, position)).FirstOrDefault();
        }

        private void SendStatus(BasePlayer player)
        {
            if (!_running) { SendReply(player, "Tower Defense inactif. Tape /td pour creer une arene."); return; }
            int seconds = _buildPhase ? Mathf.Max(0, Mathf.CeilToInt(_buildEndsAt - Time.realtimeSinceStartup)) : 0;
            SendReply(player, $"TD {(_endless ? "ENDLESS" : "NORMAL")} vague {WaveDisplay()} | coeur {_coreHealth}/{MaximumCoreHealth} | ennemis {_enemies.Count + _spawnRemaining} | defenses {_defenses.Count} | tours {_towers.Count} | credits {Credits(player.userID)} | construction {seconds}s | record {BestEndlessWave()}");
        }

        private string EnemyNameForWave()
        {
            if (_wave >= 8) return "BRISEUR BLINDE";
            if (_wave >= 5) return UnityEngine.Random.value < 0.35f ? "BRUTE DE SIEGE" : "ASSAILLANT";
            if (_wave >= 3) return UnityEngine.Random.value < 0.4f ? "COUREUR" : "ASSAILLANT";
            return "ASSAILLANT";
        }

        private float EnemySpeedForWave()
        {
            float bonus = Mathf.Min(1.15f, Mathf.Max(0, _wave - 10) * 0.025f);
            if (_wave >= 8) return UnityEngine.Random.Range(1.75f, 2.35f) + bonus;
            if (_wave >= 5) return UnityEngine.Random.Range(1.65f, 2.2f);
            if (_wave >= 3) return UnityEngine.Random.Range(2.0f, 2.8f);
            return UnityEngine.Random.Range(1.55f, 2.05f);
        }

        private string WaveDisplay() { return _endless ? $"{_wave}/INFINI" : $"{_wave}/{MaximumWaves}"; }

        private int BestEndlessWave()
        {
            return _data == null || _data.MeilleuresVaguesEndless.Count == 0 ? 0 : _data.MeilleuresVaguesEndless.Values.Max();
        }

        private void UpdateEndlessRecords()
        {
            if (!_endless || _data == null || _wave <= 0) return;
            bool changed = false;
            foreach (ulong userId in _participants)
            {
                int previous;
                if (!_data.MeilleuresVaguesEndless.TryGetValue(userId, out previous) || _wave > previous)
                {
                    _data.MeilleuresVaguesEndless[userId] = _wave;
                    changed = true;
                }
                BasePlayer player = FindPlayer(userId);
                if (player != null) _data.Noms[userId] = player.displayName;
            }
            if (changed) SaveData();
        }

        private void SaveData()
        {
            if (_data != null) Interface.Oxide.DataFileSystem.WriteObject(Name, _data);
        }

        private Vector3 CorePosition() { return Ground(_arenaCenter + new Vector3(49f, 0f, 0f)); }

        private Vector3 GetPlayerSpawn(ulong userId)
        {
            List<ulong> ids = _participants.OrderBy(value => value).ToList();
            int index = Mathf.Max(0, ids.IndexOf(userId));
            float angle = index * Mathf.PI * 2f / Mathf.Max(1, ids.Count);
            return Ground(_arenaCenter + new Vector3(42f, 0f, 0f) + new Vector3(Mathf.Cos(angle), 0f, Mathf.Sin(angle)) * 9f) + Vector3.up * 1.2f;
        }

        private void TeleportParticipant(BasePlayer player)
        {
            Vector3 position = GetPlayerSpawn(player.userID);
            if (player.IsDead()) player.RespawnAt(position, Quaternion.identity); else player.Teleport(position);
        }

        private void ReturnPlayer(BasePlayer player)
        {
            Vector3 position;
            if (!_returnPositions.TryGetValue(player.userID, out position) || player == null || !player.IsConnected) return;
            if (player.IsDead()) player.RespawnAt(position, Quaternion.identity); else player.Teleport(position);
        }

        private bool IsInOtherMode(BasePlayer player)
        {
            foreach (string hook in new[] { "IsGunGameParticipant", "IsZombieParticipant", "IsDuelParticipant", "IsCompetitiveModeParticipant", "IsTrainingParticipant", "IsBattlefieldParticipant" })
            {
                object result = Interface.CallHook(hook, player);
                if (result is bool && (bool)result) return true;
            }
            return false;
        }

        private Vector3 FindSafeCenter(float radius)
        {
            float halfSize = TerrainMeta.Size.x * 0.5f;
            float limit = Mathf.Max(120f, halfSize * 0.68f);
            for (int attempt = 0; attempt < 250; attempt++)
            {
                Vector3 candidate = new Vector3(UnityEngine.Random.Range(-limit, limit), 0f, UnityEngine.Random.Range(-limit, limit));
                if (IsSafeCenter(candidate, radius)) return Ground(candidate) + Vector3.up * 0.1f;
            }

            // Second passage sans la contrainte de relief : mieux vaut une arene
            // vallonnee qu'une arene noyee.
            for (int attempt = 0; attempt < 250; attempt++)
            {
                Vector3 candidate = new Vector3(UnityEngine.Random.Range(-limit, limit), 0f, UnityEngine.Random.Range(-limit, limit));
                if (IsDryCenter(candidate, radius)) return Ground(candidate) + Vector3.up * 0.1f;
            }

            // L'ancien repli renvoyait un point fixe jamais valide, qui pouvait
            // lui-meme etre sous l'eau. On teste chaque candidat de secours.
            Vector3[] fallbacks = { new Vector3(-250f, 0f, 250f), new Vector3(250f, 0f, 250f), new Vector3(250f, 0f, -250f), new Vector3(-250f, 0f, -250f), Vector3.zero };
            foreach (Vector3 candidate in fallbacks)
            {
                if (IsDryCenter(candidate, radius)) return Ground(candidate) + Vector3.up * 0.1f;
            }

            PrintWarning("Aucun emplacement d'arene hors de l'eau : la carte est peut-etre trop petite ou trop aquatique.");
            return Ground(fallbacks[0]) + Vector3.up * 0.1f;
        }

        private bool IsDryCenter(Vector3 candidate, float radius)
        {
            foreach (Vector3 point in ArenaSamplePoints(candidate, radius))
            {
                if (!IsDryPoint(point)) return false;
            }
            return true;
        }

        /// <summary>
        /// Un point est au sec s'il est au-dessus de l'ocean ET au-dessus de tout
        /// plan d'eau interieur.
        ///
        /// Les deux tests sont necessaires : TerrainMeta.WaterMap ne couvre que
        /// les lacs et rivieres et renvoie environ -500 en pleine mer, donc elle
        /// ne detecte jamais l'ocean. C'est ce qui laissait passer des arenes a
        /// altitude negative, les pieds dans l'eau, malgre une marge annoncee de
        /// 500m. L'ancien seuil de -1m acceptait d'ailleurs explicitement du
        /// terrain immerge, le niveau de la mer etant a 0.
        /// </summary>
        private bool IsDryPoint(Vector3 point)
        {
            float terrain = TerrainMeta.HeightMap.GetHeight(point);
            if (terrain < MinimumGroundHeight) return false;
            float water = TerrainMeta.WaterMap.GetHeight(point);
            return terrain > water + 2f;
        }

        /// <summary>
        /// Valide un centre d'arene. L'ancienne version ne testait l'eau qu'au
        /// point central et ne regardait que la hauteur du terrain sur quatre
        /// points de bordure : un centre pose sur une langue de terre au bord
        /// d'un lac passait, et l'arene de 73m plongeait dedans. On verifie
        /// desormais l'eau a CHAQUE point echantillonne, sur deux anneaux et
        /// huit directions, en couvrant tout le rayon reellement bati.
        /// </summary>
        private bool IsSafeCenter(Vector3 candidate, float radius)
        {
            float minimum = float.MaxValue;
            float maximum = float.MinValue;

            foreach (Vector3 point in ArenaSamplePoints(candidate, radius))
            {
                if (!IsDryPoint(point)) return false;
                float terrain = TerrainMeta.HeightMap.GetHeight(point);
                minimum = Mathf.Min(minimum, terrain);
                maximum = Mathf.Max(maximum, terrain);
            }

            if (maximum - minimum > 6f) return false;

            if (TerrainMeta.Path != null && TerrainMeta.Path.Monuments != null)
            {
                foreach (MonumentInfo monument in TerrainMeta.Path.Monuments)
                {
                    if (monument != null && HorizontalDistance(monument.transform.position, candidate) < 150f) return false;
                }
            }
            return true;
        }

        private IEnumerable<Vector3> ArenaSamplePoints(Vector3 center, float radius)
        {
            yield return center;
            // Deux anneaux : la bordure, et la mi-distance pour attraper une
            // riviere ou un etang qui traverserait l'arene sans toucher le bord.
            for (int ring = 1; ring <= 2; ring++)
            {
                float ringRadius = radius * ring / 2f;
                for (int step = 0; step < 8; step++)
                {
                    float angle = step * Mathf.PI * 2f / 8f;
                    yield return center + new Vector3(Mathf.Cos(angle), 0f, Mathf.Sin(angle)) * ringRadius;
                }
            }
        }

        private int Credits(ulong userId) { int value; return _credits.TryGetValue(userId, out value) ? value : 0; }
        private bool IsParticipant(BasePlayer player) { return player != null && _participants.Contains(player.userID); }
        private bool IsValid(BaseEntity entity) { return entity != null && !entity.IsDestroyed; }
        private BasePlayer FindPlayer(ulong userId) { return BasePlayer.activePlayerList.FirstOrDefault(player => player != null && player.userID == userId); }
        private IEnumerable<BasePlayer> Participants() { return _participants.Select(FindPlayer).Where(player => player != null && player.IsConnected); }
        private Vector3 Ground(Vector3 position) { position.y = TerrainMeta.HeightMap.GetHeight(position); return position; }
        private float HorizontalDistance(Vector3 first, Vector3 second) { first.y = 0f; second.y = 0f; return Vector3.Distance(first, second); }
        private void Broadcast(string message) { foreach (BasePlayer player in Participants()) SendReply(player, message); }
    }
}
