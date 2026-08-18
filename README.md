# tripapiers

`tripapiers` est un registre local de documents. Il conserve dans SQLite :

- l'identité d'un fichier (taille et SHA-256) et ses différents noms ;
- zéro, un ou plusieurs chemins qui font référence à ce contenu ;
- le texte associé au fichier ;
- les tags produits par des expressions régulières ;
- plusieurs classifications nommées afin de comparer des variantes de règles et d'étiquetage.

L'outil n'utilise **aucune IA**, ne réalise pas d'OCR et n'organise pas les documents. Il ne
copie, ne déplace et ne supprime jamais les fichiers référencés. Les extracteurs, agents et
scripts externes choisissent librement leur arborescence et utilisent `tripapiers` comme base
de textes et moteur de classification mécanique.

## Exemple

```console
tripapiers file add ./facture.pdf
tripapiers file update ./facture.pdf --text ./facture.txt

tripapiers class copy candidate
tripapiers class select candidate
tripapiers tag add cuisine:recette
tripapiers tag regexp add cuisine:recette '/pomme/i' --dry-run
tripapiers tag regexp add cuisine:recette '/pomme/i'
tripapiers class compare default
```

L'ajout de la règle recalcule immédiatement le tag concerné sur **tous** les textes. Si
`/pomme/i` étiquette aussi une facture de téléphone, `class compare default` rend ce changement
visible. La règle peut alors être retirée ou resserrée, puis la comparaison répétée.

Deux chemins vers les mêmes octets enrichissent la même entrée :

```console
tripapiers file add /Downloads/impot_2022.pdf
tripapiers file add /Documents/Jean_dupont_impot.pdf
tripapiers file name list --sha sha256:<hex>
tripapiers file detach /Downloads/impot_2022.pdf
```

Les deux noms restent enregistrés après le détachement. Ils se gèrent indépendamment avec
`file name add` et `file name remove`.

`file add` est une opération de convergence : elle ne produit jamais de conflit parce que le
chemin est déjà connu. Elle crée l'entrée correspondant aux octets si nécessaire, puis rattache
le chemin à cette entrée. Si le chemin désignait auparavant un autre SHA, sa référence est
remplacée atomiquement.

## Interface prévue

```text
tripapiers file add <path>
tripapiers file attach <sha> <path>
tripapiers file detach <path>
tripapiers file info (<path> | --sha <sha>)
tripapiers file update (<path> | --sha <sha>) (--text <path> | --clear-text)
tripapiers file text (<path> | --sha <sha>) [--output <path>]
tripapiers file paths (<path> | --sha <sha>)
tripapiers file name add (<path> | --sha <sha>) <name>
tripapiers file name remove (<path> | --sha <sha>) <name>
tripapiers file name list (<path> | --sha <sha>)
tripapiers file list [--glob <glob>]... [--regexp <regexp>]... [--tag <tag>]...
tripapiers file verify ((<path> | --sha <sha>) | --all)
tripapiers file remove --sha <sha> [--yes]

tripapiers tag add <tag>
tripapiers tag remove <tag> [--yes]
tripapiers tag list [--glob <glob>]... [--regexp <regexp>]...
tripapiers tag regexp add <tag> <regexp> [--dry-run]
tripapiers tag regexp remove <tag> (<position> | <regexp>) [--dry-run]
tripapiers tag regexp list <tag>
tripapiers tag regexp test <tag> <regexp>

tripapiers class current
tripapiers class list
tripapiers class select <name>
tripapiers class new <new_name>
tripapiers class copy <new_name>
tripapiers class rename <new_name>
tripapiers class delete [<name>] [--yes]
tripapiers class rebuild [--dry-run]
tripapiers class compare <name> [--format text|json]

tripapiers db info
tripapiers db verify
tripapiers db backup <path>
tripapiers db vacuum
```

Les commandes `tag …` travaillent sur la classification courante. L'argument global
`--class <name>` permet de viser explicitement une autre classification, ce qui est préférable
dans les scripts.

## Documentation

| Document | Rôle |
|---|---|
| [`doc/traitement-des-fichiers.md`](doc/traitement-des-fichiers.md) | Modèle de données, invariants, CLI et transactions |
| [`doc/evolution-des-regles.md`](doc/evolution-des-regles.md) | Procédure itérative de modification des regex |
| [`doc/verification.md`](doc/verification.md) | Brouillon de la vérification de la base et des références |

## État

**Conception.** L'application n'est pas encore implémentée.

Les noms de commandes, d'arguments, de champs et de statuts sont en anglais. Les diagnostics et
la documentation destinés à l'utilisateur sont en français.

## Prérequis prévus

- Rust stable, édition 2024 ;
- SQLite 3 ;
- un moteur d'expressions régulières Unicode à temps d'exécution borné.

## Licence

À définir.
