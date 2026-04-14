# Connect 5/5 — Activation de persona

## Si le nom de la session est `grand-orchestrateur` :

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

## Pour les autres noms de session :

Pas de persona speciale, retour au mode normal. **Connexion terminee.**
