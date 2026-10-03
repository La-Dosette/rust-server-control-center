# Publication Windows et GitHub

## Construire

```powershell
./Build-Standalone.ps1 -Version 12.1.0
./Build-SingleExe.ps1 -Version 12.1.0
./Build-WindowsInstaller.ps1 -Version 12.1.0
./scripts/Test-Release.ps1 -PackageRoot ./dist/RustServerControlCenter-Portable-v12.1.0
```

Le `.exe` normal est un lanceur autonome. Le `Setup` réinstalle les fichiers de l’application, crée les raccourcis et inscrit la désinstallation Windows sans effacer les mondes existants.

## Canaux et retour arrière

- tag `v12.1.0` : release stable ;
- tag `v12.2.0-beta.1` : préversion bêta.

Le canal stable utilise la dernière release non préversion. Le canal bêta accepte la release publiée la plus récente. Avant remplacement, l’updater sauvegarde chaque fichier géré avec sa taille et son SHA-256. La page Diagnostic global permet de restaurer une version précédente.

## Checklist

1. Exécuter les tests de fiabilité et de première installation.
2. Vérifier le ZIP, le lanceur et le Setup avec `--verify`.
3. Configurer le certificat comme décrit dans [SIGNING.md](SIGNING.md).
4. Pousser un tag signé `v*`. GitHub Actions construit, signe si possible, atteste et publie les artefacts.
