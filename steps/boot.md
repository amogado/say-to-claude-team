# Boot — Verification rapide

**Execute AVANT chaque commande (sauf `setup` et `connect`).**

## Action

Lance :
```bash
bash <SKILL_DIR>/scripts/whoami.sh
```

## Si exit 0 (connecte)

La sortie contient `<nom> <bit>`. La session est connectee. Retourne au routeur et execute la commande demandee.

## Si exit 1 (pas connecte)

Dis a l'utilisateur : "Session pas encore connectee. Je lance la connexion."
Puis lis et execute `<SKILL_DIR>/steps/connect.md`.
