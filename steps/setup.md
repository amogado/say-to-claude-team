# Setup — Installation one-shot

**Ne doit etre lance qu'une seule fois.** Installe la queue, les hooks, les permissions, la statusline, et la shell function.

## Action

Lance :
```bash
bash <SKILL_DIR>/scripts/setup.sh
```

## Confirmer

Afficher :
- Setup termine
- Les sessions se registrent automatiquement au demarrage (hook SessionStart)
- Shell function `claude()` active (auto-connect)
- Commandes : `/say-to-claude-team [connect | send | check | status | watch | gc]`

## Etape suivante

Proposer a l'utilisateur de lancer `/say-to-claude-team connect` pour connecter cette session.
