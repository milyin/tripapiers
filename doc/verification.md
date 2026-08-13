# tripapiers — vérification

> **Composant optionnel.** `tripapiers` classe, archive et reconstruit sans lui. Ce document
> décrit un programme d'audit **indépendant** du pipeline, qui relit le corpus depuis le disque
> et recontrôle ses invariants. Le pipeline lui-même est décrit dans
> [`traitement-des-fichiers.md`](traitement-des-fichiers.md).

---

## 1. Statut : optionnel, et ce que cela implique

Le composant peut être retiré du workspace, ou simplement jamais installé. Dans ce cas :

**Ce qui reste garanti** — le pipeline conserve son **contrôle en ligne** après écriture
(cf. [`traitement-des-fichiers.md`](traitement-des-fichiers.md) §2.5) : à la fin de chaque
transaction, il relit depuis le disque le document et le sidecar qu'il vient d'écrire,
recalcule le sidecar et compare octet à octet, puis recontrôle le checksum du document
déplacé. Ce contrôle fait partie de la transaction, échoue fermé et déclenche le rollback.
Il n'est pas désactivable et ne dépend pas de ce composant. Chaque document est donc
individuellement vérifié **au moment de son classement**.

**Ce qui est perdu** — trois choses, toutes *a posteriori* :

1. **La détection des corruptions survenues après le classement** : édition manuelle d'un
   sidecar, altération d'un document, bit rot, lien symbolique cassé par un déplacement de
   `DATE`, sidecar dupliqué par une copie de dossier.
2. **L'indépendance du contrôle.** Le contrôle en ligne du pipeline réutilise `build_sidecar` :
   il détecte une écriture ratée, mais pas un bug **dans** `build_sidecar` lui-même. Le
   composant de vérification réimplémente les contrôles depuis la configuration et le contrat
   YAML, sans partager de code métier — c'est là que réside sa valeur, exactement comme
   `verify_drive_document_yaml.py` était un programme distinct de
   `build_drive_document_yaml.py` dans le système d'origine.
3. **La procédure de reprise après incident** (`doctor`, §5.4), qui donne un feu vert motivé
   avant de relancer des tâches mutatives après une panne.

> **Compromis assumé.** Sans ce composant, l'invariant « échec fermé » n'est plus contrôlé que
> par le code qui l'implémente, et la reprise après incident redevient manuelle. C'est
> acceptable pour un usage personnel où le corpus est petit et l'utilisateur présent ; ça ne
> l'est plus dès que le classement tourne sans surveillance sur un timer. Recommandation :
> livrer le composant, et le rendre optionnel plutôt qu'absent.

---

## 2. Principe : indépendance, pas réutilisation

La règle qui gouverne toute la conception de ce composant :

**Il ne partage aucun code métier avec le pipeline, et ne lit aucun de ses états internes.**

- Entrées autorisées : les fichiers du dépôt (`DATE/`, `STRUCTURE/`, `.CONFIG/`) et le contrat
  YAML documenté.
- Entrées interdites : `inbox_batch.json`, `structure_state.json`, `executions.db`,
  `llm_cache/` — l'audit ne doit pas pouvoir être trompé par un état local corrompu.
- Dépendances Cargo autorisées : `core` et `config` en **lecture seule** (types et parseurs).
  Interdit : `pipeline`, `store`, `llm`, `extract`.
- Les contrôles sont **réimplémentés** à partir du contrat, pas obtenus en appelant
  `build_sidecar`. Une divergence entre les deux implémentations est précisément le signal
  recherché.

En conséquence, `pipeline` ne dépend pas de `verify`, et retirer `crates/verify` du workspace
doit laisser `cargo build -p tripapiers-cli` intact
([`traitement-des-fichiers.md`](traitement-des-fichiers.md) §4.1).

---

## 3. `verify_sidecar` — contrôle unitaire d'un document

```rust
fn verify_sidecar(
    document_path: &Path,
    sidecar_path: &Path,
    config: &Config,
) -> SidecarReport
```

Relit les deux fichiers depuis le disque et recontrôle, indépendamment :

| Contrôle | Détail |
|---|---|
| Identifiant stable de source | `source.sha256` correspond bien au SHA-256 des octets du document |
| Checksum | `checksum: "sha256:…"` recalculé sur les octets réels, pas sur une copie en mémoire |
| Date | `dates.primary.value` analysable, cohérente avec `dates.principal` |
| Chemin dérivé | `destination.primary_path` == `DATE/YYYY/MM/DD` dérivé de la date primaire, et == chemin réel du fichier sur le disque |
| Tags `nom:` | forme `nom:NOM_Prenom`, et présence dans `.CONFIG/persons.yml` si ce catalogue est adopté |
| Tags `cat:` | chaque catégorie existe dans `category.yml` ; règles `assign_only_listed_categories` et `allow_multiple_categories` respectées |
| Conformité du sidecar | `schema_version` connue, clés attendues présentes, aucune clé inconnue, sérialisation canonique (ordre des clés, LF, absence d'ancres) |
| Adjacence | le sidecar est bien `<nom-du-document>.yml` dans le même dossier |

Chaque échec produit une entrée `{ chemin, contrôle, attendu, obtenu }` — jamais une simple
valeur booléenne : le rapport doit être actionnable.

---

## 4. Audit du corpus

### 4.1 Audit `DATE`

Parcours borné de `DATE/YYYY/MM/DD`, sans suivre les liens symboliques :

- `verify_sidecar` sur chaque paire document/sidecar ;
- **unicité** : aucun document sans sidecar, aucun sidecar orphelin, aucun `source.sha256` en
  double dans tout le corpus (détection de doublon classé deux fois) ;
- cohérence de l'arborescence : aucun fichier hors du gabarit `YYYY/MM/DD`, aucun répertoire
  de date impossible (`2024/13/…`, `2024/02/30`).

### 4.2 Intégrité `STRUCTURE`

- **Aucun fichier physique ni sidecar** dans `STRUCTURE` : uniquement des dossiers et des
  liens symboliques (invariant 2).
- **Aucun lien pendant** : chaque symlink pointe vers un fichier existant de `DATE`.
- **Aucune cible hors `DATE`** : après résolution, chaque cible reste sous `DATE/`.
- **Reproductibilité (invariant 11)** : le contrôle fort. Le composant recalcule le plan
  attendu à partir des sidecars valides de `DATE` et de `structure.yml`, puis compare
  l'ensemble `(chemin logique → cible)` à ce qui est réellement sur le disque. Toute
  divergence — branche manquante, branche en trop, cible erronée — est signalée.
- **Aucun dossier `CATEGORY`** à la racine (invariant 6).

### 4.3 Modes de sortie

```
tripapiers verify [date|structure|all] [--format text|json] [--fail-fast]
```

Code de sortie 0 si tout passe, non-0 sinon. `--format json` produit un rapport machine,
destiné à une unité systemd ou à une tâche planifiée.

---

## 5. Reprise après incident (`doctor`)

Préflight à exécuter avant de relancer des tâches mutatives après une panne. Contrairement au
reste du composant, `doctor` **est** autorisé à lire les états locaux du pipeline : son travail
consiste justement à juger leur cohérence.

Contrôles :

1. absence d'exécution vivante `claimed` ou `running` dans le ledger ;
2. cohérence du ledger (pas de transaction ouverte sans clôture) ;
3. aucun journal de transaction non clôturé dans `journal/` ;
4. intégrité de `DATE` (§4.1) ;
5. unicité des sidecars des documents récemment ajoutés ;
6. conformité de `STRUCTURE` (§4.2), ou proposition d'un plan de reconstruction sûr ;
7. cohérence du registre de lot avec le contenu réel de `INBOX` et `DATE`.

Si l'une de ces conditions échoue, `doctor` sort non-0 avec un incident explicite et
**recommande** de laisser les tâches mutatives en pause. Il ne modifie rien lui-même.

---

## 6. Correspondance invariant → contrôle

Reprise des invariants de [`traitement-des-fichiers.md`](traitement-des-fichiers.md) §4.7.

| # | Invariant | Contrôlé par | Contrôlable *a posteriori* ? |
|---|---|---|---|
| 1 | un document par transaction | ledger via `doctor` §5.2 | partiellement |
| 2 | document physique dans `DATE`, jamais `STRUCTURE` | §4.2 | oui |
| 3 | sidecar adjacent, valide, checksummé | §3 + §4.1 | oui |
| 4 | `.CONFIG` seule autorité, jamais écrite | empreinte des fichiers de config dans le rapport | oui |
| 5 | le LLM ne sérialise pas le YAML | §3 (sérialisation canonique) | indirectement |
| 6 | aucun dossier `CATEGORY` | §4.2 | oui |
| 7 | pas de mutation concurrente | `doctor` §5.1 | non — propriété d'exécution |
| 8 | échec fermé | `doctor` §5.2–5.3 | partiellement |
| 9 | suppressions via `.TRASH/` | inventaire de `.TRASH/` | partiellement |
| 10 | un seul rapport final | — | non — propriété d'exécution |
| 11 | `STRUCTURE` reproductible depuis `DATE` + `.CONFIG` | §4.2, contrôle fort | oui |
| 12 | inventaires bornés, sans suivre les symlinks | — | non — propriété d'exécution |
| 13 | verdicts LLM rejouables | hors périmètre (état local) | non |

Les quatre invariants marqués « propriété d'exécution » ne sont pas auditables après coup :
ils sont garantis par la conception du pipeline et couverts par ses propres tests
([`traitement-des-fichiers.md`](traitement-des-fichiers.md) §7).

---

## 7. Distribution

Deux profils, à choisir à la compilation :

| Profil | Contenu | Usage |
|---|---|---|
| **minimal** | `tripapiers` seul | poste personnel, corpus surveillé |
| **complet** | `tripapiers` + `tripapiers-verify` | classement automatisé sur timer, corpus important |

Mise en œuvre : `crates/verify` produit un binaire distinct `tripapiers-verify`, et une
*feature* optionnelle `verify` du crate `cli` ajoute les sous-commandes `verify` et `doctor`
comme façade. La feature est **activée par défaut** ; `--no-default-features` produit le profil
minimal. Le binaire distinct reste utilisable seul, sans le CLI principal — c'est ce qui rend
l'audit exécutable depuis une autre machine ou sur une sauvegarde montée en lecture seule.

---

## 8. Phases de développement

Numérotation séparée de celle du pipeline. Les phases V1 et V2 peuvent démarrer dès que la
phase 1 du pipeline (cœur déterministe, contrat YAML) est figée ; V3 dépend de la phase 5
(reconstruction `STRUCTURE`).

### Phase V1 — `verify_sidecar` indépendant
- Réimplémentation des contrôles du §3 depuis le contrat YAML, sans appeler `build_sidecar`.
- Rapport structuré `{ chemin, contrôle, attendu, obtenu }`, sorties texte et JSON.
- **Recette :** pour chaque contrôle, une fixture saine et au moins une fixture corrompue
  (checksum modifié d'un octet, date incohérente avec le chemin, catégorie absente de
  `category.yml`, clé inconnue, ordre des clés altéré, sidecar renommé). Test croisé : tout
  sidecar produit par `build_sidecar` en phase 1 doit passer `verify_sidecar`.

### Phase V2 — Audit `DATE`
- Parcours borné, unicité, détection de doublons par `source.sha256`, cohérence de
  l'arborescence de dates.
- **Recette :** corpus synthétique de 500 documents avec injections — sidecar orphelin,
  document sans sidecar, doublon exact, `2024/02/30`. Chaque injection doit être détectée et
  attribuée au bon chemin.

### Phase V3 — Intégrité `STRUCTURE` et `doctor`
- Contrôles du §4.2, dont la recomparaison du plan attendu contre le disque.
- `doctor` (§5) avec lecture des états locaux et code de sortie motivé.
- **Recette :** injections — lien pendant, cible hors `DATE`, fichier physique déposé dans
  `STRUCTURE`, branche supprimée à la main, `structure.yml` modifié sans reconstruction.
  Pour `doctor` : ledger avec transaction ouverte, journal non clôturé, registre de lot
  désynchronisé de `INBOX`.

---

## 9. Recette du composant

1. **Sans réseau** — `cargo test -p tripapiers-verify` : aucune dépendance à `llm`, `extract`,
   `pipeline` ou `store`, ce qu'un test de compilation vérifie explicitement.
2. **Aller-retour pipeline → vérification** — classer un corpus synthétique avec
   `classify --all --no-llm`, puis `verify all` : doit sortir 0.
3. **Matrice de corruption** — pour chaque injection des phases V1 à V3, `verify all` doit
   sortir non-0 et nommer précisément le fichier et le contrôle en défaut. C'est la recette
   principale : un audit qui ne détecte pas est pire qu'un audit absent.
4. **Lecture seule** — `verify all` sur un dépôt monté en lecture seule doit fonctionner et ne
   rien écrire (contrôlé par comparaison d'empreintes avant/après).
5. **Indépendance réelle** — muter volontairement `build_sidecar` (par exemple inverser deux
   clés) : les tests du pipeline peuvent rester verts, mais `verify_sidecar` doit détecter la
   divergence. Ce test est la justification d'existence du composant ; il est marqué et
   documenté comme tel.
6. **Profil minimal** — `cargo build -p tripapiers-cli --no-default-features` compile, et
   `tripapiers verify` renvoie alors une erreur explicite « composant non installé », pas un
   panic ni un succès silencieux.
