# Connect 1/5 — Register

## Etape 1 : Verifier si deja registered

Lance `bash <SKILL_DIR>/scripts/whoami.sh`.

- Si exit 0 → deja registered. Afficher nom et bit. Proposer `/say-to-claude-team rename <nom>` si besoin. **Passe a l'etape suivante.**
- Si exit 1 → pas encore registered. Continue ci-dessous.

## Etape 2 : Determiner le nom de session

**OBLIGATOIRE : verifier `.SESSION_NAME` dans le repertoire courant AVANT toute autre chose.**

```bash
cat .SESSION_NAME 2>/dev/null
```

- Si le fichier existe et contient un nom valide (`[a-zA-Z0-9_-]+`) → **utiliser ce nom automatiquement**. Pas de question a l'utilisateur.
- Si le fichier n'existe pas ou est vide → demander a l'utilisateur : **"Comment veux-tu appeler cette session ?"**
  Suggestions : nom du dossier de travail, role de la session, nom court.

## Etape 3 : Register

```bash
bash <SKILL_DIR>/scripts/register.sh "<nom-choisi>"
```

Noter le **bit** retourne. Le script ecrit automatiquement `.SESSION_NAME` dans le CWD.

---

**Suite → lis `<SKILL_DIR>/steps/connect/2-kill-agents.md`**
