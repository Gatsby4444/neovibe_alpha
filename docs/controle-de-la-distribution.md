# Contrôle de la distribution

> Mot d'ordre donné par Jay le 2026-08-10 : **« comme Apple : contrôle complet
> de l'écosystème »**.
>
> État au 2026-08-10 au soir : le **mécanisme est livré** (v0.9.46) ; le plan de
> séparation des buckets qui l'accompagnait a été **retiré le même jour** — voir
> la section révisée. Ce qui reste à faire y est marqué comme tel.

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

## Le défaut, et ce qui l'a corrigé (v0.9.46)

**Avant** : une face était servie parce qu'une **permission permanente** existait
(`can_view_card_file`). Le compteur de vues vivait ailleurs, dans
`mark_card_viewed`, une RPC que le client **choisissait** d'appeler. Pire, la
face reçue était mise en cache local et c'est l'app qui purgeait son propre
cache à l'épuisement. **La limite n'était pas une garantie serveur : c'était une
convention client.**

### Le mécanisme retenu : la clé délivrée par le décompte

**Une première proposition a été écartée par Jay** : signer une URL courte à
chaque vue. Elle fonctionnait, mais imposait de **retélécharger la face à chaque
visionnage** — donc de multiplier l'egress, contre la contrainte de coût posée
au début du projet. Objection décisive.

Le modèle retenu est celui des bibliothèques éphémères, généralisé :

```
   1. Les faces sont CHIFFREES au dépôt (AES-256-GCM).
   2. Les octets voyagent UNE FOIS et restent en cache local, chiffrés.
   3. À chaque ouverture :
        client → open_card_media(card_id)
                   │ vérifie le droit
                   │ DÉCRÉMENTE le compteur
                   │ rend la clé          ← une seule transaction
                   ▼
              déchiffrement en local, affichage
```

**Pourquoi c'est robuste** : le décompte n'est plus une étape que le client peut
sauter — **c'est l'acte qui délivre la clé**. Pas de décompte, pas de clé, pas
d'image. Il n'y a plus de porte dérobée, il n'y a plus qu'une porte.

**Pourquoi c'est bon marché** : seule la clé (44 caractères) circule à chaque
vue. Le nombre de téléchargements de médias ne bouge pas — trois ordres de
grandeur sous une URL signée par vue.

### Ce que ça ne fait pas

Un client modifié qui a **déjà déchiffré une fois** peut conserver le clair.
Aucun mécanisme ne l'empêche sans retélécharger — précisément le coût refusé.
La garantie est donc : **aucun accès NOUVEAU sans le serveur**, pas « on ne
revoit jamais ce qu'on a déchiffré ».

### Effets de bord obtenus

- Le cache de l'appareil ne contient plus rien de lisible, **même pour ses
  propres Vibes** (le scellé y est rangé tel quel).
- Le clair ne vit que dans le répertoire temporaire, le temps de l'écran.
- Le bucket lui-même devient **peu critique** : les octets y sont inertes. C'est
  ce constat qui a fait tomber le plan de séparation ci-dessous.

---

## Séquençage des séparations — RÉVISÉ le 2026-08-10 au soir

⚠️ **Le plan initial de ce document a été retiré le jour même**, après une
objection de Jay. Il proposait de séparer stories, sauvegardes et bibliothèque
publique dans des buckets distincts. **Deux erreurs de raisonnement** :

**1. Ces objets ne sont pas distincts.** Une vibe de bibliothèque éphémère est un
objet à part — jamais envoyée, sans livraison, sans limite de vues : elle n'a
jamais eu deux copies. Stories, sauvegardes et bibliothèque publique sont
**la même Vibe dans plusieurs états de publication**. Les séparer physiquement
**dupliquerait des fichiers identiques** : une Vibe envoyée en DM, publiée et
mise en story vivrait en trois exemplaires — sur des faces vidéo, le poste le
plus lourd de l'app. C'est Jay qui l'a vu.

**2. Le chiffrement a déplacé le problème.** Avant lui, « accéder au fichier »
signifiait « voir l'image », donc le bucket comptait. Depuis la v0.9.46, **les
octets sont inertes partout** : ce qui décide est uniquement **qui obtient la
clé**, et cela se joue dans une seule fonction (`open_card_media`). Le contrôle
n'est plus une question de **stockage** mais de **politique de clé**.

**Leçon de méthode** : après un changement d'architecture, rejouer les décisions
qui en dépendaient au lieu de dérouler un plan écrit avant.

### Ce qui reste au programme

| # | Chantier | Verdict | Motif |
|---|---|---|---|
| ✅ | Bibliothèques éphémères | Fait | Objet réellement distinct, aucune duplication |
| ✅ | Avatars privés | Fait | Le bucket était public |
| ✅ | Limite de vues garantie | Fait (v0.9.46) | Le décompte délivre la clé |
| ❌ | Stories — bucket | **Abandonné** | Duplication coûteuse, gain nul depuis le chiffrement |
| ❌ | Bibliothèque publique — bucket | **Abandonné** | Idem |
| ❓ | Stories — règle de vues | **En attente de Jay** | Gratuit, mais change la sémantique |
| ⏳ | Sauvegardes — copie réelle | **À faire** | Corrige une promesse non tenue |

### Stories : une question de produit, pas de sécurité

Publier une Vibe en story **annule** aujourd'hui la limite de vues fixée pour un
destinataire en DM : `has_unlimited_card_access` est évaluée **avant** la
livraison. Ce n'est pas un trou — c'est la règle affichée dans l'app — mais
l'émetteur ne réalise probablement pas qu'en publiant une story il vide de son
sens le « 2 vues » qu'il a choisi.

Correctif : quelques lignes dans `open_card_media`, **zéro octet dupliqué**.
Revers : un destinataire ayant épuisé ses vues ne verrait plus une story que
tout le monde voit. **Question posée à Jay le 2026-08-10, sans réponse.**

### Sauvegardes : le seul cas où dupliquer est le BUT

`saved_cards_card_id_fkey` est en **`ON DELETE CASCADE`** : si l'auteur supprime
sa Vibe, **tous ceux qui l'ont enregistrée la perdent, sans avertissement**. Or
« Enregistrer » promet de garder.

Une vraie copie dans l'espace de celui qui sauvegarde règle le problème, et son
coût est **borné** — seulement les Vibes marquées sauvegardables **et**
réellement enregistrées (16 sur 64 en base de dev). Ici la duplication n'est pas
un coût subi : c'est exactement ce qui rend la sauvegarde indépendante de son
auteur.

### La contrainte qui commande toute migration de fichiers

**Supabase interdit de déplacer ou supprimer des fichiers depuis SQL** (trigger
`storage.protect_delete`). Toute séparation touchant des fichiers existants exige
une Edge Function, un script client, ou une purge des données de dev.

**Décision de Jay (2026-08-10) : on purge.** Non exécutée à ce jour — elle n'a
d'utilité qu'au moment où on déplace des fichiers, et détruirait entre-temps les
64 Vibes qui servent à vérifier la compatibilité des Vibes non chiffrées.

## Points restants sur le contrôle, à ne pas oublier

- **`avatars` : fait**, mais vérifier au test qu'aucun écran n'affiche encore
  une photo via une URL publique mise en cache.
- **`media`** (photos et vidéos de messages) : accès par appartenance à la
  conversation, sans limite ni expiration côté fichier. Même question que les
  Vibes si ces médias doivent être éphémères.
- **Le cache local** (`CardMediaCache`) conserve MES contenus sur l'appareil.
  C'est voulu et sans effet sur la distribution, mais à connaître : ce n'est pas
  un contournement, c'est ma propre copie.
