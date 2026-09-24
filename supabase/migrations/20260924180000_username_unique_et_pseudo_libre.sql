-- =============================================================================
-- USERNAME UNIQUE, PSEUDO LIBRE — 2026-09-24
-- =============================================================================
--
-- Jay : « on doit composer à l'inscription un username unique, cependant on
-- peut aussi, et c'est optionnel, créer un pseudo ; le pseudo est affiché s'il
-- y en a un, sinon c'est l'username ; l'username est unique, pas le pseudo ; et
-- on peut paramétrer si l'on désire que dans les groupes et pour les autres ce
-- soit notre pseudo ou notre username qui soit affiché. Pour les publications,
-- c'est notre username. » Format choisi : comme Instagram ; longueurs : username
-- 3 à 20, pseudo 1 à 30.
--
-- Relevé en base avant d'écrire : les deux colonnes EXISTAIENT déjà —
-- `display_name` (unique, index `profiles_username_unique` sur son minuscule)
-- et `tag_name` (facultatif, 1 à 30). Ce qui manquait : le format du username,
-- le réglage, et son application par le serveur.
--
-- ## Le réglage s'applique à UN endroit
--
-- `pseudo_shown` est une colonne CALCULÉE par la base : le pseudo si son
-- propriétaire veut le montrer, sinon rien. Tout ce qui affiche un nom aux
-- autres la lit (les cinq fonctions ci-dessous, et l'app). `tag_name` reste la
-- valeur brute, pour l'écran d'édition du profil et l'administration.
-- =============================================================================

-- ─── 1. Les usernames existants, au nouveau format ─────────────────────────
-- « Camille Martin » → « camille.martin » ; accents retirés ; doublons
-- départagés par un chiffre. 48 comptes en base le 2026-09-24, dont 40
-- figurants.
do $$
declare
  r record;
  v_base text;
  v_try text;
  v_n integer;
begin
  for r in select id, display_name from public.profiles order by id loop
    v_base := lower(translate(
      r.display_name,
      'ÀÂÄÁÃÉÈÊËÎÏÍÔÖÓÕÙÛÜÚÇÑàâäáãéèêëîïíôöóõùûüúçñ',
      'AAAAAEEEEIIIOOOOUUUUCNaaaaaeeeeiiioooouuuucn'
    ));
    v_base := regexp_replace(v_base, '[[:space:]]+', '.', 'g');
    v_base := regexp_replace(v_base, '[^a-z0-9._]', '', 'g');
    v_base := regexp_replace(v_base, '[.]{2,}', '.', 'g');
    v_base := btrim(v_base, '.');
    if v_base = '' then v_base := 'neovibe'; end if;
    -- ⚠️ `rpad` COUPE une chaîne plus longue que la longueur demandée :
    -- `rpad('charles', 3)` rend « cha ». Appliqué ainsi le 2026-09-24, il a
    -- réduit tous les usernames à 3 lettres (réparé par la migration
    -- suivante). On ne complète donc QUE les noms trop courts.
    if length(v_base) < 3 then v_base := rpad(v_base, 3, '0'); end if;
    v_base := left(v_base, 20);
    v_try := v_base;
    v_n := 1;
    while exists (
      select 1 from public.profiles
      where lower(display_name) = v_try and id <> r.id
    ) loop
      v_n := v_n + 1;
      v_try := left(v_base, 20 - length(v_n::text)) || v_n::text;
    end loop;
    update public.profiles set display_name = v_try where id = r.id;
  end loop;
end $$;

-- ─── 2. Les règles ─────────────────────────────────────────────────────────
alter table public.profiles drop constraint profiles_display_name_check;
alter table public.profiles add constraint profiles_display_name_check
  check (display_name ~ '^[a-z0-9._]{3,20}$');
-- Le pseudo garde sa règle (profiles_tag_name_check : 1 à 30).

-- ─── 3. Le réglage, et le pseudo tel que les autres le voient ──────────────
alter table public.profiles
  add column show_pseudo boolean not null default true;
alter table public.profiles
  add column pseudo_shown text
  generated always as (case when show_pseudo then tag_name end) stored;

-- ─── 4. Les cinq fonctions qui donnent un nom aux autres ───────────────────
-- Même signature, même nom de colonne rendue (`tag_name`) : l'app n'a rien à
-- changer pour les lire. Seule la SOURCE change : `pseudo_shown`.
-- (`admin_users` garde le pseudo brut : la modération voit tout.)

CREATE OR REPLACE FUNCTION public.content_viewers(p_content_id uuid)
 RETURNS TABLE(viewer_id uuid, display_name text, tag_name text, avatar_url text, first_viewed_at timestamp with time zone)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  select v.viewer_id, p.display_name, p.pseudo_shown, p.avatar_url, v.first_viewed_at
  from content_views v
  join profiles p on p.id = v.viewer_id
  where v.content_id = p_content_id
    and exists (
      select 1 from contents c
      where c.id = p_content_id and c.owner_id = auth.uid()
    )
    and private.can_view_profile(auth.uid(), v.viewer_id)
  order by v.first_viewed_at desc;
$function$;

CREATE OR REPLACE FUNCTION public.crossed_recently()
 RETURNS TABLE(user_id uuid, display_name text, tag_name text, avatar_url text, crossed_at timestamp with time zone, already_requested boolean, origin text, event_title text)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'private'
AS $function$
declare
  me uuid := auth.uid();
begin
  if me is null then
    raise exception 'Non authentifié';
  end if;

  return query
  -- ⚠️ Les alias internes ne reprennent PAS les noms des colonnes de sortie
  -- (`origin`, `event_title`) : en PL/pgSQL, ce serait ambigu.
  with croisements as (
    select case when pp.user_low = me then pp.user_high else pp.user_low end as autre,
           pp.last_seen_at as quand, 'ping'::text as orig, null::text as titre
    from public.ping_pairs pp
    where (pp.user_low = me or pp.user_high = me)
      and pp.last_seen_at > now() - private.fenetre_croisement('ping')
    union all
    select case when c.user_low = me then c.user_high else c.user_low end,
           c.last_at, 'event', c.event_title
    from public.event_crossings c
    where (c.user_low = me or c.user_high = me)
      and c.last_at > now() - private.fenetre_croisement('event')
  ),
  dernier as (
    select distinct on (autre) autre, quand, orig, titre
    from croisements
    order by autre, quand desc
  )
  select p.id, p.display_name, p.pseudo_shown, p.avatar_url, d.quand,
         exists (
           select 1 from public.connection_requests r
           where r.sender_id = me and r.receiver_id = p.id
             and r.status = 'pending' and r.expires_at > now()
         ),
         d.orig, d.titre
  from dernier d
  join public.profiles p on p.id = d.autre
  where not private.are_connected(me, p.id)
    and not private.is_blocked(me, p.id)
  order by d.quand desc;
end;
$function$;

CREATE OR REPLACE FUNCTION public.event_people(p_event uuid)
 RETURNS TABLE(user_id uuid, display_name text, tag_name text, avatar_url text, role event_role, invited boolean, present boolean, relation text, joined_at timestamp with time zone)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'private'
AS $function$
declare
  me uuid := auth.uid();
begin
  if me is null then raise exception 'Non authentifié'; end if;
  if not private.concerned_by_event(p_event, me) then
    raise exception 'Événement introuvable';
  end if;
  return query
  with gens as (
    select m.user_id, m.role, true as invited, m.joined_at
    from public.event_group_members m where m.event_id = p_event
    union
    select p.user_id, null::public.event_role, false, p.joined_at
    from public.event_presences p
    where p.event_id = p_event and p.left_at is null
      and not exists (select 1 from public.event_group_members m
                      where m.event_id = p_event and m.user_id = p.user_id)
  )
  select g.user_id, pr.display_name, pr.pseudo_shown, pr.avatar_url,
         g.role, g.invited,
         private.is_present_in_event(p_event, g.user_id),
         case when g.user_id = me then 'me' else private.relation_kind(me, g.user_id) end,
         g.joined_at
  from gens g
  join public.profiles pr on pr.id = g.user_id
  where not private.is_blocked(me, g.user_id)
  order by private.is_present_in_event(p_event, g.user_id) desc, pr.display_name;
end;
$function$;

CREATE OR REPLACE FUNCTION public.my_meetings()
 RETURNS TABLE(id uuid, user_id uuid, display_name text, tag_name text, avatar_url text, origin text, event_id uuid, event_title text, lat double precision, lon double precision, met_at timestamp with time zone, last_at timestamp with time zone, connected boolean, times integer)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'private'
AS $function$
declare
  me uuid := auth.uid();
begin
  if me is null then raise exception 'Non authentifié'; end if;
  return query
  select m.id, m.other_id, p.display_name, p.pseudo_shown, p.avatar_url,
         m.origin, m.event_id, m.event_title, m.lat, m.lon,
         m.met_at, m.last_at,
         private.are_connected(me, m.other_id),
         (select count(*)::integer from public.meetings x where x.user_id = me and x.other_id = m.other_id)
  from public.meetings m
  join public.profiles p on p.id = m.other_id
  where m.user_id = me and not private.is_blocked(me, m.other_id)
  order by m.last_at desc;
end;
$function$;

CREATE OR REPLACE FUNCTION public.ping_nearby()
 RETURNS TABLE(user_id uuid, display_name text, tag_name text, avatar_url text, last_seen_at timestamp with time zone, token text, special_mention text)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'private'
AS $function$
declare
  me uuid := auth.uid();
begin
  if me is null then
    raise exception 'Non authentifie';
  end if;

  return query
  select p.id,
         p.display_name,
         p.pseudo_shown,
         p.avatar_url,
         pp.last_seen_at,
         b.token,
         -- ⚠️ **L'interrupteur s'applique ICI, à la source.** Rendre la mention
         -- puis laisser l'app décider de l'afficher serait la donner à qui sait
         -- lire une réponse réseau. Ce qui n'est pas autorisé n'est pas envoyé.
         case when p.special_mention_public then p.special_mention end
  from public.ping_pairs pp
  join public.profiles p
    on p.id = case when pp.user_low = me then pp.user_high else pp.user_low end
  left join public.ping_beacons b
    on b.user_id = p.id
   and b.updated_at > now() - private.ping_beacon_ttl()
  where (pp.user_low = me or pp.user_high = me)
    -- Borne de LISTE, pas règle : la vue affine (voir 20260827170000).
    and pp.last_seen_at > now() - private.fenetre_rencontre()
    and not are_connected(me, p.id)
    and not private.is_blocked(me, p.id)
  order by pp.last_seen_at desc;
end;
$function$;


notify pgrst, 'reload schema';
