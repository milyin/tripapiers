# tripapiers — traitement des fichiers

> **Composant obligatoire.** Ce document décrit le pipeline de classement lui-même :
> `INBOX → DATE → STRUCTURE`, avec `QUARANTAINE` comme sortie d'échec. L'audit indépendant du
> corpus fait l'objet d'un document et d'un composant séparés, **optionnels** : voir
> [`verification.md`](verification.md).

---

## 1. Contexte et objectif

`hermes-documents` ne contient que de la documentation et de la configuration. Le pipeline y
est décrit mais son code d'exécution vit dans Hermes Agent, couplé à Google Drive et à un agent
LLM qui pilote l'ensemble du classement.

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
4. **Un seul document par transaction**, verrou exclusif, journal de rollback : l'état du
   dépôt après interruption est toujours l'un de deux états connus (avant / après), jamais
   un état intermédiaire.

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
confiance:85
titre:facture-electricite-mars
date:prin:2024-03-17
date:aux:2024-02-28
nom:prin:DUPONT_Marie
nom:prin:MARTIN_Paul
nom:aux:BERNARD_Luc
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
    prompt: |-
      La qualité du texte que tu viens de lire : peut-on se fier à cette OCR ?
      Réponds par un pourcentage entier de 0 à 100, arrondi à un multiple de 5.
      100 = texte propre et intégralement lisible ; 50 = lisible mais avec des
      mots manifestement altérés ; 0 = illisible ou vide. Juge le TEXTE, pas ta
      capacité à l'étiqueter. Émets exactement une ligne.
      Exemple :
      confiance:85
    cardinality: { min: 1, max: 1 }
    value_type: percent                    # entier 0..100, comparable
    value_pattern: '^(100|[0-9]{1,2})$'

  - name: titre
    prompt: |-
      Un titre court et descriptif, en minuscules sans accents, mots séparés par
      des tirets.
      Exemple :
      titre:facture-electricite-mars
    cardinality: { min: 1, max: 1 }
    value_pattern: '^[a-z0-9][a-z0-9-]{0,60}$'

  - name: date
    prompt: |-
      Chaque date portée par le document, au format AAAA-MM-JJ. La date qui
      caractérise le document porte le rôle prin, les autres aux.
      Si le document représente une liste ou un tableau de dates, par exemple
      un document financier, ignore les dates des entrées de cette liste :
      elles ne doivent produire aucun tag date:, afin d'éviter de saturer
      l'ensemble des tags.
      Exemple :
      date:prin:2024-03-17
    roles: [prin, aux]
    cardinality: { min: 1, max: 12 }
    value_pattern: '^\d{4}-\d{2}-\d{2}$'

  - name: nom
    prompt: |-
      Chaque personne physique concernée, au format NOM_Prenom. Le rôle prin
      désigne une partie au document — celle qu'il engage ou dont il traite ;
      le rôle aux désigne une personne seulement mentionnée. Un document peut
      avoir PLUSIEURS personnes principales : un contrat de bail engage le
      bailleur et le locataire, tous deux en prin. Émets-les toutes.
      Il peut aussi n'en avoir AUCUNE : un formulaire vierge, une notice, un
      barème tarifaire ne concernent personne en particulier. Dans ce cas
      n'émets aucun tag nom: — n'invente pas de destinataire.
      Si le document représente une liste de personnes, par exemple une liste
      de participants, ignore les personnes énumérées dans cette liste : elles
      ne doivent produire aucun tag nom:, afin d'éviter de saturer l'ensemble
      des tags.
      Exemples :
      nom:prin:DUPONT_Marie
      nom:prin:MARTIN_Paul
      nom:aux:BERNARD_Luc
    roles: [prin, aux]
    cardinality: { min: 0, max: 8 }        # 0 : document impersonnel (§6)
    catalogue: persons.yml                 # optionnel — cf. §11 point 3

  - name: cat
    prompt: |-
      Chaque catégorie applicable au document, parmi les valeurs déclarées
      ci-dessous. Émets le nom complet de chaque valeur retenue.
      Exemple :
      cat:ordonnance
    cardinality: { min: 1, max: 8 }
    values:
      - name: cat:assurance
        description: >-
          Attribuer aux contrats, attestations, échéanciers, garanties, sinistres
          et courriers émis par un assureur, hors documents médicaux qui ne
          concernent que les soins.
      - name: cat:banque
        description: >-
          Attribuer aux relevés, moyens de paiement, crédits, comptes, opérations
          ou correspondances d'un établissement bancaire.
      - name: cat:caution
        description: >-
          Attribuer aux actes de caution, garanties personnelles, engagements de
          garant et certificats directement liés à une caution.
      - name: cat:consultation
        description: >-
          Sous-type médical pour les convocations, comptes rendus, demandes ou
          documents liés à une consultation avec un professionnel de santé.
      - name: cat:diagnostic
        description: >-
          Attribuer aux diagnostics techniques d'un logement, notamment DPE,
          électricité, gaz, risques, amiante ou surface.
      - name: cat:education
        description: >-
          Attribuer aux diplômes, certificats de scolarité, inscriptions, relevés
          de notes, formations et documents d'établissement d'enseignement.
      - name: cat:emploi
        description: >-
          Attribuer aux contrats de travail, attestations employeur, bulletins de
          salaire, candidatures et documents professionnels.
      - name: cat:gouvernement
        description: >-
          Catégorie générale pour les documents officiels délivrés, enregistrés
          ou certifiés par une administration publique.
      - name: cat:honoraires
        description: >-
          Sous-type médical pour les factures, notes d'honoraires, feuilles de
          soins et justificatifs de paiement de professionnels de santé.
      - name: cat:loyer
        description: >-
          Attribuer aux quittances, avis d'échéance, appels de loyer et
          justificatifs de paiement ou de dette locative.
      - name: cat:logement
        description: >-
          Attribuer aux baux, états des lieux, dossiers locatifs, courriers de
          propriétaire ou d'agence et autres documents concernant un logement.
      - name: cat:medecine
        description: >-
          Catégorie générale pour les documents relatifs à la santé, aux soins,
          aux professionnels de santé et au suivi médical.
      - name: cat:analyse
        description: >-
          Sous-type médical pour les prescriptions, demandes ou résultats
          d'analyses biologiques, de laboratoire, d'imagerie ou d'examens médicaux.
      - name: cat:ordonnance
        description: >-
          Sous-type médical pour une prescription de médicaments, de soins, de
          matériel, de séances ou d'examens établie par un professionnel de santé.
      - name: cat:passeport
        description: >-
          Attribuer aux passeports, copies de passeport et pages officielles qui
          en font matériellement partie.
      - name: cat:recherche
        description: >-
          Attribuer aux projets, rapports, publications, conventions ou documents
          directement liés à une activité de recherche.
      - name: cat:titre_de_sejour
        description: >-
          Attribuer aux titres de séjour, récépissés, demandes et décisions
          administratives relatives au droit au séjour.
      - name: cat:vaccination
        description: >-
          Sous-type médical pour les carnets, certificats, historiques et
          justificatifs de vaccination.
```

### 3.3 `confiance:` — le verdict sur l'OCR

`confiance:` n'est pas un tag comme les autres : c'est **la réponse à la question « peut-on se
fier aux résultats de l'OCR ? »**, exprimée en pourcentage entier. C'est la seule des deux
missions confiées au modèle qui ne concerne pas l'étiquetage — c'est l'évaluation de l'OCR
elle-même, et c'est elle qui pilote l'escalade (§6).

Le prompt insiste sur un point qui, sans cela, se confond facilement : le modèle doit juger
**le texte**, pas sa propre aisance à l'étiqueter. Un document parfaitement océrisé mais
inhabituel doit donner `confiance:100` même si le modèle hésite sur la catégorie — c'est
l'affaire des règles de cardinalité, pas de ce tag.

> **Un pourcentage produit par un modèle n'est pas calibré.** `confiance:85` ne signifie pas
> que 85 % des caractères sont corrects : c'est un jugement ordinal habillé en nombre. Deux
> conséquences pratiques :
> - le traiter comme un **score monotone à seuil**, jamais comme une probabilité ;
> - demander un **arrondi au multiple de 5** — la fausse précision n'apporte rien et la
>   granularité grossière améliore la reproductibilité d'une exécution à l'autre ;

### 3.4 Catégories intégrées à `tags.yml`

Les valeurs fermées d'un espace de noms sont déclarées dans sa clé `values:`. Chaque entrée
associe le tag complet (`name`) à sa consigne d'attribution (`description`) ; ces descriptions
sont incluses dans le prompt rendu après la consigne générale de l'espace. Le vocabulaire de
`cat:` et tous les autres paramètres d'étiquetage ont ainsi une autorité unique : `tags.yml`.

**Conséquence à trancher (§11 point 1) :** le vocabulaire actuel encode déjà une hiérarchie,
mais *en prose*. `cat:medecine` est décrite comme « catégorie générale », tandis que
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
inscrit dans le ledger et l'invariant est testé (§10.13).

---

## 5. Contrat LLM

Rust n'a pas de SDK Anthropic officiel : appels **HTTP bruts** via `reqwest` sur
`POST https://api.anthropic.com/v1/messages`, en-têtes `x-api-key` et
`anthropic-version: 2023-06-01`.

Modèle : **`claude-opus-5`** ($5 / $25 par million de tokens entrée/sortie, fenêtre 1 M,
vision haute résolution jusqu'à 2576 px sur le grand côté). Le modèle est un paramètre de
configuration et le modèle réellement servi est consigné avec chaque exécution.

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
Tu reçois le texte d'un document, issu d'une OCR. Tu as deux tâches :
juger la qualité de cette OCR, et émettre la liste des tags que ce texte porte.

FORMAT DE SORTIE — impératif :
- une ligne = un tag, rien d'autre
- aucune prose, aucune puce, aucune numérotation, aucun bloc de code
- n'émets un tag que si le texte le justifie ; n'invente aucune valeur
- si tu hésites sur une valeur, ne l'émets pas — l'omission est traitée en aval
- confiance: juge la lisibilité du TEXTE, pas ta capacité à l'étiqueter :
  un texte propre vaut confiance:100 même si tu hésites sur la catégorie

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
  (`response.model`) dans le ledger — un repli change le producteur du verdict.
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
  - { namespace: nom,  role: prin,    min: 0 }          # ni min ni max : cf. encadré
  - { namespace: cat,                 min: 1 }

confidence:                     # le verdict sur l'OCR (§3.3)
  namespace: confiance
  minimum: 70                   # pourcentage entier ; à calibrer sur le corpus
  divergence_locale: 40         # écart max toléré avec la métrique locale (§7)

unknown_values:                 # valeur hors catalogue
  cat: reject                   # reject | propose | accept
  nom: propose

parse_quality:
  max_rejected_ratio: 0.5       # au-delà, réponse jugée non exploitable

on_failure:                     # que faire selon CE QUI a échoué
  low_confidence:    escalate   # le texte est suspect : ré-océriser peut aider
  parse_quality:     escalate
  missing_required:  escalate   # cf. encadré ci-dessous
  unknown_value:     quarantine # ré-océriser ne créera pas la catégorie manquante
  second_attempt:    quarantine # toujours terminal
```

> **Plusieurs `nom:prin:` sont autorisés, et c'est le cas normal pour tout document qui lie
> des parties.** Un contrat de bail engage le bailleur et le locataire : les deux sont
> principaux, aucun n'est « auxiliaire ». Idem pour un acte de vente, une convention, un
> jugement, une attestation de caution. Contraindre `nom:prin:` à une seule valeur
> obligerait le modèle à élire arbitrairement une partie et à rétrograder l'autre en `aux:` —
> le document deviendrait alors invisible depuis la seconde personne dans `STRUCTURE`, ce qui
> est exactement l'inverse du service rendu.
>
> `aux:` garde un sens précis, et différent : une personne **mentionnée** sans être partie —
> le médecin qui signe l'ordonnance, l'agent immobilier nommé dans le bail, l'enfant cité dans
> une attestation qui ne le concerne pas directement. La distinction est donc « partie » vs
> « mentionné », pas « le plus important » vs « les autres ».
>
> **Et il peut n'y en avoir aucune.** Un formulaire administratif vierge, une notice, un barème
> tarifaire, une plaquette d'information ne concernent personne en particulier. Exiger au moins
> une personne forcerait le modèle à en désigner une — le plus souvent l'émetteur du document
> ou un nom aperçu dans un pied de page — et produirait un classement faux, sous une personne
> qui n'a rien à voir avec le document. Mieux vaut un document sans personne qu'un document
> attribué à tort.
>
> Il n'y a donc **ni `min` ni `max` sur `nom:prin:`** ; le total reste borné par
> `cardinality.max: 8` de `tags.yml`. Trois conséquences, traitées §8.3 et §8.4 : la dérivation
> du nom de fichier doit choisir quand il y a plusieurs personnes **et se passer d'elles quand
> il n'y en a aucune** ; la vue `STRUCTURE` fait apparaître le document sous **chaque** personne
> principale — ce qu'on veut d'un bail ; et un document sans personne ne doit pas pour autant
> devenir invisible dans `STRUCTURE`, ce qui est le vrai piège.

> **Pourquoi l'issue dépend de la règle en défaut.** Escalader, c'est refaire l'OCR. Ça n'a de
> sens que si le problème vient du **texte**. Un `confiance:45` dit exactement cela : le texte
> est douteux, une transcription vision a de bonnes chances de faire mieux. À l'inverse, un
> `confiance:95` accompagné d'un `date:prin:` manquant dit que le texte est propre et que le
> document ne porte tout simplement pas de date — ré-océriser un texte déjà parfait ne la fera
> pas apparaître, et coûtera le prix fort d'un appel vision pour rien.
>
> Un seul `on_failure` global forcerait à choisir entre gaspiller des appels vision et
> quarantainer des documents qu'une meilleure OCR aurait sauvés. La valeur par défaut proposée
> ci-dessus reste `escalate` pour `missing_required` — prudente, parce qu'un champ absent est
> parfois le symptôme d'une zone illisible que `confiance:` a sous-estimée — mais c'est
> précisément le réglage à revoir en premier si la facture des appels vision dérape.

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

### 7.1 Deux mesures de la même chose

La qualité de l'OCR est jugée deux fois, et c'est voulu :

| | **métrique locale** (§7, étape 4) | **`confiance:`** (§3.3) |
|---|---|---|
| Qui | tesseract + heuristiques | le modèle |
| Quand | avant tout appel LLM | pendant l'appel `tag` |
| Coût | nul | inclus dans l'appel |
| Nature | mécanique : confiance par mot, taux de mots reconnus | sémantique : le texte a-t-il du sens ? |
| Rôle | **portail** — faut-il seulement appeler `tag` ? | **verdict** — peut-on se fier au résultat ? |

Elles ne mesurent pas la même chose et échouent différemment. Tesseract peut rendre une haute
confiance par mot sur un texte parfaitement reconnu mais dont l'ordre de lecture est absurde
(colonnes entrelacées, tableau aplati) : la métrique locale est aveugle, le modèle voit le
problème. Inversement, une police inhabituelle fait chuter la confiance tesseract sur un texte
que le modèle lit sans peine.

D'où le réglage `divergence_locale` (§6) : un écart important entre les deux — typiquement une
métrique locale bonne et un `confiance:` bas — est signalé comme anomalie et journalisé. Ce
n'est pas un échec en soi, c'est le signal qui dit que l'un des deux seuils est mal calibré, ou
que le corpus contient une classe de documents que le portail laisse passer à tort.

Les deux valeurs sont conservées dans le bloc `ocr` du sidecar (§8.3), ce qui rend la
calibration possible *a posteriori* sur le corpus réel, sans reclasser quoi que ce soit.

---

## 8. Organisation du code et du dépôt

### 8.1 Espace de travail Cargo

```text
tripapiers/
├── Cargo.toml                  # workspace
├── crates/
│   ├── core/        # grammaire des tags, contrat YAML, checksum, dérivation de chemin
│   ├── config/      # tags.yml, evaluation.yml, structure.yml + rendu du prompt
│   ├── extract/     # OCR locale : pdftotext, pdftoppm, tesseract, métriques de qualité
│   ├── llm/         # client Claude (HTTP), appels tag et vision, analyseur de lignes
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
│   ├── tags.yml                # espaces de noms, valeurs et prompts (nouveau)
│   ├── evaluation.yml          # règles d'acceptation      (nouveau)
│   └── structure.yml           # plan déclaratif de la vue logique
└── .TRASH/                     # suppressions réversibles, horodatées
```

État durable hors dépôt, sous `$XDG_STATE_HOME/tripapiers/` (défaut `~/.local/state/tripapiers/`) :

```text
inbox_batch.json              # registre durable du lot (pending/classified/quarantined)
structure_state.json          # état de reconstruction incrémentale
tag_proposals.json            # valeurs hors catalogue, idempotentes
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
  qualite_locale: 78                # métrique déterministe, 0..100 (§7.1)
  qualite_modele: 85                # le tag confiance:, recopié ici pour l'analyse
tags:
  - cat:sante:ordonnance
  - confiance:85
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

**Nom de fichier et nombre de personnes principales.** Le gabarit devient
`[NOM_Prenom_]Titre.ext` — la partie personne est **optionnelle** :

| `nom:prin:` | Nom de fichier | Exemple |
|---|---|---|
| une | `NOM_Prenom_Titre.ext` | `DUPONT_Marie_ordonnance-dr-martin.pdf` |
| plusieurs | première dans l'ordre lexicographique | `DUPONT_Marie_contrat-bail.pdf` |
| aucune | `Titre.ext` — le titre seul | `formulaire-cerfa-14011-vierge.pdf` |

Pour le cas *plusieurs*, trois issues étaient possibles — concaténer les noms (chemins longs,
plafond de 255 octets vite atteint), omettre le nom (gabarit incohérent), ou en choisir un.
Règle retenue : **la personne principale première dans l'ordre lexicographique**, les autres
n'apparaissent que dans les tags.

C'est cohérent avec la séparation qui structure tout le dépôt : `DATE` est le stockage
*physique*, où chaque document existe une fois et à un seul endroit ; `STRUCTURE` est la vue
*logique*, où il apparaît autant de fois que nécessaire (§8.4). Chercher un bail par le nom du
locataire se fait dans `STRUCTURE`, pas en lisant l'arborescence `DATE` — dont le nom de fichier
n'a qu'à être déterministe, lisible et borné. La liste complète des parties reste dans les tags
du sidecar, qui font autorité.

Collisions : deux baux du même jour dont la première partie porte le même nom produisent le même
gabarit. Le suffixe déterministe déjà prévu (§12, phase 1) les sépare — il est dérivé du `sha256`
du contenu, donc stable d'une exécution à l'autre.

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
seules `nom:prin:`. *Proposition : `nom` éventaille sur **toutes** les valeurs `nom:prin:`, et
sur elles seules ; `nom:aux:` reste disponible comme filtre explicite* — sinon chaque document
apparaît sous quiconque y est simplement mentionné, et le dossier du médecin se remplit des
ordonnances de tous ses patients.

L'éventail porte donc sur un ensemble, pas sur une valeur unique : **un document à plusieurs
personnes principales reçoit un lien symbolique sous chacune d'elles.** Un bail apparaît dans le
dossier du bailleur et dans celui du locataire, avec la même cible physique dans `DATE` — un seul
fichier, deux chemins d'accès. C'est exactement le service que rend la vue logique, et la raison
pour laquelle `nom:prin:` n'a pas de plafond (§6).

**L'éventail sur l'ensemble vide est le vrai piège.** Un ensemble vide produit zéro branche, donc
zéro lien. Or le `structure.yml` actuel fait passer **tous** les chemins par un éventail `nom:`
au premier niveau : un document sans personne principale serait correctement archivé dans `DATE`,
correctement étiqueté, et **totalement absent de `STRUCTURE`**. Il n'apparaîtrait nulle part, sans
la moindre erreur — le pire mode de défaillance possible pour un outil de classement, parce que
rien ne le signale.

*Proposition : un éventail sur un ensemble vide produit une branche unique, nommée par un
substitut déclaré dans la configuration* — `placeholder: _sans-personne` sur le niveau concerné,
avec une valeur par défaut par espace de noms. Le formulaire vierge se retrouve alors sous
`STRUCTURE/_sans-personne/gouvernement/…`, reproductible et navigable. Le préfixe `_` le fait
trier avant les noms propres et le distingue visuellement d'une personne réelle.

*Alternative écartée : faire « tomber » le niveau vide et rattacher les enfants au parent.* Elle
évite le dossier substitut mais mélange les profondeurs dans la vue — certaines catégories à la
racine, d'autres sous une personne — ce qui casse la lisibilité et complique la comparaison entre
reconstruction complète et incrémentale.

Quelle que soit l'option retenue, la garantie doit être vérifiable, d'où l'invariant 17 (§10) :
**tout document classé est joignable par au moins un chemin logique**. C'est un contrôle
générique, qui attrape cette classe de bogue au-delà du seul cas `nom:` — un filtre trop étroit,
une catégorie absente de `structure.yml`, une branche mal conditionnée produisent le même
silence.

Conséquence à ne pas manquer côté reconstruction : le plan attendu associe *plusieurs* chemins
logiques à un même document, et une reconstruction incrémentale doit les ajouter ou les retirer
**ensemble**. Retirer une seule branche parce qu'une partie a disparu des tags, en laissant
l'autre, produit une vue à demi juste — le cas est explicitement au programme de la recette de
la phase 5.

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
8. une erreur de verrou, de journal ou de ledger provoque un échec fermé ;
9. les suppressions passent par `.TRASH/`, jamais `unlink` direct ;
10. aucun rapport intermédiaire pendant le traitement d'un lot ; un seul rapport final ;
11. `STRUCTURE` est intégralement reproductible depuis `DATE` + `.CONFIG` ;
12. les inventaires sont bornés au parent exact, sans suivre les liens symboliques ;
13. **l'escalade est bornée** : au plus une reprise vision, au plus trois appels LLM par document ;
14. **aucune ligne non conforme n'est réparée** : elle est ignorée, comptée et journalisée ;
15. **un échec d'évaluation déplace le document en `QUARANTAINE`**, avec son dossier de preuve ;
     une panne d'infrastructure, elle, le laisse `pending` ;
16. **le prompt est engendré depuis `.CONFIG`**, jamais écrit en dur dans le code Rust ;
17. **tout document classé est joignable par au moins un chemin logique** dans `STRUCTURE` — un
     document correctement archivé mais invisible dans la vue est un échec silencieux, donc le
     plus dangereux.

Le pipeline **maintient** ces invariants. Le composant optionnel les **contrôle** de façon
indépendante ; la correspondance invariant → contrôle est en
[`verification.md`](verification.md) §6.

---

## 11. Points à trancher

1. **Migration du catalogue vers des catégories hiérarchiques** (§3.4). Le catalogue actuel
   encode déjà une hiérarchie en prose (« catégorie générale » / « sous-type médical pour… »).
   La rendre structurelle — `cat:medecine:ordonnance` — améliore l'étiquetage et la vue
   `STRUCTURE`, mais change les tags de tous les sidecars existants.
2. **DSL et tags hiérarchiques** (§8.4) : imbrication à l'éventail, correspondance par segments
   au filtre, et comportement de `nom` vis-à-vis des rôles `prin`/`aux`. Trois propositions y
   sont faites, aucune n'est confirmée.
3. **Catalogue des personnes.** Un `.CONFIG/persons.yml` autoritaire rend `nom:` vérifiable et
   évite les variantes orthographiques (`DUPONT_Marie` / `Dupont_Marie`). Sans lui, l'espace
   `nom:` reste ouvert et `unknown_values: propose` est le seul garde-fou. Recommandé.
4. **Calibration des seuils de `confiance:`.** L'encodage est fixé — un pourcentage entier
   décrivant la qualité de l'OCR (§3.3) — mais `confidence.minimum` (proposé à 70) et
   `divergence_locale` (proposé à 40) sont des valeurs *a priori*. Elles ne peuvent être
   réglées que sur le corpus réel, à la fin de la phase 4 : classer un lot avec un seuil
   volontairement bas, puis lire la distribution de `confiance:` croisée avec les échecs
   d'évaluation. Un seuil trop haut envoie en vision des documents parfaitement lisibles ; trop
   bas, il laisse passer des tags dérivés d'un texte corrompu — le second défaut est le plus
   coûteux, car il produit un classement faux et silencieux.
5. **Issue par défaut de `missing_required`** (§6). `escalate` est prudent mais paie un appel
   vision pour des documents dont le texte était déjà bon. À revoir après la première
   calibration, avec les chiffres sous les yeux.
6. **Documents sans date.** `nom:prin:` est désormais facultatif (§6), mais `date:prin:` reste
   obligatoire parce qu'il **dérive le chemin d'archivage** `DATE/YYYY/MM/DD`. Or l'exemple qui
   a motivé le changement — le formulaire administratif vierge — n'a généralement ni personne
   *ni date* : il partirait donc quand même en quarantaine, et la correction serait inutile pour
   le cas visé. Trois options :
   - **repli sur la date d'ingestion**, enregistrée comme telle (`source.date_origine:
     document | ingestion`) pour qu'elle ne soit jamais confondue avec une date portée par le
     document. Recommandé : le document reste classé et joignable, et la provenance de la date
     est explicite et vérifiable ;
   - **repli sur la date de modification du fichier**, souvent plus proche de la réalité pour un
     scan, mais fragile — une copie ou une synchronisation la réécrit ;
   - **maintenir l'exigence** et assumer que ces documents partent en quarantaine, où `requeue`
     permet de les traiter à la main.

   Le choix touche la dérivation du chemin, donc un invariant central : à trancher avant la
   phase 1, pas pendant.
7. **Substitut d'éventail vide** (§8.4) : nom du dossier (`_sans-personne` proposé) et portée du
   réglage — par niveau, ou par espace de noms dans `tags.yml`.
8. **Langues d'OCR** : `fra+eng` par défaut ; `rus` est installé — à activer ou non.
9. **Types d'entrée** : PDF et images au départ. Formats bureautiques (`.docx`, `.odt`) hors
   périmètre initial — à confirmer.

---

## 12. Phases de développement

Chaque phase est livrable et testable seule. Les phases 0 à 3 ne nécessitent **aucune clé
d'API**. Les phases du composant optionnel sont numérotées séparément (V1…V3) dans
[`verification.md`](verification.md) §8 et peuvent être menées en parallèle à partir de la
phase 1.

### Phase 0 — Squelette et configuration
- Workspace Cargo, `clap`, `tracing`, `anyhow`/`thiserror`, CI (`fmt`, `clippy -D warnings`, `test`).
- `crates/config` : chargement et validation de `tags.yml`, `evaluation.yml` et `structure.yml`.
  Contrôles croisés : toute valeur fermée est déclarée dans son espace de noms, tout
  `catalogue:` externe référencé existe, tout espace de noms cité par `evaluation.yml` est
  déclaré dans `tags.yml`, l'espace visé par `confidence` déclare bien `value_type: percent`,
  et `confidence.minimum` comme `divergence_locale` tiennent dans 0..100.
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
- Dérivation du nom de fichier (§8.3), y compris le choix de la personne principale première
  dans l'ordre lexicographique et le suffixe déterministe en cas de collision.
- **Recette :** tests de propriété (round-trip tags ⇄ sidecar, stabilité octet-à-octet,
  idempotence) ; **corpus de réponses LLM pathologiques** — prose d'introduction, puces,
  numérotation, blocs de code, balises internes, tags tronqués en fin de flux, espaces de noms
  inconnus, doublons, casse inattendue, ligne de 10 ko — chacune doit être ignorée sans panique
  et comptée au bon motif ; table de décision complète du moteur d'évaluation, dont les cas
  **plusieurs `nom:prin:`** (accepté, contrairement à plusieurs `date:prin:`) et **zéro
  `nom:prin:`** (accepté, gabarit de nom de fichier réduit au titre) ; nom de fichier stable
  quel que soit l'ordre d'émission des personnes par le modèle.

### Phase 2 — Stockage local, transactions et quarantaine
- `crates/store` : inventaire `INBOX` borné, écriture atomique, `rename`, `.TRASH` + `restore`,
  journal de rollback.
- `QUARANTAINE` : mise en quarantaine avec dossier de preuve (§9), `requeue`, `quarantaine list`.
- `crates/pipeline` : verrou `flock`, ledger SQLite, registre de lot, machine à états de
  l'escalade (§4) avec son compteur d'appels et rapport final unique.
- Analyse injectée (trait `Tagger`) : **le pipeline complet fonctionne sans LLM**.
- **Recette :** injection de panne à chaque étape ⇒ aucun état intermédiaire observable ; test
  de concurrence ; « aucun rapport avant état terminal du lot » ;
  **« l'escalade ne se produit qu'une fois »** ;
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
- Client `reqwest` (rustls), appels `tag` et `vision` (§5).
- Gestion de `stop_reason`, chaîne d'erreurs HTTP, backoff, repli serveur, comptabilité de coût
  et du nombre d'appels par document dans le ledger.
- `--batch`, `count-tokens` préflight, `--no-llm`.
- **Recette :** serveur HTTP simulé couvrant refus, 429, 5xx, réponse vide, réponse tronquée en
  milieu de ligne, réponse 100 % non conforme ; **un** test `#[ignore]` frappant
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
  lien pendant ; cas hiérarchiques (`cat:a:b:c`, filtre par préfixe, rôles `nom:`) ; **document à
  plusieurs `nom:prin:`** — un lien sous chaque partie, tous vers la même cible, ajoutés et
  retirés ensemble lors d'un incrément qui fait disparaître l'une des parties des tags ;
  **document sans `nom:prin:`** — l'éventail vide produit la branche substitut et le document
  reste joignable (invariant 17), en reconstruction complète comme en incrémentale.

### Phase 6 — Rapport, réétiquetage, propositions
- `report` : rapport final unique distinguant classés / mis en quarantaine avec la règle en
  défaut / contrôle qualité / propositions. Les `pending` ne sont jamais présentés comme des
  échecs.
- `retag` : relance l'appel `tag` **sur la transcription déjà stockée** dans les sidecars après
  changement de `tags.yml` ou `evaluation.yml` ; ne réocérise rien, ne déplace aucun document
  physique, puis déclenche la prise en compte par `STRUCTURE`. Remplace la
  `recategorize` d'origine, et la généralise à tous les espaces de noms.
- `propose list|approve` : valeurs hors catalogue, idempotentes, avec preuve documentaire,
  jamais écrites automatiquement dans un catalogue, jamais promues en tag.

### Phase 7 — Empaquetage et migration
- `README`, page de manuel, unité systemd `--user` + timer (`classify` toutes les 15 min,
  `structure` en décalé) — le verrou unique reste la seule garantie d'exclusion.
- `import` : adoption d'une arborescence `DATE` existante en `schema_version: 1`, avec migration
  des tags plats vers la forme hiérarchique si le point §11.1 est tranché en ce sens. Aucun
  appel LLM.
- Journal des versions de prompt, catalogue et seuils.
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
   adaptateur LLM avec serveur simulé. Porte de CI du composant obligatoire.
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
10. **Build sans le composant optionnel** — `cargo build -p tripapiers-cli` après retrait de
    `crates/verify` du workspace : doit compiler et passer les tests 1 à 9.
