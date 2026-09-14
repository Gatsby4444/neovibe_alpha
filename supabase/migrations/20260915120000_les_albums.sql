-- ===========================================================================
-- LES ALBUMS — une publication à plusieurs médias (Jay, 2026-09-15)
-- docs/plan-publications.md
-- ===========================================================================
--
-- Jay : « une publication peut contenir jusqu'à 11 contenus (photos et
-- vidéos) feuilletés à l'horizontale, légende, format comme Instagram […]
-- ça apparaît dans la grille des publications du profil ».
--
-- **Un contenu, un juge, plusieurs médias.** Vérifié en base avant d'écrire :
-- une publication Card et un album obéissent aux MÊMES règles — même audience
-- (`publication_audience`), permanents tous les deux, aucune limite de vues,
-- mêmes droits portés par `contents`. Ce qui diffère est le FORMAT (des faces
-- qu'on retourne / des médias qu'on feuillette). La règle 2 de `CLAUDE.md`
-- (deux objets aux règles différentes ne partagent pas la table) ne s'applique
-- donc pas : `library_items` reste l'en-tête unique, avec un `kind`.
--
-- **Les médias sortent dans une table enfant, pour les DEUX formats.** Une
-- Card y a ses faces aux places 0 et 1. Les quatre colonnes de faces
-- disparaissent : un chemin, une donnée. Sinon `can_view_publication_file`
-- aurait cherché un fichier à deux endroits (deux colonnes OU une table), et le
-- déclencheur des octets à supprimer aurait eu deux listes à tenir.
--
-- **Une clé par contenu, commune à tous ses médias** — exactement comme les
-- deux faces d'une Card aujourd'hui (`content_media_keys`). `library_media_keys`
-- et `open_content_media` ne changent pas.
-- ===========================================================================

-- ---------------------------------------------------------------------------
-- 1. L'en-tête : le format et le ratio
-- ---------------------------------------------------------------------------

create type public.library_kind as enum ('card', 'album');

alter table public.library_items
  add column kind public.library_kind not null default 'card',
  -- Le ratio d'un album, commun à tous ses médias (Instagram : 1:1, 4:5,
  -- 1.91:1). Nul pour une Card, dont le format est celui de la Card.
  add column aspect_w smallint,
  add column aspect_h smallint;

alter table public.library_items
  add constraint library_items_aspect_by_kind check (
    (kind = 'card' and aspect_w is null and aspect_h is null)
    or (kind = 'album' and (aspect_w, aspect_h) in ((1, 1), (4, 5), (191, 100)))
  );

comment on column public.library_items.kind is
  'card = une ou deux faces qu''on retourne ; album = 1 à 11 médias qu''on feuillette. Mêmes règles d''accès, même durée de vie : seul le format change (2026-09-15).';

-- ---------------------------------------------------------------------------
-- 2. Les médias
-- ---------------------------------------------------------------------------

create table public.library_media (
  item_id     uuid not null references public.library_items(id) on delete cascade,
  -- Le propriétaire, recopié de l'en-tête par la RPC. ⚠️ Il est ICI, et pas
  -- relu depuis `library_items`, parce que le déclencheur `before delete`
  -- d'un média tourne APRÈS la suppression de l'en-tête quand la cascade
  -- descend de `contents` — constaté au rejeu du 2026-09-15 : zéro pierre
  -- tombale. Même raison que `old.owner_id` dans l'ancien déclencheur.
  owner_id    uuid not null references public.profiles(id) on delete cascade,
  -- La place dans la publication : 0 = recto (ou couverture), 1 = verso…
  slot        smallint not null check (slot between 0 and 10),
  path        text not null,
  is_video    boolean not null default false,
  -- Vidéo : sa durée, ≤ 60 s (Jay : « vidéo de max 1 min par contenu »).
  duration_ms integer check (duration_ms is null or duration_ms between 1 and 60000),
  -- Vidéo d'album : son image de couverture, scellée avec la même clé.
  poster_path text,
  width       integer check (width is null or width > 0),
  height      integer check (height is null or height > 0),
  primary key (item_id, slot),
  unique (path),
  constraint library_media_video_fields check (
    is_video or (duration_ms is null and poster_path is null)
  )
);

-- `can_view_publication_file` cherche par chemin : les deux colonnes de
-- chemins sont indexées (le poster aussi est un fichier du coffre).
create index library_media_poster_path_idx
  on public.library_media (poster_path) where poster_path is not null;

comment on table public.library_media is
  'Les médias d''une publication, à leur place. Une Card : places 0 et 1. Un album : 1 à 11 places. Le fichier est scellé avec la clé unique du contenu (content_media_keys).';

-- Reprise des publications existantes : les faces deviennent les places 0 et 1.
insert into public.library_media (item_id, owner_id, slot, path, is_video)
select id, owner_id, 0, front_path, front_is_video from public.library_items;

insert into public.library_media (item_id, owner_id, slot, path, is_video)
select id, owner_id, 1, back_path, back_is_video
from public.library_items
where back_path is not null;

-- Les colonnes de faces ne servent plus à personne : relevé des lecteurs le
-- 2026-09-15 — `publish_to_library`, `can_view_publication_file`, le
-- déclencheur `library_items_octets_a_supprimer` (tous réécrits ci-dessous),
-- et côté Dart `LibraryItem.fromJson` (réécrit sur la jointure).
drop trigger library_items_octets_a_supprimer on public.library_items;
alter table public.library_items
  drop constraint library_items_back_face_consistent,
  drop column front_path,
  drop column back_path,
  drop column front_is_video,
  drop column back_is_video;

-- ---------------------------------------------------------------------------
-- 3. La sécurité des médias : le même juge que l'en-tête
-- ---------------------------------------------------------------------------

alter table public.library_media enable row level security;

-- Lecture : exactement l'audience de la publication — pas un second juge.
create policy library_media_select_audience
  on public.library_media for select
  using (private.publication_audience(item_id, (select auth.uid())));

-- Écriture : par la RPC seulement (security definer). Le propriétaire n'a pas
-- de chemin d'écriture direct — une ligne de média hors de sa publication
-- n'aurait aucun sens, et la RPC est le seul endroit qui contrôle le compte,
-- la durée et les chemins.
revoke insert, update, delete on public.library_media from anon, authenticated;

-- ---------------------------------------------------------------------------
-- 4. Le fichier d'un média : lisible si sa publication l'est
-- ---------------------------------------------------------------------------

create or replace function private.can_view_publication_file(file_path text, uid uuid)
returns boolean
language sql
stable
security definer
set search_path = public, private
as $$
  select exists (
    select 1 from library_media m
    where (m.path = file_path or m.poster_path = file_path)
      and private.publication_audience(m.item_id, uid)
  );
$$;

-- ---------------------------------------------------------------------------
-- 5. Les octets à supprimer : une ligne de média = un ou deux fichiers
-- ---------------------------------------------------------------------------
--
-- `private.inscrit_les_octets_a_supprimer` lit `old.front_path` / `old.back_path`
-- et sert encore `stories`, `cards` et `library_vibes` : elle n'est pas touchée.
-- Celle-ci lit une ligne de média (chemin + poster). La suppression d'une
-- publication supprime ses médias en cascade, et la cascade déclenche bien
-- les `before delete` de chaque ligne enfant.

create or replace function private.inscrit_le_media_a_supprimer()
returns trigger
language plpgsql
security definer
set search_path = public, private
as $$
begin
  insert into public.storage_tombstones (bucket_id, object_name, owner_id, delete_after)
  select 'library', chemin, old.owner_id, now() + interval '7 days'
  from unnest(array[old.path, old.poster_path]) as chemin
  where chemin is not null
    -- ⚠️ N'inscrire QUE ce que le propriétaire pourra supprimer.
    and (storage.foldername(chemin))[1] = old.owner_id::text
  on conflict (bucket_id, object_name) do nothing;
  return old;
end;
$$;

create trigger library_media_octets_a_supprimer
  before delete on public.library_media
  for each row execute function private.inscrit_le_media_a_supprimer();

-- ---------------------------------------------------------------------------
-- 6. Publier : une RPC pour les deux formats
-- ---------------------------------------------------------------------------
--
-- `p_media` : la liste ORDONNÉE des médias, un objet par place —
--   {"path": "...", "is_video": false, "duration_ms": null,
--    "poster_path": null, "width": 1080, "height": 1350}
-- Une Card : 1 ou 2 entrées (recto, verso). Un album : 1 à 11.
--
-- Contrôles ici, et pas dans l'app : le compte, la durée d'une vidéo, les
-- chemins sous le dossier du propriétaire, le ratio. L'app peut se tromper ou
-- être modifiée ; le serveur, non.

drop function public.publish_to_library(uuid, card_type, text, text, boolean, boolean, text, boolean, boolean, text, boolean);

create or replace function public.publish_to_library(
  p_item_id uuid,
  p_kind public.library_kind,
  p_card_type public.card_type,
  p_media jsonb,
  p_caption text,
  p_is_public boolean,
  p_shareable boolean,
  p_saveable boolean,
  p_media_key text,
  p_aspect_w smallint default null,
  p_aspect_h smallint default null
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_me uuid := auth.uid();
  v_count integer;
  v_slot integer := 0;
  v_m jsonb;
  v_path text;
  v_poster text;
  v_is_video boolean;
  v_duration integer;
begin
  if v_me is null then
    raise exception 'Authentification requise';
  end if;
  if p_media is null or jsonb_typeof(p_media) <> 'array' then
    raise exception 'Médias manquants';
  end if;
  v_count := jsonb_array_length(p_media);
  if p_kind = 'card' and v_count not between 1 and 2 then
    raise exception 'Une Card a une ou deux faces';
  end if;
  if p_kind = 'album' and v_count not between 1 and 11 then
    raise exception 'Une publication contient de 1 à 11 médias';
  end if;

  insert into contents (id, owner_id, context, shareable, saveable)
  values (p_item_id, v_me, 'publication', coalesce(p_shareable, false),
          coalesce(p_saveable, false));

  insert into library_items (id, owner_id, kind, card_type, caption, is_public, aspect_w, aspect_h)
  values (
    p_item_id, v_me, p_kind, coalesce(p_card_type, 'standard'),
    nullif(p_caption, ''), coalesce(p_is_public, false),
    case when p_kind = 'album' then p_aspect_w end,
    case when p_kind = 'album' then p_aspect_h end
  );

  for v_m in select * from jsonb_array_elements(p_media) loop
    v_path := v_m ->> 'path';
    v_poster := v_m ->> 'poster_path';
    v_is_video := coalesce((v_m ->> 'is_video')::boolean, false);
    v_duration := (v_m ->> 'duration_ms')::integer;
    if v_path is null or (storage.foldername(v_path))[1] <> v_me::text then
      raise exception 'Chemin de média hors du dossier du propriétaire';
    end if;
    if v_poster is not null and (storage.foldername(v_poster))[1] <> v_me::text then
      raise exception 'Chemin de couverture hors du dossier du propriétaire';
    end if;
    if v_is_video and v_duration is not null and v_duration > 60000 then
      raise exception 'Une vidéo dure au plus une minute';
    end if;
    insert into library_media (item_id, owner_id, slot, path, is_video, duration_ms, poster_path, width, height)
    values (
      p_item_id, v_me, v_slot, v_path, v_is_video,
      case when v_is_video then v_duration end,
      case when v_is_video then v_poster end,
      (v_m ->> 'width')::integer,
      (v_m ->> 'height')::integer
    );
    v_slot := v_slot + 1;
  end loop;

  insert into content_media_keys (content_id, media_key)
  values (p_item_id, p_media_key);

  return p_item_id;
end;
$$;

revoke all on function public.publish_to_library(uuid, public.library_kind, public.card_type, jsonb, text, boolean, boolean, boolean, text, smallint, smallint) from public, anon;
grant execute on function public.publish_to_library(uuid, public.library_kind, public.card_type, jsonb, text, boolean, boolean, boolean, text, smallint, smallint) to authenticated;
