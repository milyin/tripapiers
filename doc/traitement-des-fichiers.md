# tripapiers — registre de fichiers et classifications

## 1. Responsabilité

`tripapiers` est une base locale qui relie des contenus, des chemins, des textes, des tags et
des règles. Il est volontairement agnostique à la structure des dossiers.

Il ne réalise aucune extraction, aucun OCR et aucun appel à un modèle. Il ne déduit rien du nom
ou de l'emplacement d'un fichier. Il ne copie, ne déplace, ne renomme et ne supprime jamais un
fichier externe. Ces opérations appartiennent aux outils qui l'appellent.

Un fichier peut rester enregistré sans chemin. Un chemin peut être momentanément absent du
disque. Ces deux états sont valides : la base décrit des références, pas une arborescence qu'elle
administrerait.

## 2. Identité et données conservées

### 2.1 Identité par contenu

L'identifiant immuable est `sha256:<64 caractères hexadécimaux>`, calculé sur les octets du
fichier au moment de `file add`. La taille appartient à cette identité. Le nom d'affichage et les
chemins sont des métadonnées modifiables.

Une entrée contient :

- `sha256`, `size` et `name` ;
- un ensemble éventuellement vide de chemins absolus normalisés lexicalement ;
- zéro ou un texte UTF-8, avec sa propre empreinte et sa date de mise à jour ;
- pour chaque classification, les tags explicites et les tags dérivés des regex.

Deux chemins ayant le même SHA-256 sont rattachés à la même entrée. Si un chemin déjà rattaché
désigne de nouveaux octets, `file add` échoue avec `path_conflict` : il faut d'abord exécuter
`file detach`, puis ajouter le nouveau contenu. La base ne suit ni inode ni lien symbolique.

### 2.2 Chemins

Un chemin relatif fourni à la CLI est résolu depuis le dossier courant, puis enregistré sous
forme absolue normalisée. L'existence est exigée par `file add` et `file attach`, mais pas par
les commandes de consultation ni par `file detach`.

`file detach` retire seulement la référence de la base. `file remove` retire seulement l'entrée
de la base. Aucune des deux commandes ne modifie le système de fichiers.

### 2.3 Texte

Le texte est une chaîne UTF-8 opaque. `tripapiers` ne connaît ni sa langue, ni sa provenance, ni
sa qualité. En l'absence de texte, aucune règle ne correspond, mais des tags explicites restent
possibles.

Une mise à jour de texte recalcule atomiquement les tags dérivés du fichier dans **toutes** les
classifications, car le texte est partagé entre elles.

## 3. Classifications

Une classification nommée est un instantané cohérent qui contient :

- son catalogue de tags ;
- la liste ordonnée des regex de chaque tag ;
- les affectations explicites ;
- les affectations dérivées, recalculables à partir des textes et des regex ;
- un numéro de révision croissant.

Les fichiers, chemins et textes sont communs à toutes les classifications. Une base neuve crée
la classification `default` et la sélectionne.

Les commandes `tag …` et `file tag …` agissent sur la classification sélectionnée par
`class select`. L'option globale `--class <name>` remplace cette sélection pour une invocation et
évite un état implicite dans les automatisations.

Le résultat effectif d'un fichier est l'union de ses tags explicites et dérivés. Une provenance
conservée pour chaque affectation permet de distinguer les deux sources et d'indiquer les règles
responsables.

## 4. Règles mécaniques

### 4.1 Forme

Une regex est toujours écrite avec des délimiteurs, par exemple :

```text
/Ivan\s+Petrov/i
/Petrov\s+Ivan/i
/ordonnance\s+m[eé]dicale/i
```

Les `/` internes sont échappés par `\/`. Les indicateurs autorisés sont `i`, `m`, `s` et `x`,
sans doublon et dans cet ordre canonique. Le moteur est Unicode, garantit une durée bornée et
refuse les constructions non prises en charge, notamment les références arrière et les
regards avant ou arrière. Une expression invalide ou capable de correspondre à une chaîne vide
est refusée.

Les règles d'un tag sont évaluées avec un OU logique. Leur ordre n'influence pas le tag produit,
mais fournit des positions stables pour l'interface. Les positions affichées commencent à 1.
Deux regex textuellement identiques ne peuvent pas appartenir au même tag.

Dans `tag regexp remove`, une valeur entièrement numérique désigne une position ; une valeur
commençant par `/` désigne la regex exacte. Il n'existe donc aucune ambiguïté.

### 4.2 Effet d'une mutation

`tag regexp add` et `tag regexp remove` compilent d'abord la règle, puis réévaluent le tag
concerné sur tous les textes de la classification dans une transaction unique. Elles affichent
le nombre de fichiers gagnant ou perdant le tag et la liste correspondante. `--dry-run` calcule
le même résultat sans l'enregistrer.

`class rebuild` recompile toutes les règles et reconstruit tous les tags dérivés. Il sert après
une migration ou à contrôler l'intégrité ; une modification normale n'en a pas besoin.

## 5. Interface des fichiers

### 5.1 Adressage commun

Les commandes qui acceptent `<path_or_sha>` ont exactement deux formes :

```text
tripapiers file info <path>
tripapiers file info --sha sha256:<hex>
```

Un SHA n'est jamais accepté comme argument positionnel. Le préfixe `sha256:` est obligatoire.
Les options mutuellement exclusives sont validées avant toute mutation.

### 5.2 Ajout, rattachement et retrait

```text
tripapiers file add <path>
tripapiers file attach <sha> <path>
tripapiers file detach <path>
tripapiers file remove --sha <sha> [--yes]
```

`file add` lit le fichier, calcule son empreinte et sa taille, crée l'entrée si nécessaire,
puis rattache le chemin. Son nom de base initialise `name` seulement lors de la création.
Répéter l'opération sur le même couple contenu-chemin est idempotent.

`file attach` rattache à une entrée existante un autre chemin dont le contenu doit avoir le SHA
annoncé. `file detach` retire un chemin même si le fichier externe n'existe plus. La dernière
référence peut être retirée sans supprimer l'entrée.

`file remove` exige le SHA pour empêcher la suppression accidentelle par un ancien chemin. Elle
supprime l'entrée, son texte et ses affectations dans toutes les classifications, mais aucun
fichier externe. Une confirmation interactive est requise, sauf avec `--yes`.

### 5.3 Consultation et mise à jour

```text
tripapiers file info (<path> | --sha <sha>) [--format text|json]
tripapiers file update (<path> | --sha <sha>)
  [--name <name>] [--text <path>] [--clear-text]
tripapiers file text (<path> | --sha <sha>) [--output <path>]
tripapiers file paths (<path> | --sha <sha>)
tripapiers file verify ((<path> | --sha <sha>) | --all)
```

`file update --text` lit intégralement le fichier texte UTF-8 fourni. `--clear-text` est
incompatible avec `--text`. Une invocation sans champ à modifier est rejetée. Modifier le nom
ne modifie aucun chemin ; le SHA et la taille ne peuvent pas être modifiés.

`file info` affiche l'identité, tous les chemins, la présence et l'empreinte du texte, puis les
tags effectifs avec leur provenance dans la classification choisie. Il n'affiche pas le texte.
`file text` écrit le texte sur stdout ou dans `--output`. `file paths` liste les références,
y compris celles qui n'existent plus. `file verify` relit les chemins présents sur disque et
compare taille et SHA sans modifier la base ; `--all` contrôle toutes les entrées.

### 5.4 Recherche

```text
tripapiers file list
  [--glob <glob>]... [--regexp <regexp>]...
  [--tag <tag>]... [--without-path] [--missing]
  [--format text|json]
```

Les globs et regex sont appliqués au nom d'affichage et aux chemins enregistrés. Plusieurs
filtres du même type sont reliés par OU ; des types différents sont reliés par ET. Plusieurs
`--tag` exigent tous les tags dans la classification sélectionnée. `--without-path` vise les
entrées sans référence et `--missing` celles dont aucun chemin n'existe actuellement.

L'ordre de sortie est déterministe : `(name, sha256)`, puis chemins lexicographiques.

### 5.5 Tags explicites

```text
tripapiers file tag add (<path> | --sha <sha>) <tag>
tripapiers file tag remove (<path> | --sha <sha>) <tag>
tripapiers file tag list (<path> | --sha <sha>) [--source explicit|regexp|all]
```

Ces commandes permettent à un outil externe de conserver sa décision sans inventer une regex.
Le tag doit exister dans la classification. Retirer un tag explicite ne retire pas le même tag
s'il reste produit par une règle.

## 6. Interface des tags

```text
tripapiers tag add <tag>
tripapiers tag remove <tag> [--yes]
tripapiers tag list [--glob <glob>]... [--regexp <regexp>]...
tripapiers tag regexp add <tag> <regexp> [--dry-run]
tripapiers tag regexp remove <tag> (<position> | <regexp>) [--dry-run]
tripapiers tag regexp list <tag>
tripapiers tag regexp test <tag> <regexp> [--format text|json]
```

Un tag est une chaîne UTF-8 non vide, sans caractère de contrôle. `:` peut exprimer une
hiérarchie conventionnelle (`cat:medecine:ordonnance`), mais la base traite le tag comme une
chaîne opaque.

`tag remove` refuse un tag encore utilisé, sauf avec `--yes`; dans ce cas, il supprime ses
règles et toutes ses affectations dans la classification courante. Les filtres de `tag list`
s'appliquent uniquement aux noms de tags, jamais au texte de leurs regex.

`tag regexp test` compile et évalue une règle temporaire sur tous les textes, sans exiger que le
tag existe et sans mutation. Il affiche les fichiers correspondants ; c'est la forme détaillée
d'un aperçu avant ajout.

## 7. Interface des classifications

```text
tripapiers class current
tripapiers class list
tripapiers class select <name>
tripapiers class new <new_name>
tripapiers class copy <new_name>
tripapiers class rename <new_name>
tripapiers class delete [<name>] [--yes]
tripapiers class rebuild [--dry-run]
tripapiers class compare <name> [--format text|json]
```

- `new` crée une classification vide ;
- `copy` copie la classification courante, y compris catalogue, règles et affectations
  explicites, puis reconstruit ses affectations dérivées ;
- `rename` renomme la classification courante ;
- `delete` vise le nom donné ou, à défaut, la classification courante ; elle refuse de supprimer
  la dernière classification et demande confirmation ;
- `compare` compare la courante au nom donné.

La classification courante est le résultat et le nom donné est la référence : « ajouté » veut
donc dire « présent dans la courante seulement ». La comparaison distingue les tags ajoutés ou
supprimés du catalogue, les règles ajoutées, supprimées ou déplacées, et les tags effectifs
ajoutés ou supprimés pour chaque SHA. Le format texte résume d'abord les nombres puis détaille
les fichiers ; le JSON stable est destiné aux outils externes.

## 8. SQLite et configuration

### 8.1 Schéma logique minimal

```text
files(sha256 PK, name, size, created_at, updated_at)
paths(path PK, sha256 FK, added_at, last_seen_at)
texts(sha256 PK/FK, text, text_sha256, updated_at)
classifications(id PK, name UNIQUE, revision, created_at, updated_at)
tags(classification_id, tag, created_at)
regexps(classification_id, tag, position, expression, created_at)
explicit_assignments(classification_id, sha256, tag, created_at)
derived_assignments(classification_id, sha256, tag, regexp_position,
                    match_start, match_end)
```

Les clés étrangères interdisent toute règle ou affectation vers un tag ou un fichier absent.
Une vue `effective_assignments` expose l'union sans doublon des deux formes d'affectation.

### 8.2 Configuration

```toml
schema_version = 1

[database]
path = "tripapiers.db"

[regexp]
max_pattern_bytes = 4096
max_compiled_bytes = 1048576
```

Il n'existe aucune configuration `DOC`, `OCR`, `TAG`, `INBOX` ou `QUARANTINE`. Le chemin de la
base peut être remplacé par l'argument global `--database <path>`. Un chemin relatif est résolu
depuis le fichier de configuration.

### 8.3 Transactions et concurrence

SQLite utilise les clés étrangères et le mode WAL. Chaque commande mutative forme une seule
transaction : règles, affectations et numéro de révision deviennent visibles ensemble ou pas du
tout. `--if-revision <number>` permet à un outil externe de refuser une écriture si la
classification a changé depuis sa lecture.

La base et ses sauvegardes sont créées avec des permissions limitées à l'utilisateur. Les
diagnostics n'impriment jamais le texte sauf sur demande explicite avec `file text`.

## 9. Commandes de maintenance

```text
tripapiers db info
tripapiers db verify
tripapiers db backup <path>
tripapiers db vacuum
```

`db verify` contrôle les contraintes, les empreintes des textes, les positions de regex et la
reproductibilité des affectations dérivées, sans relire les fichiers externes. `db backup`
emploie l'API de sauvegarde SQLite afin de produire un instantané cohérent.

## 10. Codes de sortie

| Code | Signification |
|---|---|
| `0` | succès, y compris opération idempotente |
| `1` | contenu, règle ou invariant invalide |
| `2` | invocation ou configuration invalide |
| `3` | panne d'entrée-sortie ou de base de données |
| `4` | conflit de chemin, de nom ou de révision |

Les commandes mutatives affichent uniquement un diagnostic synthétique. Les commandes de
consultation produisent du texte stable ou, avec `--format json`, un objet versionné.
