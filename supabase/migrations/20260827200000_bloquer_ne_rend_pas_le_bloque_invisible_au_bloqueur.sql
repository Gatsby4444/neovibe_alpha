-- Bloquer coupe l'accès de CELUI QU'ON BLOQUE — pas l'inverse.
--
-- ## 🔴 Le défaut, introduit le 2026-08-27 à 16 h et trouvé à 21 h
--
-- La migration `20260827180000` a posé un garde `not private.is_blocked(a, b)`
-- en tête de `can_view_profile`. Or `is_blocked` est **symétrique** : elle est
-- vraie quel que soit celui qui a bloqué.
--
-- Conséquence, **reproduite en base sous identité** : Charles bloque mimi, et le
-- profil de mimi devient invisible **pour Charles aussi**. L'écran « Personnes
-- bloquées » lit `blocks` en joignant `profiles` — la jointure ne rend donc
-- plus rien, la liste est vide, et **il n'y a plus aucun bouton pour
-- débloquer**.
--
-- ⚠️ **Le blocage devenait irréversible depuis l'interface.** Constaté par Jay
-- pendant sa session de test : *« je n'ai pu tester que jusqu'au blocage car il
-- n'y a pas de bouton débloquer »*.
--
-- ## Ce que Jay avait demandé, mot pour mot
--
--     « je veux que bloquer un ami LUI coupe SES accès profil et stories »
--
-- *lui*, *ses* : la demande était **à sens unique**. J'ai livré du symétrique,
-- ce qui va au-delà — et l'au-delà a cassé le retour en arrière.
--
-- ## La règle, énoncée correctement
--
-- **Bloquer, c'est se retirer de la vue de quelqu'un.** Ce n'est pas se rendre
-- aveugle à lui : on doit pouvoir consulter la liste de ceux qu'on a bloqués,
-- ne serait-ce que pour les débloquer.
--
-- | Question | Sens |
-- |---|---|
-- | voir un **profil** | **une seule direction** — refusé si la CIBLE a bloqué le lecteur |
-- | voir des **stories** | symétrique — on ne veut pas non plus du contenu de quelqu'un qu'on a bloqué |
-- | **écrire** | symétrique — le silence vaut dans les deux sens |
-- | apparaître dans le **ping** | symétrique — invisibilité mutuelle à la découverte |
--
-- ⚠️ **`is_blocked` reste symétrique et n'est pas touchée** : c'est le bon outil
-- pour les trois cas symétriques. On lui ajoute une voisine à sens unique, dont
-- le nom dit lequel des deux a agi.

create or replace function private.a_bloque(qui uuid, cible uuid)
returns boolean
language sql
stable
security definer
set search_path = public, private
as $$
  select exists (
    select 1 from public.blocks
    where blocker_id = qui and blocked_id = cible
  );
$$;

comment on function private.a_bloque(uuid, uuid) is
  'Vrai si `qui` a bloqué `cible`. ⚠️ À SENS UNIQUE, contrairement à '
  '`is_blocked` : bloquer, c''est se retirer de la vue de quelqu''un, pas se '
  'rendre aveugle à lui. Sans cette distinction, la liste des comptes bloqués '
  'se vide et le déblocage devient impossible (2026-08-27).';

grant execute on function private.a_bloque(uuid, uuid) to authenticated;

-- ---------------------------------------------------------------------------
-- Voir un profil : refusé seulement si la CIBLE a bloqué le lecteur
-- ---------------------------------------------------------------------------

create or replace function private.can_view_profile(viewer uuid, target uuid)
returns boolean
language sql
stable
security definer
set search_path = public, private
as $$
  select viewer = target
    or (
      -- ⚠️ **`a_bloque(target, viewer)` et non `is_blocked`.** La cible s'est
      -- retirée de la vue du lecteur ; l'inverse ne se déduit pas. Un lecteur
      -- qui a lui-même bloqué la cible garde le droit de la voir — sinon il ne
      -- pourrait plus la retrouver pour la débloquer.
      not private.a_bloque(target, viewer)
      and (
        has_any_connection(viewer, target)
        or exists (
          select 1 from encounters e
          where e.user_low = least(viewer, target)
            and e.user_high = greatest(viewer, target)
        )
        or exists (
          select 1 from conversation_members m1
          join conversation_members m2 using (conversation_id)
          where m1.user_id = viewer and m2.user_id = target
        )
        or exists (
          select 1 from connection_requests
          where (sender_id = viewer and receiver_id = target)
             or (sender_id = target and receiver_id = viewer)
        )
        or exists (
          select 1 from recommendations
          where (intermediary_id = viewer and (requester_id = target or target_id = target))
             or (requester_id = viewer and intermediary_id = target)
             or (target_id = viewer and intermediary_id = target)
             or (requester_id = viewer and target_id = target and status = 'accepted')
             or (target_id = viewer and requester_id = target and status in ('forwarded', 'accepted'))
        )
        -- ⚠️ **Celui qu'on a bloqué reste consultable**, même si plus aucun
        -- autre lien ne subsiste : c'est ce qui permet de le retrouver dans
        -- « Personnes bloquées » et de l'y débloquer. Sans cette branche, un
        -- blocage posé sur un inconnu croisé serait définitif.
        or private.a_bloque(viewer, target)
      )
    );
$$;

grant execute on function private.can_view_profile(uuid, uuid) to authenticated;
