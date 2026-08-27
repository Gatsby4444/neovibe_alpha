-- Qui je peux reconnaître par la radio se décide sur les CLÉS, pas sur la
-- visibilité d'un profil.
--
-- ## 🔴 Le défaut, constaté chez Jay le 2026-08-27 à 20 h 58
--
-- Son diagnostic porte, sur les **deux** appareils, juste après qu'il ait
-- bloqué :
--
--     incidents consignés : 1
--          1  amis retirés du carnet
--     20:58:20  amis retirés du carnet (—) — 1 retiré(s)
--
-- **Le blocage a vidé le carnet d'amis local des deux côtés.** La
-- reconnaissance BLE s'est arrêtée, et plus aucun constat de croisement n'a été
-- produit.
--
-- ## Le chemin exact
--
-- `_pullFriendKeys` lit `device_keys` (dont la politique RLS ne rend que les
-- amis), **puis** joint `profiles` pour le nom d'affichage. Et il fait :
--
--     final profile = byId[row['user_id']];
--     if (profile == null) continue;      // ← l'ami disparaît, en silence
--
-- Or `profiles` passe par `can_view_profile`. Le garde de blocage posé à 16 h
-- rendait le profil invisible → la jointure ne rendait rien → l'ami était
-- **retiré du carnet**.
--
-- ⚠️ **Une absence de NOM faisait donc perdre une CLÉ.** C'est exactement le
-- faux positif que la ligne juste en dessous prend soin d'éviter pour la clé
-- X25519 — *« un ami sans clé n'est PAS un ami parti »* — et qui n'était pas
-- gardé une ligne plus haut.
--
-- ## La règle, remise à l'endroit
--
-- **`device_keys` décide qui je reconnais. Le profil ne fournit qu'un nom.**
-- Une source d'affichage ne doit jamais pouvoir révoquer une capacité.
--
-- Ce qui suppose que `device_keys` porte, à lui seul, la bonne réponse — donc
-- qu'il tienne compte du blocage. C'est ce que fait cette migration.
--
-- ⚠️ **Sens du filtre : celui qui a bloqué disparaît de la vue de l'autre.**
-- Si Charles bloque mimi, mimi cesse de recevoir la clé de Charles, donc cesse
-- de le reconnaître — c'est *exactement* ce que « bloquer » veut dire. Charles,
-- lui, garde la clé de mimi : il n'a pas demandé à devenir aveugle, et c'est le
-- même raisonnement que `private.a_bloque` sur les profils.

drop policy if exists device_keys_friends on public.device_keys;

create policy device_keys_friends on public.device_keys
  for select to authenticated
  using (
    exists (
      select 1 from public.connections c
      where c.status = 'full'
        and ((c.user_low = (select auth.uid()) and c.user_high = device_keys.user_id)
          or (c.user_high = (select auth.uid()) and c.user_low = device_keys.user_id))
    )
    -- ⚠️ **La clé de celui qui m'a bloqué ne m'est plus donnée.** Sans elle, je
    -- ne calcule plus son jeton de paire, donc je ne le reconnais plus — le
    -- blocage devient effectif jusque dans la radio, pas seulement à l'écran.
    and not private.a_bloque(device_keys.user_id, (select auth.uid()))
  );

comment on policy device_keys_friends on public.device_keys is
  'La clé publique de mes amis — sauf ceux qui m''ont bloqué. ⚠️ Cette '
  'politique décide À ELLE SEULE qui je peux reconnaître par la radio : le '
  'client ne doit jamais retirer un ami de son carnet parce qu''un PROFIL est '
  'invisible (défaut du 2026-08-27, qui vidait le carnet des deux côtés au '
  'premier blocage).';
