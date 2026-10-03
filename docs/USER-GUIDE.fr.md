# Guide utilisateur — Rust Server Control Center

## Premier serveur

1. Lance `RustServerControlCenter-Setup-v12.1.0.exe`.
2. Choisis Vanilla, Carbon ou Oxide dans l’assistant.
3. Crée le serveur, puis utilise **Démarrer**. La console Rust reste masquée.
4. Dans Rust, ouvre F1 et colle la commande `client.connect` affichée.

## Tester la connexion d’un ami

Ouvre **Jouer avec des amis** et clique **Lancer un test ami**. L’outil démarre l’instance publique, attend la carte, contrôle les ports et le pare-feu, demande à Steam si le serveur est visible, actualise `CONNEXION-AMIS.txt`, puis attend l’arrivée d’un joueur. Une seule commande est affichée. En cas d’échec, **Ouvrir le rapport** donne le contrôle bloquant et l’action recommandée.

![Test ami guidé](images/friend-test.png)

## Adresse IP changeante

Dans **Réseau**, le suivi indique l’IP locale, l’IP publique et si une réservation DHCP semble présente. Une modification est signalée et le fichier de connexion est régénéré.

- DuckDNS : saisis le domaine et le jeton.
- No-IP : saisis le nom d’hôte, l’utilisateur de clé DDNS et le mot de passe de clé.
- Le secret est protégé avec DPAPI et reste lisible uniquement par ton compte Windows.

## Sans ouverture de ports

- **Tailscale intégré** : dans **Réseau & ports**, utilise **Installer Tailscale**, puis **Se connecter**. Après l’authentification dans le navigateur, **Utiliser pour Rust** active le profil et copie la commande correcte. **Inviter un ami** ouvre la page officielle des invitations et **Copier le guide ami** prépare les instructions à envoyer. Tous les joueurs doivent installer Tailscale et rejoindre le même réseau privé. Le Control Center vérifie la signature de l’installateur et ne conserve aucun identifiant Tailscale. Une liaison directe offre le meilleur ping ; un relais DERP peut être plus lent.
- **Tunnel UDP public** : saisis l’hôte et le port fournis par le relais. Le trafic doit être relayé vers le port jeu UDP local ; un second tunnel vers le query port est recommandé pour Steam.
- **Direct** : meilleur ping, mais nécessite la redirection des ports UDP dans le routeur.

![Profils réseau et DDNS](images/network-access.png)

N’envoie jamais le mot de passe RCON, le jeton DDNS ou le dossier `data`. Le rapport de test ami ne contient pas ces secrets.
