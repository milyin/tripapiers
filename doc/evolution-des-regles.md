# tripapiers — évolution des règles de classification

Ce document décrit comment un outil externe, éventuellement piloté par un agent, peut faire
évoluer les regex sans masquer leurs effets sur le corpus. `tripapiers` lui-même n'utilise
aucune IA et ne décide jamais si un tag est sémantiquement correct.

## 1. Propriété recherchée

Toute modification de règle est appliquée mécaniquement à tous les textes de la classification
courante. Le résultat est atomique et immédiatement comparable à une classification de
référence. Une erreur comme `/pomme/i`, qui étiquette à la fois une recette et une facture de
téléphone, devient donc visible avant que la variante soit adoptée.

Les classifications nommées sont des instantanés explicites, conservés dans la même base et
manipulables par la CLI.

## 2. Préparer une variante

L'outil externe choisit une référence et en crée une copie :

```console
tripapiers class select accepted
tripapiers class copy candidate
tripapiers class select candidate
```

`class copy` copie les tags et leurs regex, puis reproduit les affectations sur les textes
courants. La nouvelle classification est indépendante : ses règles peuvent évoluer sans
modifier `accepted`.

Dans un script concurrent, chaque commande doit utiliser `--class candidate` au lieu de dépendre
de `class select`.

## 3. Ajouter un document et son texte

L'extraction reste entièrement externe :

```console
tripapiers file add ./documents/facture.pdf
tripapiers file text update ./documents/facture.pdf --text ./travail/facture.txt
```

Le second appel remplace le texte partagé et recalcule ce fichier dans toutes les
classifications. Tous ses tags proviennent alors des regex de chaque classification : toute
décision doit devenir une règle reproductible pour entrer dans la classification.

## 4. Proposer et éprouver une règle

La boucle minimale est :

1. Afficher les correspondances sans mutation :

   ```console
   tripapiers --class candidate tag regexp test cuisine:recette '/pomme/i'
   ```

2. Prévisualiser exactement le delta de l'ajout :

   ```console
   tripapiers --class candidate tag regexp add cuisine:recette '/pomme/i' --dry-run
   ```

3. Si le delta paraît plausible, enregistrer la règle :

   ```console
   tripapiers --class candidate tag regexp add cuisine:recette '/pomme/i'
   ```

   Cette transaction applique la règle à tous les textes, met à jour les affectations
   et incrémente la révision de `candidate`.

4. Mesurer toutes les conséquences par rapport à la référence :

   ```console
   tripapiers --class candidate class compare accepted
   ```

5. Examiner les documents dont les tags ont changé. Si un changement est incorrect, retirer la
   règle par sa position ou sa valeur exacte, puis en proposer une plus précise :

   ```console
   tripapiers --class candidate tag regexp remove cuisine:recette '/pomme/i'
   tripapiers --class candidate tag regexp add cuisine:recette \
     '/(?:recette|ingr[eé]dients)[[:space:][:punct:]]+[^\n]{0,80}pomme/i'
   ```

6. Répéter jusqu'à ce que chaque différence soit intentionnelle.

L'agent externe est responsable de lire les textes nécessaires, d'interpréter les différences
et de documenter ses décisions. La base se contente de fournir des résultats déterministes.

## 5. Effet sur les autres documents

Chaque mutation de regex montre au minimum :

```text
classification: candidate
revision: 18 -> 19
tag: cuisine:recette
files_added: 2
files_removed: 0
unchanged: 431
```

Le détail identifie les fichiers par SHA, noms et chemins connus. Il indique la regex et la
plage de correspondance, mais pas le texte complet. L'outil externe utilise `file text show`
pour lire explicitement un document lorsqu'il en a besoin.

`class compare` ne se limite pas à la dernière commande : il compare l'état complet des deux
classifications et révèle aussi les effets cumulés, les suppressions de tags et les changements
d'affectations.

## 6. Stabiliser la variante

Avant d'adopter une variante, l'outil externe exécute :

```console
tripapiers --class candidate class rebuild --dry-run
tripapiers --class candidate class compare accepted --format json
tripapiers db verify
```

Le premier contrôle exige que le recalcul complet ne produise aucun changement interne. Le
second fournit un diff stable que l'outil peut faire approuver. Le troisième vérifie les
invariants de stockage.

Le choix de la classification de référence appartient au processus externe. Une convention
simple consiste à conserver `accepted` comme référence, à renommer l'ancienne version pour
l'archive, puis à renommer la candidate :

```console
tripapiers class select accepted
tripapiers class rename accepted-before-2026-08-18
tripapiers class select candidate
tripapiers class rename accepted
```

Cette suite est volontairement explicite. `tripapiers` n'offre pas de publication sémantique
automatique et ne prétend pas savoir quelle classification est meilleure.

## 7. Concurrence et reprise

Un outil lit d'abord la révision de la classification, puis ajoute `--if-revision <number>` à
chaque mutation. Une erreur `revision_conflict` lui impose de relire et de comparer les états ;
elle ne doit jamais être contournée par une fusion implicite.

Chaque commande est transactionnelle. Après une interruption, une regex et toutes les
affectations qu'elle produit sont soit entièrement visibles, soit entièrement absentes. Une
classification candidate peut être supprimée et recréée depuis la référence à tout moment.

## 8. Scénarios de validation

1. Une règle ciblée ajoute le tag attendu à un document sans modifier les autres.
2. Une règle trop large expose tous ses faux positifs dans le delta et dans `class compare`.
3. Retirer une règle supprime seulement les affectations qui n'ont plus d'autre preuve.
4. Une mise à jour de texte recalcule le fichier dans toutes les classifications.
5. Deux recalculs du même état produisent exactement les mêmes affectations et preuves.
6. Un conflit de révision ne laisse aucune règle ni affectation partiellement écrite.
