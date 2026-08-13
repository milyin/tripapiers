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
- **LLM au strict minimum.** Un modèle n'intervient que pour évaluer le résultat de l'OCR
  locale et pour décoder un document quand l'OCR locale a échoué. Ses réponses sont contraintes
  par un schéma JSON, revalidées localement, et mémorisées par empreinte de contenu pour que
  les exécutions suivantes soient reproductibles.

## État

**Conception.** Ce dépôt ne contient pour l'instant aucun code d'exécution. La conception est
découpée en deux documents, correspondant aux deux composants du projet :

| Document | Composant |
|---|---|
| [`doc/traitement-des-fichiers.md`](doc/traitement-des-fichiers.md) | Le pipeline de classement `INBOX → DATE → STRUCTURE` — **obligatoire** |
| [`doc/verification.md`](doc/verification.md) | L'audit indépendant du corpus — **optionnel** |

Le pipeline classe et archive sans le second composant : il conserve un contrôle en ligne,
non désactivable, qui relit et revérifie chaque document au moment de son écriture. Le
composant de vérification apporte autre chose — un audit *a posteriori* de tout le corpus,
réimplémenté indépendamment du code qui a produit les fichiers.

## Prérequis prévus

- Rust stable (édition 2024)
- `poppler-utils` — `pdftotext`, `pdftoppm`, `pdfinfo`
- `tesseract-ocr` avec les paquets de langues `fra` et `eng`

## Licence

À définir.
