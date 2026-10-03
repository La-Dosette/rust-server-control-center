using System;
using System.Collections.Generic;
using System.Linq;
using System.Text;
using System.Text.RegularExpressions;
using Oxide.Core;
using UnityEngine;

namespace Oxide.Plugins
{
    [Info("RustStats", "OpenAI", "1.0.0")]
    [Description("Collecte des parties par mode et des sessions joueurs pour le tableau de bord d'administration.")]
    public class RustStats : RustPlugin
    {
        private const float TickSeconds = 5f;

        private StoredData _data;
        private readonly Dictionary<string, ModeRuntime> _runtime = new Dictionary<string, ModeRuntime>();
        private readonly Dictionary<ulong, float> _sessionStarts = new Dictionary<ulong, float>();

        /// <summary>
        /// Modes suivis et hook de statut correspondant. Les classements et les
        /// records ne sont pas dupliques ici : chaque plugin les ecrit deja dans
        /// son propre fichier de donnees, que l'outil lit directement.
        /// </summary>
        private static readonly string[][] TrackedModes =
        {
            new[] { "zombie", "Zombie", "GetZombieDashboardStatus" },
            new[] { "duel", "Duel", "GetDuelDashboardStatus" },
            new[] { "gungame", "Gun Game", "GetGunGameDashboardStatus" },
            new[] { "towerdefense", "Tower Defense", "GetTowerDefenseDashboardStatus" },
            new[] { "training", "Entrainement", "GetTrainingDashboardStatus" },
            new[] { "battlefield", "Battlefield", "GetBattlefieldDashboardStatus" }
        };

        private class ModeRuntime
        {
            public bool Running;
            public float StartedAt;
        }

        private class ModeStats
        {
            public int Parties;
            public int SecondesTotal;
            public int PlusLonguePartie;
            public string DernierePartie = string.Empty;
        }

        private class PlayerRecord
        {
            public string Nom = string.Empty;
            public int Sessions;
            public int SecondesJeu;
            public string PremiereConnexion = string.Empty;
            public string DerniereConnexion = string.Empty;
            public Dictionary<string, int> Victoires = new Dictionary<string, int>();
            public string Notes = string.Empty;
        }

        private class StoredData
        {
            public string CollecteDepuis = string.Empty;
            public Dictionary<string, ModeStats> Modes = new Dictionary<string, ModeStats>();
            public Dictionary<ulong, PlayerRecord> Joueurs = new Dictionary<ulong, PlayerRecord>();
        }

        // ----- Cycle de vie ------------------------------------------------------

        private void Init()
        {
            LoadData();
        }

        private void OnServerInitialized()
        {
            foreach (string[] mode in TrackedModes) _runtime[mode[0]] = new ModeRuntime();

            // Les joueurs deja connectes au chargement du plugin comptent a partir
            // de maintenant : sans cela, un rechargement a chaud leur ferait perdre
            // leur session en cours.
            foreach (BasePlayer player in BasePlayer.activePlayerList)
            {
                _sessionStarts[player.userID] = UnityEngine.Time.realtimeSinceStartup;
                EnsurePlayer(player);
            }

            timer.Every(TickSeconds, TickStats);
            Puts($"Statistiques pretes : {TrackedModes.Length} modes suivis, {_data.Joueurs.Count} joueur(s) connus.");
        }

        private void Unload()
        {
            // Cloture des sessions en cours pour ne pas perdre le temps de jeu.
            foreach (BasePlayer player in BasePlayer.activePlayerList) CloseSession(player);
            SaveData();
        }

        private void OnServerSave()
        {
            SaveData();
        }

        // ----- Sessions joueurs ---------------------------------------------------

        private void OnPlayerConnected(BasePlayer player)
        {
            if (player == null) return;
            _sessionStarts[player.userID] = UnityEngine.Time.realtimeSinceStartup;
            PlayerRecord record = EnsurePlayer(player);
            record.Sessions++;
            record.DerniereConnexion = Now();
            if (string.IsNullOrEmpty(record.PremiereConnexion)) record.PremiereConnexion = Now();
            SaveData();
        }

        private void OnPlayerDisconnected(BasePlayer player, string reason)
        {
            CloseSession(player);
            SaveData();
        }

        private void CloseSession(BasePlayer player)
        {
            if (player == null) return;
            float startedAt;
            if (!_sessionStarts.TryGetValue(player.userID, out startedAt)) return;
            _sessionStarts.Remove(player.userID);

            int seconds = Mathf.Max(0, Mathf.RoundToInt(UnityEngine.Time.realtimeSinceStartup - startedAt));
            PlayerRecord record = EnsurePlayer(player);
            record.SecondesJeu += seconds;
            record.DerniereConnexion = Now();
        }

        private PlayerRecord EnsurePlayer(BasePlayer player)
        {
            PlayerRecord record;
            if (!_data.Joueurs.TryGetValue(player.userID, out record))
            {
                record = new PlayerRecord { PremiereConnexion = Now() };
                _data.Joueurs[player.userID] = record;
            }
            if (record.Victoires == null) record.Victoires = new Dictionary<string, int>();
            if (!string.IsNullOrEmpty(player.displayName)) record.Nom = player.displayName;
            return record;
        }

        // ----- Detection des parties ------------------------------------------------

        /// <summary>
        /// On observe les statuts publies par chaque mode et on compte une partie
        /// a chaque transition actif -> inactif. Cette approche ne demande aucune
        /// modification des cinq autres plugins, contrairement a l'ajout de hooks
        /// de debut et de fin de partie partout.
        /// </summary>
        private void TickStats()
        {
            float now = UnityEngine.Time.realtimeSinceStartup;
            bool changed = false;

            foreach (string[] mode in TrackedModes)
            {
                ModeRuntime state;
                if (!_runtime.TryGetValue(mode[0], out state)) continue;

                object raw = Interface.CallHook(mode[2]);
                bool running = raw != null && StatusIsRunning(raw.ToString());

                if (running && !state.Running)
                {
                    state.Running = true;
                    state.StartedAt = now;
                }
                else if (!running && state.Running)
                {
                    state.Running = false;
                    int seconds = Mathf.Max(0, Mathf.RoundToInt(now - state.StartedAt));
                    RecordFinishedGame(mode[0], seconds);
                    changed = true;
                }
            }

            if (changed) SaveData();
        }

        private void RecordFinishedGame(string modeKey, int seconds)
        {
            ModeStats stats;
            if (!_data.Modes.TryGetValue(modeKey, out stats))
            {
                stats = new ModeStats();
                _data.Modes[modeKey] = stats;
            }
            stats.Parties++;
            stats.SecondesTotal += seconds;
            if (seconds > stats.PlusLonguePartie) stats.PlusLonguePartie = seconds;
            stats.DernierePartie = Now();
            Puts($"Partie terminee : {modeKey}, {seconds}s, total {stats.Parties}.");
        }

        private bool StatusIsRunning(string status)
        {
            if (string.IsNullOrEmpty(status)) return false;
            return Regex.IsMatch(status, @"\b(actif|active|match|arene)=True\b", RegexOptions.IgnoreCase);
        }

        // ----- Victoires individuelles -------------------------------------------------

        private void OnGunGameCompleted(BasePlayer player) { CreditWin(player, "gungame"); }
        private void OnDuelCompleted(BasePlayer player, int teamSize) { CreditWin(player, "duel"); }
        private void OnDuelTournamentWon(BasePlayer player) { CreditWin(player, "tournoi"); }
        private void OnCompetitiveModeCompleted(BasePlayer player, string mode) { CreditWin(player, "competitif"); }
        private void OnTowerDefenseCompleted(BasePlayer player, int wave, int coreHealth) { CreditWin(player, "towerdefense"); }

        private void CreditWin(BasePlayer player, string mode)
        {
            if (player == null) return;
            PlayerRecord record = EnsurePlayer(player);
            int current;
            record.Victoires[mode] = record.Victoires.TryGetValue(mode, out current) ? current + 1 : 1;
            SaveData();
        }

        // ----- Commandes ------------------------------------------------------------------

        [ConsoleCommand("stats.dump")]
        private void ConsoleStatsDump(ConsoleSystem.Arg arg)
        {
            BasePlayer caller = arg.Player();
            if (caller != null && !caller.IsAdmin) { arg.ReplyWith("Commande reservee aux administrateurs."); return; }

            string[] args = arg.Args != null ? arg.Args.Select(value => value.ToString()).ToArray() : new string[0];
            bool asJson = args.Length > 0 && args[0].Equals("json", StringComparison.OrdinalIgnoreCase);
            arg.ReplyWith(asJson ? BuildJson() : BuildText());
        }

        [ConsoleCommand("stats.note")]
        private void ConsoleStatsNote(ConsoleSystem.Arg arg)
        {
            BasePlayer caller = arg.Player();
            if (caller != null && !caller.IsAdmin) { arg.ReplyWith("Commande reservee aux administrateurs."); return; }

            string[] args = arg.Args != null ? arg.Args.Select(value => value.ToString()).ToArray() : new string[0];
            if (args.Length < 1) { arg.ReplyWith("Usage : stats.note <steamid> [texte]"); return; }

            ulong userId;
            if (!ulong.TryParse(args[0], out userId)) { arg.ReplyWith("SteamID invalide."); return; }

            PlayerRecord record;
            if (!_data.Joueurs.TryGetValue(userId, out record))
            {
                record = new PlayerRecord { PremiereConnexion = Now() };
                _data.Joueurs[userId] = record;
            }
            record.Notes = args.Length > 1 ? string.Join(" ", args.Skip(1).ToArray()) : string.Empty;
            SaveData();
            arg.ReplyWith(string.IsNullOrEmpty(record.Notes) ? "Note effacee." : $"Note enregistree pour {userId}.");
        }

        private string BuildText()
        {
            StringBuilder text = new StringBuilder();
            text.AppendLine($"[COLLECTE] depuis {_data.CollecteDepuis}");
            text.AppendLine();
            text.AppendLine("[PARTIES PAR MODE]");
            foreach (string[] mode in TrackedModes)
            {
                ModeStats stats;
                if (!_data.Modes.TryGetValue(mode[0], out stats)) { text.AppendLine($"{mode[1]} : aucune partie"); continue; }
                int average = stats.Parties > 0 ? stats.SecondesTotal / stats.Parties : 0;
                text.AppendLine($"{mode[1]} : {stats.Parties} partie(s), duree moyenne {average}s, plus longue {stats.PlusLonguePartie}s, derniere {stats.DernierePartie}");
            }
            text.AppendLine();
            text.AppendLine($"[JOUEURS] {_data.Joueurs.Count} connu(s)");
            foreach (KeyValuePair<ulong, PlayerRecord> pair in _data.Joueurs.OrderByDescending(entry => entry.Value.SecondesJeu).Take(20))
            {
                text.AppendLine($"{pair.Value.Nom} ({pair.Key}) : {pair.Value.Sessions} session(s), {pair.Value.SecondesJeu / 60} min, derniere {pair.Value.DerniereConnexion}");
            }
            return text.ToString();
        }

        private string BuildJson()
        {
            StringBuilder json = new StringBuilder();
            json.Append("{\"depuis\":\"").Append(Escape(_data.CollecteDepuis)).Append("\",\"modes\":[");

            bool first = true;
            foreach (string[] mode in TrackedModes)
            {
                ModeStats stats;
                if (!_data.Modes.TryGetValue(mode[0], out stats)) stats = new ModeStats();
                if (!first) json.Append(',');
                first = false;
                int average = stats.Parties > 0 ? stats.SecondesTotal / stats.Parties : 0;
                json.Append("{\"cle\":\"").Append(Escape(mode[0]))
                    .Append("\",\"nom\":\"").Append(Escape(mode[1]))
                    .Append("\",\"parties\":").Append(stats.Parties)
                    .Append(",\"secondesTotal\":").Append(stats.SecondesTotal)
                    .Append(",\"dureeMoyenne\":").Append(average)
                    .Append(",\"plusLongue\":").Append(stats.PlusLonguePartie)
                    .Append(",\"derniere\":\"").Append(Escape(stats.DernierePartie)).Append("\"}");
            }

            json.Append("],\"joueurs\":[");
            first = true;
            foreach (KeyValuePair<ulong, PlayerRecord> pair in _data.Joueurs)
            {
                if (!first) json.Append(',');
                first = false;
                PlayerRecord record = pair.Value;
                json.Append("{\"steamId\":\"").Append(pair.Key)
                    .Append("\",\"nom\":\"").Append(Escape(record.Nom))
                    .Append("\",\"sessions\":").Append(record.Sessions)
                    .Append(",\"secondesJeu\":").Append(record.SecondesJeu)
                    .Append(",\"premiere\":\"").Append(Escape(record.PremiereConnexion))
                    .Append("\",\"derniere\":\"").Append(Escape(record.DerniereConnexion))
                    .Append("\",\"notes\":\"").Append(Escape(record.Notes))
                    .Append("\",\"victoires\":{");
                bool firstWin = true;
                foreach (KeyValuePair<string, int> win in record.Victoires)
                {
                    if (!firstWin) json.Append(',');
                    firstWin = false;
                    json.Append('"').Append(Escape(win.Key)).Append("\":").Append(win.Value);
                }
                json.Append("}}");
            }
            json.Append("]}");
            return json.ToString();
        }

        private string Escape(string value)
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

        private string Now()
        {
            return DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss");
        }

        // ----- Persistance -------------------------------------------------------------------

        private void LoadData()
        {
            try { _data = Interface.Oxide.DataFileSystem.ReadObject<StoredData>(Name); }
            catch { _data = null; }

            if (_data == null) _data = new StoredData();
            if (_data.Modes == null) _data.Modes = new Dictionary<string, ModeStats>();
            if (_data.Joueurs == null) _data.Joueurs = new Dictionary<ulong, PlayerRecord>();
            if (string.IsNullOrEmpty(_data.CollecteDepuis)) _data.CollecteDepuis = Now();
        }

        private void SaveData()
        {
            Interface.Oxide.DataFileSystem.WriteObject(Name, _data);
        }
    }
}
