# Plan de test — v0.9.167

*Établi le 2026-08-30. Jay fera les tests plus tard.*

Les deux appareils doivent être en **v0.9.167**, sinon les relevés ne se
comparent pas. Téléphone = **Charles** (Xiaomi M2101K6G, Android 13) ·
tablette = **mimi** (Lenovo TB-X606F, Android 10).

⚠️ **Lire d'abord « Ce qui fausse la lecture » en bas** : deux défauts connus
peuvent faire mal interpréter les résultats.

---

## ✅ Déjà fait — les tuiles du Ping (v0.9.165)

Validé par Jay le 2026-08-30 : *« j'ai checké les nouvelles tuiles et c'est très
bien »*. Format 4:3 vertical, photo centrée en haut, toutes identiques.

🟡 **Non tranché** : l'aspect sur **tablette**, où deux colonnes en 4:3 donnent
une tuile large donc haute. À regarder au prochain passage sur la tablette ; si
c'est trop grand, il faudra arbitrer entre le nombre de colonnes et le format.

---

## Test 1 — « Tout près » et « Le presque »

Les deux se testent **en une seule manipulation** : la fenêtre du presque
commence là où celle de « tout près » finit.

### Préalables

- « Croiser mes amis » **activé** sur les deux (Réglages → Sécurité et
  confidentialité).
- « Notifications en temps réel » **activé sur le téléphone**, sinon le palier
  « Ami » ajoute **45 minutes** avant « Tout près ».

### La manipulation

| | Geste | Attendu |
|---|---|---|
| 1 | Bluetooth **OFF** sur la tablette. **Attendre 2 h.** | rien |
| 2 | Bluetooth **ON** 10 secondes, puis **OFF** | **« Tout près… mimi est juste à côté »**, immédiatement |
| 3 | Ne pas rallumer. **Attendre 1 h.** | **« Le presque… mimi est passé tout près de toi »** |
| 4 | Profil → ♥ | le presque y figure · « Tout près » **n'y figure pas** |

### Pourquoi ces attentes, et pourquoi elles ne sont pas négociables

⚠️ **Les 2 heures sont la règle n°1 de Jay**, pas une précaution. Chez lui les
deux appareils s'entendent en permanence : il y a donc en permanence « une
présence de plus de 5 min dans les 2 dernières heures », et **aucun presque ne
peut partir**. Couper le Bluetooth de la tablette est le seul moyen de fabriquer
un vrai « on ne s'est pas vus ».

⚠️ **Jusqu'à 5 minutes de battement à l'étape 3** : le verdict est rendu par
`_rendreVerdicts`, qui tourne toutes les 5 minutes. Ouvrir l'app force un tour
immédiat.

⚠️ **Le presque n'arrive que sur le TÉLÉPHONE.** La tablette, dont on coupe le
Bluetooth, ne mesure aucune fin de présence.

### Si rien n'arrive à l'étape 2

Fenêtre trop courte : il faut au moins **5 détections**
(`WaveRules.presDetectionsMin`). 10 secondes suffisent largement en temps
normal — si ça échoue, c'est la radio qu'il faut regarder, pas la règle.

### Si rien n'arrive à l'étape 3

Vérifier d'abord le **délai de garde de 2 heures** par personne
(`ProximityController.waveCooldown`) : un presque déjà parti bloque le suivant.

---

## Test 2 — 🔴 LE CONTRE-TEST, le plus important des quatre

Rallumer le Bluetooth de la tablette et **laisser les deux appareils ensemble
une demi-journée, sans rien faire.**

**Attendu : AUCUNE notification. Pas une seule.**

C'est exactement le spam signalé par Jay le 2026-08-30 (*« wave devient un spam
incessant de proximité »*). Une notification qui arrive alors que les deux ne se
sont pas quittés veut dire que la règle ne tient pas — et **ce test vaut plus
que tous les tests positifs réunis** : un système qui notifie trop est
indiscernable, vu du code, d'un système qui marche.

---

## Test 3 — Le ping inconnus — ~10 minutes

⚠️ **Charles et mimi ne peuvent pas le faire : `ping_nearby` exclut
explicitement les gens déjà connectés.** Relevé en base le 2026-08-30 : sur les
huit comptes réels, seuls **Sofia** et **Yanis** ne sont pas amis de Charles et
ne sont bloqués dans aucun sens.

1. Tablette : se déconnecter de mimi, se connecter en `yanis.bot@neovibe.dev`
   (mot de passe dans `docdev/bot-credentials.txt`).
2. Les deux : écran Ping, **« Visible à proximité »** activé.
3. **Laisser les deux applications à l'écran.** La balise qui traduit le signal
   en personne n'est rafraîchie que pendant que l'écran est affiché, et elle
   meurt au bout de **5 minutes** (`private.ping_beacon_ttl()`).
4. Position **précise** exigée ; l'app le dit si Android n'a donné que
   l'approximative.
5. La paire n'existe que quand **les deux** ont confirmé (`confirm_ping`, le
   miroir). Quelqu'un reste affiché **10 minutes** après la dernière preuve
   (`private.fenetre_rencontre()`).

### Ce qu'on regarde

- La tuile 4:3, photo en haut.
- **La mention de Yanis fait exactement 45 caractères** — la limite de saisie.
  Tient-elle sur deux lignes sans être rognée ?
- Les deux boutons : « demander en ami » et « écrire ».

⚠️ Faire la demande d'ami avec **Yanis** et garder **Sofia** propre pour un
prochain test : un bot devenu ami ne peut plus servir à ce test.

---

## Test 4 — La nuit

Les deux appareils en v0.9.167, laissés une nuit, puis **un diagnostic sur
chacun** au réveil (ils arrivent dans `dev_reports`).

### Les trois lignes à relever

| Ligne | Lecture |
|---|---|
| `slotAlarmReveils` | ≈ **40** sur une nuit de 10 h. **0 = l'alarme n'a jamais sonné**, le correctif de la v0.9.164 n'a pas pris |
| `slotAlarmRetardMaxMillis` | au-delà d'un quart d'heure, Doze a repoussé le réveil hors de la fenêtre de tolérance |
| `advertSlotDriftMax` (+ son âge) | **0 ou 1** = la page a toujours été tournée à l'heure. Élevé = le jeton est resté figé |

🔴 **Le chiffre à regarder en premier** : `slotAlarmReveils` sur le
**téléphone**. Au relevé du 2026-08-30 à 14 h 37 il valait **0** après ~52 min
de service et trois changements de créneau, alors que la tablette en était
à **2** (11 s de retard max). Si c'est encore 0 au matin, le réveil ne sonne pas
sur ce téléphone et il faudra chercher pourquoi (MIUI ?).

### Et ce qu'on ne peut PAS encore relever

Le **carnet des présences** n'est branché sur aucun rapport — voir ci-dessous.

---

## ⚠️ Ce qui fausse la lecture — deux défauts connus, non corrigés

### 1. Le réglage ment

Réglages → Sécurité et confidentialité affiche toujours
**« Waves — le presque »** et *« Par défaut, tu es prévenu après coup »*.
**C'est faux depuis la v0.9.166** : cet interrupteur commande désormais
**« Tout près »**, et le presque est différé d'une heure quoi qu'il arrive.
`RAPPELS.md` #105.

### 2. Le carnet des présences est invisible

`PresenceBook` n'apparaît dans aucune section du diagnostic. **La question
« les durées se mesurent-elles pendant que le téléphone dort ? » ne peut donc
pas être répondue par le test de nuit**, contrairement à ce que j'ai annoncé à
Jay le 2026-08-30. `RAPPELS.md` #106.

⚠️ **C'est la deuxième fois dans la même journée** que je livre un instrument
dont la sortie n'est pas lisible — après `advertSlotDrift`. Corriger les deux
avant le test de nuit rendrait la nuit exploitable ; les laisser fait perdre une
nuit.
