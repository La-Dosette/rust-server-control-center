using System;
using System.Collections.Generic;
using System.Globalization;
using System.Linq;
using Oxide.Core;
using Oxide.Game.Rust.Cui;
using UnityEngine;
using UnityEngine.AI;

namespace Oxide.Plugins
{
    [Info("RustBattlefield", "Rust Server Control Center", "1.0.0")]
    [Description("Battlefield Conquete : deux equipes, drapeaux, tickets et classes dans les monuments.")]
    public class RustBattlefield : RustPlugin
    {
        // ----- Constantes ----------------------------------------------------------

        private const string ItemPrefix = "Battlefield - ";
        private const string HudPanel = "rustbattlefield.hud";
        private const string RadiusMarkerPrefab = "assets/prefabs/tools/map/genericradiusmarker.prefab";
        private const string LabelMarkerPrefab = "assets/prefabs/deployable/vendingmachine/vending_mapmarker.prefab";
        private const string BannerPrefab = "assets/prefabs/deployable/signs/sign.pole.banner.large.prefab";
        private const string SandbagPrefab = "assets/prefabs/deployable/barricades/barricade.sandbags.prefab";
        private const int Red = 1;
        private const int Blue = 2;
        private const int StartingTickets = 150;
        private const float MatchMinutes = 20f;
        private const float RespawnDelay = 6f;
        private const float CaptureRatePerPlayer = 9f;      // % par seconde et par joueur
        private const int MaxCapturePlayers = 3;
        private const float BleedInterval = 3f;
        private const float RoundRestartDelay = 12f;

        // Les grands monuments d'abord : la Conquete demande de l'espace. Sur une
        // petite carte, on tombe sur le port ou le terminal de ferry.
        private static readonly string[] PreferredMonuments =
        {
            "launch_site", "airfield", "trainyard", "water_treatment", "powerplant", "military_tunnel",
            "harbor", "ferry_terminal", "fishing_village", "junkyard", "arctic_base", "satellite_dish", "sphere_tank"
        };

        // Combinaisons tres differentes : sans signe distinctif, impossible de
        // savoir sur qui tirer dans un mode en equipes.
        private static readonly string[] TeamOutfits = { "", "hazmatsuit", "hazmatsuit_scientist" };
        private static readonly string[] TeamNames = { "", "ROUGE", "BLEU" };
        private static readonly string[] TeamColors = { "#9A9A9A", "#E5533D", "#3D86E5" };

        private class ClassKit
        {
            public string Key;
            public string Label;
            public string Weapon;
            public string Sidearm;
            public string[] Extras;
            public int[] ExtraAmounts;
        }

        private static readonly ClassKit[] Classes =
        {
            new ClassKit { Key = "assaut", Label = "ASSAUT", Weapon = "rifle.ak", Sidearm = "pistol.semiauto", Extras = new[] { "grenade.f1", "bandage" }, ExtraAmounts = new[] { 2, 2 } },
            new ClassKit { Key = "medecin", Label = "MEDECIN", Weapon = "smg.mp5", Sidearm = "pistol.semiauto", Extras = new[] { "syringe.medical", "bandage" }, ExtraAmounts = new[] { 6, 4 } },
            new ClassKit { Key = "soutien", Label = "SOUTIEN", Weapon = "lmg.m249", Sidearm = "pistol.semiauto", Extras = new[] { "grenade.smoke", "bandage" }, ExtraAmounts = new[] { 2, 2 } },
            new ClassKit { Key = "eclaireur", Label = "ECLAIREUR", Weapon = "rifle.bolt", Sidearm = "pistol.python", Extras = new[] { "grenade.smoke", "bandage" }, ExtraAmounts = new[] { 1, 2 } }
        };

        // ----- Etat ----------------------------------------------------------------

        private class Flag
        {
            public string Name;
            public Vector3 Position;
            public float Radius;
            public float Progress;   // -100 = bleu, +100 = rouge
            public int Owner;        // 0 neutre
            public MapMarkerGenericRadius Marker;
            public VendingMachineMapMarker Label;
            public readonly List<BaseEntity> Props = new List<BaseEntity>();
        }

        private class StoredData
        {
            public Dictionary<ulong, string> Classe = new Dictionary<ulong, string>();
            public Dictionary<ulong, int> Victoires = new Dictionary<ulong, int>();
            public Dictionary<ulong, int> Eliminations = new Dictionary<ulong, int>();
        }

        private StoredData _data;
        private readonly List<Flag> _flags = new List<Flag>();
        private readonly List<BaseEntity> _arenaEntities = new List<BaseEntity>();
        private readonly Dictionary<ulong, int> _teams = new Dictionary<ulong, int>();
        private readonly Dictionary<ulong, Vector3> _returnPositions = new Dictionary<ulong, Vector3>();
        private readonly Dictionary<ulong, int> _kills = new Dictionary<ulong, int>();
        private readonly Dictionary<ulong, int> _deaths = new Dictionary<ulong, int>();
        private readonly Dictionary<ulong, int> _captures = new Dictionary<ulong, int>();
        private readonly Dictionary<ulong, string> _spawnChoice = new Dictionary<ulong, string>();
        private readonly Dictionary<ulong, float> _lastSpawn = new Dictionary<ulong, float>();
        private readonly Dictionary<ulong, KeyValuePair<ulong, float>> _lastAttacker = new Dictionary<ulong, KeyValuePair<ulong, float>>();
        private Vector3 _center;
        private Vector3 _baseRed;
        private Vector3 _baseBlue;
        private float _radius;
        private string _monumentName = "";
        private string _lastMonumentKey = "";
        private int _ticketsRed;
        private int _ticketsBlue;
        private bool _active;
        private bool _ending;
        private float _matchEndsAt;
        private float _nextBleed;
        private int _sessionId;
        private int _surfaceMask;
        private int _lastWalkableCount;

        // ----- Cycle de vie ----------------------------------------------------------

        private void Init()
        {
            LoadData();
        }

        private void OnServerInitialized()
        {
            ValidateContent();
            timer.Every(1f, Tick);
            // Les monuments irradient : purge reguliere, comme le Gun Game.
            timer.Every(3f, ClearRadiation);
            Puts("Battlefield Conquete pret : /bf pour rejoindre.");
        }

        private void Unload()
        {
            _sessionId++;
            foreach (BasePlayer player in BasePlayer.activePlayerList.ToArray())
            {
                if (!_teams.ContainsKey(player.userID)) continue;
                RemoveModeItems(player);
                CuiHelper.DestroyUi(player, HudPanel);
                ReturnPlayer(player);
            }
            _teams.Clear();
            RemoveArena();
            SaveData();
        }

        private void OnServerSave() { SaveData(); }

        private void ValidateContent()
        {
            // Une faute de frappe dans un nom d'objet se voit ici, au chargement,
            // et non au premier joueur qui reapparait sans arme.
            List<string> missing = new List<string>();
            foreach (ClassKit kit in Classes)
            {
                foreach (string shortname in new[] { kit.Weapon, kit.Sidearm }.Concat(kit.Extras))
                {
                    if (ItemManager.FindItemDefinition(shortname) == null && !missing.Contains(shortname)) missing.Add(shortname);
                }
            }
            for (int team = 1; team <= 2; team++)
            {
                if (ItemManager.FindItemDefinition(TeamOutfits[team]) == null) missing.Add(TeamOutfits[team]);
            }
            foreach (string prefab in new[] { RadiusMarkerPrefab, LabelMarkerPrefab, BannerPrefab, SandbagPrefab, ConcretePrefab, StoneWallPrefab })
            {
                if (StringPool.Get(prefab) == 0) missing.Add(prefab);
            }
            if (missing.Count > 0) PrintWarning("Battlefield : introuvable(s) dans cette version du jeu : " + string.Join(", ", missing.ToArray()));
            else Puts("Battlefield : armes, tenues et decors verifies.");
        }

        // ----- Interfaces avec les autres extensions -------------------------------

        private object IsBattlefieldParticipant(BasePlayer player)
        {
            return player != null && _teams.ContainsKey(player.userID);
        }

        private object IsBattlefieldFight(BasePlayer attacker, BasePlayer victim)
        {
            if (attacker == null || victim == null) return false;
            int a, v;
            return _teams.TryGetValue(attacker.userID, out a) && _teams.TryGetValue(victim.userID, out v) && a != v;
        }

        private object JoinBattlefieldFromLobby(BasePlayer player)
        {
            if (player == null) return false;
            if (!_teams.ContainsKey(player.userID)) Join(player);
            return _teams.ContainsKey(player.userID);
        }

        private object ForceLeaveMode(BasePlayer player)
        {
            if (player == null || !_teams.ContainsKey(player.userID)) return null;
            Leave(player, true);
            return true;
        }

        private object GetBattlefieldDashboardStatus()
        {
            return $"actif={_active && _teams.Count > 0} joueurs={_teams.Count} monument={_monumentName} tickets={_ticketsRed}-{_ticketsBlue} drapeaux={string.Join("", _flags.Select(flag => OwnerLetter(flag)).ToArray())}";
        }

        private string DescribeOtherMode(BasePlayer player)
        {
            string[][] guards =
            {
                new[] { "IsGunGameParticipant", "Quitte d'abord le Gun Game avec /gungame." },
                new[] { "IsZombieParticipant", "Quitte d'abord le mode Zombie avec /zombie." },
                new[] { "IsDuelParticipant", "Quitte d'abord le mode Duel avec /duel leave." },
                new[] { "IsCompetitiveModeParticipant", "Quitte d'abord le mode competitif avec /mode leave." },
                new[] { "IsTowerDefenseParticipant", "Quitte d'abord le Tower Defense avec /td." },
                new[] { "IsTrainingParticipant", "Quitte d'abord l'entrainement avec /entrainement quitter." }
            };
            foreach (string[] guard in guards)
            {
                object hook = Interface.CallHook(guard[0], player);
                if (hook is bool && (bool)hook) return guard[1];
            }
            return null;
        }

        // ----- Commandes -------------------------------------------------------------

        [ChatCommand("bf")]
        private void CommandBattlefield(BasePlayer player, string command, string[] args)
        {
            if (player == null) return;
            string sub = args != null && args.Length > 0 ? args[0].ToLowerInvariant() : "";

            if (sub == "classe" || sub == "class")
            {
                SetClass(player, args.Length > 1 ? args[1].ToLowerInvariant() : "");
                return;
            }
            if (sub == "spawn" || sub == "apparition")
            {
                SetSpawnChoice(player, args.Length > 1 ? args[1] : "");
                return;
            }
            if (sub == "score" || sub == "scores")
            {
                ShowScoreboard(player);
                return;
            }
            if (sub == "aide" || sub == "help")
            {
                ShowHelp(player);
                return;
            }
            if (_teams.ContainsKey(player.userID)) Leave(player, true);
            else Join(player);
        }

        [ChatCommand("battlefield")]
        private void CommandBattlefieldAlias(BasePlayer player, string command, string[] args)
        {
            CommandBattlefield(player, command, args);
        }

        [ConsoleCommand("bf.start")]
        private void ConsoleStart(ConsoleSystem.Arg arg)
        {
            if (!IsAdminCaller(arg)) return;
            if (_active) { arg.ReplyWith("Une partie est deja en cours : " + GetBattlefieldDashboardStatus()); return; }
            // "bf.start plaine" force le repli en terrain ouvert, pour le tester
            // sur une carte ou un monument conviendrait.
            _forceOpenField = ConsoleArgs(arg).Any(value => value.ToLowerInvariant() == "plaine");
            bool started = StartMatch();
            _forceOpenField = false;
            arg.ReplyWith(started ? "Partie preparee : " + DescribeArena() : "Aucun terrain exploitable sur cette carte.");
        }

        [ConsoleCommand("bf.stop")]
        private void ConsoleStop(ConsoleSystem.Arg arg)
        {
            if (!IsAdminCaller(arg)) return;
            int count = _teams.Count;
            StopMatch("Battlefield arrete par un administrateur.");
            arg.ReplyWith($"Battlefield arrete, {count} joueur(s) renvoye(s).");
        }

        [ConsoleCommand("bf.debug")]
        private void ConsoleDebug(ConsoleSystem.Arg arg)
        {
            if (!IsAdminCaller(arg)) return;
            arg.ReplyWith(GetBattlefieldDashboardStatus() + " | " + DescribeArena());
        }

        // Sonde de diagnostic : ce que voit le placement des drapeaux.
        [ConsoleCommand("bf.probe")]
        private void ConsoleProbe(ConsoleSystem.Arg arg)
        {
            if (!IsAdminCaller(arg)) return;
            List<string> lines = new List<string>();
            if (TerrainMeta.Path != null && TerrainMeta.Path.Monuments != null)
            {
                lines.Add("carte=" + TerrainMeta.Size.x + " monuments : " + string.Join(", ", TerrainMeta.Path.Monuments
                    .Where(monument => monument != null)
                    .Select(monument => { string n = monument.name ?? "?"; n = n.Substring(n.LastIndexOf('/') + 1).Replace(".prefab", ""); Vector3 e = Vector3.zero; try { e = monument.Bounds.extents; } catch { } return n + "(" + Mathf.Max(e.x, e.z).ToString("F0") + "m)"; })
                    .ToArray()));
            }
            foreach (MonumentInfo monument in CandidateMonuments().Take(4))
            {
                Vector3 center = monument.transform.position;
                lines.Add($"== {MonumentLabel(monument)} centre={center} nom={monument.name}");
                if (_surfaceMask == 0) _surfaceMask = LayerMask.GetMask("Terrain", "World", "Construction", "Default");
                foreach (Vector3 offset in new[] { Vector3.zero, new Vector3(20f, 0f, 0f), new Vector3(0f, 0f, 20f), new Vector3(-20f, 0f, -20f) })
                {
                    Vector3 point = center + offset;
                    string ray = "aucun";
                    RaycastHit hit;
                    if (Physics.Raycast(new Vector3(point.x, center.y + 80f, point.z), Vector3.down, out hit, 200f, _surfaceMask))
                        ray = $"{hit.point.y:F1} couche={LayerMask.LayerToName(hit.collider.gameObject.layer)} objet={hit.collider.name} trigger={hit.collider.isTrigger}";
                    string nav = "aucun";
                    foreach (float radius in new[] { 2f, 6f, 15f, 40f })
                    {
                        NavMeshHit navHit;
                        if (NavMesh.SamplePosition(new Vector3(point.x, TerrainMeta.HeightMap.GetHeight(point) + 1f, point.z), out navHit, radius, NavMesh.AllAreas))
                        { nav = $"r{radius}: {navHit.position.y:F1} a {Vector3.Distance(navHit.position, point):F0}m"; break; }
                    }
                    lines.Add($"  +{offset.x:F0},{offset.z:F0} terrain={TerrainMeta.HeightMap.GetHeight(point):F1} eau={TerrainMeta.WaterMap.GetHeight(point):F1} rayon={ray} navmesh={nav}");
                }
            }
            arg.ReplyWith(string.Join(" || ", lines.ToArray()));
        }

        private string[] ConsoleArgs(ConsoleSystem.Arg arg)
        {
            return arg.Args == null ? new string[0] : arg.Args.Select(value => value.ToString()).ToArray();
        }

        private bool IsAdminCaller(ConsoleSystem.Arg arg)
        {
            BasePlayer caller = arg.Player();
            if (caller == null || caller.IsAdmin) return true;
            arg.ReplyWith("Commande reservee aux administrateurs.");
            return false;
        }

        private string DescribeArena()
        {
            if (!_active) return "aucune arene";
            string flags = string.Join(" ", _flags.Select(flag =>
                $"{flag.Name}[{flag.Position.x:F0},{flag.Position.y:F1},{flag.Position.z:F0} r={flag.Radius:F0} {OwnerLetter(flag)} {flag.Progress:F0}%]").ToArray());
            int props = _flags.Sum(flag => flag.Props.Count(entity => entity != null && !entity.IsDestroyed));
            return $"monument=\"{_monumentName}\" sol_praticable={_lastWalkableCount} centre={_center} rayon={_radius:F0} QG_rouge={_baseRed} QG_bleu={_baseBlue} drapeaux=[{flags}] decors={props} marqueurs={_flags.Count(flag => flag.Marker != null && !flag.Marker.IsDestroyed)}";
        }

        private void ShowHelp(BasePlayer player)
        {
            SendReply(player, "<color=#ffd479>BATTLEFIELD CONQUETE</color> - capture les drapeaux, fais tomber les tickets ennemis a zero.");
            SendReply(player, "/bf : rejoindre ou quitter   /bf score : classement");
            SendReply(player, "/bf classe <assaut|medecin|soutien|eclaireur> : classe a la prochaine apparition");
            SendReply(player, "/bf spawn <auto|base|A|B|C...> : ou reapparaitre (un drapeau dispute est refuse)");
        }

        // ----- Partie ----------------------------------------------------------------

        private void Join(BasePlayer player)
        {
            if (player == null || !player.IsConnected) return;
            string other = DescribeOtherMode(player);
            if (other != null) { SendReply(player, other); return; }
            if (!_active && !StartMatch())
            {
                SendReply(player, "Battlefield indisponible : aucun monument exploitable sur cette carte.");
                return;
            }

            _returnPositions[player.userID] = player.transform.position;
            int redCount = _teams.Values.Count(team => team == Red);
            int blueCount = _teams.Values.Count(team => team == Blue);
            int team = redCount < blueCount ? Red : blueCount < redCount ? Blue : (UnityEngine.Random.value < 0.5f ? Red : Blue);
            _teams[player.userID] = team;
            if (!_kills.ContainsKey(player.userID)) _kills[player.userID] = 0;
            if (!_deaths.ContainsKey(player.userID)) _deaths[player.userID] = 0;
            if (!_captures.ContainsKey(player.userID)) _captures[player.userID] = 0;
            _spawnChoice[player.userID] = "auto";

            SpawnParticipant(player, true);
            Broadcast($"<color={TeamColors[team]}>{player.displayName}</color> rejoint l'equipe {TeamNames[team]}.");
            SendReply(player, $"<color=#ffd479>BATTLEFIELD - {_monumentName}</color> : tu es dans l'equipe <color={TeamColors[team]}>{TeamNames[team]}</color>. Capture les drapeaux !");
            SendReply(player, "/bf aide pour les classes et les points d'apparition. /bf pour quitter.");
        }

        private void Leave(BasePlayer player, bool teleport)
        {
            if (player == null) return;
            ulong id = player.userID;
            if (!_teams.Remove(id)) return;
            RemoveModeItems(player);
            CuiHelper.DestroyUi(player, HudPanel);
            if (teleport) ReturnPlayer(player);
            _returnPositions.Remove(id);
            _spawnChoice.Remove(id);
            _lastSpawn.Remove(id);
            SendReply(player, "Tu as quitte Battlefield.");
            if (_teams.Count == 0) StopMatch(null);
        }

        private void ReturnPlayer(BasePlayer player)
        {
            Vector3 position;
            if (player != null && player.IsConnected && !player.IsDead() && _returnPositions.TryGetValue(player.userID, out position))
            {
                player.Teleport(position);
            }
        }

        private bool StartMatch()
        {
            RemoveArena();
            if (!BuildArena()) return false;
            _ticketsRed = StartingTickets;
            _ticketsBlue = StartingTickets;
            _active = true;
            _ending = false;
            _matchEndsAt = Time.realtimeSinceStartup + MatchMinutes * 60f;
            _nextBleed = Time.realtimeSinceStartup + BleedInterval;
            _sessionId++;
            Puts("Battlefield : " + DescribeArena());
            return true;
        }

        private void StopMatch(string message)
        {
            foreach (ulong id in _teams.Keys.ToArray())
            {
                BasePlayer player = FindPlayer(id);
                if (player == null) continue;
                if (message != null) SendReply(player, message);
                RemoveModeItems(player);
                CuiHelper.DestroyUi(player, HudPanel);
                ReturnPlayer(player);
            }
            _teams.Clear();
            _returnPositions.Clear();
            _spawnChoice.Clear();
            _kills.Clear();
            _deaths.Clear();
            _captures.Clear();
            _lastAttacker.Clear();
            _active = false;
            _ending = false;
            _sessionId++;
            RemoveArena();
            SaveData();
        }

        private void EndMatch(int winner, string reason)
        {
            if (_ending) return;
            _ending = true;
            string headline = winner == 0
                ? $"Fin de partie : egalite. {reason}"
                : $"Victoire de l'equipe <color={TeamColors[winner]}>{TeamNames[winner]}</color> ! {reason}";
            Broadcast(headline);

            var best = _teams.Keys
                .Select(id => new { Id = id, Kills = Get(_kills, id), Deaths = Get(_deaths, id), Caps = Get(_captures, id) })
                .OrderByDescending(row => row.Kills * 2 + row.Caps * 3 - row.Deaths)
                .Take(3).ToList();
            int rank = 1;
            foreach (var row in best)
            {
                BasePlayer player = FindPlayer(row.Id);
                string name = player != null ? player.displayName : row.Id.ToString();
                Broadcast($"  {rank++}. {name} - {row.Kills} elim. / {row.Deaths} morts / {row.Caps} captures");
            }
            foreach (ulong id in _teams.Keys)
            {
                _data.Eliminations[id] = Get(_data.Eliminations, id) + Get(_kills, id);
                if (winner != 0 && _teams[id] == winner) _data.Victoires[id] = Get(_data.Victoires, id) + 1;
            }
            SaveData();

            int session = _sessionId;
            Broadcast($"Nouvelle manche dans {RoundRestartDelay:F0} secondes, sur un autre monument si possible.");
            timer.Once(RoundRestartDelay, () =>
            {
                if (session != _sessionId) return;
                RestartRound();
            });
        }

        private void RestartRound()
        {
            List<ulong> players = _teams.Keys.Where(id => FindPlayer(id) != null).ToList();
            if (players.Count == 0) { StopMatch(null); return; }

            // Les points de retour d'origine sont gardes : on change seulement
            // de terrain, et on reequilibre les equipes.
            Dictionary<ulong, Vector3> returns = new Dictionary<ulong, Vector3>(_returnPositions);
            Dictionary<ulong, string> choices = new Dictionary<ulong, string>(_spawnChoice);
            RemoveArena();
            if (!BuildArena())
            {
                StopMatch("Aucun monument exploitable pour une nouvelle manche.");
                return;
            }
            _teams.Clear();
            _kills.Clear();
            _deaths.Clear();
            _captures.Clear();
            _lastAttacker.Clear();
            List<ulong> shuffled = players.OrderBy(id => UnityEngine.Random.value).ToList();
            for (int index = 0; index < shuffled.Count; index++)
            {
                ulong id = shuffled[index];
                _teams[id] = index % 2 == 0 ? Red : Blue;
                _kills[id] = 0; _deaths[id] = 0; _captures[id] = 0;
            }
            foreach (KeyValuePair<ulong, Vector3> pair in returns) _returnPositions[pair.Key] = pair.Value;
            foreach (ulong id in shuffled) _spawnChoice[id] = "auto";
            _ticketsRed = StartingTickets;
            _ticketsBlue = StartingTickets;
            _active = true;
            _ending = false;
            _matchEndsAt = Time.realtimeSinceStartup + MatchMinutes * 60f;
            _nextBleed = Time.realtimeSinceStartup + BleedInterval;
            _sessionId++;

            foreach (ulong id in shuffled)
            {
                BasePlayer player = FindPlayer(id);
                if (player == null) continue;
                SendReply(player, $"Nouvelle manche - {_monumentName}. Equipe <color={TeamColors[_teams[id]]}>{TeamNames[_teams[id]]}</color>.");
                if (player.IsDead()) player.RespawnAt(ChooseSpawn(player), Quaternion.identity);
                else SpawnParticipant(player, true);
            }
        }

        // ----- Arene -----------------------------------------------------------------

        private bool BuildArena()
        {
            if (_forceOpenField) return TryBuildOpenField();
            // On essaie les monuments dans l'ordre de preference : un monument a
            // moitie dans la mer peut ne pas suffire, le suivant prendra le relais.
            foreach (MonumentInfo monument in CandidateMonuments())
            {
                if (TryBuildArenaAt(monument)) return true;
                RemoveArena();
            }
            // Aucun monument ne convient : une plaine plate et seche, equipee de
            // couvertures. Sans ce repli, le mode serait injouable sur certaines cartes.
            return TryBuildOpenField();
        }

        private bool TryBuildArenaAt(MonumentInfo monument)
        {
            _center = monument.transform.position;
            _monumentName = MonumentLabel(monument);
            float extent = 60f;
            try
            {
                Vector3 extents = monument.Bounds.extents;
                extent = Mathf.Max(extents.x, extents.z);
            }
            catch { }
            _radius = Mathf.Clamp(extent <= 1f ? 60f : extent, 45f, 120f);
            float flagRadius = Mathf.Clamp(_radius * 0.13f, 8f, 14f);
            float spacing = flagRadius * 2.5f;

            List<Vector3> walkable = SampleWalkable(_radius * 0.85f);
            _lastWalkableCount = walkable.Count;
            if (walkable.Count < 6)
            {
                Puts($"Battlefield : {_monumentName} ecarte, seulement {walkable.Count} point(s) praticable(s).");
                return false;
            }

            // Repartition par eloignement maximal : le premier drapeau au plus
            // pres du centre, chaque suivant le plus loin possible des autres.
            int wanted = _radius >= 70f ? 5 : 3;
            float limit = _radius * 0.7f;
            List<Vector3> picks = new List<Vector3> { walkable.OrderBy(point => HorizontalDistance(point, _center)).First() };
            while (picks.Count < wanted)
            {
                Vector3 best = Vector3.zero;
                float bestDistance = -1f;
                foreach (Vector3 point in walkable)
                {
                    if (HorizontalDistance(point, _center) > limit) continue;
                    float nearest = picks.Min(pick => HorizontalDistance(point, pick));
                    if (nearest > bestDistance) { bestDistance = nearest; best = point; }
                }
                if (bestDistance < spacing) break;
                picks.Add(best);
            }
            if (picks.Count < 2)
            {
                Puts($"Battlefield : {_monumentName} ecarte, terrain trop exigu pour deux drapeaux.");
                return false;
            }

            // Axe du terrain = les deux points praticables les plus eloignes. Les
            // QG en occupent les extremites, les drapeaux sont nommes de A (cote
            // rouge) a E (cote bleu).
            Vector3 from = walkable[0], to = walkable[0];
            float longest = -1f;
            for (int i = 0; i < walkable.Count; i++)
            {
                for (int j = i + 1; j < walkable.Count; j++)
                {
                    float distance = HorizontalDistance(walkable[i], walkable[j]);
                    if (distance > longest) { longest = distance; from = walkable[i]; to = walkable[j]; }
                }
            }
            Vector3 axis = to - from;
            axis.y = 0f;
            axis = axis.sqrMagnitude > 0.01f ? axis.normalized : Vector3.forward;

            List<Vector3> baseCandidates = walkable.Where(point => picks.All(pick => HorizontalDistance(point, pick) >= flagRadius + 6f)).ToList();
            if (baseCandidates.Count < 2)
            {
                Puts($"Battlefield : {_monumentName} ecarte, pas de place pour les QG.");
                return false;
            }
            _baseRed = baseCandidates.OrderBy(point => Vector3.Dot(point - _center, axis)).First();
            _baseBlue = baseCandidates.OrderByDescending(point => Vector3.Dot(point - _center, axis)).First();
            if (HorizontalDistance(_baseRed, _baseBlue) < spacing * 1.5f)
            {
                Puts($"Battlefield : {_monumentName} ecarte, QG trop proches l'un de l'autre.");
                return false;
            }

            string[] names = { "A", "B", "C", "D", "E" };
            int index = 0;
            foreach (Vector3 position in picks.OrderBy(point => Vector3.Dot(point - _center, axis)))
            {
                Flag flag = new Flag { Name = names[index++], Position = position, Radius = flagRadius };
                _flags.Add(flag);
                DecorateFlag(flag);
            }
            _arenaEntities.Add(SpawnRadiusMarker(_baseRed, 0.05f, TeamColor(Red), 0.85f));
            _arenaEntities.Add(SpawnRadiusMarker(_baseBlue, 0.05f, TeamColor(Blue), 0.85f));
            _arenaEntities.Add(SpawnLabel(_baseRed, "QG ROUGE"));
            _arenaEntities.Add(SpawnLabel(_baseBlue, "QG BLEU"));
            _arenaEntities.RemoveAll(entity => entity == null);
            string lowered = (monument.name ?? "").ToLowerInvariant();
            _lastMonumentKey = PreferredMonuments.FirstOrDefault(key => lowered.Contains(key)) ?? "";
            return true;
        }

        // ----- Sol praticable (verification physique) -------------------------------
        //
        // Le maillage de navigation n'existe pas autour de tous les monuments : la
        // sonde n'en a trouve aucun dans un rayon de 40 m au port de cette carte.
        // On verifie donc le sol avec la physique : une surface au-dessus de la mer,
        // presque horizontale, plate sur 4 x 4 m, et degagee sur la hauteur d'un
        // joueur.

        private static readonly Vector3[] FlatOffsets =
        {
            new Vector3(2f, 0f, 2f), new Vector3(-2f, 0f, 2f), new Vector3(2f, 0f, -2f), new Vector3(-2f, 0f, -2f)
        };
        private int _clearanceMask;
        private bool _forceOpenField;

        private void EnsureMasks()
        {
            if (_surfaceMask == 0) _surfaceMask = LayerMask.GetMask("Terrain", "World", "Construction", "Default");
            if (_clearanceMask == 0) _clearanceMask = LayerMask.GetMask("World", "Construction", "Default", "Deployed");
        }

        private bool IsStandable(Vector3 point, out Vector3 surface)
        {
            surface = Vector3.zero;
            EnsureMasks();
            float top = Mathf.Max(_center.y, TerrainMeta.HeightMap.GetHeight(point)) + 80f;
            RaycastHit hit;
            if (!Physics.Raycast(new Vector3(point.x, top, point.z), Vector3.down, out hit, 260f, _surfaceMask, QueryTriggerInteraction.Ignore)) return false;
            if (hit.normal.y < 0.85f) return false;
            Vector3 ground = hit.point;
            // WaterMap ne couvre pas l'ocean : niveau de la mer exige, puis lacs et rivieres.
            if (ground.y < 0.6f) return false;
            if (ground.y < TerrainMeta.WaterMap.GetHeight(ground) - 0.2f) return false;
            // Plat sur 4 x 4 m : elimine le toit d'une citerne, une rambarde, une caisse.
            foreach (Vector3 offset in FlatOffsets)
            {
                RaycastHit around;
                if (!Physics.Raycast(new Vector3(ground.x + offset.x, top, ground.z + offset.z), Vector3.down, out around, 260f, _surfaceMask, QueryTriggerInteraction.Ignore)) return false;
                if (Mathf.Abs(around.point.y - ground.y) > 0.6f) return false;
            }
            if (Physics.CheckCapsule(ground + Vector3.up * 0.5f, ground + Vector3.up * 1.7f, 0.35f, _clearanceMask, QueryTriggerInteraction.Ignore)) return false;
            surface = ground;
            return true;
        }

        private bool TryWalkable(Vector3 point, float searchRadius, out Vector3 position)
        {
            if (IsStandable(point, out position)) return true;
            // Le point exact ne convient pas : on cherche autour, sur deux anneaux.
            foreach (float distance in new[] { searchRadius * 0.5f, searchRadius })
            {
                for (int index = 0; index < 8; index++)
                {
                    float angle = index * Mathf.PI / 4f;
                    if (IsStandable(point + new Vector3(Mathf.Cos(angle), 0f, Mathf.Sin(angle)) * distance, out position)) return true;
                }
            }
            position = Vector3.zero;
            return false;
        }

        private List<Vector3> SampleWalkable(float radius)
        {
            List<Vector3> points = new List<Vector3>();
            float step = Mathf.Clamp(radius / 12f, 5f, 10f);
            for (float x = -radius; x <= radius; x += step)
            {
                for (float z = -radius; z <= radius; z += step)
                {
                    if (x * x + z * z > radius * radius) continue;
                    Vector3 position;
                    if (IsStandable(_center + new Vector3(x, 0f, z), out position)) points.Add(position);
                }
            }
            return points;
        }

        // ----- Repli en terrain ouvert -----------------------------------------------

        private const string ConcretePrefab = "assets/prefabs/deployable/barricades/barricade.concrete.prefab";
        private const string StoneWallPrefab = "assets/prefabs/building/wall.external.high.stone/wall.external.high.stone.prefab";

        private bool TryBuildOpenField()
        {
            float half = TerrainMeta.Size.x * 0.5f;
            float limit = Mathf.Max(100f, half * 0.75f);
            for (int attempt = 0; attempt < 300; attempt++)
            {
                Vector3 candidate = new Vector3(UnityEngine.Random.Range(-limit, limit), 0f, UnityEngine.Random.Range(-limit, limit));
                candidate.y = TerrainMeta.HeightMap.GetHeight(candidate);
                if (candidate.y < 4f || candidate.y < TerrainMeta.WaterMap.GetHeight(candidate) + 1f) continue;
                if (!IsFieldFlat(candidate, 50f)) continue;
                if (NearMonument(candidate, 110f)) continue;
                if (BuildOpenFieldAt(candidate)) return true;
                RemoveArena();
            }
            return false;
        }

        private bool IsFieldFlat(Vector3 center, float radius)
        {
            float min = center.y, max = center.y;
            for (int index = 0; index < 12; index++)
            {
                float angle = index * Mathf.PI / 6f;
                foreach (float distance in new[] { radius * 0.5f, radius })
                {
                    Vector3 point = center + new Vector3(Mathf.Cos(angle), 0f, Mathf.Sin(angle)) * distance;
                    float height = TerrainMeta.HeightMap.GetHeight(point);
                    if (height < 2f || height < TerrainMeta.WaterMap.GetHeight(point) + 0.5f) return false;
                    min = Mathf.Min(min, height);
                    max = Mathf.Max(max, height);
                }
            }
            return max - min < 8f;
        }

        private bool NearMonument(Vector3 point, float distance)
        {
            if (TerrainMeta.Path == null || TerrainMeta.Path.Monuments == null) return false;
            foreach (MonumentInfo monument in TerrainMeta.Path.Monuments)
            {
                if (monument != null && HorizontalDistance(monument.transform.position, point) < distance) return true;
            }
            return false;
        }

        private bool BuildOpenFieldAt(Vector3 center)
        {
            _center = center;
            _radius = 55f;
            _monumentName = "Plaine";
            float flagRadius = 10f;
            Vector3 axis = Quaternion.Euler(0f, UnityEngine.Random.Range(0f, 360f), 0f) * Vector3.forward;
            Vector3 side = new Vector3(axis.z, 0f, -axis.x);

            string[] names = { "A", "B", "C" };
            float[] steps = { -32f, 0f, 32f };
            for (int index = 0; index < 3; index++)
            {
                Vector3 position;
                if (!TryWalkable(center + axis * steps[index], 6f, out position)) return false;
                Flag flag = new Flag { Name = names[index], Position = position, Radius = flagRadius };
                _flags.Add(flag);
                DecorateFlag(flag);
            }
            Vector3 redBase, blueBase;
            if (!TryWalkable(center - axis * 52f, 8f, out redBase) || !TryWalkable(center + axis * 52f, 8f, out blueBase)) return false;
            _baseRed = redBase;
            _baseBlue = blueBase;

            // Couvertures entre les drapeaux : en plaine, sans elles, celui qui
            // voit le premier gagne a tous les coups.
            for (int index = 0; index < 16; index++)
            {
                Vector3 offset = axis * UnityEngine.Random.Range(-44f, 44f) + side * UnityEngine.Random.Range(-26f, 26f);
                Vector3 position;
                if (!TryWalkable(center + offset, 4f, out position)) continue;
                if (_flags.Any(flag => HorizontalDistance(flag.Position, position) < 4f)) continue;
                string prefab = index % 4 == 0 ? StoneWallPrefab : index % 2 == 0 ? SandbagPrefab : ConcretePrefab;
                BaseEntity cover = SpawnProp(prefab, position, Quaternion.Euler(0f, UnityEngine.Random.Range(0f, 360f), 0f));
                if (cover != null) _arenaEntities.Add(cover);
            }

            _arenaEntities.Add(SpawnRadiusMarker(_baseRed, 0.05f, TeamColor(Red), 0.85f));
            _arenaEntities.Add(SpawnRadiusMarker(_baseBlue, 0.05f, TeamColor(Blue), 0.85f));
            _arenaEntities.Add(SpawnLabel(_baseRed, "QG ROUGE"));
            _arenaEntities.Add(SpawnLabel(_baseBlue, "QG BLEU"));
            _arenaEntities.RemoveAll(entity => entity == null);
            _lastMonumentKey = "plaine";
            return true;
        }

        private float HorizontalDistance(Vector3 first, Vector3 second)
        {
            first.y = 0f;
            second.y = 0f;
            return Vector3.Distance(first, second);
        }

        private List<MonumentInfo> CandidateMonuments()
        {
            List<MonumentInfo> result = new List<MonumentInfo>();
            if (TerrainMeta.Path == null || TerrainMeta.Path.Monuments == null) return result;
            List<MonumentInfo> present = TerrainMeta.Path.Monuments.Where(monument => monument != null && monument.transform != null).ToList();
            List<string> order = PreferredMonuments.ToList();
            // Rotation : le monument de la manche precedente passe en dernier.
            if (order.Remove(_lastMonumentKey)) order.Add(_lastMonumentKey);
            foreach (string key in order)
            {
                foreach (MonumentInfo monument in present.Where(candidate => (candidate.name ?? "").ToLowerInvariant().Contains(key)).OrderBy(candidate => UnityEngine.Random.value))
                {
                    result.Add(monument);
                }
            }
            return result;
        }

        private void DecorateFlag(Flag flag)
        {
            BaseEntity banner = SpawnProp(BannerPrefab, flag.Position, Quaternion.identity);
            if (banner != null) flag.Props.Add(banner);
            // Sacs de sable autour du drapeau : ils marquent la zone et offrent
            // de la couverture aux defenseurs.
            for (int index = 0; index < 4; index++)
            {
                float angle = index * Mathf.PI / 2f + Mathf.PI / 4f;
                Vector3 offset = new Vector3(Mathf.Cos(angle), 0f, Mathf.Sin(angle)) * flag.Radius * 0.7f;
                Vector3 position;
                if (!TryWalkable(flag.Position + offset, 3f, out position)) continue;
                BaseEntity bags = SpawnProp(SandbagPrefab, position, Quaternion.LookRotation(offset.normalized));
                if (bags != null) flag.Props.Add(bags);
            }
            flag.Marker = SpawnRadiusMarker(flag.Position, Mathf.Max(0.03f, flag.Radius / 220f), TeamColor(0), 0.7f);
            flag.Label = SpawnLabel(flag.Position, "DRAPEAU " + flag.Name);
        }

        private BaseEntity SpawnProp(string prefab, Vector3 position, Quaternion rotation)
        {
            BaseEntity entity = GameManager.server.CreateEntity(prefab, position, rotation, true);
            if (entity == null) return null;
            entity.enableSaving = false;
            entity.Spawn();
            return entity;
        }

        private MapMarkerGenericRadius SpawnRadiusMarker(Vector3 position, float radius, Color color, float alpha)
        {
            MapMarkerGenericRadius marker = GameManager.server.CreateEntity(RadiusMarkerPrefab, position) as MapMarkerGenericRadius;
            if (marker == null) return null;
            marker.enableSaving = false;
            marker.alpha = alpha;
            marker.color1 = color;
            marker.color2 = Color.black;
            marker.radius = radius;
            marker.Spawn();
            marker.SendUpdate();
            return marker;
        }

        private VendingMachineMapMarker SpawnLabel(Vector3 position, string text)
        {
            VendingMachineMapMarker label = GameManager.server.CreateEntity(LabelMarkerPrefab, position) as VendingMachineMapMarker;
            if (label == null) return null;
            label.enableSaving = false;
            label.markerShopName = text;
            label.Spawn();
            return label;
        }

        private void RemoveArena()
        {
            foreach (Flag flag in _flags)
            {
                foreach (BaseEntity entity in flag.Props) if (entity != null && !entity.IsDestroyed) entity.Kill();
                if (flag.Marker != null && !flag.Marker.IsDestroyed) flag.Marker.Kill();
                if (flag.Label != null && !flag.Label.IsDestroyed) flag.Label.Kill();
            }
            _flags.Clear();
            foreach (BaseEntity entity in _arenaEntities) if (entity != null && !entity.IsDestroyed) entity.Kill();
            _arenaEntities.Clear();
        }

        private string MonumentLabel(MonumentInfo monument)
        {
            try
            {
                if (monument.displayPhrase != null && !string.IsNullOrEmpty(monument.displayPhrase.english)) return monument.displayPhrase.english;
            }
            catch { }
            string name = monument.name ?? "monument";
            int slash = name.LastIndexOf('/');
            if (slash >= 0 && slash < name.Length - 1) name = name.Substring(slash + 1);
            return name.Replace(".prefab", "");
        }

        // ----- Boucle de jeu -----------------------------------------------------------

        private void Tick()
        {
            if (!_active || _ending) return;
            float now = Time.realtimeSinceStartup;

            foreach (Flag flag in _flags) UpdateFlag(flag);

            if (now >= _nextBleed)
            {
                _nextBleed = now + BleedInterval;
                int redFlags = _flags.Count(flag => flag.Owner == Red);
                int blueFlags = _flags.Count(flag => flag.Owner == Blue);
                // L'equipe qui tient moins de drapeaux saigne des tickets.
                if (redFlags > blueFlags) _ticketsBlue -= redFlags - blueFlags;
                else if (blueFlags > redFlags) _ticketsRed -= blueFlags - redFlags;
            }

            if (_ticketsRed <= 0 || _ticketsBlue <= 0)
            {
                _ticketsRed = Mathf.Max(0, _ticketsRed);
                _ticketsBlue = Mathf.Max(0, _ticketsBlue);
                EndMatch(_ticketsRed > _ticketsBlue ? Red : Blue, "Tickets ennemis epuises.");
            }
            else if (now >= _matchEndsAt)
            {
                EndMatch(_ticketsRed == _ticketsBlue ? 0 : (_ticketsRed > _ticketsBlue ? Red : Blue), "Temps ecoule.");
            }

            foreach (ulong id in _teams.Keys.ToArray())
            {
                BasePlayer player = FindPlayer(id);
                if (player != null) DrawHud(player);
            }
        }

        private void UpdateFlag(Flag flag)
        {
            int red = 0, blue = 0;
            List<BasePlayer> inside = new List<BasePlayer>();
            foreach (ulong id in _teams.Keys)
            {
                BasePlayer player = FindPlayer(id);
                if (player == null || player.IsDead() || player.IsWounded()) continue;
                if (!InsideFlag(flag, player.transform.position)) continue;
                inside.Add(player);
                if (_teams[id] == Red) red++; else blue++;
            }
            if (red == 0 && blue == 0) return;
            if (red > 0 && blue > 0) return; // dispute : rien ne bouge

            int previousOwner = flag.Owner;
            float delta = CaptureRatePerPlayer * Mathf.Min(MaxCapturePlayers, Mathf.Max(red, blue));
            flag.Progress = Mathf.Clamp(flag.Progress + (red > 0 ? delta : -delta), -100f, 100f);

            if (flag.Owner == Red && flag.Progress <= 0f) flag.Owner = 0;
            else if (flag.Owner == Blue && flag.Progress >= 0f) flag.Owner = 0;
            if (flag.Progress >= 100f) flag.Owner = Red;
            else if (flag.Progress <= -100f) flag.Owner = Blue;

            if (flag.Owner == previousOwner) return;
            UpdateFlagVisuals(flag);
            if (flag.Owner == 0)
            {
                Broadcast($"Drapeau <color=#ffd479>{flag.Name}</color> neutralise.");
                return;
            }
            Broadcast($"L'equipe <color={TeamColors[flag.Owner]}>{TeamNames[flag.Owner]}</color> capture le drapeau <color=#ffd479>{flag.Name}</color> !");
            foreach (BasePlayer player in inside)
            {
                if (_teams[player.userID] == flag.Owner) _captures[player.userID] = Get(_captures, player.userID) + 1;
            }
        }

        private bool InsideFlag(Flag flag, Vector3 position)
        {
            Vector3 delta = position - flag.Position;
            if (Mathf.Abs(delta.y) > 12f) return false;
            delta.y = 0f;
            return delta.sqrMagnitude <= flag.Radius * flag.Radius;
        }

        private void UpdateFlagVisuals(Flag flag)
        {
            if (flag.Marker != null && !flag.Marker.IsDestroyed)
            {
                flag.Marker.color1 = TeamColor(flag.Owner);
                flag.Marker.SendUpdate();
            }
            if (flag.Label != null && !flag.Label.IsDestroyed)
            {
                flag.Label.markerShopName = $"DRAPEAU {flag.Name} - {(flag.Owner == 0 ? "NEUTRE" : TeamNames[flag.Owner])}";
                flag.Label.SendNetworkUpdate();
            }
        }

        private Color TeamColor(int team)
        {
            if (team == Red) return new Color(0.9f, 0.25f, 0.2f);
            if (team == Blue) return new Color(0.2f, 0.5f, 0.95f);
            return new Color(0.75f, 0.75f, 0.75f);
        }

        private string OwnerLetter(Flag flag)
        {
            return flag.Owner == Red ? "R" : flag.Owner == Blue ? "B" : "N";
        }

        // ----- Combats, morts et reapparitions ------------------------------------

        private object OnEntityTakeDamage(BaseCombatEntity entity, HitInfo info)
        {
            if (entity == null || info == null) return null;
            BasePlayer victim = entity as BasePlayer;
            bool victimIn = victim != null && _teams.ContainsKey(victim.userID);

            // La radiation n'a pas d'attaquant : traitee avant le filtre qui suit.
            if (victimIn && info.damageTypes != null) info.damageTypes.Scale(Rust.DamageType.Radiation, 0f);

            BasePlayer attacker = info.InitiatorPlayer;
            if (victim == null || attacker == null || attacker == victim) return null;
            bool attackerIn = _teams.ContainsKey(attacker.userID);
            if (!victimIn && !attackerIn) return null;

            if (victimIn && attackerIn && _active && !_ending && _teams[victim.userID] != _teams[attacker.userID])
            {
                _lastAttacker[victim.userID] = new KeyValuePair<ulong, float>(attacker.userID, Time.realtimeSinceStartup);
                return null;
            }
            // Tir ami, scientifiques du monument, joueurs hors partie : aucun degat.
            info.damageTypes.ScaleAll(0f);
            return true;
        }

        private object OnPlayerDeath(BasePlayer player, HitInfo info)
        {
            if (player == null || !_teams.ContainsKey(player.userID)) return null;
            // L'equipement est retire avant que le cadavre ne se forme : sinon
            // chaque mort laisse un AK skinne a ramasser.
            RemoveModeItems(player);
            CuiHelper.DestroyUi(player, HudPanel);
            if (!_active || _ending) return null;

            ulong id = player.userID;
            int team = _teams[id];
            _deaths[id] = Get(_deaths, id) + 1;
            if (team == Red) _ticketsRed--; else _ticketsBlue--;

            BasePlayer killer = info != null ? info.InitiatorPlayer : null;
            KeyValuePair<ulong, float> recent;
            // Mort d'une blessure : on credite le dernier tireur ennemi recent.
            if ((killer == null || killer == player) && _lastAttacker.TryGetValue(id, out recent) && Time.realtimeSinceStartup - recent.Value < 20f)
            {
                killer = FindPlayer(recent.Key);
            }
            _lastAttacker.Remove(id);
            int killerTeam;
            if (killer != null && killer != player && _teams.TryGetValue(killer.userID, out killerTeam) && killerTeam != team)
            {
                _kills[killer.userID] = Get(_kills, killer.userID) + 1;
                Broadcast($"<color={TeamColors[killerTeam]}>{killer.displayName}</color> elimine <color={TeamColors[team]}>{player.displayName}</color>");
            }

            int session = _sessionId;
            timer.Once(RespawnDelay, () =>
            {
                if (session != _sessionId || player == null || !player.IsConnected || !_teams.ContainsKey(id)) return;
                if (player.IsDead()) player.RespawnAt(ChooseSpawn(player), Quaternion.identity);
            });
            SendReply(player, $"Reapparition dans {RespawnDelay:F0} s. Change de point avec /bf spawn, de classe avec /bf classe.");
            return null;
        }

        private void OnPlayerRespawned(BasePlayer player)
        {
            if (player == null || !_teams.ContainsKey(player.userID)) return;
            timer.Once(0.2f, () =>
            {
                if (player == null || !player.IsConnected || !_teams.ContainsKey(player.userID)) return;
                SpawnParticipant(player, false);
            });
        }

        private void OnPlayerDisconnected(BasePlayer player, string reason)
        {
            if (player == null || !_teams.ContainsKey(player.userID)) return;
            // Un joueur deconnecte devient un dormeur : son inventaire resterait
            // dans le monde. On retire l'equipement du mode avant tout.
            Leave(player, false);
        }

        private void SpawnParticipant(BasePlayer player, bool initial)
        {
            float last;
            // Reapparition et teleportation peuvent se suivre de pres : une seule
            // dotation par seconde suffit.
            if (_lastSpawn.TryGetValue(player.userID, out last) && Time.realtimeSinceStartup - last < 1f) return;
            _lastSpawn[player.userID] = Time.realtimeSinceStartup;

            player.EnsureDismounted();
            player.Teleport(ChooseSpawn(player));
            GiveKit(player);
            RestoreStats(player);
            DrawHud(player);
        }

        private Vector3 ChooseSpawn(BasePlayer player)
        {
            int team;
            if (!_teams.TryGetValue(player.userID, out team)) return player.transform.position;
            Vector3 home = team == Red ? _baseRed : _baseBlue;
            string choice;
            if (!_spawnChoice.TryGetValue(player.userID, out choice)) choice = "auto";

            List<Flag> safe = _flags.Where(flag => flag.Owner == team && !IsContested(flag)).ToList();
            Vector3 target = home;
            if (choice != "base" && choice != "auto")
            {
                Flag wanted = safe.FirstOrDefault(flag => flag.Name.Equals(choice, StringComparison.OrdinalIgnoreCase));
                if (wanted != null) target = wanted.Position;
            }
            else if (choice == "auto" && safe.Count > 0)
            {
                // Le drapeau tenu le plus proche du centre : c'est la que se joue
                // la partie, pas au fond du QG.
                target = safe.OrderBy(flag => Vector3.Distance(flag.Position, _center)).First().Position;
            }

            Vector3 offset = new Vector3(UnityEngine.Random.Range(-3f, 3f), 0f, UnityEngine.Random.Range(-3f, 3f));
            Vector3 position;
            if (TryWalkable(target + offset, 4f, out position)) return position + Vector3.up * 0.3f;
            return target + Vector3.up * 0.3f;
        }

        private bool IsContested(Flag flag)
        {
            int red = 0, blue = 0;
            foreach (KeyValuePair<ulong, int> pair in _teams)
            {
                BasePlayer player = FindPlayer(pair.Key);
                if (player == null || player.IsDead() || !InsideFlag(flag, player.transform.position)) continue;
                if (pair.Value == Red) red++; else blue++;
            }
            return red > 0 && blue > 0;
        }

        private void SetSpawnChoice(BasePlayer player, string value)
        {
            if (!_teams.ContainsKey(player.userID)) { SendReply(player, "Rejoins d'abord Battlefield avec /bf."); return; }
            string choice = (value ?? "").Trim();
            if (choice.Equals("auto", StringComparison.OrdinalIgnoreCase) || choice.Equals("base", StringComparison.OrdinalIgnoreCase))
            {
                _spawnChoice[player.userID] = choice.ToLowerInvariant();
                SendReply(player, $"Point d'apparition : {choice.ToUpperInvariant()}.");
                return;
            }
            Flag flag = _flags.FirstOrDefault(candidate => candidate.Name.Equals(choice, StringComparison.OrdinalIgnoreCase));
            if (flag == null)
            {
                SendReply(player, "Usage : /bf spawn <auto|base|" + string.Join("|", _flags.Select(candidate => candidate.Name).ToArray()) + ">");
                return;
            }
            _spawnChoice[player.userID] = flag.Name;
            SendReply(player, $"Point d'apparition : drapeau {flag.Name}. S'il n'est pas a ton equipe ou s'il est dispute, tu apparais au QG.");
        }

        // ----- Classes et equipement ---------------------------------------------

        private ClassKit ClassOf(BasePlayer player)
        {
            string key;
            if (_data.Classe.TryGetValue(player.userID, out key))
            {
                ClassKit kit = Classes.FirstOrDefault(candidate => candidate.Key == key);
                if (kit != null) return kit;
            }
            return Classes[0];
        }

        private void SetClass(BasePlayer player, string key)
        {
            ClassKit kit = Classes.FirstOrDefault(candidate => candidate.Key == key);
            if (kit == null)
            {
                SendReply(player, "Classes : " + string.Join(", ", Classes.Select(candidate => candidate.Key).ToArray()));
                return;
            }
            _data.Classe[player.userID] = kit.Key;
            SaveData();
            SendReply(player, $"Classe <color=#ffd479>{kit.Label}</color> : {WeaponName(kit.Weapon)} + {WeaponName(kit.Sidearm)}. Effective a ta prochaine apparition.");
        }

        private void GiveKit(BasePlayer player)
        {
            if (player == null || player.inventory == null) return;
            RemoveModeItems(player);
            ClassKit kit = ClassOf(player);
            int team = _teams[player.userID];

            GiveWeapon(player, kit.Weapon);
            GiveWeapon(player, kit.Sidearm);
            for (int index = 0; index < kit.Extras.Length; index++) GiveTracked(player, kit.Extras[index], kit.ExtraAmounts[index], null);

            ItemDefinition outfit = ItemManager.FindItemDefinition(TeamOutfits[team]);
            if (outfit != null && player.inventory.containerWear != null)
            {
                // Une combinaison couvre tout le corps : le reste de la tenue est
                // mis de cote dans le sac pour ne pas bloquer l'equipement.
                Item suit = ItemManager.Create(outfit, 1);
                if (suit != null)
                {
                    suit.name = ItemPrefix + "Tenue " + TeamNames[team];
                    foreach (Item worn in player.inventory.containerWear.itemList.ToArray())
                    {
                        if (!worn.MoveToContainer(player.inventory.containerMain)) worn.Drop(player.transform.position + Vector3.up, Vector3.zero);
                    }
                    if (!suit.MoveToContainer(player.inventory.containerWear)) suit.Remove();
                }
            }
        }

        private void GiveWeapon(BasePlayer player, string shortname)
        {
            ItemDefinition definition = ItemManager.FindItemDefinition(shortname);
            if (definition == null) return;
            Item weapon = ItemManager.Create(definition, 1);
            if (weapon == null) return;
            weapon.name = ItemPrefix + WeaponName(shortname);
            if (weapon.hasCondition) weapon.condition = weapon.maxCondition;

            // Les skins choisis dans le Gun Game suivent le joueur ici aussi.
            object skin = Interface.CallHook("GetPlayerWeaponSkin", player, shortname);
            if (skin is ulong && (ulong)skin != 0UL)
            {
                weapon.skin = (ulong)skin;
                BaseEntity held = weapon.GetHeldEntity();
                if (held != null) { held.skinID = (ulong)skin; held.SendNetworkUpdate(); }
            }

            BaseProjectile projectile = weapon.GetHeldEntity() as BaseProjectile;
            ItemDefinition ammo = projectile != null && projectile.primaryMagazine != null ? projectile.primaryMagazine.ammoType : null;
            if (projectile != null && projectile.primaryMagazine != null) projectile.primaryMagazine.contents = projectile.primaryMagazine.capacity;

            if (!player.inventory.GiveItem(weapon, player.inventory.containerBelt) && !player.inventory.GiveItem(weapon))
            {
                weapon.Remove();
                return;
            }
            if (ammo != null) GiveTracked(player, ammo.shortname, shortname.StartsWith("lmg") ? 400 : 200, "Munitions");
        }

        private void GiveTracked(BasePlayer player, string shortname, int amount, string label)
        {
            Item item = ItemManager.CreateByName(shortname, amount);
            if (item == null) return;
            item.name = ItemPrefix + (label ?? item.info.displayName.english);
            // GiveItem du joueur laisserait tomber l'objet au sol si l'inventaire
            // est plein : hors de portee du nettoyage par prefixe.
            if (!player.inventory.GiveItem(item)) item.Remove();
        }

        private void RemoveModeItems(BasePlayer player)
        {
            if (player == null || player.inventory == null) return;
            List<Item> items = new List<Item>();
            foreach (ItemContainer container in new[] { player.inventory.containerMain, player.inventory.containerBelt, player.inventory.containerWear })
            {
                if (container != null) items.AddRange(container.itemList);
            }
            foreach (Item item in items)
            {
                if (item != null && !string.IsNullOrEmpty(item.name) && item.name.StartsWith(ItemPrefix, StringComparison.Ordinal)) item.Remove();
            }
        }

        private string WeaponName(string shortname)
        {
            ItemDefinition definition = ItemManager.FindItemDefinition(shortname);
            return definition != null ? definition.displayName.english : shortname;
        }

        private void RestoreStats(BasePlayer player)
        {
            if (player == null || !player.IsConnected || player.IsDead()) return;
            float max = player.MaxHealth();
            player.InitializeHealth(max, max);
            player.health = max;
            PlayerMetabolism metabolism = player.metabolism;
            if (metabolism != null)
            {
                if (metabolism.calories != null) metabolism.calories.value = metabolism.calories.max;
                if (metabolism.hydration != null) metabolism.hydration.value = metabolism.hydration.max;
                if (metabolism.bleeding != null) metabolism.bleeding.value = 0f;
                if (metabolism.radiation_poison != null) metabolism.radiation_poison.value = 0f;
                if (metabolism.radiation_level != null) metabolism.radiation_level.value = 0f;
                metabolism.SendChangesToClient();
            }
            player.SendNetworkUpdateImmediate();
        }

        private void ClearRadiation()
        {
            if (_teams.Count == 0) return;
            foreach (ulong id in _teams.Keys)
            {
                BasePlayer player = FindPlayer(id);
                if (player == null || player.metabolism == null) continue;
                if (player.metabolism.radiation_poison != null) player.metabolism.radiation_poison.value = 0f;
                if (player.metabolism.radiation_level != null) player.metabolism.radiation_level.value = 0f;
            }
        }

        // ----- Interface -----------------------------------------------------------

        private string Anchor(float x, float y)
        {
            // Les ancres sont des chaines : en locale francaise, « 0,44 » casserait
            // toute la mise en page sans erreur.
            return x.ToString(CultureInfo.InvariantCulture) + " " + y.ToString(CultureInfo.InvariantCulture);
        }

        private string Rgba(int team, float alpha)
        {
            Color color = TeamColor(team);
            return string.Format(CultureInfo.InvariantCulture, "{0:0.###} {1:0.###} {2:0.###} {3:0.###}", color.r, color.g, color.b, alpha);
        }

        private void DrawHud(BasePlayer player)
        {
            if (player == null || !player.IsConnected) return;
            int team;
            if (!_teams.TryGetValue(player.userID, out team)) return;
            CuiHelper.DestroyUi(player, HudPanel);

            CuiElementContainer container = new CuiElementContainer();
            // Parent "Hud" et pas de curseur : l'affichage reste visible en jeu
            // sans jamais capturer la souris.
            string panel = container.Add(new CuiPanel
            {
                Image = { Color = "0.06 0.06 0.06 0.72" },
                RectTransform = { AnchorMin = "0.34 0.905", AnchorMax = "0.66 0.985" }
            }, "Hud", HudPanel);

            container.Add(new CuiLabel
            {
                Text = { Text = _ticketsRed.ToString(), FontSize = 20, Align = TextAnchor.MiddleCenter, Color = Rgba(Red, 1f) },
                RectTransform = { AnchorMin = "0 0.38", AnchorMax = "0.2 1" }
            }, panel);
            container.Add(new CuiLabel
            {
                Text = { Text = _ticketsBlue.ToString(), FontSize = 20, Align = TextAnchor.MiddleCenter, Color = Rgba(Blue, 1f) },
                RectTransform = { AnchorMin = "0.8 0.38", AnchorMax = "1 1" }
            }, panel);

            float width = 0.6f / Mathf.Max(1, _flags.Count);
            for (int index = 0; index < _flags.Count; index++)
            {
                Flag flag = _flags[index];
                float minX = 0.2f + index * width + 0.01f;
                float maxX = 0.2f + (index + 1) * width - 0.01f;
                container.Add(new CuiPanel
                {
                    Image = { Color = Rgba(flag.Owner, flag.Owner == 0 ? 0.55f : 0.9f) },
                    RectTransform = { AnchorMin = Anchor(minX, 0.42f), AnchorMax = Anchor(maxX, 0.94f) }
                }, panel);
                container.Add(new CuiLabel
                {
                    Text = { Text = flag.Name, FontSize = 15, Align = TextAnchor.MiddleCenter, Color = "1 1 1 1" },
                    RectTransform = { AnchorMin = Anchor(minX, 0.42f), AnchorMax = Anchor(maxX, 0.94f) }
                }, panel);
            }

            string status = $"{TeamNames[team]} · {ClassOf(player).Label} · {Get(_kills, player.userID)} elim. / {Get(_deaths, player.userID)} morts";
            Flag here = _flags.FirstOrDefault(flag => InsideFlag(flag, player.transform.position));
            if (here != null)
            {
                float share = team == Red ? here.Progress : -here.Progress;
                status = IsContested(here) ? $"DRAPEAU {here.Name} DISPUTE" : $"DRAPEAU {here.Name} : {Mathf.Clamp(share, -100f, 100f):F0} %";
            }
            container.Add(new CuiLabel
            {
                Text = { Text = status, FontSize = 11, Align = TextAnchor.MiddleCenter, Color = "1 0.95 0.85 1" },
                RectTransform = { AnchorMin = "0 0", AnchorMax = "1 0.4" }
            }, panel);

            CuiHelper.AddUi(player, container);
        }

        private void ShowScoreboard(BasePlayer player)
        {
            if (!_active) { SendReply(player, "Aucune partie en cours."); return; }
            SendReply(player, $"<color=#ffd479>{_monumentName}</color> - tickets ROUGE {_ticketsRed} / BLEU {_ticketsBlue}");
            foreach (int team in new[] { Red, Blue })
            {
                foreach (ulong id in _teams.Where(pair => pair.Value == team).Select(pair => pair.Key).OrderByDescending(id => Get(_kills, id)))
                {
                    BasePlayer member = FindPlayer(id);
                    SendReply(player, $"<color={TeamColors[team]}>{TeamNames[team]}</color> {(member != null ? member.displayName : id.ToString())} : {Get(_kills, id)} elim. / {Get(_deaths, id)} morts / {Get(_captures, id)} captures");
                }
            }
        }

        // ----- Utilitaires ---------------------------------------------------------

        private void Broadcast(string message)
        {
            foreach (ulong id in _teams.Keys.ToArray())
            {
                BasePlayer player = FindPlayer(id);
                if (player != null) SendReply(player, message);
            }
        }

        private BasePlayer FindPlayer(ulong id)
        {
            return BasePlayer.activePlayerList.FirstOrDefault(player => player != null && player.userID == id);
        }

        private static int Get(Dictionary<ulong, int> source, ulong id)
        {
            int value;
            return source.TryGetValue(id, out value) ? value : 0;
        }

        private void LoadData()
        {
            try { _data = Interface.Oxide.DataFileSystem.ReadObject<StoredData>(Name); }
            catch { _data = null; }
            if (_data == null) _data = new StoredData();
            if (_data.Classe == null) _data.Classe = new Dictionary<ulong, string>();
            if (_data.Victoires == null) _data.Victoires = new Dictionary<ulong, int>();
            if (_data.Eliminations == null) _data.Eliminations = new Dictionary<ulong, int>();
        }

        private void SaveData()
        {
            Interface.Oxide.DataFileSystem.WriteObject(Name, _data);
        }
    }
}
