# say-to-claude-team — Rules

## REGLE #1 : Ne JAMAIS modifier les fichiers dans ~/.claude/skills/

Le dossier `~/.claude/skills/say-to-claude-team/` est un **artefact de deploiement**, PAS la source de verite.

**Workflow obligatoire :**
1. Modifier les fichiers dans le REPO : `/Users/amogado/repos/say-to-claude-team/`
2. Deployer avec : `echo y | skill install /Users/amogado/repos/say-to-claude-team`

**Ne JAMAIS :**
- Editer directement dans `~/.claude/skills/say-to-claude-team/`
- Utiliser `cp` pour syncer manuellement entre repo et skills dir
- Modifier le SKILL.md, les scripts, les steps, ou les agents dans le skills dir

Toute modification faite dans le skills dir sera **ecrasee** au prochain `skill install`.

## Structure du repo

```
scripts/          # Scripts bash (send.sh, watch-and-wait.sh, etc.)
steps/            # Steps du routeur (boot.md, connect.md, connect/, etc.)
agents/           # Definitions d'agents (grand-orchestrateur.md, etc.)
tests/            # Test suite (test-suite.sh)
SKILL.md          # Definition du skill (routeur principal)
```

## Tests

Lancer les tests : `bash tests/test-suite.sh`

Les tests utilisent des fake PIDs (10001, 10002...) et un TEAM_QUEUE_DIR temporaire. Utiliser `TEAM_SESSION_BIT` (pas PID) pour identifier les sessions dans les scripts comme `set-mode.sh`.
