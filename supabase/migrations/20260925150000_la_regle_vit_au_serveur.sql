-- =============================================================================
-- LA RÈGLE VIT AU SERVEUR — revue du 2026-09-25
-- =============================================================================
--
-- Jay : « Il faut des sécurités backend, pas juste dire que puisque ce n'est
-- pas affiché à l'utilisateur, c'est sécurisé. Revois tout avec ce principe. »
--
-- Déclencheur : le chat d'une soirée TERMINÉE acceptait encore des messages ;
-- seul l'écran masquait la saisie. Revue de toute la surface d'écriture
-- (41 politiques d'écriture, 61 fonctions appelables) : ce qui suit corrige
-- chaque écart trouvé. Chaque faille a été REPRODUITE en base sous identité
-- avant d'être corrigée (`scratchpad/failles_avant.sql`).
--
-- | Faille (constatée) | Correctif |
-- |---|---|
-- | message dans le chat d'une soirée terminée : ACCEPTÉ | `can_write_in_conversation` : un événement fermé n'accepte plus rien |
-- | les RPC `share_content`, `send_voice_message`… sautaient la règle d'écriture du chat (fonctions `security definer`) | la règle passe dans le déclencheur de `messages` : TOUT chemin la traverse |
-- | un compte suspendu écrivait encore en chat, envoyait des Vibes, likait, saluait | déclencheur « suspendu » sur les tables d'écriture des personnes |
-- | un compte suspendu levait SA PROPRE suspension (toutes les colonnes de `profiles` modifiables) : ACCEPTÉ | colonnes modifiables = celles que l'app modifie, et elles seules |
-- | `stories` / `contents` / `library_items` insérables en direct (story sans expiration, publication hors règles) | ces portes directes sont fermées : seules les fonctions `publish_*` écrivent |
-- | `waves` : le destinataire modifiable après coup (vers un inconnu) | plus de modification : l'app n'en fait jamais |
-- | `library_items` : `id`, `kind`, `card_type`… modifiables | plus de modification : l'app n'en fait jamais |
-- | une Vibe 1/1 sauvegardable, un Oneshot avec durée : seul l'écran l'empêchait | contraintes sur `cards` (0 ligne existante en défaut) |
-- | nommer le lieu d'une soirée terminée | refusé |
-- =============================================================================

-- ─── 1. Le chat d'un événement fermé est fermé ──────────────────────────────

create or replace function private.can_write_in_conversation(conv_id uuid, uid uuid)
returns boolean
language sql
stable
security definer
set search_path to 'public', 'private'
as $function$
  select case
    -- 2026-09-25 : le chat d'un événement vit AVEC l'événement. Terminé, le
    -- groupe se lit encore cinq jours ; on n'y écrit plus.
    when c.conversation_type = 'event' then not exists (
      select 1 from public.events e
      where e.conversation_id = c.id and e.closed_at is not null
    )
    when c.conversation_type = 'group' then true
    when exists (
      select 1 from public.conversation_members autre
      where autre.conversation_id = c.id
        and autre.user_id <> uid
        and private.is_blocked(uid, autre.user_id)
    ) then false
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
$function$;

-- ─── 2. La règle d'écriture du chat, pour TOUS les chemins ──────────────────
--
-- La politique `messages_insert_member` ne s'applique qu'aux insertions
-- directes. Les fonctions `security definer` (partage d'un contenu, vocal…)
-- la contournaient. Le déclencheur, lui, voit chaque ligne.

create or replace function public.enforce_message_rules()
returns trigger
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  ctype public.conversation_type;
  other_replied boolean;
  my_count integer;
begin
  -- 2026-09-25 : membre, compte actif, et conversation ouverte à l'écriture
  -- — quel que soit le chemin (insertion directe ou fonction du serveur).
  if not private.is_conversation_member(new.conversation_id, new.sender_id) then
    raise exception 'Conversation introuvable';
  end if;
  if exists (
    select 1 from public.profiles p
    where p.id = new.sender_id and p.suspended_at is not null
  ) then
    raise exception 'Ton compte est suspendu';
  end if;
  if not private.can_write_in_conversation(new.conversation_id, new.sender_id) then
    if exists (
      select 1 from public.events e
      where e.conversation_id = new.conversation_id and e.closed_at is not null
    ) then
      raise exception 'Cette soirée est terminée : son chat est fermé';
    end if;
    raise exception 'Tu ne peux plus écrire dans cette conversation';
  end if;

  select conversation_type into ctype from conversations where id = new.conversation_id;

  if ctype = 'proximity' then
    if new.kind <> 'text' then
      raise exception 'Le canal de proximité est limité au texte';
    end if;
    select exists (
      select 1 from messages
      where conversation_id = new.conversation_id and sender_id <> new.sender_id
    ) into other_replied;
    if not other_replied then
      select count(*) into my_count
      from messages
      where conversation_id = new.conversation_id and sender_id = new.sender_id;
      if my_count >= 3 then
        raise exception 'Limite de 3 messages sans réponse atteinte';
      end if;
    end if;
  end if;

  -- Une Card jointe doit appartenir à l'expéditeur
  if new.card_id is not null then
    if not exists (select 1 from cards where id = new.card_id and owner_id = new.sender_id) then
      raise exception 'Card invalide';
    end if;
  end if;

  return new;
end;
$function$;

-- ─── 3. Un compte suspendu n'écrit plus, par aucun chemin ───────────────────
--
-- `assert_not_suspended` gardait 7 portes (publier, story, Drop, soirées,
-- défi, feed) ; le chat, les Vibes envoyées, les likes, les saluts et les
-- demandes d'ami restaient ouverts (docs/administration.md §1). Un seul
-- déclencheur, paramétré par la colonne de l'auteur.

create function private.refuse_si_suspendu()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_auteur uuid := (to_jsonb(new) ->> tg_argv[0])::uuid;
begin
  if exists (
    select 1 from public.profiles p
    where p.id = v_auteur and p.suspended_at is not null
  ) then
    raise exception 'Ton compte est suspendu';
  end if;
  return new;
end;
$$;

create trigger cards_refuse_si_suspendu before insert on public.cards
  for each row execute function private.refuse_si_suspendu('owner_id');
create trigger content_likes_refuse_si_suspendu before insert on public.content_likes
  for each row execute function private.refuse_si_suspendu('user_id');
create trigger waves_refuse_si_suspendu before insert on public.waves
  for each row execute function private.refuse_si_suspendu('user_id');
create trigger recommendations_refuse_si_suspendu before insert on public.recommendations
  for each row execute function private.refuse_si_suspendu('requester_id');
create trigger connection_requests_refuse_si_suspendu before insert on public.connection_requests
  for each row execute function private.refuse_si_suspendu('sender_id');

-- ─── 4. Mon profil : les colonnes que l'app modifie, et elles seules ────────
--
-- `profiles_update_own` laissait tout modifier — `suspended_at` compris :
-- un compte suspendu se rétablissait d'une requête. Relevé dans le code :
-- l'app écrit ces colonnes-là, et aucune autre.

revoke insert, update on public.profiles from anon, authenticated;
grant insert (id, display_name, tag_name) on public.profiles to authenticated;
grant update (
  display_name, tag_name, bio, avatar_url,
  library_visibility, realtime_waves, stories_public,
  special_mention, special_mention_public, show_pseudo
) on public.profiles to authenticated;

-- ─── 5. Plus de portes directes à côté des fonctions qui portent la règle ──
--
-- L'app ne les emprunte jamais (relevé dans le code le 2026-09-25) : elle
-- publie par `publish_story` / `publish_to_library` (security definer, avec
-- leurs règles). Ouvertes, elles permettaient une story sans expiration ou
-- une publication hors règles. Seul `toggle_like` (security invoker) dépend
-- des politiques de sa table : `content_likes` garde les siennes.

drop policy stories_insert_own on public.stories;
drop policy contents_insert_own on public.contents;
drop policy library_insert_own on public.library_items;
drop policy library_update_own on public.library_items;
-- L'app crée des saluts, ne les modifie jamais : modifier permettait de
-- rediriger un salut vers un inconnu (le contrôle « amis » n'est fait qu'à
-- la création).
drop policy waves_update_own on public.waves;

-- ─── 6. Les règles des Vibes que seul l'écran tenait ────────────────────────

alter table public.cards add constraint cards_one_of_one_not_saveable
  check (not (card_type = 'one_of_one' and saveable));
-- Un Oneshot n'a jamais de durée de lecture (Jay, 2026-09-14).
alter table public.cards add constraint cards_oneshot_no_duration
  check (not (card_type = 'oneshot' and view_duration_seconds is not null));

-- ─── 7. Le lieu d'une soirée terminée ne se renomme plus ────────────────────

create or replace function public.set_event_place(p_event uuid, p_place_name text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_name text := nullif(btrim(coalesce(p_place_name, '')), '');
begin
  if v_name is not null and char_length(v_name) > 60 then
    raise exception 'Nom du lieu trop long (60 caractères au plus)';
  end if;
  update public.events set place_name = v_name
   where id = p_event and created_by = auth.uid() and closed_at is null;
  if not found then
    raise exception 'Seul le créateur nomme le lieu, et pendant l''événement';
  end if;
end;
$$;
