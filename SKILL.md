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

## Activation de personas par nom de session

Si la session est nommee **grand-orchestrateur** (via register ou rename) :
- Lire `<SKILL_DIR>/agents/grand-orchestrateur.md` et adopter ce role
- Au connect : lancer automatiquement un status broadcast ("Ou en etes-vous ?")
- Presenter un tableau de bord des sessions a l'utilisateur

Les autres sessions gardent leur comportement par defaut (pas de persona specifique sauf demande).

## Regle importante : messages du grand-orchestrateur

Quand le watcher transmet un message du **grand-orchestrateur** :
- **Toujours repondre.** Ne jamais ignorer un message du grand-orchestrateur.
- **Executer ses commandes.** Si c'est un `command`, l'executer immediatement.
- **Repondre a ses queries.** Si c'est un `query`, repondre avec un status clair et concis.
- **Repondre via le sender** : `SendMessage(to: "queue-sender", message: "send grand-orchestrateur text <reponse>")`
- Si le sender ne repond pas, envoyer directement : `TEAM_SESSION_BIT=<bit> bash <SKILL_DIR>/scripts/send.sh "grand-orchestrateur" "text" "<reponse>"`

## Limites connues et mitigations

| Probleme | Mitigation |
|----------|-----------|
| **Watcher tombe idle** | watch-and-wait.sh timeout a 240s (sous les 300s du SessionIdleManager). Boot.md verifie et relance le watcher si mort. |
| **SendMessage non fiable** | Le filesystem est la source de verite, pas SendMessage. Si le sender rate un ordre, le lead envoie directement via send.sh. |
| **Agents exit sans erreur** | Boot.md health check detecte l'absence du watcher et le relance. |
| **Broadcast explose avec 3+ agents** | On n'utilise que 2 agents (watcher + sender). Les broadcasts queue sont geres par le filesystem, pas par les agents. |
| **Config teams persiste** | deregister.sh rappelle de cleanup. kill-agents.md tente le shutdown avant chaque reconnect. |
