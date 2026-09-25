-- =============================================================================
-- LA PRÉCISION POUR CRÉER UNE SOIRÉE, TENUE PAR LE SERVEUR — 2026-09-25
-- =============================================================================
--
-- Revue « la règle vit au serveur » (Jay) : créer une soirée exige une
-- position PRÉCISE (≤ 100 m, v0.9.261) — l'écran seul le vérifiait. Un lieu
-- approximatif (Android bride parfois à ~2 km) poserait la soirée ailleurs,
-- et `join_event` refuserait ensuite ceux qui y sont vraiment.
--
-- L'app DÉCLARE la précision de sa position (`p_acc`, l'estimation d'Android)
-- et le serveur refuse au-delà du seuil — une ligne de `event_rules`, pas une
-- constante. Même limite honnête que « caméra seulement » : ce qui est fermé,
-- ce sont tous les chemins de l'app ; une app modifiée qui mentirait sur sa
-- précision ne l'est pas (la position elle-même vient du téléphone).
--
-- Seules les portes publiques changent : les fonctions privées n'ont pas
-- d'autre appelant (relevé le 2026-09-25).
-- =============================================================================

alter table public.event_rules
  add column place_max_accuracy_m integer not null default 100;

drop function public.create_open_event(text, double precision, double precision, timestamptz, integer);
drop function public.create_private_event(text, timestamptz, timestamptz, double precision, double precision, uuid[]);

create function private.assert_precise_place(p_lat double precision, p_acc double precision)
returns void
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_max integer := (select place_max_accuracy_m from public.event_rules limit 1);
begin
  if p_lat is null then return; end if;
  if p_acc is null or p_acc > v_max then
    raise exception 'Position trop imprécise pour poser une soirée (± % m, % m au plus)',
      coalesce(round(p_acc)::text, '?'), v_max;
  end if;
end;
$$;
revoke all on function private.assert_precise_place(double precision, double precision) from public, anon, authenticated;

create function public.create_open_event(
  p_title text,
  p_lat double precision,
  p_lon double precision,
  p_ends_at timestamptz,
  p_radius_m integer default null,
  p_acc double precision default null
)
returns uuid
language plpgsql
security definer
set search_path to 'public', 'private'
as $$
begin
  perform private.assert_not_suspended();
  perform private.assert_precise_place(p_lat, p_acc);
  return private.unguarded_create_open_event(p_title, p_lat, p_lon, p_ends_at, p_radius_m);
end;
$$;

create function public.create_private_event(
  p_title text,
  p_starts_at timestamptz default now(),
  p_ends_at timestamptz default null,
  p_lat double precision default null,
  p_lon double precision default null,
  p_member_ids uuid[] default '{}',
  p_acc double precision default null
)
returns uuid
language plpgsql
security definer
set search_path to 'public', 'private'
as $$
begin
  perform private.assert_not_suspended();
  -- Sans lieu fixe (soirée « chez nous », voyage), rien à vérifier.
  perform private.assert_precise_place(p_lat, p_acc);
  return private.unguarded_create_private_event(p_title, p_starts_at, p_ends_at, p_lat, p_lon, p_member_ids);
end;
$$;

revoke all on function public.create_open_event(text, double precision, double precision, timestamptz, integer, double precision) from public, anon;
revoke all on function public.create_private_event(text, timestamptz, timestamptz, double precision, double precision, uuid[], double precision) from public, anon;
grant execute on function public.create_open_event(text, double precision, double precision, timestamptz, integer, double precision) to authenticated;
grant execute on function public.create_private_event(text, timestamptz, timestamptz, double precision, double precision, uuid[], double precision) to authenticated;
