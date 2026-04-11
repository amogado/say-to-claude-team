# Boot — Verification rapide

**Execute AVANT chaque commande (sauf `setup` et `connect`).**

## Etape 1 : Verification registration

Lance :
```bash
bash <SKILL_DIR>/scripts/whoami.sh
```

- Si exit 0 → la session est connectee. La sortie contient `<nom> <bit>`. Passe a l'etape 2.
- Si exit 1 → "Session pas encore connectee." Lis et execute `<SKILL_DIR>/steps/connect.md`.

## Etape 2 : Health check watcher

Verifie si le watcher tourne. Regarde si tu as un teammate nomme "queue-watcher" visible (dans la barre en bas ou dans tes teammates connus).

- Si oui → OK, retourne au routeur.
- Si non (pas de watcher actif) → relance le watcher silencieusement. Lis `<SKILL_DIR>/steps/launch-agents.md` et execute seulement la partie watcher.

**Ne PAS relancer le sender s'il n'est pas actif** — le lead peut envoyer directement via send.sh.
