# tripapiers — traitement des fichiers

> **Composant principal.** Ce document décrit la première version de l'application : extraction
> OCR, étiquetage, rangement et suppression. Aucun index par raccourcis ou liens symboliques
> n'est construit. L'audit indépendant, encore au stade de brouillon, est décrit dans
> [`verification.md`](verification.md).

---

## 1. Objectif et périmètre

`tripapiers` est une application locale de classement documentaire. Un fichier arrive dans
`INBOX`, reçoit une représentation OCR, puis les expressions régulières de `tags.yml` lui
attribuent mécaniquement un ensemble de tags. Les trois artefacts sont rangés sous des racines
séparées :

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

[vision]
model = "claude-opus-5"

[database]
path = "tripapiers.db"
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
--database <path>
```

`--root` remplace la base de résolution des valeurs relatives. Les arguments `--*-dir`
remplacent ensuite une racine précise. La configuration effectivement résolue peut être
affichée par `tripapiers config show` et validée par `tripapiers config check`.

Le chemin SQLite relatif est résolu selon la même règle que les racines. Les chemins sont
normalisés lexicalement, puis vérifiés après canonicalisation du parent
existant. L'application refuse une racine vide, `/`, un lien symbolique comme racine gérée ou
deux racines pointant vers le même dossier. Les chemins configurés ne peuvent contenir ni
retour à la ligne ni caractère de contrôle.

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
avec `<path>`. Les paramètres OCR, les règles et la base SQLite restent chargés depuis la
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
`--name` n'accepte qu'un nom de base, sans `/`, `..`, séparateur de plateforme, retour à la
ligne ou caractère de contrôle. `--date` accepte strictement `YYYY-MM-DD` et rejette les dates
civiles impossibles.

### 4.3 Cas de `take` et `remove`

`take` exige toujours un `<path>`. Il n'existe pas de seconde forme sans chemin :

```text
tripapiers take <path> [--name <filename>] [--date <YYYY-MM-DD>]
  [--quarantine-on-error]
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
- `classify` : état, chemin du `.tag.yml`, empreinte des règles, nombre de regex évaluées et
  nombre de tags émis.

En cas d'échec, le diagnostic est écrit sur stderr. Il identifie la phase, la classe d'erreur et
le chemin concerné, sans inclure le contenu documentaire. Le format texte est destiné à
l'utilisateur ; un futur `--format json` pourra exposer les mêmes champs aux scripts.

Les écritures refusent d'écraser un fichier existant, sauf avec `--force`, et passent par un
temporaire adjacent suivi d'un `rename` atomique. Aucun fichier YAML valide n'est laissé après
un échec.

En mode géré, `take`, `extract` et `classify` acceptent l'option commune
`--quarantine-on-error`. Si l'opération échoue, la commande déplace elle-même tous les artefacts
alors disponibles dans `QUARANTINE` et écrit `report.yml`. La commande conserve son code d'échec
initial ; une panne de mise en quarantaine est ajoutée au diagnostic. Une erreur d'invocation ou
de configuration est détectée avant toute mutation et ne déclenche pas la quarantaine. Cette
option est interdite dans le mode autonome de `extract` et `classify`, puisque ce mode ignore les
racines gérées.

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

### 5.1 `inbox`

```text
tripapiers inbox
```

`inbox` affiche les chemins absolus des documents admissibles directement présents sous
`INBOX`, un par ligne et dans l'ordre lexicographique. Elle ignore les sous-dossiers, les liens
symboliques et les suffixes réservés `.ocr.yml` et `.tag.yml`. Les retours à la ligne étant
interdits dans les noms gérés, cette sortie peut être parcourue sans ambiguïté par un script
Bash. La commande ne modifie aucun fichier.

### 5.2 `take`

```text
tripapiers take <path> [--name <filename>] [--date <YYYY-MM-DD>]
  [--quarantine-on-error]
```

`take` déplace le fichier vers `DOC/YYYY/MM/DD/<filename>`. Le nom par défaut est le nom de base
de `<path>` et la date par défaut est la date civile courante. Sur le même système de fichiers,
le déplacement utilise `rename` ; sinon, la commande copie, synchronise, vérifie le SHA-256,
puis supprime la source.

En cas de succès, elle affiche au minimum `name`, `date`, `path` et `sha256`. En cas d'échec, la
source reste à sa place, sauf si `--quarantine-on-error` demande explicitement son déplacement.
Un fichier cible de même empreinte retourne `already_exists` ; un contenu différent au même
chemin retourne le code `4`. `already_exists` est un succès idempotent de code `0` : après
vérification complète de l'empreinte, la source est retirée conformément à la sémantique de
déplacement de `take`.

### 5.3 `extract`

```text
tripapiers extract <path> [--output <ocr-yaml>] [--force]
tripapiers extract --name <filename> --date <YYYY-MM-DD> [--force]
  [--quarantine-on-error]
```

La commande lit un document, exécute l'OCR locale, calcule ses métriques déterministes et écrit
un artefact `.ocr.yml`. Si la confiance locale est inférieure à `ocr.minimum_confidence` et que
`ocr.vision_fallback` est activé, elle peut demander au modèle une transcription de secours.

La confiance enregistrée reste toujours la mesure de l'OCR locale. Elle décide du recours à la
vision, mais le modèle ne reçoit jamais la mission de produire un score de confiance. Après
écriture du `.ocr.yml`, la commande affiche uniquement son diagnostic. Tout échec retourne un
code non nul.

### 5.4 `classify`

```text
tripapiers classify <path> [--output <tag-yaml>] [--force]
tripapiers classify --name <filename> --date <YYYY-MM-DD> [--force]
  [--quarantine-on-error]
```

La commande lit l'artefact OCR, vérifie son schéma et son empreinte, puis retrouve son texte dans
SQLite par `ocr_sha256`. Elle compile les expressions régulières de `tags.yml`, les applique au
texte exact et émet les tags dont au moins une règle correspond. Elle n'appelle aucun modèle et
n'utilise aucun réseau.

Les tags sont dédupliqués, triés et évalués par `evaluation.yml` avant la sérialisation du
`.tag.yml`. La commande conserve pour chaque tag l'empreinte de la règle et la première plage
d'octets correspondante. Elle affiche uniquement son diagnostic, jamais le texte, les tags ni
les extraits correspondants. Une regex invalide est une erreur de configuration et tout échec
retourne un code non nul.

En mode géré, une classification initiale crée aussi une session de revue `pending` pour le
nouveau document. Les violations de cardinalité sont alors consignées comme points à résoudre,
sans faire échouer la commande ni déclencher la quarantaine. Cette insertion SQLite est
mécanique et n'attend pas l'agent. Une reclassification lancée depuis une session de règles ne
crée pas récursivement une autre session ; sa publication reste interdite tant qu'une violation
subsiste. La création est idempotente pour le triplet `(document, ocr_sha256, rules_sha256)`.
En mode autonome, aucune session n'est créée et les violations restent des erreurs.

### 5.5 `sort`

```text
tripapiers sort
```

`sort` utilise le même inventaire que `inbox`.

Pour chaque `<path>` trouvé, elle applique exactement cette composition :

```text
take <path> --name <name> --date <date> --quarantine-on-error

extract --name <name> --date <date> --quarantine-on-error

classify --name <name> --date <date> --quarantine-on-error
```

`sort` appelle les mêmes services internes que les commandes, sans analyser leur affichage.
Après `take`, la source n'est plus dans `INBOX`. À chaque échec, tous les artefacts disponibles
sont déplacés ensemble dans un dossier de `QUARANTINE/YYYY/MM/DD/`, avec `report.yml`. Le
traitement continue avec le fichier suivant. La commande retourne `0` seulement si tous les
fichiers ont atteint l'état `classified` ; sinon elle retourne `1` après avoir traité le lot.
Une session de règles `pending` n'est pas un échec de classement et ne déclenche pas la
quarantaine ; elle indique seulement que l'agent doit encore confirmer ou améliorer les regex.

Le script exécutable [`scripts/sort-reference.sh`](../scripts/sort-reference.sh) constitue
l'implémentation Bash pédagogique de cette composition :

```text
scripts/sort-reference.sh [<global-options>...]
```

Les primitives `inbox` et `--quarantine-on-error` gardent dans l'application les détails de
configuration, de sélection, de dérivation des chemins, de rapport YAML et de déplacement. Le
script peut ainsi montrer uniquement la logique métier. Il appelle réellement les trois
commandes publiques et produit les mêmes états finaux lorsqu'il n'est pas interrompu. Il n'est
cependant **pas transactionnel** : les états intermédiaires sous `DOC` et `OCR` sont visibles,
et un signal entre deux commandes peut demander une reprise manuelle.

Les arguments reçus par le script sont transmis tels quels comme arguments globaux de chaque
appel à `tripapiers` ; la CLI reste donc l'unique responsable de leur validation.

La commande native `sort` a précisément pour rôle d'exécuter la même logique de manière
transactionnelle. Elle prend le verrou global, dirige les opérations internes de `take`,
`extract` et `classify` vers un staging privé, journalise chaque transition, puis rend visible
en une seule validation soit l'état `DOC+OCR+TAG`, soit l'ensemble correspondant dans
`QUARANTINE`. Après une interruption, la reprise termine cette validation ou restaure l'état
antérieur ; aucun état intermédiaire non journalisé n'est laissé visible.

### 5.6 `remove`

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
en place. La même transaction retire le texte OCR actif de SQLite ; l'historique conserve
seulement un identifiant marqué comme supprimé, sans contenu documentaire. `--yes` supprime la
confirmation interactive ; `--dry-run` n'effectue aucune mutation. Les dossiers de date devenus
vides sont retirés jusqu'à leur racine gérée.

### 5.7 `rules`

```text
tripapiers rules begin --name <filename> --date <YYYY-MM-DD>
tripapiers rules expect --session <id> [--tag <tag>]...
tripapiers rules check --session <id>
tripapiers rules run --session <id>
tripapiers rules diff --session <id> [--format text|json]
tripapiers rules show --session <id> --document <id> [--full-text]
tripapiers rules decide --session <id> --change <id> --accept|--reject --reason <text>
tripapiers rules commit --session <id>
tripapiers rules abort --session <id>
```

Ces commandes maintiennent une révision candidate sans modifier la classification acceptée
avant `commit`. Leur protocole est défini dans
[`evolution-des-regles.md`](evolution-des-regles.md).

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

### 6.3 Copie SQLite du texte

Après l'écriture atomique d'un `.ocr.yml`, `extract` insère dans SQLite son texte exact, son
`ocr_sha256`, l'empreinte du document, le nom et la date d'ajout. Cette règle s'applique aussi au
mode autonome ; un artefact OCR externe présenté directement à `classify` est validé puis inséré
avant son classement. Une même empreinte OCR est idempotente et ne duplique pas le texte.

La publication du YAML et de sa ligne SQLite est journalisée. `extract` ne retourne un succès
qu'après les deux écritures ; après une interruption, la reprise termine l'insertion ou retire
le YAML non validé.

Le fichier OCR reste l'autorité. Une entrée SQLite absente ou incohérente est reconstruite depuis
le YAML avant `classify`; une divergence d'empreinte est une erreur et n'est jamais masquée par
la base. Cette copie rend possible la reclassification rapide de tout le corpus sans reparcourir
les fichiers YAML à chaque essai de règles.

---

## 7. Classification mécanique

### 7.1 Grammaire des tags

```text
tag       := segment (":" segment)+
namespace := premier segment
value     := segments restants
```

Exemples valides :

```text
cat:medecine:ordonnance
date:prin:2024-03-17
nom:IVAN_Petrov
nom:DUPONT_Jean
titre:ordonnance
```

Il n'existe pas de namespace `confiance:`. La confiance reste une métadonnée de l'extraction
locale, stockée uniquement dans `.ocr.yml`. Bornes non configurables : 6 segments, 200 octets
par tag et 200 tags retenus par document. Aucun tag n'est réparé ou inventé après l'application
des règles.

### 7.2 `.CONFIG/tags.yml`

`tags.yml` est une arborescence dont chaque liste non vide est une feuille. Le chemin d'une
feuille sous la clé racine `tags`, sans inclure cette clé, définit le tag statique émis
lorsqu'au moins une de ses règles correspond.

```yaml
schema_version: 2
tags:
  cat:
    administration:
      document:
        - regexp: '/\b(r[ée]publique\s+fran[çc]aise|service\s+public)\b/i'
      passeport:
        - regexp: '/\bpasseport\b/i'
      titre_de_sejour:
        - regexp: '/\btitre\s+de\s+s[ée]jour\b/i'
    assurance:
      - regexp: '/\b(assurance|assur[ée]|police\s+d.assurance)\b/i'
    banque:
      - regexp: '/\b(iban|bic|relev[ée]\s+de\s+compte|banque)\b/i'
    education:
      - regexp: '/\b(dipl[oô]me|certificat\s+de\s+scolarit[ée]|universit[ée])\b/i'
    emploi:
      - regexp: '/\b(contrat\s+de\s+travail|bulletin\s+de\s+paie|employeur)\b/i'
    logement:
      bail:
        - regexp: '/\b(bail|contrat\s+de\s+location)\b/i'
      caution:
        - regexp: '/\b(acte\s+de\s+caution|engagement\s+de\s+garant)\b/i'
      diagnostic:
        - regexp: '/\b(diagnostic\s+de\s+performance\s+[ée]nerg[ée]tique|DPE)\b/i'
      etat_des_lieux:
        - regexp: '/\b[ée]tat\s+des\s+lieux\b/i'
      loyer:
        - regexp: '/\b(quittance\s+de\s+loyer|loyer)\b/i'
    medecine:
      analyse:
        - regexp: '/\b(analyse\s+biologique|r[ée]sultats?\s+d.analyse|laboratoire)\b/i'
      consultation:
        - regexp: '/\bconsultation\s+(m[ée]dicale|chez\s+le\s+m[ée]decin)\b/i'
      honoraire:
        - regexp: '/\b(note\s+d.honoraires?|honoraires?\s+m[ée]dicaux?)\b/i'
      ordonnance:
        - regexp: '/\b(ordonnance|prescription\s+m[ée]dicale)\b/i'
      suivi:
        - regexp: '/\b(dossier\s+m[ée]dical|suivi\s+m[ée]dical)\b/i'
      vaccination:
        - regexp: '/\b(vaccin|vaccination|certificat\s+de\s+vaccination)\b/i'
    recherche:
      - regexp: '/\b(projet\s+de\s+recherche|rapport\s+de\s+recherche|publication\s+scientifique)\b/i'

  date:
    prin:
      - regexp: '/\bdate\s*:\s*(?P<value>\d{4}-\d{2}-\d{2})\b/i'
        emit: 'date:prin:${value}'

  nom:
    IVAN_Petrov:
      - regexp: '/\bIvan\s+Petrov\b/i'
      - regexp: '/\bPetrov\s+Ivan\b/i'
    DUPONT_Jean:
      - regexp: '/\bJean\s+Dupont\b/i'
      - regexp: '/\bDupont\s+Jean\b/i'

  titre:
    ordonnance:
      - regexp: '/\b(ordonnance|prescription\s+m[ée]dicale)\b/i'
```

Sans `emit`, une correspondance sous `tags.cat.medecine.ordonnance` émet
`cat:medecine:ordonnance`. `emit` permet un tag dynamique : seules les captures nommées de la
regex peuvent être interpolées, puis le résultat doit respecter la grammaire et les bornes des
tags. Une règle dynamique produit une valeur distincte par capture distincte.

Le champ `regexp` emploie la notation `/motif/flags`. Les `/` internes sont échappés par `\/` et
les seuls flags admis sont `i`, `m`, `s` et `x`, sans doublon. Le moteur Unicode choisi garantit
un temps linéaire ; les références arrière et les assertions avant ou arrière ne sont donc pas
acceptées. Les clés YAML respectent `^[A-Za-z0-9][A-Za-z0-9_-]*$`. Les clés dupliquées, groupes
vides, listes vides, champs inconnus, regex invalides et gabarits `emit` sans capture déclarée
sont des erreurs de configuration. Un motif ne peut pas correspondre à la chaîne vide ni
dépasser 4 096 octets ; sa taille compilée est bornée à 10 Mio.

Les règles d'une même feuille sont un OU logique. Les groupes ne sont jamais des tags. Le
chargeur trie les chemins, puis les couples `(regexp, emit)` avant de produire l'empreinte
canonique `rules_sha256`; l'ordre écrit dans YAML n'influence donc ni le résultat ni l'empreinte.

### 7.3 Algorithme de `classify`

1. Charger, valider et compiler toute la révision de `tags.yml`.
2. Résoudre l'artefact OCR et vérifier sa copie SQLite par `ocr_sha256`.
3. Appliquer toutes les regex au texte UTF-8 exact, sans prétraitement supplémentaire.
4. Émettre le chemin statique ou développer le gabarit `emit` pour chaque correspondance.
5. Dédupliquer et trier les tags ; pour leur provenance, retenir la première plage d'octets,
   puis la plus petite empreinte de règle en cas d'égalité.
6. Appliquer les cardinalités d'`evaluation.yml` et écrire le `.tag.yml` atomiquement.

Une même entrée et les mêmes empreintes OCR et `tags.yml` produisent toujours les mêmes tags.
`classify` ne possède aucun client de modèle et ne fait aucun appel réseau.

### 7.4 Contrat `.tag.yml`

```yaml
schema_version: 2
source:
  filename: fichier-original.pdf
  sha256: "sha256:9f86d081..."
  added_date: "2026-08-16"
ocr:
  sha256: "sha256:2f77668a..."          # empreinte du fichier .ocr.yml
classification:
  created_at: "2026-08-16T14:32:12+02:00"
  engine: regexp
  engine_version: "regex-1"
  rules_sha256: "sha256:68c46e84..."
  run_id: 42
  review_status: pending              # pending | accepted
tags:
  - cat:medecine:ordonnance
  - date:prin:2024-03-17
  - nom:IVAN_Petrov
  - titre:ordonnance
matches:
  - tag: cat:medecine:ordonnance
    rule_sha256: "sha256:a5ab10..."
    start_byte: 18
    end_byte: 28
  - tag: date:prin:2024-03-17
    rule_sha256: "sha256:b6bc21..."
    start_byte: 42
    end_byte: 58
  - tag: nom:IVAN_Petrov
    rule_sha256: "sha256:c7cd32..."
    start_byte: 72
    end_byte: 83
  - tag: titre:ordonnance
    rule_sha256: "sha256:d8de43..."
    start_byte: 18
    end_byte: 28
diagnostics:
  regex_evaluated: 25
  regex_matched: 4
  tags_emitted: 4
  evaluation_issues: []
```

Les tags et les entrées `matches` sont triés lexicographiquement. Une entrée `matches` est
conservée par tag et ne contient aucun extrait du document. Le fichier ne duplique ni le texte
OCR ni la confiance locale : son empreinte `ocr.sha256` lie sans ambiguïté la classification à
l'artefact OCR.

### 7.5 Évolution des règles

Un agent peut proposer des regex, mais il ne peut pas affecter directement les tags. Chaque
candidate est appliquée à l'ensemble de l'instantané SQLite et comparée à la dernière révision
acceptée. La boucle, les décisions de régression et la publication transactionnelle sont
définies dans [`evolution-des-regles.md`](evolution-des-regles.md).

---

## 8. Évaluation et quarantaine

### 8.1 `.CONFIG/evaluation.yml`

```yaml
schema_version: 1

required:
  - { namespace: titre, min: 1, max: 1 }
  - { namespace: date, role: prin, min: 0, max: 1 }
  - { namespace: nom, min: 0, max: 8 }
  - { namespace: cat, min: 1, max: 8 }

ocr:
  minimum_confidence: 70

on_failure:
  low_ocr_confidence: error
  missing_required: error
  cardinality_violation: error

pending_review:
  missing_required: allow
  cardinality_violation: allow
```

Le seuil OCR est appliqué à `ocr.confidence.value` avant `classify`. Il ne s'agit pas d'un tag.
Si un repli vision est activé, la politique peut autoriser la classification malgré un score
local inférieur au seuil en exigeant `vision_fallback_used: true`. L'évaluation retourne un
échec à l'appelant hors classification initiale en attente de revue ; elle ne déplace elle-même
aucun fichier. En mode autonome ou lors d'un appel géré direct sans
`--quarantine-on-error`, l'entrée reste en place. `sort` transforme les véritables échecs en
déplacement vers `QUARANTINE`, mais conserve l'état `pending` prévu par la politique ci-dessus.

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
phase en échec, les raisons typées, les chemins cibles prévus, les empreintes, le moteur OCR
éventuellement appelé, l'empreinte des règles et les regex responsables. Aucun élément de
quarantaine n'est confondu avec un triplet rangé.

Lorsqu'elle est pilotée par `sort`, toute classe d'échec — résultat invalide, panne HTTP, manque
d'espace ou erreur d'outil — déplace les artefacts alors disponibles vers cette disposition.
Lorsqu'`extract` ou `classify` est appelée directement sans `--quarantine-on-error`, elle ne met
rien en quarantaine : elle préserve son entrée, retire tout résultat temporaire et retourne un
code non nul.

---

## 9. Transactions, verrouillage et sécurité

- Un verrou `flock` unique protège `take`, `sort` et `remove`.
- `extract` et `classify` prennent le verrou lorsqu'elles sont invoquées sans `<path>` en mode
  géré. Le mode autonome ne verrouille que son fichier de sortie.
- `rules commit` prend le verrou global ; les essais et la revue utilisent un instantané SQLite
  sans conserver ce verrou pendant le travail de l'agent.
- SQLite utilise le mode WAL avec un seul écrivain. La base, `-wal` et `-shm` sont créés avec le
  mode `0600`; `secure_delete` est activé et `remove` termine par un checkpoint tronqué.
- Chaque écriture YAML utilise temporaire adjacent, `fsync`, puis `rename`.
- `sort` applique `take`, `extract` et `classify` dans un staging privé, puis valide en une fois
  le triplet classé ou l'ensemble mis en quarantaine.
- Le journal de transaction permet le rollback après interruption.
- Aucun parcours ne suit de lien symbolique.
- Les inventaires sont bornés au dossier attendu ; aucune recherche récursive implicite.
- `remove` refuse toute résolution qui sort des racines ou forme un ensemble orphelin.

État durable hors du dépôt, par défaut sous `$XDG_STATE_HOME/tripapiers/` :

```text
tripapiers.db
tripapiers.lock
journal/
```

Le chemin de `tripapiers.db` peut être remplacé par la configuration ou `--database`. Aucun état
interne ne remplace les fichiers `DOC`, `OCR`, `TAG` et `tags.yml`, qui restent les autorités.

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
10. Chaque tag provient d'une regex compilée de `tags.yml`; `classify` n'en invente et n'en
    répare aucun.
11. Tout échec d'une étape de `sort` déplace ensemble les artefacts disponibles dans
    `QUARANTINE`.
12. Sans `--quarantine-on-error`, `take` laisse la source à sa place s'il échoue ; après une
    prise en charge réussie, elle la retire.
13. `remove` supprime tous les membres présents d'un ensemble cohérent ou n'en supprime aucun.
14. Toutes les catégories configurées sont des feuilles de règles de l'arborescence `tags.yml` ;
    ses groupes ne sont jamais des tags valides.
15. Les commandes, arguments, clés de configuration et valeurs d'état sont en anglais.
16. Avec `<path>`, `extract` et `classify` ignorent toujours le routage `DOC/OCR/TAG`.
17. Sans `<path>`, `extract`, `classify` et `remove` exigent `--name` et `--date`.
18. `remove` n'accepte jamais d'argument positionnel.
19. Chaque texte OCR possède une copie SQLite liée par l'empreinte du `.ocr.yml`.
20. Une révision de règles ne devient active qu'après reclassification et revue de tout
    l'instantané du corpus.
21. À empreintes OCR et de règles identiques, la classification est identique.

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
│   ├── classify/    # compilation des regex, affectation et provenance des tags
│   ├── rules/       # sessions agent, différences, décisions et publication
│   ├── database/    # textes OCR, révisions et classifications SQLite
│   ├── store/       # chemins, écritures atomiques, transactions et suppression
│   ├── pipeline/    # orchestration de sort et quarantaine
│   ├── cli/         # inbox, take, extract, classify, sort, remove, rules, config
│   └── verify/      # composant optionnel et indépendant
└── tests/fixtures/
```

`core`, `config` et `classify` ne dépendent d'aucun réseau. `extract` expose un trait pour
substituer les outils OCR dans les tests. Le client de modèle éventuel appartient uniquement au
repli vision et à l'agent du crate `rules`; il n'est pas une dépendance de `classify`. `sort`
compose exactement les services d'extraction et de classification au lieu de réimplémenter leur
logique.

---

## 12. Phases de développement

### Phase 0 — Configuration et contrats

- Parseur de `tripapiers.toml` et priorité des chemins.
- Types `DocumentRef`, `OcrArtifact`, `TagArtifact`, `ManagedTriplet`.
- Validation des noms, dates, racines et empreintes croisées.
- Chargement de l'arborescence `tags.yml`, compilation et empreinte canonique de ses regex ;
  chargement d'`evaluation.yml`.
- Schéma SQLite, migrations et reconstruction depuis les artefacts visibles.

### Phase 1 — `inbox`, `take`, `extract` et `classify`

- Inventaire public et non destructif avec `inbox`.
- Ajout transactionnel dans `DOC`, avec remplacement facultatif du nom et de la date.
- OCR PDF/images, métriques locales et sérialisation `.ocr.yml`.
- Repli vision optionnel sans estimation de confiance par le modèle.
- Copie de chaque texte OCR dans SQLite avec vérification d'empreinte.
- Classification mécanique, provenance des correspondances et sérialisation `.tag.yml`.
- Sélection syntaxique du mode autonome ou géré, `--output`, diagnostics et codes de sortie.
- Mise en quarantaine commune avec `--quarantine-on-error` en mode géré.

### Phase 2 — évolution des règles

- Sessions candidates, compilation et classification de l'instantané complet.
- Différences par document, décisions de l'agent et invalidation après chaque modification.
- Publication transactionnelle de `tags.yml`, des `.tag.yml` modifiés et de la révision SQLite.

### Phase 3 — `sort` et `QUARANTINE`

- Inventaire borné d'`INBOX`, transactions et verrou.
- Composition séquentielle `take` → `extract` → `classify`.
- Déplacement des artefacts disponibles à chaque échec et rapports de quarantaine.
- Tests de conformité entre le script Bash de référence et la commande native sur les mêmes
  scénarios sans interruption.

### Phase 4 — `remove`

- Résolution sûre des trois fichiers.
- `--dry-run`, confirmation et `--yes`.
- Suppression transactionnelle et nettoyage des dossiers vides.

### Phase 5 — Empaquetage

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
4. **Confiance** — vérifier que le même OCR local produit le même score et que `classify`
   n'appelle aucun modèle ni réseau.
5. **Regex** — feuilles statiques et dynamiques, captures `emit`, flags, Unicode, règles
   invalides, groupes non sélectionnables, déduplication et ordre déterministe.
6. **SQLite** — insertion idempotente de tous les textes OCR, divergence d'empreinte et
   reconstruction complète depuis les YAML.
7. **Régression** — règle ciblée, règle trop large, ajout et suppression de tags anciens,
   décisions invalidées après modification et corpus rendu obsolète pendant la revue.
8. **Modes** — prouver qu'un `<path>` impose toujours la sortie adjacente ou `--output`, même
   sous une racine gérée, et que son absence exige `--name` avec `--date`.
9. **Affichage** — diagnostic seul sur stdout en cas de succès et sur stderr en cas d'échec ;
   absence du texte OCR et des tags ; codes non nuls pour chaque classe d'échec.
10. **Rangement** — vérifier l'inventaire de `inbox`, puis injecter un échec dans `take`,
   `extract` et `classify` avec `--quarantine-on-error` et vérifier les artefacts exacts déplacés
   dans `QUARANTINE`.
11. **Équivalence** — exécuter le script Bash et `sort` sur deux copies du même corpus sans
   interruption, puis comparer `DOC`, `OCR`, `TAG`, `QUARANTINE`, diagnostics et codes de sortie.
12. **Transaction** — interrompre `sort` à chaque transition et vérifier qu'aucun staging n'est
    visible ; documenter que ce test ne s'applique pas au script de référence.
13. **Quarantaine** — vérifier la présence des artefacts disponibles et du rapport.
14. **Suppression** — états `DOC`, `DOC+OCR`, `DOC+OCR+TAG`, ensemble orphelin et panne injectée à
   chaque déplacement temporaire.
15. **Concurrence** — deux `sort` simultanés, conflit `sort`/`remove` et deux sessions de règles.
16. **Reprise** — interruption à chaque étape, puis reprise sans ensemble orphelin ni mélange de
    deux empreintes de règles.
