# Rust Server Control Center

Application Windows flat-design pour installer, lancer et administrer des serveurs Rust Dedicated. Elle fonctionne d’abord en vanilla, détecte Carbon et les plugins installés, puis affiche uniquement les fonctions réellement disponibles.

Documentation : [guide utilisateur français](docs/USER-GUIDE.fr.md), [English user guide](docs/USER-GUIDE.en.md), [publication](docs/PUBLISHING.fr.md) et [signature Windows](docs/SIGNING.md).

## Deux niveaux d’interface

- **Mode simple** : jouer en local, préparer une connexion entre amis, gérer ses serveurs et ajouter des mods.
- **Mode avancé** : cartes et seeds, wipes, sauvegardes vérifiées, planification, diagnostic global avec réparations ciblées, santé complète du PC, supervision CPU/RAM, catalogue de plugins vérifiés, accès web LAN/VPN sécurisé, configuration visuelle, joueurs, statistiques, RCON, réseau, logs et multi-instance isolé.

Le choix est mémorisé dans `instances.json`. Une nouvelle installation démarre toujours en Mode simple.

## Construire l’édition portable

```powershell
./Build-Standalone.ps1 -Version 12.1.0
./Build-SingleExe.ps1 -Version 12.1.0
./Build-WindowsInstaller.ps1 -Version 12.1.0
./scripts/Test-Release.ps1 -PackageRoot ./dist/RustServerControlCenter-Portable-v12.1.0
```

`Build-SingleExe.ps1` produit un unique exécutable Windows sans console. Il embarque le ZIP portable vérifié, réutilise une installation existante ou l'installe silencieusement dans le profil utilisateur.

Le résultat est créé dans `dist` sous forme de dossier, d’archive ZIP et de somme `.sha256`. Chaque fichier du paquet est aussi enregistré dans `release-manifest.json`. La construction suit une liste blanche : elle ne contient ni Rust Dedicated, ni SteamCMD, ni moteur Carbon, ni carte, ni sauvegarde, ni log, ni secret RCON. Les huit plugins C# du catalogue officiel sont embarqués comme sources inspectables et verrouillés par SHA256.

`Install-ControlCenter.ps1` installe l’application et ses raccourcis. `Uninstall-ControlCenter.ps1` conserve les profils, mondes, secrets et sauvegardes par défaut. `Update-ControlCenter.ps1` refuse toute release dont la somme SHA256 ou le manifeste interne est invalide, vérifie les signatures Authenticode lorsqu’elles sont annoncées et permet de restaurer une sauvegarde de version. Le workflow `.github/workflows/release.yml` construit et publie automatiquement les deux assets à la création d’un tag `v*`, génère une attestation GitHub et applique une signature Authenticode au paquet et au `.exe` si un certificat est configuré dans les secrets du dépôt.

## Fiabilité des données

Les sauvegardes sont compressées en ZIP, accompagnées d’un manifeste SHA256 et vérifiées avant toute restauration. La restauration prépare d’abord un nouveau dossier puis permute le monde de façon transactionnelle, après avoir créé un point de retour. Chaque règle planifiée définit sa propre rotation de 2 à 100 sauvegardes.

La v12 démarre par un assistant matériel et réseau, puis laisse choisir Vanilla, Carbon ou Oxide/uMod. Elle distingue les mondes vanilla (isolés par `server.identity`) des serveurs moddés multiples, qui utilisent chacun un runtime Rust complet sous `data/instances/<id>/runtime`. Les cartes RustEdit importées sont copiées dans une bibliothèque locale, vérifiées par SHA-256 et peuvent recevoir une URL HTTPS pour les serveurs publics. Les profils Gun Game, Zombie, Tower Defense et Duel restent invisibles tant que leurs plugins ne sont pas actifs. Un plan de capacité contrôle les ports, la RAM et l’isolation avant un lancement groupé. Le watchdog est opt-in et plafonne les relances. Le tableau de bord web est désactivé par défaut, utilise un jeton DPAPI, détecte les adresses VPN et ne doit pas être exposé directement à Internet. Le catalogue accepte uniquement des sources HTTPS, résout les dépendances et vérifie les empreintes SHA-256 avant toute installation. Le SDK de plugins v1 ajoute des manifestes JSON vérifiés, des réglages typés et des actions RCON générées automatiquement dans l’interface.

Le diagnostic réseau reconnait les règles pare-feu attachées au port comme celles attachées à `RustDedicated.exe`. Quand le serveur amis tourne, il interroge aussi l’annuaire Steam officiel pour confirmer que l’IP publique et le query port sont visibles depuis l’extérieur. Une absence Steam reste distinguée d’une panne temporaire de l’API et le port RCON n’est jamais proposé à l’ouverture.

Le profil Tailscale intégré permet de jouer sans redirection de ports : téléchargement depuis le dépôt officiel, validation Authenticode, connexion par navigateur sans secret conservé, détection de l’adresse privée et des pairs, invitation et génération de la commande Rust pour l’ami.

### À ajouter dans l’interface

- Afficher séparément **Adresse pour moi** (`127.0.0.1:port`) et **Adresse à partager avec mes amis** (`IP publique:port`), avec un bouton de connexion locale et un bouton de copie distincts. L’adresse publique ne doit jamais être utilisée par l’hôte depuis son propre PC.

Pour rendre un plugin tiers compatible avec l'inspecteur visuel, consulte [Plugin SDK v1](PLUGIN-SDK.md).

Consulte le `README.md` du paquet portable pour les instructions utilisateur.

## Tester une première installation

Le scénario rapide installe le paquet dans un dossier isolé, sans réutiliser Rust, SteamCMD, les profils ou les secrets de la machine :

```powershell
./scripts/Test-FirstRunExperience.ps1 -PackageRoot ./dist/RustServerControlCenter-Portable-v12.1.0 -OutputRoot ./artifacts/first-run -KeepFixture
```

Il vérifie la détection matérielle, le démarrage en Vanilla, les erreurs réparables, la réparation sûre, la création guidée d’un serveur, les collisions de ports et la commande `client.connect`. Il génère un rapport JSON et deux captures de l’interface. Le workflow `validate-portable.yml` l’exécute sur un runner Windows GitHub neuf. En lancement manuel, ses options `install_rust` et `launch_rust` permettent le test lourd avec téléchargement réel de Rust Dedicated et premier démarrage.

## Licence et marques

Le code du Control Center est distribué sous licence MIT. Ce projet communautaire n’est ni affilié ni approuvé par Facepunch Studios. Rust et ses marques appartiennent à leurs propriétaires respectifs.
