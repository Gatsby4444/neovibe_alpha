-- ════════════════════════════════════════════════════════════════════════
-- Correctifs de l'audit du 2026-08-31
-- ════════════════════════════════════════════════════════════════════════
--
-- Sept chantiers, dans cet ordre :
--
--   1. C1 — l'étiquette `pair_key` n'est plus modifiable par un client
--   2. C2 — une demande d'ami ne s'écrit plus qu'à travers la fonction
--   3. M4 — dans un groupe, seuls soi-même et le créateur retirent un membre
--   4. M5 — le blocage s'énonce à UN seul endroit, et emporte l'accès nominatif
--   5. H4 — la clé se lit AVANT de décompter une vue
--   6. H3 — les octets d'un contenu supprimé sont inscrits pour suppression
--   7. nettoyage ponctuel de ce que ces défauts ont laissé derrière eux
--
-- Chaque bloc dit ce qu'il ferme et comment le défaut se reproduirait.


-- ════════════════════════════════════════════════════════════════════════
-- 1. C1 — DÉTOURNEMENT D'UNE CONVERSATION PRIVÉE PAR L'ÉTIQUETTE
-- ════════════════════════════════════════════════════════════════════════
--
-- Le défaut, relevé le 2026-08-31.
--
-- Une conversation directe se retrouve par `pair_key` = `direct:<A>:<B>`, et
-- `get_or_create_direct_conversation` fait « insère, et si l'étiquette existe
-- déjà ne fais rien », puis « rends-moi la ligne qui la porte ».
--
-- Or la politique `conversations_update_group_member` autorise tout membre
-- d'un groupe à écrire dans ce groupe, et le rôle `authenticated` détenait
-- `UPDATE` sur **toutes** les colonnes — `pair_key`, `created_by` et
-- `conversation_type` comprises. La politique ne vérifiait que le type.
--
-- Chemin complet : je crée un groupe (autorisé, seul), j'y pose l'étiquette
-- `direct:<Alice>:<Bob>`. À la prochaine ouverture de leur conversation, le
-- serveur trouve l'étiquette, rend **mon** groupe, et y ajoute Alice et Bob.
-- Leurs messages arrivent dans une conversation dont je suis membre.
--
-- ⚠️ **La correction est un DROIT DE COLONNE, pas une condition de plus.**
-- Une politique dit qui touche à la LIGNE ; elle ne sait pas dire quelles
-- colonnes. Tant que le droit existe, toute future politique un peu plus large
-- rouvre la porte sans que personne ne le voie. Le droit retiré, la colonne est
-- inatteignable quoi qu'il arrive ensuite — c'est la règle 4 de `CLAUDE.md` :
-- « ce champ n'est pas modifiable » vaut mieux que « aucune politique ne
-- l'autorise aujourd'hui ».
--
-- Vérifié avant d'écrire : le seul `update` du client sur cette table est
-- `{'title': ...}` (`conversations_repository.dart:191`). Rien d'autre ne casse.

revoke update on public.conversations from anon, authenticated;
grant update (title) on public.conversations to authenticated;

-- ⚠️ **Et le PROTOCOLE de résolution devient explicite.** Le droit de colonne
-- suffit à fermer la porte connue ; ceci ferme la famille. Chercher une
-- conversation par sa seule étiquette, c'est faire confiance à une valeur pour
-- désigner un TYPE d'objet. On exige donc les deux, et on refuse au lieu de
-- rendre `null` — un `null` silencieux ici produisait un `conv_id` nul et une
-- insertion de membres qui échoue plus loin, sans dire pourquoi.

create or replace function public.get_or_create_direct_conversation(peer uuid)
returns uuid
language plpgsql
security definer
set search_path to 'public', 'private'
as $$
declare
  me uuid := auth.uid();
  key text;
  conv_id uuid;
begin
  if not are_connected(me, peer) then
    raise exception 'Messagerie directe réservée aux connexions établies';
  end if;
  key := 'direct:' || least(me, peer) || ':' || greatest(me, peer);

  insert into conversations (conversation_type, pair_key, created_by)
  values ('direct', key, me)
  on conflict (pair_key) do nothing;

  -- ⚠️ **Le TYPE fait partie de la question.** Sans lui, une ligne d'un autre
  -- type portant cette étiquette serait acceptée comme la conversation directe
  -- de deux personnes qui ne l'ont jamais ouverte.
  select id into conv_id
  from conversations
  where pair_key = key and conversation_type = 'direct';

  if conv_id is null then
    raise exception 'Conversation directe indisponible';
  end if;

  insert into conversation_members (conversation_id, user_id)
  values (conv_id, me), (conv_id, peer)
  on conflict do nothing;

  return conv_id;
end;
$$;

create or replace function public.get_or_create_proximity_conversation(peer uuid)
returns uuid
language plpgsql
security definer
set search_path to 'public', 'private'
as $$
declare
  me uuid := auth.uid();
  key text;
  conv_id uuid;
begin
  if are_connected(me, peer) then
    raise exception 'Déjà connectés : utilisez la messagerie directe';
  end if;

  -- La même fenêtre qu'écrire, et c'est le point : sinon on pourrait rouvrir
  -- un canal dans lequel on n'a pas le droit d'écrire.
  if not exists (
    select 1 from public.ping_pairs pp
    where ((pp.user_low = me and pp.user_high = peer)
        or (pp.user_low = peer and pp.user_high = me))
      and pp.last_seen_at > now() - private.fenetre_canal()
  ) then
    raise exception 'Proximité non constatée';
  end if;

  key := 'prox:' || least(me, peer) || ':' || greatest(me, peer);

  insert into conversations (conversation_type, pair_key, created_by)
  values ('proximity', key, me)
  on conflict (pair_key) do nothing;

  select id into conv_id
  from conversations
  where pair_key = key and conversation_type = 'proximity';

  if conv_id is null then
    raise exception 'Canal de proximité indisponible';
  end if;

  insert into conversation_members (conversation_id, user_id)
  values (conv_id, me), (conv_id, peer)
  on conflict do nothing;

  return conv_id;
end;
$$;


-- ════════════════════════════════════════════════════════════════════════
-- 2. C2 — LA BARRIÈRE FONDATRICE N'ÉTAIT TENUE QUE PAR LE CLIENT
-- ════════════════════════════════════════════════════════════════════════
--
-- Le défaut, relevé le 2026-08-31.
--
-- `request_connection_from_proximity` porte, en toutes lettres, « LA BARRIÈRE
-- FONDATRICE » : pas de demande d'ami sans proximité constatée. Mais la table
-- `connection_requests` était **ouverte en écriture directe** — la politique
-- `requests_insert_sender` n'exigeait que d'être l'expéditeur et de ne pas être
-- déjà ami. Aucun ticket, aucun déclencheur, aucune contrainte.
--
-- Deux conséquences, et la seconde est la plus discrète :
--
--   • on demandait en ami n'importe quel identifiant sans l'avoir rencontré ;
--   • `can_view_profile` s'ouvre dès qu'une demande existe **dans un sens ou
--     dans l'autre** — écrire la ligne suffisait donc à ouvrir le profil.
--
-- Et le blocage ne l'arrêtait pas : `block_user` supprime les demandes en
-- cours, mais rien n'empêchait d'en réinsérer une aussitôt.
--
-- ⚠️ **Deux chemins vers une même table, c'est le plus permissif qui gagne**
-- (règle 2 de `CLAUDE.md`). On ne durcit donc pas la politique : on **retire le
-- chemin**. La fonction reste, elle est `security definer`, elle n'est pas
-- concernée par ce retrait.
--
-- Vérifié avant d'écrire : le client ne fait que LIRE cette table (deux flux
-- temps réel et un historique). Aucun `insert`, `update` ni `delete`.

revoke insert, update, delete on public.connection_requests from anon, authenticated;

-- Les politiques d'écriture partent avec le droit. Les garder aurait laissé
-- une règle qui décrit un chemin qui n'existe plus — donc une invitation à
-- redonner le droit un jour « puisque la politique est déjà là ».
drop policy if exists "requests_insert_sender" on public.connection_requests;
drop policy if exists "requests_update_sender" on public.connection_requests;

-- ⚠️ **Et la fonction apprend le blocage.** Elle ne le consultait pas : elle
-- vérifiait la proximité, ce qui suffisait tant que `block_user` effaçait le
-- ticket. Mais « la proximité a été constatée » et « cette personne veut bien
-- de moi » sont deux questions, et une seule était posée.
create or replace function public.request_connection_from_proximity(peer uuid)
returns uuid
language plpgsql
security definer
set search_path to 'public', 'private'
as $$
declare
  me uuid := auth.uid();
  req_id uuid;
begin
  if me is null then
    raise exception 'Non authentifié';
  end if;
  if peer is null or peer = me then
    raise exception 'Destinataire invalide';
  end if;

  -- ⚠️ **Le blocage passe avant tout le reste**, et il est symétrique : ni le
  -- bloqueur ni le bloqué ne peuvent relancer la porte que le blocage a fermée.
  if private.is_blocked(me, peer) then
    raise exception 'Demande impossible';
  end if;

  if are_connected(me, peer) then
    raise exception 'Vous êtes déjà connectés';
  end if;

  -- ⚠️ **LA BARRIÈRE FONDATRICE.** Elle était tenue par la portée de la radio ;
  -- elle est maintenant une condition écrite, vérifiable et testable.
  --
  -- ⚠️ **Et depuis le 2026-08-31, elle est aussi le SEUL chemin.** Le droit
  -- d'écrire directement dans `connection_requests` a été retiré au client :
  -- avant cette date, cette condition pouvait être contournée par une simple
  -- requête sur la table.
  --
  -- ⚠️ **Fenêtre volontairement plus large que celle du canal** : ajouter
  -- quelqu'un est un geste délibéré, qu'on pose souvent APRÈS s'être quittés —
  -- dans le bus, en rangeant son téléphone. Fermer un canal de discussion et
  -- refuser une rencontre ne sont pas la même décision.
  if not exists (
    select 1 from public.ping_pairs pp
    where ((pp.user_low = me and pp.user_high = peer)
        or (pp.user_low = peer and pp.user_high = me))
      and pp.last_seen_at > now() - private.fenetre_rencontre()
  ) then
    raise exception 'Proximité non constatée';
  end if;

  select id into req_id
  from public.connection_requests
  where sender_id = me and receiver_id = peer and status = 'pending'
    and expires_at > now()
  limit 1;
  if req_id is not null then
    return req_id;
  end if;

  insert into public.connection_requests (sender_id, receiver_id, status, expires_at)
  values (me, peer, 'pending', now() + interval '7 days')
  returning id into req_id;

  return req_id;
end;
$$;

-- ⚠️ **Accepter aussi.** Une demande peut avoir été posée avant un blocage :
-- sans ce test, l'accepter reformerait l'amitié que le blocage venait de
-- rompre — et `block_user` ne repasse pas derrière.
create or replace function public.accept_connection_request(req_id uuid)
returns uuid
language plpgsql
security definer
set search_path to 'public', 'private'
as $$
declare
  r record;
  conn_id uuid;
begin
  select * into r from connection_requests where id = req_id for update;
  if not found then
    raise exception 'Demande introuvable';
  end if;
  if r.receiver_id <> auth.uid() then
    raise exception 'Seul le destinataire peut accepter';
  end if;
  if r.status <> 'pending' or r.expires_at < now() then
    raise exception 'Demande expirée';
  end if;
  if private.is_blocked(r.sender_id, r.receiver_id) then
    raise exception 'Demande impossible';
  end if;

  update connection_requests set status = 'accepted' where id = req_id;

  insert into connections (user_low, user_high, status, origin, established_at)
  values (least(r.sender_id, r.receiver_id), greatest(r.sender_id, r.receiver_id),
          'full', 'proximity', now())
  on conflict (user_low, user_high) do update
    set status = 'full', established_at = coalesce(connections.established_at, now())
  returning id into conn_id;

  return conn_id;
end;
$$;


-- ════════════════════════════════════════════════════════════════════════
-- 3. M4 — DANS UN GROUPE, N'IMPORTE QUI POUVAIT EXPULSER N'IMPORTE QUI
-- ════════════════════════════════════════════════════════════════════════
--
-- L'ancienne politique disait : « soit je me retire moi-même, **soit je suis
-- membre de cette conversation** ». La seconde branche suffisait : tout membre
-- pouvait retirer tout autre membre, créateur compris, et vider un groupe.
--
-- Décision de Jay, 2026-08-31 : chacun peut partir ; seul le créateur exclut.
--
-- ⚠️ **La branche du créateur est restreinte aux GROUPES**, et ce n'est pas une
-- précaution : dans une conversation directe ou de proximité, `created_by` est
-- simplement celui qui l'a ouverte. Sans ce filtre, ouvrir une conversation
-- donnerait le droit d'en éjecter l'autre.

drop policy if exists "members_delete_by_member" on public.conversation_members;

create policy "members_delete_self_or_group_creator"
  on public.conversation_members for delete
  using (
    user_id = (select auth.uid())
    or exists (
      select 1 from public.conversations c
      where c.id = conversation_members.conversation_id
        and c.conversation_type = 'group'
        and c.created_by = (select auth.uid())
    )
  );


-- ════════════════════════════════════════════════════════════════════════
-- 4. M5 — LE BLOCAGE S'ÉNONÇAIT À DEUX ENDROITS, ET PAS DE LA MÊME FAÇON
-- ════════════════════════════════════════════════════════════════════════
--
-- Il y a deux portes vers un contenu du socle :
--
--   • la CLÉ         → `open_content_media` → `private.content_audience`
--   • les OCTETS     → politique du coffre → `can_view_*_file` → `*_audience`
--
-- `content_audience` commençait par un test de blocage. Les fonctions
-- d'audience, elles, ne le faisaient que sur la branche des relais. Les deux
-- portes appliquaient donc deux règles — et c'est celle qui en demande le moins
-- qui décide, toujours, en silence (règle 3 de `CLAUDE.md` : compter les
-- chemins).
--
-- ⚠️ **La règle DESCEND, elle ne se duplique pas.** Le test part de
-- `content_audience` et va dans les deux fonctions d'audience : elles sont le
-- point commun des trois chemins (sécurité de `contents`, sécurité du coffre,
-- remise de la clé). Recopier le test en haut ET en bas aurait fait deux
-- endroits à corriger le jour où la règle change.

create or replace function private.story_audience(p_story_id uuid, p_uid uuid)
returns boolean
language sql
stable
security definer
set search_path to 'public', 'private'
as $$
  select exists (
    select 1 from stories s
    where s.id = p_story_id
      and s.expires_at > now()
      and not private.is_revoked(s.id)
      and (
        s.owner_id = p_uid
        or (
          -- ⚠️ **Le blocage passe avant TOUT le reste** — descendu de
          -- `content_audience` le 2026-08-31. Il vivait sur le seul chemin de
          -- la clé ; le chemin des octets ne le posait pas.
          not private.is_blocked(s.owner_id, p_uid)
          -- Le palier, en amont de toutes les portes.
          and (s.min_tier = 'friend'
            or private.friendship_tier(s.owner_id, p_uid) >= s.min_tier)
          and (
            can_view_stories(s.owner_id, p_uid)
            or exists (
              select 1 from content_grants g
              where g.content_id = s.id
                and g.grantee_id = p_uid
                -- Un relais reçu de quelqu'un que j'ai bloqué depuis ne vaut plus.
                and not private.is_blocked(g.granted_by, p_uid)
            )
          )
        )
      )
  );
$$;

create or replace function private.publication_audience(p_item_id uuid, p_uid uuid)
returns boolean
language sql
stable
security definer
set search_path to 'public', 'private'
as $$
  select exists (
    select 1 from library_items li
    where li.id = p_item_id
      and not private.is_revoked(li.id)
      and (
        li.owner_id = p_uid
        or (
          -- ⚠️ Même descente que pour les stories, même raison.
          not private.is_blocked(li.owner_id, p_uid)
          and (
            can_view_library(li.owner_id, p_uid)
            or (li.is_public and can_view_profile(p_uid, li.owner_id))
            or exists (
              select 1 from content_grants g
              where g.content_id = li.id
                and g.grantee_id = p_uid
                and not private.is_blocked(g.granted_by, p_uid)
            )
          )
        )
      )
  );
$$;

-- `content_audience` redevient un pur aiguilleur : il ne décide plus de rien
-- qui ne soit pas « quel format, donc quelle audience ».
create or replace function private.content_audience(p_content_id uuid, p_uid uuid)
returns boolean
language plpgsql
stable
security definer
set search_path to 'public', 'private'
as $$
declare
  v_context public.content_context;
begin
  select context into v_context from contents where id = p_content_id;
  if not found then
    return false;
  end if;

  -- ⚠️ **Le test de blocage a été RETIRÉ d'ici le 2026-08-31**, et ce n'est pas
  -- un relâchement : il est descendu dans `story_audience` et
  -- `publication_audience`, où il s'applique désormais aux TROIS chemins et non
  -- au seul chemin de la clé. Le remettre ici en ferait un second juge, dont
  -- l'un des deux finirait par diverger.
  return case v_context
    when 'story' then private.story_audience(p_content_id, p_uid)
    when 'publication' then private.publication_audience(p_content_id, p_uid)
    else false
  end;
end;
$$;

-- ⚠️ **Et l'accès NOMINATIF à une bibliothèque apprend le blocage.**
-- `can_view_stories` le testait déjà ; `can_view_library`, non. Une personne
-- bloquée à qui j'avais donné un accès nommé restait donc dans ma bibliothèque.
create or replace function private.can_view_library(owner uuid, viewer uuid)
returns boolean
language sql
stable
security definer
set search_path to 'public', 'private'
as $$
  select owner = viewer
    or (
      not private.is_blocked(owner, viewer)
      and exists (
        select 1 from profiles p
        where p.id = owner
          and (
            (p.library_visibility = 'connections' and are_connected(owner, viewer))
            or (p.library_visibility = 'restricted' and exists (
              select 1 from library_access la
              where la.owner_id = owner and la.grantee_id = viewer
            ))
          )
      )
    );
$$;

-- ⚠️ **Bloquer retire aussi l'accès nominatif** — décision de Jay, 2026-08-31.
--
-- Le test ci-dessus suffit à fermer la porte tant que le blocage tient. Effacer
-- la ligne va plus loin, et c'est délibéré : un accès nommé est un geste de
-- confiance, pas un réglage. Le blocage le révoque.
--
-- ⚠️ **Conséquence assumée, dite ici pour qu'on ne la découvre pas plus tard :
-- débloquer ne le rend pas.** C'est la même règle que pour l'amitié, qui part
-- avec le blocage et ne revient pas non plus.
create or replace function public.block_user(p_user_id uuid)
returns void
language plpgsql
security definer
set search_path to 'public', 'private'
as $$
declare
  me uuid := auth.uid();
begin
  if me is null then
    raise exception 'Non authentifié';
  end if;
  if p_user_id is null or p_user_id = me then
    raise exception 'Destinataire invalide';
  end if;

  insert into public.blocks (blocker_id, blocked_id)
  values (me, p_user_id)
  on conflict do nothing;

  -- ⚠️ **L'amitié part avec.** Le déclencheur sur `connections` emporte à son
  -- tour le croisement et les constats : sans ça, deux personnes qui se sont
  -- bloquées continueraient d'accumuler des streaks.
  delete from public.connections c
  where c.user_low = least(me, p_user_id)
    and c.user_high = greatest(me, p_user_id);

  -- ⚠️ **Les demandes en cours aussi**, dans les deux sens. Laisser une demande
  -- en attente entre deux personnes qui se sont bloquées, c'est garder une porte
  -- que le blocage venait de fermer.
  --
  -- ⚠️ Depuis le 2026-08-31, `request_connection_from_proximity` et
  -- `accept_connection_request` refusent aussi tant que le blocage tient, et le
  -- client n'a plus le droit d'écrire dans la table. Cet effacement ne dépend
  -- donc plus d'être le seul chemin — il l'est.
  delete from public.connection_requests r
  where (r.sender_id = me and r.receiver_id = p_user_id)
     or (r.sender_id = p_user_id and r.receiver_id = me);

  -- 🔴 **L'ACCÈS NOMINATIF À LA BIBLIOTHÈQUE — ajouté le 2026-08-31.**
  --
  -- Il survivait au blocage, dans les deux sens, et `can_view_library` ne
  -- consultait pas `blocks` : une personne bloquée continuait de lister mes
  -- publications et d'en télécharger les octets.
  delete from public.library_access la
  where (la.owner_id = me and la.grantee_id = p_user_id)
     or (la.owner_id = p_user_id and la.grantee_id = me);

  -- 🔴 **LE TICKET DE PROXIMITÉ.** C'est lui qui ouvre le chat de proximité et
  -- la demande d'ami entre inconnus.
  delete from public.ping_pairs pp
  where pp.user_low = least(me, p_user_id)
    and pp.user_high = greatest(me, p_user_id);

  -- ⚠️ **Et les confirmations qui n'ont pas encore trouvé leur miroir.**
  -- Une paire naît quand deux confirmations se font face à un créneau près —
  -- jusqu'à 45 minutes de tolérance. Après un déblocage, une confirmation
  -- d'AVANT le blocage rencontrerait la première d'après, et fabriquerait un
  -- ticket à partir d'une proximité que le blocage venait de répudier.
  delete from public.ping_confirmations pc
  where (pc.observer_id = me and pc.subject_id = p_user_id)
     or (pc.observer_id = p_user_id and pc.subject_id = me);
end;
$$;


-- ════════════════════════════════════════════════════════════════════════
-- 5. H4 — UNE VIBE SANS CLÉ CONSOMMAIT QUAND MÊME UNE VUE
-- ════════════════════════════════════════════════════════════════════════
--
-- `open_card_media` incrémentait `view_count` **avant** d'aller chercher la
-- clé, et ne vérifiait jamais qu'elle existe. Sans ligne dans
-- `card_media_keys`, la fonction rendait `NULL` : la vue était consommée, la
-- transaction validée, et le Dart échouait sur `key as String`.
--
-- Le cas est atteignable : `CardsRepository.create` insère la Vibe avec
-- `encrypted = true` puis dépose la clé **ensuite** (elle référence la Vibe,
-- elle ne peut pas partir avant). Une coupure entre les deux laisse une Vibe
-- déclarée chiffrée et sans clé, et deux ouvertures brûlent les deux vues.
--
-- ⚠️ **On lit d'abord, on décompte ensuite.** Un décompte n'est légitime que
-- s'il paie quelque chose ; sinon ce n'est pas un budget, c'est une perte.

create or replace function public.open_card_media(p_card_id uuid)
returns text
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  v_me uuid := auth.uid();
  v_card cards%rowtype;
  v_delivery card_deliveries%rowtype;
  v_effective_max integer;
  v_key text;
begin
  select * into v_card from cards where id = p_card_id;
  if not found then
    raise exception 'Vibe introuvable';
  end if;

  -- ⚠️ **La clé est lue AVANT toute écriture.** C'est le correctif du
  -- 2026-08-31 : l'ordre inverse faisait payer une vue pour rien.
  select media_key into v_key from card_media_keys where card_id = p_card_id;
  if v_key is null then
    raise exception 'Vibe indisponible : sa clé n''a jamais été déposée';
  end if;

  -- Le propriétaire : toujours, sans décompte. C'est son contenu.
  if v_card.owner_id = v_me then
    return v_key;
  end if;

  -- Destinataire en conversation : la limite s'applique, et le décompte est
  -- INDISSOCIABLE de la remise de la clé.
  select * into v_delivery from card_deliveries
  where card_id = p_card_id and recipient_id = v_me
  for update;

  if not found then
    raise exception 'Vibe introuvable';
  end if;

  if v_delivery.destroyed_at is not null then
    raise exception 'Vibe détruite';
  end if;

  v_effective_max := coalesce(v_card.max_views, 2147483647)
    + case when v_delivery.replay_granted_at is not null then 1 else 0 end;

  if v_delivery.view_count >= v_effective_max then
    raise exception 'Plus de visionnages disponibles';
  end if;

  update card_deliveries
  set view_count = view_count + 1,
      first_viewed_at = coalesce(first_viewed_at, now())
  where id = v_delivery.id;

  return v_key;
end;
$$;

-- Même trou, sans décompte : rendre `NULL` faisait échouer le Dart sur un cast,
-- très loin de la cause.
create or replace function public.open_content_media(p_content_id uuid)
returns text
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  v_me uuid := auth.uid();
  v_key text;
begin
  if not exists (select 1 from contents where id = p_content_id)
     or not private.content_audience(p_content_id, v_me) then
    raise exception 'Contenu introuvable';
  end if;

  select media_key into v_key from content_media_keys where content_id = p_content_id;
  if v_key is null then
    raise exception 'Contenu indisponible : sa clé n''a jamais été déposée';
  end if;

  -- La vue n'est PAS enregistrée ici : obtenir la clé n'est pas regarder.
  -- Voir `public.record_content_view`, appelée après un temps d'affichage réel.
  return v_key;
end;
$$;

create or replace function public.get_library_vibe_key(p_vibe_id uuid)
returns text
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  v_vibe public.library_vibes;
  v_key text;
begin
  select * into v_vibe from library_vibes where id = p_vibe_id;
  if not found then
    raise exception 'Vibe introuvable';
  end if;

  if not exists (
    select 1 from conversation_members
    where conversation_id = v_vibe.conversation_id and user_id = auth.uid()
  ) then
    raise exception 'Vibe introuvable';
  end if;

  if now() < v_vibe.reveal_at then
    raise exception 'Le reveal n''a pas encore eu lieu';
  end if;

  select media_key into v_key from library_vibe_keys where vibe_id = p_vibe_id;
  if v_key is null then
    raise exception 'Vibe indisponible : sa clé n''a jamais été déposée';
  end if;
  return v_key;
end;
$$;


-- ════════════════════════════════════════════════════════════════════════
-- 6. H3 — LES OCTETS D'UN CONTENU SUPPRIMÉ RESTAIENT SUR LE SERVEUR
-- ════════════════════════════════════════════════════════════════════════
--
-- Le défaut, mesuré le 2026-08-31 : **88 objets orphelins sur 89** dans le
-- coffre `stories` (36,6 Mo), 8 sur 74 dans `library`. La tâche de purge
-- supprime les LIGNES ; aucune tâche ne supprime les FICHIERS.
--
-- ## ⚠️ Pourquoi ce n'est pas une simple ligne de SQL
--
-- Un `delete from storage.objects` est refusé par un déclencheur de Supabase
-- (`storage.protect_delete`). Vérifié le 2026-08-31 en lisant sa définition :
-- ce n'est pas une interdiction absolue — il suffirait de poser
-- `storage.allow_delete_query` — mais **le contourner ne supprimerait que la
-- ligne, pas le fichier**. Le blob resterait dans le coffre, hors de tout
-- inventaire : on remplacerait un orphelin visible par un orphelin invisible.
--
-- ⚠️ Le commentaire de `purge_expired_library_vibes` disait « interdit par
-- Supabase ». C'était directionnellement juste et imprécis sur la raison — et
-- c'est la raison qui décide de la solution.
--
-- La seule voie qui supprime vraiment est l'**API Storage**, donc un client
-- authentifié. Le seul que nous ayons est l'app. D'où le mécanisme ci-dessous :
-- le serveur **inscrit ce qui est à supprimer**, le propriétaire **le
-- supprime** au démarrage suivant, avec le droit qu'il a déjà sur ses propres
-- fichiers (`*_delete_own`).
--
-- ⚠️ **Limite assumée, écrite ici pour qu'elle ne se redécouvre pas :** si le
-- propriétaire ne rouvre jamais l'app, ses octets restent. C'est la même limite
-- coopérative que la purge des Enregistrements. La lever demande une tâche
-- serveur capable d'appeler l'API Storage — donc `pg_net` ou une fonction
-- déportée, aucune des deux n'existant aujourd'hui.
--
-- Délai retenu : **7 jours** après la disparition de la ligne (décision de Jay,
-- 2026-08-31). La ligne partie, plus personne ne peut voir le contenu ; la
-- semaine laisse une fenêtre si un signalement de modération arrive après coup.

create table if not exists public.storage_tombstones (
  bucket_id text not null,
  object_name text not null,
  owner_id uuid not null,
  delete_after timestamptz not null,
  primary key (bucket_id, object_name)
);

alter table public.storage_tombstones enable row level security;
-- ⚠️ **Aucune politique, et c'est la règle énoncée positivement** : cette table
-- ne se lit et ne s'écrit que par les fonctions ci-dessous. Un client qui
-- pourrait la lire saurait quels fichiers vont disparaître et quand ; un client
-- qui pourrait l'écrire pourrait faire supprimer les fichiers d'autrui.

create index if not exists storage_tombstones_du
  on public.storage_tombstones (owner_id, delete_after);

-- ⚠️ **Un seul déclencheur pour les trois tables**, paramétré par le coffre.
-- Trois copies auraient été trois occasions de corriger l'une et pas les
-- autres — c'est exactement le motif « X nettoyé, Y oublié » que ce chantier
-- ferme.
create or replace function private.inscrit_les_octets_a_supprimer()
returns trigger
language plpgsql
security definer
set search_path to 'public', 'private'
as $$
begin
  insert into public.storage_tombstones (bucket_id, object_name, owner_id, delete_after)
  select tg_argv[0], chemin, old.owner_id, now() + interval '7 days'
  from unnest(array[old.front_path, old.back_path]) as chemin
  where chemin is not null
  on conflict (bucket_id, object_name) do nothing;
  return old;
end;
$$;

drop trigger if exists stories_octets_a_supprimer on public.stories;
create trigger stories_octets_a_supprimer
  before delete on public.stories
  for each row execute function private.inscrit_les_octets_a_supprimer('stories');

drop trigger if exists library_items_octets_a_supprimer on public.library_items;
create trigger library_items_octets_a_supprimer
  before delete on public.library_items
  for each row execute function private.inscrit_les_octets_a_supprimer('library');

drop trigger if exists cards_octets_a_supprimer on public.cards;
create trigger cards_octets_a_supprimer
  before delete on public.cards
  for each row execute function private.inscrit_les_octets_a_supprimer('cards');

-- Les bibliothèques éphémères portent quatre chemins sous d'autres noms : elles
-- ont donc leur déclencheur, mais **la même table et la même échéance**. Deux
-- listes de choses à supprimer auraient été deux purges à tenir d'accord.
create or replace function private.inscrit_les_octets_de_vibe()
returns trigger
language plpgsql
security definer
set search_path to 'public', 'private'
as $$
begin
  insert into public.storage_tombstones (bucket_id, object_name, owner_id, delete_after)
  select 'library_vault', chemin, old.author_id, now() + interval '7 days'
  from unnest(array[
    old.placeholder_path, old.placeholder_back_path,
    old.sealed_path, old.sealed_back_path
  ]) as chemin
  where chemin is not null
  on conflict (bucket_id, object_name) do nothing;
  return old;
end;
$$;

drop trigger if exists library_vibes_octets_a_supprimer on public.library_vibes;
create trigger library_vibes_octets_a_supprimer
  before delete on public.library_vibes
  for each row execute function private.inscrit_les_octets_de_vibe();

-- ── Ce que le client demande, et ce qu'il déclare avoir fait ────────────

-- « Lesquels de MES fichiers sont à supprimer, maintenant ? »
--
-- ⚠️ Rend **uniquement les siens**. Un client ne doit jamais apprendre qu'un
-- fichier d'autrui est sur le point de disparaître — et il n'aurait de toute
-- façon pas le droit de le supprimer (`*_delete_own`).
create or replace function public.mes_octets_a_supprimer()
returns table (bucket_id text, object_name text)
language sql
security definer
set search_path to 'public'
as $$
  select t.bucket_id, t.object_name
  from public.storage_tombstones t
  where t.owner_id = auth.uid()
    and t.delete_after <= now()
  order by t.delete_after
  limit 200;
$$;

revoke all on function public.mes_octets_a_supprimer() from public, anon;
grant execute on function public.mes_octets_a_supprimer() to authenticated;

-- « Ceux-là, c'est fait. »
--
-- ⚠️ **On raye seulement les siens.** Sans ce filtre, un client pourrait faire
-- oublier au serveur les fichiers d'autrui, qui ne seraient alors plus jamais
-- supprimés — une fuite silencieuse à travers une fonction de ménage.
create or replace function public.octets_supprimes(p_bucket text, p_names text[])
returns integer
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  v_n integer;
begin
  delete from public.storage_tombstones t
  where t.owner_id = auth.uid()
    and t.bucket_id = p_bucket
    and t.object_name = any(p_names);
  get diagnostics v_n = row_count;
  return v_n;
end;
$$;

revoke all on function public.octets_supprimes(text, text[]) from public, anon;
grant execute on function public.octets_supprimes(text, text[]) to authenticated;


-- ════════════════════════════════════════════════════════════════════════
-- 7. NETTOYAGE DE CE QUE CES DÉFAUTS ONT LAISSÉ DERRIÈRE
-- ════════════════════════════════════════════════════════════════════════

-- ── a. La ligne `contents` orpheline ───────────────────────────────────
--
-- `StoriesRepository.remove()` supprimait la ligne `stories` et laissait la
-- ligne `contents` **et sa clé**. Le lien ne va que dans l'autre sens
-- (`stories.id → contents.id ON DELETE CASCADE`). Le Dart est corrigé dans le
-- même lot ; il reste à effacer ce que l'ancien chemin a laissé.
--
-- ⚠️ Ciblé par la forme du défaut, pas par un identifiant écrit en dur : une
-- ligne de contexte `story` sans ligne `stories` ne peut être QUE ça.
delete from public.contents c
where c.context = 'story'
  and not exists (select 1 from public.stories s where s.id = c.id);

-- ── b. Les fichiers orphelins, inscrits comme les autres ───────────────
--
-- Ils n'ont plus de ligne : le déclencheur ne les verra jamais. On les inscrit
-- donc à la main, une fois, avec la même échéance de sept jours — le
-- propriétaire les effacera au prochain démarrage de son app.
--
-- Le propriétaire se lit dans le chemin : la convention est `<uid>/<nom>` et
-- elle est imposée à l'écriture par `*_write_own`.
insert into public.storage_tombstones (bucket_id, object_name, owner_id, delete_after)
select o.bucket_id, o.name, ((storage.foldername(o.name))[1])::uuid, now() + interval '7 days'
from storage.objects o
where o.bucket_id = 'stories'
  and not exists (
    select 1 from public.stories s
    where s.front_path = o.name or s.back_path = o.name
  )
  and (storage.foldername(o.name))[1] ~ '^[0-9a-f-]{36}$'
on conflict (bucket_id, object_name) do nothing;

insert into public.storage_tombstones (bucket_id, object_name, owner_id, delete_after)
select o.bucket_id, o.name, ((storage.foldername(o.name))[1])::uuid, now() + interval '7 days'
from storage.objects o
where o.bucket_id = 'library'
  and not exists (
    select 1 from public.library_items li
    where li.front_path = o.name or li.back_path = o.name
  )
  and (storage.foldername(o.name))[1] ~ '^[0-9a-f-]{36}$'
on conflict (bucket_id, object_name) do nothing;
