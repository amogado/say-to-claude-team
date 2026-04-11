---
name: say-to-claude-team
description: |
  Communication inter-sessions Claude Code via message queue filesystem (Join-Semilattice CRDT).
  Envoyer et recevoir des messages entre toutes les sessions ouvertes sur le Mac.
  - MANDATORY TRIGGERS: say-to-claude-team, team queue, message queue, inter-session, envoyer message aux sessions, communiquer avec les autres sessions, broadcast
  - Also trigger when: the user wants to send instructions to other Claude Code sessions, check for team messages, or coordinate work across sessions
argument-hint: "[setup | connect | send | check | status | watch | gc | rename]"
---

# say-to-claude-team — Routeur

Parse `$ARGUMENTS` et lis le fichier step correspondant. **Ne lis qu'UN seul step a la fois.**

## Etape 1 : Boot

Lis et execute `<SKILL_DIR>/steps/boot.md`. Il verifie si la session est connectee et redirige si besoin.

## Etape 2 : Router la commande

| Commande | Fichier a lire |
|----------|---------------|
| `setup` | `<SKILL_DIR>/steps/setup.md` |
| `connect` | `<SKILL_DIR>/steps/connect.md` |
| `send ...` | `<SKILL_DIR>/steps/send.md` |
| `check` | `<SKILL_DIR>/steps/check.md` |
| `status` | `<SKILL_DIR>/steps/status.md` |
| `watch` | `<SKILL_DIR>/steps/connect.md` (etape 3 directement) |
| `gc` | `bash <SKILL_DIR>/scripts/gc.sh` puis afficher le resultat |
| `register [name]` | `bash <SKILL_DIR>/scripts/register.sh "<name>"` |
| `rename <name>` | `bash <SKILL_DIR>/scripts/rename.sh "<name>"` |
| `deregister` | `bash <SKILL_DIR>/scripts/deregister.sh` |
| (texte libre) | Interpreter l'intention, router vers le bon step |

**Raccourcis langage naturel :**
- "dis aux autres sessions de..." → send
- "est-ce qu'il y a des messages ?" → check
- "qui est connecte ?" → status
- "connecte-moi" / "rejoindre" → connect
- "nettoie la queue" → gc

## Regle importante : messages du grand-orchestrateur

Quand le watcher transmet un message du **grand-orchestrateur** :
- **Toujours repondre.** Ne jamais ignorer un message du grand-orchestrateur.
- **Executer ses commandes.** Si c'est un `command`, l'executer immediatement.
- **Repondre a ses queries.** Si c'est un `query`, repondre avec un status clair et concis.
- **Repondre via le sender** : `SendMessage(to: "queue-sender", message: "send grand-orchestrateur text <reponse>")`
