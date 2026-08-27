-- Deux fenêtres, deux questions — et les dix minutes cessent d'être une règle.
--
-- Question de Jay du 2026-08-27 : *« pourquoi tu as choisi 10 min, je trouve
-- que c'est beaucoup, et à quoi correspond cette grâce ? »*
--
-- ## 🔎 D'où venaient ces dix minutes : de nulle part
--
-- Relevé dans les migrations, pas déduit. Elles apparaissent le **2026-08-25**,
-- une seule fois, dans `ping_nearby`, avec ce commentaire :
--
--     -- Bornée large : la vue affine. Au-delà, la ligne n'a plus de sens.
--
-- C'était donc une **borne grossière de liste**, écrite pour être **affinée en
-- aval** par le délai de grâce d'affichage. Jamais une autorisation.
--
-- Elle a ensuite été **recopiée trois fois**, sans être rediscutée :
--
--   1. `get_or_create_proximity_conversation` — ouvrir un canal ;
--   2. `request_connection_from_proximity` — demander en ami ;
--   3. `can_write_in_conversation` — écrire, le 2026-08-27, par moi, et je l'ai
--      **justifiée après coup** par « un seul nombre ».
--
-- Une borne d'affichage devenue règle de sécurité par copier-coller : c'est
-- exactement le « bricolé » que Jay a senti.
--
-- ## Ce qui les remplace : deux questions, qui ne sont pas la même
--
-- | Question | Fenêtre | Pourquoi cette valeur |
-- |---|---|---|
-- | **« Sommes-nous encore ensemble ? »** — ouvrir et écrire dans un canal | **3 min** | le téléphone dit « je l'entends encore » une fois par minute : trois minutes tolèrent **deux battements manqués** |
-- | **« L'ai-je rencontré récemment ? »** — demander en ami | **10 min** | geste délibéré, *après* la rencontre : on range son téléphone, on y repense dans le bus |
--
-- ⚠️ **Ouvrir et écrire prennent la MÊME fenêtre**, et c'est indispensable :
-- deux valeurs différentes permettraient de rouvrir un canal dans lequel on n'a
-- pas le droit d'écrire.
--
-- ⚠️ **Trois minutes n'est pas le délai que voit l'utilisateur.** L'écran sait
-- **en local**, en quelques secondes, que l'autre n'est plus là — il entend son
-- jeton, ou ne l'entend plus. Ces trois minutes sont le **filet du serveur**,
-- pour le cas où le client est muet, en retard ou malhonnête. L'écran est donc
-- toujours plus strict que la règle, jamais l'inverse.
--
-- ⚠️ **`ping_nearby` GARDE ses dix minutes**, et c'est le seul endroit où elles
-- avaient un sens : c'est une borne de liste, affinée en aval. Elle est
-- renommée pour dire ce qu'elle est.

-- ---------------------------------------------------------------------------
-- Les deux fenêtres, nommées
-- ---------------------------------------------------------------------------

/*
 * ⚠️ **Des fonctions, pas des constantes recopiées.** C'est ce qui a manqué :
 * un littéral `interval '10 minutes'` écrit à quatre endroits ne peut pas être
 * discuté, il ne peut qu'être copié une cinquième fois.
 */
create or replace function private.fenetre_canal()
returns interval language sql immutable as $$ select interval '3 minutes' $$;

comment on function private.fenetre_canal() is
  'Sommes-nous ENCORE ensemble ? Ouvrir et écrire dans un canal de proximité. '
  'Trois minutes = deux battements de cœur manqués (le client signale sa '
  'présence toutes les 60 s). Filet du serveur, pas délai vu par l''utilisateur '
  '— l''écran tranche en local en quelques secondes.';

create or replace function private.fenetre_rencontre()
returns interval language sql immutable as $$ select interval '10 minutes' $$;

comment on function private.fenetre_rencontre() is
  'L''ai-je RENCONTRÉ récemment ? Demander en ami. Plus généreuse que '
  'fenetre_canal parce que c''est un geste délibéré, posé APRÈS la rencontre.';

grant execute on function private.fenetre_canal() to authenticated;
grant execute on function private.fenetre_rencontre() to authenticated;

-- ---------------------------------------------------------------------------
-- Écrire : 10 min → 3 min
-- ---------------------------------------------------------------------------

create or replace function private.can_write_in_conversation(
  conv_id uuid,
  uid uuid
) returns boolean
language sql
stable
security definer
set search_path = public, private
as $$
  select case
    when c.conversation_type <> 'proximity' then true
    else exists (
      select 1
      from public.conversation_members autre
      join public.ping_pairs pp
        on (pp.user_low = least(uid, autre.user_id)
            and pp.user_high = greatest(uid, autre.user_id))
      where autre.conversation_id = c.id
        and autre.user_id <> uid
        and pp.last_seen_at > now() - private.fenetre_canal()
    )
  end
  from public.conversations c
  where c.id = conv_id;
$$;

grant execute on function private.can_write_in_conversation(uuid, uuid)
  to authenticated;

-- ---------------------------------------------------------------------------
-- Ouvrir un canal : la MÊME fenêtre qu'écrire
-- ---------------------------------------------------------------------------

create or replace function public.get_or_create_proximity_conversation(peer uuid)
returns uuid
language plpgsql
security definer
set search_path = public, private
as $$
declare
  me uuid := auth.uid();
  key text;
  conv_id uuid;
begin
  if are_connected(me, peer) then
    raise exception 'Déjà connectés : utilisez la messagerie directe';
  end if;

  -- ⚠️ **La même fenêtre qu'écrire, et c'est le point.** Sinon on pourrait
  -- rouvrir un canal dans lequel on n'a pas le droit d'écrire.
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

  select id into conv_id from conversations where pair_key = key;

  insert into conversation_members (conversation_id, user_id)
  values (conv_id, me), (conv_id, peer)
  on conflict do nothing;

  return conv_id;
end;
$$;

-- ---------------------------------------------------------------------------
-- Demander en ami : les dix minutes RESTENT, mais nommées
-- ---------------------------------------------------------------------------

create or replace function public.request_connection_from_proximity(peer uuid)
returns uuid
language plpgsql
security definer
set search_path = public, private
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

  if are_connected(me, peer) then
    raise exception 'Vous êtes déjà connectés';
  end if;

  -- ⚠️ **LA BARRIÈRE FONDATRICE.** Elle était tenue par la portée de la radio ;
  -- elle est maintenant une condition écrite, vérifiable et testable.
  --
  -- ⚠️ **Fenêtre volontairement plus large que celle du canal** : ajouter
  -- quelqu'un est un geste délibéré, qu'on pose souvent APRÈS s'être quitté —
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

-- ---------------------------------------------------------------------------
-- `ping_nearby` rend aussi le JETON — c'est ce qui rend l'écran autonome
-- ---------------------------------------------------------------------------

-- ⚠️ **Sans le jeton, l'écran ne peut pas se passer du serveur.** Le téléphone
-- entend « le jeton X », le serveur répond « tu es apparié à Bob » — mais rien
-- ne lui dit que Bob **est** le jeton X. Il devait donc redemander au serveur
-- toutes les dix secondes pour savoir si Bob était encore là, alors que sa
-- radio le lui criait déjà.
--
-- ⚠️ **Ça n'apprend rien de neuf à personne.** Pour figurer dans cette liste, il
-- faut déjà être apparié à la personne — donc l'avoir entendue, donc connaître
-- son jeton. On rend explicite ce que l'appelant possède déjà.
--
-- ⚠️ **Le jeton peut être nul** : la balise du pair expire à 5 minutes. L'écran
-- retombe alors sur `last_seen_at`, le temps que le pair republie.
drop function if exists public.ping_nearby();

create function public.ping_nearby()
returns table (
  user_id uuid,
  display_name text,
  tag_name text,
  avatar_url text,
  last_seen_at timestamptz,
  token text
)
language plpgsql
security definer
set search_path = public, private
as $$
declare
  me uuid := auth.uid();
begin
  if me is null then
    raise exception 'Non authentifié';
  end if;

  return query
  select p.id, p.display_name, p.tag_name, p.avatar_url, pp.last_seen_at, b.token
  from public.ping_pairs pp
  join public.profiles p
    on p.id = case when pp.user_low = me then pp.user_high else pp.user_low end
  left join public.ping_beacons b
    on b.user_id = p.id
   and b.updated_at > now() - private.ping_beacon_ttl()
  where (pp.user_low = me or pp.user_high = me)
    -- ⚠️ **Borne de LISTE, pas règle.** C'est son sens d'origine (2026-08-25) :
    -- « bornée large, la vue affine ». Les règles vivent dans
    -- `fenetre_canal()` et `fenetre_rencontre()`, qui portent leur question
    -- dans leur nom.
    and pp.last_seen_at > now() - private.fenetre_rencontre()
    and not are_connected(me, p.id)
  order by pp.last_seen_at desc;
end;
$$;

revoke all on function public.ping_nearby() from public;
grant execute on function public.ping_nearby() to authenticated;
