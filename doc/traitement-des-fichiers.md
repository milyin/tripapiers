# tripapiers — traitement des fichiers

> **Composant principal.** Ce document décrit la première version de l'application : extraction
> OCR, étiquetage, rangement et suppression. Aucun index par raccourcis ou liens symboliques
> n'est construit. L'audit indépendant, encore au stade de brouillon, est décrit dans
> [`verification.md`](verification.md).

---

## 1. Objectif et périmètre

`tripapiers` est une application locale de classement documentaire. Un fichier arrive dans
`INBOX`, reçoit une représentation OCR et un ensemble de tags, puis les trois artefacts sont
rangés sous des racines séparées :

- `DOC` contient les octets originaux, sans renommage ;
- `OCR` contient le texte extrait et les métadonnées de l'extraction ;
- `TAG` contient les étiquettes produites à partir de l'artefact OCR ;
- `QUARANTINE` reçoit les ensembles qui n'ont pas pu être rangés correctement.

Le chemin `YYYY/MM/DD` correspond toujours à la **date d'ajout au système**, capturée au début
du traitement. Il ne dépend ni d'une date trouvée dans le document, ni de ses métadonnées de
fichier, ni d'un tag `date:`.

Hors périmètre de cette première version : Google Drive, stockage distant, création de vues
logiques, raccourcis, liens symboliques, index par personne ou catégorie, surveillance
automatique d'un dossier et interface graphique.

Les noms exposés par l'application — commandes, arguments, clés TOML, valeurs d'état et champs
de protocole — sont en anglais. La documentation et les messages destinés à l'utilisateur sont
en français. Les noms de tags restent ceux du vocabulaire configuré dans `tags.yml`.

---

## 2. Arborescence et identité d'un document

### 2.1 Arborescence par défaut

```text
<root>/
├── INBOX/                              # source des fichiers à traiter
├── QUARANTINE/                         # ensembles qui n'ont pas pu être rangés
├── DOC/
│   └── YYYY/MM/DD/
│       └── fichier-original.pdf
├── OCR/
│   └── YYYY/MM/DD/
│       └── fichier-original.pdf.ocr.yml
├── TAG/
│   └── YYYY/MM/DD/
│       └── fichier-original.pdf.tag.yml
├── .CONFIG/
│   ├── tags.yml
│   └── evaluation.yml
└── tripapiers.toml
```

L'extension originale est conservée. Les exemples utilisent PDF, mais tout format pris en
charge suit la même règle : `photo.jpg`, `photo.jpg.ocr.yml`, `photo.jpg.tag.yml`.

### 2.2 Date d'ajout

La commande `sort` capture une seule valeur `added_date` au début de la transaction d'un
document : la date civile courante dans le fuseau local du système. Cette valeur `YYYY-MM-DD`
est inscrite dans les deux fichiers YAML et réutilisée pour les trois chemins.

Une relance ne recalcule pas la date si un artefact OCR ou TAG existant porte déjà `added_date` :
elle reprend cette valeur. Les commandes indépendantes `extract` et `classify` ne déplacent pas
leurs entrées ; elles conservent donc la date fournie par `--date`, celle dérivée d'un chemin
géré, celle déjà inscrite dans l'artefact d'entrée ou, à défaut, la date d'exécution.

### 2.3 Identité et collisions

L'identité stable est le SHA-256 des octets du document. Le nom de fichier sert à résoudre les
chemins, mais ne remplace jamais cette empreinte.

Avant tout rangement, `sort` réserve les trois chemins cibles :

- si aucun n'existe, le traitement continue ;
- si les trois existent et portent le même SHA-256, l'opération retourne `already_exists` sans
  réécrire les artefacts ;
- si un chemin existe avec un autre contenu, l'ensemble entrant part dans `QUARANTINE` avec la
  raison `path_conflict` ;
- un ensemble partiel est une incohérence et part dans `QUARANTINE` avec la raison
  `partial_triplet`.

---

## 3. Configuration des chemins

### 3.1 `tripapiers.toml`

```toml
schema_version = 1

[paths]
inbox = "INBOX"
quarantine = "QUARANTINE"
documents = "DOC"
ocr = "OCR"
tags = "TAG"
config = ".CONFIG"

[ocr]
languages = ["fra", "eng"]
minimum_confidence = 70
max_pages = 10
vision_fallback = true

[model]
name = "claude-opus-5"
```

Les chemins relatifs sont résolus depuis le dossier contenant `tripapiers.toml`. Un chemin
absolu reste absolu. Aucun chemin configuré ne doit être contenu dans un autre, sauf `config`
qui peut rester sous la racine commune ; `config check` refuse les chevauchements dangereux.

### 3.2 Priorité et arguments globaux

La priorité est : argument CLI, fichier TOML, valeur par défaut.

```text
--config <path>
--root <path>
--inbox-dir <path>
--quarantine-dir <path>
--documents-dir <path>
--ocr-dir <path>
--tags-dir <path>
--config-dir <path>
```

`--root` remplace la base de résolution des valeurs relatives. Les arguments `--*-dir`
remplacent ensuite une racine précise. La configuration effectivement résolue peut être
affichée par `tripapiers config show` et validée par `tripapiers config check`.

Les chemins sont normalisés lexicalement, puis vérifiés après canonicalisation du parent
existant. L'application refuse une racine vide, `/`, un lien symbolique comme racine gérée ou
deux racines pointant vers le même dossier.

---

## 4. Système commun de désignation des fichiers

`extract`, `classify` et `remove` acceptent deux formes mutuellement exclusives.

### 4.1 Forme chemin

```text
tripapiers extract <path> [--output <path>]
tripapiers classify <path> [--output <path>]
tripapiers remove <path>
```

Pour `extract`, le chemin vise un document externe, dans `INBOX` ou dans `DOC`. Pour `classify`,
il vise un `.ocr.yml` externe, dans `INBOX` ou dans `OCR`. Pour `remove`, il peut viser n'importe
quel membre d'un triplet géré sous `DOC`, `OCR` ou `TAG`. Les suffixes déterministes permettent
de retrouver les autres membres du triplet.

### 4.2 Forme nom et date

```text
--name <filename> --date <YYYY-MM-DD>
```

Cette forme résout :

| Commande | Entrée résolue |
|---|---|
| `extract` | `DOC/YYYY/MM/DD/<filename>` |
| `classify` | `OCR/YYYY/MM/DD/<filename>.ocr.yml` |
| `remove` | le triplet `DOC` / `OCR` / `TAG` portant ce nom et cette date |

`--name` n'accepte qu'un nom de base : aucun `/`, `..` ou séparateur de plateforme. `--date`
accepte strictement `YYYY-MM-DD` et rejette les dates civiles impossibles.

### 4.3 Sortie d'`extract` et `classify`

Sans `--output`, une entrée externe ou placée dans `INBOX` produit son résultat à côté d'elle :

- `extract rapport.pdf` écrit `rapport.pdf.ocr.yml` à côté de l'entrée ;
- `classify rapport.pdf.ocr.yml` écrit `rapport.pdf.tag.yml` à côté de l'entrée.

Pour une entrée sous une racine gérée, la séparation est conservée :

- `extract DOC/YYYY/MM/DD/rapport.pdf` écrit
  `OCR/YYYY/MM/DD/rapport.pdf.ocr.yml` ;
- `classify OCR/YYYY/MM/DD/rapport.pdf.ocr.yml` écrit
  `TAG/YYYY/MM/DD/rapport.pdf.tag.yml` ;
- la forme `--name` + `--date` applique toujours ces destinations gérées.

`--output` désigne le chemin complet du fichier produit, nom inclus. Les deux commandes
refusent d'écraser un fichier existant, sauf avec `--force`. Une écriture passe toujours par un
fichier temporaire adjacent suivi d'un `rename` atomique.

---

## 5. Commandes de la première étape

### 5.1 `extract`

```text
tripapiers extract <document> [--output <ocr-yaml>] [--date <YYYY-MM-DD>]
tripapiers extract --name <filename> --date <YYYY-MM-DD> [--output <ocr-yaml>]
```

La commande lit un document, exécute l'OCR locale, calcule ses métriques déterministes et écrit
un artefact `.ocr.yml`. Si la confiance locale est inférieure à `ocr.minimum_confidence` et que
`ocr.vision_fallback` est activé, elle peut demander au modèle une transcription de secours.

La confiance enregistrée reste toujours la mesure de l'OCR locale. Elle décide du recours à la
vision, mais le modèle ne reçoit jamais la mission de produire un score de confiance.

### 5.2 `classify`

```text
tripapiers classify <ocr-yaml> [--output <tag-yaml>]
tripapiers classify --name <filename> --date <YYYY-MM-DD> [--output <tag-yaml>]
```

La commande lit exclusivement l'artefact OCR, vérifie son schéma et son empreinte, puis envoie
son champ `text` au modèle avec le vocabulaire rendu depuis `tags.yml`. Le modèle produit une
liste de tags, un par ligne. Il ne juge pas la qualité OCR et n'émet aucun tag de confiance.

Les lignes non conformes sont ignorées, comptées et conservées dans les informations de
diagnostic. Les tags acceptés sont dédupliqués et triés avant la sérialisation du `.tag.yml`.

### 5.3 `sort`

```text
tripapiers sort [<files>...] [--date <YYYY-MM-DD>]
```

Sans arguments, `sort` regroupe les fichiers ordinaires placés directement dans `INBOX`, dans
l'ordre lexicographique de l'original. Un fichier portant le suffixe `.ocr.yml` ou `.tag.yml`
est reconnu comme l'artefact d'un original du même nom, jamais comme un nouveau document. Avec
des noms, la commande ne traite que les groupes correspondants. Les sous-dossiers et liens
symboliques sont refusés.

Un groupe d'entrée peut donc contenir :

```text
fichier-original.pdf
fichier-original.pdf.ocr.yml     # facultatif, produit auparavant par extract
fichier-original.pdf.tag.yml     # facultatif, produit auparavant par classify
```

Les artefacts déjà présents sont réutilisés seulement après validation de leur schéma et de
leurs empreintes. Un OCR absent est produit par `extract` ; un TAG absent est produit par
`classify`. Un YAML invalide ou orphelin est une erreur documentaire et le groupe complet est
mis en quarantaine.

Pour chaque document :

1. reprendre `added_date` d'un artefact valide ou la capturer, puis réserver `DOC/YYYY/MM/DD`,
   `OCR/YYYY/MM/DD` et `TAG/YYYY/MM/DD` ;
2. valider l'OCR présent dans `INBOX`, ou exécuter la même logique qu'`extract` vers un fichier
   temporaire ;
3. valider le TAG présent dans `INBOX`, ou exécuter la même logique que `classify` à partir de
   l'artefact OCR ;
4. valider les trois artefacts et leurs empreintes croisées ;
5. créer les trois dossiers de date si nécessaire ;
6. déplacer atomiquement l'original et les YAML présents ou générés vers `DOC`, `OCR` et `TAG` ;
7. enregistrer l'état terminal `sorted` dans le ledger.

Une erreur documentaire ou d'évaluation déplace l'original et tous les YAML déjà produits
dans un dossier adjacent de `QUARANTINE/YYYY/MM/DD/`. Une panne d'infrastructure laisse
l'entrée dans `INBOX` et conserve seulement des temporaires récupérables dans l'état local.

### 5.4 `remove`

```text
tripapiers remove DOC/YYYY/MM/DD/<filename>
tripapiers remove --name <filename> --date <YYYY-MM-DD>
```

`remove` résout et vérifie le triplet complet, affiche les trois chemins visés, puis supprime :

```text
DOC/YYYY/MM/DD/<filename>
OCR/YYYY/MM/DD/<filename>.ocr.yml
TAG/YYYY/MM/DD/<filename>.tag.yml
```

La suppression est transactionnelle à l'échelle du triplet : les trois fichiers sont d'abord
renommés vers un dossier temporaire privé situé sur le même système de fichiers ; ils ne sont
effacés qu'une fois les trois déplacements réussis. En cas d'échec intermédiaire, le rollback
les remet en place. `--yes` supprime la confirmation interactive ; `--dry-run` n'effectue aucune
mutation. Les dossiers de date devenus vides sont retirés jusqu'à leur racine gérée.

---

## 6. Extraction OCR et confiance locale

### 6.1 Chaîne locale

1. `pdfinfo` valide les PDF et détermine le nombre de pages.
2. `pdftotext -layout -enc UTF-8` extrait la couche texte native lorsqu'elle existe.
3. Sinon, `pdftoppm -r 300 -png` rasterise, puis `tesseract -l <languages> --psm 3` produit le
   texte et les données TSV.
4. Le code local calcule une confiance entière de 0 à 100 à partir de la médiane et de la
   moyenne Tesseract, du taux de caractères de remplacement, du taux de contrôle, de la densité
   alphanumérique et du nombre de mots plausibles.
5. Si le score est inférieur au seuil, l'extraction peut être refaite par le modèle de vision.

Pour un PDF à couche texte native, les mêmes métriques lexicales produisent le score ; aucune
valeur n'est demandée à un modèle. La formule, ses poids et sa version sont figés dans le code et
inscrits dans l'artefact OCR pour rendre le résultat explicable.

### 6.2 Contrat `.ocr.yml`

```yaml
schema_version: 1
source:
  filename: fichier-original.pdf
  sha256: "sha256:9f86d081..."
  added_date: "2026-08-16"
ocr:
  created_at: "2026-08-16T14:32:08+02:00"
  engine:
    kind: local                       # local | model
    name: tesseract
    version: "5.5.0"
  languages: [fra, eng]
  confidence:
    value: 87
    source: local
    formula_version: 1
  vision_fallback_used: false
text: |-
  Texte extrait du document.
```

Si la vision est utilisée, `engine.kind` vaut `model`, `engine.name` contient l'identifiant du
modèle et `vision_fallback_used` vaut `true`. `ocr.confidence` reste le score local qui a
déclenché ce repli ; il n'est pas présenté comme une évaluation de la transcription du modèle.

Le YAML est UTF-8, utilise LF, n'emploie ni ancres ni alias, et se termine par une seule ligne
vide. Le texte est conservé intégralement dans le scalaire littéral `text`.

---

## 7. Étiquetage

### 7.1 Grammaire

```text
tag       := segment (":" segment)+
namespace := premier segment
role      := deuxième segment, si l'espace de noms en déclare
value     := segments restants
```

Exemples valides :

```text
titre:facture-electricite-mars
date:prin:2024-03-17
date:aux:2024-02-28
nom:prin:DUPONT_Marie
nom:prin:MARTIN_Paul
nom:aux:BERNARD_Luc
cat:ordonnance
```

Il n'existe plus de namespace `confiance:`. La confiance est une métadonnée de l'extraction
locale, stockée uniquement dans `.ocr.yml`.

Bornes non configurables : 6 segments, 200 octets par tag et 200 tags retenus par document.
Normalisation : `trim`, suppression d'un `:` final, aucune autre réparation.

### 7.2 `.CONFIG/tags.yml`

```yaml
schema_version: 1
namespaces:
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
      caractérise le document porte le rôle prin, les autres aux. Ces dates
      décrivent le contenu et ne déterminent jamais le dossier de rangement.
      Si le document représente une liste ou un tableau de dates, par exemple
      un document financier, ignore les dates des entrées de cette liste :
      elles ne doivent produire aucun tag date:.
      Exemple :
      date:prin:2024-03-17
    roles: [prin, aux]
    cardinality: { min: 0, max: 12 }
    value_pattern: '^\d{4}-\d{2}-\d{2}$'

  - name: nom
    prompt: |-
      Chaque personne physique concernée, au format NOM_Prenom. Le rôle prin
      désigne une partie au document ; le rôle aux désigne une personne seulement
      mentionnée. Un document peut avoir plusieurs personnes principales ou aucune.
      Si le document représente une liste de personnes, par exemple une liste de
      participants, ignore les personnes énumérées dans cette liste : elles ne
      doivent produire aucun tag nom:.
      Exemples :
      nom:prin:DUPONT_Marie
      nom:prin:MARTIN_Paul
      nom:aux:BERNARD_Luc
    roles: [prin, aux]
    cardinality: { min: 0, max: 8 }
    catalog: persons.yml               # optionnel

  - name: cat
    prompt: |-
      Chaque catégorie applicable au document, parmi les valeurs déclarées
      ci-dessous. Émets le nom complet de chaque valeur retenue.
      Exemple :
      cat:ordonnance
    cardinality: { min: 1, max: 8 }
    values:
      - { name: cat:assurance, description: "Contrats, attestations, garanties et sinistres d'assurance." }
      - { name: cat:banque, description: "Relevés, paiements, crédits, comptes et correspondances bancaires." }
      - { name: cat:caution, description: "Actes de caution et engagements de garant." }
      - { name: cat:consultation, description: "Consultations avec un professionnel de santé." }
      - { name: cat:diagnostic, description: "Diagnostics techniques d'un logement." }
      - { name: cat:education, description: "Scolarité, diplômes, formations et enseignement." }
      - { name: cat:emploi, description: "Contrats de travail, salaires et documents professionnels." }
      - { name: cat:gouvernement, description: "Documents officiels d'une administration publique." }
      - { name: cat:honoraires, description: "Honoraires et paiements de professionnels de santé." }
      - { name: cat:loyer, description: "Quittances, échéances et paiements de loyer." }
      - { name: cat:logement, description: "Baux, états des lieux et documents de logement." }
      - { name: cat:medecine, description: "Santé, soins et suivi médical." }
      - { name: cat:analyse, description: "Analyses biologiques, imagerie et examens médicaux." }
      - { name: cat:ordonnance, description: "Prescriptions de médicaments, soins, matériel ou examens." }
      - { name: cat:passeport, description: "Passeports et pages officielles associées." }
      - { name: cat:recherche, description: "Projets, rapports et publications de recherche." }
      - { name: cat:titre_de_sejour, description: "Titres de séjour et décisions relatives au séjour." }
      - { name: cat:vaccination, description: "Carnets, certificats et historiques de vaccination." }
```

Toutes les catégories et leurs consignes résident dans `tags.yml`. Aucun autre fichier de
catégories n'existe.

### 7.3 Requête `classify`

Le prompt système contient le préambule fixe, le rendu déterministe de `tags.yml` et le format :

```text
Tu reçois le texte extrait d'un document. Émets uniquement les tags justifiés par ce texte.

FORMAT DE SORTIE — impératif :
- une ligne = un tag, rien d'autre
- aucune prose, puce, numérotation ou balise de code
- n'invente aucune valeur
- si tu hésites, omets la valeur

TAGS DISPONIBLES :
<rendu déterministe de tags.yml>
```

La qualité de l'OCR et son score ne figurent pas parmi les tâches du modèle. Le texte et le
prompt peuvent inclure les métadonnées utiles, mais jamais une instruction demandant une
estimation de confiance.

### 7.4 Contrat `.tag.yml`

```yaml
schema_version: 1
source:
  filename: fichier-original.pdf
  sha256: "sha256:9f86d081..."
  added_date: "2026-08-16"
ocr:
  sha256: "sha256:2f77668a..."          # empreinte du fichier .ocr.yml
classification:
  created_at: "2026-08-16T14:32:12+02:00"
  model: claude-opus-5
  prompt_sha256: "sha256:68c46e84..."
tags:
  - cat:ordonnance
  - date:prin:2024-03-17
  - nom:prin:DUPONT_Marie
  - titre:ordonnance-antibiotiques
diagnostics:
  rejected_lines: 0
```

Les tags sont triés lexicographiquement. Le fichier ne duplique ni le texte OCR ni la confiance
locale : son empreinte `ocr.sha256` lie sans ambiguïté la classification à l'artefact OCR.

---

## 8. Évaluation et quarantaine

### 8.1 `.CONFIG/evaluation.yml`

```yaml
schema_version: 1

required:
  - { namespace: titre, min: 1, max: 1 }
  - { namespace: date, role: prin, min: 0, max: 1 }
  - { namespace: nom, role: prin, min: 0 }
  - { namespace: cat, min: 1, max: 8 }

ocr:
  minimum_confidence: 70

unknown_values:
  cat: reject
  nom: propose

parse_quality:
  max_rejected_ratio: 0.5

on_failure:
  low_ocr_confidence: quarantine
  parse_quality: quarantine
  missing_required: quarantine
  unknown_value: quarantine
```

Le seuil OCR est appliqué à `ocr.confidence.value` avant `classify`. Il ne s'agit pas d'un tag.
Si un repli vision est activé, la politique peut autoriser la classification malgré un score
local inférieur au seuil en exigeant `vision_fallback_used: true`.

### 8.2 Disposition de `QUARANTINE`

```text
QUARANTINE/
└── YYYY/MM/DD/
    └── fichier-original.pdf--<short-sha>/
        ├── fichier-original.pdf
        ├── fichier-original.pdf.ocr.yml     # si produit
        ├── fichier-original.pdf.tag.yml     # si produit
        └── report.yml
```

Les YAML restent à côté du document dans son dossier de quarantaine. `report.yml` contient la
phase en échec, les raisons typées, les chemins cibles prévus, les empreintes, le modèle
éventuellement appelé et les lignes rejetées. Aucun élément de quarantaine n'est confondu avec
un triplet rangé.

Une panne HTTP, un manque d'espace, un verrou indisponible ou une interruption ne constituent
pas une erreur documentaire : le fichier reste dans `INBOX` pour une relance sûre.

---

## 9. Transactions, verrouillage et sécurité

- Un verrou `flock` unique protège `sort` et `remove`.
- `extract` et `classify` prennent un verrou de sortie lorsqu'elles ciblent une racine gérée.
- Chaque écriture YAML utilise temporaire adjacent, `fsync`, puis `rename`.
- `sort` ne retire l'original et ses YAML d'`INBOX` qu'après validation du triplet complet.
- Le journal de transaction permet le rollback après interruption.
- Aucun parcours ne suit de lien symbolique.
- Les inventaires sont bornés au dossier attendu ; aucune recherche récursive implicite.
- `remove` refuse tout chemin qui sort des racines résolues ou dont les empreintes croisées ne
  forment pas un triplet cohérent.

État durable hors du dépôt, sous `$XDG_STATE_HOME/tripapiers/` :

```text
executions.db
tripapiers.lock
journal/
```

Aucun état interne ne remplace les fichiers `DOC`, `OCR` et `TAG`, qui restent les autorités.

---

## 10. Invariants

1. La date des chemins est la date d'ajout au système.
2. Un document rangé possède exactement un fichier dans chacune des racines `DOC`, `OCR` et
   `TAG`, sous le même `YYYY/MM/DD` et avec le même nom de base.
3. Les octets de `DOC` sont identiques aux octets ajoutés.
4. `OCR.source.sha256` correspond au document ; `TAG.source.sha256` aussi.
5. `TAG.ocr.sha256` correspond exactement au fichier OCR associé.
6. La confiance est calculée localement et n'est jamais demandée pendant `classify`.
7. Une date trouvée dans le document ne détermine jamais son chemin physique.
8. Aucune vue par raccourci ou lien symbolique n'est créée.
9. Les chemins configurés sont résolus avec la priorité CLI → TOML → défauts.
10. Toute ligne de tag non conforme est ignorée, jamais réparée.
11. Une erreur documentaire terminale produit un dossier complet dans `QUARANTINE`.
12. Une panne d'infrastructure laisse le document dans `INBOX`.
13. `remove` supprime les trois membres d'un triplet ou n'en supprime aucun.
14. Toutes les catégories configurées résident dans `tags.yml`.
15. Les commandes, arguments, clés de configuration et valeurs d'état sont en anglais.

---

## 11. Organisation du code

```text
tripapiers/
├── Cargo.toml
├── crates/
│   ├── core/        # contrats OCR/TAG, empreintes et résolution des triplets
│   ├── config/      # tripapiers.toml, tags.yml, evaluation.yml
│   ├── extract/     # OCR locale, métriques et repli vision
│   ├── classify/    # rendu du prompt, client LLM et analyse des lignes
│   ├── store/       # chemins, écritures atomiques, transactions et suppression
│   ├── pipeline/    # orchestration de sort et quarantaine
│   ├── cli/         # extract, classify, sort, remove, config
│   └── verify/      # composant optionnel et indépendant
└── tests/fixtures/
```

`core`, `config` et l'analyseur de tags ne dépendent d'aucun réseau. `extract` expose un trait
pour substituer les outils OCR dans les tests ; `classify` expose un trait pour substituer le
modèle. `sort` compose exactement ces deux services au lieu de réimplémenter leur logique.

---

## 12. Phases de développement

### Phase 0 — Configuration et contrats

- Parseur de `tripapiers.toml` et priorité des chemins.
- Types `DocumentRef`, `OcrArtifact`, `TagArtifact`, `ManagedTriplet`.
- Validation des noms, dates, racines et empreintes croisées.
- Chargement de `tags.yml` et `evaluation.yml` ; instantané du prompt rendu.

### Phase 1 — `extract` et `classify`

- OCR PDF/images, métriques locales et sérialisation `.ocr.yml`.
- Repli vision optionnel sans estimation de confiance par le modèle.
- Étiquetage ligne par ligne et sérialisation `.tag.yml`.
- Forme chemin, forme `--name` + `--date`, `--output` et `--force`.

### Phase 2 — `sort` et `QUARANTINE`

- Inventaire borné d'`INBOX`, transactions et verrou.
- Rangement atomique du triplet dans `DOC`, `OCR` et `TAG`.
- Collisions, doublons, échecs documentaires et rapports de quarantaine.

### Phase 3 — `remove`

- Résolution sûre des trois fichiers.
- `--dry-run`, confirmation et `--yes`.
- Suppression transactionnelle et nettoyage des dossiers vides.

### Phase 4 — Empaquetage

- Tests d'intégration, page de manuel, complétions shell et unité systemd facultative pour
  appeler `sort` périodiquement.
- Deux profils de distribution : avec ou sans le composant de vérification.

---

## 13. Recette minimale

1. **Configuration** — tester toutes les priorités TOML/CLI, dates invalides, traversées de
   chemin, racines imbriquées et liens symboliques.
2. **Extraction** — PDF natif, scan propre, scan bruité, image, document vide, PDF corrompu et
   document dépassant `max_pages`.
3. **Confiance** — vérifier que le même OCR local produit le même score et qu'aucun prompt de
   `classify` ne demande une confiance au modèle.
4. **Classification** — prose, puces, tags inconnus, doublons, lignes tronquées et listes de
   dates ou de personnes qui ne doivent pas saturer les tags.
5. **Rangement** — vérifier les trois chemins et la même date d'ajout, y compris autour de
   minuit avec une horloge injectée ; couvrir les groupes sans YAML, avec OCR seulement et avec
   OCR plus TAG déjà générés dans `INBOX`.
6. **Quarantaine** — vérifier la présence de l'original, des YAML disponibles et du rapport.
7. **Suppression** — succès complet, membre absent, empreinte divergente et panne injectée à
   chaque déplacement temporaire.
8. **Concurrence** — deux `sort` simultanés et conflit `sort`/`remove`.
9. **Reprise** — interruption à chaque étape, puis rollback ou continuation sans triplet
   partiel.
