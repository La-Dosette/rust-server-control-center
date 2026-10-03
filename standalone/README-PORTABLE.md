# Rust Server Control Center — édition portable

Centre de contrôle Windows pour installer et administrer un serveur Rust Dedicated local ou accessible à des amis. L’application démarre en **Mode simple** et laisse tous les réglages techniques dans le **Mode avancé**.

## Démarrage

1. Décompresse le dossier dans un emplacement accessible en écriture.
2. Double-clique sur `LANCER-CONTROL-CENTER.vbs`.
3. Suis l’assistant de première installation. Rust Dedicated sera téléchargé officiellement avec SteamCMD.
4. Une fois l’installation terminée, clique sur **Démarrer**, puis sur **Ouvrir Rust**.

Le lancement de l’application et du serveur est silencieux. Les sorties techniques sont enregistrées dans `logs`.

## Jouer avec des amis

Sélectionne **Jouer avec des amis**. L’application copie l’adresse et ouvre son diagnostic réseau. Le guide intégré explique la redirection des ports pour les principaux types de box et de routeurs. Si les ports ne peuvent pas être ouverts, la page **Réseau & ports** fournit un assistant Tailscale : installation officielle vérifiée, connexion, état du réseau privé, invitation et commande Rust prête à partager.

## Vanilla, Carbon et plugins

La base est volontairement vanilla. Carbon n’est installé que sur demande. Les modes de jeu n’apparaissent que lorsqu’un plugin compatible est détecté. Le catalogue accepte des sources JSON en HTTPS, affiche les dépendances et conserve une sauvegarde avant mise à jour. Aucun binaire Rust, SteamCMD ou Carbon n’est distribué dans ce dépôt.

## Prérequis et limites

- Windows 10 ou 11 64 bits ;
- PowerShell 5.1 ;
- environ 15 Go de stockage libre pour Rust Dedicated ;
- 10 à 12 Go de RAM libres recommandés pour une instance ;
- le multi-instance est expérimental et peut dépasser rapidement la mémoire disponible ; plusieurs serveurs Carbon exigent un runtime complet isolé pour chacun ;
- l’hébergement à domicile dépend du routeur, du pare-feu et parfois du CGNAT de l’opérateur.

Les secrets RCON, mondes, sauvegardes, logs et adresses locales restent sur la machine et sont ignorés par Git.

Les sauvegardes du Control Center sont des archives ZIP vérifiées par SHA256. Avant une restauration, l’état actuel est sauvegardé et le nouveau monde est préparé séparément. Le diagnostic global vérifie installation, profils, stockage, sécurité, planning, historique et dernière sauvegarde sans démarrer Rust.

La page **Supervision** suit CPU, mémoire, disponibilité et erreurs de démarrage. La relance automatique et son service d’arrière-plan sont facultatifs et plafonnés. La page **Accès distant** crée un tableau de bord web local à jeton chiffré ; ne redirige pas ce port directement sur Internet, utilise un VPN ou un proxy HTTPS.

La page **Santé du PC** mesure CPU, RAM, disque, pare-feu, cartes réseau et VPN, puis estime prudemment combien d’instances supplémentaires la machine peut accepter. L’accès distant peut détecter une adresse Tailscale, WireGuard, ZeroTier, Hamachi, Radmin VPN ou OpenVPN et tester le service local avant partage.

## Installation et mises à jour du Control Center

- `Install-ControlCenter.ps1` installe l’application dans le profil Windows et crée les raccourcis ;
- `Update-ControlCenter.ps1 -Repository owner/repository` recherche la dernière Release GitHub, vérifie le `.sha256` puis chaque fichier du manifeste ;
- `Uninstall-ControlCenter.ps1` retire l’application en conservant les profils, mondes, secrets, logs et sauvegardes.

Les Releases GitHub publiées par le workflow reçoivent une attestation de provenance vérifiable avec `gh attestation verify`. Si les secrets `WINDOWS_CERTIFICATE_BASE64` et `WINDOWS_CERTIFICATE_PASSWORD` sont configurés, tous les scripts PowerShell du package sont aussi signés avec Authenticode avant la validation et la création de l’archive.

Une suppression complète des données exige une confirmation explicite en ligne de commande.

## Développement

L’interface est une application WPF écrite en XAML et PowerShell, sans installation Node ou .NET SDK. Lance `scripts/Test-Release.ps1` avant une publication.

Ce projet communautaire n’est ni affilié ni approuvé par Facepunch Studios. Rust et ses marques appartiennent à leurs propriétaires respectifs.
