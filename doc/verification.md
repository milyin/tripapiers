# tripapiers — vérification

> **Statut : brouillon.** Ce document décrit un composant indépendant et optionnel, susceptible
> d'évoluer après la mise en œuvre du pipeline principal.

---

## 1. Rôle

Le composant de vérification relit les autorités visibles sur le disque :

- `tripapiers.toml` et `.CONFIG` ;
- les originaux sous `DOC/YYYY/MM/DD` ;
- les artefacts OCR sous `OCR/YYYY/MM/DD` ;
- les artefacts d'étiquetage sous `TAG/YYYY/MM/DD` ;
- les ensembles en échec sous `QUARANTINE/YYYY/MM/DD`.

Il ne crée, ne déplace et ne supprime aucun fichier. Il ne dépend ni de l'état interne du
pipeline, ni du ledger, ni des journaux de transaction pour conclure qu'un triplet est valide.

Le pipeline fonctionne sans ce composant. Sans lui, les erreurs survenues après le rangement —
modification manuelle, bit rot, suppression d'un membre ou copie dans une mauvaise date — ne
sont simplement pas auditées de façon indépendante.

---

## 2. Principe d'indépendance

La vérification réimplémente les contrôles à partir des contrats documentés ; elle n'appelle ni
les constructeurs YAML du pipeline, ni ses fonctions de résolution de triplets.

Entrées autorisées :

- fichiers sous les cinq racines configurées ;
- `tripapiers.toml`, `tags.yml` et `evaluation.yml` ;
- schémas et types de lecture du crate `core`.

Entrées interdites pour l'audit normal :

- `executions.db` ;
- `journal/` ;
- réponses brutes ou caches internes d'un fournisseur ;
- fonctions mutatives de `store` et `pipeline`.

Une divergence entre le producteur et l'auditeur est le signal recherché, pas une erreur à
masquer en partageant davantage de code.

---

## 3. Résolution de la configuration

L'auditeur applique la même priorité déclarative que la CLI : arguments explicites, fichier
TOML, valeurs par défaut. Il réimplémente cependant les validations :

- racines non vides et distinctes ;
- absence de chevauchement entre `INBOX`, `QUARANTINE`, `DOC`, `OCR` et `TAG` ;
- aucun lien symbolique utilisé comme racine gérée ;
- chemins relatifs résolus depuis le fichier TOML, ou depuis `--root` lorsqu'il est fourni ;
- existence et validité des fichiers de `.CONFIG`.

Une configuration ambiguë interrompt l'audit avant tout parcours.

---

## 4. Contrôles unitaires

### 4.1 Original sous `DOC`

Pour `DOC/YYYY/MM/DD/<filename>` :

- `YYYY/MM/DD` est une date civile valide ;
- le fichier est ordinaire, jamais un lien symbolique ;
- `<filename>` ne porte pas un suffixe réservé `.ocr.yml` ou `.tag.yml` ;
- son SHA-256 est calculable et correspond aux artefacts associés lorsqu'ils sont présents.

La date du chemin est comparée à `source.added_date` dans chaque YAML présent. Aucun tag `date:`
et aucune métadonnée du fichier ne sont utilisés pour dériver ce chemin. Un document seul est
un état valide après `take`.

### 4.2 Artefact OCR

Pour `OCR/YYYY/MM/DD/<filename>.ocr.yml` :

| Contrôle | Détail |
|---|---|
| Schéma | `schema_version` connue, clés attendues uniquement |
| Source | `source.filename`, `source.sha256` et `source.added_date` présents |
| Emplacement | date et nom cohérents avec le document sous `DOC` |
| Moteur | `ocr.engine.kind` dans `local\|model`, nom non vide, version si disponible |
| Langues | liste non vide de codes configurés |
| Confiance | entier `0..100`, `source: local`, version de formule connue |
| Repli vision | cohérent avec `engine.kind` |
| Texte | chaîne UTF-8 présente, scalaire littéral dans la forme canonique |

L'auditeur vérifie explicitement que la confiance vient du calcul local. Il n'attend et
n'accepte aucun tag `confiance:` dans l'artefact TAG.

### 4.3 Artefact TAG

Pour `TAG/YYYY/MM/DD/<filename>.tag.yml` :

| Contrôle | Détail |
|---|---|
| Source | nom, SHA-256 et `added_date` identiques à l'original et à l'OCR |
| Lien OCR | `ocr.sha256` correspond aux octets du `.ocr.yml` associé |
| Modèle | identifiant non vide et horodatage analysable |
| Prompt | empreinte recalculée depuis `tags.yml` lorsqu'il s'agit de la version courante |
| Grammaire | segments, rôles, casse et bornes dures respectés |
| Valeurs | expressions régulières et valeurs fermées de `tags.yml` respectées |
| Cardinalités | règles de `tags.yml` et `evaluation.yml` satisfaites |
| Ordre | tags triés lexicographiquement et sans doublon |
| Confiance | aucun namespace `confiance:` présent |

Un artefact classé avec une ancienne empreinte de prompt reste historiquement lisible. Il est
signalé comme `stale_prompt`, pas comme corrompu, sauf si ses tags enfreignent le contrat actuel.

---

## 5. Audit global

### 5.1 Progression `DOC` / `OCR` / `TAG`

L'auditeur construit trois ensembles de clés `(date, filename)` sans suivre les liens
symboliques. Il exige une relation d'inclusion : `TAG ⊆ OCR ⊆ DOC`.

Il signale :

- OCR sans document ou TAG sans OCR, qui sont des états orphelins ;
- membre placé sous une autre date ;
- nom de base divergent ;
- SHA-256 divergent ;
- doublon de contenu sous plusieurs clés, comme avertissement distinct.

`DOC` seul (`taken`) et `DOC+OCR` (`extracted`) sont des états valides produits par les commandes
indépendantes. Ils peuvent être signalés comme incomplets selon la politique de l'audit, mais
ne sont pas des corruptions. `DOC+OCR+TAG` correspond à l'état `classified`.

### 5.2 Audit d'`INBOX`

`INBOX` ne contient que les documents sources que `sort` transmettra à `take`. L'auditeur signale
les fichiers portant les suffixes réservés `.ocr.yml` ou `.tag.yml`, les sous-dossiers, liens
symboliques, temporaires abandonnés et fichiers déjà présents à l'identique sous `DOC`.

Un fichier ancien dans `INBOX` n'est pas une corruption. Il produit un avertissement
`pending_too_long` avec un seuil configurable pour attirer l'attention sur une panne récurrente.

### 5.3 Audit de `QUARANTINE`

Chaque entrée suit :

```text
QUARANTINE/YYYY/MM/DD/<filename>--<short-sha>/
```

Elle contient l'original, les artefacts YAML qui avaient pu être produits et `report.yml`.
L'auditeur vérifie :

- cohérence des noms, date et empreintes ;
- présence de la phase et d'au moins une raison typée ;
- absence simultanée du même document dans un triplet valide ;
- absence de fichier temporaire ou inconnu ;
- cohérence des chemins cibles consignés dans le rapport avec la configuration actuelle.

### 5.4 Absence de vues dérivées

Le composant n'attend aucune racine de structure, aucun index et aucun raccourci. Dans les
racines gérées, tout lien symbolique est une erreur. L'audit ne construit donc aucun plan de vue
et ne possède aucun mode de reconstruction.

---

## 6. Interface envisagée

```text
tripapiers verify [documents|ocr|tags|inbox|quarantine|all]
  [--format text|json]
  [--fail-fast]
  [--config <path>]
  [--root <path>]
  [--inbox-dir <path>]
  [--quarantine-dir <path>]
  [--documents-dir <path>]
  [--ocr-dir <path>]
  [--tags-dir <path>]
```

Les commandes, modes, arguments, clés JSON et codes de contrôle sont en anglais. Les messages
du format `text` sont en français.

Code de sortie :

- `0` : aucun défaut ;
- `1` : défaut de corpus ;
- `2` : configuration ou invocation invalide ;
- `3` : audit incomplet à cause d'une panne d'infrastructure.

Le JSON est versionné, trié par `(date, filename, check)` et stable pour permettre sa comparaison
en CI.

---

## 7. Correspondance avec les invariants du pipeline

| # | Invariant | Contrôle |
|---|---|---|
| 1 | date choisie par `take` | comparaison avec `source.added_date` |
| 2 | progression préfixe-complète | inclusion `TAG ⊆ OCR ⊆ DOC` |
| 3 | original préservé | empreintes croisées |
| 4 | OCR lié au document | `OCR.source.sha256` |
| 5 | TAG lié à l'OCR | `TAG.ocr.sha256` |
| 6 | confiance locale uniquement | contrat OCR + absence de `confiance:` |
| 7 | date documentaire sans effet sur le chemin | contrôle de dérivation |
| 8 | aucune vue par lien | refus des liens symboliques |
| 9 | priorité des chemins | résolution indépendante de la configuration |
| 10 | lignes invalides non réparées | indirect, via grammaire et diagnostics |
| 11 | échec de `sort` déplaçant les artefacts disponibles | audit de l'entrée et du rapport |
| 12 | échec de `take` préservant la source | propriété d'exécution |
| 13 | suppression tout ou rien des membres présents | absence de nouvel état orphelin |
| 14 | catégories dans `tags.yml` | validation des valeurs fermées |
| 15 | interface configurable en anglais | tests CLI et schéma TOML |
| 16 | `<path>` imposant le mode autonome | tests CLI d'intégration |
| 17 | mode géré exigeant nom et date | tests CLI d'invocation |
| 18 | `remove` sans argument positionnel | tests CLI d'invocation |

Les propriétés purement temporelles — verrouillage, ordre exact des `rename`, rollback avant
visibilité — restent couvertes par les tests du pipeline et ne sont pas prouvables après coup.

---

## 8. Phases du composant optionnel

### Phase V1 — Contrats OCR et TAG

- Parseurs indépendants et rapports structurés.
- Une fixture saine et une fixture corrompue pour chaque champ.
- Tests croisés : tout artefact produit par le pipeline passe l'audit ; des producteurs mutés
  volontairement sont détectés.

### Phase V2 — Inventaires

- Parcours bornés des cinq racines.
- Correspondance des triplets, détection d'orphelins, doublons et dates divergentes.
- Audit complet de `QUARANTINE`.

### Phase V3 — CLI et diagnostic

- Sous-commandes de `verify`, formats texte et JSON, codes de sortie.
- Exécution sans réseau et sans dépendance au client LLM.
- Corpus synthétique d'au moins 500 triplets avec corruptions injectées.

---

## 9. Recette minimale

1. Ensemble sain dans chacun des états `taken`, `extracted` et `classified` : `verify all`
   retourne 0.
2. Modifier un octet du document : les deux liens SHA deviennent invalides.
3. Modifier le texte OCR sans refaire les tags : `TAG.ocr.sha256` diverge.
4. Déplacer seulement le TAG sous une autre date : TAG orphelin aux deux emplacements.
5. Ajouter un tag `confiance:90` : rejet explicite.
6. Créer un lien symbolique dans chaque racine : chaque cas est rejeté sans suivre la cible.
7. Corrompre `tripapiers.toml` ou faire chevaucher deux racines : audit interrompu avec code 2.
8. Créer une entrée de quarantaine sans rapport ou sans original : défaut nommé précisément.
9. Simuler une erreur de lecture au milieu du parcours : code 3, jamais un faux succès.
