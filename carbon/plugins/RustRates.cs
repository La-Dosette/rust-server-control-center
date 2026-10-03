using System;
using System.Collections.Generic;
using System.Globalization;
using System.Linq;
using System.Text;
using Oxide.Core;
using UnityEngine;

namespace Oxide.Plugins
{
    [Info("RustRates", "OpenAI", "1.0.0")]
    [Description("Multiplicateurs de recolte, ramassage, piles et fabrication, reglables ressource par ressource.")]
    public class RustRates : RustPlugin
    {
        private PluginConfig _config;

        // Tailles de pile d'origine, relevees au chargement et restaurees au
        // dechargement. Sans cette sauvegarde, desactiver le plugin laisserait
        // les piles gonflees jusqu'au prochain redemarrage du serveur.
        private readonly Dictionary<string, int> _originalStacks = new Dictionary<string, int>();
        private readonly Dictionary<string, float> _originalCraftTimes = new Dictionary<string, float>();

        // Vitesse de fonte d'origine, relevee par type de four. BaseOven.smeltSpeed
        // est un champ d'instance : chaque four pose sur la carte doit etre
        // traite, y compris ceux qui existaient avant le chargement du plugin.
        private readonly Dictionary<string, int> _originalSmeltSpeeds = new Dictionary<string, int>();

        private class PluginConfig
        {
            public float MultiplicateurGlobal = 1f;
            public bool AppliquerRecolte = true;
            public bool AppliquerRamassage = true;
            public bool AppliquerPiles = false;
            public bool AppliquerFabrication = false;
            public bool AppliquerFonte = false;
            public float MultiplicateurPiles = 1f;
            public float MultiplicateurFabrication = 1f;
            public float MultiplicateurFonte = 1f;
            public int PilePlafond = 10000;

            // Un multiplicateur par ressource. La valeur 0 signifie "suivre le
            // global" : un simple serveur x2 se regle donc d'un seul champ, sans
            // avoir a renseigner les quatorze lignes.
            public Dictionary<string, float> Ressources = new Dictionary<string, float>
            {
                ["wood"] = 0f,
                ["stones"] = 0f,
                ["metal.ore"] = 0f,
                ["sulfur.ore"] = 0f,
                ["hq.metal.ore"] = 0f,
                ["cloth"] = 0f,
                ["leather"] = 0f,
                ["fat.animal"] = 0f,
                ["bone.fragments"] = 0f,
                ["scrap"] = 0f,
                ["lowgradefuel"] = 0f,
                ["mushroom"] = 0f,
                ["corn"] = 0f,
                ["pumpkin"] = 0f
            };
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
                if (_config == null) throw new Exception("Configuration vide");
            }
            catch
            {
                PrintWarning("Configuration invalide, creation des valeurs par defaut.");
                LoadDefaultConfig();
            }
            if (_config.Ressources == null) _config.Ressources = new Dictionary<string, float>();
            SaveConfig();
        }

        protected override void SaveConfig()
        {
            Config.WriteObject(_config, true);
        }

        private void OnServerInitialized()
        {
            ApplyStackSizes();
            ApplyCraftTimes();
            ApplySmeltSpeeds();
            Puts(BuildSummary());
        }

        private void Unload()
        {
            RestoreStackSizes();
            RestoreCraftTimes();
            RestoreSmeltSpeeds();
        }

        // ----- Multiplicateurs --------------------------------------------------

        /// <summary>
        /// Multiplicateur applicable a un objet. Une entree a 0 dans la config
        /// veut dire "suivre le global", ce qui permet de regler un serveur x2
        /// d'un seul champ tout en gardant la possibilite d'affiner.
        /// </summary>
        private float RateFor(string shortname)
        {
            float specific;
            if (!string.IsNullOrEmpty(shortname) && _config.Ressources.TryGetValue(shortname, out specific) && specific > 0f)
            {
                return specific;
            }
            return Mathf.Max(0.01f, _config.MultiplicateurGlobal);
        }

        private void ScaleItem(Item item)
        {
            if (item == null || item.info == null) return;
            float rate = RateFor(item.info.shortname);
            if (Mathf.Approximately(rate, 1f)) return;
            item.amount = Mathf.Max(1, Mathf.RoundToInt(item.amount * rate));
        }

        // ----- Recolte et ramassage ----------------------------------------------

        private void OnDispenserGather(ResourceDispenser dispenser, BaseEntity entity, Item item)
        {
            if (!_config.AppliquerRecolte) return;
            if (!(entity is BasePlayer)) return;
            ScaleItem(item);
        }

        private void OnDispenserBonus(ResourceDispenser dispenser, BasePlayer player, Item item)
        {
            if (!_config.AppliquerRecolte || player == null) return;
            ScaleItem(item);
        }

        private void OnCollectiblePickup(Item item, BasePlayer player)
        {
            if (!_config.AppliquerRamassage || player == null) return;
            ScaleItem(item);
        }

        private void OnGrowableGathered(GrowableEntity plant, Item item, BasePlayer player)
        {
            if (!_config.AppliquerRecolte || player == null) return;
            ScaleItem(item);
        }

        // ----- Fabrication ----------------------------------------------------------

        /// <summary>
        /// Les durees de fabrication sont modifiees une seule fois, au chargement.
        ///
        /// Ne PAS le faire dans OnItemCraft : task.blueprint pointe sur le
        /// blueprint global partage, pas sur une copie. Le diviser a chaque
        /// fabrication cumulerait l'effet et ferait tomber toutes les durees au
        /// plancher apres quelques objets. Meme raisonnement que pour les piles,
        /// d'ou la meme sauvegarde/restauration.
        /// </summary>
        private void ApplyCraftTimes()
        {
            if (!_config.AppliquerFabrication) return;
            float rate = Mathf.Max(0.01f, _config.MultiplicateurFabrication);
            if (Mathf.Approximately(rate, 1f)) return;

            // Une commande d'administration ne doit jamais tuer la connexion RCON :
            // toute erreur d'API est journalisee et avalee ici.
            int changed = 0;
            try
            {
                List<ItemBlueprint> blueprints = ItemManager.bpList;
                if (blueprints == null)
                {
                    PrintWarning("Liste des recettes indisponible : multiplicateur de fabrication ignore.");
                    return;
                }
                foreach (ItemBlueprint blueprint in blueprints)
                {
                    if (blueprint == null || blueprint.targetItem == null || blueprint.time <= 0f) continue;
                    string key = blueprint.targetItem.shortname;
                    if (!_originalCraftTimes.ContainsKey(key))
                    {
                        _originalCraftTimes[key] = blueprint.time;
                    }
                    // x2 signifie deux fois plus vite, donc une duree divisee par deux.
                    blueprint.time = Mathf.Max(0.1f, _originalCraftTimes[key] / rate);
                    changed++;
                }
            }
            catch (Exception exception)
            {
                PrintWarning("Multiplicateur de fabrication inapplicable sur cette version de Rust : " + exception.Message);
                return;
            }
            Puts($"Duree de fabrication divisee par {rate:0.##} sur {changed} recette(s).");
        }

        private void RestoreCraftTimes()
        {
            if (_originalCraftTimes.Count == 0) return;
            try
            {
                List<ItemBlueprint> blueprints = ItemManager.bpList;
                if (blueprints != null)
                {
                    foreach (ItemBlueprint blueprint in blueprints)
                    {
                        if (blueprint == null || blueprint.targetItem == null) continue;
                        float original;
                        if (_originalCraftTimes.TryGetValue(blueprint.targetItem.shortname, out original))
                        {
                            blueprint.time = original;
                        }
                    }
                }
                Puts($"Duree de fabrication restauree sur {_originalCraftTimes.Count} recette(s).");
            }
            catch (Exception exception)
            {
                PrintWarning("Restauration des durees de fabrication impossible : " + exception.Message);
            }
            _originalCraftTimes.Clear();
        }

        // ----- Fonte -------------------------------------------------------------------

        /// <summary>
        /// Vitesse de fonte des fours, via le champ BaseOven.smeltSpeed.
        ///
        /// C'est un champ d'INSTANCE, pas une valeur de prefab partagee : il faut
        /// traiter chaque four deja pose sur la carte, puis chaque nouveau four
        /// via OnEntitySpawned. La valeur d'origine est relevee par type de four,
        /// car elle differe entre un feu de camp, un four et un grand four.
        /// </summary>
        private void ApplyOvenSpeed(BaseOven oven)
        {
            if (oven == null) return;
            string key = oven.ShortPrefabName;
            if (string.IsNullOrEmpty(key)) return;

            if (!_originalSmeltSpeeds.ContainsKey(key))
            {
                _originalSmeltSpeeds[key] = oven.smeltSpeed;
            }
            float rate = _config.AppliquerFonte ? Mathf.Max(0.01f, _config.MultiplicateurFonte) : 1f;
            // smeltSpeed est un entier : la vitesse de fonte avance donc par
            // paliers. Avec une valeur d'origine de 1, un x1.5 donne 2, soit un
            // x2 reel. Les multiplicateurs entiers sont les seuls exacts.
            oven.smeltSpeed = Mathf.Max(1, Mathf.RoundToInt(_originalSmeltSpeeds[key] * rate));
        }

        private void ApplySmeltSpeeds()
        {
            if (!_config.AppliquerFonte) return;
            float rate = Mathf.Max(0.01f, _config.MultiplicateurFonte);
            if (Mathf.Approximately(rate, 1f)) return;

            int changed = 0;
            try
            {
                foreach (BaseNetworkable entity in BaseNetworkable.serverEntities)
                {
                    BaseOven oven = entity as BaseOven;
                    if (oven == null) continue;
                    ApplyOvenSpeed(oven);
                    changed++;
                }
            }
            catch (Exception exception)
            {
                PrintWarning("Multiplicateur de fonte inapplicable : " + exception.Message);
                return;
            }
            Puts($"Vitesse de fonte multipliee par {rate:0.##} sur {changed} four(s) en place, {_originalSmeltSpeeds.Count} type(s) connu(s).");
        }

        private void RestoreSmeltSpeeds()
        {
            if (_originalSmeltSpeeds.Count == 0) return;
            int restored = 0;
            try
            {
                foreach (BaseNetworkable entity in BaseNetworkable.serverEntities)
                {
                    BaseOven oven = entity as BaseOven;
                    if (oven == null) continue;
                    int original;
                    if (_originalSmeltSpeeds.TryGetValue(oven.ShortPrefabName, out original))
                    {
                        oven.smeltSpeed = original;
                        restored++;
                    }
                }
            }
            catch (Exception exception)
            {
                PrintWarning("Restauration de la vitesse de fonte impossible : " + exception.Message);
            }
            Puts($"Vitesse de fonte restauree sur {restored} four(s).");
            _originalSmeltSpeeds.Clear();
        }

        private void OnEntitySpawned(BaseNetworkable entity)
        {
            if (!_config.AppliquerFonte) return;
            BaseOven oven = entity as BaseOven;
            if (oven != null) ApplyOvenSpeed(oven);
        }

        // ----- Piles -------------------------------------------------------------------

        private void ApplyStackSizes()
        {
            if (!_config.AppliquerPiles) return;
            float rate = Mathf.Max(0.01f, _config.MultiplicateurPiles);
            if (Mathf.Approximately(rate, 1f)) return;

            int changed = 0;
            foreach (ItemDefinition definition in ItemManager.GetItemDefinitions())
            {
                if (definition == null || definition.stackable <= 1) continue;
                if (!_originalStacks.ContainsKey(definition.shortname))
                {
                    _originalStacks[definition.shortname] = definition.stackable;
                }
                int target = Mathf.Clamp(
                    Mathf.RoundToInt(_originalStacks[definition.shortname] * rate),
                    1,
                    Mathf.Max(1, _config.PilePlafond));
                definition.stackable = target;
                changed++;
            }
            Puts($"Taille des piles multipliee par {rate:0.##} sur {changed} objet(s), plafond {_config.PilePlafond}.");
        }

        private void RestoreStackSizes()
        {
            if (_originalStacks.Count == 0) return;
            foreach (KeyValuePair<string, int> entry in _originalStacks)
            {
                ItemDefinition definition = ItemManager.FindItemDefinition(entry.Key);
                if (definition != null) definition.stackable = entry.Value;
            }
            Puts($"Taille des piles restauree sur {_originalStacks.Count} objet(s).");
            _originalStacks.Clear();
        }

        // ----- Etat et commandes ----------------------------------------------------------

        private string BuildSummary()
        {
            List<string> parts = new List<string>();
            if (_config.AppliquerRecolte) parts.Add("recolte");
            if (_config.AppliquerRamassage) parts.Add("ramassage");
            if (_config.AppliquerPiles) parts.Add($"piles x{_config.MultiplicateurPiles:0.##}");
            if (_config.AppliquerFabrication) parts.Add($"fabrication x{_config.MultiplicateurFabrication:0.##}");
            if (_config.AppliquerFonte) parts.Add($"fonte x{_config.MultiplicateurFonte:0.##}");
            int custom = _config.Ressources.Count(pair => pair.Value > 0f);
            string scope = parts.Count > 0 ? string.Join(", ", parts.ToArray()) : "aucun domaine actif";
            return $"Taux pret : global x{_config.MultiplicateurGlobal:0.##} - {scope} - {custom} ressource(s) reglee(s) individuellement.";
        }

        private object GetRatesDashboardStatus()
        {
            int custom = _config.Ressources.Count(pair => pair.Value > 0f);
            return $"actif=True global={_config.MultiplicateurGlobal:0.##} recolte={_config.AppliquerRecolte} ramassage={_config.AppliquerRamassage} piles={_config.AppliquerPiles} fabrication={_config.AppliquerFabrication} personnalisees={custom}";
        }

        [ConsoleCommand("rates")]
        private void ConsoleRates(ConsoleSystem.Arg arg)
        {
            if (!IsAdminCaller(arg)) return;
            StringBuilder text = new StringBuilder();
            text.AppendLine(BuildSummary());
            text.AppendLine();
            text.AppendLine("[RESSOURCES]");
            foreach (KeyValuePair<string, float> pair in _config.Ressources.OrderBy(entry => entry.Key))
            {
                string value = pair.Value > 0f
                    ? "x" + pair.Value.ToString("0.##")
                    : "global (x" + _config.MultiplicateurGlobal.ToString("0.##") + ")";
                text.AppendLine(pair.Key.PadRight(18) + " " + value);
            }
            arg.ReplyWith(text.ToString());
        }

        [ConsoleCommand("rates.json")]
        private void ConsoleRatesJson(ConsoleSystem.Arg arg)
        {
            if (!IsAdminCaller(arg)) return;
            StringBuilder json = new StringBuilder();
            json.Append("{\"global\":").Append(Num(_config.MultiplicateurGlobal))
                .Append(",\"recolte\":").Append(Flag(_config.AppliquerRecolte))
                .Append(",\"ramassage\":").Append(Flag(_config.AppliquerRamassage))
                .Append(",\"piles\":").Append(Flag(_config.AppliquerPiles))
                .Append(",\"pilesX\":").Append(Num(_config.MultiplicateurPiles))
                .Append(",\"fabrication\":").Append(Flag(_config.AppliquerFabrication))
                .Append(",\"fabricationX\":").Append(Num(_config.MultiplicateurFabrication))
                .Append(",\"fonte\":").Append(Flag(_config.AppliquerFonte))
                .Append(",\"fonteX\":").Append(Num(_config.MultiplicateurFonte))
                .Append(",\"plafondPile\":").Append(_config.PilePlafond)
                .Append(",\"ressources\":{");
            bool first = true;
            foreach (KeyValuePair<string, float> pair in _config.Ressources.OrderBy(entry => entry.Key))
            {
                if (!first) json.Append(',');
                first = false;
                json.Append('"').Append(pair.Key).Append("\":").Append(Num(pair.Value));
            }
            json.Append("}}");
            arg.ReplyWith(json.ToString());
        }

        private string Num(float value)
        {
            return value.ToString(CultureInfo.InvariantCulture);
        }

        private string Flag(bool value)
        {
            return value ? "true" : "false";
        }

        /// <summary>
        /// Applique un reglage a chaud. Les piles sont reappliquees dans la
        /// foulee : elles ne dependent pas d'un evenement de jeu mais de l'etat
        /// courant des definitions d'objets.
        /// </summary>
        [ConsoleCommand("rates.set")]
        private void ConsoleRatesSet(ConsoleSystem.Arg arg)
        {
            if (!IsAdminCaller(arg)) return;
            string[] args = arg.Args != null ? arg.Args.Select(value => value.ToString()).ToArray() : new string[0];
            if (args.Length < 2)
            {
                arg.ReplyWith("Usage : rates.set <global|piles|fabrication|fonte|plafond|recolte|ramassage|activerpiles|activerfabrication|activerfonte|shortname> <valeur>");
                return;
            }

            string key = args[0].ToLowerInvariant();
            string raw = args[1];
            float value;
            bool numeric = float.TryParse(raw, NumberStyles.Float, CultureInfo.InvariantCulture, out value);
            bool flag = raw.Equals("true", StringComparison.OrdinalIgnoreCase) || raw == "1";

            switch (key)
            {
                case "global":
                    if (!numeric || value <= 0f) { arg.ReplyWith("Valeur invalide."); return; }
                    _config.MultiplicateurGlobal = value;
                    break;
                case "piles":
                    if (!numeric || value <= 0f) { arg.ReplyWith("Valeur invalide."); return; }
                    RestoreStackSizes();
                    _config.MultiplicateurPiles = value;
                    ApplyStackSizes();
                    break;
                case "fabrication":
                    if (!numeric || value <= 0f) { arg.ReplyWith("Valeur invalide."); return; }
                    RestoreCraftTimes();
                    _config.MultiplicateurFabrication = value;
                    ApplyCraftTimes();
                    break;
                case "plafond":
                    if (!numeric || value < 1f) { arg.ReplyWith("Valeur invalide."); return; }
                    RestoreStackSizes();
                    _config.PilePlafond = Mathf.RoundToInt(value);
                    ApplyStackSizes();
                    break;
                case "recolte":
                    _config.AppliquerRecolte = flag;
                    break;
                case "ramassage":
                    _config.AppliquerRamassage = flag;
                    break;
                case "activerpiles":
                    RestoreStackSizes();
                    _config.AppliquerPiles = flag;
                    ApplyStackSizes();
                    break;
                case "activerfabrication":
                    RestoreCraftTimes();
                    _config.AppliquerFabrication = flag;
                    ApplyCraftTimes();
                    break;
                case "fonte":
                    if (!numeric || value <= 0f) { arg.ReplyWith("Valeur invalide."); return; }
                    RestoreSmeltSpeeds();
                    _config.MultiplicateurFonte = value;
                    ApplySmeltSpeeds();
                    break;
                case "activerfonte":
                    RestoreSmeltSpeeds();
                    _config.AppliquerFonte = flag;
                    ApplySmeltSpeeds();
                    break;
                default:
                    if (!numeric || value < 0f) { arg.ReplyWith("Valeur invalide."); return; }
                    if (ItemManager.FindItemDefinition(key) == null)
                    {
                        arg.ReplyWith("Objet inconnu : " + key);
                        return;
                    }
                    _config.Ressources[key] = value;
                    break;
            }

            SaveConfig();
            arg.ReplyWith(BuildSummary());
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
    }
}
