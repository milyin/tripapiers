# tripapiers — plan de développement

> Application Rust autonome et locale de tri documentaire, dérivée de la documentation
> de `hermes-documents` (pipeline `INBOX → DATE → STRUCTURE` actuellement orchestré par
> Hermes Agent sur Google Drive).

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
| Rôle du LLM | analyse complète, lecture native → OCR → vision | **uniquement** : évaluation de l'OCR locale, et décodage vision quand l'OCR locale a échoué |
| Suppression | corbeille Drive | `.TRASH/` local réversible |
| Exclusion mutuelle | verrou interprocessus maison + ledger | `flock` sur un fichier de verrou unique |

**Hors périmètre :** toute prise en charge de Google Drive (API, OAuth, raccourcis Drive,
tâches cron distantes). Le pipeline devient un outil en ligne de commande invoqué
manuellement ou par un timer local (systemd/cron de l'utilisateur).

**Invariants conservés depuis `architecture.md` §10** — ils constituent le cahier des
charges de la partie déterministe et sont repris en §4.7.

---

## 2. Ce que « prédictible » signifie ici (décision d'architecture centrale)

Un appel LLM n'est pas reproductible bit à bit : sur `claude-opus-5` les paramètres
d'échantillonnage (`temperature`, `top_p`, `top_k`) sont **refusés par l'API** (erreur 400),
donc il n'existe même pas de levier « temperature = 0 ». La prédictibilité est donc obtenue
par l'architecture, pas par le modèle :

1. **Le LLM ne produit jamais d'artefact canonique.** Il ne sérialise pas le YAML, ne calcule
   aucun checksum, ne dérive aucun chemin, ne crée ni ne déplace aucun fichier. Il renvoie
   uniquement un **JSON d'analyse** conforme à un schéma versionné (cf. §4.4).
2. **Sortie contrainte deux fois.** Contrainte à l'émission par les *structured outputs*
   (`output_config.format` avec `json_schema`), puis re-validée localement contre le schéma
   *et* contre la configuration (catégories existant dans `category.yml`, dates analysables,
   personnes connues). Toute violation ⇒ document `blocked` avec raison vérifiée, jamais de
   valeur devinée.
3. **Cache de verdicts adressé par contenu.** Chaque réponse LLM est mémorisée sous la clé
   `sha256(octets du document) + mode + version_prompt + version_schéma + id_modèle`.
   Une seconde exécution sur le même corpus est alors **déterministe et gratuite**, et le
   banc de tests tourne hors ligne par rejeu du cache.
4. **Un seul document par transaction**, verrou exclusif, journal de rollback : l'état du
   dépôt après interruption est toujours l'un de deux états connus (avant / après), jamais
   un état intermédiaire.
5. **Programme de vérification indépendant** (`tripapiers verify`) qui relit les fichiers
   depuis le disque et recontrôle checksum, chemin dérivé, tags et conformité du sidecar —
   l'équivalent de `verify_drive_document_yaml.py`.

> **Point à valider** — l'énoncé « le LLM ne sert qu'à l'évaluation de l'OCR et au décodage
> en cas d'échec » laisse une question ouverte : *qui attribue les catégories et extrait les
> dates/personnes ?* Le plan retient l'interprétation suivante, à confirmer : **l'étape
> « évaluation du résultat OCR » est aussi l'étape d'extraction** — un unique appel LLM reçoit
> le texte OCR et rend à la fois un verdict de qualité et l'analyse structurée. Le décodage
> vision est le même contrat, avec des images en entrée au lieu du texte. Il y a donc
> exactement **deux points d'entrée LLM et un seul contrat JSON**, et aucun autre appel LLM
> nulle part dans le programme. Si l'intention était que la catégorisation soit purement
> déterministe (règles de mots-clés dérivées de `category.yml`), il faut le dire : cela change
> la phase 4 et supprime le besoin de vision structurée.

---

## 3. Arborescence locale

Racine du dépôt documentaire, configurable (`--root`, `TRIPAPIERS_ROOT`) :

```text
<root>/
├── INBOX/                      # dépôt manuel des documents à classer
├── DATE/                       # archive physique canonique
│   └── YYYY/MM/DD/
│       ├── NOM_Prenom_Titre.ext
│       └── NOM_Prenom_Titre.yml
├── STRUCTURE/                  # vue logique : dossiers + liens symboliques uniquement
├── .CONFIG/
│   ├── category.yml            # repris tel quel de hermes-documents
│   └── structure.yml           # repris tel quel de hermes-documents
└── .TRASH/                     # suppressions réversibles, horodatées
```

État durable hors dépôt, sous `$XDG_STATE_HOME/tripapiers/` (défaut `~/.local/state/tripapiers/`) :

```text
inbox_batch.json              # registre durable du lot (pending/classified/blocked)
structure_state.json          # état de reconstruction incrémentale
category_proposals.json       # propositions taxonomiques, idempotentes
llm_cache/                    # verdicts LLM adressés par contenu
executions.db                 # ledger SQLite des exécutions
tripapiers.lock               # verrou d'exclusion unique (flock)
journal/                      # journaux de transaction pour rollback
```

Différences assumées avec Drive :
- **Raccourcis → liens symboliques relatifs.** `STRUCTURE` ne contient que des dossiers et
  des symlinks vers `DATE`, jamais de fichier physique ni de sidecar.
- **Corbeille → `.TRASH/<horodatage>/<chemin-relatif-original>`**, plus une commande
  `restore`. Aucun `unlink` direct dans le code métier.
- **Identifiant stable de source :** Drive fournissait un `file_id`. Localement,
  l'identifiant est `sha256` du contenu (qui sert aussi de détection de doublon), associé au
  chemin d'origine dans `INBOX`.

---

## 4. Conception

### 4.1 Espace de travail Cargo

```text
tripapiers/
├── Cargo.toml                  # workspace
├── crates/
│   ├── core/        # types du domaine, invariants, contrat YAML, checksum, dérivation
│   ├── config/      # chargement + validation de category.yml / structure.yml, DSL
│   ├── extract/     # extraction locale : pdftotext, pdftoppm, tesseract, métriques
│   ├── llm/         # client Claude (HTTP), schéma JSON, cache, rejeu, comptabilité coût
│   ├── store/       # opérations fichiers atomiques, journal, rollback, trash
│   ├── pipeline/    # transactions, registre de lot, verrou, ledger, rapport
│   └── cli/         # binaire `tripapiers`
├── doc/
└── tests/fixtures/  # corpus de test (PDF propres, scans bruités, images)
```

`core` et `config` ne dépendent d'aucun I/O réseau et d'aucun processus externe : ce sont
les crates testables de façon exhaustive et le siège des invariants.

### 4.2 Contrat YAML du sidecar

Repris de `architecture.md` §5 :

```yaml
schema_version: 1
source:
  original_name: "scan_2024_03.pdf"
  sha256: "…"
dates:
  primary:
    value: "YYYY-MM-DD"
  principal:
    - value: "YYYY-MM-DD"
destination:
  primary_path: DATE/YYYY/MM/DD
tags:
  - nom:NOM_Prenom
  - cat:categorie
transcription: |
  …
checksum: "sha256:<empreinte>"
```

**Sérialisation canonique écrite à la main**, pas par un sérialiseur générique : ordre des
clés fixe, guillemets explicites, LF uniquement, pas d'ancres ni d'alias, indentation
constante, pas de repli de lignes. Objectif : l'octet-à-octet du sidecar est fonction pure de
l'analyse validée. La lecture (config et sidecars) passe par un parseur YAML classique.
`serde_yaml` étant abandonné en amont, prévoir `serde_norway` ou `serde_yaml_ng` pour la
lecture seule.

Deux fonctions publiques miroir des scripts Python d'origine :
- `build_sidecar(analysis, document_bytes) -> Result<Sidecar>` : valide l'analyse, calcule le
  SHA-256 sur les octets réels, dérive `DATE/YYYY/MM/DD`, sérialise de façon stable.
- `verify_sidecar(document_path, sidecar_path, config) -> Report` : relit les deux fichiers
  depuis le disque et recontrôle indépendamment identifiant de source, checksum, date,
  chemin dérivé, tags `nom:`/`cat:` et conformité complète.

### 4.3 DSL de `structure.yml`

La configuration existante est :

```yaml
- nom:
    - cat:medecine:
        - an:
            - cat
    - cat:gouvernement:
        - cat
    - cat
```

Grammaire proposée (à confirmer — elle est **inférée d'un seul exemple**) :

| Forme | Sémantique |
|---|---|
| chaîne nue `cat`, `an`, `nom` | **niveau d'éventail** : un dossier par valeur distincte de cet espace de noms pour le document. Feuille ⇒ le lien symbolique y est créé. |
| clé de mapping `nom:` | éventail sur l'espace de noms, puis récursion dans les enfants |
| clé de mapping `cat:medecine:` | **niveau de filtre** : ne concerne que les documents portant exactement ce tag ; dossier nommé d'après la valeur ; puis récursion |
| frères dans une même liste | **alternatives** : le document est placé dans *chaque* branche qui correspond |

`an` = année, dérivée de la date primaire. Un document médical de `NOM_Prenom` apparaît donc
sous `STRUCTURE/NOM_Prenom/medecine/2024/<cat>/…` **et** sous `STRUCTURE/NOM_Prenom/<cat>/…`.

Livrables : parseur + type `StructurePlan` + tests dorés sur le `structure.yml` réel et sur
une demi-douzaine de variantes construites à la main. `structure.yml` n'est **jamais** écrit
par le programme.

### 4.4 Contrat LLM

Rust n'a pas de SDK Anthropic officiel : appels **HTTP bruts** via `reqwest` sur
`POST https://api.anthropic.com/v1/messages`, en-têtes `x-api-key` et
`anthropic-version: 2023-06-01`.

Modèle : **`claude-opus-5`** ($5 / $25 par million de tokens entrée/sortie, fenêtre 1 M,
vision haute résolution jusqu'à 2576 px sur le grand côté). Le modèle est un paramètre de
configuration et fait partie de la clé de cache : le changer invalide les verdicts, par
conception.

Deux modes, un seul schéma de sortie :

| Mode | Entrée | Déclenché par |
|---|---|---|
| `text` | métriques OCR locales + texte extrait | OCR locale ayant produit du texte |
| `vision` | pages rasterisées en PNG (blocs `image` base64) ou le PDF en bloc `document` | portail déterministe classant l'OCR comme inexploitable, ou verdict `ocr_failed` du mode `text` |

Corps de requête (extrait) :

```json
{
  "model": "claude-opus-5",
  "max_tokens": 8000,
  "thinking": { "type": "adaptive" },
  "output_config": {
    "effort": "medium",
    "format": {
      "type": "json_schema",
      "schema": {
        "type": "object",
        "additionalProperties": false,
        "required": ["ocr_verdict", "title", "persons", "dates", "categories", "transcription"],
        "properties": {
          "ocr_verdict": { "type": "string", "enum": ["ok", "degraded", "failed"] },
          "ocr_notes":   { "type": "string" },
          "title":       { "type": "string" },
          "persons":     { "type": "array", "items": { "type": "string" } },
          "dates": {
            "type": "object",
            "additionalProperties": false,
            "required": ["primary", "secondary"],
            "properties": {
              "primary":   { "type": "string", "format": "date" },
              "secondary": { "type": "array", "items": { "type": "string", "format": "date" } }
            }
          },
          "categories":         { "type": "array", "items": { "type": "string" } },
          "category_proposals": { "type": "array", "items": { "type": "object" } },
          "transcription":      { "type": "string" },
          "confidence":         { "type": "string", "enum": ["high", "medium", "low"] }
        }
      }
    }
  },
  "system": [ { "type": "text", "text": "<invariants + catalogue category.yml>",
               "cache_control": { "type": "ephemeral" } } ],
  "messages": [ { "role": "user", "content": [ /* texte OCR, ou images */ ] } ]
}
```

Points de mise en œuvre :

- **Cache de prompt.** Le prompt système (invariants + `category.yml` sérialisé) est stable et
  partagé par tous les documents : un point de cache dessus. Minimum câchable sur
  `claude-opus-5` : **512 tokens** ; TTL 5 min par défaut, `"ttl": "1h"` disponible. Vérifier
  `usage.cache_read_input_tokens` non nul, sinon un invalidateur silencieux traîne dans le
  prompt (horodatage, ordre de clés JSON non trié…).
- **Pas de `temperature` / `top_p` / `top_k`** : refusés (400) sur `claude-opus-5`.
- **Réflexion.** `thinking: {"type":"adaptive"}` est le défaut du modèle et le réglage
  recommandé ; piloter le coût par `output_config.effort` (`low`…`max`) plutôt qu'en
  désactivant la réflexion. `thinking: {"type":"disabled"}` n'est accepté qu'à `effort`
  ≤ `high` et introduit des modes de défaillance connus (fuite de balises internes dans la
  réponse) — à éviter ici.
- **Refus.** `claude-opus-5` peut renvoyer un **HTTP 200** avec `stop_reason: "refusal"` et un
  `stop_details.category`. Tester `stop_reason` *avant* de lire `content` ; un refus ⇒ document
  `blocked` avec raison `llm_refusal`, jamais un succès. Activer le repli serveur
  (`fallbacks: "default"`, en-tête beta `server-side-fallback-2026-07-01`) et **journaliser le
  modèle réellement servi** (`response.model`) dans l'entrée de cache — un repli change le
  producteur du verdict.
- **Autres `stop_reason` à traiter** : `max_tokens` (sortie tronquée ⇒ échec, pas un succès),
  `model_context_window_exceeded` (document trop volumineux ⇒ découpage ou `blocked`).
- **Erreurs.** Chaîne d'erreurs par statut : 429 avec `retry-after`, 5xx/529 avec backoff
  exponentiel borné, 400/404 non réessayables. Toute erreur non résolue ⇒ le document reste
  `pending` (jamais `blocked` : `blocked` est réservé aux tentatives réelles ayant abouti à une
  raison vérifiée, cf. `architecture.md` §7).
- **Mode lot.** Pour le traitement en masse non interactif, l'API Batches
  (`POST /v1/messages/batches`, ≤ 24 h, **‑50 % sur les tokens**) ; les résultats reviennent
  dans un ordre arbitraire, indexés par `custom_id` (= `sha256` du document). Mode
  `tripapiers classify --batch`.
- **Préflight coût.** `POST /v1/messages/count_tokens` sur un échantillon avant de lancer un
  gros corpus ; ne jamais estimer les tokens avec un tokeniseur tiers.
- **Mode hors-ligne.** `--no-llm` s'arrête après l'extraction locale et laisse les documents
  en `pending` : utile en CI, pour le développement et pour auditer le portail déterministe.

Ordre de grandeur de coût (à confirmer par `count_tokens` sur le corpus réel) :

| Scénario | Entrée / doc | Sortie / doc | 1000 documents |
|---|---|---|---|
| mode `text` (prompt système en cache) | ~3 k | ~600 | ≈ 30 $ — ≈ 15 $ en API Batches |
| mode `vision`, 3 pages haute résolution | ~14 k | ~800 | ≈ 90 $ pour 1000 (≈ 14 $ si 15 % de repli) |

### 4.5 Extraction locale (déterministe, sans LLM)

Outils vérifiés présents sur la machine : `pdftotext` 26.01, `pdftoppm`, `pdfinfo`,
`pdfimages`, `pdftocairo`, `ghostscript`, `ocrmypdf`, `tesseract` 5.5 avec
`eng`/`fra`/`rus`/`osd`.

Chaîne :

1. `pdfinfo` — nombre de pages, métadonnées, validité du PDF.
2. `pdftotext -layout -enc UTF-8` — couche texte native si elle existe.
3. Si pas de couche texte ou couche pauvre : `pdftoppm -r 300 -png` puis
   `tesseract -l fra+eng --psm 3` avec `tessedit_create_tsv=1` pour récupérer la confiance
   par mot. Images d'entrée (JPEG/PNG) : directement `tesseract`.
4. **Métriques de qualité déterministes** (le portail qui évite un appel vision inutile) :
   caractères par page, proportion alphanumérique, taux de mots reconnus dans une liste
   fr/en embarquée, confiance tesseract moyenne et médiane, nombre de caractères de
   remplacement `U+FFFD`. Seuils dans la configuration, versionnés (ils font partie de la
   clé de cache).
5. Décision : `text` exploitable ⇒ mode `text` ; manifestement inexploitable ⇒ mode `vision`
   directement, sans dépenser un appel `text`.

Les binaires externes sont invoqués avec des arguments figés, timeout, et un enregistrement
de leur version dans le ledger (une mise à jour de tesseract change les résultats — c'est
une donnée de reproductibilité).

### 4.6 Transactions, verrou, rollback

- **Verrou.** `flock` exclusif sur `tripapiers.lock`, clé unique partagée par **toutes** les
  commandes mutatives (équivalent du groupe `pipeline-google-drive`). Simplification par
  rapport à Hermes : `flock` est libéré par le noyau à la mort du processus, donc pas besoin
  du contrôle de vivacité PID + heure de démarrage. Perte du verrou ⇒ sortie immédiate,
  clôture explicite dans le ledger, aucune écriture, **jamais** d'héritage du statut réussi
  d'une exécution précédente.
- **Transaction de classement** (un seul document) : inventaire → sélection d'un `pending` →
  extraction → analyse → construction du sidecar → vérification → écriture (tmp + `fsync` +
  `rename`) → déplacement du document (`rename` intra-système de fichiers, sinon copie +
  `fsync` + suppression vers `.TRASH`) → relecture depuis le disque et audit `DATE` →
  mise à jour du registre du lot.
- **Journal de rollback** : chaque étape mutative écrit son intention avant de l'exécuter ;
  au démarrage, `tripapiers doctor` détecte un journal non clôturé et propose l'annulation.
- **Ledger** SQLite (`rusqlite`) avec états `claimed` / `running` / terminaux, pour
  l'observabilité et le diagnostic — pas comme primitive d'exclusion.

### 4.7 Invariants locaux (adaptation de `architecture.md` §10)

1. un seul document par transaction de classement ;
2. un document physique vit dans `DATE`, jamais dans `STRUCTURE` ;
3. chaque document classé a un sidecar YAML adjacent, valide et checksummé ;
4. `category.yml` et `structure.yml` sont les seules autorités de configuration, jamais
   écrites par le programme ;
5. le LLM ne sérialise pas le YAML canonique et ne touche pas au système de fichiers ;
6. aucun dossier `CATEGORY` n'est créé ;
7. aucune commande mutative concurrente (verrou unique) ;
8. une erreur de verrou, de journal ou de ledger provoque un échec fermé ;
9. les suppressions passent par `.TRASH/`, jamais `unlink` direct ;
10. aucun rapport intermédiaire pendant le traitement d'un lot ; un seul rapport final ;
11. `STRUCTURE` est intégralement reproductible depuis `DATE` + `.CONFIG` ;
12. les inventaires sont bornés au parent exact, sans suivre les liens symboliques ;
13. **(ajout local)** tout verdict LLM est mémorisé et rejouable hors ligne.

---

## 5. Phases de développement

Chaque phase est livrable et testable seule. Les phases 0 à 3 ne nécessitent **aucune clé
d'API**.

### Phase 0 — Squelette et configuration
- Workspace Cargo, `clap`, `tracing`, `anyhow`/`thiserror`, CI (`fmt`, `clippy -D warnings`, `test`).
- `crates/config` : chargement et validation de `category.yml` (schéma, unicité des noms,
  règles `assign_only_listed_categories` / `allow_multiple_categories` /
  `uncertain_category_action`).
- Parseur du DSL `structure.yml` (§4.3) + `StructurePlan`.
- **Recette :** tests dorés sur les deux fichiers réels de `hermes-documents`, plus variantes
  et cas d'erreur. `tripapiers config check` sort 0/non-0.

### Phase 1 — Cœur déterministe
- Types du domaine, tags `nom:` / `cat:`, normalisation de nom de fichier
  `NOM_Prenom_Titre.ext` (translittération, longueur, collisions → suffixe déterministe).
- `build_sidecar` / `verify_sidecar` (§4.2), émetteur YAML canonique, SHA-256.
- **Recette :** tests de propriété (round-trip, stabilité octet-à-octet, idempotence), tests
  d'instantané sur les sidecars, jeu de cas limites (dates ambiguës, personnes multiples,
  catégories multiples, catégorie inconnue ⇒ rejet).

### Phase 2 — Stockage local et transactions
- `crates/store` : inventaire `INBOX` borné, écriture atomique, `rename`, `.TRASH` + `restore`,
  journal de rollback.
- `crates/pipeline` : verrou `flock`, ledger SQLite, registre de lot
  (`pending`/`classified`/`blocked`), rapport final unique.
- Analyse injectée (trait `Analyzer` avec implémentation de test) : **le pipeline complet
  fonctionne sans LLM**.
- **Recette :** tests d'intégration sur dépôt temporaire (`assert_fs`), injection de panne à
  chaque étape ⇒ vérifier qu'aucun état intermédiaire n'est observable ; test de concurrence
  (deux processus, un seul obtient le verrou) ; test « aucun rapport avant état terminal du lot ».

### Phase 3 — Extraction locale
- Enveloppes `pdfinfo` / `pdftotext` / `pdftoppm` / `tesseract` avec arguments figés, timeouts,
  capture de version.
- Métriques de qualité et portail déterministe (§4.5).
- Générateur de corpus de test : PDF à texte natif, PDF scanné propre, scan bruité/incliné,
  scan illisible, image seule, PDF corrompu, PDF vide.
- **Recette :** classement attendu par le portail pour chaque fixture, non-régression sur les
  métriques (instantanés), aucun appel réseau.

### Phase 4 — Adaptateur LLM
- Client `reqwest` (rustls), sérialisation des deux modes, schéma JSON (§4.4).
- Cache adressé par contenu + rejeu ; validation du JSON reçu contre le schéma **et** contre
  `category.yml`.
- Gestion de `stop_reason` (`refusal`, `max_tokens`, `model_context_window_exceeded`), chaîne
  d'erreurs HTTP, backoff, repli serveur, comptabilité de coût par document dans le ledger.
- `--batch` (API Batches, ‑50 %), `count-tokens` préflight, `--no-llm`.
- **Recette :** tests hors ligne via serveur HTTP simulé (`httpmock`/`wiremock`) couvrant
  refus, 429, 5xx, JSON hors schéma, catégorie inconnue, troncature ; test de rejeu du cache ;
  **un** test d'intégration marqué `#[ignore]` frappant la vraie API.
- **Prérequis d'identification :** exporter `ANTHROPIC_API_KEY`, ou bien installer la CLI `ant`
  et faire `ant auth login`. Les profils OAuth de `ant` sont lus automatiquement par les SDK
  officiels, mais pas par un client HTTP maison : dans ce cas, récupérer un jeton éphémère via
  `ant auth print-credentials --access-token` et l'envoyer en en-têtes `Authorization: Bearer`
  et `anthropic-beta: oauth-2025-04-20` (et non `x-api-key`). Aucune information
  d'identification n'est jamais écrite dans le dépôt ni dans les sidecars.

### Phase 5 — Reconstruction de `STRUCTURE`
- Planification depuis les sidecars valides de `DATE` + `StructurePlan`.
- Modes `noop` / `incremental` / `full`. Incrémental : créer les nouvelles destinations avant
  de retirer les anciennes, annuler les mutations partielles en cas d'échec, n'enregistrer
  l'état local qu'après succès et validation. Complet : construction dans
  `.STRUCTURE.staging/`, vérification de tous les liens et de leurs cibles, bascule par
  `rename`, ancienne vue vers `.TRASH/`.
- Déclencheurs de reconstruction complète : changement de `category.yml` ou `structure.yml`
  (empreinte enregistrée), état local incompatible, `--force`, anomalie d'intégrité.
- **Recette :** propriété centrale — `STRUCTURE` reconstruite à neuf est **identique** à
  `STRUCTURE` obtenue par une suite d'incréments (comparaison arborescence + cibles de liens) ;
  aucun fichier physique dans `STRUCTURE` ; aucun lien pendant.

### Phase 6 — Supervision, rapport, recatégorisation, propositions
- `verify` : audit `DATE` (unicité des sidecars, checksums, chemins dérivés) et intégrité
  `STRUCTURE`.
- `recategorize` : relance l'analyse **sur la transcription déjà stockée** dans les sidecars
  après changement de `category.yml`, remplace uniquement les tags `cat:` validés, ne touche
  à aucun document physique, puis déclenche la prise en compte par `STRUCTURE`.
  *(À confirmer avec le point ouvert du §2 : c'est un appel LLM en mode `text`, sans nouvelle
  extraction.)*
- `propose list|approve` : propositions taxonomiques idempotentes, avec preuve documentaire,
  jamais écrites automatiquement dans `category.yml`, jamais promues en tag `cat:`.
- `report` : rapport final unique distinguant classés automatiquement / réellement tentés mais
  bloqués / contrôle qualité / propositions. Les `pending` ne sont jamais présentés comme des
  échecs.
- `doctor` : préflight de reprise après incident (§12 de `architecture.md`) — pas d'exécution
  vivante, cohérence du ledger, intégrité de `DATE`, unicité des sidecars, conformité de
  `STRUCTURE`, journaux non clôturés.

### Phase 7 — Empaquetage et migration
- `README`, page de manuel, unité systemd `--user` + timer en remplacement des crons Hermes
  (`classify` toutes les 15 min, `structure` en décalé, `verify` quotidien) — avec le verrou
  unique comme seule garantie d'exclusion.
- `import` : adoption d'une arborescence `DATE` existante produite par le pipeline Drive
  (validation des sidecars, reconstruction de l'état local, aucun appel LLM).
- Journal des versions de prompt/schéma/seuils et procédure d'invalidation du cache.

---

## 6. Dépendances Rust envisagées

| Besoin | Crate |
|---|---|
| CLI | `clap` (derive) |
| HTTP | `reqwest` (`rustls-tls`, `json`) |
| JSON / YAML | `serde`, `serde_json`, `serde_norway` (ou `serde_yaml_ng`) en lecture seule |
| Validation de schéma | `jsonschema` |
| Hachage | `sha2`, `hex` |
| Verrou de fichier | `fs2` ou `rustix` (`flock`) |
| Ledger | `rusqlite` (`bundled`) |
| Dates | `jiff` ou `time` |
| Parcours / fichiers temporaires | `walkdir`, `tempfile` |
| Journalisation | `tracing`, `tracing-subscriber` |
| Erreurs | `thiserror` (bibliothèques), `anyhow` (binaire) |
| Tests | `insta`, `proptest`, `assert_cmd`, `assert_fs`, `httpmock` |

---

## 7. Vérification de bout en bout

1. **Sans réseau** — `cargo test --workspace` : couvre config, DSL, sidecar, transactions,
   extraction, adaptateur LLM (serveur simulé + rejeu du cache). C'est la porte de CI.
2. **Corpus synthétique** — `cargo run -p tripapiers-cli -- --root <tmp> classify --all --no-llm`
   puis avec analyseur injecté : vérifier `DATE`, sidecars, registre, rapport unique.
3. **Reconstruction** — `structure --full`, puis `structure --incremental` après ajout/retrait
   de documents, puis comparer à un `--full` neuf : arborescences identiques.
4. **Vérification indépendante** — `verify all` doit sortir 0 sur un dépôt sain, non-0 sur
   chaque corruption injectée (checksum modifié, sidecar dupliqué, lien pendant, fichier
   physique dans `STRUCTURE`).
5. **Résistance à l'interruption** — `SIGKILL` à chaque point du journal, puis `doctor` :
   l'état doit être classé récupérable et le rollback rétablir l'état d'avant transaction.
6. **Concurrence** — deux processus `classify` simultanés : un seul travaille, l'autre sort
   proprement avec clôture au ledger.
7. **API réelle** — `cargo test -- --ignored` sur un mini-corpus de 5 documents avec une clé
   valide : vérifier `stop_reason`, `usage.cache_read_input_tokens` non nul au second appel,
   conformité du JSON, coût enregistré.
8. **Reproductibilité** — deux exécutions complètes sur le même corpus doivent produire des
   sidecars **identiques octet à octet** (la seconde servie par le cache).

---

## 8. Points à trancher avant la phase 4

1. **Rôle exact du LLM** dans l'attribution des catégories et l'extraction des dates/personnes
   (cf. l'encadré du §2). C'est la seule question qui change réellement la conception.
2. **Grammaire de `structure.yml`** : la lecture du §4.3 est inférée d'un unique exemple ;
   confirmer notamment le sens de `an:` (année de la date primaire ?) et le comportement des
   frères comme alternatives cumulatives.
3. **Liste des personnes** : `category.yml` catalogue les catégories, mais aucun fichier ne
   catalogue les `nom:`. Faut-il un `.CONFIG/persons.yml` autoritaire (recommandé, cohérent avec
   « personnes vérifiées » de `architecture.md` §5) ou les noms sont-ils libres ?
4. **Langues d'OCR** : `fra+eng` par défaut ; `rus` est installé — à activer ou non.
5. **Types d'entrée** : PDF et images au départ. Les formats bureautiques (`.docx`, `.odt`)
   sont hors périmètre initial — à confirmer.
