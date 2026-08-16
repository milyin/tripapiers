# tripapiers

Outil local de tri documentaire : classe des documents déposés dans `INBOX`, les archive
physiquement dans `DATE/YYYY/MM/DD` avec un sidecar YAML déterministe et vérifiable, puis
génère une vue logique `STRUCTURE` composée uniquement de dossiers et de liens symboliques.

Trois principes :

- **Local.** Aucun stockage distant, aucune API de cloud. Tout se passe sur le système de
  fichiers de la machine.
- **Prédictible.** Les artefacts canoniques — YAML, checksums, chemins dérivés — sont produits
  par du code déterministe, jamais par un modèle de langage. Un document par transaction,
  verrou exclusif, opérations réversibles, programme de vérification indépendant.
- **LLM au strict minimum.** Un modèle n'intervient que pour deux tâches : **étiqueter** un
  texte — il rend une liste de tags, un par ligne, et le code Rust ignore toute ligne non
  conforme — et **ré-océriser** un document quand l'OCR locale n'a pas suffi. Les tags reçus
  passent ensuite une évaluation formelle et configurable ; un document qui échoue part en
  `QUARANTAINE` avec son dossier de preuve, jamais dans l'archive.

## État

**Conception.** Ce dépôt ne contient pour l'instant aucun code d'exécution. La conception est
découpée en deux documents, correspondant aux deux composants du projet :

| Document | Composant |
|---|---|
| [`doc/traitement-des-fichiers.md`](doc/traitement-des-fichiers.md) | Le pipeline de classement `INBOX → DATE → STRUCTURE` — **obligatoire** |
| [`doc/verification.md`](doc/verification.md) | L'audit indépendant du corpus — **brouillon, optionnel** |

Le pipeline classe et archive sans le second composant. Le document de vérification, encore à
l'état de brouillon, propose un audit *a posteriori* de tout le corpus, réimplémenté
indépendamment du code qui a produit les fichiers.

## Prérequis prévus

- Rust stable (édition 2024)
- `poppler-utils` — `pdftotext`, `pdftoppm`, `pdfinfo`
- `tesseract-ocr` avec les paquets de langues `fra` et `eng`

## Licence

À définir.
