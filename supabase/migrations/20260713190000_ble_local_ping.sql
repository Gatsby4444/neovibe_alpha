-- Chantier A (décisions Jay 2026-07-13) : le ping devient 100 % BLE local.
-- Le serveur ne résout plus les identifiants BLE (l'annuaire disparaît) ;
-- il ne reçoit plus que des ARTEFACTS CO-SIGNÉS par les deux appareils :
-- certificats de croisement (10 s de contact continu) et connexions
-- acceptées. Vérification Ed25519 via pgsodium.

create extension if not exists pgsodium;

-- 1. Clés d'appareil : publiées par chacun, lisibles par ses connexions
--    (clé de reconnaissance des amis = IDs rotatifs déchiffrables hors ligne).
create table if not exists public.device_keys (
  user_id uuid primary key references public.profiles(id) on delete cascade,
  ed_pub text not null,          -- clé publique Ed25519 (base64)
  broadcast_key text not null,   -- clé de diffusion rotative (base64)
  updated_at timestamptz not null default now()
);

alter table public.device_keys enable row level security;

drop policy if exists device_keys_own on public.device_keys;
create policy device_keys_own on public.device_keys
  for all using (user_id = auth.uid()) with check (user_id = auth.uid());

drop policy if exists device_keys_friends on public.device_keys;
create policy device_keys_friends on public.device_keys
  for select using (
    exists (
      select 1 from public.connections c
      where c.status = 'full'
        and ((c.user_low = auth.uid() and c.user_high = device_keys.user_id)
          or (c.user_high = auth.uid() and c.user_low = device_keys.user_id))
    )
  );

-- 2. Vérification d'une signature Ed25519 base64 (pgsodium).
create or replace function private.verify_ed25519(
  message text, sig_b64 text, pub_b64 text
) returns boolean
language plpgsql immutable as $$
begin
  return pgsodium.crypto_sign_verify_detached(
    decode(sig_b64, 'base64'),
    convert_to(message, 'utf8'),
    decode(pub_b64, 'base64')
  );
exception when others then
  return false;
end;
$$;

-- 3. Croisement certifié : le serveur n'accepte QUE des certificats
--    co-signés par les clés d'appareil ENREGISTRÉES des deux utilisateurs
--    (anti-fraude : impossible de prétendre avoir croisé quelqu'un) dont
--    l'horodatage est récent. Alimente public.encounters (features de
--    rétention : « vous avez croisé… », suggestions — décision A7a).
create or replace function public.report_encounter(cert jsonb)
returns void
language plpgsql security definer set search_path = public, private as $$
declare
  a uuid := (cert->>'a')::uuid;
  b uuid := (cert->>'b')::uuid;
  ts timestamptz := (cert->>'ts')::timestamptz;
  payload text;
  pub_a text;
  pub_b text;
  lo uuid;
  hi uuid;
begin
  if auth.uid() is null or (auth.uid() <> a and auth.uid() <> b) then
    raise exception 'Certificat étranger';
  end if;
  if ts is null or ts > now() + interval '5 minutes'
     or ts < now() - interval '7 days' then
    raise exception 'Certificat expiré';
  end if;
  select ed_pub into pub_a from public.device_keys where user_id = a;
  select ed_pub into pub_b from public.device_keys where user_id = b;
  if pub_a is null or pub_b is null then
    raise exception 'Clés d''appareil non enregistrées';
  end if;
  payload := 'nv-cert|' || a || '|' || b || '|' || (cert->>'ts');
  if not private.verify_ed25519(payload, cert->>'sigA', pub_a)
     or not private.verify_ed25519(payload, cert->>'sigB', pub_b) then
    raise exception 'Signatures de croisement invalides';
  end if;
  lo := least(a, b);
  hi := greatest(a, b);
  insert into public.encounters (user_low, user_high, first_seen_at, last_seen_at)
  values (lo, hi, ts, ts)
  on conflict (user_low, user_high)
  do update set last_seen_at = greatest(excluded.last_seen_at, encounters.last_seen_at);
end;
$$;

-- 4. Connexion co-signée en BLE : la demande est signée par l'émetteur,
--    l'acceptation par le récepteur — le serveur vérifie les DEUX
--    signatures (états divergents impossibles, anti-bypass — décision A1)
--    puis crée la connexion full.
create or replace function public.submit_ble_connection(record jsonb)
returns void
language plpgsql security definer set search_path = public, private as $$
declare
  u_from uuid := (record->>'from')::uuid;
  u_to uuid := (record->>'to')::uuid;
  ts timestamptz := (record->>'ts')::timestamptz;
  pub_from text;
  pub_to text;
  lo uuid;
  hi uuid;
begin
  if auth.uid() is null or (auth.uid() <> u_from and auth.uid() <> u_to) then
    raise exception 'Connexion étrangère';
  end if;
  if ts is null or ts > now() + interval '5 minutes'
     or ts < now() - interval '30 days' then
    raise exception 'Demande expirée';
  end if;
  select ed_pub into pub_from from public.device_keys where user_id = u_from;
  select ed_pub into pub_to from public.device_keys where user_id = u_to;
  if pub_from is null or pub_to is null then
    raise exception 'Clés d''appareil non enregistrées';
  end if;
  if not private.verify_ed25519(
       'nv-friend|' || u_from || '|' || u_to || '|' || (record->>'ts'),
       record->>'sigFrom', pub_from) then
    raise exception 'Signature de demande invalide';
  end if;
  if not private.verify_ed25519(
       'nv-friend-accept|' || u_from || '|' || u_to || '|' || (record->>'ts'),
       record->>'sigTo', pub_to) then
    raise exception 'Signature d''acceptation invalide';
  end if;
  lo := least(u_from, u_to);
  hi := greatest(u_from, u_to);
  insert into public.connections
    (user_low, user_high, status, origin, confirmed_low, confirmed_high, established_at)
  values (lo, hi, 'full', 'ble', true, true, now())
  on conflict (user_low, user_high)
  do update set status = 'full', confirmed_low = true, confirmed_high = true,
    established_at = coalesce(connections.established_at, now());
end;
$$;

grant execute on function public.report_encounter(jsonb) to authenticated;
grant execute on function public.submit_ble_connection(jsonb) to authenticated;

-- 5. Fin de l'annuaire BLE serveur : le token fixe disparaît (anti-pistage
--    par conception — il n'y a plus rien à voler) et les conversations prox
--    ne migrent plus (séparation TOTALE ping/amis, décision A5).
drop trigger if exists connections_promote_prox on public.connections;
drop function if exists public.resolve_ble_tokens(uuid[]);
drop function if exists public.resolve_ble_tokens(text[]);
alter table public.profiles drop column if exists ble_token;
