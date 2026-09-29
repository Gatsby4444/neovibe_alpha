-- LE RETRAIT DE L'ANCIEN GARDIEN ET DES IMITATIONS DE SUPABASE.
--
-- Une migration « EN SERVICE » (server/migrations_en_service/) : jouée UNE
-- fois, sur les bases en service seulement — `neovibe` sur le VPS (par
-- deployer.sh, inscrite dans `nv.migrations`) et `nv_serveur` sur le PC (par
-- base_locale.py --serveur). ⚠️ JAMAIS sur la base de référence de la preuve
-- (`postgres` sur le PC) : elle garde l'ancien gardien comme étalon.
--
-- ⚠️ Une fois, pas à chaque déploiement : rejouée, elle effacerait toute
-- fonction, tout déclencheur, toute règle ajoutés PLUS TARD par une
-- migration légitime — sans bruit (prouvé par le gardien-securite le
-- 2026-09-29 sur la première version, qui était rejouée).
--
-- Depuis la bascule du 2026-09-29, le serveur Rust tient toutes les règles
-- (server/crates/nv-app) : il n'appelle aucune fonction de la base (test
-- `sans_ancien_gardien`), se connecte en `nv_server` et parle au direct par
-- `nv.annoncer`. Ce qui venait de Supabase ne fait plus rien — et un reste
-- éteint peut se rallumer (la rencontre au ping notée deux fois,
-- 2026-09-29). Inventaire complet par le cartographe le 2026-09-29 ; essayée
-- à blanc sur le VPS avant d'être jouée (sa vérification finale y a arrêté
-- une première version qui aurait retiré `set_updated_at`).
--
-- CE QUI RESTE, énoncé positivement :
-- · les tables et leurs données (public 70, private 3, nv, auth.users), les
--   types, les séquences, toutes les contraintes ;
-- · les FONDATIONS (docs/serveur-rust.md) : les 11 fonctions ci-dessous et
--   les déclencheurs qui les appellent ;
-- · `storage.foldername`, seule survivante du schéma `storage` : les
--   fondations qui posent les pierres tombales l'appellent.
--
-- Jouée dans UNE transaction (psql -1) : tout ou rien.

-- Comparées par IDENTITÉ (regprocedure → oid), jamais par le nom écrit :
-- la base écrit `set_updated_at()` sans `public.` (le schéma est dans son
-- search_path) — comparée en texte, la fondation partait avec le reste.
create temp table fondations (fn regprocedure primary key) on commit drop;
insert into fondations values
  ('public.set_updated_at()'),
  ('private.affiche_d_un_evenement_parti()'),
  ('private.annonce_une_disparition()'),
  ('private.inscrit_le_media_a_supprimer()'),
  ('private.inscrit_les_octets_a_supprimer()'),
  ('private.inscrit_les_octets_de_vibe()'),
  ('private.libere_la_preuve()'),
  ('private.note_conversation_activity()'),
  ('private.oublie_l_affiche(text)'),
  ('nv.annoncer()'),
  ('storage.foldername(text)');

do $$
declare r record;
begin
  -- 1. Les règles d'accès (RLS) : elles supposaient `auth.uid()`.
  for r in select schemaname, tablename, policyname from pg_policies loop
    execute format('drop policy %I on %I.%I', r.policyname, r.schemaname, r.tablename);
  end loop;
  for r in select n.nspname, c.relname from pg_class c join pg_namespace n on n.oid = c.relnamespace
            where c.relkind = 'r' and c.relrowsecurity loop
    execute format('alter table %I.%I disable row level security', r.nspname, r.relname);
  end loop;

  -- 2. La vue qui lisait `auth.uid()`, et le temps réel de Supabase.
  drop view if exists public.key_book;
  drop publication if exists supabase_realtime;

  -- 3. Les déclencheurs qui n'appellent pas une fondation.
  for r in select t.tgname, n.nspname, c.relname from pg_trigger t
             join pg_class c on c.oid = t.tgrelid join pg_namespace n on n.oid = c.relnamespace
            where not t.tgisinternal
              and t.tgfoid not in (select fn::oid from fondations) loop
    execute format('drop trigger %I on %I.%I', r.tgname, r.nspname, r.relname);
  end loop;

  -- 4. Les fonctions qui ne sont pas des fondations (hors extensions,
  --    retirées avec elles).
  for r in select p.oid::regprocedure::text as sig, p.prokind from pg_proc p
             join pg_namespace n on n.oid = p.pronamespace
            where n.nspname in ('public', 'private', 'auth', 'storage', 'cron', 'pgsodium', 'nv')
              and not exists (select 1 from pg_depend d where d.objid = p.oid and d.deptype = 'e')
              and p.oid not in (select fn::oid from fondations) loop
    execute format('drop %s %s', case r.prokind when 'p' then 'procedure' else 'function' end, r.sig);
  end loop;
end $$;

-- 5. Les imitations de Supabase.
drop table if exists cron.job_run_details, cron.job;
drop schema if exists cron;
drop schema if exists pgsodium;
drop table if exists storage.objects, storage.buckets;
drop type if exists storage.buckettype;
drop extension if exists pgcrypto;
drop extension if exists "uuid-ossp";
drop schema if exists extensions;

-- 6. Les droits accordés aux rôles de Supabase, dans CETTE base, puis les
--    rôles eux-mêmes s'ils ne servent plus nulle part sur ce serveur de
--    base (sur le PC, la base de référence les garde : ils restent, sans
--    rien dans CETTE base).
do $$
declare r text;
begin
  foreach r in array array['anon', 'authenticated', 'service_role', 'authenticator', 'dashboard_user',
                           'supabase_admin', 'supabase_auth_admin', 'supabase_storage_admin'] loop
    if exists (select 1 from pg_roles where rolname = r) then
      execute format('drop owned by %I', r);
    end if;
  end loop;
  foreach r in array array['authenticator', 'anon', 'authenticated', 'service_role', 'dashboard_user',
                           'supabase_admin', 'supabase_auth_admin', 'supabase_storage_admin'] loop
    if exists (select 1 from pg_roles where rolname = r)
       and not exists (select 1 from pg_shdepend where refobjid = (select oid from pg_roles where rolname = r)) then
      execute format('drop role %I', r);
    end if;
  end loop;
end $$;

-- 7. Ce que la base cherche : plus de schéma `extensions`.
do $$ begin execute format('alter database %I set search_path = "$user", public', current_database()); end $$;

-- 8. L'état attendu — vérifié, pas supposé : exactement les fondations
--    déclarées ci-dessus (comptées, pas un chiffre écrit en dur).
do $$
declare n int;
declare attendu int := (select count(*) from fondations);
begin
  select count(*) into n from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
   where ns.nspname in ('public', 'private', 'auth', 'storage', 'nv', 'cron', 'pgsodium');
  if n <> attendu then raise exception 'retrait : % fonctions restent (% attendues : les fondations)', n, attendu; end if;
  select count(*) into n from pg_policies;
  if n <> 0 then raise exception 'retrait : % règles RLS restent', n; end if;
  select count(*) into n from pg_trigger t where not t.tgisinternal
     and t.tgfoid not in (select fn::oid from fondations);
  if n <> 0 then raise exception 'retrait : % déclencheurs hors fondations restent', n; end if;
  select count(*) into n from pg_extension where extname <> 'plpgsql';
  if n <> 0 then raise exception 'retrait : % extensions restent', n; end if;
end $$;
