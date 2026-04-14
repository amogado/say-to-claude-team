# Connect 3/5 — Lancer les nouveaux agents

**Pre-requis : les anciens agents doivent etre morts (etape 2).**

## Recuperer le bit

```bash
bash <SKILL_DIR>/scripts/whoami.sh
```
La sortie contient `<nom> <bit>`. Utiliser ce bit pour les agents.

## Creer la team (si pas deja fait)

```
TeamCreate(team_name: "queue-<nom>")
```
Si erreur "Already leading team" → OK, continuer.

## Spawner les 2 agents EN PARALLELE

### Watcher (blocking poll)

```
Agent(
  name: "queue-watcher",
  team_name: "queue-<nom>",
  run_in_background: true,
  mode: "bypassPermissions",
  prompt: "Tu es le Watcher pour '<nom>' (bit <BIT>).
  TEAM_SESSION_BIT=<BIT> pour TOUTES les commandes.
  Ne JAMAIS lancer register.sh.
  Boucle : bash <SKILL_DIR>/scripts/watch-and-wait.sh <BIT> <SKILL_DIR>/scripts (timeout 600000ms)
  Exit 0 → parse JSON, SendMessage au lead, ack chaque message.
  Exit 1 → relance silencieusement.
  Exit 10 → signale au lead et stop.
  SILENCE quand pas de messages."
)
```

### Sender

```
Agent(
  name: "queue-sender",
  team_name: "queue-<nom>",
  run_in_background: true,
  mode: "bypassPermissions",
  prompt: "Tu es le Sender pour '<nom>' (bit <BIT>).
  TEAM_SESSION_BIT=<BIT> pour send.sh.
  Scripts dir: <SKILL_DIR>/scripts/
  Attends les ordres du lead. Format: send <target> <type> <body>
  Execute send.sh et confirme au lead."
)
```

---

**Suite → lis `<SKILL_DIR>/steps/connect/4-confirm.md`**
