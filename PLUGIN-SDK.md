# Plugin SDK v1

Le SDK permet à Rust Server Control Center de générer automatiquement les réglages et les actions d'un plugin Carbon/Oxide. Il ne demande aucune dépendance dans le code C# : un manifeste JSON accompagne simplement le fichier `.cs`.

## Emplacements

- Manifestes fournis par l'application : `tool/sdk/manifests/*.json`
- Manifeste propre à une instance : `carbon/plugin-manifests/<FileBase>.json`
- Schéma public : `tool/sdk/plugin-manifest.schema.json`

Un manifeste placé dans l'instance remplace le manifeste fourni ayant le même `plugin.fileBase`. Un manifeste invalide est ignoré sans empêcher le serveur ni les autres plugins de fonctionner.

## Exemple minimal

```json
{
  "schemaVersion": 1,
  "id": "example-plugin",
  "plugin": {
    "fileBase": "ExamplePlugin",
    "displayName": "Example Plugin",
    "version": "1.0.0",
    "category": "gameplay",
    "capabilities": []
  },
  "config": {
    "fileName": "ExamplePlugin.json",
    "reloadOnSave": true,
    "settings": [
      {
        "id": "enabled",
        "path": "Enabled",
        "label": "Activer la fonction",
        "description": "Active ou désactive la fonction principale.",
        "type": "boolean",
        "default": true
      },
      {
        "id": "multiplier",
        "path": "Rewards.Multiplier",
        "label": "Multiplicateur",
        "type": "number",
        "default": 1,
        "min": 0.1,
        "max": 10
      }
    ]
  },
  "actions": [
    {
      "id": "status",
      "label": "AFFICHER L'ÉTAT",
      "kind": "rcon",
      "command": "example.status",
      "confirm": false
    }
  ]
}
```

## Types de réglages

`boolean`, `integer`, `number`, `string` et `choice` sont pris en charge. Un réglage `choice` doit fournir `options`. Les nombres peuvent fournir `min` et `max`. Les chemins imbriqués utilisent un point, par exemple `Rewards.Multiplier`.

Lors de l'enregistrement, le Control Center :

1. convertit et valide chaque valeur ;
2. refuse les identifiants et chemins inconnus ;
3. sauvegarde l'ancien JSON dans `backups/plugin-config/<identity>/` ;
4. écrit le nouveau JSON atomiquement ;
5. laisse l'administrateur décider du rechargement du plugin.

## Actions

La v1 accepte uniquement `kind: "rcon"`. Les commandes composites, séparateurs, retours ligne et caractères de shell sont refusés. Utilise `confirm: true` pour une action destructive ou susceptible d'interrompre une partie.

## Publication dans un catalogue

Une entrée de catalogue peut ajouter :

```json
{
  "manifestUrl": "https://example.org/ExamplePlugin.manifest.json",
  "manifestSha256": "<64 caractères hexadécimaux>"
}
```

Le catalogue embarqué utilise `bundledManifestPath`. À l'installation, le code C# et le manifeste sont vérifiés séparément par SHA-256, puis le `fileBase` du manifeste doit correspondre au nom du fichier C#.

## English summary

Plugin SDK v1 is a dependency-free JSON contract for Carbon/Oxide plugins. It declares typed settings and safe RCON actions. Instance manifests override bundled manifests by `plugin.fileBase`; invalid manifests are isolated. Configuration writes are validated, backed up and atomic. Catalog downloads require HTTPS and may be pinned with SHA-256.
