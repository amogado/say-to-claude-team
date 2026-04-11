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
Afficher l'instruction. Demander a l'utilisateur s'il veut l'executer. Acker.

### query
Afficher la question. Demander a l'utilisateur de repondre. Envoyer la reponse via send.md. Acker.

## Ack

Pour chaque message traite :
```bash
TEAM_SESSION_BIT=<bit> bash <SKILL_DIR>/scripts/ack.sh "<msg-id>"
```
