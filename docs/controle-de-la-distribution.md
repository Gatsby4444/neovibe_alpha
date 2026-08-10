# Contrôle de la distribution — plan

> Mot d'ordre donné par Jay le 2026-08-10 : **« comme Apple : contrôle complet
> de l'écosystème »**. Ce document propose le mécanisme et le séquençage.
> Rien ici n'est implémenté sauf mention contraire.

## Ce qu'on peut contrôler, et ce qu'on ne peut pas

Il faut être net là-dessus avant de concevoir, sinon on promet l'impossible.

**Contrôlable** : *combien d'octets sortent du serveur, pour qui, et quand.*
C'est total, et c'est ce que ce plan verrouille.

**Non contrôlable** : *ce que devient un octet une fois sur l'appareil.* Qui a
reçu une image peut la garder. Apple non plus n'empêche pas la capture d'écran
d'une photo affichée — sa maîtrise porte sur la **distribution**, pas sur la
rétine.

La bonne formulation de l'objectif est donc : **personne ne doit obtenir plus
d'octets que son quota ne l'autorise.** Pas « personne ne peut conserver ce
qu'il a vu ».

---

## Le défaut actuel

Aujourd'hui, une face de Vibe est servie parce qu'une **permission permanente**
existe : `can_view_card_file` renvoie vrai, donc le fichier est téléchargeable,
autant de fois qu'on veut, tant que la condition tient.

Le compteur de vues, lui, vit ailleurs : dans `mark_card_viewed`, une RPC que le
client **choisit** d'appeler. Un client modifié saute l'appel et télécharge
quand même.

**La limite de vues n'est donc pas une garantie serveur. C'est une convention
client.**

## Le mécanisme proposé : l'autorisation à l'acte

Cesser d'accorder un droit de lecture permanent. Servir chaque octet par une
**autorisation courte, nominative et à usage unique, délivrée par le serveur au
moment même où il décompte**.

```
        AUJOURD'HUI                          PROPOSÉ
   client → storage (RLS: oui)      client → RPC open_card_face()
   client → mark_card_viewed()                 │ vérifie le droit
       (facultatif !)                          │ DÉCRÉMENTE le compteur
                                               │ signe une URL de 30 s
                                               ▼
                                      client → storage (URL signée)
```

Concrètement :

1. **Retirer** la politique `SELECT` du bucket `cards` pour tout le monde sauf
   le propriétaire. Plus personne ne télécharge directement.
2. **Ajouter** une RPC `open_card_face(delivery_id, face)` en `SECURITY DEFINER`
   qui, **dans une seule transaction** : vérifie l'appelant, vérifie et
   **décrémente** le compteur, puis renvoie une URL signée valable ~30 s.
3. Le client n'a plus d'autre moyen d'obtenir les octets.

**Pourquoi c'est robuste** : le décompte n'est plus une étape que le client peut
sauter — **c'est l'acte même qui délivre l'URL**. Pas de décompte, pas d'URL,
pas d'octets. Un client modifié n'a rien à contourner : il n'y a plus de porte
dérobée, il n'y a plus qu'une porte.

**C'est exactement le modèle des bibliothèques éphémères**, où le serveur retient
la clé. Il a déjà fait ses preuves ici — il s'agit de le généraliser.

### Ce que ça ne fait pas

Une URL signée, une fois émise, reste valable ses 30 secondes et peut servir
plusieurs fois. On obtient donc **un téléchargement par vue décomptée**, pas
l'impossibilité de conserver le fichier. C'est la limite honnête énoncée plus
haut, et elle est acceptable : le quota est respecté.

### Deux niveaux, à arbitrer

| | Niveau 1 — URL signée à l'acte | Niveau 2 — chiffrement systématique |
|---|---|---|
| Principe | Le serveur ne signe qu'en décomptant | Tout média chiffré au dépôt ; le serveur délivre la clé en décomptant |
| Effort | Moyen : 1 RPC + politiques + appels client | Élevé : chiffrement au dépôt, gestion de clés, déchiffrement à l'affichage pour **tous** les médias |
| Gagne | Le quota devient une garantie serveur | En plus : le stockage lui-même ne contient plus rien de lisible |
| Contre qui | Client modifié | Client modifié **et** fuite du stockage |

**Recommandation : niveau 1 d'abord.** Il ferme le trou réel pour un coût
mesuré. Le niveau 2 n'apporte que contre un adversaire ayant accès au stockage
lui-même — scénario à considérer avant la prod, pas maintenant.

---

## Séquençage des séparations

Jay a validé le principe : **un objet, un bucket, une règle**.

| # | Chantier | Effet | Migration de fichiers ? |
|---|---|---|---|
| ✅ | **Bibliothèques éphémères** | Fait le 2026-08-10 | — |
| ✅ | **Avatars privés** | Fait le 2026-08-10 : bucket fermé, URL signées via `can_view_profile` | Non (aucun avatar en base) |
| 1 | **Autorisation à l'acte** (ci-dessus) | La limite de vues devient réelle | Non |
| 2 | **Stories** | Bucket `stories` propre. Supprime le contournement des limites de livraison par `is_story_card` | **Oui** |
| 3 | **Vibes sauvegardées** | Copie dans l'espace de celui qui sauvegarde, au lieu d'un accès perpétuel au fichier d'origine | **Oui** |
| 4 | **Bibliothèque de profil publique** | Sépare le contenu ouvert du contenu réservé au cercle | **Oui** |

### La contrainte qui décide du séquençage

**Supabase interdit de déplacer ou supprimer des fichiers depuis SQL** (trigger
`storage.protect_delete` — découvert à nos dépens le 2026-08-10, voir le rapport
de session). Toute séparation qui déplace des fichiers existants exige donc soit
une Edge Function, soit un script client, soit… de repartir de zéro sur les
données de dev.

D'où l'ordre proposé : **le chantier 1 ne déplace aucun fichier**, il se fait
tout de suite. Les chantiers 2 à 4 en déplacent, et demandent d'abord une
décision de Jay :

> Purge-t-on les données de dev existantes, ou écrit-on un outil de migration ?

En base de dev, la purge est presque toujours le bon choix — mais c'est son
arbitrage.

---

## Points restants sur le contrôle, à ne pas oublier

- **`avatars` : fait**, mais vérifier au test qu'aucun écran n'affiche encore
  une photo via une URL publique mise en cache.
- **`media`** (photos et vidéos de messages) : accès par appartenance à la
  conversation, sans limite ni expiration côté fichier. Même question que les
  Vibes si ces médias doivent être éphémères.
- **Le cache local** (`CardMediaCache`) conserve MES contenus sur l'appareil.
  C'est voulu et sans effet sur la distribution, mais à connaître : ce n'est pas
  un contournement, c'est ma propre copie.
