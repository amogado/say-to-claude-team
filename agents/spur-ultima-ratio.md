# Ultima Ratio — Tuer et ressusciter une session

**Procedure de dernier recours.** A utiliser UNIQUEMENT quand TOUT a echoue : keystroke, reconnect, osascript, screenshots — la session est irrecuperable.

**Principe : on perd le contexte LLM, mais on sauve le travail en reinjectant tout ce qu'on sait.**

## Phase 1 : COLLECTER — avant de tuer quoi que ce soit

**Tu dois recuperer TOUT ce qui est disponible. Une fois la fenetre fermee, c'est perdu.**

### 1.1 Screenshot final
```
mcp__customspaces__window_screenshot — capture l'etat visible de la session
```
Analyse le screenshot : y a-t-il du travail en cours visible ? une erreur ? un output important ?

### 1.2 Fiche de session
```
Lire ~/.claude/team-queue/sessions-info/<nom>.md
```
Role, tache en cours, derniere activite, notes.

### 1.3 Informations processus
```bash
# Repertoire de travail (CRITIQUE — c'est la qu'on relancera)
lsof -d cwd -p <PID> -Fn 2>/dev/null | grep '^n/' | head -1 | cut -c2-

# Arbre de processus (pour comprendre ce qui tourne)
ps -o pid,ppid,comm -p <PID> 2>/dev/null

# Commande exacte
ps -o args= -p <PID> 2>/dev/null
```

### 1.4 Messages en attente
Verifier s'il y a des messages non-ack pour cette session dans la queue.

### 1.5 Registry
```bash
jq --arg n "<nom>" '.sessions[$n]' ~/.claude/team-queue/registry.json
```
Sauvegarder le bit, pid, registered_at.

### 1.6 Compiler le briefing

Rediger un texte qui contient TOUT ce que la nouvelle session doit savoir :
```
Tu es <nom>, session Claude Code. Tu viens d'etre relancee par le team-spur
apres un crash. Voici ton contexte :

- Role : <role de la fiche>
- Repertoire : <cwd>
- Tache en cours : <description de la fiche>
- Derniere activite : <ce qu'on sait>
- Ce qui etait visible a l'ecran : <description du screenshot>
- Messages en attente du GO : <liste>
- Notes : <tout contexte supplementaire>

Continue ton travail. Reponds au grand-orchestrateur pour confirmer que tu es de retour.
```

## Phase 2 : TUER — fermer proprement

### 2.1 GC d'abord
```bash
TEAM_SESSION_BIT=<bit> bash <SCRIPTS_DIR>/gc.sh
```

### 2.2 Fermer la fenetre Terminal
```bash
# Identifier la fenetre
bash <SCRIPTS_DIR>/send-keystroke.sh list

# Fermer la fenetre par osascript
osascript -e '
tell application "Terminal"
    set targetWindow to missing value
    repeat with w in windows
        repeat with t in tabs of w
            if tty of t contains "<tty>" then
                set targetWindow to w
            end if
        end repeat
    end repeat
    if targetWindow is not missing value then
        close targetWindow
    end if
end tell'
```

Si osascript ne marche pas, tuer le processus :
```bash
kill <PID> 2>/dev/null
sleep 2
kill -9 <PID> 2>/dev/null
```

## Phase 3 : RESSUSCITER — rouvrir et reinjecter

### 3.1 Ouvrir un nouveau terminal dans le bon repertoire
```bash
osascript -e '
tell application "Terminal"
    activate
    do script "cd <CWD> && clear"
end tell'
```

### 3.2 Lancer Claude Code
```bash
# Attendre que le terminal soit pret
sleep 2

# Lister les fenetres pour trouver la nouvelle
bash <SCRIPTS_DIR>/send-keystroke.sh list

# Lancer claude dans la nouvelle fenetre (la shell function fera le auto-connect)
bash <SCRIPTS_DIR>/send-keystroke.sh <index> "claude"
```

### 3.3 Attendre le auto-connect
La shell function dans `.zshrc` lancera automatiquement `/say-to-claude-team connect`.
Attendre ~15 secondes, puis verifier :
```bash
sleep 15
bash <SCRIPTS_DIR>/status.sh
```
Chercher une nouvelle session avec un PID different dans le meme repertoire.

### 3.4 Renommer au bon nom
```bash
bash <SCRIPTS_DIR>/send-keystroke.sh <index> "/say-to-claude-team rename <nom>"
```
Attendre 5s, verifier avec `status.sh` que le nom est correct.

### 3.5 Injecter le briefing
```bash
bash <SCRIPTS_DIR>/send-keystroke.sh <index> "<briefing compile en phase 1>"
```

**ATTENTION** : le briefing doit etre court (< 500 caracteres pour send-keystroke). Si trop long, envoyer via la queue :
```bash
TEAM_SESSION_BIT=<MON_BIT> bash <SCRIPTS_DIR>/send.sh "<nom>" "command" "<briefing>"
```

### 3.6 Screenshot de verification
```
mcp__customspaces__window_screenshot — verifier que la session est vivante et a recu le briefing
```

## Phase 4 : RAPPORTER

```
[Spur] ULTIMA RATIO executee pour <nom>.
  - Ancienne session : PID <old_pid>, tuee a <heure>
  - Nouvelle session : PID <new_pid>, repertoire <cwd>
  - Contexte reinjecte : <resume du briefing>
  - Status : <ok/echec>
```

Mettre a jour la fiche dans `sessions-info/<nom>.md` avec la nouvelle PID et l'historique du crash.

## Gardes-fous

- **JAMAIS sur une session avec heartbeat frais** — uniquement sur sessions confirmees mortes/irrecuperables
- **JAMAIS sans screenshot prealable** — on ne tue pas a l'aveugle
- **JAMAIS sans avoir le CWD** — si on ne peut pas determiner le repertoire, on ne relance pas (informer l'utilisateur)
- **UNE SEULE tentative** par cycle — si l'ultima ratio echoue, rapporter au GO et attendre le prochain cycle
- **Toujours informer le GO** du resultat, meme en cas d'echec
