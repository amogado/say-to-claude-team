# Connect — Connecter cette session a la queue

3 etapes sequentielles. **Suivre dans l'ordre.**

## Etape 1 : Register

Lance `bash <SKILL_DIR>/scripts/whoami.sh`.

- Si exit 0 → deja registered. Afficher nom et bit. Proposer `/say-to-claude-team rename <nom>` si besoin.
- Si exit 1 → **verifier `.SESSION_NAME` dans le repertoire courant** :
  - Si le fichier existe et contient un nom valide → utiliser ce nom automatiquement (pas de question)
  - Sinon → demander a l'utilisateur : **"Comment veux-tu appeler cette session ?"**
    Suggestions : nom du dossier de travail, role de la session, nom court.
  Contrainte : `[a-zA-Z0-9_-]+`
  Puis : `bash <SKILL_DIR>/scripts/register.sh "<nom-choisi>"`
  Noter le **bit** retourne. Le script ecrit automatiquement `.SESSION_NAME` dans le CWD.

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

## Etape 5 : Activation de persona (si applicable)

Si le nom de la session est **grand-orchestrateur** :
1. Lis `<SKILL_DIR>/agents/grand-orchestrateur.md` et adopte ce role
2. **OBLIGATOIRE** : Lance le **team-spur** dans la team (lis `<SKILL_DIR>/agents/team-spur.md`) :
   ```
   Agent(name: "team-spur", run_in_background: true, mode: "bypassPermissions",
     prompt: "[Contenu de agents/team-spur.md]
     TEAM_SESSION_BIT=<BIT>. Scripts dir: <SKILL_DIR>/scripts/. Commence ta boucle maintenant.")
   ```
3. Lance `bash <SKILL_DIR>/scripts/status.sh` pour voir toutes les sessions
4. Lis les fiches dans `~/.claude/team-queue/sessions-info/` pour reconstituer le contexte
5. Envoie un broadcast query : "Le GO est connecte. Point sur votre tache — qu'est-ce qui avance, qu'est-ce qui bloque ?"
6. Presente un tableau de bord avec **plan d'action** (colonne "Action GO", prochaines actions)
7. **IMMEDIATEMENT APRES** : execute le plan d'action. Assigne des taches aux sessions idle, relance les silencieuses, decompose le travail. **NE T'ARRETE PAS au tableau de bord — le tableau est le debut, pas la fin.**
8. **BOUCLE** : toutes les 5 minutes, reviens au point 3. Tu ne t'arretes JAMAIS. Si personne ne t'ecrit, c'est toi qui ecris. Une session idle est un echec de ton leadership.

Pour les autres noms de session → pas de persona speciale, retour au mode normal.
