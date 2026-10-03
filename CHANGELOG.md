# Changelog

## 12.1.0 - 2026-09-07

- Transforme le profil Tailscale en assistant intégré dans la page Réseau & ports.
- Télécharge l’installateur officiel et refuse de l’exécuter si sa signature Authenticode n’est pas valide ou n’appartient pas à Tailscale.
- Pilote la connexion Tailscale sans console et sans enregistrer de mot de passe, clé API ou jeton d’authentification.
- Affiche l’adresse privée, le nom de l’appareil, le tailnet ainsi que les pairs disponibles et en ligne.
- Ajoute l’activation en un clic pour Rust, l’accès aux invitations et un guide ami prêt à copier.
- Ajoute des tests automatisés pour les états connecté, authentification requise et réponse Tailscale invalide.

## 12.0.0 - 2026-08-26

- Ajout du test ami guidé avec démarrage silencieux, attente du serveur, contrôle Steam/pare-feu, détection du joueur et rapport persistant.
- Suivi des IP locale/publique, alerte de changement, détection indicative de réservation DHCP et régénération de `CONNEXION-AMIS.txt`.
- Profils Direct, Tailscale et tunnel UDP public ; intégration DuckDNS et No-IP avec secret DPAPI.
- Canaux de mise à jour stable/bêta, comparaison SemVer et retour arrière vérifié.
- Installateur Windows, désinstallation enregistrée, signature optionnelle GitHub Actions et documentation français/anglais.

## 11.1.0 - 2026-08-26

- Le diagnostic pare-feu reconnait maintenant les autorisations Windows attachees directement a `RustDedicated.exe`, y compris les regles UDP couvrant tous les ports du programme.
- Un controle exterieur interroge l'API officielle Steam `GetServersAtAddress` lorsque le serveur tourne et distingue serveur visible, serveur absent et service Steam indisponible.
- Les controles de fiabilite couvrent la selection exacte du binaire autorise et le filtrage IP/query port/AppID de la reponse Steam.

## 11.0.1 - 2026-08-25

- Ajoute un test automatisé de première installation dans un dossier Windows isolé.
- Vérifie le matériel, Vanilla, les diagnostics, la réparation sûre, la création du serveur, les ports et la commande de connexion.
- Ajoute un bouton de réparation contextuel directement dans l’assistant de premier lancement.
- Produit un rapport JSON et deux captures WPF utilisables comme preuves de recette.
- Exécute ce scénario sur un runner Windows GitHub vierge à chaque validation.
- Permet, lors d’un lancement manuel du workflow, de télécharger réellement Rust Dedicated et de démarrer le premier serveur.

## 11.0.0 - 2026-08-25

- Nouvel assistant de premier lancement avec détection CPU, mémoire, disque et capacité estimée.
- Choix explicite entre serveur Vanilla, Carbon et Oxide/uMod avant l’installation silencieuse de Rust Dedicated.
- Création guidée du premier serveur et diagnostic local, LAN, ports et connexion depuis le même parcours.
- Recherche automatique des nouvelles versions, notification Windows, contrôle SHA-256 et vérification Authenticode lorsqu’une release est signée.
- Sauvegarde de chaque mise à jour avec historique et restauration de la version précédente depuis l’interface.
- Bibliothèque RustEdit avec import `.map`, empreinte SHA-256, URL publique et application sécurisée par instance.
- Profils Gun Game, Zombie, Tower Defense et Duel affichés uniquement lorsque leurs plugins sont réellement actifs.
- Génération et nettoyage d’arènes, emplacements aléatoires sûrs et points d’apparition pilotés par les plugins.

## 10.0.0 - 2026-08-24

- Ajout d'un exécutable Windows unique qui embarque, vérifie, installe et lance le Control Center sans console.
- Ajout du SDK universel de plugins v1 avec schéma JSON public et validation stricte.
- Ajout de huit manifestes embarqués, 20 réglages typés et 33 actions RCON.
- Nouvel inspecteur dynamique dans Extensions : réglages, actions, état et accès au JSON complet.
- Installation et archivage atomiques des manifestes avec empreintes SHA-256.
- Sauvegarde automatique des configurations avant chaque écriture depuis le SDK.

## 9.0.0 - 2026-08-23

- Ajoute la page Sante du PC, l'estimation de capacite et les reparations guidees.
- Ajoute un catalogue verifie de huit plugins embarques, avec dependances et SHA-256.
- Rend les modes de jeu visibles uniquement lorsque leur plugin actif est detecte.
- Ajoute les controles d'isolation, de ports et de memoire avant le multi-instance.
- Ajoute la detection LAN/VPN, le diagnostic distant et le tableau de bord web securise.
- Etend l'historique persistant, les operations annulables et les notifications.
- Ajoute la signature Authenticode optionnelle et les attestations de provenance GitHub.
- Valide les modes Gun Game, Duel, Zombies, Tower Defense, Entrainement et lobby avec Carbon.

## 8.0.2 - 2026-08-23

- Stabilise les operations longues, les sauvegardes et le catalogue initial.
- Ajoute les tests de fiabilite et le manifeste de release.
