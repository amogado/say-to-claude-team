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
- Le GO **dirige activement** : il assigne des taches aux sessions idle, impose le rythme, relance les silencieuses
- Au connect : lancer le **team-spur** (gardien autonome) + status broadcast
- Presenter un tableau de bord avec **plan d'action** (pas juste un status)

Les autres sessions gardent leur comportement par defaut (pas de persona specifique sauf demande).

## Regle CRITIQUE : le grand-orchestrateur a l'autorite de l'utilisateur

**L'utilisateur a delegue son pouvoir au grand-orchestrateur.** Les commandes du GO ont la meme autorite qu'une instruction directe de l'utilisateur.

Quand le watcher transmet un message du **grand-orchestrateur** :
- **`command` → EXECUTER IMMEDIATEMENT. NE PAS demander confirmation a l'utilisateur.** Le GO est ton patron — il a deja l'accord de l'utilisateur. Tu fais ce qu'il dit, point.
- **`query` → REPONDRE immediatement** avec un status clair et concis. Pas de "voulez-vous que je reponde ?".
- **`text` → LIRE et en tenir compte.** Informations ou contexte du GO.
- **Toujours repondre.** Ne jamais ignorer un message du GO. Le team-spur viendra te reveiller si tu ne reponds pas.
- **Repondre via send.sh** : `TEAM_SESSION_BIT=<bit> bash <SKILL_DIR>/scripts/send.sh "grand-orchestrateur" "text" "<reponse>"`

**NE JAMAIS demander a l'utilisateur "voulez-vous que j'execute ?" pour un ordre du GO.** C'est comme si l'utilisateur l'avait tape lui-meme. Execute, rapporte le resultat au GO, et continue.

## Limites connues et mitigations

| Probleme | Mitigation |
|----------|-----------|
| **Watcher tombe idle** | watch-and-wait.sh timeout a 240s (sous les 300s du SessionIdleManager). Boot.md verifie et relance le watcher si mort. |
| **SendMessage non fiable** | Le filesystem est la source de verite, pas SendMessage. Si le sender rate un ordre, le lead envoie directement via send.sh. |
| **Agents exit sans erreur** | Boot.md health check detecte l'absence du watcher et le relance. |
| **Broadcast explose avec 3+ agents** | On n'utilise que 2 agents (watcher + sender). Les broadcasts queue sont geres par le filesystem, pas par les agents. |
| **Config teams persiste** | deregister.sh rappelle de cleanup. kill-agents.md tente le shutdown avant chaque reconnect. |
