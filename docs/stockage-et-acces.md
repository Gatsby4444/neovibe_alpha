# Stockage et accès — où vit quoi, et qui peut le lire

> Relevé **en base** le 2026-08-10, à la demande de Jay, après la séparation des
> vibes envoyées et des vibes de bibliothèque. À vérifier plutôt qu'à croire :
> les politiques évoluent, ce document date.

## Les cinq buckets

Un bucket est un espace de stockage **sur le serveur Supabase**. L'app n'en
possède aucun : elle y dépose et y télécharge, et le serveur décide de ce
qu'elle a le droit de lire. À ne pas confondre avec le **cache local**
(`CardMediaCache`), qui est une copie de tes propres contenus sur l'appareil.

| Bucket | Contenu | Public ? | Qui peut lire |
|---|---|---|---|
| `avatars` | Photos de profil | ⚠️ **OUI** | N'importe qui avec l'URL, sans authentification |
| `cards` | Faces des Vibes envoyées | Non | `can_view_card_file` — **six chemins**, voir ci-dessous |
| `library` | Médias de la bibliothèque de profil | Non | `library_read_via_acl` — visibilité de la bibliothèque de l'auteur |
| `media` | Photos et vidéos des messages | Non | `media_read_via_message` — membres de la conversation |
| `library_vault` | Bibliothèques éphémères de conversation | Non | Membres, placeholder tout de suite, scellé à reveal − 5 min |

### Le cas `avatars`

C'est le seul bucket **public** : les photos de profil sont lisibles par toute
personne connaissant l'URL, sans compte. C'est l'usage courant pour des avatars,
mais à garder en tête pour une app dont la thèse est le cercle restreint. **À
réexaminer avant la prod** : si une photo de profil doit rester dans le cercle,
ce bucket doit devenir privé.

---

## Le point de fragilité : `can_view_card_file`

L'accès à une face de Vibe passe par une seule fonction, qui ouvre le fichier si
**au moins l'une** de ces six conditions est vraie :

1. tu es le propriétaire ;
2. tu as reçu une **livraison** non détruite ;
3. la Vibe est dans la bibliothèque de profil de quelqu'un dont tu peux voir la
   bibliothèque ;
4. elle est dans une bibliothèque **publique** et tu peux voir ce profil ;
5. tu l'as **sauvegardée** ;
6. c'est une **story** que tu peux voir.

**Six chemins reliés par OU : c'est le plus permissif qui gagne, toujours, et en
silence.** C'est exactement le motif qui rendait les bibliothèques éphémères
vulnérables avant leur séparation.

### Deux conséquences vérifiées, non corrigées

**a. Les limites de vues ne protègent pas le fichier.**
La branche « livraison » ne teste que `destroyed_at is null` — **jamais le
compteur de vues**. Le décompte est appliqué par `mark_card_viewed`, une RPC que
le client *choisit* d'appeler. Un client modifié peut donc retélécharger la face
après avoir épuisé ses visionnages.

**b. Une story annule les limites de la livraison.**
`is_story_card` autorise quiconque peut voir la story, sans regarder les
compteurs. Une Vibe envoyée avec 2 vues **et** publiée en story est en pratique
illimitée pour qui voit la story.

Les deux sont cohérents avec la position assumée du produit — « coûteux et
visible, pas impossible » — mais ce ne sont pas des choix qui ont été faits :
ce sont des effets de bord de l'accumulation de chemins.

**Si les limites de vues doivent devenir une garantie réelle**, il faut cesser
de servir le fichier directement et passer par une URL signée à courte durée,
délivrée par une RPC qui décompte — le même principe que la clé des
bibliothèques.

---

## Le modèle qui marche, et qu'on peut généraliser

La séparation faite le 2026-08-10 sur les bibliothèques donne la règle :

> **Deux objets qui n'obéissent pas aux mêmes règles d'accès ne doivent pas
> partager le même stockage.**

| | Vibe envoyée | Vibe de bibliothèque |
|---|---|---|
| Bucket | `cards` | `library_vault` |
| Accès | Livraison nominative | Appartenance à la conversation |
| Vues / durée | Limitées | Aucune limite |
| Original en clair | Oui | **Nulle part** |

Le bénéfice n'est pas seulement la sécurité : chaque bucket a **une seule
règle**, qu'on peut lire, tester et expliquer. Là où `can_view_card_file`
demande de tenir six branches en tête simultanément.

### Candidats à la même séparation, par ordre d'intérêt

1. **Stories.** Aujourd'hui une story est une Vibe publiée, et son accès s'ajoute
   aux autres — d'où le point (b). Un bucket `stories` avec sa seule règle
   « visible par ceux qui peuvent voir mes stories, 24 h » supprimerait le
   conflit avec les limites de livraison.
2. **Vibes sauvegardées.** Une sauvegarde donne un accès **permanent** à un
   fichier dont l'émetteur croit contrôler la durée de vie. Copier le fichier
   dans un espace appartenant à celui qui sauvegarde rendrait la chose explicite,
   au lieu d'un accès perpétuel sur le fichier d'origine.
3. **Bibliothèque de profil publique.** Mélange dans `library` du contenu réservé
   au cercle et du contenu ouvert à tout profil visible.

**Ne rien entreprendre sans arbitrage de Jay** : chacun de ces chantiers déplace
des fichiers existants et demande une migration de données, pas seulement de
schéma.
