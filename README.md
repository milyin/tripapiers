# tripapiers

Outil local de tri documentaire. Les fichiers déposés dans `INBOX` sont extraits, étiquetés et
rangés selon leur date d'ajout au système :

```text
DOC/YYYY/MM/DD/fichier-original.pdf
OCR/YYYY/MM/DD/fichier-original.pdf.ocr.yml
TAG/YYYY/MM/DD/fichier-original.pdf.tag.yml
```

Un ensemble qui ne peut pas être rangé correctement est déplacé avec ses YAML disponibles dans
`QUARANTINE`. Les cinq racines sont configurables dans `tripapiers.toml` et par les arguments de
ligne de commande.

Principes :

- **Octets préservés.** `take` déplace le fichier dans `DOC` sans transformer son contenu ;
  `--name` peut seulement redéfinir son nom cible.
- **Artefacts séparés.** Le texte et les métadonnées OCR vivent dans `OCR` ; les tags vivent
  dans `TAG`.
- **Confiance locale.** Le score OCR est calculé par les outils locaux. Le modèle appelé par
  `classify` ne reçoit aucune demande d'estimation de confiance.
- **Aucun raccourci.** Cette première version ne construit ni vue logique ni lien symbolique.
- **Étapes composables.** `sort` enchaîne `take`, `extract` et `classify`, puis place en
  quarantaine tous les artefacts disponibles dès qu'une étape échoue.

## État

**Conception.** Le dépôt ne contient pas encore de code d'exécution.

| Document | Rôle |
|---|---|
| [`doc/traitement-des-fichiers.md`](doc/traitement-des-fichiers.md) | Pipeline, formats, configuration et CLI |
| [`doc/verification.md`](doc/verification.md) | Brouillon de l'audit indépendant et optionnel |

Les premières commandes prévues sont :

```text
tripapiers take <path> [--name <filename>] [--date <YYYY-MM-DD>]
tripapiers extract <path> [--output <path>] [--force]
tripapiers extract --name <filename> --date <YYYY-MM-DD>
tripapiers classify <path> [--output <path>] [--force]
tripapiers classify --name <filename> --date <YYYY-MM-DD>
tripapiers sort
tripapiers remove --name <filename> --date <YYYY-MM-DD>
```

Avec `<path>`, `extract` et `classify` travaillent en mode autonome et ignorent le routage
`DOC/OCR/TAG`. Sans `<path>`, elles exigent `--name` et `--date` et utilisent les racines gérées.
`remove` n'accepte jamais de chemin positionnel.

Les commandes, arguments et clés de configuration utilisent des noms anglais ; les messages et
la documentation destinés à l'utilisateur sont en français.

## Prérequis prévus

- Rust stable, édition 2024
- `poppler-utils` (`pdfinfo`, `pdftotext`, `pdftoppm`)
- `tesseract-ocr` avec les langues configurées

## Licence

À définir.
