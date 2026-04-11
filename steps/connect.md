# Connect — Connecter cette session a la queue

3 etapes sequentielles. **Suivre dans l'ordre.**

## Etape 1 : Register

Lance `bash <SKILL_DIR>/scripts/whoami.sh`.

- Si exit 0 → deja registered. Afficher nom et bit. Proposer `/say-to-claude-team rename <nom>` si besoin.
- Si exit 1 → demander a l'utilisateur : **"Comment veux-tu appeler cette session ?"**
  Suggestions : nom du dossier de travail, role de la session, nom court.
  Contrainte : `[a-zA-Z0-9_-]+`
  Puis : `bash <SKILL_DIR>/scripts/register.sh "<nom-choisi>"`
  Noter le **bit** retourne.

## Etape 2 : Kill les anciens agents

**OBLIGATOIRE.** Lis et execute `<SKILL_DIR>/steps/kill-agents.md` MAINTENANT.
**ATTENDS que kill-agents.md soit termine avant de passer a l'etape 3.**

## Etape 3 : Lancer les nouveaux agents

Lis et execute `<SKILL_DIR>/steps/launch-agents.md`.

## Etape 4 : Confirmer

```
Connecte a la team queue !
  Session : <nom> (bit <BIT>)
  Watcher : actif (reception)
  Sender  : actif (envoi)
```
