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

- **Original préservé.** Le fichier est copié sans renommage ni transformation dans `DOC`.
- **Artefacts séparés.** Le texte et les métadonnées OCR vivent dans `OCR` ; les tags vivent
  dans `TAG`.
- **Confiance locale.** Le score OCR est calculé par les outils locaux. Le modèle appelé par
  `classify` ne reçoit aucune demande d'estimation de confiance.
- **Aucun raccourci.** Cette première version ne construit ni vue logique ni lien symbolique.
- **Transactions bornées.** `sort` range un triplet complet ou place l'ensemble en quarantaine ;
  `remove` supprime les trois membres ou n'en supprime aucun.

## État

**Conception.** Le dépôt ne contient pas encore de code d'exécution.

| Document | Rôle |
|---|---|
| [`doc/traitement-des-fichiers.md`](doc/traitement-des-fichiers.md) | Pipeline, formats, configuration et CLI |
| [`doc/verification.md`](doc/verification.md) | Brouillon de l'audit indépendant et optionnel |

Les premières commandes prévues sont :

```text
tripapiers extract <document>
tripapiers classify <document.ocr.yml>
tripapiers sort [<files>...]
tripapiers remove <document>
```

Les commandes, arguments et clés de configuration utilisent des noms anglais ; les messages et
la documentation destinés à l'utilisateur sont en français.

## Prérequis prévus

- Rust stable, édition 2024
- `poppler-utils` (`pdfinfo`, `pdftotext`, `pdftoppm`)
- `tesseract-ocr` avec les langues configurées

## Licence

À définir.
