# Securite

Signale une vulnerabilite sans publier de secret, de jeton, de mot de passe RCON, d'adresse privee ou de sauvegarde serveur dans une issue publique.

Le tableau de bord distant est concu pour un LAN ou un VPN prive. Ne publie pas son port directement sur Internet. Utilise un secret RCON unique par serveur et regenere-le depuis le diagnostic s'il a ete divulgue.

Avant installation, verifie la somme SHA-256 de l'archive et, lorsqu'elle est disponible, l'attestation de provenance de la release GitHub.
