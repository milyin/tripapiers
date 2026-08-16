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

La commande `take` choisit une seule valeur `added_date` : `--date` lorsqu'il est fourni, sinon
la date civile courante dans le fuseau local du système. Cette valeur `YYYY-MM-DD` détermine le
chemin sous `DOC`. Les commandes gérées `extract --name … --date …` et
`classify --name … --date …` reprennent obligatoirement la même date pour `OCR` et `TAG`.

En mode autonome avec `<path>`, `extract` utilise la date d'exécution dans le YAML produit et
`classify` reprend la date inscrite dans son entrée OCR. Ces commandes ne déduisent jamais un
mode géré de la position du fichier sur le disque.

### 2.3 Identité et collisions

L'identité stable est le SHA-256 des octets du document. Le nom de fichier sert à résoudre les
chemins, mais ne remplace jamais cette empreinte.

`take` réserve d'abord le seul chemin `DOC/YYYY/MM/DD/<filename>` :

- s'il n'existe pas, l'ajout continue ;
- s'il existe avec le même SHA-256, la commande retourne `already_exists` ;
- s'il existe avec un autre contenu, la commande échoue avec `path_conflict`.

Les états gérés sont volontairement progressifs : `DOC` seul après `take`, `DOC` + `OCR` après
`extract`, puis `DOC` + `OCR` + `TAG` après `classify`. En revanche, `OCR` sans `DOC`, `TAG`
sans `OCR`, un nom divergent ou une empreinte croisée invalide constituent une incohérence.

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

Pour les scripts, `tripapiers config show --format shell` émet les chemins absolus résolus sous
la forme `paths.inbox=<value>`, `paths.quarantine=<value>`, `paths.documents=<value>`,
`paths.ocr=<value>` et `paths.tags=<value>`, une entrée par ligne. Les valeurs ne sont pas du
code shell et ne doivent pas être passées à `eval` ; les retours à la ligne sont interdits dans
les chemins configurés.

Les chemins sont normalisés lexicalement, puis vérifiés après canonicalisation du parent
existant. L'application refuse une racine vide, `/`, un lien symbolique comme racine gérée ou
deux racines pointant vers le même dossier.

---

## 4. Modes d'adressage

Le choix du mode est **syntaxique**. La présence d'un argument positionnel `<path>` sélectionne
le mode autonome ; son absence sélectionne le mode géré. L'application ne déduit jamais le mode
de la position réelle du fichier.

### 4.1 Mode autonome avec `<path>`

Seules `extract` et `classify` acceptent ce mode :

```text
tripapiers extract <path> [--output <path>] [--force]
tripapiers classify <path> [--output <path>] [--force]
```

Dans ce mode, les racines `DOC`, `OCR` et `TAG` sont ignorées pour la résolution de l'entrée et
de la sortie, même si `<path>` se trouve physiquement sous l'une d'elles. Sans `--output` :

- `extract /tmp/rapport.pdf` écrit `/tmp/rapport.pdf.ocr.yml` ;
- `classify /tmp/rapport.pdf.ocr.yml` écrit `/tmp/rapport.pdf.tag.yml`.

`--output` désigne le chemin complet du résultat, nom inclus. `--name` et `--date` sont interdits
avec `<path>`. Les paramètres OCR, le modèle et les vocabulaires restent chargés depuis la
configuration ; seuls le routage `DOC/OCR/TAG` et la résolution gérée sont ignorés.

### 4.2 Mode géré sans `<path>`

Sans argument positionnel, `extract` et `classify` exigent simultanément :

```text
--name <filename> --date <YYYY-MM-DD>
```

| Commande | Entrée | Sortie |
|---|---|---|
| `extract` | `DOC/YYYY/MM/DD/<filename>` | `OCR/YYYY/MM/DD/<filename>.ocr.yml` |
| `classify` | `OCR/YYYY/MM/DD/<filename>.ocr.yml` | `TAG/YYYY/MM/DD/<filename>.tag.yml` |

`--output` est interdit dans ce mode : la sortie est déterminée par les racines configurées.
`--name` n'accepte qu'un nom de base, sans `/`, `..` ou séparateur de plateforme. `--date`
accepte strictement `YYYY-MM-DD` et rejette les dates civiles impossibles.

### 4.3 Cas de `take` et `remove`

`take` exige toujours un `<path>`. Il n'existe pas de seconde forme sans chemin :

```text
tripapiers take <path> [--name <filename>] [--date <YYYY-MM-DD>]
```

Ici, `--name` et `--date` sont des remplacements facultatifs du nom de base et de la date
courante choisis par défaut. Contrairement au mode autonome d'`extract` et `classify`, `take`
utilise toujours la racine `DOC`.

`remove` suit la règle inverse : elle n'accepte jamais de `<path>` et exige toujours la forme
gérée :

```text
tripapiers remove --name <filename> --date <YYYY-MM-DD>
```

### 4.4 Écriture, diagnostic et codes de sortie

`extract` et `classify` écrivent toujours leur résultat complet dans le fichier YAML
correspondant. Elles n'affichent ni le texte OCR ni la liste des tags. Après traitement, stdout
contient uniquement un diagnostic synthétique :

- `extract` : état, chemin du `.ocr.yml`, moteur, langues, confiance locale et taille du texte ;
- `classify` : état, chemin du `.tag.yml`, modèle et nombres de tags acceptés ou de lignes
  rejetées.

En cas d'échec, le diagnostic est écrit sur stderr. Il identifie la phase, la classe d'erreur et
le chemin concerné, sans inclure le contenu documentaire. Le format texte est destiné à
l'utilisateur ; un futur `--format json` pourra exposer les mêmes champs aux scripts.

Les écritures refusent d'écraser un fichier existant, sauf avec `--force`, et passent par un
temporaire adjacent suivi d'un `rename` atomique. Aucun fichier YAML valide n'est laissé après
un échec.

Codes communs :

| Code | Signification |
|---|---|
| `0` | succès |
| `1` | document ou résultat invalide |
| `2` | invocation ou configuration invalide |
| `3` | panne d'infrastructure, d'outil ou de réseau |
| `4` | conflit avec un artefact existant |

---

## 5. Commandes de la première étape

### 5.1 `take`

```text
tripapiers take <path> [--name <filename>] [--date <YYYY-MM-DD>]
```

`take` déplace le fichier vers `DOC/YYYY/MM/DD/<filename>`. Le nom par défaut est le nom de base
de `<path>` et la date par défaut est la date civile courante. Sur le même système de fichiers,
le déplacement utilise `rename` ; sinon, la commande copie, synchronise, vérifie le SHA-256,
puis supprime la source.

En cas de succès, elle affiche au minimum `name`, `date`, `path` et `sha256`. En cas d'échec, la
source reste à sa place. Un fichier cible de même empreinte retourne `already_exists` ; un
contenu différent au même chemin retourne le code `4`. `already_exists` est un succès idempotent
de code `0` : après vérification complète de l'empreinte, la source est retirée conformément à
la sémantique de déplacement de `take`.

### 5.2 `extract`

```text
tripapiers extract <path> [--output <ocr-yaml>] [--force]
tripapiers extract --name <filename> --date <YYYY-MM-DD> [--force]
```

La commande lit un document, exécute l'OCR locale, calcule ses métriques déterministes et écrit
un artefact `.ocr.yml`. Si la confiance locale est inférieure à `ocr.minimum_confidence` et que
`ocr.vision_fallback` est activé, elle peut demander au modèle une transcription de secours.

La confiance enregistrée reste toujours la mesure de l'OCR locale. Elle décide du recours à la
vision, mais le modèle ne reçoit jamais la mission de produire un score de confiance. Après
écriture du `.ocr.yml`, la commande affiche uniquement son diagnostic. Tout échec retourne un
code non nul.

### 5.3 `classify`

```text
tripapiers classify <path> [--output <tag-yaml>] [--force]
tripapiers classify --name <filename> --date <YYYY-MM-DD> [--force]
```

La commande lit exclusivement l'artefact OCR, vérifie son schéma et son empreinte, puis envoie
son champ `text` au modèle avec le vocabulaire rendu depuis `tags.yml`. Le modèle produit une
liste de tags, un par ligne. Il ne juge pas la qualité OCR et n'émet aucun tag de confiance.

Les lignes non conformes sont ignorées, comptées et conservées dans les diagnostics. Les tags
acceptés sont dédupliqués et triés avant la sérialisation du `.tag.yml`. La commande affiche
uniquement son diagnostic, jamais les tags eux-mêmes. Tout échec retourne un code non nul.

### 5.4 `sort`

```text
tripapiers sort
```

`sort` inventorie les fichiers ordinaires directement sous `INBOX`, dans l'ordre
lexicographique. Les sous-dossiers, liens symboliques et fichiers portant les suffixes réservés
`.ocr.yml` ou `.tag.yml` ne sont pas traités comme des documents.

Pour chaque `<path>` trouvé, elle applique exactement cette composition :

```text
take <path>
  on error: move <path> to QUARANTINE

extract --name <name returned by take> --date <date returned by take>
  on error: move available DOC/OCR files to QUARANTINE

classify --name <name returned by take> --date <date returned by take>
  on error: move available DOC/OCR/TAG files to QUARANTINE
```

`sort` appelle les mêmes services internes que les commandes, sans analyser leur affichage.
Après `take`, la source n'est plus dans `INBOX`. À chaque échec, tous les artefacts disponibles
sont déplacés ensemble dans un dossier de `QUARANTINE/YYYY/MM/DD/`, avec `report.yml`. Le
traitement continue avec le fichier suivant. La commande retourne `0` seulement si tous les
fichiers ont atteint l'état `classified` ; sinon elle retourne `1` après avoir traité le lot.

Le script exécutable [`scripts/sort-reference.sh`](../scripts/sort-reference.sh) constitue
l'implémentation Bash de référence de cette composition :

```text
scripts/sort-reference.sh [--config <path>] [--root <path>]
```

Il appelle réellement les trois commandes publiques et produit les mêmes états finaux lorsqu'il
n'est pas interrompu. Il n'est cependant **pas transactionnel** : les états intermédiaires sous
`DOC` et `OCR` sont visibles, et un signal entre deux commandes peut demander une reprise
manuelle.

La commande native `sort` a précisément pour rôle d'exécuter la même logique de manière
transactionnelle. Elle prend le verrou global, dirige les opérations internes de `take`,
`extract` et `classify` vers un staging privé, journalise chaque transition, puis rend visible
en une seule validation soit l'état `DOC+OCR+TAG`, soit l'ensemble correspondant dans
`QUARANTINE`. Après une interruption, la reprise termine cette validation ou restaure l'état
antérieur ; aucun état intermédiaire non journalisé n'est laissé visible.

### 5.5 `remove`

```text
tripapiers remove --name <filename> --date <YYYY-MM-DD>
```

`remove` n'accepte aucun argument positionnel. Elle résout puis affiche les membres présents :

```text
DOC/YYYY/MM/DD/<filename>
OCR/YYYY/MM/DD/<filename>.ocr.yml
TAG/YYYY/MM/DD/<filename>.tag.yml
```

La suppression accepte les états progressifs `DOC`, `DOC+OCR` et `DOC+OCR+TAG`, mais refuse un
ensemble orphelin. Elle est transactionnelle : tous les membres présents sont d'abord renommés
vers un dossier temporaire privé situé sur le même système de fichiers ; ils ne sont effacés
qu'une fois tous les déplacements réussis. En cas d'échec intermédiaire, le rollback les remet
en place. `--yes` supprime la confirmation interactive ; `--dry-run` n'effectue aucune mutation.
Les dossiers de date devenus vides sont retirés jusqu'à leur racine gérée.

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
  low_ocr_confidence: error
  parse_quality: error
  missing_required: error
  unknown_value: error
```

Le seuil OCR est appliqué à `ocr.confidence.value` avant `classify`. Il ne s'agit pas d'un tag.
Si un repli vision est activé, la politique peut autoriser la classification malgré un score
local inférieur au seuil en exigeant `vision_fallback_used: true`. L'évaluation retourne un
échec à l'appelant ; elle ne déplace elle-même aucun fichier. En mode autonome ou lors d'un appel
géré direct, l'entrée reste en place. Seule `sort` transforme cet échec en déplacement vers
`QUARANTINE`.

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

Lorsqu'elle est pilotée par `sort`, toute classe d'échec — résultat invalide, panne HTTP, manque
d'espace ou erreur d'outil — déplace les artefacts alors disponibles vers cette disposition.
Lorsqu'`extract` ou `classify` est appelée directement, elle ne met rien en quarantaine : elle
préserve son entrée, retire tout résultat temporaire et retourne un code non nul.

---

## 9. Transactions, verrouillage et sécurité

- Un verrou `flock` unique protège `take`, `sort` et `remove`.
- `extract` et `classify` prennent le verrou lorsqu'elles sont invoquées sans `<path>` en mode
  géré. Le mode autonome ne verrouille que son fichier de sortie.
- Chaque écriture YAML utilise temporaire adjacent, `fsync`, puis `rename`.
- `sort` applique `take`, `extract` et `classify` dans un staging privé, puis valide en une fois
  le triplet classé ou l'ensemble mis en quarantaine.
- Le journal de transaction permet le rollback après interruption.
- Aucun parcours ne suit de lien symbolique.
- Les inventaires sont bornés au dossier attendu ; aucune recherche récursive implicite.
- `remove` refuse toute résolution qui sort des racines ou forme un ensemble orphelin.

État durable hors du dépôt, sous `$XDG_STATE_HOME/tripapiers/` :

```text
executions.db
tripapiers.lock
journal/
```

Aucun état interne ne remplace les fichiers `DOC`, `OCR` et `TAG`, qui restent les autorités.

---

## 10. Invariants

1. La date des chemins est celle choisie par `take`, jamais une date extraite du document.
2. Un ensemble géré est préfixe-complet : `DOC`, puis éventuellement `OCR`, puis éventuellement
   `TAG`, toujours sous le même `YYYY/MM/DD` et avec le même nom de base.
3. Les octets de `DOC` sont identiques aux octets ajoutés.
4. `OCR.source.sha256` correspond au document ; `TAG.source.sha256` aussi.
5. `TAG.ocr.sha256` correspond exactement au fichier OCR associé.
6. La confiance est calculée localement et n'est jamais demandée pendant `classify`.
7. Une date trouvée dans le document ne détermine jamais son chemin physique.
8. Aucune vue par raccourci ou lien symbolique n'est créée.
9. Les chemins configurés sont résolus avec la priorité CLI → TOML → défauts.
10. Toute ligne de tag non conforme est ignorée, jamais réparée.
11. Tout échec d'une étape de `sort` déplace ensemble les artefacts disponibles dans
    `QUARANTINE`.
12. `take` laisse la source à sa place s'il échoue et la retire après une prise en charge réussie.
13. `remove` supprime tous les membres présents d'un ensemble cohérent ou n'en supprime aucun.
14. Toutes les catégories configurées résident dans `tags.yml`.
15. Les commandes, arguments, clés de configuration et valeurs d'état sont en anglais.
16. Avec `<path>`, `extract` et `classify` ignorent toujours le routage `DOC/OCR/TAG`.
17. Sans `<path>`, `extract`, `classify` et `remove` exigent `--name` et `--date`.
18. `remove` n'accepte jamais d'argument positionnel.

---

## 11. Organisation du code

```text
tripapiers/
├── Cargo.toml
├── scripts/
│   └── sort-reference.sh
├── crates/
│   ├── core/        # contrats OCR/TAG, empreintes et résolution des triplets
│   ├── config/      # tripapiers.toml, tags.yml, evaluation.yml
│   ├── extract/     # OCR locale, métriques et repli vision
│   ├── classify/    # rendu du prompt, client LLM et analyse des lignes
│   ├── store/       # chemins, écritures atomiques, transactions et suppression
│   ├── pipeline/    # orchestration de sort et quarantaine
│   ├── cli/         # take, extract, classify, sort, remove, config
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

### Phase 1 — `take`, `extract` et `classify`

- Ajout transactionnel dans `DOC`, avec remplacement facultatif du nom et de la date.
- OCR PDF/images, métriques locales et sérialisation `.ocr.yml`.
- Repli vision optionnel sans estimation de confiance par le modèle.
- Étiquetage ligne par ligne et sérialisation `.tag.yml`.
- Sélection syntaxique du mode autonome ou géré, `--output`, diagnostics et codes de sortie.

### Phase 2 — `sort` et `QUARANTINE`

- Inventaire borné d'`INBOX`, transactions et verrou.
- Composition séquentielle `take` → `extract` → `classify`.
- Déplacement des artefacts disponibles à chaque échec et rapports de quarantaine.
- Tests de conformité entre le script Bash de référence et la commande native sur les mêmes
  scénarios sans interruption.

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
2. **Ajout** — nom et date par défaut, remplacements `--name`/`--date`, autre système de fichiers,
   doublon exact et conflit de contenu.
3. **Extraction** — PDF natif, scan propre, scan bruité, image, document vide, PDF corrompu et
   document dépassant `max_pages`.
4. **Confiance** — vérifier que le même OCR local produit le même score et qu'aucun prompt de
   `classify` ne demande une confiance au modèle.
5. **Classification** — prose, puces, tags inconnus, doublons, lignes tronquées et listes de
   dates ou de personnes qui ne doivent pas saturer les tags.
6. **Modes** — prouver qu'un `<path>` impose toujours la sortie adjacente ou `--output`, même
   sous une racine gérée, et que son absence exige `--name` avec `--date`.
7. **Affichage** — diagnostic seul sur stdout en cas de succès et sur stderr en cas d'échec ;
   absence du texte OCR et des tags ; codes non nuls pour chaque classe d'échec.
8. **Rangement** — injecter un échec après `take`, après `extract` et pendant `classify`, puis
   vérifier les artefacts exacts déplacés dans `QUARANTINE`.
9. **Équivalence** — exécuter le script Bash et `sort` sur deux copies du même corpus sans
   interruption, puis comparer `DOC`, `OCR`, `TAG`, `QUARANTINE`, diagnostics et codes de sortie.
10. **Transaction** — interrompre `sort` à chaque transition et vérifier qu'aucun staging n'est
    visible ; documenter que ce test ne s'applique pas au script de référence.
11. **Quarantaine** — vérifier la présence des artefacts disponibles et du rapport.
12. **Suppression** — états `DOC`, `DOC+OCR`, `DOC+OCR+TAG`, ensemble orphelin et panne injectée à
   chaque déplacement temporaire.
13. **Concurrence** — deux `sort` simultanés et conflit `sort`/`remove`.
14. **Reprise** — interruption à chaque étape, puis reprise sans ensemble orphelin.
