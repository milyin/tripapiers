# tripapiers — traitement des fichiers

> **Composant obligatoire.** Ce document décrit le pipeline de classement lui-même :
> `INBOX → DATE → STRUCTURE`, avec `QUARANTAINE` comme sortie d'échec. L'audit indépendant du
> corpus fait l'objet d'un document et d'un composant séparés, **optionnels** : voir
> [`verification.md`](verification.md).

---

## 1. Contexte et objectif

`hermes-documents` ne contient que de la documentation : `architecture.md`, `README.md`,
`.CONFIG/category.yml`, `.CONFIG/structure.yml`. Le pipeline y est décrit mais son code
d'exécution vit dans Hermes Agent, couplé à Google Drive et à un agent LLM qui pilote
l'ensemble du classement.

`tripapiers` reprend ce pipeline comme **application autonome, locale et prédictible** :

| Axe | `hermes-documents` (actuel) | `tripapiers` (cible) |
|---|---|---|
| Exécution | Hermes Agent + tâches cron | binaire Rust, CLI |
| Stockage | Google Drive (`INBOX`/`DATE`/`STRUCTURE`) | système de fichiers local |
| Vue logique | dossiers + raccourcis Drive | dossiers + liens symboliques |
| Rôle du LLM | analyse complète, lecture native → OCR → vision | **étiqueter un texte** et **ré-océriser** — rien d'autre |
| Sortie du LLM | analyse JSON structurée | **une liste de tags, un par ligne** |
| Échec | document laissé `blocked` dans `INBOX` | document déplacé en `QUARANTAINE` avec son dossier de preuve |
| Suppression | corbeille Drive | `.TRASH/` local réversible |
| Exclusion mutuelle | verrou interprocessus maison + ledger | `flock` sur un fichier de verrou unique |
| Vérification | intégrée au pipeline | **composant séparé et optionnel** |

**Hors périmètre :** toute prise en charge de Google Drive (API, OAuth, raccourcis Drive,
tâches cron distantes). Le pipeline devient un outil en ligne de commande invoqué
manuellement ou par un timer local (systemd/cron de l'utilisateur).

---

## 2. Ce que « prédictible » signifie ici (décision d'architecture centrale)

Un appel LLM n'est pas reproductible bit à bit : sur `claude-opus-5` les paramètres
d'échantillonnage (`temperature`, `top_p`, `top_k`) sont **refusés par l'API** (erreur 400),
donc il n'existe même pas de levier « temperature = 0 ». La prédictibilité est donc obtenue
par l'architecture, pas par le modèle :

1. **Le LLM ne produit jamais d'artefact canonique.** Il ne sérialise pas le YAML, ne calcule
   aucun checksum, ne dérive aucun chemin, ne crée ni ne déplace aucun fichier. Il rend
   uniquement du texte : soit **une liste de tags**, soit **une transcription** (§5).
2. **La sortie n'est pas contrainte à l'émission ; elle est jugée en local.** Le code Rust lit
   la réponse ligne par ligne, **ignore silencieusement toute ligne non conforme**, puis
   applique des règles d'évaluation déclarées dans `.CONFIG` (§6). Aucune valeur n'est devinée :
   ce qui ne passe pas l'évaluation escalade, puis part en quarantaine.
3. **Escalade bornée.** Au plus une reprise par OCR vision, donc **au plus trois appels LLM par
   document**. Le pipeline termine toujours, sur l'un de deux états : classé ou en quarantaine.
4. **Cache de verdicts adressé par contenu.** Chaque réponse LLM est mémorisée sous la clé
   `sha256(octets du document) + type d'appel + sha256(prompt rendu) + id_modèle`. Le prompt
   étant engendré déterministiquement depuis `.CONFIG` (§3), toute modification du vocabulaire
   invalide le cache automatiquement. Une seconde exécution sur le même corpus est alors
   **déterministe et gratuite**, et le banc de tests tourne hors ligne par rejeu du cache.
5. **Un seul document par transaction**, verrou exclusif, journal de rollback : l'état du
   dépôt après interruption est toujours l'un de deux états connus (avant / après), jamais
   un état intermédiaire.
6. **Contrôle en ligne après écriture, non désactivable.** À la fin de chaque transaction, le
   pipeline relit depuis le disque le document et son sidecar fraîchement écrits et recontrôle
   checksum, chemin dérivé et conformité du sidecar. Ce contrôle fait partie de la transaction :
   il échoue fermé et déclenche le rollback. Il est **indépendant du composant optionnel** de
   vérification, qui apporte autre chose — un audit exhaustif du corpus, réimplémenté
   séparément (cf. [`verification.md`](verification.md) §2).

**Pourquoi des lignes de tags plutôt qu'un JSON contraint.** Les *structured outputs*
(`output_config.format`) garantissent un JSON valide, mais en tout ou rien : une troncature
(`stop_reason: max_tokens`) ou un refus ne laisse **aucune** information exploitable. Une sortie
en lignes se dégrade proprement — les N premières lignes restent lisibles, et l'étape
d'évaluation décide si c'est suffisant. La contrepartie est que le format n'est plus garanti par
l'API : toute la validation revient au code Rust. C'est précisément l'intention, et cela
concentre le jugement au seul endroit qui soit déterministe et testable.

> **Effet de bord utile :** un analyseur qui ignore les lignes non conformes est naturellement
> immunisé contre les fuites de balises internes du modèle, la prose d'introduction (« Voici
> les tags : »), les puces et la numérotation. Ces lignes tombent d'elles-mêmes.

---

## 3. Vocabulaire de tags

### 3.1 Grammaire

Un tag est une suite de segments séparés par des deux-points :

```
tag       := segment (":" segment)+          # au moins deux segments
segment    := caractères autorisés, non vide
namespace  := premier segment
rôle       := deuxième segment, si l'espace de noms en déclare
valeur     := le reste
```

Exemples valides, tels que demandés :

```
confiance:haute
titre:facture-electricite-mars
date:prin:2024-03-17
date:aux:2024-02-28
nom:prin:DUPONT_Marie
nom:aux:DUPONT_Paul
cat:sante:ordonnance
cat:logement:diagnostic:dpe
```

Les tags hiérarchiques sont **permis et recommandés** : le chemin va du plus général au plus
précis. Normalisation avant validation : `trim`, suppression d'un `:` final, aucune autre
transformation — en particulier **pas** de passage en minuscules global, puisque `nom:` porte
des majuscules signifiantes. Les règles de casse et de jeu de caractères sont déclarées par
espace de noms.

Bornes dures, non configurables : au plus 6 segments, au plus 200 octets par tag, au plus 200
tags retenus par document. Au-delà, la ligne est ignorée comme non conforme.

### 3.2 `.CONFIG/tags.yml` — le catalogue *est* le prompt

Chaque espace de noms déclare sa description, et cette description **est** le fragment de prompt
envoyé au modèle. Le prompt n'est jamais écrit à la main dans le code Rust : il est engendré par
concaténation déterministe, dans l'ordre de déclaration.

```yaml
schema_version: 1
namespaces:
  - name: confiance
    prompt: >-
      Ton niveau de confiance global dans l'étiquetage de ce document.
      Émets exactement une ligne.
    cardinality: { min: 1, max: 1 }
    values: [haute, moyenne, basse]        # vocabulaire fermé et ordonné

  - name: titre
    prompt: >-
      Un titre court et descriptif, en minuscules sans accents, mots séparés par
      des tirets. Exemple : titre:facture-electricite-mars
    cardinality: { min: 1, max: 1 }
    value_pattern: '^[a-z0-9][a-z0-9-]{0,60}$'

  - name: date
    prompt: >-
      Chaque date portée par le document, au format AAAA-MM-JJ. La date qui
      caractérise le document porte le rôle prin, les autres aux.
      Exemple : date:prin:2024-03-17
    roles: [prin, aux]
    cardinality: { min: 1, max: 12 }
    value_pattern: '^\d{4}-\d{2}-\d{2}$'

  - name: nom
    prompt: >-
      Chaque personne physique concernée, au format NOM_Prenom. La personne dont
      le document traite en premier lieu porte le rôle prin, les autres aux.
      Exemple : nom:prin:DUPONT_Marie
    roles: [prin, aux]
    cardinality: { min: 1, max: 8 }
    catalogue: persons.yml                 # optionnel — cf. §11 point 3

  - name: cat
    prompt: >-
      Chaque catégorie du document. Les catégories sont hiérarchiques : émets le
      chemin complet, du plus général au plus précis. Exemple : cat:sante:ordonnance
    cardinality: { min: 1, max: 4 }
    catalogue: category.yml
    hierarchical: true
```

### 3.3 Continuité avec `category.yml`

`category.yml` a déjà exactement cette forme — une entrée y est un `name: cat:<valeur>` assorti
d'une `description` qui est une consigne d'attribution (« Attribuer aux relevés, moyens de
paiement… »). C'est déjà « un tag avec son prompt » ; `tags.yml` ne fait que généraliser le
procédé aux autres espaces de noms. Le fichier est donc conservé tel quel comme vocabulaire du
seul espace `cat:`.

**Conséquence à trancher (§11 point 1) :** le catalogue actuel encode déjà une hiérarchie, mais
*en prose*. `cat:medecine` est décrite comme « catégorie générale », tandis que
`cat:consultation`, `cat:honoraires`, `cat:analyse`, `cat:ordonnance` et `cat:vaccination` sont
décrites comme « sous-type médical pour… ». Le format hiérarchique rend cette structure
explicite — `cat:medecine:ordonnance` plutôt que `cat:ordonnance` plus une phrase. La migration
est mécanique et améliore aussi la vue `STRUCTURE` (§8), mais elle change les tags de tous les
sidecars existants : c'est une décision, pas un détail.

---

## 4. La chaîne de traitement

```
        ┌──────────────────────┐
        │ 1. OCR locale        │  pdftotext / tesseract        déterministe
        └──────────┬───────────┘
                   │ texte + métriques de qualité
                   │
        ┌──────────v───────────┐
   ┌───>│ 2. appel LLM « tag » │  catalogue + texte -> lignes  1 appel
   │    └──────────┬───────────┘
   │               │ lignes conformes retenues, autres ignorées
   │               │
   │    ┌──────────v───────────┐
   │    │ 3. évaluation        │  règles de .CONFIG            déterministe
   │    └───┬──────────────┬───┘
   │        │ accepté      │ échec
   │        │              │
   │        │        ┌─────v──────────────────┐
   │        │        │ escalade déjà faite ?  │
   │        │        └───┬────────────────┬───┘
   │        │        non │                │ oui
   │        │  ┌─────────v────────────┐   │
   └────────┼──┤ 4. appel LLM vision  │   │            1 appel
     5.     │  │    (ré-OCR)          │   │
            │  └──────────────────────┘   │
            v                             v
     ┌────────────┐              ┌─────────────────┐
     │  DATE/     │              │  6. QUARANTAINE/ │
     └────────────┘              └─────────────────┘
```

Deux raccourcis déterministes, décidés sans appel LLM :

- **OCR locale vide ou manifestement inexploitable** (§7, portail de métriques) ⇒ on saute
  l'étape 2 et on part directement en vision. L'escalade est alors considérée comme consommée :
  un échec d'évaluation après ce chemin mène droit en quarantaine.
- **Document illisible par les outils locaux** (PDF corrompu, format non pris en charge) ⇒
  quarantaine immédiate, aucun appel LLM.

**Borne :** au plus trois appels LLM par document — `tag`, `vision`, `tag`. Le compteur est
inscrit dans le ledger et l'invariant est testé (§10.14).

---

## 5. Contrat LLM

Rust n'a pas de SDK Anthropic officiel : appels **HTTP bruts** via `reqwest` sur
`POST https://api.anthropic.com/v1/messages`, en-têtes `x-api-key` et
`anthropic-version: 2023-06-01`.

Modèle : **`claude-opus-5`** ($5 / $25 par million de tokens entrée/sortie, fenêtre 1 M,
vision haute résolution jusqu'à 2576 px sur le grand côté). Le modèle est un paramètre de
configuration et fait partie de la clé de cache : le changer invalide les verdicts, par
conception.

Deux types d'appel, et rien d'autre :

| Appel | Rôle | Entrée | Sortie attendue | `effort` |
|---|---|---|---|---|
| `tag` | étiqueter un texte | catalogue rendu (§3.2) + texte | une liste de tags, un par ligne | `low` |
| `vision` | ré-océriser un document | pages rasterisées en PNG | la transcription, texte brut | `medium` |

**L'appel `tag` est identique quelle que soit l'origine du texte** — OCR locale ou transcription
vision. Le prompt est donc invariant sur tout le corpus et sur les deux passes : son préfixe est
mis en cache une seule fois.

### 5.1 Appel `tag`

Prompt système = préambule figé + catalogue rendu depuis `.CONFIG` + consignes de format :

```
Tu reçois le texte d'un document. Émets la liste des tags que ce texte porte.

FORMAT DE SORTIE — impératif :
- une ligne = un tag, rien d'autre
- aucune prose, aucune puce, aucune numérotation, aucun bloc de code
- n'émets un tag que si le texte le justifie ; n'invente aucune valeur
- si tu hésites sur une valeur, ne l'émets pas et baisse confiance:

TAGS DISPONIBLES :
<rendu déterministe de tags.yml, catalogues inclus>
```

Corps de requête :

```json
{
  "model": "claude-opus-5",
  "max_tokens": 4000,
  "thinking": { "type": "adaptive" },
  "output_config": { "effort": "low" },
  "system": [ { "type": "text", "text": "<préambule + catalogue rendu>",
                "cache_control": { "type": "ephemeral" } } ],
  "messages": [ { "role": "user", "content": [ { "type": "text", "text": "<texte OCR>" } ] } ]
}
```

Pas de `output_config.format` : la sortie est du texte libre, jugée en local.

`max_tokens` reste généreux (4000) bien que la sortie utile fasse ~80 tokens, parce que la
réflexion adaptative est active par défaut sur `claude-opus-5` et que `max_tokens` plafonne
**réflexion + texte**. Un plafond serré tronquerait la réponse. Variante d'économie possible :
`thinking: {"type":"disabled"}` avec `effort: "low"` — accepté jusqu'à `effort: high`, et le
mode de défaillance associé (fuite de balises internes dans la réponse) est ici inoffensif
puisque l'analyseur ignore ces lignes. À mesurer avant d'adopter.

### 5.2 Analyse de la réponse

```rust
fn parse_tags(raw: &str, vocab: &TagVocabulary) -> TagParse
```

Pour chaque ligne : `trim`, ignorer si vide ; refuser si elle ne respecte pas la grammaire
(§3.1), si l'espace de noms est inconnu, si le rôle n'est pas déclaré, si la valeur ne passe pas
le `value_pattern`, ou si elle dépasse les bornes dures. Toute ligne refusée est **comptée et
journalisée avec son motif**, jamais réparée ni devinée.

`TagParse` porte : les tags retenus (dédupliqués, ordre stable), les lignes rejetées avec motif,
et le ratio `rejetées / total`. Ce ratio est lui-même une règle d'évaluation (§6) : une réponse
majoritairement non conforme signale un problème de prompt ou de modèle, pas un document
difficile.

### 5.3 Appel `vision`

Pages rasterisées à 300 dpi en PNG, envoyées en blocs `image` base64 (ou le PDF en bloc
`document` quand il est petit et propre). Prompt : transcrire fidèlement, sans commenter, sans
résumer, en conservant l'ordre de lecture. La sortie est la transcription brute, reprise telle
quelle comme entrée de l'appel `tag` suivant et stockée dans le sidecar.

Coût dominant du pipeline : jusqu'à ~4784 tokens d'entrée par page en haute résolution. Le
portail déterministe (§7) existe pour ne déclencher cet appel que quand il est nécessaire ;
limiter le nombre de pages envoyées (`--max-pages`, défaut 10, au-delà quarantaine) borne le
coût par document.

### 5.4 Robustesse des appels

- **Refus.** `claude-opus-5` peut renvoyer un **HTTP 200** avec `stop_reason: "refusal"` et un
  `stop_details.category`. Tester `stop_reason` *avant* de lire `content`. Un refus sur `tag`
  compte comme un échec d'évaluation (donc escalade, puis quarantaine) ; un refus sur `vision`
  mène directement en quarantaine. Activer le repli serveur (`fallbacks: "default"`, en-tête
  beta `server-side-fallback-2026-07-01`) et **journaliser le modèle réellement servi**
  (`response.model`) dans l'entrée de cache — un repli change le producteur du verdict.
- **`max_tokens`** : sortie tronquée. Sur `tag`, les lignes complètes reçues restent
  exploitables et l'évaluation tranche — c'est tout l'intérêt du format ligne. Sur `vision`,
  une transcription tronquée est un échec.
- **`model_context_window_exceeded`** : document trop volumineux ⇒ découpage par pages ou
  quarantaine.
- **Erreurs HTTP** : 429 avec `retry-after`, 5xx/529 avec backoff exponentiel borné, 400/404 non
  réessayables. Une erreur non résolue laisse le document `pending` — **jamais** en quarantaine :
  la quarantaine est réservée aux échecs d'évaluation constatés, pas aux pannes d'infrastructure.
- **Mode lot.** API Batches (`POST /v1/messages/batches`, ≤ 24 h, **‑50 %**) pour la passe `tag`
  du premier tour, qui est homogène et non interactive ; résultats indexés par `custom_id`
  (= `sha256` du document). Les escalades repassent en appels unitaires.
- **Préflight coût.** `POST /v1/messages/count_tokens` sur un échantillon avant un gros corpus ;
  ne jamais estimer les tokens avec un tokeniseur tiers.
- **Cache de prompt.** Vérifier `usage.cache_read_input_tokens` non nul dès le second document ;
  s'il reste à zéro, un invalidateur silencieux traîne dans le préfixe. Minimum câchable sur
  `claude-opus-5` : **512 tokens** — le catalogue rendu le dépasse largement.
- **Mode hors-ligne.** `--no-llm` s'arrête après l'OCR locale et laisse les documents `pending`.
- **Prérequis d'identification :** exporter `ANTHROPIC_API_KEY`, ou installer la CLI `ant` et
  faire `ant auth login`. Les profils OAuth de `ant` sont lus automatiquement par les SDK
  officiels, mais pas par un client HTTP maison : dans ce cas, récupérer un jeton éphémère via
  `ant auth print-credentials --access-token` et l'envoyer en en-têtes `Authorization: Bearer`
  et `anthropic-beta: oauth-2025-04-20` (et non `x-api-key`). Aucune information
  d'identification n'est jamais écrite dans le dépôt ni dans les sidecars.

### 5.5 Ordre de grandeur de coût

Le format ligne réduit fortement la sortie facturée : l'appel `tag` rend une douzaine de lignes,
là où l'ancienne analyse JSON rendait aussi la transcription.

| Scénario | Entrée / doc | Sortie / doc | 1000 documents |
|---|---|---|---|
| `tag` seul, prompt en cache | ~3 k | ~80 | ≈ 17 $ — ≈ 9 $ en API Batches |
| escalade `vision` + `tag`, 3 pages | ~17 k | ~2 k | ≈ 24 $ pour 150 documents (15 %) |

À confirmer par `count_tokens` sur le corpus réel.

---

## 6. Évaluation des tags (étape 3)

Entièrement déterministe, entièrement configurable, aucun appel réseau. C'est le point de
décision du pipeline.

`.CONFIG/evaluation.yml` :

```yaml
schema_version: 1

required:
  - { namespace: titre,               min: 1, max: 1 }
  - { namespace: date, role: prin,    min: 1, max: 1 }
  - { namespace: nom,  role: prin,    min: 1, max: 1 }
  - { namespace: cat,                 min: 1 }

confidence:
  namespace: confiance
  minimum: moyenne              # ordre pris dans tags.yml : haute > moyenne > basse

unknown_values:                 # valeur hors catalogue
  cat: reject                   # reject | propose | accept
  nom: propose

parse_quality:
  max_rejected_ratio: 0.5       # au-delà, réponse jugée non exploitable

on_failure:
  first_attempt:  escalate      # -> appel vision, puis retour en 2
  second_attempt: quarantine
```

Verdict :

```rust
enum Verdict {
    Accepted { tags: TagSet },
    Escalate { reasons: Vec<RuleFailure> },
    Quarantine { reasons: Vec<RuleFailure> },
}
```

Chaque `RuleFailure` porte `{ règle, attendu, obtenu }` — jamais un simple booléen : c'est ce
qui remplit le rapport de quarantaine et le rend actionnable.

`unknown_values: propose` alimente le mécanisme de propositions taxonomiques (§9) : la valeur
inconnue est enregistrée avec sa preuve documentaire, mais **n'est jamais** promue en tag ni
écrite dans un catalogue automatiquement.

Le fichier `evaluation.yml` est une autorité de configuration au même titre que les autres :
jamais écrit par le programme, et son empreinte fait partie de l'état qui déclenche une
reconstruction (§8).

---

## 7. OCR locale (étape 1, déterministe)

Outils vérifiés présents sur la machine de développement : `pdftotext` 26.01, `pdftoppm`,
`pdfinfo`, `pdfimages`, `pdftocairo`, `ghostscript`, `ocrmypdf`, `tesseract` 5.5 avec
`eng`/`fra`/`rus`/`osd`.

1. `pdfinfo` — nombre de pages, métadonnées, validité. PDF illisible ⇒ quarantaine immédiate.
2. `pdftotext -layout -enc UTF-8` — couche texte native si elle existe.
3. Sinon `pdftoppm -r 300 -png`, puis `tesseract -l fra+eng --psm 3` avec
   `tessedit_create_tsv=1` pour récupérer la confiance par mot. Images d'entrée : directement
   `tesseract`.
4. **Métriques de qualité** — le portail qui évite un appel vision inutile *et* un appel `tag`
   voué à l'échec : caractères par page, proportion alphanumérique, taux de mots reconnus dans
   une liste fr/en embarquée, confiance tesseract moyenne et médiane, nombre de `U+FFFD`.
   Seuils dans `.CONFIG`, versionnés.
5. Décision : texte exploitable ⇒ étape 2 ; manifestement inexploitable ⇒ saut direct en
   vision (escalade consommée) ; rien du tout et pas de page rasterisable ⇒ quarantaine.

Les binaires externes sont invoqués avec des arguments figés, timeout, et un enregistrement de
leur version dans le ledger : une mise à jour de tesseract change les résultats, c'est une
donnée de reproductibilité.

---

## 8. Organisation du code et du dépôt

### 8.1 Espace de travail Cargo

```text
tripapiers/
├── Cargo.toml                  # workspace
├── crates/
│   ├── core/        # grammaire des tags, contrat YAML, checksum, dérivation de chemin
│   ├── config/      # tags.yml, category.yml, evaluation.yml, structure.yml + rendu du prompt
│   ├── extract/     # OCR locale : pdftotext, pdftoppm, tesseract, métriques de qualité
│   ├── llm/         # client Claude (HTTP), appels tag et vision, analyseur de lignes, cache
│   ├── eval/        # moteur d'évaluation des tags, verdicts
│   ├── store/       # opérations fichiers atomiques, journal, rollback, .TRASH, QUARANTAINE
│   ├── pipeline/    # machine à états de l'escalade, transactions, registre, verrou, ledger
│   ├── cli/         # binaire `tripapiers`
│   └── verify/      # OPTIONNEL — voir verification.md
├── doc/
└── tests/fixtures/  # corpus de test (PDF propres, scans bruités, réponses LLM pathologiques)
```

`core`, `config` et `eval` ne dépendent d'aucun I/O réseau et d'aucun processus externe : ce
sont les crates testables de façon exhaustive et le siège des invariants. `eval` en particulier
n'a aucune dépendance sur `llm` — il juge une liste de tags déjà analysée, d'où qu'elle vienne,
ce qui le rend testable par table de décision sans jamais simuler d'appel réseau.

**Le crate `verify` est en dehors de la chaîne de dépendances du pipeline.** `pipeline` ne
dépend pas de `verify` ; `verify` dépend de `core` et `config` en lecture seule. Retirer
`verify` du workspace doit laisser `cargo build -p tripapiers-cli` intact.

### 8.2 Arborescence locale

Racine du dépôt documentaire, configurable (`--root`, `TRIPAPIERS_ROOT`) :

```text
<root>/
├── INBOX/                      # dépôt manuel des documents à classer
├── DATE/                       # archive physique canonique
│   └── YYYY/MM/DD/
│       ├── NOM_Prenom_Titre.ext
│       └── NOM_Prenom_Titre.yml
├── STRUCTURE/                  # vue logique : dossiers + liens symboliques uniquement
├── QUARANTAINE/                 # échecs d'évaluation, avec dossier de preuve
├── .CONFIG/
│   ├── tags.yml                # espaces de noms + prompts  (nouveau)
│   ├── category.yml            # vocabulaire de l'espace cat:
│   ├── evaluation.yml          # règles d'acceptation      (nouveau)
│   └── structure.yml           # plan déclaratif de la vue logique
└── .TRASH/                     # suppressions réversibles, horodatées
```

État durable hors dépôt, sous `$XDG_STATE_HOME/tripapiers/` (défaut `~/.local/state/tripapiers/`) :

```text
inbox_batch.json              # registre durable du lot (pending/classified/quarantined)
structure_state.json          # état de reconstruction incrémentale
tag_proposals.json            # valeurs hors catalogue, idempotentes
llm_cache/                    # verdicts LLM adressés par contenu
executions.db                 # ledger SQLite des exécutions
tripapiers.lock               # verrou d'exclusion unique (flock)
journal/                      # journaux de transaction pour rollback
```

Différences assumées avec Drive : raccourcis → **liens symboliques relatifs** ; corbeille →
`.TRASH/<horodatage>/<chemin-relatif-original>` plus une commande `restore`, aucun `unlink`
direct dans le code métier ; identifiant stable de source → `sha256` du contenu, qui sert aussi
de détection de doublon.

### 8.3 Contrat YAML du sidecar

```yaml
schema_version: 2
source:
  original_name: "scan_2024_03.pdf"
  sha256: "…"
ocr:
  provenance: local | vision        # d'où vient la transcription
  engine: "tesseract 5.5.0 / fra+eng"   # ou l'id de modèle pour vision
  escalated: false
tags:
  - cat:sante:ordonnance
  - confiance:haute
  - date:prin:2024-03-17
  - nom:prin:DUPONT_Marie
  - titre:ordonnance-dr-martin
destination:
  primary_path: DATE/2024/03/17
transcription: |
  …
checksum: "sha256:<empreinte>"
```

Changements par rapport au contrat d'origine : `schema_version: 2` ; la liste `tags` est
**la** représentation des métadonnées (les anciens blocs `dates:` et la liste de personnes en
sont des vues dérivées, calculées à la lecture, pas stockées deux fois) ; ajout du bloc `ocr`
pour tracer la provenance de la transcription. La liste de tags est triée par ordre
lexicographique stable, ce qui rend le sidecar canonique.

**Sérialisation canonique écrite à la main**, pas par un sérialiseur générique : ordre des clés
fixe, guillemets explicites, LF uniquement, pas d'ancres ni d'alias, indentation constante, pas
de repli de lignes. L'octet-à-octet du sidecar est fonction pure des tags validés — c'est ce qui
rend la vérification indépendante possible. La lecture passe par un parseur YAML classique
(`serde_norway` ou `serde_yaml_ng`, `serde_yaml` étant abandonné en amont).

`build_sidecar(tags, ocr, document_bytes) -> Result<Sidecar>` valide, calcule le SHA-256 sur les
octets réels, dérive `DATE/YYYY/MM/DD` depuis `date:prin:`, et sérialise. La fonction miroir
`verify_sidecar` appartient au composant optionnel ([`verification.md`](verification.md) §3).

### 8.4 DSL de `structure.yml` face aux tags hiérarchiques

La configuration existante :

```yaml
- nom:
    - cat:medecine:
        - an:
            - cat
    - cat:gouvernement:
        - cat
    - cat
```

Grammaire (inférée d'un seul exemple, à confirmer — §11 point 2) :

| Forme | Sémantique |
|---|---|
| chaîne nue `cat`, `an`, `nom` | **éventail** : un dossier par valeur distincte de cet espace de noms |
| clé de mapping `nom:` | éventail, puis récursion dans les enfants |
| clé de mapping `cat:medecine:` | **filtre** : documents portant ce tag ; dossier nommé d'après la valeur ; puis récursion |
| frères dans une même liste | **alternatives** : le document est placé dans chaque branche qui correspond |

Les tags hiérarchiques ajoutent deux règles, qui n'existaient pas et qu'il faut trancher :

- **Éventail sur un espace hiérarchique** : `cat` appliqué à `cat:sante:ordonnance` crée-t-il
  l'arborescence imbriquée `sante/ordonnance`, ou un dossier plat `sante-ordonnance` ?
  *Proposition : arborescence imbriquée* — c'est le comportement attendu et il rend la vue plus
  navigable.
- **Filtre sur un préfixe** : `cat:sante:` filtre-t-il tout tag dont le chemin **commence** par
  `sante` (donc `cat:sante:ordonnance`) ? *Proposition : oui, correspondance par segments*, pas
  par sous-chaîne — `cat:sante:` ne doit pas capturer un hypothétique `cat:santeanimale`.

Avec les rôles, `nom:` doit aussi préciser s'il éventaille sur toutes les personnes ou sur les
seules `nom:prin:`. *Proposition : `nom` éventaille sur `prin` uniquement ; `nom:aux:` reste
disponible comme filtre explicite* — sinon chaque document apparaît sous toutes les personnes
qu'il mentionne.

`structure.yml` n'est **jamais** écrit par le programme.

---

## 9. Quarantaine

Un document qui échoue l'évaluation après escalade est **déplacé**, jamais supprimé, jamais
classé partiellement, jamais laissé à pourrir dans `INBOX`.

```text
QUARANTAINE/
└── 2024-03-17T14-22-05Z__a1b2c3d4/
    ├── scan_2024_03.pdf         # le document, intact
    ├── rapport.yml              # pourquoi il est là
    ├── ocr-locale.txt
    ├── ocr-vision.txt           # si l'escalade a eu lieu
    ├── tags-passe-1.txt         # sortie brute du modèle, telle quelle
    └── tags-passe-2.txt
```

`rapport.yml` : verdict, liste des `RuleFailure` avec attendu/obtenu, tags retenus, lignes
rejetées avec motif, ratio de rejet, provenance OCR, id de modèle réellement servi, empreinte du
prompt, horodatages, coût. Les sorties brutes du modèle sont conservées telles quelles : c'est
la matière première pour corriger un prompt ou un seuil.

Contraintes :

- `QUARANTAINE` ne contient **jamais** de sidecar canonique `.yml` conforme au contrat §8.3 —
  `rapport.yml` porte un `schema_version` distinct — afin qu'aucun outil ne puisse confondre une
  entrée de quarantaine avec un document classé.
- `tripapiers requeue <entrée>` remet le document dans `INBOX`, remet son état à `pending` et
  archive l'entrée de quarantaine dans `.TRASH/`. C'est le chemin de reprise après correction du
  vocabulaire, des seuils ou du prompt.
- `tripapiers quarantaine list [--reason <règle>]` groupe les entrées par règle en défaut :
  c'est le signal qui dit quel réglage corriger, et c'est le premier écran à regarder après un
  gros lot.

---

## 10. Invariants

1. un seul document par transaction de classement ;
2. un document physique vit dans `DATE`, jamais dans `STRUCTURE` ;
3. chaque document classé a un sidecar YAML adjacent, valide et checksummé ;
4. les fichiers de `.CONFIG` sont les seules autorités de configuration, jamais écrits par le
   programme ;
5. le LLM ne rend que du texte : des lignes de tags, ou une transcription. Il ne sérialise aucun
   YAML et ne touche pas au système de fichiers ;
6. aucun dossier `CATEGORY` n'est créé ;
7. aucune commande mutative concurrente (verrou unique) ;
8. une erreur de verrou, de journal, de ledger ou de contrôle en ligne provoque un échec fermé ;
9. les suppressions passent par `.TRASH/`, jamais `unlink` direct ;
10. aucun rapport intermédiaire pendant le traitement d'un lot ; un seul rapport final ;
11. `STRUCTURE` est intégralement reproductible depuis `DATE` + `.CONFIG` ;
12. les inventaires sont bornés au parent exact, sans suivre les liens symboliques ;
13. tout verdict LLM est mémorisé et rejouable hors ligne ;
14. **l'escalade est bornée** : au plus une reprise vision, au plus trois appels LLM par document ;
15. **aucune ligne non conforme n'est réparée** : elle est ignorée, comptée et journalisée ;
16. **un échec d'évaluation déplace le document en `QUARANTAINE`**, avec son dossier de preuve ;
     une panne d'infrastructure, elle, le laisse `pending` ;
17. **le prompt est engendré depuis `.CONFIG`**, jamais écrit en dur dans le code Rust.

Le pipeline **maintient** ces invariants. Le composant optionnel les **contrôle** de façon
indépendante ; la correspondance invariant → contrôle est en
[`verification.md`](verification.md) §6.

---

## 11. Points à trancher

1. **Migration du catalogue vers des catégories hiérarchiques** (§3.3). Le catalogue actuel
   encode déjà une hiérarchie en prose (« catégorie générale » / « sous-type médical pour… »).
   La rendre structurelle — `cat:medecine:ordonnance` — améliore l'étiquetage et la vue
   `STRUCTURE`, mais change les tags de tous les sidecars existants.
2. **DSL et tags hiérarchiques** (§8.4) : imbrication à l'éventail, correspondance par segments
   au filtre, et comportement de `nom` vis-à-vis des rôles `prin`/`aux`. Trois propositions y
   sont faites, aucune n'est confirmée.
3. **Catalogue des personnes.** Un `.CONFIG/persons.yml` autoritaire rend `nom:` vérifiable et
   évite les variantes orthographiques (`DUPONT_Marie` / `Dupont_Marie`). Sans lui, l'espace
   `nom:` reste ouvert et `unknown_values: propose` est le seul garde-fou. Recommandé.
4. **Encodage de la confiance.** `confiance:haute|moyenne|basse` est proposé — robuste et
   directement évaluable. Une confiance *par espace de noms* (`confiance:cat:haute`) serait plus
   fine et permettrait d'escalader sur la seule catégorie douteuse ; elle complique le prompt et
   les règles. À arbitrer.
5. **Langues d'OCR** : `fra+eng` par défaut ; `rus` est installé — à activer ou non.
6. **Types d'entrée** : PDF et images au départ. Formats bureautiques (`.docx`, `.odt`) hors
   périmètre initial — à confirmer.

---

## 12. Phases de développement

Chaque phase est livrable et testable seule. Les phases 0 à 3 ne nécessitent **aucune clé
d'API**. Les phases du composant optionnel sont numérotées séparément (V1…V3) dans
[`verification.md`](verification.md) §8 et peuvent être menées en parallèle à partir de la
phase 1.

### Phase 0 — Squelette et configuration
- Workspace Cargo, `clap`, `tracing`, `anyhow`/`thiserror`, CI (`fmt`, `clippy -D warnings`, `test`).
- `crates/config` : chargement et validation de `tags.yml`, `category.yml`, `evaluation.yml`,
  `structure.yml`. Contrôles croisés : tout `catalogue:` référencé existe, tout espace de noms
  cité par `evaluation.yml` est déclaré dans `tags.yml`, les niveaux de `confidence.minimum`
  appartiennent aux `values` déclarées.
- **Rendu déterministe du prompt** depuis le catalogue, avec son empreinte.
- Parseur du DSL `structure.yml` + `StructurePlan`.
- **Recette :** tests dorés sur les fichiers de configuration réels et sur le prompt rendu
  (instantané `insta` : toute évolution du prompt devient visible en revue) ; cas d'erreur de
  configuration ; `tripapiers config check` sort 0/non-0.

### Phase 1 — Grammaire des tags, analyseur, évaluation
- Grammaire (§3.1), normalisation, bornes dures.
- `parse_tags` (§5.2) avec motifs de rejet typés.
- Moteur d'évaluation (§6) et `Verdict`.
- `build_sidecar` (§8.3), émetteur YAML canonique, SHA-256.
- **Recette :** tests de propriété (round-trip tags ⇄ sidecar, stabilité octet-à-octet,
  idempotence) ; **corpus de réponses LLM pathologiques** — prose d'introduction, puces,
  numérotation, blocs de code, balises internes, tags tronqués en fin de flux, espaces de noms
  inconnus, doublons, casse inattendue, ligne de 10 ko — chacune doit être ignorée sans panique
  et comptée au bon motif ; table de décision complète du moteur d'évaluation.

### Phase 2 — Stockage local, transactions et quarantaine
- `crates/store` : inventaire `INBOX` borné, écriture atomique, `rename`, `.TRASH` + `restore`,
  journal de rollback.
- `QUARANTAINE` : mise en quarantaine avec dossier de preuve (§9), `requeue`, `quarantaine list`.
- `crates/pipeline` : verrou `flock`, ledger SQLite, registre de lot, machine à états de
  l'escalade (§4) avec son compteur d'appels, contrôle en ligne après écriture, rapport final
  unique.
- Analyse injectée (trait `Tagger`) : **le pipeline complet fonctionne sans LLM**.
- **Recette :** injection de panne à chaque étape ⇒ aucun état intermédiaire observable ; test
  de concurrence ; « aucun rapport avant état terminal du lot » ; « sidecar corrompu entre
  écriture et relecture ⇒ transaction annulée » ; **« l'escalade ne se produit qu'une fois »** ;
  aller-retour `quarantaine` → `requeue` → classement réussi après correction des seuils.

### Phase 3 — OCR locale
- Enveloppes `pdfinfo` / `pdftotext` / `pdftoppm` / `tesseract` : arguments figés, timeouts,
  capture de version.
- Métriques de qualité et portail déterministe (§7).
- Générateur de corpus : PDF à texte natif, scan propre, scan bruité/incliné, scan illisible,
  image seule, PDF corrompu, PDF vide, PDF de 200 pages.
- **Recette :** décision attendue du portail pour chaque fixture (étape 2 / saut en vision /
  quarantaine immédiate), non-régression sur les métriques, aucun appel réseau.

### Phase 4 — Adaptateur LLM
- Client `reqwest` (rustls), appels `tag` et `vision` (§5), cache adressé par contenu, rejeu.
- Gestion de `stop_reason`, chaîne d'erreurs HTTP, backoff, repli serveur, comptabilité de coût
  et du nombre d'appels par document dans le ledger.
- `--batch`, `count-tokens` préflight, `--no-llm`.
- **Recette :** serveur HTTP simulé couvrant refus, 429, 5xx, réponse vide, réponse tronquée en
  milieu de ligne, réponse 100 % non conforme ; rejeu du cache ; **un** test `#[ignore]` frappant
  la vraie API ; contrôle que la distinction « panne ⇒ `pending` » / « évaluation ⇒
  `QUARANTAINE` » est respectée dans chaque cas.

### Phase 5 — Reconstruction de `STRUCTURE`
- Planification depuis les sidecars valides de `DATE` + `StructurePlan`, avec les règles
  hiérarchiques du §8.4.
- Modes `noop` / `incremental` / `full`. Incrémental : créer avant de retirer, annuler les
  mutations partielles, n'enregistrer l'état qu'après succès. Complet : construction dans
  `.STRUCTURE.staging/`, vérification des liens et de leurs cibles, bascule par `rename`,
  ancienne vue vers `.TRASH/`.
- Déclencheurs de reconstruction complète : empreinte modifiée de n'importe quel fichier de
  `.CONFIG`, état local incompatible, `--force`, anomalie d'intégrité.
- **Recette :** propriété centrale — une `STRUCTURE` reconstruite à neuf est **identique** à
  celle obtenue par une suite d'incréments ; aucun fichier physique dans `STRUCTURE` ; aucun
  lien pendant ; cas hiérarchiques (`cat:a:b:c`, filtre par préfixe, rôles `nom:`).

### Phase 6 — Rapport, réétiquetage, propositions
- `report` : rapport final unique distinguant classés / mis en quarantaine avec la règle en
  défaut / contrôle qualité / propositions. Les `pending` ne sont jamais présentés comme des
  échecs.
- `retag` : relance l'appel `tag` **sur la transcription déjà stockée** dans les sidecars après
  changement de `tags.yml`, `category.yml` ou `evaluation.yml` ; ne réocérise rien, ne déplace
  aucun document physique, puis déclenche la prise en compte par `STRUCTURE`. Remplace la
  `recategorize` d'origine, et la généralise à tous les espaces de noms.
- `propose list|approve` : valeurs hors catalogue, idempotentes, avec preuve documentaire,
  jamais écrites automatiquement dans un catalogue, jamais promues en tag.

### Phase 7 — Empaquetage et migration
- `README`, page de manuel, unité systemd `--user` + timer (`classify` toutes les 15 min,
  `structure` en décalé) — le verrou unique reste la seule garantie d'exclusion.
- `import` : adoption d'une arborescence `DATE` existante en `schema_version: 1`, avec migration
  des tags plats vers la forme hiérarchique si le point §11.1 est tranché en ce sens. Aucun
  appel LLM.
- Journal des versions de prompt/catalogue/seuils et procédure d'invalidation du cache.
- Deux profils de distribution : avec et sans le composant de vérification
  ([`verification.md`](verification.md) §7).

---

## 13. Dépendances Rust envisagées

| Besoin | Crate |
|---|---|
| CLI | `clap` (derive) |
| HTTP | `reqwest` (`rustls-tls`, `json`) |
| JSON / YAML | `serde`, `serde_json`, `serde_norway` (ou `serde_yaml_ng`) en lecture seule |
| Expressions rationnelles (`value_pattern`) | `regex` |
| Hachage | `sha2`, `hex` |
| Verrou de fichier | `fs2` ou `rustix` (`flock`) |
| Ledger | `rusqlite` (`bundled`) |
| Dates | `jiff` ou `time` |
| Parcours / fichiers temporaires | `walkdir`, `tempfile` |
| Journalisation | `tracing`, `tracing-subscriber` |
| Erreurs | `thiserror` (bibliothèques), `anyhow` (binaire) |
| Tests | `insta`, `proptest`, `assert_cmd`, `assert_fs`, `httpmock` |

---

## 14. Recette du pipeline

Ces tests portent sur le traitement lui-même et **n'utilisent pas** le composant optionnel de
vérification (sa propre recette est en [`verification.md`](verification.md) §9).

1. **Sans réseau** — `cargo test --workspace --exclude tripapiers-verify` : configuration, rendu
   du prompt, grammaire, analyseur de tags, évaluation, transactions, quarantaine, OCR locale,
   adaptateur LLM (serveur simulé + rejeu du cache). Porte de CI du composant obligatoire.
2. **Corpus synthétique** — `tripapiers --root <tmp> classify --all --no-llm`, puis avec un
   `Tagger` injecté : vérifier `DATE`, sidecars, registre, rapport unique.
3. **Chemin d'escalade** — un `Tagger` injecté qui échoue à la passe 1 et réussit à la passe 2 :
   vérifier qu'exactement une escalade a lieu, que `ocr.provenance` vaut `vision` et que
   `ocr.escalated` est vrai dans le sidecar.
4. **Chemin de quarantaine** — un `Tagger` qui échoue aux deux passes : document déplacé, dossier
   de preuve complet, `INBOX` vide, aucun sidecar canonique dans `QUARANTAINE`, `requeue`
   réversible.
5. **Panne ≠ échec d'évaluation** — serveur simulé renvoyant 500 en boucle : le document reste
   `pending`, ne part **pas** en quarantaine.
6. **Reconstruction** — `structure --full`, puis `--incremental` après ajout/retrait, puis
   comparaison à un `--full` neuf : arborescences identiques.
7. **Résistance à l'interruption** — `SIGKILL` à chaque point du journal, puis relance : journal
   non clôturé détecté, rollback rétablissant l'état d'avant transaction.
8. **Concurrence** — deux `classify` simultanés : un seul travaille, l'autre sort proprement avec
   clôture au ledger.
9. **API réelle** — `cargo test -- --ignored` sur un mini-corpus de 5 documents : `stop_reason`,
   `usage.cache_read_input_tokens` non nul dès le second document, conformité des lignes, coût et
   nombre d'appels enregistrés.
10. **Reproductibilité** — deux exécutions complètes sur le même corpus produisent des sidecars
    **identiques octet à octet** (la seconde servie par le cache).
11. **Build sans le composant optionnel** — `cargo build -p tripapiers-cli` après retrait de
    `crates/verify` du workspace : doit compiler et passer les tests 1 à 10.
