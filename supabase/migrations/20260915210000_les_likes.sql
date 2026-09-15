-- ===========================================================================
-- LES LIKES SUR LES PUBLICATIONS (Jay, 2026-09-15 : « oui ajoute les likes »)
-- ===========================================================================
--
-- Un like = une ligne (contenu, personne). Il porte sur un CONTENU du socle
-- (`contents`), pas sur un format : une Card publiée et un album se likent de
-- la même façon, et le jour où le feed arrive, le like y sera le même objet —
-- celui qui, dans la vision, révèle qui a ajouté au feed et ouvre le chat
-- (`docs/vision-produit.md` §6.5). Ce mécanisme-là n'est PAS écrit ici :
-- aujourd'hui un like est un like, compté et nominatif pour qui peut voir le
-- contenu.
--
-- **Un seul juge** : `private.content_audience` — on ne like que ce qu'on
-- peut voir, on ne voit que les likes des contenus qu'on peut voir.
-- ===========================================================================

create table public.content_likes (
  content_id uuid not null references public.contents(id) on delete cascade,
  user_id    uuid not null references public.profiles(id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (content_id, user_id)
);

create index content_likes_user_idx on public.content_likes (user_id);

comment on table public.content_likes is
  'Un like par personne et par contenu du socle (story, publication). Lecture et écriture jugées par content_audience (2026-09-15).';

alter table public.content_likes enable row level security;

create policy content_likes_select_audience
  on public.content_likes for select
  using (private.content_audience(content_id, (select auth.uid())));

create policy content_likes_insert_own
  on public.content_likes for insert
  with check (
    user_id = (select auth.uid())
    and private.content_audience(content_id, (select auth.uid()))
  );

create policy content_likes_delete_own
  on public.content_likes for delete
  using (user_id = (select auth.uid()));

revoke update on public.content_likes from anon, authenticated;

-- ---------------------------------------------------------------------------
-- Le résumé d'un lot : compte et « aimé par moi », pour une grille ou un fil
-- ---------------------------------------------------------------------------
-- `security invoker` : la RLS filtre les lignes, la fonction ne fait que
-- compter ce que l'appelant a le droit de voir.

create or replace function public.content_likes_summary(p_ids uuid[])
returns table (content_id uuid, likes integer, liked boolean)
language sql
stable
security invoker
set search_path = public
as $$
  select i.id,
         (select count(*)::integer from content_likes l where l.content_id = i.id),
         exists (select 1 from content_likes l where l.content_id = i.id and l.user_id = auth.uid())
  from unnest(p_ids) as i(id);
$$;

-- ---------------------------------------------------------------------------
-- Aimer / ne plus aimer : une transaction, le nouvel état en retour
-- ---------------------------------------------------------------------------

create or replace function public.toggle_like(p_content_id uuid)
returns table (likes integer, liked boolean)
language plpgsql
security invoker
set search_path = public
as $$
declare
  v_me uuid := auth.uid();
  v_liked boolean;
begin
  if v_me is null then
    raise exception 'Authentification requise';
  end if;
  delete from content_likes where content_id = p_content_id and user_id = v_me;
  if found then
    v_liked := false;
  else
    -- La politique d'insertion refuse un contenu hors de mon audience.
    insert into content_likes (content_id, user_id) values (p_content_id, v_me);
    v_liked := true;
  end if;
  return query
    select (select count(*)::integer from content_likes l where l.content_id = p_content_id),
           v_liked;
end;
$$;

-- ---------------------------------------------------------------------------
-- Qui a aimé : les profils, pour qui peut voir le contenu
-- ---------------------------------------------------------------------------

create or replace function public.content_likers(p_content_id uuid)
returns table (id uuid, display_name text, avatar_url text, liked_at timestamptz)
language sql
stable
security definer
set search_path = public, private
as $$
  select p.id, p.display_name, p.avatar_url, l.created_at
  from content_likes l
  join profiles p on p.id = l.user_id
  where l.content_id = p_content_id
    and private.content_audience(p_content_id, auth.uid())
  order by l.created_at desc
  limit 200;
$$;

revoke all on function public.content_likes_summary(uuid[]) from public, anon;
grant execute on function public.content_likes_summary(uuid[]) to authenticated;
revoke all on function public.toggle_like(uuid) from public, anon;
grant execute on function public.toggle_like(uuid) to authenticated;
revoke all on function public.content_likers(uuid) from public, anon;
grant execute on function public.content_likers(uuid) to authenticated;
