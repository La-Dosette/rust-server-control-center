# Rapport de validation v9.0.0

Date : 23 aout 2026

## Perimetre livre

- Centre de controle Windows vanilla-first, puis Carbon et plugins a la demande.
- Gestion multi-serveurs et multi-instance avec preflight ports, RAM et isolation.
- Sante CPU, RAM, disque, processus Rust, pare-feu, cartes reseau et VPN.
- Diagnostic global avec reparations ciblees et regeneration sure du secret RCON.
- Catalogue de huit plugins sources verifies par SHA-256.
- Planification des sauvegardes et wipes, historique persistant et notifications.
- Interface francaise et anglaise, mode simple et mode avance.
- Paquet portable, installation locale, mise a jour verifiee et workflows GitHub.

## Validation automatique

- Analyse syntaxique PowerShell : aucun defaut sur le build, le gestionnaire, les services, la signature et les tests.
- Test de release : 52 fichiers controles par SHA-256, aucune donnee privee detectee.
- Fiabilite : 19 scenarios reussis, dont l'installation reelle d'un plugin embarque.
- Archive finale : `RustServerControlCenter-Portable-v9.0.0.zip`.
- La somme SHA-256 propre a chaque construction est livree avec l'archive dans le fichier `.zip.sha256`.

## Validation serveur reelle

Rust Dedicated et Carbon ont demarre sans erreur de compilation. Huit plugins ont ete charges. Les controles ont confirme :

- Gun Game avec 26 armes jouables, arene generee et munitions infinies;
- files Duel de 1v1 a 4v4 et generation d'arene;
- lobby central;
- Tower Defense endless avec deux routes fixes et mouvement sans NavMesh;
- entrainement avec trois cibles mobiles;
- Zombies avec dix vagues et mode endless disponible;
- commandes de statistiques, sauvegarde serveur et arret propre.

## Limites de la validation

Le comportement avec de vrais joueurs pour Zombies, les duels complets et le Gun Game doit encore etre teste en partie. Le test VPN de bout en bout demande un adaptateur VPN actif et un second appareil. La signature Authenticode demande un certificat de signature de code; sans certificat, la release reste verifiee par SHA-256 et attestation GitHub.
