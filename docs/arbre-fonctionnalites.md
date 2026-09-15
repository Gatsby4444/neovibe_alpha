# Arbre des fonctionnalités NeoVibe

*Demandé par Jay le 2026-09-10. **En vrac et sans arbitrage** : l'objectif est de
voir ce qu'on a, avant de décider comment l'organiser dans l'UI.*

**Relevé dans le code réel** (écrans, libellés, modèles), pas dans les docs.
Légende : ✅ existe et marche · 🚧 existe à moitié · ⬜ décidé mais pas écrit ·
❓ à trancher.

---

## 0. La racine — 5 onglets en bas

`lib/features/home/home_shell.dart`. Libellés masqués depuis le 2026-08-15
(consigne de Jay : « les icônes se suffisent »).

```
NeoVibe
├── 1. Vibe      (la caméra)     ✅
├── 2. Ping      (la proximité)  ✅
├── 3. Cercle    (les relations) ✅
├── 4. Jeux                      ⬜ VIDE — écran « Bientôt ici »
└── 5. Profil                    ✅
```

⚠️ **« Vibe » n'est pas une destination** : appuyer dessus ouvre la caméra
par-dessus. Il reste donc **4 vraies sections** + un déclencheur.

---

## 1. VIBE — capturer

```
Vibe
├── Types de Vibe (3 sélectionnables)
│   ├── Standard ✅        recto, puis verso FACULTATIF (bouton « Passer »)
│   ├── Oneshot ✅         les 2 faces d'un seul déclenchement, caméra pure
│   │   ├── double live GPU (2 textures simultanées) ✅ si l'appareil sait
│   │   └── repli séquentiel si non ✅  (+ repli photo-seule)
│   ├── BeReal 🚧          fenêtre déclenchée par notification, sans retouche
│   └── One of One         PAS un type : s'applique tout seul à l'envoi
│                          (1 destinataire, aucune publication) ✅
├── Prise de vue
│   ├── Photo — tap ✅
│   ├── Vidéo — appui maintenu ✅ + verrouillage (tape pour arrêter) ✅
│   ├── Changer de caméra ✅   (exclu du Oneshot et du BeReal)
│   ├── Flash ✅ + flash frontal par lueur d'écran ✅
│   ├── Miroir de la frontale ✅ (réglage)
│   └── Importer depuis la galerie ✅
├── Après la prise
│   ├── Reprendre le recto ✅
│   ├── Éditeur de face 🚧   `face_editor_screen.dart` — post-production
│   └── ⚠️ exclu du Oneshot par principe
└── → écran d'envoi
```

**Manque / à décider**
- ❓ Filtres, stickers, texte, dessin — quel niveau ? (rappel : pivot du
  2026-08-14, la barre est « parfaitement fonctionnel », pas « battre Snapchat »)
- ⬜ Le **Rush** (RAPPELS #117) : compte à rebours pour OUVRIR — 1 min / 5 min /
  30 min / 1 h / 2 h. Propriété de l'envoi, pas du contenu.

---

## 2. ENVOI — les 5 contextes de diffusion

`share_screen.dart`. **C'est le cœur de l'architecture** : un contenu appartient
à UN contexte, jamais deux.

```
Partager ma Vibe
├── Publier sur…
│   ├── Ma story ✅            24 h · visible par palier :
│   │                          Tous mes amis / Mes proches / Mes inséparables
│   └── Ma bibliothèque ✅     grille de profil, permanente, sans limite de vues
├── Pour les personnes
│   ├── Ami(e)s ✅             recherche, filtres Tout / Ami(e)s / Groupes
│   ├── Conversations & groupes ✅
│   │   └── « Aussi dans la bibliothèque du groupe » ✅
│   └── Croisé(e)s aujourd'hui ✅   la Vibe part AVEC la demande de connexion
├── Options par destination
│   ├── Partageable ✅
│   ├── Sauvegardable ✅
│   └── Visible par les gens que tu croises ✅
├── Réglages de la Vibe elle-même
│   ├── durée de vue par face ✅   (`view_duration_seconds`, 10 s par défaut)
│   └── nombre de vues ✅          (`max_views`, 2 par défaut, chat seulement)
└── Enregistrer pour moi ✅    5ᵉ contexte — octets EN CLAIR sur l'appareil,
                               aucune clé, aucune ligne serveur, permanent
```

---

## 3. PING — la proximité

```
Ping
├── Interrupteur « Visible à proximité » ✅   (découverte d'INCONNUS)
│   └── identifiant Bluetooth tournant toutes les 15 min ✅
├── Interrupteur « Croiser mes amis » ✅      (dans Réglages > Confidentialité)
├── Autour de toi ✅
│   ├── inconnus à portée → « Demander à se connecter » ✅
│   ├── « Demande envoyée — en attente de sa réponse » ✅
│   └── message ✅ (canal de proximité limité au TEXTE)
├── Croisés récemment ✅
├── Stories des gens que tu croises ✅
├── États de la radio ✅   Bluetooth éteint · localisation éteinte ·
│                          permission manquante · BLE indisponible ·
│                          détection interrompue · « tu n'es pas annoncé »
└── Diagnostic de proximité ✅  (dev, à retirer avant la prod)
```

**Manque / à décider**
- ⬜ **Carte des amis** façon Snapchat (demande de Jay, 2026-09-10) — voir
  RAPPELS #119.
- ⬜ **Émission modulée par la distance** (RAPPELS #116).
- 🚧 **Streaks de proximité** : le champ `serie` existe et nourrit les paliers,
  mais **aucun affichage de palier de couleur ni de dégradation**.

---

## 4. CERCLE — les relations et les échanges

```
Cercle
├── Barre de stories (amis) ✅
├── Filtres : Tout / Amis / Groupes ✅
├── Conversations ✅
│   ├── 1-à-1 ✅
│   ├── Groupes ✅ — créer, réglages du groupe ✅
│   └── Catégories ✅ — créer / renommer / supprimer
├── Constellation 🚧   vue « graphe » des amis — SACCADE au-delà de ~60 amis
├── Dans une conversation
│   ├── messages texte éphémères 24 h ✅
│   ├── limite anti-spam : 3 messages sans réponse ✅
│   ├── « en train d'écrire… » ✅
│   ├── envoyer une Vibe ✅ / une vidéo ✅
│   ├── états d'une Vibe reçue ✅  Nouvelle · Appuie pour ouvrir · Rouvrir ·
│   │                              Épuisée · Détruite
│   ├── Ajouter à la bibliothèque ✅
│   └── ⚠️ un bouton « Action à définir » est en place SANS action  🚧
├── Bibliothèque de conversation ✅
│   └── reveal simultané à 18h30 pour tout le monde ✅
│       └── ⬜ le DÉCOMPTE approuvé par Jay n'est pas écrit (RAPPELS #115 ③)
└── Paliers d'amitié ✅ (3)   Ami · Proche · Inséparable
    └── ⬜ 2 badges intermédiaires demandés (5 au total), sans noms encore
```

---

## 5. JEUX — ⬜ ENTIÈREMENT VIDE

L'écran affiche « **Bientôt ici** — Quiz, mini-jeux et compatibilité, avec tes
amis ». C'est tout le contenu de l'onglet.

⚠️ **C'est la moitié du produit qui manque**, au sens de `CLAUDE.md` : c'est ce
qui donne sa légitimité à la barrière physique.

---

## 6. PROFIL

```
Profil
├── Ma bibliothèque ✅   grille (le « deck » a été retiré le 2026-09-15)
│   ├── Publier ✅  (2026-09-15) → une Vibe (caméra restreinte à la
│   │                 publication) ou Photos / vidéos (l'éditeur d'album :
│   │                 jusqu'à 11 médias, ratio, filtres, réglages, rognage,
│   │                 légende, visibilité, droits — `docs/plan-publications.md`)
│   ├── retirer de la bibliothèque ✅
│   └── toucher une case → le fil des publications du profil ✅ (2026-09-15)
│       ├── posé sur la publication touchée, on défile les autres
│       ├── album : carrousel au ratio · Vibe : carte qui se retourne
│       ├── aimer ✅ (cœur, compte, « qui a aimé ») · enregistrer · partager
│       └── toucher une Vibe → plein écran façon Reels ✅ (glisser = suivante)
├── Modifier le profil ✅  + avatar avec recadrage ✅
├── Demandes & rencontres ✅  (3 onglets)
│   ├── Demandes ✅       en attente à proximité · historique
│   ├── Recos ✅          propositions de mise en relation · demandes à
│   │                     transmettre · mes demandes (plafond 10/mois)
│   └── Waves ✅          « X est passé tout près de toi »
├── Réglages →
└── Se déconnecter ✅
```

---

## 7. RÉGLAGES

```
Réglages
├── Apparence et démarrage ✅   thème · onglet d'ouverture
├── Vibes ✅                    inverser le sens de retournement ·
│   │                           enregistrements
│   └── Stockage des Vibes ✅   copies locales, cache, espace alloué
├── Caméra ✅                   miroir de la frontale
├── Partage et visibilité ✅    stories publiques (réglage de PROFIL, pas par
│                               story 🚧 RAPPELS #108) ·
│                               visible par toutes mes connexions /
│                               accès restreint (liste choisie)
├── Sécurité et confidentialité ✅
│   ├── Croiser mes amis ✅
│   ├── Personnes bloquées ✅
│   └── Me prévenir tout de suite ✅  (waves en temps réel, opt-in)
└── Développeur 🚧              À RETIRER AVANT LA PRODUCTION
    └── flags · logs · outils · mise à jour · mesure vidéo ·
        inspecteur de règles · logs caméra · aperçu GL · cycle du jour
```

---

## 8. TRANSVERSE (pas un onglet)

```
├── Auth ✅            inscription / connexion / onboarding
├── Notifications ✅
│   ├── « X est juste à côté » ✅  instantanée, tous les amis, s'annule au départ
│   ├── « le presque » ✅          différée par palier (0 / 15 / 45 min)
│   └── déclencheur BeReal 🚧
├── Anti-capture 🚧    flags OS posés ; watermarking, détection d'anomalie et
│                      couche contractuelle ⬜
├── Chiffrement & livraison scellée ✅
└── Blocage ✅
```

---

## 9. Ce qui est décidé mais n'existe nulle part

| Sujet | Où c'est écrit | État |
|---|---|---|
| **Jeux / quiz / compatibilité** | `CLAUDE.md`, vision-produit | ⬜ rien |
| **Feed local** (ville / région / pays) | RAPPELS #10, décidé le 2026-07-26 | ⬜ rien |
| **Événements** (créer, organiser, rejoindre) | demandé par Jay le 2026-09-10 | ⬜ rien |
| **Mode soirée / événement** | énoncé le 2026-08-29 | ⬜ rien |
| **Carte des amis** | demandé par Jay le 2026-09-10 | ⬜ rien |
| **Le Rush** | RAPPELS #117 | ⬜ rien |
| **Refonte visuelle « le rond »** | RAPPELS #100, arrêtée le 2026-08-29 | ⬜ rien |
| **2 paliers d'amitié de plus** | décision du 2026-09-01 | ⬜ rien |
| **Streaks visibles** (couleurs, dégradation) | `CLAUDE.md`, décision verrouillée | 🚧 donnée seule |

---

## 10. Le constat, en une phrase

**Tout ce qui est construit sert à ENTRER dans le réseau et à s'y ENVOYER des
images.** Rien n'est construit pour **y rester** : l'onglet Jeux est vide, le
feed local n'existe pas, les événements non plus, et les streaks n'ont pas
d'affichage.

C'est exactement le déséquilibre annoncé dans `CLAUDE.md` : *« une barrière sans
contrepartie ne retient personne »*. La barrière est finie ; la contrepartie
n'est pas commencée.
