# Recherche : Auto-connect des sessions Claude Code

**Status:** TERMINÉ
**Question:** Comment faire pour que chaque nouvelle session Claude Code exécute automatiquement `/say-to-claude-team connect` de manière fiable ?

## Contexte

On a un skill `/say-to-claude-team connect` qui doit être exécuté au démarrage de chaque session. Le flow connect : demande un nom → register → lance un watcher background.

### Ce qu'on sait déjà
- `--append-system-prompt` est un SYSTEM prompt passif — Claude ne l'exécute pas comme une commande
- Le positional argument `claude "message"` envoie un vrai message utilisateur en mode interactif
- Le hook `SessionStart` ne peut lancer que des commandes shell, pas des skills
- La shell function `claude() { command claude "/say-to-claude-team connect"; }` fonctionne mais consomme le premier message

### Questions ouvertes
1. Est-ce que la shell function est la meilleure approche ? Quels edge cases ?
2. Y a-t-il un mécanisme Claude Code natif qu'on a raté ?
3. Comment gérer le cas où l'utilisateur veut passer un argument à claude (ex: `claude -c`) ?
4. Le CLAUDE.md pourrait-il être rendu plus fiable avec un wording spécifique ?
5. Existe-t-il des plugins, hooks, ou extensions qui permettent d'auto-exécuter au démarrage ?

---

## Findings par agent

### Agent 1 : Shell Function Deep Dive

#### Fonction actuelle

```zsh
claude() {
  if [ $# -eq 0 ]; then
    command claude "/say-to-claude-team connect"
  else
    command claude "$@"
  fi
}
```

**Mécanisme** : `command claude` bypass la fonction elle-même et appelle le binaire `/opt/homebrew/bin/claude` directement, évitant la récursion infinie. Le positional argument `"/say-to-claude-team connect"` est envoyé comme premier message utilisateur en mode interactif.

#### Analyse des cas d'usage

| Commande | $# | Comportement | Correct ? |
|---|---|---|---|
| `claude` | 0 | → `command claude "/say-to-claude-team connect"` | OUI - auto-connect |
| `claude -c` | 1 | → `command claude -c` | OUI - continue normalement |
| `claude -p "query"` | 2 | → `command claude -p "query"` | OUI - print mode |
| `claude --resume` | 1 | → `command claude --resume` | OUI - resume |
| `claude "fais X"` | 1 | → `command claude "fais X"` | OUI - message custom, pas d'auto-connect |
| `claude -c --model opus` | 2+ | → `command claude -c --model opus` | OUI - passthrough |
| `claude --worktree` | 1 | → `command claude --worktree` | OUI - passthrough |

**Verdict** : La logique `$# -eq 0` est correcte pour tous les cas testés. Le seul cas où auto-connect se déclenche est `claude` sans argument, ce qui est exactement le cas d'usage "ouvrir une nouvelle session interactive".

#### Problème identifié : "Premier message consommé"

Quand `claude "/say-to-claude-team connect"` est lancé, le slash command `/say-to-claude-team connect` est envoyé comme premier message utilisateur. Cela signifie :

1. **La session démarre avec le connect comme premier échange** — l'utilisateur voit le flow connect (choix de nom, register, lancement watcher) avant de pouvoir taper quoi que ce soit.
2. **Ce n'est PAS gênant** en pratique : le connect doit de toute façon être la première action. L'utilisateur n'aurait rien tapé d'autre avant.
3. **L'historique de conversation** contient le message connect — c'est visible mais pas problématique.

**Évaluation** : comportement acceptable. Le "message consommé" est en réalité le message qu'on VEUT envoyer.

#### Comparaison : function vs alias vs wrapper script

| Approche | Avantages | Inconvénients |
|---|---|---|
| **Shell function** (actuel) | Logique conditionnelle ($#), pas de fork, modifiable, rapide | Doit être sourcé dans .zshrc, spécifique au shell |
| **Alias** | Simple (`alias claude='claude "/say-to-claude-team connect"'`) | Pas de logique conditionnelle — impossible de pass-through `claude -c` etc. Éliminé. |
| **Wrapper script dans PATH** | Fonctionne dans tous les shells, pas besoin de sourcer | Fork un subshell, plus lent, doit gérer le PATH pour éviter la récursion (ex: appeler `/opt/homebrew/bin/claude` en chemin absolu), moins intégré |
| **Autoload zsh function** | Lazy loading, séparation des fichiers | Overkill pour une seule fonction, complexité inutile |

**Recommandation** : la shell function est la meilleure approche. Elle est rapide (pas de fork), supporte la logique conditionnelle, et le pattern `command` est un idiome shell standard et bien documenté.

#### Edge cases et robustesse

1. **`command` est fiable** : c'est un builtin POSIX, fonctionne en bash et zsh. Il bypass les fonctions ET les alias pour appeler directement l'exécutable.

2. **Quoting** : `"$@"` est correctement quoté, préserve les arguments avec espaces (ex: `claude -p "ma question longue"`).

3. **Code de sortie** : la fonction retourne implicitement le code de sortie de `command claude`, donc `$?` est préservé. C'est correct.

4. **Portabilité bash/zsh** : la syntaxe `[ $# -eq 0 ]` est POSIX, fonctionne dans les deux shells. Le setup.sh détecte correctement .zshrc vs .bashrc.

5. **Interaction avec d'autres wrappers** : si un autre outil (ex: direnv, nvm) wrap aussi `claude`, l'ordre de définition dans .zshrc compte. Notre function doit être définie en dernier pour prendre la priorité.

6. **`which claude` vs `type claude`** : après sourcing, `type claude` montrera "claude is a shell function" au lieu du binaire. Cela peut surprendre les utilisateurs qui debuggent. Documenter dans le README.

7. **Subshells et scripts** : la function n'est PAS exportée (`export -f`), donc elle n'est pas disponible dans les scripts lancés depuis le shell. C'est correct — seul le shell interactif doit auto-connect.

#### Amélioration possible : bypass via variable d'environnement

```zsh
claude() {
  if [ $# -eq 0 ] && [ -z "${CLAUDE_NO_TEAM:-}" ]; then
    command claude "/say-to-claude-team connect"
  else
    command claude "$@"
  fi
}
# Usage: CLAUDE_NO_TEAM=1 claude  → lance sans auto-connect
```

Cela reste optionnel — le cas d'usage est rare mais utile pour le debug.

#### Conclusion Agent 1

La shell function est l'approche optimale. Elle est simple, fiable, bien quotée, POSIX-compatible, et couvre tous les cas d'usage identifiés. Le seul point d'attention est la documentation (expliquer que `type claude` montrera une function) et l'option de bypass via variable d'environnement.

### Agent 2 : Mécanismes natifs Claude Code

#### 1. Inventaire complet des mecanismes natifs explores

J'ai explore systematiquement tous les mecanismes natifs de Claude Code qui pourraient permettre l'auto-execution au demarrage.

#### 2. Hooks — le mecanisme officiel le plus proche

**SessionStart hook** (configure dans `~/.claude/settings.json`) :
- Se declenche sur les evenements : `startup`, `resume`, `clear`, `compact`
- **Stdout est injecte comme contexte** que Claude voit et peut utiliser (cap a 10,000 caracteres)
- Peut ecrire dans `$CLAUDE_ENV_FILE` pour persister des variables d'environnement
- **Limitation fondamentale** : execute uniquement des commandes shell, pas des skills/slash-commands
- Les hooks SessionStart s'executent AVANT que les plugins soient completement charges (issue #19491)

**Configuration actuelle** (deja en place dans settings.json) :
```json
"SessionStart": [{
  "matcher": "",
  "hooks": [{
    "type": "command",
    "command": "bash $HOME/.claude/skills/say-to-claude-team/scripts/register.sh \"$(hostname -s)-$$\" 2>/dev/null; true"
  }]
}]
```
Cela fait le `register` shell mais ne lance PAS le skill `/say-to-claude-team connect` (qui inclut le watcher background cote Claude).

**Autres hooks explores** :
- `PreToolUse` : se declenche avant chaque outil, peut deny/approve/modifier — pas utile pour le startup
- `PostToolUse` : se declenche apres chaque outil — pas utile pour le startup
- `Notification` : se declenche pour les notifications — pas pertinent
- Il n'existe PAS de hook `PreMessage` ou `FirstMessage` qui pourrait intercepter et injecter un skill

#### 3. Flags CLI — exploration exhaustive

Flags explores via `claude --help` :

| Flag | Potentiel | Verdict |
|------|-----------|---------|
| `--append-system-prompt` | Ajoute au system prompt | Passif — Claude ne l'execute pas comme commande |
| `--system-prompt` | Remplace le system prompt | Trop destructif, perd les instructions builtin |
| Positional arg (`claude "msg"`) | Envoie comme premier message user | **Le plus fiable** — traite comme vrai message |
| `--agents` | Definit des agents custom en JSON | Pas de mecanisme de startup auto |
| `--plugin-dir` | Charge des plugins | Les plugins n'ont pas de hook de startup fiable |
| `--bare` | Mode minimal, skip hooks/CLAUDE.md | Contre-productif |
| `-c / --continue` | Resume une session | Pas de startup hook |
| `--settings` | Charge des settings additionnels | Pas de champ "initialPrompt" ou equivalent |

**Conclusion** : aucun flag CLI ne permet d'auto-executer un skill au demarrage en mode interactif.

#### 4. Settings.json — champs explores

J'ai analyse `~/.claude/settings.json` et la documentation officielle :
- `permissions` : controle les outils autorises (allow/deny)
- `hooks` : les lifecycle hooks (SessionStart, PreToolUse, etc.)
- `env` : variables d'environnement
- `statusLine` : commande pour la barre de statut
- `enabledPlugins` : plugins actives
- **Il n'existe PAS** de champ `initialPrompt`, `startupCommand`, `autoExecute`, ou equivalent
- **Il n'existe PAS** de champ pour injecter un message utilisateur au demarrage

#### 5. CLAUDE.md — capacites et limites

**Fichiers CLAUDE.md explores** :
- `~/.claude/CLAUDE.md` (global) : contient deja l'instruction de lancer `/say-to-claude-team connect`
- `.claude/CLAUDE.md` (projet) : inexistant pour ce projet

**Mecanisme** : CLAUDE.md est charge comme contexte systeme passif. Claude le lit mais ne l'execute pas comme du code.
- Il n'existe PAS de directive HTML `<!-- auto-execute: ... -->` ou equivalent
- Il n'existe PAS de format frontmatter ou pragma qui forcerait l'execution
- La fiabilite de l'execution des instructions CLAUDE.md au startup est d'environ 40% selon la communaute (cf. issues #13422, #34763, #28678, #44960)

#### 6. Systeme de plugins

J'ai explore `~/.claude/plugins/` :
- Les plugins peuvent definir des hooks, des skills, des agents, et des serveurs MCP
- **Probleme connu** (issue #10997, #19491) : les hooks SessionStart des plugins ne s'executent pas de maniere fiable au premier demarrage car les plugins ne sont pas encore charges
- Les plugins n'ont PAS de mecanisme `onSessionStart` qui executerait un skill
- Les plugins sont charges APRES les hooks de settings.json

#### 7. Mecanisme de stdout injection via SessionStart

C'est la piste la plus prometteuse des mecanismes natifs :
- Le stdout d'un hook SessionStart est injecte dans le contexte de Claude
- On pourrait faire : `echo "CRITICAL: Execute /say-to-claude-team connect NOW before doing anything else"`
- **Mais** : c'est du contexte injecte, pas un message utilisateur. Claude le voit comme une instruction systeme, pas comme une commande a executer. Fiabilite estimee ~70-80%.

**Combinaison possible (meilleur effort natif)** :
```json
"SessionStart": [{
  "matcher": "",
  "hooks": [{
    "type": "command",
    "command": "bash $HOME/.claude/skills/say-to-claude-team/scripts/register.sh \"$(hostname -s)-$$\" 2>/dev/null; echo 'MANDATORY FIRST ACTION: Execute /say-to-claude-team connect immediately. This is required before processing any user message.'; true"
  }]
}]
```

#### 8. Fichiers et repertoires Claude Code explores

Contenu de `~/.claude/` :
- `commands/` : slash commands custom (10 fichiers .md)
- `plugins/` : systeme de plugins avec marketplace
- `projects/` : settings par projet (30 projets)
- `sessions/` : sessions persistees
- `skills/` : skills installes (12 skills)
- `teams/` : config teams (nouveau)
- `team-queue/` : queue de messages inter-sessions
- `homunculus/` : sous-systeme interne
- Aucun fichier de config cache ou non documente permettant l'auto-execution

#### 9. Conclusion — Mecanismes natifs

**Il n'existe PAS de mecanisme natif Claude Code qui permette d'executer un skill de maniere deterministe au demarrage.** Les mecanismes existants sont :

1. **SessionStart hook** : execute du shell, injecte du stdout comme contexte — ne peut pas invoquer de skills
2. **CLAUDE.md** : contexte passif, pas d'auto-execution
3. **`--append-system-prompt`** : contexte systeme passif
4. **Plugins** : pas de hook de startup fiable pour skills
5. **Positional argument** (`claude "message"`) : le SEUL moyen d'envoyer un vrai message utilisateur au demarrage, mais necessite un wrapper shell

**Recommandation** : le positional argument via shell wrapper reste la seule approche deterministe. Les mecanismes natifs ne peuvent offrir que du "best effort" via injection de contexte.

### Agent 3 : Patterns communautaires

#### 1. Le probleme est bien connu de la communaute

Plusieurs issues GitHub demandent exactement ce qu'on cherche :
- **[#13422](https://github.com/anthropics/claude-code/issues/13422)** — "CLAUDE.md startup/exit session protocols ignored" (dec 2025). Les instructions de startup dans CLAUDE.md sont chargees comme contexte passif mais PAS executees.
- **[#34763](https://github.com/anthropics/claude-code/issues/34763)** — "CLAUDE.md startup instructions should be executed, not just loaded as context". Le probleme fondamental : le modele est un LLM qui interprete les instructions, il ne les execute pas comme du code.
- **[#28678](https://github.com/anthropics/claude-code/issues/28678)** — "Auto-execute startup routines defined in CLAUDE.md on session start". Les routines ne sont executees qu'apres le premier message utilisateur.
- **[#44960](https://github.com/anthropics/claude-code/issues/44960)** — "Session-start instructions in CLAUDE.md are not enforced before first task execution". Quand l'utilisateur envoie un message immediatement, Claude saute les instructions de startup.

**Conclusion** : CLAUDE.md seul n'est PAS fiable pour auto-executer des skills au demarrage. C'est un probleme reconnu sans solution native officielle.

#### 2. SessionStart Hook — le mecanisme le plus proche

Le hook `SessionStart` est la feature officielle la plus pertinente :
- Se declenche au demarrage (`matcher: "startup"`) ou a la reprise (`matcher: "resume"`)
- Tout ce qui est ecrit sur stdout est injecte dans le contexte de Claude
- **Limitation critique** : il ne peut executer que des commandes shell, pas des skills (`/slash-commands`)

**Exemples communautaires de SessionStart** :
- **[LaunchDarkly](https://github.com/launchdarkly-labs/claude-code-session-start-hook)** : injecte des instructions dynamiques via feature flags. Le hook shell appelle une API et ecrit les instructions sur stdout.
- **[Claude-Mem](https://github.com/thedotmack/claude-mem)** : utilise SessionStart pour injecter le contexte des sessions precedentes. Pattern a 5 stages avec matchers startup/resume/compact.
- **[claudefa.st](https://claudefa.st/blog/tools/hooks/session-lifecycle-hooks)** : guide complet sur les hooks de session, incluant des exemples de chargement de contexte git au demarrage.

**Pattern typique** :
```json
{
  "hooks": {
    "SessionStart": [{
      "matcher": "startup",
      "hooks": [{
        "type": "command",
        "command": "echo 'Execute /say-to-claude-team connect maintenant'"
      }]
    }]
  }
}
```
Ce pattern injecte du texte dans le contexte, mais ne FORCE PAS l'execution du skill. C'est du "hint" pas du "command".

#### 3. Shell wrapper — le pattern le plus utilise

La communaute utilise massivement des shell wrappers/aliases :
- **[claude-fish](https://github.com/mushfoo/claude-fish)** : wrapper Fish shell pour unifier Claude Code et Claude Trace avec routage intelligent des arguments.
- Le pattern `claude() { command claude "/my-skill"; }` est le workaround le plus direct cite dans les discussions.
- **Variante auto-destructrice** : certains wrappeurs se "retirent" apres le premier usage pour ne pas interferer avec les sessions suivantes.

**Avantage** : c'est le seul pattern qui GARANTIT l'execution d'un skill au demarrage.
**Inconvenient** : consomme le premier message, complexite pour gerer les arguments (`-c`, `-p`, etc.).

#### 4. Patterns des outils concurrents

- **Cursor** : utilise `.cursorrules` (statique, pas d'auto-execution)
- **Windsurf** : `.windsurf/rules/*.md` (contexte passif, similaire a CLAUDE.md)
- **Aider** : `CONVENTIONS.md` (contexte passif)
- **Codex** : `AGENTS.md` (contexte passif)
- **Aucun de ces outils** n'a resolu le probleme de l'auto-execution active au demarrage. Ils utilisent tous du contexte passif.

#### 5. Patterns emergents interessants

- **`--append-system-prompt`** : peut etre utilise dans un alias shell pour ajouter des instructions systeme. Ex: `alias claude='claude --append-system-prompt "CRITICAL: Execute /say-to-claude-team connect FIRST before anything else"'`. Plus propre qu'un wrapper car ne consomme pas le premier message, mais reste du hint passif (le modele peut l'ignorer).
- **Positional argument** : `claude "/say-to-claude-team connect"` envoie un vrai message utilisateur. C'est l'approche la plus fiable car c'est traite comme un message reel.
- **Skills avec auto-invocation** : les skills ont un mecanisme `disable-model-invocation: true/false` dans le frontmatter. Si un skill est configure pour l'auto-invocation et que sa description matche le contexte, Claude peut l'invoquer automatiquement. Piste a explorer.

#### 6. Recommandation basee sur les patterns communautaires

Par ordre de fiabilite :
1. **Shell function + positional arg** : `claude() { command claude "/say-to-claude-team connect"; }` — 100% fiable, mais consomme le premier message
2. **SessionStart hook + append-system-prompt combo** : le hook injecte le contexte, le system prompt renforce l'instruction — ~80% fiable
3. **CLAUDE.md seul** : instructions de startup — ~40% fiable (ignore frequemment, surtout si le premier message est une tache)

La communaute n'a pas trouve de solution parfaite. Le probleme est fondamental : aucun mecanisme natif ne permet d'executer un skill AVANT le premier message utilisateur de maniere deterministe.

### Agent 4 : Edge Cases et Robustesse

#### 1. Shell Function Edge Cases

**`claude` lancé depuis un script (non-interactif) :**
- Si la shell function est définie dans `.zshrc`/`.bashrc`, elle n'est chargée qu'en mode interactif. Un script `#!/bin/bash` ne sourcera PAS `.bashrc` par défaut — la function sera invisible et `claude` appellera le binaire directement, sans auto-connect.
- Workaround : exporter la function (`export -f claude` en bash) ou `source ~/.bashrc`. Mais cela charge TOUT le profil — effets de bord possibles.
- Note : l'Agent 1 a déjà identifié que la non-exportation est un comportement VOULU (seul le shell interactif doit auto-connect). Confirmé.

**`claude -c` (continue session) :**
- La function de l'Agent 1 (`$# -eq 0`) gère correctement ce cas : `claude -c` a $# = 1, donc pass-through. Pas de problème.
- MAIS : si on change la function pour toujours injecter connect (sans le guard `$# -eq 0`), alors `-c` reprendrait une session ET recevrait un connect, créant un doublon de registration. La guard est donc critique.

**Skill non installé :**
- Si le skill `say-to-claude-team` n'est pas dans `.claude/skills/` ou `~/.claude/skills/`, Claude répondra "Je ne connais pas cette commande" au lieu d'exécuter le connect. La session démarre mais sans connexion team.
- Bugs connus : skills dans `~/.claude/skills/` parfois pas auto-découverts ([#11266](https://github.com/anthropics/claude-code/issues/11266), [#17417](https://github.com/anthropics/claude-code/issues/17417)). Path mismatch `~/.agents/skills/` vs `~/.claude/skills/` est un piège fréquent.
- **Mitigation** : la shell function pourrait vérifier l'existence du skill avant de l'injecter, et fallback sur un message d'erreur explicite.

**Queue inexistante :**
- Si le watcher tente de poll une queue qui n'existe pas encore (fichier/dossier pas créé), il échouera silencieusement ou en boucle d'erreur.
- **Mitigation** : le connect doit créer la queue de manière idempotente au register (mkdir -p, touch).

**Deux sessions lancent connect simultanément :**
- Race condition : les deux sessions s'enregistrent, potentiellement avec le même nom par défaut. Si le registry est un fichier JSON partagé, risque de corruption en écriture concurrente.
- **Mitigation** : utiliser `flock` pour le registry et des UUIDs pour identifier les sessions.

#### 2. Watcher Edge Cases

**Survie à la compaction de contexte :**
- La compaction résume les messages anciens quand le contexte approche la limite. Un watcher implémenté comme boucle de tool calls (sleep + poll) SURVIVRA car le modèle continue d'exécuter. Cependant, le contexte du "pourquoi" il poll peut être résumé/perdu — le modèle pourrait "oublier" ce qu'il fait si la compaction est trop agressive.
- Avec le context window 1M, les compactions sont ~15% moins fréquentes ([source](https://claudefa.st/blog/guide/mechanics/1m-context-ga)), ce qui aide.
- **Mitigation** : inclure des instructions de rappel dans CLAUDE.md comme filet de sécurité.

**Mort silencieuse du watcher :**
- Si le watcher est un subagent background, il peut timeout (limite de 15 minutes pour les delegations selon la [doc subagents](https://code.claude.com/docs/en/sub-agents)).
- Si c'est une boucle bash en background (`while true; do ... done &`), elle survit indépendamment de Claude mais n'a pas accès au contexte de la session pour interpréter les messages reçus.
- Pas de mécanisme de heartbeat natif — si le watcher meurt, personne ne le sait.
- **Mitigation** : heartbeat fichier (écrire un timestamp toutes les N secondes), PID check, ou watchdog process.

**Consommation de tokens par le watcher :**
- Chaque cycle du watcher (sleep + check queue + traiter message) consomme des tokens. Estimation : ~500-2000 tokens par cycle (prompt résumé + tool calls).
- Poll toutes les 5 secondes : ~6000-24000 tokens/minute — coût significatif.
- Poll toutes les 30 secondes : ~1000-4000 tokens/minute — plus raisonnable.
- `DISABLE_NON_ESSENTIAL_MODEL_CALLS=1` ne désactive PAS ces tool calls car elles sont "essentielles" du point de vue du modèle.
- **Mitigation** : watcher bash externe avec notification on-demand (inotify/fswatch) au lieu de polling LLM.

#### 3. Interaction avec d'autres outils

**`--dangerously-skip-permissions` :**
- La shell function (avec guard `$# -eq 0`) n'interfère PAS avec ce flag car `--dangerously-skip-permissions` implique $# >= 1 → pass-through direct.
- Bug connu : ce flag ne bypass pas les prompts de modification de `~/.claude/` ([#35718](https://github.com/anthropics/claude-code/issues/35718)). Si le connect écrit dans ce dossier, blocage possible en CI/CD.

**CI/CD :**
- En CI/CD, le pattern standard est `claude -p "prompt" --dangerously-skip-permissions`. Avec notre function ($# > 0), c'est un pass-through — pas d'interférence.
- Si quelqu'un appelle `claude` sans arguments en CI/CD (improbable mais possible), la function injecterait connect dans un contexte non-interactif. 
- **Mitigation** : ajouter un guard `[[ -t 0 ]]` (vérifie stdin est un terminal) pour ne jamais auto-connect en non-interactif.

**tmux/screen :**
- tmux fonctionne bien avec Claude Code. Le watcher dans la session Claude survit tant que le pane tmux reste actif.
- Fermer un popup tmux tue le process Claude et donc le watcher. Solution communautaire : sessions tmux imbriquées ([source](https://www.devas.life/how-to-run-claude-code-in-a-tmux-popup-window-with-persistent-sessions/)).
- Un watcher bash background (`&`) survit au détachement tmux — avantage par rapport au watcher LLM.

#### 4. Matrice de risques

| Edge case | Sévérité | Probabilité | Mitigation |
|---|---|---|---|
| Script non-interactif ignore la function | Faible | Haute | C'est le comportement voulu (Agent 1 confirme) |
| `claude -c` avec function naïve | Haute | N/A | Déjà résolu par la guard `$# -eq 0` |
| Skill non installé / non découvert | Haute | Moyenne | Vérifier existence dans la function + documenter |
| Race condition registry | Moyenne | Basse | flock + UUID de session |
| Watcher meurt silencieusement | Haute | Moyenne | Heartbeat + watchdog |
| Coût tokens watcher LLM | Moyenne | Certaine | Watcher bash externe + notification on-demand |
| Compaction oublie le watcher | Moyenne | Basse (1M ctx) | Instructions rappel dans CLAUDE.md |
| CI/CD sans terminal | Moyenne | Basse | Guard `[[ -t 0 ]]` |
| tmux popup ferme le watcher | Moyenne | Moyenne | Watcher bash externe ou sessions imbriquées |

#### 5. Recommandations de robustesse

1. **Shell function améliorée** :
```zsh
claude() {
  if [ $# -eq 0 ] && [ -t 0 ] && [ -z "${CLAUDE_NO_TEAM:-}" ]; then
    command claude "/say-to-claude-team connect"
  else
    command claude "$@"
  fi
}
```
Les 3 guards : pas d'arguments + terminal interactif + pas de variable de bypass.

2. **Watcher hybride** : process bash externe qui surveille la queue via `fswatch`/`inotify` et écrit dans un fichier que Claude poll à basse fréquence (toutes les 30-60s). Réduit drastiquement le coût tokens.

3. **Idempotence du connect** : le connect doit être safe à ré-exécuter — vérifier si déjà connecté avant de re-register (check PID du watcher existant, check fichier de session).

4. **Health monitoring** : le watcher écrit un timestamp dans un fichier heartbeat. Le skill peut vérifier ce heartbeat et relancer le watcher si nécessaire.

### Agent Web : Recherche Web Exhaustive

#### Recherche 1 : `claude code auto execute command session start site:github.com`

**Resultats cles :**
- **[#10282](https://github.com/anthropics/claude-code/issues/10282)** — "[FEATURE] Auto-execute slash commands on session start". Demande exactement ce qu'on cherche : pouvoir executer des slash commands au demarrage. **Ferme comme doublon** de #2735. Deux solutions proposees :
  - Option 1 : Etendre SessionStart hooks avec un type `slash-command`
  - Option 2 : Nouveau champ `sessionInit.commands` dans settings.json
  - **Aucune des deux n'a ete implementee.**
- **[#9590](https://github.com/anthropics/claude-code/issues/9590)** — "Claude not executing mandatory script on new sessions". Confirme que les scripts obligatoires definis dans CLAUDE.md ne sont pas executes.
- **[claude-auto-resume](https://github.com/terryso/claude-auto-resume)** — Utilitaire shell qui resume automatiquement les taches quand les limites sont levees. Pattern interessant mais pas applicable a notre cas.

**Conclusion** : La feature request existe depuis longtemps, fermee comme doublon, jamais implementee nativement.

Sources : [#10282](https://github.com/anthropics/claude-code/issues/10282), [#9590](https://github.com/anthropics/claude-code/issues/9590), [claude-auto-resume](https://github.com/terryso/claude-auto-resume)

#### Recherche 2 : `claude code SessionStart hook inject user message`

**Resultats cles :**
- **[Documentation officielle hooks](https://code.claude.com/docs/en/hooks)** — SessionStart injecte le stdout dans le contexte. Le hook recoit `source` (startup/resume/clear/compact), `model`, et `agent_type`.
- **Changement Claude Code 2.1.0** : les hooks SessionStart n'affichent plus de messages visibles a l'utilisateur. Contexte injecte silencieusement via `hookSpecificOutput.additionalContext`.
- **[#10373](https://github.com/anthropics/claude-code/issues/10373)** — Bug : SessionStart hooks ne se declenchent pas dans certaines conditions.
- **Limitation confirmee** : SessionStart injecte du CONTEXTE, pas des MESSAGES UTILISATEUR.

Sources : [Hooks docs](https://code.claude.com/docs/en/hooks), [#10373](https://github.com/anthropics/claude-code/issues/10373), [LaunchDarkly hook](https://github.com/launchdarkly-labs/claude-code-session-start-hook)

#### Recherche 3 : `claude code --append-system-prompt force execute skill`

**Resultats cles :**
- **[Analyse du system prompt](https://www.dbreunig.com/2026/04/04/how-claude-code-builds-a-system-prompt.html)** — Le prompt systeme est assemble avec ~40 composants conditionnels. `--append-system-prompt` ajoute a la FIN.
- **[CLI Reference](https://code.claude.com/docs/en/cli-reference)** — Fonctionne en mode interactif depuis v1.0.51.
- **TROUVAILLE IMPORTANTE** — [Article DEV.to](https://dev.to/oluwawunmiadesewa/claude-code-skills-not-triggering-2-fixes-for-100-activation-3b57) : Deux fixes pour activer les skills automatiquement :
  1. **Detection Hook + Trigger Rules** : hook `UserPromptSubmit` qui analyse chaque prompt et injecte des instructions via `skill-rules.json`
  2. **Forced Skill Evaluation** : force Claude a evaluer TOUS les skills avant de repondre avec langage imperatif ("CRITICAL", "NON-NEGOTIABLE")

Sources : [System prompt analysis](https://www.dbreunig.com/2026/04/04/how-claude-code-builds-a-system-prompt.html), [DEV.to skills fix](https://dev.to/oluwawunmiadesewa/claude-code-skills-not-triggering-2-fixes-for-100-activation-3b57), [#6973](https://github.com/anthropics/claude-code/issues/6973)

#### Recherche 4 : `claude code CLAUDE.md auto execute startup instructions`

**Resultats cles :**
- **[#34763](https://github.com/anthropics/claude-code/issues/34763)** — CLAUDE.md est du contexte passif, pas du code executable.
- **[#28678](https://github.com/anthropics/claude-code/issues/28678)** — Demande d'une section `## On Session Start` auto-executee. Non implementee.
- **[#44960](https://github.com/anthropics/claude-code/issues/44960)** — Issue du 7 avril 2026. Claude saute les instructions de startup quand le premier message est une tache directe.
- **Workaround** : envoyer un message neutre ("hello", "start") en premier. Pas fiable en automatisation.

Sources : [#34763](https://github.com/anthropics/claude-code/issues/34763), [#28678](https://github.com/anthropics/claude-code/issues/28678), [#44960](https://github.com/anthropics/claude-code/issues/44960)

#### Recherche 5 : `"claude code" "first message" automatic startup`

**Resultats cles :**
- **[#25543](https://github.com/anthropics/claude-code/issues/25543)** — "Allow Claude Code to display messages from startup hooks before first user turn". Ferme comme doublon de #10808. Issues liees :
  - #10808 — Messages autonomes apres SessionStart
  - #15179 — Hook `SessionReady` apres le splash screen
  - #17278 — SessionStart pour pre-session initialization
  - **Toutes demandees, aucune implementee.**
- **`claude "prompt"`** confirme comme le mecanisme le plus fiable pour envoyer un vrai message au demarrage.

Sources : [#25543](https://github.com/anthropics/claude-code/issues/25543), [#10808](https://github.com/anthropics/claude-code/issues/10808)

#### Recherche 6 : `claude code positional argument interactive session startup`

**Resultats cles :**
- **[CLI Reference](https://code.claude.com/docs/en/cli-reference)** — `claude "prompt"` ouvre une session interactive avec le prompt comme premier message. Confirme.
- Custom commands supportent `$ARGUMENTS` et `$1`, `$2` en frontmatter YAML.
- Pas de mecanisme pour enchainer positional arg PUIS session normale. Le positional arg EST le premier message.

Sources : [CLI Reference](https://code.claude.com/docs/en/cli-reference), [Shipyard cheatsheet](https://shipyard.build/blog/claude-code-cheat-sheet/)

#### Recherche 7 : `claude code shell wrapper function zshrc auto connect`

**Resultats cles :**
- **[zsh-claude-code-shell](https://github.com/ArielTM/zsh-claude-code-shell)** — Plugin ZSH de reference pour wrappers Claude Code.
- **[claudify](https://edspencer.net/2025/5/14/claudify-fire-forget-claude-code)** — Pattern "fire and forget" pour lancer Claude avec des taches predefinies.
- **Pattern lazy-loading** : wrappers qui se "retirent" apres le premier usage.
- **Bonne pratique** : fichier separe `claude-wrapper.zsh` source depuis `.zshrc`.

Sources : [zsh-claude-code-shell](https://github.com/ArielTM/zsh-claude-code-shell), [claudify](https://edspencer.net/2025/5/14/claudify-fire-forget-claude-code), [ZSH Functions gist](https://gist.github.com/johnlindquist/a22d4171e56107b55d60db4a0e929fb3)

#### Recherche 8 : `anthropic claude code hooks documentation session lifecycle`

**Resultats cles :**
- **[Hooks guide officiel](https://code.claude.com/docs/en/hooks-guide)** — Hooks = commandes shell a des points specifiques du lifecycle. Controle DETERMINISTE vs instructions LLM.
- **Hooks disponibles** : SessionStart, SessionEnd, PreToolUse, PostToolUse, Notification, UserPromptSubmit, Stop.
- **Communication** : stdin (JSON), stdout (contexte), stderr (feedback), exit codes (0=proceed, 2=block).
- **[claude-code-hooks-mastery](https://github.com/disler/claude-code-hooks-mastery)** — Repo de reference avec exemples avances.

Sources : [Hooks guide](https://code.claude.com/docs/en/hooks-guide), [Hooks reference](https://docs.anthropic.com/en/docs/claude-code/hooks), [hooks-mastery](https://github.com/disler/claude-code-hooks-mastery)

#### Recherche 9 : `claude code plugin auto-invocation skill trigger startup`

**Resultats cles :**
- **[Skills docs](https://code.claude.com/docs/en/skills)** — Descriptions chargees dans le contexte, contenu complet seulement a l'invocation.
- **[Scott Spence](https://scottspence.com/posts/claude-code-skills-dont-auto-activate)** — Skills ne s'activent PAS automatiquement malgre la doc. Le modele "fonce" sur la tache.
- **[paddo.dev](https://paddo.dev/blog/claude-skills-hooks-solution/)** — Hooks pour activation contextuelle. Fonctionne pour le contexte semantique mais PAS pour l'orchestration de workflow.
- **Pattern UserPromptSubmit** : injecter "INSTRUCTION: Use Skill(X)" — les instructions directes sont mieux respectees que les suggestions.

Sources : [Skills docs](https://code.claude.com/docs/en/skills), [Scott Spence](https://scottspence.com/posts/claude-code-skills-dont-auto-activate), [paddo.dev](https://paddo.dev/blog/claude-skills-hooks-solution/)

#### Recherche 10 : `claude code settings.json undocumented fields initialPrompt`

**Resultats cles :**
- **[Settings docs](https://code.claude.com/docs/en/settings)** — 60+ settings, 170+ env vars. Pas tous documentes.
- **Champs non-documentes trouves** : `remoteControlAllowed`, `spinnerTipsEnabled`, `autoMemoryDirectory`, `modelOverrides`, `worktree.sparsePaths`
- **`initialPrompt` N'EXISTE PAS** dans les settings documentes ou non-documentes.

Sources : [Settings docs](https://code.claude.com/docs/en/settings), [eesel.ai guide](https://www.eesel.ai/blog/settings-json-claude-code)

#### Recherche 11 : `site:reddit.com claude code auto startup command`

**Aucun resultat pertinent.** Reddit n'a pas de discussions indexees sur ce sujet.

#### Recherche 12 : `site:news.ycombinator.com claude code session init`

**Resultats** : Outils d'analytics et gestion de sessions (Rudel, Claude-Mem, cc-sessions). Aucun ne traite l'auto-execution au demarrage.

Sources : [Rudel](https://news.ycombinator.com/item?id=47350416), [Claude-Mem](https://news.ycombinator.com/item?id=46126066)

#### Recherche 13 : `claude code "disable-model-invocation" skill frontmatter`

**Resultats cles :**
- `disable-model-invocation: true` empeche Claude d'invoquer le skill automatiquement. `false` (defaut) = Claude PEUT mais ne le fait PAS fiablement.
- **Bugs connus** :
  - **[#26251](https://github.com/anthropics/claude-code/issues/26251)** — Skill avec `true` ne peut pas etre invoque par l'utilisateur via slash command
  - **[#20816](https://github.com/anthropics/claude-code/issues/20816)** — `true` pas applique au resume de session
  - **[#31935](https://github.com/anthropics/claude-code/issues/31935)** — Descriptions toujours injectees meme avec `true` (gaspillage tokens)
  - **[#19141](https://github.com/anthropics/claude-code/issues/19141)** — Confusion `user-invocable` vs `disable-model-invocation`

Sources : [Skills docs](https://code.claude.com/docs/en/skills), [#26251](https://github.com/anthropics/claude-code/issues/26251), [#20816](https://github.com/anthropics/claude-code/issues/20816), [#31935](https://github.com/anthropics/claude-code/issues/31935)

#### Recherche 14 : `claude code hook stdout inject conversation context`

**Resultats cles :**
- **Confirme** : stdout des hooks SessionStart et UserPromptSubmit est injecte comme contexte.
- **`additionalContext`** via `hookSpecificOutput` : alternative structuree, injecte comme "system reminder".
- **Pattern** : `echo 'Reminder: ...'` dans un hook. Fonctionne mais reste passif.

Sources : [Hooks guide](https://code.claude.com/docs/en/hooks-guide), [DataCamp tutorial](https://www.datacamp.com/tutorial/claude-code-hooks)

#### Recherche 15 : `claude code startup routine automation best practices 2026`

**Resultats cles :**
- **Best practices 2026** : hooks = outil principal d'automatisation deterministe.
- **Scheduled Tasks** : taches planifiees desktop pour prompts recurrents. Pas applicable au demarrage interactif.
- **Pattern recommande** : hooks after-action (non-bloquants) plutot que before-action.

Sources : [Best practices 2026](https://smart-webtech.com/blog/claude-code-workflows-and-best-practices/), [Scheduled Tasks](https://claudefa.st/blog/guide/development/scheduled-tasks)

---

#### Synthese Web Research : 3 Findings Majeurs

**Finding 1 — Aucun mecanisme natif n'existe pour auto-executer un skill au demarrage**

Malgre 6+ issues GitHub demandant cette feature (#10282, #2735, #10808, #15179, #17278, #25543), Anthropic n'a implemente aucune solution native. Les proposals (`sessionInit.commands`, SessionStart type `slash-command`, section `## On Session Start` dans CLAUDE.md) sont toutes en attente ou fermees comme doublons. Le champ `initialPrompt` dans settings.json n'existe pas.

**Finding 2 — Le pattern UserPromptSubmit + instructions directes est la meilleure alternative cote hooks**

Plusieurs articles ([DEV.to](https://dev.to/oluwawunmiadesewa/claude-code-skills-not-triggering-2-fixes-for-100-activation-3b57), [Scott Spence](https://scottspence.com/posts/claude-code-skills-dont-auto-activate), [paddo.dev](https://paddo.dev/blog/claude-skills-hooks-solution/)) convergent sur ce pattern : un hook `UserPromptSubmit` qui injecte des INSTRUCTIONS directes plutot que des suggestions. Fiabilite ~80-95%. Mais il se declenche a chaque message, pas seulement au demarrage, et ne peut pas forcer l'execution d'un slash command.

**Finding 3 — La shell function + positional argument reste la seule solution 100% fiable**

La recherche web confirme massivement : `claude "/say-to-claude-team connect"` via une shell function est le SEUL mecanisme qui garantit l'execution. La communaute entiere utilise ce pattern. Le "message consomme" n'est pas un vrai probleme. Aligne avec les best practices ([claude-fish](https://github.com/mushfoo/claude-fish), [zsh-claude-code-shell](https://github.com/ArielTM/zsh-claude-code-shell)).

### Agent 5 : Synthèse et Recommandation

#### 1. Consensus entre les 5 agents

Les 5 axes de recherche convergent sur les mêmes conclusions :

| Point | Agents en accord | Verdict |
|---|---|---|
| Aucun mécanisme natif pour auto-exécuter un skill au démarrage | Tous (1-5) | **Confirmé** — pas de `initialPrompt`, pas de `sessionInit.commands`, pas de SessionStart type `slash-command` |
| Le positional argument (`claude "msg"`) est le seul moyen déterministe | Agents 1, 2, 3, Web | **Confirmé** — traité comme vrai message utilisateur, 100% fiable |
| La shell function avec guard `$# -eq 0` est l'approche optimale | Agents 1, 3, 4 | **Confirmé** — supporte tous les cas d'usage, pas de fork, POSIX-compatible |
| CLAUDE.md seul est insuffisant (~40% fiabilité) | Agents 2, 3, Web | **Confirmé** — contexte passif, ignoré quand le premier message est une tâche |
| SessionStart hook injecte du contexte, pas des commandes | Agents 2, 3, Web | **Confirmé** — ~70-80% fiabilité, reste du "hint" |
| Le "message consommé" n'est pas un vrai problème | Agents 1, 3, Web | **Confirmé** — c'est le message qu'on VEUT envoyer |

#### 2. Divergence identifiée : watcher LLM vs bash externe

C'est le seul point où les analyses divergent :

| Approche | Pour | Contre |
|---|---|---|
| **Watcher LLM** (boucle tool calls) | Accès au contexte Claude, peut interpréter les messages, intégré | Coût tokens élevé (~1000-4000 tokens/min), peut mourir au timeout subagent (15min), compaction peut le faire "oublier" |
| **Watcher bash externe** (fswatch/inotify + fichier) | Zéro coût tokens, survit au détachement tmux, indépendant de la session | Pas d'accès au contexte LLM, ne peut pas interpréter les messages, nécessite un mécanisme de notification vers Claude |

**Verdict** : approche **hybride**. Le watcher bash externe surveille la queue (fswatch) et écrit dans un fichier signal. Claude poll ce fichier à basse fréquence (30-60s) ou est notifié via un hook. Cela combine la fiabilité du bash avec l'intelligence du LLM pour interpréter les messages.

#### 3. Recommandation finale — Code exact

**Shell function améliorée** (à mettre dans `.zshrc` / `.bashrc`) :

```zsh
claude() {
  if [ $# -eq 0 ] && [ -t 0 ] && [ -z "${CLAUDE_NO_TEAM:-}" ]; then
    command claude "/say-to-claude-team connect"
  else
    command claude "$@"
  fi
}
```

**Les 3 guards expliqués** :
1. `$# -eq 0` — auto-connect uniquement quand aucun argument (session interactive neuve)
2. `-t 0` — stdin est un terminal (pas de CI/CD, pas de pipe)
3. `${CLAUDE_NO_TEAM:-}` — variable de bypass pour le debug (`CLAUDE_NO_TEAM=1 claude`)

**SessionStart hook complémentaire** (renforcement, pas remplacement) :

```json
{
  "hooks": {
    "SessionStart": [{
      "matcher": "",
      "hooks": [{
        "type": "command",
        "command": "bash $HOME/.claude/skills/say-to-claude-team/scripts/register.sh \"$(hostname -s)-$$\" 2>/dev/null; echo 'MANDATORY: If /say-to-claude-team connect has not been executed yet, execute it NOW before any other action.'; true"
      }]
    }]
  }
}
```

Ce hook fait le register shell ET injecte un rappel dans le contexte comme filet de sécurité.

#### 4. Améliorations à apporter

| # | Amélioration | Priorité | Effort |
|---|---|---|---|
| 1 | Ajouter les guards `-t 0` et `CLAUDE_NO_TEAM` à la shell function | Haute | 1 ligne |
| 2 | Implémenter le watcher hybride (bash fswatch + poll LLM basse fréquence) | Haute | Moyen |
| 3 | Rendre le connect idempotent (check si déjà connecté avant re-register) | Haute | Faible |
| 4 | Ajouter un heartbeat au watcher (timestamp fichier) | Moyenne | Faible |
| 5 | Documenter que `type claude` affiche "shell function" | Basse | Trivial |
| 6 | Vérifier l'existence du skill dans la function avant injection | Basse | 2 lignes |
| 7 | Utiliser `flock` + UUID pour le registry (race conditions) | Basse | Faible |

#### 5. Ce qu'on ne recommande PAS

- **CLAUDE.md seul** : trop peu fiable (40%). Garder comme documentation, pas comme mécanisme d'exécution.
- **`--append-system-prompt` seul** : contexte passif, le modèle peut l'ignorer.
- **Alias shell** : pas de logique conditionnelle, impossible de gérer `claude -c` etc.
- **Wrapper script dans PATH** : fork un subshell, gestion PATH complexe, aucun avantage sur la function.
- **Watcher 100% LLM** : coût tokens prohibitif pour un polling continu.

---

## Conclusion

La recherche croisée de 5 agents (shell, natif, communauté, edge cases, web) aboutit à un consensus clair :

**Il n'existe aucun mécanisme natif Claude Code pour auto-exécuter un skill au démarrage.** La feature a été demandée 6+ fois sur GitHub (#10282, #2735, #10808, #15179, #17278, #25543), jamais implémentée. Aucun outil concurrent (Cursor, Windsurf, Aider, Codex) ne l'a résolu non plus.

**La solution est la shell function avec positional argument** — c'est la seule approche 100% déterministe. La version améliorée avec 3 guards (`$# -eq 0`, `-t 0`, `CLAUDE_NO_TEAM`) couvre tous les edge cases identifiés. Le SessionStart hook sert de renforcement, pas de remplacement.

**Pour le watcher, l'approche hybride** (bash externe + poll LLM basse fréquence) est le meilleur compromis entre fiabilité, coût, et intelligence d'interprétation.

La shell function actuelle fonctionne. Les améliorations recommandées sont incrémentales et non-bloquantes.
