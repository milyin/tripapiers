# tripapiers — évolution des règles de classification

Ce document définit la boucle par laquelle un agent fait évoluer les expressions régulières de
`tags.yml`. L'agent propose et révise les règles ; la commande `classify` reste entièrement
mécanique et n'appelle aucun modèle.

---

## 1. Principes

- Une classification acceptée constitue la référence de régression du corpus.
- Une révision candidate n'écrit jamais directement dans `TAG` et ne remplace jamais
  `tags.yml`.
- Chaque essai reclassifie le même instantané de **tous** les textes OCR du corpus géré conservés
  dans SQLite.
- Pour chaque document déjà accepté, toute addition ou suppression de tag par rapport à la
  référence doit recevoir une décision explicite de l'agent. Le document cible est comparé aux
  tags attendus déclarés par l'agent au début de la session.
- Une décision appartient au triplet `(empreinte du corpus, empreinte des règles, différence)` ;
  elle devient caduque dès que l'un de ces éléments change.
- Le modèle utilisé par l'agent, ses décisions et ses justifications sont consignés, mais ils ne
  participent pas à l'exécution ultérieure de `classify`.

---

## 2. État conservé dans SQLite

`tripapiers.db` contient au minimum :

```text
documents
  id, source_sha256, filename, added_date, managed, source_path

ocr_texts
  id, document_id, ocr_sha256, text, created_at

rule_revisions
  id, parent_id, rules_sha256, yaml, status, created_at

review_sessions
  id, target_document_id, parent_revision_id, expected_tags, agent, status, created_at

classification_runs
  id, revision_id, corpus_sha256, status, created_at

assignments
  run_id, document_id, tag, rule_sha256, match_start, match_end

review_decisions
  id, run_id, document_id, tag, change, verdict, reason, agent, decided_at
```

Le texte de `ocr_texts.text` est exactement le champ `text` de l'artefact `.ocr.yml`, sans
normalisation supplémentaire. `ocr_sha256` lie la ligne aux octets du YAML. La clé
`corpus_sha256` est l'empreinte de la liste triée des couples `(document_id, ocr_sha256)` des
documents gérés actifs. Les textes autonomes restent stockés, mais ne participent pas à une
publication globale dans `TAG`.

SQLite accélère les essais globaux et conserve leur historique, mais ne devient pas l'autorité
documentaire : la base peut être reconstruite depuis `DOC`, `OCR`, `TAG` et la révision acceptée
de `tags.yml`.

---

## 3. Interface de la boucle

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

`rules begin` prend la session `pending`, crée une copie candidate de la révision acceptée et
retourne son chemin. L'agent modifie uniquement ce fichier. `rules check` valide et compile
toutes les expressions avant toute exécution. `rules run` classe l'instantané complet dans les
tables de staging.

`rules expect` remplace atomiquement l'ensemble attendu du document cible ; répéter `--tag`
déclare plusieurs tags et une invocation sans `--tag` déclare explicitement un ensemble vide.

`rules abort` supprime la candidate et ses exécutions, mais laisse le document dans l'état
`pending` afin qu'une nouvelle session puisse reprendre sa revue.

`rules diff` n'envoie jamais implicitement tout le corpus au modèle. Il montre séparément les
tags manquants ou inattendus du document cible et les changements des documents déjà acceptés.
Pour chaque changement ancien, il fournit le document, l'ancien et le nouveau tag, la règle
responsable, les positions de la correspondance et un extrait borné. L'agent peut demander
explicitement le texte complet du seul document nécessaire à sa décision avec `rules show`.

---

## 4. Boucle d'apprentissage

1. `take`, `extract` puis la classification mécanique par les règles acceptées ajoutent le
   nouveau document, son texte OCR et son résultat initial à SQLite. L'appel géré de `classify`
   crée systématiquement une session `pending` pour ce document.
2. `rules begin` prend en charge cette session. L'agent lit le texte du document cible, la
   révision courante de `tags.yml` et les décisions historiques pertinentes. Avant tout essai,
   il consigne l'ensemble exact des tags qu'il juge attendus pour ce document.
3. Les règles acceptées classent mécaniquement le nouveau document. Si le résultat diffère des
   tags attendus, l'agent propose une modification minimale des regex. S'il est déjà exact, la
   candidate peut rester identique.
4. `rules check` compile l'ensemble de la révision candidate. Une seule règle invalide bloque
   l'essai.
5. `rules run` applique mécaniquement la candidate à tous les textes de l'instantané SQLite.
6. `rules diff` compare le document cible aux tags attendus et tous les autres documents à leur
   dernière classification acceptée. Il distingue partout les tags ajoutés et supprimés.
7. L'agent examine chaque différence :
   - si elle est correcte, il l'accepte avec une justification concise ;
   - si elle est incorrecte, il la rejette, resserre ou remplace la regex, puis reprend à
     l'étape 4.
8. Après chaque modification de la candidate, toutes les décisions de l'essai précédent sont
   invalidées et l'ensemble du corpus est reclassifié.
9. La boucle se termine uniquement lorsque les conditions d'acceptation ci-dessous sont toutes
   satisfaites.

L'agent ne peut pas masquer une différence en ne reclassifiant qu'un sous-ensemble. Une
acceptation groupée est permise seulement pour des différences produites par la même règle et
présentant la même justification ; chaque document reste néanmoins enregistré séparément.

---

## 5. Conditions d'acceptation

Une session est publiable seulement si :

- toutes les regex se compilent avec le moteur et les limites configurés ;
- chaque règle ajoutée ou modifiée correspond à au moins un document de l'instantané ;
- deux exécutions de la candidate sur le même instantané produisent exactement les mêmes
  affectations ;
- chaque différence d'un document déjà accepté possède une décision `accept` et aucune ne
  possède une décision `reject` ;
- le nouveau document possède les tags attendus déclarés au début de la session ;
- chaque document satisfait les cardinalités et les règles d'`evaluation.yml` ;
- la révision parente est toujours la révision acceptée ;
- `corpus_sha256` est toujours celui de l'instantané évalué.

Une session sans différence est valide : elle prouve qu'une réécriture de règle est
fonctionnellement équivalente. Une session qui change des documents anciens est également
valide, mais uniquement après acceptation explicite de chacune de ces régressions ou corrections.

---

## 6. Publication transactionnelle

`rules commit` prend le verrou global, recalcule les empreintes de la révision parente et du
corpus, puis refuse une session devenue obsolète. Il prépare dans un staging privé :

- le nouveau `tags.yml` ;
- tous les `.tag.yml` dont le contenu change ;
- la révision, les affectations et les décisions SQLite à accepter.

Un journal durable décrit les anciens et nouveaux chemins. La publication remplace les fichiers
préparés, marque la révision SQLite comme `accepted`, puis retire le staging. Après une
interruption, la reprise termine la publication ou restaure intégralement la révision précédente.
Le `.tag.yml` du document cible passe alors de `pending` à `accepted`, même si les règles sont
restées fonctionnellement identiques. Le système ne mélange jamais des `.tag.yml` produits par
deux empreintes de règles différentes.

---

## 7. Échecs et concurrence

- Une regex invalide est une erreur de configuration ; elle ne met aucun document en
  quarantaine.
- Une panne pendant un essai laisse uniquement un run `failed` dans SQLite et ne modifie pas la
  référence.
- Un nouvel OCR ou une autre révision acceptée rend la session `stale` et impose un nouvel essai
  complet.
- Deux sessions peuvent être préparées en parallèle, mais une seule peut être publiée ; l'autre
  doit repartir de la nouvelle révision acceptée.
- La suppression d'un document retire sa classification active, mais l'historique des
  exécutions et décisions reste conservé avec une référence marquée comme supprimée.

---

## 8. Tests minimaux

1. Une règle ciblée ajoute le tag attendu au nouveau document sans modifier les anciens.
2. Une règle trop large produit plusieurs différences ; leur rejet force un nouvel essai global.
3. Une modification légitime d'un ancien document ne devient référence qu'après décision
   explicite.
4. Une modification de regex invalide toutes les décisions de l'exécution précédente.
5. Une insertion OCR concurrente rend la session obsolète avant le commit.
6. Une interruption à chaque étape de publication restaure entièrement l'ancienne révision ou
   termine entièrement la nouvelle.
7. La reconstruction de SQLite depuis les artefacts visibles reproduit la révision et les
   affectations acceptées.
