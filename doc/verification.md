# tripapiers — vérification

> **Statut : brouillon.** Ce document esquisse les contrôles d'intégrité du registre. Leur
> interface pourra évoluer pendant l'implémentation.

## 1. Périmètre

La vérification porte d'abord sur SQLite, qui est l'autorité pour les textes, les références,
les tags, les règles et les classifications. Elle n'attend aucune arborescence particulière et
ne réalise ni OCR, ni analyse sémantique, ni appel à une IA.

Deux contrôles sont séparés :

- `db verify` vérifie les données internes et reste indépendant du système de fichiers ;
- `file verify` relit volontairement les chemins externes encore présents afin de signaler les
  fichiers absents ou dont les octets ont changé.

Aucun contrôle ne modifie, déplace ou supprime un fichier externe.

## 2. Vérification interne

```text
tripapiers db verify [--format text|json]
```

Le contrôle ouvre une transaction de lecture cohérente et vérifie au minimum :

- `PRAGMA integrity_check` et toutes les clés étrangères ;
- la forme canonique et l'unicité des SHA-256 ;
- une taille non négative pour chaque entrée et des noms UTF-8 valides ;
- l'unicité de chaque couple `(sha256, name)`, sans exiger l'unicité globale d'un nom ;
- l'unicité globale des chemins normalisés ;
- l'empreinte de chaque texte stocké ;
- l'existence des classifications et l'unicité de leur nom ;
- l'existence du tag visé par chaque règle et chaque affectation ;
- des positions de regex contiguës à partir de 1 pour chaque tag ;
- la compilation de toutes les regex avec les limites configurées ;
- l'absence de regex en double ou correspondant à la chaîne vide ;
- l'égalité entre les affectations stockées et un recalcul complet.

Le contrôle des affectations s'effectue dans une table temporaire de la connexion de lecture. Il
ne répare jamais silencieusement la base. `class rebuild` est la commande mutative explicite si
une reconstruction est nécessaire.

## 3. Vérification des références externes

```text
tripapiers file verify (<path> | --sha <sha>) [--format text|json]
tripapiers file verify --all [--format text|json]
```

Pour chaque référence, le contrôle distingue :

- `ok` : fichier ordinaire, taille et SHA identiques ;
- `missing` : chemin absent ;
- `not_regular` : chemin présent mais ne désignant pas un fichier ordinaire ;
- `size_mismatch` : taille différente, sans calcul d'empreinte inutile ;
- `sha_mismatch` : même taille mais contenu différent ;
- `unreadable` : accès impossible.

Un chemin absent n'est pas une corruption de la base et n'est jamais détaché automatiquement.
Une entrée sans chemin est valide et apparaît comme `detached`. Un même contenu sous plusieurs
chemins est également valide. Les noms sont contrôlés séparément : le nom de base d'un chemin
n'a pas à disparaître lorsque ce chemin est détaché, et un alias n'a pas à correspondre à un
chemin existant.

Après `file add`, le chemin doit référencer le SHA des octets lus au cours de cette commande. Un
ancien rattachement du même chemin à un autre SHA a été remplacé atomiquement ; son existence
dans un historique ou une sauvegarde n'est pas une incohérence. L'ancienne entrée et ses noms
peuvent légitimement rester sans chemin.

La vérification protège contre le remplacement concurrent : elle relève les métadonnées avant
et après la lecture et signale `changed_during_read` si elles diffèrent. Elle ne promet toutefois
pas de verrouiller un fichier administré par un autre programme.

## 4. Vérification des classifications

Pour chaque classification, l'auditeur reconstruit mécaniquement les tags à partir du
texte exact et de la liste ordonnée des regex. Il compare :

- l'ensemble des fichiers étiquetés ;
- l'ensemble effectif des tags de chaque fichier ;
- la provenance par règle et la première plage de correspondance conservée ;
- le numéro de révision et les compteurs associés.

La vérification ne juge pas les tags sémantiquement. Une regex trop large mais valide est
détectable par comparaison entre classifications, pas par `db verify`.

## 5. Sauvegarde et réparation

Avant toute réparation, l'utilisateur crée un instantané cohérent :

```console
tripapiers db backup ./tripapiers-before-repair.db
```

Les réparations envisagées restent des commandes explicites et bornées :

- `class rebuild` reconstruit les affectations ;
- `file detach <path>` retire une référence devenue inutile ;
- `file name add` et `file name remove` corrigent les alias indépendamment des chemins ;
- `file text update … --text …` remplace un texte connu comme erroné ;
- `db vacuum` compacte la base après contrôle.

Il n'existe pas de mode qui déplace les fichiers selon leurs tags ni qui reconstitue une
arborescence : cela resterait hors de la responsabilité de `tripapiers`.

## 6. Codes de sortie envisagés

| Code | Signification |
|---|---|
| `0` | aucun défaut pour le périmètre demandé |
| `1` | invariant interne violé ou contenu externe divergent |
| `2` | invocation ou configuration invalide |
| `3` | vérification incomplète à cause d'une panne d'entrée-sortie |

Le JSON sera versionné et trié de façon déterministe par `(classification, sha256, check,
path)` afin de rester comparable en intégration continue.
