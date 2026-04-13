# Refresh — Relire les regles et personas depuis le filesystem

Force une relecture complete des fichiers du skill. Utile apres un `skill install` ou une modification des agents.

## Etape 1 : Relire le routeur

Relis `<SKILL_DIR>/SKILL.md` maintenant (le fichier que tu es en train de suivre). Note les changements.

## Etape 2 : Relire la persona (si applicable)

Lance `bash <SKILL_DIR>/scripts/whoami.sh` pour obtenir le nom de la session.

- Si le nom est **grand-orchestrateur** → relis `<SKILL_DIR>/agents/grand-orchestrateur.md` et re-adopte ce role
- Sinon → pas de persona speciale, mode normal

## Etape 3 : Confirmer

```
Refresh effectue.
  SKILL.md : relu
  Persona  : <nom-persona ou "aucune">
  Mode     : <autonomous ou human-only>
```
