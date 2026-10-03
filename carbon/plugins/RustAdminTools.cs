using System;
using System.Collections.Generic;
using System.Linq;
using UnityEngine;
using UnityEngine.AI;

namespace Oxide.Plugins
{
    [Info("RustAdminTools", "Rust Server Control Center", "1.0.0")]
    [Description("Commandes administrateur simples pour les armes, les munitions infinies et une boucle de bots de test.")]
    public class RustAdminTools : RustPlugin
    {
        private const string UsePermission = "rustadmintools.use";
        private const string BotPrefab = "assets/rust.ai/agents/npcplayer/humannpc/scientist/scientistnpc_full_any.prefab";
        private const int MaximumBots = 16;

        private readonly HashSet<BasePlayer> _bots = new HashSet<BasePlayer>();
        private readonly HashSet<ulong> _infiniteAmmo = new HashSet<ulong>();
        private readonly string[] _botNames =
        {
            "[BOT] Alpha", "[BOT] Bravo", "[BOT] Charlie", "[BOT] Delta",
            "[BOT] Echo", "[BOT] Foxtrot", "[BOT] Ghost", "[BOT] Viper"
        };

        private int _loopSession;
        private int _targetBots;
        private int _botNameIndex;
        private ulong _loopOwnerId;
        private float _spawnRadius = 20f;
        private float _loopInterval = 2f;
        private Vector3 _spawnAnchor;

        private static readonly string[] ArsenalWeapons =
        {
            "rifle.ak", "lmg.m249", "smg.mp5", "shotgun.spas12", "pistol.python", "rifle.l96"
        };

        private void Init()
        {
            permission.RegisterPermission(UsePermission, this);
        }

        private void OnServerInitialized()
        {
            Puts("Commandes pretes : /armes, /arme, /munitions, /botloop, /botstop, /botstatus.");
        }

        private void Unload()
        {
            StopBotLoop(true);
            _infiniteAmmo.Clear();
        }

        private bool HasAccess(BasePlayer player)
        {
            if (player != null && (player.IsAdmin || permission.UserHasPermission(player.UserIDString, UsePermission))) return true;
            if (player != null) SendReply(player, "<color=#e76a4c>Commande reservee aux administrateurs.</color>");
            return false;
        }

        [ChatCommand("armes")]
        private void CommandWeapons(BasePlayer player, string command, string[] args)
        {
            if (!HasAccess(player)) return;
            GiveArsenal(player);
        }

        [ChatCommand("arsenal")]
        private void CommandArsenalAlias(BasePlayer player, string command, string[] args)
        {
            CommandWeapons(player, command, args);
        }

        [ChatCommand("arme")]
        private void CommandWeapon(BasePlayer player, string command, string[] args)
        {
            if (!HasAccess(player)) return;
            if (args == null || args.Length == 0)
            {
                SendReply(player, "Utilisation : <color=#ffd479>/arme rifle.ak</color> ou <color=#ffd479>/arme lmg.m249</color>.");
                return;
            }

            int amount = 1;
            if (args.Length > 1 && (!int.TryParse(args[1], out amount) || amount < 1 || amount > 1000))
            {
                SendReply(player, "Quantite attendue : 1 a 1000.");
                return;
            }
            GiveItem(player, args[0], amount, true);
        }

        [ChatCommand("munitions")]
        private void CommandInfiniteAmmo(BasePlayer player, string command, string[] args)
        {
            if (!HasAccess(player)) return;
            ToggleInfiniteAmmo(player);
        }

        [ChatCommand("ammo")]
        private void CommandInfiniteAmmoAlias(BasePlayer player, string command, string[] args)
        {
            CommandInfiniteAmmo(player, command, args);
        }

        [ChatCommand("botloop")]
        private void CommandBotLoop(BasePlayer player, string command, string[] args)
        {
            if (!HasAccess(player)) return;

            int count = ParseInt(args, 0, 4, 1, MaximumBots);
            float radius = ParseFloat(args, 1, 20f, 8f, 60f);
            float interval = ParseFloat(args, 2, 2f, 1f, 10f);
            StartBotLoop(player, count, radius, interval);
        }

        [ChatCommand("botstop")]
        private void CommandBotStop(BasePlayer player, string command, string[] args)
        {
            if (!HasAccess(player)) return;
            int removed = StopBotLoop(true);
            SendReply(player, $"Boucle arretee, {removed} bot(s) supprime(s).");
        }

        [ChatCommand("botstatus")]
        private void CommandBotStatus(BasePlayer player, string command, string[] args)
        {
            if (!HasAccess(player)) return;
            CleanupBots();
            SendReply(player, $"Bots actifs : {_bots.Count}/{_targetBots} | rayon {_spawnRadius:0} m | remplacement toutes les {_loopInterval:0.#} s.");
        }

        [ConsoleCommand("sandbox.arsenal")]
        private void ConsoleArsenal(ConsoleSystem.Arg arg)
        {
            if (!IsAdminCaller(arg)) return;
            BasePlayer target = FindPlayer(ConsoleArg(arg, 0));
            if (target == null) { arg.ReplyWith("Joueur connecte introuvable."); return; }
            GiveArsenal(target);
            arg.ReplyWith($"Arsenal donne a {target.displayName}.");
        }

        [ConsoleCommand("sandbox.botloop")]
        private void ConsoleBotLoop(ConsoleSystem.Arg arg)
        {
            if (!IsAdminCaller(arg)) return;
            string selector = ConsoleArg(arg, 0);
            BasePlayer target = FindPlayer(selector);
            if (target == null) { arg.ReplyWith("Joueur connecte introuvable. Utilisation : sandbox.botloop <joueur> [nombre] [rayon] [secondes]"); return; }

            string[] values = arg.Args == null ? new string[0] : arg.Args.Skip(1).Select(value => value.ToString()).ToArray();
            int count = ParseInt(values, 0, 4, 1, MaximumBots);
            float radius = ParseFloat(values, 1, 20f, 8f, 60f);
            float interval = ParseFloat(values, 2, 2f, 1f, 10f);
            StartBotLoop(target, count, radius, interval);
            arg.ReplyWith($"Boucle de {count} bots activee autour de {target.displayName}.");
        }

        [ConsoleCommand("sandbox.botstop")]
        private void ConsoleBotStop(ConsoleSystem.Arg arg)
        {
            if (!IsAdminCaller(arg)) return;
            arg.ReplyWith($"Boucle arretee, {StopBotLoop(true)} bot(s) supprime(s).");
        }

        [ConsoleCommand("sandbox.status")]
        private void ConsoleStatus(ConsoleSystem.Arg arg)
        {
            if (!IsAdminCaller(arg)) return;
            CleanupBots();
            arg.ReplyWith($"running={_targetBots > 0} bots={_bots.Count}/{_targetBots} owner={_loopOwnerId} radius={_spawnRadius:0.#} interval={_loopInterval:0.#}");
        }

        private bool IsAdminCaller(ConsoleSystem.Arg arg)
        {
            BasePlayer caller = arg.Player();
            if (caller == null || caller.IsAdmin || permission.UserHasPermission(caller.UserIDString, UsePermission)) return true;
            arg.ReplyWith("Commande reservee aux administrateurs.");
            return false;
        }

        private string ConsoleArg(ConsoleSystem.Arg arg, int index)
        {
            return arg.Args != null && index >= 0 && index < arg.Args.Length ? arg.Args[index].ToString() : string.Empty;
        }

        private BasePlayer FindPlayer(string selector)
        {
            return BasePlayer.activePlayerList.FirstOrDefault(player =>
                string.IsNullOrWhiteSpace(selector) ||
                player.UserIDString == selector ||
                player.displayName.IndexOf(selector, StringComparison.OrdinalIgnoreCase) >= 0);
        }

        private void GiveArsenal(BasePlayer player)
        {
            int weapons = 0;
            foreach (string shortname in ArsenalWeapons)
            {
                if (GiveItem(player, shortname, 1, false)) weapons++;
            }
            GiveItem(player, "ammo.rifle", 512, false);
            GiveItem(player, "ammo.pistol", 256, false);
            GiveItem(player, "ammo.shotgun", 128, false);
            _infiniteAmmo.Add(player.userID);
            timer.Once(0.15f, () => FillActiveMagazine(player));
            SendReply(player, $"<color=#9fd36f>Arsenal recu :</color> {weapons} armes, munitions et chargeur infini. Tape /munitions pour desactiver.");
        }

        private bool GiveItem(BasePlayer player, string shortname, int amount, bool announce)
        {
            Item item = ItemManager.CreateByName(shortname, amount);
            if (item == null)
            {
                SendReply(player, $"Objet inconnu : <color=#e76a4c>{shortname}</color>.");
                return false;
            }
            if (item.hasCondition) item.condition = item.maxCondition;
            if (!player.inventory.GiveItem(item))
            {
                item.Remove();
                SendReply(player, "Inventaire plein : libere une case puis recommence.");
                return false;
            }
            if (announce) SendReply(player, $"Objet recu : <color=#ffd479>{shortname}</color> x{amount}.");
            return true;
        }

        private void ToggleInfiniteAmmo(BasePlayer player)
        {
            if (_infiniteAmmo.Remove(player.userID))
            {
                SendReply(player, "Munitions infinies <color=#e76a4c>desactivees</color>.");
                return;
            }
            _infiniteAmmo.Add(player.userID);
            FillActiveMagazine(player);
            SendReply(player, "Munitions infinies <color=#9fd36f>activees</color>.");
        }

        private void OnWeaponFired(BaseProjectile projectile, BasePlayer player, ItemModProjectile mod, ProtoBuf.ProjectileShoot projectiles)
        {
            if (projectile == null || player == null || !_infiniteAmmo.Contains(player.userID)) return;
            timer.Once(0.01f, () =>
            {
                if (projectile == null || projectile.IsDestroyed || projectile.primaryMagazine == null) return;
                projectile.primaryMagazine.contents = projectile.primaryMagazine.capacity;
                projectile.SendNetworkUpdateImmediate();
            });
        }

        private void FillActiveMagazine(BasePlayer player)
        {
            if (player == null || !player.IsConnected) return;
            Item active = player.GetActiveItem();
            BaseProjectile projectile = active != null ? active.GetHeldEntity() as BaseProjectile : null;
            if (projectile == null || projectile.primaryMagazine == null) return;
            projectile.primaryMagazine.contents = projectile.primaryMagazine.capacity;
            projectile.SendNetworkUpdateImmediate();
            active.MarkDirty();
        }

        private void StartBotLoop(BasePlayer owner, int count, float radius, float interval)
        {
            StopBotLoop(true);
            _loopOwnerId = owner.userID;
            _spawnAnchor = owner.transform.position;
            _targetBots = Mathf.Clamp(count, 1, MaximumBots);
            _spawnRadius = Mathf.Clamp(radius, 8f, 60f);
            _loopInterval = Mathf.Clamp(interval, 1f, 10f);
            int session = ++_loopSession;
            MaintainBots();
            ScheduleBotLoop(session);
            ScheduleBotMovement(session);
            SendReply(owner, $"<color=#9fd36f>Boucle active :</color> {_targetBots} bots maintenus dans un rayon de {_spawnRadius:0} m. /botstop pour tout retirer.");
        }

        private void ScheduleBotLoop(int session)
        {
            timer.Once(_loopInterval, () =>
            {
                if (session != _loopSession || _targetBots <= 0) return;
                MaintainBots();
                ScheduleBotLoop(session);
            });
        }

        private void MaintainBots()
        {
            CleanupBots();
            int toCreate = Math.Min(4, _targetBots - _bots.Count);
            for (int index = 0; index < toCreate; index++)
            {
                if (!SpawnBot()) break;
            }
        }

        private void ScheduleBotMovement(int session)
        {
            timer.Once(0.1f, () =>
            {
                if (session != _loopSession || _targetBots <= 0) return;
                MoveBotsTowardsOwner();
                ScheduleBotMovement(session);
            });
        }

        private void MoveBotsTowardsOwner()
        {
            BasePlayer owner = BasePlayer.activePlayerList.FirstOrDefault(player => player.userID == _loopOwnerId);
            if (owner == null) return;
            foreach (BasePlayer bot in _bots.ToArray())
            {
                if (bot == null || bot.IsDestroyed) continue;
                Vector3 delta = owner.transform.position - bot.transform.position;
                delta.y = 0f;
                if (delta.sqrMagnitude <= 12.25f) continue;
                Vector3 next = Vector3.MoveTowards(bot.transform.position, bot.transform.position + delta, 0.25f);
                next.y = bot.transform.position.y;
                bot.transform.position = next;
                bot.transform.rotation = Quaternion.LookRotation(delta.normalized);
                bot.SendNetworkUpdateImmediate();
            }
        }

        private bool SpawnBot()
        {
            float angle = UnityEngine.Random.Range(0f, Mathf.PI * 2f);
            float distance = UnityEngine.Random.Range(Mathf.Max(6f, _spawnRadius * 0.55f), _spawnRadius);
            Vector3 candidate = _spawnAnchor + new Vector3(Mathf.Cos(angle) * distance, 0f, Mathf.Sin(angle) * distance);
            candidate.y = TerrainMeta.HeightMap.GetHeight(candidate) + 1f;
            NavMeshHit hit;
            if (NavMesh.SamplePosition(candidate, out hit, 18f, NavMesh.AllAreas)) candidate = hit.position + Vector3.up * 0.2f;

            BaseEntity entity = GameManager.server.CreateEntity(BotPrefab, candidate, Quaternion.identity, true);
            BasePlayer bot = entity as BasePlayer;
            if (bot == null)
            {
                if (entity != null) entity.Kill();
                PrintWarning("Impossible de creer un bot de test.");
                return false;
            }

            bot.enableSaving = false;
            bot.displayName = _botNames[_botNameIndex++ % _botNames.Length];
            bot.Spawn();
            bot.InitializeHealth(100f, 100f);
            NPCPlayer npc = bot as NPCPlayer;
            if (npc != null && npc.NavAgent != null && !npc.NavAgent.isOnNavMesh)
            {
                NavMeshHit agentHit;
                if (npc.NavAgent.SamplePosition(candidate, out agentHit, 40f, false) && npc.NavAgent.Warp(agentHit.position))
                {
                    candidate = agentHit.position;
                }
                else
                {
                    // Fallback pour les cartes sans NavMesh terrain : le tick
                    // manuel de ce plugin deplace quand meme le bot vers le joueur.
                    npc.NavAgent.enabled = false;
                }
            }
            _bots.Add(bot);
            return true;
        }

        private void OnEntityDeath(BaseCombatEntity entity, HitInfo info)
        {
            BasePlayer bot = entity as BasePlayer;
            if (bot != null) _bots.Remove(bot);
        }

        private void OnEntityKill(BaseNetworkable entity)
        {
            BasePlayer bot = entity as BasePlayer;
            if (bot != null) _bots.Remove(bot);
        }

        private void OnPlayerDisconnected(BasePlayer player, string reason)
        {
            if (player == null) return;
            _infiniteAmmo.Remove(player.userID);
            if (player.userID == _loopOwnerId) StopBotLoop(true);
        }

        private void CleanupBots()
        {
            _bots.RemoveWhere(bot => bot == null || bot.IsDestroyed);
        }

        private int StopBotLoop(bool removeBots)
        {
            _loopSession++;
            _targetBots = 0;
            _loopOwnerId = 0UL;
            CleanupBots();
            int count = _bots.Count;
            if (removeBots)
            {
                foreach (BasePlayer bot in _bots.ToArray())
                {
                    if (bot != null && !bot.IsDestroyed) bot.Kill();
                }
                _bots.Clear();
            }
            return count;
        }

        private int ParseInt(string[] args, int index, int fallback, int minimum, int maximum)
        {
            int value;
            if (args == null || index >= args.Length || !int.TryParse(args[index], out value)) return fallback;
            return Mathf.Clamp(value, minimum, maximum);
        }

        private float ParseFloat(string[] args, int index, float fallback, float minimum, float maximum)
        {
            float value;
            if (args == null || index >= args.Length || !float.TryParse(args[index], System.Globalization.NumberStyles.Float, System.Globalization.CultureInfo.InvariantCulture, out value)) return fallback;
            return Mathf.Clamp(value, minimum, maximum);
        }
    }
}
