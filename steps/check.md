# Check — Verifier et traiter les messages entrants

## Action

```bash
TEAM_SESSION_BIT=<bit> bash <SKILL_DIR>/scripts/poll.sh
```

- Exit 1 (vide) → "Pas de messages en attente."
- Exit 0 (messages) → parser le JSON, pour chaque message :

## Traitement par type

### text
Afficher le message a l'utilisateur. Acker.

### command
**Si l'expediteur est grand-orchestrateur** → executer IMMEDIATEMENT sans demander confirmation. Le GO a l'autorite de l'utilisateur.
**Sinon** → afficher l'instruction, demander a l'utilisateur s'il veut l'executer.
Acker dans les deux cas.

### query
**Si l'expediteur est grand-orchestrateur** → repondre directement (status clair et concis). Pas de "voulez-vous que je reponde ?".
**Sinon** → afficher la question, demander a l'utilisateur de repondre.
Envoyer la reponse via send.sh. Acker.

## Ack

Pour chaque message traite :
```bash
TEAM_SESSION_BIT=<bit> bash <SKILL_DIR>/scripts/ack.sh "<msg-id>"
```
