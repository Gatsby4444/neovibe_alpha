-- =============================================================================
-- UN TÉLÉPHONE, UN PLAFOND DE COMPTES — 2026-09-24
-- =============================================================================
--
-- Jay : « ok [pour couper la confirmation du mail] mais on ajoute une sécurité
-- sur l'appareil en lui-même pour identifier l'appareil et l'empêcher de
-- spammer la création de comptes » ; plafond validé : 3 comptes par
-- téléphone sur 30 jours, les comptes de test à part.
--
-- ## Les trois objets, et pourquoi trois
--
-- | Objet | Ce qu'il est | Qui l'écrit |
-- |---|---|---|
-- | `private.signup_rules` | le plafond — UNE ligne, modifiable sans code | nous, à la main |
-- | `private.device_signups` | le registre : quel téléphone a créé quel compte, quand | le trigger sur `auth.users`, seul |
-- | `private.signup_device_exempt` | les téléphones hors plafond (ceux de Jay, pour tester) | nous, à la main |
--
-- ⚠️ **Le registre n'a PAS de clé étrangère vers `auth.users`, et c'est voulu.**
-- Supprimer un compte ne doit pas rendre sa place au téléphone : sinon « créer,
-- supprimer, recréer » contournerait le plafond. On compte des CRÉATIONS, pas
-- des comptes existants.
--
-- ⚠️ **Le registre n'est pas lu dans `raw_user_meta_data`.** Cette colonne est
-- modifiable par l'utilisateur lui-même (`auth.updateUser(data: …)`) : compter
-- là-dedans laisserait n'importe qui effacer sa trace. Le trigger recopie
-- l'empreinte au moment de la création, dans une table que personne d'autre
-- n'écrit.
--
-- ## Qui décide, et quand
--
-- `hook_before_user_created` est appelé par le service d'authentification
-- AVANT de créer l'utilisateur ; il refuse avec un message lisible. Les
-- figurants et bots de test, insérés directement en SQL, ne passent pas par
-- lui (et le trigger les ignore : ils n'ont pas d'empreinte).
--
-- ⚠️ Limite assumée : une app modifiée peut envoyer une fausse empreinte.
-- « Coûteux et visible, pas impossible ». Doc : docs/inscription-et-appareil.md
-- =============================================================================

create table private.signup_rules (
  id boolean primary key default true check (id),
  max_accounts integer not null default 3 check (max_accounts > 0),
  per_window interval not null default interval '30 days'
);
insert into private.signup_rules default values;

create table private.device_signups (
  user_id uuid primary key,
  device_hash text not null check (device_hash ~ '^[0-9a-f]{64}$'),
  created_at timestamptz not null default now()
);
create index device_signups_device_recent
  on private.device_signups (device_hash, created_at);

create table private.signup_device_exempt (
  device_hash text primary key check (device_hash ~ '^[0-9a-f]{64}$'),
  note text not null,
  added_at timestamptz not null default now()
);

alter table private.signup_rules enable row level security;
alter table private.device_signups enable row level security;
alter table private.signup_device_exempt enable row level security;

-- ─── La décision : avant la création ─────────────────────────────────────────

create or replace function public.hook_before_user_created(event jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_hash text := event -> 'user' -> 'user_metadata' ->> 'device_hash';
  v_rules private.signup_rules;
  v_count integer;
begin
  if v_hash is null or v_hash !~ '^[0-9a-f]{64}$' then
    return jsonb_build_object('error', jsonb_build_object(
      'http_code', 400,
      'message', 'Mets NeoVibe à jour pour créer un compte.'));
  end if;

  if exists (select 1 from private.signup_device_exempt e
             where e.device_hash = v_hash) then
    return '{}'::jsonb;
  end if;

  select * into v_rules from private.signup_rules;
  select count(*) into v_count
    from private.device_signups s
   where s.device_hash = v_hash
     and s.created_at > now() - v_rules.per_window;

  if v_count >= v_rules.max_accounts then
    return jsonb_build_object('error', jsonb_build_object(
      'http_code', 429,
      'message', 'Ce téléphone a déjà créé trop de comptes récemment.'));
  end if;

  return '{}'::jsonb;
end;
$$;

-- Joignable par le service d'authentification SEUL : c'est une fonction du
-- schéma public, donc exposée sur /rest/v1/rpc/ si on la laissait ouverte.
revoke execute on function public.hook_before_user_created(jsonb)
  from public, anon, authenticated;
grant execute on function public.hook_before_user_created(jsonb)
  to supabase_auth_admin;

-- ─── Le registre : après la création ─────────────────────────────────────────

create or replace function private.record_device_signup()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if new.raw_user_meta_data ->> 'device_hash' ~ '^[0-9a-f]{64}$' then
    insert into private.device_signups (user_id, device_hash)
    values (new.id, new.raw_user_meta_data ->> 'device_hash')
    on conflict (user_id) do nothing;
  end if;
  return new;
end;
$$;

create trigger record_device_signup
  after insert on auth.users
  for each row execute function private.record_device_signup();
