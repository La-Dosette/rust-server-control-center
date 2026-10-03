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
    [Info("RustGunGame", "OpenAI", "3.3.0")]
    [Description("Gun Game FFA dans les monuments, sans bots, avec choix des skins d'armes.")]
    public class RustGunGame : RustPlugin
    {
        private const string ItemPrefix = "Gun Game - ";
        // On ne batit plus d'arene : on joue dans les monuments de la carte.
        // Classement par preference. Les monuments irradies viennent d'abord --
        // ils n'existent que sur les grandes cartes -- puis les meilleurs
        // terrains fermes que portent les petites.
        // Protection volontairement legere : le Gun Game se joue sur la
        // precision, pas sur l'encaissement. Casque + vetements ~25 %.
        private static readonly string[] ArmorSet =
        {
            "hoodie", "pants", "shoes.boots", "coffeecan.helmet"
        };

        private static readonly string[] PreferredMonuments =
        {
            "launch_site", "airfield", "powerplant", "trainyard", "water_treatment",
            "military_tunnel", "satellite_dish", "junkyard", "arctic_base",
            "sphere_tank", "harbor", "ferry_terminal", "oilrig_1", "oilrig_2",
            "fishing_village", "mining_quarry"
        };

        private static readonly string[] PlayableWeaponOrder =
        {
            "bow.hunting", "crossbow", "pistol.nailgun", "pistol.eoka",
            "pistol.revolver", "pistol.python", "pistol.semiauto", "pistol.m92", "pistol.prototype17",
            "shotgun.waterpipe", "shotgun.double", "shotgun.pump", "shotgun.spas12",
            "smg.2", "smg.thompson", "smg.mp5",
            "rifle.semiauto", "rifle.m39", "rifle.sks",
            "rifle.ak", "rifle.lr300", "hmlmg", "lmg.m249",
            "rifle.bolt", "rifle.l96", "knife.combat"
        };

        private readonly HashSet<ulong> _activePlayers = new HashSet<ulong>();
        private readonly List<BaseEntity> _arenaEntities = new List<BaseEntity>();
        private readonly Dictionary<ulong, Vector3> _returnPositions = new Dictionary<ulong, Vector3>();

        private List<ItemDefinition> _weapons = new List<ItemDefinition>();
        // Armes du selecteur de skins : celles du Gun Game, plus les armes de
        // melee des autres modes (Duel) qui n'en font pas partie.
        private readonly List<ItemDefinition> _skinWeapons = new List<ItemDefinition>();
        private static readonly string[] ExtraSkinWeapons = { "machete", "salvaged.sword", "spear.stone", "spear.wooden", "mace", "longsword" };
        private StoredData _data;
        private readonly Dictionary<string, List<SkinEntry>> _skins = new Dictionary<string, List<SkinEntry>>();

        private struct SkinEntry
        {
            public ulong Id;
            public string Nom;
            public string Icone;
        }

        private Vector3 _arenaCenter;
        private float _arenaRadius = 45f;
        private string _arenaName = "";
        private int _nextSpawnIndex;

        private class StoredData
        {
            public Dictionary<ulong, int> Etapes = new Dictionary<ulong, int>();
            public Dictionary<ulong, int> Victoires = new Dictionary<ulong, int>();
            public Dictionary<ulong, int> Eliminations = new Dictionary<ulong, int>();
            // "off" | "random" | "pick". Defaut : random, c'est le plus
            // agreable sans configuration.
            public Dictionary<ulong, string> ModeSkin = new Dictionary<ulong, string>();
            // Cle plate "steamid:shortname" : un dictionnaire imbrique ne se
            // relit pas de maniere fiable apres serialisation.
            public Dictionary<string, ulong> SkinChoisi = new Dictionary<string, ulong>();
        }

        private void Init()
        {
            LoadData();
        }

        private void OnServerInitialized()
        {
            BuildWeaponList();
            // Differe volontairement : les definitions Steam arrivent de facon
            // asynchrone apres le demarrage. Construit ici, le catalogue ne
            // recensait que 30 skins au lieu de 1650. Le parcours coute aussi
            // ~1,5 s, qu'on ne veut pas dans OnServerInitialized.
            timer.Once(45f, BuildSkinCatalog);
            // Les monuments irradient : sans purge, les participants meurent
            // sans tireur. On nettoie au lieu d'exclure les monuments chauds.
            timer.Every(3f, ClearRadiation);
            Puts($"Gun Game pret avec {_weapons.Count} armes. Le monument est choisi au premier /gungame.");
        }

        private void Unload()
        {
            foreach (BasePlayer player in BasePlayer.activePlayerList.ToArray())
            {
                if (_activePlayers.Contains(player.userID))
                {
                    ReturnPlayer(player);
                }
                RemoveGunGameItems(player);
            }
            RemoveArena();
            SaveData();
        }

        private void OnServerSave()
        {
            SaveData();
        }

        private object IsGunGameFight(BasePlayer attacker, BasePlayer victim)
        {
            if (attacker == null || victim == null)
            {
                return false;
            }
            return _activePlayers.Contains(attacker.userID) && _activePlayers.Contains(victim.userID);
        }

        // Conserve pour les extensions qui interrogent ce hook : le Gun Game
        // n'a plus de bots, la reponse est donc toujours negative.
        private object IsGunGameBot(BasePlayer player)
        {
            return false;
        }

        /// <summary>
        /// Source unique des gardes inter-modes, avec un message par mode plutot
        /// qu'un "quitte ton mode" generique.
        /// </summary>
        private string DescribeOtherMode(BasePlayer player)
        {
            string[][] guards =
            {
                new[] { "IsZombieParticipant", "Quitte d'abord le mode Zombie avec /zombie." },
                new[] { "IsDuelParticipant", "Quitte d'abord le mode Duel avec /duel leave." },
                new[] { "IsCompetitiveModeParticipant", "Quitte d'abord le mode competitif avec /mode leave." },
                new[] { "IsTowerDefenseParticipant", "Quitte d'abord le Tower Defense avec /td." },
                new[] { "IsTrainingParticipant", "Quitte d'abord l'entrainement avec /entrainement quitter." },
                new[] { "IsBattlefieldParticipant", "Quitte d'abord Battlefield avec /bf." }
            };
            foreach (string[] guard in guards)
            {
                object hook = Interface.CallHook(guard[0], player);
                if (hook is bool && (bool)hook) return guard[1];
            }
            return null;
        }

        private object ForceLeaveMode(BasePlayer player)
        {
            if (player == null || !_activePlayers.Contains(player.userID)) return null;
            Leave(player);
            return true;
        }

        private object GetGunGamePlayerStats(BasePlayer player)
        {
            if (player == null) return null;
            return $"etape={GetValue(_data.Etapes, player.userID)}/{_weapons.Count} victoires={GetValue(_data.Victoires, player.userID)} eliminations={GetValue(_data.Eliminations, player.userID)}";
        }

        private object IsGunGameParticipant(BasePlayer player)
        {
            return player != null && _activePlayers.Contains(player.userID);
        }

        private object JoinGunGameFromLobby(BasePlayer player)
        {
            if (player == null) return false;
            if (!_activePlayers.Contains(player.userID)) CommandGunGame(player, "gungame", new string[0]);
            return _activePlayers.Contains(player.userID);
        }

        private object OnEntityTakeDamage(BaseCombatEntity entity, HitInfo info)
        {
            if (entity == null || info == null)
            {
                return null;
            }

            BasePlayer victim = entity as BasePlayer;

            // La radiation n'a pas d'attaquant : ce test doit passer AVANT le
            // filtre sur InitiatorPlayer, sinon les monuments chauds tuent.
            if (victim != null && _activePlayers.Contains(victim.userID) && info.damageTypes != null)
            {
                info.damageTypes.Scale(Rust.DamageType.Radiation, 0f);
            }

            BasePlayer attacker = info.InitiatorPlayer;
            if (victim == null || attacker == null)
            {
                return null;
            }

            bool victimInArena = IsHumanPlayer(victim) && _activePlayers.Contains(victim.userID);
            bool attackerInArena = IsHumanPlayer(attacker) && _activePlayers.Contains(attacker.userID);

            // Duel entre participants : degats normaux.
            if (victimInArena && attackerInArena)
            {
                return null;
            }

            // Un participant ne peut ni frapper ni etre frappe hors du mode :
            // les scientifiques du monument sont donc inoffensifs pour lui.
            if (victimInArena || attackerInArena)
            {
                info.damageTypes.ScaleAll(0f);
                return true;
            }
            return null;
        }

        private void OnWeaponFired(BaseProjectile projectile, BasePlayer player, ItemModProjectile mod, ProtoBuf.ProjectileShoot projectiles)
        {
            if (projectile == null || player == null || !_activePlayers.Contains(player.userID))
            {
                return;
            }

            timer.Once(0.01f, () =>
            {
                if (projectile == null || projectile.IsDestroyed || projectile.primaryMagazine == null)
                {
                    return;
                }

                projectile.primaryMagazine.contents = projectile.primaryMagazine.capacity;
                projectile.SendNetworkUpdateImmediate();
            });
        }

        private void OnItemUse(Item item, int amountToUse)
        {
            if (item == null || item.info == null)
            {
                return;
            }

            BasePlayer player = item.GetOwnerPlayer();
            if (player == null || !_activePlayers.Contains(player.userID) || _weapons.Count == 0)
            {
                return;
            }

            int stage = Mathf.Clamp(GetStage(player.userID), 0, _weapons.Count - 1);
            if (item.info.shortname != _weapons[stage].shortname || !IsConsumableWeapon(item.info.shortname))
            {
                return;
            }

            timer.Once(0.1f, () =>
            {
                if (player != null && player.IsConnected && _activePlayers.Contains(player.userID)) GiveCurrentWeapon(player);
            });
        }

        /// <summary>
        /// Vide l'equipement Gun Game AVANT que le cadavre ne se forme. Sans
        /// ce hook, chaque mort laissait une arme -- desormais skinnee -- et
        /// une armure a ramasser : une ferme a equipement en quelques manches.
        /// </summary>
        private object OnPlayerDeath(BasePlayer player, HitInfo info)
        {
            if (player != null && _activePlayers.Contains(player.userID))
            {
                RemoveGunGameItems(player);
            }
            return null;
        }

        private void OnEntityDeath(BaseCombatEntity entity, HitInfo info)
        {
            BasePlayer victim = entity as BasePlayer;
            if (victim == null)
            {
                return;
            }

            BasePlayer killer = info != null ? info.InitiatorPlayer : null;
            if (!IsHumanPlayer(victim) || !_activePlayers.Contains(victim.userID))
            {
                return;
            }

            if (IsHumanPlayer(killer) && _activePlayers.Contains(killer.userID) && killer != victim)
            {
                if (UsedCurrentWeapon(killer))
                {
                    Advance(killer, victim.displayName);
                }
                else
                {
                    SendReply(killer, "Frag non compte : utilise l'arme Gun Game actuelle.");
                }
            }

            timer.Once(2f, () => RespawnParticipant(victim));
        }

        private void OnPlayerRespawned(BasePlayer player)
        {
            if (player == null || !_activePlayers.Contains(player.userID))
            {
                return;
            }
            timer.Once(0.2f, () =>
            {
                if (player != null && player.IsConnected)
                {
                    TeleportToArenaSpawn(player);
                    GiveCurrentWeapon(player);
                    RestoreStats(player);
                }
            });
        }

        private void OnPlayerDisconnected(BasePlayer player, string reason)
        {
            if (player == null)
            {
                return;
            }
            _activePlayers.Remove(player.userID);
            _returnPositions.Remove(player.userID);
            RemoveGunGameItems(player);
            if (_activePlayers.Count == 0)
            {
                RemoveArena();
            }
        }

        // ----- Menu de selection des skins ---------------------------------------

        private const string SkinPanel = "rustgungame.skins";
        private const int SkinsPerPage = 15;
        private readonly Dictionary<ulong, int> _skinMenuWeapon = new Dictionary<ulong, int>();
        private readonly Dictionary<ulong, int> _skinMenuPage = new Dictionary<ulong, int>();

        /// <summary>
        /// Les ancres CUI sont des chaines : une locale francaise ecrirait
        /// "0,44" et casserait toute la mise en page en silence.
        /// </summary>
        private string Anchor(float x, float y)
        {
            return x.ToString(CultureInfo.InvariantCulture) + " " + y.ToString(CultureInfo.InvariantCulture);
        }

        /// <summary>
        /// Affiche la grille de skins. Le panneau est parente a "Hud.Menu" :
        /// il ne s'affiche que l'inventaire ouvert, donc il ne peut jamais
        /// verrouiller le curseur du joueur ni survivre a une partie.
        /// </summary>
        private void ShowSkinMenu(BasePlayer player, int weaponIndex, int page)
        {
            if (player == null || !player.IsConnected) return;
            if (_skinWeapons.Count == 0)
            {
                SendReply(player, "Aucune arme chargee.");
                return;
            }

            weaponIndex = ((weaponIndex % _skinWeapons.Count) + _skinWeapons.Count) % _skinWeapons.Count;
            ItemDefinition definition = _skinWeapons[weaponIndex];
            List<SkinEntry> list = SkinsFor(definition.shortname) ?? new List<SkinEntry>();

            int pages = Mathf.Max(1, Mathf.CeilToInt(list.Count / (float)SkinsPerPage));
            page = Mathf.Clamp(page, 0, pages - 1);

            _skinMenuWeapon[player.userID] = weaponIndex;
            _skinMenuPage[player.userID] = page;

            CuiHelper.DestroyUi(player, SkinPanel);
            CuiElementContainer container = new CuiElementContainer();

            string panel = container.Add(new CuiPanel
            {
                Image = { Color = "0.09 0.08 0.07 0.98" },
                RectTransform = { AnchorMin = "0.08 0.12", AnchorMax = "0.92 0.90" }
                // Pas de CursorEnabled : celui de l'inventaire suffit, et en
                // ajouter un second entre en conflit avec le jeu.
            }, "Hud.Menu", SkinPanel);

            container.Add(new CuiPanel
            {
                Image = { Color = "0.83 0.29 0.18 1" },
                RectTransform = { AnchorMin = "0 0.93", AnchorMax = "1 1" }
            }, panel);

            container.Add(new CuiLabel
            {
                Text = { Text = "  SKINS - " + WeaponName(definition), FontSize = 17, Align = TextAnchor.MiddleLeft, Color = "1 0.97 0.93 1" },
                RectTransform = { AnchorMin = "0.01 0.93", AnchorMax = "0.55 1" }
            }, panel);

            container.Add(new CuiLabel
            {
                Text = { Text = list.Count + " skins - page " + (page + 1) + "/" + pages + "  ", FontSize = 12, Align = TextAnchor.MiddleRight, Color = "1 0.97 0.93 0.9" },
                RectTransform = { AnchorMin = "0.55 0.93", AnchorMax = "0.88 1" }
            }, panel);

            SkinButton(container, panel, 0.90f, 0.985f, 0.935f, 0.995f, "FERMER", "gg.skin.close", "0.62 0.18 0.15 1", 11);

            // Navigation d'arme : on prepare le skin de n'importe quelle arme,
            // pas seulement celle du palier courant.
            SkinButton(container, panel, 0.01f, 0.07f, 0.86f, 0.92f, "<", "gg.skin.open " + (weaponIndex - 1) + " 0", "0.22 0.20 0.17 1", 14);
            container.Add(new CuiLabel
            {
                Text = { Text = "Arme " + (weaponIndex + 1) + "/" + _skinWeapons.Count, FontSize = 12, Align = TextAnchor.MiddleCenter, Color = "0.85 0.82 0.78 1" },
                RectTransform = { AnchorMin = Anchor(0.07f, 0.86f), AnchorMax = Anchor(0.33f, 0.92f) }
            }, panel);
            SkinButton(container, panel, 0.33f, 0.39f, 0.86f, 0.92f, ">", "gg.skin.open " + (weaponIndex + 1) + " 0", "0.22 0.20 0.17 1", 14);

            string mode = SkinMode(player.userID);
            SkinButton(container, panel, 0.60f, 0.76f, 0.86f, 0.92f, "ALEATOIRE",
                "gg.skin.mode random", mode == "random" ? "0.83 0.29 0.18 1" : "0.22 0.20 0.17 1", 11);
            SkinButton(container, panel, 0.77f, 0.89f, 0.86f, 0.92f, "AUCUN",
                "gg.skin.mode off", mode == "off" ? "0.83 0.29 0.18 1" : "0.22 0.20 0.17 1", 11);

            if (list.Count == 0)
            {
                container.Add(new CuiLabel
                {
                    Text = { Text = "Aucun skin connu pour cette arme.", FontSize = 14, Align = TextAnchor.MiddleCenter, Color = "0.75 0.72 0.68 1" },
                    RectTransform = { AnchorMin = "0.1 0.4", AnchorMax = "0.9 0.6" }
                }, panel);
                CuiHelper.AddUi(player, container);
                return;
            }

            ulong current = CurrentSkinFor(player, definition.shortname);
            int start = page * SkinsPerPage;
            int count = Mathf.Min(SkinsPerPage, list.Count - start);

            const int cols = 5;
            const float gridTop = 0.82f;
            const float gridBottom = 0.14f;
            float cellW = 0.96f / cols;
            float cellH = (gridTop - gridBottom) / 3f;

            for (int i = 0; i < count; i++)
            {
                SkinEntry entry = list[start + i];
                int col = i % cols;
                int row = i / cols;

                float minX = 0.02f + col * cellW + 0.005f;
                float maxX = 0.02f + (col + 1) * cellW - 0.005f;
                float maxY = gridTop - row * cellH - 0.008f;
                float minY = gridTop - (row + 1) * cellH + 0.008f;

                bool selected = current != 0UL && current == entry.Id;

                // Le bouton occupe toute la case et porte le clic. En CUI, seule
                // une CuiButton intercepte le clic : une image posee par-dessus
                // ne le vole pas.
                string cell = container.Add(new CuiButton
                {
                    Button = { Command = "gg.skin.pick " + weaponIndex + " " + (start + i), Color = selected ? "0.83 0.29 0.18 0.95" : "0.17 0.16 0.14 0.95" },
                    Text = { Text = "" },
                    RectTransform = { AnchorMin = Anchor(minX, minY), AnchorMax = Anchor(maxX, maxY) }
                }, panel);

                if (!string.IsNullOrEmpty(entry.Icone))
                {
                    container.Add(new CuiElement
                    {
                        Parent = cell,
                        Components =
                        {
                            new CuiRawImageComponent { Url = entry.Icone },
                            new CuiRectTransformComponent { AnchorMin = "0.15 0.32", AnchorMax = "0.85 0.95" }
                        }
                    });
                }

                container.Add(new CuiLabel
                {
                    Text = { Text = Shorten(entry.Nom, 22), FontSize = 9, Align = TextAnchor.MiddleCenter, Color = "0.92 0.89 0.85 1" },
                    RectTransform = { AnchorMin = "0.02 0.02", AnchorMax = "0.98 0.3" }
                }, cell);
            }

            if (page > 0)
            {
                SkinButton(container, panel, 0.02f, 0.14f, 0.045f, 0.105f, "< PRECEDENT", "gg.skin.open " + weaponIndex + " " + (page - 1), "0.22 0.20 0.17 1", 11);
            }
            if (page < pages - 1)
            {
                SkinButton(container, panel, 0.86f, 0.98f, 0.045f, 0.105f, "SUIVANT >", "gg.skin.open " + weaponIndex + " " + (page + 1), "0.22 0.20 0.17 1", 11);
            }

            CuiHelper.AddUi(player, container);
        }

        private void SkinButton(CuiElementContainer container, string parent, float minX, float maxX, float minY, float maxY, string label, string command, string color, int fontSize)
        {
            container.Add(new CuiButton
            {
                Button = { Command = command, Color = color },
                Text = { Text = label, FontSize = fontSize, Align = TextAnchor.MiddleCenter, Color = "1 0.97 0.93 1" },
                RectTransform = { AnchorMin = Anchor(minX, minY), AnchorMax = Anchor(maxX, maxY) }
            }, parent);
        }

        private string Shorten(string value, int max)
        {
            if (string.IsNullOrEmpty(value)) return "";
            return value.Length <= max ? value : value.Substring(0, max - 1) + "...";
        }

        private ulong CurrentSkinFor(BasePlayer player, string shortname)
        {
            if (_data.SkinChoisi == null) return 0UL;
            ulong chosen;
            return _data.SkinChoisi.TryGetValue(SkinKey(player.userID, shortname), out chosen) ? chosen : 0UL;
        }

        private int SkinIndexFor(BasePlayer player)
        {
            // L'arme en main d'abord, puis celle du palier Gun Game, sinon la premiere.
            Item active = player != null ? player.GetActiveItem() : null;
            if (active != null && active.info != null)
            {
                int held = _skinWeapons.FindIndex(definition => definition.shortname == active.info.shortname);
                if (held >= 0) return held;
            }
            if (player != null && _activePlayers.Contains(player.userID) && _weapons.Count > 0)
            {
                ItemDefinition current = _weapons[Mathf.Clamp(GetStage(player.userID), 0, _weapons.Count - 1)];
                int stage = _skinWeapons.IndexOf(current);
                if (stage >= 0) return stage;
            }
            return 0;
        }

        private void CloseSkinMenu(BasePlayer player)
        {
            if (player == null) return;
            _skinMenuWeapon.Remove(player.userID);
            _skinMenuPage.Remove(player.userID);
            if (player.IsConnected) CuiHelper.DestroyUi(player, SkinPanel);
        }

        [ConsoleCommand("gg.skin.open")]
        private void ConsoleSkinOpen(ConsoleSystem.Arg arg)
        {
            BasePlayer player = arg.Player();
            if (player == null) return;
            string[] args = ConsoleArgs(arg);
            // Sans argument (bouton MES SKINS) : on ouvre sur l'arme tenue en main.
            int weapon = args.Length > 0 ? ParseInt(args[0], 0) : SkinIndexFor(player);
            int page = args.Length > 1 ? ParseInt(args[1], 0) : 0;
            ShowSkinMenu(player, weapon, page);
        }

        [ConsoleCommand("gg.skin.close")]
        private void ConsoleSkinClose(ConsoleSystem.Arg arg)
        {
            CloseSkinMenu(arg.Player());
        }

        [ConsoleCommand("gg.skin.mode")]
        private void ConsoleSkinMode(ConsoleSystem.Arg arg)
        {
            BasePlayer player = arg.Player();
            if (player == null) return;
            string[] args = ConsoleArgs(arg);
            string mode = args.Length > 0 ? args[0].ToLowerInvariant() : "random";
            if (mode != "off" && mode != "random") mode = "random";

            _data.ModeSkin[player.userID] = mode;
            SaveData();
            SendReply(player, mode == "off" ? "Skins desactives." : "Skins aleatoires a chaque arme.");
            if (_activePlayers.Contains(player.userID)) GiveCurrentWeapon(player);

            int weapon, page;
            ShowSkinMenu(player,
                _skinMenuWeapon.TryGetValue(player.userID, out weapon) ? weapon : 0,
                _skinMenuPage.TryGetValue(player.userID, out page) ? page : 0);
        }

        [ConsoleCommand("gg.skin.pick")]
        private void ConsoleSkinPick(ConsoleSystem.Arg arg)
        {
            BasePlayer player = arg.Player();
            if (player == null) return;
            string[] args = ConsoleArgs(arg);
            if (args.Length < 2) return;

            int weaponIndex = ParseInt(args[0], 0);
            int skinIndex = ParseInt(args[1], -1);
            if (_skinWeapons.Count == 0) return;
            weaponIndex = ((weaponIndex % _skinWeapons.Count) + _skinWeapons.Count) % _skinWeapons.Count;

            ItemDefinition definition = _skinWeapons[weaponIndex];
            List<SkinEntry> list = SkinsFor(definition.shortname);
            if (list == null || skinIndex < 0 || skinIndex >= list.Count) return;

            SkinEntry entry = list[skinIndex];
            ulong already = CurrentSkinFor(player, definition.shortname);

            if (already == entry.Id)
            {
                // Deuxieme clic sur le meme skin : on le retire.
                _data.SkinChoisi.Remove(SkinKey(player.userID, definition.shortname));
                SendReply(player, "Skin retire pour " + WeaponName(definition) + ".");
            }
            else
            {
                _data.ModeSkin[player.userID] = "pick";
                _data.SkinChoisi[SkinKey(player.userID, definition.shortname)] = entry.Id;
                SendReply(player, WeaponName(definition) + " : <color=#ffd479>" + entry.Nom + "</color>.");
            }

            SaveData();
            if (_activePlayers.Contains(player.userID)) GiveCurrentWeapon(player);

            int page;
            ShowSkinMenu(player, weaponIndex, _skinMenuPage.TryGetValue(player.userID, out page) ? page : 0);
        }

        private int ParseInt(string value, int fallback)
        {
            int parsed;
            return int.TryParse(value, out parsed) ? parsed : fallback;
        }

        /// <summary>
        /// Les skins choisis dans le Gun Game servent aussi aux autres modes
        /// (Battlefield) : un seul endroit pour les regler.
        /// </summary>
        private object GetPlayerWeaponSkin(BasePlayer player, string shortname)
        {
            if (player == null || string.IsNullOrEmpty(shortname)) return null;
            ItemDefinition definition = ItemManager.FindItemDefinition(shortname);
            if (definition == null) return null;
            ulong skin = ResolveSkin(player, definition);
            return skin == 0UL ? null : (object)skin;
        }

        [ConsoleCommand("ggskins.reload")]
        private void ConsoleReloadSkins(ConsoleSystem.Arg arg)
        {
            BasePlayer caller = arg.Player();
            if (caller != null && !caller.IsAdmin)
            {
                arg.ReplyWith("Commande reservee aux administrateurs.");
                return;
            }
            BuildSkinCatalog();
            int total = 0;
            foreach (var pair in _skins) total += pair.Value.Count;
            arg.ReplyWith($"Catalogue reconstruit : {total} skins sur {_skins.Count} armes.");
        }

        [ChatCommand("ggskin")]
        private void CommandSkin(BasePlayer player, string command, string[] args)
        {
            if (player == null) return;

            string sub = args != null && args.Length > 0 ? args[0].ToLowerInvariant() : "";

            // Sans argument : on ouvre la grille. Choisir parmi 336 skins dans
            // le chat n existe pas comme experience utilisable.
            if (sub == "")
            {
                ShowSkinMenu(player, SkinIndexFor(player), 0);
                SendReply(player, "Ouvre ton inventaire pour voir la grille des skins.");
                return;
            }

            if (sub == "off" || sub == "aucun")
            {
                _data.ModeSkin[player.userID] = "off";
                SaveData();
                SendReply(player, "Skins desactives : armes par defaut.");
                return;
            }

            if (sub == "random" || sub == "aleatoire" || sub == "")
            {
                _data.ModeSkin[player.userID] = "random";
                SaveData();
                SendReply(player, "Skins aleatoires a chaque arme. <color=#ffd479>/ggskin liste</color> pour choisir.");
                return;
            }

            // Les commandes suivantes portent sur l'arme du palier courant.
            int stage = Mathf.Clamp(GetStage(player.userID), 0, Mathf.Max(0, _weapons.Count - 1));
            if (_weapons.Count == 0) { SendReply(player, "Aucune arme chargee."); return; }
            ItemDefinition definition = _weapons[stage];
            List<SkinEntry> list = SkinsFor(definition.shortname);

            if (list == null || list.Count == 0)
            {
                SendReply(player, $"Aucun skin connu pour {WeaponName(definition)}.");
                return;
            }

            if (sub == "liste" || sub == "list" || sub == "skins")
            {
                SendReply(player, $"<color=#ffd479>{WeaponName(definition)}</color> : {list.Count} skins. <color=#ffd479>/ggskin <numero></color> pour en fixer un.");
                int shown = Mathf.Min(list.Count, 12);
                for (int i = 0; i < shown; i++)
                {
                    SendReply(player, $"  {i + 1}. {list[i].Nom}");
                }
                if (list.Count > shown) SendReply(player, $"  ... et {list.Count - shown} autres.");
                return;
            }

            int index;
            if (int.TryParse(sub, out index) && index >= 1 && index <= list.Count)
            {
                _data.ModeSkin[player.userID] = "pick";
                _data.SkinChoisi[SkinKey(player.userID, definition.shortname)] = list[index - 1].Id;
                SaveData();
                SendReply(player, $"Skin fixe pour {WeaponName(definition)} : <color=#ffd479>{list[index - 1].Nom}</color>.");
                if (_activePlayers.Contains(player.userID)) GiveCurrentWeapon(player);
                return;
            }

            SendReply(player, "Usage : /ggskin liste | <numero> | random | off");
        }

        [ChatCommand("gungame")]
        private void CommandGunGame(BasePlayer player, string command, string[] args)
        {
            if (_weapons.Count == 0)
            {
                SendReply(player, "Le Gun Game n'a trouve aucune arme utilisable.");
                return;
            }

            if (_activePlayers.Contains(player.userID))
            {
                Leave(player);
                return;
            }

            string otherMode = DescribeOtherMode(player);
            if (otherMode != null)
            {
                SendReply(player, otherMode);
                return;
            }

            Join(player);
        }

        [ConsoleCommand("gungame")]
        private void ConsoleGunGame(ConsoleSystem.Arg arg)
        {
            BasePlayer player = arg.Player();
            if (player == null)
            {
                arg.ReplyWith("Cette commande doit etre utilisee par un joueur.");
                return;
            }
            CommandGunGame(player, "gungame", ConsoleArgs(arg));
        }

        [ConsoleCommand("ggforce")]
        private void ConsoleForceJoin(ConsoleSystem.Arg arg)
        {
            BasePlayer caller = arg.Player();
            if (caller != null && !caller.IsAdmin)
            {
                arg.ReplyWith("Commande reservee aux administrateurs.");
                return;
            }

            string selector = arg.Args != null && arg.Args.Length > 0 ? arg.Args[0].ToString() : string.Empty;
            BasePlayer target = BasePlayer.activePlayerList.FirstOrDefault(player =>
                string.IsNullOrEmpty(selector) ||
                player.UserIDString == selector ||
                player.displayName.IndexOf(selector, StringComparison.OrdinalIgnoreCase) >= 0);

            if (target == null)
            {
                arg.ReplyWith("Joueur connecte introuvable.");
                return;
            }

            if (!_activePlayers.Contains(target.userID)) Join(target);
            else TeleportToArenaSpawn(target);
            arg.ReplyWith($"{target.displayName} est dans l'arene Gun Game.");
        }

        [ChatCommand("gg")]
        private void CommandStatus(BasePlayer player, string command, string[] args)
        {
            int victories = GetValue(_data.Victoires, player.userID);
            int kills = GetValue(_data.Eliminations, player.userID);
            if (!_activePlayers.Contains(player.userID))
            {
                SendReply(player, $"Gun Game FFA inactif - {victories} victoire(s), {kills} frag(s). Tape /gungame.");
                return;
            }

            int stage = Mathf.Clamp(GetStage(player.userID), 0, Math.Max(0, _weapons.Count - 1));
            SendReply(player, $"Arme {stage + 1}/{_weapons.Count} - <color=#ffd479>{WeaponName(_weapons[stage])}</color> - {kills} frag(s), {victories} victoire(s).");
        }

        [ConsoleCommand("gg")]
        private void ConsoleStatus(ConsoleSystem.Arg arg)
        {
            BasePlayer player = arg.Player();
            if (player != null) CommandStatus(player, "gg", ConsoleArgs(arg));
        }

        [ChatCommand("gglist")]
        private void CommandList(BasePlayer player, string command, string[] args)
        {
            int page = 1;
            if (args.Length > 0)
            {
                int parsed;
                if (int.TryParse(args[0], out parsed)) page = Mathf.Max(1, parsed);
            }

            const int perPage = 12;
            int pages = Math.Max(1, Mathf.CeilToInt(_weapons.Count / (float)perPage));
            page = Mathf.Clamp(page, 1, pages);
            int start = (page - 1) * perPage;
            IEnumerable<string> names = _weapons.Skip(start).Take(perPage).Select((weapon, index) => $"{start + index + 1}. {WeaponName(weapon)}");
            SendReply(player, $"<color=#ffd479>Gun Game - page {page}/{pages}</color>");
            SendReply(player, string.Join(" | ", names.ToArray()));
        }

        [ConsoleCommand("gglist")]
        private void ConsoleList(ConsoleSystem.Arg arg)
        {
            BasePlayer player = arg.Player();
            if (player != null) CommandList(player, "gglist", ConsoleArgs(arg));
        }

        [ChatCommand("ggreset")]
        private void CommandReset(BasePlayer player, string command, string[] args)
        {
            _data.Etapes[player.userID] = 0;
            if (_activePlayers.Contains(player.userID)) GiveCurrentWeapon(player);
            SaveData();
            SendReply(player, "Progression de la manche remise a zero.");
        }

        [ConsoleCommand("ggreset")]
        private void ConsoleReset(ConsoleSystem.Arg arg)
        {
            BasePlayer player = arg.Player();
            if (player != null) CommandReset(player, "ggreset", ConsoleArgs(arg));
        }

        [ChatCommand("arena")]
        private void CommandArena(BasePlayer player, string command, string[] args)
        {
            if (_activePlayers.Contains(player.userID))
            {
                TeleportToArenaSpawn(player);
                SendReply(player, "Retour dans l'arene Gun Game.");
            }
            else
            {
                SendReply(player, "Tape /gungame pour entrer dans l'arene FFA.");
            }
        }

        [ConsoleCommand("ggarena.random")]
        private void ConsoleRandomArena(ConsoleSystem.Arg arg)
        {
            BasePlayer caller = arg.Player();
            if (caller != null && !caller.IsAdmin)
            {
                arg.ReplyWith("Commande reservee aux administrateurs.");
                return;
            }
            if (_activePlayers.Count > 0)
            {
                arg.ReplyWith("Impossible de deplacer l'arene pendant une manche.");
                return;
            }

            BuildArena();
            arg.ReplyWith($"Nouvelle arene Gun Game generee en {_arenaCenter}.");
        }

        [ConsoleCommand("ggdebug")]
        private void ConsoleDebug(ConsoleSystem.Arg arg)
        {
            BasePlayer caller = arg.Player();
            if (caller != null && !caller.IsAdmin)
            {
                arg.ReplyWith("Commande reservee aux administrateurs.");
                return;
            }
            arg.ReplyWith($"players={_activePlayers.Count} weapons={_weapons.Count} monument=\"{_arenaName}\" rayon={_arenaRadius:F0} centre={_arenaCenter}");
        }

        [ConsoleCommand("gg.stop")]
        private void ConsoleStop(ConsoleSystem.Arg arg)
        {
            BasePlayer caller = arg.Player();
            if (caller != null && !caller.IsAdmin)
            {
                arg.ReplyWith("Commande reservee aux administrateurs.");
                return;
            }

            foreach (ulong userId in _activePlayers.ToArray())
            {
                BasePlayer player = BasePlayer.activePlayerList.FirstOrDefault(candidate => candidate.userID == userId);
                _activePlayers.Remove(userId);
                if (player == null) continue;
                RemoveGunGameItems(player);
                ReturnPlayer(player);
                SendReply(player, "Gun Game arrete par un administrateur.");
            }
            _activePlayers.Clear();
            RemoveArena();
            SaveData();
            arg.ReplyWith("Gun Game arrete et arene retiree.");
        }

        private object GetGunGameDashboardStatus()
        {
            return $"joueurs={_activePlayers.Count} armes={_weapons.Count} monument={_arenaName} actif={_activePlayers.Count > 0}";
        }

        private void Join(BasePlayer player)
        {
            if (_activePlayers.Count == 0)
            {
                BuildArena();
            }
            _returnPositions[player.userID] = player.transform.position;
            _data.Etapes[player.userID] = 0;
            _activePlayers.Add(player.userID);
            TeleportToArenaSpawn(player);
            GiveCurrentWeapon(player);
            RestoreStats(player);
            BroadcastArena($"<color=#ffd479>{player.displayName}</color> rejoint le Gun Game FFA.");
            SendReply(player, $"<color=#ffd479>Gun Game CS active !</color> {_weapons.Count} armes, respawn rapide, une nouvelle arme par frag.");
            SendReply(player, "Tape /gungame pour quitter et revenir a ta position precedente.");
            SaveData();
        }

        private void Leave(BasePlayer player)
        {
            _activePlayers.Remove(player.userID);
            RemoveGunGameItems(player);
            ReturnPlayer(player);
            SendReply(player, "Tu as quitte l'arene Gun Game.");
            if (_activePlayers.Count == 0)
            {
                RemoveArena();
                Puts("Arene Gun Game retiree. La prochaine activation choisira un nouvel emplacement.");
            }
            SaveData();
        }

        private void ReturnPlayer(BasePlayer player)
        {
            Vector3 position;
            if (player != null && _returnPositions.TryGetValue(player.userID, out position))
            {
                player.Teleport(position);
                _returnPositions.Remove(player.userID);
            }
        }

        private void RespawnParticipant(BasePlayer player)
        {
            if (player == null || !player.IsConnected || !_activePlayers.Contains(player.userID))
            {
                return;
            }

            if (player.IsDead())
            {
                player.RespawnAt(GetArenaSpawn(), Quaternion.identity);
            }
        }

        private void Advance(BasePlayer player, string victimName)
        {
            int nextStage = GetStage(player.userID) + 1;
            _data.Eliminations[player.userID] = GetValue(_data.Eliminations, player.userID) + 1;
            RemoveGunGameItems(player);

            if (nextStage >= _weapons.Count)
            {
                _data.Etapes[player.userID] = 0;
                _data.Victoires[player.userID] = GetValue(_data.Victoires, player.userID) + 1;
                BroadcastArena($"<color=#ffd479>{player.displayName} remporte la manche Gun Game !</color>");
                SendReply(player, "Victoire ! Nouvelle manche dans 3 secondes. Recompense : 750 XP et 1500 pieces.");
                Interface.CallHook("OnGunGameCompleted", player);
                timer.Once(3f, () =>
                {
                    if (player != null && player.IsConnected && _activePlayers.Contains(player.userID)) GiveCurrentWeapon(player);
                });
            }
            else
            {
                _data.Etapes[player.userID] = nextStage;
                SendReply(player, $"Frag sur {victimName} - arme suivante.");
                GiveCurrentWeapon(player);
            }
            SaveData();
        }

        private bool UsedCurrentWeapon(BasePlayer player)
        {
            if (player == null || _weapons.Count == 0)
            {
                return false;
            }
            Item active = player.GetActiveItem();
            int stage = Mathf.Clamp(GetStage(player.userID), 0, _weapons.Count - 1);
            return active != null && active.info != null && active.info.shortname == _weapons[stage].shortname;
        }

        /// <summary>
        /// Choisit le monument d'accueil. On ne construit plus rien : le decor
        /// du jeu sert d'arene, ce qui donne du relief et de la couverture que
        /// seize murs de pierre ne reproduisaient pas.
        /// </summary>
        private void BuildArena()
        {
            RemoveArena();

            MonumentInfo chosen = SelectMonument();
            if (chosen == null)
            {
                // Aucun monument exploitable : on retombe au centre de carte
                // plutot que de refuser la partie.
                _arenaCenter = GroundPosition(Vector3.zero);
                _arenaRadius = 45f;
                _arenaName = "Centre de la carte";
                PrintWarning("Aucun monument exploitable : repli sur le centre de la carte.");
                return;
            }

            _arenaCenter = chosen.transform.position;
            _arenaName = MonumentLabel(chosen);

            // Les extents valent 0 sur les petits monuments : on borne pour
            // eviter une arene d'un metre comme une arene de toute la carte.
            float extent = 45f;
            try
            {
                Vector3 e = chosen.Bounds.extents;
                extent = Mathf.Max(e.x, e.z);
            }
            catch { }
            _arenaRadius = Mathf.Clamp(extent <= 1f ? 45f : extent, 30f, 110f);

            Puts($"Gun Game : monument \"{_arenaName}\" en {_arenaCenter}, rayon {_arenaRadius:F0} m.");
        }

        private MonumentInfo SelectMonument()
        {
            if (TerrainMeta.Path == null || TerrainMeta.Path.Monuments == null) return null;

            List<MonumentInfo> present = new List<MonumentInfo>();
            foreach (MonumentInfo m in TerrainMeta.Path.Monuments)
            {
                if (m != null && m.transform != null) present.Add(m);
            }
            if (present.Count == 0) return null;

            // On parcourt la liste de preference dans l'ordre : le premier rang
            // represente sur cette carte gagne. Sur une grande carte ce sera
            // Launch Site, sur une petite le Dome ou le port, sans changer le code.
            foreach (string key in PreferredMonuments)
            {
                List<MonumentInfo> matches = new List<MonumentInfo>();
                foreach (MonumentInfo m in present)
                {
                    string n = m.name != null ? m.name.ToLowerInvariant() : "";
                    if (n.Contains(key)) matches.Add(m);
                }
                if (matches.Count == 0) continue;
                // Plusieurs exemplaires (deux phares, deux plateformes) : on tire
                // au sort pour ne pas jouer toujours au meme endroit.
                return matches[UnityEngine.Random.Range(0, matches.Count)];
            }
            return null;
        }

        private string MonumentLabel(MonumentInfo monument)
        {
            if (monument == null) return "";
            try
            {
                if (monument.displayPhrase != null && !string.IsNullOrEmpty(monument.displayPhrase.english))
                {
                    return monument.displayPhrase.english;
                }
            }
            catch { }
            string n = monument.name ?? "monument";
            int slash = n.LastIndexOf('/');
            if (slash >= 0 && slash < n.Length - 1) n = n.Substring(slash + 1);
            return n.Replace(".prefab", "").Replace("(Clone)", "");
        }

        /// <summary>
        /// Les monuments irradient. Sans cette purge, un participant meurt sans
        /// qu'aucun joueur ne l'ait touche, et le frag n'est attribue a personne.
        /// </summary>
        /// <summary>
        /// Recense les skins disponibles pour chaque arme jouable. Les noms
        /// lisibles viennent de skins2 (catalogue Steam) ; skins ne porte que
        /// des chemins d'asset, on ne s'en sert qu'en secours.
        /// </summary>
        private void BuildSkinCatalog()
        {
            _skins.Clear();
            int total = 0;
            _skinWeapons.Clear();
            _skinWeapons.AddRange(_weapons);
            foreach (string extra in ExtraSkinWeapons)
            {
                ItemDefinition definition = ItemManager.FindItemDefinition(extra);
                if (definition != null && !_skinWeapons.Contains(definition)) _skinWeapons.Add(definition);
            }

            foreach (ItemDefinition definition in _skinWeapons)
            {
                if (definition == null) continue;
                List<SkinEntry> list = new List<SkinEntry>();

                try
                {
                    var steamSkins = definition.skins2;
                    if (steamSkins != null && steamSkins.Length > 0)
                    {
                        // L'interface IPlayerItemDefinition n'expose pas les deux
                        // membres utiles de maniere garantie selon les versions :
                        // on les lit par reflexion, une seule fois au chargement.
                        var type = steamSkins[0].GetType();
                        var propId = type.GetProperty("DefinitionId");
                        var propName = type.GetProperty("Name");
                        var propIcon = type.GetProperty("IconUrl");
                        if (propId != null)
                        {
                            foreach (var skin in steamSkins)
                            {
                                if (skin == null) continue;
                                object rawId = propId.GetValue(skin, null);
                                if (rawId == null) continue;
                                ulong id = Convert.ToUInt64(rawId);
                                if (id == 0UL) continue;
                                string nom = propName != null
                                    ? Convert.ToString(propName.GetValue(skin, null))
                                    : id.ToString();
                                string icone = propIcon != null
                                    ? Convert.ToString(propIcon.GetValue(skin, null))
                                    : "";
                                list.Add(new SkinEntry
                                {
                                    Id = id,
                                    Nom = string.IsNullOrEmpty(nom) ? id.ToString() : nom,
                                    Icone = icone
                                });
                            }
                        }
                    }
                }
                catch (Exception e)
                {
                    PrintWarning($"Skins indisponibles pour {definition.shortname} : {e.Message}");
                }

                if (list.Count == 0)
                {
                    try
                    {
                        var builtin = definition.skins;
                        if (builtin != null)
                        {
                            foreach (var skin in builtin)
                            {
                                if (skin.id == 0) continue;
                                list.Add(new SkinEntry { Id = (ulong)skin.id, Nom = "skin " + skin.id, Icone = "" });
                            }
                        }
                    }
                    catch { }
                }

                if (list.Count > 0)
                {
                    _skins[definition.shortname] = list;
                    total += list.Count;
                }
            }

            Puts($"Catalogue de skins : {total} skins sur {_skins.Count} armes.");
        }

        private string SkinMode(ulong userId)
        {
            string mode;
            if (_data.ModeSkin != null && _data.ModeSkin.TryGetValue(userId, out mode) && !string.IsNullOrEmpty(mode))
            {
                return mode;
            }
            return "random";
        }

        private List<SkinEntry> SkinsFor(string shortname)
        {
            List<SkinEntry> list;
            return _skins.TryGetValue(shortname, out list) ? list : null;
        }

        /// <summary>
        /// Rend l'identifiant de skin a poser sur l'arme, 0 pour aucun.
        /// </summary>
        private ulong ResolveSkin(BasePlayer player, ItemDefinition definition)
        {
            if (player == null || definition == null) return 0UL;
            List<SkinEntry> list = SkinsFor(definition.shortname);
            if (list == null || list.Count == 0) return 0UL;

            string mode = SkinMode(player.userID);
            if (mode == "off") return 0UL;

            if (mode == "pick" && _data.SkinChoisi != null)
            {
                ulong chosen;
                if (_data.SkinChoisi.TryGetValue(SkinKey(player.userID, definition.shortname), out chosen) && chosen != 0UL)
                {
                    return chosen;
                }
                // Aucun choix pour cette arme precise : on ne bloque pas la
                // partie, on tire au sort comme en mode random.
            }

            return list[UnityEngine.Random.Range(0, list.Count)].Id;
        }

        private string SkinKey(ulong userId, string shortname)
        {
            return userId + ":" + shortname;
        }

        /// <summary>
        /// Remet le participant a neuf. Sans cela on entre en Gun Game avec la
        /// vie, la faim et la soif de sa session de survie : un duel se decide
        /// avant d'avoir commence.
        /// </summary>
        private void RestoreStats(BasePlayer player)
        {
            if (player == null || !player.IsConnected || player.IsDead()) return;

            float max = player.MaxHealth();
            player.InitializeHealth(max, max);
            player.health = max;

            PlayerMetabolism m = player.metabolism;
            if (m != null)
            {
                if (m.calories != null) m.calories.value = m.calories.max;
                if (m.hydration != null) m.hydration.value = m.hydration.max;
                if (m.bleeding != null) m.bleeding.value = 0f;
                if (m.radiation_poison != null) m.radiation_poison.value = 0f;
                if (m.radiation_level != null) m.radiation_level.value = 0f;
                if (m.oxygen != null) m.oxygen.value = 1f;
                m.SendChangesToClient();
            }

            player.SendNetworkUpdateImmediate();
        }

        /// <summary>
        /// Equipe la panoplie legere. Chaque piece porte le prefixe Gun Game :
        /// c'est ce qui la fait disparaitre a la sortie, a la deconnexion et
        /// a la mort, au lieu de finir dans la base du joueur.
        /// </summary>
        private void GiveArmor(BasePlayer player)
        {
            if (player == null || !player.IsConnected || player.inventory == null) return;
            ItemContainer wear = player.inventory.containerWear;
            if (wear == null) return;

            foreach (string shortname in ArmorSet)
            {
                ItemDefinition definition = ItemManager.FindItemDefinition(shortname);
                if (definition == null)
                {
                    PrintWarning($"Piece d'armure introuvable : {shortname}");
                    continue;
                }

                // Deja portee : on ne duplique pas a chaque palier.
                bool worn = false;
                foreach (Item existing in wear.itemList)
                {
                    if (existing != null && existing.info == definition) { worn = true; break; }
                }
                if (worn) continue;

                Item piece = ItemManager.Create(definition, 1);
                if (piece == null) continue;
                piece.name = ItemPrefix + definition.displayName.english;
                if (piece.hasCondition) piece.condition = piece.maxCondition;

                // MoveToContainer plutot que GiveItem : GiveItem laisserait la
                // piece dans le sac au lieu de l'equiper.
                if (!piece.MoveToContainer(wear))
                {
                    piece.Remove();
                }
            }
        }

        private void ClearRadiation()
        {
            if (_activePlayers.Count == 0) return;
            foreach (BasePlayer player in BasePlayer.activePlayerList)
            {
                if (player == null || !_activePlayers.Contains(player.userID)) continue;
                if (player.metabolism == null) continue;
                if (player.metabolism.radiation_poison != null) player.metabolism.radiation_poison.value = 0f;
                if (player.metabolism.radiation_level != null) player.metabolism.radiation_level.value = 0f;
            }
        }

        private Vector3 GroundPosition(Vector3 position)
        {
            position.y = TerrainMeta.HeightMap.GetHeight(position);
            return position;
        }

        private void SpawnArenaEntity(string prefab, Vector3 position, Quaternion rotation)
        {
            BaseEntity entity = GameManager.server.CreateEntity(prefab, position, rotation, true);
            if (entity == null)
            {
                PrintWarning($"Prefab d'arene introuvable : {prefab}");
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
        }

        /// <summary>
        /// Huit points repartis en anneau dans le monument. Le rayon suit la
        /// taille reelle du monument : un anneau fixe de 31 m sortirait du Dome
        /// et tomberait au milieu du port.
        /// </summary>
        private Vector3 GetArenaSpawn()
        {
            float ring = Mathf.Clamp(_arenaRadius * 0.62f, 14f, 70f);
            const int points = 8;
            int index = _nextSpawnIndex++;

            // Plusieurs tentatives : un point peut tomber dans un batiment ou
            // dans l'eau. On tourne l'anneau plutot que d'abandonner.
            for (int attempt = 0; attempt < points; attempt++)
            {
                float angle = ((index + attempt) % points) * Mathf.PI * 2f / points;
                Vector3 offset = new Vector3(Mathf.Cos(angle), 0f, Mathf.Sin(angle)) * ring;
                Vector3 candidate = GroundPosition(_arenaCenter + offset);

                float water = TerrainMeta.WaterMap.GetHeight(candidate);
                if (candidate.y < water + 0.5f) continue;

                NavMeshHit navHit;
                if (NavMesh.SamplePosition(candidate + Vector3.up, out navHit, 10f, NavMesh.AllAreas))
                {
                    candidate = navHit.position;
                }
                candidate.y += 1.2f;
                return candidate;
            }

            Vector3 fallback = GroundPosition(_arenaCenter);
            fallback.y += 1.2f;
            return fallback;
        }

        private void TeleportToArenaSpawn(BasePlayer player)
        {
            if (player != null) player.Teleport(GetArenaSpawn());
        }

        private void BroadcastArena(string message)
        {
            foreach (BasePlayer player in BasePlayer.activePlayerList)
            {
                if (_activePlayers.Contains(player.userID)) SendReply(player, message);
            }
        }

        private void BuildWeaponList()
        {
            _weapons.Clear();
            List<string> unavailable = new List<string>();
            foreach (string shortname in PlayableWeaponOrder)
            {
                ItemDefinition definition = ItemManager.FindItemDefinition(shortname);
                if (definition == null || definition.category != ItemCategory.Weapon)
                {
                    unavailable.Add(shortname);
                    continue;
                }
                _weapons.Add(definition);
            }

            if (unavailable.Count > 0)
            {
                Puts($"Armes ignorees car absentes de cette version de Rust : {string.Join(", ", unavailable.ToArray())}");
            }
            if (_weapons.Count == 0)
            {
                PrintError("Aucune arme Gun Game jouable n'a ete trouvee.");
            }
        }

        private bool ContainsAny(string value, params string[] parts)
        {
            return parts.Any(value.Contains);
        }

        private void GiveCurrentWeapon(BasePlayer player)
        {
            if (player == null || !player.IsConnected || _weapons.Count == 0)
            {
                return;
            }

            RemoveGunGameItems(player);
            int stage = Mathf.Clamp(GetStage(player.userID), 0, _weapons.Count - 1);
            ItemDefinition definition = _weapons[stage];
            int amount = IsConsumableWeapon(definition.shortname) ? 5 : 1;
            Item weapon = ItemManager.Create(definition, amount);
            if (weapon == null)
            {
                PrintWarning($"Impossible de creer l'arme {definition.shortname}.");
                return;
            }

            weapon.name = ItemPrefix + WeaponName(definition);
            if (weapon.hasCondition) weapon.condition = weapon.maxCondition;

            // Le skin doit etre pose avant la remise en inventaire, et repercute
            // sur l'entite tenue : sans le second, l'arme reste par defaut a
            // l'ecran meme si l'objet porte bien le skin.
            ulong skinId = ResolveSkin(player, definition);
            if (skinId != 0UL)
            {
                weapon.skin = skinId;
                BaseEntity held = weapon.GetHeldEntity();
                if (held != null)
                {
                    held.skinID = skinId;
                    held.SendNetworkUpdate();
                }
            }

            player.GiveItem(weapon);
            ItemDefinition ammoDefinition = ResolveAmmoDefinition(weapon, definition.shortname);
            FillMagazine(weapon, ammoDefinition);
            timer.Once(0.15f, () => FillMagazine(weapon, ammoDefinition));
            GiveAmmo(player, ammoDefinition, definition.shortname);
            // Apres l'arme : GiveCurrentWeapon commence par retirer tous les
            // objets prefixes, l'armure comprise. La reposer ici garantit
            // qu'elle survit a chaque changement de palier et a /ggskin.
            GiveArmor(player);
            SendReply(player, $"Arme {stage + 1}/{_weapons.Count} : <color=#ffd479>{WeaponName(definition)}</color>");
        }

        private ItemDefinition ResolveAmmoDefinition(Item weapon, string weaponShortname)
        {
            BaseProjectile projectile = weapon != null ? weapon.GetHeldEntity() as BaseProjectile : null;
            if (projectile != null && projectile.primaryMagazine != null && projectile.primaryMagazine.ammoType != null)
            {
                return projectile.primaryMagazine.ammoType;
            }

            string fallbackShortname = AmmoFor(weaponShortname);
            return string.IsNullOrEmpty(fallbackShortname) ? null : ItemManager.FindItemDefinition(fallbackShortname);
        }

        private void FillMagazine(Item weapon, ItemDefinition ammoDefinition)
        {
            if (weapon == null)
            {
                return;
            }

            BaseProjectile projectile = weapon.GetHeldEntity() as BaseProjectile;
            if (projectile == null || projectile.primaryMagazine == null)
            {
                return;
            }

            if (ammoDefinition != null) projectile.primaryMagazine.ammoType = ammoDefinition;

            projectile.primaryMagazine.contents = projectile.primaryMagazine.capacity;
            projectile.SendNetworkUpdateImmediate();
            weapon.MarkDirty();
        }

        private void GiveAmmo(BasePlayer player, ItemDefinition ammoDefinition, string weaponShortname)
        {
            if (ammoDefinition == null) return;

            string ammo = ammoDefinition.shortname;
            int amount = ammo == "lowgradefuel" ? 500 : ammo.Contains("rocket") ? 8 : ammo.Contains("grenadelauncher") ? 16 : 128;
            Item ammunition = ItemManager.Create(ammoDefinition, amount);
            if (ammunition == null)
            {
                PrintWarning($"Munition introuvable : {ammo} pour {weaponShortname}.");
                return;
            }
            ammunition.name = ItemPrefix + "Munitions";
            player.GiveItem(ammunition);
        }

        private string AmmoFor(string shortname)
        {
            string name = shortname.ToLowerInvariant();
            if (name.Contains("bow") || name.Contains("crossbow")) return "arrow.wooden";
            if (name.Contains("speargun")) return "speargun.spear";
            if (name.Contains("nailgun")) return "ammo.nailgun.nails";
            if (name.Contains("eoka") || name.Contains("waterpipe")) return "ammo.handmade.shell";
            if (name.Contains("shotgun")) return "ammo.shotgun";
            if (ContainsAny(name, "pistol", "revolver", "python", "smg", "thompson", "mp5")) return "ammo.pistol";
            if (ContainsAny(name, "rifle", "sks", "lmg", "m249", "minigun")) return "ammo.rifle";
            if (name.Contains("multiplegrenadelauncher")) return "ammo.grenadelauncher.he";
            if (name.Contains("rocket.launcher")) return "ammo.rocket.basic";
            if (name.Contains("flamethrower")) return "lowgradefuel";
            return string.Empty;
        }

        private bool IsConsumableWeapon(string shortname)
        {
            string name = shortname.ToLowerInvariant();
            return ContainsAny(name, "grenade", "satchel", "explosive", "molotov");
        }

        private void RemoveGunGameItems(BasePlayer player)
        {
            if (player == null || player.inventory == null) return;

            List<Item> items = new List<Item>();
            if (player.inventory.containerMain != null) items.AddRange(player.inventory.containerMain.itemList);
            if (player.inventory.containerBelt != null) items.AddRange(player.inventory.containerBelt.itemList);
            if (player.inventory.containerWear != null) items.AddRange(player.inventory.containerWear.itemList);
            foreach (Item item in items)
            {
                if (item != null && !string.IsNullOrEmpty(item.name) && item.name.StartsWith(ItemPrefix, StringComparison.Ordinal)) item.Remove();
            }
        }

        private int GetStage(ulong userId)
        {
            return GetValue(_data.Etapes, userId);
        }

        private int GetValue(Dictionary<ulong, int> dictionary, ulong userId)
        {
            int value;
            return dictionary.TryGetValue(userId, out value) ? value : 0;
        }

        private string WeaponName(ItemDefinition definition)
        {
            if (definition == null || definition.displayName == null || string.IsNullOrEmpty(definition.displayName.english))
            {
                return definition != null ? definition.shortname : "Arme inconnue";
            }
            return definition.displayName.english;
        }

        private bool IsHumanPlayer(BasePlayer player)
        {
            return player != null && !player.IsNpc && player.userID.IsSteamId();
        }

        private string[] ConsoleArgs(ConsoleSystem.Arg arg)
        {
            return arg.Args == null ? new string[0] : arg.Args.Select(value => value.ToString()).ToArray();
        }

        private void LoadData()
        {
            try
            {
                _data = Interface.Oxide.DataFileSystem.ReadObject<StoredData>(Name);
            }
            catch
            {
                _data = new StoredData();
            }
            if (_data == null) _data = new StoredData();
            if (_data.Etapes == null) _data.Etapes = new Dictionary<ulong, int>();
            if (_data.Victoires == null) _data.Victoires = new Dictionary<ulong, int>();
            if (_data.Eliminations == null) _data.Eliminations = new Dictionary<ulong, int>();
            if (_data.ModeSkin == null) _data.ModeSkin = new Dictionary<ulong, string>();
            if (_data.SkinChoisi == null) _data.SkinChoisi = new Dictionary<string, ulong>();
        }

        private void SaveData()
        {
            Interface.Oxide.DataFileSystem.WriteObject(Name, _data);
        }
    }
}
