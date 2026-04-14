# Connect 2/5 — Kill les anciens agents

**BLOQUANT. Tu ne dois PAS lire un autre fichier tant que cette etape n'est pas terminee.**

## Etape 1 : Verifier si une team existe pour CETTE session

Regarde si tu es deja dans une team (tu le sais si TeamCreate echoue avec "Already leading team", ou si tu as des teammates visibles dans la barre en bas de l'ecran).

**Si tu n'as PAS de team ou PAS de teammates** → cette etape est terminee, passe directement a la suite.

**Ne PAS lire les fichiers dans ~/.claude/teams/** — ils contiennent les teams de TOUTES les sessions, pas seulement la tienne.

## Etape 2 : Shutdown chaque agent de TA team

Envoie un shutdown_request a chaque teammate que tu connais (queue-watcher, queue-sender, ou tout autre agent que tu as lance) :

```
SendMessage(to: "queue-watcher", message: {"type": "shutdown_request"})
SendMessage(to: "queue-sender", message: {"type": "shutdown_request"})
```

## Etape 3 : ATTENDRE les confirmations

**STOP. Ne fais RIEN d'autre. Attends.**

Pour chaque agent, attendre `shutdown_approved` ou `teammate_terminated`.

Si apres 15 secondes un agent n'a pas confirme → envoie un DEUXIEME shutdown_request.
Si apres 30 secondes il n'a toujours pas confirme → considere-le comme mort et continue.

---

**Suite → lis `<SKILL_DIR>/steps/connect/3-launch-agents.md`**
