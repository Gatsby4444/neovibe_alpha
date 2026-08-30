-- ===========================================================================
-- LE STATUT « CROISÉ » — et une demande d'ami qui porte une Vibe
-- ===========================================================================
--
-- Demande de Jay, 2026-08-30 : *« on ne peut pas envoyer de DM à un inconnu
-- même croisé précédemment je pense, sauf si on ajoute ce statut, et cela
-- débloquerait des mécaniques et fonctionnalités à ajouter »*.
--
-- ## 🔎 Ce qui existait déjà, et qu'il ne fallait surtout pas réinventer
--
-- Le « statut croisé » **est déjà en base** : c'est une ligne de `ping_pairs`.
-- Elle ne naît que si les DEUX appareils se sont mutuellement confirmés
-- (`confirm_ping`, le miroir), et `purge_ping` la garde **24 heures**.
--
-- Il n'y a donc ni table à créer, ni rétention à inventer. Ce qui manquait,
-- c'est **un droit attaché à cette ligne**.
--
-- ⚠️ **Et la beauté de la chose : le droit expire exactement quand la preuve
-- est purgée.** Aucune date de péremption à maintenir en parallèle, aucun
-- ménage à écrire. La cause est supprimée, pas surveillée (`CLAUDE.md`).
--
-- ## Ce qu'on N'A PAS fait, et pourquoi
--
-- ❌ **On n'ouvre PAS de canal de discussion vers un inconnu croisé.** Le canal
-- de proximité vit sur la fenêtre de **3 minutes** (« sommes-nous encore
-- ensemble ? », migration `20260827170000`). L'élargir à 24 h transformerait
-- une preuve de coprésence en droit de parler à quelqu'un qu'on a quitté ce
-- matin — c'est-à-dire un canal de spam, et l'inverse exact de la thèse.
--
-- ✅ **On attache la Vibe à la DEMANDE D'AMI.** Le geste devient : *« je t'ai
-- croisé, voilà une Vibe, veux-tu qu'on se connecte ? »* C'est une demande
-- d'ami avec un visage dessus — sur la thèse, et sans nouvel inbox : l'écran
-- « Demandes & rencontres » existe déjà et sait afficher ces lignes.
--
-- ## ⚠️ TROISIÈME fenêtre, et pourquoi elle a le droit d'être plus large
--
-- | Question | Fenêtre | Ce qui la justifie |
-- |---|---|---|
-- | « sommes-nous encore ensemble ? » | **3 min** | ouvrir/écrire dans le canal |
-- | « l'ai-je rencontré récemment ? » | **10 min** | demande d'ami **nue** |
-- | « l'ai-je croisé aujourd'hui ? » | **24 h** | demande d'ami **avec une Vibe** |
--
-- **C'est le COÛT DU GESTE qui paie la largeur de la fenêtre.** Une demande
-- nue est gratuite : elle reste bornée à dix minutes. Une Vibe demande une
-- capture, un cadrage, un envoi — on ne la produit pas en série dans un métro.
--
-- ⚠️ **Les deux premières fenêtres ne bougent pas d'un millimètre.** Une seule
-- valeur pour trois questions, c'est exactement le « bricolé » que Jay avait
-- senti le 2026-08-27.
--
-- ## L'anti-spam ne demande aucun compteur
--
-- `connection_requests` déduplique déjà par `(sender, receiver, pending)` : on
-- ne peut pas envoyer deux demandes en attente à la même personne. Le plafond
-- existe donc **par construction**, il n'y a pas de quota à tenir ni à purger.
-- ===========================================================================

-- ---------------------------------------------------------------------------
-- 1. La troisième fenêtre, nommée
-- ---------------------------------------------------------------------------
create or replace function private.fenetre_croisement()
returns interval language sql immutable as $$ select interval '24 hours' $$;

comment on function private.fenetre_croisement() is
  'Combien de temps un croisement autorise une demande d''ami PORTEUSE d''une '
  'Vibe. Volontairement égale à la rétention de ping_pairs (purge_ping) : le '
  'droit expire exactement quand la preuve disparaît, sans ménage séparé.';

-- ---------------------------------------------------------------------------
-- 2. Une demande d'ami peut porter une Vibe
-- ---------------------------------------------------------------------------
-- ⚠️ `on delete set null` et NON `cascade` : une Vibe est éphémère (TTL 24 h),
-- une demande vit **sept jours**. La disparition de la Vibe ne doit pas
-- emporter la demande — elle la rend seulement muette, ce que l'écran sait
-- afficher. Deux cycles de vie, deux objets : c'est la règle 5 de `CLAUDE.md`.
alter table public.connection_requests
  add column if not exists card_id uuid references public.cards(id) on delete set null;

comment on column public.connection_requests.card_id is
  'La Vibe jointe à la demande, quand elle vient d''un croisement (24 h). '
  'NULL pour une demande nue (fenêtre de 10 min). Mise à NULL, jamais '
  'supprimée, quand la Vibe expire.';

-- ---------------------------------------------------------------------------
-- 3. Qui ai-je croisé aujourd'hui ?
-- ---------------------------------------------------------------------------
-- ⚠️ **Le serveur filtre, l'app n'a rien à écarter.** Rendre des gens que
-- l'app devrait ensuite masquer, c'est confier une règle au client — et c'est
-- exactement ce qui avait laissé le blocage entre les mains du client
-- jusqu'au 2026-08-28 (`RAPPELS.md` #93).
create or replace function public.crossed_recently()
returns table (
  user_id uuid,
  display_name text,
  tag_name text,
  avatar_url text,
  crossed_at timestamptz,
  already_requested boolean
)
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

  return query
  select p.id,
         p.display_name,
         p.tag_name,
         p.avatar_url,
         pp.last_seen_at,
         exists (
           select 1 from public.connection_requests r
           where r.sender_id = me and r.receiver_id = p.id
             and r.status = 'pending' and r.expires_at > now()
         )
  from public.ping_pairs pp
  join public.profiles p
    on p.id = case when pp.user_low = me then pp.user_high else pp.user_low end
  where (pp.user_low = me or pp.user_high = me)
    and pp.last_seen_at > now() - private.fenetre_croisement()
    -- Un ami n'est pas un croisé : il a sa propre section, avec son palier.
    and not are_connected(me, p.id)
    and not private.is_blocked(me, p.id)
  order by pp.last_seen_at desc;
end;
$$;

comment on function public.crossed_recently() is
  'Les gens croisés dans les dernières 24 h, hors amis et hors blocages. '
  'C''est la source de la section « Croisés récemment » de l''écran de partage.';

-- ---------------------------------------------------------------------------
-- 4. Envoyer une Vibe à quelqu'un qu'on a croisé
-- ---------------------------------------------------------------------------
create or replace function public.request_connection_with_vibe(
  peer uuid,
  p_card_id uuid
)
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

  -- ⚠️ **La Vibe doit m'appartenir.** Sans cette ligne, on pourrait joindre à
  -- une demande la Vibe de quelqu'un d'autre, dont on connaîtrait l'identifiant
  -- — et créer au passage une livraison que son auteur n'a jamais voulue.
  if not exists (
    select 1 from public.cards c where c.id = p_card_id and c.owner_id = me
  ) then
    raise exception 'Vibe introuvable';
  end if;

  if are_connected(me, peer) then
    raise exception 'Vous êtes déjà connectés';
  end if;

  -- 🔴 **LA BARRIÈRE FONDATRICE, sur la troisième fenêtre.** Voir l'en-tête :
  -- c'est le coût du geste qui paie la largeur. Une demande NUE reste sur
  -- `fenetre_rencontre()` (10 min) et n'est pas touchée par cette fonction.
  if not exists (
    select 1 from public.ping_pairs pp
    where ((pp.user_low = me and pp.user_high = peer)
        or (pp.user_low = peer and pp.user_high = me))
      and pp.last_seen_at > now() - private.fenetre_croisement()
  ) then
    raise exception 'Croisement non constaté';
  end if;

  if private.is_blocked(me, peer) then
    raise exception 'Envoi impossible';
  end if;

  -- ⚠️ **Une demande en attente en absorbe une seconde**, elle ne la double
  -- pas : c'est tout l'anti-spam, et il n'a demandé aucun compteur.
  select id into req_id
  from public.connection_requests
  where sender_id = me and receiver_id = peer and status = 'pending'
    and expires_at > now()
  limit 1;

  if req_id is not null then
    -- La demande existe déjà : on lui accroche la Vibe la plus récente plutôt
    -- que de refuser. Refuser laisserait l'utilisateur devant un mur sans
    -- issue, ce que `CLAUDE.md` appelle un bug.
    update public.connection_requests set card_id = p_card_id where id = req_id;
  else
    insert into public.connection_requests
      (sender_id, receiver_id, status, expires_at, card_id)
    values (me, peer, 'pending', now() + interval '7 days', p_card_id)
    returning id into req_id;
  end if;

  -- ⚠️ **La livraison, sans message et sans conversation.** `message_id` est
  -- nullable exprès : c'est ce qui permet à une Vibe d'exister hors d'un chat.
  -- C'est aussi ce qui ouvre la lecture du fichier au destinataire —
  -- `can_view_card_file` s'appuie sur la livraison, pas sur le message.
  insert into public.card_deliveries (card_id, recipient_id, message_id)
  values (p_card_id, peer, null)
  on conflict do nothing;

  return req_id;
end;
$$;

comment on function public.request_connection_with_vibe(uuid, uuid) is
  'Demande d''ami PORTEUSE d''une Vibe, ouverte 24 h après un croisement '
  'mutuel. La fenêtre est plus large que celle de la demande nue (10 min) '
  'parce que le geste coûte une capture : c''est le coût qui paie la largeur.';

-- ⚠️ **Exécutables par `authenticated`** : une fonction du schéma `public`
-- appelée depuis `/rest/v1/rpc/` doit l'être, et une fonction citée par une
-- politique aussi (`CLAUDE.md`, panne du 2026-08-11).
grant execute on function public.crossed_recently() to authenticated;
grant execute on function public.request_connection_with_vibe(uuid, uuid) to authenticated;

-- 🔴 **Et on RETIRE ce que PostgreSQL accorde tout seul.** Toute fonction
-- nouvellement créée reçoit `EXECUTE` pour `PUBLIC`, donc pour `anon`. Relevé
-- juste après l'application de cette migration. Les deux fonctions lèvent quand
-- `auth.uid()` est nul, mais une sécurité ne doit pas reposer sur ce qu'une
-- fonction fait à l'intérieur : elle s'énonce à la porte, positivement.
revoke execute on function public.crossed_recently() from public, anon;
revoke execute on function public.request_connection_with_vibe(uuid, uuid) from public, anon;
